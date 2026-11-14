# Roadmap

`goose-igzip` exposes **igzip**, ISA-L's gzip implementation, to Goose.

igzip is a well-defined part of ISA-L rather than a slice of its API surface:
its own header (`include/igzip_lib.h`, which includes nothing but `<stdint.h>`),
its own sources under `igzip/`, and one outside dependency — the CRC-32 and
Adler-32 kernels in `crc/`, which gzip and zlib trailers use. igzip calls those
itself to verify a trailer; this package therefore relies on them without
exposing them, which is the boundary [docs/coverage.md](docs/coverage.md)
records.

So the end state is a complete, fast gzip/zlib/deflate codec in Goose, and every
version keeps the same shape:

- state lives in Goose values, so the owning scope is the free;
- C's status codes become a typed `Status`, and nothing aborts on bad input;
- the caller chooses buffer strategy (append, or a fresh buffer) and policy
  (level, wrapper, trained tables);
- layouts are pinned by static asserts, so an ISA-L upgrade fails the build
  instead of corrupting memory.

---

## Shipped: 0.1.0 — stateless deflate

| Area | Contents |
|---|---|
| Compression | `Compressor` + `compress` / `compressed`; levels 0-3; raw, gzip and zlib wrappers; `set_tables` / `clear_tables` |
| Training | `Trainer` + `add`, `symbols`, `build`, `counts` / `trainer_of` |
| Values | `Compressor` (299,472 B), `Trainer` (18,912 B), `Histogram` (2,528 B), `HuffTables` (2,232 B) |
| Diagnostics | `Status` + `ok` / `status_name`; `version`, `bound`, `compressor_size`, `trainer_size`; a table is validated before use |
| Tests | 25 streams inflated by an independent decoder, block-boundary sizes, determinism, incompressible input, trained-vs-default size assertions, a four-worker thread test |

The training path exists because a table trained on one class of body beats
both level 0's default table and, at far higher speed, the ratio of level 1.
Numbers are in the README.

## 0.1.x — hardening the same surface

No new API; what real traffic finds.

- A fuzz harness: random inputs and lengths across every level and wrapper,
  inflated and compared, under `--debug`.
- Re-run `make stress` per ISA-L release, so `ISAL_BOUND_MARGIN` stays proven
  rather than assumed.
- Decide whether `bound()` should account for multi-member buffers.

## Shipped: 0.2.0 — streaming deflate and gzip header control

**Design brief: [docs/design/0.2.0.md](docs/design/0.2.0.md).**

For bodies produced in pieces, and for byte-identical repeats. The result is a
separate `Writer` (367,280 B), not a mode on `Compressor`:

- `write` / `flush(Sync|Full)` / `finish` / `reset`, with a `Fresh →
  HeaderWritten → Open → Flushed → Finished` lifecycle and `BadState` on misuse.
- `GzipHeader` and `ZlibHeader` written explicitly ahead of the first body byte;
  the trailer is automatic. Large headers bypass the 64 KiB chunk.
- `set_dict` for raw and zlib, with the FDICT/DICTID header igzip's default zlib
  path omits.
- `set_tables` / `clear_tables`, level-pinned to 0 and legal after a flush.
- Inputs past 2 GiB are split into windows in `write`; `test/large_stream.goose`
  streams 4.2 GiB and checks the wrapped gzip ISIZE.
- A mid-stream copy is rejected by a `pinned_self` check; `reset` recovers it.
- Tests are split by concern: `test/writer_contract.goose` for state and edge
  cases, `test/streaming.goose` for end-to-end behavior, and
  `test/support/` for shared generators; 43 streams are independently decoded.

## Shipped: 0.3.0 — the complete codec

**Design brief: [docs/design/0.3.0.md](docs/design/0.3.0.md).**

Inflate, which is the other half of the codec, and header reading, which closes
the last capability gap against `igzip_lib.h`. With this release a caller can do
everything igzip can do: compress and decompress, streaming or one-shot, write
and read a container header, train a table, and set a dictionary.

| Area | Contents |
|---|---|
| Reading | `Reader` (152,936 B) + `read` / `finished` / `finish` / `reset`; `read_windowed`; input above `MAX_INPUT` split into windows |
| One-shot | `inflate` (one member into a caller-sized slice, `TooSmall` on a short one) and `inflated` (every member, fresh buffer) |
| Headers | `read_gzip_header` / `read_zlib_header` → `GzipInfo` / `ZlibInfo`: fields plus offsets for name, comment, extra and the body, parsed in Goose over a slice |
| Dictionaries | `set_dict` in `Fresh`, and again right after `NeedDict` — the zlib FDICT path, both directions |
| Errors | `Truncated`, `TooSmall`, `NeedDict`, `Corrupt`, `BadChecksum`; a terminal error latches the reader |
| Tests | `test/roundtrip.goose`, `test/inflate_contract.goose`, `test/header_contract.goose`, `scripts/read_stress.c`, a 4.2 GiB round trip, and `make test` no longer needing Python |

Five facts the implementation is built on, all measured rather than assumed:
completion is `block_state == ISAL_BLOCK_FINISH` and not a return code (igzip
folds `ISAL_END_INPUT` into success); `FINISH` is only set once the staging buffer
is provably empty; the two halves of the codec collide on `-1` and `-3`, so the
shim translates inflate's codes into their own range; `isal_inflate_stateless` is
honest about `avail_out` where `isal_deflate_stateless` is not; and a corrupted
payload usually surfaces as `Ok` with the member unfinished, which is why
`finish` exists.

`docs/coverage.md` is the map from `igzip_lib.h` to this package, including the
four things deliberately left out and why.

### What is not in 0.3.0, and not coming

**Checksums.** The plan had a 0.4.0 for `crc32_gzip_refl` and `isal_adler32`. It
is dropped rather than deferred. igzip verifies a gzip or zlib trailer itself,
so a caller already learns whether a stream is intact from the `Reader`; a caller
who wants a CRC *value* wants a checksum library, and `crc.h` also holds `crc16`,
`crc64` and `crc32c`, which no gzip stream needs. The boundary this package keeps
is: it verifies checksums, it does not compute them. Reasoning in
[docs/coverage.md](docs/coverage.md#the-checksum-decision).

Also out by decision, all additive and all listed with their cost in
[coverage.md](docs/coverage.md): subset Huffman tables, the preprocessed
dictionary cache, and `IGZIP_HUFFTABLE_STATIC`.

## Tech debt and TODOs

Known gaps, roughly in the order they are worth picking up.

| Item | What it is | Why it matters |
|---|---|---|
| Goose v2026.4 miscompile on windows-x64 | In `test/threads.goose`, the body the *main thread* compressed was wrong while the identical function inside a `thread_fn` produced the right bytes. The first `format`-driven build of a growable body from an empty buffer in `main` is correct; every later one leaves literal fragments at wrong offsets and NUL holes -- same length, first difference at byte 15. The decoded bytes matched the main thread's own checksum and igzip had verified the gzip trailer, so the codec and the queue were correct. The test builds its largest body once and slices prefixes, and the reader worker still regenerates each body from scratch, so a wrong body fails. Details in [docs/internals.md](docs/internals.md). | An upstream compiler bug, not a package bug: the corruption is already in `main` before any thread or writer is involved. Until it is fixed in `aardappel/goose`, a Windows `main` should not build the same growable buffer in a second call. |
| macOS runner supply | Both macOS legs run (`macos-15`, `macos-15-intel`). Intel images are queued for long periods and are being retired; `macos-15-intel` is the last x64 image. | A macOS job that waits, or is cancelled before a runner is assigned, is runner availability rather than this workflow. The Linux and Windows legs run anywhere. |
| `make test-large` skipped on Windows | the 4.2 GiB round trip runs everywhere else | it takes longer than a job is worth there; revisit if Windows throughput matters |
| Extern-signature parity is unchecked | `_Static_assert`s pin every layout, but nothing pins a `extern fn` declaration against the C definition: a mismatched arity or type links and passes garbage. `goose_gfx/test/api_check.py` does this by parsing both sides | the one boundary check `goose_gfx` has that this package does not. A Goose test reading `igzip.goose` and `src/igzip_shim.c` would keep `make test` python-free |
| Streamed failures do not travel with the value | `igzip::status()` is per thread and describes the *call*, so a helper taking `r: Reader&` cannot report *r's* reason | a latched `status` field on `Writer`/`Reader` fixes it at +8 bytes each and a bump of the pinned asserts. Deliberate omission, not an oversight |
| Error-return shape is still contested | The `const Status?` variant and the current `bool` plus `status()` were both built and tested during 0.4.0 | One of the two should be chosen; carrying both designs is a maintenance trap |
| No fuzz target | `make stress` mutates a fixed corpus under ASan rather than fuzzing | the reader is the package's untrusted-input surface; libFuzzer over `inflate`/`read` would find what a fixed mutation set cannot |
| ISA-L bump is manual | checkout the tag, update `EXPECTED_ISA_L`, run verify and stress (docs/internals.md) | the procedure is written down but nothing enforces that it was followed |
| Doc snippets are compiled by hand | every snippet in README and guide was compiled against the package before a release, but nothing does it automatically | a doc example that stops compiling is invisible until someone tries it |

## 1.0.0 — stable

- Freeze the surface; additive changes only.
- Document the exact ISA-L releases tested and the static asserts that guard
  each layout.

---

## Out of scope

These are ISA-L, but they are not igzip, and folding them in would make the
package name a lie. Each wants its own package, with its own audience and its
own API shape:

| Area | Why not here |
|---|---|
| `erasure_code.h`, `raid.h` | storage-system APIs built around caller-owned pointer arrays, which Goose does not have; a design problem of their own |
| `mem_routines.h` | risks being slower than libc at small sizes, and Goose's own aggregated copies already cover the common case |
| `crc16`, `crc64`, `crc32c` | no gzip stream needs them |
| `crc32_gzip_refl`, `isal_adler32` | the trailer check, so a caller does not need one; a caller who wants a checksum value wants a checksum library, and this package verifies rather than computes (see [docs/coverage.md](docs/coverage.md#the-checksum-decision)) |

## Measurements

Sizes, taken from the vendored headers. These decide the ownership model.

| struct | bytes | consequence |
|---|---|---|
| `isal_zstream` | 82,384 | too big to pass by value per call, so it is a fixed blob in `Compressor` |
| `inflate_state` | 87,368 | the same for `Reader`: state in the value, not on the C stack |
| `isal_huff_histogram` | 18,912 | only 2,528 bytes are accumulators; the rest is per-call match scratch |
| `isal_hufftables` | 2,232 | small enough to be a cache entry's field |
| `ISAL_DEF_LVL3_MEDIUM` | 217,088 | level buffer for levels 1-3, carried by the value |
| `ISAL_DEF_LVL1_DEFAULT` | 282,624 | why a level buffer must not live on the C stack |

The behaviours these measurements explain are recorded, numbered, in
[docs/internals.md](docs/internals.md#igzip-behaviour-this-api-encodes).

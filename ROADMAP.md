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
The measurements are in [docs/guide.md](docs/guide.md).

## Shipped: 0.2.0 — streaming deflate and gzip header control

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

Five behaviours underlie the implementation, each measured against the
vendored pin: completion is `block_state == ISAL_BLOCK_FINISH` and not a return
code, because igzip folds `ISAL_END_INPUT` into success; `FINISH` is only set once
the staging buffer is provably empty; the two halves of the codec collide on `-1`
and `-3`, so the shim translates inflate's codes into their own range;
`isal_inflate_stateless` respects `avail_out` where `isal_deflate_stateless` does
not; and a corrupted payload usually surfaces as `Ok` with the member unfinished,
which is why `finish` exists.

`docs/coverage.md` is the map from `igzip_lib.h` to this package, including
what is left out and why.

## Shipped: 0.4.0 — the shape of failure, and a four-platform CI

No new codec capability. A call that can fail now returns a `bool` with its data
in front of it, and the reason is carried out of band:

- `let used, ok = r.read(..)` and `let gz, ok = c.compressed(..)`; the reason is
  `igzip::status()` for a `Status` to branch on and `igzip::error()` for text.
  `Status` lost its `Ok` variant and `ok()` is gone, because a `Status` now means
  *why a call failed*.
- Every call records its outcome, so `status()` is `Ok` exactly when the bool was
  true. The record is per thread, so a worker's failure is its own.
- `bound(n)` returns `0` when there is no bound to give: a negative length, or
  one whose bound would not fit igzip's 32-bit lengths. It no longer clamps,
  which for an input near 2 GiB produced a bound no larger than the input.
- The C boundary refuses a non-empty slice with a null data pointer at every
  entry point that dereferences one.
- CI builds, runs and independently decodes on all four platforms Goose ships a
  compiler for: linux-x64, macos-x64, macos-arm64 and windows-x64. The
  AddressSanitizer harnesses and the CPython decoder run there too, not only
  locally.
- The design briefs were retired; what a maintainer needs from them now lives in
  [docs/internals.md](docs/internals.md) and [docs/guide.md](docs/guide.md).

## Known gaps

Open work, roughly in the order it is useful to address.

| Item | What it is | Why it matters |
|---|---|---|
| Goose v2026.4 miscompile on windows-x64 | Goose v2026.4's MSVC output miscompiles a second `format`-driven build of a growable buffer in a Windows `main`: the first build from an empty buffer is correct, later ones contain literal fragments at wrong offsets. The corruption is present before any thread or writer is involved, and the same function in a `thread_fn` is correct. `test/threads.goose` builds its body once and slices it, so the defect is not on the tested path. | This is an upstream compiler defect, not a defect in this package. Until it is fixed in `aardappel/goose`, a Windows `main` should not fill the same growable buffer in a second call. |
| macOS runner availability | Both macOS jobs run (`macos-15`, `macos-15-intel`). Intel images are queued for long periods and are being retired; `macos-15-intel` is the last x64 image. | A macOS job that waits, or is cancelled before a runner is assigned, reflects runner availability rather than this workflow. The Linux and Windows jobs run on any hosted image. |
| `make test-large` is skipped on Windows | The 4.2 GiB round trip runs on every other platform. | It takes longer than the Windows job justifies. It can be enabled if Windows throughput becomes a target. |
| `extern fn` signatures are not checked against C | `_Static_assert`s pin every layout, but no check compares an `extern fn` declaration with its C definition: a mismatched arity or type links and passes garbage. | A check generated from both sides would close the last boundary gap and keep `make test` free of Python. |
| Streamed failures do not travel with the value | `igzip::status()` is per thread and describes the *call*, so a helper taking `r: Reader&` cannot report that reader's reason. | A latched `status` field on `Writer` and `Reader` would fix it at 8 bytes each, at the cost of a bump to the pinned sizes. This is a deliberate omission. |
| No fuzz target | `make stress` mutates a fixed corpus under AddressSanitizer rather than fuzzing. | The reader is the package's untrusted-input surface; libFuzzer over `inflate` and `read` would find inputs a fixed mutation set cannot. |
| ISA-L upgrades are manual | The tag is checked out, `EXPECTED_ISA_L` is updated, and `make verify` plus `make stress` are run. | The procedure is documented in `docs/internals.md`, but nothing enforces that it was followed. |
| Documentation snippets are compiled by hand | Every snippet in the README and guide is compiled against the package before a release. | Nothing does this automatically, so a snippet that stops compiling is invisible until a reader tries it. |

## 1.0.0 — stable

- Freeze the surface; additive changes only.
- Document the exact ISA-L releases tested and the static asserts that guard
  each layout.

---

## Out of scope

These are part of ISA-L but not part of igzip. Including them would make the
package something other than what its name says, and each deserves its own
package, audience and API shape:

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

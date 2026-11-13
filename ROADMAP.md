# Roadmap

`goose-igzip` exposes **igzip**, ISA-L's gzip implementation, to Goose.

igzip is a well-defined part of ISA-L rather than a slice of its API surface:
its own header (`include/igzip_lib.h`, which includes nothing but `<stdint.h>`),
its own sources under `igzip/`, and one outside dependency — the CRC-32 and
Adler-32 kernels in `crc/`, which gzip and zlib trailers use. That dependency is
the reason the checksums are in this package's scope: a gzip codec cannot verify
a trailer without them.

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

## 0.2.0 — streaming deflate and gzip header control

For bodies produced in pieces, and for byte-identical repeats.

- `isal_deflate` with `NO_FLUSH`, `SYNC_FLUSH`, `FULL_FLUSH`: compress as a
  response is generated instead of buffering it whole.
- `isal_write_gzip_header` with a filled `isal_gzip_header`: custom mtime and OS
  byte, plus `GZIP_NO_HDR`, so a cache can emit a stable header and vary only
  the deflate body.
- Lifting the 2 GiB input limit: feed igzip one 32-bit length at a time.
- `isal_deflate_set_dictionary` for shared-prefix bodies.

## 0.3.0 — inflate

The other half of the codec, and the point at which the package can test itself
instead of leaning on a Python decoder.

- `isal_inflate` (stateful) with an `Inflater` value matching `Deflater`,
  buffering output chunks through `gs_bld_append`, plus `isal_inflate_reset` for
  concatenated members.
- `isal_inflate_stateless` for whole-buffer reads.
- `isal_inflate_set_dictionary`; truncated input reported as its own `Status`,
  not as corruption.
- Round-trip becomes a Goose test: the first version whose tests need no
  `scripts/check_gzip.py`.

## 0.4.0 — the two checksums gzip needs

Small, and already linked: igzip calls these itself, so exposing them costs
nothing and lets a caller verify a trailer or build an ETag.

- `crc32_gzip_refl` and `isal_adler32`, one-shot over `const u8[:]` plus an
  incremental form for a stream read in pieces.
- `crc32_ieee` if a caller wants the non-reflected variant for a container
  format; nothing else from `crc.h`.

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
| libdeflate | a different library entirely; a caller that wants it adds its own binding |

## Decision record

**Vendored submodule + CMake, not a system install.** Three approaches were
considered:

| Approach | Verdict |
|---|---|
| Require `libisal-dev` on the build machine | Rejected: works only where a distro version is installed, the version floats, and the shim can mix old headers with a new library |
| Submodule + CMake target | **Chosen**: pinned, reproducible, full SIMD, one `git submodule update` from a clean checkout |
| Submodule + `c_sources` listing ISA-L's `.c` files | Rejected: ISA-L's kernels are NASM, and the C files alone compile only with `igzip_base_aliases.c` standing in for the SIMD bodies — correct but several times slower, which discards the point of the library |

This matches what established bindings do: [python-isal](https://github.com/pycompression/python-isal),
the binding ISA-L's own wiki points at, carries ISA-L as a git submodule and
builds it from source by default.

**Stateless deflate, with streaming later.** A chunked `isal_deflate` loop was
built and measured against the stateless path: the output is byte-identical
(120,233 bytes in, 8,045 out, `memcmp` equal), so streaming is safe to add
whenever a caller needs it. It was not used for 0.1.0 because:

| | stateless (shipped) | chunked loop |
|---|---|---|
| C stack per call | 0 (state is in the `Compressor`) | ~430 KB with the level buffer, chunk buffer and stream in one frame |
| output copies | writes once into the builder | every byte through a chunk buffer |
| input limit | 2 GiB | none |

The 2 GiB limit is the one real advantage, so streaming arrives in 0.2.0 with
the buffers owned by the value rather than the stack.

**Values, not handles.** An earlier revision kept igzip's state in C memory
behind a `u64` handle with an explicit close. That is the C idiom, not the Goose
one: a scope exit is already the free, and an explicit close is a leak waiting
to happen. Everything a caller touches is now a fixed-size value.

## Measurements

Sizes, taken from the vendored headers. These decide the ownership model.

| struct | bytes | consequence |
|---|---|---|
| `isal_zstream` | 82,384 | too big to pass by value per call, so it is a fixed blob in `Compressor` |
| `isal_huff_histogram` | 18,912 | only 2,528 bytes are accumulators; the rest is per-call match scratch |
| `isal_hufftables` | 2,232 | small enough to be a cache entry's field |
| `ISAL_DEF_LVL3_MEDIUM` | 217,088 | level buffer for levels 1-3, carried by the value |
| `ISAL_DEF_LVL1_DEFAULT` | 282,624 | why a level buffer must not live on the C stack |

Behaviours, all verified against 2.32.1 and unchanged from 2.31.1:

1. **A supplied Huffman table is used at level 0 only.** Levels 1-3 build their
   own tables per block (`create_hufftables_icf`); a trained table at level 1
   produced byte-identical output to the default one. `set_tables` therefore
   pins the level to 0, and `compress` takes no level when a table is attached.
2. **The histogram match scratch must be cleared between samples.**
   `isal_update_histogram` keeps positions in `hash_table[8192]`; reusing them
   across samples compares the new input against stale offsets.
3. **`isal_deflate_stateless` can overrun an undersized output buffer** at
   levels 2-3 instead of returning `STATELESS_OVERFLOW` (observed under
   AddressSanitizer). `compress` therefore always supplies `bound(n)`, whose
   worst case measured +23 bytes at 1 KiB and +103 bytes at 1 MiB.
4. **igzip lengths are 32-bit.** Inputs above `MAX_INPUT` are rejected, never
   silently truncated — including training samples, where truncation would
   quietly train on half a body.
5. **A table's header length is trusted by igzip.** `write_header` indexes
   `deflate_hdr[deflate_hdr_count]`, so a fabricated or deserialized table is
   validated before use and rejected as `Status.BadTable`.

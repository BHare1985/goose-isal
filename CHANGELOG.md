# Changelog

## 0.2.0 — 2026-11-13

Streaming deflate, custom headers, preset dictionaries, and inputs beyond the
one-shot 2 GiB limit.

### Added

- `Writer` — a separate 367,280-byte stateful deflater, with
  `gzip_writer` / `zlib_writer` / `raw_writer` / `writer`. `write` appends,
  `flush` is a Sync or Full decode point, `finish` writes the trailer, and
  `reset` reuses the value for the next body. Inputs above `MAX_INPUT` are split
  into windows inside `write`; `write_windowed` exposes the window size.
- `GzipHeader` and `write_gzip_header` — mtime, OS, text/xflags, name, comment,
  extra and HCRC, with reproducible defaults and the NUL/length rules RFC 1952
  requires. Headers larger than the 64 KiB chunk are supported.
- `ZlibHeader` and `write_zlib_header` — window bits and FLEVEL.
- `set_dict` for raw and zlib streams. A zlib stream with a dictionary emits
  FDICT/DICTID itself, because igzip's default zlib header does not; without it
  standard decoders reject the stream.
- `set_tables` / `clear_tables` on a Writer, legal before the first byte and
  after a completed Sync or Full flush. A supplied table pins level 0, as with
  `Compressor`.
- `Status.BadHeader`, `writer_size`, and lifecycle state (`Fresh`,
  `HeaderWritten`, `Open`, `Flushed`, `Finished`).
- Tests split into `test/contract.goose` (one-shot), `test/writer_contract.goose`
  (state, totals, headers, dictionaries, tables, copy guard), and
  `test/streaming.goose` (equivalence, chunking, flush points, windows), with
  shared generators in `test/support/`. Covers one-shot/chunked equivalence,
  Sync/Full decode points, custom and 65 KiB headers, zlib windows,
  dictionaries with and without the dictionary, trained tables and a mid-flush
  swap, lifecycle misuse, initialized-writer copies, a 4.2 GiB stream,
  two streaming thread workers, 17 new independently decoded streams (42 total), and
  stateful output-buffer/header stress cases under AddressSanitizer.

### Notes

- A copy of an initialized `Writer` is rejected with `Status.BadState`; the copy's C pointers
  would point into the original. `reset` recovers it.
- ISA-L level 0 in the stateful path ends one stored byte differently from the
  stateless path. Levels 1-3 are byte-identical; level 0 remains a valid stream.
- `isal_deflate_set_dict` copies the last 32 KiB; the dictionary slice does not
  need to outlive the call. zlib's DICTID covers the whole dictionary.
- The 0.1.0 API and its output are unchanged.

## 0.1.0 — 2026-11-13

First release: igzip's deflate half, in the shape the rest of the codec will
follow — state in Goose values, typed `Status`, the caller's choice of buffer.

### Added

- `Compressor` — one-shot deflate at levels 0-3 with raw, gzip and zlib
  wrappers. `compress` appends into a buffer you own; `compressed` builds a new
  one in your destination. Both are ~300 KB of state, freed by scope.
- `Trainer`, `Histogram`, `HuffTables` — sampling (`add`, `symbols`), table
  construction (`build`), and counts moved in and out at 2.5 KB per content
  type (`counts`, `trainer_of`). `set_tables` attaches a table to a compressor
  and pins the level to 0, the only level igzip honours one at.
- Diagnostics: `version` (read from ISA-L's own headers), `bound`, `status_name`,
  `compressor_size`, `trainer_size`, and `MAX_INPUT`.
- `docs/internals.md` — the submodule pin and bump procedure, the memory model,
  the igzip behaviours the API encodes, the security notes, and the FFI review
  gates.
- Tests: 25 streams inflated by CPython's zlib and compared byte for byte
  (including deflate's block-boundary sizes, incompressible input, concatenated
  members and concatenated runs), a four-worker thread test, and
  `scripts/bound_stress.c`, which checks the output bound as an exact buffer
  size under AddressSanitizer.

### Notes

- ISA-L 2.32.1 is vendored as a pinned submodule and built with CMake, so
  nothing is installed system-wide. Building needs git, cmake, nasm and a C
  compiler.
- libdeflate is out of scope, permanently.
- Inputs above `MAX_INPUT` are rejected rather than truncated.
- A `HuffTables` value that was never built, or was deserialized from storage,
  is validated before igzip sees it: a bogus header length returns
  `Status.BadTable` instead of reading outside the value.

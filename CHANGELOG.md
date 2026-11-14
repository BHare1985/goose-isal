# Changelog

## 0.3.0 — 2026-11-14

The other half of the codec: the package now reads what it writes, and its own
tests no longer need an external decoder.

### Added

- `Reader` — a 152,936-byte streaming inflater with `gzip_reader` /
  `zlib_reader` / `raw_reader` / `reader`. `read` appends the decoded bytes and
  returns how many of the input's bytes it consumed, because decompression stops
  at a member boundary and leaves the rest of the slice alone. `finished` reports
  that boundary, `finish` closes the body, `reset` starts the next member.
  Inputs above `MAX_INPUT` are split into windows inside `read`; `read_windowed`
  exposes the window size.
- `inflate` — one member into a caller-sized slice, returning
  `consumed, written, Status`, and the only verb that reports `TooSmall`.
  `inflated` decodes every member in a buffer into a new one, through the
  streaming path so a dictionary works there too.
- `Status.Truncated`, `TooSmall`, `NeedDict`, `Corrupt` and `BadChecksum`, plus
  `reader_size()`. Truncated input is its own status, never corruption, and a
  terminal error latches the reader rather than leaving it able to answer `Ok`
  from a dead stream.
- `set_dict` on a reader, legal in `Fresh` and again immediately after
  `NeedDict`. igzip never compares a dictionary with the stream's DICTID, so a
  wrong one surfaces at the trailer — or, on a raw stream, not at all. That is
  documented on the function and pinned by a test.
- `test/roundtrip.goose` (every wrapper, level, size and chunk size, decoded ten
  ways), `test/inflate_contract.goose` (the transition matrix, statuses,
  dictionaries, hostile input), `scripts/read_stress.c` (AddressSanitizer over
  every truncation offset, 400 mutations and the dictionary paths), and reader
  coverage in the streaming, writer-contract, threading and 4.2 GiB tests.

### Changed

- `make test` no longer needs Python: every stream the tests write is decoded by
  the package itself. `scripts/check_gzip.py` moves to `make crosscheck`, the
  independent decoder that `make verify` runs when `python3` is installed.
- `test/large_stream.goose` round-trips its 4.2 GiB: each compressed chunk goes
  from `write` straight into `read`, and `Reader.total_out` (a `u64`) is checked
  past igzip's 32-bit `total_out`.
- `test/contract.goose`, `test/streaming.goose` and
  `test/writer_contract.goose` decode their own artifacts as they write them.
- `examples/gzip_file.goose` reads its output back before reporting success.
- `status_name(BadState)` says "this state" rather than "this writer state".

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
  swap, lifecycle misuse, initialized-writer copies, a 4.2 GiB stream, two
  streaming thread workers, 18 new independently decoded streams (43 total),
  and stateful output-buffer/header stress cases under AddressSanitizer.

### Fixed

- A custom zlib `window_bits` now sets `stream.hist_bits` as well as the CMF
  field. Before this, a 4 KiB header could be followed by 32 KiB match
  distances, and a strict decoder rejected the stream with `invalid distance
  too far back`. The checker now decodes with `zlib.decompressobj(window_bits)`.
- `Writer` validates its table at use, not only in `set_tables`, so a
  deserialized `Writer` or a caller mutating the public `tables` field cannot
  hand igzip an unvalidated header length. A `Fresh` Writer carrying
  `has_dict`/`hdr_written` without a pinned C stream is refused.
- `MAX_HEADER` (1 MiB) bounds the temporary used for a gzip header larger than
  the 64 KiB chunk, so an untrusted `name`/`comment` cannot force an unbounded
  allocation.

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

# Changelog

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

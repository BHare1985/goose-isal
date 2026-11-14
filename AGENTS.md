# Agent notes

This repository is a Goose package binding Intel ISA-L's igzip. The
maintainer-facing documentation — the submodule pin, the memory model, the igzip
behaviours the API encodes, the security notes, and the FFI review gates — is in
**[docs/internals.md](docs/internals.md)**. Read it before changing
`src/igzip_shim.c` or `igzip.goose`.

## Layout

| Path | What it is |
|---|---|
| `igzip.goose` | The package and only root file: `namespace igzip`, the public API, `extern fn` declarations |
| `src/igzip_shim.c` | The C adapter and only FFI boundary; owns no memory |
| `igzip.build` | `.build` sidecar: CMake target `igzip_goose`, directories that are not modules |
| `CMakeLists.txt` | Builds the shim and ISA-L from `vendor/isa-l` (pinned submodule) |
| `test/contract.goose` | One-shot contract tests; asserts and writes artifacts for `scripts/check_gzip.py` |
| `test/writer_contract.goose` | `Writer` state, totals, headers, dictionaries, tables, copy guard and lifecycle errors |
| `test/inflate_contract.goose` | `Reader` state machine, statuses, dictionaries, hostile input |
| `test/header_contract.goose` | Headers both ways: write then read back, and every malformed one |
| `test/roundtrip.goose` | Every wrapper, level and size, each stream decoded ten ways |
| `test/streaming.goose` | End-to-end streaming: equivalence, chunking, flush points and input windows |
| `test/support/support.goose` | Shared corpus/body/noise generators and byte comparison for the test roots |
| `test/threads.goose`, `test/large_stream.goose` | Native-only worker and 4.2 GiB tests |
| `examples/*.goose` | Runnable root programs: bench, gzip_file, trained_table |
| `scripts/` | Verification harnesses: `check_gzip.py` (independent decode), `bound_stress.c`, `read_stress.c` |
| `docs/guide.md` | How to use the package, with the reasoning |
| `docs/coverage.md` | `igzip_lib.h` surface → this package, plus what is left out and why |
| `docs/verification.md` | What `make verify` proves, file by file |
| `docs/internals.md` | Maintainer invariants: the pin, the memory model, the behaviours the API encodes, the FFI gates |

## Commands

| Command | Meaning |
|---|---|
| `make check` | `goose check igzip.goose`; typecheck only, silent on success |
| `goose run test/contract.goose --debug` | JIT; no C compiler needed |
| `goose run test/writer_contract.goose --debug` | the writer state-machine and edge-case half |
| `goose build test/threads.goose -o build/threads_test` | native build; threads require it |
| `goose build test/large_stream.goose -o build/large_stream` | 4.2 GiB through one writer |
| `goose fetch igzip.goose` | fetch declared packages (none today) |
| `goose lsp` | editor integration; list all twelve root programs as its entry files |
| `goose format igzip.goose test examples` | rewrite in Goose layout |
| `make verify` | check + JIT tests + thread test + large-stream test + examples |

## Goose code

Load the `goose-lang` skill (`.pi/skills/goose-lang/SKILL.md`) before writing or
refactoring non-trivial Goose. It carries the language reference, diagnostics,
and verified samples. Never assume Rust, C++ or Zig syntax or heap allocation:
Goose has no heap, no GC and no lifetime annotations.

Four rules, in short:

1. **C owns no memory.** State lives in Goose values; no `malloc`, no handle to
   close.
2. **`Status` is the only failure channel**, and nothing aborts on bad input.
3. **Layouts are pinned** by static asserts; a layout change must fail the build.
4. **The build is self-contained**: ISA-L comes from `vendor/isa-l` via CMake.
   Never add `c_libs`, an `extern "isal"` block, or a system install.

The loop:

```bash
make check     # after every edit; silent on success
make verify    # check + tests + thread test + large test + examples
make stress    # AddressSanitizer check of the output bound and avail_out
make fmt       # layout is goose format's decision
```

`make test` inflates every stream the tests wrote. A compressor can return `Ok`
with a plausible size and still emit a broken stream, so passing tests are not
evidence on their own.

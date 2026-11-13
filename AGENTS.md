# Agent notes

This repository is a Goose package binding Intel ISA-L's igzip. The
maintainer-facing documentation — the submodule pin, the memory model, the igzip
behaviours the API encodes, the security notes, and the FFI review gates — is in
**[docs/internals.md](docs/internals.md)**. Read it before changing
`src/igzip_shim.c` or `igzip.goose`.

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
make verify    # check + tests + thread test + examples
make stress    # AddressSanitizer check of the output bound
make fmt       # layout is goose format's decision
```

`make test` inflates every stream the tests wrote. A compressor can return `Ok`
with a plausible size and still emit a broken stream, so passing tests are not
evidence on their own.

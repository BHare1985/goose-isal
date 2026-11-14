# Internals

How the package is put together, and the invariants that are not obvious from
reading a single file. `README.md` is for people *using* the package; this is
for people *changing* it.

## The native part

ISA-L is vendored, not installed. `vendor/isa-l` is a git submodule pinned by
**commit** `7c3479e0a9dac17f448603ec1ad64c7c625f530c`, which is release tag
**v2.32.1**. `CMakeLists.txt` is the package's `cmake_target`; Goose configures
it, links the `igzip_goose` static library, and takes the rest of the link line
from it.

- **A commit, not a tag.** `.gitmodules` records only the URL; the pin is the
  tree's gitlink. If upstream force-pushes a tag, nothing here changes.
- **Why 2.32.1 and not 2.31.1:** 2.31.1 predates ISA-L's `CMakeLists.txt`
  (autotools only), and `cmake_target` needs one. Everything in this package was
  measured against both: the struct sizes are identical (82,384 / 18,912 /
  2,232 / 217,088) and the compressed output is byte-identical, so the pin did
  not change behaviour.
- **`nasm` is a build requirement.** Without it ISA-L falls back to portable C
  and the SIMD kernels — the reason to use ISA-L — are gone. The configure step
  failing is the honest outcome; do not switch to a C-only build to make a
  build pass.

**Bumping it** is a deliberate edit:

```bash
cd vendor/isa-l && git fetch --depth 1 origin tag vX.Y.Z && git checkout vX.Y.Z
```

then update `EXPECTED_ISA_L` in `test/contract.goose` and run `make verify`
and `make stress`. The `_Static_assert`s catch layout drift; `make stress`
re-proves the output bound; `igzip::version` reads ISA-L's own version macros, so
it cannot drift from the code being linked.

## The rule: C owns no memory

Goose has no heap, so `src/igzip_shim.c` must not allocate. All igzip working
state is the bytes of the `Compressor` and `Trainer` values Goose declared;
`Histogram` and `HuffTables` are plain fixed-size values the caller owns. No
`malloc`, no `free`, no `open`/`close`, no handle that can leak. Adding any of
those needs a reason that survives review.

Consequences that follow, and that repeatedly bite:

- A `Compressor` passed **by value is a ~300 KB copy**, a `Writer` ~367 KB, and
  a `Trainer` 19 KB. Functions that write take them by reference. `HuffTables`
  and `Histogram` are small enough to pass and copy freely.
- `goose.h` exports the builder types but no slice type. A `const u8[:]` arrives
  as a packed `{data, len}` pair, declared in the shim as `igzip_slice_u8`.
- Appending writes at `out.stk->top` and then claims the bytes, mirroring
  `gs_bld_append`. Never claim bytes that were not written.
- Sizes and offsets are pinned by `_Static_assert` against the C structs. When
  ISA-L changes a layout, the build fails. Keep the `compressor_size()` /
  `trainer_size()` / `writer_size()` assertions in the tests too.

## igzip behaviour this API encodes

Each of these was measured, not assumed.

1. A supplied Huffman table applies at **level 0 only**. Levels 1-3 build tables
   per block (`create_hufftables_icf`) and ignore `stream->hufftables`, so
   `set_tables` pins the level to 0 and `compress` takes no level while a table
   is attached.
2. `isal_update_histogram` keeps match positions in a scratch hash table. Every
   `add` clears that table and keeps the counters, or the new sample is compared
   against stale offsets.
3. `level_buf` must be at least `ISAL_DEF_LVL{1,2,3}_MIN`; the `Compressor`
   carries `ISAL_DEF_LVL3_MEDIUM`, which satisfies all levels.
4. `isal_deflate_stateless` can overrun a small output buffer at levels 2-3
   instead of returning `STATELESS_OVERFLOW`. Always give it `bound(n)`.
5. igzip lengths are 32-bit: inputs are rejected above `MAX_INPUT`, never
   clamped — including training samples, where truncation would quietly train on
   half a body.

6. `isal_deflate_set_dict` **copies** at most the last 32 KiB into
   `internal_state.buffer`; the Goose slice does not outlive the call. The
   zlib DICTID is the Adler-32 of the whole dictionary, so compute it before
   igzip truncates.
7. `isal_deflate_reset` does **not** clear `end_of_stream`, `flush`,
   `gzip_flag` or `hufftables`. `igzip_gs_writer_reset` clears the first three,
   re-points `level_buf`/`hufftables`, and zeroes the 64-bit totals.
8. A stateful level-0 finish ends one stored byte differently from the
   stateless path. Levels 1-3 are byte-identical. Both are valid deflate; the
   tests compare levels 1-3 and decode level 0.
9. A gzip custom header's `name` and `comment` must be NUL-terminated on the
   wire. ISA-L uses `strnlen` and does **not** add a terminator when the buffer
   length ends exactly at the name. `write_gzip_header` builds NUL-terminated
   copies in Goose and the shim checks the contract; passing a raw slice would
   silently omit the terminator.

Nothing from libdeflate belongs here, ever.

## Memory safety notes

- **The output bound is load-bearing.** `compress` lets igzip write straight
  into the destination and passes `bound(n)` as the limit. If that bound is ever
  too small, igzip writes past the end of the data stack. `make stress` allocates
  the bound *exactly*, compresses incompressible and adversarial inputs at every
  level and wrapper, and runs under AddressSanitizer; it is the reason the margin
  can be trusted. Re-run it after any change to `ISAL_BOUND_MARGIN`, the shim's
  buffers, or the ISA-L version.
- **A table is untrusted input.** `HuffTables` is a raw mirror of
  `struct isal_hufftables`, and igzip reads a length out of it: `write_header`
  indexes `deflate_hdr[deflate_hdr_count]` and memcpy's `deflate_hdr_count` bytes
  from the 328-byte header array (`igzip/igzip.c`). A fabricated table, or one
  deserialized from a cache file or the network, with a count past that array
  makes igzip read past the value and copy what it finds into the compressed
  output. `compress` validates `deflate_hdr_count` and `deflate_hdr_extra_bits`
  before any table reaches igzip and returns `Status.BadTable` instead. Anything
  that adds a path to a table — loading one from disk, accepting one over the
  wire — must go through that check.
- **igzip does not write through its input pointer.** `isal_deflate_stateless`
  and `isal_update_histogram` take `uint8_t *`, and the shim passes a
  `const u8[:]` by casting away const. This was checked in the vendored sources:
  neither writes through `next_in` / `start_stream`. Re-check if you add a call
  that takes an input pointer.
- **No globals, no mutable statics** in the shim, which is why two compressors in
  two threads share nothing and `igzip.build` does not declare
  `main_thread_only`. `test/threads.goose` exercises that with four workers.
- **Nothing borrowed outlives a call.** `next_in` and `next_out` are cleared
  before returning. In a `Compressor`, `hufftables` is cleared too; a `Writer`
  deliberately keeps `level_buf` and `hufftables` pointing into its own fields,
  and `pinned_self` rejects the copy that would invalidate them.
- **A live Writer copy is rejected.** The C stream's `level_buf` and
  `hufftables` point into the Writer value. Since Goose copies fixed-size values
  silently, the shim stores the Writer's address in `pinned_self` on first use
  and returns `BadState` when a later call arrives at a different address. A
  copy is recoverable with `reset`, which reinitializes the copied stream.
- **The header path has two sizes.** A header that fits in `chunk` is written
  there and appended. A larger one is first measured (`isal_write_gzip_header`
  returns the required size without touching the stream), then built in a
  temporary builder of exactly that size and appended. The temporary is created
  after the header views, because growing an array that a header slice may view
  is not legal Goose.

## FFI review gates

The boundary is `src/igzip_shim.c`; check these on every change that touches it.

1. **Borrowed memory dies with the call**, and is cleared afterwards. The
   `Writer` is the exception that is not an exception: it owns its state, and
   only the pointers *into* that state are stored (`level_buf`, `tables`), then
   re-established by `pinned_self`.
2. **`const` follows the C.** An `extern fn` parameter is not generic over
   constness: read-only parameters must say `const` (`const u8[:]`,
   `const Trainer&`, `const HuffTables&`), or callers cannot pass read-only
   views.
3. **Alignment.** The state blobs are `u64[...]`, so 8-byte aligned;
   `_Static_assert(_Alignof(...) <= 8)` guards each C struct cast out of them.
4. **Slices, not `(ptr, len)`.** Our own C is an adapter, so a `const u8[:]`
   crosses directly as `{data, len}`. The one C-string case is a custom gzip
   header's `name`/`comment`: the Goose wrapper appends the NUL and passes a
   length that includes it, so the shim never needs `ffi::cstr`.
5. **No variadics, no callbacks, no statics.**
6. **Build shape.** Native code is the CMake target `igzip_goose`; ISA-L comes
   from the submodule. No `c_libs`, no `extern "isal"` block, no system install.

## Goose pitfalls this code has hit

- `in` is a keyword (`for x in xs`, `u32 in a`). Parameter names: `src`, `out`.
- Struct **fields are comma-separated**. A missing comma reports
  `expected '}' in struct declaration` and points at the field name.
- A struct field's type must be **declared before** the struct that uses it.
  Functions are order-independent; struct fields are not.
- Fixed-size values copy silently. `let x = y` on a struct is a copy; use `.=`
  to bind a reference when you mean the same value.
- `let` stops reassignment, not mutation. Use `var` for anything retargeted.
- No `$` sigils, no `?`, no tuples, no named arguments: `T?`, trailing `bool`,
  `return E from f`.
- `out.resize` while a struct with slice fields is still live is rejected if
  its views may point into `out`. Build large headers in a fresh temporary
  instead of resizing the caller's builder.
- An enum with no payload is one byte. Store `Wrapper` and `WriterState`
  directly; casting an `i32` to an enum is not allowed.

## Conventions

- Public functions live in `igzip.goose`, documented above the declaration with
  *why*, not *what*.
- `Status` is the only failure channel. Every C call goes through `status_of`;
  igzip's negative codes never escape.
- Validate in Goose when the check is about the API contract (level range, input
  size); validate in C when it is about pointers or sizes.
- Tests assert; they do not print and hope. `test/contract.goose` keeps the
  assertions and exports the artifacts `scripts/check_gzip.py` inflates, so a
  new case needs no Python change.
- `goose format` decides layout. `make fmt-check` before calling work done.

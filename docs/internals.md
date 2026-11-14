# Internals

How the package is put together, and the invariants that are not obvious from
reading a single file. [README.md](../README.md) and
[guide.md](guide.md) are for people *using* the package;
[coverage.md](coverage.md) says what igzip can do and what this package does with
it; [verification.md](verification.md) says what the tests prove. This file is
for people *changing* the package.

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
state is the bytes of the `Compressor`, `Writer`, `Reader` and `Trainer` values
Goose declared; `Histogram` and `HuffTables` are plain fixed-size values the
caller owns. No `malloc`, no `free`, no `open`/`close`, no handle that can leak.
Adding any of those needs a reason that survives review.

Consequences that follow, and that repeatedly bite:

- A `Compressor` passed **by value is a ~300 KB copy**, a `Writer` ~367 KB, a
  `Reader` ~153 KB, and a `Trainer` 19 KB. Functions that write take them by
  reference. `HuffTables` and `Histogram` are small enough to pass and copy
  freely.
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
   stateless path. Levels 1-3 are byte-identical, measured on a chunked
   `isal_deflate` loop against `isal_deflate_stateless` (120,233 bytes in,
   8,045 out, `memcmp` equal). Both level-0 spellings are valid deflate; the
   tests compare levels 1-3 and decode level 0.
9. A gzip custom header's `name` and `comment` must be NUL-terminated on the
   wire. ISA-L uses `strnlen` and does **not** add a terminator when the buffer
   length ends exactly at the name. `write_gzip_header` builds NUL-terminated
   copies in Goose and the shim checks the contract; passing a raw slice would
   silently omit the terminator.

10. **Inflate reports completion in a block state, not a return code.**
    `isal_inflate` folds `ISAL_END_INPUT` into `ISAL_DECOMP_OK`, so "ran out of
    input" and "decoded a whole member" are the same return value. `finished`
    reads `block_state == ISAL_BLOCK_FINISH`, and that is why `finish` exists: a
    caller that never asks cannot tell a complete stream from a truncated one.
11. **`ISAL_BLOCK_FINISH` implies the staging buffer is empty.** Measured over
    200,000 one-byte-output calls: igzip only sets `FINISH` when
    `tmp_out_valid == tmp_out_processed` (`igzip_inflate.c` ~2433), so nothing
    can be held back at a member boundary and `finish` needs no output buffer.
    The case that *does* leave bytes staged is the caller's destination filling
    up, and `isal_inflate` with `avail_in == 0` copies them out on the next call
    (measured: 4,053 bytes in one call). `read` never gets there — its
    destination is the whole 64 KiB chunk and it loops until nothing is left —
    so the empty-source drain matters to a caller driving
    `igzip_gs_reader_step` directly, and is a documented no-op otherwise.
12. **The two families collide on return codes.** Inflate uses `-1` for
    `ISAL_INVALID_BLOCK` and `-3` for `ISAL_INVALID_LOOKBACK`, which the deflate
    status table reads as `STATELESS_OVERFLOW` and `ISAL_INVALID_STATE`. Worse,
    ISA-L itself defines `ISAL_INVALID_STATE == ISAL_INVALID_LOOKBACK == -3`, so
    the same number means different things on different calls. `reader_status`
    translates the inflate family into `IGZIP_GS_*` codes in `-11..-15`, and
    `isal_inflate_set_dict`'s `-3` is read as `BadState` where it is called.
    One `status_of` table then serves both families. Both tables are keyed on
    numbers ISA-L owns, so every one of them is `_Static_assert`ed in the shim:
    a renumbering there would otherwise turn `BadChecksum` into `BadState`, or
    a zlib stream into a raw one, without failing to compile anywhere.
13. **`isal_inflate_stateless` is honest about `avail_out`.** Unlike
    `isal_deflate_stateless` (behaviour 4), a destination one byte short returns
    `ISAL_OUT_OVERFLOW` having written exactly `dst.len` bytes, and an exact-size
    destination returns `ISAL_DECOMP_OK`. `scripts/read_stress.c` pins it. It
    also does **not** call `isal_inflate_reset`: it clears a subset of fields
    inline and leaves `tmp_out_processed`/`tmp_out_valid` alone, which is why the
    stateless verb refuses a Reader that holds a dictionary instead of relying
    on an undocumented side effect.
14. **`isal_inflate_set_dict` may be called in two places**, guarded by
    `block_state == ISAL_BLOCK_NEW_HDR && tmp_out_processed == tmp_out_valid` —
    before any input, and immediately after `ISAL_NEED_DICT` (the zlib FDICT
    path, where igzip has re-entered `NEW_HDR`). It copies at most the last
    `IGZIP_HIST_SIZE` bytes and never looks at `total_out`. A zlib member with
    FDICT reports `ISAL_NEED_DICT` **even when the dictionary is already set**,
    because parsing the header is what notices; the shim decodes on in that case
    rather than making every caller learn the sequence.
15. **`dict_id` and `dict_length` are inert.** `igzip_inflate.c` stores
    `dict_id` from the zlib header and never compares it to the dictionary
    (2114 / 2257), and `dict_length` is written by the setter and both resets and
    read by nothing. The dictionary works purely as `tmp_out_buffer` history, so
    a wrong one is caught only by a gzip/zlib trailer. On `Wrapper.Raw` there is
    no trailer and nothing catches it: wrong bytes and no error. That is
    documented on `set_dict` and pinned by a test.
16. **A gzip or zlib header is parsed in Goose, not by ISA-L.** `read_gzip_header`
    and `read_zlib_header` walk the container themselves over a `const u8[:]` and
    report *offsets* into it. `isal_read_gzip_header` would have been the
    alternative, but it copies the name, comment and extra field into
    caller-provided buffers, which means either a 65 KiB temporary or a caller
    who has to size three builders to read four numbers. Parsing over a slice has
    no pointers to get wrong, and every length in the header is a claim checked
    against the bytes present before it is used. The decoder is the authority on
    where the body starts, which is what makes `body_at` testable: the bytes from
    it decode as a standalone raw stream.
17. **Header CRCs are reported, not verified, and checksums are not exposed.**
    `isal_inflate` steps over FHCRC, so verifying it in `read_gzip_header` and
    not in the decoder would make the package disagree with itself. And while
    igzip uses `isal_adler32` (zlib DICTID, trailer) and `crc32_gzip_refl`
    (gzip trailer) internally, neither is part of this package's surface: a
    caller who wants a CRC has a library for it, and one who wants to know
    whether a stream is intact asks the `Reader`, which already answers
    `BadChecksum`. [coverage.md](coverage.md) records the boundary.
18. **`isal_inflate_reset` keeps `crc_flag` and `hist_bits`** and clears
    `wrapper_flag`, `dict_length`, `tmp_in_*`, `tmp_out_*`, the overflow cursors
    and `total_out`. Keeping `crc_flag` is what makes the next concatenated
    member's trailer still checked; `igzip_gs_reader_reset` rewrites it anyway so
    the invariant is local.

### Streaming surface: what is exposed

| ISA-L facility | Goose surface |
|---|---|
| `isal_deflate_init` / `isal_deflate` / `isal_deflate_reset` | `Writer`; `write`, `flush`, `finish`, `reset` |
| `NO_FLUSH`, `SYNC_FLUSH`, `FULL_FLUSH`, `end_of_stream` | `write`, `flush(Sync|Full)`, `finish` |
| `isal_deflate_set_dict` | `set_dict` (Fresh only; the dictionary is copied) |
| `isal_deflate_set_hufftables` (custom/default) | `set_tables` / `clear_tables` |
| `isal_write_gzip_header` / `isal_gzip_header_init` | `GzipHeader` / `write_gzip_header` |
| `isal_write_zlib_header` / `isal_zlib_header_init` | `ZlibHeader` / `write_zlib_header` |
| `IGZIP_GZIP`, `IGZIP_GZIP_NO_HDR`, `IGZIP_ZLIB`, `IGZIP_ZLIB_NO_HDR`, `IGZIP_DEFLATE` | `Wrapper` plus the explicit-header paths |
| `isal_zstream.hist_bits` | `ZlibHeader.window_bits`; raw/gzip use the format default |
| output staging and `avail_out` | the `Writer`'s 64 KiB `chunk`, drained by `write`/`flush`/`finish` |
| `isal_inflate_init` / `isal_inflate` / `isal_inflate_reset` | `Reader`; `read`, `finished`, `finish`, `reset` |
| `isal_inflate_stateless` | `inflate` (into a caller-sized slice) and, via the streaming loop, `inflated` |
| `isal_inflate_set_dict` | `set_dict` (Fresh, or immediately after `NeedDict`) |
| `isal_read_gzip_header` / `isal_read_zlib_header` | `read_gzip_header` / `read_zlib_header`, parsed in Goose over a slice and returning offsets rather than copies |
| `ISAL_BLOCK_FINISH` | `finished(r)` |
| input staging and `avail_out` | the `Reader`'s 64 KiB `chunk`, drained by `read` |

Deliberately not exposed in 0.3, with the reason:

- **`IGZIP_HUFFTABLE_STATIC`** — a table choice, not a streaming operation.
  Trained and default tables are the package's supported policy; this is an
  additive `set_static_tables` if a caller needs it.
- **`isal_deflate_process_dict` / `isal_deflate_reset_dict`** — a
  preprocessed-dictionary cache. `set_dict` covers correctness; the cache is a
  performance feature for a fixed dictionary and can be added additively.
- **`isal_deflate_set_dict` after a flush** — legal in ISA-L for raw streams,
  but zlib's FDICT header cannot be retrofitted, so the Goose API keeps the
  dictionary to `Fresh`.
- **`level_buf_size` / a caller-chosen level buffer** — the value carries
  `ISAL_DEF_LVL3_MEDIUM` (217,088 bytes), which satisfies levels 1-3 and is
  pinned by the layout. A smaller buffer would change the `Writer` size and
  compression decisions; it is not a 0.2 knob.
- **`isal_read_gzip_header` / `isal_read_zlib_header`** — header *inspection*
  (mtime, name, comment) is a different feature from decoding, and additive
  later. The wrappers already validate what a reader must validate.
- **`isal_inflate_stateless` with a dictionary** — ISA-L documents it as
  dictionary-free; the reader refuses a dictionary-holding Reader rather than
  depend on the history buffer surviving its partial reset.
- **An expansion limit** — `read` plus `r.total_out` is a better one: a caller
  stops feeding input when its own cap is passed, instead of being aborted
  mid-member.
- **Checksums** (`crc32_gzip_refl`, `isal_adler32`, and the rest of `crc.h`).
  This package verifies checksums and does not compute them: igzip checks a
  trailer itself through `crc_flag`, and a caller who needs a CRC value has a
  library for it. [coverage.md](coverage.md) has the reasoning in full.
- **`isal_create_hufftables_subset`, `isal_deflate_process_dict` /
  `isal_deflate_reset_dict`, `IGZIP_HUFFTABLE_STATIC`** — a table-policy knob, a
  dictionary cache, and a third table source. Each is additive and each is
  listed with its cost in [coverage.md](coverage.md).

The streaming values share `CHUNK_SIZE` and the `append_output` helper in
`igzip.goose`: output is staged in a fixed chunk and only the bytes produced are
appended. `Writer` and `Reader` share the lazy-init plus `pinned_self` copy
guard, and each family of C statuses has its own range — the deflate family at
`-8`/`-10`, inflate at `-11..-15` — so `status_of` stays one table.

The reader's phase rules are the part of 0.3 a caller can get wrong, so they are
a matrix in [design/0.3.0.md](design/0.3.0.md) §5 Q11 and asserted cell by cell
in `test/inflate_contract.goose`. Two rules hold it together: `read` never ends
a body (a member boundary is `finished(r)`, not a state change, so a caller that
stops feeding can resume), and a terminal error latches the Reader `Finished`,
because `isal_inflate` would otherwise answer `Ok` forever from a `FINISH` block
state.

The zlib `window_bits` field is not cosmetic: the shim also sets
`stream.hist_bits` to the same value before deflating. A 4 KiB window on the
header with a 32 KiB match history makes strict decoders reject the stream with
`invalid distance too far back`; `zlib.decompressobj(window_bits)` in the
checker is the regression test.

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
  before any table reaches igzip and returns `Status.BadTable` instead. The
  `Writer` validates in `igzip_gs_writer_step`, not only in `set_tables`: a
  deserialized `Writer` with `has_tables = true`, or a caller that mutates the
  public `tables` field, is checked at the use site. `clear_tables` remains
  available to drop a table that fails the check.
- **A `Reader` never reads or writes past its buffers.** The destination is the
  only limit on decompression, so `scripts/read_stress.c` decodes into buffers
  allocated to their exact size, from 1 byte to 64 KiB, at every truncation
  offset, through 400 mutations and the dictionary paths, under
  AddressSanitizer. It also pins the assumption the API rests on — stateless
  inflate is honest about `avail_out` — the one place this package trusts a
  behaviour `isal_deflate_stateless` does not have.
- **A truncated or corrupted stream is a `Status`, never a crash.** Truncation
  is `finished(r) == false`, which `finish` reports as `Truncated`; corruption is
  `Corrupt`, `BadChecksum` or `BadWrapper`, and each latches. A payload mutation
  can also leave the member merely unfinished — igzip cannot tell "not yet" from
  "not ever" — which is why a caller must call `finish` rather than only watch
  for errors.
- **A deserialized `Writer` is not trusted either.** A `Fresh` Writer whose
  `pinned_self` is zero but which carries `has_dict` or `hdr_written` has no C
  dictionary/header behind those flags; `writer_pin` returns `BadState` and
  `reset` clears it. A Writer in `Open`, `Flushed` or `Finished` with no pinned
  address is similarly refused. Only the `tables` bytes are self-contained, and
  they are validated at use.
- **Header temporaries are bounded.** RFC 1952 bounds `extra` at 65,535 bytes
  but not `name`/`comment`. A header that does not fit the 64 KiB chunk is built
  in a temporary of the measured size; `MAX_HEADER` (1 MiB) caps that
  allocation, so an untrusted long name is `BadHeader` rather than an unbounded
  allocation.
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
- **A live Reader copy is rejected too**, for a different reason: no pointer into
  Goose memory survives a reader call, so the copy is memory-safe, but both
  copies would decode from the same position and emit the same bytes twice. One
  rule for stateful values, and `reset` recovers the copy. A `Fresh` Reader
  carrying `has_dict` with no pinned address is refused as deserialized or
  forged: the history the flag names was never copied in.
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

## Editors

`goose lsp` serves diagnostics, hover, go-to-definition, rename, completion and
formatting over stdio. It analyses the programs its client lists as entry files
(`initializationOptions.entryFiles`) plus any open file none of them imports, and
it fetches nothing.

This repository is one package plus eleven other root programs, so a client that
knows only the package sees the package and whichever test is open. List them
all: `igzip.goose`, the eight `test/*.goose` roots, and the three
`examples/*.goose` roots. `test/support/support.goose` is a module, not a root;
it is analysed because the test roots import it.

Every root file typechecks under `goose check`, which is the same analysis the
server runs; `make check` covers the package and `make test` the tests.

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
- An enum with no payload is one byte. Store `Wrapper`, `WriterState` and
  `ReaderState` directly; casting an `i32` to an enum is not allowed.
- `resize` on a builder needs a fill value (`dst.resize(n, 0)`); there is no
  zero-initializing overload for `u8[>..]`.
- A multiple return has to be taken whole: `let used, ok = r.read(..)`. Binding
  only the first value leaves the second name referring to the count, and the
  mistake surfaces later as a nonsense comparison rather than at the binding.
- A status is out of band: `if !call { ... igzip::error() ... }`, and
  `igzip::status()` narrowed by `if` before a `match`.

## Conventions

- Public functions live in `igzip.goose`, documented above the declaration with
  *why*, not *what*. `igzip.goose` is ordered the way a reader meets it:
  compressor, writer, reader, headers, training, diagnostics.
- Prose that explains *how to use* the package belongs in `docs/guide.md`; the
  README is a front page and the API tables. A behaviour that a maintainer must
  not undo belongs here.
- `Status` is the only failure channel. Every C call goes through `record`,
  which stores its code for `status()`/`error()` and returns the call's bool;
  igzip's negative codes never escape. `status_of` and `status_code` are the
  inverse pair that names a code and finds it again, and both are
  compiler-exhaustive over the enum.
- **One piece of mutable state, per thread.** `src/igzip_shim.c` keeps
  `_Thread_local int32_t gs_last_status`, written by every fallible call
  (zero on success, so `status()` is null exactly when the bool was true) and
  read only by `status()` / `error()`. It is the one exception to "no mutable
  statics", it is per thread so two workers stay independent, and it means the
  reason belongs to the *call*, not to the value: a caller that wants a
  `Reader`'s failure to travel with it must ask immediately.
- Validate in Goose when the check is about the API contract (level range, input
  size); validate in C when it is about pointers or sizes.
- Tests assert; they do not print and hope. `test/contract.goose` keeps the
  assertions and exports the artifacts `scripts/check_gzip.py` inflates, so a
  new case needs no Python change.
- `goose format` decides layout. `make fmt-check` before calling work done.

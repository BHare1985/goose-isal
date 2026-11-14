# goose-igzip

Goose bindings for Intel ISA-L's **igzip**: one-shot and streaming deflate in
raw, gzip and zlib wrappers, plus trained Huffman tables.

Everything a caller touches is a Goose value, so the owning scope is the free —
no C memory to release and no handle to close. Failures are a typed `Status`,
and levels, sizes and tables are validated before igzip sees them. ISA-L is
vendored, pinned and built by the package; nothing is installed system-wide.

**v0.2.0** adds the streaming half: a `Writer` that keeps one deflate stream
open across calls, custom gzip/zlib headers, preset dictionaries, and inputs
past the one-shot 2 GiB limit.

[Quick start](#quick-start) · [Install](#install-and-build) · [API](#api) ·
[Training](#training) · [Verification](#verification) ·
[How it works](#how-it-works) · [Layout](#layout)

## Quick start

A compressor is a value you make once and keep:

```goose
import std;
import igzip;

fn main() {
    var c = igzip::gzip_compressor(1);          // keep one per thread
    let gz, err = c.compressed(body);           // fresh buffer in your destination
    guard err.ok() else { abort(igzip::status_name(err)); };
}
```

A writer does the same one member at a time:

```goose
var w = igzip::gzip_writer(1);
var out: u8[>..] = [];

guard w.write(chunk_a, out).ok() else { abort("write failed"); };
guard w.flush(out).ok() else { abort("flush failed"); };   // Sync decode point
guard w.write(chunk_b, out).ok() else { abort("write failed"); };
guard w.finish(out).ok() else { abort("finish failed"); };  // trailer

w.reset();                                                  // next response
```

`Compressor` is 299,472 bytes; `Writer` is 367,280. Both are freed by scope, so
a server keeps one per thread and shares nothing between them.

## Install and build

ISA-L is a **pinned submodule** at `vendor/isa-l` (release `v2.32.1`, pinned by
commit) and is built from source by this package's `CMakeLists.txt`. There is no
`libisal-dev` to install, no `.so` to find at run time, and no way for the
headers and the library to disagree: `igzip::version` reads the release the
tests link against. [docs/internals.md](docs/internals.md) records the exact
commit and the bump procedure.

The native build needs git (for the submodule), cmake, `nasm` and a C compiler.
`nasm` is not optional in practice: without it ISA-L falls back to portable C
and loses the kernels that are the reason to use ISA-L.

```bash
make tools          # compiler version, ISA-L tag, nasm, cmake
make check          # typecheck the package; silent on success
make test           # Goose tests, then inflate every stream they wrote
make test-threads   # worker-pool test (needs a native build)
make test-large     # 4.2 GiB through one Writer (native)
make stress         # AddressSanitizer output-bound and avail_out checks
make verify         # check + all tests + examples
make bench          # native throughput benchmark
make fmt            # layout is goose format's decision, not yours
```

## API

Every function takes the value first, so the method form works: `c.compress(..)`
is `igzip::compress(c, ..)`.

### Values

| Value | Bytes | What it is |
|---|---:|---|
| `Compressor` | 299,472 | one-shot deflate state; no stream to finish |
| `Writer` | 367,280 | streaming state + a 64 KiB output chunk |
| `Trainer` | 18,912 | histogram, counters and match scratch |
| `Histogram` | 2,528 | just the counters, for caching many content types |
| `HuffTables` | 2,232 | one complete Huffman table |

### One-shot

| Call | Meaning |
|---|---|
| `gzip_compressor(level = 1)` | also `zlib_compressor`, `raw_compressor`, `compressor(wrap, level)` |
| `c.compressed(src)` → `u8[>..], Status` | one member, in a new buffer built in your destination |
| `c.compress(src, out)` → `Status` | one member, appended to a buffer you already own |
| `c.set_tables(t)` / `c.clear_tables(level = 1)` | attach a trained table (pins level 0) / drop it |
| `gzip(src, level = 1)` | one-shot convenience; declares its own compressor |

```goose
var c = igzip::gzip_compressor(1);

let gz, err = c.compressed(body);      // you have nowhere to put the bytes yet

var out: u8[>..] = [];                 // or you own the buffer and reuse it
c.compress(body_a, out);
c.compress(body_b, out);               // two members, back to back
```

### Streaming

| Call | Meaning |
|---|---|
| `gzip_writer(level = 1)` | also `zlib_writer`, `raw_writer`, `writer(wrap, level)` |
| `w.write(src, out)` → `Status` | append the compressed bytes for `src`; consumes all of it |
| `w.flush(out)` / `w.flush(mode, out)` → `Status` | `Sync` (default) or `Full` decode point |
| `w.finish(out)` → `Status` | final block and trailer; the writer is `Finished` |
| `w.reset()` → `Status` | back to `Fresh`, keeping wrapper, base level and trained table |
| `w.write_gzip_header(hdr, out)` / `w.write_zlib_header(hdr, out)` | custom header before the first body byte |
| `w.set_dict(dict)` → `Status` | preset dictionary, raw and zlib only |
| `w.set_tables(t)` / `w.clear_tables()` → `Status` | attach (pins level 0) / drop a trained table |
| `w.write_windowed(src, out, step)` | `write` with an explicit input window |
| `w.total_in`, `w.total_out`, `w.state` | bytes consumed, bytes produced, lifecycle state |

The lifecycle is `Fresh → HeaderWritten → Open → Flushed → Finished`, with
`reset` returning to `Fresh`. Writing after `finish`, writing a header after the
first body byte, or swapping a table while a block is open returns
`Status.BadState` rather than silently resetting or corrupting the stream.

`Writer` stages igzip's output through its own 64 KiB chunk and appends only the
bytes produced, so callers never loop over `avail_out`. `write` splits inputs
above 2 GiB into windows and consumes all of them; `MAX_INPUT` no longer applies
to a whole stream.

A fixed-size Goose value can be copied by assignment. A copy of an initialized
`Writer` would share the C pointers into the original's `level_buf` or table, so
the shim records the writer's address and returns `BadState` for such a copy.
`reset` makes the copy independent.

### Headers

`GzipHeader` and `ZlibHeader` are written explicitly, before the first `write`,
`flush` or `finish`:

```goose
var w = igzip::gzip_writer(1);
var out: u8[>..] = [];
let hdr = igzip::GzipHeader { os: 3, name: "report.csv", mtime: 0 };

guard w.write_gzip_header(hdr, out).ok() else { abort("header failed"); };
guard w.write(body, out).ok() else { abort("write failed"); };
guard w.finish(out).ok() else { abort("finish failed"); };
```

`mtime` defaults to 0 and `os` to 0xff, so a header left alone is reproducible.
RFC 1952 wants `name` and `comment` NUL-terminated; the wrapper adds the
terminator. An interior NUL or an `extra` field longer than 65,535 bytes is
`Status.BadHeader`. A header larger than the 64 KiB chunk is still supported: it
is built in a temporary of the measured required size and appended.

`ZlibHeader` exposes `window_bits` (8–15) and `flevel` (0–3). The zlib CMF/FLG
fields carry both.

### Dictionaries

```goose
var wz = igzip::zlib_writer(1);
guard wz.set_dict(dictionary).ok() else { abort("dictionary failed"); };
guard wz.write(payload, out).ok() else { abort("write failed"); };
guard wz.finish(out).ok() else { abort("finish failed"); };
```

A zlib stream with a dictionary advertises FDICT and DICTID automatically.
igzip's plain `IGZIP_ZLIB` header does not, and a standard decoder would reject
the stream, so the shim emits the six-byte header itself. Calling
`write_zlib_header` after `set_dict` also forces the flag; an explicit mismatch
is `BadHeader`. gzip has no preset-dictionary header, so `set_dict` on a gzip
writer is `BadState`.

igzip copies at most the last 32 KiB of the dictionary into its own history
buffer, so the slice need not outlive the call. zlib's DICTID is Adler-32 over
the whole dictionary.

### Training

Level 0 is the only level that uses a table you supply — levels 1–3 build their
own per block. It is also the fast path, so a trained table buys speed *and*
ratio on text of the trained kind.

```goose
var c = igzip::gzip_compressor(1);
var t = igzip::trainer();

// Sample bodies of this content type as they go by.
t.add(json_body);
guard t.symbols() >= 64 * 1024 else { /* keep warming */ };

let tables, built = t.build();
guard built.ok() else { abort(igzip::status_name(built)); };

c.set_tables(tables);                  // level 0 from here on
let gz, err = c.compressed(next_json_body);
guard err.ok() else { /* fall back to the default tables */ };
```

On a `Writer`, `set_tables` is legal before the first byte and after a completed
`Sync` or `Full` flush. `reset` keeps the table; `clear_tables` returns to the
writer's base level.

### Diagnostics

`Status` is `Ok`, seven named failures, and `Other`; `status_name` renders them.
Nothing aborts on bad input.

A `Status` is not a condition — Goose takes a `bool` or an optional — so the
common case is `guard err.ok() else { ... }`, and a specific failure is
`err == igzip::Status.BadTable`.

| Diagnostic | Meaning |
|---|---|
| `version(out)` | ISA-L release, read from its headers |
| `bound(n)` | upper bound on compressed size, for sizing a destination |
| `compressor_size()`, `writer_size()`, `trainer_size()` | the pinned value sizes |
| `MAX_INPUT` | one-shot input limit, 0x7FFFFFF0 bytes |
| `MAX_IN_STEP` | `write`'s input window, the same 32-bit limit |

## Why trained tables

Level 0 is igzip's fast path — 3–4x the throughput of level 1 on a few-kilobyte
response, 1.6x on a 9 KB one. It pays for that in bytes: untrained, it
compresses an API response ~40% worse than level 1, and on bodies under a few
hundred bytes it can expand them. Train one table per content type and keep
level 1's ratio at level 0's speed:

| event-log API, 1.9 KB responses | ratio | µs/response |
|---|---|---|
| level 1 | 34.0% | 12 |
| level 3 | 34.1% | 18 |
| level 0, default table | 46.6% | 3 |
| **level 0, trained table** | **35.5%** | **3** |

At 9.4 KB per response: 20.5% at 19 µs for level 1, **20.8% at 11 µs** for the
trained table. Same bytes out, 3.8x and 1.6x less time in.
`examples/bench.goose` reproduces it on your own data.

## Verification

`make verify` proves the following, and nothing here is claimed without it.

**One-shot** (`test/contract.goose`): layouts match the C `sizeof`s; every level
and wrapper stays inside `bound(n)`; invalid levels, oversized inputs and
fabricated tables are rejected before igzip sees them; two runs are identical;
trained tables beat level 0's default; counts round-trip to a bit-identical
table; empty input is a valid 20-byte member.

**Writer state and edges** (`test/writer_contract.goose`): state transitions and
64-bit totals; legal and illegal `set_tables`/`set_dict` ordering; copies after a
write, a header, `finish`, `set_dict` or `set_tables`; reset from `Open`,
`Flushed` and `Finished`; custom, large and default gzip headers; name/comment
NUL rejection; the 65,535-byte extra boundary; zlib window/FLEVEL; dictionary
FDICT/DICTID and matching/mismatched IDs; trained tables, mid-flush swaps and
`clear_tables`; invalid levels and tables.

**Streaming end-to-end** (`test/streaming.goose`): one-shot equivalence at
levels 1–3 for every wrapper from 32 KiB to 316 KiB; chunked writes at 1, 7, 63,
4,096 and 70,000 bytes; 1 MiB in 64 KiB windows; `Sync`/`Full` decode points;
two flushes in a row; a 4 MiB incompressible stream that crosses the output
chunk. Level 0 is decoded rather than compared, for the ISA-L reason below.

**Large input** (`test/large_stream.goose`): one writer fed 4.2 GiB in 1 MiB
pieces, checking the 64-bit total and the wrapped 32-bit gzip ISIZE without
holding the stream.

**Independent decode** (`scripts/check_gzip.py`): **42 streams** are inflated
with CPython's zlib and compared byte for byte — every wrapper and level, sizes
on deflate's block seams, deterministic repeats, concatenated members,
incompressible noise, trained and trained-on-half streams, the empty member,
chunked/default/level-0 streams, both flush points, the trained-table flush swap,
custom and large headers, the zlib header, dictionary streams with `zdict`, and
the 4 MiB stream. It also checks `mtime = 0` where promised, parses header
fields, and checks FDICT/DICTID.

**Memory safety** (`make stress`): `scripts/bound_stress.c` allocates `bound(n)`
*exactly* and compresses adversarial inputs at every level and wrapper under
AddressSanitizer, then drives the stateful path with output slices as small as 8
bytes and writes gzip headers into exact-size and one-byte-short buffers — 600
cases, no overrun.

**Threading** (`test/threads.goose`): four compressor workers and two streaming
workers, each with its own value; two workers compressing the same input must
agree on the size.

One ISA-L quirk: at level 0 the stateful path ends a stream one stored byte
differently from the stateless path. Levels 1–3 are byte-identical; level 0
emits a valid stream of its own.

```
[ok]   determinism           two runs gave identical bytes
[ok]   ratio vs zlib l1          2113 bytes vs 2219
[ok]   ratio vs zlib l9          1887 bytes vs 1868
[ok]   matrix/gzip_0.gz          3095 bytes    9.9% of 31364
[ok]   matrix/gzip_1.gz          2113 bytes    6.7% of 31364
[ok]   matrix/gzip_3.gz          1887 bytes    6.0% of 31364
[ok]   trained.gz                2135 bytes    6.8% of 31364
[ok]   trained table saves 960 bytes over the level 0 default
42/42 streams valid
4 workers, 16 jobs, 2977 bytes for 425 records
4200 MiB, ISIZE 109051904, total_in 4404019200
```

## How it works

**C owns no memory.** Goose has no heap, so the binding has none: `malloc`
appears nowhere in `src/igzip_shim.c`. The 82 KB `isal_zstream` and its level
buffer are the bytes of a `Compressor` or a `Writer`; the histogram, counters
and match scratch are the bytes of a `Trainer`. Compressed bytes are written
straight into the destination builder's stack top (or a writer's 64 KiB chunk)
and only the bytes written are claimed, which is the contract `goose.h`
documents for C appending to a builder.

**Layouts are pinned.** Those values mirror C structs whose sizes and offsets
are asserted in the shim, so an ISA-L upgrade that changes a layout fails the
build instead of corrupting memory. The size functions let the tests assert the
same thing at run time.

**Errors are typed.** C's negative status codes become `Status`; levels, input
lengths, header fields and tables are validated before igzip sees them.

**Nothing borrowed outlives a call.** `next_in` and `next_out` are cleared
before returning. A `Writer` keeps `level_buf` and a custom table pointer
pointing into its own fields, which is why an initialized copy is rejected.

## Layout

```
igzip.goose              the package: types, extern declarations, public API
igzip.build              native part: names the CMake target "igzip_goose"
CMakeLists.txt           builds the shim and ISA-L from vendor/isa-l
vendor/isa-l             pinned submodule, v2.32.1 (not installed anywhere)
src/igzip_shim.c          the C side; owns no memory
test/contract.goose      one-shot contract tests
test/writer_contract.goose  Writer state, headers, dictionaries, tables
test/streaming.goose     end-to-end streaming, chunking, flush and windows
test/support/support.goose  shared corpus/body/noise generators
test/threads.goose       compressor and streaming workers (native)
test/large_stream.goose  4.2 GiB through one Writer (native)
examples/                gzip_file, trained_table, bench
scripts/check_gzip.py    inflates every stream the tests wrote
scripts/bound_stress.c   proves the output bound and avail_out as exact sizes
ROADMAP.md               igzip coverage plan and the measurements behind the API
CHANGELOG.md             what each release added
docs/internals.md        maintainer docs: pin, memory model, security, FFI gates
AGENTS.md                short agent hook pointing at docs/internals.md
```

## Contributing

[`docs/internals.md`](docs/internals.md) has the parts that are not obvious from
reading one file: the submodule pin and how to bump it, the memory model, the
igzip behaviours the API encodes, the security notes, and the FFI review gates.

Four invariants hold across the package; a change that breaks one needs a
better reason than convenience.

1. **C owns no memory.** State lives in `Compressor`, `Writer` and `Trainer`
   values, so the owning scope is the free. No `malloc`, no `free`, no handle.
2. **Errors are typed.** C's negative status codes become `Status`; nothing
   aborts on bad input, and levels, sizes, headers and tables are checked first.
3. **Layouts are pinned.** Mirrored struct sizes and offsets are asserted in
   `src/igzip_shim.c`, and the tests compare them with the declarations.
4. **The build is self-contained.** ISA-L comes from `vendor/isa-l` via
   `CMakeLists.txt`. Never add `c_libs`, an `extern "isal"` block, or a
   dependency on an installed ISA-L.

```bash
make check     # after every edit; silent on success
make verify    # check + all tests + examples
make stress    # the output bound, as an exact buffer size, under ASan
make fmt       # layout is goose format's decision, not yours
```

`make test` inflates every stream the tests wrote, because "it returned Ok" is
not evidence that the bytes are a valid gzip stream.

## Importing

```goose
import igzip from "BHare1985/goose-igzip@v0.2.0";
```

Goose fetches the repo and its submodule. Until a tag exists, use a commit or a
local path.

## License

BSD-3-Clause, see [LICENSE](LICENSE). ISA-L itself is vendored under
`vendor/isa-l` with its own BSD-3-Clause [license](vendor/isa-l/LICENSE).

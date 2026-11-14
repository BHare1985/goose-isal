# goose-igzip

**igzip — ISA-L's gzip — for Goose, with trained Huffman tables.**

Level 0 is igzip's fast path — 3-4x the throughput of level 1 on a few-kilobyte
response, 1.6x on a 9 KB one. It pays for that in bytes: untrained, it
compresses an API response ~40% worse than level 1 does, and on bodies under a
few hundred bytes it can expand them. Train one Huffman table per content type
and you keep level 1's ratio at level 0's speed:

| event-log API, 1.9 KB responses | ratio | µs/response |
|---|---|---|
| level 1 | 34.0% | 12 |
| level 3 | 34.1% | 18 |
| level 0, default table | 46.6% | 3 |
| **level 0, trained table** | **35.5%** | **3** |

At 9.4 KB per response: 20.5% at 19 µs for level 1, **20.8% at 11 µs** for the
trained table. That is the whole argument — same bytes out, 3.8x and 1.6x less
time in — and `examples/bench.goose` is the benchmark, reproducible on your own
data.

```goose
import std;
import igzip;

fn main() {
    var c = igzip::gzip_compressor(1);          // a compressor you keep
    let gz, err = c.compressed(body);
    guard err.ok() else { abort(igzip::status_name(err)); };
}
```

Everything a caller touches is a Goose value, so the owning scope is the free:
there is no C memory to release and no handle to close. Failures are a typed
`Status`, and the level, the input size and any trained table are validated
before igzip sees them. ISA-L is vendored and built by the package, so nothing
is installed system-wide.

**v0.1.0 is the deflate half** — every level, raw/gzip/zlib wrappers, and the
training path. Inflate and the checksums follow in [ROADMAP.md](ROADMAP.md) to
make the codec whole.

## Nothing to install

ISA-L is **vendored as a pinned submodule** — `vendor/isa-l` at release
`v2.32.1`, pinned by commit in the tree, so a force-pushed tag cannot change what
builds — and it is built from source by this package's `CMakeLists.txt`. No
`libisal-dev`, no `libisal.so` to find at run time, and no way for the headers
and the library to disagree: the release that is built is the release the tests
read back from `igzip::version`. [docs/internals.md](docs/internals.md) records
the exact commit and how to bump it.

The native part needs, on the machine that builds it:

```bash
git submodule update --init --depth 1 vendor/isa-l   # `make submodule`
cmake, nasm, a C compiler                            # nasm assembles ISA-L's kernels
```

```bash
make tools     # compiler version, ISA-L tag, nasm, cmake
make check     # typecheck the package
make test      # run the Goose tests, then inflate every stream they wrote
make test-threads  # build and run the worker-pool test (needs a native build)
make stress    # AddressSanitizer check that the output bound is exact
make verify    # check + test + test-threads + examples
make bench     # native build and throughput
```

`nasm` is not optional in practice: without it ISA-L falls back to portable C
and you lose the kernels that are the reason to use ISA-L at all.

## Using it

A compressor is a value you make once and keep. Every function takes it first,
so the method form works: `c.compress(..)` is `igzip::compress(c, ..)`.

| | |
|---|---|
| `gzip_compressor(level = 1)` | also `zlib_compressor`, `raw_compressor`, `compressor(wrap, level)` |
| `c.compressed(src)` → `u8[>..], Status` | one member, in a new buffer built in your destination |
| `c.compress(src, out)` → `Status` | one member, appended to a buffer you already own |
| `c.set_tables(t)` / `c.clear_tables(level = 1)` | attach a trained table (pins level 0) / drop it |
| `trainer()` → `Trainer` | the accumulator you count samples into |
| `t.add(body)` → `Status` | count one sample body |
| `t.symbols()` → `i64` | symbols counted so far |
| `t.build()` → `HuffTables, Status` | turn the counts into a table |
| `t.counts(h)` / `trainer_of(h)` | copy counts out / back in, 2.5 KB per content type |
| `gzip(src, level = 1)` | one-shot; declares its own compressor |
| `err.ok()` → `bool` | whether a call succeeded; a `Status` is not a condition in Goose |
| `version`, `bound`, `status_name`, `compressor_size`, `trainer_size`, `writer_size` | diagnostics |
| `MAX_INPUT` | the largest input accepted by the one-shot path, 0x7FFFFFF0 bytes (igzip's 32-bit lengths) |

`Wrapper` is `Raw`, `Gzip` or `Zlib`. `Status` is `Ok`, seven named failures,
and `Other`; `status_name` renders them. Nothing aborts on bad input.

A `Status` is not a condition — Goose takes a `bool` or an optional — so the
common case is `guard err.ok() else { ... }`, and a specific failure is
`err == igzip::Status.BadTable`.

The two compression forms differ only in where the bytes go, and neither
copies them:

```goose
var c = igzip::gzip_compressor(1);

let gz, err = c.compressed(body);      // you have nowhere to put the bytes yet

var out: u8[>..] = [];                 // or you own the buffer and reuse it
c.compress(body_a, out);
c.compress(body_b, out);               // two members, back to back
```

## Streaming

A `Writer` is the stateful half: it keeps one deflate stream open across calls,
so a body can be compressed as it is produced. It is a separate type rather
than a mode on `Compressor`, so a stateless user does not pay for the stream or
its 64 KiB staging buffer. `Writer` is 367,280 bytes — one per thread, like a
compressor.

| | |
|---|---|
| `gzip_writer(level = 1)` | also `zlib_writer`, `raw_writer`, `writer(wrap, level)` |
| `w.write(src, out)` → `Status` | append the compressed bytes for `src`; consumes all of it |
| `w.flush(out)` / `w.flush(mode, out)` → `Status` | `Sync` (default) or `Full` decode point |
| `w.finish(out)` → `Status` | final block and trailer; the writer is then `Finished` |
| `w.reset()` → `Status` | back to `Fresh`, keeping wrapper, base level and trained table |
| `w.write_gzip_header(hdr, out)` / `w.write_zlib_header(hdr, out)` | custom header before the first body byte |
| `w.set_dict(dict)` → `Status` | preset dictionary, raw and zlib only |
| `w.set_tables(t)` / `w.clear_tables()` → `Status` | attach (pins level 0) / drop a trained table |
| `w.write_windowed(src, out, step)` | `write` with an explicit input window; `write` uses `MAX_IN_STEP` |
| `w.total_in`, `w.total_out`, `w.state` | bytes consumed, bytes produced, lifecycle state |

```goose
var w = igzip::gzip_writer(1);
var out: u8[>..] = [];

guard w.write(chunk_a, out).ok() else { abort("write failed"); };
guard w.flush(out).ok() else { abort("flush failed"); };   // Sync: a decode point
guard w.write(chunk_b, out).ok() else { abort("write failed"); };
guard w.finish(out).ok() else { abort("finish failed"); };

w.reset();                                                // next response
```

`finish` writes the trailer automatically. A `Writer` stages igzip's output
through its own 64 KiB chunk and appends only the bytes produced, so callers
never loop over `avail_out`. `write` splits inputs above 2 GiB into windows and
consumes all of them; `MAX_INPUT` no longer applies to a whole stream.

The lifecycle is `Fresh → HeaderWritten → Open → Flushed → Finished`, with
`reset` returning to `Fresh`. Writing after `finish`, writing a header after the
first body byte, or swapping a table while a block is open returns
`Status.BadState` rather than silently resetting or corrupting the stream.

A fixed-size Goose value can be copied by assignment. A C pointer into the
original `level_buf` or table would then be shared, so the shim records the
writer's address and rejects a copy made after the writer has been initialized
(write, header, `set_dict` or `set_tables`) with `BadState`; `reset` makes the
copy independent.

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
terminator, and rejects an interior NUL or an `extra` field longer than 65,535
bytes with `Status.BadHeader`. A header larger than the 64 KiB chunk still
works: it is built in a temporary of the required size and appended.

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
writer is `BadState`. igzip copies at most the last 32 KiB of the dictionary
into its own history buffer, so the slice need not outlive the call.

`set_tables` has the same level-0 rule as `Compressor`: a supplied table is
used only at level 0, so attaching one pins the level. It is legal before the
first byte and after a completed `Sync` or `Full` flush. `reset` keeps the
table; `clear_tables` returns to the writer's base level.

One ISA-L quirk: at level 0 the stateful path ends a stream one stored byte
differently from the stateless path. Levels 1-3 are byte-identical to
`compressed`; level 0 emits a valid stream of its own. The tests decode it
rather than asserting byte identity.

## Training a table

Level 0 is the only level that uses a table you supply — levels 1-3 build their
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

Sizes, so a cache can budget: `HuffTables` 2,232 bytes, `Histogram` 2,528,
`Trainer` 18,912, `Compressor` 299,472. Keep one `Compressor` per thread —
they share nothing, so no locks — rather than one per request.

The numbers at the top of this file come from `examples/bench.goose`: an
event-log API answering with JSON of one shape, 200 responses sampled, 1000
timed, one thread. Two things to read off it:

- **Trained level 0 is the fastest option.** It keeps level 1's ratio while
  skipping the per-block Huffman table that levels 1-3 rebuild for every block —
  which is where their time goes.
- **Untrained level 0 is the worst of both.** Same speed, 40% worse ratio, and
  on bodies under a few hundred bytes it expands them. Reach for a table before
  reaching for level 0.

## How it works

**C owns no memory.** Goose has no heap, so the binding has none: `malloc`
appears nowhere in `src/igzip_shim.c`. The 82 KB `isal_zstream` and its level
buffer are the bytes of the `Compressor`; the histogram, counters and match
scratch are the bytes of the `Trainer`. A compressor starts with that state
array, so C receives a pointer to the Goose aggregate and reads its first
field. Compressed bytes are written straight into the destination builder's
stack top and only the bytes written are claimed, which is the contract
`goose.h` documents for C appending to a builder.

**Layouts are pinned.** Those values mirror C structs whose sizes and offsets
are asserted in the shim, so an ISA-L upgrade that changes a layout fails the
build instead of corrupting memory. `igzip::compressor_size()` and
`trainer_size()` let the tests assert the same thing at run time.

**Errors are typed.** C's negative status codes become `Status`; the level and
input length are validated in Goose before igzip sees them.

## Verification

`make verify` proves the following, and nothing here is claimed without it.

Goose-side (`test/contract.goose`):

- Layouts agree: the C `sizeof` values match the declarations in `igzip.goose`.
- Every level and wrapper stays inside `bound(n)`; incompressible input is
  never claimed to have shrunk.
- An invalid level or an oversized input is rejected without touching the
  output, and so is a fabricated Huffman table whose header length would make
  igzip read outside the value.
- Two runs of the same input give identical bytes, and so do two compressors.
- Trained tables beat level 0's default both on the sampled text and on a
  half of the corpus the samples never saw.
- Counts exported and re-imported produce a bit-identical table.
- Empty input yields a well-formed 20-byte member.

Streaming (`test/streaming.goose`):

- A single `write` + `finish` matches `compressed` byte for byte at levels 1-3
  for every wrapper, at 32 KiB through 316 KiB; level 0 is decoded, not
  compared, for the ISA-L reason above.
- Chunked writes (1, 7, 63, 4,096 and 70,000 bytes) produce the same bytes as
  one write at 120,233 bytes, and 1 MiB written in 64 KiB windows matches.
- `Sync` prefixes decode to exactly the bytes written before the flush; the raw
  bytes after a `Full` flush decode as the following chunk with a fresh decoder.
- Custom gzip headers carry mtime, OS, text/xflags, name, comment, extra and
  HCRC; a 67 KB header exercises the large-header path; interior NULs and
  oversized extra fields are rejected.
- zlib window/FLEVEL are honored; preset dictionaries work for raw and zlib,
  and a zlib stream without the dictionary fails to decode.
- Trained tables are used at level 0; `reset` keeps one, `clear_tables` drops it.
- Lifecycle misuse, mid-stream table changes, copies made after the first write,
  and reset recovery all return the documented `Status`.
- `test/large_stream.goose` feeds one writer 4.2 GiB in 1 MiB pieces, checks the
  64-bit total and the wrapped 32-bit gzip ISIZE, and never holds the stream.

Independent decode (`scripts/check_gzip.py`): **40 streams** are inflated with
CPython's zlib and compared byte for byte — one per wrapper and level, sizes of
0, 1, 17, 65535, 65536 and 262144 bytes (deflate's block seams), two
deterministic repeats, two concatenated members, incompressible noise, the
trained stream, the trained-on-half stream, the empty member, the streaming
chunked/default/level-0 streams, both flush points, the trained-table flush swap, the custom and large
headers, the zlib header, and the dictionary streams with their `zdict`. It
also checks `mtime = 0` where the API promises it, parses header fields, and
checks FDICT/DICTID.

Memory safety (`make stress`): `scripts/bound_stress.c` allocates `bound(n)`
*exactly* and compresses incompressible and adversarial inputs at every level
and wrapper under AddressSanitizer, then drives the stateful path with output
slices as small as 8 bytes and writes gzip headers into exact-size and
one-byte-short buffers — 600 cases, up to 4 MiB, no overrun. That is what makes
the bound and `avail_out` trustworthy rather than hopeful.

Threading (`test/threads.goose`): four `thread_fn` workers, each with its own
compressor, 16 jobs through typed queues, plus two streaming workers with a
`Writer` on the data stack; two workers compressing the same input must agree
on the size.

```
[ok]   determinism           two runs gave identical bytes
[ok]   ratio vs zlib l1          2113 bytes vs 2219
[ok]   ratio vs zlib l9          1887 bytes vs 1868
[ok]   matrix/gzip_0.gz          3095 bytes    9.9% of 31364
[ok]   matrix/gzip_1.gz          2113 bytes    6.7% of 31364
[ok]   matrix/gzip_3.gz          1887 bytes    6.0% of 31364
[ok]   trained.gz                2135 bytes    6.8% of 31364
[ok]   trained table saves 960 bytes over the level 0 default
40/40 streams valid
4 workers, 16 jobs, 2977 bytes for 425 records
4200 MiB, ISIZE 109051904, total_in 4404019200
```

## Layout

```
igzip.goose              the package: types, extern declarations, public API
igzip.build              native part: names the CMake target "igzip_goose"
CMakeLists.txt          builds the shim and ISA-L from vendor/isa-l
vendor/isa-l            pinned submodule, v2.32.1 (not installed anywhere)
src/igzip_shim.c         the C side; owns no memory
test/contract.goose     one-shot contract tests, writes build/tmp for the checker
test/streaming.goose    writer, flush, header, dictionary and lifecycle tests
test/threads.goose      one compressor per worker thread (built, not JIT-run)
test/large_stream.goose >2 GiB and >4 GiB through one writer (built, not JIT-run)
examples/               gzip_file, trained_table, bench
scripts/check_gzip.py   inflates every stream the tests wrote
scripts/bound_stress.c  proves the output bound as an exact buffer size
ROADMAP.md              igzip coverage plan and the measurements behind the API
CHANGELOG.md            what each release added
docs/internals.md       maintainer documentation: pin, memory model, security
AGENTS.md               short agent hook pointing at docs/internals.md
```

## Contributing

[`docs/internals.md`](docs/internals.md) has the parts that are not obvious from
reading one file: the submodule pin and how to bump it, the memory model, the
igzip behaviours the API encodes, the security notes, and the FFI review gates.

Four invariants hold across the package; a change that breaks one needs a
better reason than convenience.

1. **C owns no memory.** State lives in `Compressor` / `Trainer` values, so the
   owning scope is the free. No `malloc`, no `free`, no handle to close.
2. **Errors are typed.** C's negative status codes become `Status`; nothing
   aborts on bad input, and the level and input size are checked before igzip
   sees them.
3. **Layouts are pinned.** Mirrored struct sizes and offsets are asserted in
   `src/igzip_shim.c`, and the tests compare them with the declarations.
4. **The build is self-contained.** ISA-L comes from `vendor/isa-l` via
   `CMakeLists.txt`. Never add `c_libs`, an `extern "isal"` block, or a
   dependency on an installed ISA-L.

```bash
make check     # after every edit; silent on success
make verify    # check + tests + thread test + examples
make stress    # the output bound, as an exact buffer size, under ASan
make fmt       # layout is goose format's decision, not yours
```

`make test` inflates every stream the tests wrote, because "it returned Ok" is
not evidence that the bytes are a valid gzip stream.

## Importing

```goose
import igzip from "BHare1985/goose-igzip@v0.1.0";
```

Goose fetches the repo and its submodule. Until a tag exists, use a commit or a
local path.

## License

BSD-3-Clause, see [LICENSE](LICENSE). ISA-L itself is vendored under
`vendor/isa-l` with its own BSD-3-Clause [license](vendor/isa-l/LICENSE).

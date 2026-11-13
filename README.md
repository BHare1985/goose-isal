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
| `version`, `bound`, `status_name`, `compressor_size`, `trainer_size` | diagnostics |
| `MAX_INPUT` | the largest input accepted, 0x7FFFFFF0 bytes (igzip's 32-bit lengths) |

`Wrapper` is `Raw`, `Gzip` or `Zlib`. `Status` is `Ok`, six named failures, and
`Other`; `status_name` renders them. Nothing aborts on bad input.

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

Independent decode (`scripts/check_gzip.py`): **25 streams** are inflated with
CPython's zlib and compared byte for byte — one per wrapper and level, sizes of
0, 1, 17, 65535, 65536 and 262144 bytes (deflate's block seams), two
deterministic repeats, two concatenated members, incompressible noise, the
trained stream, the trained-on-half stream, and the empty member. It also
checks `mtime = 0` on every gzip member and that our sizes are not far off
zlib's own.

Memory safety (`make stress`): `scripts/bound_stress.c` allocates `bound(n)`
*exactly* and compresses incompressible and adversarial inputs at every level
and wrapper under AddressSanitizer — 480 cases, up to 4 MiB, no overrun. That is
what makes the bound trustworthy rather than hopeful.

Threading (`test/threads.goose`): four `thread_fn` workers, each with its own
compressor, 16 jobs through typed queues, and two workers compressing the same
input must agree on the size.

```
[ok]   determinism           two runs gave identical bytes
[ok]   ratio vs zlib l1          2113 bytes vs 2219
[ok]   ratio vs zlib l9          1887 bytes vs 1868
[ok]   matrix/gzip_0.gz          3095 bytes    9.9% of 31364
[ok]   matrix/gzip_1.gz          2113 bytes    6.7% of 31364
[ok]   matrix/gzip_3.gz          1887 bytes    6.0% of 31364
[ok]   trained.gz                2135 bytes    6.8% of 31364
[ok]   trained table saves 960 bytes over the level 0 default
25/25 streams valid
4 workers, 16 jobs, 2977 bytes for 425 records
```

## Layout

```
igzip.goose              the package: types, extern declarations, public API
igzip.build              native part: names the CMake target "igzip_goose"
CMakeLists.txt          builds the shim and ISA-L from vendor/isa-l
vendor/isa-l            pinned submodule, v2.32.1 (not installed anywhere)
src/igzip_shim.c         the C side; owns no memory
test/contract.goose     contract tests, writes build/tmp for the checker
test/threads.goose      one compressor per worker thread (built, not JIT-run)
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

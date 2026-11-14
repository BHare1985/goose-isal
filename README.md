# goose-igzip

A complete gzip, zlib and raw-deflate codec in [Goose](https://goose-lang.org),
bound to Intel ISA-L's **igzip**: compress and decompress, streaming or one-shot,
with trained Huffman tables, custom headers and preset dictionaries.

Everything a caller touches is a Goose value, so the owning scope is the free —
no C memory to release and no handle to close. Failures are a typed `Status`, and
levels, sizes, headers and tables are validated before igzip sees them. ISA-L is
vendored, pinned and built by the package; nothing is installed system-wide.

```goose
import std;
import igzip;

fn main() {
    var c = igzip::gzip_compressor(1);          // keep one per thread
    let gz, err = c.compressed(body);           // fresh buffer in your destination
    guard err.ok() else { abort(igzip::status_name(err)); };
}
```

## What you get

| Value | Bytes | What it is |
|---|---:|---|
| `Compressor` | 299,472 | one-shot deflate; no stream to finish |
| `Writer` | 367,280 | streaming deflate + a 64 KiB output chunk |
| `Reader` | 152,936 | streaming inflate + a 64 KiB staging chunk |
| `Trainer` | 18,912 | histogram, counters and match scratch |
| `Histogram` | 2,528 | just the counters, for caching many content types |
| `HuffTables` | 2,232 | one complete Huffman table |

Plus small values for the container: `GzipHeader` / `ZlibHeader` to write a
header, `GzipInfo` / `ZlibInfo` to read one, and `GzipInfo`'s offsets for the
optional name, comment and extra field.

## Quick start

**Compress.** One call, one member. Two calls leave two members back to back.

```goose
var c = igzip::gzip_compressor(1);

let gz, err = c.compressed(body);      // you have nowhere to put the bytes yet
var out: u8[>..] = [];                 // or you own the buffer and reuse it
c.compress(body_a, out);
c.compress(body_b, out);
```

**Compress as you go.** A `Writer` is a `Fresh → HeaderWritten → Open → Flushed
→ Finished` machine, and `reset` starts the next body.

```goose
var w = igzip::gzip_writer(1);
var out: u8[>..] = [];

guard w.write(chunk_a, out).ok() else { abort("write failed"); };
guard w.flush(out).ok() else { abort("flush failed"); };      // a decode point
guard w.write(chunk_b, out).ok() else { abort("write failed"); };
guard w.finish(out).ok() else { abort("finish failed"); };     // the trailer
guard w.reset().ok() else { abort("reset failed"); };          // next body
```

**Decompress.** `read` appends decoded bytes and tells you how much of your input
it used, because a decoder stops at the end of a member.

```goose
var r = igzip::gzip_reader();
var body: u8[>..] = [];

let used, err = r.read(gz, body);
guard err.ok() else { abort(igzip::status_name(err)); };
guard r.finished() else { abort("feed me more"); };   // member not complete yet
guard r.finish().ok() else { abort("truncated"); };   // Ok, or Truncated

// gz[used..] is the next member, or trailing bytes that are not this one.
```

**Decompress a whole buffer.** `inflated` walks every member; `inflate` decodes
one into a slice you sized (and is the only call that reports `TooSmall`).

```goose
var r = igzip::gzip_reader();
let plain, err = r.inflated(gz);                  // every member, joined

var dst: u8[>..] = [];
dst.resize(isize, 0);                             // from the trailer, or a guess
let used, written, ierr = r.inflate(gz, dst);     // TooSmall tells you to grow
```

**Train a table** on one class of body and use level 0 — the fast path — at
level 1's ratio. Table of measurements in [docs/guide.md](docs/guide.md#trained-tables).

```goose
var t = igzip::trainer();
t.add(json_body);
guard t.symbols() >= 64 * 1024 else { /* keep warming */ };

let tables, built = t.build();
guard built.ok() else { abort(igzip::status_name(built)); };
c.set_tables(tables);                  // level 0 from here on
```

## Install and build

ISA-L is a **pinned submodule** at `vendor/isa-l` (release `v2.32.1`, pinned by
commit) built from source by this package's `CMakeLists.txt`. There is no
`libisal-dev` to install and no `.so` to find at run time; `igzip::version` reads
the release the tests link against. [docs/internals.md](docs/internals.md) has the
commit and the bump procedure.

The native build needs git (for the submodule), cmake, `nasm` and a C compiler.
`nasm` is not optional in practice: without it ISA-L falls back to portable C and
loses the kernels that are the reason to use ISA-L.

```bash
make tools          # compiler version, ISA-L tag, nasm, cmake
make check          # typecheck the package; silent on success
make test           # Goose tests; every stream is decoded by the package itself
make crosscheck     # the same streams through CPython's zlib (needs python3)
make test-threads   # worker-pool test (needs a native build)
make test-large     # 4.2 GiB through one Writer and one Reader (native)
make stress         # AddressSanitizer: bounds, staging, hostile input
make verify         # check + tests + crosscheck + examples
make bench          # native throughput benchmark
make fmt            # layout is goose format's decision, not yours
```

`GOOSE_HOME` (default `~/.goose`) locates the toolchain and the package build
tree; `GOOSE` selects a specific compiler.

## API

Every function takes the value first, so the method form works: `c.compress(..)`
is `igzip::compress(c, ..)`. Full detail, with the reasoning, is in
[docs/guide.md](docs/guide.md).

**One-shot compression**

| Call | Meaning |
|---|---|
| `gzip_compressor(level = 1)` | also `zlib_compressor`, `raw_compressor`, `compressor(wrap, level)` |
| `c.compressed(src)` → `u8[>..], Status` | one member, in a new buffer |
| `c.compress(src, out)` → `Status` | one member, appended to a buffer you own |
| `c.set_tables(t)` / `c.clear_tables(level = 1)` | attach a trained table (pins level 0) / drop it |
| `gzip(src, level = 1)` | one-shot convenience; declares its own compressor |

**Streaming compression**

| Call | Meaning |
|---|---|
| `gzip_writer(level = 1)` | also `zlib_writer`, `raw_writer`, `writer(wrap, level)` |
| `w.write(src, out)` → `Status` | append the bytes for `src`; consumes all of it |
| `w.flush(out)` / `w.flush(mode, out)` | `Sync` (default) or `Full` decode point |
| `w.finish(out)` → `Status` | final block and trailer; the writer is `Finished` |
| `w.reset()` → `Status` | back to `Fresh`, keeping wrapper, level and trained table |
| `w.write_gzip_header(hdr, out)` / `w.write_zlib_header(hdr, out)` | a custom header before the first body byte |
| `w.set_dict(dict)` → `Status` | preset dictionary (raw and zlib only) |
| `w.set_tables(t)` / `w.clear_tables()` | attach (pins level 0) / drop a trained table |
| `w.write_windowed(src, out, step)` | `write` with an explicit input window |
| `w.total_in`, `w.total_out`, `w.state` | bytes consumed, bytes produced, lifecycle |

**Decompression**

| Call | Meaning |
|---|---|
| `gzip_reader()` | also `zlib_reader`, `raw_reader`, `reader(wrap)` |
| `r.read(src, out)` → `i64, Status` | append decoded bytes; returns how much of `src` was consumed |
| `r.finished()` → `bool` | the member ended |
| `r.finish()` → `Status` | close the body: `Ok`, or `Truncated` |
| `r.reset()` → `Status` | back to `Fresh`, keeping the wrapper |
| `r.inflate(src, dst)` → `i64, i64, Status` | one member into a slice you sized |
| `r.inflated(src)` → `u8[>..], Status` | every member in `src` |
| `r.set_dict(dict)` → `Status` | preset dictionary (raw and zlib only) |
| `r.read_windowed(src, out, step)` | `read` with an explicit input window |
| `r.total_in`, `r.total_out`, `r.state` | bytes consumed, bytes decoded, lifecycle |

**Headers, either direction**

| Call | Meaning |
|---|---|
| `read_gzip_header(src)` → `GzipInfo, Status` | the fields, plus offsets of name/comment/extra and where the body starts |
| `read_zlib_header(src)` → `ZlibInfo, Status` | window bits, FLEVEL, FDICT and DICTID, where the body starts |

**Diagnostics**

| Call | Meaning |
|---|---|
| `version(out)` | ISA-L release, read from its headers |
| `bound(n)` | upper bound on compressed size, for sizing a destination |
| `compressor_size()`, `writer_size()`, `reader_size()`, `trainer_size()` | the pinned value sizes |
| `MAX_INPUT`, `MAX_IN_STEP`, `MAX_HEADER` | the 32-bit input limit, the window size, the header cap |

`Status` is `Ok`, twelve named failures and `Other`; `status_name` renders them
and nothing aborts on bad input. A `Status` is not a condition in Goose, so the
common form is `guard err.ok() else { ... }` and a specific case is
`err == igzip::Status.BadTable`. The full list is in
[docs/guide.md](docs/guide.md#errors).

## Documentation

| | |
|---|---|
| [docs/guide.md](docs/guide.md) | how to use it: buffer strategy, streaming, reading, headers, dictionaries, training, threads |
| [docs/coverage.md](docs/coverage.md) | what `igzip` exposes and what this package does with it — including what is deliberately left out |
| [docs/verification.md](docs/verification.md) | what `make verify` proves, file by file |
| [docs/internals.md](docs/internals.md) | maintaining it: the pin, the memory model, the igzip behaviours the API encodes, the FFI gates |
| [docs/design/](docs/design/) | the design briefs, with the measurements behind each decision |
| [ROADMAP.md](ROADMAP.md) · [CHANGELOG.md](CHANGELOG.md) | where it is going, and what each release added |

## Verification

`make verify` proves the following; nothing here is claimed without it.

- **Round trip in Goose** (`test/roundtrip.goose`): every wrapper × level × a
  ladder of sizes, each stream decoded ten ways and compared byte for byte.
- **Contract** (`test/contract.goose`, `test/writer_contract.goose`,
  `test/inflate_contract.goose`, `test/header_contract.goose`): layouts, state
  machines, totals, headers both directions, dictionaries, trained tables, and
  every misuse as a `Status` rather than a corrupt decode.
- **Streaming end to end** (`test/streaming.goose`): chunking, flush points,
  windows, and a 4 MiB incompressible stream across the output chunk.
- **4.2 GiB** (`test/large_stream.goose`): one writer fed 4.2 GiB in 1 MiB pieces
  and one reader decoding each piece as it goes, checking the 64-bit totals and
  the wrapped 32-bit gzip ISIZE.
- **Threads** (`test/threads.goose`): four compressor workers, two streaming
  workers, and a reader worker decoding members compressed on another thread.
- **Memory safety** (`make stress`): two AddressSanitizer harnesses that allocate
  every buffer to its exact size — the compression output bound, and the reader's
  destination and input.
- **Independent decode** (`make crosscheck`): **43 streams** inflated with
  CPython's zlib, because a compressor and a decompressor that agree with each
  other can still agree on a broken stream.

File-by-file detail, and the ISA-L quirks that shape the results, are in
[docs/verification.md](docs/verification.md).

## Importing

```goose
import igzip from "BHare1985/goose-igzip@v0.3.0";
```

Goose fetches the repo and its submodule. Until a tag exists, use a commit or a
local path.

## License

BSD-3-Clause, see [LICENSE](LICENSE). ISA-L itself is vendored under
`vendor/isa-l` with its own BSD-3-Clause [license](vendor/isa-l/LICENSE).

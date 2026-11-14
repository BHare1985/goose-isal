# Guide

How to use the package, and the reasons the API has the shape it has.
[README](../README.md) is the short version; this is the long one.
[internals.md](internals.md) is for people changing the package instead.

## Choosing a value

| You have | Use | It costs |
|---|---|---|
| one buffer, in and out | `Compressor` (`compress` / `compressed`) | 299,472 B |
| a body that arrives in pieces | `Writer` (`write` / `flush` / `finish`) | 367,280 B |
| compressed input to decode | `Reader` (`read` / `finish` / `inflate`) | 152,936 B |

All three are plain values: they are freed when the owning scope ends, they can
live in an array or a struct field, and they are safe to create inside a worker
thread. A server keeps one of each per thread rather than one per request.

A `Writer` and a `Reader` side by side is ~520 KB, and each carries its own
64 KiB chunk. That is the honest budget for a proxy that compresses and
decompresses; it is smaller than two `Compressor`s.

## Buffer strategy

Every call that produces bytes offers the same two shapes:

- **append to a buffer you own** — `c.compress(src, out)`, `w.write(src, out)`,
  `r.read(src, out)`. Nothing is allocated and the buffer is reused across calls.
- **a fresh buffer built in your destination** — `c.compressed(src)`,
  `r.inflated(src)`. For a caller that has nowhere to put the bytes yet.

Both avoid a copy the package could not have avoided itself: compressed output is
written straight into the destination (a `Writer` stages it in its own 64 KiB
chunk and appends only the bytes produced), and decompressed output is appended
from the `Reader`'s chunk. Callers never loop over `avail_out`; the package does.

`bound(n)` is an upper bound on the compressed size of `n` bytes at any level and
wrapper, for a caller that needs to reserve room up front. Decompression has no
bound, which is what `inflate` and `TooSmall` exist for.

## Streaming compression

```goose
var w = igzip::zlib_writer(1);
var out: u8[>..] = [];

if !w.write(header_json, out) { abort("write failed"); };
if !w.flush(out) { abort("flush failed"); };   // a decode point
if !w.write(rows_json, out) { abort("write failed"); };
if !w.finish(out) { abort("finish failed"); };
```

The lifecycle is `Fresh → HeaderWritten → Open → Flushed → Finished`, with
`reset` returning to `Fresh`. Writing after `finish`, writing a header after the
first body byte, or swapping a table while a block is open returns
`Status.BadState` rather than silently resetting or corrupting the stream.

- **`flush(Sync)`** byte-aligns the stream and ends the current stored block, so
  everything written so far is a complete decode point. That is what a
  checkpoint, a progress report, or an HTTP chunk boundary needs.
- **`flush(Full)`** also drops the LZ77 history, so the bytes after the flush do
  not reference anything before it. The raw bytes after a Full flush decode as a
  standalone stream — `test/streaming.goose` asserts exactly that in Goose.
- **`finish`** writes the final block and the trailer (CRC-32 and ISIZE for gzip,
  Adler-32 for zlib).

Inputs above `MAX_INPUT` are split into windows inside `write`, so `MAX_INPUT` is
a limit on one call, not on a stream. `write_windowed(src, out, step)` exposes
the window size, and the tests use it to reach the 32-bit path without a 2 GiB
input.

## Streaming decompression

```goose
var r = igzip::gzip_reader();
var body: u8[>..] = [];

let used, ok = r.read(gz, body);
if !ok { abort(str("read failed: ", igzip::error())); };
guard r.finished() else { abort("member is incomplete: feed more"); };
if !r.finish() { abort("truncated"); };
```

`read` returns a count as well as a status because decompression does not consume
everything it is given: it stops at the end of a member and leaves the rest of the
slice alone. `src[used..]` is the next member or trailing bytes, which is what
makes both expressible.

`Ok` with `!r.finished()` is not an error. It means the caller stopped feeding
input before the member ended, which is what makes a partially delivered body
resumable. Only `finish` turns that into `Status.Truncated`, and truncated input
is never reported as `Corrupt` — the remedy is different (fetch more, versus drop
it).

At a member boundary every decoded byte has already been appended, so `finish`
takes no buffer. `read` never returns holding staged output: it loops until igzip
has nothing left to give.

The lifecycle is `Fresh → Open → Finished`: `read` starts a body, `finish` closes
it, `reset` reopens the reader. A terminal error — `Corrupt`, `BadChecksum`,
`BadWrapper` — latches the reader `Finished`, so a loop that ignores a status
cannot go on reading `Ok` out of a dead stream. `finish` after such an error is
`BadState` rather than a second verdict on a stream that is already dead.

### Members, one at a time

```goose
var pos: i64 = 0;
loop {
    let used, ok = r.read(all[pos..], body);
    if !ok { abort(str("read failed: ", igzip::error())); };
    pos += used;
    if !r.finished() { break; }
    if pos == all.len { break; }
    if !r.reset() { abort("reset failed"); };
}
if !r.finish() { abort("truncated"); };
```

`inflated(src)` runs that loop for you and joins the members. Trailing garbage
after the last member is `BadWrapper`, never silently dropped.

### When you know the size

`inflate` decodes one member into a slice you already sized, and is the only verb
that reports `TooSmall`:

```goose
var dst: u8[>..] = [];
dst.resize(isize, 0);                        // from the trailer, or a guess

let used, written, err = r.inflate(gz, dst);
if err == igzip::Status.TooSmall {           // written == dst.len: grow, retry
    dst.resize(dst.len * 2, 0);
    let u2, w2, e2 = r.inflate(gz, dst);     // no reset needed
}
```

`TooSmall` leaves the reader `Fresh` with its decode state reset, so a retry needs
no `reset` and a caller may also switch to `read` and start over cleanly.

### Expansion limits

There is no limit parameter. A decompressor cannot know how large a member will
be, and `read` plus `r.total_out` is a better limit than aborting mid-member: a
caller stops feeding input when its own cap is passed. `inflated` and `inflate`
are for buffers whose size the caller already trusts, and their documentation
says so.

## Headers

### Writing one

`GzipHeader` and `ZlibHeader` are written explicitly, before the first `write`,
`flush` or `finish`:

```goose
var w = igzip::gzip_writer(1);
var out: u8[>..] = [];
let hdr = igzip::GzipHeader { os: 3, name: "report.csv", mtime: 0 };

if !w.write_gzip_header(hdr, out) { abort("header failed"); };
if !w.write(body, out) { abort("write failed"); };
if !w.finish(out) { abort("finish failed"); };
```

`mtime` defaults to 0 and `os` to 0xff, so a header left alone is reproducible.
RFC 1952 wants `name` and `comment` NUL-terminated; the wrapper adds the
terminator, and an empty name or comment is left out entirely. An interior NUL or
an `extra` field longer than 65,535 bytes is `Status.BadHeader`. A header larger
than the 64 KiB chunk is still supported: it is built in a temporary of the
measured required size and appended. Headers above `MAX_HEADER` (1 MiB) are
rejected, so an untrusted name or comment cannot force an unbounded temporary.

`ZlibHeader` exposes `window_bits` (8–15) and `flevel` (0–3); the zlib CMF/FLG
fields carry both, and the shim sets the match window to match, so a strict
decoder does not reject the stream with `invalid distance too far back`.

### Reading one

`read_gzip_header` and `read_zlib_header` parse the header at the start of a
buffer without decoding or copying anything. They report the fields and the
*offsets* of the optional parts, so a caller slices the input it already has:

```goose
var info, ok = igzip::read_gzip_header(gz);
if !ok { abort(str("header failed: ", igzip::error())); };

let name = gz[info.name_at..][..info.name_len];   // name_at is -1 when absent
let body = gz[info.body_at..];                    // the deflate stream
```

Offsets rather than copies or views: a view would dangle as soon as the caller
stopped borrowing the buffer, and a copy would need somewhere to put up to
65,535 bytes of `extra`. A field that is absent is `-1`, so one value answers both
"is it there" and "where". On any status but `Ok` the optional offsets stay `-1`
and only the ten fixed bytes are reported: an offset is worth having only once the
whole header has been seen.

The bytes are untrusted input, read before any of the stream is decoded, so every
length in the header is checked against the bytes actually present: a header that
ends early is `Truncated`, one that is not gzip at all is `BadWrapper`, and one
with reserved FLG bits set is `BadHeader`. Nothing scans without a bound.

`body_at` is what lets a proxy strip a header: feed `gz[info.body_at..]` to a
`raw_reader` and you have the member without its container.

Header CRCs (FHCRC) are *reported* (`info.hcrc`), not verified. `isal_inflate`
steps over them too, and a header that one call accepts and another rejects is
worse than a documented gap. Checksums in general are out of this package's
scope; see [coverage.md](coverage.md).

## Dictionaries

A preset dictionary is history both sides already have, so it need not be sent.

```goose
var w = igzip::zlib_writer(1);
if !w.set_dict(dictionary) { abort("dictionary failed"); };
if !w.write(payload, out) { abort("write failed"); };
if !w.finish(out) { abort("finish failed"); };
```

A zlib stream with a dictionary advertises FDICT and DICTID automatically.
igzip's plain `IGZIP_ZLIB` header does not, and a standard decoder would reject
the stream, so the shim emits the six-byte header itself. Calling
`write_zlib_header` after `set_dict` forces the flag too; an explicit mismatch is
`BadHeader`. gzip has no preset-dictionary header, so `set_dict` on a gzip
writer or reader is `BadState`.

Reading is the same idea in reverse. A zlib member with FDICT reports
`Status.NeedDict` with the header and DICTID already consumed, and `set_dict` is
legal right at that moment:

```goose
var r = igzip::zlib_reader();
var out: u8[>..] = [];

let used, err = r.read(member, out);
guard err == igzip::Status.NeedDict else { /* no dictionary needed */ };
if !r.set_dict(dictionary) { abort("set_dict failed"); };
let u2, e2 = r.read(member[used..], out);      // continues from where it stopped
```

Setting it before any input works too; the shim swallows the one redundant
`NeedDict` that a zlib header always produces. `reset` drops the dictionary, so a
reader reused for another dictionary stream sets it again.

Two facts worth knowing:

- igzip copies at most the last 32 KiB into its own history, so the slice need
  not outlive the call, and zlib's DICTID is Adler-32 over the *whole*
  dictionary.
- igzip **never compares** the dictionary against the stream's DICTID. With a
  gzip or zlib trailer a wrong dictionary is caught at the end (`BadChecksum`);
  on a **raw** stream there is no trailer and nothing catches it — you get wrong
  bytes and no error. Use a wrapper when the bytes must be trusted.

## Trained tables

Level 0 is the only level that uses a table you supply — levels 1–3 build their
own per block. It is also the fast path, so a trained table buys speed *and*
ratio on text of the trained kind.

```goose
var c = igzip::gzip_compressor(1);
var t = igzip::trainer();

t.add(json_body);                              // sample bodies as they go by
guard t.symbols() >= 64 * 1024 else { /* keep warming */ };

let tables, built = t.build();
if !built { abort(str("training failed: ", igzip::error())); };
c.set_tables(tables);                          // level 0 from here on
```

A table is built from a histogram, so it can be cached and rehydrated: `counts`
copies the 2,528-byte counters out of a trainer, and `trainer_of` builds a
trainer from them. `Histogram` is 2,528 bytes against a trainer's 18,912, which
is what makes a per-content-type cache cheap.

On a `Writer`, `set_tables` is legal before the first byte and after a completed
`Sync` or `Full` flush. `reset` keeps the table; `clear_tables` returns to the
writer's base level.

Numbers, on an event-log API serving 1.9 KB responses (`make bench` reproduces it):

| | ratio | µs/response |
|---|---|---|
| level 1 | 34.0% | 12 |
| level 3 | 34.1% | 18 |
| level 0, default table | 46.6% | 3 |
| **level 0, trained table** | **35.5%** | **3** |

At 9.4 KB per response: 20.5% at 19 µs for level 1, **20.8% at 11 µs** for the
trained table. Same bytes out, 3.8x and 1.6x less time in.

## Threads and memory

- No globals and no mutable statics in the shim, so two values in two threads
  share nothing. `igzip.build` does not declare `main_thread_only`.
- A `Compressor` passed **by value** is a ~300 KB copy, a `Writer` ~367 KB, a
  `Reader` ~153 KB. Take them by reference.
- A 367 KB fixed local is at home on the C stack on Linux but is close to macOS's
  512 KB pthread default. Workers keep their values in `T[>..]` holders, which
  live on the thread's data stack — see `test/threads.goose`.
- A fixed-size Goose value can be copied by assignment. A started `Writer` copy
  is refused because the C stream points into the original's level buffer; a
  started `Reader` copy is refused because both copies would decode from the same
  position and emit the same bytes twice. `reset` recovers either.

## Errors

`Status` is `Ok`, twelve named failures and `Other`:

| Status | Meaning |
|---|---|
| `Overflow` | input too large for igzip's 32-bit lengths |
| `BadLevel`, `BadLevelBuf` | level outside 0..3, or an unusable level buffer |
| `BadState` | call not allowed in this state |
| `BadWrapper` | invalid flush or wrapper, or bytes that are not this container |
| `BadTable`, `BadHeader` | a table or header this API cannot encode |
| `Truncated` | input ended before the member's final block |
| `TooSmall` | the destination had no room for the decoded bytes |
| `NeedDict` | a zlib stream requires a preset dictionary |
| `Corrupt` | the bytes are not a valid deflate stream |
| `BadChecksum` | the trailer does not match the decoded bytes |

Every call that can fail returns a `bool`, with any data in front of it:

```goose
let used, ok = r.read(gz, body);
if !ok { abort(str("read failed: ", igzip::error())); };
```

The reason is out of band, in the two accessors `goose_gfx` uses:
`igzip::error()` is that reason as text, and `igzip::status()` is the `Status`
itself, for a caller that needs to branch. Both describe the call just made —
success included, which clears them — and both are per thread, so a worker's
failure is its own:

```goose
let err = igzip::status();
if err {
    match err {
        Truncated => { /* feed more, or re-fetch */ },
        Corrupt => { /* drop it */ },
        NeedDict => { /* set_dict, then keep reading */ },
        _ => { /* anything else */ },
    }
}
```

`Status` names twelve failures plus `Other`, and prints itself, so
`str("finish failed: ", igzip::error())` needs no second call. `status_name`
gives the same words when you already hold a `Status`.

`guard` is still the right tool when the condition is not a status — `guard
r.finished() else { ... }` — and a status-only call reads naturally negated:
`if !w.finish(out) { ... }`.

One thing to expect: a corrupted payload often comes back as `Ok` with the member
unfinished rather than as an error, because igzip reports completion in a block
state and cannot tell "not yet" from "not ever". That is what `finish` is for; a
caller that only watches for errors cannot tell a truncated stream from a whole
one.

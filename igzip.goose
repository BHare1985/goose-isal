// igzip: Goose bindings for Intel ISA-L's igzip.
//
// ISA-L is a C library of hand-vectorised kernels for compression, checksums,
// erasure coding and RAID. igzip is its gzip implementation, and this package
// exposes it in the shape the rest of the codec should take:
//
//   * No C-owned memory. Every byte igzip works with lives in a Goose value,
//     so the scope that owns the value is the free, and C allocates nothing
//     on the caller's behalf.
//   * Typed errors. C's negative status codes become `Status`, one value per
//     distinct failure; nothing aborts on bad input.
//   * Your buffer policy, not ours. Append into a buffer you already own, or
//     get a fresh one built in your destination. Neither is a copy.
//   * The library is vendored, not installed: vendor/isa-l is a pinned
//     submodule and the package builds it. Values that mirror igzip's structs
//     are pinned by static asserts on the C side.
//
// A compressor is a value you make once and keep:
//
//   var c = igzip::gzip_compressor(1);
//   let gz, err = c.compressed(body);          // fresh buffer
//   c.compress(body, out);                     // or append to yours
//
// Training a Huffman table on one class of body and reusing it for every later
// body of that class is what makes level 0 pay off:
//
//   var t = igzip::trainer();
//   t.add(json_body);
//   guard t.symbols() >= 64 * 1024 else { /* keep warming */ };
//   let tables, err = t.build();
//   c.set_tables(tables);                      // level 0 from here on
//
// Facts about igzip this API encodes, all measured on 2.32.1:
//
//   * A supplied Huffman table is used at level 0 only. Levels 1-3 build their
//     own tables per block and ignore it, so `set_tables` pins the level to 0.
//     Level 0 is also the fast path: it skips per-block table construction and
//     reuses the header baked into the table.
//   * Level 0 without a trained table uses igzip's default table, which fits
//     text poorly. Stay on level 1 until a table is trained.
//   * One member per call. igzip's lengths are 32-bit, so inputs above 2 GiB
//     are rejected rather than silently truncated.
namespace igzip;

// ---------------------------------------------------------------------------
// Values Goose owns
// ---------------------------------------------------------------------------

// Container written around the deflate stream.
enum Wrapper {
    Raw,  // bare deflate, no header or trailer
    Gzip, // gzip (RFC 1952), with a fixed mtime of 0 so output is cacheable
    Zlib, // zlib (RFC 1950)
}

// The largest input the one-shot path accepts, in bytes. igzip's lengths are
// 32-bit, so `compress` rejects anything above rather than truncating; a
// `Writer` splits larger inputs into windows.
let MAX_INPUT = 0x7FFFFFF0;

// The largest custom gzip header accepted, bounding the temporary used when a
// header does not fit in the 64 KiB chunk. RFC 1952 bounds `extra` at 65,535
// bytes but places no bound on `name` or `comment`; this API does.
let MAX_HEADER = 1 << 20;

// How a call ended. `Ok` is the only success.
enum Status {
    Ok,
    Overflow,     // input too large for igzip's 32-bit lengths
    BadLevel,     // level outside 0..3
    BadLevelBuf,  // igzip's level buffer unusable
    BadState,     // call not allowed in this state
    BadWrapper,   // invalid flush or wrapper
    BadTable,     // the histogram produced an invalid table
    BadHeader,    // a gzip or zlib header this API cannot encode
    Other,        // an igzip error this package does not name
}

// A complete Huffman table: 2,232 bytes, the size of `struct isal_hufftables`,
// checked on the C side. Fixed-size and copyable, so a cache entry can hold
// one and a compressor can hold its own copy.
struct HuffTables {
    raw: u64[279] = [0; 279],
}

// Just the symbol counts: 2,528 bytes, being `struct isal_huff_histogram`'s
// 286 literal/length counters and 30 distance counters without its match
// scratch. For keeping many content types cheap: store one per type and
// rehydrate a Trainer when there is a sample to count.
struct Histogram {
    raw: u64[316] = [0; 316],
}

// A one-shot compressor: 299,472 bytes of igzip state (an `isal_zstream` and
// its level buffer), the wrapper it writes, the level, and, once trained, its
// own copy of a Huffman table.
struct Compressor {
    state:   u64[37434] = [0; 37434],
    tables:  HuffTables = HuffTables { .. },
    level:   i32        = 1,
    wrap:    Wrapper    = Wrapper.Gzip,
    trained: bool       = false,
}

// A table trainer: 18,912 bytes of histogram, counters and match scratch
// together, so a sample is counted straight into this value.
struct Trainer {
    state: u64[2364] = [0; 2364],
}

// ---------------------------------------------------------------------------
// Streaming writer
// ---------------------------------------------------------------------------

// Flush points. `Sync` byte-aligns the stream and ends the current stored
// block, so everything written so far is a complete decode point; `Full` also
// drops the LZ77 history, so the next block is independent of it.
enum Flush { Sync, Full }

// The writer's lifecycle. Every operation is legal in only some of these
// states; a call in the wrong one returns `Status.BadState` instead of
// corrupting the stream.
enum WriterState {
    Fresh,          // nothing written yet; headers and a dictionary may be set
    HeaderWritten,  // a custom gzip or zlib header is already in the output
    Open,           // body bytes written, no flush pending
    Flushed,        // the last call completed a Sync or Full flush
    Finished,       // the trailer is written; only `reset` is legal
}

// A custom gzip header. RFC 1952's mtime defaults to 0 and the OS byte to
// 0xff, so two runs over the same input produce identical bytes. `name` and
// `comment` are NUL-terminated on the wire; the wrapper adds that terminator.
// `extra` is length-prefixed and may contain any bytes.
struct GzipHeader {
    text:    bool        = false,
    mtime:   u32         = 0,
    xflags:  u8          = 0,
    os:      u8          = 0xff,
    hcrc:    bool        = false,
    name:    const u8[:] = "",
    comment: const u8[:] = "",
    extra:   const u8[:] = "",
}

// A custom zlib header. `window_bits` is 8..15; `flevel` is the 0..3 hint
// (0 = fastest, 3 = maximum). A preset dictionary set with `set_dict` forces
// `dict_flag` and supplies the DICTID.
struct ZlibHeader {
    window_bits: u8   = 15,
    flevel:      u8   = 0,
    dict_flag:   bool = false,
    dict_id:     u32  = 0,
}

// A streaming deflater: 367,280 bytes of igzip state, a 64 KiB output staging
// buffer, its wrapper and level, and its own copy of an optional trained table.
//
// The C stream keeps pointers into `level_buf` and `tables`. A fixed-size Goose
// value can be copied by assignment, so a copy made after the writer has been
// initialized (a write, a header, `set_dict` or `set_tables`) would leave those
// pointers in the original; the C side records the Writer's address and returns
// `Status.BadState` for such a copy. Call `reset` to recover a copy.
struct Writer {
    stream:      u64[10298]  = [0; 10298],
    level_buf:   u64[27136]  = [0; 27136],
    chunk:       u8[65536]   = [0; 65536],
    tables:      u64[279]    = [0; 279],
    pinned_self: u64         = 0,
    total_in:    u64         = 0,
    total_out:   u64         = 0,
    dict_id:     u32         = 0,
    base_level:  i32         = 1,
    wrap:        Wrapper     = Wrapper.Gzip,
    state:       WriterState = WriterState.Fresh,
    has_tables:  bool        = false,
    has_dict:    bool        = false,
    hdr_written: bool        = false,
}

// ---------------------------------------------------------------------------
// C surface (src/igzip_shim.c)
// ---------------------------------------------------------------------------

extern fn igzip_gs_version_major() -> i32;
extern fn igzip_gs_version_minor() -> i32;
extern fn igzip_gs_version_patch() -> i32;
extern fn igzip_gs_bound(n: i64) -> i64;
extern fn igzip_gs_compressor_size() -> i64;
extern fn igzip_gs_trainer_size() -> i64;

extern fn igzip_gs_hist_add(t: Trainer&, sample: const u8[:]) -> i32;
extern fn igzip_gs_hist_symbols(t: const Trainer&) -> i64;
extern fn igzip_gs_tables_build(t: const Trainer&, dst: HuffTables&) -> i32;
extern fn igzip_gs_tables_check(t: const HuffTables&) -> i32;
extern fn igzip_gs_hist_export(t: const Trainer&, dst: Histogram&);
extern fn igzip_gs_hist_import(t: Trainer&, src: const Histogram&);

extern fn igzip_gs_compress(c: Compressor&, src: const u8[:], out: u8[>..]&, level: i32, wrap: i32) -> i32;
extern fn igzip_gs_compress_trained(c: Compressor&, t: const HuffTables&, src: const u8[:], out: u8[>..]&, wrap: i32) -> i32;

extern fn igzip_gs_writer_size() -> i64;
extern fn igzip_gs_writer_reset(w: Writer&) -> i32;
extern fn igzip_gs_writer_gzip_header(w: Writer&, text: bool, mtime: u32, xflags: u8, os: u8,
    hcrc: bool, name: const u8[:], comment: const u8[:], extra: const u8[:], dst: u8[:],
    out_written: u32&, out_needed: u32&) -> i32;
extern fn igzip_gs_writer_zlib_header(w: Writer&, window_bits: u8, flevel: u8, dict_flag: bool,
    dict_id: u32, dst: u8[:], out_written: u32&) -> i32;
extern fn igzip_gs_writer_set_dict(w: Writer&, dict: const u8[:]) -> i32;
extern fn igzip_gs_writer_set_tables(w: Writer&, t: const HuffTables&) -> i32;
extern fn igzip_gs_writer_clear_tables(w: Writer&) -> i32;
extern fn igzip_gs_writer_step(w: Writer&, src: const u8[:], mode: u8, dst: u8[:],
    out_consumed: u32&, out_written: u32&, out_more: bool&) -> i32;

fn wrapper_code(w: Wrapper) -> i32 {
    return match w {
        Raw => 0,
        Gzip => 1,
        Zlib => 3,
    };
}

fn status_of(rc: i32) -> Status {
    return match rc {
        0 => Status.Ok,
        -1 => Status.Overflow,
        -3 => Status.BadState,
        -4 => Status.BadLevel,
        -5 => Status.BadLevelBuf,
        -7 => Status.BadWrapper,
        -8 => Status.BadHeader,
        -9 => Status.BadState,
        -10 => Status.BadTable,
        _ => Status.Other,
    };
}

// ---------------------------------------------------------------------------
// Compressors
// ---------------------------------------------------------------------------

// A compressor for any wrapper and level. Levels: 1 is the usual choice, 0 is
// fastest and the only level a trained table can be used at, 2 and 3 trade
// speed for a slightly smaller result.
fn compressor(wrap: Wrapper, level: i32 = 1) -> Compressor {
    return Compressor { wrap: wrap, level: level, .. };
}

fn gzip_compressor(level: i32 = 1) -> Compressor {
    return compressor(Wrapper.Gzip, level);
}

fn zlib_compressor(level: i32 = 1) -> Compressor {
    return compressor(Wrapper.Zlib, level);
}

fn raw_compressor(level: i32 = 1) -> Compressor {
    return compressor(Wrapper.Raw, level);
}

// Compresses `src` into `out`, appending. One member per call, so two calls
// leave two members back to back. Nothing is retained between calls, so one
// compressor serves every body.
fn compress(c: Compressor&, src: const u8[:], out: u8[>..]&) -> Status {
    // Checked here: igzip takes the level as an unsigned 32-bit field, so a
    // negative value would arrive as 0xFFFFFFFF.
    guard c.level >= 0 && c.level <= 3 else { return Status.BadLevel; }
    guard src.len <= MAX_INPUT else { return Status.Overflow; }
    let wrap = wrapper_code(c.wrap);
    if c.trained {
        // A table is raw C memory that igzip indexes with its own header length,
        // so a fabricated or deserialized one is checked before it is used.
        guard igzip_gs_tables_check(c.tables) == 0 else { return Status.BadTable; }
        return status_of(igzip_gs_compress_trained(c, c.tables, src, out, wrap));
    }
    return status_of(igzip_gs_compress(c, src, out, c.level, wrap));
}

// Compresses into a new buffer, built in the caller's destination: for a
// caller that has nowhere to put the bytes yet.
fn compressed(c: Compressor&, src: const u8[:]) -> u8[>..], Status {
    var out: u8[>..] = [];
    let err = compress(c, src, out);
    return out, err;
}

// Gives the compressor a trained table, which it copies. igzip uses a supplied
// table at level 0 only, so this sets the level to 0: the fastest level and the
// one the table is meant for.
//
// Anything is accepted here; the table is validated when it is used, and a
// malformed one gives `Status.BadTable` instead of reaching igzip. Prefer
// `build` over fabricating a table, and treat one read back from disk as
// untrusted until it has been through this.
fn set_tables(c: Compressor&, t: HuffTables&) {
    c.tables = t;
    c.trained = true;
    c.level = 0;
}

// Drops the trained table and returns to the default tables at `level`.
fn clear_tables(c: Compressor&, level: i32 = 1) {
    c.trained = false;
    c.level = level;
}

// ---------------------------------------------------------------------------
// Streaming writers
// ---------------------------------------------------------------------------

// The largest slice one shim call can pass to igzip; longer writes are split
// into windows of this size. It is `MAX_INPUT` because `avail_in` is 32-bit.
let MAX_IN_STEP = 0x7FFFFFF0;

// A writer for any wrapper and level. The stream is initialized on first use,
// not here, so returning the value from a function or storing it in an array
// cannot leave a C pointer to a dead local.
fn writer(wrap: Wrapper, level: i32 = 1) -> Writer {
    return Writer { wrap: wrap, base_level: level, .. };
}

fn gzip_writer(level: i32 = 1) -> Writer {
    return writer(Wrapper.Gzip, level);
}

fn zlib_writer(level: i32 = 1) -> Writer {
    return writer(Wrapper.Zlib, level);
}

fn raw_writer(level: i32 = 1) -> Writer {
    return writer(Wrapper.Raw, level);
}

// The exact byte size of a Writer, checked against the C mirror.
fn writer_size() -> i64 {
    return igzip_gs_writer_size();
}

// Compresses `src` in windows of at most `step` bytes. `write` uses this with
// MAX_IN_STEP; tests use a smaller step to exercise the same code path without
// allocating a 2 GiB input.
fn write_windowed(w: Writer&, src: const u8[:], out: u8[>..]&, step: i64) -> Status {
    guard step > 0 && step <= MAX_INPUT else { return Status.Overflow; }
    var pos: i64 = 0;
    while pos < src.len {
        var n = src.len - pos;
        if n > step { n = step; }
        let err = write_window(w, src[pos..pos + n], out);
        if err != Status.Ok { return err; }
        pos += n;
    }
    return Status.Ok;
}

// Appends the compressed bytes for `src` to `out`. All of `src` is consumed
// before returning; the writer stages igzip's output through its 64 KiB chunk.
fn write(w: Writer&, src: const u8[:], out: u8[>..]&) -> Status {
    return write_windowed(w, src, out, MAX_IN_STEP);
}

// One window: feed igzip until it has taken every byte of `src` and drained
// its output. A zero-progress result would loop forever, so it is a Status
// rather than a hang.
fn write_window(w: Writer&, src: const u8[:], out: u8[>..]&) -> Status {
    var consumed: i64 = 0;
    loop {
        var used:    u32 = 0;
        var written: u32 = 0;
        var more = false;
        let rc = igzip_gs_writer_step(w, src[consumed..], 0, w.chunk, used, written, more);
        if rc != 0 { return status_of(rc); }
        if written > 0 { out.append(w.chunk[..written]); }
        consumed += used;
        if !more { return Status.Ok; }
        if used == 0 && written == 0 { return Status.Other; }
    }
}

// A Sync flush: everything written so far is a complete decode point. The
// two-argument form is the common one; the three-argument form selects Full.
fn flush(w: Writer&, out: u8[>..]&) -> Status {
    return flush(w, Flush.Sync, out);
}

fn flush(w: Writer&, mode: Flush, out: u8[>..]&) -> Status {
    let code: u8 = match mode {
        Sync => 1,
        Full => 2,
    };
    return step_empty(w, code, out);
}

// Writes the final block and trailer. The writer cannot be used again until
// `reset`.
fn finish(w: Writer&, out: u8[>..]&) -> Status {
    return step_empty(w, 3, out);
}

fn step_empty(w: Writer&, mode: u8, out: u8[>..]&) -> Status {
    loop {
        var used:    u32 = 0;
        var written: u32 = 0;
        var more = false;
        let rc = igzip_gs_writer_step(w, "", mode, w.chunk, used, written, more);
        if rc != 0 { return status_of(rc); }
        if written > 0 { out.append(w.chunk[..written]); }
        if !more { return Status.Ok; }
        if used == 0 && written == 0 { return Status.Other; }
    }
}

// Returns the writer to Fresh, preserving its wrapper, base level and trained
// table, and dropping the dictionary and any header. This is how a server
// reuses one writer for the next response, and how a mid-stream copy recovers.
fn reset(w: Writer&) -> Status {
    return status_of(igzip_gs_writer_reset(w));
}

// Writes a custom gzip header. RFC 1952 requires name and comment to be
// NUL-terminated; Goose slices are not, so copies with a trailing 0 are built
// here and passed to C. The header goes through the 64 KiB chunk unless it is
// larger than that, in which case it is built in a temporary of the required
// size and appended.
fn write_gzip_header(w: Writer&, hdr: GzipHeader, out: u8[>..]&) -> Status {
    // Bound the NUL-terminated copies before making them; the shim also caps
    // the measured header, but this refuses an untrusted multi-gigabyte name
    // before the first copy.
    guard hdr.name.len <= MAX_HEADER && hdr.comment.len <= MAX_HEADER else {
        return Status.BadHeader;
    }

    var name_buf: u8[>..] = [];
    if hdr.name.len > 0 {
        name_buf.append(hdr.name);
        name_buf.push(0);
    }
    var comment_buf: u8[>..] = [];
    if hdr.comment.len > 0 {
        comment_buf.append(hdr.comment);
        comment_buf.push(0);
    }

    var written: u32 = 0;
    var needed:  u32 = 0;
    let rc = igzip_gs_writer_gzip_header(w, hdr.text, hdr.mtime, hdr.xflags, hdr.os, hdr.hcrc,
                                        name_buf, comment_buf, hdr.extra, w.chunk, written, needed);
    if rc != 0 { return status_of(rc); }

    if needed > 0 {
        guard needed <= MAX_HEADER else { return Status.BadHeader };
        // Larger than the 64 KiB chunk. Build the header in a temporary of
        // exactly the required size; `out` may be one of the arrays `hdr`'s
        // slices point into, and growing it while those views are live is not
        // legal.
        var big: u8[>..] = [];
        for i in needed { big.push(0); }
        var written2: u32 = 0;
        var needed2:  u32 = 0;
        let rc2 = igzip_gs_writer_gzip_header(w, hdr.text, hdr.mtime, hdr.xflags, hdr.os, hdr.hcrc,
                                             name_buf, comment_buf, hdr.extra, big,
                                             written2, needed2);
        if rc2 != 0 { return status_of(rc2); }
        if needed2 > 0 { return Status.BadHeader; }
        out.append(big[..written2]);
        return Status.Ok;
    }

    if written > 0 { out.append(w.chunk[..written]); }
    return Status.Ok;
}

// Writes a custom zlib header. If a dictionary was set, FDICT and DICTID are
// filled in automatically, because a zlib decoder rejects a dictionary stream
// whose header does not advertise one.
fn write_zlib_header(w: Writer&, hdr: ZlibHeader, out: u8[>..]&) -> Status {
    var written: u32 = 0;
    let rc = igzip_gs_writer_zlib_header(w, hdr.window_bits, hdr.flevel, hdr.dict_flag,
                                        hdr.dict_id, w.chunk, written);
    if rc != 0 { return status_of(rc); }
    if written > 0 { out.append(w.chunk[..written]); }
    return Status.Ok;
}

// Sets a preset dictionary. Legal only on raw and zlib writers before the
// first byte. igzip copies the last 32 KiB into its own history buffer, so the
// slice does not have to outlive the call.
fn set_dict(w: Writer&, dict: const u8[:]) -> Status {
    guard dict.len <= MAX_INPUT else { return Status.Overflow; }
    return status_of(igzip_gs_writer_set_dict(w, dict));
}

// Attaches a trained table to a writer. As with `Compressor`, a supplied table
// is used at level 0 only, so this pins the level to 0. Legal before the first
// byte and after a completed Sync or Full flush.
fn set_tables(w: Writer&, t: const HuffTables&) -> Status {
    guard igzip_gs_tables_check(t) == 0 else { return Status.BadTable; }
    return status_of(igzip_gs_writer_set_tables(w, t));
}

// Drops the trained table and returns to the writer's base level.
fn clear_tables(w: Writer&) -> Status {
    return status_of(igzip_gs_writer_clear_tables(w));
}

// ---------------------------------------------------------------------------
// Training
// ---------------------------------------------------------------------------

fn trainer() -> Trainer {
    return Trainer { .. };
}

fn histogram() -> Histogram {
    return Histogram { .. };
}

fn tables() -> HuffTables {
    return HuffTables { .. };
}

// Counts one sample body. Each call counts that body on its own: matches that
// would span two samples are not found, so a table trained from many small
// bodies reflects bodies, not the corpus as one long run.
fn add(t: Trainer&, body: const u8[:]) -> Status {
    // Rejected rather than clamped: a silently shortened sample would train on
    // half a body and say nothing.
    guard body.len <= MAX_INPUT else { return Status.Overflow; }
    return status_of(igzip_gs_hist_add(t, body));
}

// Symbols counted so far. Check this against a floor before building a table
// from a handful of tiny bodies.
fn symbols(t: Trainer&) -> i64 {
    return igzip_gs_hist_symbols(t);
}

// Builds the table. Every literal keeps a code, so a body containing bytes the
// samples never saw still encodes.
fn build(t: Trainer&) -> HuffTables, Status {
    var tables = HuffTables { .. };
    let rc = igzip_gs_tables_build(t, tables);
    return tables, status_of(rc);
}

// Copies the counts out, for keeping a content type's progress at 2.5 KB
// instead of the trainer's 19 KB.
fn counts(t: Trainer&, h: Histogram&) {
    igzip_gs_hist_export(t, h);
}

// A trainer holding those counts, ready for the next sample.
fn trainer_of(h: Histogram&) -> Trainer {
    var t = trainer();
    igzip_gs_hist_import(t, h);
    return t;
}

// ---------------------------------------------------------------------------
// Diagnostics and the no-ceremony form
// ---------------------------------------------------------------------------

// Writes the ISA-L release this package is built against, such as "2.32.1".
// Read from ISA-L's own headers at compile time, so it cannot drift from the
// code being linked.
fn version(out: u8[>..]&) {
    format(out, igzip_gs_version_major(), ".", igzip_gs_version_minor(), ".", igzip_gs_version_patch());
}

// An upper bound on compressed size for an input of `n` bytes, at any level and
// wrapper. `compress` needs no reservation of its own; this is for sizing a
// destination buffer up front.
fn bound(n: i64) -> i64 {
    return igzip_gs_bound(n);
}

// Whether a call succeeded, so the common case reads as one condition:
//
//   let gz, err = c.compressed(body);
//   guard err.ok() else { abort(igzip::status_name(err)); };
//
// A Status is not a condition in Goose — `guard err` is a type error, because
// only a bool or an optional is — and this is the shortest spelling that is
// one.
fn ok(s: Status) -> bool {
    return s == Status.Ok;
}

fn status_name(e: Status) -> const u8[:] {
    return match e {
        Ok => "ok",
        Overflow => "input too large for igzip's 32-bit lengths",
        BadLevel => "compression level must be 0..3",
        BadLevelBuf => "igzip level buffer unusable",
        BadState => "call is not allowed in this writer state",
        BadWrapper => "invalid flush or wrapper",
        BadTable => "histogram produced an invalid table",
        BadHeader => "gzip or zlib header field cannot be encoded",
        Other => "igzip reported an error this package does not name",
    };
}

// The sizes the C side and the declarations above must agree on; the tests
// compare them, so a struct change cannot pass unnoticed.
fn compressor_size() -> i64 {
    return igzip_gs_compressor_size();
}

fn trainer_size() -> i64 {
    return igzip_gs_trainer_size();
}

// For a tool that compresses one buffer and exits:
//
//   let gz, err = igzip::gzip(body);
//
// A server keeps a `Compressor` per thread instead: this declares ~300 KB of
// state inside the call.
fn gzip(src: const u8[:], level: i32 = 1) -> u8[>..], Status {
    var c = gzip_compressor(level);
    var out: u8[>..] = [];
    let err = compress(c, src, out);
    return out, err;
}

// igzip: a gzip, zlib and raw-deflate codec for Goose, bound to Intel ISA-L.
//
// Three values do the work, and each is a plain value -- the owning scope is the
// free, and a value can live in an array, a struct field or a worker thread:
//
//   Compressor (299,472 B)   one-shot deflate:  compress / compressed
//   Writer     (367,280 B)   streaming deflate: write / flush / finish / reset
//   Reader     (152,936 B)   streaming inflate: read / finish / inflate
//
// Two small values describe the container in both directions: GzipHeader and
// ZlibHeader are what you write, GzipInfo and ZlibInfo are what a member says
// (including the offsets of its name, comment and extra field).
//
//   var c = igzip::gzip_compressor(1);
//   let gz, err = c.compressed(body);          // a whole body, one member
//
//   var r = igzip::gzip_reader();
//   let used, err = r.read(gz, body);          // appends; reports consumption
//   guard r.finished() else { /* feed more */ };
//   guard r.finish() else { /* truncated */ };
//
// Four rules hold the shape together:
//
//   * No C-owned memory. Every byte igzip works with lives in a Goose value, so
//     C allocates nothing on the caller's behalf and there is nothing to close.
//   * Typed errors. C's status codes become `Status`, one value per distinct
//     failure; nothing aborts on bad input, and untrusted bytes are checked
//     before igzip sees them.
//   * Your buffer policy, not ours. Append into a buffer you already own, or
//     get a fresh one built in your destination. Neither is a copy.
//   * Vendored, not installed: vendor/isa-l is a pinned submodule the package
//     builds, and every mirrored layout is pinned by static asserts in C.
//
// This file is ordered the way a reader meets it: values, the C surface, then
// compressor, writer, reader, headers, training and diagnostics. docs/guide.md
// explains how to use them; docs/coverage.md maps what igzip can do onto what
// this package exposes; docs/internals.md is for changing it.
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
//     are rejected rather than silently truncated; the streaming values split
//     them into windows instead.
//   * Decompression reports completion in a block state, not a return code:
//     igzip folds "ran out of input" into success, so `finished`/`finish` are
//     the only way to tell a whole member from a truncated one. A corrupted
//     payload can therefore come back as `Ok` with the member unfinished.
//   * igzip never compares a supplied dictionary with the stream's DICTID, so a
//     wrong one is caught by a gzip or zlib trailer and by nothing at all on a
//     raw stream.
//   * Checksums are verified by igzip itself through the trailer and are not
//     part of this package's surface: it verifies them and does not compute
//     them. docs/coverage.md says why.
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

// Output staging shared by the streaming values: compressed bytes accumulate
// here until the caller's destination is handed them.
let CHUNK_SIZE = 65536;

// How a call ended. `Ok` is the only success.
// The outcome of a call that can fail: `Ok`, one of twelve named failures, or
// `Other`. The call itself returns a `bool`, and the reason is available from
// `status()` / `error()` -- the shape goose_gfx uses, where `gfx::open(..)`
// returns a bool and `gfx::error()` says why.
enum Status {
    Ok,
    Overflow,     // input too large for igzip's 32-bit lengths
    BadLevel,     // level outside 0..3
    BadLevelBuf,  // igzip's level buffer unusable
    BadState,     // call not allowed in this state
    BadWrapper,   // invalid flush or wrapper
    BadTable,     // the histogram produced an invalid table
    BadHeader,    // a gzip or zlib header this API cannot encode
    Truncated,    // input ended before the member's final block
    TooSmall,     // the destination had no room for the decoded bytes
    NeedDict,     // a zlib stream requires a preset dictionary
    Corrupt,      // the bytes are not a valid deflate stream
    BadChecksum,  // the trailer does not match the decoded bytes
    Other,        // an igzip error this package does not name
}

// The C return code a variant stands for: the inverse of status_of, so a
// failure the Goose side decides on can be recorded the same way a C one is.
fn status_code(s: Status) -> i32 {
    return match s {
        Ok => 0,
        Overflow => -1,
        BadState => -3,
        BadLevel => -4,
        BadLevelBuf => -5,
        BadWrapper => -7,
        BadHeader => -8,
        BadTable => -10,
        Truncated => -11,
        NeedDict => -12,
        TooSmall => -13,
        Corrupt => -14,
        BadChecksum => -15,
        Other => -16,
    };
}

// Records a C return code and reports whether the call succeeded, so a call
// site reads `if !write_window(..) { return false; }`.
fn record(rc: i32) -> bool {
    igzip_gs_record(rc); // 0 on success, which clears the record
    return rc == 0;
}

// The same for a failure this package decided on itself (a bad level, a call in
// the wrong state), so `error()` describes it too.
fn record_status(s: Status) -> bool {
    igzip_gs_record(status_code(s));
    return false;
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
    stream:      u64[10298]     = [0; 10298],
    level_buf:   u64[27136]     = [0; 27136],
    chunk:       u8[CHUNK_SIZE] = [0; CHUNK_SIZE],
    tables:      u64[279]       = [0; 279],
    pinned_self: u64            = 0,
    total_in:    u64            = 0,
    total_out:   u64            = 0,
    dict_id:     u32            = 0,
    base_level:  i32            = 1,
    wrap:        Wrapper        = Wrapper.Gzip,
    state:       WriterState    = WriterState.Fresh,
    has_tables:  bool           = false,
    has_dict:    bool           = false,
    hdr_written: bool           = false,
}

// ---------------------------------------------------------------------------
// Streaming reader
// ---------------------------------------------------------------------------

// The reader's lifecycle. `read` only ever moves `Fresh` to `Open`: a member
// ending is a fact (`finished`), not a state change, because a caller that
// stops feeding input may still resume. `finish` closes a body, and `reset`
// makes the reader usable again.
enum ReaderState {
    Fresh,    // nothing read yet; a dictionary may be set
    Open,     // mid-member, or at the end of one; `read` may continue
    Finished, // the body was closed; only `reset` is legal
}

// What a gzip member's header says, and where each part of it sits.
//
// The parts are offsets into the input, not copies and not views: a view would
// dangle as soon as the caller stopped borrowing the buffer, and a copy would
// need somewhere to put up to 65,535 bytes of `extra`. Slice the input with
// them: `gz[info.name_at..][..info.name_len]`.
//
// `GzipHeader` is what you *write*; this is what you *read*. A field that is
// absent is `-1`, so one value answers both "is it there" and "where". On any
// status but `Ok` the optional offsets stay `-1` and only the ten fixed bytes
// are reported: an offset is worth having only once the whole header has been
// seen.
struct GzipInfo {
    text:        bool = false, // FTEXT: the file is probably ASCII
    hcrc:        bool = false, // an FHCRC follows the header (reported, not verified)
    mtime:       u32  = 0,     // unix time of the last modification
    xflags:      u8   = 0,     // XFL: compressor-specific hint
    os:          u8   = 0xff,  // OS the file was written on
    extra_at:    i64  = -1,    // FEXTRA, a subfield block the format leaves open
    extra_len:   i64  = 0,
    name_at:     i64  = -1,    // FNAME, without its NUL terminator
    name_len:    i64  = 0,
    comment_at:  i64  = -1,    // FCOMMENT, without its NUL terminator
    comment_len: i64  = 0,
    body_at:     i64  = 0,     // where the deflate stream starts
}

// What a zlib member's header says. Same offsets-not-copies rule as `GzipInfo`,
// with no variable-length parts to point at.
struct ZlibInfo {
    window_bits: i64  = 15, // 8..15, from CMF's CINFO
    flevel:      u8   = 0,  // FLEVEL: 0 fastest, 3 maximum, a hint only
    dict:        bool = false, // FDICT: a preset dictionary is required
    dict_id:     u32  = 0,  // the DICTID, big-endian on the wire as RFC 1950 says
    body_at:     i64  = 2,  // where the deflate stream starts
}

// A streaming inflater: 87,368 bytes of igzip state, a 64 KiB output staging
// buffer, and its wrapper.
//
// Unlike a `Writer`, no pointer into this value is held between calls, so a copy
// is memory-safe. It is still refused, because a copy would decode from the same
// position and emit the same bytes twice without saying so; `reset` recovers it.
struct Reader {
    istate:      u64[10921]     = [0; 10921],
    chunk:       u8[CHUNK_SIZE] = [0; CHUNK_SIZE],
    pinned_self: u64            = 0,
    total_in:    u64            = 0,
    total_out:   u64            = 0,
    wrap:        Wrapper        = Wrapper.Gzip,
    state:       ReaderState    = ReaderState.Fresh,
    has_dict:    bool           = false,
}

// ---------------------------------------------------------------------------
// C surface (src/igzip_shim.c)
// ---------------------------------------------------------------------------

extern fn igzip_gs_record(rc: i32);
extern fn igzip_gs_last_status() -> i32;
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

extern fn igzip_gs_reader_size() -> i64;
extern fn igzip_gs_reader_reset(r: Reader&) -> i32;
extern fn igzip_gs_reader_finished(r: const Reader&) -> bool;
extern fn igzip_gs_reader_set_dict(r: Reader&, dict: const u8[:]) -> i32;
extern fn igzip_gs_reader_step(r: Reader&, src: const u8[:], dst: u8[:], out_consumed: u32&,
    out_written: u32&, out_finished: bool&) -> i32;
extern fn igzip_gs_reader_stateless(r: Reader&, src: const u8[:], dst: u8[:],
    out_consumed: u32&, out_written: u32&) -> i32;

fn wrapper_code(w: Wrapper) -> i32 {
    return match w {
        Raw => 0,
        Gzip => 1,
        Zlib => 3,
    };
}

// The one table every C return goes through. The inflate family's own codes are
// translated in C into the -11..-15 range, because ISA-L reuses -1 and -3 for
// different failures on the two sides of the codec and a table keyed on the
// number alone cannot be right for both.
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
        -11 => Status.Truncated,
        -12 => Status.NeedDict,
        -13 => Status.TooSmall,
        -14 => Status.Corrupt,
        -15 => Status.BadChecksum,
        _ => Status.Other,
    };
}

// Why the last call failed, or `Status.Ok` if it succeeded. Every call that can
// fail records its outcome here, success included, so `status()` and the `bool`
// the call returned always agree: `guard ok else` means `status()` is not `Ok`.
//
// It is per thread, so a worker's failure is its own, and it is the most recent
// call's outcome rather than a history -- ask straight away, the way
// `gfx::error()` is used.
fn status() -> Status {
    return status_of(igzip_gs_last_status());
}

// That reason as text, or "" when the last call succeeded:
//
//   guard w.finish(out) else { abort(str("finish failed: ", igzip::error())); };
fn error() -> const u8[:] {
    let s = status();
    if s == Status.Ok { return ""; }
    return status_name(s);
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
fn compress(c: Compressor&, src: const u8[:], out: u8[>..]&) -> bool {
    // Checked here: igzip takes the level as an unsigned 32-bit field, so a
    // negative value would arrive as 0xFFFFFFFF.
    guard c.level >= 0 && c.level <= 3 else { return record_status(Status.BadLevel); }
    guard src.len <= MAX_INPUT else { return record_status(Status.Overflow); }
    let wrap = wrapper_code(c.wrap);
    if c.trained {
        // A table is raw C memory that igzip indexes with its own header length,
        // so a fabricated or deserialized one is checked before it is used.
        guard igzip_gs_tables_check(c.tables) == 0 else { return record_status(Status.BadTable); }
        return record(igzip_gs_compress_trained(c, c.tables, src, out, wrap));
    }
    return record(igzip_gs_compress(c, src, out, c.level, wrap));
}

// Compresses into a new buffer, built in the caller's destination: for a
// caller that has nowhere to put the bytes yet.
fn compressed(c: Compressor&, src: const u8[:]) -> u8[>..], bool {
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
// Streaming writers and headers
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
fn write_windowed(w: Writer&, src: const u8[:], out: u8[>..]&, step: i64) -> bool {
    guard step > 0 && step <= MAX_INPUT else { return record_status(Status.Overflow); }
    var pos: i64 = 0;
    while pos < src.len {
        var n = src.len - pos;
        if n > step { n = step; }
        let err = write_window(w, src[pos..pos + n], out);
        if !err { return err; }
        pos += n;
    }
    return true;
}

// Appends the compressed bytes for `src` to `out`. All of `src` is consumed
// before returning; the writer stages igzip's output through its 64 KiB chunk.
fn write(w: Writer&, src: const u8[:], out: u8[>..]&) -> bool {
    return write_windowed(w, src, out, MAX_IN_STEP);
}

// Hands the bytes a streaming value produced to the caller's builder. Kept
// separate so every streaming verb drains a staging chunk the same way.
fn append_output(out: u8[>..]&, chunk: const u8[:], n: u32) {
    if n > 0 { out.append(chunk[..n]); }
}

// One window: feed igzip until it has taken every byte of `src` and drained
// its output. A zero-progress result would loop forever, so it is a Status
// rather than a hang.
fn write_window(w: Writer&, src: const u8[:], out: u8[>..]&) -> bool {
    var consumed: i64 = 0;
    loop {
        var used:    u32 = 0;
        var written: u32 = 0;
        var more = false;
        let rc = igzip_gs_writer_step(w, src[consumed..], 0, w.chunk, used, written, more);
        if rc != 0 { return record(rc); }
        append_output(out, w.chunk, written);
        consumed += used;
        if !more { return true; }
        if used == 0 && written == 0 { return record_status(Status.Other); }
    }
}

// A Sync flush: everything written so far is a complete decode point. The
// two-argument form is the common one; the three-argument form selects Full.
fn flush(w: Writer&, out: u8[>..]&) -> bool {
    return flush(w, Flush.Sync, out);
}

fn flush(w: Writer&, mode: Flush, out: u8[>..]&) -> bool {
    let code: u8 = match mode {
        Sync => 1,
        Full => 2,
    };
    return step_empty(w, code, out);
}

// Writes the final block and trailer. The writer cannot be used again until
// `reset`.
fn finish(w: Writer&, out: u8[>..]&) -> bool {
    return step_empty(w, 3, out);
}

fn step_empty(w: Writer&, mode: u8, out: u8[>..]&) -> bool {
    loop {
        var used:    u32 = 0;
        var written: u32 = 0;
        var more = false;
        let rc = igzip_gs_writer_step(w, "", mode, w.chunk, used, written, more);
        if rc != 0 { return record(rc); }
        append_output(out, w.chunk, written);
        if !more { return true; }
        if used == 0 && written == 0 { return record_status(Status.Other); }
    }
}

// Returns the writer to Fresh, preserving its wrapper, base level and trained
// table, and dropping the dictionary and any header. This is how a server
// reuses one writer for the next response, and how a mid-stream copy recovers.
fn reset(w: Writer&) -> bool {
    return record(igzip_gs_writer_reset(w));
}

// Writes a custom gzip header. RFC 1952 requires name and comment to be
// NUL-terminated; Goose slices are not, so copies with a trailing 0 are built
// here and passed to C. The header goes through the 64 KiB chunk unless it is
// larger than that, in which case it is built in a temporary of the required
// size and appended.
fn write_gzip_header(w: Writer&, hdr: GzipHeader, out: u8[>..]&) -> bool {
    // Bound the NUL-terminated copies before making them; the shim also caps
    // the measured header, but this refuses an untrusted multi-gigabyte name
    // before the first copy.
    guard hdr.name.len <= MAX_HEADER && hdr.comment.len <= MAX_HEADER else {
        return record_status(Status.BadHeader);
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
    if rc != 0 { return record(rc); }

    if needed > 0 {
        guard needed <= MAX_HEADER else { return record_status(Status.BadHeader); }
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
        if rc2 != 0 { return record(rc2); }
        if needed2 > 0 { return record_status(Status.BadHeader); }
        append_output(out, big, written2);
        return true;
    }

    append_output(out, w.chunk, written);
    return true;
}

// Writes a custom zlib header. If a dictionary was set, FDICT and DICTID are
// filled in automatically, because a zlib decoder rejects a dictionary stream
// whose header does not advertise one.
fn write_zlib_header(w: Writer&, hdr: ZlibHeader, out: u8[>..]&) -> bool {
    var written: u32 = 0;
    let rc = igzip_gs_writer_zlib_header(w, hdr.window_bits, hdr.flevel, hdr.dict_flag,
                                        hdr.dict_id, w.chunk, written);
    if rc != 0 { return record(rc); }
    append_output(out, w.chunk, written);
    return true;
}

// The other direction: reading back the same two headers, for a caller that
// received a member rather than wrote one.

// Reads the header of the gzip member at the start of `src`, without decoding
// or copying anything. Returns the fields and the offsets of the optional parts,
// so a caller can look at a name, or skip a header it does not care about and
// hand `src[info.body_at..]` to a `raw_reader`.
//
// The bytes are untrusted input: every length is checked against `src.len`, a
// header that ends early is `Truncated`, one that is not gzip at all is
// `BadWrapper`, and one that is gzip with a field this API cannot represent
// (reserved FLG bits set) is `BadHeader`. Nothing scans without a bound.
//
// This parses and reports; it does not verify the optional FHCRC, because the
// decoder does not either (`isal_inflate` steps over it), and a header that one
// call accepts and another rejects is worse than a documented gap.
fn read_gzip_header(src: const u8[:]) -> GzipInfo, bool {
    var info = GzipInfo { .. };
    // 10 fixed bytes: ID1, ID2, CM, FLG, MTIME, XFL, OS.
    guard src.len >= 10 else { return info, record_status(Status.Truncated); }
    guard (src[0] as i64) == 0x1f && (src[1] as i64) == 0x8b else { return info, record_status(Status.BadWrapper); }
    guard (src[2] as i64) == 8 else { return info, record_status(Status.BadWrapper); }

    let flg = src[3] as i64;
    // RFC 1952 reserves the top three bits and requires them to be zero.
    guard (flg & 0xe0) == 0 else { return info, record_status(Status.BadHeader); }
    info.text = (flg & 0x01) != 0;
    info.hcrc = (flg & 0x02) != 0;
    info.mtime = src[4] | ((src[5] as u32) << 8) | ((src[6] as u32) << 16) |
                 ((src[7] as u32) << 24);
    info.xflags = src[8];
    info.os = src[9];

    var pos: i64 = 10;
    if (flg & 0x04) != 0 {
        // FEXTRA: a 16-bit length, then that many bytes.
        guard src.len >= pos + 2 else { return info, record_status(Status.Truncated); }
        let xlen = src[pos] | ((src[pos + 1] as i64) << 8);
        pos += 2;
        guard src.len >= pos + xlen else { return info, record_status(Status.Truncated); }
        info.extra_at = pos;
        info.extra_len = xlen;
        pos += xlen;
    }
    if (flg & 0x08) != 0 {
        let end = nul_at(src, pos);
        guard end >= 0 else { return info, record_status(Status.Truncated); }
        info.name_at = pos;
        info.name_len = end - pos;
        pos = end + 1;
    }
    if (flg & 0x10) != 0 {
        let end = nul_at(src, pos);
        guard end >= 0 else { return info, record_status(Status.Truncated); }
        info.comment_at = pos;
        info.comment_len = end - pos;
        pos = end + 1;
    }
    if info.hcrc {
        guard src.len >= pos + 2 else { return info, record_status(Status.Truncated); }
        pos += 2;
    }
    info.body_at = pos;
    return info, true;
}

// The index of the first zero byte at or after `at`, or -1 when there is none.
// RFC 1952's names and comments are NUL-terminated strings with no length, so
// the end of the buffer is the only other thing that can end one.
fn nul_at(src: const u8[:], at: i64) -> i64 {
    var i = at;
    while i < src.len {
        if src[i] == 0 { return i; }
        i += 1;
    }
    return -1;
}

// Reads the two-byte header of the zlib member at the start of `src`. The check
// value zlib requires (CMF*256+FLG divisible by 31) is verified, so a stream
// with a corrupted header is `BadHeader` here rather than a decode error later.
fn read_zlib_header(src: const u8[:]) -> ZlibInfo, bool {
    var info = ZlibInfo { .. };
    guard src.len >= 2 else { return info, record_status(Status.Truncated); }
    let cmf = src[0] as i64;
    let flg = src[1] as i64;
    // CM (low four bits) must be 8: deflate is the only method zlib defines.
    guard (cmf & 0x0f) == 8 else { return info, record_status(Status.BadWrapper); }
    // CINFO (high four bits) is log2(window) - 8, so 8..15 once the 8 is added.
    guard (cmf >> 4) <= 7 else { return info, record_status(Status.BadHeader); }
    guard ((cmf << 8) | flg) % 31 == 0 else { return info, record_status(Status.BadHeader); }

    info.window_bits = (cmf >> 4) + 8;
    info.flevel = (flg >> 6) as u8;
    info.dict = (flg & 0x20) != 0;
    if info.dict {
        guard src.len >= 6 else { return info, record_status(Status.Truncated); }
        info.dict_id = ((src[2] as u32) << 24) | ((src[3] as u32) << 16) |
                       ((src[4] as u32) << 8) | src[5];
        info.body_at = 6;
    }
    return info, true;
}

// Sets a preset dictionary. Legal only on raw and zlib writers before the
// first byte. igzip copies the last 32 KiB into its own history buffer, so the
// slice does not have to outlive the call.
fn set_dict(w: Writer&, dict: const u8[:]) -> bool {
    guard dict.len <= MAX_INPUT else { return record_status(Status.Overflow); }
    return record(igzip_gs_writer_set_dict(w, dict));
}

// Attaches a trained table to a writer. As with `Compressor`, a supplied table
// is used at level 0 only, so this pins the level to 0. Legal before the first
// byte and after a completed Sync or Full flush.
fn set_tables(w: Writer&, t: const HuffTables&) -> bool {
    guard igzip_gs_tables_check(t) == 0 else { return record_status(Status.BadTable); }
    return record(igzip_gs_writer_set_tables(w, t));
}

// Drops the trained table and returns to the writer's base level.
fn clear_tables(w: Writer&) -> bool {
    return record(igzip_gs_writer_clear_tables(w));
}

// ---------------------------------------------------------------------------
// Streaming readers
// ---------------------------------------------------------------------------

// A reader for any wrapper. The state is initialized on first use, not here, so
// returning the value from a function or storing it in an array cannot leave a C
// pointer to a dead local.
fn reader(wrap: Wrapper) -> Reader {
    return Reader { wrap: wrap, .. };
}

fn gzip_reader() -> Reader {
    return reader(Wrapper.Gzip);
}

fn zlib_reader() -> Reader {
    return reader(Wrapper.Zlib);
}

fn raw_reader() -> Reader {
    return reader(Wrapper.Raw);
}

// The exact byte size of a Reader, checked against the C mirror.
fn reader_size() -> i64 {
    return igzip_gs_reader_size();
}

// Decodes `src` into `out`, appending, and returns how many of `src`'s bytes
// were consumed.
//
// Compression consumes everything it is given, so `write` returning a Status is
// the whole story. Decompression stops at the end of a member and leaves the
// rest of the slice alone, so the count is part of the result: `src[used..]` is
// the next member or trailing bytes, and a caller that cannot see that would
// re-feed or re-scan the buffer.
//
// The call ends when `src` is exhausted or a member ends. `finished(r)` is true
// only in the second case, and at that point every decoded byte is already in
// `out`: this loops until igzip has nothing left to give, so it never returns
// holding staged output. An empty `src` is therefore legal and a no-op; it is
// kept because `igzip_gs_reader_step` needs exactly that call to drain a
// destination smaller than the chunk, and the two spellings should not disagree.
//
// Input beyond `MAX_INPUT` is split into windows, never rejected.
fn read(r: Reader&, src: const u8[:], out: u8[>..]&) -> i64, bool {
    return read_windowed(r, src, out, MAX_IN_STEP);
}

// Decodes `src` in windows of at most `step` bytes. `read` uses this with
// MAX_IN_STEP; tests use a smaller step to exercise the same path without a
// 2 GiB input.
fn read_windowed(r: Reader&, src: const u8[:], out: u8[>..]&, step: i64) -> i64, bool {
    guard step > 0 && step <= MAX_INPUT else { return 0, record_status(Status.Overflow); }
    guard r.state != ReaderState.Finished else { return 0, record_status(Status.BadState); }
    // An empty source is legal: it is the drain call for a step-level caller
    // whose destination was smaller than the chunk, and a no-op otherwise.
    if src.len == 0 { return read_window(r, "", out); }

    var pos: i64 = 0;
    while pos < src.len {
        var n = src.len - pos;
        if n > step { n = step; }
        let used, err = read_window(r, src[pos..pos + n], out);
        pos += used;
        if !err { return pos, err; }
        if used == 0 { return pos, true; } // member done, or need more input
    }
    return pos, true;
}

// One window: feed igzip until it has taken every byte of `src` and drained
// whatever it staged. A zero-progress result with input left would spin, so it
// is a Status rather than a hang.
fn read_window(r: Reader&, src: const u8[:], out: u8[>..]&) -> i64, bool {
    var pos: i64 = 0;
    loop {
        var used:    u32 = 0;
        var written: u32 = 0;
        var done = false;
        let rc = igzip_gs_reader_step(r, src[pos..], r.chunk, used, written, done);
        append_output(out, r.chunk, written);
        pos += used;
        if rc != 0 { return pos, record(rc); }
        if done { return pos, true; }
        if used == 0 && written == 0 {
            // igzip has nothing left to give from these bytes.
            if pos < src.len { return pos, record_status(Status.Other); }
            return pos, true;
        }
    }
}

// Whether a member ended. This is the completion predicate `isal_inflate`
// cannot express through a return code: it folds `ISAL_END_INPUT` into success
// and reports completion only in a block state.
//
// `Ok` from `read` plus `!finished(r)` is not an error: it means the caller
// stopped feeding before the member ended. `finish` is what turns that into one.
fn finished(r: Reader&) -> bool {
    return igzip_gs_reader_finished(r);
}

// Closes the body and reports whether it was complete: `Truncated` if the
// member's final block was never reached, `Ok` if it was. Takes no output
// because `read` cannot return at a member boundary holding bytes back, so
// there is nothing to drain.
//
// A reader cannot be read from after this, and `reset` starts the next member.
// A terminal error closes the body too, so `finish` after `Corrupt` is
// `BadState` rather than a second verdict on a stream that is already dead.
fn finish(r: Reader&) -> bool {
    guard r.state != ReaderState.Finished else { return record_status(Status.BadState); }
    let done = finished(r);
    r.state = ReaderState.Finished;
    if done { return true; }
    return record_status(Status.Truncated);
}

// Returns the reader to Fresh, keeping its wrapper and dropping any dictionary
// and staged history. This is how a caller decodes a second concatenated member
// and how a mid-stream copy recovers.
fn reset(r: Reader&) -> bool {
    return record(igzip_gs_reader_reset(r));
}

// Sets a preset dictionary. Legal in `Fresh`, and again in the one moment igzip
// allows after decoding starts: right after `Status.NeedDict`, when the zlib
// header has been parsed and nothing has been emitted.
//
// igzip copies the last 32 KiB, so the slice does not have to outlive the call.
// It also **never checks the dictionary against the stream's DICTID**: with a
// gzip or zlib trailer a wrong dictionary is reported as `BadChecksum` at the
// end, and on a raw stream it is not reported at all — the caller gets wrong
// bytes with `true`. Use a wrapper if the bytes must be trusted.
//
// An empty dictionary is a no-op, as on a `Writer`: it cannot satisfy FDICT.
fn set_dict(r: Reader&, dict: const u8[:]) -> bool {
    return record(igzip_gs_reader_set_dict(r, dict));
}

// Decodes one member into a destination the caller has already sized, and
// returns `consumed, written, bool`. This is the only verb that can answer
// `TooSmall`: igzip cannot say how large a member will be, so a caller that
// knows (from a header, a length field, or a previous attempt) hands over its
// room. `TooSmall` writes exactly `dst.len` bytes and leaves the reader `Fresh`,
// so a retry with a bigger slice needs no `reset`.
//
// Trailing bytes after the member are left in `src`; the status does not claim
// they were consumed. `inflated` is the verb that loops over members.
fn inflate(r: Reader&, src: const u8[:], dst: u8[:]) -> i64, i64, bool {
    guard r.state == ReaderState.Fresh else { return 0, 0, record_status(Status.BadState); }
    var used:    u32 = 0;
    var written: u32 = 0;
    let rc = igzip_gs_reader_stateless(r, src, dst, used, written);
    return used, written, record(rc);
}

// Decodes every member in `src` into a new buffer.
//
// This drives the streaming loop rather than the stateless call: a fresh builder
// cannot be sized ahead of time, the streaming path needs no guess, and it is
// what lets a dictionary work here. Concatenated members are joined; trailing
// bytes after the last member are an error (`BadWrapper`), never silently
// dropped.
//
// On a non-`Ok` status the bytes decoded so far are returned beside it. They are
// not authenticated plaintext: check the status before using one. The reader's
// totals describe the last member, because `reset` between members zeroes them;
// `out.len` is the total and is not affected.
fn inflated(r: Reader&, src: const u8[:]) -> u8[>..], bool {
    var out: u8[>..] = [];
    guard r.state == ReaderState.Fresh else { return out, record_status(Status.BadState); }
    var pos: i64 = 0;
    loop {
        let used, err = read(r, src[pos..], out);
        pos += used;
        if !err { return out, err; }
        if !finished(r) { break; }
        if pos == src.len { break; }
        let again = reset(r);
        if !again { return out, again; }
    }
    // Without this a stream that simply ran out would report success: `read`
    // treats "no more input yet" as Ok, and only here is it knowable that there
    // is no more input coming.
    let err = finish(r);
    return out, err;
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
fn add(t: Trainer&, body: const u8[:]) -> bool {
    // Rejected rather than clamped: a silently shortened sample would train on
    // half a body and say nothing.
    guard body.len <= MAX_INPUT else { return record_status(Status.Overflow); }
    return record(igzip_gs_hist_add(t, body));
}

// Symbols counted so far. Check this against a floor before building a table
// from a handful of tiny bodies.
fn symbols(t: Trainer&) -> i64 {
    return igzip_gs_hist_symbols(t);
}

// Builds the table. Every literal keeps a code, so a body containing bytes the
// samples never saw still encodes.
fn build(t: Trainer&) -> HuffTables, bool {
    var tables = HuffTables { .. };
    let rc = igzip_gs_tables_build(t, tables);
    return tables, record(rc);
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

fn status_name(e: Status) -> const u8[:] {
    return match e {
        Ok => "ok",
        Overflow => "input too large for igzip's 32-bit lengths",
        BadLevel => "compression level must be 0..3",
        BadLevelBuf => "igzip level buffer unusable",
        BadState => "call is not allowed in this state",
        BadWrapper => "invalid flush or wrapper",
        BadTable => "histogram produced an invalid table",
        BadHeader => "gzip or zlib header field cannot be encoded",
        Truncated => "input ended before the end of the member",
        TooSmall => "destination had no room for the decoded bytes",
        NeedDict => "stream needs a preset dictionary",
        Corrupt => "bytes are not a valid deflate stream",
        BadChecksum => "trailer does not match the decoded bytes",
        Other => "igzip reported an error this package does not name",
    };
}

// Renders a Status wherever text goes: `print(err)`, `str(err)`,
// `abort(str("write failed: ", err))`. One table (`status_name`) decides the
// words, so the two spellings cannot disagree.
fn format(out: u8[>..]&, s: Status) {
    format(out, status_name(s));
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
fn gzip(src: const u8[:], level: i32 = 1) -> u8[>..], bool {
    var c = gzip_compressor(level);
    var out: u8[>..] = [];
    let err = compress(c, src, out);
    return out, err;
}

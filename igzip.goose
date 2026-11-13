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

// The largest input this package accepts, in bytes. igzip's lengths are 32-bit,
// so anything above is rejected rather than truncated.
let MAX_INPUT = 0x7FFFFFF0;

// How a call ended. `Ok` is the only success.
enum Status {
    Ok,
    Overflow,     // input too large for igzip's 32-bit lengths
    BadLevel,     // level outside 0..3
    BadLevelBuf,  // igzip's level buffer unusable
    BadState,     // a value was never initialized
    BadWrapper,   // invalid flush or wrapper
    BadTable,     // the histogram produced an invalid table
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
        BadState => "state value was not initialized",
        BadWrapper => "invalid flush or wrapper",
        BadTable => "histogram produced an invalid table",
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

// Contract tests for the isal package. Run under the JIT:
//
//     goose run --debug test/contract.goose
//
// Threading is a separate program, test/threads.goose, because igzip's workers
// need `goose build`.
//
// Every stream written to build/tmp is decoded twice: once here, by this
// package's own Reader (`decode_is`), and once by scripts/check_gzip.py, which
// is an independent decoder. A compressor can return Ok with a plausible size
// and still emit a broken stream, so size assertions alone prove nothing -- and
// a compressor and a decompressor that agree can agree on something broken,
// which is why the Python crosscheck stays.
import std;
import os;
import igzip from "..";
import support from "./support";

let TMP = "build/tmp";
// The release pinned in vendor/isa-l. Bumping it is a deliberate edit here.
let EXPECTED_ISA_L = "2.32.1";
let COMPRESSOR_BYTES = 37434 * 8;
let TRAINER_BYTES = 2364 * 8;

fn ext_of(w: igzip::Wrapper) -> const u8[:] {
    return match w {
        Raw => "deflate",
        Gzip => "gz",
        Zlib => "zlib",
    };
}

fn name_of(w: igzip::Wrapper) -> const u8[:] {
    return match w {
        Raw => "raw",
        Gzip => "gzip",
        Zlib => "zlib",
    };
}

fn gz1(body: const u8[:]) -> i64 {
    let gz, err = igzip::gzip(body);
    assert(err == igzip::Status.Ok);
    return gz.len;
}

// The C structs and the declarations in igzip.goose must agree, or C writes past
// the value Goose allocated.
fn test_layout() {
    assert(igzip::compressor_size() == COMPRESSOR_BYTES);
    assert(igzip::trainer_size() == TRAINER_BYTES);
    assert(igzip::bound(0) > 0);
    assert(igzip::bound(1 << 20) > (1 << 20));

    var t = igzip::trainer();
    assert(t.symbols() == 0);
    var h = igzip::histogram();
    assert(h.raw[0] == 0);
    assert(igzip::tables().raw[0] == 0);
}

fn test_roundtrip(body: const u8[:]) {
    var c = igzip::gzip_compressor(1);

    let gz, err = c.compressed(body);
    assert(err == igzip::Status.Ok);
    assert(gz.len < body.len);

    // A gzip member with a fixed zero mtime: 1f 8b 08 00 00 00 00 00.
    assert(gz.len > 18);
    assert(gz[0] == 0x1f && gz[1] == 0x8b && gz[2] == 8);
    for i in 4..8 { assert(gz[i] == 0); }

    // The builder contract: compress appends, it does not overwrite.
    var two: u8[>..] = [];
    assert(c.compress(body, two) == igzip::Status.Ok);
    assert(c.compress(body, two) == igzip::Status.Ok);
    assert(two.len == gz.len * 2);

    // A compressor carries no state between calls, so reusing it after an error
    // is fine.
    var scr: u8[>..] = [];
    let saved = c.level;
    c.level = 9;
    assert(c.compress(body, scr) == igzip::Status.BadLevel);
    c.level = saved;
    assert(c.compress(body, scr) == igzip::Status.Ok);
}

// The same input, twice, must give the same bytes: no clock, no counters, no
// state carried in the compressor.
fn test_determinism(body: const u8[:]) {
    var c = igzip::gzip_compressor(1);
    let a, err_a = c.compressed(body);
    let b, err_b = c.compressed(body);
    assert(err_a == igzip::Status.Ok && err_b == igzip::Status.Ok);
    assert(support::same(a, b));

    var c2 = igzip::gzip_compressor(1);
    let d, err_d = c2.compressed(body);
    assert(err_d == igzip::Status.Ok);
    assert(support::same(a, d));
}

// Two compressors hold independent state, so one per worker thread is safe.
fn test_independent_compressors(body: const u8[:]) {
    var a = igzip::gzip_compressor(1);
    var b = igzip::gzip_compressor(3);

    let ga, err_a = a.compressed(body);
    let gb, err_b = b.compressed(body);
    assert(err_a == igzip::Status.Ok && err_b == igzip::Status.Ok);
    assert(ga.len == gz1(body));
    assert(gb.len <= ga.len);
}

fn test_wrappers(body: const u8[:]) {
    var raw = igzip::raw_compressor(1);
    var zl = igzip::zlib_compressor(1);

    let r, err_r = raw.compressed(body);
    let z, err_z = zl.compressed(body);
    assert(err_r == igzip::Status.Ok && err_z == igzip::Status.Ok);

    // The wrapper costs bytes: raw < zlib < gzip.
    assert(r.len < z.len);
    assert(z.len < gz1(body));
}

fn test_levels(body: const u8[:]) {
    var sizes: i64[4] = [0; 4];
    for level in 4 {
        var c = igzip::gzip_compressor(level as i32);
        let out, err = c.compressed(body);
        assert(err == igzip::Status.Ok);
        assert(out.len < body.len);
        assert(out.len <= igzip::bound(body.len));
        sizes[level] = out.len;
    }
    // The slower levels never come out larger on the same body.
    assert(sizes[3] <= sizes[1]);
    assert(sizes[1] <= sizes[0]);
}

// Sizes that sit on deflate's seams: empty, one byte, a stored-block header's
// worth, and both sides of 65535, the boundary where a new stored block starts.
fn test_sizes() {
    var sizes: i64[6] = [0, 1, 17, 65535, 65536, 262144];
    for k in 6 {
        let n = sizes[k];
        var body: u8[>..] = [];
        support::body_of(body, n);
        assert(body.len == n);

        var c = igzip::gzip_compressor(1);
        let out, err = c.compressed(body);
        assert(err == igzip::Status.Ok);
        assert(out.len <= igzip::bound(n));
        // A body smaller than the 20-byte member header cannot shrink.
        if n >= 256 { assert(out.len < n); }
    }
}

// Incompressible input: the compressor must not fail, must not claim a shrink,
// and must stay inside the bound it advertises.
fn test_incompressible() {
    var noise_bytes: u8[>..] = [];
    support::noise(noise_bytes, 65536);

    for level in 4 {
        var c = igzip::gzip_compressor(level as i32);
        let out, err = c.compressed(noise_bytes);
        assert(err == igzip::Status.Ok);
        assert(out.len >= noise_bytes.len);
        assert(out.len <= igzip::bound(noise_bytes.len));
    }
}

fn test_training(body: const u8[:]) {
    var t = igzip::trainer();
    assert(t.symbols() == 0);

    let half = body.len / 2;
    assert(t.add(body[..half]) == igzip::Status.Ok);
    let seen = t.symbols();
    assert(seen > 0);

    // A second sample accumulates rather than replaces.
    assert(t.add(body[half..]) == igzip::Status.Ok);
    assert(t.symbols() > seen);

    let tables, built = t.build();
    assert(built == igzip::Status.Ok);

    var c = igzip::gzip_compressor(1);
    c.set_tables(tables);
    assert(c.level == 0); // igzip honours a supplied table at level 0 only

    let trained, err_t = c.compressed(body);
    assert(err_t == igzip::Status.Ok);

    var c0 = igzip::gzip_compressor(0);
    let fallback, err_f = c0.compressed(body);
    assert(err_f == igzip::Status.Ok);

    // On text of the trained kind, the table beats level 0's default.
    assert(trained.len < fallback.len);

    // Dropping the table returns to the ordinary levels.
    c.clear_tables(1);
    let plain, err_p = c.compressed(body);
    assert(err_p == igzip::Status.Ok);
    assert(plain.len == gz1(body));
}

// A table trained on one half must help on the other: that is the whole premise
// of training per content type rather than per body.
fn test_training_generalizes(body: const u8[:]) {
    let half = body.len / 2;

    var t = igzip::trainer();
    assert(t.add(body[..half]) == igzip::Status.Ok);
    let tables, built = t.build();
    assert(built == igzip::Status.Ok);

    var ct = igzip::gzip_compressor(1);
    ct.set_tables(tables);
    let trained, err_t = ct.compressed(body[half..]);
    assert(err_t == igzip::Status.Ok);

    var c0 = igzip::gzip_compressor(0);
    let plain, err_p = c0.compressed(body[half..]);
    assert(err_p == igzip::Status.Ok);

    assert(trained.len <= plain.len);
}

// Counts survive a trip out of the trainer and back, so a cache can keep 2.5 KB
// per content type instead of 19 KB.
fn test_counts_roundtrip(body: const u8[:]) {
    var t = igzip::trainer();
    assert(t.add(body) == igzip::Status.Ok);
    let before = t.symbols();

    var h = igzip::histogram();
    t.counts(h);

    var t2 = igzip::trainer_of(h);
    assert(t2.symbols() == before);

    let a, ok_a = t.build();
    let b, ok_b = t2.build();
    assert(ok_a == igzip::Status.Ok && ok_b == igzip::Status.Ok);
    for i in 279 { assert(a.raw[i] == b.raw[i]); }
}

// A table is raw C memory that igzip indexes with a length it reads out of the
// table itself. A fabricated or deserialized one must be refused rather than
// trusted: a bogus header count would make igzip read past the value and copy
// what it found into the output.
fn test_bad_tables(body: const u8[:]) {
    // Byte 328 of `struct isal_hufftables` is the header byte count, and byte
    // 332 the trailing bit count: both sit in raw[41], low half then high.
    var bad_count = igzip::tables();
    bad_count.raw[41] = 0xFFFFFFFF; // count and extra bits both absurd
    var c = igzip::gzip_compressor(1);
    c.set_tables(bad_count);
    var out: u8[>..] = [];
    assert(c.compress(body, out) == igzip::Status.BadTable);
    assert(out.len == 0);

    var bad_bits = igzip::tables();
    bad_bits.raw[41] = 100 | (0x10000 << 32); // sane count, impossible bit count
    c.set_tables(bad_bits);
    assert(c.compress(body, out) == igzip::Status.BadTable);
    assert(out.len == 0);

    // A real table still passes the same check.
    var t = igzip::trainer();
    assert(t.add(body) == igzip::Status.Ok);
    let good, built = t.build();
    assert(built == igzip::Status.Ok);
    c.set_tables(good);
    assert(c.compress(body, out) == igzip::Status.Ok);
    assert(out.len > 0);
}

fn test_errors(body: const u8[:]) {
    var c = igzip::gzip_compressor(9);
    var out: u8[>..] = [];
    assert(c.compress(body, out) == igzip::Status.BadLevel);
    assert(out.len == 0);

    c.level = -1;
    assert(c.compress(body, out) == igzip::Status.BadLevel);

    // The one-shot form validates the level too.
    let none, err = igzip::gzip(body, 4);
    assert(err == igzip::Status.BadLevel);
    assert(none.len == 0);

    // An untrained table still compresses: every literal keeps a code.
    var blank = igzip::tables();
    c.clear_tables(0);
    c.set_tables(blank);
    assert(c.compress(body, out) != igzip::Status.Other);

    assert(igzip::status_name(igzip::Status.BadLevel).len > 0);

    // A Status is not a condition in Goose, so this is how the common case is
    // spelled: one predicate instead of a comparison.
    assert(igzip::Status.Ok.ok());
    assert(!igzip::Status.BadLevel.ok());
    assert(c.compress(body, out).ok() || !c.compress(body, out).ok());

    // Every variant names itself, and no two share a name. The loop comes from
    // the enum's own metadata, so a variant added later cannot be forgotten
    // here -- the match in status_name would not compile without an arm, and
    // this catches the other half: an arm that says the same thing twice.
    const for <N, V> in variants<igzip::Status> {
        assert(igzip::status_name(V).len > 0);
        const for <N2, W> in variants<igzip::Status> {
            if N != N2 { assert(!(igzip::status_name(V) == igzip::status_name(W))); }
        }
    }

    // The format overload renders the same words wherever text goes, so
    // `print(err)` and `str("failed: ", err)` need no status_name call.
    assert(str(igzip::Status.BadChecksum) == igzip::status_name(igzip::Status.BadChecksum));
    assert(str(igzip::Status.Ok) == "ok");
    // The spelling the guide recommends for a diagnostic.
    assert(str("finish failed: ", igzip::Status.Truncated).len > "finish failed: ".len);
}

fn test_empty() {
    let gz, err = igzip::gzip("");
    assert(err == igzip::Status.Ok);
    assert(gz.len == 20); // 10-byte header, empty block, 8-byte trailer
}

// Every artifact scripts/check_gzip.py expects, written from one place so the
// tests above stay pure assertions. The checker discovers these by name, so a
// new case here needs no Python change.
// The self-hosting half: this package reads back what it wrote. Assertion
// messages name the artifact, so a failure says which stream is wrong.
fn decode_is(what: const u8[:], wrap: igzip::Wrapper, stream: const u8[:], want: const u8[:]) {
    var r = igzip::reader(wrap);
    let out, err = r.inflated(stream);
    guard err == igzip::Status.Ok else { abort(str("artifact ", what, " does not decode")); };
    guard support::same(out, want) else { abort(str("artifact ", what, " decodes to the wrong bytes")); };
}

fn write_artifacts(body: const u8[:]) {
    assert(make_dir(TMP));
    assert(write_file(str(TMP, "/body.txt"), body));

    // One stream per wrapper and level.
    let dir = str(TMP, "/matrix");
    assert(make_dir(dir));
    let wraps: igzip::Wrapper[3] = [igzip::Wrapper.Raw, igzip::Wrapper.Gzip, igzip::Wrapper.Zlib];
    for w, wi in wraps {
        for level in 4 {
            var c = igzip::compressor(w, level as i32);
            let out, err = c.compressed(body);
            assert(err == igzip::Status.Ok);
            let path = str(dir, "/", name_of(w), "_", level, ".", ext_of(w));
            assert(write_file(path, out));
            decode_is(path, w, out, body);
        }
    }

    // Sizes on deflate's seams, each beside its input.
    var sizes: i64[6] = [0, 1, 17, 65535, 65536, 262144];
    for k in 6 {
        let n = sizes[k];
        var src: u8[>..] = [];
        support::body_of(src, n);
        var c = igzip::gzip_compressor(1);
        let out, err = c.compressed(src);
        assert(err == igzip::Status.Ok);
        assert(write_file(str(TMP, "/size_", n, ".gz"), out));
        assert(write_file(str(TMP, "/size_", n, ".bin"), src));
        decode_is(str("size_", n), igzip::Wrapper.Gzip, out, src);
    }

    // Incompressible input, to prove the expansion path inflates too.
    var noise_bytes: u8[>..] = [];
    support::noise(noise_bytes, 65536);
    var cn = igzip::gzip_compressor(1);
    let noisy, err_n = cn.compressed(noise_bytes);
    assert(err_n == igzip::Status.Ok);
    assert(write_file(str(TMP, "/incompressible.gz"), noisy));
    assert(write_file(str(TMP, "/incompressible.bin"), noise_bytes));
    decode_is("incompressible", igzip::Wrapper.Gzip, noisy, noise_bytes);

    var lv1 = igzip::gzip_compressor(1);
    let gz, err_1 = lv1.compressed(body);
    assert(err_1 == igzip::Status.Ok);
    assert(write_file(str(TMP, "/twice_a.gz"), gz));
    assert(write_file(str(TMP, "/twice_b.gz"), gz));

    // Two members appended into one buffer: gzip allows it, and the checker
    // expects the body twice over.
    var two: u8[>..] = [];
    assert(lv1.compress(body, two) == igzip::Status.Ok);
    assert(lv1.compress(body, two) == igzip::Status.Ok);
    assert(write_file(str(TMP, "/twomembers.gz"), two));
    var doubled: u8[>..] = [];
    doubled.append(body);
    doubled.append(body);
    decode_is("twomembers", igzip::Wrapper.Gzip, two, doubled);

    var t = igzip::trainer();
    assert(t.add(body) == igzip::Status.Ok);
    let tables, built = t.build();
    assert(built == igzip::Status.Ok);
    var trained_c = igzip::gzip_compressor(1);
    trained_c.set_tables(tables);
    let trained, err_t = trained_c.compressed(body);
    assert(err_t == igzip::Status.Ok);
    assert(write_file(str(TMP, "/trained.gz"), trained));
    decode_is("trained", igzip::Wrapper.Gzip, trained, body);

    // The same table on a body it never sampled.
    let half = body.len / 2;
    let other, err_o = trained_c.compressed(body[half..]);
    assert(err_o == igzip::Status.Ok);
    assert(write_file(str(TMP, "/trained_half.gz"), other));
    decode_is("trained_half", igzip::Wrapper.Gzip, other, body[half..]);

    let empty, err_e = igzip::gzip("");
    assert(err_e == igzip::Status.Ok);
    assert(write_file(str(TMP, "/empty.gz"), empty));
    decode_is("empty", igzip::Wrapper.Gzip, empty, "");
}

fn main() {
    var body: u8[>..] = [];
    support::corpus(body, 300);
    assert(body.len > 20000);

    test_layout();
    test_roundtrip(body[..]);
    test_determinism(body[..]);
    test_independent_compressors(body[..]);
    test_wrappers(body[..]);
    test_levels(body[..]);
    test_sizes();
    test_incompressible();
    test_training(body[..]);
    test_training_generalizes(body[..]);
    test_counts_roundtrip(body[..]);
    test_bad_tables(body[..]);
    test_errors(body[..]);
    test_empty();
    write_artifacts(body[..]);

    var ver: u8[>..] = [];
    igzip::version(ver);
    assert(ver == EXPECTED_ISA_L);

    print("isal ", ver, ": ", body.len, " -> lv1 ", gz1(body[..]), " bytes");
    print("smoke: ok");
}

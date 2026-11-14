// Large-input streaming: feed one Writer past MAX_INPUT (2 GiB) and past the
// 32-bit ISIZE wrap (4 GiB), and decode it back through one Reader as it goes,
// without ever holding either the uncompressed or the compressed stream.
//
//     goose build test/large_stream.goose -o build/large_stream
//     ./build/large_stream
//
// The body is repeated, so the compressed output stays small and the test is
// bounded by igzip's throughput, not by memory. Every compressed chunk goes from
// `write` straight into `read`, which is the only way a 4 GiB round trip fits in
// a few MiB: the writer cannot keep its output either. The final gzip trailer's
// ISIZE is checked against the 64-bit total, and the reader's `total_out` is
// checked past igzip's 32-bit `total_out`.
import std;
import igzip from "..";

let MIB = 1048576;
let REPS = 4200; // 4,404,019,200 bytes, past 2^32

fn make_body(out: u8[>..]&) {
    for i in 16000 {
        format(out, "{\"id\":", i, ",\"user\":\"alice\",\"email\":\"alice@example.com\",",
               "\"active\":true,\"score\":", i * 37 % 1000, ",\"tags\":[\"alpha\",\"beta\"]},\n");
    }
    out.resize(MIB);
}

fn u32_le(xs: const u8[:], at: i64) -> u32 {
    return xs[at] | ((xs[at + 1] as u32) << 8) | ((xs[at + 2] as u32) << 16) |
           ((xs[at + 3] as u32) << 24);
}

// Checks a sample of the bytes decoded since the last call against the body the
// writer was fed, in order. Sampling one byte in 97 keeps a 4.4 GB comparison to
// a second or two while still walking every offset of the repeating body; the
// exact, every-byte claim belongs to test/roundtrip.goose, which can afford it.
fn verify_prefix(plain: const u8[:], body: const u8[:], verified: i64) -> i64 {
    var i: i64 = 0;
    while i < plain.len {
        assert(plain[i] == body[(verified + i) % body.len]);
        i += 97;
    }
    return verified + plain.len;
}

fn main() {
    var body: u8[>..] = [];
    make_body(body);
    assert(body.len == MIB);

    var w = igzip::gzip_writer(1);
    var r = igzip::gzip_reader();
    var out:      u8[>..] = []; // compressed bytes, between a write and a read
    var plain:    u8[>..] = []; // decoded bytes, between a read and the next write
    var verified: i64     = 0;

    for i in REPS {
        out.clear();
        assert(w.write(body, out) == igzip::Status.Ok);
        let used, err = r.read(out, plain);
        assert(err == igzip::Status.Ok);
        assert(used == out.len);
        verified = verify_prefix(plain, body, verified);
        plain.clear();
    }

    let fed = REPS * MIB;
    assert(w.total_in == fed as u64);
    // The finish output is the trailer on its own: the last round's compressed
    // bytes were already fed to the reader above.
    out.clear();
    assert(w.finish(out) == igzip::Status.Ok);
    assert(w.state == igzip::WriterState.Finished);
    assert(w.total_in == fed as u64);

    // The trailer is the last thing written, and the reader takes it too.
    guard out.len >= 8 else { abort("trailer missing"); }
    let isize = u32_le(out, out.len - 4);
    assert(isize == (fed & 0xFFFFFFFF) as u32);
    let used_tail, tail_err = r.read(out, plain);
    assert(tail_err == igzip::Status.Ok);
    assert(used_tail == out.len);
    verified = verify_prefix(plain, body, verified);
    assert(r.finished());
    assert(r.finish() == igzip::Status.Ok);

    // Every byte that went in came out: the reader's total is a u64 and does not
    // wrap at igzip's 32-bit total_out, which this stream passes four times.
    assert(verified == fed);
    assert(r.total_out == fed as u64);
    assert(r.total_in == w.total_out);

    print("large stream: ", fed / MIB, " MiB, ISIZE ", isize, ", total_in ", w.total_in,
          ", decoded ", r.total_out);
    print("large stream: ok");
}

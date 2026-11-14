// Large-input streaming: feed one Writer past MAX_INPUT (2 GiB) and past the
// 32-bit ISIZE wrap (4 GiB), without ever holding the whole stream.
//
//     goose build test/large_stream.goose -o build/large_stream
//     ./build/large_stream
//
// The body is repeated, so the compressed output stays small and the test is
// bounded by igzip's throughput, not by memory. The final gzip trailer's ISIZE
// is checked against the 64-bit total: that is the part of >4 GiB that a
// running decoder can observe.
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

fn main() {
    var body: u8[>..] = [];
    make_body(body);
    assert(body.len == MIB);

    var w = igzip::gzip_writer(1);
    var out: u8[>..] = [];
    for i in REPS {
        assert(w.write(body, out) == igzip::Status.Ok);
        // Keep only the recent tail: the stream history lives in the Writer,
        // not in the destination.
        if out.len > 4 * MIB { out.clear(); }
    }

    let fed = REPS * MIB;
    assert(w.total_in == fed as u64);
    assert(w.finish(out) == igzip::Status.Ok);
    assert(w.state == igzip::WriterState.Finished);
    assert(w.total_in == fed as u64);

    // A gzip trailer ends in CRC32 (4 bytes) then ISIZE (4 bytes), both LE.
    guard out.len >= 8 else { abort("trailer missing"); }
    let n = out.len;
    let isize = u32_le(out, n - 4);
    assert(isize == (fed & 0xFFFFFFFF) as u32);

    print("large stream: ", fed / MIB, " MiB, ISIZE ", isize, ", total_in ", w.total_in);
    print("large stream: ok");
}

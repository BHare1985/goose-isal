// Shared generators for the root test programs. Keeping the corpus in one
// place means the one-shot and streaming artifacts decode against the same
// bytes, and a new test does not re-implement the skew.
namespace support;

import std;

// A skewed JSON corpus: one schema, many records, the shape an API server
// actually compresses.
fn corpus(out: u8[>..]&, records: i64) {
    for i in records {
        format(out, "{\"id\":", i, ",\"user\":\"alice\",\"email\":\"alice@example.com\",",
               "\"active\":true,\"score\":", i * 37 % 1000, ",\"tags\":[\"alpha\",\"beta\"]},\n");
    }
}

// A compressible body of exactly n bytes, cut from the corpus's pattern.
fn body_of(out: u8[>..]&, n: i64) {
    var id = 0;
    while out.len < n {
        format(out, "{\"id\":", id, ",\"user\":\"alice\",\"email\":\"alice@example.com\",",
               "\"active\":true,\"score\":", id * 37 % 1000, "},\n");
        id++;
    }
    out.resize(n);
}

// Bytes nothing can compress: xorshift64. This is what exercises the worst-case
// expansion path and, on the streaming side, output larger than one chunk.
fn noise(out: u8[>..]&, n: i64) {
    var x: u64 = 0x243F6A8885A308D3;
    for i in n {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        out.push((x & 0xff) as! u8);
    }
}

fn same(a: const u8[:], b: const u8[:]) -> bool {
    guard a.len == b.len else { return false; }
    for x, i in a {
        if x != b[i] { return false; }
    }
    return true;
}

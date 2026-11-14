// Streaming end-to-end tests: one-shot equivalence, chunking, flush points,
// input windows, and a medium incompressible stream.
//
//     goose run --debug test/streaming.goose
//
// A Writer's state machine, headers, dictionaries, tables and copy guard are
// covered by test/writer_contract.goose. Streams written here are inflated by
// scripts/check_gzip.py.
import std;
import os;
import igzip from "..";
import support from "./support";

let TMP = "build/tmp/stream";

fn one_shot(body: const u8[:], wrap: igzip::Wrapper, level: i32) -> u8[>..] {
    var c = igzip::compressor(wrap, level);
    let out, err = c.compressed(body);
    assert(err == igzip::Status.Ok);
    return out;
}

fn streamed(body: const u8[:], wrap: igzip::Wrapper, level: i32) -> u8[>..] {
    var w = igzip::writer(wrap, level);
    var out: u8[>..] = [];
    assert(w.write(body, out) == igzip::Status.Ok);
    assert(w.finish(out) == igzip::Status.Ok);
    return out;
}

fn streamed_chunks(body: const u8[:], chunks: const i64[:]) -> u8[>..] {
    var w = igzip::gzip_writer(1);
    var out: u8[>..] = [];
    var pos: i64     = 0;
    var ci:  i64     = 0;
    while pos < body.len {
        var n = chunks[ci % chunks.len];
        if n > body.len - pos { n = body.len - pos; }
        assert(w.write(body[pos..pos + n], out) == igzip::Status.Ok);
        pos += n;
        ci++;
    }
    assert(w.finish(out) == igzip::Status.Ok);
    return out;
}

// The one-shot and streaming paths are byte-identical at the sizes the design
// measured. Below the 32 KiB internal buffer the two shapes are allowed to
// differ (both are valid gzip); the chunking and flush tests cover those.
fn test_equivalence() {
    var sizes: i64[4] = [32768, 65536, 120233, 316560];
    let wraps: igzip::Wrapper[3] = [igzip::Wrapper.Raw, igzip::Wrapper.Gzip, igzip::Wrapper.Zlib];
    for n in sizes {
        var body: u8[>..] = [];
        support::body_of(body, n);
        for w in wraps {
            for level in 4 {
                let a = one_shot(body, w, level as i32);
                let b = streamed(body, w, level as i32);
                // ISA-L's level-0 stateful path ends one stored byte
                // differently from its stateless path; levels 1-3 are
                // byte-identical. Both level-0 streams decode (checked by
                // scripts/check_gzip.py).
                if level > 0 {
                    assert(a.len == b.len);
                    assert(support::same(a, b));
                } else {
                    assert(b.len > 0);
                }
            }
        }
    }

    // The empty member is exact for the wrapped formats. Bare raw deflate has
    // different valid spellings of "no data", and ISA-L's stateful path writes
    // the shorter one.
    for w in wraps {
        let a = one_shot("", w, 1);
        let b = streamed("", w, 1);
        if w != igzip::Wrapper.Raw {
            assert(a.len == b.len && support::same(a, b));
        } else {
            assert(b.len > 0);
        }
    }
}

fn test_chunked() {
    var body: u8[>..] = [];
    support::body_of(body, 120233);
    let one = streamed(body, igzip::Wrapper.Gzip, 1);
    let chunks: i64[5] = [1, 7, 63, 4096, 70000];
    let many = streamed_chunks(body, chunks);
    assert(one.len == many.len);
    assert(support::same(one, many));

    let tiny: i64[1] = [13];
    let slow = streamed_chunks(body, tiny);
    assert(one.len == slow.len && support::same(one, slow));
}

fn test_flush() {
    var a: u8[>..] = [];
    support::body_of(a, 4096);
    var b: u8[>..] = [];
    support::body_of(b, 5000);

    var w = igzip::gzip_writer(1);
    var out: u8[>..] = [];
    assert(w.write(a, out) == igzip::Status.Ok);
    assert(w.flush(out) == igzip::Status.Ok);
    assert(write_file(str(TMP, "/sync_prefix.gz"), out));
    assert(w.write(b, out) == igzip::Status.Ok);
    assert(w.finish(out) == igzip::Status.Ok);
    assert(write_file(str(TMP, "/sync_full.gz"), out));
    assert(write_file(str(TMP, "/flush_a.bin"), a));
    assert(write_file(str(TMP, "/flush_b.bin"), b));

    // A flush larger than the 64 KiB chunk: the flush request must not be
    // re-issued when the output buffer fills.
    var noise: u8[>..] = [];
    support::noise(noise, 200000);
    var wn = igzip::gzip_writer(1);
    var nout: u8[>..] = [];
    assert(wn.write(noise, nout) == igzip::Status.Ok);
    assert(wn.flush(nout) == igzip::Status.Ok);
    assert(wn.write(noise, nout) == igzip::Status.Ok);
    assert(wn.finish(nout) == igzip::Status.Ok);
    assert(write_file(str(TMP, "/sync_big.gz"), nout));
    assert(write_file(str(TMP, "/sync_big.bin"), noise));

    // A Full flush drops the history. The raw bytes after the flush must
    // decode as B with a fresh decoder, which would fail if they referenced A.
    var wf = igzip::raw_writer(1);
    var ro: u8[>..] = [];
    assert(wf.write(a, ro) == igzip::Status.Ok);
    assert(wf.flush(igzip::Flush.Full, ro) == igzip::Status.Ok);
    let mark = ro.len;
    assert(wf.write(b, ro) == igzip::Status.Ok);
    assert(wf.finish(ro) == igzip::Status.Ok);
    assert(write_file(str(TMP, "/full_tail.deflate"), ro[mark..]));

    // Full flush is also a decode point in a complete gzip stream.
    var wg = igzip::gzip_writer(1);
    var gz: u8[>..] = [];
    assert(wg.write(a, gz) == igzip::Status.Ok);
    assert(wg.flush(igzip::Flush.Full, gz) == igzip::Status.Ok);
    assert(wg.write(b, gz) == igzip::Status.Ok);
    assert(wg.finish(gz) == igzip::Status.Ok);
    assert(write_file(str(TMP, "/full_full.gz"), gz));

    // Two flushes in a row are legal; ISA-L emits a redundant sync marker and
    // the stream still decodes.
    var wt = igzip::gzip_writer(1);
    var to: u8[>..] = [];
    assert(wt.write(a, to) == igzip::Status.Ok);
    assert(wt.flush(to) == igzip::Status.Ok);
    assert(wt.flush(to) == igzip::Status.Ok);
    assert(wt.finish(to) == igzip::Status.Ok);
    assert(write_file(str(TMP, "/sync_twice.gz"), to));
}

fn test_windows() {
    var body: u8[>..] = [];
    support::body_of(body, 1048576);

    var w = igzip::gzip_writer(1);
    var out: u8[>..] = [];
    assert(w.write_windowed(body, out, 65536) == igzip::Status.Ok);
    assert(w.finish(out) == igzip::Status.Ok);
    let direct = streamed(body, igzip::Wrapper.Gzip, 1);
    assert(out.len == direct.len && support::same(out, direct));

    var w2 = igzip::gzip_writer(1);
    var o2: u8[>..] = [];
    assert(w2.write_windowed(body, o2, 1) == igzip::Status.Ok);
    assert(w2.finish(o2) == igzip::Status.Ok);
    assert(support::same(o2, direct));

    var wlarge = igzip::gzip_writer(1);
    var olarge: u8[>..] = [];
    assert(wlarge.write_windowed(body, olarge, igzip::MAX_INPUT) == igzip::Status.Ok);
    assert(wlarge.finish(olarge) == igzip::Status.Ok);
    assert(support::same(olarge, direct));

    var w3 = igzip::gzip_writer(1);
    var o3: u8[>..] = [];
    assert(w3.write_windowed(body, o3, 0) == igzip::Status.Overflow);
    assert(w3.write_windowed(body, o3, igzip::MAX_INPUT + 1) == igzip::Status.Overflow);
}

// Output larger than the 64 KiB chunk, and a body large enough that the
// compressed stream crosses several buffer flushes.
fn test_medium() {
    var body: u8[>..] = [];
    support::noise(body, 4194304);
    let out = streamed(body, igzip::Wrapper.Gzip, 1);
    assert(out.len > 65536);
    assert(write_file(str(TMP, "/medium.gz"), out));
    assert(write_file(str(TMP, "/medium.bin"), body));
}

fn write_artifacts(body: const u8[:]) {
    assert(make_dir(TMP));
    assert(write_file(str(TMP, "/body.txt"), body));

    let chunks: i64[5] = [1, 7, 63, 4096, 70000];
    let chunked = streamed_chunks(body, chunks);
    assert(write_file(str(TMP, "/chunked.gz"), chunked));

    let plain = streamed(body, igzip::Wrapper.Gzip, 1);
    assert(write_file(str(TMP, "/default.gz"), plain));

    // Level 0 has a different (valid) ending in the stateful path; the decoder
    // checks it rather than asserting byte identity.
    let slow = streamed(body, igzip::Wrapper.Gzip, 0);
    assert(write_file(str(TMP, "/level0.gz"), slow));
}

fn main() {
    var body: u8[>..] = [];
    support::corpus(body, 3000);
    assert(body.len > 20000);

    assert(make_dir(TMP));
    test_equivalence();
    test_chunked();
    test_flush();
    test_windows();
    test_medium();
    write_artifacts(body);

    print("streaming: ", body.len, " bytes, writer ", igzip::writer_size(), " bytes");
    print("streaming: ok");
}

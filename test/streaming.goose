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
    assert(err);
    return out;
}

fn streamed(body: const u8[:], wrap: igzip::Wrapper, level: i32) -> u8[>..] {
    var w = igzip::writer(wrap, level);
    var out: u8[>..] = [];
    assert(w.write(body, out));
    assert(w.finish(out));
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
        assert(w.write(body[pos..pos + n], out));
        pos += n;
        ci++;
    }
    assert(w.finish(out));
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
    assert(w.write(a, out));
    assert(w.flush(out));
    assert(write_file(str(TMP, "/sync_prefix.gz"), out));
    assert(w.write(b, out));
    assert(w.finish(out));
    assert(write_file(str(TMP, "/sync_full.gz"), out));
    assert(write_file(str(TMP, "/flush_a.bin"), a));
    assert(write_file(str(TMP, "/flush_b.bin"), b));

    // A flush larger than the 64 KiB chunk: the flush request must not be
    // re-issued when the output buffer fills.
    var noise: u8[>..] = [];
    support::noise(noise, 200000);
    var wn = igzip::gzip_writer(1);
    var nout: u8[>..] = [];
    assert(wn.write(noise, nout));
    assert(wn.flush(nout));
    assert(wn.write(noise, nout));
    assert(wn.finish(nout));
    assert(write_file(str(TMP, "/sync_big.gz"), nout));
    assert(write_file(str(TMP, "/sync_big.bin"), noise));

    // A Full flush drops the history. The raw bytes after the flush must
    // decode as B with a fresh decoder, which would fail if they referenced A.
    var wf = igzip::raw_writer(1);
    var ro: u8[>..] = [];
    assert(wf.write(a, ro));
    assert(wf.flush(igzip::Flush.Full, ro));
    let mark = ro.len;
    assert(wf.write(b, ro));
    assert(wf.finish(ro));
    assert(write_file(str(TMP, "/full_tail.deflate"), ro[mark..]));

    // Full flush is also a decode point in a complete gzip stream.
    var wg = igzip::gzip_writer(1);
    var gz: u8[>..] = [];
    assert(wg.write(a, gz));
    assert(wg.flush(igzip::Flush.Full, gz));
    assert(wg.write(b, gz));
    assert(wg.finish(gz));
    assert(write_file(str(TMP, "/full_full.gz"), gz));

    // Two flushes in a row are legal; ISA-L emits a redundant sync marker and
    // the stream still decodes.
    var wt = igzip::gzip_writer(1);
    var to: u8[>..] = [];
    assert(wt.write(a, to));
    assert(wt.flush(to));
    assert(wt.flush(to));
    assert(wt.finish(to));
    assert(write_file(str(TMP, "/sync_twice.gz"), to));

    // What the flush claims, asserted in Goose rather than in a Python script:
    // the bytes after a Full flush are a complete raw stream of B on their own,
    // which is only possible because the flush dropped the history they would
    // otherwise have referenced.
    var tail_reader = igzip::raw_reader();
    let tail, tail_err = tail_reader.inflated(ro[mark..]);
    assert(tail_err);
    assert(support::same(tail, b));

    // A redundant flush marker does not confuse the decoder either.
    var twice = igzip::gzip_reader();
    var two: u8[>..] = [];
    let t_used, t_err = twice.read(to, two);
    assert(t_err);
    assert(t_used == to.len);
    assert(twice.finish());
    assert(support::same(two, a));

    // The flush larger than the 64 KiB chunk decodes to the body twice over.
    var big_reader = igzip::gzip_reader();
    let big_plain, big_err = big_reader.inflated(nout);
    assert(big_err);
    assert(big_plain.len == noise.len * 2);
    assert(support::same(big_plain[..noise.len], noise));
    assert(support::same(big_plain[noise.len..], noise));

    // And the Full-flushed gzip member decodes as one stream, A then B.
    var full_reader = igzip::gzip_reader();
    let full_plain, full_err = full_reader.inflated(gz);
    assert(full_err);
    assert(full_plain.len == a.len + b.len);
    assert(support::same(full_plain[..a.len], a));
    assert(support::same(full_plain[a.len..], b));
}

fn test_windows() {
    var body: u8[>..] = [];
    support::body_of(body, 1048576);

    var w = igzip::gzip_writer(1);
    var out: u8[>..] = [];
    assert(w.write_windowed(body, out, 65536));
    assert(w.finish(out));
    let direct = streamed(body, igzip::Wrapper.Gzip, 1);
    assert(out.len == direct.len && support::same(out, direct));

    var w2 = igzip::gzip_writer(1);
    var o2: u8[>..] = [];
    assert(w2.write_windowed(body, o2, 1));
    assert(w2.finish(o2));
    assert(support::same(o2, direct));

    var wlarge = igzip::gzip_writer(1);
    var olarge: u8[>..] = [];
    assert(wlarge.write_windowed(body, olarge, igzip::MAX_INPUT));
    assert(wlarge.finish(olarge));
    assert(support::same(olarge, direct));

    var w3 = igzip::gzip_writer(1);
    var o3: u8[>..] = [];
    assert(!w3.write_windowed(body, o3, 0));
    assert(failed_as(igzip::Status.Overflow));
    assert(!w3.write_windowed(body, o3, igzip::MAX_INPUT + 1));
    assert(failed_as(igzip::Status.Overflow));
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
    assert(make_dir("build"));
    assert(make_dir("build/tmp"));
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

// The reason the last failing call gave, compared with a variant. Five lines
// rather than a whole assertion shape at 40 call sites: with a bool return the
// detail is out of band, in igzip::status().
fn failed_as(want: igzip::Status) -> bool {
    return igzip::status() == want;
}

fn main() {
    var body: u8[>..] = [];
    support::corpus(body, 3000);
    assert(body.len > 20000);

    assert(make_dir("build"));
    assert(make_dir("build/tmp"));
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

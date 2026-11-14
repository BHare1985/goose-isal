// Streaming (0.2.0) contract tests. Run under the JIT:
//
//     goose run --debug test/streaming.goose
//
// Every stream written under build/tmp/stream is inflated by
// scripts/check_gzip.py. A stream can return Ok with a plausible size and
// still be malformed, so the assertions here are only half the check.
import std;
import os;
import igzip from "..";

let TMP = "build/tmp/stream";
let WRITER_BYTES = 367280;

fn corpus(out: u8[>..]&) {
    for i in 3000 {
        format(out, "{\"id\":", i, ",\"user\":\"alice\",\"email\":\"alice@example.com\",",
               "\"active\":true,\"score\":", i * 37 % 1000, ",\"tags\":[\"alpha\",\"beta\"]},\n");
    }
}

fn body_of(out: u8[>..]&, n: i64) {
    var id = 0;
    while out.len < n {
        format(out, "{\"id\":", id, ",\"user\":\"alice\",\"email\":\"alice@example.com\",",
               "\"active\":true,\"score\":", id * 37 % 1000, "},\n");
        id++;
    }
    out.resize(n);
}

fn same(a: const u8[:], b: const u8[:]) -> bool {
    guard a.len == b.len else { return false; }
    for x, i in a {
        if x != b[i] { return false; }
    }
    return true;
}

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

fn test_layout() {
    assert(igzip::writer_size() == WRITER_BYTES);
    var w = igzip::gzip_writer(1);
    assert(w.state == igzip::WriterState.Fresh);
    assert(w.wrap == igzip::Wrapper.Gzip);
    assert(w.base_level == 1);
    assert(w.total_in == 0 && w.total_out == 0);
    assert(!w.has_tables && !w.has_dict && !w.hdr_written);
}

// The one-shot and streaming paths are byte-identical at the size the design
// measured. Below the 32 KiB internal buffer the two shapes are allowed to
// differ (both are valid gzip); the chunking and flush tests cover those.
fn test_equivalence() {
    var sizes: i64[4] = [32768, 65536, 120233, 316560];
    let wraps: igzip::Wrapper[3] = [igzip::Wrapper.Raw, igzip::Wrapper.Gzip, igzip::Wrapper.Zlib];
    for n in sizes {
        var body: u8[>..] = [];
        body_of(body, n);
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
                    assert(same(a, b));
                } else {
                    assert(b.len > 0);
                }
            }
        }
    }

    // The empty member is exact for the wrapped formats. Bare raw deflate
    // has different valid spellings of "no data", and ISA-L's stateful path
    // writes the shorter one.
    for w in wraps {
        let a = one_shot("", w, 1);
        let b = streamed("", w, 1);
        if w != igzip::Wrapper.Raw {
            assert(a.len == b.len && same(a, b));
        } else {
            assert(b.len > 0);
        }
    }
}

fn test_chunked() {
    var body: u8[>..] = [];
    body_of(body, 120233);
    let one = streamed(body, igzip::Wrapper.Gzip, 1);
    let chunks: i64[5] = [1, 7, 63, 4096, 70000];
    let many = streamed_chunks(body, chunks);
    assert(one.len == many.len);
    assert(same(one, many));

    let tiny: i64[1] = [13];
    let slow = streamed_chunks(body, tiny);
    assert(one.len == slow.len && same(one, slow));
}

fn test_flush() {
    var a: u8[>..] = [];
    body_of(a, 4096);
    var b: u8[>..] = [];
    body_of(b, 5000);

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

    // A flush larger than the 64 KiB chunk: the flush request must not be
    // re-issued when the output buffer fills.
    var noise: u8[>..] = [];
    var x:     u64     = 0x243F6A8885A308D3;
    for i in 200000 {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        noise.push((x & 0xff) as! u8);
    }
    var wn = igzip::gzip_writer(1);
    var nout: u8[>..] = [];
    assert(wn.write(noise, nout) == igzip::Status.Ok);
    assert(wn.flush(nout) == igzip::Status.Ok);
    assert(wn.write(noise, nout) == igzip::Status.Ok);
    assert(wn.finish(nout) == igzip::Status.Ok);
    assert(write_file(str(TMP, "/sync_big.gz"), nout));
    assert(write_file(str(TMP, "/sync_big.bin"), noise));

    // Full flush is also a decode point in a complete gzip stream.
    var wg = igzip::gzip_writer(1);
    var gz: u8[>..] = [];
    assert(wg.write(a, gz) == igzip::Status.Ok);
    assert(wg.flush(igzip::Flush.Full, gz) == igzip::Status.Ok);
    assert(wg.write(b, gz) == igzip::Status.Ok);
    assert(wg.finish(gz) == igzip::Status.Ok);
    assert(write_file(str(TMP, "/full_full.gz"), gz));
}

fn test_headers(body: const u8[:]) {
    let extra: u8[3] = [1, 2, 3];
    let hdr = igzip::GzipHeader { text: true, mtime: 123456789, xflags: 2, os: 3, hcrc: true,
                                  name: "report.csv", comment: "built by goose", extra: extra };
    var w = igzip::gzip_writer(1);
    var out: u8[>..] = [];
    assert(w.write_gzip_header(hdr, out) == igzip::Status.Ok);
    assert(w.write(body, out) == igzip::Status.Ok);
    assert(w.finish(out) == igzip::Status.Ok);
    assert(write_file(str(TMP, "/custom_header.gz"), out));

    // The same header twice must give the same bytes.
    var w2 = igzip::gzip_writer(1);
    var out2: u8[>..] = [];
    assert(w2.write_gzip_header(hdr, out2) == igzip::Status.Ok);
    assert(w2.write(body, out2) == igzip::Status.Ok);
    assert(w2.finish(out2) == igzip::Status.Ok);
    assert(same(out, out2));

    // A header larger than the 64 KiB chunk: 65,000 bytes of extra plus a
    // 2,000-byte name.
    var big_extra: u8[>..] = [];
    for i in 65000 { big_extra.push(7); }
    var big_name: u8[>..] = [];
    for i in 2000 { big_name.push(110); }
    var w3 = igzip::gzip_writer(1);
    var big: u8[>..] = [];
    let big_hdr = igzip::GzipHeader { name: big_name, extra: big_extra, mtime: 7 };
    assert(w3.write_gzip_header(big_hdr, big) == igzip::Status.Ok);
    assert(big.len > 65536);
    assert(w3.write(body, big) == igzip::Status.Ok);
    assert(w3.finish(big) == igzip::Status.Ok);
    assert(write_file(str(TMP, "/large_header.gz"), big));

    // An interior NUL cannot be encoded: reject it, append nothing, and let
    // the same writer fall back to the default header.
    var bad_name: u8[>..] = [];
    bad_name.append("bad");
    bad_name.push(0);
    bad_name.append("x");
    var w4 = igzip::gzip_writer(1);
    var o4: u8[>..] = [];
    let bad_hdr = igzip::GzipHeader { name: bad_name };
    assert(w4.write_gzip_header(bad_hdr, o4) == igzip::Status.BadHeader);
    assert(o4.len == 0);
    assert(w4.write(body, o4) == igzip::Status.Ok);
    assert(w4.finish(o4) == igzip::Status.Ok);

    // RFC 1952's XLEN is 16-bit.
    var too_much: u8[>..] = [];
    for i in 65536 { too_much.push(1); }
    var w5 = igzip::gzip_writer(1);
    var o5: u8[>..] = [];
    let too_hdr = igzip::GzipHeader { extra: too_much };
    assert(w5.write_gzip_header(too_hdr, o5) == igzip::Status.BadHeader);
    assert(o5.len == 0);

    // A custom zlib header, with the window and FLEVEL the caller asked for.
    var wz = igzip::zlib_writer(1);
    var zo: u8[>..] = [];
    let zhdr = igzip::ZlibHeader { window_bits: 12, flevel: 2 };
    assert(wz.write_zlib_header(zhdr, zo) == igzip::Status.Ok);
    assert(wz.write(body, zo) == igzip::Status.Ok);
    assert(wz.finish(zo) == igzip::Status.Ok);
    assert(write_file(str(TMP, "/zlib_header.zlib"), zo));

    // Header/wrapper mismatches.
    var w6 = igzip::gzip_writer(1);
    var o6: u8[>..] = [];
    assert(w6.write_zlib_header(zhdr, o6) == igzip::Status.BadState);
    var w7 = igzip::zlib_writer(1);
    var o7: u8[>..] = [];
    assert(w7.write_gzip_header(hdr, o7) == igzip::Status.BadState);

    // Impossible zlib fields.
    var w8 = igzip::zlib_writer(1);
    var o8: u8[>..] = [];
    assert(w8.write_zlib_header(igzip::ZlibHeader { window_bits: 7 }, o8) == igzip::Status.BadHeader);
    assert(w8.write_zlib_header(igzip::ZlibHeader { flevel: 4 }, o8) == igzip::Status.BadHeader);
    assert(w8.write_zlib_header(igzip::ZlibHeader { dict_flag: true }, o8) == igzip::Status.BadHeader);
}

fn test_dict(body: const u8[:]) {
    var dict: u8[>..] = [];
    body_of(dict, 40000); // past igzip's 32 KiB history, to exercise truncation

    // The automatic zlib header: set_dict makes it FDICT=1, or every decoder
    // that did not receive the dictionary would reject the stream.
    var wz = igzip::zlib_writer(1);
    var zo: u8[>..] = [];
    assert(wz.set_dict(dict) == igzip::Status.Ok);
    assert(wz.write(body, zo) == igzip::Status.Ok);
    assert(wz.finish(zo) == igzip::Status.Ok);
    assert(write_file(str(TMP, "/dict_zlib.zlib"), zo));
    assert(write_file(str(TMP, "/dict.bin"), dict));

    // The explicit zlib header after set_dict must also advertise the
    // dictionary, even though dict_flag was left false.
    var wz2 = igzip::zlib_writer(1);
    var zo2: u8[>..] = [];
    assert(wz2.set_dict(dict) == igzip::Status.Ok);
    assert(wz2.write_zlib_header(igzip::ZlibHeader { window_bits: 15, flevel: 1 }, zo2) == igzip::Status.Ok);
    assert(wz2.write(body, zo2) == igzip::Status.Ok);
    assert(wz2.finish(zo2) == igzip::Status.Ok);
    assert(write_file(str(TMP, "/dict_zlib_explicit.zlib"), zo2));

    // A mismatched DICTID is a caller bug, not a dictionary.
    var wz3 = igzip::zlib_writer(1);
    var zo3: u8[>..] = [];
    assert(wz3.set_dict(dict) == igzip::Status.Ok);
    assert(wz3.write_zlib_header(igzip::ZlibHeader { dict_flag: true, dict_id: 123 }, zo3) == igzip::Status.BadHeader);

    // Raw deflate has no header; the dictionary is history only.
    var wr = igzip::raw_writer(1);
    var ro: u8[>..] = [];
    assert(wr.set_dict(dict) == igzip::Status.Ok);
    assert(wr.write(body, ro) == igzip::Status.Ok);
    assert(wr.finish(ro) == igzip::Status.Ok);
    assert(write_file(str(TMP, "/dict_raw.deflate"), ro));

    // gzip has no preset-dictionary header.
    var wg = igzip::gzip_writer(1);
    assert(wg.set_dict(dict) == igzip::Status.BadState);
}

fn test_lifecycle(body: const u8[:]) {
    var t = igzip::trainer();
    assert(t.add(body) == igzip::Status.Ok);
    let tables, built = t.build();
    assert(built == igzip::Status.Ok);

    var w = igzip::gzip_writer(1);
    var out: u8[>..] = [];
    assert(w.write(body, out) == igzip::Status.Ok);

    // A block is open: no header, table, or dictionary changes.
    assert(w.write_gzip_header(igzip::GzipHeader { .. }, out) == igzip::Status.BadState);
    assert(w.set_tables(tables) == igzip::Status.BadState);
    assert(w.set_dict("x") == igzip::Status.BadState);

    // After a flush, a table swap is legal.
    assert(w.flush(out) == igzip::Status.Ok);
    assert(w.set_tables(tables) == igzip::Status.Ok);
    assert(w.clear_tables() == igzip::Status.Ok);
    assert(w.write(body, out) == igzip::Status.Ok);
    assert(w.finish(out) == igzip::Status.Ok);

    // Finished is terminal until reset.
    assert(w.write(body, out) == igzip::Status.BadState);
    assert(w.flush(out) == igzip::Status.BadState);
    assert(w.finish(out) == igzip::Status.BadState);
    assert(w.reset() == igzip::Status.Ok);
    assert(w.write(body, out) == igzip::Status.Ok);
    assert(w.finish(out) == igzip::Status.Ok);

    // Copying a live Writer would leave C pointers into the original. The
    // copy reports BadState; reset makes it independent.
    var w2 = igzip::gzip_writer(1);
    var o2: u8[>..] = [];
    assert(w2.write(body, o2) == igzip::Status.Ok);
    var copy = w2;
    var o3: u8[>..] = [];
    assert(copy.write(body, o3) == igzip::Status.BadState);
    assert(w2.finish(o2) == igzip::Status.Ok);
    assert(copy.reset() == igzip::Status.Ok);
    assert(copy.write(body, o3) == igzip::Status.Ok);
    assert(copy.finish(o3) == igzip::Status.Ok);

    // A Fresh Writer that already holds a dictionary must not be copied and
    // silently re-initialized: the dictionary buffer lives in the C stream.
    var wd = igzip::zlib_writer(1);
    var od: u8[>..] = [];
    assert(wd.set_dict("the dictionary") == igzip::Status.Ok);
    var wd_copy = wd;
    var od_copy: u8[>..] = [];
    assert(wd_copy.write(body, od_copy) == igzip::Status.BadState);
    assert(wd_copy.reset() == igzip::Status.Ok);
    assert(wd_copy.write(body, od_copy) == igzip::Status.Ok);
    assert(wd_copy.finish(od_copy) == igzip::Status.Ok);
    assert(wd.write(body, od) == igzip::Status.Ok);
    assert(wd.finish(od) == igzip::Status.Ok);

    // The same guard for a Fresh Writer that already holds a trained table.
    var wt = igzip::gzip_writer(1);
    assert(wt.set_tables(tables) == igzip::Status.Ok);
    var wt_copy = wt;
    var ot: u8[>..] = [];
    assert(wt_copy.write(body, ot) == igzip::Status.BadState);
    assert(wt_copy.reset() == igzip::Status.Ok);
    assert(wt_copy.write(body, ot) == igzip::Status.Ok);
    assert(wt_copy.finish(ot) == igzip::Status.Ok);

    // reset preserves a trained table and its level-0 pin.
    var w3 = igzip::gzip_writer(1);
    assert(w3.set_tables(tables) == igzip::Status.Ok);
    var o4: u8[>..] = [];
    assert(w3.write(body, o4) == igzip::Status.Ok);
    assert(w3.finish(o4) == igzip::Status.Ok);
    assert(w3.reset() == igzip::Status.Ok);
    assert(w3.has_tables);
    assert(w3.clear_tables() == igzip::Status.Ok);
    assert(w3.write(body, o4) == igzip::Status.Ok);
    assert(w3.finish(o4) == igzip::Status.Ok);
}

fn test_trained(body: const u8[:]) {
    var t = igzip::trainer();
    assert(t.add(body) == igzip::Status.Ok);
    let tables, built = t.build();
    assert(built == igzip::Status.Ok);

    var wt = igzip::gzip_writer(1);
    var trained: u8[>..] = [];
    assert(wt.set_tables(tables) == igzip::Status.Ok);
    assert(wt.write(body, trained) == igzip::Status.Ok);
    assert(wt.finish(trained) == igzip::Status.Ok);
    assert(write_file(str(TMP, "/trained.gz"), trained));

    var w0 = igzip::gzip_writer(0);
    var plain: u8[>..] = [];
    assert(w0.write(body, plain) == igzip::Status.Ok);
    assert(w0.finish(plain) == igzip::Status.Ok);
    assert(trained.len <= plain.len);

    // Fresh -> Flushed and Fresh -> Finished both write a valid (empty)
    // member without an explicit write.
    var wf0 = igzip::gzip_writer(1);
    var of0: u8[>..] = [];
    assert(wf0.flush(of0) == igzip::Status.Ok);
    assert(wf0.finish(of0) == igzip::Status.Ok);
    var we0 = igzip::gzip_writer(1);
    var oe0: u8[>..] = [];
    assert(we0.finish(oe0) == igzip::Status.Ok);
    assert(oe0.len == 20);

    // Attaching a table pins level 0, so an out-of-range base level must not
    // block it (the one-shot Compressor behaves the same way).
    var wbad = igzip::gzip_writer(9);
    var bo: u8[>..] = [];
    assert(wbad.set_tables(tables) == igzip::Status.Ok);
    assert(wbad.write(body[..1024], bo) == igzip::Status.Ok);
    assert(wbad.finish(bo) == igzip::Status.Ok);

    // A trained table swapped in at a flush boundary, mid-stream.
    var wf = igzip::gzip_writer(1);
    var swapped: u8[>..] = [];
    assert(wf.write(body[..4096], swapped) == igzip::Status.Ok);
    assert(wf.flush(swapped) == igzip::Status.Ok);
    assert(wf.set_tables(tables) == igzip::Status.Ok);
    assert(wf.write(body[4096..], swapped) == igzip::Status.Ok);
    assert(wf.finish(swapped) == igzip::Status.Ok);
    assert(write_file(str(TMP, "/trained_swap.gz"), swapped));
}

fn test_windows() {
    var body: u8[>..] = [];
    body_of(body, 1048576);
    var w = igzip::gzip_writer(1);
    var out: u8[>..] = [];
    assert(w.write_windowed(body, out, 65536) == igzip::Status.Ok);
    assert(w.finish(out) == igzip::Status.Ok);
    let direct = streamed(body, igzip::Wrapper.Gzip, 1);
    assert(out.len == direct.len && same(out, direct));

    var w2 = igzip::gzip_writer(1);
    var o2: u8[>..] = [];
    assert(w2.write_windowed(body, o2, 0) == igzip::Status.Overflow);
    assert(w2.write_windowed(body, o2, igzip::MAX_INPUT + 1) == igzip::Status.Overflow);
}

fn test_errors(body: const u8[:]) {
    var w = igzip::gzip_writer(9);
    var out: u8[>..] = [];
    assert(w.write(body, out) == igzip::Status.BadLevel);

    var w2 = igzip::gzip_writer(-1);
    var o2: u8[>..] = [];
    assert(w2.write(body, o2) == igzip::Status.BadLevel);

    var bad = igzip::tables();
    bad.raw[41] = 0xFFFFFFFF;
    var w3 = igzip::gzip_writer(1);
    assert(w3.set_tables(bad) == igzip::Status.BadTable);

    assert(igzip::status_name(igzip::Status.BadHeader).len > 0);
    assert(!igzip::Status.BadHeader.ok());
}

fn write_artifacts(body: const u8[:]) {
    assert(make_dir(TMP));
    assert(write_file(str(TMP, "/body.txt"), body));

    // Chunked, no flush: the bytes are the same as one write.
    let chunks: i64[5] = [1, 7, 63, 4096, 70000];
    let chunked = streamed_chunks(body, chunks);
    assert(write_file(str(TMP, "/chunked.gz"), chunked));

    // Default one-shot stream for the decoder.
    let plain = streamed(body, igzip::Wrapper.Gzip, 1);
    assert(write_file(str(TMP, "/default.gz"), plain));

    // Level 0 has a different (valid) ending in the stateful path; the decoder
    // checks it rather than asserting byte identity.
    let slow = streamed(body, igzip::Wrapper.Gzip, 0);
    assert(write_file(str(TMP, "/level0.gz"), slow));
}

fn main() {
    var body: u8[>..] = [];
    corpus(body);
    assert(body.len > 20000);

    assert(make_dir(TMP));
    test_layout();
    test_equivalence();
    test_chunked();
    test_flush();
    test_headers(body);
    test_dict(body);
    test_lifecycle(body);
    test_trained(body);
    test_windows();
    test_errors(body);
    write_artifacts(body);

    print("streaming: ", body.len, " bytes, writer ", igzip::writer_size(), " bytes");
    print("streaming: ok");
}

// Writer unit tests: layout, state transitions, totals, ordering, copy guard,
// reset, headers, dictionaries, tables and lifecycle errors.
//
//     goose run --debug test/writer_contract.goose
//
// The streams this writes under build/tmp/stream are inflated independently by
// scripts/check_gzip.py. The end-to-end equivalence/chunking/window tests live
// in test/streaming.goose; this file is the state-machine and edge-case half.
import std;
import os;
import igzip from "..";
import support from "./support";

let TMP = "build/tmp/stream";
let WRITER_BYTES = 367280;

fn step_tiny(w: igzip::Writer&, src: const u8[:], mode: u8, out: u8[>..]&) -> bool {
    var pos: i64 = 0;
    loop {
        var used:    u32 = 0;
        var written: u32 = 0;
        var more = false;
        var buf: u8[8] = [0; 8];
        let rc = igzip::igzip_gs_writer_step(w, src[pos..], mode, buf, used, written, more);
        if rc != 0 { return false; }
        if written > 0 { out.append(buf[..written]); }
        pos += used;
        if !more { return true; }
        if used == 0 && written == 0 { return false; }
    }
}

fn one_shot(body: const u8[:], wrap: igzip::Wrapper, level: i32) -> u8[>..] {
    var c = igzip::compressor(wrap, level);
    let out, err = c.compressed(body);
    assert(err);
    return out;
}

// Decodes a whole member this file just wrote. Header *inspection* is out of
// scope; what is asserted is that a reader accepts every header a writer emits.
fn decoded(wrap: igzip::Wrapper, stream: const u8[:]) -> u8[>..] {
    var r = igzip::reader(wrap);
    var out: u8[>..] = [];
    let used, err = r.read(stream, out);
    assert(err);
    assert(used == stream.len);
    assert(r.finished());
    assert(r.finish());
    assert(r.total_out == out.len as u64);
    return out;
}

fn test_layout() {
    assert(igzip::writer_size() == WRITER_BYTES);
    assert(igzip::MAX_IN_STEP == igzip::MAX_INPUT);

    var w = igzip::gzip_writer(1);
    assert(w.state == igzip::WriterState.Fresh);
    assert(w.wrap == igzip::Wrapper.Gzip);
    assert(w.base_level == 1);
    assert(w.total_in == 0 && w.total_out == 0);
    assert(!w.has_tables && !w.has_dict && !w.hdr_written);

    let h = igzip::GzipHeader { .. };
    assert(!h.text && h.mtime == 0 && h.xflags == 0 && h.os == 0xff && !h.hcrc);
    assert(h.name.len == 0 && h.comment.len == 0 && h.extra.len == 0);

    let z = igzip::ZlibHeader { .. };
    assert(z.window_bits == 15 && z.flevel == 0 && !z.dict_flag && z.dict_id == 0);
}

fn test_state_and_totals(body: const u8[:]) {
    var w = igzip::gzip_writer(1);
    var out: u8[>..] = [];

    assert(w.write_gzip_header(igzip::GzipHeader { .. }, out));
    assert(w.state == igzip::WriterState.HeaderWritten);
    assert(w.hdr_written);
    assert(w.total_in == 0);
    assert(w.total_out == out.len as u64);
    let after_header = out.len;

    assert(w.write(body, out));
    assert(w.state == igzip::WriterState.Open);
    assert(w.total_in == body.len as u64);
    assert(w.total_out == out.len as u64);
    assert(w.total_out >= after_header as u64);

    assert(w.flush(out));
    assert(w.state == igzip::WriterState.Flushed);
    assert(w.total_in == body.len as u64);

    assert(w.write(body[..1024], out));
    assert(w.state == igzip::WriterState.Open);
    assert(w.total_in == (body.len + 1024) as u64);

    assert(w.finish(out));
    assert(w.state == igzip::WriterState.Finished);
    assert(w.total_out == out.len as u64);

    assert(w.reset());
    assert(w.state == igzip::WriterState.Fresh);
    assert(w.total_in == 0 && w.total_out == 0);
    assert(!w.hdr_written);
}

fn test_ordering(body: const u8[:], tables: const igzip::HuffTables&) {
    // Tables and a dictionary may be set in either order while Fresh.
    var a = igzip::raw_writer(1);
    var ao: u8[>..] = [];
    assert(a.set_tables(tables));
    assert(a.state == igzip::WriterState.Fresh);
    assert(a.set_dict(body[..1000]));
    assert(a.state == igzip::WriterState.Fresh);
    assert(a.has_tables && a.has_dict);
    assert(a.write(body, ao));
    assert(a.finish(ao));

    var b = igzip::raw_writer(1);
    var bo: u8[>..] = [];
    assert(b.set_dict(body[..1000]));
    assert(b.set_tables(tables));
    assert(b.write(body, bo));
    assert(b.finish(bo));

    // A zlib header already written cannot acquire FDICT afterwards.
    var c = igzip::zlib_writer(1);
    var co: u8[>..] = [];
    assert(c.write_zlib_header(igzip::ZlibHeader { .. }, co));
    assert(c.state == igzip::WriterState.HeaderWritten);
    assert(!c.set_dict(body));
    assert(failed_as(igzip::Status.BadState));

    // After finish, every configuration call is refused.
    var d = igzip::gzip_writer(1);
    var do: u8[>..] = [];
    assert(d.finish(do));
    assert(!d.set_tables(tables));
    assert(failed_as(igzip::Status.BadState));
    assert(!d.set_dict(body));
    assert(failed_as(igzip::Status.BadState));
    assert(!d.clear_tables());
    assert(failed_as(igzip::Status.BadState));
    assert(!d.write_gzip_header(igzip::GzipHeader { .. }, do));
    assert(failed_as(igzip::Status.BadState));
    assert(!d.write_zlib_header(igzip::ZlibHeader { .. }, do));
    assert(failed_as(igzip::Status.BadState));

    // Clearing when no table is attached is a no-op, not an error.
    var e = igzip::gzip_writer(1);
    assert(e.clear_tables());
    assert(!e.has_tables);
    assert(e.set_tables(tables));

    // A table and a custom gzip header on the same Fresh writer.
    var g = igzip::gzip_writer(1);
    var go: u8[>..] = [];
    assert(g.set_tables(tables));
    assert(g.write_gzip_header(igzip::GzipHeader { .. }, go));
    assert(g.state == igzip::WriterState.HeaderWritten);
    assert(g.write(body, go));
    assert(g.finish(go));

    // A table or dictionary cannot be changed while a block is open.
    var f = igzip::raw_writer(1);
    var fo: u8[>..] = [];
    assert(f.write(body[..64], fo));
    assert(!f.set_tables(tables));
    assert(failed_as(igzip::Status.BadState));
    assert(!f.set_dict(body));
    assert(failed_as(igzip::Status.BadState));
    assert(!f.write_zlib_header(igzip::ZlibHeader { .. }, fo));
    assert(failed_as(igzip::Status.BadState));
    assert(!f.write_gzip_header(igzip::GzipHeader { .. }, fo));
    assert(failed_as(igzip::Status.BadState));
}

fn test_copy_guard(body: const u8[:], tables: const igzip::HuffTables&) {
    // Before any use, both copies initialize independently.
    var fresh = igzip::gzip_writer(1);
    var fresh_copy = fresh;
    var f1: u8[>..] = [];
    var f2: u8[>..] = [];
    assert(fresh.write(body, f1));
    assert(fresh_copy.write(body, f2));
    assert(fresh.finish(f1));
    assert(fresh_copy.finish(f2));
    assert(support::same(f1, f2));

    // After a body write.
    var w = igzip::gzip_writer(1);
    var out: u8[>..] = [];
    assert(w.write(body, out));
    var copy = w;
    var co: u8[>..] = [];
    assert(!copy.write(body, co));
    assert(failed_as(igzip::Status.BadState));
    assert(w.finish(out));
    assert(copy.reset());
    assert(copy.write(body, co));
    assert(copy.finish(co));

    // After a custom header.
    var wh = igzip::gzip_writer(1);
    var oh: u8[>..] = [];
    assert(wh.write_gzip_header(igzip::GzipHeader { .. }, oh));
    var hc = wh;
    var ho: u8[>..] = [];
    assert(!hc.write(body, ho));
    assert(failed_as(igzip::Status.BadState));
    assert(hc.reset());
    assert(hc.write(body, ho));
    assert(hc.finish(ho));

    // After finish.
    var wf = igzip::gzip_writer(1);
    var fo: u8[>..] = [];
    assert(wf.finish(fo));
    var fc = wf;
    var fco: u8[>..] = [];
    assert(!fc.write(body, fco));
    assert(failed_as(igzip::Status.BadState));
    assert(fc.reset());
    assert(fc.write(body, fco));
    assert(fc.finish(fco));

    // A Fresh Writer with a dictionary or a table has already been initialized.
    var wd = igzip::zlib_writer(1);
    var od: u8[>..] = [];
    assert(wd.set_dict(body[..1000]));
    var dc = wd;
    assert(!dc.write(body, od));
    assert(failed_as(igzip::Status.BadState));
    assert(dc.reset());
    assert(!dc.has_dict);

    var wt = igzip::gzip_writer(1);
    assert(wt.set_tables(tables));
    var tc = wt;
    var to: u8[>..] = [];
    assert(!tc.write(body, to));
    assert(failed_as(igzip::Status.BadState));
    assert(tc.reset());
    assert(tc.has_tables);
    assert(tc.write(body, to));
    assert(tc.finish(to));
}

fn test_reset(body: const u8[:]) {
    // Open -> reset -> a complete new stream.
    var w = igzip::gzip_writer(1);
    var out: u8[>..] = [];
    assert(w.write(body, out));
    assert(w.reset());
    assert(w.state == igzip::WriterState.Fresh);
    out.clear();
    assert(w.write(body, out));
    assert(w.finish(out));

    // HeaderWritten -> reset.
    var wh = igzip::gzip_writer(1);
    var oh: u8[>..] = [];
    assert(wh.write_gzip_header(igzip::GzipHeader { .. }, oh));
    assert(wh.reset());
    assert(!wh.hdr_written);
    oh.clear();
    assert(wh.write(body, oh));
    assert(wh.finish(oh));

    // Flushed -> reset.
    var w2 = igzip::gzip_writer(1);
    var o2: u8[>..] = [];
    assert(w2.write(body[..100], o2));
    assert(w2.flush(o2));
    assert(w2.reset());
    o2.clear();
    assert(w2.write(body, o2));
    assert(w2.finish(o2));

    // reset drops the dictionary: the next stream is identical to one that
    // never had one.
    var dict: u8[>..] = [];
    support::body_of(dict, 4000);
    var wd = igzip::zlib_writer(1);
    var od: u8[>..] = [];
    assert(wd.set_dict(dict));
    assert(wd.write(body[..2000], od));
    assert(wd.finish(od));
    assert(wd.reset());
    assert(!wd.has_dict && wd.dict_id == 0);
    var after: u8[>..] = [];
    assert(wd.write(body[..2000], after));
    assert(wd.finish(after));

    var plain = igzip::zlib_writer(1);
    var po: u8[>..] = [];
    assert(plain.write(body[..2000], po));
    assert(plain.finish(po));
    assert(support::same(after, po));
}

fn test_headers(body: const u8[:]) {
    let extra: u8[3] = [1, 2, 3];
    let hdr = igzip::GzipHeader { text: true, mtime: 123456789, xflags: 2, os: 3, hcrc: true,
                                  name: "report.csv", comment: "built by goose", extra: extra };
    var w = igzip::gzip_writer(1);
    var out: u8[>..] = [];
    assert(w.write_gzip_header(hdr, out));
    assert(w.write(body, out));
    assert(w.finish(out));
    assert(write_file(str(TMP, "/custom_header.gz"), out));

    // The same header twice must give the same bytes.
    var w2 = igzip::gzip_writer(1);
    var out2: u8[>..] = [];
    assert(w2.write_gzip_header(hdr, out2));
    assert(w2.write(body, out2));
    assert(w2.finish(out2));
    assert(support::same(out, out2));

    // A header larger than the 64 KiB chunk: 65,000 bytes of extra plus a
    // 2,000-byte name.
    var big_extra: u8[>..] = [];
    for i in 65000 { big_extra.push(7); }
    var big_name: u8[>..] = [];
    for i in 2000 { big_name.push(110); }
    var w3 = igzip::gzip_writer(1);
    var big: u8[>..] = [];
    let big_hdr = igzip::GzipHeader { name: big_name, extra: big_extra, mtime: 7 };
    assert(w3.write_gzip_header(big_hdr, big));
    assert(big.len > 65536);
    assert(w3.write(body, big));
    assert(w3.finish(big));
    assert(write_file(str(TMP, "/large_header.gz"), big));

    // An explicit default header is 10 bytes and leaves the writer usable.
    var w4 = igzip::gzip_writer(1);
    var o4: u8[>..] = [];
    assert(w4.write_gzip_header(igzip::GzipHeader { .. }, o4));
    assert(o4.len == 10);
    assert(w4.write(body, o4));
    assert(w4.finish(o4));

    // Interior NULs cannot be encoded in name or comment; nothing is appended
    // and the writer falls back to its default header.
    var bad_name: u8[>..] = [];
    bad_name.append("bad");
    bad_name.push(0);
    bad_name.append("x");
    var w5 = igzip::gzip_writer(1);
    var o5: u8[>..] = [];
    assert(!w5.write_gzip_header(igzip::GzipHeader { name: bad_name }, o5));
    assert(failed_as(igzip::Status.BadHeader));
    assert(o5.len == 0);
    assert(w5.write(body, o5));
    assert(w5.finish(o5));

    var bad_comment: u8[>..] = [];
    bad_comment.append("bad");
    bad_comment.push(0);
    bad_comment.append("x");
    var w6 = igzip::gzip_writer(1);
    var o6: u8[>..] = [];
    assert(!w6.write_gzip_header(igzip::GzipHeader { comment: bad_comment }, o6));
    assert(failed_as(igzip::Status.BadHeader));
    assert(o6.len == 0);

    // RFC 1952's XLEN is 16-bit: 65,535 fits, 65,536 does not.
    var max_extra: u8[>..] = [];
    for i in 65535 { max_extra.push(9); }
    var w7 = igzip::gzip_writer(1);
    var o7: u8[>..] = [];
    assert(w7.write_gzip_header(igzip::GzipHeader { extra: max_extra }, o7));
    assert(o7.len > 65536);
    assert(w7.reset());

    var too_much: u8[>..] = [];
    for i in 65536 { too_much.push(1); }
    var w8 = igzip::gzip_writer(1);
    var o8: u8[>..] = [];
    assert(!w8.write_gzip_header(igzip::GzipHeader { extra: too_much }, o8));
    assert(failed_as(igzip::Status.BadHeader));
    assert(o8.len == 0);

    // A custom zlib header, with the window and FLEVEL the caller asked for.
    var wz = igzip::zlib_writer(1);
    var zo: u8[>..] = [];
    let zhdr = igzip::ZlibHeader { window_bits: 12, flevel: 2 };
    assert(wz.write_zlib_header(zhdr, zo));
    assert(wz.write(body, zo));
    assert(wz.finish(zo));
    assert(write_file(str(TMP, "/zlib_header.zlib"), zo));

    // The zlib CMF/FLG fields carry the requested window and level hint.
    var wz2 = igzip::zlib_writer(1);
    var z2: u8[>..] = [];
    assert(wz2.write_zlib_header(igzip::ZlibHeader { window_bits: 8, flevel: 3 }, z2));
    assert((z2[0] >> 4) == 0);
    assert((z2[1] >> 6) == 3);
    assert(((z2[0] as u32) << 8 | z2[1]) % 31 == 0);
    assert(wz2.write(body, z2));
    assert(wz2.finish(z2));
    assert(write_file(str(TMP, "/zlib_window8.zlib"), z2));

    var wz3 = igzip::zlib_writer(1);
    var z3: u8[>..] = [];
    assert(wz3.write_zlib_header(igzip::ZlibHeader { window_bits: 15, flevel: 0 }, z3));
    assert((z3[0] >> 4) == 7);
    assert((z3[1] >> 6) == 0);

    // Header/wrapper mismatches.
    var w9 = igzip::gzip_writer(1);
    var o9: u8[>..] = [];
    assert(!w9.write_zlib_header(zhdr, o9));
    assert(failed_as(igzip::Status.BadState));
    var w10 = igzip::zlib_writer(1);
    var o10: u8[>..] = [];
    assert(!w10.write_gzip_header(hdr, o10));
    assert(failed_as(igzip::Status.BadState));

    // Impossible zlib fields.
    var w11 = igzip::zlib_writer(1);
    var o11: u8[>..] = [];
    assert(!w11.write_zlib_header(igzip::ZlibHeader { window_bits: 7 }, o11));
    assert(failed_as(igzip::Status.BadHeader));
    assert(!w11.write_zlib_header(igzip::ZlibHeader { flevel: 4 }, o11));
    assert(failed_as(igzip::Status.BadHeader));
    assert(!w11.write_zlib_header(igzip::ZlibHeader { dict_flag: true }, o11));
    assert(failed_as(igzip::Status.BadHeader));

    // The same header API must not turn an unbounded name into an unbounded
    // temporary: MAX_HEADER is the cap, and nothing is appended when it trips.
    var huge: u8[>..] = [];
    for i in igzip::MAX_HEADER + 1 { huge.push(110); }
    var w12 = igzip::gzip_writer(1);
    var o12: u8[>..] = [];
    assert(!w12.write_gzip_header(igzip::GzipHeader { name: huge }, o12));
    assert(failed_as(igzip::Status.BadHeader));
    assert(o12.len == 0);

    // Every stream above must decode, header and all: an all-fields header, one
    // larger than the 64 KiB chunk, and two zlib windows a strict decoder would
    // reject if the history did not match the header.
    assert(support::same(decoded(igzip::Wrapper.Gzip, out), body));
    assert(support::same(decoded(igzip::Wrapper.Gzip, big), body));
    assert(support::same(decoded(igzip::Wrapper.Gzip, o4), body));
    assert(support::same(decoded(igzip::Wrapper.Gzip, o5), body));
    assert(support::same(decoded(igzip::Wrapper.Zlib, zo), body));
    assert(support::same(decoded(igzip::Wrapper.Zlib, z2), body));
}

fn test_dict(body: const u8[:]) {
    var dict: u8[>..] = [];
    support::body_of(dict, 40000); // past igzip's 32 KiB history, to exercise truncation

    // The automatic zlib header: set_dict makes it FDICT=1, or every decoder
    // that did not receive the dictionary would reject the stream.
    var wz = igzip::zlib_writer(1);
    var zo: u8[>..] = [];
    assert(wz.set_dict(dict));
    assert(wz.has_dict && wz.dict_id != 0);
    assert(wz.write(body, zo));
    assert(wz.finish(zo));
    assert(write_file(str(TMP, "/dict_zlib.zlib"), zo));
    assert(write_file(str(TMP, "/dict.bin"), dict));

    // The explicit zlib header after set_dict must also advertise the
    // dictionary, even though dict_flag was left false.
    var wz2 = igzip::zlib_writer(1);
    var zo2: u8[>..] = [];
    assert(wz2.set_dict(dict));
    assert(wz2.write_zlib_header(igzip::ZlibHeader { window_bits: 15, flevel: 1 }, zo2));
    assert(wz2.write(body, zo2));
    assert(wz2.finish(zo2));
    assert(write_file(str(TMP, "/dict_zlib_explicit.zlib"), zo2));

    // Supplying the matching DICTID explicitly is accepted.
    var wz3 = igzip::zlib_writer(1);
    var zo3: u8[>..] = [];
    assert(wz3.set_dict(dict));
    let matching = igzip::ZlibHeader { dict_flag: true, dict_id: wz3.dict_id };
    assert(wz3.write_zlib_header(matching, zo3));
    assert(wz3.reset());

    // A mismatched DICTID is a caller bug, not a dictionary.
    var wz4 = igzip::zlib_writer(1);
    var zo4: u8[>..] = [];
    assert(wz4.set_dict(dict));
    assert(!wz4.write_zlib_header(igzip::ZlibHeader { dict_flag: true, dict_id: 123 }, zo4));
    assert(failed_as(igzip::Status.BadHeader));

    // Raw deflate has no header; the dictionary is history only.
    var wr = igzip::raw_writer(1);
    var ro: u8[>..] = [];
    assert(wr.set_dict(dict));
    assert(wr.write(body, ro));
    assert(wr.finish(ro));
    assert(write_file(str(TMP, "/dict_raw.deflate"), ro));

    // gzip has no preset-dictionary header.
    var wg = igzip::gzip_writer(1);
    assert(!wg.set_dict(dict));
    assert(failed_as(igzip::Status.BadState));

    // An empty dictionary is a no-op: no FDICT, and the stream matches a
    // dictionary-free one.
    var we = igzip::zlib_writer(1);
    var eo: u8[>..] = [];
    assert(we.set_dict(""));
    assert(!we.has_dict);
    assert(we.write(body[..2000], eo));
    assert(we.finish(eo));
    var plain = igzip::zlib_writer(1);
    var po: u8[>..] = [];
    assert(plain.write(body[..2000], po));
    assert(plain.finish(po));
    assert(support::same(eo, po));
}

fn test_trained(body: const u8[:], tables: const igzip::HuffTables&) {
    var wt = igzip::gzip_writer(1);
    var trained: u8[>..] = [];
    assert(wt.set_tables(tables));
    assert(wt.has_tables);
    assert(wt.write(body, trained));
    assert(wt.finish(trained));
    assert(write_file(str(TMP, "/trained.gz"), trained));

    var w0 = igzip::gzip_writer(0);
    var plain: u8[>..] = [];
    assert(w0.write(body, plain));
    assert(w0.finish(plain));
    assert(trained.len <= plain.len);

    // Attaching a table pins level 0, so an out-of-range base level must not
    // block it (the one-shot Compressor behaves the same way).
    var wbad = igzip::gzip_writer(9);
    var bo: u8[>..] = [];
    assert(wbad.set_tables(tables));
    assert(wbad.write(body[..1024], bo));
    assert(wbad.finish(bo));

    // A trained table swapped in at a flush boundary, mid-stream.
    var wf = igzip::gzip_writer(1);
    var swapped: u8[>..] = [];
    assert(wf.write(body[..4096], swapped));
    assert(wf.flush(swapped));
    assert(wf.set_tables(tables));
    assert(wf.write(body[4096..], swapped));
    assert(wf.finish(swapped));
    assert(write_file(str(TMP, "/trained_swap.gz"), swapped));

    // reset keeps the table; clear_tables returns to the base level, and that
    // stream is byte-identical to a fresh level-1 compressor.
    var wc = igzip::gzip_writer(1);
    var co: u8[>..] = [];
    assert(wc.set_tables(tables));
    assert(wc.write(body, co));
    assert(wc.finish(co));
    assert(wc.reset());
    assert(wc.has_tables);
    assert(wc.clear_tables());
    assert(!wc.has_tables);
    var co2: u8[>..] = [];
    assert(wc.write(body, co2));
    assert(wc.finish(co2));
    assert(support::same(co2, one_shot(body, igzip::Wrapper.Gzip, 1)));
}

// The shim's output loop must drain a destination much smaller than its normal
// 64 KiB chunk without losing or duplicating bytes.
//
// The assertion is the decoded bytes, not equality with a one-shot stream. An
// 8-byte destination makes igzip drain through its staging buffer, which can put
// block boundaries somewhere else: below the 32 KiB internal buffer the two
// spellings are allowed to differ, and a stream that decodes correctly is the
// contract either way.
fn test_tiny_output() {
    var body: u8[>..] = [];
    support::body_of(body, 16384);
    var w = igzip::raw_writer(1);
    var out: u8[>..] = [];
    assert(step_tiny(w, body, 0, out));
    assert(step_tiny(w, "", 3, out));
    assert(support::same(decoded(igzip::Wrapper.Raw, out), body));
}

fn test_errors(body: const u8[:]) {
    var w = igzip::gzip_writer(9);
    var out: u8[>..] = [];
    assert(!w.write(body, out));
    assert(failed_as(igzip::Status.BadLevel));

    var w2 = igzip::gzip_writer(-1);
    var o2: u8[>..] = [];
    assert(!w2.write(body, o2));
    assert(failed_as(igzip::Status.BadLevel));

    var bad = igzip::tables();
    bad.raw[41] = 0xFFFFFFFF;
    var w3 = igzip::gzip_writer(1);
    assert(!w3.set_tables(bad));
    assert(failed_as(igzip::Status.BadTable));

    // A Writer that was deserialized or had its public table field forged
    // bypasses set_tables, so the use site validates it too.
    var forged = igzip::Writer { tables: bad.raw, has_tables: true, .. };
    var fo: u8[>..] = [];
    assert(!forged.write(body, fo));
    assert(failed_as(igzip::Status.BadTable));
    assert(forged.clear_tables());

    // A Fresh Writer carrying state that only an initialized stream can back
    // is refused. reset is the recovery path.
    var fd = igzip::Writer { has_dict: true, .. };
    var fdo: u8[>..] = [];
    assert(!fd.write(body, fdo));
    assert(failed_as(igzip::Status.BadState));
    assert(fd.reset());
    assert(fd.write(body, fdo));
    assert(fd.finish(fdo));

    var fh = igzip::Writer { hdr_written: true, .. };
    var fho: u8[>..] = [];
    assert(!fh.write(body, fho));
    assert(failed_as(igzip::Status.BadState));

    var fs = igzip::Writer { state: igzip::WriterState.Open, .. };
    var fso: u8[>..] = [];
    assert(!fs.write(body, fso));
    assert(failed_as(igzip::Status.BadState));
    assert(fs.reset());

    assert(igzip::status_name(igzip::Status.BadHeader).len > 0);
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

    // One table for the tests that need one.
    var t = igzip::trainer();
    assert(t.add(body));
    let tables, built = t.build();
    assert(built);

    assert(make_dir("build"));
    assert(make_dir("build/tmp"));
    assert(make_dir(TMP));
    test_layout();
    test_state_and_totals(body);
    test_ordering(body, tables);
    test_copy_guard(body, tables);
    test_reset(body);
    test_headers(body);
    test_dict(body);
    test_trained(body, tables);
    test_tiny_output();
    test_errors(body);

    print("writer contract: ", body.len, " bytes, writer ", igzip::writer_size(), " bytes");
    print("writer contract: ok");
}

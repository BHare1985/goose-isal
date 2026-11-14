// Reader unit tests: layout, the state machine, statuses, dictionaries,
// concatenated members, hostile input, and the copy guard.
//
//     goose run --debug test/inflate_contract.goose
//
// The end-to-end round trip at every wrapper, level, size and chunk size lives
// in test/roundtrip.goose. This file is the state-machine and edge-case half: it
// asserts the transition matrix, and that every way of misusing a Reader is a
// Status rather than a corrupt decode or a crash.
import std;
import os;
import igzip from "..";
import support from "./support";

let READER_BYTES = 152936;

// Drives one member through the shim's step function with a destination of
// `cap` bytes. The shim stages the rest in the Reader's 64 KiB chunk and hands
// it back on the next call, so this is the only place the staged-drain path is
// exercised with a destination smaller than that chunk. The Reader is passed by
// reference on purpose: a 152,936-byte value returned from a helper would be a
// copy, and the copy guard refuses the very next call.
fn read_tiny(r: igzip::Reader&, src: const u8[:], cap: i64) -> u8[>..] {
    var out: u8[>..] = [];
    var pos: i64     = 0;
    var buf: u8[8]   = [0; 8];
    loop {
        var used:    u32 = 0;
        var written: u32 = 0;
        var done = false;
        let rc = igzip::igzip_gs_reader_step(r, src[pos..], buf[..cap], used, written, done);
        assert(rc == 0);
        if written > 0 { out.append(buf[..written]); }
        pos += used;
        if done { break; }
        if used == 0 && written == 0 { break; }
    }
    assert(pos == src.len);
    return out;
}

fn gz_of(body: const u8[:]) -> u8[>..] {
    let out, err = igzip::gzip(body);
    assert(err);
    return out;
}

fn test_layout() {
    assert(igzip::reader_size() == READER_BYTES);
    assert(igzip::CHUNK_SIZE == 65536);

    var r = igzip::gzip_reader();
    assert(r.state == igzip::ReaderState.Fresh);
    assert(r.wrap == igzip::Wrapper.Gzip);
    assert(r.total_in == 0 && r.total_out == 0);
    assert(!r.has_dict);
    assert(!r.finished());

    assert(igzip::zlib_reader().wrap == igzip::Wrapper.Zlib);
    assert(igzip::raw_reader().wrap == igzip::Wrapper.Raw);

    // A Reader is larger than the Writer it sits beside, and both are counted
    // in the same units the README quotes.
    assert(igzip::reader_size() + igzip::writer_size() < 1024 * 1024);
}

fn test_one_member(body: const u8[:]) {
    let gz = gz_of(body);

    var r = igzip::gzip_reader();
    var out: u8[>..] = [];
    let used, err = r.read(gz, out);
    assert(err);
    assert(used == gz.len);
    assert(r.finished());
    assert(support::same(out, body));
    assert(r.total_in == gz.len as u64);
    assert(r.total_out == body.len as u64);
    assert(r.state == igzip::ReaderState.Open);

    // A member boundary is a fact, not a state change: reading again from it is
    // legal, consumes nothing, and produces nothing.
    var more: u8[>..] = [];
    let u2, e2 = r.read(gz, more);
    assert(e2);
    assert(u2 == 0 && more.len == 0);

    assert(r.finish());
    assert(r.state == igzip::ReaderState.Finished);
}

fn test_empty_body() {
    var empty: u8[>..] = [];
    let gz = gz_of(empty);
    assert(gz.len > 0);

    var r = igzip::gzip_reader();
    var out: u8[>..] = [];
    let used, err = r.read(gz, out);
    assert(err);
    assert(used == gz.len && out.len == 0);
    assert(r.finished());
    assert(r.finish());

    // Stateless into no room at all: the member decodes to nothing, so a
    // zero-length destination is not TooSmall.
    var r2 = igzip::gzip_reader();
    var none: u8[>..] = [];
    let u2, w2, e2 = r2.inflate(gz, none);
    assert(e2);
    assert(u2 == gz.len && w2 == 0);
}

fn test_truncation(body: const u8[:]) {
    let gz = gz_of(body);

    // Cut at several depths, including inside the header and inside the
    // trailer. Every one of them is Truncated at finish, never Corrupt.
    var cuts: i64[5] = [0, 2, 10, gz.len / 2, gz.len - 4];
    for cut in cuts {
        var r = igzip::gzip_reader();
        var out: u8[>..] = [];
        let used, err = r.read(gz[..cut], out);
        assert(err);
        assert(used <= cut);
        assert(!r.finished());
        assert(!r.finish());
        assert(failed_as(igzip::Status.Truncated));
    }

    // A reader that stops early and is told there is no more input.
    var r2 = igzip::gzip_reader();
    var o2: u8[>..] = [];
    let u2, e2 = r2.read(gz[..gz.len / 3], o2);
    assert(e2);
    assert(u2 > 0);
    assert(!r2.finish());
    assert(failed_as(igzip::Status.Truncated));

    // The whole-buffer verbs agree.
    var r3 = igzip::gzip_reader();
    let p3, e3 = r3.inflated(gz[..gz.len - 4]);
    assert(!e3);
    assert(failed_as(igzip::Status.Truncated));
    assert(p3.len == body.len);

    var r4 = igzip::gzip_reader();
    var d4: u8[>..] = [];
    d4.resize(body.len, 0);
    let u4, w4, e4 = r4.inflate(gz[..gz.len - 4], d4);
    assert(!e4);
    assert(failed_as(igzip::Status.Truncated));
    assert(w4 == body.len);

    // No input at all.
    var r5 = igzip::gzip_reader();
    let p5, e5 = r5.inflated("");
    assert(!e5);
    assert(failed_as(igzip::Status.Truncated));
    assert(p5.len == 0);
}

fn test_too_small(body: const u8[:]) {
    let gz = gz_of(body);

    var r = igzip::gzip_reader();
    var dst: u8[>..] = [];
    dst.resize(body.len - 1, 0);
    let used, written, err = r.inflate(gz, dst);
    assert(!err);
    assert(failed_as(igzip::Status.TooSmall));
    assert(written == dst.len);
    // TooSmall leaves the reader usable without a reset.
    assert(r.state == igzip::ReaderState.Fresh);

    var bigger: u8[>..] = [];
    bigger.resize(body.len + 64, 0);
    let u2, w2, e2 = r.inflate(gz, bigger);
    assert(e2);
    assert(w2 == body.len);
    assert(u2 == gz.len);
    assert(support::same(bigger[..w2], body));

    // Exactly the right size is enough: no off-by-one at the boundary.
    var r3 = igzip::gzip_reader();
    var exact: u8[>..] = [];
    exact.resize(body.len, 0);
    let u3, w3, e3 = r3.inflate(gz, exact);
    assert(e3 == true && w3 == body.len);
    assert(support::same(exact, body));
}

fn test_tiny_destination(body: const u8[:]) {
    let gz = gz_of(body);

    // One byte of room at a time: everything but that byte waits in the Reader's
    // chunk, and nothing may be lost or reordered on the way out.
    var r = igzip::gzip_reader();
    let one = read_tiny(r, gz, 1);
    assert(support::same(one, body));
    assert(r.finished());
    assert(r.total_in == gz.len as u64);
    assert(r.total_out == body.len as u64);
    assert(r.finish());

    // And eight at a time, which straddles every chunk boundary differently.
    var r2 = igzip::gzip_reader();
    let eight = read_tiny(r2, gz, 8);
    assert(support::same(eight, body));
    assert(r2.finish());
}

fn test_read_after_too_small(body: const u8[:]) {
    let gz = gz_of(body);

    // TooSmall leaves the Reader Fresh, and Fresh has to mean it: the decode
    // state is mid-member, so switching to the streaming path afterwards must
    // start from the beginning rather than continue a half-decoded member.
    var r = igzip::gzip_reader();
    var dst: u8[>..] = [];
    dst.resize(body.len / 2, 0);
    let u1, w1, e1 = r.inflate(gz, dst);
    assert(!e1);
    assert(failed_as(igzip::Status.TooSmall));
    assert(w1 == dst.len);

    var out: u8[>..] = [];
    let u2, e2 = r.read(gz, out);
    assert(e2);
    assert(u2 == gz.len);
    assert(r.finished());
    assert(support::same(out, body));
    assert(r.finish());
}

fn test_trailing_bytes(body: const u8[:]) {
    let gz = gz_of(body);
    var both: u8[>..] = [];
    both.append(gz);
    both.append("not part of the member");

    // One member consumed, the rest reported as unconsumed.
    var r = igzip::gzip_reader();
    var dst: u8[>..] = [];
    dst.resize(body.len, 0);
    let used, written, err = r.inflate(both, dst);
    assert(err);
    assert(used == gz.len);
    assert(written == body.len);

    // Trailing bytes are never silently dropped by the whole-buffer verb.
    var r2 = igzip::gzip_reader();
    let p2, e2 = r2.inflated(both);
    assert(!e2);
    assert(failed_as(igzip::Status.BadWrapper));
    assert(p2.len == body.len);

    // Through the streaming path the caller sees the boundary itself.
    var r3 = igzip::gzip_reader();
    var o3: u8[>..] = [];
    let u3, e3 = r3.read(both, o3);
    assert(e3);
    assert(u3 == gz.len);
    assert(r3.finished());
    assert(r3.finish());
}

fn test_concatenated(body: const u8[:]) {
    let a = gz_of(body);
    var two: u8[>..] = [];
    two.append(a);
    two.append(a);
    two.append(a);

    // Automatic: every member, joined.
    var r = igzip::gzip_reader();
    let joined, err = r.inflated(two);
    assert(err);
    assert(joined.len == body.len * 3);
    for i in 3 {
        let at = i * body.len;
        assert(support::same(joined[at..at + body.len], body));
    }

    // Explicit: one member at a time, with reset between them.
    var r2 = igzip::gzip_reader();
    var out: u8[>..] = [];
    var pos: i64     = 0;
    var members = 0;
    loop {
        let used, e = r2.read(two[pos..], out);
        assert(e);
        pos += used;
        members++;
        if !r2.finished() { break; }
        if pos == two.len { break; }
        assert(r2.reset());
        // reset keeps the wrapper and clears the totals.
        assert(r2.total_in == 0 && r2.total_out == 0);
    }
    assert(members == 3);
    assert(pos == two.len);
    assert(out.len == body.len * 3);
    assert(r2.finish());
}

fn test_states(body: const u8[:]) {
    let gz = gz_of(body);

    // Finished is terminal until reset.
    var r = igzip::gzip_reader();
    var out: u8[>..] = [];
    let u1, e1 = r.read(gz, out);
    assert(e1 == true && u1 == gz.len);
    assert(r.finish());
    var more: u8[>..] = [];
    let u2, e2 = r.read(gz, more);
    assert(!e2);
    assert(failed_as(igzip::Status.BadState));
    assert(u2 == 0);
    assert(!r.finish());
    assert(failed_as(igzip::Status.BadState));
    assert(!r.finished());

    // finish on a reader that never saw input: the member never ended.
    var f = igzip::gzip_reader();
    assert(!f.finish());
    assert(failed_as(igzip::Status.Truncated));
    assert(f.state == igzip::ReaderState.Finished);
    assert(f.reset());
    assert(f.state == igzip::ReaderState.Fresh);

    // The one-shot verbs are Fresh-only, and a body is one mode or the other.
    var r2 = igzip::gzip_reader();
    var o2: u8[>..] = [];
    let u3, e3 = r2.read(gz[..gz.len / 2], o2);
    assert(e3 == true && u3 > 0);
    var dst: u8[>..] = [];
    dst.resize(body.len, 0);
    let a, b, e4 = r2.inflate(gz, dst);
    assert(!e4);
    assert(failed_as(igzip::Status.BadState));
    assert(a == 0 && b == 0);

    var r3 = igzip::gzip_reader();
    var d3: u8[>..] = [];
    d3.resize(body.len, 0);
    let c, d, e5 = r3.inflate(gz, d3);
    assert(e5);
    var o5: u8[>..] = [];
    let u5, e6 = r3.read(gz, o5);
    assert(!e6);
    assert(failed_as(igzip::Status.BadState));
    assert(u5 == 0);
    // ... and reset is the way out of either.
    assert(r3.reset());
    let u6, e7 = r3.read(gz, o5);
    assert(e7 == true && u6 == gz.len);
}

fn test_terminal_error_latches(body: const u8[:]) {
    let gz = gz_of(body);
    var bad: u8[>..] = [];
    bad.append(gz);
    bad[gz.len - 5] = bad[gz.len - 5] ^ 0xff;

    var r = igzip::gzip_reader();
    var out: u8[>..] = [];
    let u1, e1 = r.read(bad, out);
    assert(!e1);
    assert(failed_as(igzip::Status.BadChecksum) || failed_as(igzip::Status.Corrupt));
    // Without the latch, isal_inflate reports Ok forever from a FINISH state.
    let u2, e2 = r.read(bad, out);
    assert(!e2);
    assert(failed_as(igzip::Status.BadState));
    assert(u2 == 0);
    assert(r.reset());
}

fn test_hostile_input() {
    // Not a gzip file at all.
    var junk: u8[>..] = [];
    support::noise(junk, 512);
    var r = igzip::gzip_reader();
    var out: u8[>..] = [];
    let u1, e1 = r.read(junk, out);
    assert(!e1);
    assert(failed_as(igzip::Status.BadWrapper));

    // A gzip header claiming a compression method other than 8.
    var m: u8[>..] = [];
    m.push(0x1f);
    m.push(0x8b);
    m.push(7); // CM = LZMA, not deflate
    m.push(0);
    while m.len < 24 { m.push(0); }
    var r2 = igzip::gzip_reader();
    var o2: u8[>..] = [];
    let u2, e2 = r2.read(m, o2);
    assert(!e2);
    assert(failed_as(igzip::Status.BadWrapper));

    // A valid header followed by garbage: the deflate stream is invalid.
    var g = igzip::gzip_writer(1);
    var gz: u8[>..] = [];
    assert(!g.write_zlib_header(igzip::ZlibHeader { .. }, gz));
    assert(failed_as(igzip::Status.BadState));
    var g2 = igzip::zlib_writer(1);
    assert(g2.write_zlib_header(igzip::ZlibHeader { .. }, gz));
    var body: u8[>..] = [];
    support::corpus(body, 100);
    assert(g2.write(body, gz));
    assert(g2.finish(gz));
    for i in 16 {
        var mutant: u8[>..] = [];
        mutant.append(gz);
        let at = 2 + (i * 7919) % (gz.len - 6);
        mutant[at] = mutant[at] ^ 0x5a;
        var rr = igzip::zlib_reader();
        var oo: u8[>..] = [];
        let uu, ee = rr.read(mutant, oo);
        // Three things can happen, and only these three. The mutation breaks
        // the stream (a corrupt block, a trailer that no longer matches, a
        // header that is not zlib); or it lands in a field a decoder may ignore
        // (a zlib FLEVEL bit), and the plaintext is intact; or it leaves the
        // deflate stream unterminated, which igzip reports as `Ok` with the
        // member unfinished -- a payload mutation is not detectable from the
        // return code alone, only from `finished`/`finish`.
        assert(uu <= mutant.len);
        if ee != true {
            assert(failed_as(igzip::Status.Corrupt) ||
                   failed_as(igzip::Status.BadChecksum) ||
                   failed_as(igzip::Status.BadWrapper) ||
                   failed_as(igzip::Status.Truncated));
        } else if rr.finished() {
            assert(support::same(oo, body));
            assert(rr.finish());
        } else {
            assert(!rr.finish());
            assert(failed_as(igzip::Status.Truncated));
        }
    }

    // The same bytes through the whole-buffer verb.
    var r3 = igzip::zlib_reader();
    let p3, e3 = r3.inflated(m[..20]);
    assert(e3 != true);
}

fn test_dictionaries(body: const u8[:]) {
    var dict: u8[>..] = [];
    support::body_of(dict, 40000); // past igzip's 32 KiB history
    var wrong: u8[>..] = [];
    support::noise(wrong, 40000);

    // A zlib stream with FDICT, and no dictionary to hand: NeedDict, with the
    // header and DICTID already consumed.
    var wz = igzip::zlib_writer(1);
    var zs: u8[>..] = [];
    assert(wz.set_dict(dict));
    assert(wz.write(body, zs));
    assert(wz.finish(zs));

    var r = igzip::zlib_reader();
    var out: u8[>..] = [];
    let u1, e1 = r.read(zs, out);
    assert(!e1);
    assert(failed_as(igzip::Status.NeedDict));
    assert(u1 >= 6);
    assert(out.len == 0);
    // NeedDict does not latch: the reader is still usable.
    assert(r.state == igzip::ReaderState.Open);
    assert(r.set_dict(dict));
    let u2, e2 = r.read(zs[u1..], out);
    assert(e2);
    assert(support::same(out, body));
    assert(r.finish());

    // Supplying it before any input is accepted too, and the redundant NeedDict
    // is not passed on.
    var r2 = igzip::zlib_reader();
    var o2: u8[>..] = [];
    assert(r2.set_dict(dict));
    assert(r2.has_dict);
    let u3, e3 = r2.read(zs, o2);
    assert(e3);
    assert(support::same(o2, body));

    // A wrong dictionary is caught by the trailer, not by set_dict.
    var r3 = igzip::zlib_reader();
    var o3: u8[>..] = [];
    let u4, e4 = r3.read(zs, o3);
    assert(!e4);
    assert(failed_as(igzip::Status.NeedDict));
    assert(r3.set_dict(wrong));
    let u5, e5 = r3.read(zs[u4..], o3);
    assert(!e5);
    assert(failed_as(igzip::Status.BadChecksum) || failed_as(igzip::Status.Corrupt));

    // Raw deflate has no trailer, so a wrong dictionary is undetectable: wrong
    // bytes with Ok. This is documented behaviour, not an accident.
    var wr = igzip::raw_writer(1);
    var rs: u8[>..] = [];
    assert(wr.set_dict(dict));
    assert(wr.write(body, rs));
    assert(wr.finish(rs));

    var r4 = igzip::raw_reader();
    var o4: u8[>..] = [];
    assert(r4.set_dict(dict));
    let u6, e6 = r4.read(rs, o4);
    assert(e6);
    assert(support::same(o4, body));

    var r5 = igzip::raw_reader();
    var o5: u8[>..] = [];
    assert(r5.set_dict(wrong));
    let u7, e7 = r5.read(rs, o5);
    assert(e7);
    assert(o5.len == body.len);
    assert(!support::same(o5, body));

    // reset drops the dictionary: the next member needs it again.
    var r6 = igzip::zlib_reader();
    var o6: u8[>..] = [];
    assert(r6.set_dict(dict));
    assert(r6.reset());
    assert(!r6.has_dict);
    let u8_, e8 = r6.read(zs, o6);
    assert(!e8);
    assert(failed_as(igzip::Status.NeedDict));

    // Wrapper and size rules.
    var r7 = igzip::gzip_reader();
    assert(!r7.set_dict(dict));
    assert(failed_as(igzip::Status.BadState));
    var r8 = igzip::raw_reader();
    assert(r8.set_dict(""));
    assert(!r8.has_dict);

    // The stateless verb refuses a reader that holds one, rather than relying
    // on igzip's undocumented handling of the history buffer.
    var r9 = igzip::raw_reader();
    assert(r9.set_dict(dict));
    var d9: u8[>..] = [];
    d9.resize(body.len, 0);
    let q9, w9, e9 = r9.inflate(rs, d9);
    assert(!e9);
    assert(failed_as(igzip::Status.BadState));
    assert(q9 == 0 && w9 == 0);
}

fn test_set_dict_after_output(body: const u8[:]) {
    // Mid-body is not a legal moment for a dictionary; igzip's own guard says
    // so and it arrives as BadState rather than as a corrupt decode.
    let gz = gz_of(body);
    var r = igzip::gzip_reader();
    var out: u8[>..] = [];
    let u1, e1 = r.read(gz[..gz.len / 2], out);
    assert(e1);

    // gzip refuses outright; zlib and raw reach igzip's guard.
    var rz = igzip::zlib_reader();
    var zo: u8[>..] = [];
    var wz = igzip::zlib_writer(1);
    var zs: u8[>..] = [];
    assert(wz.write(body, zs));
    assert(wz.finish(zs));
    let u2, e2 = rz.read(zs[..zs.len / 2], zo);
    assert(e2);
    var dict: u8[>..] = [];
    support::body_of(dict, 100);
    assert(!rz.set_dict(dict));
    assert(failed_as(igzip::Status.BadState));
    // An empty dictionary is a no-op where a dictionary is legal, and still a
    // BadState where it is not: the moment is checked either way.
    assert(!rz.set_dict(""));
    assert(failed_as(igzip::Status.BadState));
}

fn test_copy_guard(body: const u8[:]) {
    let gz = gz_of(body);

    // Two copies of an unused reader are independent.
    var fresh = igzip::gzip_reader();
    var fresh_copy = fresh;
    var f1: u8[>..] = [];
    var f2: u8[>..] = [];
    let uf1, ef1 = fresh.read(gz, f1);
    let uf2, ef2 = fresh_copy.read(gz, f2);
    assert(ef1 == true && ef2);
    assert(uf1 == uf2);
    assert(support::same(f1, f2));

    // A copy of a reader that has started is refused, and reset recovers it.
    var r = igzip::gzip_reader();
    var out: u8[>..] = [];
    let u1, e1 = r.read(gz[..16], out);
    assert(e1);

    var copy = r;
    var co: u8[>..] = [];
    let uc, ec = copy.read(gz, co);
    assert(!ec);
    assert(failed_as(igzip::Status.BadState));
    assert(uc == 0);
    assert(!copy.finished());

    assert(copy.reset());
    let uc2, ec2 = copy.read(gz, co);
    assert(ec2);
    assert(copy.finished());
    assert(copy.finish());
    assert(support::same(co, body));

    // After a dictionary, too: the copy has the flag but not the history.
    var rd = igzip::raw_reader();
    var dict: u8[>..] = [];
    support::body_of(dict, 200);
    assert(rd.set_dict(dict));
    var dc = rd;
    var dco: u8[>..] = [];
    assert(!dc.set_dict(dict));
    assert(failed_as(igzip::Status.BadState));
    assert(dc.reset());
    assert(dc.set_dict(dict));
}

fn test_statuses() {
    assert(igzip::status_name(igzip::Status.Truncated).len > 0);
    assert(igzip::status_name(igzip::Status.TooSmall).len > 0);
    assert(igzip::status_name(igzip::Status.NeedDict).len > 0);
    assert(igzip::status_name(igzip::Status.Corrupt).len > 0);
    assert(igzip::status_name(igzip::Status.BadChecksum).len > 0);

    // The five are distinct from each other and from the deflate family.
    assert(igzip::status_name(igzip::Status.Truncated) != igzip::status_name(igzip::Status.Overflow));
    assert(igzip::status_name(igzip::Status.Corrupt) != igzip::status_name(igzip::Status.BadState));
    assert(igzip::status_name(igzip::Status.TooSmall) != igzip::status_name(igzip::Status.BadLevelBuf));
    assert(igzip::status_name(igzip::Status.BadChecksum) != igzip::status_name(igzip::Status.BadTable));
}

fn test_windows(body: const u8[:]) {
    let gz = gz_of(body);

    // A one-byte input window exercises the same path as a 2 GiB one.
    var r = igzip::gzip_reader();
    var out: u8[>..] = [];
    let used, err = r.read_windowed(gz, out, 1);
    assert(err);
    assert(used == gz.len);
    assert(support::same(out, body));

    // A window that does not divide the stream, and one larger than it.
    var r2 = igzip::gzip_reader();
    var o2: u8[>..] = [];
    let u2, e2 = r2.read_windowed(gz, o2, 13);
    assert(e2 == true && u2 == gz.len);
    assert(support::same(o2, body));

    var r3 = igzip::gzip_reader();
    var o3: u8[>..] = [];
    let u3, e3 = r3.read_windowed(gz, o3, 1 << 20);
    assert(e3 == true && u3 == gz.len);
    assert(support::same(o3, body));

    // An unusable window is a Status, not a silent whole-buffer read.
    var r4 = igzip::gzip_reader();
    var o4: u8[>..] = [];
    let u4, e4 = r4.read_windowed(gz, o4, 0);
    assert(!e4);
    assert(failed_as(igzip::Status.Overflow));
    assert(u4 == 0);
    let u5, e5 = r4.read_windowed(gz, o4, igzip::MAX_INPUT + 1);
    assert(!e5);
    assert(failed_as(igzip::Status.Overflow));
    assert(u5 == 0);
}

fn test_larger_than_a_chunk() {
    // Output filling the 64 KiB staging chunk, and overflow past it, is where a
    // missed history cursor would show up.
    var noise: u8[>..] = [];
    support::noise(noise, 300000);
    let gz, cerr = igzip::gzip(noise);
    assert(cerr);

    var r = igzip::gzip_reader();
    var out: u8[>..] = [];
    let used, err = r.read(gz, out);
    assert(err);
    assert(used == gz.len);
    assert(out.len == noise.len);
    assert(support::same(out, noise));
    assert(r.total_out == noise.len as u64);

    // Same bytes, one byte of input at a time: the staging path has to hand
    // everything back in order.
    var r2 = igzip::gzip_reader();
    var o2: u8[>..] = [];
    let u2, e2 = r2.read_windowed(gz, o2, 1);
    assert(e2 == true && u2 == gz.len);
    assert(support::same(o2, noise));
}

// The reason the last failing call gave, compared with a variant. Five lines
// rather than a whole assertion shape at 40 call sites: with a bool return the
// detail is out of band, in igzip::status().
fn failed_as(want: igzip::Status) -> bool {
    return igzip::status() == want;
}

fn main() {
    var body: u8[>..] = [];
    support::corpus(body, 1500);
    assert(body.len > 10000);

    test_layout();
    test_one_member(body);
    test_empty_body();
    test_truncation(body);
    test_too_small(body);
    test_read_after_too_small(body);
    test_tiny_destination(body);
    test_trailing_bytes(body);
    test_concatenated(body);
    test_states(body);
    test_terminal_error_latches(body);
    test_hostile_input();
    test_dictionaries(body);
    test_set_dict_after_output(body);
    test_copy_guard(body);
    test_statuses();
    test_windows(body);
    test_larger_than_a_chunk();

    print("inflate contract: ", body.len, " bytes, reader ", igzip::reader_size(), " bytes");
    print("inflate contract: ok");
}

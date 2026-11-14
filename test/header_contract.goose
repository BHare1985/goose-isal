// Header contract: every header this package writes, it can read back, and a
// header it did not write is parsed or refused, never trusted.
//
//     goose run --debug test/header_contract.goose
//
// The writer and the reader here are written against the same RFC but from
// opposite ends, so agreeing is evidence: a field the writer set and the parser
// cannot find is a bug in one of them. The hostile half matters more -- a header
// is untrusted input read before any of the stream has been decoded, so every
// length in it is a claim that has to be checked against the bytes that are
// actually there.
import std;
import igzip from "..";
import support from "./support";

// One member with a header the caller built. The header holds views into the
// caller's buffers, so it cannot be returned from here: `GzipHeader` is a value
// with borrowed parts, and the borrow has to outlive the stream.
fn write_with_header(body: const u8[:], hdr: igzip::GzipHeader) -> u8[>..] {
    var w = igzip::gzip_writer(1);
    var out: u8[>..] = [];
    assert(w.write_gzip_header(hdr, out));
    assert(w.write(body, out));
    assert(w.finish(out));
    return out;
}

fn test_round_trip(body: const u8[:]) {
    var extra: u8[>..] = [];
    for i in 300 { extra.push(((i * 7) & 0xff) as u8); }
    let hdr = igzip::GzipHeader { text: true, mtime: 1234567890, xflags: 4, os: 3, hcrc: true,
                                  name: "reports/2026.csv", comment: "written by goose",
                                  extra: extra };
    let gz = write_with_header(body, hdr);

    var info, err = igzip::read_gzip_header(gz);
    assert(err);
    assert(info.text);
    assert(info.hcrc);
    assert(info.mtime == hdr.mtime);
    assert(info.xflags == hdr.xflags);
    assert(info.os == hdr.os);

    // The optional parts are offsets into the input.
    assert(info.extra_at >= 10 && info.extra_len == hdr.extra.len);
    assert(support::same(gz[info.extra_at..][..info.extra_len], hdr.extra));
    assert(info.name_len == hdr.name.len);
    assert(support::same(gz[info.name_at..][..info.name_len], hdr.name));
    assert(info.comment_len == hdr.comment.len);
    assert(support::same(gz[info.comment_at..][..info.comment_len], hdr.comment));

    // `body_at` is where the deflate stream starts, which the decoder can prove:
    // the rest of the member decodes as a bare deflate stream, all but the
    // eight-byte trailer.
    assert(info.body_at < gz.len);
    var r = igzip::raw_reader();
    var out: u8[>..] = [];
    let used, derr = r.read(gz[info.body_at..], out);
    assert(derr);
    assert(r.finished());
    assert(support::same(out, body));
    assert(used < gz.len - info.body_at); // the trailer is left over

    // And the same decode through the whole member agrees with it.
    var g = igzip::gzip_reader();
    let plain, gerr = g.inflated(gz);
    assert(gerr);
    assert(support::same(plain, body));

    // A default header: no optional parts, and every "absent" offset is -1.
    var w2 = igzip::gzip_writer(1);
    var d: u8[>..] = [];
    assert(w2.write_gzip_header(igzip::GzipHeader { .. }, d));
    assert(d.len == 10);
    var dinfo, derr2 = igzip::read_gzip_header(d);
    assert(derr2);
    assert(dinfo.body_at == 10);
    assert(dinfo.extra_at == -1 && dinfo.extra_len == 0);
    assert(dinfo.name_at == -1 && dinfo.name_len == 0);
    assert(dinfo.comment_at == -1 && dinfo.comment_len == 0);
    assert(!dinfo.text && !dinfo.hcrc);
    assert(dinfo.mtime == 0 && dinfo.os == 0xff);

    // An empty name is not written at all: FNAME is a NUL-terminated string, and
    // "" carries nothing the flag could add, so the writer leaves it out and the
    // reader reports it absent rather than present-and-empty.
    var w3 = igzip::gzip_writer(1);
    var e: u8[>..] = [];
    assert(w3.write_gzip_header(igzip::GzipHeader { name: "" }, e));
    assert(e.len == 10);
    var einfo, eerr = igzip::read_gzip_header(e);
    assert(eerr);
    assert(einfo.name_at == -1 && einfo.name_len == 0);
    assert(einfo.body_at == 10);
}

fn test_large_header(body: const u8[:]) {
    // Bigger than the 64 KiB chunk, so the writer's temporary path is in play.
    var extra: u8[>..] = [];
    for i in 65000 { extra.push(7); }
    var name: u8[>..] = [];
    for i in 2000 { name.push(110); }

    var w = igzip::gzip_writer(1);
    var out: u8[>..] = [];
    let hdr = igzip::GzipHeader { name: name, extra: extra, mtime: 7, hcrc: true };
    assert(w.write_gzip_header(hdr, out));
    assert(out.len > 65536);
    assert(w.write(body, out));
    assert(w.finish(out));

    var info, err = igzip::read_gzip_header(out);
    assert(err);
    assert(info.extra_len == 65000);
    assert(info.name_len == 2000);
    assert(info.mtime == 7);
    assert(support::same(out[info.name_at..][..info.name_len], name));
    // The offsets have to add up to the header the writer emitted: 10 fixed
    // bytes, a two-byte XLEN, 65,000 of extra, 2,000 of name plus its NUL, and
    // two bytes of FHCRC.
    assert(info.extra_at == 12);
    assert(info.name_at == 12 + 65000);
    assert(info.body_at == 10 + 2 + 65000 + 2000 + 1 + 2);
}

fn test_hostile() {
    // Not gzip at all.
    var junk: u8[>..] = [];
    support::noise(junk, 64);
    var i1, e1 = igzip::read_gzip_header(junk);
    assert(!e1);
    assert(failed_as(igzip::Status.BadWrapper));
    assert(i1.body_at == 0);

    // Magic, then a method zlib does not define.
    var cm: u8[>..] = [];
    cm.push(0x1f);
    cm.push(0x8b);
    cm.push(7);
    for i in 12 { cm.push(0); }
    var i2, e2 = igzip::read_gzip_header(cm);
    assert(!e2);
    assert(failed_as(igzip::Status.BadWrapper));

    // Reserved FLG bits set: RFC 1952 says they must be zero.
    var res: u8[>..] = [];
    res.push(0x1f);
    res.push(0x8b);
    res.push(8);
    res.push(0x20);
    for i in 10 { res.push(0); }
    var i3, e3 = igzip::read_gzip_header(res);
    assert(!e3);
    assert(failed_as(igzip::Status.BadHeader));

    // Every prefix of a valid header is Truncated, never Ok and never a crash.
    var extra: u8[>..] = [];
    for i in 300 { extra.push(1); }
    let full = igzip::GzipHeader { text: true, hcrc: true, name: "n", comment: "c", extra: extra };
    let gz = write_with_header("body", full);
    var hinfo, herr = igzip::read_gzip_header(gz);
    assert(herr);
    var cut: i64 = 0;
    while cut < hinfo.body_at {
        var i4, e4 = igzip::read_gzip_header(gz[..cut]);
        assert(!e4);
        assert(failed_as(igzip::Status.Truncated));
        cut += 1;
    }
    // At exactly the header length it is complete: the last optional part ends
    // there, and nothing past it is needed to read the header.
    var hi2, he2 = igzip::read_gzip_header(gz[..hinfo.body_at]);
    assert(he2);
    assert(hi2.body_at == hinfo.body_at);

    // FEXTRA length running past the end of the input.
    var xlen: u8[>..] = [];
    xlen.push(0x1f);
    xlen.push(0x8b);
    xlen.push(8);
    xlen.push(0x04); // FEXTRA
    for i in 6 { xlen.push(0); }
    xlen.push(0x00); // XLEN = 0xffff, far more than the buffer holds
    xlen.push(0xff);
    for i in 100 { xlen.push(1); }
    var i5, e5 = igzip::read_gzip_header(xlen);
    assert(!e5);
    assert(failed_as(igzip::Status.Truncated));

    // FNAME with no terminator: the whole remaining buffer is the name, and the
    // parser must say so rather than run off the end.
    var unnamed: u8[>..] = [];
    unnamed.push(0x1f);
    unnamed.push(0x8b);
    unnamed.push(8);
    unnamed.push(0x08); // FNAME
    for i in 6 { unnamed.push(0); }
    for i in 500 { unnamed.push(65); }
    var i6, e6 = igzip::read_gzip_header(unnamed);
    assert(!e6);
    assert(failed_as(igzip::Status.Truncated));
    // No offset is reported for a part whose extent is unknown: an offset is
    // only meaningful once the whole header has been read.
    assert(i6.name_at == -1 && i6.name_len == 0);

    // A header that ends inside FHCRC.
    var nh: u8[>..] = [];
    nh.push(0x1f);
    nh.push(0x8b);
    nh.push(8);
    nh.push(0x02); // FHCRC
    for i in 6 { nh.push(0); }
    nh.push(0); // one byte of the CRC, and no more
    var i7, e7 = igzip::read_gzip_header(nh);
    assert(!e7);
    assert(failed_as(igzip::Status.Truncated));
}

fn test_zlib_headers() {
    // What the writer emits, at several windows and levels.
    for window_bits in [8, 12, 15] {
        for flevel in [0, 1, 3] {
            var w = igzip::zlib_writer(1);
            var out: u8[>..] = [];
            let hdr = igzip::ZlibHeader { window_bits: window_bits as u8, flevel: flevel as u8 };
            assert(w.write_zlib_header(hdr, out));
            assert(w.write("hello", out));
            assert(w.finish(out));

            var info, err = igzip::read_zlib_header(out);
            assert(err);
            assert(info.window_bits == window_bits);
            assert(info.flevel == flevel as u8);
            assert(!info.dict);
            assert(info.body_at == 2);
        }
    }

    // A dictionary stream names its DICTID, big-endian.
    var dict: u8[>..] = [];
    support::body_of(dict, 2000);
    var wz = igzip::zlib_writer(1);
    var zs: u8[>..] = [];
    assert(wz.set_dict(dict));
    assert(wz.write("payload", zs));
    assert(wz.finish(zs));
    var dinfo, derr = igzip::read_zlib_header(zs);
    assert(derr);
    assert(dinfo.dict);
    assert(dinfo.dict_id == wz.dict_id);
    assert(dinfo.body_at == 6);

    // The offsets are right: the payload after them decodes as raw deflate.
    var r = igzip::raw_reader();
    var out: u8[>..] = [];
    assert(r.set_dict(dict));
    let used, rerr = r.read(zs[dinfo.body_at..], out);
    assert(rerr);
    assert(r.finished());
    assert(support::same(out, "payload"));
    assert(used < zs.len - dinfo.body_at); // the Adler-32 trailer is left over

    // Hostile: a bad check value is caught here rather than at the trailer.
    var bad: u8[>..] = [];
    bad.push(0x78);
    bad.push(0x9d); // 0x789d % 31 != 0
    bad.push(0);
    bad.push(0);
    var bi, berr = igzip::read_zlib_header(bad);
    assert(!berr);
    assert(failed_as(igzip::Status.BadHeader));

    // A method other than deflate.
    var cm: u8[>..] = [];
    cm.push(0x77);
    cm.push(0x9c);
    var ci, cerr = igzip::read_zlib_header(cm);
    assert(!cerr);
    assert(failed_as(igzip::Status.BadWrapper));

    // CINFO above 7 claims a window larger than 32 KiB.
    var big: u8[>..] = [];
    big.push(0x88);
    big.push(0x1c); // 0x881c % 31 == 0, CINFO = 8
    var gi, gerr = igzip::read_zlib_header(big);
    assert(!gerr);
    assert(failed_as(igzip::Status.BadHeader));

    // Truncated, including a missing DICTID.
    var d2: u8[>..] = [];
    d2.push(0x78);
    d2.push(0xbb); // FDICT set, check value valid
    var ti, terr = igzip::read_zlib_header(d2);
    assert(!terr);
    assert(failed_as(igzip::Status.Truncated));
    var si, serr = igzip::read_zlib_header("x");
    assert(!serr);
    assert(failed_as(igzip::Status.Truncated));
}

// The reason the last failing call gave, compared with a variant. Five lines
// rather than a whole assertion shape at 40 call sites: with a bool return the
// detail is out of band, in igzip::status().
fn failed_as(want: igzip::Status) -> bool {
    return igzip::status() == want;
}

fn main() {
    var body: u8[>..] = [];
    support::corpus(body, 400);

    test_round_trip(body);
    test_large_header(body);
    test_hostile();
    test_zlib_headers();

    print("header contract: ok");
}

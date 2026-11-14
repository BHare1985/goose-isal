// Round trip: everything this package writes, this package reads.
//
//     goose run --debug test/roundtrip.goose
//
// This is the test 0.3.0 exists for. Every wrapper, every level, a ladder of
// sizes either side of each igzip boundary, compressible and incompressible
// bodies, trained tables, and every way of decoding: one `read`, `read` in
// power-of-two and prime input chunks, `read_windowed` at every window size,
// `inflate` into an exactly sized destination, and `inflated`. Byte equality is
// the assertion in all of them -- "it decoded" is not the claim.
//
// test/inflate_contract.goose covers the state machine and the statuses; this
// one covers the bytes.
import std;
import igzip from "..";
import support from "./support";

// Sizes either side of igzip's internal boundaries: the 64 KiB staging chunk,
// the 32 KiB history window, and the one-byte and empty cases.
let SIZES = [0, 1, 7, 100, 1023, 4095, 4096, 65535, 65536, 65537, 131111];

let WRAPPERS: igzip::Wrapper[3] = [igzip::Wrapper.Raw, igzip::Wrapper.Gzip,
                                   igzip::Wrapper.Zlib];

fn compress_one_shot(body: const u8[:], wrap: igzip::Wrapper, level: i64) -> u8[>..] {
    var c = igzip::compressor(wrap, level as i32);
    let out, err = c.compressed(body);
    assert(err);
    return out;
}

fn compress_written(body: const u8[:], wrap: igzip::Wrapper, level: i64) -> u8[>..] {
    var w = igzip::writer(wrap, level as i32);
    var out: u8[>..] = [];
    assert(w.write(body, out));
    assert(w.finish(out));
    assert(w.total_in == body.len as u64);
    return out;
}

// Uneven chunks. A Writer fed in pieces legitimately emits different blocks from
// one fed the whole body, so this stream is decoded rather than compared.
fn compress_chunked(body: const u8[:], wrap: igzip::Wrapper, level: i64) -> u8[>..] {
    var w = igzip::writer(wrap, level as i32);
    var out:  u8[>..] = [];
    var pos:  i64     = 0;
    var step: i64     = 1;
    while pos < body.len {
        var n = step;
        if n > body.len - pos { n = body.len - pos; }
        assert(w.write(body[pos..pos + n], out));
        pos += n;
        step = step * 3 + 1;
        if step > 4096 { step = 1; }
    }
    assert(w.finish(out));
    assert(w.total_in == body.len as u64);
    return out;
}

// One `read`, one member.
fn read_whole(wrap: igzip::Wrapper, stream: const u8[:], want: const u8[:]) {
    var r = igzip::reader(wrap);
    var out: u8[>..] = [];
    let used, err = r.read(stream, out);
    assert(err);
    assert(used == stream.len);
    assert(r.finished());
    assert(r.finish());
    assert(r.total_in == stream.len as u64);
    assert(r.total_out == want.len as u64);
    assert(support::same(out, want));
}

// The compressed stream handed over in chunks, the way a socket delivers it.
fn read_chunked(wrap: igzip::Wrapper, stream: const u8[:], want: const u8[:], step: i64) {
    var r = igzip::reader(wrap);
    var out: u8[>..] = [];
    var pos: i64     = 0;
    loop {
        var n = step;
        if n > stream.len - pos { n = stream.len - pos; }
        let used, err = r.read(stream[pos..pos + n], out);
        assert(err);
        pos += used;
        // A window may end before the bytes it was given were taken: the reader
        // stops at a member boundary and nowhere else.
        assert(used == n || r.finished());
        if pos == stream.len { break; }
        if r.finished() { break; }
    }
    assert(pos == stream.len);
    assert(r.finished());
    assert(r.finish());
    assert(support::same(out, want));
}

fn read_windowed_at(wrap: igzip::Wrapper, stream: const u8[:], want: const u8[:], step: i64) {
    var r = igzip::reader(wrap);
    var out: u8[>..] = [];
    let used, err = r.read_windowed(stream, out, step);
    assert(err);
    assert(used == stream.len);
    assert(r.finished());
    assert(support::same(out, want));
}

// The whole-buffer verb, into a destination the caller sized.
fn read_stateless(wrap: igzip::Wrapper, stream: const u8[:], want: const u8[:]) {
    var r = igzip::reader(wrap);
    var dst: u8[>..] = [];
    dst.resize(want.len, 0);
    let used, written, err = r.inflate(stream, dst);
    assert(err);
    assert(used == stream.len);
    assert(written == want.len);
    assert(support::same(dst, want));
}

// A caller with no idea of the size: start small, take TooSmall, grow.
fn read_stateless_retry(wrap: igzip::Wrapper, stream: const u8[:], want: const u8[:]) {
    var r = igzip::reader(wrap);
    var cap: i64 = 1;
    loop {
        var dst: u8[>..] = [];
        dst.resize(cap, 0);
        let used, written, err = r.inflate(stream, dst);
        if failed_as(igzip::Status.TooSmall) {
            // The claim behind TooSmall: the destination really was too small,
            // it was filled exactly, and the reader is ready to try again.
            assert(cap < want.len);
            assert(written == cap);
            assert(r.state == igzip::ReaderState.Fresh);
            cap = cap * 2 + 16;
            continue;
        }
        assert(err);
        assert(written == want.len);
        assert(support::same(dst[..written], want));
        return;
    }
}

fn read_inflated(wrap: igzip::Wrapper, stream: const u8[:], want: const u8[:]) {
    var r = igzip::reader(wrap);
    let out, err = r.inflated(stream);
    assert(err);
    assert(support::same(out, want));
}

// Every decode path, for one stream.
fn decode_every_way(wrap: igzip::Wrapper, stream: const u8[:], want: const u8[:]) {
    read_whole(wrap, stream, want);
    read_chunked(wrap, stream, want, 1);
    read_chunked(wrap, stream, want, 3);
    read_chunked(wrap, stream, want, 1000);
    read_windowed_at(wrap, stream, want, 1);
    read_windowed_at(wrap, stream, want, 97);
    read_windowed_at(wrap, stream, want, 1 << 20);
    read_stateless(wrap, stream, want);
    read_stateless_retry(wrap, stream, want);
    read_inflated(wrap, stream, want);
}

fn test_map() {
    var body: u8[>..] = [];
    support::corpus(body, 4000);

    for wrap in WRAPPERS {
        for level in 4 {
            let one = compress_one_shot(body, wrap, level);
            let written = compress_written(body, wrap, level);
            let chunked = compress_chunked(body, wrap, level);
            // Levels 1-3 produce the same bytes from the stateless and the
            // streaming path when the whole body arrives in one call. Level 0
            // ends one stored byte differently, and both spellings are valid
            // deflate, so both are decoded instead of compared.
            if level > 0 {
                assert(support::same(one, written));
            }
            decode_every_way(wrap, one, body);
            decode_every_way(wrap, written, body);
            decode_every_way(wrap, chunked, body);
        }
    }
}

fn test_sizes() {
    for n in SIZES {
        var body: u8[>..] = [];
        support::body_of(body, n);
        assert(body.len == n);
        for wrap in WRAPPERS {
            for level in 4 {
                let stream = compress_one_shot(body, wrap, level);
                decode_every_way(wrap, stream, body);
                // The streaming writer at every size too: a Writer's block
                // choices depend on how its input was split.
                let written = compress_written(body, wrap, level);
                decode_every_way(wrap, written, body);
            }
        }
    }
}

fn test_noise() {
    // Incompressible input: the worst case for both sides, and the case where
    // the compressed stream is larger than the body.
    for n in [4096, 65536, 100003] {
        var body: u8[>..] = [];
        support::noise(body, n);
        for wrap in WRAPPERS {
            for level in 4 {
                let stream = compress_one_shot(body, wrap, level);
                assert(stream.len > n || level == 0);
                decode_every_way(wrap, stream, body);
            }
        }
    }
}

fn test_trained_tables() {
    var sample: u8[>..] = [];
    support::corpus(sample, 3000);
    var t = igzip::trainer();
    assert(t.add(sample));
    let tables, built = t.build();
    assert(built);

    // Through a Compressor.
    for wrap in WRAPPERS {
        var c = igzip::compressor(wrap, 0);
        c.set_tables(tables);
        let stream, err = c.compressed(sample);
        assert(err);
        decode_every_way(wrap, stream, sample);
    }

    // And through a Writer.
    var w = igzip::gzip_writer(1);
    var out: u8[>..] = [];
    assert(w.set_tables(tables));
    assert(w.write(sample, out));
    assert(w.finish(out));
    decode_every_way(igzip::Wrapper.Gzip, out, sample);
}

fn test_concatenated() {
    var a: u8[>..] = [];
    support::corpus(a, 300);
    var b: u8[>..] = [];
    support::noise(b, 5000);
    var empty: u8[>..] = [];

    for wrap in WRAPPERS {
        let sa = compress_one_shot(a, wrap, 1);
        let sb = compress_one_shot(b, wrap, 2);
        let se = compress_one_shot(empty, wrap, 1);

        var joined: u8[>..] = [];
        joined.append(sa);
        joined.append(se);
        joined.append(sb);

        var want: u8[>..] = [];
        want.append(a);
        want.append(b);

        // Automatic: all three, joined, the empty member contributing nothing.
        var r = igzip::reader(wrap);
        let out, err = r.inflated(joined);
        assert(err);
        assert(support::same(out, want));

        // Explicit: one member per read, reset between.
        var r2 = igzip::reader(wrap);
        var acc: u8[>..] = [];
        var pos: i64     = 0;
        var members = 0;
        loop {
            let used, e = r2.read(joined[pos..], acc);
            assert(e);
            pos += used;
            members++;
            if !r2.finished() { break; }
            if pos == joined.len { break; }
            assert(r2.reset());
        }
        assert(members == 3);
        assert(pos == joined.len);
        assert(support::same(acc, want));
        assert(r2.finish());
    }
}

fn test_flush_points() {
    // A Sync flush is a decode point: every input byte written so far decodes
    // without anything after it, even though the member is not finished.
    var a: u8[>..] = [];
    support::corpus(a, 200);
    var b: u8[>..] = [];
    support::corpus(b, 200);
    var want: u8[>..] = [];
    want.append(a);
    want.append(b);

    for wrap in WRAPPERS {
        var w = igzip::writer(wrap, 1);
        var out: u8[>..] = [];
        assert(w.write(a, out));
        assert(w.flush(igzip::Flush.Sync, out));
        let at_flush = out.len;
        assert(w.write(b, out));
        assert(w.finish(out));

        // The prefix decodes entirely, and is not a complete member.
        var r = igzip::reader(wrap);
        let prefix, e1 = r.inflated(out[..at_flush]);
        assert(!e1);
        assert(failed_as(igzip::Status.Truncated));
        assert(support::same(prefix, a));

        // Nothing after the flush point is needed to get every byte of `a`.
        var r2 = igzip::reader(wrap);
        var parts: u8[>..] = [];
        let u2, e2 = r2.read(out[..at_flush], parts);
        assert(e2);
        assert(u2 == at_flush);
        assert(!r2.finished());
        assert(support::same(parts, a));
        assert(!r2.finish());
        assert(failed_as(igzip::Status.Truncated));

        // Resuming from the flush point gives the rest, and the whole stream
        // decodes as one member.
        var r3 = igzip::reader(wrap);
        var acc: u8[>..] = [];
        let u3, e3 = r3.read(out[..at_flush], acc);
        assert(e3 == true && u3 == at_flush);
        let u4, e4 = r3.read(out[at_flush..], acc);
        assert(e4);
        assert(u4 == out.len - at_flush);
        assert(r3.finished());
        assert(r3.finish());
        assert(support::same(acc, want));

        var r4 = igzip::reader(wrap);
        let whole, e5 = r4.inflated(out);
        assert(e5);
        assert(support::same(whole, want));
    }
}

// The reason the last failing call gave, compared with a variant. Five lines
// rather than a whole assertion shape at 40 call sites: with a bool return the
// detail is out of band, in igzip::status().
fn failed_as(want: igzip::Status) -> bool {
    let s = igzip::status();
    guard s else { return false; }
    return s == want;
}

fn main() {
    test_map();
    test_sizes();
    test_noise();
    test_trained_tables();
    test_concatenated();
    test_flush_points();

    print("roundtrip: ok (", igzip::reader_size(), "-byte reader, ", igzip::writer_size(),
          "-byte writer )");
}

// One compressor per worker thread, no locks, no shared state.
//
//     goose build test/threads.goose -o build/threads && ./build/threads
//
// `goose run` cannot do this: the JIT cannot place thread-local storage, so a
// program with `thread_fn` has to be built.
//
// This tests the claim in the README rather than asserting it: Goose workers
// share nothing, so each owns a Compressor (300 KB of igzip state) and the only
// thing crossing between them is a flat Result through a typed queue. The last
// two jobs carry the same input, so two different workers must report the same
// compressed size.
import std;
import igzip from "..";

let WORKERS = 4;
let JOBS = 16;
// Not a multiple of 50, so it cannot collide with the generated jobs.
let SHARED_RECORDS = 425;

struct Job {
    records: i32,
}

struct Result {
    records: i32,
    size:    i32,
    code:    i32,
}

struct StreamJob {
    records: i32,
}

struct StreamResult {
    records: i32,
    size:    i32,
    code:    i32,
}

// One compressed member, boxed so it can cross a queue by value. The reader
// worker below decodes what another thread's Writer produced.
let BOX = 65536;

struct RoundBox {
    records: i32,
    len:     i32,
    // The checksum of the body this member was made from. The reader worker
    // rebuilds that body itself, so on a mismatch this says which side is
    // wrong: the bytes it generated, or the bytes it decoded.
    sum:  i64,
    data: u8[BOX],
}

struct RoundResult {
    records: i32,
    matched: bool,
    code:    i32,
}

let STREAM_WORKERS = 2;
let STREAM_JOBS = 6;
let ROUND_JOBS = 4;

// One JSON record, appended: the unit both the main thread and the reader
// worker build their bodies from.
fn make_record(out: u8[>..]&, i: i32) {
    format(out, "{\"id\":", i, ",\"user\":\"alice\",\"email\":\"alice@example.com\",",
           "\"active\":true,\"score\":", i * 37 % 1000, ",\"tags\":[\"alpha\",\"beta\"]},\n");
}

// One JSON schema, N records: the body a worker compresses.
fn make_body(out: u8[>..]&, records: i32) {
    for i in records { make_record(out, i); }
}

thread_fn worker() {
    // Declared inside the worker, not before it: each thread gets its own
    // value, and with it its own igzip stream and level buffer.
    var c = igzip::gzip_compressor(1);
    var body: u8[>..] = [];
    var out:  u8[>..] = [];

    loop {
        let job = qget<Job>();
        guard job.records >= 0 else { break; }

        body.clear();
        make_body(body, job.records);
        out.clear();
        let err = c.compress(body, out);

        var code: i32 = 0;
        if !err { code = 1; }
        qput(Result {
            records: job.records,
            size:    if err == true { out.len as i32 } else { -1 },
            code:    code,
        });
    }
}

// A streaming worker keeps its Writer in a growable array, which lives on the
// thread's data stack. A 367 KB fixed local would be at home on the C stack on
// Linux but is close to macOS's 512 KB pthread default.
thread_fn stream_worker() {
    var holder: igzip::Writer[>..] = [];
    holder.push(igzip::gzip_writer(1));
    var body: u8[>..] = [];
    var out:  u8[>..] = [];

    loop {
        let job = qget<StreamJob>();
        guard job.records >= 0 else { break; }

        body.clear();
        make_body(body, job.records);
        out.clear();
        let err = holder[0].write(body, out);
        var code: i32 = 0;
        if err {
            let done = holder[0].finish(out);
            if done {
                let again = holder[0].reset();
                if !again { code = 3; }
            } else {
                code = 2;
            }
        } else {
            code = 1;
        }
        qput(StreamResult {
            records: job.records,
            size:    if code == 0 { out.len as i32 } else { -1 },
            code:    code,
        });
    }
}

// A reader worker: it owns a Reader (152,936 bytes) and decodes the members
// other threads compressed. Both stateful values live in holders on this
// thread's data stack, so a 512 KB pthread stack is not in the picture.
thread_fn reader_worker() {
    var holder: igzip::Reader[>..] = [];
    holder.push(igzip::gzip_reader());
    var body: u8[>..] = [];
    var out:  u8[>..] = [];

    loop {
        let box = qget<RoundBox>();
        guard box.len >= 0 else { break; }

        body.clear();
        make_body(body, box.records);
        out.clear();
        let used, err = holder[0].read(box.data[..box.len], out);
        var code: i32 = 0;
        if used != box.len || !err {
            code = 1;
        } else if !holder[0].finished() {
            code = 2;
        } else if !same_bytes(out, body) {
            // Say how it diverged: a different length points at the box or the
            // queue, a same-length difference at the decode itself. `box.sum`
            // is the body the member was made from, so whichever of `out` and
            // `body` matches it is the one that is right.
            var at: i64 = -1;
            var k:  i64 = 0;
            while k < out.len && k < body.len {
                if out[k] != body[k] { at = k; break; }
                k++;
            }
            print("threads: mismatch records=", box.records, " box.len=", box.len,
                  " out.len=", out.len, " body.len=", body.len, " at=", at,
                  " box.sum=", box.sum, " out.sum=", checksum(out),
                  " body.sum=", checksum(body));
            show_around("  out", out, at);
            show_around("  body", body, at);
            code = 3;
        } else if !holder[0].finish() {
            code = 4;
        } else if !holder[0].reset() {
            code = 5;
        }
        qput(RoundResult {
            records: box.records,
            matched: code == 0,
            code:    code,
        });
    }
}

// A position-sensitive checksum, so two bodies that differ anywhere do not
// collide by accident: i64 arithmetic, no wrap, the same function on both
// sides of the comparison.
fn checksum(xs: const u8[:]) -> i64 {
    var h: i64 = 0;
    for x in xs { h = (h * 31 + x) % 1000000007; }
    return h;
}

// A log with no hexdump, for the bytes either side of the first difference.
fn show_around(tag: const u8[:], xs: const u8[:], at: i64) {
    guard at >= 0 else { return; }
    var from = at - 8;
    if from < 0 { from = 0; }
    var to = at + 16;
    if to > xs.len { to = xs.len; }
    var line: u8[>..] = [];
    format(line, tag, " [", from, "..", to, "):");
    for i in from..to { format(line, " ", xs[i] as i64); }
    print(line);
}

// Byte equality, local to this file: threads.goose does not import the support
// module, and a worker comparing what it decoded is the whole point here.
fn same_bytes(a: const u8[:], b: const u8[:]) -> bool {
    guard a.len == b.len else { return false; }
    for x, i in a {
        if x != b[i] { return false; }
    }
    return true;
}

// The reason the last failing call gave, compared with a variant. Five lines
// rather than a whole assertion shape at 40 call sites: with a bool return the
// detail is out of band, in igzip::status().
fn failed_as(want: igzip::Status) -> bool {
    return igzip::status() == want;
}

fn main() {
    // Queue the work before any worker exists, then one sentinel each.
    for i in JOBS - 2 { qput(Job { records: ((i + 1) * 50) as i32 }); }
    qput(Job { records: SHARED_RECORDS });
    qput(Job { records: SHARED_RECORDS });
    for i in WORKERS { qput(Job { records: -1 }); }
    for i in STREAM_JOBS - 2 { qput(StreamJob { records: ((i + 1) * 50) as i32 }); }
    qput(StreamJob { records: SHARED_RECORDS });
    qput(StreamJob { records: SHARED_RECORDS });
    for i in STREAM_WORKERS { qput(StreamJob { records: -1 }); }

    // Members compressed on this thread, to be decoded by a worker thread.
    //
    // The body for N records is a prefix of the body for more, so the largest
    // is built once and sliced. That is not only natural -- it is the only
    // shape that works on windows-x64: Goose v2026.4's MSVC output miscompiles
    // a second write into a growable buffer in the main program, leaving
    // fragments of the literals at the wrong offsets and zeros in the holes
    // (docs/internals.md, ROADMAP.md). One generation, written from an empty
    // buffer, is correct on every target, and the worker still regenerates
    // each body from scratch, so a wrong body cannot pass unnoticed.
    var body: u8[>..]  = [];
    var ends: i64[>..] = [];
    for i in 100 + (ROUND_JOBS - 1) * 75 {
        make_record(body, i as i32);
        ends.push(body.len);
    }

    var w = igzip::gzip_writer(1);
    var member: u8[>..] = [];
    for i in ROUND_JOBS {
        let records = 100 + i * 75;
        let prefix = ends[records - 1];
        member.clear();
        assert(w.write(body[..prefix], member));
        assert(w.finish(member));
        assert(w.reset());
        assert(member.len <= BOX);
        var box = RoundBox {
            records: records as i32,
            len:     member.len as i32,
            sum:     checksum(body[..prefix]),
            ..
        };
        box.data[..member.len].move_from(member[..]);
        qput(box);
    }
    qput(RoundBox { len: -1, .. });

    var ids: i64[>..] = [];
    for i in WORKERS { ids.push(thread_spawn(worker)); }
    var stream_ids: i64[>..] = [];
    for i in STREAM_WORKERS { stream_ids.push(thread_spawn(stream_worker)); }
    var reader_ids: i64[>..] = [];
    reader_ids.push(thread_spawn(reader_worker));

    // Results arrive in completion order, so nothing here depends on which
    // worker did what.
    var shared_seen = 0;
    var shared_size: i32 = 0;
    for i in JOBS {
        let r = qget<Result>();
        guard r.code == 0 else { abort(str("worker failed on ", r.records, " records")); };
        guard r.size > 0 else { abort(str("empty result for ", r.records, " records")); };

        if r.records == SHARED_RECORDS {
            if shared_seen == 0 {
                shared_size = r.size;
            } else if r.size != shared_size {
                abort("two workers disagreed on the size of the same input");
            }
            shared_seen++;
        }
    }
    guard shared_seen == 2 else { abort("the shared job did not come back twice"); };

    // Streaming jobs go through the same typed queue, one result each. The
    // two shared jobs must agree on size, as the Compressor jobs do.
    var stream_shared_seen = 0;
    var stream_shared_size: i32 = 0;
    for i in STREAM_JOBS {
        let r = qget<StreamResult>();
        guard r.code == 0 else { abort(str("stream worker failed on ", r.records, " records")); };
        guard r.size > 0 else { abort(str("empty stream result for ", r.records, " records")); };
        if r.records == SHARED_RECORDS {
            if stream_shared_seen == 0 {
                stream_shared_size = r.size;
            } else if r.size != stream_shared_size {
                abort("two streaming workers disagreed on the size of the same input");
            }
            stream_shared_seen++;
        }
    }
    guard stream_shared_seen == 2 else { abort("the shared streaming job did not come back twice"); };

    // Members compressed here, decoded on another thread, byte for byte. Every
    // result is collected before deciding, so one run reports every failing
    // member rather than the first one to arrive.
    var rounds_seen = 0;
    var round_failures = 0;
    var first_failure: i32 = 0;
    for i in ROUND_JOBS {
        let r = qget<RoundResult>();
        if r.code != 0 || !r.matched {
            round_failures++;
            if first_failure == 0 { first_failure = r.code; }
        }
        rounds_seen++;
    }
    guard rounds_seen == ROUND_JOBS else { abort("a round trip went missing"); };
    guard round_failures == 0 else {
        abort(str("reader worker failed (code ", first_failure, ") on ", round_failures,
                  " of ", ROUND_JOBS, " members"));
    };

    for id in ids { thread_wait(id); }
    for id in stream_ids { thread_wait(id); }
    for id in reader_ids { thread_wait(id); }

    print(WORKERS, " workers, ", JOBS, " jobs, ", shared_size, " bytes for ", SHARED_RECORDS,
          " records");
    print(ROUND_JOBS, " members compressed here, decoded on a worker thread, ",
          igzip::reader_size(), "-byte reader");
    print("threads: ok");
}

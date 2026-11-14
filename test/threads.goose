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
    data:    u8[BOX],
}

struct RoundResult {
    records: i32,
    matched: bool,
    code:    i32,
}

let STREAM_WORKERS = 2;
let STREAM_JOBS = 6;
let ROUND_JOBS = 4;

// One JSON schema, N records: the body a worker compresses.
fn make_body(out: u8[>..]&, records: i32) {
    for i in records {
        format(out, "{\"id\":", i, ",\"user\":\"alice\",\"email\":\"alice@example.com\",",
               "\"active\":true,\"score\":", i * 37 % 1000, ",\"tags\":[\"alpha\",\"beta\"]},\n");
    }
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
    var w = igzip::gzip_writer(1);
    var member: u8[>..] = [];
    var body:   u8[>..] = [];
    for i in ROUND_JOBS {
        let records = 100 + i * 75;
        body.clear();
        make_body(body, records as i32);
        member.clear();
        assert(w.write(body, member));
        assert(w.finish(member));
        assert(w.reset());
        assert(member.len <= BOX);
        var box = RoundBox { records: records as i32, len: member.len as i32, .. };
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

    // Members compressed here, decoded on another thread, byte for byte.
    var rounds_seen = 0;
    for i in ROUND_JOBS {
        let r = qget<RoundResult>();
        guard r.code == 0 else { abort(str("reader worker failed (code ", r.code, ")")); };
        guard r.matched else { abort("reader worker decoded the wrong bytes"); };
        rounds_seen++;
    }
    guard rounds_seen == ROUND_JOBS else { abort("a round trip went missing"); };

    for id in ids { thread_wait(id); }
    for id in stream_ids { thread_wait(id); }
    for id in reader_ids { thread_wait(id); }

    print(WORKERS, " workers, ", JOBS, " jobs, ", shared_size, " bytes for ", SHARED_RECORDS,
          " records");
    print(ROUND_JOBS, " members compressed here, decoded on a worker thread, ",
          igzip::reader_size(), "-byte reader");
    print("threads: ok");
}

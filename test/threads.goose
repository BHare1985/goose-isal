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

let STREAM_WORKERS = 2;
let STREAM_JOBS = 6;

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
        if !err.ok() { code = 1; }
        qput(Result {
            records: job.records,
            size:    if err == igzip::Status.Ok { out.len as i32 } else { -1 },
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
        if err.ok() {
            let done = holder[0].finish(out);
            if done.ok() {
                let again = holder[0].reset();
                if !again.ok() { code = 3; }
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

fn main() {
    // Queue the work before any worker exists, then one sentinel each.
    for i in JOBS - 2 { qput(Job { records: ((i + 1) * 50) as i32 }); }
    qput(Job { records: SHARED_RECORDS });
    qput(Job { records: SHARED_RECORDS });
    for i in WORKERS { qput(Job { records: -1 }); }
    for i in STREAM_JOBS { qput(StreamJob { records: ((i + 1) * 50) as i32 }); }
    for i in STREAM_WORKERS { qput(StreamJob { records: -1 }); }

    var ids: i64[>..] = [];
    for i in WORKERS { ids.push(thread_spawn(worker)); }
    var stream_ids: i64[>..] = [];
    for i in STREAM_WORKERS { stream_ids.push(thread_spawn(stream_worker)); }

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

    // Streaming jobs go through the same typed queue, one result each.
    for i in STREAM_JOBS {
        let r = qget<StreamResult>();
        guard r.code == 0 else { abort(str("stream worker failed on ", r.records, " records")); };
        guard r.size > 0 else { abort(str("empty stream result for ", r.records, " records")); };
    }

    for id in ids { thread_wait(id); }
    for id in stream_ids { thread_wait(id); }

    print(WORKERS, " workers, ", JOBS, " jobs, ", shared_size, " bytes for ", SHARED_RECORDS,
          " records");
    print("threads: ok");
}

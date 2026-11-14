// What a trained table is worth, on a workload that exists: an event-log API
// answering with JSON of the same shape every time.
//
//     goose build examples/bench.goose -o build/bench && ./build/bench
//
// Build it: `goose run` compiles through TinyCC, and timings from that mean
// nothing. The scenario is the one the training API exists for — one content
// type, many responses, a cache that samples the first few hundred and then
// compresses the rest with the table it learned.
//
// The result to look for: the trained table keeps level 1's ratio at level 0's
// speed. Untrained level 0 is just as fast and much worse; level 1 and 3 are as
// good and several times slower.
import std;
import os;
import igzip from "..";

let TRAIN = 200;     // responses sampled before the table is built
let MEASURED = 1000; // responses timed per mode
let SIZES: i64[2] = [10, 50];

fn level_of(i: i64) -> const u8[:] {
    return match i % 4 { 0 => "info", 1 => "warn", 2 => "error", _ => "debug" };
}

fn svc_of(i: i64) -> const u8[:] {
    return match i % 5 {
        0 => "checkout-api", 1 => "cart-api", 2 => "inventory", 3 => "auth", _ => "search",
    };
}

fn path_of(i: i64) -> const u8[:] {
    return match i % 5 {
        0 => "/v1/orders", 1 => "/v1/carts/8f2", 2 => "/v1/stock", 3 => "/v1/token", _ => "/v1/search",
    };
}

fn msg_of(i: i64) -> const u8[:] {
    return match i % 4 {
        0 => "payment authorized", 1 => "cart recalculated", 2 => "stock reserved", _ => "token refreshed",
    };
}

// A UUID-shaped id derived from the event number, so the corpus is reproducible
// without carrying a random state around.
fn hex_id(out: u8[>..]&, seed: i64) {
    var x = seed * 2654435761;
    for i in 8 {
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF;
        let digit = x % 16;
        out.push(if digit < 10 { ('0' + digit) as! u8 } else { ('a' + digit - 10) as! u8 });
        if i == 1 || i == 3 { out.push('-'); }
    }
}

// One observability event: timestamps, ids and paths vary, the schema does not.
fn event(out: u8[>..]&, i: i64) {
    format(out, "{\"ts\":\"2026-11-13T22:", i % 60, ":", (i * 7) % 60, ".", (i * 13) % 1000,
           "Z\",\"level\":\"", level_of(i), "\",\"svc\":\"", svc_of(i), "\",\"trace\":\"");
    hex_id(out, i);
    out.append("\",\"span\":\"");
    hex_id(out, i + 7);
    format(out, "\",\"ep\":\"", path_of(i), "\",\"dur_ms\":", (i * 37) % 900, ",\"status\":",
           (if i % 2 == 0 { 200 } else { 503 }), ",\"msg\":\"", msg_of(i), "\",\"user\":\"u",
           i % 99999, "\"}\n");
}

// One HTTP response: `count` events, the way an endpoint pages them back.
fn response(out: u8[>..]&, first: i64, count: i64) {
    out.clear();
    for k in count { event(out, first + k); }
}

// Every response the run needs, laid end to end, with the offset where each
// one starts. Built once so the timings measure the compressor and nothing
// else.
fn build_arena(arena: u8[>..]&, at: i64[>..]&, per: i64, count: i64) {
    var scratch: u8[>..] = [];
    at.push(0);
    for i in count {
        response(scratch, i, per);
        arena.append(scratch[..]);
        at.push(arena.len);
    }
}

fn ratio_tenths(compressed: i64, original: i64) -> i64 {
    if original == 0 { return 0; }
    return compressed * 1000 / original;
}

fn report(label: const u8[:], compressed: i64, original: i64, ns: i64) {
    let r = ratio_tenths(compressed, original);
    print("  ", label, "  ", r / 10, ".", r % 10, "%   ", ns / MEASURED / 1000, " us/response");
}

fn run(c: igzip::Compressor&, arena: u8[>..]&, at: i64[>..]&, out: u8[>..]&) -> i64, i64 {
    var compressed: i64 = 0;
    let start = clock_ns();
    for i in MEASURED {
        out.clear();
        let body = arena[at[TRAIN + i]..at[TRAIN + i + 1]];
        let err = c.compress(body, out);
        if !err { abort(str("compress failed: ", igzip::error())); }
        compressed += out.len;
    }
    return compressed, clock_ns() - start;
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
    var out: u8[>..] = [];

    for s in 2 {
        let per = SIZES[s];

        var arena: u8[>..]  = [];
        var at:    i64[>..] = [];
        build_arena(arena, at, per, TRAIN + MEASURED);

        // Warm a table on the first TRAIN responses of this content type.
        var trainer = igzip::trainer();
        for i in TRAIN {
            let err = trainer.add(arena[at[i]..at[i + 1]]);
            if !err { abort(str("compress failed: ", igzip::error())); }
        }
        let tables, built = trainer.build();
        if !built { abort(igzip::error()); }

        let size = at[1] - at[0];
        let original = size * MEASURED;
        print("\nresponses of ", per, " events, ", size, " bytes each (", trainer.symbols(),
              " symbols sampled)");

        var lv1 = igzip::gzip_compressor(1);
        var lv3 = igzip::gzip_compressor(3);
        var lv0 = igzip::gzip_compressor(0);
        var trained = igzip::gzip_compressor(1);
        trained.set_tables(tables);

        let c1, t1 = run(lv1, arena, at, out);
        let c3, t3 = run(lv3, arena, at, out);
        let c0, t0 = run(lv0, arena, at, out);
        let ct, tt = run(trained, arena, at, out);

        report("level 1          ", c1, original, t1);
        report("level 3          ", c3, original, t3);
        report("level 0, default ", c0, original, t0);
        report("level 0, trained ", ct, original, tt);

        // The claim in one line: level 1's ratio, level 0's speed.
        let speedup = t1 * 10 / tt;
        print("  trained: ", speedup / 10, ".", speedup % 10, "x faster than level 1, ",
              ct * 100 / c1, "% of its bytes");
    }
}

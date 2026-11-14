// Train a Huffman table on a corpus, then compress with it.
//
//     goose run examples/trained_table.goose -- corpus.json
//
// The shape a server uses: sample the bodies of one content type once, build a
// table, then compress every later body of that type at level 0 with it. Level
// 0 is the only level that honours a supplied table, and it is also the fastest
// path.
import std;
import os;
import igzip from "..";

let MIN_SAMPLES = 8;

fn report(label: const u8[:], size: i64) {
    print("  ", label, ": ", size, " bytes");
}

// The reason the last failing call gave, compared with a variant. Five lines
// rather than a whole assertion shape at 40 call sites: with a bool return the
// detail is out of band, in igzip::status().
fn failed_as(want: igzip::Status) -> bool {
    return igzip::status() == want;
}

fn main() {
    let argv = args();
    guard argv.len > 1 else {
        print("usage: trained_table <file>");
        exit(2);
    }

    var corpus: u8[>..] = [];
    guard read_file(argv[1], corpus) else { abort(str("cannot read ", argv[1])); };
    guard corpus.len > 4096 else { abort("corpus too small to train on"); };

    // Sample eight slices of the corpus, the way a cache warms from whole
    // responses. Each sample is counted on its own, so matches do not span
    // sample boundaries.
    var trainer = igzip::trainer();
    let step = corpus.len / MIN_SAMPLES;
    for i in MIN_SAMPLES {
        let lo = i * step;
        let hi = if i == MIN_SAMPLES - 1 { corpus.len } else { lo + step };
        let err = trainer.add(corpus[lo..hi]);
        guard err else { abort(igzip::error()); };
    }
    print("sampled ", trainer.symbols(), " symbols from ", corpus.len, " bytes");

    let tables, built = trainer.build();
    guard built else {
        abort(str("table build failed: ", igzip::error()));
    };

    // Compress the whole corpus three ways and compare.
    var c0 = igzip::gzip_compressor(0);
    var c1 = igzip::gzip_compressor(1);
    var ct = igzip::gzip_compressor(1);
    ct.set_tables(tables);

    let lv0, err0 = c0.compressed(corpus);
    guard err0 else { abort(igzip::error()); };
    let lv1, err1 = c1.compressed(corpus);
    guard err1 else { abort(igzip::error()); };
    let trained, errt = ct.compressed(corpus);
    guard errt else { abort(igzip::error()); };

    print("original: ", corpus.len, " bytes");
    report("level 0, default table", lv0.len);
    report("level 1, default table", lv1.len);
    report("level 0, trained table", trained.len);

    if trained.len < lv0.len {
        print("trained table beats the level 0 default by ", lv0.len - trained.len, " bytes");
    } else {
        print("trained table did not help this corpus; keep level 1");
    }
}

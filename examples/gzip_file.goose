// Compress a file with ISA-L's igzip.
//
//     goose build examples/gzip_file.goose -o build/gzip_file
//     ./build/gzip_file notes.txt        # writes notes.txt.gz
//     ./build/gzip_file notes.txt 0      # level 0, the fastest
//
// A one-shot tool: `igzip::gzip` declares the compressor, compresses, and lets
// the scope free it. A server keeps one compressor per thread instead and
// appends into a buffer it already owns.
import std;
import os;
import igzip from "..";

fn main() {
    let argv = args();
    guard argv.len > 1 else {
        print("usage: gzip_file <file> [level 0..3]");
        exit(2);
    }

    var level: i32 = 1;
    if argv.len > 2 {
        let n, ok = parse_int(argv[2]);
        if ok { level = n as i32; }
    }

    var body: u8[>..] = [];
    guard read_file(argv[1], body) else {
        abort(str("cannot read ", argv[1]));
    }

    let gz, err = igzip::gzip(body, level);
    guard err.ok() else {
        abort(str("compress failed: ", igzip::status_name(err)));
    }

    let path = str(argv[1], ".gz");
    guard write_file(path, gz) else { abort(str("cannot write ", path)); };

    print(path, ": ", body.len, " -> ", gz.len, " bytes");
    if body.len > 0 {
        // Integer percentage, without floats.
        print("ratio: ", gz.len * 100 / body.len, "% of the original");
    }
}

// Compress a file with ISA-L's igzip.
//
//     goose build examples/gzip_file.goose -o build/gzip_file
//     ./build/gzip_file notes.txt        # writes notes.txt.gz
//     ./build/gzip_file notes.txt 0      # level 0, the fastest
//
// A one-shot tool: `igzip::gzip` declares the compressor, compresses, and lets
// the scope free it. A server keeps one compressor per thread instead and
// appends into a buffer it already owns.
//
// The file is then read back with the package's own reader before the tool
// says it succeeded. A compressor can return Ok with a plausible size and still
// emit a broken stream, so "it compressed" is not evidence.
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

    // Read it back: a complete member that decodes to what went in.
    var r = igzip::gzip_reader();
    let back, derr = r.inflated(gz);
    guard derr.ok() else { abort(str("verify failed: ", igzip::status_name(derr))); };
    guard back == body else { abort("verify failed: the file does not round trip"); };

    print(path, ": ", body.len, " -> ", gz.len, " bytes");
    if body.len > 0 {
        // Integer percentage, without floats.
        print("ratio: ", gz.len * 100 / body.len, "% of the original");
    }
}

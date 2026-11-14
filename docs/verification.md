# Verification

What `make verify` proves, and which file proves it. The claim behind all of it
is the one in [AGENTS.md](../AGENTS.md): *a compressor can return `Ok` with a
plausible size and still emit a broken stream, so passing tests are not evidence
on their own.*

| Command | What it runs |
|---|---|
| `make check` | `goose check igzip.goose` — typecheck only, silent on success |
| `make test` | every `test/*.goose` under the JIT except the two native ones; each asserts, and each decodes what it wrote |
| `make crosscheck` | the artifacts, through CPython's `zlib` (skipped when `python3` is absent) |
| `make test-threads` | `test/threads.goose`, native |
| `make test-large` | `test/large_stream.goose`, native: 4.2 GiB |
| `make stress` | `scripts/bound_stress.c` and `scripts/read_stress.c` under AddressSanitizer |
| `make verify` | all of the above except `stress` |

## By file

**`test/contract.goose`** — one-shot. Layouts match the C `sizeof`s; every level
and wrapper stays inside `bound(n)`; invalid levels, oversized inputs and
fabricated tables are rejected before igzip sees them; two runs are identical;
trained tables beat level 0's default; counts round-trip to a bit-identical
table; the empty input is a valid 20-byte member. Every artifact it writes is
decoded twice — by `decode_is` in Goose and by the crosscheck — as it is written.

**`test/writer_contract.goose`** — the writer's state machine: transitions and
64-bit totals; legal and illegal `set_tables` / `set_dict` ordering; copies after
a write, a header, `finish`, `set_dict` or `set_tables`; reset from `Open`,
`Flushed` and `Finished`; custom, large and default gzip headers; name/comment NUL
rejection; the 65,535-byte extra boundary; zlib window/FLEVEL; dictionary
FDICT/DICTID and matching/mismatched IDs; trained tables, mid-flush swaps and
`clear_tables`. Every custom-header stream is decoded back to the same body.

**`test/inflate_contract.goose`** — the reader's state machine, cell by cell
against the matrix in [design/0.3.0.md](design/0.3.0.md) §5 Q11; a terminal error
latching; the copy guard and its recovery; `Truncated` from `finish`, from
`inflated("")` and from `inflate`; `TooSmall` at the exact size, one byte short and
a zero-length destination, and a clean reader after it; `NeedDict` and the resume
after it; dictionaries supplied up front, after `NeedDict`, wrong, empty, on gzip
(refused) and on raw (undetectable, pinned as documented behaviour); trailing
bytes; concatenated members; truncations at five depths; non-gzip bytes, a bad
compression method and 16 mutated streams; windows from one byte up; output larger
than the staging chunk both in one call and one input byte at a time; and a whole
member driven through `igzip_gs_reader_step` with 1- and 8-byte destinations.

**`test/header_contract.goose`** — headers both directions. Every header the
writer emits parses back to the same fields and the same optional parts — an
all-fields header with FHCRC, an empty name (absent, not present-and-empty), a
default header, and one larger than the 64 KiB chunk. `body_at` is proved by
decoding the bytes from it as a standalone raw stream. Hostile headers: not gzip,
a method zlib does not define, reserved FLG bits, every prefix of a valid header
(`Truncated`, never `Ok`), an XLEN past the end, a name with no terminator, a
header ending inside FHCRC, a bad zlib check value, CINFO above 7, a missing
DICTID.

**`test/roundtrip.goose`** — the headline. Three wrappers × four levels × eleven
sizes (either side of the 32 KiB history, the 64 KiB staging chunk, one byte and
zero), compressible and incompressible bodies, trained tables through both
`Compressor` and `Writer`, and four members joined. Each stream is decoded ten
ways: one `read`, `read` in 1-, 3- and 1000-byte input chunks, `read_windowed` at
1, 97 and 1 MiB, `inflate` into an exact destination, `inflate` retried from a
one-byte destination until it fits, and `inflated` — compared byte for byte.

**`test/streaming.goose`** — end-to-end: one-shot equivalence at levels 1–3 for
every wrapper from 32 KiB to 316 KiB; chunked writes at 1, 7, 63, 4,096 and
70,000 bytes; 1 MiB in 64 KiB windows; `Sync` and `Full` decode points; two
flushes in a row; a 4 MiB incompressible stream that crosses the output chunk; a
`Full` flush's tail decoding as a standalone raw stream in Goose.

**`test/threads.goose`** — four compressor workers, two streaming workers and a
reader worker, each with its own value; two workers compressing the same input
must agree on the size; and members compressed on the main thread are decoded on
a worker thread, byte for byte.

**`test/large_stream.goose`** — one writer fed 4.2 GiB in 1 MiB pieces, each
compressed piece decoded by one reader on the way past, in a few MiB of RAM.
Checks `total_out == total_in == 4,404,019,200` (a `u64`, past igzip's 32-bit
`total_out`), a sampled byte comparison against the repeating body, and the
wrapped 32-bit gzip ISIZE.

**`scripts/bound_stress.c`** — allocates `bound(n)` *exactly* and compresses
adversarial inputs at every level and wrapper, then drives the stateful path with
output slices as small as 8 bytes and writes gzip headers into exact-size and
one-byte-short buffers: 600 cases, no overrun.

**`scripts/read_stress.c`** — decodes into destinations from 1 byte to 64 KiB,
from level 0 (stored and static-Huffman blocks) and level 1 (dynamic-Huffman block
headers), at every truncation offset, through 400 mutations and the dictionary
paths. It also pins the assumption the reader rests on: stateless inflate is
honest about `avail_out` (one byte short is `ISAL_OUT_OVERFLOW` with exactly
`dst.len` bytes written), unlike stateless deflate.

**`scripts/check_gzip.py`** — 43 streams inflated with CPython's `zlib` and
compared byte for byte: every wrapper and level, sizes on deflate's block seams,
deterministic repeats, concatenated members, incompressible noise, trained and
trained-on-half streams, the empty member, chunked/default/level-0 streams, both
flush points, the trained-table flush swap, custom and large headers, the zlib
header, dictionary streams with `zdict`, and the 4 MiB stream. It also checks
`mtime = 0` where promised, parses header *fields* independently, checks
FDICT/DICTID, and decodes the custom zlib windows with
`zlib.decompressobj(window_bits)` rather than the permissive 15-bit default.

## Two ISA-L behaviours that show up in results

1. At level 0 the stateful path ends a stream one stored byte differently from the
   stateless path. Levels 1–3 are byte-identical; level 0 emits a valid stream of
   its own. `/tmp`'s crosscheck decodes both.
2. A corrupted payload usually comes back as `Ok` with the member unfinished, not
   as an error: igzip consumes the input, emits whatever the corrupted block
   spelled, and reports success with `block_state` short of `FINISH`. CPython's
   `zlib` says the same thing (`eof=False`). Only `finished`/`finish` can tell
   that apart, which is why `finish` exists.

## Sample output

```
[ok]   determinism           two runs gave identical bytes
[ok]   ratio vs zlib l1          2113 bytes vs 2219
[ok]   ratio vs zlib l9          1887 bytes vs 1868
[ok]   matrix/gzip_1.gz          2113 bytes    6.7% of 31364
[ok]   trained.gz                2135 bytes    6.8% of 31364
[ok]   trained table saves 960 bytes over the level 0 default
43/43 streams valid
4 workers, 16 jobs, 2977 bytes for 425 records
4 members compressed here, decoded on a worker thread, 152936-byte reader
4200 MiB, ISIZE 109051904, total_in 4404019200, decoded 4404019200
600 cases, 0 failures: bound and avail_out held as exact sizes
read_stress: ok (streaming, stateless, truncations, mutations, dictionary)
```

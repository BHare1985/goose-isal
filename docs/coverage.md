# igzip coverage

What `vendor/isa-l/include/igzip_lib.h` exposes, and what this package does with
it. Everything in the left column is either reachable through the public API or
listed below with a reason it is not.

## Exposed

| igzip | This package |
|---|---|
| `isal_deflate_stateless_init` / `isal_deflate_stateless` | `Compressor`, `compress` / `compressed`, `gzip` |
| `isal_deflate_init` / `isal_deflate` / `isal_deflate_reset` | `Writer`, `write` / `flush` / `finish` / `reset` |
| `NO_FLUSH`, `SYNC_FLUSH`, `FULL_FLUSH`, `end_of_stream` | `write`, `flush(Sync\|Full)`, `finish` |
| `isal_deflate_set_dict` | `set_dict` (writer: `Fresh`; the dictionary is copied) |
| `isal_deflate_set_hufftables` (custom and default) | `set_tables` / `clear_tables` |
| `isal_write_gzip_header` / `isal_gzip_header_init` | `GzipHeader`, `write_gzip_header` |
| `isal_write_zlib_header` / `isal_zlib_header_init` | `ZlibHeader`, `write_zlib_header` |
| `isal_update_histogram` | `Trainer`, `add` |
| `isal_create_hufftables` | `Trainer.build`, `HuffTables` |
| `isal_inflate_init` / `isal_inflate` / `isal_inflate_reset` | `Reader`, `read` / `finished` / `finish` / `reset` |
| `isal_inflate_stateless` | `inflate` (into a caller-sized slice), `inflated` (streaming loop) |
| `isal_inflate_set_dict` | `set_dict` on a reader |
| `isal_read_gzip_header` | `read_gzip_header` → `GzipInfo` |
| `isal_read_zlib_header` | `read_zlib_header` → `ZlibInfo` |
| `ISAL_BLOCK_FINISH` | `finished(r)` |
| `IGZIP_GZIP`, `IGZIP_GZIP_NO_HDR`, `IGZIP_ZLIB`, `IGZIP_ZLIB_NO_HDR`, `IGZIP_DEFLATE` | `Wrapper`, plus the explicit-header paths |
| `ISAL_DEF_LVL3_MEDIUM`, `ISAL_DEF_MAX_HDR_SIZE`, `IGZIP_HIST_SIZE` | baked into the values and asserted, not exposed as knobs |

## Not exposed, with the reason

| igzip | Why not | Cost of adding it |
|---|---|---|
| `isal_create_hufftables_subset` | A subset table leaves out literals the samples never saw, and a body containing one cannot be encoded correctly — silently, since deflate has no error channel. The package builds complete tables so an unseen byte still encodes. | A flag on `build`; the caller then owns "my training data covered every byte", which is exactly the assumption a library should not quietly make |
| `isal_deflate_process_dict` / `isal_deflate_reset_dict` | A cache for a *fixed* dictionary: preprocess once, attach to each stream. `set_dict` already makes dictionaries correct; this makes them faster. | A second stateful value sized by level, plus its own lifetime rules — a performance feature with a design cost, so it waits for a caller who asks |
| `IGZIP_HUFFTABLE_STATIC` | A table choice, not an operation. The package supports default and trained tables; a third source is additive. | One call |
| `crc32_gzip_refl`, `crc32_ieee`, `crc16`, `crc64`, `crc32c` | Checksums are not a codec capability: igzip verifies a trailer itself through `crc_flag`, and this package's scope is the container and the codec. See below. | Additive, but a second purpose for the package |
| FHCRC verification in `read_gzip_header` | `isal_inflate` steps over the header CRC, so verifying it in one entry point and not the other would make the package disagree with itself. `info.hcrc` reports that the field is present. | Comes with the checksum decision below |
| Erasure coding, RAID, memory routines (`erasure_code.h`, `raid.h`, `mem_routines.h`) | Not igzip. Each is a package of its own with a different audience and a different API shape. | Out of scope by name |

## The checksum decision

`isal_adler32` is declared in `igzip_lib.h`, and igzip uses both it and
`crc32_gzip_refl` internally: the zlib DICTID this package's writer emits is an
Adler-32, and every gzip member's trailer is a CRC-32. Both are reachable from
this package *indirectly* — write a dictionary, read the DICTID off the header,
and check it against your own idea of the dictionary.

They are not exposed as functions, on purpose. A caller who wants a CRC has a
library for it, generally a faster general-purpose one; a caller who wants to
know whether a stream is intact asks the `Reader`, which already answers with
`BadChecksum`. Exposing `crc32_gzip_refl` would also oblige the package to answer
for `crc32_ieee` (a *different*, non-reflected CRC-32 that gzip does not use),
`crc16`, `crc64` and `crc32c` — none of which a gzip stream needs.

So the boundary is: this package verifies checksums, and does not compute them.
If a real caller needs one, the honest shape is a separate small package, not a
seventh purpose for this one.

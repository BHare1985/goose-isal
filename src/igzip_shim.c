/* igzip_shim.c: the C side of the Goose isal package.
 *
 * This file owns no memory. Each Goose value carries the igzip state it needs:
 *
 *   Compressor   82,384-byte isal_zstream + 217,088-byte level buffer
 *   Trainer      18,912-byte isal_huff_histogram
 *
 * Goose frees them when the owning scope ends, like any other value, so there
 * is nothing to open and nothing to close. A trained HuffTables (2,232 bytes)
 * is a plain Goose value; the compressor keeps its own copy when given one.
 *
 * There are no globals and no mutable statics: every byte touched here came
 * from a Goose value or was lent for the duration of one call. Two compressors
 * in two threads share nothing, which is why igzip.build does not declare
 * main_thread_only.
 *
 * Two igzip behaviours the API is built around, measured on 2.32.1 and
 * unchanged from 2.31.1:
 *
 *   1. A supplied Huffman table is used at level 0 only. Levels 1-3 build
 *      their own tables per block (igzip.c: create_hufftables_icf), so
 *      isal_deflate_set_hufftables has no effect there. The Goose layer pins
 *      level 0 when a table is set.
 *   2. isal_update_histogram keeps match positions in a scratch hash table.
 *      Counting a second sample without clearing that table would compare it
 *      against stale offsets, so every call clears it and keeps the counters.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "goose.h" /* gs_rref, gs_bld_append */

/* CMake puts vendor/isa-l/include on the include path, so the vendored tree is
 * reached by the headers' bare names. An installed ISA-L is reached the same
 * way with -I<prefix>/include/isa-l. */
#include <igzip_lib.h>
#include <isal_api.h>

/* A `const u8[:]` argument arrives as this packed { data, len } pair (spec
 * C.2). goose.h ships the builder types but no slice type, because the runtime
 * only needs the slices it declares itself. */
typedef struct {
	const uint8_t *data;
	int64_t len;
} igzip_slice_u8;

/* ---- Goose-side layout mirrors ------------------------------------------- */
/* A package's C is compiled on its own, so it cannot see the program's
 * generated types. These match igzip.goose, and the asserts below fail the
 * build rather than let a silent drift through. */

#define ISAL_LIT_LEN_SYMBOLS ISAL_DEF_LIT_LEN_SYMBOLS /* 286 */
#define ISAL_DIST_SYMBOLS ISAL_DEF_DIST_SYMBOLS       /* 30 */
#define ISAL_HIST_BYTES ((ISAL_LIT_LEN_SYMBOLS + ISAL_DIST_SYMBOLS) * 8)
#define ISAL_LEVEL_BUF ISAL_DEF_LVL3_MEDIUM

/* Compressor.state: everything a one-shot deflate needs, and nothing else. */
typedef struct {
	struct isal_zstream zs;
	uint8_t lvb[ISAL_LEVEL_BUF];
} igzip_comp_state;

/* Goose's Compressor starts with `state: u64[37434]`, so C receives a pointer
 * to the aggregate and reads that first field. The rest of the struct (the
 * table copy, the level, the wrapper) is Goose's business. */
typedef struct {
	uint64_t state[sizeof(igzip_comp_state) / 8];
} Compressor_g;

/* Trainer.state: the histogram, counters and scratch together, so a sample is
 * counted straight into the value Goose owns. */
typedef struct {
	struct isal_huff_histogram hist;
} igzip_train_state;

typedef struct {
	uint64_t state[sizeof(igzip_train_state) / 8];
} Trainer_g;

typedef struct {
	uint64_t raw_g[ISAL_HIST_BYTES / 8];
} Histogram_g;

typedef struct {
	uint64_t raw_g[279];
} HuffTables_g;

/* Writer: the streaming state. Its size is pinned because Goose allocates it
 * inline and C casts the u64 arrays back to the ISA-L types. The field order
 * matches igzip.goose; every offset below is asserted. */
#define GS_WRAP_RAW 0
#define GS_WRAP_GZIP 1
#define GS_WRAP_ZLIB 2

#define GS_FRESH 0
#define GS_HDR 1
#define GS_OPEN 2
#define GS_FLUSHED 3
#define GS_FINISHED 4

#define GS_CHUNK 65536

/* Package-specific statuses occupy -8 and -10; keep any new code disjoint
 * from ISA-L's own negative returns. -8 is a header the API cannot encode (an
 * interior NUL, too-long name/comment/extra, or an impossible zlib flag); -10
 * is a Writer table that failed validation at use. */
#define IGZIP_GS_BAD_HEADER (-8)
#define IGZIP_GS_BAD_TABLE (-10)

typedef struct {
	uint64_t stream[sizeof(struct isal_zstream) / 8];
	uint64_t level_buf[ISAL_LEVEL_BUF / 8];
	uint8_t chunk[GS_CHUNK];
	uint64_t tables[sizeof(struct isal_hufftables) / 8];
	uint64_t pinned_self;
	uint64_t total_in;
	uint64_t total_out;
	uint32_t dict_id;
	int32_t base_level;
	uint8_t wrap;
	uint8_t state;
	bool has_tables;
	bool has_dict;
	bool hdr_written;
} GooseWriter;

_Static_assert(sizeof(bool) == 1, "Goose bool must be one byte for the Writer mirror");
_Static_assert(sizeof(GooseWriter) == 367280, "Writer size changed; update igzip.goose");
_Static_assert(_Alignof(GooseWriter) >= 8, "Writer must be 8-byte aligned for isal_zstream");
_Static_assert(sizeof(((GooseWriter *)0)->stream) == sizeof(struct isal_zstream),
	       "Writer.stream must hold an isal_zstream");
_Static_assert(sizeof(((GooseWriter *)0)->level_buf) == ISAL_LEVEL_BUF,
	       "Writer.level_buf must be ISAL_LEVEL_BUF bytes");
_Static_assert(sizeof(((GooseWriter *)0)->tables) == sizeof(struct isal_hufftables),
	       "Writer.tables must hold an isal_hufftables");
_Static_assert(sizeof(((GooseWriter *)0)->chunk) == GS_CHUNK, "Writer.chunk must be 64 KiB");
_Static_assert(offsetof(GooseWriter, stream) == 0, "Writer.stream offset");
_Static_assert(offsetof(GooseWriter, level_buf) == 82384, "Writer.level_buf offset");
_Static_assert(offsetof(GooseWriter, chunk) == 299472, "Writer.chunk offset");
_Static_assert(offsetof(GooseWriter, tables) == 365008, "Writer.tables offset");
_Static_assert(offsetof(GooseWriter, pinned_self) == 367240, "Writer.pinned_self offset");
_Static_assert(offsetof(GooseWriter, total_in) == 367248, "Writer.total_in offset");
_Static_assert(offsetof(GooseWriter, total_out) == 367256, "Writer.total_out offset");
_Static_assert(offsetof(GooseWriter, dict_id) == 367264, "Writer.dict_id offset");
_Static_assert(offsetof(GooseWriter, base_level) == 367268, "Writer.base_level offset");
_Static_assert(offsetof(GooseWriter, wrap) == 367272, "Writer.wrap offset");
_Static_assert(offsetof(GooseWriter, state) == 367273, "Writer.state offset");
_Static_assert(offsetof(GooseWriter, has_tables) == 367274, "Writer.has_tables offset");
_Static_assert(offsetof(GooseWriter, has_dict) == 367275, "Writer.has_dict offset");
_Static_assert(offsetof(GooseWriter, hdr_written) == 367276, "Writer.hdr_written offset");

_Static_assert(sizeof(igzip_comp_state) % 8 == 0, "Compressor must be a whole number of u64");
_Static_assert(sizeof(igzip_train_state) % 8 == 0, "Trainer must be a whole number of u64");
/* Goose stores the state as u64[...], which is 8-byte aligned. Neither C
 * struct asks for more, so the casts in comp_of/train_of are sound. */
_Static_assert(_Alignof(struct isal_zstream) <= 8, "isal_zstream needs more alignment than u64 gives");
_Static_assert(_Alignof(struct isal_huff_histogram) <= 8, "histogram needs more alignment than u64 gives");
_Static_assert(sizeof(((Compressor_g *)0)->state) == sizeof(igzip_comp_state),
	       "Compressor.state in igzip.goose must be u64[37434]");
_Static_assert(sizeof(((Trainer_g *)0)->state) == sizeof(igzip_train_state),
	       "Trainer.state in igzip.goose must be u64[2364]");
_Static_assert(sizeof(HuffTables_g) == sizeof(struct isal_hufftables),
	       "HuffTables.raw in igzip.goose must be sizeof(struct isal_hufftables) / 8");
_Static_assert(sizeof(Histogram_g) == ISAL_HIST_BYTES, "Histogram.raw must hold 286 + 30 counters");
_Static_assert(offsetof(struct isal_huff_histogram, dist_histogram) == ISAL_LIT_LEN_SYMBOLS * 8,
	       "histogram counter layout changed");
_Static_assert(offsetof(struct isal_huff_histogram, hash_table) == ISAL_HIST_BYTES,
	       "histogram scratch layout changed");

/* Worst case expansion is a stored block per 65535 bytes plus headers. Measured
 * on incompressible input: +23 bytes for 1 KiB, +103 for 1 MiB. */
#define ISAL_BOUND_MARGIN 512

static igzip_comp_state *comp_of(Compressor_g *s) {
	return (igzip_comp_state *)(void *)s->state;
}

static igzip_train_state *train_of(Trainer_g *s) {
	return (igzip_train_state *)(void *)s->state;
}

/* Claims n bytes the caller already wrote at the builder's stack top. This is
 * gs_bld_append's effect without the copy: goose.h documents that C may write a
 * builder's elements and append whole ones by moving the stack top and the
 * header's count together. */
static void bld_claim(gs_rref b, int64_t n) {
	if (n <= 0) return;
	b.stk->top += n;
	b.hdr->len += n;
}

/* ---- diagnostics --------------------------------------------------------- */

int32_t igzip_gs_version_major(void) { return ISAL_MAJOR_VERSION; }
int32_t igzip_gs_version_minor(void) { return ISAL_MINOR_VERSION; }
int32_t igzip_gs_version_patch(void) { return ISAL_PATCH_VERSION; }

int64_t igzip_gs_bound(int64_t n) {
	if (n < 0) return 0;
	int64_t bound = n + (n / 65535 + 1) * 6 + ISAL_BOUND_MARGIN;
	if (bound > 0x7FFFFFF0) bound = 0x7FFFFFF0; /* igzip lengths are 32-bit */
	return bound;
}

int64_t igzip_gs_compressor_size(void) { return (int64_t)sizeof(igzip_comp_state); }
int64_t igzip_gs_trainer_size(void) { return (int64_t)sizeof(igzip_train_state); }

/* ---- training ------------------------------------------------------------ */

int32_t igzip_gs_hist_add(Trainer_g *t, igzip_slice_u8 sample) {
	if (!t) return ISAL_INVALID_STATE;
	if (sample.len < 0 || sample.len > 0x7FFFFFF0) return STATELESS_OVERFLOW;
	int32_t len = (int32_t)sample.len;
	if (len == 0) return COMP_OK;
	igzip_train_state *c = train_of(t);
	/* The counters accumulate; the match scratch does not, and stale offsets
	 * from the previous sample would be read against this one. */
	memset(c->hist.hash_table, 0, sizeof c->hist.hash_table);
	isal_update_histogram((uint8_t *)(uintptr_t)sample.data, len, &c->hist);
	return COMP_OK;
}

int64_t igzip_gs_hist_symbols(const Trainer_g *t) {
	if (!t) return 0;
	const igzip_train_state *c = (const igzip_train_state *)(const void *)t->state;
	int64_t total = 0;
	for (int i = 0; i < ISAL_LIT_LEN_SYMBOLS; i++) total += (int64_t)c->hist.lit_len_histogram[i];
	return total;
}

/* A complete Huffman table: every literal keeps a code, so a body containing
 * bytes the samples never saw still encodes (isal_create_hufftables, not the
 * _subset variant). */
int32_t igzip_gs_tables_build(const Trainer_g *t, HuffTables_g *dst) {
	if (!t || !dst) return ISAL_INVALID_STATE;
	const igzip_train_state *c = (const igzip_train_state *)(const void *)t->state;
	return isal_create_hufftables((struct isal_hufftables *)dst->raw_g, &c->hist);
}

/* The counters are the first 2,528 bytes of the histogram struct: 286
 * literal/length counts then 30 distance counts. Copying between those and
 * Goose's `Histogram` happens here and nowhere else. */
static void counters_to(uint64_t *dst, const struct isal_huff_histogram *src) {
	memcpy(dst, src->lit_len_histogram, sizeof src->lit_len_histogram);
	memcpy(dst + ISAL_LIT_LEN_SYMBOLS, src->dist_histogram, sizeof src->dist_histogram);
}

static void counters_from(struct isal_huff_histogram *dst, const uint64_t *src) {
	memcpy(dst->lit_len_histogram, src, sizeof dst->lit_len_histogram);
	memcpy(dst->dist_histogram, src + ISAL_LIT_LEN_SYMBOLS, sizeof dst->dist_histogram);
}

/* The counters alone, so a cache can keep many content types at 2,528 bytes
 * each and rehydrate a trainer when it has a sample to count. */
void igzip_gs_hist_export(const Trainer_g *t, Histogram_g *dst) {
	if (!t || !dst) return;
	const igzip_train_state *c = (const igzip_train_state *)(const void *)t->state;
	counters_to(dst->raw_g, &c->hist);
}

void igzip_gs_hist_import(Trainer_g *t, const Histogram_g *src) {
	if (!t || !src) return;
	igzip_train_state *c = train_of(t);
	memset(&c->hist, 0, sizeof c->hist);
	counters_from(&c->hist, src->raw_g);
}

/* A HuffTables value is a raw mirror of `struct isal_hufftables`, and igzip
 * trusts it: write_deflate_header_stateless reads
 * `deflate_hdr[deflate_hdr_count]` and memcpy's `deflate_hdr_count` bytes out of
 * it. A fabricated or deserialized table with a count past the 328-byte header
 * array therefore reads past this value — and copies what it finds into the
 * caller's output. The count and the trailing bit count are checked before any
 * table reaches igzip; everything else in the struct is only used as code
 * lengths, which cannot address memory. */
int32_t igzip_gs_tables_check(const HuffTables_g *t) {
	if (!t) return ISAL_INVALID_STATE;
	const struct isal_hufftables *h = (const struct isal_hufftables *)(const void *)t->raw_g;
	if (h->deflate_hdr_count > ISAL_DEF_MAX_HDR_SIZE) return ISAL_INVALID_OPERATION;
	if (h->deflate_hdr_extra_bits > 7) return ISAL_INVALID_OPERATION;
	return COMP_OK;
}

/* ---- compression --------------------------------------------------------- */

static int32_t run(Compressor_g *s, igzip_slice_u8 src, gs_rref out, int32_t level, int32_t wrap,
		   const HuffTables_g *tables) {
	if (!s) return ISAL_INVALID_STATE;
	if (src.len < 0 || src.len > 0x7FFFFFF0) return STATELESS_OVERFLOW;

	igzip_comp_state *c = comp_of(s);
	int64_t cap = igzip_gs_bound(src.len);

	isal_deflate_stateless_init(&c->zs);
	c->zs.next_in = (uint8_t *)(uintptr_t)src.data;
	c->zs.avail_in = (uint32_t)src.len;
	/* The compressed bytes go straight into the builder's stack top; only the
	 * bytes actually written are claimed afterwards. */
	c->zs.next_out = out.stk->top;
	c->zs.avail_out = (uint32_t)cap;
	c->zs.end_of_stream = 1;
	c->zs.level = (uint32_t)level;
	c->zs.gzip_flag = (uint16_t)wrap;
	if (level > 0) {
		c->zs.level_buf = c->lvb;
		c->zs.level_buf_size = (uint32_t)sizeof c->lvb;
	}
	if (tables) c->zs.hufftables = (struct isal_hufftables *)(uintptr_t)tables->raw_g;

	int32_t rc = (int32_t)isal_deflate_stateless(&c->zs);
	int64_t written = (int64_t)(cap - c->zs.avail_out);

	/* Nothing borrowed outlives the call: the stream holds next_in, next_out
	 * and the table pointer only while isal_deflate_stateless runs, and they
	 * are cleared rather than left pointing at Goose memory that may be gone
	 * by the next call. */
	c->zs.next_in = NULL;
	c->zs.next_out = NULL;
	c->zs.hufftables = NULL;

	if (rc != COMP_OK) return rc;
	bld_claim(out, written);
	return COMP_OK;
}

int32_t igzip_gs_compress(Compressor_g *s, igzip_slice_u8 src, gs_rref out, int32_t level,
			 int32_t wrap) {
	return run(s, src, out, level, wrap, NULL);
}

/* A supplied table takes effect at level 0 only, so that is the level used. */
int32_t igzip_gs_compress_trained(Compressor_g *s, const HuffTables_g *t, igzip_slice_u8 src,
				 gs_rref out, int32_t wrap) {
	if (!t) return ISAL_INVALID_STATE;
	return run(s, src, out, 0, wrap, t);
}

/* ---- streaming writer ---------------------------------------------------- */

static uint16_t writer_flag(uint8_t wrap) {
	if (wrap == GS_WRAP_GZIP) return IGZIP_GZIP;
	if (wrap == GS_WRAP_ZLIB) return IGZIP_ZLIB;
	return IGZIP_DEFLATE;
}

static struct isal_zstream *writer_stream(GooseWriter *w) {
	return (struct isal_zstream *)(void *)w->stream;
}

static struct isal_hufftables *writer_tables(GooseWriter *w) {
	return (struct isal_hufftables *)(void *)w->tables;
}

/* Levels 1-3 need the level buffer; level 0 must not have one, matching the
 * stateless path in 0.1.0. */
static void writer_set_level(GooseWriter *w, struct isal_zstream *s, int32_t level) {
	s->level = (uint32_t)level;
	if (level > 0) {
		s->level_buf = (uint8_t *)(void *)w->level_buf;
		s->level_buf_size = (uint32_t)sizeof w->level_buf;
	} else {
		s->level_buf = NULL;
		s->level_buf_size = 0;
	}
}

/* Initializes the C stream on first use, or verifies that this exact Writer is
 * the one the C stream points into. A fixed-size Goose value can be copied by
 * assignment; after that, level_buf and a custom table would point into the
 * original. Callers reach that through a mismatch and get BadState. */
static int32_t writer_pin_at(GooseWriter *w, int32_t level) {
	if (!w) return ISAL_INVALID_STATE;
	if (w->wrap > GS_WRAP_ZLIB) return INVALID_FLUSH;
	if (w->state > GS_FINISHED) return ISAL_INVALID_STATE;
	/* A header flag without a HeaderWritten state has no header behind it. */
	if (w->state == GS_FRESH && w->hdr_written) return ISAL_INVALID_STATE;

	if (w->state == GS_FRESH) {
		if (w->pinned_self == (uint64_t)(uintptr_t)w) return COMP_OK;
		/* A Fresh Writer that has already been used for set_dict or
		 * set_tables must not be re-initialized: the dictionary lives in the
		 * stream buffer, not in a field the shim could replay. A deserialized
		 * Writer carrying either flag has no such buffer to replay, so it is
		 * refused rather than emitting a header that lies about its state. */
		if (w->pinned_self != 0) return ISAL_INVALID_STATE;
		if (w->has_dict || w->hdr_written) return ISAL_INVALID_STATE;
		struct isal_zstream *s = writer_stream(w);
		isal_deflate_init(s);
		s->hist_bits = 0;
		writer_set_level(w, s, level);
		s->gzip_flag = writer_flag(w->wrap);
		if (w->has_tables) s->hufftables = writer_tables(w);
		w->pinned_self = (uint64_t)(uintptr_t)w;
		return COMP_OK;
	}

	if (w->pinned_self != (uint64_t)(uintptr_t)w) return ISAL_INVALID_STATE;
	return COMP_OK;
}

static int32_t writer_pin(GooseWriter *w) {
	if (!w) return ISAL_INVALID_STATE;
	int32_t level = w->has_tables ? 0 : w->base_level;
	if (level < 0 || level > 3) return ISAL_INVALID_LEVEL;
	return writer_pin_at(w, level);
}

/* The zlib header that carries a preset dictionary. ISA-L's IGZIP_ZLIB path
 * writes FDICT=0, so a stream with a dictionary needs this six-byte header
 * first and gzip_flag=IGZIP_ZLIB_NO_HDR afterwards. */
static int32_t writer_auto_zlib(GooseWriter *w, struct isal_zstream *s, igzip_slice_u8 *dst,
				uint32_t *written) {
	if (dst->len < 6) return IGZIP_GS_BAD_HEADER;
	struct isal_zlib_header z;
	isal_zlib_header_init(&z);
	z.info = 7; /* 32 KiB window */
	z.level = w->base_level == 0 ? 0 : 1;
	z.dict_flag = 1;
	z.dict_id = w->dict_id;

	uint32_t before = s->total_out;
	s->next_out = (uint8_t *)(uintptr_t)dst->data;
	s->avail_out = (uint32_t)dst->len;
	uint32_t need = isal_write_zlib_header(s, &z);
	s->next_out = NULL;
	s->avail_out = 0;
	if (need != 0) return IGZIP_GS_BAD_HEADER;
	s->gzip_flag = IGZIP_ZLIB_NO_HDR;
	s->hist_bits = 15;

	uint32_t n = s->total_out - before;
	*written = n;
	dst->data += n;
	dst->len -= n;
	w->total_out += n;
	w->hdr_written = true;
	w->state = GS_HDR;
	return COMP_OK;
}

/* A Goose slice is not NUL-terminated. The public wrapper appends the 0 and
 * passes a length that includes it; this checks the contract instead of
 * trusting it. */
static int32_t writer_cstr_ok(igzip_slice_u8 s) {
	if (s.len < 0 || (uint64_t)s.len > UINT32_MAX) return IGZIP_GS_BAD_HEADER;
	if (s.len == 0) return COMP_OK;
	if (!s.data) return IGZIP_GS_BAD_HEADER;
	if (s.data[s.len - 1] != 0) return IGZIP_GS_BAD_HEADER;
	for (int64_t i = 0; i + 1 < s.len; i++) {
		if (s.data[i] == 0) return IGZIP_GS_BAD_HEADER;
	}
	return COMP_OK;
}

int64_t igzip_gs_writer_size(void) { return (int64_t)sizeof(GooseWriter); }

int32_t igzip_gs_writer_reset(GooseWriter *w) {
	if (!w) return ISAL_INVALID_STATE;
	struct isal_zstream *s = writer_stream(w);
	isal_deflate_reset(s);
	s->end_of_stream = 0;
	s->flush = NO_FLUSH;
	s->hist_bits = 0;
	s->gzip_flag = writer_flag(w->wrap);
	s->level = w->has_tables ? 0 : (uint32_t)w->base_level;
	if (s->level > 0) {
		s->level_buf = (uint8_t *)(void *)w->level_buf;
		s->level_buf_size = (uint32_t)sizeof w->level_buf;
	} else {
		s->level_buf = NULL;
		s->level_buf_size = 0;
	}
	if (w->has_tables) {
		s->hufftables = writer_tables(w);
	} else {
		isal_deflate_set_hufftables(s, NULL, IGZIP_HUFFTABLE_DEFAULT);
	}
	s->next_in = NULL;
	s->next_out = NULL;
	s->avail_in = 0;
	s->avail_out = 0;
	w->pinned_self = 0;
	w->state = GS_FRESH;
	w->has_dict = false;
	w->dict_id = 0;
	w->hdr_written = false;
	w->total_in = 0;
	w->total_out = 0;
	return COMP_OK;
}

int32_t igzip_gs_writer_gzip_header(GooseWriter *w, bool text, uint32_t mtime, uint8_t xflags,
				    uint8_t os, bool hcrc, igzip_slice_u8 name,
				    igzip_slice_u8 comment, igzip_slice_u8 extra,
				    igzip_slice_u8 dst, uint32_t *out_written,
				    uint32_t *out_needed) {
	if (!w || !out_written || !out_needed) return ISAL_INVALID_STATE;
	if (dst.len < 0 || (uint64_t)dst.len > UINT32_MAX) return STATELESS_OVERFLOW;

	int32_t rc = writer_pin(w);
	if (rc != COMP_OK) return rc;
	if (w->state != GS_FRESH || w->wrap != GS_WRAP_GZIP) return ISAL_INVALID_STATE;
	if (writer_cstr_ok(name) != COMP_OK || writer_cstr_ok(comment) != COMP_OK)
		return IGZIP_GS_BAD_HEADER;
	if (extra.len < 0 || (uint64_t)extra.len > UINT16_MAX) return IGZIP_GS_BAD_HEADER;

	struct isal_gzip_header h;
	isal_gzip_header_init(&h);
	h.text = text ? 1 : 0;
	h.time = mtime;
	h.xflags = xflags;
	h.os = os;
	h.hcrc = hcrc ? 1 : 0;
	if (extra.len > 0) {
		h.extra = (uint8_t *)(uintptr_t)extra.data;
		h.extra_buf_len = (uint32_t)extra.len;
		h.extra_len = (uint32_t)extra.len;
	}
	if (name.len > 0) {
		h.name = (char *)(uintptr_t)name.data;
		h.name_buf_len = (uint32_t)name.len;
	}
	if (comment.len > 0) {
		h.comment = (char *)(uintptr_t)comment.data;
		h.comment_buf_len = (uint32_t)comment.len;
	}

	struct isal_zstream *s = writer_stream(w);
	uint32_t before = s->total_out;
	s->next_out = (uint8_t *)(uintptr_t)dst.data;
	s->avail_out = (uint32_t)dst.len;
	uint32_t need = isal_write_gzip_header(s, &h);
	s->next_out = NULL;
	s->avail_out = 0;
	if (need == UINT32_MAX) return IGZIP_GS_BAD_HEADER;
	if (need != 0) {
		*out_written = 0;
		*out_needed = need;
		return COMP_OK;
	}

	uint32_t written = s->total_out - before;
	s->gzip_flag = IGZIP_GZIP_NO_HDR;
	w->total_out += written;
	w->state = GS_HDR;
	w->hdr_written = true;
	*out_written = written;
	*out_needed = 0;
	return COMP_OK;
}

int32_t igzip_gs_writer_zlib_header(GooseWriter *w, uint8_t window_bits, uint8_t flevel,
				    bool dict_flag, uint32_t dict_id, igzip_slice_u8 dst,
				    uint32_t *out_written) {
	if (!w || !out_written) return ISAL_INVALID_STATE;
	if (dst.len < 6 || (uint64_t)dst.len > UINT32_MAX) return IGZIP_GS_BAD_HEADER;

	int32_t rc = writer_pin(w);
	if (rc != COMP_OK) return rc;
	if (w->state != GS_FRESH || w->wrap != GS_WRAP_ZLIB) return ISAL_INVALID_STATE;
	if (window_bits < 8 || window_bits > 15 || flevel > 3) return IGZIP_GS_BAD_HEADER;

	bool use_dict = dict_flag;
	uint32_t use_id = dict_id;
	if (w->has_dict) {
		if (use_dict && use_id != w->dict_id) return IGZIP_GS_BAD_HEADER;
		use_dict = true;
		use_id = w->dict_id;
	} else if (use_dict) {
		return IGZIP_GS_BAD_HEADER;
	}

	struct isal_zlib_header z;
	isal_zlib_header_init(&z);
	z.info = (uint32_t)(window_bits - 8);
	z.level = flevel;
	z.dict_flag = use_dict ? 1 : 0;
	z.dict_id = use_id;

	struct isal_zstream *s = writer_stream(w);
	uint32_t before = s->total_out;
	s->next_out = (uint8_t *)(uintptr_t)dst.data;
	s->avail_out = (uint32_t)dst.len;
	uint32_t need = isal_write_zlib_header(s, &z);
	s->next_out = NULL;
	s->avail_out = 0;
	if (need != 0) return IGZIP_GS_BAD_HEADER;

	uint32_t written = s->total_out - before;
	s->gzip_flag = IGZIP_ZLIB_NO_HDR;
	s->hist_bits = window_bits;
	w->total_out += written;
	w->state = GS_HDR;
	w->hdr_written = true;
	*out_written = written;
	return COMP_OK;
}

int32_t igzip_gs_writer_set_dict(GooseWriter *w, igzip_slice_u8 dict) {
	int32_t rc = writer_pin(w);
	if (rc != COMP_OK) return rc;
	if (w->state != GS_FRESH) return ISAL_INVALID_STATE;
	if (w->wrap == GS_WRAP_GZIP) return ISAL_INVALID_STATE;
	if (dict.len < 0 || dict.len > 0x7FFFFFF0) return STATELESS_OVERFLOW;
	if (dict.len == 0) return COMP_OK;

	struct isal_zstream *s = writer_stream(w);
	rc = isal_deflate_set_dict(s, (uint8_t *)(uintptr_t)dict.data, (uint32_t)dict.len);
	if (rc != COMP_OK) return rc;

	w->has_dict = true;
	w->dict_id = w->wrap == GS_WRAP_ZLIB
			     ? isal_adler32(1, (const unsigned char *)(uintptr_t)dict.data,
					    (uint64_t)dict.len)
			     : 0;
	return COMP_OK;
}

int32_t igzip_gs_writer_set_tables(GooseWriter *w, const HuffTables_g *t) {
	if (!t) return ISAL_INVALID_STATE;
	/* The table forces level 0, so an out-of-range base level is irrelevant
	 * here; this matches Compressor.set_tables. */
	int32_t rc = writer_pin_at(w, 0);
	if (rc != COMP_OK) return rc;
	if (w->state != GS_FRESH && w->state != GS_HDR && w->state != GS_FLUSHED)
		return ISAL_INVALID_STATE;

	rc = igzip_gs_tables_check(t);
	if (rc != COMP_OK) return rc;

	struct isal_zstream *s = writer_stream(w);
	bool old = w->has_tables;
	memcpy(w->tables, t->raw_g, sizeof w->tables);
	s->hufftables = writer_tables(w);
	writer_set_level(w, s, 0);
	rc = isal_deflate_set_hufftables(s, writer_tables(w), IGZIP_HUFFTABLE_CUSTOM);
	if (rc != COMP_OK) {
		w->has_tables = old;
		if (old) {
			s->hufftables = writer_tables(w);
			writer_set_level(w, s, 0);
		} else {
			isal_deflate_set_hufftables(s, NULL, IGZIP_HUFFTABLE_DEFAULT);
			writer_set_level(w, s, w->base_level);
		}
		return rc;
	}
	w->has_tables = true;
	return COMP_OK;
}

int32_t igzip_gs_writer_clear_tables(GooseWriter *w) {
	int32_t rc = writer_pin(w);
	if (rc != COMP_OK) return rc;
	if (w->state != GS_FRESH && w->state != GS_HDR && w->state != GS_FLUSHED)
		return ISAL_INVALID_STATE;

	struct isal_zstream *s = writer_stream(w);
	writer_set_level(w, s, w->base_level);
	rc = isal_deflate_set_hufftables(s, NULL, IGZIP_HUFFTABLE_DEFAULT);
	if (rc != COMP_OK) return rc;
	w->has_tables = false;
	return COMP_OK;
}

/* One step of deflate into dst. mode: 0=write, 1=sync flush, 2=full flush,
 * 3=finish. src.len is at most MAX_INPUT; the Goose wrapper splits larger
 * writes into windows. */
int32_t igzip_gs_writer_step(GooseWriter *w, igzip_slice_u8 src, uint8_t mode,
			     igzip_slice_u8 dst, uint32_t *out_consumed, uint32_t *out_written,
			     bool *out_more) {
	if (!w || !out_consumed || !out_written || !out_more) return ISAL_INVALID_STATE;
	if (mode > 3) return INVALID_FLUSH;
	if (src.len < 0 || src.len > 0x7FFFFFF0) return STATELESS_OVERFLOW;
	if (dst.len < 0 || (uint64_t)dst.len > UINT32_MAX) return STATELESS_OVERFLOW;

	int32_t rc = writer_pin(w);
	if (rc != COMP_OK) return rc;
	if (w->state == GS_FINISHED) return ISAL_INVALID_STATE;
	if (w->has_tables) {
		const HuffTables_g *ht = (const HuffTables_g *)(const void *)w->tables;
		if (igzip_gs_tables_check(ht) != COMP_OK) return IGZIP_GS_BAD_TABLE;
	}

	struct isal_zstream *s = writer_stream(w);
	uint32_t header_written = 0;
	igzip_slice_u8 body = dst;

	if (w->state == GS_FRESH && w->wrap == GS_WRAP_ZLIB && w->has_dict && !w->hdr_written) {
		if (body.len < 6) {
			*out_consumed = 0;
			*out_written = 0;
			*out_more = true;
			return COMP_OK;
		}
		rc = writer_auto_zlib(w, s, &body, &header_written);
		if (rc != COMP_OK) return rc;
	}

	uint32_t body_cap = (uint32_t)body.len;
	s->next_in = src.len > 0 ? (uint8_t *)(uintptr_t)src.data : NULL;
	s->avail_in = (uint32_t)src.len;
	s->next_out = body.len > 0 ? (uint8_t *)(uintptr_t)body.data : NULL;
	s->avail_out = body_cap;

	switch (mode) {
	case 0:
		s->flush = NO_FLUSH;
		s->end_of_stream = 0;
		break;
	case 1:
		s->flush = SYNC_FLUSH;
		s->end_of_stream = 0;
		break;
	case 2:
		s->flush = FULL_FLUSH;
		s->end_of_stream = 0;
		break;
	default:
		s->flush = NO_FLUSH;
		s->end_of_stream = 1;
		break;
	}

	rc = (int32_t)isal_deflate(s);
	uint32_t consumed = (uint32_t)src.len - s->avail_in;
	uint32_t body_written = body_cap - s->avail_out;
	uint32_t written = header_written + body_written;

	bool more = s->avail_in > 0 || s->avail_out == 0 ||
		    s->internal_state.tmp_out_start != s->internal_state.tmp_out_end;
	if (mode == 1 || mode == 2)
		more = more || s->internal_state.state != ZSTATE_NEW_HDR;
	else if (mode == 3)
		more = more || s->internal_state.state != ZSTATE_END;

	/* Borrowed input and output die with the call. */
	s->next_in = NULL;
	s->next_out = NULL;
	w->total_in += consumed;
	w->total_out += written;

	if (rc == COMP_OK) {
		if (mode == 3) {
			if (!more) w->state = GS_FINISHED;
			else if (w->state == GS_FRESH || w->state == GS_HDR) w->state = GS_OPEN;
		} else if (mode == 1 || mode == 2) {
			/* The flush request is submitted once. Later calls only drain
			 * the pending output; leaving it set would emit a second,
			 * redundant empty stored block if the buffer filled exactly. */
			s->flush = NO_FLUSH;
			if (!more) w->state = GS_FLUSHED;
			else if (w->state == GS_FRESH || w->state == GS_HDR) w->state = GS_OPEN;
		} else {
			w->state = GS_OPEN;
		}
	}

	*out_consumed = consumed;
	*out_written = written;
	*out_more = more;
	return rc;
}

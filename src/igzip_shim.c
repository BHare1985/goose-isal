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

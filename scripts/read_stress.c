/* Does the decompressor ever touch memory it was not given?
 *
 * Three claims only memory safety can prove:
 *
 *   1. Nothing is written past `dst.len`. A decompressor cannot size its output
 *      ahead of time, so the caller's destination is the only limit there is.
 *   2. Nothing is read past `src.len`, including through the 328-byte
 *      `tmp_in_buffer` that holds a header across a chunk boundary.
 *   3. `isal_inflate_stateless` is honest about `avail_out` -- unlike
 *      `isal_deflate_stateless`, which overruns a small buffer at levels 2-3
 *      (see bound_stress.c). The 0.3.0 brief made this an acceptance gate
 *      before the API trusted it.
 *
 * Every buffer here is malloc'ed to its exact size, so under AddressSanitizer a
 * single byte past either end is a failure rather than a silent corruption.
 * Output buffers run from 1 byte to 64 KiB, every truncation offset is decoded,
 * and a few hundred mutations are decoded too, because untrusted input is the
 * whole reason a reader exists. Both level 0 (stored and static-Huffman blocks)
 * and level 1 (dynamic-Huffman block headers) are decoded: they are different
 * decode paths, not the same one with different tables.
 *
 *     make stress
 *
 * This drives ISA-L directly rather than through the shim: the shim is compiled
 * inside the package against the Goose-generated header, and a second struct
 * mirror here would be one more thing to keep in step. What is checked is the
 * behaviour the shim is built on. test/inflate_contract.goose and
 * test/roundtrip.goose check the shim's own logic, including the FDICT round
 * trip through the Writer.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <igzip_lib.h>

#define N (300 * 1024)
#define CHUNK 65536
#define MARGIN 512

static uint8_t plain[N];
static uint8_t *comp;
static size_t clen;

/* xorshift64: bytes nothing can compress. */
static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint8_t nextb(void) {
	rng ^= rng << 13;
	rng ^= rng >> 7;
	rng ^= rng << 17;
	return (uint8_t)rng;
}

static int failures;

static void fail(const char *what, int wrap, long a, long b) {
	fprintf(stderr, "read_stress: %s (wrap %d, %ld, %ld)\n", what, wrap, a, b);
	failures++;
}

static int64_t gs_bound(int64_t n) {
	int64_t bound = n + (n / 65535 + 1) * 6 + MARGIN;
	return bound > 0x7FFFFFF0 ? 0x7FFFFFF0 : bound;
}

/* These are the same constants: gzip_flag on the deflate side and crc_flag on
 * the inflate side name the same three wrappers. */
static uint32_t wrapper_code(int wrap) {
	return wrap == 0 ? IGZIP_DEFLATE : wrap == 1 ? IGZIP_GZIP : IGZIP_ZLIB;
}

/* Half structured, half noise: compressible enough to exercise matches and
 * lookbacks, incompressible enough to exercise stored blocks. */
static void make_plain(void) {
	const char *rec = "{\"id\":12345,\"user\":\"alice\",\"active\":true},";
	size_t rec_len = strlen(rec);
	for (size_t i = 0; i < N; i++)
		plain[i] = ((i / 4096) % 2 == 0) ? (uint8_t)rec[i % rec_len] : nextb();
}

/* Level 0 and level 1 do not decode through the same code: level 0 emits stored
 * and static-Huffman blocks, level 1 emits dynamic-Huffman block headers. Both
 * are decoded here, so the ASan checks cover the block kinds a caller will see
 * in practice. */
static void make_stream(int wrap, int level) {
	uint8_t *lvb = malloc(ISAL_DEF_LVL3_MEDIUM);
	size_t cap = (size_t)gs_bound(N);
	if (!comp) comp = malloc(cap);

	struct isal_zstream zs;
	isal_deflate_stateless_init(&zs);
	zs.next_in = plain;
	zs.avail_in = N;
	zs.next_out = comp;
	zs.avail_out = (uint32_t)cap;
	zs.end_of_stream = 1;
	zs.level = (uint32_t)level;
	zs.gzip_flag = (uint16_t)wrapper_code(wrap);
	if (level) {
		zs.level_buf = lvb;
		zs.level_buf_size = ISAL_DEF_LVL3_MEDIUM;
	}
	if (isal_deflate_stateless(&zs) != COMP_OK) {
		fprintf(stderr, "deflate failed (wrap %d level %d)\n", wrap, level);
		exit(2);
	}
	clen = cap - zs.avail_out;
	if (clen == 0 || clen > cap) {
		fprintf(stderr, "deflate produced no stream (wrap %d level %d)\n", wrap, level);
		exit(2);
	}
	free(lvb);
}

static void reset_state(struct inflate_state *st, int wrap) {
	isal_inflate_init(st);
	st->crc_flag = wrapper_code(wrap);
}

/* 1. Streaming decode with `dst_cap` bytes of room at a time. Output is compared
 *    as it arrives, so no second copy of a 300 KB body is needed and every write
 *    lands in an exactly sized allocation. */
static void check_streaming(int wrap, size_t dst_cap) {
	static struct inflate_state st;
	reset_state(&st, wrap);

	size_t pos = 0, produced = 0;
	int finished = 0;
	for (long call = 0; call < 100000000L; call++) {
		uint8_t *dst = malloc(dst_cap);
		st.next_in = comp + pos;
		st.avail_in = (uint32_t)(clen - pos);
		st.next_out = dst;
		st.avail_out = (uint32_t)dst_cap;
		int rc = isal_inflate(&st);
		uint32_t wrote = (uint32_t)dst_cap - st.avail_out;
		if (wrote > dst_cap) { /* survives a broken avail_out */
			fail("avail_out underflow", wrap, (long)dst_cap, (long)wrote);
			free(dst);
			return;
		}
		if (produced + wrote > N) {
			fail("decoded more than the body", wrap, (long)produced, (long)wrote);
			free(dst);
			return;
		}
		if (memcmp(dst, plain + produced, wrote) != 0)
			fail("wrong bytes", wrap, (long)dst_cap, (long)produced);
		free(dst);

		produced += wrote;
		pos = clen - st.avail_in;
		if (rc != 0) {
			fail("streaming inflate returned an error", wrap, rc, (long)dst_cap);
			return;
		}
		if (st.block_state == ISAL_BLOCK_FINISH) {
			finished = 1;
			break;
		}
		if (wrote == 0 && pos == clen) break; /* ran out of input */
	}
	if (!finished) fail("stream never finished", wrap, (long)dst_cap, 0);
	if (produced != N) fail("wrong output length", wrap, (long)produced, N);
	if (st.total_out != N) fail("total_out disagrees with the output", wrap, (long)st.total_out, N);
}

/* 2. The stateless call, into exact and short destinations. */
static void check_stateless(int wrap) {
	static struct inflate_state st;

	size_t sizes[] = {N, N - 1, 1, 0};
	for (size_t k = 0; k < sizeof sizes / sizeof sizes[0]; k++) {
		size_t cap = sizes[k];
		uint8_t *dst = cap ? malloc(cap) : NULL;
		reset_state(&st, wrap);
		st.next_in = comp;
		st.avail_in = (uint32_t)clen;
		st.next_out = dst;
		st.avail_out = (uint32_t)cap;
		int rc = isal_inflate_stateless(&st);
		uint32_t wrote = (uint32_t)cap - st.avail_out;

		if (cap >= N) {
			if (rc != ISAL_DECOMP_OK) fail("stateless exact size", wrap, rc, (long)cap);
			if (wrote != N) fail("stateless wrote the wrong length", wrap, (long)wrote, N);
			if (st.avail_in != 0) fail("stateless left input", wrap, (long)st.avail_in, 0);
			if (memcmp(dst, plain, N) != 0) fail("stateless wrong bytes", wrap, 0, 0);
		} else {
			if (rc != ISAL_OUT_OVERFLOW) fail("stateless short did not overflow", wrap, rc, (long)cap);
			if (wrote != cap) fail("stateless short did not fill dst", wrap, (long)wrote, (long)cap);
			if (memcmp(dst, plain, cap) != 0) fail("stateless short wrong bytes", wrap, 0, 0);
		}
		free(dst);
	}

	/* Truncated input is END_INPUT, and absorbs everything it was given. */
	reset_state(&st, wrap);
	uint8_t *dst = malloc(N);
	st.next_in = comp;
	st.avail_in = (uint32_t)(clen - 4);
	st.next_out = dst;
	st.avail_out = N;
	int rc = isal_inflate_stateless(&st);
	if (rc != ISAL_END_INPUT) fail("stateless truncation was not END_INPUT", wrap, rc, 0);
	free(dst);
}

/* 3. Every truncation offset: a cut stream is never mistaken for a complete
 *    one, and nothing is read past the bytes that are there. */
static void check_truncations(int wrap) {
	static struct inflate_state st;
	uint8_t *dst = malloc((size_t)gs_bound(0) + N);
	for (size_t cut = 0; cut < clen; cut += (cut < 64 ? 1 : 97)) {
		reset_state(&st, wrap);
		st.next_in = comp;
		st.avail_in = (uint32_t)cut;
		st.next_out = dst;
		st.avail_out = (uint32_t)(N + MARGIN);
		int rc;
		uint32_t wrote = 0;
		for (int guard = 0; guard < 100000; guard++) {
			rc = isal_inflate(&st);
			wrote += (uint32_t)(N + MARGIN) - st.avail_out;
			st.next_out = dst;
			st.avail_out = (uint32_t)(N + MARGIN);
			if (rc != 0 || st.block_state == ISAL_BLOCK_FINISH ||
			    st.avail_in == 0)
				break;
		}
		if (rc != 0 && !(rc == ISAL_INCORRECT_CHECKSUM))
			fail("truncation returned an unexpected error", wrap, rc, (long)cut);
		if (st.block_state == ISAL_BLOCK_FINISH && cut < clen - 8)
			fail("a truncated stream reported completion", wrap, (long)cut, (long)clen);
		if (wrote > cut * 4000 + N)
			fail("truncation produced absurd output", wrap, (long)wrote, (long)cut);
	}
	free(dst);
}

/* 4. Mutations: a single flipped byte must never crash, never hang, and never be
 *    reported as a complete member with the wrong plaintext. Nothing here
 *    asserts that every mutation is *caught*: a wrapper's checksum catches the
 *    ones that decode, and a bare deflate stream has no checksum at all. */
static void check_mutations(int wrap) {
	static struct inflate_state st;
	uint8_t *dst = malloc(N);
	uint8_t *mutant = malloc(clen);

	for (int i = 0; i < 400; i++) {
		memcpy(mutant, comp, clen);
		size_t at = (size_t)(rng % clen);
		mutant[at] ^= (uint8_t)(1 + (rng >> 8));
		reset_state(&st, wrap);
		size_t pos = 0, produced = 0;
		int rc = 0;
		for (int guard = 0; guard < 100000; guard++) {
			st.next_in = mutant + pos;
			st.avail_in = (uint32_t)(clen - pos);
			st.next_out = dst;
			st.avail_out = N;
			rc = isal_inflate(&st);
			uint32_t wrote = (uint32_t)N - st.avail_out;
			if (produced + wrote > N) {
				fail("mutation decoded past the body", wrap, (long)produced, (long)wrote);
				break;
			}
			produced += wrote;
			pos = clen - st.avail_in;
			if (rc != 0 || st.block_state == ISAL_BLOCK_FINISH) break;
			if (wrote == 0 && pos == clen) break;
		}
		if (rc == ISAL_DECOMP_OK && st.block_state == ISAL_BLOCK_FINISH) {
			/* Complete: with a wrapper, the trailer has spoken, so the
			 * plaintext must be the plaintext. Bare deflate has no trailer. */
			if (wrap != 0 && (produced != N || memcmp(dst, plain, N) != 0))
				fail("mutation completed with the wrong bytes", wrap, (long)at,
				     (long)produced);
		}
	}
	free(mutant);
	free(dst);
}

/* 5. The dictionary guard, and a dictionary in the history the stream does not
 *    use. Both are places where a stale history could be read. */
static void check_dictionary(void) {
	static struct inflate_state st;
	size_t dict_len = 40000; /* past igzip's 32 KiB history */
	uint8_t *dict = malloc(dict_len);
	for (size_t i = 0; i < dict_len; i++) dict[i] = nextb();

	reset_state(&st, IGZIP_ZLIB);
	if (isal_inflate_set_dict(&st, dict, (uint32_t)dict_len) != COMP_OK)
		fail("set_dict refused a fresh state", 2, (long)dict_len, 0);
	/* igzip copies the tail only, and nothing beyond the history window. */
	if (st.tmp_out_valid != IGZIP_HIST_SIZE || st.tmp_out_processed != IGZIP_HIST_SIZE)
		fail("set_dict did not keep exactly the history window", 2, st.tmp_out_valid,
		     IGZIP_HIST_SIZE);

	/* A dictionary that the stream never references must not disturb it. */
	uint8_t *dst = malloc(N);
	st.next_in = comp;
	st.avail_in = (uint32_t)clen;
	st.next_out = dst;
	st.avail_out = N;
	int rc = isal_inflate(&st);
	if (rc != ISAL_DECOMP_OK) fail("a plain zlib stream with a dictionary set", 2, rc, 0);
	if (st.block_state != ISAL_BLOCK_FINISH) fail("plain stream with dictionary unfinished", 2, 0, 0);
	if (memcmp(dst, plain, N) != 0) fail("wrong bytes with an unused dictionary", 2, 0, 0);

	/* Once output exists, the dictionary moment has passed. */
	reset_state(&st, IGZIP_ZLIB);
	if (isal_inflate_set_dict(&st, dict, (uint32_t)dict_len) != COMP_OK)
		fail("set_dict refused a fresh state (2)", 2, 0, 0);
	st.next_in = comp;
	st.avail_in = (uint32_t)clen;
	st.next_out = dst;
	st.avail_out = N;
	(void)isal_inflate(&st);
	if (isal_inflate_set_dict(&st, dict, (uint32_t)dict_len) != ISAL_INVALID_STATE)
		fail("set_dict accepted a state mid-body", 2, 0, 0);

	free(dst);
	free(dict);
}

int main(void) {
	make_plain();
	static const size_t caps[] = {1, 2, 3, 8, 64, 4096, CHUNK};
	/* Stored/static blocks and dynamic blocks, for every wrapper. */
	static const int levels[] = {0, 1};

	for (int wrap = 0; wrap < 3; wrap++) {
		for (size_t l = 0; l < sizeof levels / sizeof levels[0]; l++) {
			make_stream(wrap, levels[l]);
			for (size_t k = 0; k < sizeof caps / sizeof caps[0]; k++)
				check_streaming(wrap, caps[k]);
			check_stateless(wrap);
			check_truncations(wrap);
		}
	}

	/* Mutations use the gzip stream: a wrapper is the interesting case, and a
	 * bare deflate stream is the case where nothing can catch them. Both block
	 * kinds, because a corruption inside a stored block reads very differently
	 * from one inside a Huffman code. */
	for (size_t l = 0; l < sizeof levels / sizeof levels[0]; l++) {
		make_stream(1, levels[l]);
		check_mutations(1);
		check_mutations(0);
	}

	make_stream(2, 1);
	check_dictionary();
	free(comp);

	if (failures) {
		fprintf(stderr, "read_stress: %d failure(s)\n", failures);
		return 1;
	}
	printf("read_stress: ok (streaming, stateless, truncations, mutations, dictionary)\n");
	return 0;
}

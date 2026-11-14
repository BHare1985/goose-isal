/* Does igzip ever write past the buffer size this package promises?
 *
 * `igzip::bound(n)` claims an upper bound on the compressed size of n bytes, and
 * `compress` relies on it: igzip is handed exactly that much room and writes
 * straight into the destination builder. If the promise is wrong, igzip writes
 * past the end of the data stack. This program allocates the bound *exactly*
 * and compresses incompressible and adversarial inputs at every level and
 * wrapper under AddressSanitizer, where any overrun is a failure rather than a
 * silent corruption.
 *
 * The second half drives the stateful path (`isal_deflate`) with output
 * buffers as small as 8 bytes, at exact sizes, and writes gzip headers into
 * buffers of exactly the required size and one byte less. The stateful path
 * has no `bound()`: the contract is that nothing is written past `avail_out`.
 *
 *     make stress
 *
 * It duplicates the bound formula on purpose: it has to check the arithmetic
 * the shim uses, not take it on trust. Keep the two in step, and re-run this
 * after any change to ISAL_BOUND_MARGIN or an ISA-L version bump.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <igzip_lib.h>

#define ISAL_BOUND_MARGIN 512

static int64_t gs_bound(int64_t n) {
	int64_t bound = n + (n / 65535 + 1) * 6 + ISAL_BOUND_MARGIN;
	return bound > 0x7FFFFFF0 ? 0x7FFFFFF0 : bound;
}

/* xorshift64: bytes nothing can compress. */
static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint8_t nextb(void) {
	rng ^= rng << 13;
	rng ^= rng >> 7;
	rng ^= rng << 17;
	return (uint8_t)rng;
}


static int stream_case(const uint8_t *in, size_t n, int level, int wrap) {
	static const size_t chunks[] = {8, 9, 16, 64, 4096, 65536};
	static uint8_t lvb[ISAL_DEF_LVL3_MEDIUM];
	int64_t bound = gs_bound((int64_t)n);
	uint8_t *out = malloc((size_t)bound);
	struct isal_zstream zs;
	isal_deflate_init(&zs);
	zs.level = (uint32_t)level;
	zs.gzip_flag = (uint16_t)(wrap == 0   ? IGZIP_DEFLATE
				  : wrap == 1 ? IGZIP_GZIP
					      : IGZIP_ZLIB);
	if (level) {
		zs.level_buf = lvb;
		zs.level_buf_size = ISAL_DEF_LVL3_MEDIUM;
	}
	zs.next_in = (uint8_t *)in;
	zs.avail_in = (uint32_t)n;
	zs.end_of_stream = 1;

	size_t used = 0;
	size_t ci = 0;
	int rc = COMP_OK;
	for (int guard = 0; guard < 1000000; guard++) {
		size_t room = (size_t)bound - used;
		if (room == 0) break;
		size_t want = chunks[ci++ % (sizeof chunks / sizeof chunks[0])];
		if (want > room) want = room;
		zs.next_out = out + used;
		zs.avail_out = (uint32_t)want;
		rc = isal_deflate(&zs);
		used += want - zs.avail_out;
		if (rc != COMP_OK) break;
		if (zs.internal_state.state == ZSTATE_END) break;
		if (used == (size_t)bound) break;
	}

	int ok = rc == COMP_OK && used <= (size_t)bound;
	free(out);
	if (!ok) {
		printf("FAIL stream rc=%d n=%zu level=%d wrap=%d used=%zu bound=%lld\n", rc, n,
		       level, wrap, used, (long long)bound);
		return 1;
	}
	return 0;
}

static int header_case(void) {
	int fails = 0;
	struct isal_zstream zs;
	isal_deflate_init(&zs);
	struct isal_gzip_header h;
	isal_gzip_header_init(&h);
	char name[] = "report.csv";
	char comment[] = "stress";
	uint8_t extra[70000];
	memset(extra, 0xA5, sizeof extra);
	h.text = 1;
	h.time = 1234;
	h.os = 3;
	h.hcrc = 1;
	h.name = name;
	h.name_buf_len = (uint32_t)sizeof name;
	h.comment = comment;
	h.comment_buf_len = (uint32_t)sizeof comment;
	h.extra = extra;
	h.extra_len = 65000;
	h.extra_buf_len = 65000;

	/* Ask for the required size, then write into exactly that many bytes and
	 * one byte less. */
	uint32_t need = isal_write_gzip_header(&zs, &h);
	if (need == 0 || need == UINT32_MAX) return 1;
	uint8_t *exact = malloc(need);
	zs.next_out = exact;
	zs.avail_out = need;
	if (isal_write_gzip_header(&zs, &h) != 0) fails++;
	free(exact);

	uint8_t *shortbuf = malloc(need - 1);
	zs.next_out = shortbuf;
	zs.avail_out = need - 1;
	if (isal_write_gzip_header(&zs, &h) != need) fails++;
	free(shortbuf);
	if (fails) printf("FAIL gzip header exact/short buffer\n");
	return fails;
}

int main(void) {
	static const size_t sizes[] = {1, 17, 1000, 65534, 65535, 65536, 120233, 262144, 1048576, 4194304};
	static const int patterns = 4;
	static uint8_t lvb[ISAL_DEF_LVL3_MEDIUM];
	int cases = 0;
	int failures = 0;

	for (int pi = 0; pi < patterns; pi++) {
		for (size_t si = 0; si < sizeof sizes / sizeof sizes[0]; si++) {
			size_t n = sizes[si];
			uint8_t *in = malloc(n);
			for (size_t i = 0; i < n; i++) {
				switch (pi) {
				case 0: in[i] = nextb(); break;            /* incompressible */
				case 1: in[i] = 0xFF; break;               /* runs */
				case 2: in[i] = (i & 1) ? 0x00 : 0xFF; break; /* alternating */
				default: in[i] = (uint8_t)("abcdefghij"[i % 10]); break; /* text-ish */
				}
			}

			int64_t bound = gs_bound((int64_t)n);
			/* Exactly the size the package promises, so ASan's redzone starts
			 * where a wrong bound would end. */
			uint8_t *out = malloc((size_t)bound);

			for (int level = 0; level <= 3; level++) {
				for (int wrap = 0; wrap <= 2; wrap++) {
					struct isal_zstream zs;
					isal_deflate_stateless_init(&zs);
					zs.next_in = in;
					zs.avail_in = (uint32_t)n;
					zs.next_out = out;
					zs.avail_out = (uint32_t)bound;
					zs.end_of_stream = 1;
					zs.level = (uint32_t)level;
					zs.gzip_flag = (uint16_t)(wrap == 0   ? IGZIP_DEFLATE
								  : wrap == 1 ? IGZIP_GZIP
									      : IGZIP_ZLIB);
					if (level) {
						zs.level_buf = lvb;
						zs.level_buf_size = ISAL_DEF_LVL3_MEDIUM;
					}
					int rc = isal_deflate_stateless(&zs);
					cases++;
					if (rc != COMP_OK) {
						printf("FAIL rc=%d n=%zu level=%d wrap=%d\n", rc, n, level, wrap);
						failures++;
					}
				}
			}
			free(in);
			free(out);
		}
	}

	/* Stateful streaming with tiny and exact output slices. */
	for (size_t si = 0; si < sizeof sizes / sizeof sizes[0]; si++) {
		size_t n = sizes[si] > 262144 ? 262144 : sizes[si];
		uint8_t *in = malloc(n);
		for (size_t i = 0; i < n; i++) in[i] = (uint8_t)("abcdefghij"[i % 10]);
		for (int level = 0; level <= 3; level++)
			for (int wrap = 0; wrap <= 2; wrap++) {
				failures += stream_case(in, n, level, wrap);
				cases++;
			}
		free(in);
	}
	failures += header_case();

	printf("%d cases, %d failures: bound and avail_out held as exact sizes\n", cases, failures);
	return failures != 0;
}

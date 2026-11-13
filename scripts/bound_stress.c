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

	printf("%d cases, %d failures: bound held as an exact buffer size\n", cases, failures);
	return failures != 0;
}

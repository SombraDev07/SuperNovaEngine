#include "zstd.h"
#include <stddef.h>
#include <stdint.h>

/* Thin C ABI for Zig (Dagor Oodle/Zstd second-stage role). */

size_t tzstd_compress_bound(size_t src_size) {
    return ZSTD_compressBound(src_size);
}

/* Returns compressed size, or 0 on failure. */
size_t tzstd_compress(void *dst, size_t dst_cap, const void *src, size_t src_size, int level) {
    const size_t r = ZSTD_compress(dst, dst_cap, src, src_size, level);
    if (ZSTD_isError(r)) return 0;
    return r;
}

/* Returns decompressed size, or 0 on failure. */
size_t tzstd_decompress(void *dst, size_t dst_cap, const void *src, size_t src_size) {
    const size_t r = ZSTD_decompress(dst, dst_cap, src, src_size);
    if (ZSTD_isError(r)) return 0;
    return r;
}

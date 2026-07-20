#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum ZBasisFormat {
    ZBASIS_FMT_BC7_RGBA_SRGB = 0,
    ZBASIS_FMT_BC7_RGBA = 1,
    ZBASIS_FMT_ASTC_4x4_RGBA_SRGB = 2,
    ZBASIS_FMT_ASTC_4x4_RGBA = 3,
    ZBASIS_FMT_RGBA8 = 4,
} ZBasisFormat;

typedef struct ZBasisImage {
    uint32_t width;
    uint32_t height;
    ZBasisFormat format;
    uint8_t *data;
    size_t data_size;
    uint32_t bytes_per_row;
} ZBasisImage;

/** Call once before any transcode (loads transcoder tables). */
void zbasis_init(void);

/** Transcode .basis or .ktx2 file bytes to GPU format. Caller frees with zbasis_image_free. */
int zbasis_transcode_memory(
    const void *file_data,
    size_t file_size,
    int prefer_astc, /* non-zero → ASTC 4x4, else BC7 */
    int srgb,
    ZBasisImage *out);

int zbasis_transcode_file(const char *path, int prefer_astc, int srgb, ZBasisImage *out);

void zbasis_image_free(ZBasisImage *img);

/** Cook path: encode RGBA8 → .basis or .ktx2 (UASTC). Caller frees with zbasis_encode_free. */
void zbasis_encoder_init(void);
int zbasis_encode_rgba8(
    const uint8_t *rgba,
    uint32_t width,
    uint32_t height,
    int srgb,
    int ktx2, /* non-zero → .ktx2, else .basis */
    uint8_t **out_data,
    size_t *out_size);
void zbasis_encode_free(uint8_t *data);

/** Zstd second-stage compress/decompress (Dagor streaming pack role). */
size_t tzstd_compress_bound(size_t src_size);
size_t tzstd_compress(void *dst, size_t dst_cap, const void *src, size_t src_size, int level);
size_t tzstd_decompress(void *dst, size_t dst_cap, const void *src, size_t src_size);

#ifdef __cplusplus
}
#endif

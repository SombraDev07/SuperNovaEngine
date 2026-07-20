#include "zbasis.h"

#include "basisu_comp.h"
#include "basisu_enc.h"

#include <cstring>

using namespace basisu;

extern "C" void zbasis_encoder_init(void) {
    basisu_encoder_init(false, false);
}

extern "C" int zbasis_encode_rgba8(
    const uint8_t *rgba,
    uint32_t width,
    uint32_t height,
    int srgb,
    int ktx2,
    uint8_t **out_data,
    size_t *out_size)
{
    if (!rgba || !out_data || !out_size || width == 0 || height == 0) return 0;
    zbasis_encoder_init();

    // UASTC → good BC7/ASTC runtime transcode quality.
    uint32_t flags = cFlagUASTC | cFlagThreaded | (uint32_t)cPackUASTCLevelDefault;
    if (srgb) flags |= cFlagSRGB;
    if (ktx2) flags |= cFlagKTX2;

    size_t sz = 0;
    void *data = basis_compress(rgba, width, height, width, flags, 1.0f, &sz, nullptr);
    if (!data || sz == 0) return 0;

    *out_data = (uint8_t *)data;
    *out_size = sz;
    return 1;
}

extern "C" void zbasis_encode_free(uint8_t *data) {
    basis_free_data(data);
}

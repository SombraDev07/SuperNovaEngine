#include "zbasis.h"

#include "basisu_transcoder.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <fstream>

using namespace basist;

static bool g_inited = false;

extern "C" void zbasis_init(void) {
    if (g_inited) return;
    basisu_transcoder_init();
    g_inited = true;
}

static uint32_t bytes_per_block(ZBasisFormat fmt) {
    switch (fmt) {
        case ZBASIS_FMT_BC7_RGBA_SRGB:
        case ZBASIS_FMT_BC7_RGBA:
        case ZBASIS_FMT_ASTC_4x4_RGBA_SRGB:
        case ZBASIS_FMT_ASTC_4x4_RGBA:
            return 16;
        case ZBASIS_FMT_RGBA8:
            return 4;
    }
    return 16;
}

static transcoder_texture_format to_basis_fmt(ZBasisFormat fmt) {
    switch (fmt) {
        case ZBASIS_FMT_BC7_RGBA_SRGB:
        case ZBASIS_FMT_BC7_RGBA:
            return transcoder_texture_format::cTFBC7_RGBA;
        case ZBASIS_FMT_ASTC_4x4_RGBA_SRGB:
        case ZBASIS_FMT_ASTC_4x4_RGBA:
            return transcoder_texture_format::cTFASTC_4x4_RGBA;
        case ZBASIS_FMT_RGBA8:
            return transcoder_texture_format::cTFRGBA32;
    }
    return transcoder_texture_format::cTFBC7_RGBA;
}

static int transcode_basis(
    const void *data,
    uint32_t size,
    ZBasisFormat out_fmt,
    ZBasisImage *out)
{
    basisu_transcoder dec;
    if (!dec.validate_header(data, size)) return 0;
    if (!dec.start_transcoding(data, size)) return 0;

    uint32_t orig_w = 0, orig_h = 0, total_blocks = 0;
    if (!dec.get_image_level_desc(data, size, 0, 0, orig_w, orig_h, total_blocks)) return 0;

    const transcoder_texture_format bf = to_basis_fmt(out_fmt);
    const bool is_uncomp = (out_fmt == ZBASIS_FMT_RGBA8);
    const uint32_t bpb = bytes_per_block(out_fmt);
    const uint32_t blocks_x = (orig_w + 3) / 4;
    const uint32_t blocks_y = (orig_h + 3) / 4;
    const uint32_t out_size = is_uncomp ? (orig_w * orig_h * 4) : (blocks_x * blocks_y * bpb);
    const uint32_t out_blocks_or_pixels = is_uncomp ? (orig_w * orig_h) : total_blocks;

    uint8_t *dst = (uint8_t *)malloc(out_size);
    if (!dst) return 0;

    if (!dec.transcode_image_level(
            data, size, 0, 0, dst, out_blocks_or_pixels, bf, 0,
            is_uncomp ? orig_w : 0, nullptr, is_uncomp ? orig_h : 0)) {
        free(dst);
        return 0;
    }

    out->width = orig_w;
    out->height = orig_h;
    out->format = out_fmt;
    out->data = dst;
    out->data_size = out_size;
    out->bytes_per_row = is_uncomp ? (orig_w * 4) : (blocks_x * bpb);
    return 1;
}

static int transcode_ktx2(
    const void *data,
    uint32_t size,
    ZBasisFormat out_fmt,
    ZBasisImage *out)
{
    ktx2_transcoder dec;
    if (!dec.init(data, size)) return 0;
    if (!dec.start_transcoding()) return 0;

    basist::ktx2_image_level_info li;
    if (!dec.get_image_level_info(li, 0, 0, 0)) return 0;

    const transcoder_texture_format bf = to_basis_fmt(out_fmt);
    const bool is_uncomp = (out_fmt == ZBASIS_FMT_RGBA8);
    const uint32_t bpb = bytes_per_block(out_fmt);
    const uint32_t blocks_x = (li.m_width + 3) / 4;
    const uint32_t blocks_y = (li.m_height + 3) / 4;
    const uint32_t out_size = is_uncomp ? (li.m_width * li.m_height * 4) : (blocks_x * blocks_y * bpb);
    const uint32_t out_blocks_or_pixels = is_uncomp ? (li.m_width * li.m_height) : (blocks_x * blocks_y);

    uint8_t *dst = (uint8_t *)malloc(out_size);
    if (!dst) return 0;

    if (!dec.transcode_image_level(
            0, 0, 0, dst, out_blocks_or_pixels, bf, 0,
            is_uncomp ? li.m_width : 0, is_uncomp ? li.m_height : 0)) {
        free(dst);
        return 0;
    }

    out->width = li.m_width;
    out->height = li.m_height;
    out->format = out_fmt;
    out->data = dst;
    out->data_size = out_size;
    out->bytes_per_row = is_uncomp ? (li.m_width * 4) : (blocks_x * bpb);
    return 1;
}

extern "C" int zbasis_transcode_memory(
    const void *file_data,
    size_t file_size,
    int prefer_astc,
    int srgb,
    ZBasisImage *out)
{
    if (!file_data || !out || file_size < 4) return 0;
    zbasis_init();
    std::memset(out, 0, sizeof(*out));

    ZBasisFormat fmt;
    if (prefer_astc)
        fmt = srgb ? ZBASIS_FMT_ASTC_4x4_RGBA_SRGB : ZBASIS_FMT_ASTC_4x4_RGBA;
    else
        fmt = srgb ? ZBASIS_FMT_BC7_RGBA_SRGB : ZBASIS_FMT_BC7_RGBA;

    // KTX2 magic: 0xAB 0x4B 0x54 0x58
    const uint8_t *b = (const uint8_t *)file_data;
    const bool is_ktx2 = file_size >= 12 && b[0] == 0xAB && b[1] == 'K' && b[2] == 'T' && b[3] == 'X';

    if (is_ktx2)
        return transcode_ktx2(file_data, (uint32_t)file_size, fmt, out);
    return transcode_basis(file_data, (uint32_t)file_size, fmt, out);
}

extern "C" int zbasis_transcode_file(const char *path, int prefer_astc, int srgb, ZBasisImage *out) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) return 0;
    const auto sz = (size_t)f.tellg();
    f.seekg(0);
    std::vector<uint8_t> buf(sz);
    if (!f.read((char *)buf.data(), (std::streamsize)sz)) return 0;
    return zbasis_transcode_memory(buf.data(), buf.size(), prefer_astc, srgb, out);
}

extern "C" void zbasis_image_free(ZBasisImage *img) {
    if (!img) return;
    free(img->data);
    img->data = nullptr;
    img->data_size = 0;
}

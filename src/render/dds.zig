const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

/// Minimal DDS BC1/BC3/BC7 loader (ROADMAP §2.4 compressed textures — PC/WebGPU path).
/// ASTC: `astc.zig`. Basis/KTX2 cook+transcode: `zbasis`.

const dds_magic: u32 = 0x20534444; // "DDS "

const DdsPixelFormat = extern struct {
    size: u32,
    flags: u32,
    four_cc: u32,
    rgb_bit_count: u32,
    r_bit_mask: u32,
    g_bit_mask: u32,
    b_bit_mask: u32,
    a_bit_mask: u32,
};

const DdsHeader = extern struct {
    size: u32,
    flags: u32,
    height: u32,
    width: u32,
    pitch_or_linear: u32,
    depth: u32,
    mip_map_count: u32,
    reserved1: [11]u32,
    pf: DdsPixelFormat,
    caps: u32,
    caps2: u32,
    caps3: u32,
    caps4: u32,
    reserved2: u32,
};

const DdsHeaderDxt10 = extern struct {
    dxgi_format: u32,
    resource_dimension: u32,
    misc_flag: u32,
    array_size: u32,
    misc_flags2: u32,
};

const fourcc_dxt1: u32 = 0x31545844;
const fourcc_dxt5: u32 = 0x35545844;
const fourcc_dx10: u32 = 0x30315844;

// DXGI_FORMAT
const dxgi_bc1_unorm: u32 = 71;
const dxgi_bc1_unorm_srgb: u32 = 72;
const dxgi_bc3_unorm: u32 = 77;
const dxgi_bc3_unorm_srgb: u32 = 78;
const dxgi_bc7_unorm: u32 = 98;
const dxgi_bc7_unorm_srgb: u32 = 99;

pub const Loaded = struct {
    width: u32,
    height: u32,
    format: wgpu.TextureFormat,
    /// Owned block-compressed bytes (mip0 only).
    data: []u8,
    bytes_per_row: u32,
};

pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !Loaded {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const raw = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(raw);
    return try parse(allocator, raw);
}

pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !Loaded {
    if (raw.len < 4 + @sizeOf(DdsHeader)) return error.InvalidDds;
    const magic = std.mem.readInt(u32, raw[0..4], .little);
    if (magic != dds_magic) return error.InvalidDds;

    var header: DdsHeader = undefined;
    @memcpy(std.mem.asBytes(&header), raw[4 .. 4 + @sizeOf(DdsHeader)]);
    if (header.size != 124) return error.InvalidDds;

    var offset: usize = 4 + @sizeOf(DdsHeader);
    var format: wgpu.TextureFormat = .bc3_rgba_unorm_srgb;
    var block_bytes: u32 = 16;

    if (header.pf.four_cc == fourcc_dxt1) {
        format = .bc1_rgba_unorm_srgb;
        block_bytes = 8;
    } else if (header.pf.four_cc == fourcc_dxt5) {
        format = .bc3_rgba_unorm_srgb;
        block_bytes = 16;
    } else if (header.pf.four_cc == fourcc_dx10) {
        if (raw.len < offset + @sizeOf(DdsHeaderDxt10)) return error.InvalidDds;
        var dx10: DdsHeaderDxt10 = undefined;
        @memcpy(std.mem.asBytes(&dx10), raw[offset .. offset + @sizeOf(DdsHeaderDxt10)]);
        offset += @sizeOf(DdsHeaderDxt10);
        switch (dx10.dxgi_format) {
            dxgi_bc1_unorm => {
                format = .bc1_rgba_unorm;
                block_bytes = 8;
            },
            dxgi_bc1_unorm_srgb => {
                format = .bc1_rgba_unorm_srgb;
                block_bytes = 8;
            },
            dxgi_bc3_unorm => {
                format = .bc3_rgba_unorm;
                block_bytes = 16;
            },
            dxgi_bc3_unorm_srgb => {
                format = .bc3_rgba_unorm_srgb;
                block_bytes = 16;
            },
            dxgi_bc7_unorm => {
                format = .bc7_rgba_unorm;
                block_bytes = 16;
            },
            dxgi_bc7_unorm_srgb => {
                format = .bc7_rgba_unorm_srgb;
                block_bytes = 16;
            },
            else => return error.UnsupportedDdsFormat,
        }
    } else return error.UnsupportedDdsFormat;

    const w = header.width;
    const h = header.height;
    const blocks_x = (@max(w, 1) + 3) / 4;
    const blocks_y = (@max(h, 1) + 3) / 4;
    const mip0_size = blocks_x * blocks_y * block_bytes;
    if (raw.len < offset + mip0_size) return error.TruncatedDds;

    const data = try allocator.dupe(u8, raw[offset .. offset + mip0_size]);
    return .{
        .width = w,
        .height = h,
        .format = format,
        .data = data,
        .bytes_per_row = blocks_x * block_bytes,
    };
}

pub fn upload(
    gctx: *zgpu.GraphicsContext,
    loaded: Loaded,
) zgpu.TextureHandle {
    const tex = gctx.createTexture(.{
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .dimension = .tdim_2d,
        .size = .{ .width = loaded.width, .height = loaded.height, .depth_or_array_layers = 1 },
        .format = loaded.format,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    gctx.queue.writeTexture(
        .{
            .texture = gctx.lookupResource(tex).?,
            .mip_level = 0,
            .origin = .{},
            .aspect = .all,
        },
        .{
            .offset = 0,
            .bytes_per_row = loaded.bytes_per_row,
            .rows_per_image = (@max(loaded.height, 1) + 3) / 4,
        },
        .{ .width = loaded.width, .height = loaded.height, .depth_or_array_layers = 1 },
        u8,
        loaded.data,
    );
    return tex;
}

test "reject non-dds" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidDds, parse(allocator, "not a dds"));
}

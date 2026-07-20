const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

pub extern fn zbasis_init() void;
pub extern fn zbasis_transcode_memory(file_data: ?*const anyopaque, file_size: usize, prefer_astc: c_int, srgb: c_int, out: *ZBasisImage) c_int;
pub extern fn zbasis_transcode_file(path: [*:0]const u8, prefer_astc: c_int, srgb: c_int, out: *ZBasisImage) c_int;
pub extern fn zbasis_image_free(img: *ZBasisImage) void;

pub extern fn tzstd_compress_bound(src_size: usize) usize;
pub extern fn tzstd_compress(dst: ?*anyopaque, dst_cap: usize, src: ?*const anyopaque, src_size: usize, level: c_int) usize;
pub extern fn tzstd_decompress(dst: ?*anyopaque, dst_cap: usize, src: ?*const anyopaque, src_size: usize) usize;

/// Zstd compress (Dagor second-stage pack). Level 1..=22, default 3.
pub fn zstdCompress(allocator: std.mem.Allocator, src: []const u8, level: c_int) ![]u8 {
    const bound = tzstd_compress_bound(src.len);
    const dst = try allocator.alloc(u8, bound);
    errdefer allocator.free(dst);
    const n = tzstd_compress(dst.ptr, dst.len, src.ptr, src.len, level);
    if (n == 0) return error.ZstdCompressFailed;
    return try allocator.realloc(dst, n);
}

pub fn zstdDecompress(allocator: std.mem.Allocator, src: []const u8, max_out: usize) ![]u8 {
    const dst = try allocator.alloc(u8, max_out);
    errdefer allocator.free(dst);
    const n = tzstd_decompress(dst.ptr, dst.len, src.ptr, src.len);
    if (n == 0) return error.ZstdDecompressFailed;
    return try allocator.realloc(dst, n);
}

pub const ZBasisFormat = enum(c_int) {
    bc7_rgba_srgb = 0,
    bc7_rgba = 1,
    astc_4x4_rgba_srgb = 2,
    astc_4x4_rgba = 3,
    rgba8 = 4,
};

pub const ZBasisImage = extern struct {
    width: u32,
    height: u32,
    format: ZBasisFormat,
    data: ?[*]u8,
    data_size: usize,
    bytes_per_row: u32,
};

pub const Format = enum {
    bc7_srgb,
    bc7,
    astc4x4_srgb,
    astc4x4,
    rgba8,
};

pub const Image = struct {
    width: u32,
    height: u32,
    format: Format,
    data: []u8,
    bytes_per_row: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Image) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }
};

var inited = false;

pub fn init() void {
    if (inited) return;
    zbasis_init();
    inited = true;
}

pub fn transcodeFile(
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    prefer_astc: bool,
    srgb: bool,
) !Image {
    init();
    var raw: ZBasisImage = std.mem.zeroes(ZBasisImage);
    if (zbasis_transcode_file(path.ptr, @intFromBool(prefer_astc), @intFromBool(srgb), &raw) == 0)
        return error.ZBasisTranscodeFailed;
    defer zbasis_image_free(&raw);
    const ptr = raw.data orelse return error.ZBasisTranscodeFailed;
    const copy = try allocator.dupe(u8, ptr[0..raw.data_size]);
    return .{
        .width = raw.width,
        .height = raw.height,
        .format = fromC(raw.format),
        .data = copy,
        .bytes_per_row = raw.bytes_per_row,
        .allocator = allocator,
    };
}

fn fromC(f: ZBasisFormat) Format {
    return switch (f) {
        .bc7_rgba_srgb => .bc7_srgb,
        .bc7_rgba => .bc7,
        .astc_4x4_rgba_srgb => .astc4x4_srgb,
        .astc_4x4_rgba => .astc4x4,
        .rgba8 => .rgba8,
    };
}

pub fn toWgpu(f: Format) wgpu.TextureFormat {
    return switch (f) {
        .bc7_srgb => .bc7_rgba_unorm_srgb,
        .bc7 => .bc7_rgba_unorm,
        .astc4x4_srgb => .astc4x4_unorm_srgb,
        .astc4x4 => .astc4x4_unorm,
        .rgba8 => .rgba8_unorm,
    };
}

pub fn upload(gctx: *zgpu.GraphicsContext, img: Image) zgpu.TextureHandle {
    const fmt = toWgpu(img.format);
    const tex = gctx.createTexture(.{
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .dimension = .tdim_2d,
        .size = .{ .width = img.width, .height = img.height, .depth_or_array_layers = 1 },
        .format = fmt,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    const rows: u32 = if (img.format == .rgba8) img.height else (@max(img.height, 1) + 3) / 4;
    gctx.queue.writeTexture(
        .{
            .texture = gctx.lookupResource(tex).?,
            .mip_level = 0,
            .origin = .{},
            .aspect = .all,
        },
        .{
            .offset = 0,
            .bytes_per_row = img.bytes_per_row,
            .rows_per_image = rows,
        },
        .{ .width = img.width, .height = img.height, .depth_or_array_layers = 1 },
        u8,
        img.data,
    );
    return tex;
}

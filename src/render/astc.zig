const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

/// Native ASTC 4x4 container + void-extent cook (ROADMAP §2.4).
/// File magic "ASTC\0" + u32 width + u32 height + raw 16-byte blocks.

pub const magic = "ASTC";
pub const block_bytes: u32 = 16;

pub const Loaded = struct {
    width: u32,
    height: u32,
    srgb: bool,
    data: []u8,
    bytes_per_row: u32,
};

pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !Loaded {
    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(raw);
    return try parse(allocator, raw);
}

pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !Loaded {
    if (raw.len < 12) return error.InvalidAstc;
    if (!std.mem.eql(u8, raw[0..4], magic)) return error.InvalidAstc;
    const w = std.mem.readInt(u32, raw[4..8], .little);
    const h = std.mem.readInt(u32, raw[8..12], .little);
    const flags = if (raw.len >= 16) std.mem.readInt(u32, raw[12..16], .little) else 1;
    const header: usize = if (raw.len >= 16 and (flags == 0 or flags == 1)) 16 else 12;
    const srgb = if (header == 16) flags != 0 else true;

    const bx = (@max(w, 1) + 3) / 4;
    const by = (@max(h, 1) + 3) / 4;
    const need = header + bx * by * block_bytes;
    if (raw.len < need) return error.TruncatedAstc;

    const data = try allocator.dupe(u8, raw[header..need]);
    return .{
        .width = w,
        .height = h,
        .srgb = srgb,
        .data = data,
        .bytes_per_row = bx * block_bytes,
    };
}

pub fn upload(gctx: *zgpu.GraphicsContext, loaded: Loaded) zgpu.TextureHandle {
    const format: wgpu.TextureFormat = if (loaded.srgb) .astc4x4_unorm_srgb else .astc4x4_unorm;
    const tex = gctx.createTexture(.{
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .dimension = .tdim_2d,
        .size = .{ .width = loaded.width, .height = loaded.height, .depth_or_array_layers = 1 },
        .format = format,
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

/// Encode constant-color ASTC 4x4 void-extent block (LDR).
pub fn encodeVoidExtent(r: u8, g: u8, b: u8, a: u8) [16]u8 {
    var block: [16]u8 = .{0} ** 16;
    // 2D LDR void-extent marker (Khronos ASTC): low bits form void-extent mode.
    block[0] = 0xFC;
    block[1] = 0xFD;
    block[2] = 0xFF;
    block[3] = 0xFF;
    block[4] = 0xFF;
    block[5] = 0xFF;
    block[6] = 0xFF;
    block[7] = 0xFF;
    // RGBA as 16-bit UNORM little-endian (replicate 8→16).
    writeU16(&block, 8, expand8(r));
    writeU16(&block, 10, expand8(g));
    writeU16(&block, 12, expand8(b));
    writeU16(&block, 14, expand8(a));
    return block;
}

fn expand8(v: u8) u16 {
    return (@as(u16, v) << 8) | v;
}

fn writeU16(block: *[16]u8, offset: usize, v: u16) void {
    block[offset] = @truncate(v);
    block[offset + 1] = @truncate(v >> 8);
}

/// Cook RGBA8 image to native .astc (void-extent per 4x4 — valid ASTC, good for pipeline demo).
pub fn cookRgba8(allocator: std.mem.Allocator, width: u32, height: u32, rgba: []const u8, srgb: bool) ![]u8 {
    const bx = (@max(width, 1) + 3) / 4;
    const by = (@max(height, 1) + 3) / 4;
    var out = try allocator.alloc(u8, 16 + bx * by * block_bytes);
    @memcpy(out[0..4], magic);
    std.mem.writeInt(u32, out[4..8], width, .little);
    std.mem.writeInt(u32, out[8..12], height, .little);
    std.mem.writeInt(u32, out[12..16], if (srgb) @as(u32, 1) else 0, .little);

    var by_i: u32 = 0;
    while (by_i < by) : (by_i += 1) {
        var bx_i: u32 = 0;
        while (bx_i < bx) : (bx_i += 1) {
            var sum = [4]u32{ 0, 0, 0, 0 };
            var count: u32 = 0;
            var py: u32 = 0;
            while (py < 4) : (py += 1) {
                var px: u32 = 0;
                while (px < 4) : (px += 1) {
                    const x = bx_i * 4 + px;
                    const y = by_i * 4 + py;
                    if (x >= width or y >= height) continue;
                    const i = (y * width + x) * 4;
                    sum[0] += rgba[i];
                    sum[1] += rgba[i + 1];
                    sum[2] += rgba[i + 2];
                    sum[3] += rgba[i + 3];
                    count += 1;
                }
            }
            if (count == 0) count = 1;
            const block = encodeVoidExtent(
                @intCast(sum[0] / count),
                @intCast(sum[1] / count),
                @intCast(sum[2] / count),
                @intCast(sum[3] / count),
            );
            const dst = 16 + (by_i * bx + bx_i) * block_bytes;
            @memcpy(out[dst .. dst + 16], &block);
        }
    }
    return out;
}

test "void extent block size" {
    const b = encodeVoidExtent(255, 0, 0, 255);
    try std.testing.expectEqual(@as(usize, 16), b.len);
}

test "cook and parse roundtrip" {
    const allocator = std.testing.allocator;
    var rgba: [16 * 4]u8 = undefined;
    @memset(&rgba, 200);
    const cooked = try cookRgba8(allocator, 4, 4, &rgba, true);
    defer allocator.free(cooked);
    const loaded = try parse(allocator, cooked);
    defer allocator.free(loaded.data);
    try std.testing.expectEqual(@as(u32, 4), loaded.width);
    try std.testing.expectEqual(@as(u32, 4), loaded.height);
    try std.testing.expect(loaded.srgb);
    try std.testing.expectEqual(@as(usize, 16), loaded.data.len);
}

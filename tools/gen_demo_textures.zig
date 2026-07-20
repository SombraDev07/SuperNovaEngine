const std = @import("std");
const zstbi = @import("zstbi");

/// One-shot helper: write demo PBR PNGs under assets/textures/.
pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    zstbi.init(allocator);
    defer zstbi.deinit();

    try std.fs.cwd().makePath("assets/textures");
    try std.fs.cwd().makePath("assets/materials");

    const size: u32 = 256;
    var albedo = try allocator.alloc(u8, size * size * 4);
    defer allocator.free(albedo);
    var normal = try allocator.alloc(u8, size * size * 4);
    defer allocator.free(normal);
    var orm = try allocator.alloc(u8, size * size * 4);
    defer allocator.free(orm);

    var y: u32 = 0;
    while (y < size) : (y += 1) {
        var x: u32 = 0;
        while (x < size) : (x += 1) {
            const checker = ((x / 32) + (y / 32)) % 2 == 0;
            const i = (y * size + x) * 4;
            const u = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(size));
            const v = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(size));
            const fu = @abs(@mod(u * 8.0, 1.0) - 0.5);
            const fv = @abs(@mod(v * 8.0, 1.0) - 0.5);
            const groove = @max(1.0 - fu * 12.0, 0.0) + @max(1.0 - fv * 12.0, 0.0);
            const dx = std.math.clamp((@mod(u * 8.0, 1.0) - 0.5) * 4.0, -1.0, 1.0) * groove;
            const dy = std.math.clamp((@mod(v * 8.0, 1.0) - 0.5) * 4.0, -1.0, 1.0) * groove;

            if (checker) {
                albedo[i + 0] = 210;
                albedo[i + 1] = 95;
                albedo[i + 2] = 55;
            } else {
                albedo[i + 0] = 48;
                albedo[i + 1] = 56;
                albedo[i + 2] = 68;
            }
            albedo[i + 3] = 255;

            normal[i + 0] = @intFromFloat((dx * 0.5 + 0.5) * 255.0);
            normal[i + 1] = @intFromFloat((dy * 0.5 + 0.5) * 255.0);
            normal[i + 2] = 255;
            normal[i + 3] = 255;

            orm[i + 0] = if (groove > 0.55) 160 else 255;
            orm[i + 1] = if (checker) 45 else 180;
            orm[i + 2] = if (checker) 220 else 10;
            orm[i + 3] = @intFromFloat(std.math.clamp(1.0 - groove, 0, 1) * 255.0);
        }
    }

    try writePng("assets/textures/demo_albedo.png", albedo, size, size);
    try writePng("assets/textures/demo_normal.png", normal, size, size);
    try writePng("assets/textures/demo_orm.png", orm, size, size);

    var emissive = try allocator.alloc(u8, size * size * 4);
    defer allocator.free(emissive);
    y = 0;
    while (y < size) : (y += 1) {
        var x: u32 = 0;
        while (x < size) : (x += 1) {
            const checker = ((x / 32) + (y / 32)) % 2 == 0;
            const i = (y * size + x) * 4;
            if (checker) {
                emissive[i + 0] = 40;
                emissive[i + 1] = 12;
                emissive[i + 2] = 4;
            } else {
                emissive[i + 0] = 0;
                emissive[i + 1] = 0;
                emissive[i + 2] = 0;
            }
            emissive[i + 3] = 255;
        }
    }
    try writePng("assets/textures/demo_emissive.png", emissive, size, size);
    std.debug.print("wrote demo PBR textures\n", .{});
}

fn writePng(path: [:0]const u8, rgba: []u8, w: u32, h: u32) !void {
    var img = zstbi.Image{
        .data = rgba,
        .width = w,
        .height = h,
        .num_components = 4,
        .bytes_per_component = 1,
        .bytes_per_row = w * 4,
        .is_hdr = false,
    };
    try img.writeToFile(path, .png);
}

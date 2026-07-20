const std = @import("std");
const zstbi = @import("zstbi");
const astc = @import("astc");

/// Cook demo PNG maps → .astc (native) + .basis / .ktx2 (zbasis/UASTC).
pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    zstbi.init(allocator);
    defer zstbi.deinit();

    try std.fs.cwd().makePath("assets/textures");

    try cookMap(allocator, "assets/textures/demo_albedo.png", true);
    try cookMap(allocator, "assets/textures/demo_normal.png", false);
    try cookMap(allocator, "assets/textures/demo_orm.png", false);
    try cookMap(allocator, "assets/textures/demo_emissive.png", true);

    std.debug.print("cook-textures: wrote .astc + .basis (+ albedo.ktx2)\n", .{});
}

fn cookMap(allocator: std.mem.Allocator, png_path: [:0]const u8, srgb: bool) !void {
    var img = try zstbi.Image.loadFromFile(png_path, 4);
    defer img.deinit();
    const w = img.width;
    const h = img.height;
    const rgba = img.data[0 .. w * h * 4];

    const stem = stemOf(png_path);

    const astc_bytes = try astc.cookRgba8(allocator, w, h, rgba, srgb);
    defer allocator.free(astc_bytes);
    const astc_path = try std.fmt.allocPrint(allocator, "assets/textures/{s}.astc", .{stem});
    defer allocator.free(astc_path);
    try std.fs.cwd().writeFile(.{ .sub_path = astc_path, .data = astc_bytes });

    try encodeBasis(allocator, rgba, w, h, srgb, false, stem);
    if (std.mem.eql(u8, stem, "demo_albedo")) {
        try encodeBasis(allocator, rgba, w, h, srgb, true, stem);
    }
}

fn stemOf(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| return base[0..dot];
    return base;
}

fn encodeBasis(
    allocator: std.mem.Allocator,
    rgba: []const u8,
    w: u32,
    h: u32,
    srgb: bool,
    ktx2: bool,
    stem: []const u8,
) !void {
    var out_ptr: ?[*]u8 = null;
    var out_size: usize = 0;
    const ok = zbasis_encode_rgba8(
        rgba.ptr,
        w,
        h,
        @intFromBool(srgb),
        @intFromBool(ktx2),
        &out_ptr,
        &out_size,
    );
    if (ok == 0 or out_ptr == null or out_size == 0) return error.ZBasisEncodeFailed;
    defer zbasis_encode_free(out_ptr);

    const ext = if (ktx2) "ktx2" else "basis";
    const out_path = try std.fmt.allocPrint(allocator, "assets/textures/{s}.{s}", .{ stem, ext });
    defer allocator.free(out_path);
    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = out_ptr.?[0..out_size] });
}

pub extern fn zbasis_encode_rgba8(
    rgba: [*]const u8,
    width: u32,
    height: u32,
    srgb: c_int,
    ktx2: c_int,
    out_data: *?[*]u8,
    out_size: *usize,
) c_int;
pub extern fn zbasis_encode_free(data: ?[*]u8) void;

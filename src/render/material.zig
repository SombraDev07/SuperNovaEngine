const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zstbi = @import("zstbi");
const zbasis = @import("zbasis");
const log = @import("../core/log.zig");
const dds = @import("dds.zig");
const astc = @import("astc.zig");

/// Data-driven PBR material definition (ZON, ROADMAP §2.4a).
/// Paths are relative to the assets root (usually `assets/`).
pub const MaterialDef = struct {
    name: []const u8 = "unnamed",
    albedo: []const u8 = "",
    normal: []const u8 = "",
    orm: []const u8 = "",
    /// Optional; empty → black emissive.
    emissive: []const u8 = "",
    metallic: f32 = 1.0,
    roughness: f32 = 1.0,
    ao: f32 = 1.0,

    pub fn parseZon(allocator: std.mem.Allocator, source: [:0]const u8) !MaterialDef {
        return try std.zon.parse.fromSlice(MaterialDef, allocator, source, null, .{});
    }

    pub fn free(self: *MaterialDef, allocator: std.mem.Allocator) void {
        std.zon.parse.free(allocator, self.*);
        self.* = .{};
    }

    pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !MaterialDef {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const src = try file.readToEndAllocOptions(allocator, 64 * 1024, null, .@"1", 0);
        defer allocator.free(src);
        return try parseZon(allocator, src);
    }
};

/// GPU PBR maps bound by the G-buffer pass.
pub const Maps = struct {
    albedo: zgpu.TextureHandle = .{},
    albedo_view: zgpu.TextureViewHandle = .{},
    normal: zgpu.TextureHandle = .{},
    normal_view: zgpu.TextureViewHandle = .{},
    /// R=AO, G=roughness, B=metallic, A=height
    orm: zgpu.TextureHandle = .{},
    orm_view: zgpu.TextureViewHandle = .{},
    emissive: zgpu.TextureHandle = .{},
    emissive_view: zgpu.TextureViewHandle = .{},
    sampler: zgpu.SamplerHandle = .{},
    /// Multipliers from the material def (applied in G-buffer uniforms).
    metallic: f32 = 1.0,
    roughness: f32 = 1.0,
    ao: f32 = 1.0,
    name: []const u8 = "procedural",

    pub fn create(gctx: *zgpu.GraphicsContext, allocator: std.mem.Allocator) !Maps {
        // Prefer authored ZON + maps; fall back to procedural if missing.
        const zon_path = "assets/materials/demo_pbr.zon";
        if (std.fs.cwd().access(zon_path, .{})) |_| {
            var def = MaterialDef.loadFile(allocator, zon_path) catch |err| {
                log.warn(.render, "material ZON load failed ({s}): {s}", .{ zon_path, @errorName(err) });
                return try createProcedural(gctx, allocator);
            };
            defer def.free(allocator);
            return loadFromDef(gctx, allocator, "assets", def) catch |err| {
                log.warn(.render, "material maps load failed: {s}; using procedural", .{@errorName(err)});
                return try createProcedural(gctx, allocator);
            };
        } else |_| {
            log.info(.render, "no {s}; using procedural PBR maps", .{zon_path});
            return try createProcedural(gctx, allocator);
        }
    }

    pub fn loadFromDef(
        gctx: *zgpu.GraphicsContext,
        allocator: std.mem.Allocator,
        assets_root: []const u8,
        def: MaterialDef,
    ) !Maps {
        const albedo_path = try joinAsset(allocator, assets_root, def.albedo);
        defer allocator.free(albedo_path);
        const normal_path = try joinAsset(allocator, assets_root, def.normal);
        defer allocator.free(normal_path);
        const orm_path = try joinAsset(allocator, assets_root, def.orm);
        defer allocator.free(orm_path);

        const albedo = try loadTexture(gctx, allocator, albedo_path, .rgba8_unorm_srgb);
        errdefer destroyTex(gctx, albedo);
        const normal = try loadTexture(gctx, allocator, normal_path, .rgba8_unorm);
        errdefer destroyTex(gctx, normal);
        const orm = try loadTexture(gctx, allocator, orm_path, .rgba8_unorm);
        errdefer destroyTex(gctx, orm);

        const emissive = if (def.emissive.len > 0) blk: {
            const ep = try joinAsset(allocator, assets_root, def.emissive);
            defer allocator.free(ep);
            break :blk try loadTexture(gctx, allocator, ep, .rgba8_unorm_srgb);
        } else try createSolidColor(gctx, .{ 0, 0, 0, 255 }, .rgba8_unorm_srgb);
        errdefer destroyTex(gctx, emissive);

        log.info(.render, "material '{s}' maps loaded", .{def.name});
        return .{
            .albedo = albedo.tex,
            .albedo_view = albedo.view,
            .normal = normal.tex,
            .normal_view = normal.view,
            .orm = orm.tex,
            .orm_view = orm.view,
            .emissive = emissive.tex,
            .emissive_view = emissive.view,
            .sampler = gctx.createSampler(.{
                .mag_filter = .linear,
                .min_filter = .linear,
                .mipmap_filter = .linear,
                .address_mode_u = .repeat,
                .address_mode_v = .repeat,
                .address_mode_w = .repeat,
            }),
            .metallic = def.metallic,
            .roughness = def.roughness,
            .ao = def.ao,
            .name = "file",
        };
    }

    pub fn createProcedural(gctx: *zgpu.GraphicsContext, allocator: std.mem.Allocator) !Maps {
        const map_size: u32 = 256;
        var albedo_px = try allocator.alloc([4]u8, map_size * map_size);
        defer allocator.free(albedo_px);
        var normal_px = try allocator.alloc([4]u8, map_size * map_size);
        defer allocator.free(normal_px);
        var orm_px = try allocator.alloc([4]u8, map_size * map_size);
        defer allocator.free(orm_px);
        var emissive_px = try allocator.alloc([4]u8, map_size * map_size);
        defer allocator.free(emissive_px);

        var y: u32 = 0;
        while (y < map_size) : (y += 1) {
            var x: u32 = 0;
            while (x < map_size) : (x += 1) {
                const u = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(map_size));
                const v = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(map_size));
                const checker = ((x / 32) + (y / 32)) % 2 == 0;
                const idx = y * map_size + x;
                if (checker) {
                    albedo_px[idx] = .{ 210, 95, 55, 255 };
                } else {
                    albedo_px[idx] = .{ 48, 56, 68, 255 };
                }
                const edge = edgeFactor(u, v);
                normal_px[idx] = .{
                    @intFromFloat((edge[0] * 0.5 + 0.5) * 255.0),
                    @intFromFloat((edge[1] * 0.5 + 0.5) * 255.0),
                    255,
                    255,
                };
                const ao: u8 = if (edge[2] > 0.55) 160 else 255;
                const rough: u8 = if (checker) 45 else 180;
                const metal: u8 = if (checker) 220 else 10;
                const height: u8 = @intFromFloat(std.math.clamp(1.0 - edge[2], 0, 1) * 255.0);
                orm_px[idx] = .{ ao, rough, metal, height };
                // Warm emissive on metal tiles.
                if (checker) {
                    emissive_px[idx] = .{ 40, 12, 4, 255 };
                } else {
                    emissive_px[idx] = .{ 0, 0, 0, 255 };
                }
            }
        }

        const albedo = uploadRgba8(gctx, albedo_px, map_size, map_size, .rgba8_unorm_srgb);
        const normal = uploadRgba8(gctx, normal_px, map_size, map_size, .rgba8_unorm);
        const orm = uploadRgba8(gctx, orm_px, map_size, map_size, .rgba8_unorm);
        const emissive = uploadRgba8(gctx, emissive_px, map_size, map_size, .rgba8_unorm_srgb);

        return .{
            .albedo = albedo,
            .albedo_view = gctx.createTextureView(albedo, .{}),
            .normal = normal,
            .normal_view = gctx.createTextureView(normal, .{}),
            .orm = orm,
            .orm_view = gctx.createTextureView(orm, .{}),
            .emissive = emissive,
            .emissive_view = gctx.createTextureView(emissive, .{}),
            .sampler = gctx.createSampler(.{
                .mag_filter = .linear,
                .min_filter = .linear,
                .mipmap_filter = .nearest,
                .address_mode_u = .repeat,
                .address_mode_v = .repeat,
                .address_mode_w = .repeat,
            }),
            .name = "procedural",
        };
    }

    pub fn destroy(self: *Maps, gctx: *zgpu.GraphicsContext) void {
        if (gctx.isResourceValid(self.albedo_view)) gctx.releaseResource(self.albedo_view);
        if (gctx.isResourceValid(self.albedo)) gctx.destroyResource(self.albedo);
        if (gctx.isResourceValid(self.normal_view)) gctx.releaseResource(self.normal_view);
        if (gctx.isResourceValid(self.normal)) gctx.destroyResource(self.normal);
        if (gctx.isResourceValid(self.orm_view)) gctx.releaseResource(self.orm_view);
        if (gctx.isResourceValid(self.orm)) gctx.destroyResource(self.orm);
        if (gctx.isResourceValid(self.emissive_view)) gctx.releaseResource(self.emissive_view);
        if (gctx.isResourceValid(self.emissive)) gctx.destroyResource(self.emissive);
        if (gctx.isResourceValid(self.sampler)) gctx.releaseResource(self.sampler);
        self.* = .{};
    }
};

const TexPair = struct {
    tex: zgpu.TextureHandle,
    view: zgpu.TextureViewHandle,
};

fn destroyTex(gctx: *zgpu.GraphicsContext, t: TexPair) void {
    if (gctx.isResourceValid(t.view)) gctx.releaseResource(t.view);
    if (gctx.isResourceValid(t.tex)) gctx.destroyResource(t.tex);
}

/// Public texture load for glTF / tooling (png/jpg/dds/basis/ktx2/astc).
pub fn loadTextureFile(
    gctx: *zgpu.GraphicsContext,
    allocator: std.mem.Allocator,
    path_z: [:0]const u8,
    format: wgpu.TextureFormat,
) !struct { tex: zgpu.TextureHandle, view: zgpu.TextureViewHandle } {
    const t = try loadTexture(gctx, allocator, path_z, format);
    return .{ .tex = t.tex, .view = t.view };
}

pub fn createSolidRgba(
    gctx: *zgpu.GraphicsContext,
    rgba: [4]u8,
    format: wgpu.TextureFormat,
) !struct { tex: zgpu.TextureHandle, view: zgpu.TextureViewHandle } {
    const t = try createSolidColor(gctx, rgba, format);
    return .{ .tex = t.tex, .view = t.view };
}

pub fn uploadRgba8Public(
    gctx: *zgpu.GraphicsContext,
    pixels: []const [4]u8,
    width: u32,
    height: u32,
    format: wgpu.TextureFormat,
) zgpu.TextureHandle {
    return uploadRgba8(gctx, pixels, width, height, format);
}

fn joinAsset(allocator: std.mem.Allocator, root: []const u8, rel: []const u8) ![:0]u8 {
    return try std.fs.path.joinZ(allocator, &.{ root, rel });
}

fn loadTexture(
    gctx: *zgpu.GraphicsContext,
    allocator: std.mem.Allocator,
    path_z: [:0]const u8,
    fallback_rgba_format: wgpu.TextureFormat,
) !TexPair {
    if (std.ascii.endsWithIgnoreCase(path_z, ".dds")) {
        const loaded = try dds.loadFile(allocator, path_z);
        defer allocator.free(loaded.data);
        const tex = dds.upload(gctx, loaded);
        return .{ .tex = tex, .view = gctx.createTextureView(tex, .{}) };
    }

    if (std.ascii.endsWithIgnoreCase(path_z, ".astc")) {
        const loaded = try astc.loadFile(allocator, path_z);
        defer allocator.free(loaded.data);
        const tex = astc.upload(gctx, loaded);
        return .{ .tex = tex, .view = gctx.createTextureView(tex, .{}) };
    }

    if (std.ascii.endsWithIgnoreCase(path_z, ".basis") or
        std.ascii.endsWithIgnoreCase(path_z, ".ktx2"))
    {
        const srgb = fallback_rgba_format == .rgba8_unorm_srgb or
            fallback_rgba_format == .bc7_rgba_unorm_srgb or
            fallback_rgba_format == .astc4x4_unorm_srgb;
        // Prefer BC7 on desktop Dawn (D3D12/Vulkan/Metal); ASTC mainly for mobile GPUs.
        var img = try zbasis.transcodeFile(allocator, path_z, false, srgb);
        defer img.deinit();
        const tex = zbasis.upload(gctx, img);
        return .{ .tex = tex, .view = gctx.createTextureView(tex, .{}) };
    }

    var img = try zstbi.Image.loadFromFile(path_z, 4);
    defer img.deinit();
    const w = img.width;
    const h = img.height;
    const pixels = std.mem.bytesAsSlice([4]u8, img.data[0 .. w * h * 4]);
    const tex = uploadRgba8(gctx, pixels, w, h, fallback_rgba_format);
    return .{ .tex = tex, .view = gctx.createTextureView(tex, .{}) };
}

fn createSolidColor(gctx: *zgpu.GraphicsContext, rgba: [4]u8, format: wgpu.TextureFormat) !TexPair {
    const pixels = [_][4]u8{rgba};
    const tex = uploadRgba8(gctx, &pixels, 1, 1, format);
    return .{ .tex = tex, .view = gctx.createTextureView(tex, .{}) };
}

fn uploadRgba8(
    gctx: *zgpu.GraphicsContext,
    pixels: []const [4]u8,
    width: u32,
    height: u32,
    format: wgpu.TextureFormat,
) zgpu.TextureHandle {
    const tex = gctx.createTexture(.{
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .dimension = .tdim_2d,
        .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
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
            .bytes_per_row = width * 4,
            .rows_per_image = height,
        },
        .{ .width = width, .height = height, .depth_or_array_layers = 1 },
        [4]u8,
        pixels,
    );
    return tex;
}

fn edgeFactor(u: f32, v: f32) [3]f32 {
    const fu = @abs(@mod(u * 8.0, 1.0) - 0.5);
    const fv = @abs(@mod(v * 8.0, 1.0) - 0.5);
    const groove = @max(1.0 - fu * 12.0, 0.0) + @max(1.0 - fv * 12.0, 0.0);
    const dx = std.math.clamp((@mod(u * 8.0, 1.0) - 0.5) * 4.0, -1.0, 1.0);
    const dy = std.math.clamp((@mod(v * 8.0, 1.0) - 0.5) * 4.0, -1.0, 1.0);
    return .{ dx * groove, dy * groove, groove };
}

test "parse demo material zon" {
    const allocator = std.testing.allocator;
    const src =
        \\.{
        \\    .name = "unit",
        \\    .albedo = "textures/a.png",
        \\    .normal = "textures/n.png",
        \\    .orm = "textures/o.png",
        \\    .metallic = 0.5,
        \\    .roughness = 0.4,
        \\    .ao = 0.9,
        \\}
    ;
    var def = try MaterialDef.parseZon(allocator, src);
    defer def.free(allocator);
    try std.testing.expectEqualStrings("unit", def.name);
    try std.testing.expectEqualStrings("textures/a.png", def.albedo);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), def.metallic, 1e-5);
}

test "edge factor in range" {
    const e = edgeFactor(0.1, 0.2);
    try std.testing.expect(e[0] >= -1.0 and e[0] <= 1.0);
    _ = wgpu.TextureFormat.rgba8_unorm;
}

test "transcode demo albedo basis to bc7" {
    const allocator = std.testing.allocator;
    // Skip if assets not present (CI without cook).
    std.fs.cwd().access("assets/textures/demo_albedo.basis", .{}) catch return;
    var img = try zbasis.transcodeFile(allocator, "assets/textures/demo_albedo.basis", false, true);
    defer img.deinit();
    try std.testing.expect(img.width >= 4);
    try std.testing.expect(img.height >= 4);
    try std.testing.expect(img.format == .bc7_srgb or img.format == .bc7);
    try std.testing.expect(img.data.len > 0);
}

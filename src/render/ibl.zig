const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const log = @import("../core/log.zig");

pub const face_size: u32 = 256;
pub const mip_count: u32 = 9; // log2(256)+1
pub const dfg_size: u32 = 256;
pub const prefilter_samples: u32 = 96;

pub const Pixel = extern struct { r: f16, g: f16, b: f16, a: f16 };

/// L2 SH irradiance coefficients (9 RGB triplets), GPU-ready as 9×vec4.
pub const ShIrradiance = extern struct {
    coeff: [9][4]f32,

    pub fn zero() ShIrradiance {
        return .{ .coeff = .{.{ 0, 0, 0, 0 }} ** 9 };
    }
};

pub const Environment = struct {
    cubemap: zgpu.TextureHandle = .{},
    cubemap_view: zgpu.TextureViewHandle = .{},
    sampler: zgpu.SamplerHandle = .{},
    dfg: zgpu.TextureHandle = .{},
    dfg_view: zgpu.TextureViewHandle = .{},
    dfg_sampler: zgpu.SamplerHandle = .{},
    sh: ShIrradiance = .zero(),
    max_mip: f32 = @floatFromInt(mip_count - 1),

    pub fn create(gctx: *zgpu.GraphicsContext, allocator: std.mem.Allocator) !Environment {
        var faces: [6][]Pixel = undefined;
        defer for (&faces) |*f| allocator.free(f.*);

        var sh_acc = ShAccumulator.init();
        const hdri_paths = [_][:0]const u8{
            "assets/env/default.hdr",
            "assets/env/studio.hdr",
            "assets/env/default.png",
        };
        var loaded_hdri = false;
        for (0..6) |face| {
            faces[face] = try allocator.alloc(Pixel, face_size * face_size);
        }
        for (hdri_paths) |path| {
            if (tryFillFacesFromEquirect(allocator, path, &faces, &sh_acc)) {
                loaded_hdri = true;
                log.info(.render, "IBL from HDRI {s}", .{path});
                break;
            }
        }
        if (!loaded_hdri) {
            for (0..6) |face| {
                generateFace(faces[face], @intCast(face), &sh_acc);
            }
            log.info(.render, "IBL procedural Hosek-lite (no assets/env HDRI)", .{});
        }
        const sh = sh_acc.finalize();

        const cubemap = gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .dimension = .tdim_2d,
            .size = .{
                .width = face_size,
                .height = face_size,
                .depth_or_array_layers = 6,
            },
            .format = .rgba16_float,
            .mip_level_count = mip_count,
            .sample_count = 1,
        });

        // Mip 0: source radiance.
        for (0..6) |face| {
            writeCubeFace(gctx, cubemap, 0, @intCast(face), face_size, faces[face]);
        }

        // GGX specular prefilter for remaining mips (Karis split-sum).
        {
            var mip: u32 = 1;
            while (mip < mip_count) : (mip += 1) {
                const size = face_size >> @intCast(mip);
                const roughness = @as(f32, @floatFromInt(mip)) / @as(f32, @floatFromInt(mip_count - 1));
                var face: u32 = 0;
                while (face < 6) : (face += 1) {
                    const filtered = try allocator.alloc(Pixel, size * size);
                    defer allocator.free(filtered);
                    prefilterFace(filtered, size, face, roughness, &faces);
                    writeCubeFace(gctx, cubemap, mip, face, size, filtered);
                }
            }
        }

        const cubemap_view = gctx.createTextureView(cubemap, .{
            .dimension = .tvdim_cube,
            .base_mip_level = 0,
            .mip_level_count = mip_count,
            .base_array_layer = 0,
            .array_layer_count = 6,
        });

        const sampler = gctx.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .lod_min_clamp = 0,
            .lod_max_clamp = @floatFromInt(mip_count - 1),
        });

        const dfg_pixels = try allocator.alloc(Pixel, dfg_size * dfg_size);
        defer allocator.free(dfg_pixels);
        generateDfgLut(dfg_pixels);

        const dfg = gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .dimension = .tdim_2d,
            .size = .{ .width = dfg_size, .height = dfg_size, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        gctx.queue.writeTexture(
            .{
                .texture = gctx.lookupResource(dfg).?,
                .mip_level = 0,
                .origin = .{},
                .aspect = .all,
            },
            .{
                .offset = 0,
                .bytes_per_row = dfg_size * @sizeOf(Pixel),
                .rows_per_image = dfg_size,
            },
            .{ .width = dfg_size, .height = dfg_size, .depth_or_array_layers = 1 },
            Pixel,
            dfg_pixels,
        );

        const dfg_view = gctx.createTextureView(dfg, .{});
        const dfg_sampler = gctx.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });

        log.info(.render, "IBL ready ({d}^2 cube, GGX mips, DFG {d}^2, SH diffuse)", .{ face_size, dfg_size });

        return .{
            .cubemap = cubemap,
            .cubemap_view = cubemap_view,
            .sampler = sampler,
            .dfg = dfg,
            .dfg_view = dfg_view,
            .dfg_sampler = dfg_sampler,
            .sh = sh,
            .max_mip = @floatFromInt(mip_count - 1),
        };
    }
};

/// Sample equirectangular HDR/LDR into cube faces + SH (Dagor envi probe role).
fn tryFillFacesFromEquirect(
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    faces: *[6][]Pixel,
    sh: *ShAccumulator,
) bool {
    const zstbi = @import("zstbi");
    var img = zstbi.Image.loadFromFile(path, 4) catch return false;
    defer img.deinit();
    if (img.width < 8 or img.height < 4) return false;

    const w = img.width;
    const h = img.height;
    const is_hdr = img.is_hdr;
    const bpp = img.bytes_per_component;

    for (0..6) |face| {
        var y: u32 = 0;
        while (y < face_size) : (y += 1) {
            var x: u32 = 0;
            while (x < face_size) : (x += 1) {
                const u = (2.0 * (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(face_size))) - 1.0;
                const v = (2.0 * (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(face_size))) - 1.0;
                const dir = normalize(faceDirection(@intCast(face), u, v));
                const rgb = sampleEquirect(img.data, w, h, bpp, is_hdr, dir);
                faces[face][y * face_size + x] = .{
                    .r = @floatCast(rgb[0]),
                    .g = @floatCast(rgb[1]),
                    .b = @floatCast(rgb[2]),
                    .a = 1,
                };
                const r2 = u * u + v * v + 1.0;
                const weight = 4.0 / (r2 * @sqrt(r2) * @as(f32, @floatFromInt(face_size * face_size)));
                sh.add(dir, rgb, weight);
            }
        }
    }
    _ = allocator;
    return true;
}

fn sampleEquirect(data: []const u8, w: u32, h: u32, bpp: u32, is_hdr: bool, dir: [3]f32) [3]f32 {
    const d = normalize(dir);
    const phi = std.math.atan2(d[2], d[0]);
    const uu = (phi + std.math.pi) / (2.0 * std.math.pi);
    const vv = std.math.acos(clamp01(@max(-1.0, @min(1.0, d[1])))) / std.math.pi;

    const fx = clamp01(uu) * @as(f32, @floatFromInt(w - 1));
    const fy = clamp01(vv) * @as(f32, @floatFromInt(h - 1));
    const x0: u32 = @intFromFloat(@floor(fx));
    const y0: u32 = @intFromFloat(@floor(fy));
    const x1 = @min(x0 + 1, w - 1);
    const y1 = @min(y0 + 1, h - 1);
    const tx = fx - @as(f32, @floatFromInt(x0));
    const ty = fy - @as(f32, @floatFromInt(y0));

    const c00 = fetchEquirectPixel(data, w, bpp, is_hdr, x0, y0);
    const c10 = fetchEquirectPixel(data, w, bpp, is_hdr, x1, y0);
    const c01 = fetchEquirectPixel(data, w, bpp, is_hdr, x0, y1);
    const c11 = fetchEquirectPixel(data, w, bpp, is_hdr, x1, y1);
    return lerp3(lerp3(c00, c10, tx), lerp3(c01, c11, tx), ty);
}

fn fetchEquirectPixel(data: []const u8, w: u32, bpp: u32, is_hdr: bool, x: u32, y: u32) [3]f32 {
    const i = (y * w + x) * 4;
    if (is_hdr or bpp == 2) {
        const f16s = std.mem.bytesAsSlice(f16, data);
        return .{
            @floatCast(f16s[i + 0]),
            @floatCast(f16s[i + 1]),
            @floatCast(f16s[i + 2]),
        };
    }
    const scale: f32 = 1.0 / 255.0;
    // Assume sRGB LDR → rough linear.
    const r = std.math.pow(f32, @as(f32, @floatFromInt(data[i + 0])) * scale, 2.2);
    const g = std.math.pow(f32, @as(f32, @floatFromInt(data[i + 1])) * scale, 2.2);
    const b = std.math.pow(f32, @as(f32, @floatFromInt(data[i + 2])) * scale, 2.2);
    return .{ r * 1.5, g * 1.5, b * 1.5 };
}

fn writeCubeFace(
    gctx: *zgpu.GraphicsContext,
    cubemap: zgpu.TextureHandle,
    mip: u32,
    face: u32,
    size: u32,
    pixels: []const Pixel,
) void {
    gctx.queue.writeTexture(
        .{
            .texture = gctx.lookupResource(cubemap).?,
            .mip_level = mip,
            .origin = .{ .x = 0, .y = 0, .z = face },
            .aspect = .all,
        },
        .{
            .offset = 0,
            .bytes_per_row = size * @sizeOf(Pixel),
            .rows_per_image = size,
        },
        .{ .width = size, .height = size, .depth_or_array_layers = 1 },
        Pixel,
        pixels,
    );
}

fn generateDfgLut(out: []Pixel) void {
    var y: u32 = 0;
    while (y < dfg_size) : (y += 1) {
        var x: u32 = 0;
        while (x < dfg_size) : (x += 1) {
            const n_dot_v = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(dfg_size));
            const roughness = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(dfg_size));
            const integ = integrateBrdf(n_dot_v, roughness);
            out[y * dfg_size + x] = .{
                .r = @floatCast(integ[0]),
                .g = @floatCast(integ[1]),
                .b = 0,
                .a = 1,
            };
        }
    }
}

fn integrateBrdf(n_dot_v: f32, roughness: f32) [2]f32 {
    const v = [3]f32{
        @sqrt(1.0 - n_dot_v * n_dot_v),
        0,
        n_dot_v,
    };
    var a: f32 = 0;
    var b: f32 = 0;
    const n = [3]f32{ 0, 0, 1 };
    var i: u32 = 0;
    while (i < prefilter_samples) : (i += 1) {
        const xi = hammersley(i, prefilter_samples);
        const h = importanceSampleGgx(xi, n, roughness);
        const l = normalize(sub3(scale3(h, 2.0 * dot(v, h)), v));
        const n_dot_l = @max(l[2], 0.0);
        const n_dot_h = @max(h[2], 0.0);
        const v_dot_h = @max(dot(v, h), 0.0);
        if (n_dot_l > 0.0) {
            const g = geometrySmith(n_dot_v, n_dot_l, roughness);
            const g_vis = (g * v_dot_h) / @max(n_dot_h * n_dot_v, 1e-5);
            const fc = std.math.pow(f32, 1.0 - v_dot_h, 5.0);
            a += (1.0 - fc) * g_vis;
            b += fc * g_vis;
        }
    }
    const inv: f32 = 1.0 / @as(f32, @floatFromInt(prefilter_samples));
    return .{ a * inv, b * inv };
}

fn prefilterFace(out: []Pixel, size: u32, face: u32, roughness: f32, src_faces: *const [6][]Pixel) void {
    var y: u32 = 0;
    while (y < size) : (y += 1) {
        var x: u32 = 0;
        while (x < size) : (x += 1) {
            const u = (2.0 * (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(size))) - 1.0;
            const v = (2.0 * (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(size))) - 1.0;
            const n = normalize(faceDirection(face, u, v));
            const r = n;
            const v_dir = n;

            var color = [3]f32{ 0, 0, 0 };
            var weight: f32 = 0;
            var i: u32 = 0;
            while (i < prefilter_samples) : (i += 1) {
                const xi = hammersley(i, prefilter_samples);
                const h = importanceSampleGgx(xi, n, roughness);
                const l = normalize(sub3(scale3(h, 2.0 * dot(v_dir, h)), v_dir));
                const n_dot_l = @max(dot(n, l), 0.0);
                if (n_dot_l > 0.0) {
                    const sample = sampleCube(src_faces, l);
                    color[0] += sample[0] * n_dot_l;
                    color[1] += sample[1] * n_dot_l;
                    color[2] += sample[2] * n_dot_l;
                    weight += n_dot_l;
                }
            }
            if (weight > 0) {
                color[0] /= weight;
                color[1] /= weight;
                color[2] /= weight;
            } else {
                // Fallback to mirror sample when roughness≈0 / no hits.
                color = sampleCube(src_faces, r);
            }
            out[y * size + x] = .{
                .r = @floatCast(color[0]),
                .g = @floatCast(color[1]),
                .b = @floatCast(color[2]),
                .a = 1,
            };
        }
    }
}

fn sampleCube(faces: *const [6][]Pixel, dir_in: [3]f32) [3]f32 {
    const dir = normalize(dir_in);
    const ax = @abs(dir[0]);
    const ay = @abs(dir[1]);
    const az = @abs(dir[2]);
    var face: u32 = 0;
    var uc: f32 = 0;
    var vc: f32 = 0;
    if (ax >= ay and ax >= az) {
        if (dir[0] > 0) {
            face = 0;
            uc = -dir[2];
            vc = -dir[1];
        } else {
            face = 1;
            uc = dir[2];
            vc = -dir[1];
        }
        const ma = ax;
        uc = (uc / ma + 1.0) * 0.5;
        vc = (vc / ma + 1.0) * 0.5;
    } else if (ay >= ax and ay >= az) {
        if (dir[1] > 0) {
            face = 2;
            uc = dir[0];
            vc = dir[2];
        } else {
            face = 3;
            uc = dir[0];
            vc = -dir[2];
        }
        const ma = ay;
        uc = (uc / ma + 1.0) * 0.5;
        vc = (vc / ma + 1.0) * 0.5;
    } else {
        if (dir[2] > 0) {
            face = 4;
            uc = dir[0];
            vc = -dir[1];
        } else {
            face = 5;
            uc = -dir[0];
            vc = -dir[1];
        }
        const ma = az;
        uc = (uc / ma + 1.0) * 0.5;
        vc = (vc / ma + 1.0) * 0.5;
    }

    const fx = clamp01(uc) * (@as(f32, @floatFromInt(face_size)) - 1.0);
    const fy = clamp01(vc) * (@as(f32, @floatFromInt(face_size)) - 1.0);
    const x0: u32 = @intFromFloat(@floor(fx));
    const y0: u32 = @intFromFloat(@floor(fy));
    const x1 = @min(x0 + 1, face_size - 1);
    const y1 = @min(y0 + 1, face_size - 1);
    const tx = fx - @as(f32, @floatFromInt(x0));
    const ty = fy - @as(f32, @floatFromInt(y0));

    const p00 = faces.*[face][y0 * face_size + x0];
    const p10 = faces.*[face][y0 * face_size + x1];
    const p01 = faces.*[face][y1 * face_size + x0];
    const p11 = faces.*[face][y1 * face_size + x1];

    const c0 = lerp3(pixelRgb(p00), pixelRgb(p10), tx);
    const c1 = lerp3(pixelRgb(p01), pixelRgb(p11), tx);
    return lerp3(c0, c1, ty);
}

fn pixelRgb(p: Pixel) [3]f32 {
    return .{ @floatCast(p.r), @floatCast(p.g), @floatCast(p.b) };
}

fn hammersley(i: u32, n: u32) [2]f32 {
    return .{
        @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)),
        radicalInverseVdC(i),
    };
}

fn radicalInverseVdC(bits_in: u32) f32 {
    var bits = bits_in;
    bits = (bits << 16) | (bits >> 16);
    bits = ((bits & 0x55555555) << 1) | ((bits & 0xAAAAAAAA) >> 1);
    bits = ((bits & 0x33333333) << 2) | ((bits & 0xCCCCCCCC) >> 2);
    bits = ((bits & 0x0F0F0F0F) << 4) | ((bits & 0xF0F0F0F0) >> 4);
    bits = ((bits & 0x00FF00FF) << 8) | ((bits & 0xFF00FF00) >> 8);
    return @as(f32, @floatFromInt(bits)) * 2.3283064365386963e-10;
}

fn importanceSampleGgx(xi: [2]f32, n: [3]f32, roughness: f32) [3]f32 {
    const a = roughness * roughness;
    const phi = 2.0 * std.math.pi * xi[0];
    const cos_theta = @sqrt((1.0 - xi[1]) / (1.0 + (a * a - 1.0) * xi[1]));
    const sin_theta = @sqrt(@max(0.0, 1.0 - cos_theta * cos_theta));
    const h = [3]f32{
        @cos(phi) * sin_theta,
        @sin(phi) * sin_theta,
        cos_theta,
    };

    const up: [3]f32 = if (@abs(n[2]) < 0.999) .{ 0, 0, 1 } else .{ 1, 0, 0 };
    const tangent = normalize(cross(up, n));
    const bitangent = cross(n, tangent);
    return normalize(.{
        tangent[0] * h[0] + bitangent[0] * h[1] + n[0] * h[2],
        tangent[1] * h[0] + bitangent[1] * h[1] + n[1] * h[2],
        tangent[2] * h[0] + bitangent[2] * h[1] + n[2] * h[2],
    });
}

fn geometrySchlickGGX(n_dot_x: f32, roughness: f32) f32 {
    const a = roughness;
    const k = (a * a) / 2.0;
    return n_dot_x / (n_dot_x * (1.0 - k) + k);
}

fn geometrySmith(n_dot_v: f32, n_dot_l: f32, roughness: f32) f32 {
    return geometrySchlickGGX(n_dot_v, roughness) * geometrySchlickGGX(n_dot_l, roughness);
}

/// Procedural outdoor HDR for one cubemap face (+X=0 … -Z=5).
/// Hosek-lite sky + ground bounce + sun disk (no external HDRI required).
fn generateFace(out: []Pixel, face: u32, sh: *ShAccumulator) void {
    const sun_dir = normalize(.{ 0.35, 0.75, -0.45 });
    var y: u32 = 0;
    while (y < face_size) : (y += 1) {
        var x: u32 = 0;
        while (x < face_size) : (x += 1) {
            const u = (2.0 * (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(face_size))) - 1.0;
            const v = (2.0 * (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(face_size))) - 1.0;
            const dir = normalize(faceDirection(face, u, v));

            const elev = dir[1];
            const sky_zenith = .{ 0.08, 0.22, 0.72 };
            const sky_mid = .{ 0.28, 0.48, 0.88 };
            const sky_horizon = .{ 0.72, 0.78, 0.92 };
            const ground = .{ 0.12, 0.11, 0.09 };
            const ground_bounce = .{ 0.18, 0.16, 0.12 };

            var rgb: [3]f32 = undefined;
            if (elev > 0.0) {
                const t = clamp01(elev);
                const low = lerp3(sky_horizon, sky_mid, clamp01(t * 2.0));
                rgb = lerp3(low, sky_zenith, clamp01((t - 0.5) * 2.0));
                const limb = std.math.pow(f32, 1.0 - t, 4.0) * 0.55;
                rgb[0] += limb * 0.35;
                rgb[1] += limb * 0.25;
                rgb[2] += limb * 0.15;
            } else {
                const g = clamp01(-elev);
                rgb = lerp3(sky_horizon, ground, std.math.pow(f32, g, 0.55));
                const bounce = (1.0 - g) * 0.35;
                rgb[0] += ground_bounce[0] * bounce;
                rgb[1] += ground_bounce[1] * bounce;
                rgb[2] += ground_bounce[2] * bounce;
            }

            const sun_dot = clamp01(dot(dir, sun_dir));
            const sun = std.math.pow(f32, sun_dot, 512.0) * 28.0 +
                std.math.pow(f32, sun_dot, 32.0) * 3.5 +
                std.math.pow(f32, sun_dot, 4.0) * 0.45;
            rgb[0] += sun * 1.0;
            rgb[1] += sun * 0.92;
            rgb[2] += sun * 0.75;

            const fill = 0.04 + 0.06 * clamp01(elev * 0.5 + 0.5);
            rgb[0] += fill * 0.55;
            rgb[1] += fill * 0.65;
            rgb[2] += fill * 0.85;

            out[y * face_size + x] = .{
                .r = @floatCast(rgb[0]),
                .g = @floatCast(rgb[1]),
                .b = @floatCast(rgb[2]),
                .a = 1,
            };

            const r2 = u * u + v * v + 1.0;
            const weight = 4.0 / (r2 * @sqrt(r2) * @as(f32, @floatFromInt(face_size * face_size)));
            sh.add(dir, rgb, weight);
        }
    }
}

fn faceDirection(face: u32, u: f32, v: f32) [3]f32 {
    return switch (face) {
        0 => .{ 1, -v, -u },
        1 => .{ -1, -v, u },
        2 => .{ u, 1, v },
        3 => .{ u, -1, -v },
        4 => .{ u, -v, 1 },
        else => .{ -u, -v, -1 },
    };
}

const ShAccumulator = struct {
    c: [9][3]f32 = .{.{ 0, 0, 0 }} ** 9,
    weight_sum: f32 = 0,

    fn init() ShAccumulator {
        return .{};
    }

    fn add(self: *ShAccumulator, dir: [3]f32, color: [3]f32, weight: f32) void {
        const x = dir[0];
        const y = dir[1];
        const z = dir[2];
        const b = [_]f32{
            0.282095,
            0.488603 * y,
            0.488603 * z,
            0.488603 * x,
            1.092548 * x * y,
            1.092548 * y * z,
            0.315392 * (3.0 * z * z - 1.0),
            1.092548 * x * z,
            0.546274 * (x * x - y * y),
        };
        inline for (0..9) |i| {
            const w = b[i] * weight;
            self.c[i][0] += color[0] * w;
            self.c[i][1] += color[1] * w;
            self.c[i][2] += color[2] * w;
        }
        self.weight_sum += weight;
    }

    fn finalize(self: *const ShAccumulator) ShIrradiance {
        var out = ShIrradiance.zero();
        const inv = if (self.weight_sum > 0) 4.0 * std.math.pi / self.weight_sum else 0;
        const a = [_]f32{ std.math.pi, 2.094395, 2.094395, 2.094395, 0.785398, 0.785398, 0.785398, 0.785398, 0.785398 };
        inline for (0..9) |i| {
            out.coeff[i][0] = self.c[i][0] * inv * a[i];
            out.coeff[i][1] = self.c[i][1] * inv * a[i];
            out.coeff[i][2] = self.c[i][2] * inv * a[i];
            out.coeff[i][3] = 0;
        }
        return out;
    }
};

fn normalize(v: [3]f32) [3]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len < 1e-8) return .{ 0, 1, 0 };
    return .{ v[0] / len, v[1] / len, v[2] / len };
}
fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}
fn sub3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
fn scale3(a: [3]f32, s: f32) [3]f32 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}
fn clamp01(x: f32) f32 {
    return @max(0, @min(1, x));
}
fn lerp3(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return .{
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
    };
}

test "face directions are unit-ish" {
    const d = normalize(faceDirection(0, 0, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 1), @abs(d[0]), 0.01);
    _ = wgpu.TextureFormat.rgba16_float;
}

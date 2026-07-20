const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const log = @import("../core/log.zig");

pub const face_size: u32 = 64;
pub const mip_count: u32 = 7; // log2(64)+1

pub const Pixel = extern struct { r: f16, g: f16, b: f16, a: f16 };

/// L2 SH irradiance coefficients (9 RGB triplets), GPU-ready as 9×vec4.
pub const ShIrradiance = extern struct {
    /// Each: rgb = coefficient, w unused.
    coeff: [9][4]f32,

    pub fn zero() ShIrradiance {
        return .{ .coeff = .{.{ 0, 0, 0, 0 }} ** 9 };
    }
};

pub const Environment = struct {
    cubemap: zgpu.TextureHandle = .{},
    cubemap_view: zgpu.TextureViewHandle = .{},
    sampler: zgpu.SamplerHandle = .{},
    sh: ShIrradiance = .zero(),
    max_mip: f32 = @floatFromInt(mip_count - 1),

    pub fn create(gctx: *zgpu.GraphicsContext, allocator: std.mem.Allocator) !Environment {
        var faces: [6][]Pixel = undefined;
        defer for (&faces) |*f| allocator.free(f.*);

        var sh_acc = ShAccumulator.init();
        for (0..6) |face| {
            faces[face] = try allocator.alloc(Pixel, face_size * face_size);
            generateFace(faces[face], @intCast(face), &sh_acc);
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

        for (0..6) |face| {
            gctx.queue.writeTexture(
                .{
                    .texture = gctx.lookupResource(cubemap).?,
                    .mip_level = 0,
                    .origin = .{ .x = 0, .y = 0, .z = @intCast(face) },
                    .aspect = .all,
                },
                .{
                    .offset = 0,
                    .bytes_per_row = face_size * @sizeOf(Pixel),
                    .rows_per_image = face_size,
                },
                .{ .width = face_size, .height = face_size, .depth_or_array_layers = 1 },
                Pixel,
                faces[face],
            );
        }

        // Generate specular mip chain (all 6 faces).
        {
            const encoder = gctx.device.createCommandEncoder(null);
            defer encoder.release();
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            gctx.generateMipmaps(arena_state.allocator(), encoder, cubemap);
            const cmds = encoder.finish(null);
            defer cmds.release();
            gctx.queue.submit(&.{cmds});
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

        log.info(.render, "IBL environment ready ({d}^2 cube, {d} mips, SH diffuse)", .{ face_size, mip_count });

        return .{
            .cubemap = cubemap,
            .cubemap_view = cubemap_view,
            .sampler = sampler,
            .sh = sh,
            .max_mip = @floatFromInt(mip_count - 1),
        };
    }
};

/// Procedural clear-sky HDR for one cubemap face (+X=0 … -Z=5).
fn generateFace(out: []Pixel, face: u32, sh: *ShAccumulator) void {
    const sun_dir = normalize(.{ 0.35, 0.75, -0.45 });
    var y: u32 = 0;
    while (y < face_size) : (y += 1) {
        var x: u32 = 0;
        while (x < face_size) : (x += 1) {
            const u = (2.0 * (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(face_size))) - 1.0;
            const v = (2.0 * (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(face_size))) - 1.0;
            const dir = normalize(faceDirection(face, u, v));

            const sky_zenith = .{ 0.12, 0.28, 0.75 };
            const sky_horizon = .{ 0.55, 0.70, 0.95 };
            const ground = .{ 0.08, 0.09, 0.07 };
            const t = clamp01(dir[1] * 0.5 + 0.5);
            var rgb: [3]f32 = if (dir[1] > 0)
                lerp3(sky_horizon, sky_zenith, std.math.pow(f32, t, 0.65))
            else
                lerp3(sky_horizon, ground, clamp01(-dir[1]));

            // Soft sun disk (HDR).
            const sun_dot = clamp01(dot(dir, sun_dir));
            const sun = std.math.pow(f32, sun_dot, 256.0) * 12.0 + std.math.pow(f32, sun_dot, 16.0) * 1.5;
            rgb[0] += sun * 1.0;
            rgb[1] += sun * 0.92;
            rgb[2] += sun * 0.75;

            // Subtle horizon glow.
            const hglow = std.math.pow(f32, clamp01(1.0 - @abs(dir[1])), 4.0) * 0.35;
            rgb[0] += hglow * 0.9;
            rgb[1] += hglow * 0.55;
            rgb[2] += hglow * 0.25;

            out[y * face_size + x] = .{
                .r = @floatCast(rgb[0]),
                .g = @floatCast(rgb[1]),
                .b = @floatCast(rgb[2]),
                .a = 1,
            };

            // Solid angle weight ≈ (4/N^2) / (r^3) for cube mapping.
            const r2 = u * u + v * v + 1.0;
            const weight = 4.0 / (r2 * @sqrt(r2) * @as(f32, @floatFromInt(face_size * face_size)));
            sh.add(dir, rgb, weight);
        }
    }
}

fn faceDirection(face: u32, u: f32, v: f32) [3]f32 {
    // Match WebGPU / DirectX cubemap face order.
    return switch (face) {
        0 => .{ 1, -v, -u }, // +X
        1 => .{ -1, -v, u }, // -X
        2 => .{ u, 1, v }, // +Y
        3 => .{ u, -1, -v }, // -Y
        4 => .{ u, -v, 1 }, // +Z
        else => .{ -u, -v, -1 }, // -Z
    };
}

const ShAccumulator = struct {
    // 9 bands × RGB, plus weight sum for normalization.
    c: [9][3]f32 = .{.{ 0, 0, 0 }} ** 9,
    weight_sum: f32 = 0,

    fn init() ShAccumulator {
        return .{};
    }

    fn add(self: *ShAccumulator, dir: [3]f32, color: [3]f32, weight: f32) void {
        const x = dir[0];
        const y = dir[1];
        const z = dir[2];
        // Real SH basis (unnormalized; scale applied in finalize for irradiance form).
        const b = [_]f32{
            0.282095, // L00
            0.488603 * y, // L1-1
            0.488603 * z, // L10
            0.488603 * x, // L11
            1.092548 * x * y, // L2-2
            1.092548 * y * z, // L2-1
            0.315392 * (3.0 * z * z - 1.0), // L20
            1.092548 * x * z, // L21
            0.546274 * (x * x - y * y), // L22
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
        // Convert radiance SH → irradiance SH (Ramamoorthi & Hanrahan).
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
}

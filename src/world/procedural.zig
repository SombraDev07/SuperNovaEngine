const std = @import("std");
const znoise = @import("znoise");
const Heightfield = @import("heightfield.zig").Heightfield;

pub const NoiseKind = enum {
    perlin,
    simplex,
};

pub const ProceduralConfig = struct {
    seed: i32 = 1337,
    frequency: f32 = 0.02,
    octaves: i32 = 4,
    lacunarity: f32 = 2.0,
    gain: f32 = 0.5,
    amplitude: f32 = 12.0,
    base_height: f32 = 0.0,
    noise: NoiseKind = .simplex,
    /// Domain warp before sampling (Dagor-style warped continents).
    domain_warp: bool = true,
    warp_amp: f32 = 40.0,
    warp_frequency: f32 = 0.01,
};

/// Fill heightfield with znoise (Perlin / OpenSimplex2 + optional domain warp).
pub fn fillHeightfield(hf: *Heightfield, cfg: ProceduralConfig) void {
    var gen = znoise.FnlGenerator{
        .seed = cfg.seed,
        .frequency = cfg.frequency,
        .noise_type = switch (cfg.noise) {
            .perlin => .perlin,
            .simplex => .opensimplex2,
        },
        .fractal_type = .fbm,
        .octaves = cfg.octaves,
        .lacunarity = cfg.lacunarity,
        .gain = cfg.gain,
        .domain_warp_type = .opensimplex2,
        .domain_warp_amp = cfg.warp_amp,
    };

    var warp = znoise.FnlGenerator{
        .seed = cfg.seed + 91,
        .frequency = cfg.warp_frequency,
        .noise_type = .opensimplex2,
        .fractal_type = .domain_warp_independent,
        .octaves = 2,
        .domain_warp_type = .opensimplex2,
        .domain_warp_amp = cfg.warp_amp,
    };

    const n = Heightfield.vertCount(hf.resolution);
    const sp = hf.sampleSpacing();
    var z: u32 = 0;
    while (z < n) : (z += 1) {
        var x: u32 = 0;
        while (x < n) : (x += 1) {
            var wx = hf.origin_x + @as(f32, @floatFromInt(x)) * sp;
            var wz = hf.origin_z + @as(f32, @floatFromInt(z)) * sp;
            if (cfg.domain_warp) {
                warp.domainWarp2(&wx, &wz);
            }
            const nval = gen.noise2(wx, wz); // ~[-1,1]
            hf.set(x, z, cfg.base_height + nval * cfg.amplitude);
        }
    }
}

test "procedural fills non-flat" {
    const allocator = std.testing.allocator;
    var hf = try Heightfield.init(allocator, 16, 64);
    defer hf.deinit();
    fillHeightfield(&hf, .{ .seed = 42, .domain_warp = true });
    const mm = hf.minMax();
    try std.testing.expect(mm.max > mm.min);
}

test "procedural seams match across chunks" {
    const allocator = std.testing.allocator;
    const cfg: ProceduralConfig = .{ .seed = 99, .domain_warp = false };
    var a = try Heightfield.init(allocator, 8, 32);
    defer a.deinit();
    a.origin_x = 0;
    a.origin_z = 0;
    fillHeightfield(&a, cfg);
    var b = try Heightfield.init(allocator, 8, 32);
    defer b.deinit();
    b.origin_x = 32;
    b.origin_z = 0;
    fillHeightfield(&b, cfg);
    // Shared edge x=32: a.x=8 vs b.x=0
    try std.testing.expectApproxEqAbs(a.get(8, 4), b.get(0, 4), 1e-4);
}

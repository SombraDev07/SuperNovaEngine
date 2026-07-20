const std = @import("std");
const Heightfield = @import("heightfield.zig").Heightfield;

pub const layer_count: usize = 4;

/// Per-vertex/texel splat weights (Dagor DetailMap / landClass role) — 4 layers.
pub const SplatMap = struct {
    allocator: std.mem.Allocator,
    resolution: u32,
    /// RGBA weights, unnormalized ok (shader/normalize on sample). Size (res+1)^2.
    weights: [][4]f32,

    pub fn init(allocator: std.mem.Allocator, resolution: u32) !SplatMap {
        const n = resolution + 1;
        const weights = try allocator.alloc([4]f32, n * n);
        for (weights) |*w| w.* = .{ 1, 0, 0, 0 };
        return .{ .allocator = allocator, .resolution = resolution, .weights = weights };
    }

    pub fn deinit(self: *SplatMap) void {
        self.allocator.free(self.weights);
        self.* = undefined;
    }

    pub fn index(self: *const SplatMap, x: u32, z: u32) usize {
        const n = self.resolution + 1;
        return z * n + x;
    }

    pub fn get(self: *const SplatMap, x: u32, z: u32) [4]f32 {
        return self.weights[self.index(x, z)];
    }

    pub fn set(self: *SplatMap, x: u32, z: u32, w: [4]f32) void {
        self.weights[self.index(x, z)] = w;
    }

    pub fn normalizeAt(self: *SplatMap, x: u32, z: u32) void {
        const i = self.index(x, z);
        var sum: f32 = 0;
        for (self.weights[i]) |v| sum += v;
        if (sum <= 1e-6) {
            self.weights[i] = .{ 1, 0, 0, 0 };
            return;
        }
        for (&self.weights[i]) |*v| v.* /= sum;
    }

    /// Slope-based land class: steep → rock, flat → grass, low → sand, blend dirt.
    /// Also applies cliff bias (Dagor vertical/landClass role).
    pub fn fillFromSlope(self: *SplatMap, hf: *const Heightfield, rock_slope: f32) void {
        const n = self.resolution + 1;
        const sp = hf.sampleSpacing();
        var z: u32 = 0;
        while (z < n) : (z += 1) {
            var x: u32 = 0;
            while (x < n) : (x += 1) {
                const x0 = if (x > 0) x - 1 else x;
                const x1 = @min(x + 1, self.resolution);
                const z0 = if (z > 0) z - 1 else z;
                const z1 = @min(z + 1, self.resolution);
                const dhx = (hf.get(x1, z) - hf.get(x0, z)) / (@as(f32, @floatFromInt(@max(x1 - x0, 1))) * sp);
                const dhz = (hf.get(x, z1) - hf.get(x, z0)) / (@as(f32, @floatFromInt(@max(z1 - z0, 1))) * sp);
                const slope = @sqrt(dhx * dhx + dhz * dhz);
                // Cliff: steep normals get extra rock weight.
                const cliff = std.math.clamp((slope - rock_slope * 0.6) / (rock_slope * 1.4), 0, 1);
                const rock = std.math.clamp(slope / rock_slope + cliff * 0.55, 0, 1);
                const h = hf.get(x, z);
                const sand: f32 = if (h < 1.5) std.math.clamp((1.5 - h) * 0.4, 0, 0.55) else 0;
                const grass = std.math.clamp(1.0 - rock - sand, 0, 1);
                const dirt = grass * 0.22 * (1.0 - cliff);
                self.set(x, z, .{ grass - dirt, rock, sand, dirt });
                self.normalizeAt(x, z);
            }
        }
    }

    pub fn paint(self: *SplatMap, x: u32, z: u32, layer: u2, amount: f32) void {
        const i = self.index(x, z);
        const li: usize = layer;
        self.weights[i][li] = std.math.clamp(self.weights[i][li] + amount, 0, 1);
        self.normalizeAt(x, z);
    }
};

test "splat normalize" {
    const allocator = std.testing.allocator;
    var s = try SplatMap.init(allocator, 2);
    defer s.deinit();
    s.set(0, 0, .{ 2, 2, 0, 0 });
    s.normalizeAt(0, 0);
    const w = s.get(0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), w[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), w[1], 1e-5);
}

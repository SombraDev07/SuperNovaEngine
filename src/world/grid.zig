const std = @import("std");
const chunk = @import("chunk.zig");
const ChunkCoord = chunk.ChunkCoord;
const LodBand = chunk.LodBand;

/// Enumerate chunk coords in a Chebyshev ring (inclusive radius) around `center`.
pub fn forEachInRadius(
    center: ChunkCoord,
    radius: u32,
    context: anytype,
    comptime onChunk: fn (@TypeOf(context), ChunkCoord, u32) void,
) void {
    const r: i32 = @intCast(radius);
    var z: i32 = center.z - r;
    while (z <= center.z + r) : (z += 1) {
        var x: i32 = center.x - r;
        while (x <= center.x + r) : (x += 1) {
            const c = ChunkCoord{ .x = x, .z = z };
            const dist = ChunkCoord.chebyshev(center, c);
            if (dist <= radius) onChunk(context, c, dist);
        }
    }
}

/// Dagor-style optima: lower = higher priority (load first).
/// LOD0 beats LOD2; within band, closer chunks win.
pub fn optima(dist: u32, lod: LodBand) f32 {
    return @as(f32, @floatFromInt(dist)) * 3.0 + @as(f32, @floatFromInt(@intFromEnum(lod)));
}

pub const Candidate = struct {
    coord: ChunkCoord,
    dist: u32,
    lod: LodBand,
    priority: f32,

    pub fn lessThan(_: void, a: Candidate, b: Candidate) bool {
        return a.priority < b.priority;
    }
};

test "radius covers center" {
    var count: usize = 0;
    const Ctx = struct {
        n: *usize,
        fn on(self: @This(), _: ChunkCoord, _: u32) void {
            self.n.* += 1;
        }
    };
    forEachInRadius(.{ .x = 0, .z = 0 }, 1, Ctx{ .n = &count }, Ctx.on);
    try std.testing.expectEqual(@as(usize, 9), count);
}

test "optima prefers near lod0" {
    const a = optima(0, .lod0);
    const b = optima(0, .lod2);
    const c = optima(5, .lod0);
    try std.testing.expect(a < b);
    try std.testing.expect(a < c);
}

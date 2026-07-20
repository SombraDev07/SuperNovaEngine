const std = @import("std");

/// Integer chunk coordinate on the XZ world plane (ROADMAP §3.1).
pub const ChunkCoord = struct {
    x: i32 = 0,
    z: i32 = 0,

    pub fn eql(a: ChunkCoord, b: ChunkCoord) bool {
        return a.x == b.x and a.z == b.z;
    }

    pub fn hash(self: ChunkCoord) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&self.x));
        h.update(std.mem.asBytes(&self.z));
        return h.final();
    }

    pub fn fromWorld(world_x: f32, world_z: f32, chunk_size: f32) ChunkCoord {
        std.debug.assert(chunk_size > 0);
        return .{
            .x = @intFromFloat(@floor(world_x / chunk_size)),
            .z = @intFromFloat(@floor(world_z / chunk_size)),
        };
    }

    pub fn centerWorld(self: ChunkCoord, chunk_size: f32) [2]f32 {
        return .{
            (@as(f32, @floatFromInt(self.x)) + 0.5) * chunk_size,
            (@as(f32, @floatFromInt(self.z)) + 0.5) * chunk_size,
        };
    }

    /// Chebyshev distance (square rings) — natural for chunk grids.
    pub fn chebyshev(a: ChunkCoord, b: ChunkCoord) u32 {
        const dx: u32 = @intCast(@abs(a.x - b.x));
        const dz: u32 = @intCast(@abs(a.z - b.z));
        return @max(dx, dz);
    }

    pub fn manhattan(a: ChunkCoord, b: ChunkCoord) u32 {
        const dx: u32 = @intCast(@abs(a.x - b.x));
        const dz: u32 = @intCast(@abs(a.z - b.z));
        return dx + dz;
    }
};

/// Streaming LOD band (priority: lod0 > lod1 > lod2).
pub const LodBand = enum(u8) {
    lod0 = 0,
    lod1 = 1,
    lod2 = 2,

    pub fn fromChebyshev(dist: u32, load_radius: u32) LodBand {
        if (load_radius == 0) return .lod0;
        const t1 = @max(load_radius / 3, 1);
        const t2 = @max((load_radius * 2) / 3, t1 + 1);
        if (dist <= t1) return .lod0;
        if (dist <= t2) return .lod1;
        return .lod2;
    }

    /// True if `self` is a finer (higher detail) band than `other`.
    pub fn isFinerThan(self: LodBand, other: LodBand) bool {
        return @intFromEnum(self) < @intFromEnum(other);
    }
};

pub const ChunkState = enum(u8) {
    empty,
    queued,
    loading,
    ready,
    unloading,
};

/// Streamed chunk payload — owns optional terrain tile (ROADMAP §3.2).
pub const ChunkPayload = struct {
    coord: ChunkCoord = .{},
    lod: LodBand = .lod2,
    height_seed: u64 = 0,
    version: u32 = 0,
    occupied: bool = false,
    /// Heap terrain; freed via `release`.
    terrain: ?*anyopaque = null,
    terrain_deinit: ?*const fn (*anyopaque) void = null,

    pub fn release(self: *ChunkPayload) void {
        if (self.terrain) |ptr| {
            if (self.terrain_deinit) |d| d(ptr);
            self.terrain = null;
            self.terrain_deinit = null;
        }
    }
};

/// Resident chunk with front (main/read) + back (worker/write) buffers.
pub const ChunkSlot = struct {
    state: ChunkState = .empty,
    lod: LodBand = .lod2,
    /// Target LOD from last schedule (Dagor getBinDumpOptima re-eval role).
    desired_lod: LodBand = .lod2,
    generation: u32 = 0,
    /// Mid-flight cancel: discard completion and unload (Dagor unloadRequested).
    unload_requested: bool = false,
    front: ChunkPayload = .{},
    back: ChunkPayload = .{},

    pub fn swapBuffers(self: *ChunkSlot) void {
        const tmp = self.front;
        self.front = self.back;
        self.back = tmp;
    }

    pub fn releaseAll(self: *ChunkSlot) void {
        self.front.release();
        self.back.release();
    }
};

test "chunk coord from world" {
    const c = ChunkCoord.fromWorld(65.0, -1.0, 64.0);
    try std.testing.expectEqual(@as(i32, 1), c.x);
    try std.testing.expectEqual(@as(i32, -1), c.z);
    try std.testing.expectEqual(@as(u32, 2), ChunkCoord.chebyshev(.{ .x = 0, .z = 0 }, .{ .x = 2, .z = -1 }));
}

test "lod bands by distance" {
    try std.testing.expect(LodBand.fromChebyshev(0, 6) == .lod0);
    try std.testing.expect(LodBand.fromChebyshev(2, 6) == .lod0);
    try std.testing.expect(LodBand.fromChebyshev(3, 6) == .lod1);
    try std.testing.expect(LodBand.fromChebyshev(5, 6) == .lod2);
}

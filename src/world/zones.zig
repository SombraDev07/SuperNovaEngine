const std = @import("std");
const chunk_mod = @import("chunk.zig");
const ChunkCoord = chunk_mod.ChunkCoord;

/// Authored load zone (Dagor StreamingSceneController::ActionSphere).
pub const ActionSphere = struct {
    center: [3]f32 = .{ 0, 0, 0 },
    load_rad: f32 = 128.0,
    unload_rad: f32 = 192.0,
    /// Optional logical dump id for tooling / future BinaryDump binding.
    dump_id: i32 = -1,
    enabled: bool = true,

    pub fn loadRad2(self: ActionSphere) f32 {
        return self.load_rad * self.load_rad;
    }

    pub fn unloadRad2(self: ActionSphere) f32 {
        return self.unload_rad * self.unload_rad;
    }

    pub fn dist2XZ(self: ActionSphere, wx: f32, wz: f32) f32 {
        const dx = wx - self.center[0];
        const dz = wz - self.center[2];
        return dx * dx + dz * dz;
    }

    pub fn shouldLoad(self: ActionSphere, wx: f32, wz: f32) bool {
        return self.enabled and self.dist2XZ(wx, wz) <= self.loadRad2();
    }

    pub fn shouldUnload(self: ActionSphere, wx: f32, wz: f32) bool {
        if (!self.enabled) return false;
        return self.dist2XZ(wx, wz) > self.unloadRad2();
    }
};

pub const ZoneSet = struct {
    allocator: std.mem.Allocator,
    spheres: std.ArrayList(ActionSphere) = .{},

    pub fn init(allocator: std.mem.Allocator) ZoneSet {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ZoneSet) void {
        self.spheres.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *ZoneSet, s: ActionSphere) !void {
        try self.spheres.append(self.allocator, s);
    }

    pub fn clear(self: *ZoneSet) void {
        self.spheres.clearRetainingCapacity();
    }

    /// Chunk should stay loaded if inside any sphere load radius OR observer Chebyshev ring.
    pub fn forceLoadChunk(self: *const ZoneSet, coord: ChunkCoord, chunk_size: f32) bool {
        const c = coord.centerWorld(chunk_size);
        for (self.spheres.items) |s| {
            if (s.shouldLoad(c[0], c[1])) return true;
        }
        return false;
    }

    /// True if any enabled sphere still wants this chunk resident (inside unload rad).
    pub fn forceKeepChunk(self: *const ZoneSet, coord: ChunkCoord, chunk_size: f32) bool {
        const c = coord.centerWorld(chunk_size);
        for (self.spheres.items) |s| {
            if (!s.enabled) continue;
            if (!s.shouldUnload(c[0], c[1])) return true;
        }
        return false;
    }

    /// Enumerate chunk coords covered by any load sphere (approx AABB of sphere).
    pub fn forEachLoadChunk(
        self: *const ZoneSet,
        chunk_size: f32,
        context: anytype,
        comptime onChunk: fn (@TypeOf(context), ChunkCoord) void,
    ) void {
        for (self.spheres.items) |s| {
            if (!s.enabled) continue;
            const r = s.load_rad;
            const min_c = ChunkCoord.fromWorld(s.center[0] - r, s.center[2] - r, chunk_size);
            const max_c = ChunkCoord.fromWorld(s.center[0] + r, s.center[2] + r, chunk_size);
            var z = min_c.z;
            while (z <= max_c.z) : (z += 1) {
                var x = min_c.x;
                while (x <= max_c.x) : (x += 1) {
                    const coord = ChunkCoord{ .x = x, .z = z };
                    if (s.shouldLoad(coord.centerWorld(chunk_size)[0], coord.centerWorld(chunk_size)[1])) {
                        onChunk(context, coord);
                    }
                }
            }
        }
    }
};

test "action sphere hysteresis" {
    const s = ActionSphere{ .center = .{ 0, 0, 0 }, .load_rad = 10, .unload_rad = 20 };
    try std.testing.expect(s.shouldLoad(0, 0));
    try std.testing.expect(!s.shouldUnload(0, 0));
    try std.testing.expect(s.shouldUnload(25, 0));
}

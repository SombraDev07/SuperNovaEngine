const std = @import("std");

pub const EntityId = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,
};

/// Lightweight entity registry placeholder.
/// Will be replaced / backed by zig-ecs (or flecs) once Zig version aligns.
pub const World = struct {
    allocator: std.mem.Allocator,
    next_id: u32 = 0,
    live: std.AutoHashMap(EntityId, void),

    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .live = std.AutoHashMap(EntityId, void).init(allocator),
        };
    }

    pub fn deinit(self: *World) void {
        self.live.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *World) void {
        self.live.clearRetainingCapacity();
    }

    pub fn createEntity(self: *World) !EntityId {
        const id: EntityId = @enumFromInt(self.next_id);
        self.next_id += 1;
        try self.live.put(id, {});
        return id;
    }

    pub fn destroyEntity(self: *World, id: EntityId) void {
        _ = self.live.remove(id);
    }

    pub fn isAlive(self: *const World, id: EntityId) bool {
        return self.live.contains(id);
    }

    pub fn entityCount(self: *const World) usize {
        return self.live.count();
    }
};

test "world entities" {
    const allocator = std.testing.allocator;
    var world = World.init(allocator);
    defer world.deinit();

    const a = try world.createEntity();
    const b = try world.createEntity();
    try std.testing.expect(world.isAlive(a));
    try std.testing.expect(world.isAlive(b));
    try std.testing.expectEqual(@as(usize, 2), world.entityCount());
    world.destroyEntity(a);
    try std.testing.expect(!world.isAlive(a));
    try std.testing.expectEqual(@as(usize, 1), world.entityCount());
}

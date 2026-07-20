const std = @import("std");
const World = @import("world.zig").World;

/// A named collection of worlds / levels. One scene is active at a time.
pub const Scene = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    world: World,
    loaded: bool = false,

    pub fn create(allocator: std.mem.Allocator, name: []const u8) !Scene {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        return .{
            .allocator = allocator,
            .name = owned_name,
            .world = World.init(allocator),
            .loaded = false,
        };
    }

    pub fn destroy(self: *Scene) void {
        self.unload();
        self.world.deinit();
        self.allocator.free(self.name);
        self.* = undefined;
    }

    pub fn load(self: *Scene) void {
        self.loaded = true;
    }

    pub fn unload(self: *Scene) void {
        if (!self.loaded) return;
        self.world.clear();
        self.loaded = false;
    }
};

test "scene lifecycle" {
    const allocator = std.testing.allocator;
    var scene = try Scene.create(allocator, "test");
    defer scene.destroy();
    scene.load();
    try std.testing.expect(scene.loaded);
    scene.unload();
    try std.testing.expect(!scene.loaded);
}

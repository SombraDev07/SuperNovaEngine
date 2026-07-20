const std = @import("std");
const ecs = @import("ecs.zig");
const World = ecs.World;
const world_stream = @import("../world/root.zig");
const log = @import("../core/log.zig");

/// Named playable scene (DagorGameScene: act / beforeDraw / drawPrepare / select lifecycle).
pub const Scene = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    world: World,
    streamer: world_stream.Streamer,
    loaded: bool = false,
    selected: bool = false,
    can_present: bool = true,
    draw_ready: bool = false,

    pub fn create(allocator: std.mem.Allocator, name: []const u8) !Scene {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        var streamer = try world_stream.Streamer.init(allocator, .{
            .dump_root = "assets/world/chunks",
            .frame_budget_usec = 5000,
            .max_gpu_ready = 48,
        });
        errdefer streamer.deinit();
        // Default authored keep-alive around origin (Dagor ActionSphere role).
        try streamer.addActionSphere(.{
            .center = .{ 0, 0, 0 },
            .load_rad = 96,
            .unload_rad = 160,
            .dump_id = 0,
        });
        var world = try World.init(allocator);
        errdefer world.deinit();
        return .{
            .allocator = allocator,
            .name = owned_name,
            .world = world,
            .streamer = streamer,
            .loaded = false,
        };
    }

    pub fn destroy(self: *Scene) void {
        self.unload();
        self.streamer.deinit();
        self.world.deinit();
        self.allocator.free(self.name);
        self.* = undefined;
    }

    pub fn load(self: *Scene) void {
        self.loaded = true;
        self.streamer.start();
        log.info(.scene, "scene '{s}' load", .{self.name});
    }

    pub fn unload(self: *Scene) void {
        if (!self.loaded) return;
        self.streamer.clearAll();
        self.world.clear();
        self.loaded = false;
        self.draw_ready = false;
        log.info(.scene, "scene '{s}' unload", .{self.name});
    }

    /// Dagor `actScene` — ECS US_ACT + streamer.
    pub fn act(self: *Scene, observer_pos: [3]f32, dt: f64) void {
        if (!self.loaded) return;
        self.world.update(.act, dt);
        self.streamer.tick(observer_pos, dt);
    }

    /// Dagor `beforeDrawScene` — ECS US_BEFORE_RENDER.
    pub fn beforeDrawScene(self: *Scene, realtime_usec: i64, gametime_sec: f32) void {
        _ = realtime_usec;
        if (!self.loaded) return;
        self.world.update(.before_render, gametime_sec);
        self.draw_ready = true;
    }

    pub fn drawPrepare(self: *Scene) void {
        if (!self.loaded) return;
        self.world.update(.render, 0);
        self.draw_ready = true;
    }

    pub fn canPresentAndReset(self: *const Scene) bool {
        return self.loaded and self.can_present;
    }

    pub fn sceneSelected(self: *Scene, prev: ?*Scene) void {
        self.selected = true;
        const prev_name = if (prev) |p| p.name else "<null>";
        log.info(.scene, "scene '{s}' selected (prev={s})", .{ self.name, prev_name });
    }

    pub fn sceneDeselected(self: *Scene, next: ?*Scene) void {
        self.selected = false;
        self.draw_ready = false;
        const next_name = if (next) |n| n.name else "<null>";
        log.info(.scene, "scene '{s}' deselected (next={s})", .{ self.name, next_name });
    }
};

test "scene lifecycle act ecs" {
    const allocator = std.testing.allocator;
    var scene = try Scene.create(allocator, "test");
    defer scene.destroy();
    scene.load();
    try std.testing.expect(scene.loaded);
    _ = try scene.world.createEntitySync("static_marker", .{});
    scene.act(.{ 0, 0, 0 }, 1.0 / 60.0);
    scene.beforeDrawScene(16000, 1.0 / 60.0);
    scene.drawPrepare();
    scene.unload();
    try std.testing.expect(!scene.loaded);
}

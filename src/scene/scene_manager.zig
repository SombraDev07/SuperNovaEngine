const std = @import("std");
const Scene = @import("scene.zig").Scene;
const log = @import("../core/log.zig");

/// Primary + secondary scene select (Dagor `dagor_select_game_scene` / secondary / swap).
pub const SceneManager = struct {
    primary: ?*Scene = null,
    secondary: ?*Scene = null,
    /// True while between deselect and select (Dagor NULL-during-switch).
    switching: bool = false,

    pub fn init() SceneManager {
        return .{};
    }

    pub fn current(self: *const SceneManager) ?*Scene {
        if (self.switching) return null;
        return self.primary;
    }

    pub fn getSecondary(self: *const SceneManager) ?*Scene {
        return self.secondary;
    }

    /// Safe switch: deselect → NULL → select (reentrancy: mid-switch primary is null).
    pub fn select(self: *SceneManager, next: ?*Scene) void {
        if (self.primary == next) return;
        const prev = self.primary;
        self.switching = true;
        self.primary = null;
        if (prev) |p| p.sceneDeselected(next);
        if (next) |n| n.sceneSelected(prev);
        self.primary = next;
        self.switching = false;
        if (next) |n| {
            log.info(.scene, "selected primary '{s}'", .{n.name});
        } else {
            log.info(.scene, "selected primary <null>", .{});
        }
    }

    pub fn selectSecondary(self: *SceneManager, next: ?*Scene) void {
        if (self.secondary == next) return;
        const prev = self.secondary;
        if (prev) |p| p.sceneDeselected(next);
        if (next) |n| n.sceneSelected(prev);
        self.secondary = next;
        if (next) |n| {
            log.info(.scene, "selected secondary '{s}'", .{n.name});
        } else {
            log.info(.scene, "selected secondary <null>", .{});
        }
    }

    pub fn swap(self: *SceneManager) void {
        const a = self.primary;
        const b = self.secondary;
        self.primary = b;
        self.secondary = a;
        log.info(.scene, "swapped primary/secondary", .{});
    }

    pub fn actAll(self: *SceneManager, observer_pos: [3]f32, dt: f64) void {
        if (self.current()) |s| s.act(observer_pos, dt);
        if (self.secondary) |s| s.act(observer_pos, dt);
    }

    pub fn beforeDrawAll(self: *SceneManager, realtime_usec: i64, gametime_sec: f32) void {
        if (self.current()) |s| s.beforeDrawScene(realtime_usec, gametime_sec);
        if (self.secondary) |s| s.beforeDrawScene(realtime_usec, gametime_sec);
    }

    pub fn drawPrepareAll(self: *SceneManager) void {
        if (self.current()) |s| s.drawPrepare();
        if (self.secondary) |s| s.drawPrepare();
    }

    pub fn canPresent(self: *const SceneManager) bool {
        const s = self.current() orelse return false;
        return s.canPresentAndReset();
    }
};

test "scene manager select null-during-switch" {
    const allocator = std.testing.allocator;
    var a = try Scene.create(allocator, "a");
    defer a.destroy();
    var b = try Scene.create(allocator, "b");
    defer b.destroy();
    a.load();
    b.load();

    var mgr = SceneManager.init();
    mgr.select(&a);
    try std.testing.expect(mgr.current() == &a);
    mgr.selectSecondary(&b);
    try std.testing.expect(mgr.getSecondary() == &b);
    mgr.actAll(.{ 0, 0, 0 }, 1.0 / 60.0);
    mgr.swap();
    try std.testing.expect(mgr.current() == &b);
    try std.testing.expect(mgr.getSecondary() == &a);
    mgr.select(null);
    try std.testing.expect(mgr.current() == null);
}

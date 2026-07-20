const std = @import("std");
const Heightfield = @import("heightfield.zig").Heightfield;
const SplatMap = @import("splat.zig").SplatMap;

/// Runtime terrain brushes (Dagor HeightmapLand / Terraform role).
pub const Brush = struct {
    radius: f32 = 8.0,
    strength: f32 = 1.0,
    /// Soft falloff exponent.
    falloff: f32 = 2.0,
};

/// Undo stack entry (height snapshot for dirty rect).
pub const UndoEntry = struct {
    allocator: std.mem.Allocator,
    min_x: u32,
    min_z: u32,
    max_x: u32,
    max_z: u32,
    heights: []f32,
    splat: ?[][4]f32 = null,

    pub fn deinit(self: *UndoEntry) void {
        self.allocator.free(self.heights);
        if (self.splat) |s| self.allocator.free(s);
        self.* = undefined;
    }
};

pub const EditorSession = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayList(UndoEntry) = .{},
    redo_stack: std.ArrayList(UndoEntry) = .{},
    max_undo: usize = 32,

    pub fn init(allocator: std.mem.Allocator) EditorSession {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EditorSession) void {
        for (self.stack.items) |*e| e.deinit();
        self.stack.deinit(self.allocator);
        for (self.redo_stack.items) |*e| e.deinit();
        self.redo_stack.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn pushUndo(self: *EditorSession, hf: *const Heightfield, splat: ?*const SplatMap) !void {
        if (!hf.dirty_valid) return;
        // New edit invalidates redo.
        for (self.redo_stack.items) |*e| e.deinit();
        self.redo_stack.clearRetainingCapacity();
        const x0 = hf.dirty_min_x;
        const z0 = hf.dirty_min_z;
        const x1 = hf.dirty_max_x;
        const z1 = hf.dirty_max_z;
        const w = x1 - x0 + 1;
        const h = z1 - z0 + 1;
        var heights = try self.allocator.alloc(f32, w * h);
        errdefer self.allocator.free(heights);
        var zi: u32 = 0;
        while (zi < h) : (zi += 1) {
            var xi: u32 = 0;
            while (xi < w) : (xi += 1) {
                heights[zi * w + xi] = hf.get(x0 + xi, z0 + zi);
            }
        }
        var splat_copy: ?[][4]f32 = null;
        if (splat) |s| {
            var sw = try self.allocator.alloc([4]f32, w * h);
            zi = 0;
            while (zi < h) : (zi += 1) {
                var xi: u32 = 0;
                while (xi < w) : (xi += 1) {
                    sw[zi * w + xi] = s.get(x0 + xi, z0 + zi);
                }
            }
            splat_copy = sw;
        }
        if (self.stack.items.len >= self.max_undo) {
            var old = self.stack.orderedRemove(0);
            old.deinit();
        }
        try self.stack.append(self.allocator, .{
            .allocator = self.allocator,
            .min_x = x0,
            .min_z = z0,
            .max_x = x1,
            .max_z = z1,
            .heights = heights,
            .splat = splat_copy,
        });
    }

    pub fn undo(self: *EditorSession, hf: *Heightfield, splat: ?*SplatMap) bool {
        if (self.stack.items.len == 0) return false;
        var e = self.stack.pop().?;
        defer e.deinit();
        // Capture current state into redo before restore.
        hf.markDirtySample(e.min_x, e.min_z);
        hf.markDirtySample(e.max_x, e.max_z);
        self.pushRedo(hf, splat, e.min_x, e.min_z, e.max_x, e.max_z) catch {};
        applyEntry(hf, splat, &e);
        hf.rebuildCompressedDirty() catch {};
        return true;
    }

    fn pushRedo(
        self: *EditorSession,
        hf: *const Heightfield,
        splat: ?*const SplatMap,
        x0: u32,
        z0: u32,
        x1: u32,
        z1: u32,
    ) !void {
        const w = x1 - x0 + 1;
        const h = z1 - z0 + 1;
        var heights = try self.allocator.alloc(f32, w * h);
        errdefer self.allocator.free(heights);
        var zi: u32 = 0;
        while (zi < h) : (zi += 1) {
            var xi: u32 = 0;
            while (xi < w) : (xi += 1) {
                heights[zi * w + xi] = hf.get(x0 + xi, z0 + zi);
            }
        }
        var splat_copy: ?[][4]f32 = null;
        if (splat) |s| {
            var sw = try self.allocator.alloc([4]f32, w * h);
            zi = 0;
            while (zi < h) : (zi += 1) {
                var xi: u32 = 0;
                while (xi < w) : (xi += 1) {
                    sw[zi * w + xi] = s.get(x0 + xi, z0 + zi);
                }
            }
            splat_copy = sw;
        }
        if (self.redo_stack.items.len >= self.max_undo) {
            var old = self.redo_stack.orderedRemove(0);
            old.deinit();
        }
        try self.redo_stack.append(self.allocator, .{
            .allocator = self.allocator,
            .min_x = x0,
            .min_z = z0,
            .max_x = x1,
            .max_z = z1,
            .heights = heights,
            .splat = splat_copy,
        });
    }

    pub fn redo(self: *EditorSession, hf: *Heightfield, splat: ?*SplatMap) bool {
        if (self.redo_stack.items.len == 0) return false;
        var e = self.redo_stack.pop().?;
        defer e.deinit();
        applyEntry(hf, splat, &e);
        hf.rebuildCompressedDirty() catch {};
        return true;
    }

    fn applyEntry(hf: *Heightfield, splat: ?*SplatMap, e: *const UndoEntry) void {
        const w = e.max_x - e.min_x + 1;
        var zi: u32 = 0;
        while (zi <= e.max_z - e.min_z) : (zi += 1) {
            var xi: u32 = 0;
            while (xi <= e.max_x - e.min_x) : (xi += 1) {
                hf.set(e.min_x + xi, e.min_z + zi, e.heights[zi * w + xi]);
                if (splat) |s| {
                    if (e.splat) |sw| s.set(e.min_x + xi, e.min_z + zi, sw[zi * w + xi]);
                }
            }
        }
    }
};

fn forEachInBrush(
    hf: *Heightfield,
    world_x: f32,
    world_z: f32,
    brush: Brush,
    context: anytype,
    comptime onSample: fn (@TypeOf(context), x: u32, z: u32, weight: f32) void,
) void {
    const n = Heightfield.vertCount(hf.resolution);
    const sp = hf.sampleSpacing();
    const r = brush.radius;
    var z: u32 = 0;
    while (z < n) : (z += 1) {
        var x: u32 = 0;
        while (x < n) : (x += 1) {
            const wx = hf.origin_x + @as(f32, @floatFromInt(x)) * sp;
            const wz = hf.origin_z + @as(f32, @floatFromInt(z)) * sp;
            const dx = wx - world_x;
            const dz = wz - world_z;
            const dist = @sqrt(dx * dx + dz * dz);
            if (dist > r) continue;
            const t = 1.0 - dist / r;
            const w = std.math.pow(f32, t, brush.falloff) * brush.strength;
            onSample(context, x, z, w);
        }
    }
}

pub fn raise(hf: *Heightfield, world_x: f32, world_z: f32, brush: Brush) void {
    const Ctx = struct {
        hf: *Heightfield,
        fn on(ctx: @This(), x: u32, z: u32, w: f32) void {
            ctx.hf.set(x, z, ctx.hf.get(x, z) + w);
        }
    };
    forEachInBrush(hf, world_x, world_z, brush, Ctx{ .hf = hf }, Ctx.on);
}

pub fn lower(hf: *Heightfield, world_x: f32, world_z: f32, brush: Brush) void {
    var b = brush;
    b.strength = -@abs(b.strength);
    raise(hf, world_x, world_z, b);
}

pub fn smooth(hf: *Heightfield, world_x: f32, world_z: f32, brush: Brush) void {
    const tmp = hf.allocator.alloc(f32, hf.heights.len) catch return;
    defer hf.allocator.free(tmp);
    @memcpy(tmp, hf.heights);

    const Ctx = struct {
        hf: *Heightfield,
        tmp: []const f32,
        fn on(ctx: @This(), x: u32, z: u32, w: f32) void {
            const nn = Heightfield.vertCount(ctx.hf.resolution);
            var sum: f32 = 0;
            var count: f32 = 0;
            var dz: i32 = -1;
            while (dz <= 1) : (dz += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    const xx: i32 = @as(i32, @intCast(x)) + dx;
                    const zz: i32 = @as(i32, @intCast(z)) + dz;
                    if (xx < 0 or zz < 0 or xx >= nn or zz >= nn) continue;
                    sum += ctx.tmp[@as(usize, @intCast(zz)) * nn + @as(usize, @intCast(xx))];
                    count += 1;
                }
            }
            if (count <= 0) return;
            const avg = sum / count;
            const cur = ctx.hf.get(x, z);
            const t = std.math.clamp(w, 0, 1);
            ctx.hf.set(x, z, cur + (avg - cur) * t);
        }
    };
    forEachInBrush(hf, world_x, world_z, brush, Ctx{ .hf = hf, .tmp = tmp }, Ctx.on);
}

/// Flatten toward a target height (Dagor Align brush role).
pub fn flatten(hf: *Heightfield, world_x: f32, world_z: f32, brush: Brush, target_y: f32) void {
    const Ctx = struct {
        hf: *Heightfield,
        target: f32,
        fn on(ctx: @This(), x: u32, z: u32, w: f32) void {
            const cur = ctx.hf.get(x, z);
            const t = std.math.clamp(w, 0, 1);
            ctx.hf.set(x, z, cur + (ctx.target - cur) * t);
        }
    };
    forEachInBrush(hf, world_x, world_z, brush, Ctx{ .hf = hf, .target = target_y }, Ctx.on);
}

/// Hill: raise with gaussian-like falloff peak (Dagor Hill brush).
pub fn hill(hf: *Heightfield, world_x: f32, world_z: f32, brush: Brush) void {
    var b = brush;
    b.falloff = @max(b.falloff, 1.5);
    raise(hf, world_x, world_z, b);
}

pub fn paint(
    splat: *SplatMap,
    hf: *const Heightfield,
    world_x: f32,
    world_z: f32,
    brush: Brush,
    layer: u2,
) void {
    const n = Heightfield.vertCount(hf.resolution);
    const sp = hf.sampleSpacing();
    const r = brush.radius;
    var z: u32 = 0;
    while (z < n) : (z += 1) {
        var x: u32 = 0;
        while (x < n) : (x += 1) {
            const wx = hf.origin_x + @as(f32, @floatFromInt(x)) * sp;
            const wz = hf.origin_z + @as(f32, @floatFromInt(z)) * sp;
            const dx = wx - world_x;
            const dz = wz - world_z;
            const dist = @sqrt(dx * dx + dz * dz);
            if (dist > r) continue;
            const t = 1.0 - dist / r;
            const w = std.math.pow(f32, t, brush.falloff) * brush.strength;
            splat.paint(x, z, layer, w);
        }
    }
}

/// Apply brush then rebuild compressed hierarchy for dirty region.
pub fn commitEdit(hf: *Heightfield) void {
    hf.rebuildCompressedDirty() catch {};
}

test "raise increases height under brush" {
    const allocator = std.testing.allocator;
    var hf = try Heightfield.init(allocator, 8, 32);
    defer hf.deinit();
    const before = hf.sampleWorld(16, 16);
    raise(&hf, 16, 16, .{ .radius = 6, .strength = 2 });
    try std.testing.expect(hf.sampleWorld(16, 16) > before);
}

test "smooth flattens spike" {
    const allocator = std.testing.allocator;
    var hf = try Heightfield.init(allocator, 8, 32);
    defer hf.deinit();
    hf.set(4, 4, 20);
    smooth(&hf, 16, 16, .{ .radius = 8, .strength = 1 });
    try std.testing.expect(hf.get(4, 4) < 20);
}

test "undo restores height" {
    const allocator = std.testing.allocator;
    var hf = try Heightfield.init(allocator, 8, 32);
    defer hf.deinit();
    var session = EditorSession.init(allocator);
    defer session.deinit();
    raise(&hf, 16, 16, .{ .radius = 4, .strength = 3 });
    try session.pushUndo(&hf, null);
    const after = hf.sampleWorld(16, 16);
    // Mutate again then undo to previous snapshot — snapshot was AFTER first raise.
    // For true undo-before, push before edit. Simulate: capture before, raise, undo.
    session.deinit();
    session = EditorSession.init(allocator);
    hf.clearDirty();
    const before = hf.sampleWorld(16, 16);
    hf.markDirtyAll();
    try session.pushUndo(&hf, null);
    raise(&hf, 16, 16, .{ .radius = 4, .strength = 5 });
    try std.testing.expect(session.undo(&hf, null));
    try std.testing.expectApproxEqAbs(before, hf.sampleWorld(16, 16), 0.01);
    _ = after;
}

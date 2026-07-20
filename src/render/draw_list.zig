const std = @import("std");
const zm = @import("zmath");
const frustum_mod = @import("frustum.zig");
const occlusion_mod = @import("occlusion.zig");
const Streamer = @import("../world/streamer.zig").Streamer;

pub const MeshKind = enum(u8) {
    cube = 0,
    floor = 1,
};

pub const Renderable = struct {
    mesh: MeshKind = .cube,
    transform: zm.Mat = zm.identity(),
    local_min: [3]f32 = .{ -0.5, -0.5, -0.5 },
    local_max: [3]f32 = .{ 0.5, 0.5, 0.5 },
    /// metallic, roughness, ao, use_maps
    material: [4]f32 = .{ 0.15, 0.35, 1.0, 1.0 },
    color: [3]f32 = .{ 1, 1, 1 },
    cast_shadow: bool = true,
    /// Large solids rasterized into CPU Hi-Z before visibility tests.
    is_occluder: bool = false,
};

pub const DrawItem = struct {
    renderable_index: u32,
    mesh: MeshKind,
    object_to_world: zm.Mat,
    material: [4]f32,
    color: [3]f32,
    cast_shadow: bool,
};

pub const DrawList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(DrawItem) = .{},
    total_tested: u32 = 0,
    total_frustum_visible: u32 = 0,
    total_visible: u32 = 0,
    total_occlusion_culled: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) DrawList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DrawList) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *DrawList) void {
        self.items.clearRetainingCapacity();
        self.total_tested = 0;
        self.total_frustum_visible = 0;
        self.total_visible = 0;
        self.total_occlusion_culled = 0;
    }

    pub fn rebuild(
        self: *DrawList,
        renderables: []const Renderable,
        view_proj: zm.Mat,
        hiz: ?*occlusion_mod.HiZ,
    ) !void {
        self.clear();
        const fr = frustum_mod.Frustum.fromViewProj(view_proj);
        self.total_tested = @intCast(renderables.len);

        if (hiz) |z| {
            z.clear();
            for (renderables) |r| {
                if (!r.is_occluder) continue;
                const world_aabb = transformAabb(r.local_min, r.local_max, r.transform);
                z.rasterizeAabb(view_proj, world_aabb[0], world_aabb[1]);
            }
            z.buildMips();
        }

        for (renderables, 0..) |r, i| {
            const world_aabb = transformAabb(r.local_min, r.local_max, r.transform);
            if (!fr.containsAabb(world_aabb[0], world_aabb[1])) continue;
            self.total_frustum_visible += 1;

            if (hiz) |z| {
                if (!r.is_occluder and z.isOccluded(view_proj, world_aabb[0], world_aabb[1])) {
                    self.total_occlusion_culled += 1;
                    continue;
                }
            }

            try self.items.append(self.allocator, .{
                .renderable_index = @intCast(i),
                .mesh = r.mesh,
                .object_to_world = r.transform,
                .material = r.material,
                .color = r.color,
                .cast_shadow = r.cast_shadow,
            });
        }
        self.total_visible = @intCast(self.items.items.len);
    }
};

pub fn transformAabb(local_min: [3]f32, local_max: [3]f32, object_to_world: zm.Mat) [2][3]f32 {
    var min_w = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
    var max_w = [3]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
    const corners = [_][3]f32{
        .{ local_min[0], local_min[1], local_min[2] },
        .{ local_max[0], local_min[1], local_min[2] },
        .{ local_min[0], local_max[1], local_min[2] },
        .{ local_max[0], local_max[1], local_min[2] },
        .{ local_min[0], local_min[1], local_max[2] },
        .{ local_max[0], local_min[1], local_max[2] },
        .{ local_min[0], local_max[1], local_max[2] },
        .{ local_max[0], local_max[1], local_max[2] },
    };
    for (corners) |c| {
        // Row-vector convention (matches camera/renderer: mul(local_xf, view_proj)).
        const w = zm.mul(zm.f32x4(c[0], c[1], c[2], 1), object_to_world);
        min_w[0] = @min(min_w[0], w[0]);
        min_w[1] = @min(min_w[1], w[1]);
        min_w[2] = @min(min_w[2], w[2]);
        max_w[0] = @max(max_w[0], w[0]);
        max_w[1] = @max(max_w[1], w[1]);
        max_w[2] = @max(max_w[2], w[2]);
    }
    return .{ min_w, max_w };
}

pub fn buildDemoRenderables(
    out: *std.ArrayList(Renderable),
    allocator: std.mem.Allocator,
    time: f32,
    center_material: [4]f32,
    /// When set, props sit on terrain so they don't pierce hills.
    streamer: ?*const Streamer,
) !void {
    out.clearRetainingCapacity();
    const ground = struct {
        fn y(s: ?*const Streamer, wx: f32, wz: f32) f32 {
            if (s) |st| return st.sampleHeight(wx, wz) orelse 0;
            return 0;
        }
    };

    // No flat floor — real terrain is the ground plane.

    const wall_x: f32 = -3.2;
    const wall_z: f32 = 2.0;
    const wall_h = ground.y(streamer, wall_x, wall_z);
    try out.append(allocator, .{
        .mesh = .cube,
        .transform = zm.mul(zm.scaling(0.4, 3.2, 10.0), zm.translation(wall_x, wall_h + 1.6, wall_z)),
        .local_min = .{ -0.5, -0.5, -0.5 },
        .local_max = .{ 0.5, 0.5, 0.5 },
        // Solid color (w=0) — avoid shared demo UV albedo on every prop.
        .material = .{ 0.05, 0.55, 1.0, 0 },
        .color = .{ 0.42, 0.45, 0.50 },
        .cast_shadow = true,
        .is_occluder = true,
    });

    const grid: i32 = 5;
    var z: i32 = -grid;
    while (z <= grid) : (z += 1) {
        var x: i32 = -grid;
        while (x <= grid) : (x += 1) {
            const fx: f32 = @floatFromInt(x);
            const fz: f32 = @floatFromInt(z);
            const wx = fx * 2.2;
            const wz = fz * 2.2;
            const gy = ground.y(streamer, wx, wz);
            if (x == 0 and z == 0) {
                try out.append(allocator, .{
                    .mesh = .cube,
                    .transform = zm.mul(
                        zm.translation(0, gy + 0.55, 0),
                        zm.mul(zm.rotationY(time), zm.rotationX(time * 0.35)),
                    ),
                    .material = center_material,
                    .color = .{ 1, 1, 1 },
                    .cast_shadow = true,
                });
                continue;
            }
            const bob = gy + 0.5 + 0.12 * @sin(time * 1.3 + fx * 0.7 + fz * 0.5);
            try out.append(allocator, .{
                .mesh = .cube,
                .transform = zm.translation(wx, bob, wz),
                .material = .{
                    0.05 + 0.35 * @abs(fx) / @as(f32, @floatFromInt(grid)),
                    0.35 + 0.4 * @abs(fz) / @as(f32, @floatFromInt(grid)),
                    1.0,
                    0, // vertex/instance color only
                },
                .color = .{
                    0.55 + 0.08 * fx,
                    0.5,
                    0.55 + 0.08 * fz,
                },
                .cast_shadow = true,
            });
        }
    }
}

test "draw list culls far cube" {
    const allocator = std.testing.allocator;
    var list = DrawList.init(allocator);
    defer list.deinit();

    // Same VP as frustum.zig unit test (known to reject AABB near 100,100,100 with far=100).
    const vp = zm.mul(
        zm.lookAtLh(zm.f32x4(0, 0, -5, 1), zm.f32x4(0, 0, 0, 1), zm.f32x4(0, 1, 0, 0)),
        zm.perspectiveFovLh(0.6, 1.0, 0.1, 100.0),
    );
    const objs = [_]Renderable{
        .{ .transform = zm.translation(0, 0.5, 0) },
        .{ .transform = zm.translation(100.5, 100.5, 100.5) },
    };
    try list.rebuild(&objs, vp, null);
    try std.testing.expectEqual(@as(u32, 2), list.total_tested);
    try std.testing.expectEqual(@as(u32, 1), list.total_visible);
}

test "draw list occlusion culls behind wall" {
    const allocator = std.testing.allocator;
    var list = DrawList.init(allocator);
    defer list.deinit();
    var hiz: occlusion_mod.HiZ = .{};

    const vp = zm.mul(
        zm.lookAtLh(zm.f32x4(0, 1.2, -7, 1), zm.f32x4(0, 1.2, 2, 1), zm.f32x4(0, 1, 0, 0)),
        zm.perspectiveFovLh(0.7, 1.6, 0.1, 80.0),
    );
    const objs = [_]Renderable{
        .{
            .transform = zm.mul(zm.scaling(0.5, 3, 6), zm.translation(0, 1.5, 0)),
            .is_occluder = true,
        },
        .{ .transform = zm.translation(0, 1.0, 4.0) },
        .{ .transform = zm.translation(5, 1.0, 1.0) },
    };
    try list.rebuild(&objs, vp, &hiz);
    try std.testing.expect(list.total_occlusion_culled >= 1);
    try std.testing.expect(list.total_visible >= 1);
    try std.testing.expect(list.total_visible < list.total_frustum_visible);
}

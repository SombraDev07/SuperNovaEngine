const std = @import("std");
const Heightfield = @import("heightfield.zig").Heightfield;

/// 3D hole volume (Dagor landMesh hole TM / ActionSphere role).
pub const HoleVolume = struct {
    kind: enum { disk, capsule, box } = .disk,
    /// World-space center (disk/box) or capsule endpoint A.
    ax: f32 = 0,
    ay: f32 = 0,
    az: f32 = 0,
    /// Capsule endpoint B / box half-extents encoded in bx,by,bz for box.
    bx: f32 = 0,
    by: f32 = 0,
    bz: f32 = 0,
    radius: f32 = 1,
    /// Vertical extent for disk (cuts surface when |y - surface| < half_height OR always for surface cut).
    half_height: f32 = 1000,
};

/// Hole / cave density field + volume list (Dagor groundHoles / lmeshHoles).
pub const HoleField = struct {
    allocator: std.mem.Allocator,
    resolution: u32,
    /// 0 = solid, 1 = fully open. Size (res+1)^2 — surface mask.
    density: []f32,
    threshold: f32 = 0.5,
    /// Explicit 3D volumes (caves/tunnels).
    volumes: std.ArrayList(HoleVolume) = .{},
    /// Spatial cells (Dagor LandMeshHolesManager cell grid role).
    cells_n: u32 = 8,
    /// Per-cell volume index lists (flattened: cell_i → list of volume indices).
    cell_lists: []std.ArrayList(u32) = &.{},
    region_min_x: f32 = 0,
    region_min_z: f32 = 0,
    region_max_x: f32 = 0,
    region_max_z: f32 = 0,
    region_valid: bool = false,

    pub fn init(allocator: std.mem.Allocator, resolution: u32) !HoleField {
        const n = resolution + 1;
        const density = try allocator.alloc(f32, n * n);
        @memset(density, 0);
        const cells_n: u32 = 8;
        const cell_lists = try allocator.alloc(std.ArrayList(u32), cells_n * cells_n);
        for (cell_lists) |*cl| cl.* = .{};
        return .{
            .allocator = allocator,
            .resolution = resolution,
            .density = density,
            .cells_n = cells_n,
            .cell_lists = cell_lists,
        };
    }

    pub fn deinit(self: *HoleField) void {
        for (self.cell_lists) |*cl| cl.deinit(self.allocator);
        self.allocator.free(self.cell_lists);
        self.volumes.deinit(self.allocator);
        self.allocator.free(self.density);
        self.* = undefined;
    }

    fn volumeBBoxXZ(v: HoleVolume) struct { min_x: f32, min_z: f32, max_x: f32, max_z: f32 } {
        return switch (v.kind) {
            .disk => .{
                .min_x = v.ax - v.radius,
                .min_z = v.az - v.radius,
                .max_x = v.ax + v.radius,
                .max_z = v.az + v.radius,
            },
            .capsule => .{
                .min_x = @min(v.ax, v.bx) - v.radius,
                .min_z = @min(v.az, v.bz) - v.radius,
                .max_x = @max(v.ax, v.bx) + v.radius,
                .max_z = @max(v.az, v.bz) + v.radius,
            },
            .box => .{
                .min_x = v.ax - v.bx,
                .min_z = v.az - v.bz,
                .max_x = v.ax + v.bx,
                .max_z = v.az + v.bz,
            },
        };
    }

    fn rebuildCells(self: *HoleField) void {
        for (self.cell_lists) |*cl| cl.clearRetainingCapacity();
        self.region_valid = false;
        if (self.volumes.items.len == 0) return;
        var min_x: f32 = std.math.floatMax(f32);
        var min_z: f32 = std.math.floatMax(f32);
        var max_x: f32 = -std.math.floatMax(f32);
        var max_z: f32 = -std.math.floatMax(f32);
        for (self.volumes.items) |v| {
            const bb = volumeBBoxXZ(v);
            min_x = @min(min_x, bb.min_x);
            min_z = @min(min_z, bb.min_z);
            max_x = @max(max_x, bb.max_x);
            max_z = @max(max_z, bb.max_z);
        }
        // Pad so single-point regions still have extent.
        if (max_x - min_x < 1) {
            min_x -= 0.5;
            max_x += 0.5;
        }
        if (max_z - min_z < 1) {
            min_z -= 0.5;
            max_z += 0.5;
        }
        self.region_min_x = min_x;
        self.region_min_z = min_z;
        self.region_max_x = max_x;
        self.region_max_z = max_z;
        self.region_valid = true;
        const inv_w = @as(f32, @floatFromInt(self.cells_n)) / (max_x - min_x);
        const inv_h = @as(f32, @floatFromInt(self.cells_n)) / (max_z - min_z);
        for (self.volumes.items, 0..) |v, vi| {
            const bb = volumeBBoxXZ(v);
            const cx0: i32 = @intFromFloat(@floor((bb.min_x - min_x) * inv_w));
            const cz0: i32 = @intFromFloat(@floor((bb.min_z - min_z) * inv_h));
            const cx1: i32 = @intFromFloat(@floor((bb.max_x - min_x) * inv_w));
            const cz1: i32 = @intFromFloat(@floor((bb.max_z - min_z) * inv_h));
            var cz = @max(cz0, 0);
            while (cz <= @min(cz1, @as(i32, @intCast(self.cells_n - 1)))) : (cz += 1) {
                var cx = @max(cx0, 0);
                while (cx <= @min(cx1, @as(i32, @intCast(self.cells_n - 1)))) : (cx += 1) {
                    const idx = @as(usize, @intCast(cz)) * self.cells_n + @as(usize, @intCast(cx));
                    self.cell_lists[idx].append(self.allocator, @intCast(vi)) catch {};
                }
            }
        }
    }

    pub fn index(self: *const HoleField, x: u32, z: u32) usize {
        const n = self.resolution + 1;
        return z * n + x;
    }

    pub fn get(self: *const HoleField, x: u32, z: u32) f32 {
        return self.density[self.index(x, z)];
    }

    pub fn set(self: *HoleField, x: u32, z: u32, d: f32) void {
        self.density[self.index(x, z)] = std.math.clamp(d, 0, 1);
    }

    pub fn isHole(self: *const HoleField, x: u32, z: u32) bool {
        return self.get(x, z) >= self.threshold;
    }

    pub fn addVolume(self: *HoleField, v: HoleVolume) !void {
        try self.volumes.append(self.allocator, v);
        self.rebuildCells();
    }

    fn volumeContains(v: HoleVolume, wx: f32, wy: f32, wz: f32) bool {
        return switch (v.kind) {
            .disk => blk: {
                const dx = wx - v.ax;
                const dz = wz - v.az;
                break :blk dx * dx + dz * dz <= v.radius * v.radius and @abs(wy - v.ay) <= v.half_height;
            },
            .capsule => blk: {
                const abx = v.bx - v.ax;
                const aby = v.by - v.ay;
                const abz = v.bz - v.az;
                const ab_len2 = @max(abx * abx + aby * aby + abz * abz, 1e-6);
                var t = ((wx - v.ax) * abx + (wy - v.ay) * aby + (wz - v.az) * abz) / ab_len2;
                t = std.math.clamp(t, 0, 1);
                const cx = v.ax + abx * t;
                const cy = v.ay + aby * t;
                const cz = v.az + abz * t;
                const dx = wx - cx;
                const dy = wy - cy;
                const dz = wz - cz;
                break :blk dx * dx + dy * dy + dz * dz <= v.radius * v.radius;
            },
            .box => @abs(wx - v.ax) <= v.bx and @abs(wy - v.ay) <= v.by and @abs(wz - v.az) <= v.bz,
        };
    }

    /// World-space 3D hole test (Dagor shape/proj role) via cell grid.
    pub fn isHoleWorld(self: *const HoleField, wx: f32, wy: f32, wz: f32) bool {
        if (!self.region_valid) return false;
        if (wx < self.region_min_x or wx > self.region_max_x or wz < self.region_min_z or wz > self.region_max_z)
            return false;
        const inv_w = @as(f32, @floatFromInt(self.cells_n)) / (self.region_max_x - self.region_min_x);
        const inv_h = @as(f32, @floatFromInt(self.cells_n)) / (self.region_max_z - self.region_min_z);
        const cx: u32 = @intFromFloat(std.math.clamp(@floor((wx - self.region_min_x) * inv_w), 0, @as(f32, @floatFromInt(self.cells_n - 1))));
        const cz: u32 = @intFromFloat(std.math.clamp(@floor((wz - self.region_min_z) * inv_h), 0, @as(f32, @floatFromInt(self.cells_n - 1))));
        const list = self.cell_lists[cz * self.cells_n + cx];
        for (list.items) |vi| {
            if (volumeContains(self.volumes.items[vi], wx, wy, wz)) return true;
        }
        return false;
    }

    /// Fast reject: any hole volume overlaps this XZ AABB? (Dagor approximateCheckBBox).
    pub fn approximateCheckBBox(self: *const HoleField, min_x: f32, min_z: f32, max_x: f32, max_z: f32) bool {
        if (!self.region_valid) return false;
        if (max_x < self.region_min_x or min_x > self.region_max_x or max_z < self.region_min_z or min_z > self.region_max_z)
            return false;
        const inv_w = @as(f32, @floatFromInt(self.cells_n)) / (self.region_max_x - self.region_min_x);
        const inv_h = @as(f32, @floatFromInt(self.cells_n)) / (self.region_max_z - self.region_min_z);
        const cx0: i32 = @intFromFloat(@floor((min_x - self.region_min_x) * inv_w));
        const cz0: i32 = @intFromFloat(@floor((min_z - self.region_min_z) * inv_h));
        const cx1: i32 = @intFromFloat(@floor((max_x - self.region_min_x) * inv_w));
        const cz1: i32 = @intFromFloat(@floor((max_z - self.region_min_z) * inv_h));
        var cz = @max(cz0, 0);
        while (cz <= @min(cz1, @as(i32, @intCast(self.cells_n - 1)))) : (cz += 1) {
            var cx = @max(cx0, 0);
            while (cx <= @min(cx1, @as(i32, @intCast(self.cells_n - 1)))) : (cx += 1) {
                if (self.cell_lists[@as(usize, @intCast(cz)) * self.cells_n + @as(usize, @intCast(cx))].items.len > 0)
                    return true;
            }
        }
        return false;
    }

    /// Projected circular hole in world XZ + optional volume registration.
    pub fn stampDisk(
        self: *HoleField,
        hf: *const Heightfield,
        world_x: f32,
        world_z: f32,
        radius: f32,
        strength: f32,
    ) void {
        const n = self.resolution + 1;
        const sp = hf.sampleSpacing();
        const surface_y = hf.sampleWorld(world_x, world_z);
        var z: u32 = 0;
        while (z < n) : (z += 1) {
            var x: u32 = 0;
            while (x < n) : (x += 1) {
                const wx = hf.origin_x + @as(f32, @floatFromInt(x)) * sp;
                const wz = hf.origin_z + @as(f32, @floatFromInt(z)) * sp;
                const dx = wx - world_x;
                const dz = wz - world_z;
                const dist = @sqrt(dx * dx + dz * dz);
                if (dist <= radius) {
                    const t = 1.0 - dist / radius;
                    const d = self.get(x, z) + strength * t * t;
                    self.set(x, z, d);
                }
            }
        }
        self.addVolume(.{
            .kind = .disk,
            .ax = world_x,
            .ay = surface_y,
            .az = world_z,
            .radius = radius,
            .half_height = radius * 2.0,
        }) catch {};
    }

    /// 3D capsule tunnel between two world points.
    pub fn stampTunnelDensity(
        self: *HoleField,
        hf: *const Heightfield,
        ax: f32,
        az: f32,
        bx: f32,
        bz: f32,
        radius: f32,
    ) void {
        const ay = hf.sampleWorld(ax, az) - radius * 0.5;
        const by = hf.sampleWorld(bx, bz) - radius * 0.5;
        const n = self.resolution + 1;
        const sp = hf.sampleSpacing();
        const abx = bx - ax;
        const abz = bz - az;
        const ab_len2 = @max(abx * abx + abz * abz, 1e-6);
        var z: u32 = 0;
        while (z < n) : (z += 1) {
            var x: u32 = 0;
            while (x < n) : (x += 1) {
                const wx = hf.origin_x + @as(f32, @floatFromInt(x)) * sp;
                const wz = hf.origin_z + @as(f32, @floatFromInt(z)) * sp;
                var t = ((wx - ax) * abx + (wz - az) * abz) / ab_len2;
                t = std.math.clamp(t, 0, 1);
                const cx = ax + abx * t;
                const cz = az + abz * t;
                const dx = wx - cx;
                const dz = wz - cz;
                const dist = @sqrt(dx * dx + dz * dz);
                if (dist < radius) {
                    self.set(x, z, @max(self.get(x, z), 1.0 - dist / radius));
                }
            }
        }
        self.addVolume(.{
            .kind = .capsule,
            .ax = ax,
            .ay = ay,
            .az = az,
            .bx = bx,
            .by = by,
            .bz = bz,
            .radius = radius,
        }) catch {};
    }

    /// Bake density + volumes into RGBA8 mask for GPU (R=density, G=1 if any volume covers sample).
    pub fn bakeGpuMask(self: *const HoleField, hf: *const Heightfield, out_rgba: []u8) void {
        const n = self.resolution + 1;
        std.debug.assert(out_rgba.len >= n * n * 4);
        const sp = hf.sampleSpacing();
        var z: u32 = 0;
        while (z < n) : (z += 1) {
            var x: u32 = 0;
            while (x < n) : (x += 1) {
                const i = (z * n + x) * 4;
                const d = self.get(x, z);
                const wx = hf.origin_x + @as(f32, @floatFromInt(x)) * sp;
                const wz = hf.origin_z + @as(f32, @floatFromInt(z)) * sp;
                const wy = hf.get(x, z);
                const vol = self.isHoleWorld(wx, wy, wz);
                out_rgba[i + 0] = @intFromFloat(std.math.clamp(d, 0, 1) * 255.0);
                out_rgba[i + 1] = if (vol) 255 else 0;
                out_rgba[i + 2] = 0;
                out_rgba[i + 3] = 255;
            }
        }
    }
};

test "hole disk marks center" {
    const allocator = std.testing.allocator;
    var hf = try Heightfield.init(allocator, 8, 32);
    defer hf.deinit();
    hf.origin_x = 0;
    hf.origin_z = 0;
    var holes = try HoleField.init(allocator, 8);
    defer holes.deinit();
    holes.stampDisk(&hf, 16, 16, 6, 1.0);
    try std.testing.expect(holes.isHole(4, 4));
    try std.testing.expect(!holes.isHole(0, 0));
    try std.testing.expect(holes.volumes.items.len == 1);
}

test "capsule volume hits interior" {
    const allocator = std.testing.allocator;
    var holes = try HoleField.init(allocator, 4);
    defer holes.deinit();
    try holes.addVolume(.{
        .kind = .capsule,
        .ax = 0,
        .ay = 0,
        .az = 0,
        .bx = 10,
        .by = 0,
        .bz = 0,
        .radius = 2,
    });
    try std.testing.expect(holes.isHoleWorld(5, 0, 0));
    try std.testing.expect(!holes.isHoleWorld(5, 0, 5));
}

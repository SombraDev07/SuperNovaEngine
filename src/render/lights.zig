const std = @import("std");
const zm = @import("zmath");
const zgpu = @import("zgpu");
const ibl = @import("ibl.zig");
const shadow = @import("shadow.zig");

pub const max_lights: usize = 32;
pub const tile_count_x: u32 = 24;
pub const tile_count_y: u32 = 14;
pub const tile_count_z: u32 = 16;
pub const tile_count: u32 = tile_count_x * tile_count_y * tile_count_z;

pub const Kind = enum(u32) {
    directional = 0,
    point = 1,
    spot = 2,
};

pub const Light = struct {
    kind: Kind = .directional,
    position_or_direction: [3]f32 = .{ 0, 1, 0 },
    spot_direction: [3]f32 = .{ 0, -1, 0 },
    color: [3]f32 = .{ 1, 1, 1 },
    intensity: f32 = 1.0,
    range: f32 = 10.0,
    inner_cone: f32 = std.math.degreesToRadians(15.0),
    outer_cone: f32 = std.math.degreesToRadians(25.0),
};

pub const GpuLight = extern struct {
    pos_type: [4]f32,
    color: [4]f32,
    dir_range: [4]f32,
    cone: [4]f32,
};

pub const FrameUniforms = extern struct {
    inv_view_proj: zm.Mat,
    view: zm.Mat,
    camera_pos: [4]f32,
    ambient: [4]f32,
    /// x = light count, y = tiles_x, z = tiles_y, w = tiles_z
    counts: [4]f32,
    /// x = env max mip, y = IBL intensity, z = camera near, w = camera far
    ibl_params: [4]f32,
    /// x = directional shadow light index (-1 none), y = first point slot (compat), zw unused
    shadow_light_ids: [4]f32,
    /// Light indices for omni atlas slots 0..3 (-1 = empty).
    point_shadow_slots: [4]f32,
    /// Omni slots 4..7.
    point_shadow_slots_hi: [4]f32,
    /// Light indices for spot atlas slots (-1 = empty). First 4 only (vec4).
    spot_shadow_slots: [4]f32,
    sh: ibl.ShIrradiance,
    lights: [max_lights]GpuLight,
    shadow_vp: [shadow.cascade_count]zm.Mat,
    spot_shadow_vp: [shadow.max_spot_shadow_slots]zm.Mat,
    cascade_splits: [4]f32,
    cascade_radii: [4]f32,
    /// x = depth bias, y = normal bias, z = PCSS light size (world), w = dir shadow enabled
    shadow_params: [4]f32,
    /// x = point bias, y = point soft scale, z = point enabled, w = contact shadow length
    point_shadow_params: [4]f32,
    /// Ortho depth range per cascade (PCSS).
    cascade_z_ranges: [4]f32,
    /// x = last-cascade fade start (view z), y = fade end, z = cascade dither scale, w = unused
    shadow_fade: [4]f32,
};

/// One u32 bitmask per froxel (bit i → light i).
pub const TileMaskBuffer = struct {
    buffer: zgpu.BufferHandle = .{},
    masks: [tile_count]u32 = .{0} ** tile_count,

    pub fn create(gctx: *zgpu.GraphicsContext) TileMaskBuffer {
        const buffer = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .storage = true },
            .size = tile_count * @sizeOf(u32),
        });
        return .{ .buffer = buffer };
    }

    pub fn destroy(self: *TileMaskBuffer, gctx: *zgpu.GraphicsContext) void {
        if (gctx.isResourceValid(self.buffer)) gctx.destroyResource(self.buffer);
        self.* = .{};
    }

    pub fn rebuild(
        self: *TileMaskBuffer,
        gctx: *zgpu.GraphicsContext,
        light_list: []const Light,
        view_proj: zm.Mat,
        view: zm.Mat,
        cam_near: f32,
        cam_far: f32,
    ) void {
        @memset(&self.masks, 0);
        const n = @min(light_list.len, max_lights);
        for (0..n) |li| {
            const light = light_list[li];
            const bit: u32 = @as(u32, 1) << @intCast(li);
            switch (light.kind) {
                .directional => {
                    for (&self.masks) |*m| m.* |= bit;
                },
                .point => {
                    markSphereFroxels(
                        &self.masks,
                        view_proj,
                        view,
                        light.position_or_direction,
                        light.range,
                        cam_near,
                        cam_far,
                        bit,
                    );
                },
                .spot => {
                    // Tighter froxel radius ≈ range * sin(outer) (Dagor spot cluster approx).
                    const cone_r = light.range * @sin(@min(light.outer_cone, std.math.pi * 0.49));
                    markSphereFroxels(
                        &self.masks,
                        view_proj,
                        view,
                        light.position_or_direction,
                        @max(cone_r, light.range * 0.35),
                        cam_near,
                        cam_far,
                        bit,
                    );
                },
            }
        }
        gctx.queue.writeBuffer(gctx.lookupResource(self.buffer).?, 0, u32, self.masks[0..]);
    }
};

fn markSphereFroxels(
    masks: *[tile_count]u32,
    view_proj: zm.Mat,
    view: zm.Mat,
    center: [3]f32,
    range: f32,
    cam_near: f32,
    cam_far: f32,
    bit: u32,
) void {
    var min_u: f32 = 1;
    var max_u: f32 = 0;
    var min_v: f32 = 1;
    var max_v: f32 = 0;
    var any = false;

    const offsets = [_][3]f32{
        .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ -1, 1, -1 }, .{ 1, 1, -1 },
        .{ -1, -1, 1 },  .{ 1, -1, 1 },  .{ -1, 1, 1 },  .{ 1, 1, 1 },
    };
    for (offsets) |o| {
        const p = zm.f32x4(
            center[0] + o[0] * range,
            center[1] + o[1] * range,
            center[2] + o[2] * range,
            1,
        );
        const clip = zm.mul(view_proj, p);
        if (clip[3] <= 0.0001) continue;
        const ndc_x = clip[0] / clip[3];
        const ndc_y = clip[1] / clip[3];
        const u = ndc_x * 0.5 + 0.5;
        const v = 0.5 - ndc_y * 0.5;
        min_u = @min(min_u, u);
        max_u = @max(max_u, u);
        min_v = @min(min_v, v);
        max_v = @max(max_v, v);
        any = true;
    }

    // View-space Z extent of the sphere (LH: +Z forward).
    const center_v = zm.mul(view, zm.f32x4(center[0], center[1], center[2], 1));
    const z0 = center_v[2] - range;
    const z1 = center_v[2] + range;

    if (!any) {
        for (masks) |*m| m.* |= bit;
        return;
    }

    min_u = std.math.clamp(min_u, 0, 1);
    max_u = std.math.clamp(max_u, 0, 1);
    min_v = std.math.clamp(min_v, 0, 1);
    max_v = std.math.clamp(max_v, 0, 1);

    const x0: u32 = @intFromFloat(@floor(min_u * @as(f32, @floatFromInt(tile_count_x))));
    const x1: u32 = @min(@as(u32, @intFromFloat(@floor(max_u * @as(f32, @floatFromInt(tile_count_x))))), tile_count_x - 1);
    const y0: u32 = @intFromFloat(@floor(min_v * @as(f32, @floatFromInt(tile_count_y))));
    const y1: u32 = @min(@as(u32, @intFromFloat(@floor(max_v * @as(f32, @floatFromInt(tile_count_y))))), tile_count_y - 1);
    const zi0 = depthSlice(z0, cam_near, cam_far);
    const zi1 = depthSlice(z1, cam_near, cam_far);
    const z_lo = @min(zi0, zi1);
    const z_hi = @max(zi0, zi1);

    var tz = z_lo;
    while (tz <= z_hi) : (tz += 1) {
        var ty = y0;
        while (ty <= y1) : (ty += 1) {
            var tx = x0;
            while (tx <= x1) : (tx += 1) {
                const idx = tz * (tile_count_x * tile_count_y) + ty * tile_count_x + tx;
                masks[idx] |= bit;
            }
        }
    }
}

fn depthSlice(view_z: f32, cam_near: f32, cam_far: f32) u32 {
    const z = std.math.clamp(view_z, cam_near, cam_far);
    // Logarithmic split (closer slices denser).
    const t = std.math.log(f32, std.math.e, z / cam_near) / std.math.log(f32, std.math.e, cam_far / cam_near);
    const s = std.math.clamp(t, 0, 0.9999) * @as(f32, @floatFromInt(tile_count_z));
    return @intFromFloat(@floor(s));
}

pub fn pack(light: Light) GpuLight {
    var pos = light.position_or_direction;
    var spot_dir = light.spot_direction;
    if (light.kind == .directional) {
        const len = @sqrt(pos[0] * pos[0] + pos[1] * pos[1] + pos[2] * pos[2]);
        if (len > 0.0001) {
            pos[0] /= len;
            pos[1] /= len;
            pos[2] /= len;
        }
    } else if (light.kind == .spot) {
        const len = @sqrt(spot_dir[0] * spot_dir[0] + spot_dir[1] * spot_dir[1] + spot_dir[2] * spot_dir[2]);
        if (len > 0.0001) {
            spot_dir[0] /= len;
            spot_dir[1] /= len;
            spot_dir[2] /= len;
        }
    }
    const kind_f: f32 = @floatFromInt(@intFromEnum(light.kind));
    return .{
        .pos_type = .{ pos[0], pos[1], pos[2], kind_f },
        .color = .{ light.color[0], light.color[1], light.color[2], light.intensity },
        .dir_range = .{ spot_dir[0], spot_dir[1], spot_dir[2], light.range },
        .cone = .{ @cos(light.inner_cone), @cos(light.outer_cone), 0, 0 },
    };
}

pub const ShadowIds = struct {
    dir: i32,
    point: i32,
    point_slots: [8]i32,
    spot_slots: [4]i32,
};

fn findShadowLights(light_list: []const Light) ShadowIds {
    var dir: i32 = -1;
    var point: i32 = -1;
    var point_slots: [8]i32 = .{-1} ** 8;
    var spot_slots: [4]i32 = .{-1, -1, -1, -1};
    var point_slot: usize = 0;
    var spot_slot: usize = 0;
    const n = @min(light_list.len, max_lights);
    for (0..n) |i| {
        switch (light_list[i].kind) {
            .directional => if (dir < 0) {
                dir = @intCast(i);
            },
            .point => {
                if (point < 0) point = @intCast(i);
                if (point_slot < point_slots.len and point_slot < shadow.max_point_shadow_slots) {
                    point_slots[point_slot] = @intCast(i);
                    point_slot += 1;
                }
            },
            .spot => {
                if (spot_slot < spot_slots.len and spot_slot < shadow.max_spot_shadow_slots) {
                    spot_slots[spot_slot] = @intCast(i);
                    spot_slot += 1;
                }
            },
        }
    }
    return .{ .dir = dir, .point = point, .point_slots = point_slots, .spot_slots = spot_slots };
}

pub fn packFrame(
    inv_view_proj: zm.Mat,
    view: zm.Mat,
    camera_pos: zm.Vec,
    ambient: [3]f32,
    light_list: []const Light,
    sh: ibl.ShIrradiance,
    max_mip: f32,
    ibl_intensity: f32,
    cam_near: f32,
    cam_far: f32,
    cascades: shadow.CascadeData,
    shadow_params: [4]f32,
    point_shadow_params: [4]f32,
    spot_vps: *const [shadow.max_spot_shadow_slots]zm.Mat,
    shadow_fade: [4]f32,
) FrameUniforms {
    const ids = findShadowLights(light_list);
    var out: FrameUniforms = .{
        .inv_view_proj = zm.transpose(inv_view_proj),
        .view = zm.transpose(view),
        .camera_pos = .{ camera_pos[0], camera_pos[1], camera_pos[2], 1 },
        .ambient = .{ ambient[0], ambient[1], ambient[2], 0 },
        .counts = .{
            @floatFromInt(@min(light_list.len, max_lights)),
            @floatFromInt(tile_count_x),
            @floatFromInt(tile_count_y),
            @floatFromInt(tile_count_z),
        },
        .ibl_params = .{ max_mip, ibl_intensity, cam_near, cam_far },
        .shadow_light_ids = .{ @floatFromInt(ids.dir), @floatFromInt(ids.point), 0, 0 },
        .point_shadow_slots = .{
            @floatFromInt(ids.point_slots[0]),
            @floatFromInt(ids.point_slots[1]),
            @floatFromInt(ids.point_slots[2]),
            @floatFromInt(ids.point_slots[3]),
        },
        .point_shadow_slots_hi = .{
            @floatFromInt(ids.point_slots[4]),
            @floatFromInt(ids.point_slots[5]),
            @floatFromInt(ids.point_slots[6]),
            @floatFromInt(ids.point_slots[7]),
        },
        .spot_shadow_slots = .{
            @floatFromInt(ids.spot_slots[0]),
            @floatFromInt(ids.spot_slots[1]),
            @floatFromInt(ids.spot_slots[2]),
            @floatFromInt(ids.spot_slots[3]),
        },
        .sh = sh,
        .lights = undefined,
        .shadow_vp = undefined,
        .spot_shadow_vp = undefined,
        .cascade_splits = cascades.splits,
        .cascade_radii = cascades.radii,
        .shadow_params = shadow_params,
        .point_shadow_params = point_shadow_params,
        .cascade_z_ranges = cascades.z_ranges,
        .shadow_fade = shadow_fade,
    };
    @memset(std.mem.asBytes(&out.lights), 0);

    const n = @min(light_list.len, max_lights);
    for (0..n) |i| {
        out.lights[i] = pack(light_list[i]);
    }
    for (0..shadow.cascade_count) |i| {
        out.shadow_vp[i] = zm.transpose(cascades.light_vp[i]);
    }
    for (0..shadow.max_spot_shadow_slots) |i| {
        out.spot_shadow_vp[i] = zm.transpose(spot_vps[i]);
    }
    return out;
}

test "pack directional" {
    const g = pack(.{
        .kind = .directional,
        .position_or_direction = .{ 0, 1, 0 },
        .intensity = 2.0,
    });
    try std.testing.expectEqual(@as(f32, 0), g.pos_type[3]);
    try std.testing.expectEqual(@as(f32, 2), g.color[3]);
}

test "depth slice in range" {
    const s = depthSlice(1.0, 0.1, 100.0);
    try std.testing.expect(s < tile_count_z);
}

const std = @import("std");
const zm = @import("zmath");
const ibl = @import("ibl.zig");
const shadow = @import("shadow.zig");

pub const max_lights: usize = 8;

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
    camera_pos: [4]f32,
    ambient: [4]f32,
    /// x = light count
    counts: [4]f32,
    /// x = env max mip, y = IBL intensity
    ibl_params: [4]f32,
    sh: ibl.ShIrradiance,
    lights: [max_lights]GpuLight,
    shadow_vp: [shadow.cascade_count]zm.Mat,
    cascade_splits: [4]f32,
    /// x = depth bias, y = normal bias, z = PCSS light size, w = dir shadow enabled
    shadow_params: [4]f32,
    /// x = point bias, y = point soft scale, z = point enabled, w = unused
    point_shadow_params: [4]f32,
};

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

pub fn packFrame(
    camera_pos: zm.Vec,
    ambient: [3]f32,
    light_list: []const Light,
    sh: ibl.ShIrradiance,
    max_mip: f32,
    ibl_intensity: f32,
    cascades: shadow.CascadeData,
    shadow_params: [4]f32,
    point_shadow_params: [4]f32,
) FrameUniforms {
    var out: FrameUniforms = .{
        .camera_pos = .{ camera_pos[0], camera_pos[1], camera_pos[2], 1 },
        .ambient = .{ ambient[0], ambient[1], ambient[2], 0 },
        .counts = .{ @floatFromInt(@min(light_list.len, max_lights)), 0, 0, 0 },
        .ibl_params = .{ max_mip, ibl_intensity, 0, 0 },
        .sh = sh,
        .lights = undefined,
        .shadow_vp = undefined,
        .cascade_splits = cascades.splits,
        .shadow_params = shadow_params,
        .point_shadow_params = point_shadow_params,
    };
    @memset(std.mem.asBytes(&out.lights), 0);

    const n = @min(light_list.len, max_lights);
    for (0..n) |i| {
        out.lights[i] = pack(light_list[i]);
    }
    for (0..shadow.cascade_count) |i| {
        out.shadow_vp[i] = zm.transpose(cascades.light_vp[i]);
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

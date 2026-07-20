const std = @import("std");
const zgpu = @import("zgpu");
const zm = @import("zmath");
const Camera = @import("camera.zig").Camera;

pub const cascade_count: u32 = 4;
pub const map_size: u32 = 1024;
pub const point_map_size: u32 = 512;
pub const point_face_count: u32 = 6;

pub const DepthUniforms = extern struct {
    object_to_clip: zm.Mat,
};

pub const PointDepthUniforms = extern struct {
    object_to_clip: zm.Mat,
    object_to_world: zm.Mat,
    /// xyz = light position, w = range
    light_pos_range: [4]f32,
};

pub const CascadeData = struct {
    light_vp: [cascade_count]zm.Mat,
    /// Far distance of each cascade (view-space / camera-distance metric).
    splits: [4]f32,
};

pub const Maps = struct {
    texture: zgpu.TextureHandle = .{},
    array_view: zgpu.TextureViewHandle = .{},
    layer_views: [cascade_count]zgpu.TextureViewHandle = [_]zgpu.TextureViewHandle{.{}} ** cascade_count,
    comparison_sampler: zgpu.SamplerHandle = .{},
    /// Non-comparison sampler to read raw depth (PCSS blocker search).
    depth_sampler: zgpu.SamplerHandle = .{},

    pub fn create(gctx: *zgpu.GraphicsContext) Maps {
        const texture = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{
                .width = map_size,
                .height = map_size,
                .depth_or_array_layers = cascade_count,
            },
            .format = .depth32_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });

        const array_view = gctx.createTextureView(texture, .{
            .dimension = .tvdim_2d_array,
            .base_mip_level = 0,
            .mip_level_count = 1,
            .base_array_layer = 0,
            .array_layer_count = cascade_count,
            .aspect = .depth_only,
        });

        var layer_views: [cascade_count]zgpu.TextureViewHandle = undefined;
        for (0..cascade_count) |i| {
            layer_views[i] = gctx.createTextureView(texture, .{
                .dimension = .tvdim_2d,
                .base_mip_level = 0,
                .mip_level_count = 1,
                .base_array_layer = @intCast(i),
                .array_layer_count = 1,
                .aspect = .depth_only,
            });
        }

        const comparison_sampler = gctx.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .compare = .less,
        });

        const depth_sampler = gctx.createSampler(.{
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .mipmap_filter = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });

        return .{
            .texture = texture,
            .array_view = array_view,
            .layer_views = layer_views,
            .comparison_sampler = comparison_sampler,
            .depth_sampler = depth_sampler,
        };
    }

    pub fn destroy(self: *Maps, gctx: *zgpu.GraphicsContext) void {
        for (&self.layer_views) |*v| {
            if (gctx.isResourceValid(v.*)) gctx.releaseResource(v.*);
        }
        if (gctx.isResourceValid(self.array_view)) gctx.releaseResource(self.array_view);
        if (gctx.isResourceValid(self.texture)) gctx.destroyResource(self.texture);
        if (gctx.isResourceValid(self.comparison_sampler)) gctx.releaseResource(self.comparison_sampler);
        if (gctx.isResourceValid(self.depth_sampler)) gctx.releaseResource(self.depth_sampler);
        self.* = .{};
    }
};

/// Omnidirectional depth cubemap for one point light.
pub const PointMaps = struct {
    texture: zgpu.TextureHandle = .{},
    cube_view: zgpu.TextureViewHandle = .{},
    face_views: [point_face_count]zgpu.TextureViewHandle = [_]zgpu.TextureViewHandle{.{}} ** point_face_count,

    pub fn create(gctx: *zgpu.GraphicsContext) PointMaps {
        const texture = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{
                .width = point_map_size,
                .height = point_map_size,
                .depth_or_array_layers = point_face_count,
            },
            .format = .depth32_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });

        const cube_view = gctx.createTextureView(texture, .{
            .dimension = .tvdim_cube,
            .base_mip_level = 0,
            .mip_level_count = 1,
            .base_array_layer = 0,
            .array_layer_count = point_face_count,
            .aspect = .depth_only,
        });

        var face_views: [point_face_count]zgpu.TextureViewHandle = undefined;
        for (0..point_face_count) |i| {
            face_views[i] = gctx.createTextureView(texture, .{
                .dimension = .tvdim_2d,
                .base_mip_level = 0,
                .mip_level_count = 1,
                .base_array_layer = @intCast(i),
                .array_layer_count = 1,
                .aspect = .depth_only,
            });
        }

        return .{
            .texture = texture,
            .cube_view = cube_view,
            .face_views = face_views,
        };
    }

    pub fn destroy(self: *PointMaps, gctx: *zgpu.GraphicsContext) void {
        for (&self.face_views) |*v| {
            if (gctx.isResourceValid(v.*)) gctx.releaseResource(v.*);
        }
        if (gctx.isResourceValid(self.cube_view)) gctx.releaseResource(self.cube_view);
        if (gctx.isResourceValid(self.texture)) gctx.destroyResource(self.texture);
        self.* = .{};
    }
};

/// Six light-space view-projection matrices for a point light cubemap (WebGPU face order).
pub fn pointFaceViewProjs(light_pos: [3]f32, near: f32, range: f32) [point_face_count]zm.Mat {
    const eye = zm.f32x4(light_pos[0], light_pos[1], light_pos[2], 1);
    const proj = zm.perspectiveFovLh(std.math.pi * 0.5, 1.0, near, range);

    const targets = [_][3]f32{
        .{ 1, 0, 0 },
        .{ -1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, -1, 0 },
        .{ 0, 0, 1 },
        .{ 0, 0, -1 },
    };
    const ups = [_]zm.Vec{
        zm.f32x4(0, -1, 0, 0),
        zm.f32x4(0, -1, 0, 0),
        zm.f32x4(0, 0, 1, 0),
        zm.f32x4(0, 0, -1, 0),
        zm.f32x4(0, -1, 0, 0),
        zm.f32x4(0, -1, 0, 0),
    };

    var out: [point_face_count]zm.Mat = undefined;
    for (0..point_face_count) |i| {
        const focus = zm.f32x4(
            light_pos[0] + targets[i][0],
            light_pos[1] + targets[i][1],
            light_pos[2] + targets[i][2],
            1,
        );
        const view = zm.lookAtLh(eye, focus, ups[i]);
        out[i] = zm.mul(view, proj);
    }
    return out;
}

/// Practical split scheme (uniform / log blend) up to `max_distance`.
pub fn computeCascades(
    camera: Camera,
    aspect: f32,
    /// Direction toward the light (same as deferred L for directional).
    light_dir: [3]f32,
    max_distance: f32,
) CascadeData {
    const near = camera.near;
    const far = @min(camera.far, max_distance);
    const lambda: f32 = 0.7;

    var splits: [4]f32 = undefined;
    var i: u32 = 0;
    while (i < cascade_count) : (i += 1) {
        const p = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(cascade_count));
        const log_s = near * std.math.pow(f32, far / near, p);
        const uni_s = near + (far - near) * p;
        splits[i] = std.math.lerp(uni_s, log_s, lambda);
    }

    var light_vp: [cascade_count]zm.Mat = undefined;
    var prev: f32 = near;
    i = 0;
    while (i < cascade_count) : (i += 1) {
        light_vp[i] = fitCascade(camera, aspect, light_dir, prev, splits[i]);
        prev = splits[i];
    }

    return .{ .light_vp = light_vp, .splits = splits };
}

fn fitCascade(
    camera: Camera,
    aspect: f32,
    light_dir: [3]f32,
    near_z: f32,
    far_z: f32,
) zm.Mat {
    const corners = frustumSliceCorners(camera, aspect, near_z, far_z);

    var center = zm.f32x4(0, 0, 0, 1);
    for (corners) |c| {
        center[0] += c[0];
        center[1] += c[1];
        center[2] += c[2];
    }
    center[0] /= 8.0;
    center[1] /= 8.0;
    center[2] /= 8.0;

    const ld = normalize3(light_dir);
    var radius: f32 = 0;
    for (corners) |c| {
        const dx = c[0] - center[0];
        const dy = c[1] - center[1];
        const dz = c[2] - center[2];
        radius = @max(radius, @sqrt(dx * dx + dy * dy + dz * dz));
    }
    radius = @ceil(radius * 16.0) / 16.0;

    const up = if (@abs(ld[1]) > 0.95)
        zm.f32x4(0, 0, 1, 0)
    else
        zm.f32x4(0, 1, 0, 0);

    const eye = zm.f32x4(
        center[0] + ld[0] * radius * 2.0,
        center[1] + ld[1] * radius * 2.0,
        center[2] + ld[2] * radius * 2.0,
        1,
    );
    const light_view = zm.lookAtLh(eye, center, up);

    const texel = (radius * 2.0) / @as(f32, @floatFromInt(map_size));
    var light_center = zm.mul(center, light_view);
    light_center[0] = @floor(light_center[0] / texel) * texel;
    light_center[1] = @floor(light_center[1] / texel) * texel;

    const ortho = zm.orthographicOffCenterLh(
        light_center[0] - radius,
        light_center[0] + radius,
        light_center[1] + radius,
        light_center[1] - radius,
        0.1,
        radius * 6.0,
    );
    return zm.mul(light_view, ortho);
}

fn frustumSliceCorners(camera: Camera, aspect: f32, near_z: f32, far_z: f32) [8][3]f32 {
    const tan_half = @tan(camera.fov_y * 0.5);
    const near_h = near_z * tan_half;
    const near_w = near_h * aspect;
    const far_h = far_z * tan_half;
    const far_w = far_h * aspect;

    const vs = [_][3]f32{
        .{ -near_w, near_h, near_z },
        .{ near_w, near_h, near_z },
        .{ near_w, -near_h, near_z },
        .{ -near_w, -near_h, near_z },
        .{ -far_w, far_h, far_z },
        .{ far_w, far_h, far_z },
        .{ far_w, -far_h, far_z },
        .{ -far_w, -far_h, far_z },
    };

    const inv_view = zm.inverse(camera.viewMatrix());
    var out: [8][3]f32 = undefined;
    for (vs, 0..) |p, i| {
        const w = zm.mul(zm.f32x4(p[0], p[1], p[2], 1), inv_view);
        out[i] = .{ w[0], w[1], w[2] };
    }
    return out;
}

fn normalize3(v: [3]f32) [3]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len < 1e-6) return .{ 0, 1, 0 };
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

test "cascade splits increase" {
    const cam = Camera{};
    const data = computeCascades(cam, 16.0 / 9.0, .{ 0.45, 0.85, -0.35 }, 40.0);
    try std.testing.expect(data.splits[0] < data.splits[1]);
    try std.testing.expect(data.splits[2] < data.splits[3]);
}

test "point face count" {
    const mats = pointFaceViewProjs(.{ 0, 1, 0 }, 0.05, 6.0);
    try std.testing.expectEqual(@as(usize, 6), mats.len);
}

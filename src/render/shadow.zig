const std = @import("std");
const zgpu = @import("zgpu");
const zm = @import("zmath");
const Camera = @import("camera.zig").Camera;

pub const cascade_count: u32 = 4;
pub const map_size: u32 = 1024;
pub const max_point_shadow_slots: u32 = 8;
pub const point_map_size: u32 = 256;
pub const point_face_count: u32 = 6;
pub const point_atlas_layers: u32 = max_point_shadow_slots * point_face_count;
pub const max_spot_shadow_slots: u32 = 4;
pub const spot_map_size: u32 = 512;
/// Max punctual shadow volumes refreshed per frame (Dagor DEFAULT_MAX_SHADOWS_TO_UPDATE).
pub const max_shadow_updates_per_frame: u32 = 4;

pub const DepthUniforms = extern struct {
    light_vp: zm.Mat,
};

pub const PointDepthUniforms = extern struct {
    face_vp: zm.Mat,
    light_pos_range: [4]f32,
};

pub const CascadeData = struct {
    light_vp: [cascade_count]zm.Mat,
    splits: [4]f32,
    radii: [4]f32,
    z_ranges: [4]f32,
};

pub const Maps = struct {
    texture: zgpu.TextureHandle = .{},
    array_view: zgpu.TextureViewHandle = .{},
    layer_views: [cascade_count]zgpu.TextureViewHandle = [_]zgpu.TextureViewHandle{.{}} ** cascade_count,
    comparison_sampler: zgpu.SamplerHandle = .{},
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

/// Atlas of up to `max_point_shadow_slots` cubemaps as a cube-array (Dagor ShadowSystem role).
pub const PointMaps = struct {
    texture: zgpu.TextureHandle = .{},
    cube_array_view: zgpu.TextureViewHandle = .{},
    /// [slot][face]
    face_views: [max_point_shadow_slots][point_face_count]zgpu.TextureViewHandle =
        [_][point_face_count]zgpu.TextureViewHandle{[_]zgpu.TextureViewHandle{.{}} ** point_face_count} ** max_point_shadow_slots,
    /// Legacy single-cube view of slot 0 (compat).
    cube_view: zgpu.TextureViewHandle = .{},

    pub fn create(gctx: *zgpu.GraphicsContext) PointMaps {
        const texture = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{
                .width = point_map_size,
                .height = point_map_size,
                .depth_or_array_layers = point_atlas_layers,
            },
            .format = .depth32_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });

        const cube_array_view = gctx.createTextureView(texture, .{
            .dimension = .tvdim_cube_array,
            .base_mip_level = 0,
            .mip_level_count = 1,
            .base_array_layer = 0,
            .array_layer_count = point_atlas_layers,
            .aspect = .depth_only,
        });

        const cube_view = gctx.createTextureView(texture, .{
            .dimension = .tvdim_cube,
            .base_mip_level = 0,
            .mip_level_count = 1,
            .base_array_layer = 0,
            .array_layer_count = point_face_count,
            .aspect = .depth_only,
        });

        var face_views: [max_point_shadow_slots][point_face_count]zgpu.TextureViewHandle = undefined;
        for (0..max_point_shadow_slots) |slot| {
            for (0..point_face_count) |face| {
                const layer: u32 = @intCast(slot * point_face_count + face);
                face_views[slot][face] = gctx.createTextureView(texture, .{
                    .dimension = .tvdim_2d,
                    .base_mip_level = 0,
                    .mip_level_count = 1,
                    .base_array_layer = layer,
                    .array_layer_count = 1,
                    .aspect = .depth_only,
                });
            }
        }

        return .{
            .texture = texture,
            .cube_array_view = cube_array_view,
            .face_views = face_views,
            .cube_view = cube_view,
        };
    }

    pub fn destroy(self: *PointMaps, gctx: *zgpu.GraphicsContext) void {
        for (&self.face_views) |*slot| {
            for (slot) |*v| {
                if (gctx.isResourceValid(v.*)) gctx.releaseResource(v.*);
            }
        }
        if (gctx.isResourceValid(self.cube_view)) gctx.releaseResource(self.cube_view);
        if (gctx.isResourceValid(self.cube_array_view)) gctx.releaseResource(self.cube_array_view);
        if (gctx.isResourceValid(self.texture)) gctx.destroyResource(self.texture);
        self.* = .{};
    }

    pub fn faceView(self: *const PointMaps, slot: u32, face: u32) zgpu.TextureViewHandle {
        return self.face_views[slot][face];
    }
};

/// Spot-light shadow atlas (depth 2D array) — Dagor setSpotLightShadowVolume role.
pub const SpotMaps = struct {
    texture: zgpu.TextureHandle = .{},
    array_view: zgpu.TextureViewHandle = .{},
    layer_views: [max_spot_shadow_slots]zgpu.TextureViewHandle =
        [_]zgpu.TextureViewHandle{.{}} ** max_spot_shadow_slots,

    pub fn create(gctx: *zgpu.GraphicsContext) SpotMaps {
        const texture = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{
                .width = spot_map_size,
                .height = spot_map_size,
                .depth_or_array_layers = max_spot_shadow_slots,
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
            .array_layer_count = max_spot_shadow_slots,
            .aspect = .depth_only,
        });
        var layer_views: [max_spot_shadow_slots]zgpu.TextureViewHandle = undefined;
        for (0..max_spot_shadow_slots) |i| {
            layer_views[i] = gctx.createTextureView(texture, .{
                .dimension = .tvdim_2d,
                .base_mip_level = 0,
                .mip_level_count = 1,
                .base_array_layer = @intCast(i),
                .array_layer_count = 1,
                .aspect = .depth_only,
            });
        }
        return .{ .texture = texture, .array_view = array_view, .layer_views = layer_views };
    }

    pub fn destroy(self: *SpotMaps, gctx: *zgpu.GraphicsContext) void {
        for (&self.layer_views) |*v| {
            if (gctx.isResourceValid(v.*)) gctx.releaseResource(v.*);
        }
        if (gctx.isResourceValid(self.array_view)) gctx.releaseResource(self.array_view);
        if (gctx.isResourceValid(self.texture)) gctx.destroyResource(self.texture);
        self.* = .{};
    }
};

/// Sparse cascade update (Dagor shouldUpdateCascade role).
/// Near cascades every frame; far cascades on a schedule unless `force` (camera jump).
pub fn shouldUpdateCascade(frame_index: u64, cascade: u32, force: bool) bool {
    if (force) return true;
    return switch (cascade) {
        0, 1 => true,
        2 => (frame_index % 2) == 0,
        else => (frame_index % 4) == 0,
    };
}

pub fn spotLightViewProj(
    light_pos: [3]f32,
    light_dir: [3]f32,
    near: f32,
    range: f32,
    outer_cone_rad: f32,
) zm.Mat {
    const eye = zm.f32x4(light_pos[0], light_pos[1], light_pos[2], 1);
    const ld = normalize3(light_dir);
    const focus = zm.f32x4(
        light_pos[0] + ld[0],
        light_pos[1] + ld[1],
        light_pos[2] + ld[2],
        1,
    );
    const up = if (@abs(ld[1]) > 0.95)
        zm.f32x4(0, 0, 1, 0)
    else
        zm.f32x4(0, 1, 0, 0);
    const view = zm.lookAtLh(eye, focus, up);
    const fov = @max(outer_cone_rad * 2.0, 0.05);
    const zn = @max(near, range * 0.001);
    const proj = zm.perspectiveFovLh(fov, 1.0, zn, range);
    return zm.mul(view, proj);
}

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

pub fn computeCascades(
    camera: Camera,
    aspect: f32,
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
    var radii: [4]f32 = undefined;
    var z_ranges: [4]f32 = undefined;
    var prev: f32 = near;
    i = 0;
    while (i < cascade_count) : (i += 1) {
        const fitted = fitCascade(camera, aspect, light_dir, prev, splits[i]);
        light_vp[i] = fitted.vp;
        radii[i] = fitted.radius;
        z_ranges[i] = fitted.z_range;
        prev = splits[i];
    }

    return .{ .light_vp = light_vp, .splits = splits, .radii = radii, .z_ranges = z_ranges };
}

const FittedCascade = struct {
    vp: zm.Mat,
    radius: f32,
    z_range: f32,
};

fn fitCascade(
    camera: Camera,
    aspect: f32,
    light_dir: [3]f32,
    near_z: f32,
    far_z: f32,
) FittedCascade {
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
    const texel_world = (radius * 2.0) / @as(f32, @floatFromInt(map_size));
    radius += texel_world * 8.0;
    radius = @ceil(radius * 16.0) / 16.0;

    const up = if (@abs(ld[1]) > 0.95)
        zm.f32x4(0, 0, 1, 0)
    else
        zm.f32x4(0, 1, 0, 0);

    const pull_back = radius * 3.0;
    const eye = zm.f32x4(
        center[0] + ld[0] * pull_back,
        center[1] + ld[1] * pull_back,
        center[2] + ld[2] * pull_back,
        1,
    );
    const light_view = zm.lookAtLh(eye, center, up);

    const texel = (radius * 2.0) / @as(f32, @floatFromInt(map_size));
    var light_center = zm.mul(center, light_view);
    light_center[0] = @floor(light_center[0] / texel) * texel;
    light_center[1] = @floor(light_center[1] / texel) * texel;

    const z_near: f32 = 0.1;
    const z_far = pull_back + radius * 2.0;
    const ortho = zm.orthographicOffCenterLh(
        light_center[0] - radius,
        light_center[0] + radius,
        light_center[1] + radius,
        light_center[1] - radius,
        z_near,
        z_far,
    );
    return .{
        .vp = zm.mul(light_view, ortho),
        .radius = radius,
        .z_range = z_far - z_near,
    };
}

fn frustumSliceCorners(camera: Camera, aspect: f32, near_z: f32, far_z: f32) [8][3]f32 {
    const tan_half = @tan(camera.fov_y * 0.5);
    const near_h = near_z * tan_half;
    const near_w = near_h * aspect;
    const far_h = far_z * tan_half;
    const far_w = far_h * aspect;

    const inv_view = zm.inverse(camera.viewMatrix());
    const corners_vs = [_][3]f32{
        .{ -near_w, near_h, near_z },
        .{ near_w, near_h, near_z },
        .{ near_w, -near_h, near_z },
        .{ -near_w, -near_h, near_z },
        .{ -far_w, far_h, far_z },
        .{ far_w, far_h, far_z },
        .{ far_w, -far_h, far_z },
        .{ -far_w, -far_h, far_z },
    };
    var out: [8][3]f32 = undefined;
    for (corners_vs, 0..) |c, i| {
        const w = zm.mul(zm.f32x4(c[0], c[1], c[2], 1), inv_view);
        out[i] = .{ w[0], w[1], w[2] };
    }
    return out;
}

fn normalize3(v: [3]f32) [3]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len < 1e-8) return .{ 0, 1, 0 };
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

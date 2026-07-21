const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zm = @import("zmath");
const dds = @import("dds.zig");
const shader = @import("shader.zig");
const log = @import("../core/log.zig");

/// CryEngine-inspired rain controller (amount / speed / wetness / wind).
/// Mirrors Cry `SRainInfo` + `CRainDrops` knobs, driven smoothly for gameplay/UI.
pub const Controller = struct {
    enabled: bool = true,
    /// Master rain 0..1 (smooth toward `target`).
    intensity: f32 = 0.0,
    target: f32 = 0.0,
    /// Seconds to approach target (higher = snappier).
    transition_speed: f32 = 1.2,

    /// Screen-space streak density (Cry RainDrops_Amount).
    drops_amount: f32 = 0.65,
    /// Fall speed multiplier (Cry fRainDropsSpeed).
    drops_speed: f32 = 1.15,
    /// Streak scale (Cry RainDrops_Size).
    drops_size: f32 = 1.0,
    /// Near-camera splatters.
    spatter_amount: f32 = 0.55,
    /// Ground wetness / puddle darkening.
    wetness: f32 = 0.75,
    puddle_scale: f32 = 1.0,
    /// How much atmosphere wind tilts streaks.
    wind_influence: f32 = 1.0,
    /// Sync `atmosphere.params.rain` from intensity.
    sync_atmosphere: bool = true,
    /// Lightning flash (0..1, decays each frame).
    lightning: f32 = 0.0,

    pub fn setIntensity(self: *Controller, v: f32) void {
        self.target = std.math.clamp(v, 0.0, 1.0);
        if (!self.enabled) self.target = 0;
    }

    pub fn start(self: *Controller, intensity: f32) void {
        self.enabled = true;
        self.setIntensity(intensity);
    }

    pub fn stop(self: *Controller) void {
        self.setIntensity(0);
    }

    pub fn thunder(self: *Controller, strength: f32) void {
        self.lightning = @max(self.lightning, std.math.clamp(strength, 0, 1));
    }

    pub fn update(self: *Controller, dt: f32) void {
        if (!self.enabled) self.target = 0;
        const k = 1.0 - @exp(-self.transition_speed * @max(dt, 0));
        self.intensity += (self.target - self.intensity) * k;
        if (@abs(self.intensity) < 0.001 and self.target == 0) self.intensity = 0;
        self.lightning = @max(0, self.lightning - dt * 2.5);
    }

    pub fn active(self: *const Controller) bool {
        return self.enabled and self.intensity > 0.005;
    }
};

pub const GpuUniforms = extern struct {
    /// x=intensity, y=drops_amount, z=drops_speed, w=drops_size
    params0: [4]f32,
    /// x=spatter, y=wetness, z=puddle_scale, w=lightning
    params1: [4]f32,
    /// xy=wind xz, z=wind_influence, w=time
    wind_time: [4]f32,
    /// xy=screen size, z=near, w=far
    screen: [4]f32,
    camera_pos: [4]f32,
    inv_view_proj: zm.Mat,
    view_proj: zm.Mat,
};

pub const System = struct {
    controller: Controller = .{},

    streak_tex: zgpu.TextureHandle = .{},
    streak_view: zgpu.TextureViewHandle = .{},
    rainfall_tex: zgpu.TextureHandle = .{},
    rainfall_view: zgpu.TextureViewHandle = .{},
    spatter_tex: zgpu.TextureHandle = .{},
    spatter_view: zgpu.TextureViewHandle = .{},
    puddle_tex: zgpu.TextureHandle = .{},
    puddle_view: zgpu.TextureViewHandle = .{},
    flow_tex: zgpu.TextureHandle = .{},
    flow_view: zgpu.TextureViewHandle = .{},
    ripple_tex: zgpu.TextureHandle = .{},
    ripple_view: zgpu.TextureViewHandle = .{},
    sampler: zgpu.SamplerHandle = .{},

    pipeline: zgpu.RenderPipelineHandle = .{},
    bgl: zgpu.BindGroupLayoutHandle = .{},
    bg: zgpu.BindGroupHandle = .{},
    ready: bool = false,
    time: f32 = 0,

    pub fn create(gctx: *zgpu.GraphicsContext, allocator: std.mem.Allocator, cache: *shader.Cache) !System {
        var self: System = .{};
        self.sampler = gctx.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
        });

        self.streak_tex = try loadDds(gctx, allocator, "assets/weather/rain/rain_streak.dds");
        self.streak_view = gctx.createTextureView(self.streak_tex, .{});
        self.rainfall_tex = try loadDds(gctx, allocator, "assets/weather/rain/rainfall.dds");
        self.rainfall_view = gctx.createTextureView(self.rainfall_tex, .{});
        self.spatter_tex = try loadDds(gctx, allocator, "assets/weather/rain/rain_spatter.dds");
        self.spatter_view = gctx.createTextureView(self.spatter_tex, .{});
        self.puddle_tex = try loadDds(gctx, allocator, "assets/weather/rain/puddle_mask.dds");
        self.puddle_view = gctx.createTextureView(self.puddle_tex, .{});
        self.flow_tex = try loadDds(gctx, allocator, "assets/weather/rain/surface_flow_ddn.dds");
        self.flow_view = gctx.createTextureView(self.flow_tex, .{});
        self.ripple_tex = try loadDds(gctx, allocator, "assets/weather/rain/ripple/ripple8_ddn.dds");
        self.ripple_view = gctx.createTextureView(self.ripple_tex, .{});

        self.bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .depth, .tvdim_2d, false),
            zgpu.textureEntry(3, .{ .fragment = true }, .float, .tvdim_2d, false), // gbuffer normals
            zgpu.textureEntry(4, .{ .fragment = true }, .float, .tvdim_2d, false), // streak
            zgpu.textureEntry(5, .{ .fragment = true }, .float, .tvdim_2d, false), // rainfall
            zgpu.textureEntry(6, .{ .fragment = true }, .float, .tvdim_2d, false), // spatter
            zgpu.textureEntry(7, .{ .fragment = true }, .float, .tvdim_2d, false), // puddle
            zgpu.textureEntry(8, .{ .fragment = true }, .float, .tvdim_2d, false), // flow nrm
            zgpu.textureEntry(9, .{ .fragment = true }, .float, .tvdim_2d, false), // ripple nrm
        });

        const pl = gctx.createPipelineLayout(&.{self.bgl});
        defer gctx.releaseResource(pl);
        const module = try cache.getOrLoad("assets/shaders/rain_overlay.wgsl");
        defer module.release();

        const blend = wgpu.BlendState{
            .color = .{ .operation = .add, .src_factor = .one, .dst_factor = .one_minus_src_alpha },
            .alpha = .{ .operation = .add, .src_factor = .one, .dst_factor = .one_minus_src_alpha },
        };
        const targets = [_]wgpu.ColorTargetState{.{
            .format = .rgba16_float,
            .blend = &blend,
            .write_mask = .all,
        }};
        self.pipeline = gctx.createRenderPipeline(pl, .{
            .vertex = .{ .module = module, .entry_point = "vs_main" },
            .primitive = .{
                .front_face = .ccw,
                .cull_mode = .none,
                .topology = .triangle_list,
            },
            .fragment = &wgpu.FragmentState{
                .module = module,
                .entry_point = "fs_main",
                .target_count = targets.len,
                .targets = &targets,
            },
        });

        self.ready = true;
        log.info(.render, "rain system: CryEngine textures (streak/rainfall/spatter/puddle/flow/ripple)", .{});
        return self;
    }

    fn loadDds(gctx: *zgpu.GraphicsContext, allocator: std.mem.Allocator, path: []const u8) !zgpu.TextureHandle {
        const loaded = try dds.loadFile(allocator, path);
        defer allocator.free(loaded.data);
        return dds.upload(gctx, loaded);
    }

    pub fn destroy(self: *System, gctx: *zgpu.GraphicsContext) void {
        if (gctx.isResourceValid(self.bg)) gctx.releaseResource(self.bg);
        inline for (.{
            self.streak_view, self.rainfall_view, self.spatter_view,
            self.puddle_view, self.flow_view,     self.ripple_view,
        }) |v| {
            if (gctx.isResourceValid(v)) gctx.releaseResource(v);
        }
        inline for (.{
            self.streak_tex, self.rainfall_tex, self.spatter_tex,
            self.puddle_tex, self.flow_tex,     self.ripple_tex,
        }) |t| {
            if (gctx.isResourceValid(t)) gctx.destroyResource(t);
        }
        if (gctx.isResourceValid(self.sampler)) gctx.releaseResource(self.sampler);
        self.* = .{};
    }

    pub fn rebuildBindGroup(
        self: *System,
        gctx: *zgpu.GraphicsContext,
        depth_view: zgpu.TextureViewHandle,
        normal_view: zgpu.TextureViewHandle,
    ) void {
        if (!self.ready) return;
        if (gctx.isResourceValid(self.bg)) gctx.releaseResource(self.bg);
        self.bg = gctx.createBindGroup(self.bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(GpuUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = depth_view },
            .{ .binding = 3, .texture_view_handle = normal_view },
            .{ .binding = 4, .texture_view_handle = self.streak_view },
            .{ .binding = 5, .texture_view_handle = self.rainfall_view },
            .{ .binding = 6, .texture_view_handle = self.spatter_view },
            .{ .binding = 7, .texture_view_handle = self.puddle_view },
            .{ .binding = 8, .texture_view_handle = self.flow_view },
            .{ .binding = 9, .texture_view_handle = self.ripple_view },
        });
    }

    /// Draw additive/alpha rain overlay into HDR (before bloom).
    pub fn draw(
        self: *System,
        gctx: *zgpu.GraphicsContext,
        encoder: wgpu.CommandEncoder,
        hdr_view: zgpu.TextureViewHandle,
        wind_xz: [2]f32,
        cam_pos: [3]f32,
        inv_view_proj: zm.Mat,
        view_proj: zm.Mat,
        cam_near: f32,
        cam_far: f32,
        dt: f32,
        fb_w: u32,
        fb_h: u32,
    ) void {
        if (!self.ready or !self.controller.active()) return;
        self.time += dt;
        const pipeline = gctx.lookupResource(self.pipeline) orelse return;
        const bind_group = gctx.lookupResource(self.bg) orelse return;
        const view = gctx.lookupResource(hdr_view) orelse return;

        const c = &self.controller;
        const color = [_]wgpu.RenderPassColorAttachment{.{
            .view = view,
            .load_op = .load,
            .store_op = .store,
        }};
        const pass = encoder.beginRenderPass(.{
            .color_attachment_count = color.len,
            .color_attachments = &color,
        });
        defer {
            pass.end();
            pass.release();
        }
        pass.setPipeline(pipeline);
        const mem = gctx.uniformsAllocate(GpuUniforms, 1);
        mem.slice[0] = .{
            .params0 = .{ c.intensity, c.drops_amount, c.drops_speed, c.drops_size },
            .params1 = .{ c.spatter_amount, c.wetness, c.puddle_scale, c.lightning },
            .wind_time = .{ wind_xz[0], wind_xz[1], c.wind_influence, self.time },
            .screen = .{
                @floatFromInt(fb_w),
                @floatFromInt(fb_h),
                cam_near,
                cam_far,
            },
            .camera_pos = .{ cam_pos[0], cam_pos[1], cam_pos[2], 1 },
            .inv_view_proj = zm.transpose(inv_view_proj),
            .view_proj = zm.transpose(view_proj),
        };
        pass.setBindGroup(0, bind_group, &.{mem.offset});
        pass.draw(3, 1, 0, 0);
    }
};

test "controller ramps to target" {
    var c: Controller = .{};
    c.start(0.8);
    c.update(1.0);
    try std.testing.expect(c.intensity > 0.4);
    c.stop();
    c.update(2.0);
    try std.testing.expect(c.intensity < 0.2);
}

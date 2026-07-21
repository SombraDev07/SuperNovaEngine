const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zm = @import("zmath");
const shader = @import("shader.zig");
const log = @import("../core/log.zig");

/// Screen-space Ground Truth AO (Jimenez) — Dagor GTAORenderer role.
/// Passes: raw → spatial H/V → temporal → stable `final` (lighting always binds this).
pub const Params = struct {
    enabled: bool = true,
    radius: f32 = 0.55,
    power: f32 = 1.35,
    thickness: f32 = 0.85,
    strength: f32 = 1.0,
    temporal_blend: f32 = 0.92,
    slice_count: u32 = 4,
    step_count: u32 = 4,
    depth_sigma: f32 = 1.0,
};

pub const RawUniforms = extern struct {
    inv_view_proj: zm.Mat,
    view: zm.Mat,
    params: [4]f32,
    screen: [4]f32,
    proj: [4]f32,
};

pub const SpatialUniforms = extern struct {
    params: [4]f32,
    screen: [4]f32,
};

pub const TemporalUniforms = extern struct {
    prev_view_proj: zm.Mat,
    inv_view_proj: zm.Mat,
    params: [4]f32,
};

pub const System = struct {
    params: Params = .{},
    ready: bool = false,
    sample_index: u32 = 0,

    width: u32 = 0,
    height: u32 = 0,

    raw_tex: zgpu.TextureHandle = .{},
    raw_view: zgpu.TextureViewHandle = .{},
    spatial_tex: zgpu.TextureHandle = .{},
    spatial_view: zgpu.TextureViewHandle = .{},
    /// Stable output bound by deferred lighting (never ping-pongs).
    final_tex: zgpu.TextureHandle = .{},
    final_view: zgpu.TextureViewHandle = .{},
    /// Temporal history only.
    hist_tex: [2]zgpu.TextureHandle = .{ .{}, .{} },
    hist_view: [2]zgpu.TextureViewHandle = .{ .{}, .{} },
    hist_idx: u32 = 0,

    white_tex: zgpu.TextureHandle = .{},
    white_view: zgpu.TextureViewHandle = .{},

    sampler: zgpu.SamplerHandle = .{},

    raw_pipeline: zgpu.RenderPipelineHandle = .{},
    raw_bgl: zgpu.BindGroupLayoutHandle = .{},
    raw_bg: zgpu.BindGroupHandle = .{},

    spatial_pipeline: zgpu.RenderPipelineHandle = .{},
    spatial_bgl: zgpu.BindGroupLayoutHandle = .{},
    spatial_bg_h: zgpu.BindGroupHandle = .{},
    spatial_bg_v: zgpu.BindGroupHandle = .{},

    temporal_pipeline: zgpu.RenderPipelineHandle = .{},
    temporal_bgl: zgpu.BindGroupLayoutHandle = .{},
    /// temporal_bg[i] reads hist_view[i] as history.
    temporal_bg: [2]zgpu.BindGroupHandle = .{ .{}, .{} },

    prev_view_proj: zm.Mat = zm.identity(),
    has_history: bool = false,

    pub fn create(gctx: *zgpu.GraphicsContext, cache: *shader.Cache) !System {
        var self: System = .{};
        self.sampler = gctx.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });

        self.white_tex = gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .dimension = .tdim_2d,
            .size = .{ .width = 1, .height = 1, .depth_or_array_layers = 1 },
            .format = .rg16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        self.white_view = gctx.createTextureView(self.white_tex, .{});
        const white_px = [_]u16{ 0x3C00, 0x3C00 };
        gctx.queue.writeTexture(
            .{
                .texture = gctx.lookupResource(self.white_tex).?,
                .mip_level = 0,
                .origin = .{},
                .aspect = .all,
            },
            .{ .offset = 0, .bytes_per_row = 256, .rows_per_image = 1 },
            .{ .width = 1, .height = 1, .depth_or_array_layers = 1 },
            u16,
            white_px[0..],
        );

        self.raw_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .depth, .tvdim_2d, false),
            zgpu.textureEntry(3, .{ .fragment = true }, .float, .tvdim_2d, false),
        });
        self.spatial_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .float, .tvdim_2d, false),
        });
        self.temporal_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(3, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(4, .{ .fragment = true }, .depth, .tvdim_2d, false),
        });

        const raw_pl = gctx.createPipelineLayout(&.{self.raw_bgl});
        defer gctx.releaseResource(raw_pl);
        const spat_pl = gctx.createPipelineLayout(&.{self.spatial_bgl});
        defer gctx.releaseResource(spat_pl);
        const temp_pl = gctx.createPipelineLayout(&.{self.temporal_bgl});
        defer gctx.releaseResource(temp_pl);

        const targets = [_]wgpu.ColorTargetState{.{ .format = .rg16_float }};

        {
            const module = try cache.getOrLoad("assets/shaders/gtao.wgsl");
            defer module.release();
            self.raw_pipeline = gctx.createRenderPipeline(raw_pl, .{
                .vertex = .{ .module = module, .entry_point = "vs_main" },
                .primitive = .{ .front_face = .ccw, .cull_mode = .none, .topology = .triangle_list },
                .fragment = &wgpu.FragmentState{
                    .module = module,
                    .entry_point = "fs_main",
                    .target_count = targets.len,
                    .targets = &targets,
                },
            });
        }
        {
            const module = try cache.getOrLoad("assets/shaders/gtao_spatial.wgsl");
            defer module.release();
            self.spatial_pipeline = gctx.createRenderPipeline(spat_pl, .{
                .vertex = .{ .module = module, .entry_point = "vs_main" },
                .primitive = .{ .front_face = .ccw, .cull_mode = .none, .topology = .triangle_list },
                .fragment = &wgpu.FragmentState{
                    .module = module,
                    .entry_point = "fs_main",
                    .target_count = targets.len,
                    .targets = &targets,
                },
            });
        }
        {
            const module = try cache.getOrLoad("assets/shaders/gtao_temporal.wgsl");
            defer module.release();
            self.temporal_pipeline = gctx.createRenderPipeline(temp_pl, .{
                .vertex = .{ .module = module, .entry_point = "vs_main" },
                .primitive = .{ .front_face = .ccw, .cull_mode = .none, .topology = .triangle_list },
                .fragment = &wgpu.FragmentState{
                    .module = module,
                    .entry_point = "fs_main",
                    .target_count = targets.len,
                    .targets = &targets,
                },
            });
        }

        self.resize(gctx);
        self.ready = true;
        log.info(.render, "GTAO: Jimenez raw + bilateral + temporal (stable final RT)", .{});
        return self;
    }

    fn destroyTargets(self: *System, gctx: *zgpu.GraphicsContext) void {
        inline for (.{
            &self.raw_view, &self.spatial_view, &self.final_view,
            &self.hist_view[0], &self.hist_view[1],
        }) |v| {
            if (gctx.isResourceValid(v.*)) gctx.releaseResource(v.*);
            v.* = .{};
        }
        inline for (.{
            &self.raw_tex, &self.spatial_tex, &self.final_tex,
            &self.hist_tex[0], &self.hist_tex[1],
        }) |t| {
            if (gctx.isResourceValid(t.*)) gctx.destroyResource(t.*);
            t.* = .{};
        }
        if (gctx.isResourceValid(self.raw_bg)) gctx.releaseResource(self.raw_bg);
        if (gctx.isResourceValid(self.spatial_bg_h)) gctx.releaseResource(self.spatial_bg_h);
        if (gctx.isResourceValid(self.spatial_bg_v)) gctx.releaseResource(self.spatial_bg_v);
        if (gctx.isResourceValid(self.temporal_bg[0])) gctx.releaseResource(self.temporal_bg[0]);
        if (gctx.isResourceValid(self.temporal_bg[1])) gctx.releaseResource(self.temporal_bg[1]);
        self.raw_bg = .{};
        self.spatial_bg_h = .{};
        self.spatial_bg_v = .{};
        self.temporal_bg = .{ .{}, .{} };
        self.has_history = false;
    }

    fn makeAoTarget(gctx: *zgpu.GraphicsContext, w: u32, h: u32) struct { zgpu.TextureHandle, zgpu.TextureViewHandle } {
        const tex = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true, .copy_src = true, .copy_dst = true },
            .dimension = .tdim_2d,
            .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
            .format = .rg16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        return .{ tex, gctx.createTextureView(tex, .{}) };
    }

    pub fn resize(self: *System, gctx: *zgpu.GraphicsContext) void {
        const w = @max(gctx.swapchain_descriptor.width, 1);
        const h = @max(gctx.swapchain_descriptor.height, 1);
        if (w == self.width and h == self.height and gctx.isResourceValid(self.final_tex)) return;
        self.destroyTargets(gctx);
        self.width = w;
        self.height = h;
        const raw = makeAoTarget(gctx, w, h);
        self.raw_tex = raw[0];
        self.raw_view = raw[1];
        const spat = makeAoTarget(gctx, w, h);
        self.spatial_tex = spat[0];
        self.spatial_view = spat[1];
        const fin = makeAoTarget(gctx, w, h);
        self.final_tex = fin[0];
        self.final_view = fin[1];
        const h0 = makeAoTarget(gctx, w, h);
        self.hist_tex[0] = h0[0];
        self.hist_view[0] = h0[1];
        const h1 = makeAoTarget(gctx, w, h);
        self.hist_tex[1] = h1[0];
        self.hist_view[1] = h1[1];
        self.hist_idx = 0;
    }

    pub fn destroy(self: *System, gctx: *zgpu.GraphicsContext) void {
        self.destroyTargets(gctx);
        if (gctx.isResourceValid(self.white_view)) gctx.releaseResource(self.white_view);
        if (gctx.isResourceValid(self.white_tex)) gctx.destroyResource(self.white_tex);
        if (gctx.isResourceValid(self.sampler)) gctx.releaseResource(self.sampler);
        self.* = .{};
    }

    /// Always the stable final RT (or 1×1 white if not ready). Safe to keep in light_bg across frames.
    pub fn outputView(self: *const System) zgpu.TextureViewHandle {
        if (!self.ready) return self.white_view;
        return self.final_view;
    }

    pub fn rebuildBindGroups(
        self: *System,
        gctx: *zgpu.GraphicsContext,
        depth_view: zgpu.TextureViewHandle,
        normal_view: zgpu.TextureViewHandle,
    ) void {
        if (!self.ready) return;
        self.resize(gctx);

        if (gctx.isResourceValid(self.raw_bg)) gctx.releaseResource(self.raw_bg);
        if (gctx.isResourceValid(self.spatial_bg_h)) gctx.releaseResource(self.spatial_bg_h);
        if (gctx.isResourceValid(self.spatial_bg_v)) gctx.releaseResource(self.spatial_bg_v);
        if (gctx.isResourceValid(self.temporal_bg[0])) gctx.releaseResource(self.temporal_bg[0]);
        if (gctx.isResourceValid(self.temporal_bg[1])) gctx.releaseResource(self.temporal_bg[1]);

        self.raw_bg = gctx.createBindGroup(self.raw_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(RawUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = depth_view },
            .{ .binding = 3, .texture_view_handle = normal_view },
        });
        self.spatial_bg_h = gctx.createBindGroup(self.spatial_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(SpatialUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.raw_view },
        });
        self.spatial_bg_v = gctx.createBindGroup(self.spatial_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(SpatialUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.spatial_view },
        });
        inline for (0..2) |i| {
            self.temporal_bg[i] = gctx.createBindGroup(self.temporal_bgl, &.{
                .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(TemporalUniforms) },
                .{ .binding = 1, .sampler_handle = self.sampler },
                .{ .binding = 2, .texture_view_handle = self.raw_view },
                .{ .binding = 3, .texture_view_handle = self.hist_view[i] },
                .{ .binding = 4, .texture_view_handle = depth_view },
            });
        }
    }

    fn beginFs(
        gctx: *zgpu.GraphicsContext,
        encoder: wgpu.CommandEncoder,
        pipeline: zgpu.RenderPipelineHandle,
        target: zgpu.TextureViewHandle,
    ) ?wgpu.RenderPassEncoder {
        const pl = gctx.lookupResource(pipeline) orelse return null;
        const tv = gctx.lookupResource(target) orelse return null;
        const color = [_]wgpu.RenderPassColorAttachment{.{
            .view = tv,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 1, .g = 1, .b = 0, .a = 1 },
        }};
        const pass = encoder.beginRenderPass(.{
            .color_attachment_count = color.len,
            .color_attachments = &color,
        });
        pass.setPipeline(pl);
        return pass;
    }

    /// Clear stable final to AO=1 (used when disabled).
    fn clearFinal(self: *System, gctx: *zgpu.GraphicsContext, encoder: wgpu.CommandEncoder) void {
        const tv = gctx.lookupResource(self.final_view) orelse return;
        const color = [_]wgpu.RenderPassColorAttachment{.{
            .view = tv,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 1, .g = 1, .b = 0, .a = 1 },
        }};
        const pass = encoder.beginRenderPass(.{
            .color_attachment_count = color.len,
            .color_attachments = &color,
        });
        pass.end();
        pass.release();
    }

    pub fn draw(
        self: *System,
        gctx: *zgpu.GraphicsContext,
        encoder: wgpu.CommandEncoder,
        view: zm.Mat,
        inv_view_proj: zm.Mat,
        view_proj: zm.Mat,
        fov_y: f32,
        cam_near: f32,
        cam_far: f32,
    ) void {
        if (!self.ready) return;
        if (!self.params.enabled) {
            self.clearFinal(gctx, encoder);
            self.has_history = false;
            return;
        }
        if (!gctx.isResourceValid(self.raw_bg)) return;

        const p = &self.params;
        const fw: f32 = @floatFromInt(self.width);
        const fh: f32 = @floatFromInt(self.height);
        const tan_half = @tan(fov_y * 0.5);
        const proj_scale = 0.5 * fh / @max(tan_half, 1e-4);
        const sample_off: f32 = @floatFromInt(self.sample_index % 8);
        self.sample_index +%= 1;

        // Raw
        if (beginFs(gctx, encoder, self.raw_pipeline, self.raw_view)) |pass| {
            defer {
                pass.end();
                pass.release();
            }
            const bg = gctx.lookupResource(self.raw_bg) orelse return;
            const mem = gctx.uniformsAllocate(RawUniforms, 1);
            mem.slice[0] = .{
                .inv_view_proj = zm.transpose(inv_view_proj),
                .view = zm.transpose(view),
                .params = .{ p.radius, p.power, p.thickness, p.strength },
                .screen = .{ fw, fh, cam_near, cam_far },
                .proj = .{
                    proj_scale,
                    sample_off,
                    @floatFromInt(p.slice_count),
                    @floatFromInt(p.step_count),
                },
            };
            pass.setBindGroup(0, bg, &.{mem.offset});
            pass.draw(3, 1, 0, 0);
        }

        // Spatial H
        if (beginFs(gctx, encoder, self.spatial_pipeline, self.spatial_view)) |pass| {
            defer {
                pass.end();
                pass.release();
            }
            const bg = gctx.lookupResource(self.spatial_bg_h) orelse return;
            const mem = gctx.uniformsAllocate(SpatialUniforms, 1);
            mem.slice[0] = .{
                .params = .{ 1, 0, p.depth_sigma, 0 },
                .screen = .{ fw, fh, 0, 0 },
            };
            pass.setBindGroup(0, bg, &.{mem.offset});
            pass.draw(3, 1, 0, 0);
        }

        // Spatial V → raw scratch
        if (beginFs(gctx, encoder, self.spatial_pipeline, self.raw_view)) |pass| {
            defer {
                pass.end();
                pass.release();
            }
            const bg = gctx.lookupResource(self.spatial_bg_v) orelse return;
            const mem = gctx.uniformsAllocate(SpatialUniforms, 1);
            mem.slice[0] = .{
                .params = .{ 0, 1, p.depth_sigma, 0 },
                .screen = .{ fw, fh, 0, 0 },
            };
            pass.setBindGroup(0, bg, &.{mem.offset});
            pass.draw(3, 1, 0, 0);
        }

        // Temporal → stable final (history from hist[read_i])
        const read_i = self.hist_idx;
        const write_i = 1 - self.hist_idx;
        if (beginFs(gctx, encoder, self.temporal_pipeline, self.final_view)) |pass| {
            defer {
                pass.end();
                pass.release();
            }
            const bg = gctx.lookupResource(self.temporal_bg[read_i]) orelse return;
            const mem = gctx.uniformsAllocate(TemporalUniforms, 1);
            mem.slice[0] = .{
                .prev_view_proj = zm.transpose(self.prev_view_proj),
                .inv_view_proj = zm.transpose(inv_view_proj),
                .params = .{
                    p.temporal_blend,
                    if (self.has_history) @as(f32, 1) else 0,
                    fw,
                    fh,
                },
            };
            pass.setBindGroup(0, bg, &.{mem.offset});
            pass.draw(3, 1, 0, 0);
        }

        // Copy final → hist[write] for next frame (no bind-group churn).
        const src_tex = gctx.lookupResource(self.final_tex) orelse return;
        const dst_tex = gctx.lookupResource(self.hist_tex[write_i]) orelse return;
        encoder.copyTextureToTexture(
            .{ .texture = src_tex },
            .{ .texture = dst_tex },
            .{ .width = self.width, .height = self.height, .depth_or_array_layers = 1 },
        );

        self.hist_idx = write_i;
        self.prev_view_proj = view_proj;
        self.has_history = true;
    }
};

test "gtao params defaults" {
    const p: Params = .{};
    try std.testing.expect(p.enabled);
    try std.testing.expect(p.slice_count >= 3);
}

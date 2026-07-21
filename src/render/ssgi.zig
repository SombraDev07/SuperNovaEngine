const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zm = @import("zmath");
const shader = @import("shader.zig");
const log = @import("../core/log.zig");

/// Phase B GI — daGI2 ScreenSpaceProbes *role* (WebGPU).
/// Tile irradiance from hemisphere SS rays + bilateral upsample.
pub const tile_size: u32 = 16;

pub const Params = struct {
    enabled: bool = true,
    intensity: f32 = 0.85,
    blend: f32 = 0.9,
    temporal: f32 = 0.85,
    max_ray_m: f32 = 5.0,
    ray_steps: f32 = 14,
    rays: f32 = 8,
};

pub const GpuUniforms = extern struct {
    inv_view_proj: zm.Mat,
    view_proj: zm.Mat,
    screen: [4]f32,
    params: [4]f32,
    budget: [4]f32,
    sun_dir: [4]f32,
    sun_color: [4]f32,
    camera_pos: [4]f32,
};

pub const ApplyUniforms = extern struct {
    inv_view_proj: zm.Mat,
    params: [4]f32,
};

pub const System = struct {
    params: Params = .{},
    ready: bool = false,
    frame: u32 = 0,
    warm_frames: u32 = 0,

    w: u32 = 0,
    h: u32 = 0,
    needs_clear: bool = true,

    final_tex: zgpu.TextureHandle = .{},
    final_view: zgpu.TextureViewHandle = .{},
    hist_tex: zgpu.TextureHandle = .{},
    hist_view: zgpu.TextureViewHandle = .{},
    spat_tex: zgpu.TextureHandle = .{},
    spat_view: zgpu.TextureViewHandle = .{},

    sampler: zgpu.SamplerHandle = .{},
    pipeline: zgpu.RenderPipelineHandle = .{},
    bgl: zgpu.BindGroupLayoutHandle = .{},
    bg: zgpu.BindGroupHandle = .{},

    spat_pipeline: zgpu.RenderPipelineHandle = .{},
    spat_bgl: zgpu.BindGroupLayoutHandle = .{},
    spat_bg: zgpu.BindGroupHandle = .{},

    apply_pipeline: zgpu.RenderPipelineHandle = .{},
    apply_bgl: zgpu.BindGroupLayoutHandle = .{},
    apply_bg: zgpu.BindGroupHandle = .{},

    hzb_view: zgpu.TextureViewHandle = .{},
    white_view: zgpu.TextureViewHandle = .{},
    white_tex: zgpu.TextureHandle = .{},

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

        self.bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .depth, .tvdim_2d, false),
            zgpu.textureEntry(3, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(4, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(5, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(6, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(7, .{ .fragment = true }, .float, .tvdim_cube, false),
            zgpu.samplerEntry(8, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(9, .{ .fragment = true }, .unfilterable_float, .tvdim_2d, false),
        });
        const pl = gctx.createPipelineLayout(&.{self.bgl});
        defer gctx.releaseResource(pl);
        {
            const module = try cache.getOrLoad("assets/shaders/ssgi_update.wgsl");
            defer module.release();
            const targets = [_]wgpu.ColorTargetState{.{ .format = .rgba16_float }};
            self.pipeline = gctx.createRenderPipeline(pl, .{
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

        self.spat_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(3, .{ .fragment = true }, .depth, .tvdim_2d, false),
            zgpu.textureEntry(4, .{ .fragment = true }, .float, .tvdim_2d, false),
        });
        {
            const spl = gctx.createPipelineLayout(&.{self.spat_bgl});
            defer gctx.releaseResource(spl);
            const smod = try cache.getOrLoad("assets/shaders/ssgi_spatial.wgsl");
            defer smod.release();
            const targets = [_]wgpu.ColorTargetState{.{ .format = .rgba16_float }};
            self.spat_pipeline = gctx.createRenderPipeline(spl, .{
                .vertex = .{ .module = smod, .entry_point = "vs_main" },
                .primitive = .{ .front_face = .ccw, .cull_mode = .none, .topology = .triangle_list },
                .fragment = &wgpu.FragmentState{
                    .module = smod,
                    .entry_point = "fs_main",
                    .target_count = targets.len,
                    .targets = &targets,
                },
            });
        }

        self.white_tex = gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .dimension = .tdim_2d,
            .size = .{ .width = 1, .height = 1, .depth_or_array_layers = 1 },
            .format = .r32_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        self.white_view = gctx.createTextureView(self.white_tex, .{});
        const far: f32 = 1.0;
        gctx.queue.writeTexture(
            .{ .texture = gctx.lookupResource(self.white_tex).?, .mip_level = 0, .origin = .{}, .aspect = .all },
            .{ .offset = 0, .bytes_per_row = 256, .rows_per_image = 1 },
            .{ .width = 1, .height = 1, .depth_or_array_layers = 1 },
            f32,
            &[_]f32{far},
        );

        self.apply_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(3, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(4, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(5, .{ .fragment = true }, .depth, .tvdim_2d, false),
            zgpu.textureEntry(6, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(7, .{ .fragment = true }, .float, .tvdim_2d, false),
        });
        const apply_pl = gctx.createPipelineLayout(&.{self.apply_bgl});
        defer gctx.releaseResource(apply_pl);
        {
            const amod = try cache.getOrLoad("assets/shaders/ssgi_apply.wgsl");
            defer amod.release();
            const blend = wgpu.BlendState{
                .color = .{ .operation = .add, .src_factor = .one, .dst_factor = .one },
                .alpha = .{ .operation = .add, .src_factor = .one, .dst_factor = .one },
            };
            const atargets = [_]wgpu.ColorTargetState{.{
                .format = .rgba16_float,
                .blend = &blend,
                .write_mask = .all,
            }};
            self.apply_pipeline = gctx.createRenderPipeline(apply_pl, .{
                .vertex = .{ .module = amod, .entry_point = "vs_main" },
                .primitive = .{ .front_face = .ccw, .cull_mode = .none, .topology = .triangle_list },
                .fragment = &wgpu.FragmentState{
                    .module = amod,
                    .entry_point = "fs_main",
                    .target_count = atargets.len,
                    .targets = &atargets,
                },
            });
        }

        self.resize(gctx);
        self.ready = true;
        log.info(.render, "GI Phase B: screen probes tile={d} (SSGI irradiance)", .{tile_size});
        return self;
    }

    pub fn resize(self: *System, gctx: *zgpu.GraphicsContext) void {
        const fw = @max(gctx.swapchain_descriptor.width, 1);
        const fh = @max(gctx.swapchain_descriptor.height, 1);
        const w = @max((fw + tile_size - 1) / tile_size, 1);
        const h = @max((fh + tile_size - 1) / tile_size, 1);
        if (w == self.w and h == self.h and gctx.isResourceValid(self.final_tex)) return;

        if (gctx.isResourceValid(self.final_view)) gctx.releaseResource(self.final_view);
        if (gctx.isResourceValid(self.hist_view)) gctx.releaseResource(self.hist_view);
        if (gctx.isResourceValid(self.spat_view)) gctx.releaseResource(self.spat_view);
        if (gctx.isResourceValid(self.final_tex)) gctx.destroyResource(self.final_tex);
        if (gctx.isResourceValid(self.hist_tex)) gctx.destroyResource(self.hist_tex);
        if (gctx.isResourceValid(self.spat_tex)) gctx.destroyResource(self.spat_tex);

        self.w = w;
        self.h = h;
        self.final_tex = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true, .copy_src = true },
            .dimension = .tdim_2d,
            .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        self.final_view = gctx.createTextureView(self.final_tex, .{});
        self.hist_tex = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true, .copy_dst = true },
            .dimension = .tdim_2d,
            .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        self.hist_view = gctx.createTextureView(self.hist_tex, .{});
        self.spat_tex = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true, .copy_src = true },
            .dimension = .tdim_2d,
            .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        self.spat_view = gctx.createTextureView(self.spat_tex, .{});
        self.needs_clear = true;
        self.warm_frames = 0;
    }

    pub fn destroy(self: *System, gctx: *zgpu.GraphicsContext) void {
        if (gctx.isResourceValid(self.bg)) gctx.releaseResource(self.bg);
        if (gctx.isResourceValid(self.spat_bg)) gctx.releaseResource(self.spat_bg);
        if (gctx.isResourceValid(self.apply_bg)) gctx.releaseResource(self.apply_bg);
        if (gctx.isResourceValid(self.final_view)) gctx.releaseResource(self.final_view);
        if (gctx.isResourceValid(self.hist_view)) gctx.releaseResource(self.hist_view);
        if (gctx.isResourceValid(self.spat_view)) gctx.releaseResource(self.spat_view);
        if (gctx.isResourceValid(self.white_view)) gctx.releaseResource(self.white_view);
        if (gctx.isResourceValid(self.final_tex)) gctx.destroyResource(self.final_tex);
        if (gctx.isResourceValid(self.hist_tex)) gctx.destroyResource(self.hist_tex);
        if (gctx.isResourceValid(self.spat_tex)) gctx.destroyResource(self.spat_tex);
        if (gctx.isResourceValid(self.white_tex)) gctx.destroyResource(self.white_tex);
        if (gctx.isResourceValid(self.sampler)) gctx.releaseResource(self.sampler);
        self.* = .{};
    }

    pub fn outputView(self: *const System) zgpu.TextureViewHandle {
        return self.spat_view;
    }

    pub fn setHzb(self: *System, view: zgpu.TextureViewHandle) void {
        self.hzb_view = view;
    }

    pub fn rebuildBindGroup(
        self: *System,
        gctx: *zgpu.GraphicsContext,
        depth_view: zgpu.TextureViewHandle,
        normal_view: zgpu.TextureViewHandle,
        albedo_view: zgpu.TextureViewHandle,
        material_view: zgpu.TextureViewHandle,
        gtao_view: zgpu.TextureViewHandle,
        prev_hdr_view: zgpu.TextureViewHandle,
        env_cube_view: zgpu.TextureViewHandle,
        env_sampler: zgpu.SamplerHandle,
    ) void {
        if (!self.ready) return;
        self.resize(gctx);
        if (gctx.isResourceValid(self.bg)) gctx.releaseResource(self.bg);
        if (gctx.isResourceValid(self.spat_bg)) gctx.releaseResource(self.spat_bg);
        if (gctx.isResourceValid(self.apply_bg)) gctx.releaseResource(self.apply_bg);
        const hzb = if (gctx.isResourceValid(self.hzb_view)) self.hzb_view else self.white_view;
        self.bg = gctx.createBindGroup(self.bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(GpuUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = depth_view },
            .{ .binding = 3, .texture_view_handle = normal_view },
            .{ .binding = 4, .texture_view_handle = albedo_view },
            .{ .binding = 5, .texture_view_handle = self.hist_view },
            .{ .binding = 6, .texture_view_handle = prev_hdr_view },
            .{ .binding = 7, .texture_view_handle = env_cube_view },
            .{ .binding = 8, .sampler_handle = env_sampler },
            .{ .binding = 9, .texture_view_handle = hzb },
        });
        self.spat_bg = gctx.createBindGroup(self.spat_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(ApplyUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.final_view },
            .{ .binding = 3, .texture_view_handle = depth_view },
            .{ .binding = 4, .texture_view_handle = normal_view },
        });
        self.apply_bg = gctx.createBindGroup(self.apply_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(ApplyUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = albedo_view },
            .{ .binding = 3, .texture_view_handle = normal_view },
            .{ .binding = 4, .texture_view_handle = material_view },
            .{ .binding = 5, .texture_view_handle = depth_view },
            .{ .binding = 6, .texture_view_handle = gtao_view },
            .{ .binding = 7, .texture_view_handle = self.spat_view },
        });
    }

    pub fn draw(
        self: *System,
        gctx: *zgpu.GraphicsContext,
        encoder: wgpu.CommandEncoder,
        cam_pos: [3]f32,
        inv_view_proj: zm.Mat,
        view_proj: zm.Mat,
        sun_dir: [3]f32,
        sun_color: [3]f32,
        sun_intensity: f32,
        ambient_boost: f32,
        cam_near: f32,
        cam_far: f32,
        fb_w: u32,
        fb_h: u32,
    ) void {
        if (!self.ready or !self.params.enabled) return;
        if (!gctx.isResourceValid(self.bg) or !gctx.isResourceValid(self.final_view)) return;

        const pipeline = gctx.lookupResource(self.pipeline) orelse return;
        const bind_group = gctx.lookupResource(self.bg) orelse return;
        const tv = gctx.lookupResource(self.final_view) orelse return;

        const load_op: wgpu.LoadOp = if (self.needs_clear) .clear else .load;
        self.needs_clear = false;

        {
            const color = [_]wgpu.RenderPassColorAttachment{.{
                .view = tv,
                .load_op = load_op,
                .store_op = .store,
                .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
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

            var sd = sun_dir;
            const slen = @sqrt(sd[0] * sd[0] + sd[1] * sd[1] + sd[2] * sd[2]);
            if (slen > 1e-5) {
                sd[0] /= slen;
                sd[1] /= slen;
                sd[2] /= slen;
            }

            const mem = gctx.uniformsAllocate(GpuUniforms, 1);
            mem.slice[0] = .{
                .inv_view_proj = zm.transpose(inv_view_proj),
                .view_proj = zm.transpose(view_proj),
                .screen = .{ @floatFromInt(fb_w), @floatFromInt(fb_h), cam_near, cam_far },
                .params = .{
                    self.params.temporal,
                    0,
                    @floatFromInt(self.frame),
                    @floatFromInt(tile_size),
                },
                .budget = .{
                    self.params.ray_steps,
                    self.params.max_ray_m,
                    1,
                    self.params.rays,
                },
                .sun_dir = .{ sd[0], sd[1], sd[2], 0 },
                .sun_color = .{
                    sun_color[0] * sun_intensity,
                    sun_color[1] * sun_intensity,
                    sun_color[2] * sun_intensity,
                    ambient_boost,
                },
                .camera_pos = .{ cam_pos[0], cam_pos[1], cam_pos[2], 1 },
            };
            pass.setBindGroup(0, bind_group, &.{mem.offset});
            pass.draw(3, 1, 0, 0);
        }

        // Spatial filter → spat
        {
            const spipe = gctx.lookupResource(self.spat_pipeline) orelse return;
            const sbg = gctx.lookupResource(self.spat_bg) orelse return;
            const stv = gctx.lookupResource(self.spat_view) orelse return;
            const color = [_]wgpu.RenderPassColorAttachment{.{
                .view = stv,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            }};
            const pass = encoder.beginRenderPass(.{
                .color_attachment_count = color.len,
                .color_attachments = &color,
            });
            defer {
                pass.end();
                pass.release();
            }
            pass.setPipeline(spipe);
            const mem = gctx.uniformsAllocate(ApplyUniforms, 1);
            mem.slice[0] = .{
                .inv_view_proj = zm.transpose(inv_view_proj),
                .params = .{ 1, 0, 0, 0 },
            };
            pass.setBindGroup(0, sbg, &.{mem.offset});
            pass.draw(3, 1, 0, 0);
        }

        const src = gctx.lookupResource(self.spat_tex) orelse return;
        const dst = gctx.lookupResource(self.hist_tex) orelse return;
        encoder.copyTextureToTexture(
            .{ .texture = src },
            .{ .texture = dst },
            .{ .width = self.w, .height = self.h, .depth_or_array_layers = 1 },
        );
        self.frame +%= 1;
        self.warm_frames +%= 1;
    }

    pub fn apply(
        self: *System,
        gctx: *zgpu.GraphicsContext,
        encoder: wgpu.CommandEncoder,
        hdr_view: zgpu.TextureViewHandle,
        inv_view_proj: zm.Mat,
    ) void {
        if (!self.ready or !self.params.enabled) return;
        if (self.warm_frames < 4) return;
        const pipeline = gctx.lookupResource(self.apply_pipeline) orelse return;
        const bind_group = gctx.lookupResource(self.apply_bg) orelse return;
        const tv = gctx.lookupResource(hdr_view) orelse return;

        const color = [_]wgpu.RenderPassColorAttachment{.{
            .view = tv,
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
        const mem = gctx.uniformsAllocate(ApplyUniforms, 1);
        mem.slice[0] = .{
            .inv_view_proj = zm.transpose(inv_view_proj),
            .params = .{
                self.params.intensity,
                1,
                self.params.blend,
                @floatFromInt(tile_size),
            },
        };
        pass.setBindGroup(0, bind_group, &.{mem.offset});
        pass.draw(3, 1, 0, 0);
    }
};

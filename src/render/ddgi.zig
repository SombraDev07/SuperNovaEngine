const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zm = @import("zmath");
const shader = @import("shader.zig");
const log = @import("../core/log.zig");

/// Phase A+C GI — daGI2 RadianceGrid irradiance role (WebGPU).
/// Octa irradiance + distance (Chebyshev), multi-clip cascade, budgeted update.
/// Phase B = screen probes (ssgi). Full WorldSDF = next depth pass.
pub const grid_x: u32 = 8;
pub const grid_y: u32 = 6;
pub const grid_z: u32 = 8;
pub const octa_res: u32 = 8;
pub const clips: u32 = 3;

pub const Params = struct {
    enabled: bool = true,
    intensity: f32 = 1.15,
    spacing: f32 = 2.0,
    temporal_blend: f32 = 0.88,
    max_dist_scale: f32 = 1.6,
    probe_blend: f32 = 0.8,
    /// Probes updated per frame (Dagor select_temporal budget).
    probes_per_frame: f32 = 64,
    max_steps: f32 = 20,
};

pub const GpuUniforms = extern struct {
    inv_view_proj: zm.Mat,
    view_proj: zm.Mat,
    view: zm.Mat,
    /// clip0: xyz origin, w spacing
    origin_spacing: [4]f32,
    /// clip1 / clip2 origins + spacing in w
    origin1: [4]f32,
    origin2: [4]f32,
    grid_octa: [4]f32,
    params: [4]f32,
    sun_dir: [4]f32,
    sun_color: [4]f32,
    screen: [4]f32,
    camera_pos: [4]f32,
    /// x=probes_per_frame, y=max_steps, z=enabled, w=clips
    budget: [4]f32,
    vol_clip0: [4]f32 = .{ 0, 0, 0, 0.28 },
    vol_clip1: [4]f32 = .{ 0, 0, 0, 0.56 },
    vol_clip2: [4]f32 = .{ 0, 0, 0, 1.12 },
    vol_clip3: [4]f32 = .{ 0, 0, 0, 2.24 },
    vol_dims: [4]f32 = .{ 64, 32, 4, 512 },
    vol_atlas: [4]f32 = .{ 1024, 8, 4, 0 },
};

pub const ApplyUniforms = extern struct {
    inv_view_proj: zm.Mat,
    /// xyz origin0, w intensity
    origin: [4]f32,
    origin1: [4]f32,
    origin2: [4]f32,
    /// x=spacing0, yzx = grid counts
    grid: [4]f32,
    /// x=octa, y=enabled, z=blend, w=clips
    params: [4]f32,
    camera_pos: [4]f32,
};

pub const System = struct {
    params: Params = .{},
    ready: bool = false,
    frame: u32 = 0,
    atlas_needs_clear: bool = true,

    atlas_w: u32 = 0,
    atlas_h: u32 = 0,
    origin: [3]f32 = .{ 0, 0, 0 },
    origins: [clips][3]f32 = .{.{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }},
    prev_cam: [3]f32 = .{ 0, 0, 0 },
    has_prev_cam: bool = false,

    /// WorldSDF / lit / albedo atlas views (bound each rebuild; white if unavailable).
    vol_sdf_view: zgpu.TextureViewHandle = .{},
    vol_lit_view: zgpu.TextureViewHandle = .{},
    vol_alb_view: zgpu.TextureViewHandle = .{},
    vol_clip0: [4]f32 = .{ 0, 0, 0, 0.28 },
    vol_clip1: [4]f32 = .{ 0, 0, 0, 0.56 },
    vol_clip2: [4]f32 = .{ 0, 0, 0, 1.12 },
    vol_clip3: [4]f32 = .{ 0, 0, 0, 2.24 },
    vol_dims: [4]f32 = .{ 64, 32, 4, 512 },
    vol_atlas: [4]f32 = .{ 1024, 8, 4, 0 },

    final_irr_tex: zgpu.TextureHandle = .{},
    final_irr_view: zgpu.TextureViewHandle = .{},
    final_dist_tex: zgpu.TextureHandle = .{},
    final_dist_view: zgpu.TextureViewHandle = .{},
    hist_irr_tex: zgpu.TextureHandle = .{},
    hist_irr_view: zgpu.TextureViewHandle = .{},
    hist_dist_tex: zgpu.TextureHandle = .{},
    hist_dist_view: zgpu.TextureViewHandle = .{},

    prev_hdr_tex: zgpu.TextureHandle = .{},
    prev_hdr_view: zgpu.TextureViewHandle = .{},
    prev_hdr_w: u32 = 0,
    prev_hdr_h: u32 = 0,
    has_prev_hdr: bool = false,

    white_tex: zgpu.TextureHandle = .{},
    white_view: zgpu.TextureViewHandle = .{},

    sampler: zgpu.SamplerHandle = .{},
    pipeline: zgpu.RenderPipelineHandle = .{},
    bgl: zgpu.BindGroupLayoutHandle = .{},
    bg: zgpu.BindGroupHandle = .{},

    apply_pipeline: zgpu.RenderPipelineHandle = .{},
    apply_bgl: zgpu.BindGroupLayoutHandle = .{},
    apply_bg: zgpu.BindGroupHandle = .{},

    pub fn atlasWidth() u32 {
        return grid_x * octa_res;
    }
    pub fn atlasHeight() u32 {
        return clips * grid_y * grid_z * octa_res;
    }
    pub fn clipAtlasHeight() u32 {
        return grid_y * grid_z * octa_res;
    }
    pub fn spacingForClip(base: f32, clip: u32) f32 {
        var s = base;
        var i: u32 = 0;
        while (i < clip) : (i += 1) s *= 2.0;
        return s;
    }

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
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        self.white_view = gctx.createTextureView(self.white_tex, .{});
        const white_px = [_]u16{ 0, 0, 0, 0x3C00 };
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

        self.bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .depth, .tvdim_2d, false),
            zgpu.textureEntry(3, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(4, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(5, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(6, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(7, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(8, .{ .fragment = true }, .float, .tvdim_cube, false),
            zgpu.samplerEntry(9, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(10, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(11, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(12, .{ .fragment = true }, .float, .tvdim_2d, false),
        });

        const pl = gctx.createPipelineLayout(&.{self.bgl});
        defer gctx.releaseResource(pl);
        {
            const module = try cache.getOrLoad("assets/shaders/ddgi_update.wgsl");
            defer module.release();
            const targets = [_]wgpu.ColorTargetState{
                .{ .format = .rgba16_float },
                .{ .format = .rg16_float },
            };
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

        self.apply_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(3, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(4, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(5, .{ .fragment = true }, .depth, .tvdim_2d, false),
            zgpu.textureEntry(6, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(7, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(8, .{ .fragment = true }, .float, .tvdim_2d, false),
        });
        const apply_pl = gctx.createPipelineLayout(&.{self.apply_bgl});
        defer gctx.releaseResource(apply_pl);
        {
            const amod = try cache.getOrLoad("assets/shaders/ddgi_apply.wgsl");
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

        self.ensureAtlas(gctx);
        self.ready = true;
        log.info(.render, "GI Phase A+C: {d}x{d}x{d} octa={d} clips={d} atlas {d}x{d}", .{
            grid_x,       grid_y,        grid_z, octa_res, clips,
            atlasWidth(), atlasHeight(),
        });
        return self;
    }

    fn makeTex(gctx: *zgpu.GraphicsContext, w: u32, h: u32, format: wgpu.TextureFormat) struct { zgpu.TextureHandle, zgpu.TextureViewHandle } {
        const tex = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true, .copy_src = true, .copy_dst = true },
            .dimension = .tdim_2d,
            .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
            .format = format,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        return .{ tex, gctx.createTextureView(tex, .{}) };
    }

    fn ensureAtlas(self: *System, gctx: *zgpu.GraphicsContext) void {
        const w = atlasWidth();
        const h = atlasHeight();
        if (w == self.atlas_w and h == self.atlas_h and gctx.isResourceValid(self.final_irr_tex)) return;
        inline for (.{
            &self.final_irr_view, &self.final_dist_view, &self.hist_irr_view, &self.hist_dist_view,
        }) |v| {
            if (gctx.isResourceValid(v.*)) gctx.releaseResource(v.*);
            v.* = .{};
        }
        inline for (.{
            &self.final_irr_tex, &self.final_dist_tex, &self.hist_irr_tex, &self.hist_dist_tex,
        }) |t| {
            if (gctx.isResourceValid(t.*)) gctx.destroyResource(t.*);
            t.* = .{};
        }
        self.atlas_w = w;
        self.atlas_h = h;
        const fi = makeTex(gctx, w, h, .rgba16_float);
        self.final_irr_tex = fi[0];
        self.final_irr_view = fi[1];
        const fd = makeTex(gctx, w, h, .rg16_float);
        self.final_dist_tex = fd[0];
        self.final_dist_view = fd[1];
        const hi = makeTex(gctx, w, h, .rgba16_float);
        self.hist_irr_tex = hi[0];
        self.hist_irr_view = hi[1];
        const hd = makeTex(gctx, w, h, .rg16_float);
        self.hist_dist_tex = hd[0];
        self.hist_dist_view = hd[1];
        self.atlas_needs_clear = true;
    }

    pub fn ensurePrevHdr(self: *System, gctx: *zgpu.GraphicsContext) void {
        const w = @max(gctx.swapchain_descriptor.width, 1);
        const h = @max(gctx.swapchain_descriptor.height, 1);
        if (w == self.prev_hdr_w and h == self.prev_hdr_h and gctx.isResourceValid(self.prev_hdr_tex)) return;
        if (gctx.isResourceValid(self.prev_hdr_view)) gctx.releaseResource(self.prev_hdr_view);
        if (gctx.isResourceValid(self.prev_hdr_tex)) gctx.destroyResource(self.prev_hdr_tex);
        self.prev_hdr_w = w;
        self.prev_hdr_h = h;
        self.prev_hdr_tex = gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .dimension = .tdim_2d,
            .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        self.prev_hdr_view = gctx.createTextureView(self.prev_hdr_tex, .{});
        self.has_prev_hdr = false;
    }

    pub fn destroy(self: *System, gctx: *zgpu.GraphicsContext) void {
        if (gctx.isResourceValid(self.bg)) gctx.releaseResource(self.bg);
        if (gctx.isResourceValid(self.apply_bg)) gctx.releaseResource(self.apply_bg);
        inline for (.{
            &self.final_irr_view, &self.final_dist_view, &self.hist_irr_view, &self.hist_dist_view,
            &self.prev_hdr_view,  &self.white_view,
        }) |v| {
            if (gctx.isResourceValid(v.*)) gctx.releaseResource(v.*);
        }
        inline for (.{
            &self.final_irr_tex, &self.final_dist_tex, &self.hist_irr_tex, &self.hist_dist_tex,
            &self.prev_hdr_tex,  &self.white_tex,
        }) |t| {
            if (gctx.isResourceValid(t.*)) gctx.destroyResource(t.*);
        }
        if (gctx.isResourceValid(self.sampler)) gctx.releaseResource(self.sampler);
        self.* = .{};
    }

    pub fn outputView(self: *const System) zgpu.TextureViewHandle {
        if (!self.ready) return self.white_view;
        return self.final_irr_view;
    }

    pub fn distView(self: *const System) zgpu.TextureViewHandle {
        if (!self.ready) return self.white_view;
        return self.final_dist_view;
    }

    pub fn updateOrigin(self: *System, cam_pos: [3]f32) void {
        // Frustum / teleport invalidation (daGI2 invalidateFrustum role).
        if (self.has_prev_cam) {
            const dx = cam_pos[0] - self.prev_cam[0];
            const dy = cam_pos[1] - self.prev_cam[1];
            const dz = cam_pos[2] - self.prev_cam[2];
            const dist2 = dx * dx + dy * dy + dz * dz;
            if (dist2 > 25.0) self.atlas_needs_clear = true;
        }
        self.prev_cam = cam_pos;
        self.has_prev_cam = true;

        var c: u32 = 0;
        while (c < clips) : (c += 1) {
            const sp = spacingForClip(self.params.spacing, c);
            const hx = 0.5 * @as(f32, @floatFromInt(grid_x - 1)) * sp;
            const hy = 0.5 * @as(f32, @floatFromInt(grid_y - 1)) * sp;
            const hz = 0.5 * @as(f32, @floatFromInt(grid_z - 1)) * sp;
            self.origins[c] = .{
                @floor((cam_pos[0] - hx) / sp) * sp,
                @floor((cam_pos[1] - hy) / sp) * sp,
                @floor((cam_pos[2] - hz) / sp) * sp,
            };
        }
        self.origin = self.origins[0];
    }

    pub fn setVolume(
        self: *System,
        sdf_view: zgpu.TextureViewHandle,
        lit_view: zgpu.TextureViewHandle,
        alb_view: zgpu.TextureViewHandle,
        clip0: [4]f32,
        clip1: [4]f32,
        clip2: [4]f32,
        clip3: [4]f32,
        dims: [4]f32,
        atlas: [4]f32,
    ) void {
        self.vol_sdf_view = sdf_view;
        self.vol_lit_view = lit_view;
        self.vol_alb_view = alb_view;
        self.vol_clip0 = clip0;
        self.vol_clip1 = clip1;
        self.vol_clip2 = clip2;
        self.vol_clip3 = clip3;
        self.vol_dims = dims;
        self.vol_atlas = atlas;
    }

    pub fn rebuildBindGroup(
        self: *System,
        gctx: *zgpu.GraphicsContext,
        depth_view: zgpu.TextureViewHandle,
        albedo_view: zgpu.TextureViewHandle,
        normal_view: zgpu.TextureViewHandle,
        material_view: zgpu.TextureViewHandle,
        gtao_view: zgpu.TextureViewHandle,
        env_cube_view: zgpu.TextureViewHandle,
        env_sampler: zgpu.SamplerHandle,
    ) void {
        if (!self.ready) return;
        self.ensureAtlas(gctx);
        self.ensurePrevHdr(gctx);
        if (gctx.isResourceValid(self.bg)) gctx.releaseResource(self.bg);
        if (gctx.isResourceValid(self.apply_bg)) gctx.releaseResource(self.apply_bg);
        const prev_view = if (gctx.isResourceValid(self.prev_hdr_view)) self.prev_hdr_view else self.white_view;
        const sdf_v = if (gctx.isResourceValid(self.vol_sdf_view)) self.vol_sdf_view else self.white_view;
        const lit_v = if (gctx.isResourceValid(self.vol_lit_view)) self.vol_lit_view else self.white_view;
        const alb_v = if (gctx.isResourceValid(self.vol_alb_view)) self.vol_alb_view else self.white_view;
        self.bg = gctx.createBindGroup(self.bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(GpuUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = depth_view },
            .{ .binding = 3, .texture_view_handle = albedo_view },
            .{ .binding = 4, .texture_view_handle = normal_view },
            .{ .binding = 5, .texture_view_handle = self.hist_irr_view },
            .{ .binding = 6, .texture_view_handle = self.hist_dist_view },
            .{ .binding = 7, .texture_view_handle = prev_view },
            .{ .binding = 8, .texture_view_handle = env_cube_view },
            .{ .binding = 9, .sampler_handle = env_sampler },
            .{ .binding = 10, .texture_view_handle = sdf_v },
            .{ .binding = 11, .texture_view_handle = lit_v },
            .{ .binding = 12, .texture_view_handle = alb_v },
        });
        self.apply_bg = gctx.createBindGroup(self.apply_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(ApplyUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = albedo_view },
            .{ .binding = 3, .texture_view_handle = normal_view },
            .{ .binding = 4, .texture_view_handle = material_view },
            .{ .binding = 5, .texture_view_handle = depth_view },
            .{ .binding = 6, .texture_view_handle = gtao_view },
            .{ .binding = 7, .texture_view_handle = self.final_irr_view },
            .{ .binding = 8, .texture_view_handle = self.final_dist_view },
        });
    }

    pub fn apply(
        self: *System,
        gctx: *zgpu.GraphicsContext,
        encoder: wgpu.CommandEncoder,
        hdr_view: zgpu.TextureViewHandle,
        inv_view_proj: zm.Mat,
        cam_pos: [3]f32,
    ) void {
        if (!self.ready or !self.params.enabled) return;
        const pack = self.packing();
        if (pack.params[1] < 0.5) return;
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
            .origin = pack.origin,
            .origin1 = pack.origin1,
            .origin2 = pack.origin2,
            .grid = pack.grid,
            .params = pack.params,
            .camera_pos = .{ cam_pos[0], cam_pos[1], cam_pos[2], 1 },
        };
        pass.setBindGroup(0, bind_group, &.{mem.offset});
        pass.draw(3, 1, 0, 0);
    }

    pub fn draw(
        self: *System,
        gctx: *zgpu.GraphicsContext,
        encoder: wgpu.CommandEncoder,
        cam_pos: [3]f32,
        view: zm.Mat,
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
        if (!gctx.isResourceValid(self.bg) or !gctx.isResourceValid(self.final_irr_view)) return;
        self.updateOrigin(cam_pos);

        const pipeline = gctx.lookupResource(self.pipeline) orelse return;
        const bind_group = gctx.lookupResource(self.bg) orelse return;
        const irr_tv = gctx.lookupResource(self.final_irr_view) orelse return;
        const dist_tv = gctx.lookupResource(self.final_dist_view) orelse return;

        const load_op: wgpu.LoadOp = if (self.atlas_needs_clear) .clear else .load;
        self.atlas_needs_clear = false;

        {
            const color = [_]wgpu.RenderPassColorAttachment{
                .{
                    .view = irr_tv,
                    .load_op = load_op,
                    .store_op = .store,
                    .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
                },
                .{
                    .view = dist_tv,
                    .load_op = load_op,
                    .store_op = .store,
                    .clear_value = .{ .r = 1, .g = 1, .b = 0, .a = 1 },
                },
            };
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

            const sp0 = spacingForClip(self.params.spacing, 0);
            const sp1 = spacingForClip(self.params.spacing, 1);
            const sp2 = spacingForClip(self.params.spacing, 2);
            const mem = gctx.uniformsAllocate(GpuUniforms, 1);
            mem.slice[0] = .{
                .inv_view_proj = zm.transpose(inv_view_proj),
                .view_proj = zm.transpose(view_proj),
                .view = zm.transpose(view),
                .origin_spacing = .{ self.origins[0][0], self.origins[0][1], self.origins[0][2], sp0 },
                .origin1 = .{ self.origins[1][0], self.origins[1][1], self.origins[1][2], sp1 },
                .origin2 = .{ self.origins[2][0], self.origins[2][1], self.origins[2][2], sp2 },
                .grid_octa = .{
                    @floatFromInt(grid_x),
                    @floatFromInt(grid_y),
                    @floatFromInt(grid_z),
                    @floatFromInt(octa_res),
                },
                .params = .{
                    self.params.temporal_blend,
                    self.params.max_dist_scale,
                    @floatFromInt(self.frame),
                    sun_intensity,
                },
                .sun_dir = .{ sd[0], sd[1], sd[2], 0 },
                .sun_color = .{
                    sun_color[0] * sun_intensity,
                    sun_color[1] * sun_intensity,
                    sun_color[2] * sun_intensity,
                    ambient_boost,
                },
                .screen = .{
                    @floatFromInt(fb_w),
                    @floatFromInt(fb_h),
                    cam_near,
                    cam_far,
                },
                .camera_pos = .{ cam_pos[0], cam_pos[1], cam_pos[2], 1 },
                .budget = .{
                    self.params.probes_per_frame,
                    self.params.max_steps,
                    1,
                    @floatFromInt(clips),
                },
                .vol_clip0 = self.vol_clip0,
                .vol_clip1 = self.vol_clip1,
                .vol_clip2 = self.vol_clip2,
                .vol_clip3 = self.vol_clip3,
                .vol_dims = self.vol_dims,
                .vol_atlas = self.vol_atlas,
            };
            pass.setBindGroup(0, bind_group, &.{mem.offset});
            pass.draw(3, 1, 0, 0);
        }

        // After pass ends: finals → history for next frame.
        const src_i = gctx.lookupResource(self.final_irr_tex) orelse return;
        const dst_i = gctx.lookupResource(self.hist_irr_tex) orelse return;
        const src_d = gctx.lookupResource(self.final_dist_tex) orelse return;
        const dst_d = gctx.lookupResource(self.hist_dist_tex) orelse return;
        encoder.copyTextureToTexture(
            .{ .texture = src_i },
            .{ .texture = dst_i },
            .{ .width = self.atlas_w, .height = self.atlas_h, .depth_or_array_layers = 1 },
        );
        encoder.copyTextureToTexture(
            .{ .texture = src_d },
            .{ .texture = dst_d },
            .{ .width = self.atlas_w, .height = self.atlas_h, .depth_or_array_layers = 1 },
        );
        self.frame +%= 1;
    }

    pub fn captureHdr(
        self: *System,
        gctx: *zgpu.GraphicsContext,
        encoder: wgpu.CommandEncoder,
        hdr_tex: zgpu.TextureHandle,
    ) void {
        if (!self.ready or !self.params.enabled) return;
        if (!gctx.isResourceValid(self.prev_hdr_tex)) return;
        const src = gctx.lookupResource(hdr_tex) orelse return;
        const dst = gctx.lookupResource(self.prev_hdr_tex) orelse return;
        const w = @min(self.prev_hdr_w, gctx.swapchain_descriptor.width);
        const h = @min(self.prev_hdr_h, gctx.swapchain_descriptor.height);
        if (w == 0 or h == 0) return;
        encoder.copyTextureToTexture(
            .{ .texture = src },
            .{ .texture = dst },
            .{ .width = w, .height = h, .depth_or_array_layers = 1 },
        );
        self.has_prev_hdr = true;
    }

    pub fn packing(self: *const System) struct {
        origin: [4]f32,
        origin1: [4]f32,
        origin2: [4]f32,
        grid: [4]f32,
        params: [4]f32,
    } {
        const warmed = self.ready and self.params.enabled and self.has_prev_hdr and self.frame > 16;
        const en: f32 = if (warmed) 1.0 else 0.0;
        const sp0 = spacingForClip(self.params.spacing, 0);
        const sp1 = spacingForClip(self.params.spacing, 1);
        const sp2 = spacingForClip(self.params.spacing, 2);
        return .{
            .origin = .{ self.origins[0][0], self.origins[0][1], self.origins[0][2], self.params.intensity },
            .origin1 = .{ self.origins[1][0], self.origins[1][1], self.origins[1][2], sp1 },
            .origin2 = .{ self.origins[2][0], self.origins[2][1], self.origins[2][2], sp2 },
            .grid = .{
                sp0,
                @floatFromInt(grid_x),
                @floatFromInt(grid_y),
                @floatFromInt(grid_z),
            },
            .params = .{ @floatFromInt(octa_res), en, self.params.probe_blend, @floatFromInt(clips) },
        };
    }
};

test "ddgi atlas size phase A+C" {
    try std.testing.expectEqual(@as(u32, 64), System.atlasWidth());
    try std.testing.expectEqual(@as(u32, 1152), System.atlasHeight());
}

const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zm = @import("zmath");
const shader = @import("shader.zig");
const log = @import("../core/log.zig");

/// daGI2 WorldSDF + lit + albedo voxel scenes (gbuffer fill, JFA, removeFromDepth).
pub const res_xz: u32 = 64;
pub const res_y: u32 = 32;
pub const clips: u32 = 4;
pub const slices_per_row: u32 = 8;
pub const band_voxels: f32 = 4.0;

pub const Params = struct {
    enabled: bool = true,
    voxel0: f32 = 0.28,
    mark_budget: f32 = 4.5,
    lit_budget: f32 = 3.5,
    albedo_budget: f32 = 3.0,
    remove_budget: f32 = 2.5,
    lit_temporal: f32 = 0.9,
    jfa_enabled: bool = true,
};

pub fn voxelCount() u32 {
    return res_xz * res_y * res_xz * clips;
}
pub fn atlasWidth() u32 {
    return res_xz * slices_per_row;
}
pub fn atlasHeight() u32 {
    const slices = res_xz * clips;
    const rows = (slices + slices_per_row - 1) / slices_per_row;
    return res_y * rows;
}

const SdfMarkUniforms = extern struct {
    inv_view_proj: zm.Mat,
    clip0: [4]f32,
    clip1: [4]f32,
    clip2: [4]f32,
    clip3: [4]f32,
    dims: [4]f32,
    screen: [4]f32,
};
const JfaUniforms = extern struct {
    dims: [4]f32,
    params: [4]f32,
};
const RemoveUniforms = extern struct {
    view_proj: zm.Mat,
    clip0: [4]f32,
    clip1: [4]f32,
    clip2: [4]f32,
    clip3: [4]f32,
    dims: [4]f32,
    screen: [4]f32,
};
const AtlasUniforms = extern struct {
    dims: [4]f32,
    atlas: [4]f32,
};
const LitMarkUniforms = extern struct {
    inv_view_proj: zm.Mat,
    view_proj: zm.Mat,
    clip0: [4]f32,
    clip1: [4]f32,
    clip2: [4]f32,
    clip3: [4]f32,
    dims: [4]f32,
    screen: [4]f32,
    sun_dir: [4]f32,
    sun_color: [4]f32,
};
const LitAtlasUniforms = extern struct {
    dims: [4]f32,
    atlas: [4]f32,
    params: [4]f32,
};
const AlbedoMarkUniforms = extern struct {
    inv_view_proj: zm.Mat,
    clip0: [4]f32,
    clip1: [4]f32,
    clip2: [4]f32,
    clip3: [4]f32,
    dims: [4]f32,
    screen: [4]f32,
};

pub const System = struct {
    allocator: std.mem.Allocator = undefined,
    params: Params = .{},
    ready: bool = false,
    frame: u32 = 0,
    /// 0 = sdf_buf is current after JFA; 1 = sdf_ping
    sdf_read: u32 = 0,
    origins: [clips][3]f32 = .{.{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }},
    prev_origins: [clips][3]f32 = .{.{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }},
    has_prev_origin: bool = false,

    sdf_buf: zgpu.BufferHandle = .{},
    sdf_ping: zgpu.BufferHandle = .{},
    lit_rgb_buf: zgpu.BufferHandle = .{},
    lit_w_buf: zgpu.BufferHandle = .{},
    alb_rgb_buf: zgpu.BufferHandle = .{},
    alb_w_buf: zgpu.BufferHandle = .{},

    sdf_atlas: zgpu.TextureHandle = .{},
    sdf_atlas_view: zgpu.TextureViewHandle = .{},
    lit_atlas: zgpu.TextureHandle = .{},
    lit_atlas_view: zgpu.TextureViewHandle = .{},
    lit_hist: zgpu.TextureHandle = .{},
    lit_hist_view: zgpu.TextureViewHandle = .{},
    alb_atlas: zgpu.TextureHandle = .{},
    alb_atlas_view: zgpu.TextureViewHandle = .{},
    alb_hist: zgpu.TextureHandle = .{},
    alb_hist_view: zgpu.TextureViewHandle = .{},

    sampler: zgpu.SamplerHandle = .{},
    hzb_view: zgpu.TextureViewHandle = .{},
    white_hzb: zgpu.TextureHandle = .{},
    white_hzb_view: zgpu.TextureViewHandle = .{},

    sdf_mark_pipe: zgpu.ComputePipelineHandle = .{},
    sdf_mark_bgl: zgpu.BindGroupLayoutHandle = .{},
    sdf_mark_bg: zgpu.BindGroupHandle = .{},

    jfa_pipe: zgpu.ComputePipelineHandle = .{},
    jfa_bgl: zgpu.BindGroupLayoutHandle = .{},
    jfa_bg_a: zgpu.BindGroupHandle = .{},
    jfa_bg_b: zgpu.BindGroupHandle = .{},

    remove_pipe: zgpu.ComputePipelineHandle = .{},
    remove_bgl: zgpu.BindGroupLayoutHandle = .{},
    remove_bg: zgpu.BindGroupHandle = .{},

    sdf_atlas_pipe: zgpu.ComputePipelineHandle = .{},
    sdf_atlas_bgl: zgpu.BindGroupLayoutHandle = .{},
    sdf_atlas_bg: zgpu.BindGroupHandle = .{},

    lit_mark_pipe: zgpu.ComputePipelineHandle = .{},
    lit_mark_bgl: zgpu.BindGroupLayoutHandle = .{},
    lit_mark_bg: zgpu.BindGroupHandle = .{},
    lit_atlas_pipe: zgpu.ComputePipelineHandle = .{},
    lit_atlas_bgl: zgpu.BindGroupLayoutHandle = .{},
    lit_atlas_bg: zgpu.BindGroupHandle = .{},

    alb_mark_pipe: zgpu.ComputePipelineHandle = .{},
    alb_mark_bgl: zgpu.BindGroupLayoutHandle = .{},
    alb_mark_bg: zgpu.BindGroupHandle = .{},
    alb_atlas_pipe: zgpu.ComputePipelineHandle = .{},
    alb_atlas_bgl: zgpu.BindGroupLayoutHandle = .{},
    alb_atlas_bg: zgpu.BindGroupHandle = .{},

    pub fn create(gctx: *zgpu.GraphicsContext, allocator: std.mem.Allocator, cache: *shader.Cache) !System {
        var self: System = .{ .allocator = allocator };
        self.sampler = gctx.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });

        const n = voxelCount();
        const buf_size = n * @sizeOf(u32);
        self.sdf_buf = gctx.createBuffer(.{ .usage = .{ .storage = true, .copy_dst = true, .copy_src = true }, .size = buf_size });
        self.sdf_ping = gctx.createBuffer(.{ .usage = .{ .storage = true, .copy_dst = true, .copy_src = true }, .size = buf_size });
        self.lit_rgb_buf = gctx.createBuffer(.{ .usage = .{ .storage = true, .copy_dst = true }, .size = buf_size });
        self.lit_w_buf = gctx.createBuffer(.{ .usage = .{ .storage = true, .copy_dst = true }, .size = buf_size });
        self.alb_rgb_buf = gctx.createBuffer(.{ .usage = .{ .storage = true, .copy_dst = true }, .size = buf_size });
        self.alb_w_buf = gctx.createBuffer(.{ .usage = .{ .storage = true, .copy_dst = true }, .size = buf_size });

        const aw = atlasWidth();
        const ah = atlasHeight();
        inline for (.{
            .{ &self.sdf_atlas, &self.sdf_atlas_view },
            .{ &self.lit_atlas, &self.lit_atlas_view },
            .{ &self.lit_hist, &self.lit_hist_view },
            .{ &self.alb_atlas, &self.alb_atlas_view },
            .{ &self.alb_hist, &self.alb_hist_view },
        }) |pair| {
            pair[0].* = gctx.createTexture(.{
                .usage = .{ .texture_binding = true, .storage_binding = true, .copy_src = true, .copy_dst = true },
                .dimension = .tdim_2d,
                .size = .{ .width = aw, .height = ah, .depth_or_array_layers = 1 },
                .format = .rgba16_float,
                .mip_level_count = 1,
                .sample_count = 1,
            });
            pair[1].* = gctx.createTextureView(pair[0].*, .{});
        }

        self.white_hzb = gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .dimension = .tdim_2d,
            .size = .{ .width = 1, .height = 1, .depth_or_array_layers = 1 },
            .format = .r32_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        self.white_hzb_view = gctx.createTextureView(self.white_hzb, .{});
        gctx.queue.writeTexture(
            .{ .texture = gctx.lookupResource(self.white_hzb).?, .mip_level = 0, .origin = .{}, .aspect = .all },
            .{ .offset = 0, .bytes_per_row = 256, .rows_per_image = 1 },
            .{ .width = 1, .height = 1, .depth_or_array_layers = 1 },
            f32,
            &[_]f32{1.0},
        );

        const far = std.math.maxInt(u32);
        const clear_sdf = try allocator.alloc(u32, n);
        defer allocator.free(clear_sdf);
        @memset(clear_sdf, far);
        gctx.queue.writeBuffer(gctx.lookupResource(self.sdf_buf).?, 0, u32, clear_sdf);
        gctx.queue.writeBuffer(gctx.lookupResource(self.sdf_ping).?, 0, u32, clear_sdf);

        // Pipelines
        self.sdf_mark_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .compute = true }, .uniform, true, 0),
            zgpu.textureEntry(1, .{ .compute = true }, .depth, .tvdim_2d, false),
            zgpu.bufferEntry(2, .{ .compute = true }, .storage, false, 0),
        });
        try self.makeCs(gctx, cache, &self.sdf_mark_pipe, self.sdf_mark_bgl, "assets/shaders/gi_sdf_mark.wgsl");

        self.jfa_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .compute = true }, .uniform, true, 0),
            zgpu.bufferEntry(1, .{ .compute = true }, .read_only_storage, false, 0),
            zgpu.bufferEntry(2, .{ .compute = true }, .storage, false, 0),
        });
        try self.makeCs(gctx, cache, &self.jfa_pipe, self.jfa_bgl, "assets/shaders/gi_sdf_jfa.wgsl");

        self.remove_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .compute = true }, .uniform, true, 0),
            zgpu.textureEntry(1, .{ .compute = true }, .depth, .tvdim_2d, false),
            zgpu.textureEntry(2, .{ .compute = true }, .unfilterable_float, .tvdim_2d, false),
            zgpu.bufferEntry(3, .{ .compute = true }, .storage, false, 0),
        });
        try self.makeCs(gctx, cache, &self.remove_pipe, self.remove_bgl, "assets/shaders/gi_sdf_remove.wgsl");

        self.sdf_atlas_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .compute = true }, .uniform, true, 0),
            zgpu.bufferEntry(1, .{ .compute = true }, .read_only_storage, false, 0),
            zgpu.storageTextureEntry(2, .{ .compute = true }, .write_only, .rgba16_float, .tvdim_2d),
        });
        try self.makeCs(gctx, cache, &self.sdf_atlas_pipe, self.sdf_atlas_bgl, "assets/shaders/gi_sdf_to_atlas.wgsl");

        self.lit_mark_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .compute = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .compute = true }, .filtering),
            zgpu.textureEntry(2, .{ .compute = true }, .depth, .tvdim_2d, false),
            zgpu.textureEntry(3, .{ .compute = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(4, .{ .compute = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(5, .{ .compute = true }, .float, .tvdim_2d, false),
            zgpu.bufferEntry(6, .{ .compute = true }, .storage, false, 0),
            zgpu.bufferEntry(7, .{ .compute = true }, .storage, false, 0),
        });
        try self.makeCs(gctx, cache, &self.lit_mark_pipe, self.lit_mark_bgl, "assets/shaders/gi_lit_mark.wgsl");

        self.lit_atlas_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .compute = true }, .uniform, true, 0),
            zgpu.bufferEntry(1, .{ .compute = true }, .read_only_storage, false, 0),
            zgpu.bufferEntry(2, .{ .compute = true }, .read_only_storage, false, 0),
            zgpu.textureEntry(3, .{ .compute = true }, .float, .tvdim_2d, false),
            zgpu.storageTextureEntry(4, .{ .compute = true }, .write_only, .rgba16_float, .tvdim_2d),
        });
        try self.makeCs(gctx, cache, &self.lit_atlas_pipe, self.lit_atlas_bgl, "assets/shaders/gi_lit_to_atlas.wgsl");

        self.alb_mark_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .compute = true }, .uniform, true, 0),
            zgpu.textureEntry(1, .{ .compute = true }, .depth, .tvdim_2d, false),
            zgpu.textureEntry(2, .{ .compute = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(3, .{ .compute = true }, .float, .tvdim_2d, false),
            zgpu.bufferEntry(4, .{ .compute = true }, .storage, false, 0),
            zgpu.bufferEntry(5, .{ .compute = true }, .storage, false, 0),
        });
        try self.makeCs(gctx, cache, &self.alb_mark_pipe, self.alb_mark_bgl, "assets/shaders/gi_albedo_mark.wgsl");

        self.alb_atlas_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .compute = true }, .uniform, true, 0),
            zgpu.bufferEntry(1, .{ .compute = true }, .read_only_storage, false, 0),
            zgpu.bufferEntry(2, .{ .compute = true }, .read_only_storage, false, 0),
            zgpu.textureEntry(3, .{ .compute = true }, .float, .tvdim_2d, false),
            zgpu.storageTextureEntry(4, .{ .compute = true }, .write_only, .rgba16_float, .tvdim_2d),
        });
        try self.makeCs(gctx, cache, &self.alb_atlas_pipe, self.alb_atlas_bgl, "assets/shaders/gi_albedo_to_atlas.wgsl");

        self.ready = true;
        log.info(.render, "GI WorldSDF deepened: {d}x{d}x{d}x{d} JFA+remove+albedo atlas {d}x{d}", .{
            res_xz, res_y, res_xz, clips, aw, ah,
        });
        return self;
    }

    fn makeCs(
        _: *System,
        gctx: *zgpu.GraphicsContext,
        cache: *shader.Cache,
        out: *zgpu.ComputePipelineHandle,
        bgl: zgpu.BindGroupLayoutHandle,
        path: []const u8,
    ) !void {
        const pl = gctx.createPipelineLayout(&.{bgl});
        defer gctx.releaseResource(pl);
        const mod = try cache.getOrLoad(path);
        defer mod.release();
        out.* = gctx.createComputePipeline(pl, .{
            .compute = .{ .module = mod, .entry_point = "main" },
        });
    }

    pub fn destroy(self: *System, gctx: *zgpu.GraphicsContext) void {
        inline for (.{
            &self.sdf_mark_bg, &self.jfa_bg_a, &self.jfa_bg_b, &self.remove_bg, &self.sdf_atlas_bg,
            &self.lit_mark_bg, &self.lit_atlas_bg, &self.alb_mark_bg, &self.alb_atlas_bg,
            &self.sdf_atlas_view, &self.lit_atlas_view, &self.lit_hist_view,
            &self.alb_atlas_view, &self.alb_hist_view, &self.white_hzb_view,
        }) |v| {
            if (gctx.isResourceValid(v.*)) gctx.releaseResource(v.*);
        }
        inline for (.{
            &self.sdf_atlas, &self.lit_atlas, &self.lit_hist, &self.alb_atlas, &self.alb_hist, &self.white_hzb,
        }) |t| {
            if (gctx.isResourceValid(t.*)) gctx.destroyResource(t.*);
        }
        inline for (.{
            &self.sdf_buf, &self.sdf_ping, &self.lit_rgb_buf, &self.lit_w_buf, &self.alb_rgb_buf, &self.alb_w_buf,
        }) |b| {
            if (gctx.isResourceValid(b.*)) gctx.destroyResource(b.*);
        }
        if (gctx.isResourceValid(self.sampler)) gctx.releaseResource(self.sampler);
        self.* = .{};
    }

    pub fn sdfView(self: *const System) zgpu.TextureViewHandle {
        return self.sdf_atlas_view;
    }
    pub fn litView(self: *const System) zgpu.TextureViewHandle {
        return self.lit_atlas_view;
    }
    pub fn albedoView(self: *const System) zgpu.TextureViewHandle {
        return self.alb_atlas_view;
    }

    pub fn setHzb(self: *System, view: zgpu.TextureViewHandle) void {
        self.hzb_view = view;
    }

    pub fn updateOrigin(self: *System, cam_pos: [3]f32) void {
        var c: u32 = 0;
        while (c < clips) : (c += 1) {
            const vs = self.params.voxel0 * @as(f32, @floatFromInt(@as(u32, 1) << @intCast(c)));
            const hx = 0.5 * @as(f32, @floatFromInt(res_xz)) * vs;
            const hy = 0.5 * @as(f32, @floatFromInt(res_y)) * vs;
            const hz = 0.5 * @as(f32, @floatFromInt(res_xz)) * vs;
            self.origins[c] = .{
                @floor((cam_pos[0] - hx) / vs) * vs,
                @floor((cam_pos[1] - hy) / vs) * vs,
                @floor((cam_pos[2] - hz) / vs) * vs,
            };
        }
    }

    fn clipGpu(self: *const System) struct { clip0: [4]f32, clip1: [4]f32, clip2: [4]f32, clip3: [4]f32 } {
        return .{
            .clip0 = .{ self.origins[0][0], self.origins[0][1], self.origins[0][2], self.params.voxel0 },
            .clip1 = .{ self.origins[1][0], self.origins[1][1], self.origins[1][2], self.params.voxel0 * 2 },
            .clip2 = .{ self.origins[2][0], self.origins[2][1], self.origins[2][2], self.params.voxel0 * 4 },
            .clip3 = .{ self.origins[3][0], self.origins[3][1], self.origins[3][2], self.params.voxel0 * 8 },
        };
    }

    pub fn packing(self: *const System) struct {
        clip0: [4]f32,
        clip1: [4]f32,
        clip2: [4]f32,
        clip3: [4]f32,
        dims: [4]f32,
        atlas: [4]f32,
    } {
        const c = self.clipGpu();
        return .{
            .clip0 = c.clip0,
            .clip1 = c.clip1,
            .clip2 = c.clip2,
            .clip3 = c.clip3,
            .dims = .{ @floatFromInt(res_xz), @floatFromInt(res_y), @floatFromInt(clips), @floatFromInt(atlasWidth()) },
            .atlas = .{ @floatFromInt(atlasHeight()), @floatFromInt(slices_per_row), band_voxels, if (self.params.enabled) 1 else 0 },
        };
    }

    pub fn rebuildBindGroups(
        self: *System,
        gctx: *zgpu.GraphicsContext,
        depth_view: zgpu.TextureViewHandle,
        albedo_view: zgpu.TextureViewHandle,
        normal_view: zgpu.TextureViewHandle,
        prev_hdr_view: zgpu.TextureViewHandle,
    ) void {
        if (!self.ready) return;
        inline for (.{
            &self.sdf_mark_bg, &self.jfa_bg_a, &self.jfa_bg_b, &self.remove_bg, &self.sdf_atlas_bg,
            &self.lit_mark_bg, &self.lit_atlas_bg, &self.alb_mark_bg, &self.alb_atlas_bg,
        }) |bg| {
            if (gctx.isResourceValid(bg.*)) gctx.releaseResource(bg.*);
        }
        const hzb = if (gctx.isResourceValid(self.hzb_view)) self.hzb_view else self.white_hzb_view;
        const n = voxelCount() * @sizeOf(u32);

        self.sdf_mark_bg = gctx.createBindGroup(self.sdf_mark_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(SdfMarkUniforms) },
            .{ .binding = 1, .texture_view_handle = depth_view },
            .{ .binding = 2, .buffer_handle = self.sdf_buf, .offset = 0, .size = n },
        });
        self.jfa_bg_a = gctx.createBindGroup(self.jfa_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(JfaUniforms) },
            .{ .binding = 1, .buffer_handle = self.sdf_buf, .offset = 0, .size = n },
            .{ .binding = 2, .buffer_handle = self.sdf_ping, .offset = 0, .size = n },
        });
        self.jfa_bg_b = gctx.createBindGroup(self.jfa_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(JfaUniforms) },
            .{ .binding = 1, .buffer_handle = self.sdf_ping, .offset = 0, .size = n },
            .{ .binding = 2, .buffer_handle = self.sdf_buf, .offset = 0, .size = n },
        });
        self.remove_bg = gctx.createBindGroup(self.remove_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(RemoveUniforms) },
            .{ .binding = 1, .texture_view_handle = depth_view },
            .{ .binding = 2, .texture_view_handle = hzb },
            .{ .binding = 3, .buffer_handle = self.sdf_buf, .offset = 0, .size = n },
        });
        self.sdf_atlas_bg = gctx.createBindGroup(self.sdf_atlas_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(AtlasUniforms) },
            .{ .binding = 1, .buffer_handle = self.sdf_buf, .offset = 0, .size = n },
            .{ .binding = 2, .texture_view_handle = self.sdf_atlas_view },
        });
        self.lit_mark_bg = gctx.createBindGroup(self.lit_mark_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(LitMarkUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = depth_view },
            .{ .binding = 3, .texture_view_handle = albedo_view },
            .{ .binding = 4, .texture_view_handle = normal_view },
            .{ .binding = 5, .texture_view_handle = prev_hdr_view },
            .{ .binding = 6, .buffer_handle = self.lit_rgb_buf, .offset = 0, .size = n },
            .{ .binding = 7, .buffer_handle = self.lit_w_buf, .offset = 0, .size = n },
        });
        self.lit_atlas_bg = gctx.createBindGroup(self.lit_atlas_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(LitAtlasUniforms) },
            .{ .binding = 1, .buffer_handle = self.lit_rgb_buf, .offset = 0, .size = n },
            .{ .binding = 2, .buffer_handle = self.lit_w_buf, .offset = 0, .size = n },
            .{ .binding = 3, .texture_view_handle = self.lit_hist_view },
            .{ .binding = 4, .texture_view_handle = self.lit_atlas_view },
        });
        self.alb_mark_bg = gctx.createBindGroup(self.alb_mark_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(AlbedoMarkUniforms) },
            .{ .binding = 1, .texture_view_handle = depth_view },
            .{ .binding = 2, .texture_view_handle = albedo_view },
            .{ .binding = 3, .texture_view_handle = normal_view },
            .{ .binding = 4, .buffer_handle = self.alb_rgb_buf, .offset = 0, .size = n },
            .{ .binding = 5, .buffer_handle = self.alb_w_buf, .offset = 0, .size = n },
        });
        self.alb_atlas_bg = gctx.createBindGroup(self.alb_atlas_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(LitAtlasUniforms) },
            .{ .binding = 1, .buffer_handle = self.alb_rgb_buf, .offset = 0, .size = n },
            .{ .binding = 2, .buffer_handle = self.alb_w_buf, .offset = 0, .size = n },
            .{ .binding = 3, .texture_view_handle = self.alb_hist_view },
            .{ .binding = 4, .texture_view_handle = self.alb_atlas_view },
        });
    }

    pub fn beginFrame(self: *System, gctx: *zgpu.GraphicsContext, cam_pos: [3]f32) void {
        if (!self.ready or !self.params.enabled) return;
        self.updateOrigin(cam_pos);
        const n = voxelCount();
        const zeros = self.allocator.alloc(u32, n) catch return;
        defer self.allocator.free(zeros);
        @memset(zeros, 0);
        gctx.queue.writeBuffer(gctx.lookupResource(self.lit_w_buf).?, 0, u32, zeros);
        gctx.queue.writeBuffer(gctx.lookupResource(self.lit_rgb_buf).?, 0, u32, zeros);
        gctx.queue.writeBuffer(gctx.lookupResource(self.alb_w_buf).?, 0, u32, zeros);
        gctx.queue.writeBuffer(gctx.lookupResource(self.alb_rgb_buf).?, 0, u32, zeros);

        // Toroidal snap → clear SDF (invalidate clip volume).
        var snapped = false;
        if (self.has_prev_origin) {
            var c: u32 = 0;
            while (c < clips) : (c += 1) {
                if (self.origins[c][0] != self.prev_origins[c][0] or
                    self.origins[c][1] != self.prev_origins[c][1] or
                    self.origins[c][2] != self.prev_origins[c][2])
                {
                    snapped = true;
                    break;
                }
            }
        }
        if (snapped or self.frame % 120 == 0) {
            const far = std.math.maxInt(u32);
            const far_buf = self.allocator.alloc(u32, n) catch return;
            defer self.allocator.free(far_buf);
            @memset(far_buf, far);
            gctx.queue.writeBuffer(gctx.lookupResource(self.sdf_buf).?, 0, u32, far_buf);
            gctx.queue.writeBuffer(gctx.lookupResource(self.sdf_ping).?, 0, u32, far_buf);
            self.sdf_read = 0;
        }
        self.prev_origins = self.origins;
        self.has_prev_origin = true;
    }

    pub fn dispatch(
        self: *System,
        gctx: *zgpu.GraphicsContext,
        encoder: wgpu.CommandEncoder,
        _: [3]f32,
        inv_view_proj: zm.Mat,
        view_proj: zm.Mat,
        sun_dir: [3]f32,
        sun_color: [3]f32,
        sun_intensity: f32,
        ambient: f32,
        fb_w: u32,
        fb_h: u32,
    ) void {
        if (!self.ready or !self.params.enabled) return;
        if (!gctx.isResourceValid(self.sdf_mark_bg)) return;
        const cg = self.clipGpu();

        var sd = sun_dir;
        const slen = @sqrt(sd[0] * sd[0] + sd[1] * sd[1] + sd[2] * sd[2]);
        if (slen > 1e-5) {
            sd[0] /= slen;
            sd[1] /= slen;
            sd[2] /= slen;
        }

        // 1) Seed SDF
        {
            const pipe = gctx.lookupResource(self.sdf_mark_pipe) orelse return;
            const bg = gctx.lookupResource(self.sdf_mark_bg) orelse return;
            const pass = encoder.beginComputePass(null);
            defer {
                pass.end();
                pass.release();
            }
            pass.setPipeline(pipe);
            const mem = gctx.uniformsAllocate(SdfMarkUniforms, 1);
            mem.slice[0] = .{
                .inv_view_proj = zm.transpose(inv_view_proj),
                .clip0 = cg.clip0,
                .clip1 = cg.clip1,
                .clip2 = cg.clip2,
                .clip3 = cg.clip3,
                .dims = .{ @floatFromInt(res_xz), @floatFromInt(res_y), @floatFromInt(clips), @floatFromInt(self.frame) },
                .screen = .{ @floatFromInt(fb_w), @floatFromInt(fb_h), self.params.mark_budget, band_voxels },
            };
            pass.setBindGroup(0, bg, &.{mem.offset});
            pass.dispatchWorkgroups(@max((@as(u32, @intFromFloat(self.params.mark_budget * 8192)) + 63) / 64, 1), 1, 1);
        }

        // 2) JFA dilate (ping-pong)
        if (self.params.jfa_enabled) {
            const jumps = [_]f32{ 8, 4, 2, 1 };
            var use_a = true; // a: buf→ping, b: ping→buf
            for (jumps) |jump| {
                const pipe = gctx.lookupResource(self.jfa_pipe) orelse break;
                const bg = gctx.lookupResource(if (use_a) self.jfa_bg_a else self.jfa_bg_b) orelse break;
                const pass = encoder.beginComputePass(null);
                defer {
                    pass.end();
                    pass.release();
                }
                pass.setPipeline(pipe);
                const mem = gctx.uniformsAllocate(JfaUniforms, 1);
                mem.slice[0] = .{
                    .dims = .{ @floatFromInt(res_xz), @floatFromInt(res_y), @floatFromInt(clips), jump },
                    .params = .{ band_voxels, 0, 0, 0 },
                };
                pass.setBindGroup(0, bg, &.{mem.offset});
                // Dispatch covers ix,iy, iz+clip*rx
                pass.dispatchWorkgroups((res_xz + 3) / 4, (res_y + 3) / 4, (res_xz * clips + 3) / 4);
                use_a = !use_a;
            }
            // After 4 jumps starting buf→ping: final in buf (even count → ends with ping→buf)
            self.sdf_read = 0;
            // Copy final into sdf_buf if last write was ping — even jumps: a,b,a,b last is b (ping→buf). OK.
        }

        // 3) removeFromDepth
        {
            // Ensure remove uses current sdf_buf (JFA ended there).
            const pipe = gctx.lookupResource(self.remove_pipe) orelse return;
            const bg = gctx.lookupResource(self.remove_bg) orelse return;
            const pass = encoder.beginComputePass(null);
            defer {
                pass.end();
                pass.release();
            }
            pass.setPipeline(pipe);
            const mem = gctx.uniformsAllocate(RemoveUniforms, 1);
            mem.slice[0] = .{
                .view_proj = zm.transpose(view_proj),
                .clip0 = cg.clip0,
                .clip1 = cg.clip1,
                .clip2 = cg.clip2,
                .clip3 = cg.clip3,
                .dims = .{ @floatFromInt(res_xz), @floatFromInt(res_y), @floatFromInt(clips), @floatFromInt(self.frame) },
                .screen = .{ @floatFromInt(fb_w), @floatFromInt(fb_h), self.params.remove_budget, band_voxels },
            };
            pass.setBindGroup(0, bg, &.{mem.offset});
            pass.dispatchWorkgroups(@max((@as(u32, @intFromFloat(self.params.remove_budget * 2048)) + 63) / 64, 1), 1, 1);
        }

        // 4) SDF → atlas (always from sdf_buf)
        self.dispatchAtlas(gctx, encoder, self.sdf_atlas_pipe, self.sdf_atlas_bg);

        // 5) Lit
        {
            const pipe = gctx.lookupResource(self.lit_mark_pipe) orelse return;
            const bg = gctx.lookupResource(self.lit_mark_bg) orelse return;
            const pass = encoder.beginComputePass(null);
            defer {
                pass.end();
                pass.release();
            }
            pass.setPipeline(pipe);
            const mem = gctx.uniformsAllocate(LitMarkUniforms, 1);
            mem.slice[0] = .{
                .inv_view_proj = zm.transpose(inv_view_proj),
                .view_proj = zm.transpose(view_proj),
                .clip0 = cg.clip0,
                .clip1 = cg.clip1,
                .clip2 = cg.clip2,
                .clip3 = cg.clip3,
                .dims = .{ @floatFromInt(res_xz), @floatFromInt(res_y), @floatFromInt(clips), @floatFromInt(self.frame) },
                .screen = .{ @floatFromInt(fb_w), @floatFromInt(fb_h), self.params.lit_budget, 0 },
                .sun_dir = .{ sd[0], sd[1], sd[2], 0 },
                .sun_color = .{ sun_color[0] * sun_intensity, sun_color[1] * sun_intensity, sun_color[2] * sun_intensity, ambient },
            };
            pass.setBindGroup(0, bg, &.{mem.offset});
            pass.dispatchWorkgroups(@max((@as(u32, @intFromFloat(self.params.lit_budget * 2048)) + 63) / 64, 1), 1, 1);
        }
        self.dispatchLitAtlas(gctx, encoder);

        // 6) Albedo scene
        {
            const pipe = gctx.lookupResource(self.alb_mark_pipe) orelse return;
            const bg = gctx.lookupResource(self.alb_mark_bg) orelse return;
            const pass = encoder.beginComputePass(null);
            defer {
                pass.end();
                pass.release();
            }
            pass.setPipeline(pipe);
            const mem = gctx.uniformsAllocate(AlbedoMarkUniforms, 1);
            mem.slice[0] = .{
                .inv_view_proj = zm.transpose(inv_view_proj),
                .clip0 = cg.clip0,
                .clip1 = cg.clip1,
                .clip2 = cg.clip2,
                .clip3 = cg.clip3,
                .dims = .{ @floatFromInt(res_xz), @floatFromInt(res_y), @floatFromInt(clips), @floatFromInt(self.frame) },
                .screen = .{ @floatFromInt(fb_w), @floatFromInt(fb_h), self.params.albedo_budget, 0 },
            };
            pass.setBindGroup(0, bg, &.{mem.offset});
            pass.dispatchWorkgroups(@max((@as(u32, @intFromFloat(self.params.albedo_budget * 2048)) + 63) / 64, 1), 1, 1);
        }
        self.dispatchAlbAtlas(gctx, encoder);

        self.frame +%= 1;
    }

    fn dispatchAtlas(_: *System, gctx: *zgpu.GraphicsContext, encoder: wgpu.CommandEncoder, pipe_h: zgpu.ComputePipelineHandle, bg_h: zgpu.BindGroupHandle) void {
        const pipe = gctx.lookupResource(pipe_h) orelse return;
        const bg = gctx.lookupResource(bg_h) orelse return;
        const pass = encoder.beginComputePass(null);
        defer {
            pass.end();
            pass.release();
        }
        pass.setPipeline(pipe);
        const mem = gctx.uniformsAllocate(AtlasUniforms, 1);
        mem.slice[0] = .{
            .dims = .{ @floatFromInt(res_xz), @floatFromInt(res_y), @floatFromInt(clips), @floatFromInt(atlasWidth()) },
            .atlas = .{ @floatFromInt(atlasHeight()), @floatFromInt(slices_per_row), band_voxels, 0 },
        };
        pass.setBindGroup(0, bg, &.{mem.offset});
        pass.dispatchWorkgroups((atlasWidth() + 7) / 8, (atlasHeight() + 7) / 8, 1);
    }

    fn dispatchLitAtlas(self: *System, gctx: *zgpu.GraphicsContext, encoder: wgpu.CommandEncoder) void {
        const pipe = gctx.lookupResource(self.lit_atlas_pipe) orelse return;
        const bg = gctx.lookupResource(self.lit_atlas_bg) orelse return;
        {
            const pass = encoder.beginComputePass(null);
            defer {
                pass.end();
                pass.release();
            }
            pass.setPipeline(pipe);
            const mem = gctx.uniformsAllocate(LitAtlasUniforms, 1);
            mem.slice[0] = .{
                .dims = .{ @floatFromInt(res_xz), @floatFromInt(res_y), @floatFromInt(clips), @floatFromInt(atlasWidth()) },
                .atlas = .{ @floatFromInt(atlasHeight()), @floatFromInt(slices_per_row), 0, 0 },
                .params = .{ self.params.lit_temporal, 1, 0, 0 },
            };
            pass.setBindGroup(0, bg, &.{mem.offset});
            pass.dispatchWorkgroups((atlasWidth() + 7) / 8, (atlasHeight() + 7) / 8, 1);
        }
        // Must copy after the compute pass ends — encoder is locked while a pass is open.
        const src = gctx.lookupResource(self.lit_atlas) orelse return;
        const dst = gctx.lookupResource(self.lit_hist) orelse return;
        encoder.copyTextureToTexture(.{ .texture = src }, .{ .texture = dst }, .{ .width = atlasWidth(), .height = atlasHeight(), .depth_or_array_layers = 1 });
    }

    fn dispatchAlbAtlas(self: *System, gctx: *zgpu.GraphicsContext, encoder: wgpu.CommandEncoder) void {
        const pipe = gctx.lookupResource(self.alb_atlas_pipe) orelse return;
        const bg = gctx.lookupResource(self.alb_atlas_bg) orelse return;
        {
            const pass = encoder.beginComputePass(null);
            defer {
                pass.end();
                pass.release();
            }
            pass.setPipeline(pipe);
            const mem = gctx.uniformsAllocate(LitAtlasUniforms, 1);
            mem.slice[0] = .{
                .dims = .{ @floatFromInt(res_xz), @floatFromInt(res_y), @floatFromInt(clips), @floatFromInt(atlasWidth()) },
                .atlas = .{ @floatFromInt(atlasHeight()), @floatFromInt(slices_per_row), 0, 0 },
                .params = .{ self.params.lit_temporal, 1, 0, 0 },
            };
            pass.setBindGroup(0, bg, &.{mem.offset});
            pass.dispatchWorkgroups((atlasWidth() + 7) / 8, (atlasHeight() + 7) / 8, 1);
        }
        const src = gctx.lookupResource(self.alb_atlas) orelse return;
        const dst = gctx.lookupResource(self.alb_hist) orelse return;
        encoder.copyTextureToTexture(.{ .texture = src }, .{ .texture = dst }, .{ .width = atlasWidth(), .height = atlasHeight(), .depth_or_array_layers = 1 });
    }
};

test "gi volume atlas size deepened" {
    try std.testing.expectEqual(@as(u32, 512), atlasWidth());
    try std.testing.expect(voxelCount() == 64 * 32 * 64 * 4);
}

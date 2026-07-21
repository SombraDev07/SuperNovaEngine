const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const shader = @import("shader.zig");
const log = @import("../core/log.zig");

/// GPU far-depth Hi-Z for screen probes (daGI2 HZB).
pub const mip_count: u32 = 4;

pub const DownUniforms = extern struct {
    src_size: [4]f32,
};

pub const System = struct {
    ready: bool = false,
    w: u32 = 0,
    h: u32 = 0,
    levels: [mip_count]zgpu.TextureHandle = .{ .{}, .{}, .{}, .{} },
    views: [mip_count]zgpu.TextureViewHandle = .{ .{}, .{}, .{}, .{} },
    sampler: zgpu.SamplerHandle = .{},

    mip0_pipe: zgpu.RenderPipelineHandle = .{},
    mip0_bgl: zgpu.BindGroupLayoutHandle = .{},
    mip0_bg: zgpu.BindGroupHandle = .{},

    down_pipe: zgpu.RenderPipelineHandle = .{},
    down_bgl: zgpu.BindGroupLayoutHandle = .{},
    down_bgs: [mip_count - 1]zgpu.BindGroupHandle = .{ .{}, .{}, .{} },

    pub fn create(gctx: *zgpu.GraphicsContext, cache: *shader.Cache) !System {
        var self: System = .{};
        self.sampler = gctx.createSampler(.{
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .mipmap_filter = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });

        self.mip0_bgl = gctx.createBindGroupLayout(&.{
            zgpu.textureEntry(0, .{ .fragment = true }, .depth, .tvdim_2d, false),
        });
        {
            const pl = gctx.createPipelineLayout(&.{self.mip0_bgl});
            defer gctx.releaseResource(pl);
            const mod = try cache.getOrLoad("assets/shaders/hzb_mip0.wgsl");
            defer mod.release();
            const targets = [_]wgpu.ColorTargetState{.{ .format = .r32_float }};
            self.mip0_pipe = gctx.createRenderPipeline(pl, .{
                .vertex = .{ .module = mod, .entry_point = "vs_main" },
                .primitive = .{ .front_face = .ccw, .cull_mode = .none, .topology = .triangle_list },
                .fragment = &wgpu.FragmentState{
                    .module = mod,
                    .entry_point = "fs_main",
                    .target_count = targets.len,
                    .targets = &targets,
                },
            });
        }

        self.down_bgl = gctx.createBindGroupLayout(&.{
            zgpu.textureEntry(0, .{ .fragment = true }, .unfilterable_float, .tvdim_2d, false),
        });
        {
            const pl = gctx.createPipelineLayout(&.{self.down_bgl});
            defer gctx.releaseResource(pl);
            const mod = try cache.getOrLoad("assets/shaders/hzb_down.wgsl");
            defer mod.release();
            const targets = [_]wgpu.ColorTargetState{.{ .format = .r32_float }};
            self.down_pipe = gctx.createRenderPipeline(pl, .{
                .vertex = .{ .module = mod, .entry_point = "vs_main" },
                .primitive = .{ .front_face = .ccw, .cull_mode = .none, .topology = .triangle_list },
                .fragment = &wgpu.FragmentState{
                    .module = mod,
                    .entry_point = "fs_main",
                    .target_count = targets.len,
                    .targets = &targets,
                },
            });
        }

        self.resize(gctx);
        self.ready = true;
        log.info(.render, "HZB GPU: {d} mips (far-depth)", .{mip_count});
        return self;
    }

    pub fn resize(self: *System, gctx: *zgpu.GraphicsContext) void {
        const fw = @max(gctx.swapchain_descriptor.width, 1);
        const fh = @max(gctx.swapchain_descriptor.height, 1);
        const w = @max(fw / 2, 1);
        const h = @max(fh / 2, 1);
        if (w == self.w and h == self.h and gctx.isResourceValid(self.levels[0])) return;

        for (&self.views) |*v| {
            if (gctx.isResourceValid(v.*)) gctx.releaseResource(v.*);
            v.* = .{};
        }
        for (&self.levels) |*t| {
            if (gctx.isResourceValid(t.*)) gctx.destroyResource(t.*);
            t.* = .{};
        }
        self.w = w;
        self.h = h;
        var lw = w;
        var lh = h;
        var i: u32 = 0;
        while (i < mip_count) : (i += 1) {
            self.levels[i] = gctx.createTexture(.{
                .usage = .{ .render_attachment = true, .texture_binding = true },
                .dimension = .tdim_2d,
                .size = .{ .width = lw, .height = lh, .depth_or_array_layers = 1 },
                .format = .r32_float,
                .mip_level_count = 1,
                .sample_count = 1,
            });
            self.views[i] = gctx.createTextureView(self.levels[i], .{});
            lw = @max(lw / 2, 1);
            lh = @max(lh / 2, 1);
        }
    }

    pub fn destroy(self: *System, gctx: *zgpu.GraphicsContext) void {
        if (gctx.isResourceValid(self.mip0_bg)) gctx.releaseResource(self.mip0_bg);
        for (&self.down_bgs) |*bg| {
            if (gctx.isResourceValid(bg.*)) gctx.releaseResource(bg.*);
        }
        for (&self.views) |*v| {
            if (gctx.isResourceValid(v.*)) gctx.releaseResource(v.*);
        }
        for (&self.levels) |*t| {
            if (gctx.isResourceValid(t.*)) gctx.destroyResource(t.*);
        }
        if (gctx.isResourceValid(self.sampler)) gctx.releaseResource(self.sampler);
        self.* = .{};
    }

    pub fn viewMip(self: *const System, mip: u32) zgpu.TextureViewHandle {
        return self.views[@min(mip, mip_count - 1)];
    }

    pub fn rebuildBindGroups(self: *System, gctx: *zgpu.GraphicsContext, depth_view: zgpu.TextureViewHandle) void {
        if (!self.ready) return;
        self.resize(gctx);
        if (gctx.isResourceValid(self.mip0_bg)) gctx.releaseResource(self.mip0_bg);
        self.mip0_bg = gctx.createBindGroup(self.mip0_bgl, &.{
            .{ .binding = 0, .texture_view_handle = depth_view },
        });
        var i: u32 = 0;
        while (i < mip_count - 1) : (i += 1) {
            if (gctx.isResourceValid(self.down_bgs[i])) gctx.releaseResource(self.down_bgs[i]);
            self.down_bgs[i] = gctx.createBindGroup(self.down_bgl, &.{
                .{ .binding = 0, .texture_view_handle = self.views[i] },
            });
        }
    }

    pub fn build(self: *System, gctx: *zgpu.GraphicsContext, encoder: wgpu.CommandEncoder) void {
        if (!self.ready or !gctx.isResourceValid(self.mip0_bg)) return;
        // mip0
        {
            const pipe = gctx.lookupResource(self.mip0_pipe) orelse return;
            const bg = gctx.lookupResource(self.mip0_bg) orelse return;
            const tv = gctx.lookupResource(self.views[0]) orelse return;
            const color = [_]wgpu.RenderPassColorAttachment{.{
                .view = tv,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 1, .g = 0, .b = 0, .a = 1 },
            }};
            const pass = encoder.beginRenderPass(.{
                .color_attachment_count = color.len,
                .color_attachments = &color,
            });
            defer {
                pass.end();
                pass.release();
            }
            pass.setPipeline(pipe);
            pass.setBindGroup(0, bg, &.{});
            pass.draw(3, 1, 0, 0);
        }
        var mip: u32 = 0;
        while (mip < mip_count - 1) : (mip += 1) {
            const pipe = gctx.lookupResource(self.down_pipe) orelse return;
            const bg = gctx.lookupResource(self.down_bgs[mip]) orelse return;
            const tv = gctx.lookupResource(self.views[mip + 1]) orelse return;
            const color = [_]wgpu.RenderPassColorAttachment{.{
                .view = tv,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 1, .g = 0, .b = 0, .a = 1 },
            }};
            const pass = encoder.beginRenderPass(.{
                .color_attachment_count = color.len,
                .color_attachments = &color,
            });
            defer {
                pass.end();
                pass.release();
            }
            pass.setPipeline(pipe);
            pass.setBindGroup(0, bg, &.{});
            pass.draw(3, 1, 0, 0);
        }
    }
};

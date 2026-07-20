const zgpu = @import("zgpu");

pub const mip_count: u32 = 7;

/// Multi-mip bloom pyramid (Dagor bloomCore role — downsample → blur → upsample).
pub const Targets = struct {
    /// Pyramid levels [0]=half-res … [mip_count-1]=coarsest.
    levels: [mip_count]zgpu.TextureHandle = [_]zgpu.TextureHandle{.{}} ** mip_count,
    views: [mip_count]zgpu.TextureViewHandle = [_]zgpu.TextureViewHandle{.{}} ** mip_count,
    /// Scratch for separable blur at each level.
    blur: [mip_count]zgpu.TextureHandle = [_]zgpu.TextureHandle{.{}} ** mip_count,
    blur_views: [mip_count]zgpu.TextureViewHandle = [_]zgpu.TextureViewHandle{.{}} ** mip_count,
    widths: [mip_count]u32 = .{0} ** mip_count,
    heights: [mip_count]u32 = .{0} ** mip_count,
    /// Legacy aliases (tonemap / old blur bind groups) → mip 0.
    a_view: zgpu.TextureViewHandle = .{},
    b_view: zgpu.TextureViewHandle = .{},
    width: u32 = 0,
    height: u32 = 0,

    pub fn create(gctx: *zgpu.GraphicsContext) Targets {
        var self: Targets = .{};
        const sw = gctx.swapchain_descriptor.width;
        const sh = gctx.swapchain_descriptor.height;
        var w = @max(sw / 2, 1);
        var h = @max(sh / 2, 1);
        var i: u32 = 0;
        while (i < mip_count) : (i += 1) {
            self.widths[i] = w;
            self.heights[i] = h;
            self.levels[i] = gctx.createTexture(.{
                .usage = .{ .render_attachment = true, .texture_binding = true },
                .dimension = .tdim_2d,
                .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
                .format = .rgba16_float,
                .mip_level_count = 1,
                .sample_count = 1,
            });
            self.views[i] = gctx.createTextureView(self.levels[i], .{});
            self.blur[i] = gctx.createTexture(.{
                .usage = .{ .render_attachment = true, .texture_binding = true },
                .dimension = .tdim_2d,
                .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
                .format = .rgba16_float,
                .mip_level_count = 1,
                .sample_count = 1,
            });
            self.blur_views[i] = gctx.createTextureView(self.blur[i], .{});
            w = @max(w / 2, 1);
            h = @max(h / 2, 1);
        }
        self.a_view = self.views[0];
        self.b_view = self.blur_views[0];
        self.width = self.widths[0];
        self.height = self.heights[0];
        return self;
    }

    pub fn destroy(self: *Targets, gctx: *zgpu.GraphicsContext) void {
        for (0..mip_count) |i| {
            if (gctx.isResourceValid(self.views[i])) gctx.releaseResource(self.views[i]);
            if (gctx.isResourceValid(self.levels[i])) gctx.destroyResource(self.levels[i]);
            if (gctx.isResourceValid(self.blur_views[i])) gctx.releaseResource(self.blur_views[i]);
            if (gctx.isResourceValid(self.blur[i])) gctx.destroyResource(self.blur[i]);
        }
        self.* = .{};
    }

    pub fn resize(self: *Targets, gctx: *zgpu.GraphicsContext) void {
        self.destroy(gctx);
        self.* = create(gctx);
    }

    /// Final composite lives in level 0 (after upsample).
    pub fn outputView(self: *const Targets) zgpu.TextureViewHandle {
        return self.views[0];
    }
};

pub const ExtractUniforms = extern struct {
    /// x = threshold, y = soft knee, z = intensity (unused here), w = pad
    params: [4]f32,
};

pub const BlurUniforms = extern struct {
    /// xy = texel size * direction, zw unused
    direction: [4]f32,
};

pub const UpsampleUniforms = extern struct {
    /// x = filter radius, y = coarse contribution (upsample_factor), z = halation tint strength, w = mip index
    params: [4]f32,
};

pub const TonemapUniforms = extern struct {
    /// x = bloom strength, yzw unused (exposure comes from GPU 1×1)
    params: [4]f32,
};

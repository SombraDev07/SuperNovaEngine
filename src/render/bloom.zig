const zgpu = @import("zgpu");

/// Half-resolution ping-pong targets for bloom.
pub const Targets = struct {
    a: zgpu.TextureHandle = .{},
    a_view: zgpu.TextureViewHandle = .{},
    b: zgpu.TextureHandle = .{},
    b_view: zgpu.TextureViewHandle = .{},
    width: u32 = 0,
    height: u32 = 0,

    pub fn create(gctx: *zgpu.GraphicsContext) Targets {
        const sw = gctx.swapchain_descriptor.width;
        const sh = gctx.swapchain_descriptor.height;
        const w = @max(sw / 2, 1);
        const h = @max(sh / 2, 1);

        const a = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        const b = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });

        return .{
            .a = a,
            .a_view = gctx.createTextureView(a, .{}),
            .b = b,
            .b_view = gctx.createTextureView(b, .{}),
            .width = w,
            .height = h,
        };
    }

    pub fn destroy(self: *Targets, gctx: *zgpu.GraphicsContext) void {
        if (gctx.isResourceValid(self.a_view)) gctx.releaseResource(self.a_view);
        if (gctx.isResourceValid(self.a)) gctx.destroyResource(self.a);
        if (gctx.isResourceValid(self.b_view)) gctx.releaseResource(self.b_view);
        if (gctx.isResourceValid(self.b)) gctx.destroyResource(self.b);
        self.* = .{};
    }

    pub fn resize(self: *Targets, gctx: *zgpu.GraphicsContext) void {
        self.destroy(gctx);
        self.* = create(gctx);
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

pub const TonemapUniforms = extern struct {
    /// x = bloom strength, yzw unused
    params: [4]f32,
};

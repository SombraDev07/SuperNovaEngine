const std = @import("std");
const zgpu = @import("zgpu");

pub const mid_size: u32 = 64;
pub const hist_bins: u32 = 256;

/// GPU auto-exposure: HDR → log-luminance mid → 256-bin hist → percentile → adapted exposure.
pub const Chain = struct {
    lum_mid: zgpu.TextureHandle = .{},
    lum_mid_view: zgpu.TextureViewHandle = .{},
    hist: zgpu.TextureHandle = .{},
    hist_view: zgpu.TextureViewHandle = .{},
    lum_1x1: zgpu.TextureHandle = .{},
    lum_1x1_view: zgpu.TextureViewHandle = .{},
    exp_a: zgpu.TextureHandle = .{},
    exp_a_view: zgpu.TextureViewHandle = .{},
    exp_b: zgpu.TextureHandle = .{},
    exp_b_view: zgpu.TextureViewHandle = .{},
    /// false → read A write B; true → read B write A
    flip: bool = false,

    pub fn create(gctx: *zgpu.GraphicsContext) Chain {
        const lum_mid = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{ .width = mid_size, .height = mid_size, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        const hist = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{ .width = hist_bins, .height = 1, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        const lum_1x1 = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{ .width = 1, .height = 1, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        const exp_a = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{ .width = 1, .height = 1, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        const exp_b = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{ .width = 1, .height = 1, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        return .{
            .lum_mid = lum_mid,
            .lum_mid_view = gctx.createTextureView(lum_mid, .{}),
            .hist = hist,
            .hist_view = gctx.createTextureView(hist, .{}),
            .lum_1x1 = lum_1x1,
            .lum_1x1_view = gctx.createTextureView(lum_1x1, .{}),
            .exp_a = exp_a,
            .exp_a_view = gctx.createTextureView(exp_a, .{}),
            .exp_b = exp_b,
            .exp_b_view = gctx.createTextureView(exp_b, .{}),
        };
    }

    pub fn destroy(self: *Chain, gctx: *zgpu.GraphicsContext) void {
        inline for (.{
            .{ self.lum_mid_view, self.lum_mid },
            .{ self.hist_view, self.hist },
            .{ self.lum_1x1_view, self.lum_1x1 },
            .{ self.exp_a_view, self.exp_a },
            .{ self.exp_b_view, self.exp_b },
        }) |pair| {
            if (gctx.isResourceValid(pair[0])) gctx.releaseResource(pair[0]);
            if (gctx.isResourceValid(pair[1])) gctx.destroyResource(pair[1]);
        }
        self.* = .{};
    }

    pub fn resize(self: *Chain, gctx: *zgpu.GraphicsContext) void {
        _ = self;
        _ = gctx;
    }

    pub fn prevExpView(self: *const Chain) zgpu.TextureViewHandle {
        return if (self.flip) self.exp_b_view else self.exp_a_view;
    }

    pub fn currExpView(self: *const Chain) zgpu.TextureViewHandle {
        return if (self.flip) self.exp_a_view else self.exp_b_view;
    }

    pub fn advance(self: *Chain) void {
        self.flip = !self.flip;
    }
};

pub const AdaptUniforms = extern struct {
    /// x = key/target grey, y = adapt_up, z = min exposure, w = max exposure
    params: [4]f32,
};

pub const HistUniforms = extern struct {
    /// x = log_min, y = log_range (Dagor-like -12..+3 → range 15)
    params: [4]f32,
};

test "exposure chain sizes" {
    try std.testing.expect(mid_size >= 8);
    try std.testing.expect(hist_bins == 256);
}

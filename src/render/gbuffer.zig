const zgpu = @import("zgpu");
const zm = @import("zmath");

pub const Targets = struct {
    albedo: zgpu.TextureHandle = .{},
    albedo_view: zgpu.TextureViewHandle = .{},
    /// Octahedral normal in RG (unorm).
    normal: zgpu.TextureHandle = .{},
    normal_view: zgpu.TextureViewHandle = .{},
    /// R = metallic, G = roughness, B = flags, A = 1
    material: zgpu.TextureHandle = .{},
    material_view: zgpu.TextureViewHandle = .{},
    /// RGB emissive (sRGB), A unused
    emissive: zgpu.TextureHandle = .{},
    emissive_view: zgpu.TextureViewHandle = .{},
    depth: zgpu.TextureHandle = .{},
    depth_view: zgpu.TextureViewHandle = .{},
    hdr: zgpu.TextureHandle = .{},
    hdr_view: zgpu.TextureViewHandle = .{},

    pub fn create(gctx: *zgpu.GraphicsContext) Targets {
        const w = gctx.swapchain_descriptor.width;
        const h = gctx.swapchain_descriptor.height;

        const albedo = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
            .format = .rgba8_unorm_srgb,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        const normal = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
            .format = .rgba8_unorm,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        const material = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
            .format = .rgba8_unorm,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        const emissive = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
            .format = .rgba8_unorm_srgb,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        const depth = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
            .format = .depth32_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        const hdr = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });

        return .{
            .albedo = albedo,
            .albedo_view = gctx.createTextureView(albedo, .{}),
            .normal = normal,
            .normal_view = gctx.createTextureView(normal, .{}),
            .material = material,
            .material_view = gctx.createTextureView(material, .{}),
            .emissive = emissive,
            .emissive_view = gctx.createTextureView(emissive, .{}),
            .depth = depth,
            .depth_view = gctx.createTextureView(depth, .{}),
            .hdr = hdr,
            .hdr_view = gctx.createTextureView(hdr, .{}),
        };
    }

    pub fn destroy(self: *Targets, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(self.albedo_view);
        gctx.destroyResource(self.albedo);
        gctx.releaseResource(self.normal_view);
        gctx.destroyResource(self.normal);
        gctx.releaseResource(self.material_view);
        gctx.destroyResource(self.material);
        gctx.releaseResource(self.emissive_view);
        gctx.destroyResource(self.emissive);
        gctx.releaseResource(self.depth_view);
        gctx.destroyResource(self.depth);
        gctx.releaseResource(self.hdr_view);
        gctx.destroyResource(self.hdr);
        self.* = .{};
    }

    pub fn resize(self: *Targets, gctx: *zgpu.GraphicsContext) void {
        self.destroy(gctx);
        self.* = create(gctx);
    }
};

pub const GBufferUniforms = extern struct {
    /// Transposed world→clip (row-vector WGSL).
    world_to_clip: zm.Mat,
};

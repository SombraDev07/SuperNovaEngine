const std = @import("std");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zm = @import("zmath");
const zgui = @import("zgui");
const log = @import("../core/log.zig");
const profile = @import("../core/profile.zig");
const Camera = @import("camera.zig").Camera;
const shader = @import("shader.zig");
const mesh = @import("mesh.zig");
const gbuffer = @import("gbuffer.zig");
const lights = @import("lights.zig");
const ibl = @import("ibl.zig");
const bloom = @import("bloom.zig");
const shadow = @import("shadow.zig");

pub const ClearColor = struct {
    r: f64 = 0.04,
    g: f64 = 0.05,
    b: f64 = 0.07,
    a: f64 = 1.0,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    camera: Camera = .{},
    clear_color: ClearColor = .{},

    targets: gbuffer.Targets = .{},
    bloom_targets: bloom.Targets = .{},
    shadow_maps: shadow.Maps = .{},
    point_shadow_maps: shadow.PointMaps = .{},
    sampler: zgpu.SamplerHandle = .{},
    env: ibl.Environment = .{},

    gbuffer_pipeline: zgpu.RenderPipelineHandle = .{},
    gbuffer_bgl: zgpu.BindGroupLayoutHandle = .{},
    gbuffer_bg: zgpu.BindGroupHandle = .{},

    shadow_pipeline: zgpu.RenderPipelineHandle = .{},
    shadow_bgl: zgpu.BindGroupLayoutHandle = .{},
    shadow_bg: zgpu.BindGroupHandle = .{},

    point_shadow_pipeline: zgpu.RenderPipelineHandle = .{},
    point_shadow_bgl: zgpu.BindGroupLayoutHandle = .{},
    point_shadow_bg: zgpu.BindGroupHandle = .{},

    light_pipeline: zgpu.RenderPipelineHandle = .{},
    light_bgl: zgpu.BindGroupLayoutHandle = .{},
    light_bg: zgpu.BindGroupHandle = .{},

    bloom_extract_pipeline: zgpu.RenderPipelineHandle = .{},
    bloom_extract_bgl: zgpu.BindGroupLayoutHandle = .{},
    bloom_extract_bg: zgpu.BindGroupHandle = .{},

    bloom_blur_pipeline: zgpu.RenderPipelineHandle = .{},
    bloom_blur_bgl: zgpu.BindGroupLayoutHandle = .{},
    bloom_blur_a_to_b: zgpu.BindGroupHandle = .{},
    bloom_blur_b_to_a: zgpu.BindGroupHandle = .{},

    tonemap_pipeline: zgpu.RenderPipelineHandle = .{},
    tonemap_bgl: zgpu.BindGroupLayoutHandle = .{},
    tonemap_bg: zgpu.BindGroupHandle = .{},

    cube: mesh.Mesh = undefined,
    floor: mesh.Mesh = undefined,
    time: f32 = 0.0,

    /// Default PBR params for the demo cube.
    metallic: f32 = 0.15,
    roughness: f32 = 0.35,
    ao: f32 = 1.0,
    ibl_intensity: f32 = 1.0,
    bloom_threshold: f32 = 1.0,
    bloom_knee: f32 = 0.5,
    bloom_strength: f32 = 0.65,
    shadow_max_distance: f32 = 40.0,
    shadow_depth_bias: f32 = 0.002,
    shadow_normal_bias: f32 = 0.02,
    /// World-space light radius used by PCSS penumbra.
    shadow_light_size: f32 = 0.12,
    point_shadow_bias: f32 = 0.015,
    point_shadow_soft: f32 = 1.0,
    point_shadow_near: f32 = 0.05,

    pub fn create(allocator: std.mem.Allocator, window: *zglfw.Window) !Renderer {
        const gctx = try zgpu.GraphicsContext.create(
            allocator,
            .{
                .window = window,
                .fn_getTime = @ptrCast(&zglfw.getTime),
                .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
                .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
                .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
                .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
                .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
                .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
                .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
            },
            .{},
        );
        errdefer gctx.destroy(allocator);

        var self: Renderer = .{
            .allocator = allocator,
            .gctx = gctx,
        };

        self.targets = gbuffer.Targets.create(gctx);
        self.bloom_targets = bloom.Targets.create(gctx);
        self.shadow_maps = shadow.Maps.create(gctx);
        self.point_shadow_maps = shadow.PointMaps.create(gctx);
        self.sampler = gctx.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        self.env = try ibl.Environment.create(gctx, allocator);

        try self.initPipelines();
        self.rebuildBindGroups();

        const verts = mesh.cubeVertices();
        const inds = mesh.cubeIndices();
        self.cube = mesh.createGpuMesh(gctx, verts[0..], inds[0..]);
        const floor_verts = mesh.planeVertices(8.0, 0.0);
        const floor_inds = mesh.planeIndices();
        self.floor = mesh.createGpuMesh(gctx, floor_verts[0..], floor_inds[0..]);

        log.info(.render, "deferred PBR + IBL + bloom + CSM/PCSS + point shadows ready ({d}x{d})", .{
            gctx.swapchain_descriptor.width,
            gctx.swapchain_descriptor.height,
        });
        return self;
    }

    fn initPipelines(self: *Renderer) !void {
        const gctx = self.gctx;

        // --- G-buffer -------------------------------------------------------
        self.gbuffer_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
        });
        const gbuffer_pl = gctx.createPipelineLayout(&.{self.gbuffer_bgl});
        defer gctx.releaseResource(gbuffer_pl);

        {
            const wgsl = try shader.loadFile(self.allocator, "assets/shaders/gbuffer.wgsl");
            defer self.allocator.free(wgsl);
            const module = shader.createModule(gctx.device, wgsl, "gbuffer");
            defer module.release();

            const targets = [_]wgpu.ColorTargetState{
                .{ .format = .rgba8_unorm },
                .{ .format = .rgba16_float },
                .{ .format = .rgba16_float },
            };
            const vbufs = [_]wgpu.VertexBufferLayout{.{
                .array_stride = @sizeOf(mesh.Vertex),
                .attribute_count = mesh.Vertex.attributes.len,
                .attributes = &mesh.Vertex.attributes,
            }};

            self.gbuffer_pipeline = gctx.createRenderPipeline(gbuffer_pl, .{
                .vertex = .{
                    .module = module,
                    .entry_point = "vs_main",
                    .buffer_count = vbufs.len,
                    .buffers = &vbufs,
                },
                .primitive = .{
                    .front_face = .ccw,
                    .cull_mode = .back,
                    .topology = .triangle_list,
                },
                .depth_stencil = &wgpu.DepthStencilState{
                    .format = .depth32_float,
                    .depth_write_enabled = true,
                    .depth_compare = .less,
                },
                .fragment = &wgpu.FragmentState{
                    .module = module,
                    .entry_point = "fs_main",
                    .target_count = targets.len,
                    .targets = &targets,
                },
            });
        }

        // --- Shadow depth ---------------------------------------------------
        self.shadow_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true }, .uniform, true, 0),
        });
        const shadow_pl = gctx.createPipelineLayout(&.{self.shadow_bgl});
        defer gctx.releaseResource(shadow_pl);

        {
            const wgsl = try shader.loadFile(self.allocator, "assets/shaders/shadow.wgsl");
            defer self.allocator.free(wgsl);
            const module = shader.createModule(gctx.device, wgsl, "shadow");
            defer module.release();

            const vbufs = [_]wgpu.VertexBufferLayout{.{
                .array_stride = @sizeOf(mesh.Vertex),
                .attribute_count = 1,
                .attributes = &[_]wgpu.VertexAttribute{.{
                    .format = .float32x3,
                    .offset = @offsetOf(mesh.Vertex, "position"),
                    .shader_location = 0,
                }},
            }};

            self.shadow_pipeline = gctx.createRenderPipeline(shadow_pl, .{
                .vertex = .{
                    .module = module,
                    .entry_point = "vs_main",
                    .buffer_count = vbufs.len,
                    .buffers = &vbufs,
                },
                .primitive = .{
                    .front_face = .ccw,
                    .cull_mode = .front,
                    .topology = .triangle_list,
                },
                .depth_stencil = &wgpu.DepthStencilState{
                    .format = .depth32_float,
                    .depth_write_enabled = true,
                    .depth_compare = .less,
                    .depth_bias = 2,
                    .depth_bias_slope_scale = 1.75,
                    .depth_bias_clamp = 0.0,
                },
            });
        }

        // --- Point shadow cubemap -------------------------------------------
        self.point_shadow_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
        });
        const point_shadow_pl = gctx.createPipelineLayout(&.{self.point_shadow_bgl});
        defer gctx.releaseResource(point_shadow_pl);

        {
            const wgsl = try shader.loadFile(self.allocator, "assets/shaders/shadow_point.wgsl");
            defer self.allocator.free(wgsl);
            const module = shader.createModule(gctx.device, wgsl, "shadow_point");
            defer module.release();

            const vbufs = [_]wgpu.VertexBufferLayout{.{
                .array_stride = @sizeOf(mesh.Vertex),
                .attribute_count = 1,
                .attributes = &[_]wgpu.VertexAttribute{.{
                    .format = .float32x3,
                    .offset = @offsetOf(mesh.Vertex, "position"),
                    .shader_location = 0,
                }},
            }};

            self.point_shadow_pipeline = gctx.createRenderPipeline(point_shadow_pl, .{
                .vertex = .{
                    .module = module,
                    .entry_point = "vs_main",
                    .buffer_count = vbufs.len,
                    .buffers = &vbufs,
                },
                .primitive = .{
                    .front_face = .ccw,
                    .cull_mode = .front,
                    .topology = .triangle_list,
                },
                .depth_stencil = &wgpu.DepthStencilState{
                    .format = .depth32_float,
                    .depth_write_enabled = true,
                    .depth_compare = .less,
                },
                .fragment = &wgpu.FragmentState{
                    .module = module,
                    .entry_point = "fs_main",
                    .target_count = 0,
                    .targets = null,
                },
            });
        }

        // --- Deferred lighting ----------------------------------------------
        self.light_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(3, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(4, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(5, .{ .fragment = true }, .float, .tvdim_cube, false),
            zgpu.samplerEntry(6, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(7, .{ .fragment = true }, .depth, .tvdim_2d_array, false),
            zgpu.samplerEntry(8, .{ .fragment = true }, .comparison),
            zgpu.samplerEntry(9, .{ .fragment = true }, .non_filtering),
            zgpu.textureEntry(10, .{ .fragment = true }, .depth, .tvdim_cube, false),
        });
        const light_pl = gctx.createPipelineLayout(&.{self.light_bgl});
        defer gctx.releaseResource(light_pl);

        {
            const wgsl = try shader.loadFile(self.allocator, "assets/shaders/deferred_light.wgsl");
            defer self.allocator.free(wgsl);
            const module = shader.createModule(gctx.device, wgsl, "deferred_light");
            defer module.release();

            const targets = [_]wgpu.ColorTargetState{.{ .format = .rgba16_float }};
            self.light_pipeline = gctx.createRenderPipeline(light_pl, .{
                .vertex = .{
                    .module = module,
                    .entry_point = "vs_main",
                },
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
        }

        // --- Bloom extract --------------------------------------------------
        self.bloom_extract_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .float, .tvdim_2d, false),
        });
        const extract_pl = gctx.createPipelineLayout(&.{self.bloom_extract_bgl});
        defer gctx.releaseResource(extract_pl);

        {
            const wgsl = try shader.loadFile(self.allocator, "assets/shaders/bloom_extract.wgsl");
            defer self.allocator.free(wgsl);
            const module = shader.createModule(gctx.device, wgsl, "bloom_extract");
            defer module.release();

            const targets = [_]wgpu.ColorTargetState{.{ .format = .rgba16_float }};
            self.bloom_extract_pipeline = gctx.createRenderPipeline(extract_pl, .{
                .vertex = .{
                    .module = module,
                    .entry_point = "vs_main",
                },
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
        }

        // --- Bloom blur -----------------------------------------------------
        self.bloom_blur_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .float, .tvdim_2d, false),
        });
        const blur_pl = gctx.createPipelineLayout(&.{self.bloom_blur_bgl});
        defer gctx.releaseResource(blur_pl);

        {
            const wgsl = try shader.loadFile(self.allocator, "assets/shaders/bloom_blur.wgsl");
            defer self.allocator.free(wgsl);
            const module = shader.createModule(gctx.device, wgsl, "bloom_blur");
            defer module.release();

            const targets = [_]wgpu.ColorTargetState{.{ .format = .rgba16_float }};
            self.bloom_blur_pipeline = gctx.createRenderPipeline(blur_pl, .{
                .vertex = .{
                    .module = module,
                    .entry_point = "vs_main",
                },
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
        }

        // --- Tonemap --------------------------------------------------------
        self.tonemap_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(3, .{ .fragment = true }, .float, .tvdim_2d, false),
        });
        const tonemap_pl = gctx.createPipelineLayout(&.{self.tonemap_bgl});
        defer gctx.releaseResource(tonemap_pl);

        {
            const wgsl = try shader.loadFile(self.allocator, "assets/shaders/tonemap.wgsl");
            defer self.allocator.free(wgsl);
            const module = shader.createModule(gctx.device, wgsl, "tonemap");
            defer module.release();

            const targets = [_]wgpu.ColorTargetState{.{
                .format = zgpu.GraphicsContext.swapchain_format,
            }};
            self.tonemap_pipeline = gctx.createRenderPipeline(tonemap_pl, .{
                .vertex = .{
                    .module = module,
                    .entry_point = "vs_main",
                },
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
        }
    }

    fn rebuildBindGroups(self: *Renderer) void {
        const gctx = self.gctx;

        if (gctx.isResourceValid(self.gbuffer_bg)) gctx.releaseResource(self.gbuffer_bg);
        if (gctx.isResourceValid(self.shadow_bg)) gctx.releaseResource(self.shadow_bg);
        if (gctx.isResourceValid(self.point_shadow_bg)) gctx.releaseResource(self.point_shadow_bg);
        if (gctx.isResourceValid(self.light_bg)) gctx.releaseResource(self.light_bg);
        if (gctx.isResourceValid(self.bloom_extract_bg)) gctx.releaseResource(self.bloom_extract_bg);
        if (gctx.isResourceValid(self.bloom_blur_a_to_b)) gctx.releaseResource(self.bloom_blur_a_to_b);
        if (gctx.isResourceValid(self.bloom_blur_b_to_a)) gctx.releaseResource(self.bloom_blur_b_to_a);
        if (gctx.isResourceValid(self.tonemap_bg)) gctx.releaseResource(self.tonemap_bg);

        self.gbuffer_bg = gctx.createBindGroup(self.gbuffer_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(gbuffer.GBufferUniforms) },
        });
        self.shadow_bg = gctx.createBindGroup(self.shadow_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(shadow.DepthUniforms) },
        });
        self.point_shadow_bg = gctx.createBindGroup(self.point_shadow_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(shadow.PointDepthUniforms) },
        });
        self.light_bg = gctx.createBindGroup(self.light_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(lights.FrameUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.targets.albedo_view },
            .{ .binding = 3, .texture_view_handle = self.targets.normal_view },
            .{ .binding = 4, .texture_view_handle = self.targets.world_pos_view },
            .{ .binding = 5, .texture_view_handle = self.env.cubemap_view },
            .{ .binding = 6, .sampler_handle = self.env.sampler },
            .{ .binding = 7, .texture_view_handle = self.shadow_maps.array_view },
            .{ .binding = 8, .sampler_handle = self.shadow_maps.comparison_sampler },
            .{ .binding = 9, .sampler_handle = self.shadow_maps.depth_sampler },
            .{ .binding = 10, .texture_view_handle = self.point_shadow_maps.cube_view },
        });
        self.bloom_extract_bg = gctx.createBindGroup(self.bloom_extract_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(bloom.ExtractUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.targets.hdr_view },
        });
        self.bloom_blur_a_to_b = gctx.createBindGroup(self.bloom_blur_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(bloom.BlurUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.bloom_targets.a_view },
        });
        self.bloom_blur_b_to_a = gctx.createBindGroup(self.bloom_blur_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(bloom.BlurUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.bloom_targets.b_view },
        });
        self.tonemap_bg = gctx.createBindGroup(self.tonemap_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(bloom.TonemapUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.targets.hdr_view },
            .{ .binding = 3, .texture_view_handle = self.bloom_targets.a_view },
        });
    }

    pub fn destroy(self: *Renderer) void {
        self.point_shadow_maps.destroy(self.gctx);
        self.shadow_maps.destroy(self.gctx);
        self.bloom_targets.destroy(self.gctx);
        self.targets.destroy(self.gctx);
        self.gctx.destroy(self.allocator);
        self.* = undefined;
    }

    pub fn drawFrame(self: *Renderer, dt: f32, draw_ui: bool) void {
        const zone = profile.zoneColor(@src(), "Render", 0x00_ee_55_22);
        defer zone.End();

        self.time += dt;
        const gctx = self.gctx;
        const aspect = self.framebufferAspect();

        const object_to_world = zm.mul(
            zm.translation(0, 0.5, 0),
            zm.mul(
                zm.rotationY(self.time),
                zm.rotationX(self.time * 0.35),
            ),
        );
        const floor_to_world = zm.identity();
        const world_to_clip = self.camera.viewProjection(aspect);
        const object_to_clip = zm.mul(object_to_world, world_to_clip);
        const floor_to_clip = zm.mul(floor_to_world, world_to_clip);

        const sun_dir = [3]f32{ 0.45, 0.85, -0.35 };
        const cascades = shadow.computeCascades(self.camera, aspect, sun_dir, self.shadow_max_distance);

        const cam_pos = self.camera.position;
        const orbit_r: f32 = 2.2;
        const point_pos = [3]f32{
            @cos(self.time * 1.1) * orbit_r,
            0.6 + 0.25 * @sin(self.time * 2.0),
            @sin(self.time * 1.1) * orbit_r,
        };

        const scene_lights = [_]lights.Light{
            .{
                .kind = .directional,
                .position_or_direction = sun_dir,
                .color = .{ 1.0, 0.96, 0.90 },
                .intensity = 2.2,
            },
            .{
                .kind = .point,
                .position_or_direction = point_pos,
                .color = .{ 0.35, 0.75, 1.0 },
                .intensity = 8.0,
                .range = 6.0,
            },
            .{
                .kind = .spot,
                .position_or_direction = .{ -1.8, 2.5, -1.5 },
                .spot_direction = .{ 0.45, -1.0, 0.35 },
                .color = .{ 1.0, 0.55, 0.20 },
                .intensity = 18.0,
                .range = 10.0,
                .inner_cone = std.math.degreesToRadians(12.0),
                .outer_cone = std.math.degreesToRadians(28.0),
            },
        };

        const back_buffer_view = gctx.swapchain.getCurrentTextureView();
        defer back_buffer_view.release();

        const commands = commands: {
            const encoder = gctx.device.createCommandEncoder(null);
            defer encoder.release();

            // Pass 0: cascaded shadow maps
            {
                const pipeline = gctx.lookupResource(self.shadow_pipeline);
                const bind_group = gctx.lookupResource(self.shadow_bg);
                const cube_vb = gctx.lookupResourceInfo(self.cube.vertex_buffer);
                const cube_ib = gctx.lookupResourceInfo(self.cube.index_buffer);
                const floor_vb = gctx.lookupResourceInfo(self.floor.vertex_buffer);
                const floor_ib = gctx.lookupResourceInfo(self.floor.index_buffer);

                if (pipeline != null and bind_group != null and cube_vb != null and cube_ib != null and floor_vb != null and floor_ib != null) {
                    var cascade_i: u32 = 0;
                    while (cascade_i < shadow.cascade_count) : (cascade_i += 1) {
                        const depth_view = gctx.lookupResource(self.shadow_maps.layer_views[cascade_i]) orelse continue;
                        const depth_attachment = wgpu.RenderPassDepthStencilAttachment{
                            .view = depth_view,
                            .depth_load_op = .clear,
                            .depth_store_op = .store,
                            .depth_clear_value = 1.0,
                        };
                        const pass = encoder.beginRenderPass(.{
                            .color_attachment_count = 0,
                            .color_attachments = null,
                            .depth_stencil_attachment = &depth_attachment,
                        });
                        defer {
                            pass.end();
                            pass.release();
                        }

                        pass.setPipeline(pipeline.?);
                        pass.setViewport(0, 0, @floatFromInt(shadow.map_size), @floatFromInt(shadow.map_size), 0, 1);
                        pass.setScissorRect(0, 0, shadow.map_size, shadow.map_size);

                        const light_vp = cascades.light_vp[cascade_i];

                        pass.setVertexBuffer(0, cube_vb.?.gpuobj.?, 0, cube_vb.?.size);
                        pass.setIndexBuffer(cube_ib.?.gpuobj.?, .uint32, 0, cube_ib.?.size);
                        {
                            const mem = gctx.uniformsAllocate(shadow.DepthUniforms, 1);
                            mem.slice[0] = .{
                                .object_to_clip = zm.transpose(zm.mul(object_to_world, light_vp)),
                            };
                            pass.setBindGroup(0, bind_group.?, &.{mem.offset});
                            pass.drawIndexed(self.cube.index_count, 1, 0, 0, 0);
                        }

                        pass.setVertexBuffer(0, floor_vb.?.gpuobj.?, 0, floor_vb.?.size);
                        pass.setIndexBuffer(floor_ib.?.gpuobj.?, .uint32, 0, floor_ib.?.size);
                        {
                            const mem = gctx.uniformsAllocate(shadow.DepthUniforms, 1);
                            mem.slice[0] = .{
                                .object_to_clip = zm.transpose(zm.mul(floor_to_world, light_vp)),
                            };
                            pass.setBindGroup(0, bind_group.?, &.{mem.offset});
                            pass.drawIndexed(self.floor.index_count, 1, 0, 0, 0);
                        }
                    }
                }
            }

            // Pass 0b: point light cubemap shadows
            {
                const pipeline = gctx.lookupResource(self.point_shadow_pipeline);
                const bind_group = gctx.lookupResource(self.point_shadow_bg);
                const cube_vb = gctx.lookupResourceInfo(self.cube.vertex_buffer);
                const cube_ib = gctx.lookupResourceInfo(self.cube.index_buffer);
                const floor_vb = gctx.lookupResourceInfo(self.floor.vertex_buffer);
                const floor_ib = gctx.lookupResourceInfo(self.floor.index_buffer);

                if (pipeline != null and bind_group != null and cube_vb != null and cube_ib != null and floor_vb != null and floor_ib != null) {
                    const face_vps = shadow.pointFaceViewProjs(point_pos, self.point_shadow_near, 6.0);
                    const light_pos_range = [4]f32{ point_pos[0], point_pos[1], point_pos[2], 6.0 };

                    var face_i: u32 = 0;
                    while (face_i < shadow.point_face_count) : (face_i += 1) {
                        const depth_view = gctx.lookupResource(self.point_shadow_maps.face_views[face_i]) orelse continue;
                        const depth_attachment = wgpu.RenderPassDepthStencilAttachment{
                            .view = depth_view,
                            .depth_load_op = .clear,
                            .depth_store_op = .store,
                            .depth_clear_value = 1.0,
                        };
                        const pass = encoder.beginRenderPass(.{
                            .color_attachment_count = 0,
                            .color_attachments = null,
                            .depth_stencil_attachment = &depth_attachment,
                        });
                        defer {
                            pass.end();
                            pass.release();
                        }

                        pass.setPipeline(pipeline.?);
                        pass.setViewport(0, 0, @floatFromInt(shadow.point_map_size), @floatFromInt(shadow.point_map_size), 0, 1);
                        pass.setScissorRect(0, 0, shadow.point_map_size, shadow.point_map_size);

                        const face_vp = face_vps[face_i];

                        pass.setVertexBuffer(0, cube_vb.?.gpuobj.?, 0, cube_vb.?.size);
                        pass.setIndexBuffer(cube_ib.?.gpuobj.?, .uint32, 0, cube_ib.?.size);
                        {
                            const mem = gctx.uniformsAllocate(shadow.PointDepthUniforms, 1);
                            mem.slice[0] = .{
                                .object_to_clip = zm.transpose(zm.mul(object_to_world, face_vp)),
                                .object_to_world = zm.transpose(object_to_world),
                                .light_pos_range = light_pos_range,
                            };
                            pass.setBindGroup(0, bind_group.?, &.{mem.offset});
                            pass.drawIndexed(self.cube.index_count, 1, 0, 0, 0);
                        }

                        pass.setVertexBuffer(0, floor_vb.?.gpuobj.?, 0, floor_vb.?.size);
                        pass.setIndexBuffer(floor_ib.?.gpuobj.?, .uint32, 0, floor_ib.?.size);
                        {
                            const mem = gctx.uniformsAllocate(shadow.PointDepthUniforms, 1);
                            mem.slice[0] = .{
                                .object_to_clip = zm.transpose(zm.mul(floor_to_world, face_vp)),
                                .object_to_world = zm.transpose(floor_to_world),
                                .light_pos_range = light_pos_range,
                            };
                            pass.setBindGroup(0, bind_group.?, &.{mem.offset});
                            pass.drawIndexed(self.floor.index_count, 1, 0, 0, 0);
                        }
                    }
                }
            }

            // Pass 1: G-buffer
            gbuffer_pass: {
                const cube_vb = gctx.lookupResourceInfo(self.cube.vertex_buffer) orelse break :gbuffer_pass;
                const cube_ib = gctx.lookupResourceInfo(self.cube.index_buffer) orelse break :gbuffer_pass;
                const floor_vb = gctx.lookupResourceInfo(self.floor.vertex_buffer) orelse break :gbuffer_pass;
                const floor_ib = gctx.lookupResourceInfo(self.floor.index_buffer) orelse break :gbuffer_pass;
                const pipeline = gctx.lookupResource(self.gbuffer_pipeline) orelse break :gbuffer_pass;
                const bind_group = gctx.lookupResource(self.gbuffer_bg) orelse break :gbuffer_pass;
                const albedo_view = gctx.lookupResource(self.targets.albedo_view) orelse break :gbuffer_pass;
                const normal_view = gctx.lookupResource(self.targets.normal_view) orelse break :gbuffer_pass;
                const world_view = gctx.lookupResource(self.targets.world_pos_view) orelse break :gbuffer_pass;
                const depth_view = gctx.lookupResource(self.targets.depth_view) orelse break :gbuffer_pass;

                const color_attachments = [_]wgpu.RenderPassColorAttachment{
                    .{ .view = albedo_view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } },
                    .{ .view = normal_view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
                    .{ .view = world_view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
                };
                const depth_attachment = wgpu.RenderPassDepthStencilAttachment{
                    .view = depth_view,
                    .depth_load_op = .clear,
                    .depth_store_op = .store,
                    .depth_clear_value = 1.0,
                };
                const pass = encoder.beginRenderPass(.{
                    .color_attachment_count = color_attachments.len,
                    .color_attachments = &color_attachments,
                    .depth_stencil_attachment = &depth_attachment,
                });
                defer {
                    pass.end();
                    pass.release();
                }

                pass.setPipeline(pipeline);

                pass.setVertexBuffer(0, cube_vb.gpuobj.?, 0, cube_vb.size);
                pass.setIndexBuffer(cube_ib.gpuobj.?, .uint32, 0, cube_ib.size);
                {
                    const mem = gctx.uniformsAllocate(gbuffer.GBufferUniforms, 1);
                    mem.slice[0] = .{
                        .object_to_clip = zm.transpose(object_to_clip),
                        .object_to_world = zm.transpose(object_to_world),
                        .material = .{ self.metallic, self.roughness, self.ao, 0 },
                    };
                    pass.setBindGroup(0, bind_group, &.{mem.offset});
                    pass.drawIndexed(self.cube.index_count, 1, 0, 0, 0);
                }

                pass.setVertexBuffer(0, floor_vb.gpuobj.?, 0, floor_vb.size);
                pass.setIndexBuffer(floor_ib.gpuobj.?, .uint32, 0, floor_ib.size);
                {
                    const mem = gctx.uniformsAllocate(gbuffer.GBufferUniforms, 1);
                    mem.slice[0] = .{
                        .object_to_clip = zm.transpose(floor_to_clip),
                        .object_to_world = zm.transpose(floor_to_world),
                        .material = .{ 0.0, 0.85, 1.0, 0 },
                    };
                    pass.setBindGroup(0, bind_group, &.{mem.offset});
                    pass.drawIndexed(self.floor.index_count, 1, 0, 0, 0);
                }
            }

            // Pass 2: deferred lighting → HDR
            light_pass: {
                const pipeline = gctx.lookupResource(self.light_pipeline) orelse break :light_pass;
                const bind_group = gctx.lookupResource(self.light_bg) orelse break :light_pass;
                const hdr_view = gctx.lookupResource(self.targets.hdr_view) orelse break :light_pass;

                const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                    .view = hdr_view,
                    .load_op = .clear,
                    .store_op = .store,
                    .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
                }};
                const pass = encoder.beginRenderPass(.{
                    .color_attachment_count = color_attachments.len,
                    .color_attachments = &color_attachments,
                });
                defer {
                    pass.end();
                    pass.release();
                }

                pass.setPipeline(pipeline);
                const mem = gctx.uniformsAllocate(lights.FrameUniforms, 1);
                mem.slice[0] = lights.packFrame(
                    cam_pos,
                    .{ 0.0, 0.0, 0.0 },
                    &scene_lights,
                    self.env.sh,
                    self.env.max_mip,
                    self.ibl_intensity,
                    cascades,
                    .{ self.shadow_depth_bias, self.shadow_normal_bias, self.shadow_light_size, 1.0 },
                    .{ self.point_shadow_bias, self.point_shadow_soft, 1.0, 0.0 },
                );
                pass.setBindGroup(0, bind_group, &.{mem.offset});
                pass.draw(3, 1, 0, 0);
            }

            // Pass 3: bloom extract (HDR → bloom A half-res)
            bloom_extract: {
                const pipeline = gctx.lookupResource(self.bloom_extract_pipeline) orelse break :bloom_extract;
                const bind_group = gctx.lookupResource(self.bloom_extract_bg) orelse break :bloom_extract;
                const dst = gctx.lookupResource(self.bloom_targets.a_view) orelse break :bloom_extract;

                const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                    .view = dst,
                    .load_op = .clear,
                    .store_op = .store,
                    .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
                }};
                const pass = encoder.beginRenderPass(.{
                    .color_attachment_count = color_attachments.len,
                    .color_attachments = &color_attachments,
                });
                defer {
                    pass.end();
                    pass.release();
                }

                pass.setPipeline(pipeline);
                const mem = gctx.uniformsAllocate(bloom.ExtractUniforms, 1);
                mem.slice[0] = .{ .params = .{ self.bloom_threshold, self.bloom_knee, 0, 0 } };
                pass.setBindGroup(0, bind_group, &.{mem.offset});
                pass.draw(3, 1, 0, 0);
            }

            // Pass 4: separable blur (2 iterations H/V)
            {
                const texel_x = 1.0 / @as(f32, @floatFromInt(self.bloom_targets.width));
                const texel_y = 1.0 / @as(f32, @floatFromInt(self.bloom_targets.height));
                const blur_iters: u32 = 2;
                var iter: u32 = 0;
                while (iter < blur_iters) : (iter += 1) {
                    // A → B horizontal
                    blur_h: {
                        const pipeline = gctx.lookupResource(self.bloom_blur_pipeline) orelse break :blur_h;
                        const bind_group = gctx.lookupResource(self.bloom_blur_a_to_b) orelse break :blur_h;
                        const dst = gctx.lookupResource(self.bloom_targets.b_view) orelse break :blur_h;

                        const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                            .view = dst,
                            .load_op = .clear,
                            .store_op = .store,
                            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
                        }};
                        const pass = encoder.beginRenderPass(.{
                            .color_attachment_count = color_attachments.len,
                            .color_attachments = &color_attachments,
                        });
                        defer {
                            pass.end();
                            pass.release();
                        }
                        pass.setPipeline(pipeline);
                        const mem = gctx.uniformsAllocate(bloom.BlurUniforms, 1);
                        mem.slice[0] = .{ .direction = .{ texel_x, 0, 0, 0 } };
                        pass.setBindGroup(0, bind_group, &.{mem.offset});
                        pass.draw(3, 1, 0, 0);
                    }
                    // B → A vertical
                    blur_v: {
                        const pipeline = gctx.lookupResource(self.bloom_blur_pipeline) orelse break :blur_v;
                        const bind_group = gctx.lookupResource(self.bloom_blur_b_to_a) orelse break :blur_v;
                        const dst = gctx.lookupResource(self.bloom_targets.a_view) orelse break :blur_v;

                        const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                            .view = dst,
                            .load_op = .clear,
                            .store_op = .store,
                            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
                        }};
                        const pass = encoder.beginRenderPass(.{
                            .color_attachment_count = color_attachments.len,
                            .color_attachments = &color_attachments,
                        });
                        defer {
                            pass.end();
                            pass.release();
                        }
                        pass.setPipeline(pipeline);
                        const mem = gctx.uniformsAllocate(bloom.BlurUniforms, 1);
                        mem.slice[0] = .{ .direction = .{ 0, texel_y, 0, 0 } };
                        pass.setBindGroup(0, bind_group, &.{mem.offset});
                        pass.draw(3, 1, 0, 0);
                    }
                }
            }

            // Pass 5: ACES tonemap (HDR + bloom) → swapchain
            tonemap_pass: {
                const pipeline = gctx.lookupResource(self.tonemap_pipeline) orelse break :tonemap_pass;
                const bind_group = gctx.lookupResource(self.tonemap_bg) orelse break :tonemap_pass;

                const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                    .view = back_buffer_view,
                    .load_op = .clear,
                    .store_op = .store,
                    .clear_value = .{
                        .r = self.clear_color.r,
                        .g = self.clear_color.g,
                        .b = self.clear_color.b,
                        .a = self.clear_color.a,
                    },
                }};
                const pass = encoder.beginRenderPass(.{
                    .color_attachment_count = color_attachments.len,
                    .color_attachments = &color_attachments,
                });
                defer {
                    pass.end();
                    pass.release();
                }

                pass.setPipeline(pipeline);
                const mem = gctx.uniformsAllocate(bloom.TonemapUniforms, 1);
                mem.slice[0] = .{ .params = .{ self.bloom_strength, 0, 0, 0 } };
                pass.setBindGroup(0, bind_group, &.{mem.offset});
                pass.draw(3, 1, 0, 0);
            }

            if (draw_ui) {
                const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                    .view = back_buffer_view,
                    .load_op = .load,
                    .store_op = .store,
                }};
                const pass = encoder.beginRenderPass(.{
                    .color_attachment_count = color_attachments.len,
                    .color_attachments = &color_attachments,
                });
                defer {
                    pass.end();
                    pass.release();
                }
                zgui.backend.draw(pass);
            }

            break :commands encoder.finish(null);
        };
        defer commands.release();

        gctx.submit(&.{commands});

        if (gctx.present() == .swap_chain_resized) {
            self.targets.resize(gctx);
            self.bloom_targets.resize(gctx);
            self.rebuildBindGroups();
        }
    }

    pub fn framebufferAspect(self: *const Renderer) f32 {
        const w = self.gctx.swapchain_descriptor.width;
        const h = self.gctx.swapchain_descriptor.height;
        if (h == 0) return 1.0;
        return @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(h));
    }
};

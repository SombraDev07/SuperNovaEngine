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
const material = @import("material.zig");
const exposure = @import("exposure.zig");
const draw_list = @import("draw_list.zig");
const render_graph = @import("render_graph.zig");
const gpu_driven = @import("gpu_driven.zig");
const occlusion = @import("occlusion.zig");
const shader_hot = @import("shader_hot.zig");
const terrain_splat = @import("terrain_splat.zig");
const base_pass_mod = @import("base_pass.zig");
const world = @import("../world/root.zig");

pub const ClearColor = struct {
    r: f64 = 0.04,
    g: f64 = 0.05,
    b: f64 = 0.07,
    a: f64 = 1.0,
};

/// Per-frame scratch shared by render-graph nodes (valid only during `drawFrame`).
pub const FrameScratch = struct {
    encoder: ?wgpu.CommandEncoder = null,
    back_buffer: ?wgpu.TextureView = null,
    dt: f32 = 0,
    draw_ui: bool = false,
    cascades: shadow.CascadeData = undefined,
    view: zm.Mat = zm.identity(),
    world_to_clip: zm.Mat = zm.identity(),
    inv_view_proj: zm.Mat = zm.identity(),
    cam_pos: zm.Vec = zm.f32x4(0, 0, 0, 1),
    point_pos: [3]f32 = .{ 0, 0, 0 },
    scene_lights: [16]lights.Light = undefined,
    scene_light_count: u32 = 0,
};

fn asRenderer(ctx: *anyopaque) *Renderer {
    return @ptrCast(@alignCast(ctx));
}

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    camera: Camera = .{},
    clear_color: ClearColor = .{},

    targets: gbuffer.Targets = .{},
    bloom_targets: bloom.Targets = .{},
    shadow_maps: shadow.Maps = .{},
    point_shadow_maps: shadow.PointMaps = .{},
    spot_shadow_maps: shadow.SpotMaps = .{},
    sampler: zgpu.SamplerHandle = .{},
    env: ibl.Environment = .{},
    maps: material.Maps = .{},
    tile_masks: lights.TileMaskBuffer = .{},
    exposure_chain: exposure.Chain = .{},

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

    bloom_upsample_pipeline: zgpu.RenderPipelineHandle = .{},
    bloom_upsample_bgl: zgpu.BindGroupLayoutHandle = .{},

    tonemap_pipeline: zgpu.RenderPipelineHandle = .{},
    tonemap_bgl: zgpu.BindGroupLayoutHandle = .{},
    tonemap_bg_a: zgpu.BindGroupHandle = .{},
    tonemap_bg_b: zgpu.BindGroupHandle = .{},

    lum_reduce_pipeline: zgpu.RenderPipelineHandle = .{},
    lum_reduce_bgl: zgpu.BindGroupLayoutHandle = .{},
    lum_reduce_bg: zgpu.BindGroupHandle = .{},

    lum_hist_pipeline: zgpu.RenderPipelineHandle = .{},
    lum_hist_bgl: zgpu.BindGroupLayoutHandle = .{},
    lum_hist_bg: zgpu.BindGroupHandle = .{},

    lum_avg_pipeline: zgpu.RenderPipelineHandle = .{},
    lum_avg_bgl: zgpu.BindGroupLayoutHandle = .{},
    lum_avg_bg: zgpu.BindGroupHandle = .{},

    exposure_adapt_pipeline: zgpu.RenderPipelineHandle = .{},
    exposure_adapt_bgl: zgpu.BindGroupLayoutHandle = .{},
    exposure_adapt_bg_a: zgpu.BindGroupHandle = .{},
    exposure_adapt_bg_b: zgpu.BindGroupHandle = .{},

    cube: mesh.Mesh = undefined,
    floor: mesh.Mesh = undefined,
    terrain: terrain_splat.TerrainSplat = undefined,
    /// Last streamer passed to `syncTerrain` — used to seat demo props on heightfield.
    height_streamer: ?*const world.Streamer = null,
    base_pass: base_pass_mod.BasePass = undefined,
    shader_cache: shader.Cache = undefined,
    /// When true, only §1.3 clear+cube path (no deferred stack).
    base_only: bool = false,
    present_mode: wgpu.PresentMode = .fifo,
    /// Device-lost: set by Dawn callback → skip draw → quit (WebGPU has no in-process reset).
    device_lost: bool = false,
    time: f32 = 0.0,

    renderables: std.ArrayList(draw_list.Renderable) = .{},
    visible: draw_list.DrawList = undefined,
    graph: render_graph.Graph = undefined,
    gpu_draw: gpu_driven.GpuDriven = .{},
    hiz: occlusion.HiZ = .{},
    shader_watch: shader_hot.HotReload = undefined,
    /// Transient per-frame state for render-graph pass callbacks.
    frame: FrameScratch = .{},

    /// Default PBR params for the demo cube.
    metallic: f32 = 0.15,
    roughness: f32 = 0.35,
    ao: f32 = 1.0,
    ibl_intensity: f32 = 1.0,
    bloom_threshold: f32 = 1.0,
    bloom_knee: f32 = 0.5,
    bloom_strength: f32 = 0.65,
    shadow_max_distance: f32 = 200.0,
    shadow_depth_bias: f32 = 0.002,
    shadow_normal_bias: f32 = 0.02,
    /// World-space light radius used by PCSS penumbra.
    shadow_light_size: f32 = 0.12,
    point_shadow_bias: f32 = 0.015,
    point_shadow_soft: f32 = 1.0,
    point_shadow_near: f32 = 0.05,
    /// Frame counter for sparse cascade updates.
    frame_index: u64 = 0,
    last_csm_cam_pos: [3]f32 = .{ 0, 0, 0 },
    csm_cam_initialized: bool = false,

    pub const CreateOptions = struct {
        present_mode: wgpu.PresentMode = .fifo,
        base_only: bool = false,
    };

    pub fn create(allocator: std.mem.Allocator, window: *zglfw.Window, options: CreateOptions) !Renderer {
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
            .{
                .present_mode = options.present_mode,
                .required_features = &.{
                    .texture_compression_bc,
                },
            },
        );
        errdefer gctx.destroy(allocator);

        var self: Renderer = .{
            .allocator = allocator,
            .gctx = gctx,
            .present_mode = options.present_mode,
            .base_only = options.base_only,
        };
        const fb = window.getFramebufferSize();
        self.camera.setAspectFromSize(@intCast(fb[0]), @intCast(fb[1]));

        self.targets = gbuffer.Targets.create(gctx);
        self.bloom_targets = bloom.Targets.create(gctx);
        self.shadow_maps = shadow.Maps.create(gctx);
        self.point_shadow_maps = shadow.PointMaps.create(gctx);
        self.spot_shadow_maps = shadow.SpotMaps.create(gctx);
        self.sampler = gctx.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        self.env = try ibl.Environment.create(gctx, allocator);
        self.maps = try material.Maps.create(gctx, allocator);
        self.tile_masks = lights.TileMaskBuffer.create(gctx);
        self.exposure_chain = exposure.Chain.create(gctx);

        self.gpu_draw = gpu_driven.GpuDriven.create(gctx);

        self.shader_cache = shader.Cache.init(allocator, gctx.device);

        try self.initPipelines();
        self.rebuildBindGroups();

        const verts = mesh.cubeVertices();
        const inds = mesh.cubeIndices();
        self.cube = mesh.createGpuMesh(gctx, verts[0..], inds[0..]);
        const floor_verts = mesh.planeVertices(8.0, 0.0);
        const floor_inds = mesh.planeIndices();
        self.floor = mesh.createGpuMesh(gctx, floor_verts[0..], floor_inds[0..]);
        self.terrain = try terrain_splat.TerrainSplat.create(gctx, allocator);
        self.base_pass = try base_pass_mod.BasePass.create(gctx, &self.shader_cache);

        self.visible = draw_list.DrawList.init(allocator);
        self.graph = render_graph.Graph.init(allocator, &deferred_frame_nodes);
        self.shader_watch = try shader_hot.HotReload.init(allocator, &shader_hot.watched_shaders);

        log.info(.render, "renderer init present={s} base_only={} device_lost=fatal ({d}x{d})", .{
            @tagName(options.present_mode),
            options.base_only,
            gctx.swapchain_descriptor.width,
            gctx.swapchain_descriptor.height,
        });
        return self;
    }

    fn releasePipelines(self: *Renderer) void {
        const gctx = self.gctx;
        const pipes = [_]*zgpu.RenderPipelineHandle{
            &self.gbuffer_pipeline,
            &self.shadow_pipeline,
            &self.point_shadow_pipeline,
            &self.light_pipeline,
            &self.bloom_extract_pipeline,
            &self.bloom_blur_pipeline,
            &self.bloom_upsample_pipeline,
            &self.tonemap_pipeline,
            &self.lum_reduce_pipeline,
            &self.lum_hist_pipeline,
            &self.lum_avg_pipeline,
            &self.exposure_adapt_pipeline,
        };
        for (pipes) |p| {
            if (gctx.isResourceValid(p.*)) gctx.releaseResource(p.*);
            p.* = .{};
        }
        const bgls = [_]*zgpu.BindGroupLayoutHandle{
            &self.gbuffer_bgl,
            &self.shadow_bgl,
            &self.point_shadow_bgl,
            &self.light_bgl,
            &self.bloom_extract_bgl,
            &self.bloom_blur_bgl,
            &self.bloom_upsample_bgl,
            &self.tonemap_bgl,
            &self.lum_reduce_bgl,
            &self.lum_hist_bgl,
            &self.lum_avg_bgl,
            &self.exposure_adapt_bgl,
        };
        for (bgls) |b| {
            if (gctx.isResourceValid(b.*)) gctx.releaseResource(b.*);
            b.* = .{};
        }
    }

    fn reloadPipelines(self: *Renderer) void {
        self.releasePipelines();
        self.initPipelines() catch |err| {
            log.err(.render, "shader hot-reload failed: {s}", .{@errorName(err)});
            return;
        };
        self.rebuildBindGroups();
        log.info(.render, "pipelines reloaded from WGSL", .{});
    }

    fn initPipelines(self: *Renderer) !void {
        const gctx = self.gctx;

        // --- G-buffer -------------------------------------------------------
        self.gbuffer_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
            zgpu.bufferEntry(1, .{ .vertex = true, .fragment = true }, .read_only_storage, false, 0),
            zgpu.samplerEntry(2, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(3, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(4, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(5, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(6, .{ .fragment = true }, .float, .tvdim_2d, false),
        });
        const gbuffer_pl = gctx.createPipelineLayout(&.{self.gbuffer_bgl});
        defer gctx.releaseResource(gbuffer_pl);

        { const module = try self.shader_cache.getOrLoad("assets/shaders/gbuffer.wgsl"); defer module.release();

            const targets = [_]wgpu.ColorTargetState{
                .{ .format = .rgba8_unorm_srgb },
                .{ .format = .rgba8_unorm },
                .{ .format = .rgba8_unorm },
                .{ .format = .rgba8_unorm_srgb },
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
            zgpu.bufferEntry(1, .{ .vertex = true }, .read_only_storage, false, 0),
        });
        const shadow_pl = gctx.createPipelineLayout(&.{self.shadow_bgl});
        defer gctx.releaseResource(shadow_pl);

        { const module = try self.shader_cache.getOrLoad("assets/shaders/shadow.wgsl"); defer module.release();

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
            zgpu.bufferEntry(1, .{ .vertex = true, .fragment = true }, .read_only_storage, false, 0),
        });
        const point_shadow_pl = gctx.createPipelineLayout(&.{self.point_shadow_bgl});
        defer gctx.releaseResource(point_shadow_pl);

        { const module = try self.shader_cache.getOrLoad("assets/shaders/shadow_point.wgsl"); defer module.release();

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
            zgpu.textureEntry(5, .{ .fragment = true }, .depth, .tvdim_2d, false),
            zgpu.textureEntry(6, .{ .fragment = true }, .float, .tvdim_cube, false),
            zgpu.samplerEntry(7, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(8, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.samplerEntry(9, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(10, .{ .fragment = true }, .depth, .tvdim_2d_array, false),
            zgpu.samplerEntry(11, .{ .fragment = true }, .comparison),
            zgpu.samplerEntry(12, .{ .fragment = true }, .non_filtering),
            zgpu.textureEntry(13, .{ .fragment = true }, .depth, .tvdim_cube_array, false),
            zgpu.bufferEntry(14, .{ .fragment = true }, .read_only_storage, false, 0),
            zgpu.textureEntry(15, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(16, .{ .fragment = true }, .depth, .tvdim_2d_array, false),
        });
        const light_pl = gctx.createPipelineLayout(&.{self.light_bgl});
        defer gctx.releaseResource(light_pl);

        { const module = try self.shader_cache.getOrLoad("assets/shaders/deferred_light.wgsl"); defer module.release();

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

        { const module = try self.shader_cache.getOrLoad("assets/shaders/bloom_extract.wgsl"); defer module.release();

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

        { const module = try self.shader_cache.getOrLoad("assets/shaders/bloom_blur.wgsl"); defer module.release();

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

        // --- Bloom upsample -------------------------------------------------
        self.bloom_upsample_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(3, .{ .fragment = true }, .float, .tvdim_2d, false),
        });
        const upsample_pl = gctx.createPipelineLayout(&.{self.bloom_upsample_bgl});
        defer gctx.releaseResource(upsample_pl);

        { const module = try self.shader_cache.getOrLoad("assets/shaders/bloom_upsample.wgsl"); defer module.release();

            const targets = [_]wgpu.ColorTargetState{.{ .format = .rgba16_float }};
            self.bloom_upsample_pipeline = gctx.createRenderPipeline(upsample_pl, .{
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
            zgpu.textureEntry(4, .{ .fragment = true }, .float, .tvdim_2d, false),
        });
        const tonemap_pl = gctx.createPipelineLayout(&.{self.tonemap_bgl});
        defer gctx.releaseResource(tonemap_pl);

        { const module = try self.shader_cache.getOrLoad("assets/shaders/tonemap.wgsl"); defer module.release();

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

        // --- Luminance reduce / avg / exposure adapt ------------------------
        self.lum_reduce_bgl = gctx.createBindGroupLayout(&.{
            zgpu.samplerEntry(0, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(1, .{ .fragment = true }, .float, .tvdim_2d, false),
        });
        {
            const pl = gctx.createPipelineLayout(&.{self.lum_reduce_bgl});
            defer gctx.releaseResource(pl);
            const module = try self.shader_cache.getOrLoad("assets/shaders/lum_reduce.wgsl");
            defer module.release();
            const targets = [_]wgpu.ColorTargetState{.{ .format = .rgba16_float }};
            self.lum_reduce_pipeline = gctx.createRenderPipeline(pl, .{
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

        self.lum_hist_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .float, .tvdim_2d, false),
        });
        {
            const pl = gctx.createPipelineLayout(&.{self.lum_hist_bgl});
            defer gctx.releaseResource(pl);
            const module = try self.shader_cache.getOrLoad("assets/shaders/lum_hist.wgsl");
            defer module.release();
            const targets = [_]wgpu.ColorTargetState{.{ .format = .rgba16_float }};
            self.lum_hist_pipeline = gctx.createRenderPipeline(pl, .{
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

        self.lum_avg_bgl = gctx.createBindGroupLayout(&.{
            zgpu.samplerEntry(0, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(1, .{ .fragment = true }, .float, .tvdim_2d, false),
        });
        {
            const pl = gctx.createPipelineLayout(&.{self.lum_avg_bgl});
            defer gctx.releaseResource(pl);
            const module = try self.shader_cache.getOrLoad("assets/shaders/lum_avg.wgsl");
            defer module.release();
            const targets = [_]wgpu.ColorTargetState{.{ .format = .rgba16_float }};
            self.lum_avg_pipeline = gctx.createRenderPipeline(pl, .{
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

        self.exposure_adapt_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(3, .{ .fragment = true }, .float, .tvdim_2d, false),
        });
        {
            const pl = gctx.createPipelineLayout(&.{self.exposure_adapt_bgl});
            defer gctx.releaseResource(pl);
            const module = try self.shader_cache.getOrLoad("assets/shaders/exposure_adapt.wgsl");
            defer module.release();
            const targets = [_]wgpu.ColorTargetState{.{ .format = .rgba16_float }};
            self.exposure_adapt_pipeline = gctx.createRenderPipeline(pl, .{
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
        if (gctx.isResourceValid(self.tonemap_bg_a)) gctx.releaseResource(self.tonemap_bg_a);
        if (gctx.isResourceValid(self.tonemap_bg_b)) gctx.releaseResource(self.tonemap_bg_b);
        if (gctx.isResourceValid(self.lum_reduce_bg)) gctx.releaseResource(self.lum_reduce_bg);
        if (gctx.isResourceValid(self.lum_hist_bg)) gctx.releaseResource(self.lum_hist_bg);
        if (gctx.isResourceValid(self.lum_avg_bg)) gctx.releaseResource(self.lum_avg_bg);
        if (gctx.isResourceValid(self.exposure_adapt_bg_a)) gctx.releaseResource(self.exposure_adapt_bg_a);
        if (gctx.isResourceValid(self.exposure_adapt_bg_b)) gctx.releaseResource(self.exposure_adapt_bg_b);

        self.gbuffer_bg = gctx.createBindGroup(self.gbuffer_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(gbuffer.GBufferUniforms) },
            .{ .binding = 1, .buffer_handle = self.gpu_draw.gbuffer_instances, .offset = 0, .size = gpu_driven.max_instances * @sizeOf(gpu_driven.InstanceGpu) },
            .{ .binding = 2, .sampler_handle = self.maps.sampler },
            .{ .binding = 3, .texture_view_handle = self.maps.albedo_view },
            .{ .binding = 4, .texture_view_handle = self.maps.normal_view },
            .{ .binding = 5, .texture_view_handle = self.maps.orm_view },
            .{ .binding = 6, .texture_view_handle = self.maps.emissive_view },
        });
        self.shadow_bg = gctx.createBindGroup(self.shadow_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(shadow.DepthUniforms) },
            .{ .binding = 1, .buffer_handle = self.gpu_draw.shadow_instances, .offset = 0, .size = gpu_driven.max_instances * @sizeOf(gpu_driven.InstanceGpu) },
        });
        self.point_shadow_bg = gctx.createBindGroup(self.point_shadow_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(shadow.PointDepthUniforms) },
            .{ .binding = 1, .buffer_handle = self.gpu_draw.shadow_instances, .offset = 0, .size = gpu_driven.max_instances * @sizeOf(gpu_driven.InstanceGpu) },
        });
        self.light_bg = gctx.createBindGroup(self.light_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(lights.FrameUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.targets.albedo_view },
            .{ .binding = 3, .texture_view_handle = self.targets.normal_view },
            .{ .binding = 4, .texture_view_handle = self.targets.material_view },
            .{ .binding = 5, .texture_view_handle = self.targets.depth_view },
            .{ .binding = 6, .texture_view_handle = self.env.cubemap_view },
            .{ .binding = 7, .sampler_handle = self.env.sampler },
            .{ .binding = 8, .texture_view_handle = self.env.dfg_view },
            .{ .binding = 9, .sampler_handle = self.env.dfg_sampler },
            .{ .binding = 10, .texture_view_handle = self.shadow_maps.array_view },
            .{ .binding = 11, .sampler_handle = self.shadow_maps.comparison_sampler },
            .{ .binding = 12, .sampler_handle = self.shadow_maps.depth_sampler },
            .{ .binding = 13, .texture_view_handle = self.point_shadow_maps.cube_array_view },
            .{ .binding = 14, .buffer_handle = self.tile_masks.buffer, .offset = 0, .size = lights.tile_count * @sizeOf(u32) },
            .{ .binding = 15, .texture_view_handle = self.targets.emissive_view },
            .{ .binding = 16, .texture_view_handle = self.spot_shadow_maps.array_view },
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
        self.lum_reduce_bg = gctx.createBindGroup(self.lum_reduce_bgl, &.{
            .{ .binding = 0, .sampler_handle = self.sampler },
            .{ .binding = 1, .texture_view_handle = self.targets.hdr_view },
        });
        self.lum_hist_bg = gctx.createBindGroup(self.lum_hist_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(exposure.HistUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.exposure_chain.lum_mid_view },
        });
        self.lum_avg_bg = gctx.createBindGroup(self.lum_avg_bgl, &.{
            .{ .binding = 0, .sampler_handle = self.sampler },
            .{ .binding = 1, .texture_view_handle = self.exposure_chain.hist_view },
        });
        self.exposure_adapt_bg_a = gctx.createBindGroup(self.exposure_adapt_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(exposure.AdaptUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.exposure_chain.lum_1x1_view },
            .{ .binding = 3, .texture_view_handle = self.exposure_chain.exp_a_view },
        });
        self.exposure_adapt_bg_b = gctx.createBindGroup(self.exposure_adapt_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(exposure.AdaptUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.exposure_chain.lum_1x1_view },
            .{ .binding = 3, .texture_view_handle = self.exposure_chain.exp_b_view },
        });
        self.tonemap_bg_a = gctx.createBindGroup(self.tonemap_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(bloom.TonemapUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.targets.hdr_view },
            .{ .binding = 3, .texture_view_handle = self.bloom_targets.blur_views[0] },
            .{ .binding = 4, .texture_view_handle = self.exposure_chain.exp_a_view },
        });
        self.tonemap_bg_b = gctx.createBindGroup(self.tonemap_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(bloom.TonemapUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.targets.hdr_view },
            .{ .binding = 3, .texture_view_handle = self.bloom_targets.blur_views[0] },
            .{ .binding = 4, .texture_view_handle = self.exposure_chain.exp_b_view },
        });
    }

    pub fn syncTerrain(self: *Renderer, streamer: *world.Streamer) !void {
        self.height_streamer = streamer;
        try self.terrain.sync(self.gctx, streamer);
    }

    /// Dagor workCycle `is_need_to_draw` — skip when minimized / zero framebuffer / unfocused.
    pub fn shouldDraw(window: *zglfw.Window) bool {
        if (window.getAttribute(.iconified)) return false;
        if (!window.getAttribute(.focused)) return false;
        const fb = window.getFramebufferSize();
        return fb[0] > 0 and fb[1] > 0;
    }

    pub fn onFramebufferResize(self: *Renderer, width: u32, height: u32) void {
        self.camera.setAspectFromSize(width, height);
    }

    pub fn isDeviceLost(self: *const Renderer) bool {
        return self.device_lost;
    }

    /// Must be called with a stable `*Renderer` (not a temporary).
    pub fn installDeviceLostHandler(self: *Renderer) void {
        self.gctx.device.setDeviceLostCallback(onDeviceLost, self);
    }

    /// Runtime vsync / present mode (Dagor `enable_vsync` role).
    pub fn setPresentMode(self: *Renderer, mode: wgpu.PresentMode) void {
        if (self.present_mode == mode) return;
        self.present_mode = mode;
        const gctx = self.gctx;
        gctx.swapchain_descriptor.present_mode = mode;
        gctx.swapchain.release();
        gctx.swapchain = gctx.device.createSwapChain(gctx.surface, gctx.swapchain_descriptor);
        log.info(.render, "present_mode -> {s}", .{@tagName(mode)});
    }

    pub fn setVsync(self: *Renderer, enabled: bool, adaptive: bool) void {
        if (!enabled) {
            self.setPresentMode(.immediate);
        } else if (adaptive) {
            self.setPresentMode(.fifo);
        } else {
            self.setPresentMode(.fifo);
        }
    }

    fn onDeviceLost(reason: wgpu.DeviceLostReason, message: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Renderer = @ptrCast(@alignCast(userdata.?));
        self.device_lost = true;
        const msg = if (message) |m| std.mem.span(m) else "unknown";
        log.err(.render, "device lost reason={s}: {s} (restart required)", .{ @tagName(reason), msg });
    }

    pub fn destroy(self: *Renderer) void {
        self.shader_watch.deinit();
        self.base_pass.destroy(self.gctx);
        self.shader_cache.deinit();
        self.terrain.destroy(self.gctx);
        self.gpu_draw.destroy(self.gctx);
        self.graph.deinit();
        self.visible.deinit();
        self.renderables.deinit(self.allocator);
        self.exposure_chain.destroy(self.gctx);
        self.tile_masks.destroy(self.gctx);
        self.maps.destroy(self.gctx);
        self.point_shadow_maps.destroy(self.gctx);
        self.spot_shadow_maps.destroy(self.gctx);
        self.shadow_maps.destroy(self.gctx);
        self.bloom_targets.destroy(self.gctx);
        self.targets.destroy(self.gctx);
        self.gctx.destroy(self.allocator);
        self.* = undefined;
    }

    fn meshFor(self: *Renderer, kind: draw_list.MeshKind) *mesh.Mesh {
        return switch (kind) {
            .cube => &self.cube,
            .floor => &self.floor,
        };
    }

    fn bindMesh(self: *Renderer, pass: wgpu.RenderPassEncoder, kind: draw_list.MeshKind) ?u32 {
        const m = self.meshFor(kind);
        const vb = self.gctx.lookupResourceInfo(m.vertex_buffer) orelse return null;
        const ib = self.gctx.lookupResourceInfo(m.index_buffer) orelse return null;
        pass.setVertexBuffer(0, vb.gpuobj.?, 0, vb.size);
        pass.setIndexBuffer(ib.gpuobj.?, .uint32, 0, ib.size);
        return m.index_count;
    }

    fn meshIndexCounts(self: *Renderer) [gpu_driven.mesh_kind_count]u32 {
        return .{ self.cube.index_count, self.floor.index_count };
    }

    fn drawIndirectBatches(
        self: *Renderer,
        pass: wgpu.RenderPassEncoder,
        bind_group: wgpu.BindGroup,
        uniform_offset: u32,
        upload: gpu_driven.UploadResult,
        indirect_handle: zgpu.BufferHandle,
    ) void {
        const indirect_buf = self.gctx.lookupResource(indirect_handle) orelse return;
        var i: u32 = 0;
        while (i < upload.batch_count) : (i += 1) {
            const batch = upload.batches[i];
            if (batch.instance_count == 0) continue;
            _ = self.bindMesh(pass, batch.mesh) orelse continue;
            pass.setBindGroup(0, bind_group, &.{uniform_offset});
            const args_offset: u64 = @as(u64, batch.indirect_index) * @sizeOf(gpu_driven.DrawIndexedIndirectArgs);
            pass.drawIndexedIndirect(indirect_buf, args_offset);
        }
    }

    fn drawCastersDepth(self: *Renderer, pass: wgpu.RenderPassEncoder, bind_group: wgpu.BindGroup, light_vp: zm.Mat) void {
        const mem = self.gctx.uniformsAllocate(shadow.DepthUniforms, 1);
        mem.slice[0] = .{ .light_vp = zm.transpose(light_vp) };
        self.drawIndirectBatches(pass, bind_group, mem.offset, self.gpu_draw.shadow_upload, self.gpu_draw.shadow_indirect);
    }

    fn drawCastersPointDepth(
        self: *Renderer,
        pass: wgpu.RenderPassEncoder,
        bind_group: wgpu.BindGroup,
        face_vp: zm.Mat,
        light_pos_range: [4]f32,
    ) void {
        const mem = self.gctx.uniformsAllocate(shadow.PointDepthUniforms, 1);
        mem.slice[0] = .{
            .face_vp = zm.transpose(face_vp),
            .light_pos_range = light_pos_range,
        };
        self.drawIndirectBatches(pass, bind_group, mem.offset, self.gpu_draw.shadow_upload, self.gpu_draw.shadow_indirect);
    }

    fn drawVisibleGBuffer(self: *Renderer, pass: wgpu.RenderPassEncoder, bind_group: wgpu.BindGroup) void {
        const mem = self.gctx.uniformsAllocate(gbuffer.GBufferUniforms, 1);
        mem.slice[0] = .{ .world_to_clip = zm.transpose(self.frame.world_to_clip) };
        self.drawIndirectBatches(pass, bind_group, mem.offset, self.gpu_draw.gbuffer_upload, self.gpu_draw.gbuffer_indirect);
    }

    pub fn drawFrame(self: *Renderer, dt: f32, draw_ui: bool) void {
        const zone = profile.zoneColor(@src(), "Render", 0x00_ee_55_22);
        defer zone.End();

        if (self.device_lost) return;

        self.time += dt;
        const gctx = self.gctx;
        self.camera.setAspectFromSize(gctx.swapchain_descriptor.width, gctx.swapchain_descriptor.height);

        if (self.base_only) {
            self.drawBaseOnlyFrame(draw_ui);
            return;
        }

        if (self.shader_watch.poll()) {
            self.reloadPipelines();
        }
        const aspect = self.camera.aspect;

        const view = self.camera.viewMatrix();
        const world_to_clip = self.camera.viewProjectionOwned();
        const inv_view_proj = zm.inverse(world_to_clip);

        const sun_dir = [3]f32{ 0.45, 0.85, -0.35 };
        const cascades = shadow.computeCascades(self.camera, aspect, sun_dir, self.shadow_max_distance);

        const cam_pos = self.camera.position;
        const ground0: f32 = if (self.height_streamer) |s| s.sampleHeight(0, 0) orelse 0 else 0;
        const orbit_r: f32 = 2.2;
        const point_pos = [3]f32{
            @cos(self.time * 1.1) * orbit_r,
            ground0 + 0.6 + 0.25 * @sin(self.time * 2.0),
            @sin(self.time * 1.1) * orbit_r,
        };

        var scene_lights: [16]lights.Light = [_]lights.Light{.{}} ** 16;
        scene_lights[0] = .{
            .kind = .directional,
            .position_or_direction = sun_dir,
            .color = .{ 1.0, 0.96, 0.90 },
            .intensity = 2.2,
        };
        scene_lights[1] = .{
            .kind = .point,
            .position_or_direction = point_pos,
            .color = .{ 0.35, 0.75, 1.0 },
            .intensity = 8.0,
            .range = 6.0,
        };
        scene_lights[2] = .{
            .kind = .spot,
            .position_or_direction = .{ -1.8, ground0 + 2.5, -1.5 },
            .spot_direction = .{ 0.45, -1.0, 0.35 },
            .color = .{ 1.0, 0.55, 0.20 },
            .intensity = 18.0,
            .range = 10.0,
            .inner_cone = std.math.degreesToRadians(12.0),
            .outer_cone = std.math.degreesToRadians(28.0),
        };
        scene_lights[3] = .{
            .kind = .point,
            .position_or_direction = .{ 3.5, ground0 + 1.2, -2.0 },
            .color = .{ 1.0, 0.3, 0.4 },
            .intensity = 5.0,
            .range = 8.0,
        };
        scene_lights[4] = .{
            .kind = .point,
            .position_or_direction = .{ -3.0, ground0 + 0.8, 2.5 },
            .color = .{ 0.3, 1.0, 0.5 },
            .intensity = 4.5,
            .range = 7.0,
        };
        scene_lights[5] = .{
            .kind = .point,
            .position_or_direction = .{ 0.0, ground0 + 2.0, 4.0 },
            .color = .{ 0.9, 0.9, 0.4 },
            .intensity = 3.5,
            .range = 9.0,
        };
        scene_lights[6] = .{
            .kind = .spot,
            .position_or_direction = .{ 2.5, ground0 + 3.0, 2.0 },
            .spot_direction = .{ -0.3, -1.0, -0.2 },
            .color = .{ 0.6, 0.8, 1.0 },
            .intensity = 12.0,
            .range = 12.0,
            .inner_cone = std.math.degreesToRadians(10.0),
            .outer_cone = std.math.degreesToRadians(24.0),
        };
        scene_lights[7] = .{
            .kind = .point,
            .position_or_direction = .{ -1.5, ground0 + 0.5, -3.5 },
            .color = .{ 0.8, 0.4, 1.0 },
            .intensity = 4.0,
            .range = 6.5,
        };
        scene_lights[8] = .{
            .kind = .point,
            .position_or_direction = .{ 4.0, ground0 + 0.7, 1.0 },
            .color = .{ 1.0, 0.7, 0.3 },
            .intensity = 3.5,
            .range = 5.5,
        };
        scene_lights[9] = .{
            .kind = .point,
            .position_or_direction = .{ -4.0, ground0 + 1.5, -1.0 },
            .color = .{ 0.4, 0.6, 1.0 },
            .intensity = 3.0,
            .range = 7.0,
        };
        scene_lights[10] = .{
            .kind = .point,
            .position_or_direction = .{ 1.5, ground0 + 0.4, -4.5 },
            .color = .{ 0.9, 0.2, 0.6 },
            .intensity = 3.2,
            .range = 5.0,
        };
        scene_lights[11] = .{
            .kind = .spot,
            .position_or_direction = .{ 0.0, ground0 + 4.0, 0.0 },
            .spot_direction = .{ 0.1, -1.0, 0.1 },
            .color = .{ 1.0, 0.95, 0.85 },
            .intensity = 14.0,
            .range = 14.0,
            .inner_cone = std.math.degreesToRadians(8.0),
            .outer_cone = std.math.degreesToRadians(22.0),
        };
        const scene_light_count: u32 = 12;

        draw_list.buildDemoRenderables(
            &self.renderables,
            self.allocator,
            self.time,
            .{ self.metallic, self.roughness, self.ao, 1 },
            self.height_streamer,
        ) catch {};
        self.visible.rebuild(self.renderables.items, world_to_clip, &self.hiz) catch {};

        const index_counts = self.meshIndexCounts();
        self.gpu_draw.uploadShadows(gctx, self.renderables.items, index_counts, cascades.light_vp[0..]);
        self.gpu_draw.uploadGBuffer(gctx, self.visible.items.items, index_counts);

        const back_buffer_view = gctx.swapchain.getCurrentTextureView();
        defer back_buffer_view.release();

        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        self.frame = .{
            .encoder = encoder,
            .back_buffer = back_buffer_view,
            .dt = dt,
            .draw_ui = draw_ui,
            .cascades = cascades,
            .view = view,
            .world_to_clip = world_to_clip,
            .inv_view_proj = inv_view_proj,
            .cam_pos = cam_pos,
            .point_pos = point_pos,
            .scene_lights = scene_lights,
            .scene_light_count = scene_light_count,
        };

        // Full deferred frame
        self.passShadowCsm();
        self.passShadowPoint();
        self.passShadowSpot();
        self.passGBuffer();
        self.passLighting();
        self.passBloom();
        self.passExposure();
        self.passTonemap();
        self.passUi();

        const commands = encoder.finish(null);
        defer commands.release();

        gctx.submit(&.{commands});
        self.frame.encoder = null;

        if (gctx.present() == .swap_chain_resized) {
            self.targets.resize(gctx);
            self.bloom_targets.resize(gctx);
            self.rebuildBindGroups();
            self.onFramebufferResize(gctx.swapchain_descriptor.width, gctx.swapchain_descriptor.height);
        }
    }

    /// §1.3 evidence path: clear + cube via BasePass (independent of deferred).
    /// `draw_ui` must be true only after `zgui.backend.newFrame` (not during boot splash).
    pub fn drawBaseOnlyFrame(self: *Renderer, draw_ui: bool) void {
        const gctx = self.gctx;
        self.camera.setAspectFromSize(gctx.swapchain_descriptor.width, gctx.swapchain_descriptor.height);
        const back_buffer_view = gctx.swapchain.getCurrentTextureView();
        defer back_buffer_view.release();
        self.base_pass.draw(gctx, back_buffer_view, self.camera, .{
            .r = self.clear_color.r,
            .g = self.clear_color.g,
            .b = self.clear_color.b,
            .a = self.clear_color.a,
        });
        if (draw_ui) {
            const encoder = gctx.device.createCommandEncoder(null);
            defer encoder.release();
            const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                .view = back_buffer_view,
                .load_op = .load,
                .store_op = .store,
            }};
            const pass = encoder.beginRenderPass(.{
                .color_attachment_count = color_attachments.len,
                .color_attachments = &color_attachments,
            });
            zgui.backend.draw(pass);
            pass.end();
            pass.release();
            const commands = encoder.finish(null);
            defer commands.release();
            gctx.submit(&.{commands});
        }
        if (gctx.present() == .swap_chain_resized) {
            self.onFramebufferResize(gctx.swapchain_descriptor.width, gctx.swapchain_descriptor.height);
        }
    }

    pub fn framebufferAspect(self: *const Renderer) f32 {
        const w = self.gctx.swapchain_descriptor.width;
        const h = self.gctx.swapchain_descriptor.height;
        if (h == 0) return 1.0;
        return @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(h));
    }

    fn passShadowCsm(self: *Renderer) void {
        const encoder = self.frame.encoder orelse return;
        const gctx = self.gctx;
        const cascades = self.frame.cascades;
        const pipeline = gctx.lookupResource(self.shadow_pipeline);
        const bind_group = gctx.lookupResource(self.shadow_bg);
        if (pipeline == null or bind_group == null) return;

        const cam = self.camera.position;
        var force = !self.csm_cam_initialized;
        if (self.csm_cam_initialized) {
            const dx = cam[0] - self.last_csm_cam_pos[0];
            const dy = cam[1] - self.last_csm_cam_pos[1];
            const dz = cam[2] - self.last_csm_cam_pos[2];
            force = (dx * dx + dy * dy + dz * dz) > (2.5 * 2.5);
        }

        var cascade_i: u32 = 0;
        while (cascade_i < shadow.cascade_count) : (cascade_i += 1) {
            if (!shadow.shouldUpdateCascade(self.frame_index, cascade_i, force)) continue;
            // Per-cascade caster cull (Dagor cascade frustum role).
            const index_counts = self.meshIndexCounts();
            self.gpu_draw.uploadShadows(
                gctx,
                self.renderables.items,
                index_counts,
                self.frame.cascades.light_vp[cascade_i .. cascade_i + 1],
            );
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
            pass.setPipeline(pipeline.?);
            pass.setViewport(0, 0, @floatFromInt(shadow.map_size), @floatFromInt(shadow.map_size), 0, 1);
            pass.setScissorRect(0, 0, shadow.map_size, shadow.map_size);
            self.drawCastersDepth(pass, bind_group.?, cascades.light_vp[cascade_i]);
            pass.end();
            pass.release();
        }
        self.last_csm_cam_pos = .{ cam[0], cam[1], cam[2] };
        self.csm_cam_initialized = true;
    }

    fn passShadowPoint(self: *Renderer) void {
        const encoder = self.frame.encoder orelse return;
        const gctx = self.gctx;
        const pipeline = gctx.lookupResource(self.point_shadow_pipeline);
        const bind_group = gctx.lookupResource(self.point_shadow_bg);
        if (pipeline == null or bind_group == null) return;

        // Full caster set for omni (not cascade-culled).
        const index_counts = self.meshIndexCounts();
        self.gpu_draw.uploadShadows(gctx, self.renderables.items, index_counts, &.{});

        const light_list = self.frame.scene_lights[0..self.frame.scene_light_count];
        const cam = self.camera.position;

        var slot_of: [shadow.max_point_shadow_slots]u32 = undefined;
        var dist_of: [shadow.max_point_shadow_slots]f32 = undefined;
        var n_slots: u32 = 0;
        for (light_list) |light| {
            if (light.kind != .point) continue;
            if (n_slots >= shadow.max_point_shadow_slots) break;
            const dx = light.position_or_direction[0] - cam[0];
            const dy = light.position_or_direction[1] - cam[1];
            const dz = light.position_or_direction[2] - cam[2];
            slot_of[n_slots] = n_slots;
            dist_of[n_slots] = dx * dx + dy * dy + dz * dz;
            n_slots += 1;
        }
        // Sort slot indices by distance (nearest first).
        var a: u32 = 0;
        while (a + 1 < n_slots) : (a += 1) {
            var b = a + 1;
            while (b < n_slots) : (b += 1) {
                if (dist_of[b] < dist_of[a]) {
                    const td = dist_of[a];
                    dist_of[a] = dist_of[b];
                    dist_of[b] = td;
                    const ts = slot_of[a];
                    slot_of[a] = slot_of[b];
                    slot_of[b] = ts;
                }
            }
        }

        var updates: u32 = 0;
        var rank: u32 = 0;
        while (rank < n_slots) : (rank += 1) {
            if (updates >= shadow.max_shadow_updates_per_frame) break;
            const slot = slot_of[rank];
            if (rank >= 4 and (self.frame_index % 2) != 0) continue;
            if (rank >= 6 and (self.frame_index % 4) != 0) continue;

            // Resolve light for this atlas slot (same order as findShadowLights).
            var point_i: u32 = 0;
            var light_idx: ?usize = null;
            for (light_list, 0..) |light, li| {
                if (light.kind != .point) continue;
                if (point_i == slot) {
                    light_idx = li;
                    break;
                }
                point_i += 1;
            }
            const li = light_idx orelse continue;
            const light = light_list[li];
            const point_pos = light.position_or_direction;
            const range = light.range;
            const face_vps = shadow.pointFaceViewProjs(point_pos, self.point_shadow_near, range);
            const light_pos_range = [4]f32{ point_pos[0], point_pos[1], point_pos[2], range };

            var face_i: u32 = 0;
            while (face_i < shadow.point_face_count) : (face_i += 1) {
                const depth_view = gctx.lookupResource(self.point_shadow_maps.faceView(slot, face_i)) orelse continue;
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
                pass.setPipeline(pipeline.?);
                pass.setViewport(0, 0, @floatFromInt(shadow.point_map_size), @floatFromInt(shadow.point_map_size), 0, 1);
                pass.setScissorRect(0, 0, shadow.point_map_size, shadow.point_map_size);
                self.drawCastersPointDepth(pass, bind_group.?, face_vps[face_i], light_pos_range);
                pass.end();
                pass.release();
            }
            updates += 1;
        }
    }

    fn passShadowSpot(self: *Renderer) void {
        const encoder = self.frame.encoder orelse return;
        const gctx = self.gctx;
        const pipeline = gctx.lookupResource(self.shadow_pipeline);
        const bind_group = gctx.lookupResource(self.shadow_bg);
        if (pipeline == null or bind_group == null) return;

        const index_counts = self.meshIndexCounts();
        self.gpu_draw.uploadShadows(gctx, self.renderables.items, index_counts, &.{});

        const light_list = self.frame.scene_lights[0..self.frame.scene_light_count];
        var slot: u32 = 0;
        var updates: u32 = 0;
        for (light_list) |light| {
            if (light.kind != .spot) continue;
            if (slot >= shadow.max_spot_shadow_slots) break;
            if (updates >= shadow.max_shadow_updates_per_frame) break;
            if (slot >= 2 and (self.frame_index % 2) != (slot % 2)) {
                slot += 1;
                continue;
            }
            const vp = shadow.spotLightViewProj(
                light.position_or_direction,
                light.spot_direction,
                self.point_shadow_near,
                light.range,
                light.outer_cone,
            );
            const depth_view = gctx.lookupResource(self.spot_shadow_maps.layer_views[slot]) orelse continue;
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
            pass.setPipeline(pipeline.?);
            pass.setViewport(0, 0, @floatFromInt(shadow.spot_map_size), @floatFromInt(shadow.spot_map_size), 0, 1);
            pass.setScissorRect(0, 0, shadow.spot_map_size, shadow.spot_map_size);
            self.drawCastersDepth(pass, bind_group.?, vp);
            pass.end();
            pass.release();
            updates += 1;
            slot += 1;
        }
    }

    fn passGBuffer(self: *Renderer) void {
        const encoder = self.frame.encoder orelse return;
        const gctx = self.gctx;
        const pipeline = gctx.lookupResource(self.gbuffer_pipeline) orelse return;
        const bind_group = gctx.lookupResource(self.gbuffer_bg) orelse return;
        const albedo_view = gctx.lookupResource(self.targets.albedo_view) orelse return;
        const normal_view = gctx.lookupResource(self.targets.normal_view) orelse return;
        const world_view = gctx.lookupResource(self.targets.material_view) orelse return;
        const emissive_view = gctx.lookupResource(self.targets.emissive_view) orelse return;
        const depth_view = gctx.lookupResource(self.targets.depth_view) orelse return;

        const color_attachments = [_]wgpu.RenderPassColorAttachment{
            .{ .view = albedo_view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } },
            .{ .view = normal_view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
            .{ .view = world_view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
            .{ .view = emissive_view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } },
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
        pass.setPipeline(pipeline);
        self.drawVisibleGBuffer(pass, bind_group);
        self.terrain.draw(gctx, pass, self.frame.world_to_clip);
        pass.end();
        pass.release();
    }

    fn passLighting(self: *Renderer) void {
        const encoder = self.frame.encoder orelse return;
        const gctx = self.gctx;
        const pipeline = gctx.lookupResource(self.light_pipeline) orelse return;
        const bind_group = gctx.lookupResource(self.light_bg) orelse return;
        const hdr_view = gctx.lookupResource(self.targets.hdr_view) orelse return;

        self.tile_masks.rebuild(
            gctx,
            self.frame.scene_lights[0..self.frame.scene_light_count],
            self.frame.world_to_clip,
            self.frame.view,
            self.camera.near,
            self.camera.far,
        );

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
        var spot_vps: [shadow.max_spot_shadow_slots]zm.Mat = [_]zm.Mat{zm.identity()} ** shadow.max_spot_shadow_slots;
        {
            var slot: u32 = 0;
            for (self.frame.scene_lights[0..self.frame.scene_light_count]) |light| {
                if (light.kind != .spot) continue;
                if (slot >= shadow.max_spot_shadow_slots) break;
                spot_vps[slot] = shadow.spotLightViewProj(
                    light.position_or_direction,
                    light.spot_direction,
                    self.point_shadow_near,
                    light.range,
                    light.outer_cone,
                );
                slot += 1;
            }
        }
        const last_split = self.frame.cascades.splits[3];
        mem.slice[0] = lights.packFrame(
            self.frame.inv_view_proj,
            self.frame.view,
            self.frame.cam_pos,
            .{ 0.0, 0.0, 0.0 },
            self.frame.scene_lights[0..self.frame.scene_light_count],
            self.env.sh,
            self.env.max_mip,
            self.ibl_intensity,
            self.camera.near,
            self.camera.far,
            self.frame.cascades,
            .{ self.shadow_depth_bias, self.shadow_normal_bias, self.shadow_light_size, 1.0 },
            .{ self.point_shadow_bias, self.point_shadow_soft, 1.0, 0.2 },
            &spot_vps,
            .{ last_split * 0.75, last_split, 0.1, 0.0 },
        );
        pass.setBindGroup(0, bind_group, &.{mem.offset});
        pass.draw(3, 1, 0, 0);
    }

    fn passBloom(self: *Renderer) void {
        const encoder = self.frame.encoder orelse return;
        const gctx = self.gctx;
        const bt = &self.bloom_targets;

        // 1) Extract bright regions → mip 0
        bloom_extract: {
            const pipeline = gctx.lookupResource(self.bloom_extract_pipeline) orelse break :bloom_extract;
            const bind_group = gctx.lookupResource(self.bloom_extract_bg) orelse break :bloom_extract;
            const dst = gctx.lookupResource(bt.views[0]) orelse break :bloom_extract;
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

        // 2) Blur + downsample pyramid (mip 0 → mip_count-1)
        var level: u32 = 0;
        while (level < bloom.mip_count) : (level += 1) {
            const tw = 1.0 / @as(f32, @floatFromInt(bt.widths[level]));
            const th = 1.0 / @as(f32, @floatFromInt(bt.heights[level]));
            // H blur: levels[level] → blur[level]
            {
                const bg = gctx.createBindGroup(self.bloom_blur_bgl, &.{
                    .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(bloom.BlurUniforms) },
                    .{ .binding = 1, .sampler_handle = self.sampler },
                    .{ .binding = 2, .texture_view_handle = bt.views[level] },
                });
                defer gctx.releaseResource(bg);
                if (gctx.lookupResource(self.bloom_blur_pipeline)) |pipeline| {
                    if (gctx.lookupResource(bg)) |bind_group| {
                        if (gctx.lookupResource(bt.blur_views[level])) |dst| {
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
                            mem.slice[0] = .{ .direction = .{ tw, 0, 0, 0 } };
                            pass.setBindGroup(0, bind_group, &.{mem.offset});
                            pass.draw(3, 1, 0, 0);
                        }
                    }
                }
            }
            // V blur: blur[level] → levels[level]
            {
                const bg = gctx.createBindGroup(self.bloom_blur_bgl, &.{
                    .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(bloom.BlurUniforms) },
                    .{ .binding = 1, .sampler_handle = self.sampler },
                    .{ .binding = 2, .texture_view_handle = bt.blur_views[level] },
                });
                defer gctx.releaseResource(bg);
                if (gctx.lookupResource(self.bloom_blur_pipeline)) |pipeline| {
                    if (gctx.lookupResource(bg)) |bind_group| {
                        if (gctx.lookupResource(bt.views[level])) |dst| {
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
                            mem.slice[0] = .{ .direction = .{ 0, th, 0, 0 } };
                            pass.setBindGroup(0, bind_group, &.{mem.offset});
                            pass.draw(3, 1, 0, 0);
                        }
                    }
                }
            }
            // Downsample to next mip (levels[level] → levels[level+1]) using 4-tap via blur pipeline as box proxy:
            // Use H+V with large texel to approximate downsample into next level.
            if (level + 1 < bloom.mip_count) {
                const bg = gctx.createBindGroup(self.bloom_blur_bgl, &.{
                    .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(bloom.BlurUniforms) },
                    .{ .binding = 1, .sampler_handle = self.sampler },
                    .{ .binding = 2, .texture_view_handle = bt.views[level] },
                });
                defer gctx.releaseResource(bg);
                if (gctx.lookupResource(self.bloom_blur_pipeline)) |pipeline| {
                    if (gctx.lookupResource(bg)) |bind_group| {
                        if (gctx.lookupResource(bt.views[level + 1])) |dst| {
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
                            // Slight blur while sampling parent into child resolution.
                            mem.slice[0] = .{ .direction = .{ tw * 0.5, th * 0.5, 0, 0 } };
                            pass.setBindGroup(0, bind_group, &.{mem.offset});
                            pass.draw(3, 1, 0, 0);
                        }
                    }
                }
            }
        }

        // 3) Upsample coarse → fine into blur[level] (final composite in blur[0])
        {
            var up_level: i32 = @as(i32, @intCast(bloom.mip_count)) - 2;
            while (up_level >= 0) : (up_level -= 1) {
                const li: u32 = @intCast(up_level);
                const coarse_view = if (li + 1 == bloom.mip_count - 1)
                    bt.views[li + 1]
                else
                    bt.blur_views[li + 1];
                const bg = gctx.createBindGroup(self.bloom_upsample_bgl, &.{
                    .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(bloom.UpsampleUniforms) },
                    .{ .binding = 1, .sampler_handle = self.sampler },
                    .{ .binding = 2, .texture_view_handle = bt.views[li] },
                    .{ .binding = 3, .texture_view_handle = coarse_view },
                });
                defer gctx.releaseResource(bg);
                if (gctx.lookupResource(self.bloom_upsample_pipeline)) |pipeline| {
                    if (gctx.lookupResource(bg)) |bind_group| {
                        if (gctx.lookupResource(bt.blur_views[li])) |dst| {
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
                            const mem = gctx.uniformsAllocate(bloom.UpsampleUniforms, 1);
                            mem.slice[0] = .{ .params = .{ 1.0, 0.35, 0.55, @floatFromInt(li) } };
                            pass.setBindGroup(0, bind_group, &.{mem.offset});
                            pass.draw(3, 1, 0, 0);
                        }
                    }
                }
            }
        }
    }

    fn passExposure(self: *Renderer) void {
        const encoder = self.frame.encoder orelse return;
        const gctx = self.gctx;
        const dt = self.frame.dt;

        lum_reduce: {
            const pipeline = gctx.lookupResource(self.lum_reduce_pipeline) orelse break :lum_reduce;
            const bind_group = gctx.lookupResource(self.lum_reduce_bg) orelse break :lum_reduce;
            const dst = gctx.lookupResource(self.exposure_chain.lum_mid_view) orelse break :lum_reduce;
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
            pass.setBindGroup(0, bind_group, &.{});
            pass.draw(3, 1, 0, 0);
        }

        lum_hist: {
            const pipeline = gctx.lookupResource(self.lum_hist_pipeline) orelse break :lum_hist;
            const bind_group = gctx.lookupResource(self.lum_hist_bg) orelse break :lum_hist;
            const dst = gctx.lookupResource(self.exposure_chain.hist_view) orelse break :lum_hist;
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
            const mem = gctx.uniformsAllocate(exposure.HistUniforms, 1);
            mem.slice[0] = .{ .params = .{ -12.0, 15.0, 0, 0 } };
            pass.setBindGroup(0, bind_group, &.{mem.offset});
            pass.draw(3, 1, 0, 0);
        }

        lum_avg: {
            const pipeline = gctx.lookupResource(self.lum_avg_pipeline) orelse break :lum_avg;
            const bind_group = gctx.lookupResource(self.lum_avg_bg) orelse break :lum_avg;
            const dst = gctx.lookupResource(self.exposure_chain.lum_1x1_view) orelse break :lum_avg;
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
            pass.setBindGroup(0, bind_group, &.{});
            pass.draw(3, 1, 0, 0);
        }

        exposure_adapt: {
            const pipeline = gctx.lookupResource(self.exposure_adapt_pipeline) orelse break :exposure_adapt;
            const bind_group_handle = if (self.exposure_chain.flip)
                self.exposure_adapt_bg_b
            else
                self.exposure_adapt_bg_a;
            const bind_group = gctx.lookupResource(bind_group_handle) orelse break :exposure_adapt;
            const dst_handle = self.exposure_chain.currExpView();
            const dst = gctx.lookupResource(dst_handle) orelse break :exposure_adapt;
            const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                .view = dst,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 1, .g = 0, .b = 0, .a = 1 },
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
            const adapt_up = 1.0 - std.math.exp(-dt * 1.0);
            const mem = gctx.uniformsAllocate(exposure.AdaptUniforms, 1);
            mem.slice[0] = .{ .params = .{ 0.18, adapt_up, 0.25, 5.0 } };
            pass.setBindGroup(0, bind_group, &.{mem.offset});
            pass.draw(3, 1, 0, 0);
        }
    }

    fn passTonemap(self: *Renderer) void {
        const encoder = self.frame.encoder orelse return;
        const gctx = self.gctx;
        const back_buffer_view = self.frame.back_buffer orelse return;
        const pipeline = gctx.lookupResource(self.tonemap_pipeline) orelse return;
        const bind_group_handle = if (self.exposure_chain.flip)
            self.tonemap_bg_a
        else
            self.tonemap_bg_b;
        const bind_group = gctx.lookupResource(bind_group_handle) orelse return;

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
        pass.setPipeline(pipeline);
        const mem = gctx.uniformsAllocate(bloom.TonemapUniforms, 1);
        if (mem.slice.len >= 1) {
            mem.slice[0] = .{ .params = .{ self.bloom_strength, 0, 0, 0 } };
            pass.setBindGroup(0, bind_group, &.{mem.offset});
            pass.draw(3, 1, 0, 0);
        }
        pass.end();
        pass.release();

        self.exposure_chain.advance();
        self.frame_index +%= 1;
    }

    fn passUi(self: *Renderer) void {
        if (!self.frame.draw_ui) return;
        const encoder = self.frame.encoder orelse return;
        const back_buffer_view = self.frame.back_buffer orelse return;
        const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
            .view = back_buffer_view,
            .load_op = .load,
            .store_op = .store,
        }};
        const pass = encoder.beginRenderPass(.{
            .color_attachment_count = color_attachments.len,
            .color_attachments = &color_attachments,
        });
        zgui.backend.draw(pass);
        pass.end();
        pass.release();
    }
};

fn graphPassShadowCsm(ctx: *anyopaque) void {
    asRenderer(ctx).passShadowCsm();
}
fn graphPassShadowPoint(ctx: *anyopaque) void {
    asRenderer(ctx).passShadowPoint();
}
fn graphPassShadowSpot(ctx: *anyopaque) void {
    asRenderer(ctx).passShadowSpot();
}
fn graphPassGBuffer(ctx: *anyopaque) void {
    asRenderer(ctx).passGBuffer();
}
fn graphPassLighting(ctx: *anyopaque) void {
    asRenderer(ctx).passLighting();
}
fn graphPassBloom(ctx: *anyopaque) void {
    asRenderer(ctx).passBloom();
}
fn graphPassExposure(ctx: *anyopaque) void {
    asRenderer(ctx).passExposure();
}
fn graphPassTonemap(ctx: *anyopaque) void {
    asRenderer(ctx).passTonemap();
}
fn graphPassUi(ctx: *anyopaque) void {
    asRenderer(ctx).passUi();
}

const deferred_frame_nodes = [_]render_graph.Node{
    .{
        .id = .shadow_csm,
        .writes = &.{.shadow_cascades},
        .execute = graphPassShadowCsm,
    },
    .{
        .id = .shadow_point,
        .writes = &.{.point_shadow_cube},
        .execute = graphPassShadowPoint,
    },
    .{
        .id = .shadow_spot,
        .writes = &.{.spot_shadow_maps},
        .execute = graphPassShadowSpot,
    },
    .{
        .id = .gbuffer,
        .writes = &.{ .gbuffer_albedo, .gbuffer_normal, .gbuffer_material, .gbuffer_depth },
        .execute = graphPassGBuffer,
    },
    .{
        .id = .lighting,
        .reads = &.{ .gbuffer_albedo, .gbuffer_normal, .gbuffer_material, .gbuffer_depth, .shadow_cascades, .point_shadow_cube, .spot_shadow_maps },
        .writes = &.{.hdr_color},
        .execute = graphPassLighting,
    },
    .{
        .id = .bloom,
        .reads = &.{.hdr_color},
        .writes = &.{ .bloom_a, .bloom_b },
        .execute = graphPassBloom,
    },
    .{
        .id = .exposure,
        .reads = &.{.hdr_color},
        .writes = &.{ .lum_mid, .lum_1x1, .exposure },
        .execute = graphPassExposure,
    },
    .{
        .id = .tonemap,
        .reads = &.{ .hdr_color, .bloom_a, .exposure },
        .writes = &.{.swapchain},
        .execute = graphPassTonemap,
    },
    .{
        .id = .ui,
        .reads = &.{.swapchain},
        .writes = &.{.swapchain},
        .execute = graphPassUi,
    },
};

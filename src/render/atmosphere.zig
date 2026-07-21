const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const shader = @import("shader.zig");
const log = @import("../core/log.zig");

pub const transmittance_w: u32 = 256;
pub const transmittance_h: u32 = 64;
pub const ms_size: u32 = 32;
pub const skyview_w: u32 = 192;
pub const skyview_h: u32 = 108;
pub const cloud_w: u32 = 480;
pub const cloud_h: u32 = 270;
pub const shadow_map_size: u32 = 256;
pub const rain_map_size: u32 = 256;
pub const panorama_w: u32 = 512;
pub const panorama_h: u32 = 256;

/// Runtime atmosphere / weather (Dagor daSkies2 role on WebGPU).
pub const Params = struct {
    time_of_day: f32 = 14.0,
    day_of_year: f32 = 180.0,
    latitude_deg: f32 = -23.5,
    longitude_deg: f32 = -46.6,
    /// Cumulus coverage [0,1].
    cloud_coverage: f32 = 0.35,
    /// Strata / cirrus veil [0,1].
    strata_coverage: f32 = 0.25,
    fog_density: f32 = 0.05,
    rain: f32 = 0.0,
    snow: f32 = 0.0,
    /// Wind direction XZ (normalized at pack time) + speed (km/s scale).
    wind_dir: [2]f32 = .{ 1.0, 0.35 },
    wind_speed: f32 = 0.8,
    cloud_shadow_strength: f32 = 1.0,
    taa_alpha: f32 = 0.12,
    panorama_enabled: bool = true,
    world_to_km: f32 = 0.001,
    enabled: bool = true,
};

pub const GpuUniforms = extern struct {
    sun_dir: [4]f32,
    moon_dir: [4]f32,
    cam_pos: [4]f32,
    weather: [4]f32,
    time_params: [4]f32,
    clouds: [4]f32,
    cloud_ext: [4]f32,
};

/// CPU-side scattering / weather queries (Dagor daScatteringCPU role).
pub const ScatteringQuery = struct {
    transmittance_sun: [3]f32 = .{ 1, 1, 1 },
    sky_radiance: [3]f32 = .{ 0, 0, 0 },
    fog: f32 = 0,
    rain: f32 = 0,
    cloud_shadow: f32 = 0,
};

pub const System = struct {
    transmittance: zgpu.TextureHandle = .{},
    transmittance_view: zgpu.TextureViewHandle = .{},
    multiscatter: zgpu.TextureHandle = .{},
    multiscatter_view: zgpu.TextureViewHandle = .{},
    skyview: zgpu.TextureHandle = .{},
    skyview_view: zgpu.TextureViewHandle = .{},

    cloud_trace: zgpu.TextureHandle = .{},
    cloud_trace_view: zgpu.TextureViewHandle = .{},
    cloud_taa_a: zgpu.TextureHandle = .{},
    cloud_taa_a_view: zgpu.TextureViewHandle = .{},
    cloud_taa_b: zgpu.TextureHandle = .{},
    cloud_taa_b_view: zgpu.TextureViewHandle = .{},
    cloud_taa_flip: bool = false,

    cloud_shadow: zgpu.TextureHandle = .{},
    cloud_shadow_view: zgpu.TextureViewHandle = .{},
    rain_map: zgpu.TextureHandle = .{},
    rain_map_view: zgpu.TextureViewHandle = .{},
    panorama: zgpu.TextureHandle = .{},
    panorama_view: zgpu.TextureViewHandle = .{},

    dummy: zgpu.TextureHandle = .{},
    dummy_view: zgpu.TextureViewHandle = .{},
    sampler: zgpu.SamplerHandle = .{},

    lut_bgl: zgpu.BindGroupLayoutHandle = .{},
    clouds_bgl: zgpu.BindGroupLayoutHandle = .{},

    transmittance_pipeline: zgpu.RenderPipelineHandle = .{},
    multiscatter_pipeline: zgpu.RenderPipelineHandle = .{},
    skyview_pipeline: zgpu.RenderPipelineHandle = .{},
    cloud_trace_pipeline: zgpu.RenderPipelineHandle = .{},
    cloud_taa_pipeline: zgpu.RenderPipelineHandle = .{},
    cloud_shadow_pipeline: zgpu.RenderPipelineHandle = .{},
    rain_map_pipeline: zgpu.RenderPipelineHandle = .{},
    panorama_pipeline: zgpu.RenderPipelineHandle = .{},

    transmittance_bg: zgpu.BindGroupHandle = .{},
    multiscatter_bg: zgpu.BindGroupHandle = .{},
    skyview_bg: zgpu.BindGroupHandle = .{},
    cloud_trace_bg: zgpu.BindGroupHandle = .{},
    cloud_taa_bg_a: zgpu.BindGroupHandle = .{},
    cloud_taa_bg_b: zgpu.BindGroupHandle = .{},
    cloud_shadow_bg: zgpu.BindGroupHandle = .{},
    rain_map_bg: zgpu.BindGroupHandle = .{},
    panorama_bg: zgpu.BindGroupHandle = .{},

    params: Params = .{},
    sun_dir: [3]f32 = .{ 0.35, 0.75, -0.45 },
    moon_dir: [3]f32 = .{ -0.4, 0.5, 0.3 },
    sun_illuminance: f32 = 1.0,
    moon_illuminance: f32 = 0.0,
    moon_phase: f32 = 0.5,
    star_intensity: f32 = 0.0,
    sun_color: [3]f32 = .{ 1.0, 0.96, 0.90 },
    ambient_sky: [3]f32 = .{ 0.02, 0.04, 0.08 },
    wind_time: f32 = 0,
    jitter: f32 = 0,
    cam_xz_km: [2]f32 = .{ 0, 0 },

    transmittance_dirty: bool = true,
    panorama_dirty: bool = true,
    last_sun_dir: [3]f32 = .{ 0, 0, 0 },
    last_tod: f32 = -1.0,

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

        self.transmittance = makeTex(gctx, transmittance_w, transmittance_h);
        self.transmittance_view = gctx.createTextureView(self.transmittance, .{});
        self.multiscatter = makeTex(gctx, ms_size, ms_size);
        self.multiscatter_view = gctx.createTextureView(self.multiscatter, .{});
        self.skyview = makeTex(gctx, skyview_w, skyview_h);
        self.skyview_view = gctx.createTextureView(self.skyview, .{});

        self.cloud_trace = makeTex(gctx, cloud_w, cloud_h);
        self.cloud_trace_view = gctx.createTextureView(self.cloud_trace, .{});
        self.cloud_taa_a = makeTex(gctx, cloud_w, cloud_h);
        self.cloud_taa_a_view = gctx.createTextureView(self.cloud_taa_a, .{});
        self.cloud_taa_b = makeTex(gctx, cloud_w, cloud_h);
        self.cloud_taa_b_view = gctx.createTextureView(self.cloud_taa_b, .{});

        self.cloud_shadow = makeTex(gctx, shadow_map_size, shadow_map_size);
        self.cloud_shadow_view = gctx.createTextureView(self.cloud_shadow, .{});
        self.rain_map = makeTex(gctx, rain_map_size, rain_map_size);
        self.rain_map_view = gctx.createTextureView(self.rain_map, .{});
        self.panorama = makeTex(gctx, panorama_w, panorama_h);
        self.panorama_view = gctx.createTextureView(self.panorama, .{});

        self.dummy = gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .dimension = .tdim_2d,
            .size = .{ .width = 1, .height = 1, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        self.dummy_view = gctx.createTextureView(self.dummy, .{});

        self.lut_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(3, .{ .fragment = true }, .float, .tvdim_2d, false),
        });
        self.clouds_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(3, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(4, .{ .fragment = true }, .float, .tvdim_2d, false),
        });

        const lut_pl = gctx.createPipelineLayout(&.{self.lut_bgl});
        defer gctx.releaseResource(lut_pl);
        const clouds_pl = gctx.createPipelineLayout(&.{self.clouds_bgl});
        defer gctx.releaseResource(clouds_pl);

        const atm_mod = try cache.getOrLoad("assets/shaders/atmosphere.wgsl");
        defer atm_mod.release();
        const clouds_mod = try cache.getOrLoad("assets/shaders/clouds_ext.wgsl");
        defer clouds_mod.release();

        const targets = [_]wgpu.ColorTargetState{.{ .format = .rgba16_float }};
        const prim = wgpu.PrimitiveState{
            .front_face = .ccw,
            .cull_mode = .none,
            .topology = .triangle_list,
        };

        self.transmittance_pipeline = makePipe(gctx, lut_pl, atm_mod, "fs_transmittance", &targets, prim);
        self.multiscatter_pipeline = makePipe(gctx, lut_pl, atm_mod, "fs_multiscatter", &targets, prim);
        self.skyview_pipeline = makePipe(gctx, lut_pl, atm_mod, "fs_skyview", &targets, prim);

        self.cloud_trace_pipeline = makePipe(gctx, clouds_pl, clouds_mod, "fs_cloud_trace", &targets, prim);
        self.cloud_taa_pipeline = makePipe(gctx, clouds_pl, clouds_mod, "fs_cloud_taa", &targets, prim);
        self.cloud_shadow_pipeline = makePipe(gctx, clouds_pl, clouds_mod, "fs_cloud_shadow", &targets, prim);
        self.rain_map_pipeline = makePipe(gctx, clouds_pl, clouds_mod, "fs_rain_map", &targets, prim);
        self.panorama_pipeline = makePipe(gctx, clouds_pl, clouds_mod, "fs_panorama", &targets, prim);

        self.rebuildBindGroups(gctx);
        self.updateAstronomy();
        log.info(.render, "atmosphere+clouds: LUT {d}x{d} sky {d}x{d} cloudTAA {d}x{d} shadow/rain {d} pano {d}x{d}", .{
            transmittance_w, transmittance_h, skyview_w, skyview_h, cloud_w, cloud_h, shadow_map_size, panorama_w, panorama_h,
        });
        return self;
    }

    fn makeTex(gctx: *zgpu.GraphicsContext, w: u32, h: u32) zgpu.TextureHandle {
        return gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
            .format = .rgba16_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
    }

    fn makePipe(
        gctx: *zgpu.GraphicsContext,
        pl: zgpu.PipelineLayoutHandle,
        module: wgpu.ShaderModule,
        entry: [*:0]const u8,
        targets: []const wgpu.ColorTargetState,
        prim: wgpu.PrimitiveState,
    ) zgpu.RenderPipelineHandle {
        return gctx.createRenderPipeline(pl, .{
            .vertex = .{ .module = module, .entry_point = "vs_main" },
            .primitive = prim,
            .fragment = &wgpu.FragmentState{
                .module = module,
                .entry_point = entry,
                .target_count = targets.len,
                .targets = targets.ptr,
            },
        });
    }

    pub fn destroy(self: *System, gctx: *zgpu.GraphicsContext) void {
        inline for (.{
            self.transmittance_bg,     self.multiscatter_bg, self.skyview_bg,
            self.cloud_trace_bg,       self.cloud_taa_bg_a,  self.cloud_taa_bg_b,
            self.cloud_shadow_bg,      self.rain_map_bg,     self.panorama_bg,
        }) |bg| {
            if (gctx.isResourceValid(bg)) gctx.releaseResource(bg);
        }
        inline for (.{
            self.transmittance_view, self.multiscatter_view, self.skyview_view,
            self.cloud_trace_view,   self.cloud_taa_a_view,  self.cloud_taa_b_view,
            self.cloud_shadow_view,  self.rain_map_view,     self.panorama_view,
            self.dummy_view,
        }) |v| {
            if (gctx.isResourceValid(v)) gctx.releaseResource(v);
        }
        inline for (.{
            self.transmittance, self.multiscatter, self.skyview,
            self.cloud_trace,   self.cloud_taa_a,  self.cloud_taa_b,
            self.cloud_shadow,  self.rain_map,     self.panorama,
            self.dummy,
        }) |t| {
            if (gctx.isResourceValid(t)) gctx.destroyResource(t);
        }
        if (gctx.isResourceValid(self.sampler)) gctx.releaseResource(self.sampler);
        self.* = .{};
    }

    pub fn cloudTaaView(self: *const System) zgpu.TextureViewHandle {
        return if (self.cloud_taa_flip) self.cloud_taa_a_view else self.cloud_taa_b_view;
    }

    pub fn rebuildBindGroups(self: *System, gctx: *zgpu.GraphicsContext) void {
        inline for (.{
            &self.transmittance_bg, &self.multiscatter_bg, &self.skyview_bg,
            &self.cloud_trace_bg,   &self.cloud_taa_bg_a,  &self.cloud_taa_bg_b,
            &self.cloud_shadow_bg,  &self.rain_map_bg,     &self.panorama_bg,
        }) |bg| {
            if (gctx.isResourceValid(bg.*)) gctx.releaseResource(bg.*);
            bg.* = .{};
        }

        self.transmittance_bg = gctx.createBindGroup(self.lut_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(GpuUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.dummy_view },
            .{ .binding = 3, .texture_view_handle = self.dummy_view },
        });
        self.multiscatter_bg = gctx.createBindGroup(self.lut_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(GpuUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.transmittance_view },
            .{ .binding = 3, .texture_view_handle = self.dummy_view },
        });
        self.skyview_bg = gctx.createBindGroup(self.lut_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(GpuUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.transmittance_view },
            .{ .binding = 3, .texture_view_handle = self.multiscatter_view },
        });

        self.cloud_trace_bg = gctx.createBindGroup(self.clouds_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(GpuUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.transmittance_view },
            .{ .binding = 3, .texture_view_handle = self.dummy_view },
            .{ .binding = 4, .texture_view_handle = self.dummy_view },
        });
        // TAA: history A + current trace → write B; history B + current → write A
        self.cloud_taa_bg_a = gctx.createBindGroup(self.clouds_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(GpuUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.transmittance_view },
            .{ .binding = 3, .texture_view_handle = self.cloud_taa_a_view },
            .{ .binding = 4, .texture_view_handle = self.cloud_trace_view },
        });
        self.cloud_taa_bg_b = gctx.createBindGroup(self.clouds_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(GpuUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.transmittance_view },
            .{ .binding = 3, .texture_view_handle = self.cloud_taa_b_view },
            .{ .binding = 4, .texture_view_handle = self.cloud_trace_view },
        });
        self.cloud_shadow_bg = gctx.createBindGroup(self.clouds_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(GpuUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.transmittance_view },
            .{ .binding = 3, .texture_view_handle = self.dummy_view },
            .{ .binding = 4, .texture_view_handle = self.dummy_view },
        });
        self.rain_map_bg = gctx.createBindGroup(self.clouds_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(GpuUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.transmittance_view },
            .{ .binding = 3, .texture_view_handle = self.dummy_view },
            .{ .binding = 4, .texture_view_handle = self.dummy_view },
        });
        self.panorama_bg = gctx.createBindGroup(self.clouds_bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(GpuUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.transmittance_view },
            .{ .binding = 3, .texture_view_handle = self.cloud_taa_a_view },
            .{ .binding = 4, .texture_view_handle = self.skyview_view },
        });
    }

    pub fn setTimeOfDay(self: *System, hours: f32) void {
        self.params.time_of_day = @mod(hours, 24.0);
        self.updateAstronomy();
        self.panorama_dirty = true;
    }

    pub fn advanceTime(self: *System, dt_hours: f32) void {
        self.setTimeOfDay(self.params.time_of_day + dt_hours);
    }

    pub fn advanceWind(self: *System, dt: f32) void {
        self.wind_time += dt;
        self.jitter = @mod(self.jitter + 0.618033988, 1.0);
    }

    pub fn updateAstronomy(self: *System) void {
        const lat = std.math.degreesToRadians(self.params.latitude_deg);
        const decl = 0.4093 * @sin(2.0 * std.math.pi * (self.params.day_of_year - 81.0) / 365.0);
        const hour_angle = (self.params.time_of_day - 12.0) * (std.math.pi / 12.0);

        const sin_alt = @sin(lat) * @sin(decl) + @cos(lat) * @cos(decl) * @cos(hour_angle);
        const alt = std.math.asin(std.math.clamp(sin_alt, -1.0, 1.0));
        const cos_az_num = @sin(decl) - @sin(lat) * sin_alt;
        const cos_az_den = @cos(lat) * @cos(alt);
        var az: f32 = 0;
        if (@abs(cos_az_den) > 1e-5) {
            az = std.math.acos(std.math.clamp(cos_az_num / cos_az_den, -1.0, 1.0));
            if (hour_angle > 0) az = -az;
        }
        const cos_a = @cos(alt);
        self.sun_dir = .{ @sin(az) * cos_a, @sin(alt), @cos(az) * cos_a };
        normalize3(&self.sun_dir);

        const moon_phase = @mod(self.params.day_of_year + self.params.time_of_day / 24.0, 29.53) / 29.53;
        self.moon_phase = moon_phase;
        const moon_ha = hour_angle + std.math.pi * (0.5 + moon_phase);
        const moon_decl = decl * 0.7;
        const sin_m = @sin(lat) * @sin(moon_decl) + @cos(lat) * @cos(moon_decl) * @cos(moon_ha);
        const malt = std.math.asin(std.math.clamp(sin_m, -1.0, 1.0));
        const mcos = @cos(malt);
        self.moon_dir = .{ @sin(moon_ha) * mcos, @sin(malt), @cos(moon_ha) * mcos };
        normalize3(&self.moon_dir);

        const sun_up = std.math.clamp((self.sun_dir[1] + 0.05) / 0.25, 0.0, 1.0);
        const moon_up = std.math.clamp((self.moon_dir[1] + 0.02) / 0.2, 0.0, 1.0);
        self.sun_illuminance = sun_up * sun_up;
        self.moon_illuminance = (1.0 - sun_up) * moon_up * 0.08;
        self.star_intensity = std.math.clamp(1.0 - sun_up * 3.0, 0.0, 1.0) * 1.5;

        const sunset = std.math.clamp(1.0 - @abs(self.sun_dir[1]) * 4.0, 0.0, 1.0) * sun_up;
        self.sun_color = .{ 1.0, 0.96 - sunset * 0.25, 0.90 - sunset * 0.55 };
        self.ambient_sky = .{
            0.01 + 0.04 * sun_up,
            0.02 + 0.06 * sun_up,
            0.04 + 0.10 * sun_up,
        };
    }

    fn normalize3(v: *[3]f32) void {
        const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
        if (len > 1e-6) {
            v[0] /= len;
            v[1] /= len;
            v[2] /= len;
        }
    }

    fn packUniforms(self: *const System, cam_y_world: f32) GpuUniforms {
        const cam_km = @max(cam_y_world * self.params.world_to_km, 0.001);
        var wdx = self.params.wind_dir[0];
        var wdz = self.params.wind_dir[1];
        const wlen = @sqrt(wdx * wdx + wdz * wdz);
        if (wlen > 1e-5) {
            wdx /= wlen;
            wdz /= wlen;
        }
        return .{
            .sun_dir = .{ self.sun_dir[0], self.sun_dir[1], self.sun_dir[2], self.sun_illuminance },
            .moon_dir = .{ self.moon_dir[0], self.moon_dir[1], self.moon_dir[2], self.moon_illuminance },
            .cam_pos = .{ self.cam_xz_km[0], cam_km, self.cam_xz_km[1], self.wind_time },
            .weather = .{
                self.params.cloud_coverage,
                self.params.fog_density + self.params.rain * 0.4 + self.params.snow * 0.3,
                self.params.rain,
                self.params.snow,
            },
            .time_params = .{
                self.params.time_of_day,
                self.star_intensity,
                self.moon_phase,
                if (self.params.enabled) 1.0 else 0.0,
            },
            .clouds = .{ self.params.strata_coverage, wdx, wdz, self.params.wind_speed },
            .cloud_ext = .{
                self.params.cloud_shadow_strength,
                self.params.taa_alpha,
                if (self.params.panorama_enabled) 1.0 else 0.0,
                self.jitter,
            },
        };
    }

    fn drawFullscreen(
        gctx: *zgpu.GraphicsContext,
        encoder: wgpu.CommandEncoder,
        pipeline_h: zgpu.RenderPipelineHandle,
        bg_h: zgpu.BindGroupHandle,
        view_h: zgpu.TextureViewHandle,
        uniforms: GpuUniforms,
    ) void {
        const pipeline = gctx.lookupResource(pipeline_h) orelse return;
        const bind_group = gctx.lookupResource(bg_h) orelse return;
        const view = gctx.lookupResource(view_h) orelse return;
        const color = [_]wgpu.RenderPassColorAttachment{.{
            .view = view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
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
        const mem = gctx.uniformsAllocate(GpuUniforms, 1);
        mem.slice[0] = uniforms;
        pass.setBindGroup(0, bind_group, &.{mem.offset});
        pass.draw(3, 1, 0, 0);
    }

    pub fn prepare(
        self: *System,
        gctx: *zgpu.GraphicsContext,
        encoder: wgpu.CommandEncoder,
        cam_pos_world: [3]f32,
        dt: f32,
    ) void {
        if (!self.params.enabled) return;
        self.advanceWind(dt);
        self.cam_xz_km = .{
            cam_pos_world[0] * self.params.world_to_km,
            cam_pos_world[2] * self.params.world_to_km,
        };
        const u = self.packUniforms(cam_pos_world[1]);

        if (self.transmittance_dirty) {
            drawFullscreen(gctx, encoder, self.transmittance_pipeline, self.transmittance_bg, self.transmittance_view, u);
            drawFullscreen(gctx, encoder, self.multiscatter_pipeline, self.multiscatter_bg, self.multiscatter_view, u);
            self.transmittance_dirty = false;
        }

        drawFullscreen(gctx, encoder, self.skyview_pipeline, self.skyview_bg, self.skyview_view, u);

        // Cloud tracing → TAA
        drawFullscreen(gctx, encoder, self.cloud_trace_pipeline, self.cloud_trace_bg, self.cloud_trace_view, u);
        if (self.cloud_taa_flip) {
            // history B + cur → A
            drawFullscreen(gctx, encoder, self.cloud_taa_pipeline, self.cloud_taa_bg_b, self.cloud_taa_a_view, u);
        } else {
            drawFullscreen(gctx, encoder, self.cloud_taa_pipeline, self.cloud_taa_bg_a, self.cloud_taa_b_view, u);
        }
        self.cloud_taa_flip = !self.cloud_taa_flip;

        drawFullscreen(gctx, encoder, self.cloud_shadow_pipeline, self.cloud_shadow_bg, self.cloud_shadow_view, u);
        drawFullscreen(gctx, encoder, self.rain_map_pipeline, self.rain_map_bg, self.rain_map_view, u);

        const sun_moved =
            @abs(self.sun_dir[0] - self.last_sun_dir[0]) > 0.01 or
            @abs(self.sun_dir[1] - self.last_sun_dir[1]) > 0.01 or
            @abs(self.params.time_of_day - self.last_tod) > 0.05;
        if (self.params.panorama_enabled and (self.panorama_dirty or sun_moved)) {
            // Rebind panorama with current TAA target as history slot.
            if (gctx.isResourceValid(self.panorama_bg)) gctx.releaseResource(self.panorama_bg);
            self.panorama_bg = gctx.createBindGroup(self.clouds_bgl, &.{
                .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(GpuUniforms) },
                .{ .binding = 1, .sampler_handle = self.sampler },
                .{ .binding = 2, .texture_view_handle = self.transmittance_view },
                .{ .binding = 3, .texture_view_handle = self.cloudTaaView() },
                .{ .binding = 4, .texture_view_handle = self.skyview_view },
            });
            drawFullscreen(gctx, encoder, self.panorama_pipeline, self.panorama_bg, self.panorama_view, u);
            self.panorama_dirty = false;
        }

        self.last_sun_dir = self.sun_dir;
        self.last_tod = self.params.time_of_day;
    }

    pub fn directionalIntensity(self: *const System) f32 {
        return 2.5 * self.sun_illuminance + 0.35 * self.moon_illuminance;
    }

    pub fn dominantLightDir(self: *const System) [3]f32 {
        if (self.sun_illuminance >= self.moon_illuminance * 0.5) return self.sun_dir;
        return self.moon_dir;
    }

    // --- CPU scattering queries (analytic; no GPU readback) -----------------

    /// Optical transmittance toward the sun from altitude (km AGL).
    pub fn queryTransmittanceToSun(self: *const System, alt_km: f32) [3]f32 {
        const mu = std.math.clamp(self.sun_dir[1], -1.0, 1.0);
        // Beer–Lambert approx with Rayleigh+Mie scale heights.
        const h = @max(alt_km, 0.0);
        const od_r = 0.008 * @exp(-h / 8.0) / @max(mu + 0.15, 0.05);
        const od_m = 0.004 * @exp(-h / 1.2) / @max(mu + 0.15, 0.05);
        const od_o = 0.0015 * @exp(-@abs(h - 25.0) / 15.0);
        const illum = @max(self.sun_illuminance, 0.02);
        return .{
            @exp(-(od_r * 0.5 + od_m + od_o)) * illum,
            @exp(-(od_r * 1.0 + od_m + od_o * 1.5)) * illum,
            @exp(-(od_r * 2.2 + od_m + od_o * 0.3)) * illum,
        };
    }

    /// Cheap sky radiance along a view direction (gradient + sun glow).
    pub fn querySkyRadiance(self: *const System, dir: [3]f32) [3]f32 {
        var d = dir;
        normalize3(&d);
        const elev = std.math.clamp(d[1], -1.0, 1.0);
        const zenith = [_]f32{ 0.08, 0.22, 0.72 };
        const horizon = [_]f32{ 0.72, 0.78, 0.92 };
        const t = std.math.clamp(elev, 0, 1);
        var rgb: [3]f32 = .{
            horizon[0] + (zenith[0] - horizon[0]) * t,
            horizon[1] + (zenith[1] - horizon[1]) * t,
            horizon[2] + (zenith[2] - horizon[2]) * t,
        };
        const sun_dot = std.math.clamp(d[0] * self.sun_dir[0] + d[1] * self.sun_dir[1] + d[2] * self.sun_dir[2], 0, 1);
        const sun = std.math.pow(f32, sun_dot, 64.0) * 4.0 * self.sun_illuminance;
        rgb[0] += sun * self.sun_color[0];
        rgb[1] += sun * self.sun_color[1];
        rgb[2] += sun * self.sun_color[2];
        const night = self.star_intensity * 0.05;
        rgb[0] = rgb[0] * self.sun_illuminance + night;
        rgb[1] = rgb[1] * self.sun_illuminance + night;
        rgb[2] = rgb[2] * self.sun_illuminance + night * 1.2;
        return rgb;
    }

    pub fn queryFog(self: *const System, distance_m: f32) f32 {
        const fog = self.params.fog_density + self.params.rain * 0.4;
        return 1.0 - @exp(-fog * 0.00035 * distance_m);
    }

    /// Procedural rain intensity at world XZ (matches rain_map shader).
    pub fn queryRainAt(self: *const System, world_x: f32, world_z: f32) f32 {
        const xz_x = world_x * self.params.world_to_km;
        const xz_z = world_z * self.params.world_to_km;
        const n = hashNoise2(xz_x * 0.12 + self.wind_time * 0.1, xz_z * 0.12);
        const under = std.math.clamp(n - (1.0 - self.params.cloud_coverage * 0.9), 0, 1);
        return std.math.clamp(self.params.rain * (0.35 + under * 1.2), 0, 1);
    }

    /// Soft cloud shadow factor [0=dark, 1=full sun] at world XZ.
    pub fn queryCloudShadowAt(self: *const System, world_x: f32, world_z: f32) f32 {
        const xz_x = world_x * self.params.world_to_km;
        const xz_z = world_z * self.params.world_to_km;
        const n = hashNoise2(xz_x * 0.07 + self.wind_time * self.params.wind_speed * 0.05, xz_z * 0.07);
        const cumulus = std.math.clamp(n - (1.0 - self.params.cloud_coverage), 0, 1);
        const strata = std.math.clamp(hashNoise2(xz_x * 0.03, xz_z * 0.03) - (1.0 - self.params.strata_coverage), 0, 1) * 0.35;
        const od = (cumulus * 2.5 + strata) * self.params.cloud_shadow_strength;
        return @exp(-od);
    }

    pub fn queryAt(self: *const System, world_pos: [3]f32, view_dir: [3]f32) ScatteringQuery {
        const alt = world_pos[1] * self.params.world_to_km;
        return .{
            .transmittance_sun = self.queryTransmittanceToSun(alt),
            .sky_radiance = self.querySkyRadiance(view_dir),
            .fog = self.queryFog(@sqrt(world_pos[0] * world_pos[0] + world_pos[2] * world_pos[2])),
            .rain = self.queryRainAt(world_pos[0], world_pos[2]),
            .cloud_shadow = self.queryCloudShadowAt(world_pos[0], world_pos[2]),
        };
    }
};

fn hashNoise2(x: f32, z: f32) f32 {
    const ix = @floor(x);
    const iz = @floor(z);
    const fx = x - ix;
    const fz = z - iz;
    const u = fx * fx * (3 - 2 * fx);
    const v = fz * fz * (3 - 2 * fz);
    const a = fract(std.math.sin(ix * 127.1 + iz * 311.7) * 43758.5453);
    const b = fract(std.math.sin((ix + 1) * 127.1 + iz * 311.7) * 43758.5453);
    const c = fract(std.math.sin(ix * 127.1 + (iz + 1) * 311.7) * 43758.5453);
    const d = fract(std.math.sin((ix + 1) * 127.1 + (iz + 1) * 311.7) * 43758.5453);
    return a * (1 - u) * (1 - v) + b * u * (1 - v) + c * (1 - u) * v + d * u * v;
}

fn fract(x: f32) f32 {
    return x - @floor(x);
}

test "astronomy noon elevates sun" {
    var s: System = .{};
    s.params.time_of_day = 12.0;
    s.params.latitude_deg = 0;
    s.params.day_of_year = 80;
    s.updateAstronomy();
    try std.testing.expect(s.sun_dir[1] > 0.5);
    s.params.time_of_day = 0.0;
    s.updateAstronomy();
    try std.testing.expect(s.sun_illuminance < 0.15);
}

test "cpu scattering queries range" {
    var s: System = .{};
    s.updateAstronomy();
    const t = s.queryTransmittanceToSun(0.1);
    try std.testing.expect(t[0] > 0 and t[0] <= 1.5);
    const rain = s.queryRainAt(10, 20);
    try std.testing.expect(rain >= 0 and rain <= 1);
    const sh = s.queryCloudShadowAt(0, 0);
    try std.testing.expect(sh > 0 and sh <= 1);
}

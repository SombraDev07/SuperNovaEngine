const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zm = @import("zmath");
const mesh = @import("mesh.zig");
const gbuffer = @import("gbuffer.zig");
const shader = @import("shader.zig");
const world = @import("../world/root.zig");

const frustum_mod = @import("frustum.zig");
const terrain_mesh = @import("../world/terrain_mesh.zig");

const ChunkCoord = world.ChunkCoord;
const Streamer = world.Streamer;
const SplatMap = world.SplatMap;
const TerrainTile = world.TerrainTile;

pub const max_gpu_chunks: u32 = 64;

const TerrainFrameUniforms = extern struct {
    world_to_clip: zm.Mat,
    decode_origin: [4]f32,
    decode_scale: [4]f32,
};

const LayerGpu = struct {
    mesh: mesh.Mesh = .{ .vertex_buffer = .{}, .index_buffer = .{}, .index_count = 0 },
    decode: mesh.TerrainDecode = .{},
    active: bool = false,
};

const GpuChunk = struct {
    coord: ChunkCoord = .{},
    /// land / decal / combined / patches (Dagor CellData).
    layers: [4]LayerGpu = .{ .{}, .{}, .{}, .{} },
    splat_tex: zgpu.TextureHandle = .{},
    splat_view: zgpu.TextureViewHandle = .{},
    hole_tex: zgpu.TextureHandle = .{},
    hole_view: zgpu.TextureViewHandle = .{},
    bind_group: zgpu.BindGroupHandle = .{},
    aabb_min: [3]f32 = .{ 0, 0, 0 },
    aabb_max: [3]f32 = .{ 0, 0, 0 },
    decode: mesh.TerrainDecode = .{},
    generation: u32 = 0,
    valid: bool = false,
};

/// GPU terrain splat: 4 detail albedos + per-chunk weight mask (Dagor LandClass/DetailMap).
pub const TerrainSplat = struct {
    allocator: std.mem.Allocator,
    pipeline: zgpu.RenderPipelineHandle = .{},
    bgl: zgpu.BindGroupLayoutHandle = .{},
    sampler: zgpu.SamplerHandle = .{},
    layer_tex: [4]zgpu.TextureHandle = .{ .{}, .{}, .{}, .{} },
    layer_view: [4]zgpu.TextureViewHandle = .{ .{}, .{}, .{}, .{} },
    chunks: [max_gpu_chunks]GpuChunk = [_]GpuChunk{.{}} ** max_gpu_chunks,
    chunk_count: u32 = 0,

    pub fn create(gctx: *zgpu.GraphicsContext, allocator: std.mem.Allocator) !TerrainSplat {
        var self: TerrainSplat = .{
            .allocator = allocator,
            .sampler = gctx.createSampler(.{
                .mag_filter = .linear,
                .min_filter = .linear,
                .mipmap_filter = .linear,
                .address_mode_u = .repeat,
                .address_mode_v = .repeat,
                .address_mode_w = .repeat,
            }),
        };

        // Detail layer albedos (procedural 64²) — grass, rock, sand, dirt.
        self.layer_tex[0] = createDetailTex(gctx, .{ 72, 118, 48 }, .{ 40, 70, 28 }, 0);
        self.layer_tex[1] = createDetailTex(gctx, .{ 110, 105, 98 }, .{ 70, 68, 64 }, 1);
        self.layer_tex[2] = createDetailTex(gctx, .{ 194, 170, 120 }, .{ 160, 140, 90 }, 2);
        self.layer_tex[3] = createDetailTex(gctx, .{ 92, 64, 42 }, .{ 60, 42, 28 }, 3);
        for (0..4) |i| {
            self.layer_view[i] = gctx.createTextureView(self.layer_tex[i], .{});
        }

        self.bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            zgpu.textureEntry(2, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(3, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(4, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(5, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(6, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.textureEntry(7, .{ .fragment = true }, .float, .tvdim_2d, false),
        });

        try self.createPipeline(gctx);
        return self;
    }

    fn createPipeline(self: *TerrainSplat, gctx: *zgpu.GraphicsContext) !void {
        const pl = gctx.createPipelineLayout(&.{self.bgl});
        defer gctx.releaseResource(pl);

        const wgsl = try shader.loadFile(self.allocator, "assets/shaders/terrain_gbuffer.wgsl");
        defer self.allocator.free(wgsl);
        const module = shader.createModule(gctx.device, wgsl, "terrain_gbuffer");
        defer module.release();

        const targets = [_]wgpu.ColorTargetState{
            .{ .format = .rgba8_unorm_srgb },
            .{ .format = .rgba8_unorm },
            .{ .format = .rgba8_unorm },
            .{ .format = .rgba8_unorm_srgb },
        };
        const vbufs = [_]wgpu.VertexBufferLayout{.{
            .array_stride = @sizeOf(mesh.TerrainPackedVertex),
            .attribute_count = mesh.TerrainPackedVertex.attributes.len,
            .attributes = &mesh.TerrainPackedVertex.attributes,
        }};

        self.pipeline = gctx.createRenderPipeline(pl, .{
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

    pub fn destroy(self: *TerrainSplat, gctx: *zgpu.GraphicsContext) void {
        self.clearChunks(gctx);
        for (0..4) |i| {
            if (gctx.isResourceValid(self.layer_view[i])) gctx.releaseResource(self.layer_view[i]);
            if (gctx.isResourceValid(self.layer_tex[i])) gctx.destroyResource(self.layer_tex[i]);
        }
        if (gctx.isResourceValid(self.sampler)) gctx.releaseResource(self.sampler);
        if (gctx.isResourceValid(self.pipeline)) gctx.releaseResource(self.pipeline);
        if (gctx.isResourceValid(self.bgl)) gctx.releaseResource(self.bgl);
        self.* = undefined;
    }

    pub fn clearChunks(self: *TerrainSplat, gctx: *zgpu.GraphicsContext) void {
        for (self.chunks[0..self.chunk_count]) |*c| {
            destroyChunk(gctx, c);
        }
        self.chunk_count = 0;
    }

    /// Upload/update GPU meshes + splat masks for ready streamer tiles.
    pub fn sync(self: *TerrainSplat, gctx: *zgpu.GraphicsContext, streamer: *const Streamer) !void {
        // Drop GPU chunks no longer resident.
        var i: u32 = 0;
        while (i < self.chunk_count) {
            const coord = self.chunks[i].coord;
            if (!streamer.isReady(coord)) {
                destroyChunk(gctx, &self.chunks[i]);
                self.chunks[i] = self.chunks[self.chunk_count - 1];
                self.chunk_count -= 1;
                continue;
            }
            i += 1;
        }

        var it = streamer.chunks.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state != .ready) continue;
            const tile_ptr = entry.value_ptr.front.terrain orelse continue;
            const tile: *TerrainTile = @ptrCast(@alignCast(tile_ptr));
            const coord = entry.key_ptr.*;

            if (self.findChunk(coord)) |idx| {
                if (self.chunks[idx].generation == tile.gpu_generation) continue;
                destroyChunk(gctx, &self.chunks[idx]);
                self.chunks[idx] = try self.uploadChunk(gctx, tile);
            } else {
                if (self.chunk_count >= max_gpu_chunks) break;
                self.chunks[self.chunk_count] = try self.uploadChunk(gctx, tile);
                self.chunk_count += 1;
            }
        }
    }

    fn findChunk(self: *TerrainSplat, coord: ChunkCoord) ?u32 {
        var i: u32 = 0;
        while (i < self.chunk_count) : (i += 1) {
            if (ChunkCoord.eql(self.chunks[i].coord, coord)) return i;
        }
        return null;
    }

    fn uploadChunk(self: *TerrainSplat, gctx: *zgpu.GraphicsContext, tile: *TerrainTile) !GpuChunk {
        var set = try tile.buildCombinedMeshes(self.allocator);
        defer set.deinit();

        var layers: [4]LayerGpu = .{ .{}, .{}, .{}, .{} };
        // 0=land, 1=decal, 2=combined (distant-only, not with land), 3=patches
        layers[0] = uploadLayer(gctx, &set.land);
        if (set.decal) |*d| {
            if (d.indices.len > 0) layers[1] = uploadLayer(gctx, d);
        }
        // Patches replace land while editing. Never upload combined alongside land —
        // drawing both with mismatched LOD produced the "shard field" look.
        if (set.patches) |*p| {
            layers[3] = uploadLayer(gctx, p);
            layers[0].active = false;
        }

        const splat_pixels = try packSplatRgba8(self.allocator, &tile.splat);
        defer self.allocator.free(splat_pixels);
        const n = tile.splat.resolution + 1;
        const splat_tex = uploadRgba8(gctx, splat_pixels, n, n, .rgba8_unorm);
        const splat_view = gctx.createTextureView(splat_tex, .{});

        const hole_pixels = try self.allocator.alloc([4]u8, n * n);
        defer self.allocator.free(hole_pixels);
        tile.holes.bakeGpuMask(&tile.heightfield, std.mem.sliceAsBytes(hole_pixels));
        const hole_tex = uploadRgba8(gctx, hole_pixels, n, n, .rgba8_unorm);
        const hole_view = gctx.createTextureView(hole_tex, .{});

        const bg = gctx.createBindGroup(self.bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(TerrainFrameUniforms) },
            .{ .binding = 1, .sampler_handle = self.sampler },
            .{ .binding = 2, .texture_view_handle = self.layer_view[0] },
            .{ .binding = 3, .texture_view_handle = self.layer_view[1] },
            .{ .binding = 4, .texture_view_handle = self.layer_view[2] },
            .{ .binding = 5, .texture_view_handle = self.layer_view[3] },
            .{ .binding = 6, .texture_view_handle = splat_view },
            .{ .binding = 7, .texture_view_handle = hole_view },
        });

        const bounds = terrain_mesh.patchBounds(&tile.heightfield);
        return .{
            .coord = tile.coord,
            .layers = layers,
            .splat_tex = splat_tex,
            .splat_view = splat_view,
            .hole_tex = hole_tex,
            .hole_view = hole_view,
            .bind_group = bg,
            .aabb_min = bounds.min,
            .aabb_max = bounds.max,
            .decode = set.land.decode,
            .generation = tile.gpu_generation,
            .valid = true,
        };
    }

    fn uploadLayer(gctx: *zgpu.GraphicsContext, built: *const terrain_mesh.BuiltMesh) LayerGpu {
        if (built.indices.len == 0) return .{};
        return .{
            .mesh = mesh.createGpuTerrainMesh(gctx, built.vertices, built.indices),
            .decode = built.decode,
            .active = true,
        };
    }

    pub fn draw(
        self: *TerrainSplat,
        gctx: *zgpu.GraphicsContext,
        pass: wgpu.RenderPassEncoder,
        world_to_clip: zm.Mat,
    ) void {
        const pipeline = gctx.lookupResource(self.pipeline) orelse return;
        pass.setPipeline(pipeline);

        const fr = frustum_mod.Frustum.fromViewProj(world_to_clip);
        for (self.chunks[0..self.chunk_count]) |c| {
            if (!c.valid) continue;
            if (!fr.containsAabb(c.aabb_min, c.aabb_max)) continue;
            const bg = gctx.lookupResource(c.bind_group) orelse continue;
            // patches > land > decal (never land+combined together)
            const draw_order = [_]u32{ 3, 0, 1 };
            for (draw_order) |li| {
                const layer = c.layers[li];
                if (!layer.active or layer.mesh.index_count == 0) continue;
                const vb = gctx.lookupResourceInfo(layer.mesh.vertex_buffer) orelse continue;
                const ib = gctx.lookupResourceInfo(layer.mesh.index_buffer) orelse continue;
                const mem = gctx.uniformsAllocate(TerrainFrameUniforms, 1);
                if (mem.slice.len < 1) continue;
                mem.slice[0] = .{
                    .world_to_clip = zm.transpose(world_to_clip),
                    .decode_origin = layer.decode.origin,
                    .decode_scale = layer.decode.scale,
                };
                pass.setBindGroup(0, bg, &.{mem.offset});
                pass.setVertexBuffer(0, vb.gpuobj.?, 0, vb.size);
                pass.setIndexBuffer(ib.gpuobj.?, .uint32, 0, ib.size);
                pass.drawIndexed(layer.mesh.index_count, 1, 0, 0, 0);
            }
        }
    }
};

fn destroyChunk(gctx: *zgpu.GraphicsContext, c: *GpuChunk) void {
    if (!c.valid) return;
    if (gctx.isResourceValid(c.bind_group)) gctx.releaseResource(c.bind_group);
    if (gctx.isResourceValid(c.splat_view)) gctx.releaseResource(c.splat_view);
    if (gctx.isResourceValid(c.splat_tex)) gctx.destroyResource(c.splat_tex);
    if (gctx.isResourceValid(c.hole_view)) gctx.releaseResource(c.hole_view);
    if (gctx.isResourceValid(c.hole_tex)) gctx.destroyResource(c.hole_tex);
    for (&c.layers) |*layer| {
        if (gctx.isResourceValid(layer.mesh.vertex_buffer)) gctx.destroyResource(layer.mesh.vertex_buffer);
        if (gctx.isResourceValid(layer.mesh.index_buffer)) gctx.destroyResource(layer.mesh.index_buffer);
    }
    c.* = .{};
}

pub fn packSplatRgba8(allocator: std.mem.Allocator, splat: *const SplatMap) ![][4]u8 {
    const out = try allocator.alloc([4]u8, splat.weights.len);
    for (splat.weights, 0..) |w, i| {
        var sum: f32 = 0;
        for (w) |v| sum += v;
        if (sum < 1e-6) sum = 1;
        out[i] = .{
            @intFromFloat(std.math.clamp(w[0] / sum, 0, 1) * 255.0),
            @intFromFloat(std.math.clamp(w[1] / sum, 0, 1) * 255.0),
            @intFromFloat(std.math.clamp(w[2] / sum, 0, 1) * 255.0),
            @intFromFloat(std.math.clamp(w[3] / sum, 0, 1) * 255.0),
        };
    }
    return out;
}

fn createDetailTex(gctx: *zgpu.GraphicsContext, base: [3]u8, alt: [3]u8, seed: u32) zgpu.TextureHandle {
    // 128² multi-octave noise (Dagor detail albedo role; normals derived in shader).
    const size: u32 = 128;
    var pixels: [128 * 128][4]u8 = undefined;
    var y: u32 = 0;
    while (y < size) : (y += 1) {
        var x: u32 = 0;
        while (x < size) : (x += 1) {
            const h0 = hash2(x +% seed * 17, y +% seed * 31);
            const h1 = hash2(x *% 2 +% seed, y *% 2 +% seed *% 3);
            const h2 = hash2(x / 4 +% seed *% 7, y / 4 +% seed *% 11);
            const t0 = @as(f32, @floatFromInt(h0 & 255)) / 255.0;
            const t1 = @as(f32, @floatFromInt(h1 & 255)) / 255.0;
            const t2 = @as(f32, @floatFromInt(h2 & 255)) / 255.0;
            const t = t0 * 0.55 + t1 * 0.30 + t2 * 0.15;
            // Alpha encodes height/bump for detail normals (LandClass normal-map stand-in).
            const bump: u8 = @intFromFloat(std.math.clamp(t, 0, 1) * 255.0);
            pixels[y * size + x] = .{
                mixU8(base[0], alt[0], t),
                mixU8(base[1], alt[1], t),
                mixU8(base[2], alt[2], t),
                bump,
            };
        }
    }
    return uploadRgba8(gctx, pixels[0..], size, size, .rgba8_unorm_srgb);
}

fn mixU8(a: u8, b: u8, t: f32) u8 {
    return @intFromFloat(@as(f32, @floatFromInt(a)) * (1 - t) + @as(f32, @floatFromInt(b)) * t);
}

fn hash2(x: u32, y: u32) u32 {
    var h = x *% 374761393 +% y *% 668265263;
    h = (h ^ (h >> 13)) *% 1274126177;
    return h ^ (h >> 16);
}

fn uploadRgba8(
    gctx: *zgpu.GraphicsContext,
    pixels: []const [4]u8,
    width: u32,
    height: u32,
    format: wgpu.TextureFormat,
) zgpu.TextureHandle {
    const tex = gctx.createTexture(.{
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .dimension = .tdim_2d,
        .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
        .format = format,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    gctx.queue.writeTexture(
        .{
            .texture = gctx.lookupResource(tex).?,
            .mip_level = 0,
            .origin = .{},
            .aspect = .all,
        },
        .{
            .offset = 0,
            .bytes_per_row = width * 4,
            .rows_per_image = height,
        },
        .{ .width = width, .height = height, .depth_or_array_layers = 1 },
        [4]u8,
        pixels,
    );
    return tex;
}

test "pack splat rgba" {
    const allocator = std.testing.allocator;
    var s = try SplatMap.init(allocator, 1);
    defer s.deinit();
    s.set(0, 0, .{ 1, 1, 0, 0 });
    const px = try packSplatRgba8(allocator, &s);
    defer allocator.free(px);
    try std.testing.expect(px[0][0] >= 127 and px[0][0] <= 128);
    try std.testing.expect(px[0][1] >= 127 and px[0][1] <= 128);
    try std.testing.expectEqual(@as(u8, 0), px[0][2]);
}

const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zm = @import("zmath");
const zmesh = @import("zmesh");
const zstbi = @import("zstbi");
const log = @import("../core/log.zig");
const mesh = @import("mesh.zig");
const material = @import("material.zig");
const draw_list = @import("draw_list.zig");
const frustum_mod = @import("frustum.zig");
const gpu_driven = @import("gpu_driven.zig");
const gbuffer = @import("gbuffer.zig");
const shadow = @import("shadow.zig");

const zcgltf = zmesh.io.zcgltf;

pub const Primitive = struct {
    gpu: mesh.Mesh,
    transform: zm.Mat = zm.identity(),
    local_min: [3]f32 = .{ -0.5, -0.5, -0.5 },
    local_max: [3]f32 = .{ 0.5, 0.5, 0.5 },
    material_index: u32 = 0,
};

pub const MaterialGpu = struct {
    mat: material.Material = .{},
    gbuffer_bg: zgpu.BindGroupHandle = .{},
    shadow_bg: zgpu.BindGroupHandle = .{},
};

/// Loaded glTF scene ready for deferred G-buffer + CSM alpha shadows.
pub const Scene = struct {
    allocator: std.mem.Allocator,
    primitives: std.ArrayList(Primitive) = .{},
    materials: std.ArrayList(MaterialGpu) = .{},
    aabb_min: [3]f32 = .{ 0, 0, 0 },
    aabb_max: [3]f32 = .{ 0, 0, 0 },

    pub fn deinit(self: *Scene, gctx: *zgpu.GraphicsContext) void {
        for (self.primitives.items) |*p| {
            if (gctx.isResourceValid(p.gpu.vertex_buffer)) gctx.destroyResource(p.gpu.vertex_buffer);
            if (gctx.isResourceValid(p.gpu.index_buffer)) gctx.destroyResource(p.gpu.index_buffer);
        }
        self.primitives.deinit(self.allocator);
        for (self.materials.items) |*m| {
            if (gctx.isResourceValid(m.gbuffer_bg)) gctx.releaseResource(m.gbuffer_bg);
            if (gctx.isResourceValid(m.shadow_bg)) gctx.releaseResource(m.shadow_bg);
            m.mat.destroy(gctx);
        }
        self.materials.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn createBindGroups(
        self: *Scene,
        gctx: *zgpu.GraphicsContext,
        gbuffer_bgl: zgpu.BindGroupLayoutHandle,
        shadow_bgl: zgpu.BindGroupLayoutHandle,
        gbuffer_instances: zgpu.BufferHandle,
        shadow_instances: zgpu.BufferHandle,
        instance_bytes: usize,
    ) void {
        for (self.materials.items) |*m| {
            if (gctx.isResourceValid(m.gbuffer_bg)) gctx.releaseResource(m.gbuffer_bg);
            if (gctx.isResourceValid(m.shadow_bg)) gctx.releaseResource(m.shadow_bg);
            m.gbuffer_bg = gctx.createBindGroup(gbuffer_bgl, &.{
                .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(gbuffer.GBufferUniforms) },
                .{ .binding = 1, .buffer_handle = gbuffer_instances, .offset = 0, .size = instance_bytes },
                .{ .binding = 2, .sampler_handle = m.mat.maps.sampler },
                .{ .binding = 3, .texture_view_handle = m.mat.maps.albedo_view },
                .{ .binding = 4, .texture_view_handle = m.mat.maps.normal_view },
                .{ .binding = 5, .texture_view_handle = m.mat.maps.orm_view },
                .{ .binding = 6, .texture_view_handle = m.mat.maps.emissive_view },
            });
            m.shadow_bg = gctx.createBindGroup(shadow_bgl, &.{
                .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(shadow.DepthUniforms) },
                .{ .binding = 1, .buffer_handle = shadow_instances, .offset = 0, .size = instance_bytes },
                .{ .binding = 2, .sampler_handle = m.mat.maps.sampler },
                .{ .binding = 3, .texture_view_handle = m.mat.maps.albedo_view },
            });
        }
    }
};

pub fn loadFile(
    gctx: *zgpu.GraphicsContext,
    allocator: std.mem.Allocator,
    path: [:0]const u8,
) !Scene {
    zmesh.init(allocator);
    defer zmesh.deinit();

    const data = try zcgltf.parseAndLoadFile(path);
    defer zcgltf.freeData(data);

    const dir = std.fs.path.dirname(path) orelse ".";

    var scene: Scene = .{ .allocator = allocator };
    errdefer scene.deinit(gctx);

    try scene.materials.append(allocator, .{
        .mat = try makeFallbackMaterial(gctx, allocator),
    });

    if (data.materials) |mats| {
        var mi: usize = 0;
        while (mi < data.materials_count) : (mi += 1) {
            const mat = loadGltfMaterial(gctx, allocator, dir, &mats[mi]) catch |err| {
                log.warn(.render, "gltf material {d} failed ({s}); fallback", .{ mi, @errorName(err) });
                try scene.materials.append(allocator, .{ .mat = try makeFallbackMaterial(gctx, allocator) });
                continue;
            };
            try scene.materials.append(allocator, .{ .mat = mat });
        }
    }

    const empty_roots: []*zcgltf.Node = &.{};
    const roots: []*zcgltf.Node = blk: {
        if (data.scene) |sc| {
            if (sc.nodes) |nodes| break :blk nodes[0..sc.nodes_count];
        }
        if (data.scenes_count > 0) {
            const sc = data.scenes.?[0];
            if (sc.nodes) |nodes| break :blk nodes[0..sc.nodes_count];
        }
        break :blk empty_roots;
    };

    if (roots.len == 0 and data.nodes_count > 0) {
        var ni: usize = 0;
        while (ni < data.nodes_count) : (ni += 1) {
            const node = &data.nodes.?[ni];
            if (node.parent != null) continue;
            try appendNodePrimitives(gctx, allocator, data, node, &scene);
        }
    } else {
        for (roots) |node| {
            try appendNodePrimitives(gctx, allocator, data, node, &scene);
        }
    }

    if (scene.primitives.items.len > 0) {
        var amin = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
        var amax = [3]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
        for (scene.primitives.items) |p| {
            const w = draw_list.transformAabb(p.local_min, p.local_max, p.transform);
            amin[0] = @min(amin[0], w[0][0]);
            amin[1] = @min(amin[1], w[0][1]);
            amin[2] = @min(amin[2], w[0][2]);
            amax[0] = @max(amax[0], w[1][0]);
            amax[1] = @max(amax[1], w[1][1]);
            amax[2] = @max(amax[2], w[1][2]);
        }
        scene.aabb_min = amin;
        scene.aabb_max = amax;
    }

    log.info(.render, "gltf '{s}' primitives={d} materials={d} aabb=({d:.1},{d:.1},{d:.1})-({d:.1},{d:.1},{d:.1})", .{
        path,
        scene.primitives.items.len,
        scene.materials.items.len,
        scene.aabb_min[0],
        scene.aabb_min[1],
        scene.aabb_min[2],
        scene.aabb_max[0],
        scene.aabb_max[1],
        scene.aabb_max[2],
    });
    return scene;
}

fn appendNodePrimitives(
    gctx: *zgpu.GraphicsContext,
    allocator: std.mem.Allocator,
    data: *zcgltf.Data,
    node: *zcgltf.Node,
    scene: *Scene,
) !void {
    if (node.mesh) |mesh_ptr| {
        const mesh_index = indexOfMesh(data, mesh_ptr);
        const world_col = node.transformWorld();
        const world = matFromGltfColMajor(world_col);

        var pi: u32 = 0;
        while (pi < mesh_ptr.primitives_count) : (pi += 1) {
            var indices: std.ArrayListUnmanaged(u32) = .{};
            defer indices.deinit(allocator);
            var positions: std.ArrayListUnmanaged([3]f32) = .{};
            defer positions.deinit(allocator);
            var normals: std.ArrayListUnmanaged([3]f32) = .{};
            defer normals.deinit(allocator);
            var uvs: std.ArrayListUnmanaged([2]f32) = .{};
            defer uvs.deinit(allocator);

            try zcgltf.appendMeshPrimitive(
                allocator,
                data,
                mesh_index,
                pi,
                &indices,
                &positions,
                &normals,
                &uvs,
                null,
            );

            if (positions.items.len == 0 or indices.items.len == 0) continue;

            var verts = try allocator.alloc(mesh.Vertex, positions.items.len);
            defer allocator.free(verts);
            var amin = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
            var amax = [3]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
            for (positions.items, 0..) |p, vi| {
                const n = if (vi < normals.items.len) normals.items[vi] else [3]f32{ 0, 1, 0 };
                const uv = if (vi < uvs.items.len) uvs.items[vi] else [2]f32{ 0, 0 };
                verts[vi] = .{
                    .position = p,
                    .normal = n,
                    .color = .{ 1, 1, 1 },
                    .uv = uv,
                };
                amin[0] = @min(amin[0], p[0]);
                amin[1] = @min(amin[1], p[1]);
                amin[2] = @min(amin[2], p[2]);
                amax[0] = @max(amax[0], p[0]);
                amax[1] = @max(amax[1], p[1]);
                amax[2] = @max(amax[2], p[2]);
            }

            const prim = &mesh_ptr.primitives[pi];
            try scene.primitives.append(allocator, .{
                .gpu = mesh.createGpuMesh(gctx, verts, indices.items),
                .transform = world,
                .local_min = amin,
                .local_max = amax,
                .material_index = materialIndex(data, prim.material),
            });
        }
    }

    if (node.children) |children| {
        var ci: usize = 0;
        while (ci < node.children_count) : (ci += 1) {
            try appendNodePrimitives(gctx, allocator, data, children[ci], scene);
        }
    }
}

fn indexOfMesh(data: *zcgltf.Data, mesh_ptr: *zcgltf.Mesh) u32 {
    const base = data.meshes orelse return 0;
    const off = @intFromPtr(mesh_ptr) - @intFromPtr(base);
    return @intCast(off / @sizeOf(zcgltf.Mesh));
}

fn materialIndex(data: *zcgltf.Data, mat: ?*zcgltf.Material) u32 {
    const m = mat orelse return 0;
    const base = data.materials orelse return 0;
    const off = @intFromPtr(m) - @intFromPtr(base);
    return @intCast(1 + off / @sizeOf(zcgltf.Material));
}

fn matFromGltfColMajor(m: [16]f32) zm.Mat {
    return .{
        zm.f32x4(m[0], m[4], m[8], m[12]),
        zm.f32x4(m[1], m[5], m[9], m[13]),
        zm.f32x4(m[2], m[6], m[10], m[14]),
        zm.f32x4(m[3], m[7], m[11], m[15]),
    };
}

fn makeFallbackMaterial(gctx: *zgpu.GraphicsContext, allocator: std.mem.Allocator) !material.Material {
    const albedo = try material.createSolidRgba(gctx, allocator, .{ 180, 180, 180, 255 }, .rgba8_unorm_srgb);
    const normal = try material.createSolidRgba(gctx, allocator, .{ 128, 128, 255, 255 }, .rgba8_unorm);
    const orm = try material.createSolidRgba(gctx, allocator, .{ 255, 200, 0, 255 }, .rgba8_unorm);
    const emissive = try material.createSolidRgba(gctx, allocator, .{ 0, 0, 0, 255 }, .rgba8_unorm_srgb);
    return .{
        .maps = .{
            .albedo = albedo.tex,
            .albedo_view = albedo.view,
            .normal = normal.tex,
            .normal_view = normal.view,
            .orm = orm.tex,
            .orm_view = orm.view,
            .emissive = emissive.tex,
            .emissive_view = emissive.view,
            .sampler = gctx.createSampler(.{
                .mag_filter = .linear,
                .min_filter = .linear,
                .mipmap_filter = .linear,
                .address_mode_u = .repeat,
                .address_mode_v = .repeat,
                .address_mode_w = .repeat,
            }),
            .name = "gltf_fallback",
        },
        .metallic = 0.0,
        .roughness = 0.8,
        .ao = 1.0,
        .alpha_mode = .@"opaque",
    };
}

fn gltfAlphaMode(mode: zcgltf.AlphaMode) material.AlphaMode {
    return switch (mode) {
        .mask => .mask,
        .blend => .blend,
        .@"opaque" => .@"opaque",
    };
}

fn loadGltfMaterial(
    gctx: *zgpu.GraphicsContext,
    allocator: std.mem.Allocator,
    dir: []const u8,
    mat: *const zcgltf.Material,
) !material.Material {
    var albedo = try material.createSolidRgba(gctx, allocator, .{ 200, 200, 200, 255 }, .rgba8_unorm_srgb);
    errdefer {
        gctx.releaseResource(albedo.view);
        gctx.destroyResource(albedo.tex);
    }
    var normal = try material.createSolidRgba(gctx, allocator, .{ 128, 128, 255, 255 }, .rgba8_unorm);
    errdefer {
        gctx.releaseResource(normal.view);
        gctx.destroyResource(normal.tex);
    }
    var orm = try material.createSolidRgba(gctx, allocator, .{ 255, 180, 0, 255 }, .rgba8_unorm);
    errdefer {
        gctx.releaseResource(orm.view);
        gctx.destroyResource(orm.tex);
    }
    var emissive = try material.createSolidRgba(gctx, allocator, .{ 0, 0, 0, 255 }, .rgba8_unorm_srgb);
    errdefer {
        gctx.releaseResource(emissive.view);
        gctx.destroyResource(emissive.tex);
    }

    var base_color = [3]f32{ 1, 1, 1 };
    var metallic: f32 = 1;
    var roughness: f32 = 1;

    if (mat.has_pbr_metallic_roughness != 0) {
        const pbr = mat.pbr_metallic_roughness;
        metallic = pbr.metallic_factor;
        roughness = pbr.roughness_factor;
        base_color = .{ pbr.base_color_factor[0], pbr.base_color_factor[1], pbr.base_color_factor[2] };
        if (textureImagePath(allocator, dir, pbr.base_color_texture)) |path| {
            defer allocator.free(path);
            if (material.loadTextureFile(gctx, allocator, path, .rgba8_unorm_srgb)) |L| {
                gctx.releaseResource(albedo.view);
                gctx.destroyResource(albedo.tex);
                albedo.tex = L.tex;
                albedo.view = L.view;
            } else |_| {}
        }
        if (textureImagePath(allocator, dir, pbr.metallic_roughness_texture)) |mr_path| {
            defer allocator.free(mr_path);
            const ao_path = textureImagePath(allocator, dir, mat.occlusion_texture);
            defer if (ao_path) |p| allocator.free(p);
            if (packOrmMaps(gctx, allocator, mr_path, ao_path)) |packed_orm| {
                gctx.releaseResource(orm.view);
                gctx.destroyResource(orm.tex);
                orm.tex = packed_orm.tex;
                orm.view = packed_orm.view;
            } else |_| {}
        }
    }

    if (textureImagePath(allocator, dir, mat.normal_texture)) |path| {
        defer allocator.free(path);
        if (material.loadTextureFile(gctx, allocator, path, .rgba8_unorm)) |L| {
            gctx.releaseResource(normal.view);
            gctx.destroyResource(normal.tex);
            normal.tex = L.tex;
            normal.view = L.view;
        } else |_| {}
    }

    if (textureImagePath(allocator, dir, mat.emissive_texture)) |path| {
        defer allocator.free(path);
        if (material.loadTextureFile(gctx, allocator, path, .rgba8_unorm_srgb)) |L| {
            gctx.releaseResource(emissive.view);
            gctx.destroyResource(emissive.tex);
            emissive.tex = L.tex;
            emissive.view = L.view;
        } else |_| {}
    }

    return .{
        .maps = .{
            .albedo = albedo.tex,
            .albedo_view = albedo.view,
            .normal = normal.tex,
            .normal_view = normal.view,
            .orm = orm.tex,
            .orm_view = orm.view,
            .emissive = emissive.tex,
            .emissive_view = emissive.view,
            .sampler = gctx.createSampler(.{
                .mag_filter = .linear,
                .min_filter = .linear,
                .mipmap_filter = .linear,
                .address_mode_u = .repeat,
                .address_mode_v = .repeat,
                .address_mode_w = .repeat,
            }),
            .metallic = 1,
            .roughness = 1,
            .ao = 1,
            .name = "gltf",
        },
        .metallic = metallic,
        .roughness = roughness,
        .ao = 1,
        .base_color = base_color,
        .emissive_factor = mat.emissive_factor,
        .alpha_mode = gltfAlphaMode(mat.alpha_mode),
        .alpha_cutoff = mat.alpha_cutoff,
        .double_sided = mat.double_sided != 0,
        .use_maps = true,
    };
}

fn textureImagePath(allocator: std.mem.Allocator, dir: []const u8, view: zcgltf.TextureView) ?[:0]u8 {
    const tex = view.texture orelse return null;
    const img = tex.image orelse return null;
    const uri = img.uri orelse return null;
    const uri_s = std.mem.span(uri);
    if (std.mem.startsWith(u8, uri_s, "data:")) return null;
    return std.fs.path.joinZ(allocator, &.{ dir, uri_s }) catch null;
}

fn packOrmMaps(
    gctx: *zgpu.GraphicsContext,
    allocator: std.mem.Allocator,
    mr_path: [:0]const u8,
    ao_path: ?[:0]const u8,
) !struct { tex: zgpu.TextureHandle, view: zgpu.TextureViewHandle } {
    var mr = try zstbi.Image.loadFromFile(mr_path, 4);
    defer mr.deinit();
    const w = mr.width;
    const h = mr.height;
    const mr_px = std.mem.bytesAsSlice([4]u8, mr.data[0 .. w * h * 4]);

    var ao_img: ?zstbi.Image = null;
    defer if (ao_img) |*a| a.deinit();
    if (ao_path) |p| {
        if (zstbi.Image.loadFromFile(p, 4)) |loaded| {
            var img = loaded;
            if (img.width == w and img.height == h) {
                ao_img = img;
            } else {
                img.deinit();
            }
        } else |_| {}
    }

    var out = try allocator.alloc([4]u8, w * h);
    defer allocator.free(out);
    // glTF: metallicRoughness uses G=roughness, B=metallic; R MUST be ignored unless
    // the same image is also the occlusionTexture. Missing AO → 255 (not MR.R, often 0).
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const ao: u8 = if (ao_img) |a| blk: {
            const ap = std.mem.bytesAsSlice([4]u8, a.data[0 .. w * h * 4]);
            break :blk ap[i][0];
        } else 255;
        out[i] = .{ ao, mr_px[i][1], mr_px[i][2], 255 };
    }
    const tex = try material.uploadRgba8Public(gctx, allocator, out, w, h, .rgba8_unorm);
    return .{ .tex = tex, .view = gctx.createTextureView(tex, .{}) };
}

fn drawPrimitive(
    scene: *const Scene,
    gctx: *zgpu.GraphicsContext,
    pass: wgpu.RenderPassEncoder,
    p: Primitive,
    instance_buf: zgpu.BufferHandle,
    use_shadow_bg: bool,
    uniform_offset: u32,
) void {
    const mat_i = @min(p.material_index, @as(u32, @intCast(scene.materials.items.len -| 1)));
    const mg = &scene.materials.items[mat_i];
    const bg_handle = if (use_shadow_bg) mg.shadow_bg else mg.gbuffer_bg;
    const bg = gctx.lookupResource(bg_handle) orelse return;
    const vb = gctx.lookupResourceInfo(p.gpu.vertex_buffer) orelse return;
    const ib = gctx.lookupResourceInfo(p.gpu.index_buffer) orelse return;

    const inst: gpu_driven.InstanceGpu = .{
        .object_to_world = zm.transpose(p.transform),
        .material = mg.mat.instanceMaterial(),
        .color = mg.mat.instanceColor(),
    };
    gctx.queue.writeBuffer(gctx.lookupResource(instance_buf).?, 0, gpu_driven.InstanceGpu, &.{inst});

    pass.setBindGroup(0, bg, &.{uniform_offset});
    pass.setVertexBuffer(0, vb.gpuobj.?, 0, vb.size);
    pass.setIndexBuffer(ib.gpuobj.?, .uint32, 0, ib.size);
    pass.drawIndexed(p.gpu.index_count, 1, 0, 0, 0);
}

pub fn drawGBuffer(
    scene: *const Scene,
    gctx: *zgpu.GraphicsContext,
    pass: wgpu.RenderPassEncoder,
    world_to_clip: zm.Mat,
    instance_buf: zgpu.BufferHandle,
) void {
    const fr = frustum_mod.Frustum.fromViewProj(world_to_clip);
    for (scene.primitives.items) |p| {
        const world_aabb = draw_list.transformAabb(p.local_min, p.local_max, p.transform);
        if (!fr.containsAabb(world_aabb[0], world_aabb[1])) continue;
        const mem = gctx.uniformsAllocate(gbuffer.GBufferUniforms, 1);
        mem.slice[0] = .{ .world_to_clip = zm.transpose(world_to_clip) };
        drawPrimitive(scene, gctx, pass, p, instance_buf, false, mem.offset);
    }
}

/// CSM / directional depth with albedo alpha test.
pub fn drawDepth(
    scene: *const Scene,
    gctx: *zgpu.GraphicsContext,
    pass: wgpu.RenderPassEncoder,
    light_vp: zm.Mat,
    instance_buf: zgpu.BufferHandle,
) void {
    const fr = frustum_mod.Frustum.fromViewProj(light_vp);
    for (scene.primitives.items) |p| {
        const world_aabb = draw_list.transformAabb(p.local_min, p.local_max, p.transform);
        if (!fr.containsAabb(world_aabb[0], world_aabb[1])) continue;
        const mem = gctx.uniformsAllocate(shadow.DepthUniforms, 1);
        mem.slice[0] = .{ .light_vp = zm.transpose(light_vp) };
        drawPrimitive(scene, gctx, pass, p, instance_buf, true, mem.offset);
    }
}

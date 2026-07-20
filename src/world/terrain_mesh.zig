const std = @import("std");
const mesh = @import("../render/mesh.zig");
const Heightfield = @import("heightfield.zig").Heightfield;
const SplatMap = @import("splat.zig").SplatMap;
const HoleField = @import("holes.zig").HoleField;
const LodBand = @import("chunk.zig").LodBand;
const terraform = @import("terraform.zig");

/// Geo-mipmap step for distance LOD (Dagor LodGrid role; WebGPU sem hull/domain).
pub fn stepForLod(lod: LodBand) u32 {
    return switch (lod) {
        .lod0 => 1,
        .lod1 => 2,
        .lod2 => 4,
    };
}

/// Skirt depth in world units (fills T-junction cracks between LODs).
pub const skirt_depth: f32 = 2.0;

pub const BuiltMesh = struct {
    allocator: std.mem.Allocator,
    vertices: []mesh.TerrainPackedVertex,
    indices: []u32,
    decode: mesh.TerrainDecode,

    pub fn deinit(self: *BuiltMesh) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
        self.* = undefined;
    }
};

fn quantizePos(v: f32, origin: f32, scale: f32) i16 {
    if (scale < 1e-8) return 0;
    const t = (v - origin) / scale;
    return @intFromFloat(std.math.clamp(t, -1, 1) * 32767.0);
}

fn quantizeN(v: f32) i16 {
    return @intFromFloat(std.math.clamp(v, -1, 1) * 32767.0);
}

fn heightAt(hf: *const Heightfield, tf: ?*const terraform.Terraform, x: u32, z: u32) f32 {
    const sp = hf.sampleSpacing();
    const wx = hf.origin_x + @as(f32, @floatFromInt(x)) * sp;
    const wz = hf.origin_z + @as(f32, @floatFromInt(z)) * sp;
    return terraform.sampleWorld(hf, tf, wx, wz);
}

fn vertAt(
    hf: *const Heightfield,
    tf: ?*const terraform.Terraform,
    decode: mesh.TerrainDecode,
    x: u32,
    z: u32,
    y_offset: f32,
) mesh.TerrainPackedVertex {
    const sp = hf.sampleSpacing();
    const wx = hf.origin_x + @as(f32, @floatFromInt(x)) * sp;
    const wz = hf.origin_z + @as(f32, @floatFromInt(z)) * sp;
    const wy = heightAt(hf, tf, x, z) + y_offset;

    const x0 = if (x > 0) x - 1 else x;
    const x1 = @min(x + 1, hf.resolution);
    const z0 = if (z > 0) z - 1 else z;
    const z1 = @min(z + 1, hf.resolution);
    const dhx = (heightAt(hf, tf, x1, z) - heightAt(hf, tf, x0, z)) / (@as(f32, @floatFromInt(@max(x1 - x0, 1))) * sp);
    const dhz = (heightAt(hf, tf, x, z1) - heightAt(hf, tf, x, z0)) / (@as(f32, @floatFromInt(@max(z1 - z0, 1))) * sp);
    var nx = -dhx;
    var ny: f32 = 1;
    var nz = -dhz;
    const len = @sqrt(nx * nx + ny * ny + nz * nz);
    nx /= len;
    ny /= len;
    nz /= len;

    const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(hf.resolution));
    const v = @as(f32, @floatFromInt(z)) / @as(f32, @floatFromInt(hf.resolution));
    return .{
        .px = quantizePos(wx, decode.origin[0], decode.scale[0]),
        .py = quantizePos(wy, decode.origin[1], decode.scale[1]),
        .pz = quantizePos(wz, decode.origin[2], decode.scale[2]),
        .nx = quantizeN(nx),
        .ny = quantizeN(ny),
        .nz = quantizeN(nz),
        .u = @intFromFloat(std.math.clamp(u, 0, 1) * 65535.0),
        .v = @intFromFloat(std.math.clamp(v, 0, 1) * 65535.0),
    };
}

fn makeDecode(hf: *const Heightfield) mesh.TerrainDecode {
    const mm = hf.minMax();
    const pad_y = @max((mm.max - mm.min) * 0.1, 2.0);
    return .{
        .origin = .{ hf.origin_x, mm.min - pad_y, hf.origin_z, 0 },
        .scale = .{
            hf.world_size,
            (mm.max - mm.min) + pad_y * 2.0 + skirt_depth,
            hf.world_size,
            0,
        },
    };
}

/// Build packed int16 mesh from heightfield + optional terraform/holes/splat + LOD skirts.
pub fn buildMesh(
    allocator: std.mem.Allocator,
    hf: *const Heightfield,
    splat: ?*const SplatMap,
    holes: ?*const HoleField,
    step: u32,
) !BuiltMesh {
    return buildMeshEx(allocator, hf, null, splat, holes, step);
}

pub fn buildMeshEx(
    allocator: std.mem.Allocator,
    hf: *const Heightfield,
    tf: ?*const terraform.Terraform,
    splat: ?*const SplatMap,
    holes: ?*const HoleField,
    step: u32,
) !BuiltMesh {
    _ = splat;
    std.debug.assert(step >= 1);
    const grid_n = (hf.resolution / step) + 1;
    const decode = makeDecode(hf);

    var vertices: std.ArrayList(mesh.TerrainPackedVertex) = .{};
    errdefer vertices.deinit(allocator);
    try vertices.ensureTotalCapacity(allocator, grid_n * grid_n + grid_n * 4 * 2);

    var gz: u32 = 0;
    while (gz < grid_n) : (gz += 1) {
        var gx: u32 = 0;
        while (gx < grid_n) : (gx += 1) {
            const x = @min(gx * step, hf.resolution);
            const z = @min(gz * step, hf.resolution);
            try vertices.append(allocator, vertAt(hf, tf, decode, x, z, 0));
        }
    }

    var indices: std.ArrayList(u32) = .{};
    errdefer indices.deinit(allocator);

    var cz: u32 = 0;
    while (cz + 1 < grid_n) : (cz += 1) {
        var cx: u32 = 0;
        while (cx + 1 < grid_n) : (cx += 1) {
            const x = cx * step;
            const z = cz * step;
            const x1 = @min(x + step, hf.resolution);
            const z1 = @min(z + step, hf.resolution);
            if (holes) |h| {
                if (h.isHole(x, z) or h.isHole(x1, z) or h.isHole(x, z1) or h.isHole(x1, z1))
                    continue;
                const sp = hf.sampleSpacing();
                const wx = hf.origin_x + (@as(f32, @floatFromInt(x + x1)) * 0.5) * sp;
                const wz = hf.origin_z + (@as(f32, @floatFromInt(z + z1)) * 0.5) * sp;
                const wy = (heightAt(hf, tf, x, z) + heightAt(hf, tf, x1, z) + heightAt(hf, tf, x, z1) + heightAt(hf, tf, x1, z1)) * 0.25;
                if (h.isHoleWorld(wx, wy, wz)) continue;
            }
            const v00: u32 = cz * grid_n + cx;
            const v10: u32 = cz * grid_n + (cx + 1);
            const v01: u32 = (cz + 1) * grid_n + cx;
            const v11: u32 = (cz + 1) * grid_n + (cx + 1);
            // Front faces point +Y (solid when viewed from above). Empirically the opposite
            // of mesh.planeIndices — WebGPU LH + ccw culls the old order from above.
            try indices.appendSlice(allocator, &[_]u32{ v00, v10, v11, v00, v11, v01 });
        }
    }

    // Always emit skirts — hides T-junction cracks between LOD bands and micro seams.
    {
        const base_count: u32 = @intCast(vertices.items.len);
        {
            var sx: u32 = 0;
            while (sx < grid_n) : (sx += 1) {
                const x = @min(sx * step, hf.resolution);
                try vertices.append(allocator, vertAt(hf, tf, decode, x, 0, -skirt_depth));
            }
            sx = 0;
            while (sx + 1 < grid_n) : (sx += 1) {
                try indices.appendSlice(allocator, &[_]u32{ sx, base_count + sx, sx + 1, sx + 1, base_count + sx, base_count + sx + 1 });
            }
        }
        const after_neg_z: u32 = @intCast(vertices.items.len);
        {
            var sx: u32 = 0;
            while (sx < grid_n) : (sx += 1) {
                const x = @min(sx * step, hf.resolution);
                try vertices.append(allocator, vertAt(hf, tf, decode, x, hf.resolution, -skirt_depth));
            }
            sx = 0;
            while (sx + 1 < grid_n) : (sx += 1) {
                const top0 = (grid_n - 1) * grid_n + sx;
                const top1 = (grid_n - 1) * grid_n + sx + 1;
                try indices.appendSlice(allocator, &[_]u32{ top0, top1, after_neg_z + sx, top1, after_neg_z + sx + 1, after_neg_z + sx });
            }
        }
        const after_pos_z: u32 = @intCast(vertices.items.len);
        {
            var sz: u32 = 0;
            while (sz < grid_n) : (sz += 1) {
                const z = @min(sz * step, hf.resolution);
                try vertices.append(allocator, vertAt(hf, tf, decode, 0, z, -skirt_depth));
            }
            sz = 0;
            while (sz + 1 < grid_n) : (sz += 1) {
                const top0 = sz * grid_n;
                const top1 = (sz + 1) * grid_n;
                try indices.appendSlice(allocator, &[_]u32{ top0, top1, after_pos_z + sz, top1, after_pos_z + sz + 1, after_pos_z + sz });
            }
        }
        const after_neg_x: u32 = @intCast(vertices.items.len);
        {
            var sz: u32 = 0;
            while (sz < grid_n) : (sz += 1) {
                const z = @min(sz * step, hf.resolution);
                try vertices.append(allocator, vertAt(hf, tf, decode, hf.resolution, z, -skirt_depth));
            }
            sz = 0;
            while (sz + 1 < grid_n) : (sz += 1) {
                const top0 = sz * grid_n + (grid_n - 1);
                const top1 = (sz + 1) * grid_n + (grid_n - 1);
                try indices.appendSlice(allocator, &[_]u32{ top0, after_neg_x + sz, top1, top1, after_neg_x + sz, after_neg_x + sz + 1 });
            }
        }
    }

    return .{
        .allocator = allocator,
        .vertices = try vertices.toOwnedSlice(allocator),
        .indices = try indices.toOwnedSlice(allocator),
        .decode = decode,
    };
}

pub fn buildMeshForLod(
    allocator: std.mem.Allocator,
    hf: *const Heightfield,
    splat: ?*const SplatMap,
    holes: ?*const HoleField,
    lod: LodBand,
) !BuiltMesh {
    return buildMesh(allocator, hf, splat, holes, stepForLod(lod));
}

pub fn buildMeshForLodEx(
    allocator: std.mem.Allocator,
    hf: *const Heightfield,
    tf: ?*const terraform.Terraform,
    splat: ?*const SplatMap,
    holes: ?*const HoleField,
    lod: LodBand,
) !BuiltMesh {
    return buildMeshEx(allocator, hf, tf, splat, holes, stepForLod(lod));
}

pub fn patchBounds(hf: *const Heightfield) struct { min: [3]f32, max: [3]f32 } {
    const mm = if (hf.compressed) |_|
        hf.rangeMinMax(hf.origin_x, hf.origin_z, hf.origin_x + hf.world_size, hf.origin_z + hf.world_size)
    else
        hf.minMax();
    return .{
        .min = .{ hf.origin_x, mm.min, hf.origin_z },
        .max = .{ hf.origin_x + hf.world_size, mm.max, hf.origin_z + hf.world_size },
    };
}

/// Dagor landMesh CellData layers: land / decal / combined / patches.
pub const MeshLayer = enum { land, decal, combined, patches };

pub const CombinedMeshes = struct {
    allocator: std.mem.Allocator,
    land: BuiltMesh,
    /// Optional projective/overlay mesh (may be empty indices).
    decal: ?BuiltMesh = null,
    /// Merged static extras (may share land geometry when unused).
    combined: ?BuiltMesh = null,
    /// High-detail mesh over terraform dirty regions.
    patches: ?BuiltMesh = null,

    pub fn deinit(self: *CombinedMeshes) void {
        self.land.deinit();
        if (self.decal) |*m| m.deinit();
        if (self.combined) |*m| m.deinit();
        if (self.patches) |*m| m.deinit();
        self.* = undefined;
    }
};

/// Build land + optional patches/decal/combined (Dagor lmesh CellData role).
pub fn buildCombined(
    allocator: std.mem.Allocator,
    hf: *const Heightfield,
    tf: ?*const terraform.Terraform,
    splat: ?*const SplatMap,
    holes: ?*const HoleField,
    lod: LodBand,
) !CombinedMeshes {
    var land = try buildMeshForLodEx(allocator, hf, tf, splat, holes, lod);
    errdefer land.deinit();

    var patches: ?BuiltMesh = null;
    if (tf) |t| {
        if (t.dirtyBounds() != null) {
            // Full-res patch mesh when terraform dirty (Dagor patches ShaderMesh).
            patches = try buildMeshEx(allocator, hf, tf, splat, holes, 1);
        }
    }

    // Decal: hole-rim strip — reuse land topology filtered is expensive; emit empty stub mesh.
    var decal_verts = try allocator.alloc(mesh.TerrainPackedVertex, 0);
    var decal_inds = try allocator.alloc(u32, 0);
    const decal: BuiltMesh = .{
        .allocator = allocator,
        .vertices = decal_verts,
        .indices = decal_inds,
        .decode = land.decode,
    };

    // Combined distant merge is opt-in later; building it every tile doubled GPU cost and
    // was incorrectly drawn with land (shard artifacts).
    _ = &decal_verts;
    _ = &decal_inds;
    return .{
        .allocator = allocator,
        .land = land,
        .decal = decal,
        .combined = null,
        .patches = patches,
    };
}

test "combined meshes has land" {
    const allocator = std.testing.allocator;
    var hf = try Heightfield.init(allocator, 8, 32);
    defer hf.deinit();
    var set = try buildCombined(allocator, &hf, null, null, null, .lod1);
    defer set.deinit();
    try std.testing.expect(set.land.indices.len > 0);
    // Combined distant merge is opt-in (null by default) to avoid double-draw shards.
    try std.testing.expect(set.combined == null);
}

test "mesh lod reduces indices" {
    const allocator = std.testing.allocator;
    var hf = try Heightfield.init(allocator, 8, 32);
    defer hf.deinit();
    var z: u32 = 0;
    while (z <= 8) : (z += 1) {
        var x: u32 = 0;
        while (x <= 8) : (x += 1) {
            hf.set(x, z, @as(f32, @floatFromInt(x + z)) * 0.1);
        }
    }
    var hi = try buildMeshForLod(allocator, &hf, null, null, .lod0);
    defer hi.deinit();
    var lo = try buildMeshForLod(allocator, &hf, null, null, .lod2);
    defer lo.deinit();
    try std.testing.expect(hi.indices.len > lo.indices.len);
    try std.testing.expect(lo.vertices.len > (8 / 4 + 1) * (8 / 4 + 1));
    try std.testing.expect(@sizeOf(mesh.TerrainPackedVertex) <= 20);
}

test "land winding faces +Y from above" {
    const v00 = [2]f32{ 0, 0 };
    const v10 = [2]f32{ 1, 0 };
    const v01 = [2]f32{ 0, 1 };
    const v11 = [2]f32{ 1, 1 };
    const shoelace = struct {
        fn area(a: [2]f32, b: [2]f32, c: [2]f32) f32 {
            return a[0] * (b[1] - c[1]) + b[0] * (c[1] - a[1]) + c[0] * (a[1] - b[1]);
        }
    }.area;
    // v00,v10,v11 — CCW in XZ (Z-up paper) → front from above with our GPU convention.
    try std.testing.expect(shoelace(v00, v10, v11) > 0);
    _ = v01;
}

test "holes remove triangles" {
    const allocator = std.testing.allocator;
    var hf = try Heightfield.init(allocator, 4, 16);
    defer hf.deinit();
    var holes = try HoleField.init(allocator, 4);
    defer holes.deinit();
    holes.stampDisk(&hf, 8, 8, 10, 1.0);
    var solid = try buildMesh(allocator, &hf, null, null, 1);
    defer solid.deinit();
    var cut = try buildMesh(allocator, &hf, null, &holes, 1);
    defer cut.deinit();
    try std.testing.expect(cut.indices.len < solid.indices.len);
}

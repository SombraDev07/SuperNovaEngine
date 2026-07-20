const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Heightfield = @import("heightfield.zig").Heightfield;
const procedural = @import("procedural.zig");
const SplatMap = @import("splat.zig").SplatMap;
const HoleField = @import("holes.zig").HoleField;
const terrain_mesh = @import("terrain_mesh.zig");
const terraform_mod = @import("terraform.zig");

const ChunkCoord = chunk_mod.ChunkCoord;
const LodBand = chunk_mod.LodBand;

pub const TileConfig = struct {
    resolution: u32 = 32,
    chunk_size: f32 = 64.0,
    procedural: procedural.ProceduralConfig = .{},
    /// Stamp a demo hole near chunk center when true.
    demo_hole: bool = false,
    /// Optional per-chunk CHMZ/HMAP path template is handled by streamer; if set, load file instead of procedural.
    heightmap_path: ?[]const u8 = null,
};

/// Full terrain payload for one streamed chunk (owned heap data).
pub const TerrainTile = struct {
    allocator: std.mem.Allocator,
    heightfield: Heightfield,
    splat: SplatMap,
    holes: HoleField,
    /// High-res deformation overlay @ 0.25 m/cell (Dagor Terraform patches).
    terraform: terraform_mod.Terraform,
    lod: LodBand,
    coord: ChunkCoord,
    /// Bumped on CPU edits so GPU cache re-uploads mesh/splat.
    gpu_generation: u32 = 1,

    pub fn deinit(self: *TerrainTile) void {
        self.terraform.deinit();
        self.holes.deinit();
        self.splat.deinit();
        self.heightfield.deinit();
        self.allocator.destroy(self);
    }

    pub fn markDirty(self: *TerrainTile) void {
        if (self.heightfield.dirty_valid) {
            self.heightfield.rebuildCompressedDirty() catch {};
        }
        self.gpu_generation +%= 1;
    }

    pub fn buildMesh(self: *const TerrainTile, allocator: std.mem.Allocator) !terrain_mesh.BuiltMesh {
        return terrain_mesh.buildMeshForLodEx(
            allocator,
            &self.heightfield,
            &self.terraform,
            &self.splat,
            &self.holes,
            self.lod,
        );
    }

    pub fn buildCombinedMeshes(self: *const TerrainTile, allocator: std.mem.Allocator) !terrain_mesh.CombinedMeshes {
        return terrain_mesh.buildCombined(
            allocator,
            &self.heightfield,
            &self.terraform,
            &self.splat,
            &self.holes,
            self.lod,
        );
    }
};

pub fn generateTile(
    allocator: std.mem.Allocator,
    coord: ChunkCoord,
    lod: LodBand,
    cfg: TileConfig,
) !*TerrainTile {
    const tile = try allocator.create(TerrainTile);
    errdefer allocator.destroy(tile);

    var hf = try Heightfield.init(allocator, cfg.resolution, cfg.chunk_size);
    errdefer hf.deinit();
    hf.origin_x = @as(f32, @floatFromInt(coord.x)) * cfg.chunk_size;
    hf.origin_z = @as(f32, @floatFromInt(coord.z)) * cfg.chunk_size;

    var filled = false;
    if (cfg.heightmap_path) |path| {
        // Parallel CHMZ/HMAP unpack inside readFile/importChmap (Dagor UnpackChunkJob).
        if (Heightfield.readFile(allocator, path)) |loaded_raw| {
            var loaded = loaded_raw;
            defer loaded.deinit();
            if (loaded.resolution == hf.resolution) {
                @memcpy(hf.heights, loaded.heights);
                hf.origin_x = @as(f32, @floatFromInt(coord.x)) * cfg.chunk_size;
                hf.origin_z = @as(f32, @floatFromInt(coord.z)) * cfg.chunk_size;
                try hf.rebuildCompressed();
                filled = true;
            }
        } else |_| {}
    }
    if (!filled) {
        var pcfg = cfg.procedural;
        pcfg.seed = cfg.procedural.seed;
        procedural.fillHeightfield(&hf, pcfg);
        try hf.rebuildCompressed();
    }

    var splat = try SplatMap.init(allocator, cfg.resolution);
    errdefer splat.deinit();
    splat.fillFromSlope(&hf, 1.2);

    var holes = try HoleField.init(allocator, cfg.resolution);
    errdefer holes.deinit();
    if (cfg.demo_hole) {
        const c = coord.centerWorld(cfg.chunk_size);
        holes.stampDisk(&hf, c[0], c[1], cfg.chunk_size * 0.15, 1.0);
    }

    tile.* = .{
        .allocator = allocator,
        .heightfield = hf,
        .splat = splat,
        .holes = holes,
        .terraform = terraform_mod.Terraform.init(allocator),
        .lod = lod,
        .coord = coord,
    };
    return tile;
}

test "generate tile mesh" {
    const allocator = std.testing.allocator;
    const tile = try generateTile(allocator, .{ .x = 0, .z = 0 }, .lod1, .{ .resolution = 16, .demo_hole = true });
    defer tile.deinit();
    var m = try tile.buildMesh(allocator);
    defer m.deinit();
    try std.testing.expect(m.vertices.len > 0);
    try std.testing.expect(m.indices.len > 0);
}

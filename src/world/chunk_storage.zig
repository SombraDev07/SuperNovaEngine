const std = @import("std");
const chunk_mod = @import("chunk.zig");
const terrain_tile = @import("terrain_tile.zig");

const ChunkCoord = chunk_mod.ChunkCoord;
const LodBand = chunk_mod.LodBand;

/// BinaryDump / scene storage client role — resolve per-chunk dump paths (CHMZ).
pub const ChunkStorage = struct {
    /// Optional root: `{root}/{x}_{z}.chmz`. Null → procedural only.
    dump_root: ?[]const u8 = null,

    pub fn pathBuf(self: ChunkStorage, coord: ChunkCoord, buf: []u8) ?[]const u8 {
        const root = self.dump_root orelse return null;
        return std.fmt.bufPrint(buf, "{s}/{d}_{d}.chmz", .{ root, coord.x, coord.z }) catch null;
    }

    pub fn fileExists(self: ChunkStorage, coord: ChunkCoord) bool {
        var buf: [512]u8 = undefined;
        const path = self.pathBuf(coord, &buf) orelse return false;
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    /// Ensure dump root directory exists (Dagor bindump folder role).
    pub fn ensureRoot(self: ChunkStorage) !void {
        const root = self.dump_root orelse return;
        std.fs.cwd().makePath(root) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    /// Persist heightfield as CHMZ (BinaryDump write / unload flush role).
    pub fn saveDump(self: ChunkStorage, coord: ChunkCoord, tile: *const terrain_tile.TerrainTile) !void {
        var buf: [512]u8 = undefined;
        const path = self.pathBuf(coord, &buf) orelse return;
        try self.ensureRoot();
        try tile.heightfield.writeFile(path);
    }

    /// Load CHMZ dump when present, else procedural generate (Dagor load_binary_dump_async role).
    pub fn loadOrGenerate(
        self: ChunkStorage,
        allocator: std.mem.Allocator,
        coord: ChunkCoord,
        lod: LodBand,
        base_cfg: terrain_tile.TileConfig,
    ) !*terrain_tile.TerrainTile {
        var cfg = base_cfg;
        var path_buf: [512]u8 = undefined;
        if (self.pathBuf(coord, &path_buf)) |path| {
            if (std.fs.cwd().access(path, .{})) |_| {
                cfg.heightmap_path = path;
            } else |_| {}
        }
        return terrain_tile.generateTile(allocator, coord, lod, cfg);
    }
};

test "storage path format" {
    const s = ChunkStorage{ .dump_root = "assets/world/chunks" };
    var buf: [128]u8 = undefined;
    const p = s.pathBuf(.{ .x = -1, .z = 2 }, &buf).?;
    try std.testing.expectEqualStrings("assets/world/chunks/-1_2.chmz", p);
}

test "dump save load roundtrip" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/tmp_chmz_roundtrip";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const storage = ChunkStorage{ .dump_root = root };
    const coord = ChunkCoord{ .x = 1, .z = -2 };
    const tile = try storage.loadOrGenerate(allocator, coord, .lod0, .{
        .resolution = 8,
        .chunk_size = 32,
    });
    defer tile.deinit();
    tile.heightfield.set(2, 2, 7.5);
    try tile.heightfield.rebuildCompressed();
    try storage.saveDump(coord, tile);
    try std.testing.expect(storage.fileExists(coord));

    const loaded = try storage.loadOrGenerate(allocator, coord, .lod0, .{
        .resolution = 8,
        .chunk_size = 32,
    });
    defer loaded.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 7.5), loaded.heightfield.get(2, 2), 0.05);
}

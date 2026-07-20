const std = @import("std");
const zbasis = @import("zbasis");

pub const HeightRange = struct { min: f32, max: f32 };

/// CPU heightfield (Dagor HeightmapPhysHandler / CompressedHeightmap role) — ROADMAP §3.2.
pub const Heightfield = struct {
    allocator: std.mem.Allocator,
    /// Samples per side (verts = resolution + 1 along each edge when used as grid cells).
    resolution: u32,
    /// World size of the field on XZ (meters).
    world_size: f32,
    /// Origin (min corner) in world XZ.
    origin_x: f32 = 0,
    origin_z: f32 = 0,
    /// Row-major heights[z * (resolution+1) + x], size = (resolution+1)^2.
    heights: []f32,
    /// Optional compressed mirror (block u16 + hierarchy) — rebuilt on `rebuildCompressed`.
    compressed: ?Compressed = null,
    /// Dirty rect in sample coords (inclusive); full field when dirty_valid=false after clear.
    dirty_min_x: u32 = 0,
    dirty_min_z: u32 = 0,
    dirty_max_x: u32 = 0,
    dirty_max_z: u32 = 0,
    dirty_valid: bool = false,

    pub const block_shift: u8 = 3; // 8×8 blocks (Dagor-style)

    pub fn vertCount(resolution: u32) u32 {
        return resolution + 1;
    }

    pub fn init(allocator: std.mem.Allocator, resolution: u32, world_size: f32) !Heightfield {
        std.debug.assert(resolution >= 1);
        std.debug.assert(world_size > 0);
        const n = vertCount(resolution);
        const heights = try allocator.alloc(f32, n * n);
        @memset(heights, 0);
        return .{
            .allocator = allocator,
            .resolution = resolution,
            .world_size = world_size,
            .heights = heights,
        };
    }

    pub fn deinit(self: *Heightfield) void {
        if (self.compressed) |*c| c.deinit(self.allocator);
        self.allocator.free(self.heights);
        self.* = undefined;
    }

    pub fn clone(self: *const Heightfield, allocator: std.mem.Allocator) !Heightfield {
        var out = try init(allocator, self.resolution, self.world_size);
        out.origin_x = self.origin_x;
        out.origin_z = self.origin_z;
        @memcpy(out.heights, self.heights);
        try out.rebuildCompressed();
        return out;
    }

    pub fn index(self: *const Heightfield, x: u32, z: u32) usize {
        const n = vertCount(self.resolution);
        std.debug.assert(x < n and z < n);
        return z * n + x;
    }

    pub fn get(self: *const Heightfield, x: u32, z: u32) f32 {
        return self.heights[self.index(x, z)];
    }

    pub fn set(self: *Heightfield, x: u32, z: u32, h: f32) void {
        self.heights[self.index(x, z)] = h;
        self.markDirtySample(x, z);
    }

    pub fn markDirtySample(self: *Heightfield, x: u32, z: u32) void {
        if (!self.dirty_valid) {
            self.dirty_min_x = x;
            self.dirty_max_x = x;
            self.dirty_min_z = z;
            self.dirty_max_z = z;
            self.dirty_valid = true;
            return;
        }
        self.dirty_min_x = @min(self.dirty_min_x, x);
        self.dirty_max_x = @max(self.dirty_max_x, x);
        self.dirty_min_z = @min(self.dirty_min_z, z);
        self.dirty_max_z = @max(self.dirty_max_z, z);
    }

    pub fn markDirtyAll(self: *Heightfield) void {
        const n = vertCount(self.resolution);
        self.dirty_min_x = 0;
        self.dirty_min_z = 0;
        self.dirty_max_x = n - 1;
        self.dirty_max_z = n - 1;
        self.dirty_valid = true;
    }

    pub fn clearDirty(self: *Heightfield) void {
        self.dirty_valid = false;
    }

    pub fn sampleSpacing(self: *const Heightfield) f32 {
        return self.world_size / @as(f32, @floatFromInt(self.resolution));
    }

    /// Bilinear sample at world XZ.
    pub fn sampleWorld(self: *const Heightfield, world_x: f32, world_z: f32) f32 {
        const sp = self.sampleSpacing();
        const u = (world_x - self.origin_x) / sp;
        const v = (world_z - self.origin_z) / sp;
        const n = @as(f32, @floatFromInt(vertCount(self.resolution) - 1));
        const x = std.math.clamp(u, 0, n);
        const z = std.math.clamp(v, 0, n);
        const x0: u32 = @intFromFloat(@floor(x));
        const z0: u32 = @intFromFloat(@floor(z));
        const x1 = @min(x0 + 1, self.resolution);
        const z1 = @min(z0 + 1, self.resolution);
        const fx = x - @as(f32, @floatFromInt(x0));
        const fz = z - @as(f32, @floatFromInt(z0));
        const h00 = self.get(x0, z0);
        const h10 = self.get(x1, z0);
        const h01 = self.get(x0, z1);
        const h11 = self.get(x1, z1);
        const hx0 = h00 + (h10 - h00) * fx;
        const hx1 = h01 + (h11 - h01) * fx;
        return hx0 + (hx1 - hx0) * fz;
    }

    /// Diamond 5-point sample (Dagor hml diamond) — bilinear corners + center average.
    pub fn sampleWorldDiamond(self: *const Heightfield, world_x: f32, world_z: f32) f32 {
        const sp = self.sampleSpacing();
        const half = sp * 0.5;
        const c = self.sampleWorld(world_x, world_z);
        const n = self.sampleWorld(world_x, world_z - half);
        const s = self.sampleWorld(world_x, world_z + half);
        const e = self.sampleWorld(world_x + half, world_z);
        const w = self.sampleWorld(world_x - half, world_z);
        return (c * 2.0 + n + s + e + w) * (1.0 / 6.0);
    }

    pub fn minMax(self: *const Heightfield) HeightRange {
        var mn: f32 = std.math.floatMax(f32);
        var mx: f32 = -std.math.floatMax(f32);
        for (self.heights) |h| {
            mn = @min(mn, h);
            mx = @max(mx, h);
        }
        return .{ .min = mn, .max = mx };
    }

    /// Hierarchical AABB query for a world XZ rect (uses compressed range blocks when present).
    pub fn rangeMinMax(self: *const Heightfield, min_x: f32, min_z: f32, max_x: f32, max_z: f32) HeightRange {
        if (self.compressed) |c| {
            return c.rangeWorld(self, min_x, min_z, max_x, max_z);
        }
        // Fallback: sample corners + center.
        var mn = self.sampleWorld(min_x, min_z);
        var mx = mn;
        const pts = [_][2]f32{
            .{ max_x, min_z }, .{ min_x, max_z }, .{ max_x, max_z },
            .{ (min_x + max_x) * 0.5, (min_z + max_z) * 0.5 },
        };
        for (pts) |p| {
            const h = self.sampleWorld(p[0], p[1]);
            mn = @min(mn, h);
            mx = @max(mx, h);
        }
        return .{ .min = mn, .max = mx };
    }

    /// Ray vs heightfield. Returns hit world Y or null.
    pub fn traceRay(
        self: *const Heightfield,
        ox: f32,
        oy: f32,
        oz: f32,
        dx: f32,
        dy: f32,
        dz: f32,
        max_t: f32,
    ) ?f32 {
        if (self.traceRayHit(ox, oy, oz, dx, dy, dz, max_t)) |h| return h[1];
        return null;
    }

    /// Ray vs heightfield. Returns world XYZ hit or null (for mouse pick).
    pub fn traceRayHit(
        self: *const Heightfield,
        ox: f32,
        oy: f32,
        oz: f32,
        dx: f32,
        dy: f32,
        dz: f32,
        max_t: f32,
    ) ?[3]f32 {
        const steps: u32 = 96;
        var t: f32 = 0;
        const dt = max_t / @as(f32, @floatFromInt(steps));
        var prev_above = true;
        var i: u32 = 0;
        while (i <= steps) : (i += 1) {
            const x = ox + dx * t;
            const y = oy + dy * t;
            const z = oz + dz * t;
            const ground = self.sampleWorld(x, z);
            const above = y >= ground;
            if (i > 0 and prev_above and !above) {
                const t0 = t - dt;
                const y0 = oy + dy * t0;
                const x0 = ox + dx * t0;
                const z0 = oz + dz * t0;
                const g0 = self.sampleWorld(x0, z0);
                const denom = (y - ground) - (y0 - g0);
                const th = if (@abs(denom) < 1e-8) t0 else t0 + ((0 - (y0 - g0)) / denom) * dt;
                const hx = ox + dx * th;
                const hz = oz + dz * th;
                const hy = self.sampleWorld(hx, hz);
                return .{ hx, hy, hz };
            }
            prev_above = above;
            t += dt;
        }
        return null;
    }

    pub fn rebuildCompressed(self: *Heightfield) !void {
        if (self.compressed) |*c| c.deinit(self.allocator);
        self.compressed = try Compressed.build(self.allocator, self);
        self.clearDirty();
    }

    /// Update compressed blocks covering the dirty rect (Dagor updateHier role). Full rebuild if none.
    pub fn rebuildCompressedDirty(self: *Heightfield) !void {
        if (self.compressed == null or !self.dirty_valid) {
            try self.rebuildCompressed();
            return;
        }
        self.compressed.?.updateDirty(self) catch {
            try self.rebuildCompressed();
            return;
        };
        self.clearDirty();
    }

    /// Export raw little-endian f32 heights.
    pub fn exportF32(self: *const Heightfield, allocator: std.mem.Allocator) ![]u8 {
        const bytes = try allocator.alloc(u8, self.heights.len * 4);
        for (self.heights, 0..) |h, i| {
            std.mem.writeInt(u32, bytes[i * 4 ..][0..4], @bitCast(h), .little);
        }
        return bytes;
    }

    pub fn importF32(self: *Heightfield, data: []const u8) !void {
        if (data.len != self.heights.len * 4) return error.SizeMismatch;
        for (self.heights, 0..) |*h, i| {
            const bits = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
            h.* = @bitCast(bits);
        }
        self.markDirtyAll();
        try self.rebuildCompressed();
    }

    pub fn exportR16(self: *const Heightfield, allocator: std.mem.Allocator, min_h: f32, max_h: f32) ![]u8 {
        const range = @max(max_h - min_h, 1e-6);
        const bytes = try allocator.alloc(u8, self.heights.len * 2);
        for (self.heights, 0..) |h, i| {
            const t = std.math.clamp((h - min_h) / range, 0, 1);
            const v: u16 = @intFromFloat(t * 65535.0);
            std.mem.writeInt(u16, bytes[i * 2 ..][0..2], v, .little);
        }
        return bytes;
    }

    pub fn importR16(self: *Heightfield, data: []const u8, min_h: f32, max_h: f32) !void {
        if (data.len != self.heights.len * 2) return error.SizeMismatch;
        const range = max_h - min_h;
        for (self.heights, 0..) |*h, i| {
            const v = std.mem.readInt(u16, data[i * 2 ..][0..2], .little);
            h.* = min_h + (@as(f32, @floatFromInt(v)) / 65535.0) * range;
        }
        self.markDirtyAll();
        try self.rebuildCompressed();
    }

    /// Native container: magic "HMAP" + u32 res + f32 world_size + f32 origin_x/z + f32 heights.
    pub fn exportHmap(self: *const Heightfield, allocator: std.mem.Allocator) ![]u8 {
        const n = self.heights.len;
        var out = try allocator.alloc(u8, 4 + 4 + 4 + 8 + n * 4);
        @memcpy(out[0..4], "HMAP");
        std.mem.writeInt(u32, out[4..8], self.resolution, .little);
        std.mem.writeInt(u32, out[8..12], @bitCast(self.world_size), .little);
        std.mem.writeInt(u32, out[12..16], @bitCast(self.origin_x), .little);
        std.mem.writeInt(u32, out[16..20], @bitCast(self.origin_z), .little);
        for (self.heights, 0..) |h, i| {
            std.mem.writeInt(u32, out[20 + i * 4 ..][0..4], @bitCast(h), .little);
        }
        return out;
    }

    /// Raw block payload (no zstd) — used as CHMZ inner body / legacy CHMP.
    pub fn exportChmapRaw(self: *const Heightfield, allocator: std.mem.Allocator) ![]u8 {
        var owned: ?Compressed = null;
        defer if (owned) |*c| c.deinit(allocator);
        const c: Compressed = if (self.compressed) |existing|
            existing
        else blk: {
            owned = try Compressed.build(allocator, self);
            break :blk owned.?;
        };
        const mm = self.minMax();
        const header: usize = 4 + 4 + 4 + 8 + 8 + 4;
        const body = c.blocks.len * (@sizeOf(u16) * 2 + (1 << block_shift) * (1 << block_shift));
        var out = try allocator.alloc(u8, header + body);
        @memcpy(out[0..4], "CHMP");
        std.mem.writeInt(u32, out[4..8], self.resolution, .little);
        std.mem.writeInt(u32, out[8..12], @bitCast(self.world_size), .little);
        std.mem.writeInt(u32, out[12..16], @bitCast(self.origin_x), .little);
        std.mem.writeInt(u32, out[16..20], @bitCast(self.origin_z), .little);
        std.mem.writeInt(u32, out[20..24], @bitCast(mm.min), .little);
        std.mem.writeInt(u32, out[24..28], @bitCast(mm.max), .little);
        std.mem.writeInt(u32, out[28..32], block_shift, .little);
        var off: usize = 32;
        const bw: u32 = 1 << block_shift;
        for (c.blocks) |b| {
            std.mem.writeInt(u16, out[off..][0..2], b.mn, .little);
            off += 2;
            std.mem.writeInt(u16, out[off..][0..2], b.delta, .little);
            off += 2;
            @memcpy(out[off .. off + bw * bw], b.variance[0 .. bw * bw]);
            off += bw * bw;
        }
        return out;
    }

    /// CHMZ = header + u32 raw_size + zstd(CHMP body from byte 32). ~8× smaller than raw CHMP.
    pub fn exportChmap(self: *const Heightfield, allocator: std.mem.Allocator) ![]u8 {
        const raw = try self.exportChmapRaw(allocator);
        defer allocator.free(raw);
        const payload = raw[32..];
        const packed_body = try zbasis.zstdCompress(allocator, payload, 3);
        defer allocator.free(packed_body);
        var out = try allocator.alloc(u8, 36 + packed_body.len);
        @memcpy(out[0..4], "CHMZ");
        @memcpy(out[4..32], raw[4..32]);
        std.mem.writeInt(u32, out[32..36], @intCast(payload.len), .little);
        @memcpy(out[36..], packed_body);
        return out;
    }

    pub fn importHmap(allocator: std.mem.Allocator, data: []const u8) !Heightfield {
        if (data.len < 20) return error.InvalidHmap;
        if (!std.mem.eql(u8, data[0..4], "HMAP")) return error.InvalidHmap;
        const resolution = std.mem.readInt(u32, data[4..8], .little);
        const world_size: f32 = @bitCast(std.mem.readInt(u32, data[8..12], .little));
        var hf = try init(allocator, resolution, world_size);
        errdefer hf.deinit();
        hf.origin_x = @bitCast(std.mem.readInt(u32, data[12..16], .little));
        hf.origin_z = @bitCast(std.mem.readInt(u32, data[16..20], .little));
        try hf.importF32(data[20..]);
        return hf;
    }

    fn decodeBlockIntoHeights(
        heights: []f32,
        n: u32,
        bx: u32,
        bz: u32,
        bw: u32,
        mn: u16,
        delta: u16,
        var_slice: []const u8,
        min_h: f32,
        range: f32,
    ) void {
        var lz: u32 = 0;
        while (lz < bw) : (lz += 1) {
            var lx: u32 = 0;
            while (lx + 4 <= bw) : (lx += 4) {
                const hs = Compressed.Block.decode4Raw(mn, delta, var_slice[lz * bw + lx ..][0..4], min_h, range);
                inline for (0..4) |i| {
                    const x = bx * bw + lx + @as(u32, @intCast(i));
                    const z = bz * bw + lz;
                    if (x < n and z < n) heights[z * n + x] = hs[i];
                }
            }
            while (lx < bw) : (lx += 1) {
                const x = bx * bw + lx;
                const z = bz * bw + lz;
                if (x >= n or z >= n) continue;
                heights[z * n + x] = Compressed.Block.decode1(mn, delta, var_slice[lz * bw + lx], min_h, range);
            }
        }
    }

    fn importChmapBody(allocator: std.mem.Allocator, header: []const u8, body: []const u8) !Heightfield {
        if (header.len < 32) return error.InvalidChmap;
        const resolution = std.mem.readInt(u32, header[4..8], .little);
        const world_size: f32 = @bitCast(std.mem.readInt(u32, header[8..12], .little));
        var hf = try init(allocator, resolution, world_size);
        errdefer hf.deinit();
        hf.origin_x = @bitCast(std.mem.readInt(u32, header[12..16], .little));
        hf.origin_z = @bitCast(std.mem.readInt(u32, header[16..20], .little));
        const min_h: f32 = @bitCast(std.mem.readInt(u32, header[20..24], .little));
        const max_h: f32 = @bitCast(std.mem.readInt(u32, header[24..28], .little));
        const bshift = std.mem.readInt(u32, header[28..32], .little);
        if (bshift != block_shift) return error.InvalidChmap;
        const bw: u32 = 1 << block_shift;
        const n = vertCount(resolution);
        const blocks_x = (n + bw - 1) / bw;
        const blocks_z = (n + bw - 1) / bw;
        const block_bytes: usize = 4 + bw * bw;
        if (body.len < blocks_x * blocks_z * block_bytes) return error.InvalidChmap;
        const range = @max(max_h - min_h, 1e-6);

        // Parallel row unpack (Dagor UnpackChunkJob role).
        const Worker = struct {
            heights: []f32,
            body: []const u8,
            n: u32,
            bw: u32,
            blocks_x: u32,
            bz0: u32,
            bz1: u32,
            min_h: f32,
            range: f32,
            block_bytes: usize,

            fn run(self: *@This()) void {
                var bz = self.bz0;
                while (bz < self.bz1) : (bz += 1) {
                    var bx: u32 = 0;
                    while (bx < self.blocks_x) : (bx += 1) {
                        const off = (@as(usize, bz) * self.blocks_x + bx) * self.block_bytes;
                        const mn = std.mem.readInt(u16, self.body[off..][0..2], .little);
                        const delta = std.mem.readInt(u16, self.body[off + 2 ..][0..2], .little);
                        const var_slice = self.body[off + 4 .. off + 4 + self.bw * self.bw];
                        Heightfield.decodeBlockIntoHeights(
                            self.heights,
                            self.n,
                            bx,
                            bz,
                            self.bw,
                            mn,
                            delta,
                            var_slice,
                            self.min_h,
                            self.range,
                        );
                    }
                }
            }
        };

        const cpu = std.Thread.getCpuCount() catch 2;
        const nworkers: u32 = @intCast(@max(@min(cpu, blocks_z), 1));
        if (nworkers <= 1 or blocks_z < 2) {
            var w = Worker{
                .heights = hf.heights,
                .body = body,
                .n = n,
                .bw = bw,
                .blocks_x = blocks_x,
                .bz0 = 0,
                .bz1 = blocks_z,
                .min_h = min_h,
                .range = range,
                .block_bytes = block_bytes,
            };
            w.run();
        } else {
            const rows_per = (blocks_z + nworkers - 1) / nworkers;
            var threads = try allocator.alloc(std.Thread, nworkers);
            defer allocator.free(threads);
            var workers = try allocator.alloc(Worker, nworkers);
            defer allocator.free(workers);
            var t: u32 = 0;
            while (t < nworkers) : (t += 1) {
                const z0 = t * rows_per;
                const z1 = @min(z0 + rows_per, blocks_z);
                workers[t] = .{
                    .heights = hf.heights,
                    .body = body,
                    .n = n,
                    .bw = bw,
                    .blocks_x = blocks_x,
                    .bz0 = z0,
                    .bz1 = z1,
                    .min_h = min_h,
                    .range = range,
                    .block_bytes = block_bytes,
                };
                threads[t] = try std.Thread.spawn(.{}, Worker.run, .{&workers[t]});
            }
            for (threads) |th| th.join();
        }

        hf.markDirtyAll();
        try hf.rebuildCompressed();
        return hf;
    }

    pub fn importChmap(allocator: std.mem.Allocator, data: []const u8) !Heightfield {
        if (data.len < 32) return error.InvalidChmap;
        if (std.mem.eql(u8, data[0..4], "CHMZ")) {
            if (data.len < 36) return error.InvalidChmap;
            const raw_size = std.mem.readInt(u32, data[32..36], .little);
            const dec = try zbasis.zstdDecompress(allocator, data[36..], raw_size);
            defer allocator.free(dec);
            if (dec.len != raw_size) return error.InvalidChmap;
            return try importChmapBody(allocator, data[0..32], dec);
        }
        if (!std.mem.eql(u8, data[0..4], "CHMP")) return error.InvalidChmap;
        return try importChmapBody(allocator, data[0..32], data[32..]);
    }

    pub fn writeFile(self: *const Heightfield, path: []const u8) !void {
        const bytes = try self.exportHmap(self.allocator);
        defer self.allocator.free(bytes);
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes });
    }

    pub fn writeCompressedFile(self: *const Heightfield, path: []const u8) !void {
        const bytes = try self.exportChmap(self.allocator);
        defer self.allocator.free(bytes);
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes });
    }

    pub fn readFile(allocator: std.mem.Allocator, path: []const u8) !Heightfield {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
        defer allocator.free(bytes);
        if (bytes.len >= 4 and (std.mem.eql(u8, bytes[0..4], "CHMP") or std.mem.eql(u8, bytes[0..4], "CHMZ")))
            return try importChmap(allocator, bytes);
        return try importHmap(allocator, bytes);
    }
};

/// Block-compressed heightmap + multi-level range quadtree (Dagor CompressedHeightmap).
pub const Compressed = struct {
    blocks_x: u32,
    blocks_z: u32,
    global_min: f32,
    global_max: f32,
    blocks: []Block,
    /// levels[0] = coarsest (≈1×1), levels[last] = 2×2 over blocks. Block level is implicit.
    levels: []HierLevel,
    allocator: std.mem.Allocator,

    pub const HierLevel = struct {
        w: u32,
        h: u32,
        mn: []f32,
        mx: []f32,
    };

    pub const Block = struct {
        mn: u16,
        delta: u16,
        variance: [64]u8, // 8×8

        pub fn decode1(mn: u16, delta: u16, v: u8, gmin: f32, range: f32) f32 {
            const u16h = if (delta == 0) mn else mn + @as(u16, @intCast((@as(u32, v) * delta + 127) / 255));
            return gmin + (@as(f32, @floatFromInt(u16h)) / 65535.0) * range;
        }

        /// SIMD-ish decode of 4 variance samples (Dagor decodeInsideBlock4HeightsRaw).
        pub fn decode4Raw(mn: u16, delta: u16, v4: *const [4]u8, gmin: f32, range: f32) @Vector(4, f32) {
            const vv: @Vector(4, f32) = .{
                @floatFromInt(v4[0]),
                @floatFromInt(v4[1]),
                @floatFromInt(v4[2]),
                @floatFromInt(v4[3]),
            };
            const mn_f: @Vector(4, f32) = @splat(@as(f32, @floatFromInt(mn)));
            const delta_f: @Vector(4, f32) = @splat(@as(f32, @floatFromInt(delta)));
            const scale: @Vector(4, f32) = @splat(range / 65535.0);
            const gmin_v: @Vector(4, f32) = @splat(gmin);
            if (delta == 0) return gmin_v + mn_f * scale;
            const u16h = mn_f + (vv * delta_f + @as(@Vector(4, f32), @splat(127.0))) * @as(@Vector(4, f32), @splat(1.0 / 255.0));
            return gmin_v + u16h * scale;
        }

        pub fn decode4(self: *const Block, lx: u32, lz: u32, gmin: f32, gmax: f32) @Vector(4, f32) {
            const range = @max(gmax - gmin, 1e-6);
            const base = lz * 8 + lx;
            const v4 = self.variance[base..][0..4];
            return decode4Raw(self.mn, self.delta, v4, gmin, range);
        }

        pub fn rangeMeters(self: *const Block, gmin: f32, gmax: f32) HeightRange {
            const range = @max(gmax - gmin, 1e-6);
            return .{
                .min = gmin + (@as(f32, @floatFromInt(self.mn)) / 65535.0) * range,
                .max = gmin + (@as(f32, @floatFromInt(self.mn +% self.delta)) / 65535.0) * range,
            };
        }
    };

    pub fn deinit(self: *Compressed, allocator: std.mem.Allocator) void {
        allocator.free(self.blocks);
        self.freeLevels(allocator);
        self.* = undefined;
    }

    pub fn build(allocator: std.mem.Allocator, hf: *const Heightfield) !Compressed {
        const n = Heightfield.vertCount(hf.resolution);
        const bw: u32 = 1 << Heightfield.block_shift;
        const blocks_x = (n + bw - 1) / bw;
        const blocks_z = (n + bw - 1) / bw;
        const mm = hf.minMax();
        const blocks = try allocator.alloc(Block, blocks_x * blocks_z);
        errdefer allocator.free(blocks);

        // Parallel block encode (pairs with UnpackChunkJob on load).
        const EncWorker = struct {
            hf: *const Heightfield,
            blocks: []Block,
            blocks_x: u32,
            bz0: u32,
            bz1: u32,
            mm: HeightRange,
            fn run(self: *@This()) void {
                var bz = self.bz0;
                while (bz < self.bz1) : (bz += 1) {
                    var bx: u32 = 0;
                    while (bx < self.blocks_x) : (bx += 1) {
                        self.blocks[bz * self.blocks_x + bx] = encodeBlock(self.hf, bx, bz, self.mm);
                    }
                }
            }
        };
        const cpu = std.Thread.getCpuCount() catch 2;
        const nworkers: u32 = @intCast(@max(@min(cpu, blocks_z), 1));
        if (nworkers <= 1 or blocks_z < 2) {
            var w = EncWorker{ .hf = hf, .blocks = blocks, .blocks_x = blocks_x, .bz0 = 0, .bz1 = blocks_z, .mm = mm };
            w.run();
        } else {
            const rows_per = (blocks_z + nworkers - 1) / nworkers;
            var threads = try allocator.alloc(std.Thread, nworkers);
            defer allocator.free(threads);
            var workers = try allocator.alloc(EncWorker, nworkers);
            defer allocator.free(workers);
            var t: u32 = 0;
            while (t < nworkers) : (t += 1) {
                const z0 = t * rows_per;
                const z1 = @min(z0 + rows_per, blocks_z);
                workers[t] = .{ .hf = hf, .blocks = blocks, .blocks_x = blocks_x, .bz0 = z0, .bz1 = z1, .mm = mm };
                threads[t] = try std.Thread.spawn(.{}, EncWorker.run, .{&workers[t]});
            }
            for (threads) |th| th.join();
        }

        var self_c: Compressed = .{
            .blocks_x = blocks_x,
            .blocks_z = blocks_z,
            .global_min = mm.min,
            .global_max = mm.max,
            .blocks = blocks,
            .levels = &.{},
            .allocator = allocator,
        };
        try self_c.buildLevels(allocator);
        return self_c;
    }

    fn encodeBlock(hf: *const Heightfield, bx: u32, bz: u32, mm: HeightRange) Block {
        const n = Heightfield.vertCount(hf.resolution);
        const bw: u32 = 1 << Heightfield.block_shift;
        const range = @max(mm.max - mm.min, 1e-6);
        var bmin: f32 = std.math.floatMax(f32);
        var bmax: f32 = -std.math.floatMax(f32);
        var lz: u32 = 0;
        while (lz < bw) : (lz += 1) {
            var lx: u32 = 0;
            while (lx < bw) : (lx += 1) {
                const x = @min(bx * bw + lx, n - 1);
                const z = @min(bz * bw + lz, n - 1);
                const h = hf.get(x, z);
                bmin = @min(bmin, h);
                bmax = @max(bmax, h);
            }
        }
        const mn_u: u16 = @intFromFloat(std.math.clamp((bmin - mm.min) / range, 0, 1) * 65535.0);
        const mx_u: u16 = @intFromFloat(std.math.clamp((bmax - mm.min) / range, 0, 1) * 65535.0);
        const delta: u16 = mx_u -% mn_u;
        var variance: [64]u8 = .{0} ** 64;
        lz = 0;
        while (lz < bw) : (lz += 1) {
            var lx: u32 = 0;
            while (lx < bw) : (lx += 1) {
                const x = @min(bx * bw + lx, n - 1);
                const z = @min(bz * bw + lz, n - 1);
                const h = hf.get(x, z);
                const hu: u16 = @intFromFloat(std.math.clamp((h - mm.min) / range, 0, 1) * 65535.0);
                const v: u8 = if (delta == 0) 0 else @intCast((@as(u32, hu -% mn_u) * 255 + (delta >> 1)) / delta);
                variance[lz * bw + lx] = v;
            }
        }
        return .{ .mn = mn_u, .delta = delta, .variance = variance };
    }

    fn freeLevels(self: *Compressed, allocator: std.mem.Allocator) void {
        if (self.levels.len == 0) return;
        for (self.levels) |*lev| {
            allocator.free(lev.mn);
            allocator.free(lev.mx);
        }
        allocator.free(self.levels);
        self.levels = &.{};
    }

    fn buildLevels(self: *Compressed, allocator: std.mem.Allocator) !void {
        self.freeLevels(allocator);
        // Finest hier level: 2×2 over blocks, then pyramid to 1×1 (Dagor htRangeBlocksLevels).
        var owned: std.ArrayList(HierLevel) = .{};
        errdefer {
            for (owned.items) |*lev| {
                allocator.free(lev.mn);
                allocator.free(lev.mx);
            }
            owned.deinit(allocator);
        }

        var cur_w = self.blocks_x;
        var cur_h = self.blocks_z;
        {
            const cur_mn = try allocator.alloc(f32, cur_w * cur_h);
            errdefer allocator.free(cur_mn);
            const cur_mx = try allocator.alloc(f32, cur_w * cur_h);
            errdefer allocator.free(cur_mx);
            var bz: u32 = 0;
            while (bz < self.blocks_z) : (bz += 1) {
                var bx: u32 = 0;
                while (bx < self.blocks_x) : (bx += 1) {
                    const rr = self.blocks[bz * self.blocks_x + bx].rangeMeters(self.global_min, self.global_max);
                    cur_mn[bz * cur_w + bx] = rr.min;
                    cur_mx[bz * cur_w + bx] = rr.max;
                }
            }
            try owned.append(allocator, .{ .w = cur_w, .h = cur_h, .mn = cur_mn, .mx = cur_mx });
        }

        while (cur_w > 1 or cur_h > 1) {
            const next_w = @max((cur_w + 1) / 2, 1);
            const next_h = @max((cur_h + 1) / 2, 1);
            const prev = owned.items[owned.items.len - 1];
            const next_mn = try allocator.alloc(f32, next_w * next_h);
            const next_mx = allocator.alloc(f32, next_w * next_h) catch |err| {
                allocator.free(next_mn);
                return err;
            };
            @memset(next_mn, std.math.floatMax(f32));
            @memset(next_mx, -std.math.floatMax(f32));
            var bz: u32 = 0;
            while (bz < cur_h) : (bz += 1) {
                var bx: u32 = 0;
                while (bx < cur_w) : (bx += 1) {
                    const i = bz * cur_w + bx;
                    const hi = (bz / 2) * next_w + (bx / 2);
                    next_mn[hi] = @min(next_mn[hi], prev.mn[i]);
                    next_mx[hi] = @max(next_mx[hi], prev.mx[i]);
                }
            }
            owned.append(allocator, .{ .w = next_w, .h = next_h, .mn = next_mn, .mx = next_mx }) catch |err| {
                allocator.free(next_mn);
                allocator.free(next_mx);
                return err;
            };
            cur_w = next_w;
            cur_h = next_h;
        }

        const items = try owned.toOwnedSlice(allocator);
        // Reverse: levels[0] = coarsest root.
        var i: usize = 0;
        while (i < items.len / 2) : (i += 1) {
            const tmp = items[i];
            items[i] = items[items.len - 1 - i];
            items[items.len - 1 - i] = tmp;
        }
        self.levels = items;
    }

    fn rebuildHierarchy(self: *Compressed) void {
        self.buildLevels(self.allocator) catch {};
    }

    /// Expand/shrink hierarchy for a block rect only (Dagor recomputeHierHeightRangeBlocksForRect).
    pub fn recomputeHierForBlockRect(self: *Compressed, bx0: u32, bz0: u32, bx1: u32, bz1: u32) void {
        if (self.levels.len == 0) return;
        const fine_i = self.levels.len - 1;
        const fine = &self.levels[fine_i];
        var bz = bz0;
        while (bz <= bz1) : (bz += 1) {
            var bx = bx0;
            while (bx <= bx1) : (bx += 1) {
                if (bx >= fine.w or bz >= fine.h) continue;
                const rr = self.blocks[bz * self.blocks_x + bx].rangeMeters(self.global_min, self.global_max);
                const i = bz * fine.w + bx;
                fine.mn[i] = rr.min;
                fine.mx[i] = rr.max;
            }
        }
        var child_x0 = bx0;
        var child_z0 = bz0;
        var child_x1 = bx1;
        var child_z1 = bz1;
        var lev: usize = fine_i;
        while (lev > 0) {
            const child = self.levels[lev];
            const parent = &self.levels[lev - 1];
            const px0 = child_x0 / 2;
            const pz0 = child_z0 / 2;
            const px1 = @min(child_x1 / 2, parent.w - 1);
            const pz1 = @min(child_z1 / 2, parent.h - 1);
            var pz = pz0;
            while (pz <= pz1) : (pz += 1) {
                var px = px0;
                while (px <= px1) : (px += 1) {
                    var mn: f32 = std.math.floatMax(f32);
                    var mx: f32 = -std.math.floatMax(f32);
                    var dz: u32 = 0;
                    while (dz < 2) : (dz += 1) {
                        var dx: u32 = 0;
                        while (dx < 2) : (dx += 1) {
                            const sx = px * 2 + dx;
                            const sz = pz * 2 + dz;
                            if (sx >= child.w or sz >= child.h) continue;
                            const ci = sz * child.w + sx;
                            mn = @min(mn, child.mn[ci]);
                            mx = @max(mx, child.mx[ci]);
                        }
                    }
                    parent.mn[pz * parent.w + px] = mn;
                    parent.mx[pz * parent.w + px] = mx;
                }
            }
            child_x0 = px0;
            child_z0 = pz0;
            child_x1 = px1;
            child_z1 = pz1;
            lev -= 1;
        }
    }

    /// Point expand-only update (Dagor updateHierHeightRangeBlocksForPoint).
    pub fn updateHierForPoint(self: *Compressed, sample_x: u32, sample_z: u32, height: f32) void {
        if (self.levels.len == 0) return;
        const bw: u32 = 1 << Heightfield.block_shift;
        const bx = sample_x / bw;
        const bz = sample_z / bw;
        if (bx >= self.blocks_x or bz >= self.blocks_z) return;
        var lev_i: i32 = @intCast(self.levels.len - 1);
        var cx = bx;
        var cz = bz;
        while (lev_i >= 0) : (lev_i -= 1) {
            const lev = &self.levels[@intCast(lev_i)];
            if (cx >= lev.w or cz >= lev.h) break;
            const i = cz * lev.w + cx;
            lev.mn[i] = @min(lev.mn[i], height);
            lev.mx[i] = @max(lev.mx[i], height);
            cx /= 2;
            cz /= 2;
        }
    }

    /// Re-encode blocks covering the heightfield dirty rect; incremental hierarchy refresh.
    pub fn updateDirty(self: *Compressed, hf: *const Heightfield) !void {
        const mm = hf.minMax();
        if (mm.min < self.global_min - 1e-3 or mm.max > self.global_max + 1e-3) {
            return error.RangeExpanded;
        }
        const bw: u32 = 1 << Heightfield.block_shift;
        const bx0 = hf.dirty_min_x / bw;
        const bz0 = hf.dirty_min_z / bw;
        const bx1 = @min(hf.dirty_max_x / bw, self.blocks_x - 1);
        const bz1 = @min(hf.dirty_max_z / bw, self.blocks_z - 1);
        const gmm: HeightRange = .{ .min = self.global_min, .max = self.global_max };
        var bz = bz0;
        while (bz <= bz1) : (bz += 1) {
            var bx = bx0;
            while (bx <= bx1) : (bx += 1) {
                self.blocks[bz * self.blocks_x + bx] = encodeBlock(hf, bx, bz, gmm);
            }
        }
        self.recomputeHierForBlockRect(bx0, bz0, bx1, bz1);
    }

    fn rangeWorld(
        self: *const Compressed,
        hf: *const Heightfield,
        min_x: f32,
        min_z: f32,
        max_x: f32,
        max_z: f32,
    ) HeightRange {
        const sp = hf.sampleSpacing();
        const n = @as(f32, @floatFromInt(Heightfield.vertCount(hf.resolution) - 1));
        const su0 = std.math.clamp((min_x - hf.origin_x) / sp, 0, n);
        const sv0 = std.math.clamp((min_z - hf.origin_z) / sp, 0, n);
        const su1 = std.math.clamp((max_x - hf.origin_x) / sp, 0, n);
        const sv1 = std.math.clamp((max_z - hf.origin_z) / sp, 0, n);
        const bw: f32 = @floatFromInt(@as(u32, 1) << Heightfield.block_shift);
        const bx0: u32 = @intFromFloat(@floor(su0 / bw));
        const bz0: u32 = @intFromFloat(@floor(sv0 / bw));
        const bx1: u32 = @min(@as(u32, @intFromFloat(@floor(su1 / bw))), self.blocks_x - 1);
        const bz1: u32 = @min(@as(u32, @intFromFloat(@floor(sv1 / bw))), self.blocks_z - 1);

        if (self.levels.len == 0) {
            return self.rangeBlocks(bx0, bz0, bx1, bz1);
        }

        var mn: f32 = std.math.floatMax(f32);
        var mx: f32 = -std.math.floatMax(f32);
        self.queryLevel(0, 0, 0, bx0, bz0, bx1, bz1, &mn, &mx);
        if (mn > mx) return .{ .min = self.global_min, .max = self.global_max };
        return .{ .min = mn, .max = mx };
    }

    fn rangeBlocks(self: *const Compressed, bx0: u32, bz0: u32, bx1: u32, bz1: u32) HeightRange {
        var mn: f32 = std.math.floatMax(f32);
        var mx: f32 = -std.math.floatMax(f32);
        var bz = bz0;
        while (bz <= bz1) : (bz += 1) {
            var bx = bx0;
            while (bx <= bx1) : (bx += 1) {
                const rr = self.blocks[bz * self.blocks_x + bx].rangeMeters(self.global_min, self.global_max);
                mn = @min(mn, rr.min);
                mx = @max(mx, rr.max);
            }
        }
        if (mn > mx) return .{ .min = self.global_min, .max = self.global_max };
        return .{ .min = mn, .max = mx };
    }

    /// Quadtree descent O(log N + k) (Dagor hier height-range role).
    fn queryLevel(
        self: *const Compressed,
        level: usize,
        cx: u32,
        cz: u32,
        qbx0: u32,
        qbz0: u32,
        qbx1: u32,
        qbz1: u32,
        mn: *f32,
        mx: *f32,
    ) void {
        const lev = self.levels[level];
        if (cx >= lev.w or cz >= lev.h) return;
        // Map this cell to block coverage. Finest level matches blocks 1:1.
        const fine = self.levels[self.levels.len - 1];
        const span_x = @max(fine.w / lev.w, 1);
        const span_z = @max(fine.h / lev.h, 1);
        const b0x = cx * span_x;
        const b0z = cz * span_z;
        const b1x = @min(b0x + span_x - 1, self.blocks_x - 1);
        const b1z = @min(b0z + span_z - 1, self.blocks_z - 1);
        if (b1x < qbx0 or b0x > qbx1 or b1z < qbz0 or b0z > qbz1) return;

        const fully = b0x >= qbx0 and b1x <= qbx1 and b0z >= qbz0 and b1z <= qbz1;
        if (fully or level + 1 >= self.levels.len) {
            const i = cz * lev.w + cx;
            mn.* = @min(mn.*, lev.mn[i]);
            mx.* = @max(mx.*, lev.mx[i]);
            return;
        }
        // Descend 2×2 children.
        self.queryLevel(level + 1, cx * 2, cz * 2, qbx0, qbz0, qbx1, qbz1, mn, mx);
        self.queryLevel(level + 1, cx * 2 + 1, cz * 2, qbx0, qbz0, qbx1, qbz1, mn, mx);
        self.queryLevel(level + 1, cx * 2, cz * 2 + 1, qbx0, qbz0, qbx1, qbz1, mn, mx);
        self.queryLevel(level + 1, cx * 2 + 1, cz * 2 + 1, qbx0, qbz0, qbx1, qbz1, mn, mx);
    }
};

test "heightfield sample and hmap roundtrip" {
    const allocator = std.testing.allocator;
    var hf = try Heightfield.init(allocator, 4, 16);
    defer hf.deinit();
    hf.set(0, 0, 1);
    hf.set(4, 4, 5);
    const mid = hf.sampleWorld(8, 8);
    try std.testing.expect(mid >= 0);

    const bytes = try hf.exportHmap(allocator);
    defer allocator.free(bytes);
    var hf2 = try Heightfield.importHmap(allocator, bytes);
    defer hf2.deinit();
    try std.testing.expectEqual(@as(f32, 1), hf2.get(0, 0));
    try std.testing.expectEqual(@as(f32, 5), hf2.get(4, 4));
}

test "chmap roundtrip and hierarchy" {
    const allocator = std.testing.allocator;
    var hf = try Heightfield.init(allocator, 16, 64);
    defer hf.deinit();
    var z: u32 = 0;
    while (z <= 16) : (z += 1) {
        var x: u32 = 0;
        while (x <= 16) : (x += 1) {
            hf.set(x, z, @as(f32, @floatFromInt(x + z)) * 0.25);
        }
    }
    try hf.rebuildCompressed();
    try std.testing.expect(hf.compressed.?.levels.len >= 2);
    const raw = try hf.exportChmapRaw(allocator);
    defer allocator.free(raw);
    const bytes = try hf.exportChmap(allocator);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.eql(u8, bytes[0..4], "CHMZ"));
    try std.testing.expect(bytes.len < raw.len); // zstd second stage smaller
    var hf2 = try Heightfield.importChmap(allocator, bytes);
    defer hf2.deinit();
    try std.testing.expectApproxEqAbs(hf.get(8, 8), hf2.get(8, 8), 0.5);
    const rr = hf.rangeMinMax(0, 0, 32, 32);
    try std.testing.expect(rr.max >= rr.min);
}

test "simd decode4 matches scalar" {
    var b = Compressed.Block{ .mn = 1000, .delta = 2000, .variance = .{0} ** 64 };
    b.variance[0] = 64;
    b.variance[1] = 128;
    b.variance[2] = 192;
    b.variance[3] = 255;
    const hs = b.decode4(0, 0, 0, 100);
    inline for (0..4) |i| {
        const s = Compressed.Block.decode1(b.mn, b.delta, b.variance[i], 0, 100);
        try std.testing.expectApproxEqAbs(s, hs[i], 0.01);
    }
}

test "incremental hier update matches full rebuild range" {
    const allocator = std.testing.allocator;
    var hf = try Heightfield.init(allocator, 32, 128);
    defer hf.deinit();
    var z: u32 = 0;
    while (z <= 32) : (z += 1) {
        var x: u32 = 0;
        while (x <= 32) : (x += 1) {
            hf.set(x, z, @as(f32, @floatFromInt(x + z)) * 0.1);
        }
    }
    try hf.rebuildCompressed();
    const before = hf.rangeMinMax(0, 0, 64, 64);
    hf.set(16, 16, 50);
    try hf.rebuildCompressedDirty();
    const after = hf.rangeMinMax(0, 0, 64, 64);
    try std.testing.expect(after.max >= before.max);
    try std.testing.expect(after.max >= 49);
}

test "traceRay hits ground" {
    const allocator = std.testing.allocator;
    var hf = try Heightfield.init(allocator, 8, 32);
    defer hf.deinit();
    // Flat at y=5
    @memset(hf.heights, 5);
    const hit = hf.traceRay(16, 20, 16, 0, -1, 0, 40);
    try std.testing.expect(hit != null);
    try std.testing.expectApproxEqAbs(@as(f32, 5), hit.?, 0.5);
}

test "r16 roundtrip" {
    const allocator = std.testing.allocator;
    var hf = try Heightfield.init(allocator, 2, 8);
    defer hf.deinit();
    hf.set(0, 0, -10);
    hf.set(2, 2, 10);
    const raw = try hf.exportR16(allocator, -10, 10);
    defer allocator.free(raw);
    var hf2 = try Heightfield.init(allocator, 2, 8);
    defer hf2.deinit();
    try hf2.importR16(raw, -10, 10);
    try std.testing.expectApproxEqAbs(@as(f32, -10), hf2.get(0, 0), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 10), hf2.get(2, 2), 0.01);
}

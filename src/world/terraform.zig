const std = @import("std");
const Heightfield = @import("heightfield.zig").Heightfield;

/// Terraform patch system (Dagor Terraform role): 256² patches @ 4 cells/m (0.25 m/cell).
pub const cells_per_meter: f32 = 4.0;
pub const patch_cells: u32 = 256;
pub const cell_meters: f32 = 1.0 / cells_per_meter;
pub const alt_scale: f32 = 0.05;
pub const zero_alt: u8 = 128;
pub const max_level_m: f32 = 6.0;
pub const default_spread_radius: i32 = 4;

pub const PrimMode = enum {
    replace,
    additive,
    min,
    max,
};

pub const PatchCoord = struct {
    x: i32,
    z: i32,

    pub fn eql(a: PatchCoord, b: PatchCoord) bool {
        return a.x == b.x and a.z == b.z;
    }

    pub fn fromWorld(wx: f32, wz: f32) PatchCoord {
        const cx = @floor(wx * cells_per_meter);
        const cz = @floor(wz * cells_per_meter);
        return .{
            .x = @divFloor(@as(i32, @intFromFloat(cx)), @as(i32, @intCast(patch_cells))),
            .z = @divFloor(@as(i32, @intFromFloat(cz)), @as(i32, @intCast(patch_cells))),
        };
    }

    pub fn originWorld(self: PatchCoord) struct { x: f32, z: f32 } {
        return .{
            .x = @as(f32, @floatFromInt(self.x)) * @as(f32, @floatFromInt(patch_cells)) * cell_meters,
            .z = @as(f32, @floatFromInt(self.z)) * @as(f32, @floatFromInt(patch_cells)) * cell_meters,
        };
    }
};

/// World-space quad (Dagor QuadData) — 4 XZ corners.
pub const QuadData = struct {
    verts: [4][2]f32,
    diff_alt: f32,
};

pub const Patch = struct {
    alt: []u8,
    generation: u32 = 1,
    dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Patch {
        const alt = try allocator.alloc(u8, patch_cells * patch_cells);
        @memset(alt, zero_alt);
        return .{ .alt = alt };
    }

    pub fn deinit(self: *Patch, allocator: std.mem.Allocator) void {
        allocator.free(self.alt);
        self.* = undefined;
    }

    pub fn get(self: *const Patch, lx: u32, lz: u32) u8 {
        return self.alt[lz * patch_cells + lx];
    }

    pub fn set(self: *Patch, lx: u32, lz: u32, v: u8) void {
        self.alt[lz * patch_cells + lx] = v;
        self.dirty = true;
        self.generation +%= 1;
    }

    pub fn deltaMeters(self: *const Patch, lx: u32, lz: u32) f32 {
        return (@as(f32, @floatFromInt(self.get(lx, lz))) - @as(f32, @floatFromInt(zero_alt))) * alt_scale;
    }
};

fn packKey(c: PatchCoord) u64 {
    return (@as(u64, @bitCast(@as(i64, c.x))) << 32) | @as(u64, @bitCast(@as(i64, c.z)));
}

fn pointInQuad(px: f32, pz: f32, q: QuadData) bool {
    // Barycentric-ish: sum of cross signs for edges (convex quad).
    var pos: i32 = 0;
    var neg: i32 = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const a = q.verts[i];
        const b = q.verts[(i + 1) % 4];
        const cross = (b[0] - a[0]) * (pz - a[1]) - (b[1] - a[1]) * (px - a[0]);
        if (cross > 0) pos += 1;
        if (cross < 0) neg += 1;
    }
    return !(pos > 0 and neg > 0);
}

pub const Terraform = struct {
    allocator: std.mem.Allocator,
    patches: std.AutoHashMap(u64, Patch),
    generation: u32 = 1,
    spread_radius: i32 = default_spread_radius,

    pub fn init(allocator: std.mem.Allocator) Terraform {
        return .{
            .allocator = allocator,
            .patches = std.AutoHashMap(u64, Patch).init(allocator),
        };
    }

    pub fn deinit(self: *Terraform) void {
        var it = self.patches.valueIterator();
        while (it.next()) |p| p.deinit(self.allocator);
        self.patches.deinit();
        self.* = undefined;
    }

    pub fn ensurePatch(self: *Terraform, coord: PatchCoord) !*Patch {
        const key = packKey(coord);
        const gop = try self.patches.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = try Patch.init(self.allocator);
        }
        return gop.value_ptr;
    }

    pub fn sampleDelta(self: *const Terraform, wx: f32, wz: f32) f32 {
        const pc = PatchCoord.fromWorld(wx, wz);
        const key = packKey(pc);
        const p = self.patches.get(key) orelse return 0;
        const origin = pc.originWorld();
        const lx_f = (wx - origin.x) * cells_per_meter;
        const lz_f = (wz - origin.z) * cells_per_meter;
        const lx0: u32 = @intFromFloat(std.math.clamp(@floor(lx_f), 0, @as(f32, @floatFromInt(patch_cells - 1))));
        const lz0: u32 = @intFromFloat(std.math.clamp(@floor(lz_f), 0, @as(f32, @floatFromInt(patch_cells - 1))));
        const lx1 = @min(lx0 + 1, patch_cells - 1);
        const lz1 = @min(lz0 + 1, patch_cells - 1);
        const fx = lx_f - @as(f32, @floatFromInt(lx0));
        const fz = lz_f - @as(f32, @floatFromInt(lz0));
        const h00 = p.deltaMeters(lx0, lz0);
        const h10 = p.deltaMeters(lx1, lz0);
        const h01 = p.deltaMeters(lx0, lz1);
        const h11 = p.deltaMeters(lx1, lz1);
        const hx0 = h00 + (h10 - h00) * fx;
        const hx1 = h01 + (h11 - h01) * fx;
        return hx0 + (hx1 - hx0) * fz;
    }

    fn applyCell(self: *Terraform, wx: f32, wz: f32, value_m: f32, mode: PrimMode) !void {
        const pc = PatchCoord.fromWorld(wx, wz);
        const p = try self.ensurePatch(pc);
        const origin = pc.originWorld();
        const lx: u32 = @intFromFloat(std.math.clamp(@floor((wx - origin.x) * cells_per_meter), 0, @as(f32, @floatFromInt(patch_cells - 1))));
        const lz: u32 = @intFromFloat(std.math.clamp(@floor((wz - origin.z) * cells_per_meter), 0, @as(f32, @floatFromInt(patch_cells - 1))));
        const cur_m = p.deltaMeters(lx, lz);
        const out_m: f32 = switch (mode) {
            .replace => value_m,
            .additive => cur_m + value_m,
            .min => @min(cur_m, value_m),
            .max => @max(cur_m, value_m),
        };
        const u: u8 = @intFromFloat(std.math.clamp(out_m / alt_scale + @as(f32, @floatFromInt(zero_alt)), 0, 255));
        p.set(lx, lz, u);
        self.generation +%= 1;
    }

    pub fn storeSphere(self: *Terraform, wx: f32, wz: f32, radius: f32, strength_m: f32, mode: PrimMode) !void {
        const r = radius;
        const step = cell_meters;
        var z = wz - r;
        while (z <= wz + r) : (z += step) {
            var x = wx - r;
            while (x <= wx + r) : (x += step) {
                const dx = x - wx;
                const dz = z - wz;
                const dist = @sqrt(dx * dx + dz * dz);
                if (dist > r) continue;
                const t = 1.0 - dist / r;
                try self.applyCell(x, z, strength_m * t * t, mode);
            }
        }
    }

    /// Filled convex quad (Dagor storeQuad).
    pub fn storeQuad(self: *Terraform, quad: QuadData, mode: PrimMode) !void {
        var min_x = quad.verts[0][0];
        var max_x = quad.verts[0][0];
        var min_z = quad.verts[0][1];
        var max_z = quad.verts[0][1];
        for (quad.verts[1..]) |v| {
            min_x = @min(min_x, v[0]);
            max_x = @max(max_x, v[0]);
            min_z = @min(min_z, v[1]);
            max_z = @max(max_z, v[1]);
        }
        const step = cell_meters;
        var z = min_z;
        while (z <= max_z) : (z += step) {
            var x = min_x;
            while (x <= max_x) : (x += step) {
                if (!pointInQuad(x, z, quad)) continue;
                try self.applyCell(x, z, quad.diff_alt, mode);
            }
        }
    }

    /// Dig trench at cells then spread soil as heap (Dagor handleCells / terraformDig).
    pub fn digAndSpread(
        self: *Terraform,
        dig_cells: []const [2]f32,
        dig_depth_m: f32,
        heap_aspect: f32,
    ) !f32 {
        var mass: f32 = 0;
        for (dig_cells) |c| {
            const before = self.sampleDelta(c[0], c[1]);
            try self.applyCell(c[0], c[1], -dig_depth_m, .additive);
            const after = self.sampleDelta(c[0], c[1]);
            mass += @max(before - after, 0);
        }
        if (mass <= 0 or dig_cells.len == 0) return 0;

        // Deposit heap near first dig cell, ring-weighted (simplified Dagor spread).
        const cx = dig_cells[0][0];
        const cz = dig_cells[0][1];
        const rad = @as(f32, @floatFromInt(self.spread_radius)) * cell_meters * @max(heap_aspect, 0.5);
        var left = mass;
        const step = cell_meters;
        var z = cz - rad;
        while (z <= cz + rad and left > 0) : (z += step) {
            var x = cx - rad;
            while (x <= cx + rad and left > 0) : (x += step) {
                const dx = x - cx;
                const dz = z - cz;
                const dist = @sqrt(dx * dx + dz * dz);
                if (dist > rad or dist < cell_meters * 0.5) continue;
                const cur = self.sampleDelta(x, z);
                const space = max_level_m - cur;
                if (space <= 0) continue;
                const w = (1.0 - dist / rad);
                const spend = @min(left * w * 0.15, space);
                if (spend <= 0) continue;
                try self.applyCell(x, z, spend, .additive);
                left -= spend;
            }
        }
        return mass - left;
    }

    /// Bomb crater: inner bowl (DYN_MIN) + outer rim (DYN_MAX) — Dagor makeBombCraterPart.
    pub fn makeBombCrater(
        self: *Terraform,
        wx: f32,
        wz: f32,
        inner_radius: f32,
        inner_depth: f32,
        outer_radius: f32,
        outer_alt: f32,
    ) !void {
        const outer_r = @max(outer_radius, inner_radius);
        const inner_r = inner_radius;
        const outer_rsq = outer_r * outer_r;
        const inner_rsq = inner_r * inner_r;
        const mid_r = inner_r + (outer_r - inner_r) * 0.25;
        const mid_rsq = mid_r * mid_r;
        const step = cell_meters;
        var z = wz - outer_r;
        while (z <= wz + outer_r) : (z += step) {
            var x = wx - outer_r;
            while (x <= wx + outer_r) : (x += step) {
                const dx = x - wx;
                const dz = z - wz;
                const dist_sq = dx * dx + dz * dz;
                if (dist_sq > outer_rsq) continue;
                const cur = self.sampleDelta(x, z);
                const is_zero_or_high = cur >= 0;
                const alt: f32 = if (dist_sq > inner_rsq)
                    (if (dist_sq < mid_rsq)
                        outer_alt * (1.0 - (mid_rsq - dist_sq) / @max(mid_rsq - inner_rsq, 1e-6))
                    else
                        outer_alt * (1.0 - (dist_sq - mid_rsq) / @max(outer_rsq - mid_rsq, 1e-6)))
                else
                    -inner_depth * (1.0 - dist_sq / @max(inner_rsq, 1e-6));
                const mode: PrimMode = if (dist_sq > inner_rsq and is_zero_or_high) .max else .min;
                try self.applyCell(x, z, alt, mode);
            }
        }
    }

    /// RLE delta serialize (Dagor TerraformComponent::serialize role).
    /// Format: "TFDL" + u32 patch_count + [i32 x, i32 z, u32 nbytes, runs...]
    /// Run: u8 alt, u16 index_delta, u8 count (only non-zero cells).
    pub fn writeDelta(self: *const Terraform, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .{};
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "TFDL");
        const count_at = out.items.len;
        try out.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
        var patch_count: u32 = 0;

        var it = self.patches.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr.*;
            if (!p.dirty and p.generation <= 1) {
                // Still serialize if any non-zero alt.
                var any = false;
                for (p.alt) |a| {
                    if (a != zero_alt) {
                        any = true;
                        break;
                    }
                }
                if (!any) continue;
            }
            const key = entry.key_ptr.*;
            const px: i32 = @truncate(@as(i64, @bitCast(key >> 32)));
            const pz: i32 = @truncate(@as(i64, @bitCast(key & 0xffff_ffff)));
            try appendI32(&out, allocator, px);
            try appendI32(&out, allocator, pz);
            const size_at = out.items.len;
            try out.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
            const content_start = out.items.len;

            var index_base: u32 = 0;
            var i: u32 = 0;
            while (i < p.alt.len) {
                if (p.alt[i] == zero_alt) {
                    i += 1;
                    continue;
                }
                const alt = p.alt[i];
                var count: u32 = 0;
                const start = i;
                while (i < p.alt.len and p.alt[i] == alt and count < 255) : (i += 1) count += 1;
                const delta: u16 = @intCast(start - index_base);
                try out.append(allocator, alt);
                try appendU16(&out, allocator, delta);
                try out.append(allocator, @intCast(count));
                index_base = start;
            }
            const nbytes: u32 = @intCast(out.items.len - content_start);
            std.mem.writeInt(u32, out.items[size_at..][0..4], nbytes, .little);
            patch_count += 1;
        }
        std.mem.writeInt(u32, out.items[count_at..][0..4], patch_count, .little);
        return try out.toOwnedSlice(allocator);
    }

    pub fn readDelta(self: *Terraform, data: []const u8) !void {
        if (data.len < 8 or !std.mem.eql(u8, data[0..4], "TFDL")) return error.InvalidTerraformDelta;
        const patch_count = std.mem.readInt(u32, data[4..8], .little);
        var off: usize = 8;
        var pi: u32 = 0;
        while (pi < patch_count) : (pi += 1) {
            if (off + 12 > data.len) return error.InvalidTerraformDelta;
            const px = std.mem.readInt(i32, data[off..][0..4], .little);
            off += 4;
            const pz = std.mem.readInt(i32, data[off..][0..4], .little);
            off += 4;
            const nbytes = std.mem.readInt(u32, data[off..][0..4], .little);
            off += 4;
            const content_end = off + nbytes;
            if (content_end > data.len) return error.InvalidTerraformDelta;
            const patch = try self.ensurePatch(.{ .x = px, .z = pz });
            var index_base: u32 = 0;
            while (off < content_end) {
                if (off + 4 > content_end) return error.InvalidTerraformDelta;
                const alt = data[off];
                off += 1;
                const index_delta = std.mem.readInt(u16, data[off..][0..2], .little);
                off += 2;
                const count = data[off];
                off += 1;
                index_base += index_delta;
                var c: u32 = 0;
                while (c < count) : (c += 1) {
                    const idx = index_base + c;
                    if (idx >= patch.alt.len) return error.InvalidTerraformDelta;
                    patch.alt[idx] = alt;
                }
                patch.dirty = true;
            }
            off = content_end;
            patch.generation +%= 1;
            self.generation +%= 1;
        }
    }

    pub fn bakeInto(self: *const Terraform, hf: *Heightfield) void {
        const n = Heightfield.vertCount(hf.resolution);
        const sp = hf.sampleSpacing();
        var z: u32 = 0;
        while (z < n) : (z += 1) {
            var x: u32 = 0;
            while (x < n) : (x += 1) {
                const wx = hf.origin_x + @as(f32, @floatFromInt(x)) * sp;
                const wz = hf.origin_z + @as(f32, @floatFromInt(z)) * sp;
                const d = self.sampleDelta(wx, wz);
                if (d != 0) hf.set(x, z, hf.get(x, z) + d);
            }
        }
    }

    /// World AABB of all dirty terraform (for patches mesh).
    pub fn dirtyBounds(self: *const Terraform) ?struct { min_x: f32, min_z: f32, max_x: f32, max_z: f32 } {
        var any = false;
        var min_x: f32 = 0;
        var min_z: f32 = 0;
        var max_x: f32 = 0;
        var max_z: f32 = 0;
        var it = self.patches.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.dirty) continue;
            const key = entry.key_ptr.*;
            const pc = PatchCoord{
                .x = @truncate(@as(i64, @bitCast(key >> 32))),
                .z = @truncate(@as(i64, @bitCast(key & 0xffff_ffff))),
            };
            const o = pc.originWorld();
            const ext = @as(f32, @floatFromInt(patch_cells)) * cell_meters;
            if (!any) {
                min_x = o.x;
                min_z = o.z;
                max_x = o.x + ext;
                max_z = o.z + ext;
                any = true;
            } else {
                min_x = @min(min_x, o.x);
                min_z = @min(min_z, o.z);
                max_x = @max(max_x, o.x + ext);
                max_z = @max(max_z, o.z + ext);
            }
        }
        if (!any) return null;
        return .{ .min_x = min_x, .min_z = min_z, .max_x = max_x, .max_z = max_z };
    }
};

fn appendI32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, v, .little);
    try out.appendSlice(allocator, &buf);
}

fn appendU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .little);
    try out.appendSlice(allocator, &buf);
}

pub fn sampleWorld(hf: *const Heightfield, tf: ?*const Terraform, wx: f32, wz: f32) f32 {
    const base = hf.sampleWorld(wx, wz);
    if (tf) |t| return base + t.sampleDelta(wx, wz);
    return base;
}

test "terraform 0.25m sphere changes delta" {
    const allocator = std.testing.allocator;
    var tf = Terraform.init(allocator);
    defer tf.deinit();
    try tf.storeSphere(10, 10, 2.0, 1.0, .additive);
    try std.testing.expect(tf.sampleDelta(10, 10) > 0.2);
}

test "bomb crater digs center" {
    const allocator = std.testing.allocator;
    var tf = Terraform.init(allocator);
    defer tf.deinit();
    try tf.makeBombCrater(20, 20, 2.0, 1.5, 5.0, 0.4);
    try std.testing.expect(tf.sampleDelta(20, 20) < -0.3);
}

test "quad + soil spread" {
    const allocator = std.testing.allocator;
    var tf = Terraform.init(allocator);
    defer tf.deinit();
    try tf.storeQuad(.{
        .verts = .{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } },
        .diff_alt = -0.5,
    }, .additive);
    const cells = [_][2]f32{ .{ 1, 1 }, .{ 1.25, 1 } };
    const deposited = try tf.digAndSpread(&cells, 0.8, 1.0);
    try std.testing.expect(deposited >= 0);
}

test "network RLE roundtrip" {
    const allocator = std.testing.allocator;
    var tf = Terraform.init(allocator);
    defer tf.deinit();
    try tf.storeSphere(5, 5, 1.5, 1.0, .additive);
    const bytes = try tf.writeDelta(allocator);
    defer allocator.free(bytes);
    var tf2 = Terraform.init(allocator);
    defer tf2.deinit();
    try tf2.readDelta(bytes);
    try std.testing.expectApproxEqAbs(tf.sampleDelta(5, 5), tf2.sampleDelta(5, 5), 0.15);
}

test "patch coord covers 64m" {
    const a = PatchCoord.fromWorld(0, 0);
    const b = PatchCoord.fromWorld(63.9, 0);
    const c = PatchCoord.fromWorld(64.0, 0);
    try std.testing.expect(PatchCoord.eql(a, b));
    try std.testing.expect(!PatchCoord.eql(a, c));
}

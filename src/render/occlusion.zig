const std = @import("std");
const zm = @import("zmath");

/// Software hierarchical-Z occlusion (ROADMAP §2.3c), Dagor-style screen-rect tests.
/// Depth: 0 = near, 1 = far (D3D/WebGPU LH). Buffer cleared to 0; occluders write max(z_near).
pub const width: u32 = 256;
pub const height: u32 = 128;
pub const mip_count: u32 = 8;

pub const ScreenBounds = struct {
    x0: i32,
    x1: i32,
    y0: i32,
    y1: i32,
    /// Nearest clip-space Z in 0..1 (after perspective divide).
    z_near: f32,
    /// Farthest clip-space Z.
    z_far: f32,
    valid: bool,
};

pub const HiZ = struct {
    /// Packed mips: mip0 is width*height, then quarter, etc.
    depth: [mipTotalFloats()]f32 = .{0} ** mipTotalFloats(),
    occluders_rasterized: u32 = 0,
    tests: u32 = 0,
    culled: u32 = 0,

    pub fn clear(self: *HiZ) void {
        @memset(&self.depth, 0);
        self.occluders_rasterized = 0;
        self.tests = 0;
        self.culled = 0;
    }

    pub fn rasterizeAabb(self: *HiZ, view_proj: zm.Mat, world_min: [3]f32, world_max: [3]f32) void {
        const sb = projectAabb(view_proj, world_min, world_max) orelse return;
        if (!sb.valid) return;
        const max_x: i32 = @intCast(width - 1);
        const max_y: i32 = @intCast(height - 1);
        if (sb.x1 < 0 or sb.y1 < 0 or sb.x0 > max_x or sb.y0 > max_y) return;
        const x0: u32 = @intCast(@max(sb.x0, 0));
        const y0: u32 = @intCast(@max(sb.y0, 0));
        const x1: u32 = @intCast(@min(sb.x1, max_x));
        const y1: u32 = @intCast(@min(sb.y1, max_y));
        if (x0 > x1 or y0 > y1) return;

        var y: u32 = y0;
        while (y <= y1) : (y += 1) {
            var x: u32 = x0;
            while (x <= x1) : (x += 1) {
                const i = y * width + x;
                self.depth[i] = @max(self.depth[i], sb.z_near);
            }
        }
        self.occluders_rasterized += 1;
    }

    pub fn buildMips(self: *HiZ) void {
        var src_w: u32 = width;
        var src_h: u32 = height;
        var src_off: u32 = 0;
        var mip: u32 = 1;
        while (mip < mip_count) : (mip += 1) {
            const dst_w = @max(src_w / 2, 1);
            const dst_h = @max(src_h / 2, 1);
            const dst_off = mipOffset(mip);
            var y: u32 = 0;
            while (y < dst_h) : (y += 1) {
                var x: u32 = 0;
                while (x < dst_w) : (x += 1) {
                    const x0 = x * 2;
                    const y0 = y * 2;
                    const x1 = @min(x0 + 1, src_w - 1);
                    const y1 = @min(y0 + 1, src_h - 1);
                    const a = self.depth[src_off + y0 * src_w + x0];
                    const b = self.depth[src_off + y0 * src_w + x1];
                    const c = self.depth[src_off + y1 * src_w + x0];
                    const d = self.depth[src_off + y1 * src_w + x1];
                    // Max depth = farthest occluder claim; holes stay 0 via min check at test time.
                    self.depth[dst_off + y * dst_w + x] = @max(@max(a, b), @max(c, d));
                }
            }
            src_off = dst_off;
            src_w = dst_w;
            src_h = dst_h;
        }
    }

    /// True if the AABB is fully behind rasterized occluders (never false-occlude via holes).
    pub fn isOccluded(self: *HiZ, view_proj: zm.Mat, world_min: [3]f32, world_max: [3]f32) bool {
        self.tests += 1;
        const sb = projectAabb(view_proj, world_min, world_max) orelse return false;
        if (!sb.valid) return false;

        const x0 = @max(sb.x0, 0);
        const y0 = @max(sb.y0, 0);
        const x1 = @min(sb.x1, @as(i32, @intCast(width - 1)));
        const y1 = @min(sb.y1, @as(i32, @intCast(height - 1)));
        if (x0 > x1 or y0 > y1) return false;

        const bw = x1 - x0 + 1;
        const bh = y1 - y0 + 1;
        const min_side: u32 = @intCast(@min(bw, bh));
        var mip: u32 = 0;
        var side = min_side;
        while (side > 2 and mip + 1 < mip_count) : ({
            side /= 2;
            mip += 1;
        }) {}

        const mw = mipWidth(mip);
        const mh = mipHeight(mip);
        const off = mipOffset(mip);
        const mx0: u32 = @intCast(@max(x0, 0) >> @intCast(mip));
        const my0: u32 = @intCast(@max(y0, 0) >> @intCast(mip));
        const mx1: u32 = @min(@as(u32, @intCast(x1 >> @intCast(mip))), mw - 1);
        const my1: u32 = @min(@as(u32, @intCast(y1 >> @intCast(mip))), mh - 1);

        var max_d: f32 = 0;
        var min_d: f32 = 1;
        var y: u32 = my0;
        while (y <= my1) : (y += 1) {
            var x: u32 = mx0;
            while (x <= mx1) : (x += 1) {
                const d = self.depth[off + y * mw + x];
                max_d = @max(max_d, d);
                min_d = @min(min_d, d);
            }
        }
        // Hole in coverage (never written) → not occluded.
        if (min_d <= 1e-5) return false;
        // Behind the farthest occluder depth covering the rect.
        if (sb.z_near > max_d + 1e-4) {
            self.culled += 1;
            return true;
        }
        return false;
    }
};

fn mipWidth(mip: u32) u32 {
    return @max(width >> @intCast(mip), 1);
}
fn mipHeight(mip: u32) u32 {
    return @max(height >> @intCast(mip), 1);
}
fn mipOffset(mip: u32) u32 {
    var off: u32 = 0;
    var m: u32 = 0;
    while (m < mip) : (m += 1) {
        off += mipWidth(m) * mipHeight(m);
    }
    return off;
}
fn mipTotalFloats() u32 {
    var total: u32 = 0;
    var m: u32 = 0;
    while (m < mip_count) : (m += 1) {
        total += mipWidth(m) * mipHeight(m);
    }
    return total;
}

pub fn projectAabb(view_proj: zm.Mat, world_min: [3]f32, world_max: [3]f32) ?ScreenBounds {
    const corners = [_][3]f32{
        .{ world_min[0], world_min[1], world_min[2] },
        .{ world_max[0], world_min[1], world_min[2] },
        .{ world_min[0], world_max[1], world_min[2] },
        .{ world_max[0], world_max[1], world_min[2] },
        .{ world_min[0], world_min[1], world_max[2] },
        .{ world_max[0], world_min[1], world_max[2] },
        .{ world_min[0], world_max[1], world_max[2] },
        .{ world_max[0], world_max[1], world_max[2] },
    };

    var min_sx: f32 = std.math.floatMax(f32);
    var max_sx: f32 = -std.math.floatMax(f32);
    var min_sy: f32 = std.math.floatMax(f32);
    var max_sy: f32 = -std.math.floatMax(f32);
    var z_near: f32 = 1;
    var z_far: f32 = 0;
    var any = false;

    for (corners) |c| {
        const clip = zm.mul(zm.f32x4(c[0], c[1], c[2], 1), view_proj);
        if (clip[3] <= 1e-5) continue;
        const inv_w = 1.0 / clip[3];
        const ndc_x = clip[0] * inv_w;
        const ndc_y = clip[1] * inv_w;
        const ndc_z = clip[2] * inv_w;
        // Map NDC [-1,1] → buffer pixels (Y flip for top-left).
        const sx = (ndc_x * 0.5 + 0.5) * @as(f32, @floatFromInt(width));
        const sy = (1.0 - (ndc_y * 0.5 + 0.5)) * @as(f32, @floatFromInt(height));
        min_sx = @min(min_sx, sx);
        max_sx = @max(max_sx, sx);
        min_sy = @min(min_sy, sy);
        max_sy = @max(max_sy, sy);
        z_near = @min(z_near, ndc_z);
        z_far = @max(z_far, ndc_z);
        any = true;
    }
    if (!any) return null;

    return .{
        .x0 = @intFromFloat(@floor(min_sx)),
        .x1 = @intFromFloat(@ceil(max_sx)),
        .y0 = @intFromFloat(@floor(min_sy)),
        .y1 = @intFromFloat(@ceil(max_sy)),
        .z_near = std.math.clamp(z_near, 0, 1),
        .z_far = std.math.clamp(z_far, 0, 1),
        .valid = true,
    };
}

test "hiz occludes box behind wall" {
    var hiz: HiZ = .{};
    hiz.clear();

    // Camera looking +Z from origin-ish.
    const vp = zm.mul(
        zm.lookAtLh(zm.f32x4(0, 1, -6, 1), zm.f32x4(0, 1, 0, 1), zm.f32x4(0, 1, 0, 0)),
        zm.perspectiveFovLh(0.7, 1.6, 0.1, 80.0),
    );

    // Wall in front of hidden cube.
    hiz.rasterizeAabb(vp, .{ -2, 0, 0 }, .{ 2, 3, 0.4 });
    hiz.buildMips();

    // Object clearly behind the wall.
    const hidden = hiz.isOccluded(vp, .{ -0.4, 0.5, 2.0 }, .{ 0.4, 1.5, 2.8 });
    try std.testing.expect(hidden);

    // Object beside the wall (should remain visible — hole in coverage laterally).
    hiz.tests = 0;
    hiz.culled = 0;
    const side = hiz.isOccluded(vp, .{ 3.5, 0.5, 1.0 }, .{ 4.5, 1.5, 2.0 });
    try std.testing.expect(!side);
}

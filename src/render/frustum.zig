const std = @import("std");
const zm = @import("zmath");

/// Six frustum planes in ax+by+cz+d >= 0 (inside) form.
pub const Frustum = struct {
    planes: [6][4]f32,

    /// Extract planes from a column-major view-projection (CPU, pre-transpose).
    pub fn fromViewProj(view_proj: zm.Mat) Frustum {
        // Row-vector GPU uploads use transposed mats; here we use CPU mul(mat, vec).
        const m = view_proj;
        // zmath Mat is [4]F32x4 columns. Extract rows for Gribb-Hartmann.
        const r0 = [4]f32{ m[0][0], m[1][0], m[2][0], m[3][0] };
        const r1 = [4]f32{ m[0][1], m[1][1], m[2][1], m[3][1] };
        const r2 = [4]f32{ m[0][2], m[1][2], m[2][2], m[3][2] };
        const r3 = [4]f32{ m[0][3], m[1][3], m[2][3], m[3][3] };

        var f: Frustum = undefined;
        f.planes[0] = normalizePlane(add4(r3, r0)); // left
        f.planes[1] = normalizePlane(sub4(r3, r0)); // right
        f.planes[2] = normalizePlane(add4(r3, r1)); // bottom
        f.planes[3] = normalizePlane(sub4(r3, r1)); // top
        f.planes[4] = normalizePlane(add4(r3, r2)); // near
        f.planes[5] = normalizePlane(sub4(r3, r2)); // far
        return f;
    }

    pub fn containsAabb(self: Frustum, min_p: [3]f32, max_p: [3]f32) bool {
        for (self.planes) |p| {
            const nx = if (p[0] >= 0) max_p[0] else min_p[0];
            const ny = if (p[1] >= 0) max_p[1] else min_p[1];
            const nz = if (p[2] >= 0) max_p[2] else min_p[2];
            if (p[0] * nx + p[1] * ny + p[2] * nz + p[3] < 0) return false;
        }
        return true;
    }

    pub fn containsSphere(self: Frustum, center: [3]f32, radius: f32) bool {
        for (self.planes) |p| {
            if (p[0] * center[0] + p[1] * center[1] + p[2] * center[2] + p[3] < -radius)
                return false;
        }
        return true;
    }
};

fn add4(a: [4]f32, b: [4]f32) [4]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3] };
}
fn sub4(a: [4]f32, b: [4]f32) [4]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2], a[3] - b[3] };
}
fn normalizePlane(p: [4]f32) [4]f32 {
    const len = @sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
    if (len < 1e-8) return p;
    return .{ p[0] / len, p[1] / len, p[2] / len, p[3] / len };
}

test "unit cube inside identity-ish frustum" {
    const cam_vp = zm.mul(
        zm.lookAtLh(zm.f32x4(0, 0, -5, 1), zm.f32x4(0, 0, 0, 1), zm.f32x4(0, 1, 0, 0)),
        zm.perspectiveFovLh(0.6, 1.0, 0.1, 100.0),
    );
    const f = Frustum.fromViewProj(cam_vp);
    try std.testing.expect(f.containsAabb(.{ -0.5, -0.5, -0.5 }, .{ 0.5, 0.5, 0.5 }));
    try std.testing.expect(!f.containsAabb(.{ 100, 100, 100 }, .{ 101, 101, 101 }));
}

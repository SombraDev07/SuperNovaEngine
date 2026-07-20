const std = @import("std");
const zm = @import("zmath");

pub const Camera = struct {
    /// Spawn high above hills (~±12 m), looking down at origin.
    position: zm.Vec = zm.f32x4(24.0, 32.0, -24.0, 1),
    target: zm.Vec = zm.f32x4(0, 2, 0, 1),
    up: zm.Vec = zm.f32x4(0, 1, 0, 0),
    fov_y: f32 = 0.25 * std.math.pi,
    near: f32 = 0.1,
    far: f32 = 1000.0,
    /// Owned aspect (Dagor settm / resize ownership). Updated from framebuffer.
    aspect: f32 = 16.0 / 9.0,
    /// Yaw / pitch (radians) for fly camera. Defaults look toward origin from spawn.
    yaw: f32 = 2.356, // ~135° — from (+X,-Z) toward origin
    pitch: f32 = -0.85, // steeper look-down so ground reads as ground

    pub fn setAspect(self: *Camera, aspect: f32) void {
        if (aspect > 0.001 and std.math.isFinite(aspect)) {
            self.aspect = aspect;
        }
    }

    pub fn setAspectFromSize(self: *Camera, width: u32, height: u32) void {
        if (height == 0) return;
        self.setAspect(@as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)));
    }

    pub fn forward(self: Camera) zm.Vec {
        const cp = @cos(self.pitch);
        return zm.normalize3(zm.f32x4(
            @cos(self.yaw) * cp,
            @sin(self.pitch),
            @sin(self.yaw) * cp,
            0,
        ));
    }

    pub fn right(self: Camera) zm.Vec {
        return zm.normalize3(zm.cross3(self.up, self.forward()));
    }

    /// Sync look target from yaw/pitch (call after fly input).
    pub fn syncLookTarget(self: *Camera) void {
        const f = self.forward();
        self.target = self.position + f;
    }

    /// lookAt with degenerate-up fallback (Dagor mathUtils lookAt role).
    pub fn viewMatrix(self: Camera) zm.Mat {
        var eye = self.position;
        var at = self.target;
        var up = self.up;
        eye[3] = 1;
        at[3] = 1;
        up[3] = 0;

        const fwd = zm.normalize3(at - eye);
        var right_v = zm.cross3(up, fwd);
        const right_len = zm.length3(right_v)[0];
        if (right_len < 1e-5) {
            // Forward nearly parallel to up — pick alternate up.
            up = if (@abs(fwd[1]) > 0.9) zm.f32x4(0, 0, 1, 0) else zm.f32x4(0, 1, 0, 0);
            right_v = zm.cross3(up, fwd);
        }
        _ = zm.normalize3(right_v);
        return zm.lookAtLh(eye, at, up);
    }

    pub fn projectionMatrix(self: Camera) zm.Mat {
        return zm.perspectiveFovLh(self.fov_y, self.aspect, self.near, self.far);
    }

    pub fn viewProjection(self: Camera) zm.Mat {
        return zm.mul(self.viewMatrix(), self.projectionMatrix());
    }

    /// Kept for callers that still pass framebuffer aspect; prefers owned if override invalid.
    pub fn viewProjectionAspect(self: Camera, aspect_override: f32) zm.Mat {
        const a = if (aspect_override > 0.001) aspect_override else self.aspect;
        return zm.mul(self.viewMatrix(), zm.perspectiveFovLh(self.fov_y, a, self.near, self.far));
    }

    pub fn viewProjectionOwned(self: Camera) zm.Mat {
        return self.viewProjection();
    }
};

test "camera matrices" {
    var cam = Camera{};
    cam.setAspectFromSize(1920, 1080);
    try std.testing.expectApproxEqAbs(@as(f32, 1920.0 / 1080.0), cam.aspect, 1e-5);
    const view = cam.viewMatrix();
    const proj = cam.projectionMatrix();
    _ = view;
    _ = proj;
    // Degenerate up (look straight up)
    cam.target = cam.position + zm.f32x4(0, 1, 0, 0);
    _ = cam.viewMatrix();
}

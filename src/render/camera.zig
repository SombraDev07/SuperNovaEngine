const std = @import("std");
const zm = @import("zmath");

pub const Camera = struct {
    position: zm.Vec = zm.f32x4(2.5, 2.0, -3.5, 1),
    target: zm.Vec = zm.f32x4(0, 0, 0, 1),
    up: zm.Vec = zm.f32x4(0, 1, 0, 0),
    fov_y: f32 = 0.25 * std.math.pi,
    near: f32 = 0.1,
    far: f32 = 1000.0,

    pub fn viewMatrix(self: Camera) zm.Mat {
        return zm.lookAtLh(self.position, self.target, self.up);
    }

    pub fn projectionMatrix(self: Camera, aspect: f32) zm.Mat {
        return zm.perspectiveFovLh(self.fov_y, aspect, self.near, self.far);
    }

    pub fn viewProjection(self: Camera, aspect: f32) zm.Mat {
        return zm.mul(self.viewMatrix(), self.projectionMatrix(aspect));
    }
};

test "camera matrices" {
    const cam = Camera{};
    const view = cam.viewMatrix();
    const proj = cam.projectionMatrix(16.0 / 9.0);
    _ = view;
    _ = proj;
}

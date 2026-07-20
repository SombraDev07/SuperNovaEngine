pub const Renderer = @import("renderer.zig").Renderer;
pub const Camera = @import("camera.zig").Camera;
pub const shader = @import("shader.zig");
pub const mesh = @import("mesh.zig");
pub const gbuffer = @import("gbuffer.zig");
pub const lights = @import("lights.zig");
pub const ibl = @import("ibl.zig");
pub const bloom = @import("bloom.zig");
pub const shadow = @import("shadow.zig");

test {
    _ = @import("renderer.zig");
    _ = @import("camera.zig");
    _ = @import("shader.zig");
    _ = @import("mesh.zig");
    _ = @import("gbuffer.zig");
    _ = @import("lights.zig");
    _ = @import("ibl.zig");
    _ = @import("bloom.zig");
    _ = @import("shadow.zig");
}

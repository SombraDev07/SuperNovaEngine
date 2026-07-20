//! TucanoEngine — public API surface.
pub const core = @import("core/root.zig");
pub const scene = @import("scene/root.zig");
pub const render = @import("render/root.zig");
pub const resources = @import("resources/root.zig");

pub const log = core.log;
pub const assert = core.assert;
pub const time = core.time;
pub const profile = core.profile;
pub const GameLoop = core.GameLoop;
pub const EventBus = core.EventBus;
pub const DebugConsole = core.DebugConsole;

pub const Scene = scene.Scene;
pub const World = scene.World;

pub const Renderer = render.Renderer;
pub const Camera = render.Camera;

pub const ResourceManager = resources.ResourceManager;

test {
    _ = core;
    _ = scene;
    _ = render;
    _ = resources;
}

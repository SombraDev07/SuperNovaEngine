//! TucanoEngine — public API surface.
pub const core = @import("core/root.zig");
pub const scene = @import("scene/root.zig");
pub const render = @import("render/root.zig");
pub const resources = @import("resources/root.zig");
pub const world = @import("world/root.zig");

pub const log = core.log;
pub const assert = core.assert;
pub const time = core.time;
pub const profile = core.profile;
pub const GameLoop = core.GameLoop;
pub const EventBus = core.EventBus;
pub const Event = core.Event;
pub const EventId = core.EventId;
pub const ResizePayload = core.ResizePayload;
pub const KeyPayload = core.KeyPayload;
pub const FocusPayload = core.FocusPayload;
pub const IconifyPayload = core.IconifyPayload;
pub const MouseMovePayload = core.MouseMovePayload;
pub const MouseButtonPayload = core.MouseButtonPayload;
pub const DebugConsole = core.DebugConsole;

pub const Scene = scene.Scene;
pub const SceneManager = scene.SceneManager;
pub const World = scene.World;
pub const EntityManager = scene.EntityManager;
pub const EntityId = scene.EntityId;
pub const UpdateStage = scene.UpdateStage;
pub const ComponentsInit = scene.ComponentsInit;
pub const CoreEvent = scene.CoreEvent;

pub const Renderer = render.Renderer;
pub const Camera = render.Camera;
pub const VideoSettings = render.VideoSettings;
pub const WindowMode = render.WindowMode;

pub const ResourceManager = resources.ResourceManager;
pub const ResourceHandle = resources.ResourceHandle;
pub const ResourceClass = resources.ResourceClass;

pub const Streamer = world.Streamer;
pub const ChunkCoord = world.ChunkCoord;
pub const Heightfield = world.Heightfield;
pub const TerrainTile = world.TerrainTile;

test {
    _ = core;
    _ = scene;
    _ = render;
    _ = resources;
    _ = world;
}

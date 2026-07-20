pub const Scene = @import("scene.zig").Scene;
pub const SceneManager = @import("scene_manager.zig").SceneManager;
pub const ecs = @import("ecs.zig");
pub const World = ecs.World;
pub const EntityManager = ecs.EntityManager;
pub const EntityId = ecs.EntityId;
pub const UpdateStage = ecs.UpdateStage;
pub const Transform = ecs.Transform;
pub const Velocity = ecs.Velocity;
pub const ComponentsInit = ecs.ComponentsInit;
pub const CoreEvent = ecs.CoreEvent;

test {
    _ = @import("scene.zig");
    _ = @import("scene_manager.zig");
    _ = @import("world.zig");
    _ = @import("ecs.zig");
}

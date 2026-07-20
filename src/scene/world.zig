//! Compatibility facade — prefer `ecs.EntityManager` for new code.
pub const ecs = @import("ecs.zig");
pub const EntityId = ecs.EntityId;
pub const UpdateStage = ecs.UpdateStage;
pub const ComponentId = ecs.ComponentId;
pub const Transform = ecs.Transform;
pub const Velocity = ecs.Velocity;
pub const NameTag = ecs.NameTag;
pub const Tag = ecs.Tag;
pub const ComponentsInit = ecs.ComponentsInit;
pub const CoreEvent = ecs.CoreEvent;
pub const EntityManager = ecs.EntityManager;
pub const World = ecs.World;
pub const componentBit = ecs.componentBit;

test {
    _ = @import("ecs.zig");
}

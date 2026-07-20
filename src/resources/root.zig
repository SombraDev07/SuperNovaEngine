pub const manager = @import("manager.zig");
pub const ResourceManager = manager.ResourceManager;
pub const ResourceHandle = manager.Handle;
pub const ResourceClass = manager.ResourceClass;
pub const ResourceFactory = manager.Factory;

test {
    _ = @import("manager.zig");
}

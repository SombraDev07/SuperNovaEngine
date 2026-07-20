pub const log = @import("log.zig");
pub const assert = @import("assert.zig");
pub const time = @import("time.zig");
pub const profile = @import("profile.zig");
pub const GameLoop = @import("game_loop.zig").GameLoop;
pub const events = @import("events.zig");
pub const EventBus = events.EventBus;
pub const Event = events.Event;
pub const EventId = events.EventId;
pub const ResizePayload = events.ResizePayload;
pub const KeyPayload = events.KeyPayload;
pub const FocusPayload = events.FocusPayload;
pub const IconifyPayload = events.IconifyPayload;
pub const MouseMovePayload = events.MouseMovePayload;
pub const MouseButtonPayload = events.MouseButtonPayload;
pub const DebugConsole = @import("debug_console.zig").DebugConsole;

test {
    _ = log;
    _ = assert;
    _ = time;
    _ = profile;
    _ = @import("game_loop.zig");
    _ = @import("events.zig");
    _ = @import("debug_console.zig");
}

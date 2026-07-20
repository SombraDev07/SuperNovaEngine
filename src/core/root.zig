pub const log = @import("log.zig");
pub const assert = @import("assert.zig");
pub const time = @import("time.zig");
pub const profile = @import("profile.zig");
pub const GameLoop = @import("game_loop.zig").GameLoop;
pub const EventBus = @import("events.zig").EventBus;
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

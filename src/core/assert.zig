const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");

pub fn that(condition: bool, comptime message: []const u8) void {
    if (builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) return;
    if (!condition) {
        log.fatal(.core, "ASSERT FAILED: {s}", .{message});
        @panic(message);
    }
}

pub fn thatFmt(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) return;
    if (!condition) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
        log.fatal(.core, "ASSERT FAILED: {s}", .{msg});
        @panic("assertion failed");
    }
}

pub fn unreachableMsg(comptime message: []const u8) noreturn {
    log.fatal(.core, "UNREACHABLE: {s}", .{message});
    unreachable;
}

test "assert passes" {
    that(true, "should not fire");
}

const std = @import("std");

pub const Level = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    fatal = 5,

    pub fn asText(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }
};

pub const Channel = enum {
    core,
    render,
    scene,
    assets,
    audio,
    physics,
    net,
    editor,

    pub fn asText(self: Channel) []const u8 {
        return @tagName(self);
    }
};

pub const SinkFn = *const fn (level: Level, channel: Channel, message: []const u8) void;

var min_level: Level = .info;
var sink: ?SinkFn = null;

pub fn setLevel(level: Level) void {
    min_level = level;
}

pub fn getLevel() Level {
    return min_level;
}

pub fn setSink(new_sink: ?SinkFn) void {
    sink = new_sink;
}

pub fn log(
    comptime level: Level,
    comptime channel: Channel,
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) < @intFromEnum(min_level)) return;

    var buf: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "[{s}] " ++ fmt, .{channel.asText()} ++ args) catch blk: {
        break :blk fmt;
    };

    std.debug.print("[{s}]{s}\n", .{ level.asText(), message });

    if (sink) |s| {
        s(level, channel, message);
    }
}

pub fn trace(comptime channel: Channel, comptime fmt: []const u8, args: anytype) void {
    log(.trace, channel, fmt, args);
}
pub fn debug(comptime channel: Channel, comptime fmt: []const u8, args: anytype) void {
    log(.debug, channel, fmt, args);
}
pub fn info(comptime channel: Channel, comptime fmt: []const u8, args: anytype) void {
    log(.info, channel, fmt, args);
}
pub fn warn(comptime channel: Channel, comptime fmt: []const u8, args: anytype) void {
    log(.warn, channel, fmt, args);
}
pub fn err(comptime channel: Channel, comptime fmt: []const u8, args: anytype) void {
    log(.err, channel, fmt, args);
}
pub fn fatal(comptime channel: Channel, comptime fmt: []const u8, args: anytype) void {
    log(.fatal, channel, fmt, args);
}

test "level ordering" {
    try std.testing.expect(@intFromEnum(Level.trace) < @intFromEnum(Level.fatal));
}

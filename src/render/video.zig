const std = @import("std");
const zglfw = @import("zglfw");
const log = @import("../core/log.zig");

/// Window / display policy (Dagor `init_video` / `update_window_mode` role).
pub const WindowMode = enum {
    windowed,
    resizable_windowed,
    borderless_fullscreen,
    exclusive_fullscreen,
};

pub const VideoSettings = struct {
    width: i32 = 1280,
    height: i32 = 720,
    mode: WindowMode = .resizable_windowed,
    monitor_index: u32 = 0,
    vsync: bool = true,
    /// Adaptive vsync maps to fifo_relaxed when available.
    adaptive_vsync: bool = false,
    title: [:0]const u8 = "TucanoEngine",

    pub fn fromArgs(args: []const []const u8) VideoSettings {
        var s: VideoSettings = .{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--fullscreen") or std.mem.eql(u8, a, "-f")) {
                s.mode = .borderless_fullscreen;
            } else if (std.mem.eql(u8, a, "--exclusive")) {
                s.mode = .exclusive_fullscreen;
            } else if (std.mem.eql(u8, a, "--windowed")) {
                s.mode = .windowed;
            } else if (std.mem.eql(u8, a, "--no-vsync")) {
                s.vsync = false;
            } else if (std.mem.eql(u8, a, "--adaptive-vsync")) {
                s.vsync = true;
                s.adaptive_vsync = true;
            } else if (std.mem.eql(u8, a, "--width") and i + 1 < args.len) {
                i += 1;
                s.width = std.fmt.parseInt(i32, args[i], 10) catch s.width;
            } else if (std.mem.eql(u8, a, "--height") and i + 1 < args.len) {
                i += 1;
                s.height = std.fmt.parseInt(i32, args[i], 10) catch s.height;
            } else if (std.mem.startsWith(u8, a, "--res=")) {
                var it = std.mem.tokenizeScalar(u8, a["--res=".len..], 'x');
                if (it.next()) |w| s.width = std.fmt.parseInt(i32, w, 10) catch s.width;
                if (it.next()) |h| s.height = std.fmt.parseInt(i32, h, 10) catch s.height;
            }
        }
        return s;
    }
};

pub const VideoModeInfo = struct {
    width: i32,
    height: i32,
    refresh_hz: i32,
};

pub fn listVideoModes(allocator: std.mem.Allocator, monitor_index: u32) ![]VideoModeInfo {
    const monitors = zglfw.getMonitors();
    if (monitors.len == 0) return error.NoMonitor;
    const idx = @min(monitor_index, @as(u32, @intCast(monitors.len - 1)));
    const modes = try zglfw.getVideoModes(monitors[idx]);
    var out = try allocator.alloc(VideoModeInfo, modes.len);
    for (modes, 0..) |m, i| {
        out[i] = .{
            .width = m.width,
            .height = m.height,
            .refresh_hz = m.refresh_rate,
        };
    }
    return out;
}

pub fn createWindow(settings: VideoSettings) !*zglfw.Window {
    zglfw.windowHint(.client_api, .no_api);
    const resizable = settings.mode == .resizable_windowed or settings.mode == .windowed;
    zglfw.windowHint(.resizable, resizable);
    zglfw.windowHint(.decorated, settings.mode != .borderless_fullscreen);

    const window = zglfw.Window.create(settings.width, settings.height, settings.title, null, null) catch |err| {
        log.err(.core, "window create failed: {s}", .{@errorName(err)});
        return err;
    };
    errdefer window.destroy();

    if (settings.mode == .resizable_windowed or settings.mode == .windowed) {
        window.setSizeLimits(640, 360, -1, -1);
    }

    try applyWindowMode(window, settings);
    log.info(.core, "video init {d}x{d} mode={s} vsync={}", .{
        settings.width,
        settings.height,
        @tagName(settings.mode),
        settings.vsync,
    });
    return window;
}

pub fn applyWindowMode(window: *zglfw.Window, settings: VideoSettings) !void {
    const monitors = zglfw.getMonitors();
    if (monitors.len == 0) return error.NoMonitor;
    const idx = @min(settings.monitor_index, @as(u32, @intCast(monitors.len - 1)));
    const monitor = monitors[idx];

    switch (settings.mode) {
        .windowed, .resizable_windowed => {
            window.setMonitor(null, 100, 100, settings.width, settings.height, 0);
        },
        .borderless_fullscreen => {
            const mode = try zglfw.getVideoMode(monitor);
            window.setMonitor(monitor, 0, 0, mode.width, mode.height, mode.refresh_rate);
        },
        .exclusive_fullscreen => {
            window.setMonitor(monitor, 0, 0, settings.width, settings.height, 0);
        },
    }
}

test "video settings args" {
    const s = VideoSettings.fromArgs(&.{ "tucano", "--res=1920x1080", "--no-vsync" });
    try std.testing.expectEqual(@as(i32, 1920), s.width);
    try std.testing.expectEqual(@as(i32, 1080), s.height);
    try std.testing.expect(!s.vsync);
}

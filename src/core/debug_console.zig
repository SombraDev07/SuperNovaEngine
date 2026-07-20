const std = @import("std");
const zgui = @import("zgui");
const log = @import("log.zig");

const max_lines: usize = 256;
const line_capacity: usize = 240;
const input_capacity: usize = 256;

const Line = struct {
    level: log.Level,
    text: [line_capacity]u8 = undefined,
    len: usize = 0,

    fn set(self: *Line, level: log.Level, msg: []const u8) void {
        self.level = level;
        const n = @min(msg.len, line_capacity);
        @memcpy(self.text[0..n], msg[0..n]);
        self.len = n;
    }

    fn slice(self: *const Line) []const u8 {
        return self.text[0..self.len];
    }
};

pub const DebugConsole = struct {
    open: bool = false,
    lines: [max_lines]Line = undefined,
    line_count: usize = 0,
    write_index: usize = 0,
    input: [input_capacity:0]u8 = [_:0]u8{0} ** input_capacity,
    scroll_to_bottom: bool = true,
    quit_requested: bool = false,
    key_grave_was_down: bool = false,
    key_f1_was_down: bool = false,
    fps: f32 = 0,
    frame_dt: f32 = 0,

    pub fn init() DebugConsole {
        return .{};
    }

    pub fn push(self: *DebugConsole, level: log.Level, msg: []const u8) void {
        self.lines[self.write_index].set(level, msg);
        self.write_index = (self.write_index + 1) % max_lines;
        if (self.line_count < max_lines) self.line_count += 1;
        self.scroll_to_bottom = true;
    }

    pub fn clear(self: *DebugConsole) void {
        self.line_count = 0;
        self.write_index = 0;
    }

    /// Edge-detect toggle keys. Returns true if console consumed Escape.
    pub fn handleInput(self: *DebugConsole, grave_down: bool, f1_down: bool, escape_down: bool) bool {
        if (grave_down and !self.key_grave_was_down) self.open = !self.open;
        if (f1_down and !self.key_f1_was_down) self.open = !self.open;
        self.key_grave_was_down = grave_down;
        self.key_f1_was_down = f1_down;

        if (self.open and escape_down) {
            self.open = false;
            return true;
        }
        return false;
    }

    pub fn draw(self: *DebugConsole) void {
        if (!self.open) return;

        const viewport = zgui.getMainViewport();
        const pos = viewport.getPos();
        const size = viewport.getSize();

        zgui.setNextWindowPos(.{ .x = pos[0] + 10, .y = pos[1] + 10, .cond = .always });
        zgui.setNextWindowSize(.{ .w = size[0] - 20, .h = size[1] * 0.4, .cond = .always });

        _ = zgui.begin("Debug Console (` / F1)", .{
            .popen = &self.open,
            .flags = .{
                .no_collapse = true,
                .no_resize = true,
                .no_move = true,
            },
        });
        defer zgui.end();

        zgui.text("FPS: {d:.1}  dt: {d:.2} ms", .{ self.fps, self.frame_dt * 1000.0 });
        zgui.separator();

        const footer_h: f32 = zgui.getFrameHeightWithSpacing() + 8;
        if (zgui.beginChild("##log", .{ .h = -footer_h, .window_flags = .{ .horizontal_scrollbar = true } })) {
            var i: usize = 0;
            while (i < self.line_count) : (i += 1) {
                const idx = if (self.line_count < max_lines)
                    i
                else
                    (self.write_index + i) % max_lines;
                const line = &self.lines[idx];
                const color = levelColor(line.level);
                zgui.textUnformattedColored(color, line.slice());
            }
            if (self.scroll_to_bottom) {
                zgui.setScrollHereY(.{ .center_y_ratio = 1.0 });
                self.scroll_to_bottom = false;
            }
        }
        zgui.endChild();

        var reclaim_focus = false;
        zgui.pushItemWidth(-1);
        const submitted = zgui.inputText("##cmd", .{
            .buf = &self.input,
            .flags = .{ .enter_returns_true = true },
        });
        zgui.popItemWidth();

        if (submitted) {
            const cmd = std.mem.sliceTo(&self.input, 0);
            if (cmd.len > 0) {
                self.execute(cmd);
                @memset(self.input[0..], 0);
            }
            reclaim_focus = true;
        }

        zgui.setItemDefaultFocus();
            if (reclaim_focus) {
            zgui.setKeyboardFocusHere(-1);
        }
    }

    fn execute(self: *DebugConsole, cmd_line: []const u8) void {
        self.push(.info, cmd_line);

        var it = std.mem.tokenizeScalar(u8, cmd_line, ' ');
        const cmd = it.next() orelse return;

        if (std.ascii.eqlIgnoreCase(cmd, "help")) {
            self.push(.info, "commands: help, clear, fps, quit, log <trace|debug|info|warn|error>");
        } else if (std.ascii.eqlIgnoreCase(cmd, "clear")) {
            self.clear();
        } else if (std.ascii.eqlIgnoreCase(cmd, "fps")) {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fps={d:.2} dt={d:.4}s", .{ self.fps, self.frame_dt }) catch return;
            self.push(.info, msg);
        } else if (std.ascii.eqlIgnoreCase(cmd, "quit") or std.ascii.eqlIgnoreCase(cmd, "exit")) {
            self.quit_requested = true;
            self.push(.warn, "quit requested");
        } else if (std.ascii.eqlIgnoreCase(cmd, "log")) {
            const level_name = it.next() orelse {
                self.push(.warn, "usage: log <trace|debug|info|warn|error>");
                return;
            };
            if (parseLevel(level_name)) |level| {
                log.setLevel(level);
                var buf: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "log level -> {s}", .{level.asText()}) catch return;
                self.push(.info, msg);
            } else {
                self.push(.err, "unknown level");
            }
        } else {
            self.push(.err, "unknown command (try 'help')");
        }
    }
};

fn parseLevel(name: []const u8) ?log.Level {
    if (std.ascii.eqlIgnoreCase(name, "trace")) return .trace;
    if (std.ascii.eqlIgnoreCase(name, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(name, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(name, "warn")) return .warn;
    if (std.ascii.eqlIgnoreCase(name, "error") or std.ascii.eqlIgnoreCase(name, "err")) return .err;
    if (std.ascii.eqlIgnoreCase(name, "fatal")) return .fatal;
    return null;
}

fn levelColor(level: log.Level) [4]f32 {
    return switch (level) {
        .trace => .{ 0.55, 0.55, 0.55, 1 },
        .debug => .{ 0.60, 0.80, 1.0, 1 },
        .info => .{ 0.85, 0.85, 0.85, 1 },
        .warn => .{ 1.0, 0.85, 0.30, 1 },
        .err => .{ 1.0, 0.35, 0.35, 1 },
        .fatal => .{ 1.0, 0.15, 0.45, 1 },
    };
}

test "console ring wraps" {
    var c = DebugConsole.init();
    var i: usize = 0;
    while (i < max_lines + 10) : (i += 1) {
        c.push(.info, "x");
    }
    try std.testing.expectEqual(max_lines, c.line_count);
}

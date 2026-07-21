const std = @import("std");

pub const EventId = enum(u32) {
    window_resize,
    window_close,
    window_focus,
    window_iconify,
    key_down,
    key_up,
    mouse_move,
    mouse_button,
    scene_loaded,
    scene_unloaded,
    custom = 1000,
    _,
};

pub const ResizePayload = struct {
    width: u32,
    height: u32,
};

pub const KeyPayload = struct {
    key: i32,
    scancode: i32,
    mods: i32,
};

pub const FocusPayload = struct {
    focused: bool,
};

pub const IconifyPayload = struct {
    iconified: bool,
};

pub const MouseMovePayload = struct {
    x: f64,
    y: f64,
};

pub const MouseButtonPayload = struct {
    button: i32,
    action: i32,
    mods: i32,
    x: f64,
    y: f64,
};

pub const Event = struct {
    id: EventId,
    payload: ?*anyopaque = null,
};

const Handler = struct {
    context: ?*anyopaque,
    callback: *const fn (context: ?*anyopaque, event: Event) void,
};

/// Synchronous event bus (Dagor workCycle / wndproc dispatch role).
pub const EventBus = struct {
    allocator: std.mem.Allocator,
    handlers: std.AutoHashMap(EventId, std.ArrayList(Handler)),
    /// App-active / focus state (Dagor activate role).
    focused: bool = true,
    iconified: bool = false,

    pub fn init(allocator: std.mem.Allocator) EventBus {
        return .{
            .allocator = allocator,
            .handlers = std.AutoHashMap(EventId, std.ArrayList(Handler)).init(allocator),
        };
    }

    pub fn deinit(self: *EventBus) void {
        var it = self.handlers.valueIterator();
        while (it.next()) |list| {
            list.deinit(self.allocator);
        }
        self.handlers.deinit();
    }

    pub fn subscribe(
        self: *EventBus,
        id: EventId,
        context: ?*anyopaque,
        callback: *const fn (context: ?*anyopaque, event: Event) void,
    ) !void {
        const gop = try self.handlers.getOrPut(id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.append(self.allocator, .{
            .context = context,
            .callback = callback,
        });
    }

    pub fn publish(self: *EventBus, event: Event) void {
        const list = self.handlers.getPtr(event.id) orelse return;
        for (list.items) |handler| {
            handler.callback(handler.context, event);
        }
    }

    pub fn publishResize(self: *EventBus, width: u32, height: u32) void {
        var payload = ResizePayload{ .width = width, .height = height };
        self.publish(.{ .id = .window_resize, .payload = &payload });
    }

    pub fn publishKey(self: *EventBus, down: bool, key: i32, scancode: i32, mods: i32) void {
        var payload = KeyPayload{ .key = key, .scancode = scancode, .mods = mods };
        self.publish(.{
            .id = if (down) .key_down else .key_up,
            .payload = &payload,
        });
    }

    pub fn publishFocus(self: *EventBus, focused: bool) void {
        self.focused = focused;
        var payload = FocusPayload{ .focused = focused };
        self.publish(.{ .id = .window_focus, .payload = &payload });
    }

    pub fn publishIconify(self: *EventBus, iconified: bool) void {
        self.iconified = iconified;
        var payload = IconifyPayload{ .iconified = iconified };
        self.publish(.{ .id = .window_iconify, .payload = &payload });
    }

    pub fn publishMouseMove(self: *EventBus, x: f64, y: f64) void {
        var payload = MouseMovePayload{ .x = x, .y = y };
        self.publish(.{ .id = .mouse_move, .payload = &payload });
    }

    pub fn publishMouseButton(self: *EventBus, button: i32, action: i32, mods: i32, x: f64, y: f64) void {
        var payload = MouseButtonPayload{ .button = button, .action = action, .mods = mods, .x = x, .y = y };
        self.publish(.{ .id = .mouse_button, .payload = &payload });
    }

    /// Skip draw only when iconified. Unfocused windows still render (see Renderer.shouldDraw).
    pub fn shouldDrawApp(self: *const EventBus) bool {
        return !self.iconified;
    }
};

test "event bus publish" {
    const allocator = std.testing.allocator;
    var bus = EventBus.init(allocator);
    defer bus.deinit();

    const Counter = struct {
        count: u32 = 0,
        fn onEvent(ctx: ?*anyopaque, _: Event) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.count += 1;
        }
    };
    var counter: Counter = .{};

    try bus.subscribe(.window_close, &counter, Counter.onEvent);
    bus.publish(.{ .id = .window_close });
    bus.publish(.{ .id = .window_close });
    try std.testing.expectEqual(@as(u32, 2), counter.count);
}

test "focus mouse payloads" {
    const allocator = std.testing.allocator;
    var bus = EventBus.init(allocator);
    defer bus.deinit();
    bus.publishFocus(false);
    // Unfocused still draws (iconify is what pauses).
    try std.testing.expect(bus.shouldDrawApp());
    bus.publishFocus(true);
    bus.publishMouseMove(10, 20);
    bus.publishMouseButton(0, 1, 0, 10, 20);
    try std.testing.expect(bus.shouldDrawApp());
    bus.publishIconify(true);
    try std.testing.expect(!bus.shouldDrawApp());
}

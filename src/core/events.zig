const std = @import("std");

pub const EventId = enum(u32) {
    window_resize,
    window_close,
    key_down,
    key_up,
    mouse_move,
    mouse_button,
    scene_loaded,
    scene_unloaded,
    custom = 1000,
    _,
};

pub const Event = struct {
    id: EventId,
    payload: ?*anyopaque = null,
};

const Handler = struct {
    context: ?*anyopaque,
    callback: *const fn (context: ?*anyopaque, event: Event) void,
};

/// Simple synchronous event bus. Handlers are invoked immediately on publish.
pub const EventBus = struct {
    allocator: std.mem.Allocator,
    handlers: std.AutoHashMap(EventId, std.ArrayList(Handler)),

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

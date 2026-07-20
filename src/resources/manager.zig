const std = @import("std");
const log = @import("../core/log.zig");

pub const Handle = enum(u32) {
    invalid = 0,
    _,
};

const Entry = struct {
    path: []const u8,
    ref_count: u32,
};

/// Reference-counted asset registry. Actual GPU/CPU loading hooks come later.
pub const ResourceManager = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap(Handle, Entry),
    path_to_handle: std.StringHashMap(Handle),
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) ResourceManager {
        return .{
            .allocator = allocator,
            .entries = std.AutoHashMap(Handle, Entry).init(allocator),
            .path_to_handle = std.StringHashMap(Handle).init(allocator),
        };
    }

    pub fn deinit(self: *ResourceManager) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.path);
        }
        self.entries.deinit();
        self.path_to_handle.deinit();
        self.* = undefined;
    }

    pub fn acquire(self: *ResourceManager, path: []const u8) !Handle {
        if (self.path_to_handle.get(path)) |existing| {
            const entry = self.entries.getPtr(existing).?;
            entry.ref_count += 1;
            return existing;
        }

        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);

        const handle: Handle = @enumFromInt(self.next_id);
        self.next_id += 1;

        try self.entries.put(handle, .{ .path = owned, .ref_count = 1 });
        try self.path_to_handle.put(owned, handle);

        log.debug(.assets, "loaded handle={d} path={s}", .{ @intFromEnum(handle), path });
        return handle;
    }

    pub fn release(self: *ResourceManager, handle: Handle) void {
        const entry = self.entries.getPtr(handle) orelse return;
        if (entry.ref_count == 0) return;
        entry.ref_count -= 1;
        if (entry.ref_count > 0) return;

        const path = entry.path;
        _ = self.path_to_handle.remove(path);
        _ = self.entries.remove(handle);
        self.allocator.free(path);
        log.debug(.assets, "unloaded handle={d}", .{@intFromEnum(handle)});
    }

    pub fn pathOf(self: *const ResourceManager, handle: Handle) ?[]const u8 {
        const entry = self.entries.get(handle) orelse return null;
        return entry.path;
    }
};

test "resource refcount" {
    const allocator = std.testing.allocator;
    var rm = ResourceManager.init(allocator);
    defer rm.deinit();

    const a = try rm.acquire("textures/dirt.png");
    const b = try rm.acquire("textures/dirt.png");
    try std.testing.expectEqual(a, b);
    rm.release(a);
    try std.testing.expect(rm.pathOf(a) != null);
    rm.release(b);
    try std.testing.expect(rm.pathOf(a) == null);
}

const std = @import("std");
const log = @import("../core/log.zig");

pub const Handle = enum(u32) {
    invalid = 0,
    _,
};

pub const ResourceClass = enum(u32) {
    raw_bytes = 1,
    shader_source = 2,
    _,
};

/// Dagor `GameResourceFactory` role — typed load/unload by class.
pub const Factory = struct {
    class_id: ResourceClass,
    class_name: []const u8,
    context: ?*anyopaque = null,
    load: *const fn (context: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8,
    unload: *const fn (context: ?*anyopaque, allocator: std.mem.Allocator, data: []u8) void = defaultUnload,

    fn defaultUnload(_: ?*anyopaque, allocator: std.mem.Allocator, data: []u8) void {
        allocator.free(data);
    }
};

const Entry = struct {
    path: []const u8,
    data: []u8,
    ref_count: u32,
    class_id: ResourceClass,
};

fn loadRawBytes(_: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
}

fn loadShaderSource(_: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.mem.endsWith(u8, path, ".wgsl")) return error.NotShaderSource;
    return try std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024);
}

/// Reference-counted asset registry with typed factories (gameres role).
pub const ResourceManager = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap(Handle, Entry),
    path_to_handle: std.StringHashMap(Handle),
    factories: std.AutoHashMap(ResourceClass, Factory),
    next_id: u32 = 1,
    max_file_bytes: usize = 64 * 1024 * 1024,

    pub fn init(allocator: std.mem.Allocator) ResourceManager {
        return .{
            .allocator = allocator,
            .entries = std.AutoHashMap(Handle, Entry).init(allocator),
            .path_to_handle = std.StringHashMap(Handle).init(allocator),
            .factories = std.AutoHashMap(ResourceClass, Factory).init(allocator),
        };
    }

    pub fn deinit(self: *ResourceManager) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            if (self.factories.get(entry.class_id)) |f| {
                f.unload(f.context, self.allocator, entry.data);
            } else {
                self.allocator.free(entry.data);
            }
            self.allocator.free(entry.path);
        }
        self.entries.deinit();
        self.path_to_handle.deinit();
        self.factories.deinit();
        self.* = undefined;
    }

    pub fn registerFactory(self: *ResourceManager, factory: Factory) !void {
        try self.factories.put(factory.class_id, factory);
        log.info(.assets, "factory registered {s} class={d}", .{
            factory.class_name,
            @intFromEnum(factory.class_id),
        });
    }

    pub fn registerStdFactories(self: *ResourceManager) !void {
        try self.registerFactory(.{
            .class_id = .raw_bytes,
            .class_name = "raw_bytes",
            .load = loadRawBytes,
        });
        try self.registerFactory(.{
            .class_id = .shader_source,
            .class_name = "shader_source",
            .load = loadShaderSource,
        });
    }

    pub fn acquire(self: *ResourceManager, path: []const u8) !Handle {
        return self.acquireClass(path, .raw_bytes);
    }

    pub fn acquireClass(self: *ResourceManager, path: []const u8, class_id: ResourceClass) !Handle {
        if (self.path_to_handle.get(path)) |existing| {
            const entry = self.entries.getPtr(existing).?;
            entry.ref_count += 1;
            return existing;
        }

        const factory = self.factories.get(class_id) orelse return error.NoFactory;
        const data = try factory.load(factory.context, self.allocator, path);
        errdefer factory.unload(factory.context, self.allocator, data);

        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);

        const handle: Handle = @enumFromInt(self.next_id);
        self.next_id += 1;

        try self.entries.put(handle, .{
            .path = owned,
            .data = data,
            .ref_count = 1,
            .class_id = class_id,
        });
        try self.path_to_handle.put(owned, handle);

        log.debug(.assets, "loaded handle={d} class={s} path={s} bytes={d}", .{
            @intFromEnum(handle),
            factory.class_name,
            path,
            data.len,
        });
        return handle;
    }

    pub fn release(self: *ResourceManager, handle: Handle) void {
        const entry = self.entries.getPtr(handle) orelse return;
        if (entry.ref_count == 0) return;
        entry.ref_count -= 1;
        if (entry.ref_count > 0) return;

        const path = entry.path;
        const data = entry.data;
        const class_id = entry.class_id;
        _ = self.path_to_handle.remove(path);
        _ = self.entries.remove(handle);
        if (self.factories.get(class_id)) |f| {
            f.unload(f.context, self.allocator, data);
        } else {
            self.allocator.free(data);
        }
        self.allocator.free(path);
        log.debug(.assets, "unloaded handle={d}", .{@intFromEnum(handle)});
    }

    /// Free zero-ref leftovers (Dagor `free_unused_game_resources` role).
    pub fn freeUnused(self: *ResourceManager) u32 {
        var freed: u32 = 0;
        var to_free: std.ArrayList(Handle) = .{};
        defer to_free.deinit(self.allocator);
        var it = self.entries.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.ref_count == 0) to_free.append(self.allocator, e.key_ptr.*) catch {};
        }
        for (to_free.items) |h| {
            self.release(h);
            freed += 1;
        }
        return freed;
    }

    pub fn isLoaded(self: *const ResourceManager, path: []const u8) bool {
        return self.path_to_handle.contains(path);
    }

    pub fn handleOf(self: *const ResourceManager, path: []const u8) Handle {
        return self.path_to_handle.get(path) orelse .invalid;
    }

    pub fn pathOf(self: *const ResourceManager, handle: Handle) ?[]const u8 {
        const entry = self.entries.get(handle) orelse return null;
        return entry.path;
    }

    pub fn bytes(self: *const ResourceManager, handle: Handle) ?[]const u8 {
        const entry = self.entries.get(handle) orelse return null;
        return entry.data;
    }

    pub fn refCount(self: *const ResourceManager, handle: Handle) u32 {
        const entry = self.entries.get(handle) orelse return 0;
        return entry.ref_count;
    }

    pub fn classOf(self: *const ResourceManager, handle: Handle) ?ResourceClass {
        const entry = self.entries.get(handle) orelse return null;
        return entry.class_id;
    }

    /// Preload batch (Dagor RRL-lite): acquire many paths, return count loaded.
    pub fn preload(self: *ResourceManager, paths: []const []const u8, class_id: ResourceClass) !u32 {
        var n: u32 = 0;
        for (paths) |p| {
            _ = try self.acquireClass(p, class_id);
            n += 1;
        }
        return n;
    }

    /// Load a newline-separated pack list file (path per line, `#` comments).
    pub fn loadPackList(self: *ResourceManager, list_path: []const u8, class_id: ResourceClass) !u32 {
        const text = try std.fs.cwd().readFileAlloc(self.allocator, list_path, 1 * 1024 * 1024);
        defer self.allocator.free(text);
        var n: u32 = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            _ = try self.acquireClass(line, class_id);
            n += 1;
        }
        log.info(.assets, "pack '{s}' loaded {d} resources", .{ list_path, n });
        return n;
    }
};

test "resource factories" {
    const allocator = std.testing.allocator;
    var rm = ResourceManager.init(allocator);
    defer rm.deinit();
    try rm.registerStdFactories();

    const a = try rm.acquireClass("assets/shaders/basic.wgsl", .shader_source);
    const b = try rm.acquireClass("assets/shaders/basic.wgsl", .shader_source);
    try std.testing.expectEqual(a, b);
    try std.testing.expect(rm.bytes(a).?.len > 0);
    try std.testing.expect(rm.isLoaded("assets/shaders/basic.wgsl"));
    try std.testing.expectEqual(ResourceClass.shader_source, rm.classOf(a).?);
    rm.release(a);
    rm.release(b);
    try std.testing.expect(!rm.isLoaded("assets/shaders/basic.wgsl"));
}

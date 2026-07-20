const std = @import("std");
const zgpu = @import("zgpu");
const log = @import("../core/log.zig");

/// Load a WGSL source file as a null-terminated string owned by `allocator`.
pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) ![:0]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(data);

    const source = try allocator.dupeZ(u8, data);
    log.debug(.render, "loaded shader {s} ({d} bytes)", .{ path, source.len });
    return source;
}

/// Compile WGSL source into a GPU shader module. Caller must `release()` the module.
pub fn createModule(device: zgpu.wgpu.Device, source: [:0]const u8, label: ?[*:0]const u8) zgpu.wgpu.ShaderModule {
    return zgpu.createWgslShaderModule(device, source, label);
}

/// Cached WGSL modules (Dagor shader bindump cache role — source path keyed).
pub const Cache = struct {
    allocator: std.mem.Allocator,
    device: zgpu.wgpu.Device,
    modules: std.StringHashMap(zgpu.wgpu.ShaderModule),
    /// Last load failure path (Dawn also logs validation; this surfaces path to callers).
    last_error_path: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, device: zgpu.wgpu.Device) Cache {
        return .{
            .allocator = allocator,
            .device = device,
            .modules = std.StringHashMap(zgpu.wgpu.ShaderModule).init(allocator),
        };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.modules.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.release();
            self.allocator.free(e.key_ptr.*);
        }
        self.modules.deinit();
        self.* = undefined;
    }

    /// Load+compile once; subsequent calls return the cached module (referenced).
    pub fn getOrLoad(self: *Cache, path: []const u8) !zgpu.wgpu.ShaderModule {
        if (self.modules.get(path)) |m| {
            m.reference();
            return m;
        }
        const source = loadFile(self.allocator, path) catch |err| {
            self.last_error_path = path;
            log.err(.render, "shader load failed {s}: {s}", .{ path, @errorName(err) });
            return err;
        };
        defer self.allocator.free(source);

        // Label from basename for Dawn validation messages.
        const label_z = try self.allocator.dupeZ(u8, std.fs.path.basename(path));
        defer self.allocator.free(label_z);

        const module = createModule(self.device, source, label_z.ptr);
        // Dawn reports WGSL errors via device uncaptured-error callback.
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        try self.modules.put(key, module);
        module.reference(); // one ref for cache, one for caller
        self.last_error_path = null;
        log.info(.render, "shader cached {s}", .{path});
        return module;
    }

    pub fn invalidate(self: *Cache, path: []const u8) void {
        const kv = self.modules.fetchRemove(path) orelse return;
        kv.value.release();
        self.allocator.free(kv.key);
    }

    pub fn clear(self: *Cache) void {
        var it = self.modules.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.release();
            self.allocator.free(e.key_ptr.*);
        }
        self.modules.clearRetainingCapacity();
    }
};

test "shader path convention" {
    try std.testing.expect(std.mem.endsWith(u8, "assets/shaders/basic.wgsl", ".wgsl"));
}

test "load basic wgsl file" {
    const allocator = std.testing.allocator;
    const src = try loadFile(allocator, "assets/shaders/basic.wgsl");
    defer allocator.free(src);
    try std.testing.expect(src.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, src, "vs_main") != null);
}

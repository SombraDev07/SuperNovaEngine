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

test "shader path convention" {
    try std.testing.expect(std.mem.endsWith(u8, "assets/shaders/basic.wgsl", ".wgsl"));
}

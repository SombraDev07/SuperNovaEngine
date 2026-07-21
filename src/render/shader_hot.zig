const std = @import("std");
const log = @import("../core/log.zig");

/// Poll WGSL files for mtime changes (ROADMAP §2.4 hot-reload).
pub const HotReload = struct {
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    mtimes: []i128,
    enabled: bool = true,
    /// Frames to skip between polls.
    poll_every: u32 = 30,
    frame_counter: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, paths: []const []const u8) !HotReload {
        const mtimes = try allocator.alloc(i128, paths.len);
        errdefer allocator.free(mtimes);
        for (paths, 0..) |path, i| {
            mtimes[i] = fileMtime(path) orelse 0;
        }
        return .{
            .allocator = allocator,
            .paths = paths,
            .mtimes = mtimes,
        };
    }

    pub fn deinit(self: *HotReload) void {
        self.allocator.free(self.mtimes);
        self.* = undefined;
    }

    /// Returns true if any watched file changed since last poll.
    pub fn poll(self: *HotReload) bool {
        if (!self.enabled) return false;
        self.frame_counter += 1;
        if (self.frame_counter < self.poll_every) return false;
        self.frame_counter = 0;

        var changed = false;
        for (self.paths, 0..) |path, i| {
            const mt = fileMtime(path) orelse continue;
            if (mt != self.mtimes[i] and self.mtimes[i] != 0) {
                log.info(.render, "shader changed: {s}", .{path});
                changed = true;
            }
            self.mtimes[i] = mt;
        }
        return changed;
    }
};

fn fileMtime(path: []const u8) ?i128 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const st = file.stat() catch return null;
    return @intCast(st.mtime);
}

pub const watched_shaders = [_][]const u8{
    "assets/shaders/gbuffer.wgsl",
    "assets/shaders/terrain_gbuffer.wgsl",
    "assets/shaders/shadow.wgsl",
    "assets/shaders/shadow_point.wgsl",
    "assets/shaders/deferred_light.wgsl",
    "assets/shaders/gtao.wgsl",
    "assets/shaders/gtao_spatial.wgsl",
    "assets/shaders/gtao_temporal.wgsl",
    "assets/shaders/ddgi_update.wgsl",
    "assets/shaders/ddgi_apply.wgsl",
    "assets/shaders/ssgi_update.wgsl",
    "assets/shaders/ssgi_apply.wgsl",
    "assets/shaders/ssgi_spatial.wgsl",
    "assets/shaders/gi_sdf_mark.wgsl",
    "assets/shaders/gi_sdf_jfa.wgsl",
    "assets/shaders/gi_sdf_remove.wgsl",
    "assets/shaders/gi_sdf_to_atlas.wgsl",
    "assets/shaders/gi_lit_mark.wgsl",
    "assets/shaders/gi_lit_to_atlas.wgsl",
    "assets/shaders/gi_albedo_mark.wgsl",
    "assets/shaders/gi_albedo_to_atlas.wgsl",
    "assets/shaders/hzb_mip0.wgsl",
    "assets/shaders/hzb_down.wgsl",
    "assets/shaders/bloom_extract.wgsl",
    "assets/shaders/bloom_blur.wgsl",
    "assets/shaders/bloom_upsample.wgsl",
    "assets/shaders/tonemap.wgsl",
    "assets/shaders/lum_reduce.wgsl",
    "assets/shaders/lum_hist.wgsl",
    "assets/shaders/lum_avg.wgsl",
    "assets/shaders/exposure_adapt.wgsl",
};

test "hot reload init" {
    const allocator = std.testing.allocator;
    var hr = try HotReload.init(allocator, &watched_shaders);
    defer hr.deinit();
    try std.testing.expect(hr.mtimes.len == watched_shaders.len);
}

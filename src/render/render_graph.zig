const std = @import("std");

/// Minimal declarative render-graph skeleton (ROADMAP §2.3a).
pub const ResourceId = enum(u16) {
    shadow_cascades,
    point_shadow_cube,
    spot_shadow_maps,
    gbuffer_albedo,
    gbuffer_normal,
    gbuffer_material,
    gbuffer_depth,
    hdr_color,
    bloom_a,
    bloom_b,
    lum_mid,
    lum_1x1,
    exposure,
    swapchain,
};

pub const PassId = enum(u16) {
    shadow_csm,
    shadow_point,
    shadow_spot,
    gbuffer,
    lighting,
    bloom,
    exposure,
    tonemap,
    ui,
};

pub const Node = struct {
    id: PassId,
    reads: []const ResourceId = &.{},
    writes: []const ResourceId = &.{},
    execute: *const fn (*anyopaque) void,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    nodes: []const Node,
    last_run: std.ArrayList(PassId) = .{},

    pub fn init(allocator: std.mem.Allocator, nodes: []const Node) Graph {
        return .{
            .allocator = allocator,
            .nodes = nodes,
        };
    }

    pub fn deinit(self: *Graph) void {
        self.last_run.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn execute(self: *Graph, ctx: *anyopaque) void {
        self.last_run.clearRetainingCapacity();
        for (self.nodes) |node| {
            node.execute(ctx);
            self.last_run.append(self.allocator, node.id) catch {};
        }
    }
};

test "graph runs in order" {
    const allocator = std.testing.allocator;
    const S = struct {
        fn a(_: *anyopaque) void {}
        fn b(_: *anyopaque) void {}
    };
    const nodes = [_]Node{
        .{ .id = .gbuffer, .execute = S.a },
        .{ .id = .lighting, .execute = S.b },
    };
    var g = Graph.init(allocator, &nodes);
    defer g.deinit();
    var dummy: u8 = 0;
    g.execute(&dummy);
    try std.testing.expectEqual(@as(usize, 2), g.last_run.items.len);
    try std.testing.expectEqual(PassId.gbuffer, g.last_run.items[0]);
    try std.testing.expectEqual(PassId.lighting, g.last_run.items[1]);
}

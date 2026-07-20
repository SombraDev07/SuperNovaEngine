const std = @import("std");
const zgpu = @import("zgpu");

pub const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    color: [3]f32,

    pub const attributes = [_]zgpu.wgpu.VertexAttribute{
        .{ .format = .float32x3, .offset = @offsetOf(Vertex, "position"), .shader_location = 0 },
        .{ .format = .float32x3, .offset = @offsetOf(Vertex, "normal"), .shader_location = 1 },
        .{ .format = .float32x3, .offset = @offsetOf(Vertex, "color"), .shader_location = 2 },
    };
};

pub const Mesh = struct {
    vertex_buffer: zgpu.BufferHandle,
    index_buffer: zgpu.BufferHandle,
    index_count: u32,
};

pub fn createGpuMesh(
    gctx: *zgpu.GraphicsContext,
    vertices: []const Vertex,
    indices: []const u32,
) Mesh {
    const vertex_buffer = gctx.createBuffer(.{
        .usage = .{ .copy_dst = true, .vertex = true },
        .size = vertices.len * @sizeOf(Vertex),
    });
    gctx.queue.writeBuffer(gctx.lookupResource(vertex_buffer).?, 0, Vertex, vertices);

    const index_buffer = gctx.createBuffer(.{
        .usage = .{ .copy_dst = true, .index = true },
        .size = indices.len * @sizeOf(u32),
    });
    gctx.queue.writeBuffer(gctx.lookupResource(index_buffer).?, 0, u32, indices);

    return .{
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .index_count = @intCast(indices.len),
    };
}

/// Unit cube centered at origin. CCW when viewed from outside; face normals included.
pub fn cubeVertices() [24]Vertex {
    const ldb = [3]f32{ -0.5, -0.5, -0.5 };
    const rdb = [3]f32{ 0.5, -0.5, -0.5 };
    const lub = [3]f32{ -0.5, 0.5, -0.5 };
    const rub = [3]f32{ 0.5, 0.5, -0.5 };
    const ldf = [3]f32{ -0.5, -0.5, 0.5 };
    const rdf = [3]f32{ 0.5, -0.5, 0.5 };
    const luf = [3]f32{ -0.5, 0.5, 0.5 };
    const ruf = [3]f32{ 0.5, 0.5, 0.5 };

    const faces = [_]struct { n: [3]f32, c: [3]f32, q: [4][3]f32 }{
        .{ .n = .{ 0, 0, 1 }, .c = .{ 0.85, 0.15, 0.12 }, .q = .{ ldf, rdf, ruf, luf } },
        .{ .n = .{ 0, 0, -1 }, .c = .{ 0.15, 0.75, 0.25 }, .q = .{ rdb, ldb, lub, rub } },
        .{ .n = .{ 1, 0, 0 }, .c = .{ 0.15, 0.35, 0.90 }, .q = .{ rdf, rdb, rub, ruf } },
        .{ .n = .{ -1, 0, 0 }, .c = .{ 0.90, 0.80, 0.15 }, .q = .{ ldb, ldf, luf, lub } },
        .{ .n = .{ 0, 1, 0 }, .c = .{ 0.85, 0.20, 0.85 }, .q = .{ luf, ruf, rub, lub } },
        .{ .n = .{ 0, -1, 0 }, .c = .{ 0.20, 0.85, 0.85 }, .q = .{ ldb, rdb, rdf, ldf } },
    };

    var out: [24]Vertex = undefined;
    var i: usize = 0;
    for (faces) |face| {
        for (face.q) |p| {
            out[i] = .{ .position = p, .normal = face.n, .color = face.c };
            i += 1;
        }
    }
    return out;
}

pub fn cubeIndices() [36]u32 {
    var out: [36]u32 = undefined;
    var i: usize = 0;
    var face: u32 = 0;
    while (face < 6) : (face += 1) {
        const b = face * 4;
        out[i + 0] = b + 0;
        out[i + 1] = b + 1;
        out[i + 2] = b + 2;
        out[i + 3] = b + 0;
        out[i + 4] = b + 2;
        out[i + 5] = b + 3;
        i += 6;
    }
    return out;
}

/// Horizontal ground plane (Y-up), size = half-extent on XZ.
pub fn planeVertices(half_extent: f32, y: f32) [4]Vertex {
    const e = half_extent;
    const c = [3]f32{ 0.45, 0.47, 0.50 };
    const n = [3]f32{ 0, 1, 0 };
    return .{
        .{ .position = .{ -e, y, -e }, .normal = n, .color = c },
        .{ .position = .{ e, y, -e }, .normal = n, .color = c },
        .{ .position = .{ e, y, e }, .normal = n, .color = c },
        .{ .position = .{ -e, y, e }, .normal = n, .color = c },
    };
}

pub fn planeIndices() [6]u32 {
    // CCW from above (+Y).
    return .{ 0, 2, 1, 0, 3, 2 };
}

test "cube topology" {
    try std.testing.expectEqual(@as(usize, 24), cubeVertices().len);
    try std.testing.expectEqual(@as(usize, 36), cubeIndices().len);
}

test "cube face winding is outward CCW" {
    const verts = cubeVertices();
    const inds = cubeIndices();
    var face: usize = 0;
    while (face < 6) : (face += 1) {
        const ia = inds[face * 6 + 0];
        const ib = inds[face * 6 + 1];
        const ic = inds[face * 6 + 2];
        const a = verts[ia].position;
        const b = verts[ib].position;
        const c = verts[ic].position;
        const e1 = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
        const e2 = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
        const n = [3]f32{
            e1[1] * e2[2] - e1[2] * e2[1],
            e1[2] * e2[0] - e1[0] * e2[2],
            e1[0] * e2[1] - e1[1] * e2[0],
        };
        const center = [3]f32{
            (a[0] + b[0] + c[0]) / 3.0,
            (a[1] + b[1] + c[1]) / 3.0,
            (a[2] + b[2] + c[2]) / 3.0,
        };
        const outward = n[0] * center[0] + n[1] * center[1] + n[2] * center[2];
        try std.testing.expect(outward > 0.0);
    }
}

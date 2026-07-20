const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zm = @import("zmath");
const mesh = @import("mesh.zig");
const shader = @import("shader.zig");
const Camera = @import("camera.zig").Camera;

/// Isolated forward clear+cube path for §1.3 gate evidence (Dagor basic draw role).
/// Does not depend on deferred / shadows / IBL.
pub const BasePass = struct {
    pipeline: zgpu.RenderPipelineHandle = .{},
    bgl: zgpu.BindGroupLayoutHandle = .{},
    bg: zgpu.BindGroupHandle = .{},
    cube: mesh.Mesh = .{ .vertex_buffer = .{}, .index_buffer = .{}, .index_count = 0 },
    triangle: mesh.Mesh = .{ .vertex_buffer = .{}, .index_buffer = .{}, .index_count = 0 },

    pub const Uniforms = extern struct {
        object_to_clip: zm.Mat,
    };

    pub fn create(gctx: *zgpu.GraphicsContext, cache: *shader.Cache) !BasePass {
        var self: BasePass = .{};
        const verts = mesh.cubeVertices();
        // basic.wgsl expects position + color (no normal/uv) — pack compact verts.
        var basic_verts: [24]BasicVertex = undefined;
        for (verts, 0..) |v, i| {
            basic_verts[i] = .{ .position = v.position, .color = v.color };
        }
        const inds = mesh.cubeIndices();
        self.cube = createBasicMesh(gctx, basic_verts[0..], inds[0..]);

        const tri_verts = [_]BasicVertex{
            .{ .position = .{ 0.0, 0.6, 0.0 }, .color = .{ 1, 0.2, 0.2 } },
            .{ .position = .{ -0.6, -0.5, 0.0 }, .color = .{ 0.2, 1, 0.2 } },
            .{ .position = .{ 0.6, -0.5, 0.0 }, .color = .{ 0.2, 0.2, 1 } },
        };
        const tri_inds = [_]u32{ 0, 1, 2 };
        self.triangle = createBasicMesh(gctx, tri_verts[0..], tri_inds[0..]);

        self.bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true }, .uniform, true, 0),
        });
        const pl = gctx.createPipelineLayout(&.{self.bgl});
        defer gctx.releaseResource(pl);

        const module = try cache.getOrLoad("assets/shaders/basic.wgsl");
        defer module.release();

        const attrs = [_]wgpu.VertexAttribute{
            .{ .format = .float32x3, .offset = @offsetOf(BasicVertex, "position"), .shader_location = 0 },
            .{ .format = .float32x3, .offset = @offsetOf(BasicVertex, "color"), .shader_location = 1 },
        };
        const vbufs = [_]wgpu.VertexBufferLayout{.{
            .array_stride = @sizeOf(BasicVertex),
            .attribute_count = attrs.len,
            .attributes = &attrs,
        }};

        self.pipeline = gctx.createRenderPipeline(pl, .{
            .vertex = .{
                .module = module,
                .entry_point = "vs_main",
                .buffer_count = vbufs.len,
                .buffers = &vbufs,
            },
            .primitive = .{
                .front_face = .ccw,
                .cull_mode = .back,
                .topology = .triangle_list,
            },
            .depth_stencil = null,
            .fragment = &wgpu.FragmentState{
                .module = module,
                .entry_point = "fs_main",
                .target_count = 1,
                .targets = &[_]wgpu.ColorTargetState{.{
                    .format = zgpu.GraphicsContext.swapchain_format,
                }},
            },
        });

        self.bg = gctx.createBindGroup(self.bgl, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(Uniforms) },
        });
        return self;
    }

    pub fn destroy(self: *BasePass, gctx: *zgpu.GraphicsContext) void {
        if (gctx.isResourceValid(self.bg)) gctx.releaseResource(self.bg);
        if (gctx.isResourceValid(self.pipeline)) gctx.releaseResource(self.pipeline);
        if (gctx.isResourceValid(self.bgl)) gctx.releaseResource(self.bgl);
        if (gctx.isResourceValid(self.cube.vertex_buffer)) gctx.destroyResource(self.cube.vertex_buffer);
        if (gctx.isResourceValid(self.cube.index_buffer)) gctx.destroyResource(self.cube.index_buffer);
        if (gctx.isResourceValid(self.triangle.vertex_buffer)) gctx.destroyResource(self.triangle.vertex_buffer);
        if (gctx.isResourceValid(self.triangle.index_buffer)) gctx.destroyResource(self.triangle.index_buffer);
        self.* = undefined;
    }

    /// Clear swapchain + draw triangle and cube (present left to caller).
    pub fn draw(
        self: *BasePass,
        gctx: *zgpu.GraphicsContext,
        back_buffer: wgpu.TextureView,
        camera: Camera,
        clear: wgpu.Color,
    ) void {
        const pipeline = gctx.lookupResource(self.pipeline) orelse return;
        const bind_group = gctx.lookupResource(self.bg) orelse return;
        const cube_vb = gctx.lookupResourceInfo(self.cube.vertex_buffer) orelse return;
        const cube_ib = gctx.lookupResourceInfo(self.cube.index_buffer) orelse return;
        const tri_vb = gctx.lookupResourceInfo(self.triangle.vertex_buffer) orelse return;
        const tri_ib = gctx.lookupResourceInfo(self.triangle.index_buffer) orelse return;

        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
            .view = back_buffer,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = clear,
        }};
        const pass = encoder.beginRenderPass(.{
            .color_attachment_count = color_attachments.len,
            .color_attachments = &color_attachments,
        });

        const vp = camera.viewProjectionOwned();
        pass.setPipeline(pipeline);

        // Triangle (slightly forward)
        {
            const world = zm.translation(0, 0, 0.5);
            const object_to_clip = zm.transpose(zm.mul(world, vp));
            const mem = gctx.uniformsAllocate(Uniforms, 1);
            if (mem.slice.len >= 1) {
                mem.slice[0] = .{ .object_to_clip = object_to_clip };
                pass.setBindGroup(0, bind_group, &.{mem.offset});
                pass.setVertexBuffer(0, tri_vb.gpuobj.?, 0, tri_vb.size);
                pass.setIndexBuffer(tri_ib.gpuobj.?, .uint32, 0, tri_ib.size);
                pass.drawIndexed(self.triangle.index_count, 1, 0, 0, 0);
            }
        }
        // Cube
        {
            const world = zm.identity();
            const object_to_clip = zm.transpose(zm.mul(world, vp));
            const mem = gctx.uniformsAllocate(Uniforms, 1);
            if (mem.slice.len >= 1) {
                mem.slice[0] = .{ .object_to_clip = object_to_clip };
                pass.setBindGroup(0, bind_group, &.{mem.offset});
                pass.setVertexBuffer(0, cube_vb.gpuobj.?, 0, cube_vb.size);
                pass.setIndexBuffer(cube_ib.gpuobj.?, .uint32, 0, cube_ib.size);
                pass.drawIndexed(self.cube.index_count, 1, 0, 0, 0);
            }
        }

        pass.end();
        pass.release();

        const commands = encoder.finish(null);
        defer commands.release();
        gctx.submit(&.{commands});
    }
};

const BasicVertex = extern struct {
    position: [3]f32,
    color: [3]f32,
};

fn createBasicMesh(gctx: *zgpu.GraphicsContext, vertices: []const BasicVertex, indices: []const u32) mesh.Mesh {
    const vertex_buffer = gctx.createBuffer(.{
        .usage = .{ .copy_dst = true, .vertex = true },
        .size = vertices.len * @sizeOf(BasicVertex),
    });
    gctx.queue.writeBuffer(gctx.lookupResource(vertex_buffer).?, 0, BasicVertex, vertices);

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

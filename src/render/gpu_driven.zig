const std = @import("std");
const zgpu = @import("zgpu");
const zm = @import("zmath");
const draw_list = @import("draw_list.zig");

pub const max_instances: u32 = 512;
pub const mesh_kind_count: u32 = 2;

/// GPU instance record (row-vector mats = CPU-transposed).
/// Must match WGSL `Instance` in gbuffer/shadow shaders (96 B).
pub const InstanceGpu = extern struct {
    object_to_world: zm.Mat,
    material: [4]f32,
    color: [4]f32,

    comptime {
        if (@sizeOf(InstanceGpu) != 96) @compileError("InstanceGpu must stay 96 bytes (WGSL Instance)");
    }
};

/// WebGPU DrawIndexedIndirect args (20 bytes).
pub const DrawIndexedIndirectArgs = extern struct {
    index_count: u32 = 0,
    instance_count: u32 = 0,
    first_index: u32 = 0,
    base_vertex: u32 = 0,
    first_instance: u32 = 0,
};

pub const Batch = struct {
    mesh: draw_list.MeshKind = .cube,
    /// Byte offset into the instance SSBO for dynamic bind-group offset.
    instance_byte_offset: u32 = 0,
    instance_count: u32 = 0,
    /// Slot in the indirect args buffer.
    indirect_index: u32 = 0,
};

pub const UploadResult = struct {
    batches: [mesh_kind_count]Batch = [_]Batch{.{}} ** mesh_kind_count,
    batch_count: u32 = 0,
    instance_count: u32 = 0,
};

fn meshIndex(kind: draw_list.MeshKind) u32 {
    return switch (kind) {
        .cube => 0,
        .floor => 1,
    };
}

fn meshFromIndex(i: u32) draw_list.MeshKind {
    return switch (i) {
        0 => .cube,
        else => .floor,
    };
}

/// GPU-driven draw path: instance SSBO + indirect args (CPU-filled after frustum cull).
pub const GpuDriven = struct {
    gbuffer_instances: zgpu.BufferHandle = .{},
    gbuffer_indirect: zgpu.BufferHandle = .{},
    shadow_instances: zgpu.BufferHandle = .{},
    shadow_indirect: zgpu.BufferHandle = .{},

    cpu_instances: [max_instances]InstanceGpu = undefined,
    cpu_indirect: [mesh_kind_count]DrawIndexedIndirectArgs = [_]DrawIndexedIndirectArgs{.{}} ** mesh_kind_count,

    gbuffer_upload: UploadResult = .{},
    shadow_upload: UploadResult = .{},

    pub fn create(gctx: *zgpu.GraphicsContext) GpuDriven {
        const inst_size = max_instances * @sizeOf(InstanceGpu);
        const args_size = mesh_kind_count * @sizeOf(DrawIndexedIndirectArgs);
        return .{
            .gbuffer_instances = gctx.createBuffer(.{
                .usage = .{ .copy_dst = true, .storage = true },
                .size = inst_size,
            }),
            .gbuffer_indirect = gctx.createBuffer(.{
                .usage = .{ .copy_dst = true, .indirect = true },
                .size = args_size,
            }),
            .shadow_instances = gctx.createBuffer(.{
                .usage = .{ .copy_dst = true, .storage = true },
                .size = inst_size,
            }),
            .shadow_indirect = gctx.createBuffer(.{
                .usage = .{ .copy_dst = true, .indirect = true },
                .size = args_size,
            }),
        };
    }

    pub fn destroy(self: *GpuDriven, gctx: *zgpu.GraphicsContext) void {
        if (gctx.isResourceValid(self.gbuffer_instances)) gctx.destroyResource(self.gbuffer_instances);
        if (gctx.isResourceValid(self.gbuffer_indirect)) gctx.destroyResource(self.gbuffer_indirect);
        if (gctx.isResourceValid(self.shadow_instances)) gctx.destroyResource(self.shadow_instances);
        if (gctx.isResourceValid(self.shadow_indirect)) gctx.destroyResource(self.shadow_indirect);
        self.* = .{};
    }

    pub fn uploadGBuffer(
        self: *GpuDriven,
        gctx: *zgpu.GraphicsContext,
        items: []const draw_list.DrawItem,
        index_counts: [mesh_kind_count]u32,
    ) void {
        self.gbuffer_upload = self.packItems(items, index_counts);
        self.flush(gctx, self.gbuffer_instances, self.gbuffer_indirect, self.gbuffer_upload);
    }

    pub fn uploadShadows(
        self: *GpuDriven,
        gctx: *zgpu.GraphicsContext,
        renderables: []const draw_list.Renderable,
        index_counts: [mesh_kind_count]u32,
        cascade_vps: []const zm.Mat,
    ) void {
        var scratch: [max_instances]draw_list.DrawItem = undefined;
        var n: u32 = 0;
        for (renderables) |r| {
            if (!r.cast_shadow) continue;
            if (n >= max_instances) break;
            // Cull casters that miss every cascade light frustum (Dagor cascade cull role).
            if (cascade_vps.len > 0 and !intersectsAnyCascade(r, cascade_vps)) continue;
            scratch[n] = .{
                .renderable_index = n,
                .mesh = r.mesh,
                .object_to_world = r.transform,
                .material = r.material,
                .color = r.color,
                .cast_shadow = true,
            };
            n += 1;
        }
        self.shadow_upload = self.packItems(scratch[0..n], index_counts);
        self.flush(gctx, self.shadow_instances, self.shadow_indirect, self.shadow_upload);
    }

    fn intersectsAnyCascade(r: draw_list.Renderable, cascade_vps: []const zm.Mat) bool {
        // Unit-ish mesh radius in local space; transform scale approx from matrix columns.
        const m = r.transform;
        const sx = @sqrt(m[0][0] * m[0][0] + m[0][1] * m[0][1] + m[0][2] * m[0][2]);
        const sy = @sqrt(m[1][0] * m[1][0] + m[1][1] * m[1][1] + m[1][2] * m[1][2]);
        const sz = @sqrt(m[2][0] * m[2][0] + m[2][1] * m[2][1] + m[2][2] * m[2][2]);
        const radius = 0.75 * @max(sx, @max(sy, sz));
        const cx = m[3][0];
        const cy = m[3][1];
        const cz = m[3][2];
        for (cascade_vps) |vp| {
            const clip = zm.mul(zm.f32x4(cx, cy, cz, 1), vp);
            const w = @max(@abs(clip[3]), 0.0001);
            const ndc_x = clip[0] / w;
            const ndc_y = clip[1] / w;
            const ndc_z = clip[2] / w;
            // Inflate NDC by projected sphere approx.
            const pad = radius / w;
            if (ndc_x >= -1.0 - pad and ndc_x <= 1.0 + pad and
                ndc_y >= -1.0 - pad and ndc_y <= 1.0 + pad and
                ndc_z >= -0.1 - pad and ndc_z <= 1.0 + pad)
            {
                return true;
            }
        }
        return false;
    }

    fn packItems(
        self: *GpuDriven,
        items: []const draw_list.DrawItem,
        index_counts: [mesh_kind_count]u32,
    ) UploadResult {
        var counts = [_]u32{0} ** mesh_kind_count;
        for (items) |it| {
            counts[meshIndex(it.mesh)] += 1;
        }

        var offsets = [_]u32{0} ** mesh_kind_count;
        var running: u32 = 0;
        for (0..mesh_kind_count) |i| {
            offsets[i] = running;
            running += counts[i];
        }

        var write = offsets;
        var total: u32 = 0;
        for (items) |it| {
            if (total >= max_instances) break;
            const mi = meshIndex(it.mesh);
            const dst = write[mi];
            write[mi] += 1;
            self.cpu_instances[dst] = .{
                .object_to_world = zm.transpose(it.object_to_world),
                .material = it.material,
                .color = .{ it.color[0], it.color[1], it.color[2], 1 },
            };
            total += 1;
        }

        var result: UploadResult = .{ .instance_count = total };
        var bi: u32 = 0;
        for (0..mesh_kind_count) |i| {
            if (counts[i] == 0) continue;
            const first = offsets[i];
            result.batches[bi] = .{
                .mesh = meshFromIndex(@intCast(i)),
                .instance_byte_offset = first * @sizeOf(InstanceGpu),
                .instance_count = counts[i],
                .indirect_index = bi,
            };
            self.cpu_indirect[bi] = .{
                .index_count = index_counts[i],
                .instance_count = counts[i],
                .first_index = 0,
                .base_vertex = 0,
                .first_instance = first,
            };
            bi += 1;
        }
        result.batch_count = bi;
        while (bi < mesh_kind_count) : (bi += 1) {
            self.cpu_indirect[bi] = .{};
        }
        return result;
    }

    fn flush(
        self: *GpuDriven,
        gctx: *zgpu.GraphicsContext,
        instance_buf: zgpu.BufferHandle,
        indirect_buf: zgpu.BufferHandle,
        upload: UploadResult,
    ) void {
        if (upload.instance_count > 0) {
            gctx.queue.writeBuffer(
                gctx.lookupResource(instance_buf).?,
                0,
                InstanceGpu,
                self.cpu_instances[0..upload.instance_count],
            );
        }
        gctx.queue.writeBuffer(
            gctx.lookupResource(indirect_buf).?,
            0,
            DrawIndexedIndirectArgs,
            self.cpu_indirect[0..],
        );
    }
};

test "pack batches by mesh kind" {
    var gd: GpuDriven = .{};
    const items = [_]draw_list.DrawItem{
        .{ .renderable_index = 0, .mesh = .cube, .object_to_world = zm.translation(1, 0, 0), .material = .{ 0.1, 0.2, 1, 1 }, .color = .{ 1, 0, 0 }, .cast_shadow = true },
        .{ .renderable_index = 1, .mesh = .floor, .object_to_world = zm.identity(), .material = .{ 0, 0.8, 1, 1 }, .color = .{ 0.5, 0.5, 0.5 }, .cast_shadow = true },
        .{ .renderable_index = 2, .mesh = .cube, .object_to_world = zm.translation(2, 0, 0), .material = .{ 0.2, 0.3, 1, 1 }, .color = .{ 0, 1, 0 }, .cast_shadow = true },
    };
    const result = gd.packItems(&items, .{ 36, 6 });
    try std.testing.expectEqual(@as(u32, 3), result.instance_count);
    try std.testing.expectEqual(@as(u32, 2), result.batch_count);
    try std.testing.expectEqual(@as(u32, 2), gd.cpu_indirect[0].instance_count);
    try std.testing.expectEqual(@as(u32, 1), gd.cpu_indirect[1].instance_count);
}

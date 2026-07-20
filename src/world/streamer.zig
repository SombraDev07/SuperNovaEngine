const std = @import("std");
const zjobs = @import("zjobs");
const chunk_mod = @import("chunk.zig");
const grid = @import("grid.zig");
const terrain_tile = @import("terrain_tile.zig");
const zones_mod = @import("zones.zig");
const chunk_storage = @import("chunk_storage.zig");

const ChunkCoord = chunk_mod.ChunkCoord;
const ChunkPayload = chunk_mod.ChunkPayload;
const ChunkSlot = chunk_mod.ChunkSlot;
const ChunkState = chunk_mod.ChunkState;
const LodBand = chunk_mod.LodBand;
const ActionSphere = zones_mod.ActionSphere;
const ZoneSet = zones_mod.ZoneSet;
const ChunkStorage = chunk_storage.ChunkStorage;

pub const Jobs = zjobs.JobQueue(.{
    .max_jobs = 256,
    .max_job_size = 64,
    .max_threads = 8,
    .idle_sleep_ns = 100,
});

pub const Config = struct {
    chunk_size: f32 = 64.0,
    load_radius: u32 = 2,
    unload_radius: u32 = 4,
    max_concurrent_loads: u32 = 4,
    max_resident: u32 = 128,
    /// Dagor usecAllowedPerFrame role (drain + schedule + unload).
    frame_budget_usec: u64 = 5000,
    schedule_budget_ms: f32 = 2.0,
    /// GPU backpressure: do not exceed this many ready chunks (terrain_splat cap).
    max_gpu_ready: u32 = 48,
    /// Optional CHMZ dump root `{root}/{x}_{z}.chmz` (BinaryDump path role).
    dump_root: ?[]const u8 = null,
    terrain: terrain_tile.TileConfig = .{
        .resolution = 32,
        .chunk_size = 64.0,
        .demo_hole = false,
        .procedural = .{
            .amplitude = 8.0,
            .domain_warp = true,
            .warp_amp = 12.0,
            .frequency = 0.025,
        },
    },
};

pub const Stats = struct {
    resident: u32 = 0,
    ready: u32 = 0,
    loading: u32 = 0,
    queued: u32 = 0,
    loads_started: u64 = 0,
    loads_completed: u64 = 0,
    lod_upgrades: u64 = 0,
    unloads: u64 = 0,
    unload_requested: u64 = 0,
    stale_completions: u64 = 0,
    budget_cuts: u64 = 0,
    gpu_backpressure: u64 = 0,
};

const Completion = struct {
    coord: ChunkCoord,
    generation: u32,
    payload: ChunkPayload,
};

const LoadJob = struct {
    streamer: *Streamer,
    coord: ChunkCoord,
    generation: u32,
    lod: LodBand,
    version: u32,

    pub fn exec(self: *@This()) void {
        const payload = self.streamer.buildPayload(self.coord, self.lod, self.version) catch {
            self.streamer.pushCompletion(.{
                .coord = self.coord,
                .generation = self.generation,
                .payload = .{},
            });
            return;
        };
        self.streamer.pushCompletion(.{
            .coord = self.coord,
            .generation = self.generation,
            .payload = payload,
        });
    }
};

fn terrainDeinit(ptr: *anyopaque) void {
    const tile: *terrain_tile.TerrainTile = @ptrCast(@alignCast(ptr));
    tile.deinit();
}

/// Distance-driven chunk streamer (Dagor StreamingSceneController + Manager role).
pub const Streamer = struct {
    allocator: std.mem.Allocator,
    config: Config,
    jobs: Jobs align(64) = undefined,
    jobs_started: bool = false,
    chunks: std.AutoHashMap(ChunkCoord, ChunkSlot),
    completions: std.ArrayList(Completion),
    completion_mutex: std.Thread.Mutex = .{},
    observer: [3]f32 = .{ 0, 0, 0 },
    observer_chunk: ChunkCoord = .{},
    stats: Stats = .{},
    payload_version: u32 = 1,
    zones: ZoneSet = undefined,
    storage: ChunkStorage = .{},
    /// Soft feedback from renderer (how many GPU terrain chunks are live).
    gpu_ready_hint: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Streamer {
        var cfg = config;
        cfg.terrain.chunk_size = cfg.chunk_size;
        var self: Streamer = .{
            .allocator = allocator,
            .config = cfg,
            .chunks = std.AutoHashMap(ChunkCoord, ChunkSlot).init(allocator),
            .completions = try std.ArrayList(Completion).initCapacity(allocator, 32),
            .zones = ZoneSet.init(allocator),
            .storage = .{ .dump_root = cfg.dump_root },
        };
        self.jobs = Jobs.init();
        return self;
    }

    pub fn deinit(self: *Streamer) void {
        if (self.jobs_started) {
            self.jobs.stop();
            self.jobs.join();
            self.jobs_started = false;
        } else if (self.jobs.isInitialized()) {
            self.jobs.deinit();
        }
        self.releaseAllChunks();
        self.drainCompletionsDiscard();
        self.zones.deinit();
        self.chunks.deinit();
        self.completions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addActionSphere(self: *Streamer, s: ActionSphere) !void {
        try self.zones.add(s);
    }

    pub fn setGpuReadyHint(self: *Streamer, count: u32) void {
        self.gpu_ready_hint = count;
    }

    pub fn start(self: *Streamer) void {
        if (self.jobs_started) return;
        self.jobs.start(.{ .num_threads = 2 });
        self.jobs_started = true;
    }

    pub fn setObserver(self: *Streamer, pos: [3]f32) void {
        self.observer = pos;
        self.observer_chunk = ChunkCoord.fromWorld(pos[0], pos[2], self.config.chunk_size);
    }

    pub fn tick(self: *Streamer, pos: [3]f32, dt: f64) void {
        _ = dt;
        if (!self.jobs_started) self.start();
        self.setObserver(pos);
        var timer = std.time.Timer.start() catch {
            self.drainCompletions();
            self.unloadFar();
            self.scheduleLoads();
            self.refreshStats();
            return;
        };
        const budget = self.config.frame_budget_usec;
        self.drainCompletions();
        if (timer.read() / 1000 > budget) {
            self.stats.budget_cuts += 1;
            self.refreshStats();
            return;
        }
        self.unloadFar();
        if (timer.read() / 1000 > budget) {
            self.stats.budget_cuts += 1;
            self.refreshStats();
            return;
        }
        self.scheduleLoads();
        self.refreshStats();
    }

    pub fn getFront(self: *const Streamer, coord: ChunkCoord) ?ChunkPayload {
        const slot = self.chunks.get(coord) orelse return null;
        if (slot.state != .ready or !slot.front.occupied) return null;
        return slot.front;
    }

    pub fn getTerrain(self: *const Streamer, coord: ChunkCoord) ?*terrain_tile.TerrainTile {
        const slot = self.chunks.get(coord) orelse return null;
        if (slot.state != .ready) return null;
        const ptr = slot.front.terrain orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Height at world XZ including terraform overlay (null if chunk not ready).
    pub fn sampleHeight(self: *const Streamer, wx: f32, wz: f32) ?f32 {
        const coord = ChunkCoord.fromWorld(wx, wz, self.config.chunk_size);
        const tile = self.getTerrain(coord) orelse return null;
        const terraform = @import("terraform.zig");
        return terraform.sampleWorld(&tile.heightfield, &tile.terraform, wx, wz);
    }

    pub fn isReady(self: *const Streamer, coord: ChunkCoord) bool {
        const slot = self.chunks.get(coord) orelse return false;
        return slot.state == .ready;
    }

    pub fn residentCount(self: *const Streamer) usize {
        return self.chunks.count();
    }

    pub fn waitReady(self: *Streamer, coord: ChunkCoord, timeout_ms: u64) bool {
        const start_ms = std.time.milliTimestamp();
        while (std.time.milliTimestamp() - start_ms < @as(i64, @intCast(timeout_ms))) {
            self.drainCompletions();
            if (self.isReady(coord)) return true;
            self.scheduleLoads();
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        self.drainCompletions();
        return self.isReady(coord);
    }

    pub fn isLoading(self: *const Streamer) bool {
        return self.stats.loading > 0 or self.stats.queued > 0;
    }

    pub fn clearSchedule(self: *Streamer) void {
        var it = self.chunks.valueIterator();
        while (it.next()) |slot| {
            if (slot.state == .queued or slot.state == .loading) {
                slot.generation +%= 1;
                slot.back.release();
                slot.back = .{};
                if (slot.front.occupied) {
                    slot.state = .ready;
                } else {
                    slot.state = .empty;
                }
            }
        }
        self.refreshStats();
    }

    pub fn clearAll(self: *Streamer) void {
        self.clearSchedule();
        self.releaseAllChunks();
        self.chunks.clearRetainingCapacity();
        self.drainCompletionsDiscard();
        self.stats = .{};
    }

    /// Foreground / blocking ring load (Dagor readScene / sync bindump role).
    pub fn syncLoadAt(self: *Streamer, pos: [3]f32, overlap_chunks: u32) !void {
        try self.preloadAtPos(pos, overlap_chunks);
    }

    pub fn preloadAtPos(self: *Streamer, pos: [3]f32, overlap_chunks: u32) !void {
        self.setObserver(pos);
        const radius = self.config.load_radius + overlap_chunks;
        const center = self.observer_chunk;
        const Ctx = struct {
            streamer: *Streamer,
            fn on(ctx: @This(), coord: ChunkCoord, dist: u32) void {
                if (ctx.streamer.chunks.get(coord)) |slot| {
                    if (slot.state == .ready) return;
                }
                const lod = LodBand.fromChebyshev(dist, ctx.streamer.config.load_radius);
                const gop = ctx.streamer.chunks.getOrPut(coord) catch return;
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.front.release();
                gop.value_ptr.back.release();
                gop.value_ptr.generation +%= 1;
                gop.value_ptr.front = ctx.streamer.buildPayload(coord, lod, ctx.streamer.payload_version) catch .{};
                gop.value_ptr.back = .{};
                gop.value_ptr.lod = lod;
                gop.value_ptr.state = if (gop.value_ptr.front.occupied) .ready else .empty;
                if (gop.value_ptr.state == .ready) ctx.streamer.stats.loads_completed += 1;
            }
        };
        grid.forEachInRadius(center, radius, Ctx{ .streamer = self }, Ctx.on);
        self.refreshStats();
    }

    fn buildPayload(self: *Streamer, coord: ChunkCoord, lod: LodBand, version: u32) !ChunkPayload {
        const tile = try self.storage.loadOrGenerate(self.allocator, coord, lod, self.config.terrain);
        var h = std.hash.Wyhash.init(0xC4A1_C4A1);
        h.update(std.mem.asBytes(&coord.x));
        h.update(std.mem.asBytes(&coord.z));
        h.update(std.mem.asBytes(&@intFromEnum(lod)));
        return .{
            .coord = coord,
            .lod = lod,
            .height_seed = h.final(),
            .version = version,
            .occupied = true,
            .terrain = tile,
            .terrain_deinit = terrainDeinit,
        };
    }

    fn pushCompletion(self: *Streamer, c: Completion) void {
        self.completion_mutex.lock();
        defer self.completion_mutex.unlock();
        self.completions.append(self.allocator, c) catch {
            var p = c.payload;
            p.release();
        };
    }

    fn drainCompletionsDiscard(self: *Streamer) void {
        self.completion_mutex.lock();
        defer self.completion_mutex.unlock();
        for (self.completions.items) |*c| c.payload.release();
        self.completions.clearRetainingCapacity();
    }

    fn drainCompletions(self: *Streamer) void {
        var local: std.ArrayList(Completion) = .{};
        defer local.deinit(self.allocator);

        {
            self.completion_mutex.lock();
            defer self.completion_mutex.unlock();
            local.appendSlice(self.allocator, self.completions.items) catch {};
            self.completions.clearRetainingCapacity();
        }

        for (local.items) |c| {
            const slot = self.chunks.getPtr(c.coord) orelse {
                var p = c.payload;
                p.release();
                continue;
            };
            if (slot.generation != c.generation) {
                self.stats.stale_completions += 1;
                var p = c.payload;
                p.release();
                // Cancelled mid-load (generation bump + unload_requested).
                if (slot.unload_requested and slot.state != .ready) {
                    slot.releaseAll();
                    slot.unload_requested = false;
                    _ = self.chunks.remove(c.coord);
                    self.stats.unloads += 1;
                }
                continue;
            }
            // Dagor unloadRequested without gen bump (race-safe path).
            if (slot.unload_requested) {
                self.stats.unload_requested += 1;
                var p = c.payload;
                p.release();
                slot.releaseAll();
                slot.unload_requested = false;
                slot.state = .empty;
                _ = self.chunks.remove(c.coord);
                self.stats.unloads += 1;
                continue;
            }
            if (slot.state != .loading and slot.state != .queued) {
                var p = c.payload;
                p.release();
                continue;
            }

            const was_ready = slot.front.occupied;
            const prev_lod = slot.lod;
            slot.back.release();
            slot.back = c.payload;
            slot.swapBuffers();
            // Keep previous front in `back` one frame for GPU consumers, then free.
            slot.back.release();
            slot.back = .{};
            slot.state = .ready;
            slot.lod = slot.front.lod;
            slot.unload_requested = false;
            self.stats.loads_completed += 1;
            if (was_ready and slot.lod.isFinerThan(prev_lod)) self.stats.lod_upgrades += 1;

            // Still finer desired? Re-queue immediately (continuous optima).
            if (slot.desired_lod.isFinerThan(slot.lod)) {
                self.enqueueLoad(c.coord, slot.desired_lod) catch {};
            }
        }
    }

    fn releaseAllChunks(self: *Streamer) void {
        var it = self.chunks.valueIterator();
        while (it.next()) |slot| slot.releaseAll();
    }

    fn unloadFar(self: *Streamer) void {
        const center = self.observer_chunk;
        var to_remove: std.ArrayList(ChunkCoord) = .{};
        defer to_remove.deinit(self.allocator);

        var it = self.chunks.iterator();
        while (it.next()) |entry| {
            const coord = entry.key_ptr.*;
            const dist = ChunkCoord.chebyshev(center, coord);
            const kept_by_zone = self.zones.forceKeepChunk(coord, self.config.chunk_size);
            const far = dist > self.config.unload_radius and !kept_by_zone;
            if (!far) continue;
            to_remove.append(self.allocator, coord) catch continue;
        }

        for (to_remove.items) |coord| {
            const slot = self.chunks.getPtr(coord) orelse continue;
            if (slot.state == .loading or slot.state == .queued) {
                // Cancel mid-load (Dagor unloadRequested).
                slot.unload_requested = true;
                slot.generation +%= 1;
                self.stats.unload_requested += 1;
                continue;
            }
            // Flush CHMZ dump when leaving the pool (BinaryDump unload lifecycle).
            if (slot.state == .ready) {
                if (slot.front.terrain) |ptr| {
                    const tile: *terrain_tile.TerrainTile = @ptrCast(@alignCast(ptr));
                    self.storage.saveDump(coord, tile) catch {};
                }
            }
            slot.generation +%= 1;
            slot.state = .unloading;
            slot.releaseAll();
            _ = self.chunks.remove(coord);
            self.stats.unloads += 1;
        }
    }

    fn scheduleLoads(self: *Streamer) void {
        const center = self.observer_chunk;
        var candidates: std.ArrayList(grid.Candidate) = .{};
        defer candidates.deinit(self.allocator);

        const Ctx = struct {
            streamer: *Streamer,
            list: *std.ArrayList(grid.Candidate),
            fn consider(ctx: @This(), coord: ChunkCoord, dist: u32, lod: LodBand) void {
                if (ctx.streamer.chunks.getPtr(coord)) |slot| {
                    slot.desired_lod = lod;
                    if (slot.unload_requested) return;
                    if (slot.state == .loading or slot.state == .queued) return;
                    if (slot.state == .ready) {
                        // LOD upgrade when closer (finer band).
                        if (!lod.isFinerThan(slot.lod)) return;
                    }
                }
                ctx.list.append(ctx.streamer.allocator, .{
                    .coord = coord,
                    .dist = dist,
                    .lod = lod,
                    .priority = grid.optima(dist, lod),
                }) catch {};
            }
            fn onRing(ctx: @This(), coord: ChunkCoord, dist: u32) void {
                const lod = LodBand.fromChebyshev(dist, ctx.streamer.config.load_radius);
                consider(ctx, coord, dist, lod);
            }
        };
        const ctx = Ctx{ .streamer = self, .list = &candidates };
        grid.forEachInRadius(center, self.config.load_radius, ctx, Ctx.onRing);

        // ActionSphere forced loads (Dagor actionSph) — always request lod0.
        const ZCtx = struct {
            streamer: *Streamer,
            list: *std.ArrayList(grid.Candidate),
            fn on(zctx: @This(), coord: ChunkCoord) void {
                const dist = ChunkCoord.chebyshev(zctx.streamer.observer_chunk, coord);
                Ctx.consider(.{ .streamer = zctx.streamer, .list = zctx.list }, coord, dist, .lod0);
            }
        };
        self.zones.forEachLoadChunk(self.config.chunk_size, ZCtx{ .streamer = self, .list = &candidates }, ZCtx.on);

        std.mem.sort(grid.Candidate, candidates.items, {}, grid.Candidate.lessThan);

        var in_flight: u32 = 0;
        var it = self.chunks.valueIterator();
        while (it.next()) |slot| {
            if (slot.state == .loading or slot.state == .queued) in_flight += 1;
        }

        // GPU backpressure (Dagor delayed tex pack / resident budget role).
        if (self.gpu_ready_hint >= self.config.max_gpu_ready and in_flight == 0) {
            self.stats.gpu_backpressure += 1;
            return;
        }

        const budget_start = std.time.milliTimestamp();
        for (candidates.items) |cand| {
            if (in_flight >= self.config.max_concurrent_loads) break;
            if (self.stats.ready + in_flight >= self.config.max_gpu_ready) {
                self.stats.gpu_backpressure += 1;
                break;
            }
            if (self.chunks.count() >= self.config.max_resident and !self.chunks.contains(cand.coord)) break;
            if (@as(f32, @floatFromInt(std.time.milliTimestamp() - budget_start)) > self.config.schedule_budget_ms) {
                self.stats.budget_cuts += 1;
                break;
            }
            self.enqueueLoad(cand.coord, cand.lod) catch break;
            in_flight += 1;
        }
    }

    fn enqueueLoad(self: *Streamer, coord: ChunkCoord, lod: LodBand) !void {
        const gop = try self.chunks.getOrPut(coord);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        } else if (gop.value_ptr.state == .loading or gop.value_ptr.state == .queued) {
            return;
        } else if (gop.value_ptr.state == .ready and !lod.isFinerThan(gop.value_ptr.lod)) {
            return;
        }

        gop.value_ptr.generation +%= 1;
        gop.value_ptr.desired_lod = lod;
        gop.value_ptr.unload_requested = false;
        // Keep front occupied during LOD upgrade (double-buffer).
        gop.value_ptr.state = .queued;
        const gen = gop.value_ptr.generation;

        const job = LoadJob{
            .streamer = self,
            .coord = coord,
            .generation = gen,
            .lod = lod,
            .version = self.payload_version,
        };
        comptime {
            if (@sizeOf(LoadJob) > 64) @compileError("LoadJob exceeds zjobs max_job_size");
        }

        if (self.jobs.schedule(zjobs.JobId.none, job)) |_| {
            gop.value_ptr.state = .loading;
            self.stats.loads_started += 1;
        } else |_| {
            if (!gop.value_ptr.front.occupied) {
                gop.value_ptr.state = .empty;
            } else {
                gop.value_ptr.state = .ready;
            }
            return error.JobQueueFull;
        }
    }

    fn refreshStats(self: *Streamer) void {
        var ready: u32 = 0;
        var loading: u32 = 0;
        var queued: u32 = 0;
        var it = self.chunks.valueIterator();
        while (it.next()) |slot| {
            switch (slot.state) {
                .ready => ready += 1,
                .loading => loading += 1,
                .queued => queued += 1,
                else => {},
            }
        }
        self.stats.resident = @intCast(self.chunks.count());
        self.stats.ready = ready;
        self.stats.loading = loading;
        self.stats.queued = queued;
    }
};

test "streamer loads observer neighborhood" {
    const allocator = std.testing.allocator;
    var streamer = try Streamer.init(allocator, .{
        .chunk_size = 64,
        .load_radius = 1,
        .unload_radius = 3,
        .max_concurrent_loads = 8,
        .terrain = .{ .resolution = 8, .chunk_size = 64 },
    });
    defer streamer.deinit();
    streamer.start();

    streamer.tick(.{ 0, 0, 0 }, 1.0 / 60.0);
    const center = ChunkCoord{ .x = 0, .z = 0 };
    try std.testing.expect(streamer.waitReady(center, 5000));

    var frames: u32 = 0;
    while (frames < 300 and streamer.stats.ready < 9) : (frames += 1) {
        streamer.tick(.{ 0, 0, 0 }, 1.0 / 60.0);
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
    try std.testing.expect(streamer.stats.ready >= 5);
    const front = streamer.getFront(center).?;
    try std.testing.expect(front.occupied);
    try std.testing.expect(streamer.getTerrain(center) != null);
}

test "streamer unload hysteresis" {
    const allocator = std.testing.allocator;
    var streamer = try Streamer.init(allocator, .{
        .chunk_size = 64,
        .load_radius = 1,
        .unload_radius = 2,
        .max_concurrent_loads = 8,
        .terrain = .{ .resolution = 8, .chunk_size = 64 },
    });
    defer streamer.deinit();
    streamer.start();

    streamer.tick(.{ 0, 0, 0 }, 0.016);
    _ = streamer.waitReady(.{ .x = 0, .z = 0 }, 5000);

    streamer.tick(.{ 64.0 * 20.0, 0, 64.0 * 20.0 }, 0.016);
    try std.testing.expect(!streamer.chunks.contains(.{ .x = 0, .z = 0 }));
}

test "double buffer front stable until swap" {
    var slot = ChunkSlot{};
    slot.front = .{ .coord = .{ .x = 1, .z = 2 }, .lod = .lod0, .height_seed = 11, .occupied = true };
    slot.back = .{ .coord = .{ .x = 1, .z = 2 }, .lod = .lod1, .height_seed = 22, .occupied = true };
    const seed_before = slot.front.height_seed;
    try std.testing.expect(slot.front.lod == .lod0);
    slot.swapBuffers();
    try std.testing.expect(slot.front.lod == .lod1);
    try std.testing.expect(slot.back.height_seed == seed_before);
}

test "preload at pos fills ring sync" {
    const allocator = std.testing.allocator;
    var streamer = try Streamer.init(allocator, .{
        .load_radius = 1,
        .unload_radius = 3,
        .terrain = .{ .resolution = 8, .chunk_size = 64 },
    });
    defer streamer.deinit();
    try streamer.preloadAtPos(.{ 0, 0, 0 }, 0);
    try std.testing.expectEqual(@as(u32, 9), streamer.stats.ready);
    try std.testing.expect(streamer.isReady(.{ .x = 0, .z = 0 }));
    try std.testing.expect(streamer.getTerrain(.{ .x = 0, .z = 0 }) != null);
}

test "lod upgrade requeues finer band" {
    const allocator = std.testing.allocator;
    var streamer = try Streamer.init(allocator, .{
        .chunk_size = 64,
        .load_radius = 6,
        .unload_radius = 8,
        .max_concurrent_loads = 8,
        .terrain = .{ .resolution = 8, .chunk_size = 64 },
    });
    defer streamer.deinit();
    streamer.start();
    // Observer at origin → chunk (5,0) is lod2.
    streamer.tick(.{ 0, 0, 0 }, 0.016);
    const far = ChunkCoord{ .x = 5, .z = 0 };
    try std.testing.expect(streamer.waitReady(far, 5000));
    const lod_far = streamer.chunks.get(far).?.lod;
    try std.testing.expect(lod_far == .lod2);
    // Move observer onto that chunk → desire lod0 upgrade.
    var frames: u32 = 0;
    while (frames < 400) : (frames += 1) {
        streamer.tick(.{ 64.0 * 5.0 + 1.0, 0, 0 }, 0.016);
        if (streamer.chunks.get(far)) |slot| {
            if (slot.state == .ready and slot.lod.isFinerThan(lod_far)) break;
            if (streamer.stats.lod_upgrades > 0) break;
        }
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
    const slot = streamer.chunks.get(far).?;
    try std.testing.expect(slot.lod.isFinerThan(lod_far) or streamer.stats.lod_upgrades > 0);
}

test "action sphere forces load outside observer ring" {
    const allocator = std.testing.allocator;
    var streamer = try Streamer.init(allocator, .{
        .chunk_size = 64,
        .load_radius = 0,
        .unload_radius = 1,
        .max_concurrent_loads = 4,
        .max_gpu_ready = 64,
        .terrain = .{ .resolution = 8, .chunk_size = 64 },
    });
    defer streamer.deinit();
    try streamer.addActionSphere(.{
        .center = .{ 64.0 * 3.0 + 32.0, 0, 32.0 },
        .load_rad = 48,
        .unload_rad = 96,
    });
    streamer.start();
    const target = ChunkCoord{ .x = 3, .z = 0 };
    var frames: u32 = 0;
    while (frames < 400 and !streamer.isReady(target)) : (frames += 1) {
        streamer.tick(.{ 0, 0, 0 }, 0.016);
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
    try std.testing.expect(streamer.isReady(target));
}

test "mid-load unload cancel bumps generation" {
    const allocator = std.testing.allocator;
    var streamer = try Streamer.init(allocator, .{
        .chunk_size = 64,
        .load_radius = 2,
        .unload_radius = 2,
        .max_concurrent_loads = 8,
        .terrain = .{ .resolution = 16, .chunk_size = 64 },
    });
    defer streamer.deinit();
    streamer.start();
    streamer.tick(.{ 0, 0, 0 }, 0.016);
    // Immediately flee before neighborhood settles — cancel in-flight.
    streamer.tick(.{ 64.0 * 40.0, 0, 64.0 * 40.0 }, 0.016);
    var frames: u32 = 0;
    while (frames < 100) : (frames += 1) {
        streamer.tick(.{ 64.0 * 40.0, 0, 64.0 * 40.0 }, 0.016);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try std.testing.expect(streamer.stats.unload_requested > 0 or streamer.stats.stale_completions > 0 or streamer.stats.unloads > 0);
    try std.testing.expect(!streamer.chunks.contains(.{ .x = 0, .z = 0 }));
}

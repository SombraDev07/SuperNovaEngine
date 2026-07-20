const std = @import("std");

/// Generation-safe entity id (daECS EntityId role).
pub const EntityId = packed struct(u32) {
    index: u20 = 0,
    generation: u12 = 0,

    pub const invalid: EntityId = .{ .index = 0, .generation = 0 };

    pub fn eql(a: EntityId, b: EntityId) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }
};

pub const UpdateStage = enum(u8) {
    act = 0,
    before_render = 1,
    render = 2,
    user = 3,
};

pub const ComponentId = enum(u8) {
    transform = 0,
    velocity = 1,
    name_tag = 2,
    tag = 3,
    _,
};

pub const component_count = 4;

pub const Transform = extern struct {
    position: [3]f32 = .{ 0, 0, 0 },
    rotation_y: f32 = 0,
};

pub const Velocity = extern struct {
    linear: [3]f32 = .{ 0, 0, 0 },
};

pub const NameTag = extern struct {
    bytes: [32]u8 = .{0} ** 32,
    len: u8 = 0,

    pub fn set(self: *NameTag, name: []const u8) void {
        const n = @min(name.len, self.bytes.len);
        @memcpy(self.bytes[0..n], name[0..n]);
        self.len = @intCast(n);
        if (n < self.bytes.len) @memset(self.bytes[n..], 0);
    }

    pub fn slice(self: *const NameTag) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Tag = extern struct {
    id: u32 = 0,
};

pub const ArchetypeMask = u32;

pub fn componentBit(id: ComponentId) ArchetypeMask {
    return @as(ArchetypeMask, 1) << @as(u5, @intCast(@intFromEnum(id)));
}

pub const CoreEvent = union(enum) {
    entity_created: EntityId,
    entity_destroyed: EntityId,
    component_changed: struct { entity: EntityId, component: ComponentId },
    manager_before_clear: void,
    manager_after_clear: void,
};

pub const EventListener = *const fn (ctx: ?*anyopaque, event: CoreEvent) void;

const EventBinding = struct {
    ctx: ?*anyopaque,
    callback: EventListener,
};

pub const ComponentsInit = struct {
    transform: ?Transform = null,
    velocity: ?Velocity = null,
    name: ?[]const u8 = null,
    tag: ?Tag = null,

    pub fn mask(self: ComponentsInit) ArchetypeMask {
        var m: ArchetypeMask = 0;
        if (self.transform != null) m |= componentBit(.transform);
        if (self.velocity != null) m |= componentBit(.velocity);
        if (self.name != null) m |= componentBit(.name_tag);
        if (self.tag != null) m |= componentBit(.tag);
        return m;
    }
};

const TemplateDef = struct {
    name: []const u8,
    mask: ArchetypeMask,
    transform: Transform = .{},
    velocity: Velocity = .{},
    name_tag: NameTag = .{},
    tag: Tag = .{},
};

const Archetype = struct {
    mask: ArchetypeMask,
    entities: std.ArrayList(EntityId) = .{},
    transforms: std.ArrayList(Transform) = .{},
    velocities: std.ArrayList(Velocity) = .{},
    names: std.ArrayList(NameTag) = .{},
    tags: std.ArrayList(Tag) = .{},

    fn deinit(self: *Archetype, allocator: std.mem.Allocator) void {
        self.entities.deinit(allocator);
        self.transforms.deinit(allocator);
        self.velocities.deinit(allocator);
        self.names.deinit(allocator);
        self.tags.deinit(allocator);
    }

    fn len(self: *const Archetype) usize {
        return self.entities.items.len;
    }
};

const EntityRec = struct {
    generation: u12 = 1,
    alive: bool = false,
    archetype: ArchetypeMask = 0,
    index: u32 = 0,
    template_name: ?[]const u8 = null,
};

pub const SystemFn = *const fn (mgr: *EntityManager, stage: UpdateStage, dt: f64) void;

const SystemEntry = struct {
    stage: UpdateStage,
    priority: i32,
    name: []const u8,
    callback: SystemFn,
};

const DeferredCreate = struct {
    template: []const u8,
    init: ComponentsInit,
};

/// Entity manager (daECS EntityManager bootstrap role for §1.2).
pub const EntityManager = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(EntityRec) = .{},
    free_indices: std.ArrayList(u20) = .{},
    archetypes: std.AutoHashMap(ArchetypeMask, Archetype),
    templates: std.StringHashMap(TemplateDef),
    systems: std.ArrayList(SystemEntry) = .{},
    listeners: std.ArrayList(EventBinding) = .{},
    deferred: std.ArrayList(DeferredCreate) = .{},
    singletons: std.StringHashMap(EntityId),
    created_this_tick: std.ArrayList(EntityId) = .{},
    destroyed_this_tick: std.ArrayList(EntityId) = .{},
    cur_time: f64 = 0,

    pub fn init(allocator: std.mem.Allocator) !EntityManager {
        var mgr: EntityManager = .{
            .allocator = allocator,
            .archetypes = std.AutoHashMap(ArchetypeMask, Archetype).init(allocator),
            .templates = std.StringHashMap(TemplateDef).init(allocator),
            .singletons = std.StringHashMap(EntityId).init(allocator),
        };
        // Slot 0 reserved (invalid index).
        try mgr.records.append(allocator, .{ .alive = false, .generation = 0 });
        try mgr.registerBuiltinTemplates();
        try mgr.registerSystem(.act, 0, "integrate_velocity", integrateVelocity);
        return mgr;
    }

    pub fn deinit(self: *EntityManager) void {
        self.emit(.{ .manager_before_clear = {} });
        self.clearEntities();
        self.emit(.{ .manager_after_clear = {} });

        var tit = self.templates.iterator();
        while (tit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
        }
        self.templates.deinit();

        var ait = self.archetypes.valueIterator();
        while (ait.next()) |arch| arch.deinit(self.allocator);
        self.archetypes.deinit();

        var sit = self.singletons.keyIterator();
        while (sit.next()) |k| self.allocator.free(k.*);
        self.singletons.deinit();

        for (self.deferred.items) |d| self.allocator.free(d.template);
        self.deferred.deinit(self.allocator);
        self.systems.deinit(self.allocator);
        self.listeners.deinit(self.allocator);
        self.created_this_tick.deinit(self.allocator);
        self.destroyed_this_tick.deinit(self.allocator);
        self.free_indices.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *EntityManager) void {
        self.emit(.{ .manager_before_clear = {} });
        self.clearEntities();
        self.emit(.{ .manager_after_clear = {} });
    }

    fn clearEntities(self: *EntityManager) void {
        for (self.deferred.items) |d| self.allocator.free(d.template);
        self.deferred.clearRetainingCapacity();
        self.created_this_tick.clearRetainingCapacity();
        self.destroyed_this_tick.clearRetainingCapacity();
        self.free_indices.clearRetainingCapacity();

        var sit = self.singletons.keyIterator();
        while (sit.next()) |k| self.allocator.free(k.*);
        self.singletons.clearRetainingCapacity();

        var ait = self.archetypes.valueIterator();
        while (ait.next()) |arch| arch.deinit(self.allocator);
        self.archetypes.clearRetainingCapacity();

        // Keep invalid slot 0.
        self.records.clearRetainingCapacity();
        self.records.append(self.allocator, .{ .alive = false, .generation = 0 }) catch {};
    }

    pub fn subscribe(self: *EntityManager, ctx: ?*anyopaque, callback: EventListener) !void {
        try self.listeners.append(self.allocator, .{ .ctx = ctx, .callback = callback });
    }

    fn emit(self: *EntityManager, event: CoreEvent) void {
        for (self.listeners.items) |b| b.callback(b.ctx, event);
    }

    pub fn registerTemplate(self: *EntityManager, name: []const u8, comps: ComponentsInit) !void {
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        var def: TemplateDef = .{
            .name = key,
            .mask = comps.mask(),
            .transform = comps.transform orelse .{},
            .velocity = comps.velocity orelse .{},
            .tag = comps.tag orelse .{},
        };
        if (comps.name) |n| def.name_tag.set(n) else def.name_tag.set(name);
        if (def.mask == 0) def.mask = componentBit(.transform);
        try self.templates.put(key, def);
    }

    fn registerBuiltinTemplates(self: *EntityManager) !void {
        try self.registerTemplate("moving_marker", .{
            .transform = .{},
            .velocity = .{ .linear = .{ 0.5, 0, 0 } },
            .name = "moving_marker",
        });
        try self.registerTemplate("static_marker", .{
            .transform = .{},
            .name = "static_marker",
        });
        try self.registerTemplate("tagged_actor", .{
            .transform = .{},
            .velocity = .{},
            .tag = .{ .id = 1 },
            .name = "tagged_actor",
        });
    }

    pub fn registerSystem(self: *EntityManager, stage: UpdateStage, priority: i32, name: []const u8, callback: SystemFn) !void {
        try self.systems.append(self.allocator, .{
            .stage = stage,
            .priority = priority,
            .name = name,
            .callback = callback,
        });
        std.mem.sort(SystemEntry, self.systems.items, {}, struct {
            fn less(_: void, a: SystemEntry, b: SystemEntry) bool {
                if (a.stage != b.stage) return @intFromEnum(a.stage) < @intFromEnum(b.stage);
                return a.priority < b.priority;
            }
        }.less);
    }

    pub fn update(self: *EntityManager, stage: UpdateStage, dt: f64) void {
        if (stage == .act) {
            self.cur_time += dt;
            self.performDeferredCreates();
        }
        for (self.systems.items) |sys| {
            if (sys.stage == stage) sys.callback(self, stage, dt);
        }
        if (stage == .act) {
            self.created_this_tick.clearRetainingCapacity();
            self.destroyed_this_tick.clearRetainingCapacity();
        }
    }

    pub fn doesEntityExist(self: *const EntityManager, id: EntityId) bool {
        if (id.index == 0 or id.index >= self.records.items.len) return false;
        const rec = self.records.items[id.index];
        return rec.alive and rec.generation == id.generation;
    }

    pub fn entityCount(self: *const EntityManager) usize {
        var n: usize = 0;
        for (self.records.items) |r| {
            if (r.alive) n += 1;
        }
        return n;
    }

    pub fn getEntityTemplateName(self: *const EntityManager, id: EntityId) ?[]const u8 {
        if (!self.doesEntityExist(id)) return null;
        return self.records.items[id.index].template_name;
    }

    pub fn createEntitySync(self: *EntityManager, template_name: []const u8, override_comps: ComponentsInit) !EntityId {
        const templ = self.templates.get(template_name) orelse return error.UnknownTemplate;
        var merged: ComponentsInit = .{
            .transform = if (override_comps.transform != null or (templ.mask & componentBit(.transform) != 0))
                override_comps.transform orelse templ.transform
            else
                null,
            .velocity = if (override_comps.velocity != null or (templ.mask & componentBit(.velocity) != 0))
                override_comps.velocity orelse templ.velocity
            else
                null,
            .name = if (override_comps.name != null or (templ.mask & componentBit(.name_tag) != 0))
                override_comps.name orelse templ.name_tag.slice()
            else
                null,
            .tag = if (override_comps.tag != null or (templ.mask & componentBit(.tag) != 0))
                override_comps.tag orelse templ.tag
            else
                null,
        };
        if (templ.mask & componentBit(.transform) != 0 and merged.transform == null) merged.transform = templ.transform;
        if (templ.mask & componentBit(.velocity) != 0 and merged.velocity == null) merged.velocity = templ.velocity;
        if (templ.mask & componentBit(.name_tag) != 0 and merged.name == null) merged.name = templ.name_tag.slice();
        if (templ.mask & componentBit(.tag) != 0 and merged.tag == null) merged.tag = templ.tag;

        const id = try self.spawnRaw(merged, templ.name);
        try self.created_this_tick.append(self.allocator, id);
        self.emit(.{ .entity_created = id });
        return id;
    }

    /// Async/deferred create (daECS createEntityAsync role — flushed on next Act).
    pub fn createEntityAsync(self: *EntityManager, template_name: []const u8, comps: ComponentsInit) !void {
        const owned = try self.allocator.dupe(u8, template_name);
        errdefer self.allocator.free(owned);
        try self.deferred.append(self.allocator, .{ .template = owned, .init = comps });
    }

    fn performDeferredCreates(self: *EntityManager) void {
        const batch = self.deferred.toOwnedSlice(self.allocator) catch return;
        defer {
            for (batch) |d| self.allocator.free(d.template);
            self.allocator.free(batch);
        }
        self.deferred = .{};
        for (batch) |d| {
            _ = self.createEntitySync(d.template, d.init) catch {};
        }
    }

    pub fn destroyEntity(self: *EntityManager, id: EntityId) bool {
        if (!self.doesEntityExist(id)) return false;
        self.emit(.{ .entity_destroyed = id });
        self.removeFromArchetype(id);
        var rec = &self.records.items[id.index];
        rec.alive = false;
        rec.template_name = null;
        rec.generation +%= 1;
        if (rec.generation == 0) rec.generation = 1;
        self.free_indices.append(self.allocator, id.index) catch {};
        self.destroyed_this_tick.append(self.allocator, id) catch {};
        return true;
    }

    /// Recreate entity with a different template (daECS reCreateEntity role — sync).
    pub fn reCreateEntity(self: *EntityManager, id: EntityId, template_name: []const u8, comps: ComponentsInit) !EntityId {
        if (!self.doesEntityExist(id)) return error.DeadEntity;
        var name_buf: [32]u8 = undefined;
        var name_len: usize = 0;
        var keep = ComponentsInit{};
        if (self.getTransform(id)) |t| keep.transform = t.*;
        if (self.getVelocity(id)) |v| keep.velocity = v.*;
        if (self.getNameTag(id)) |n| {
            name_len = n.len;
            @memcpy(name_buf[0..name_len], n.bytes[0..name_len]);
            keep.name = name_buf[0..name_len];
        }
        if (self.getTag(id)) |t| keep.tag = t.*;
        if (comps.transform != null) keep.transform = comps.transform;
        if (comps.velocity != null) keep.velocity = comps.velocity;
        if (comps.name) |n| {
            name_len = @min(n.len, name_buf.len);
            @memcpy(name_buf[0..name_len], n[0..name_len]);
            keep.name = name_buf[0..name_len];
        }
        if (comps.tag != null) keep.tag = comps.tag;

        _ = self.destroyEntity(id);
        return self.createEntitySync(template_name, keep);
    }

    pub fn getOrCreateSingleton(self: *EntityManager, name: []const u8, template_name: []const u8) !EntityId {
        if (self.singletons.get(name)) |existing| {
            if (self.doesEntityExist(existing)) return existing;
        }
        const id = try self.createEntitySync(template_name, .{});
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try self.singletons.put(key, id);
        return id;
    }

    pub fn getSingleton(self: *const EntityManager, name: []const u8) ?EntityId {
        const id = self.singletons.get(name) orelse return null;
        if (!self.doesEntityExist(id)) return null;
        return id;
    }

    pub fn getTransform(self: *EntityManager, id: EntityId) ?*Transform {
        const place = self.locate(id) orelse return null;
        if (place.mask & componentBit(.transform) == 0) return null;
        return &place.arch.transforms.items[place.index];
    }

    pub fn getVelocity(self: *EntityManager, id: EntityId) ?*Velocity {
        const place = self.locate(id) orelse return null;
        if (place.mask & componentBit(.velocity) == 0) return null;
        return &place.arch.velocities.items[place.index];
    }

    pub fn getNameTag(self: *EntityManager, id: EntityId) ?*NameTag {
        const place = self.locate(id) orelse return null;
        if (place.mask & componentBit(.name_tag) == 0) return null;
        return &place.arch.names.items[place.index];
    }

    pub fn getTag(self: *EntityManager, id: EntityId) ?*Tag {
        const place = self.locate(id) orelse return null;
        if (place.mask & componentBit(.tag) == 0) return null;
        return &place.arch.tags.items[place.index];
    }

    pub fn setTransform(self: *EntityManager, id: EntityId, value: Transform) void {
        const t = self.getTransform(id) orelse return;
        t.* = value;
        self.emit(.{ .component_changed = .{ .entity = id, .component = .transform } });
    }

    pub fn setVelocity(self: *EntityManager, id: EntityId, value: Velocity) void {
        const v = self.getVelocity(id) orelse return;
        v.* = value;
        self.emit(.{ .component_changed = .{ .entity = id, .component = .velocity } });
    }

    /// Query: entities whose archetype contains all `required` bits.
    pub fn query(self: *EntityManager, required: ArchetypeMask, out: *std.ArrayList(EntityId)) !void {
        out.clearRetainingCapacity();
        var it = self.archetypes.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.* & required != required) continue;
            try out.appendSlice(self.allocator, e.value_ptr.entities.items);
        }
    }

    /// Iterate matching archetypes and invoke callback per entity index (RO/RW via pointers).
    pub fn each(
        self: *EntityManager,
        required: ArchetypeMask,
        ctx: ?*anyopaque,
        callback: *const fn (ctx: ?*anyopaque, mgr: *EntityManager, id: EntityId, index: u32, arch: *Archetype) void,
    ) void {
        var it = self.archetypes.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.* & required != required) continue;
            const arch = e.value_ptr;
            for (arch.entities.items, 0..) |id, i| {
                callback(ctx, self, id, @intCast(i), arch);
            }
        }
    }

    const Loc = struct {
        mask: ArchetypeMask,
        index: u32,
        arch: *Archetype,
    };

    fn locate(self: *EntityManager, id: EntityId) ?Loc {
        if (!self.doesEntityExist(id)) return null;
        const rec = self.records.items[id.index];
        const arch = self.archetypes.getPtr(rec.archetype) orelse return null;
        return .{ .mask = rec.archetype, .index = rec.index, .arch = arch };
    }

    fn spawnRaw(self: *EntityManager, comps: ComponentsInit, template_name: []const u8) !EntityId {
        var mask = comps.mask();
        if (mask == 0) mask = componentBit(.transform);

        const arch = try self.ensureArchetype(mask);
        const index_in_arch: u32 = @intCast(arch.len());

        const slot = try self.allocSlot();
        const id = EntityId{ .index = slot, .generation = self.records.items[slot].generation };

        try arch.entities.append(self.allocator, id);
        if (mask & componentBit(.transform) != 0) try arch.transforms.append(self.allocator, comps.transform orelse .{});
        if (mask & componentBit(.velocity) != 0) try arch.velocities.append(self.allocator, comps.velocity orelse .{});
        if (mask & componentBit(.name_tag) != 0) {
            var tag: NameTag = .{};
            if (comps.name) |n| tag.set(n);
            try arch.names.append(self.allocator, tag);
        }
        if (mask & componentBit(.tag) != 0) try arch.tags.append(self.allocator, comps.tag orelse .{});

        self.records.items[slot] = .{
            .generation = id.generation,
            .alive = true,
            .archetype = mask,
            .index = index_in_arch,
            .template_name = template_name,
        };
        return id;
    }

    fn allocSlot(self: *EntityManager) !u20 {
        if (self.free_indices.pop()) |idx| {
            return idx;
        }
        const idx: u20 = @intCast(self.records.items.len);
        if (idx == std.math.maxInt(u20)) return error.OutOfEntities;
        try self.records.append(self.allocator, .{ .generation = 1, .alive = false });
        return idx;
    }

    fn removeFromArchetype(self: *EntityManager, id: EntityId) void {
        const rec = self.records.items[id.index];
        const arch = self.archetypes.getPtr(rec.archetype) orelse return;
        const idx = rec.index;
        const last = arch.entities.items.len - 1;
        if (idx != last) {
            const moved = arch.entities.items[last];
            arch.entities.items[idx] = moved;
            if (rec.archetype & componentBit(.transform) != 0) arch.transforms.items[idx] = arch.transforms.items[last];
            if (rec.archetype & componentBit(.velocity) != 0) arch.velocities.items[idx] = arch.velocities.items[last];
            if (rec.archetype & componentBit(.name_tag) != 0) arch.names.items[idx] = arch.names.items[last];
            if (rec.archetype & componentBit(.tag) != 0) arch.tags.items[idx] = arch.tags.items[last];
            if (self.doesEntityExist(moved)) self.records.items[moved.index].index = idx;
        }
        _ = arch.entities.pop();
        if (rec.archetype & componentBit(.transform) != 0) _ = arch.transforms.pop();
        if (rec.archetype & componentBit(.velocity) != 0) _ = arch.velocities.pop();
        if (rec.archetype & componentBit(.name_tag) != 0) _ = arch.names.pop();
        if (rec.archetype & componentBit(.tag) != 0) _ = arch.tags.pop();
    }

    fn ensureArchetype(self: *EntityManager, mask: ArchetypeMask) !*Archetype {
        const gop = try self.archetypes.getOrPut(mask);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .mask = mask };
        }
        return gop.value_ptr;
    }
};

fn integrateVelocity(mgr: *EntityManager, _: UpdateStage, dt: f64) void {
    const req = componentBit(.transform) | componentBit(.velocity);
    var it = mgr.archetypes.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.* & req != req) continue;
        const arch = e.value_ptr;
        const n = arch.entities.items.len;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const v = arch.velocities.items[i];
            arch.transforms.items[i].position[0] += v.linear[0] * @as(f32, @floatCast(dt));
            arch.transforms.items[i].position[1] += v.linear[1] * @as(f32, @floatCast(dt));
            arch.transforms.items[i].position[2] += v.linear[2] * @as(f32, @floatCast(dt));
        }
    }
}

/// Compatibility alias used by Scene.
pub const World = EntityManager;

test "entity manager templates events query" {
    const allocator = std.testing.allocator;
    var mgr = try EntityManager.init(allocator);
    defer mgr.deinit();

    const Counter = struct {
        created: u32 = 0,
        destroyed: u32 = 0,
        changed: u32 = 0,
        fn on(ctx: ?*anyopaque, ev: CoreEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            switch (ev) {
                .entity_created => self.created += 1,
                .entity_destroyed => self.destroyed += 1,
                .component_changed => self.changed += 1,
                else => {},
            }
        }
    };
    var counter: Counter = .{};
    try mgr.subscribe(&counter, Counter.on);

    const a = try mgr.createEntitySync("moving_marker", .{});
    try std.testing.expect(mgr.doesEntityExist(a));
    try std.testing.expectEqual(@as(u32, 1), counter.created);
    try std.testing.expectEqualStrings("moving_marker", mgr.getEntityTemplateName(a).?);

    mgr.update(.act, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), mgr.getTransform(a).?.position[0], 1e-5);

    mgr.setVelocity(a, .{ .linear = .{ 2, 0, 0 } });
    try std.testing.expectEqual(@as(u32, 1), counter.changed);

    var ids: std.ArrayList(EntityId) = .{};
    defer ids.deinit(allocator);
    try mgr.query(componentBit(.transform) | componentBit(.velocity), &ids);
    try std.testing.expectEqual(@as(usize, 1), ids.items.len);

    try mgr.createEntityAsync("static_marker", .{});
    mgr.update(.act, 0);
    try std.testing.expectEqual(@as(usize, 2), mgr.entityCount());

    const singleton = try mgr.getOrCreateSingleton("game_mode", "static_marker");
    try std.testing.expect(EntityId.eql(singleton, (try mgr.getOrCreateSingleton("game_mode", "static_marker"))));

    const b = try mgr.reCreateEntity(a, "tagged_actor", .{});
    try std.testing.expect(mgr.getTag(b) != null);
    try std.testing.expect(!mgr.doesEntityExist(a)); // generation invalidated

    try std.testing.expect(mgr.destroyEntity(b));
    try std.testing.expectEqual(@as(u32, 2), counter.destroyed);
}

test "system priority order" {
    const allocator = std.testing.allocator;
    var mgr = try EntityManager.init(allocator);
    defer mgr.deinit();

    const Order = struct {
        seq: [4]u8 = .{0} ** 4,
        n: usize = 0,
        fn push(self: *@This(), v: u8) void {
            if (self.n < self.seq.len) {
                self.seq[self.n] = v;
                self.n += 1;
            }
        }
    };
    var order: Order = .{};
    const Ctx = struct {
        order: *Order,
        fn early(mgr_ptr: *EntityManager, _: UpdateStage, _: f64) void {
            const c: *@This() = @ptrCast(@alignCast(mgr_ptr.listeners.items[0].ctx.?));
            _ = c;
        }
    };
    _ = Ctx;
    // Register after builtin; lower priority runs first among act systems we add.
    const S = struct {
        var o: *Order = undefined;
        fn a(m: *EntityManager, _: UpdateStage, _: f64) void {
            _ = m;
            o.push(1);
        }
        fn b(m: *EntityManager, _: UpdateStage, _: f64) void {
            _ = m;
            o.push(2);
        }
    };
    S.o = &order;
    try mgr.registerSystem(.act, 10, "a", S.a);
    try mgr.registerSystem(.act, 20, "b", S.b);
    mgr.update(.act, 0);
    // integrate_velocity (prio 0) runs first, then a, then b
    try std.testing.expectEqual(@as(u8, 1), order.seq[0]);
    try std.testing.expectEqual(@as(u8, 2), order.seq[1]);
}

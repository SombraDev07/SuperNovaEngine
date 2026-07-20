const std = @import("std");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");
const zm = @import("zmath");
const engine = @import("TucanoEngine");

var g_console: *engine.DebugConsole = undefined;

fn logSink(level: engine.log.Level, _: engine.log.Channel, message: []const u8) void {
    g_console.push(level, message);
}

const SculptTool = enum { raise, lower, smooth, flatten, hill, paint };

const App = struct {
    window: *zglfw.Window,
    renderer: engine.Renderer,
    scenes: engine.SceneManager,
    boot_scene: engine.Scene,
    overlay_scene: engine.Scene,
    resources: engine.ResourceManager,
    events: engine.EventBus,
    console: engine.DebugConsole,
    terrain_editor: engine.world.EditorSession = undefined,
    loop: ?*engine.GameLoop = null,
    wants_quit: bool = false,
    esc_was_down: bool = false,
    boot_shader: engine.ResourceHandle = .invalid,
    cursor_x: f64 = 0,
    cursor_y: f64 = 0,
    look_prev_x: f64 = 0,
    look_prev_y: f64 = 0,
    look_dragging: bool = false,
    /// Mouse terrain sculpt (LMB drag). Toggle with B.
    sculpt_enabled: bool = true,
    sculpt_tool: SculptTool = .raise,
    sculpt_brush: engine.world.Brush = .{ .radius = 8, .strength = 1.2, .falloff = 2 },
    sculpt_paint_layer: u2 = 0,
    sculpt_stroke_active: bool = false,
    sculpt_undo_pushed: bool = false,
    key_b_was_down: bool = false,

    fn shouldQuit(ctx: *anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.window.shouldClose() or self.wants_quit or self.console.quit_requested or self.renderer.isDeviceLost();
    }

    fn fixedUpdate(ctx: *anyopaque, dt: f64) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const cam = self.renderer.camera.position;
        self.scenes.actAll(.{ cam[0], cam[1], cam[2] }, dt);
    }

    fn onEvent(ctx: ?*anyopaque, event: engine.Event) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        switch (event.id) {
            .window_resize => {
                const p: *const engine.ResizePayload = @ptrCast(@alignCast(event.payload.?));
                self.renderer.onFramebufferResize(p.width, p.height);
            },
            .window_close => self.wants_quit = true,
            .window_focus => {
                const p: *const engine.FocusPayload = @ptrCast(@alignCast(event.payload.?));
                if (!p.focused) engine.log.debug(.core, "window unfocused — skip draw", .{});
            },
            .window_iconify => {},
            .scene_loaded => engine.log.info(.scene, "event scene_loaded", .{}),
            else => {},
        }
    }

    fn observerTerrain(self: *App) ?*engine.world.TerrainTile {
        const cam = self.renderer.camera.position;
        const primary = self.scenes.current() orelse return null;
        const coord = engine.ChunkCoord.fromWorld(cam[0], cam[2], primary.streamer.config.chunk_size);
        return primary.streamer.getTerrain(coord);
    }

    fn terrainAtWorld(self: *App, wx: f32, wz: f32) ?*engine.world.TerrainTile {
        const primary = self.scenes.current() orelse return null;
        const coord = engine.ChunkCoord.fromWorld(wx, wz, primary.streamer.config.chunk_size);
        return primary.streamer.getTerrain(coord);
    }

    fn pushTerrainUndo(self: *App, tile: *engine.world.TerrainTile) void {
        tile.heightfield.markDirtyAll();
        self.terrain_editor.pushUndo(&tile.heightfield, &tile.splat) catch {};
    }

    /// Screen pixel → world ray (LH, Y-up).
    fn screenRay(self: *const App, mx: f64, my: f64) struct { origin: [3]f32, dir: [3]f32 } {
        const w: f32 = @floatFromInt(self.renderer.gctx.swapchain_descriptor.width);
        const h: f32 = @floatFromInt(self.renderer.gctx.swapchain_descriptor.height);
        const ndc_x = (@as(f32, @floatCast(mx)) / @max(w, 1)) * 2.0 - 1.0;
        const ndc_y = 1.0 - (@as(f32, @floatCast(my)) / @max(h, 1)) * 2.0;
        const cam = self.renderer.camera;
        const vp = cam.viewProjection();
        const inv = zm.inverse(vp);
        const near_p = zm.mul(zm.f32x4(ndc_x, ndc_y, 0, 1), inv);
        const far_p = zm.mul(zm.f32x4(ndc_x, ndc_y, 1, 1), inv);
        const nw = near_p / @as(zm.Vec, @splat(near_p[3]));
        const fw = far_p / @as(zm.Vec, @splat(far_p[3]));
        var dir = fw - nw;
        dir = zm.normalize3(dir);
        return .{
            .origin = .{ nw[0], nw[1], nw[2] },
            .dir = .{ dir[0], dir[1], dir[2] },
        };
    }

    fn pickTerrain(self: *App) ?struct { wx: f32, wy: f32, wz: f32, tile: *engine.world.TerrainTile } {
        const ray = self.screenRay(self.cursor_x, self.cursor_y);
        const primary = self.scenes.current() orelse return null;
        // March ray; resolve tile per sample (open-world pick).
        const max_t: f32 = @min(self.renderer.camera.far, 800);
        const steps: u32 = 128;
        const dt = max_t / @as(f32, @floatFromInt(steps));
        var t: f32 = 0;
        var prev_above = true;
        var i: u32 = 0;
        while (i <= steps) : (i += 1) {
            const x = ray.origin[0] + ray.dir[0] * t;
            const y = ray.origin[1] + ray.dir[1] * t;
            const z = ray.origin[2] + ray.dir[2] * t;
            const coord = engine.ChunkCoord.fromWorld(x, z, primary.streamer.config.chunk_size);
            const tile = primary.streamer.getTerrain(coord) orelse {
                prev_above = true;
                t += dt;
                continue;
            };
            const ground = engine.world.terraform.sampleWorld(&tile.heightfield, &tile.terraform, x, z);
            const above = y >= ground;
            if (i > 0 and prev_above and !above) {
                const t0 = t - dt;
                const x0 = ray.origin[0] + ray.dir[0] * t0;
                const y0 = ray.origin[1] + ray.dir[1] * t0;
                const z0 = ray.origin[2] + ray.dir[2] * t0;
                const g0 = engine.world.terraform.sampleWorld(&tile.heightfield, &tile.terraform, x0, z0);
                const denom = (y - ground) - (y0 - g0);
                const th = if (@abs(denom) < 1e-8) t0 else t0 + ((0 - (y0 - g0)) / denom) * dt;
                const hx = ray.origin[0] + ray.dir[0] * th;
                const hz = ray.origin[2] + ray.dir[2] * th;
                const hit_tile = self.terrainAtWorld(hx, hz) orelse tile;
                const hy = engine.world.terraform.sampleWorld(&hit_tile.heightfield, &hit_tile.terraform, hx, hz);
                return .{ .wx = hx, .wy = hy, .wz = hz, .tile = hit_tile };
            }
            prev_above = above;
            t += dt;
        }
        return null;
    }

    /// Apply sculpt to every resident chunk the brush overlaps (keeps chunk seams welded).
    fn applySculptStroke(self: *App, hit_tile: *engine.world.TerrainTile, wx: f32, wz: f32, tool: SculptTool, dt: f32) void {
        const primary = self.scenes.current() orelse return;
        const cs = primary.streamer.config.chunk_size;
        var brush = self.sculpt_brush;
        const frame_w = brush.strength * @min(dt, 0.05) * 4.0;
        brush.strength = frame_w;
        const r = self.sculpt_brush.radius;
        const c0 = engine.ChunkCoord.fromWorld(wx - r, wz - r, cs);
        const c1 = engine.ChunkCoord.fromWorld(wx + r, wz + r, cs);

        if (!self.sculpt_undo_pushed) {
            self.pushTerrainUndo(hit_tile);
            self.sculpt_undo_pushed = true;
        }

        const flatten_target = if (tool == .flatten)
            engine.world.terraform.sampleWorld(&hit_tile.heightfield, &hit_tile.terraform, wx, wz)
        else
            0;

        var cz = c0.z;
        while (cz <= c1.z) : (cz += 1) {
            var cx = c0.x;
            while (cx <= c1.x) : (cx += 1) {
                const tile = primary.streamer.getTerrain(.{ .x = cx, .z = cz }) orelse continue;
                switch (tool) {
                    .raise => {
                        tile.terraform.storeSphere(wx, wz, brush.radius, frame_w, .additive) catch {};
                        engine.world.terrain_edit.raise(&tile.heightfield, wx, wz, brush);
                    },
                    .lower => {
                        tile.terraform.storeSphere(wx, wz, brush.radius, -frame_w, .additive) catch {};
                        engine.world.terrain_edit.lower(&tile.heightfield, wx, wz, brush);
                    },
                    .smooth => engine.world.terrain_edit.smooth(&tile.heightfield, wx, wz, brush),
                    .flatten => engine.world.terrain_edit.flatten(&tile.heightfield, wx, wz, brush, flatten_target),
                    .hill => {
                        tile.terraform.storeSphere(wx, wz, brush.radius, frame_w * 1.5, .additive) catch {};
                        engine.world.terrain_edit.hill(&tile.heightfield, wx, wz, brush);
                    },
                    .paint => engine.world.terrain_edit.paint(&tile.splat, &tile.heightfield, wx, wz, brush, self.sculpt_paint_layer),
                }
                tile.markDirty();
            }
        }
    }

    fn updateFlyCamera(self: *App, dt: f32) void {
        if (self.console.open) return;
        if (zgui.io.getWantCaptureKeyboard() and zgui.io.getWantCaptureMouse()) return;

        var cam = &self.renderer.camera;
        const speed: f32 = if (self.window.getKey(.left_shift) == .press) 25.0 else 8.0;
        const move = speed * dt;
        const f = cam.forward();
        const r = cam.right();
        const up = cam.up;

        if (!zgui.io.getWantCaptureKeyboard()) {
            if (self.window.getKey(.w) == .press) cam.position = cam.position + f * @as(zm.Vec, @splat(move));
            if (self.window.getKey(.s) == .press) cam.position = cam.position - f * @as(zm.Vec, @splat(move));
            if (self.window.getKey(.d) == .press) cam.position = cam.position + r * @as(zm.Vec, @splat(move));
            if (self.window.getKey(.a) == .press) cam.position = cam.position - r * @as(zm.Vec, @splat(move));
            if (self.window.getKey(.e) == .press or self.window.getKey(.space) == .press) {
                cam.position = cam.position + up * @as(zm.Vec, @splat(move));
            }
            if (self.window.getKey(.q) == .press) {
                cam.position = cam.position - up * @as(zm.Vec, @splat(move));
            }
        }

        // RMB drag = look (LMB reserved for terrain sculpt).
        const rmb = self.window.getMouseButton(.right) == .press and !zgui.io.getWantCaptureMouse();
        if (rmb) {
            if (!self.look_dragging) {
                self.look_dragging = true;
                self.look_prev_x = self.cursor_x;
                self.look_prev_y = self.cursor_y;
            } else {
                const dx: f32 = @floatCast(self.cursor_x - self.look_prev_x);
                const dy: f32 = @floatCast(self.cursor_y - self.look_prev_y);
                self.look_prev_x = self.cursor_x;
                self.look_prev_y = self.cursor_y;
                const sens: f32 = 0.0025;
                cam.yaw += dx * sens;
                cam.pitch -= dy * sens;
                cam.pitch = std.math.clamp(cam.pitch, -1.45, 1.45);
            }
        } else {
            self.look_dragging = false;
        }

        // Keep eye above terrain (avoid flying inside / under the mesh).
        if (self.scenes.current()) |s| {
            const wx = cam.position[0];
            const wz = cam.position[2];
            const gy = s.streamer.sampleHeight(wx, wz) orelse 0;
            const min_eye = gy + 2.5;
            if (cam.position[1] < min_eye) cam.position[1] = min_eye;
        }

        cam.syncLookTarget();
    }

    fn updateSculptHotkeys(self: *App) void {
        if (self.console.open) return;
        if (zgui.io.getWantCaptureKeyboard()) return;

        const b_down = self.window.getKey(.b) == .press;
        if (b_down and !self.key_b_was_down) {
            self.sculpt_enabled = !self.sculpt_enabled;
            if (self.sculpt_enabled) {
                engine.log.info(.core, "sculpt ON — LMB raise | Shift lower | Ctrl smooth | Alt flatten | [ ] radius | 1-6 tool", .{});
            } else {
                engine.log.info(.core, "sculpt OFF", .{});
            }
        }
        self.key_b_was_down = b_down;
        if (!self.sculpt_enabled) return;

        if (self.window.getKey(.left_bracket) == .press) {
            self.sculpt_brush.radius = @max(1.0, self.sculpt_brush.radius - 0.25);
        }
        if (self.window.getKey(.right_bracket) == .press) {
            self.sculpt_brush.radius = @min(64.0, self.sculpt_brush.radius + 0.25);
        }
        if (self.window.getKey(.one) == .press) self.sculpt_tool = .raise;
        if (self.window.getKey(.two) == .press) self.sculpt_tool = .lower;
        if (self.window.getKey(.three) == .press) self.sculpt_tool = .smooth;
        if (self.window.getKey(.four) == .press) self.sculpt_tool = .flatten;
        if (self.window.getKey(.five) == .press) self.sculpt_tool = .hill;
        if (self.window.getKey(.six) == .press) self.sculpt_tool = .paint;
        if (self.window.getKey(.zero) == .press) self.sculpt_paint_layer = 0;
        if (self.window.getKey(.nine) == .press) self.sculpt_paint_layer = 1;
        if (self.window.getKey(.eight) == .press) self.sculpt_paint_layer = 2;
        if (self.window.getKey(.seven) == .press) self.sculpt_paint_layer = 3;
    }

    fn updateMouseSculpt(self: *App, dt: f32) void {
        if (!self.sculpt_enabled) return;
        if (self.console.open) return;
        if (zgui.io.getWantCaptureMouse()) return;

        const lmb = self.window.getMouseButton(.left) == .press;
        const shift = self.window.getKey(.left_shift) == .press or self.window.getKey(.right_shift) == .press;
        const ctrl = self.window.getKey(.left_control) == .press or self.window.getKey(.right_control) == .press;
        const alt = self.window.getKey(.left_alt) == .press or self.window.getKey(.right_alt) == .press;

        if (!lmb) {
            self.sculpt_stroke_active = false;
            self.sculpt_undo_pushed = false;
            return;
        }

        var tool = self.sculpt_tool;
        if (shift) tool = .lower;
        if (ctrl) tool = .smooth;
        if (alt) tool = .flatten;

        const hit = self.pickTerrain() orelse return;
        self.sculpt_stroke_active = true;
        self.applySculptStroke(hit.tile, hit.wx, hit.wz, tool, dt);
    }

    fn terrainCommand(ctx: ?*anyopaque, console: *engine.DebugConsole, cmd_line: []const u8) bool {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        var it = std.mem.tokenizeScalar(u8, cmd_line, ' ');
        const cmd = it.next() orelse return false;
        const cam = self.renderer.camera.position;
        const wx = cam[0];
        const wz = cam[2];
        const brush = engine.world.Brush{ .radius = 10, .strength = 1.5 };

        if (std.ascii.eqlIgnoreCase(cmd, "raise")) {
            const tile = self.observerTerrain() orelse {
                console.push(.warn, "no terrain under camera");
                return true;
            };
            self.pushTerrainUndo(tile);
            // High-res terraform @ 0.25 m/cell (Dagor storeSphereAlt) + coarse brush.
            tile.terraform.storeSphere(wx, wz, brush.radius, brush.strength, .additive) catch {};
            engine.world.terrain_edit.raise(&tile.heightfield, wx, wz, brush);
            tile.markDirty();
            console.push(.info, "terrain raise (0.25m terraform)");
            return true;
        } else if (std.ascii.eqlIgnoreCase(cmd, "lower")) {
            const tile = self.observerTerrain() orelse {
                console.push(.warn, "no terrain under camera");
                return true;
            };
            self.pushTerrainUndo(tile);
            tile.terraform.storeSphere(wx, wz, brush.radius, -brush.strength, .additive) catch {};
            engine.world.terrain_edit.lower(&tile.heightfield, wx, wz, brush);
            tile.markDirty();
            console.push(.info, "terrain lower (0.25m terraform)");
            return true;
        } else if (std.ascii.eqlIgnoreCase(cmd, "smooth")) {
            const tile = self.observerTerrain() orelse {
                console.push(.warn, "no terrain under camera");
                return true;
            };
            self.pushTerrainUndo(tile);
            engine.world.terrain_edit.smooth(&tile.heightfield, wx, wz, brush);
            tile.markDirty();
            console.push(.info, "terrain smooth");
            return true;
        } else if (std.ascii.eqlIgnoreCase(cmd, "flatten") or std.ascii.eqlIgnoreCase(cmd, "align")) {
            const tile = self.observerTerrain() orelse {
                console.push(.warn, "no terrain under camera");
                return true;
            };
            self.pushTerrainUndo(tile);
            const target = engine.world.terraform.sampleWorld(&tile.heightfield, &tile.terraform, wx, wz);
            engine.world.terrain_edit.flatten(&tile.heightfield, wx, wz, brush, target);
            tile.markDirty();
            console.push(.info, "terrain flatten");
            return true;
        } else if (std.ascii.eqlIgnoreCase(cmd, "hill")) {
            const tile = self.observerTerrain() orelse {
                console.push(.warn, "no terrain under camera");
                return true;
            };
            self.pushTerrainUndo(tile);
            tile.terraform.storeSphere(wx, wz, brush.radius, brush.strength * 1.5, .additive) catch {};
            engine.world.terrain_edit.hill(&tile.heightfield, wx, wz, brush);
            tile.markDirty();
            console.push(.info, "terrain hill (0.25m terraform)");
            return true;
        } else if (std.ascii.eqlIgnoreCase(cmd, "undo")) {
            const tile = self.observerTerrain() orelse {
                console.push(.warn, "no terrain under camera");
                return true;
            };
            if (self.terrain_editor.undo(&tile.heightfield, &tile.splat)) {
                tile.markDirty();
                console.push(.info, "terrain undo");
            } else {
                console.push(.warn, "undo stack empty");
            }
            return true;
        } else if (std.ascii.eqlIgnoreCase(cmd, "redo")) {
            const tile = self.observerTerrain() orelse {
                console.push(.warn, "no terrain under camera");
                return true;
            };
            if (self.terrain_editor.redo(&tile.heightfield, &tile.splat)) {
                tile.markDirty();
                console.push(.info, "terrain redo");
            } else {
                console.push(.warn, "redo stack empty");
            }
            return true;
        } else if (std.ascii.eqlIgnoreCase(cmd, "paint")) {
            const layer_s = it.next() orelse {
                console.push(.warn, "usage: paint <0-3>");
                return true;
            };
            const layer_i = std.fmt.parseInt(u8, layer_s, 10) catch {
                console.push(.err, "paint layer must be 0-3");
                return true;
            };
            if (layer_i > 3) {
                console.push(.err, "paint layer must be 0-3");
                return true;
            }
            const tile = self.observerTerrain() orelse {
                console.push(.warn, "no terrain under camera");
                return true;
            };
            self.pushTerrainUndo(tile);
            engine.world.terrain_edit.paint(&tile.splat, &tile.heightfield, wx, wz, brush, @intCast(layer_i));
            tile.markDirty();
            console.push(.info, "terrain paint");
            return true;
        } else if (std.ascii.eqlIgnoreCase(cmd, "hole")) {
            const tile = self.observerTerrain() orelse {
                console.push(.warn, "no terrain under camera");
                return true;
            };
            tile.holes.stampDisk(&tile.heightfield, wx, wz, 8, 1);
            tile.markDirty();
            console.push(.info, "terrain hole stamped");
            return true;
        } else if (std.ascii.eqlIgnoreCase(cmd, "bomb") or std.ascii.eqlIgnoreCase(cmd, "crater")) {
            const tile = self.observerTerrain() orelse {
                console.push(.warn, "no terrain under camera");
                return true;
            };
            self.pushTerrainUndo(tile);
            tile.terraform.makeBombCrater(wx, wz, 3.0, 2.0, 8.0, 0.5) catch {};
            tile.markDirty();
            console.push(.info, "bomb crater");
            return true;
        } else if (std.ascii.eqlIgnoreCase(cmd, "dig")) {
            const tile = self.observerTerrain() orelse {
                console.push(.warn, "no terrain under camera");
                return true;
            };
            self.pushTerrainUndo(tile);
            const cells = [_][2]f32{ .{ wx, wz }, .{ wx + 0.5, wz }, .{ wx, wz + 0.5 } };
            _ = tile.terraform.digAndSpread(&cells, 1.2, 1.0) catch {};
            tile.markDirty();
            console.push(.info, "dig + soil spread");
            return true;
        } else if (std.ascii.eqlIgnoreCase(cmd, "export")) {
            const path = it.next() orelse "assets/terrain/chunk.hmap";
            const tile = self.observerTerrain() orelse {
                console.push(.warn, "no terrain under camera");
                return true;
            };
            std.fs.cwd().makePath("assets/terrain") catch {};
            if (std.mem.endsWith(u8, path, ".chmp")) {
                tile.heightfield.writeCompressedFile(path) catch {
                    console.push(.err, "export chmp failed");
                    return true;
                };
                console.push(.info, "exported CHMP");
            } else {
                tile.heightfield.writeFile(path) catch {
                    console.push(.err, "export failed");
                    return true;
                };
                console.push(.info, "exported heightmap");
            }
            return true;
        } else if (std.ascii.eqlIgnoreCase(cmd, "import")) {
            const path = it.next() orelse {
                console.push(.warn, "usage: import <path.hmap|.chmp>");
                return true;
            };
            const tile = self.observerTerrain() orelse {
                console.push(.warn, "no terrain under camera");
                return true;
            };
            const primary = self.scenes.current() orelse return true;
            self.pushTerrainUndo(tile);
            var loaded = engine.world.Heightfield.readFile(primary.allocator, path) catch {
                console.push(.err, "import failed");
                return true;
            };
            defer loaded.deinit();
            if (loaded.resolution != tile.heightfield.resolution) {
                console.push(.err, "resolution mismatch");
                return true;
            }
            @memcpy(tile.heightfield.heights, loaded.heights);
            tile.splat.fillFromSlope(&tile.heightfield, 1.2);
            tile.markDirty();
            console.push(.info, "imported heightmap");
            return true;
        }
        return false;
    }

    fn frameUpdate(ctx: *anyopaque, dt: f64, alpha: f64) void {
        _ = alpha;
        const self: *App = @ptrCast(@alignCast(ctx));
        zglfw.pollEvents();

        if (self.renderer.isDeviceLost()) {
            self.wants_quit = true;
            return;
        }

        const grave = self.window.getKey(.grave_accent) == .press;
        const f1 = self.window.getKey(.F1) == .press;
        const esc = self.window.getKey(.escape) == .press;
        const was_open = self.console.open;
        _ = self.console.handleInput(grave, f1, esc);
        if (esc and !self.esc_was_down and !was_open) {
            self.wants_quit = true;
        }
        self.esc_was_down = esc;

        self.updateSculptHotkeys();
        self.updateMouseSculpt(@floatCast(dt));
        self.updateFlyCamera(@floatCast(dt));

        self.console.frame_dt = @floatCast(dt);
        if (dt > 0.0001) {
            const instant: f32 = @floatCast(1.0 / dt);
            self.console.fps = self.console.fps * 0.9 + instant * 0.1;
        }
        self.console.cull_tested = self.renderer.visible.total_tested;
        self.console.cull_visible = self.renderer.visible.total_visible;
        self.console.cull_occlusion = self.renderer.visible.total_occlusion_culled;
        if (self.scenes.current()) |s| {
            self.console.stream_ready = s.streamer.stats.ready;
            self.console.stream_loading = s.streamer.stats.loading;
            self.console.stream_resident = s.streamer.stats.resident;
            self.console.stream_lod_up = s.streamer.stats.lod_upgrades;
            self.console.stream_budget_cuts = s.streamer.stats.budget_cuts;
            self.console.stream_gpu_bp = s.streamer.stats.gpu_backpressure;
            self.console.stream_zones = @intCast(s.streamer.zones.spheres.items.len);
        }

        if (!engine.Renderer.shouldDraw(self.window) or !self.events.shouldDrawApp()) return;
        if (!self.scenes.canPresent()) return;

        const realtime_usec: i64 = @intFromFloat(dt * 1_000_000.0);
        self.scenes.beforeDrawAll(realtime_usec, @floatCast(dt));
        self.scenes.drawPrepareAll();
        if (self.scenes.current()) |s| {
            self.renderer.syncTerrain(&s.streamer) catch {};
        }

        const gctx = self.renderer.gctx;
        zgui.backend.newFrame(gctx.swapchain_descriptor.width, gctx.swapchain_descriptor.height);
        self.console.draw();
        self.renderer.drawFrame(@floatCast(dt), true);
    }
};

fn glfwFramebufferSize(window: *zglfw.Window, width: c_int, height: c_int) callconv(.c) void {
    const app = window.getUserPointer(App) orelse return;
    if (width > 0 and height > 0) {
        app.events.publishResize(@intCast(width), @intCast(height));
    }
}

fn glfwKey(window: *zglfw.Window, key: zglfw.Key, scancode: c_int, action: zglfw.Action, mods: zglfw.Mods) callconv(.c) void {
    const app = window.getUserPointer(App) orelse return;
    const down = action == .press or action == .repeat;
    if (action == .press or action == .release) {
        app.events.publishKey(down, @intFromEnum(key), scancode, @bitCast(mods));
    }
}

fn glfwClose(window: *zglfw.Window) callconv(.c) void {
    const app = window.getUserPointer(App) orelse return;
    app.events.publish(.{ .id = .window_close });
}

fn glfwIconify(window: *zglfw.Window, iconified: zglfw.Bool) callconv(.c) void {
    const app = window.getUserPointer(App) orelse return;
    app.events.publishIconify(iconified == zglfw.TRUE);
}

fn glfwFocus(window: *zglfw.Window, focused: zglfw.Bool) callconv(.c) void {
    const app = window.getUserPointer(App) orelse return;
    app.events.publishFocus(focused == zglfw.TRUE);
}

fn glfwCursorPos(window: *zglfw.Window, x: f64, y: f64) callconv(.c) void {
    const app = window.getUserPointer(App) orelse return;
    app.cursor_x = x;
    app.cursor_y = y;
    app.events.publishMouseMove(x, y);
}

fn glfwMouseButton(window: *zglfw.Window, button: zglfw.MouseButton, action: zglfw.Action, mods: zglfw.Mods) callconv(.c) void {
    const app = window.getUserPointer(App) orelse return;
    app.events.publishMouseButton(
        @intFromEnum(button),
        @intFromEnum(action),
        @bitCast(mods),
        app.cursor_x,
        app.cursor_y,
    );
}

pub fn main() !void {
    {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_dir = std.fs.selfExeDirPath(&buf) catch ".";
        std.posix.chdir(exe_dir) catch {};
    }

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    engine.log.setLevel(.info);
    engine.log.info(.core, "TucanoEngine starting", .{});

    const zstbi = @import("zstbi");
    zstbi.init(allocator);
    defer zstbi.deinit();
    const zbasis = @import("zbasis");
    zbasis.init();

    try zglfw.init();
    defer zglfw.terminate();

    const arg_list = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arg_list);
    const video = engine.VideoSettings.fromArgs(arg_list);
    const base_only = blk: {
        for (arg_list) |a| {
            if (std.mem.eql(u8, a, "--base-only")) break :blk true;
        }
        break :blk false;
    };

    const window = engine.render.video.createWindow(video) catch |err| {
        engine.log.err(.core, "fatal: video init failed ({s})", .{@errorName(err)});
        return err;
    };
    defer window.destroy();

    const present: wgpu.PresentMode = if (!video.vsync) .immediate else .fifo;

    var app = App{
        .window = window,
        .renderer = try engine.Renderer.create(allocator, window, .{
            .present_mode = present,
            .base_only = base_only,
        }),
        .scenes = engine.SceneManager.init(),
        .boot_scene = try engine.Scene.create(allocator, "boot"),
        .overlay_scene = try engine.Scene.create(allocator, "overlay"),
        .resources = engine.ResourceManager.init(allocator),
        .events = engine.EventBus.init(allocator),
        .console = engine.DebugConsole.init(),
        .terrain_editor = engine.world.EditorSession.init(allocator),
    };
    defer {
        zgui.backend.deinit();
        zgui.deinit();
        if (app.boot_shader != .invalid) app.resources.release(app.boot_shader);
        app.terrain_editor.deinit();
        app.events.deinit();
        app.resources.deinit();
        app.scenes.select(null);
        app.scenes.selectSecondary(null);
        app.overlay_scene.destroy();
        app.boot_scene.destroy();
        app.renderer.destroy();
    }

    app.renderer.installDeviceLostHandler();
    app.renderer.setVsync(video.vsync, video.adaptive_vsync);
    app.renderer.camera.syncLookTarget();

    window.setUserPointer(&app);
    _ = window.setFramebufferSizeCallback(glfwFramebufferSize);
    _ = window.setKeyCallback(glfwKey);
    _ = window.setCloseCallback(glfwClose);
    _ = window.setIconifyCallback(glfwIconify);
    _ = window.setFocusCallback(glfwFocus);
    _ = window.setCursorPosCallback(glfwCursorPos);
    _ = window.setMouseButtonCallback(glfwMouseButton);

    try app.events.subscribe(.window_resize, &app, App.onEvent);
    try app.events.subscribe(.window_close, &app, App.onEvent);
    try app.events.subscribe(.window_iconify, &app, App.onEvent);
    try app.events.subscribe(.window_focus, &app, App.onEvent);
    try app.events.subscribe(.scene_loaded, &app, App.onEvent);

    g_console = &app.console;
    app.console.command_context = &app;
    app.console.command_handler = App.terrainCommand;
    engine.log.setSink(logSink);
    defer engine.log.setSink(null);

    try app.resources.registerStdFactories();
    _ = app.resources.loadPackList("assets/packs/boot_shaders.list", .shader_source) catch |err| {
        engine.log.warn(.assets, "boot pack missing ({s}), falling back", .{@errorName(err)});
        _ = try app.resources.acquireClass("assets/shaders/basic.wgsl", .shader_source);
    };
    app.boot_shader = app.resources.handleOf("assets/shaders/basic.wgsl");
    if (app.resources.bytes(app.boot_shader)) |data| {
        engine.log.info(.assets, "boot shader_source ({d} bytes)", .{data.len});
    }

    // Enumerate modes (Dagor get_video_modes_list role).
    if (engine.render.video.listVideoModes(allocator, video.monitor_index)) |modes| {
        defer allocator.free(modes);
        engine.log.info(.core, "display modes available: {d}", .{modes.len});
    } else |_| {}

    zgui.init(allocator);
    _ = zgui.io.addFontDefault(null);
    zgui.backend.init(
        window,
        app.renderer.gctx.device,
        @intFromEnum(zgpu.GraphicsContext.swapchain_format),
        @intFromEnum(wgpu.TextureFormat.undef),
    );

    // Boot splash clear+cube once (Dagor init_video first present).
    app.renderer.drawBaseOnlyFrame(false);

    app.boot_scene.load();
    app.overlay_scene.load();
    _ = try app.boot_scene.world.createEntitySync("moving_marker", .{});
    try app.boot_scene.world.createEntityAsync("static_marker", .{});
    _ = try app.overlay_scene.world.createEntitySync("static_marker", .{});
    _ = try app.boot_scene.world.getOrCreateSingleton("boot_state", "static_marker");
    app.scenes.select(&app.boot_scene);
    app.scenes.selectSecondary(&app.overlay_scene);

    {
        const cam = app.renderer.camera.position;
        try app.boot_scene.streamer.preloadAtPos(.{ cam[0], cam[1], cam[2] }, 0);
    }
    app.events.publish(.{ .id = .scene_loaded });
    engine.log.info(.scene, "scenes ready primary={s} secondary={s} entities={d}", .{
        app.boot_scene.name,
        app.overlay_scene.name,
        app.boot_scene.world.entityCount(),
    });
    engine.log.info(.core, "press ` or F1 for debug console; --base-only for §1.3 path", .{});

    var loop = try engine.GameLoop.init(.{});
    app.loop = &loop;
    loop.run(.{
        .context = &app,
        .fixedUpdate = App.fixedUpdate,
        .frameUpdate = App.frameUpdate,
        .shouldQuit = App.shouldQuit,
    });

    engine.log.info(.core, "TucanoEngine shutdown", .{});
}

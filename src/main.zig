const std = @import("std");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");
const engine = @import("TucanoEngine");

const window_title = "TucanoEngine";
const window_width: i32 = 1280;
const window_height: i32 = 720;

var g_console: *engine.DebugConsole = undefined;

fn logSink(level: engine.log.Level, _: engine.log.Channel, message: []const u8) void {
    g_console.push(level, message);
}

const App = struct {
    window: *zglfw.Window,
    renderer: engine.Renderer,
    scene: engine.Scene,
    resources: engine.ResourceManager,
    events: engine.EventBus,
    console: engine.DebugConsole,
    loop: ?*engine.GameLoop = null,
    wants_quit: bool = false,
    esc_was_down: bool = false,

    fn shouldQuit(ctx: *anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.window.shouldClose() or self.wants_quit or self.console.quit_requested;
    }

    fn fixedUpdate(ctx: *anyopaque, dt: f64) void {
        _ = ctx;
        _ = dt;
    }

    fn frameUpdate(ctx: *anyopaque, dt: f64, alpha: f64) void {
        _ = alpha;
        const self: *App = @ptrCast(@alignCast(ctx));
        zglfw.pollEvents();

        const grave = self.window.getKey(.grave_accent) == .press;
        const f1 = self.window.getKey(.F1) == .press;
        const esc = self.window.getKey(.escape) == .press;
        const was_open = self.console.open;
        _ = self.console.handleInput(grave, f1, esc);
        if (esc and !self.esc_was_down and !was_open) {
            self.wants_quit = true;
        }
        self.esc_was_down = esc;

        self.console.frame_dt = @floatCast(dt);
        if (dt > 0.0001) {
            const instant: f32 = @floatCast(1.0 / dt);
            self.console.fps = self.console.fps * 0.9 + instant * 0.1;
        }

        const gctx = self.renderer.gctx;
        zgui.backend.newFrame(gctx.swapchain_descriptor.width, gctx.swapchain_descriptor.height);
        self.console.draw();
        self.renderer.drawFrame(@floatCast(dt), true);
    }
};

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

    try zglfw.init();
    defer zglfw.terminate();

    zglfw.windowHint(.client_api, .no_api);
    const window = try zglfw.Window.create(window_width, window_height, window_title, null, null);
    defer window.destroy();
    window.setSizeLimits(640, 360, -1, -1);

    var app = App{
        .window = window,
        .renderer = try engine.Renderer.create(allocator, window),
        .scene = try engine.Scene.create(allocator, "boot"),
        .resources = engine.ResourceManager.init(allocator),
        .events = engine.EventBus.init(allocator),
        .console = engine.DebugConsole.init(),
    };
    defer {
        zgui.backend.deinit();
        zgui.deinit();
        app.events.deinit();
        app.resources.deinit();
        app.scene.destroy();
        app.renderer.destroy();
    }

    g_console = &app.console;
    engine.log.setSink(logSink);
    defer engine.log.setSink(null);

    zgui.init(allocator);
    _ = zgui.io.addFontDefault(null);
    zgui.backend.init(
        window,
        app.renderer.gctx.device,
        @intFromEnum(zgpu.GraphicsContext.swapchain_format),
        @intFromEnum(wgpu.TextureFormat.undef),
    );

    app.scene.load();
    engine.log.info(.scene, "scene '{s}' loaded", .{app.scene.name});
    engine.log.info(.core, "press ` or F1 for debug console", .{});

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

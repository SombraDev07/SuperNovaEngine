const std = @import("std");
const time = @import("time.zig");
const log = @import("log.zig");
const assert = @import("assert.zig");
const profile = @import("profile.zig");

pub const Config = struct {
    /// Fixed simulation step in seconds (default 60 Hz).
    fixed_dt: f64 = 1.0 / 60.0,
    /// Max simulation steps per frame (avoids spiral of death).
    max_steps: u32 = 8,
};

pub const Callbacks = struct {
    context: *anyopaque,
    fixedUpdate: *const fn (context: *anyopaque, dt: f64) void,
    frameUpdate: *const fn (context: *anyopaque, dt: f64, alpha: f64) void,
    shouldQuit: *const fn (context: *anyopaque) bool,
};

/// Fixed-timestep game loop with residual accumulator for smooth rendering.
pub const GameLoop = struct {
    config: Config,
    clock: time.Clock,
    accumulator: f64 = 0.0,
    frame_count: u64 = 0,
    sim_count: u64 = 0,
    running: bool = false,

    pub fn init(config: Config) !GameLoop {
        assert.that(config.fixed_dt > 0.0, "fixed_dt must be > 0");
        assert.that(config.max_steps > 0, "max_steps must be > 0");
        return .{
            .config = config,
            .clock = try time.Clock.start(),
        };
    }

    pub fn run(self: *GameLoop, callbacks: Callbacks) void {
        self.running = true;
        log.info(.core, "game loop started (fixed_dt={d:.4}s)", .{self.config.fixed_dt});

        while (self.running and !callbacks.shouldQuit(callbacks.context)) {
            const frame_zone = profile.zoneColor(@src(), "Frame", 0x00_44_aa_ff);
            defer {
                frame_zone.End();
                profile.frameMark();
            }

            var frame_dt = self.clock.tick();
            if (frame_dt > 0.25) frame_dt = 0.25;

            self.accumulator += frame_dt;

            {
                const sim_zone = profile.zoneColor(@src(), "FixedUpdate", 0x00_22_cc_66);
                defer sim_zone.End();

                var steps: u32 = 0;
                while (self.accumulator >= self.config.fixed_dt and steps < self.config.max_steps) {
                    callbacks.fixedUpdate(callbacks.context, self.config.fixed_dt);
                    self.accumulator -= self.config.fixed_dt;
                    self.sim_count += 1;
                    steps += 1;
                }

                if (steps == self.config.max_steps) {
                    self.accumulator = 0.0;
                }
            }

            const alpha = self.accumulator / self.config.fixed_dt;
            {
                const update_zone = profile.zoneColor(@src(), "FrameUpdate", 0x00_cc_aa_22);
                defer update_zone.End();
                callbacks.frameUpdate(callbacks.context, frame_dt, alpha);
            }
            self.frame_count += 1;
        }

        log.info(.core, "game loop stopped (frames={d}, sims={d})", .{ self.frame_count, self.sim_count });
    }

    pub fn stop(self: *GameLoop) void {
        self.running = false;
    }
};

test "game loop config defaults" {
    const cfg = Config{};
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 60.0), cfg.fixed_dt, 0.0001);
}

const std = @import("std");

/// Fixed timestep clock used by the game loop.
pub const Clock = struct {
    /// Seconds since the clock was created / reset.
    elapsed: f64 = 0.0,
    /// Last raw timestamp from `std.time.Timer`.
    timer: std.time.Timer,

    pub fn start() !Clock {
        return .{
            .elapsed = 0.0,
            .timer = try std.time.Timer.start(),
        };
    }

    /// Returns delta seconds since the previous tick and advances elapsed time.
    pub fn tick(self: *Clock) f64 {
        const nanos = self.timer.lap();
        const dt = @as(f64, @floatFromInt(nanos)) / std.time.ns_per_s;
        self.elapsed += dt;
        return dt;
    }

    pub fn reset(self: *Clock) void {
        self.elapsed = 0.0;
        self.timer.reset();
    }
};

test "clock advances" {
    var clock = try Clock.start();
    std.Thread.sleep(1 * std.time.ns_per_ms);
    const dt = clock.tick();
    try std.testing.expect(dt > 0.0);
    try std.testing.expect(clock.elapsed > 0.0);
}

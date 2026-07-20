const std = @import("std");
const ztracy = @import("ztracy");

pub const ZoneCtx = ztracy.ZoneCtx;

/// Begin a named Tracy zone. Call `defer zone.End()`.
pub fn zone(comptime src: std.builtin.SourceLocation, comptime name: [*:0]const u8) ZoneCtx {
    return ztracy.ZoneN(src, name);
}

pub fn zoneColor(
    comptime src: std.builtin.SourceLocation,
    comptime name: [*:0]const u8,
    comptime color: u32,
) ZoneCtx {
    return ztracy.ZoneNC(src, name, color);
}

pub fn frameMark() void {
    ztracy.FrameMark();
}

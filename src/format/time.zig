//! Commit times as text.

const std = @import("std");

/// git's `%ai` format, in the signature's own time zone.
pub const IsoDate = struct {
    time: i64,
    tz: i16,
    /// RFC 3339 instead, for --json.
    rfc3339: bool = false,

    /// Year 0000 and 9999, the range both formats have four digits for.
    pub const min_local: i64 = -62167219200;
    pub const max_local: i64 = 253402300799;

    /// Times outside years 0000 to 9999 (git takes any number) print as
    /// the nearest end of that range.
    pub fn format(d: IsoDate, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const local = std.math.clamp(d.time +| @as(i64, d.tz) * 60, min_local, max_local);
        const days = @divFloor(local, 86400);
        const secs: u32 = @intCast(local - days * 86400);
        const civil = civilFromDays(days);
        const abs_tz: u16 = @abs(d.tz);
        const args = .{
            @as(u32, @intCast(civil.year)),      civil.month,      civil.day,
            secs / 3600,                         (secs / 60) % 60, secs % 60,
            @as(u8, if (d.tz < 0) '-' else '+'), abs_tz / 60,      abs_tz % 60,
        };
        if (d.rfc3339) {
            try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>2}:{d:0>2}", args);
        } else {
            try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {c}{d:0>2}{d:0>2}", args);
        }
    }
};

/// Howard Hinnant's days-from-civil, inverted.
fn civilFromDays(z_in: i64) struct { year: i64, month: u8, day: u8 } {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097;
    const yoe = @divFloor(
        doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096),
        365,
    );
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = if (m <= 2) y + 1 else y, .month = m, .day = d };
}

test IsoDate {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f}", .{IsoDate{ .time = 1760799642, .tz = 330 }});
    try t.expectEqualStrings("2025-10-18 20:30:42 +0530", w.buffered());
    w = .fixed(&buf);
    try w.print("{f}", .{IsoDate{ .time = 0, .tz = -60 }});
    try t.expectEqualStrings("1969-12-31 23:00:00 -0100", w.buffered());
}

test "IsoDate out of range" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f}", .{IsoDate{ .time = std.math.maxInt(i64), .tz = 60, .rfc3339 = true }});
    try t.expectEqualStrings("9999-12-31T23:59:59+01:00", w.buffered());
    w = .fixed(&buf);
    try w.print("{f}", .{IsoDate{ .time = -99999999999, .tz = 0 }});
    try t.expectEqualStrings("0000-01-01 00:00:00 +0000", w.buffered());
}

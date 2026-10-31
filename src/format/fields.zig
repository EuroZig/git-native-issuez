//! Grammars of the extension trailers. Anything that doesn't parse is
//! invalid: kept and reported, never used. Writers only emit values these
//! parsers accept.

const std = @import("std");
const uuid = @import("uuid.zig");

/// `<email>`, or `<lowercase-uuid> <email>`.
pub const Assignee = struct {
    uuid: ?[]const u8,
    email: []const u8,

    /// If the first word isn't a UUID the whole value is the email, like
    /// format 1 reads it (upstream accepts `user name@x.y`). Null when
    /// empty, or for a UUID followed by nothing or by more than one word.
    pub fn parse(value: []const u8) ?Assignee {
        if (value.len == 0) return null;
        const space = std.mem.findScalar(u8, value, ' ') orelse
            return .{ .uuid = null, .email = value };
        const id = value[0..space];
        if (!uuid.isCanonical(id)) return .{ .uuid = null, .email = value };
        const email = value[space + 1 ..];
        if (email.len == 0 or std.mem.findAny(u8, email, " \t") != null) return null;
        return .{ .uuid = id, .email = email };
    }
};

/// `YYYY-MM-DD`, no time or zone.
pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,

    pub fn parse(s: []const u8) ?Date {
        if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
        for (s, 0..) |c, i| if (i != 4 and i != 7 and !std.ascii.isDigit(c)) return null;
        const y = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
        const m = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
        const d = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
        if (y == 0 or m < 1 or m > 12 or d < 1) return null;
        if (d > std.time.epoch.getDaysInMonth(y, @enumFromInt(m))) return null;
        return .{ .year = y, .month = m, .day = d };
    }

    pub fn order(a: Date, b: Date) std.math.Order {
        if (a.year != b.year) return std.math.order(a.year, b.year);
        if (a.month != b.month) return std.math.order(a.month, b.month);
        return std.math.order(a.day, b.day);
    }

    pub fn format(d: Date, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
    }
};

/// 10 years, far beyond any real estimate.
pub const max_estimate_minutes: u32 = 10 * 366 * 24 * 60;

/// Decimal, `0` is valid.
pub fn parseMinutes(s: []const u8) ?u32 {
    if (s.len == 0 or s.len > 10) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    if (s.len > 1 and s[0] == '0') return null;
    const v = std.fmt.parseInt(u32, s, 10) catch return null;
    return if (v <= max_estimate_minutes) v else null;
}

/// `90`, `2h`, `90m`, `1h30m`.
pub fn parseDuration(s: []const u8) ?u32 {
    if (parseMinutes(s)) |m| return m;
    var total: u64 = 0;
    var rest = s;
    var seen_h = false;
    var seen_m = false;
    if (rest.len == 0) return null;
    while (rest.len > 0) {
        var n: usize = 0;
        while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
        if (n == 0 or n == rest.len or n > 7) return null;
        const v = std.fmt.parseInt(u32, rest[0..n], 10) catch return null;
        switch (rest[n]) {
            'h' => {
                if (seen_h or seen_m) return null;
                seen_h = true;
                total += @as(u64, v) * 60;
            },
            'm' => {
                if (seen_m) return null;
                seen_m = true;
                total += v;
            },
            else => return null,
        }
        rest = rest[n + 1 ..];
    }
    return if (total <= max_estimate_minutes) @intCast(total) else null;
}

/// Lowercase letters, digits and `-`, starting with a letter, at most 64
/// bytes.
pub fn isSlug(s: []const u8) bool {
    if (s.len == 0 or s.len > 64 or !std.ascii.isLower(s[0])) return false;
    for (s) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return false;
    return true;
}

/// Used when `issue.workflowStates` isn't set.
pub const default_workflow = [_][]const u8{ "backlog", "ready", "in-progress", "review" };

const testing = std.testing;

test Assignee {
    const plain = Assignee.parse("a@b.c").?;
    try testing.expect(plain.uuid == null);
    const both = Assignee.parse("a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e a@b.c").?;
    try testing.expectEqualStrings("a@b.c", both.email);
    // Not the UUID form, so the whole value is the email.
    try testing.expectEqualStrings("user name@b.c", Assignee.parse("user name@b.c").?.email);
    try testing.expect(Assignee.parse("a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e a@b.c extra") == null);
    try testing.expect(Assignee.parse("") == null);
}

test Date {
    try testing.expect(Date.parse("2026-02-29") == null);
    try testing.expect(Date.parse("2028-02-29") != null);
    try testing.expect(Date.parse("2026-13-01") == null);
    try testing.expect(Date.parse("2026-1-01") == null);
    try testing.expect(Date.parse("2026-01-01T00:00") == null);
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f}", .{Date.parse("2026-12-01").?});
    try testing.expectEqualStrings("2026-12-01", w.buffered());
}

test "minutes and durations" {
    try testing.expectEqual(@as(?u32, 0), parseMinutes("0"));
    try testing.expectEqual(@as(?u32, null), parseMinutes("007"));
    try testing.expectEqual(@as(?u32, null), parseMinutes("-1"));
    try testing.expectEqual(@as(?u32, 120), parseDuration("2h"));
    try testing.expectEqual(@as(?u32, 90), parseDuration("1h30m"));
    try testing.expectEqual(@as(?u32, 90), parseDuration("90m"));
    try testing.expectEqual(@as(?u32, null), parseDuration("30m1h"));
    try testing.expectEqual(@as(?u32, null), parseDuration("2x"));
}

test isSlug {
    try testing.expect(isSlug("in-progress"));
    try testing.expect(!isSlug("In-Progress"));
    try testing.expect(!isSlug("1st"));
    try testing.expect(!isSlug(""));
}

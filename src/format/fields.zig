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

    pub fn eql(a: Date, b: Date) bool {
        return a.order(b) == .eq;
    }

    /// The first and last dates `fromDays` gives: years 1 to 9999, what
    /// `parse` reads.
    pub const min_days: i32 = -719_162; // 0001-01-01
    pub const max_days: i32 = 2_932_896; // 9999-12-31

    /// Days since 1970-01-01, negative before.
    pub fn toDays(d: Date) i32 {
        // Howard Hinnant's days_from_civil, with March as the first month.
        const y: i32 = @as(i32, d.year) - @intFromBool(d.month <= 2);
        const era = @divFloor(y, 400);
        const yoe = y - era * 400;
        const m: i32 = d.month;
        const mp = if (m > 2) m - 3 else m + 9;
        const doy = @divFloor(153 * mp + 2, 5) + @as(i32, d.day) - 1;
        const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
        return era * 146_097 + doe - 719_468;
    }

    /// Clamped to `min_days` and `max_days`.
    pub fn fromDays(days_in: i32) Date {
        const days = std.math.clamp(days_in, min_days, max_days);
        const z = days + 719_468;
        const era = @divFloor(z, 146_097);
        const doe = z - era * 146_097;
        const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
        const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp = @divFloor(5 * doy + 2, 153);
        const day = doy - @divFloor(153 * mp + 2, 5) + 1;
        const month = if (mp < 10) mp + 3 else mp - 9;
        const year = yoe + era * 400 + @intFromBool(month <= 2);
        return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
    }

    pub fn addDays(d: Date, n: i32) Date {
        return fromDays(d.toDays() +| n);
    }

    pub fn daysInMonth(d: Date) u8 {
        return std.time.epoch.getDaysInMonth(d.year, @enumFromInt(d.month));
    }

    /// The month's last day.
    pub fn endOfMonth(d: Date) Date {
        return .{ .year = d.year, .month = d.month, .day = d.daysInMonth() };
    }

    /// The same day `n` months on, at most the month's last. Null outside
    /// years 1 to 9999.
    pub fn addMonths(d: Date, n: i32) ?Date {
        const total = @as(i64, d.year) * 12 + (d.month - 1) + n;
        const year = @divFloor(total, 12);
        if (year < 1 or year > 9999) return null;
        const first: Date = .{ .year = @intCast(year), .month = @intCast(@mod(total, 12) + 1), .day = 1 };
        return .{ .year = first.year, .month = first.month, .day = @min(d.day, first.daysInMonth()) };
    }

    /// `b` minus `a`, in days.
    pub fn daysBetween(a: Date, b: Date) i32 {
        return b.toDays() - a.toDays();
    }

    /// The UTC date of a Unix time.
    pub fn fromUnix(seconds: i64) Date {
        const days = std.math.clamp(@divFloor(seconds, std.time.s_per_day), min_days, max_days);
        return fromDays(@intCast(days));
    }

    /// The date of a Unix time where the clock is `utc_offset_s` seconds
    /// ahead of UTC: the local date there.
    pub fn fromUnixLocal(seconds: i64, utc_offset_s: i32) Date {
        return fromUnix(seconds +| utc_offset_s);
    }

    pub fn weekday(d: Date) Weekday {
        // 1970-01-01 was a Thursday.
        return @enumFromInt(@as(u3, @intCast(@mod(d.toDays() + 3, 7))));
    }
};

/// Monday first, as ISO 8601 counts.
pub const Weekday = enum(u3) {
    mon,
    tue,
    wed,
    thu,
    fri,
    sat,
    sun,

    pub fn parse(s: []const u8) ?Weekday {
        if (s.len < 3) return null;
        inline for (std.meta.fields(Weekday)) |f| {
            if (std.ascii.eqlIgnoreCase(s[0..3], f.name)) {
                const full = [_][]const u8{ "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday" };
                const long = full[f.value];
                if (s.len == 3 or (s.len <= long.len and std.ascii.eqlIgnoreCase(s, long[0..s.len]))) return @enumFromInt(f.value);
            }
        }
        return null;
    }

    pub fn short(w: Weekday) []const u8 {
        return switch (w) {
            .mon => "Mon",
            .tue => "Tue",
            .wed => "Wed",
            .thu => "Thu",
            .fri => "Fri",
            .sat => "Sat",
            .sun => "Sun",
        };
    }
};

/// The days of the week that count as working days.
pub const WorkDays = struct {
    bits: u7 = 0x7f,

    pub const all: WorkDays = .{};
    pub const weekdays: WorkDays = .{ .bits = 0x1f };

    pub fn has(w: WorkDays, d: Weekday) bool {
        return w.bits & (@as(u7, 1) << @intFromEnum(d)) != 0;
    }

    pub fn with(w: WorkDays, d: Weekday) WorkDays {
        return .{ .bits = w.bits | (@as(u7, 1) << @intFromEnum(d)) };
    }

    pub fn isWorkDay(w: WorkDays, d: Date) bool {
        return w.bits == 0 or w.has(d.weekday());
    }

    /// `n` working days after `d` (before it when negative). From a day
    /// that isn't one, the first step lands on the next working day. With
    /// no working days at all, every day counts.
    pub fn add(w: WorkDays, d: Date, n_in: i32) Date {
        if (w.bits == 0 or w.bits == 0x7f) return d.addDays(n_in);
        // Farther than any date: the steps below can't overflow.
        const range = Date.max_days - Date.min_days;
        const n = std.math.clamp(n_in, -range, range);
        const step: i32 = if (n < 0) -1 else 1;
        var left: i32 = if (n < 0) -n else n;
        var days = d.toDays();
        // Whole weeks first, so a long move doesn't walk day by day.
        const per_week: i32 = @popCount(w.bits);
        const weeks = @divFloor(left, per_week) -| 1;
        if (weeks > 0) {
            days +|= step * weeks * 7;
            left -= weeks * per_week;
        }
        while (left > 0) {
            days += step;
            if (w.isWorkDay(Date.fromDays(days))) left -= 1;
            if (days <= Date.min_days or days >= Date.max_days) break;
        }
        return Date.fromDays(days);
    }

    /// The working days from `a` to `b`, both included: a span's length.
    /// Zero when `b` is before `a`.
    pub fn countInclusive(w: WorkDays, a: Date, b: Date) u32 {
        const x = a.toDays();
        const y = b.toDays();
        if (y < x) return 0;
        const total: u32 = @intCast(y - x + 1);
        if (w.bits == 0 or w.bits == 0x7f) return total;
        const per_week: u32 = @popCount(w.bits);
        var n: u32 = (total / 7) * per_week;
        var d = x + @as(i32, @intCast((total / 7) * 7));
        while (d <= y) : (d += 1) {
            if (w.isWorkDay(Date.fromDays(d))) n += 1;
        }
        return n;
    }

    /// `mon,tue,wed`: names (`mon` or `monday`, any case), comma or space
    /// separated. Null for an unknown name; an empty list is `all`.
    pub fn parse(s: []const u8) ?WorkDays {
        var out: WorkDays = .{ .bits = 0 };
        var it = std.mem.tokenizeAny(u8, s, ", \t");
        while (it.next()) |name| out = out.with(Weekday.parse(name) orelse return null);
        return if (out.bits == 0) all else out;
    }
};

test "Date: days, weekdays, round trips" {
    const t = std.testing;
    const epoch: Date = .{ .year = 1970, .month = 1, .day = 1 };
    try t.expectEqual(@as(i32, 0), epoch.toDays());
    try t.expectEqual(Weekday.thu, epoch.weekday());
    const leap = Date.parse("2024-02-29").?;
    try t.expect(leap.addDays(1).eql(Date.parse("2024-03-01").?));
    try t.expect(Date.parse("2100-02-28").?.addDays(1).eql(Date.parse("2100-03-01").?));
    try t.expect(Date.parse("2000-02-28").?.addDays(1).eql(Date.parse("2000-02-29").?));
    try t.expect(Date.parse("2026-12-31").?.addDays(1).eql(Date.parse("2027-01-01").?));
    try t.expectEqual(Weekday.wed, Date.parse("2026-11-04").?.weekday());
    try t.expectEqual(@as(i32, 30), Date.parse("2026-11-01").?.daysBetween(Date.parse("2026-12-01").?));
    try t.expect(Date.fromUnix(1_700_000_000).eql(Date.parse("2023-11-14").?));
    try t.expect(Date.fromUnix(-1).eql(Date.parse("1969-12-31").?));
    // 2023-11-14 22:13:20 UTC: the 15th two hours east, the 14th west.
    try t.expect(Date.fromUnixLocal(1_700_000_000, 2 * 3600).eql(Date.parse("2023-11-15").?));
    // Months: the day stays, at most the month's last.
    try t.expect(Date.parse("2026-01-31").?.addMonths(1).?.eql(Date.parse("2026-02-28").?));
    try t.expect(Date.parse("2024-01-31").?.addMonths(1).?.eql(Date.parse("2024-02-29").?));
    try t.expect(Date.parse("2026-11-04").?.addMonths(-11).?.eql(Date.parse("2025-12-04").?));
    try t.expect(Date.parse("2026-11-04").?.addMonths(12 * 8000) == null);
    try t.expect(Date.parse("0001-01-01").?.addMonths(-1) == null);
    try t.expect(Date.parse("2026-02-10").?.endOfMonth().eql(Date.parse("2026-02-28").?));
    try t.expect(Date.fromUnixLocal(1_700_000_000, -8 * 3600).eql(Date.parse("2023-11-14").?));
    try t.expect(Date.fromUnixLocal(0, -1).eql(Date.parse("1969-12-31").?));
    try t.expect(Date.fromDays(Date.min_days).eql(.{ .year = 1, .month = 1, .day = 1 }));
    try t.expect(Date.fromDays(Date.max_days).eql(.{ .year = 9999, .month = 12, .day = 31 }));
    try t.expect(Date.fromDays(std.math.maxInt(i32)).eql(.{ .year = 9999, .month = 12, .day = 31 }));
    // Every day of four centuries, against std.time.epoch.
    var days: i32 = -146_097;
    while (days < 146_097 * 2) : (days += 1) {
        const d = Date.fromDays(days);
        try t.expectEqual(days, d.toDays());
        if (days >= 0) {
            const es: std.time.epoch.EpochDay = .{ .day = @intCast(days) };
            const yd = es.calculateYearDay();
            const md = yd.calculateMonthDay();
            try t.expectEqual(yd.year, d.year);
            try t.expectEqual(md.month.numeric(), d.month);
            try t.expectEqual(md.day_index + 1, d.day);
        }
    }
}

test "WorkDays" {
    const t = std.testing;
    try t.expectEqual(WorkDays.weekdays, WorkDays.parse("mon,tue, wed thu,Friday").?);
    try t.expectEqual(WorkDays.all, WorkDays.parse(" , ").?);
    try t.expect(WorkDays.parse("mon,funday") == null);
    try t.expect(WorkDays.parse("mo") == null);
    const w = WorkDays.weekdays;
    const fri = Date.parse("2026-11-06").?;
    try t.expect(w.add(fri, 1).eql(Date.parse("2026-11-09").?));
    try t.expect(w.add(Date.parse("2026-11-09").?, -1).eql(fri));
    try t.expect(w.add(fri, 0).eql(fri));
    try t.expect(w.add(Date.parse("2026-11-07").?, 1).eql(Date.parse("2026-11-09").?));
    try t.expect(w.add(fri, 10).eql(Date.parse("2026-11-20").?));
    try t.expect(w.add(fri, -10).eql(Date.parse("2026-10-23").?));
    try t.expectEqual(@as(u32, 5), w.countInclusive(Date.parse("2026-11-02").?, fri));
    try t.expectEqual(@as(u32, 6), w.countInclusive(fri, Date.parse("2026-11-13").?));
    try t.expectEqual(@as(u32, 0), w.countInclusive(fri, Date.parse("2026-11-05").?));
    try t.expectEqual(@as(u32, 0), w.countInclusive(Date.parse("2026-11-07").?, Date.parse("2026-11-08").?));
    try t.expectEqual(@as(u32, 3), WorkDays.all.countInclusive(fri, Date.parse("2026-11-08").?));
    // Long moves agree with walking day by day.
    var n: i32 = -40;
    while (n <= 40) : (n += 1) {
        var walked = fri;
        var left = if (n < 0) -n else n;
        while (left > 0) {
            walked = walked.addDays(if (n < 0) -1 else 1);
            if (w.isWorkDay(walked)) left -= 1;
        }
        try t.expect(w.add(fri, n).eql(walked));
    }
    // The ends of the range, not an overflow.
    const first = Date.fromDays(Date.min_days);
    const last = Date.fromDays(Date.max_days);
    try t.expect(w.add(fri, std.math.minInt(i32)).eql(first));
    try t.expect(w.add(fri, std.math.maxInt(i32)).eql(last));
    try t.expect(WorkDays.all.add(fri, std.math.minInt(i32)).eql(first));
    try t.expect(w.add(first, -1).eql(first));
}

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

pub const MilestoneMode = enum {
    inherit,
    /// No milestone, and stop inheriting.
    none,
    explicit,

    pub fn parse(s: []const u8) ?MilestoneMode {
        return std.meta.stringToEnum(MilestoneMode, s);
    }

    /// The mode in effect: the written one, else `explicit` with an
    /// `X-Milestone-Id`, else `inherit` under a parent, else `none`.
    pub fn of(written: ?MilestoneMode, has_id: bool, has_parent: bool) MilestoneMode {
        return written orelse if (has_id) .explicit else if (has_parent) .inherit else .none;
    }
};

/// `X-Milestone-Status`. Readers take a missing or unknown value as `open`.
pub const MilestoneStatus = enum {
    open,
    completed,
    retired,

    pub fn parse(s: []const u8) ?MilestoneStatus {
        return std.meta.stringToEnum(MilestoneStatus, s);
    }
};

/// `X-Deleted`: exactly `true` or `false`.
pub fn parseBool(s: []const u8) ?bool {
    if (std.mem.eql(u8, s, "true")) return true;
    if (std.mem.eql(u8, s, "false")) return false;
    return null;
}

/// `X-Event` values. A commit carries at most one.
pub const Event = enum {
    comment_edit,
    comment_delete,
    comment_restore,
    description_edit,

    /// The tag names with `-` for `_`, so the two can't drift apart.
    const names = blk: {
        const tags = @typeInfo(Event).@"enum".fields;
        var out: [tags.len][]const u8 = undefined;
        for (tags, &out) |t, *o| {
            var name: [t.name.len]u8 = t.name[0..t.name.len].*;
            std.mem.replaceScalar(u8, &name, '_', '-');
            const final = name;
            o.* = &final;
        }
        break :blk out;
    };

    pub fn parse(s: []const u8) ?Event {
        for (names, 0..) |n, i| if (std.mem.eql(u8, n, s)) return @enumFromInt(i);
        return null;
    }

    pub fn text(e: Event) []const u8 {
        return names[@intFromEnum(e)];
    }

    /// Needs `X-Comment`.
    pub fn targetsComment(e: Event) bool {
        return e != .description_edit;
    }

    /// The message text is the new content.
    pub fn carriesText(e: Event) bool {
        return e == .comment_edit or e == .description_edit;
    }
};

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

test parseBool {
    try testing.expectEqual(true, parseBool("true").?);
    try testing.expectEqual(false, parseBool("false").?);
    for ([_][]const u8{ "", "True", "yes", "1", "maybe", "true " }) |s| {
        try testing.expect(parseBool(s) == null);
    }
}

test Event {
    for (std.enums.values(Event)) |e| try testing.expectEqual(e, Event.parse(e.text()).?);
    try testing.expectEqualStrings("comment-edit", Event.comment_edit.text());
    try testing.expect(Event.parse("comment_edit") == null);
    try testing.expect(Event.parse("Comment-Edit") == null);
}

test isSlug {
    try testing.expect(isSlug("in-progress"));
    try testing.expect(!isSlug("In-Progress"));
    try testing.expect(!isSlug("1st"));
    try testing.expect(!isSlug(""));
}

test MilestoneMode {
    try testing.expectEqual(MilestoneMode.none, MilestoneMode.of(.none, true, true));
    try testing.expectEqual(MilestoneMode.explicit, MilestoneMode.of(null, true, true));
    try testing.expectEqual(MilestoneMode.inherit, MilestoneMode.of(null, false, true));
    try testing.expectEqual(MilestoneMode.none, MilestoneMode.of(null, false, false));
}

test MilestoneStatus {
    for (std.enums.values(MilestoneStatus)) |s| {
        try testing.expectEqual(s, MilestoneStatus.parse(@tagName(s)).?);
    }
    for ([_][]const u8{ "", "Completed", "done", "open " }) |s| {
        try testing.expect(MilestoneStatus.parse(s) == null);
    }
}

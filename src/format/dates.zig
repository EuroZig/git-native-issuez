//! Dates as people type them: `2026-12-01`, or relative to today for
//! convenience. What is written to git is always the absolute date
//! (`fields.Date`); these forms are never read from a trailer.
//!
//!     today  tomorrow  yesterday  +3d  -1w  +2m  fri  eom  eow

const std = @import("std");
const fields = @import("fields.zig");

const Date = fields.Date;
const Weekday = fields.Weekday;
const WorkDays = fields.WorkDays;

pub const hint = "YYYY-MM-DD, today, tomorrow, +3d, +2w, fri, eom; empty clears";

/// `d` when it is after `today`: null when clamping kept it from being.
fn after(today: Date, d: Date) ?Date {
    return if (d.order(today) == .gt) d else null;
}

/// Null when it isn't a date. `text` is trimmed. `today` is the user's
/// local date; `eow` is the week's last day in `work_days`.
pub fn parse(text_in: []const u8, today: Date, work_days: WorkDays) ?Date {
    const text = std.mem.trim(u8, text_in, " \t");
    if (text.len == 0) return null;
    if (Date.parse(text)) |d| return d;
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(text, "today") or eq(text, "now")) return today;
    // Past 9999-12-31 the days clamp: no "next" one is left there.
    if (eq(text, "tomorrow") or eq(text, "tmr")) return after(today, today.addDays(1));
    if (eq(text, "yesterday")) return today.addDays(-1);
    if (eq(text, "eom")) return today.endOfMonth();
    if (eq(text, "eow")) {
        // The week's last working day, today if it is that; once it is
        // past, the next week's.
        const sunday = today.addDays(6 - @as(i32, @backingInt(today.weekday())));
        const this_week = lastWorkDay(sunday, work_days);
        if (this_week.order(today) != .lt) return this_week;
        return after(today, lastWorkDay(sunday.addDays(7), work_days));
    }
    if (text[0] == '+' or text[0] == '-') {
        if (text.len < 3) return null;
        // Digits only after the sign: no second sign, no `_`.
        const digits = text[1 .. text.len - 1];
        if (digits.len == 0 or digits.len > 6) return null;
        for (digits) |c| if (!std.ascii.isDigit(c)) return null;
        const unit = std.ascii.toLower(text[text.len - 1]);
        const n = std.fmt.parseInt(i32, digits, 10) catch return null;
        if (n > 100_000) return null;
        const signed = if (text[0] == '-') -n else n;
        return switch (unit) {
            'd' => today.addDays(signed),
            'w' => today.addDays(signed * 7),
            'm' => today.addMonths(signed),
            'y' => today.addMonths(signed * 12),
            else => null,
        };
    }
    // A weekday: the next one, never today.
    if (Weekday.parse(text)) |w| {
        const from: i32 = @backingInt(today.weekday());
        const to: i32 = @backingInt(w);
        const ahead = @mod(to - from + 6, 7) + 1;
        return after(today, today.addDays(ahead));
    }
    return null;
}

/// The last working day on or before `sunday`, in its week.
fn lastWorkDay(sunday: Date, work_days: WorkDays) Date {
    var d = sunday;
    // Some day of the week is one: `isWorkDay` takes all with none set.
    while (!work_days.isWorkDay(d)) d = d.addDays(-1);
    return d;
}

/// "in 16d", "today", "3d late": relative to today, for due dates.
pub fn relative(buf: []u8, d: Date, today: Date) []const u8 {
    const n = today.daysBetween(d);
    if (n == 0) return "today";
    if (n == 1) return "tomorrow";
    if (n == -1) return "1d late";
    if (n < 0) return std.fmt.bufPrint(buf, "{d}d late", .{-n}) catch "";
    if (n < 100) return std.fmt.bufPrint(buf, "{d}d", .{n}) catch "";
    return std.fmt.bufPrint(buf, "{d}w", .{@divFloor(n, 7)}) catch "";
}

test parse {
    const t = std.testing;
    const today = Date.parse("2026-11-04").?; // a Wednesday
    const is = struct {
        fn f(s: []const u8, want: []const u8) !void {
            const got = parse(s, Date.parse("2026-11-04").?, .all) orelse return error.NoDate;
            try t.expect(got.eql(Date.parse(want).?));
        }
    }.f;
    try is("2026-12-01", "2026-12-01");
    try is(" today ", "2026-11-04");
    try is("Tomorrow", "2026-11-05");
    try is("+3d", "2026-11-07");
    try is("-1w", "2026-10-28");
    try is("+1m", "2026-12-04");
    try is("+1y", "2027-11-04");
    try is("fri", "2026-11-06");
    try is("wed", "2026-11-11");
    try is("monday", "2026-11-09");
    try is("eom", "2026-11-30");
    try is("eow", "2026-11-08");
    try t.expect(parse("soon", today, .all) == null);
    try t.expect(parse("+d", today, .all) == null);
    try t.expect(parse("+3x", today, .all) == null);
    try t.expect(parse("2026-13-01", today, .all) == null);
    try t.expect(parse("", today, .all) == null);
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("16d", relative(&buf, Date.parse("2026-11-20").?, today));
    try t.expectEqualStrings("3d late", relative(&buf, Date.parse("2026-11-01").?, today));
    try t.expectEqualStrings("today", relative(&buf, today, today));
}

test "parse: signs and sizes that don't fit are not dates" {
    const t = std.testing;
    const today = Date.parse("2026-11-04").?;
    for ([_][]const u8{
        "--2147483648d", "+-306783379w", "+-178956971y", "-+3d", "++3d", "+1_0d",
        "+ 3d",          "+100001d",     "+9999999d",    "+3",   "-w",   "+",
        "-",
    }) |text| {
        try t.expect(parse(text, today, .all) == null);
    }
    try t.expect(parse("+100000d", today, .all) != null);
    try t.expect(parse("-100000y", today, .all) == null); // before year 1
}

test "parse: no day after 9999-12-31" {
    const t = std.testing;
    const last = Date.parse("9999-12-31").?;
    for ([_][]const u8{ "tomorrow", "fri", "mon" }) |text| try t.expect(
        parse(text, last, .weekdays) == null,
    );
    // A Friday: the week's last working day is today, unless only Monday
    // works, whose next week isn't there.
    try t.expect(parse("eow", last, .weekdays).?.eql(last));
    try t.expect(parse("eow", last, (WorkDays{ .bits = 0 }).with(.mon)) == null);
}

test "parse: eow is the week's last working day" {
    const t = std.testing;
    const D = Date.parse;
    // 2026-11-04 is a Wednesday.
    try t.expect(parse("eow", D("2026-11-04").?, .weekdays).?.eql(D("2026-11-06").?));
    try t.expect(parse("eow", D("2026-11-06").?, .weekdays).?.eql(D("2026-11-06").?));
    // Past Friday: the next week's.
    try t.expect(parse("eow", D("2026-11-07").?, .weekdays).?.eql(D("2026-11-13").?));
    try t.expect(parse("eow", D("2026-11-08").?, .all).?.eql(D("2026-11-08").?));
}

test "parse: today is the local date, around midnight" {
    const t = std.testing;
    // 2026-11-04 23:30 UTC: already the 5th in Berlin, still the 4th in
    // New York.
    const now: i64 = (Date.parse(
        "2026-11-04",
    ).?.toDays() * @as(i64, std.time.s_per_day)) + 23 * 3600 + 30 * 60;
    const berlin = Date.fromUnixLocal(now, 3600);
    const new_york = Date.fromUnixLocal(now, -5 * 3600);
    try t.expect(parse("today", berlin, .all).?.eql(Date.parse("2026-11-05").?));
    try t.expect(parse("tomorrow", berlin, .all).?.eql(Date.parse("2026-11-06").?));
    try t.expect(parse("today", new_york, .all).?.eql(Date.parse("2026-11-04").?));
    try t.expect(parse("+1d", Date.fromUnix(now), .all).?.eql(Date.parse("2026-11-05").?));
}

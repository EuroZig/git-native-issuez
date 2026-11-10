//! The local time zone, for what "today" is: `TZ`, else /etc/localtime,
//! read without libc. A TZif file's transitions, and its POSIX rule for
//! the years after them; `TZ` may be such a rule itself. UTC where there
//! is none, like on Windows.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Date = @import("../format/fields.zig").Date;

pub const Zone = struct {
    /// When the offset changed, in Unix seconds, and to what.
    transitions: []const Transition = &.{},
    /// Before the first transition.
    initial: i32 = 0,
    /// After the last transition, or all along without any.
    rule: ?Rule = null,

    pub const utc: Zone = .{};

    pub const Transition = struct { at: i64, offset: i32 };

    pub fn deinit(z: *Zone, gpa: Allocator) void {
        gpa.free(z.transitions);
        z.* = undefined;
    }

    /// The local date at `unix_s`.
    pub fn today(z: *const Zone, unix_s: i64) Date {
        return Date.fromUnixLocal(unix_s, z.offsetAt(unix_s));
    }

    /// Seconds the local clock is ahead of UTC at `unix_s`.
    pub fn offsetAt(z: *const Zone, unix_s: i64) i32 {
        const ts = z.transitions;
        if (ts.len == 0 or unix_s < ts[0].at) {
            if (ts.len == 0) if (z.rule) |r| return r.offsetAt(unix_s);
            return z.initial;
        }
        if (unix_s >= ts[ts.len - 1].at) if (z.rule) |r| return r.offsetAt(unix_s);
        // The last transition at or before it.
        var lo: usize = 0;
        var hi: usize = ts.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (ts[mid].at <= unix_s) lo = mid else hi = mid;
        }
        return ts[lo].offset;
    }
};

/// The local date now, in the zone as configured.
pub fn today(io: std.Io, gpa: Allocator, environ_map: *const std.process.Environ.Map) Date {
    var zone = load(io, gpa, environ_map);
    defer zone.deinit(gpa);
    return zone.today(nowS(io));
}

/// The real clock, in Unix seconds.
pub fn nowS(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

/// The zone as configured; UTC when it can't be read.
pub fn load(io: std.Io, gpa: Allocator, environ_map: *const std.process.Environ.Map) Zone {
    if (@import("builtin").os.tag == .windows) return .utc;
    const tz = environ_map.get("TZ") orelse return loadFile(io, gpa, "/etc/localtime") orelse .utc;
    // Set but empty: UTC, as POSIX has it.
    if (tz.len == 0) return .utc;
    const name = if (tz[0] == ':') tz[1..] else tz;
    if (name.len > 0 and name[0] == '/') return loadFile(io, gpa, name) orelse .utc;
    if (name.len > 0 and std.mem.indexOf(u8, name, "..") == null) {
        var buf: [256]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "/usr/share/zoneinfo/{s}", .{name})) |path| {
            if (loadFile(io, gpa, path)) |z| return z;
        } else |_| {}
    }
    if (Rule.parse(name)) |r| return .{ .rule = r };
    return .utc;
}

fn loadFile(io: std.Io, gpa: Allocator, path: []const u8) ?Zone {
    // A FIFO or a terminal would block the read.
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    if (st.kind != .file) return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        gpa,
        .limited(1 << 20),
    ) catch return null;
    defer gpa.free(bytes);
    return parseTzif(gpa, bytes) catch null;
}

/// A TZif file's transitions and its rule.
pub fn parseTzif(gpa: Allocator, bytes: []const u8) (Allocator.Error || error{Malformed})!Zone {
    try checkTzif(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var tz = std.Tz.parse(gpa, &reader) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    defer tz.deinit();
    const out = try gpa.alloc(Zone.Transition, tz.transitions.len);
    for (tz.transitions, out) |t, *o| o.* = .{ .at = t.ts, .offset = t.timetype.offset };
    // Before the first transition: the first type that isn't summer time.
    const initial = for (tz.timetypes) |tt| {
        if (!tt.isDst()) break tt.offset;
    } else tz.timetypes[0].offset;
    return .{
        .transitions = out,
        .initial = initial,
        .rule = if (tz.footer) |f| Rule.parse(f) else null,
    };
}

/// What `std.Tz.parse` would overflow on instead of refusing: counts past
/// the end of the file, and leap seconds too far out or too large.
fn checkTzif(bytes: []const u8) error{Malformed}!void {
    const header_len = 44;
    const Counts = struct { isut: u64, isstd: u64, leap: u64, time: u64, type: u64, char: u64 };
    const at = struct {
        fn counts(b: []const u8, h: usize) ?Counts {
            if (b.len < h + header_len) return null;
            var c: [6]u64 = undefined;
            for (&c, 0..) |*n, k| n.* = std.mem.readInt(u32, b[h + 20 + 4 * k ..][0..4], .big);
            return .{
                .isut = c[0],
                .isstd = c[1],
                .leap = c[2],
                .time = c[3],
                .type = c[4],
                .char = c[5],
            };
        }
    };
    // Each block: its header, then times of 4 bytes (version 1) or 8.
    var h: usize = 0;
    for ([_]u64{ 4, 8 }) |time_len| {
        // Too short for a header: `std.Tz.parse` refuses it.
        const c = at.counts(bytes, h) orelse return;
        const leaps_at = h + header_len + c.time * (time_len + 1) + c.type * 6 + c.char;
        const end = leaps_at + c.leap * (time_len + 4) + c.isstd + c.isut;
        if (end > bytes.len) return error.Malformed;
        for (0..@intCast(c.leap)) |k| {
            const r = bytes[@intCast(leaps_at + k * (time_len + 4))..];
            const occur: i64 = if (time_len == 4) std.mem.readInt(
                i32,
                r[0..4],
                .big,
            ) else std.mem.readInt(i64, r[0..8], .big);
            const corr = std.mem.readInt(i32, r[@intCast(time_len)..][0..4], .big);
            if (occur > std.math.maxInt(i48) - 2419199) return error.Malformed;
            if (corr > std.math.maxInt(i16) or corr < std.math.minInt(i16)) return error.Malformed;
        }
        // Version 1 holds only the first block.
        if (bytes[h + 4] == 0) return;
        h = @intCast(end);
    }
}

/// A POSIX TZ rule: `CET-1CEST,M3.5.0,M10.5.0/3`. Offsets are stored as
/// seconds ahead of UTC; POSIX writes them the other way round.
pub const Rule = struct {
    std_offset: i32,
    dst: ?Dst = null,

    pub const Dst = struct {
        offset: i32,
        start: When,
        end: When,
    };

    /// A day of the year and the local time on it, in seconds.
    pub const When = struct {
        day: Day,
        time: i32 = 2 * 3600,

        pub const Day = union(enum) {
            /// `Mm.w.d`: weekday `d` (0 is Sunday) of week `w` (5 the
            /// last) of month `m`.
            month_week_day: struct { month: u8, week: u8, weekday: u8 },
            /// `Jn`: 1 to 365, February 29 not counted.
            julian: u16,
            /// `n`: 0 to 365, February 29 counted.
            zero_based: u16,
        };

        /// Unix seconds of it in `year`, with the local clock at `offset`.
        fn at(w: When, year: u16, offset: i32) i64 {
            const jan1 = (Date{ .year = year, .month = 1, .day = 1 }).toDays();
            const days: i32 = switch (w.day) {
                .zero_based => |n| jan1 + n,
                .julian => |n| blk: {
                    const leap = std.time.epoch.isLeapYear(year);
                    // From March on, a leap year has one day more before.
                    break :blk jan1 + n - 1 + @intFromBool(leap and n >= 60);
                },
                .month_week_day => |x| blk: {
                    const first: Date = .{ .year = year, .month = x.month, .day = 1 };
                    // Weekday 0 is Monday for `Date`, Sunday here.
                    const first_wd: i32 = @mod(@as(i32, @backingInt(first.weekday())) + 1, 7);
                    var day: i32 = 1 + @mod(
                        @as(i32, x.weekday) - first_wd,
                        7,
                    ) + (@as(i32, x.week) - 1) * 7;
                    const in_month: i32 = std.time.epoch.getDaysInMonth(
                        year,
                        @fromBackingInt(@intCast(x.month)),
                    );
                    while (day > in_month) day -= 7;
                    break :blk first.toDays() + day - 1;
                },
            };
            return @as(i64, days) * std.time.s_per_day + w.time - offset;
        }
    };

    pub fn offsetAt(r: Rule, unix_s: i64) i32 {
        const d = r.dst orelse return r.std_offset;
        const year = Date.fromUnixLocal(unix_s, r.std_offset).year;
        // The switch to summer time happens on standard time, the one
        // back on summer time.
        const start = d.start.at(year, r.std_offset);
        const end = d.end.at(year, d.offset);
        const summer = if (start < end)
            unix_s >= start and unix_s < end
        else
            // The southern hemisphere: summer over the new year.
            !(unix_s >= end and unix_s < start);
        return if (summer) d.offset else r.std_offset;
    }

    /// Null when it isn't one.
    pub fn parse(text: []const u8) ?Rule {
        var p: Parser = .{ .s = text };
        if (!p.name()) return null;
        const std_offset = -(p.time() orelse return null);
        if (p.done()) return .{ .std_offset = std_offset };
        if (!p.name()) return null;
        // Summer time an hour ahead unless said otherwise.
        const dst_offset =
            if (p.peek() == ',' or p.done()) std_offset + 3600 else -(p.time() orelse return null);
        // No rule: the US one, as most systems do.
        var start: When = .{
            .day = .{ .month_week_day = .{ .month = 3, .week = 2, .weekday = 0 } },
        };
        var end: When = .{
            .day = .{ .month_week_day = .{ .month = 11, .week = 1, .weekday = 0 } },
        };
        if (!p.done()) {
            if (!p.eat(',')) return null;
            start = p.when() orelse return null;
            if (!p.eat(',')) return null;
            end = p.when() orelse return null;
            if (!p.done()) return null;
        }
        return .{
            .std_offset = std_offset,
            .dst = .{ .offset = dst_offset, .start = start, .end = end },
        };
    }

    const Parser = struct {
        s: []const u8,
        i: usize = 0,

        fn done(p: *const Parser) bool {
            return p.i == p.s.len;
        }

        fn peek(p: *const Parser) u8 {
            return if (p.done()) 0 else p.s[p.i];
        }

        fn eat(p: *Parser, c: u8) bool {
            if (p.peek() != c) return false;
            p.i += 1;
            return true;
        }

        /// `CET`, or `<+0530>` quoted.
        fn name(p: *Parser) bool {
            const from = p.i;
            if (p.eat('<')) {
                while (!p.done() and p.peek() != '>') p.i += 1;
                return p.eat('>') and p.i - from >= 5;
            }
            while (std.ascii.isAlphabetic(p.peek())) p.i += 1;
            return p.i - from >= 3;
        }

        fn number(p: *Parser, max: u32) ?u32 {
            const from = p.i;
            var n: u32 = 0;
            while (std.ascii.isDigit(
                p.peek(),
            ) and p.i - from < 3) : (p.i += 1) n = n * 10 + (p.peek() - '0');
            if (p.i == from or n > max) return null;
            return n;
        }

        /// `[+-]hh[:mm[:ss]]` in seconds.
        fn time(p: *Parser) ?i32 {
            var sign: i32 = 1;
            if (p.eat('-')) sign = -1 else _ = p.eat('+');
            var secs: i32 = @intCast((p.number(167) orelse return null) * 3600);
            if (p.eat(':')) {
                secs += @intCast((p.number(59) orelse return null) * 60);
                if (p.eat(':')) secs += @intCast(p.number(59) orelse return null);
            }
            return sign * secs;
        }

        fn when(p: *Parser) ?When {
            var w: When = .{ .day = undefined };
            if (p.eat('M')) {
                const month = p.number(12) orelse return null;
                if (month == 0 or !p.eat('.')) return null;
                const week = p.number(5) orelse return null;
                if (week == 0 or !p.eat('.')) return null;
                const weekday = p.number(6) orelse return null;
                w.day = .{
                    .month_week_day = .{
                        .month = @intCast(month),
                        .week = @intCast(week),
                        .weekday = @intCast(weekday),
                    },
                };
            } else if (p.eat('J')) {
                const n = p.number(365) orelse return null;
                if (n == 0) return null;
                w.day = .{ .julian = @intCast(n) };
            } else {
                w.day = .{ .zero_based = @intCast(p.number(365) orelse return null) };
            }
            if (p.eat('/')) w.time = p.time() orelse return null;
            return w;
        }
    };
};

/// Seconds since the epoch at a UTC date and time, for tests.
fn utcAt(date: []const u8, h: i64, m: i64) i64 {
    return @as(i64, Date.parse(date).?.toDays()) * std.time.s_per_day + h * 3600 + m * 60;
}

test "Rule: Berlin, Sydney, fixed and invalid" {
    const t = std.testing;
    const berlin = Rule.parse("CET-1CEST,M3.5.0,M10.5.0/3").?;
    try t.expectEqual(@as(i32, 3600), berlin.offsetAt(utcAt("2026-01-15", 12, 0)));
    try t.expectEqual(@as(i32, 7200), berlin.offsetAt(utcAt("2026-07-15", 12, 0)));
    // 2026-03-29 at 01:00 UTC the clocks go to summer time.
    try t.expectEqual(@as(i32, 3600), berlin.offsetAt(utcAt("2026-03-29", 0, 59)));
    try t.expectEqual(@as(i32, 7200), berlin.offsetAt(utcAt("2026-03-29", 1, 0)));
    // 2026-10-25 at 01:00 UTC back.
    try t.expectEqual(@as(i32, 7200), berlin.offsetAt(utcAt("2026-10-25", 0, 59)));
    try t.expectEqual(@as(i32, 3600), berlin.offsetAt(utcAt("2026-10-25", 1, 0)));

    const sydney = Rule.parse("AEST-10AEDT,M10.1.0,M4.1.0/3").?;
    try t.expectEqual(@as(i32, 11 * 3600), sydney.offsetAt(utcAt("2026-01-15", 12, 0)));
    try t.expectEqual(@as(i32, 10 * 3600), sydney.offsetAt(utcAt("2026-07-15", 12, 0)));

    const kolkata = Rule.parse("<+0530>-5:30").?;
    try t.expectEqual(@as(i32, 5 * 3600 + 1800), kolkata.offsetAt(0));
    try t.expectEqual(
        @as(i32, -5 * 3600),
        Rule.parse("EST5EDT").?.offsetAt(utcAt("2026-01-15", 12, 0)),
    );
    try t.expectEqual(
        @as(i32, -4 * 3600),
        Rule.parse("EST5EDT").?.offsetAt(utcAt("2026-07-15", 12, 0)),
    );
    try t.expectEqual(@as(i32, 0), Rule.parse("UTC0").?.offsetAt(0));

    for ([_][]const u8{
        "",
        "Europe/Berlin",
        "CET",
        "CET-1CEST,M3.5.0",
        "CET-1CEST,M13.5.0,M10.5.0",
        "X-1",
    }) |bad| {
        try t.expect(Rule.parse(bad) == null);
    }
}

test "Zone: transitions, then the rule" {
    const t = std.testing;
    const rule = Rule.parse("CET-1CEST,M3.5.0,M10.5.0/3").?;
    const z: Zone = .{
        .transitions = &.{
            .{ .at = utcAt("2000-03-26", 1, 0), .offset = 7200 },
            .{ .at = utcAt("2000-10-29", 1, 0), .offset = 3600 },
        },
        .initial = 3600,
        .rule = rule,
    };
    try t.expectEqual(@as(i32, 3600), z.offsetAt(utcAt("1999-07-01", 0, 0)));
    try t.expectEqual(@as(i32, 7200), z.offsetAt(utcAt("2000-07-01", 0, 0)));
    // After the last: the rule's summer.
    try t.expectEqual(@as(i32, 7200), z.offsetAt(utcAt("2026-07-01", 0, 0)));
    try t.expectEqual(@as(i32, 0), Zone.utc.offsetAt(utcAt("2026-07-01", 0, 0)));
    // 00:30 in Berlin on 2026-11-05 is still the 4th in UTC.
    const now = utcAt("2026-11-04", 23, 30);
    try t.expect(z.today(now).eql(Date.parse("2026-11-05").?));
}

test "parseTzif: a version 2 file" {
    const t = std.testing;
    // A file with one transition (to +01:00) and a fixed rule after it.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    const header = struct {
        fn f(
            b: *std.ArrayList(u8),
            gpa: Allocator,
            timecnt: u32,
            typecnt: u32,
            charcnt: u32,
        ) !void {
            try b.appendSlice(gpa, "TZif2");
            try b.appendNTimes(gpa, 0, 15);
            for ([_]u32{ 0, 0, 0, timecnt, typecnt, charcnt }) |n| {
                var be: [4]u8 = undefined;
                std.mem.writeInt(u32, &be, n, .big);
                try b.appendSlice(gpa, &be);
            }
        }
    }.f;
    const gpa = t.allocator;
    // The version 1 block, empty but for one type.
    try header(&buf, gpa, 0, 1, 4);
    try buf.appendSlice(gpa, &.{ 0, 0, 0, 0, 0, 0 });
    try buf.appendSlice(gpa, "UTC\x00");
    // The version 2 block.
    try header(&buf, gpa, 1, 2, 8);
    var be64: [8]u8 = undefined;
    std.mem.writeInt(i64, &be64, 1000, .big);
    try buf.appendSlice(gpa, &be64);
    try buf.append(gpa, 1);
    try buf.appendSlice(gpa, &.{ 0, 0, 0, 0, 0, 0 });
    try buf.appendSlice(gpa, &.{ 0, 0, 0x0e, 0x10, 0, 4 });
    try buf.appendSlice(gpa, "UTC\x00CET\x00");
    try buf.appendSlice(gpa, "\nCET-1\n");
    var z = try parseTzif(gpa, buf.items);
    defer z.deinit(gpa);
    try t.expectEqual(@as(i32, 0), z.offsetAt(999));
    try t.expectEqual(@as(i32, 3600), z.offsetAt(1000));
    try t.expectEqual(@as(i32, 3600), z.offsetAt(utcAt("2026-07-01", 0, 0)));
}

test "parseTzif: malformed counts and leap seconds are refused, not overflowed" {
    const t = std.testing;
    const gpa = t.allocator;
    const header = struct {
        fn f(b: *std.ArrayList(u8), version: u8, counts: [6]u32) !void {
            try b.appendSlice(t.allocator, "TZif");
            try b.append(t.allocator, version);
            try b.appendNTimes(t.allocator, 0, 15);
            for (counts) |n| {
                var be: [4]u8 = undefined;
                std.mem.writeInt(u32, &be, n, .big);
                try b.appendSlice(t.allocator, &be);
            }
        }
    }.f;
    // Counts that would overflow std's u32 sum.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try header(&buf, '2', .{ 0, 0, 0, 0xffff_ffff, 1, 4 });
        try t.expectError(error.Malformed, parseTzif(gpa, buf.items));
    }
    // A leap second's correction that std's `corr + 1` would overflow.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try header(&buf, 0, .{ 0, 0, 2, 0, 1, 4 });
        try buf.appendSlice(gpa, &.{ 0, 0, 0, 0, 0, 0 });
        try buf.appendSlice(gpa, "UTC\x00");
        for ([_][2]i32{ .{ 0, 1 }, .{ 3_000_000, std.math.maxInt(i32) } }) |r| for (r) |n| {
            var be: [4]u8 = undefined;
            std.mem.writeInt(i32, &be, n, .big);
            try buf.appendSlice(gpa, &be);
        };
        try t.expectError(error.Malformed, parseTzif(gpa, buf.items));
    }
    // And an occurrence that the next record's check would overflow.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try header(&buf, '2', .{ 0, 0, 0, 0, 1, 4 });
        try buf.appendSlice(gpa, &.{ 0, 0, 0, 0, 0, 0 });
        try buf.appendSlice(gpa, "UTC\x00");
        try header(&buf, '2', .{ 0, 0, 2, 0, 1, 4 });
        try buf.appendSlice(gpa, &.{ 0, 0, 0, 0, 0, 0 });
        try buf.appendSlice(gpa, "UTC\x00");
        for ([_]struct {
            i64,
            i32,
        }{ .{ std.math.maxInt(i48), 1 }, .{ std.math.maxInt(i48), 2 } }) |r| {
            var be8: [8]u8 = undefined;
            std.mem.writeInt(i64, &be8, r[0], .big);
            try buf.appendSlice(gpa, &be8);
            var be4: [4]u8 = undefined;
            std.mem.writeInt(i32, &be4, r[1], .big);
            try buf.appendSlice(gpa, &be4);
        }
        try buf.appendSlice(gpa, "\nUTC0\n");
        try t.expectError(error.Malformed, parseTzif(gpa, buf.items));
    }
}

test "load: a TZ that isn't a regular file is UTC, without blocking" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    // Read, a terminal would wait for a line.
    try env.put("TZ", "/dev/tty");
    const z = load(std.testing.io, std.testing.allocator, &env);
    try std.testing.expectEqual(@as(usize, 0), z.transitions.len);
    try std.testing.expect(z.rule == null);
}

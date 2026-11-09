//! Milestones and dates for front ends: what is in each milestone and how
//! it is going. Pure functions over a projection, so a terminal UI and a
//! GUI show the same numbers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fields_fmt = @import("../format/fields.zig");
const projection_mod = @import("projection.zig");
const milestone_mod = @import("milestone.zig");
const settings_mod = @import("settings.zig");

const Date = fields_fmt.Date;
const Projection = projection_mod.Projection;
const Progress = projection_mod.Progress;
const Milestone = milestone_mod.Milestone;

/// One milestone's work, or the work in none.
pub const Summary = struct {
    /// Non-deleted issues whose effective milestone it is.
    issues: u32 = 0,
    open: u32 = 0,
    done: u32 = 0,
    /// Open and actively blocked.
    blocked: u32 = 0,
    /// The leaves among them, as `Projection.milestoneProgress` counts.
    leaves: Progress = .{ .closed = 0, .total = 0 },
    /// Open leaves past the first workflow state: work in progress.
    leaves_active: u32 = 0,
    /// Open, past their own due date.
    overdue: u32 = 0,
    /// Estimates of the leaves, in minutes.
    estimate_total: u64 = 0,
    estimate_done: u64 = 0,
    /// Issues with problems.
    problems: u32 = 0,
    /// The earliest start and the latest due date written on the issues.
    first_start: ?Date = null,
    last_due: ?Date = null,

    /// Done leaves out of all, 0 to 1. Zero without leaves.
    pub fn doneShare(s: Summary) f32 {
        if (s.leaves.total == 0) return 0;
        return @as(f32, @floatFromInt(s.leaves.closed)) / @as(f32, @floatFromInt(s.leaves.total));
    }
};

/// `milestones.len + 1` summaries: one per milestone, in order, then the
/// issues whose effective milestone is none or not among `milestones`
/// (a retired one's, say).
pub fn summarize(
    arena: Allocator,
    proj: *const Projection,
    milestones: []const Milestone,
    today: Date,
) Allocator.Error![]Summary {
    const out = try arena.alloc(Summary, milestones.len + 1);
    @memset(out, .{});
    var index: std.StringHashMapUnmanaged(u32) = .empty;
    try index.ensureTotalCapacity(arena, @intCast(milestones.len));
    for (milestones, 0..) |m, n| index.putAssumeCapacity(m.id, @intCast(n));
    const none_slot: u32 = @intCast(milestones.len);

    for (proj.issues, 0..) |issue, n| {
        if (issue.deleted) continue;
        const i: u32 = @intCast(n);
        const slot = if (proj.milestone[i]) |id| index.get(id) orelse none_slot else none_slot;
        const s = &out[slot];
        const done = proj.isDone(i);
        s.issues += 1;
        if (done) s.done += 1 else s.open += 1;
        if (proj.activelyBlocked(i)) s.blocked += 1;
        if (proj.problemsOf(i).len > 0) s.problems += 1;
        if (issue.due_date) |d| {
            if (!done and d.order(today) == .lt) s.overdue += 1;
            if (s.last_due == null or d.order(s.last_due.?) == .gt) s.last_due = d;
        }
        if (issue.start_date) |d| {
            if (s.first_start == null or d.order(s.first_start.?) == .lt) s.first_start = d;
        }
        // A leaf, as progress counts them.
        if (proj.leaves[i].total == 0) {
            s.leaves.total += 1;
            if (done) s.leaves.closed += 1;
            if (!done and isStarted(proj, i)) s.leaves_active += 1;
            if (issue.estimate_minutes) |e| {
                s.estimate_total += e;
                if (done) s.estimate_done += e;
            }
        }
    }
    return out;
}

/// Open, in a workflow state other than the first configured one. A
/// state that isn't configured counts: it isn't where work begins.
pub fn isStarted(proj: *const Projection, i: u32) bool {
    if (!proj.isActive(i)) return false;
    const w = proj.issues[i].workflow orelse return false;
    const states = proj.options.workflow;
    if (states.len == 0) return false;
    return !std.mem.eql(u8, w, states[0]);
}

pub const Health = enum {
    /// Completed.
    done,
    retired,
    /// Open, no due date.
    no_date,
    on_track,
    /// Due soon, or past half its time, with less done than time gone.
    /// Also any open work with a day or less left.
    at_risk,
    /// Due date passed with open work left, or with no work at all.
    overdue,

    pub fn label(h: Health) []const u8 {
        return switch (h) {
            .done => "done",
            .retired => "retired",
            .no_date => "no date",
            .on_track => "on track",
            .at_risk => "at risk",
            .overdue => "overdue",
        };
    }

    /// Worst first, for sorting.
    pub fn rank(h: Health) u8 {
        return switch (h) {
            .overdue => 0,
            .at_risk => 1,
            .on_track => 2,
            .no_date => 3,
            .done => 4,
            .retired => 5,
        };
    }
};

/// Days before the due date from which a milestone behind its time is at
/// risk, however long it is.
pub const risk_days = 7;

/// `today` is the local date where the user is, and `utc_offset_s` that
/// clock's lead on UTC: the milestone's creation is dated the same way.
pub fn health(m: Milestone, s: Summary, today: Date, utc_offset_s: i32) Health {
    switch (m.status) {
        .completed => return .done,
        .retired => return .retired,
        .open => {},
    }
    const due = m.due orelse return .no_date;
    const left = today.daysBetween(due);
    // Empty and past due: nothing came of it, it isn't on track.
    if (s.leaves.total == 0) return if (left < 0) .overdue else .on_track;
    const open_leaves = s.leaves.total - s.leaves.closed;
    if (open_leaves == 0) return .on_track;
    if (left < 0) return .overdue;
    // The time from the first start (or creation) to the due date.
    const created = Date.fromUnixLocal(m.created, utc_offset_s);
    const start = if (s.first_start) |f| (if (f.order(created) == .lt) f else created) else created;
    const length: i32 = @max(start.daysBetween(due), 1);
    const elapsed: i32 = std.math.clamp(start.daysBetween(today), 0, length);
    if (left > risk_days and elapsed * 2 < length) return .on_track;
    const time_share = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(length));
    return if (s.doneShare() < time_share or left <= 1) .at_risk else .on_track;
}

// Timelines.

/// What a schedule counts: `issue.workDays` and `issue.hoursPerDay`.
pub const Calendar = struct {
    work_days: fields_fmt.WorkDays = .all,
    hours_per_day: u8 = settings_mod.default_hours_per_day,

    /// Working days an estimate takes, at least one.
    pub fn days(c: Calendar, minutes: u32) u32 {
        const per_day: u32 = @as(u32, @max(c.hours_per_day, 1)) * 60;
        return @max(std.math.divCeil(u32, minutes, per_day) catch unreachable, 1);
    }
};

/// The dates a bar comes from: what an issue has, or what a draft would
/// give it.
pub const Dates = struct {
    start: ?Date = null,
    due: ?Date = null,
    estimate_minutes: ?u32 = null,

    pub fn of(issue: *const @import("../model/issue.zig").Issue) Dates {
        return .{
            .start = issue.start_date,
            .due = issue.due_date,
            .estimate_minutes = issue.estimate_minutes,
        };
    }
};

/// Where an issue sits on a timeline: from `start` to `end`, both days
/// included.
pub const Span = struct {
    start: Date,
    end: Date,
    shape: Shape,
    /// Not written: from the estimate.
    derived_start: bool = false,
    derived_end: bool = false,

    pub const Shape = enum {
        /// Start and end.
        bar,
        /// A due date only: one day.
        due,
        /// A start only, open-ended.
        start,
    };

    pub fn contains(sp: Span, d: Date) bool {
        return sp.start.order(d) != .gt and sp.end.order(d) != .lt;
    }
};

/// Null with neither a start nor a due date. A due date before the start
/// gives a bar from the due date to the start, which `Warning` reports.
/// An estimate counts working days from the written date, or from the
/// first working day after it (before it, from a due date).
pub fn span(dates: Dates, cal: Calendar) ?Span {
    const w = cal.work_days;
    if (dates.start) |st| {
        if (dates.due) |due| {
            if (due.order(st) == .lt) return .{ .start = due, .end = st, .shape = .bar };
            return .{ .start = st, .end = due, .shape = .bar };
        }
        if (dates.estimate_minutes) |m| {
            const n: i32 = @intCast(@min(cal.days(m), 10_000));
            const first = if (w.isWorkDay(st)) st else w.add(st, 1);
            return .{ .start = st, .end = w.add(first, n - 1), .shape = .bar, .derived_end = true };
        }
        return .{ .start = st, .end = st, .shape = .start };
    }
    const due = dates.due orelse return null;
    if (dates.estimate_minutes) |m| {
        const n: i32 = @intCast(@min(cal.days(m), 10_000));
        const last = if (w.isWorkDay(due)) due else w.add(due, -1);
        return .{
            .start = w.add(last, -(n - 1)),
            .end = due,
            .shape = .bar,
            .derived_start = true,
        };
    }
    return .{ .start = due, .end = due, .shape = .due };
}

/// Dates that override some issues' own (a draft's): `dates(context, i)`
/// for issue `i`, null for its own.
pub const Overlay = struct {
    context: *const anyopaque,
    dates: *const fn (context: *const anyopaque, i: u32) ?Dates,
};

/// The spans of every issue, by snapshot position, with `overlay`'s dates
/// where it has some.
pub fn spans(
    arena: Allocator,
    proj: *const Projection,
    cal: Calendar,
    overlay: ?Overlay,
) Allocator.Error![]?Span {
    const out = try arena.alloc(?Span, proj.issues.len);
    for (proj.issues, out, 0..) |*issue, *o, n| {
        const given = if (overlay) |x| x.dates(x.context, @intCast(n)) else null;
        o.* = span(given orelse Dates.of(issue), cal);
    }
    return out;
}

/// A milestone on a timeline: from its first issue's start to its due
/// date, or to the last issue's end when later.
pub fn milestoneSpan(
    proj: *const Projection,
    all: []const ?Span,
    id: []const u8,
    due: ?Date,
) ?Span {
    var first: ?Date = null;
    var last: ?Date = due;
    for (proj.issues, proj.milestone, all) |issue, m, sp| {
        if (issue.deleted) continue;
        if (!std.mem.eql(u8, m orelse continue, id)) continue;
        const x = sp orelse continue;
        if (first == null or x.start.order(first.?) == .lt) first = x.start;
        if (last == null or x.end.order(last.?) == .gt) last = x.end;
    }
    const end = last orelse return null;
    const start = first orelse return .{ .start = end, .end = end, .shape = .due };
    return .{ .start = if (start.order(end) == .gt) end else start, .end = end, .shape = .bar };
}

pub const Warning = union(enum) {
    /// Starts on or before the day an open blocker ends, or the open
    /// blocker has a start only: it may end any day after.
    before_blocker: u32,
    /// Ends after its milestone's due date.
    after_milestone,
    /// Its due date is before its start.
    due_before_start,

    pub fn describe(w: Warning) []const u8 {
        return switch (w) {
            .before_blocker => "starts before its blocker is done",
            .after_milestone => "ends after its milestone is due",
            .due_before_start => "due before it starts",
        };
    }
};

/// What doesn't fit for issue `i`, at most `out.len` of it.
pub fn warnings(
    proj: *const Projection,
    all: []const ?Span,
    dates: Dates,
    milestone_due: ?Date,
    i: u32,
    out: []Warning,
) []const Warning {
    var n: usize = 0;
    if (dates.start != null and dates.due != null and dates.due.?.order(dates.start.?) == .lt) {
        if (n < out.len) out[n] = .due_before_start;
        n += 1;
    }
    const me = all[i] orelse return out[0..@min(n, out.len)];
    if (!proj.isActive(i)) return out[0..@min(n, out.len)];
    if (milestone_due) |d| if (me.end.order(d) == .gt) {
        if (n < out.len) out[n] = .after_milestone;
        n += 1;
    };
    for (proj.blockers[i]) |b| {
        if (!proj.isActive(b)) continue;
        const theirs = all[b] orelse continue;
        if (theirs.shape == .start or me.start.order(theirs.end) != .gt) {
            if (n < out.len) out[n] = .{ .before_blocker = b };
            n += 1;
        }
    }
    return out[0..@min(n, out.len)];
}

const testing = std.testing;
const issue_model = @import("../model/issue.zig");

fn fake(id: []const u8, state: []const u8, ext: issue_model.Extensions) issue_model.Issue {
    var issue: issue_model.Issue = .{
        .id = id,
        .tip = undefined,
        .root = undefined,
        .roots = 1,
        .title = id,
        .title_override = null,
        .description = "",
        .state = .parse(state),
        .labels = &.{},
        .fields = &.{},
        .conflicts = &.{},
        .author = undefined,
        .created = 0,
        .updated = 0,
        .comments = &.{},
        .format_version = "1",
        .commit_count = 1,
        .log = &.{},
    };
    issue.setExtensions(ext);
    return issue;
}

fn fakeMilestone(
    id: []const u8,
    due: ?[]const u8,
    status: fields_fmt.MilestoneStatus,
    created: []const u8,
) Milestone {
    return .{
        .id = id,
        .tip = undefined,
        .name = id,
        .description = "",
        .due = if (due) |d| Date.parse(d).? else null,
        .status = status,
        .created = @as(i64, Date.parse(created).?.toDays()) * std.time.s_per_day,
        .conflicts = &.{},
    };
}

test summarize {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = Date.parse;
    var issues = [_]issue_model.Issue{
        fake("root", "open", .{ .milestone_id = "m1", .start_date = d("2026-11-02") }),
        fake(
            "kid",
            "closed",
            .{ .parent = "root", .estimate_minutes = 60, .due_date = d("2026-11-01") },
        ),
        fake(
            "kid2",
            "open",
            .{
                .parent = "root",
                .estimate_minutes = 30,
                .due_date = d("2026-11-03"),
                .blocked_by = &.{"other"},
                .workflow = "review",
            },
        ),
        fake("gone", "open", .{ .milestone_id = "m1" }),
        fake("other", "open", .{}),
        fake("old", "open", .{ .milestone_id = "m2" }),
    };
    issues[3].deleted = true;
    const ms = [_]Milestone{
        fakeMilestone("m1", "2026-12-01", .open, "2026-10-01"),
        fakeMilestone("m2", null, .retired, "2026-10-01"),
    };
    const proj = try projection_mod.build(arena, &issues, .{ .milestones = &.{
        .{ .id = "m1", .status = .open },
        .{ .id = "m2", .status = .retired },
    } });
    const out = try summarize(arena, &proj, &ms, d("2026-11-04").?);
    try testing.expectEqual(@as(usize, 3), out.len);
    const m1 = out[0];
    try testing.expectEqual(@as(u32, 3), m1.issues);
    try testing.expectEqual(@as(u32, 2), m1.open);
    try testing.expectEqual(@as(u32, 1), m1.done);
    try testing.expectEqual(@as(u32, 1), m1.blocked);
    try testing.expectEqual(Progress{ .closed = 1, .total = 2 }, m1.leaves);
    try testing.expectEqual(@as(u32, 1), m1.leaves_active);
    try testing.expectEqual(@as(u32, 1), m1.overdue); // kid2; kid is done
    try testing.expectEqual(@as(u64, 90), m1.estimate_total);
    try testing.expectEqual(@as(u64, 60), m1.estimate_done);
    try testing.expect(m1.first_start.?.eql(d("2026-11-02").?));
    try testing.expect(m1.last_due.?.eql(d("2026-11-03").?));
    // Retired: its issue has no milestone any more.
    try testing.expectEqual(@as(u32, 0), out[1].issues);
    try testing.expectEqual(@as(u32, 2), out[2].issues); // other, old
}

test health {
    const d = Date.parse;
    const half: Summary = .{ .leaves = .{ .closed = 5, .total = 10 } };
    const all: Summary = .{ .leaves = .{ .closed = 10, .total = 10 } };
    const none: Summary = .{ .leaves = .{ .closed = 0, .total = 10 } };
    const m = fakeMilestone("m", "2026-12-01", .open, "2026-11-01");
    try testing.expectEqual(
        Health.done,
        health(fakeMilestone("m", null, .completed, "2026-11-01"), half, d("2026-11-04").?, 0),
    );
    try testing.expectEqual(
        Health.retired,
        health(fakeMilestone("m", null, .retired, "2026-11-01"), half, d("2026-11-04").?, 0),
    );
    try testing.expectEqual(
        Health.no_date,
        health(fakeMilestone("m", null, .open, "2026-11-01"), half, d("2026-11-04").?, 0),
    );
    // Early on, anything goes.
    try testing.expectEqual(Health.on_track, health(m, none, d("2026-11-04").?, 0));
    // Two thirds of the time gone, half done.
    try testing.expectEqual(Health.at_risk, health(m, half, d("2026-11-21").?, 0));
    try testing.expectEqual(
        Health.on_track,
        health(m, .{ .leaves = .{ .closed = 8, .total = 10 } }, d("2026-11-21").?, 0),
    );
    // Nothing open: on track, even late.
    try testing.expectEqual(Health.on_track, health(m, all, d("2026-12-05").?, 0));
    try testing.expectEqual(Health.overdue, health(m, half, d("2026-12-02").?, 0));
    // The last day with work open.
    try testing.expectEqual(
        Health.at_risk,
        health(m, .{ .leaves = .{ .closed = 9, .total = 10 } }, d("2026-12-01").?, 0),
    );
    // Empty: on track until its due date, then overdue.
    try testing.expectEqual(Health.on_track, health(m, .{}, d("2026-12-01").?, 0));
    try testing.expectEqual(Health.overdue, health(m, .{}, d("2026-12-02").?, 0));
    // Work that started before the milestone was created: its time began
    // then, so two thirds of it are gone.
    const early: Summary = .{ .leaves = none.leaves, .first_start = d("2026-10-01") };
    try testing.expectEqual(Health.at_risk, health(m, early, d("2026-11-04").?, 0));
    // Created after its due date: overdue from the start.
    const backdated = fakeMilestone("m", "2026-10-25", .open, "2026-11-01");
    try testing.expectEqual(Health.overdue, health(backdated, half, d("2026-11-01").?, 0));
    try testing.expectEqual(Health.overdue, health(backdated, .{}, d("2026-11-01").?, 0));
    // Created at midnight UTC: an hour west it was the day before, so a
    // day more of its time is gone.
    try testing.expectEqual(Health.on_track, health(m, half, d("2026-11-16").?, 0));
    try testing.expectEqual(Health.at_risk, health(m, half, d("2026-11-16").?, -3600));
}

test span {
    const d = Date.parse;
    const cal: Calendar = .{ .work_days = .weekdays, .hours_per_day = 8 };
    // 2026-11-06 is a Friday.
    const both = span(.{ .start = d("2026-11-02"), .due = d("2026-11-06") }, cal).?;
    try testing.expectEqual(Span.Shape.bar, both.shape);
    try testing.expect(both.start.eql(d("2026-11-02").?) and both.end.eql(d("2026-11-06").?));
    // 16h from a Friday: Friday and Monday.
    const from = span(.{ .start = d("2026-11-06"), .estimate_minutes = 16 * 60 }, cal).?;
    try testing.expect(from.end.eql(d("2026-11-09").?) and from.derived_end);
    // 3 days back from a Tuesday due date: Thursday.
    const back = span(.{ .due = d("2026-11-10"), .estimate_minutes = 20 * 60 }, cal).?;
    try testing.expect(back.start.eql(d("2026-11-06").?) and back.derived_start);
    try testing.expectEqual(Span.Shape.due, span(.{ .due = d("2026-11-10") }, cal).?.shape);
    try testing.expectEqual(Span.Shape.start, span(.{ .start = d("2026-11-10") }, cal).?.shape);
    try testing.expect(span(.{ .estimate_minutes = 60 }, cal) == null);
    // Upside down: drawn the right way round.
    const flip = span(.{ .start = d("2026-11-10"), .due = d("2026-11-02") }, cal).?;
    try testing.expect(flip.start.eql(d("2026-11-02").?));
    try testing.expectEqual(@as(u32, 1), cal.days(0));
    try testing.expectEqual(@as(u32, 2), cal.days(9 * 60));
    try testing.expectEqual(@as(u32, 1), (Calendar{ .hours_per_day = 6 }).days(6 * 60));
    const max = std.math.maxInt(u32);
    try testing.expectEqual(@as(u32, 71_582_789), (Calendar{ .hours_per_day = 1 }).days(max));
    try testing.expectEqual(@as(u32, 1), (Calendar{ .hours_per_day = 0 }).days(60));
    // A huge estimate ends at the last date, without overflowing.
    const huge = span(.{ .start = d("2026-11-06"), .estimate_minutes = max }, cal).?;
    try testing.expect(huge.end.order(huge.start) == .gt);
}

test "span: anchored on a day off" {
    const d = Date.parse;
    const cal: Calendar = .{ .work_days = .weekdays, .hours_per_day = 8 };
    // 2026-11-07 is a Saturday: the work starts on Monday.
    const two = span(.{ .start = d("2026-11-07"), .estimate_minutes = 16 * 60 }, cal).?;
    try testing.expect(two.start.eql(d("2026-11-07").?) and two.end.eql(d("2026-11-10").?));
    try testing.expectEqual(@as(u32, 2), cal.work_days.countInclusive(two.start, two.end));
    const one = span(.{ .start = d("2026-11-07"), .estimate_minutes = 8 * 60 }, cal).?;
    try testing.expect(one.end.eql(d("2026-11-09").?));
    try testing.expectEqual(@as(u32, 1), cal.work_days.countInclusive(one.start, one.end));
    // Due on a Sunday: the work ends on Friday.
    const back = span(.{ .due = d("2026-11-08"), .estimate_minutes = 16 * 60 }, cal).?;
    try testing.expect(back.start.eql(d("2026-11-05").?) and back.end.eql(d("2026-11-08").?));
    try testing.expectEqual(@as(u32, 2), cal.work_days.countInclusive(back.start, back.end));
}

test warnings {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = Date.parse;
    var issues = [_]issue_model.Issue{
        fake(
            "blocker",
            "open",
            .{ .start_date = d("2026-11-02"), .due_date = d("2026-11-10"), .milestone_id = "m" },
        ),
        fake(
            "late",
            "open",
            .{
                .start_date = d("2026-11-09"),
                .due_date = d("2026-11-20"),
                .blocked_by = &.{"blocker"},
                .milestone_id = "m",
            },
        ),
        fake(
            "fine",
            "open",
            .{
                .start_date = d("2026-11-11"),
                .due_date = d("2026-11-12"),
                .blocked_by = &.{"blocker"},
            },
        ),
        fake(
            "closed",
            "closed",
            .{
                .start_date = d("2026-11-01"),
                .due_date = d("2026-11-02"),
                .blocked_by = &.{"blocker"},
            },
        ),
        fake("open-ended", "open", .{ .start_date = d("2026-11-02") }),
        fake("after", "open", .{ .start_date = d("2026-11-20"), .blocked_by = &.{"open-ended"} }),
    };
    const proj = try projection_mod.build(
        arena,
        &issues,
        .{ .milestones = &.{.{ .id = "m", .status = .open }} },
    );
    const all = try spans(arena, &proj, .{}, null);
    var buf: [4]Warning = undefined;
    const late = proj.find("late").?;
    const w = warnings(&proj, all, Dates.of(&issues[late]), d("2026-11-15"), late, &buf);
    try testing.expectEqual(@as(usize, 2), w.len);
    try testing.expectEqual(Warning.after_milestone, w[0]);
    try testing.expectEqual(proj.find("blocker").?, w[1].before_blocker);
    try testing.expectEqual(
        @as(usize, 0),
        warnings(&proj, all, Dates.of(&issues[2]), null, proj.find("fine").?, &buf).len,
    );
    try testing.expectEqual(
        @as(usize, 0),
        warnings(&proj, all, Dates.of(&issues[3]), null, proj.find("closed").?, &buf).len,
    );
    // A blocker with a start only may end any day: always a warning.
    const after = warnings(&proj, all, Dates.of(&issues[5]), null, proj.find("after").?, &buf);
    try testing.expectEqual(@as(usize, 1), after.len);
    try testing.expectEqual(proj.find("open-ended").?, after[0].before_blocker);
    const ms = milestoneSpan(&proj, all, "m", d("2026-11-15")).?;
    try testing.expect(ms.start.eql(d("2026-11-02").?) and ms.end.eql(d("2026-11-20").?));
    try testing.expect(milestoneSpan(&proj, all, "nothing", null) == null);
}

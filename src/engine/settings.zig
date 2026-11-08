//! What git config says about issues: `issue.doneStates` and
//! `issue.workflowStates`, both comma-separated lists, and for schedules
//! `issue.workDays` and `issue.hoursPerDay`.
//!
//!     git config issue.doneStates "wontfix,duplicate"
//!     git config issue.workflowStates "backlog,ready,in-progress,review"
//!     git config issue.workDays "mon,tue,wed,thu,fri"   # unset: every day
//!     git config issue.hoursPerDay 8                    # 1 to 24
//!     git config issue.autoSync 10                      # minutes; front ends fetch and merge
//!
//! `issue.remote`, the remote front ends sync with, is read by
//! `sync.defaultRemote`.

const std = @import("std");
const contract = @import("../backend/contract.zig");
const Allocator = std.mem.Allocator;
const core_fmt = @import("../format/core.zig");
const fields_fmt = @import("../format/fields.zig");
const labels_fmt = @import("../format/labels.zig");

pub const done_states_key = "issue.doneStates";
pub const workflow_states_key = "issue.workflowStates";
pub const work_days_key = "issue.workDays";
pub const hours_per_day_key = "issue.hoursPerDay";
pub const auto_sync_key = "issue.autoSync";

pub const default_hours_per_day: u8 = 8;

pub const Settings = struct {
    /// Besides `closed`. For `Repo.doneStates` and `query.Filter`.
    done_states: []const []const u8 = &core_fmt.default_done_states,
    /// What `workflow` may be set to.
    workflow_states: []const []const u8 = &fields_fmt.default_workflow,
    /// The first entry of `issue.doneStates` that isn't a state, or `open`.
    /// The defaults stand in; a front end should refuse to work with it.
    invalid_done_state: ?[]const u8 = null,
    /// The first entry of `issue.workflowStates` that isn't a workflow
    /// state. The defaults stand in, so reads still work; `checkWorkflow`
    /// fails.
    invalid_workflow_state: ?[]const u8 = null,
    /// Which days a schedule counts. Every day when unset.
    work_days: fields_fmt.WorkDays = .all,
    /// What one working day of an estimate is.
    hours_per_day: u8 = default_hours_per_day,
    /// `issue.workDays` or `issue.hoursPerDay` as given, when it doesn't
    /// parse. The defaults stand in; a front end says so.
    invalid_work_days: ?[]const u8 = null,
    invalid_hours_per_day: ?[]const u8 = null,
    /// Minutes between a front end's automatic fetch and merge (never a
    /// push). Null: off, or `0`.
    auto_sync_minutes: ?u16 = null,
    invalid_auto_sync: ?[]const u8 = null,

    pub const Error = WorkflowError;

    /// Whether two reads of git config found the same settings.
    pub fn eql(a: Settings, b: Settings) bool {
        return sameList(a.done_states, b.done_states) and
            sameList(a.workflow_states, b.workflow_states) and
            sameText(a.invalid_done_state, b.invalid_done_state) and
            sameText(a.invalid_workflow_state, b.invalid_workflow_state) and
            a.work_days.bits == b.work_days.bits and
            a.hours_per_day == b.hours_per_day and
            sameText(a.invalid_work_days, b.invalid_work_days) and
            sameText(a.invalid_hours_per_day, b.invalid_hours_per_day) and
            a.auto_sync_minutes == b.auto_sync_minutes and
            sameText(a.invalid_auto_sync, b.invalid_auto_sync);
    }

    fn sameList(x: []const []const u8, y: []const []const u8) bool {
        if (x.len != y.len) return false;
        for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
        return true;
    }

    fn sameText(x: ?[]const u8, y: ?[]const u8) bool {
        if (x == null or y == null) return x == null and y == null;
        return std.mem.eql(u8, x.?, y.?);
    }

    /// What `Repo` checks on a write that sets `workflow`, for a front end
    /// to check first and say more (the states, the bad setting).
    pub fn checkWorkflow(s: Settings, state: []const u8) Error!void {
        const states = if (s.invalid_workflow_state != null) null else s.workflow_states;
        return checkWorkflowState(states, state);
    }
};

/// What the keys' entries must be, for messages about a bad setting.
pub const done_states_rule = "states are letters, digits, '-' and '_', and 'open' can't be done";
pub const workflow_states_rule = "states are lowercase letters, digits and '-'";
pub const work_days_rule = "day names like mon,tue,wed,thu,fri";
pub const hours_per_day_rule = "a whole number of hours from 1 to 24";
pub const auto_sync_rule = "a whole number of minutes from 1 to 1440, or 0 for off";

pub const WorkflowError = error{
    /// Not a workflow state at all (lowercase letters, digits and `-`).
    InvalidValue,
    /// `issue.workflowStates` has an entry that isn't a workflow state.
    InvalidWorkflowStates,
    /// Not one of the workflow states.
    UnknownWorkflowState,
};

/// The rule for a write that sets `workflow`. `states` is null when
/// `issue.workflowStates` is invalid.
fn checkWorkflowState(states: ?[]const []const u8, state: []const u8) WorkflowError!void {
    if (!fields_fmt.isSlug(state)) return error.InvalidValue;
    const list = states orelse return error.InvalidWorkflowStates;
    if (!labels_fmt.contains(list, state)) return error.UnknownWorkflowState;
}

/// The keys' raw values, null when unset.
const Raw = struct {
    done_states: ?[]const u8 = null,
    workflow_states: ?[]const u8 = null,
    work_days: ?[]const u8 = null,
    hours_per_day: ?[]const u8 = null,
    auto_sync: ?[]const u8 = null,
};

fn parse(arena: Allocator, raw: Raw) Allocator.Error!Settings {
    const done_states = raw.done_states;
    const workflow_states = raw.workflow_states;
    var out: Settings = .{};
    if (raw.work_days) |v| {
        if (fields_fmt.WorkDays.parse(v)) |w| out.work_days = w else out.invalid_work_days = v;
    }
    if (raw.hours_per_day) |v| {
        const h = parseDigits(u8, v) orelse 0;
        if (h >= 1 and h <= 24) out.hours_per_day = h else out.invalid_hours_per_day = v;
    }
    if (raw.auto_sync) |v| {
        if (parseDigits(u16, v)) |m| {
            if (m > 1440) out.invalid_auto_sync = v else if (m > 0) out.auto_sync_minutes = m;
        } else out.invalid_auto_sync = v;
    }
    switch (try parseDoneStates(arena, done_states)) {
        .ok => |l| out.done_states = l,
        .invalid => |v| out.invalid_done_state = v,
    }
    switch (try parseWorkflowStates(arena, workflow_states)) {
        .ok => |l| out.workflow_states = l,
        .invalid => |v| out.invalid_workflow_state = v,
    }
    return out;
}

/// Plain digits, around blanks: no sign, no `_`. Null when it isn't that
/// or doesn't fit.
fn parseDigits(comptime T: type, raw: []const u8) ?T {
    const text = std.mem.trim(u8, raw, " \t");
    if (text.len == 0) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(T, text, 10) catch null;
}

/// From config entries (`.key`, `.value`) as `git config --list` gives
/// them: section and name lowercase, the last value wins.
pub fn fromConfig(
    arena: Allocator,
    entries: []const contract.ConfigEntry,
) Allocator.Error!Settings {
    var raw: Raw = .{};
    for (entries) |e| {
        if (std.ascii.eqlIgnoreCase(e.key, done_states_key)) raw.done_states = e.value;
        if (std.ascii.eqlIgnoreCase(e.key, workflow_states_key)) raw.workflow_states = e.value;
        if (std.ascii.eqlIgnoreCase(e.key, work_days_key)) raw.work_days = e.value;
        if (std.ascii.eqlIgnoreCase(e.key, hours_per_day_key)) raw.hours_per_day = e.value;
        if (std.ascii.eqlIgnoreCase(e.key, auto_sync_key)) raw.auto_sync = e.value;
    }
    return parse(arena, raw);
}

/// With one `configList` when the backend has it, else two `configGet`s.
pub fn read(
    comptime B: type,
    arena: Allocator,
    backend: *B,
) (Allocator.Error || B.Error)!Settings {
    if (@hasDecl(B, "configList")) return fromConfig(
        arena,
        try backend.configList(arena),
    );
    return parse(arena, .{
        .done_states = try backend.configGet(arena, done_states_key),
        .workflow_states = try backend.configGet(arena, workflow_states_key),
        .work_days = try backend.configGet(arena, work_days_key),
        .hours_per_day = try backend.configGet(arena, hours_per_day_key),
        .auto_sync = try backend.configGet(arena, auto_sync_key),
    });
}

/// A change to one of the two keys: set it to these states, or unset it
/// (the defaults then).
pub const Change = union(enum) { set: []const []const u8, unset };

pub const WriteSpec = struct {
    done_states: ?Change = null,
    workflow_states: ?Change = null,
};

/// Writes the keys `spec` names to the repository's git config, after
/// checking every state (`done_states_rule`, `workflow_states_rule`):
/// what a settings page saves. Read them back with `read`.
pub fn write(
    comptime B: type,
    arena: Allocator,
    backend: *B,
    spec: WriteSpec,
) (Allocator.Error || error{InvalidValue} || B.Error)!void {
    if (spec.done_states) |c| if (c == .set) for (c.set) |st| {
        if (!isDoneState(st)) return error.InvalidValue;
    };
    if (spec.workflow_states) |c| if (c == .set) for (c.set) |st| {
        if (!fields_fmt.isSlug(st)) return error.InvalidValue;
    };
    for ([_]struct { []const u8, ?Change }{
        .{ done_states_key, spec.done_states },
        .{ workflow_states_key, spec.workflow_states },
    }) |k| {
        const change = k[1] orelse continue;
        for (try backend.configGetAll(arena, k[0])) |old| try backend.configUnsetValue(k[0], old);
        if (change == .set) try backend.configAdd(k[0], try labels_fmt.join(arena, change.set));
    }
}

pub const List = union(enum) {
    ok: []const []const u8,
    /// The first entry that isn't allowed.
    invalid: []const u8,
};

/// `issue.doneStates`: states (letters, digits, `-` and `_`), not `open`.
/// Null (unset) gives the defaults, an empty list none.
fn parseDoneStates(arena: Allocator, raw: ?[]const u8) Allocator.Error!List {
    const text = raw orelse return .{ .ok = &core_fmt.default_done_states };
    return parseList(arena, text, isDoneState);
}

/// `issue.workflowStates`: lowercase letters, digits and `-`. Null or an
/// empty list gives the defaults.
fn parseWorkflowStates(arena: Allocator, raw: ?[]const u8) Allocator.Error!List {
    const text = raw orelse return .{ .ok = &fields_fmt.default_workflow };
    const list = try parseList(arena, text, fields_fmt.isSlug);
    return switch (list) {
        .ok => |l| if (l.len == 0) .{ .ok = &fields_fmt.default_workflow } else list,
        .invalid => list,
    };
}

fn isDoneState(s: []const u8) bool {
    return core_fmt.isState(s) and !std.mem.eql(u8, s, "open");
}

fn parseList(arena: Allocator, raw: []const u8, valid: fn ([]const u8) bool) Allocator.Error!List {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const s = std.mem.trim(u8, part, " \t");
        if (s.len == 0) continue;
        if (!valid(s)) return .{ .invalid = s };
        try out.append(arena, s);
    }
    return .{ .ok = out.items };
}

test parseDoneStates {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try t.expectEqual(@as(usize, 2), (try parseDoneStates(arena, null)).ok.len);
    try t.expectEqual(@as(usize, 0), (try parseDoneStates(arena, "")).ok.len);
    const l = (try parseDoneStates(arena, " wontfix , ,cancelled")).ok;
    try t.expectEqual(@as(usize, 2), l.len);
    try t.expectEqualStrings("cancelled", l[1]);
    try t.expectEqualStrings("open", (try parseDoneStates(arena, "done,open")).invalid);
    try t.expectEqualStrings("a b", (try parseDoneStates(arena, "a b")).invalid);
}

test parseWorkflowStates {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try t.expectEqual(@as(usize, 4), (try parseWorkflowStates(arena, null)).ok.len);
    try t.expectEqual(@as(usize, 4), (try parseWorkflowStates(arena, " , ")).ok.len);
    try t.expectEqual(@as(usize, 2), (try parseWorkflowStates(arena, "todo,doing")).ok.len);
    try t.expectEqualStrings(
        "In Progress",
        (try parseWorkflowStates(arena, "todo,In Progress")).invalid,
    );
}

test fromConfig {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Entry = contract.ConfigEntry;
    const s = try fromConfig(arena, &[_]Entry{
        .{ .key = "issue.donestates", .value = "wontfix" },
        .{ .key = "issue.donestates", .value = "cancelled,open" },
        .{ .key = "issue.workflowstates", .value = "todo,doing" },
        .{ .key = "issue.workdays", .value = "mon,tue,wed,thu,fri" },
        .{ .key = "issue.hoursperday", .value = "6" },
        .{ .key = "issue.autosync", .value = "15" },
    });
    try t.expectEqual(@as(?u16, 15), s.auto_sync_minutes);
    try t.expectEqualStrings("open", s.invalid_done_state.?);
    try t.expectEqual(@as(usize, 2), s.done_states.len);
    try t.expectEqualStrings("doing", s.workflow_states[1]);
    try t.expectEqual(fields_fmt.WorkDays.weekdays, s.work_days);
    try t.expectEqual(@as(u8, 6), s.hours_per_day);

    const d = try fromConfig(arena, &[_]Entry{});
    try t.expectEqual(fields_fmt.WorkDays.all, d.work_days);
    try t.expectEqual(default_hours_per_day, d.hours_per_day);
    const bad = try fromConfig(arena, &[_]Entry{
        .{ .key = "issue.workdays", .value = "mon,someday" },
        .{ .key = "issue.hoursperday", .value = "25" },
        .{ .key = "issue.autosync", .value = "soon" },
    });
    try t.expectEqualStrings("soon", bad.invalid_auto_sync.?);
    try t.expect(bad.auto_sync_minutes == null);
    try t.expect(
        (try fromConfig(
            arena,
            &[_]Entry{.{ .key = "issue.autosync", .value = "0" }},
        )).auto_sync_minutes == null,
    );
    try t.expectEqualStrings("mon,someday", bad.invalid_work_days.?);
    try t.expectEqual(fields_fmt.WorkDays.all, bad.work_days);
    try t.expectEqualStrings("25", bad.invalid_hours_per_day.?);
    try t.expectEqual(default_hours_per_day, bad.hours_per_day);
    // Plain digits only, and at most a day.
    for ([_][]const u8{ "+8", "1_0", "-1", "", "8h" }) |v| {
        const odd = try fromConfig(arena, &[_]Entry{
            .{ .key = "issue.hoursperday", .value = v },
            .{ .key = "issue.autosync", .value = v },
        });
        try t.expectEqualStrings(v, odd.invalid_hours_per_day.?);
        try t.expectEqualStrings(v, odd.invalid_auto_sync.?);
    }
    const long = try fromConfig(arena, &[_]Entry{.{ .key = "issue.autosync", .value = "1441" }});
    try t.expectEqualStrings("1441", long.invalid_auto_sync.?);
    try t.expect(long.auto_sync_minutes == null);
    const day = try fromConfig(arena, &[_]Entry{.{ .key = "issue.autosync", .value = " 1440 " }});
    try t.expectEqual(@as(?u16, 1440), day.auto_sync_minutes);
}

test "Settings.checkWorkflow" {
    const t = std.testing;
    const s: Settings = .{};
    try s.checkWorkflow("ready");
    try t.expectError(error.UnknownWorkflowState, s.checkWorkflow("done"));
    const bad: Settings = .{ .invalid_workflow_state = "X" };
    try t.expectError(error.InvalidWorkflowStates, bad.checkWorkflow("ready"));
}

test write {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const GitSim = @import("../backend/GitSim.zig");
    var world: GitSim.World = .{ .seed = 71, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    try write(GitSim, arena, &sim, .{ .done_states = .{ .set = &.{ "wontfix", "cancelled" } } });
    try write(GitSim, arena, &sim, .{ .workflow_states = .{ .set = &.{ "todo", "doing" } } });
    var s = try read(GitSim, arena, &sim);
    try t.expectEqual(@as(usize, 2), s.done_states.len);
    try t.expectEqualStrings("cancelled", s.done_states[1]);
    try t.expectEqualStrings("doing", s.workflow_states[1]);
    try write(GitSim, arena, &sim, .{ .workflow_states = .unset });
    s = try read(GitSim, arena, &sim);
    try t.expectEqual(@as(usize, 4), s.workflow_states.len);
    const done: WriteSpec = .{ .done_states = .{ .set = &.{"open"} } };
    try t.expectError(error.InvalidValue, write(GitSim, arena, &sim, done));
    const workflow: WriteSpec = .{ .workflow_states = .{ .set = &.{"In Progress"} } };
    try t.expectError(error.InvalidValue, write(GitSim, arena, &sim, workflow));
}

//! What git config says about issues: `issue.doneStates` and
//! `issue.workflowStates`, both comma-separated lists.
//!
//!     git config issue.doneStates "wontfix,duplicate"
//!     git config issue.workflowStates "backlog,ready,in-progress,review"

const std = @import("std");
const Allocator = std.mem.Allocator;
const core_fmt = @import("../format/core.zig");
const fields_fmt = @import("../format/fields.zig");
const labels_fmt = @import("../format/labels.zig");

pub const done_states_key = "issue.doneStates";
pub const workflow_states_key = "issue.workflowStates";

pub const Settings = struct {
    /// Besides `closed`. For `Repo.done_states` and `query.Filter`.
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

    pub const Error = WorkflowError;

    /// What `Repo` checks on a write that sets `workflow`, for a front end
    /// to check first and say more (the states, the bad setting).
    pub fn checkWorkflow(s: Settings, state: []const u8) Error!void {
        const states = if (s.invalid_workflow_state != null) null else s.workflow_states;
        return checkWorkflowState(states, state);
    }

    /// Sets `repo`'s done and workflow states. With an invalid
    /// `issue.workflowStates`, writes that set a workflow state then fail;
    /// with an invalid `issue.doneStates`, the defaults stand in, and a
    /// front end should refuse to go on.
    pub fn apply(s: Settings, repo: anytype) void {
        repo.done_states = s.done_states;
        repo.workflow_states = if (s.invalid_workflow_state != null) null else s.workflow_states;
    }
};

/// What the keys' entries must be, for messages about a bad setting.
pub const done_states_rule = "states are letters, digits, '-' and '_', and 'open' can't be done";
pub const workflow_states_rule = "states are lowercase letters, digits and '-'";

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
pub fn checkWorkflowState(states: ?[]const []const u8, state: []const u8) WorkflowError!void {
    if (!fields_fmt.isSlug(state)) return error.InvalidValue;
    const list = states orelse return error.InvalidWorkflowStates;
    if (!labels_fmt.contains(list, state)) return error.UnknownWorkflowState;
}

/// From the two keys' raw values, null when unset.
pub fn parse(arena: Allocator, done_states: ?[]const u8, workflow_states: ?[]const u8) Allocator.Error!Settings {
    var out: Settings = .{};
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

/// From config entries (`.key`, `.value`) as `git config --list` gives
/// them: section and name lowercase, the last value wins.
pub fn fromConfig(arena: Allocator, entries: anytype) Allocator.Error!Settings {
    var done: ?[]const u8 = null;
    var workflow: ?[]const u8 = null;
    for (entries) |e| {
        if (std.ascii.eqlIgnoreCase(e.key, done_states_key)) done = e.value;
        if (std.ascii.eqlIgnoreCase(e.key, workflow_states_key)) workflow = e.value;
    }
    return parse(arena, done, workflow);
}

/// With one `configList` when the backend has it, else two `configGet`s.
pub fn read(arena: Allocator, backend: anytype) (Allocator.Error || @TypeOf(backend.*).Error)!Settings {
    if (@hasDecl(@TypeOf(backend.*), "configList")) return fromConfig(arena, try backend.configList(arena));
    return parse(
        arena,
        try backend.configGet(arena, done_states_key),
        try backend.configGet(arena, workflow_states_key),
    );
}

pub const List = union(enum) {
    ok: []const []const u8,
    /// The first entry that isn't allowed.
    invalid: []const u8,
};

/// `issue.doneStates`: states (letters, digits, `-` and `_`), not `open`.
/// Null (unset) gives the defaults, an empty list none.
pub fn parseDoneStates(arena: Allocator, raw: ?[]const u8) Allocator.Error!List {
    const text = raw orelse return .{ .ok = &core_fmt.default_done_states };
    return parseList(arena, text, isDoneState);
}

/// `issue.workflowStates`: lowercase letters, digits and `-`. Null or an
/// empty list gives the defaults.
pub fn parseWorkflowStates(arena: Allocator, raw: ?[]const u8) Allocator.Error!List {
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
    try t.expectEqualStrings("In Progress", (try parseWorkflowStates(arena, "todo,In Progress")).invalid);
}

test fromConfig {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Entry = struct { key: []const u8, value: []const u8 };
    const s = try fromConfig(arena, &[_]Entry{
        .{ .key = "issue.donestates", .value = "wontfix" },
        .{ .key = "issue.donestates", .value = "cancelled,open" },
        .{ .key = "issue.workflowstates", .value = "todo,doing" },
    });
    try t.expectEqualStrings("open", s.invalid_done_state.?);
    try t.expectEqual(@as(usize, 2), s.done_states.len);
    try t.expectEqualStrings("doing", s.workflow_states[1]);
}

test "Settings.checkWorkflow" {
    const t = std.testing;
    const s: Settings = .{};
    try s.checkWorkflow("ready");
    try t.expectError(error.UnknownWorkflowState, s.checkWorkflow("done"));
    const bad: Settings = .{ .invalid_workflow_state = "X" };
    try t.expectError(error.InvalidWorkflowStates, bad.checkWorkflow("ready"));
}

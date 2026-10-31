//! What `ls` and `search` do, for programs that list issues themselves.

const std = @import("std");
const Allocator = std.mem.Allocator;
const issue_model = @import("../model/issue.zig");
const labels_fmt = @import("../format/labels.zig");

const Issue = issue_model.Issue;
const core_fmt = @import("../format/core.zig");
const State = core_fmt.State;
const Priority = core_fmt.Priority;

/// All set criteria must match, exactly, like upstream compares.
pub const Filter = struct {
    /// Null for any state. Compared as text, so `wontfix` finds `wontfix`.
    state: ?State = .open,
    label: ?[]const u8 = null,
    /// "" matches unassigned issues.
    assignee: ?[]const u8 = null,
    priority: ?Priority = null,
    /// false hides deleted issues, true shows only those, null both.
    deleted: ?bool = false,

    pub fn matches(f: Filter, issue: Issue) bool {
        if (f.deleted) |d| if (issue.deleted != d) return false;
        if (f.state) |s| if (!issue.state.eql(s)) return false;
        if (f.label) |l| if (!labels_fmt.contains(issue.labels, l)) return false;
        if (f.assignee) |a| if (!std.mem.eql(u8, issue.field("Assignee") orelse "", a)) {
            return false;
        };
        if (f.priority) |p| if (issue.priority() != p) return false;
        return true;
    }
};

pub const SortKey = enum { created, updated, priority, state };

pub const Order = struct {
    key: SortKey = .created,
    /// Newest, highest or open first by default. Ties go by ID.
    reverse: bool = false,
};

/// Returns a new slice. The issues aren't copied.
pub fn list(
    arena: Allocator,
    issues: []const Issue,
    filter: Filter,
    order: Order,
) Allocator.Error![]Issue {
    var out: std.ArrayList(Issue) = .empty;
    for (issues) |issue| if (filter.matches(issue)) try out.append(arena, issue);
    std.mem.sort(Issue, out.items, order, lessThan);
    return out.items;
}

fn lessThan(order: Order, a: Issue, b: Issue) bool {
    const ka = sortKey(a, order.key);
    const kb = sortKey(b, order.key);
    if (ka != kb) return if (order.reverse) ka < kb else ka > kb;
    return std.mem.lessThan(u8, a.id, b.id);
}

fn sortKey(issue: Issue, key: SortKey) i64 {
    return switch (key) {
        .created => issue.created,
        .updated => issue.updated,
        // Values outside the four levels sort below `low`, like upstream.
        .priority => if (issue.priority()) |p| p.rank() else 0,
        .state => if (issue.state.isOpen()) 1 else 0,
    };
}

pub const SearchOptions = struct {
    /// ASCII only, so it doesn't depend on the locale.
    ignore_case: bool = false,
};

/// Matching lines of the issue's commit messages, trailers included, newest
/// commit first.
pub fn searchLines(
    arena: Allocator,
    issue: Issue,
    needle: []const u8,
    options: SearchOptions,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (needle.len == 0) return out.items;
    for (issue.log) |message| {
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, message, "\n"), '\n');
        while (lines.next()) |line| {
            const hit = if (options.ignore_case)
                std.ascii.findIgnoreCase(line, needle) != null
            else
                std.mem.find(u8, line, needle) != null;
            if (hit) try out.append(arena, line);
        }
    }
    return out.items;
}

const testing = std.testing;

fn testIssue(
    arena: Allocator,
    id: []const u8,
    state: []const u8,
    created: i64,
    prio: ?[]const u8,
) Allocator.Error!Issue {
    const fields: []const issue_model.Field = if (prio) |p|
        try arena.dupe(issue_model.Field, &.{.{ .key = "Priority", .value = p }})
    else
        &.{};
    return .{
        .id = id,
        .tip = undefined,
        .root = undefined,
        .roots = 1,
        .title = id,
        .title_override = null,
        .description = "",
        .state = State.parse(state),
        .labels = &.{},
        .fields = fields,
        .conflicts = &.{},
        .author = undefined,
        .created = created,
        .updated = created,
        .comments = &.{},
        .format_version = "1",
        .commit_count = 1,
        .log = &.{},
    };
}

test "filter and sort like git issue ls" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const issues = [_]Issue{
        try testIssue(arena, "a", "open", 10, "low"),
        try testIssue(arena, "b", "closed", 30, "critical"),
        try testIssue(arena, "c", "open", 20, null),
        try testIssue(arena, "d", "open", 20, "critical"),
    };

    const open = try list(arena, &issues, .{}, .{});
    try testing.expectEqual(@as(usize, 3), open.len);
    // Newest first, the tie at 20 goes to the lower ID.
    try testing.expectEqualStrings("c", open[0].id);
    try testing.expectEqualStrings("d", open[1].id);
    try testing.expectEqualStrings("a", open[2].id);

    const by_priority = try list(arena, &issues, .{ .state = null }, .{ .key = .priority });
    try testing.expectEqualStrings("b", by_priority[0].id);
    try testing.expectEqualStrings("d", by_priority[1].id);
    try testing.expectEqualStrings("c", by_priority[3].id);

    const reversed = try list(arena, &issues, .{ .state = null }, .{ .reverse = true });
    try testing.expectEqualStrings("a", reversed[0].id);

    const critical = try list(arena, &issues, .{ .state = null, .priority = .critical }, .{});
    try testing.expectEqual(@as(usize, 2), critical.len);
    const unassigned = try list(arena, &issues, .{ .assignee = "" }, .{});
    try testing.expectEqual(@as(usize, 3), unassigned.len);
}

test "search finds fixed strings line by line" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var issue = try testIssue(arena, "a", "open", 1, null);
    issue.log = &.{ "Fix the Login page\n\nLogin fails twice.\n", "login retry\n" };
    try testing.expectEqual(@as(usize, 2), (try searchLines(arena, issue, "Login", .{})).len);
    const folded = try searchLines(arena, issue, "LOGIN", .{ .ignore_case = true });
    try testing.expectEqual(@as(usize, 3), folded.len);
    try testing.expectEqual(@as(usize, 0), (try searchLines(arena, issue, "", .{})).len);
}

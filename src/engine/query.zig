//! What `ls` and `search` do, for programs that list issues themselves.

const std = @import("std");
const stableSort = @import("../sort.zig").stable;
const Allocator = std.mem.Allocator;
const issue_model = @import("../model/issue.zig");
const labels_fmt = @import("../format/labels.zig");
const fields_fmt = @import("../format/fields.zig");

const Issue = issue_model.Issue;
const core_fmt = @import("../format/core.zig");
const State = core_fmt.State;
const Priority = core_fmt.Priority;

/// All set criteria must match, exactly, like upstream compares.
pub const Filter = struct {
    /// Null for any state. Compared as text, so `wontfix` finds `wontfix`.
    state: ?State = null,
    /// false: only work that isn't done, the default like `ls`. true: only
    /// done issues. Null for both.
    done: ?bool = false,
    /// Besides `closed`. See `core.State.isDone`.
    done_states: []const []const u8 = &core_fmt.default_done_states,
    label: ?[]const u8 = null,
    /// "" matches unassigned issues. Also matches the email of a
    /// `<uuid> <email>` value.
    assignee: ?[]const u8 = null,
    priority: ?Priority = null,
    /// false hides deleted issues, true shows only those, null both.
    deleted: ?bool = false,

    pub fn matches(f: Filter, issue: Issue) bool {
        if (f.deleted) |d| if (issue.deleted != d) return false;
        if (f.state) |s| if (!issue.state.eql(s)) return false;
        if (f.done) |d| if (issue.state.isDone(f.done_states) != d) return false;
        if (f.label) |l| if (!labels_fmt.contains(issue.labels, l)) return false;
        if (f.assignee) |a| if (!anyAssignee(issue, a)) return false;
        if (f.priority) |p| if (issue.priority != p) return false;
        return true;
    }

    /// Any of the assignees (format.md §3); "" matches none assigned.
    fn anyAssignee(issue: Issue, wanted: []const u8) bool {
        if (issue.assignees_written.len == 0)
            return assigneeMatches(issue.field("Assignee") orelse "", wanted);
        for (issue.assignees_written) |m| if (assigneeMatches(m, wanted)) return true;
        return false;
    }

    fn assigneeMatches(value: []const u8, wanted: []const u8) bool {
        if (std.mem.eql(u8, value, wanted)) return true;
        const parsed = fields_fmt.Assignee.parse(value) orelse return false;
        return parsed.uuid != null and std.mem.eql(u8, parsed.email, wanted);
    }
};

pub const SortKey = enum { created, updated, priority, state };

pub const Order = struct {
    key: SortKey = .created,
    /// Newest, highest or not done first by default. Ties go by ID.
    reverse: bool = false,
    /// For `.state`.
    done_states: []const []const u8 = &core_fmt.default_done_states,
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
    stableSort(Issue, out.items, order, lessThan);
    return out.items;
}

fn lessThan(order: Order, a: Issue, b: Issue) bool {
    const ka = sortKey(a, order);
    const kb = sortKey(b, order);
    if (ka != kb) return if (order.reverse) ka < kb else ka > kb;
    return std.mem.lessThan(u8, a.id, b.id);
}

fn sortKey(issue: Issue, order: Order) i64 {
    return switch (order.key) {
        .created => issue.created,
        .updated => issue.updated,
        // Values outside the four levels sort below `low`, like upstream.
        .priority => if (issue.priority) |p| p.rank() else 0,
        .state => if (issue.state.isDone(order.done_states)) 0 else 1,
    };
}

pub const SearchOptions = struct {
    /// ASCII only, so it doesn't depend on the locale.
    ignore_case: bool = false,
};

/// Matching lines of what the issue says now: the title, the fields as
/// `Key: value`, the description, and the comments that aren't deleted,
/// edited ones as edited, oldest first. Unlike upstream's `search`, which
/// greps every commit message, replaced text and event commits don't match.
pub fn searchLines(
    arena: Allocator,
    issue: Issue,
    needle: []const u8,
    options: SearchOptions,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (needle.len == 0) return out.items;
    const S = struct {
        arena: Allocator,
        needle: []const u8,
        options: SearchOptions,
        out: *std.ArrayList([]const u8),

        fn text(s: @This(), value: []const u8) Allocator.Error!void {
            var lines = std.mem.splitScalar(u8, value, '\n');
            while (lines.next()) |l| try s.line(l);
        }

        fn line(s: @This(), l: []const u8) Allocator.Error!void {
            const hit = if (s.options.ignore_case)
                std.ascii.findIgnoreCase(l, s.needle) != null
            else
                std.mem.find(u8, l, s.needle) != null;
            if (hit) try s.out.append(s.arena, l);
        }
    };
    const s: S = .{ .arena = arena, .needle = needle, .options = options, .out = &out };
    try s.line(issue.title);
    try s.line(try std.fmt.allocPrint(arena, "State: {s}", .{issue.state.text()}));
    if (issue.labels.len > 0) try s.line(
        try std.fmt.allocPrint(arena, "Labels: {s}", .{try labels_fmt.join(arena, issue.labels)}),
    );
    for (issue.fields) |f| try s.line(
        try std.fmt.allocPrint(arena, "{s}: {s}", .{ f.key, f.value }),
    );
    try s.text(issue.description);
    for (issue.comments) |c| {
        if (c.deleted or c.is_merge) continue;
        try s.line(c.subject);
        for (c.body) |l| try s.line(l);
    }
    return out.items;
}

const testing = std.testing;

/// A label in use, with how many issues carry it: for pickers and filters.
pub const LabelCount = struct {
    name: []const u8,
    open: u32 = 0,
    total: u32 = 0,
};

/// Every label the issues carry, by name; deleted issues don't count.
pub fn labelCounts(
    arena: Allocator,
    issues: []const Issue,
    done_states: []const []const u8,
) Allocator.Error![]LabelCount {
    var by: std.StringArrayHashMapUnmanaged(LabelCount) = .empty;
    for (issues) |issue| {
        if (issue.deleted) continue;
        const done = issue.state.isDone(done_states);
        for (issue.labels) |l| {
            const e = try by.getOrPut(arena, l);
            if (!e.found_existing) e.value_ptr.* = .{ .name = l };
            e.value_ptr.total += 1;
            if (!done) e.value_ptr.open += 1;
        }
    }
    const out = by.values();
    stableSort(LabelCount, out, {}, struct {
        fn lt(_: void, x: LabelCount, y: LabelCount) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.lt);
    return out;
}

/// Someone the history knows: an author or an assignee, by email.
pub const Person = struct {
    email: []const u8,
    /// The latest name they wrote under; null for assignees only.
    name: ?[]const u8 = null,
    /// Their host UUID, when a commit or assignment carried one.
    user_id: ?[]const u8 = null,
    authored: u32 = 0,
    assigned: u32 = 0,
};

/// Everyone who opened or is assigned an issue, by email (compared
/// ignoring case): candidates for assignee and author pickers.
pub fn people(arena: Allocator, issues: []const Issue) Allocator.Error![]Person {
    var by: std.StringArrayHashMapUnmanaged(Person) = .empty;
    const add = struct {
        fn f(
            al: Allocator,
            map: *std.StringArrayHashMapUnmanaged(Person),
            email: []const u8,
        ) Allocator.Error!*Person {
            const key = try std.ascii.allocLowerString(al, email);
            const e = try map.getOrPut(al, key);
            if (!e.found_existing) e.value_ptr.* = .{ .email = email };
            return e.value_ptr;
        }
    }.f;
    for (issues) |issue| {
        if (issue.deleted) continue;
        const p = try add(arena, &by, issue.author.email);
        p.authored += 1;
        p.name = issue.author.name;
        if (issue.author_id) |id| p.user_id = id;
        for (issue.assignees) |a| {
            const q = try add(arena, &by, a.email);
            q.assigned += 1;
            if (a.uuid) |id| q.user_id = id;
        }
    }
    const out = by.values();
    stableSort(Person, out, {}, struct {
        fn lt(_: void, x: Person, y: Person) bool {
            return std.ascii.orderIgnoreCase(x.email, y.email) == .lt;
        }
    }.lt);
    return out;
}

/// The shortest prefix of each of `ids` (sorted) that no other starts
/// with, at least `min` long: what to show so that `resolve` takes it.
pub fn shortIds(
    arena: Allocator,
    ids: []const []const u8,
    min: usize,
) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, ids.len);
    for (ids, out, 0..) |id, *o, i| {
        var n = @min(min, id.len);
        for ([_]?[]const u8{
            if (i > 0) ids[i - 1] else null,
            if (i + 1 < ids.len) ids[i + 1] else null,
        }) |other| if (other) |x| {
            var common: usize = 0;
            while (common < id.len and common < x.len and id[common] == x[common]) common += 1;
            n = @max(n, @min(common + 1, id.len));
        };
        o.* = id[0..n];
    }
    return out;
}

test "labelCounts, people, shortIds" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sig: @import("../backend/object.zig").Signature = .{
        .name = "Ada",
        .email = "ada@e.x",
        .time = 1,
        .tz_offset_minutes = 0,
    };
    var a = try testIssue(arena, "a", "open", 1, null);
    a.author = sig;
    a.labels = &.{ "bug", "ui" };
    a.assignees = &.{.{ .uuid = null, .email = "Grace@e.x" }};
    var b = try testIssue(arena, "b", "closed", 2, null);
    b.author = sig;
    b.labels = &.{"bug"};
    b.assignees = &.{.{ .uuid = null, .email = "grace@e.x" }};
    var c = try testIssue(arena, "c", "open", 3, null);
    c.author = sig;
    c.labels = &.{"gone"};
    c.deleted = true;
    const issues = [_]Issue{ a, b, c };
    const labels = try labelCounts(arena, &issues, &.{});
    try testing.expectEqual(@as(usize, 2), labels.len);
    try testing.expectEqualStrings("bug", labels[0].name);
    try testing.expectEqual(@as(u32, 1), labels[0].open);
    try testing.expectEqual(@as(u32, 2), labels[0].total);
    const who = try people(arena, &issues);
    var grace: ?Person = null;
    for (who) |p| if (std.ascii.eqlIgnoreCase(p.email, "grace@e.x")) {
        grace = p;
    };
    try testing.expectEqual(@as(u32, 2), grace.?.assigned);
    try testing.expectEqual(@as(u32, 2), who[0].authored); // Ada, not the deleted one

    const short = try shortIds(arena, &.{ "a7f30000", "a7f31111", "b0000000" }, 4);
    try testing.expectEqualStrings("a7f30", short[0]);
    try testing.expectEqualStrings("a7f31", short[1]);
    try testing.expectEqualStrings("b000", short[2]);
}

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
        .priority = if (prio) |p| Priority.parse(p) else null,
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
    const closed = try list(arena, &issues, .{ .done = true }, .{});
    try testing.expectEqual(@as(usize, 1), closed.len);
    try testing.expectEqual(@as(usize, 3), open.len);
    // Newest first, the tie at 20 goes to the lower ID.
    try testing.expectEqualStrings("c", open[0].id);
    try testing.expectEqualStrings("d", open[1].id);
    try testing.expectEqualStrings("a", open[2].id);

    const by_priority = try list(arena, &issues, .{ .done = null }, .{ .key = .priority });
    try testing.expectEqualStrings("b", by_priority[0].id);
    try testing.expectEqualStrings("d", by_priority[1].id);
    try testing.expectEqualStrings("c", by_priority[3].id);

    const reversed = try list(arena, &issues, .{ .done = null }, .{ .reverse = true });
    try testing.expectEqualStrings("a", reversed[0].id);

    const critical = try list(arena, &issues, .{ .done = null, .priority = .critical }, .{});
    try testing.expectEqual(@as(usize, 2), critical.len);
    const unassigned = try list(arena, &issues, .{ .assignee = "" }, .{});
    try testing.expectEqual(@as(usize, 3), unassigned.len);
}

test "search finds fixed strings line by line" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var issue = try testIssue(arena, "a", "open", 1, null);
    issue.title = "Fix the Login page";
    issue.description = "Login fails twice.\nlogin retry";
    issue.fields = &.{.{ .key = "Assignee", .value = "login@example.com" }};
    const Signature = @import("../backend/object.zig").Signature;
    const sig: Signature = .{ .name = "T", .email = "t@e.x", .time = 1, .tz_offset_minutes = 0 };
    const comment: issue_model.Comment = .{
        .oid = undefined,
        .author = sig,
        .subject = "Seen it",
        .text = &.{},
        .body = &.{"Login again"},
        .state_change = null,
        .is_merge = false,
    };
    var gone = comment;
    gone.deleted = true;
    gone.body = &.{"Login secret"};
    issue.comments = &.{ comment, gone };
    try testing.expectEqual(@as(usize, 3), (try searchLines(arena, issue, "Login", .{})).len);
    const folded = try searchLines(arena, issue, "LOGIN", .{ .ignore_case = true });
    try testing.expectEqual(@as(usize, 5), folded.len);
    try testing.expectEqual(@as(usize, 0), (try searchLines(arena, issue, "secret", .{})).len);
    try testing.expectEqual(@as(usize, 0), (try searchLines(arena, issue, "", .{})).len);

    // An assignee with a UUID matches by email too.
    issue.fields = &.{
        .{ .key = "Assignee", .value = "a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e ada@e.x" },
    };
    try testing.expect((Filter{ .assignee = "ada@e.x" }).matches(issue));
    try testing.expect(!(Filter{ .assignee = "bob@e.x" }).matches(issue));
}

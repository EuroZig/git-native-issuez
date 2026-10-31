//! Everything that needs all issues at once: the hierarchy, blocking,
//! progress, workflow states and the problems.
//!
//! Merges and other tools can produce any graph, so this works on every
//! input and never loops. A parent that is missing, the issue itself or
//! part of a cycle is ignored and reported, and the issue becomes a root.
//! On a cycle every member is reported and the one with the smallest ID is
//! cut loose, so the forest still covers every issue exactly once. Blocker
//! cycles are reported and their issues count as blocked. Nodes deeper
//! than `max_depth` are reported but stay in the tree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const issue_model = @import("../model/issue.zig");
const fields_fmt = @import("../format/fields.zig");

const Issue = issue_model.Issue;

pub const Options = struct {
    /// A root has depth 0.
    max_depth: u8 = 8,
    max_progress_leaves: u32 = 2_000,
    /// In order. The first is the state of an open issue without one.
    workflow: []const []const u8 = &fields_fmt.default_workflow,
};

pub const Problem = struct {
    id: []const u8,
    kind: Kind,
    /// The missing target, a cycle member, ...
    other: ?[]const u8 = null,
    /// For `invalid_value`.
    key: ?[]const u8 = null,
    value: ?[]const u8 = null,

    pub const Kind = enum {
        parent_missing,
        parent_self,
        parent_cycle,
        too_deep,
        blocker_missing,
        blocker_self,
        blocker_cycle,
        too_many_leaves,
        invalid_value,
        /// Rules our writes keep, broken by a merge or another tool.
        closed_with_open_descendants,
        open_under_closed_ancestor,
        /// Its parent is deleted. Allowed, restoring is fine.
        parent_deleted,
        /// See model.issue.EventProblem.
        invalid_event,
        /// The target comment isn't here yet.
        pending_event,
        /// The target is a comment of another issue.
        event_in_other_issue,

        pub fn describe(k: Kind) []const u8 {
            return switch (k) {
                .parent_missing => "parent not found",
                .parent_self => "is its own parent",
                .parent_cycle => "parent chain loops back",
                .too_deep => "nested deeper than the limit",
                .blocker_missing => "blocker not found",
                .blocker_self => "blocks itself",
                .blocker_cycle => "blockers form a cycle",
                .too_many_leaves => "too many leaves for progress",
                .invalid_value => "invalid value ignored",
                .closed_with_open_descendants => "closed, but has open descendants",
                .open_under_closed_ancestor => "open under a closed ancestor",
                .parent_deleted => "parent is deleted",
                .invalid_event => "event commit can't apply",
                .pending_event => "event waits for a comment not here yet",
                .event_in_other_issue => "event targets a comment of another issue",
            };
        }
    };
};

pub const Progress = struct { closed: u32, total: u32 };

const none: u32 = std.math.maxInt(u32);

pub const Projection = struct {
    issues: []const Issue,
    /// Each issue's effective parent, or `none` for roots.
    parent: []const u32,
    children: []const []const u32,
    /// Existing blockers, and the issues this one blocks.
    blockers: []const []const u32,
    blocks: []const []const u32,
    depth: []const u32,
    problems: []const Problem,
    roots: []const u32,
    options: Options,
    index: std.StringHashMapUnmanaged(u32),

    pub fn find(p: Projection, id: []const u8) ?u32 {
        return p.index.get(id);
    }

    /// Open, with at least one open blocker that exists.
    pub fn activelyBlocked(p: Projection, i: u32) bool {
        if (isClosed(p.issues[i]) or p.issues[i].deleted) return false;
        for (p.blockers[i]) |b| if (isActive(p.issues[b])) return true;
        return false;
    }

    /// Closed leaves out of all leaves below `i`. Null for a leaf, or over
    /// the leaf limit.
    pub fn progress(p: Projection, arena: Allocator, i: u32) Allocator.Error!?Progress {
        if (p.children[i].len == 0) return null;
        var closed: u32 = 0;
        var total: u32 = 0;
        var stack: std.ArrayList(u32) = .empty;
        try stack.appendSlice(arena, p.children[i]);
        while (stack.pop()) |n| {
            if (p.children[n].len > 0) {
                // A deleted node passes its children through.
                try stack.appendSlice(arena, p.children[n]);
                continue;
            }
            if (p.issues[n].deleted) continue; // counts in no denominator
            total += 1;
            if (total > p.options.max_progress_leaves) return null;
            if (isClosed(p.issues[n])) closed += 1;
        }
        return .{ .closed = closed, .total = total };
    }

    /// Its own, else the first state for open issues. Null when closed.
    pub fn workflow(p: Projection, i: u32) ?[]const u8 {
        if (p.issues[i].deleted) return null;
        if (p.issues[i].ext.workflow) |w| return w;
        if (isClosed(p.issues[i]) or p.options.workflow.len == 0) return null;
        return p.options.workflow[0];
    }

    pub fn problemsOf(p: Projection, arena: Allocator, i: u32) Allocator.Error![]const Problem {
        var out: std.ArrayList(Problem) = .empty;
        for (p.problems) |pr| if (std.mem.eql(u8, pr.id, p.issues[i].id)) try out.append(arena, pr);
        return out.items;
    }
};

/// Anything but `open` counts as done (`wontfix`, `duplicate`, ...), like
/// `ls` hides it.
pub fn isClosed(issue: Issue) bool {
    return !issue.state.isOpen();
}

/// What blocks, and what the open/closed rules look at.
pub fn isActive(issue: Issue) bool {
    return !isClosed(issue) and !issue.deleted;
}

pub fn build(arena: Allocator, issues: []const Issue, options: Options) Allocator.Error!Projection {
    const n: u32 = @intCast(issues.len);
    var index: std.StringHashMapUnmanaged(u32) = .empty;
    for (issues, 0..) |issue, i| try index.put(arena, issue.id, @intCast(i));
    var problems: std.ArrayList(Problem) = .empty;

    // A missing event target may be a comment of another issue.
    var comment_owner: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (issues) |issue| for (issue.comments) |c| {
        try comment_owner.put(arena, try arena.dupe(u8, c.oid.hex().slice()), issue.id);
    };
    for (issues) |issue| for (issue.event_problems) |ep| switch (ep.kind) {
        .invalid => try problems.append(arena, .{ .id = issue.id, .kind = .invalid_event }),
        .dangling => if (comment_owner.get(ep.target.?)) |owner|
            try problems.append(arena, .{
                .id = issue.id,
                .kind = .event_in_other_issue,
                .other = owner,
            })
        else
            try problems.append(arena, .{ .id = issue.id, .kind = .pending_event }),
    };

    for (issues) |issue| for (issue.ext.invalid) |f| try problems.append(arena, .{
        .id = issue.id,
        .kind = .invalid_value,
        .key = f.key,
        .value = f.value,
    });

    // Parents as written, minus missing targets and self-references.
    const parent = try arena.alloc(u32, n);
    for (issues, parent) |issue, *p| {
        p.* = none;
        const target = issue.ext.parent orelse continue;
        if (std.mem.eql(u8, target, issue.id)) {
            try problems.append(arena, .{ .id = issue.id, .kind = .parent_self });
        } else if (index.get(target)) |t| {
            p.* = t;
        } else try problems.append(arena, .{
            .id = issue.id,
            .kind = .parent_missing,
            .other = target,
        });
    }

    // Follow each chain once. Report every member of a cycle, cut it at
    // its smallest ID.
    const colour = try arena.alloc(u8, n); // 0 unvisited, 1 on the current path, 2 done
    @memset(colour, 0);
    var path: std.ArrayList(u32) = .empty;
    for (0..n) |start_usize| {
        const start: u32 = @intCast(start_usize);
        if (colour[start] != 0) continue;
        path.clearRetainingCapacity();
        var cur = start;
        while (cur != none and colour[cur] == 0) {
            colour[cur] = 1;
            try path.append(arena, cur);
            cur = parent[cur];
        }
        if (cur != none and colour[cur] == 1) {
            // cur to the end of path is a cycle.
            const at = std.mem.findScalar(u32, path.items, cur).?;
            const cycle = path.items[at..];
            var cut = cycle[0];
            for (cycle) |c| if (std.mem.lessThan(u8, issues[c].id, issues[cut].id)) {
                cut = c;
            };
            for (cycle) |c| try problems.append(arena, .{
                .id = issues[c].id,
                .kind = .parent_cycle,
                .other = issues[parent[c]].id,
            });
            parent[cut] = none;
        }
        for (path.items) |p| colour[p] = 2;
    }

    // Children (by creation time, then ID) and depths.
    var kids = try arena.alloc(std.ArrayList(u32), n);
    for (kids) |*k| k.* = .empty;
    var roots: std.ArrayList(u32) = .empty;
    for (parent, 0..) |p, i| {
        const idx: u32 = @intCast(i);
        if (p == none) try roots.append(arena, idx) else try kids[p].append(arena, idx);
    }
    const Order = struct {
        issues: []const Issue,
        fn lt(o: @This(), a: u32, b: u32) bool {
            const x = o.issues[a];
            const y = o.issues[b];
            if (x.created != y.created) return x.created < y.created;
            return std.mem.lessThan(u8, x.id, y.id);
        }
    };
    std.mem.sort(u32, roots.items, Order{ .issues = issues }, Order.lt);
    const children = try arena.alloc([]const u32, n);
    for (kids, children) |*k, *c| {
        std.mem.sort(u32, k.items, Order{ .issues = issues }, Order.lt);
        c.* = k.items;
    }
    const depth = try arena.alloc(u32, n);
    var stack: std.ArrayList(u32) = .empty;
    for (roots.items) |r| {
        depth[r] = 0;
        try stack.append(arena, r);
    }
    var reached: usize = 0;
    while (stack.pop()) |i| {
        reached += 1;
        if (depth[i] > options.max_depth) try problems.append(
            arena,
            .{ .id = issues[i].id, .kind = .too_deep },
        );
        for (children[i]) |c| {
            depth[c] = depth[i] + 1;
            try stack.append(arena, c);
        }
    }
    std.debug.assert(reached == n); // cycles were cut: a forest

    const blockers = try arena.alloc([]const u32, n);
    var blocks_lists = try arena.alloc(std.ArrayList(u32), n);
    for (blocks_lists) |*b| b.* = .empty;
    for (issues, blockers, 0..) |issue, *bl, i| {
        var list: std.ArrayList(u32) = .empty;
        for (issue.ext.blocked_by) |target| {
            if (std.mem.eql(u8, target, issue.id)) {
                try problems.append(arena, .{ .id = issue.id, .kind = .blocker_self });
            } else if (index.get(target)) |t| {
                try list.append(arena, t);
                try blocks_lists[t].append(arena, @intCast(i));
            } else try problems.append(arena, .{
                .id = issue.id,
                .kind = .blocker_missing,
                .other = target,
            });
        }
        bl.* = list.items;
    }
    const blocks = try arena.alloc([]const u32, n);
    for (blocks_lists, blocks) |*l, *b| b.* = l.items;

    // Over the effective forest, which has no cycles.
    const open_below = try arena.alloc(bool, n);
    var post: std.ArrayList(u32) = .empty;
    try stack.appendSlice(arena, roots.items);
    while (stack.pop()) |i| {
        try post.append(arena, i);
        try stack.appendSlice(arena, children[i]);
    }
    var k = post.items.len;
    while (k > 0) { // children before parents
        k -= 1;
        const i = post.items[k];
        open_below[i] = false;
        for (children[i]) |c| {
            if (open_below[c] or isActive(issues[c])) open_below[i] = true;
        }
        if (isClosed(issues[i]) and !issues[i].deleted and open_below[i]) try problems.append(
            arena,
            .{ .id = issues[i].id, .kind = .closed_with_open_descendants },
        );
    }
    for (post.items) |i| { // parents before children
        if (!isActive(issues[i])) continue;
        if (parent[i] != none and issues[parent[i]].deleted) try problems.append(arena, .{
            .id = issues[i].id,
            .kind = .parent_deleted,
            .other = issues[parent[i]].id,
        });
        var up = parent[i];
        while (up != none) : (up = parent[up]) {
            if (issues[up].deleted) continue; // the rule passes through
            if (isClosed(issues[up])) {
                try problems.append(arena, .{
                    .id = issues[i].id,
                    .kind = .open_under_closed_ancestor,
                    .other = issues[up].id,
                });
                break;
            }
        }
    }
    try blockerCycles(arena, issues, blockers, &problems);

    const proj: Projection = .{
        .issues = issues,
        .parent = parent,
        .children = children,
        .blockers = blockers,
        .blocks = blocks,
        .depth = depth,
        .problems = problems.items,
        .roots = roots.items,
        .options = options,
        .index = index,
    };
    for (0..n) |i| {
        if (proj.children[i].len == 0) continue;
        if ((try proj.progress(arena, @intCast(i))) == null) try problems.append(arena, .{
            .id = issues[i].id,
            .kind = .too_many_leaves,
        });
    }
    var out = proj;
    out.problems = problems.items;
    return out;
}

/// Tarjan's strongly connected components, iterative. A component with
/// more than one issue is a cycle.
fn blockerCycles(
    arena: Allocator,
    issues: []const Issue,
    edges: []const []const u32,
    problems: *std.ArrayList(Problem),
) Allocator.Error!void {
    const n = edges.len;
    const undef: u32 = none;
    const idx = try arena.alloc(u32, n);
    const low = try arena.alloc(u32, n);
    const on_stack = try arena.alloc(bool, n);
    @memset(idx, undef);
    @memset(on_stack, false);
    var counter: u32 = 0;
    var scc: std.ArrayList(u32) = .empty;
    const Frame = struct { v: u32, next: usize };
    var calls: std.ArrayList(Frame) = .empty;
    for (0..n) |s| {
        if (idx[s] != undef) continue;
        try calls.append(arena, .{ .v = @intCast(s), .next = 0 });
        idx[s] = counter;
        low[s] = counter;
        counter += 1;
        try scc.append(arena, @intCast(s));
        on_stack[s] = true;
        while (calls.items.len > 0) {
            const top = &calls.items[calls.items.len - 1];
            const v = top.v;
            if (top.next < edges[v].len) {
                const w = edges[v][top.next];
                top.next += 1;
                if (idx[w] == undef) {
                    idx[w] = counter;
                    low[w] = counter;
                    counter += 1;
                    try scc.append(arena, w);
                    on_stack[w] = true;
                    try calls.append(arena, .{ .v = w, .next = 0 });
                } else if (on_stack[w]) low[v] = @min(low[v], idx[w]);
                continue;
            }
            _ = calls.pop();
            if (calls.items.len > 0) {
                const u = calls.items[calls.items.len - 1].v;
                low[u] = @min(low[u], low[v]);
            }
            if (low[v] != idx[v]) continue;
            // v is the root of a component.
            const start = std.mem.findScalarLast(u32, scc.items, v).?;
            const comp = scc.items[start..];
            if (comp.len > 1) for (comp) |c| try problems.append(arena, .{
                .id = issues[c].id,
                .kind = .blocker_cycle,
            });
            for (comp) |c| on_stack[c] = false;
            scc.shrinkRetainingCapacity(start);
        }
    }
}

const testing = std.testing;

fn fakeIssue(id: []const u8, created: i64, state: []const u8, ext: issue_model.Extensions) Issue {
    return .{
        .id = id,
        .tip = undefined,
        .root = undefined,
        .roots = 1,
        .title = id,
        .title_override = null,
        .description = "",
        .state = .parse(state),
        .labels = &.{},
        .ext = ext,
        .fields = &.{},
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

test "hierarchy, blocking, progress and workflow" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const issues = [_]Issue{
        fakeIssue("a-epic", 1, "open", .{}),
        fakeIssue("b-task", 2, "closed", .{ .parent = "a-epic" }),
        fakeIssue("c-task", 3, "open", .{ .parent = "a-epic", .blocked_by = &.{"d-blocker"} }),
        fakeIssue("d-blocker", 4, "open", .{ .workflow = "review" }),
        fakeIssue("e-sub", 5, "closed", .{ .parent = "c-task" }),
    };
    const p = try build(arena, &issues, .{});
    try testing.expectEqual(@as(usize, 0), p.problems.len);
    try testing.expectEqual(@as(usize, 2), p.roots.len);
    const epic = p.find("a-epic").?;
    try testing.expectEqual(@as(usize, 2), p.children[epic].len);
    // The epic's leaves are b and e, both closed. c isn't a leaf.
    try testing.expectEqual(Progress{ .closed = 2, .total = 2 }, (try p.progress(arena, epic)).?);
    try testing.expect(p.activelyBlocked(p.find("c-task").?));
    try testing.expectEqual(@as(usize, 1), p.blocks[p.find("d-blocker").?].len);
    try testing.expectEqualStrings("backlog", p.workflow(epic).?);
    try testing.expectEqualStrings("review", p.workflow(p.find("d-blocker").?).?);
    try testing.expect(p.workflow(p.find("b-task").?) == null);
    try testing.expectEqual(@as(u32, 2), p.depth[p.find("e-sub").?]);

    // Any state but open is done: a `wontfix` blocker no longer blocks, and
    // a `wontfix` leaf counts as closed.
    var more = issues;
    more[3].state = .{ .other = "wontfix" };
    more[1].state = .{ .other = "duplicate" };
    const q = try build(arena, &more, .{});
    try testing.expect(!q.activelyBlocked(q.find("c-task").?));
    try testing.expectEqual(Progress{ .closed = 2, .total = 2 }, (try q.progress(arena, epic)).?);
    try testing.expect(q.workflow(q.find("d-blocker").?) != null); // as written
}

test "broken graphs" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const issues = [_]Issue{
        fakeIssue("x", 1, "open", .{ .parent = "y", .blocked_by = &.{"y"} }),
        fakeIssue("y", 2, "open", .{ .parent = "z", .blocked_by = &.{"x"} }),
        fakeIssue("z", 3, "open", .{ .parent = "x" }),
        fakeIssue("s", 4, "open", .{ .parent = "s", .blocked_by = &.{ "s", "gone" } }),
        fakeIssue("o", 5, "open", .{ .parent = "missing" }),
    };
    const p = try build(arena, &issues, .{});
    var counts = std.EnumArray(Problem.Kind, usize).initFill(0);
    for (p.problems) |pr| counts.getPtr(pr.kind).* += 1;
    try testing.expectEqual(@as(usize, 3), counts.get(.parent_cycle));
    try testing.expectEqual(@as(usize, 2), counts.get(.blocker_cycle));
    try testing.expectEqual(@as(usize, 1), counts.get(.parent_self));
    try testing.expectEqual(@as(usize, 1), counts.get(.blocker_self));
    try testing.expectEqual(@as(usize, 1), counts.get(.blocker_missing));
    try testing.expectEqual(@as(usize, 1), counts.get(.parent_missing));
    // x has the smallest ID on the cycle, so it becomes a root.
    try testing.expectEqual(none, p.parent[p.find("x").?]);

    // A chain of 12: everything deeper than 8 is reported.
    var chain: [12]Issue = undefined;
    var ids: [12][]const u8 = undefined;
    for (&ids, 0..) |*id, i| id.* = try std.fmt.allocPrint(arena, "n{d:0>2}", .{i});
    for (&chain, 0..) |*c, i| c.* = fakeIssue(ids[i], @intCast(i), "open", .{
        .parent = if (i == 0) null else ids[i - 1],
    });
    const deep = try build(arena, &chain, .{});
    var too_deep: usize = 0;
    for (deep.problems) |pr| if (pr.kind == .too_deep) {
        too_deep += 1;
    };
    try testing.expectEqual(@as(usize, 3), too_deep); // n09, n10, n11
}

test "random graphs" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(0x9e3779b97f4a7c15);
    const rand = prng.random();
    for (0..400) |_| {
        const n = rand.intRangeAtMost(usize, 1, 40);
        const ids = try arena.alloc([]const u8, n);
        for (ids, 0..) |*id, i| id.* = try std.fmt.allocPrint(arena, "i{d:0>3}", .{i});
        const issues = try arena.alloc(Issue, n);
        for (issues, 0..) |*is, i| {
            const parent: ?[]const u8 = switch (rand.uintLessThan(u8, 4)) {
                0 => null,
                1 => "missing",
                else => ids[rand.uintLessThan(usize, n)],
            };
            var bl: std.ArrayList([]const u8) = .empty;
            for (0..rand.uintAtMost(usize, 3)) |_| {
                try bl.append(arena, ids[rand.uintLessThan(usize, n)]);
            }
            const state = if (rand.boolean()) "open" else "closed";
            is.* = fakeIssue(ids[i], rand.intRangeAtMost(i64, 0, 5), state, .{
                .parent = parent,
                .blocked_by = bl.items,
            });
        }
        const a = try build(arena, issues, .{ .max_depth = 3 });
        const b = try build(arena, issues, .{ .max_depth = 3 });
        // Every issue reachable exactly once.
        var seen = try std.DynamicBitSetUnmanaged.initEmpty(arena, n);
        var stack: std.ArrayList(u32) = .empty;
        try stack.appendSlice(arena, a.roots);
        while (stack.pop()) |i| {
            try testing.expect(!seen.isSet(i));
            seen.set(i);
            try stack.appendSlice(arena, a.children[i]);
            if (a.parent[i] != none) {
                const siblings = a.children[a.parent[i]];
                try testing.expect(std.mem.findScalar(u32, siblings, i) != null);
            }
        }
        try testing.expectEqual(n, seen.count());
        try testing.expectEqualSlices(u32, a.parent, b.parent);
        try testing.expectEqual(a.problems.len, b.problems.len);
        for (0..n) |i| _ = try a.progress(arena, @intCast(i));
    }
}

test "deleted issues" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var issues = [_]Issue{
        fakeIssue("a", 1, "closed", .{}),
        fakeIssue("b-gone", 2, "open", .{ .parent = "a" }), // deleted interior node
        fakeIssue("c", 3, "closed", .{ .parent = "b-gone" }),
        fakeIssue("d-gone", 4, "open", .{ .parent = "a" }), // deleted leaf
        fakeIssue("e", 5, "open", .{ .blocked_by = &.{"d-gone"} }),
    };
    issues[1].deleted = true;
    issues[3].deleted = true;
    const p = try build(arena, &issues, .{});
    // Only c counts: b passes through and d is a deleted leaf.
    try testing.expectEqual(Progress{ .closed = 1, .total = 1 }, (try p.progress(arena, 0)).?);
    // a is closed with open but deleted descendants: fine. c is closed under
    // a deleted parent: only active issues are reported.
    try testing.expectEqual(@as(usize, 0), p.problems.len);
    try testing.expect(!p.activelyBlocked(p.find("e").?));
    try testing.expect(p.workflow(1) == null);

    // Reopening c under the deleted b is allowed, and reported.
    issues[2].state = .open;
    const q = try build(arena, &issues, .{});
    var kinds: std.ArrayList(Problem.Kind) = .empty;
    for (q.problems) |pr| try kinds.append(arena, pr.kind);
    try testing.expect(std.mem.findScalar(Problem.Kind, kinds.items, .parent_deleted) != null);
    const has = std.mem.findScalar(Problem.Kind, kinds.items, .open_under_closed_ancestor);
    try testing.expect(has != null);
}

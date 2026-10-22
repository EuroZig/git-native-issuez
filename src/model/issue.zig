//! Reads an issue from its commit DAG.
//!
//! Every field value remembers the commit that set it. Walking the commits
//! parents first, each commit's trailers set fields. When a merge brings
//! two values together and one setter is an ancestor of the other, the
//! newer one wins whatever the clocks say. Only concurrent setters fall
//! back to last writer wins (author time, then OID), and that case is
//! reported as a conflict. A missing trailer never clears a field, an
//! empty value does.
//!
//! Each label tracks its own setter, and a concurrent add and remove
//! resolves to add. No merge base is needed, so criss-cross histories are
//! fine too.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const object = @import("../backend/object.zig");
const trailers = @import("../format/trailers.zig");
const labels_fmt = @import("../format/labels.zig");
const Oid = object.Oid;
const Signature = object.Signature;

pub const CommitInput = struct {
    oid: Oid,
    tree: ?Oid = null,
    parents: []const Oid,
    author: Signature,
    committer: Signature,
    message: []const u8,
};

pub const Field = struct {
    key: []const u8,
    value: []const u8,
};

pub const Conflict = struct {
    field: []const u8,
    value: []const u8,
    lost: []const u8,
};

pub const Comment = struct {
    oid: Oid,
    author: Signature,
    subject: []const u8,
    /// Like upstream's `show`, which keeps a lone trailer paragraph such as
    /// `State: closed`.
    text: []const []const u8,
    /// Without the trailer block, the way git reads trailers. Use this one
    /// to display a comment.
    body: []const []const u8 = &.{},
    state_change: ?[]const u8,
    is_merge: bool,
};

pub const Issue = struct {
    id: []const u8,
    tip: Oid,
    root: Oid,
    roots: usize,
    title: []const u8,
    title_override: ?[]const u8,
    description: []const u8,
    state: []const u8,
    labels: []const []const u8,
    /// Every other field with a value, sorted by key. Per-commit trailers
    /// (`per_commit_keys`) are not fields.
    fields: []const Field,
    conflicts: []const Conflict,
    author: Signature,
    created: i64,
    updated: i64,
    comments: []const Comment,
    format_version: ?[]const u8,
    commit_count: usize,
    /// Raw messages in `git log` order, for `search`.
    log: []const []const u8,

    pub fn field(issue: Issue, key: []const u8) ?[]const u8 {
        for (issue.fields) |f| if (std.mem.eql(u8, f.key, key)) return f.value;
        return null;
    }
};

pub const Error = error{
    /// A parent wasn't loaded.
    MissingParent,
    NoRoot,
} || Allocator.Error;

const none_setter: u32 = std.math.maxInt(u32);

const Cell = struct {
    value: []const u8,
    setter: u32,
    lost: ?[]const u8 = null,
};

const LabelCell = struct {
    present: bool,
    setter: u32,
};

const SetState = struct {
    members: std.array_hash_map.String(LabelCell) = .empty,
    /// The most recent explicit list first.
    order: []const []const u8 = &.{},
};

const State = struct {
    scalars: std.array_hash_map.String(Cell) = .empty,
    sets: std.array_hash_map.String(SetState) = .empty,
};

pub const set_keys = [_][]const u8{"Labels"};

fn setKey(key: []const u8) ?[]const u8 {
    for (set_keys) |k| if (std.ascii.eqlIgnoreCase(k, key)) return k;
    return null;
}

const Node = struct {
    input: CommitInput,
    parents: []u32,
    block: trailers.Block,
};

pub fn materialize(
    arena: Allocator,
    id: []const u8,
    tip: Oid,
    commits: []const CommitInput,
) Error!Issue {
    assert(commits.len > 0);
    var index: std.AutoHashMapUnmanaged([object.Oid.max_byte_len]u8, u32) = .empty;
    for (commits, 0..) |c, i| try index.put(arena, c.oid.bytes, @intCast(i));
    const nodes = try arena.alloc(Node, commits.len);
    for (commits, nodes) |c, *n| {
        const parents = try arena.alloc(u32, c.parents.len);
        for (
            c.parents,
            parents,
        ) |p, *pi| pi.* = index.get(p.bytes) orelse return error.MissingParent;
        n.* = .{
            .input = c,
            .parents = parents,
            .block = try trailers.parse(arena, c.message, .{}),
        };
    }
    const tip_index = index.get(tip.bytes) orelse return error.MissingParent;

    const order = try topoOrder(arena, nodes);
    const ancestors = try ancestorSets(arena, nodes, order);
    const ctx: Ctx = .{ .nodes = nodes, .ancestors = ancestors };

    const states = try arena.alloc(State, nodes.len);
    for (order) |i| {
        const n = nodes[i];
        var s: State = if (n.parents.len == 0)
            .{}
        else blk: {
            var merged = try cloneState(arena, states[n.parents[0]]);
            for (n.parents[1..]) |p| merged = try ctx.mergeStates(arena, merged, states[p]);
            break :blk merged;
        };
        try applyTrailers(arena, &s, n, i);
        states[i] = s;
    }

    // With several roots (unrelated histories merged) take the newest by
    // committer time, like upstream.
    var root: ?u32 = null;
    var roots: usize = 0;
    for (nodes, 0..) |n, i| if (n.parents.len == 0) {
        roots += 1;
        const newer = root == null or n.input.committer.time > nodes[root.?].input.committer.time;
        if (newer) root = @intCast(i);
    };
    const r = root orelse return error.NoRoot;
    const root_node = nodes[r];
    const final = states[tip_index];

    const title = nonEmpty(final.scalars.get("Title"));
    const root_body = try trailers.bodyLines(arena, root_node.input.message);
    const description_lines = try trailers.textLines(arena, root_body, false);
    const description = try std.mem.join(arena, "\n", description_lines);

    var fields: std.ArrayList(Field) = .empty;
    var conflicts: std.ArrayList(Conflict) = .empty;
    const keys = try arena.dupe([]const u8, final.scalars.keys());
    std.mem.sort([]const u8, keys, {}, lessThan);
    for (keys) |k| {
        const c = final.scalars.get(k).?;
        if (c.lost) |lost| try conflicts.append(
            arena,
            .{ .field = k, .value = c.value, .lost = lost },
        );
        if (std.mem.eql(u8, k, "State") or std.mem.eql(u8, k, "Title") or std.mem.eql(
            u8,
            k,
            "Format-Version",
        )) continue;
        if (c.value.len == 0) continue;
        try fields.append(arena, .{ .key = k, .value = c.value });
    }

    const labels = try setMembers(arena, final, "Labels");

    const state_value = nonEmpty(final.scalars.get("State")) orelse "open";

    return .{
        .id = id,
        .tip = tip,
        .root = root_node.input.oid,
        .roots = roots,
        .title = title orelse try trailers.subject(arena, root_node.input.message),
        .title_override = title,
        .description = description,
        .state = state_value,
        .labels = labels,
        .fields = try fields.toOwnedSlice(arena),
        .conflicts = try conflicts.toOwnedSlice(arena),
        .author = root_node.input.author,
        .created = root_node.input.author.time,
        .updated = nodes[tip_index].input.author.time,
        .comments = try comments(arena, nodes, tip_index, r),
        .log = try logMessages(arena, nodes, tip_index),
        .format_version = trailers.lastValue(root_node.block, "Format-Version"),
        .commit_count = nodes.len,
    };
}

const Ctx = struct {
    nodes: []const Node,
    ancestors: []const std.DynamicBitSetUnmanaged,

    fn isAncestor(ctx: Ctx, a: u32, b: u32) bool {
        if (a == none_setter) return true;
        if (b == none_setter) return false;
        return ctx.ancestors[b].isSet(a);
    }

    fn lwwWins(ctx: Ctx, a: u32, b: u32) bool {
        const ta = ctx.nodes[a].input.author.time;
        const tb = ctx.nodes[b].input.author.time;
        if (ta != tb) return ta > tb;
        return ctx.nodes[a].input.oid.order(ctx.nodes[b].input.oid) == .gt;
    }

    fn mergeStates(ctx: Ctx, arena: Allocator, a: State, b: State) Allocator.Error!State {
        var out = try cloneState(arena, a);
        for (b.scalars.keys(), b.scalars.values()) |k, bc| {
            const gop = try out.scalars.getOrPut(arena, k);
            if (!gop.found_existing) {
                gop.value_ptr.* = bc;
                continue;
            }
            gop.value_ptr.* = ctx.mergeCell(gop.value_ptr.*, bc);
        }
        for (b.sets.keys(), b.sets.values()) |key, bset| {
            const gop = try out.sets.getOrPut(arena, key);
            if (!gop.found_existing) {
                gop.value_ptr.* = try cloneSet(arena, bset);
                continue;
            }
            gop.value_ptr.* = try ctx.mergeSets(arena, gop.value_ptr.*, bset);
        }
        return out;
    }

    fn mergeSets(ctx: Ctx, arena: Allocator, a: SetState, b: SetState) Allocator.Error!SetState {
        var out = try cloneSet(arena, a);
        var b_wins_order = false;
        for (b.members.keys(), b.members.values()) |m, bc| {
            const gop = try out.members.getOrPut(arena, m);
            if (!gop.found_existing) {
                gop.value_ptr.* = bc;
                continue;
            }
            const ac = gop.value_ptr.*;
            if (ac.setter == bc.setter) continue;
            if (ctx.isAncestor(ac.setter, bc.setter)) {
                gop.value_ptr.* = bc;
                b_wins_order = true;
            } else if (ctx.isAncestor(bc.setter, ac.setter)) {
                // keep a
            } else if (ac.present != bc.present) {
                gop.value_ptr.* = if (ac.present) ac else bc; // add wins
            } else if (ctx.lwwWins(bc.setter, ac.setter)) {
                gop.value_ptr.* = bc;
            }
        }
        out.order = if (b_wins_order)
            try concatOrder(arena, b.order, a.order)
        else
            try concatOrder(arena, a.order, b.order);
        return out;
    }

    fn mergeCell(ctx: Ctx, a: Cell, b: Cell) Cell {
        if (a.setter == b.setter) return a;
        if (ctx.isAncestor(a.setter, b.setter)) return b;
        if (ctx.isAncestor(b.setter, a.setter)) return a;
        const b_wins = ctx.lwwWins(b.setter, a.setter);
        var winner = if (b_wins) b else a;
        const loser = if (b_wins) a else b;
        if (!std.mem.eql(u8, winner.value, loser.value)) winner.lost = loser.value;
        return winner;
    }
};

/// Upstream's provider bridges put these on single commits (imported
/// comments, export records). As issue fields they would show whichever
/// came last. `Provider-ID` names the issue and stays a field.
pub const per_commit_keys = [_][]const u8{ "Provider-Comment-ID", "Exported-Commit" };

fn isPerCommitKey(key: []const u8) bool {
    for (per_commit_keys) |k| if (std.ascii.eqlIgnoreCase(k, key)) return true;
    return false;
}

fn applyTrailers(
    arena: Allocator,
    s: *State,
    n: Node,
    self: usize,
) Allocator.Error!void {
    const setter: u32 = @intCast(self);
    const is_merge = n.parents.len > 1;
    // Within a commit the last occurrence of a key wins, like git's
    // %(trailers:key=...).
    for (n.block.trailers) |t| {
        if (setKey(t.key)) |key| {
            try applySet(arena, s, key, t.value, setter);
            continue;
        }
        if (isPerCommitKey(t.key)) continue;
        const key = canonicalKey(t.key);
        const gop = try s.scalars.getOrPut(arena, key);
        if (gop.found_existing and is_merge and std.mem.eql(u8, gop.value_ptr.value, t.value)) {
            // Restating the merge's own result keeps the conflict.
            gop.value_ptr.setter = setter;
        } else {
            gop.value_ptr.* = .{ .value = t.value, .setter = setter };
        }
    }
}

fn applySet(
    arena: Allocator,
    s: *State,
    key: []const u8,
    value: []const u8,
    setter: u32,
) Allocator.Error!void {
    const wanted = try labels_fmt.parse(arena, value);
    const gop = try s.sets.getOrPut(arena, key);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const set = gop.value_ptr;
    for (set.members.keys(), set.members.values()) |m, *cell| {
        if (cell.present and !labels_fmt.contains(wanted, m)) cell.* = .{
            .present = false,
            .setter = setter,
        };
    }
    for (wanted) |m| {
        const mg = try set.members.getOrPut(arena, m);
        if (!mg.found_existing or !mg.value_ptr.present) mg.value_ptr.* = .{
            .present = true,
            .setter = setter,
        };
    }
    set.order = wanted;
}

fn setMembers(arena: Allocator, s: State, key: []const u8) Allocator.Error![]const []const u8 {
    const set = s.sets.get(key) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (set.order) |m| {
        if (set.members.get(m)) |cell| if (cell.present and !labels_fmt.contains(out.items, m))
            try out.append(arena, m);
    }
    for (set.members.keys(), set.members.values()) |m, cell| {
        if (cell.present and !labels_fmt.contains(out.items, m)) try out.append(arena, m);
    }
    return out.toOwnedSlice(arena);
}

fn cloneSet(arena: Allocator, set: SetState) Allocator.Error!SetState {
    return .{ .members = try set.members.clone(arena), .order = set.order };
}

/// git matches keys case-insensitively, so `state:` and `State:` are one
/// field.
fn canonicalKey(key: []const u8) []const u8 {
    const core = [_][]const u8{
        "State",
        "Title",
        "Assignee",
        "Priority",
        "Milestone",
        "Format-Version",
        "Fixed-By",
        "Release",
        "Reason",
    };
    for (core) |c| if (std.ascii.eqlIgnoreCase(c, key)) return c;
    return key;
}

fn cloneState(arena: Allocator, s: State) Allocator.Error!State {
    var sets: std.array_hash_map.String(SetState) = .empty;
    for (s.sets.keys(), s.sets.values()) |k, v| try sets.put(arena, k, try cloneSet(arena, v));
    return .{
        .scalars = try s.scalars.clone(arena),
        .sets = sets,
    };
}

fn concatOrder(
    arena: Allocator,
    first: []const []const u8,
    second: []const []const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (first) |l| if (!labels_fmt.contains(out.items, l)) try out.append(arena, l);
    for (second) |l| if (!labels_fmt.contains(out.items, l)) try out.append(arena, l);
    return out.toOwnedSlice(arena);
}

/// Parents first (iterative DFS post-order).
fn topoOrder(arena: Allocator, nodes: []const Node) Allocator.Error![]u32 {
    const visited = try arena.alloc(u8, nodes.len); // 0 new, 1 open, 2 done
    @memset(visited, 0);
    var order: std.ArrayList(u32) = .empty;
    var stack: std.ArrayList(struct { node: u32, next_parent: usize }) = .empty;
    for (0..nodes.len) |start| {
        if (visited[start] != 0) continue;
        try stack.append(arena, .{ .node = @intCast(start), .next_parent = 0 });
        visited[start] = 1;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const parents = nodes[top.node].parents;
            if (top.next_parent < parents.len) {
                const p = parents[top.next_parent];
                top.next_parent += 1;
                if (visited[p] == 0) {
                    visited[p] = 1;
                    try stack.append(arena, .{ .node = p, .next_parent = 0 });
                }
                continue;
            }
            visited[top.node] = 2;
            try order.append(arena, top.node);
            _ = stack.pop();
        }
    }
    assert(order.items.len == nodes.len);
    return order.items;
}

/// Bit j of ancestors[i] is set when j is a proper ancestor of i.
fn ancestorSets(
    arena: Allocator,
    nodes: []const Node,
    order: []const u32,
) Allocator.Error![]std.DynamicBitSetUnmanaged {
    const sets = try arena.alloc(std.DynamicBitSetUnmanaged, nodes.len);
    for (order) |i| {
        var set = try std.DynamicBitSetUnmanaged.initEmpty(arena, nodes.len);
        for (nodes[i].parents) |p| {
            set.set(p);
            set.setUnion(sets[p]);
        }
        sets[i] = set;
    }
    return sets;
}

/// Oldest first, in `git rev-list --reverse <root>..<tip>` order.
fn comments(
    arena: Allocator,
    nodes: []const Node,
    tip: u32,
    root: u32,
) Allocator.Error![]const Comment {
    const seen = try arena.alloc(bool, nodes.len);
    @memset(seen, false);
    var queue: std.ArrayList(u32) = .empty;
    var walk: std.ArrayList(u32) = .empty;
    try queue.append(arena, tip);
    seen[tip] = true;
    while (queue.items.len > 0) {
        const n = queue.orderedRemove(newestIndex(nodes, queue.items));
        if (n == root) continue;
        try walk.append(arena, n);
        for (nodes[n].parents) |p| if (!seen[p]) {
            seen[p] = true;
            try queue.append(arena, p);
        };
    }
    var out: std.ArrayList(Comment) = .empty;
    var k = walk.items.len;
    while (k > 0) { // oldest first
        k -= 1;
        const n = walk.items[k];
        const node = nodes[n];
        const body = try trailers.bodyLines(arena, node.input.message);
        try out.append(arena, .{
            .oid = node.input.oid,
            .author = node.input.author,
            .subject = try trailers.subject(arena, node.input.message),
            .text = try trailers.textLines(arena, body, true),
            .body = try trailers.textLines(arena, body, false),
            .state_change = trailers.lastValue(node.block, "State"),
            .is_merge = node.parents.len > 1,
        });
    }
    return out.items;
}

/// Newest committer time first, like `git log`.
fn logMessages(arena: Allocator, nodes: []const Node, tip: u32) Allocator.Error![]const []const u8 {
    const seen = try arena.alloc(bool, nodes.len);
    @memset(seen, false);
    var queue: std.ArrayList(u32) = .empty;
    var out: std.ArrayList([]const u8) = .empty;
    try queue.append(arena, tip);
    seen[tip] = true;
    while (queue.items.len > 0) {
        const n = queue.orderedRemove(newestIndex(nodes, queue.items));
        try out.append(arena, nodes[n].input.message);
        for (nodes[n].parents) |p| if (!seen[p]) {
            seen[p] = true;
            try queue.append(arena, p);
        };
    }
    return out.items;
}

/// Ties go to the earliest inserted, like git's walk.
fn newestIndex(nodes: []const Node, queue: []const u32) usize {
    var best: usize = 0;
    for (queue, 0..) |q, qi| {
        if (nodes[q].input.committer.time > nodes[queue[best]].input.committer.time) best = qi;
    }
    return best;
}

fn nonEmpty(cell: ?Cell) ?[]const u8 {
    const c = cell orelse return null;
    return if (c.value.len > 0) c.value else null;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const testing = std.testing;

const TestDag = struct {
    arena: Allocator,
    commits: std.ArrayList(CommitInput) = .empty,

    fn add(d: *TestDag, parents: []const usize, time: i64, message: []const u8) !usize {
        const idx = d.commits.items.len;
        var oid: Oid = .{ .object_format = .sha1, .bytes = @splat(0) };
        oid.bytes[0] = @intCast(idx + 1);
        oid.bytes[1] = 0xab;
        const ps = try d.arena.alloc(Oid, parents.len);
        for (parents, ps) |p, *o| o.* = d.commits.items[p].oid;
        const sig: Signature = .{
            .name = "T",
            .email = "t@e.x",
            .time = time,
            .tz_offset_minutes = 0,
        };
        try d.commits.append(
            d.arena,
            .{ .oid = oid, .parents = ps, .author = sig, .committer = sig, .message = message },
        );
        return idx;
    }

    fn issue(d: *TestDag, tip: usize) !Issue {
        return materialize(
            d.arena,
            "a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e",
            d.commits.items[tip].oid,
            d.commits.items,
        );
    }
};

test "linear history" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(
        &.{},
        100,
        "Crash\n\nBody text.\n\n" ++
            "State: open\nLabels: bug, auth\nAssignee: a@e.x\nPriority: high\nFormat-Version: 1\n",
    );
    const c1 = try d.add(&.{root}, 200, "A comment\n\nwith text\n");
    const c2 = try d.add(&.{c1}, 300, "Close issue\n\nState: closed\n");
    const c3 = try d.add(
        &.{c2},
        400,
        "Update labels, assignee\n\nLabels: bug, regression\nAssignee: \n",
    );
    const i = try d.issue(c3);
    try testing.expectEqualStrings("Crash", i.title);
    try testing.expectEqualStrings("Body text.", i.description);
    try testing.expectEqualStrings("closed", i.state);
    try testing.expectEqual(@as(usize, 2), i.labels.len);
    try testing.expectEqualStrings("regression", i.labels[1]);
    try testing.expect(i.field("Assignee") == null); // explicitly cleared
    try testing.expectEqualStrings("high", i.field("Priority").?); // never cleared by omission
    try testing.expectEqual(@as(usize, 3), i.comments.len);
    try testing.expectEqualStrings("A comment", i.comments[0].subject);
    try testing.expectEqualStrings("closed", i.comments[1].state_change.?);
    try testing.expectEqualStrings("1", i.format_version.?);
    try testing.expectEqual(@as(i64, 100), i.created);
    try testing.expectEqual(@as(i64, 400), i.updated);
}

test "causality beats clocks" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(&.{}, 1000, "T\n\nState: open\nPriority: low\nFormat-Version: 1\n");
    const skewed = try d.add(&.{root}, 10, "Update priority\n\nPriority: critical\n");
    const i = try d.issue(skewed);
    try testing.expectEqualStrings("critical", i.field("Priority").?);
    try testing.expectEqual(@as(usize, 0), i.conflicts.len);
}

test "concurrent edits" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(
        &.{},
        100,
        "T\n\nState: open\nPriority: low\nLabels: bug\nFormat-Version: 1\n",
    );
    const left = try d.add(&.{root}, 200, "L\n\nPriority: high\nLabels: bug, ui\n");
    const right = try d.add(&.{root}, 300, "R\n\nPriority: medium\nState: closed\nLabels: \n");
    const merge = try d.add(&.{ left, right }, 400, "Merge issue from origin\n");
    const i = try d.issue(merge);
    try testing.expectEqualStrings("medium", i.field("Priority").?); // later author time
    try testing.expectEqualStrings("closed", i.state); // only right changed it
    // Right removed "bug" while left left it alone, so it's gone. Left
    // added "ui", so it stays.
    try testing.expectEqual(@as(usize, 1), i.labels.len);
    try testing.expectEqualStrings("ui", i.labels[0]);
    try testing.expectEqual(@as(usize, 1), i.conflicts.len);
    try testing.expectEqualStrings("Priority", i.conflicts[0].field);
    try testing.expectEqualStrings("high", i.conflicts[0].lost);
}

test "restating merges" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(&.{}, 100, "T\n\nState: open\nFormat-Version: 1\n");
    const left = try d.add(&.{root}, 200, "L\n\nPriority: high\n");
    const right = try d.add(&.{root}, 300, "R\n\nPriority: low\n");
    const restating = try d.add(
        &.{ left, right },
        400,
        "Merge issue\n\nState: open\nPriority: low\n",
    );
    try testing.expectEqual(@as(usize, 1), (try d.issue(restating)).conflicts.len);
    const choosing = try d.add(&.{ left, right }, 400, "Merge issue\n\nPriority: high\n");
    const i = try d.issue(choosing);
    try testing.expectEqual(@as(usize, 0), i.conflicts.len);
    try testing.expectEqualStrings("high", i.field("Priority").?);
    const later = try d.add(&.{restating}, 500, "Update priority\n\nPriority: low\n");
    try testing.expectEqual(@as(usize, 0), (try d.issue(later)).conflicts.len);
}

test "concurrent add vs remove of a label: add wins" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(&.{}, 100, "T\n\nState: open\nLabels: a\nFormat-Version: 1\n");
    const removed = try d.add(&.{root}, 900, "R\n\nLabels: \n");
    const readded = try d.add(&.{root}, 200, "A\n\nLabels: a, b\n");
    const merge = try d.add(&.{ removed, readded }, 1000, "Merge\n");
    const i = try d.issue(merge);
    // "a" was removed on the left and untouched on the right: removed.
    // "b" was added on the right: present.
    try testing.expectEqual(@as(usize, 1), i.labels.len);
    try testing.expectEqualStrings("b", i.labels[0]);

    // Concurrent: one side removes x, the other removes and re-adds it.
    // The add wins, even though the removal is newer.
    const root2 = try d.add(&.{}, 100, "T\n\nState: open\nLabels: x\nFormat-Version: 1\n");
    const del_x = try d.add(&.{root2}, 900, "D\n\nLabels: \n");
    const rm_x = try d.add(&.{root2}, 200, "R\n\nLabels: \n");
    const readd_x = try d.add(&.{rm_x}, 210, "A\n\nLabels: x\n");
    const m2 = try d.add(&.{ del_x, readd_x }, 1000, "Merge\n");
    const j = try d.issue(m2);
    try testing.expectEqual(@as(usize, 1), j.labels.len);
    try testing.expectEqualStrings("x", j.labels[0]);
}

test "criss-cross merges are deterministic" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(&.{}, 100, "T\n\nState: open\nFormat-Version: 1\n");
    const a = try d.add(&.{root}, 200, "A\n\nPriority: high\n");
    const b = try d.add(&.{root}, 300, "B\n\nAssignee: b@e.x\n");
    const m1 = try d.add(&.{ a, b }, 400, "M1\n");
    const m2 = try d.add(&.{ b, a }, 410, "M2\n");
    const top = try d.add(&.{ m1, m2 }, 500, "Top\n");
    const i = try d.issue(top);
    try testing.expectEqualStrings("high", i.field("Priority").?);
    try testing.expectEqualStrings("b@e.x", i.field("Assignee").?);
    try testing.expectEqual(@as(usize, 0), i.conflicts.len);
}

test "description and comment text" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(
        &.{},
        100,
        "Crash\n\nFirst paragraph.\n\nSecond paragraph\nwith two lines.\n\n" ++
            "State: open\nFormat-Version: 1\n",
    );
    const close = try d.add(&.{root}, 200, "Fixed in abc\n\nState: closed\n");
    const i = try d.issue(close);
    try testing.expectEqualStrings(
        "First paragraph.\n\nSecond paragraph\nwith two lines.",
        i.description,
    );
    try testing.expectEqual(@as(usize, 1), i.comments[0].text.len);
    try testing.expectEqualStrings("State: closed", i.comments[0].text[0]);
    try testing.expectEqualStrings("closed", i.comments[0].state_change.?);
}

test "per-commit trailers" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(
        &.{},
        100,
        "Crash\n\nState: open\nProvider-ID: github:o/r#7\nFormat-Version: 1\n",
    );
    const comment = try d.add(
        &.{root},
        200,
        "Looks bad\n\nProvider-Comment-ID: github:o/r#comment-42\n",
    );
    const record = try d.add(
        &.{comment},
        300,
        "Record export of comment to GitHub #7\n\n" ++
            "Provider-Comment-ID: github:o/r#comment-43\nExported-Commit: 0123abc\n",
    );
    const i = try d.issue(record);
    try testing.expectEqualStrings("github:o/r#7", i.field("Provider-ID").?);
    try testing.expect(i.field("Provider-Comment-ID") == null);
    try testing.expect(i.field("Exported-Commit") == null);
    try testing.expect(i.field("provider-comment-id") == null);
    try testing.expectEqual(@as(usize, 2), i.comments.len);
}

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
//! Set members (`Labels`, `X-Blocked-By`) each track their own setter, and
//! a concurrent add and remove resolves to add. No merge base is needed,
//! so criss-cross histories are fine too.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const object = @import("../backend/object.zig");
const trailers = @import("../format/trailers.zig");
const labels_fmt = @import("../format/labels.zig");
const fields_fmt = @import("../format/fields.zig");
const uuid_fmt = @import("../format/uuid.zig");
const core_fmt = @import("../format/core.zig");
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
    target: Target,
    value: []const u8,
    lost: []const u8,

    pub const Target = union(enum) {
        /// A trailer key, as canonicalized.
        field: []const u8,
        description,
        /// The comment's commit.
        comment: Oid,

        /// `Priority`, `Description`, `Comment 3f9a1c2`.
        pub fn format(t: Target, w: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (t) {
                .field => |k| try w.writeAll(k),
                .description => try w.writeAll("Description"),
                .comment => |oid| {
                    const h = oid.hex();
                    try w.print("Comment {s}", .{h.short()});
                },
            }
        }
    };
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
    /// The `State` this commit wrote, if any.
    state_change: ?core_fmt.State,
    is_merge: bool,
    /// Set by events. `text` and `body` already hold the edited text.
    edited: bool = false,
    deleted: bool = false,
};

pub const EventProblem = struct {
    oid: Oid,
    kind: Kind,
    target: ?[]const u8 = null,

    pub const Kind = enum {
        /// The target isn't in this history yet. It applies once a sync
        /// brings it in, unless it belongs to another issue.
        dangling,
        /// Unknown or repeated `X-Event`, bad `X-Comment`, or a target that
        /// is the root, a merge or another event.
        invalid,
    };
};

/// References are full UUIDs. Whether their targets exist is up to the
/// projection. Values that don't parse end up in `invalid`.
pub const Extensions = struct {
    assignee: ?fields_fmt.Assignee = null,
    parent: ?[]const u8 = null,
    blocked_by: []const []const u8 = &.{},
    /// Every member as written, invalid ones included, in set order.
    blocked_by_written: []const []const u8 = &.{},
    start_date: ?fields_fmt.Date = null,
    due_date: ?fields_fmt.Date = null,
    estimate_minutes: ?u32 = null,
    /// As written. The projection applies the default for open issues.
    workflow: ?[]const u8 = null,
    milestone_id: ?[]const u8 = null,
    milestone_mode: ?fields_fmt.MilestoneMode = null,
    invalid: []const Field = &.{},
};

pub const Issue = struct {
    id: []const u8,
    tip: Oid,
    root: Oid,
    roots: usize,
    title: []const u8,
    title_override: ?[]const u8,
    description: []const u8,
    /// `open` when never set.
    state: core_fmt.State,
    labels: []const []const u8,
    ext: Extensions = .{},
    deleted: bool = false,
    event_problems: []const EventProblem = &.{},
    /// Every other field with a value, sorted by key. Per-commit trailers
    /// (`per_commit_keys`) are not fields.
    fields: []const Field,
    /// Keys written and then cleared: their last value is empty. Sorted,
    /// `State` and `Format-Version` left out. A merge restates them empty.
    cleared: []const []const u8 = &.{},
    conflicts: []const Conflict,
    author: Signature,
    created: i64,
    updated: i64,
    comments: []const Comment,
    format_version: ?[]const u8,
    commit_count: usize,
    /// Raw messages in `git log` order, for `search`.
    log: []const []const u8,

    /// Null when unset or not one of the four levels (another tool may
    /// write `urgent`); `field("Priority")` has the text.
    pub fn priority(issue: Issue) ?core_fmt.Priority {
        return core_fmt.Priority.parse(issue.field("Priority") orelse return null);
    }

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

/// What the fold carries from commit to commit: each field with its setter.
const FoldState = struct {
    scalars: std.array_hash_map.String(Cell) = .empty,
    sets: std.array_hash_map.String(SetState) = .empty,
};

pub const set_keys = [_][]const u8{ "Labels", "X-Blocked-By" };

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
    var event_problems: std.ArrayList(EventProblem) = .empty;
    const events = try classifyEvents(arena, nodes, &index, &event_problems);

    const states = try arena.alloc(FoldState, nodes.len);
    for (order) |i| {
        const n = nodes[i];
        var s: FoldState = if (n.parents.len == 0)
            .{}
        else blk: {
            var merged = try cloneState(arena, states[n.parents[0]]);
            for (n.parents[1..]) |p| merged = try ctx.mergeStates(arena, merged, states[p]);
            break :blk merged;
        };
        try applyTrailers(arena, &s, n, i, events[i]);
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
    const description = if (final.scalars.get(description_key)) |c|
        c.value
    else
        try std.mem.join(arena, "\n", description_lines);

    var fields: std.ArrayList(Field) = .empty;
    var cleared: std.ArrayList([]const u8) = .empty;
    var conflicts: std.ArrayList(Conflict) = .empty;
    const keys = try arena.dupe([]const u8, final.scalars.keys());
    std.mem.sort([]const u8, keys, {}, lessThan);
    for (keys) |k| {
        const c = final.scalars.get(k).?;
        if (c.lost) |lost| try conflicts.append(arena, .{
            .target = conflictTarget(k, root_node.input.oid.object_format),
            .value = c.value,
            .lost = lost,
        });
        if (isInternalKey(k)) continue;
        if (std.mem.eql(u8, k, "State") or std.mem.eql(u8, k, "Format-Version")) continue;
        if (c.value.len == 0) {
            try cleared.append(arena, k);
            continue;
        }
        if (std.mem.eql(u8, k, "Title")) continue;
        try fields.append(arena, .{ .key = k, .value = c.value });
    }

    const labels = try setMembers(arena, final, "Labels");
    const blocked_by = try setMembers(arena, final, "X-Blocked-By");
    for ([_]struct { []const u8, usize }{
        .{ "Labels", labels.len },
        .{ "X-Blocked-By", blocked_by.len },
    }) |set| if (set[1] == 0 and final.sets.contains(set[0])) try cleared.append(arena, set[0]);
    std.mem.sort([]const u8, cleared.items, {}, lessThan);

    const state_value = core_fmt.State.parse(nonEmpty(final.scalars.get("State")) orelse "open");

    return .{
        .id = id,
        .tip = tip,
        .root = root_node.input.oid,
        .roots = roots,
        .title = title orelse try trailers.subject(arena, root_node.input.message),
        .title_override = title,
        .description = description,
        .deleted = if (final.scalars.get("X-Deleted")) |c|
            fields_fmt.parseBool(c.value) orelse false
        else
            false,
        .event_problems = event_problems.items,
        .state = state_value,
        .labels = labels,
        .ext = try extensions(arena, final, blocked_by),
        .fields = try fields.toOwnedSlice(arena),
        .cleared = cleared.items,
        .conflicts = try conflicts.toOwnedSlice(arena),
        .author = root_node.input.author,
        .created = root_node.input.author.time,
        .updated = nodes[tip_index].input.author.time,
        .comments = try comments(arena, nodes, tip_index, r, events, final),
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

    fn mergeStates(ctx: Ctx, arena: Allocator, a: FoldState, b: FoldState) Allocator.Error!FoldState {
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
    s: *FoldState,
    n: Node,
    self: usize,
    event: ?Event,
) Allocator.Error!void {
    const setter: u32 = @intCast(self);
    const is_merge = n.parents.len > 1;
    if (event) |e| try applyEvent(arena, s, e, setter);
    // Within a commit the last occurrence of a key wins, like git's
    // %(trailers:key=...).
    for (n.block.trailers) |t| {
        if (setKey(t.key)) |key| {
            try applySet(arena, s, key, t.value, setter);
            continue;
        }
        if (isPerCommitKey(t.key) or isEventKey(t.key)) continue;
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

/// Keys for event state. Trailer keys can't contain spaces, so these never
/// collide with one, like a `description:` trailer from another tool.
const description_key = "event description";

fn commentKey(arena: Allocator, what: []const u8, target: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "comment-{s} {s}", .{ what, target });
}

fn isInternalKey(k: []const u8) bool {
    return std.mem.findScalar(u8, k, ' ') != null;
}

/// Event keys name what they change: the description or a comment.
fn conflictTarget(k: []const u8, format: object.ObjectFormat) Conflict.Target {
    if (std.mem.eql(u8, k, description_key)) return .description;
    if (std.mem.findScalar(u8, k, ' ')) |sp| {
        // Event targets were checked when the event was read.
        return .{ .comment = Oid.parseHex(format, k[sp + 1 ..]) catch unreachable };
    }
    return .{ .field = k };
}

fn isEventKey(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "X-Event") or std.ascii.eqlIgnoreCase(key, "X-Comment");
}

const Event = struct {
    kind: fields_fmt.Event,
    target: []const u8 = "",
    text: []const u8 = "",
};

fn classifyEvents(
    arena: Allocator,
    nodes: []const Node,
    index: *const std.AutoHashMapUnmanaged([object.Oid.max_byte_len]u8, u32),
    problems: *std.ArrayList(EventProblem),
) Allocator.Error![]?Event {
    const out = try arena.alloc(?Event, nodes.len);
    const is_event = try arena.alloc(bool, nodes.len);
    for (nodes, is_event) |n, *e| e.* = trailers.lastValue(n.block, "X-Event") != null;
    for (nodes, out) |n, *o| {
        o.* = null;
        var count: usize = 0;
        for (n.block.trailers) |t| if (std.ascii.eqlIgnoreCase(t.key, "X-Event")) {
            count += 1;
        };
        if (count == 0) continue;
        const bad: EventProblem = .{ .oid = n.input.oid, .kind = .invalid };
        const kind = fields_fmt.Event.parse(trailers.lastValue(n.block, "X-Event").?) orelse {
            try problems.append(arena, bad);
            continue;
        };
        if (count > 1) {
            try problems.append(arena, bad);
            continue;
        }
        var e: Event = .{ .kind = kind };
        if (kind.carriesText()) {
            const body = try trailers.bodyLines(arena, n.input.message);
            e.text = try std.mem.join(arena, "\n", try trailers.textLines(arena, body, false));
        }
        if (kind.targetsComment()) {
            const target = trailers.lastValue(n.block, "X-Comment") orelse {
                try problems.append(arena, bad);
                continue;
            };
            const oid = Oid.parseHex(n.input.oid.object_format, target) catch {
                try problems.append(arena, bad);
                continue;
            };
            const ti = index.get(oid.bytes) orelse {
                try problems.append(arena, .{
                    .oid = n.input.oid,
                    .kind = .dangling,
                    .target = target,
                });
                continue;
            };
            if (nodes[ti].parents.len != 1 or is_event[ti]) {
                try problems.append(arena, bad);
                continue;
            }
            e.target = target;
        }
        o.* = e;
    }
    return out;
}

fn applyEvent(arena: Allocator, s: *FoldState, e: Event, setter: u32) Allocator.Error!void {
    const put = struct {
        fn f(a: Allocator, st: *FoldState, key: []const u8, value: []const u8, by: u32) !void {
            try st.scalars.put(a, key, .{ .value = value, .setter = by });
        }
    }.f;
    switch (e.kind) {
        .description_edit => try put(arena, s, description_key, e.text, setter),
        .comment_edit => {
            try put(arena, s, try commentKey(arena, "text", e.target), e.text, setter);
            try put(arena, s, try commentKey(arena, "visible", e.target), "1", setter);
        },
        .comment_delete, .comment_restore => {
            const visible = if (e.kind == .comment_delete) "0" else "1";
            try put(arena, s, try commentKey(arena, "visible", e.target), visible, setter);
        },
    }
}

fn applySet(
    arena: Allocator,
    s: *FoldState,
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

fn extensions(
    arena: Allocator,
    s: FoldState,
    blocked_by: []const []const u8,
) Allocator.Error!Extensions {
    var ext: Extensions = .{};
    var invalid: std.ArrayList(Field) = .empty;
    const value = struct {
        fn of(st: FoldState, key: []const u8) ?[]const u8 {
            const c = st.scalars.get(key) orelse return null;
            return if (c.value.len == 0) null else c.value;
        }
    }.of;
    if (value(s, "Assignee")) |v| {
        if (fields_fmt.Assignee.parse(v)) |a| ext.assignee = a else {
            try invalid.append(arena, .{ .key = "Assignee", .value = v });
        }
    }
    if (value(s, "X-Parent")) |v| {
        if (uuid_fmt.isCanonical(v)) ext.parent = v else {
            try invalid.append(arena, .{ .key = "X-Parent", .value = v });
        }
    }
    var refs: std.ArrayList([]const u8) = .empty;
    for (blocked_by) |b| {
        if (uuid_fmt.isCanonical(b)) try refs.append(arena, b) else {
            try invalid.append(arena, .{ .key = "X-Blocked-By", .value = b });
        }
    }
    ext.blocked_by = refs.items;
    ext.blocked_by_written = blocked_by;
    inline for (.{ .{ "X-Start-Date", "start_date" }, .{ "X-Due-Date", "due_date" } }) |d| {
        if (value(s, d[0])) |v| {
            if (fields_fmt.Date.parse(v)) |date| @field(ext, d[1]) = date else {
                try invalid.append(arena, .{ .key = d[0], .value = v });
            }
        }
    }
    if (value(s, "X-Estimate-Minutes")) |v| {
        if (fields_fmt.parseMinutes(v)) |m| ext.estimate_minutes = m else {
            try invalid.append(arena, .{ .key = "X-Estimate-Minutes", .value = v });
        }
    }
    if (value(s, "X-Milestone-Id")) |v| {
        if (uuid_fmt.isCanonical(v)) ext.milestone_id = v else {
            try invalid.append(arena, .{ .key = "X-Milestone-Id", .value = v });
        }
    }
    if (value(s, "X-Milestone-Mode")) |v| {
        if (fields_fmt.MilestoneMode.parse(v)) |m| ext.milestone_mode = m else {
            try invalid.append(arena, .{ .key = "X-Milestone-Mode", .value = v });
        }
    }
    if (value(s, "X-Deleted")) |v| {
        if (fields_fmt.parseBool(v) == null) try invalid.append(arena, .{ .key = "X-Deleted", .value = v });
    }
    if (value(s, "X-Workflow-State")) |v| {
        if (fields_fmt.isSlug(v)) ext.workflow = v else {
            try invalid.append(arena, .{ .key = "X-Workflow-State", .value = v });
        }
    }
    ext.invalid = invalid.items;
    return ext;
}

fn setMembers(arena: Allocator, s: FoldState, key: []const u8) Allocator.Error![]const []const u8 {
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
        "X-Parent",
        "X-Start-Date",
        "X-Due-Date",
        "X-Estimate-Minutes",
        "X-Workflow-State",
        "X-Deleted",
        "X-Milestone-Id",
        "X-Milestone-Mode",
    };
    for (core) |c| if (std.ascii.eqlIgnoreCase(c, key)) return c;
    return key;
}

fn cloneState(arena: Allocator, s: FoldState) Allocator.Error!FoldState {
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
    events: []const ?Event,
    final: FoldState,
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
        // Event commits, valid or not, aren't comments.
        if (events[n] != null or trailers.lastValue(node.block, "X-Event") != null) continue;
        const body = try trailers.bodyLines(arena, node.input.message);
        const hex = node.input.oid.hex();
        const hex_s = try arena.dupe(u8, hex.slice());
        const edited = final.scalars.get(try commentKey(arena, "text", hex_s));
        const visible = final.scalars.get(try commentKey(arena, "visible", hex_s));
        var c: Comment = .{
            .oid = node.input.oid,
            .author = node.input.author,
            .subject = try trailers.subject(arena, node.input.message),
            .text = try trailers.textLines(arena, body, true),
            .body = try trailers.textLines(arena, body, false),
            .state_change = if (trailers.lastValue(node.block, "State")) |v| core_fmt.State.parse(v) else null,
            .is_merge = node.parents.len > 1,
            .deleted = visible != null and std.mem.eql(u8, visible.?.value, "0"),
        };
        if (edited) |e| {
            // The edit replaces the whole comment.
            var lines = std.mem.splitScalar(u8, e.value, '\n');
            c.subject = lines.first();
            var rest: std.ArrayList([]const u8) = .empty;
            while (lines.next()) |l| try rest.append(arena, l);
            while (rest.items.len > 0 and rest.items[0].len == 0) _ = rest.orderedRemove(0);
            c.text = rest.items;
            c.body = rest.items;
            c.edited = true;
        }
        try out.append(arena, c);
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
    try testing.expectEqualStrings("closed", i.state.text());
    try testing.expectEqual(@as(usize, 2), i.labels.len);
    try testing.expectEqualStrings("regression", i.labels[1]);
    try testing.expect(i.field("Assignee") == null); // explicitly cleared
    try testing.expectEqualStrings("high", i.field("Priority").?); // never cleared by omission
    try testing.expectEqual(@as(usize, 3), i.comments.len);
    try testing.expectEqualStrings("A comment", i.comments[0].subject);
    try testing.expectEqualStrings("closed", i.comments[1].state_change.?.text());
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
    try testing.expectEqualStrings("closed", i.state.text()); // only right changed it
    // Right removed "bug" while left left it alone, so it's gone. Left
    // added "ui", so it stays.
    try testing.expectEqual(@as(usize, 1), i.labels.len);
    try testing.expectEqualStrings("ui", i.labels[0]);
    try testing.expectEqual(@as(usize, 1), i.conflicts.len);
    try testing.expectEqualStrings("Priority", i.conflicts[0].target.field);
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

test "upstream merges keep X- fields" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(
        &.{},
        100,
        "T\n\nState: open\nX-Workflow-State: ready\nFormat-Version: 1\n",
    );
    const l = try d.add(&.{root}, 200, "comment\n");
    const r = try d.add(&.{root}, 300, "Close issue\n\nState: closed\n");
    const m = try d.add(&.{ l, r }, 400, "Merge issue from origin\n\nState: closed\n");
    const i = try d.issue(m);
    try testing.expectEqualStrings("ready", i.field("X-Workflow-State").?);
    try testing.expectEqualStrings("closed", i.state.text());
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
    try testing.expectEqualStrings("closed", i.comments[0].state_change.?.text());
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

test "invalid extension values" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const parent = "b8e4c3d2-5f6e-4b9c-8d2f-3a4b5c6d7e8f";
    const root = try d.add(&.{}, 100, "Child\n\nState: open\n" ++
        "Assignee: a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e ada@e.x\n" ++
        "X-Parent: " ++ parent ++ "\n" ++
        "X-Blocked-By: c9f5d4e3-6a7f-4cad-9e3a-4b5c6d7e8f90, not-a-uuid\n" ++
        "X-Start-Date: 2026-11-01\nX-Due-Date: 2026-02-30\n" ++
        "X-Estimate-Minutes: 90\nX-Workflow-State: in-progress\nFormat-Version: 1\n");
    const i = try d.issue(root);
    try testing.expectEqualStrings(parent, i.ext.parent.?);
    try testing.expectEqualStrings("ada@e.x", i.ext.assignee.?.email);
    try testing.expectEqual(@as(usize, 1), i.ext.blocked_by.len);
    try testing.expectEqual(@as(u8, 11), i.ext.start_date.?.month);
    try testing.expect(i.ext.due_date == null);
    try testing.expectEqual(@as(?u32, 90), i.ext.estimate_minutes);
    try testing.expectEqualStrings("in-progress", i.ext.workflow.?);
    try testing.expectEqual(@as(usize, 2), i.ext.invalid.len); // not-a-uuid, Feb 30

    // Only exactly `true` deletes. Anything else but `false` is reported.
    const maybe = try d.add(&.{root}, 200, "Delete?\n\nX-Deleted: True\n");
    const m = try d.issue(maybe);
    try testing.expect(!m.deleted);
    try testing.expectEqual(@as(usize, 3), m.ext.invalid.len);
    try testing.expectEqualStrings("X-Deleted", m.ext.invalid[2].key);
    const cleared = try d.issue(try d.add(&.{maybe}, 300, "Undo\n\nX-Deleted:\n"));
    try testing.expectEqual(@as(usize, 2), cleared.ext.invalid.len);
}

test "blocked-by merges per member" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const a = "c9f5d4e3-6a7f-4cad-9e3a-4b5c6d7e8f90";
    const b = "d0a6e5f4-7b8a-4dbe-8f4b-5c6d7e8f9012";
    const c = "e1b7f6a5-8c9b-4ecf-9a5c-6d7e8f901234";
    const root = try d.add(
        &.{},
        100,
        "Blocked\n\nState: open\nX-Blocked-By: " ++ a ++ "\nFormat-Version: 1\n",
    );
    const left = try d.add(&.{root}, 200, "Add b\n\nX-Blocked-By: " ++ a ++ ", " ++ b ++ "\n");
    const right = try d.add(&.{root}, 300, "Swap a for c\n\nX-Blocked-By: " ++ c ++ "\n");
    const merge = try d.add(&.{ left, right }, 400, "Merge issue\n\nState: open\n");
    const i = try d.issue(merge);
    // b and c were added concurrently, so both stay. a was removed on one
    // side and untouched on the other, so it's gone.
    try testing.expectEqual(@as(usize, 2), i.ext.blocked_by.len);
    for ([_][]const u8{ b, c }) |x| try testing.expect(labels_fmt.contains(i.ext.blocked_by, x));

    // A concurrent re-add and remove: the add wins.
    const all = a ++ ", " ++ b ++ ", " ++ c;
    const readd = try d.add(&.{merge}, 500, "Re-add a\n\nX-Blocked-By: " ++ all ++ "\n");
    const drop = try d.add(&.{merge}, 600, "Drop b\n\nX-Blocked-By: " ++ c ++ "\n");
    const again = try d.add(&.{ readd, drop }, 700, "Merge issue\n\nState: open\n");
    const j = try d.issue(again);
    try testing.expect(labels_fmt.contains(j.ext.blocked_by, a));
    try testing.expect(!labels_fmt.contains(j.ext.blocked_by, b));
}

fn hexOf(d: *TestDag, i: usize) ![]const u8 {
    return d.arena.dupe(u8, d.commits.items[i].oid.hex().slice());
}

fn eventMsg(d: *TestDag, head: []const u8, kind: []const u8, target: ?usize) ![]const u8 {
    const comment_line = if (target) |t|
        try std.fmt.allocPrint(d.arena, "X-Comment: {s}\n", .{try hexOf(d, t)})
    else
        "";
    return std.fmt.allocPrint(d.arena, "{s}\n\nX-Event: {s}\n{s}", .{ head, kind, comment_line });
}

test "events" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(&.{}, 100, "Title\n\nOld text.\n\nState: open\nFormat-Version: 1\n");
    const c1 = try d.add(&.{root}, 200, "First comment\n\nwith text\n");
    const c2 = try d.add(&.{c1}, 300, "Second comment\n");
    const edit = try d.add(&.{c2}, 400, try eventMsg(
        &d,
        "Edit comment x\n\nFirst, edited\n\nnew text",
        "comment-edit",
        c1,
    ));
    const del = try d.add(&.{edit}, 500, try eventMsg(&d, "Delete comment", "comment-delete", c2));
    const desc = try d.add(&.{del}, 600, try eventMsg(
        &d,
        "Edit description\n\nNew description.",
        "description-edit",
        null,
    ));
    const gone = try d.add(&.{desc}, 700, "Delete issue\n\nX-Deleted: true\n");

    var i = try d.issue(gone);
    try testing.expect(i.deleted);
    try testing.expectEqualStrings("New description.", i.description);
    // c1, c2 and "Delete issue" (a field change, like "Close issue"). The
    // four event commits aren't comments.
    try testing.expectEqual(@as(usize, 3), i.comments.len);
    try testing.expect(i.comments[0].edited);
    try testing.expectEqualStrings("First, edited", i.comments[0].subject);
    try testing.expectEqualStrings("new text", i.comments[0].text[0]);
    try testing.expect(i.comments[1].deleted);
    try testing.expectEqual(@as(usize, 0), i.event_problems.len);
    try testing.expect(i.field("X-Event") == null and i.field("X-Comment") == null);

    const restore = try d.add(&.{gone}, 800, try eventMsg(&d, "Restore", "comment-restore", c2));
    const back = try d.add(&.{restore}, 900, "Restore issue\n\nX-Deleted: false\n");
    i = try d.issue(back);
    try testing.expect(!i.deleted);
    try testing.expect(!i.comments[1].deleted);
}

test "event text with a divider line, and a lowercase description trailer" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(&.{}, 100, "T\n\nIntro\n\n---\n\nMore\n\nState: open\nFormat-Version: 1\n");
    var i = try d.issue(root);
    try testing.expectEqualStrings("Intro\n\n---\n\nMore", i.description);
    // `---` doesn't end the text: the trailers after it are still fields,
    // so they aren't text.
    const desc = try d.add(&.{root}, 200, try eventMsg(
        &d,
        "Edit description\n\nOwner: bob\n\n---\n\nDetails",
        "description-edit",
        null,
    ));
    const c = try d.add(&.{desc}, 300, "Done\n\n---\n\nx\n\nState: closed\n");
    // Another tool's `description:` trailer is just a field.
    const foreign = try d.add(&.{c}, 400, "Note\n\ndescription: hijacked\n");
    i = try d.issue(foreign);
    try testing.expectEqualStrings("Owner: bob\n\n---\n\nDetails", i.description);
    try testing.expectEqualStrings("hijacked", i.field("description").?);
    try testing.expectEqual(core_fmt.State.closed, i.state);
    const close = i.comments[0];
    try testing.expectEqual(@as(usize, 3), close.body.len);
    try testing.expectEqualStrings("x", close.body[2]);
}

test "concurrent and bad events" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(&.{}, 100, "T\n\nState: open\nFormat-Version: 1\n");
    const c = try d.add(&.{root}, 200, "Comment\n");
    const left = try d.add(&.{c}, 300, try eventMsg(&d, "Edit\n\nLeft text", "comment-edit", c));
    const right = try d.add(&.{c}, 400, try eventMsg(&d, "Edit\n\nRight text", "comment-edit", c));
    // A delete concurrent with an edit: the later edit (400) wins and shows
    // the comment again.
    const merge = try d.add(&.{ left, right }, 500, "Merge issue\n\nState: open\n");
    var i = try d.issue(merge);
    try testing.expectEqualStrings("Right text", i.comments[0].subject);
    try testing.expectEqual(@as(usize, 1), i.conflicts.len);
    try testing.expect(i.conflicts[0].target == .comment);

    // Dangling target, the root, an event, and two events in one commit.
    const missing = "0f" ** 20;
    const dangling_msg = "Edit\n\nX\n\nX-Event: comment-edit\nX-Comment: " ++ missing ++ "\n";
    const bad1 = try d.add(&.{merge}, 600, dangling_msg);
    const bad2 = try d.add(&.{bad1}, 700, try eventMsg(&d, "Delete", "comment-delete", root));
    const bad3 = try d.add(&.{bad2}, 800, try eventMsg(&d, "Delete", "comment-delete", left));
    const two = "Two\n\nX-Event: description-edit\nX-Event: comment-delete\n";
    const bad4 = try d.add(&.{bad3}, 900, two);
    i = try d.issue(bad4);
    var dangling: usize = 0;
    var invalid: usize = 0;
    for (i.event_problems) |p| switch (p.kind) {
        .dangling => dangling += 1,
        .invalid => invalid += 1,
    };
    try testing.expectEqual(@as(usize, 1), dangling);
    try testing.expectEqual(@as(usize, 3), invalid);
    try testing.expectEqual(@as(usize, 2), i.comments.len); // the comment and the merge
}

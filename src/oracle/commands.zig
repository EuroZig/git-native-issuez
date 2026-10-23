//! Oracle rules for issue commands. Besides object primitives this may
//! use the trailer parser, which test/trailers_git.zig checks against git,
//! but nothing from the model, the engine or the CLI. Expected messages
//! are built from scratch.

const std = @import("std");
const Allocator = std.mem.Allocator;
const issuez = @import("issuez");
const object = issuez.backend.object;
const trailers = issuez.format.trailers;
const World = issuez.backend.GitSim.World;
const command = @import("command.zig");

pub const RuleError = Allocator.Error || error{NoRule};
pub const Block = trailers.Block;
pub const Trailer = trailers.Trailer;

pub fn trailersOf(arena: Allocator, message: []const u8) Allocator.Error!trailers.Block {
    return trailers.parse(arena, message, .{});
}

pub fn subjectOf(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    return trailers.subject(arena, text);
}

/// One issue as the oracle reads it. See `Dag` for the merge rule.
pub const NaiveIssue = struct {
    title: []const u8,
    title_override: ?[]const u8,
    state: []const u8,
    labels: []const []const u8,
    assignee: []const u8,
    priority: []const u8,
    milestone: []const u8,
};

pub const Clone = struct {
    arena: Allocator,
    format: object.ObjectFormat,
    clone: World.Clone,
    objects: std.StringHashMapUnmanaged(World.StoredObject),

    pub fn init(
        arena: Allocator,
        format: object.ObjectFormat,
        clone: World.Clone,
    ) Allocator.Error!Clone {
        var set: std.StringHashMapUnmanaged(World.StoredObject) = .empty;
        for (clone.objects) |o| {
            const oid = object.hashObject(format, o.kind, o.data);
            try set.put(arena, try arena.dupe(u8, oid.hex().slice()), o);
        }
        return .{ .arena = arena, .format = format, .clone = clone, .objects = set };
    }

    pub fn ref(c: Clone, name: []const u8) ?[]const u8 {
        for (c.clone.refs) |r| if (std.mem.eql(u8, r.name, name)) return r.oid;
        return null;
    }

    pub fn commit(c: Clone, hex: []const u8) ?object.Commit {
        const o = c.objects.get(hex) orelse return null;
        if (o.kind != .commit) return null;
        return object.Commit.parse(c.arena, c.format, o.data) catch null;
    }

    pub fn matching(c: Clone, prefix: []const u8) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (c.clone.refs) |r| {
            if (!std.mem.startsWith(u8, r.name, "refs/issues/")) continue;
            if (std.mem.startsWith(u8, r.name["refs/issues/".len..], prefix)) try out.append(
                c.arena,
                r.name,
            );
        }
        return out.items;
    }

    pub fn naive(c: Clone, tip_hex: []const u8) RuleError!NaiveIssue {
        return c.naiveAt(&.{tip_hex});
    }

    pub fn naiveAt(c: Clone, tips: []const []const u8) RuleError!NaiveIssue {
        var dag = try Dag.load(c, tips);
        return dag.resolve();
    }
};

/// The merge rule stated differently from the engine, which merges
/// per-parent states pairwise. Here a field's setters are the commits in
/// the history whose trailers set it. Of those, keep the ones that aren't
/// an ancestor of another setter. One left gives the value, several
/// (concurrent ones) go by newest author time, then the greater OID.
///
/// A commit with `Labels:` is a setter of label L only when it changes L's
/// membership compared to all of its ancestors. L is present when any
/// remaining setter says so, so a concurrent add wins.
const Dag = struct {
    arena: Allocator,
    commits: []const Node,
    tips: []const usize,

    const Node = struct {
        hex: []const u8,
        commit: object.Commit,
        block: trailers.Block,
        parents: []const usize,
        ancestors: std.DynamicBitSetUnmanaged,
    };

    fn load(c: Clone, tip_hexes: []const []const u8) RuleError!Dag {
        var index: std.StringHashMapUnmanaged(usize) = .empty;
        var order: std.ArrayList([]const u8) = .empty;
        var stack: std.ArrayList([]const u8) = .empty;
        for (tip_hexes) |t| try stack.append(c.arena, t);
        while (stack.pop()) |hex| {
            if (index.contains(hex)) continue;
            const cm = c.commit(hex) orelse return error.NoRule;
            try index.put(c.arena, hex, order.items.len);
            try order.append(c.arena, hex);
            for (cm.parents) |p| try stack.append(c.arena, try c.arena.dupe(u8, p.hex().slice()));
        }
        const nodes = try c.arena.alloc(Node, order.items.len);
        for (order.items, nodes) |hex, *n| {
            const cm = c.commit(hex).?;
            const parents = try c.arena.alloc(usize, cm.parents.len);
            for (cm.parents, parents) |p, *pi| pi.* = index.get(p.hex().slice()).?;
            n.* = .{
                .hex = hex,
                .commit = cm,
                .block = try trailers.parse(c.arena, cm.message, .{}),
                .parents = parents,
                .ancestors = try std.DynamicBitSetUnmanaged.initEmpty(c.arena, order.items.len),
            };
        }
        // Naive fixpoint. Histories are small and this is easy to trust.
        var changed = true;
        while (changed) {
            changed = false;
            for (nodes) |*n| for (n.parents) |p| {
                const before = n.ancestors.count();
                n.ancestors.set(p);
                n.ancestors.setUnion(nodes[p].ancestors);
                if (n.ancestors.count() != before) changed = true;
            };
        }
        const tips = try c.arena.alloc(usize, tip_hexes.len);
        for (tip_hexes, tips) |t, *ti| ti.* = index.get(t).?;
        return .{ .arena = c.arena, .commits = nodes, .tips = tips };
    }

    /// The tips and their ancestors.
    fn inHistory(d: Dag, i: usize) bool {
        for (d.tips) |t| if (t == i or d.commits[t].ancestors.isSet(i)) return true;
        return false;
    }

    fn isAncestor(d: Dag, a: usize, b: usize) bool {
        return d.commits[b].ancestors.isSet(a);
    }

    /// None of them an ancestor of another.
    fn maximal(d: Dag, setters: []const usize) Allocator.Error![]const usize {
        var out: std.ArrayList(usize) = .empty;
        outer: for (setters) |s| {
            for (setters) |other| if (other != s and d.isAncestor(s, other)) continue :outer;
            try out.append(d.arena, s);
        }
        return out.items;
    }

    fn scalar(d: Dag, key: []const u8) Allocator.Error!?[]const u8 {
        var setters: std.ArrayList(usize) = .empty;
        for (d.commits, 0..) |n, i| {
            if (d.inHistory(i) and lastOf(n.block, key) != null) try setters.append(d.arena, i);
        }
        const top = try d.maximal(setters.items);
        if (top.len == 0) return null;
        var best = top[0];
        for (top[1..]) |t| {
            const a = d.commits[t].commit.author.time;
            const bt = d.commits[best].commit.author.time;
            if (a > bt or (a == bt and std.mem.order(
                u8,
                d.commits[t].hex,
                d.commits[best].hex,
            ) == .gt)) best = t;
        }
        return lastOf(d.commits[best].block, key).?;
    }

    const LabelSetter = struct { commit: usize, present: bool };

    fn member(d: Dag, setters: []const LabelSetter, scope_contains: anytype) Allocator.Error!bool {
        var ids: std.ArrayList(usize) = .empty;
        for (setters) |s| if (scope_contains.has(s.commit)) try ids.append(d.arena, s.commit);
        const top = try d.maximal(ids.items);
        for (top) |t| for (setters) |s| if (s.commit == t and s.present) return true;
        return false;
    }

    fn set(d: Dag, key: []const u8) Allocator.Error![]const []const u8 {
        var universe: std.ArrayList([]const u8) = .empty;
        for (d.commits) |n| if (lastOf(n.block, key)) |v| {
            for (try splitLabels(d.arena, v)) |l| {
                if (!contains(universe.items, l)) try universe.append(d.arena, l);
            }
        };
        // Ancestors first.
        const order = try d.arena.alloc(usize, d.commits.len);
        for (order, 0..) |*o, i| o.* = i;
        std.mem.sort(usize, order, d, struct {
            fn lt(dag: Dag, a: usize, b: usize) bool {
                return dag.commits[a].ancestors.count() < dag.commits[b].ancestors.count();
            }
        }.lt);

        var result: std.ArrayList([]const u8) = .empty;
        for (universe.items) |l| {
            var setters: std.ArrayList(LabelSetter) = .empty;
            for (order) |i| {
                const v = lastOf(d.commits[i].block, key) orelse continue;
                const now = contains(try splitLabels(d.arena, v), l);
                const before = try d.member(setters.items, AncestorScope{ .dag = d, .of = i });
                if (now != before) try setters.append(d.arena, .{ .commit = i, .present = now });
            }
            if (try d.member(setters.items, HistoryScope{ .dag = d })) try result.append(
                d.arena,
                l,
            );
        }
        return result.items;
    }

    const AncestorScope = struct {
        dag: Dag,
        of: usize,
        fn has(s: AncestorScope, i: usize) bool {
            return s.dag.isAncestor(i, s.of);
        }
    };

    const HistoryScope = struct {
        dag: Dag,
        fn has(s: HistoryScope, i: usize) bool {
            return s.dag.inHistory(i);
        }
    };

    fn resolve(d: *Dag) RuleError!NaiveIssue {
        // The parentless commit with the newest committer time.
        var root: ?usize = null;
        for (d.commits, 0..) |n, i| if (n.parents.len == 0 and d.inHistory(i)) {
            const newer = root == null or
                n.commit.committer.time > d.commits[root.?].commit.committer.time;
            if (newer) root = i;
        };
        const r = root orelse return error.NoRule;
        const title = try d.scalar("Title");
        const state = try d.scalar("State");
        return .{
            .title = if (title != null and title.?.len > 0) title.? else try trailers.subject(
                d.arena,
                d.commits[r].commit.message,
            ),
            .title_override = if (title != null and title.?.len > 0) title.? else null,
            .state = if (state != null and state.?.len > 0) state.? else "open",
            .labels = try d.set("Labels"),
            .assignee = (try d.scalar("Assignee")) orelse "",
            .priority = (try d.scalar("Priority")) orelse "",
            .milestone = (try d.scalar("Milestone")) orelse "",
        };
    }
};

pub fn sameSet(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a) |x| if (!contains(b, x)) return false;
    return true;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

fn lastOf(block: trailers.Block, key: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (block.trailers) |t| if (std.ascii.eqlIgnoreCase(t.key, key)) {
        found = t.value;
    };
    return found;
}

pub fn splitLabels(arena: Allocator, value: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, value, ',');
    outer: while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t");
        if (l.len == 0) continue;
        for (out.items) |e| if (std.mem.eql(u8, e, l)) continue :outer;
        try out.append(arena, l);
    }
    return out.items;
}

fn joinLabels(arena: Allocator, labels: []const []const u8) Allocator.Error![]const u8 {
    return std.mem.join(arena, ", ", labels);
}

/// The exact root message `create` must write.
pub fn expectedCreateMessage(
    arena: Allocator,
    a: command.Create,
) Allocator.Error![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    const body = std.mem.trimEnd(u8, a.body orelse "", " \t\r\n");
    w.writer.print(
        "{s}\n\n",
        .{std.mem.trimEnd(u8, a.title, " \t")},
    ) catch return error.OutOfMemory;
    if (body.len > 0) w.writer.print("{s}\n\n", .{body}) catch return error.OutOfMemory;
    w.writer.writeAll("State: open\n") catch return error.OutOfMemory;
    const labels = try splitLabels(arena, try std.mem.join(arena, ",", a.labels));
    if (labels.len > 0) w.writer.print(
        "Labels: {s}\n",
        .{try joinLabels(arena, labels)},
    ) catch return error.OutOfMemory;
    if (a.assignee) |v| if (v.len > 0) w.writer.print(
        "Assignee: {s}\n",
        .{v},
    ) catch return error.OutOfMemory;
    if (a.priority) |v| w.writer.print("Priority: {s}\n", .{v}) catch return error.OutOfMemory;
    if (a.milestone) |v| if (v.len > 0) w.writer.print(
        "Milestone: {s}\n",
        .{v},
    ) catch return error.OutOfMemory;
    w.writer.writeAll("Format-Version: 1\n") catch return error.OutOfMemory;
    return w.written();
}

/// In order.
pub fn expectedEditTrailers(
    arena: Allocator,
    a: command.Edit,
    previous: NaiveIssue,
) Allocator.Error![]const trailers.Trailer {
    var list: std.ArrayList(trailers.Trailer) = .empty;
    if (a.title) |t| try list.append(arena, .{ .key = "Title", .value = t });
    if (a.set_labels != null or a.add.len > 0 or a.remove.len > 0) {
        var next: std.ArrayList([]const u8) = .empty;
        try next.appendSlice(arena, a.set_labels orelse previous.labels);
        try next.appendSlice(arena, a.add);
        var removed: std.ArrayList([]const u8) = .empty;
        for (a.remove) |v| {
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |r| try removed.append(arena, std.mem.trim(u8, r, " \t"));
        }
        var kept: std.ArrayList([]const u8) = .empty;
        for (next.items) |l| {
            if (!contains(removed.items, std.mem.trim(u8, l, " \t"))) try kept.append(arena, l);
        }
        const normalized = try splitLabels(arena, try std.mem.join(arena, ",", kept.items));
        try list.append(arena, .{ .key = "Labels", .value = try joinLabels(arena, normalized) });
    }
    if (a.assignee) |v| try list.append(arena, .{ .key = "Assignee", .value = v });
    if (a.priority) |v| try list.append(arena, .{ .key = "Priority", .value = v });
    if (a.milestone) |v| try list.append(arena, .{ .key = "Milestone", .value = v });
    return list.items;
}

pub fn expectedStateTrailers(
    arena: Allocator,
    a: command.State,
) Allocator.Error![]const trailers.Trailer {
    var list: std.ArrayList(trailers.Trailer) = .empty;
    try list.append(arena, .{ .key = "State", .value = a.state });
    if (a.fixed_by) |v| try list.append(arena, .{ .key = "Fixed-By", .value = v });
    if (a.release) |v| try list.append(arena, .{ .key = "Release", .value = v });
    if (a.reason) |v| try list.append(arena, .{ .key = "Reason", .value = v });
    return list.items;
}

/// Non-blank lines, trimmed, so blank line handling doesn't matter.
pub fn contentLines(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, " \t\r");
        if (std.mem.trim(u8, l, " \t").len == 0) continue;
        try out.append(arena, l);
    }
    return out.items;
}

test expectedCreateMessage {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a: command.Create = .{
        .title = "Crash on login",
        .body = "x",
        .labels = &.{ "bug", " bug " },
    };
    try std.testing.expectEqualStrings(
        "Crash on login\n\nx\n\nState: open\nLabels: bug\nFormat-Version: 1\n",
        try expectedCreateMessage(arena, a),
    );
}

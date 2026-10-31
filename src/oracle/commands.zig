//! Oracle rules for issue commands. Besides object primitives this may
//! use the trailer parser, which test/trailers_git.zig checks against git,
//! and the format's policy constants, but nothing from the model, the
//! engine or the CLI. Expected messages are built from scratch.

const std = @import("std");
const Allocator = std.mem.Allocator;
const issuez = @import("issuez");
const object = issuez.backend.object;
const trailers = issuez.format.trailers;
const hex_fmt = issuez.format.hex;
const World = issuez.backend.GitSim.World;
const fields_fmt = issuez.format.fields;
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
    /// As written, "" when never set.
    deleted: []const u8 = "",
    // Extension fields as written, "" when unset.
    parent: []const u8 = "",
    blocked_by: []const []const u8 = &.{},
    start: []const u8 = "",
    due: []const u8 = "",
    estimate: []const u8 = "",
    workflow: []const u8 = "",
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

    /// Labels, X-Blocked-By.
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
            .deleted = (try d.scalar("X-Deleted")) orelse "",
            .parent = (try d.scalar("X-Parent")) orelse "",
            .blocked_by = try d.set("X-Blocked-By"),
            .start = (try d.scalar("X-Start-Date")) orelse "",
            .due = (try d.scalar("X-Due-Date")) orelse "",
            .estimate = (try d.scalar("X-Estimate-Minutes")) orelse "",
            .workflow = (try d.scalar("X-Workflow-State")) orelse "",
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

/// References as full IDs, the estimate in minutes. Null when the CLI must
/// have refused the arguments.
pub const ExtResolved = struct {
    parent: ?[]const u8 = null,
    blocked_by: []const []const u8 = &.{},
    unblock: []const []const u8 = &.{},
    estimate: ?[]const u8 = null,
};

pub fn resolveExt(arena: Allocator, c: Clone, e: command.Ext) Allocator.Error!?ExtResolved {
    var out: ExtResolved = .{};
    if (e.parent) |p| out.parent = (try uniqueIssue(c, p)) orelse return null;
    var blocked: std.ArrayList([]const u8) = .empty;
    for (e.blocked_by) |p| try blocked.append(arena, (try uniqueIssue(c, p)) orelse return null);
    out.blocked_by = blocked.items;
    var unblock: std.ArrayList([]const u8) = .empty;
    for (e.unblock) |p| try unblock.append(arena, (try uniqueIssue(c, p)) orelse return null);
    out.unblock = unblock.items;
    for ([_]?[]const u8{ e.start, e.due }) |d| if (d) |v| if (!isDate(v)) return null;
    if (e.estimate) |v| {
        const m = minutesOf(v) orelse return null;
        out.estimate = try std.fmt.allocPrint(arena, "{d}", .{m});
    }
    if (e.workflow) |w| if (!contains(try workflowStates(arena, c), w)) return null;
    return out;
}

fn uniqueIssue(c: Clone, prefix: []const u8) Allocator.Error!?[]const u8 {
    const m = try c.matching(prefix);
    if (m.len != 1) return null;
    return m[0]["refs/issues/".len..];
}

fn workflowStates(arena: Allocator, c: Clone) Allocator.Error![]const []const u8 {
    var raw: ?[]const u8 = null;
    for (c.clone.config) |e| if (std.ascii.eqlIgnoreCase(e.key, "issue.workflowStates")) {
        raw = e.value;
    };
    const defaults: []const []const u8 = &fields_fmt.default_workflow;
    const v = raw orelse return defaults;
    const parts = try splitLabels(arena, v);
    return if (parts.len == 0) defaults else parts;
}

/// A real day of the month.
fn isDate(s: []const u8) bool {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return false;
    for (s, 0..) |ch, i| if (i != 4 and i != 7 and !std.ascii.isDigit(ch)) return false;
    const y = std.fmt.parseInt(u16, s[0..4], 10) catch return false;
    const m = std.fmt.parseInt(u4, s[5..7], 10) catch return false;
    const d = std.fmt.parseInt(u8, s[8..10], 10) catch return false;
    if (y == 0 or m < 1 or m > 12 or d < 1) return false;
    return d <= std.time.epoch.getDaysInMonth(y, @enumFromInt(m));
}

/// `90`, `90m`, `2h`, `1h30m`, bounded like the CLI.
fn minutesOf(s: []const u8) ?u32 {
    const cap: u64 = fields_fmt.max_estimate_minutes;
    if (s.len == 0) return null;
    var all_digits = true;
    for (s) |ch| if (!std.ascii.isDigit(ch)) {
        all_digits = false;
    };
    if (all_digits) {
        if (s.len > 1 and s[0] == '0') return null;
        const v = std.fmt.parseInt(u64, s, 10) catch return null;
        return if (v <= cap) @intCast(v) else null;
    }
    var total: u64 = 0;
    var rest = s;
    var hours = false;
    var mins = false;
    while (rest.len > 0) {
        var n: usize = 0;
        while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
        if (n == 0 or n == rest.len or n > 7) return null;
        const v = std.fmt.parseInt(u64, rest[0..n], 10) catch return null;
        if (rest[n] == 'h' and !hours and !mins) {
            hours = true;
            total += v * 60;
        } else if (rest[n] == 'm' and !mins) {
            mins = true;
            total += v;
        } else return null;
        rest = rest[n + 1 ..];
    }
    return if (total <= cap) @intCast(total) else null;
}

/// The exact root message `create` must write.
pub fn expectedCreateMessage(
    arena: Allocator,
    a: command.Create,
    x: ExtResolved,
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
    for (try extTrailers(arena, a.ext, x, null)) |t| {
        w.writer.print("{s}: {s}\n", .{ t.key, t.value }) catch return error.OutOfMemory;
    }
    w.writer.writeAll("Format-Version: 1\n") catch return error.OutOfMemory;
    return w.written();
}

/// In writing order. `previous` is null on create.
fn extTrailers(
    arena: Allocator,
    e: command.Ext,
    x: ExtResolved,
    previous: ?NaiveIssue,
) Allocator.Error![]const trailers.Trailer {
    var list: std.ArrayList(trailers.Trailer) = .empty;
    if (e.cleared("parent")) {
        try list.append(arena, .{ .key = "X-Parent", .value = "" });
    } else if (x.parent) |p| try list.append(arena, .{ .key = "X-Parent", .value = p });
    const touched = e.cleared("blockers") or x.blocked_by.len > 0 or x.unblock.len > 0;
    if (touched) {
        var base: []const []const u8 = &.{};
        if (previous) |prev| if (!e.cleared("blockers")) {
            base = prev.blocked_by;
        };
        var next: std.ArrayList([]const u8) = .empty;
        for ([_][]const []const u8{ base, x.blocked_by }) |part| for (part) |r| {
            if (!isUuidShape(r) or contains(next.items, r) or contains(x.unblock, r)) continue;
            try next.append(arena, r);
        };
        // An empty set writes nothing on create.
        if (previous != null or next.items.len > 0) try list.append(
            arena,
            .{ .key = "X-Blocked-By", .value = try std.mem.join(arena, ", ", next.items) },
        );
    }
    const scalars = [_]struct { []const u8, []const u8, ?[]const u8 }{
        .{ "X-Start-Date", "start", e.start },
        .{ "X-Due-Date", "due", e.due },
        .{ "X-Estimate-Minutes", "estimate", x.estimate },
        .{ "X-Workflow-State", "workflow", e.workflow },
    };
    for (scalars) |s| {
        if (e.cleared(s[1])) {
            try list.append(arena, .{ .key = s[0], .value = "" });
        } else if (s[2]) |v| try list.append(arena, .{ .key = s[0], .value = v });
    }
    return list.items;
}

fn isUuidShape(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |ch, i| switch (i) {
        8, 13, 18, 23 => if (ch != '-') return false,
        else => if (!hex_fmt.isLowerDigit(ch)) return false,
    };
    return true;
}

/// In order.
pub fn expectedEditTrailers(
    arena: Allocator,
    a: command.Edit,
    x: ExtResolved,
    previous: NaiveIssue,
) Allocator.Error![]const trailers.Trailer {
    var list: std.ArrayList(trailers.Trailer) = .empty;
    if (a.title) |t| try list.append(arena, .{ .key = "Title", .value = t });
    const no_labels = a.ext.cleared("labels");
    if (a.set_labels != null or a.add.len > 0 or a.remove.len > 0 or no_labels) {
        var next: std.ArrayList([]const u8) = .empty;
        const base: []const []const u8 = if (no_labels)
            &.{}
        else
            a.set_labels orelse previous.labels;
        try next.appendSlice(arena, base);
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
    const core = [_]struct { []const u8, []const u8, ?[]const u8 }{
        .{ "Assignee", "assignee", a.assignee },
        .{ "Priority", "priority", a.priority },
        .{ "Milestone", "milestone", a.milestone },
    };
    for (core) |f| {
        if (a.ext.cleared(f[1])) {
            try list.append(arena, .{ .key = f[0], .value = "" });
        } else if (f[2]) |v| try list.append(arena, .{ .key = f[0], .value = v });
    }
    try list.appendSlice(arena, try extTrailers(arena, a.ext, x, previous));
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
        try expectedCreateMessage(arena, a, .{}),
    );
}

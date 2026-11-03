//! Which issues the list and the board show, and in what order.
//!
//! The filter text is words and `key:value` terms, all of which must
//! match; a leading `-` negates a term:
//!
//!     login bug label:ui -label:wontfix @ada p:high is:blocked
//!
//! Plain words match the title (ignoring ASCII case), an ID prefix or a
//! label. Keys: `label:`/`l:`, `assignee:`/`a:`/`@`, `priority:`/`p:`,
//! `state:`/`s:`, `workflow:`/`w:`, `milestone:`/`m:`, `parent:` (ID
//! prefix), and `is:` with `blocked`, `child`, `root`, `parent`,
//! `unassigned`, `conflict`, `problem`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const issuez = @import("issuez");
const Snapshot = @import("store.zig").Snapshot;

const Issue = issuez.engine.Issue;
const labels_fmt = issuez.format.labels;
const fields_fmt = issuez.format.fields;

pub const Scope = enum {
    open,
    done,
    all,

    pub fn label(s: Scope) []const u8 {
        return switch (s) {
            .open => "Open",
            .done => "Done",
            .all => "All",
        };
    }
};

pub const SortKey = enum {
    updated,
    created,
    priority,
    title,
    state,
    due,
    id,

    pub fn label(k: SortKey) []const u8 {
        return @tagName(k);
    }

    /// The natural order, which reverse flips.
    pub fn order(k: SortKey) []const u8 {
        return switch (k) {
            .updated => "newest first",
            .created => "newest first",
            .priority => "highest first",
            .title => "A to Z",
            .state => "open first, by workflow",
            .due => "earliest first",
            .id => "by ID",
        };
    }
};

pub const Query = struct {
    scope: Scope = .open,
    text: []const u8 = "",
    key: SortKey = .updated,
    /// Flips the key's natural order: newest, highest, A to Z, not done,
    /// earliest due first.
    reverse: bool = false,
    /// The list shows sub-issues under their parents.
    tree: bool = false,
};

/// A list row. `context` rows don't match but have a descendant that does.
pub const Row = struct { issue: u32, depth: u8 = 0, context: bool = false };

const none = std.math.maxInt(u32);
/// Deeper than this is drawn at this depth.
pub const max_depth = 32;
const max_terms = 32;

const Term = struct {
    negate: bool,
    key: Key,
    value: []const u8,

    const Key = enum { word, label, assignee, priority, state, workflow, milestone, parent, is };
};

fn parseTerms(text: []const u8, out: *[max_terms]Term) []const Term {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t");
    while (it.next()) |raw| {
        if (n == max_terms) break;
        var tok = raw;
        const negate = tok.len > 1 and tok[0] == '-';
        if (negate) tok = tok[1..];
        var term: Term = .{ .negate = negate, .key = .word, .value = tok };
        if (tok.len > 1 and tok[0] == '@') {
            term.key = .assignee;
            term.value = tok[1..];
        } else if (std.mem.findScalar(u8, tok, ':')) |colon| {
            const k = tok[0..colon];
            const map = [_]struct { []const u8, Term.Key }{
                .{ "label", .label },         .{ "l", .label },
                .{ "assignee", .assignee },   .{ "a", .assignee },
                .{ "priority", .priority },   .{ "p", .priority },
                .{ "state", .state },         .{ "s", .state },
                .{ "workflow", .workflow },   .{ "w", .workflow },
                .{ "milestone", .milestone }, .{ "m", .milestone },
                .{ "parent", .parent },       .{ "is", .is },
            };
            for (map) |entry| if (std.ascii.eqlIgnoreCase(k, entry[0])) {
                term.key = entry[1];
                term.value = tok[colon + 1 ..];
                break;
            };
        }
        out[n] = term;
        n += 1;
    }
    return out[0..n];
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(haystack, needle) != null;
}

fn termMatches(snap: *const Snapshot, i: u32, t: Term) bool {
    const issue = snap.issues[i];
    const v = t.value;
    return switch (t.key) {
        .word => containsIgnoreCase(issue.title, v) or std.mem.startsWith(u8, issue.id, v) or
            for (issue.labels) |l| {
                if (containsIgnoreCase(l, v)) break true;
            } else false,
        .label => for (issue.labels) |l| {
            if (std.ascii.eqlIgnoreCase(l, v)) break true;
        } else false,
        .assignee => blk: {
            const a = issue.field("Assignee") orelse "";
            break :blk if (v.len == 0) a.len == 0 else containsIgnoreCase(a, v);
        },
        .priority => std.ascii.eqlIgnoreCase(issue.field("Priority") orelse "", v),
        .state => std.ascii.eqlIgnoreCase(issue.state.text(), v) or
            (std.ascii.eqlIgnoreCase(v, "done") and snap.isDone(i)),
        .workflow => std.ascii.eqlIgnoreCase(snap.proj.workflow(i) orelse "", v),
        .milestone => blk: {
            const m = snap.milestoneName(i) orelse "";
            break :blk if (v.len == 0) m.len == 0 else containsIgnoreCase(m, v);
        },
        .parent => snap.proj.parent[i] != none and
            std.mem.startsWith(u8, snap.issues[snap.proj.parent[i]].id, v),
        .is => isMatches(snap, i, v),
    };
}

fn isMatches(snap: *const Snapshot, i: u32, v: []const u8) bool {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(v, "blocked")) return snap.proj.activelyBlocked(i);
    if (eq(v, "child")) return snap.proj.parent[i] != none;
    if (eq(v, "root")) return snap.proj.parent[i] == none;
    if (eq(v, "parent")) return snap.proj.children[i].len > 0;
    if (eq(v, "unassigned")) return snap.issues[i].field("Assignee") == null or snap.issues[i].field("Assignee").?.len == 0;
    if (eq(v, "conflict")) return snap.issues[i].conflicts.len > 0;
    if (eq(v, "problem")) return snap.proj.problemsOf(i).len > 0;
    if (eq(v, "open")) return !snap.isDone(i);
    if (eq(v, "done") or eq(v, "closed")) return snap.isDone(i);
    return false;
}

fn inScope(snap: *const Snapshot, i: u32, scope: Scope) bool {
    if (snap.issues[i].deleted) return false;
    return switch (scope) {
        .open => !snap.isDone(i),
        .done => snap.isDone(i),
        .all => true,
    };
}

pub fn matches(snap: *const Snapshot, i: u32, scope: Scope, terms: []const Term) bool {
    if (!inScope(snap, i, scope)) return false;
    for (terms) |t| if (termMatches(snap, i, t) == t.negate) return false;
    return true;
}

const Order = struct {
    snap: *const Snapshot,
    key: SortKey,
    reverse: bool,

    /// Negative: `a` comes first, in the key's natural order.
    fn compare(o: Order, a: u32, b: u32) std.math.Order {
        const x = o.snap.issues[a];
        const y = o.snap.issues[b];
        const ord: std.math.Order = switch (o.key) {
            .updated => std.math.order(y.updated, x.updated),
            .created => std.math.order(y.created, x.created),
            .priority => std.math.order(rank(y), rank(x)),
            .title => titleOrder(x.title, y.title),
            .state => std.math.order(@intFromBool(o.snap.isDone(a)), @intFromBool(o.snap.isDone(b)))
                .differ() orelse o.workflowOrder(a, b).differ() orelse
                std.mem.order(u8, x.state.text(), y.state.text()),
            .due => dueOrder(x, y),
            .id => std.mem.order(u8, x.id, y.id),
        };
        // Ties: the most recently touched first.
        return ord.differ() orelse std.math.order(y.updated, x.updated).differ() orelse
            std.mem.order(u8, x.id, y.id);
    }

    fn lessThan(o: Order, a: u32, b: u32) bool {
        const c = o.compare(a, b);
        return if (o.reverse) c == .gt else c == .lt;
    }

    /// In the configured order; states that aren't configured after, by
    /// name, and no workflow state last.
    fn workflowOrder(o: Order, a: u32, b: u32) std.math.Order {
        const wa = o.snap.proj.workflow(a);
        const wb = o.snap.proj.workflow(b);
        if (wa == null or wb == null) return std.math.order(@intFromBool(wa == null), @intFromBool(wb == null));
        const states = o.snap.settings.workflow_states;
        const pa = position(states, wa.?);
        const pb = position(states, wb.?);
        return std.math.order(pa, pb).differ() orelse std.mem.order(u8, wa.?, wb.?);
    }

    fn position(states: []const []const u8, w: []const u8) usize {
        for (states, 0..) |st, n| if (std.mem.eql(u8, st, w)) return n;
        return states.len;
    }

    fn rank(i: Issue) u8 {
        return if (i.priority()) |p| p.rank() else 0;
    }

    fn titleOrder(a: []const u8, b: []const u8) std.math.Order {
        const n = @min(a.len, b.len);
        for (a[0..n], b[0..n]) |x, y| {
            const o = std.math.order(std.ascii.toLower(x), std.ascii.toLower(y));
            if (o != .eq) return o;
        }
        return std.math.order(a.len, b.len);
    }

    /// Earliest first; without a due date last.
    fn dueOrder(x: Issue, y: Issue) std.math.Order {
        const a = x.ext.due_date;
        const b = y.ext.due_date;
        if (a != null and b != null) return a.?.order(b.?);
        if (a == null and b == null) return .eq;
        return if (a != null) .lt else .gt;
    }
};

fn sort(snap: *const Snapshot, items: []u32, q: Query) void {
    std.mem.sort(u32, items, Order{ .snap = snap, .key = q.key, .reverse = q.reverse }, Order.lessThan);
}

/// The list's rows.
pub fn rows(arena: Allocator, snap: *const Snapshot, q: Query) Allocator.Error![]const Row {
    var buf: [max_terms]Term = undefined;
    const terms = parseTerms(q.text, &buf);
    const n: u32 = @intCast(snap.issues.len);
    var out: std.ArrayList(Row) = .empty;
    if (!q.tree) {
        var hits: std.ArrayList(u32) = .empty;
        for (0..n) |i| if (matches(snap, @intCast(i), q.scope, terms)) try hits.append(arena, @intCast(i));
        sort(snap, hits.items, q);
        try out.ensureTotalCapacity(arena, hits.items.len);
        for (hits.items) |i| out.appendAssumeCapacity(.{ .issue = i });
        return out.items;
    }

    // Matches and their ancestors.
    const keep = try arena.alloc(enum { no, context, hit }, n);
    @memset(keep, .no);
    for (0..n) |idx| {
        const i: u32 = @intCast(idx);
        if (!matches(snap, i, q.scope, terms)) continue;
        keep[i] = .hit;
        var p = snap.proj.parent[i];
        var guard: u32 = 0;
        while (p != none and guard < n) : (guard += 1) {
            if (keep[p] == .no) keep[p] = .context;
            p = snap.proj.parent[p];
        }
    }

    // Depth first, siblings in order, without recursion.
    const Frame = struct { issue: u32, depth: u8 };
    var stack: std.ArrayList(Frame) = .empty;
    var level: std.ArrayList(u32) = .empty;
    for (snap.proj.roots) |r| if (keep[r] != .no) try level.append(arena, r);
    sort(snap, level.items, q);
    var k = level.items.len;
    while (k > 0) {
        k -= 1;
        try stack.append(arena, .{ .issue = level.items[k], .depth = 0 });
    }
    while (stack.pop()) |f| {
        assert(keep[f.issue] != .no);
        try out.append(arena, .{ .issue = f.issue, .depth = f.depth, .context = keep[f.issue] == .context });
        level.clearRetainingCapacity();
        for (snap.proj.children[f.issue]) |c| if (keep[c] != .no) try level.append(arena, c);
        sort(snap, level.items, q);
        k = level.items.len;
        while (k > 0) {
            k -= 1;
            try stack.append(arena, .{ .issue = level.items[k], .depth = @min(f.depth + 1, max_depth) });
        }
    }
    assert(out.items.len <= n);
    return out.items;
}

pub const Column = struct {
    /// A workflow state, or "done".
    name: []const u8,
    done: bool,
    cards: []const u32,
    /// Cards can move here: done, a configured workflow state, or none.
    /// Not a state only some issues have.
    target: bool = true,
};

/// The board's columns: the workflow states in order, states issues have
/// that aren't configured, and done work last.
pub fn board(arena: Allocator, snap: *const Snapshot, q: Query) Allocator.Error![]const Column {
    var buf: [max_terms]Term = undefined;
    const terms = parseTerms(q.text, &buf);
    var names: std.ArrayList([]const u8) = .empty;
    try names.appendSlice(arena, snap.settings.workflow_states);
    var cards: std.ArrayList(std.ArrayList(u32)) = .empty;
    for (names.items) |_| try cards.append(arena, .empty);
    var done: std.ArrayList(u32) = .empty;

    for (0..snap.issues.len) |idx| {
        const i: u32 = @intCast(idx);
        if (!matches(snap, i, q.scope, terms)) continue;
        if (snap.isDone(i)) {
            try done.append(arena, i);
            continue;
        }
        const w = snap.proj.workflow(i) orelse "";
        const col = for (names.items, 0..) |name, c| {
            if (std.mem.eql(u8, name, w)) break c;
        } else blk: {
            try names.append(arena, w);
            try cards.append(arena, .empty);
            break :blk names.items.len - 1;
        };
        try cards.items[col].append(arena, i);
    }

    const configured = snap.settings.workflow_states.len;
    const out = try arena.alloc(Column, names.items.len + 1);
    for (names.items, cards.items, out[0..names.items.len], 0..) |name, *c, *col, n| {
        sort(snap, c.items, q);
        col.* = .{
            .name = if (name.len == 0) "(none)" else name,
            .done = false,
            .cards = c.items,
            .target = n < configured or name.len == 0,
        };
    }
    sort(snap, done.items, q);
    out[names.items.len] = .{ .name = "done", .done = true, .cards = done.items };
    return out;
}

const testing = std.testing;

test parseTerms {
    var buf: [max_terms]Term = undefined;
    const t = parseTerms("login -label:ui @ada is:blocked p:", &buf);
    try testing.expectEqual(@as(usize, 5), t.len);
    try testing.expectEqual(Term.Key.word, t[0].key);
    try testing.expect(t[1].negate);
    try testing.expectEqual(Term.Key.label, t[1].key);
    try testing.expectEqualStrings("ui", t[1].value);
    try testing.expectEqual(Term.Key.assignee, t[2].key);
    try testing.expectEqualStrings("ada", t[2].value);
    try testing.expectEqual(Term.Key.is, t[3].key);
    try testing.expectEqualStrings("", t[4].value);
}

//! Oracle rules for issue commands. Besides object primitives this may
//! use the trailer parser, which test/trailers_git.zig checks against git,
//! and the format's policy constants, but nothing from the model, the
//! engine or the CLI. Expected messages are built from scratch.

const std = @import("std");
const stableSort = @import("issuez").sort.stable;
const Allocator = std.mem.Allocator;
const issuez = @import("issuez");
const object = issuez.backend.object;
const trailers = issuez.format.trailers;
const hex_fmt = issuez.format.hex;
const World = issuez.backend.GitSim.World;
const attachment_fmt = issuez.format.attachment;
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
    /// The newest `Assignee` when it is one of `assignees`, "" when there
    /// are none.
    assignee: []const u8,
    /// Every member as written, by the oracle's own reading of format.md §3.
    assignees: []const []const u8 = &.{},
    /// The newest `Assignee` isn't one of `assignees`: the first of them
    /// stands for it, and since the oracle doesn't model member order, any
    /// of them may (`isAssignee`).
    assignee_any: bool = false,
    /// `X-Number` as written, "" when unset.
    number: []const u8 = "",
    /// Present reactions as `<comment hex or -> <emoji> <email>`, by the
    /// oracle's own reading of format.md §5.
    reactions: []const []const u8 = &.{},
    /// `host_keys` as written, "" when unset.
    host: [host_keys.len][]const u8 = @splat(""),
    /// `X-Locked`, `X-Lock-Reason` and `X-Ref` as written, "" when unset.
    locked: []const u8 = "",
    lock_reason: []const u8 = "",
    ref: []const u8 = "",
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
    milestone_id: []const u8 = "",
    milestone_mode: []const u8 = "",
    /// In no particular order.
    attachments: []const NaiveAttachment = &.{},
    /// Of the fields a merge restates: written somewhere in the history,
    /// empty now.
    cleared: []const []const u8 = &.{},
    /// The versions of the description and of each comment, by commit:
    /// the original, then each event that targets it. Order isn't checked.
    description_history: []const NaiveRevision = &.{},
    comment_histories: []const NaiveHistory = &.{},
};

pub const NaiveRevision = struct { commit: []const u8, kind: []const u8 };
pub const NaiveHistory = struct { comment: []const u8, revisions: []const NaiveRevision };

/// Fields as text.
pub const NaiveAttachment = struct {
    id: []const u8,
    media: []const u8,
    size: []const u8,
    sha256: []const u8,
    name: []const u8,

    pub fn value(a: NaiveAttachment, arena: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "{s} {s} {s} sha256:{s} {s}", .{
            a.id, a.media, a.size, a.sha256, a.name,
        });
    }

    pub fn extension(a: NaiveAttachment) []const u8 {
        if (std.mem.eql(u8, a.media, "image/png")) return "png";
        if (std.mem.eql(u8, a.media, "image/jpeg")) return "jpg";
        return "webp";
    }
};

/// The oracle's own reading of the attachment grammar.
pub fn parseAttachment(v: []const u8) ?NaiveAttachment {
    var it = std.mem.splitScalar(u8, v, ' ');
    const id = it.next() orelse return null;
    const media = it.next() orelse return null;
    const size = it.next() orelse return null;
    const hash = it.next() orelse return null;
    const name = it.rest();
    if (!isUuidShape(id)) return null;
    const medias = [_][]const u8{ "image/png", "image/jpeg", "image/webp" };
    if (!contains(&medias, media)) return null;
    if (size.len == 0 or size.len > 8 or size[0] == '0') return null;
    for (size) |ch| if (!std.ascii.isDigit(ch)) return null;
    const bytes = std.fmt.parseInt(u64, size, 10) catch return null;
    if (bytes > attachment_fmt.max_object_bytes) return null;
    if (!std.mem.startsWith(u8, hash, "sha256:") or hash.len != 7 + 64) return null;
    if (!hex_fmt.isLower(hash[7..])) return null;
    if (name.len == 0 or name.len > attachment_fmt.max_name_bytes) return null;
    if (name[0] == ' ' or name[name.len - 1] == ' ') return null;
    for (name) |ch| if (ch < 0x20 or ch == 0x7f) return null;
    if (!std.unicode.utf8ValidateSlice(name)) return null;
    return .{ .id = id, .media = media, .size = size, .sha256 = hash[7..], .name = name };
}

/// `Name` and `X-Milestone-Status` by the same rule as issue fields.
pub const NaiveMilestone = struct {
    id: []const u8,
    name: []const u8,
    /// open, completed or retired. Anything else reads as open.
    status: []const u8,
};

pub const Walk = struct {
    clone: Clone,
    /// Every ID met so far, missing commits too.
    seen: std.StringHashMapUnmanaged(void) = .empty,
    stack: std.ArrayList([]const u8) = .empty,
    /// One of them wasn't there, or isn't a commit.
    missing: bool = false,

    pub fn next(w: *Walk) Allocator.Error!?struct { hex: []const u8, commit: object.Commit } {
        const arena = w.clone.arena;
        while (w.stack.pop()) |hex| {
            if ((try w.seen.getOrPut(arena, hex)).found_existing) continue;
            const cm = w.clone.commit(hex) orelse {
                w.missing = true;
                continue;
            };
            for (cm.parents) |p| try w.stack.append(arena, try p.hexAlloc(arena));
            return .{ .hex = hex, .commit = cm };
        }
        return null;
    }
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
            try set.put(arena, try oid.hexAlloc(arena), o);
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

    /// A commit ID in this repository's format, lowercase.
    pub fn isFullHex(c: Clone, s: []const u8) bool {
        if (s.len != c.format.hexLen()) return false;
        for (s) |ch| if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return false;
        return true;
    }

    /// The commits reachable from `tip`, each once, as far as the objects go.
    pub fn walk(c: Clone, tip: []const u8) Allocator.Error!Walk {
        var w: Walk = .{ .clone = c };
        try w.stack.append(c.arena, tip);
        return w;
    }

    /// What `walk` meets from `tip`, missing commits too.
    pub fn reach(c: Clone, tip: []const u8) Allocator.Error!std.StringHashMapUnmanaged(void) {
        var w = try c.walk(tip);
        while (try w.next()) |_| {}
        return w.seen;
    }

    pub fn matching(c: Clone, prefix: []const u8) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        // `#12`: the issues whose `X-Number` reads as exactly that.
        if (prefix.len > 1 and prefix[0] == '#') {
            for (c.clone.refs) |r| {
                if (!std.mem.startsWith(u8, r.name, "refs/issues/")) continue;
                const n = c.naive(r.oid) catch continue;
                if (std.mem.eql(
                    u8,
                    n.number,
                    prefix[1..],
                ) and validNumber(n.number)) try out.append(c.arena, r.name);
            }
            return out.items;
        }
        for (c.clone.refs) |r| {
            if (!std.mem.startsWith(u8, r.name, "refs/issues/")) continue;
            if (std.mem.startsWith(u8, r.name["refs/issues/".len..], prefix)) try out.append(
                c.arena,
                r.name,
            );
        }
        return out.items;
    }

    pub fn milestones(c: Clone) RuleError![]const NaiveMilestone {
        var out: std.ArrayList(NaiveMilestone) = .empty;
        for (c.clone.refs) |r| {
            if (!std.mem.startsWith(u8, r.name, "refs/milestones/")) continue;
            var dag = try Dag.load(c, &.{r.oid});
            const status = (try dag.scalar("X-Milestone-Status")) orelse "open";
            const known = std.mem.eql(u8, status, "completed") or
                std.mem.eql(u8, status, "retired");
            try out.append(c.arena, .{
                .id = r.name["refs/milestones/".len..],
                .name = (try dag.scalar("Name")) orelse "",
                .status = if (known) status else "open",
            });
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

    /// Whether every trailer in `want` is what the issue at `tip` already
    /// has, by the oracle's own reading: a field its value as written (none
    /// is the same as empty, no state open, no flag false), a list its
    /// members. NoRule for what it
    /// doesn't read that way: events, per-commit trailers.
    pub fn restates(c: Clone, tip: []const u8, want: []const Trailer) RuleError!bool {
        const dag = try Dag.load(c, &.{tip});
        for (want) |t| {
            if (std.ascii.eqlIgnoreCase(t.key, "X-Event") or
                std.ascii.eqlIgnoreCase(t.key, "X-Comment") or
                std.ascii.eqlIgnoreCase(t.key, "X-Message") or
                std.ascii.startsWithIgnoreCase(t.key, "X-Original-")) return error.NoRule;
            const is_set = for ([_][]const u8{ "Labels", "X-Blocked-By", "X-Assignees" }) |k| {
                if (std.ascii.eqlIgnoreCase(k, t.key)) break true;
            } else false;
            if (is_set) {
                const have = try dag.set(t.key);
                const given = try splitLabels(c.arena, t.value);
                if (have.len != given.len) return false;
                for (given) |m| if (!contains(have, m)) return false;
            } else {
                const have = (try dag.scalar(t.key)) orelse "";
                if (!std.mem.eql(u8, shown(t.key, have), shown(t.key, t.value))) return false;
            }
        }
        return true;
    }
};

pub const NaiveChange = struct {
    key: []const u8,
    op: []const u8,
    old: ?[]const u8,
    new: ?[]const u8,
};

/// The fields whose changes the oracle states.
pub const change_scalars = [_][]const u8{
    "Title",            "State",          "Assignee",         "Priority",
    "Milestone",        "Fixed-By",       "Release",          "Reason",
    "X-Parent",         "X-Start-Date",   "X-Due-Date",       "X-Estimate-Minutes",
    "X-Workflow-State", "X-Milestone-Id", "X-Milestone-Mode", "X-Deleted",
    "X-Number",         "X-Locked",       "X-Lock-Reason",    "X-Ref",
};
pub const change_sets = [_][]const u8{ "Labels", "X-Blocked-By", "X-Assignees" };

const Values = struct {
    scalars: [change_scalars.len]?[]const u8 = @splat(null),
    sets: [change_sets.len][]const []const u8 = @splat(&.{}),
    attachments: []const []const u8 = &.{},
};

/// What a commit changed: the fields read at the commit, against the
/// fields read at its parents together (none for a root). Its own way of
/// reading per-commit changes, from the tip-reading rule.
pub fn changesOf(c: Clone, commit_hex: []const u8) RuleError![]const NaiveChange {
    const cm = c.commit(commit_hex) orelse return error.NoRule;
    var parents: std.ArrayList([]const u8) = .empty;
    for (cm.parents) |p| try parents.append(c.arena, try p.hexAlloc(c.arena));
    const before = try valuesAt(c, parents.items);
    const after = try valuesAt(c, &.{commit_hex});
    var out: std.ArrayList(NaiveChange) = .empty;
    for (change_scalars, before.scalars, after.scalars) |k, old, new| {
        if (old == null and new == null) continue;
        if (old != null and new != null and std.mem.eql(u8, old.?, new.?)) continue;
        try out.append(
            c.arena,
            .{ .key = k, .op = if (new == null) "clear" else "set", .old = old, .new = new },
        );
    }
    for (
        change_sets,
        before.sets,
        after.sets,
    ) |k, old, new| try memberChanges(c.arena, &out, k, old, new);
    try memberChanges(c.arena, &out, "X-Attachment", before.attachments, after.attachments);
    return out.items;
}

fn memberChanges(
    arena: Allocator,
    out: *std.ArrayList(NaiveChange),
    key: []const u8,
    old: []const []const u8,
    new: []const []const u8,
) Allocator.Error!void {
    for (new) |m| if (!contains(
        old,
        m,
    )) try out.append(arena, .{ .key = key, .op = "add", .old = null, .new = m });
    for (old) |m| if (!contains(
        new,
        m,
    )) try out.append(arena, .{ .key = key, .op = "remove", .old = m, .new = null });
}

fn valuesAt(c: Clone, tips: []const []const u8) RuleError!Values {
    var v: Values = .{};
    if (tips.len == 0) return v;
    var dag = try Dag.load(c, tips);
    for (change_scalars, &v.scalars) |k, *x| {
        const raw = try dag.scalar(k);
        x.* = if (raw) |r| (if (r.len == 0) null else r) else null;
    }
    for (change_sets, &v.sets) |k, *x| x.* = try dag.set(k);
    var ids: std.ArrayList([]const u8) = .empty;
    for (try dag.attachments()) |a| try ids.append(c.arena, a.id);
    v.attachments = ids.items;
    return v;
}

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
            for (cm.parents) |p| try stack.append(c.arena, try p.hexAlloc(c.arena));
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

    /// Per UUID, the commits that add or remove it. Present when a maximal
    /// one adds it, with the newest add's value.
    fn attachments(d: Dag) Allocator.Error![]const NaiveAttachment {
        const Entry = struct { commit: usize, add: ?NaiveAttachment };
        var per: std.array_hash_map.String(std.ArrayList(Entry)) = .empty;
        for (d.commits, 0..) |n, i| {
            if (!d.inHistory(i)) continue;
            // The last trailer for a UUID in a commit counts.
            var mine: std.array_hash_map.String(?NaiveAttachment) = .empty;
            for (n.block.trailers) |t| {
                if (std.ascii.eqlIgnoreCase(t.key, "X-Attachment")) {
                    const a = parseAttachment(t.value) orelse continue;
                    try mine.put(d.arena, a.id, a);
                } else if (std.ascii.eqlIgnoreCase(t.key, "X-Attachment-Removed")) {
                    if (isUuidShape(t.value)) try mine.put(d.arena, t.value, null);
                }
            }
            for (mine.keys(), mine.values()) |id, a| {
                const gop = try per.getOrPut(d.arena, id);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(d.arena, .{ .commit = i, .add = a });
            }
        }
        var out: std.ArrayList(NaiveAttachment) = .empty;
        for (per.values()) |entries| {
            var ids: std.ArrayList(usize) = .empty;
            for (entries.items) |e| try ids.append(d.arena, e.commit);
            const top = try d.maximal(ids.items);
            var best: ?Entry = null;
            for (entries.items) |e| {
                if (e.add == null or !containsIndex(top, e.commit)) continue;
                if (best) |b| {
                    const x = d.commits[e.commit];
                    const y = d.commits[b.commit];
                    const newer = x.commit.author.time > y.commit.author.time or
                        (x.commit.author.time == y.commit.author.time and
                            std.mem.order(u8, x.hex, y.hex) == .gt);
                    if (!newer) continue;
                }
                best = e;
            }
            if (best) |b| try out.append(d.arena, b.add.?);
        }
        return out.items;
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
    /// The value a commit lists for a set. For `X-Assignees`, a commit
    /// that isn't a merge and writes `Assignee` without it lists that one
    /// (format.md §3).
    fn listed(d: Dag, i: usize, key: []const u8) ?[]const u8 {
        const n = d.commits[i];
        if (lastOf(n.block, key)) |v| return v;
        if (!std.mem.eql(u8, key, "X-Assignees") or n.parents.len > 1) return null;
        return lastOf(n.block, "Assignee");
    }

    fn set(d: Dag, key: []const u8) Allocator.Error![]const []const u8 {
        var universe: std.ArrayList([]const u8) = .empty;
        for (0..d.commits.len) |ci| if (d.listed(ci, key)) |v| {
            for (try splitLabels(d.arena, v)) |l| {
                if (!contains(universe.items, l)) try universe.append(d.arena, l);
            }
        };
        // Ancestors first.
        const order = try d.arena.alloc(usize, d.commits.len);
        for (order, 0..) |*o, i| o.* = i;
        stableSort(usize, order, d, struct {
            fn lt(dag: Dag, a: usize, b: usize) bool {
                return dag.commits[a].ancestors.count() < dag.commits[b].ancestors.count();
            }
        }.lt);

        var result: std.ArrayList([]const u8) = .empty;
        for (universe.items) |l| {
            var setters: std.ArrayList(LabelSetter) = .empty;
            for (order) |i| {
                const v = d.listed(i, key) orelse continue;
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
        var cleared: std.ArrayList([]const u8) = .empty;
        // Of the fields a merge restates.
        for ([_][]const u8{
            "Title",
            "Priority",
            "Milestone",
            "X-Parent",
            "X-Start-Date",
            "X-Due-Date",
            "X-Estimate-Minutes",
            "X-Workflow-State",
            "X-Milestone-Id",
            "X-Milestone-Mode",
            "X-Deleted",
        }) |key| {
            const v = try d.scalar(key);
            if (v != null and v.?.len == 0) try cleared.append(d.arena, key);
        }
        for ([_][]const u8{ "Labels", "X-Blocked-By" }) |key| {
            if ((try d.set(key)).len > 0) continue;
            for (d.commits, 0..) |n, i| if (d.inHistory(i) and lastOf(n.block, key) != null) {
                try cleared.append(d.arena, key);
                break;
            };
        }
        // format.md §3: the assignees decide; `Assignee` names one of them.
        const assignees = try d.set("X-Assignees");
        const newest = try d.scalar("Assignee");
        const assignee: []const u8 = if (newest) |v|
            (if (contains(assignees, v)) v else "")
        else
            "";
        if (assignees.len == 0 and newest != null) try cleared.append(d.arena, "Assignee");
        return .{
            .cleared = cleared.items,
            .title = if (title != null and title.?.len > 0) title.? else try trailers.subject(
                d.arena,
                d.commits[r].commit.message,
            ),
            .title_override = if (title != null and title.?.len > 0) title.? else null,
            .state = if (state != null and state.?.len > 0) state.? else "open",
            .labels = try d.set("Labels"),
            .assignee = assignee,
            .assignees = assignees,
            .assignee_any = assignee.len == 0 and assignees.len > 0,
            .number = (try d.scalar("X-Number")) orelse "",
            .locked = (try d.scalar("X-Locked")) orelse "",
            .lock_reason = (try d.scalar("X-Lock-Reason")) orelse "",
            .ref = (try d.scalar("X-Ref")) orelse "",
            .reactions = try d.reactions(),
            .host = blk: {
                var h: [host_keys.len][]const u8 = undefined;
                for (host_keys, &h) |k, *v| v.* = (try d.scalar(k)) orelse "";
                break :blk h;
            },
            .priority = (try d.scalar("Priority")) orelse "",
            .milestone = (try d.scalar("Milestone")) orelse "",
            .deleted = (try d.scalar("X-Deleted")) orelse "",
            .parent = (try d.scalar("X-Parent")) orelse "",
            .blocked_by = try d.set("X-Blocked-By"),
            .start = (try d.scalar("X-Start-Date")) orelse "",
            .due = (try d.scalar("X-Due-Date")) orelse "",
            .estimate = (try d.scalar("X-Estimate-Minutes")) orelse "",
            .workflow = (try d.scalar("X-Workflow-State")) orelse "",
            .milestone_id = (try d.scalar("X-Milestone-Id")) orelse "",
            .milestone_mode = (try d.scalar("X-Milestone-Mode")) orelse "",
            .attachments = try d.attachments(),
            .description_history = try d.revisionsOf(r, null),
            .comment_histories = try d.histories(),
        };
    }

    /// An event commit, stated plainly: one parent, one `X-Event` of a
    /// known kind; those that target a comment name, in `X-Comment`, a
    /// commit of this history with one parent that is no event itself.
    fn eventOf(d: Dag, i: usize) ?struct { kind: []const u8, target: ?usize } {
        const n = d.commits[i];
        const kind = soleEvent(n.block) orelse return null;
        if (std.mem.eql(u8, kind, "description-edit")) return .{ .kind = "edit", .target = null };
        const name = if (std.mem.eql(u8, kind, "comment-edit"))
            "edit"
        else if (std.mem.eql(u8, kind, "comment-delete"))
            "delete"
        else if (std.mem.eql(u8, kind, "comment-restore")) "restore" else return null;
        const target = lastOf(n.block, "X-Comment") orelse return null;
        for (d.commits, 0..) |t, ti| {
            if (!std.mem.eql(u8, t.hex, target) or !d.inHistory(ti)) continue;
            if (t.parents.len != 1 or d.hasEvent(ti)) return null;
            return .{ .kind = name, .target = ti };
        }
        return null;
    }

    /// The value of a commit's one `X-Event`; null for none or several.
    fn soleEvent(block: trailers.Block) ?[]const u8 {
        var found: ?[]const u8 = null;
        for (block.trailers) |t| if (std.ascii.eqlIgnoreCase(t.key, "X-Event")) {
            if (found != null) return null;
            found = t.value;
        };
        return found;
    }

    fn hasEvent(d: Dag, i: usize) bool {
        return lastOf(d.commits[i].block, "X-Event") != null;
    }

    /// `first` and the events that target `comment` (null: the
    /// description's).
    fn revisionsOf(d: Dag, first: usize, comment: ?usize) Allocator.Error![]const NaiveRevision {
        var out: std.ArrayList(NaiveRevision) = .empty;
        try out.append(d.arena, .{ .commit = d.commits[first].hex, .kind = "original" });
        for (d.commits, 0..) |n, i| {
            if (!d.inHistory(i) or n.parents.len != 1) continue;
            const e = d.eventOf(i) orelse continue;
            if (comment) |c| {
                if (e.target != c) continue;
            } else if (e.target != null) continue;
            try out.append(d.arena, .{ .commit = n.hex, .kind = e.kind });
        }
        return out.items;
    }

    /// A reaction commit: one parent, one `X-Event: reaction`, a valid
    /// `X-Reaction`, and an `X-Comment`, if any, naming a comment here.
    /// The member it sets, and whether it adds it.
    fn reactionOf(d: Dag, i: usize) Allocator.Error!?struct { member: []const u8, add: bool } {
        const n = d.commits[i];
        if (n.parents.len != 1) return null;
        const kind = soleEvent(n.block) orelse return null;
        if (!std.mem.eql(u8, kind, "reaction")) return null;
        const r = lastOf(n.block, "X-Reaction") orelse return null;
        if (r.len < 2 or (r[0] != '+' and r[0] != '-')) return null;
        const emoji = r[1..];
        if (emoji.len > 64) return null;
        for (emoji) |ch| if (ch <= 0x20 or ch == 0x7f or ch == ',') return null;
        var target: []const u8 = "-";
        if (lastOf(n.block, "X-Comment")) |t| {
            const ok = for (d.commits, 0..) |x, xi| {
                if (!std.mem.eql(u8, x.hex, t) or !d.inHistory(xi)) continue;
                break x.parents.len == 1 and !d.hasEvent(xi);
            } else false;
            if (!ok) return null;
            target = t;
        }
        return .{
            .member = try std.fmt.allocPrint(
                d.arena,
                "{s} {s} {s}",
                .{ target, emoji, n.commit.author.email },
            ),
            .add = r[0] == '+',
        };
    }

    /// Per member, its setters that no other setter descends from; present
    /// when one of them adds it.
    fn reactions(d: Dag) Allocator.Error![]const []const u8 {
        const Setter = struct { commit: usize, member: []const u8, add: bool };
        var setters: std.ArrayList(Setter) = .empty;
        for (0..d.commits.len) |i| {
            if (!d.inHistory(i)) continue;
            const r = (try d.reactionOf(i)) orelse continue;
            try setters.append(d.arena, .{ .commit = i, .member = r.member, .add = r.add });
        }
        var out: std.ArrayList([]const u8) = .empty;
        for (setters.items) |s| {
            if (contains(out.items, s.member)) continue;
            var present = false;
            for (setters.items) |t| {
                if (!std.mem.eql(u8, t.member, s.member)) continue;
                const overtaken = for (setters.items) |u| {
                    if (u.commit != t.commit and std.mem.eql(
                        u8,
                        u.member,
                        t.member,
                    ) and d.isAncestor(t.commit, u.commit))
                        break true;
                } else false;
                if (!overtaken and t.add) present = true;
            }
            if (present) try out.append(d.arena, s.member);
        }
        return out.items;
    }

    /// For every comment commit: one parent and no event.
    fn histories(d: Dag) Allocator.Error![]const NaiveHistory {
        var out: std.ArrayList(NaiveHistory) = .empty;
        for (d.commits, 0..) |n, i| {
            if (!d.inHistory(i) or n.parents.len != 1 or d.hasEvent(i)) continue;
            try out.append(d.arena, .{ .comment = n.hex, .revisions = try d.revisionsOf(i, i) });
        }
        return out.items;
    }
};

/// Whether `got`, as written, is the assignee `n` resolves to.
pub fn isAssignee(n: NaiveIssue, got: []const u8) bool {
    if (n.assignee_any) return contains(n.assignees, got);
    return std.mem.eql(u8, got, n.assignee);
}

pub fn sameSet(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a) |x| if (!contains(b, x)) return false;
    return true;
}

/// format.md: an issue without `State` is open; `X-Deleted` and
/// `X-Locked` are false unless `true`.
fn shown(key: []const u8, value: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(key, "State")) return if (value.len > 0) value else "open";
    if (std.ascii.eqlIgnoreCase(key, "X-Deleted") or std.ascii.eqlIgnoreCase(key, "X-Locked"))
        return if (std.mem.eql(u8, value, "true")) "true" else "false";
    return value;
}

fn containsIndex(list: []const usize, item: usize) bool {
    for (list) |x| if (x == item) return true;
    return false;
}

pub fn containsText(list: []const []const u8, item: []const u8) bool {
    return contains(list, item);
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
    /// null writes none.
    milestone_text: ?[]const u8 = null,
    milestone_id: ?[]const u8 = null,
    milestone_mode: ?[]const u8 = null,
};

/// `previous` is null on create.
pub fn resolveExt(
    arena: Allocator,
    c: Clone,
    e: command.Ext,
    text: ?[]const u8,
    previous: ?NaiveIssue,
) RuleError!?ExtResolved {
    var out: ExtResolved = .{};
    if (!try resolveMilestone(c, e, text, previous, &out)) return null;
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

/// The CLI's milestone rules again. False when the CLI must refuse.
fn resolveMilestone(
    c: Clone,
    e: command.Ext,
    text_arg: ?[]const u8,
    previous: ?NaiveIssue,
    out: *ExtResolved,
) RuleError!bool {
    const eql = std.mem.eql;
    const text: ?[]const u8 = if (e.cleared("milestone")) "" else text_arg;
    var mode: ?[]const u8 = null;
    if (e.milestone_mode) |m| {
        if (!eql(u8, m, "inherit") and !eql(u8, m, "none") and !eql(u8, m, "explicit"))
            return false;
        mode = m;
    }
    const all = try c.milestones();
    const prev_id = if (previous) |p| p.milestone_id else "";
    if (e.milestone_id) |key| {
        if (text != null) return false;
        if (mode != null and !eql(u8, mode.?, "explicit")) return false;
        var hit: ?NaiveMilestone = null;
        var hits: usize = 0;
        if (key.len >= 4) for (all) |m| if (std.mem.startsWith(u8, m.id, key)) {
            hit = m;
            hits += 1;
        };
        if (hits == 0) for (all) |m| if (!eql(u8, m.status, "retired") and eql(u8, m.name, key)) {
            hit = m;
            hits += 1;
        };
        if (hits != 1) return false;
        // Restating the issue's own link changes nothing, so no guard runs
        // and a completed or retired milestone is fine.
        const unchanged = if (previous) |p| eql(u8, p.milestone_id, hit.?.id) and
            eql(u8, p.milestone, hit.?.name) and
            (p.milestone_mode.len == 0 or eql(u8, p.milestone_mode, "explicit")) else false;
        if (!eql(u8, hit.?.status, "open") and !unchanged) return false;
        out.milestone_text = hit.?.name;
        out.milestone_id = hit.?.id;
        out.milestone_mode = "explicit";
        return true;
    }
    const explicit = mode != null and eql(u8, mode.?, "explicit");
    if (explicit and text != null and text.?.len == 0) return false;
    if (explicit and text == null and prev_id.len == 0) return false;
    const t = text orelse {
        // Only a mode. On edit, inherit/none also clear the text and ID.
        if (previous != null and mode != null and !explicit) {
            out.milestone_text = "";
            out.milestone_id = "";
        }
        out.milestone_mode = mode;
        return true;
    };
    if (t.len == 0) {
        // Invalid values link nothing. A parent given now counts.
        const linked = e.parent != null or if (previous) |p|
            isUuidShape(p.milestone_id) or isUuidShape(p.parent) or
                eql(u8, p.milestone_mode, "inherit") or eql(u8, p.milestone_mode, "none") or
                eql(u8, p.milestone_mode, "explicit")
        else
            false;
        const m: ?[]const u8 = mode orelse (if (linked) @as([]const u8, "none") else null);
        // create writes no empty Milestone.
        if (previous != null) out.milestone_text = "";
        if (m != null and previous != null) out.milestone_id = "";
        out.milestone_mode = m;
        return true;
    }
    if (mode != null and !explicit) {
        out.milestone_text = t;
        out.milestone_id = "";
        if (previous == null) out.milestone_id = null;
        out.milestone_mode = mode;
        return true;
    }
    var open_hit: ?NaiveMilestone = null;
    var open_hits: usize = 0;
    var any_named = false;
    for (all) |m| if (eql(u8, m.name, t)) {
        any_named = true;
        if (eql(u8, m.status, "open")) {
            open_hit = m;
            open_hits += 1;
        }
    };
    if (open_hits > 1) return false;
    if (open_hits == 1) {
        out.milestone_text = t;
        out.milestone_id = open_hit.?.id;
        out.milestone_mode = "explicit";
        return true;
    }
    if (any_named or explicit) return false;
    out.milestone_text = t;
    if (prev_id.len > 0) {
        out.milestone_id = "";
        out.milestone_mode = "none";
    }
    return true;
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
    var people: std.ArrayList([]const u8) = .empty;
    if (a.assignee) |v| if (v.len > 0) try people.append(arena, v);
    try people.appendSlice(arena, a.more_assignees);
    for (try assigneeTrailers(arena, try assigneeSet(arena, people.items, &.{}), false)) |t| {
        w.writer.print("{s}: {s}\n", .{ t.key, t.value }) catch return error.OutOfMemory;
    }
    if (a.priority) |v| w.writer.print("Priority: {s}\n", .{v}) catch return error.OutOfMemory;
    if (x.milestone_text) |v| if (v.len > 0) w.writer.print(
        "Milestone: {s}\n",
        .{v},
    ) catch return error.OutOfMemory;
    for (try extTrailers(arena, a.ext, x, null)) |t| {
        w.writer.print("{s}: {s}\n", .{ t.key, t.value }) catch return error.OutOfMemory;
    }
    if (a.number) |n| w.writer.print("X-Number: {s}\n", .{n}) catch return error.OutOfMemory;
    for (a.fields) |f| {
        const eq = std.mem.findScalar(u8, f, '=').?;
        if (eq + 1 < f.len) w.writer.print(
            "{s}: {s}\n",
            .{ f[0..eq], f[eq + 1 ..] },
        ) catch return error.OutOfMemory;
    }
    for (try originalTrailers(arena, a.original_author, a.original_id)) |t| {
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
    // create writes no empty X-Milestone-Id.
    if (x.milestone_id) |v| if (v.len > 0 or previous != null) {
        try list.append(arena, .{ .key = "X-Milestone-Id", .value = v });
    };
    if (x.milestone_mode) |v| try list.append(arena, .{ .key = "X-Milestone-Mode", .value = v });
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
    if (a.state) |st| {
        try list.append(arena, .{ .key = "State", .value = st });
        if (a.fixed_by) |v| try list.append(arena, .{ .key = "Fixed-By", .value = v });
        if (a.reason) |v| try list.append(arena, .{ .key = "Reason", .value = v });
    }
    if (a.title) |t| try list.append(arena, .{ .key = "Title", .value = t });
    // Written once: only when it has none (or none that reads as one).
    if (a.number) |n| if (!validNumber(previous.number))
        try list.append(arena, .{ .key = "X-Number", .value = n });
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
    const cleared = a.ext.cleared("assignee");
    // `--add-assignee ""` adds nobody, as the CLI reads it.
    var adds: std.ArrayList([]const u8) = .empty;
    for (a.add_assignees) |v| if (v.len > 0) try adds.append(arena, v);
    if (a.assignee != null or cleared or adds.items.len > 0 or a.unassign.len > 0) {
        var next: std.ArrayList([]const u8) = .empty;
        if (cleared) {} else if (a.assignee) |v| {
            if (v.len > 0) try next.append(arena, v);
        } else try next.appendSlice(arena, previous.assignees);
        try next.appendSlice(arena, adds.items);
        try list.appendSlice(
            arena,
            try assigneeTrailers(arena, try assigneeSet(arena, next.items, a.unassign), true),
        );
    }
    const core = [_]struct { []const u8, []const u8, ?[]const u8 }{
        .{ "Priority", "priority", a.priority },
    };
    for (core) |f| {
        if (a.ext.cleared(f[1])) {
            try list.append(arena, .{ .key = f[0], .value = "" });
        } else if (f[2]) |v| try list.append(arena, .{ .key = f[0], .value = v });
    }
    if (x.milestone_text) |v| try list.append(arena, .{ .key = "Milestone", .value = v });
    try list.appendSlice(arena, try extTrailers(arena, a.ext, x, previous));
    if (a.lock) |l| {
        try list.append(arena, .{ .key = "X-Locked", .value = if (l) "true" else "false" });
        const reason = if (l) (a.lock_reason orelse "") else "";
        // Unlocking, or locking without one, clears an earlier reason.
        if (reason.len > 0 or previous.lock_reason.len > 0)
            try list.append(arena, .{ .key = "X-Lock-Reason", .value = reason });
    }
    if (a.ref) |v| try list.append(arena, .{ .key = "X-Ref", .value = v });
    for (a.fields) |f| {
        const eq = std.mem.findScalar(u8, f, '=').?;
        try list.append(arena, .{ .key = f[0..eq], .value = f[eq + 1 ..] });
    }
    try list.appendSlice(arena, try originalTrailers(arena, a.original_author, a.original_id));
    if (a.comment.len > 0) try list.append(arena, comment_marker);
    return list.items;
}

/// Without duplicates and the ones removed, by value or email.
fn assigneeSet(
    arena: Allocator,
    members: []const []const u8,
    remove: []const []const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (members) |raw| {
        const m = std.mem.trim(u8, raw, " \t");
        if (m.len == 0 or contains(out.items, m)) continue;
        // The email is the last word.
        const email = if (std.mem.findScalarLast(u8, m, ' ')) |sp| m[sp + 1 ..] else m;
        const gone = for (remove) |r| {
            const t = std.mem.trim(u8, r, " \t");
            if (std.mem.eql(u8, t, m) or std.mem.eql(u8, t, email)) break true;
        } else false;
        if (!gone) try out.append(arena, m);
    }
    return out.items;
}

/// format.md §3: `Assignee` with the first, `X-Assignees` for several.
fn assigneeTrailers(
    arena: Allocator,
    set: []const []const u8,
    clear: bool,
) Allocator.Error![]const trailers.Trailer {
    var list: std.ArrayList(trailers.Trailer) = .empty;
    if (set.len == 0 and !clear) return list.items;
    try list.append(arena, .{ .key = "Assignee", .value = if (set.len > 0) set[0] else "" });
    if (set.len > 1) try list.append(
        arena,
        .{ .key = "X-Assignees", .value = try std.mem.join(arena, ", ", set) },
    );
    return list.items;
}

/// format.md §3: decimal from 1, no leading zero, at most 2^53.
/// What a merge commit restates, as this oracle reads format.md §4. A field
/// written before but empty now is restated empty.
pub fn restatedBy(arena: Allocator, n: NaiveIssue) Allocator.Error!std.ArrayList(Trailer) {
    var want: std.ArrayList(Trailer) = .empty;
    const was = struct {
        fn f(x: NaiveIssue, key: []const u8) bool {
            for (x.cleared) |k| if (std.mem.eql(u8, k, key)) return true;
            return false;
        }
    }.f;
    try want.append(arena, .{ .key = "State", .value = n.state });
    if (n.title_override) |t|
        try want.append(arena, .{ .key = "Title", .value = t })
    else if (was(n, "Title"))
        try want.append(arena, .{ .key = "Title", .value = "" });
    if (n.labels.len > 0) try want.append(
        arena,
        .{ .key = "Labels", .value = try std.mem.join(arena, ", ", n.labels) },
    ) else if (was(n, "Labels")) try want.append(arena, .{ .key = "Labels", .value = "" });
    for ([_]Trailer{
        // Any assignee may stand in (`isAssignee`): the first here.
        .{ .key = "Assignee", .value = if (n.assignee_any) n.assignees[0] else n.assignee },
        .{ .key = "Priority", .value = n.priority },
        .{ .key = "Milestone", .value = n.milestone },
    }) |t| if (t.value.len > 0 or was(n, t.key)) try want.append(arena, t);
    // Extension fields as written, then the blockers.
    for ([_]Trailer{
        .{ .key = "X-Parent", .value = n.parent },
        .{ .key = "X-Start-Date", .value = n.start },
        .{ .key = "X-Due-Date", .value = n.due },
        .{ .key = "X-Estimate-Minutes", .value = n.estimate },
        .{ .key = "X-Workflow-State", .value = n.workflow },
        .{ .key = "X-Milestone-Id", .value = n.milestone_id },
        .{ .key = "X-Milestone-Mode", .value = n.milestone_mode },
        .{ .key = "X-Deleted", .value = n.deleted },
    }) |t| if (t.value.len > 0 or was(n, t.key)) try want.append(arena, t);
    if (n.blocked_by.len > 0) try want.append(arena, .{
        .key = "X-Blocked-By",
        .value = try std.mem.join(arena, ", ", n.blocked_by),
    }) else if (was(n, "X-Blocked-By")) try want.append(
        arena,
        .{ .key = "X-Blocked-By", .value = "" },
    );
    return want;
}

pub fn validNumber(s: []const u8) bool {
    if (s.len == 0 or s.len > 16 or s[0] == '0') return false;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return (std.fmt.parseInt(u64, s, 10) catch return false) <= 1 << 53;
}

pub fn originalTrailers(
    arena: Allocator,
    author: ?[]const u8,
    id: ?[]const u8,
) Allocator.Error![]const trailers.Trailer {
    var list: std.ArrayList(trailers.Trailer) = .empty;
    if (author) |v| try list.append(arena, .{ .key = "X-Original-Author", .value = v });
    if (id) |v| try list.append(arena, .{ .key = "X-Original-Id", .value = v });
    return list.items;
}

/// The keys format.md gives a meaning, stated here on their own.
const format_keys = [_][]const u8{
    "State",                "Title",             "Labels",         "Assignee",
    "Priority",             "Milestone",         "Fixed-By",       "Release",
    "Reason",               "Format-Version",    "X-Milestone-Id", "X-Milestone-Mode",
    "X-Parent",             "X-Blocked-By",      "X-Start-Date",   "X-Due-Date",
    "X-Estimate-Minutes",   "X-Workflow-State",  "X-Deleted",      "X-Attachment",
    "X-Attachment-Removed", "X-Event",           "X-Comment",      "X-Assignees",
    "X-Number",             "X-Locked",          "X-Lock-Reason",  "X-Ref",
    "X-Message",            "X-Original-Author", "X-Original-Id",  "Provider-Comment-ID",
    "Exported-Commit",      "X-Author-Id",
};

/// format.md §2: a host field is an `X-` key the format doesn't use, made
/// of letters, digits and `-`.
pub fn hostFieldOk(spec: []const u8) bool {
    const eq = std.mem.findScalar(u8, spec, '=') orelse return false;
    const key = spec[0..eq];
    if (key.len < 3 or !std.ascii.startsWithIgnoreCase(key, "X-")) return false;
    for (key) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    for (format_keys) |k| if (std.ascii.eqlIgnoreCase(k, key)) return false;
    return std.mem.findAny(u8, spec[eq + 1 ..], "\r\n") == null;
}

/// The host fields the fuzzer writes, read back.
pub const host_keys = [_][]const u8{ "X-Forgejo-Project", "X-Forgejo-Ref-Id" };

/// format.md §2: a comment beside fields says so.
pub const comment_marker: trailers.Trailer = .{ .key = "X-Message", .value = "comment" };

/// The message without its trailer block, as content lines.
pub fn textLines(arena: Allocator, message: []const u8) Allocator.Error![]const []const u8 {
    const block = try trailers.parse(arena, message, .{});
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, message, '\n');
    var i: usize = 0;
    while (it.next()) |l| : (i += 1) {
        if (block.first_line) |f| if (i >= f) break;
        try lines.append(arena, l);
    }
    return contentLines(arena, try std.mem.join(arena, "\n", lines.items));
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
    if (a.comment.len > 0) try list.append(arena, comment_marker);
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

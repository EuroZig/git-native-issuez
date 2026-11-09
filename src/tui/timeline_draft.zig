//! The timeline's edit mode: changes staged in a draft, written only when
//! applied. Every change is an op, kept in order for undo and redo; what
//! a draft changes is what its ops add up to against the snapshot, so a
//! bar moved and moved back changes nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const issuez = @import("issuez");
const store = @import("store.zig");

const Id = store.Id;
const Snapshot = store.Snapshot;
const Oid = issuez.engine.Oid;
const Date = issuez.format.fields.Date;
const labels_fmt = issuez.format.labels;
const none = std.math.maxInt(u32);

pub const Link = union(enum) {
    id: Id,
    none,
    inherit,

    fn eql(a: Link, b: Link) bool {
        return switch (a) {
            .none => b == .none,
            .inherit => b == .inherit,
            .id => |x| b == .id and x.eql(b.id.slice()),
        };
    }
};

pub const Op = union(enum) {
    /// The dates an issue ends up with: null leaves one as it is, a null
    /// inside clears it.
    dates: struct { id: Id, start: ?(?Date) = null, due: ?(?Date) = null },
    estimate: struct { id: Id, minutes: ?u32 },
    milestone: struct { id: Id, link: Link },
    add_blocker: struct { id: Id, blocker: Id },
    remove_blocker: struct { id: Id, blocker: Id },
    /// A milestone's due date.
    milestone_due: struct { id: Id, due: ?Date },

    pub fn target(op: *const Op) *const Id {
        return switch (op.*) {
            inline else => |*x| &x.id,
        };
    }
};

/// What a draft does to one issue, against the snapshot. Null parts stay.
pub const IssueChange = struct {
    id: Id,
    start: ?(?Date) = null,
    due: ?(?Date) = null,
    estimate: ?(?u32) = null,
    link: ?Link = null,
    add: []const Id = &.{},
    remove: []const Id = &.{},

    pub fn empty(c: IssueChange) bool {
        return c.start == null and c.due == null and c.estimate == null and c.link == null and
            c.add.len == 0 and c.remove.len == 0;
    }
};

pub const MilestoneChange = struct { id: Id, due: ?Date };

pub const Base = struct { id: Id, tip: ?Oid };

pub const Draft = struct {
    ops: std.ArrayList(Op) = .empty,
    /// Ops after this are undone, for redo.
    len: usize = 0,
    /// The tip of each issue or milestone when first touched: what the
    /// write expects.
    base: std.ArrayList(Base) = .empty,

    pub fn deinit(d: *Draft, gpa: Allocator) void {
        d.ops.deinit(gpa);
        d.base.deinit(gpa);
    }

    pub fn clear(d: *Draft) void {
        d.ops.clearRetainingCapacity();
        d.base.clearRetainingCapacity();
        d.len = 0;
    }

    pub fn active(d: *const Draft) []const Op {
        return d.ops.items[0..d.len];
    }

    pub fn push(d: *Draft, gpa: Allocator, op: Op, tip: ?Oid) Allocator.Error!void {
        d.ops.shrinkRetainingCapacity(d.len);
        const id = op.target();
        if (d.baseOf(id.slice())) |b| {
            // All of it undone: what is there now is what it changes.
            if (!d.touches(id.slice())) b.tip = tip;
        } else try d.base.append(gpa, .{ .id = id.*, .tip = tip });
        try d.ops.append(gpa, op);
        d.len += 1;
    }

    /// Whether an active op changes `id`.
    fn touches(d: *const Draft, id: []const u8) bool {
        for (d.active()) |*op| if (op.target().eql(id)) return true;
        return false;
    }

    pub fn undo(d: *Draft) bool {
        if (d.len == 0) return false;
        d.len -= 1;
        return true;
    }

    pub fn redo(d: *Draft) bool {
        if (d.len == d.ops.items.len) return false;
        d.len += 1;
        return true;
    }

    pub fn baseOf(d: *const Draft, id: []const u8) ?*Base {
        for (d.base.items) |*b| if (b.id.eql(id)) return b;
        return null;
    }

    /// Every op of `id`, gone: "drop mine".
    pub fn drop(d: *Draft, id: []const u8) void {
        var kept: usize = 0;
        var kept_active: usize = 0;
        for (d.ops.items, 0..) |op, n| {
            if (op.target().eql(id)) continue;
            d.ops.items[kept] = op;
            kept += 1;
            if (n < d.len) kept_active += 1;
        }
        d.ops.shrinkRetainingCapacity(kept);
        d.len = kept_active;
        for (d.base.items, 0..) |b, n| if (b.id.eql(id)) {
            _ = d.base.orderedRemove(n);
            break;
        };
    }

    /// The issue's change, ops folded in order: dates and the rest as
    /// last set, blockers as added and removed. Not yet against the
    /// snapshot: see `issueChange`.
    fn fold(
        d: *const Draft,
        arena: Allocator,
        id: []const u8,
        current_blockers: []const []const u8,
    ) Allocator.Error!?IssueChange {
        var out: IssueChange = .{ .id = .of(id) };
        var touched = false;
        var blockers: std.ArrayList([]const u8) = .empty;
        try blockers.appendSlice(arena, current_blockers);
        var blockers_touched = false;
        for (d.active()) |*op| {
            if (!op.target().eql(id)) continue;
            touched = true;
            switch (op.*) {
                .dates => |x| {
                    if (x.start) |v| out.start = v;
                    if (x.due) |v| out.due = v;
                },
                .estimate => |x| out.estimate = x.minutes,
                .milestone => |x| out.link = x.link,
                .add_blocker => |x| {
                    blockers_touched = true;
                    if (!labels_fmt.contains(
                        blockers.items,
                        x.blocker.slice(),
                    )) try blockers.append(
                        arena,
                        try arena.dupe(u8, x.blocker.slice()),
                    );
                },
                .remove_blocker => |x| {
                    blockers_touched = true;
                    for (blockers.items, 0..) |b, n| if (std.mem.eql(u8, b, x.blocker.slice())) {
                        _ = blockers.orderedRemove(n);
                        break;
                    };
                },
                .milestone_due => {},
            }
        }
        if (!touched) return null;
        if (blockers_touched) {
            var add: std.ArrayList(Id) = .empty;
            var remove: std.ArrayList(Id) = .empty;
            for (blockers.items) |b| if (!labels_fmt.contains(current_blockers, b)) try add.append(
                arena,
                .of(b),
            );
            for (current_blockers) |b| if (!labels_fmt.contains(
                blockers.items,
                b,
            )) try remove.append(
                arena,
                .of(b),
            );
            out.add = add.items;
            out.remove = remove.items;
        }
        return out;
    }

    /// What the draft changes on issue `i`, against the snapshot; null
    /// when nothing.
    pub fn issueChange(
        d: *const Draft,
        arena: Allocator,
        snap: *const Snapshot,
        i: u32,
    ) Allocator.Error!?IssueChange {
        const issue = snap.issues[i];
        var c = (try d.fold(arena, issue.id, issue.blocked_by)) orelse return null;
        if (c.start) |v| if (optEql(v, issue.start_date)) {
            c.start = null;
        };
        if (c.due) |v| if (optEql(v, issue.due_date)) {
            c.due = null;
        };
        if (c.estimate) |v| if (v == issue.estimate_minutes) {
            c.estimate = null;
        };
        if (c.link) |l| if (l.eql(currentLink(snap, i))) {
            c.link = null;
        };
        return if (c.empty()) null else c;
    }

    pub fn milestoneDue(d: *const Draft, id: []const u8) ??Date {
        var out: ??Date = null;
        for (d.active()) |op| switch (op) {
            .milestone_due => |x| if (x.id.eql(id)) {
                out = x.due;
            },
            else => {},
        };
        return out;
    }

    /// Everything the draft changes, against the snapshot.
    pub const Plan = struct {
        issues: []const IssueChange,
        milestones: []const MilestoneChange,
        /// Touched issues or milestones that changed elsewhere since.
        stale: []const Id,
        /// Touched ones that are gone.
        gone: []const Id,
        /// Issues whose dates the draft changes, starting after their due
        /// date once applied over what is there now.
        inverted: []const Id,
        /// Issues the draft makes wait on an issue, or moves into a
        /// milestone, that is gone or closed elsewhere since.
        dangling: []const Id = &.{},
        /// Issues the draft makes wait on themselves, through blockers.
        loops: []const Id = &.{},

        pub fn count(p: Plan) usize {
            return p.issues.len + p.milestones.len;
        }
    };

    pub fn plan(d: *const Draft, arena: Allocator, snap: *const Snapshot) Allocator.Error!Plan {
        var issues: std.ArrayList(IssueChange) = .empty;
        var milestones: std.ArrayList(MilestoneChange) = .empty;
        var stale: std.ArrayList(Id) = .empty;
        var gone: std.ArrayList(Id) = .empty;
        var inverted: std.ArrayList(Id) = .empty;
        for (d.base.items) |b| {
            const id = b.id.slice();
            if (snap.find(id)) |i| {
                if (snap.issues[i].deleted) {
                    try gone.append(arena, b.id);
                    continue;
                }
                const c = (try d.issueChange(arena, snap, i)) orelse continue;
                try issues.append(arena, c);
                if (c.start != null or c.due != null) {
                    const ext = &snap.issues[i];
                    const start = if (c.start) |v| v else ext.start_date;
                    const due = if (c.due) |v| v else ext.due_date;
                    if (start != null and due != null and start.?.order(
                        due.?,
                    ) == .gt) try inverted.append(
                        arena,
                        b.id,
                    );
                }
                if (!tipEql(b.tip, snap.issues[i].tip)) try stale.append(arena, b.id);
            } else if (snap.findMilestone(id)) |n| {
                const m = snap.milestones[n];
                const due = d.milestoneDue(id) orelse continue;
                if (optEql(due, m.due)) continue;
                try milestones.append(arena, .{ .id = b.id, .due = due });
                if (!tipEql(b.tip, m.tip)) try stale.append(arena, b.id);
            } else try gone.append(arena, b.id);
        }
        var dangling: std.ArrayList(Id) = .empty;
        for (issues.items) |c| {
            const blocker_gone = for (c.add) |b| {
                const i = snap.find(b.slice()) orelse break true;
                if (snap.issues[i].deleted) break true;
            } else false;
            const milestone_gone = if (c.link) |l| switch (l) {
                .id => |m| if (snap.findMilestone(
                    m.slice(),
                )) |n| snap.milestones[n].status != .open else true,
                else => false,
            } else false;
            if (blocker_gone or milestone_gone) try dangling.append(arena, c.id);
        }
        return .{
            .issues = issues.items,
            .milestones = milestones.items,
            .stale = stale.items,
            .gone = gone.items,
            .inverted = inverted.items,
            .dangling = dangling.items,
            .loops = try loops(arena, snap, issues.items),
        };
    }

    /// The changed issues that would wait on themselves: blockers as the
    /// snapshot has them, with the changes' added and removed.
    fn loops(
        arena: Allocator,
        snap: *const Snapshot,
        changes: []const IssueChange,
    ) Allocator.Error![]const Id {
        const Graph = struct {
            snap: *const Snapshot,
            changes: []const IssueChange,

            fn blockers(g: @This(), arena_: Allocator, i: u32) Allocator.Error![]const []const u8 {
                const current = g.snap.issues[i].blocked_by;
                const c = for (g.changes) |*c| {
                    if (c.id.eql(g.snap.issues[i].id)) break c;
                } else return current;
                if (c.add.len == 0 and c.remove.len == 0) return current;
                var out: std.ArrayList([]const u8) = .empty;
                for (current) |b| {
                    const removed = for (c.remove) |r| {
                        if (r.eql(b)) break true;
                    } else false;
                    if (!removed) try out.append(arena_, b);
                }
                for (c.add) |*b| try out.append(arena_, b.slice());
                return out.items;
            }
        };
        const g: Graph = .{ .snap = snap, .changes = changes };
        var out: std.ArrayList(Id) = .empty;
        const seen = try arena.alloc(bool, snap.issues.len);
        var stack: std.ArrayList(u32) = .empty;
        // Only an added blocker can close a loop.
        for (changes) |c| {
            if (c.add.len == 0) continue;
            const start = snap.find(c.id.slice()) orelse continue;
            @memset(seen, false);
            stack.clearRetainingCapacity();
            try stack.append(arena, start);
            const looped = search: while (stack.pop()) |i| {
                for (try g.blockers(arena, i)) |b| {
                    const j = snap.find(b) orelse continue;
                    if (j == start) break :search true;
                    if (seen[j]) continue;
                    seen[j] = true;
                    try stack.append(arena, j);
                }
            } else false;
            if (looped) try out.append(arena, c.id);
        }
        return out.items;
    }

    /// After the user chose to keep their change: it now applies over
    /// what is there.
    pub fn rebase(d: *Draft, snap: *const Snapshot, id: []const u8) void {
        const b = d.baseOf(id) orelse return;
        if (snap.find(
            id,
        )) |i| b.tip = snap.issues[i].tip else if (snap.findMilestone(
            id,
        )) |n| b.tip = snap.milestones[n].tip;
    }
};

fn optEql(a: ?Date, b: ?Date) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

fn tipEql(a: ?Oid, b: ?Oid) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

/// How the issue gets its milestone now, as a draft link.
pub fn currentLink(snap: *const Snapshot, i: u32) Link {
    const ext = &snap.issues[i];
    const mode = issuez.format.fields.MilestoneMode.of(
        ext.milestone_mode,
        .{ .has_id = ext.milestone_id != null, .has_parent = snap.proj.parent[i] != none },
    );
    return switch (mode) {
        .explicit => if (ext.milestone_id) |m| .{ .id = .of(m) } else .none,
        .inherit => .inherit,
        .none => .none,
    };
}

/// Each issue's effective milestone with the draft's links: a link of its
/// own, else its parent's, as the projection walks it.
pub fn effectiveMilestones(
    arena: Allocator,
    d: *const Draft,
    snap: *const Snapshot,
) Allocator.Error![]const ?[]const u8 {
    const n = snap.issues.len;
    const out = try arena.alloc(?[]const u8, n);
    const state = try arena.alloc(enum(u2) { todo, busy, done }, n);
    @memset(state, .todo);
    var links = try arena.alloc(?Link, n);
    @memset(links, null);
    var any = false;
    for (d.active()) |op| switch (op) {
        .milestone => |x| if (snap.find(x.id.slice())) |i| {
            links[i] = x.link;
            any = true;
        },
        else => {},
    };
    if (!any) {
        @memcpy(out, snap.proj.milestone);
        return out;
    }
    for (0..n) |start| {
        if (state[start] == .done) continue;
        // Walk up until something is known, then fill in on the way down.
        var chain: std.ArrayList(u32) = .empty;
        var cur: u32 = @intCast(start);
        const resolved: ?[]const u8 = while (true) {
            if (state[cur] == .done) break out[cur];
            if (state[cur] == .busy) break null; // a loop: none
            state[cur] = .busy;
            try chain.append(arena, cur);
            const own: ?Link = links[cur] orelse switch (currentLink(snap, cur)) {
                .inherit => .inherit,
                else => null,
            };
            if (own) |l| switch (l) {
                .id => |id| {
                    const m = snap.findMilestone(id.slice()) orelse break null;
                    const ms = snap.milestones[m];
                    break if (ms.status == .retired) null else ms.id;
                },
                .none => break null,
                .inherit => {
                    const p = snap.proj.parent[cur];
                    if (p == none) break null;
                    cur = p;
                    continue;
                },
            };
            // Its own explicit link or none: what the projection says.
            break snap.proj.milestone[cur];
        };
        for (chain.items) |c| {
            out[c] = resolved;
            state[c] = .done;
        }
    }
    return out;
}

// Tests run on a snapshot built from the simulator.

const testing = std.testing;
const GitSim = issuez.backend.GitSim;

test "a draft adds up its ops, undoes and redoes them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .clones = &.{.{ .name = "local" }} };
    var sim = try GitSim.init(arena, &world, 0);
    var st: store.Store(GitSim) = .init(testing.allocator, &sim);
    defer st.deinit();
    try st.reload();
    const a = try st.create(.{ .title = "A" });
    const b = try st.create(.{ .title = "B" });
    try st.edit(
        a.slice(),
        .{
            .start_date = .{ .set = issuez.format.fields.Date.parse("2026-11-02").? },
            .due_date = .{ .set = issuez.format.fields.Date.parse("2026-11-06").? },
        },
    );
    const v1 = try st.createMilestone(.{ .name = "v1", .due = .parse("2026-12-01") });
    const snap = &st.snap;
    const ia = snap.find(a.slice()).?;

    var d: Draft = .{};
    defer d.deinit(testing.allocator);
    const D = Date.parse;
    try d.push(
        testing.allocator,
        .{ .dates = .{ .id = a, .start = D("2026-11-03"), .due = D("2026-11-07") } },
        snap.issues[ia].tip,
    );
    try d.push(testing.allocator, .{ .add_blocker = .{ .id = a, .blocker = b } }, null);
    try d.push(
        testing.allocator,
        .{ .milestone_due = .{ .id = v1, .due = D("2026-12-08") } },
        snap.milestones[0].tip,
    );
    var p = try d.plan(arena, snap);
    try testing.expectEqual(@as(usize, 2), p.count());
    try testing.expect(p.issues[0].start.?.?.eql(D("2026-11-03").?));
    try testing.expectEqual(@as(usize, 1), p.issues[0].add.len);
    try testing.expectEqual(@as(usize, 0), p.stale.len);

    // Moved back: no date change left, the blocker stays.
    try d.push(
        testing.allocator,
        .{ .dates = .{ .id = a, .start = D("2026-11-02"), .due = D("2026-11-06") } },
        null,
    );
    p = try d.plan(arena, snap);
    try testing.expect(p.issues[0].start == null and p.issues[0].due == null);
    // Undo the move back, then the milestone: one change.
    try testing.expect(d.undo());
    try testing.expect(d.redo());
    try testing.expect(d.undo());
    try testing.expect(d.undo());
    try testing.expectEqual(@as(usize, 1), (try d.plan(arena, snap)).count());
    // A new op drops what could be redone.
    try d.push(testing.allocator, .{ .remove_blocker = .{ .id = a, .blocker = b } }, null);
    try testing.expect(!d.redo());
    p = try d.plan(arena, snap);
    try testing.expect(p.issues[0].add.len == 0 and p.issues[0].remove.len == 0);
    try testing.expect(p.issues[0].due.?.?.eql(D("2026-11-07").?));

    // Changed elsewhere: stale until rebased.
    try st.edit(a.slice(), .{ .title = "A, renamed" });
    p = try d.plan(arena, &st.snap);
    try testing.expectEqual(@as(usize, 1), p.stale.len);
    d.rebase(&st.snap, a.slice());
    try testing.expectEqual(@as(usize, 0), (try d.plan(arena, &st.snap)).stale.len);
    d.drop(a.slice());
    try testing.expectEqual(@as(usize, 0), (try d.plan(arena, &st.snap)).count());
}

test "effective milestones with a draft's links" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .clones = &.{.{ .name = "local" }} };
    var sim = try GitSim.init(arena, &world, 0);
    var st: store.Store(GitSim) = .init(testing.allocator, &sim);
    defer st.deinit();
    try st.reload();
    const v1 = try st.createMilestone(.{ .name = "v1" });
    const v2 = try st.createMilestone(.{ .name = "v2" });
    const p = try st.create(.{ .title = "P", .milestone_id = v1.slice() });
    const c = try st.create(.{ .title = "C", .parent = p.slice() });
    var d: Draft = .{};
    defer d.deinit(testing.allocator);
    try d.push(testing.allocator, .{ .milestone = .{ .id = p, .link = .{ .id = v2 } } }, null);
    const eff = try effectiveMilestones(arena, &d, &st.snap);
    try testing.expectEqualStrings(v2.slice(), eff[st.snap.find(c.slice()).?].?);
    try d.push(testing.allocator, .{ .milestone = .{ .id = c, .link = .none } }, null);
    const eff2 = try effectiveMilestones(arena, &d, &st.snap);
    try testing.expect(eff2[st.snap.find(c.slice()).?] == null);
    try testing.expectEqualStrings(v2.slice(), eff2[st.snap.find(p.slice()).?].?);
}

test "a date change keeps the other date as it is there now" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .clones = &.{.{ .name = "local" }} };
    var sim = try GitSim.init(arena, &world, 0);
    var st: store.Store(GitSim) = .init(testing.allocator, &sim);
    defer st.deinit();
    try st.reload();
    const a = try st.create(.{ .title = "A" });
    try st.edit(
        a.slice(),
        .{
            .start_date = .{ .set = issuez.format.fields.Date.parse("2026-11-02").? },
            .due_date = .{ .set = issuez.format.fields.Date.parse("2026-11-06").? },
        },
    );
    const D = Date.parse;
    const ia = st.snap.find(a.slice()).?;

    var d: Draft = .{};
    defer d.deinit(testing.allocator);
    // The user moves the start only.
    try d.push(
        testing.allocator,
        .{ .dates = .{ .id = a, .start = D("2026-11-03") } },
        st.snap.issues[ia].tip,
    );
    // Someone else moves the due date; the user keeps theirs.
    try st.edit(
        a.slice(),
        .{ .due_date = .{ .set = issuez.format.fields.Date.parse("2026-11-20").? } },
    );
    try testing.expectEqual(@as(usize, 1), (try d.plan(arena, &st.snap)).stale.len);
    d.rebase(&st.snap, a.slice());
    var p = try d.plan(arena, &st.snap);
    try testing.expectEqual(@as(usize, 1), p.issues.len);
    try testing.expect(p.issues[0].start.?.?.eql(D("2026-11-03").?));
    // Their due date stays.
    try testing.expect(p.issues[0].due == null);
    try testing.expectEqual(@as(usize, 0), p.inverted.len);

    // Their due date moved before the user's start: refused when applied.
    try st.edit(
        a.slice(),
        .{ .due_date = .{ .set = issuez.format.fields.Date.parse("2026-11-01").? } },
    );
    d.rebase(&st.snap, a.slice());
    p = try d.plan(arena, &st.snap);
    try testing.expectEqual(@as(usize, 1), p.inverted.len);
}

test "staged again after undoing all, an issue expects what is there now" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .clones = &.{.{ .name = "local" }} };
    var sim = try GitSim.init(arena, &world, 0);
    var st: store.Store(GitSim) = .init(testing.allocator, &sim);
    defer st.deinit();
    try st.reload();
    const a = try st.create(.{ .title = "A" });
    const D = Date.parse;
    var d: Draft = .{};
    defer d.deinit(testing.allocator);
    try d.push(
        testing.allocator,
        .{ .dates = .{ .id = a, .due = D("2026-11-03") } },
        st.snap.issues[st.snap.find(a.slice()).?].tip,
    );
    try testing.expect(d.undo());
    try st.edit(a.slice(), .{ .title = "A, renamed" });
    try d.push(
        testing.allocator,
        .{ .dates = .{ .id = a, .due = D("2026-11-04") } },
        st.snap.issues[st.snap.find(a.slice()).?].tip,
    );
    try testing.expectEqual(@as(usize, 0), (try d.plan(arena, &st.snap)).stale.len);
}

test "plan: what a draft points at gone or closed elsewhere, and blocker loops" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .clones = &.{.{ .name = "local" }} };
    var sim = try GitSim.init(arena, &world, 0);
    var st: store.Store(GitSim) = .init(testing.allocator, &sim);
    defer st.deinit();
    try st.reload();
    const a = try st.create(.{ .title = "A" });
    const b = try st.create(.{ .title = "B" });
    const c = try st.create(.{ .title = "C" });
    // B waits on A already.
    try st.edit(b.slice(), .{ .add_blocked_by = &.{a.slice()} });
    const v1 = try st.createMilestone(.{ .name = "v1" });
    const tip = struct {
        fn of(sn: *const Snapshot, id: Id) ?Oid {
            return sn.issues[sn.find(id.slice()).?].tip;
        }
    }.of;

    var d: Draft = .{};
    defer d.deinit(testing.allocator);
    // A waits on C, and C on B: A → C → B → A.
    try d.push(testing.allocator, .{ .add_blocker = .{ .id = a, .blocker = c } }, tip(&st.snap, a));
    var p = try d.plan(arena, &st.snap);
    try testing.expectEqual(@as(usize, 0), p.loops.len);
    try d.push(testing.allocator, .{ .add_blocker = .{ .id = c, .blocker = b } }, tip(&st.snap, c));
    p = try d.plan(arena, &st.snap);
    try testing.expectEqual(@as(usize, 2), p.loops.len);
    // Dropping C's changes ends it.
    d.drop(c.slice());
    p = try d.plan(arena, &st.snap);
    try testing.expectEqual(@as(usize, 0), p.loops.len);
    // So does removing the snapshot's B → A in the draft.
    try d.push(testing.allocator, .{ .add_blocker = .{ .id = c, .blocker = b } }, tip(&st.snap, c));
    try d.push(
        testing.allocator,
        .{ .remove_blocker = .{ .id = b, .blocker = a } },
        tip(&st.snap, b),
    );
    p = try d.plan(arena, &st.snap);
    try testing.expectEqual(@as(usize, 0), p.loops.len);

    // A blocker that is gone, and a milestone retired since.
    d.clear();
    const gone: Id = .of("ffffffff-ffff-4fff-bfff-ffffffffffff");
    try d.push(
        testing.allocator,
        .{ .add_blocker = .{ .id = a, .blocker = gone } },
        tip(&st.snap, a),
    );
    try d.push(
        testing.allocator,
        .{ .milestone = .{ .id = b, .link = .{ .id = v1 } } },
        tip(&st.snap, b),
    );
    p = try d.plan(arena, &st.snap);
    try testing.expectEqual(@as(usize, 1), p.dangling.len);
    try testing.expect(p.dangling[0].eql(a.slice()));
    try st.editMilestone(v1.slice(), .{ .status = .retired });
    p = try d.plan(arena, &st.snap);
    try testing.expectEqual(@as(usize, 2), p.dangling.len);
}

test "effective milestones with a parent loop" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .clones = &.{.{ .name = "local" }} };
    var sim = try GitSim.init(arena, &world, 0);
    var st: store.Store(GitSim) = .init(testing.allocator, &sim);
    defer st.deinit();
    try st.reload();
    const v1 = try st.createMilestone(.{ .name = "v1" });
    const p = try st.create(.{ .title = "P" });
    const c = try st.create(.{ .title = "C", .parent = p.slice() });
    // The projection cuts loops; one made by hand must not hang.
    var snap = st.snap;
    const ip = snap.find(p.slice()).?;
    const ic = snap.find(c.slice()).?;
    const parent = try arena.dupe(u32, snap.proj.parent);
    parent[ip] = ic;
    snap.proj.parent = parent;
    var d: Draft = .{};
    defer d.deinit(testing.allocator);
    try d.push(testing.allocator, .{ .milestone = .{ .id = p, .link = .inherit } }, null);
    try d.push(testing.allocator, .{ .milestone = .{ .id = c, .link = .inherit } }, null);
    const eff = try effectiveMilestones(arena, &d, &snap);
    try testing.expect(eff[ip] == null);
    try testing.expect(eff[ic] == null);
    // One of them in v1: the other inherits it.
    try d.push(testing.allocator, .{ .milestone = .{ .id = p, .link = .{ .id = v1 } } }, null);
    const eff2 = try effectiveMilestones(arena, &d, &snap);
    try testing.expectEqualStrings(v1.slice(), eff2[ip].?);
    try testing.expectEqualStrings(v1.slice(), eff2[ic].?);
}

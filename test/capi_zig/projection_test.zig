//! Projections: tree, blockers, progress, milestones, problems.

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

/// E (in M) > C1 > G, E > C2 (closed); X blocked by B1 (open) and B2
/// (closed); O with a parent that isn't there; P and Q each other's parent.
const Tree = struct {
    r: fixture.Repo,
    m: fixture.Created,
    e: fixture.Created,
    c1: fixture.Created,
    c2: fixture.Created,
    g: fixture.Created,
    x: fixture.Created,
    b1: fixture.Created,
    b2: fixture.Created,
    o: fixture.Created,
    p: fixture.Created,

    fn init(t: *Tree) !void {
        try t.r.init(.{});
        errdefer t.r.deinit();
        const h = t.r.handle;
        t.m = try fixture.milestone(h, "M");
        t.e = try fixture.create(
            h,
            &.{ c.issuez_set_title(fixture.str("E")), c.issuez_set_milestone(t.m.idStr()) },
        );
        t.c1 = try fixture.create(
            h,
            &.{
                c.issuez_set_title(fixture.str("C1")),
                c.issuez_set_parent(t.e.idStr()),
                c.issuez_inherit_milestone(),
            },
        );
        t.g = try fixture.create(
            h,
            &.{
                c.issuez_set_title(fixture.str("G")),
                c.issuez_set_parent(t.c1.idStr()),
                c.issuez_inherit_milestone(),
            },
        );
        t.c2 = try fixture.create(
            h,
            &.{
                c.issuez_set_title(fixture.str("C2")),
                c.issuez_set_parent(t.e.idStr()),
                c.issuez_inherit_milestone(),
                c.issuez_set_state(fixture.str("closed")),
            },
        );
        t.b1 = try fixture.titled(h, "B1");
        t.b2 = try fixture.create(
            h,
            &.{ c.issuez_set_title(fixture.str("B2")), c.issuez_set_state(fixture.str("closed")) },
        );
        t.x = try fixture.create(
            h,
            &.{
                c.issuez_set_title(fixture.str("X")),
                c.issuez_add_blocker(t.b1.idStr()),
                c.issuez_add_blocker(t.b2.idStr()),
            },
        );
        t.o = try fixture.titled(h, "O");
        try fixture.foreignCommit(
            &t.r,
            t.o.idSlice(),
            "Parent\n\nX-Parent: 0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c",
        );
        t.p = try fixture.titled(h, "P");
        const q = try fixture.titled(h, "Q");
        const p_parent = try std.fmt.allocPrint(
            t.r.arena(),
            "Parent\n\nX-Parent: {s}",
            .{q.idSlice()},
        );
        const q_parent = try std.fmt.allocPrint(
            t.r.arena(),
            "Parent\n\nX-Parent: {s}",
            .{t.p.idSlice()},
        );
        try fixture.foreignCommit(&t.r, t.p.idSlice(), p_parent);
        try fixture.foreignCommit(&t.r, q.idSlice(), q_parent);
    }

    fn deinit(t: *Tree) void {
        t.r.deinit();
    }

    fn build(t: *Tree) !*c.issuez_projection {
        var p: ?*c.issuez_projection = null;
        var err: ?*c.issuez_error = null;
        try expect.code(c.ISSUEZ_OK, c.issuez_projection_build(t.r.handle, null, &p, &err), err);
        return p.?;
    }
};

fn hasRoot(p: *c.issuez_projection, want: []const u8) bool {
    for (0..c.issuez_projection_root_count(p)) |k| {
        if (std.mem.eql(u8, fixture.slice(c.issuez_projection_root_at(p, k)), want)) return true;
    }
    return false;
}

fn hasChild(p: *c.issuez_projection, id: c.issuez_str, want: []const u8) bool {
    for (0..c.issuez_projection_child_count(p, id)) |k| {
        if (std.mem.eql(
            u8,
            fixture.slice(c.issuez_projection_child_at(p, id, k)),
            want,
        )) return true;
    }
    return false;
}

test "issuez_projection_build, issuez_projection_free, issuez_projection_issues: the whole repo" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    const p = try t.build();
    const list = c.issuez_projection_issues(p);
    try testing.expectEqual(@as(usize, 10), c.issuez_issue_list_len(list));
    // It outlives later writes.
    _ = try fixture.titled(t.r.handle, "Later");
    try testing.expectEqual(@as(usize, 10), c.issuez_issue_list_len(list));
    try expect.terminated(c.issuez_issue_title(c.issuez_issue_list_at(list, 0)));
    c.issuez_projection_free(p);
    c.issuez_projection_free(null);
    try testing.expect(c.issuez_projection_issues(null) == null);
}

// covers: issuez_projection_root_at, issuez_projection_child_count, issuez_projection_child_at
test "issuez_projection_root_count: the tree" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    const p = try t.build();
    defer c.issuez_projection_free(p);
    try testing.expect(hasRoot(p, t.e.idSlice()));
    // A missing parent makes a root.
    try testing.expect(hasRoot(p, t.o.idSlice()));
    try testing.expect(!hasRoot(p, t.g.idSlice()));
    try testing.expectEqual(@as(usize, 2), c.issuez_projection_child_count(p, t.e.idStr()));
    try testing.expect(hasChild(p, t.e.idStr(), t.c2.idSlice()));
    try expect.str(t.g.idSlice(), c.issuez_projection_child_at(p, t.c1.idStr(), 0));
    try expect.str("", c.issuez_projection_child_at(p, t.c1.idStr(), 1));
    try testing.expectEqual(@as(usize, 0), c.issuez_projection_child_count(p, t.g.idStr()));
    try testing.expectEqual(@as(usize, 0), c.issuez_projection_child_count(p, fixture.str("nope")));
    try expect.str("", c.issuez_projection_root_at(p, 999));
}

// covers: issuez_projection_active_blocker_at, issuez_projection_blocking_count
// covers: issuez_projection_blocking_at
test "issuez_projection_active_blocker_count: open blockers only" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    const p = try t.build();
    defer c.issuez_projection_free(p);
    try testing.expectEqual(
        @as(usize, 1),
        c.issuez_projection_active_blocker_count(p, t.x.idStr()),
    );
    try expect.str(t.b1.idSlice(), c.issuez_projection_active_blocker_at(p, t.x.idStr(), 0));
    try expect.str("", c.issuez_projection_active_blocker_at(p, t.x.idStr(), 1));
    try testing.expectEqual(@as(usize, 1), c.issuez_projection_blocking_count(p, t.b1.idStr()));
    try expect.str(t.x.idSlice(), c.issuez_projection_blocking_at(p, t.b1.idStr(), 0));
    try testing.expectEqual(@as(usize, 1), c.issuez_projection_blocking_count(p, t.b2.idStr()));
    try testing.expectEqual(
        @as(usize, 0),
        c.issuez_projection_active_blocker_count(p, t.e.idStr()),
    );
}

// covers: issuez_projection_milestone_of, issuez_projection_milestone_progress
test "issuez_projection_progress: leaves and milestones" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    const p = try t.build();
    defer c.issuez_projection_free(p);
    var pr: c.issuez_progress = undefined;
    try testing.expect(c.issuez_projection_progress(p, t.e.idStr(), &pr));
    try testing.expectEqual(@as(u32, 1), pr.done);
    try testing.expectEqual(@as(u32, 2), pr.total);
    try testing.expect(c.issuez_projection_progress(p, t.c1.idStr(), &pr));
    try testing.expectEqual(@as(u32, 0), pr.done);
    try testing.expect(!c.issuez_projection_progress(p, t.g.idStr(), &pr));
    try expect.str(t.m.idSlice(), c.issuez_projection_milestone_of(p, t.e.idStr()));
    try expect.str(t.m.idSlice(), c.issuez_projection_milestone_of(p, t.g.idStr()));
    try expect.str("", c.issuez_projection_milestone_of(p, t.x.idStr()));
    const mp = c.issuez_projection_milestone_progress(p, t.m.idStr());
    try testing.expectEqual(@as(u32, 1), mp.done);
    try testing.expectEqual(@as(u32, 2), mp.total);
    const none = c.issuez_projection_milestone_progress(p, fixture.str("nope"));
    try testing.expectEqual(@as(u32, 0), none.total);
}

test "issuez_projection_problems: per issue and for all" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    const p = try t.build();
    defer c.issuez_projection_free(p);
    const all = c.issuez_projection_problems(p, .{});
    try testing.expect(c.issuez_problems_len(all) >= 2);
    const oid = t.o.idStr();
    const of_o = c.issuez_projection_problems(p, oid);
    try testing.expectEqual(@as(usize, 1), c.issuez_problems_len(of_o));
    try testing.expectEqual(
        @as(u32, c.ISSUEZ_PROBLEM_MISSING_TARGET),
        c.issuez_problems_at(of_o, 0).*.kind,
    );
    const pid = t.p.idStr();
    const of_p = c.issuez_projection_problems(p, pid);
    try testing.expectEqual(@as(u32, c.ISSUEZ_PROBLEM_CYCLE), c.issuez_problems_at(of_p, 0).*.kind);
    const eid = t.e.idStr();
    try testing.expectEqual(
        @as(usize, 0),
        c.issuez_problems_len(c.issuez_projection_problems(p, eid)),
    );
}

test "issuez_projection_around: what one issue's answers need" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    var p: ?*c.issuez_projection = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_projection_around(t.r.handle, t.g.idStr(), null, &p, null),
        null,
    );
    const list = c.issuez_projection_issues(p);
    // G, its ancestors, and what their answers need; not the unrelated ones.
    try testing.expect(c.issuez_issue_list_len(list) < 10);
    try expect.str(t.m.idSlice(), c.issuez_projection_milestone_of(p, t.g.idStr()));
    try expect.str(t.g.idSlice(), c.issuez_projection_child_at(p, t.c1.idStr(), 0));
    c.issuez_projection_free(p);
    var err: ?*c.issuez_error = null;
    p = null;
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        c.issuez_projection_around(
            t.r.handle,
            fixture.str("0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c"),
            null,
            &p,
            &err,
        ),
        err,
    );
    try testing.expect(p == null);
    c.issuez_error_free(err);
}

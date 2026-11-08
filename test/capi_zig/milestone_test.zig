//! Milestones.

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

fn create(h: *c.issuez_repo, ops: []const c.issuez_op) !fixture.Created {
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_milestone_create(h, ops.ptr, ops.len, &fixture.ada, null, &w, &err),
        err,
    );
    defer c.issuez_write_free(w);
    var out: fixture.Created = .{ .id = @splat(0), .tip = c.issuez_write_new_tip(w) };
    @memcpy(out.id[0..36], fixture.slice(c.issuez_write_id(w)));
    return out;
}

fn update(h: *c.issuez_repo, id: c.issuez_str, ops: []const c.issuez_op) c.issuez_code {
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    const rc = c.issuez_milestone_update(h, id, ops.ptr, ops.len, &fixture.ada, null, &w, &err);
    c.issuez_write_free(w);
    c.issuez_error_free(err);
    return rc;
}

fn load(h: *c.issuez_repo, id: c.issuez_str) !*c.issuez_milestone {
    var m: ?*c.issuez_milestone = null;
    var err: ?*c.issuez_error = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_milestone_load(h, id, null, &m, &err), err);
    return m.?;
}

// covers: issuez_milestone_load, issuez_milestone_free, issuez_milestone_id, issuez_milestone_tip
// covers: issuez_milestone_name, issuez_milestone_description, issuez_milestone_status_of
// covers: issuez_milestone_due_date, issuez_milestone_created
test "issuez_milestone_create: every field" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const full = try create(h, &.{
        c.issuez_set_name(fixture.str("v1.0")),
        c.issuez_set_description(fixture.str("The first release.")),
        c.issuez_set_due_date(.{ .year = 2026, .month = 12, .day = 24 }),
    });
    const m = try load(h, full.idStr());
    try expect.str(full.idSlice(), c.issuez_milestone_id(m));
    const tip = c.issuez_milestone_tip(m);
    try testing.expect(c.issuez_oid_eq(&tip, &full.tip));
    try expect.str("v1.0", c.issuez_milestone_name(m));
    try expect.str("The first release.", c.issuez_milestone_description(m));
    try testing.expectEqual(
        @as(c.issuez_milestone_status, c.ISSUEZ_MILESTONE_OPEN),
        c.issuez_milestone_status_of(m),
    );
    var d: c.issuez_date = undefined;
    try testing.expect(c.issuez_milestone_due_date(m, &d));
    try testing.expectEqual(@as(c_int, 24), @as(c_int, d.day));
    try testing.expect(c.issuez_milestone_created(m).unix_seconds > 1_600_000_000);
    c.issuez_milestone_free(m);

    // Imported completed; minimal.
    const done = try create(
        h,
        &.{
            c.issuez_set_name(fixture.str("v0.9")),
            c.issuez_set_milestone_status(c.ISSUEZ_MILESTONE_COMPLETED),
        },
    );
    const dm = try load(h, done.idStr());
    try testing.expectEqual(
        @as(c.issuez_milestone_status, c.ISSUEZ_MILESTONE_COMPLETED),
        c.issuez_milestone_status_of(dm),
    );
    try testing.expect(!c.issuez_milestone_due_date(dm, &d));
    try expect.str("", c.issuez_milestone_description(dm));
    c.issuez_milestone_free(dm);
    c.issuez_milestone_free(null);

    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    const nameless = [_]c.issuez_op{c.issuez_set_description(fixture.str("x"))};
    try expect.code(
        c.ISSUEZ_E_INVALID_VALUE,
        c.issuez_milestone_create(h, &nameless, 1, &fixture.ada, null, &w, &err),
        err,
    );
    c.issuez_error_free(err);
    err = null;
    const missing = fixture.str("0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c");
    var out: ?*c.issuez_milestone = null;
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        c.issuez_milestone_load(h, missing, null, &out, &err),
        err,
    );
    c.issuez_error_free(err);
    try expect.str("", c.issuez_milestone_name(null));
}

// covers: issuez_milestone_list_len, issuez_milestone_list_at, issuez_milestone_list_free
test "issuez_milestone_list_all: none, several" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    var list: ?*c.issuez_milestone_list = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_milestone_list_all(h, null, &list, null), null);
    try testing.expectEqual(@as(usize, 0), c.issuez_milestone_list_len(list));
    c.issuez_milestone_list_free(list);
    _ = try fixture.milestone(h, "b");
    _ = try fixture.milestone(h, "a");
    _ = try fixture.milestone(h, "c");
    try expect.code(c.ISSUEZ_OK, c.issuez_milestone_list_all(h, null, &list, null), null);
    try testing.expectEqual(@as(usize, 3), c.issuez_milestone_list_len(list));
    var names: [3][]const u8 = undefined;
    for (&names, 0..) |*n, i| n.* = fixture.slice(
        c.issuez_milestone_name(c.issuez_milestone_list_at(list, i)),
    );
    std.mem.sort([]const u8, &names, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    try testing.expectEqualStrings("a", names[0]);
    try testing.expectEqualStrings("c", names[2]);
    try testing.expect(c.issuez_milestone_list_at(list, 3) == null);
    c.issuez_milestone_list_free(list);
    c.issuez_milestone_list_free(null);
    try testing.expectEqual(@as(usize, 0), c.issuez_milestone_list_len(null));
}

test "issuez_milestone_update: rename, due, status, stale" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const made = try fixture.milestone(h, "Spring");
    const id = made.idStr();
    try expect.code(
        c.ISSUEZ_OK,
        update(
            h,
            id,
            &.{
                c.issuez_set_name(fixture.str("Summer")),
                c.issuez_set_due_date(.{ .year = 2027, .month = 6, .day = 1 }),
            },
        ),
        null,
    );
    var m = try load(h, id);
    try expect.str("Summer", c.issuez_milestone_name(m));
    c.issuez_milestone_free(m);
    try expect.code(c.ISSUEZ_OK, update(h, id, &.{c.issuez_clear_due_date()}), null);
    try expect.code(
        c.ISSUEZ_OK,
        update(h, id, &.{c.issuez_set_milestone_status(c.ISSUEZ_MILESTONE_RETIRED)}),
        null,
    );
    m = try load(h, id);
    var d: c.issuez_date = undefined;
    try testing.expect(!c.issuez_milestone_due_date(m, &d));
    try testing.expectEqual(
        @as(c.issuez_milestone_status, c.ISSUEZ_MILESTONE_RETIRED),
        c.issuez_milestone_status_of(m),
    );
    c.issuez_milestone_free(m);
    try expect.code(
        c.ISSUEZ_OK,
        update(h, id, &.{c.issuez_set_milestone_status(c.ISSUEZ_MILESTONE_OPEN)}),
        null,
    );
    try expect.code(
        c.ISSUEZ_E_VERSION_MISMATCH,
        update(h, id, &.{ c.issuez_set_name(fixture.str("Autumn")), c.issuez_expect(made.tip) }),
        null,
    );
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        update(
            h,
            fixture.str("0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c"),
            &.{c.issuez_set_name(fixture.str("x"))},
        ),
        null,
    );
}

test "issuez_milestone_check: valid, completing with open work, nothing written" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const m = try fixture.milestone(h, "Busy");
    _ = try fixture.create(
        h,
        &.{ c.issuez_set_title(fixture.str("Work")), c.issuez_set_milestone(m.idStr()) },
    );
    const id = m.idStr();
    var ps: ?*c.issuez_problems = null;
    var err: ?*c.issuez_error = null;
    const rename = [_]c.issuez_op{c.issuez_set_name(fixture.str("Renamed"))};
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_milestone_check(h, id, &rename, 1, null, &ps, &err),
        err,
    );
    try testing.expectEqual(@as(usize, 0), c.issuez_problems_len(ps));
    c.issuez_problems_free(ps);
    const complete = [_]c.issuez_op{c.issuez_set_milestone_status(c.ISSUEZ_MILESTONE_COMPLETED)};
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_milestone_check(h, id, &complete, 1, null, &ps, &err),
        err,
    );
    try testing.expectEqual(@as(usize, 1), c.issuez_problems_len(ps));
    try testing.expectEqual(
        @as(u32, c.ISSUEZ_PROBLEM_MILESTONE_OPEN_WORK),
        c.issuez_problems_at(ps, 0).*.kind,
    );
    c.issuez_problems_free(ps);
    // As a create: no name.
    const nameless = [_]c.issuez_op{c.issuez_set_description(fixture.str("x"))};
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_milestone_check(h, .{}, &nameless, 1, null, &ps, &err),
        err,
    );
    try testing.expectEqual(
        @as(u32, c.ISSUEZ_PROBLEM_MISSING_VALUE),
        c.issuez_problems_at(ps, 0).*.kind,
    );
    c.issuez_problems_free(ps);
    const ml = try load(h, id);
    defer c.issuez_milestone_free(ml);
    try expect.str("Busy", c.issuez_milestone_name(ml));
    try testing.expectEqual(
        @as(c.issuez_milestone_status, c.ISSUEZ_MILESTONE_OPEN),
        c.issuez_milestone_status_of(ml),
    );
}

test "issuez_milestone_problems: two clones renamed it differently" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const m = try fixture.milestone(h, "Base");
    const ref = try std.fmt.allocPrint(r.arena(), "refs/milestones/{s}", .{m.idSlice()});
    const tree = try r.git(&.{ "hash-object", "-t", "tree", "-w", "/dev/null" });
    const one = try r.git(&.{ "commit-tree", tree, "-p", ref, "-m", "Rename\n\nName: one" });
    const two = try r.git(&.{ "commit-tree", tree, "-p", ref, "-m", "Rename\n\nName: two" });
    const merged = try r.git(
        &.{ "commit-tree", tree, "-p", one, "-p", two, "-m", "Merge milestone" },
    );
    _ = try r.git(&.{ "update-ref", ref, merged });
    const ml = try load(h, m.idStr());
    defer c.issuez_milestone_free(ml);
    const ps = c.issuez_milestone_problems(ml);
    try testing.expectEqual(@as(usize, 1), c.issuez_problems_len(ps));
    try testing.expectEqual(
        @as(u32, c.ISSUEZ_PROBLEM_CONFLICT),
        c.issuez_problems_at(ps, 0).*.kind,
    );
    const plain = try fixture.milestone(h, "Plain");
    const pl = try load(h, plain.idStr());
    defer c.issuez_milestone_free(pl);
    try testing.expectEqual(@as(usize, 0), c.issuez_problems_len(c.issuez_milestone_problems(pl)));
}

// covers: issuez_milestone_status_changed, issuez_milestone_author
test "issuez_milestone_updated: times and who" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const made = try fixture.milestone(h, "Spring");
    const id = made.idStr();
    var m = try load(h, id);
    var t: c.issuez_time = undefined;
    try testing.expect(!c.issuez_milestone_status_changed(m, &t));
    try testing.expectEqual(
        c.issuez_milestone_created(m).unix_seconds,
        c.issuez_milestone_updated(m).unix_seconds,
    );
    try expect.str("ada@example.invalid", c.issuez_milestone_author(m).*.email);
    c.issuez_milestone_free(m);
    try expect.code(
        c.ISSUEZ_OK,
        update(h, id, &.{c.issuez_set_milestone_status(c.ISSUEZ_MILESTONE_COMPLETED)}),
        null,
    );
    m = try load(h, id);
    defer c.issuez_milestone_free(m);
    try testing.expect(c.issuez_milestone_status_changed(m, &t));
    try testing.expect(t.unix_seconds >= c.issuez_milestone_created(m).unix_seconds);
    try testing.expect(c.issuez_milestone_status_changed(m, null));
    try testing.expect(!c.issuez_milestone_status_changed(null, &t));
    try testing.expect(c.issuez_milestone_author(null) == null);
    try testing.expectEqual(@as(i64, 0), c.issuez_milestone_updated(null).unix_seconds);
}

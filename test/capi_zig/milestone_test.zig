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

// C fills the record by hand: no two fields here hold the same value, so a swapped field fails.
test "issuez_milestone_info_of: every value" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    var t1: c.issuez_time = .{ .unix_seconds = 1_700_000_000, .tz_offset_minutes = 0 };
    var t2: c.issuez_time = .{ .unix_seconds = 1_700_000_500, .tz_offset_minutes = 0 };
    var t3: c.issuez_time = .{ .unix_seconds = 1_700_001_000, .tz_offset_minutes = 0 };
    var opener = fixture.ada;
    opener.at = &t1;
    var closer = fixture.ada;
    closer.email = fixture.str("grace@example.invalid");
    closer.at = &t2;
    var renamer = fixture.ada;
    renamer.email = fixture.str("lin@example.invalid");
    renamer.at = &t3;
    const ops = [_]c.issuez_op{
        c.issuez_set_name(fixture.str("v0.9")),
        c.issuez_set_description(fixture.str("The first release.")),
        c.issuez_set_due_date(.{ .year = 2026, .month = 12, .day = 24 }),
    };
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_milestone_create(h, &ops, ops.len, &opener, null, &w, &err),
        err,
    );
    var id_buf: [36]u8 = undefined;
    @memcpy(&id_buf, fixture.slice(c.issuez_write_id(w)));
    c.issuez_write_free(w);
    const id = fixture.str(&id_buf);
    const complete = [_]c.issuez_op{c.issuez_set_milestone_status(c.ISSUEZ_MILESTONE_COMPLETED)};
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_milestone_update(h, id, &complete, 1, &closer, null, &w, &err),
        err,
    );
    c.issuez_write_free(w);
    const rename = [_]c.issuez_op{c.issuez_set_name(fixture.str("v1.0"))};
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_milestone_update(h, id, &rename, 1, &renamer, null, &w, &err),
        err,
    );
    const tip = c.issuez_write_new_tip(w);
    c.issuez_write_free(w);

    const m = try load(h, id);
    defer c.issuez_milestone_free(m);
    const info = c.issuez_milestone_info_of(m);
    try testing.expect(c.issuez_milestone_info_of(m) == info);
    try expect.str(&id_buf, info.*.id);
    try testing.expect(c.issuez_oid_eq(&info.*.tip, &tip));
    try expect.str("v1.0", info.*.name);
    try expect.str("The first release.", info.*.description);
    try testing.expectEqual(@as(u32, c.ISSUEZ_MILESTONE_COMPLETED), info.*.status);
    try testing.expectEqual(c.issuez_date{ .year = 2026, .month = 12, .day = 24 }, info.*.due_date);
    try testing.expectEqual(t1.unix_seconds, info.*.created.unix_seconds);
    try testing.expectEqual(t3.unix_seconds, info.*.updated.unix_seconds);
    try testing.expect(info.*.has_status_changed);
    try testing.expectEqual(t2.unix_seconds, info.*.status_changed.unix_seconds);
    try expect.str("ada@example.invalid", info.*.author.*.email);
}

// covers: issuez_milestone_load, issuez_milestone_free, issuez_milestone_create
test "issuez_milestone_info_of: a minimal one, NULL, and what can't be created or found" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const made = try fixture.milestone(h, "Minimal");
    const m = try load(h, made.idStr());
    const info = c.issuez_milestone_info_of(m);
    try testing.expectEqual(@as(u32, c.ISSUEZ_MILESTONE_OPEN), info.*.status);
    try expect.str("", info.*.description);
    try testing.expectEqual(std.mem.zeroes(c.issuez_date), info.*.due_date);
    try testing.expect(!info.*.has_status_changed);
    try testing.expectEqual(@as(i64, 0), info.*.status_changed.unix_seconds);
    c.issuez_milestone_free(m);
    c.issuez_milestone_free(null);
    try testing.expect(c.issuez_milestone_info_of(null) == null);

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
    // A milestone has no original author: refused, not dropped.
    const imported = [_]c.issuez_op{
        c.issuez_set_name(fixture.str("v2")),
        c.issuez_set_original_author(fixture.str("octo@example.invalid")),
    };
    try expect.code(
        c.ISSUEZ_E_INVALID_VALUE,
        c.issuez_milestone_create(h, &imported, imported.len, &fixture.ada, null, &w, &err),
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
        c.issuez_milestone_info_of(c.issuez_milestone_list_at(list, i)).*.name,
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
    try expect.str("Summer", c.issuez_milestone_info_of(m).*.name);
    c.issuez_milestone_free(m);
    try expect.code(c.ISSUEZ_OK, update(h, id, &.{c.issuez_clear_due_date()}), null);
    try expect.code(
        c.ISSUEZ_OK,
        update(h, id, &.{c.issuez_set_milestone_status(c.ISSUEZ_MILESTONE_RETIRED)}),
        null,
    );
    m = try load(h, id);
    const retired = c.issuez_milestone_info_of(m);
    try testing.expectEqual(std.mem.zeroes(c.issuez_date), retired.*.due_date);
    try testing.expectEqual(@as(u32, c.ISSUEZ_MILESTONE_RETIRED), retired.*.status);
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
    // Nothing to write: the engine never gets to see this one.
    try expect.code(
        c.ISSUEZ_E_VERSION_MISMATCH,
        update(h, id, &.{c.issuez_expect(made.tip)}),
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
    try expect.str("Busy", c.issuez_milestone_info_of(ml).*.name);
    const info = c.issuez_milestone_info_of(ml);
    try testing.expectEqual(@as(u32, c.ISSUEZ_MILESTONE_OPEN), info.*.status);
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

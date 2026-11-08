//! Writing issues, comments, reactions, and the write receipts
//! (docs/test-plan.md §2.5.10).

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

fn checkProblems(
    repo: *c.issuez_repo,
    id: ?c.issuez_str,
    ops: []const c.issuez_op,
) !std.ArrayList(c.issuez_problem) {
    var ps: ?*c.issuez_problems = null;
    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_issue_check(repo, id orelse .{}, ops.ptr, ops.len, null, &ps, &err),
        err,
    );
    defer c.issuez_problems_free(ps);
    var out: std.ArrayList(c.issuez_problem) = .empty;
    for (0..c.issuez_problems_len(ps)) |i| try out.append(
        testing.allocator,
        c.issuez_problems_at(ps, i).*,
    );
    return out;
}

fn snapshotBytes(repo: *c.issuez_repo, a: std.mem.Allocator) ![]const u8 {
    var s: ?*c.issuez_snapshot = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_snapshot_take(repo, null, &s, null), null);
    defer c.issuez_snapshot_free(s);
    return a.dupe(u8, fixture.slice(c.issuez_snapshot_encode(s)));
}

test "issuez_issue_check: every guard, nothing written" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const closed = try fixture.create(
        h,
        &.{ c.issuez_set_title(fixture.str("Closed")), c.issuez_set_state(fixture.str("closed")) },
    );
    const parent = try fixture.titled(h, "Parent");
    const child = try fixture.create(
        h,
        &.{ c.issuez_set_title(fixture.str("Child")), c.issuez_set_parent(parent.idStr()) },
    );
    _ = try fixture.create(
        h,
        &.{ c.issuez_set_title(fixture.str("Seven")), c.issuez_set_number(7) },
    );
    const done = try fixture.milestone(h, "Done");
    const complete = [_]c.issuez_op{c.issuez_set_milestone_status(c.ISSUEZ_MILESTONE_COMPLETED)};
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    _ = try fixture.wrote(
        c.issuez_milestone_update(h, done.idStr(), &complete, 1, &fixture.ada, null, &w, &err),
        w,
        err,
        "complete",
    );
    const before = try snapshotBytes(h, r.arena());

    const missing = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c";
    const Case = struct { ?c.issuez_str, []const c.issuez_op, c_uint };
    const cases = [_]Case{
        .{
            null,
            &.{
                c.issuez_set_title(fixture.str("Under closed")),
                c.issuez_set_parent(closed.idStr()),
            },
            c.ISSUEZ_PROBLEM_CLOSED_ANCESTOR,
        },
        .{
            parent.idStr(),
            &.{c.issuez_set_state(fixture.str("closed"))},
            c.ISSUEZ_PROBLEM_OPEN_CHILDREN,
        },
        .{ parent.idStr(), &.{c.issuez_set_parent(child.idStr())}, c.ISSUEZ_PROBLEM_CYCLE },
        .{
            null,
            &.{
                c.issuez_set_title(fixture.str("Orphan")),
                c.issuez_set_parent(fixture.str(missing)),
            },
            c.ISSUEZ_PROBLEM_MISSING_TARGET,
        },
        .{
            null,
            &.{ c.issuez_set_title(fixture.str("Late")), c.issuez_set_milestone(done.idStr()) },
            c.ISSUEZ_PROBLEM_MILESTONE_CLOSED,
        },
        .{
            null,
            &.{ c.issuez_set_title(fixture.str("Also seven")), c.issuez_set_number(7) },
            c.ISSUEZ_PROBLEM_DUPLICATE_NUMBER,
        },
        .{
            null,
            &.{
                c.issuez_set_title(fixture.str("T")),
                c.issuez_set_workflow_state(fixture.str("nowhere")),
            },
            c.ISSUEZ_PROBLEM_UNKNOWN_WORKFLOW_STATE,
        },
        .{ null, &.{c.issuez_set_title(fixture.str("a\nb"))}, c.ISSUEZ_PROBLEM_NEWLINE },
    };
    for (cases, 0..) |case, i| {
        var ps = try checkProblems(h, case[0], case[1]);
        defer ps.deinit(testing.allocator);
        testing.expect(ps.items.len > 0) catch |e| {
            std.debug.print("check case {d}: no problem\n", .{i});
            return e;
        };
        testing.expectEqual(case[2], ps.items[0].kind) catch |e| {
            for (ps.items) |pp| std.debug.print(
                "check case {d}: kind {d} field {d} op {d} '{s}' value '{s}'\n",
                .{
                    i,
                    pp.kind,
                    pp.field,
                    pp.op_index,
                    fixture.slice(pp.message),
                    fixture.slice(pp.value),
                },
            );
            return e;
        };
    }
    var fine = try checkProblems(h, null, &.{c.issuez_set_title(fixture.str("Fine"))});
    defer fine.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), fine.items.len);
    var fine_update = try checkProblems(h, child.idStr(), &.{c.issuez_add_label(fixture.str("x"))});
    defer fine_update.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), fine_update.items.len);
    // Nothing was written.
    try testing.expectEqualStrings(before, try snapshotBytes(h, r.arena()));
    // A missing issue is the check's own error.
    var ps: ?*c.issuez_problems = null;
    const missing_id = fixture.str(missing);
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        c.issuez_issue_check(h, missing_id, null, 0, null, &ps, &err),
        err,
    );
    c.issuez_error_free(err);
}

test "issuez_issue_create: minimal, dated, closed, refused" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const when: c.issuez_time = .{ .unix_seconds = 1_500_000_000, .tz_offset_minutes = 120 };
    const dated: c.issuez_actor = .{
        .name = fixture.str("Bob"),
        .email = fixture.str("bob@example.invalid"),
        .user_id = .{},
        .at = &when,
        .reserved = .{ 0, 0, 0, 0 },
    };
    const ops = [_]c.issuez_op{c.issuez_set_title(fixture.str("Dated"))};
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_issue_create(h, &ops, 1, &dated, null, &w, &err), err);
    var issue: ?*c.issuez_issue = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_write_load_issue(w, null, &issue, null), null);
    try testing.expectEqual(@as(i64, 1_500_000_000), c.issuez_issue_created(issue).unix_seconds);
    try testing.expectEqual(@as(i16, 120), c.issuez_issue_created(issue).tz_offset_minutes);
    try expect.str("bob@example.invalid", c.issuez_issue_author(issue).*.email);
    c.issuez_issue_free(issue);
    c.issuez_write_free(w);

    // Without an actor: git's identity (the fixture's).
    try expect.code(c.ISSUEZ_OK, c.issuez_issue_create(h, &ops, 1, null, null, &w, null), null);
    const id = try r.arena().dupe(u8, fixture.slice(c.issuez_write_id(w)));
    c.issuez_write_free(w);
    const plain = try fixture.load(h, fixture.str(id));
    try expect.str("tester@example.invalid", c.issuez_issue_author(plain).*.email);
    c.issuez_issue_free(plain);

    // Imported closed.
    const closed = try fixture.create(h, &.{
        c.issuez_set_title(fixture.str("Imported")),
        c.issuez_set_state(fixture.str("closed")),
        c.issuez_set_fixed_by(fixture.str("abc123")),
    });
    const ci = try fixture.load(h, closed.idStr());
    try testing.expect(c.issuez_issue_is_done(ci));
    try expect.str("abc123", c.issuez_issue_fixed_by(ci));
    try testing.expectEqual(@as(u32, 1), c.issuez_issue_commit_count(ci));
    c.issuez_issue_free(ci);

    // Refused: no title, deleted, a comment, a guard, an actor without email.
    const refused = [_]struct { []const c.issuez_op, c.issuez_code }{
        .{ &.{c.issuez_add_label(fixture.str("x"))}, c.ISSUEZ_E_INVALID_VALUE },
        .{
            &.{ c.issuez_set_title(fixture.str("T")), c.issuez_set_deleted(true) },
            c.ISSUEZ_E_INVALID_VALUE,
        },
        .{
            &.{ c.issuez_set_title(fixture.str("T")), c.issuez_set_comment(fixture.str("hi")) },
            c.ISSUEZ_E_INVALID_VALUE,
        },
        .{
            &.{ c.issuez_set_title(fixture.str("T")), c.issuez_set_parent(closed.idStr()) },
            c.ISSUEZ_E_GUARD,
        },
    };
    for (refused, 0..) |case, i| {
        err = null;
        const rc = c.issuez_issue_create(h, case[0].ptr, case[0].len, &fixture.ada, null, &w, &err);
        expect.code(case[1], rc, err) catch |e| {
            std.debug.print("refused case {d}\n", .{i});
            return e;
        };
        try testing.expect(c.issuez_error_problems(err) != null);
        c.issuez_error_free(err);
    }
    const nobody: c.issuez_actor = .{
        .name = fixture.str("X"),
        .email = .{},
        .user_id = .{},
        .at = null,
        .reserved = .{ 0, 0, 0, 0 },
    };
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_issue_create(h, &ops, 1, &nobody, null, &w, null),
        null,
    );
    const not_uuid: c.issuez_actor = .{
        .name = fixture.str("X"),
        .email = fixture.str("x@example.invalid"),
        .user_id = fixture.str("42"),
        .at = null,
        .reserved = .{ 0, 0, 0, 0 },
    };
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_issue_create(h, &ops, 1, &not_uuid, null, &w, null),
        null,
    );

    // A host's user: its UUID on every commit (X-Author-Id), read back on
    // the author, the comment and the timeline, and on the receipt.
    const uid = "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d";
    const hosted: c.issuez_actor = .{
        .name = fixture.str("Grace"),
        .email = fixture.str("grace@example.invalid"),
        .user_id = fixture.str(uid),
        .at = null,
        .reserved = .{ 0, 0, 0, 0 },
    };
    try expect.code(c.ISSUEZ_OK, c.issuez_issue_create(h, &ops, 1, &hosted, null, &w, null), null);
    try expect.str(uid, c.issuez_write_entry(w).*.author.*.user_id);
    const hid = try r.arena().dupe(u8, fixture.slice(c.issuez_write_id(w)));
    c.issuez_write_free(w);
    const say = [_]c.issuez_op{c.issuez_set_comment(fixture.str("Signed"))};
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_issue_update(h, fixture.str(hid), &say, 1, &hosted, null, &w, null),
        null,
    );
    c.issuez_write_free(w);
    const hi = try fixture.load(h, fixture.str(hid));
    defer c.issuez_issue_free(hi);
    try expect.str(uid, c.issuez_issue_author(hi).*.user_id);
    try expect.str(uid, c.issuez_issue_comment_at(hi, 0).*.author.*.user_id);
    try expect.str(uid, c.issuez_issue_timeline_at(hi, 1).*.author.*.user_id);
    // Without one, none.
    const anon = try fixture.load(h, fixture.str(id));
    defer c.issuez_issue_free(anon);
    try expect.str("", c.issuez_issue_author(anon).*.user_id);
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_issue_create(h, &ops, 1, &fixture.ada, null, null, null),
        null,
    );
}

test "issuez_issue_update: set, clear, add, remove, with a comment, missing" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const other = try fixture.titled(h, "Other");
    const made = try fixture.create(h, &.{
        c.issuez_set_title(fixture.str("Before")),
        c.issuez_add_label(fixture.str("a")),
        c.issuez_set_priority(c.ISSUEZ_PRIORITY_LOW),
        c.issuez_set_due_date(.{ .year = 2026, .month = 1, .day = 1 }),
        c.issuez_set_workflow_state(fixture.str("ready")),
    });
    const id = made.idStr();
    _ = try fixture.update(h, id, &.{
        c.issuez_set_title(fixture.str("After")),
        c.issuez_remove_label(fixture.str("a")),
        c.issuez_add_label(fixture.str("b")),
        c.issuez_clear_priority(),
        c.issuez_clear_due_date(),
        c.issuez_set_start_date(.{ .year = 2026, .month = 2, .day = 1 }),
        c.issuez_set_estimate(30),
        c.issuez_add_blocker(other.idStr()),
        c.issuez_clear_workflow_state(),
        c.issuez_set_subject(fixture.str("Rework")),
    });
    var i = try fixture.load(h, id);
    try expect.str("After", c.issuez_issue_title(i));
    try testing.expect(
        c.issuez_issue_has_label(
            i,
            fixture.str("b"),
        ) and !c.issuez_issue_has_label(i, fixture.str("a")),
    );
    try testing.expectEqual(
        @as(c.issuez_priority, c.ISSUEZ_PRIORITY_UNKNOWN),
        c.issuez_issue_priority(i),
    );
    var d: c.issuez_date = undefined;
    try testing.expect(!c.issuez_issue_due_date(i, &d));
    try testing.expect(c.issuez_issue_start_date(i, &d));
    try expect.str(other.idSlice(), c.issuez_issue_blocker_at(i, 0));
    try expect.str("backlog", c.issuez_issue_workflow_state(i));
    const subject = try r.git(
        &.{
            "log",
            "-1",
            "--format=%s",
            try std.fmt.allocPrint(r.arena(), "refs/issues/{s}", .{made.idSlice()}),
        },
    );
    try testing.expectEqualStrings("Rework", subject);
    c.issuez_issue_free(i);

    // Clearing a set replaces it; a comment rides along.
    _ = try fixture.update(
        h,
        id,
        &.{
            c.issuez_clear_labels(),
            c.issuez_add_label(fixture.str("c")),
            c.issuez_remove_blocker(other.idStr()),
            c.issuez_set_comment(fixture.str("Reworked.")),
        },
    );
    i = try fixture.load(h, id);
    try testing.expectEqual(@as(usize, 1), c.issuez_issue_label_count(i));
    try testing.expectEqual(@as(usize, 0), c.issuez_issue_blocker_count(i));
    try expect.str("Reworked.", c.issuez_issue_comment_at(i, 0).*.text);
    c.issuez_issue_free(i);

    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    const missing = fixture.str("0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c");
    const ops = [_]c.issuez_op{c.issuez_add_label(fixture.str("x"))};
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        c.issuez_issue_update(h, missing, &ops, 1, &fixture.ada, null, &w, &err),
        err,
    );
    c.issuez_error_free(err);
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_issue_update(h, fixture.str("abc"), &ops, 1, &fixture.ada, null, &w, null),
        null,
    );
    // Nothing to change: OK, nothing written. Values as they are too.
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_issue_update(h, id, null, 0, &fixture.ada, null, &w, null),
        null,
    );
    try testing.expect(!c.issuez_write_wrote(w));
    const tip = c.issuez_write_new_tip(w);
    c.issuez_write_free(w);
    const now = try fixture.load(h, id);
    const title = c.issuez_issue_title(now);
    const same = [_]c.issuez_op{
        c.issuez_set_title(title),
        c.issuez_set_state(fixture.str("open")),
    };
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_issue_update(h, id, &same, same.len, &fixture.ada, null, &w, null),
        null,
    );
    c.issuez_issue_free(now);
    try testing.expect(!c.issuez_write_wrote(w));
    const kept = c.issuez_write_new_tip(w);
    try testing.expect(c.issuez_oid_eq(&kept, &tip));
    try testing.expectEqual(@as(usize, 0), c.issuez_write_entry(w).*.change_count);
    c.issuez_write_free(w);
}

test "issuez_issue_update: a comment's edit, delete and restore; the root, stale" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const made = try fixture.titled(h, "Talk");
    const id = made.idStr();
    const said = try fixture.comment(h, id, "First");
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    const edited = try fixture.wrote(
        fixture.updateRc(
            h,
            id,
            &.{
                c.issuez_edit_comment(said.commit),
                c.issuez_set_comment(fixture.str("Better")),
                c.issuez_expect(said.tip),
            },
            &fixture.ada,
            null,
            &w,
            &err,
        ),
        w,
        err,
        "edit",
    );
    // Stale expect.
    try expect.code(
        c.ISSUEZ_E_VERSION_MISMATCH,
        fixture.updateRc(
            h,
            id,
            &.{
                c.issuez_edit_comment(said.commit),
                c.issuez_set_comment(fixture.str("No")),
                c.issuez_expect(said.tip),
            },
            &fixture.ada,
            null,
            &w,
            &err,
        ),
        err,
    );
    c.issuez_error_free(err);
    err = null;
    _ = try fixture.wrote(
        fixture.updateRc(
            h,
            id,
            &.{ c.issuez_delete_comment(said.commit), c.issuez_expect(edited.tip) },
            &fixture.ada,
            null,
            &w,
            &err,
        ),
        w,
        err,
        "delete",
    );
    var i = try fixture.load(h, id);
    try testing.expect(c.issuez_issue_comment_at(i, 0).*.deleted);
    c.issuez_issue_free(i);
    _ = try fixture.wrote(
        fixture.updateRc(
            h,
            id,
            &.{c.issuez_restore_comment(said.commit)},
            &fixture.ada,
            null,
            &w,
            &err,
        ),
        w,
        err,
        "restore",
    );
    i = try fixture.load(h, id);
    try testing.expect(!c.issuez_issue_comment_at(i, 0).*.deleted);
    try expect.str("Better", c.issuez_issue_comment_at(i, 0).*.text);
    c.issuez_issue_free(i);
    // The root holds the description: no comment events on it.
    err = null;
    try testing.expect(
        fixture.updateRc(
            h,
            id,
            &.{ c.issuez_edit_comment(made.tip), c.issuez_set_comment(fixture.str("x")) },
            &fixture.ada,
            null,
            &w,
            &err,
        ) != c.ISSUEZ_OK,
    );
    c.issuez_error_free(err);
    err = null;
    const none = std.mem.zeroes(c.issuez_oid);
    try testing.expect(
        fixture.updateRc(
            h,
            id,
            &.{c.issuez_delete_comment(none)},
            &fixture.ada,
            null,
            &w,
            &err,
        ) != c.ISSUEZ_OK,
    );
    c.issuez_error_free(err);
}

test "issuez_write_wrote: a reaction added, again, taken back, on a comment" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const made = try fixture.titled(h, "Liked");
    const id = made.idStr();
    const said = try fixture.comment(h, id, "Me too");
    var w: ?*c.issuez_write = null;
    try expect.code(
        c.ISSUEZ_OK,
        fixture.updateRc(
            h,
            id,
            &.{c.issuez_add_reaction(fixture.str(":+1:"))},
            &fixture.ada,
            null,
            &w,
            null,
        ),
        null,
    );
    try testing.expect(c.issuez_write_wrote(w));
    c.issuez_write_free(w);
    try expect.code(
        c.ISSUEZ_OK,
        fixture.updateRc(
            h,
            id,
            &.{c.issuez_add_reaction(fixture.str(":+1:"))},
            &fixture.ada,
            null,
            &w,
            null,
        ),
        null,
    );
    try testing.expect(!c.issuez_write_wrote(w));
    c.issuez_write_free(w);
    try expect.code(
        c.ISSUEZ_OK,
        fixture.updateRc(
            h,
            id,
            &.{
                c.issuez_reaction_target(said.commit),
                c.issuez_add_reaction(fixture.str("heart")),
            },
            &fixture.ada,
            null,
            &w,
            null,
        ),
        null,
    );
    c.issuez_write_free(w);
    try expect.code(
        c.ISSUEZ_OK,
        fixture.updateRc(
            h,
            id,
            &.{c.issuez_remove_reaction(fixture.str(":+1:"))},
            &fixture.ada,
            null,
            &w,
            null,
        ),
        null,
    );
    try testing.expect(c.issuez_write_wrote(w));
    c.issuez_write_free(w);
    const i = try fixture.load(h, id);
    defer c.issuez_issue_free(i);
    try testing.expectEqual(@as(usize, 0), c.issuez_issue_reaction_count(i, null));
    try testing.expectEqual(@as(usize, 1), c.issuez_issue_reaction_count(i, &said.commit));
    const cm = c.issuez_issue_comment_find(i, &said.commit);
    try testing.expectEqual(@as(usize, 1), c.issuez_comment_reaction_count(cm));
    try expect.str("heart", c.issuez_comment_reaction_at(cm, 0).*.emoji);
    try testing.expect(c.issuez_comment_reaction_at(cm, 1) == null);
    try testing.expectEqual(@as(usize, 0), c.issuez_comment_reaction_count(null));
    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_E_INVALID_VALUE,
        fixture.updateRc(
            h,
            id,
            &.{c.issuez_add_reaction(fixture.str("a b"))},
            &fixture.ada,
            null,
            &w,
            &err,
        ),
        err,
    );
    c.issuez_error_free(err);
    // An expected tip that isn't the issue's any more.
    try expect.code(
        c.ISSUEZ_E_VERSION_MISMATCH,
        fixture.updateRc(
            h,
            id,
            &.{ c.issuez_add_reaction(fixture.str("eyes")), c.issuez_expect(made.tip) },
            &fixture.ada,
            null,
            &w,
            &err,
        ),
        err,
    );
    c.issuez_error_free(err);
    const now = c.issuez_issue_tip(i);
    try expect.code(
        c.ISSUEZ_OK,
        fixture.updateRc(
            h,
            id,
            &.{ c.issuez_add_reaction(fixture.str("eyes")), c.issuez_expect(now) },
            &fixture.ada,
            null,
            &w,
            null,
        ),
        null,
    );
    c.issuez_write_free(w);
}

// covers: issuez_write_kind, issuez_write_id, issuez_write_commit, issuez_write_old_tip
// covers: issuez_write_new_tip, issuez_write_entry, issuez_write_load_issue
test "issuez_write_free: receipts" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const ops = [_]c.issuez_op{
        c.issuez_set_title(fixture.str("Receipt")),
        c.issuez_add_label(fixture.str("bug")),
    };
    var w: ?*c.issuez_write = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_issue_create(h, &ops, ops.len, &fixture.ada, null, &w, null),
        null,
    );
    try testing.expectEqual(@as(c.issuez_kind, c.ISSUEZ_KIND_ISSUE), c.issuez_write_kind(w));
    const id = try r.arena().dupe(u8, fixture.slice(c.issuez_write_id(w)));
    try expect.terminated(c.issuez_write_id(w));
    try testing.expectEqual(@as(u8, 0), c.issuez_write_old_tip(w).len);
    const created_tip = c.issuez_write_new_tip(w);
    const created_commit = c.issuez_write_commit(w);
    try testing.expect(c.issuez_oid_eq(&created_tip, &created_commit));
    const e = c.issuez_write_entry(w).*;
    try testing.expectEqual(@as(u32, c.ISSUEZ_ENTRY_CREATED), e.kind);
    try testing.expect(e.change_count >= 1);
    c.issuez_write_free(w);

    const upd = [_]c.issuez_op{c.issuez_set_priority(c.ISSUEZ_PRIORITY_HIGH)};
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_issue_update(h, fixture.str(id), &upd, 1, &fixture.ada, null, &w, null),
        null,
    );
    const old_tip = c.issuez_write_old_tip(w);
    try testing.expect(c.issuez_oid_eq(&old_tip, &created_tip));
    const ue = c.issuez_write_entry(w).*;
    try testing.expectEqual(@as(u32, c.ISSUEZ_ENTRY_UPDATE), ue.kind);
    try testing.expectEqual(@as(usize, 1), ue.change_count);
    const ch = c.issuez_entry_change_at(c.issuez_write_entry(w), 0).*;
    try testing.expectEqual(@as(u32, c.ISSUEZ_FIELD_PRIORITY), ch.field);
    try expect.str("high", ch.new_value);
    var issue: ?*c.issuez_issue = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_write_load_issue(w, null, &issue, null), null);
    const tip = c.issuez_issue_tip(issue);
    const new_tip = c.issuez_write_new_tip(w);
    try testing.expect(c.issuez_oid_eq(&tip, &new_tip));
    c.issuez_issue_free(issue);
    c.issuez_write_free(w);

    const m = [_]c.issuez_op{c.issuez_set_name(fixture.str("v1"))};
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_milestone_create(h, &m, 1, &fixture.ada, null, &w, null),
        null,
    );
    try testing.expectEqual(@as(c.issuez_kind, c.ISSUEZ_KIND_MILESTONE), c.issuez_write_kind(w));
    c.issuez_write_free(w);
    c.issuez_write_free(null);
    try testing.expectEqual(@as(c.issuez_kind, c.ISSUEZ_KIND_UNKNOWN), c.issuez_write_kind(null));
    try testing.expect(!c.issuez_write_wrote(null));
    try testing.expect(c.issuez_write_entry(null) == null);
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_write_load_issue(null, null, &issue, null),
        null,
    );
}

test "issuez_write_retries: a concurrent write in between makes one retry" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const made = try fixture.titled(r.handle, "Raced");
    const ref = try std.fmt.allocPrint(r.arena(), "refs/issues/{s}", .{made.idSlice()});
    const tree = try r.git(&.{ "hash-object", "-t", "tree", "-w", "/dev/null" });
    const theirs = try r.git(&.{ "commit-tree", tree, "-p", ref, "-m", "Theirs" });
    const done = try std.fs.path.join(r.arena(), &.{ r.root, "raced" });
    // On its first ref update the library finds the ref moved.
    const racing = try fixture.script(r.arena(), r.root, "racing-git",
        \\#!/bin/sh
        \\for a; do
        \\  if [ "$a" = update-ref ] && [ ! -e "$RACE_DONE" ]; then
        \\    : > "$RACE_DONE"; git update-ref "$RACE_REF" "$RACE_TO"; break
        \\  fi
        \\done
        \\exec git "$@"
        \\
    );
    var vars: [3]c.issuez_op = undefined;
    for ([_][2][]const u8{
        .{ "RACE_REF", ref },
        .{ "RACE_TO", theirs },
        .{ "RACE_DONE", done },
    }, &vars) |kv, *o| {
        o.* = fixture.opStr(c.ISSUEZ_OPT_ENV, c.ISSUEZ_OP_SET, kv[1]);
        o.name = fixture.str(kv[0]);
    }
    const h = try r.open(
        &.{ c.issuez_opt_git_path(fixture.str(racing)), vars[0], vars[1], vars[2] },
    );
    defer c.issuez_repo_close(h);
    const ops = [_]c.issuez_op{c.issuez_add_label(fixture.str("ours"))};
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_issue_update(h, made.idStr(), &ops, 1, &fixture.ada, null, &w, &err),
        err,
    );
    try testing.expectEqual(@as(u32, 1), c.issuez_write_retries(w));
    c.issuez_write_free(w);
    // Both writes are there, ours on theirs.
    const parent = try r.git(&.{ "rev-parse", try std.fmt.allocPrint(r.arena(), "{s}~1", .{ref}) });
    try testing.expectEqualStrings(theirs, parent);
    const again = [_]c.issuez_op{c.issuez_add_label(fixture.str("again"))};
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_issue_update(h, made.idStr(), &again, 1, &fixture.ada, null, &w, null),
        null,
    );
    try testing.expectEqual(@as(u32, 0), c.issuez_write_retries(w));
    c.issuez_write_free(w);
    try testing.expectEqual(@as(u32, 0), c.issuez_write_retries(null));
}

test "issuez_issue_update: EXPECT_EDITS, a text's version that other changes don't touch" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const made = try fixture.create(
        h,
        &.{
            c.issuez_set_title(fixture.str("Versioned")),
            c.issuez_set_description(fixture.str("v0")),
        },
    );
    const id = made.idStr();
    const said = try fixture.comment(h, id, "c0");
    const edits = struct {
        fn op(n: i64) c.issuez_op {
            return fixture.opNum(c.ISSUEZ_OPT_EXPECT_EDITS, n);
        }
    }.op;
    const Case = struct { ops: []const c.issuez_op, code: c.issuez_code };
    var edit_comment = std.mem.zeroes(c.issuez_op);
    edit_comment.verb = c.ISSUEZ_OP_SET;
    edit_comment.target = c.ISSUEZ_OPT_EDIT_COMMENT;
    edit_comment.oid = said.commit;
    const cases = [_]Case{
        .{
            .ops = &.{ c.issuez_set_description(fixture.str("v1")), edits(0) },
            .code = c.ISSUEZ_OK,
        },
        .{
            .ops = &.{ c.issuez_set_description(fixture.str("stale")), edits(0) },
            .code = c.ISSUEZ_E_VERSION_MISMATCH,
        },
        // Another change in between leaves the description's version be.
        .{ .ops = &.{c.issuez_add_label(fixture.str("bug"))}, .code = c.ISSUEZ_OK },
        .{
            .ops = &.{ c.issuez_set_description(fixture.str("v2")), edits(1) },
            .code = c.ISSUEZ_OK,
        },
        .{
            .ops = &.{ edit_comment, c.issuez_set_comment(fixture.str("c1")), edits(0) },
            .code = c.ISSUEZ_OK,
        },
        .{
            .ops = &.{ edit_comment, c.issuez_set_comment(fixture.str("stale")), edits(0) },
            .code = c.ISSUEZ_E_VERSION_MISMATCH,
        },
        .{
            .ops = &.{ c.issuez_add_label(fixture.str("x")), edits(0) },
            .code = c.ISSUEZ_E_INVALID_VALUE,
        },
    };
    for (cases) |case| {
        var w: ?*c.issuez_write = null;
        var err: ?*c.issuez_error = null;
        try expect.code(
            case.code,
            c.issuez_issue_update(h, id, case.ops.ptr, case.ops.len, &fixture.ada, null, &w, &err),
            err,
        );
        c.issuez_error_free(err);
        c.issuez_write_free(w);
    }
    const i = try fixture.load(h, id);
    defer c.issuez_issue_free(i);
    try expect.str("v2", c.issuez_issue_description(i));
    try expect.str("c1", c.issuez_issue_comment_find(i, &said.commit).*.text);
}

// covers: issuez_comment_reaction_count, issuez_comment_reaction_at
test "issuez_issue_update: DELETE_COMMENT, RESTORE_COMMENT and REACTIONS as update ops" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const made = try fixture.titled(h, "Ops");
    const id = made.idStr();
    const said = try fixture.comment(h, id, "Hello");
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    const del = [_]c.issuez_op{c.issuez_delete_comment(said.commit)};
    _ = try fixture.wrote(
        c.issuez_issue_update(h, id, &del, del.len, &fixture.ada, null, &w, &err),
        w,
        err,
        "delete",
    );
    var i = try fixture.load(h, id);
    try testing.expect(c.issuez_issue_comment_find(i, &said.commit).*.deleted);
    c.issuez_issue_free(i);
    const back = [_]c.issuez_op{c.issuez_restore_comment(said.commit)};
    _ = try fixture.wrote(
        c.issuez_issue_update(h, id, &back, back.len, &fixture.ada, null, &w, &err),
        w,
        err,
        "restore",
    );
    const like = [_]c.issuez_op{
        c.issuez_add_reaction(fixture.str("heart")),
        c.issuez_reaction_target(said.commit),
    };
    _ = try fixture.wrote(
        c.issuez_issue_update(h, id, &like, like.len, &fixture.ada, null, &w, &err),
        w,
        err,
        "react",
    );
    const on_issue = [_]c.issuez_op{c.issuez_add_reaction(fixture.str(":+1:"))};
    _ = try fixture.wrote(
        c.issuez_issue_update(h, id, &on_issue, on_issue.len, &fixture.ada, null, &w, &err),
        w,
        err,
        "react",
    );
    i = try fixture.load(h, id);
    defer c.issuez_issue_free(i);
    try testing.expect(!c.issuez_issue_comment_find(i, &said.commit).*.deleted);
    try testing.expectEqual(@as(usize, 1), c.issuez_issue_reaction_count(i, &said.commit));
    const cm = c.issuez_issue_comment_find(i, &said.commit);
    try testing.expectEqual(@as(usize, 1), c.issuez_comment_reaction_count(cm));
    try expect.str("heart", c.issuez_comment_reaction_at(cm, 0).*.emoji);
    try testing.expect(c.issuez_comment_reaction_at(cm, 1) == null);
    try testing.expectEqual(@as(usize, 0), c.issuez_comment_reaction_count(null));
    try testing.expectEqual(@as(usize, 1), c.issuez_issue_reaction_count(i, null));
    // A commit of its own.
    const mixed = [_]c.issuez_op{
        c.issuez_add_reaction(fixture.str("eyes")),
        c.issuez_set_title(fixture.str("x")),
    };
    try expect.code(
        c.ISSUEZ_E_INVALID_VALUE,
        c.issuez_issue_update(h, id, &mixed, mixed.len, &fixture.ada, null, &w, null),
        null,
    );
    const bad = [_]c.issuez_op{c.issuez_add_reaction(fixture.str("a b"))};
    try expect.code(
        c.ISSUEZ_E_INVALID_VALUE,
        c.issuez_issue_update(h, id, &bad, bad.len, &fixture.ada, null, &w, null),
        null,
    );
}

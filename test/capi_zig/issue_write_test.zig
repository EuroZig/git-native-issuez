//! Writing issues, comments, reactions, and the write receipts.

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

/// The kind of the first problem a create (no id) or an update is refused for.
fn refusedFor(repo: *c.issuez_repo, id: ?c.issuez_str, ops: []const c.issuez_op) !u32 {
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    const rc = if (id) |i|
        fixture.updateRc(repo, i, ops, &fixture.ada, null, &w, &err)
    else
        c.issuez_issue_create(repo, ops.ptr, ops.len, &fixture.ada, null, &w, &err);
    defer c.issuez_error_free(err);
    if (rc == c.ISSUEZ_OK) {
        c.issuez_write_free(w);
        return error.NotRefused;
    }
    try testing.expect(rc == c.ISSUEZ_E_GUARD or rc == c.ISSUEZ_E_INVALID_VALUE);
    const problems = c.issuez_error_problems(err);
    try testing.expect(c.issuez_problems_len(problems) > 0);
    return c.issuez_problems_at(problems, 0).*.kind;
}

fn snapshotBytes(repo: *c.issuez_repo, a: std.mem.Allocator) ![]const u8 {
    var s: ?*c.issuez_snapshot = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_snapshot_take(repo, null, &s, null), null);
    defer c.issuez_snapshot_free(s);
    var text: std.Io.Writer.Allocating = .init(a);
    for (0..c.issuez_snapshot_len(s)) |i| {
        var kind: c.issuez_kind = undefined;
        var id: c.issuez_str = undefined;
        var tip: c.issuez_oid = undefined;
        c.issuez_snapshot_at(s, i, &kind, &id, &tip);
        const hex = fixture.oidHex(tip);
        try text.writer.print("{d} {s} {s}\n", .{ kind, fixture.slice(id), hex[0 .. tip.len * 2] });
    }
    return text.written();
}

test "issuez_issue_update: every guard refuses with its problem, nothing written" {
    var r = try fixture.Repo.init(.{});
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
    };
    for (cases, 0..) |case, i| {
        testing.expectEqual(case[2], try refusedFor(h, case[0], case[1])) catch |e| {
            std.debug.print("refused case {d}\n", .{i});
            return e;
        };
    }
    // Nothing was written.
    try testing.expectEqualStrings(before, try snapshotBytes(h, r.arena()));
    // A missing issue or parent is an error of its own.
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        fixture.updateRc(h, fixture.str(missing), &.{}, &fixture.ada, null, &w, &err),
        err,
    );
    c.issuez_error_free(err);
    err = null;
    const orphan = [_]c.issuez_op{
        c.issuez_set_title(fixture.str("Orphan")),
        c.issuez_set_parent(fixture.str(missing)),
    };
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        c.issuez_issue_create(h, &orphan, orphan.len, &fixture.ada, null, &w, &err),
        err,
    );
    c.issuez_error_free(err);
    try testing.expectEqualStrings(before, try snapshotBytes(h, r.arena()));
}

test "issuez_issue_create: minimal, dated, closed, refused" {
    var r = try fixture.Repo.init(.{});
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
    const info = c.issuez_issue_info_of(issue);
    try testing.expectEqual(@as(i64, 1_500_000_000), info.*.created.unix_seconds);
    try testing.expectEqual(@as(i16, 120), info.*.created.tz_offset_minutes);
    try expect.str("bob@example.invalid", info.*.author.*.email);
    c.issuez_issue_free(issue);
    c.issuez_write_free(w);

    // Without an actor: git's identity (the fixture's).
    try expect.code(c.ISSUEZ_OK, c.issuez_issue_create(h, &ops, 1, null, null, &w, null), null);
    const id = try r.arena().dupe(u8, fixture.slice(c.issuez_write_id(w)));
    c.issuez_write_free(w);
    const plain = try fixture.load(h, fixture.str(id));
    try expect.str("tester@example.invalid", c.issuez_issue_info_of(plain).*.author.*.email);
    c.issuez_issue_free(plain);

    // From a template: locked and about a ref on its root.
    var locked = fixture.opNum(c.ISSUEZ_FIELD_LOCKED, 1);
    locked.str = fixture.str("heated");
    const started = try fixture.create(h, &.{
        c.issuez_set_title(fixture.str("From a template")),
        locked,
        fixture.opStr(c.ISSUEZ_FIELD_REF, c.ISSUEZ_OP_SET, "refs/tags/v1"),
    });
    const si = try fixture.load(h, started.idStr());
    const started_info = c.issuez_issue_info_of(si);
    try testing.expect(started_info.*.is_locked);
    try expect.str("heated", started_info.*.lock_reason);
    try expect.str("refs/tags/v1", started_info.*.ref);
    try testing.expectEqual(@as(u32, 1), started_info.*.commit_count);
    c.issuez_issue_free(si);

    // Imported closed.
    const closed = try fixture.create(h, &.{
        c.issuez_set_title(fixture.str("Imported")),
        c.issuez_set_state(fixture.str("closed")),
        c.issuez_set_fixed_by(fixture.str("abc123")),
    });
    const ci = try fixture.load(h, closed.idStr());
    try testing.expect(c.issuez_issue_info_of(ci).*.is_done);
    try expect.str("abc123", c.issuez_issue_info_of(ci).*.fixed_by);
    try testing.expectEqual(@as(u32, 1), c.issuez_issue_info_of(ci).*.commit_count);
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
        // Nothing here could take these: refused, not dropped.
        .{
            &.{
                c.issuez_set_title(fixture.str("T")),
                fixture.opStr(c.ISSUEZ_OPT_SUBJECT, c.ISSUEZ_OP_SET, "Why"),
            },
            c.ISSUEZ_E_INVALID_VALUE,
        },
        .{
            &.{ c.issuez_set_title(fixture.str("T")), c.issuez_expect(closed.tip) },
            c.ISSUEZ_E_INVALID_VALUE,
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
    try expect.str(uid, c.issuez_issue_info_of(hi).*.author.*.user_id);
    try expect.str(uid, c.issuez_issue_comment_at(hi, 0).*.author.*.user_id);
    try expect.str(uid, c.issuez_issue_timeline_at(hi, 1).*.author.*.user_id);
    // Without one, none.
    const anon = try fixture.load(h, fixture.str(id));
    defer c.issuez_issue_free(anon);
    try expect.str("", c.issuez_issue_info_of(anon).*.author.*.user_id);
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_issue_create(h, &ops, 1, &fixture.ada, null, null, null),
        null,
    );
}

test "issuez_issue_update: set, clear, add, remove, with a comment, missing" {
    var r = try fixture.Repo.init(.{});
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
    try expect.str("After", c.issuez_issue_info_of(i).*.title);
    try testing.expect(fixture.hasLabel(i, "b") and !fixture.hasLabel(i, "a"));
    try testing.expectEqual(
        @as(u32, c.ISSUEZ_PRIORITY_UNKNOWN),
        c.issuez_issue_info_of(i).*.priority,
    );
    try testing.expectEqual(@as(i16, 0), c.issuez_issue_info_of(i).*.due_date.year);
    try testing.expect(c.issuez_issue_info_of(i).*.start_date.year != 0);
    try expect.str(other.idSlice(), c.issuez_issue_blocker_at(i, 0));
    try expect.str("backlog", c.issuez_issue_info_of(i).*.workflow_state);
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
    const last = try fixture.update(
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
    // Nothing to change: OK, nothing written, the tip as it was.
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_issue_update(h, id, null, 0, &fixture.ada, null, &w, null),
        null,
    );
    try testing.expect(!c.issuez_write_wrote(w));
    const kept = c.issuez_write_new_tip(w);
    try testing.expect(fixture.oidEql(kept, last));
    try testing.expectEqual(@as(usize, 0), c.issuez_write_entry(w).*.change_count);
    c.issuez_write_free(w);
}

test "issuez_issue_update: a comment's edit, delete and restore; the root" {
    var r = try fixture.Repo.init(.{});
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

test "issuez_write_wrote: a reaction added, taken back, on a comment" {
    var r = try fixture.Repo.init(.{});
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
    _ = try fixture.update(h, id, &.{
        c.issuez_reaction_target(said.commit),
        c.issuez_add_reaction(fixture.str("eyes")),
    });
    const i = try fixture.load(h, id);
    defer c.issuez_issue_free(i);
    try testing.expectEqual(@as(usize, 0), c.issuez_issue_reaction_count(i, null));
    try testing.expectEqual(@as(usize, 2), c.issuez_issue_reaction_count(i, &said.commit));
    try expect.str("heart", c.issuez_issue_reaction_at(i, &said.commit, 0).*.emoji);
    try expect.str("eyes", c.issuez_issue_reaction_at(i, &said.commit, 1).*.emoji);
    try testing.expect(c.issuez_issue_reaction_at(i, &said.commit, 2) == null);
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
}

// covers: issuez_write_kind, issuez_write_id, issuez_write_commit, issuez_write_old_tip
// covers: issuez_write_new_tip, issuez_write_entry, issuez_write_load_issue
test "issuez_write_free: receipts" {
    var r = try fixture.Repo.init(.{});
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
    try testing.expect(fixture.oidEql(created_tip, created_commit));
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
    try testing.expect(fixture.oidEql(old_tip, created_tip));
    const ue = c.issuez_write_entry(w).*;
    try testing.expectEqual(@as(u32, c.ISSUEZ_ENTRY_UPDATE), ue.kind);
    try testing.expectEqual(@as(usize, 1), ue.change_count);
    const ch = c.issuez_entry_change_at(c.issuez_write_entry(w), 0).*;
    try testing.expectEqual(@as(u32, c.ISSUEZ_FIELD_PRIORITY), ch.field);
    try expect.str("high", ch.new_value);
    var issue: ?*c.issuez_issue = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_write_load_issue(w, null, &issue, null), null);
    const tip = c.issuez_issue_info_of(issue).*.tip;
    const new_tip = c.issuez_write_new_tip(w);
    try testing.expect(fixture.oidEql(tip, new_tip));
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
    var r = try fixture.Repo.init(.{});
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
    var r = try fixture.Repo.init(.{});
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
        .{
            .ops = &.{ edit_comment, c.issuez_set_comment(fixture.str("c1")), edits(0) },
            .code = c.ISSUEZ_OK,
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
    try expect.str("v1", c.issuez_issue_info_of(i).*.description);
    try expect.str("c1", fixture.findComment(i, said.commit).?.text);
}

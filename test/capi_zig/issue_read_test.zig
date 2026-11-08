//! Reading issues (docs/test-plan.md §2.5.8): one issue with every field,
//! one with none.

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

const grace: c.issuez_person = .{
    .name = .{},
    .email = .{ .ptr = "grace@example.invalid", .len = 21 },
    .user_id = .{ .ptr = "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d", .len = 36 },
};

/// The issue with every field, and its relatives.
const Rich = struct {
    r: fixture.Repo,
    x: fixture.Created,
    bare: fixture.Created,
    parent: fixture.Created,
    blocker: fixture.Created,
    milestone: fixture.Created,
    c1: c.issuez_oid,
    c2: c.issuez_oid,
    issue: *c.issuez_issue,
    plain: *c.issuez_issue,

    fn init(rich: *Rich) !void {
        try rich.r.init(.{});
        errdefer rich.r.deinit();
        const h = rich.r.handle;
        rich.parent = try fixture.titled(h, "Parent");
        rich.blocker = try fixture.titled(h, "Blocker");
        rich.milestone = try fixture.milestone(h, "v1");
        var locked = fixture.opNum(c.ISSUEZ_FIELD_LOCKED, 1);
        locked.str = fixture.str("heated");
        var assignee = std.mem.zeroes(c.issuez_op);
        assignee = c.issuez_add_assignee(grace);
        rich.x = try fixture.create(h, &.{
            c.issuez_set_title(fixture.str("Login page crashes")),
            c.issuez_set_description(fixture.str("On Safari.\n\nEvery time.")),
            c.issuez_set_workflow_state(fixture.str("ready")),
            c.issuez_set_priority(c.ISSUEZ_PRIORITY_HIGH),
            c.issuez_add_label(fixture.str("bug")),
            c.issuez_add_label(fixture.str("ui")),
            assignee,
            c.issuez_add_assignee(
                .{ .name = .{}, .email = fixture.str("ada@example.invalid"), .user_id = .{} },
            ),
            c.issuez_set_milestone(rich.milestone.idStr()),
            c.issuez_set_parent(rich.parent.idStr()),
            c.issuez_add_blocker(rich.blocker.idStr()),
            c.issuez_set_start_date(.{ .year = 2026, .month = 11, .day = 1 }),
            c.issuez_set_due_date(.{ .year = 2026, .month = 12, .day = 1 }),
            c.issuez_set_estimate(90),
            c.issuez_set_number(7),
            c.issuez_set_extra(fixture.str("X-Forgejo-Project"), fixture.str("3")),
            fixture.opStr(c.ISSUEZ_OPT_ORIGINAL_AUTHOR, c.ISSUEZ_OP_SET, "octo@github"),
            fixture.opStr(c.ISSUEZ_OPT_ORIGINAL_ID, c.ISSUEZ_OP_SET, "gh-12"),
        });
        const id = rich.x.idStr();
        _ = try fixture.update(h, id, &.{c.issuez_set_description(fixture.str("On Safari only."))});
        rich.c1 = (try fixture.comment(h, id, "First take")).commit;
        var w: ?*c.issuez_write = null;
        var err: ?*c.issuez_error = null;
        _ = try fixture.wrote(
            fixture.updateRc(
                h,
                id,
                &.{
                    c.issuez_edit_comment(rich.c1),
                    c.issuez_set_comment(fixture.str("Second take")),
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
        rich.c2 = (try fixture.comment(h, id, "Hidden for a while")).commit;
        _ = try fixture.wrote(
            fixture.updateRc(
                h,
                id,
                &.{c.issuez_delete_comment(rich.c2)},
                &fixture.ada,
                null,
                &w,
                &err,
            ),
            w,
            err,
            "delete",
        );
        _ = try fixture.wrote(
            fixture.updateRc(
                h,
                id,
                &.{c.issuez_restore_comment(rich.c2)},
                &fixture.ada,
                null,
                &w,
                &err,
            ),
            w,
            err,
            "restore",
        );
        const c3 = (try fixture.comment(h, id, "Abuse")).commit;
        const c4 = (try fixture.comment(h, id, "Spam")).commit;
        _ = try fixture.wrote(
            fixture.updateRc(h, id, &.{c.issuez_delete_comment(c4)}, &fixture.ada, null, &w, &err),
            w,
            err,
            "delete",
        );
        _ = try fixture.wrote(
            fixture.updateRc(
                h,
                id,
                &.{c.issuez_add_reaction(fixture.str(":+1:"))},
                &fixture.ada,
                null,
                &w,
                &err,
            ),
            w,
            err,
            "react",
        );
        _ = try fixture.wrote(
            fixture.updateRc(
                h,
                id,
                &.{
                    c.issuez_reaction_target(rich.c1),
                    c.issuez_add_reaction(fixture.str("heart")),
                },
                &fixture.ada,
                null,
                &w,
                &err,
            ),
            w,
            err,
            "react",
        );
        _ = try fixture.update(
            h,
            id,
            &.{ locked, fixture.opStr(c.ISSUEZ_FIELD_REF, c.ISSUEZ_OP_SET, "v2") },
        );
        _ = try fixture.update(h, id, &.{
            c.issuez_set_state(fixture.str("closed")),
            c.issuez_set_fixed_by(fixture.str("1a2b3c4")),
            c.issuez_set_release(fixture.str("1.2")),
            c.issuez_set_reason(fixture.str("completed")),
        });
        // Last: a purge rewrites what comes after its comment.
        var pr: ?*c.issuez_purge_result = null;
        try expect.code(
            c.ISSUEZ_OK,
            c.issuez_purge_comment(h, id, &c3, &fixture.ada, fixture.str("abuse"), null, &pr, null),
            null,
        );
        c.issuez_purge_result_free(pr);

        rich.bare = try fixture.titled(h, "Bare");
        // Another tool wrote a due date that doesn't parse.
        try fixture.foreignCommit(&rich.r, rich.bare.idSlice(), "Due\n\nX-Due-Date: someday");
        rich.issue = try fixture.load(h, id);
        rich.plain = try fixture.load(h, rich.bare.idStr());
    }

    fn deinit(rich: *Rich) void {
        c.issuez_issue_free(rich.issue);
        c.issuez_issue_free(rich.plain);
        rich.r.deinit();
    }
};

test "issuez_issue_load, issuez_issue_free: by UUID, missing, not a UUID, damaged" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const made = try fixture.titled(r.handle, "Loaded");
    const issue = try fixture.load(r.handle, made.idStr());
    try expect.str("Loaded", c.issuez_issue_title(issue));
    c.issuez_issue_free(issue);
    c.issuez_issue_free(null);
    var out: ?*c.issuez_issue = null;
    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_issue_load(r.handle, fixture.str(made.idSlice()[0..8]), null, &out, &err),
        err,
    );
    c.issuez_error_free(err);
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_issue_load(r.handle, made.idStr(), null, null, null),
        null,
    );
    // A ref pointing at a blob isn't an issue.
    const blob = try r.git(&.{ "hash-object", "-w", "--stdin" });
    const bad_id = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c";
    _ = try r.git(&.{ "update-ref", "refs/issues/" ++ bad_id, blob });
    err = null;
    try expect.code(
        c.ISSUEZ_E_CORRUPT,
        c.issuez_issue_load(r.handle, fixture.str(bad_id), null, &out, &err),
        err,
    );
    c.issuez_error_free(err);
}

test "issuez_issue_load_many: found, missing, strict" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const a = try fixture.titled(r.handle, "A");
    const b = try fixture.titled(r.handle, "B");
    const missing = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c";
    const ids = [_]c.issuez_str{ a.idStr(), fixture.str(missing), b.idStr(), a.idStr() };
    var list: ?*c.issuez_issue_list = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_issue_load_many(r.handle, &ids, ids.len, 0, null, &list, null),
        null,
    );
    try testing.expectEqual(@as(usize, 3), c.issuez_issue_list_len(list));
    try expect.str("A", c.issuez_issue_title(c.issuez_issue_list_at(list, 0)));
    try expect.str("B", c.issuez_issue_title(c.issuez_issue_list_at(list, 1)));
    try testing.expectEqual(@as(usize, 1), c.issuez_issue_list_skipped_count(list));
    try expect.str(missing, c.issuez_issue_list_skipped_at(list, 0));
    c.issuez_issue_list_free(list);
    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        c.issuez_issue_load_many(
            r.handle,
            &ids,
            ids.len,
            c.ISSUEZ_LOAD_FLAG_STRICT,
            null,
            &list,
            &err,
        ),
        err,
    );
    try expect.str(missing, c.issuez_error_subject(err));
    c.issuez_error_free(err);
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_issue_load_many(r.handle, null, 0, c.ISSUEZ_LOAD_FLAG_STRICT, null, &list, null),
        null,
    );
    try testing.expectEqual(@as(usize, 0), c.issuez_issue_list_len(list));
    c.issuez_issue_list_free(list);
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_issue_load_many(r.handle, null, 0, 1 << 31, null, &list, null),
        null,
    );
}

// covers: issuez_issue_tip, issuez_issue_number, issuez_issue_format_version
// covers: issuez_issue_commit_count
test "issuez_issue_id: identity" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var rich: Rich = undefined;
    try rich.init();
    defer rich.deinit();
    const i = rich.issue;
    try expect.str(rich.x.idSlice(), c.issuez_issue_id(i));
    const tip = c.issuez_issue_tip(i);
    const want = try rich.r.git(
        &.{
            "rev-parse",
            try std.fmt.allocPrint(rich.r.arena(), "refs/issues/{s}", .{rich.x.idSlice()}),
        },
    );
    const hex = fixture.oidHex(tip);
    try testing.expectEqualStrings(want, hex[0..want.len]);
    var n: u64 = 0;
    try testing.expect(c.issuez_issue_number(i, &n));
    try testing.expectEqual(@as(u64, 7), n);
    try testing.expect(!c.issuez_issue_number(rich.plain, &n));
    try expect.str("1", c.issuez_issue_format_version(i));
    const count = try rich.r.git(&.{ "rev-list", "--count", want });
    try testing.expectEqual(try std.fmt.parseInt(u32, count, 10), c.issuez_issue_commit_count(i));
    try testing.expectEqual(@as(u32, 2), c.issuez_issue_commit_count(rich.plain));
    try expect.str("", c.issuez_issue_id(null));
}

// covers: issuez_issue_description, issuez_issue_author, issuez_issue_created
// covers: issuez_issue_updated
test "issuez_issue_title: text and who" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var rich: Rich = undefined;
    try rich.init();
    defer rich.deinit();
    const i = rich.issue;
    try expect.str("Login page crashes", c.issuez_issue_title(i));
    try expect.str("On Safari only.", c.issuez_issue_description(i));
    try expect.str("", c.issuez_issue_description(rich.plain));
    const author = c.issuez_issue_author(i).*;
    try expect.str("Ada", author.name);
    try expect.str("ada@example.invalid", author.email);
    const created = c.issuez_issue_created(i);
    const updated = c.issuez_issue_updated(i);
    try testing.expect(created.unix_seconds > 1_600_000_000);
    try testing.expect(updated.unix_seconds >= created.unix_seconds);
}

// covers: issuez_issue_state_name, issuez_issue_is_done, issuez_issue_closed
// covers: issuez_issue_fixed_by, issuez_issue_release, issuez_issue_reason
test "issuez_issue_state: closing" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var rich: Rich = undefined;
    try rich.init();
    defer rich.deinit();
    const i = rich.issue;
    try testing.expectEqual(@as(c.issuez_state, c.ISSUEZ_STATE_CLOSED), c.issuez_issue_state(i));
    try expect.str("closed", c.issuez_issue_state_name(i));
    try testing.expect(c.issuez_issue_is_done(i));
    var at: c.issuez_time = undefined;
    var by: [*c]const c.issuez_person = null;
    try testing.expect(c.issuez_issue_closed(i, &at, &by));
    try expect.str("ada@example.invalid", by.*.email);
    try expect.str("1a2b3c4", c.issuez_issue_fixed_by(i));
    try expect.str("1.2", c.issuez_issue_release(i));
    try expect.str("completed", c.issuez_issue_reason(i));

    const p = rich.plain;
    try testing.expectEqual(@as(c.issuez_state, c.ISSUEZ_STATE_OPEN), c.issuez_issue_state(p));
    try testing.expect(!c.issuez_issue_is_done(p));
    try testing.expect(!c.issuez_issue_closed(p, &at, &by));
    try expect.str("", c.issuez_issue_fixed_by(p));

    // Another state, done by default; reopened, not closed any more.
    const h = rich.r.handle;
    _ = try fixture.update(h, rich.bare.idStr(), &.{c.issuez_set_state(fixture.str("wontfix"))});
    const wontfix = try fixture.load(h, rich.bare.idStr());
    defer c.issuez_issue_free(wontfix);
    try testing.expectEqual(
        @as(c.issuez_state, c.ISSUEZ_STATE_OTHER),
        c.issuez_issue_state(wontfix),
    );
    try expect.str("wontfix", c.issuez_issue_state_name(wontfix));
    try testing.expect(c.issuez_issue_is_done(wontfix));
    _ = try fixture.update(h, rich.x.idStr(), &.{c.issuez_set_state(fixture.str("open"))});
    const reopened = try fixture.load(h, rich.x.idStr());
    defer c.issuez_issue_free(reopened);
    try testing.expect(!c.issuez_issue_closed(reopened, &at, &by));
    try expect.str("ready", c.issuez_issue_workflow_state(reopened));
}

// covers: issuez_issue_is_deleted, issuez_issue_is_locked, issuez_issue_lock_reason
// covers: issuez_issue_priority, issuez_issue_ref
test "issuez_issue_workflow_state: fields" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var rich: Rich = undefined;
    try rich.init();
    defer rich.deinit();
    const i = rich.issue;
    // Done issues have no workflow state; open ones the default.
    try expect.str("", c.issuez_issue_workflow_state(i));
    try expect.str("backlog", c.issuez_issue_workflow_state(rich.plain));
    try testing.expect(!c.issuez_issue_is_deleted(i));
    try testing.expect(c.issuez_issue_is_locked(i));
    try expect.str("heated", c.issuez_issue_lock_reason(i));
    try testing.expectEqual(
        @as(c.issuez_priority, c.ISSUEZ_PRIORITY_HIGH),
        c.issuez_issue_priority(i),
    );
    try expect.str("v2", c.issuez_issue_ref(i));
    const p = rich.plain;
    try testing.expect(!c.issuez_issue_is_locked(p));
    try expect.str("", c.issuez_issue_lock_reason(p));
    try testing.expectEqual(
        @as(c.issuez_priority, c.ISSUEZ_PRIORITY_UNKNOWN),
        c.issuez_issue_priority(p),
    );
    try expect.str("", c.issuez_issue_ref(p));
    _ = try fixture.update(rich.r.handle, rich.bare.idStr(), &.{c.issuez_set_deleted(true)});
    const deleted = try fixture.load(rich.r.handle, rich.bare.idStr());
    defer c.issuez_issue_free(deleted);
    try testing.expect(c.issuez_issue_is_deleted(deleted));
}

// covers: issuez_issue_label_at, issuez_issue_has_label, issuez_issue_assignee_count
// covers: issuez_issue_assignee_at
test "issuez_issue_label_count: sets" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var rich: Rich = undefined;
    try rich.init();
    defer rich.deinit();
    const i = rich.issue;
    try testing.expectEqual(@as(usize, 2), c.issuez_issue_label_count(i));
    try expect.str("bug", c.issuez_issue_label_at(i, 0));
    try expect.str("ui", c.issuez_issue_label_at(i, 1));
    try expect.str("", c.issuez_issue_label_at(i, 2));
    try testing.expect(c.issuez_issue_has_label(i, fixture.str("ui")));
    try testing.expect(!c.issuez_issue_has_label(i, fixture.str("UI")));
    try testing.expectEqual(@as(usize, 0), c.issuez_issue_label_count(rich.plain));
    try testing.expectEqual(@as(usize, 2), c.issuez_issue_assignee_count(i));
    const first = c.issuez_issue_assignee_at(i, 0).*;
    try expect.str("grace@example.invalid", first.email);
    try expect.str("0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d", first.user_id);
    try expect.str("", first.name);
    try expect.str("ada@example.invalid", c.issuez_issue_assignee_at(i, 1).*.email);
    try expect.str("", c.issuez_issue_assignee_at(i, 1).*.user_id);
    try testing.expect(c.issuez_issue_assignee_at(i, 2) == null);
}

// covers: issuez_issue_parent_id, issuez_issue_blocker_count, issuez_issue_blocker_at
test "issuez_issue_milestone_id: relations" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var rich: Rich = undefined;
    try rich.init();
    defer rich.deinit();
    const i = rich.issue;
    try expect.str(rich.milestone.idSlice(), c.issuez_issue_milestone_id(i));
    try expect.str(rich.parent.idSlice(), c.issuez_issue_parent_id(i));
    try testing.expectEqual(@as(usize, 1), c.issuez_issue_blocker_count(i));
    try expect.str(rich.blocker.idSlice(), c.issuez_issue_blocker_at(i, 0));
    try expect.str("", c.issuez_issue_blocker_at(i, 1));
    try expect.str("", c.issuez_issue_milestone_id(rich.plain));
    try expect.str("", c.issuez_issue_parent_id(rich.plain));
}

// covers: issuez_issue_due_date, issuez_issue_estimate_minutes
test "issuez_issue_start_date: set and unset" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var rich: Rich = undefined;
    try rich.init();
    defer rich.deinit();
    var d: c.issuez_date = undefined;
    try testing.expect(c.issuez_issue_start_date(rich.issue, &d));
    try testing.expectEqual(@as(c_int, 1), @as(c_int, d.day));
    try testing.expect(c.issuez_issue_due_date(rich.issue, &d));
    try testing.expectEqual(@as(c_int, 12), @as(c_int, d.month));
    var m: u32 = 0;
    try testing.expect(c.issuez_issue_estimate_minutes(rich.issue, &m));
    try testing.expectEqual(@as(u32, 90), m);
    try testing.expect(!c.issuez_issue_start_date(rich.plain, &d));
    try testing.expect(!c.issuez_issue_due_date(rich.plain, &d));
    try testing.expect(!c.issuez_issue_estimate_minutes(rich.plain, &m));
}

// covers: issuez_issue_original_id, issuez_issue_field, issuez_issue_extra_count
// covers: issuez_issue_extra_at
test "issuez_issue_original_author: trailers" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var rich: Rich = undefined;
    try rich.init();
    defer rich.deinit();
    const i = rich.issue;
    try expect.str("octo@github", c.issuez_issue_original_author(i));
    try expect.str("gh-12", c.issuez_issue_original_id(i));
    try expect.str("", c.issuez_issue_original_author(rich.plain));
    try expect.str("high", c.issuez_issue_field(i, fixture.str("Priority")));
    try expect.str("3", c.issuez_issue_field(i, fixture.str("X-Forgejo-Project")));
    try expect.str("", c.issuez_issue_field(i, fixture.str("No-Such-Key")));
    try testing.expectEqual(@as(usize, 1), c.issuez_issue_extra_count(i));
    var key: c.issuez_str = undefined;
    var value: c.issuez_str = undefined;
    c.issuez_issue_extra_at(i, 0, &key, &value);
    try expect.str("X-Forgejo-Project", key);
    try expect.str("3", value);
    c.issuez_issue_extra_at(i, 1, &key, &value);
    try expect.str("", key);
    try testing.expectEqual(@as(usize, 0), c.issuez_issue_extra_count(rich.plain));
}

test "issuez_issue_problems: a value another tool wrote that doesn't parse" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var rich: Rich = undefined;
    try rich.init();
    defer rich.deinit();
    try testing.expectEqual(
        @as(usize, 0),
        c.issuez_problems_len(c.issuez_issue_problems(rich.issue)),
    );
    const ps = c.issuez_issue_problems(rich.plain);
    try testing.expectEqual(@as(usize, 1), c.issuez_problems_len(ps));
    const p = c.issuez_problems_at(ps, 0).*;
    try testing.expectEqual(@as(u32, c.ISSUEZ_PROBLEM_INVALID_STORED_VALUE), p.kind);
    try expect.str("X-Due-Date", p.key);
    try expect.str("someday", p.value);
    try testing.expectEqual(@as(i64, -1), p.op_index);
}

// covers: issuez_issue_reaction_at, issuez_reaction_user_at
test "issuez_issue_reaction_count: on the issue and on a comment" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var rich: Rich = undefined;
    try rich.init();
    defer rich.deinit();
    const i = rich.issue;
    try testing.expectEqual(@as(usize, 1), c.issuez_issue_reaction_count(i, null));
    const on_issue = c.issuez_issue_reaction_at(i, null, 0);
    try expect.str(":+1:", on_issue.*.emoji);
    try testing.expectEqual(@as(usize, 1), on_issue.*.user_count);
    try expect.str("ada@example.invalid", c.issuez_reaction_user_at(on_issue, 0).*.email);
    try testing.expect(c.issuez_reaction_user_at(on_issue, 1) == null);
    try testing.expectEqual(@as(usize, 1), c.issuez_issue_reaction_count(i, &rich.c1));
    try expect.str("heart", c.issuez_issue_reaction_at(i, &rich.c1, 0).*.emoji);
    try testing.expectEqual(@as(usize, 0), c.issuez_issue_reaction_count(i, &rich.c2));
    try testing.expect(c.issuez_issue_reaction_at(i, null, 1) == null);
    try testing.expectEqual(@as(usize, 0), c.issuez_issue_reaction_count(rich.plain, null));
}

// covers: issuez_issue_comment_at, issuez_issue_comment_find
test "issuez_issue_comment_count: edited, restored, purged, deleted" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var rich: Rich = undefined;
    try rich.init();
    defer rich.deinit();
    const i = rich.issue;
    try testing.expectEqual(@as(usize, 4), c.issuez_issue_comment_count(i));
    const first = c.issuez_issue_comment_at(i, 0).*;
    try testing.expect(c.issuez_oid_eq(&first.id, &rich.c1));
    try expect.str("Second take", first.text);
    try testing.expect(first.edited and !first.deleted and !first.purged);
    try testing.expect(first.updated.unix_seconds >= first.created.unix_seconds);
    try expect.str("ada@example.invalid", first.author.*.email);
    try testing.expectEqual(@as(usize, 0), first.attachment_count);
    const second = c.issuez_issue_comment_at(i, 1).*;
    try expect.str("Hidden for a while", second.text);
    try testing.expect(!second.deleted);
    const third = c.issuez_issue_comment_at(i, 2).*;
    try testing.expect(third.purged);
    try testing.expect(std.mem.find(u8, fixture.slice(third.text), "Abuse") == null);
    const fourth = c.issuez_issue_comment_at(i, 3).*;
    try testing.expect(fourth.deleted);
    try expect.str("Spam", fourth.text);
    try testing.expect(c.issuez_issue_comment_at(i, 4) == null);
    const found = c.issuez_issue_comment_find(i, &rich.c2);
    try expect.str("Hidden for a while", found.*.text);
    const none = std.mem.zeroes(c.issuez_oid);
    try testing.expect(c.issuez_issue_comment_find(i, &none) == null);
    try testing.expectEqual(@as(usize, 0), c.issuez_issue_comment_count(rich.plain));
}

// covers: issuez_issue_timeline_at, issuez_entry_change_at
test "issuez_issue_timeline_count: every kind of step" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var rich: Rich = undefined;
    try rich.init();
    defer rich.deinit();
    const i = rich.issue;
    const n = c.issuez_issue_timeline_count(i);
    try testing.expectEqual(c.issuez_issue_commit_count(i), @as(u32, @intCast(n)));
    const created = c.issuez_issue_timeline_at(i, 0).*;
    try testing.expectEqual(@as(u32, c.ISSUEZ_ENTRY_CREATED), created.kind);
    try testing.expect(created.change_count > 0);
    var kinds: [16]bool = @splat(false);
    var saw_lock = false;
    for (0..n) |k| {
        const e = c.issuez_issue_timeline_at(i, k).*;
        kinds[e.kind] = true;
        try expect.str("ada@example.invalid", e.author.*.email);
        switch (e.kind) {
            c.ISSUEZ_ENTRY_COMMENT,
            c.ISSUEZ_ENTRY_COMMENT_EDIT,
            c.ISSUEZ_ENTRY_COMMENT_DELETE,
            c.ISSUEZ_ENTRY_COMMENT_RESTORE,
            => try testing.expect(e.comment != null),
            else => {},
        }
        if (e.kind == c.ISSUEZ_ENTRY_COMMENT_EDIT) try testing.expect(
            c.issuez_oid_eq(&e.comment.*.id, &rich.c1),
        );
        for (0..e.change_count) |j| {
            const ch = c.issuez_entry_change_at(c.issuez_issue_timeline_at(i, k), j).*;
            try expect.terminated(ch.key);
            try expect.terminated(ch.old_value);
            try expect.terminated(ch.new_value);
            if (ch.field == c.ISSUEZ_FIELD_LOCKED) saw_lock = true;
        }
        try testing.expect(
            c.issuez_entry_change_at(c.issuez_issue_timeline_at(i, k), e.change_count) == null,
        );
    }
    for ([_]c_uint{
        c.ISSUEZ_ENTRY_COMMENT,      c.ISSUEZ_ENTRY_UPDATE,         c.ISSUEZ_ENTRY_DESCRIPTION_EDIT,
        c.ISSUEZ_ENTRY_COMMENT_EDIT, c.ISSUEZ_ENTRY_COMMENT_DELETE, c.ISSUEZ_ENTRY_COMMENT_RESTORE,
        c.ISSUEZ_ENTRY_REACTION,
    }) |k| testing.expect(kinds[k]) catch |e| {
        std.debug.print("no entry of kind {d}\n", .{k});
        return e;
    };
    try testing.expect(saw_lock);
    try testing.expect(c.issuez_issue_timeline_at(i, n) == null);
    try testing.expect(c.issuez_entry_change_at(null, 0) == null);
}

// covers: issuez_issue_history_at
test "issuez_issue_history_count: the description and comments, version by version" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var rich: Rich = undefined;
    try rich.init();
    defer rich.deinit();
    const i = rich.issue;
    try testing.expectEqual(@as(usize, 2), c.issuez_issue_history_count(i, null));
    const orig = c.issuez_issue_history_at(i, null, 0).*;
    try testing.expectEqual(@as(u32, c.ISSUEZ_REVISION_ORIGINAL), orig.kind);
    try expect.str("On Safari.\n\nEvery time.", orig.text);
    try testing.expectEqual(
        @as(u32, c.ISSUEZ_REVISION_EDIT),
        c.issuez_issue_history_at(i, null, 1).*.kind,
    );
    try testing.expectEqual(@as(usize, 2), c.issuez_issue_history_count(i, &rich.c1));
    try expect.str("First take", c.issuez_issue_history_at(i, &rich.c1, 0).*.text);
    try expect.str("Second take", c.issuez_issue_history_at(i, &rich.c1, 1).*.text);
    try testing.expectEqual(@as(usize, 3), c.issuez_issue_history_count(i, &rich.c2));
    try testing.expectEqual(
        @as(u32, c.ISSUEZ_REVISION_DELETE),
        c.issuez_issue_history_at(i, &rich.c2, 1).*.kind,
    );
    try testing.expectEqual(
        @as(u32, c.ISSUEZ_REVISION_RESTORE),
        c.issuez_issue_history_at(i, &rich.c2, 2).*.kind,
    );
    try expect.str(
        "ada@example.invalid",
        c.issuez_issue_history_at(i, &rich.c2, 2).*.author.*.email,
    );
    try testing.expect(c.issuez_issue_history_at(i, &rich.c2, 3) == null);
    const none = std.mem.zeroes(c.issuez_oid);
    try testing.expectEqual(@as(usize, 0), c.issuez_issue_history_count(i, &none));
    try testing.expectEqual(@as(usize, 1), c.issuez_issue_history_count(rich.plain, null));
}

test "issuez_issue_load_since, issuez_issue_rewritten: entries new since a tip" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const x = try fixture.titled(h, "Since");
    const other = try fixture.titled(h, "Other");
    const first = try fixture.comment(h, x.idStr(), "First");
    const second = try fixture.comment(h, x.idStr(), "Second");
    var err: ?*c.issuez_error = null;

    var i: ?*c.issuez_issue = null;
    try testing.expectEqual(
        @as(c.issuez_code, c.ISSUEZ_OK),
        c.issuez_issue_load_since(h, x.idStr(), &first.commit, null, &i, &err),
    );
    try testing.expect(!c.issuez_issue_rewritten(i));
    try testing.expectEqual(@as(usize, 3), c.issuez_issue_timeline_count(i));
    try testing.expect(!c.issuez_issue_timeline_at(i, 0).*.is_new);
    try testing.expect(!c.issuez_issue_timeline_at(i, 1).*.is_new);
    const last = c.issuez_issue_timeline_at(i, 2).*;
    try testing.expect(last.is_new and c.issuez_oid_eq(&last.commit, &second.commit));
    c.issuez_issue_free(i);

    // No since: every entry is new, as from issuez_issue_load.
    try testing.expectEqual(
        @as(c.issuez_code, c.ISSUEZ_OK),
        c.issuez_issue_load_since(h, x.idStr(), null, null, &i, &err),
    );
    for (0..3) |k| try testing.expect(c.issuez_issue_timeline_at(i, k).*.is_new);
    c.issuez_issue_free(i);
    const plain = try fixture.load(h, x.idStr());
    try testing.expect(
        c.issuez_issue_timeline_at(plain, 2).*.is_new and !c.issuez_issue_rewritten(plain),
    );
    c.issuez_issue_free(plain);

    // Another issue's tip isn't in this history.
    try testing.expectEqual(
        @as(c.issuez_code, c.ISSUEZ_OK),
        c.issuez_issue_load_since(h, x.idStr(), &other.tip, null, &i, &err),
    );
    try testing.expect(c.issuez_issue_rewritten(i));
    for (0..3) |k| try testing.expect(!c.issuez_issue_timeline_at(i, k).*.is_new);
    c.issuez_issue_free(i);

    try testing.expectEqual(
        @as(c.issuez_code, c.ISSUEZ_E_INVALID_ARGUMENT),
        c.issuez_issue_load_since(h, fixture.str("x"), null, null, &i, null),
    );
    try testing.expect(!c.issuez_issue_rewritten(null));
}

/// The changes of timeline entry k.
fn changesAt(i: *c.issuez_issue, k: usize) []const c.issuez_change {
    const e = c.issuez_issue_timeline_at(i, k);
    var out: [16]c.issuez_change = undefined;
    const n = e.*.change_count;
    for (0..n) |j| out[j] = c.issuez_entry_change_at(e, j).*;
    return out[0..n];
}

fn changeOf(list: []const c.issuez_change, field: c_uint) ?c.issuez_change {
    for (list) |ch| if (ch.field == field) return ch;
    return null;
}

test "issuez_entry_change_at: one change per field, unsaid values filled in, typed values" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const x = try fixture.titled(h, "First title");
    const id = x.idStr();
    _ = try fixture.update(h, id, &.{c.issuez_set_title(fixture.str("Second title"))});
    _ = try fixture.update(h, id, &.{c.issuez_add_assignee(grace)});
    _ = try fixture.update(
        h,
        id,
        &.{c.issuez_set_due_date(.{ .year = 2026, .month = 12, .day = 1 })},
    );
    var locked = fixture.opNum(c.ISSUEZ_FIELD_LOCKED, 1);
    locked.str = fixture.str("heated");
    _ = try fixture.update(h, id, &.{locked});
    _ = try fixture.update(h, id, &.{c.issuez_set_state(fixture.str("wontfix"))});
    const i = try fixture.load(h, id);
    defer c.issuez_issue_free(i);
    try testing.expectEqual(@as(usize, 6), c.issuez_issue_timeline_count(i));

    // The first Title says nothing of the root's subject; the change does.
    const title = changeOf(changesAt(i, 1), c.ISSUEZ_FIELD_TITLE).?;
    try expect.str("First title", title.old_value);
    try expect.str("Second title", title.new_value);

    // One change for the assignee, parsed, however many trailers said it.
    const assigned = changesAt(i, 2);
    var n_assignees: usize = 0;
    for (assigned) |ch| if (ch.field == c.ISSUEZ_FIELD_ASSIGNEES) {
        n_assignees += 1;
    };
    try testing.expectEqual(@as(usize, 1), n_assignees);
    const who = changeOf(assigned, c.ISSUEZ_FIELD_ASSIGNEES).?;
    try testing.expect(who.old_person == null);
    try expect.str("grace@example.invalid", who.new_person.*.email);
    try expect.str("0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d", who.new_person.*.user_id);

    const due = changeOf(changesAt(i, 3), c.ISSUEZ_FIELD_DUE_DATE).?;
    try testing.expectEqual(@as(i16, 0), due.old_date.year);
    try testing.expectEqual(@as(i16, 2026), due.new_date.year);
    try testing.expectEqual(@as(u8, 12), due.new_date.month);

    // The lock carries its reason; the reason has a field of its own.
    const lock = changesAt(i, 4);
    try expect.str("heated", changeOf(lock, c.ISSUEZ_FIELD_LOCKED).?.reason);
    try testing.expect(changeOf(lock, c.ISSUEZ_FIELD_LOCK_REASON) != null);

    // wontfix is a done state by default; the first State is from open.
    const state = changeOf(changesAt(i, 5), c.ISSUEZ_FIELD_STATE).?;
    try expect.str("open", state.old_value);
    try testing.expect(!state.old_done and state.new_done);
}

test "issuez_issue_json, issuez_issue_json_many: the documented JSON" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const x = try fixture.create(
        h,
        &.{
            c.issuez_set_title(fixture.str("As JSON")),
            c.issuez_set_description(fixture.str("Body")),
        },
    );
    const y = try fixture.titled(h, "Second");
    var b: ?*c.issuez_bytes = null;
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_issue_json(h, x.idStr(), 1 << 31, null, &b, null),
        null,
    );
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_issue_json(h, x.idStr(), c.ISSUEZ_JSON_FLAG_FULL, null, &b, null),
        null,
    );
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const one = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        fixture.slice(c.issuez_bytes_data(b)),
        .{},
    );
    c.issuez_bytes_free(b);
    try testing.expectEqualStrings("As JSON", one.object.get("title").?.string);
    try testing.expectEqualStrings("Body", one.object.get("description").?.string);
    const ids = [_]c.issuez_str{ y.idStr(), x.idStr() };
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_issue_json_many(h, &ids, ids.len, 0, null, &b, null),
        null,
    );
    const two = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        fixture.slice(c.issuez_bytes_data(b)),
        .{},
    );
    c.issuez_bytes_free(b);
    try testing.expectEqual(@as(usize, 2), two.array.items.len);
    try testing.expectEqualStrings("Second", two.array.items[0].object.get("title").?.string);
    try expect.code(c.ISSUEZ_OK, c.issuez_issue_json_many(h, null, 0, 0, null, &b, null), null);
    const all = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        fixture.slice(c.issuez_bytes_data(b)),
        .{},
    );
    c.issuez_bytes_free(b);
    try testing.expectEqual(@as(usize, 2), all.array.items.len);
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        c.issuez_issue_json(
            h,
            fixture.str("0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c"),
            0,
            null,
            &b,
            null,
        ),
        null,
    );
}

//! Reading issues: one issue with every field,
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
    blocker: fixture.Created,
    c1: c.issuez_oid,
    c2: c.issuez_oid,
    issue: *c.issuez_issue,
    plain: *c.issuez_issue,

    fn init() !Rich {
        var rich: Rich = undefined;
        rich.r = try fixture.Repo.init(.{});
        errdefer rich.r.deinit();
        const h = rich.r.handle;
        const parent = try fixture.titled(h, "Parent");
        rich.blocker = try fixture.titled(h, "Blocker");
        const milestone = try fixture.milestone(h, "v1");
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
            c.issuez_set_milestone(milestone.idStr()),
            c.issuez_set_parent(parent.idStr()),
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
        return rich;
    }

    fn deinit(rich: *Rich) void {
        c.issuez_issue_free(rich.issue);
        c.issuez_issue_free(rich.plain);
        rich.r.deinit();
    }
};

test "issuez_issue_load, issuez_issue_free: by UUID, missing, not a UUID, damaged" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const made = try fixture.titled(r.handle, "Loaded");
    const issue = try fixture.load(r.handle, made.idStr());
    try expect.str("Loaded", c.issuez_issue_info_of(issue).*.title);
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

const lin_id = "7d1f0a34-2b6c-4e8d-a1f3-9c0b5d7e6f21";

/// Someone writing at a time and in a zone of their own.
fn at(
    name: []const u8,
    email: []const u8,
    id: []const u8,
    when: *const c.issuez_time,
) c.issuez_actor {
    return .{
        .name = fixture.str(name),
        .email = fixture.str(email),
        .user_id = fixture.str(id),
        .at = when,
        .reserved = .{ 0, 0, 0, 0 },
    };
}

// C fills the record by hand: no two fields here hold the same value, so a swapped field fails.
test "issuez_issue_info_of: every value of a closed, locked issue" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const h = r.handle;
    const parent = try fixture.titled(h, "Parent");
    const milestone = try fixture.milestone(h, "v1");
    const t1: c.issuez_time = .{ .unix_seconds = 1_700_000_000, .tz_offset_minutes = 60 };
    const t2: c.issuez_time = .{ .unix_seconds = 1_700_000_500, .tz_offset_minutes = 120 };
    const t3: c.issuez_time = .{ .unix_seconds = 1_700_001_000, .tz_offset_minutes = -180 };
    const opener = at("Ada", "ada@example.invalid", "", &t1);
    const closer = at("Grace", "grace@example.invalid", "", &t2);
    const last = at("Lin", "lin@example.invalid", lin_id, &t3);
    const create_ops = [_]c.issuez_op{
        c.issuez_set_title(fixture.str("Login page crashes")),
        c.issuez_set_description(fixture.str("On Safari.")),
        c.issuez_set_priority(c.ISSUEZ_PRIORITY_HIGH),
        c.issuez_set_milestone(milestone.idStr()),
        c.issuez_set_parent(parent.idStr()),
        c.issuez_set_start_date(.{ .year = 2026, .month = 11, .day = 1 }),
        c.issuez_set_due_date(.{ .year = 2027, .month = 12, .day = 31 }),
        c.issuez_set_estimate(90),
        c.issuez_set_number(7),
        fixture.opStr(c.ISSUEZ_OPT_ORIGINAL_AUTHOR, c.ISSUEZ_OP_SET, "octo@github"),
        fixture.opStr(c.ISSUEZ_OPT_ORIGINAL_ID, c.ISSUEZ_OP_SET, "gh-12"),
    };
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_issue_create(h, &create_ops, create_ops.len, &opener, null, &w, &err),
        err,
    );
    var id_buf: [36]u8 = undefined;
    @memcpy(&id_buf, fixture.slice(c.issuez_write_id(w)));
    c.issuez_write_free(w);
    const id = fixture.str(&id_buf);
    var locked = fixture.opNum(c.ISSUEZ_FIELD_LOCKED, 1);
    locked.str = fixture.str("heated");
    _ = try fixture.wrote(
        fixture.updateRc(h, id, &.{
            c.issuez_set_state(fixture.str("closed")),
            c.issuez_set_fixed_by(fixture.str("1a2b3c4")),
            c.issuez_set_release(fixture.str("1.2")),
            c.issuez_set_reason(fixture.str("completed")),
            fixture.opStr(c.ISSUEZ_FIELD_REF, c.ISSUEZ_OP_SET, "v2"),
            locked,
        }, &closer, null, &w, &err),
        w,
        err,
        "close",
    );
    _ = try fixture.wrote(
        fixture.updateRc(
            h,
            id,
            &.{c.issuez_set_comment(fixture.str("Late"))},
            &last,
            null,
            &w,
            &err,
        ),
        w,
        err,
        "comment",
    );

    const issue = try fixture.load(h, id);
    defer c.issuez_issue_free(issue);
    const info = c.issuez_issue_info_of(issue);
    try testing.expect(c.issuez_issue_info_of(issue) == info);
    try expect.str(&id_buf, info.*.id);
    const ref = try std.fmt.allocPrint(r.arena(), "refs/issues/{s}", .{id_buf});
    const want_tip = try r.git(&.{ "rev-parse", ref });
    try testing.expectEqualStrings(want_tip, fixture.oidHex(info.*.tip)[0..want_tip.len]);
    try testing.expect(info.*.has_number);
    try testing.expectEqual(@as(u64, 7), info.*.number);
    try expect.str("1", info.*.format_version);
    try testing.expectEqual(@as(u32, 3), info.*.commit_count);
    try expect.str("Login page crashes", info.*.title);
    try expect.str("On Safari.", info.*.description);
    try expect.str("Ada", info.*.author.*.name);
    try expect.str("ada@example.invalid", info.*.author.*.email);
    try testing.expectEqual(t1, info.*.created);
    try testing.expectEqual(t3, info.*.updated);
    try testing.expectEqual(@as(u32, c.ISSUEZ_STATE_CLOSED), info.*.state);
    try expect.str("closed", info.*.state_name);
    try testing.expect(info.*.is_done);
    try expect.str("grace@example.invalid", info.*.closed_by.*.email);
    try testing.expectEqual(t2, info.*.closed_at);
    try expect.str("1a2b3c4", info.*.fixed_by);
    try expect.str("1.2", info.*.release);
    try expect.str("completed", info.*.reason);
    try testing.expect(info.*.is_locked);
    try expect.str("heated", info.*.lock_reason);
    try testing.expectEqual(@as(u32, c.ISSUEZ_PRIORITY_HIGH), info.*.priority);
    try expect.str(milestone.idSlice(), info.*.milestone_id);
    try expect.str(parent.idSlice(), info.*.parent_id);
    try testing.expectEqual(
        c.issuez_date{ .year = 2026, .month = 11, .day = 1 },
        info.*.start_date,
    );
    try testing.expectEqual(c.issuez_date{ .year = 2027, .month = 12, .day = 31 }, info.*.due_date);
    try testing.expect(info.*.has_estimate_minutes);
    try testing.expectEqual(@as(u32, 90), info.*.estimate_minutes);
    try expect.str("v2", info.*.ref);
    try expect.str("octo@github", info.*.original_author);
    try expect.str("gh-12", info.*.original_id);
    // The next test's is_deleted and the load_since test's rewritten set them.
    try testing.expect(!info.*.is_deleted and !info.*.rewritten);
}

test "issuez_issue_info_of: a deleted open issue with nothing else set, and NULL" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const h = r.handle;
    const x = try fixture.titled(h, "Bare");
    _ = try fixture.update(h, x.idStr(), &.{c.issuez_set_deleted(true)});
    const issue = try fixture.load(h, x.idStr());
    defer c.issuez_issue_free(issue);
    const info = c.issuez_issue_info_of(issue);
    try testing.expect(info.*.is_deleted);
    try testing.expect(!info.*.is_done and !info.*.is_locked and !info.*.rewritten);
    try testing.expectEqual(@as(u32, c.ISSUEZ_STATE_OPEN), info.*.state);
    // Open: the default workflow state, nobody closed it.
    try expect.str("backlog", info.*.workflow_state);
    try testing.expect(info.*.closed_by == null);
    try testing.expectEqual(std.mem.zeroes(c.issuez_time), info.*.closed_at);
    try testing.expect(!info.*.has_number and !info.*.has_estimate_minutes);
    try testing.expectEqual(@as(u64, 0), info.*.number);
    try testing.expectEqual(@as(u32, 0), info.*.estimate_minutes);
    try testing.expectEqual(std.mem.zeroes(c.issuez_date), info.*.start_date);
    try testing.expectEqual(std.mem.zeroes(c.issuez_date), info.*.due_date);
    try testing.expectEqual(@as(u32, c.ISSUEZ_PRIORITY_UNKNOWN), info.*.priority);
    // A description is always there, if empty; these are absent, {NULL,0}.
    try testing.expect(info.*.description.ptr != null);
    try expect.str("", info.*.description);
    for ([_]c.issuez_str{
        info.*.fixed_by,     info.*.release,   info.*.reason, info.*.lock_reason,
        info.*.milestone_id, info.*.parent_id, info.*.ref,    info.*.original_author,
        info.*.original_id,
    }) |absent| try testing.expect(absent.ptr == null and absent.len == 0);
    try testing.expect(c.issuez_issue_info_of(null) == null);
}

test "issuez_issue_info_of: each optional is there on its own, an estimate of 0 included" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const h = r.handle;
    const zero = try fixture.create(h, &.{
        c.issuez_set_title(fixture.str("Zero")),
        c.issuez_set_estimate(0),
        c.issuez_set_due_date(.{ .year = 2026, .month = 12, .day = 1 }),
    });
    const first = try fixture.load(h, zero.idStr());
    defer c.issuez_issue_free(first);
    const a = c.issuez_issue_info_of(first);
    try testing.expect(a.*.has_estimate_minutes and !a.*.has_number);
    try testing.expectEqual(@as(u32, 0), a.*.estimate_minutes);
    try testing.expectEqual(@as(i16, 2026), a.*.due_date.year);
    try testing.expectEqual(@as(i16, 0), a.*.start_date.year);
    const numbered = try fixture.create(h, &.{
        c.issuez_set_title(fixture.str("Numbered")),
        c.issuez_set_number(3),
        c.issuez_set_start_date(.{ .year = 2026, .month = 11, .day = 1 }),
    });
    const second = try fixture.load(h, numbered.idStr());
    defer c.issuez_issue_free(second);
    const b = c.issuez_issue_info_of(second);
    try testing.expect(b.*.has_number and !b.*.has_estimate_minutes);
    try testing.expectEqual(@as(i16, 2026), b.*.start_date.year);
    try testing.expectEqual(@as(i16, 0), b.*.due_date.year);
}

test "issuez_issue_info_of: a done state of the repo, then reopened" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const h = r.handle;
    const x = try fixture.create(h, &.{
        c.issuez_set_title(fixture.str("Ready")),
        c.issuez_set_workflow_state(fixture.str("ready")),
    });
    _ = try fixture.update(h, x.idStr(), &.{c.issuez_set_state(fixture.str("wontfix"))});
    const wontfix = try fixture.load(h, x.idStr());
    defer c.issuez_issue_free(wontfix);
    const done = c.issuez_issue_info_of(wontfix);
    try testing.expectEqual(@as(u32, c.ISSUEZ_STATE_OTHER), done.*.state);
    try expect.str("wontfix", done.*.state_name);
    try testing.expect(done.*.is_done and done.*.closed_by != null);
    try testing.expect(done.*.workflow_state.ptr == null);
    _ = try fixture.update(h, x.idStr(), &.{c.issuez_set_state(fixture.str("open"))});
    const reopened = try fixture.load(h, x.idStr());
    defer c.issuez_issue_free(reopened);
    const open = c.issuez_issue_info_of(reopened);
    try testing.expect(!open.*.is_done and open.*.closed_by == null);
    try expect.str("ready", open.*.workflow_state);
}

// covers: issuez_issue_label_at, issuez_issue_assignee_count
// covers: issuez_issue_assignee_at
test "issuez_issue_label_count: sets" {
    var rich = try Rich.init();
    defer rich.deinit();
    const i = rich.issue;
    try testing.expectEqual(@as(usize, 2), c.issuez_issue_label_count(i));
    try expect.str("bug", c.issuez_issue_label_at(i, 0));
    try expect.str("ui", c.issuez_issue_label_at(i, 1));
    try expect.str("", c.issuez_issue_label_at(i, 2));
    try testing.expect(fixture.hasLabel(i, "ui"));
    try testing.expect(!fixture.hasLabel(i, "UI"));
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

// covers: issuez_issue_blocker_at
test "issuez_issue_blocker_count: relations" {
    var rich = try Rich.init();
    defer rich.deinit();
    const i = rich.issue;
    try testing.expectEqual(@as(usize, 1), c.issuez_issue_blocker_count(i));
    try expect.str(rich.blocker.idSlice(), c.issuez_issue_blocker_at(i, 0));
    try expect.str("", c.issuez_issue_blocker_at(i, 1));
}

// covers: issuez_issue_extra_at
test "issuez_issue_extra_count: trailers the library doesn't interpret" {
    var rich = try Rich.init();
    defer rich.deinit();
    const i = rich.issue;
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
    var rich = try Rich.init();
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
    // Ignored: the record has no date.
    try testing.expectEqual(@as(i16, 0), c.issuez_issue_info_of(rich.plain).*.due_date.year);
}

// covers: issuez_issue_reaction_at, issuez_reaction_user_at
test "issuez_issue_reaction_count: on the issue and on a comment" {
    var rich = try Rich.init();
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

// covers: issuez_issue_comment_at
test "issuez_issue_comment_count: edited, restored, purged, deleted" {
    var rich = try Rich.init();
    defer rich.deinit();
    const i = rich.issue;
    try testing.expectEqual(@as(usize, 4), c.issuez_issue_comment_count(i));
    const first = c.issuez_issue_comment_at(i, 0).*;
    try testing.expect(fixture.oidEql(first.id, rich.c1));
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
    const found = fixture.findComment(i, rich.c2);
    try expect.str("Hidden for a while", found.?.text);
    try testing.expectEqual(@as(usize, 0), c.issuez_issue_comment_count(rich.plain));
}

// covers: issuez_issue_timeline_at, issuez_entry_change_at
test "issuez_issue_timeline_count: every kind of step" {
    var rich = try Rich.init();
    defer rich.deinit();
    const i = rich.issue;
    const n = c.issuez_issue_timeline_count(i);
    try testing.expectEqual(c.issuez_issue_info_of(i).*.commit_count, @as(u32, @intCast(n)));
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
            fixture.oidEql(e.comment.*.id, rich.c1),
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
    var rich = try Rich.init();
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

test "issuez_issue_load_since: entries new since a tip" {
    var r = try fixture.Repo.init(.{});
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
    try testing.expect(!c.issuez_issue_info_of(i).*.rewritten);
    try testing.expectEqual(@as(usize, 3), c.issuez_issue_timeline_count(i));
    try testing.expect(!c.issuez_issue_timeline_at(i, 0).*.is_new);
    try testing.expect(!c.issuez_issue_timeline_at(i, 1).*.is_new);
    const last = c.issuez_issue_timeline_at(i, 2).*;
    try testing.expect(last.is_new and fixture.oidEql(last.commit, second.commit));
    c.issuez_issue_free(i);

    // No since: every entry is new, as from issuez_issue_load.
    try testing.expectEqual(
        @as(c.issuez_code, c.ISSUEZ_OK),
        c.issuez_issue_load_since(h, x.idStr(), null, null, &i, &err),
    );
    for (0..3) |k| try testing.expect(c.issuez_issue_timeline_at(i, k).*.is_new);
    c.issuez_issue_free(i);
    const plain = try fixture.load(h, x.idStr());
    try testing.expect(c.issuez_issue_timeline_at(plain, 2).*.is_new);
    try testing.expect(!c.issuez_issue_info_of(plain).*.rewritten);
    c.issuez_issue_free(plain);

    // Another issue's tip isn't in this history.
    try testing.expectEqual(
        @as(c.issuez_code, c.ISSUEZ_OK),
        c.issuez_issue_load_since(h, x.idStr(), &other.tip, null, &i, &err),
    );
    try testing.expect(c.issuez_issue_info_of(i).*.rewritten);
    for (0..3) |k| try testing.expect(!c.issuez_issue_timeline_at(i, k).*.is_new);
    c.issuez_issue_free(i);

    try testing.expectEqual(
        @as(c.issuez_code, c.ISSUEZ_E_INVALID_ARGUMENT),
        c.issuez_issue_load_since(h, fixture.str("x"), null, null, &i, null),
    );
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
    var r = try fixture.Repo.init(.{});
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

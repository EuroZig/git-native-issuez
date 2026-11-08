//! Purges, and handles outliving what made them.

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

test "issuez_purge_issue: the actor's user_id is on the tombstone, and must be a UUID" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const x = try fixture.titled(h, "Doxxing");
    const uuid = "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d";
    var actor = fixture.ada;
    var pr: ?*c.issuez_purge_result = null;
    var err: ?*c.issuez_error = null;

    actor.user_id = fixture.str("not a uuid");
    try testing.expect(
        c.issuez_purge_issue(h, x.idStr(), &actor, fixture.str(""), null, &pr, &err) ==
            c.ISSUEZ_E_INVALID_ARGUMENT,
    );
    c.issuez_error_free(err);
    err = null;

    actor.user_id = fixture.str(uuid);
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_purge_issue(h, x.idStr(), &actor, fixture.str(""), null, &pr, &err),
        err,
    );
    c.issuez_purge_result_free(pr);
    const message = try r.git(&.{
        "log",
        "-1",
        "--format=%B",
        try std.fmt.allocPrint(r.arena(), "refs/issuez-purged/{s}", .{x.idSlice()}),
    });
    try testing.expect(std.mem.find(u8, message, "X-Author-Id: " ++ uuid) != null);
}

test "issuez_purge_result_exposed_remote_at: a remote synced by URL" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const path = try fixture.hub(&r, "hub.git");
    _ = try r.git(&.{ "remote", "remove", "origin" });
    const x = try fixture.titled(h, "Doxxing");
    var out: ?*c.issuez_sync_report = null;
    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_sync(h, fixture.str(path), null, 0, null, &out, &err),
        err,
    );
    c.issuez_sync_report_free(out);

    var pr: ?*c.issuez_purge_result = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_purge_issue(h, x.idStr(), &fixture.ada, fixture.str(""), null, &pr, &err),
        err,
    );
    defer c.issuez_purge_result_free(pr);
    try testing.expectEqual(@as(usize, 1), c.issuez_purge_result_exposed_remote_count(pr));
    const name = c.issuez_purge_result_exposed_remote_at(pr, 0);
    try testing.expect(std.mem.startsWith(u8, name.ptr[0..name.len], "url-"));
}

// covers: issuez_purge_result_free, issuez_purge_result_new_tip
// covers: issuez_purge_result_exposed_remote_count, issuez_purge_result_exposed_remote_at
test "issuez_purge_issue: an issue a remote saw" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    _ = try fixture.hub(&r, "hub.git");
    const x = try fixture.create(
        h,
        &.{ c.issuez_set_title(fixture.str("Doxxing")), c.issuez_set_number(4) },
    );
    const local_only = try fixture.titled(h, "Never pushed");
    (try fixture.sync(h, &.{})).deinit();
    _ = local_only;

    var pr: ?*c.issuez_purge_result = null;
    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_purge_issue(h, x.idStr(), &fixture.ada, fixture.str("legal"), null, &pr, &err),
        err,
    );
    try testing.expectEqual(@as(u8, 0), c.issuez_purge_result_new_tip(pr).len);
    try testing.expectEqual(@as(usize, 1), c.issuez_purge_result_exposed_remote_count(pr));
    try expect.str("origin", c.issuez_purge_result_exposed_remote_at(pr, 0));
    try expect.str("", c.issuez_purge_result_exposed_remote_at(pr, 1));
    c.issuez_purge_result_free(pr);
    c.issuez_purge_result_free(null);
    try testing.expectEqual(@as(usize, 0), c.issuez_purge_result_exposed_remote_count(null));
    try testing.expectEqual(@as(u8, 0), c.issuez_purge_result_new_tip(null).len);

    // Gone, with its tombstone; its number is free again.
    var out: ?*c.issuez_issue = null;
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        c.issuez_issue_load(h, x.idStr(), null, &out, null),
        null,
    );
    const why = try r.git(
        &.{
            "log",
            "-1",
            "--format=%an %B",
            try std.fmt.allocPrint(r.arena(), "refs/issuez-purged/{s}", .{x.idSlice()}),
        },
    );
    try testing.expect(std.mem.find(u8, why, "Ada") != null);
    try testing.expect(std.mem.find(u8, why, "Reason: legal") != null);
    _ = try fixture.create(
        h,
        &.{ c.issuez_set_title(fixture.str("Four again")), c.issuez_set_number(4) },
    );

    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        c.issuez_purge_issue(h, x.idStr(), &fixture.ada, fixture.str(""), null, &pr, &err),
        err,
    );
    c.issuez_error_free(err);
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_purge_issue(h, fixture.str("abc"), &fixture.ada, fixture.str(""), null, &pr, null),
        null,
    );
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_purge_issue(h, x.idStr(), &fixture.ada, fixture.str(""), null, null, null),
        null,
    );
}

test "issuez_purge_comment: the text goes, the fields stay, later commits move" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const x = try fixture.titled(h, "Moderated");
    var w: ?*c.issuez_write = null;
    const ops = [_]c.issuez_op{
        c.issuez_set_comment(fixture.str("Abuse")),
        c.issuez_add_label(fixture.str("kept")),
    };
    const bad = try fixture.wrote(
        c.issuez_issue_update(h, x.idStr(), &ops, ops.len, &fixture.ada, null, &w, null),
        w,
        null,
        "comment",
    );
    const later = try fixture.comment(h, x.idStr(), "Fine");
    var pr: ?*c.issuez_purge_result = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_purge_comment(
            h,
            x.idStr(),
            &bad.commit,
            &fixture.ada,
            fixture.str("abuse"),
            null,
            &pr,
            null,
        ),
        null,
    );
    const new_tip = c.issuez_purge_result_new_tip(pr);
    try testing.expect(new_tip.len > 0 and !c.issuez_oid_eq(&new_tip, &later.tip));
    try testing.expectEqual(@as(usize, 0), c.issuez_purge_result_exposed_remote_count(pr));
    c.issuez_purge_result_free(pr);
    const i = try fixture.load(h, x.idStr());
    defer c.issuez_issue_free(i);
    const tip = c.issuez_issue_tip(i);
    try testing.expect(c.issuez_oid_eq(&tip, &new_tip));
    try testing.expect(c.issuez_issue_comment_at(i, 0).*.purged);
    try testing.expect(c.issuez_issue_has_label(i, fixture.str("kept")));
    try expect.str("Fine", c.issuez_issue_comment_at(i, 1).*.text);

    // The root holds the title: purge the issue instead. Not a full oid.
    var err: ?*c.issuez_error = null;
    try testing.expect(
        c.issuez_purge_comment(
            h,
            x.idStr(),
            &x.tip,
            &fixture.ada,
            fixture.str(""),
            null,
            &pr,
            &err,
        ) != c.ISSUEZ_OK,
    );
    c.issuez_error_free(err);
    const none = std.mem.zeroes(c.issuez_oid);
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_purge_comment(h, x.idStr(), &none, &fixture.ada, fixture.str(""), null, &pr, null),
        null,
    );
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_purge_comment(h, x.idStr(), null, &fixture.ada, fixture.str(""), null, &pr, null),
        null,
    );
}

test "lifetime: results outlive the repo and each other, freed in any order" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const made = try fixture.titled(r.handle, "Kept");
    const h = try r.open(&.{});
    var issue: ?*c.issuez_issue = null;
    var list: ?*c.issuez_issue_list = null;
    var proj: ?*c.issuez_projection = null;
    var snap: ?*c.issuez_snapshot = null;
    var ms: ?*c.issuez_milestone_list = null;
    var w: ?*c.issuez_write = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_issue_load(h, made.idStr(), null, &issue, null), null);
    var q = [_]c.issuez_op{c.issuez_q_done(-1)};
    try expect.code(c.ISSUEZ_OK, c.issuez_query_run(h, &q, 1, null, &list, null), null);
    try expect.code(c.ISSUEZ_OK, c.issuez_projection_build(h, null, &proj, null), null);
    try expect.code(c.ISSUEZ_OK, c.issuez_snapshot_take(h, null, &snap, null), null);
    try expect.code(c.ISSUEZ_OK, c.issuez_milestone_list_all(h, null, &ms, null), null);
    const ops = [_]c.issuez_op{c.issuez_add_label(fixture.str("late"))};
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_issue_update(h, made.idStr(), &ops, 1, &fixture.ada, null, &w, null),
        null,
    );
    c.issuez_repo_close(h);
    // All still readable, and a receipt can still load its issue.
    try expect.str("Kept", c.issuez_issue_title(issue));
    try expect.str(
        "Kept",
        c.issuez_issue_title(c.issuez_issue_list_at(c.issuez_projection_issues(proj), 0)),
    );
    try testing.expectEqual(@as(usize, 1), c.issuez_snapshot_len(snap));
    var after: ?*c.issuez_issue = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_write_load_issue(w, null, &after, null), null);
    try testing.expect(c.issuez_issue_has_label(after, fixture.str("late")));
    c.issuez_write_free(w);
    c.issuez_projection_free(proj);
    c.issuez_issue_free(issue);
    c.issuez_milestone_list_free(ms);
    c.issuez_issue_free(after);
    c.issuez_snapshot_free(snap);
    try expect.str("Kept", c.issuez_issue_title(c.issuez_issue_list_at(list, 0)));
    c.issuez_issue_list_free(list);
}

// covers: issuez_purge_result_attachment_at
test "issuez_purge_result_attachment_count: the attachments a purge takes" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{ .ops = &.{fixture.opNum(c.ISSUEZ_OPT_ATTACHMENT_STORE, 0)} });
    defer r.deinit();
    const h = r.handle;
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01" ++
        "\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x00IEND\xaeB`\x82";
    const shot = "5b0c4e0e-2b8a-4f5e-9d39-6c1c1f0f2a77";
    const photo = "6c1d5f1f-3c9b-4a6f-8e4a-7d2d2a1a3b88";
    const attach = struct {
        fn op(id: []const u8) c.issuez_op {
            var o = fixture.opStr(c.ISSUEZ_FIELD_ATTACHMENTS, c.ISSUEZ_OP_ADD, png);
            o.name = fixture.str("a.png");
            o.id = fixture.str(id);
            return o;
        }
    }.op;
    const x = try fixture.create(
        h,
        &.{ c.issuez_set_title(fixture.str("Pictured")), attach(shot) },
    );
    var w: ?*c.issuez_write = null;
    const ops = [_]c.issuez_op{ c.issuez_set_comment(fixture.str("Look")), attach(photo) };
    const said = try fixture.wrote(
        c.issuez_issue_update(h, x.idStr(), &ops, ops.len, &fixture.ada, null, &w, null),
        w,
        null,
        "comment",
    );

    var pr: ?*c.issuez_purge_result = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_purge_comment(
            h,
            x.idStr(),
            &said.commit,
            &fixture.ada,
            fixture.str("abuse"),
            null,
            &pr,
            null,
        ),
        null,
    );
    try testing.expectEqual(@as(usize, 1), c.issuez_purge_result_attachment_count(pr));
    try expect.str(photo, c.issuez_purge_result_attachment_at(pr, 0));
    try testing.expect(c.issuez_purge_result_attachment_at(pr, 1).ptr == null);
    c.issuez_purge_result_free(pr);

    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_purge_issue(h, x.idStr(), &fixture.ada, fixture.str("gone"), null, &pr, null),
        null,
    );
    try testing.expectEqual(@as(usize, 1), c.issuez_purge_result_attachment_count(pr));
    try expect.str(shot, c.issuez_purge_result_attachment_at(pr, 0));
    c.issuez_purge_result_free(pr);
    try testing.expectEqual(@as(usize, 0), c.issuez_purge_result_attachment_count(null));
}

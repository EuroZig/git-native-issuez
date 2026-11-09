//! Host consistency: exact receipts, prepared images and staged publication.
const std = @import("std");
const testing = std.testing;
const f = @import("fixture.zig");
const expect = @import("expect.zig");
const c = f.c;

// covers: issuez_issue_load_at, issuez_write_load_milestone, issuez_milestone_load_at
test "receipt reads stay at their tip after a later write and ref deletion" {
    const leaks = f.Leaks.start();
    defer leaks.check();
    var r: f.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const ops = [_]c.issuez_op{c.issuez_set_title(f.str("Before"))};
    var w: ?*c.issuez_write = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_issue_create(
        r.handle,
        &ops,
        ops.len,
        &f.ada,
        null,
        &w,
        null,
    ), null);
    defer c.issuez_write_free(w);
    const id = c.issuez_write_id(w);
    const tip = c.issuez_write_new_tip(w);
    _ = try f.update(r.handle, id, &.{c.issuez_set_title(f.str("After"))});
    var loaded: ?*c.issuez_issue = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_write_load_issue(w, null, &loaded, null), null);
    defer c.issuez_issue_free(loaded);
    try testing.expectEqualStrings("Before", f.slice(c.issuez_issue_info_of(loaded).*.title));
    const got_tip = c.issuez_issue_info_of(loaded).*.tip;
    try testing.expect(c.issuez_oid_eq(&tip, &got_tip));
    _ = try r.git(&.{
        "update-ref",                                                         "-d",
        try std.fmt.allocPrint(r.arena(), "refs/issues/{s}", .{f.slice(id)}),
    });
    var historical: ?*c.issuez_issue = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_issue_load_at(
        r.handle,
        id,
        &tip,
        null,
        null,
        &historical,
        null,
    ), null);
    c.issuez_issue_free(historical);
    try expect.code(c.ISSUEZ_E_INVALID_ARGUMENT, c.issuez_issue_load_at(
        r.handle,
        id,
        null,
        null,
        null,
        &historical,
        null,
    ), null);
    const ms = [_]c.issuez_op{c.issuez_set_name(f.str("v1"))};
    var mw: ?*c.issuez_write = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_milestone_create(
        r.handle,
        &ms,
        ms.len,
        &f.ada,
        null,
        &mw,
        null,
    ), null);
    defer c.issuez_write_free(mw);
    const rename = [_]c.issuez_op{c.issuez_set_name(f.str("v2"))};
    var changed: ?*c.issuez_write = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_milestone_update(
        r.handle,
        c.issuez_write_id(mw),
        &rename,
        rename.len,
        &f.ada,
        null,
        &changed,
        null,
    ), null);
    defer c.issuez_write_free(changed);
    var m: ?*c.issuez_milestone = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_write_load_milestone(mw, null, &m, null), null);
    defer c.issuez_milestone_free(m);
    try testing.expectEqualStrings("v1", f.slice(c.issuez_milestone_info_of(m).*.name));
}

// covers: issuez_repo_begin_import, issuez_repo_commit_import
test "staged import: invisible until committed, no partial conflict" {
    const leaks = f.Leaks.start();
    defer leaks.check();
    var r: f.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    var stage: ?*c.issuez_repo = null;
    var err: ?*c.issuez_error = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_repo_begin_import(r.handle, null, &stage, &err), err);
    defer c.issuez_repo_close(stage);
    const x = try f.titled(stage.?, "Imported");
    var loaded: ?*c.issuez_issue = null;
    try expect.code(c.ISSUEZ_E_NOT_FOUND, c.issuez_issue_load(
        r.handle,
        x.idStr(),
        null,
        &loaded,
        null,
    ), null);
    var count: usize = 0;
    try expect.code(c.ISSUEZ_OK, c.issuez_repo_commit_import(stage, null, &count, &err), err);
    try testing.expectEqual(@as(usize, 1), count);
    try expect.code(c.ISSUEZ_OK, c.issuez_issue_load(
        r.handle,
        x.idStr(),
        null,
        &loaded,
        null,
    ), null);
    c.issuez_issue_free(loaded);
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_repo_commit_import(stage, null, &count, null),
        null,
    );
}

// covers: issuez_attachment_prepare, issuez_prepared_attachment_info
// covers: issuez_prepared_attachment_op, issuez_prepared_attachment_free
test "prepared attachments: metadata survives handle lifetime through a write" {
    const leaks = f.Leaks.start();
    defer leaks.check();
    var r: f.Repo = undefined;
    try r.init(.{ .ops = &.{c.issuez_opt_attachment_store(false)} });
    defer r.deinit();
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01" ++
        "\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x00IEND\xaeB`\x82";
    var prepared: ?*c.issuez_prepared_attachment = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_attachment_prepare(
        r.handle,
        .{},
        f.str("/tmp/shot.png"),
        f.str(png),
        null,
        &prepared,
        null,
    ), null);
    const info = c.issuez_prepared_attachment_info(prepared)[0];
    try testing.expectEqualStrings("shot.png", f.slice(info.name));
    try testing.expectEqualStrings("image/png", f.slice(info.media_type));
    const id = try r.arena().dupe(u8, f.slice(info.id));
    const x = try f.create(r.handle, &.{
        c.issuez_set_title(f.str("Image")),
        c.issuez_prepared_attachment_op(prepared),
    });
    c.issuez_prepared_attachment_free(prepared);
    var loaded: ?*c.issuez_issue = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_issue_load(
        r.handle,
        x.idStr(),
        null,
        &loaded,
        null,
    ), null);
    defer c.issuez_issue_free(loaded);
    try testing.expectEqual(@as(usize, 1), c.issuez_issue_attachment_count(loaded));
    try testing.expectEqualStrings(id, f.slice(c.issuez_issue_attachment_at(loaded, 0)[0].id));
}

const CancelOnCommit = struct {
    fn log(userdata: ?*anyopaque, event: [*c]const c.issuez_log_event) callconv(.c) void {
        if (!std.mem.eql(u8, f.slice(event[0].operation), "git.update-ref")) return;
        const token: *c.issuez_cancel = @ptrCast(@alignCast(userdata.?));
        c.issuez_cancel_trigger(token);
    }
};

test "committed writes with the repository's identity succeed despite cancellation" {
    const leaks = f.Leaks.start();
    defer leaks.check();
    var r: f.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const cancel = c.issuez_cancel_new();
    defer c.issuez_cancel_free(cancel);
    c.issuez_repo_set_logger(r.handle, c.ISSUEZ_LOG_DEBUG, CancelOnCommit.log, cancel);
    const ops = [_]c.issuez_op{c.issuez_set_title(f.str("Committed"))};
    var w: ?*c.issuez_write = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_issue_create(
        r.handle,
        &ops,
        ops.len,
        null,
        cancel,
        &w,
        null,
    ), null);
    defer c.issuez_write_free(w);
    try testing.expect(c.issuez_write_wrote(w));
    var loaded: ?*c.issuez_issue = null;
    try expect.code(
        c.ISSUEZ_E_CANCELLED,
        c.issuez_write_load_issue(w, cancel, &loaded, null),
        null,
    );
    try expect.code(c.ISSUEZ_OK, c.issuez_write_load_issue(w, null, &loaded, null), null);
    c.issuez_issue_free(loaded);
    c.issuez_repo_set_logger(r.handle, c.ISSUEZ_LOG_OFF, null, null);
}

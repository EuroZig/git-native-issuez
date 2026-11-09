//! Attachments in the commits of writes, read back from the issue
//! (docs/attachments.md, format.md §7).

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01" ++
    "\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x00IEND\xaeB`\x82";
const jpeg = "\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xd9";
const host_id = "5b0c4e0e-2b8a-4f5e-9d39-6c1c1f0f2a77";

fn attach(name: []const u8, data: []const u8) c.issuez_op {
    var o = fixture.opStr(c.ISSUEZ_FIELD_ATTACHMENTS, c.ISSUEZ_OP_ADD, data);
    o.name = fixture.str(name);
    return o;
}

/// attach with a UUID of the caller's.
fn attachAs(id: []const u8, name: []const u8, data: []const u8) c.issuez_op {
    var o = attach(name, data);
    o.id = fixture.str(id);
    return o;
}

fn detach(id: []const u8) c.issuez_op {
    return fixture.opStr(c.ISSUEZ_FIELD_ATTACHMENTS, c.ISSUEZ_OP_REMOVE, id);
}

fn editComment(oid: c.issuez_oid) c.issuez_op {
    var o = std.mem.zeroes(c.issuez_op);
    o.verb = c.ISSUEZ_OP_SET;
    o.target = c.ISSUEZ_OPT_EDIT_COMMENT;
    o.oid = oid;
    return o;
}

/// The code of an update as Ada, and the first problem's field.
fn refused(
    h: *c.issuez_repo,
    id: c.issuez_str,
    ops: []const c.issuez_op,
) !struct { c.issuez_code, c_uint } {
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    const rc = c.issuez_issue_update(h, id, ops.ptr, ops.len, &fixture.ada, null, &w, &err);
    defer c.issuez_error_free(err);
    try testing.expect(rc != c.ISSUEZ_OK);
    const ps = c.issuez_error_problems(err);
    const field: c_uint = if (ps != null and c.issuez_problems_len(ps) > 0)
        c.issuez_problems_at(ps, 0).*.field
    else
        0;
    return .{ rc, field };
}

// covers: issuez_issue_attachment_at, issuez_comment_attachment_at
test "issuez_issue_attachment_count: on the root, a comment and its edit, bytes kept by the host" {
    var r = try fixture.Repo.init(.{ .ops = &.{fixture.opNum(c.ISSUEZ_OPT_ATTACHMENT_STORE, 0)} });
    defer r.deinit();
    const h = r.handle;

    const created = try fixture.create(h, &.{
        c.issuez_set_title(fixture.str("Login broken")),
        c.issuez_set_description(fixture.str("![shot](attachment:" ++ host_id ++ ")")),
        attachAs(host_id, "shot.png", png),
    });
    const id = created.idStr();
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    const with_photo = [_]c.issuez_op{
        c.issuez_set_comment(fixture.str("A photo.")),
        attach("photo.jpg", jpeg),
    };
    const commented = try fixture.wrote(
        c.issuez_issue_update(h, id, &with_photo, with_photo.len, &fixture.ada, null, &w, &err),
        w,
        err,
        "comment",
    );

    // The photo's ID, from the comment that added it.
    var i = try fixture.load(h, id);
    const cm = fixture.findComment(i, commented.commit).?;
    try testing.expectEqual(@as(usize, 1), cm.attachment_count);
    var photo: [36]u8 = undefined;
    @memcpy(&photo, fixture.slice(c.issuez_comment_attachment_at(cm, 0)));
    try testing.expect(c.issuez_comment_attachment_at(cm, 1).ptr == null);
    try testing.expect(c.issuez_comment_attachment_at(null, 0).ptr == null);
    c.issuez_issue_free(i);

    // The comment's edit swaps its image.
    const swap = [_]c.issuez_op{
        editComment(commented.commit),
        c.issuez_set_comment(fixture.str("A better one.")),
        attach("better.png", png),
        detach(&photo),
    };
    w = null;
    const edited = try fixture.wrote(
        c.issuez_issue_update(h, id, &swap, swap.len, &fixture.ada, null, &w, &err),
        w,
        err,
        "edit",
    );

    i = try fixture.load(h, id);
    defer c.issuez_issue_free(i);
    try testing.expectEqual(@as(usize, 3), c.issuez_issue_attachment_count(i));
    // Present ones first; within the same second, by commit.
    const first = c.issuez_issue_attachment_at(i, 0);
    const shot, const better = if (fixture.slice(first.*.name)[0] == 's')
        .{ first, c.issuez_issue_attachment_at(i, 1) }
    else
        .{ c.issuez_issue_attachment_at(i, 1), first };
    try expect.str(host_id, shot.*.id);
    try expect.str("image/png", shot.*.media_type);
    try expect.str("shot.png", shot.*.name);
    try testing.expectEqual(@as(u64, png.len), shot.*.size);
    try testing.expectEqual(@as(usize, 64), shot.*.sha256.len);
    try testing.expect(fixture.oidEql(shot.*.added_in, created.tip));
    try expect.str("ada@example.invalid", shot.*.added_by.*.email);
    try testing.expect(!shot.*.removed);
    try expect.str("better.png", better.*.name);
    try testing.expect(fixture.oidEql(better.*.added_in, edited.commit));
    const gone = c.issuez_issue_attachment_at(i, 2);
    try expect.str("photo.jpg", gone.*.name);
    try expect.str("image/jpeg", gone.*.media_type);
    try testing.expect(gone.*.removed);
    // The description's (the root's) has no comment; an edit's and its
    // comment's belong to that comment.
    const none = std.mem.zeroes(c.issuez_oid);
    try testing.expect(fixture.oidEql(shot.*.comment, none));
    try testing.expect(fixture.oidEql(better.*.comment, commented.commit));
    try testing.expect(fixture.oidEql(gone.*.comment, commented.commit));
    try testing.expect(
        shot.*.at.unix_seconds > 0 and better.*.at.unix_seconds >= shot.*.at.unix_seconds,
    );
    try testing.expect(c.issuez_issue_attachment_at(i, 3) == null);
    try testing.expectEqual(@as(usize, 0), c.issuez_issue_attachment_count(null));
    try testing.expect(c.issuez_issue_attachment_at(null, 0) == null);
    try expect.str("A better one.", fixture.findComment(i, commented.commit).?.text);

    // The derived ref moved with them; no bytes were stored.
    const derived = try std.fmt.allocPrint(r.arena(), "refs/attachments/{s}", .{created.idSlice()});
    _ = try r.git(&.{ "rev-parse", "--verify", derived });
    const store = try std.fs.path.join(r.arena(), &.{ r.path, ".git", "issuez", "lfs" });
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, store, .{}));

    // Refusals, each with the attachments as the problem's field.
    const text = try refused(h, id, &.{attach("notes.txt", "just text\n")});
    try testing.expectEqual(@as(c.issuez_code, c.ISSUEZ_E_INVALID_VALUE), text[0]);
    try testing.expectEqual(@as(c_uint, c.ISSUEZ_FIELD_ATTACHMENTS), text[1]);
    const missing = try refused(h, id, &.{detach(&photo)});
    try testing.expectEqual(@as(c.issuez_code, c.ISSUEZ_E_NOT_FOUND), missing[0]);
    const bad_id = try refused(h, id, &.{detach("photo")});
    try testing.expectEqual(@as(c.issuez_code, c.ISSUEZ_E_INVALID_VALUE), bad_id[0]);
    const bad_uuid = try refused(h, id, &.{attachAs("not-a-uuid", "x.png", png)});
    try testing.expectEqual(@as(c.issuez_code, c.ISSUEZ_E_INVALID_VALUE), bad_uuid[0]);
    try testing.expectEqual(@as(c_uint, c.ISSUEZ_FIELD_ATTACHMENTS), bad_uuid[1]);
    const no_text = try refused(h, id, &.{ editComment(commented.commit), attach("x.png", png) });
    try testing.expectEqual(@as(c.issuez_code, c.ISSUEZ_E_INVALID_VALUE), no_text[0]);
    const with_title = try refused(h, id, &.{
        editComment(commented.commit),
        c.issuez_set_comment(fixture.str("x")),
        c.issuez_set_title(fixture.str("y")),
    });
    try testing.expectEqual(@as(c.issuez_code, c.ISSUEZ_E_INVALID_VALUE), with_title[0]);
}

fn prepare(h: ?*c.issuez_repo, name: []const u8, data: []const u8, err: *?*c.issuez_error) c_uint {
    var p: ?*c.issuez_prepared_attachment = null;
    const rc = c.issuez_attachment_prepare(
        h,
        .{},
        fixture.str(name),
        fixture.str(data),
        null,
        &p,
        err,
    );
    c.issuez_prepared_attachment_free(p);
    return rc;
}

test "issuez_attachment_prepare: types, limits" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const h = r.handle;
    var err: ?*c.issuez_error = null;
    var p: ?*c.issuez_prepared_attachment = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_attachment_prepare(h, .{}, fixture.str("a.png"), fixture.str(png), null, &p, &err),
        err,
    );
    try expect.str("image/png", c.issuez_prepared_attachment_info(p).*.media_type);
    c.issuez_prepared_attachment_free(p);
    try expect.code(c.ISSUEZ_OK, prepare(h, "a.jpg", jpeg, &err), err);
    try testing.expectEqual(
        @as(c_uint, c.ISSUEZ_E_INVALID_VALUE),
        prepare(h, "a.txt", "text", &err),
    );
    try testing.expect(c.issuez_error_problems(err) != null);
    c.issuez_error_free(err);
    err = null;
    try testing.expectEqual(
        @as(c_uint, c.ISSUEZ_E_INVALID_ARGUMENT),
        prepare(null, "a.png", png, &err),
    );
    c.issuez_error_free(err);
    err = null;

    var limit = fixture.opNum(c.ISSUEZ_OPT_LIMIT, 16);
    limit.name = fixture.str("max_attachment_bytes");
    const small = try r.open(&.{limit});
    defer c.issuez_repo_close(small);
    try testing.expectEqual(@as(c_uint, c.ISSUEZ_E_LIMIT), prepare(small, "a.png", png, &err));
    c.issuez_error_free(err);
}

test "issuez_issue_create: an attachment's bytes go to the library's store" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const h = r.handle;
    var err: ?*c.issuez_error = null;

    // By default the bytes go to this library's store, which needs git-lfs.
    var w: ?*c.issuez_write = null;
    const ops = [_]c.issuez_op{ c.issuez_set_title(fixture.str("Stored")), attach("a.png", png) };
    const rc = c.issuez_issue_create(h, &ops, ops.len, &fixture.ada, null, &w, &err);
    if (rc == c.ISSUEZ_E_LFS) {
        c.issuez_error_free(err);
        return;
    }
    try expect.code(c.ISSUEZ_OK, rc, err);
    defer c.issuez_write_free(w);
    const i = try fixture.load(h, c.issuez_write_id(w));
    defer c.issuez_issue_free(i);
    const a = c.issuez_issue_attachment_at(i, 0);
    const sha = fixture.slice(a.*.sha256);
    const path = try std.fs.path.join(
        r.arena(),
        &.{ r.path, ".git", "issuez", "lfs", "objects", sha[0..2], sha[2..4], sha },
    );
    const stored = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        path,
        r.arena(),
        .limited(1 << 20),
    );
    try testing.expectEqualStrings(png, stored);
}

test "issuez_issue_update: a stale expect is refused before the rest of the write" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const made = try fixture.titled(r.handle, "Racy");
    _ = try fixture.comment(r.handle, made.idStr(), "Moved on");
    const stale = c.issuez_expect(made.tip);
    const cases = [_][]const c.issuez_op{
        // Without the check: refused by the engine (repo.zig's "expect").
        &.{stale},
        // Without the check: INVALID_VALUE, the type refused before the engine runs.
        &.{ c.issuez_set_comment(fixture.str("Text")), attach("a.txt", "not an image"), stale },
        // Without the check: refused too, but with the bytes already stored.
        &.{ c.issuez_set_comment(fixture.str("Shot")), attach("a.png", png), stale },
    };
    for (cases) |ops| {
        var w: ?*c.issuez_write = null;
        var err: ?*c.issuez_error = null;
        const rc = c.issuez_issue_update(
            r.handle,
            made.idStr(),
            ops.ptr,
            ops.len,
            &fixture.ada,
            null,
            &w,
            &err,
        );
        defer c.issuez_error_free(err);
        defer c.issuez_write_free(w);
        try expect.code(c.ISSUEZ_E_VERSION_MISMATCH, rc, err);
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(png, &digest, .{});
    const sha = std.fmt.bytesToHex(digest, .lower);
    const path = try std.fs.path.join(
        r.arena(),
        &.{ r.path, ".git", "issuez", "lfs", "objects", sha[0..2], sha[2..4], &sha },
    );
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(testing.io, path, .{}),
    );
}

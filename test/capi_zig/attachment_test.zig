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
const apng = "\x89PNG\r\n\x1a\n\x00\x00\x00\x08acTL\x00\x00\x00\x01\x00\x00\x00\x00" ++
    "\x00\x00\x00\x00\x00\x00\x00\x00IEND\xaeB`\x82";
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
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{ .ops = &.{fixture.opNum(c.ISSUEZ_OPT_ATTACHMENT_STORE, 0)} });
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
    const cm = c.issuez_issue_comment_find(i, &commented.commit);
    try testing.expectEqual(@as(usize, 1), cm.*.attachment_count);
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
    try testing.expect(c.issuez_oid_eq(&shot.*.added_in, &created.tip));
    try expect.str("ada@example.invalid", shot.*.added_by.*.email);
    try testing.expect(!shot.*.removed);
    try expect.str("better.png", better.*.name);
    try testing.expect(c.issuez_oid_eq(&better.*.added_in, &edited.commit));
    const gone = c.issuez_issue_attachment_at(i, 2);
    try expect.str("photo.jpg", gone.*.name);
    try expect.str("image/jpeg", gone.*.media_type);
    try testing.expect(gone.*.removed);
    // The description's (the root's) has no comment; an edit's and its
    // comment's belong to that comment.
    const none = std.mem.zeroes(c.issuez_oid);
    try testing.expect(c.issuez_oid_eq(&shot.*.comment, &none));
    try testing.expect(c.issuez_oid_eq(&better.*.comment, &commented.commit));
    try testing.expect(c.issuez_oid_eq(&gone.*.comment, &commented.commit));
    try testing.expect(
        shot.*.at.unix_seconds > 0 and better.*.at.unix_seconds >= shot.*.at.unix_seconds,
    );
    try testing.expect(c.issuez_issue_attachment_at(i, 3) == null);
    try testing.expectEqual(@as(usize, 0), c.issuez_issue_attachment_count(null));
    try testing.expect(c.issuez_issue_attachment_at(null, 0) == null);
    try expect.str("A better one.", c.issuez_issue_comment_find(i, &commented.commit).*.text);

    // The derived ref moved with them; no bytes were stored.
    const derived = try std.fmt.allocPrint(r.arena(), "refs/attachments/{s}", .{created.idSlice()});
    _ = try r.git(&.{ "rev-parse", "--verify", derived });
    const store = try std.fs.path.join(r.arena(), &.{ r.path, ".git", "issuez", "lfs" });
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, store, .{}));

    // Refusals, each with the attachments as the problem's field.
    const text = try refused(h, id, &.{attach("notes.txt", "just text\n")});
    try testing.expectEqual(@as(c.issuez_code, c.ISSUEZ_E_INVALID_VALUE), text[0]);
    try testing.expectEqual(@as(c_uint, c.ISSUEZ_FIELD_ATTACHMENTS), text[1]);
    const twice = try refused(h, id, &.{attachAs(host_id, "again.png", png)});
    try testing.expectEqual(@as(c.issuez_code, c.ISSUEZ_E_INVALID_VALUE), twice[0]);
    try testing.expectEqual(@as(c_uint, c.ISSUEZ_FIELD_ATTACHMENTS), twice[1]);
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

test "issuez_attachment_validate: types, animation, names, limits; the CLI's store" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    var media: c.issuez_str = .{};
    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_attachment_validate(h, fixture.str("a.png"), fixture.str(png), &media, &err),
        err,
    );
    try expect.str("image/png", media);
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_attachment_validate(h, fixture.str("a.jpg"), fixture.str(jpeg), null, &err),
        err,
    );
    for ([_]struct { []const u8, []const u8, c.issuez_code }{
        .{ "a.png", apng, c.ISSUEZ_E_INVALID_VALUE },
        .{ "a.txt", "text", c.ISSUEZ_E_INVALID_VALUE },
        .{ "a.png", "", c.ISSUEZ_E_INVALID_VALUE },
        .{ "", png, c.ISSUEZ_E_INVALID_VALUE },
    }) |case| {
        try testing.expectEqual(
            case[2],
            c.issuez_attachment_validate(h, fixture.str(case[0]), fixture.str(case[1]), null, &err),
        );
        try testing.expect(c.issuez_error_problems(err) != null);
        c.issuez_error_free(err);
        err = null;
    }
    try testing.expectEqual(
        @as(c.issuez_code, c.ISSUEZ_E_INVALID_ARGUMENT),
        c.issuez_attachment_validate(null, fixture.str("a.png"), fixture.str(png), null, &err),
    );
    c.issuez_error_free(err);
    err = null;

    var limit = fixture.opNum(c.ISSUEZ_OPT_LIMIT, 16);
    limit.name = fixture.str("max_attachment_bytes");
    const small = try r.open(&.{limit});
    defer c.issuez_repo_close(small);
    try testing.expectEqual(
        @as(c.issuez_code, c.ISSUEZ_E_LIMIT),
        c.issuez_attachment_validate(small, fixture.str("a.png"), fixture.str(png), null, &err),
    );
    c.issuez_error_free(err);
    err = null;

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

test "issuez_attachment_read, issuez_bytes_data, issuez_bytes_free: stored bytes, missing ones" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const x = try fixture.create(
        h,
        &.{ c.issuez_set_title(fixture.str("Pictured")), attachAs(host_id, "shot.png", png) },
    );
    var b: ?*c.issuez_bytes = null;
    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_attachment_read(h, x.idStr(), fixture.str(host_id), null, &b, &err),
        err,
    );
    try testing.expectEqualSlices(u8, png, fixture.slice(c.issuez_bytes_data(b)));
    c.issuez_bytes_free(b);
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        c.issuez_attachment_read(
            h,
            x.idStr(),
            fixture.str("6c1d5f1f-3c9b-4a6f-8e4a-7d2d2a1a3b88"),
            null,
            &b,
            null,
        ),
        null,
    );
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        c.issuez_attachment_read(
            h,
            fixture.str("0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c"),
            fixture.str(host_id),
            null,
            &b,
            null,
        ),
        null,
    );

    // A host that keeps the bytes itself has none here.
    const kept = try r.open(&.{fixture.opNum(c.ISSUEZ_OPT_ATTACHMENT_STORE, 0)});
    defer c.issuez_repo_close(kept);
    const other = "6c1d5f1f-3c9b-4a6f-8e4a-7d2d2a1a3b88";
    const y = try fixture.create(
        kept,
        &.{ c.issuez_set_title(fixture.str("Hosted")), attachAs(other, "a.jpg", jpeg) },
    );
    try expect.code(
        c.ISSUEZ_E_LFS,
        c.issuez_attachment_read(kept, y.idStr(), fixture.str(other), null, &b, null),
        null,
    );
    try testing.expectEqual(@as(usize, 0), c.issuez_bytes_data(null).len);
    c.issuez_bytes_free(null);
}

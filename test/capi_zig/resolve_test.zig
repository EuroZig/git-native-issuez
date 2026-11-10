//! Resolving input and snapshots.

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

test "issuez_resolve_one: UUIDs, prefixes, numbers, names" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const one = try fixture.create(
        r.handle,
        &.{ c.issuez_set_title(fixture.str("One")), c.issuez_set_number(12) },
    );
    _ = try fixture.titled(r.handle, "Two");
    const m = try fixture.milestone(r.handle, "v1.0");

    const cases = [_]struct { c.issuez_kind, []const u8, ?[]const u8 }{
        .{ c.ISSUEZ_KIND_ISSUE, one.idSlice(), one.idSlice() },
        .{ c.ISSUEZ_KIND_ISSUE, one.idSlice()[0..8], one.idSlice() },
        .{ c.ISSUEZ_KIND_ISSUE, "#12", one.idSlice() },
        .{ c.ISSUEZ_KIND_ISSUE, "#13", null },
        .{ c.ISSUEZ_KIND_ISSUE, "ffffffff", null },
        .{ c.ISSUEZ_KIND_MILESTONE, "v1.0", m.idSlice() },
        .{ c.ISSUEZ_KIND_MILESTONE, m.idSlice()[0..6], m.idSlice() },
        .{ c.ISSUEZ_KIND_MILESTONE, "v2", null },
    };
    for (cases) |case| {
        var buf: [37]u8 = undefined;
        const rc = c.issuez_resolve_one(r.handle, case[0], fixture.str(case[1]), null, &buf, null);
        if (case[2]) |want| {
            try expect.code(c.ISSUEZ_OK, rc, null);
            try testing.expectEqualStrings(want, std.mem.sliceTo(&buf, 0));
        } else {
            try expect.code(c.ISSUEZ_E_NOT_FOUND, rc, null);
        }
    }
    var buf: [37]u8 = undefined;
    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_resolve_one(r.handle, c.ISSUEZ_KIND_TOMBSTONE, fixture.str("x"), null, &buf, &err),
        err,
    );
    c.issuez_error_free(err);
}

test "issuez_resolve_one: a number two issues were given" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    _ = try fixture.create(
        r.handle,
        &.{ c.issuez_set_title(fixture.str("A")), c.issuez_set_number(5) },
    );
    // Another clone gave #5 too: written with git, as a sync would bring it.
    const b = try fixture.titled(r.handle, "B");
    const ref = try std.fmt.allocPrint(r.arena(), "refs/issues/{s}", .{b.idSlice()});
    const tree = try r.git(&.{ "hash-object", "-t", "tree", "-w", "/dev/null" });
    const tip = try r.git(&.{ "commit-tree", tree, "-p", ref, "-m", "Number\n\nX-Number: 5" });
    _ = try r.git(&.{ "update-ref", ref, tip });
    var buf: [37]u8 = undefined;
    try expect.code(
        c.ISSUEZ_E_AMBIGUOUS,
        c.issuez_resolve_one(r.handle, c.ISSUEZ_KIND_ISSUE, fixture.str("#5"), null, &buf, null),
        null,
    );
}

test "issuez_resolve_one: one, none, several" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const one = try fixture.titled(r.handle, "One");
    // 17 issues: two share their first hex digit.
    var firsts: [16]u8 = @splat(0);
    var shared: ?u8 = null;
    for (0..17) |_| {
        const x = try fixture.titled(r.handle, "Another");
        const d = x.id[0];
        const slot = std.fmt.charToDigit(d, 16) catch unreachable;
        firsts[slot] += 1;
        if (firsts[slot] == 2) shared = d;
    }
    var buf: [37]u8 = @splat('x');
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_resolve_one(
            r.handle,
            c.ISSUEZ_KIND_ISSUE,
            fixture.str(one.idSlice()[0..10]),
            null,
            &buf,
            null,
        ),
        null,
    );
    try testing.expectEqualStrings(one.idSlice(), buf[0..36]);
    try testing.expectEqual(@as(u8, 0), buf[36]);
    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        c.issuez_resolve_one(
            r.handle,
            c.ISSUEZ_KIND_ISSUE,
            fixture.str("ffffffff"),
            null,
            &buf,
            &err,
        ),
        err,
    );
    try expect.str("ffffffff", c.issuez_error_subject(err));
    c.issuez_error_free(err);
    err = null;
    const prefix = [_]u8{shared.?};
    try expect.code(
        c.ISSUEZ_E_AMBIGUOUS,
        c.issuez_resolve_one(r.handle, c.ISSUEZ_KIND_ISSUE, fixture.str(&prefix), null, &buf, &err),
        err,
    );
    c.issuez_error_free(err);
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_resolve_one(r.handle, c.ISSUEZ_KIND_ISSUE, fixture.str("x"), null, null, null),
        null,
    );
}

test "issuez_resolve_one: a ref that is no UUID is no candidate" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const one = try fixture.titled(r.handle, "One");
    // Its name starts like the issue's, and is far longer than a UUID.
    const long = try std.fmt.allocPrint(
        r.arena(),
        "refs/issues/{s}{s}",
        .{ one.idSlice()[0..4], &@as([200]u8, @splat('x')) },
    );
    const ref = try std.fmt.allocPrint(r.arena(), "refs/issues/{s}", .{one.idSlice()});
    _ = try r.git(&.{ "update-ref", long, ref });
    var buf: [37 + 8]u8 = @splat('x');
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_resolve_one(
            r.handle,
            c.ISSUEZ_KIND_ISSUE,
            fixture.str(one.idSlice()[0..4]),
            null,
            &buf,
            null,
        ),
        null,
    );
    try testing.expectEqualStrings(one.idSlice(), std.mem.sliceTo(&buf, 0));
    try testing.expectEqualStrings(&@as([8]u8, @splat('x')), buf[37..]);
    // Matched alone, it isn't written into the buffer either.
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        c.issuez_resolve_one(
            r.handle,
            c.ISSUEZ_KIND_ISSUE,
            fixture.str(long["refs/issues/".len..][0..12]),
            null,
            &buf,
            null,
        ),
        null,
    );
    try testing.expectEqualStrings(&@as([8]u8, @splat('x')), buf[37..]);
}

fn take(repo: *c.issuez_repo) !*c.issuez_snapshot {
    var s: ?*c.issuez_snapshot = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_snapshot_take(repo, null, &s, null), null);
    return s.?;
}

// covers: issuez_snapshot_free, issuez_snapshot_len, issuez_snapshot_at
test "issuez_snapshot_take: every ref, sorted" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const empty = try take(r.handle);
    try testing.expectEqual(@as(usize, 0), c.issuez_snapshot_len(empty));
    c.issuez_snapshot_free(empty);

    const first = try fixture.titled(r.handle, "One");
    const second = try fixture.titled(r.handle, "Two");
    const m = try fixture.milestone(r.handle, "v1");
    const s = try take(r.handle);
    defer c.issuez_snapshot_free(s);
    try testing.expectEqual(@as(usize, 3), c.issuez_snapshot_len(s));
    var last_kind: c.issuez_kind = 0;
    var last_id: []const u8 = "";
    for (0..3) |i| {
        var kind: c.issuez_kind = undefined;
        var id: c.issuez_str = undefined;
        var tip: c.issuez_oid = undefined;
        c.issuez_snapshot_at(s, i, &kind, &id, &tip);
        try expect.terminated(id);
        // Sorted by kind, then UUID.
        try testing.expect(
            kind > last_kind or (kind == last_kind and std.mem.order(
                u8,
                last_id,
                fixture.slice(id),
            ) == .lt),
        );
        last_kind = kind;
        last_id = fixture.slice(id);
    }
    {
        // Out of range: emptied, not left as they were.
        var kind: c.issuez_kind = c.ISSUEZ_KIND_ISSUE;
        var id: c.issuez_str = fixture.str("left over");
        var t = first.tip;
        c.issuez_snapshot_at(s, 3, &kind, &id, &t);
        try testing.expectEqual(@as(c.issuez_kind, c.ISSUEZ_KIND_UNKNOWN), kind);
        try expect.str("", id);
        try testing.expectEqual(@as(u8, 0), t.len);
    }
    // Every ref, each with its tip.
    for ([_]struct { c.issuez_kind, *const fixture.Created }{
        .{ c.ISSUEZ_KIND_ISSUE, &first },
        .{ c.ISSUEZ_KIND_ISSUE, &second },
        .{ c.ISSUEZ_KIND_MILESTONE, &m },
    }) |want| {
        var found = false;
        for (0..3) |i| {
            var kind: c.issuez_kind = undefined;
            var id: c.issuez_str = undefined;
            var tip: c.issuez_oid = undefined;
            c.issuez_snapshot_at(s, i, &kind, &id, &tip);
            if (kind != want[0] or !std.mem.eql(u8, fixture.slice(id), want[1].idSlice())) continue;
            try testing.expect(fixture.oidEql(tip, want[1].tip));
            found = true;
        }
        try testing.expect(found);
    }
    try testing.expectEqual(@as(usize, 0), c.issuez_snapshot_len(null));
    c.issuez_snapshot_free(null);
}

test "issuez_snapshot_decode: the encoding, sorted; empty; garbage" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    const issue = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c";
    const other = "1b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c";
    const sha1 = "5186cff79af42ee5c6a80d822eec95a842832b34";
    const sha256 = "a7f3" ++ @as([56]u8, @splat('0')) ++ "beef";
    const line = "i " ++ issue ++ " " ++ sha1 ++ "\n";
    const bytes = "issuez-snapshot 1\n" ++
        "m " ++ other ++ " " ++ sha256 ++ "\n" ++
        "i " ++ other ++ " " ++ sha1 ++ "\n" ++
        line;

    var s: ?*c.issuez_snapshot = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_snapshot_decode(fixture.str(bytes), &s, null), null);
    defer c.issuez_snapshot_free(s);
    try testing.expectEqual(@as(usize, 3), c.issuez_snapshot_len(s));
    for ([_]struct { c.issuez_kind, []const u8, []const u8 }{
        .{ c.ISSUEZ_KIND_ISSUE, issue, sha1 },
        .{ c.ISSUEZ_KIND_ISSUE, other, sha1 },
        .{ c.ISSUEZ_KIND_MILESTONE, other, sha256 },
    }, 0..) |want, i| {
        var kind: c.issuez_kind = undefined;
        var id: c.issuez_str = undefined;
        var tip: c.issuez_oid = undefined;
        c.issuez_snapshot_at(s, i, &kind, &id, &tip);
        try testing.expectEqual(want[0], kind);
        try expect.str(want[1], id);
        try testing.expect(fixture.oidEql(tip, try fixture.oidParse(want[2])));
    }

    var empty: ?*c.issuez_snapshot = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_snapshot_decode(fixture.str(""), &empty, null), null);
    try testing.expectEqual(@as(usize, 0), c.issuez_snapshot_len(empty));
    c.issuez_snapshot_free(empty);
    const garbage = [_][]const u8{
        "garbage",
        "issuez-snapshot 9\n",
        bytes[0 .. bytes.len - 3],
        "issuez-snapshot 1\nx " ++ issue ++ " " ++ sha1 ++ "\n",
        "issuez-snapshot 1\ni a7f3 " ++ sha1 ++ "\n",
        "issuez-snapshot 1\ni " ++ issue ++ " 5186CFF79AF42EE5C6A80D822EEC95A842832B34\n",
    };
    for (garbage) |g| {
        var out: ?*c.issuez_snapshot = null;
        var err: ?*c.issuez_error = null;
        const rc = c.issuez_snapshot_decode(fixture.str(g), &out, &err);
        testing.expect(rc != c.ISSUEZ_OK) catch |e| {
            std.debug.print("decoded: {s}\n", .{g});
            c.issuez_snapshot_free(out);
            return e;
        };
        c.issuez_error_free(err);
    }
}

test "issuez_snapshot_decode: the refs a snapshot took, as Go encodes them" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const x = try fixture.titled(r.handle, "One");
    const m = try fixture.milestone(r.handle, "v1");
    const taken = try take(r.handle);
    defer c.issuez_snapshot_free(taken);
    const bytes = try std.fmt.allocPrint(r.arena(), "issuez-snapshot 1\ni {s} {s}\nm {s} {s}\n", .{
        x.idSlice(),
        fixture.oidHex(x.tip)[0 .. x.tip.len * 2],
        m.idSlice(),
        fixture.oidHex(m.tip)[0 .. m.tip.len * 2],
    });
    var back: ?*c.issuez_snapshot = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_snapshot_decode(fixture.str(bytes), &back, null), null);
    defer c.issuez_snapshot_free(back);
    try testing.expectEqual(c.issuez_snapshot_len(taken), c.issuez_snapshot_len(back));
    for (0..c.issuez_snapshot_len(back)) |i| {
        var kinds: [2]c.issuez_kind = undefined;
        var ids: [2]c.issuez_str = undefined;
        var tips: [2]c.issuez_oid = undefined;
        c.issuez_snapshot_at(taken, i, &kinds[0], &ids[0], &tips[0]);
        c.issuez_snapshot_at(back, i, &kinds[1], &ids[1], &tips[1]);
        try testing.expectEqual(kinds[0], kinds[1]);
        try testing.expectEqualStrings(fixture.slice(ids[0]), fixture.slice(ids[1]));
        try testing.expect(fixture.oidEql(tips[0], tips[1]));
    }
}

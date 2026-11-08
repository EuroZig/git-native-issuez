//! Resolving input, snapshots and diffs (docs/test-plan.md §2.5.7).

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

// covers: issuez_matches_len, issuez_matches_at, issuez_matches_free
test "issuez_resolve: UUIDs, prefixes, numbers, names" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const one = try fixture.create(
        r.handle,
        &.{ c.issuez_set_title(fixture.str("One")), c.issuez_set_number(12) },
    );
    _ = try fixture.titled(r.handle, "Two");
    const m = try fixture.milestone(r.handle, "v1.0");

    const cases = [_]struct { c.issuez_kind, []const u8, []const []const u8 }{
        .{ c.ISSUEZ_KIND_ISSUE, one.idSlice(), &.{one.idSlice()} },
        .{ c.ISSUEZ_KIND_ISSUE, one.idSlice()[0..8], &.{one.idSlice()} },
        .{ c.ISSUEZ_KIND_ISSUE, "#12", &.{one.idSlice()} },
        .{ c.ISSUEZ_KIND_ISSUE, "#13", &.{} },
        .{ c.ISSUEZ_KIND_ISSUE, "ffffffff", &.{} },
        .{ c.ISSUEZ_KIND_MILESTONE, "v1.0", &.{m.idSlice()} },
        .{ c.ISSUEZ_KIND_MILESTONE, m.idSlice()[0..6], &.{m.idSlice()} },
        .{ c.ISSUEZ_KIND_MILESTONE, "v2", &.{} },
    };
    for (cases) |case| {
        const got = try fixture.resolve(r.handle, case[0], case[1]);
        defer fixture.freeAll(got);
        try testing.expectEqual(case[2].len, got.len);
        for (case[2]) |want| {
            const found = for (got) |g| {
                if (std.mem.eql(u8, g, want)) break true;
            } else false;
            try testing.expect(found);
        }
    }
    var mm: ?*c.issuez_matches = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_resolve(r.handle, c.ISSUEZ_KIND_ISSUE, fixture.str("#12"), null, &mm, null),
        null,
    );
    try expect.terminated(c.issuez_matches_at(mm, 0));
    try expect.str("", c.issuez_matches_at(mm, 1));
    c.issuez_matches_free(mm);
    c.issuez_matches_free(null);
    try testing.expectEqual(@as(usize, 0), c.issuez_matches_len(null));
    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_resolve(r.handle, c.ISSUEZ_KIND_TOMBSTONE, fixture.str("x"), null, &mm, &err),
        err,
    );
    c.issuez_error_free(err);
}

test "issuez_resolve: a number two issues were given" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const a = try fixture.create(
        r.handle,
        &.{ c.issuez_set_title(fixture.str("A")), c.issuez_set_number(5) },
    );
    // Another clone gave #5 too: written with git, as a sync would bring it.
    const b = try fixture.titled(r.handle, "B");
    const ref = try std.fmt.allocPrint(r.arena(), "refs/issues/{s}", .{b.idSlice()});
    const tree = try r.git(&.{ "hash-object", "-t", "tree", "-w", "/dev/null" });
    const tip = try r.git(&.{ "commit-tree", tree, "-p", ref, "-m", "Number\n\nX-Number: 5" });
    _ = try r.git(&.{ "update-ref", ref, tip });
    const got = try fixture.resolve(r.handle, c.ISSUEZ_KIND_ISSUE, "#5");
    defer fixture.freeAll(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    _ = a;
}

test "issuez_resolve_one: one, none, several" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
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

fn take(repo: *c.issuez_repo) !*c.issuez_snapshot {
    var s: ?*c.issuez_snapshot = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_snapshot_take(repo, null, &s, null), null);
    return s.?;
}

// covers: issuez_snapshot_free, issuez_snapshot_len, issuez_snapshot_at, issuez_snapshot_tip
test "issuez_snapshot_take: every ref, sorted" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
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
    var tip: c.issuez_oid = undefined;
    try testing.expect(c.issuez_snapshot_tip(s, c.ISSUEZ_KIND_ISSUE, first.idStr(), &tip));
    try testing.expect(c.issuez_oid_eq(&tip, &first.tip));
    try testing.expect(c.issuez_snapshot_tip(s, c.ISSUEZ_KIND_MILESTONE, m.idStr(), &tip));
    try testing.expect(!c.issuez_snapshot_tip(s, c.ISSUEZ_KIND_MILESTONE, second.idStr(), &tip));
    try testing.expect(!c.issuez_snapshot_tip(null, c.ISSUEZ_KIND_ISSUE, second.idStr(), &tip));
    try testing.expectEqual(@as(usize, 0), c.issuez_snapshot_len(null));
    c.issuez_snapshot_free(null);
}

test "issuez_snapshot_encode, issuez_snapshot_decode: round trip, empty, garbage" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    _ = try fixture.titled(r.handle, "One");
    _ = try fixture.milestone(r.handle, "v1");
    const s = try take(r.handle);
    defer c.issuez_snapshot_free(s);
    const bytes = c.issuez_snapshot_encode(s);
    try testing.expect(bytes.len > 0);
    // Stable: a second snapshot of the same refs encodes the same.
    const again = try take(r.handle);
    defer c.issuez_snapshot_free(again);
    try testing.expectEqualStrings(
        fixture.slice(bytes),
        fixture.slice(c.issuez_snapshot_encode(again)),
    );

    var back: ?*c.issuez_snapshot = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_snapshot_decode(bytes, &back, null), null);
    defer c.issuez_snapshot_free(back);
    var d: ?*c.issuez_diff = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_diff_new(s, back, &d, null), null);
    try testing.expectEqual(@as(usize, 0), c.issuez_diff_len(d));
    c.issuez_diff_free(d);

    var empty: ?*c.issuez_snapshot = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_snapshot_decode(fixture.str(""), &empty, null), null);
    try testing.expectEqual(@as(usize, 0), c.issuez_snapshot_len(empty));
    c.issuez_snapshot_free(empty);
    const text = fixture.slice(bytes);
    const garbage = [_][]const u8{ "garbage", "issuez-snapshot 9\n", text[0 .. text.len - 3] };
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

// covers: issuez_diff_len, issuez_diff_at, issuez_diff_free
test "issuez_diff_new: created, updated, removed" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const kept = try fixture.titled(r.handle, "Kept");
    const changed = try fixture.titled(r.handle, "Changed");
    const gone = try fixture.titled(r.handle, "Gone");
    const before = try take(r.handle);
    defer c.issuez_snapshot_free(before);

    var d: ?*c.issuez_diff = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_diff_new(null, before, &d, null), null);
    try testing.expectEqual(@as(usize, 3), c.issuez_diff_len(d));
    for (0..3) |i| try testing.expectEqual(
        @as(u32, c.ISSUEZ_CHANGE_CREATED),
        c.issuez_diff_at(d, i).*.change,
    );
    c.issuez_diff_free(d);

    const new_tip = try fixture.update(
        r.handle,
        changed.idStr(),
        &.{c.issuez_add_label(fixture.str("x"))},
    );
    var pr: ?*c.issuez_purge_result = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_purge_issue(
            r.handle,
            gone.idStr(),
            &fixture.ada,
            fixture.str(""),
            null,
            &pr,
            null,
        ),
        null,
    );
    c.issuez_purge_result_free(pr);
    const m = try fixture.milestone(r.handle, "v1");
    const after = try take(r.handle);
    defer c.issuez_snapshot_free(after);
    try expect.code(c.ISSUEZ_OK, c.issuez_diff_new(before, after, &d, null), null);
    defer c.issuez_diff_free(d);
    try testing.expectEqual(@as(usize, 3), c.issuez_diff_len(d));
    var seen: u8 = 0;
    for (0..3) |i| {
        const e = c.issuez_diff_at(d, i).*;
        try expect.terminated(e.id);
        const id = fixture.slice(e.id);
        if (std.mem.eql(u8, id, changed.idSlice())) {
            try testing.expectEqual(@as(u32, c.ISSUEZ_CHANGE_UPDATED), e.change);
            try testing.expect(c.issuez_oid_eq(&e.old_tip, &changed.tip));
            try testing.expect(c.issuez_oid_eq(&e.new_tip, &new_tip));
            seen |= 1;
        } else if (std.mem.eql(u8, id, gone.idSlice())) {
            try testing.expectEqual(@as(u32, c.ISSUEZ_CHANGE_REMOVED), e.change);
            try testing.expectEqual(@as(u8, 0), e.new_tip.len);
            seen |= 2;
        } else if (std.mem.eql(u8, id, m.idSlice())) {
            try testing.expectEqual(@as(u32, c.ISSUEZ_CHANGE_CREATED), e.change);
            try testing.expectEqual(@as(u32, c.ISSUEZ_KIND_MILESTONE), e.kind);
            try testing.expectEqual(@as(u8, 0), e.old_tip.len);
            seen |= 4;
        }
    }
    try testing.expectEqual(@as(u8, 7), seen);
    try testing.expect(c.issuez_diff_at(d, 3) == null);
    _ = kept;
    try expect.code(c.ISSUEZ_E_INVALID_ARGUMENT, c.issuez_diff_new(before, null, &d, null), null);
    c.issuez_diff_free(null);
    try testing.expectEqual(@as(usize, 0), c.issuez_diff_len(null));
}

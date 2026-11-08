//! Sync between two repositories and a hub.

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

const Pair = struct {
    r: fixture.Repo,
    hub: []const u8,
    b: *c.issuez_repo,

    fn init(p: *Pair) !void {
        try p.r.init(.{});
        errdefer p.r.deinit();
        p.hub = try fixture.hub(&p.r, "hub.git");
        p.b = try fixture.second(&p.r, "b", p.hub);
    }

    fn deinit(p: *Pair) void {
        c.issuez_repo_close(p.b);
        p.r.deinit();
    }

    fn a(p: *Pair) *c.issuez_repo {
        return p.r.handle;
    }
};

fn outcomeOf(s: fixture.Synced, id: []const u8) !u32 {
    const it = s.item(id) orelse {
        std.debug.print("{s} isn't in the report\n", .{id});
        return error.NotReported;
    };
    try expect.terminated(it.id);
    return it.outcome;
}

// covers: issuez_sync_report_len, issuez_sync_report_at, issuez_sync_report_ok
// covers: issuez_sync_report_free
test "issuez_sync: pushed, new, fast-forward, merged" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var p: Pair = undefined;
    try p.init();
    defer p.deinit();
    const x = try fixture.titled(p.a(), "Shared");
    var s = try fixture.sync(p.a(), &.{});
    try testing.expectEqual(@as(u32, c.ISSUEZ_SYNC_PUSHED), try outcomeOf(s, x.idSlice()));
    const pushed = s.item(x.idSlice()).?;
    try testing.expect(c.issuez_oid_eq(&pushed.local_tip, &pushed.remote_tip));
    try testing.expect(c.issuez_oid_eq(&pushed.local_tip, &x.tip));
    try testing.expectEqual(@as(u32, c.ISSUEZ_KIND_ISSUE), pushed.kind);
    try testing.expect(c.issuez_sync_report_ok(s.report));
    try testing.expectEqual(@as(usize, 1), c.issuez_sync_report_len(s.report));
    try testing.expect(c.issuez_sync_report_at(s.report, 1) == null);
    s.deinit();

    s = try fixture.sync(p.b, &.{});
    try testing.expectEqual(@as(u32, c.ISSUEZ_SYNC_NEW), try outcomeOf(s, x.idSlice()));
    s.deinit();

    _ = try fixture.comment(p.a(), x.idStr(), "From A");
    (try fixture.sync(p.a(), &.{})).deinit();
    s = try fixture.sync(p.b, &.{});
    try testing.expectEqual(@as(u32, c.ISSUEZ_SYNC_FAST_FORWARD), try outcomeOf(s, x.idSlice()));
    s.deinit();

    // Both write; B merges, and pushes the merge.
    _ = try fixture.comment(p.a(), x.idStr(), "A again");
    (try fixture.sync(p.a(), &.{})).deinit();
    _ = try fixture.comment(p.b, x.idStr(), "B meanwhile");
    s = try fixture.sync(p.b, &.{});
    try testing.expectEqual(@as(u32, c.ISSUEZ_SYNC_MERGED), try outcomeOf(s, x.idSlice()));
    const merged = s.item(x.idSlice()).?;
    try testing.expect(c.issuez_oid_eq(&merged.local_tip, &merged.remote_tip));
    s.deinit();
    s = try fixture.sync(p.a(), &.{});
    try testing.expectEqual(@as(u32, c.ISSUEZ_SYNC_FAST_FORWARD), try outcomeOf(s, x.idSlice()));
    s.deinit();
    s = try fixture.sync(p.a(), &.{});
    try testing.expectEqual(@as(u32, c.ISSUEZ_SYNC_UP_TO_DATE), try outcomeOf(s, x.idSlice()));
    s.deinit();

    // Milestones too.
    const m = try fixture.milestone(p.a(), "v1");
    s = try fixture.sync(p.a(), &.{});
    try testing.expectEqual(@as(u32, c.ISSUEZ_KIND_MILESTONE), s.item(m.idSlice()).?.kind);
    s.deinit();
    c.issuez_sync_report_free(null);
    try testing.expectEqual(@as(usize, 0), c.issuez_sync_report_len(null));
    try testing.expect(!c.issuez_sync_report_ok(null));
}

test "issuez_sync: merge only, a hub that refuses, options" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var p: Pair = undefined;
    try p.init();
    defer p.deinit();
    const x = try fixture.titled(p.a(), "Local");
    const no_push = [_]c.issuez_op{fixture.opNum(c.ISSUEZ_OPT_SYNC_PUSH, 0)};
    var s = try fixture.sync(p.a(), &no_push);
    try testing.expect(s.item(x.idSlice()) == null);
    s.deinit();
    const listed = try fixture.runGit(p.r.arena(), p.hub, &.{ "for-each-ref", "refs/issues/" });
    try testing.expectEqualStrings("", listed);

    const hook = try std.fs.path.join(p.r.arena(), &.{ p.hub, "hooks" });
    _ = try fixture.script(p.r.arena(), hook, "pre-receive",
        \\#!/bin/sh
        \\echo "no issues here" >&2
        \\exit 1
        \\
    );
    var out: ?*c.issuez_sync_report = null;
    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_E_NETWORK,
        c.issuez_sync(p.a(), fixture.str("origin"), null, 0, null, &out, &err),
        err,
    );
    try testing.expect(
        std.mem.find(u8, fixture.slice(c.issuez_error_git_stderr(err)), "no issues here") != null,
    );
    c.issuez_error_free(err);
    err = null;
    const bad = [_]c.issuez_op{c.issuez_set_title(fixture.str("x"))};
    try expect.code(
        c.ISSUEZ_E_INVALID_VALUE,
        c.issuez_sync(p.a(), fixture.str("origin"), &bad, 1, null, &out, &err),
        err,
    );
    c.issuez_error_free(err);
    err = null;
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_sync(p.a(), fixture.str("origin"), null, 0, null, null, null),
        null,
    );
    try testing.expect(
        c.issuez_sync(
            p.a(),
            fixture.str("no-such-remote"),
            null,
            0,
            null,
            &out,
            &err,
        ) != c.ISSUEZ_OK,
    );
    c.issuez_error_free(err);
}

test "issuez_quarantine_resolve: a rewound hub, take theirs, keep ours" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var p: Pair = undefined;
    try p.init();
    defer p.deinit();
    const x = try fixture.titled(p.a(), "Rewritten");
    const y = try fixture.titled(p.a(), "Also");
    (try fixture.sync(p.a(), &.{})).deinit();
    (try fixture.sync(p.b, &.{})).deinit();
    // Someone starts both over on the hub.
    for ([_]fixture.Created{ x, y }) |z| {
        const tree = try fixture.runGit(
            p.r.arena(),
            p.hub,
            &.{ "hash-object", "-t", "tree", "-w", "/dev/null" },
        );
        const root = try fixture.runGit(
            p.r.arena(),
            p.hub,
            &.{ "commit-tree", tree, "-m", "Started over\n\nState: open\nFormat-Version: 1" },
        );
        _ = try fixture.runGit(
            p.r.arena(),
            p.hub,
            &.{
                "update-ref",
                try std.fmt.allocPrint(p.r.arena(), "refs/issues/{s}", .{z.idSlice()}),
                root,
            },
        );
    }
    var s = try fixture.sync(p.b, &.{});
    try testing.expectEqual(@as(u32, c.ISSUEZ_SYNC_QUARANTINED), try outcomeOf(s, x.idSlice()));
    try testing.expect(!c.issuez_sync_report_ok(s.report));
    try expect.terminated(s.item(x.idSlice()).?.reason);
    try testing.expect(s.item(x.idSlice()).?.reason.len > 0);
    s.deinit();

    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_quarantine_resolve(
            p.b,
            fixture.str("origin"),
            c.ISSUEZ_KIND_ISSUE,
            x.idStr(),
            c.ISSUEZ_CHOICE_TAKE_REMOTE,
            null,
            &err,
        ),
        err,
    );
    const took = try fixture.load(p.b, x.idStr());
    try expect.str("Started over", c.issuez_issue_title(took));
    c.issuez_issue_free(took);
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_quarantine_resolve(
            p.b,
            fixture.str("origin"),
            c.ISSUEZ_KIND_ISSUE,
            y.idStr(),
            c.ISSUEZ_CHOICE_KEEP_LOCAL,
            null,
            &err,
        ),
        err,
    );
    const kept = try fixture.load(p.b, y.idStr());
    try expect.str("Also", c.issuez_issue_title(kept));
    c.issuez_issue_free(kept);
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        c.issuez_quarantine_resolve(
            p.b,
            fixture.str("origin"),
            c.ISSUEZ_KIND_ISSUE,
            x.idStr(),
            c.ISSUEZ_CHOICE_TAKE_REMOTE,
            null,
            &err,
        ),
        err,
    );
    c.issuez_error_free(err);
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_quarantine_resolve(
            p.b,
            fixture.str("origin"),
            c.ISSUEZ_KIND_ISSUE,
            y.idStr(),
            c.ISSUEZ_CHOICE_UNKNOWN,
            null,
            null,
        ),
        null,
    );
}

test "issuez_sync: purges travel" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var p: Pair = undefined;
    try p.init();
    defer p.deinit();
    const x = try fixture.titled(p.a(), "Doxxing");
    (try fixture.sync(p.a(), &.{})).deinit();
    (try fixture.sync(p.b, &.{})).deinit();
    var pr: ?*c.issuez_purge_result = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_purge_issue(p.a(), x.idStr(), &fixture.ada, fixture.str("legal"), null, &pr, null),
        null,
    );
    c.issuez_purge_result_free(pr);
    (try fixture.sync(p.a(), &.{})).deinit();
    const s = try fixture.sync(p.b, &.{});
    defer s.deinit();
    try testing.expectEqual(@as(u32, c.ISSUEZ_SYNC_PURGED), try outcomeOf(s, x.idSlice()));
    var out: ?*c.issuez_issue = null;
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        c.issuez_issue_load(p.b, x.idStr(), null, &out, null),
        null,
    );
}

fn triggerLater(t: *c.issuez_cancel) void {
    std.Io.sleep(testing.io, .fromMilliseconds(200), .awake) catch {};
    c.issuez_cancel_trigger(t);
}

test "issuez_sync: cancelled while git hangs" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var p: Pair = undefined;
    try p.init();
    defer p.deinit();
    const slow = try fixture.slowGit(p.r.arena(), p.r.root);
    const h = try p.r.open(&.{c.issuez_opt_git_path(fixture.str(slow))});
    defer c.issuez_repo_close(h);
    const token = c.issuez_cancel_new().?;
    defer c.issuez_cancel_free(token);
    const thread = try std.Thread.spawn(.{}, triggerLater, .{token});
    const start = std.Io.Timestamp.now(testing.io, .awake);
    var out: ?*c.issuez_sync_report = null;
    var err: ?*c.issuez_error = null;
    try expect.code(
        c.ISSUEZ_E_CANCELLED,
        c.issuez_sync(h, fixture.str("origin"), null, 0, token, &out, &err),
        err,
    );
    c.issuez_error_free(err);
    thread.join();
    try testing.expect(start.untilNow(testing.io, .awake).toMilliseconds() < 3000);
}

// covers: issuez_sync_status_quarantined_count, issuez_sync_status_quarantined_at
// covers: issuez_sync_status_pending_count, issuez_sync_status_pending_at, issuez_sync_status_free
test "issuez_sync_status_take: pending without the network" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    _ = try fixture.hub(&r, "hub.git");
    const x = try fixture.titled(r.handle, "Unpushed");
    var st: ?*c.issuez_sync_status = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_sync_status_take(r.handle, fixture.str("origin"), null, &st, null),
        null,
    );
    try testing.expectEqual(@as(usize, 1), c.issuez_sync_status_pending_count(st));
    try expect.str(x.idSlice(), c.issuez_sync_status_pending_at(st, 0));
    try testing.expect(c.issuez_sync_status_pending_at(st, 1).ptr == null);
    try testing.expectEqual(@as(usize, 0), c.issuez_sync_status_quarantined_count(st));
    try testing.expect(c.issuez_sync_status_quarantined_at(st, 0) == null);
    c.issuez_sync_status_free(st);
    var err: ?*c.issuez_error = null;
    try testing.expect(
        c.issuez_sync_status_take(
            r.handle,
            fixture.str("bad name"),
            null,
            &st,
            &err,
        ) != c.ISSUEZ_OK,
    );
    c.issuez_error_free(err);
}

test "issuez_remote_default, issuez_remote_configure: refspecs once, upstream's on request" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    var m: ?*c.issuez_matches = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_remote_default(r.handle, null, &m, null), null);
    try testing.expectEqual(@as(usize, 0), c.issuez_matches_len(m));
    c.issuez_matches_free(m);
    _ = try fixture.hub(&r, "hub.git");
    _ = try r.git(&.{ "config", "--add", "remote.origin.fetch", "+refs/issues/*:refs/issues/*" });
    try expect.code(c.ISSUEZ_OK, c.issuez_remote_default(r.handle, null, &m, null), null);
    try expect.str("origin", c.issuez_matches_at(m, 0));
    c.issuez_matches_free(m);
    var setup: c.issuez_remote_setup = undefined;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_remote_configure(r.handle, fixture.str("origin"), 0, null, &setup, null),
        null,
    );
    try testing.expect(setup.configured and setup.unsafe and !setup.removed_unsafe);
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_remote_configure(
            r.handle,
            fixture.str("origin"),
            c.ISSUEZ_REMOTE_FLAG_FIX_UNSAFE,
            null,
            &setup,
            null,
        ),
        null,
    );
    try testing.expect(!setup.configured and setup.removed_unsafe and !setup.unsafe);
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        c.issuez_remote_configure(r.handle, fixture.str("upstream"), 0, null, &setup, null),
        null,
    );
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_remote_configure(r.handle, fixture.str("origin"), 0, null, null, null),
        null,
    );
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_remote_configure(r.handle, fixture.str("origin"), 1 << 31, null, &setup, null),
        null,
    );
}

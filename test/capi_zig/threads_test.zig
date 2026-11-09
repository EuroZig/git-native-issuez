//! One repo handle from many threads.

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

const Work = struct {
    h: *c.issuez_repo,
    seed: fixture.Created,
    failures: std.atomic.Value(u32) = .init(0),
    written: std.atomic.Value(u32) = .init(0),

    fn run(w: *Work, n: usize) void {
        for (0..12) |round| {
            switch ((n + round) % 4) {
                0 => {
                    const ops = [_]c.issuez_op{c.issuez_set_title(fixture.str("From a thread"))};
                    var out: ?*c.issuez_write = null;
                    if (c.issuez_issue_create(
                        w.h,
                        &ops,
                        1,
                        &fixture.ada,
                        null,
                        &out,
                        null,
                    ) != c.ISSUEZ_OK) {
                        _ = w.failures.fetchAdd(1, .monotonic);
                    } else _ = w.written.fetchAdd(1, .monotonic);
                    c.issuez_write_free(out);
                },
                1 => {
                    const ops = [_]c.issuez_op{c.issuez_set_comment(fixture.str("Busy"))};
                    var out: ?*c.issuez_write = null;
                    if (c.issuez_issue_update(
                        w.h,
                        w.seed.idStr(),
                        &ops,
                        1,
                        &fixture.ada,
                        null,
                        &out,
                        null,
                    ) != c.ISSUEZ_OK)
                        _ = w.failures.fetchAdd(1, .monotonic);
                    c.issuez_write_free(out);
                },
                2 => {
                    var list: ?*c.issuez_issue_list = null;
                    var q = [_]c.issuez_op{c.issuez_q_done(-1)};
                    if (c.issuez_query_run(
                        w.h,
                        &q,
                        1,
                        null,
                        &list,
                        null,
                    ) != c.ISSUEZ_OK or c.issuez_issue_list_len(list) == 0)
                        _ = w.failures.fetchAdd(1, .monotonic);
                    c.issuez_issue_list_free(list);
                },
                else => {
                    var issue: ?*c.issuez_issue = null;
                    if (c.issuez_issue_load(w.h, w.seed.idStr(), null, &issue, null) != c.ISSUEZ_OK)
                        _ = w.failures.fetchAdd(1, .monotonic);
                    c.issuez_issue_free(issue);
                },
            }
        }
    }
};

test "threads: eight threads read, query and write one repo" {
    var r = try fixture.Repo.init(.{ .ops = &.{c.issuez_opt_pool_size(3)} });
    defer r.deinit();
    var w: Work = .{ .h = r.handle, .seed = try fixture.titled(r.handle, "Seed") };
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*t, n| t.* = try std.Thread.spawn(.{}, Work.run, .{ &w, n });
    for (threads) |t| t.join();
    try testing.expectEqual(@as(u32, 0), w.failures.load(.monotonic));
    // Every create landed once; the comments are all on the seed.
    const count = try fixture.queryCount(r.handle, &.{c.issuez_q_done(-1)});
    try testing.expectEqual(@as(u64, w.written.load(.monotonic) + 1), count);
    const seed = try fixture.load(r.handle, w.seed.idStr());
    defer c.issuez_issue_free(seed);
    try testing.expectEqual(@as(usize, 24), c.issuez_issue_comment_count(seed));
}

fn hang(h: *c.issuez_repo, done: *std.atomic.Value(bool)) void {
    var out: ?*c.issuez_snapshot = null;
    var err: ?*c.issuez_error = null;
    // Holds the only session until its git times out.
    while (!done.load(.acquire)) {
        _ = c.issuez_snapshot_take(h, null, &out, &err);
        c.issuez_error_free(err);
        err = null;
        c.issuez_snapshot_free(out);
        out = null;
        break;
    }
}

fn triggerLater(t: *c.issuez_cancel) void {
    std.Io.sleep(testing.io, .fromMilliseconds(300), .awake) catch {};
    c.issuez_cancel_trigger(t);
}

test "threads: a call waiting for a busy pool is cancelled" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const made = try fixture.titled(r.handle, "Waiting");
    const slow = try fixture.slowGit(r.arena(), r.root);
    const h = try r.open(
        &.{
            c.issuez_opt_git_path(fixture.str(slow)),
            c.issuez_opt_pool_size(1),
            c.issuez_opt_timeout_local_ms(3000),
        },
    );
    defer c.issuez_repo_close(h);
    var done: std.atomic.Value(bool) = .init(false);
    const holder = try std.Thread.spawn(.{}, hang, .{ h, &done });
    std.Io.sleep(testing.io, .fromMilliseconds(200), .awake) catch {};

    const token = c.issuez_cancel_new().?;
    defer c.issuez_cancel_free(token);
    const trigger = try std.Thread.spawn(.{}, triggerLater, .{token});
    const start = std.Io.Timestamp.now(testing.io, .awake);
    var issue: ?*c.issuez_issue = null;
    try expect.code(
        c.ISSUEZ_E_CANCELLED,
        c.issuez_issue_load(h, made.idStr(), token, &issue, null),
        null,
    );
    try testing.expect(start.untilNow(testing.io, .awake).toMilliseconds() < 2000);
    trigger.join();
    done.store(true, .release);
    holder.join();
}

var logged: std.atomic.Value(u32) = .init(0);

fn countEvent(_: ?*anyopaque, _: [*c]const c.issuez_log_event) callconv(.c) void {
    _ = logged.fetchAdd(1, .monotonic);
}

test "threads: the logger is called from several threads at once" {
    var r = try fixture.Repo.init(.{ .ops = &.{c.issuez_opt_pool_size(4)} });
    defer r.deinit();
    var w: Work = .{ .h = r.handle, .seed = try fixture.titled(r.handle, "Seed") };
    logged.store(0, .monotonic);
    c.issuez_set_logger(c.ISSUEZ_LOG_DEBUG, countEvent, null);
    defer c.issuez_set_logger(c.ISSUEZ_LOG_OFF, null, null);
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, n| t.* = try std.Thread.spawn(.{}, Work.run, .{ &w, n });
    for (threads) |t| t.join();
    try testing.expectEqual(@as(u32, 0), w.failures.load(.monotonic));
    try testing.expect(logged.load(.monotonic) > 0);
}

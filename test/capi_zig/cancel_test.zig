//! Cancel tokens and the logger.

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

// covers: issuez_cancel_trigger, issuez_cancel_free
test "issuez_cancel_new: a token and NULL" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const t = c.issuez_cancel_new().?;
    defer c.issuez_cancel_free(t);
    var snap: ?*c.issuez_snapshot = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_snapshot_take(r.handle, t, &snap, null), null);
    c.issuez_snapshot_free(snap);
    // Triggering twice is the same; every call with the token stops.
    c.issuez_cancel_trigger(t);
    c.issuez_cancel_trigger(t);
    try expect.code(c.ISSUEZ_E_CANCELLED, c.issuez_snapshot_take(r.handle, t, &snap, null), null);
    try expect.code(c.ISSUEZ_E_CANCELLED, c.issuez_snapshot_take(r.handle, t, &snap, null), null);
    c.issuez_cancel_free(null);
    c.issuez_cancel_trigger(null);
}

fn triggerLater(t: *c.issuez_cancel) void {
    std.Io.sleep(testing.io, .fromMilliseconds(200), .awake) catch {};
    c.issuez_cancel_trigger(t);
}

test "issuez_fsck: a cancelled call fails, with no report" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    _ = try fixture.titled(r.handle, "Fine");
    const slow = try fixture.slowGit(r.arena(), r.root);
    const h = try r.open(&.{c.issuez_opt_git_path(fixture.str(slow))});
    defer c.issuez_repo_close(h);
    const token = c.issuez_cancel_new().?;
    defer c.issuez_cancel_free(token);
    const thread = try std.Thread.spawn(.{}, triggerLater, .{token});
    defer thread.join();
    var rep: ?*c.issuez_fsck_report = null;
    try expect.code(c.ISSUEZ_E_CANCELLED, c.issuez_fsck(h, token, &rep, null), null);
    try testing.expect(rep == null);
}

test "issuez_cancel_trigger: kills a git that is running" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const slow = try fixture.slowGit(r.arena(), r.root);
    const h = try r.open(&.{c.issuez_opt_git_path(fixture.str(slow))});
    defer c.issuez_repo_close(h);
    const token = c.issuez_cancel_new().?;
    defer c.issuez_cancel_free(token);
    const thread = try std.Thread.spawn(.{}, triggerLater, .{token});
    const start = std.Io.Timestamp.now(testing.io, .awake);
    var snap: ?*c.issuez_snapshot = null;
    var err: ?*c.issuez_error = null;
    try expect.code(c.ISSUEZ_E_CANCELLED, c.issuez_snapshot_take(h, token, &snap, &err), err);
    c.issuez_error_free(err);
    thread.join();
    try testing.expect(start.untilNow(testing.io, .awake).toMilliseconds() < 3000);
}

/// Records what the logger gets.
const Recorder = struct {
    mutex: std.Io.Mutex = .init,
    events: std.ArrayList(Event) = .empty,
    unterminated: usize = 0,

    const Event = struct { level: u32, operation: []const u8, duration_ns: i64, repo: bool };

    fn callback(userdata: ?*anyopaque, e: [*c]const c.issuez_log_event) callconv(.c) void {
        const r: *Recorder = @ptrCast(@alignCast(userdata.?));
        r.mutex.lockUncancelable(testing.io);
        defer r.mutex.unlock(testing.io);
        const ev = e.*;
        for ([_]c.issuez_str{ ev.operation, ev.message, ev.repo_path, ev.subject }) |s| {
            expect.terminated(s) catch {
                r.unterminated += 1;
            };
        }
        r.events.append(testing.allocator, .{
            .level = ev.level,
            .operation = testing.allocator.dupe(u8, fixture.slice(ev.operation)) catch return,
            .duration_ns = ev.duration_ns,
            .repo = ev.repo_path.len > 0,
        }) catch return;
    }

    fn deinit(r: *Recorder) void {
        for (r.events.items) |e| testing.allocator.free(e.operation);
        r.events.deinit(testing.allocator);
    }

    fn count(r: *Recorder, operation: []const u8) usize {
        var n: usize = 0;
        for (r.events.items) |e| {
            if (std.mem.eql(u8, e.operation, operation)) n += 1;
        }
        return n;
    }
};

test "issuez_set_logger: git requests at debug, nothing when off" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    var rec: Recorder = .{};
    defer rec.deinit();
    c.issuez_set_logger(c.ISSUEZ_LOG_DEBUG, Recorder.callback, &rec);
    _ = try fixture.titled(r.handle, "Logged");
    c.issuez_set_logger(c.ISSUEZ_LOG_OFF, null, null);
    try testing.expect(rec.count("git.update-ref") >= 1);
    try testing.expectEqual(@as(usize, 0), rec.unterminated);
    for (rec.events.items) |e| {
        try testing.expect(e.level <= c.ISSUEZ_LOG_DEBUG);
        if (std.mem.startsWith(u8, e.operation, "git.")) {
            try testing.expect(e.duration_ns >= 0);
            try testing.expect(e.repo);
        }
    }
    // Below the level: no debug events. Off: none at all.
    const before = rec.events.items.len;
    const writes = rec.count("git.update-ref");
    c.issuez_set_logger(c.ISSUEZ_LOG_INFO, Recorder.callback, &rec);
    _ = try fixture.titled(r.handle, "Quiet");
    c.issuez_set_logger(c.ISSUEZ_LOG_OFF, Recorder.callback, &rec);
    _ = try fixture.titled(r.handle, "Off");
    c.issuez_set_logger(c.ISSUEZ_LOG_OFF, null, null);
    for (rec.events.items[before..]) |e| try testing.expect(e.level <= c.ISSUEZ_LOG_INFO);
    try testing.expectEqual(writes, rec.count("git.update-ref"));
}

test "issuez_repo_set_logger: one repo's calls log to its own logger" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const other = try r.open(&.{});
    defer c.issuez_repo_close(other);
    var mine: Recorder = .{};
    defer mine.deinit();
    var global: Recorder = .{};
    defer global.deinit();
    c.issuez_set_logger(c.ISSUEZ_LOG_DEBUG, Recorder.callback, &global);
    defer c.issuez_set_logger(c.ISSUEZ_LOG_OFF, null, null);
    c.issuez_repo_set_logger(r.handle, c.ISSUEZ_LOG_DEBUG, Recorder.callback, &mine);
    _ = try fixture.titled(r.handle, "Mine");
    try testing.expect(mine.count("git.update-ref") >= 1);
    try testing.expectEqual(@as(usize, 0), global.count("git.update-ref"));
    // Another handle logs to the process-wide logger.
    _ = try fixture.titled(other, "Theirs");
    try testing.expect(global.count("git.update-ref") >= 1);
    // Unset: back to the process-wide one.
    c.issuez_repo_set_logger(r.handle, c.ISSUEZ_LOG_OFF, null, null);
    const had = mine.events.items.len;
    _ = try fixture.titled(r.handle, "Again");
    try testing.expectEqual(had, mine.events.items.len);
    c.issuez_repo_set_logger(null, c.ISSUEZ_LOG_DEBUG, null, null);
}

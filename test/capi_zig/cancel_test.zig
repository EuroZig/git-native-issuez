//! Cancel tokens and the logger (docs/test-plan.md §2.5.5).

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

// covers: issuez_cancel_trigger, issuez_cancel_triggered, issuez_cancel_free
test "issuez_cancel_new: a token and NULL" {
    fixture.ensureInit();
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    const t = c.issuez_cancel_new().?;
    try testing.expect(!c.issuez_cancel_triggered(t));
    c.issuez_cancel_trigger(t);
    try testing.expect(c.issuez_cancel_triggered(t));
    c.issuez_cancel_trigger(t);
    try testing.expect(c.issuez_cancel_triggered(t));
    c.issuez_cancel_free(t);
    c.issuez_cancel_free(null);
    c.issuez_cancel_trigger(null);
    try testing.expect(!c.issuez_cancel_triggered(null));
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
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
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
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
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

//! Queries, lists and the repo's issue cache.

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

const grace_uid = "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d";

fn at(year: i64) c.issuez_time {
    // January 1st of `year`, near enough.
    return .{ .unix_seconds = (year - 1970) * 365 * 86400, .tz_offset_minutes = 0 };
}

fn actor(name: []const u8, email: []const u8, when: *const c.issuez_time) c.issuez_actor {
    return .{
        .name = fixture.str(name),
        .email = fixture.str(email),
        .user_id = .{},
        .at = when,
        .reserved = .{ 0, 0, 0, 0 },
    };
}

fn num(target: c_uint, n: i64) c.issuez_op {
    return fixture.opNum(target, n);
}

fn qstr(target: c_uint, s: []const u8) c.issuez_op {
    return fixture.opStr(target, c.ISSUEZ_OP_ADD, s);
}

/// A, B, C (closed), D (deleted), E (A's child, blocked by B), F (wontfix).
const World = struct {
    r: fixture.Repo,
    times: [6]c.issuez_time,
    a: fixture.Created,
    b: fixture.Created,
    e: fixture.Created,
    m: fixture.Created,

    fn init() !World {
        var w: World = undefined;
        w.r = try fixture.Repo.init(.{});
        errdefer w.r.deinit();
        const h = w.r.handle;
        w.m = try fixture.milestone(h, "v1");
        for (&w.times, 0..) |*t, i| t.* = at(2020 + @as(i64, @intCast(i)));
        const ada0 = actor("Ada", "ada@example.invalid", &w.times[0]);
        const bob1 = actor("Bob", "bob@example.invalid", &w.times[1]);
        const ada2 = actor("Ada", "ada@example.invalid", &w.times[2]);
        const ada3 = actor("Ada", "ada@example.invalid", &w.times[3]);
        const ada5 = actor("Ada", "ada@example.invalid", &w.times[5]);
        w.a = try make(h, &.{
            c.issuez_set_title(fixture.str("Login crash")),
            c.issuez_set_description(fixture.str("Only on Safari.")),
            c.issuez_add_label(fixture.str("bug")),
            c.issuez_add_label(fixture.str("ui")),
            c.issuez_add_assignee(
                .{
                    .name = .{},
                    .email = fixture.str("grace@example.invalid"),
                    .user_id = fixture.str(grace_uid),
                },
            ),
            c.issuez_set_priority(c.ISSUEZ_PRIORITY_HIGH),
            c.issuez_set_milestone(w.m.idStr()),
            c.issuez_set_number(3),
            c.issuez_set_due_date(.{ .year = 2026, .month = 1, .day = 1 }),
        }, &ada0);
        w.b = try make(h, &.{
            c.issuez_set_title(fixture.str("Dark mode")),
            c.issuez_add_label(fixture.str("feature")),
            c.issuez_set_priority(c.ISSUEZ_PRIORITY_LOW),
            c.issuez_set_workflow_state(fixture.str("review")),
            c.issuez_set_number(1),
            c.issuez_set_due_date(.{ .year = 2025, .month = 6, .day = 1 }),
        }, &bob1);
        _ = try make(h, &.{
            c.issuez_set_title(fixture.str("Old bug")),
            c.issuez_add_label(fixture.str("bug")),
            c.issuez_set_state(fixture.str("closed")),
        }, &ada2);
        const gone = try make(h, &.{c.issuez_set_title(fixture.str("Gone"))}, &ada2);
        _ = try fixture.update(h, gone.idStr(), &.{c.issuez_set_deleted(true)});
        w.e = try make(h, &.{
            c.issuez_set_title(fixture.str("Child")),
            c.issuez_set_parent(w.a.idStr()),
            c.issuez_add_blocker(w.b.idStr()),
            c.issuez_set_number(2),
        }, &ada3);
        _ = try make(
            h,
            &.{
                c.issuez_set_title(fixture.str("Won't")),
                c.issuez_set_state(fixture.str("wontfix")),
            },
            &ada5,
        );
        // Comments: E two, A one, B none; dated so E stays the latest.
        for ([_]struct { fixture.Created, usize }{ .{ w.e, 2 }, .{ w.a, 1 } }) |x| {
            for (0..x[1]) |_| {
                const ops = [_]c.issuez_op{c.issuez_set_comment(fixture.str("+1"))};
                const who = actor(
                    "Ada",
                    "ada@example.invalid",
                    if (std.meta.eql(x[0].id, w.e.id)) &w.times[4] else &w.times[0],
                );
                var wr: ?*c.issuez_write = null;
                var err: ?*c.issuez_error = null;
                _ = try fixture.wrote(
                    c.issuez_issue_update(h, x[0].idStr(), &ops, 1, &who, null, &wr, &err),
                    wr,
                    err,
                    "comment",
                );
            }
        }
        return w;
    }

    fn make(
        h: *c.issuez_repo,
        ops: []const c.issuez_op,
        who: *const c.issuez_actor,
    ) !fixture.Created {
        var wr: ?*c.issuez_write = null;
        var err: ?*c.issuez_error = null;
        if (c.issuez_issue_create(h, ops.ptr, ops.len, who, null, &wr, &err) != c.ISSUEZ_OK) {
            std.debug.print("create: {s}\n", .{fixture.slice(c.issuez_error_message(err))});
            c.issuez_error_free(err);
            return error.CreateFailed;
        }
        defer c.issuez_write_free(wr);
        var out: fixture.Created = .{ .id = @splat(0), .tip = c.issuez_write_new_tip(wr) };
        @memcpy(out.id[0..36], fixture.slice(c.issuez_write_id(wr)));
        return out;
    }

    fn deinit(w: *World) void {
        w.r.deinit();
    }

    /// The titles a query returns, in order, joined by ",".
    fn titles(w: *World, ops: []const c.issuez_op) ![]const u8 {
        var list: ?*c.issuez_issue_list = null;
        var err: ?*c.issuez_error = null;
        try expect.code(
            c.ISSUEZ_OK,
            c.issuez_query_run(w.r.handle, ops.ptr, ops.len, null, &list, &err),
            err,
        );
        defer c.issuez_issue_list_free(list);
        var out: std.ArrayList(u8) = .empty;
        for (0..c.issuez_issue_list_len(list)) |i| {
            if (i > 0) try out.append(w.r.arena(), ',');
            try out.appendSlice(
                w.r.arena(),
                fixture.slice(c.issuez_issue_info_of(c.issuez_issue_list_at(list, i)).*.title),
            );
        }
        return out.items;
    }
};

test "issuez_query_run: every filter" {
    var w = try World.init();
    defer w.deinit();
    const created_asc = blk: {
        var o = num(c.ISSUEZ_OPT_Q_ORDER, c.ISSUEZ_SORT_CREATED);
        o.num2 = 1;
        break :blk o;
    };
    var unassigned = qstr(c.ISSUEZ_OPT_Q_ASSIGNEE, "");
    unassigned.str = .{ .ptr = "", .len = 0 };
    const text = fixture.opStr(c.ISSUEZ_OPT_Q_TEXT, c.ISSUEZ_OP_SET, "safari");
    var text_case = text;
    text_case.num = 1;
    var updated = num(c.ISSUEZ_OPT_Q_UPDATED, at(2022).unix_seconds);
    updated.num2 = 0;
    var no_labels = std.mem.zeroes(c.issuez_op);
    no_labels.verb = c.ISSUEZ_OP_SET;
    no_labels.target = c.ISSUEZ_OPT_Q_NO_LABELS;
    var priority_high = num(c.ISSUEZ_OPT_Q_PRIORITY, c.ISSUEZ_PRIORITY_HIGH);
    priority_high.verb = c.ISSUEZ_OP_ADD;
    var priority_low = num(c.ISSUEZ_OPT_Q_PRIORITY, c.ISSUEZ_PRIORITY_LOW);
    priority_low.verb = c.ISSUEZ_OP_ADD;
    const any = c.issuez_q_done(-1);
    const cases = [_]struct { []const c.issuez_op, []const u8 }{
        .{ &.{created_asc}, "Login crash,Dark mode,Child" },
        .{ &.{ c.issuez_q_done(1), created_asc }, "Old bug,Won't" },
        .{ &.{ any, created_asc }, "Login crash,Dark mode,Old bug,Child,Won't" },
        .{ &.{ any, num(c.ISSUEZ_OPT_Q_DELETED, 1) }, "Gone" },
        .{ &.{ any, c.issuez_q_state(fixture.str("closed")) }, "Old bug" },
        .{ &.{qstr(c.ISSUEZ_OPT_Q_WORKFLOW_STATE, "review")}, "Dark mode" },
        .{ &.{ any, c.issuez_q_label(fixture.str("bug")), created_asc }, "Login crash,Old bug" },
        .{
            &.{ c.issuez_q_label(fixture.str("bug")), c.issuez_q_label(fixture.str("ui")) },
            "Login crash",
        },
        .{ &.{ c.issuez_q_not_label(fixture.str("bug")), created_asc }, "Dark mode,Child" },
        .{ &.{no_labels}, "Child" },
        .{ &.{c.issuez_q_assignee(fixture.str("grace@example.invalid"))}, "Login crash" },
        .{ &.{c.issuez_q_assignee(fixture.str(grace_uid))}, "Login crash" },
        .{ &.{ unassigned, created_asc }, "Dark mode,Child" },
        .{ &.{qstr(c.ISSUEZ_OPT_Q_AUTHOR, "bob@example.invalid")}, "Dark mode" },
        .{ &.{priority_high}, "Login crash" },
        .{ &.{ priority_high, priority_low, created_asc }, "Login crash,Dark mode" },
        .{ &.{fixture.opStr(c.ISSUEZ_OPT_Q_PARENT, c.ISSUEZ_OP_SET, w.a.idSlice())}, "Child" },
        .{ &.{num(c.ISSUEZ_OPT_Q_BLOCKED, 1)}, "Child" },
        .{ &.{ num(c.ISSUEZ_OPT_Q_BLOCKED, 0), created_asc }, "Login crash,Dark mode" },
        .{ &.{updated}, "Child" },
        .{ &.{text}, "" },
        .{ &.{text_case}, "Login crash" },
    };
    for (cases, 0..) |case, i| {
        const got = try w.titles(case[0]);
        testing.expectEqualStrings(case[1], got) catch |e| {
            std.debug.print("case {d}\n", .{i});
            return e;
        };
    }
    // The effective milestone.
    const in_v1 = try w.titles(&.{qstr(c.ISSUEZ_OPT_Q_MILESTONE, w.m.idSlice())});
    try testing.expect(std.mem.find(u8, in_v1, "Login crash") != null);
    try testing.expect(std.mem.find(u8, in_v1, "Dark mode") == null);
}

test "issuez_query_run: every sort" {
    var w = try World.init();
    defer w.deinit();
    const Case = struct { c_uint, i64, []const c.issuez_op, []const u8 };
    const cases = [_]Case{
        .{ c.ISSUEZ_SORT_CREATED, 0, &.{}, "Child,Dark mode,Login crash" },
        .{ c.ISSUEZ_SORT_UPDATED, 0, &.{}, "Child,Dark mode,Login crash" },
        .{ c.ISSUEZ_SORT_NUMBER, 0, &.{}, "Login crash,Child,Dark mode" },
        .{ c.ISSUEZ_SORT_NUMBER, 1, &.{}, "Dark mode,Child,Login crash" },
        .{ c.ISSUEZ_SORT_PRIORITY, 0, &.{}, "Login crash,Dark mode,Child" },
        .{ c.ISSUEZ_SORT_DUE_DATE, 0, &.{}, "Dark mode,Login crash,Child" },
        .{ c.ISSUEZ_SORT_COMMENTS, 0, &.{}, "Child,Login crash,Dark mode" },
        .{
            c.ISSUEZ_SORT_STATE,
            0,
            &.{ c.issuez_q_done(-1), c.issuez_q_label(fixture.str("bug")) },
            "Login crash,Old bug",
        },
    };
    for (cases, 0..) |case, i| {
        var order = num(c.ISSUEZ_OPT_Q_ORDER, case[0]);
        order.num2 = case[1];
        var ops: std.ArrayList(c.issuez_op) = .empty;
        try ops.appendSlice(w.r.arena(), case[2]);
        try ops.append(w.r.arena(), order);
        const got = try w.titles(ops.items);
        testing.expectEqualStrings(case[3], got) catch |e| {
            std.debug.print("sort case {d}\n", .{i});
            return e;
        };
    }
}

// covers: issuez_issue_list_at, issuez_issue_list_next_cursor, issuez_issue_list_free
test "issuez_issue_list_len: pages" {
    var w = try World.init();
    defer w.deinit();
    var order = num(c.ISSUEZ_OPT_Q_ORDER, c.ISSUEZ_SORT_CREATED);
    order.num2 = 1;
    var page = [_]c.issuez_op{ order, c.issuez_q_limit(2), c.issuez_q_after(.{}) };
    var list: ?*c.issuez_issue_list = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_query_run(w.r.handle, &page, 2, null, &list, null), null);
    try testing.expectEqual(@as(usize, 2), c.issuez_issue_list_len(list));
    try expect.str("Dark mode", c.issuez_issue_info_of(c.issuez_issue_list_at(list, 1)).*.title);
    try testing.expect(c.issuez_issue_list_at(list, 2) == null);
    const cursor = c.issuez_issue_list_next_cursor(list);
    try expect.terminated(cursor);
    try testing.expect(cursor.len > 0);
    const saved = try w.r.arena().dupe(u8, fixture.slice(cursor));
    c.issuez_issue_list_free(list);
    page[2] = c.issuez_q_after(fixture.str(saved));
    try expect.code(c.ISSUEZ_OK, c.issuez_query_run(w.r.handle, &page, 3, null, &list, null), null);
    try testing.expectEqual(@as(usize, 1), c.issuez_issue_list_len(list));
    try expect.str("Child", c.issuez_issue_info_of(c.issuez_issue_list_at(list, 0)).*.title);
    try expect.str("", c.issuez_issue_list_next_cursor(list));
    c.issuez_issue_list_free(list);
    c.issuez_issue_list_free(null);
    try testing.expectEqual(@as(usize, 0), c.issuez_issue_list_len(null));
    try testing.expect(c.issuez_issue_list_at(null, 0) == null);
    var err: ?*c.issuez_error = null;
    page[2] = c.issuez_q_after(fixture.str("garbage"));
    try expect.code(
        c.ISSUEZ_E_INVALID_VALUE,
        c.issuez_query_run(w.r.handle, &page, 3, null, &list, &err),
        err,
    );
    c.issuez_error_free(err);
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_query_run(w.r.handle, null, 0, null, null, null),
        null,
    );
}

test "issuez_issue_list_skipped_count, issuez_issue_list_skipped_at: damaged issues" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    _ = try fixture.titled(r.handle, "Fine");
    const blob = try r.git(&.{ "hash-object", "-w", "--stdin" });
    const bad = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c";
    _ = try r.git(&.{ "update-ref", "refs/issues/" ++ bad, blob });
    var list: ?*c.issuez_issue_list = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_query_run(r.handle, null, 0, null, &list, null), null);
    defer c.issuez_issue_list_free(list);
    try testing.expectEqual(@as(usize, 1), c.issuez_issue_list_len(list));
    try testing.expectEqual(@as(usize, 1), c.issuez_issue_list_skipped_count(list));
    try expect.str(bad, c.issuez_issue_list_skipped_at(list, 0));
    try expect.str("", c.issuez_issue_list_skipped_at(list, 1));
    try testing.expectEqual(@as(usize, 0), c.issuez_issue_list_skipped_count(null));
}

/// Counts the object reads the library logs.
var reads: std.atomic.Value(usize) = .init(0);

fn countReads(_: ?*anyopaque, e: [*c]const c.issuez_log_event) callconv(.c) void {
    if (std.mem.eql(u8, fixture.slice(e.*.operation), "git.read-object")) _ = reads.fetchAdd(
        1,
        .monotonic,
    );
}

fn countAll(h: *c.issuez_repo) !u64 {
    return fixture.queryCount(h, &.{c.issuez_q_done(-1)});
}

test "issuez_query_run: the cache loads only what changed, and sees every change" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const h = r.handle;
    const a = try fixture.titled(h, "A");
    const b = try fixture.titled(h, "B");
    _ = try fixture.titled(h, "C");
    c.issuez_set_logger(c.ISSUEZ_LOG_DEBUG, countReads, null);
    defer c.issuez_set_logger(c.ISSUEZ_LOG_OFF, null, null);
    try testing.expectEqual(@as(u64, 3), try countAll(h));
    reads.store(0, .monotonic);
    try testing.expectEqual(@as(u64, 3), try countAll(h));
    try testing.expectEqual(@as(usize, 0), reads.load(.monotonic));

    // A write through the library, one by another tool, a purge.
    _ = try fixture.update(h, a.idStr(), &.{c.issuez_add_label(fixture.str("seen"))});
    var labelled = [_]c.issuez_op{c.issuez_q_label(fixture.str("seen"))};
    var n = try fixture.queryCount(h, &labelled);
    try testing.expectEqual(@as(u64, 1), n);
    try fixture.foreignCommit(&r, b.idSlice(), "Label\n\nLabels: seen");
    n = try fixture.queryCount(h, &labelled);
    try testing.expectEqual(@as(u64, 2), n);
    var pr: ?*c.issuez_purge_result = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_purge_issue(h, a.idStr(), &fixture.ada, fixture.str(""), null, &pr, null),
        null,
    );
    c.issuez_purge_result_free(pr);
    try testing.expectEqual(@as(u64, 2), try countAll(h));
    n = try fixture.queryCount(h, &labelled);
    try testing.expectEqual(@as(u64, 1), n);

    // With the cache off, every query reads again.
    const uncached = try r.open(&.{fixture.opNum(c.ISSUEZ_OPT_CACHE_ISSUES, 0)});
    defer c.issuez_repo_close(uncached);
    _ = try countAll(uncached);
    reads.store(0, .monotonic);
    _ = try countAll(uncached);
    try testing.expect(reads.load(.monotonic) > 0);
}

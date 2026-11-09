//! Op lists checked without a repo.

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

fn problemsOf(list: c.issuez_op_list, ops: []const c.issuez_op) !std.ArrayList(c.issuez_problem) {
    var ps: ?*c.issuez_problems = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_ops_validate(list, ops.ptr, ops.len, &ps, null), null);
    defer c.issuez_problems_free(ps);
    var out: std.ArrayList(c.issuez_problem) = .empty;
    for (0..c.issuez_problems_len(ps)) |i| try out.append(
        testing.allocator,
        c.issuez_problems_at(ps, i).*,
    );
    return out;
}

fn op(verb: c_uint, target: c_uint) c.issuez_op {
    var o = std.mem.zeroes(c.issuez_op);
    o.verb = verb;
    o.target = target;
    return o;
}

test "issuez_ops_validate: the create lists accept their ops" {
    fixture.ensureInit();
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    const cases = [_]struct { c.issuez_op_list, []const c.issuez_op }{
        .{
            c.ISSUEZ_LIST_ISSUE_CREATE,
            &.{ c.issuez_set_title(fixture.str("T")), c.issuez_add_label(fixture.str("bug")) },
        },
        .{ c.ISSUEZ_LIST_MILESTONE_CREATE, &.{c.issuez_set_name(fixture.str("v1"))} },
    };
    for (cases) |case| {
        var ps = try problemsOf(case[0], case[1]);
        defer ps.deinit(testing.allocator);
        testing.expectEqual(@as(usize, 0), ps.items.len) catch |e| {
            std.debug.print("list {d}: {s}\n", .{ case[0], fixture.slice(ps.items[0].message) });
            return e;
        };
    }
}

// covers: issuez_problems_free
test "issuez_ops_validate: each kind of mistake, at its op" {
    fixture.ensureInit();
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    const long = "x" ** 1100;
    const Case = struct { c.issuez_op_list, c.issuez_op, c_uint };
    const cases = [_]Case{
        .{
            c.ISSUEZ_LIST_ISSUE_CREATE,
            c.issuez_set_title(fixture.str("  ")),
            c.ISSUEZ_PROBLEM_EMPTY,
        },
        .{
            c.ISSUEZ_LIST_ISSUE_CREATE,
            c.issuez_set_title(fixture.str("a\nb")),
            c.ISSUEZ_PROBLEM_NEWLINE,
        },
        .{
            c.ISSUEZ_LIST_ISSUE_CREATE,
            c.issuez_set_title(fixture.str(long)),
            c.ISSUEZ_PROBLEM_TOO_LONG,
        },
        .{
            c.ISSUEZ_LIST_ISSUE_UPDATE,
            c.issuez_set_due_date(.{ .year = 2026, .month = 13, .day = 1 }),
            c.ISSUEZ_PROBLEM_BAD_FORMAT,
        },
        .{
            c.ISSUEZ_LIST_ISSUE_UPDATE,
            c.issuez_set_state(fixture.str("not a state")),
            c.ISSUEZ_PROBLEM_BAD_FORMAT,
        },
        .{
            c.ISSUEZ_LIST_ISSUE_UPDATE,
            op(c.ISSUEZ_OP_ADD, c.ISSUEZ_FIELD_TITLE),
            c.ISSUEZ_PROBLEM_BAD_VERB,
        },
        .{
            c.ISSUEZ_LIST_ISSUE_UPDATE,
            op(c.ISSUEZ_OP_SET, c.ISSUEZ_OPT_SYNC_PUSH),
            c.ISSUEZ_PROBLEM_UNKNOWN_TARGET,
        },
        .{
            c.ISSUEZ_LIST_MILESTONE_CREATE,
            c.issuez_set_title(fixture.str("T")),
            c.ISSUEZ_PROBLEM_UNKNOWN_TARGET,
        },
        .{
            c.ISSUEZ_LIST_QUERY,
            c.issuez_set_title(fixture.str("T")),
            c.ISSUEZ_PROBLEM_UNKNOWN_TARGET,
        },
        .{ c.ISSUEZ_LIST_QUERY, c.issuez_q_limit(0), c.ISSUEZ_PROBLEM_BAD_FORMAT },
        // Numbers no enum can hold fail the same way, not the process.
        .{
            c.ISSUEZ_LIST_QUERY,
            fixture.opNum(c.ISSUEZ_OPT_Q_PRIORITY, 1 << 40),
            c.ISSUEZ_PROBLEM_BAD_FORMAT,
        },
        .{
            c.ISSUEZ_LIST_QUERY,
            fixture.opNum(c.ISSUEZ_OPT_Q_ORDER, 1 << 40),
            c.ISSUEZ_PROBLEM_BAD_FORMAT,
        },
        .{
            c.ISSUEZ_LIST_PUSH_CHECK,
            fixture.opNum(c.ISSUEZ_OPT_AUTHOR_POLICY, 1 << 40),
            c.ISSUEZ_PROBLEM_UNKNOWN_TARGET,
        },
        .{
            c.ISSUEZ_LIST_QUERY,
            c.issuez_q_after(fixture.str("nope")),
            c.ISSUEZ_PROBLEM_BAD_FORMAT,
        },
        .{ c.ISSUEZ_LIST_OPEN, c.issuez_q_limit(1), c.ISSUEZ_PROBLEM_UNKNOWN_TARGET },
        .{ c.ISSUEZ_LIST_OPEN, c.issuez_opt_pool_size(0), c.ISSUEZ_PROBLEM_BAD_FORMAT },
        .{
            c.ISSUEZ_LIST_SYNC,
            c.issuez_set_title(fixture.str("T")),
            c.ISSUEZ_PROBLEM_UNKNOWN_TARGET,
        },
        .{
            c.ISSUEZ_LIST_PUSH_CHECK,
            c.issuez_opt_author_policy(77),
            c.ISSUEZ_PROBLEM_UNKNOWN_TARGET,
        },
    };
    for (cases, 0..) |case, n| {
        // A good op first, so the problem points at index 1.
        const good = switch (case[0]) {
            c.ISSUEZ_LIST_QUERY => c.issuez_q_done(1),
            c.ISSUEZ_LIST_OPEN => c.issuez_opt_pool_size(2),
            c.ISSUEZ_LIST_SYNC, c.ISSUEZ_LIST_PUSH_CHECK => c.issuez_opt_allow_numbers(true),
            c.ISSUEZ_LIST_MILESTONE_CREATE => c.issuez_set_name(fixture.str("v1")),
            else => c.issuez_add_label(fixture.str("ok")),
        };
        const sync_good = blk: {
            var o = op(c.ISSUEZ_OP_SET, c.ISSUEZ_OPT_SYNC_PUSH);
            o.num = 1;
            break :blk o;
        };
        const ops = [_]c.issuez_op{
            if (case[0] == c.ISSUEZ_LIST_SYNC) sync_good else good,
            case[1],
        };
        var ps = try problemsOf(case[0], &ops);
        defer ps.deinit(testing.allocator);
        testing.expect(ps.items.len >= 1) catch |e| {
            std.debug.print("case {d}: no problem\n", .{n});
            return e;
        };
        testing.expectEqual(case[2], ps.items[0].kind) catch |e| {
            std.debug.print("case {d}: {s}\n", .{ n, fixture.slice(ps.items[0].message) });
            return e;
        };
        try testing.expectEqual(@as(i64, 1), ps.items[0].op_index);
        try expect.terminated(ps.items[0].message);
    }
    var ps: ?*c.issuez_problems = null;
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_ops_validate(c.ISSUEZ_LIST_QUERY, null, 0, null, null),
        null,
    );
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_ops_validate(99, null, 0, &ps, null),
        null,
    );
    c.issuez_problems_free(null);
}

//! Errors and problems (docs/test-plan.md §2.5.3).

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

test "issuez_code_name: every code, distinct; unknown ones" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(testing.allocator);
    var code: c.issuez_code = c.ISSUEZ_OK;
    while (code <= c.ISSUEZ_E_INTERNAL) : (code += 1) {
        const name = std.mem.span(c.issuez_code_name(code));
        try testing.expect(name.len > 0 and !std.mem.eql(u8, name, "UNKNOWN"));
        try testing.expect(!(try seen.getOrPut(testing.allocator, name)).found_existing);
    }
    try testing.expectEqualStrings("OK", std.mem.span(c.issuez_code_name(c.ISSUEZ_OK)));
    try testing.expectEqualStrings(
        "VERSION_MISMATCH",
        std.mem.span(c.issuez_code_name(c.ISSUEZ_E_VERSION_MISMATCH)),
    );
    try testing.expectEqualStrings("UNKNOWN", std.mem.span(c.issuez_code_name(999)));
    try testing.expectEqualStrings("UNKNOWN", std.mem.span(c.issuez_code_name(999)));
}

// covers: issuez_error_code, issuez_error_message, issuez_error_subject
test "issuez_error_free: a missing issue" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const id = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c";
    var issue: ?*c.issuez_issue = null;
    var err: ?*c.issuez_error = null;
    const rc = c.issuez_issue_load(r.handle, fixture.str(id), null, &issue, &err);
    try expect.code(c.ISSUEZ_E_NOT_FOUND, rc, err);
    try testing.expectEqual(rc, c.issuez_error_code(err));
    try expect.terminated(c.issuez_error_message(err));
    try testing.expect(c.issuez_error_message(err).len > 0);
    try expect.str(id, c.issuez_error_subject(err));
    try expect.str("", c.issuez_error_git_stderr(err));
    try testing.expect(c.issuez_error_problems(err) == null);
    try testing.expect(c.issuez_error_write(err) == null);
    c.issuez_error_free(err);
    // Without err the code still comes back.
    try expect.code(
        c.ISSUEZ_E_NOT_FOUND,
        c.issuez_issue_load(r.handle, fixture.str(id), null, &issue, null),
        null,
    );
    // NULL errors read as nothing.
    c.issuez_error_free(null);
    try testing.expectEqual(@as(c.issuez_code, c.ISSUEZ_OK), c.issuez_error_code(null));
    try expect.str("", c.issuez_error_message(null));
    try expect.str("", c.issuez_error_subject(null));
}

test "issuez_error_current_tip: a stale expect reports the tip now" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const made = try fixture.titled(r.handle, "Racy");
    const now = try fixture.update(
        r.handle,
        made.idStr(),
        &.{c.issuez_add_label(fixture.str("a"))},
    );
    const ops = [_]c.issuez_op{ c.issuez_add_label(fixture.str("b")), c.issuez_expect(made.tip) };
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    const rc = c.issuez_issue_update(
        r.handle,
        made.idStr(),
        &ops,
        ops.len,
        &fixture.ada,
        null,
        &w,
        &err,
    );
    try expect.code(c.ISSUEZ_E_VERSION_MISMATCH, rc, err);
    var tip: c.issuez_oid = undefined;
    try testing.expect(c.issuez_error_current_tip(err, &tip));
    try testing.expect(c.issuez_oid_eq(&tip, &now));
    try testing.expect(c.issuez_error_current_tip(err, null));
    try expect.str(made.idSlice(), c.issuez_error_subject(err));
    c.issuez_error_free(err);
    try testing.expect(!c.issuez_error_current_tip(null, &tip));
}

test "issuez_error_problems, issuez_problems_len, issuez_problems_at: every bad value at once" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const bad = [_]c.issuez_op{
        c.issuez_set_title(fixture.str("two\nlines")),
        c.issuez_add_label(fixture.str("ok")),
        c.issuez_set_due_date(.{ .year = 2026, .month = 2, .day = 30 }),
    };
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    const rc = c.issuez_issue_create(r.handle, &bad, bad.len, &fixture.ada, null, &w, &err);
    try expect.code(c.ISSUEZ_E_INVALID_VALUE, rc, err);
    const ps = c.issuez_error_problems(err);
    try testing.expectEqual(@as(usize, 2), c.issuez_problems_len(ps));
    const first = c.issuez_problems_at(ps, 0).*;
    try testing.expectEqual(@as(u32, c.ISSUEZ_PROBLEM_NEWLINE), first.kind);
    try testing.expectEqual(@as(u32, c.ISSUEZ_FIELD_TITLE), first.field);
    try testing.expectEqual(@as(i64, 0), first.op_index);
    try expect.terminated(first.message);
    try expect.str("Title", first.key);
    const second = c.issuez_problems_at(ps, 1).*;
    try testing.expectEqual(@as(u32, c.ISSUEZ_FIELD_DUE_DATE), second.field);
    try testing.expectEqual(@as(i64, 2), second.op_index);
    try testing.expect(c.issuez_problems_at(ps, 2) == null);
    try testing.expectEqual(@as(usize, 0), c.issuez_problems_len(null));
    try testing.expect(c.issuez_problems_at(null, 0) == null);
    c.issuez_error_free(err);
}

test "issuez_error_git_stderr: what git said when a fetch failed" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    _ = try r.git(&.{ "remote", "add", "origin", "/nonexistent/hub.git" });
    var report: ?*c.issuez_sync_report = null;
    var err: ?*c.issuez_error = null;
    const rc = c.issuez_sync(r.handle, fixture.str("origin"), null, 0, null, &report, &err);
    try testing.expect(rc == c.ISSUEZ_E_NETWORK or rc == c.ISSUEZ_E_GIT);
    const stderr = fixture.slice(c.issuez_error_git_stderr(err));
    try expect.terminated(c.issuez_error_git_stderr(err));
    try testing.expect(std.mem.find(u8, stderr, "nonexistent") != null);
    c.issuez_error_free(err);
}

test "issuez_error_write: a cancelled write didn't happen" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const cancel = c.issuez_cancel_new();
    defer c.issuez_cancel_free(cancel);
    c.issuez_cancel_trigger(cancel);
    const ops = [_]c.issuez_op{c.issuez_set_title(fixture.str("Never"))};
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    const rc = c.issuez_issue_create(r.handle, &ops, 1, &fixture.ada, cancel, &w, &err);
    try expect.code(c.ISSUEZ_E_CANCELLED, rc, err);
    try testing.expect(c.issuez_error_write(err) == null);
    try testing.expect(c.issuez_error_write(null) == null);
    c.issuez_error_free(err);
    var count: u64 = 99;
    var all = [_]c.issuez_op{c.issuez_q_done(-1)};
    try expect.code(c.ISSUEZ_OK, c.issuez_query_count(r.handle, &all, 1, null, &count, null), null);
    try testing.expectEqual(@as(u64, 0), count);
}

test "issuez_field_key: trailer keys" {
    try testing.expectEqualStrings(
        "X-Due-Date",
        std.mem.span(c.issuez_field_key(c.ISSUEZ_FIELD_DUE_DATE)),
    );
    try testing.expectEqualStrings(
        "Labels",
        std.mem.span(c.issuez_field_key(c.ISSUEZ_FIELD_LABELS)),
    );
    try testing.expectEqualStrings("Title", std.mem.span(c.issuez_field_key(c.ISSUEZ_FIELD_TITLE)));
    try testing.expectEqualStrings(
        "X-Number",
        std.mem.span(c.issuez_field_key(c.ISSUEZ_FIELD_NUMBER)),
    );
    try testing.expectEqualStrings("", std.mem.span(c.issuez_field_key(9999)));
}

test "issuez_problems_free: owned lists; NULL is fine" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var ps: ?*c.issuez_problems = null;
    const ops = [_]c.issuez_op{c.issuez_set_title(fixture.str(""))};
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_ops_validate(c.ISSUEZ_LIST_ISSUE_CREATE, &ops, 1, &ps, null),
        null,
    );
    try testing.expectEqual(@as(usize, 1), c.issuez_problems_len(ps));
    c.issuez_problems_free(ps);
    c.issuez_problems_free(null);
}

test "issuez_error_problems: the field and value the library refused" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    var limit = fixture.opNum(c.ISSUEZ_OPT_LIMIT, 4);
    limit.name = fixture.str("max_title_bytes");
    try r.init(.{ .ops = &.{limit} });
    defer r.deinit();
    const h = r.handle;
    const made = try fixture.titled(h, "Okay");
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    const ops = [_]c.issuez_op{c.issuez_set_title(fixture.str("Far too long"))};
    try testing.expectEqual(
        @as(c.issuez_code, c.ISSUEZ_E_LIMIT),
        c.issuez_issue_update(h, made.idStr(), &ops, 1, &fixture.ada, null, &w, &err),
    );
    defer c.issuez_error_free(err);
    const ps = c.issuez_error_problems(err);
    try testing.expect(c.issuez_problems_len(ps) >= 1);
    const p = c.issuez_problems_at(ps, 0).*;
    try testing.expectEqual(@as(c_uint, c.ISSUEZ_FIELD_TITLE), p.field);
    try expect.str("Title", p.key);
    try expect.str("Far too long", p.value);
}

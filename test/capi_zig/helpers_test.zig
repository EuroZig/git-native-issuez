//! The generated op helpers and the header's macros: each builds the op
//! the API description says, and the call it belongs to accepts it. The
//! table follows issuez-api.json's helpers.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

const api_json = @embedFile("issuez-api.json");

const Want = struct {
    str: ?[]const u8 = null,
    num: ?i64 = null,
    num2: ?i64 = null,
    name: ?[]const u8 = null,
    date: bool = false,
    oid: bool = false,
    person: bool = false,
};

const Row = struct {
    name: []const u8,
    op: c.issuez_op,
    verb: c_uint,
    target: c_uint,
    list: c.issuez_op_list,
    want: Want,
    /// An op the call needs beside it.
    with: ?c.issuez_op = null,
};

const set: c_uint = c.ISSUEZ_OP_SET;
const add: c_uint = c.ISSUEZ_OP_ADD;
const clear: c_uint = c.ISSUEZ_OP_CLEAR;
const remove: c_uint = c.ISSUEZ_OP_REMOVE;
const inherit: c_uint = c.ISSUEZ_OP_INHERIT;

const update: c.issuez_op_list = c.ISSUEZ_LIST_ISSUE_UPDATE;
const milestone: c.issuez_op_list = c.ISSUEZ_LIST_MILESTONE_UPDATE;
const query: c.issuez_op_list = c.ISSUEZ_LIST_QUERY;
const open: c.issuez_op_list = c.ISSUEZ_LIST_OPEN;
const push: c.issuez_op_list = c.ISSUEZ_LIST_PUSH_CHECK;

const uuid = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c";
const ada = "ada@example.invalid";

/// The row for `issuez_<helper>(args...)`, whose op targets `ISSUEZ_<target>`.
fn row(
    comptime helper: []const u8,
    args: anytype,
    verb: c_uint,
    comptime target: []const u8,
    list: c.issuez_op_list,
    want: Want,
) Row {
    return .{
        .name = "issuez_" ++ helper,
        .op = @call(.auto, @field(c, "issuez_" ++ helper), args),
        .verb = verb,
        .target = @field(c, "ISSUEZ_" ++ target),
        .list = list,
        .want = want,
    };
}

/// A helper that takes one string and puts it in the op.
fn strRow(
    comptime helper: []const u8,
    s: []const u8,
    verb: c_uint,
    comptime target: []const u8,
    list: c.issuez_op_list,
) Row {
    return row(helper, .{fixture.str(s)}, verb, target, list, .{ .str = s });
}

const sample_person: c.issuez_person = .{
    .name = .{},
    .email = .{ .ptr = "grace@example.invalid", .len = 21 },
    .user_id = .{},
};

var sample_oid: c.issuez_oid = blk: {
    var o = std.mem.zeroes(c.issuez_oid);
    o.len = 20;
    o.bytes[0] = 0xab;
    break :blk o;
};

/// `issuez_add_attachment`, except on x86_64 macOS: Zig 0.16 can't compile
/// the translated helper there (LLVM: "Intrinsic has incorrect argument
/// type!" for its third issuez_str, passed on the stack), so the test
/// builds the op the helper does. C and cgo callers aren't affected.
fn addAttachment(id: c.issuez_str, name: c.issuez_str, data: c.issuez_str) c.issuez_op {
    if (comptime builtin.cpu.arch != .x86_64 or !builtin.os.tag.isDarwin())
        return c.issuez_add_attachment(id, name, data);
    var o = std.mem.zeroes(c.issuez_op);
    o.verb = c.ISSUEZ_OP_ADD;
    o.target = c.ISSUEZ_FIELD_ATTACHMENTS;
    o.id = id;
    o.name = name;
    o.str = data;
    return o;
}

// covers: issuez_set_description, issuez_set_comment, issuez_set_state, issuez_set_fixed_by
// covers: issuez_set_release, issuez_set_reason, issuez_set_workflow_state
// covers: issuez_clear_workflow_state, issuez_add_label, issuez_remove_label, issuez_clear_labels
// covers: issuez_add_assignee, issuez_remove_assignee, issuez_clear_assignees, issuez_set_priority
// covers: issuez_clear_priority, issuez_set_milestone, issuez_inherit_milestone
// covers: issuez_clear_milestone, issuez_set_parent, issuez_clear_parent, issuez_add_blocker
// covers: issuez_remove_blocker, issuez_set_start_date, issuez_clear_start_date
// covers: issuez_set_due_date, issuez_clear_due_date, issuez_set_estimate, issuez_clear_estimate
// covers: issuez_set_deleted, issuez_set_number, issuez_set_name, issuez_set_milestone_status
// covers: issuez_set_extra, issuez_expect, issuez_set_subject, issuez_q_label, issuez_q_not_label
// covers: issuez_q_assignee, issuez_q_state, issuez_q_done, issuez_q_limit, issuez_q_after
// covers: issuez_opt_git_path, issuez_opt_committer, issuez_opt_pool_size, issuez_opt_pusher
// covers: issuez_opt_pusher_email, issuez_opt_author_policy, issuez_opt_allow_numbers
// covers: issuez_opt_allow_purge, issuez_opt_object_dir, issuez_opt_alternate_object_dirs
// covers: issuez_opt_pusher_user_id, issuez_set_ref, issuez_clear_ref, issuez_set_locked
// covers: issuez_add_attachment, issuez_remove_attachment, issuez_set_original_author
// covers: issuez_set_original_id, issuez_edit_comment, issuez_expect_edits, issuez_delete_comment
// covers: issuez_restore_comment, issuez_add_reaction, issuez_remove_reaction
// covers: issuez_reaction_target, issuez_q_deleted, issuez_q_workflow_state, issuez_q_no_labels
// covers: issuez_q_author, issuez_q_priority, issuez_q_milestone, issuez_q_parent
// covers: issuez_q_blocked, issuez_q_updated, issuez_q_text, issuez_q_order, issuez_opt_env
// covers: issuez_opt_done_state, issuez_opt_workflow_state, issuez_opt_exclusive_scope
// covers: issuez_opt_extra_prefix, issuez_opt_timeout_local_ms
// covers: issuez_opt_limit, issuez_opt_cache_issues, issuez_opt_attachment_store
test "issuez_set_title: each builds its op, and its call accepts it" {
    fixture.ensureInit();
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    const rows = [_]Row{
        strRow("set_title", "text", set, "FIELD_TITLE", update),
        strRow("set_description", "text", set, "FIELD_DESCRIPTION", update),
        strRow("set_comment", "text", set, "FIELD_COMMENT", update),
        strRow("set_state", "closed", set, "FIELD_STATE", update),
        strRow("set_fixed_by", "text", set, "FIELD_FIXED_BY", update),
        strRow("set_release", "text", set, "FIELD_RELEASE", update),
        strRow("set_reason", "text", set, "FIELD_REASON", update),
        strRow("set_workflow_state", "ready", set, "FIELD_WORKFLOW_STATE", update),
        row("clear_workflow_state", .{}, clear, "FIELD_WORKFLOW_STATE", update, .{}),
        strRow("add_label", "bug", add, "FIELD_LABELS", update),
        strRow("remove_label", "bug", remove, "FIELD_LABELS", update),
        row("clear_labels", .{}, clear, "FIELD_LABELS", update, .{}),
        row("add_assignee", .{sample_person}, add, "FIELD_ASSIGNEES", update, .{ .person = true }),
        .{
            .name = "issuez_remove_assignee",
            .op = c.issuez_remove_assignee(sample_person),
            .verb = c.ISSUEZ_OP_REMOVE,
            .target = c.ISSUEZ_FIELD_ASSIGNEES,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .person = true },
        },
        row("clear_assignees", .{}, clear, "FIELD_ASSIGNEES", update, .{}),
        .{
            .name = "issuez_set_priority",
            .op = c.issuez_set_priority(c.ISSUEZ_PRIORITY_HIGH),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_PRIORITY,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .num = c.ISSUEZ_PRIORITY_HIGH },
        },
        row("clear_priority", .{}, clear, "FIELD_PRIORITY", update, .{}),
        strRow("set_milestone", uuid, set, "FIELD_MILESTONE", update),
        row("inherit_milestone", .{}, inherit, "FIELD_MILESTONE", update, .{}),
        row("clear_milestone", .{}, clear, "FIELD_MILESTONE", update, .{}),
        strRow("set_parent", uuid, set, "FIELD_PARENT", update),
        row("clear_parent", .{}, clear, "FIELD_PARENT", update, .{}),
        strRow("add_blocker", uuid, add, "FIELD_BLOCKED_BY", update),
        strRow("remove_blocker", uuid, remove, "FIELD_BLOCKED_BY", update),
        .{
            .name = "issuez_set_start_date",
            .op = c.issuez_set_start_date(.{ .year = 2026, .month = 1, .day = 2 }),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_START_DATE,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .date = true },
        },
        row("clear_start_date", .{}, clear, "FIELD_START_DATE", update, .{}),
        .{
            .name = "issuez_set_due_date",
            .op = c.issuez_set_due_date(.{ .year = 2026, .month = 1, .day = 2 }),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_DUE_DATE,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .date = true },
        },
        row("clear_due_date", .{}, clear, "FIELD_DUE_DATE", update, .{}),
        row("set_estimate", .{30}, set, "FIELD_ESTIMATE", update, .{ .num = 30 }),
        row("clear_estimate", .{}, clear, "FIELD_ESTIMATE", update, .{}),
        row("set_deleted", .{true}, set, "FIELD_DELETED", update, .{ .num = 1 }),
        row("set_number", .{7}, set, "FIELD_NUMBER", update, .{ .num = 7 }),
        strRow("set_name", "text", set, "FIELD_NAME", milestone),
        .{
            .name = "issuez_set_milestone_status",
            .op = c.issuez_set_milestone_status(c.ISSUEZ_MILESTONE_COMPLETED),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_MILESTONE_STATUS,
            .list = c.ISSUEZ_LIST_MILESTONE_UPDATE,
            .want = .{ .num = c.ISSUEZ_MILESTONE_COMPLETED },
        },
        .{
            .name = "issuez_set_extra",
            .op = c.issuez_set_extra(fixture.str("X-Forgejo-Project"), fixture.str("3")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_EXTRA,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .name = "X-Forgejo-Project", .str = "3" },
        },
        row("expect", .{sample_oid}, set, "OPT_EXPECT", update, .{ .oid = true }),
        strRow("set_subject", "text", set, "OPT_SUBJECT", update),
        strRow("q_label", "text", add, "OPT_Q_LABEL", query),
        strRow("q_not_label", "text", add, "OPT_Q_NOT_LABEL", query),
        strRow("q_assignee", ada, add, "OPT_Q_ASSIGNEE", query),
        strRow("q_state", "open", add, "OPT_Q_STATE", query),
        row("q_done", .{1}, set, "OPT_Q_DONE", query, .{ .num = 1 }),
        row("q_limit", .{5}, set, "OPT_Q_LIMIT", query, .{ .num = 5 }),
        strRow("q_after", "o:1", set, "OPT_Q_AFTER", query),
        strRow("opt_git_path", "git", set, "OPT_GIT_PATH", open),
        .{
            .name = "issuez_opt_committer",
            .op = c.issuez_opt_committer(
                fixture.str("Server"),
                fixture.str("server@example.invalid"),
            ),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_COMMITTER,
            .list = c.ISSUEZ_LIST_OPEN,
            .want = .{ .person = true },
        },
        row("opt_pool_size", .{2}, set, "OPT_POOL_SIZE", open, .{ .num = 2 }),
        row("opt_pusher", .{sample_person}, set, "OPT_PUSHER", push, .{ .person = true }),
        strRow("opt_pusher_email", ada, add, "OPT_PUSHER_EMAIL", push),
        .{
            .name = "issuez_opt_author_policy",
            .op = c.issuez_opt_author_policy(c.ISSUEZ_AUTHOR_ENFORCE),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_AUTHOR_POLICY,
            .list = c.ISSUEZ_LIST_PUSH_CHECK,
            .want = .{ .num = c.ISSUEZ_AUTHOR_ENFORCE },
        },
        row("opt_allow_numbers", .{true}, set, "OPT_ALLOW_NUMBERS", push, .{ .num = 1 }),
        row("opt_allow_purge", .{true}, set, "OPT_ALLOW_PURGE", push, .{ .num = 1 }),
        .{
            .name = "issuez_opt_pusher_user_id",
            .op = c.issuez_opt_pusher_user_id(fixture.str("0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d")),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_OPT_PUSHER_USER_ID,
            .list = c.ISSUEZ_LIST_PUSH_CHECK,
            .want = .{ .str = "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d" },
        },
        strRow("opt_object_dir", "/tmp/objects", set, "OPT_OBJECT_DIR", push),
        .{
            .name = "issuez_opt_alternate_object_dirs",
            .op = c.issuez_opt_alternate_object_dirs(fixture.str("/tmp/alternates")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_ALTERNATE_OBJECT_DIRS,
            .list = c.ISSUEZ_LIST_PUSH_CHECK,
            .want = .{ .str = "/tmp/alternates" },
        },
        strRow("set_ref", "main", set, "FIELD_REF", update),
        row("clear_ref", .{}, clear, "FIELD_REF", update, .{}),
        .{
            .name = "issuez_set_locked",
            .op = c.issuez_set_locked(true, fixture.str("heated")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_LOCKED,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .num = 1, .str = "heated" },
        },
        .{
            .name = "issuez_add_attachment",
            .op = addAttachment(
                fixture.str("0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c"),
                fixture.str("a.png"),
                fixture.str("bytes"),
            ),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_FIELD_ATTACHMENTS,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .name = "a.png", .str = "bytes" },
        },
        strRow("remove_attachment", uuid, remove, "FIELD_ATTACHMENTS", update),
        strRow("set_original_author", "octo@github", set, "OPT_ORIGINAL_AUTHOR", update),
        strRow("set_original_id", "gh-1", set, "OPT_ORIGINAL_ID", update),
        .{
            .name = "issuez_edit_comment",
            .op = c.issuez_edit_comment(sample_oid),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_EDIT_COMMENT,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .oid = true },
            .with = c.issuez_set_comment(fixture.str("text")),
        },
        row("expect_edits", .{2}, set, "OPT_EXPECT_EDITS", update, .{ .num = 2 }),
        row("delete_comment", .{sample_oid}, set, "OPT_DELETE_COMMENT", update, .{ .oid = true }),
        row("restore_comment", .{sample_oid}, set, "OPT_RESTORE_COMMENT", update, .{ .oid = true }),
        strRow("add_reaction", ":+1:", add, "FIELD_REACTIONS", update),
        strRow("remove_reaction", ":+1:", remove, "FIELD_REACTIONS", update),
        row("reaction_target", .{sample_oid}, set, "OPT_REACTION_TARGET", update, .{ .oid = true }),
        row("q_deleted", .{1}, set, "OPT_Q_DELETED", query, .{ .num = 1 }),
        strRow("q_workflow_state", "ready", add, "OPT_Q_WORKFLOW_STATE", query),
        row("q_no_labels", .{}, set, "OPT_Q_NO_LABELS", query, .{}),
        strRow("q_author", ada, add, "OPT_Q_AUTHOR", query),
        .{
            .name = "issuez_q_priority",
            .op = c.issuez_q_priority(c.ISSUEZ_PRIORITY_HIGH),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_OPT_Q_PRIORITY,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .num = c.ISSUEZ_PRIORITY_HIGH },
        },
        strRow("q_milestone", uuid, add, "OPT_Q_MILESTONE", query),
        strRow("q_parent", uuid, set, "OPT_Q_PARENT", query),
        row("q_blocked", .{true}, set, "OPT_Q_BLOCKED", query, .{ .num = 1 }),
        row("q_updated", .{ 100, 200 }, set, "OPT_Q_UPDATED", query, .{ .num = 100, .num2 = 200 }),
        .{
            .name = "issuez_q_text",
            .op = c.issuez_q_text(fixture.str("crash"), true),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_Q_TEXT,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .num = 1, .str = "crash" },
        },
        .{
            .name = "issuez_q_order",
            .op = c.issuez_q_order(c.ISSUEZ_SORT_UPDATED, true),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_Q_ORDER,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .num = c.ISSUEZ_SORT_UPDATED, .num2 = 1 },
        },
        .{
            .name = "issuez_opt_env",
            .op = c.issuez_opt_env(fixture.str("LANG"), fixture.str("C")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_ENV,
            .list = c.ISSUEZ_LIST_OPEN,
            .want = .{ .name = "LANG", .str = "C" },
        },
        strRow("opt_done_state", "wontfix", add, "OPT_DONE_STATE", open),
        strRow("opt_workflow_state", "ready", add, "OPT_WORKFLOW_STATE", open),
        strRow("opt_exclusive_scope", "kind", add, "OPT_EXCLUSIVE_SCOPE", open),
        strRow("opt_extra_prefix", "X-Acme-", add, "OPT_EXTRA_PREFIX", open),
        row("opt_timeout_local_ms", .{5000}, set, "OPT_TIMEOUT_LOCAL_MS", open, .{ .num = 5000 }),
        .{
            .name = "issuez_opt_limit",
            .op = c.issuez_opt_limit(fixture.str("max_labels"), 9),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_LIMIT,
            .list = c.ISSUEZ_LIST_OPEN,
            .want = .{ .name = "max_labels", .num = 9 },
        },
        row("opt_cache_issues", .{10}, set, "OPT_CACHE_ISSUES", open, .{ .num = 10 }),
        row("opt_attachment_store", .{false}, set, "OPT_ATTACHMENT_STORE", open, .{ .num = 0 }),
    };
    // Every helper the API describes is in the table.
    const Api = struct { helpers: []const struct { name: []const u8 } };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const api = try std.json.parseFromSliceLeaky(
        Api,
        arena.allocator(),
        api_json,
        .{ .ignore_unknown_fields = true },
    );
    try testing.expectEqual(api.helpers.len, rows.len);
    for (api.helpers, rows) |h, r| try testing.expectEqualStrings(h.name, r.name);

    for (rows) |r| {
        errdefer std.debug.print("helper {s}\n", .{r.name});
        try testing.expectEqual(r.verb, r.op.verb);
        try testing.expectEqual(r.target, r.op.target);
        try testing.expect(std.mem.allEqual(u64, &r.op.reserved, 0));
        if (r.want.str) |s| try testing.expectEqualStrings(s, fixture.slice(r.op.str));
        if (r.want.num) |n| try testing.expectEqual(n, r.op.num);
        if (r.want.num2) |n| try testing.expectEqual(n, r.op.num2);
        if (r.want.name) |s| try testing.expectEqualStrings(s, fixture.slice(r.op.name));
        if (r.want.date) try testing.expectEqual(@as(c_int, 2), @as(c_int, r.op.date.day));
        if (r.want.oid) try testing.expect(fixture.oidEql(r.op.oid, sample_oid));
        if (r.want.person) try testing.expect(r.op.person.email.len > 0);
        var ps: ?*c.issuez_problems = null;
        const ops = [_]c.issuez_op{ r.op, r.with orelse r.op };
        const n: usize = if (r.with != null) 2 else 1;
        try expect.code(c.ISSUEZ_OK, c.issuez_ops_validate(r.list, &ops, n, &ps, null), null);
        defer c.issuez_problems_free(ps);
        if (c.issuez_problems_len(ps) > 0) {
            std.debug.print(
                "{s}: {s}\n",
                .{ r.name, fixture.slice(c.issuez_problems_at(ps, 0).*.message) },
            );
            return error.HelperRefused;
        }
    }
}

test "macros: ISSUEZ_STR, issuez_str_c, ISSUEZ_COUNT" {
    const s = c.ISSUEZ_STR("abc");
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqualStrings("abc", fixture.slice(s));
    const z = c.issuez_str_c("hello");
    try testing.expectEqual(@as(usize, 5), z.len);
    const empty = c.issuez_str_c(null);
    try testing.expectEqual(@as(usize, 0), empty.len);
    const arr = [_]c.issuez_op{ c.issuez_q_done(1), c.issuez_q_limit(2), c.issuez_clear_labels() };
    try testing.expectEqual(@as(usize, 3), c.ISSUEZ_COUNT(arr));
}

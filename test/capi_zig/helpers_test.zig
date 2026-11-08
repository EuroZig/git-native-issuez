//! The generated op helpers and the header's macros: each builds the op
//! the API description says, and the call it belongs to accepts it. The
//! table follows issuez-api.json's helpers.

const std = @import("std");
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
// covers: issuez_opt_extra_prefix, issuez_opt_timeout_local_ms, issuez_opt_timeout_network_ms
// covers: issuez_opt_limit, issuez_opt_cache_issues, issuez_opt_attachment_store
// covers: issuez_opt_sync_push, issuez_opt_sync_attachments
test "issuez_set_title: each builds its op, and its call accepts it" {
    fixture.ensureInit();
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    const rows = [_]Row{
        .{
            .name = "issuez_set_title",
            .op = c.issuez_set_title(fixture.str("text")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_TITLE,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "text" },
        },
        .{
            .name = "issuez_set_description",
            .op = c.issuez_set_description(fixture.str("text")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_DESCRIPTION,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "text" },
        },
        .{
            .name = "issuez_set_comment",
            .op = c.issuez_set_comment(fixture.str("text")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_COMMENT,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "text" },
        },
        .{
            .name = "issuez_set_state",
            .op = c.issuez_set_state(fixture.str("closed")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_STATE,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "closed" },
        },
        .{
            .name = "issuez_set_fixed_by",
            .op = c.issuez_set_fixed_by(fixture.str("text")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_FIXED_BY,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "text" },
        },
        .{
            .name = "issuez_set_release",
            .op = c.issuez_set_release(fixture.str("text")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_RELEASE,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "text" },
        },
        .{
            .name = "issuez_set_reason",
            .op = c.issuez_set_reason(fixture.str("text")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_REASON,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "text" },
        },
        .{
            .name = "issuez_set_workflow_state",
            .op = c.issuez_set_workflow_state(fixture.str("ready")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_WORKFLOW_STATE,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "ready" },
        },
        .{
            .name = "issuez_clear_workflow_state",
            .op = c.issuez_clear_workflow_state(),
            .verb = c.ISSUEZ_OP_CLEAR,
            .target = c.ISSUEZ_FIELD_WORKFLOW_STATE,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{},
        },
        .{
            .name = "issuez_add_label",
            .op = c.issuez_add_label(fixture.str("bug")),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_FIELD_LABELS,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "bug" },
        },
        .{
            .name = "issuez_remove_label",
            .op = c.issuez_remove_label(fixture.str("bug")),
            .verb = c.ISSUEZ_OP_REMOVE,
            .target = c.ISSUEZ_FIELD_LABELS,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "bug" },
        },
        .{
            .name = "issuez_clear_labels",
            .op = c.issuez_clear_labels(),
            .verb = c.ISSUEZ_OP_CLEAR,
            .target = c.ISSUEZ_FIELD_LABELS,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{},
        },
        .{
            .name = "issuez_add_assignee",
            .op = c.issuez_add_assignee(sample_person),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_FIELD_ASSIGNEES,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .person = true },
        },
        .{
            .name = "issuez_remove_assignee",
            .op = c.issuez_remove_assignee(sample_person),
            .verb = c.ISSUEZ_OP_REMOVE,
            .target = c.ISSUEZ_FIELD_ASSIGNEES,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .person = true },
        },
        .{
            .name = "issuez_clear_assignees",
            .op = c.issuez_clear_assignees(),
            .verb = c.ISSUEZ_OP_CLEAR,
            .target = c.ISSUEZ_FIELD_ASSIGNEES,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{},
        },
        .{
            .name = "issuez_set_priority",
            .op = c.issuez_set_priority(c.ISSUEZ_PRIORITY_HIGH),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_PRIORITY,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .num = c.ISSUEZ_PRIORITY_HIGH },
        },
        .{
            .name = "issuez_clear_priority",
            .op = c.issuez_clear_priority(),
            .verb = c.ISSUEZ_OP_CLEAR,
            .target = c.ISSUEZ_FIELD_PRIORITY,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{},
        },
        .{
            .name = "issuez_set_milestone",
            .op = c.issuez_set_milestone(fixture.str("0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_MILESTONE,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c" },
        },
        .{
            .name = "issuez_inherit_milestone",
            .op = c.issuez_inherit_milestone(),
            .verb = c.ISSUEZ_OP_INHERIT,
            .target = c.ISSUEZ_FIELD_MILESTONE,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{},
        },
        .{
            .name = "issuez_clear_milestone",
            .op = c.issuez_clear_milestone(),
            .verb = c.ISSUEZ_OP_CLEAR,
            .target = c.ISSUEZ_FIELD_MILESTONE,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{},
        },
        .{
            .name = "issuez_set_parent",
            .op = c.issuez_set_parent(fixture.str("0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_PARENT,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c" },
        },
        .{
            .name = "issuez_clear_parent",
            .op = c.issuez_clear_parent(),
            .verb = c.ISSUEZ_OP_CLEAR,
            .target = c.ISSUEZ_FIELD_PARENT,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{},
        },
        .{
            .name = "issuez_add_blocker",
            .op = c.issuez_add_blocker(fixture.str("0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c")),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_FIELD_BLOCKED_BY,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c" },
        },
        .{
            .name = "issuez_remove_blocker",
            .op = c.issuez_remove_blocker(fixture.str("0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c")),
            .verb = c.ISSUEZ_OP_REMOVE,
            .target = c.ISSUEZ_FIELD_BLOCKED_BY,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c" },
        },
        .{
            .name = "issuez_set_start_date",
            .op = c.issuez_set_start_date(.{ .year = 2026, .month = 1, .day = 2 }),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_START_DATE,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .date = true },
        },
        .{
            .name = "issuez_clear_start_date",
            .op = c.issuez_clear_start_date(),
            .verb = c.ISSUEZ_OP_CLEAR,
            .target = c.ISSUEZ_FIELD_START_DATE,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{},
        },
        .{
            .name = "issuez_set_due_date",
            .op = c.issuez_set_due_date(.{ .year = 2026, .month = 1, .day = 2 }),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_DUE_DATE,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .date = true },
        },
        .{
            .name = "issuez_clear_due_date",
            .op = c.issuez_clear_due_date(),
            .verb = c.ISSUEZ_OP_CLEAR,
            .target = c.ISSUEZ_FIELD_DUE_DATE,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{},
        },
        .{
            .name = "issuez_set_estimate",
            .op = c.issuez_set_estimate(30),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_ESTIMATE,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .num = 30 },
        },
        .{
            .name = "issuez_clear_estimate",
            .op = c.issuez_clear_estimate(),
            .verb = c.ISSUEZ_OP_CLEAR,
            .target = c.ISSUEZ_FIELD_ESTIMATE,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{},
        },
        .{
            .name = "issuez_set_deleted",
            .op = c.issuez_set_deleted(true),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_DELETED,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .num = 1 },
        },
        .{
            .name = "issuez_set_number",
            .op = c.issuez_set_number(7),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_NUMBER,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .num = 7 },
        },
        .{
            .name = "issuez_set_name",
            .op = c.issuez_set_name(fixture.str("text")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_NAME,
            .list = c.ISSUEZ_LIST_MILESTONE_UPDATE,
            .want = .{ .str = "text" },
        },
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
        .{
            .name = "issuez_expect",
            .op = c.issuez_expect(sample_oid),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_EXPECT,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .oid = true },
        },
        .{
            .name = "issuez_set_subject",
            .op = c.issuez_set_subject(fixture.str("text")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_SUBJECT,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "text" },
        },
        .{
            .name = "issuez_q_label",
            .op = c.issuez_q_label(fixture.str("text")),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_OPT_Q_LABEL,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .str = "text" },
        },
        .{
            .name = "issuez_q_not_label",
            .op = c.issuez_q_not_label(fixture.str("text")),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_OPT_Q_NOT_LABEL,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .str = "text" },
        },
        .{
            .name = "issuez_q_assignee",
            .op = c.issuez_q_assignee(fixture.str("ada@example.invalid")),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_OPT_Q_ASSIGNEE,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .str = "ada@example.invalid" },
        },
        .{
            .name = "issuez_q_state",
            .op = c.issuez_q_state(fixture.str("open")),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_OPT_Q_STATE,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .str = "open" },
        },
        .{
            .name = "issuez_q_done",
            .op = c.issuez_q_done(1),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_Q_DONE,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .num = 1 },
        },
        .{
            .name = "issuez_q_limit",
            .op = c.issuez_q_limit(5),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_Q_LIMIT,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .num = 5 },
        },
        .{
            .name = "issuez_q_after",
            .op = c.issuez_q_after(fixture.str("o:1")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_Q_AFTER,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .str = "o:1" },
        },
        .{
            .name = "issuez_opt_git_path",
            .op = c.issuez_opt_git_path(fixture.str("git")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_GIT_PATH,
            .list = c.ISSUEZ_LIST_OPEN,
            .want = .{ .str = "git" },
        },
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
        .{
            .name = "issuez_opt_pool_size",
            .op = c.issuez_opt_pool_size(2),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_POOL_SIZE,
            .list = c.ISSUEZ_LIST_OPEN,
            .want = .{ .num = 2 },
        },
        .{
            .name = "issuez_opt_pusher",
            .op = c.issuez_opt_pusher(sample_person),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_PUSHER,
            .list = c.ISSUEZ_LIST_PUSH_CHECK,
            .want = .{ .person = true },
        },
        .{
            .name = "issuez_opt_pusher_email",
            .op = c.issuez_opt_pusher_email(fixture.str("ada@example.invalid")),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_OPT_PUSHER_EMAIL,
            .list = c.ISSUEZ_LIST_PUSH_CHECK,
            .want = .{ .str = "ada@example.invalid" },
        },
        .{
            .name = "issuez_opt_author_policy",
            .op = c.issuez_opt_author_policy(c.ISSUEZ_AUTHOR_ENFORCE),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_AUTHOR_POLICY,
            .list = c.ISSUEZ_LIST_PUSH_CHECK,
            .want = .{ .num = c.ISSUEZ_AUTHOR_ENFORCE },
        },
        .{
            .name = "issuez_opt_allow_numbers",
            .op = c.issuez_opt_allow_numbers(true),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_ALLOW_NUMBERS,
            .list = c.ISSUEZ_LIST_PUSH_CHECK,
            .want = .{ .num = 1 },
        },
        .{
            .name = "issuez_opt_allow_purge",
            .op = c.issuez_opt_allow_purge(true),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_ALLOW_PURGE,
            .list = c.ISSUEZ_LIST_PUSH_CHECK,
            .want = .{ .num = 1 },
        },
        .{
            .name = "issuez_opt_pusher_user_id",
            .op = c.issuez_opt_pusher_user_id(fixture.str("0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d")),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_OPT_PUSHER_USER_ID,
            .list = c.ISSUEZ_LIST_PUSH_CHECK,
            .want = .{ .str = "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d" },
        },
        .{
            .name = "issuez_opt_object_dir",
            .op = c.issuez_opt_object_dir(fixture.str("/tmp/objects")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_OBJECT_DIR,
            .list = c.ISSUEZ_LIST_PUSH_CHECK,
            .want = .{ .str = "/tmp/objects" },
        },
        .{
            .name = "issuez_opt_alternate_object_dirs",
            .op = c.issuez_opt_alternate_object_dirs(fixture.str("/tmp/alternates")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_ALTERNATE_OBJECT_DIRS,
            .list = c.ISSUEZ_LIST_PUSH_CHECK,
            .want = .{ .str = "/tmp/alternates" },
        },
        .{
            .name = "issuez_set_ref",
            .op = c.issuez_set_ref(fixture.str("main")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_FIELD_REF,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "main" },
        },
        .{
            .name = "issuez_clear_ref",
            .op = c.issuez_clear_ref(),
            .verb = c.ISSUEZ_OP_CLEAR,
            .target = c.ISSUEZ_FIELD_REF,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{},
        },
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
            .op = c.issuez_add_attachment(
                fixture.str("0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c"),
                fixture.str("a.png"),
                fixture.str("bytes"),
            ),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_FIELD_ATTACHMENTS,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .name = "a.png", .str = "bytes" },
        },
        .{
            .name = "issuez_remove_attachment",
            .op = c.issuez_remove_attachment(fixture.str("0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c")),
            .verb = c.ISSUEZ_OP_REMOVE,
            .target = c.ISSUEZ_FIELD_ATTACHMENTS,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c" },
        },
        .{
            .name = "issuez_set_original_author",
            .op = c.issuez_set_original_author(fixture.str("octo@github")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_ORIGINAL_AUTHOR,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "octo@github" },
        },
        .{
            .name = "issuez_set_original_id",
            .op = c.issuez_set_original_id(fixture.str("gh-1")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_ORIGINAL_ID,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = "gh-1" },
        },
        .{
            .name = "issuez_edit_comment",
            .op = c.issuez_edit_comment(sample_oid),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_EDIT_COMMENT,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .oid = true },
            .with = c.issuez_set_comment(fixture.str("text")),
        },
        .{
            .name = "issuez_expect_edits",
            .op = c.issuez_expect_edits(2),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_EXPECT_EDITS,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .num = 2 },
        },
        .{
            .name = "issuez_delete_comment",
            .op = c.issuez_delete_comment(sample_oid),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_DELETE_COMMENT,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .oid = true },
        },
        .{
            .name = "issuez_restore_comment",
            .op = c.issuez_restore_comment(sample_oid),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_RESTORE_COMMENT,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .oid = true },
        },
        .{
            .name = "issuez_add_reaction",
            .op = c.issuez_add_reaction(fixture.str(":+1:")),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_FIELD_REACTIONS,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = ":+1:" },
        },
        .{
            .name = "issuez_remove_reaction",
            .op = c.issuez_remove_reaction(fixture.str(":+1:")),
            .verb = c.ISSUEZ_OP_REMOVE,
            .target = c.ISSUEZ_FIELD_REACTIONS,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .str = ":+1:" },
        },
        .{
            .name = "issuez_reaction_target",
            .op = c.issuez_reaction_target(sample_oid),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_REACTION_TARGET,
            .list = c.ISSUEZ_LIST_ISSUE_UPDATE,
            .want = .{ .oid = true },
        },
        .{
            .name = "issuez_q_deleted",
            .op = c.issuez_q_deleted(1),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_Q_DELETED,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .num = 1 },
        },
        .{
            .name = "issuez_q_workflow_state",
            .op = c.issuez_q_workflow_state(fixture.str("ready")),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_OPT_Q_WORKFLOW_STATE,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .str = "ready" },
        },
        .{
            .name = "issuez_q_no_labels",
            .op = c.issuez_q_no_labels(),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_Q_NO_LABELS,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{},
        },
        .{
            .name = "issuez_q_author",
            .op = c.issuez_q_author(fixture.str("ada@example.invalid")),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_OPT_Q_AUTHOR,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .str = "ada@example.invalid" },
        },
        .{
            .name = "issuez_q_priority",
            .op = c.issuez_q_priority(c.ISSUEZ_PRIORITY_HIGH),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_OPT_Q_PRIORITY,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .num = c.ISSUEZ_PRIORITY_HIGH },
        },
        .{
            .name = "issuez_q_milestone",
            .op = c.issuez_q_milestone(fixture.str("0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c")),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_OPT_Q_MILESTONE,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .str = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c" },
        },
        .{
            .name = "issuez_q_parent",
            .op = c.issuez_q_parent(fixture.str("0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c")),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_Q_PARENT,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .str = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c" },
        },
        .{
            .name = "issuez_q_blocked",
            .op = c.issuez_q_blocked(true),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_Q_BLOCKED,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .num = 1 },
        },
        .{
            .name = "issuez_q_updated",
            .op = c.issuez_q_updated(100, 200),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_Q_UPDATED,
            .list = c.ISSUEZ_LIST_QUERY,
            .want = .{ .num = 100, .num2 = 200 },
        },
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
        .{
            .name = "issuez_opt_done_state",
            .op = c.issuez_opt_done_state(fixture.str("wontfix")),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_OPT_DONE_STATE,
            .list = c.ISSUEZ_LIST_OPEN,
            .want = .{ .str = "wontfix" },
        },
        .{
            .name = "issuez_opt_workflow_state",
            .op = c.issuez_opt_workflow_state(fixture.str("ready")),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_OPT_WORKFLOW_STATE,
            .list = c.ISSUEZ_LIST_OPEN,
            .want = .{ .str = "ready" },
        },
        .{
            .name = "issuez_opt_exclusive_scope",
            .op = c.issuez_opt_exclusive_scope(fixture.str("kind")),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_OPT_EXCLUSIVE_SCOPE,
            .list = c.ISSUEZ_LIST_OPEN,
            .want = .{ .str = "kind" },
        },
        .{
            .name = "issuez_opt_extra_prefix",
            .op = c.issuez_opt_extra_prefix(fixture.str("X-Acme-")),
            .verb = c.ISSUEZ_OP_ADD,
            .target = c.ISSUEZ_OPT_EXTRA_PREFIX,
            .list = c.ISSUEZ_LIST_OPEN,
            .want = .{ .str = "X-Acme-" },
        },
        .{
            .name = "issuez_opt_timeout_local_ms",
            .op = c.issuez_opt_timeout_local_ms(5000),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_TIMEOUT_LOCAL_MS,
            .list = c.ISSUEZ_LIST_OPEN,
            .want = .{ .num = 5000 },
        },
        .{
            .name = "issuez_opt_timeout_network_ms",
            .op = c.issuez_opt_timeout_network_ms(9000),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_TIMEOUT_NETWORK_MS,
            .list = c.ISSUEZ_LIST_OPEN,
            .want = .{ .num = 9000 },
        },
        .{
            .name = "issuez_opt_limit",
            .op = c.issuez_opt_limit(fixture.str("max_labels"), 9),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_LIMIT,
            .list = c.ISSUEZ_LIST_OPEN,
            .want = .{ .name = "max_labels", .num = 9 },
        },
        .{
            .name = "issuez_opt_cache_issues",
            .op = c.issuez_opt_cache_issues(10),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_CACHE_ISSUES,
            .list = c.ISSUEZ_LIST_OPEN,
            .want = .{ .num = 10 },
        },
        .{
            .name = "issuez_opt_attachment_store",
            .op = c.issuez_opt_attachment_store(false),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_ATTACHMENT_STORE,
            .list = c.ISSUEZ_LIST_OPEN,
            .want = .{ .num = 0 },
        },
        .{
            .name = "issuez_opt_sync_push",
            .op = c.issuez_opt_sync_push(false),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_SYNC_PUSH,
            .list = c.ISSUEZ_LIST_SYNC,
            .want = .{ .num = 0 },
        },
        .{
            .name = "issuez_opt_sync_attachments",
            .op = c.issuez_opt_sync_attachments(false),
            .verb = c.ISSUEZ_OP_SET,
            .target = c.ISSUEZ_OPT_SYNC_ATTACHMENTS,
            .list = c.ISSUEZ_LIST_SYNC,
            .want = .{ .num = 0 },
        },
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
    for (api.helpers, rows) |h, row| try testing.expectEqualStrings(h.name, row.name);

    for (rows) |row| {
        errdefer std.debug.print("helper {s}\n", .{row.name});
        try testing.expectEqual(row.verb, row.op.verb);
        try testing.expectEqual(row.target, row.op.target);
        try testing.expect(std.mem.allEqual(u64, &row.op.reserved, 0));
        if (row.want.str) |s| try testing.expectEqualStrings(s, fixture.slice(row.op.str));
        if (row.want.num) |n| try testing.expectEqual(n, row.op.num);
        if (row.want.num2) |n| try testing.expectEqual(n, row.op.num2);
        if (row.want.name) |s| try testing.expectEqualStrings(s, fixture.slice(row.op.name));
        if (row.want.date) try testing.expectEqual(@as(c_int, 2), @as(c_int, row.op.date.day));
        if (row.want.oid) try testing.expect(c.issuez_oid_eq(&row.op.oid, &sample_oid));
        if (row.want.person) try testing.expect(row.op.person.email.len > 0);
        var ps: ?*c.issuez_problems = null;
        const ops = [_]c.issuez_op{ row.op, row.with orelse row.op };
        const n: usize = if (row.with != null) 2 else 1;
        try expect.code(c.ISSUEZ_OK, c.issuez_ops_validate(row.list, &ops, n, &ps, null), null);
        defer c.issuez_problems_free(ps);
        if (c.issuez_problems_len(ps) > 0) {
            std.debug.print(
                "{s}: {s}\n",
                .{ row.name, fixture.slice(c.issuez_problems_at(ps, 0).*.message) },
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

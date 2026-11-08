//! Writes: op lists checked and turned into one engine write, write
//! receipts, comment events and milestone writes.
//!
//! An op list becomes one commit. The engine writes a comment, a state
//! change, field edits and a delete as separate operations, so for now a
//! list asks for one of them; a list that combines them fails with
//! UNSUPPORTED (problem INCOMPATIBLE) until the engine writes them in one
//! commit. A comment can't ride on a state change either: a commit whose
//! only text is its subject reads as the tool's own ("Close issue").

const std = @import("std");
const api = @import("api.zig");
const rt = @import("rt.zig");
const repo_mod = @import("repo.zig");
const read = @import("read.zig");
const more = @import("more.zig");
const issuez = @import("issuez");
const MilestoneEdit = issuez.engine.MilestoneEdit;

const Allocator = std.mem.Allocator;
const Code = api.Code;
const Str = api.Str;
const Field = api.Field;
const Opt = api.Opt;
const Verb = api.Verb;
const Call = repo_mod.Call;
const RepoObj = repo_mod.RepoObj;
const Issue = issuez.model.issue.Issue;
const Signature = issuez.backend.object.Signature;
const Oid = issuez.backend.object.Oid;
const core_fmt = issuez.format.core;
const fields_fmt = issuez.format.fields;
const uuid_fmt = issuez.format.uuid;
const labels_fmt = issuez.format.labels;
const attachment_fmt = issuez.format.attachment;
const Store = issuez.Attachments(repo_mod.Backend);

// ─── Checking op lists ─────────────────────────────────────────────────

const Problems = std.ArrayList(rt.ProblemSpec);

const Slot = enum { str, num, date, oid, person, none, name_str };

const Rule = struct { verbs: []const Verb, slot: Slot };

fn ruleOf(list: api.OpList, target: u32) ?Rule {
    const issue_list = list == .issue_create or list == .issue_update;
    const milestone_list = list == .milestone_create or list == .milestone_update;
    if (issue_list or milestone_list) {
        if (target >= 0x100) return switch (@as(Opt, @enumFromInt(target))) {
            .expect => .{ .verbs = &.{.set}, .slot = .oid },
            .prepared_attachment => if (issue_list)
                .{ .verbs = &.{.add}, .slot = .str }
            else
                null,
            .subject, .original_author, .original_id => .{ .verbs = &.{.set}, .slot = .str },
            .edit_comment => if (list == .issue_update) .{
                .verbs = &.{.set},
                .slot = .oid,
            } else null,
            .expect_edits => if (list == .issue_update) .{
                .verbs = &.{.set},
                .slot = .num,
            } else null,
            .delete_comment, .restore_comment, .reaction_target => if (list == .issue_update)
                .{ .verbs = &.{.set}, .slot = .oid }
            else
                null,
            else => null,
        };
        const f: Field = @enumFromInt(target);
        if (milestone_list) return switch (f) {
            .name, .description => .{ .verbs = &.{.set}, .slot = .str },
            .due_date => .{ .verbs = &.{ .set, .clear }, .slot = .date },
            .milestone_status => .{ .verbs = &.{.set}, .slot = .num },
            else => null,
        };
        return switch (f) {
            .title, .description, .comment, .state, .fixed_by, .release, .reason => .{
                .verbs = &.{.set},
                .slot = .str,
            },
            .ref => .{ .verbs = &.{ .set, .clear }, .slot = .str },
            .workflow_state => .{ .verbs = &.{ .set, .clear }, .slot = .str },
            .labels, .blocked_by => .{ .verbs = &.{ .add, .remove, .clear }, .slot = .str },
            .assignees => .{ .verbs = &.{ .add, .remove, .clear }, .slot = .person },
            .priority, .estimate => .{ .verbs = &.{ .set, .clear }, .slot = .num },
            .milestone => .{ .verbs = &.{ .set, .clear, .inherit }, .slot = .str },
            .parent => .{ .verbs = &.{ .set, .clear }, .slot = .str },
            .start_date, .due_date => .{ .verbs = &.{ .set, .clear }, .slot = .date },
            .locked, .deleted, .number => .{ .verbs = &.{.set}, .slot = .num },
            .extra => .{ .verbs = &.{.set}, .slot = .name_str },
            .attachments => .{ .verbs = &.{ .add, .remove }, .slot = .name_str },
            .reactions => if (list == .issue_update) .{
                .verbs = &.{ .add, .remove },
                .slot = .str,
            } else null,
            else => null,
        };
    }
    return null;
}

fn targetField(target: u32) Field {
    return if (target < 0x100) @enumFromInt(target) else .unknown;
}

/// Problems with the ops themselves and their values' format: everything
/// that doesn't need the repository.
fn checkOps(a: Allocator, list: api.OpList, ops: []const api.Op, problems: *Problems) !void {
    for (ops, 0..) |op, i| {
        const index: i64 = @intCast(i);
        if (rt.hasReserved(op)) {
            try problems.append(a, rt.reservedProblem(index));
            continue;
        }
        const field = targetField(op.target);
        const rule = ruleOf(list, op.target) orelse {
            try problems.append(a, .{
                .kind = .unknown_target,
                .field = field,
                .message = "not a target of this call",
                .op_index = index,
            });
            continue;
        };
        const verb: Verb = @enumFromInt(op.verb);
        if (std.mem.indexOfScalar(Verb, rule.verbs, verb) == null) {
            try problems.append(a, .{
                .kind = .bad_verb,
                .field = field,
                .message = "this verb doesn't apply to this target",
                .op_index = index,
            });
            continue;
        }
        if (verb == .clear or verb == .inherit) continue;
        const s = op.str.slice();
        // The default limits: a repo opened with others checks again.
        const limits: issuez.engine.Limits = .{};
        const max: ?usize = switch (field) {
            .title, .name => limits.max_title_bytes,
            .description, .comment => limits.max_body_bytes,
            else => null,
        };
        if (max) |m| if (s.len > m) {
            try problems.append(a, .{
                .kind = .too_long,
                .field = field,
                .message = "longer than the limit",
                .op_index = index,
            });
            continue;
        };
        const p = struct {
            fn add(
                pr: *Problems,
                al: Allocator,
                f: Field,
                idx: i64,
                kind: api.ProblemKind,
                v: []const u8,
                msg: []const u8,
            ) !void {
                try pr.append(
                    al,
                    .{ .kind = kind, .field = f, .value = v, .message = msg, .op_index = idx },
                );
            }
        };
        switch (field) {
            .title, .name => if (std.mem.trim(u8, s, " \t\r\n").len == 0) {
                try p.add(problems, a, field, index, .empty, s, "must not be empty");
            } else if (std.mem.findAny(u8, s, "\r\n") != null) {
                try p.add(problems, a, field, index, .newline, s, "must be one line");
            },
            .comment => if (std.mem.trim(u8, s, " \t\r\n").len == 0)
                try p.add(problems, a, field, index, .empty, s, "must not be empty"),
            .state => if (!core_fmt.isState(s))
                try p.add(
                    problems,
                    a,
                    field,
                    index,
                    .bad_format,
                    s,
                    "states are letters, digits, '-' and '_'",
                ),
            .workflow_state => if (!fields_fmt.isSlug(s))
                try p.add(
                    problems,
                    a,
                    field,
                    index,
                    .bad_format,
                    s,
                    "workflow states are lowercase letters, digits and '-'",
                ),
            .ref => if (!fields_fmt.isRefName(s))
                try p.add(problems, a, field, index, .bad_format, s, "not a branch or tag name"),
            .locked => if (std.mem.findAny(u8, s, "\r\n") != null)
                try p.add(problems, a, field, index, .newline, s, "must be one line"),
            .fixed_by, .release, .reason => if (std.mem.findAny(u8, s, "\r\n") != null)
                try p.add(problems, a, field, index, .newline, s, "must be one line"),
            .labels => labels_fmt.validate(s) catch
                try p.add(
                    problems,
                    a,
                    field,
                    index,
                    .bad_format,
                    s,
                    "labels must not contain commas or newlines",
                ),
            .blocked_by, .parent, .milestone => if (!uuid_fmt.isCanonical(s))
                try p.add(problems, a, field, index, .bad_format, s, "references are full UUIDs"),
            .assignees => {
                const email = op.person.email.slice();
                if (core_fmt.checkEmail(email) != null)
                    try p.add(
                        problems,
                        a,
                        field,
                        index,
                        .bad_format,
                        email,
                        "not an email address",
                    );
                const uid = op.person.user_id.slice();
                if (uid.len > 0 and !uuid_fmt.isCanonical(uid))
                    try p.add(problems, a, field, index, .bad_format, uid, "user IDs are UUIDs");
            },
            .priority => if (op.num < 1 or op.num > 4)
                try p.add(problems, a, field, index, .bad_format, "", "not a priority"),
            .estimate => if (op.num < 0 or op.num > 10 * 366 * 24 * 60)
                try p.add(
                    problems,
                    a,
                    field,
                    index,
                    .bad_format,
                    "",
                    "estimates are 0 to 10 years, in minutes",
                ),
            .start_date, .due_date => if (engineDate(op.date) == null)
                try p.add(problems, a, field, index, .bad_format, "", "not a calendar day"),
            .milestone_status => if (op.num < 1 or op.num > 3)
                try p.add(problems, a, field, index, .bad_format, "", "not a milestone status"),
            .extra => {
                const key = op.name.slice();
                const namespaced = key.len > 2 and std.ascii.startsWithIgnoreCase(key, "X-");
                const usable = issuez.format.trailers.isValidKey(key) and
                    !issuez.model.issue.isFormatKey(key);
                if (!namespaced or !usable)
                    try p.add(
                        problems,
                        a,
                        field,
                        index,
                        .bad_format,
                        key,
                        "host fields are X- keys the format doesn't use",
                    );
                if (std.mem.findAny(u8, s, "\r\n") != null)
                    try p.add(problems, a, field, index, .newline, s, "must be one line");
            },
            .number => if (op.num < 1)
                try p.add(problems, a, field, index, .bad_format, "", "numbers start at 1"),
            .attachments => if (verb == .remove) {
                if (!uuid_fmt.isCanonical(s)) try p.add(
                    problems,
                    a,
                    field,
                    index,
                    .bad_format,
                    s,
                    "attachments are removed by their UUID",
                );
            } else {
                if (s.len == 0)
                    try p.add(problems, a, field, index, .empty, "", "an attachment has bytes");
                if (op.name.len == 0)
                    try p.add(problems, a, field, index, .empty, "", "an attachment has a name");
                if (op.id.len > 0 and !uuid_fmt.isCanonical(op.id.slice())) try p.add(
                    problems,
                    a,
                    field,
                    index,
                    .bad_format,
                    op.id.slice(),
                    "an attachment's id is a full UUID",
                );
            },
            else => {},
        }
        const oid_opt = op.target == @intFromEnum(Opt.expect) or
            op.target == @intFromEnum(Opt.edit_comment) or
            op.target == @intFromEnum(Opt.delete_comment) or
            op.target == @intFromEnum(Opt.restore_comment) or
            op.target == @intFromEnum(Opt.reaction_target);
        if (oid_opt and rt.oidFrom(op.oid) == null)
            try p.add(problems, a, .unknown, index, .bad_format, "", "not an object ID");
    }
}

/// "YYYY-MM-DD" for a real calendar day.
fn engineDate(d: api.Date) ?fields_fmt.Date {
    if (d.year < 1 or d.year > 9999) return null;
    const out: fields_fmt.Date = .{ .year = @intCast(d.year), .month = d.month, .day = d.day };
    return if (out.isValid()) out else null;
}

pub fn issuez_ops_validate(
    list: api.OpList,
    ops: ?[*]const api.Op,
    n: usize,
    out: ?*?*api.Problems,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    var scratch: std.heap.ArenaAllocator = .init(rt.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var problems: Problems = .empty;
    const slice = if (ops) |p| p[0..n] else &.{};
    switch (list) {
        .issue_create, .issue_update, .milestone_create, .milestone_update => {
            checkOps(
                a,
                list,
                slice,
                &problems,
            ) catch return rt.fail(err, .e_nomem, "out of memory", .{});
            if (problems.items.len == 0) {
                _ = plan(
                    a,
                    list,
                    slice,
                    &problems,
                ) catch return rt.fail(err, .e_nomem, "out of memory", .{});
            }
        },
        .query => _ = read.parseQuery(a, slice, &problems) catch
            return rt.fail(err, .e_nomem, "out of memory", .{}),
        .open => repo_mod.validateOpen(a, slice, &problems) catch
            return rt.fail(err, .e_nomem, "out of memory", .{}),
        .sync => _ = more.parseSyncOps(a, slice, &problems) catch
            return rt.fail(err, .e_nomem, "out of memory", .{}),
        .push_check => _ = more.parsePushOps(a, slice, &problems) catch
            return rt.fail(err, .e_nomem, "out of memory", .{}),
        .settings => more.validateSettings(a, slice, &problems) catch
            return rt.fail(err, .e_nomem, "out of memory", .{}),
        else => return rt.fail(err, .e_invalid_argument, "not an issuez_op_list", .{}),
    }
    const owned = rt.ownedProblems(problems.items) catch return rt.fail(
        err,
        .e_nomem,
        "out of memory",
        .{},
    );
    o.* = @ptrCast(owned);
    return .ok;
}

// ─── Planning a write ──────────────────────────────────────────────────

/// What an op list asks for, with the op each part came from.
const Plan = struct {
    comment: ?[]const u8 = null,
    state: ?[]const u8 = null,
    fixed_by: ?[]const u8 = null,
    release: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    deleted: ?bool = null,
    expect: ?Oid = null,
    subject: ?[]const u8 = null,
    edit: issuez.engine.EditSpec = .{},
    create: issuez.engine.CreateSpec = .{ .title = "" },
    milestone: struct {
        name: ?[]const u8 = null,
        description: ?[]const u8 = null,
        due: ?fields_fmt.Date = null,
        clear_due: bool = false,
        status: ?fields_fmt.MilestoneStatus = null,
    } = .{},
    /// Labels and blockers, as adds and removes; a CLEAR replaces.
    labels_add: std.ArrayList([]const u8) = .empty,
    labels_remove: std.ArrayList([]const u8) = .empty,
    labels_replace: bool = false,
    blockers_add: std.ArrayList([]const u8) = .empty,
    blockers_remove: std.ArrayList([]const u8) = .empty,
    blockers_replace: bool = false,
    extra: std.ArrayList(issuez.engine.HostField) = .empty,
    assignees_add: std.ArrayList(fields_fmt.Assignee) = .empty,
    assignees_remove: std.ArrayList([]const u8) = .empty,
    assignees_replace: bool = false,
    has_fields: bool = false,
    has_state: bool = false,
    attachments_add: std.ArrayList(Store.Input) = .empty,
    attachments_prepared: std.ArrayList(attachment_fmt.Spec) = .empty,
    attachments_remove: std.ArrayList([]const u8) = .empty,
    /// ISSUEZ_OPT_EDIT_COMMENT: the write edits this comment.
    edit_comment: ?Oid = null,
    /// ISSUEZ_OPT_EXPECT_EDITS: the edits the text it edits has had.
    expect_edits: ?i64 = null,
    /// ISSUEZ_OPT_DELETE_COMMENT / RESTORE_COMMENT.
    comment_event: ?struct { target: Oid, delete: bool } = null,
    /// REACTIONS ADD or REMOVE, on REACTION_TARGET or the issue.
    reaction: ?struct { emoji: []const u8, present: bool } = null,
    reaction_target: ?Oid = null,
    /// The op each field came from, -1 for none.
    op_of: [32]i64 = @splat(-1),

    fn opOf(p: *const Plan, f: Field) i64 {
        const i = @intFromEnum(f);
        return if (i < 32) p.op_of[i] else -1;
    }
};

fn unsupportedField(
    a: Allocator,
    problems: *Problems,
    field: Field,
    index: i64,
    what: []const u8,
) !void {
    try problems.append(a, .{
        .kind = .incompatible,
        .field = field,
        .message = what,
        .op_index = index,
    });
}

fn plan(a: Allocator, list: api.OpList, ops: []const api.Op, problems: *Problems) !Plan {
    var p: Plan = .{};
    const creating = list == .issue_create or list == .milestone_create;
    for (ops, 0..) |op, i| {
        const index: i64 = @intCast(i);
        const verb: Verb = @enumFromInt(op.verb);
        const s = op.str.slice();
        if (op.target >= 0x100) {
            switch (@as(Opt, @enumFromInt(op.target))) {
                .expect => p.expect = rt.oidFrom(op.oid),
                .subject => p.subject = s,
                .original_author => {
                    p.edit.original.author = s;
                    p.create.original.author = s;
                },
                .original_id => {
                    p.edit.original.id = s;
                    p.create.original.id = s;
                },
                .edit_comment => p.edit_comment = rt.oidFrom(op.oid),
                .expect_edits => p.expect_edits = op.num,
                .prepared_attachment => {
                    if (attachment_fmt.parseSpec(s)) |spec| {
                        try p.attachments_prepared.append(a, spec);
                        p.has_fields = true;
                    } else try problems.append(a, .{
                        .kind = .bad_format,
                        .field = .attachments,
                        .message = "invalid prepared attachment metadata",
                        .op_index = index,
                    });
                },
                .delete_comment, .restore_comment => if (rt.oidFrom(op.oid)) |t| {
                    p.comment_event = .{
                        .target = t,
                        .delete = op.target == @intFromEnum(Opt.delete_comment),
                    };
                },
                .reaction_target => p.reaction_target = rt.oidFrom(op.oid),
                else => unreachable,
            }
            continue;
        }
        const field: Field = @enumFromInt(op.target);
        if (@intFromEnum(field) < 32) p.op_of[@intFromEnum(field)] = index;
        if (list == .milestone_create or list == .milestone_update) {
            switch (field) {
                .name => p.milestone.name = s,
                .description => p.milestone.description = s,
                .due_date => if (verb == .clear) {
                    p.milestone.clear_due = true;
                    p.milestone.due = null;
                } else {
                    p.milestone.due = engineDate(op.date).?;
                    p.milestone.clear_due = false;
                },
                .milestone_status => p.milestone.status = switch (op.num) {
                    1 => .open,
                    2 => .completed,
                    else => .retired,
                },
                else => unreachable,
            }
            continue;
        }
        switch (field) {
            .comment => {
                if (creating) try unsupportedField(
                    a,
                    problems,
                    field,
                    index,
                    "a new issue has no comment; use DESCRIPTION",
                );
                p.comment = s;
            },
            .state => {
                p.state = s;
                p.has_state = true;
            },
            .fixed_by => {
                p.fixed_by = s;
                p.has_state = true;
            },
            .release => {
                p.release = s;
                p.has_state = true;
            },
            .reason => {
                p.reason = s;
                p.has_state = true;
            },
            .deleted => p.deleted = op.num != 0,
            .title => {
                p.edit.title = s;
                p.create.title = s;
                p.has_fields = true;
            },
            .description => {
                p.edit.description = s;
                p.create.body = s;
                p.has_fields = true;
            },
            .workflow_state => {
                p.edit.workflow = if (verb == .clear) .clear else .{ .set = s };
                if (verb != .clear) p.create.workflow = s;
                p.has_fields = true;
            },
            .labels => {
                switch (verb) {
                    .clear => {
                        p.labels_replace = true;
                        p.labels_add.clearRetainingCapacity();
                        p.labels_remove.clearRetainingCapacity();
                    },
                    .add => try p.labels_add.append(a, s),
                    else => try p.labels_remove.append(a, s),
                }
                p.has_fields = true;
            },
            .blocked_by => {
                switch (verb) {
                    .clear => {
                        p.blockers_replace = true;
                        p.blockers_add.clearRetainingCapacity();
                        p.blockers_remove.clearRetainingCapacity();
                    },
                    .add => try p.blockers_add.append(a, s),
                    else => try p.blockers_remove.append(a, s),
                }
                p.has_fields = true;
            },
            .assignees => {
                const email = op.person.email.slice();
                const uid = op.person.user_id.slice();
                const who: fields_fmt.Assignee = .{
                    .uuid = if (uid.len > 0) uid else null,
                    .email = email,
                };
                switch (verb) {
                    .clear => {
                        p.assignees_replace = true;
                        p.assignees_add.clearRetainingCapacity();
                        p.assignees_remove.clearRetainingCapacity();
                    },
                    .add => try p.assignees_add.append(a, who),
                    else => try p.assignees_remove.append(a, if (uid.len > 0)
                        try who.text(a)
                    else
                        email),
                }
                p.has_fields = true;
            },
            .priority => {
                const pr: ?core_fmt.Priority = if (verb == .clear) null else switch (op.num) {
                    1 => .low,
                    2 => .medium,
                    3 => .high,
                    else => .critical,
                };
                p.edit.priority = if (pr) |v| .{ .set = v } else .clear;
                p.create.priority = pr;
                p.has_fields = true;
            },
            .milestone => {
                const m: issuez.engine.MilestoneEdit = switch (verb) {
                    .set => .linked(s),
                    .inherit => .{ .link = .inherit },
                    else => .{ .link = .none },
                };
                p.edit.milestone = m;
                p.create.milestone = m;
                p.has_fields = true;
            },
            .parent => {
                p.edit.parent = if (verb == .clear) .clear else .{ .set = s };
                if (verb != .clear) p.create.parent = s;
                p.has_fields = true;
            },
            .start_date, .due_date => {
                const date = if (verb == .clear) null else engineDate(op.date).?;
                const change: issuez.engine.EditSpec.DateEdit =
                    if (date) |d| .{ .set = d } else .clear;
                if (field == .start_date) {
                    p.edit.start_date = change;
                    p.create.start_date = date;
                } else {
                    p.edit.due_date = change;
                    p.create.due_date = date;
                }
                p.has_fields = true;
            },
            .estimate => {
                p.edit.estimate_minutes = if (verb == .clear)
                    .clear
                else
                    .{ .set = @intCast(op.num) };
                if (verb != .clear) p.create.estimate_minutes = @intCast(op.num);
                p.has_fields = true;
            },
            .number => {
                p.edit.number = @intCast(op.num);
                p.create.number = @intCast(op.num);
                p.has_fields = true;
            },
            .locked => {
                p.edit.locked = op.num != 0;
                if (op.num != 0 and s.len > 0) p.edit.lock_reason = s;
                p.has_fields = true;
            },
            .ref => {
                p.edit.ref = if (verb == .clear) .clear else .{ .set = s };
                p.has_fields = true;
            },
            .extra => {
                try p.extra.append(a, .{ .key = op.name.slice(), .value = s });
                p.has_fields = true;
            },
            .reactions => {
                if (!fields_fmt.isEmoji(s)) try problems.append(a, .{
                    .kind = .bad_format,
                    .field = field,
                    .value = s,
                    .message = "an emoji is 1 to 64 bytes without whitespace or commas",
                    .op_index = index,
                });
                p.reaction = .{ .emoji = s, .present = verb == .add };
            },
            .attachments => {
                if (verb == .remove) {
                    if (creating) try unsupportedField(
                        a,
                        problems,
                        field,
                        index,
                        "a new issue has no attachments to remove",
                    );
                    try p.attachments_remove.append(a, s);
                } else {
                    const id: ?[]const u8 = if (op.id.len > 0) op.id.slice() else null;
                    try p.attachments_add.append(
                        a,
                        .{ .name = op.name.slice(), .data = s, .id = id },
                    );
                }
                p.has_fields = true;
            },
            else => unreachable,
        }
    }
    if (list == .milestone_create and p.milestone.name == null) try problems.append(a, .{
        .kind = .missing_value,
        .field = .name,
        .message = "a new milestone needs a name",
    });
    if (list == .issue_create) {
        if (p.create.title.len == 0) try problems.append(a, .{
            .kind = .missing_value,
            .field = .title,
            .message = "a new issue needs a title",
        });
        if (p.deleted != null) try unsupportedField(
            a,
            problems,
            .deleted,
            p.opOf(.deleted),
            "a new issue isn't deleted",
        );
    }
    if (list == .issue_update) {
        if (p.deleted != null and (p.has_state or p.has_fields or p.comment != null))
            try unsupportedField(a, problems, .deleted, p.opOf(.deleted), "a delete or restore " ++
                "can't share a commit with other changes");
        if (p.comment != null and p.edit.description != null)
            try unsupportedField(a, problems, .comment, p.opOf(.comment), "a description edit " ++
                "can't carry a comment: its text is the description");
        if (p.comment_event != null or p.reaction != null) {
            // A commit of its own: only EXPECT and SUBJECT (and the
            // reaction's target) go with it.
            for (ops, 0..) |op, i| {
                const own = (op.target >= 0x100 and
                    op.target != @intFromEnum(Opt.prepared_attachment) and
                    op.target != @intFromEnum(Opt.expect_edits)) or
                    op.target == @intFromEnum(Field.reactions);
                if (!own or (p.comment_event != null and p.reaction != null) or
                    (p.edit_comment != null)) try unsupportedField(
                    a,
                    problems,
                    targetField(op.target),
                    @intCast(i),
                    "a comment delete, restore or reaction is a commit of its own",
                );
            }
        }
        if (p.edit_comment != null) {
            if (p.comment == null) try problems.append(a, .{
                .kind = .missing_value,
                .field = .comment,
                .message = "a comment edit needs the comment's new text",
            });
            // Only the comment's text and images, as its edit event takes.
            for (ops, 0..) |op, i| {
                const alone = op.target == @intFromEnum(Field.comment) or
                    op.target == @intFromEnum(Field.attachments) or op.target >= 0x100;
                if (!alone) try unsupportedField(
                    a,
                    problems,
                    targetField(op.target),
                    @intCast(i),
                    "a comment edit carries only COMMENT and ATTACHMENTS",
                );
            }
        }
    }
    return p;
}

/// The attachments to add, validated and hashed; their bytes stored
/// unless the caller keeps them (ISSUEZ_OPT_ATTACHMENT_STORE 0).
fn prepareAttachments(c: *Call, p: *const Plan) ![]const attachment_fmt.Spec {
    const inputs = p.attachments_add.items;
    if (p.attachments_prepared.items.len > 0 and c.repo.store_attachments)
        return error.InvalidValue;
    for (p.attachments_prepared.items) |spec| {
        if (spec.size > c.repo.limits.max_attachment_bytes) return error.AttachmentTooLarge;
    }
    if (inputs.len == 0) return p.attachments_prepared.items;
    const a = c.arena();
    const store = Store.fromRepo(c.engine());
    const specs = try a.alloc(attachment_fmt.Spec, inputs.len);
    for (inputs, specs) |in, *spec| spec.* = try store.prepare(a, in);
    if (c.repo.store_attachments and !c.dry_run) {
        for (inputs, specs) |in, spec| try store.storeBytes(a, spec, in.data);
    }
    return try std.mem.concat(a, attachment_fmt.Spec, &.{ specs, p.attachments_prepared.items });
}

fn attachmentChanges(c: *Call, p: *const Plan) !issuez.engine.AttachmentChanges {
    return .{ .add = try prepareAttachments(c, p), .remove = p.attachments_remove.items };
}

// ─── Typed changes ─────────────────────────────────────────────────────

/// The changes of the timeline entry for `commit`, as the model reads them.
fn entryChanges(after: *const read.IssueObj, commit: Oid) []const api.Change {
    const want = rt.oidOf(commit);
    for (after.timeline) |e| {
        if (!rt.issuez_oid_eq(&e.public.commit, &want)) continue;
        const ptr = e.changes orelse return &.{};
        return ptr[0..e.public.change_count];
    }
    return &.{};
}

// ─── The receipt ───────────────────────────────────────────────────────

pub const WriteObj = struct {
    arena: *std.heap.ArenaAllocator,
    repo: *RepoObj,
    kind: api.Kind,
    id: Str,
    wrote: bool,
    commit: api.Oid = .{},
    old_tip: api.Oid = .{},
    new_tip: api.Oid = .{},
    retries: u32 = 0,
    entry: read.EntryObj,

    fn free(w: *WriteObj) void {
        const r = w.repo;
        rt.freeArena(w.arena);
        r.release();
    }

    fn freeOpaque(p: *anyopaque) void {
        free(@ptrCast(@alignCast(p)));
    }
};

fn copyPerson(a: Allocator, p: ?*const api.Person) Allocator.Error!?*const api.Person {
    const from = p orelse return null;
    const out = try a.create(api.Person);
    out.* = .{
        .name = try rt.dupeZ(a, from.name.slice()),
        .email = try rt.dupeZ(a, from.email.slice()),
        .user_id = try rt.dupeZ(a, from.user_id.slice()),
    };
    return out;
}

fn apiDate(d: fields_fmt.Date) api.Date {
    return .{ .year = @intCast(d.year), .month = d.month, .day = d.day };
}

fn makeWrite(
    c: *Call,
    kind: api.Kind,
    id: []const u8,
    given_old_tip: ?Oid,
    given_new_tip: ?Oid,
    entry_kind: api.EntryKind,
    given_changes: []const api.Change,
    author: Signature,
) !*WriteObj {
    // The engine skipped a commit that changed nothing: the tip it returned
    // is the one there was.
    const old_tip = if (c.skipped) given_new_tip orelse given_old_tip else given_old_tip;
    const new_tip = if (c.skipped) null else given_new_tip;
    const changes = if (c.skipped) &.{} else given_changes;
    const arena = try rt.newArena();
    errdefer rt.freeArena(arena);
    const a = arena.allocator();
    const w = try a.create(WriteObj);
    const copied = try a.alloc(api.Change, changes.len);
    for (changes, copied) |ch, *o| {
        o.* = .{
            .field = ch.field,
            .key = try rt.dupeZ(a, ch.key.slice()),
            .op = ch.op,
            .old_value = try rt.dupeZ(a, ch.old_value.slice()),
            .new_value = try rt.dupeZ(a, ch.new_value.slice()),
            .old_person = try copyPerson(a, ch.old_person),
            .new_person = try copyPerson(a, ch.new_person),
            .old_date = ch.old_date,
            .new_date = ch.new_date,
            .old_done = ch.old_done,
            .new_done = ch.new_done,
            .reason = try rt.dupeZ(a, ch.reason.slice()),
        };
        // Milestone writes spell their dates out only.
        const field: Field = @enumFromInt(ch.field);
        if (field == .due_date or field == .start_date) {
            if (fields_fmt.Date.parse(ch.old_value.slice())) |d| o.old_date = apiDate(d);
            if (fields_fmt.Date.parse(ch.new_value.slice())) |d| o.new_date = apiDate(d);
        }
    }
    const person = try a.create(api.Person);
    person.* = try rt.personOf(a, author, c.author_id);
    const wrote = new_tip != null and (old_tip == null or !old_tip.?.eql(new_tip.?));
    w.* = .{
        .arena = arena,
        .repo = c.repo,
        .kind = kind,
        .id = try rt.dupeZ(a, id),
        .wrote = wrote,
        .retries = c.retries,
        .commit = if (wrote) rt.oidOf(new_tip.?) else .{},
        .old_tip = if (old_tip) |t| rt.oidOf(t) else .{},
        .new_tip = if (new_tip) |t| rt.oidOf(t) else if (old_tip) |t| rt.oidOf(t) else .{},
        .entry = .{
            .public = .{
                .kind = @intFromEnum(entry_kind),
                .commit = if (wrote) rt.oidOf(new_tip.?) else .{},
                .author = person,
                .at = rt.timeOf(author),
                .comment = null,
                .change_count = copied.len,
                .is_new = true,
            },
            .changes = copied.ptr,
        },
    };
    c.repo.retain();
    return w;
}

fn getWrite(w: ?*const api.Write) ?*WriteObj {
    return rt.obj(WriteObj, w);
}

pub fn issuez_write_free(w: ?*api.Write) callconv(.c) void {
    const o = getWrite(w) orelse return;
    o.free();
}
pub fn issuez_write_kind(w: ?*const api.Write) callconv(.c) api.Kind {
    return if (getWrite(w)) |o| o.kind else .unknown;
}
pub fn issuez_write_id(w: ?*const api.Write) callconv(.c) Str {
    return if (getWrite(w)) |o| o.id else .{};
}
pub fn issuez_write_wrote(w: ?*const api.Write) callconv(.c) bool {
    return if (getWrite(w)) |o| o.wrote else false;
}
pub fn issuez_write_commit(w: ?*const api.Write) callconv(.c) api.Oid {
    return if (getWrite(w)) |o| o.commit else .{};
}
pub fn issuez_write_old_tip(w: ?*const api.Write) callconv(.c) api.Oid {
    return if (getWrite(w)) |o| o.old_tip else .{};
}
pub fn issuez_write_new_tip(w: ?*const api.Write) callconv(.c) api.Oid {
    return if (getWrite(w)) |o| o.new_tip else .{};
}
pub fn issuez_write_retries(w: ?*const api.Write) callconv(.c) u32 {
    return if (getWrite(w)) |o| o.retries else 0;
}
pub fn issuez_write_entry(w: ?*const api.Write) callconv(.c) ?*const api.Entry {
    const o = getWrite(w) orelse return null;
    return &o.entry.public;
}

pub fn issuez_write_load_issue(
    w: ?*const api.Write,
    cancel: ?*api.Cancel,
    out: ?*?*api.Issue,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = getWrite(w) orelse return rt.fail(err, .e_invalid_argument, "w is NULL", .{});
    if (o.kind != .issue) return rt.fail(err, .e_invalid_argument, "not an issue write", .{});
    return read.issuez_issue_load_at(@ptrCast(o.repo), o.id, &o.new_tip, null, cancel, out, err);
}

pub fn issuez_write_load_milestone(
    w: ?*const api.Write,
    cancel: ?*api.Cancel,
    out: ?*?*api.Milestone,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = getWrite(w) orelse return rt.fail(err, .e_invalid_argument, "w is NULL", .{});
    if (o.kind != .milestone)
        return rt.fail(err, .e_invalid_argument, "not a milestone write", .{});
    return more.issuez_milestone_load_at(@ptrCast(o.repo), o.id, &o.new_tip, cancel, out, err);
}

// ─── Issue writes ──────────────────────────────────────────────────────

/// The actor's signature; its `user_id`, a UUID, goes on the call's
/// commits as `X-Author-Id`.
fn signatureOf(c: *Call, actor: ?*const api.Actor) !?Signature {
    const act = actor orelse return null;
    if (act.email.len == 0 or rt.hasReserved(act.*)) return error.InvalidValue;
    if (act.user_id.len > 0) {
        if (!uuid_fmt.isCanonical(act.user_id.slice())) return error.InvalidValue;
        c.author_id = act.user_id.slice();
    }
    const time = if (act.at) |t| t.* else api.Time{
        .unix_seconds = std.Io.Timestamp.now(rt.io(), .real).toSeconds(),
    };
    return .{
        .name = if (act.name.len > 0) act.name.slice() else act.email.slice(),
        .email = act.email.slice(),
        .time = time.unix_seconds,
        .tz_offset_minutes = time.tz_offset_minutes,
    };
}

fn opSlice(p: ?[*]const api.Op, n: usize) []const api.Op {
    return if (p) |x| x[0..n] else &.{};
}

/// Format problems first, then the plan's; INVALID_VALUE with all of them.
fn checked(
    a: Allocator,
    list: api.OpList,
    slice: []const api.Op,
    prefixes: []const []const u8,
    err: ?*?*api.Error,
) !union(enum) { ok: Plan, failed: Code } {
    var problems: Problems = .empty;
    try checkOps(a, list, slice, &problems);
    if (problems.items.len > 0) return .{ .failed = invalid(err, problems.items) };
    const p = try plan(a, list, slice, &problems);
    // Host fields only under the prefixes the repo was opened with.
    for (slice, 0..) |op, i| {
        if (op.target != @intFromEnum(Field.extra)) continue;
        const key = op.name.slice();
        const allowed = for (prefixes) |pre| {
            if (std.ascii.startsWithIgnoreCase(key, pre)) break true;
        } else false;
        if (!allowed) try problems.append(a, .{
            .kind = .bad_format,
            .field = .extra,
            .key = key,
            .message = "not under an allowed host prefix (ISSUEZ_OPT_EXTRA_PREFIX)",
            .op_index = @intCast(i),
        });
    }
    if (problems.items.len > 0) {
        return .{ .failed = invalid(err, problems.items) };
    }
    return .{ .ok = p };
}

fn invalid(err: ?*?*api.Error, problems: []const rt.ProblemSpec) Code {
    if (problems.len == 1) return rt.failWith(
        err,
        .e_invalid_value,
        .{ .problems = problems },
        "{s}",
        .{problems[0].message},
    );
    return rt.failWith(err, .e_invalid_value, .{
        .problems = problems,
    }, "{d} problems, first: {s}", .{
        problems.len,
        problems[0].message,
    });
}

/// The field an engine error is about, for its problem.
fn fieldOf(e: anyerror, p: *const Plan) Field {
    return switch (e) {
        error.InvalidLabel, error.TooManyLabels => .labels,
        error.TooManyBlockers, error.BlocksItself, error.BlockerCycle => .blocked_by,
        error.ParentIsSelf, error.ParentCycle, error.TooDeep, error.ParentDeleted => .parent,
        error.UnknownWorkflowState, error.InvalidWorkflowStates => .workflow_state,
        error.MilestoneCompleted, error.MilestoneRetired, error.OpenWorkInMilestone => .milestone,
        error.OpenDescendants, error.ClosedAncestor => if (p.has_state) .state else .parent,
        error.ActiveChildren => .deleted,
        error.NumberAlreadySet, error.NumberTaken => .number,
        error.UnsupportedType,
        error.AnimatedImage,
        error.MediaMismatch,
        error.EmptyAttachment,
        error.AttachmentTooLarge,
        error.TooManyAttachments,
        error.AttachmentExists,
        => .attachments,
        error.ReferenceNotFound => if (p.edit.parent != null or p.create.parent != null)
            .parent
        else if (MilestoneEdit.toParts(p.edit.milestone).id != null or
            MilestoneEdit.toParts(p.create.milestone).id != null)
            .milestone
        else
            .blocked_by,
        error.BodyLooksLikeTrailers => if (p.comment != null) .comment else .description,
        error.EmptyText, error.InvalidText, error.TooLong => if (p.comment != null)
            .comment
        else
            .title,
        else => .unknown,
    };
}

fn writeFailed(c: *Call, err: ?*?*api.Error, e: anyerror, p: *const Plan, id: []const u8) Code {
    const code = rt.codeOf(e);
    switch (code) {
        .e_invalid_value, .e_guard, .e_limit => {
            // The engine says which field and value; else a guess.
            const said: ?issuez.errors.Diagnostic = if (c.diagnostics) |d| d.last() else null;
            const known = said != null and said.?.err == e and said.?.key.len > 0;
            const field = if (known) read.fieldOfKey(said.?.key) else fieldOf(e, p);
            var problem = rt.problemOf(e, field, p.opOf(field));
            if (known) {
                problem.key = said.?.key;
                problem.value = said.?.value;
            }
            return rt.failWith(
                err,
                code,
                .{ .subject = id, .problems = &.{problem} },
                "{s}",
                .{problem.message},
            );
        },
        .e_version_mismatch => {
            const tip = currentTip(c, id);
            return rt.failWith(
                err,
                code,
                .{ .subject = id, .current_tip = tip },
                "the issue changed since it was read",
                .{},
            );
        },
        else => return rt.failError(
            err,
            e,
            .{ .subject = id, .git_stderr = c.session.git.lastStderr() },
        ),
    }
}

fn currentTip(c: *Call, id: []const u8) ?api.Oid {
    const name = std.fmt.allocPrint(
        c.arena(),
        "{s}{s}",
        .{ issuez.engine.issue_ref_prefix, id },
    ) catch return null;
    const tip = (c.session.backend.resolveRef(name) catch return null) orelse return null;
    return rt.oidOf(tip);
}

/// The exclusive scope a label is in, if any: `kind` for `kind/bug`.
fn exclusiveScopeOf(scopes: []const []const u8, label: []const u8) ?[]const u8 {
    const slash = std.mem.findScalarLast(u8, label, '/') orelse return null;
    for (scopes) |s| if (std.mem.eql(u8, s, label[0..slash])) return s;
    return null;
}

/// Two labels of one exclusive scope added in one op list.
fn scopeConflicts(
    a: Allocator,
    scopes: []const []const u8,
    slice: []const api.Op,
    problems: *Problems,
) !void {
    if (scopes.len == 0) return;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (slice, 0..) |op, i| {
        if (op.target != @intFromEnum(Field.labels) or op.verb != @intFromEnum(Verb.add)) continue;
        const scope = exclusiveScopeOf(scopes, op.str.slice()) orelse continue;
        if (!(try seen.getOrPut(a, scope)).found_existing) continue;
        try problems.append(a, .{
            .kind = .incompatible,
            .field = .labels,
            .value = op.str.slice(),
            .message = "another label of this exclusive scope is in the same write",
            .op_index = @intCast(i),
        });
    }
}

/// Adding `scope/x` takes the issue's other `scope/` labels off.
fn replaceScoped(a: Allocator, scopes: []const []const u8, p: *Plan, current: []const Str) !void {
    if (p.labels_replace) return;
    for (p.labels_add.items) |added| {
        const scope = exclusiveScopeOf(scopes, added) orelse continue;
        for (current) |l| {
            const label = l.slice();
            if (std.mem.eql(u8, label, added)) continue;
            const other = exclusiveScopeOf(scopes, label) orelse continue;
            if (std.mem.eql(u8, other, scope)) try p.labels_remove.append(a, label);
        }
    }
}

fn applySets(a: Allocator, p: *Plan, current: ?Issue) !void {
    if (p.labels_replace) {
        p.edit.set_labels = p.labels_add.items;
    } else {
        p.edit.add_labels = p.labels_add.items;
        p.edit.remove_labels = p.labels_remove.items;
    }
    p.create.labels = p.labels_add.items;
    if (p.blockers_replace) {
        p.edit.set_blocked_by = p.blockers_add.items;
    } else {
        p.edit.add_blocked_by = p.blockers_add.items;
        p.edit.remove_blocked_by = p.blockers_remove.items;
    }
    p.create.blocked_by = p.blockers_add.items;
    const touched = p.assignees_replace or p.assignees_add.items.len > 0 or
        p.assignees_remove.items.len > 0;
    if (p.assignees_replace) {
        p.edit.set_assignees = p.assignees_add.items;
    } else if (touched) {
        p.edit.add_assignees = p.assignees_add.items;
        p.edit.remove_assignees = p.assignees_remove.items;
    }
    p.create.assignees = p.assignees_add.items;
    p.edit.extra = p.extra.items;
    p.create.extra = p.extra.items;
    _ = a;
    _ = current;
}

pub fn issuez_issue_create(
    repo: ?*api.Repo,
    op_ptr: ?[*]const api.Op,
    n: usize,
    actor: ?*const api.Actor,
    cancel: ?*api.Cancel,
    out: ?*?*api.Write,
    err: ?*?*api.Error,
) callconv(.c) Code {
    return issueCreateIn(repo, op_ptr, n, actor, cancel, out, err, false);
}

fn issueCreateIn(
    repo: ?*api.Repo,
    op_ptr: ?[*]const api.Op,
    n: usize,
    actor: ?*const api.Actor,
    cancel: ?*api.Cancel,
    out: ?*?*api.Write,
    err: ?*?*api.Error,
    dry: bool,
) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    c.dry_run = dry;
    const a = c.arena();
    var p = switch (checked(
        a,
        .issue_create,
        opSlice(op_ptr, n),
        c.repo.extra_prefixes,
        err,
    ) catch |e| return rt.failError(err, e, .{})) {
        .ok => |v| v,
        .failed => |code| return code,
    };
    if (scopedFailed(&c, opSlice(op_ptr, n), err)) |code| return code;
    applySets(a, &p, null) catch |e| return rt.failError(err, e, .{});
    const author = signatureOf(
        &c,
        actor,
    ) catch return rt.fail(
        err,
        .e_invalid_argument,
        "the actor needs an email, and its user_id must be a UUID",
        .{},
    );
    const who = author orelse (c.engine().identity(
        a,
        null,
    ) catch |e| return c.fail(err, e)).author;
    p.create.author = author;
    if (p.state) |st| p.create.state = core_fmt.State.parse(st);
    p.create.fixed_by = p.fixed_by;
    p.create.release = p.release;
    p.create.reason = p.reason;
    p.create.attachments = prepareAttachments(
        &c,
        &p,
    ) catch |e| return writeFailed(&c, err, e, &p, "");
    const engine = c.engine();
    const created = engine.create(
        a,
        p.create,
        .{},
    ) catch |e| return writeFailed(&c, err, e, &p, "");
    const id = created.id;
    const after = loadObjAt(&c, id, created.tip) catch null;
    const changes = if (after) |x| entryChanges(x, created.tip) else &.{};

    const w = makeWrite(
        &c,
        .issue,
        id,
        null,
        created.tip,
        .created,
        changes,
        who,
    ) catch |e| return rt.failError(err, e, .{});
    o.* = @ptrCast(w);
    return .ok;
}

fn loadObj(c: *Call, id: []const u8) !?*read.IssueObj {
    const a = c.arena();
    const name = try std.fmt.allocPrint(a, "{s}{s}", .{ issuez.engine.issue_ref_prefix, id });
    const tip = (try c.session.backend.resolveRef(name)) orelse return null;
    return try loadObjAt(c, id, tip);
}

fn loadObjAt(c: *Call, id: []const u8, tip: Oid) !*read.IssueObj {
    const a = c.arena();
    const name = try issuez.engine.refFor(a, issuez.engine.issue_ref_prefix, id);
    const issue = try c.engine().load(a, .{ .name = name, .tip = tip });
    const obj = try a.create(read.IssueObj);
    obj.* = try read.build(a, issue, .of(c.repo));
    return obj;
}

pub fn issuez_issue_update(
    repo: ?*api.Repo,
    id: Str,
    op_ptr: ?[*]const api.Op,
    n: usize,
    actor: ?*const api.Actor,
    cancel: ?*api.Cancel,
    out: ?*?*api.Write,
    err: ?*?*api.Error,
) callconv(.c) Code {
    return issueUpdateIn(repo, id, op_ptr, n, actor, cancel, out, err, false);
}

fn issueUpdateIn(
    repo: ?*api.Repo,
    id: Str,
    op_ptr: ?[*]const api.Op,
    n: usize,
    actor: ?*const api.Actor,
    cancel: ?*api.Cancel,
    out: ?*?*api.Write,
    err: ?*?*api.Error,
    dry: bool,
) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    const ident = id.slice();
    if (!uuid_fmt.isCanonical(ident)) return rt.fail(
        err,
        .e_invalid_argument,
        "not a full issue UUID",
        .{},
    );
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    c.dry_run = dry;
    const a = c.arena();
    var p = switch (checked(
        a,
        .issue_update,
        opSlice(op_ptr, n),
        c.repo.extra_prefixes,
        err,
    ) catch |e| return rt.failError(err, e, .{})) {
        .ok => |v| v,
        .failed => |code| return code,
    };
    if (scopedFailed(&c, opSlice(op_ptr, n), err)) |code| return code;
    const author = signatureOf(
        &c,
        actor,
    ) catch return rt.fail(
        err,
        .e_invalid_argument,
        "the actor needs an email, and its user_id must be a UUID",
        .{},
    );
    const who = author orelse (c.engine().identity(
        a,
        null,
    ) catch |e| return c.fail(err, e)).author;
    const engine = c.engine();
    const before = (loadObj(&c, ident) catch |e| return c.fail(err, e)) orelse
        return rt.failWith(err, .e_not_found, .{ .subject = ident }, "no such issue", .{});
    const removals = p.labels_remove.items.len;
    replaceScoped(a, c.repo.exclusive_scopes, &p, before.labels) catch
        return rt.fail(err, .e_nomem, "out of memory", .{});
    // Pinned to the tip read only where the write depends on it: a state
    // kept from it, labels its scope takes off. Otherwise a concurrent
    // write is retried over, as in the engine.
    const depends = (p.has_state and p.state == null) or p.labels_remove.items.len > removals;
    applySets(a, &p, null) catch |e| return rt.failError(err, e, .{});
    const old_tip = rt.oidFrom(before.tip).?;
    if (p.expect) |want| if (!want.eql(old_tip)) return rt.failWith(err, .e_version_mismatch, .{
        .subject = ident,
        .current_tip = before.tip,
    }, "the issue changed since it was read", .{});
    if (p.expect_edits) |want| {
        if (want < 0 or want > std.math.maxInt(u32) or
            (p.edit.description == null and p.edit_comment == null))
            return rt.fail(err, .e_invalid_value, "EXPECT_EDITS needs a text and a u32 count", .{});
        p.edit.expect_edits = @intCast(want);
    }
    const ref_name = std.fmt.allocPrint(
        a,
        "{s}{s}",
        .{ issuez.engine.issue_ref_prefix, ident },
    ) catch
        return rt.fail(err, .e_nomem, "out of memory", .{});
    const expect: ?Oid = p.expect orelse if (depends) old_tip else null;

    p.edit.attachments = attachmentChanges(
        &c,
        &p,
    ) catch |e| return writeFailed(&c, err, e, &p, ident);
    if (p.has_state) {
        p.edit.state = core_fmt.State.parse(p.state orelse before.state_name.slice());
        p.edit.fixed_by = p.fixed_by;
        p.edit.release = p.release;
        p.edit.reason = p.reason;
    }
    p.edit.comment = p.comment;
    p.edit.message = p.subject;
    p.edit.author = author;
    p.edit.expect = expect;
    const comment_event: @FieldType(
        issuez.Update,
        "comment_event",
    ) = if (p.edit_comment) |t|
        .{ .target = t, .event = .edit }
    else if (p.comment_event) |ce|
        .{ .target = ce.target, .event = if (ce.delete) .delete else .restore }
    else
        null;
    const receipt = engine.update(a, ref_name, .{
        .edit = p.edit,
        .comment_event = comment_event,
        .deleted = p.deleted,
        .reaction = if (p.reaction) |rx|
            .{ .target = p.reaction_target, .emoji = rx.emoji, .present = rx.present }
        else
            null,
    }, .{}) catch |e| return writeFailed(&c, err, e, &p, ident);
    c.retries = receipt.retries;
    c.skipped = !receipt.wrote;
    const entry_kind: api.EntryKind = switch (receipt.kind) {
        .comment => .comment,
        .description_edit => .description_edit,
        .comment_edit => .comment_edit,
        .comment_delete => .comment_delete,
        .comment_restore => .comment_restore,
        .reaction => .reaction,
        .update, .deleted => .update,
    };
    const new_tip: ?Oid = receipt.tip;
    const after = if (new_tip) |t| (loadObjAt(&c, ident, t) catch null) else null;
    const changes = if (after) |x| (if (new_tip) |t| entryChanges(x, t) else &.{}) else &.{};

    // After a retry the commit's parent isn't the tip read first.
    const parent = if (new_tip) |t| parentOf(&c, t) orelse old_tip else old_tip;
    const w = makeWrite(&c, .issue, ident, parent, new_tip, entry_kind, changes, who) catch |e|
        return rt.failError(err, e, .{});
    o.* = @ptrCast(w);
    return .ok;
}

/// The first parent of `commit`, when it can be read.
fn parentOf(c: *Call, commit: Oid) ?Oid {
    if (c.dry_run) return null;
    const o = (c.session.backend.readObject(
        c.arena(),
        commit,
    ) catch return null) orelse return null;
    const parsed = issuez.backend.object.Commit.parse(c.arena(), commit.object_format, o.data) catch
        return null;
    return if (parsed.parents.len > 0) parsed.parents[0] else null;
}

pub fn issuez_issue_check(
    repo: ?*api.Repo,
    id: Str,
    op_ptr: ?[*]const api.Op,
    n: usize,
    cancel: ?*api.Cancel,
    out: ?*?*api.Problems,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    // {NULL,0}: as a create.
    const existing: ?Str = if (id.len == 0) null else id;
    var scratch: std.heap.ArenaAllocator = .init(rt.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const list: api.OpList = if (existing == null) .issue_create else .issue_update;
    var problems: Problems = .empty;
    const slice = opSlice(op_ptr, n);
    checkOps(a, list, slice, &problems) catch return rt.fail(err, .e_nomem, "out of memory", .{});
    if (problems.items.len == 0) {
        _ = plan(
            a,
            list,
            slice,
            &problems,
        ) catch return rt.fail(err, .e_nomem, "out of memory", .{});
    }
    // Repository rules: the workflow states, references that must exist.
    if (problems.items.len == 0) {
        var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
        defer c.end();
        repoChecks(&c, a, slice, &problems) catch |e| return c.fail(err, e);
    }
    // Then the write itself, guards and all, without writing.
    if (problems.items.len == 0) {
        var w: ?*api.Write = null;
        var e: ?*api.Error = null;
        const code = if (existing) |i|
            issueUpdateIn(repo, i, op_ptr, n, &dry_actor, cancel, &w, &e, true)
        else
            issueCreateIn(repo, op_ptr, n, &dry_actor, cancel, &w, &e, true);
        if (dryFailed(a, code, e, &problems, err)) |failed| return failed;
        issuez_write_free(w);
    }
    const owned = rt.ownedProblems(problems.items) catch return rt.fail(
        err,
        .e_nomem,
        "out of memory",
        .{},
    );
    o.* = @ptrCast(owned);
    return .ok;
}

/// Who a dry run writes as: it writes nothing, and needs no identity.
const dry_actor: api.Actor = .{ .name = Str.of("issuez"), .email = Str.of("check@issuez.invalid") };

/// A dry run's outcome: its problems go to `problems`; other failures
/// (no such issue, git) are the check's own. Takes `e`.
fn dryFailed(
    a: Allocator,
    code: Code,
    e: ?*api.Error,
    problems: *Problems,
    err: ?*?*api.Error,
) ?Code {
    switch (code) {
        .ok => return null,
        .e_invalid_value, .e_guard, .e_limit => {
            defer rt.issuez_error_free(e);
            const list = rt.obj(rt.ErrorObj, e).?.problems;
            const items = if (list) |l| l.items else &.{};
            for (items) |p| problems.append(a, .{
                .kind = @enumFromInt(p.kind),
                .field = @enumFromInt(p.field),
                .key = a.dupe(
                    u8,
                    p.key.slice(),
                ) catch return rt.fail(err, .e_nomem, "out of memory", .{}),
                .value = a.dupe(
                    u8,
                    p.value.slice(),
                ) catch return rt.fail(err, .e_nomem, "out of memory", .{}),
                .subject = a.dupe(
                    u8,
                    p.subject.slice(),
                ) catch return rt.fail(err, .e_nomem, "out of memory", .{}),
                .message = a.dupe(
                    u8,
                    p.message.slice(),
                ) catch return rt.fail(err, .e_nomem, "out of memory", .{}),
                .op_index = p.op_index,
            }) catch return rt.fail(err, .e_nomem, "out of memory", .{});
            if (items.len == 0) problems.append(a, .{
                .kind = .unknown,
                .message = a.dupe(u8, rt.issuez_error_message(e).slice()) catch "",
            }) catch return rt.fail(err, .e_nomem, "out of memory", .{});
            return null;
        },
        else => {
            if (err) |p| p.* = e else rt.issuez_error_free(e);
            return code;
        },
    }
}

/// INVALID_VALUE when two labels of one exclusive scope come together.
fn scopedFailed(c: *Call, slice: []const api.Op, err: ?*?*api.Error) ?Code {
    var problems: Problems = .empty;
    scopeConflicts(c.arena(), c.repo.exclusive_scopes, slice, &problems) catch
        return rt.fail(err, .e_nomem, "out of memory", .{});
    if (problems.items.len == 0) return null;
    return invalid(err, problems.items);
}

/// `a` holds the problems: they outlive the call.
fn repoChecks(c: *Call, a: Allocator, slice: []const api.Op, problems: *Problems) !void {
    try scopeConflicts(a, c.repo.exclusive_scopes, slice, problems);
    for (slice, 0..) |op, i| {
        const index: i64 = @intCast(i);
        if (op.target >= 0x100 or op.verb == @intFromEnum(Verb.clear)) continue;
        const field: Field = @enumFromInt(op.target);
        const s = op.str.slice();
        switch (field) {
            .workflow_state => c.repo.settings.checkWorkflow(s) catch |e|
                try problems.append(a, rt.problemOf(e, field, index)),
            .parent, .blocked_by => if (op.verb != @intFromEnum(Verb.remove) and (try loadObj(
                c,
                s,
            )) == null)
                try problems.append(a, rt.problemOf(error.ReferenceNotFound, field, index)),
            .milestone => if (op.verb == @intFromEnum(Verb.set)) {
                const m = try c.catalog().find(a, s);
                if (m == null) {
                    try problems.append(a, rt.problemOf(error.ReferenceNotFound, field, index));
                } else if (m.?.status != .open) {
                    try problems.append(a, rt.problemOf(error.MilestoneCompleted, field, index));
                }
            },
            else => {},
        }
    }
}

// ─── Milestone writes ──────────────────────────────────────────────────

fn statusOf(s: fields_fmt.MilestoneStatus) []const u8 {
    return @tagName(s);
}

pub fn issuez_milestone_check(
    repo: ?*api.Repo,
    id: Str,
    op_ptr: ?[*]const api.Op,
    n: usize,
    cancel: ?*api.Cancel,
    out: ?*?*api.Problems,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    // {NULL,0}: as a create.
    const existing: ?Str = if (id.len == 0) null else id;
    var scratch: std.heap.ArenaAllocator = .init(rt.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    var ended = false;
    defer if (!ended) c.end();
    const list: api.OpList = if (existing == null) .milestone_create else .milestone_update;
    var problems: Problems = .empty;
    const slice = opSlice(op_ptr, n);
    checkOps(a, list, slice, &problems) catch return rt.fail(err, .e_nomem, "out of memory", .{});
    if (problems.items.len == 0) {
        _ = plan(
            a,
            list,
            slice,
            &problems,
        ) catch return rt.fail(err, .e_nomem, "out of memory", .{});
    }
    if (existing) |i| if (problems.items.len == 0) {
        const m = c.catalog().find(a, i.slice()) catch |e| return c.fail(err, e);
        if (m == null) return rt.failWith(
            err,
            .e_not_found,
            .{ .subject = i.slice() },
            "no such milestone",
            .{},
        );
    };
    // The write itself, without writing. The session goes back first.
    c.end();
    ended = true;
    if (problems.items.len == 0) {
        var w: ?*api.Write = null;
        var e: ?*api.Error = null;
        const code = if (existing) |i|
            milestoneUpdateIn(repo, i, op_ptr, n, &dry_actor, cancel, &w, &e, true)
        else
            milestoneCreateIn(repo, op_ptr, n, &dry_actor, cancel, &w, &e, true);
        if (dryFailed(a, code, e, &problems, err)) |failed| return failed;
        issuez_write_free(w);
    }
    const owned = rt.ownedProblems(problems.items) catch return rt.fail(
        err,
        .e_nomem,
        "out of memory",
        .{},
    );
    o.* = @ptrCast(owned);
    return .ok;
}

pub fn issuez_milestone_create(
    repo: ?*api.Repo,
    op_ptr: ?[*]const api.Op,
    n: usize,
    actor: ?*const api.Actor,
    cancel: ?*api.Cancel,
    out: ?*?*api.Write,
    err: ?*?*api.Error,
) callconv(.c) Code {
    return milestoneCreateIn(repo, op_ptr, n, actor, cancel, out, err, false);
}

fn milestoneCreateIn(
    repo: ?*api.Repo,
    op_ptr: ?[*]const api.Op,
    n: usize,
    actor: ?*const api.Actor,
    cancel: ?*api.Cancel,
    out: ?*?*api.Write,
    err: ?*?*api.Error,
    dry: bool,
) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    c.dry_run = dry;
    const a = c.arena();
    const p = switch (checked(
        a,
        .milestone_create,
        opSlice(op_ptr, n),
        c.repo.extra_prefixes,
        err,
    ) catch |e| return rt.failError(err, e, .{})) {
        .ok => |v| v,
        .failed => |code| return code,
    };
    const author = signatureOf(
        &c,
        actor,
    ) catch return rt.fail(
        err,
        .e_invalid_argument,
        "the actor needs an email, and its user_id must be a UUID",
        .{},
    );
    const who = author orelse (c.engine().identity(
        a,
        null,
    ) catch |e| return c.fail(err, e)).author;
    const catalog = c.catalog();
    const created = catalog.create(a, .{
        .name = p.milestone.name.?,
        .description = p.milestone.description orelse "",
        .due = p.milestone.due,
        .author = author,
        .status = p.milestone.status orelse .open,
    }, .{}) catch |e| return writeFailed(&c, err, e, &p, "");
    var changes: std.ArrayList(api.Change) = .empty;
    changes.append(a, .{
        .field = @intFromEnum(Field.name),
        .key = Str.of("Name"),
        .op = @intFromEnum(Verb.set),
        .old_value = .{},
        .new_value = Str.of(p.milestone.name.?),
    }) catch return rt.fail(err, .e_nomem, "out of memory", .{});

    const w = makeWrite(
        &c,
        .milestone,
        created.id,
        null,
        created.tip,
        .created,
        changes.items,
        who,
    ) catch |e|
        return rt.failError(err, e, .{});
    o.* = @ptrCast(w);
    return .ok;
}

pub fn issuez_milestone_update(
    repo: ?*api.Repo,
    id: Str,
    op_ptr: ?[*]const api.Op,
    n: usize,
    actor: ?*const api.Actor,
    cancel: ?*api.Cancel,
    out: ?*?*api.Write,
    err: ?*?*api.Error,
) callconv(.c) Code {
    return milestoneUpdateIn(repo, id, op_ptr, n, actor, cancel, out, err, false);
}

fn milestoneUpdateIn(
    repo: ?*api.Repo,
    id: Str,
    op_ptr: ?[*]const api.Op,
    n: usize,
    actor: ?*const api.Actor,
    cancel: ?*api.Cancel,
    out: ?*?*api.Write,
    err: ?*?*api.Error,
    dry: bool,
) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    const ident = id.slice();
    if (!uuid_fmt.isCanonical(ident)) return rt.fail(
        err,
        .e_invalid_argument,
        "not a full milestone UUID",
        .{},
    );
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    c.dry_run = dry;
    const a = c.arena();
    const p = switch (checked(
        a,
        .milestone_update,
        opSlice(op_ptr, n),
        c.repo.extra_prefixes,
        err,
    ) catch |e| return rt.failError(err, e, .{})) {
        .ok => |v| v,
        .failed => |code| return code,
    };
    const author = signatureOf(
        &c,
        actor,
    ) catch return rt.fail(
        err,
        .e_invalid_argument,
        "the actor needs an email, and its user_id must be a UUID",
        .{},
    );
    const who = author orelse (c.engine().identity(
        a,
        null,
    ) catch |e| return c.fail(err, e)).author;
    const catalog = c.catalog();
    const before = (catalog.find(a, ident) catch |e| return c.fail(err, e)) orelse
        return rt.failWith(err, .e_not_found, .{ .subject = ident }, "no such milestone", .{});
    if (p.expect) |want| if (!want.eql(before.tip)) return rt.failWith(err, .e_version_mismatch, .{
        .subject = ident,
        .current_tip = rt.oidOf(before.tip),
    }, "the milestone changed since it was read", .{});
    const nothing = p.milestone.name == null and p.milestone.description == null and
        p.milestone.due == null and !p.milestone.clear_due and p.milestone.status == null;
    const tip: ?Oid = if (nothing) null else catalog.edit(a, ident, .{
        .name = p.milestone.name,
        .due = if (p.milestone.clear_due)
            .clear
        else if (p.milestone.due) |d|
            .{ .set = d }
        else
            null,
        .status = p.milestone.status,
        .description = p.milestone.description,
        .message = p.subject,
        .author = author,
        .expect = p.expect orelse before.tip,
    }, .{}) catch |e| return writeFailed(&c, err, e, &p, ident);
    var changes: std.ArrayList(api.Change) = .empty;
    const add = struct {
        fn f(
            list: *std.ArrayList(api.Change),
            al: Allocator,
            field: Field,
            old: []const u8,
            new: ?[]const u8,
        ) !void {
            const v = new orelse return;
            if (std.mem.eql(u8, old, v)) return;
            try list.append(al, .{
                .field = @intFromEnum(field),
                .key = Str.of(field.key()),
                .op = @intFromEnum(if (v.len == 0) Verb.clear else Verb.set),
                .old_value = Str.of(old),
                .new_value = Str.of(v),
            });
        }
    }.f;
    var old_due_buf: [10]u8 = undefined;
    const old_due: []const u8 = if (before.due) |d|
        std.fmt.bufPrint(
            &old_due_buf,
            "{d:0>4}-{d:0>2}-{d:0>2}",
            .{ d.year, d.month, d.day },
        ) catch ""
    else
        "";
    if (tip != null) {
        add(&changes, a, .name, before.name, p.milestone.name) catch {};
        add(&changes, a, .description, before.description, p.milestone.description) catch {};
        add(
            &changes,
            a,
            .due_date,
            old_due,
            if (p.milestone.clear_due)
                ""
            else if (p.milestone.due) |d|
                std.fmt.allocPrint(a, "{f}", .{d}) catch null
            else
                null,
        ) catch {};
        add(
            &changes,
            a,
            .milestone_status,
            statusOf(before.status),
            if (p.milestone.status) |s| statusOf(s) else null,
        ) catch {};
    }

    const w = makeWrite(
        &c,
        .milestone,
        ident,
        before.tip,
        tip,
        .update,
        changes.items,
        who,
    ) catch |e|
        return rt.failError(err, e, .{});
    o.* = @ptrCast(w);
    return .ok;
}

comptime {
    _ = WriteObj.freeOpaque;
}

// ─── Attachments ───────────────────────────────────────────────────────

pub fn issuez_attachment_validate(
    repo: ?*api.Repo,
    name: Str,
    data: Str,
    media_type: ?*Str,
    err: ?*?*api.Error,
) callconv(.c) Code {
    if (name.len == 0) return rt.failWith(err, .e_invalid_value, .{
        .problems = &.{
            .{ .kind = .empty, .field = .attachments, .message = "an attachment has a name" },
        },
    }, "an attachment has a name", .{});
    var c = Call.begin(repo, null) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const store = Store.fromRepo(c.engine());
    const media = store.validate(.{ .name = name.slice(), .data = data.slice() }) catch |e| {
        const p: Plan = .{};
        return writeFailed(&c, err, e, &p, "");
    };
    if (media_type) |m| m.* = Str.of(media.mediaType());
    return .ok;
}

const PreparedObj = struct {
    arena: *std.heap.ArenaAllocator,
    info: api.AttachmentSpec,
    encoded: Str,
};

pub fn issuez_attachment_prepare(
    repo: ?*api.Repo,
    id: Str,
    name: Str,
    data: Str,
    cancel: ?*api.Cancel,
    out: ?*?*api.PreparedAttachment,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const spec = Store.fromRepo(c.engine()).prepare(c.arena(), .{
        .id = if (id.len == 0) null else id.slice(),
        .name = name.slice(),
        .data = data.slice(),
    }) catch |e| {
        const p: Plan = .{};
        return writeFailed(&c, err, e, &p, "");
    };
    const arena = rt.newArena() catch |e| return rt.failError(err, e, .{});
    const a = arena.allocator();
    const p = makePrepared(a, arena, spec) catch |e| {
        rt.freeArena(arena);
        return rt.failError(err, e, .{});
    };
    o.* = @ptrCast(p);
    return .ok;
}

fn makePrepared(
    a: Allocator,
    arena: *std.heap.ArenaAllocator,
    spec: attachment_fmt.Spec,
) !*PreparedObj {
    const p = try a.create(PreparedObj);
    p.* = .{
        .arena = arena,
        .info = .{
            .id = try rt.dupeZ(a, spec.id),
            .name = try rt.dupeZ(a, spec.name),
            .media_type = try rt.dupeZ(a, spec.media.mediaType()),
            .sha256 = try rt.dupeZ(a, spec.sha256.slice()),
            .size = spec.size,
        },
        .encoded = try rt.dupeZ(a, try std.fmt.allocPrint(a, "{f}", .{spec})),
    };
    return p;
}

pub fn issuez_prepared_attachment_info(
    p: ?*const api.PreparedAttachment,
) callconv(.c) ?*const api.AttachmentSpec {
    const o = rt.obj(PreparedObj, p) orelse return null;
    return &o.info;
}

pub fn issuez_prepared_attachment_op(p: ?*const api.PreparedAttachment) callconv(.c) api.Op {
    const o = rt.obj(PreparedObj, p) orelse return .{};
    return .{
        .verb = @intFromEnum(Verb.add),
        .target = @intFromEnum(Opt.prepared_attachment),
        .str = o.encoded,
    };
}

pub fn issuez_prepared_attachment_free(p: ?*api.PreparedAttachment) callconv(.c) void {
    const o = rt.obj(PreparedObj, p) orelse return;
    rt.freeArena(o.arena);
}

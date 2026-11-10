//! Writes: op lists checked and turned into one engine write, write
//! receipts, comment events and milestone writes.
//!
//! An op list becomes one commit. A list that can't (a delete with other
//! changes, a description edit with a comment) fails with INVALID_VALUE,
//! problem INCOMPATIBLE.

const std = @import("std");
const assert = std.debug.assert;
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
const Signature = issuez.backend.object.Signature;
const Oid = issuez.backend.object.Oid;
const core_fmt = issuez.format.core;
const fields_fmt = issuez.format.fields;
const uuid_fmt = issuez.format.uuid;
const labels_fmt = issuez.format.labels;
const attachment_fmt = issuez.format.attachment;
const Store = issuez.Attachments(repo_mod.Backend);

// ─── Checking op lists ─────────────────────────────────────────────────

const Problems = rt.Problems;

const set_only: []const Verb = &.{.set};
const set_clear: []const Verb = &.{ .set, .clear };
const add_remove: []const Verb = &.{ .add, .remove };

/// The verbs a target takes in a list; null when it isn't one of its targets.
fn verbsOf(list: api.OpList, target: u32) ?[]const Verb {
    const update = list == .issue_update;
    const milestone = list == .milestone_create or list == .milestone_update;
    if (target >= 0x100) return switch (@as(Opt, @fromBackingInt(@intCast(target)))) {
        // A new commit has no tip to expect, and its subject is the title.
        .expect, .subject => if (list == .issue_create or list == .milestone_create)
            null
        else
            set_only,
        .original_author, .original_id => if (milestone) null else set_only,
        .prepared_attachment => if (milestone) null else &.{.add},
        .edit_comment,
        .expect_edits,
        .delete_comment,
        .restore_comment,
        .reaction_target,
        => if (update) set_only else null,
        else => null,
    };
    const f: Field = @fromBackingInt(@intCast(target));
    if (milestone) return switch (f) {
        .name, .description, .milestone_status => set_only,
        .due_date => set_clear,
        else => null,
    };
    return switch (f) {
        .title, .description, .comment, .state, .fixed_by, .release, .reason => set_only,
        .locked, .deleted, .number, .extra => set_only,
        .ref, .workflow_state, .priority, .estimate, .parent, .start_date, .due_date => set_clear,
        .labels, .blocked_by, .assignees => &.{ .add, .remove, .clear },
        .milestone => &.{ .set, .clear, .inherit },
        .attachments => add_remove,
        .reactions => if (update) add_remove else null,
        else => null,
    };
}

fn targetField(target: u32) Field {
    return if (target < 0x100) @fromBackingInt(@intCast(target)) else .unknown;
}

/// Problems with the ops themselves and their values' format: everything
/// that doesn't need the repository.
fn checkOps(a: Allocator, list: api.OpList, ops: []const api.Op, problems: *Problems) !void {
    for (ops, 0..) |op, i| {
        var check: rt.OpCheck = .at(a, problems, i);
        if (try check.reserved(op)) continue;
        const field = targetField(op.target);
        check.field = field;
        const verbs = verbsOf(list, op.target) orelse {
            try check.add(.unknown_target, "not a target of this call");
            continue;
        };
        const verb: Verb = @fromBackingInt(@intCast(op.verb));
        if (std.mem.indexOfScalar(Verb, verbs, verb) == null) {
            try check.add(.bad_verb, "this verb doesn't apply to this target");
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
            try check.add(.too_long, "longer than the limit");
            continue;
        };
        const blank = std.mem.trim(u8, s, " \t\r\n").len == 0;
        const multiline = std.mem.findAny(u8, s, "\r\n") != null;
        switch (field) {
            .title, .name => if (blank) {
                try check.addValue(.empty, s, "must not be empty");
            } else if (multiline) {
                try check.addValue(.newline, s, "must be one line");
            },
            .comment => if (blank) try check.addValue(.empty, s, "must not be empty"),
            .state => if (!core_fmt.isState(s))
                try check.addValue(.bad_format, s, "states are letters, digits, '-' and '_'"),
            .workflow_state => if (!fields_fmt.isSlug(s)) try check.addValue(
                .bad_format,
                s,
                "workflow states are lowercase letters, digits and '-'",
            ),
            .ref => if (!fields_fmt.isRefName(s))
                try check.addValue(.bad_format, s, "not a branch or tag name"),
            .locked, .fixed_by, .release, .reason => if (multiline)
                try check.addValue(.newline, s, "must be one line"),
            .labels => labels_fmt.validate(s) catch
                try check.addValue(.bad_format, s, "labels must not contain commas or newlines"),
            .blocked_by, .parent, .milestone => if (!uuid_fmt.isCanonical(s))
                try check.addValue(.bad_format, s, "references are full UUIDs"),
            .assignees => {
                const email = op.person.email.slice();
                if (core_fmt.checkEmail(email) != null)
                    try check.addValue(.bad_format, email, "not an email address");
                const uid = op.person.user_id.slice();
                if (uid.len > 0 and !uuid_fmt.isCanonical(uid))
                    try check.addValue(.bad_format, uid, "user IDs are UUIDs");
            },
            .priority => if (op.num < 1 or op.num > 4) try check.add(.bad_format, "not a priority"),
            .estimate => if (op.num < 0 or op.num > 10 * 366 * 24 * 60)
                try check.add(.bad_format, "estimates are 0 to 10 years, in minutes"),
            .start_date, .due_date => if (engineDate(op.date) == null)
                try check.add(.bad_format, "not a calendar day"),
            .milestone_status => if (op.num < 1 or op.num > 3)
                try check.add(.bad_format, "not a milestone status"),
            .extra => {
                const key = op.name.slice();
                const namespaced = key.len > 2 and std.ascii.startsWithIgnoreCase(key, "X-");
                const usable = issuez.format.trailers.isValidKey(key) and
                    !issuez.model.issue.isFormatKey(key);
                if (!namespaced or !usable) try check.addValue(
                    .bad_format,
                    key,
                    "host fields are X- keys the format doesn't use",
                );
                if (multiline) try check.addValue(.newline, s, "must be one line");
            },
            .number => if (op.num < 1) try check.add(.bad_format, "numbers start at 1"),
            .attachments => if (verb == .remove) {
                if (!uuid_fmt.isCanonical(s))
                    try check.addValue(.bad_format, s, "attachments are removed by their UUID");
            } else {
                if (s.len == 0) try check.add(.empty, "an attachment has bytes");
                if (op.name.len == 0) try check.add(.empty, "an attachment has a name");
                if (op.id.len > 0 and !uuid_fmt.isCanonical(op.id.slice())) try check.addValue(
                    .bad_format,
                    op.id.slice(),
                    "an attachment's id is a full UUID",
                );
            },
            else => {},
        }
        const oid_opt = op.target == @backingInt(Opt.expect) or
            op.target == @backingInt(Opt.edit_comment) or
            op.target == @backingInt(Opt.delete_comment) or
            op.target == @backingInt(Opt.restore_comment) or
            op.target == @backingInt(Opt.reaction_target);
        if (oid_opt and rt.oidFrom(op.oid) == null) try check.add(.bad_format, "not an object ID");
    }
}

/// checkOps, then the plan's problems when there are none yet.
fn validate(a: Allocator, list: api.OpList, ops: []const api.Op, problems: *Problems) !void {
    try checkOps(a, list, ops, problems);
    if (problems.items.len == 0) _ = try plan(a, list, ops, problems);
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
    const o = out orelse return rt.badArgument(err, "out is NULL");
    var scratch: std.heap.ArenaAllocator = .init(rt.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var problems: Problems = .empty;
    const slice = rt.sliceOf(api.Op, ops, n);
    switch (list) {
        .issue_create, .issue_update, .milestone_create, .milestone_update => validate(
            a,
            list,
            slice,
            &problems,
        ) catch return rt.oom(err),
        .query => _ = read.parseQuery(a, slice, &problems) catch return rt.oom(err),
        .open => repo_mod.validateOpen(a, slice, &problems) catch return rt.oom(err),
        .push_check => _ = more.parsePushOps(a, slice, &problems) catch return rt.oom(err),
        else => return rt.badArgument(err, "not an issuez_op_list"),
    }
    return rt.give(o, rt.ownedProblems(problems.items), err);
}

// ─── Planning a write ──────────────────────────────────────────────────

/// A list field's ops, as adds and removes; a CLEAR replaces.
fn SetEdit(comptime Item: type) type {
    return struct {
        add: std.ArrayList(Item) = .empty,
        remove: std.ArrayList([]const u8) = .empty,
        replace: bool = false,

        fn apply(e: *@This(), a: Allocator, verb: Verb, item: Item, key: []const u8) !void {
            switch (verb) {
                .clear => {
                    e.replace = true;
                    e.add.clearRetainingCapacity();
                    e.remove.clearRetainingCapacity();
                },
                .add => try e.add.append(a, item),
                else => try e.remove.append(a, key),
            }
        }
    };
}

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
    labels: SetEdit([]const u8) = .{},
    blockers: SetEdit([]const u8) = .{},
    assignees: SetEdit(fields_fmt.Assignee) = .{},
    extra: std.ArrayList(issuez.engine.HostField) = .empty,
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
        const i = @backingInt(f);
        return if (i < 32) p.op_of[i] else -1;
    }
};

/// One value, on both specs: a field an update and a create spell alike.
fn both(edit: anytype, create: anytype, value: anytype) void {
    edit.* = value;
    create.* = value;
}

/// A text field that SET or CLEAR changes; CLEAR leaves a create as it is.
fn setText(
    edit: *?issuez.engine.EditSpec.TextEdit,
    create: *?[]const u8,
    verb: Verb,
    s: []const u8,
) void {
    if (verb == .clear) {
        edit.* = .clear;
    } else {
        edit.* = .{ .set = s };
        create.* = s;
    }
}

fn plan(a: Allocator, list: api.OpList, ops: []const api.Op, problems: *Problems) !Plan {
    var p: Plan = .{};
    const creating = list == .issue_create or list == .milestone_create;
    const whole: rt.OpCheck = .{ .a = a, .problems = problems, .index = -1 };
    for (ops, 0..) |op, i| {
        const index: i64 = @intCast(i);
        const verb: Verb = @fromBackingInt(@intCast(op.verb));
        const s = op.str.slice();
        if (op.target >= 0x100) {
            switch (@as(Opt, @fromBackingInt(@intCast(op.target)))) {
                .expect => p.expect = rt.oidFrom(op.oid),
                .subject => p.subject = s,
                .original_author => both(&p.edit.original.author, &p.create.original.author, s),
                .original_id => both(&p.edit.original.id, &p.create.original.id, s),
                .edit_comment => p.edit_comment = rt.oidFrom(op.oid),
                .expect_edits => p.expect_edits = op.num,
                .prepared_attachment => {
                    if (attachment_fmt.parseSpec(s)) |spec| {
                        try p.attachments_prepared.append(a, spec);
                        p.has_fields = true;
                    } else {
                        const check = whole.on(.attachments, index);
                        try check.add(.bad_format, "invalid prepared attachment metadata");
                    }
                },
                .delete_comment, .restore_comment => if (rt.oidFrom(op.oid)) |t| {
                    p.comment_event = .{
                        .target = t,
                        .delete = op.target == @backingInt(Opt.delete_comment),
                    };
                },
                .reaction_target => p.reaction_target = rt.oidFrom(op.oid),
                else => unreachable,
            }
            continue;
        }
        const field: Field = @fromBackingInt(@intCast(op.target));
        if (@backingInt(field) < 32) p.op_of[@backingInt(field)] = index;
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
        const check = whole.on(field, index);
        switch (field) {
            .comment, .deleted, .reactions => {},
            .state, .fixed_by, .release, .reason => p.has_state = true,
            else => p.has_fields = true,
        }
        switch (field) {
            .comment => {
                if (creating)
                    try check.add(.incompatible, "a new issue has no comment; use DESCRIPTION");
                p.comment = s;
            },
            .state => p.state = s,
            .fixed_by => p.fixed_by = s,
            .release => p.release = s,
            .reason => p.reason = s,
            .deleted => p.deleted = op.num != 0,
            .title => both(&p.edit.title, &p.create.title, s),
            .description => both(&p.edit.description, &p.create.body, s),
            .workflow_state => setText(&p.edit.workflow, &p.create.workflow, verb, s),
            .labels => try p.labels.apply(a, verb, s, s),
            .blocked_by => try p.blockers.apply(a, verb, s, s),
            .assignees => {
                const email = op.person.email.slice();
                const uid = op.person.user_id.slice();
                const who: fields_fmt.Assignee = .{
                    .uuid = if (uid.len > 0) uid else null,
                    .email = email,
                };
                const key = if (verb == .remove and uid.len > 0) try who.text(a) else email;
                try p.assignees.apply(a, verb, who, key);
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
            },
            .milestone => {
                const m: issuez.engine.MilestoneEdit = switch (verb) {
                    .set => .linked(s),
                    .inherit => .{ .link = .inherit },
                    else => .{ .link = .none },
                };
                both(&p.edit.milestone, &p.create.milestone, m);
            },
            .parent => setText(&p.edit.parent, &p.create.parent, verb, s),
            .start_date, .due_date => {
                const date = if (verb == .clear) null else engineDate(op.date).?;
                const start = field == .start_date;
                const edit = if (start) &p.edit.start_date else &p.edit.due_date;
                edit.* = if (date) |d| .{ .set = d } else .clear;
                const create = if (start) &p.create.start_date else &p.create.due_date;
                create.* = date;
            },
            .estimate => {
                p.edit.estimate_minutes = if (verb == .clear)
                    .clear
                else
                    .{ .set = @intCast(op.num) };
                if (verb != .clear) p.create.estimate_minutes = @intCast(op.num);
            },
            .number => both(&p.edit.number, &p.create.number, @as(u64, @intCast(op.num))),
            .locked => {
                both(&p.edit.locked, &p.create.locked, op.num != 0);
                if (op.num != 0 and s.len > 0) both(&p.edit.lock_reason, &p.create.lock_reason, s);
            },
            .ref => setText(&p.edit.ref, &p.create.ref, verb, s),
            .extra => try p.extra.append(a, .{ .key = op.name.slice(), .value = s }),
            .reactions => {
                if (!fields_fmt.isEmoji(s)) try check.addValue(
                    .bad_format,
                    s,
                    "an emoji is 1 to 64 bytes without whitespace or commas",
                );
                p.reaction = .{ .emoji = s, .present = verb == .add };
            },
            .attachments => if (verb == .remove) {
                if (creating)
                    try check.add(.incompatible, "a new issue has no attachments to remove");
                try p.attachments_remove.append(a, s);
            } else {
                const id: ?[]const u8 = if (op.id.len > 0) op.id.slice() else null;
                try p.attachments_add.append(a, .{ .name = op.name.slice(), .data = s, .id = id });
            },
            else => unreachable,
        }
    }
    if (list == .milestone_create and p.milestone.name == null)
        try whole.on(.name, -1).add(.missing_value, "a new milestone needs a name");
    const deleted = whole.on(.deleted, p.opOf(.deleted));
    if (list == .issue_create) {
        if (p.create.title.len == 0)
            try whole.on(.title, -1).add(.missing_value, "a new issue needs a title");
        if (p.deleted != null) try deleted.add(.incompatible, "a new issue isn't deleted");
    }
    if (list == .issue_update) {
        if (p.deleted != null and (p.has_state or p.has_fields or p.comment != null))
            try deleted.add(.incompatible, "a delete or restore " ++
                "can't share a commit with other changes");
        if (p.comment != null and p.edit.description != null)
            try whole.on(.comment, p.opOf(.comment)).add(.incompatible, "a description edit " ++
                "can't carry a comment: its text is the description");
        if (p.comment_event != null or p.reaction != null) {
            // A commit of its own: only EXPECT and SUBJECT (and the
            // reaction's target) go with it.
            for (ops, 0..) |op, i| {
                const own = (op.target >= 0x100 and
                    op.target != @backingInt(Opt.prepared_attachment) and
                    op.target != @backingInt(Opt.expect_edits)) or
                    op.target == @backingInt(Field.reactions);
                if (!own or (p.comment_event != null and p.reaction != null) or
                    (p.edit_comment != null)) try whole.on(targetField(op.target), @intCast(i)).add(
                    .incompatible,
                    "a comment delete, restore or reaction is a commit of its own",
                );
            }
        }
        if (p.edit_comment != null) {
            if (p.comment == null) try whole.on(.comment, -1)
                .add(.missing_value, "a comment edit needs the comment's new text");
            // Only the comment's text and images, as its edit event takes.
            for (ops, 0..) |op, i| {
                const alone = op.target == @backingInt(Field.comment) or
                    op.target == @backingInt(Field.attachments) or op.target >= 0x100;
                if (!alone) try whole.on(targetField(op.target), @intCast(i))
                    .add(.incompatible, "a comment edit carries only COMMENT and ATTACHMENTS");
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
    if (c.repo.store_attachments) {
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
        if (!rt.oidEql(&e.public.commit, &want)) continue;
        const ptr = e.changes orelse return &.{};
        return ptr[0..e.public.change_count];
    }
    return &.{};
}

// ─── The receipt ───────────────────────────────────────────────────────

pub const WriteObj = struct {
    arena: *std.heap.ArenaAllocator,
    repo: *RepoObj,
    kind: api.Kind = .unknown,
    id: Str = .{},
    /// `id`'s bytes: a UUID and its NUL need no allocation once the
    /// commit landed.
    id_buf: [37]u8 = @splat(0),
    wrote: bool = false,
    commit: api.Oid = .{},
    old_tip: api.Oid = .{},
    new_tip: api.Oid = .{},
    retries: u32 = 0,
    entry: read.EntryObj = std.mem.zeroes(read.EntryObj),

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

/// A write's receipt, allocated before its commit: one whose commit
/// landed returns OK, whatever memory is left then.
fn reserveWrite(c: *Call) Allocator.Error!*WriteObj {
    const arena = try rt.newArena();
    errdefer rt.freeArena(arena);
    const w = try arena.allocator().create(WriteObj);
    w.* = .{ .arena = arena, .repo = c.repo };
    return w;
}

/// Fills a reserved receipt, which can't fail: the entry's changes and
/// author are left out when there is no memory for them.
fn makeWrite(
    c: *Call,
    w: *WriteObj,
    kind: api.Kind,
    id: []const u8,
    given_old_tip: ?Oid,
    given_new_tip: ?Oid,
    entry_kind: api.EntryKind,
    given_changes: []const api.Change,
    author: Signature,
) *WriteObj {
    // The engine skipped a commit that changed nothing: the tip it returned
    // is the one there was.
    const old_tip = if (c.skipped) given_new_tip orelse given_old_tip else given_old_tip;
    const new_tip = if (c.skipped) null else given_new_tip;
    const changes = if (c.skipped) &.{} else given_changes;
    const a = w.arena.allocator();
    const copied = copyChanges(a, changes) catch &.{};
    const wrote = new_tip != null and (old_tip == null or !old_tip.?.eql(new_tip.?));
    assert(uuid_fmt.isCanonical(id));
    @memcpy(w.id_buf[0..36], id);
    w.kind = kind;
    w.id = .{ .ptr = &w.id_buf, .len = 36 };
    w.wrote = wrote;
    w.retries = c.retries;
    w.commit = if (wrote) rt.oidOf(new_tip.?) else .{};
    w.old_tip = if (old_tip) |t| rt.oidOf(t) else .{};
    w.new_tip = if (new_tip) |t| rt.oidOf(t) else if (old_tip) |t| rt.oidOf(t) else .{};
    w.entry = .{
        .public = .{
            .kind = @backingInt(entry_kind),
            .commit = w.commit,
            .author = rt.newPerson(a, author, c.author_id) catch null,
            .at = rt.timeOf(author),
            .comment = null,
            .change_count = copied.len,
            .is_new = true,
        },
        .changes = copied.ptr,
    };
    c.repo.retain();
    return w;
}

fn copyChanges(a: Allocator, changes: []const api.Change) Allocator.Error![]const api.Change {
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
        const field: Field = @fromBackingInt(@intCast(ch.field));
        if (field == .due_date or field == .start_date) {
            if (fields_fmt.Date.parse(ch.old_value.slice())) |d| o.old_date = rt.dateOf(d);
            if (fields_fmt.Date.parse(ch.new_value.slice())) |d| o.new_date = rt.dateOf(d);
        }
    }
    return copied;
}

fn getWrite(w: ?*const api.Write) ?*WriteObj {
    return rt.obj(WriteObj, w);
}

pub fn issuez_write_free(w: ?*api.Write) callconv(.c) void {
    const o = getWrite(w) orelse return;
    o.free();
}
const WriteReads = rt.Reads(api.Write, WriteObj);
pub const issuez_write_kind = WriteReads.field("kind");
pub const issuez_write_id = WriteReads.field("id");
pub const issuez_write_wrote = WriteReads.field("wrote");
pub const issuez_write_commit = WriteReads.field("commit");
pub const issuez_write_old_tip = WriteReads.field("old_tip");
pub const issuez_write_new_tip = WriteReads.field("new_tip");
pub const issuez_write_retries = WriteReads.field("retries");
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
    const o = getWrite(w) orelse return rt.badArgument(err, "w is NULL");
    if (o.kind != .issue) return rt.badArgument(err, "not an issue write");
    return read.issuez_issue_load_at(@ptrCast(o.repo), o.id, &o.new_tip, null, cancel, out, err);
}

pub fn issuez_write_load_milestone(
    w: ?*const api.Write,
    cancel: ?*api.Cancel,
    out: ?*?*api.Milestone,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = getWrite(w) orelse return rt.badArgument(err, "w is NULL");
    if (o.kind != .milestone) return rt.badArgument(err, "not a milestone write");
    return more.issuez_milestone_load_at(@ptrCast(o.repo), o.id, &o.new_tip, cancel, out, err);
}

// ─── Issue writes ──────────────────────────────────────────────────────

/// The actor's signature; its `user_id`, a UUID, goes on the call's
/// commits as `X-Author-Id`. Null with an error set when it can't be one.
fn signatureOf(
    c: *Call,
    actor: ?*const api.Actor,
    out: *?Signature,
    err: ?*?*api.Error,
) ?Code {
    out.* = null;
    const act = actor orelse return null;
    switch (rt.actorSignature(act.*)) {
        .bad => |message| return rt.fail(err, .e_invalid_argument, "{s}", .{message}),
        .sig => |sig| out.* = sig,
    }
    if (act.user_id.len > 0) c.author_id = act.user_id.slice();
    return null;
}

/// Format problems first, then the plan's; INVALID_VALUE with all of them.
fn checked(
    a: Allocator,
    list: api.OpList,
    slice: []const api.Op,
    prefixes: []const []const u8,
    out: *Plan,
    err: ?*?*api.Error,
) !?Code {
    var problems: Problems = .empty;
    try checkOps(a, list, slice, &problems);
    if (problems.items.len > 0) return invalid(err, problems.items);
    out.* = try plan(a, list, slice, &problems);
    // Host fields only under the prefixes the repo was opened with.
    for (slice, 0..) |op, i| {
        if (op.target != @backingInt(Field.extra)) continue;
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
    return if (problems.items.len > 0) invalid(err, problems.items) else null;
}

/// What every write starts from: its plan, who writes it, and its receipt.
const Begun = struct {
    plan: Plan,
    author: ?Signature,
    who: Signature,
    /// Freed with the call unless the write hands it out.
    receipt: ?*WriteObj,

    fn discard(b: *Begun) void {
        if (b.receipt) |w| rt.freeArena(w.arena);
    }

    fn give(b: *Begun, out: *?*api.Write, w: *WriteObj) Code {
        assert(b.receipt == w);
        b.receipt = null;
        out.* = @ptrCast(w);
        return .ok;
    }
};

/// The start of a write: `out` is set, or the failure's code comes back.
fn beginWrite(
    c: *Call,
    out: *Begun,
    list: api.OpList,
    op_ptr: ?[*]const api.Op,
    n: usize,
    actor: ?*const api.Actor,
    err: ?*?*api.Error,
) ?Code {
    const a = c.arena();
    const slice = rt.sliceOf(api.Op, op_ptr, n);
    const failed = checked(a, list, slice, c.repo.extra_prefixes, &out.plan, err) catch |e|
        return rt.failError(err, e, .{});
    if (failed) |code| return code;
    if (scopedFailed(c, slice, err)) |code| return code;
    if (signatureOf(c, actor, &out.author, err)) |code| return code;
    out.who = out.author orelse who: {
        const identity = c.engine().identity(a, null) catch |e| return c.fail(err, e);
        break :who identity.author;
    };
    out.receipt = reserveWrite(c) catch return rt.oom(err);
    return null;
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
    const name = c.issueRef(id) catch return null;
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
        if (op.target != @backingInt(Field.labels) or op.verb != @backingInt(Verb.add)) continue;
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
    if (p.labels.replace) return;
    for (p.labels.add.items) |added| {
        const scope = exclusiveScopeOf(scopes, added) orelse continue;
        for (current) |l| {
            const label = l.slice();
            if (std.mem.eql(u8, label, added)) continue;
            const other = exclusiveScopeOf(scopes, label) orelse continue;
            if (std.mem.eql(u8, other, scope)) try p.labels.remove.append(a, label);
        }
    }
}

fn applySets(p: *Plan) void {
    if (p.labels.replace) {
        p.edit.set_labels = p.labels.add.items;
    } else {
        p.edit.add_labels = p.labels.add.items;
        p.edit.remove_labels = p.labels.remove.items;
    }
    p.create.labels = p.labels.add.items;
    if (p.blockers.replace) {
        p.edit.set_blocked_by = p.blockers.add.items;
    } else {
        p.edit.add_blocked_by = p.blockers.add.items;
        p.edit.remove_blocked_by = p.blockers.remove.items;
    }
    p.create.blocked_by = p.blockers.add.items;
    const touched = p.assignees.replace or p.assignees.add.items.len > 0 or
        p.assignees.remove.items.len > 0;
    if (p.assignees.replace) {
        p.edit.set_assignees = p.assignees.add.items;
    } else if (touched) {
        p.edit.add_assignees = p.assignees.add.items;
        p.edit.remove_assignees = p.assignees.remove.items;
    }
    p.create.assignees = p.assignees.add.items;
    p.edit.extra = p.extra.items;
    p.create.extra = p.extra.items;
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
    const o = out orelse return rt.badArgument(err, "out is NULL");
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    var w: Begun = undefined;
    if (beginWrite(&c, &w, .issue_create, op_ptr, n, actor, err)) |code| return code;
    defer w.discard();
    const a = c.arena();
    const p = &w.plan;
    applySets(p);
    p.create.author = w.author;
    if (p.state) |st| p.create.state = core_fmt.State.parse(st);
    p.create.fixed_by = p.fixed_by;
    p.create.release = p.release;
    p.create.reason = p.reason;
    p.create.attachments = prepareAttachments(&c, p) catch |e|
        return writeFailed(&c, err, e, p, "");
    const created = c.engine().create(a, p.create, .{}) catch |e|
        return writeFailed(&c, err, e, p, "");
    const id = created.id;
    const after = loadObjAt(&c, id, created.tip) catch null;
    const changes = if (after) |x| entryChanges(x, created.tip) else &.{};

    const slot = w.receipt.?;
    const write = makeWrite(&c, slot, .issue, id, null, created.tip, .created, changes, w.who);
    return w.give(o, write);
}

fn loadObj(c: *Call, id: []const u8) !?*read.IssueObj {
    const tip = (try c.session.backend.resolveRef(try c.issueRef(id))) orelse return null;
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
    const o = out orelse return rt.badArgument(err, "out is NULL");
    const ident = id.slice();
    if (!uuid_fmt.isCanonical(ident)) return rt.badArgument(err, "not a full issue UUID");
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    var w: Begun = undefined;
    if (beginWrite(&c, &w, .issue_update, op_ptr, n, actor, err)) |code| return code;
    defer w.discard();
    const a = c.arena();
    const p = &w.plan;
    const engine = c.engine();
    const before = (loadObj(&c, ident) catch |e| return c.fail(err, e)) orelse
        return rt.notFound(err, ident, "no such issue");
    const removals = p.labels.remove.items.len;
    replaceScoped(a, c.repo.exclusive_scopes, p, before.labels) catch return rt.oom(err);
    // Pinned to the tip read only where the write depends on it: a state
    // kept from it, labels its scope takes off. Otherwise a concurrent
    // write is retried over, as in the engine.
    const depends = (p.has_state and p.state == null) or p.labels.remove.items.len > removals;
    applySets(p);
    const old_tip = rt.oidFrom(before.info.tip).?;
    if (p.expect) |want| if (!want.eql(old_tip)) return rt.failWith(err, .e_version_mismatch, .{
        .subject = ident,
        .current_tip = before.info.tip,
    }, "the issue changed since it was read", .{});
    if (p.expect_edits) |want| {
        if (want < 0 or want > std.math.maxInt(u32) or
            (p.edit.description == null and p.edit_comment == null))
            return rt.fail(err, .e_invalid_value, "EXPECT_EDITS needs a text and a u32 count", .{});
        p.edit.expect_edits = @intCast(want);
    }
    const ref_name = c.issueRef(ident) catch return rt.oom(err);
    const expect: ?Oid = p.expect orelse if (depends) old_tip else null;

    p.edit.attachments = attachmentChanges(&c, p) catch |e|
        return writeFailed(&c, err, e, p, ident);
    if (p.has_state) {
        p.edit.state = core_fmt.State.parse(p.state orelse before.info.state_name.slice());
        p.edit.fixed_by = p.fixed_by;
        p.edit.release = p.release;
        p.edit.reason = p.reason;
    }
    p.edit.comment = p.comment;
    p.edit.message = p.subject;
    p.edit.author = w.author;
    p.edit.expect = expect;
    const comment_event: @FieldType(issuez.Update, "comment_event") = if (p.edit_comment) |t|
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
    }, .{}) catch |e| return writeFailed(&c, err, e, p, ident);
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
    const slot = w.receipt.?;
    const write = makeWrite(&c, slot, .issue, ident, parent, new_tip, entry_kind, changes, w.who);
    return w.give(o, write);
}

/// The first parent of `commit`, when it can be read.
fn parentOf(c: *Call, commit: Oid) ?Oid {
    const o = (c.session.backend.readObject(
        c.arena(),
        commit,
    ) catch return null) orelse return null;
    const parsed = issuez.backend.object.Commit.parse(c.arena(), commit.object_format, o.data) catch
        return null;
    return if (parsed.parents.len > 0) parsed.parents[0] else null;
}

/// INVALID_VALUE when two labels of one exclusive scope come together.
fn scopedFailed(c: *Call, slice: []const api.Op, err: ?*?*api.Error) ?Code {
    var problems: Problems = .empty;
    scopeConflicts(c.arena(), c.repo.exclusive_scopes, slice, &problems) catch return rt.oom(err);
    if (problems.items.len == 0) return null;
    return invalid(err, problems.items);
}

// ─── Milestone writes ──────────────────────────────────────────────────

pub fn issuez_milestone_create(
    repo: ?*api.Repo,
    op_ptr: ?[*]const api.Op,
    n: usize,
    actor: ?*const api.Actor,
    cancel: ?*api.Cancel,
    out: ?*?*api.Write,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.badArgument(err, "out is NULL");
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    var w: Begun = undefined;
    if (beginWrite(&c, &w, .milestone_create, op_ptr, n, actor, err)) |code| return code;
    defer w.discard();
    const a = c.arena();
    const p = &w.plan;
    const catalog = c.catalog();
    const created = catalog.create(a, .{
        .name = p.milestone.name.?,
        .description = p.milestone.description orelse "",
        .due = p.milestone.due,
        .author = w.author,
        .status = p.milestone.status orelse .open,
    }, .{}) catch |e| return writeFailed(&c, err, e, p, "");
    var changes: std.ArrayList(api.Change) = .empty;
    changes.append(a, .{
        .field = @backingInt(Field.name),
        .key = Str.of("Name"),
        .op = @backingInt(Verb.set),
        .old_value = .{},
        .new_value = Str.of(p.milestone.name.?),
    }) catch {};

    return w.give(o, makeWrite(
        &c,
        w.receipt.?,
        .milestone,
        created.id,
        null,
        created.tip,
        .created,
        changes.items,
        w.who,
    ));
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
    const o = out orelse return rt.badArgument(err, "out is NULL");
    const ident = id.slice();
    if (!uuid_fmt.isCanonical(ident)) return rt.badArgument(err, "not a full milestone UUID");
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    var w: Begun = undefined;
    if (beginWrite(&c, &w, .milestone_update, op_ptr, n, actor, err)) |code| return code;
    defer w.discard();
    const a = c.arena();
    const p = &w.plan;
    const catalog = c.catalog();
    const before = (catalog.find(a, ident) catch |e| return c.fail(err, e)) orelse
        return rt.notFound(err, ident, "no such milestone");
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
        .author = w.author,
        .expect = p.expect orelse before.tip,
    }, .{}) catch |e| return writeFailed(&c, err, e, p, ident);
    var changes: std.ArrayList(api.Change) = .empty;
    const m = p.milestone;
    const old_due = if (before.due) |d| std.fmt.allocPrint(a, "{f}", .{d}) catch "" else "";
    const new_due: ?[]const u8 = if (m.clear_due)
        ""
    else if (m.due) |d|
        std.fmt.allocPrint(a, "{f}", .{d}) catch null
    else
        null;
    if (tip != null) for ([_]struct { Field, []const u8, ?[]const u8 }{
        .{ .name, before.name, m.name },
        .{ .description, before.description, m.description },
        .{ .due_date, old_due, new_due },
        .{ .milestone_status, @tagName(before.status), if (m.status) |s| @tagName(s) else null },
    }) |row| {
        const field, const old, const new = row;
        const value = new orelse continue;
        if (std.mem.eql(u8, old, value)) continue;
        changes.append(a, .{
            .field = @backingInt(field),
            .key = Str.of(field.key()),
            .op = @backingInt(if (value.len == 0) Verb.clear else Verb.set),
            .old_value = Str.of(old),
            .new_value = Str.of(value),
        }) catch {};
    };

    return w.give(o, makeWrite(
        &c,
        w.receipt.?,
        .milestone,
        ident,
        before.tip,
        tip,
        .update,
        changes.items,
        w.who,
    ));
}

comptime {
    _ = WriteObj.freeOpaque;
}

const PreparedObj = struct {
    arena: *std.heap.ArenaAllocator,
    info: api.AttachmentSpec,
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
    const o = out orelse return rt.badArgument(err, "out is NULL");
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const spec = Store.fromRepo(c.engine()).prepare(c.arena(), .{
        .id = if (id.len == 0) null else id.slice(),
        .name = name.slice(),
        .data = data.slice(),
    }) catch |e| return writeFailed(&c, err, e, &.{}, "");
    return rt.give(o, rt.owned(PreparedObj, makePrepared, .{spec}), err);
}

fn makePrepared(a: Allocator, spec: attachment_fmt.Spec) !PreparedObj {
    return .{
        .arena = undefined,
        .info = .{
            .id = try rt.dupeZ(a, spec.id),
            .name = try rt.dupeZ(a, spec.name),
            .media_type = try rt.dupeZ(a, spec.media.mediaType()),
            .sha256 = try rt.dupeZ(a, spec.sha256.slice()),
            .size = spec.size,
        },
    };
}

const PreparedReads = rt.Reads(api.PreparedAttachment, PreparedObj);
pub const issuez_prepared_attachment_info = PreparedReads.ref("info");

pub const issuez_prepared_attachment_free = PreparedReads.free();

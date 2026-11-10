//! Reading issues: `issuez_issue` and its records, lists, queries and
//! resolving user input.
//!
//! An issue handle holds C records built once from the engine's `Issue`,
//! strings NUL-terminated, so accessors are plain field reads.

const std = @import("std");
const stableSort = @import("issuez").sort.stable;
const api = @import("api.zig");
const rt = @import("rt.zig");
const cache_mod = @import("cache.zig");
const repo_mod = @import("repo.zig");
const issuez = @import("issuez");

const Allocator = std.mem.Allocator;
const Code = api.Code;
const Str = api.Str;
const Issue = issuez.model.issue.Issue;
const core_fmt = issuez.format.core;
const view = issuez.view;
const fields_fmt = issuez.format.fields;
const uuid_fmt = issuez.format.uuid;
const authorIdAt = issuez.model.issue.authorIdAt;
const Call = repo_mod.Call;
const RepoObj = repo_mod.RepoObj;

// ─── The issue record ──────────────────────────────────────────────────

/// A reaction with its users, behind the public part.
pub const ReactionObj = extern struct {
    public: api.Reaction,
    target: api.Oid,
    has_target: bool,
    users: ?[*]const api.Person,
};

/// An entry with its changes, behind the public part.
pub const EntryObj = extern struct {
    public: api.Entry,
    changes: ?[*]const api.Change,
};

/// A comment with its attachments, behind the public part.
pub const CommentObj = extern struct {
    public: api.Comment,
    attachment_ids: ?[*]const Str,
};

const ExtraField = struct { key: Str, value: Str };

pub const IssueObj = struct {
    /// Set when the issue is a handle of its own; null inside a list.
    arena: ?*std.heap.ArenaAllocator = null,
    info: api.IssueInfo,
    labels: []const Str,
    assignees: []const api.Person,
    blockers: []const Str,
    extra: []const ExtraField,
    problems: *rt.ProblemList,
    comments: []const CommentObj,
    /// Per comment, in the same order: every version.
    comment_histories: []const []const api.Revision,
    description_history: []const api.Revision,
    timeline: []const EntryObj,
    reactions: []const ReactionObj,
    /// Present ones, then removed ones.
    attachments: []const api.Attachment,
};

/// Trailers this library interprets; the rest are extras.
const known_keys = [_][]const u8{
    "State",            "Title",          "Labels",           "Assignee",
    "Priority",         "Milestone",      "Fixed-By",         "Release",
    "Reason",           "X-Milestone-Id", "X-Milestone-Mode", "X-Parent",
    "X-Blocked-By",     "X-Start-Date",   "X-Due-Date",       "X-Estimate-Minutes",
    "X-Workflow-State", "X-Deleted",      "X-Attachment",     "X-Attachment-Removed",
    "X-Event",          "X-Comment",      "Format-Version",   "X-Number",
    "X-Locked",         "X-Lock-Reason",  "X-Ref",            "Provider-Comment-ID",
    "Exported-Commit",
};

fn isKnown(key: []const u8) bool {
    for (known_keys) |k| if (std.ascii.eqlIgnoreCase(k, key)) return true;
    return false;
}

/// Settings a record depends on.
pub const Context = struct {
    done_states: []const []const u8,
    workflow_states: []const []const u8,

    pub fn of(r: *const RepoObj) Context {
        return .{
            .done_states = r.settings.done_states,
            .workflow_states = r.settings.workflow_states,
        };
    }
};

pub fn workflowOf(issue: Issue, ctx: Context) ?[]const u8 {
    if (issue.state.isDone(ctx.done_states)) return null;
    if (issue.workflow) |w| return w;
    return if (ctx.workflow_states.len > 0) ctx.workflow_states[0] else null;
}

fn priorityOf(issue: Issue) api.Priority {
    return if (issue.priority) |p| rt.mirrored(api.Priority, p) else .unknown;
}

pub fn numberOf(issue: Issue) ?u64 {
    return issue.number;
}

pub fn build(a: Allocator, issue: Issue, ctx: Context) Allocator.Error!IssueObj {
    const author = try rt.newPerson(a, issue.author, issue.author_id);
    const created: api.Time = .{
        .unix_seconds = issue.created,
        .tz_offset_minutes = issue.author.tz_offset_minutes,
    };
    const state: api.State = switch (issue.state) {
        .open => .open,
        .closed => .closed,
        .other => |t| if (std.mem.eql(u8, t, "open")) .open else .other,
    };

    const assignees = try a.alloc(api.Person, issue.assignees.len);
    for (issue.assignees, assignees) |as, *o| o.* = .{
        .email = try rt.dupeZ(a, as.email),
        .user_id = try rt.optZ(a, as.uuid),
    };
    var extra: std.ArrayList(ExtraField) = .empty;
    for (issue.fields) |f| {
        if (isKnown(f.key)) continue;
        try extra.append(a, .{ .key = try rt.dupeZ(a, f.key), .value = try rt.dupeZ(a, f.value) });
    }

    var problems: rt.Problems = .empty;
    for (issue.conflicts) |c| try problems.append(a, .{
        .kind = .conflict,
        .key = try std.fmt.allocPrint(a, "{f}", .{c.target}),
        .value = c.value,
        .message = try std.fmt.allocPrint(
            a,
            "clones disagree; kept {s}, lost {s}",
            .{ c.value, c.lost },
        ),
    });
    for (issue.invalid_fields) |f| try problems.append(a, .{
        .kind = .invalid_stored_value,
        .key = f.key,
        .value = f.value,
        .message = "a stored value doesn't parse and is ignored",
    });
    for (issue.event_problems) |e| try problems.append(a, .{
        .kind = if (e.kind == .dangling) .pending_event else .invalid_stored_value,
        .value = e.target orelse "",
        .message = if (e.kind == .dangling)
            "an event waits for its comment"
        else
            "an event can't apply",
    });

    // Comments with their versions, then the timeline from the steps.
    var comments: std.ArrayList(CommentObj) = .empty;
    var histories: std.ArrayList([]const api.Revision) = .empty;
    var comment_of: std.ArrayList(?usize) = .empty;
    const people = try a.alloc(api.Person, issue.comments.len);
    const closure = view.closure(issue, ctx.done_states);
    for (issue.comments, people) |c, *person| {
        person.* = try rt.personOf(a, c.author, authorIdAt(issue.author_ids, c.oid));
        const at = rt.timeOf(c.author);
        if (c.kind != .comment or c.is_merge) {
            try comment_of.append(a, null);
            continue;
        }
        const ids = try rt.strs(a, c.attachments);
        const body = try std.mem.join(a, "\n", c.body);
        const full = if (body.len == 0)
            c.subject
        else
            try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ c.subject, body });
        try comment_of.append(a, comments.items.len);
        try comments.append(a, .{ .attachment_ids = ids.ptr, .public = .{
            .id = rt.oidOf(c.oid),
            .author = person,
            .created = at,
            .updated = if (c.history.len > 0)
                rt.timeOf(c.history[c.history.len - 1].author)
            else
                at,
            .text = try rt.dupeZ(a, full),
            .edited = c.edited,
            .deleted = c.deleted,
            .attachment_count = ids.len,
            .original_author = try rt.optZ(a, c.original_author),
            .original_id = try rt.optZ(a, c.original_id),
            .purged = c.purged,
        } });
        try histories.append(a, try revisionsOf(a, c.history, issue.author_ids));
    }
    var timeline: std.ArrayList(EntryObj) = .empty;
    var cx: ChangeContext = .of(issue, ctx.done_states);
    const created_changes = try changesOf(a, issue.created_changes, &cx);
    try timeline.append(a, .{
        .public = .{
            .kind = @backingInt(api.EntryKind.created),
            .commit = rt.oidOf(issue.root),
            .author = author,
            .at = created,
            .comment = null,
            .change_count = created_changes.len,
            .is_new = true,
        },
        .changes = created_changes.ptr,
    });
    for (issue.steps) |step| {
        const person = try rt.newPerson(a, step.author, authorIdAt(issue.author_ids, step.oid));
        var entry: api.Entry = .{
            .kind = 0,
            .commit = rt.oidOf(step.oid),
            .author = person,
            .at = rt.timeOf(step.author),
            .comment = null,
            .change_count = 0,
            .is_new = true,
        };
        var changes: []const api.Change = &.{};
        switch (step.what) {
            .comment => |k| {
                const c = issue.comments[k];
                changes = try changesOf(a, c.changes, &cx);
                const kind: api.EntryKind = if (c.is_merge)
                    .merge
                else if (c.kind == .comment) .comment else .update;
                entry.kind = @backingInt(kind);
                if (comment_of.items[k]) |ci| entry.comment = &comments.items[ci].public;
            },
            .event => |e| {
                entry.kind = @backingInt(rt.mirrored(api.EntryKind, e.kind));
                if (e.target) |t| for (comments.items) |*c| {
                    const oid = rt.oidOf(t);
                    if (rt.oidEql(&c.public.id, &oid)) entry.comment = &c.public;
                };
            },
        }
        entry.change_count = changes.len;
        try timeline.append(a, .{ .public = entry, .changes = changes.ptr });
    }
    const description = try rt.dupeZ(a, issue.description);
    const reactions = try a.alloc(ReactionObj, issue.reactions.len);
    for (issue.reactions, reactions) |rx, *o| {
        const users = try a.alloc(api.Person, rx.users.len);
        for (
            rx.users,
            users,
        ) |u, *p| p.* = .{ .name = try rt.dupeZ(a, u.name), .email = try rt.dupeZ(a, u.email) };
        o.* = .{
            .public = .{ .emoji = try rt.dupeZ(a, rx.emoji), .user_count = users.len },
            .target = if (rx.target) |t| rt.oidOf(t) else .{},
            .has_target = rx.target != null,
            .users = users.ptr,
        };
    }

    const attachments = try a.alloc(
        api.Attachment,
        issue.attachments.len + issue.removed_attachments.len,
    );
    for (attachments, 0..) |*o, k| {
        const removed = k >= issue.attachments.len;
        const x = if (removed)
            issue.removed_attachments[k - issue.attachments.len]
        else
            issue.attachments[k];
        const by = try rt.newPerson(a, x.added_by, authorIdAt(issue.author_ids, x.added_in));
        const owner = view.ownerOf(issue, x.added_in);
        o.* = .{
            .comment = if (owner.comment) |cm| rt.oidOf(cm) else .{},
            .at = rt.timeOf(owner.at),
            .id = try rt.dupeZ(a, x.id),
            .media_type = Str.of(x.media.mediaType()),
            .size = x.size,
            .sha256 = try rt.dupeZ(a, x.sha256.slice()),
            .name = try rt.dupeZ(a, x.name),
            .added_in = rt.oidOf(x.added_in),
            .added_by = by,
            .removed = removed,
        };
    }

    return .{
        .info = .{
            .id = try rt.dupeZ(a, issue.id),
            .tip = rt.oidOf(issue.tip),
            .has_number = issue.number != null,
            .number = numberOf(issue) orelse 0,
            .format_version = try rt.optZ(a, issue.format_version),
            .commit_count = @intCast(issue.commit_count),
            .title = try rt.dupeZ(a, issue.title),
            .description = description,
            .author = author,
            .created = created,
            .updated = .{
                .unix_seconds = issue.updated,
                .tz_offset_minutes = issue.updated_tz_offset_minutes,
            },
            .state = @backingInt(state),
            .state_name = try rt.dupeZ(a, issue.state.text()),
            .is_done = issue.state.isDone(ctx.done_states),
            .workflow_state = try rt.optZ(a, workflowOf(issue, ctx)),
            .closed_by = if (closure) |cl| try rt.newPerson(a, cl.at, cl.author_id) else null,
            .closed_at = if (closure) |cl| rt.timeOf(cl.at) else .{},
            .fixed_by = try rt.optZ(a, issue.field("Fixed-By")),
            .release = try rt.optZ(a, issue.field("Release")),
            .reason = try rt.optZ(a, issue.field("Reason")),
            .is_deleted = issue.deleted,
            .is_locked = issue.locked,
            .lock_reason = try rt.optZ(a, issue.lock_reason),
            .priority = @backingInt(priorityOf(issue)),
            .milestone_id = try rt.optZ(a, issue.milestone_id),
            .parent_id = try rt.optZ(a, issue.parent),
            .start_date = if (issue.start_date) |d| rt.dateOf(d) else .{},
            .due_date = if (issue.due_date) |d| rt.dateOf(d) else .{},
            .has_estimate_minutes = issue.estimate_minutes != null,
            .estimate_minutes = issue.estimate_minutes orelse 0,
            .ref = try rt.optZ(a, issue.ref),
            .original_author = try rt.optZ(a, issue.original_author),
            .original_id = try rt.optZ(a, issue.original_id),
            .rewritten = false,
        },
        .attachments = attachments,
        .labels = try rt.strs(a, issue.labels),
        .assignees = assignees,
        .blockers = try rt.strs(a, issue.blocked_by),
        .extra = extra.items,
        .problems = try rt.borrowedProblems(a, problems.items),
        .comments = comments.items,
        .comment_histories = histories.items,
        .description_history = try revisionsOf(a, issue.description_history, issue.author_ids),
        .timeline = timeline.items,
        .reactions = reactions,
    };
}

/// The API field a trailer key stands for.
pub fn fieldOfKey(key: []const u8) api.Field {
    inline for (@typeInfo(api.Field).@"enum".field_values) |v| {
        const field: api.Field = @fromBackingInt(@intCast(v));
        const k = field.key();
        if (k.len > 0 and std.ascii.eqlIgnoreCase(k, key)) return field;
    }
    if (std.ascii.eqlIgnoreCase(key, "X-Assignees")) return .assignees;
    if (std.ascii.eqlIgnoreCase(
        key,
        "Milestone",
    ) or std.ascii.eqlIgnoreCase(key, "X-Milestone-Mode"))
        return .milestone;
    return .extra;
}

pub const ChangeContext = view.ChangeContext;

/// The view's per-field changes as the API's.
pub fn changesOf(
    a: Allocator,
    list: []const issuez.model.issue.Change,
    cx: *ChangeContext,
) Allocator.Error![]const api.Change {
    const typed = try view.changes(a, list, cx);
    const out = try a.alloc(api.Change, typed.len);
    for (typed, out) |c, *o| o.* = .{
        .field = @backingInt(rt.mirrored(api.Field, c.field)),
        .key = try rt.dupeZ(a, c.key),
        .op = @backingInt(rt.mirrored(api.Verb, c.op)),
        .old_value = try rt.optZ(a, c.old),
        .new_value = try rt.optZ(a, c.new),
        .old_person = try personOfAssignee(a, c.old_person),
        .new_person = try personOfAssignee(a, c.new_person),
        .old_date = if (c.old_date) |d| rt.dateOf(d) else .{},
        .new_date = if (c.new_date) |d| rt.dateOf(d) else .{},
        .old_done = c.old_done,
        .new_done = c.new_done,
        .reason = if (c.field == .locked) try rt.optZ(a, c.reason) else .{},
    };
    return out;
}

fn personOfAssignee(
    a: Allocator,
    value: ?issuez.format.fields.Assignee,
) Allocator.Error!?*const api.Person {
    const parsed = value orelse return null;
    const p = try a.create(api.Person);
    p.* = .{ .email = try rt.dupeZ(a, parsed.email), .user_id = try rt.optZ(a, parsed.uuid) };
    return p;
}

fn revisionsOf(
    a: Allocator,
    list: []const issuez.model.issue.Revision,
    author_ids: []const issuez.model.issue.AuthorId,
) Allocator.Error![]const api.Revision {
    const out = try a.alloc(api.Revision, list.len);
    for (list, out) |r, *o| {
        o.* = .{
            .commit = rt.oidOf(r.oid),
            .author = try rt.newPerson(a, r.author, authorIdAt(author_ids, r.oid)),
            .at = rt.timeOf(r.author),
            .kind = @backingInt(rt.mirrored(api.RevisionKind, r.kind)),
            .text = try rt.dupeZ(a, r.text),
        };
    }
    return out;
}

/// An issue handle of its own.
pub fn ownedIssue(issue: Issue, ctx: Context) Allocator.Error!*IssueObj {
    return rt.owned(IssueObj, build, .{ issue, ctx });
}

fn get(i: ?*const api.Issue) ?*IssueObj {
    return rt.obj(IssueObj, i);
}

// ─── Accessors ─────────────────────────────────────────────────────────

pub fn issuez_issue_free(issue: ?*api.Issue) callconv(.c) void {
    const o = get(issue) orelse return;
    if (o.arena) |a| rt.freeArena(a);
}

const IssueReads = rt.Reads(api.Issue, IssueObj);
pub const issuez_issue_info_of = IssueReads.ref("info");
pub const issuez_issue_label_count = IssueReads.count("labels");
pub const issuez_issue_label_at = IssueReads.at("labels");
pub const issuez_issue_assignee_count = IssueReads.count("assignees");
pub const issuez_issue_assignee_at = IssueReads.refAt("assignees");
pub const issuez_issue_blocker_count = IssueReads.count("blockers");
pub const issuez_issue_blocker_at = IssueReads.at("blockers");
pub const issuez_issue_extra_count = IssueReads.count("extra");
pub fn issuez_issue_extra_at(
    i: ?*const api.Issue,
    k: usize,
    key: ?*Str,
    value: ?*Str,
) callconv(.c) void {
    // Out of range or NULL: empty, never what the caller had there.
    if (key) |p| p.* = .{};
    if (value) |p| p.* = .{};
    const o = get(i) orelse return;
    if (k >= o.extra.len) return;
    if (key) |p| p.* = o.extra[k].key;
    if (value) |p| p.* = o.extra[k].value;
}
pub fn issuez_issue_problems(i: ?*const api.Issue) callconv(.c) ?*const api.Problems {
    const o = get(i) orelse return null;
    return @ptrCast(o.problems);
}
fn reactionIsOn(rx: *const ReactionObj, comment: ?*const api.Oid) bool {
    return if (comment) |c| rx.has_target and rt.oidEql(&rx.target, c) else !rx.has_target;
}

pub fn issuez_issue_reaction_count(
    i: ?*const api.Issue,
    comment: ?*const api.Oid,
) callconv(.c) usize {
    const o = get(i) orelse return 0;
    var n: usize = 0;
    for (o.reactions) |*rx| {
        if (reactionIsOn(rx, comment)) n += 1;
    }
    return n;
}

pub fn issuez_issue_reaction_at(
    i: ?*const api.Issue,
    comment: ?*const api.Oid,
    k: usize,
) callconv(.c) ?*const api.Reaction {
    const o = get(i) orelse return null;
    var n: usize = 0;
    for (o.reactions) |*rx| {
        if (!reactionIsOn(rx, comment)) continue;
        if (n == k) return &rx.public;
        n += 1;
    }
    return null;
}

pub fn issuez_reaction_user_at(r: ?*const api.Reaction, k: usize) callconv(.c) ?*const api.Person {
    const rx: *const ReactionObj = @ptrCast(@alignCast(r orelse return null));
    if (k >= rx.public.user_count) return null;
    return &rx.users.?[k];
}

pub const issuez_issue_comment_count = IssueReads.count("comments");
pub const issuez_issue_comment_at = IssueReads.publicAt("comments");
pub fn issuez_comment_attachment_at(cm: ?*const api.Comment, k: usize) callconv(.c) Str {
    const p = cm orelse return .{};
    const obj: *const CommentObj = @fieldParentPtr("public", p);
    return if (k < p.attachment_count) obj.attachment_ids.?[k] else .{};
}

pub const issuez_issue_attachment_count = IssueReads.count("attachments");
pub const issuez_issue_attachment_at = IssueReads.refAt("attachments");
pub const issuez_issue_timeline_count = IssueReads.count("timeline");
pub const issuez_issue_timeline_at = IssueReads.publicAt("timeline");
pub fn issuez_entry_change_at(e: ?*const api.Entry, k: usize) callconv(.c) ?*const api.Change {
    const entry: *const EntryObj = @ptrCast(@alignCast(e orelse return null));
    if (k >= entry.public.change_count) return null;
    return &entry.changes.?[k];
}
fn historyOf(o: *const IssueObj, comment: ?*const api.Oid) []const api.Revision {
    const id = comment orelse return o.description_history;
    for (o.comments, o.comment_histories) |c, h| {
        if (rt.oidEql(&c.public.id, id)) return h;
    }
    return &.{};
}

pub fn issuez_issue_history_count(
    i: ?*const api.Issue,
    comment: ?*const api.Oid,
) callconv(.c) usize {
    const o = get(i) orelse return 0;
    return historyOf(o, comment).len;
}

pub fn issuez_issue_history_at(
    i: ?*const api.Issue,
    comment: ?*const api.Oid,
    k: usize,
) callconv(.c) ?*const api.Revision {
    const o = get(i) orelse return null;
    const h = historyOf(o, comment);
    return if (k < h.len) &h[k] else null;
}

// ─── Loading ───────────────────────────────────────────────────────────

fn isDamaged(e: anyerror) bool {
    return switch (e) {
        error.CorruptIssue, error.HistoryTooLong, error.MissingParent, error.NoRoot => true,
        else => false,
    };
}

pub fn issuez_issue_load(
    repo: ?*api.Repo,
    id: Str,
    cancel: ?*api.Cancel,
    out: ?*?*api.Issue,
    err: ?*?*api.Error,
) callconv(.c) Code {
    return issuez_issue_load_since(repo, id, null, cancel, out, err);
}

pub fn issuez_issue_load_at(
    repo: ?*api.Repo,
    id: Str,
    tip: ?*const api.Oid,
    since: ?*const api.Oid,
    cancel: ?*api.Cancel,
    out: ?*?*api.Issue,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.badArgument(err, "out is NULL");
    const t = rt.oidFrom((tip orelse
        return rt.badArgument(err, "tip is NULL")).*) orelse
        return rt.badArgument(err, "tip is invalid");
    if (!uuid_fmt.isCanonical(id.slice())) return rt.badArgument(err, "not a full issue UUID");
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    if (t.object_format != c.session.backend.objectFormat())
        return rt.badArgument(err, "tip uses another object format");
    const name = issuez.engine.refFor(
        c.arena(),
        issuez.engine.issue_ref_prefix,
        id.slice(),
    ) catch |e| return c.fail(err, e);
    const found = c.engine().load(c.arena(), .{ .name = name, .tip = t }) catch |e|
        return c.fail(err, e);
    const obj = ownedIssue(found, .of(c.repo)) catch |e| return rt.failError(err, e, .{});
    if (since) |s| markNew(&c, obj, s.*) catch |e| {
        issuez_issue_free(@ptrCast(obj));
        return c.fail(err, e);
    };
    o.* = @ptrCast(obj);
    return .ok;
}

pub fn issuez_issue_load_since(
    repo: ?*api.Repo,
    id: Str,
    since: ?*const api.Oid,
    cancel: ?*api.Cancel,
    out: ?*?*api.Issue,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.badArgument(err, "out is NULL");
    if (!uuid_fmt.isCanonical(id.slice())) return rt.badArgument(err, "not a full issue UUID");
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const issue = loadOne(&c, id.slice()) catch |e| return c.fail(err, e);
    const found = issue orelse return rt.notFound(err, id.slice(), "no such issue");
    const obj = ownedIssue(found, .of(c.repo)) catch |e| return rt.failError(err, e, .{});
    if (since) |s| markNew(&c, obj, s.*) catch |e| {
        issuez_issue_free(@ptrCast(obj));
        return c.fail(err, e);
    };
    o.* = @ptrCast(obj);
    return .ok;
}

/// Marks the entries whose commits since reaches as not new, or none new
/// when since isn't in the history.
fn markNew(c: *Call, obj: *IssueObj, since: api.Oid) !void {
    const in_history = for (obj.timeline) |e| {
        if (rt.oidEql(&e.public.commit, &since)) break true;
    } else false;
    const entries: []EntryObj = @constCast(obj.timeline);
    if (!in_history) {
        obj.info.rewritten = true;
        for (entries) |*e| e.public.is_new = false;
        return;
    }
    const a = c.arena();
    const known = try c.engine().loadCommits(a, rt.oidFrom(since).?);
    var seen: std.AutoHashMapUnmanaged([32]u8, void) = .empty;
    for (known) |k| try seen.put(a, rt.oidOf(k.oid).bytes, {});
    for (entries) |*e| e.public.is_new = !seen.contains(e.public.commit.bytes);
}

fn loadOne(c: *Call, id: []const u8) !?Issue {
    const a = c.arena();
    const name = try c.issueRef(id);
    const tip = (try c.session.backend.resolveRef(name)) orelse return null;
    return try c.engine().load(a, .{ .name = name, .tip = tip });
}

pub const ListObj = struct {
    arena: *std.heap.ArenaAllocator,
    issues: []const IssueObj,
    skipped: []const Str,
    next: Str = .{},
    /// Cache entries the issues were built from, released with the list.
    held: []const *cache_mod.Entry = &.{},
};

/// Everything the list needs memory for; the caller retains `held` once
/// the list is made, so a failure here holds nothing.
fn makeList(
    a: Allocator,
    issues: []const Issue,
    skipped: []const []const u8,
    next: ?usize,
    held: []const *cache_mod.Entry,
    ctx: Context,
) !ListObj {
    const objs = try a.alloc(IssueObj, issues.len);
    for (issues, objs) |i, *o| o.* = try build(a, i, ctx);
    return .{
        .arena = undefined,
        .issues = objs,
        .skipped = try rt.strs(a, skipped),
        .next = if (next) |n| try rt.dupeZ(a, try std.fmt.allocPrint(a, "o:{d}", .{n})) else .{},
        .held = try a.dupe(*cache_mod.Entry, held),
    };
}

/// Every issue that loads; the damaged ones by ID.
/// Through the repo's cache: only issues whose tip changed are loaded.
pub fn loadEvery(c: *Call, skipped: *std.ArrayList([]const u8)) ![]Issue {
    const a = c.arena();
    const engine = c.engine();
    const refs = try engine.refs(a);
    if (refs.len > engine.limits.max_issues) return error.TooManyIssues;
    return c.repo.cache.loadAll(a, engine, refs, &c.held, skipped, isDamaged);
}

const ListReads = rt.Reads(api.IssueList, ListObj);
pub const issuez_issue_list_len = ListReads.count("issues");
pub fn issuez_issue_list_at(l: ?*const api.IssueList, i: usize) callconv(.c) ?*const api.Issue {
    const list = rt.obj(ListObj, l) orelse return null;
    return if (i < list.issues.len) @ptrCast(&list.issues[i]) else null;
}
pub const issuez_issue_list_next_cursor = ListReads.field("next");
pub const issuez_issue_list_skipped_count = ListReads.count("skipped");
pub const issuez_issue_list_skipped_at = ListReads.at("skipped");
pub fn issuez_issue_list_free(l: ?*api.IssueList) callconv(.c) void {
    const list = rt.obj(ListObj, l) orelse return;
    for (list.held) |e| e.release();
    rt.freeArena(list.arena);
}

// ─── Query ─────────────────────────────────────────────────────────────

const Query = struct {
    done: ?bool = false,
    deleted: ?bool = false,
    states: std.ArrayList([]const u8) = .empty,
    workflow: std.ArrayList([]const u8) = .empty,
    labels: std.ArrayList([]const u8) = .empty,
    not_labels: std.ArrayList([]const u8) = .empty,
    no_labels: bool = false,
    assignees: std.ArrayList([]const u8) = .empty,
    authors: std.ArrayList([]const u8) = .empty,
    priorities: std.ArrayList(api.Priority) = .empty,
    milestones: std.ArrayList([]const u8) = .empty,
    parent: ?[]const u8 = null,
    blocked: ?bool = null,
    updated_after: i64 = 0,
    updated_before: i64 = 0,
    text: ?[]const u8 = null,
    ignore_case: bool = false,
    order: api.Sort = .created,
    ascending: bool = false,
    limit: usize = 100,
    offset: usize = 0,
};

fn tri(n: i64) ?bool {
    return switch (n) {
        0 => false,
        1 => true,
        else => null,
    };
}

pub fn parseQuery(a: Allocator, ops: []const api.Op, problems: *rt.Problems) !Query {
    var q: Query = .{};
    for (ops, 0..) |op, i| {
        const check: rt.OpCheck = .at(a, problems, i);
        if (try check.reserved(op)) continue;
        const s = op.str.slice();
        switch (@as(api.Opt, @fromBackingInt(@intCast(op.target)))) {
            .q_done => q.done = tri(op.num),
            .q_deleted => q.deleted = tri(op.num),
            .q_state => try q.states.append(a, s),
            .q_workflow_state => try q.workflow.append(a, s),
            .q_label => try q.labels.append(a, s),
            .q_not_label => try q.not_labels.append(a, s),
            .q_no_labels => q.no_labels = true,
            .q_assignee => try q.assignees.append(a, s),
            .q_author => try q.authors.append(a, s),
            .q_priority => if (std.math.cast(u32, op.num)) |n| {
                try q.priorities.append(a, @fromBackingInt(@intCast(n)));
            } else {
                try check.add(.bad_format, "unknown priority");
            },
            .q_milestone => try q.milestones.append(a, s),
            .q_parent => q.parent = s,
            .q_blocked => q.blocked = op.num != 0,
            .q_updated => {
                q.updated_after = op.num;
                q.updated_before = op.num2;
            },
            .q_text => {
                q.text = s;
                q.ignore_case = op.num != 0;
            },
            .q_order => {
                q.order = @fromBackingInt(@intCast(std.math.cast(u32, op.num) orelse 0));
                q.ascending = op.num2 != 0;
                switch (q.order) {
                    .created, .updated, .number, .priority, .due_date, .comments, .state => {},
                    else => try check.add(.bad_format, "unknown sort"),
                }
            },
            .q_limit => if (op.num < 1) {
                try check.add(.bad_format, "the limit must be positive");
            } else {
                q.limit = @intCast(op.num);
            },
            .q_after => q.offset = parseCursor(s) orelse {
                try check.add(.bad_format, "not a cursor of this query");
                continue;
            },
            else => try check.add(.unknown_target, "not a query option"),
        }
    }
    return q;
}

/// Cursors are positions in the sorted result: stable while nothing
/// changes, like most offset paging.
fn parseCursor(s: []const u8) ?usize {
    if (!std.mem.startsWith(u8, s, "o:")) return null;
    return std.fmt.parseInt(usize, s[2..], 10) catch null;
}

fn containsText(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn matches(
    q: *const Query,
    issue: Issue,
    ctx: Context,
    proj: ?*const issuez.projection.Projection,
    a: Allocator,
) !bool {
    if (q.deleted) |d| if (issue.deleted != d) return false;
    if (q.done) |d| if (issue.state.isDone(ctx.done_states) != d) return false;
    if (q.states.items.len > 0 and !containsText(q.states.items, issue.state.text())) return false;
    if (q.workflow.items.len > 0) {
        const w = workflowOf(issue, ctx) orelse return false;
        if (!containsText(q.workflow.items, w)) return false;
    }
    for (q.labels.items) |l| if (!containsText(issue.labels, l)) return false;
    for (q.not_labels.items) |l| if (containsText(issue.labels, l)) return false;
    if (q.no_labels and issue.labels.len > 0) return false;
    if (q.assignees.items.len > 0) {
        var hit = false;
        for (q.assignees.items) |who| {
            if (who.len == 0 and issue.assignees.len == 0) hit = true;
            for (issue.assignees) |as| {
                if (std.mem.eql(u8, as.email, who)) hit = true;
                if (as.uuid) |u| if (std.mem.eql(u8, u, who)) {
                    hit = true;
                };
            }
        }
        if (!hit) return false;
    }
    if (q.authors.items.len > 0 and !containsText(
        q.authors.items,
        issue.author.email,
    )) return false;
    if (q.priorities.items.len > 0) {
        const p = priorityOf(issue);
        if (std.mem.indexOfScalar(api.Priority, q.priorities.items, p) == null) return false;
    }
    if (q.parent) |p| if (!std.mem.eql(u8, issue.parent orelse "", p)) return false;
    if (q.updated_after != 0 and issue.updated <= q.updated_after) return false;
    if (q.updated_before != 0 and issue.updated >= q.updated_before) return false;
    if (proj) |p| {
        const at = p.find(issue.id) orelse return false;
        if (q.milestones.items.len > 0) {
            const m = p.milestone[at] orelse "";
            if (!containsText(q.milestones.items, m)) return false;
        }
        if (q.blocked) |b| if (p.activelyBlocked(at) != b) return false;
    }
    if (q.text) |t| {
        const hits = try issuez.query.searchLines(a, issue, t, .{ .ignore_case = q.ignore_case });
        if (hits.len == 0) return false;
    }
    return true;
}

fn priorityRank(issue: Issue) i64 {
    const p = issue.priority orelse return 0;
    return @as(i64, p.rank()) + 1;
}

fn sortKey(issue: Issue, order: api.Sort, ctx: Context) i64 {
    return switch (order) {
        .updated => issue.updated,
        .number => @intCast(numberOf(issue) orelse 0),
        .priority => priorityRank(issue),
        .due_date => if (issue.due_date) |d|
            @as(i64, d.year) * 10000 + @as(i64, d.month) * 100 + d.day
        else
            std.math.maxInt(i64),
        .comments => @intCast(issue.comments.len),
        .state => if (issue.state.isDone(ctx.done_states)) 1 else 0,
        else => issue.created,
    };
}

const SortCtx = struct { order: api.Sort, ascending: bool, ctx: Context };

fn lessThan(s: SortCtx, x: Issue, y: Issue) bool {
    const kx = sortKey(x, s.order, s.ctx);
    const ky = sortKey(y, s.order, s.ctx);
    // Newest, highest, most first unless ascending; due dates soonest
    // first, and state open first, unless ascending says the opposite.
    const natural_ascending = s.order == .due_date or s.order == .state;
    const asc = if (natural_ascending) !s.ascending else s.ascending;
    if (kx != ky) return if (asc) kx < ky else kx > ky;
    return std.mem.lessThan(u8, x.id, y.id);
}

fn runQuery(c: *Call, ops: []const api.Op, err: ?*?*api.Error) !union(enum) {
    failed: Code,
    list: struct { matched: []Issue, skipped: []const []const u8, next: ?usize },
} {
    const a = c.arena();
    var problems: rt.Problems = .empty;
    const q = try parseQuery(a, ops, &problems);
    if (problems.items.len > 0) {
        return .{ .failed = rt.badOps(err, problems.items, "invalid query") };
    }
    var skipped: std.ArrayList([]const u8) = .empty;
    const all = try loadEvery(c, &skipped);
    const ctx: Context = .of(c.repo);
    var proj: ?issuez.projection.Projection = null;
    if (q.milestones.items.len > 0 or q.blocked != null) {
        proj = try c.catalog().project(a, all, .{});
    }
    var matched: std.ArrayList(Issue) = .empty;
    for (all) |issue| {
        if (try matches(
            &q,
            issue,
            ctx,
            if (proj) |*p| p else null,
            a,
        )) try matched.append(a, issue);
    }
    stableSort(
        Issue,
        matched.items,
        SortCtx{ .order = q.order, .ascending = q.ascending, .ctx = ctx },
        lessThan,
    );
    const start = @min(q.offset, matched.items.len);
    const end = @min(start + q.limit, matched.items.len);
    return .{ .list = .{
        .matched = matched.items[start..end],
        .skipped = skipped.items,
        .next = if (end < matched.items.len) end else null,
    } };
}

pub fn issuez_query_run(
    repo: ?*api.Repo,
    ops: ?[*]const api.Op,
    n: usize,
    cancel: ?*api.Cancel,
    out: ?*?*api.IssueList,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.badArgument(err, "out is NULL");
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const result = runQuery(&c, rt.sliceOf(api.Op, ops, n), err) catch |e|
        return c.fail(err, e);
    switch (result) {
        .failed => |code| return code,
        .list => |l| {
            const ctx: Context = .of(c.repo);
            const list = rt.owned(
                ListObj,
                makeList,
                .{ l.matched, l.skipped, l.next, c.held.items, ctx },
            ) catch |e| return rt.failError(err, e, .{});
            for (list.held) |e| e.retain();
            o.* = @ptrCast(list);
            return .ok;
        },
    }
}

// ─── Resolve ───────────────────────────────────────────────────────────

/// Only full UUIDs: a ref named `refs/issues/<anything>` is no issue, and
/// its name may not fit the host's `ISSUEZ_UUID_BUFSIZE` buffer.
fn resolveIds(c: *Call, kind: api.Kind, input: []const u8) ![]const []const u8 {
    const a = c.arena();
    var out: std.ArrayList([]const u8) = .empty;
    switch (kind) {
        .issue => {
            // `#12` goes through the engine's number lookup (the cache).
            switch (try c.engine().resolve(a, input)) {
                .none => {},
                .one => |r| try appendId(a, &out, r.id()),
                .many => |rs| for (rs) |r| try appendId(a, &out, r.id()),
            }
        },
        .milestone => switch (try c.catalog().resolve(a, input)) {
            .none, .retired_name => {},
            .one => |m| try appendId(a, &out, m.id),
            .many => |ms| for (ms) |m| try appendId(a, &out, m.id),
        },
        else => return error.UnknownKind,
    }
    return out.items;
}

fn appendId(a: std.mem.Allocator, out: *std.ArrayList([]const u8), id: []const u8) !void {
    if (uuid_fmt.isCanonical(id)) try out.append(a, id);
}

pub fn issuez_resolve_one(
    repo: ?*api.Repo,
    kind: api.Kind,
    input: Str,
    cancel: ?*api.Cancel,
    buf_or_null: ?[*]u8,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const buf = buf_or_null orelse return rt.badArgument(err, "buf is NULL");
    buf[0] = 0;
    if (input.len == 0) return rt.badArgument(err, "input is empty");
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const ids = resolveIds(&c, kind, input.slice()) catch |e| return c.fail(err, e);
    switch (ids.len) {
        0 => return rt.notFound(err, input.slice(), "nothing matches"),
        1 => {
            // A canonical UUID: 36 bytes, the NUL makes 37.
            @memcpy(buf[0..36], ids[0][0..36]);
            buf[36] = 0;
            return .ok;
        },
        else => return rt.failWith(
            err,
            .e_ambiguous,
            .{ .subject = input.slice() },
            "{d} match",
            .{ids.len},
        ),
    }
}

//! An issue as front ends show it, worked out once from the model: who
//! closed it and when, the timeline as entries with their comment and
//! per-field changes (the value before filled in, typed values parsed),
//! and the comment each attachment belongs to. The C API, the JSON and
//! the MCP server read these instead of each walking the model's commits.

const std = @import("std");
const Allocator = std.mem.Allocator;
const issue_model = @import("../model/issue.zig");
const core_fmt = @import("../format/core.zig");
const fields_fmt = @import("../format/fields.zig");
const object = @import("../backend/object.zig");

const Issue = issue_model.Issue;
const Oid = object.Oid;
const Signature = object.Signature;

/// Who closed an issue that is done, and when: the last commit that set a
/// done state. Null for an issue that isn't done, or was created done.
pub const Closure = struct {
    at: Signature,
    author_id: ?[]const u8,
    commit: Oid,
};

pub fn closure(issue: Issue, done_states: []const []const u8) ?Closure {
    if (!issue.state.isDone(done_states)) return null;
    var out: ?Closure = null;
    for (issue.comments) |c| if (c.state_change) |st| {
        out = if (st.isDone(done_states)) .{
            .at = c.author,
            .author_id = issue_model.authorIdAt(issue.author_ids, c.oid),
            .commit = c.oid,
        } else null;
    };
    return out;
}

/// What a field the timeline shows is, whichever trailers said it.
pub const Field = enum {
    title,
    description,
    comment,
    state,
    workflow_state,
    labels,
    assignees,
    priority,
    milestone,
    parent,
    blocked_by,
    start_date,
    due_date,
    estimate,
    number,
    locked,
    lock_reason,
    ref,
    deleted,
    fixed_by,
    release,
    reason,
    attachments,
    reactions,
    name,
    milestone_status,
    /// A host field or another trailer the library doesn't know.
    extra,

    pub fn ofKey(key: []const u8) Field {
        const keys = .{
            .{ "Title", .title },                         .{ "Description", .description },
            .{ "Comment", .comment },                     .{ "State", .state },
            .{ "X-Workflow-State", .workflow_state },     .{ "Labels", .labels },
            .{ "Assignee", .assignees },                  .{ "X-Assignees", .assignees },
            .{ "Priority", .priority },                   .{ "X-Milestone-Id", .milestone },
            .{ "Milestone", .milestone },                 .{ "X-Milestone-Mode", .milestone },
            .{ "X-Parent", .parent },                     .{ "X-Blocked-By", .blocked_by },
            .{ "X-Start-Date", .start_date },             .{ "X-Due-Date", .due_date },
            .{ "X-Estimate-Minutes", .estimate },         .{ "X-Number", .number },
            .{ "X-Locked", .locked },                     .{ "X-Lock-Reason", .lock_reason },
            .{ "X-Ref", .ref },                           .{ "X-Deleted", .deleted },
            .{ "Fixed-By", .fixed_by },                   .{ "Release", .release },
            .{ "Reason", .reason },                       .{ "X-Attachment", .attachments },
            .{ "X-Reaction", .reactions },                .{ "Name", .name },
            .{ "X-Milestone-Status", .milestone_status },
        };
        inline for (keys) |k| if (std.ascii.eqlIgnoreCase(k[0], key)) return k[1];
        return .extra;
    }
};

/// One field change of a timeline entry.
pub const Change = struct {
    field: Field,
    /// The trailer key it came from.
    key: []const u8,
    op: issue_model.Change.Op,
    /// The value before, also where the commit didn't say it (outside the
    /// root): a first `Title` has the root's subject, a first `State`
    /// "open". Null for none.
    old: ?[]const u8,
    /// A cleared title is the root's subject again.
    new: ?[]const u8,
    /// `assignees`: the member, parsed.
    old_person: ?fields_fmt.Assignee = null,
    new_person: ?fields_fmt.Assignee = null,
    /// `start_date`, `due_date`: parsed.
    old_date: ?fields_fmt.Date = null,
    new_date: ?fields_fmt.Date = null,
    /// `state`: whether each is done, by the repository's done states.
    old_done: bool = false,
    new_done: bool = false,
    /// `locked`: the lock's reason as of this commit.
    reason: ?[]const u8 = null,
};

/// What turning one commit's changes into `Change`s needs from the
/// commits before it, in timeline order.
pub const ChangeContext = struct {
    done_states: []const []const u8,
    /// The root's subject, the title until a `Title` sets one.
    root_title: []const u8,
    title: []const u8,
    lock_reason: ?[]const u8 = null,
    /// The root's changes come from nothing: no value before to fill in.
    root: bool = true,

    pub fn of(issue: Issue, done_states: []const []const u8) ChangeContext {
        return .{
            .done_states = done_states,
            .root_title = issue.root_subject,
            .title = issue.root_subject,
        };
    }
};

/// The model's changes, which are per trailer key, as per-field ones.
pub fn changes(
    arena: Allocator,
    list: []const issue_model.Change,
    cx: *ChangeContext,
) Allocator.Error![]const Change {
    // `Assignee` restates a member of `X-Assignees` when both are written.
    const has_set = for (list) |c| {
        if (std.ascii.eqlIgnoreCase(c.key, "X-Assignees")) break true;
    } else false;
    for (list) |c| if (Field.ofKey(c.key) == .lock_reason) {
        cx.lock_reason = c.new;
    };
    var out: std.ArrayList(Change) = .empty;
    for (list) |c| {
        const field = Field.ofKey(c.key);
        if (has_set and field == .assignees and std.ascii.eqlIgnoreCase(c.key, "Assignee"))
            continue;
        var o: Change = .{ .field = field, .key = c.key, .op = c.op, .old = c.old, .new = c.new };
        switch (field) {
            .title => {
                if (c.old == null and !cx.root) o.old = cx.title;
                const now = c.new orelse cx.root_title;
                o.new = now;
                cx.title = now;
            },
            .state => {
                const was = c.old orelse "open";
                if (c.old == null and !cx.root) o.old = was;
                o.old_done = core_fmt.State.parse(was).isDone(cx.done_states);
                o.new_done = core_fmt.State.parse(c.new orelse "open").isDone(cx.done_states);
            },
            .assignees => {
                if (c.old) |v| o.old_person = fields_fmt.Assignee.parse(v);
                if (c.new) |v| o.new_person = fields_fmt.Assignee.parse(v);
            },
            .start_date, .due_date => {
                if (c.old) |v| o.old_date = fields_fmt.Date.parse(v);
                if (c.new) |v| o.new_date = fields_fmt.Date.parse(v);
            },
            .locked => o.reason = cx.lock_reason,
            else => {},
        }
        try out.append(arena, o);
    }
    cx.root = false;
    return out.items;
}

/// One commit of the timeline.
pub const Entry = struct {
    kind: Kind,
    commit: Oid,
    author: Signature,
    author_id: ?[]const u8,
    /// The comment it adds (`comment`) or targets (`comment_*`), as an
    /// index into `Issue.comments`; null otherwise.
    comment: ?usize,
    changes: []const Change,

    pub const Kind = enum {
        created,
        comment,
        update,
        description_edit,
        comment_edit,
        comment_delete,
        comment_restore,
        reaction,
        merge,
    };
};

/// The timeline, root first, in the order of `Issue.steps`.
pub fn entries(
    arena: Allocator,
    issue: Issue,
    done_states: []const []const u8,
) Allocator.Error![]const Entry {
    var cx: ChangeContext = .of(issue, done_states);
    var out: std.ArrayList(Entry) = .empty;
    try out.append(arena, .{
        .kind = .created,
        .commit = issue.root,
        .author = issue.author,
        .author_id = issue.author_id,
        .comment = null,
        .changes = try changes(arena, issue.created_changes, &cx),
    });
    for (issue.steps) |step| {
        var e: Entry = .{
            .kind = .update,
            .commit = step.oid,
            .author = step.author,
            .author_id = issue_model.authorIdAt(issue.author_ids, step.oid),
            .comment = null,
            .changes = &.{},
        };
        switch (step.what) {
            .comment => |k| {
                const c = issue.comments[k];
                e.changes = try changes(arena, c.changes, &cx);
                e.kind = if (c.is_merge) .merge else if (c.kind == .comment) .comment else .update;
                if (!c.is_merge and c.kind == .comment) e.comment = k;
            },
            .event => |ev| {
                e.kind = switch (ev.kind) {
                    .description_edit => .description_edit,
                    .comment_edit => .comment_edit,
                    .comment_delete => .comment_delete,
                    .comment_restore => .comment_restore,
                    .reaction => .reaction,
                };
                if (ev.target) |t| for (issue.comments, 0..) |c, k| {
                    if (c.oid.eql(t)) e.comment = k;
                };
            },
        }
        try out.append(arena, e);
    }
    return out.items;
}

/// The comment an attachment added in `commit` belongs to (its own, or
/// the one a comment edit edits; null: the description's), and when that
/// commit was written.
pub const Owner = struct {
    comment: ?Oid,
    at: Signature,
};

pub fn ownerOf(issue: Issue, commit: Oid) Owner {
    for (issue.steps) |step| {
        if (!step.oid.eql(commit)) continue;
        return switch (step.what) {
            .comment => |k| .{
                .comment = if (issue.comments[k].kind == .comment) commit else null,
                .at = step.author,
            },
            .event => |e| .{
                .comment = if (e.kind == .comment_edit) e.target else null,
                .at = step.author,
            },
        };
    }
    return .{ .comment = null, .at = issue.author };
}

const testing = std.testing;

test "closure, entries, ownerOf" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const GitSim = @import("../backend/GitSim.zig");
    const Repo = @import("repo.zig").Repo(GitSim);
    var world: GitSim.World = .{ .seed = 103, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo.init(&sim);
    const made = try repo.create(arena, .{ .title = "First" }, .{});
    const id = made.id;
    _ = try repo.edit(arena, id, .{ .title = "Second" }, .{});
    _ = try repo.comment(arena, id, .{ .text = "A note" }, .{});
    _ = try repo.setState(arena, id, .{ .state = .{ .other = "wontfix" } }, .{});
    const issue = (try repo.find(arena, id)).?;
    const done = &core_fmt.default_done_states;
    const c = closure(issue, done).?;
    try testing.expect(c.commit.eql(issue.tip));
    const list = try entries(arena, issue, done);
    try testing.expectEqual(@as(usize, 4), list.len);
    try testing.expectEqual(Entry.Kind.created, list[0].kind);
    try testing.expectEqualStrings("First", list[1].changes[0].old.?);
    try testing.expectEqual(Entry.Kind.comment, list[2].kind);
    try testing.expectEqual(@as(?usize, 1), list[2].comment);
    var state: ?Change = null;
    for (list[3].changes) |ch| if (ch.field == .state) {
        state = ch;
    };
    try testing.expect(!state.?.old_done and state.?.new_done);
    try testing.expect(ownerOf(issue, issue.root).comment == null);
}

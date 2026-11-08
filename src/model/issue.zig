//! Reads an issue from its commit DAG.
//!
//! Every field value remembers its latest setters: the commits that set it,
//! none an ancestor of another. Walking the commits parents first, each
//! commit's trailers set fields. A merge keeps the setters of both sides
//! that no setter descends from, so a newer one wins whatever the clocks
//! say. Only concurrent setters fall back to last writer wins (author time,
//! then OID), and that case is reported as a conflict. A missing trailer
//! never clears a field, an empty value does.
//!
//! Set members (`Labels`, `X-Blocked-By`) and attachments each keep their
//! own setters, and a concurrent add and remove resolves to add. No merge
//! base is needed, so criss-cross histories are fine too.

const std = @import("std");
const stableSort = @import("../sort.zig").stable;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const object = @import("../backend/object.zig");
const trailers = @import("../format/trailers.zig");
const labels_fmt = @import("../format/labels.zig");
const fields_fmt = @import("../format/fields.zig");
const uuid_fmt = @import("../format/uuid.zig");
const attachment_fmt = @import("../format/attachment.zig");
const core_fmt = @import("../format/core.zig");
const Oid = object.Oid;
const Signature = object.Signature;

pub const CommitInput = struct {
    oid: Oid,
    tree: ?Oid = null,
    parents: []const Oid,
    author: Signature,
    committer: Signature,
    message: []const u8,
};

pub const Field = struct {
    key: []const u8,
    value: []const u8,
};

pub const Conflict = struct {
    target: Target,
    value: []const u8,
    lost: []const u8,

    pub const Target = union(enum) {
        /// A trailer key, as canonicalized.
        field: []const u8,
        description,
        /// The comment's commit.
        comment: Oid,

        /// `Priority`, `Description`, `Comment 3f9a1c2`.
        pub fn format(t: Target, w: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (t) {
                .field => |k| try w.writeAll(k),
                .description => try w.writeAll("Description"),
                .comment => |oid| {
                    const h = oid.hex();
                    try w.print("Comment {s}", .{h.short()});
                },
            }
        }
    };
};

/// A commit's `X-Author-Id`.
pub const AuthorId = struct { oid: Oid, id: []const u8 };

/// The author UUID of `oid`, one of the issue's commits.
pub fn authorIdAt(author_ids: []const AuthorId, oid: Oid) ?[]const u8 {
    for (author_ids) |a| if (a.oid.eql(oid)) return a.id;
    return null;
}

pub const Comment = struct {
    oid: Oid,
    author: Signature,
    subject: []const u8,
    /// Like upstream's `show`, which keeps a lone trailer paragraph such as
    /// `State: closed`.
    text: []const []const u8,
    /// Without the trailer block, the way git reads trailers. Use this one
    /// to display a comment.
    body: []const []const u8 = &.{},
    /// The `State` this commit wrote, if any.
    state_change: ?core_fmt.State,
    is_merge: bool,
    /// Set by events. `text` and `body` already hold the edited text.
    edited: bool = false,
    deleted: bool = false,
    /// Attachments this commit added that are still present, in trailer
    /// order.
    attachments: []const []const u8 = &.{},
    kind: Kind = .comment,
    /// Every version of the comment, oldest first: the original, then each
    /// edit, delete and restore event that targets it.
    history: []const Revision = &.{},
    /// Where an imported comment came from (`X-Original-Author`,
    /// `X-Original-Id`): its author and ID in the other tracker.
    original_author: ?[]const u8 = null,
    original_id: ?[]const u8 = null,
    /// `X-Purged: true`: a purge took its text, attachments and origin
    /// (format.md §10). Its fields stay.
    purged: bool = false,
    /// What this commit changed in the resolved fields, compared with its
    /// parent; for a merge, with what its parents merge to, so only what
    /// the merge itself resolved.
    changes: []const Change = &.{},

    pub const Kind = enum {
        /// Text someone wrote, possibly with fields or attachments.
        comment,
        /// A commit that only changed fields or the state, merged, or
        /// recorded an export: no text beyond its subject, which the tool
        /// wrote ("Update labels").
        update,
    };
};

pub const Step = struct {
    oid: Oid,
    author: Signature,
    what: union(enum) {
        comment: usize,
        event: struct {
            kind: fields_fmt.Event,
            /// The comment it targets; null for a description edit.
            target: ?Oid,
        },
    },
};

/// Who reacted with one emoji, on the issue (`target` null) or a comment.
pub const Reaction = struct {
    target: ?Oid,
    emoji: []const u8,
    users: []const ReactionUser,
};

pub const ReactionUser = struct {
    email: []const u8,
    /// From the commit that added it.
    name: []const u8,
};

/// One field change of a commit, values as written (`<uuid> <email>`, a
/// label, a date). Sets change by member, attachments by UUID.
pub const Change = struct {
    /// The trailer key: `Labels`, `X-Due-Date`, `X-Attachment`, ...
    key: []const u8,
    op: Op,
    /// Null when the field had no value (set) or for an added member.
    old: ?[]const u8,
    /// Null when cleared or for a removed member.
    new: ?[]const u8,

    pub const Op = enum { set, clear, add, remove };
};

/// One version of the description or of a comment. The current text is the
/// one §4 resolves to, which after concurrent edits needn't be the last.
pub const Revision = struct {
    /// The commit that wrote it: the comment or root itself, or an event.
    oid: Oid,
    author: Signature,
    kind: Kind,
    /// The whole text after it; for delete and restore, the text then.
    text: []const u8,

    pub const Kind = enum { original, edit, delete, restore };
};

/// Read the bytes through `issuez.Attachments`.
pub const Attachment = struct {
    id: []const u8,
    media: attachment_fmt.Media,
    size: u32,
    sha256: attachment_fmt.Sha256,
    name: []const u8,
    /// A comment, or a commit that only attaches.
    added_in: Oid,
    added_by: Signature,
};

/// An attachment trailer that is ignored, reported by `fsck`.
pub const AttachmentProblem = struct {
    oid: Oid,
    kind: Kind,
    value: []const u8,

    pub const Kind = enum {
        malformed,
        /// A different hash, size or media type for an existing UUID.
        /// Attachments are immutable.
        changed_object,

        pub fn text(k: Kind) []const u8 {
            return switch (k) {
                .malformed => "malformed",
                .changed_object => "object-changing",
            };
        }
    };
};

pub const EventProblem = struct {
    oid: Oid,
    kind: Kind,
    target: ?[]const u8 = null,

    pub const Kind = enum {
        /// The target isn't in this history yet. It applies once a sync
        /// brings it in, unless it belongs to another issue.
        dangling,
        /// Unknown or repeated `X-Event`, bad `X-Comment`, or a target that
        /// is the root, a merge or another event.
        invalid,
    };
};

/// References are full UUIDs. Whether their targets exist is up to the
/// projection. Values that don't parse end up in `invalid_fields`.
pub const Extensions = struct {
    assignee: ?fields_fmt.Assignee = null,
    /// Everyone assigned, in order (format.md §3): `X-Assignees`, which a
    /// plain `Assignee` (upstream's edit) sets to that one.
    assignees: []const fields_fmt.Assignee = &.{},
    /// As written.
    assignees_written: []const []const u8 = &.{},
    /// `X-Number`, the issue's number in its host (format.md §3).
    number: ?u64 = null,
    /// `X-Locked`: the host limits who may comment (its policy, not ours).
    locked: bool = false,
    lock_reason: ?[]const u8 = null,
    /// `X-Ref`: the branch or tag the issue is about.
    ref: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    blocked_by: []const []const u8 = &.{},
    /// Every member as written, invalid ones included, in set order.
    blocked_by_written: []const []const u8 = &.{},
    start_date: ?fields_fmt.Date = null,
    due_date: ?fields_fmt.Date = null,
    estimate_minutes: ?u32 = null,
    /// As written. The projection applies the default for open issues.
    workflow: ?[]const u8 = null,
    milestone_id: ?[]const u8 = null,
    milestone_mode: ?fields_fmt.MilestoneMode = null,
    invalid_fields: []const Field = &.{},
};

pub const Issue = struct {
    id: []const u8,
    tip: Oid,
    root: Oid,
    roots: usize,
    title: []const u8,
    title_override: ?[]const u8,
    /// The root's subject: the title until a `Title` sets one.
    root_subject: []const u8 = "",
    description: []const u8,
    /// Every version of the description, oldest first: the root's, then
    /// each `description-edit`.
    description_history: []const Revision = &.{},
    /// The fields the root commit set.
    created_changes: []const Change = &.{},
    /// An imported issue's author and ID in the other tracker, from the
    /// root commit.
    original_author: ?[]const u8 = null,
    original_id: ?[]const u8 = null,
    /// Present reactions, by target, then emoji, in the order they came.
    reactions: []const Reaction = &.{},
    /// Every commit after the root, oldest first, in the order of
    /// `comments`: a comment (an index into `comments`) or an event.
    steps: []const Step = &.{},
    /// `open` when never set.
    state: core_fmt.State,
    labels: []const []const u8,
    // The extension fields (format.md §3), as `Extensions` has them.
    assignee: ?fields_fmt.Assignee = null,
    /// Everyone assigned, in order (format.md §3): `X-Assignees`, which a
    /// plain `Assignee` (upstream's edit) sets to that one.
    assignees: []const fields_fmt.Assignee = &.{},
    /// As written.
    assignees_written: []const []const u8 = &.{},
    /// `X-Number`, the issue's number in its host (format.md §3).
    number: ?u64 = null,
    /// `X-Locked`: the host limits who may comment (its policy, not ours).
    locked: bool = false,
    lock_reason: ?[]const u8 = null,
    /// `X-Ref`: the branch or tag the issue is about.
    ref: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    blocked_by: []const []const u8 = &.{},
    /// Every member as written, invalid ones included, in set order.
    blocked_by_written: []const []const u8 = &.{},
    start_date: ?fields_fmt.Date = null,
    due_date: ?fields_fmt.Date = null,
    estimate_minutes: ?u32 = null,
    /// As written. The projection applies the default for open issues.
    workflow: ?[]const u8 = null,
    milestone_id: ?[]const u8 = null,
    milestone_mode: ?fields_fmt.MilestoneMode = null,
    /// Extension values that don't parse.
    invalid_fields: []const Field = &.{},
    /// `Priority`; null when unset or not one of the four levels (another
    /// tool may write `urgent`: `field("Priority")` has the text).
    priority: ?core_fmt.Priority = null,
    /// The `Milestone` text, as written; `milestone_id` is the catalog link.
    milestone: ?[]const u8 = null,
    deleted: bool = false,
    event_problems: []const EventProblem = &.{},
    /// Oldest first.
    attachments: []const Attachment = &.{},
    /// History still references their bytes, and re-adding the same UUID
    /// brings one back.
    removed_attachments: []const Attachment = &.{},
    attachment_problems: []const AttachmentProblem = &.{},
    /// Every other field with a value, sorted by key. Per-commit trailers
    /// (`per_commit_keys`) are not fields.
    fields: []const Field,
    /// Keys written and then cleared: their last value is empty. Sorted,
    /// `State` and `Format-Version` left out. A merge restates them empty.
    cleared: []const []const u8 = &.{},
    conflicts: []const Conflict,
    author: Signature,
    /// The root author's host UUID (`X-Author-Id`), if it has one.
    author_id: ?[]const u8 = null,
    /// Every commit's author UUID, by commit, for those that have one.
    author_ids: []const AuthorId = &.{},
    created: i64,
    /// The tip's author time.
    updated: i64,
    /// The tip author's offset, since that may not be `author`'s.
    updated_tz_offset_minutes: i16 = 0,
    comments: []const Comment,
    format_version: ?[]const u8,
    commit_count: usize,
    /// Raw messages in `git log` order, for `search`.
    log: []const []const u8,

    /// The extension fields as one value, as the parser has them.
    pub fn extensions(issue: *const Issue) Extensions {
        var x: Extensions = .{};
        inline for (std.meta.fields(Extensions)) |f| @field(x, f.name) = @field(issue, f.name);
        return x;
    }

    /// Sets the extension fields from `x`.
    pub fn setExtensions(issue: *Issue, x: Extensions) void {
        inline for (std.meta.fields(Extensions)) |f| @field(issue, f.name) = @field(x, f.name);
    }

    pub fn field(issue: *const Issue, key: []const u8) ?[]const u8 {
        for (issue.fields) |f| if (std.mem.eql(u8, f.key, key)) return f.value;
        return null;
    }
};

pub const Error = error{
    /// A parent wasn't loaded.
    MissingParent,
    NoRoot,
} || Allocator.Error;

/// A scalar. Like a set member it keeps every latest setter, so that a
/// later change on one branch doesn't hide a concurrent setter on another.
const Cell = struct {
    /// The newest setter's.
    value: []const u8,
    /// None an ancestor of another.
    setters: []const Setter,
    lost: ?[]const u8 = null,

    const Setter = struct { commit: u32, value: []const u8 };

    fn set(arena: Allocator, value: []const u8, commit: u32) Allocator.Error!Cell {
        return .{
            .value = value,
            .setters = try arena.dupe(Setter, &.{.{ .commit = commit, .value = value }}),
        };
    }
};

/// A set member. Two branches can each set it, and a later change on one
/// of them doesn't overrule the other, so every latest setter is kept.
const LabelCell = struct {
    /// Concurrent setters that disagree resolve to present (add wins).
    present: bool,
    /// None an ancestor of another.
    setters: []const Setter,

    const Setter = struct { commit: u32, present: bool };

    fn set(arena: Allocator, present: bool, commit: u32) Allocator.Error!LabelCell {
        return .{
            .present = present,
            .setters = try arena.dupe(Setter, &.{.{ .commit = commit, .present = present }}),
        };
    }
};

const SetState = struct {
    members: std.array_hash_map.String(LabelCell) = .empty,
    /// The most recent explicit list first.
    order: []const []const u8 = &.{},
};

/// What the fold carries from commit to commit: each field with its setter.
const FoldState = struct {
    scalars: std.array_hash_map.String(Cell) = .empty,
    sets: std.array_hash_map.String(SetState) = .empty,
    /// Removed attachments stay: a UUID's object never changes.
    attachments: std.array_hash_map.String(AttachmentCell) = .empty,
};

const AttachmentCell = struct {
    /// The newest present setter's, or the newest setter's when removed.
    spec: attachment_fmt.Spec,
    /// Concurrent setters that disagree resolve to present (add wins).
    present: bool,
    /// The latest adds, renames and removals, none an ancestor of another.
    setters: []const Setter,
    /// First commit that added this object under this UUID.
    added_in: u32,

    const Setter = struct { commit: u32, present: bool, spec: attachment_fmt.Spec };

    fn set(
        arena: Allocator,
        spec: attachment_fmt.Spec,
        present: bool,
        commit: u32,
        added_in: u32,
    ) Allocator.Error!AttachmentCell {
        return .{
            .spec = spec,
            .present = present,
            .setters = try arena.dupe(Setter, &.{.{
                .commit = commit,
                .present = present,
                .spec = spec,
            }}),
            .added_in = added_in,
        };
    }
};

pub const set_keys = [_][]const u8{ "Labels", "X-Blocked-By", "X-Assignees" };

fn setKey(key: []const u8) ?[]const u8 {
    for (set_keys) |k| if (std.ascii.eqlIgnoreCase(k, key)) return k;
    return null;
}

const Node = struct {
    input: CommitInput,
    parents: []u32,
    block: trailers.Block,
};

/// Every commit folded in topological order: the state after each.
const Folded = struct {
    nodes: []Node,
    index: std.AutoHashMapUnmanaged([object.Oid.max_byte_len]u8, u32),
    events: []const ?Event,
    event_problems: std.ArrayList(EventProblem),
    attachment_problems: std.ArrayList(AttachmentProblem),
    states: []FoldState,
    /// What each merge's parents merge to, before its own trailers.
    merged_parents: []?FoldState,
};

fn fold(arena: Allocator, commits: []const CommitInput) Error!*Folded {
    assert(commits.len > 0);
    const f = try arena.create(Folded);
    f.* = .{
        .nodes = try arena.alloc(Node, commits.len),
        .index = .empty,
        .events = &.{},
        .event_problems = .empty,
        .attachment_problems = .empty,
        .states = try arena.alloc(FoldState, commits.len),
        .merged_parents = try arena.alloc(?FoldState, commits.len),
    };
    for (commits, 0..) |c, i| try f.index.put(arena, c.oid.bytes, @intCast(i));
    for (commits, f.nodes) |c, *n| {
        const parents = try arena.alloc(u32, c.parents.len);
        for (
            c.parents,
            parents,
        ) |p, *pi| pi.* = f.index.get(p.bytes) orelse return error.MissingParent;
        n.* = .{
            .input = c,
            .parents = parents,
            .block = try trailers.parse(arena, c.message, .{}),
        };
    }
    const order = try topoOrder(arena, f.nodes);
    const ctx: Ctx = .{
        .nodes = f.nodes,
        .ancestors = try ancestorSets(arena, f.nodes, order),
        .attachment_problems = &f.attachment_problems,
    };
    f.events = try classifyEvents(arena, f.nodes, &f.index, &f.event_problems);
    for (order) |i| {
        const n = f.nodes[i];
        f.merged_parents[i] = null;
        var s: FoldState = if (n.parents.len == 0)
            .{}
        else blk: {
            var merged = try cloneState(arena, f.states[n.parents[0]]);
            for (n.parents[1..]) |p| merged = try ctx.mergeStates(arena, merged, f.states[p]);
            if (n.parents.len > 1) f.merged_parents[i] = try cloneState(arena, merged);
            break :blk merged;
        };
        try applyTrailers(arena, &s, n, i, f.events[i], &f.attachment_problems);
        f.states[i] = s;
    }
    return f;
}

/// Whether `candidate`, a child of `tip`, would change nothing an issue
/// shows: every field, set, event and attachment as it was, and no
/// conflict it resolves. An empty value is the same as none. Writers
/// use it to skip a commit that only restates what's there.
pub fn changesNothing(
    arena: Allocator,
    commits: []const CommitInput,
    tip: Oid,
    candidate: CommitInput,
) Error!bool {
    // What the fold doesn't hold: a comment, provenance, a reaction.
    const block = try trailers.parse(arena, candidate.message, .{});
    // Who wrote it isn't a change.
    for (block.trailers) |t| if (isPerCommitKey(t.key) and
        !std.ascii.eqlIgnoreCase(t.key, author_id_key)) return false;
    // Attachments are checked by the writer: present to remove, new to add.
    for (block.trailers) |t| if (std.ascii.eqlIgnoreCase(t.key, attachment_fmt.add_key) or
        std.ascii.eqlIgnoreCase(t.key, attachment_fmt.remove_key)) return false;
    if (trailers.lastValue(block, "X-Event") == null) {
        const body = try trailers.bodyLines(arena, candidate.message);
        if ((try trailers.textLines(arena, body, .{})).len > 0) return false;
    }
    const all = try arena.alloc(CommitInput, commits.len + 1);
    @memcpy(all[0..commits.len], commits);
    all[commits.len] = candidate;
    const f = try fold(arena, all);
    const before = f.states[f.index.get(tip.bytes) orelse return error.MissingParent];
    const after = f.states[commits.len];
    // The candidate's own problems (a bad event target) are a change too.
    for (f.event_problems.items) |p| if (p.oid.eql(candidate.oid)) return false;
    // The title is the root's subject until a `Title` sets it.
    var root: ?u32 = null;
    for (f.nodes, 0..) |n, i| if (n.parents.len == 0) {
        if (root == null or n.input.committer.time > f.nodes[root.?].input.committer.time)
            root = @intCast(i);
    };
    const subject = try trailers.subject(
        arena,
        f.nodes[root orelse return error.NoRoot].input.message,
    );
    for (after.scalars.keys(), after.scalars.values()) |k, c| {
        const prev = before.scalars.get(k);
        if (std.mem.eql(u8, k, "Title")) {
            const was = nonEmpty(prev) orelse subject;
            if (!std.mem.eql(u8, was, nonEmpty(c) orelse subject)) return false;
            if (prev != null and prev.?.lost != null and c.lost == null) return false;
            continue;
        }
        const old = if (prev) |x| x.value else "";
        if (!std.mem.eql(u8, shownValue(k, old), shownValue(k, c.value))) return false;
        if (prev != null and prev.?.lost != null and c.lost == null) return false;
    }
    for (after.sets.keys()) |k| {
        const old = try setMembers(arena, before, k);
        const new = try setMembers(arena, after, k);
        if (old.len != new.len) return false;
        for (old, new) |a, b| if (!std.mem.eql(u8, a, b)) return false;
    }
    for (after.attachments.keys(), after.attachments.values()) |k, cell| {
        const prev = before.attachments.get(k) orelse return false;
        const same = prev.spec.sameObject(cell.spec) and
            std.mem.eql(u8, prev.spec.name, cell.spec.name);
        if (prev.present != cell.present or !same) return false;
    }
    return true;
}

/// A scalar as an issue shows it: no state is open, no flag is false.
fn shownValue(key: []const u8, value: []const u8) []const u8 {
    if (std.mem.eql(
        u8,
        key,
        "State",
    )) return core_fmt.State.parse(if (value.len > 0) value else "open").text();
    if (std.mem.eql(u8, key, "X-Deleted") or std.mem.eql(u8, key, "X-Locked"))
        return if (fields_fmt.parseBool(value) orelse false) "true" else "false";
    return value;
}

/// Restated by merge commits after the core fields, as written (invalid
/// values too), so a reader that takes the newest trailer it finds gets the
/// merged value. `X-Blocked-By` follows them.
pub const restated_extensions = [_][]const u8{
    "X-Parent",
    "X-Start-Date",
    "X-Due-Date",
    "X-Estimate-Minutes",
    "X-Workflow-State",
    "X-Milestone-Id",
    "X-Milestone-Mode",
    "X-Deleted",
};

/// What a merge of `parents` resolves to, through a synthetic node. `commits`
/// are the parents' histories.
pub fn resolveMerge(
    arena: Allocator,
    id: []const u8,
    commits: []const CommitInput,
    parents: []const Oid,
    sig: Signature,
    subject: []const u8,
) Error!Issue {
    assert(parents.len > 0);
    var synthetic: Oid = .{ .object_format = parents[0].object_format, .bytes = @splat(0xff) };
    synthetic.bytes[0] = 0xfe;
    const all = try arena.alloc(CommitInput, commits.len + 1);
    @memcpy(all[0..commits.len], commits);
    all[commits.len] = .{
        .oid = synthetic,
        .parents = parents,
        .author = sig,
        .committer = sig,
        .message = subject,
    };
    return materialize(arena, id, synthetic, all);
}

/// The trailers a merge commit restates (format.md §4). Cleared fields are
/// restated empty, so a reader that takes the newest value doesn't find an
/// older one.
pub fn restatedTrailers(
    arena: Allocator,
    resolved: Issue,
) Allocator.Error!std.ArrayList(trailers.Trailer) {
    var list: std.ArrayList(trailers.Trailer) = .empty;
    const cleared = struct {
        fn f(issue: Issue, key: []const u8) ?[]const u8 {
            return if (labels_fmt.contains(issue.cleared, key)) "" else null;
        }
    }.f;
    try list.append(arena, .{ .key = "State", .value = resolved.state.text() });
    if (resolved.title_override orelse cleared(resolved, "Title")) |t| try list.append(
        arena,
        .{ .key = "Title", .value = t },
    );
    if (resolved.labels.len > 0) try list.append(
        arena,
        .{ .key = "Labels", .value = try labels_fmt.join(arena, resolved.labels) },
    ) else if (cleared(resolved, "Labels")) |v| try list.append(
        arena,
        .{ .key = "Labels", .value = v },
    );
    for ([_][]const u8{
        "Assignee",
        "Priority",
        "Milestone",
    } ++ restated_extensions) |key| {
        const value = resolved.field(key) orelse cleared(resolved, key) orelse continue;
        try list.append(arena, .{ .key = key, .value = value });
    }
    if (resolved.blocked_by_written.len > 0) try list.append(arena, .{
        .key = "X-Blocked-By",
        .value = try labels_fmt.join(arena, resolved.blocked_by_written),
    }) else if (cleared(resolved, "X-Blocked-By")) |v| try list.append(
        arena,
        .{ .key = "X-Blocked-By", .value = v },
    );
    return list;
}

pub fn materialize(
    arena: Allocator,
    id: []const u8,
    tip: Oid,
    commits: []const CommitInput,
) Error!Issue {
    const f = try fold(arena, commits);
    const nodes = f.nodes;
    const index = &f.index;
    const tip_index = index.get(tip.bytes) orelse return error.MissingParent;
    const events = f.events;
    const states = f.states;
    const merged_parents = f.merged_parents;
    const attachment_problems = f.attachment_problems;
    const event_problems = f.event_problems;

    // With several roots (unrelated histories merged) take the newest by
    // committer time, like upstream.
    var root: ?u32 = null;
    var roots: usize = 0;
    for (nodes, 0..) |n, i| if (n.parents.len == 0) {
        roots += 1;
        const newer = root == null or n.input.committer.time > nodes[root.?].input.committer.time;
        if (newer) root = @intCast(i);
    };
    const r = root orelse return error.NoRoot;
    const root_node = nodes[r];
    const final = states[tip_index];
    const walk = try oldestFirst(arena, nodes, tip_index, r);
    var steps: std.ArrayList(Step) = .empty;

    const title = nonEmpty(final.scalars.get("Title"));
    const root_subject = try trailers.subject(arena, root_node.input.message);
    const root_body = try trailers.bodyLines(arena, root_node.input.message);
    const description_lines = try trailers.textLines(arena, root_body, .{});
    const description = if (final.scalars.get(description_key)) |c|
        c.value
    else
        try std.mem.join(arena, "\n", description_lines);

    var fields: std.ArrayList(Field) = .empty;
    var cleared: std.ArrayList([]const u8) = .empty;
    var conflicts: std.ArrayList(Conflict) = .empty;
    const keys = try arena.dupe([]const u8, final.scalars.keys());
    stableSort([]const u8, keys, {}, lessThan);
    for (keys) |k| {
        const c = final.scalars.get(k).?;
        if (c.lost) |lost| try conflicts.append(arena, .{
            .target = conflictTarget(k, root_node.input.oid.object_format),
            .value = c.value,
            .lost = lost,
        });
        if (isInternalKey(k)) continue;
        if (std.mem.eql(u8, k, "State") or std.mem.eql(u8, k, "Format-Version")) continue;
        if (c.value.len == 0) {
            try cleared.append(arena, k);
            continue;
        }
        if (std.mem.eql(u8, k, "Title")) continue;
        try fields.append(arena, .{ .key = k, .value = c.value });
    }

    const labels = try setMembers(arena, final, "Labels");
    const blocked_by = try setMembers(arena, final, "X-Blocked-By");
    for ([_]struct { []const u8, usize }{
        .{ "Labels", labels.len },
        .{ "X-Blocked-By", blocked_by.len },
    }) |set| if (set[1] == 0 and final.sets.contains(set[0])) try cleared.append(arena, set[0]);
    stableSort([]const u8, cleared.items, {}, lessThan);

    const state_value = core_fmt.State.parse(nonEmpty(final.scalars.get("State")) orelse "open");

    const ext = try extensions(
        arena,
        final,
        blocked_by,
        try setMembers(arena, final, "X-Assignees"),
    );
    var issue: Issue = .{
        .id = id,
        .tip = tip,
        .root = root_node.input.oid,
        .roots = roots,
        .title = title orelse root_subject,
        .title_override = title,
        .root_subject = root_subject,
        .description = description,
        .deleted = if (final.scalars.get("X-Deleted")) |c|
            fields_fmt.parseBool(c.value) orelse false
        else
            false,
        .event_problems = event_problems.items,
        .attachments = try attachmentList(arena, nodes, final, true),
        .removed_attachments = try attachmentList(arena, nodes, final, false),
        .attachment_problems = try dedupProblems(arena, attachment_problems.items),
        .state = state_value,
        .labels = labels,
        .fields = try fields.toOwnedSlice(arena),
        .cleared = cleared.items,
        .conflicts = try conflicts.toOwnedSlice(arena),
        .author = root_node.input.author,
        .author_id = authorIdIn(root_node.block),
        .author_ids = try authorIds(arena, nodes),
        .created = root_node.input.author.time,
        .updated = nodes[tip_index].input.author.time,
        .updated_tz_offset_minutes = nodes[tip_index].input.author.tz_offset_minutes,
        .comments = try comments(arena, nodes, walk, events, final, states, merged_parents, &steps),
        .steps = steps.items,
        .reactions = try reactionsOf(arena, nodes, final, root_node.input.oid.object_format),
        .created_changes = try diffStates(arena, null, states[r]),
        .original_author = trailers.lastValue(root_node.block, "X-Original-Author"),
        .original_id = trailers.lastValue(root_node.block, "X-Original-Id"),
        .description_history = try descriptionHistory(arena, nodes, walk, r, events),
        .log = try logMessages(arena, nodes, tip_index),
        .format_version = trailers.lastValue(root_node.block, "Format-Version"),
        .commit_count = nodes.len,
    };
    issue.setExtensions(ext);
    issue.priority = core_fmt.Priority.parse(issue.field("Priority") orelse "");
    issue.milestone = issue.field("Milestone");
    return issue;
}

fn authorIdIn(block: trailers.Block) ?[]const u8 {
    const v = trailers.lastValue(block, author_id_key) orelse return null;
    return if (uuid_fmt.isCanonical(v)) v else null;
}

fn authorIds(arena: Allocator, nodes: []const Node) Allocator.Error![]const AuthorId {
    var out: std.ArrayList(AuthorId) = .empty;
    for (nodes) |n| if (authorIdIn(n.block)) |id| try out.append(
        arena,
        .{ .oid = n.input.oid, .id = id },
    );
    return out.items;
}

const Ctx = struct {
    nodes: []const Node,
    ancestors: []const std.DynamicBitSetUnmanaged,
    attachment_problems: *std.ArrayList(AttachmentProblem),

    fn isAncestor(ctx: Ctx, a: u32, b: u32) bool {
        return ctx.ancestors[b].isSet(a);
    }

    fn lwwWins(ctx: Ctx, a: u32, b: u32) bool {
        const ta = ctx.nodes[a].input.author.time;
        const tb = ctx.nodes[b].input.author.time;
        if (ta != tb) return ta > tb;
        return ctx.nodes[a].input.oid.order(ctx.nodes[b].input.oid) == .gt;
    }

    fn mergeStates(
        ctx: Ctx,
        arena: Allocator,
        a: FoldState,
        b: FoldState,
    ) Allocator.Error!FoldState {
        var out = try cloneState(arena, a);
        for (b.scalars.keys(), b.scalars.values()) |k, bc| {
            const gop = try out.scalars.getOrPut(arena, k);
            if (!gop.found_existing) {
                gop.value_ptr.* = bc;
                continue;
            }
            gop.value_ptr.* = try ctx.mergeCell(arena, gop.value_ptr.*, bc);
        }
        for (b.sets.keys(), b.sets.values()) |key, bset| {
            const gop = try out.sets.getOrPut(arena, key);
            if (!gop.found_existing) {
                gop.value_ptr.* = try cloneSet(arena, bset);
                continue;
            }
            gop.value_ptr.* = try ctx.mergeSets(arena, gop.value_ptr.*, bset);
        }
        for (b.attachments.keys(), b.attachments.values()) |id, bc| {
            const gop = try out.attachments.getOrPut(arena, id);
            if (!gop.found_existing) {
                gop.value_ptr.* = bc;
                continue;
            }
            gop.value_ptr.* = try ctx.mergeAttachment(arena, gop.value_ptr.*, bc);
        }
        return out;
    }

    /// Two different objects under one UUID can only come from concurrent
    /// writes. The first one added stays, the other is reported.
    fn mergeAttachment(
        ctx: Ctx,
        arena: Allocator,
        a: AttachmentCell,
        b: AttachmentCell,
    ) Allocator.Error!AttachmentCell {
        if (!a.spec.sameObject(b.spec)) {
            const b_first = ctx.lwwWins(a.added_in, b.added_in);
            const keep = if (b_first) b else a;
            const drop = if (b_first) a else b;
            try ctx.attachment_problems.append(arena, .{
                .oid = ctx.nodes[drop.added_in].input.oid,
                .kind = .changed_object,
                .value = drop.spec.id,
            });
            return keep;
        }
        const added_in = if (ctx.lwwWins(a.added_in, b.added_in)) b.added_in else a.added_in;
        const setters = try ctx.latest(AttachmentCell.Setter, arena, a.setters, b.setters);
        var present = false;
        for (setters) |x| present = present or x.present;
        var best: ?AttachmentCell.Setter = null;
        for (setters) |x| {
            if (present and !x.present) continue;
            if (best == null or ctx.lwwWins(x.commit, best.?.commit)) best = x;
        }
        return .{
            .spec = best.?.spec,
            .present = present,
            .setters = setters,
            .added_in = added_in,
        };
    }

    /// The setters of both sides that no setter on either side descends
    /// from. Sorted by commit, so the same setters compare equal.
    fn latest(
        ctx: Ctx,
        comptime T: type,
        arena: Allocator,
        a: []const T,
        b: []const T,
    ) Allocator.Error![]const T {
        // Most merges change a cell on one side or none: no allocation.
        if (sameSetters(T, a, b)) return a;
        if (a.len == 1 and b.len == 1) {
            if (ctx.isAncestor(a[0].commit, b[0].commit)) return b;
            if (ctx.isAncestor(b[0].commit, a[0].commit)) return a;
        }
        var out: std.ArrayList(T) = .empty;
        for ([_][]const T{ a, b }) |side| {
            next: for (side) |x| {
                for (out.items) |y| if (y.commit == x.commit) continue :next;
                for ([_][]const T{ a, b }) |other| {
                    for (other) |y| if (y.commit != x.commit and ctx.isAncestor(x.commit, y.commit))
                        continue :next;
                }
                try out.append(arena, x);
            }
        }
        stableSort(T, out.items, {}, struct {
            fn lt(_: void, x: T, y: T) bool {
                return x.commit < y.commit;
            }
        }.lt);
        return out.items;
    }

    fn mergeSets(ctx: Ctx, arena: Allocator, a: SetState, b: SetState) Allocator.Error!SetState {
        var out = try cloneSet(arena, a);
        var b_wins_order = false;
        for (b.members.keys(), b.members.values()) |m, bc| {
            const gop = try out.members.getOrPut(arena, m);
            if (!gop.found_existing) {
                gop.value_ptr.* = bc;
                continue;
            }
            const ac = gop.value_ptr.*;
            const setters = try ctx.latest(LabelCell.Setter, arena, ac.setters, bc.setters);
            var present = false;
            var a_kept = false;
            for (setters) |x| {
                present = present or x.present;
                if (!containsSetter(LabelCell.Setter, bc.setters, x.commit)) a_kept = true;
            }
            // b's changes are newer than everything a has: b's order.
            if (!a_kept and !sameSetters(LabelCell.Setter, ac.setters, bc.setters))
                b_wins_order = true;
            gop.value_ptr.* = .{ .present = present, .setters = setters };
        }
        out.order = if (b_wins_order)
            try concatOrder(arena, b.order, a.order)
        else
            try concatOrder(arena, a.order, b.order);
        return out;
    }

    /// The newest latest setter wins; the newest one with another value
    /// is the conflict's lost value.
    fn mergeCell(ctx: Ctx, arena: Allocator, a: Cell, b: Cell) Allocator.Error!Cell {
        const setters = try ctx.latest(Cell.Setter, arena, a.setters, b.setters);
        if (sameSetters(Cell.Setter, setters, a.setters)) return a;
        if (sameSetters(Cell.Setter, setters, b.setters)) return b;
        var best = setters[0];
        for (setters[1..]) |x| if (ctx.lwwWins(x.commit, best.commit)) {
            best = x;
        };
        var lost: ?Cell.Setter = null;
        for (setters) |x| if (!std.mem.eql(u8, x.value, best.value)) {
            if (lost == null or ctx.lwwWins(x.commit, lost.?.commit)) lost = x;
        };
        // All agree: a conflict a merge restated stays.
        const carried = if (containsSetter(Cell.Setter, a.setters, best.commit)) a.lost else b.lost;
        return .{
            .value = best.value,
            .setters = setters,
            .lost = if (lost) |l| l.value else carried,
        };
    }
};

/// Upstream's provider bridges put these on single commits (imported
/// comments, export records). As issue fields they would show whichever
/// came last. `Provider-ID` names the issue and stays a field.
pub const per_commit_keys = [_][]const u8{
    "Provider-Comment-ID", "Exported-Commit",  "X-Message",  "X-Original-Author", "X-Original-Id",
    "X-Purged",            "X-Rewritten-From", "X-Reaction", author_id_key,
};

/// The host's UUID of a commit's author (format.md §3): the identity
/// behind the name and email, which may change.
pub const author_id_key = "X-Author-Id";

/// The commit's author UUID: its last `X-Author-Id` when that is a
/// canonical UUID.
pub fn authorIdOf(arena: Allocator, message: []const u8) Allocator.Error!?[]const u8 {
    const block = try trailers.parse(arena, message, .{});
    const v = trailers.lastValue(block, author_id_key) orelse return null;
    return if (uuid_fmt.isCanonical(v)) v else null;
}

/// A key the format gives a meaning (fields, events, attachments,
/// per-commit trailers): host fields can't use it.
pub fn isFormatKey(key: []const u8) bool {
    if (setKey(key) != null or isPerCommitKey(key) or isEventKey(key)) return true;
    if (std.ascii.eqlIgnoreCase(key, attachment_fmt.add_key) or
        std.ascii.eqlIgnoreCase(key, attachment_fmt.remove_key)) return true;
    for (scalar_keys) |k| if (std.ascii.eqlIgnoreCase(k, key)) return true;
    return false;
}

fn isPerCommitKey(key: []const u8) bool {
    for (per_commit_keys) |k| if (std.ascii.eqlIgnoreCase(k, key)) return true;
    return false;
}

fn applyTrailers(
    arena: Allocator,
    s: *FoldState,
    n: Node,
    self: usize,
    event: ?Event,
    attachment_problems: *std.ArrayList(AttachmentProblem),
) Allocator.Error!void {
    const setter: u32 = @intCast(self);
    const is_merge = n.parents.len > 1;
    if (event) |e| try applyEvent(arena, s, e, setter);
    // A plain `Assignee` without `X-Assignees`, as upstream (which knows
    // only one) writes it, sets the assignees to that one. Merges restate
    // `Assignee`, so they don't count.
    if (!is_merge and trailers.lastValue(n.block, "X-Assignees") == null) {
        if (trailers.lastValue(
            n.block,
            "Assignee",
        )) |v| try applySet(arena, s, "X-Assignees", v, setter);
    }
    // Within a commit the last occurrence of a key wins, like git's
    // %(trailers:key=...).
    for (n.block.trailers) |t| {
        if (setKey(t.key)) |key| {
            try applySet(arena, s, key, t.value, setter);
            continue;
        }
        if (isPerCommitKey(t.key) or isEventKey(t.key)) continue;
        if (std.ascii.eqlIgnoreCase(t.key, attachment_fmt.add_key) or
            std.ascii.eqlIgnoreCase(t.key, attachment_fmt.remove_key))
        {
            try applyAttachment(arena, s, n, setter, t, attachment_problems);
            continue;
        }
        const key = canonicalKey(t.key);
        const gop = try s.scalars.getOrPut(arena, key);
        const lost = if (gop.found_existing and is_merge and
            std.mem.eql(u8, gop.value_ptr.value, t.value))
            // Restating the merge's own result keeps the conflict.
            gop.value_ptr.lost
        else
            null;
        gop.value_ptr.* = try .set(arena, t.value, setter);
        gop.value_ptr.lost = lost;
    }
}

fn applyAttachment(
    arena: Allocator,
    s: *FoldState,
    n: Node,
    setter: u32,
    t: trailers.Trailer,
    problems: *std.ArrayList(AttachmentProblem),
) Allocator.Error!void {
    const bad: AttachmentProblem = .{ .oid = n.input.oid, .kind = .malformed, .value = t.value };
    if (std.ascii.eqlIgnoreCase(t.key, attachment_fmt.remove_key)) {
        if (!uuid_fmt.isCanonical(t.value)) return problems.append(arena, bad);
        const cell = s.attachments.getPtr(t.value) orelse return;
        cell.* = try .set(arena, cell.spec, false, setter, cell.added_in);
        return;
    }
    const spec = attachment_fmt.parseSpec(t.value) orelse return problems.append(arena, bad);
    const gop = try s.attachments.getOrPut(arena, spec.id);
    if (gop.found_existing) {
        if (!gop.value_ptr.spec.sameObject(spec)) return problems.append(arena, .{
            .oid = n.input.oid,
            .kind = .changed_object,
            .value = spec.id,
        });
        gop.value_ptr.* = try .set(arena, spec, true, setter, gop.value_ptr.added_in);
        return;
    }
    gop.value_ptr.* = try .set(arena, spec, true, setter, setter);
}

/// Criss-cross merges can run into the same conflict twice.
fn dedupProblems(
    arena: Allocator,
    all: []const AttachmentProblem,
) Allocator.Error![]const AttachmentProblem {
    var out: std.ArrayList(AttachmentProblem) = .empty;
    outer: for (all) |p| {
        for (out.items) |q| if (q.oid.eql(p.oid) and q.kind == p.kind and
            std.mem.eql(u8, q.value, p.value)) continue :outer;
        try out.append(arena, p);
    }
    return out.items;
}

fn attachmentList(
    arena: Allocator,
    nodes: []const Node,
    final: FoldState,
    present: bool,
) Allocator.Error![]const Attachment {
    var out: std.ArrayList(Attachment) = .empty;
    for (final.attachments.values()) |c| {
        if (c.present != present) continue;
        const added = nodes[c.added_in].input;
        try out.append(arena, .{
            .id = c.spec.id,
            .media = c.spec.media,
            .size = c.spec.size,
            .sha256 = c.spec.sha256,
            .name = c.spec.name,
            .added_in = added.oid,
            .added_by = added.author,
        });
    }
    stableSort(Attachment, out.items, {}, struct {
        fn lt(_: void, x: Attachment, y: Attachment) bool {
            if (x.added_by.time != y.added_by.time) return x.added_by.time < y.added_by.time;
            // Same commit: trailer order, the sort is stable.
            return x.added_in.order(y.added_in) == .lt;
        }
    }.lt);
    return out.items;
}

/// Keys for event state. Trailer keys can't contain spaces, so these never
/// collide with one, like a `description:` trailer from another tool.
const description_key = "event description";

fn commentKey(arena: Allocator, what: []const u8, target: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "comment-{s} {s}", .{ what, target });
}

fn reactionsOf(
    arena: Allocator,
    nodes: []const Node,
    final: FoldState,
    format: object.ObjectFormat,
) Allocator.Error![]const Reaction {
    var out: std.ArrayList(Reaction) = .empty;
    for (final.sets.keys(), final.sets.values()) |k, set| {
        if (!std.mem.startsWith(u8, k, "reaction ")) continue;
        const t = k["reaction ".len..];
        const target: ?Oid = if (std.mem.eql(
            u8,
            t,
            "-",
        )) null else Oid.parseHex(format, t) catch continue;
        var emojis: std.ArrayList([]const u8) = .empty;
        var users: std.ArrayList(std.ArrayList(ReactionUser)) = .empty;
        for (set.members.keys(), set.members.values()) |member, cell| {
            if (!cell.present) continue;
            const sp = std.mem.findScalar(u8, member, ' ') orelse continue;
            const emoji = member[0..sp];
            var name: []const u8 = "";
            for (cell.setters) |st| if (st.present) {
                name = nodes[st.commit].input.author.name;
            };
            const at = for (emojis.items, 0..) |e, i| {
                if (std.mem.eql(u8, e, emoji)) break i;
            } else blk: {
                try emojis.append(arena, emoji);
                try users.append(arena, .empty);
                break :blk emojis.items.len - 1;
            };
            try users.items[at].append(arena, .{ .email = member[sp + 1 ..], .name = name });
        }
        for (
            emojis.items,
            users.items,
        ) |e, u| try out.append(arena, .{ .target = target, .emoji = e, .users = u.items });
    }
    return out.items;
}

/// "reaction -" for the issue's, "reaction <oid>" for a comment's.
fn reactionKey(arena: Allocator, target: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "reaction {s}", .{if (target.len == 0) "-" else target});
}

fn isInternalKey(k: []const u8) bool {
    return std.mem.findScalar(u8, k, ' ') != null;
}

/// Event keys name what they change: the description or a comment.
fn conflictTarget(k: []const u8, format: object.ObjectFormat) Conflict.Target {
    if (std.mem.eql(u8, k, description_key)) return .description;
    if (std.mem.findScalar(u8, k, ' ')) |sp| {
        // Event targets were checked when the event was read.
        return .{ .comment = Oid.parseHex(format, k[sp + 1 ..]) catch unreachable };
    }
    return .{ .field = k };
}

fn isEventKey(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "X-Event") or std.ascii.eqlIgnoreCase(key, "X-Comment");
}

const Event = struct {
    kind: fields_fmt.Event,
    target: []const u8 = "",
    text: []const u8 = "",
    reaction: ?fields_fmt.Reaction = null,
    /// The author's email: whose reaction it is.
    actor: []const u8 = "",
};

fn classifyEvents(
    arena: Allocator,
    nodes: []const Node,
    index: *const std.AutoHashMapUnmanaged([object.Oid.max_byte_len]u8, u32),
    problems: *std.ArrayList(EventProblem),
) Allocator.Error![]?Event {
    const out = try arena.alloc(?Event, nodes.len);
    const is_event = try arena.alloc(bool, nodes.len);
    for (nodes, is_event) |n, *e| e.* = trailers.lastValue(n.block, "X-Event") != null;
    for (nodes, out) |n, *o| {
        o.* = null;
        var count: usize = 0;
        for (n.block.trailers) |t| if (std.ascii.eqlIgnoreCase(t.key, "X-Event")) {
            count += 1;
        };
        if (count == 0) continue;
        const bad: EventProblem = .{ .oid = n.input.oid, .kind = .invalid };
        const kind = fields_fmt.Event.parse(trailers.lastValue(n.block, "X-Event").?) orelse {
            try problems.append(arena, bad);
            continue;
        };
        if (count > 1) {
            try problems.append(arena, bad);
            continue;
        }
        var e: Event = .{ .kind = kind };
        if (kind.carriesText()) {
            const body = try trailers.bodyLines(arena, n.input.message);
            e.text = try std.mem.join(arena, "\n", try trailers.textLines(arena, body, .{}));
        }
        if (kind == .reaction) {
            e.reaction = fields_fmt.Reaction.parse(trailers.lastValue(
                n.block,
                "X-Reaction",
            ) orelse "") orelse {
                try problems.append(arena, bad);
                continue;
            };
            e.actor = n.input.author.email;
        }
        const optional_target = kind == .reaction and trailers.lastValue(
            n.block,
            "X-Comment",
        ) != null;
        if (kind.targetsComment() or optional_target) {
            const target = trailers.lastValue(n.block, "X-Comment") orelse {
                try problems.append(arena, bad);
                continue;
            };
            const oid = Oid.parseHex(n.input.oid.object_format, target) catch {
                try problems.append(arena, bad);
                continue;
            };
            const ti = index.get(oid.bytes) orelse {
                try problems.append(arena, .{
                    .oid = n.input.oid,
                    .kind = .dangling,
                    .target = target,
                });
                continue;
            };
            if (nodes[ti].parents.len != 1 or is_event[ti]) {
                try problems.append(arena, bad);
                continue;
            }
            e.target = target;
        }
        o.* = e;
    }
    return out;
}

fn applyEvent(arena: Allocator, s: *FoldState, e: Event, setter: u32) Allocator.Error!void {
    const put = struct {
        fn f(a: Allocator, st: *FoldState, key: []const u8, value: []const u8, by: u32) !void {
            try st.scalars.put(a, key, try .set(a, value, by));
        }
    }.f;
    switch (e.kind) {
        .description_edit => try put(arena, s, description_key, e.text, setter),
        .comment_edit => {
            try put(arena, s, try commentKey(arena, "text", e.target), e.text, setter);
            try put(arena, s, try commentKey(arena, "visible", e.target), "1", setter);
        },
        .comment_delete, .comment_restore => {
            const visible = if (e.kind == .comment_delete) "0" else "1";
            try put(arena, s, try commentKey(arena, "visible", e.target), visible, setter);
        },
        // Per target, a set of `<emoji> <email>`: §4 per member, so a
        // concurrent add and remove resolve to add.
        .reaction => {
            const r = e.reaction.?;
            const key = try reactionKey(arena, e.target);
            const gop = try s.sets.getOrPut(arena, key);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const member = try std.fmt.allocPrint(arena, "{s} {s}", .{ r.emoji, e.actor });
            const mg = try gop.value_ptr.members.getOrPut(arena, member);
            if (!mg.found_existing or mg.value_ptr.present != r.add)
                mg.value_ptr.* = try .set(arena, r.add, setter);
        },
    }
}

fn containsSetter(comptime T: type, list: []const T, commit: u32) bool {
    for (list) |x| if (x.commit == commit) return true;
    return false;
}

fn sameSetters(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    for (a) |x| if (!containsSetter(T, b, x.commit)) return false;
    return true;
}

fn applySet(
    arena: Allocator,
    s: *FoldState,
    key: []const u8,
    value: []const u8,
    setter: u32,
) Allocator.Error!void {
    const wanted = try labels_fmt.parse(arena, value);
    const gop = try s.sets.getOrPut(arena, key);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const set = gop.value_ptr;
    for (set.members.keys(), set.members.values()) |m, *cell| {
        if (cell.present and !labels_fmt.contains(wanted, m))
            cell.* = try .set(arena, false, setter);
    }
    for (wanted) |m| {
        const mg = try set.members.getOrPut(arena, m);
        if (!mg.found_existing or !mg.value_ptr.present)
            mg.value_ptr.* = try .set(arena, true, setter);
    }
    set.order = wanted;
}

fn extensions(
    arena: Allocator,
    s: FoldState,
    blocked_by: []const []const u8,
    assignees: []const []const u8,
) Allocator.Error!Extensions {
    var ext: Extensions = .{};
    var invalid: std.ArrayList(Field) = .empty;
    const value = struct {
        fn of(st: FoldState, key: []const u8) ?[]const u8 {
            const c = st.scalars.get(key) orelse return null;
            return if (c.value.len == 0) null else c.value;
        }
    }.of;
    if (value(s, "Assignee")) |v| {
        if (fields_fmt.Assignee.parse(v)) |a| ext.assignee = a else {
            try invalid.append(arena, .{ .key = "Assignee", .value = v });
        }
    }
    var people: std.ArrayList(fields_fmt.Assignee) = .empty;
    for (assignees) |a| {
        if (fields_fmt.Assignee.parse(a)) |parsed| try people.append(arena, parsed) else {
            try invalid.append(arena, .{ .key = "X-Assignees", .value = a });
        }
    }
    ext.assignees = people.items;
    ext.assignees_written = assignees;
    if (value(s, "X-Parent")) |v| {
        if (uuid_fmt.isCanonical(v)) ext.parent = v else {
            try invalid.append(arena, .{ .key = "X-Parent", .value = v });
        }
    }
    var refs: std.ArrayList([]const u8) = .empty;
    for (blocked_by) |b| {
        if (uuid_fmt.isCanonical(b)) try refs.append(arena, b) else {
            try invalid.append(arena, .{ .key = "X-Blocked-By", .value = b });
        }
    }
    ext.blocked_by = refs.items;
    ext.blocked_by_written = blocked_by;
    inline for (.{ .{ "X-Start-Date", "start_date" }, .{ "X-Due-Date", "due_date" } }) |d| {
        if (value(s, d[0])) |v| {
            if (fields_fmt.Date.parse(v)) |date| @field(ext, d[1]) = date else {
                try invalid.append(arena, .{ .key = d[0], .value = v });
            }
        }
    }
    if (value(s, "X-Estimate-Minutes")) |v| {
        if (fields_fmt.parseMinutes(v)) |m| ext.estimate_minutes = m else {
            try invalid.append(arena, .{ .key = "X-Estimate-Minutes", .value = v });
        }
    }
    if (value(s, "X-Milestone-Id")) |v| {
        if (uuid_fmt.isCanonical(v)) ext.milestone_id = v else {
            try invalid.append(arena, .{ .key = "X-Milestone-Id", .value = v });
        }
    }
    if (value(s, "X-Milestone-Mode")) |v| {
        if (fields_fmt.MilestoneMode.parse(v)) |m| ext.milestone_mode = m else {
            try invalid.append(arena, .{ .key = "X-Milestone-Mode", .value = v });
        }
    }
    if (value(s, "X-Deleted")) |v| {
        if (fields_fmt.parseBool(v) == null) try invalid.append(
            arena,
            .{ .key = "X-Deleted", .value = v },
        );
    }
    if (value(s, "X-Number")) |v| {
        if (fields_fmt.parseNumber(v)) |n| ext.number = n else {
            try invalid.append(arena, .{ .key = "X-Number", .value = v });
        }
    }
    if (value(s, "X-Locked")) |v| {
        if (fields_fmt.parseBool(v)) |b| ext.locked = b else {
            try invalid.append(arena, .{ .key = "X-Locked", .value = v });
        }
    }
    ext.lock_reason = value(s, "X-Lock-Reason");
    if (value(s, "X-Ref")) |v| {
        if (fields_fmt.isRefName(v)) ext.ref = v else {
            try invalid.append(arena, .{ .key = "X-Ref", .value = v });
        }
    }
    if (value(s, "X-Workflow-State")) |v| {
        if (fields_fmt.isSlug(v)) ext.workflow = v else {
            try invalid.append(arena, .{ .key = "X-Workflow-State", .value = v });
        }
    }
    ext.invalid_fields = invalid.items;
    return ext;
}

fn setMembers(arena: Allocator, s: FoldState, key: []const u8) Allocator.Error![]const []const u8 {
    const set = s.sets.get(key) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (set.order) |m| {
        if (set.members.get(m)) |cell| if (cell.present and !labels_fmt.contains(out.items, m))
            try out.append(arena, m);
    }
    for (set.members.keys(), set.members.values()) |m, cell| {
        if (cell.present and !labels_fmt.contains(out.items, m)) try out.append(arena, m);
    }
    return out.toOwnedSlice(arena);
}

fn cloneSet(arena: Allocator, set: SetState) Allocator.Error!SetState {
    return .{ .members = try set.members.clone(arena), .order = set.order };
}

/// The scalar fields this tool and upstream write, in their usual case.
const scalar_keys = [_][]const u8{
    "State",
    "Title",
    "Assignee",
    "Priority",
    "Milestone",
    "Format-Version",
    "Fixed-By",
    "Release",
    "Reason",
    "X-Parent",
    "X-Start-Date",
    "X-Due-Date",
    "X-Estimate-Minutes",
    "X-Workflow-State",
    "X-Deleted",
    "X-Milestone-Id",
    "X-Milestone-Mode",
    "X-Number",
    "X-Locked",
    "X-Lock-Reason",
    "X-Ref",
};

/// git matches keys case-insensitively, so `state:` and `State:` are one
/// field.
fn canonicalKey(key: []const u8) []const u8 {
    for (scalar_keys) |c| if (std.ascii.eqlIgnoreCase(c, key)) return c;
    return key;
}

/// A trailer that a write of this tool or upstream's makes: a field, or an
/// export record. A comment's last paragraph can parse as trailers too
/// (`Version: 2.3.1`); those are none of these.
fn isToolKey(key: []const u8) bool {
    for (scalar_keys ++ set_keys ++ [_][]const u8{"Exported-Commit"}) |k| {
        if (std.ascii.eqlIgnoreCase(k, key)) return true;
    }
    return false;
}

fn cloneState(arena: Allocator, s: FoldState) Allocator.Error!FoldState {
    var sets: std.array_hash_map.String(SetState) = .empty;
    for (s.sets.keys(), s.sets.values()) |k, v| try sets.put(arena, k, try cloneSet(arena, v));
    return .{
        .scalars = try s.scalars.clone(arena),
        .sets = sets,
        .attachments = try s.attachments.clone(arena),
    };
}

fn concatOrder(
    arena: Allocator,
    first: []const []const u8,
    second: []const []const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (first) |l| if (!labels_fmt.contains(out.items, l)) try out.append(arena, l);
    for (second) |l| if (!labels_fmt.contains(out.items, l)) try out.append(arena, l);
    return out.toOwnedSlice(arena);
}

/// Parents first (iterative DFS post-order).
fn topoOrder(arena: Allocator, nodes: []const Node) Allocator.Error![]u32 {
    const visited = try arena.alloc(u8, nodes.len); // 0 new, 1 open, 2 done
    @memset(visited, 0);
    var order: std.ArrayList(u32) = .empty;
    var stack: std.ArrayList(struct { node: u32, next_parent: usize }) = .empty;
    for (0..nodes.len) |start| {
        if (visited[start] != 0) continue;
        try stack.append(arena, .{ .node = @intCast(start), .next_parent = 0 });
        visited[start] = 1;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const parents = nodes[top.node].parents;
            if (top.next_parent < parents.len) {
                const p = parents[top.next_parent];
                top.next_parent += 1;
                if (visited[p] == 0) {
                    visited[p] = 1;
                    try stack.append(arena, .{ .node = p, .next_parent = 0 });
                }
                continue;
            }
            visited[top.node] = 2;
            try order.append(arena, top.node);
            _ = stack.pop();
        }
    }
    assert(order.items.len == nodes.len);
    return order.items;
}

/// Bit j of ancestors[i] is set when j is a proper ancestor of i.
fn ancestorSets(
    arena: Allocator,
    nodes: []const Node,
    order: []const u32,
) Allocator.Error![]std.DynamicBitSetUnmanaged {
    const sets = try arena.alloc(std.DynamicBitSetUnmanaged, nodes.len);
    for (order) |i| {
        var set = try std.DynamicBitSetUnmanaged.initEmpty(arena, nodes.len);
        for (nodes[i].parents) |p| {
            set.set(p);
            set.setUnion(sets[p]);
        }
        sets[i] = set;
    }
    return sets;
}

/// Oldest first, in `git rev-list --reverse <root>..<tip>` order.
/// Every commit but the root, oldest first, in `git log` order reversed.
fn oldestFirst(
    arena: Allocator,
    nodes: []const Node,
    tip: u32,
    root: u32,
) Allocator.Error![]const u32 {
    const seen = try arena.alloc(bool, nodes.len);
    @memset(seen, false);
    var queue: std.ArrayList(u32) = .empty;
    var walk: std.ArrayList(u32) = .empty;
    try queue.append(arena, tip);
    seen[tip] = true;
    while (queue.items.len > 0) {
        const n = queue.orderedRemove(newestIndex(nodes, queue.items));
        if (n == root) continue;
        try walk.append(arena, n);
        for (nodes[n].parents) |p| if (!seen[p]) {
            seen[p] = true;
            try queue.append(arena, p);
        };
    }
    std.mem.reverse(u32, walk.items);
    return walk.items;
}

/// The text a comment commit wrote: its subject, then its body without
/// the trailer block.
fn commentText(
    arena: Allocator,
    subject_line: []const u8,
    body: []const []const u8,
) Allocator.Error![]const u8 {
    if (body.len == 0) return subject_line;
    return std.fmt.allocPrint(
        arena,
        "{s}\n\n{s}",
        .{ subject_line, try std.mem.join(arena, "\n", body) },
    );
}

/// The events that target `target` (a comment's full hex OID), as
/// versions after the one it starts from.
fn eventRevisions(
    arena: Allocator,
    nodes: []const Node,
    walk: []const u32,
    events: []const ?Event,
    target: ?[]const u8,
    first: Revision,
) Allocator.Error![]const Revision {
    var out: std.ArrayList(Revision) = .empty;
    try out.append(arena, first);
    var text = first.text;
    for (walk) |n| {
        const e = events[n] orelse continue;
        const kind: Revision.Kind = if (target) |t| blk: {
            if (!e.kind.targetsComment() or !std.mem.eql(u8, e.target, t)) continue;
            break :blk switch (e.kind) {
                .comment_edit => .edit,
                .comment_delete => .delete,
                .comment_restore => .restore,
                .description_edit, .reaction => unreachable,
            };
        } else if (e.kind == .description_edit) .edit else continue;
        if (kind == .edit) text = e.text;
        try out.append(
            arena,
            .{
                .oid = nodes[n].input.oid,
                .author = nodes[n].input.author,
                .kind = kind,
                .text = text,
            },
        );
    }
    return out.items;
}

fn descriptionHistory(
    arena: Allocator,
    nodes: []const Node,
    walk: []const u32,
    root: u32,
    events: []const ?Event,
) Allocator.Error![]const Revision {
    const root_body = try trailers.bodyLines(arena, nodes[root].input.message);
    const original = try std.mem.join(arena, "\n", try trailers.textLines(arena, root_body, .{}));
    return eventRevisions(arena, nodes, walk, events, null, .{
        .oid = nodes[root].input.oid,
        .author = nodes[root].input.author,
        .kind = .original,
        .text = original,
    });
}

/// Field changes from `before` (null: nothing) to `after`. Internal event
/// state and `Format-Version` aren't fields.
fn diffStates(
    arena: Allocator,
    before: ?FoldState,
    after: FoldState,
) Allocator.Error![]const Change {
    var out: std.ArrayList(Change) = .empty;
    const empty: FoldState = .{};
    const b = before orelse empty;
    for (after.scalars.keys(), after.scalars.values()) |k, c| {
        if (isInternalKey(k) or std.mem.eql(u8, k, "Format-Version")) continue;
        const prev = b.scalars.get(k);
        const old: ?[]const u8 = if (prev != null and prev.?.value.len > 0) prev.?.value else null;
        const new: ?[]const u8 = if (c.value.len == 0) null else c.value;
        if (old == null and new == null) continue;
        if (old != null and new != null and std.mem.eql(u8, old.?, new.?)) continue;
        try out.append(
            arena,
            .{ .key = k, .op = if (new == null) .clear else .set, .old = old, .new = new },
        );
    }
    for (after.sets.keys(), after.sets.values()) |k, set| {
        if (isInternalKey(k)) continue;
        const before_set = b.sets.get(k);
        for (set.members.keys(), set.members.values()) |m, cell| {
            const prior = if (before_set) |bs| bs.members.get(m) else null;
            const was = if (prior) |x| x.present else false;
            if (was == cell.present) continue;
            try out.append(arena, .{
                .key = k,
                .op = if (cell.present) .add else .remove,
                .old = if (cell.present) null else m,
                .new = if (cell.present) m else null,
            });
        }
    }
    for (after.attachments.keys(), after.attachments.values()) |id, cell| {
        const was = if (b.attachments.get(id)) |x| x.present else false;
        if (was == cell.present) continue;
        try out.append(arena, .{
            .key = attachment_fmt.add_key,
            .op = if (cell.present) .add else .remove,
            .old = if (cell.present) null else id,
            .new = if (cell.present) id else null,
        });
    }
    return out.items;
}

fn comments(
    arena: Allocator,
    nodes: []const Node,
    walk: []const u32,
    events: []const ?Event,
    final: FoldState,
    states: []const FoldState,
    merged_parents: []const ?FoldState,
    steps: *std.ArrayList(Step),
) Allocator.Error![]const Comment {
    var out: std.ArrayList(Comment) = .empty;
    for (walk) |n| {
        const node = nodes[n];
        if (events[n]) |e| try steps.append(arena, .{
            .oid = node.input.oid,
            .author = node.input.author,
            .what = .{ .event = .{
                .kind = e.kind,
                .target = if (e.target.len > 0)
                    Oid.parseHex(node.input.oid.object_format, e.target) catch unreachable
                else
                    null,
            } },
        });
        // Event commits, valid or not, aren't comments.
        if (events[n] != null or trailers.lastValue(node.block, "X-Event") != null) continue;
        const body = try trailers.bodyLines(arena, node.input.message);
        const hex = node.input.oid.hex();
        const hex_s = try arena.dupe(u8, hex.slice());
        const edited = final.scalars.get(try commentKey(arena, "text", hex_s));
        const visible = final.scalars.get(try commentKey(arena, "visible", hex_s));
        var c: Comment = .{
            .oid = node.input.oid,
            .author = node.input.author,
            .subject = try trailers.subject(arena, node.input.message),
            .text = try trailers.textLines(arena, body, .{ .has_title = true }),
            .body = try trailers.textLines(arena, body, .{}),
            .state_change = if (trailers.lastValue(node.block, "State")) |v|
                core_fmt.State.parse(v)
            else
                null,
            .is_merge = node.parents.len > 1,
            .deleted = visible != null and std.mem.eql(u8, visible.?.value, "0"),
            .original_author = trailers.lastValue(node.block, "X-Original-Author"),
            .original_id = trailers.lastValue(node.block, "X-Original-Id"),
            .purged = if (trailers.lastValue(node.block, "X-Purged")) |v|
                std.mem.eql(u8, v, "true")
            else
                false,
        };
        const original_body = c.body;
        var added: std.ArrayList([]const u8) = .empty;
        for (node.block.trailers) |t| {
            if (!std.ascii.eqlIgnoreCase(t.key, attachment_fmt.add_key)) continue;
            const spec = attachment_fmt.parseSpec(t.value) orelse continue;
            const cell = final.attachments.get(spec.id) orelse continue;
            if (cell.present and cell.added_in == n and !labels_fmt.contains(added.items, spec.id))
                try added.append(arena, spec.id);
        }
        c.attachments = added.items;
        // A comment may be just a subject, with an image, an import ID or
        // a last paragraph that parses as trailers.
        const tool_trailer = for (node.block.trailers) |t| {
            if (isToolKey(t.key)) break true;
        } else false;
        // `X-Message: comment` says the text is a comment, fields or not.
        const marked = if (trailers.lastValue(node.block, "X-Message")) |v|
            std.ascii.eqlIgnoreCase(v, "comment")
        else
            false;
        if (c.body.len == 0 and (tool_trailer or c.is_merge) and !marked) c.kind = .update;
        if (edited) |e| {
            // The edit replaces the whole comment.
            var lines = std.mem.splitScalar(u8, e.value, '\n');
            c.subject = lines.first();
            var rest: std.ArrayList([]const u8) = .empty;
            while (lines.next()) |l| try rest.append(arena, l);
            while (rest.items.len > 0 and rest.items[0].len == 0) _ = rest.orderedRemove(0);
            c.text = rest.items;
            c.body = rest.items;
            c.edited = true;
            c.kind = .comment;
        }
        // A second root (unrelated histories merged) changed from nothing.
        const before: ?FoldState = merged_parents[n] orelse
            if (node.parents.len > 0) states[node.parents[0]] else null;
        c.changes = try diffStates(arena, before, states[n]);
        c.history = try eventRevisions(arena, nodes, walk, events, hex_s, .{
            .oid = node.input.oid,
            .author = node.input.author,
            .kind = .original,
            .text = try commentText(
                arena,
                try trailers.subject(arena, node.input.message),
                original_body,
            ),
        });
        try steps.append(
            arena,
            .{
                .oid = node.input.oid,
                .author = node.input.author,
                .what = .{ .comment = out.items.len },
            },
        );
        try out.append(arena, c);
    }
    return out.items;
}

/// Newest committer time first, like `git log`.
fn logMessages(arena: Allocator, nodes: []const Node, tip: u32) Allocator.Error![]const []const u8 {
    const seen = try arena.alloc(bool, nodes.len);
    @memset(seen, false);
    var queue: std.ArrayList(u32) = .empty;
    var out: std.ArrayList([]const u8) = .empty;
    try queue.append(arena, tip);
    seen[tip] = true;
    while (queue.items.len > 0) {
        const n = queue.orderedRemove(newestIndex(nodes, queue.items));
        try out.append(arena, nodes[n].input.message);
        for (nodes[n].parents) |p| if (!seen[p]) {
            seen[p] = true;
            try queue.append(arena, p);
        };
    }
    return out.items;
}

/// Ties go to the earliest inserted, like git's walk.
fn newestIndex(nodes: []const Node, queue: []const u32) usize {
    var best: usize = 0;
    for (queue, 0..) |q, qi| {
        if (nodes[q].input.committer.time > nodes[queue[best]].input.committer.time) best = qi;
    }
    return best;
}

fn nonEmpty(cell: ?Cell) ?[]const u8 {
    const c = cell orelse return null;
    return if (c.value.len > 0) c.value else null;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const testing = std.testing;

const TestDag = struct {
    arena: Allocator,
    commits: std.ArrayList(CommitInput) = .empty,

    fn add(d: *TestDag, parents: []const usize, time: i64, message: []const u8) !usize {
        const idx = d.commits.items.len;
        var oid: Oid = .{ .object_format = .sha1, .bytes = @splat(0) };
        oid.bytes[0] = @intCast(idx + 1);
        oid.bytes[1] = 0xab;
        const ps = try d.arena.alloc(Oid, parents.len);
        for (parents, ps) |p, *o| o.* = d.commits.items[p].oid;
        const sig: Signature = .{
            .name = "T",
            .email = "t@e.x",
            .time = time,
            .tz_offset_minutes = 0,
        };
        try d.commits.append(
            d.arena,
            .{ .oid = oid, .parents = ps, .author = sig, .committer = sig, .message = message },
        );
        return idx;
    }

    fn issue(d: *TestDag, tip: usize) !Issue {
        return materialize(
            d.arena,
            "a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e",
            d.commits.items[tip].oid,
            d.commits.items,
        );
    }
};

test "linear history" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(
        &.{},
        100,
        "Crash\n\nBody text.\n\n" ++
            "State: open\nLabels: bug, auth\nAssignee: a@e.x\nPriority: high\nFormat-Version: 1\n",
    );
    const c1 = try d.add(&.{root}, 200, "A comment\n\nwith text\n");
    const c2 = try d.add(&.{c1}, 300, "Close issue\n\nState: closed\n");
    const c3 = try d.add(
        &.{c2},
        400,
        "Update labels, assignee\n\nLabels: bug, regression\nAssignee: \n",
    );
    const i = try d.issue(c3);
    try testing.expectEqualStrings("Crash", i.title);
    try testing.expectEqualStrings("Body text.", i.description);
    try testing.expectEqualStrings("closed", i.state.text());
    try testing.expectEqual(@as(usize, 2), i.labels.len);
    try testing.expectEqualStrings("regression", i.labels[1]);
    try testing.expect(i.field("Assignee") == null); // explicitly cleared
    try testing.expectEqualStrings("high", i.field("Priority").?); // never cleared by omission
    try testing.expectEqual(@as(usize, 3), i.comments.len);
    try testing.expectEqualStrings("A comment", i.comments[0].subject);
    try testing.expectEqualStrings("closed", i.comments[1].state_change.?.text());
    try testing.expectEqualStrings("1", i.format_version.?);
    try testing.expectEqual(@as(i64, 100), i.created);
    try testing.expectEqual(@as(i64, 400), i.updated);
}

test "causality beats clocks" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(&.{}, 1000, "T\n\nState: open\nPriority: low\nFormat-Version: 1\n");
    const skewed = try d.add(&.{root}, 10, "Update priority\n\nPriority: critical\n");
    const i = try d.issue(skewed);
    try testing.expectEqualStrings("critical", i.field("Priority").?);
    try testing.expectEqual(@as(usize, 0), i.conflicts.len);
}

test "concurrent edits" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(
        &.{},
        100,
        "T\n\nState: open\nPriority: low\nLabels: bug\nFormat-Version: 1\n",
    );
    const left = try d.add(&.{root}, 200, "L\n\nPriority: high\nLabels: bug, ui\n");
    const right = try d.add(&.{root}, 300, "R\n\nPriority: medium\nState: closed\nLabels: \n");
    const merge = try d.add(&.{ left, right }, 400, "Merge issue from origin\n");
    const i = try d.issue(merge);
    try testing.expectEqualStrings("medium", i.field("Priority").?); // later author time
    try testing.expectEqualStrings("closed", i.state.text()); // only right changed it
    // Right removed "bug" while left left it alone, so it's gone. Left
    // added "ui", so it stays.
    try testing.expectEqual(@as(usize, 1), i.labels.len);
    try testing.expectEqualStrings("ui", i.labels[0]);
    try testing.expectEqual(@as(usize, 1), i.conflicts.len);
    try testing.expectEqualStrings("Priority", i.conflicts[0].target.field);
    try testing.expectEqualStrings("high", i.conflicts[0].lost);
}

test "changesNothing: restated fields, a resolved conflict, what the fold doesn't hold" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d: TestDag = .{ .arena = arena };
    const root = try d.add(
        &.{},
        100,
        "T\n\nState: open\nPriority: low\nLabels: bug, ui\nFormat-Version: 1\n",
    );
    const left = try d.add(&.{root}, 200, "L\n\nPriority: high\n");
    const right = try d.add(&.{root}, 300, "R\n\nPriority: medium\n");
    const merge = try d.add(&.{ left, right }, 400, "Merge issue from origin\n");
    const tip = d.commits.items[root].oid;
    const Case = struct { []const u8, bool };
    for ([_]Case{
        .{ "Edit\n\nState: open\nPriority: low\nX-Deleted: false\n", true },
        .{ "Edit\n\nX-Deleted: true\n", false },
        // A list is its members, in order; none is the same as empty.
        .{ "Edit\n\nLabels: bug, ui\nX-Parent: \n", true },
        .{ "Edit\n\nLabels: ui, bug\n", false },
        .{ "Edit\n\nPriority: high\n", false },
        // The root's subject is the title.
        .{ "Edit\n\nTitle: T\n", true },
        .{ "Edit\n\nTitle: U\n", false },
        // A comment, provenance, a reaction: not in the fold.
        .{ "Same\n\nwith text\n\nPriority: low\n", false },
        .{ "Same\n\nPriority: low\nX-Message: comment\n", false },
        .{ "Same\n\nPriority: low\nX-Original-Id: 7\n", false },
    }) |c| {
        var candidate = d.commits.items[root];
        candidate.oid.bytes = @splat(0);
        candidate.parents = &.{tip};
        candidate.message = c[0];
        errdefer std.debug.print("{s}\n", .{c[0]});
        try testing.expectEqual(c[1], try changesNothing(arena, d.commits.items, tip, candidate));
    }
    // Restating the winner of a conflict resolves it: a change.
    var candidate = d.commits.items[merge];
    candidate.oid.bytes = @splat(0);
    candidate.parents = &.{d.commits.items[merge].oid};
    candidate.message = "Edit\n\nPriority: medium\n";
    try testing.expect(!try changesNothing(
        arena,
        d.commits.items,
        d.commits.items[merge].oid,
        candidate,
    ));
    candidate.message = "Edit\n\nLabels: bug, ui\n";
    try testing.expect(try changesNothing(
        arena,
        d.commits.items,
        d.commits.items[merge].oid,
        candidate,
    ));
}

test "restating merges" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(&.{}, 100, "T\n\nState: open\nFormat-Version: 1\n");
    const left = try d.add(&.{root}, 200, "L\n\nPriority: high\n");
    const right = try d.add(&.{root}, 300, "R\n\nPriority: low\n");
    const restating = try d.add(
        &.{ left, right },
        400,
        "Merge issue\n\nState: open\nPriority: low\n",
    );
    try testing.expectEqual(@as(usize, 1), (try d.issue(restating)).conflicts.len);
    const choosing = try d.add(&.{ left, right }, 400, "Merge issue\n\nPriority: high\n");
    const i = try d.issue(choosing);
    try testing.expectEqual(@as(usize, 0), i.conflicts.len);
    try testing.expectEqualStrings("high", i.field("Priority").?);
    const later = try d.add(&.{restating}, 500, "Update priority\n\nPriority: low\n");
    try testing.expectEqual(@as(usize, 0), (try d.issue(later)).conflicts.len);
}

test "concurrent add vs remove of a label: add wins" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(&.{}, 100, "T\n\nState: open\nLabels: a\nFormat-Version: 1\n");
    const removed = try d.add(&.{root}, 900, "R\n\nLabels: \n");
    const readded = try d.add(&.{root}, 200, "A\n\nLabels: a, b\n");
    const merge = try d.add(&.{ removed, readded }, 1000, "Merge\n");
    const i = try d.issue(merge);
    // "a" was removed on the left and untouched on the right: removed.
    // "b" was added on the right: present.
    try testing.expectEqual(@as(usize, 1), i.labels.len);
    try testing.expectEqualStrings("b", i.labels[0]);

    // Concurrent: one side removes x, the other removes and re-adds it.
    // The add wins, even though the removal is newer.
    const root2 = try d.add(&.{}, 100, "T\n\nState: open\nLabels: x\nFormat-Version: 1\n");
    const del_x = try d.add(&.{root2}, 900, "D\n\nLabels: \n");
    const rm_x = try d.add(&.{root2}, 200, "R\n\nLabels: \n");
    const readd_x = try d.add(&.{rm_x}, 210, "A\n\nLabels: x\n");
    const m2 = try d.add(&.{ del_x, readd_x }, 1000, "Merge\n");
    const j = try d.issue(m2);
    try testing.expectEqual(@as(usize, 1), j.labels.len);
    try testing.expectEqualStrings("x", j.labels[0]);
}

test "a set member added on two branches survives a removal on one" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(&.{}, 100, "T\n\nState: open\nFormat-Version: 1\n");
    const left = try d.add(&.{root}, 120, "L\n\nLabels: x\n");
    const right = try d.add(&.{root}, 180, "R\n\nLabels: x\n");
    // A merge that doesn't restate: both adds stay its latest setters.
    const both = try d.add(&.{ left, right }, 400, "Merge\n");
    // Removed after the right add only, so concurrent with the left one.
    const removed = try d.add(&.{right}, 600, "Edit\n\nLabels: y\n");
    const i = try d.issue(try d.add(&.{ both, removed }, 700, "Merge\n"));
    try testing.expectEqual(@as(usize, 2), i.labels.len);
    try testing.expect(labels_fmt.contains(i.labels, "x"));
    try testing.expect(labels_fmt.contains(i.labels, "y"));
}

test "criss-cross merges are deterministic" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(&.{}, 100, "T\n\nState: open\nFormat-Version: 1\n");
    const a = try d.add(&.{root}, 200, "A\n\nPriority: high\n");
    const b = try d.add(&.{root}, 300, "B\n\nAssignee: b@e.x\n");
    const m1 = try d.add(&.{ a, b }, 400, "M1\n");
    const m2 = try d.add(&.{ b, a }, 410, "M2\n");
    const top = try d.add(&.{ m1, m2 }, 500, "Top\n");
    const i = try d.issue(top);
    try testing.expectEqualStrings("high", i.field("Priority").?);
    try testing.expectEqualStrings("b@e.x", i.field("Assignee").?);
    try testing.expectEqual(@as(usize, 0), i.conflicts.len);
}

test "upstream merges keep X- fields" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(
        &.{},
        100,
        "T\n\nState: open\nX-Workflow-State: ready\nFormat-Version: 1\n",
    );
    const l = try d.add(&.{root}, 200, "comment\n");
    const r = try d.add(&.{root}, 300, "Close issue\n\nState: closed\n");
    const m = try d.add(&.{ l, r }, 400, "Merge issue from origin\n\nState: closed\n");
    const i = try d.issue(m);
    try testing.expectEqualStrings("ready", i.field("X-Workflow-State").?);
    try testing.expectEqualStrings("closed", i.state.text());
}

test "description and comment text" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(
        &.{},
        100,
        "Crash\n\nFirst paragraph.\n\nSecond paragraph\nwith two lines.\n\n" ++
            "State: open\nFormat-Version: 1\n",
    );
    const close = try d.add(&.{root}, 200, "Fixed in abc\n\nState: closed\n");
    const i = try d.issue(close);
    try testing.expectEqualStrings(
        "First paragraph.\n\nSecond paragraph\nwith two lines.",
        i.description,
    );
    try testing.expectEqual(@as(usize, 1), i.comments[0].text.len);
    try testing.expectEqualStrings("State: closed", i.comments[0].text[0]);
    try testing.expectEqualStrings("closed", i.comments[0].state_change.?.text());
    // Closing with a message only is an update.
    try testing.expectEqual(Comment.Kind.update, i.comments[0].kind);
}

test "comment kinds" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(&.{}, 100, "T\n\nState: open\nFormat-Version: 1\n");
    const one_line = try d.add(&.{root}, 200, "LGTM\n");
    const with_text = try d.add(&.{one_line}, 300, "Draft\n\nIn the wiki.\n\nPriority: high\n");
    const edit = try d.add(&.{with_text}, 400, "Update labels\n\nLabels: bug\n");
    const image = try d.add(&.{edit}, 500, "Screenshot\n\n" ++
        "X-Attachment: 720964d9-80f3-4953-bf91-3b32b2897504 image/png 10 " ++
        "0000000000000000000000000000000000000000000000000000000000000000 a.png\n");
    const imported = try d.add(
        &.{image},
        600,
        "Looks bad\n\nProvider-Comment-ID: github:o/r#c-1\n",
    );
    const trailer_like = try d.add(&.{imported}, 650, "Still happens\n\nVersion: 2.3.1\n");
    const record = try d.add(&.{trailer_like}, 700, "Record export\n\nExported-Commit: 0123abc\n");
    const side = try d.add(&.{record}, 800, "Update priority\n\nPriority: low\n");
    const other = try d.add(&.{record}, 800, "Update assignee\n\nAssignee: a@example.com\n");
    const merge = try d.add(&.{ side, other }, 900, "Merge issue\n\nPriority: low\n");
    const i = try d.issue(merge);
    var kinds: std.ArrayList(Comment.Kind) = .empty;
    for (i.comments) |c| try kinds.append(arena_state.allocator(), c.kind);
    try testing.expectEqualSlices(Comment.Kind, &.{
        .comment, // LGTM
        .comment, // text with a field
        .update, // Update labels
        .comment, // an image with a subject
        .comment, // an imported one-liner
        .comment, // a last paragraph that parses as a trailer
        .update, // an export record
        .update,
        .update,
        .update, // the merge
    }, kinds.items);
}

test "per-commit trailers" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(
        &.{},
        100,
        "Crash\n\nState: open\nProvider-ID: github:o/r#7\nFormat-Version: 1\n",
    );
    const comment = try d.add(
        &.{root},
        200,
        "Looks bad\n\nProvider-Comment-ID: github:o/r#comment-42\n",
    );
    const record = try d.add(
        &.{comment},
        300,
        "Record export of comment to GitHub #7\n\n" ++
            "Provider-Comment-ID: github:o/r#comment-43\nExported-Commit: 0123abc\n",
    );
    const i = try d.issue(record);
    try testing.expectEqualStrings("github:o/r#7", i.field("Provider-ID").?);
    try testing.expect(i.field("Provider-Comment-ID") == null);
    try testing.expect(i.field("Exported-Commit") == null);
    try testing.expect(i.field("provider-comment-id") == null);
    try testing.expectEqual(@as(usize, 2), i.comments.len);
}

test "invalid extension values" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const parent = "b8e4c3d2-5f6e-4b9c-8d2f-3a4b5c6d7e8f";
    const root = try d.add(&.{}, 100, "Child\n\nState: open\n" ++
        "Assignee: a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e ada@e.x\n" ++
        "X-Parent: " ++ parent ++ "\n" ++
        "X-Blocked-By: c9f5d4e3-6a7f-4cad-9e3a-4b5c6d7e8f90, not-a-uuid\n" ++
        "X-Start-Date: 2026-11-01\nX-Due-Date: 2026-02-30\n" ++
        "X-Estimate-Minutes: 90\nX-Workflow-State: in-progress\nFormat-Version: 1\n");
    const i = try d.issue(root);
    try testing.expectEqualStrings(parent, i.parent.?);
    try testing.expectEqualStrings("ada@e.x", i.assignee.?.email);
    try testing.expectEqual(@as(usize, 1), i.blocked_by.len);
    try testing.expectEqual(@as(u8, 11), i.start_date.?.month);
    try testing.expect(i.due_date == null);
    try testing.expectEqual(@as(?u32, 90), i.estimate_minutes);
    try testing.expectEqualStrings("in-progress", i.workflow.?);
    try testing.expectEqual(@as(usize, 2), i.invalid_fields.len); // not-a-uuid, Feb 30

    // Only exactly `true` deletes. Anything else but `false` is reported.
    const maybe = try d.add(&.{root}, 200, "Delete?\n\nX-Deleted: True\n");
    const m = try d.issue(maybe);
    try testing.expect(!m.deleted);
    try testing.expectEqual(@as(usize, 3), m.invalid_fields.len);
    try testing.expectEqualStrings("X-Deleted", m.invalid_fields[2].key);
    const cleared = try d.issue(try d.add(&.{maybe}, 300, "Undo\n\nX-Deleted:\n"));
    try testing.expectEqual(@as(usize, 2), cleared.invalid_fields.len);
}

test "blocked-by merges per member" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const a = "c9f5d4e3-6a7f-4cad-9e3a-4b5c6d7e8f90";
    const b = "d0a6e5f4-7b8a-4dbe-8f4b-5c6d7e8f9012";
    const c = "e1b7f6a5-8c9b-4ecf-9a5c-6d7e8f901234";
    const root = try d.add(
        &.{},
        100,
        "Blocked\n\nState: open\nX-Blocked-By: " ++ a ++ "\nFormat-Version: 1\n",
    );
    const left = try d.add(&.{root}, 200, "Add b\n\nX-Blocked-By: " ++ a ++ ", " ++ b ++ "\n");
    const right = try d.add(&.{root}, 300, "Swap a for c\n\nX-Blocked-By: " ++ c ++ "\n");
    const merge = try d.add(&.{ left, right }, 400, "Merge issue\n\nState: open\n");
    const i = try d.issue(merge);
    // b and c were added concurrently, so both stay. a was removed on one
    // side and untouched on the other, so it's gone.
    try testing.expectEqual(@as(usize, 2), i.blocked_by.len);
    for ([_][]const u8{ b, c }) |x| try testing.expect(labels_fmt.contains(i.blocked_by, x));

    // A concurrent re-add and remove: the add wins.
    const all = a ++ ", " ++ b ++ ", " ++ c;
    const readd = try d.add(&.{merge}, 500, "Re-add a\n\nX-Blocked-By: " ++ all ++ "\n");
    const drop = try d.add(&.{merge}, 600, "Drop b\n\nX-Blocked-By: " ++ c ++ "\n");
    const again = try d.add(&.{ readd, drop }, 700, "Merge issue\n\nState: open\n");
    const j = try d.issue(again);
    try testing.expect(labels_fmt.contains(j.blocked_by, a));
    try testing.expect(!labels_fmt.contains(j.blocked_by, b));
}

fn hexOf(d: *TestDag, i: usize) ![]const u8 {
    return d.commits.items[i].oid.hexAlloc(d.arena);
}

fn eventMsg(d: *TestDag, head: []const u8, kind: []const u8, target: ?usize) ![]const u8 {
    const comment_line = if (target) |t|
        try std.fmt.allocPrint(d.arena, "X-Comment: {s}\n", .{try hexOf(d, t)})
    else
        "";
    return std.fmt.allocPrint(d.arena, "{s}\n\nX-Event: {s}\n{s}", .{ head, kind, comment_line });
}

test "events" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(&.{}, 100, "Title\n\nOld text.\n\nState: open\nFormat-Version: 1\n");
    const c1 = try d.add(&.{root}, 200, "First comment\n\nwith text\n");
    const c2 = try d.add(&.{c1}, 300, "Second comment\n");
    const edit = try d.add(&.{c2}, 400, try eventMsg(
        &d,
        "Edit comment x\n\nFirst, edited\n\nnew text",
        "comment-edit",
        c1,
    ));
    const del = try d.add(&.{edit}, 500, try eventMsg(&d, "Delete comment", "comment-delete", c2));
    const desc = try d.add(&.{del}, 600, try eventMsg(
        &d,
        "Edit description\n\nNew description.",
        "description-edit",
        null,
    ));
    const gone = try d.add(&.{desc}, 700, "Delete issue\n\nX-Deleted: true\n");

    var i = try d.issue(gone);
    try testing.expect(i.deleted);
    try testing.expectEqualStrings("New description.", i.description);
    // c1, c2 and "Delete issue" (a field change, like "Close issue"). The
    // four event commits aren't comments.
    try testing.expectEqual(@as(usize, 3), i.comments.len);
    try testing.expect(i.comments[0].edited);
    try testing.expectEqualStrings("First, edited", i.comments[0].subject);
    try testing.expectEqualStrings("new text", i.comments[0].text[0]);
    try testing.expect(i.comments[1].deleted);
    try testing.expectEqual(@as(usize, 0), i.event_problems.len);
    try testing.expect(i.field("X-Event") == null and i.field("X-Comment") == null);

    const restore = try d.add(&.{gone}, 800, try eventMsg(&d, "Restore", "comment-restore", c2));
    const back = try d.add(&.{restore}, 900, "Restore issue\n\nX-Deleted: false\n");
    i = try d.issue(back);
    try testing.expect(!i.deleted);
    try testing.expect(!i.comments[1].deleted);
}

test "history: every version of the description and of each comment" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(&.{}, 100, "Title\n\nOld text.\n\nState: open\nFormat-Version: 1\n");
    const c1 = try d.add(&.{root}, 200, "First comment\n\nwith text\n");
    const e1 = try d.add(&.{c1}, 300, try eventMsg(&d, "Edit\n\nSecond take", "comment-edit", c1));
    const del = try d.add(&.{e1}, 400, try eventMsg(&d, "Delete comment", "comment-delete", c1));
    const back = try d.add(&.{del}, 500, try eventMsg(&d, "Restore", "comment-restore", c1));
    const desc = try d.add(&.{back}, 600, try eventMsg(
        &d,
        "Edit description\n\nNew description.",
        "description-edit",
        null,
    ));
    const i = try d.issue(desc);

    const dh = i.description_history;
    try testing.expectEqual(@as(usize, 2), dh.len);
    try testing.expectEqual(Revision.Kind.original, dh[0].kind);
    try testing.expectEqualStrings("Old text.", dh[0].text);
    try testing.expect(dh[0].oid.eql(d.commits.items[root].oid));
    try testing.expectEqualStrings("New description.", dh[1].text);
    try testing.expect(dh[1].oid.eql(d.commits.items[desc].oid));

    const h = i.comments[0].history;
    try testing.expectEqual(@as(usize, 4), h.len);
    try testing.expectEqualStrings("First comment\n\nwith text", h[0].text);
    try testing.expectEqual(Revision.Kind.edit, h[1].kind);
    try testing.expectEqualStrings("Second take", h[1].text);
    // Delete and restore keep the text they hide and show.
    try testing.expectEqual(Revision.Kind.delete, h[2].kind);
    try testing.expectEqualStrings("Second take", h[2].text);
    try testing.expectEqual(Revision.Kind.restore, h[3].kind);
    try testing.expect(h[3].oid.eql(d.commits.items[back].oid));
}

test "changes: what each commit changed" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(
        &.{},
        100,
        "T\n\nState: open\nLabels: bug, ui\nPriority: high\nFormat-Version: 1\n",
    );
    const a = try d.add(&.{root}, 200, "Update\n\nLabels: bug, api\nPriority: \n");
    const b = try d.add(&.{root}, 210, "Update\n\nX-Due-Date: 2026-12-01\n");
    // Merges both sides; restates nothing, so it changed nothing itself.
    const m = try d.add(&.{ a, b }, 300, "Merge issue\n");
    const i = try d.issue(m);

    const created = i.created_changes;
    try testing.expect(hasChange(created, "State", .set, null, "open"));
    try testing.expect(hasChange(created, "Labels", .add, null, "bug"));
    try testing.expect(hasChange(created, "Priority", .set, null, "high"));
    try testing.expect(!hasChange(created, "Format-Version", .set, null, "1"));

    const ca = i.comments[0].changes;
    try testing.expectEqual(@as(usize, 3), ca.len);
    try testing.expect(hasChange(ca, "Labels", .add, null, "api"));
    try testing.expect(hasChange(ca, "Labels", .remove, "ui", null));
    try testing.expect(hasChange(ca, "Priority", .clear, "high", null));
    const cb = i.comments[1].changes;
    try testing.expectEqual(@as(usize, 1), cb.len);
    try testing.expect(hasChange(cb, "X-Due-Date", .set, null, "2026-12-01"));
    try testing.expect(i.comments[2].is_merge);
    try testing.expectEqual(@as(usize, 0), i.comments[2].changes.len);

    try testing.expectEqual(@as(usize, 3), i.steps.len);
    try testing.expectEqual(@as(usize, 2), i.steps[2].what.comment);
}

fn hasChange(
    list: []const Change,
    key: []const u8,
    op: Change.Op,
    old: ?[]const u8,
    new: ?[]const u8,
) bool {
    const same = struct {
        fn f(x: ?[]const u8, y: ?[]const u8) bool {
            if (x == null or y == null) return x == null and y == null;
            return std.mem.eql(u8, x.?, y.?);
        }
    }.f;
    for (list) |c| if (std.mem.eql(
        u8,
        c.key,
        key,
    ) and c.op == op and same(c.old, old) and same(c.new, new))
        return true;
    return false;
}

test "assignees: upstream's Assignee sets them to one, a merge's restatement doesn't" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(
        &.{},
        100,
        "T\n\nState: open\nAssignee: a@e.x\nX-Assignees: a@e.x, b@e.x\nFormat-Version: 1\n",
    );
    var i = try d.issue(root);
    try testing.expectEqual(@as(usize, 2), i.assignees.len);
    // A merge restates only the first; the set stays.
    const side = try d.add(&.{root}, 200, "Update\n\nLabels: x\n");
    const other = try d.add(&.{root}, 210, "Update\n\nPriority: high\n");
    const m = try d.add(&.{ side, other }, 300, "Merge issue\n\nState: open\nAssignee: a@e.x\n");
    i = try d.issue(m);
    try testing.expectEqual(@as(usize, 2), i.assignees.len);
    // Upstream's edit names one: that's the set now.
    const up = try d.add(&.{m}, 400, "Update assignee\n\nAssignee: c@e.x\n");
    i = try d.issue(up);
    try testing.expectEqual(@as(usize, 1), i.assignees.len);
    try testing.expectEqualStrings("c@e.x", i.assignees[0].email);
}

test "event text with a divider line, and a lowercase description trailer" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(
        &.{},
        100,
        "T\n\nIntro\n\n---\n\nMore\n\nState: open\nFormat-Version: 1\n",
    );
    var i = try d.issue(root);
    try testing.expectEqualStrings("Intro\n\n---\n\nMore", i.description);
    // `---` doesn't end the text: the trailers after it are still fields,
    // so they aren't text.
    const desc = try d.add(&.{root}, 200, try eventMsg(
        &d,
        "Edit description\n\nOwner: bob\n\n---\n\nDetails",
        "description-edit",
        null,
    ));
    const c = try d.add(&.{desc}, 300, "Done\n\n---\n\nx\n\nState: closed\n");
    // Another tool's `description:` trailer is just a field.
    const foreign = try d.add(&.{c}, 400, "Note\n\ndescription: hijacked\n");
    i = try d.issue(foreign);
    try testing.expectEqualStrings("Owner: bob\n\n---\n\nDetails", i.description);
    try testing.expectEqualStrings("hijacked", i.field("description").?);
    try testing.expectEqual(core_fmt.State.closed, i.state);
    const close = i.comments[0];
    try testing.expectEqual(@as(usize, 3), close.body.len);
    try testing.expectEqualStrings("x", close.body[2]);
}

test "concurrent and bad events" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(&.{}, 100, "T\n\nState: open\nFormat-Version: 1\n");
    const c = try d.add(&.{root}, 200, "Comment\n");
    const left = try d.add(&.{c}, 300, try eventMsg(&d, "Edit\n\nLeft text", "comment-edit", c));
    const right = try d.add(&.{c}, 400, try eventMsg(&d, "Edit\n\nRight text", "comment-edit", c));
    // A delete concurrent with an edit: the later edit (400) wins and shows
    // the comment again.
    const merge = try d.add(&.{ left, right }, 500, "Merge issue\n\nState: open\n");
    var i = try d.issue(merge);
    try testing.expectEqualStrings("Right text", i.comments[0].subject);
    try testing.expectEqual(@as(usize, 1), i.conflicts.len);
    try testing.expect(i.conflicts[0].target == .comment);

    // Dangling target, the root, an event, and two events in one commit.
    const missing = "0f" ** 20;
    const dangling_msg = "Edit\n\nX\n\nX-Event: comment-edit\nX-Comment: " ++ missing ++ "\n";
    const bad1 = try d.add(&.{merge}, 600, dangling_msg);
    const bad2 = try d.add(&.{bad1}, 700, try eventMsg(&d, "Delete", "comment-delete", root));
    const bad3 = try d.add(&.{bad2}, 800, try eventMsg(&d, "Delete", "comment-delete", left));
    const two = "Two\n\nX-Event: description-edit\nX-Event: comment-delete\n";
    const bad4 = try d.add(&.{bad3}, 900, two);
    i = try d.issue(bad4);
    var dangling: usize = 0;
    var invalid: usize = 0;
    for (i.event_problems) |p| switch (p.kind) {
        .dangling => dangling += 1,
        .invalid => invalid += 1,
    };
    try testing.expectEqual(@as(usize, 1), dangling);
    try testing.expectEqual(@as(usize, 3), invalid);
    try testing.expectEqual(@as(usize, 2), i.comments.len); // the comment and the merge
}

test "attachments" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const id1 = "1b4e28ba-2fa1-4d3b-a3f5-ef19b5a7633b";
    const id2 = "2c5f39cb-3ab2-4e4c-b4a6-f02ac6b8744c";
    const h1 = " image/png 10 sha256:" ++ "a" ** 64 ++ " ";
    const h2 = " image/jpeg 20 sha256:" ++ "b" ** 64 ++ " ";
    const root = try d.add(&.{}, 100, "Crash\n\nState: open\nFormat-Version: 1\n");
    const c1 = try d.add(&.{root}, 200, "Here's a screenshot\n\n" ++
        "X-Attachment: " ++ id1 ++ h1 ++ "shot.png\n" ++
        "X-Attachment: " ++ id2 ++ h2 ++ "photo.jpg\n");
    const c2 = try d.add(
        &.{c1},
        300,
        "Rename attachment\n\nX-Attachment: " ++ id1 ++ h1 ++ "login.png\n",
    );
    const c3 = try d.add(&.{c2}, 400, "Remove attachment\n\nX-Attachment-Removed: " ++ id2 ++ "\n");
    // A different object under id1, and garbage. Both ignored and reported.
    const c4 = try d.add(&.{c3}, 500, "Bad\n\n" ++
        "X-Attachment: " ++ id1 ++ h2 ++ "other.jpg\n" ++
        "X-Attachment: nonsense\nX-Attachment-Removed: nope\n");
    var i = try d.issue(c4);
    try testing.expectEqual(@as(usize, 1), i.attachments.len);
    try testing.expectEqualStrings("login.png", i.attachments[0].name);
    try testing.expectEqual(attachment_fmt.Media.png, i.attachments[0].media);
    try testing.expect(i.attachments[0].added_in.eql(d.commits.items[c1].oid));
    try testing.expectEqual(@as(usize, 3), i.attachment_problems.len);
    try testing.expectEqual(AttachmentProblem.Kind.changed_object, i.attachment_problems[0].kind);
    try testing.expect(i.field("X-Attachment") == null);
    try testing.expectEqualStrings("Here's a screenshot", i.comments[0].subject);
    try testing.expectEqual(@as(usize, 1), i.comments[0].attachments.len);
    try testing.expectEqualStrings(id1, i.comments[0].attachments[0]);

    const c5 = try d.add(&.{c4}, 600, "Re-add\n\nX-Attachment: " ++ id2 ++ h2 ++ "photo.jpg\n");
    i = try d.issue(c5);
    try testing.expectEqual(@as(usize, 2), i.attachments.len);
}

test "attachment merges" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const id = "1b4e28ba-2fa1-4d3b-a3f5-ef19b5a7633b";
    const h = " image/png 10 sha256:" ++ "a" ** 64 ++ " ";
    const root = try d.add(&.{}, 100, "Crash\n\nState: open\nX-Attachment: " ++ id ++ h ++
        "a.png\nFormat-Version: 1\n");
    const removed = try d.add(&.{root}, 300, "Remove\n\nX-Attachment-Removed: " ++ id ++ "\n");
    const renamed = try d.add(&.{root}, 200, "Rename\n\nX-Attachment: " ++ id ++ h ++ "b.png\n");
    const merge = try d.add(&.{ removed, renamed }, 400, "Merge issue\n\nState: open\n");
    var i = try d.issue(merge);
    try testing.expectEqual(@as(usize, 1), i.attachments.len);
    try testing.expectEqualStrings("b.png", i.attachments[0].name);

    const r1 = try d.add(&.{merge}, 500, "Rename\n\nX-Attachment: " ++ id ++ h ++ "c.png\n");
    const r2 = try d.add(&.{merge}, 600, "Rename\n\nX-Attachment: " ++ id ++ h ++ "d.png\n");
    const m2 = try d.add(&.{ r1, r2 }, 700, "Merge issue\n\nState: open\n");
    i = try d.issue(m2);
    try testing.expectEqualStrings("d.png", i.attachments[0].name);

    const h2 = " image/jpeg 20 sha256:" ++ "b" ** 64 ++ " ";
    const other = "3d6a4adc-4bc3-4f5d-85b7-013bd7c9855d";
    const x1 = try d.add(&.{m2}, 800, "X\n\nX-Attachment: " ++ other ++ h ++ "first.png\n");
    const x2 = try d.add(&.{m2}, 900, "Y\n\nX-Attachment: " ++ other ++ h2 ++ "second.jpg\n");
    const m3 = try d.add(&.{ x2, x1 }, 1000, "Merge issue\n\nState: open\n");
    i = try d.issue(m3);
    try testing.expectEqual(@as(usize, 2), i.attachments.len);
    try testing.expectEqualStrings("first.png", i.attachments[1].name);
    try testing.expectEqual(@as(usize, 1), i.attachment_problems.len);
}

test "a skewed clock after a merge doesn't hide a concurrent setter" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const root = try d.add(&.{}, 100, "T\n\nState: open\nFormat-Version: 1\n");
    const x = try d.add(&.{root}, 300, "X\n\nPriority: high\n");
    const y = try d.add(&.{root}, 200, "Y\n\nPriority: medium\n");
    // Doesn't restate: x and y stay its latest setters, x wins.
    const both = try d.add(&.{ x, y }, 400, "Merge\n");
    try testing.expectEqualStrings("high", (try d.issue(both)).field("Priority").?);
    // After x only, with a clock behind y's: concurrent with y, y is newer.
    const after_x = try d.add(&.{x}, 50, "X2\n\nPriority: low\n");
    const i = try d.issue(try d.add(&.{ both, after_x }, 500, "Merge\n"));
    try testing.expectEqualStrings("medium", i.field("Priority").?);
    try testing.expectEqual(@as(usize, 1), i.conflicts.len);
    try testing.expectEqualStrings("low", i.conflicts[0].lost);
}

test "an attachment renamed on two branches survives a removal on one" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: TestDag = .{ .arena = arena_state.allocator() };
    const id = "1b4e28ba-2fa1-4d3b-a3f5-ef19b5a7633b";
    const h = " image/png 10 sha256:" ++ "a" ** 64 ++ " ";
    const root = try d.add(&.{}, 100, "Crash\n\nState: open\nX-Attachment: " ++ id ++ h ++
        "a.png\nFormat-Version: 1\n");
    const left = try d.add(&.{root}, 300, "Rename\n\nX-Attachment: " ++ id ++ h ++ "l.png\n");
    const right = try d.add(&.{root}, 200, "Rename\n\nX-Attachment: " ++ id ++ h ++ "r.png\n");
    const both = try d.add(&.{ left, right }, 400, "Merge\n");
    try testing.expectEqualStrings("l.png", (try d.issue(both)).attachments[0].name);
    // Removed after the left rename only: concurrent with the right one.
    const removed = try d.add(&.{left}, 500, "Remove\n\nX-Attachment-Removed: " ++ id ++ "\n");
    const i = try d.issue(try d.add(&.{ both, removed }, 600, "Merge\n"));
    try testing.expectEqual(@as(usize, 1), i.attachments.len);
    try testing.expectEqualStrings("r.png", i.attachments[0].name);
}

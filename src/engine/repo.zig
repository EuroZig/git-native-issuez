//! Reading and writing issues through a backend.
//!
//! Every write reads the tip, builds a new commit on top of it and moves
//! the ref only if it still points at that tip. If it moved, we start over
//! from the new tip. We never just re-point the old commit at the new
//! tip, which is how upstream's retry can lose a concurrent edit.

const std = @import("std");
const Allocator = std.mem.Allocator;
const contract = @import("../backend/contract.zig");
const object = @import("../backend/object.zig");
const trailers = @import("../format/trailers.zig");
const labels_fmt = @import("../format/labels.zig");
const uuid_fmt = @import("../format/uuid.zig");
const core_fmt = @import("../format/core.zig");
const attachment_fmt = @import("../format/attachment.zig");
const fields_fmt = @import("../format/fields.zig");
const settings_mod = @import("settings.zig");
const errors_mod = @import("errors.zig");
const issue_model = @import("../model/issue.zig");

pub const Issue = issue_model.Issue;
pub const Oid = object.Oid;
pub const Signature = object.Signature;

pub const issue_ref_prefix = "refs/issues/";
/// Milestones use the same engine.
pub const milestone_ref_prefix = "refs/milestones/";
/// Derived refs: LFS pointer trees, never the source of truth.
pub const attachment_ref_prefix = "refs/attachments/";
/// Local only, never pushed. A guard can pin what it read but not that
/// something is absent, like a child of the issue being closed. So writes
/// that add work under an issue or to a milestone move that ID's guard ref,
/// and so do the writes that need its absence: closing or deleting the
/// issue, completing the milestone. Two such writes then conflict.
pub const guard_ref_prefix = "refs/issuez-guard/";

/// `X-Message: comment`: the commit's text is a comment someone wrote,
/// whatever fields it also sets (format.md §2).
pub const message_key = "X-Message";
pub const message_comment = "comment";

/// A blob listing every issue's parent, so finding an issue's children
/// doesn't load every issue. Lines are `<id> <tip> -` (no parent) or
/// `<id> <tip> =<parent>`. An entry counts only while its tip is the
/// issue's, so a stale or broken cache costs loads, never a wrong answer.
/// Local, never pushed, can be deleted at any time.
pub const parent_cache_ref = "refs/issuez-cache/parents";

/// Internal: the library's own plumbing, not API; it may change.
/// The ref a write names: `ref_or_id` itself, or for a bare UUID the ref
/// under `prefix`. Every write that takes a ref name takes the ID too.
pub fn refFor(
    arena: Allocator,
    prefix: []const u8,
    ref_or_id: []const u8,
) Allocator.Error![]const u8 {
    if (!uuid_fmt.isCanonical(ref_or_id)) return ref_or_id;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, ref_or_id });
}

/// Every namespace of the library's refs, shared and local, as `dropAll`
/// empties them; the first four are the shared ones, as `adoptFrom` takes
/// them. Remote-tracking copies (`refs/remotes/`) aren't ours.
pub const all_ref_prefixes = [_][]const u8{
    issue_ref_prefix,
    milestone_ref_prefix,
    attachment_ref_prefix,
    "refs/issuez-purged/",
    guard_ref_prefix,
    "refs/issuez-cache/",
    "refs/issuez-sync/",
};
/// Version 2 adds each issue's number; older caches are rebuilt.
const parent_cache_header = "issuez-parents 2\n";
/// Stale or missing entries before the cache is rewritten.
const parent_cache_slack = 64;

/// What a builder's `guard` returns.
pub const Guarded = struct {
    /// Refs it read.
    verify: []const contract.RefUpdate = &.{},
    /// Guard refs to move to the new commit.
    bump: []const Bump = &.{},
    /// A refreshed `parent_cache_ref`, written once the write succeeded.
    parent_cache: ?ParentCache = null,

    pub const ParentCache = struct { old: ?Oid, text: []const u8 };

    pub const Bump = struct { name: []const u8, old: ?Oid };

    fn ops(
        g: Guarded,
        arena: Allocator,
        new: Oid,
    ) Allocator.Error![]const contract.RefUpdate {
        var out: std.ArrayList(contract.RefUpdate) = .empty;
        try out.appendSlice(arena, g.verify);
        for (g.bump) |b| try out.append(arena, .{ .name = b.name, .op = if (b.old) |old|
            .{ .update = .{ .new = new, .old = old } }
        else
            .{ .create = new } });
        return out.items;
    }
};

pub const Limits = struct {
    /// No truncation: more commits than this is an error.
    max_commits_per_issue: u32 = 10_000,
    /// Use `loadPage` beyond this.
    max_issues: u32 = 100_000,
    page_size: u32 = 1_000,
    cas_retries: u8 = 8,
    max_title_bytes: u32 = 1024,
    max_body_bytes: u32 = 1024 * 1024,
    max_trailer_value_bytes: u32 = 4096,
    max_labels: u16 = 64,
    max_blockers: u16 = 256,
    max_assignees: u16 = 64,
    /// For our writes. A root has depth 0.
    max_depth: u8 = 8,
    max_guard_scan: u32 = 100_000,
    max_attachments: u16 = attachment_fmt.max_per_issue,
    max_attachment_bytes: u32 = attachment_fmt.max_bytes,

    /// So no limit can be raised to the point of meaning nothing.
    pub const maximum: Limits = .{
        .max_commits_per_issue = 1_000_000,
        .max_issues = 10_000_000,
        .page_size = 100_000,
        .cas_retries = 64,
        .max_title_bytes = 64 * 1024,
        .max_body_bytes = 64 * 1024 * 1024,
        .max_trailer_value_bytes = 64 * 1024,
        .max_labels = 4096,
        .max_blockers = 4096,
        .max_assignees = 4096,
        .max_depth = 64,
        .max_guard_scan = 10_000_000,
        .max_attachments = 1000,
        .max_attachment_bytes = attachment_fmt.max_object_bytes,
    };

    pub fn valid(l: Limits) bool {
        inline for (std.meta.fields(Limits)) |f| {
            const v = @field(l, f.name);
            if (v == 0 or v > @field(maximum, f.name)) return false;
        }
        return true;
    }

    comptime {
        std.debug.assert((Limits{}).valid());
    }
};

pub const IssueRef = struct {
    name: []const u8,
    tip: Oid,

    /// Also works for `refs/milestones/`.
    pub fn id(r: IssueRef) []const u8 {
        const slash = std.mem.findScalarLast(u8, r.name, '/') orelse return r.name;
        return r.name[slash + 1 ..];
    }
};

pub const Resolution = union(enum) {
    none,
    one: IssueRef,
    many: []const IssueRef,
};

pub const CreateSpec = struct {
    title: []const u8,
    body: []const u8 = "",
    labels: []const []const u8 = &.{},
    /// In order. A host's user UUID goes beside the email (`<uuid> <email>`).
    assignees: []const fields_fmt.Assignee = &.{},
    priority: ?core_fmt.Priority = null,
    /// `link = .pin` doesn't go with create (there is nothing to pin).
    milestone: ?MilestoneEdit = null,
    // References are full UUIDs. Callers resolve short IDs first.
    parent: ?[]const u8 = null,
    blocked_by: []const []const u8 = &.{},
    start_date: ?fields_fmt.Date = null,
    due_date: ?fields_fmt.Date = null,
    estimate_minutes: ?u32 = null,
    /// Callers check it against the configured workflow states.
    workflow: ?[]const u8 = null,
    /// `X-Number`, unique in this clone (format.md §3).
    number: ?u64 = null,
    /// Host fields, as `extra` in `EditSpec`.
    extra: []const HostField = &.{},
    /// Images on the root commit, e.g. the description's.
    attachments: []const attachment_fmt.Spec = &.{},
    original: Original = .{},
    /// Overrides the backend's identity.
    author: ?Signature = null,
    /// The state it starts in, on its root: imports bring closed issues.
    state: core_fmt.State = .open,
    /// With a done state, like `StateSpec`'s.
    fixed_by: ?[]const u8 = null,
    release: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

/// Every spec has `expect`: the tip the caller based the change on (an
/// ETag, say). If the issue has changed since, the write fails with
/// VersionMismatch instead of being applied on top.
pub const CommentSpec = struct {
    text: []const u8,
    original: Original = .{},
    author: ?Signature = null,
    expect: ?Oid = null,
};

/// Where imported text came from: per-commit `X-Original-Author` and
/// `X-Original-Id` (format.md §2), not issue fields.
pub const Original = struct {
    author: ?[]const u8 = null,
    id: ?[]const u8 = null,

    fn trailerList(
        o: Original,
        arena: Allocator,
        list: *std.ArrayList(trailers.Trailer),
    ) Allocator.Error!void {
        if (o.author) |v| try list.append(arena, .{ .key = "X-Original-Author", .value = v });
        if (o.id) |v| try list.append(arena, .{ .key = "X-Original-Id", .value = v });
    }
};

/// A host's own field: any `X-` key the format doesn't use. "" clears.
pub const HostField = issue_model.Field;

/// Images a write adds or removes in its own commit (format.md §7), so a
/// comment, a new issue or an edit carries them. The bytes are stored
/// before the write, by `Attachments.storeBytes` or by a host that keeps
/// them in its own LFS store. Build the specs with `Attachments.prepare`.
pub const AttachmentChanges = struct {
    add: []const attachment_fmt.Spec = &.{},
    /// UUIDs of present attachments.
    remove: []const []const u8 = &.{},

    pub fn isEmpty(c: AttachmentChanges) bool {
        return c.add.len == 0 and c.remove.len == 0;
    }

    /// Against the issue as the write finds it, on every attempt.
    pub fn check(c: AttachmentChanges, current: Issue, limits: Limits) error{
        AttachmentNotFound,
        AttachmentExists,
        TooManyAttachments,
    }!void {
        for (c.remove) |id| if (!hasAttachment(current.attachments, id))
            return error.AttachmentNotFound;
        for (c.add, 0..) |a, i| {
            if (hasAttachment(current.attachments, a.id) or
                hasAttachment(current.removed_attachments, a.id)) return error.AttachmentExists;
            for (c.add[0..i]) |o| if (std.mem.eql(u8, o.id, a.id)) return error.AttachmentExists;
        }
        // Removing must work on an issue over the limit, e.g. after
        // concurrent adds.
        const count = current.attachments.len - @min(c.remove.len, current.attachments.len) +
            c.add.len;
        if (c.add.len > 0 and count > limits.max_attachments) return error.TooManyAttachments;
    }

    fn trailerList(
        c: AttachmentChanges,
        arena: Allocator,
        list: *std.ArrayList(trailers.Trailer),
    ) Allocator.Error!void {
        for (c.add) |a| try list.append(arena, .{
            .key = attachment_fmt.add_key,
            .value = try std.fmt.allocPrint(arena, "{f}", .{a}),
        });
        for (c.remove) |id| try list.append(
            arena,
            .{ .key = attachment_fmt.remove_key, .value = id },
        );
    }

    /// The default subject of a commit that only changes attachments, as
    /// `Attachments.add` and `remove` write them.
    fn subject(c: AttachmentChanges) []const u8 {
        if (c.remove.len == 0) return if (c.add.len == 1) "Add attachment" else "Add attachments";
        if (c.add.len == 0)
            return if (c.remove.len == 1) "Remove attachment" else "Remove attachments";
        return "Update attachments";
    }
};

fn hasAttachment(list: []const issue_model.Attachment, id: []const u8) bool {
    for (list) |a| if (std.mem.eql(u8, a.id, id)) return true;
    return false;
}

/// A reaction of the author's, on the issue (`target` null) or a comment.
pub const ReactSpec = struct {
    target: ?Oid = null,
    /// `:+1:` or the character: 1 to 64 bytes, no whitespace or commas.
    emoji: []const u8,
    /// false takes it back.
    present: bool = true,
    author: ?Signature = null,
    expect: ?Oid = null,
};

pub const StateSpec = struct {
    /// `.other` takes letters, digits, `-` and `_`, like upstream.
    state: core_fmt.State,
    /// Defaults to "Close issue", "Reopen issue", ...
    message: ?[]const u8 = null,
    fixed_by: ?[]const u8 = null,
    release: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    author: ?Signature = null,
    expect: ?Oid = null,
};

/// An issue's milestone (format.md §3): the `Milestone:` text, the catalog
/// link (`X-Milestone-Id`) and how it follows the parent's
/// (`X-Milestone-Mode`). `Catalog.choose` turns a name into one the way
/// `--milestone` does.
pub const MilestoneEdit = struct {
    /// The `Milestone:` text; "" clears it. Null: as it is, or the catalog
    /// milestone's name with `link = .id`, which doesn't go with a text.
    text: ?[]const u8 = null,
    link: Link = .keep,

    pub const Link = union(enum) {
        /// The link and mode as they are.
        keep,
        /// A catalog milestone, by full ID: mode `explicit`, its name as
        /// the text. It must be open.
        id: []const u8,
        /// Mode `explicit` on the catalog milestone the issue already has.
        pin,
        /// Follow the parent's milestone; drops the link (and the text,
        /// unless one is given).
        inherit,
        /// No milestone, not even the parent's; drops the link (and the
        /// text, unless one is given).
        none,
    };

    /// A name written as plain text, no catalog link.
    pub fn named(text: []const u8) MilestoneEdit {
        return .{ .text = text };
    }

    pub fn linked(id: []const u8) MilestoneEdit {
        return .{ .link = .{ .id = id } };
    }

    /// The parts as the trailers have them; null leaves one alone.
    pub const Parts = struct {
        text: ?[]const u8 = null,
        id: ?[]const u8 = null,
        mode: ?fields_fmt.MilestoneMode = null,
    };

    /// From the trailers' parts, as `Catalog.choose` and the CLI's flags
    /// give them; null when none is set.
    pub fn fromParts(p: Parts) ?MilestoneEdit {
        if (p.text == null and p.id == null and p.mode == null) return null;
        if (p.id) |id| return .linked(id);
        return .{ .text = p.text, .link = if (p.mode) |m| switch (m) {
            .explicit => .pin,
            .inherit => .inherit,
            .none => .none,
        } else .keep };
    }

    /// The trailers' parts `m` writes; all null for null.
    pub fn toParts(m: ?MilestoneEdit) Parts {
        const e = m orelse return .{};
        return .{
            .text = e.text,
            .id = if (e.link == .id) e.link.id else null,
            .mode = switch (e.link) {
                .keep => null,
                .id, .pin => .explicit,
                .inherit => .inherit,
                .none => .none,
            },
        };
    }
};

/// A field an edit sets or clears; null in a spec leaves it alone.
pub fn Edit(comptime T: type) type {
    return union(enum) {
        set: T,
        clear,

        /// For text input where empty means clear (a form field, a JSON
        /// string); null leaves the field alone.
        pub fn fromInput(v: ?T) ?@This() {
            if (T != []const u8) @compileError("fromInput is for text fields");
            const t = v orelse return null;
            return if (t.len == 0) .clear else .{ .set = t };
        }
    };
}

pub const EditSpec = struct {
    title: ?[]const u8 = null,
    /// Replaces the labels.
    set_labels: ?[]const []const u8 = null,
    add_labels: []const []const u8 = &.{},
    remove_labels: []const []const u8 = &.{},
    /// Replaces the assignees (`&.{}` unassigns everyone), then
    /// `add_assignees`, then `remove_assignees`.
    set_assignees: ?[]const fields_fmt.Assignee = null,
    add_assignees: []const fields_fmt.Assignee = &.{},
    /// By email.
    remove_assignees: []const []const u8 = &.{},
    priority: ?PriorityEdit = null,
    milestone: ?MilestoneEdit = null,
    // null leaves a field alone, `.clear` clears it.
    parent: ?TextEdit = null,
    set_blocked_by: ?[]const []const u8 = null,
    add_blocked_by: []const []const u8 = &.{},
    remove_blocked_by: []const []const u8 = &.{},
    start_date: ?DateEdit = null,
    due_date: ?DateEdit = null,
    estimate_minutes: ?EstimateEdit = null,
    workflow: ?TextEdit = null,
    /// Replaces the description, in the same commit as the other changes:
    /// a `description-edit` event that also sets their fields.
    description: ?[]const u8 = null,
    /// The subject. With a description it can't have a body.
    message: ?[]const u8 = null,
    /// A state change in the same commit, with its details, guarded like
    /// `setState`.
    state: ?core_fmt.State = null,
    fixed_by: ?[]const u8 = null,
    release: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    /// A comment in the same commit: the commit's text, marked
    /// `X-Message: comment` so it reads as one with the fields beside it.
    /// Not with a description (an event's text is the description) or a
    /// message.
    comment: ?[]const u8 = null,
    /// `X-Number`, written once: a different number is NumberAlreadySet,
    /// the same one changes nothing.
    number: ?u64 = null,
    /// `X-Locked`, with `lock_reason` (unlocking clears the reason).
    locked: ?bool = null,
    lock_reason: ?[]const u8 = null,
    /// `X-Ref`, a branch or tag.
    ref: ?TextEdit = null,
    /// Host fields (`X-Forgejo-...`): `X-` keys the format doesn't use.
    extra: []const HostField = &.{},
    /// Images added or removed in this commit, beside a comment, a new
    /// description or other changes, or alone.
    attachments: AttachmentChanges = .{},
    /// Provenance of this commit, for imports.
    original: Original = .{},
    author: ?Signature = null,
    expect: ?Oid = null,

    /// The targeted text must have this many edits, checked on every retry.
    /// With `description`, or `Update.comment_event` for a comment edit.
    expect_edits: ?u32 = null,

    pub const EstimateEdit = Edit(u32);
    pub const PriorityEdit = Edit(core_fmt.Priority);
    pub const DateEdit = Edit(fields_fmt.Date);
    /// An issue ID, a workflow state or a ref name.
    pub const TextEdit = Edit([]const u8);

    /// As the trailer has it: "" for `.clear`.
    fn textOf(e: ?TextEdit) ?[]const u8 {
        const v = e orelse return null;
        return switch (v) {
            .set => |t| t,
            .clear => "",
        };
    }

    pub fn isEmpty(spec: EditSpec) bool {
        return spec.title == null and spec.set_labels == null and spec.add_labels.len == 0 and
            spec.remove_labels.len == 0 and spec.priority == null and
            spec.set_assignees == null and spec.add_assignees.len == 0 and
            spec.remove_assignees.len == 0 and
            spec.milestone == null and spec.parent == null and spec.set_blocked_by == null and
            spec.add_blocked_by.len == 0 and spec.remove_blocked_by.len == 0 and
            spec.start_date == null and spec.due_date == null and
            spec.estimate_minutes == null and spec.workflow == null and
            spec.description == null and
            spec.state == null and spec.comment == null and spec.number == null and
            spec.locked == null and spec.ref == null and spec.extra.len == 0 and
            spec.attachments.isEmpty();
    }
};

fn dateText(arena: Allocator, d: fields_fmt.Date) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{f}", .{d});
}

pub const Change = enum {
    title,
    labels,
    assignee,
    priority,
    milestone,
    parent,
    blockers,
    start_date,
    due_date,
    estimate,
    workflow,
    description,
    state,
    comment,
    number,
    lock,
    ref,
    fields,
    attachments,

    /// For default subjects like "Update title, due date".
    pub fn name(c: Change) []const u8 {
        return switch (c) {
            .start_date => "start date",
            .due_date => "due date",
            else => @tagName(c),
        };
    }
};

/// The `X-Event`s that target a comment.
pub const CommentEvent = enum {
    edit,
    delete,
    restore,

    pub fn event(e: CommentEvent) fields_fmt.Event {
        return switch (e) {
            .edit => .comment_edit,
            .delete => .comment_delete,
            .restore => .comment_restore,
        };
    }
};

/// `id` is the full UUID, what `find`, `resolve` and every write take.
pub const Created = struct { id: []const u8, tip: Oid };

/// What `setDeleted` takes.
pub const DeleteSpec = struct {
    /// false restores the issue.
    deleted: bool = true,
    /// Defaults to "Delete issue" or "Restore issue".
    message: ?[]const u8 = null,
    author: ?Signature = null,
    expect: ?Oid = null,
};

/// What `commentEvent` takes: a comment's edit, delete or restore.
pub const CommentEventSpec = struct {
    /// The full ID of the comment's commit.
    target: Oid,
    event: CommentEvent,
    /// An edit's new text; it replaces the whole text. Unused otherwise.
    text: []const u8 = "",
    /// Defaults to "Edit comment", "Delete comment", ...
    message: ?[]const u8 = null,
    /// Edits only: images added or removed with the new text.
    attachments: AttachmentChanges = .{},
    author: ?Signature = null,
    expect: ?Oid = null,
    /// Edits: unrelated field changes may still be retried.
    expect_edits: ?u32 = null,
};

/// The write bodies' common part.
const LifecycleSpec = struct {
    /// Defaults to "Delete issue", "Edit description", ...
    message: ?[]const u8 = null,
    /// Comment edits only: images added or removed with the new
    /// text.
    attachments: AttachmentChanges = .{},
    author: ?Signature = null,
    expect: ?Oid = null,
    /// Comment edits: unrelated field changes may still be retried.
    expect_edits: ?u32 = null,
};

/// One write to an issue, whatever it changes: what `update` takes.
pub const Update = struct {
    /// Fields, a comment, a description edit, a state change, images:
    /// one commit. `edit.message` is the subject where the library
    /// picks one, `edit.author` and `edit.expect` hold for every
    /// kind below.
    edit: EditSpec = .{},
    /// A comment's edit (`edit.comment` its new text, with
    /// `edit.attachments`), delete or restore instead.
    comment_event: ?struct { target: Oid, event: CommentEvent } = null,
    /// Soft-deletes (true) or restores the issue: a commit of its own.
    deleted: ?bool = null,
    /// A reaction instead, on the issue (`target` null) or a comment;
    /// `present` false takes it back.
    reaction: ?struct {
        target: ?Oid = null,
        emoji: []const u8,
        present: bool = true,
    } = null,
};

/// What a write did.
pub const Receipt = struct {
    /// The issue's tip after it: the commit it made, or the tip as
    /// it was when it changed nothing.
    tip: Oid,
    /// false: nothing changed, no commit.
    wrote: bool,
    /// Attempts after the first, when other writes raced it.
    retries: u32,
    kind: Kind,
    /// What an edit changed, by field; empty for the other kinds.
    changes: []const Change = &.{},

    pub const Kind = enum {
        update,
        comment,
        description_edit,
        comment_edit,
        comment_delete,
        comment_restore,
        deleted,
        reaction,
    };
};

pub const WriteOptions = struct {
    /// The author's host UUID, as `X-Author-Id` on the commit.
    author_id: ?[]const u8 = null,
    /// Run every check, guards too, and write nothing.
    dry_run: bool = false,
    /// Where the write says what it refused.
    diagnostics: ?*errors_mod.Diagnostics = null,
};

pub fn Repo(comptime B: type) type {
    contract.assertBackend(B);
    return struct {
        const Self = @This();

        backend: *B,
        limits: Limits = .{},
        /// What git config said, from `open`; the defaults from `init`.
        settings: settings_mod.Settings = .{},
        /// What one call carries, set from its `WriteOptions` by `update`
        /// and by the parts built on a repo. Not for callers: pass
        /// `WriteOptions` and read the `Receipt`.
        call: Call = .{},

        pub const Call = struct {
            /// Where a write says what it refused.
            diagnostics: ?*errors_mod.Diagnostics = null,
            /// Keeps `refs` from listing the issues again within one call,
            /// like resolving a prefix and then a write's guards. A write
            /// clears it first, so every attempt after the first lists
            /// afresh.
            listing: ?*Listing = null,
            /// How many times the write retried after a concurrent change.
            retries: ?*u32 = null,
            /// Whether the write changed nothing, so wrote no commit.
            skipped: ?*bool = null,
            /// The host's UUID of the author, as `X-Author-Id`.
            author_id: ?[]const u8 = null,
            /// Every check, guards too, and no ref update.
            dry_run: bool = false,
        };

        pub const Listing = struct { refs: ?[]const IssueRef = null };

        /// Internal: the library's own plumbing, not API; it may change.
        /// This repo with `options` for its next write, on top of what it
        /// carries already: how every write and the parts built on a repo
        /// take their `WriteOptions`.
        pub fn withOptions(self: Self, options: WriteOptions) Self {
            var me = self;
            me.call.author_id = options.author_id orelse self.call.author_id;
            me.call.dry_run = options.dry_run or self.call.dry_run;
            me.call.diagnostics = options.diagnostics orelse self.call.diagnostics;
            return me;
        }

        /// Besides `closed`. See `core.State.isDone`.
        pub fn doneStates(self: Self) []const []const u8 {
            return self.settings.done_states;
        }

        /// What writes may set `workflow` to; null when
        /// `issue.workflowStates` is invalid, so such writes fail with
        /// InvalidWorkflowStates.
        pub fn workflowStates(self: Self) ?[]const []const u8 {
            const s = self.settings;
            return if (s.invalid_workflow_state != null) null else s.workflow_states;
        }

        /// What reading issues fails with.
        pub const ReadError = error{
            /// Over the guard scan's bound (`Limits`): too many issues to
            /// check a hierarchy rule.
            GuardScanTooLarge,
            /// More commits than `Limits.max_commits_per_issue`.
            HistoryTooLong,
            /// A reachable object is missing or isn't a commit.
            CorruptIssue,
            /// Use `loadPage`.
            TooManyIssues,
            InvalidLimits,
            /// Not `refs/issues/<valid ref component>`, or `refs/milestones/`
            /// for the catalog's writes.
            InvalidIssueRef,
        };

        /// A value the format or a limit refuses: a write's input is wrong.
        pub const FormatError = error{
            /// A newline in a field, or similar.
            InvalidText,
            /// The text's last paragraph would read as trailers.
            BodyLooksLikeTrailers,
            /// Over a `Limits` bound.
            TooLong,
            TooManyLabels,
            TooManyBlockers,
            TooManyAssignees,
            NothingToEdit,
            /// `editBatch` with two edits of one issue.
            DuplicateEdit,
            /// A title or a comment's text that is empty or only whitespace.
            EmptyText,
            /// A label with a comma (the separator) or a newline.
            InvalidLabel,
            /// Not one of `workflow_states`.
            UnknownWorkflowState,
            /// `workflow_states` is null: `issue.workflowStates` is invalid.
            InvalidWorkflowStates,
            /// `EditSpec.message` with a blank line, and a description: the
            /// description is the body, so the message is only the subject.
            MessageHasBody,
            /// `EditSpec.comment` with a description or a message.
            CommentNotAlone,
            /// A value the format or upstream doesn't allow, like an unknown
            /// priority or a reference that isn't a full UUID.
            InvalidValue,
        };

        /// A hierarchy, milestone or number rule refuses the write.
        pub const GuardError = error{
            /// The issue has another number already: numbers are written once.
            NumberAlreadySet,
            /// Another issue here has that number.
            NumberTaken,
            /// A parent or blocker that isn't here.
            ReferenceNotFound,
            ParentIsSelf,
            /// The new parent is the issue itself or below it.
            ParentCycle,
            /// Deeper than `Limits.max_depth`, counting the subtree.
            TooDeep,
            BlocksItself,
            /// The new blocker is (transitively) blocked by this issue.
            BlockerCycle,
            /// Closing an issue with open descendants.
            OpenDescendants,
            /// Open work under a closed ancestor. Reopen the ancestors first.
            ClosedAncestor,
            /// Deleting an issue whose sub-issues aren't deleted.
            ActiveChildren,
            /// Creating or moving under a deleted parent. Restoring a child
            /// under one is allowed.
            ParentDeleted,
            /// Not a comment of this issue: the root, a merge, an event, or
            /// not in its history.
            CommentNotFound,
            /// Selecting a completed milestone, or open work ending up in
            /// one.
            MilestoneCompleted,
            MilestoneRetired,
            /// Completing a milestone with open work.
            OpenWorkInMilestone,
        };

        /// The repository moved under the write, or there is no identity.
        pub const RaceError = error{
            /// Out of compare-and-swap retries.
            ConcurrentModification,
            /// The issue ref went away during a write.
            IssueDisappeared,
            IdentityUnknown,
            /// The tip is no longer the `expect`ed one.
            VersionMismatch,
        };

        /// An image refused or not stored.
        pub const AttachmentError = error{
            /// The backend has no LFS store.
            AttachmentsUnsupported,
            /// git-lfs isn't installed.
            LfsUnavailable,
            /// Not a PNG, JPEG or WebP.
            UnsupportedType,
            AnimatedImage,
            /// The given media type doesn't match the bytes.
            MediaMismatch,
            /// Over `Limits.max_attachment_bytes`.
            AttachmentTooLarge,
            EmptyAttachment,
            TooManyAttachments,
            AttachmentNotFound,
            NoAttachments,
            /// An attachment UUID the issue has, or had, already.
            AttachmentExists,
        };

        /// Reads: the backend's errors, the read set and malformed history.
        pub const LoadError = B.Error || ReadError || issue_model.Error;

        /// Every write: a union of the area sets, so a `switch` can
        /// handle an area (`FormatError`, `GuardError`, ...) at once.
        pub const Error = LoadError || FormatError || GuardError || RaceError ||
            AttachmentError;

        pub fn init(backend: *B) Self {
            return .{ .backend = backend };
        }

        pub const OpenError = B.Error || Allocator.Error || error{InvalidDoneStates};

        /// A repo over `backend` with git config's issue settings applied
        /// (`settings`): what every front end wants. An `issue.doneStates`
        /// that isn't valid is InvalidDoneStates, since done-ness would be
        /// wrong everywhere (`settings.done_states_rule` says why); a bad
        /// `issue.workflowStates` only fails writes that set one.
        pub fn open(arena: Allocator, backend: *B) OpenError!Self {
            return fromSettings(backend, try settings_mod.read(B, arena, backend));
        }

        /// `open` with settings the caller read (`settings.fromConfig`).
        pub fn fromSettings(
            backend: *B,
            settings: settings_mod.Settings,
        ) error{InvalidDoneStates}!Self {
            if (settings.invalid_done_state != null) return error.InvalidDoneStates;
            var r: Self = .init(backend);
            r.settings = settings;
            return r;
        }

        /// Internal: the library's own plumbing, not API; it may change.
        /// Reads the guard ref of `id`, to move it in the same transaction.
        pub fn readGuardRef(
            self: Self,
            arena: Allocator,
            id: []const u8,
        ) (B.Error || Allocator.Error)!Guarded.Bump {
            const name = try std.fmt.allocPrint(arena, "{s}{s}", .{ guard_ref_prefix, id });
            return .{ .name = name, .old = try self.backend.resolveRef(name) };
        }

        /// `closed` or one of `done_states`.
        pub fn isDone(self: Self, issue: Issue) bool {
            return issue.state.isDone(self.doneStates());
        }

        /// Sorted by name, so by UUID.
        pub fn refs(self: Self, arena: Allocator) LoadError![]const IssueRef {
            if (self.call.listing) |l| if (l.refs) |r| return r;
            const entries = try self.backend.listRefs(arena, issue_ref_prefix);
            const out = try arena.alloc(IssueRef, entries.len);
            for (entries, out) |e, *r| r.* = .{ .name = e.name, .tip = e.oid };
            if (self.call.listing) |l| l.refs = out;
            return out;
        }

        fn forgetListing(self: Self) void {
            if (self.call.listing) |l| l.refs = null;
        }

        /// Like upstream's `refs/issues/<prefix>*`. A full UUID is looked up
        /// directly, without listing every issue.
        pub fn resolve(self: Self, arena: Allocator, prefix: []const u8) LoadError!Resolution {
            // `#12`: by `X-Number`, through the parents cache.
            if (prefix.len > 0 and prefix[0] == '#') {
                const n = fields_fmt.parseNumber(prefix[1..]) orelse return .none;
                const owners = try self.findNumber(arena, n);
                return switch (owners.len) {
                    0 => .none,
                    1 => .{ .one = owners[0] },
                    else => .{ .many = owners },
                };
            }
            if (uuid_fmt.isCanonical(prefix)) {
                const name = try refNameOf(arena, prefix);
                const tip = (try self.backend.resolveRef(name)) orelse return .none;
                return .{ .one = .{ .name = name, .tip = tip } };
            }
            const all = try self.refs(arena);
            var matches: std.ArrayList(IssueRef) = .empty;
            for (all) |r| if (std.mem.startsWith(u8, r.id(), prefix)) try matches.append(arena, r);
            return switch (matches.items.len) {
                0 => .none,
                1 => .{ .one = matches.items[0] },
                else => .{ .many = matches.items },
            };
        }

        pub fn load(self: Self, arena: Allocator, ref: IssueRef) LoadError!Issue {
            const commits = try self.loadCommits(arena, ref.tip);
            return issue_model.materialize(arena, ref.id(), ref.tip, commits);
        }

        /// The issue with this full UUID; null when there is none.
        pub fn find(self: Self, arena: Allocator, id: []const u8) LoadError!?Issue {
            const name = try refFor(arena, issue_ref_prefix, id);
            const tip = (try self.backend.resolveRef(name)) orelse return null;
            return try self.load(arena, .{ .name = name, .tip = tip });
        }

        pub fn loadAll(self: Self, arena: Allocator) LoadError![]Issue {
            try self.checkLimits();
            const all = try self.refs(arena);
            if (all.len > self.limits.max_issues) return error.TooManyIssues;
            const issues = try arena.alloc(Issue, all.len);
            for (all, issues) |r, *i| i.* = try self.load(arena, r);
            return issues;
        }

        /// For guards: issues that can't be loaded are skipped (fsck reports
        /// them), and at most `Limits.max_guard_scan` are read.
        pub fn loadForGuards(self: Self, arena: Allocator) LoadError![]Issue {
            const all = try self.refs(arena);
            if (all.len > self.limits.max_guard_scan) return error.GuardScanTooLarge;
            var out: std.ArrayList(Issue) = .empty;
            for (all) |r| {
                try out.append(arena, self.load(arena, r) catch |err| switch (err) {
                    error.CorruptIssue,
                    error.HistoryTooLong,
                    error.MissingParent,
                    error.NoRoot,
                    => continue,
                    else => |e| return e,
                });
            }
            return out.items;
        }

        /// What `projection.build` needs to project one issue as it would
        /// among all of them: the issue, its ancestors, its descendants and
        /// every issue its blockers lead to. Sub-issues come from
        /// `parent_cache_ref`, which this refreshes when stale (best effort).
        /// An event whose comment is missing may target another issue's
        /// comment, and then it is every issue. Other issues that can't be
        /// loaded are left out, as in the guards.
        pub fn loadAround(self: Self, arena: Allocator, ref: IssueRef) LoadError![]Issue {
            try self.checkLimits();
            const center = try self.load(arena, ref);
            // Skipping what can't be loaded, like the rest of this.
            for (center.event_problems) |ep| {
                if (ep.kind == .dangling) return self.loadForGuards(arena);
            }

            var out: std.ArrayList(Issue) = .empty;
            var have: std.StringHashMapUnmanaged(void) = .empty;
            try out.append(arena, center);
            try have.put(arena, center.id, {});
            const Add = struct {
                fn f(
                    o: *std.ArrayList(Issue),
                    h: *std.StringHashMapUnmanaged(void),
                    a: Allocator,
                    issue: Issue,
                ) !void {
                    if ((try h.getOrPut(a, issue.id)).found_existing) return;
                    try o.append(a, issue);
                }
            }.f;

            // Up. Each walk has its own `seen`: in a parent cycle the
            // ancestors are descendants too.
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            try seen.put(arena, center.id, {});
            var up = center.parent;
            while (up) |id| {
                if ((try seen.getOrPut(arena, id)).found_existing) break;
                const issue = (try self.loadById(arena, id)) orelse break;
                try Add(&out, &have, arena, issue);
                up = issue.parent;
            }

            // Down.
            const index = try self.childIndex(arena);
            if (index.refreshed) |c| self.writeParentCache(c);
            seen.clearRetainingCapacity();
            try seen.put(arena, center.id, {});
            var stack: std.ArrayList([]const u8) = .empty;
            try stack.append(arena, center.id);
            while (stack.pop()) |id| {
                const kids = index.children.get(id) orelse continue;
                for (kids.items) |r| {
                    if ((try seen.getOrPut(arena, r.id())).found_existing) continue;
                    const issue = index.loaded.get(r.id()) orelse
                        self.load(arena, r) catch |err| switch (err) {
                        error.CorruptIssue,
                        error.HistoryTooLong,
                        error.MissingParent,
                        error.NoRoot,
                        => continue,
                        else => |e| return e,
                    };
                    try Add(&out, &have, arena, issue);
                    try stack.append(arena, issue.id);
                }
            }

            // Along the blockers, for cycles through this issue.
            seen.clearRetainingCapacity();
            try seen.put(arena, center.id, {});
            var blocked: std.ArrayList(Issue) = .empty;
            try blocked.append(arena, center);
            while (blocked.pop()) |x| for (x.blocked_by) |id| {
                if ((try seen.getOrPut(arena, id)).found_existing) continue;
                const issue = (try self.loadById(arena, id)) orelse continue;
                try Add(&out, &have, arena, issue);
                try blocked.append(arena, issue);
            };

            // Whoever shares a number with one of them: a duplicate is a
            // problem of both.
            const loaded = out.items.len;
            for (0..loaded) |k| {
                const n = out.items[k].number orelse continue;
                const owners = index.numbers.get(n) orelse continue;
                for (owners.items) |r| {
                    if (have.contains(r.id())) continue;
                    const issue = index.loaded.get(r.id()) orelse
                        self.load(arena, r) catch |err| switch (err) {
                        error.CorruptIssue,
                        error.HistoryTooLong,
                        error.MissingParent,
                        error.NoRoot,
                        => continue,
                        else => |e| return e,
                    };
                    try Add(&out, &have, arena, issue);
                }
            }
            return out.items;
        }

        /// Null when there's no such issue, or it can't be loaded.
        fn loadById(self: Self, arena: Allocator, id: []const u8) LoadError!?Issue {
            if (!uuid_fmt.isCanonical(id)) return null;
            const name = try refNameOf(arena, id);
            const tip = (try self.backend.resolveRef(name)) orelse return null;
            return self.load(arena, .{ .name = name, .tip = tip }) catch |err| switch (err) {
                error.CorruptIssue,
                error.HistoryTooLong,
                error.MissingParent,
                error.NoRoot,
                => null,
                else => |e| return e,
            };
        }

        pub const Page = struct {
            issues: []Issue,
            /// Null on the last page.
            next: ?[]const u8,
        };

        pub const PageOptions = struct {
            /// Start after this issue ID; null: the first page.
            after: ?[]const u8 = null,
            /// Defaults to, and is capped by, `Limits.page_size`.
            limit: ?u32 = null,
        };

        /// In ID order (`PageOptions`).
        pub fn loadPage(
            self: Self,
            arena: Allocator,
            options: PageOptions,
        ) LoadError!Page {
            const after = options.after;
            const limit = options.limit;
            try self.checkLimits();
            const size = @min(limit orelse self.limits.page_size, self.limits.page_size);
            if (size == 0) return error.InvalidLimits;
            const all = try self.refs(arena);
            var start: usize = 0;
            if (after) |a| {
                while (start < all.len and std.mem.order(u8, all[start].id(), a) != .gt) start += 1;
            }
            const end = @min(all.len, start + size);
            const issues = try arena.alloc(Issue, end - start);
            for (all[start..end], issues) |r, *i| i.* = try self.load(arena, r);
            return .{
                .issues = issues,
                .next = if (end < all.len) all[end - 1].id() else null,
            };
        }

        fn checkLimits(self: Self) LoadError!void {
            if (!self.limits.valid()) return error.InvalidLimits;
        }

        pub fn loadCommits(
            self: Self,
            arena: Allocator,
            tip: Oid,
        ) LoadError![]issue_model.CommitInput {
            var out: std.ArrayList(issue_model.CommitInput) = .empty;
            var seen: std.AutoHashMapUnmanaged([Oid.max_byte_len]u8, void) = .empty;
            var stack: std.ArrayList(Oid) = .empty;
            try stack.append(arena, tip);
            try seen.put(arena, tip.bytes, {});
            const format = self.backend.objectFormat();
            while (stack.pop()) |oid| {
                if (out.items.len >= self.limits.max_commits_per_issue) return error.HistoryTooLong;
                const o = (try self.backend.readObject(
                    arena,
                    oid,
                )) orelse return error.CorruptIssue;
                if (o.kind != .commit) return error.CorruptIssue;
                const c = object.Commit.parse(
                    arena,
                    format,
                    o.data,
                ) catch return error.CorruptIssue;
                try out.append(arena, .{
                    .oid = oid,
                    .tree = c.tree,
                    .parents = c.parents,
                    .author = c.author,
                    .committer = c.committer,
                    .message = c.message,
                });
                for (c.parents) |p| {
                    const gop = try seen.getOrPut(arena, p.bytes);
                    if (!gop.found_existing) try stack.append(arena, p);
                }
            }
            return out.items;
        }

        pub const Problem = union(enum) {
            invalid_uuid,
            non_empty_tree: Oid,
            root_count: usize,
            missing_state,
            missing_format_version,
            /// Other than State and Format-Version, e.g. `Name` for
            /// milestones.
            missing_root_trailer: []const u8,
            unreadable: Error,

            /// One sentence, as fsck prints it.
            pub fn format(p: Problem, w: *std.Io.Writer) std.Io.Writer.Error!void {
                switch (p) {
                    .invalid_uuid => try w.writeAll("invalid UUID format"),
                    .non_empty_tree => |oid| try w.print(
                        "commit {s} does not use empty tree",
                        .{oid.hex().short()},
                    ),
                    .root_count => |n| try w.print("expected 1 root commit, found {d}", .{n}),
                    .missing_state => try w.writeAll("root commit missing State: trailer"),
                    .missing_format_version => try w.writeAll(
                        "root commit missing Format-Version: trailer",
                    ),
                    .missing_root_trailer => |k| try w.print(
                        "root commit missing {s}: trailer",
                        .{k},
                    ),
                    .unreadable => |e| try w.print("history unreadable ({t})", .{e}),
                }
            }
        };

        pub const CheckOptions = struct {
            /// The trailers the root commit must have; a milestone's are
            /// `Name` and `Format-Version`.
            root_keys: []const []const u8 = &.{ "State", "Format-Version" },
        };

        /// Upstream fsck's checks, with our trailer parsing.
        pub fn check(
            self: Self,
            arena: Allocator,
            ref: IssueRef,
            options: CheckOptions,
        ) Allocator.Error![]const Problem {
            const commits = self.loadCommits(arena, ref.tip) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    var problems: std.ArrayList(Problem) = .empty;
                    if (!uuid_fmt.isCanonical(ref.id())) try problems.append(arena, .invalid_uuid);
                    try problems.append(arena, .{ .unreadable = e });
                    return problems.items;
                },
            };
            return self.checkCommits(arena, ref, commits, options);
        }

        /// `check` on commits already loaded with `loadCommits`.
        pub fn checkCommits(
            self: Self,
            arena: Allocator,
            ref: IssueRef,
            commits: []const issue_model.CommitInput,
            options: CheckOptions,
        ) Allocator.Error![]const Problem {
            const root_keys = options.root_keys;
            var problems: std.ArrayList(Problem) = .empty;
            if (!uuid_fmt.isCanonical(ref.id())) try problems.append(arena, .invalid_uuid);
            const empty = object.emptyTree(self.backend.objectFormat());
            var roots: usize = 0;
            var root_message: ?[]const u8 = null;
            for (commits) |c| {
                if (c.tree) |t| if (!t.eql(empty)) try problems.append(
                    arena,
                    .{ .non_empty_tree = c.oid },
                );
                if (c.parents.len == 0) {
                    roots += 1;
                    root_message = c.message;
                }
            }
            if (roots != 1) try problems.append(arena, .{ .root_count = roots });
            if (root_message) |m| {
                const block = try trailers.parse(arena, m, .{});
                for (root_keys) |k| {
                    if (trailers.has(block, k)) continue;
                    try problems.append(arena, if (std.mem.eql(u8, k, "State"))
                        .missing_state
                    else if (std.mem.eql(u8, k, "Format-Version"))
                        .missing_format_version
                    else
                        .{ .missing_root_trailer = k });
                }
            }
            return problems.items;
        }

        /// A new issue: its root commit and ref. `options` as for `update`.
        pub fn create(
            self_in: Self,
            arena: Allocator,
            spec: CreateSpec,
            options: WriteOptions,
        ) Error!Created {
            var self = self_in.withOptions(options);
            try self.checkLimits();
            try self.checkTextOf("Title", spec.title, self.limits.max_title_bytes);
            try self.notBlank("Title", spec.title);
            if (spec.body.len > self.limits.max_body_bytes)
                return self.refuse(error.TooLong, "Description", "", self.limits.max_body_bytes);
            const normalized = try self.normalizeLabels(arena, spec.labels);
            const ms = MilestoneEdit.toParts(spec.milestone);
            var milestone_text = ms.text;
            if (ms.id) |mid| {
                const info = (try self.milestoneInfo(arena, mid)) orelse
                    return error.ReferenceNotFound;
                try checkSelectable(info.status);
                milestone_text = info.name;
            }
            // Nothing to pin yet; a link brings its own name.
            if (ms.mode) |m| if ((m == .explicit) != (ms.id != null))
                return error.InvalidValue;
            if (ms.id != null and ms.text != null) return error.InvalidValue;

            var list: std.ArrayList(trailers.Trailer) = .empty;
            try list.append(arena, .{ .key = "State", .value = spec.state.text() });
            for ([_]struct { []const u8, ?[]const u8 }{
                .{ "Fixed-By", spec.fixed_by },
                .{ "Release", spec.release },
                .{ "Reason", spec.reason },
            }) |kv| if (kv[1]) |v| if (v.len > 0) {
                try self.checkTextOf(kv[0], v, self.limits.max_trailer_value_bytes);
                try list.append(arena, .{ .key = kv[0], .value = v });
            };
            if (normalized.len > 0) try list.append(
                arena,
                .{ .key = "Labels", .value = try labels_fmt.join(arena, normalized) },
            );
            const people = try assigneeTexts(arena, spec.assignees);
            const assignees = try self.assigneeSet(arena, people, &.{});
            try appendAssignees(arena, &list, assignees, false);
            if (spec.priority) |v| try list.append(
                arena,
                .{ .key = "Priority", .value = v.text() },
            );
            if (milestone_text) |v| if (v.len > 0) try list.append(
                arena,
                .{ .key = "Milestone", .value = v },
            );
            if (spec.parent) |v| {
                try checkReference(v);
                try list.append(arena, .{ .key = "X-Parent", .value = v });
            }
            if (spec.blocked_by.len > 0) {
                const set = try self.referenceSet(arena, spec.blocked_by, &.{});
                const value = try labels_fmt.join(arena, set);
                try list.append(arena, .{ .key = "X-Blocked-By", .value = value });
            }
            for ([_]struct { []const u8, ?fields_fmt.Date }{
                .{ "X-Start-Date", spec.start_date },
                .{ "X-Due-Date", spec.due_date },
            }) |d| if (d[1]) |v| {
                if (!v.isValid()) return error.InvalidValue;
                try list.append(arena, .{ .key = d[0], .value = try dateText(arena, v) });
            };
            if (spec.estimate_minutes) |m| {
                if (m > fields_fmt.max_estimate_minutes) return error.InvalidValue;
                try list.append(arena, .{
                    .key = "X-Estimate-Minutes",
                    .value = try std.fmt.allocPrint(arena, "{d}", .{m}),
                });
            }
            if (spec.workflow) |v| {
                try self.checkWorkflow(v);
                try list.append(arena, .{ .key = "X-Workflow-State", .value = v });
            }
            if (ms.id) |mid| {
                try list.append(arena, .{ .key = "X-Milestone-Id", .value = mid });
                try list.append(arena, .{ .key = "X-Milestone-Mode", .value = explicit_mode });
            } else if (ms.mode) |m| {
                try list.append(arena, .{ .key = "X-Milestone-Mode", .value = @tagName(m) });
            }
            if (spec.number) |n| {
                if (n == 0 or n > fields_fmt.max_number) return error.InvalidValue;
                try list.append(arena, .{
                    .key = "X-Number",
                    .value = try std.fmt.allocPrint(arena, "{d}", .{n}),
                });
            }
            try checkHostFields(spec.extra);
            for (spec.extra) |f| if (f.value.len > 0) try list.append(
                arena,
                .{ .key = f.key, .value = f.value },
            );
            if (spec.attachments.len > self.limits.max_attachments) return error.TooManyAttachments;
            for (spec.attachments, 0..) |a, i| for (spec.attachments[0..i]) |o| {
                if (std.mem.eql(u8, o.id, a.id)) return error.AttachmentExists;
            };
            const images: AttachmentChanges = .{ .add = spec.attachments };
            try images.trailerList(arena, &list);
            try checkOriginal(spec.original);
            try spec.original.trailerList(arena, &list);
            if (self.call.author_id) |id| {
                if (!uuid_fmt.isCanonical(id)) return error.InvalidValue;
                try list.append(arena, .{ .key = issue_model.author_id_key, .value = id });
            }
            try list.append(arena, .{ .key = "Format-Version", .value = "1" });
            for (list.items) |t| try self.checkText(t.value, self.limits.max_trailer_value_bytes);

            const message = try trailers.build(arena, spec.title, spec.body, list.items);
            const who = try self.identity(arena, spec.author);
            const oid = try self.writeCommit(arena, &.{}, who, message);

            // A UUID collision or a change to an issue the guards read is a
            // CAS conflict: retry with a new UUID and fresh reads.
            var attempt: u8 = 0;
            while (attempt < self.limits.cas_retries) : (attempt += 1) {
                const guarded = try self.runGuards(arena, .{
                    .id = null,
                    .parent = spec.parent,
                    .parent_changed = spec.parent != null,
                    .blockers_added = spec.blocked_by,
                    .closed = spec.state.isDone(self.doneStates()),
                    .state_changed = false,
                    .was_closed = false,
                    .milestone_id = ms.id,
                    .milestone_mode = ms.mode,
                    .milestone_changed = true,
                    .number = spec.number,
                });
                var random: [16]u8 = undefined;
                self.backend.randomBytes(&random);
                const id = uuid_fmt.Uuid.fromRandom(random);
                const name = try std.fmt.allocPrint(
                    arena,
                    "{s}{s}",
                    .{ issue_ref_prefix, id.slice() },
                );
                var ops: std.ArrayList(contract.RefUpdate) = .empty;
                try ops.append(arena, .{ .name = name, .op = .{ .create = oid } });
                try ops.appendSlice(arena, try guarded.ops(arena, oid));
                const created: Created = .{ .id = name[issue_ref_prefix.len..], .tip = oid };
                if (self.call.dry_run) return created;
                try ops.appendSlice(
                    arena,
                    try self.attachmentRefs(arena, id.slice(), &.{}, oid, images),
                );
                self.forgetListing();
                self.backend.updateRefs(ops.items) catch |err| switch (err) {
                    error.RefConflict => continue,
                    else => |e| return e,
                };
                if (self.call.retries) |r| r.* = attempt;
                return created;
            }
            return error.ConcurrentModification;
        }

        fn writeComment(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            spec: CommentSpec,
        ) Error!Oid {
            const ref_name = try refFor(arena, issue_ref_prefix, ref_or_id);
            try self.checkLimits();
            if (spec.text.len > self.limits.max_body_bytes) return error.TooLong;
            try checkNotBlank(spec.text);
            try checkOriginal(spec.original);
            var provenance: std.ArrayList(trailers.Trailer) = .empty;
            try spec.original.trailerList(arena, &provenance);
            const split = splitMessage(spec.text);
            const message = try trailers.build(arena, split.subject, split.body, provenance.items);
            return self.appendCommit(arena, ref_name, spec.author, spec.expect, FixedMessage{
                .text = message,
            });
        }

        fn writeState(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            spec: StateSpec,
        ) Error!Oid {
            const ref_name = try refFor(arena, issue_ref_prefix, ref_or_id);
            try self.checkLimits();
            // `.{ .other = "closed" }` is `.closed`.
            const state = core_fmt.State.parse(spec.state.text());
            try self.checkText(state.text(), 64);
            if (!core_fmt.isState(state.text())) return error.InvalidValue;
            var list: std.ArrayList(trailers.Trailer) = .empty;
            try list.append(arena, .{ .key = "State", .value = state.text() });
            if (spec.fixed_by) |v| try list.append(arena, .{ .key = "Fixed-By", .value = v });
            if (spec.release) |v| try list.append(arena, .{ .key = "Release", .value = v });
            if (spec.reason) |v| try list.append(arena, .{ .key = "Reason", .value = v });
            for (list.items) |t| try self.checkText(t.value, self.limits.max_trailer_value_bytes);
            const default_subject = switch (state) {
                .open => "Reopen issue",
                .closed => "Close issue",
                .other => |s| try std.fmt.allocPrint(arena, "Change state to {s}", .{s}),
            };
            const split = splitMessage(givenMessage(spec.message) orelse default_subject);
            const message = try trailers.build(arena, split.subject, split.body, list.items);
            return self.appendCommit(arena, ref_name, spec.author, spec.expect, StateBuilder{
                .repo = self,
                .text = message,
                .closed = state.isDone(self.doneStates()),
            });
        }

        const StateBuilder = struct {
            /// A commit that changes nothing isn't written.
            pub const skip_unchanged = true;

            repo: Self,
            text: []const u8,
            closed: bool,

            pub fn message(b: StateBuilder, arena: Allocator, current: Issue) Error![]const u8 {
                _ = arena;
                _ = current;
                return b.text;
            }

            pub fn guard(
                b: StateBuilder,
                arena: Allocator,
                current: Issue,
            ) Error!Guarded {
                const was_closed = b.repo.isDone(current);
                return b.repo.runGuards(arena, .{
                    .id = current.id,
                    .parent = current.parent,
                    .parent_changed = false,
                    .blockers_added = &.{},
                    .closed = b.closed,
                    .state_changed = b.closed != was_closed,
                    .was_closed = was_closed,
                    .milestone_id = current.milestone_id,
                    .milestone_mode = current.milestone_mode,
                    .milestone_changed = false,
                });
            }
        };

        /// Deletes every ref of the library's in one transaction and returns
        /// how many: it undoes an import into a repository that had none,
        /// with no writes running. Not a purge: clones keep their copies and
        /// sync them back.
        pub fn dropAll(self: Self, arena: Allocator) (Error || error{RefConflict})!usize {
            var deletes: std.ArrayList(contract.RefUpdate) = .empty;
            for (all_ref_prefixes) |prefix| {
                for (try self.backend.listRefs(arena, prefix)) |e| try deletes.append(arena, .{
                    .name = e.name,
                    .op = .{ .delete = e.oid },
                });
            }
            if (deletes.items.len > 0) try self.backend.updateRefs(deletes.items);
            self.forgetListing();
            return deletes.items.len;
        }

        /// Creates in this repository every issue, milestone, attachment and
        /// tombstone ref `from` has, in one transaction, and returns how
        /// many: an import written into a scratch repository that shares
        /// this one's objects lands at once or not at all. RefConflict when
        /// this repository has one of them; CorruptIssue when a tip's
        /// object isn't in this repository's store.
        pub fn adoptFrom(
            self: Self,
            arena: Allocator,
            from: Self,
        ) (Error || error{RefConflict})!usize {
            var creates: std.ArrayList(contract.RefUpdate) = .empty;
            for (all_ref_prefixes[0..4]) |prefix| {
                for (try from.backend.listRefs(arena, prefix)) |e| {
                    const blob = try self.backend.readObject(arena, e.oid);
                    if (blob == null) return error.CorruptIssue;
                    try creates.append(arena, .{ .name = e.name, .op = .{ .create = e.oid } });
                }
            }
            if (creates.items.len > 0) try self.backend.updateRefs(creates.items);
            self.forgetListing();
            return creates.items.len;
        }

        /// Refused while sub-issues aren't deleted.
        fn writeDeleted(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            deleted: bool,
            spec: LifecycleSpec,
        ) Error!Oid {
            const ref_name = try refFor(arena, issue_ref_prefix, ref_or_id);
            try self.checkLimits();
            const given = givenMessage(spec.message);
            const subject = given orelse if (deleted) "Delete issue" else "Restore issue";
            const split = splitMessage(subject);
            const message = try trailers.build(arena, split.subject, split.body, &.{
                .{ .key = "X-Deleted", .value = if (deleted) "true" else "false" },
            });
            return self.appendCommit(arena, ref_name, spec.author, spec.expect, DeleteBuilder{
                .repo = self,
                .text = message,
                .deleted = deleted,
            });
        }

        const DeleteBuilder = struct {
            /// A commit that changes nothing isn't written.
            pub const skip_unchanged = true;

            repo: Self,
            text: []const u8,
            deleted: bool,

            pub fn message(b: DeleteBuilder, arena: Allocator, current: Issue) Error![]const u8 {
                _ = arena;
                _ = current;
                return b.text;
            }

            pub fn guard(
                b: DeleteBuilder,
                arena: Allocator,
                current: Issue,
            ) Error!Guarded {
                if (!b.deleted and current.deleted) return b.repo.runGuards(arena, .{
                    .id = current.id,
                    .parent = current.parent,
                    .parent_changed = false,
                    .blockers_added = &.{},
                    .closed = b.repo.isDone(current),
                    .state_changed = false,
                    .was_closed = b.repo.isDone(current),
                    .milestone_id = current.milestone_id,
                    .milestone_mode = current.milestone_mode,
                    .milestone_changed = false,
                    .restored = true,
                });
                if (!b.deleted or current.deleted) return .{};
                var g: Guard = .{ .repo = b.repo, .arena = arena, .self_id = current.id };
                // Before reading the children, so a new one conflicts.
                try g.bumpGuard(current.id);
                for (try g.childrenOf(current.id)) |c| {
                    if (!c.deleted) return error.ActiveChildren;
                    try g.pin(try refNameOf(arena, c.id), c.id, c.tip);
                }
                return g.result();
            }
        };

        /// Null when the reaction is already as asked: nothing written.
        fn writeReaction(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            spec: ReactSpec,
        ) Error!?Oid {
            const ref_name = try refFor(arena, issue_ref_prefix, ref_or_id);
            try self.checkLimits();
            if (!fields_fmt.isEmoji(spec.emoji)) return error.InvalidValue;
            const who = (try self.identity(arena, spec.author)).author;
            const tip = (try self.backend.resolveRef(ref_name)) orelse
                return error.IssueDisappeared;
            if (spec.expect) |want| if (!want.eql(tip)) return error.VersionMismatch;
            const current = try self.load(arena, .{ .name = ref_name, .tip = tip });
            if (spec.target) |t| {
                const found = for (current.comments) |c| {
                    if (c.oid.eql(t) and !c.is_merge) break true;
                } else false;
                if (!found) return error.CommentNotFound;
            }
            var has = false;
            for (current.reactions) |rx| {
                const same_target = if (rx.target) |t|
                    spec.target != null and t.eql(spec.target.?)
                else
                    spec.target == null;
                if (!same_target or !std.mem.eql(u8, rx.emoji, spec.emoji)) continue;
                for (rx.users) |u| {
                    if (std.mem.eql(u8, u.email, who.email)) has = true;
                }
            }
            if (has == spec.present) return null;
            return try self.appendCommit(arena, ref_name, spec.author, spec.expect, ReactionBuilder{
                .spec = spec,
            });
        }

        const ReactionBuilder = struct {
            spec: ReactSpec,

            pub fn message(b: ReactionBuilder, arena: Allocator, current: Issue) Error![]const u8 {
                _ = current;
                var list: std.ArrayList(trailers.Trailer) = .empty;
                try list.append(
                    arena,
                    .{ .key = "X-Event", .value = fields_fmt.Event.reaction.text() },
                );
                if (b.spec.target) |t| {
                    const hex = t.hex();
                    try list.append(
                        arena,
                        .{ .key = "X-Comment", .value = try arena.dupe(u8, hex.slice()) },
                    );
                }
                const sign: []const u8 = if (b.spec.present) "+" else "-";
                try list.append(arena, .{
                    .key = "X-Reaction",
                    .value = try std.fmt.allocPrint(arena, "{s}{s}", .{ sign, b.spec.emoji }),
                });
                const subject = try std.fmt.allocPrint(arena, "{s} {s}", .{
                    if (b.spec.present) "React" else "Take back", b.spec.emoji,
                });
                return trailers.build(arena, subject, "", list.items);
            }
        };

        /// `comment` is the full ID of the comment's commit. An edit
        /// replaces the whole text.
        fn writeCommentEvent(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            comment_oid: Oid,
            event: CommentEvent,
            text: []const u8,
            spec: LifecycleSpec,
        ) Error!Oid {
            const ref_name = try refFor(arena, issue_ref_prefix, ref_or_id);
            try self.checkLimits();
            if (text.len > self.limits.max_body_bytes) return error.TooLong;
            if (event == .edit) try checkNotBlank(text);
            if (event != .edit) {
                if (!spec.attachments.isEmpty() or spec.expect_edits != null)
                    return error.InvalidValue;
            }
            for (spec.attachments.remove) |id| if (!uuid_fmt.isCanonical(id))
                return error.AttachmentNotFound;
            return self.appendCommit(arena, ref_name, spec.author, spec.expect, CommentEventBuilder{
                .repo = self,
                .comment = comment_oid,
                .event = event,
                .text = text,
                .subject = givenMessage(spec.message),
                .attachments = spec.attachments,
                .expect_edits = spec.expect_edits,
            });
        }

        const CommentEventBuilder = struct {
            /// A commit that changes nothing isn't written.
            pub const skip_unchanged = true;

            repo: Self,
            comment: Oid,
            event: CommentEvent,
            text: []const u8,
            subject: ?[]const u8,
            attachments: AttachmentChanges,
            expect_edits: ?u32,

            pub fn after(
                b: CommentEventBuilder,
                arena: Allocator,
                current: Issue,
                new_tip: Oid,
            ) Error![]const contract.RefUpdate {
                return b.repo.attachmentRefs(
                    arena,
                    current.id,
                    current.attachments,
                    new_tip,
                    b.attachments,
                );
            }

            pub fn message(
                b: CommentEventBuilder,
                arena: Allocator,
                current: Issue,
            ) Error![]const u8 {
                var found = false;
                for (current.comments) |c| if (c.oid.eql(b.comment) and !c.is_merge) {
                    found = true;
                    try checkTextVersion(c.history, b.expect_edits);
                };
                if (!found) return error.CommentNotFound;
                const hex = b.comment.hex();
                const short = hex.short();
                const verb = switch (b.event) {
                    .edit => "Edit",
                    .delete => "Delete",
                    .restore => "Restore",
                };
                const subject = b.subject orelse
                    try std.fmt.allocPrint(arena, "{s} comment {s}", .{ verb, short });
                try b.attachments.check(current, b.repo.limits);
                const kind = b.event.event();
                var list: std.ArrayList(trailers.Trailer) = .empty;
                try list.append(arena, .{ .key = "X-Event", .value = kind.text() });
                try list.append(
                    arena,
                    .{ .key = "X-Comment", .value = try arena.dupe(u8, hex.slice()) },
                );
                try b.attachments.trailerList(arena, &list);
                return trailers.build(
                    arena,
                    subject,
                    if (kind.carriesText()) b.text else "",
                    list.items,
                );
            }
        };

        /// `wrote` is false when every field was already as given: no
        /// commit, the tip as it was.
        pub const EditResult = struct { tip: Oid, changes: []const Change, wrote: bool = true };

        /// Every write to an existing issue, routed to the commit it takes:
        /// a state change alone keeps its subject ("Close issue"), a comment
        /// alone is a plain comment, the rest is one edit. The receipt says
        /// what happened.
        pub fn update(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            u: Update,
            options: WriteOptions,
        ) Error!Receipt {
            var me = self.withOptions(options);
            var retries: u32 = 0;
            var skipped = false;
            me.call.retries = &retries;
            me.call.skipped = &skipped;
            const e = u.edit;
            const alternatives = @as(u8, @intFromBool(u.reaction != null)) +
                @intFromBool(u.comment_event != null) + @intFromBool(u.deleted != null);
            if (alternatives > 1) return error.InvalidValue;
            if (alternatives != 0) {
                var fields = e;
                fields.message = null;
                fields.author = null;
                fields.expect = null;
                if (u.comment_event) |ce| if (ce.event == .edit) {
                    fields.comment = null;
                    fields.attachments = .{};
                    fields.expect_edits = null;
                };
                if (!fields.isEmpty() or fields.expect_edits != null)
                    return error.InvalidValue;
            }
            var kind: Receipt.Kind = .update;
            var changes: []const Change = &.{};
            const written: ?Oid = blk: {
                if (u.reaction) |rx| {
                    kind = .reaction;
                    break :blk try me.writeReaction(arena, ref_or_id, .{
                        .target = rx.target,
                        .emoji = rx.emoji,
                        .present = rx.present,
                        .author = e.author,
                        .expect = e.expect,
                    });
                }
                if (u.comment_event) |ce| {
                    kind = switch (ce.event) {
                        .edit => .comment_edit,
                        .delete => .comment_delete,
                        .restore => .comment_restore,
                    };
                    const text = e.comment orelse "";
                    const target = ce.target;
                    break :blk try me.writeCommentEvent(arena, ref_or_id, target, ce.event, text, .{
                        .message = e.message,
                        .author = e.author,
                        .expect = e.expect,
                        .attachments = e.attachments,
                        .expect_edits = e.expect_edits,
                    });
                }
                if (u.deleted) |d| {
                    kind = .deleted;
                    break :blk try me.writeDeleted(arena, ref_or_id, d, .{
                        .message = e.message,
                        .author = e.author,
                        .expect = e.expect,
                    });
                }
                var fields = e;
                fields.state = null;
                fields.comment = null;
                const has_fields = !fields.isEmpty();
                if (e.state != null and !has_fields and e.comment == null) {
                    break :blk try me.writeState(arena, ref_or_id, .{
                        .state = e.state.?,
                        .message = e.message,
                        .fixed_by = e.fixed_by,
                        .release = e.release,
                        .reason = e.reason,
                        .author = e.author,
                        .expect = e.expect,
                    });
                }
                if (e.comment != null and e.state == null and !has_fields) {
                    kind = .comment;
                    break :blk try me.writeComment(arena, ref_or_id, .{
                        .text = e.comment.?,
                        .original = e.original,
                        .author = e.author,
                        .expect = e.expect,
                    });
                }
                if (e.description != null) kind = .description_edit;
                if (e.comment != null) kind = .comment;
                var spec = e;
                if (spec.comment != null) spec.message = null;
                const r = me.writeEdit(arena, ref_or_id, spec) catch |err| switch (err) {
                    error.NothingToEdit => break :blk null,
                    else => return err,
                };
                changes = r.changes;
                break :blk r.tip;
            };
            const tip = written orelse
                (try self.backend.resolveRef(try refFor(arena, issue_ref_prefix, ref_or_id))) orelse
                return error.IssueDisappeared;
            const receipt: Receipt = .{
                .tip = tip,
                .wrote = written != null and !skipped,
                .retries = retries,
                .kind = kind,
                .changes = changes,
            };
            self.report(receipt);
            return receipt;
        }

        /// For a caller that set `call`'s pointers (the C layer).
        fn report(self: Self, r: Receipt) void {
            if (self.call.retries) |p| p.* = r.retries;
            if (self.call.skipped) |p| p.* = !r.wrote;
        }

        // Shorthands for `update`, with the receipt it returns; `options`
        // as for `update`.

        /// A plain comment.
        pub fn comment(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            spec: CommentSpec,
            options: WriteOptions,
        ) Error!Receipt {
            return self.update(arena, ref_or_id, .{ .edit = .{
                .comment = spec.text,
                .original = spec.original,
                .author = spec.author,
                .expect = spec.expect,
            } }, options);
        }

        /// A state change alone, with its subject ("Close issue").
        pub fn setState(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            spec: StateSpec,
            options: WriteOptions,
        ) Error!Receipt {
            return self.update(arena, ref_or_id, .{ .edit = .{
                .state = spec.state,
                .message = spec.message,
                .fixed_by = spec.fixed_by,
                .release = spec.release,
                .reason = spec.reason,
                .author = spec.author,
                .expect = spec.expect,
            } }, options);
        }

        /// Refused while sub-issues aren't deleted.
        pub fn setDeleted(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            spec: DeleteSpec,
            options: WriteOptions,
        ) Error!Receipt {
            return self.update(arena, ref_or_id, .{
                .deleted = spec.deleted,
                .edit = .{ .message = spec.message, .author = spec.author, .expect = spec.expect },
            }, options);
        }

        /// `wrote` is false when the reaction is already as asked.
        pub fn react(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            spec: ReactSpec,
            options: WriteOptions,
        ) Error!Receipt {
            return self.update(arena, ref_or_id, .{
                .reaction = .{
                    .target = spec.target,
                    .emoji = spec.emoji,
                    .present = spec.present,
                },
                .edit = .{ .author = spec.author, .expect = spec.expect },
            }, options);
        }

        /// A comment's edit, delete or restore (`CommentEventSpec`).
        pub fn commentEvent(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            spec: CommentEventSpec,
            options: WriteOptions,
        ) Error!Receipt {
            return self.update(arena, ref_or_id, .{
                .comment_event = .{ .target = spec.target, .event = spec.event },
                .edit = .{
                    .comment = if (spec.event == .edit) spec.text else null,
                    .message = spec.message,
                    .author = spec.author,
                    .expect = spec.expect,
                    .attachments = spec.attachments,
                    .expect_edits = spec.expect_edits,
                },
            }, options);
        }

        /// One edit commit as given (a state alone keeps "Update state"
        /// rather than `setState`'s subject). An empty spec is
        /// NothingToEdit; `update` takes one as "nothing to write".
        pub fn edit(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            spec: EditSpec,
            options: WriteOptions,
        ) Error!Receipt {
            var me = self.withOptions(options);
            var retries: u32 = 0;
            var skipped = false;
            me.call.retries = &retries;
            me.call.skipped = &skipped;
            const r = try me.writeEdit(arena, ref_or_id, spec);
            const receipt: Receipt = .{
                .tip = r.tip,
                .wrote = r.wrote and !skipped,
                .retries = retries,
                .kind = if (spec.comment != null)
                    .comment
                else if (spec.description != null)
                    .description_edit
                else
                    .update,
                .changes = r.changes,
            };
            self.report(receipt);
            return receipt;
        }

        fn writeEdit(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            spec: EditSpec,
        ) Error!EditResult {
            const ref_name = try refFor(arena, issue_ref_prefix, ref_or_id);
            try self.checkLimits();
            const changes = try self.checkEdit(arena, spec);
            var me = self;
            var skipped = false;
            if (me.call.skipped == null) me.call.skipped = &skipped;
            const builder: EditBuilder = .{ .repo = me, .spec = spec, .changes = changes };
            const tip = try me.appendCommit(arena, ref_name, spec.author, spec.expect, builder);
            if (me.call.skipped.?.*) return .{ .tip = tip, .changes = &.{}, .wrote = false };
            return .{ .tip = tip, .changes = changes };
        }

        pub const BatchEdit = struct { ref_name: []const u8, spec: EditSpec };

        /// Several issues' edits, one commit each, written in one ref
        /// transaction: all of them or, on any failure, none. Each edit is
        /// checked like `edit`, its guards against the issues as the whole
        /// batch leaves them: the batch's issues with their new commits,
        /// every other one as it is. So edits can't make a parent or
        /// blocker loop between them, nest too deep, or put open work
        /// under a closed issue or in a completed milestone. Sub-issues are
        /// found as they were before the batch, which errs towards refusing:
        /// one the batch moves away still counts for depth and milestones.
        /// With `expect` on an edit whose issue moved, `VersionMismatch` and
        /// nothing written; without, a concurrent change retries the whole
        /// batch.
        pub fn editBatch(
            self: Self,
            arena: Allocator,
            edits: []const BatchEdit,
            options: WriteOptions,
        ) Error![]EditResult {
            return self.withOptions(options).editBatchWith(arena, edits, NoMore{});
        }

        const NoMore = struct {
            fn ops(_: NoMore, _: Allocator, _: *std.ArrayList(contract.RefUpdate)) Error!void {}
            fn moved(_: NoMore) Error!bool {
                return false;
            }
        };

        /// The issues a batch edits, as it leaves them, by ID.
        const Batched = std.StringHashMapUnmanaged(Issue);

        /// Internal: the library's own plumbing, not API; it may change.
        /// `editBatch`, with more ref updates from `more` in the same
        /// transaction, like the milestone catalog's: `more.ops(arena,
        /// &ops)` appends them on every attempt, `more.moved()` says
        /// whether a ref it expects moved after a conflict. A guard that
        /// read a ref `more` updates needs it at the update's old tip.
        pub fn editBatchWith(
            self: Self,
            arena: Allocator,
            edits: []const BatchEdit,
            more: anytype,
        ) Error![]EditResult {
            try self.checkLimits();
            const out = try arena.alloc(EditResult, edits.len);
            for (edits, 0..) |e, n| {
                if (!std.mem.startsWith(u8, e.ref_name, issue_ref_prefix) or
                    e.ref_name.len == issue_ref_prefix.len or
                    !contract.isValidRefName(e.ref_name)) return error.InvalidIssueRef;
                for (edits[0..n]) |prev| if (std.mem.eql(
                    u8,
                    prev.ref_name,
                    e.ref_name,
                )) return error.DuplicateEdit;
                out[n].changes = try self.checkEdit(arena, e.spec);
            }
            const any_expect = for (edits) |e| {
                if (e.spec.expect != null) break true;
            } else false;

            var attempt: u8 = 0;
            while (attempt < self.limits.cas_retries) : (attempt += 1) {
                var ops: std.ArrayList(contract.RefUpdate) = .empty;
                // Every commit first, each on its tip read once, so that the
                // guards see the batch's issues as it leaves them.
                var batched: Batched = .empty;
                const currents = try arena.alloc(Issue, edits.len);
                for (edits, currents, 0..) |e, *current, n| {
                    const tip = (try self.backend.resolveRef(
                        e.ref_name,
                    )) orelse return error.IssueDisappeared;
                    if (e.spec.expect) |want| if (!want.eql(tip)) return error.VersionMismatch;
                    const commits = try self.loadCommits(arena, tip);
                    const ref: IssueRef = .{ .name = e.ref_name, .tip = tip };
                    current.* = try issue_model.materialize(arena, ref.id(), tip, commits);
                    const builder: EditBuilder = .{
                        .repo = self,
                        .spec = e.spec,
                        .changes = out[n].changes,
                    };
                    const message = try self.stampAuthor(
                        arena,
                        try builder.message(arena, current.*),
                    );
                    const who = try self.identity(arena, e.spec.author);
                    const oid = try self.writeCommit(arena, &.{tip}, who, message);
                    out[n].tip = oid;
                    try ops.append(
                        arena,
                        .{ .name = e.ref_name, .op = .{ .update = .{ .new = oid, .old = tip } } },
                    );
                    // As the batch leaves it, from memory: a dry run only
                    // hashed the commit.
                    const with = try arena.alloc(issue_model.CommitInput, commits.len + 1);
                    @memcpy(with[0..commits.len], commits);
                    with[commits.len] = .{
                        .oid = oid,
                        .tree = object.emptyTree(oid.object_format),
                        .parents = try arena.dupe(Oid, &.{tip}),
                        .author = who.author,
                        .committer = who.committer,
                        .message = message,
                    };
                    try batched.put(
                        arena,
                        current.id,
                        try issue_model.materialize(arena, ref.id(), oid, with),
                    );
                }
                var verify: std.ArrayList(contract.RefUpdate) = .empty;
                var bumps: std.ArrayList(struct { name: []const u8, old: ?Oid }) = .empty;
                var cache: ?Guarded.ParentCache = null;
                for (edits, currents, 0..) |e, current, n| {
                    const builder: EditBuilder = .{
                        .repo = self,
                        .spec = e.spec,
                        .changes = out[n].changes,
                        .batch = &batched,
                    };
                    const guarded = try builder.guard(arena, current);
                    for (guarded.verify) |v| {
                        const seen = for (verify.items) |x| {
                            if (std.mem.eql(u8, x.name, v.name)) break true;
                        } else false;
                        if (!seen) try verify.append(arena, v);
                    }
                    // A guard ref moves once, to any of the new commits.
                    for (guarded.bump) |b| {
                        const seen = for (bumps.items) |x| {
                            if (std.mem.eql(u8, x.name, b.name)) break true;
                        } else false;
                        if (!seen) try bumps.append(arena, .{ .name = b.name, .old = b.old });
                    }
                    if (guarded.parent_cache) |c| cache = c;
                }
                try more.ops(arena, &ops);
                if (ops.items.len == 0) return out;
                // A ref the batch updates is checked by its update, when a
                // guard read it at the update's old tip. Read at another,
                // it moved in between: the attempt is stale.
                const updates = ops.items.len;
                var stale = false;
                for (verify.items) |v| {
                    const same: ?bool = for (ops.items[0..updates]) |o| {
                        if (std.mem.eql(u8, o.name, v.name))
                            break o.op == .update and v.op.verify != null and o.op.update.old.eql(
                                v.op.verify.?,
                            );
                    } else null;
                    if (same) |ok| {
                        if (!ok) stale = true;
                    } else try ops.append(arena, v);
                }
                for (bumps.items) |b| {
                    const op: contract.RefUpdate.Op = if (b.old) |old|
                        .{ .update = .{ .new = out[0].tip, .old = old } }
                    else
                        .{ .create = out[0].tip };
                    try ops.append(arena, .{ .name = b.name, .op = op });
                }
                // Every check and guard ran; the commits are only hashed.
                if (self.call.dry_run) return out;
                self.forgetListing();
                const conflict = stale or written: {
                    self.backend.updateRefs(ops.items) catch |err| switch (err) {
                        error.RefConflict => break :written true,
                        else => |e| return e,
                    };
                    break :written false;
                };
                if (conflict) {
                    if (any_expect) for (edits) |e| if (e.spec.expect) |want| {
                        const now = (try self.backend.resolveRef(e.ref_name)) orelse
                            return error.IssueDisappeared;
                        if (!now.eql(want)) return error.VersionMismatch;
                    };
                    if (try more.moved()) return error.VersionMismatch;
                    continue;
                }
                if (cache) |c| self.writeParentCache(c);
                return out;
            }
            return error.ConcurrentModification;
        }

        /// What `edit` checks before writing; the changes for the subject.
        fn checkEdit(self: Self, arena: Allocator, spec: EditSpec) Error![]const Change {
            const ms = MilestoneEdit.toParts(spec.milestone);
            if (spec.expect_edits != null and spec.description == null) return error.InvalidValue;
            if (spec.isEmpty()) return error.NothingToEdit;
            if (spec.description != null) {
                if (givenMessage(spec.message)) |m| if (splitMessage(m).body.len != 0)
                    return error.MessageHasBody;
            }
            if (spec.title) |t| {
                try self.checkTextOf("Title", t, self.limits.max_title_bytes);
                try self.notBlank("Title", t);
            }
            if (ms.text) |v| try self.checkText(v, self.limits.max_trailer_value_bytes);
            const set_people = if (spec.set_assignees) |s| try assigneeTexts(arena, s) else null;
            const add_people = try assigneeTexts(arena, spec.add_assignees);
            for (set_people orelse &.{}) |v|
                try self.checkText(v, self.limits.max_trailer_value_bytes);
            for (add_people) |v| try self.checkText(v, self.limits.max_trailer_value_bytes);
            var changes: std.ArrayList(Change) = .empty;
            if (spec.title != null) try changes.append(arena, .title);
            if (spec.set_labels != null or spec.add_labels.len > 0 or spec.remove_labels.len > 0)
                try changes.append(arena, .labels);
            const assignees_changed = spec.set_assignees != null or
                spec.add_assignees.len > 0 or spec.remove_assignees.len > 0;
            if (assignees_changed) try changes.append(arena, .assignee);
            for (set_people orelse &.{}) |v| try self.assignee(v);
            for (add_people) |v| try self.assignee(v);
            if (spec.priority != null) try changes.append(arena, .priority);
            const milestone_changes = ms.text != null or ms.id != null or
                ms.mode != null;
            if (milestone_changes) try changes.append(arena, .milestone);
            // The guard checks that the milestone can be selected.
            // A link brings its own name.
            if (ms.id != null and ms.text != null) return error.InvalidValue;
            if (spec.parent) |v| {
                if (v == .set) try self.reference("X-Parent", v.set);
                try changes.append(arena, .parent);
            }
            if (spec.set_blocked_by != null or spec.add_blocked_by.len > 0 or
                spec.remove_blocked_by.len > 0)
            {
                for (spec.set_blocked_by orelse &.{}) |r| try self.reference("X-Blocked-By", r);
                for (spec.add_blocked_by) |r| try self.reference("X-Blocked-By", r);
                try changes.append(arena, .blockers);
            }
            for ([_]struct { Change, ?EditSpec.DateEdit }{
                .{ .start_date, spec.start_date },
                .{ .due_date, spec.due_date },
            }) |d| if (d[1]) |v| {
                if (v == .set and !v.set.isValid()) return error.InvalidValue;
                try changes.append(arena, d[0]);
            };
            if (spec.estimate_minutes) |e| {
                const too_big = e == .set and e.set > fields_fmt.max_estimate_minutes;
                if (too_big) return error.InvalidValue;
                try changes.append(arena, .estimate);
            }
            if (spec.workflow) |v| {
                if (v == .set) try self.checkWorkflow(v.set);
                try changes.append(arena, .workflow);
            }
            if (spec.description) |d| {
                if (d.len > self.limits.max_body_bytes) return error.TooLong;
                try changes.append(arena, .description);
            }
            if (spec.state) |st| {
                const text = core_fmt.State.parse(st.text()).text();
                try self.checkText(text, 64);
                if (!core_fmt.isState(text)) return error.InvalidValue;
                try changes.append(arena, .state);
            }
            for ([_]?[]const u8{ spec.fixed_by, spec.release, spec.reason }) |v| if (v) |value| {
                if (spec.state == null) return error.InvalidValue;
                try self.checkText(value, self.limits.max_trailer_value_bytes);
            };
            if (spec.number) |n| {
                if (n == 0 or n > fields_fmt.max_number) return error.InvalidValue;
                try changes.append(arena, .number);
            }
            if (spec.locked) |_| try changes.append(arena, .lock);
            if (spec.lock_reason) |v| {
                if (spec.locked == null) return error.InvalidValue;
                try self.checkText(v, self.limits.max_trailer_value_bytes);
            }
            if (spec.ref) |v| {
                if (v == .set and !fields_fmt.isRefName(v.set)) return error.InvalidValue;
                try changes.append(arena, .ref);
            }
            try checkHostFields(spec.extra);
            for (spec.extra) |f| try self.checkText(f.value, self.limits.max_trailer_value_bytes);
            if (spec.extra.len > 0) try changes.append(arena, .fields);
            if (!spec.attachments.isEmpty()) {
                for (spec.attachments.remove) |id| if (!uuid_fmt.isCanonical(id))
                    return error.AttachmentNotFound;
                try changes.append(arena, .attachments);
            }
            try checkOriginal(spec.original);
            if (spec.comment) |text| {
                if (spec.description != null or givenMessage(spec.message) != null)
                    return error.CommentNotAlone;
                if (text.len > self.limits.max_body_bytes) return error.TooLong;
                try checkNotBlank(text);
                try changes.append(arena, .comment);
            }
            return changes.items;
        }

        fn appendCommit(
            self: Self,
            arena: Allocator,
            ref_name: []const u8,
            author: ?Signature,
            expect: ?Oid,
            builder: anytype,
        ) Error!Oid {
            return self.appendUnder(issue_ref_prefix, arena, ref_name, author, expect, builder);
        }

        /// `builder.message` runs against the fresh tip on every attempt.
        /// With `expect` there's a single attempt: if the ref moved, that's
        /// the caller's conflict, not ours to rebase.
        fn appendUnder(
            self: Self,
            prefix: []const u8,
            arena: Allocator,
            ref_or_id: []const u8,
            author: ?Signature,
            expect: ?Oid,
            builder: anytype,
        ) Error!Oid {
            const ref_name = try refFor(arena, prefix, ref_or_id);
            if (!std.mem.startsWith(u8, ref_name, prefix) or ref_name.len == prefix.len or
                !contract.isValidRefName(ref_name)) return error.InvalidIssueRef;
            var attempt: u8 = 0;
            while (attempt < self.limits.cas_retries) : (attempt += 1) {
                const tip = (try self.backend.resolveRef(ref_name)) orelse
                    return error.IssueDisappeared;
                if (expect) |want| if (!want.eql(tip)) return error.VersionMismatch;
                const skips = @hasDecl(@TypeOf(builder), "skip_unchanged");
                const commits = try self.loadCommits(arena, tip);
                const issue_ref: IssueRef = .{ .name = ref_name, .tip = tip };
                const current = try issue_model.materialize(arena, issue_ref.id(), tip, commits);
                const message = try self.stampAuthor(arena, try builder.message(arena, current));
                const who = try self.identity(arena, author);
                if (self.call.skipped) |sk| sk.* = false;
                if (skips and try issue_model.changesNothing(arena, commits, tip, .{
                    .oid = .{ .object_format = tip.object_format, .bytes = @splat(0) },
                    .parents = &.{tip},
                    .author = who.author,
                    .committer = who.committer,
                    .message = message,
                })) {
                    if (self.call.skipped) |sk| sk.* = true;
                    if (self.call.retries) |r| r.* = attempt;
                    return tip;
                }
                const guarded: Guarded = if (@hasDecl(@TypeOf(builder), "guard"))
                    try builder.guard(arena, current)
                else
                    .{};
                const oid = try self.writeCommit(arena, &.{tip}, who, message);
                var ops: std.ArrayList(contract.RefUpdate) = .empty;
                try ops.append(arena, .{
                    .name = ref_name,
                    .op = .{ .update = .{ .new = oid, .old = tip } },
                });
                try ops.appendSlice(arena, try guarded.ops(arena, oid));
                // More refs in the same transaction, like the derived
                // attachment ref.
                if (self.call.dry_run) return oid;
                if (@hasDecl(@TypeOf(builder), "after"))
                    try ops.appendSlice(arena, try builder.after(arena, current, oid));
                self.forgetListing();
                self.backend.updateRefs(ops.items) catch |err| switch (err) {
                    // Our ref moved, or an issue a guard read changed. With
                    // `expect` only the first is the caller's problem.
                    error.RefConflict => if (expect) |want| {
                        const now = (try self.backend.resolveRef(ref_name)) orelse
                            return error.IssueDisappeared;
                        if (!now.eql(want)) return error.VersionMismatch;
                        continue;
                    } else continue,
                    else => |e| return e,
                };
                if (guarded.parent_cache) |c| self.writeParentCache(c);
                if (self.call.retries) |r| r.* = attempt;
                return oid;
            }
            return error.ConcurrentModification;
        }

        pub const MilestoneInfo = struct {
            name: []const u8,
            status: fields_fmt.MilestoneStatus,
            tip: Oid,
        };

        pub fn milestoneInfo(
            self: Self,
            arena: Allocator,
            id: []const u8,
        ) LoadError!?MilestoneInfo {
            if (!uuid_fmt.isCanonical(id)) return null;
            const name = try milestoneRefName(arena, id);
            const tip = (try self.backend.resolveRef(name)) orelse return null;
            const header = milestoneHeader(try self.load(arena, .{ .name = name, .tip = tip }));
            return .{ .name = header.name, .status = header.status, .tip = tip };
        }

        /// The derived ref's update for a write that changes attachments.
        fn attachmentRefs(
            self: Self,
            arena: Allocator,
            issue_id: []const u8,
            before: []const issue_model.Attachment,
            new_tip: Oid,
            changes: AttachmentChanges,
        ) Error![]const contract.RefUpdate {
            if (changes.isEmpty()) return &.{};
            const Store = @import("attachments.zig").Attachments(B);
            return Store.fromRepo(self).derivedAfter(
                arena,
                issue_id,
                before,
                new_tip,
                changes.add,
                changes.remove,
            );
        }

        /// Internal: the library's own plumbing, not API; it may change.
        /// For builders from other modules, like the attachment store.
        pub fn appendIssue(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            author: ?Signature,
            expect: ?Oid,
            builder: anytype,
        ) Error!Oid {
            const ref_name = try refFor(arena, issue_ref_prefix, ref_or_id);
            try self.checkLimits();
            return self.appendCommit(arena, ref_name, author, expect, builder);
        }

        /// Internal: the library's own plumbing, not API; it may change.
        /// For the milestone catalog: `appendIssue` for `refs/milestones/`.
        pub fn appendMilestone(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            author: ?Signature,
            expect: ?Oid,
            builder: anytype,
        ) Error!Oid {
            try self.checkLimits();
            return self.appendUnder(
                milestone_ref_prefix,
                arena,
                ref_or_id,
                author,
                expect,
                builder,
            );
        }

        /// A builder with a message that doesn't depend on the tip.
        const FixedMessage = struct {
            text: []const u8,
            pub fn message(b: FixedMessage, arena: Allocator, current: Issue) Error![]const u8 {
                _ = arena;
                _ = current;
                return b.text;
            }
        };

        /// Internal: the library's own plumbing, not API; it may change.
        /// FixedMessage for an edit: not written when it changes nothing.
        pub const FixedEdit = struct {
            pub const skip_unchanged = true;

            text: []const u8,
            pub fn message(b: FixedEdit, arena: Allocator, current: Issue) Error![]const u8 {
                _ = arena;
                _ = current;
                return b.text;
            }
        };

        const EditBuilder = struct {
            /// A commit that changes nothing isn't written.
            pub const skip_unchanged = true;

            repo: Self,
            spec: EditSpec,
            changes: []const Change,
            /// In a batch, for the guards.
            batch: ?*const Batched = null,

            pub fn message(b: EditBuilder, arena: Allocator, current: Issue) Error![]const u8 {
                const spec = b.spec;
                try checkTextVersion(current.description_history, spec.expect_edits);
                const ms = MilestoneEdit.toParts(spec.milestone);
                try spec.attachments.check(current, b.repo.limits);
                var list: std.ArrayList(trailers.Trailer) = .empty;
                if (spec.state) |st| {
                    const parsed = core_fmt.State.parse(st.text());
                    try list.append(arena, .{ .key = "State", .value = parsed.text() });
                    if (spec.fixed_by) |v| try list.append(
                        arena,
                        .{ .key = "Fixed-By", .value = v },
                    );
                    if (spec.release) |v| try list.append(arena, .{ .key = "Release", .value = v });
                    if (spec.reason) |v| try list.append(arena, .{ .key = "Reason", .value = v });
                }
                if (spec.title) |t| try list.append(arena, .{ .key = "Title", .value = t });
                if (spec.number) |n| {
                    if (current.number) |had| {
                        if (had != n) return error.NumberAlreadySet;
                    } else try list.append(arena, .{
                        .key = "X-Number",
                        .value = try std.fmt.allocPrint(arena, "{d}", .{n}),
                    });
                }
                const labels_changed = spec.set_labels != null or spec.add_labels.len > 0 or
                    spec.remove_labels.len > 0;
                if (labels_changed) {
                    // From the fresh state, on every attempt.
                    var next: std.ArrayList([]const u8) = .empty;
                    try next.appendSlice(arena, spec.set_labels orelse current.labels);
                    try next.appendSlice(arena, spec.add_labels);
                    // Trimmed, like upstream compares them.
                    // The limit counts what is left after the removals.
                    const candidates = try b.repo.cleanLabels(arena, next.items);
                    var kept: std.ArrayList([]const u8) = .empty;
                    for (candidates) |l| {
                        var removed = false;
                        for (spec.remove_labels) |r| if (std.mem.eql(
                            u8,
                            std.mem.trim(u8, r, " \t"),
                            l,
                        )) {
                            removed = true;
                        };
                        if (!removed) try kept.append(arena, l);
                    }
                    const normalized = keepOrder(kept.items, current.labels);
                    if (normalized.len > b.repo.limits.max_labels)
                        return b.repo.refuse(
                            error.TooManyLabels,
                            "Labels",
                            "",
                            b.repo.limits.max_labels,
                        );
                    try list.append(
                        arena,
                        .{ .key = "Labels", .value = try labels_fmt.join(arena, normalized) },
                    );
                }
                const assignees_changed = spec.set_assignees != null or
                    spec.add_assignees.len > 0 or spec.remove_assignees.len > 0;
                if (assignees_changed) {
                    // From the fresh state, like labels.
                    var next: std.ArrayList([]const u8) = .empty;
                    if (spec.set_assignees) |s|
                        try next.appendSlice(arena, try assigneeTexts(arena, s))
                    else
                        try next.appendSlice(arena, current.assignees_written);
                    try next.appendSlice(arena, try assigneeTexts(arena, spec.add_assignees));
                    const set = keepOrder(
                        try b.repo.assigneeSet(arena, next.items, spec.remove_assignees),
                        current.assignees_written,
                    );
                    try appendAssignees(arena, &list, set, true);
                }
                if (spec.priority) |v| try list.append(arena, .{
                    .key = "Priority",
                    .value = switch (v) {
                        .set => |p| p.text(),
                        .clear => "",
                    },
                });
                // The catalog name for an ID, the given text, or empty when
                // the mode drops the milestone.
                const mode = ms.mode;
                const drops = ms.id == null and (mode == .inherit or mode == .none);
                if (ms.id) |mid| {
                    const info = (try b.repo.milestoneInfo(arena, mid)) orelse
                        return error.ReferenceNotFound;
                    try list.append(arena, .{ .key = "Milestone", .value = info.name });
                } else if (ms.text) |v| {
                    try list.append(arena, .{ .key = "Milestone", .value = v });
                } else if (drops) try list.append(arena, .{ .key = "Milestone", .value = "" });
                if (EditSpec.textOf(spec.parent)) |v|
                    try list.append(arena, .{ .key = "X-Parent", .value = v });
                if (spec.set_blocked_by != null or spec.add_blocked_by.len > 0 or
                    spec.remove_blocked_by.len > 0)
                {
                    // From the fresh state, like labels.
                    var next: std.ArrayList([]const u8) = .empty;
                    try next.appendSlice(arena, spec.set_blocked_by orelse current.blocked_by);
                    try next.appendSlice(arena, spec.add_blocked_by);
                    const set = keepOrder(
                        try b.repo.referenceSet(arena, next.items, spec.remove_blocked_by),
                        current.blocked_by,
                    );
                    try list.append(arena, .{
                        .key = "X-Blocked-By",
                        .value = try labels_fmt.join(arena, set),
                    });
                }
                for ([_]struct { []const u8, ?EditSpec.DateEdit }{
                    .{ "X-Start-Date", spec.start_date },
                    .{ "X-Due-Date", spec.due_date },
                }) |d| if (d[1]) |v| try list.append(arena, .{
                    .key = d[0],
                    .value = switch (v) {
                        .set => |date| try dateText(arena, date),
                        .clear => "",
                    },
                });
                if (spec.estimate_minutes) |e| try list.append(arena, .{
                    .key = "X-Estimate-Minutes",
                    .value = switch (e) {
                        .set => |m| try std.fmt.allocPrint(arena, "{d}", .{m}),
                        .clear => "",
                    },
                });
                if (EditSpec.textOf(spec.workflow)) |v| try list.append(
                    arena,
                    .{ .key = "X-Workflow-State", .value = v },
                );
                if (ms.id) |mid| {
                    try list.append(arena, .{ .key = "X-Milestone-Id", .value = mid });
                    try list.append(arena, .{ .key = "X-Milestone-Mode", .value = explicit_mode });
                } else if (mode) |m| {
                    if (m == .explicit and current.milestone_id == null)
                        return error.InvalidValue;
                    if (m != .explicit)
                        try list.append(arena, .{ .key = "X-Milestone-Id", .value = "" });
                    try list.append(arena, .{ .key = "X-Milestone-Mode", .value = @tagName(m) });
                }
                try spec.attachments.trailerList(arena, &list);
                if (spec.description) |d| {
                    try list.append(arena, .{
                        .key = "X-Event",
                        .value = fields_fmt.Event.description_edit.text(),
                    });
                    // Images that go with the new text don't count.
                    const images = std.mem.indexOfScalar(Change, b.changes, .attachments) != null;
                    const only = b.changes.len == 1 or (b.changes.len == 2 and images);
                    const given = if (givenMessage(spec.message)) |m|
                        splitMessage(m).subject
                    else
                        null;
                    const subject = given orelse if (only)
                        "Edit description"
                    else
                        try defaultEditSubject(arena, b.changes);
                    return trailers.build(arena, subject, d, list.items);
                }
                if (spec.locked) |locked| {
                    try list.append(
                        arena,
                        .{ .key = "X-Locked", .value = if (locked) "true" else "false" },
                    );
                    const reason = if (locked) (spec.lock_reason orelse "") else "";
                    if (reason.len > 0 or current.lock_reason != null)
                        try list.append(arena, .{ .key = "X-Lock-Reason", .value = reason });
                }
                if (EditSpec.textOf(spec.ref)) |v|
                    try list.append(arena, .{ .key = "X-Ref", .value = v });
                for (spec.extra) |f| try list.append(arena, .{ .key = f.key, .value = f.value });
                const fields_written = list.items.len;
                try spec.original.trailerList(arena, &list);
                // Only the number it already has: nothing to write, and a
                // commit without trailers would read as a comment.
                if (fields_written == 0 and spec.comment == null and spec.description == null)
                    return error.NothingToEdit;
                if (spec.comment) |text| {
                    try list.append(arena, .{ .key = message_key, .value = message_comment });
                    const split = splitMessage(text);
                    return trailers.build(arena, split.subject, split.body, list.items);
                }
                const attachments_only = b.changes.len == 1 and b.changes[0] == .attachments;
                const subject = givenMessage(spec.message) orelse if (attachments_only)
                    spec.attachments.subject()
                else
                    try defaultEditSubject(arena, b.changes);
                const split = splitMessage(subject);
                return trailers.build(arena, split.subject, split.body, list.items);
            }

            /// The derived attachment ref, in the same transaction.
            pub fn after(
                b: EditBuilder,
                arena: Allocator,
                current: Issue,
                new_tip: Oid,
            ) Error![]const contract.RefUpdate {
                return b.repo.attachmentRefs(
                    arena,
                    current.id,
                    current.attachments,
                    new_tip,
                    b.spec.attachments,
                );
            }

            pub fn guard(
                b: EditBuilder,
                arena: Allocator,
                current: Issue,
            ) Error!Guarded {
                const spec = b.spec;
                const ms = MilestoneEdit.toParts(spec.milestone);
                const parent: ?[]const u8 = if (spec.parent) |p| switch (p) {
                    .set => |id| id,
                    .clear => null,
                } else current.parent;
                var added: std.ArrayList([]const u8) = .empty;
                const parts = [_][]const []const u8{
                    spec.set_blocked_by orelse &.{},
                    spec.add_blocked_by,
                };
                for (parts) |part| {
                    for (part) |r| {
                        if (labels_fmt.contains(current.blocked_by, r)) continue;
                        if (labels_fmt.contains(spec.remove_blocked_by, r)) continue;
                        try added.append(arena, r);
                    }
                }
                const mode_after: ?fields_fmt.MilestoneMode = if (ms.id != null)
                    .explicit
                else
                    ms.mode orelse current.milestone_mode;
                const id_after: ?[]const u8 = if (ms.id) |mid|
                    mid
                else if (ms.mode) |m|
                    (if (m == .explicit) current.milestone_id else null)
                else
                    current.milestone_id;
                const was_closed = b.repo.isDone(current);
                const closed = if (spec.state) |st|
                    core_fmt.State.parse(st.text()).isDone(b.repo.doneStates())
                else
                    was_closed;
                return b.repo.runGuards(arena, .{
                    .id = current.id,
                    .parent = parent,
                    .parent_changed = spec.parent != null and parent != null,
                    .blockers_added = added.items,
                    .closed = closed,
                    .state_changed = closed != was_closed,
                    .was_closed = was_closed,
                    .milestone_id = id_after,
                    .milestone_mode = mode_after,
                    .milestone_changed = ms.id != null or ms.mode != null,
                    .number = if (current.number == null) spec.number else null,
                    .batch = b.batch,
                });
            }
        };

        /// The issue as a write would leave it.
        const Proposal = struct {
            /// Null on create.
            id: ?[]const u8,
            parent: ?[]const u8,
            parent_changed: bool,
            blockers_added: []const []const u8,
            closed: bool,
            state_changed: bool,
            was_closed: bool,
            milestone_id: ?[]const u8,
            milestone_mode: ?fields_fmt.MilestoneMode,
            milestone_changed: bool,
            /// A deleted issue comes back.
            restored: bool = false,
            /// A number being given: no other issue here may have it.
            number: ?u64 = null,
            /// The other issues a batch writes, as it leaves them.
            batch: ?*const Batched = null,
        };

        /// Every issue a guard reads is loaded once and gets a verify line,
        /// so a concurrent change aborts the write. What it can't pin, a
        /// new child or new milestone work, goes through the guard refs.
        const Guard = struct {
            repo: Self,
            arena: Allocator,
            /// The issue being written never gets a verify line: the update
            /// itself checks its ref, and a ref can't appear twice. Nor do
            /// the issues of its batch, which `get` reads from here.
            self_id: ?[]const u8,
            batch: ?*const Batched = null,
            cache: std.StringHashMapUnmanaged(?Issue) = .empty,
            verify: std.ArrayList(contract.RefUpdate) = .empty,
            bump: std.ArrayList(Guarded.Bump) = .empty,
            scanned: u32 = 0,
            /// Built on first use.
            index: ?ChildIndex = null,
            /// `childrenOf` results, by parent ID.
            children: std.StringHashMapUnmanaged([]const Issue) = .empty,
            milestones: std.StringHashMapUnmanaged(?MilestoneInfo) = .empty,

            fn get(g: *Guard, id: []const u8) Error!?Issue {
                if (g.cache.get(id)) |hit| return hit;
                if (g.batch) |b| if (b.get(id)) |issue| return issue;
                g.scanned += 1;
                if (g.scanned > g.repo.limits.max_guard_scan) return error.GuardScanTooLarge;
                const name = try std.fmt.allocPrint(g.arena, "{s}{s}", .{ issue_ref_prefix, id });
                const found: ?Issue = if (uuid_fmt.isCanonical(id))
                    if (try g.repo.backend.resolveRef(name)) |tip| blk: {
                        try g.pin(name, id, tip);
                        break :blk try g.repo.load(g.arena, .{ .name = name, .tip = tip });
                    } else null
                else
                    null;
                try g.cache.put(g.arena, id, found);
                return found;
            }

            /// See `guard_ref_prefix`.
            fn bumpGuard(g: *Guard, id: []const u8) Error!void {
                for (g.bump.items) |b| {
                    if (std.mem.eql(u8, b.name[guard_ref_prefix.len..], id)) return;
                }
                try g.bump.append(g.arena, try g.repo.readGuardRef(g.arena, id));
            }

            fn result(g: *Guard) Guarded {
                return .{
                    .verify = g.verify.items,
                    .bump = g.bump.items,
                    .parent_cache = if (g.index) |i| i.refreshed else null,
                };
            }

            fn pin(g: *Guard, name: []const u8, id: []const u8, tip: Oid) Error!void {
                if (g.self_id) |s| if (std.mem.eql(u8, s, id)) return;
                if (g.batch) |b| if (std.mem.startsWith(
                    u8,
                    name,
                    issue_ref_prefix,
                ) and b.contains(id)) return;
                for (g.verify.items) |v| if (std.mem.eql(u8, v.name, name)) return;
                try g.verify.append(g.arena, .{ .name = name, .op = .{ .verify = tip } });
            }

            /// Loaded once, and pinned.
            fn milestone(g: *Guard, id: []const u8) Error!?MilestoneInfo {
                if (g.milestones.get(id)) |hit| return hit;
                const info = try g.repo.milestoneInfo(g.arena, id);
                if (info) |i| try g.pin(try milestoneRefName(g.arena, id), id, i.tip);
                try g.milestones.put(g.arena, id, info);
                return info;
            }

            /// Its own setting, or the first explicit/none up the parent
            /// chain, as the projection reads it. Deleted ancestors pass
            /// through, cycles and missing parents end the walk.
            fn effectiveMilestone(g: *Guard, p: Proposal) Error!?[]const u8 {
                const has_id = p.milestone_id != null;
                switch (fields_fmt.MilestoneMode.of(p.milestone_mode, .{
                    .has_id = has_id,
                    .has_parent = p.parent != null,
                })) {
                    .explicit => return p.milestone_id,
                    .none => return null,
                    .inherit => {},
                }
                var seen: std.StringHashMapUnmanaged(void) = .empty;
                var next = p.parent;
                while (next) |up| {
                    if (p.id) |id| if (std.mem.eql(u8, id, up)) return null;
                    if ((try seen.getOrPut(g.arena, up)).found_existing) return null;
                    const anc = (try g.get(up)) orelse return null;
                    if (anc.deleted) {
                        next = anc.parent;
                        continue;
                    }
                    const ext = anc.extensions();
                    switch (fields_fmt.MilestoneMode.of(ext.milestone_mode, .{
                        .has_id = ext.milestone_id != null,
                        .has_parent = ext.parent != null,
                    })) {
                        .explicit => return ext.milestone_id,
                        .none => return null,
                        .inherit => next = ext.parent,
                    }
                }
                return null;
            }

            /// Whether an open descendant takes its milestone from `id`:
            /// through children that inherit, and through deleted ones,
            /// which pass it on whatever their own setting. Each one read
            /// is pinned.
            fn openHeir(g: *Guard, id: []const u8) Error!bool {
                var seen: std.StringHashMapUnmanaged(void) = .empty;
                try seen.put(g.arena, id, {});
                var stack: std.ArrayList([]const u8) = .empty;
                try stack.append(g.arena, id);
                while (stack.pop()) |up| {
                    for (try g.childrenOf(up)) |c| {
                        if ((try seen.getOrPut(g.arena, c.id)).found_existing) continue;
                        try g.pin(try refNameOf(g.arena, c.id), c.id, c.tip);
                        if (!c.deleted) {
                            const Mode = fields_fmt.MilestoneMode;
                            const has_id = c.milestone_id != null;
                            const known: Mode.Known = .{ .has_id = has_id, .has_parent = true };
                            if (Mode.of(c.milestone_mode, known) != .inherit) continue;
                            if (!g.repo.isDone(c)) return true;
                        }
                        try stack.append(g.arena, c.id);
                    }
                }
                return false;
            }

            /// Issues that can't be loaded are skipped, as in `loadForGuards`.
            fn childrenOf(g: *Guard, id: []const u8) Error![]const Issue {
                if (g.children.get(id)) |hit| return hit;
                if (g.index == null) g.index = try g.repo.childIndex(g.arena);
                const index = &g.index.?;
                var out: std.ArrayList(Issue) = .empty;
                if (index.children.get(id)) |kids| for (kids.items) |r| {
                    const batched = if (g.batch) |b| b.get(r.id()) else null;
                    const issue = batched orelse index.loaded.get(r.id()) orelse
                        g.repo.load(g.arena, r) catch |err| switch (err) {
                        error.CorruptIssue,
                        error.HistoryTooLong,
                        error.MissingParent,
                        error.NoRoot,
                        => continue,
                        else => |e| return e,
                    };
                    try out.append(g.arena, issue);
                };
                try g.children.put(g.arena, id, out.items);
                return out.items;
            }

            /// Each one pinned with a verify line. Cycle-safe. `height` gets
            /// the subtree's height.
            fn descendants(g: *Guard, id: []const u8, height: *u32) Error![]const Issue {
                var out: std.ArrayList(Issue) = .empty;
                var seen: std.StringHashMapUnmanaged(void) = .empty;
                try seen.put(g.arena, id, {});
                const Item = struct { id: []const u8, depth: u32 };
                var stack: std.ArrayList(Item) = .empty;
                try stack.append(g.arena, .{ .id = id, .depth = 0 });
                height.* = 0;
                while (stack.pop()) |it| {
                    for (try g.childrenOf(it.id)) |c| {
                        if ((try seen.getOrPut(g.arena, c.id)).found_existing) continue;
                        try out.append(g.arena, c);
                        const name = try std.fmt.allocPrint(
                            g.arena,
                            "{s}{s}",
                            .{ issue_ref_prefix, c.id },
                        );
                        try g.pin(name, c.id, c.tip);
                        height.* = @max(height.*, it.depth + 1);
                        try stack.append(g.arena, .{ .id = c.id, .depth = it.depth + 1 });
                    }
                }
                return out.items;
            }
        };

        const ChildIndex = struct {
            /// Parent ID to child refs, in ref order.
            children: std.StringHashMapUnmanaged(std.ArrayList(IssueRef)) = .empty,
            /// Issues loaded to bring it up to date, by ID.
            loaded: std.StringHashMapUnmanaged(Issue) = .empty,
            /// The cache to write, when it changed.
            refreshed: ?Guarded.ParentCache = null,
            /// `X-Number` to the issues that have it.
            numbers: std.AutoHashMapUnmanaged(u64, std.ArrayList(IssueRef)) = .empty,
        };

        /// From `parent_cache_ref`, loading only issues whose tip changed.
        /// The refreshed cache is written by a write that succeeds, so a
        /// refused one changes nothing. Issues that can't be loaded aren't
        /// cached, and are no one's children.
        fn childIndex(self: Self, arena: Allocator) LoadError!ChildIndex {
            const all = try self.refs(arena);
            if (all.len > self.limits.max_guard_scan) return error.GuardScanTooLarge;
            const cache_tip = try self.backend.resolveRef(parent_cache_ref);
            const cached = if (cache_tip) |t| try self.readParentCache(arena, t) else null;

            var index: ChildIndex = .{};
            var text: std.ArrayList(u8) = .empty;
            try text.appendSlice(arena, parent_cache_header);
            var hits: usize = 0;
            var unloadable: usize = 0;
            for (all) |r| {
                const id = r.id();
                const entry: ?ParentEntry = if (cached) |c| c.get(id) else null;
                var number: ?u64 = null;
                const parent: ?[]const u8 = if (entry != null and entry.?.tip.eql(r.tip)) blk: {
                    hits += 1;
                    number = entry.?.number;
                    break :blk entry.?.parent;
                } else blk: {
                    const issue = self.load(arena, r) catch |err| switch (err) {
                        error.CorruptIssue,
                        error.HistoryTooLong,
                        error.MissingParent,
                        error.NoRoot,
                        => {
                            unloadable += 1;
                            continue;
                        },
                        else => |e| return e,
                    };
                    try index.loaded.put(arena, id, issue);
                    number = issue.number;
                    break :blk issue.parent;
                };
                const hex = r.tip.hex();
                try text.print(arena, "{s} {s} ", .{ id, hex.slice() });
                if (parent) |p| try text.print(
                    arena,
                    "={s}",
                    .{p},
                ) else try text.appendSlice(arena, "-");
                if (number) |n| try text.print(
                    arena,
                    " #{d}\n",
                    .{n},
                ) else try text.appendSlice(arena, " #-\n");
                if (number) |n| {
                    const gop = try index.numbers.getOrPut(arena, n);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(arena, r);
                }
                const p = parent orelse continue;
                // Its own parent, from another tool: not a child.
                if (std.mem.eql(u8, p, id)) continue;
                const gop = try index.children.getOrPut(arena, p);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(arena, r);
            }
            // Loading a few stale entries costs no git call, rewriting the
            // cache two, and every write leaves its own entry stale. Issues
            // that can't be loaded never get an entry.
            const stale = if (cached) |c|
                (all.len - hits - unloadable) + (c.count() - hits)
            else
                all.len;
            if (cached == null or stale >= parent_cache_slack)
                index.refreshed = .{ .old = cache_tip, .text = text.items };
            return index;
        }

        const ParentEntry = struct { tip: Oid, parent: ?[]const u8, number: ?u64 };

        /// Null when it isn't a cache we can read.
        fn readParentCache(
            self: Self,
            arena: Allocator,
            tip: Oid,
        ) LoadError!?std.StringHashMapUnmanaged(ParentEntry) {
            const o = (try self.backend.readObject(arena, tip)) orelse return null;
            if (o.kind != .blob) return null;
            if (!std.mem.startsWith(u8, o.data, parent_cache_header)) return null;
            var out: std.StringHashMapUnmanaged(ParentEntry) = .empty;
            var lines = std.mem.splitScalar(u8, o.data[parent_cache_header.len..], '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                var it = std.mem.splitScalar(u8, line, ' ');
                const id = it.next() orelse return null;
                const tip_hex = it.next() orelse return null;
                const parent_text = it.next() orelse return null;
                const number_text = it.next() orelse return null;
                if (it.next() != null) return null;
                const parent: ?[]const u8 = if (std.mem.eql(u8, parent_text, "-"))
                    null
                else if (parent_text.len > 1 and parent_text[0] == '=')
                    parent_text[1..]
                else
                    return null;
                const number: ?u64 = if (std.mem.eql(u8, number_text, "#-"))
                    null
                else if (number_text.len > 1 and number_text[0] == '#')
                    fields_fmt.parseNumber(number_text[1..]) orelse return null
                else
                    return null;
                const t = Oid.parseHex(self.backend.objectFormat(), tip_hex) catch return null;
                try out.put(arena, id, .{ .tip = t, .parent = parent, .number = number });
            }
            return out;
        }

        /// Best effort: it's only a cache.
        fn writeParentCache(self: Self, cache: Guarded.ParentCache) void {
            self.writeParentCacheOrFail(cache.old, cache.text) catch {};
        }

        fn writeParentCacheOrFail(self: Self, old: ?Oid, text: []const u8) Error!void {
            const oid = try self.backend.writeObject(.blob, text);
            if (old != null and old.?.eql(oid)) return;
            self.backend.updateRefs(&.{.{ .name = parent_cache_ref, .op = if (old) |o|
                .{ .update = .{ .new = oid, .old = o } }
            else
                .{ .create = oid } }}) catch |err| switch (err) {
                error.RefConflict => {}, // someone else refreshed it
                else => |e| return e,
            };
        }

        /// The issues with `X-Number` n, through the parents cache (which
        /// this refreshes when stale, best effort). Several means another
        /// clone gave the same number.
        pub fn findNumber(self: Self, arena: Allocator, n: u64) LoadError![]const IssueRef {
            const index = try self.childIndex(arena);
            if (index.refreshed) |c| self.writeParentCache(c);
            const owners = index.numbers.get(n) orelse return &.{};
            return owners.items;
        }

        /// Every `X-Number` with the issues that have it, without writing
        /// the cache: for checks that must not write.
        pub fn numbers(
            self: Self,
            arena: Allocator,
        ) LoadError!std.AutoHashMapUnmanaged(u64, std.ArrayList(IssueRef)) {
            return (try self.childIndex(arena)).numbers;
        }

        /// Returns verify lines for every issue it read.
        fn runGuards(self: Self, arena: Allocator, p: Proposal) Error!Guarded {
            var g: Guard = .{ .repo = self, .arena = arena, .self_id = p.id, .batch = p.batch };
            const eql = std.mem.eql;

            if (p.number) |n| {
                // Two writers giving the same number here meet on its
                // guard ref; the cache finds who has it already.
                try g.bumpGuard(try std.fmt.allocPrint(arena, "number-{d}", .{n}));
                if (g.index == null) g.index = try self.childIndex(arena);
                if (g.index.?.numbers.get(n)) |owners| for (owners.items) |r| {
                    if (p.id) |id| if (eql(u8, r.id(), id)) continue;
                    return error.NumberTaken;
                };
            }
            if (p.parent_changed) if (p.parent) |parent| {
                if (p.id) |id| if (eql(u8, id, parent)) return error.ParentIsSelf;
                var cur = (try g.get(parent)) orelse return error.ReferenceNotFound;
                if (cur.deleted) return error.ParentDeleted;
                // Finding our own ID above the new parent means a cycle.
                var depth_of_parent: u32 = 0;
                var seen: std.StringHashMapUnmanaged(void) = .empty;
                while (true) {
                    if (p.id) |id| if (eql(u8, cur.id, id)) return error.ParentCycle;
                    if ((try seen.getOrPut(arena, cur.id)).found_existing) break; // foreign cycle
                    // Work arrives under every ancestor.
                    try g.bumpGuard(cur.id);
                    const up = cur.parent orelse break;
                    cur = (try g.get(up)) orelse break; // dangling: treated as a root
                    depth_of_parent += 1;
                }
                var height: u32 = 0;
                if (p.id) |id| _ = try g.descendants(id, &height);
                if (depth_of_parent + 1 + height > self.limits.max_depth) return error.TooDeep;
            };

            // No open issue under a closed ancestor.
            const placing_open = !p.closed and (p.id == null or p.parent_changed or p.restored or
                (p.state_changed and p.was_closed));
            if (placing_open) if (p.parent) |parent| {
                var seen: std.StringHashMapUnmanaged(void) = .empty;
                var next: ?[]const u8 = parent;
                while (next) |up| {
                    // Back at ourselves: a cycle someone else made.
                    if (p.id) |id| if (std.mem.eql(u8, up, id)) break;
                    if ((try seen.getOrPut(arena, up)).found_existing) break;
                    const anc = (try g.get(up)) orelse break;
                    // Deleted ancestors don't count.
                    if (self.isDone(anc) and !anc.deleted) return error.ClosedAncestor;
                    next = anc.parent;
                }
            };

            // A closed issue coming back may have gained open work while
            // deleted: deleted ancestors don't stop it.
            if (p.closed and (p.state_changed or p.restored)) if (p.id) |id| {
                try g.bumpGuard(id);
                var height: u32 = 0;
                for (try g.descendants(id, &height)) |d| {
                    if (!self.isDone(d) and !d.deleted) return error.OpenDescendants;
                }
            };

            // Checked against a pinned tip.
            if (p.milestone_changed) if (p.milestone_id) |mid| {
                if (p.milestone_mode == null or p.milestone_mode.? == .explicit) {
                    const info = (try g.milestone(mid)) orelse return error.ReferenceNotFound;
                    try checkSelectable(info.status);
                }
            };
            // No open work in a completed milestone: neither this issue nor
            // the open descendants that inherit through it. Both kinds of
            // write move the milestone's guard ref, like completing it.
            const placing = placing_open or (!p.closed and p.milestone_changed);
            const moves = p.milestone_changed or p.parent_changed or p.restored;
            if (placing or moves) if (try g.effectiveMilestone(p)) |mid| {
                if (try g.milestone(mid)) |info| {
                    try g.bumpGuard(mid);
                    if (info.status == .completed) {
                        if (placing) return error.MilestoneCompleted;
                        if (p.id) |id| if (try g.openHeir(id)) return error.MilestoneCompleted;
                    }
                }
            };

            for (p.blockers_added) |b| {
                if (p.id) |id| if (eql(u8, id, b)) return error.BlocksItself;
                const target = (try g.get(b)) orelse return error.ReferenceNotFound;
                // Is the new blocker waiting for us, directly or not?
                const id = p.id orelse continue;
                var seen: std.StringHashMapUnmanaged(void) = .empty;
                var stack: std.ArrayList(Issue) = .empty;
                try stack.append(arena, target);
                while (stack.pop()) |x| {
                    if ((try seen.getOrPut(arena, x.id)).found_existing) continue;
                    for (x.blocked_by) |y| {
                        if (eql(u8, y, id)) return error.BlockerCycle;
                        if (try g.get(y)) |next| try stack.append(arena, next);
                    }
                }
            }
            return g.result();
        }

        /// Internal: the library's own plumbing, not API; it may change.
        /// `message` with the author's `X-Author-Id`, when the embedder
        /// set one and the message doesn't carry it yet.
        pub fn stampAuthor(self: Self, arena: Allocator, message: []const u8) Error![]const u8 {
            const id = self.call.author_id orelse return message;
            if (!uuid_fmt.isCanonical(id)) return error.InvalidValue;
            if (try issue_model.authorIdOf(arena, message) != null) return message;
            return (try trailers.append(arena, message, issue_model.author_id_key, id)) orelse
                error.InvalidValue;
        }

        /// Internal: the library's own plumbing, not API; it may change.
        pub fn writeCommit(
            self: Self,
            arena: Allocator,
            parents: []const Oid,
            who: contract.Identity,
            message: []const u8,
        ) Error!Oid {
            const format = self.backend.objectFormat();
            const c: object.Commit = .{
                .tree = object.emptyTree(format),
                .parents = parents,
                .author = who.author,
                .committer = who.committer,
                .message = message,
            };
            const data = try c.serializeAlloc(arena);
            if (self.call.dry_run) return object.hashObject(format, .commit, data);
            return self.backend.writeObject(.commit, data);
        }

        /// Internal: the library's own plumbing, not API; it may change.
        /// The backend's identity, with `author` replacing the author.
        pub fn identity(self: Self, arena: Allocator, author: ?Signature) Error!contract.Identity {
            const defaults = self.backend.identity(arena) catch |err| switch (err) {
                error.IdentityUnknown => if (author) |a| return .{
                    .author = a,
                    .committer = a,
                } else return error.IdentityUnknown,
                else => |e| return e,
            };
            if (author) |a| return .{ .author = a, .committer = defaults.committer };
            return defaults;
        }

        /// Full UUIDs, deduplicated, minus `remove`, at most
        /// `Limits.max_blockers`.
        fn referenceSet(
            self: Self,
            arena: Allocator,
            members: []const []const u8,
            remove: []const []const u8,
        ) Error![]const []const u8 {
            var out: std.ArrayList([]const u8) = .empty;
            for (members) |r| {
                try self.reference("X-Blocked-By", r);
                if (labels_fmt.contains(out.items, r) or labels_fmt.contains(remove, r)) continue;
                try out.append(arena, r);
            }
            if (out.items.len > self.limits.max_blockers)
                return self.refuse(
                    error.TooManyBlockers,
                    "X-Blocked-By",
                    "",
                    self.limits.max_blockers,
                );
            return out.items;
        }

        /// Valid, without duplicates or the removed ones (by value or
        /// email), at most `Limits.max_assignees`.
        fn assigneeSet(
            self: Self,
            arena: Allocator,
            members: []const []const u8,
            remove: []const []const u8,
        ) Error![]const []const u8 {
            var out: std.ArrayList([]const u8) = .empty;
            for (members) |raw| {
                const m = std.mem.trim(u8, raw, " \t");
                if (m.len == 0) continue;
                try self.assignee(m);
                const a = fields_fmt.Assignee.parse(m).?;
                const gone = for (remove) |r| {
                    const t = std.mem.trim(u8, r, " \t");
                    if (std.mem.eql(u8, t, m) or std.mem.eql(u8, t, a.email)) break true;
                } else false;
                if (gone or labels_fmt.contains(out.items, m)) continue;
                try out.append(arena, m);
            }
            if (out.items.len > self.limits.max_assignees)
                return self.refuse(
                    error.TooManyAssignees,
                    "Assignee",
                    "",
                    self.limits.max_assignees,
                );
            return out.items;
        }

        fn normalizeLabels(
            self: Self,
            arena: Allocator,
            raw: []const []const u8,
        ) Error![]const []const u8 {
            const out = try cleanLabels(self, arena, raw);
            if (out.len > self.limits.max_labels)
                return self.refuse(error.TooManyLabels, "Labels", "", self.limits.max_labels);
            return out;
        }

        /// Checked, trimmed, each once; no limit yet.
        fn cleanLabels(
            self: Self,
            arena: Allocator,
            raw: []const []const u8,
        ) Error![]const []const u8 {
            var out: std.ArrayList([]const u8) = .empty;
            for (raw) |l| {
                labels_fmt.validate(l) catch
                    return self.refuse(error.InvalidLabel, "Labels", l, null);
                const t = std.mem.trim(u8, l, " \t");
                if (t.len == 0 or labels_fmt.contains(out.items, t)) continue;
                try out.append(arena, t);
            }
            return out.items;
        }

        fn checkText(self: Self, text: []const u8, max: u32) Error!void {
            return self.checkTextOf("", text, max);
        }

        /// `checkText` that says which field (`key`) refused what.
        fn checkTextOf(self: Self, key: []const u8, text: []const u8, max: u32) Error!void {
            if (text.len > max) return self.refuse(error.TooLong, key, text, max);
            if (std.mem.findAny(u8, text, "\r\n") != null) return self.refuse(
                error.InvalidText,
                key,
                text,
                null,
            );
        }

        /// Records what a write refused, for `diagnostics`, and returns `err`.
        fn refuse(
            self: Self,
            err: anytype,
            key: []const u8,
            value: []const u8,
            limit: ?u64,
        ) @TypeOf(err) {
            if (self.call.diagnostics) |d| d.add(
                .{ .err = err, .key = key, .value = value, .limit = limit },
            );
            return err;
        }

        fn notBlank(self: Self, key: []const u8, text: []const u8) Error!void {
            checkNotBlank(text) catch |e| return self.refuse(e, key, text, null);
        }

        fn assignee(self: Self, v: []const u8) Error!void {
            checkAssignee(v) catch |e| return self.refuse(e, "Assignee", v, null);
        }

        fn reference(self: Self, key: []const u8, v: []const u8) Error!void {
            checkReference(v) catch |e| return self.refuse(e, key, v, null);
        }

        fn checkWorkflow(self: Self, state: []const u8) Error!void {
            return self.settings.checkWorkflow(state);
        }
    };
}

fn refNameOf(arena: Allocator, id: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}", .{ issue_ref_prefix, id });
}

/// Internal: the library's own plumbing, not API; it may change.
/// `refs/milestones/<id>`.
pub fn milestoneRefName(arena: Allocator, id: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}", .{ milestone_ref_prefix, id });
}

/// Internal: the library's own plumbing, not API; it may change.
/// What every reader takes from a loaded milestone: `Name` (else the
/// subject) and `X-Milestone-Status` (`open` when missing or unknown).
pub fn milestoneHeader(m: Issue) struct { name: []const u8, status: fields_fmt.MilestoneStatus } {
    const status = if (m.field("X-Milestone-Status")) |v|
        fields_fmt.MilestoneStatus.parse(v) orelse .open
    else
        .open;
    return .{ .name = m.field("Name") orelse m.title, .status = status };
}

const explicit_mode = @tagName(fields_fmt.MilestoneMode.explicit);

fn checkSelectable(
    status: fields_fmt.MilestoneStatus,
) error{ MilestoneCompleted, MilestoneRetired }!void {
    switch (status) {
        .open => {},
        .completed => return error.MilestoneCompleted,
        .retired => return error.MilestoneRetired,
    }
}

fn checkReference(r: []const u8) error{InvalidValue}!void {
    if (!uuid_fmt.isCanonical(r)) return error.InvalidValue;
}

/// The set a write states, in the order `current` has when they hold the
/// same members: a host that restates a set in its own order changes
/// nothing, as a list's order is part of what the issue shows.
fn keepOrder(set: []const []const u8, current: []const []const u8) []const []const u8 {
    if (set.len != current.len) return set;
    for (set) |m| if (!labels_fmt.contains(current, m)) return set;
    return current;
}

/// `Assignee` with the first, and `X-Assignees` with all of them when
/// there are several (format.md §3): one alone is what upstream writes and
/// reads back as that one. `clear` writes an empty `Assignee` for none.
fn appendAssignees(
    arena: Allocator,
    list: *std.ArrayList(trailers.Trailer),
    set: []const []const u8,
    clear: bool,
) Allocator.Error!void {
    if (set.len == 0 and !clear) return;
    try list.append(arena, .{ .key = "Assignee", .value = if (set.len > 0) set[0] else "" });
    if (set.len > 1) try list.append(arena, .{
        .key = "X-Assignees",
        .value = try labels_fmt.join(arena, set),
    });
}

fn checkHostFields(list: []const HostField) error{ InvalidValue, InvalidText }!void {
    for (list) |f| {
        const namespaced = f.key.len > 2 and std.ascii.startsWithIgnoreCase(f.key, "X-");
        if (!trailers.isValidKey(f.key) or !namespaced or issue_model.isFormatKey(f.key))
            return error.InvalidValue;
        if (std.mem.findAny(u8, f.value, "\r\n") != null) return error.InvalidText;
    }
}

fn checkOriginal(o: Original) error{InvalidText}!void {
    for ([_]?[]const u8{ o.author, o.id }) |v| if (v) |x| {
        if (x.len == 0 or std.mem.findAny(u8, x, "\r\n") != null) return error.InvalidText;
    };
}

fn assigneeTexts(
    arena: Allocator,
    list: []const fields_fmt.Assignee,
) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, list.len);
    for (list, out) |a, *o| o.* = try a.text(arena);
    return out;
}

fn checkAssignee(v: []const u8) error{InvalidValue}!void {
    const a = fields_fmt.Assignee.parse(v) orelse return error.InvalidValue;
    if (core_fmt.checkEmail(a.email) != null) return error.InvalidValue;
}

fn defaultEditSubject(arena: Allocator, changes: []const Change) Allocator.Error![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (changes) |c| try names.append(arena, c.name());
    return std.fmt.allocPrint(arena, "Update {s}", .{try std.mem.join(arena, ", ", names.items)});
}

/// Internal: the library's own plumbing, not API; it may change.
/// A commit message the caller gave, null when it is blank, like upstream
/// takes an empty `-m`: the write's default subject stands in.
pub fn givenMessage(message: ?[]const u8) ?[]const u8 {
    const m = message orelse return null;
    return if (std.mem.trim(u8, m, " \t\r\n").len == 0) null else m;
}

/// For text that must say something: titles, comments.
fn checkTextVersion(
    revisions: []const issue_model.Revision,
    expected: ?u32,
) error{VersionMismatch}!void {
    const want = expected orelse return;
    var edits: u32 = 0;
    for (revisions) |r| if (r.kind == .edit) {
        edits += 1;
    };
    if (edits != want) return error.VersionMismatch;
}

/// Internal: the library's own plumbing, not API; it may change.
pub fn checkNotBlank(text: []const u8) error{EmptyText}!void {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.EmptyText;
}

/// Internal: the library's own plumbing, not API; it may change.
/// First paragraph is the subject, the rest the body, so `-m a -m b` gives
/// subject "a" and body "b".
pub fn splitMessage(text: []const u8) struct { subject: []const u8, body: []const u8 } {
    const trimmed = std.mem.trim(u8, text, "\n");
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, trimmed, i, '\n')) |nl| {
        const rest = trimmed[nl + 1 ..];
        const line_end = std.mem.findScalar(u8, rest, '\n') orelse rest.len;
        if (std.mem.trim(u8, rest[0..line_end], " \t\r").len == 0) {
            return .{ .subject = trimmed[0..nl], .body = skipBlankLines(rest) };
        }
        i = nl + 1;
    }
    return .{ .subject = trimmed, .body = "" };
}

/// Keeps the first line's indentation, so indented code in a comment
/// survives.
fn skipBlankLines(text: []const u8) []const u8 {
    var rest = text;
    while (rest.len > 0) {
        const line_end = std.mem.findScalar(u8, rest, '\n') orelse rest.len;
        if (std.mem.trim(u8, rest[0..line_end], " \t\r").len != 0) break;
        rest = if (line_end < rest.len) rest[line_end + 1 ..] else rest[rest.len..];
    }
    return rest;
}

test splitMessage {
    const t = std.testing;
    const a = splitMessage("one");
    try t.expectEqualStrings("one", a.subject);
    try t.expectEqualStrings("", a.body);
    const b = splitMessage("Repro\n\nDetail one\ndetail two");
    try t.expectEqualStrings("Repro", b.subject);
    try t.expectEqualStrings("Detail one\ndetail two", b.body);
    const c = splitMessage("line one\nline two\n\nbody");
    try t.expectEqualStrings("line one\nline two", c.subject);
    try t.expectEqualStrings("body", c.body);
    const d = splitMessage("Code:\n\n  \n    indented();\n");
    try t.expectEqualStrings("    indented();", d.body);
}

const GitSim = @import("../backend/GitSim.zig");
const testing = std.testing;
const RacingSim = @import("racing_sim.zig").RacingSim;

test "create, comment, state, edit and read back" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 3, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);

    const created = try repo.create(arena, .{
        .title = "Crash on login",
        .body = "First paragraph.\n\nSecond.",
        .labels = &.{ "bug", " auth ", "bug" },
        .assignees = &.{.byEmail("bob@e.x")},
        .priority = .high,
    }, .{});
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    _ = try repo.comment(arena, ref_name, .{ .text = "Repro on Firefox\n\nDetail line" }, .{});
    _ = try repo.setState(
        arena,
        ref_name,
        .{ .state = .closed, .message = "Fixed in abc", .fixed_by = "abc123" },
        .{},
    );
    const edited = try repo.edit(
        arena,
        ref_name,
        .{
            .add_labels = &.{"regression"},
            .remove_labels = &.{"auth"},
            .set_assignees = &.{},
        },
        .{},
    );
    try testing.expectEqual(@as(usize, 2), edited.changes.len);

    const res = try repo.resolve(arena, uuid_fmt.shortId(created.id));
    const issue = try repo.load(arena, res.one);
    try testing.expectEqualStrings("Crash on login", issue.title);
    try testing.expectEqualStrings("First paragraph.\n\nSecond.", issue.description);
    try testing.expectEqualStrings("closed", issue.state.text());
    try testing.expectEqual(@as(usize, 2), issue.labels.len);
    try testing.expectEqualStrings("bug", issue.labels[0]);
    try testing.expectEqualStrings("regression", issue.labels[1]);
    try testing.expect(issue.field("Assignee") == null);
    try testing.expectEqualStrings("high", issue.field("Priority").?);
    try testing.expectEqualStrings("abc123", issue.field("Fixed-By").?);
    try testing.expectEqual(@as(usize, 3), issue.comments.len);
    try testing.expectEqualStrings("Repro on Firefox", issue.comments[0].subject);

    // Byte for byte what upstream writes.
    const root = (try sim.readObject(arena, issue.root)).?;
    const c = try object.Commit.parse(arena, .sha1, root.data);
    try testing.expectEqualStrings(
        "Crash on login\n\nFirst paragraph.\n\nSecond.\n\n" ++
            "State: open\nLabels: bug, auth\nAssignee: bob@e.x\n" ++
            "Priority: high\nFormat-Version: 1\n",
        c.message,
    );
    try testing.expect(c.tree.eql(object.emptyTree(.sha1)));
}

test "extension fields" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 21, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const parent = try repo.create(arena, .{ .title = "Epic" }, .{});
    const blocker = try repo.create(arena, .{ .title = "Blocker" }, .{});
    const other = try repo.create(arena, .{ .title = "Other" }, .{});

    const child = try repo.create(arena, .{
        .title = "Child",
        .assignees = &.{.{ .uuid = "a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e", .email = "ada@e.x" }},
        .parent = parent.id,
        .blocked_by = &.{ blocker.id, blocker.id },
        .start_date = fields_fmt.Date.parse("2026-11-01"),
        .due_date = fields_fmt.Date.parse("2026-12-01"),
        .estimate_minutes = 90,
        .workflow = "ready",
    }, .{});
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{child.id});
    var issue = try repo.load(arena, .{ .name = ref_name, .tip = child.tip });
    try testing.expectEqualStrings(parent.id, issue.parent.?);
    try testing.expectEqual(@as(usize, 1), issue.blocked_by.len); // deduplicated
    try testing.expectEqual(@as(?u32, 90), issue.estimate_minutes);
    try testing.expectEqualStrings("ready", issue.workflow.?);
    try testing.expectEqual(@as(usize, 0), issue.invalid_fields.len);

    const edited = try repo.edit(arena, ref_name, .{
        .add_blocked_by = &.{other.id},
        .remove_blocked_by = &.{blocker.id},
        .due_date = .clear,
        .estimate_minutes = .clear,
        .parent = .clear,
    }, .{});
    issue = try repo.load(arena, .{ .name = ref_name, .tip = edited.tip });
    try testing.expectEqual(@as(usize, 1), issue.blocked_by.len);
    try testing.expectEqualStrings(other.id, issue.blocked_by[0]);
    try testing.expect(issue.due_date == null and issue.estimate_minutes == null);
    try testing.expect(issue.parent == null);
    try testing.expectEqual(@as(u8, 11), issue.start_date.?.month);
    const subject = (try sim.readObject(arena, edited.tip)).?.data;
    const want = "Update parent, blockers, due date, estimate";
    try testing.expect(std.mem.find(u8, subject, want) != null);

    for ([_]CreateSpec{
        .{ .title = "x", .parent = "a7f3b2c" }, // short IDs must be resolved first
        .{ .title = "x", .due_date = .{ .year = 2026, .month = 2, .day = 30 } },
        .{ .title = "x", .workflow = "In Progress" },
        .{
            .title = "x",
            .assignees = &.{.{ .uuid = "a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e", .email = "" }},
        },
        .{ .title = "x", .blocked_by = &.{"nope"} },
    }) |bad| try testing.expectError(error.InvalidValue, repo.create(arena, bad, .{}));
    try testing.expectError(
        error.UnknownWorkflowState,
        repo.create(arena, .{ .title = "x", .workflow = "done" }, .{}),
    );
    // An invalid issue.workflowStates: no state can be set.
    var unset = repo;
    unset.settings.invalid_workflow_state = "Bad";
    try testing.expectError(
        error.InvalidWorkflowStates,
        unset.create(arena, .{ .title = "x", .workflow = "ready" }, .{}),
    );
    try testing.expectError(error.EmptyText, repo.create(arena, .{ .title = " " }, .{}));
    try testing.expectError(
        error.InvalidLabel,
        repo.create(arena, .{ .title = "x", .labels = &.{"a,b"} }, .{}),
    );
}

test "caller mistakes are errors, not panics" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 3, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const created = try repo.create(arena, .{ .title = "Target" }, .{});
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});

    try testing.expectError(error.NothingToEdit, repo.edit(arena, ref_name, .{}, .{}));
    try testing.expectError(error.MessageHasBody, repo.edit(arena, ref_name, .{
        .description = "New text.",
        .message = "Subject\n\nBody",
    }, .{}));
    // Without a body, the message is fine, and only its subject is written.
    const tip = (try repo.edit(
        arena,
        ref_name,
        .{ .description = "Newer text.", .message = "Subject\n  " },
        .{},
    )).tip;
    const written = (try sim.readObject(arena, tip)).?.data;
    try testing.expect(
        std.mem.startsWith(
            u8,
            written[std.mem.find(u8, written, "\n\n").? + 2 ..],
            "Subject\n\nNewer text.",
        ),
    );
    // A blank message is no message.
    const closed = try repo.setState(arena, ref_name, .{ .state = .closed, .message = " " }, .{});
    const close_msg = (try sim.readObject(arena, closed.tip)).?.data;
    try testing.expect(std.mem.find(u8, close_msg, "\n\nClose issue") != null);
    try testing.expectError(error.EmptyText, repo.edit(arena, ref_name, .{ .title = "" }, .{}));
    try testing.expectError(
        error.EmptyText,
        repo.comment(arena, ref_name, .{ .text = " \n" }, .{}),
    );
    for ([_][]const u8{ "refs/heads/main", "refs/issues/", "refs/issues/a..b", "x" }) |bad| {
        try testing.expectError(
            error.InvalidIssueRef,
            repo.comment(arena, bad, .{ .text = "hi" }, .{}),
        );
        try testing.expectError(
            error.InvalidIssueRef,
            repo.setState(arena, bad, .{ .state = .closed }, .{}),
        );
        try testing.expectError(
            error.InvalidIssueRef,
            repo.edit(arena, bad, .{ .title = "t" }, .{}),
        );
    }

    // Upstream's write rules hold for library callers too. Priorities
    // can't be wrong: they're an enum.
    for ([_]CreateSpec{
        .{ .title = "x", .assignees = &.{.byEmail("ada")} },
        .{ .title = "x", .assignees = &.{.byEmail("ada@example.")} },
    }) |bad| try testing.expectError(error.InvalidValue, repo.create(arena, bad, .{}));
    try testing.expectError(
        error.InvalidValue,
        repo.edit(arena, ref_name, .{ .set_assignees = &.{.byEmail("ada")} }, .{}),
    );
    try testing.expectError(
        error.InvalidValue,
        repo.setState(arena, ref_name, .{ .state = .{ .other = "in progress" } }, .{}),
    );
    _ = try repo.edit(arena, ref_name, .{ .priority = .clear, .set_assignees = &.{} }, .{});
}

test "expect" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 5, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const created = try repo.create(arena, .{ .title = "Versioned" }, .{});
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});

    // A client read the issue at `created.tip`, then someone else comments.
    const seen = created.tip;
    const other = try repo.comment(arena, ref_name, .{ .text = "Someone else" }, .{});

    try testing.expectError(
        error.VersionMismatch,
        repo.comment(arena, ref_name, .{ .text = "Mine", .expect = seen }, .{}),
    );
    try testing.expectError(
        error.VersionMismatch,
        repo.setState(arena, ref_name, .{ .state = .closed, .expect = seen }, .{}),
    );
    try testing.expectError(
        error.VersionMismatch,
        repo.edit(arena, ref_name, .{ .title = "Renamed", .expect = seen }, .{}),
    );
    // The refused calls wrote nothing.
    try testing.expect((try sim.resolveRef(ref_name)).?.eql(other.tip));

    const next = try repo.comment(arena, ref_name, .{ .text = "Mine", .expect = other.tip }, .{});
    const done = try repo.edit(arena, ref_name, .{ .title = "Renamed", .expect = next.tip }, .{});
    try testing.expect((try sim.resolveRef(ref_name)).?.eql(done.tip));
}

test "limits and paging" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 9, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    var repo = Repo(GitSim).init(&sim);
    for (0..5) |i| _ = try repo.create(arena, .{
        .title = try std.fmt.allocPrint(arena, "Issue {d}", .{i}),
    }, .{});

    var seen: usize = 0;
    var after: ?[]const u8 = null;
    var pages: usize = 0;
    while (true) {
        const page = try repo.loadPage(arena, .{ .after = after, .limit = 2 });
        seen += page.issues.len;
        pages += 1;
        after = page.next orelse break;
    }
    try testing.expectEqual(@as(usize, 5), seen);
    try testing.expectEqual(@as(usize, 3), pages);

    repo.limits.max_issues = 4;
    try testing.expectError(error.TooManyIssues, repo.loadAll(arena));
    repo.limits = .{};
    repo.limits.cas_retries = 0;
    try testing.expectError(error.InvalidLimits, repo.create(arena, .{ .title = "x" }, .{}));
    repo.limits = .{};
    repo.limits.max_body_bytes = Limits.maximum.max_body_bytes + 1;
    try testing.expectError(error.InvalidLimits, repo.loadAll(arena));
    try testing.expect(Limits.maximum.valid());
}

test "resolve: none, one, ambiguous" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 9, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    _ = try repo.create(arena, .{ .title = "one" }, .{});
    _ = try repo.create(arena, .{ .title = "two" }, .{});
    try testing.expect(try repo.resolve(arena, "zzzz") == .none);
    try testing.expect((try repo.resolve(arena, "")) == .many);
}

test "comments that would read as trailers are refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const created = try repo.create(arena, .{ .title = "t" }, .{});
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    try testing.expectError(
        error.BodyLooksLikeTrailers,
        repo.comment(arena, ref_name, .{ .text = "I agree.\n\nX-Deleted: true" }, .{}),
    );
    // A single line is the subject, never a trailer.
    _ = try repo.comment(arena, ref_name, .{ .text = "State: closed" }, .{});
    try testing.expectEqualStrings(
        "open",
        (try repo.load(
            arena,
            (try repo.resolve(arena, uuid_fmt.shortId(created.id))).one,
        )).state.text(),
    );
    try testing.expectError(error.InvalidText, repo.create(arena, .{ .title = "two\nlines" }, .{}));
}

test "a write that changes nothing isn't written" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 5, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    var repo = Repo(GitSim).init(&sim);
    var skipped = false;
    repo.call.skipped = &skipped;

    const made = try repo.create(arena, .{ .title = "Same", .labels = &.{ "bug", "ui" } }, .{});
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{made.id});
    // Every field as it is: no commit, the tip as it was.
    const same = try repo.edit(
        arena,
        ref,
        .{ .title = "Same", .set_labels = &.{ "bug", "ui" } },
        .{},
    );
    try testing.expect(!same.wrote and skipped);
    // Sets in another order are the same sets.
    const reordered = try repo.edit(arena, ref, .{
        .set_labels = &.{ "ui", "bug" },
        .set_assignees = &.{},
    }, .{});
    try testing.expect(!reordered.wrote and reordered.tip.eql(made.tip));
    try testing.expect(same.tip.eql(made.tip));
    try testing.expectEqual(@as(usize, 0), same.changes.len);
    try testing.expect(made.tip.eql((try repo.setState(arena, ref, .{ .state = .open }, .{})).tip));
    try testing.expect(
        made.tip.eql((try repo.setDeleted(arena, ref, .{ .deleted = false }, .{})).tip),
    );
    // Removing what isn't there, a clear of what was never set.
    const none = try repo.edit(
        arena,
        ref,
        .{ .remove_labels = &.{"absent"}, .parent = .clear },
        .{},
    );
    try testing.expect(!none.wrote and none.tip.eql(made.tip));

    // One real change among restatements writes, and says what changed.
    const one = try repo.edit(arena, ref, .{ .title = "Same", .add_labels = &.{"new"} }, .{});
    try testing.expect(one.wrote and !skipped and !one.tip.eql(made.tip));
    // A comment is always a change, with fields as they are.
    const said = try repo.edit(arena, ref, .{ .title = "Same", .comment = "Hello" }, .{});
    try testing.expect(said.wrote and !said.tip.eql(one.tip));
    // Expect still guards: a stale tip fails even when nothing would change.
    try testing.expectError(
        error.VersionMismatch,
        repo.edit(arena, ref, .{ .title = "Same", .expect = made.tip }, .{}),
    );
    // Without an embedder's flag the result still says so.
    repo.call.skipped = null;
    try testing.expect(!(try repo.edit(arena, ref, .{ .title = "Same" }, .{})).wrote);
    // Assignees and blockers as well.
    const two = try repo.edit(
        arena,
        ref,
        .{ .set_assignees = &.{ .byEmail("a@e.x"), .byEmail("b@e.x") } },
        .{},
    );
    try testing.expect(two.wrote);
    const swapped = try repo.edit(
        arena,
        ref,
        .{ .set_assignees = &.{ .byEmail("b@e.x"), .byEmail("a@e.x") } },
        .{},
    );
    try testing.expect(!swapped.wrote and swapped.tip.eql(two.tip));
}

test "X-Author-Id: each commit names its author's UUID" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 5, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    var repo = Repo(GitSim).init(&sim);
    const ada = "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d";
    const bob = "1d9e8b63-4a2f-4c7b-8e3d-6f5a4b3c2d1e";

    repo.call.author_id = ada;
    const made = try repo.create(arena, .{ .title = "Who wrote this" }, .{});
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{made.id});
    repo.call.author_id = bob;
    const said = try repo.comment(arena, ref, .{ .text = "Bob here" }, .{});
    repo.call.author_id = null;
    const anon = try repo.comment(arena, ref, .{ .text = "No one" }, .{});

    const issue = try repo.load(arena, .{ .name = ref, .tip = anon.tip });
    try testing.expectEqualStrings(ada, issue.author_id.?);
    try testing.expectEqualStrings(bob, issue_model.authorIdAt(issue.author_ids, said.tip).?);
    try testing.expect(issue_model.authorIdAt(issue.author_ids, anon.tip) == null);
    // A per-commit trailer: never an issue field.
    for (issue.fields) |f| try testing.expect(!std.ascii.eqlIgnoreCase(
        f.key,
        issue_model.author_id_key,
    ));

    // Who wrote a write that changes nothing doesn't make it a change.
    repo.call.author_id = bob;
    const same = try repo.edit(arena, ref, .{ .title = "Who wrote this" }, .{});
    try testing.expect(!same.wrote and same.tip.eql(anon.tip));
    // Not a UUID: refused before anything is written.
    repo.call.author_id = "not-a-uuid";
    try testing.expectError(error.InvalidValue, repo.create(arena, .{ .title = "Bad" }, .{}));
    try testing.expectError(error.InvalidValue, repo.comment(arena, ref, .{ .text = "Bad" }, .{}));
}

test "a comment, a state change and fields in one commit" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 5, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);

    const epic = try repo.create(arena, .{ .title = "Epic" }, .{});
    const epic_ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{epic.id});
    const task = try repo.create(arena, .{ .title = "Task", .parent = epic.id }, .{});

    // Refused like setState: the task under it is open.
    try testing.expectError(error.OpenDescendants, repo.edit(arena, epic_ref, .{
        .comment = "Done.",
        .state = .closed,
    }, .{}));
    const task_ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{task.id});
    const closed = try repo.edit(arena, task_ref, .{
        .comment = "Fixed in abc.",
        .add_labels = &.{"done"},
        .state = .closed,
        .fixed_by = "abc123",
    }, .{});
    const issue = try repo.load(arena, .{ .name = task_ref, .tip = closed.tip });
    try testing.expectEqualStrings("closed", issue.state.text());
    try testing.expectEqualStrings("abc123", issue.field("Fixed-By").?);
    try testing.expectEqual(@as(usize, 1), issue.labels.len);
    // The one-line comment reads as a comment, not as the tool's update.
    try testing.expectEqual(@as(usize, 1), issue.comments.len);
    try testing.expectEqual(issuez_model_kind_comment, issue.comments[0].kind);
    try testing.expectEqualStrings("Fixed in abc.", issue.comments[0].subject);
    try testing.expect(issue.field("X-Message") == null);
    const commit = (try sim.readObject(arena, closed.tip)).?;
    const c = try object.Commit.parse(arena, .sha1, commit.data);
    try testing.expectEqualStrings(
        "Fixed in abc.\n\nState: closed\nFixed-By: abc123\nLabels: done\nX-Message: comment\n",
        c.message,
    );

    try testing.expectError(error.CommentNotAlone, repo.edit(arena, task_ref, .{
        .comment = "x",
        .description = "new",
    }, .{}));
    try testing.expectError(
        error.InvalidValue,
        repo.edit(arena, task_ref, .{ .title = "t", .fixed_by = "x" }, .{}),
    );
}

const issuez_model_kind_comment = issue_model.Comment.Kind.comment;

test "several assignees" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 9, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);

    const ada_id = "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d";
    const ada = ada_id ++ " ada@e.x";
    const created = try repo.create(arena, .{
        .title = "Pair",
        .assignees = &.{ .{ .uuid = ada_id, .email = "ada@e.x" }, .byEmail("bob@e.x") },
    }, .{});
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    const root = (try sim.readObject(arena, created.tip)).?;
    const rc = try object.Commit.parse(arena, .sha1, root.data);
    try testing.expect(std.mem.indexOf(u8, rc.message, "Assignee: " ++ ada ++ "\n") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        rc.message,
        "X-Assignees: " ++ ada ++ ", bob@e.x\n",
    ) != null);
    var issue = try repo.load(arena, .{ .name = ref, .tip = created.tip });
    try testing.expectEqual(@as(usize, 2), issue.assignees.len);
    try testing.expectEqualStrings("ada@e.x", issue.assignees[0].email);

    // Down to one: only `Assignee`, as upstream writes it.
    const one = try repo.edit(arena, ref, .{ .remove_assignees = &.{"ada@e.x"} }, .{});
    const oc = try object.Commit.parse(arena, .sha1, (try sim.readObject(arena, one.tip)).?.data);
    try testing.expect(std.mem.indexOf(u8, oc.message, "X-Assignees") == null);
    issue = try repo.load(arena, .{ .name = ref, .tip = one.tip });
    try testing.expectEqual(@as(usize, 1), issue.assignees.len);
    try testing.expectEqualStrings("bob@e.x", issue.assignees[0].email);

    const more = try repo.edit(
        arena,
        ref,
        .{ .add_assignees = &.{ .byEmail("cy@e.x"), .byEmail("bob@e.x") } },
        .{},
    );
    issue = try repo.load(arena, .{ .name = ref, .tip = more.tip });
    try testing.expectEqual(@as(usize, 2), issue.assignees.len);
    const none = try repo.edit(arena, ref, .{ .set_assignees = &.{} }, .{});
    issue = try repo.load(arena, .{ .name = ref, .tip = none.tip });
    try testing.expectEqual(@as(usize, 0), issue.assignees.len);
    try testing.expectError(
        error.InvalidValue,
        repo.edit(arena, ref, .{ .add_assignees = &.{.byEmail("not an email")} }, .{}),
    );
}

test "lock and ref" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 11, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const created = try repo.create(arena, .{ .title = "Heated" }, .{});
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});

    const locked = try repo.edit(
        arena,
        ref,
        .{ .locked = true, .lock_reason = "too heated", .ref = .{ .set = "main" } },
        .{},
    );
    var issue = try repo.load(arena, .{ .name = ref, .tip = locked.tip });
    try testing.expect(issue.locked);
    try testing.expectEqualStrings("too heated", issue.lock_reason.?);
    try testing.expectEqualStrings("main", issue.ref.?);
    // Unlocking clears the reason; "" clears the ref.
    const open = try repo.edit(arena, ref, .{ .locked = false, .ref = .clear }, .{});
    issue = try repo.load(arena, .{ .name = ref, .tip = open.tip });
    try testing.expect(!issue.locked);
    try testing.expect(issue.lock_reason == null and issue.ref == null);
    try testing.expectError(
        error.InvalidValue,
        repo.edit(arena, ref, .{ .ref = .{ .set = "a b" } }, .{}),
    );
    try testing.expectError(
        error.InvalidValue,
        repo.edit(arena, ref, .{ .title = "t", .lock_reason = "x" }, .{}),
    );
}

test "host fields and provenance" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 13, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const created = try repo.create(arena, .{
        .title = "Imported",
        .extra = &.{.{ .key = "X-Forgejo-Project", .value = "7" }},
        .original = .{ .author = "octocat", .id = "github:o/r#1" },
    }, .{});
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    const commented = try repo.comment(arena, ref, .{
        .text = "Thanks",
        .original = .{ .author = "hubot", .id = "github:o/r#c-2" },
    }, .{});
    const edited = try repo.edit(
        arena,
        ref,
        .{ .extra = &.{.{ .key = "X-Forgejo-Project", .value = "" }} },
        .{},
    );
    _ = commented;
    const issue = try repo.load(arena, .{ .name = ref, .tip = edited.tip });
    try testing.expect(issue.field("X-Forgejo-Project") == null);
    try testing.expectEqualStrings("octocat", issue.original_author.?);
    try testing.expectEqualStrings("github:o/r#1", issue.original_id.?);
    try testing.expect(issue.field("X-Original-Author") == null);
    try testing.expectEqual(issue_model.Comment.Kind.comment, issue.comments[0].kind);
    try testing.expectEqualStrings("hubot", issue.comments[0].original_author.?);
    for ([_][]const u8{ "State", "Labels", "Foo", "X-Original-Id", "X-Event" }) |key| {
        try testing.expectError(
            error.InvalidValue,
            repo.edit(arena, ref, .{ .extra = &.{.{ .key = key, .value = "x" }} }, .{}),
        );
    }
}

test "reactions" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 17, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const created = try repo.create(arena, .{ .title = "Liked" }, .{});
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    const c = try repo.comment(arena, ref, .{ .text = "Nice" }, .{});

    const sig = struct {
        fn of(name: []const u8, email: []const u8) Signature {
            return .{ .name = name, .email = email, .time = 1000, .tz_offset_minutes = 0 };
        }
    }.of;
    try testing.expect((try repo.react(
        arena,
        ref,
        .{ .emoji = ":+1:", .author = sig("Ada", "ada@e.x") },
        .{},
    )).wrote);
    // The same again writes nothing.
    try testing.expect((try repo.react(
        arena,
        ref,
        .{ .emoji = ":+1:", .author = sig("Ada", "ada@e.x") },
        .{},
    )).wrote == false);
    _ = try repo.react(arena, ref, .{ .emoji = ":+1:", .author = sig("Bob", "bob@e.x") }, .{});
    _ = try repo.react(
        arena,
        ref,
        .{ .target = c.tip, .emoji = ":heart:", .author = sig("Ada", "ada@e.x") },
        .{},
    );
    var issue = try repo.load(arena, (try repo.resolve(arena, created.id)).one);
    try testing.expectEqual(@as(usize, 2), issue.reactions.len);
    try testing.expect(issue.reactions[0].target == null);
    try testing.expectEqual(@as(usize, 2), issue.reactions[0].users.len);
    try testing.expectEqualStrings("Ada", issue.reactions[0].users[0].name);
    try testing.expect(issue.reactions[1].target.?.eql(c.tip));
    // Reactions are events, not comments.
    try testing.expectEqual(@as(usize, 1), issue.comments.len);

    _ = try repo.react(
        arena,
        ref,
        .{ .emoji = ":+1:", .present = false, .author = sig("Ada", "ada@e.x") },
        .{},
    );
    issue = try repo.load(arena, (try repo.resolve(arena, created.id)).one);
    try testing.expectEqual(@as(usize, 1), issue.reactions[0].users.len);
    try testing.expectEqualStrings("bob@e.x", issue.reactions[0].users[0].email);
    try testing.expectError(
        error.InvalidValue,
        repo.react(arena, ref, .{ .emoji = "two words" }, .{}),
    );
    try testing.expectError(
        error.CommentNotFound,
        repo.react(arena, ref, .{ .target = created.tip, .emoji = "x" }, .{}),
    );
}

test "guards" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 31, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const refOf = struct {
        fn f(a: Allocator, c: Created) ![]const u8 {
            return std.fmt.allocPrint(a, "refs/issues/{s}", .{c.id});
        }
    }.f;

    const epic = try repo.create(arena, .{ .title = "Epic" }, .{});
    const task = try repo.create(arena, .{ .title = "Task", .parent = epic.id }, .{});
    const sub = try repo.create(arena, .{ .title = "Sub", .parent = task.id }, .{});

    try testing.expectError(error.ParentIsSelf, repo.edit(arena, try refOf(arena, epic), .{
        .parent = .{ .set = epic.id },
    }, .{}));
    try testing.expectError(error.ParentCycle, repo.edit(arena, try refOf(arena, epic), .{
        .parent = .{ .set = sub.id },
    }, .{}));
    try testing.expectError(error.ReferenceNotFound, repo.create(arena, .{
        .title = "x",
        .parent = "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
    }, .{}));
    // A chain of depth 8 is fine, a ninth level isn't.
    var chain = sub; // depth 2
    for (3..9) |_| chain = try repo.create(arena, .{ .title = "deep", .parent = chain.id }, .{});
    try testing.expectError(error.TooDeep, repo.create(arena, .{
        .title = "too deep",
        .parent = chain.id,
    }, .{}));
    // Moving a subtree counts its height.
    const side = try repo.create(arena, .{ .title = "Side" }, .{});
    try testing.expectError(error.TooDeep, repo.edit(arena, try refOf(arena, epic), .{
        .parent = .{ .set = side.id },
    }, .{}));

    const b1 = try repo.create(arena, .{ .title = "B1", .blocked_by = &.{side.id} }, .{});
    try testing.expectError(error.BlocksItself, repo.edit(arena, try refOf(arena, b1), .{
        .add_blocked_by = &.{b1.id},
    }, .{}));
    try testing.expectError(error.BlockerCycle, repo.edit(arena, try refOf(arena, side), .{
        .add_blocked_by = &.{b1.id},
    }, .{}));

    try testing.expectError(
        error.OpenDescendants,
        repo.setState(arena, try refOf(arena, task), .{ .state = .closed }, .{}),
    );
    const leaf = try repo.create(arena, .{ .title = "Leaf", .parent = side.id }, .{});
    // Any state but open is done: a `wontfix` leaf doesn't hold its parent
    // open, and counts as closing.
    _ = try repo.setState(
        arena,
        try refOf(arena, leaf),
        .{ .state = .{ .other = "wontfix" } },
        .{},
    );
    _ = try repo.setState(arena, try refOf(arena, leaf), .{ .state = .closed }, .{});
    _ = try repo.setState(arena, try refOf(arena, side), .{ .state = .closed }, .{});
    try testing.expectError(error.ClosedAncestor, repo.create(arena, .{
        .title = "Under closed",
        .parent = side.id,
    }, .{}));
    try testing.expectError(
        error.ClosedAncestor,
        repo.setState(arena, try refOf(arena, leaf), .{ .state = .open }, .{}),
    );
    try testing.expectError(error.ClosedAncestor, repo.edit(arena, try refOf(arena, b1), .{
        .parent = .{ .set = side.id },
    }, .{}));
    _ = try repo.setState(arena, try refOf(arena, side), .{ .state = .open }, .{});
    _ = try repo.setState(arena, try refOf(arena, leaf), .{ .state = .open }, .{});

    // Whatever the guards let through leaves no violation.
    const issues = try repo.loadAll(arena);
    const proj = try @import("projection.zig").build(arena, issues, .{});
    try testing.expectEqual(@as(usize, 0), proj.problems.len);
}

test "parent cache: stale entries are reloaded, a broken cache is ignored" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 37, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const nameOf = struct {
        fn f(a: Allocator, c: Created) ![]const u8 {
            return std.fmt.allocPrint(a, "refs/issues/{s}", .{c.id});
        }
    }.f;

    const epic = try repo.create(arena, .{ .title = "Epic" }, .{});
    const one = try repo.create(arena, .{ .title = "One", .parent = epic.id }, .{});
    // A refused close writes nothing, not even the cache.
    try testing.expectError(error.OpenDescendants, repo.setState(
        arena,
        try nameOf(arena, epic),
        .{ .state = .closed },
        .{},
    ));
    try testing.expect(try sim.resolveRef(parent_cache_ref) == null);
    _ = try repo.setState(arena, try nameOf(arena, one), .{ .state = .closed }, .{});
    const first = (try sim.resolveRef(parent_cache_ref)).?;

    // Not in the cache yet: found by loading it.
    const two = try repo.create(arena, .{ .title = "Two", .parent = epic.id }, .{});
    try testing.expectError(error.OpenDescendants, repo.setState(
        arena,
        try nameOf(arena, epic),
        .{ .state = .closed },
        .{},
    ));
    _ = try repo.setState(arena, try nameOf(arena, two), .{ .state = .closed }, .{});
    // A few stale entries don't make it worth rewriting.
    try testing.expect((try sim.resolveRef(parent_cache_ref)).?.eql(first));

    // Garbage instead of a cache: it's rebuilt.
    const junk = try sim.writeObject(.blob, "not a cache\n");
    try sim.updateRefs(&.{.{
        .name = parent_cache_ref,
        .op = .{ .update = .{ .new = junk, .old = (try sim.resolveRef(parent_cache_ref)).? } },
    }});
    _ = try repo.setState(arena, try nameOf(arena, two), .{ .state = .open }, .{});
    try testing.expectError(error.OpenDescendants, repo.setState(
        arena,
        try nameOf(arena, epic),
        .{ .state = .closed },
        .{},
    ));
    _ = try repo.setState(arena, try nameOf(arena, two), .{ .state = .closed }, .{});
    _ = try repo.setState(arena, try nameOf(arena, epic), .{ .state = .closed }, .{});
    try testing.expect(!(try sim.resolveRef(parent_cache_ref)).?.eql(junk));
}

test "guards on foreign cycles" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 35, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const a = try repo.create(arena, .{ .title = "A" }, .{});
    const b = try repo.create(arena, .{ .title = "B", .parent = a.id }, .{});
    const a_ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{a.id});

    // Someone else closes A and makes it B's child: an A, B cycle.
    const who = try sim.identity(arena);
    const msg = try std.fmt.allocPrint(
        arena,
        "Edit\n\nState: closed\nX-Parent: {s}\n",
        .{b.id},
    );
    const foreign = try repo.writeCommit(arena, &.{a.tip}, who, msg);
    try sim.updateRefs(&.{.{
        .name = a_ref,
        .op = .{ .update = .{ .new = foreign, .old = a.tip } },
    }});

    // Reopening A walks up through B back to A. That must neither put A's
    // ref in the transaction twice nor fail because A was closed.
    _ = try repo.setState(arena, a_ref, .{ .state = .open }, .{});
    const now = try repo.load(arena, .{ .name = a_ref, .tip = (try sim.resolveRef(a_ref)).? });
    try testing.expectEqualStrings("open", now.state.text());
}

test "lifecycle" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 41, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const parent = try repo.create(arena, .{ .title = "Parent", .body = "Old." }, .{});
    const child = try repo.create(arena, .{ .title = "Child", .parent = parent.id }, .{});
    const ref = try refNameOf(arena, parent.id);
    const latest = struct {
        fn f(r: Repo(GitSim), a: Allocator, s: *GitSim, name: []const u8) !Issue {
            return r.load(a, .{ .name = name, .tip = (try s.resolveRef(name)).? });
        }
    }.f;

    const c = try repo.comment(arena, ref, .{ .text = "Tpyo here" }, .{});
    _ = try repo.commentEvent(
        arena,
        ref,
        .{ .target = c.tip, .event = .edit, .text = "Typo fixed" },
        .{},
    );
    var issue = try latest(repo, arena, &sim, ref);
    try testing.expectEqualStrings("Typo fixed", issue.comments[0].subject);
    try testing.expect(issue.comments[0].edited);
    _ = try repo.commentEvent(arena, ref, .{ .target = c.tip, .event = .delete }, .{});
    issue = try latest(repo, arena, &sim, ref);
    try testing.expect(issue.comments[0].deleted);
    _ = try repo.commentEvent(arena, ref, .{ .target = c.tip, .event = .restore }, .{});
    try testing.expectError(
        error.CommentNotFound,
        repo.commentEvent(arena, ref, .{ .target = parent.tip, .event = .delete }, .{}), // the root
    );

    _ = try repo.edit(arena, ref, .{ .description = "New.\n\nTwo paragraphs." }, .{});
    issue = try latest(repo, arena, &sim, ref);
    try testing.expectEqualStrings("New.\n\nTwo paragraphs.", issue.description);
    try testing.expectEqual(@as(usize, 1), issue.comments.len); // events aren't comments

    // A parent with an active child can't be deleted, bottom-up works.
    try testing.expectError(error.ActiveChildren, repo.setDeleted(arena, ref, .{}, .{}));
    _ = try repo.setDeleted(arena, try refNameOf(arena, child.id), .{}, .{});
    _ = try repo.setDeleted(arena, ref, .{}, .{});
    issue = try latest(repo, arena, &sim, ref);
    try testing.expect(issue.deleted);
    _ = try repo.setDeleted(arena, ref, .{ .deleted = false }, .{});
    try testing.expect(!(try latest(repo, arena, &sim, ref)).deleted);

    // A closed parent gains open work while deleted (deleted ancestors
    // don't stop a reopen): it can't come back until that work is closed.
    const child_ref = try refNameOf(arena, child.id);
    _ = try repo.setState(arena, ref, .{ .state = .closed }, .{});
    _ = try repo.setDeleted(arena, ref, .{}, .{});
    _ = try repo.setDeleted(arena, child_ref, .{ .deleted = false }, .{});
    try testing.expectError(
        error.OpenDescendants,
        repo.setDeleted(arena, ref, .{ .deleted = false }, .{}),
    );
    _ = try repo.setState(arena, child_ref, .{ .state = .closed }, .{});
    _ = try repo.setDeleted(arena, ref, .{ .deleted = false }, .{});
}

test "guards under concurrent change" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 33, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const parent = try Repo(GitSim).init(&sim).create(arena, .{ .title = "Parent" }, .{});
    const parent_ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{parent.id});

    // The parent gets closed between our guard read and our write. The
    // verify line fails and the retry sees it closed.
    var racing: RacingSim = .{
        .sim = &sim,
        .race = .{ .ref = parent_ref, .message = "", .close = true },
    };
    const repo = Repo(RacingSim).init(&racing);
    try testing.expectError(error.ClosedAncestor, repo.create(arena, .{
        .title = "Child",
        .parent = parent.id,
    }, .{}));
    try testing.expectEqual(@as(usize, 1), (try repo.refs(arena)).len);

    // A child appears between our scan of the children and our write. A
    // verify line can't pin that absence. The guard ref makes the write
    // conflict, and the retry sees the child.
    for ([_]bool{ false, true }) |delete| {
        const epic = try Repo(GitSim).init(&sim).create(arena, .{ .title = "Epic" }, .{});
        const epic_ref = try refNameOf(arena, epic.id);
        racing.race = .{ .ref = epic_ref, .message = "", .child_of = epic.id };
        if (delete) {
            try testing.expectError(
                error.ActiveChildren,
                repo.setDeleted(arena, epic_ref, .{}, .{}),
            );
        } else {
            try testing.expectError(error.OpenDescendants, repo.setState(arena, epic_ref, .{
                .state = .closed,
            }, .{}));
        }
        try testing.expect(racing.race == null);
    }
}

test "guards skip what they can't read" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 37, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const leaf = try repo.create(arena, .{ .title = "Leaf" }, .{});

    // A damaged issue elsewhere doesn't stop closing a healthy one.
    const blob = try sim.writeObject(.blob, "not a commit");
    try sim.updateRefs(&.{.{
        .name = "refs/issues/0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
        .op = .{ .create = blob },
    }});
    _ = try repo.setState(arena, try refNameOf(arena, leaf.id), .{ .state = .closed }, .{});

    // Its own parent, from another tool, isn't its own child.
    const selfish = try repo.create(arena, .{ .title = "Selfish" }, .{});
    const ref = try refNameOf(arena, selfish.id);
    const who = try sim.identity(arena);
    const msg = try std.fmt.allocPrint(arena, "Edit\n\nX-Parent: {s}\n", .{selfish.id});
    const foreign = try repo.writeCommit(arena, &.{selfish.tip}, who, msg);
    try sim.updateRefs(
        &.{.{ .name = ref, .op = .{ .update = .{ .new = foreign, .old = selfish.tip } } }},
    );
    _ = try repo.setDeleted(arena, ref, .{}, .{});
}

test "CAS conflict rebuilds the commit" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const created = try Repo(
        GitSim,
    ).init(&sim).create(arena, .{ .title = "t", .labels = &.{"a"} }, .{});
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});

    var racing: RacingSim = .{
        .sim = &sim,
        .race = .{ .ref = ref_name, .message = "concurrent comment" },
    };
    var repo = Repo(RacingSim).init(&racing);
    var retries: u32 = 99;
    repo.call.retries = &retries;
    _ = try repo.edit(arena, ref_name, .{ .add_labels = &.{"b"} }, .{});
    try testing.expectEqual(@as(u32, 1), retries);
    _ = try repo.edit(arena, ref_name, .{ .add_labels = &.{"c"} }, .{});
    try testing.expectEqual(@as(u32, 0), retries);

    const issue = try repo.load(
        arena,
        .{ .name = ref_name, .tip = (try sim.resolveRef(ref_name)).? },
    );
    // Both the concurrent comment and our edits survive, in one chain.
    try testing.expectEqual(@as(usize, 3), issue.comments.len);
    try testing.expectEqualStrings("concurrent comment", issue.comments[0].subject);
    try testing.expectEqualStrings("Update labels", issue.comments[1].subject);
    try testing.expectEqual(@as(usize, 3), issue.labels.len);
}

test "a full issue swaps a label in one edit" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    var repo = Repo(GitSim).init(&sim);
    repo.limits.max_labels = 2;
    const created = try repo.create(arena, .{ .title = "Full", .labels = &.{ "a", "b" } }, .{});
    const ref = try refNameOf(arena, created.id);
    _ = try repo.edit(arena, ref, .{ .add_labels = &.{"c"}, .remove_labels = &.{"a"} }, .{});
    const issue = try repo.load(arena, .{ .name = ref, .tip = (try sim.resolveRef(ref)).? });
    try testing.expectEqual(@as(usize, 2), issue.labels.len);
    try testing.expectError(
        error.TooManyLabels,
        repo.edit(arena, ref, .{ .add_labels = &.{"d"} }, .{}),
    );
}

test "a dry run checks everything and writes nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    var repo = Repo(GitSim).init(&sim);
    const parent = try repo.create(arena, .{ .title = "Parent" }, .{});
    const pref = try refNameOf(arena, parent.id);
    _ = try repo.create(arena, .{ .title = "Child", .parent = parent.id }, .{});
    const objects = sim.objects.count();
    const tip = (try sim.resolveRef(pref)).?;

    repo.call.dry_run = true;
    const would = try repo.create(arena, .{ .title = "Not written" }, .{});
    try testing.expect(try sim.resolveRef(try refNameOf(arena, would.id)) == null);
    const edited = try repo.edit(arena, pref, .{ .title = "Renamed" }, .{});
    try testing.expect(!edited.tip.eql(tip));
    try testing.expect((try sim.resolveRef(pref)).?.eql(tip));
    // Guards still run.
    try testing.expectError(
        error.OpenDescendants,
        repo.setState(arena, pref, .{ .state = .closed }, .{}),
    );
    try testing.expectEqual(objects, sim.objects.count());
    try testing.expectEqual(@as(usize, 2), (try repo.refs(arena)).len);
}

test "dropAll: every ref of the library's goes, the rest stays" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 61, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    var repo: Repo(GitSim) = .init(&sim);
    _ = try repo.create(arena, .{ .title = "One" }, .{});
    _ = try repo.create(arena, .{ .title = "Two" }, .{});
    const blob = try sim.writeObject(.blob, "x");
    try sim.updateRefs(&.{.{ .name = "refs/heads/main", .op = .{ .create = blob } }});
    try testing.expect(try repo.dropAll(arena) >= 2);
    try testing.expectEqual(@as(usize, 0), (try repo.refs(arena)).len);
    try testing.expect(try sim.resolveRef("refs/heads/main") != null);
    try testing.expectEqual(@as(usize, 0), try repo.dropAll(arena));
}

test "adoptFrom: another repository's refs, at once, never over ours" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{
        .seed = 67,
        .clones = &.{ .{ .name = "main" }, .{ .name = "scratch" } },
    };
    var main_sim = try GitSim.init(arena, &world, 0);
    var scratch_sim = try GitSim.init(arena, &world, 1);
    var main: Repo(GitSim) = .init(&main_sim);
    var scratch: Repo(GitSim) = .init(&scratch_sim);
    _ = try scratch.create(arena, .{ .title = "One" }, .{});
    _ = try scratch.create(arena, .{ .title = "Two" }, .{});
    // Objects this repository doesn't have: nothing is taken.
    try testing.expectError(error.CorruptIssue, main.adoptFrom(arena, scratch));
    try testing.expectEqual(@as(usize, 0), (try main.refs(arena)).len);
    // Shared objects, as a scratch repository writing into ours has them.
    for (try scratch.refs(arena)) |r| for (try scratch.loadCommits(arena, r.tip)) |c| {
        // The simulator keeps no empty trees.
        if (c.tree) |t| if (try scratch_sim.readObject(arena, t)) |tree| {
            _ = try main_sim.writeObject(tree.kind, tree.data);
        };
        const o = (try scratch_sim.readObject(arena, c.oid)).?;
        _ = try main_sim.writeObject(o.kind, o.data);
    };
    try testing.expectEqual(@as(usize, 2), try main.adoptFrom(arena, scratch));
    try testing.expectEqual(@as(usize, 2), (try main.refs(arena)).len);
    // Again: the refs are there, so nothing is taken.
    try testing.expectError(error.RefConflict, main.adoptFrom(arena, scratch));
}

test "writes take an issue's UUID as well as its ref; find loads by UUID" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 83, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const made = try repo.create(arena, .{ .title = "By ID" }, .{});
    const id = made.id;
    _ = try repo.edit(arena, id, .{ .add_labels = &.{"bug"} }, .{});
    _ = try repo.comment(arena, id, .{ .text = "Seen." }, .{});
    _ = try repo.setState(arena, id, .{ .state = .closed }, .{});
    _ = try repo.react(arena, id, .{ .emoji = ":+1:" }, .{});
    const issue = (try repo.find(arena, id)).?;
    try testing.expectEqualStrings("bug", issue.labels[0]);
    try testing.expect(issue.state == .closed);
    try testing.expectEqual(@as(usize, 1), issue.reactions.len);
    try testing.expect(try repo.find(arena, "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c") == null);
}

test "open: git config's settings applied, invalid done states refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 89, .clones = &.{.{ .name = "a", .config = &.{
        .{ .key = "issue.doneStates", .value = "cancelled" },
        .{ .key = "issue.workflowStates", .value = "todo,doing" },
    } }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = try Repo(GitSim).open(arena, &sim);
    try testing.expectEqualStrings("cancelled", repo.doneStates()[0]);
    try testing.expectEqualStrings("doing", repo.workflowStates().?[1]);
    try testing.expectEqualStrings("cancelled", repo.settings.done_states[0]);
    try testing.expectError(
        error.InvalidDoneStates,
        Repo(GitSim).fromSettings(&sim, .{ .invalid_done_state = "open" }),
    );
}

test "update: one entry for every write, with its receipt" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 97, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const made = try repo.create(arena, .{ .title = "Routed" }, .{});
    const id = made.id;
    const said = try repo.update(arena, id, .{ .edit = .{ .comment = "Hello" } }, .{});
    try testing.expect(said.wrote and said.kind == .comment);
    const closed = try repo.update(arena, id, .{ .edit = .{ .state = .closed } }, .{});
    try testing.expect(closed.wrote and closed.kind == .update);
    const again = try repo.update(arena, id, .{ .edit = .{ .state = .closed } }, .{});
    try testing.expect(!again.wrote and again.tip.eql(closed.tip));
    const edited = try repo.update(arena, id, .{
        .edit = .{ .comment = "Hello, edited" },
        .comment_event = .{ .target = said.tip, .event = .edit },
    }, .{});
    try testing.expect(edited.wrote and edited.kind == .comment_edit);
    const reacted = try repo.update(arena, id, .{ .reaction = .{ .emoji = ":+1:" } }, .{});
    try testing.expect(reacted.wrote and reacted.kind == .reaction);
    const nothing = try repo.update(arena, id, .{}, .{});
    try testing.expect(!nothing.wrote and nothing.tip.eql(reacted.tip));
    const dry = try repo.update(
        arena,
        id,
        .{ .edit = .{ .title = "Not written" } },
        .{ .dry_run = true },
    );
    try testing.expectEqualStrings("Routed", (try repo.find(arena, id)).?.title);
    _ = dry;
    const gone = try repo.update(arena, id, .{ .deleted = true }, .{});
    try testing.expect(
        gone.wrote and gone.kind == .deleted and (try repo.find(arena, id)).?.deleted,
    );
}

test "diagnostics: a refused write says the field, the value and the limit" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 107, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    var repo = Repo(GitSim).init(&sim);
    var d: errors_mod.Diagnostics = .{ .arena = arena };
    repo.call.diagnostics = &d;
    const made = try repo.create(arena, .{ .title = "Checked" }, .{});
    const id = made.id;
    try testing.expectError(
        error.InvalidLabel,
        repo.edit(arena, id, .{ .add_labels = &.{"a,b"} }, .{}),
    );
    try testing.expectEqualStrings("Labels", d.last().?.key);
    try testing.expectEqualStrings("a,b", d.last().?.value);
    try testing.expectError(
        error.InvalidValue,
        repo.edit(arena, id, .{ .add_blocked_by = &.{"nope"} }, .{}),
    );
    try testing.expectEqualStrings("X-Blocked-By", d.last().?.key);
    repo.limits.max_title_bytes = 4;
    try testing.expectError(error.TooLong, repo.create(arena, .{ .title = "Too long" }, .{}));
    try testing.expectEqualStrings("Title", d.last().?.key);
    try testing.expectEqual(@as(?u64, 4), d.last().?.limit);
    // Per call, through update.
    var e: errors_mod.Diagnostics = .{ .arena = arena };
    repo.call.diagnostics = null;
    try testing.expectError(error.InvalidValue, repo.update(arena, id, .{
        .edit = .{ .add_assignees = &.{.byEmail("not an email")} },
    }, .{ .diagnostics = &e }));
    try testing.expectEqualStrings("Assignee", e.last().?.key);
}

test "MilestoneEdit: parts and back" {
    const P = MilestoneEdit.Parts;
    try testing.expectEqual(P{}, MilestoneEdit.toParts(null));
    try testing.expect(MilestoneEdit.fromParts(.{}) == null);
    const linked = MilestoneEdit.toParts(.linked("m1"));
    try testing.expectEqualStrings("m1", linked.id.?);
    try testing.expectEqual(@as(?fields_fmt.MilestoneMode, .explicit), linked.mode);
    try testing.expect(MilestoneEdit.toParts(.named("v1")).mode == null);
    const pin = MilestoneEdit.fromParts(.{ .mode = .explicit }).?;
    try testing.expect(pin.link == .pin and pin.text == null);
    const text_none = MilestoneEdit.fromParts(.{ .text = "", .mode = .none }).?;
    try testing.expect(text_none.link == .none);
    try testing.expectEqualStrings("", text_none.text.?);
}

test "text expectations survive unrelated races and reject concurrent text edits" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 211, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(a, &world, 0);
    const plain = Repo(GitSim).init(&sim);
    const made = try plain.create(a, .{ .title = "Versioned", .body = "Original" }, .{});
    const ref = try refNameOf(a, made.id);
    const comment = try plain.comment(a, ref, .{ .text = "Comment" }, .{});
    try testing.expectError(error.InvalidValue, plain.update(a, ref, .{
        .edit = .{ .title = "Ignored?" },
        .deleted = true,
    }, .{}));
    try testing.expectError(error.InvalidValue, plain.update(a, ref, .{
        .edit = .{ .comment = "Ignored?" },
        .reaction = .{ .emoji = "+1" },
    }, .{}));
    try testing.expectError(error.InvalidValue, plain.update(a, ref, .{
        .edit = .{ .expect_edits = 0 },
        .comment_event = .{ .target = comment.tip, .event = .delete },
    }, .{}));
    var racing: RacingSim = .{
        .sim = &sim,
        .race = .{ .ref = ref, .message = "Unrelated comment" },
    };
    const repo = Repo(RacingSim).init(&racing);
    const written = try repo.update(a, made.id, .{
        .edit = .{ .description = "Changed", .expect_edits = 0 },
    }, .{});
    try testing.expectEqual(@as(u32, 1), written.retries);
    racing.race = .{ .ref = ref, .message = "Another unrelated comment" };
    const edited = try repo.update(a, made.id, .{
        .edit = .{ .comment = "Edited comment", .expect_edits = 0 },
        .comment_event = .{ .target = comment.tip, .event = .edit },
    }, .{});
    try testing.expectEqual(@as(u32, 1), edited.retries);
    racing.race = .{ .ref = ref, .message = "Their description", .description = true };
    try testing.expectError(error.VersionMismatch, repo.update(a, ref, .{
        .edit = .{ .description = "Our description", .expect_edits = 1 },
    }, .{}));
    racing.race = .{ .ref = ref, .message = "Their comment", .comment_edit = comment.tip };
    try testing.expectError(error.VersionMismatch, repo.update(a, ref, .{
        .edit = .{ .comment = "Our comment", .expect_edits = 1 },
        .comment_event = .{ .target = comment.tip, .event = .edit },
    }, .{}));
    const current = (try plain.find(a, made.id)).?;
    try testing.expectEqualStrings("Their description", current.description);
    const text = for (current.comments) |c| {
        if (c.oid.eql(comment.tip)) break c.subject;
    } else return error.CommentNotFound;
    try testing.expectEqualStrings("Their comment", text);
}

test "editBatch: all or nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 7, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const Catalog = @import("milestone.zig").Catalog(GitSim);
    const cat = Catalog.fromRepo(repo);
    const v1 = try cat.create(arena, .{ .name = "v1" }, .{});

    const ref = struct {
        fn f(a: Allocator, id: []const u8) []const u8 {
            return std.fmt.allocPrint(a, "refs/issues/{s}", .{id}) catch unreachable;
        }
    }.f;
    const a = try repo.create(arena, .{ .title = "A" }, .{});
    const b = try repo.create(arena, .{ .title = "B" }, .{});
    const c = try repo.create(arena, .{ .title = "C" }, .{});
    const ra = ref(arena, a.id);
    const rb = ref(arena, b.id);
    const rc = ref(arena, c.id);

    // Two issues into one milestone: one guard ref, moved once.
    const res = try repo.editBatch(arena, &.{
        .{
            .ref_name = ra,
            .spec = .{
                .milestone = .linked(v1.id),
                .due_date = .{ .set = fields_fmt.Date.parse("2026-12-01").? },
            },
        },
        .{
            .ref_name = rb,
            .spec = .{
                .milestone = .linked(v1.id),
                .start_date = .{ .set = fields_fmt.Date.parse("2026-11-10").? },
            },
        },
    }, .{});
    try testing.expectEqual(@as(usize, 2), res.len);
    const la = try repo.load(arena, .{ .name = ra, .tip = res[0].tip });
    try testing.expectEqualStrings(v1.id, la.milestone_id.?);
    try testing.expect(la.due_date.?.eql(fields_fmt.Date.parse("2026-12-01").?));

    // One stale expect: nothing written.
    const tip_c = (try sim.resolveRef(rc)).?;
    const tip_b = (try sim.resolveRef(rb)).?;
    _ = try repo.edit(arena, rc, .{ .title = "C, renamed elsewhere" }, .{});
    try testing.expectError(error.VersionMismatch, repo.editBatch(arena, &.{
        .{
            .ref_name = rb,
            .spec = .{
                .due_date = .{ .set = fields_fmt.Date.parse("2027-01-01").? },
                .expect = tip_b,
            },
        },
        .{
            .ref_name = rc,
            .spec = .{
                .due_date = .{ .set = fields_fmt.Date.parse("2027-01-01").? },
                .expect = tip_c,
            },
        },
    }, .{}));
    try testing.expect(tip_b.eql((try sim.resolveRef(rb)).?));

    // A loop only the batch as a whole makes.
    try testing.expectError(error.BlockerCycle, repo.editBatch(arena, &.{
        .{ .ref_name = ra, .spec = .{ .add_blocked_by = &.{b.id} } },
        .{ .ref_name = rb, .spec = .{ .add_blocked_by = &.{c.id} } },
        .{ .ref_name = rc, .spec = .{ .add_blocked_by = &.{a.id} } },
    }, .{}));
    try testing.expectEqual(
        @as(usize, 0),
        (try repo.load(arena, .{ .name = ra, .tip = (try sim.resolveRef(ra)).? })).blocked_by.len,
    );
    // Without the loop it goes through.
    _ = try repo.editBatch(arena, &.{
        .{ .ref_name = ra, .spec = .{ .add_blocked_by = &.{b.id} } },
        .{ .ref_name = rb, .spec = .{ .add_blocked_by = &.{c.id} } },
    }, .{});
    try testing.expectError(error.DuplicateEdit, repo.editBatch(arena, &.{
        .{ .ref_name = ra, .spec = .{ .title = "x" } },
        .{ .ref_name = ra, .spec = .{ .title = "y" } },
    }, .{}));
    // A guard refusal anywhere refuses all.
    _ = try cat.edit(arena, v1.id, .{ .status = .retired }, .{});
    try testing.expectError(error.MilestoneRetired, repo.editBatch(arena, &.{
        .{
            .ref_name = ra,
            .spec = .{ .due_date = .{ .set = fields_fmt.Date.parse("2027-02-02").? } },
        },
        .{ .ref_name = rc, .spec = .{ .milestone = .linked(v1.id) } },
    }, .{}));
    try testing.expect(
        (try repo.load(
            arena,
            .{ .name = ra, .tip = (try sim.resolveRef(ra)).? },
        )).due_date.?.year == 2026,
    );
}

fn issueRef(arena: Allocator, id: anytype) ![]const u8 {
    return std.fmt.allocPrint(arena, "refs/issues/{s}", .{id});
}

test "editBatch: parents, checked as the batch leaves them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 8, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    var repo = Repo(GitSim).init(&sim);
    repo.limits.max_depth = 2;
    var ids: [4][]const u8 = undefined;
    var refs: [4][]const u8 = undefined;
    for (&ids, &refs, 0..) |*id, *r, n| {
        const created = try repo.create(
            arena,
            .{ .title = try std.fmt.allocPrint(arena, "{d}", .{n}) },
            .{},
        );
        id.* = try arena.dupe(u8, created.id);
        r.* = try issueRef(arena, created.id);
    }
    // Each fine alone, a loop together.
    try testing.expectError(error.ParentCycle, repo.editBatch(arena, &.{
        .{ .ref_name = refs[0], .spec = .{ .parent = .{ .set = ids[1] } } },
        .{ .ref_name = refs[1], .spec = .{ .parent = .{ .set = ids[0] } } },
    }, .{}));
    try testing.expectError(error.ParentCycle, repo.editBatch(arena, &.{
        .{ .ref_name = refs[0], .spec = .{ .parent = .{ .set = ids[1] } } },
        .{ .ref_name = refs[1], .spec = .{ .parent = .{ .set = ids[2] } } },
        .{ .ref_name = refs[2], .spec = .{ .parent = .{ .set = ids[0] } } },
    }, .{}));
    // Depth three, from edits that each make depth one.
    try testing.expectError(error.TooDeep, repo.editBatch(arena, &.{
        .{ .ref_name = refs[1], .spec = .{ .parent = .{ .set = ids[0] } } },
        .{ .ref_name = refs[2], .spec = .{ .parent = .{ .set = ids[1] } } },
        .{ .ref_name = refs[3], .spec = .{ .parent = .{ .set = ids[2] } } },
    }, .{}));
    try testing.expect(
        (try repo.load(
            arena,
            .{ .name = refs[1], .tip = (try sim.resolveRef(refs[1])).? },
        )).parent == null,
    );
    // Depth two is allowed.
    const res = try repo.editBatch(arena, &.{
        .{ .ref_name = refs[1], .spec = .{ .parent = .{ .set = ids[0] } } },
        .{ .ref_name = refs[2], .spec = .{ .parent = .{ .set = ids[1] } } },
    }, .{});
    try testing.expectEqualStrings(
        ids[1],
        (try repo.load(arena, .{ .name = refs[2], .tip = res[1].tip })).parent.?,
    );
    try testing.expectError(
        error.TooDeep,
        repo.edit(arena, refs[3], .{ .parent = .{ .set = ids[2] } }, .{}),
    );
}

test "editBatch: retries when an issue moves under it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 9, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const a = try Repo(GitSim).init(&sim).create(arena, .{ .title = "A" }, .{});
    const b = try Repo(GitSim).init(&sim).create(arena, .{ .title = "B" }, .{});
    const ra = try issueRef(arena, a.id);
    const rb = try issueRef(arena, b.id);
    var racing: RacingSim = .{ .sim = &sim, .race = .{ .ref = ra, .message = "Meanwhile" } };
    const repo = Repo(RacingSim).init(&racing);
    // No expect: the comment that lands first is kept, the edits too.
    const res = try repo.editBatch(arena, &.{
        .{ .ref_name = ra, .spec = .{ .title = "A, renamed" } },
        .{ .ref_name = rb, .spec = .{ .add_blocked_by = &.{a.id} } },
    }, .{});
    const la = try repo.load(arena, .{ .name = ra, .tip = (try sim.resolveRef(ra)).? });
    try testing.expect(la.tip.eql(res[0].tip));
    try testing.expectEqualStrings("A, renamed", la.title);
    try testing.expectEqualStrings("Meanwhile", la.comments[0].subject);
    try testing.expect(res[1].tip.eql((try sim.resolveRef(rb)).?));
}

test "editBatch: WriteOptions: a dry run writes nothing, an author ID stamps every commit" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 61, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const a = try repo.create(arena, .{ .title = "A" }, .{});
    const b = try repo.create(arena, .{ .title = "B" }, .{});
    const edits = [_]Repo(GitSim).BatchEdit{
        .{ .ref_name = try issueRef(arena, a.id), .spec = .{ .title = "A2" } },
        .{ .ref_name = try issueRef(arena, b.id), .spec = .{ .title = "B2" } },
    };

    const dry = try repo.editBatch(arena, &edits, .{ .dry_run = true });
    try testing.expectEqual(@as(usize, 2), dry.len);
    try testing.expect(a.tip.eql((try sim.resolveRef(edits[0].ref_name)).?));
    try testing.expect(b.tip.eql((try sim.resolveRef(edits[1].ref_name)).?));
    try testing.expect(try sim.readObject(arena, dry[0].tip) == null);

    const ada = "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d";
    const done = try repo.editBatch(arena, &edits, .{ .author_id = ada });
    for (edits, done) |e, r| {
        const issue = try repo.load(arena, .{ .name = e.ref_name, .tip = r.tip });
        try testing.expectEqualStrings(ada, issue_model.authorIdAt(issue.author_ids, r.tip).?);
    }

    var d: errors_mod.Diagnostics = .{ .arena = arena };
    try testing.expectError(error.InvalidLabel, repo.editBatch(arena, &.{
        .{ .ref_name = edits[0].ref_name, .spec = .{ .add_labels = &.{"a,b"} } },
    }, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("Labels", d.last().?.key);
}

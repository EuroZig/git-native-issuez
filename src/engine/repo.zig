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

/// What a builder's `guard` returns.
pub const Guarded = struct {
    /// Refs it read.
    verify: []const contract.RefUpdate = &.{},
    /// Guard refs to move to the new commit.
    bump: []const Bump = &.{},

    pub const Bump = struct { name: []const u8, old: ?Oid };

    pub fn ops(
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

/// Reads the guard ref of `id`, to move it in the same transaction.
pub fn readGuardRef(backend: anytype, arena: Allocator, id: []const u8) !Guarded.Bump {
    const name = try std.fmt.allocPrint(arena, "{s}{s}", .{ guard_ref_prefix, id });
    return .{ .name = name, .old = try backend.resolveRef(name) };
}

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
    /// `email` or `<uuid> <email>`.
    assignee: ?[]const u8 = null,
    priority: ?core_fmt.Priority = null,
    milestone: ?[]const u8 = null,
    // References are full UUIDs. Callers resolve short IDs first.
    parent: ?[]const u8 = null,
    blocked_by: []const []const u8 = &.{},
    start_date: ?[]const u8 = null,
    due_date: ?[]const u8 = null,
    estimate_minutes: ?u32 = null,
    /// Callers check it against the configured workflow states.
    workflow: ?[]const u8 = null,
    /// A catalog milestone. Written with mode `explicit` and its name as
    /// `Milestone:`. Must be open.
    milestone_id: ?[]const u8 = null,
    /// `inherit` or `none`. `explicit` needs `milestone_id`.
    milestone_mode: ?fields_fmt.MilestoneMode = null,
    /// Overrides the backend's identity.
    author: ?Signature = null,
};

/// Every spec has `expect`: the tip the caller based the change on (an
/// ETag, say). If the issue has changed since, the write fails with
/// VersionMismatch instead of being applied on top.
pub const CommentSpec = struct {
    text: []const u8,
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

pub const EditSpec = struct {
    title: ?[]const u8 = null,
    /// Replaces the labels.
    set_labels: ?[]const []const u8 = null,
    add_labels: []const []const u8 = &.{},
    remove_labels: []const []const u8 = &.{},
    /// Empty clears it.
    assignee: ?[]const u8 = null,
    priority: ?PriorityEdit = null,
    milestone: ?[]const u8 = null,
    // null leaves a field alone, "" or `.clear` clears it.
    parent: ?[]const u8 = null,
    set_blocked_by: ?[]const []const u8 = null,
    add_blocked_by: []const []const u8 = &.{},
    remove_blocked_by: []const []const u8 = &.{},
    start_date: ?[]const u8 = null,
    due_date: ?[]const u8 = null,
    estimate_minutes: ?EstimateEdit = null,
    workflow: ?[]const u8 = null,
    milestone_id: ?[]const u8 = null,
    /// `inherit` and `none` clear the ID and the name. `explicit` needs an
    /// ID, given or already set.
    milestone_mode: ?fields_fmt.MilestoneMode = null,
    /// Replaces the description, in the same commit as the other changes:
    /// a `description-edit` event that also sets their fields.
    description: ?[]const u8 = null,
    /// The subject. With a description it can't have a body.
    message: ?[]const u8 = null,
    author: ?Signature = null,
    expect: ?Oid = null,

    pub const EstimateEdit = union(enum) { set: u32, clear };
    pub const PriorityEdit = union(enum) { set: core_fmt.Priority, clear };

    pub fn isEmpty(spec: EditSpec) bool {
        return spec.title == null and spec.set_labels == null and spec.add_labels.len == 0 and
            spec.remove_labels.len == 0 and spec.assignee == null and spec.priority == null and
            spec.milestone == null and spec.parent == null and spec.set_blocked_by == null and
            spec.add_blocked_by.len == 0 and spec.remove_blocked_by.len == 0 and
            spec.start_date == null and spec.due_date == null and
            spec.estimate_minutes == null and spec.workflow == null and
            spec.milestone_id == null and spec.milestone_mode == null and spec.description == null;
    }
};

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

    /// For default subjects like "Update title, due date".
    pub fn name(c: Change) []const u8 {
        return switch (c) {
            .start_date => "start date",
            .due_date => "due date",
            else => @tagName(c),
        };
    }
};

pub fn Repo(comptime B: type) type {
    contract.assertBackend(B);
    return struct {
        const Self = @This();

        backend: *B,
        limits: Limits = .{},
        /// Besides `closed`. See `core.State.isDone`.
        done_states: []const []const u8 = &core_fmt.default_done_states,

        pub const Error = B.Error || error{
            /// More commits than `Limits.max_commits_per_issue`.
            HistoryTooLong,
            /// A reachable object is missing or isn't a commit.
            CorruptIssue,
            /// Out of compare-and-swap retries.
            ConcurrentModification,
            /// The issue ref went away during a write.
            IssueDisappeared,
            IdentityUnknown,
            /// A newline in a field, or similar.
            InvalidText,
            /// The text's last paragraph would read as trailers.
            BodyLooksLikeTrailers,
            /// Over a `Limits` bound.
            TooLong,
            TooManyLabels,
            TooManyBlockers,
            NothingToEdit,
            /// A value the format or upstream doesn't allow, like an unknown
            /// priority or a reference that isn't a full UUID.
            InvalidValue,
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
            GuardScanTooLarge,
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
            /// Not `refs/issues/<valid ref component>`, or `refs/milestones/`
            /// for the catalog's writes.
            InvalidIssueRef,
            /// The tip is no longer the `expect`ed one.
            VersionMismatch,
            /// Use `loadPage`.
            TooManyIssues,
            InvalidLimits,
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
        } || issue_model.Error;

        pub fn init(backend: *B) Self {
            return .{ .backend = backend };
        }

        /// `closed` or one of `done_states`.
        pub fn isDone(self: Self, issue: Issue) bool {
            return issue.state.isDone(self.done_states);
        }

        /// Sorted by name, so by UUID.
        pub fn refs(self: Self, arena: Allocator) Error![]IssueRef {
            const entries = try self.backend.listRefs(arena, issue_ref_prefix);
            const out = try arena.alloc(IssueRef, entries.len);
            for (entries, out) |e, *r| r.* = .{ .name = e.name, .tip = e.oid };
            return out;
        }

        /// Like upstream's `refs/issues/<prefix>*`.
        pub fn resolve(self: Self, arena: Allocator, prefix: []const u8) Error!Resolution {
            const all = try self.refs(arena);
            var matches: std.ArrayList(IssueRef) = .empty;
            for (all) |r| if (std.mem.startsWith(u8, r.id(), prefix)) try matches.append(arena, r);
            return switch (matches.items.len) {
                0 => .none,
                1 => .{ .one = matches.items[0] },
                else => .{ .many = matches.items },
            };
        }

        pub fn load(self: Self, arena: Allocator, ref: IssueRef) Error!Issue {
            const commits = try self.loadCommits(arena, ref.tip);
            return issue_model.materialize(arena, ref.id(), ref.tip, commits);
        }

        pub fn loadAll(self: Self, arena: Allocator) Error![]Issue {
            try self.checkLimits();
            const all = try self.refs(arena);
            if (all.len > self.limits.max_issues) return error.TooManyIssues;
            const issues = try arena.alloc(Issue, all.len);
            for (all, issues) |r, *i| i.* = try self.load(arena, r);
            return issues;
        }

        /// For guards: issues that can't be loaded are skipped (fsck reports
        /// them), and at most `Limits.max_guard_scan` are read.
        pub fn loadForGuards(self: Self, arena: Allocator) Error![]Issue {
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

        pub const Page = struct {
            issues: []Issue,
            /// Null on the last page.
            next: ?[]const u8,
        };

        /// In ID order, after the issue ID `after`. `limit` defaults to
        /// and is capped by `Limits.page_size`.
        pub fn loadPage(
            self: Self,
            arena: Allocator,
            after: ?[]const u8,
            limit: ?u32,
        ) Error!Page {
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

        fn checkLimits(self: Self) Error!void {
            if (!self.limits.valid()) return error.InvalidLimits;
        }

        pub fn loadCommits(self: Self, arena: Allocator, tip: Oid) Error![]issue_model.CommitInput {
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
        };

        /// Upstream fsck's checks, with our trailer parsing.
        pub fn check(self: Self, arena: Allocator, ref: IssueRef) Allocator.Error![]const Problem {
            return self.checkWith(arena, ref, &.{ "State", "Format-Version" });
        }

        pub fn checkWith(
            self: Self,
            arena: Allocator,
            ref: IssueRef,
            root_keys: []const []const u8,
        ) Allocator.Error![]const Problem {
            var problems: std.ArrayList(Problem) = .empty;
            if (!uuid_fmt.isCanonical(ref.id())) try problems.append(arena, .invalid_uuid);
            const commits = self.loadCommits(arena, ref.tip) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try problems.append(arena, .{ .unreadable = e });
                    return problems.items;
                },
            };
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

        pub const Created = struct { id: uuid_fmt.Uuid, tip: Oid };

        pub fn create(self: Self, arena: Allocator, spec: CreateSpec) Error!Created {
            try self.checkLimits();
            try self.checkText(spec.title, self.limits.max_title_bytes);
            if (spec.body.len > self.limits.max_body_bytes) return error.TooLong;
            const normalized = try self.normalizeLabels(arena, spec.labels);
            var milestone_text = spec.milestone;
            if (spec.milestone_id) |mid| {
                const info = (try self.milestoneInfo(arena, mid)) orelse
                    return error.ReferenceNotFound;
                try checkSelectable(info.status);
                milestone_text = info.name;
            }
            if (spec.milestone_mode) |m| if ((m == .explicit) != (spec.milestone_id != null))
                return error.InvalidValue;

            var list: std.ArrayList(trailers.Trailer) = .empty;
            try list.append(arena, .{ .key = "State", .value = "open" });
            if (normalized.len > 0) try list.append(
                arena,
                .{ .key = "Labels", .value = try labels_fmt.join(arena, normalized) },
            );
            if (spec.assignee) |v| if (v.len > 0) try list.append(
                arena,
                .{ .key = "Assignee", .value = v },
            );
            if (spec.priority) |v| try list.append(arena, .{ .key = "Priority", .value = v.text() });
            if (milestone_text) |v| if (v.len > 0) try list.append(
                arena,
                .{ .key = "Milestone", .value = v },
            );
            if (spec.assignee) |v| if (v.len > 0) try checkAssignee(v);
            if (spec.parent) |v| {
                try checkReference(v);
                try list.append(arena, .{ .key = "X-Parent", .value = v });
            }
            if (spec.blocked_by.len > 0) try list.append(arena, .{
                .key = "X-Blocked-By",
                .value = try self.referenceSet(arena, spec.blocked_by, &.{}),
            });
            for ([_]struct { []const u8, ?[]const u8 }{
                .{ "X-Start-Date", spec.start_date },
                .{ "X-Due-Date", spec.due_date },
            }) |d| if (d[1]) |v| {
                if (fields_fmt.Date.parse(v) == null) return error.InvalidValue;
                try list.append(arena, .{ .key = d[0], .value = v });
            };
            if (spec.estimate_minutes) |m| {
                if (m > fields_fmt.max_estimate_minutes) return error.InvalidValue;
                try list.append(arena, .{
                    .key = "X-Estimate-Minutes",
                    .value = try std.fmt.allocPrint(arena, "{d}", .{m}),
                });
            }
            if (spec.workflow) |v| {
                if (!fields_fmt.isSlug(v)) return error.InvalidValue;
                try list.append(arena, .{ .key = "X-Workflow-State", .value = v });
            }
            if (spec.milestone_id) |mid| {
                try list.append(arena, .{ .key = "X-Milestone-Id", .value = mid });
                try list.append(arena, .{ .key = "X-Milestone-Mode", .value = explicit_mode });
            } else if (spec.milestone_mode) |m| {
                try list.append(arena, .{ .key = "X-Milestone-Mode", .value = @tagName(m) });
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
                    .closed = false,
                    .state_changed = false,
                    .was_closed = false,
                    .milestone_id = spec.milestone_id,
                    .milestone_mode = spec.milestone_mode,
                    .milestone_changed = true,
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
                self.backend.updateRefs(ops.items) catch |err| switch (err) {
                    error.RefConflict => continue,
                    else => |e| return e,
                };
                return .{ .id = id, .tip = oid };
            }
            return error.ConcurrentModification;
        }

        pub fn comment(
            self: Self,
            arena: Allocator,
            ref_name: []const u8,
            spec: CommentSpec,
        ) Error!Oid {
            try self.checkLimits();
            if (spec.text.len > self.limits.max_body_bytes) return error.TooLong;
            const split = splitMessage(spec.text);
            const message = try trailers.build(arena, split.subject, split.body, &.{});
            return self.appendCommit(arena, ref_name, spec.author, spec.expect, FixedMessage{
                .text = message,
            });
        }

        pub fn setState(
            self: Self,
            arena: Allocator,
            ref_name: []const u8,
            spec: StateSpec,
        ) Error!Oid {
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
            const split = splitMessage(spec.message orelse default_subject);
            const message = try trailers.build(arena, split.subject, split.body, list.items);
            return self.appendCommit(arena, ref_name, spec.author, spec.expect, StateBuilder{
                .repo = self,
                .text = message,
                .closed = state.isDone(self.done_states),
            });
        }

        const StateBuilder = struct {
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
                    .parent = current.ext.parent,
                    .parent_changed = false,
                    .blockers_added = &.{},
                    .closed = b.closed,
                    .state_changed = b.closed != was_closed,
                    .was_closed = was_closed,
                    .milestone_id = current.ext.milestone_id,
                    .milestone_mode = current.ext.milestone_mode,
                    .milestone_changed = false,
                });
            }
        };

        pub const LifecycleSpec = struct {
            /// Defaults to "Delete issue", "Edit description", ...
            message: ?[]const u8 = null,
            author: ?Signature = null,
            expect: ?Oid = null,
        };

        /// Refused while sub-issues aren't deleted.
        pub fn setDeleted(
            self: Self,
            arena: Allocator,
            ref_name: []const u8,
            deleted: bool,
            spec: LifecycleSpec,
        ) Error!Oid {
            try self.checkLimits();
            const subject = spec.message orelse if (deleted) "Delete issue" else "Restore issue";
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
                    .parent = current.ext.parent,
                    .parent_changed = false,
                    .blockers_added = &.{},
                    .closed = b.repo.isDone(current),
                    .state_changed = false,
                    .was_closed = b.repo.isDone(current),
                    .milestone_id = current.ext.milestone_id,
                    .milestone_mode = current.ext.milestone_mode,
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

        pub fn editDescription(
            self: Self,
            arena: Allocator,
            ref_name: []const u8,
            text: []const u8,
            spec: LifecycleSpec,
        ) Error!Oid {
            const result = try self.edit(arena, ref_name, .{
                .description = text,
                .message = spec.message,
                .author = spec.author,
                .expect = spec.expect,
            });
            return result.tip;
        }

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

        /// `comment` is the full ID of the comment's commit. An edit
        /// replaces the whole text.
        pub fn commentEvent(
            self: Self,
            arena: Allocator,
            ref_name: []const u8,
            comment_oid: Oid,
            event: CommentEvent,
            text: []const u8,
            spec: LifecycleSpec,
        ) Error!Oid {
            try self.checkLimits();
            if (text.len > self.limits.max_body_bytes) return error.TooLong;
            return self.appendCommit(arena, ref_name, spec.author, spec.expect, CommentEventBuilder{
                .comment = comment_oid,
                .event = event,
                .text = text,
                .subject = spec.message,
            });
        }

        const CommentEventBuilder = struct {
            comment: Oid,
            event: CommentEvent,
            text: []const u8,
            subject: ?[]const u8,

            pub fn message(
                b: CommentEventBuilder,
                arena: Allocator,
                current: Issue,
            ) Error![]const u8 {
                var found = false;
                for (current.comments) |c| if (c.oid.eql(b.comment) and !c.is_merge) {
                    found = true;
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
                const kind = b.event.event();
                return trailers.build(arena, subject, if (kind.carriesText()) b.text else "", &.{
                    .{ .key = "X-Event", .value = kind.text() },
                    .{ .key = "X-Comment", .value = try arena.dupe(u8, hex.slice()) },
                });
            }
        };

        pub const EditResult = struct { tip: Oid, changes: []const Change };

        pub fn edit(
            self: Self,
            arena: Allocator,
            ref_name: []const u8,
            spec: EditSpec,
        ) Error!EditResult {
            try self.checkLimits();
            if (spec.isEmpty()) return error.NothingToEdit;
            if (spec.title) |t| try self.checkText(t, self.limits.max_title_bytes);
            for ([_]?[]const u8{ spec.assignee, spec.milestone }) |v| {
                if (v) |value| try self.checkText(value, self.limits.max_trailer_value_bytes);
            }
            var changes: std.ArrayList(Change) = .empty;
            if (spec.title != null) try changes.append(arena, .title);
            if (spec.set_labels != null or spec.add_labels.len > 0 or spec.remove_labels.len > 0)
                try changes.append(arena, .labels);
            if (spec.assignee != null) try changes.append(arena, .assignee);
            if (spec.priority != null) try changes.append(arena, .priority);
            const milestone_changes = spec.milestone != null or spec.milestone_id != null or
                spec.milestone_mode != null;
            if (milestone_changes) try changes.append(arena, .milestone);
            // The guard checks that the milestone can be selected.
            if (spec.milestone_id != null) if (spec.milestone_mode) |m| if (m != .explicit)
                return error.InvalidValue;
            if (spec.assignee) |v| if (v.len > 0) try checkAssignee(v);
            if (spec.parent) |v| {
                if (v.len > 0) try checkReference(v);
                try changes.append(arena, .parent);
            }
            if (spec.set_blocked_by != null or spec.add_blocked_by.len > 0 or
                spec.remove_blocked_by.len > 0)
            {
                for (spec.set_blocked_by orelse &.{}) |r| try checkReference(r);
                for (spec.add_blocked_by) |r| try checkReference(r);
                try changes.append(arena, .blockers);
            }
            for ([_]struct { Change, ?[]const u8 }{
                .{ .start_date, spec.start_date },
                .{ .due_date, spec.due_date },
            }) |d| if (d[1]) |v| {
                if (v.len > 0 and fields_fmt.Date.parse(v) == null) return error.InvalidValue;
                try changes.append(arena, d[0]);
            };
            if (spec.estimate_minutes) |e| {
                const too_big = e == .set and e.set > fields_fmt.max_estimate_minutes;
                if (too_big) return error.InvalidValue;
                try changes.append(arena, .estimate);
            }
            if (spec.workflow) |v| {
                if (v.len > 0 and !fields_fmt.isSlug(v)) return error.InvalidValue;
                try changes.append(arena, .workflow);
            }
            if (spec.description) |d| {
                if (d.len > self.limits.max_body_bytes) return error.TooLong;
                try changes.append(arena, .description);
            }
            const builder: EditBuilder = .{ .repo = self, .spec = spec, .changes = changes.items };
            const tip = try self.appendCommit(arena, ref_name, spec.author, spec.expect, builder);
            return .{ .tip = tip, .changes = changes.items };
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
            ref_name: []const u8,
            author: ?Signature,
            expect: ?Oid,
            builder: anytype,
        ) Error!Oid {
            if (!std.mem.startsWith(u8, ref_name, prefix) or ref_name.len == prefix.len or
                !contract.isValidRefName(ref_name)) return error.InvalidIssueRef;
            var attempt: u8 = 0;
            while (attempt < self.limits.cas_retries) : (attempt += 1) {
                const tip = (try self.backend.resolveRef(ref_name)) orelse
                    return error.IssueDisappeared;
                if (expect) |want| if (!want.eql(tip)) return error.VersionMismatch;
                const current = try self.load(arena, .{ .name = ref_name, .tip = tip });
                const message = try builder.message(arena, current);
                const guarded: Guarded = if (@hasDecl(@TypeOf(builder), "guard"))
                    try builder.guard(arena, current)
                else
                    .{};
                const who = try self.identity(arena, author);
                const oid = try self.writeCommit(arena, &.{tip}, who, message);
                var ops: std.ArrayList(contract.RefUpdate) = .empty;
                try ops.append(arena, .{
                    .name = ref_name,
                    .op = .{ .update = .{ .new = oid, .old = tip } },
                });
                try ops.appendSlice(arena, try guarded.ops(arena, oid));
                // More refs in the same transaction, like the derived
                // attachment ref.
                if (@hasDecl(@TypeOf(builder), "after"))
                    try ops.appendSlice(arena, try builder.after(arena, current, oid));
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
                return oid;
            }
            return error.ConcurrentModification;
        }

        pub const MilestoneInfo = struct {
            name: []const u8,
            status: fields_fmt.MilestoneStatus,
            tip: Oid,
        };

        pub fn milestoneInfo(self: Self, arena: Allocator, id: []const u8) Error!?MilestoneInfo {
            if (!uuid_fmt.isCanonical(id)) return null;
            const name = try milestoneRefName(arena, id);
            const tip = (try self.backend.resolveRef(name)) orelse return null;
            const header = milestoneHeader(try self.load(arena, .{ .name = name, .tip = tip }));
            return .{ .name = header.name, .status = header.status, .tip = tip };
        }

        /// For builders from other modules, like the attachment store.
        pub fn appendWith(
            self: Self,
            arena: Allocator,
            ref_name: []const u8,
            author: ?Signature,
            expect: ?Oid,
            builder: anytype,
        ) Error!Oid {
            try self.checkLimits();
            return self.appendCommit(arena, ref_name, author, expect, builder);
        }

        /// For the milestone catalog: `appendWith` for `refs/milestones/`.
        pub fn appendMilestone(
            self: Self,
            arena: Allocator,
            ref_name: []const u8,
            author: ?Signature,
            expect: ?Oid,
            builder: anytype,
        ) Error!Oid {
            try self.checkLimits();
            return self.appendUnder(milestone_ref_prefix, arena, ref_name, author, expect, builder);
        }

        /// A builder with a message that doesn't depend on the tip.
        pub const FixedMessage = struct {
            text: []const u8,
            pub fn message(b: FixedMessage, arena: Allocator, current: Issue) Error![]const u8 {
                _ = arena;
                _ = current;
                return b.text;
            }
        };

        const EditBuilder = struct {
            repo: Self,
            spec: EditSpec,
            changes: []const Change,

            pub fn message(b: EditBuilder, arena: Allocator, current: Issue) Error![]const u8 {
                const spec = b.spec;
                var list: std.ArrayList(trailers.Trailer) = .empty;
                if (spec.title) |t| try list.append(arena, .{ .key = "Title", .value = t });
                const labels_changed = spec.set_labels != null or spec.add_labels.len > 0 or
                    spec.remove_labels.len > 0;
                if (labels_changed) {
                    // From the fresh state, on every attempt.
                    var next: std.ArrayList([]const u8) = .empty;
                    try next.appendSlice(arena, spec.set_labels orelse current.labels);
                    try next.appendSlice(arena, spec.add_labels);
                    // Trimmed, like upstream compares them.
                    const candidates = try b.repo.normalizeLabels(arena, next.items);
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
                    const normalized = kept.items;
                    try list.append(
                        arena,
                        .{ .key = "Labels", .value = try labels_fmt.join(arena, normalized) },
                    );
                }
                if (spec.assignee) |v| try list.append(arena, .{ .key = "Assignee", .value = v });
                if (spec.priority) |v| try list.append(arena, .{
                    .key = "Priority",
                    .value = switch (v) {
                        .set => |p| p.text(),
                        .clear => "",
                    },
                });
                // The catalog name for an ID, the given text, or empty when
                // the mode drops the milestone.
                const mode = spec.milestone_mode;
                const drops = spec.milestone_id == null and (mode == .inherit or mode == .none);
                if (spec.milestone_id) |mid| {
                    const info = (try b.repo.milestoneInfo(arena, mid)) orelse
                        return error.ReferenceNotFound;
                    try list.append(arena, .{ .key = "Milestone", .value = info.name });
                } else if (spec.milestone) |v| {
                    try list.append(arena, .{ .key = "Milestone", .value = v });
                } else if (drops) try list.append(arena, .{ .key = "Milestone", .value = "" });
                if (spec.parent) |v| try list.append(arena, .{ .key = "X-Parent", .value = v });
                if (spec.set_blocked_by != null or spec.add_blocked_by.len > 0 or
                    spec.remove_blocked_by.len > 0)
                {
                    // From the fresh state, like labels.
                    var next: std.ArrayList([]const u8) = .empty;
                    try next.appendSlice(arena, spec.set_blocked_by orelse current.ext.blocked_by);
                    try next.appendSlice(arena, spec.add_blocked_by);
                    try list.append(arena, .{
                        .key = "X-Blocked-By",
                        .value = try b.repo.referenceSet(arena, next.items, spec.remove_blocked_by),
                    });
                }
                for ([_]struct { []const u8, ?[]const u8 }{
                    .{ "X-Start-Date", spec.start_date },
                    .{ "X-Due-Date", spec.due_date },
                }) |d| if (d[1]) |v| try list.append(arena, .{ .key = d[0], .value = v });
                if (spec.estimate_minutes) |e| try list.append(arena, .{
                    .key = "X-Estimate-Minutes",
                    .value = switch (e) {
                        .set => |m| try std.fmt.allocPrint(arena, "{d}", .{m}),
                        .clear => "",
                    },
                });
                if (spec.workflow) |v| try list.append(
                    arena,
                    .{ .key = "X-Workflow-State", .value = v },
                );
                if (spec.milestone_id) |mid| {
                    try list.append(arena, .{ .key = "X-Milestone-Id", .value = mid });
                    try list.append(arena, .{ .key = "X-Milestone-Mode", .value = explicit_mode });
                } else if (mode) |m| {
                    if (m == .explicit and current.ext.milestone_id == null)
                        return error.InvalidValue;
                    if (m != .explicit)
                        try list.append(arena, .{ .key = "X-Milestone-Id", .value = "" });
                    try list.append(arena, .{ .key = "X-Milestone-Mode", .value = @tagName(m) });
                }
                if (spec.description) |d| {
                    try list.append(arena, .{
                        .key = "X-Event",
                        .value = fields_fmt.Event.description_edit.text(),
                    });
                    const only = b.changes.len == 1;
                    const subject = spec.message orelse if (only)
                        "Edit description"
                    else
                        try defaultEditSubject(arena, b.changes);
                    return trailers.build(arena, subject, d, list.items);
                }
                const subject = spec.message orelse try defaultEditSubject(arena, b.changes);
                const split = splitMessage(subject);
                return trailers.build(arena, split.subject, split.body, list.items);
            }

            pub fn guard(
                b: EditBuilder,
                arena: Allocator,
                current: Issue,
            ) Error!Guarded {
                const spec = b.spec;
                const parent: ?[]const u8 = if (spec.parent) |p|
                    (if (p.len == 0) null else p)
                else
                    current.ext.parent;
                var added: std.ArrayList([]const u8) = .empty;
                const parts = [_][]const []const u8{
                    spec.set_blocked_by orelse &.{},
                    spec.add_blocked_by,
                };
                for (parts) |part| {
                    for (part) |r| {
                        if (labels_fmt.contains(current.ext.blocked_by, r)) continue;
                        if (labels_fmt.contains(spec.remove_blocked_by, r)) continue;
                        try added.append(arena, r);
                    }
                }
                const mode_after: ?fields_fmt.MilestoneMode = if (spec.milestone_id != null)
                    .explicit
                else
                    spec.milestone_mode orelse current.ext.milestone_mode;
                const id_after: ?[]const u8 = if (spec.milestone_id) |mid|
                    mid
                else if (spec.milestone_mode) |m|
                    (if (m == .explicit) current.ext.milestone_id else null)
                else
                    current.ext.milestone_id;
                return b.repo.runGuards(arena, .{
                    .id = current.id,
                    .parent = parent,
                    .parent_changed = spec.parent != null and parent != null,
                    .blockers_added = added.items,
                    .closed = b.repo.isDone(current),
                    .state_changed = false,
                    .was_closed = b.repo.isDone(current),
                    .milestone_id = id_after,
                    .milestone_mode = mode_after,
                    .milestone_changed = spec.milestone_id != null or spec.milestone_mode != null,
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
        };

        /// Every issue a guard reads is loaded once and gets a verify line,
        /// so a concurrent change aborts the write. What it can't pin, a
        /// new child or new milestone work, goes through the guard refs.
        const Guard = struct {
            repo: Self,
            arena: Allocator,
            /// The issue being written never gets a verify line: the update
            /// itself checks its ref, and a ref can't appear twice.
            self_id: ?[]const u8,
            cache: std.StringHashMapUnmanaged(?Issue) = .empty,
            verify: std.ArrayList(contract.RefUpdate) = .empty,
            bump: std.ArrayList(Guarded.Bump) = .empty,
            scanned: u32 = 0,
            /// Parent ID to children, built on first use.
            children: ?std.StringHashMapUnmanaged(std.ArrayList(Issue)) = null,
            milestones: std.StringHashMapUnmanaged(?MilestoneInfo) = .empty,

            fn get(g: *Guard, id: []const u8) Error!?Issue {
                if (g.cache.get(id)) |hit| return hit;
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
                try g.bump.append(g.arena, try readGuardRef(g.repo.backend, g.arena, id));
            }

            fn result(g: *Guard) Guarded {
                return .{ .verify = g.verify.items, .bump = g.bump.items };
            }

            fn pin(g: *Guard, name: []const u8, id: []const u8, tip: Oid) Error!void {
                if (g.self_id) |s| if (std.mem.eql(u8, s, id)) return;
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
                switch (fields_fmt.MilestoneMode.of(p.milestone_mode, has_id, p.parent != null)) {
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
                        next = anc.ext.parent;
                        continue;
                    }
                    const ext = anc.ext;
                    switch (fields_fmt.MilestoneMode.of(
                        ext.milestone_mode,
                        ext.milestone_id != null,
                        ext.parent != null,
                    )) {
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
                            const has_id = c.ext.milestone_id != null;
                            if (Mode.of(c.ext.milestone_mode, has_id, true) != .inherit) continue;
                            if (!g.repo.isDone(c)) return true;
                        }
                        try stack.append(g.arena, c.id);
                    }
                }
                return false;
            }

            fn childrenOf(g: *Guard, id: []const u8) Error![]const Issue {
                if (g.children == null) {
                    var index: std.StringHashMapUnmanaged(std.ArrayList(Issue)) = .empty;
                    for (try g.repo.loadForGuards(g.arena)) |issue| {
                        const parent = issue.ext.parent orelse continue;
                        // Its own parent, from another tool: not a child.
                        if (std.mem.eql(u8, parent, issue.id)) continue;
                        const gop = try index.getOrPut(g.arena, parent);
                        if (!gop.found_existing) gop.value_ptr.* = .empty;
                        try gop.value_ptr.append(g.arena, issue);
                    }
                    g.children = index;
                }
                const list = g.children.?.get(id) orelse return &.{};
                return list.items;
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

        /// Returns verify lines for every issue it read.
        fn runGuards(self: Self, arena: Allocator, p: Proposal) Error!Guarded {
            var g: Guard = .{ .repo = self, .arena = arena, .self_id = p.id };
            const eql = std.mem.eql;

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
                    const up = cur.ext.parent orelse break;
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
                    next = anc.ext.parent;
                }
            };

            if (p.closed and p.state_changed) if (p.id) |id| {
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
                    for (x.ext.blocked_by) |y| {
                        if (eql(u8, y, id)) return error.BlockerCycle;
                        if (try g.get(y)) |next| try stack.append(arena, next);
                    }
                }
            }
            return g.result();
        }

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
            return self.backend.writeObject(.commit, try c.serializeAlloc(arena));
        }

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
        ) Error![]const u8 {
            var out: std.ArrayList([]const u8) = .empty;
            for (members) |r| {
                try checkReference(r);
                if (labels_fmt.contains(out.items, r) or labels_fmt.contains(remove, r)) continue;
                try out.append(arena, r);
            }
            if (out.items.len > self.limits.max_blockers) return error.TooManyBlockers;
            return labels_fmt.join(arena, out.items);
        }

        fn normalizeLabels(
            self: Self,
            arena: Allocator,
            raw: []const []const u8,
        ) Error![]const []const u8 {
            var out: std.ArrayList([]const u8) = .empty;
            for (raw) |l| {
                labels_fmt.validate(l) catch return error.InvalidText;
                const t = std.mem.trim(u8, l, " \t");
                if (t.len == 0 or labels_fmt.contains(out.items, t)) continue;
                try out.append(arena, t);
            }
            if (out.items.len > self.limits.max_labels) return error.TooManyLabels;
            return out.items;
        }

        fn checkText(self: Self, text: []const u8, max: u32) Error!void {
            _ = self;
            if (text.len > max) return error.TooLong;
            if (std.mem.findAny(u8, text, "\r\n") != null) return error.InvalidText;
        }
    };
}

fn refNameOf(arena: Allocator, id: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}", .{ issue_ref_prefix, id });
}

/// `refs/milestones/<id>`.
pub fn milestoneRefName(arena: Allocator, id: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}", .{ milestone_ref_prefix, id });
}

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

fn checkAssignee(v: []const u8) error{InvalidValue}!void {
    const a = fields_fmt.Assignee.parse(v) orelse return error.InvalidValue;
    if (core_fmt.checkEmail(a.email) != null) return error.InvalidValue;
}

fn defaultEditSubject(arena: Allocator, changes: []const Change) Allocator.Error![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (changes) |c| try names.append(arena, c.name());
    return std.fmt.allocPrint(arena, "Update {s}", .{try std.mem.join(arena, ", ", names.items)});
}

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
        .assignee = "bob@e.x",
        .priority = .high,
    });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});
    _ = try repo.comment(arena, ref_name, .{ .text = "Repro on Firefox\n\nDetail line" });
    _ = try repo.setState(
        arena,
        ref_name,
        .{ .state = .closed, .message = "Fixed in abc", .fixed_by = "abc123" },
    );
    const edited = try repo.edit(
        arena,
        ref_name,
        .{ .add_labels = &.{"regression"}, .remove_labels = &.{"auth"}, .assignee = "" },
    );
    try testing.expectEqual(@as(usize, 2), edited.changes.len);

    const res = try repo.resolve(arena, created.id.short());
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
    const parent = try repo.create(arena, .{ .title = "Epic" });
    const blocker = try repo.create(arena, .{ .title = "Blocker" });
    const other = try repo.create(arena, .{ .title = "Other" });

    const child = try repo.create(arena, .{
        .title = "Child",
        .assignee = "a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e ada@e.x",
        .parent = parent.id.slice(),
        .blocked_by = &.{ blocker.id.slice(), blocker.id.slice() },
        .start_date = "2026-11-01",
        .due_date = "2026-12-01",
        .estimate_minutes = 90,
        .workflow = "ready",
    });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{child.id.slice()});
    var issue = try repo.load(arena, .{ .name = ref_name, .tip = child.tip });
    try testing.expectEqualStrings(parent.id.slice(), issue.ext.parent.?);
    try testing.expectEqual(@as(usize, 1), issue.ext.blocked_by.len); // deduplicated
    try testing.expectEqual(@as(?u32, 90), issue.ext.estimate_minutes);
    try testing.expectEqualStrings("ready", issue.ext.workflow.?);
    try testing.expectEqual(@as(usize, 0), issue.ext.invalid.len);

    const edited = try repo.edit(arena, ref_name, .{
        .add_blocked_by = &.{other.id.slice()},
        .remove_blocked_by = &.{blocker.id.slice()},
        .due_date = "",
        .estimate_minutes = .clear,
        .parent = "",
    });
    issue = try repo.load(arena, .{ .name = ref_name, .tip = edited.tip });
    try testing.expectEqual(@as(usize, 1), issue.ext.blocked_by.len);
    try testing.expectEqualStrings(other.id.slice(), issue.ext.blocked_by[0]);
    try testing.expect(issue.ext.due_date == null and issue.ext.estimate_minutes == null);
    try testing.expect(issue.ext.parent == null);
    try testing.expectEqual(@as(u8, 11), issue.ext.start_date.?.month);
    const subject = (try sim.readObject(arena, edited.tip)).?.data;
    const want = "Update parent, blockers, due date, estimate";
    try testing.expect(std.mem.find(u8, subject, want) != null);

    for ([_]CreateSpec{
        .{ .title = "x", .parent = "a7f3b2c" }, // short IDs must be resolved first
        .{ .title = "x", .due_date = "2026-02-30" },
        .{ .title = "x", .workflow = "In Progress" },
        .{ .title = "x", .assignee = "a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e" ++ " " },
        .{ .title = "x", .blocked_by = &.{"nope"} },
    }) |bad| try testing.expectError(error.InvalidValue, repo.create(arena, bad));
}

test "caller mistakes are errors, not panics" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 3, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const created = try repo.create(arena, .{ .title = "Target" });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});

    try testing.expectError(error.NothingToEdit, repo.edit(arena, ref_name, .{}));
    for ([_][]const u8{ "refs/heads/main", "refs/issues/", "refs/issues/a..b", "x" }) |bad| {
        try testing.expectError(error.InvalidIssueRef, repo.comment(arena, bad, .{ .text = "hi" }));
        try testing.expectError(
            error.InvalidIssueRef,
            repo.setState(arena, bad, .{ .state = .closed }),
        );
        try testing.expectError(error.InvalidIssueRef, repo.edit(arena, bad, .{ .title = "t" }));
    }

    // Upstream's write rules hold for library callers too. Priorities
    // can't be wrong: they're an enum.
    for ([_]CreateSpec{
        .{ .title = "x", .assignee = "ada" },
        .{ .title = "x", .assignee = "ada@example." },
    }) |bad| try testing.expectError(error.InvalidValue, repo.create(arena, bad));
    try testing.expectError(error.InvalidValue, repo.edit(arena, ref_name, .{ .assignee = "ada" }));
    try testing.expectError(
        error.InvalidValue,
        repo.setState(arena, ref_name, .{ .state = .{ .other = "in progress" } }),
    );
    _ = try repo.edit(arena, ref_name, .{ .priority = .clear, .assignee = "" });
}

test "expect" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 5, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const created = try repo.create(arena, .{ .title = "Versioned" });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});

    // A client read the issue at `created.tip`, then someone else comments.
    const seen = created.tip;
    const other = try repo.comment(arena, ref_name, .{ .text = "Someone else" });

    try testing.expectError(
        error.VersionMismatch,
        repo.comment(arena, ref_name, .{ .text = "Mine", .expect = seen }),
    );
    try testing.expectError(
        error.VersionMismatch,
        repo.setState(arena, ref_name, .{ .state = .closed, .expect = seen }),
    );
    try testing.expectError(
        error.VersionMismatch,
        repo.edit(arena, ref_name, .{ .title = "Renamed", .expect = seen }),
    );
    // The refused calls wrote nothing.
    try testing.expect((try sim.resolveRef(ref_name)).?.eql(other));

    const next = try repo.comment(arena, ref_name, .{ .text = "Mine", .expect = other });
    const done = try repo.edit(arena, ref_name, .{ .title = "Renamed", .expect = next });
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
    });

    var seen: usize = 0;
    var after: ?[]const u8 = null;
    var pages: usize = 0;
    while (true) {
        const page = try repo.loadPage(arena, after, 2);
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
    try testing.expectError(error.InvalidLimits, repo.create(arena, .{ .title = "x" }));
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
    _ = try repo.create(arena, .{ .title = "one" });
    _ = try repo.create(arena, .{ .title = "two" });
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
    const created = try repo.create(arena, .{ .title = "t" });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});
    try testing.expectError(
        error.BodyLooksLikeTrailers,
        repo.comment(arena, ref_name, .{ .text = "I agree.\n\nX-Deleted: true" }),
    );
    // A single line is the subject, never a trailer.
    _ = try repo.comment(arena, ref_name, .{ .text = "State: closed" });
    try testing.expectEqualStrings(
        "open",
        (try repo.load(arena, (try repo.resolve(arena, created.id.short())).one)).state.text(),
    );
    try testing.expectError(error.InvalidText, repo.create(arena, .{ .title = "two\nlines" }));
}

/// Lets another writer move a ref right before our first update, to
/// exercise the CAS retry.
const RacingSim = struct {
    sim: *GitSim,
    race: ?struct {
        ref: []const u8,
        message: []const u8,
        close: bool = false,
        /// Creates an open child of this issue instead.
        child_of: ?[]const u8 = null,
    } = null,

    pub const Error = GitSim.Error;

    pub fn objectFormat(r: *const RacingSim) object.ObjectFormat {
        return r.sim.objectFormat();
    }
    pub fn readObject(r: *RacingSim, arena: Allocator, oid: Oid) Error!?contract.Object {
        return r.sim.readObject(arena, oid);
    }
    pub fn writeObject(r: *RacingSim, kind: object.ObjectKind, data: []const u8) Error!Oid {
        return r.sim.writeObject(kind, data);
    }
    pub fn resolveRef(r: *RacingSim, name: []const u8) Error!?Oid {
        return r.sim.resolveRef(name);
    }
    pub fn listRefs(r: *RacingSim, arena: Allocator, prefix: []const u8) Error![]contract.RefEntry {
        return r.sim.listRefs(arena, prefix);
    }
    pub fn updateRefs(
        r: *RacingSim,
        updates: []const contract.RefUpdate,
    ) (Error || error{RefConflict})!void {
        if (r.race) |race| {
            r.race = null;
            const other = Repo(GitSim).init(r.sim);
            const a = r.sim.arena;
            if (race.child_of) |parent| {
                _ = other.create(a, .{ .title = "Late child", .parent = parent }) catch unreachable;
            } else if (race.close) {
                _ = other.setState(a, race.ref, .{ .state = .closed }) catch unreachable;
            } else {
                _ = other.comment(a, race.ref, .{ .text = race.message }) catch unreachable;
            }
        }
        return r.sim.updateRefs(updates);
    }
    pub fn isAncestor(r: *RacingSim, a: Oid, b: Oid) Error!bool {
        return r.sim.isAncestor(a, b);
    }
    pub fn mergeBases(r: *RacingSim, arena: Allocator, a: Oid, b: Oid) Error![]Oid {
        return r.sim.mergeBases(arena, a, b);
    }
    pub fn configGet(r: *RacingSim, arena: Allocator, key: []const u8) Error!?[]const u8 {
        return r.sim.configGet(arena, key);
    }
    pub fn configGetAll(r: *RacingSim, arena: Allocator, key: []const u8) Error![]const []const u8 {
        return r.sim.configGetAll(arena, key);
    }
    pub fn configAdd(r: *RacingSim, key: []const u8, value: []const u8) Error!void {
        return r.sim.configAdd(key, value);
    }
    pub fn configUnsetValue(r: *RacingSim, key: []const u8, value: []const u8) Error!void {
        return r.sim.configUnsetValue(key, value);
    }
    pub fn remoteNames(r: *RacingSim, arena: Allocator) Error![]const []const u8 {
        return r.sim.remoteNames(arena);
    }
    pub fn fetch(
        r: *RacingSim,
        arena: Allocator,
        remote: []const u8,
        refspecs: []const []const u8,
    ) (Error || error{FetchFailed})!void {
        return r.sim.fetch(arena, remote, refspecs);
    }
    pub fn push(
        r: *RacingSim,
        arena: Allocator,
        remote: []const u8,
        refspecs: []const []const u8,
        atomic: bool,
    ) (Error || error{PushFailed})!contract.PushResult {
        return r.sim.push(arena, remote, refspecs, atomic);
    }
    pub fn identity(
        r: *RacingSim,
        arena: Allocator,
    ) (Error || error{IdentityUnknown})!contract.Identity {
        return r.sim.identity(arena);
    }
    pub fn randomBytes(r: *RacingSim, buf: []u8) void {
        r.sim.randomBytes(buf);
    }
};

test "guards" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 31, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const refOf = struct {
        fn f(a: Allocator, c: Repo(GitSim).Created) ![]const u8 {
            return std.fmt.allocPrint(a, "refs/issues/{s}", .{c.id.slice()});
        }
    }.f;

    const epic = try repo.create(arena, .{ .title = "Epic" });
    const task = try repo.create(arena, .{ .title = "Task", .parent = epic.id.slice() });
    const sub = try repo.create(arena, .{ .title = "Sub", .parent = task.id.slice() });

    try testing.expectError(error.ParentIsSelf, repo.edit(arena, try refOf(arena, epic), .{
        .parent = epic.id.slice(),
    }));
    try testing.expectError(error.ParentCycle, repo.edit(arena, try refOf(arena, epic), .{
        .parent = sub.id.slice(),
    }));
    try testing.expectError(error.ReferenceNotFound, repo.create(arena, .{
        .title = "x",
        .parent = "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
    }));
    // A chain of depth 8 is fine, a ninth level isn't.
    var chain = sub; // depth 2
    for (3..9) |_| chain = try repo.create(arena, .{ .title = "deep", .parent = chain.id.slice() });
    try testing.expectError(error.TooDeep, repo.create(arena, .{
        .title = "too deep",
        .parent = chain.id.slice(),
    }));
    // Moving a subtree counts its height.
    const side = try repo.create(arena, .{ .title = "Side" });
    try testing.expectError(error.TooDeep, repo.edit(arena, try refOf(arena, epic), .{
        .parent = side.id.slice(),
    }));

    const b1 = try repo.create(arena, .{ .title = "B1", .blocked_by = &.{side.id.slice()} });
    try testing.expectError(error.BlocksItself, repo.edit(arena, try refOf(arena, b1), .{
        .add_blocked_by = &.{b1.id.slice()},
    }));
    try testing.expectError(error.BlockerCycle, repo.edit(arena, try refOf(arena, side), .{
        .add_blocked_by = &.{b1.id.slice()},
    }));

    try testing.expectError(
        error.OpenDescendants,
        repo.setState(arena, try refOf(arena, task), .{ .state = .closed }),
    );
    const leaf = try repo.create(arena, .{ .title = "Leaf", .parent = side.id.slice() });
    // Any state but open is done: a `wontfix` leaf doesn't hold its parent
    // open, and counts as closing.
    _ = try repo.setState(arena, try refOf(arena, leaf), .{ .state = .{ .other = "wontfix" } });
    _ = try repo.setState(arena, try refOf(arena, leaf), .{ .state = .closed });
    _ = try repo.setState(arena, try refOf(arena, side), .{ .state = .closed });
    try testing.expectError(error.ClosedAncestor, repo.create(arena, .{
        .title = "Under closed",
        .parent = side.id.slice(),
    }));
    try testing.expectError(
        error.ClosedAncestor,
        repo.setState(arena, try refOf(arena, leaf), .{ .state = .open }),
    );
    try testing.expectError(error.ClosedAncestor, repo.edit(arena, try refOf(arena, b1), .{
        .parent = side.id.slice(),
    }));
    _ = try repo.setState(arena, try refOf(arena, side), .{ .state = .open });
    _ = try repo.setState(arena, try refOf(arena, leaf), .{ .state = .open });

    // Whatever the guards let through leaves no violation.
    const issues = try repo.loadAll(arena);
    const proj = try @import("projection.zig").build(arena, issues, .{});
    try testing.expectEqual(@as(usize, 0), proj.problems.len);
}

test "guards on foreign cycles" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 35, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const a = try repo.create(arena, .{ .title = "A" });
    const b = try repo.create(arena, .{ .title = "B", .parent = a.id.slice() });
    const a_ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{a.id.slice()});

    // Someone else closes A and makes it B's child: an A, B cycle.
    const who = try sim.identity(arena);
    const msg = try std.fmt.allocPrint(
        arena,
        "Edit\n\nState: closed\nX-Parent: {s}\n",
        .{b.id.slice()},
    );
    const foreign = try repo.writeCommit(arena, &.{a.tip}, who, msg);
    try sim.updateRefs(&.{.{
        .name = a_ref,
        .op = .{ .update = .{ .new = foreign, .old = a.tip } },
    }});

    // Reopening A walks up through B back to A. That must neither put A's
    // ref in the transaction twice nor fail because A was closed.
    _ = try repo.setState(arena, a_ref, .{ .state = .open });
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
    const parent = try repo.create(arena, .{ .title = "Parent", .body = "Old." });
    const child = try repo.create(arena, .{ .title = "Child", .parent = parent.id.slice() });
    const ref = try refNameOf(arena, parent.id.slice());
    const latest = struct {
        fn f(r: Repo(GitSim), a: Allocator, s: *GitSim, name: []const u8) !Issue {
            return r.load(a, .{ .name = name, .tip = (try s.resolveRef(name)).? });
        }
    }.f;

    const c = try repo.comment(arena, ref, .{ .text = "Tpyo here" });
    _ = try repo.commentEvent(arena, ref, c, .edit, "Typo fixed", .{});
    var issue = try latest(repo, arena, &sim, ref);
    try testing.expectEqualStrings("Typo fixed", issue.comments[0].subject);
    try testing.expect(issue.comments[0].edited);
    _ = try repo.commentEvent(arena, ref, c, .delete, "", .{});
    issue = try latest(repo, arena, &sim, ref);
    try testing.expect(issue.comments[0].deleted);
    _ = try repo.commentEvent(arena, ref, c, .restore, "", .{});
    try testing.expectError(
        error.CommentNotFound,
        repo.commentEvent(arena, ref, parent.tip, .delete, "", .{}), // the root
    );

    _ = try repo.editDescription(arena, ref, "New.\n\nTwo paragraphs.", .{});
    issue = try latest(repo, arena, &sim, ref);
    try testing.expectEqualStrings("New.\n\nTwo paragraphs.", issue.description);
    try testing.expectEqual(@as(usize, 1), issue.comments.len); // events aren't comments

    // A parent with an active child can't be deleted, bottom-up works.
    try testing.expectError(error.ActiveChildren, repo.setDeleted(arena, ref, true, .{}));
    _ = try repo.setDeleted(arena, try refNameOf(arena, child.id.slice()), true, .{});
    _ = try repo.setDeleted(arena, ref, true, .{});
    issue = try latest(repo, arena, &sim, ref);
    try testing.expect(issue.deleted);
    _ = try repo.setDeleted(arena, ref, false, .{});
    try testing.expect(!(try latest(repo, arena, &sim, ref)).deleted);
}

test "guards under concurrent change" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 33, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const parent = try Repo(GitSim).init(&sim).create(arena, .{ .title = "Parent" });
    const parent_ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{parent.id.slice()});

    // The parent gets closed between our guard read and our write. The
    // verify line fails and the retry sees it closed.
    var racing: RacingSim = .{
        .sim = &sim,
        .race = .{ .ref = parent_ref, .message = "", .close = true },
    };
    const repo = Repo(RacingSim).init(&racing);
    try testing.expectError(error.ClosedAncestor, repo.create(arena, .{
        .title = "Child",
        .parent = parent.id.slice(),
    }));
    try testing.expectEqual(@as(usize, 1), (try repo.refs(arena)).len);

    // A child appears between our scan of the children and our write. A
    // verify line can't pin that absence. The guard ref makes the write
    // conflict, and the retry sees the child.
    for ([_]bool{ false, true }) |delete| {
        const epic = try Repo(GitSim).init(&sim).create(arena, .{ .title = "Epic" });
        const epic_ref = try refNameOf(arena, epic.id.slice());
        racing.race = .{ .ref = epic_ref, .message = "", .child_of = epic.id.slice() };
        if (delete) {
            try testing.expectError(error.ActiveChildren, repo.setDeleted(arena, epic_ref, true, .{}));
        } else {
            try testing.expectError(error.OpenDescendants, repo.setState(arena, epic_ref, .{
                .state = .closed,
            }));
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
    const leaf = try repo.create(arena, .{ .title = "Leaf" });

    // A damaged issue elsewhere doesn't stop closing a healthy one.
    const blob = try sim.writeObject(.blob, "not a commit");
    try sim.updateRefs(&.{.{
        .name = "refs/issues/0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
        .op = .{ .create = blob },
    }});
    _ = try repo.setState(arena, try refNameOf(arena, leaf.id.slice()), .{ .state = .closed });

    // Its own parent, from another tool, isn't its own child.
    const selfish = try repo.create(arena, .{ .title = "Selfish" });
    const ref = try refNameOf(arena, selfish.id.slice());
    const who = try sim.identity(arena);
    const msg = try std.fmt.allocPrint(arena, "Edit\n\nX-Parent: {s}\n", .{selfish.id.slice()});
    const foreign = try repo.writeCommit(arena, &.{selfish.tip}, who, msg);
    try sim.updateRefs(&.{.{ .name = ref, .op = .{ .update = .{ .new = foreign, .old = selfish.tip } } }});
    _ = try repo.setDeleted(arena, ref, true, .{});
}

test "CAS conflict rebuilds the commit" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const created = try Repo(GitSim).init(&sim).create(arena, .{ .title = "t", .labels = &.{"a"} });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});

    var racing: RacingSim = .{
        .sim = &sim,
        .race = .{ .ref = ref_name, .message = "concurrent comment" },
    };
    const repo = Repo(RacingSim).init(&racing);
    _ = try repo.edit(arena, ref_name, .{ .add_labels = &.{"b"} });

    const issue = try repo.load(
        arena,
        .{ .name = ref_name, .tip = (try sim.resolveRef(ref_name)).? },
    );
    // Both the concurrent comment and our edit survive, in one chain.
    try testing.expectEqual(@as(usize, 2), issue.comments.len);
    try testing.expectEqualStrings("concurrent comment", issue.comments[0].subject);
    try testing.expectEqualStrings("Update labels", issue.comments[1].subject);
    try testing.expectEqual(@as(usize, 2), issue.labels.len);
}

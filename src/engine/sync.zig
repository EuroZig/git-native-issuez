//! Merge, push and sync with a git remote.
//!
//! Fetches land in `refs/remotes/<remote>/<ns>/` and get merged from there.
//! What we merged, what the remote has and what we refused is recorded in
//! `refs/issuez-sync/<remote>/<record>/<ns>/<uuid>` (`Record`). Those refs
//! are never pushed, and losing them only costs extra work.
//!
//! Merge commits are deterministic (parents sorted, fixed identity, dated
//! by the newest parent), so two clones merging the same pair write the
//! same commit.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const contract = @import("../backend/contract.zig");
const object = @import("../backend/object.zig");
const trailers = @import("../format/trailers.zig");
const labels_fmt = @import("../format/labels.zig");
const uuid_fmt = @import("../format/uuid.zig");
const issue_model = @import("../model/issue.zig");
const repo_mod = @import("repo.zig");
const attachments_mod = @import("attachments.zig");

const Oid = object.Oid;

pub const merge_identity_name = "git-issue";
pub const merge_identity_email = "git-issue@invalid";
pub const merge_subject = "Merge issue";

/// Restated by merge commits after the core fields, as written (invalid
/// values too), so upstream, which reads the newest trailer, shows the
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

/// Refs per atomic push.
pub const push_chunk = 128;
/// Push attempts, with a merge in between when the remote moved.
pub const push_rounds = 4;

pub const Reason = enum {
    /// The remote and local issue share no history.
    unrelated_history,
    /// The remote ref no longer contains the tip we merged before.
    rewound,
    /// Fails the integrity checks, see `fsck`.
    invalid_issue,

    pub fn describe(r: Reason) []const u8 {
        return switch (r) {
            .unrelated_history => "remote issue has unrelated history",
            .rewound => "remote history was rewritten since the last merge",
            .invalid_issue => "remote issue fails integrity checks",
        };
    }
};

pub const Outcome = union(enum) {
    created,
    fast_forwarded,
    merged: Oid, // a merge base, for display
    up_to_date,
    local_ahead,
    quarantined: Reason,
};

/// `attachments` is fetched and pushed but never merged: the derived refs
/// are rebuilt from the merged issues.
pub const Namespace = enum {
    issues,
    milestones,
    attachments,

    pub fn refPrefix(ns: Namespace) []const u8 {
        return switch (ns) {
            .issues => "refs/issues/",
            .milestones => "refs/milestones/",
            .attachments => "refs/attachments/",
        };
    }
};

/// Sync's bookkeeping: `refs/issuez-sync/<remote>/<record>/<ns>/...`.
pub const Record = enum {
    /// The remote tip merged last.
    merged,
    /// The tip the remote is known to have.
    pushed,
    /// A remote tip that was refused, kept for inspection.
    quarantined,
    /// A quarantine resolved with `keep_local`, for that remote tip.
    kept,
    /// Where push fetches the remote's refs, deleted right after.
    seen,
    /// Local tips that `accept_remote` replaced, one ref per tip.
    replaced,
};

pub const namespaces = [_]Namespace{ .issues, .milestones };
pub const fetched_namespaces = [_]Namespace{ .issues, .milestones, .attachments };

/// `before_push` gets the LFS objects that the pushed attachment refs
/// point at and the remote doesn't have yet, before any ref is pushed, so
/// an embedder can upload them through its own LFS client. If it fails,
/// nothing is pushed. Without it, sync uses `git lfs push`, and fails with
/// LfsUnavailable, again before pushing anything, when there are objects
/// to upload and no git-lfs.
pub const PushOptions = struct {
    before_push: ?BeforePush = null,
};

pub const BeforePush = struct {
    context: *anyopaque,
    run: *const fn (
        context: *anyopaque,
        remote: []const u8,
        objects: []const attachments_mod.Upload,
    ) anyerror!void,
};

pub const Entry = struct {
    namespace: Namespace = .issues,
    id: []const u8,
    title: []const u8,
    outcome: Outcome,
    /// Fields still in conflict after this merge. Empty for `check` runs
    /// and quarantined issues.
    conflicts: []const issue_model.Conflict = &.{},
    /// `resolve(.keep_local)` already acknowledged this remote version.
    kept_local: bool = false,
};

pub const Quarantined = struct {
    namespace: Namespace = .issues,
    id: []const u8,
    /// Local title, or the remote one if the issue only exists there.
    title: []const u8,
    /// The refused remote version.
    remote_tip: Oid,
    /// Null when it no longer applies. The next merge clears it.
    reason: ?Reason,
    kept_local: bool,
};

pub const Status = struct {
    quarantined: []const Quarantined,
    /// Not pushed yet, quarantined ones excluded.
    pending: []const repo_mod.IssueRef,
};

pub const Resolution = enum {
    /// The local tip is kept in
    /// `refs/issuez-sync/<remote>/replaced/<ns>/<id>/<tip>`, one ref per
    /// replaced tip.
    accept_remote,
    /// A rewound remote becomes the new baseline, so the next merge works
    /// normally. Unrelated or invalid remote history stays quarantined
    /// (pushing would take a force push), but stops being reported.
    keep_local,
};

pub const MergeOptions = struct {
    fetch: bool = true,
    /// Report only, change nothing.
    check: bool = false,
};

pub const MergeReport = struct {
    entries: []const Entry,
    attachment_refs: usize = 0,

    pub fn count(r: MergeReport, tag: std.meta.Tag(Outcome)) usize {
        var n: usize = 0;
        for (r.entries) |e| if (e.outcome == tag) {
            n += 1;
        };
        return n;
    }
};

pub const PushReport = struct {
    /// Objects the remote's derived refs didn't list yet, handed to
    /// `git lfs push` or `before_push`.
    lfs_uploaded: usize = 0,
    /// Not counted in `pushed`.
    attachment_refs: usize = 0,
    pushed: usize,
    up_to_date: usize,
    skipped_quarantined: usize,
    /// Quarantined issues that weren't pushed.
    skipped: []const []const u8 = &.{},
    /// Merges done because the remote moved.
    merges: []const MergeReport,
};

pub const SyncReport = struct {
    merge: MergeReport,
    push: PushReport,

    /// Across the merge and any merges the push needed.
    pub fn conflicted(r: SyncReport, arena: Allocator) Allocator.Error![]const Entry {
        var out: std.ArrayList(Entry) = .empty;
        for (r.merge.entries) |e| if (e.conflicts.len > 0) try out.append(arena, e);
        for (r.push.merges) |m| for (m.entries) |e| if (e.conflicts.len > 0) {
            try out.append(arena, e);
        };
        return out.items;
    }
};

pub fn Sync(comptime B: type) type {
    const R = repo_mod.Repo(B);
    return struct {
        const Self = @This();

        repo: R,

        pub const Error = R.Error || error{
            FetchFailed,
            PushFailed,
            InvalidRemoteName,
            UnknownRemote,
            /// The remote kept moving on every push round.
            PushRoundsExhausted,
            NotQuarantined,
            /// `accept_remote` on a remote issue that fails the integrity
            /// checks, so there's nothing valid to accept.
            RemoteIssueInvalid,
            /// Nothing was pushed.
            BeforePushFailed,
            /// git-lfs is there but the upload failed, so nothing was
            /// pushed. The backend's last error output says why.
            LfsUploadFailed,
        };

        pub fn init(backend: *B) Self {
            return .{ .repo = R.init(backend) };
        }

        fn b(self: Self) *B {
            return self.repo.backend;
        }

        pub fn merge(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            options: MergeOptions,
        ) Error!MergeReport {
            if (!contract.isValidRemoteName(remote)) return error.InvalidRemoteName;
            if (options.fetch) {
                try self.ensureRemote(arena, remote);
                var specs: [fetched_namespaces.len][]const u8 = undefined;
                for (fetched_namespaces, &specs) |ns, *spec| spec.* = try std.fmt.allocPrint(
                    arena,
                    "+{s}*:{s}*",
                    .{ ns.refPrefix(), try stagingPrefix(arena, remote, ns) },
                );
                try self.b().fetch(arena, remote, &specs);
            }
            var entries: std.ArrayList(Entry) = .empty;
            for (namespaces) |ns| {
                const staging_prefix = try stagingPrefix(arena, remote, ns);
                const staged = try self.b().listRefs(arena, staging_prefix);
                for (staged) |s| {
                    const id = s.name[staging_prefix.len..];
                    // Remote-tracking branches named `issues/...` land here
                    // too. They aren't issues: leave them alone.
                    if (!uuid_fmt.isCanonical(id)) continue;
                    var e = try self.mergeOne(arena, remote, ns, id, s, options);
                    e.namespace = ns;
                    try entries.append(arena, e);
                }
            }
            if (options.check) return .{ .entries = entries.items };
            return .{
                .entries = entries.items,
                .attachment_refs = try self.reconcileAttachments(arena, remote, options),
            };
        }

        fn reconcileAttachments(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            options: MergeOptions,
        ) Error!usize {
            const A = attachments_mod.Attachments(B);
            const att = A.fromRepo(self.repo);
            const staging_prefix = try stagingPrefix(arena, remote, .attachments);
            const staged = try self.b().listRefs(arena, staging_prefix);
            const remote_tips = try self.refsUnder(arena, staging_prefix);
            const local_tips = try self.refsUnder(arena, attachments_mod.ref_prefix);
            var moved: usize = 0;
            for (try self.repo.refs(arena)) |r| {
                const id = r.id();
                const remote_tip = remote_tips.get(id);
                const issue = self.repo.load(arena, r) catch continue;
                // Issues that never had attachments cost no git process.
                if (remote_tip == null and !local_tips.contains(id) and
                    issue.attachments.len == 0 and issue.removed_attachments.len == 0) continue;
                if (try att.reconcile(arena, issue, remote_tip)) moved += 1;
                if (remote_tip == null) continue;
                const local = try self.b().resolveRef(try A.derivedRefName(arena, id));
                const same = remote_tip != null and local != null and local.?.eql(remote_tip.?);
                if (same) try self.setRef(
                    arena,
                    try recordRef(arena, remote, .pushed, .attachments, id),
                    remote_tip.?,
                );
            }
            if (options.fetch) for (staged) |s| {
                if (uuid_fmt.isCanonical(s.name[staging_prefix.len..]))
                    try self.deleteRef(arena, s.name);
            };
            return moved;
        }

        fn mergeOne(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            ns: Namespace,
            id: []const u8,
            staged: contract.RefEntry,
            options: MergeOptions,
        ) Error!Entry {
            const remote_tip = staged.oid;
            const local_name = try localRef(arena, ns, id);
            const q = Q{ .sync = self, .arena = arena, .remote = remote, .ns = ns, .id = id };
            assert(uuid_fmt.isCanonical(id));

            const local_before = try self.b().resolveRef(local_name);
            const loaded = switch (try self.vet(arena, remote, ns, id, local_before, remote_tip)) {
                .ok => |issue| issue,
                .refused => |r| return q.quarantine(r.title, remote_tip, r.reason, options),
            };
            const title = titleIn(ns, loaded);

            var attempt: u8 = 0;
            while (attempt < self.repo.limits.cas_retries) : (attempt += 1) {
                // The first attempt reuses the read above: if a local writer
                // moved the ref since, the update below conflicts.
                const local_tip = if (attempt == 0)
                    local_before
                else
                    try self.b().resolveRef(local_name);
                var new_tip: ?Oid = null;
                const outcome: Outcome = switch (try self.relate(arena, local_tip, remote_tip)) {
                    .unrelated => return q.quarantine(
                        title,
                        remote_tip,
                        .unrelated_history,
                        options,
                    ),
                    .absent => blk: {
                        new_tip = remote_tip;
                        break :blk .created;
                    },
                    .same => .up_to_date,
                    .behind => blk: {
                        new_tip = remote_tip;
                        break :blk .fast_forwarded;
                    },
                    .ahead => .local_ahead,
                    .diverged => |base| blk: {
                        if (!options.check) new_tip = try self.mergeCommitIn(
                            arena,
                            ns,
                            id,
                            local_tip.?,
                            remote_tip,
                        );
                        break :blk .{ .merged = base };
                    },
                };
                if (options.check) return .{ .id = id, .title = title, .outcome = outcome };

                if (new_tip) |t| {
                    const op: contract.RefUpdate.Op = if (local_tip) |old|
                        .{ .update = .{ .new = t, .old = old } }
                    else
                        .{ .create = t };
                    self.b().updateRefs(&.{.{
                        .name = local_name,
                        .op = op,
                    }}) catch |err| switch (err) {
                        error.RefConflict => continue, // a local writer moved it: redo
                        else => |e| return e,
                    };
                }
                try self.setRef(arena, try recordRef(arena, remote, .merged, ns, id), remote_tip);
                const final_tip = new_tip orelse local_tip.?;
                // The fetched tip is what the remote has, even when it went
                // back to one we pushed earlier: push compares against this.
                try self.setRef(arena, try recordRef(arena, remote, .pushed, ns, id), remote_tip);
                try self.deleteRef(arena, try recordRef(arena, remote, .quarantined, ns, id));
                const final_issue = try self.repo.load(
                    arena,
                    .{ .name = local_name, .tip = final_tip },
                );
                // Like upstream, only clean up what this merge fetched. With
                // `--no-fetch` the staging refs came from the user's own fetch.
                if (options.fetch) try self.deleteRef(arena, staged.name);
                return .{
                    .id = id,
                    .title = title,
                    .outcome = outcome,
                    .conflicts = final_issue.conflicts,
                };
            }
            return error.ConcurrentModification;
        }

        const Q = struct {
            sync: Self,
            arena: Allocator,
            remote: []const u8,
            ns: Namespace,
            id: []const u8,

            fn quarantine(
                q: Q,
                title: []const u8,
                remote_tip: Oid,
                reason: Reason,
                options: MergeOptions,
            ) Error!Entry {
                const a = q.arena;
                if (!options.check) {
                    // Keep the staging ref for inspection, and the marker
                    // keeps push away from it.
                    const marker = try recordRef(a, q.remote, .quarantined, q.ns, q.id);
                    try q.sync.setRef(a, marker, remote_tip);
                }
                const kept = try q.sync.b().resolveRef(
                    try recordRef(a, q.remote, .kept, q.ns, q.id),
                );
                return .{
                    .namespace = q.ns,
                    .id = q.id,
                    .title = title,
                    .outcome = .{ .quarantined = reason },
                    .kept_local = kept != null and kept.?.eql(remote_tip),
                };
            }
        };

        /// Null when the remote issue's history is broken. Other errors,
        /// like a failing git, are passed on rather than quarantined.
        fn loadRemote(
            self: Self,
            arena: Allocator,
            ref: repo_mod.IssueRef,
        ) Error!?issue_model.Issue {
            return self.repo.load(arena, ref) catch |e| switch (e) {
                error.CorruptIssue, error.HistoryTooLong => null,
                else => |x| x,
            };
        }

        /// The remote no longer contains the tip merged last time. A remote
        /// reset to a tip the local issue already contains isn't rewound:
        /// nothing is lost, and the next push restores the local tip.
        fn isRewound(self: Self, merged_before: Oid, remote_tip: Oid, local: ?Oid) Error!bool {
            if (merged_before.eql(remote_tip)) return false;
            if (try self.b().isAncestor(merged_before, remote_tip)) return false;
            const l = local orelse return true;
            if (l.eql(remote_tip)) return false;
            return !try self.b().isAncestor(remote_tip, l);
        }

        fn mergeCommitIn(
            self: Self,
            arena: Allocator,
            ns: Namespace,
            id: []const u8,
            local: Oid,
            remote: Oid,
        ) Error!Oid {
            if (ns == .issues) return self.mergeCommit(arena, id, local, remote);
            // Only we read milestones, and every field follows from the
            // parents, so nothing is restated.
            var time: i64 = std.math.minInt(i64);
            for ([_]Oid{ local, remote }) |p| {
                const o = (try self.b().readObject(arena, p)) orelse return error.CorruptIssue;
                const c = object.Commit.parse(arena, self.b().objectFormat(), o.data) catch
                    return error.CorruptIssue;
                time = @max(time, c.committer.time);
            }
            const parents = try arena.dupe(Oid, &.{ local, remote });
            if (parents[1].order(parents[0]) == .lt) std.mem.swap(Oid, &parents[0], &parents[1]);
            const sig: object.Signature = .{
                .name = merge_identity_name,
                .email = merge_identity_email,
                .time = time,
                .tz_offset_minutes = 0,
            };
            return self.repo.writeCommit(
                arena,
                parents,
                .{ .author = sig, .committer = sig },
                "Merge milestone\n",
            );
        }

        fn mergeCommit(
            self: Self,
            arena: Allocator,
            id: []const u8,
            local: Oid,
            remote: Oid,
        ) Error!Oid {
            const format = self.b().objectFormat();
            const local_commits = try self.repo.loadCommits(arena, local);
            const remote_commits = try self.repo.loadCommits(arena, remote);
            var all: std.ArrayList(issue_model.CommitInput) = .empty;
            var seen: std.AutoHashMapUnmanaged([Oid.max_byte_len]u8, void) = .empty;
            var time: i64 = std.math.minInt(i64);
            for ([_][]const issue_model.CommitInput{ local_commits, remote_commits }) |list| {
                for (list) |c| {
                    if ((try seen.getOrPut(arena, c.oid.bytes)).found_existing) continue;
                    try all.append(arena, c);
                    if (c.oid.eql(local) or c.oid.eql(remote)) time = @max(time, c.committer.time);
                }
            }
            assert(time != std.math.minInt(i64));
            const parents = try arena.dupe(Oid, &.{ local, remote });
            if (parents[1].order(parents[0]) == .lt) std.mem.swap(Oid, &parents[0], &parents[1]);
            const sig: object.Signature = .{
                .name = merge_identity_name,
                .email = merge_identity_email,
                .time = time,
                .tz_offset_minutes = 0,
            };

            // Resolve through a synthetic merge node, then restate.
            var synthetic: Oid = .{ .object_format = format, .bytes = @splat(0xff) };
            synthetic.bytes[0] = 0xfe;
            try all.append(arena, .{
                .oid = synthetic,
                .parents = parents,
                .author = sig,
                .committer = sig,
                .message = merge_subject ++ "\n",
            });
            const resolved = try issue_model.materialize(arena, id, synthetic, all.items);

            // Cleared fields are restated empty, so a reader that takes
            // the newest value doesn't find an older one.
            var list: std.ArrayList(trailers.Trailer) = .empty;
            const cleared = struct {
                fn f(issue: issue_model.Issue, key: []const u8) ?[]const u8 {
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
            for ([_][]const u8{ "Assignee", "Priority", "Milestone" } ++ restated_extensions) |key| {
                const value = resolved.field(key) orelse cleared(resolved, key) orelse continue;
                try list.append(arena, .{ .key = key, .value = value });
            }
            if (resolved.ext.blocked_by_written.len > 0) try list.append(arena, .{
                .key = "X-Blocked-By",
                .value = try labels_fmt.join(arena, resolved.ext.blocked_by_written),
            }) else if (cleared(resolved, "X-Blocked-By")) |v| try list.append(
                arena,
                .{ .key = "X-Blocked-By", .value = v },
            );
            const message = try trailers.build(arena, merge_subject, "", list.items);
            return self.repo.writeCommit(
                arena,
                parents,
                .{ .author = sig, .committer = sig },
                message,
            );
        }

        pub fn mergeCommitForTest(
            self: Self,
            arena: Allocator,
            id: []const u8,
            a: Oid,
            c: Oid,
        ) Error!Oid {
            return self.mergeCommit(arena, id, a, c);
        }

        /// From local state only, no fetch.
        pub fn status(self: Self, arena: Allocator, remote: []const u8) Error!Status {
            if (!contract.isValidRemoteName(remote)) return error.InvalidRemoteName;
            var quarantined: std.ArrayList(Quarantined) = .empty;
            for (namespaces) |ns| {
                const prefix = try recordRef(arena, remote, .quarantined, ns, "");
                for (try self.b().listRefs(arena, prefix)) |m| {
                    const id = m.name[prefix.len..];
                    const local = try self.b().resolveRef(try localRef(arena, ns, id));
                    const kept_ref = try recordRef(arena, remote, .kept, ns, id);
                    const kept = try self.b().resolveRef(kept_ref);
                    try quarantined.append(arena, .{
                        .namespace = ns,
                        .id = id,
                        .title = try self.titleOf(arena, ns, id, local orelse m.oid),
                        .remote_tip = m.oid,
                        .reason = try self.classify(arena, remote, ns, id, local, m.oid),
                        .kept_local = kept != null and kept.?.eql(m.oid),
                    });
                }
            }
            var skipped: std.ArrayList([]const u8) = .empty;
            return .{
                .quarantined = quarantined.items,
                .pending = try self.pendingRefs(arena, remote, &skipped),
            };
        }

        fn titleOf(
            self: Self,
            arena: Allocator,
            ns: Namespace,
            id: []const u8,
            tip: Oid,
        ) Error![]const u8 {
            const ref: repo_mod.IssueRef = .{ .name = try localRef(arena, ns, id), .tip = tip };
            const loaded = self.repo.load(arena, ref) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return "?",
            };
            return titleIn(ns, loaded);
        }

        /// Why `merge` would quarantine this remote issue, null when it
        /// would merge. The same `vet` and `relate` as `mergeOne`.
        fn classify(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            ns: Namespace,
            id: []const u8,
            local: ?Oid,
            remote_tip: Oid,
        ) Error!?Reason {
            if (!uuid_fmt.isCanonical(id)) return .invalid_issue;
            switch (try self.vet(arena, remote, ns, id, local, remote_tip)) {
                .ok => {},
                .refused => |r| return r.reason,
            }
            return if (try self.relate(arena, local, remote_tip) == .unrelated)
                .unrelated_history
            else
                null;
        }

        const Vetted = union(enum) {
            ok: issue_model.Issue,
            refused: struct { reason: Reason, title: []const u8 },
        };

        /// The checks before any merge: the remote history loads and passes
        /// `fsck`, and the remote didn't lose the tip merged last.
        fn vet(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            ns: Namespace,
            id: []const u8,
            local: ?Oid,
            remote_tip: Oid,
        ) Error!Vetted {
            const as_issue: repo_mod.IssueRef = .{
                .name = try localRef(arena, ns, id),
                .tip = remote_tip,
            };
            const invalid: Vetted = .{ .refused = .{ .reason = .invalid_issue, .title = "?" } };
            const loaded = (try self.loadRemote(arena, as_issue)) orelse return invalid;
            if ((try self.repo.checkWith(arena, as_issue, rootKeys(ns))).len > 0) return invalid;
            const merged_ref = try recordRef(arena, remote, .merged, ns, id);
            if (try self.b().resolveRef(merged_ref)) |before| {
                if (try self.isRewound(before, remote_tip, local)) {
                    return .{ .refused = .{ .reason = .rewound, .title = titleIn(ns, loaded) } };
                }
            }
            return .{ .ok = loaded };
        }

        const Relation = union(enum) {
            /// No local ref yet.
            absent,
            same,
            /// The local tip is an ancestor of the remote one.
            behind,
            ahead,
            /// Both moved on from this merge base.
            diverged: Oid,
            /// No common history.
            unrelated,
        };

        /// How the local tip relates to the remote one.
        fn relate(self: Self, arena: Allocator, local: ?Oid, remote_tip: Oid) Error!Relation {
            const l = local orelse return .absent;
            if (l.eql(remote_tip)) return .same;
            if (try self.b().isAncestor(l, remote_tip)) return .behind;
            if (try self.b().isAncestor(remote_tip, l)) return .ahead;
            const bases = try self.b().mergeBases(arena, l, remote_tip);
            return if (bases.len == 0) .unrelated else .{ .diverged = bases[0] };
        }

        /// Never force-pushes, and never drops a local version without
        /// keeping it in a ref. Returns the local tip that `accept_remote`
        /// replaced, kept under `replacedRef`.
        pub fn resolve(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            id: []const u8,
            how: Resolution,
        ) Error!?Oid {
            if (!contract.isValidRemoteName(remote)) return error.InvalidRemoteName;
            if (!uuid_fmt.isCanonical(id)) return error.NotQuarantined;
            // An issue or a milestone: UUIDs don't repeat across them.
            var found: ?struct { Namespace, []const u8, Oid } = null;
            for (namespaces) |n| {
                const marker = try recordRef(arena, remote, .quarantined, n, id);
                if (try self.b().resolveRef(marker)) |tip| {
                    found = .{ n, marker, tip };
                    break;
                }
            }
            const ns, const marker_name, const remote_tip = found orelse
                return error.NotQuarantined;
            const local_name = try localRef(arena, ns, id);
            const local = try self.b().resolveRef(local_name);
            const reason = try self.classify(arena, remote, ns, id, local, remote_tip);
            const kept_name = try recordRef(arena, remote, .kept, ns, id);

            switch (how) {
                .accept_remote => {
                    if (reason == .invalid_issue) return error.RemoteIssueInvalid;
                    var ops: std.ArrayList(contract.RefUpdate) = .empty;
                    if (local) |l| {
                        const backup = try replacedRef(arena, remote, ns, id, l);
                        if (try self.b().resolveRef(backup) == null) try ops.append(arena, .{
                            .name = backup,
                            .op = .{ .create = l },
                        });
                        try ops.append(arena, .{
                            .name = local_name,
                            .op = .{ .update = .{ .new = remote_tip, .old = l } },
                        });
                    } else try ops.append(arena, .{
                        .name = local_name,
                        .op = .{ .create = remote_tip },
                    });
                    try ops.append(arena, .{
                        .name = marker_name,
                        .op = .{ .delete = remote_tip },
                    });
                    self.b().updateRefs(ops.items) catch |err| switch (err) {
                        error.RefConflict => return error.ConcurrentModification,
                        else => |e| return e,
                    };
                    const merged_ref = try recordRef(arena, remote, .merged, ns, id);
                    try self.setRef(arena, merged_ref, remote_tip);
                    const pushed_ref = try recordRef(arena, remote, .pushed, ns, id);
                    try self.setRef(arena, pushed_ref, remote_tip);
                    try self.deleteRef(arena, kept_name);
                    return local;
                },
                .keep_local => if (reason == .rewound) {
                    // The remote started over from an older point. Take it
                    // as the baseline so the next sync pushes ours back.
                    const merged_ref = try recordRef(arena, remote, .merged, ns, id);
                    try self.setRef(arena, merged_ref, remote_tip);
                    const pushed_ref = try recordRef(arena, remote, .pushed, ns, id);
                    try self.setRef(arena, pushed_ref, remote_tip);
                    try self.deleteRef(arena, marker_name);
                    try self.deleteRef(arena, kept_name);
                } else {
                    try self.setRef(arena, kept_name, remote_tip);
                },
            }
            return null;
        }

        pub fn sync(self: Self, arena: Allocator, remote: []const u8) Error!SyncReport {
            const merged = try self.merge(arena, remote, .{});
            const pushed = try self.push(arena, remote);
            return .{ .merge = merged, .push = pushed };
        }

        pub fn push(self: Self, arena: Allocator, remote: []const u8) Error!PushReport {
            return self.pushWith(arena, remote, .{});
        }

        pub fn syncWith(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            options: PushOptions,
        ) Error!SyncReport {
            const merged = try self.merge(arena, remote, .{});
            const pushed = try self.pushWith(arena, remote, options);
            return .{ .merge = merged, .push = pushed };
        }

        pub fn pushWith(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            options: PushOptions,
        ) Error!PushReport {
            if (!contract.isValidRemoteName(remote)) return error.InvalidRemoteName;
            try self.ensureRemote(arena, remote);
            try self.refreshPushed(arena, remote);
            // Pushed issues should carry their pointers. Issues that came in
            // through upstream have no derived ref yet.
            const att = attachments_mod.Attachments(B).fromRepo(self.repo);
            const local_tips = try self.refsUnder(arena, attachments_mod.ref_prefix);
            for (try self.repo.refs(arena)) |r| {
                const issue = self.repo.load(arena, r) catch continue;
                if (!local_tips.contains(r.id()) and issue.attachments.len == 0 and
                    issue.removed_attachments.len == 0) continue;
                _ = try att.reconcile(arena, issue, null);
            }
            var report: PushReport = .{
                .pushed = 0,
                .up_to_date = 0,
                .skipped_quarantined = 0,
                .merges = &.{},
            };
            var merges: std.ArrayList(MergeReport) = .empty;
            var skipped: std.ArrayList([]const u8) = .empty;
            var uploaded: std.StringHashMapUnmanaged(void) = .empty;

            var round: usize = 0;
            while (round < push_rounds) : (round += 1) {
                skipped.clearRetainingCapacity();
                const todo = try self.pendingIn(arena, remote, &skipped);
                report.skipped_quarantined = skipped.items.len;
                if (todo.len == 0) {
                    report.merges = merges.items;
                    report.skipped = skipped.items;
                    return report;
                }
                // All bytes before any ref, so a failed upload pushes
                // nothing.
                try self.uploadPending(arena, remote, todo, options, &report, &uploaded);
                var rejected = false;
                var start: usize = 0;
                while (start < todo.len) {
                    // An issue and its derived ref go in the same push.
                    var end = @min(start + push_chunk, todo.len);
                    while (end < todo.len and todo[end].ns == .attachments and
                        std.mem.eql(u8, todo[end].id, todo[end - 1].id)) end += 1;
                    const chunk = todo[start..end];
                    start = end;
                    var specs: std.ArrayList([]const u8) = .empty;
                    for (chunk) |r| try specs.append(
                        arena,
                        try std.fmt.allocPrint(arena, "{s}:{s}", .{ r.name, r.name }),
                    );
                    const result = try self.b().push(arena, remote, specs.items, true);
                    for (result.refs) |p| {
                        if (p.status == .rejected) {
                            rejected = true;
                            continue;
                        }
                        const pushed = findPending(chunk, p.name) orelse continue;
                        if (pushed.ns == .attachments) {
                            if (p.status == .ok) report.attachment_refs += 1;
                        } else if (p.status == .ok) report.pushed += 1 else report.up_to_date += 1;
                        try self.setRef(
                            arena,
                            try recordRef(arena, remote, .pushed, pushed.ns, pushed.id),
                            pushed.tip,
                        );
                    }
                    if (rejected) break;
                }
                if (!rejected) {
                    report.merges = merges.items;
                    report.skipped = skipped.items;
                    return report;
                }
                // The remote has changes we don't. Merge, then retry.
                try merges.append(arena, try self.merge(arena, remote, .{}));
            }
            return error.PushRoundsExhausted;
        }

        /// Sets the `pushed` records to what the remote has now. They go
        /// stale when someone else force-pushes or deletes a ref, and push
        /// only sends what differs from them.
        fn refreshPushed(self: Self, arena: Allocator, remote: []const u8) Error!void {
            // Left over from an interrupted push, they would read as what
            // the remote has.
            var stale: std.ArrayList(contract.RefUpdate) = .empty;
            for (fetched_namespaces) |ns| {
                for (try self.b().listRefs(arena, try recordRef(arena, remote, .seen, ns, ""))) |e| {
                    try stale.append(arena, .{ .name = e.name, .op = .{ .delete = e.oid } });
                }
            }
            if (stale.items.len > 0) self.b().updateRefs(stale.items) catch |err| switch (err) {
                error.RefConflict => return error.ConcurrentModification,
                else => |e| return e,
            };
            var specs: [fetched_namespaces.len][]const u8 = undefined;
            for (fetched_namespaces, &specs) |ns, *spec| spec.* = try std.fmt.allocPrint(
                arena,
                "+{s}*:{s}*",
                .{ ns.refPrefix(), try recordRef(arena, remote, .seen, ns, "") },
            );
            try self.b().fetch(arena, remote, &specs);
            // One transaction for all records, not a git call per issue.
            var ops: std.ArrayList(contract.RefUpdate) = .empty;
            for (fetched_namespaces) |ns| {
                const seen_prefix = try recordRef(arena, remote, .seen, ns, "");
                const remote_tips = try self.refsUnder(arena, seen_prefix);
                const pushed_prefix = try recordRef(arena, remote, .pushed, ns, "");
                const pushed = try self.refsUnder(arena, pushed_prefix);
                for (try self.b().listRefs(arena, ns.refPrefix())) |r| {
                    const id = r.name[ns.refPrefix().len..];
                    const name = try std.mem.concat(arena, u8, &.{ pushed_prefix, id });
                    const old = pushed.get(id);
                    const op: ?contract.RefUpdate.Op = if (remote_tips.get(id)) |new|
                        (if (old) |o|
                            (if (o.eql(new)) null else .{ .update = .{ .new = new, .old = o } })
                        else
                            .{ .create = new })
                    else if (old) |o| .{ .delete = o } else null;
                    if (op) |o| try ops.append(arena, .{ .name = name, .op = o });
                }
                var it = remote_tips.iterator();
                while (it.next()) |e| try ops.append(arena, .{
                    .name = try std.mem.concat(arena, u8, &.{ seen_prefix, e.key_ptr.* }),
                    .op = .{ .delete = e.value_ptr.* },
                });
            }
            if (ops.items.len == 0) return;
            self.b().updateRefs(ops.items) catch |err| switch (err) {
                error.RefConflict => return error.ConcurrentModification,
                else => |e| return e,
            };
        }

        /// The refs under `prefix`, by the rest of their name.
        fn refsUnder(
            self: Self,
            arena: Allocator,
            prefix: []const u8,
        ) Error!std.StringHashMapUnmanaged(Oid) {
            var map: std.StringHashMapUnmanaged(Oid) = .empty;
            for (try self.b().listRefs(arena, prefix)) |e| {
                try map.put(arena, e.name[prefix.len..], e.oid);
            }
            return map;
        }

        const Pending = struct { name: []const u8, tip: Oid, ns: Namespace, id: []const u8 };

        /// Uploads the objects the pending derived refs list and the
        /// remote's derived refs don't, once per push. Objects this clone
        /// doesn't have are skipped: whoever attached them uploaded them.
        fn uploadPending(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            todo: []const Pending,
            options: PushOptions,
            report: *PushReport,
            uploaded: *std.StringHashMapUnmanaged(void),
        ) Error!void {
            if (comptime !contract.hasLfs(B)) return;
            const att = attachments_mod.Attachments(B).fromRepo(self.repo);
            var wanted: std.ArrayList(issue_model.Attachment) = .empty;
            for (todo) |p| if (p.ns == .attachments) {
                const name = try localRef(arena, .issues, p.id);
                const tip = (try self.b().resolveRef(name)) orelse continue;
                const issue = try self.repo.load(arena, .{ .name = name, .tip = tip });
                const record = try recordRef(arena, remote, .pushed, .attachments, p.id);
                const known = if (try self.b().resolveRef(record)) |t|
                    try att.derivedIds(arena, t)
                else
                    &.{};
                for (issue.attachments) |a| {
                    if (uploaded.contains(a.sha256.slice())) continue;
                    if (labels_fmt.contains(known, a.id)) continue;
                    try wanted.append(arena, a);
                }
            };
            if (wanted.items.len == 0) return;
            const mode: attachments_mod.UploadMode = if (options.before_push != null)
                .caller
            else
                .git_lfs;
            const ups = try att.uploads(arena, wanted.items, mode);
            if (ups.len == 0) return;
            if (options.before_push) |hook| {
                hook.run(hook.context, remote, ups) catch return error.BeforePushFailed;
            } else {
                if (comptime !contract.hasLfsTransport(B)) return error.LfsUnavailable;
                var shas: std.ArrayList([]const u8) = .empty;
                for (ups) |u| try shas.append(arena, u.sha256);
                self.b().lfsPush(arena, remote, shas.items) catch |e| switch (e) {
                    error.LfsUnavailable => return error.LfsUnavailable,
                    error.LfsTransferFailed => return error.LfsUploadFailed,
                    else => |x| return x,
                };
            }
            for (ups) |u| try uploaded.put(arena, u.sha256, {});
            report.lfs_uploaded += ups.len;
        }

        /// What the remote doesn't have yet, by our records.
        fn pendingIn(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            skipped: *std.ArrayList([]const u8),
        ) Error![]Pending {
            var out: std.ArrayList(Pending) = .empty;
            for (namespaces) |ns| {
                const markers = try self.refsUnder(
                    arena,
                    try recordRef(arena, remote, .quarantined, ns, ""),
                );
                const records = try self.refsUnder(
                    arena,
                    try recordRef(arena, remote, .pushed, ns, ""),
                );
                for (try self.b().listRefs(arena, ns.refPrefix())) |r| {
                    const id = r.name[ns.refPrefix().len..];
                    if (markers.contains(id)) {
                        try skipped.append(arena, id);
                        continue;
                    }
                    const pushed = records.get(id);
                    if (pushed != null and pushed.?.eql(r.oid)) continue;
                    try out.append(arena, .{ .name = r.name, .tip = r.oid, .ns = ns, .id = id });
                }
            }
            // Derived refs right after their issue, or on their own if the
            // issue is already pushed.
            const ns: Namespace = .attachments;
            const markers = try self.refsUnder(
                arena,
                try recordRef(arena, remote, .quarantined, .issues, ""),
            );
            const records = try self.refsUnder(arena, try recordRef(arena, remote, .pushed, ns, ""));
            var derived: std.StringArrayHashMapUnmanaged(Pending) = .empty;
            for (try self.b().listRefs(arena, ns.refPrefix())) |r| {
                const id = r.name[ns.refPrefix().len..];
                if (markers.contains(id)) continue;
                const pushed = records.get(id);
                if (pushed != null and pushed.?.eql(r.oid)) continue;
                try derived.put(arena, id, .{ .name = r.name, .tip = r.oid, .ns = ns, .id = id });
            }
            var with_derived: std.ArrayList(Pending) = .empty;
            for (out.items) |p| {
                try with_derived.append(arena, p);
                if (p.ns != .issues) continue;
                if (derived.fetchSwapRemove(p.id)) |d| try with_derived.append(arena, d.value);
            }
            try with_derived.appendSlice(arena, derived.values());
            return with_derived.items;
        }

        fn pendingRefs(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            skipped: *std.ArrayList([]const u8),
        ) Error![]repo_mod.IssueRef {
            var out: std.ArrayList(repo_mod.IssueRef) = .empty;
            for (try self.pendingIn(arena, remote, skipped)) |p| {
                if (p.ns == .issues) try out.append(arena, .{ .name = p.name, .tip = p.tip });
            }
            return out.items;
        }

        fn ensureRemote(self: Self, arena: Allocator, remote: []const u8) Error!void {
            for (try self.b().remoteNames(arena)) |r| if (std.mem.eql(u8, r, remote)) return;
            return error.UnknownRemote;
        }

        /// CAS against what we read.
        fn setRef(self: Self, arena: Allocator, name: []const u8, value: Oid) Error!void {
            _ = arena;
            var attempt: u8 = 0;
            while (attempt < self.repo.limits.cas_retries) : (attempt += 1) {
                const current = try self.b().resolveRef(name);
                if (current != null and current.?.eql(value)) return;
                const op: contract.RefUpdate.Op = if (current) |c| .{ .update = .{
                    .new = value,
                    .old = c,
                } } else .{ .create = value };
                self.b().updateRefs(&.{.{ .name = name, .op = op }}) catch |err| switch (err) {
                    error.RefConflict => continue,
                    else => |e| return e,
                };
                return;
            }
            return error.ConcurrentModification;
        }

        fn deleteRef(self: Self, arena: Allocator, name: []const u8) Error!void {
            _ = arena;
            const current = (try self.b().resolveRef(name)) orelse return;
            self.b().updateRefs(&.{.{
                .name = name,
                .op = .{ .delete = current },
            }}) catch |err| switch (err) {
                error.RefConflict => {}, // someone else changed it; leave it
                else => |e| return e,
            };
        }
    };
}

/// `refs/<ns>/<id>`.
fn localRef(arena: Allocator, ns: Namespace, id: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}", .{ ns.refPrefix(), id });
}

fn findPending(list: anytype, name: []const u8) ?@TypeOf(list[0]) {
    for (list) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

fn stagingPrefix(arena: Allocator, remote: []const u8, ns: Namespace) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "refs/remotes/{s}/{t}/", .{ remote, ns });
}

fn titleIn(ns: Namespace, loaded: issue_model.Issue) []const u8 {
    return if (ns == .milestones) loaded.field("Name") orelse "?" else loaded.title;
}

fn rootKeys(ns: Namespace) []const []const u8 {
    return switch (ns) {
        .issues => &.{ "State", "Format-Version" },
        .milestones => &.{ "Name", "Format-Version" },
        .attachments => &.{},
    };
}

/// `refs/issuez-sync/<remote>/<record>/<ns>/<id>`. An empty `id` gives
/// the prefix.
pub fn recordRef(
    arena: Allocator,
    remote: []const u8,
    record: Record,
    ns: Namespace,
    id: []const u8,
) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "refs/issuez-sync/{s}/{t}/{t}/{s}", .{ remote, record, ns, id });
}

/// Where `resolve(.accept_remote)` keeps the local tip it replaced.
pub fn replacedRef(
    arena: Allocator,
    remote: []const u8,
    ns: Namespace,
    id: []const u8,
    tip: Oid,
) Allocator.Error![]const u8 {
    const hex = tip.hex();
    const prefix = try recordRef(arena, remote, .replaced, ns, id);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, hex.slice() });
}

const GitSim = @import("../backend/GitSim.zig");
const testing = std.testing;

const remote_config: []const GitSim.World.ConfigEntry = &.{.{
    .key = "remote.origin.url",
    .value = "sim:hub",
}};

fn testWorld() GitSim.World {
    return .{ .seed = 11, .clones = &.{
        .{ .name = "alice", .config = remote_config },
        .{ .name = "bob", .config = remote_config },
        .{ .name = "hub" },
    } };
}

fn onClone(
    arena: Allocator,
    world: *GitSim.World,
    idx: usize,
) !struct { sim: *GitSim, sync: Sync(GitSim) } {
    const sim = try arena.create(GitSim);
    sim.* = try GitSim.init(arena, world, idx);
    return .{ .sim = sim, .sync = Sync(GitSim).init(sim) };
}

test "push and merge converge" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();

    var a = try onClone(arena, &world, 0);
    const created = try a.sync.repo.create(arena, .{ .title = "Shared", .labels = &.{"bug"} });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});
    const pushed = try a.sync.push(arena, "origin");
    try testing.expectEqual(@as(usize, 1), pushed.pushed);
    try a.sim.commit();

    var bob = try onClone(arena, &world, 1);
    const m1 = try bob.sync.merge(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), m1.count(.created));
    try bob.sim.commit();

    a = try onClone(arena, &world, 0);
    _ = try a.sync.repo.edit(arena, ref_name, .{ .priority = .{ .set = .high }, .add_labels = &.{"ui"} });
    try a.sim.commit();
    bob = try onClone(arena, &world, 1);
    _ = try bob.sync.repo.edit(
        arena,
        ref_name,
        .{ .assignee = "bob@e.x", .remove_labels = &.{"bug"} },
    );
    _ = try bob.sync.push(arena, "origin");
    try bob.sim.commit();

    // Alice's push is rejected, so she merges and retries.
    a = try onClone(arena, &world, 0);
    const p2 = try a.sync.push(arena, "origin");
    try testing.expectEqual(@as(usize, 1), p2.merges.len);
    try testing.expectEqual(@as(usize, 1), p2.merges[0].count(.merged));
    try testing.expectEqual(@as(usize, 1), p2.pushed);
    const merged_issue = try a.sync.repo.load(
        arena,
        (try a.sync.repo.resolve(arena, created.id.short())).one,
    );
    try a.sim.commit();
    try testing.expectEqualStrings("high", merged_issue.field("Priority").?);
    try testing.expectEqualStrings("bob@e.x", merged_issue.field("Assignee").?);
    try testing.expectEqual(@as(usize, 1), merged_issue.labels.len); // bug removed, ui added
    try testing.expectEqualStrings("ui", merged_issue.labels[0]);

    const tip_obj = (try a.sim.readObject(arena, merged_issue.tip)).?;
    const tip = try object.Commit.parse(arena, .sha1, tip_obj.data);
    try testing.expectEqual(@as(usize, 2), tip.parents.len);
    try testing.expect(tip.parents[0].order(tip.parents[1]) == .lt);
    try testing.expectEqualStrings(merge_identity_name, tip.author.name);
    try testing.expect(std.mem.startsWith(u8, tip.message, "Merge issue\n\nState: open\n"));

    // Bob fast-forwards, everyone is on one tip.
    bob = try onClone(arena, &world, 1);
    const m3 = try bob.sync.merge(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), m3.count(.fast_forwarded));
    try testing.expect((try bob.sim.resolveRef(ref_name)).?.eql(merged_issue.tip));
    const p3 = try bob.sync.push(arena, "origin");
    try testing.expectEqual(@as(usize, 0), p3.pushed);
    try testing.expectEqual(@as(usize, 0), (try bob.sim.listRefs(arena, "refs/remotes/")).len);
    try bob.sim.commit();
}

test "merge commits restate extension fields" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();

    var a = try onClone(arena, &world, 0);
    const epic = try a.sync.repo.create(arena, .{ .title = "Epic" });
    const created = try a.sync.repo.create(arena, .{ .title = "Shared" });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});
    _ = try a.sync.push(arena, "origin");
    try a.sim.commit();
    var bob = try onClone(arena, &world, 1);
    _ = try bob.sync.merge(arena, "origin", .{});
    try bob.sim.commit();

    a = try onClone(arena, &world, 0);
    _ = try a.sync.repo.edit(arena, ref_name, .{
        .parent = epic.id.slice(),
        .due_date = "2026-12-01",
    });
    try a.sim.commit();
    bob = try onClone(arena, &world, 1);
    _ = try bob.sync.repo.edit(arena, ref_name, .{
        .add_blocked_by = &.{epic.id.slice()},
        .estimate_minutes = .{ .set = 90 },
        .workflow = "ready",
    });
    _ = try bob.sync.push(arena, "origin");
    try bob.sim.commit();

    a = try onClone(arena, &world, 0);
    const p = try a.sync.push(arena, "origin");
    try testing.expectEqual(@as(usize, 1), p.merges[0].count(.merged));
    const tip = (try a.sim.resolveRef(ref_name)).?;
    const commit = try object.Commit.parse(arena, .sha1, (try a.sim.readObject(arena, tip)).?.data);
    try a.sim.commit();
    const want = try std.fmt.allocPrint(arena,
        \\Merge issue
        \\
        \\State: open
        \\X-Parent: {s}
        \\X-Due-Date: 2026-12-01
        \\X-Estimate-Minutes: 90
        \\X-Workflow-State: ready
        \\X-Blocked-By: {s}
        \\
    , .{ epic.id.slice(), epic.id.slice() });
    try testing.expectEqualStrings(want, commit.message);
}

test "merge commits restate cleared fields as empty" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();

    var a = try onClone(arena, &world, 0);
    const created = try a.sync.repo.create(arena, .{
        .title = "Shared",
        .labels = &.{"bug"},
        .priority = .high,
    });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});
    _ = try a.sync.push(arena, "origin");
    try a.sim.commit();
    var bob = try onClone(arena, &world, 1);
    _ = try bob.sync.merge(arena, "origin", .{});
    _ = try bob.sync.repo.edit(arena, ref_name, .{ .set_labels = &.{}, .priority = .clear });
    _ = try bob.sync.push(arena, "origin");
    try bob.sim.commit();

    a = try onClone(arena, &world, 0);
    _ = try a.sync.repo.comment(arena, ref_name, .{ .text = "Meanwhile" });
    const p = try a.sync.push(arena, "origin");
    try testing.expectEqual(@as(usize, 1), p.merges[0].count(.merged));
    const tip = (try a.sim.resolveRef(ref_name)).?;
    const commit = try object.Commit.parse(arena, .sha1, (try a.sim.readObject(arena, tip)).?.data);
    try a.sim.commit();
    // A reader taking the newest value finds the cleared ones empty.
    try testing.expectEqualStrings("Merge issue\n\nState: open\nLabels: \nPriority: \n", commit.message);
}

test "deterministic merge commits" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 12, .clones = &.{
        .{ .name = "alice", .config = remote_config },
        .{ .name = "bob", .config = &.{
            .{ .key = "remote.origin.url", .value = "sim:hub" },
            .{ .key = "remote.alice.url", .value = "sim:alice" },
        } },
        .{ .name = "hub" },
    } };

    var a = try onClone(arena, &world, 0);
    const created = try a.sync.repo.create(arena, .{ .title = "T", .priority = .low });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});
    _ = try a.sync.push(arena, "origin");
    try a.sim.commit();
    var bob = try onClone(arena, &world, 1);
    _ = try bob.sync.merge(arena, "origin", .{});
    try bob.sim.commit();

    a = try onClone(arena, &world, 0);
    _ = try a.sync.repo.edit(arena, ref_name, .{ .priority = .{ .set = .high } });
    try a.sim.commit();
    bob = try onClone(arena, &world, 1);
    _ = try bob.sync.repo.comment(arena, ref_name, .{ .text = "from bob" });
    _ = try bob.sync.push(arena, "origin");
    try bob.sim.commit();

    // Alice merges bob's tip through the hub...
    a = try onClone(arena, &world, 0);
    _ = try a.sync.merge(arena, "origin", .{});
    const alice_merge = (try a.sim.resolveRef(ref_name)).?;
    try a.sim.commit();
    // ...while bob merges alice's tip from before that, directly. Same
    // parents, same merge commit.
    bob = try onClone(arena, &world, 1);
    const alice_merge_obj = (try GitSim.init(arena, &world, 0)).objects.get(alice_merge).?;
    const parents = (try object.Commit.parse(arena, .sha1, alice_merge_obj.data)).parents;
    const bob_tip = (try bob.sim.resolveRef(ref_name)).?;
    const alice_pre = if (parents[0].eql(bob_tip)) parents[1] else parents[0];
    _ = try bob.sync.merge(arena, "alice", .{}); // fetches alice's refs (including the merge)
    try testing.expect((try bob.sim.resolveRef(ref_name)).?.eql(alice_merge));
    // Merging the pair explicitly gives the same OID too.
    const again = try bob.sync.mergeCommitForTest(arena, created.id.slice(), bob_tip, alice_pre);
    try testing.expect(again.eql(alice_merge));
}

test "merge without fetch" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();

    var a = try onClone(arena, &world, 0);
    const created = try a.sync.repo.create(arena, .{ .title = "Staged" });
    _ = try a.sync.push(arena, "origin");
    try a.sim.commit();

    // Bob fetches by hand, then merges twice without fetching.
    var bob = try onClone(arena, &world, 1);
    try bob.sim.fetch(arena, "origin", &.{"+refs/issues/*:refs/remotes/origin/issues/*"});
    const staged = try std.fmt.allocPrint(
        arena,
        "refs/remotes/origin/issues/{s}",
        .{created.id.slice()},
    );
    const first = try bob.sync.merge(arena, "origin", .{ .fetch = false });
    try testing.expectEqual(@as(usize, 1), first.count(.created));
    try testing.expect(try bob.sim.resolveRef(staged) != null);
    const again = try bob.sync.merge(arena, "origin", .{ .fetch = false });
    try testing.expectEqual(@as(usize, 1), again.count(.up_to_date));
    try testing.expect(try bob.sim.resolveRef(staged) != null);

    const fetched = try bob.sync.merge(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), fetched.count(.up_to_date));
    try testing.expect(try bob.sim.resolveRef(staged) == null);
}

test "sync reports conflicts" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();

    var a = try onClone(arena, &world, 0);
    const created = try a.sync.repo.create(arena, .{ .title = "Contested", .priority = .low });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});
    const first = try a.sync.sync(arena, "origin");
    try testing.expectEqual(@as(usize, 1), first.push.pushed);
    try testing.expectEqual(@as(usize, 0), (try first.conflicted(arena)).len);
    try a.sim.commit();

    var bob = try onClone(arena, &world, 1);
    _ = try bob.sync.sync(arena, "origin");
    _ = try bob.sync.repo.edit(arena, ref_name, .{ .priority = .{ .set = .high } });
    _ = try bob.sync.sync(arena, "origin");
    try bob.sim.commit();

    // Alice changed the same field concurrently. Her sync keeps one value
    // and reports the conflict.
    a = try onClone(arena, &world, 0);
    _ = try a.sync.repo.edit(arena, ref_name, .{ .priority = .{ .set = .critical } });
    const report = try a.sync.sync(arena, "origin");
    const conflicted = try report.conflicted(arena);
    try testing.expectEqual(@as(usize, 1), conflicted.len);
    try testing.expectEqualStrings(created.id.slice(), conflicted[0].id);
    try testing.expectEqualStrings("Priority", conflicted[0].conflicts[0].target.field);
    try testing.expectEqual(@as(usize, 1), report.push.pushed);
    try testing.expectEqual(@as(usize, 0), report.push.skipped.len);
}

/// An unrelated root under an existing ID, as if two tools had picked the
/// same UUID.
fn foreignRoot(arena: Allocator, sim: *GitSim, title: []const u8) !Oid {
    const r = repo_mod.Repo(GitSim).init(sim);
    const who = try sim.identity(arena);
    const message = try std.fmt.allocPrint(
        arena,
        "{s}\n\nState: open\nFormat-Version: 1\n",
        .{title},
    );
    return r.writeCommit(arena, &.{}, who, message);
}

test "quarantine" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();

    var a = try onClone(arena, &world, 0);
    const created = try a.sync.repo.create(arena, .{ .title = "Alice's" });
    const id = created.id.slice();
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{id});
    _ = try a.sync.push(arena, "origin");
    try a.sim.commit();

    var bob = try onClone(arena, &world, 1);
    const bobs = try foreignRoot(arena, bob.sim, "Bob's");
    try bob.sim.updateRefs(&.{.{ .name = ref_name, .op = .{ .create = bobs } }});
    const m1 = try bob.sync.merge(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), m1.count(.quarantined));
    try testing.expect(!m1.entries[0].kept_local);

    const st = try bob.sync.status(arena, "origin");
    try testing.expectEqual(@as(usize, 1), st.quarantined.len);
    try testing.expectEqualStrings("Bob's", st.quarantined[0].title);
    try testing.expectEqual(Reason.unrelated_history, st.quarantined[0].reason.?);
    try testing.expect(st.quarantined[0].remote_tip.eql(created.tip));
    try testing.expectEqual(@as(usize, 0), st.pending.len); // quarantined is not pending

    // keep_local: still quarantined, since pushing would take a force push,
    // but no longer reported.
    _ = try bob.sync.resolve(arena, "origin", id, .keep_local);
    const m2 = try bob.sync.merge(arena, "origin", .{});
    try testing.expect(m2.entries[0].kept_local);
    try testing.expect((try bob.sim.resolveRef(ref_name)).?.eql(bobs));

    // accept_remote: Alice's version wins and Bob's is kept in a ref.
    _ = try bob.sync.resolve(arena, "origin", id, .accept_remote);
    try testing.expect((try bob.sim.resolveRef(ref_name)).?.eql(created.tip));
    const backup = try replacedRef(arena, "origin", .issues, id, bobs);
    try testing.expect((try bob.sim.resolveRef(backup)).?.eql(bobs));

    // Accepting again keeps both replaced versions.
    const again = try foreignRoot(arena, bob.sim, "Bob's again");
    try bob.sim.updateRefs(&.{.{
        .name = ref_name,
        .op = .{ .update = .{ .new = again, .old = created.tip } },
    }});
    try testing.expectEqual(@as(usize, 1), (try bob.sync.merge(arena, "origin", .{})).count(.quarantined));
    _ = try bob.sync.resolve(arena, "origin", id, .accept_remote);
    try testing.expect((try bob.sim.resolveRef(backup)).?.eql(bobs));
    const backup_again = try replacedRef(arena, "origin", .issues, id, again);
    try testing.expect((try bob.sim.resolveRef(backup_again)).?.eql(again));
    try testing.expectEqual(@as(usize, 0), (try bob.sync.status(arena, "origin")).quarantined.len);
    const after = try bob.sync.sync(arena, "origin");
    try testing.expectEqual(@as(usize, 0), after.merge.count(.quarantined));
    try testing.expectEqual(@as(usize, 0), after.push.pushed);

    try testing.expectError(
        error.NotQuarantined,
        bob.sync.resolve(arena, "origin", id, .keep_local),
    );
}

test "quarantined milestones are reported and resolved" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();

    var a = try onClone(arena, &world, 0);
    const cat = @import("milestone.zig").Catalog(GitSim).of(a.sync.repo);
    const created = try cat.create(arena, .{ .name = "v1" });
    const id = created.id.slice();
    const ref_name = try std.fmt.allocPrint(arena, "refs/milestones/{s}", .{id});
    _ = try a.sync.push(arena, "origin");
    try a.sim.commit();

    // Bob has an unrelated milestone under the same UUID.
    var bob = try onClone(arena, &world, 1);
    const r = repo_mod.Repo(GitSim).init(bob.sim);
    const bobs = try r.writeCommit(
        arena,
        &.{},
        try bob.sim.identity(arena),
        "Create milestone v1\n\nName: Bob's v1\nFormat-Version: 1\n",
    );
    try bob.sim.updateRefs(&.{.{ .name = ref_name, .op = .{ .create = bobs } }});
    const merged = try bob.sync.merge(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), merged.count(.quarantined));

    const st = try bob.sync.status(arena, "origin");
    try testing.expectEqual(@as(usize, 1), st.quarantined.len);
    try testing.expectEqual(Namespace.milestones, st.quarantined[0].namespace);
    try testing.expectEqualStrings("Bob's v1", st.quarantined[0].title);
    try testing.expectEqual(Reason.unrelated_history, st.quarantined[0].reason.?);

    _ = try bob.sync.resolve(arena, "origin", id, .accept_remote);
    try testing.expect((try bob.sim.resolveRef(ref_name)).?.eql(created.tip));
    const backup = try replacedRef(arena, "origin", .milestones, id, bobs);
    try testing.expect((try bob.sim.resolveRef(backup)).?.eql(bobs));
    try testing.expectEqual(@as(usize, 0), (try bob.sync.status(arena, "origin")).quarantined.len);
}

test "keep_local on a rewound remote" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();

    var a = try onClone(arena, &world, 0);
    const created = try a.sync.repo.create(arena, .{ .title = "Rewound" });
    const id = created.id.slice();
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{id});
    _ = try a.sync.push(arena, "origin");
    _ = try a.sync.repo.comment(arena, ref_name, .{ .text = "Second" });
    _ = try a.sync.push(arena, "origin");
    try a.sim.commit();

    var bob = try onClone(arena, &world, 1);
    _ = try bob.sync.merge(arena, "origin", .{});
    try bob.sim.commit();

    // Someone rewrites the hub's history: back to the root, plus a new
    // commit Bob doesn't have.
    var hub = try GitSim.init(arena, &world, 2);
    const hub_tip = (try hub.resolveRef(ref_name)).?;
    const sig: object.Signature = .{
        .name = "Mallory",
        .email = "mallory@example.invalid",
        .time = 1,
        .tz_offset_minutes = 0,
    };
    const rewritten: object.Commit = .{
        .tree = object.emptyTree(hub.objectFormat()),
        .parents = &.{created.tip},
        .author = sig,
        .committer = sig,
        .message = "Rewritten\n",
    };
    const new_tip = try hub.writeObject(.commit, try rewritten.serializeAlloc(arena));
    try hub.updateRefs(&.{.{
        .name = ref_name,
        .op = .{ .update = .{ .new = new_tip, .old = hub_tip } },
    }});
    try hub.commit();

    bob = try onClone(arena, &world, 1);
    const m = try bob.sync.merge(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), m.count(.quarantined));
    const st = try bob.sync.status(arena, "origin");
    try testing.expectEqual(Reason.rewound, st.quarantined[0].reason.?);

    _ = try bob.sync.resolve(arena, "origin", id, .keep_local);
    try testing.expectEqual(@as(usize, 0), (try bob.sync.status(arena, "origin")).quarantined.len);
    // The rewritten history is the new baseline: sync merges it with Bob's
    // and pushes the result.
    const s = try bob.sync.sync(arena, "origin");
    try testing.expectEqual(@as(usize, 0), s.merge.count(.quarantined));
    try testing.expectEqual(@as(usize, 1), s.merge.count(.merged));
    try testing.expectEqual(@as(usize, 1), s.push.pushed);
}

test "remote reset to an older tip gets the local tip again" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();

    var a = try onClone(arena, &world, 0);
    const created = try a.sync.repo.create(arena, .{ .title = "Reset" });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});
    _ = try a.sync.repo.comment(arena, ref_name, .{ .text = "Second" });
    _ = try a.sync.push(arena, "origin");
    const local_tip = (try a.sim.resolveRef(ref_name)).?;
    try a.sim.commit();

    // Someone force-pushes the issue back to its root.
    var hub = try GitSim.init(arena, &world, 2);
    try hub.updateRefs(&.{.{
        .name = ref_name,
        .op = .{ .update = .{ .new = created.tip, .old = local_tip } },
    }});
    try hub.commit();

    a = try onClone(arena, &world, 0);
    const s = try a.sync.sync(arena, "origin");
    try testing.expectEqual(@as(usize, 1), s.merge.count(.local_ahead));
    try testing.expectEqual(@as(usize, 1), s.push.pushed);
    try a.sim.commit();
    hub = try GitSim.init(arena, &world, 2);
    try testing.expect((try hub.resolveRef(ref_name)).?.eql(local_tip));

    // Push alone, without a merge, notices too.
    try hub.updateRefs(&.{.{
        .name = ref_name,
        .op = .{ .update = .{ .new = created.tip, .old = local_tip } },
    }});
    try hub.commit();
    a = try onClone(arena, &world, 0);
    const p = try a.sync.push(arena, "origin");
    try testing.expectEqual(@as(usize, 1), p.pushed);
    try testing.expectEqual(@as(usize, 0), (try a.sim.listRefs(arena, "refs/issuez-sync/origin/seen/")).len);
    try a.sim.commit();
    hub = try GitSim.init(arena, &world, 2);
    try testing.expect((try hub.resolveRef(ref_name)).?.eql(local_tip));

    // Also after a merge recorded the newer tip: the local issue still has
    // everything, so it's not a rewrite to quarantine.
    a = try onClone(arena, &world, 0);
    _ = try a.sync.merge(arena, "origin", .{});
    try a.sim.commit();
    hub = try GitSim.init(arena, &world, 2);
    try hub.updateRefs(&.{.{
        .name = ref_name,
        .op = .{ .update = .{ .new = created.tip, .old = local_tip } },
    }});
    try hub.commit();
    a = try onClone(arena, &world, 0);
    const again = try a.sync.sync(arena, "origin");
    try testing.expectEqual(@as(usize, 0), again.merge.count(.quarantined));
    try testing.expectEqual(@as(usize, 1), again.merge.count(.local_ahead));
    try testing.expectEqual(@as(usize, 1), again.push.pushed);
}

test "attachment sync" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();
    const samples = @import("../format/attachment.zig").samples;
    const A = attachments_mod.Attachments(GitSim);

    var a = try onClone(arena, &world, 0);
    const created = try a.sync.repo.create(arena, .{ .title = "Shots" });
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});
    const derived = try A.derivedRefName(arena, created.id.slice());
    _ = try A.fromRepo(a.sync.repo).add(arena, ref, .{
        .files = &.{.{ .name = "a.png", .data = samples.png }},
    });
    const first = try a.sync.sync(arena, "origin");
    try testing.expectEqual(@as(usize, 1), first.push.lfs_uploaded);
    try testing.expectEqual(@as(usize, 1), first.push.pushed);
    try testing.expectEqual(@as(usize, 1), first.push.attachment_refs);
    try a.sim.commit();
    const hub = world.clones[2];
    try testing.expect(for (hub.refs) |r| {
        if (std.mem.eql(u8, r.name, derived)) break true;
    } else false);
    try testing.expectEqual(@as(usize, 1), hub.lfs.len);

    // Bob gets the issue and the derived ref but not the bytes.
    var bob = try onClone(arena, &world, 1);
    const got = try bob.sync.merge(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), got.attachment_refs);
    const bob_att = A.fromRepo(bob.sync.repo);
    const bob_tip = (try bob.sim.resolveRef(ref)).?;
    var issue = try bob.sync.repo.load(arena, .{ .name = ref, .tip = bob_tip });
    try testing.expect(try bob_att.read(arena, issue.attachments[0]) == .missing);
    const fetched = try bob_att.fetch(arena, "origin", &.{issue});
    try testing.expectEqual(@as(usize, 1), fetched.fetched);
    try testing.expect(try bob_att.read(arena, issue.attachments[0]) == .bytes);

    _ = try bob_att.add(arena, ref, .{ .files = &.{.{ .name = "b.webp", .data = samples.webp }} });
    try bob.sim.commit();
    a = try onClone(arena, &world, 0);
    _ = try A.fromRepo(a.sync.repo).add(arena, ref, .{
        .files = &.{.{ .name = "c.jpg", .data = samples.jpeg }},
    });
    _ = try a.sync.sync(arena, "origin");
    try a.sim.commit();
    bob = try onClone(arena, &world, 1);
    _ = try bob.sync.sync(arena, "origin"); // merges the issue, reconciles, pushes
    try bob.sim.commit();
    a = try onClone(arena, &world, 0);
    const last = try a.sync.sync(arena, "origin");
    try testing.expectEqual(@as(usize, 1), last.merge.attachment_refs); // fast-forward
    try a.sim.commit();

    const tipOf = struct {
        fn f(clone: GitSim.World.Clone, name: []const u8) ?[]const u8 {
            for (clone.refs) |r| if (std.mem.eql(u8, r.name, name)) return r.oid;
            return null;
        }
    }.f;
    for ([_][]const u8{ ref, derived }) |name| {
        const h = tipOf(world.clones[2], name).?;
        try testing.expectEqualStrings(h, tipOf(world.clones[0], name).?);
        try testing.expectEqualStrings(h, tipOf(world.clones[1], name).?);
    }
    a = try onClone(arena, &world, 0);
    issue = try a.sync.repo.load(arena, .{ .name = ref, .tip = (try a.sim.resolveRef(ref)).? });
    try testing.expectEqual(@as(usize, 3), issue.attachments.len);
    const state = try A.fromRepo(a.sync.repo).derivedState(arena, issue);
    try testing.expectEqual(A.DerivedState.ok, state);
    try testing.expectEqual(@as(usize, 3), world.clones[2].lfs.len);
}

test "before_push and no git-lfs" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 12, .clones = &.{
        .{ .name = "alice", .config = remote_config },
        .{ .name = "hub" },
    } };
    const samples = @import("../format/attachment.zig").samples;
    const A = attachments_mod.Attachments(GitSim);
    var a = try onClone(arena, &world, 0);
    const created = try a.sync.repo.create(arena, .{ .title = "Shots" });
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});
    _ = try A.fromRepo(a.sync.repo).add(arena, ref, .{
        .files = &.{.{ .name = "a.png", .data = samples.png }},
    });

    // A failing hook stops the push before any ref moves.
    const Hook = struct {
        calls: usize = 0,
        fail: bool,
        fn run(
            ctx: *anyopaque,
            remote: []const u8,
            objects: []const attachments_mod.Upload,
        ) anyerror!void {
            const h: *@This() = @ptrCast(@alignCast(ctx));
            h.calls += 1;
            try testing.expectEqualStrings("origin", remote);
            try testing.expectEqual(@as(usize, 1), objects.len);
            if (h.fail) return error.Offline;
        }
    };
    var failing: Hook = .{ .fail = true };
    try testing.expectError(error.BeforePushFailed, a.sync.pushWith(arena, "origin", .{
        .before_push = .{ .context = &failing, .run = Hook.run },
    }));
    try a.sim.commit();
    try testing.expectEqual(@as(usize, 0), world.clones[1].refs.len);
    var ok: Hook = .{ .fail = false };
    a = try onClone(arena, &world, 0);
    const pushed = try a.sync.pushWith(arena, "origin", .{
        .before_push = .{ .context = &ok, .run = Hook.run },
    });
    try testing.expectEqual(@as(usize, 1), ok.calls);
    try testing.expectEqual(@as(usize, 1), pushed.lfs_uploaded);
    // Only what the remote's derived ref doesn't list yet.
    _ = try A.fromRepo(a.sync.repo).add(arena, ref, .{
        .files = &.{.{ .name = "b.jpg", .data = samples.jpeg }},
    });
    _ = try a.sync.pushWith(arena, "origin", .{
        .before_push = .{ .context = &ok, .run = Hook.run },
    });
    try testing.expectEqual(@as(usize, 2), ok.calls);

    // Without git-lfs: attachment calls refuse up front, and a push with
    // bytes to upload fails before any ref moves.
    _ = try A.fromRepo(a.sync.repo).add(arena, ref, .{
        .files = &.{.{ .name = "c.webp", .data = samples.webp }},
    });
    try a.sim.configAdd("sim.lfs", "false");
    const att = A.fromRepo(a.sync.repo);
    try testing.expectError(error.LfsUnavailable, att.add(arena, ref, .{
        .files = &.{.{ .name = "d.png", .data = samples.png }},
    }));
    const hub_before = world.clones[1].refs;
    try testing.expectError(error.LfsUnavailable, a.sync.push(arena, "origin"));
    try a.sim.commit();
    try testing.expectEqualDeep(hub_before, world.clones[1].refs);
    // With nothing to upload, push needs no git-lfs.
    a = try onClone(arena, &world, 0);
    try a.sim.configAdd("sim.lfs", "true");
    _ = try a.sync.push(arena, "origin");
    try a.sim.configAdd("sim.lfs", "false");
    _ = try a.sync.repo.create(arena, .{ .title = "No images" });
    const plain = try a.sync.push(arena, "origin");
    try testing.expectEqual(@as(usize, 1), plain.pushed);
}

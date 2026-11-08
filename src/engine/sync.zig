//! Merge, push and sync with a git remote.
//!
//! Fetches land in `refs/issuez-sync/<remote>/seen/<ns>/`, kept between
//! syncs, and get merged from there (`--no-fetch` merges the user's own
//! fetch in `refs/remotes/<remote>/<ns>/`). What we merged, what the
//! remote has and what we refused is recorded in
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
const purge_mod = @import("purge.zig");

const Oid = object.Oid;

pub const merge_identity_name = "git-issue";
pub const merge_identity_email = "git-issue@invalid";
pub const merge_subject = "Merge issue";
pub const purge_merge_subject = purge_mod.merge_subject;

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
    /// A tombstone purged the whole issue (format.md §10): the remote's
    /// copy is ignored, and the next push deletes it.
    purged,
};

/// `attachments` is fetched and pushed but never merged: the derived refs
/// are rebuilt from the merged issues. `purged` holds the tombstones,
/// merged before the issues and applied to them.
pub const Namespace = enum {
    issues,
    milestones,
    attachments,
    purged,

    pub fn refPrefix(ns: Namespace) []const u8 {
        return switch (ns) {
            .issues => "refs/issues/",
            .milestones => "refs/milestones/",
            .attachments => "refs/attachments/",
            .purged => purge_mod.ref_prefix,
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
    /// The remote's refs as of the last fetch by merge or push. Kept
    /// between syncs, so a fetch only writes what changed.
    seen,
    /// Local tips that `accept_remote` replaced, one ref per tip.
    replaced,
};

pub const namespaces = [_]Namespace{ .issues, .milestones };
pub const fetched_namespaces = [_]Namespace{ .issues, .milestones, .attachments, .purged };

/// `before_push` gets the LFS objects that the pushed attachment refs
/// point at and the remote doesn't have yet, before any ref is pushed, so
/// an embedder can upload them through its own LFS client. If it fails,
/// nothing is pushed. Without it, sync uses `git lfs push`, and fails with
/// LfsUnavailable, again before pushing anything, when there are objects
/// to upload and no git-lfs.
pub const PushOptions = struct {
    before_push: ?BeforePush = null,
    /// false right after a `merge` that fetched (and checked the remote):
    /// `seen/` is current, so the push doesn't fetch again.
    fetch: bool = true,
    progress: ?Progress = null,
};

/// Where a merge or push is, for a front end to show.
pub const Phase = enum { fetching, merging, pushing };

pub const Progress = struct {
    context: *anyopaque,
    phase: *const fn (context: *anyopaque, phase: Phase) void,

    fn report(p: ?Progress, phase: Phase) void {
        if (p) |x| x.phase(x.context, phase);
    }
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
    /// The same, and milestones, with whether the remote ever had them.
    unpushed: []const Unpushed = &.{},
};

pub const Unpushed = struct {
    namespace: Namespace,
    id: []const u8,
    /// Null for a purged issue whose remote ref the push deletes.
    tip: ?Oid,
    /// Never pushed to this remote.
    new: bool,
};

/// What `Sync.counts` finds: from local refs only.
pub const Counts = struct {
    /// Issues and milestones not pushed yet.
    unpushed: usize,
    /// Quarantines not answered by keeping the local version.
    quarantined: usize,
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
    progress: ?Progress = null,
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
    /// Tombstones sent, not counted in `pushed`.
    tombstones: usize = 0,
    /// Remote copies of purged issues deleted, counted in `pushed`.
    deleted: usize = 0,
    pushed: usize,
    up_to_date: usize,
    skipped_quarantined: usize,
    /// Quarantined issues that weren't pushed.
    skipped: []const []const u8 = &.{},
    /// Merges done because the remote moved.
    merges: []const MergeReport,
    /// The issues and milestones it sent, in order; `tip` null for a
    /// purged issue's delete.
    refs: []const Pushed = &.{},

    pub const Pushed = struct { namespace: Namespace, id: []const u8, tip: ?Oid };
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
        /// Histories a merge read, by tip, so each is read once per merge.
        histories: ?*Histories = null,
        /// A URL or path synced with instead of a named remote: fetch and
        /// push go there, the refs under `remoteKey`'s name.
        target: ?[]const u8 = null,

        /// Objects are immutable, so an entry never goes stale.
        const Histories = std.AutoHashMapUnmanaged([Oid.max_byte_len]u8, History);
        const History = struct {
            commits: []issue_model.CommitInput,
            ancestry: ?Ancestry = null,
        };

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
            /// A purge has to replace the remote's history and the backend
            /// can't push with a lease.
            LeasedPushUnsupported,
        };

        pub fn init(backend: *B) Self {
            return .{ .repo = R.init(backend) };
        }

        /// With the repo's limits and settings.
        pub fn fromRepo(repo: R) Self {
            return .{ .repo = repo };
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
            if (self.histories != null) return self.mergeIn(arena, remote, options);
            var histories: Histories = .empty;
            var s = self;
            s.histories = &histories;
            return s.mergeIn(arena, remote, options);
        }

        fn mergeIn(
            self_in: Self,
            arena: Allocator,
            remote_in: []const u8,
            options_in: MergeOptions,
        ) Error!MergeReport {
            const self, const remote = try self_in.at(arena, remote_in);
            var options = options_in;
            // A URL has no staging refs of the user's own fetch to read.
            if (self.target != null) options.fetch = true;
            if (options.fetch) {
                try self.ensureRemote(arena, remote);
                Progress.report(options.progress, .fetching);
                try self.fetchSeen(arena, remote);
            }
            Progress.report(options.progress, .merging);
            // Before the records are read: applying a tombstone drops
            // those of the issues it rewrote.
            const tombs = try arena.create(Tombs);
            var purged_here: std.ArrayList([]const u8) = .empty;
            tombs.* = try self.mergeTombstones(arena, remote, options, &purged_here);
            // Nothing below writes a record before the last namespace is
            // read, so one read serves all of them.
            const records = try self.readRecords(arena, remote);
            var entries: std.ArrayList(Entry) = .empty;
            var batch: Batch = .{};
            var local: std.ArrayList(LocalWrite) = .empty;
            for (namespaces) |ns| {
                const staging_prefix = try sourcePrefix(arena, remote, ns, options.fetch);
                const staged = if (options.fetch)
                    try entriesUnder(arena, records, staging_prefix)
                else
                    try self.b().listRefs(arena, staging_prefix);
                const k = try arena.create(Known);
                k.* = try self.readKnown(arena, remote, ns, records);
                k.tombs = tombs;
                for (staged) |s| {
                    const id = s.name[staging_prefix.len..];
                    // Remote-tracking branches named `issues/...` land here
                    // too. They aren't issues: leave them alone.
                    if (!uuid_fmt.isCanonical(id)) continue;
                    const pending = local.items.len;
                    var e = try self.mergeOne(arena, remote, ns, id, s, options, k, &batch, &local);
                    e.namespace = ns;
                    if (local.items.len > pending) local.items[pending].entry = entries.items.len;
                    try entries.append(arena, e);
                }
            }
            // Purged here though the remote had no copy left to compare.
            for (purged_here.items) |id| {
                const listed = for (entries.items) |e| {
                    if (e.namespace == .issues and std.mem.eql(u8, e.id, id)) break true;
                } else false;
                if (!listed) try entries.append(arena, .{
                    .namespace = .issues,
                    .id = id,
                    .title = "(purged)",
                    .outcome = .purged,
                });
            }
            if (options.check) return .{ .entries = entries.items };
            try self.applyLocal(arena, remote, options, local.items, entries.items, &batch);
            try self.apply(arena, &batch);
            return .{
                .entries = entries.items,
                .attachment_refs = try self.reconcileAttachments(arena, remote, options, records),
            };
        }

        fn reconcileAttachments(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            options: MergeOptions,
            /// From the start of the merge, which writes no attachment
            /// records.
            records: []const contract.RefEntry,
        ) Error!usize {
            const A = attachments_mod.Attachments(B);
            const att = A.fromRepo(self.repo);
            const staging_prefix = try sourcePrefix(arena, remote, .attachments, options.fetch);
            const remote_tips = if (options.fetch)
                try mapUnder(arena, records, staging_prefix)
            else
                try self.refsUnder(arena, staging_prefix);
            const local_tips = try self.refsUnder(arena, attachments_mod.ref_prefix);
            const tombs = try self.refsUnder(arena, purge_mod.ref_prefix);
            const pushed = try mapUnder(
                arena,
                records,
                try recordRef(arena, remote, .pushed, .attachments, ""),
            );
            var batch: Batch = .{};
            var moved: usize = 0;
            for (try self.repo.refs(arena)) |r| {
                const id = r.id();
                const remote_tip = remote_tips.get(id);
                const issue = self.repo.load(arena, r) catch continue;
                // Issues that never had attachments cost no git process.
                if (remote_tip == null and !local_tips.contains(id) and
                    issue.attachments.len == 0 and issue.removed_attachments.len == 0) continue;
                // Never on top of purged history: the push replaces it.
                const tomb = tombs.contains(id);
                const old_remote = tomb and remote_tip != null and
                    try att.hasOldTips(arena, remote_tip.?, issue.tip);
                const old_local = tomb and local_tips.contains(id) and
                    try att.hasOldTips(arena, local_tips.get(id).?, issue.tip);
                const moved_now = if (old_remote or old_local)
                    try att.replacePurged(
                        arena,
                        issue,
                        if (old_remote) null else remote_tip,
                        old_local,
                    )
                else
                    try att.reconcile(arena, issue, remote_tip);
                if (moved_now) moved += 1;
                const remote_derived = remote_tip orelse continue;
                const local = if (moved_now)
                    try self.b().resolveRef(try attachments_mod.refName(arena, id))
                else
                    local_tips.get(id);
                if (local != null and local.?.eql(remote_derived)) try batch.set(
                    arena,
                    try recordRef(arena, remote, .pushed, .attachments, id),
                    pushed.get(id),
                    remote_derived,
                );
            }
            try self.apply(arena, &batch);
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
            k: *const Known,
            batch: *Batch,
            /// Takes the first attempt's local ref write, for one
            /// transaction with the others; null writes it here.
            local: ?*std.ArrayList(LocalWrite),
        ) Error!Entry {
            var remote_tip = staged.oid;
            const local_name = try localRef(arena, ns, id);
            const q = Q{ .sync = self, .arena = arena, .remote = remote, .ns = ns, .id = id };
            assert(uuid_fmt.isCanonical(id));

            // Read before the fetch's results are used: if a local writer
            // moves the ref after this, the update below conflicts.
            const local_before = k.local.get(id);
            var merged_before = k.merged.get(id);
            // Purged here: the remote's copy is purged the same way before
            // it is compared, so the purged text never comes back. The
            // records keep the remote's own tips.
            if (ns == .issues) if (k.tombs.get(id)) |t| {
                if (t.issue) return .{ .id = id, .title = "(purged)", .outcome = .purged };
                if (t.comments.len > 0) {
                    remote_tip = try self.purgedTip(arena, remote_tip, t.comments);
                    if (merged_before) |m| merged_before = try self.purgedTip(arena, m, t.comments);
                }
            };
            const records: RecordWrites = .{
                .sync = self,
                .arena = arena,
                .remote = remote,
                .ns = ns,
                .id = id,
                .k = k,
                .staged = staged,
            };

            // Merged before and nothing changed since: vetted then, so only
            // the records are brought up to date.
            const unchanged = local_before != null and local_before.?.eql(remote_tip) and
                merged_before != null and merged_before.?.eql(remote_tip);
            if (unchanged) if (self.repo.load(arena, .{
                .name = local_name,
                .tip = remote_tip,
            })) |issue| {
                if (!options.check) try records.add(batch);
                return .{
                    .id = id,
                    .title = titleIn(ns, issue),
                    .outcome = .up_to_date,
                    .conflicts = if (options.check) &.{} else issue.conflicts,
                };
            } else |_| {};

            const vetted = try self.vet(arena, ns, id, local_before, remote_tip, merged_before);
            const loaded = switch (vetted) {
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

                const deferred = attempt == 0 and local != null and new_tip != null;
                if (new_tip) |t| {
                    const op: contract.RefUpdate.Op = if (local_tip) |old|
                        .{ .update = .{ .new = t, .old = old } }
                    else
                        .{ .create = t };
                    const update: contract.RefUpdate = .{ .name = local_name, .op = op };
                    if (deferred) try local.?.append(arena, .{
                        .update = update,
                        .records = records,
                        .ns = ns,
                        .id = id,
                        .staged = staged,
                    }) else self.b().updateRefs(&.{update}) catch |err| switch (err) {
                        error.RefConflict => continue, // a local writer moved it: redo
                        else => |e| return e,
                    };
                }
                if (!deferred) try records.add(batch);
                const final_tip = new_tip orelse local_tip.?;
                const final_issue = if (final_tip.eql(remote_tip))
                    loaded
                else
                    try self.repo.load(arena, .{ .name = local_name, .tip = final_tip });
                return .{
                    .id = id,
                    .title = title,
                    .outcome = outcome,
                    .conflicts = final_issue.conflicts,
                };
            }
            return error.ConcurrentModification;
        }

        /// What a merge reads once per namespace instead of per issue, by
        /// ID. Stale values are safe: every write states the old value.
        const Known = struct {
            local: std.StringHashMapUnmanaged(Oid),
            merged: std.StringHashMapUnmanaged(Oid),
            pushed: std.StringHashMapUnmanaged(Oid),
            quarantined: std.StringHashMapUnmanaged(Oid),
            tombs: *const Tombs = &empty_tombs,
        };

        /// Tombstones by issue ID.
        const Tombs = std.StringHashMapUnmanaged(purge_mod.Tombstone);
        const empty_tombs: Tombs = .empty;

        /// Merges the remote's tombstones into the local ones, like issues
        /// but without checks: a fast-forward or a "Merge purges" commit.
        /// Then applies every tombstone, so purged text that came back
        /// another way (upstream's merge, a plain fetch) goes again.
        /// Returns every tombstone, merged; with `check`, the union, and
        /// nothing is written.
        fn mergeTombstones(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            options: MergeOptions,
            /// Issues a tombstone took out of this clone just now.
            purged_here: *std.ArrayList([]const u8),
        ) Error!Tombs {
            const purger = purge_mod.Purge(B).fromRepo(self.repo);
            const local = try self.refsUnder(arena, purge_mod.ref_prefix);
            var out: Tombs = .empty;
            var it = local.iterator();
            while (it.next()) |e| {
                const t = try purge_mod.readAt(arena, self.b(), e.value_ptr.*);
                try out.put(arena, e.key_ptr.*, t);
            }
            const prefix = try sourcePrefix(arena, remote, .purged, options.fetch);
            for (try self.b().listRefs(arena, prefix)) |r| {
                const id = r.name[prefix.len..];
                if (!uuid_fmt.isCanonical(id)) continue;
                // Anyone can push anything there: only commits count.
                const o = (try self.b().readObject(arena, r.oid)) orelse continue;
                if (o.kind != .commit) continue;
                const theirs = try purge_mod.readAt(arena, self.b(), r.oid);
                const mine = local.get(id);
                if (options.check) {
                    const merged = if (out.get(id)) |t| try purge_mod.unionOf(
                        arena,
                        t,
                        theirs,
                    ) else theirs;
                    try out.put(arena, id, merged);
                    continue;
                }
                const new: Oid = if (mine) |m| blk: {
                    if (m.eql(r.oid) or try self.b().isAncestor(r.oid, m)) continue;
                    if (try self.b().isAncestor(m, r.oid)) break :blk r.oid;
                    break :blk try self.mergeTombstoneCommit(arena, m, r.oid);
                } else r.oid;
                const name = try localRef(arena, .purged, id);
                const op: contract.RefUpdate.Op = if (mine) |m|
                    .{ .update = .{ .new = new, .old = m } }
                else
                    .{ .create = new };
                self.b().updateRefs(&.{.{ .name = name, .op = op }}) catch |err| switch (err) {
                    // A purge here at the same time: the next merge.
                    error.RefConflict => continue,
                    else => |e| return e,
                };
                try out.put(arena, id, try purge_mod.readAt(arena, self.b(), new));
            }
            if (options.check) return out;
            var all = out.iterator();
            while (all.next()) |e| {
                const changed = try purger.apply(arena, e.key_ptr.*, e.value_ptr.*);
                if (changed and e.value_ptr.issue) try purged_here.append(arena, e.key_ptr.*);
            }
            return out;
        }

        /// A purged issue whose remote tip, purged, isn't in the local one.
        fn leaseWouldLose(self: Self, arena: Allocator, view: *const PushView) Error!bool {
            const seen = view.seen[@intFromEnum(Namespace.issues)];
            var it = view.tombs.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.issue or e.value_ptr.comments.len == 0) continue;
                const remote_tip = seen.get(e.key_ptr.*) orelse continue;
                const name = try localRef(arena, .issues, e.key_ptr.*);
                const local = (try self.b().resolveRef(name)) orelse continue;
                if (local.eql(remote_tip)) continue;
                const purged = try self.purgedTip(arena, remote_tip, e.value_ptr.comments);
                if (purged.eql(local) or try self.b().isAncestor(purged, local)) continue;
                return true;
            }
            return false;
        }

        /// The remote has a tombstone this clone doesn't: merge it first,
        /// or the push brings back what it purged.
        fn tombstonesBehind(self: Self, view: *const PushView) Error!bool {
            var it = view.seen[@intFromEnum(Namespace.purged)].iterator();
            while (it.next()) |e| {
                const local = view.tombs.get(e.key_ptr.*) orelse return true;
                if (local.tip.eql(e.value_ptr.*)) continue;
                if (!try self.b().isAncestor(e.value_ptr.*, local.tip)) return true;
            }
            return false;
        }

        fn applyTombstones(self: Self, arena: Allocator) Error!void {
            const purger = purge_mod.Purge(B).fromRepo(self.repo);
            for (try self.b().listRefs(arena, purge_mod.ref_prefix)) |r| {
                const t = try purge_mod.readAt(arena, self.b(), r.oid);
                _ = try purger.apply(arena, r.name[purge_mod.ref_prefix.len..], t);
            }
        }

        /// Deterministic like issue merges: parents sorted, fixed identity,
        /// dated by the later parent.
        fn mergeTombstoneCommit(self: Self, arena: Allocator, x: Oid, y: Oid) Error!Oid {
            var time: i64 = std.math.minInt(i64);
            for ([_]Oid{ x, y }) |p| {
                const o = (try self.b().readObject(arena, p)) orelse return error.CorruptIssue;
                const c = object.Commit.parse(arena, self.b().objectFormat(), o.data) catch
                    return error.CorruptIssue;
                time = @max(time, c.committer.time);
            }
            const parents = try arena.dupe(Oid, &.{ x, y });
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
                purge_merge_subject ++ "\n",
            );
        }

        /// `tip` with the purged comments' text gone. History that doesn't
        /// load is left for `vet` to refuse.
        fn purgedTip(self: Self, arena: Allocator, tip: Oid, comments: []const Oid) Error!Oid {
            const commits = self.history(arena, tip) catch |e| switch (e) {
                error.CorruptIssue, error.HistoryTooLong => return tip,
                else => |x| return x,
            };
            const r = purge_mod.rewrite(
                arena,
                self.b(),
                commits,
                tip,
                comments,
            ) catch |e| switch (e) {
                error.CorruptIssue => return tip,
                else => |x| return x,
            };
            return r.tip;
        }

        fn readKnown(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            ns: Namespace,
            records: []const contract.RefEntry,
        ) Error!Known {
            return .{
                .local = try self.refsUnder(arena, ns.refPrefix()),
                .merged = try mapUnder(
                    arena,
                    records,
                    try recordRef(arena, remote, .merged, ns, ""),
                ),
                .pushed = try mapUnder(
                    arena,
                    records,
                    try recordRef(arena, remote, .pushed, ns, ""),
                ),
                .quarantined = try mapUnder(
                    arena,
                    records,
                    try recordRef(arena, remote, .quarantined, ns, ""),
                ),
            };
        }

        /// Every ref under `refs/issuez-sync/<remote>/`, sorted, in one
        /// `for-each-ref`.
        fn readRecords(
            self: Self,
            arena: Allocator,
            remote: []const u8,
        ) Error![]const contract.RefEntry {
            return self.b().listRefs(
                arena,
                try std.fmt.allocPrint(arena, "refs/issuez-sync/{s}/", .{remote}),
            );
        }

        /// A merged issue's local ref write, held for one transaction.
        const LocalWrite = struct {
            update: contract.RefUpdate,
            records: RecordWrites,
            ns: Namespace,
            id: []const u8,
            staged: contract.RefEntry,
            /// Its place in the report.
            entry: usize = 0,
        };

        /// All local ref writes of a merge in one transaction, then their
        /// records. When one lost a race, those issues are merged again one
        /// by one.
        fn applyLocal(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            options: MergeOptions,
            writes: []const LocalWrite,
            entries: []Entry,
            batch: *Batch,
        ) Error!void {
            if (writes.len == 0) return;
            var ops: std.ArrayList(contract.RefUpdate) = .empty;
            for (writes) |w| try ops.append(arena, w.update);
            if (self.b().updateRefs(ops.items)) {
                for (writes) |w| try w.records.add(batch);
                return;
            } else |err| switch (err) {
                error.RefConflict => {},
                else => |e| return e,
            }
            for (writes) |w| {
                var e = self.mergeOne(
                    arena,
                    remote,
                    w.ns,
                    w.id,
                    w.staged,
                    options,
                    w.records.k,
                    batch,
                    null,
                ) catch |err| {
                    // The issues merged so far wrote their local refs:
                    // their records go too.
                    self.apply(arena, batch) catch {};
                    return err;
                };
                e.namespace = w.ns;
                entries[w.entry] = e;
            }
        }

        /// The records a merged issue leaves.
        const RecordWrites = struct {
            sync: Self,
            arena: Allocator,
            remote: []const u8,
            ns: Namespace,
            id: []const u8,
            k: *const Known,
            staged: contract.RefEntry,

            fn add(w: RecordWrites, batch: *Batch) Error!void {
                const a = w.arena;
                const tip = w.staged.oid;
                const merged = try recordRef(a, w.remote, .merged, w.ns, w.id);
                try batch.set(a, merged, w.k.merged.get(w.id), tip);
                // The fetched tip is what the remote has, even when it went
                // back to one we pushed earlier: push compares against this.
                const pushed = try recordRef(a, w.remote, .pushed, w.ns, w.id);
                try batch.set(a, pushed, w.k.pushed.get(w.id), tip);
                const marker = try recordRef(a, w.remote, .quarantined, w.ns, w.id);
                try batch.delete(a, marker, w.k.quarantined.get(w.id));
            }
        };

        /// Bookkeeping writes, applied in one transaction. When one lost a
        /// race, each is redone on its own against the current value.
        const Batch = struct {
            ops: std.ArrayList(contract.RefUpdate) = .empty,

            fn set(bt: *Batch, arena: Allocator, name: []const u8, old: ?Oid, new: Oid) !void {
                if (old) |o| if (o.eql(new)) return;
                try bt.ops.append(arena, .{ .name = name, .op = if (old) |o|
                    .{ .update = .{ .new = new, .old = o } }
                else
                    .{ .create = new } });
            }

            fn delete(bt: *Batch, arena: Allocator, name: []const u8, old: ?Oid) !void {
                const o = old orelse return;
                try bt.ops.append(arena, .{ .name = name, .op = .{ .delete = o } });
            }
        };

        fn apply(self: Self, arena: Allocator, batch: *const Batch) Error!void {
            if (batch.ops.items.len == 0) return;
            self.b().updateRefs(batch.ops.items) catch |err| switch (err) {
                error.RefConflict => for (batch.ops.items) |u| switch (u.op) {
                    .create => |new| try self.setRef(arena, u.name, new),
                    .update => |x| try self.setRef(arena, u.name, x.new),
                    .delete => try self.deleteRef(arena, u.name),
                    .verify => unreachable,
                },
                else => |e| return e,
            };
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
                    // The marker keeps the remote tip for inspection
                    // (`seen/` moves on with the next fetch), and push away
                    // from the issue.
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

        /// The remote no longer contains the tip merged last time. A remote
        /// reset to a tip the local issue already contains isn't rewound:
        /// nothing is lost, and the next push restores the local tip.
        fn isRewound(
            self: Self,
            arena: Allocator,
            merged_before: Oid,
            remote_tip: Oid,
            local: ?Oid,
        ) Error!bool {
            if (merged_before.eql(remote_tip)) return false;
            if (try self.isAncestor(arena, merged_before, remote_tip)) return false;
            const l = local orelse return true;
            if (l.eql(remote_tip)) return false;
            return !try self.isAncestor(arena, remote_tip, l);
        }

        /// A tip's history by OID, with each commit's parents. Null when it
        /// can't be read as an issue's: then git answers instead.
        const Ancestry = std.AutoHashMapUnmanaged([Oid.max_byte_len]u8, []const Oid);

        fn ancestry(self: Self, arena: Allocator, tip: Oid) Error!?Ancestry {
            const commits = self.history(arena, tip) catch |e| switch (e) {
                error.CorruptIssue, error.HistoryTooLong => return null,
                else => |x| return x,
            };
            const memo = if (self.histories) |h| h.getPtr(tip.bytes) else null;
            if (memo) |m| if (m.ancestry) |a| return a;
            var out: Ancestry = .empty;
            for (commits) |c| try out.put(arena, c.oid.bytes, c.parents);
            if (memo) |m| m.ancestry = out;
            return out;
        }

        /// `Repo.loadCommits`, once per tip in a merge.
        fn history(self: Self, arena: Allocator, tip: Oid) Error![]issue_model.CommitInput {
            const h = self.histories orelse return self.repo.loadCommits(arena, tip);
            if (h.get(tip.bytes)) |m| return m.commits;
            const commits = try self.repo.loadCommits(arena, tip);
            try h.put(arena, tip.bytes, .{ .commits = commits });
            return commits;
        }

        /// Issue histories are small and read through the object session,
        /// so this doesn't start a `git merge-base` per issue.
        fn isAncestor(self: Self, arena: Allocator, a: Oid, b_tip: Oid) Error!bool {
            const h = (try self.ancestry(arena, b_tip)) orelse return self.b().isAncestor(a, b_tip);
            return h.contains(a.bytes);
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
            const local_commits = try self.history(arena, local);
            const remote_commits = try self.history(arena, remote);
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

            const resolved = try issue_model.resolveMerge(
                arena,
                id,
                all.items,
                parents,
                sig,
                merge_subject ++ "\n",
            );
            var list = try issue_model.restatedTrailers(arena, resolved);
            // The remote has already given its number out, and a host keeps
            // what it gave (format.md 4). Only the other side's differs here.
            const theirs = try issue_model.materialize(arena, id, remote, remote_commits);
            if (theirs.number) |n| if (resolved.number != n) try list.append(arena, .{
                .key = "X-Number",
                .value = try std.fmt.allocPrint(arena, "{d}", .{n}),
            });
            const message = try trailers.build(arena, merge_subject, "", list.items);
            return self.repo.writeCommit(
                arena,
                parents,
                .{ .author = sig, .committer = sig },
                message,
            );
        }

        /// From local state only, no fetch.
        pub fn status(self_in: Self, arena: Allocator, remote_in: []const u8) Error!Status {
            const self, const remote = try self_in.at(arena, remote_in);
            // One read of the refs for all of it, so the parts agree.
            const view = try self.readView(arena, remote);
            var quarantined: std.ArrayList(Quarantined) = .empty;
            for (namespaces) |ns| {
                const prefix = try recordRef(arena, remote, .quarantined, ns, "");
                for (view.records) |m| {
                    if (!std.mem.startsWith(u8, m.name, prefix)) continue;
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
            const pending = try self.pendingIn(arena, &skipped, &view);
            var issues: std.ArrayList(repo_mod.IssueRef) = .empty;
            for (pending) |p| {
                if (p.ns == .issues) if (p.tip) |t| try issues.append(
                    arena,
                    .{ .name = p.name, .tip = t },
                );
            }
            return .{
                .quarantined = quarantined.items,
                .pending = issues.items,
                .unpushed = try unpushedIn(arena, pending),
            };
        }

        /// Issues and milestones not pushed to `remote` yet, quarantined
        /// ones excluded. Local refs only.
        pub fn unpushed(self: Self, arena: Allocator, remote: []const u8) Error![]const Unpushed {
            if (!contract.isValidRemoteName(remote)) return error.InvalidRemoteName;
            const view = try self.readView(arena, remote);
            var skipped: std.ArrayList([]const u8) = .empty;
            return unpushedIn(arena, try self.pendingIn(arena, &skipped, &view));
        }

        fn unpushedIn(arena: Allocator, pending: []const Pending) Error![]const Unpushed {
            var out: std.ArrayList(Unpushed) = .empty;
            for (pending) |p| {
                if (p.ns == .attachments) continue;
                try out.append(
                    arena,
                    .{ .namespace = p.ns, .id = p.id, .tip = p.tip, .new = p.record == null },
                );
            }
            return out.items;
        }

        /// How much is unpushed and quarantined, without loading any
        /// issue: for a badge after every reload.
        pub fn counts(self: Self, arena: Allocator, remote: []const u8) Error!Counts {
            if (!contract.isValidRemoteName(remote)) return error.InvalidRemoteName;
            const view = try self.readView(arena, remote);
            var skipped: std.ArrayList([]const u8) = .empty;
            var quarantined: usize = 0;
            for (namespaces) |ns| {
                // Kept local (`resolve(.keep_local)`) for this remote tip:
                // answered, as `status` and the CLI have it.
                const kept = try mapUnder(
                    arena,
                    view.records,
                    try recordRef(arena, remote, .kept, ns, ""),
                );
                var it = view.quarantined[@intFromEnum(ns)].iterator();
                while (it.next()) |e| {
                    if (kept.get(e.key_ptr.*)) |k| if (k.eql(e.value_ptr.*)) continue;
                    quarantined += 1;
                }
            }
            return .{
                .unpushed = (try unpushedIn(arena, try self.pendingIn(arena, &skipped, &view))).len,
                .quarantined = quarantined,
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
            const merged = try self.b().resolveRef(try recordRef(arena, remote, .merged, ns, id));
            switch (try self.vet(arena, ns, id, local, remote_tip, merged)) {
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
            ns: Namespace,
            id: []const u8,
            local: ?Oid,
            remote_tip: Oid,
            /// The `merged` record.
            merged: ?Oid,
        ) Error!Vetted {
            const as_issue: repo_mod.IssueRef = .{
                .name = try localRef(arena, ns, id),
                .tip = remote_tip,
            };
            const invalid: Vetted = .{ .refused = .{ .reason = .invalid_issue, .title = "?" } };
            // Loaded once, for both the issue and the checks.
            const commits = self.history(arena, remote_tip) catch |e| switch (e) {
                error.CorruptIssue, error.HistoryTooLong => return invalid,
                else => |x| return x,
            };
            const loaded = try issue_model.materialize(arena, id, remote_tip, commits);
            const check: R.CheckOptions = .{ .root_keys = rootKeys(ns) };
            if ((try self.repo.checkCommits(arena, as_issue, commits, check)).len > 0)
                return invalid;
            if (merged) |before| {
                if (try self.isRewound(arena, before, remote_tip, local)) {
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
            const rh = (try self.ancestry(arena, remote_tip)) orelse return self.relateByGit(
                arena,
                l,
                remote_tip,
            );
            if (rh.contains(l.bytes)) return .behind;
            const lh = (try self.ancestry(arena, l)) orelse return self.relateByGit(
                arena,
                l,
                remote_tip,
            );
            if (lh.contains(remote_tip.bytes)) return .ahead;
            // The common history is closed under parents, so its maximal
            // commits, the merge bases, are those with no child in it.
            var has_child: std.AutoHashMapUnmanaged([Oid.max_byte_len]u8, void) = .empty;
            var it = lh.iterator();
            while (it.next()) |e| if (rh.contains(e.key_ptr.*)) for (e.value_ptr.*) |p| {
                try has_child.put(arena, p.bytes, {});
            };
            var base: ?Oid = null;
            it = lh.iterator();
            while (it.next()) |e| {
                if (!rh.contains(e.key_ptr.*) or has_child.contains(e.key_ptr.*)) continue;
                const oid: Oid = .{ .object_format = l.object_format, .bytes = e.key_ptr.* };
                // Like `mergeBases`, sorted: the smallest.
                if (base == null or oid.order(base.?) == .lt) base = oid;
            }
            return if (base) |x| .{ .diverged = x } else .unrelated;
        }

        fn relateByGit(self: Self, arena: Allocator, l: Oid, remote_tip: Oid) Error!Relation {
            if (try self.b().isAncestor(l, remote_tip)) return .behind;
            if (try self.b().isAncestor(remote_tip, l)) return .ahead;
            const bases = try self.b().mergeBases(arena, l, remote_tip);
            return if (bases.len == 0) .unrelated else .{ .diverged = bases[0] };
        }

        /// Never force-pushes, and never drops a local version without
        /// keeping it in a ref. Returns the local tip that `accept_remote`
        /// replaced, kept under `replacedRef`.
        pub fn resolve(
            self_in: Self,
            arena: Allocator,
            remote_in: []const u8,
            id: []const u8,
            how: Resolution,
        ) Error!?Oid {
            const self, const remote = try self_in.at(arena, remote_in);
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

        /// `merge`, then `push`: what `git issue sync` does.
        pub fn sync(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            options: PushOptions,
        ) Error!SyncReport {
            const merged = try self.merge(arena, remote, .{ .progress = options.progress });
            var after_merge = options;
            after_merge.fetch = false;
            return .{ .merge = merged, .push = try self.push(arena, remote, after_merge) };
        }

        pub fn push(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            options: PushOptions,
        ) Error!PushReport {
            return self.pushIn(arena, remote, options, options.fetch);
        }

        fn pushIn(
            self_in: Self,
            arena: Allocator,
            remote_in: []const u8,
            options: PushOptions,
            fetch: bool,
        ) Error!PushReport {
            const self, const remote = try self_in.at(arena, remote_in);
            if (fetch) try self.ensureRemote(arena, remote);
            // Never push purged text, even when it came back another way.
            try self.applyTombstones(arena);
            Progress.report(options.progress, if (fetch) .fetching else .pushing);
            var view = try self.refreshPushed(arena, remote, fetch);
            if (fetch) Progress.report(options.progress, .pushing);
            // Pushed issues should carry their pointers. Issues that came in
            // through upstream have no derived ref yet.
            const att = attachments_mod.Attachments(B).fromRepo(self.repo);
            const local_tips = try mapUnder(
                arena,
                view.local(.attachments),
                attachments_mod.ref_prefix,
            );
            var moved = false;
            for (view.local(.issues)) |e| {
                const issue = self.repo.load(
                    arena,
                    .{ .name = e.name, .tip = e.oid },
                ) catch continue;
                if (!local_tips.contains(e.name[Namespace.issues.refPrefix().len..]) and
                    issue.attachments.len == 0 and issue.removed_attachments.len == 0) continue;
                if (try att.reconcile(arena, issue, null)) moved = true;
            }
            if (moved) view.locals[@intFromEnum(Namespace.attachments)] =
                try self.b().listRefs(arena, Namespace.attachments.refPrefix());
            var report: PushReport = .{
                .pushed = 0,
                .up_to_date = 0,
                .skipped_quarantined = 0,
                .merges = &.{},
            };
            var merges: std.ArrayList(MergeReport) = .empty;
            var skipped: std.ArrayList([]const u8) = .empty;
            var uploaded: std.StringHashMapUnmanaged(void) = .empty;
            // A lease replaces the remote's history: first merge what it
            // has that we don't, or the replace would drop it.
            if (try self.leaseWouldLose(arena, &view) or try self.tombstonesBehind(&view)) {
                try merges.append(arena, try self.merge(arena, remote, .{}));
                view = try self.readView(arena, remote);
            }

            var sent: std.ArrayList(PushReport.Pushed) = .empty;
            var round: usize = 0;
            while (round < push_rounds) : (round += 1) {
                skipped.clearRetainingCapacity();
                const todo = try self.purgeQuarantined(
                    arena,
                    try self.pendingIn(arena, &skipped, &view),
                    &view,
                );
                report.skipped_quarantined = skipped.items.len;
                if (todo.len == 0) {
                    report.merges = merges.items;
                    report.refs = sent.items;
                    report.skipped = skipped.items;
                    return report;
                }
                // All bytes before any ref, so a failed upload pushes
                // nothing.
                try self.uploadPending(arena, remote, todo, options, &report, &uploaded);
                var rejected = false;
                var start: usize = 0;
                while (start < todo.len) {
                    // An issue, its derived ref and its tombstone go in the
                    // same push.
                    var end = @min(start + push_chunk, todo.len);
                    while (end < todo.len and todo[end].group == todo[end - 1].group) end += 1;
                    const chunk = todo[start..end];
                    start = end;
                    const result = try self.pushChunk(arena, remote, chunk, &view);
                    var batch: Batch = .{};
                    for (result.refs) |p| {
                        if (p.status == .rejected) {
                            rejected = true;
                            continue;
                        }
                        const pushed = findPending(chunk, p.name) orelse continue;
                        const ok = p.status == .ok;
                        switch (pushed.ns) {
                            .attachments => {
                                if (ok) report.attachment_refs += 1;
                            },
                            .purged => {
                                if (ok) report.tombstones += 1;
                            },
                            .issues, .milestones => if (ok) {
                                report.pushed += 1;
                                if (pushed.tip == null) report.deleted += 1;
                                try sent.append(arena, .{
                                    .namespace = pushed.ns,
                                    .id = pushed.id,
                                    .tip = pushed.tip,
                                });
                            } else {
                                report.up_to_date += 1;
                            },
                        }
                        const record = try recordRef(arena, remote, .pushed, pushed.ns, pushed.id);
                        if (pushed.tip) |t|
                            try batch.set(arena, record, pushed.record, t)
                        else
                            try batch.delete(arena, record, pushed.record);
                    }
                    try self.apply(arena, &batch);
                    if (rejected) break;
                }
                if (!rejected) {
                    report.merges = merges.items;
                    report.refs = sent.items;
                    report.skipped = skipped.items;
                    return report;
                }
                // The remote has changes we don't. Merge, then retry.
                try merges.append(arena, try self.merge(arena, remote, .{}));
                view = try self.readView(arena, remote);
            }
            return error.PushRoundsExhausted;
        }

        /// What a push reads, one `for-each-ref` each: the local refs and
        /// the remote's records.
        const PushView = struct {
            locals: [fetched_namespaces.len][]const contract.RefEntry,
            pushed: [fetched_namespaces.len]std.StringHashMapUnmanaged(Oid),
            quarantined: [fetched_namespaces.len]std.StringHashMapUnmanaged(Oid),
            /// The remote's refs as last fetched: what a lease expects.
            seen: [fetched_namespaces.len]std.StringHashMapUnmanaged(Oid),
            /// The local tombstones.
            tombs: Tombs,
            records: []const contract.RefEntry,

            fn local(v: *const PushView, ns: Namespace) []const contract.RefEntry {
                return v.locals[@intFromEnum(ns)];
            }
        };

        fn readView(self: Self, arena: Allocator, remote: []const u8) Error!PushView {
            const records = try self.readRecords(arena, remote);
            var v: PushView = .{
                .locals = undefined,
                .pushed = undefined,
                .quarantined = undefined,
                .seen = undefined,
                .tombs = .empty,
                .records = records,
            };
            for (fetched_namespaces) |ns| {
                const i = @intFromEnum(ns);
                v.locals[i] = try self.b().listRefs(arena, ns.refPrefix());
                v.seen[i] = try mapUnder(
                    arena,
                    records,
                    try recordRef(arena, remote, .seen, ns, ""),
                );
                v.pushed[i] = try mapUnder(
                    arena,
                    records,
                    try recordRef(arena, remote, .pushed, ns, ""),
                );
                v.quarantined[i] = try mapUnder(
                    arena,
                    records,
                    try recordRef(arena, remote, .quarantined, ns, ""),
                );
            }
            for (v.local(.purged)) |r| try v.tombs.put(
                arena,
                r.name[Namespace.purged.refPrefix().len..],
                try purge_mod.readAt(arena, self.b(), r.oid),
            );
            return v;
        }

        /// Sets the `pushed` records to what the remote has now. They go
        /// stale when someone else force-pushes or deletes a ref, and push
        /// only sends what differs from them.
        /// `fetch` false: `seen/` is current, a merge just fetched it.
        fn refreshPushed(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            fetch: bool,
        ) Error!PushView {
            if (fetch) try self.fetchSeen(arena, remote);
            var view = try self.readView(arena, remote);
            // One transaction for all records, not a git call per issue.
            var ops: std.ArrayList(contract.RefUpdate) = .empty;
            const Change = struct { ns: Namespace, id: []const u8, new: ?Oid };
            var changes: std.ArrayList(Change) = .empty;
            for (fetched_namespaces) |ns| {
                const remote_tips = try mapUnder(
                    arena,
                    view.records,
                    try recordRef(arena, remote, .seen, ns, ""),
                );
                const pushed_prefix = try recordRef(arena, remote, .pushed, ns, "");
                const pushed = &view.pushed[@intFromEnum(ns)];
                for (view.local(ns)) |r| {
                    const id = r.name[ns.refPrefix().len..];
                    const name = try std.mem.concat(arena, u8, &.{ pushed_prefix, id });
                    const old = pushed.get(id);
                    const new = remote_tips.get(id);
                    const op: ?contract.RefUpdate.Op = if (new) |n|
                        (if (old) |o|
                            (if (o.eql(n)) null else .{ .update = .{ .new = n, .old = o } })
                        else
                            .{ .create = n })
                    else if (old) |o| .{ .delete = o } else null;
                    const o = op orelse continue;
                    try ops.append(arena, .{ .name = name, .op = o });
                    try changes.append(arena, .{ .ns = ns, .id = id, .new = new });
                }
            }
            if (ops.items.len == 0) return view;
            self.b().updateRefs(ops.items) catch |err| switch (err) {
                error.RefConflict => return error.ConcurrentModification,
                else => |e| return e,
            };
            for (changes.items) |c| {
                const pushed = &view.pushed[@intFromEnum(c.ns)];
                if (c.new) |n| try pushed.put(arena, c.id, n) else _ = pushed.remove(c.id);
            }
            return view;
        }

        /// Brings `seen/` in line with the remote: refs it no longer has
        /// go, and only changed refs are written.
        fn fetchSeen(self: Self, arena: Allocator, remote: []const u8) Error!void {
            var specs: [fetched_namespaces.len][]const u8 = undefined;
            for (fetched_namespaces, &specs) |ns, *spec| spec.* = try std.fmt.allocPrint(
                arena,
                "+{s}*:{s}*",
                .{ ns.refPrefix(), try recordRef(arena, remote, .seen, ns, "") },
            );
            try self.b().fetch(arena, self.where(remote), &specs, .{ .prune = true });
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

        const Pending = struct {
            name: []const u8,
            /// Null deletes the remote's ref: a purged issue's.
            tip: ?Oid,
            ns: Namespace,
            id: []const u8,
            /// The `pushed` record when it was read.
            record: ?Oid,
            /// Refs that go in one atomic push share it.
            group: usize = 0,
            /// A purge: replace or delete the remote's ref, leased on what
            /// it was at the fetch.
            leased: bool = false,
            /// Pushed in place of the local ref: an object ID in hex.
            src: ?[]const u8 = null,
        };

        /// One atomic push. With a lease in it, every ref is leased on the
        /// fetched value, so only a remote that didn't move is replaced.
        fn pushChunk(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            chunk: []const Pending,
            view: *const PushView,
        ) Error!contract.PushResult {
            // Only a purge's refs are leased: the rest stay fast-forwards,
            // or a lease would replace what the remote has and we don't.
            var specs: std.ArrayList([]const u8) = .empty;
            var updates: std.ArrayList(contract.LeasedRef) = .empty;
            for (chunk) |p| if (p.leased) try updates.append(arena, .{
                .src = if (p.tip != null) p.src orelse p.name else null,
                .dst = p.name,
                .expect = view.seen[@intFromEnum(p.ns)].get(p.id),
            }) else try specs.append(
                arena,
                try std.fmt.allocPrint(arena, "{s}:{s}", .{ p.name, p.name }),
            );
            var refs: std.ArrayList(contract.PushedRef) = .empty;
            if (specs.items.len > 0) {
                const r = try self.b().push(
                    arena,
                    self.where(remote),
                    specs.items,
                    .{ .atomic = true },
                );
                try refs.appendSlice(arena, r.refs);
            }
            if (updates.items.len > 0) {
                if (comptime !contract.hasLeasedPush(B)) return error.LeasedPushUnsupported;
                const r = try self.b().pushLeased(arena, self.where(remote), updates.items);
                try refs.appendSlice(arena, r.refs);
            }
            return .{ .refs = refs.items };
        }

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
                const known = if (p.record) |t|
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
            const ups = try att.uploads(arena, wanted.items);
            if (ups.len == 0) return;
            if (options.before_push) |hook| {
                hook.run(hook.context, self.where(remote), ups) catch return error.BeforePushFailed;
            } else {
                if (comptime !contract.hasLfsTransport(B)) return error.LfsUnavailable;
                var shas: std.ArrayList([]const u8) = .empty;
                for (ups) |u| try shas.append(arena, u.sha256);
                self.b().lfsPush(arena, self.where(remote), shas.items) catch |e| switch (e) {
                    error.LfsUnavailable => return error.LfsUnavailable,
                    error.LfsTransferFailed => return error.LfsUploadFailed,
                    else => |x| return x,
                };
            }
            for (ups) |u| try uploaded.put(arena, u.sha256, {});
            report.lfs_uploaded += ups.len;
        }

        /// A quarantined issue isn't pushed, but the remote's copy of it
        /// still loses the text our tombstone purged: its tip, purged,
        /// goes with the tombstone, leased on the fetched tip.
        fn purgeQuarantined(
            self: Self,
            arena: Allocator,
            todo: []Pending,
            view: *const PushView,
        ) Error![]Pending {
            var out: std.ArrayList(Pending) = .fromOwnedSlice(todo);
            var group: usize = 0;
            for (todo) |p| group = @max(group, p.group);
            var it = view.quarantined[@intFromEnum(Namespace.issues)].keyIterator();
            while (it.next()) |key| {
                const id = key.*;
                const t = view.tombs.get(id) orelse continue;
                if (t.issue or t.comments.len == 0) continue;
                const remote_tip = view.seen[@intFromEnum(Namespace.issues)].get(id) orelse
                    continue;
                const purged = try self.purgedTip(arena, remote_tip, t.comments);
                if (purged.eql(remote_tip)) continue;
                const hex = purged.hex();
                var index = out.items.len;
                var g = group + 1;
                for (out.items, 0..) |p, i| if (p.ns == .purged and std.mem.eql(u8, p.id, id)) {
                    index = i + 1;
                    g = p.group;
                    break;
                };
                if (g > group) group = g;
                try out.insert(arena, index, .{
                    .name = try localRef(arena, .issues, id),
                    .tip = purged,
                    .ns = .issues,
                    .id = id,
                    .record = view.pushed[@intFromEnum(Namespace.issues)].get(id),
                    .group = g,
                    .leased = true,
                    .src = try arena.dupe(u8, hex.slice()),
                });
            }
            return out.items;
        }

        /// What the remote doesn't have yet, by our records. Each issue
        /// comes with its derived ref and tombstone; the tombstone of a
        /// purged issue with the deletes of its remote copies.
        fn pendingIn(
            self: Self,
            arena: Allocator,
            skipped: *std.ArrayList([]const u8),
            view: *const PushView,
        ) Error![]Pending {
            _ = self;
            const Extra = std.StringArrayHashMapUnmanaged(Pending);
            // Derived refs and tombstones that differ from the records.
            var extras: [2]Extra = .{ .empty, .empty };
            const issue_markers = view.quarantined[@intFromEnum(Namespace.issues)];
            for ([_]Namespace{ .attachments, .purged }, &extras) |ns, *extra| {
                const records = view.pushed[@intFromEnum(ns)];
                for (view.local(ns)) |r| {
                    const id = r.name[ns.refPrefix().len..];
                    if (ns == .attachments and issue_markers.contains(id)) continue;
                    const pushed = records.get(id);
                    if (pushed != null and pushed.?.eql(r.oid)) continue;
                    try extra.put(arena, id, .{
                        .name = r.name,
                        .tip = r.oid,
                        .ns = ns,
                        .id = id,
                        .record = pushed,
                        .leased = ns == .purged,
                    });
                }
            }
            var out: std.ArrayList(Pending) = .empty;
            var group: usize = 0;
            for (namespaces) |ns| {
                const markers = view.quarantined[@intFromEnum(ns)];
                const records = view.pushed[@intFromEnum(ns)];
                for (view.local(ns)) |r| {
                    const id = r.name[ns.refPrefix().len..];
                    if (markers.contains(id)) {
                        try skipped.append(arena, id);
                        continue;
                    }
                    const pushed = records.get(id);
                    if (pushed != null and pushed.?.eql(r.oid)) continue;
                    // A rewrite replaces the remote's history.
                    const purged = ns == .issues and view.tombs.contains(id);
                    group += 1;
                    try out.append(arena, .{
                        .name = r.name,
                        .tip = r.oid,
                        .ns = ns,
                        .id = id,
                        .record = pushed,
                        .group = group,
                        .leased = purged,
                    });
                    if (ns != .issues) continue;
                    for (&extras) |*extra| if (extra.fetchSwapRemove(id)) |d| {
                        var x = d.value;
                        x.group = group;
                        x.leased = x.leased or purged;
                        try out.append(arena, x);
                    };
                }
            }
            // Purged issues: delete the remote's copies.
            var it = view.tombs.iterator();
            while (it.next()) |e| {
                if (!e.value_ptr.issue) continue;
                const id = e.key_ptr.*;
                const before = out.items.len;
                for ([_]Namespace{ .issues, .attachments }) |ns| {
                    if (view.seen[@intFromEnum(ns)].get(id) == null) continue;
                    if (before == out.items.len) group += 1;
                    try out.append(arena, .{
                        .name = try localRef(arena, ns, id),
                        .tip = null,
                        .ns = ns,
                        .id = id,
                        .record = view.pushed[@intFromEnum(ns)].get(id),
                        .group = group,
                        .leased = true,
                    });
                }
                if (out.items.len == before) continue;
                for (&extras) |*extra| if (extra.fetchSwapRemove(id)) |d| {
                    var x = d.value;
                    x.group = group;
                    try out.append(arena, x);
                };
            }
            for (&extras) |*extra| for (extra.values()) |d| {
                group += 1;
                var x = d;
                x.group = group;
                // A derived ref rebuilt by a purge isn't a fast-forward.
                x.leased = x.leased or view.tombs.contains(x.id);
                try out.append(arena, x);
            };
            return out.items;
        }

        fn pendingRefs(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            skipped: *std.ArrayList([]const u8),
        ) Error![]repo_mod.IssueRef {
            const view = try self.readView(arena, remote);
            var out: std.ArrayList(repo_mod.IssueRef) = .empty;
            for (try self.pendingIn(arena, skipped, &view)) |p| {
                if (p.ns == .issues) if (p.tip) |t| try out.append(
                    arena,
                    .{ .name = p.name, .tip = t },
                );
            }
            return out.items;
        }

        /// The sync for `remote` and the name its refs go under: the
        /// remote's own, or for a URL or path `remoteKey`'s. Idempotent,
        /// so entry points that call each other may each call it.
        fn at(self: Self, arena: Allocator, remote: []const u8) Error!struct { Self, []const u8 } {
            if (self.target != null or contract.isValidRemoteName(remote)) return .{ self, remote };
            if (!contract.isRemoteUrl(remote)) return error.InvalidRemoteName;
            var me = self;
            me.target = remote;
            return .{ me, try remoteKey(arena, remote) };
        }

        /// Where fetch and push go.
        fn where(self: Self, remote: []const u8) []const u8 {
            return self.target orelse remote;
        }

        fn ensureRemote(self: Self, arena: Allocator, remote: []const u8) Error!void {
            if (self.target != null) return;
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

/// The entries of a sorted list under `prefix`, as `listRefs` gives them.
fn entriesUnder(
    arena: Allocator,
    entries: []const contract.RefEntry,
    prefix: []const u8,
) Allocator.Error![]const contract.RefEntry {
    var out: std.ArrayList(contract.RefEntry) = .empty;
    for (entries) |e| if (std.mem.startsWith(u8, e.name, prefix)) try out.append(arena, e);
    return out.items;
}

/// Like `refsUnder`, from entries already read.
fn mapUnder(
    arena: Allocator,
    entries: []const contract.RefEntry,
    prefix: []const u8,
) Allocator.Error!std.StringHashMapUnmanaged(Oid) {
    var map: std.StringHashMapUnmanaged(Oid) = .empty;
    for (entries) |e| if (std.mem.startsWith(u8, e.name, prefix)) {
        try map.put(arena, e.name[prefix.len..], e.oid);
    };
    return map;
}

fn findPending(list: anytype, name: []const u8) ?@TypeOf(list[0]) {
    for (list) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

/// Where merge reads the remote's refs: `seen/` after its own fetch,
/// otherwise the staging refs of the user's fetch,
/// `refs/remotes/<remote>/<ns>/`.
fn sourcePrefix(
    arena: Allocator,
    remote: []const u8,
    ns: Namespace,
    fetched: bool,
) Allocator.Error![]const u8 {
    if (fetched) return recordRef(arena, remote, .seen, ns, "");
    return std.fmt.allocPrint(arena, "refs/remotes/{s}/{t}/", .{ remote, ns });
}

fn titleIn(ns: Namespace, loaded: issue_model.Issue) []const u8 {
    return if (ns == .milestones) loaded.field("Name") orelse "?" else loaded.title;
}

fn rootKeys(ns: Namespace) []const []const u8 {
    return switch (ns) {
        .issues => &.{ "State", "Format-Version" },
        .milestones => &.{ "Name", "Format-Version" },
        .attachments, .purged => &.{},
    };
}

/// The name a URL or path's refs go under, in place of a remote's:
/// `url-` and the first 16 hex digits of its SHA-256.
pub fn remoteKey(arena: Allocator, url: []const u8) Allocator.Error![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
    return std.fmt.allocPrint(arena, "url-{x}", .{digest[0..8]});
}

pub const remote_key = "issue.remote";

/// The remote to sync with when none is named: the one `git config
/// issue.remote` names, else the only one, else `origin`, else the first
/// by name. Null without remotes. `UnknownIssueRemote` when
/// `issue.remote` names no remote: a typo shouldn't send issues elsewhere.
pub fn defaultRemote(
    comptime B: type,
    arena: Allocator,
    backend: *B,
) (B.Error || error{UnknownIssueRemote})!?[]const u8 {
    const names = try backend.remoteNames(arena);
    return chooseRemote(names, try backend.configGet(arena, remote_key));
}

/// `defaultRemote` for remotes already read: `names`, and `configured`,
/// the value of `issue.remote` (null when unset). The result is one of
/// `names`.
pub fn chooseRemote(
    names: []const []const u8,
    configured: ?[]const u8,
) error{UnknownIssueRemote}!?[]const u8 {
    if (configured) |want| {
        if (!contract.isValidRemoteName(want)) return error.UnknownIssueRemote;
        for (names) |n| if (std.mem.eql(u8, n, want)) return n;
        return error.UnknownIssueRemote;
    }
    if (names.len == 0) return null;
    if (names.len == 1) return names[0];
    for (names) |n| if (std.mem.eql(u8, n, "origin")) return n;
    var first = names[0];
    for (names[1..]) |n| if (std.mem.lessThan(u8, n, first)) {
        first = n;
    };
    return first;
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
    return std.fmt.allocPrint(
        arena,
        "refs/issuez-sync/{s}/{t}/{t}/{s}",
        .{ remote, record, ns, id },
    );
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
    const created = try a.sync.repo.create(arena, .{ .title = "Shared", .labels = &.{"bug"} }, .{});
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    const pushed = try a.sync.push(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), pushed.pushed);
    try a.sim.commit();

    var bob = try onClone(arena, &world, 1);
    const m1 = try bob.sync.merge(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), m1.count(.created));
    try bob.sim.commit();

    a = try onClone(arena, &world, 0);
    _ = try a.sync.repo.edit(
        arena,
        ref_name,
        .{ .priority = .{ .set = .high }, .add_labels = &.{"ui"} },
        .{},
    );
    try a.sim.commit();
    bob = try onClone(arena, &world, 1);
    _ = try bob.sync.repo.edit(
        arena,
        ref_name,
        .{ .set_assignees = &.{.byEmail("bob@e.x")}, .remove_labels = &.{"bug"} },
        .{},
    );
    _ = try bob.sync.push(arena, "origin", .{});
    try bob.sim.commit();

    // Alice's push is rejected, so she merges and retries.
    a = try onClone(arena, &world, 0);
    const p2 = try a.sync.push(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), p2.merges.len);
    try testing.expectEqual(@as(usize, 1), p2.merges[0].count(.merged));
    try testing.expectEqual(@as(usize, 1), p2.pushed);
    const merged_issue = try a.sync.repo.load(
        arena,
        (try a.sync.repo.resolve(arena, uuid_fmt.shortId(created.id))).one,
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
    const p3 = try bob.sync.push(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 0), p3.pushed);
    try testing.expectEqual(@as(usize, 0), (try bob.sim.listRefs(arena, "refs/remotes/")).len);
    try bob.sim.commit();
}

test "purges sync: tombstones travel, remote copies are replaced and deleted" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();
    const P = purge_mod.Purge(GitSim);

    var a = try onClone(arena, &world, 0);
    const keep = try a.sync.repo.create(arena, .{ .title = "Keep" }, .{});
    const keep_ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{keep.id});
    const bad = try a.sync.repo.comment(arena, keep_ref, .{ .text = "Abuse" }, .{});
    _ = try a.sync.repo.comment(arena, keep_ref, .{ .text = "Fine" }, .{});
    const gone = try a.sync.repo.create(arena, .{ .title = "Doxxing" }, .{});
    const gone_ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{gone.id});
    _ = try a.sync.push(arena, "origin", .{});
    try a.sim.commit();

    var bob = try onClone(arena, &world, 1);
    _ = try bob.sync.merge(arena, "origin", .{});
    // Bob writes on the issue before he hears of the purge.
    _ = try bob.sync.repo.comment(arena, keep_ref, .{ .text = "Bob's" }, .{});
    try bob.sim.commit();

    a = try onClone(arena, &world, 0);
    const purger = P.fromRepo(a.sync.repo);
    const r = try purger.comment(arena, keep_ref, bad.tip, .{ .reason = "abuse" }, .{});
    _ = try purger.issue(arena, gone_ref, .{}, .{});
    const p1 = try a.sync.sync(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), p1.push.deleted);
    try testing.expectEqual(@as(usize, 2), p1.push.tombstones);
    try a.sim.commit();

    // The hub has the rewritten issue, not the old one.
    var hub = try GitSim.init(arena, &world, 2);
    try testing.expect((try hub.resolveRef(keep_ref)).?.eql(r.tip.?));
    try testing.expect(try hub.resolveRef(gone_ref) == null);

    // Bob's sync purges his copy, keeps his comment and pushes it.
    bob = try onClone(arena, &world, 1);
    const p2 = try bob.sync.sync(arena, "origin", .{});
    // His comment now sits on the purged history.
    try testing.expectEqual(@as(usize, 1), p2.merge.count(.local_ahead));
    try testing.expectEqual(@as(usize, 1), p2.push.pushed);
    try testing.expect(try bob.sim.resolveRef(gone_ref) == null);
    const tip_b = (try bob.sim.resolveRef(keep_ref)).?;
    const issue_b = try bob.sync.repo.load(arena, .{ .name = keep_ref, .tip = tip_b });
    for (try bob.sync.repo.loadCommits(arena, tip_b)) |c|
        try testing.expect(std.mem.find(u8, c.message, "Abuse") == null);
    try testing.expect(issue_b.comments[0].purged);
    try testing.expectEqualStrings("Bob's", issue_b.comments[issue_b.comments.len - 1].subject);
    try bob.sim.commit();

    // And Alice gets Bob's comment back without the purged text.
    a = try onClone(arena, &world, 0);
    _ = try a.sync.sync(arena, "origin", .{});
    try testing.expect((try a.sim.resolveRef(keep_ref)).?.eql(tip_b));
    try a.sim.commit();
    hub = try GitSim.init(arena, &world, 2);
    try testing.expect((try hub.resolveRef(keep_ref)).?.eql(tip_b));
}

test "a quarantined issue's remote copy loses the purged text too" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();

    var a = try onClone(arena, &world, 0);
    const created = try a.sync.repo.create(arena, .{ .title = "Shared" }, .{});
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    const bad = try a.sync.repo.comment(arena, ref_name, .{ .text = "Abuse" }, .{});
    _ = try a.sync.repo.comment(arena, ref_name, .{ .text = "Fine" }, .{});
    _ = try a.sync.sync(arena, "origin", .{});
    try a.sim.commit();

    // Someone writes a broken merge (two roots) on the abusive comment
    // straight to the hub, so Alice's merge quarantines it.
    var hub = try GitSim.init(arena, &world, 2);
    const stray = try foreignRoot(arena, &hub, "Stray");
    const sig: object.Signature = .{
        .name = "Mallory",
        .email = "mallory@e.x",
        .time = 1_700_000_000,
        .tz_offset_minutes = 0,
    };
    const rewritten: object.Commit = .{
        .tree = object.emptyTree(.sha1),
        .parents = &.{ bad.tip, stray },
        .author = sig,
        .committer = sig,
        .message = "Rewritten\n",
    };
    const hub_tip = (try hub.resolveRef(ref_name)).?;
    const forced = try hub.writeObject(.commit, try rewritten.serializeAlloc(arena));
    try hub.updateRefs(&.{.{
        .name = ref_name,
        .op = .{ .update = .{ .new = forced, .old = hub_tip } },
    }});
    try hub.commit();

    // Alice purges the comment. The hub's history stays quarantined, but
    // its copy goes out purged with the tombstone.
    a = try onClone(arena, &world, 0);
    _ = try purge_mod.Purge(GitSim).fromRepo(a.sync.repo).comment(
        arena,
        ref_name,
        bad.tip,
        .{ .reason = "abuse" },
        .{},
    );
    const pushed = try a.sync.push(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), pushed.skipped_quarantined);
    try testing.expectEqual(@as(usize, 1), pushed.tombstones);
    try a.sim.commit();
    const h = try onClone(arena, &world, 2);
    const now = (try h.sim.resolveRef(ref_name)).?;
    try testing.expect(!now.eql(forced));
    for (try h.sync.repo.loadCommits(arena, now)) |c|
        try testing.expect(std.mem.find(u8, c.message, "Abuse") == null);
}

test "a purge's leased push replaces nothing else" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();

    var a = try onClone(arena, &world, 0);
    const gone = try a.sync.repo.create(arena, .{ .title = "Doxxing" }, .{});
    const gone_ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{gone.id});
    const other = try a.sync.repo.create(arena, .{ .title = "Other" }, .{});
    const other_ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{other.id});
    _ = try a.sync.push(arena, "origin", .{});
    try a.sim.commit();

    var bob = try onClone(arena, &world, 1);
    _ = try bob.sync.merge(arena, "origin", .{});
    const bobs = try bob.sync.repo.comment(arena, other_ref, .{ .text = "Bob's" }, .{});
    _ = try bob.sync.push(arena, "origin", .{});
    try bob.sim.commit();

    // Alice comments on the other issue too, purges one, and pushes
    // without merging first: the purge goes out leased, the other issue
    // only as a fast-forward, so Bob's comment stays.
    a = try onClone(arena, &world, 0);
    _ = try a.sync.repo.comment(arena, other_ref, .{ .text = "Alice's" }, .{});
    _ = try purge_mod.Purge(GitSim).fromRepo(a.sync.repo).issue(arena, gone_ref, .{}, .{});
    const pushed = try a.sync.push(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), pushed.deleted);
    try a.sim.commit();
    var hub = try GitSim.init(arena, &world, 2);
    try testing.expect(try hub.resolveRef(gone_ref) == null);
    const hub_tip = (try hub.resolveRef(other_ref)).?;
    try testing.expect(try hub.isAncestor(bobs.tip, hub_tip));
}

test "merge commits restate extension fields" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();

    var a = try onClone(arena, &world, 0);
    const epic = try a.sync.repo.create(arena, .{ .title = "Epic" }, .{});
    const created = try a.sync.repo.create(arena, .{ .title = "Shared" }, .{});
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    _ = try a.sync.push(arena, "origin", .{});
    try a.sim.commit();
    var bob = try onClone(arena, &world, 1);
    _ = try bob.sync.merge(arena, "origin", .{});
    try bob.sim.commit();

    a = try onClone(arena, &world, 0);
    _ = try a.sync.repo.edit(arena, ref_name, .{
        .parent = .{ .set = epic.id },
        .due_date = .{ .set = .{ .year = 2026, .month = 12, .day = 1 } },
    }, .{});
    try a.sim.commit();
    bob = try onClone(arena, &world, 1);
    _ = try bob.sync.repo.edit(arena, ref_name, .{
        .add_blocked_by = &.{epic.id},
        .estimate_minutes = .{ .set = 90 },
        .workflow = .{ .set = "ready" },
    }, .{});
    _ = try bob.sync.push(arena, "origin", .{});
    try bob.sim.commit();

    a = try onClone(arena, &world, 0);
    const p = try a.sync.push(arena, "origin", .{});
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
    , .{ epic.id, epic.id });
    try testing.expectEqualStrings(want, commit.message);
}

test "a merge keeps the number the remote has" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();

    var a = try onClone(arena, &world, 0);
    const first = try a.sync.repo.create(arena, .{ .title = "First" }, .{});
    const second = try a.sync.repo.create(arena, .{ .title = "Second" }, .{});
    const first_ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{first.id});
    const second_ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{second.id});
    _ = try a.sync.push(arena, "origin", .{});
    try a.sim.commit();
    var bob = try onClone(arena, &world, 1);
    _ = try bob.sync.merge(arena, "origin", .{});
    try bob.sim.commit();

    // Whichever writes later: the remote's number stays, not the newer one.
    a = try onClone(arena, &world, 0);
    _ = try a.sync.repo.edit(arena, first_ref, .{ .number = 3 }, .{});
    try a.sim.commit();
    bob = try onClone(arena, &world, 1);
    _ = try bob.sync.repo.edit(arena, first_ref, .{ .number = 2 }, .{});
    _ = try bob.sync.repo.edit(arena, second_ref, .{ .number = 4 }, .{});
    _ = try bob.sync.push(arena, "origin", .{});
    try bob.sim.commit();
    a = try onClone(arena, &world, 0);
    _ = try a.sync.repo.edit(arena, second_ref, .{ .number = 5 }, .{});

    _ = try a.sync.merge(arena, "origin", .{});
    for ([_]struct { ref: []const u8, want: u64 }{
        .{ .ref = first_ref, .want = 2 },
        .{ .ref = second_ref, .want = 4 },
    }) |x| {
        const tip = (try a.sim.resolveRef(x.ref)).?;
        const issue = try a.sync.repo.load(arena, .{ .name = x.ref, .tip = tip });
        try testing.expectEqual(@as(?u64, x.want), issue.number);
    }
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
    }, .{});
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    _ = try a.sync.push(arena, "origin", .{});
    try a.sim.commit();
    var bob = try onClone(arena, &world, 1);
    _ = try bob.sync.merge(arena, "origin", .{});
    _ = try bob.sync.repo.edit(arena, ref_name, .{ .set_labels = &.{}, .priority = .clear }, .{});
    _ = try bob.sync.push(arena, "origin", .{});
    try bob.sim.commit();

    a = try onClone(arena, &world, 0);
    _ = try a.sync.repo.comment(arena, ref_name, .{ .text = "Meanwhile" }, .{});
    const p = try a.sync.push(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), p.merges[0].count(.merged));
    const tip = (try a.sim.resolveRef(ref_name)).?;
    const commit = try object.Commit.parse(arena, .sha1, (try a.sim.readObject(arena, tip)).?.data);
    try a.sim.commit();
    // A reader taking the newest value finds the cleared ones empty.
    try testing.expectEqualStrings(
        "Merge issue\n\nState: open\nLabels: \nPriority: \n",
        commit.message,
    );
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
    const created = try a.sync.repo.create(arena, .{ .title = "T", .priority = .low }, .{});
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    _ = try a.sync.push(arena, "origin", .{});
    try a.sim.commit();
    var bob = try onClone(arena, &world, 1);
    _ = try bob.sync.merge(arena, "origin", .{});
    try bob.sim.commit();

    a = try onClone(arena, &world, 0);
    _ = try a.sync.repo.edit(arena, ref_name, .{ .priority = .{ .set = .high } }, .{});
    try a.sim.commit();
    bob = try onClone(arena, &world, 1);
    _ = try bob.sync.repo.comment(arena, ref_name, .{ .text = "from bob" }, .{});
    _ = try bob.sync.push(arena, "origin", .{});
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
    const again = try bob.sync.mergeCommit(arena, created.id, bob_tip, alice_pre);
    try testing.expect(again.eql(alice_merge));
}

test "merge without fetch" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();

    var a = try onClone(arena, &world, 0);
    const created = try a.sync.repo.create(arena, .{ .title = "Staged" }, .{});
    _ = try a.sync.push(arena, "origin", .{});
    try a.sim.commit();

    // Bob fetches by hand, then merges twice without fetching.
    var bob = try onClone(arena, &world, 1);
    try bob.sim.fetch(arena, "origin", &.{"+refs/issues/*:refs/remotes/origin/issues/*"}, .{});
    const staged = try std.fmt.allocPrint(
        arena,
        "refs/remotes/origin/issues/{s}",
        .{created.id},
    );
    const first = try bob.sync.merge(arena, "origin", .{ .fetch = false });
    try testing.expectEqual(@as(usize, 1), first.count(.created));
    try testing.expect(try bob.sim.resolveRef(staged) != null);
    const again = try bob.sync.merge(arena, "origin", .{ .fetch = false });
    try testing.expectEqual(@as(usize, 1), again.count(.up_to_date));
    try testing.expect(try bob.sim.resolveRef(staged) != null);

    // Its own fetch goes to `seen/`; the user's staging refs stay.
    const fetched = try bob.sync.merge(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), fetched.count(.up_to_date));
    try testing.expect(try bob.sim.resolveRef(staged) != null);
    const seen = try recordRef(arena, "origin", .seen, .issues, created.id);
    try testing.expect(try bob.sim.resolveRef(seen) != null);
}

test "merge: when the batched local writes lose a race, issues merge one by one" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();

    var a = try onClone(arena, &world, 0);
    const shared = try a.sync.repo.create(arena, .{ .title = "Shared" }, .{});
    const shared_ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{shared.id});
    _ = try a.sync.push(arena, "origin", .{});
    try a.sim.commit();
    var bob = try onClone(arena, &world, 1);
    _ = try bob.sync.merge(arena, "origin", .{});
    try bob.sim.commit();

    a = try onClone(arena, &world, 0);
    _ = try a.sync.repo.comment(arena, shared_ref, .{ .text = "From alice" }, .{});
    const fresh = try a.sync.repo.create(arena, .{ .title = "New" }, .{});
    _ = try a.sync.push(arena, "origin", .{});
    try a.sim.commit();

    // Bob comments on the shared issue just before the merge's transaction.
    var bob_sim = try GitSim.init(arena, &world, 1);
    var racing: @import("racing_sim.zig").RacingSim = .{
        .sim = &bob_sim,
        .race = .{ .ref = shared_ref, .message = "From bob" },
    };
    const s = Sync(@import("racing_sim.zig").RacingSim).init(&racing);
    const m = try s.merge(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), m.count(.created));
    try testing.expectEqual(@as(usize, 1), m.count(.merged));
    const issue = try s.repo.load(arena, .{
        .name = shared_ref,
        .tip = (try bob_sim.resolveRef(shared_ref)).?,
    });
    var said: usize = 0;
    for (issue.comments) |c| said += @intFromBool(!c.is_merge);
    try testing.expectEqual(@as(usize, 2), said);
    const fresh_ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{fresh.id});
    try testing.expect((try bob_sim.resolveRef(fresh_ref)).?.eql(fresh.tip));
}

test "relate from loaded histories agrees with git" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();
    var a = try onClone(arena, &world, 0);
    const repo = a.sync.repo;
    const who = try repo.identity(arena, null);
    const root = try repo.writeCommit(arena, &.{}, who, "T\n\nState: open\nFormat-Version: 1\n");
    const x = try repo.writeCommit(arena, &.{root}, who, "X\n");
    const y = try repo.writeCommit(arena, &.{root}, who, "Y\n");
    // Criss-cross: two merge bases, x and y.
    const m1 = try repo.writeCommit(arena, &.{ x, y }, who, "M1\n");
    const m2 = try repo.writeCommit(arena, &.{ y, x }, who, "M2\n");
    const later = try repo.writeCommit(arena, &.{m1}, who, "L\n");
    const other = try repo.writeCommit(arena, &.{}, who, "U\n\nState: open\nFormat-Version: 1\n");
    const pairs = [_][2]Oid{
        .{ root, x },   .{ x, root },   .{ x, y },     .{ m1, m2 },
        .{ m1, later }, .{ later, m2 }, .{ x, other },
    };
    for (pairs) |pr| {
        const mine = try a.sync.relate(arena, pr[0], pr[1]);
        const git = try a.sync.relateByGit(arena, pr[0], pr[1]);
        try testing.expect(std.meta.eql(mine, git));
    }
    try testing.expect(try a.sync.relate(arena, m1, m2) == .diverged);
}

test "seen refs follow the remote, deleted refs are pushed again" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();

    var a = try onClone(arena, &world, 0);
    const created = try a.sync.repo.create(arena, .{ .title = "Kept" }, .{});
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    _ = try a.sync.sync(arena, "origin", .{});
    // Fetches write `seen/`, pushes don't.
    const seen = try recordRef(arena, "origin", .seen, .issues, created.id);
    try testing.expect(try a.sim.resolveRef(seen) == null);
    _ = try a.sync.merge(arena, "origin", .{});
    try testing.expect((try a.sim.resolveRef(seen)).?.eql(created.tip));
    try a.sim.commit();

    // Someone deletes it on the hub: the next fetch drops it from `seen/`,
    // so push no longer counts it as there and sends it again.
    var hub = try GitSim.init(arena, &world, 2);
    try hub.updateRefs(&.{.{ .name = ref_name, .op = .{ .delete = created.tip } }});
    try hub.commit();
    a = try onClone(arena, &world, 0);
    const s = try a.sync.sync(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), s.push.pushed);
    try testing.expect(try a.sim.resolveRef(seen) == null);
    try a.sim.commit();
    hub = try GitSim.init(arena, &world, 2);
    try testing.expect((try hub.resolveRef(ref_name)).?.eql(created.tip));
}

test "sync reports conflicts" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();

    var a = try onClone(arena, &world, 0);
    const created = try a.sync.repo.create(arena, .{ .title = "Contested", .priority = .low }, .{});
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    const first = try a.sync.sync(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), first.push.pushed);
    try testing.expectEqual(@as(usize, 0), (try first.conflicted(arena)).len);
    try a.sim.commit();

    var bob = try onClone(arena, &world, 1);
    _ = try bob.sync.sync(arena, "origin", .{});
    _ = try bob.sync.repo.edit(arena, ref_name, .{ .priority = .{ .set = .high } }, .{});
    _ = try bob.sync.sync(arena, "origin", .{});
    try bob.sim.commit();

    // Alice changed the same field concurrently. Her sync keeps one value
    // and reports the conflict.
    a = try onClone(arena, &world, 0);
    _ = try a.sync.repo.edit(arena, ref_name, .{ .priority = .{ .set = .critical } }, .{});
    const report = try a.sync.sync(arena, "origin", .{});
    const conflicted = try report.conflicted(arena);
    try testing.expectEqual(@as(usize, 1), conflicted.len);
    try testing.expectEqualStrings(created.id, conflicted[0].id);
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
    const created = try a.sync.repo.create(arena, .{ .title = "Alice's" }, .{});
    const id = created.id;
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{id});
    _ = try a.sync.push(arena, "origin", .{});
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
    const c = try bob.sync.counts(arena, "origin");
    try testing.expectEqual(@as(usize, 1), c.quarantined);
    try testing.expectEqual(@as(usize, 0), c.unpushed);

    // keep_local: still quarantined, since pushing would take a force push,
    // but no longer reported.
    _ = try bob.sync.resolve(arena, "origin", id, .keep_local);
    const m2 = try bob.sync.merge(arena, "origin", .{});
    try testing.expect(m2.entries[0].kept_local);
    try testing.expect((try bob.sim.resolveRef(ref_name)).?.eql(bobs));
    // Answered, so not counted for a badge either.
    try testing.expectEqual(@as(usize, 0), (try bob.sync.counts(arena, "origin")).quarantined);

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
    try testing.expectEqual(
        @as(usize, 1),
        (try bob.sync.merge(arena, "origin", .{})).count(.quarantined),
    );
    _ = try bob.sync.resolve(arena, "origin", id, .accept_remote);
    try testing.expect((try bob.sim.resolveRef(backup)).?.eql(bobs));
    const backup_again = try replacedRef(arena, "origin", .issues, id, again);
    try testing.expect((try bob.sim.resolveRef(backup_again)).?.eql(again));
    try testing.expectEqual(@as(usize, 0), (try bob.sync.status(arena, "origin")).quarantined.len);
    const after = try bob.sync.sync(arena, "origin", .{});
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
    const cat = @import("milestone.zig").Catalog(GitSim).fromRepo(a.sync.repo);
    const created = try cat.create(arena, .{ .name = "v1" }, .{});
    const id = created.id;
    const ref_name = try std.fmt.allocPrint(arena, "refs/milestones/{s}", .{id});
    _ = try a.sync.push(arena, "origin", .{});
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
    const created = try a.sync.repo.create(arena, .{ .title = "Rewound" }, .{});
    const id = created.id;
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{id});
    _ = try a.sync.push(arena, "origin", .{});
    _ = try a.sync.repo.comment(arena, ref_name, .{ .text = "Second" }, .{});
    _ = try a.sync.push(arena, "origin", .{});
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
    const s = try bob.sync.sync(arena, "origin", .{});
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
    const created = try a.sync.repo.create(arena, .{ .title = "Reset" }, .{});
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    _ = try a.sync.repo.comment(arena, ref_name, .{ .text = "Second" }, .{});
    _ = try a.sync.push(arena, "origin", .{});
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
    const s = try a.sync.sync(arena, "origin", .{});
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
    const p = try a.sync.push(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), p.pushed);
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
    const again = try a.sync.sync(arena, "origin", .{});
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
    const created = try a.sync.repo.create(arena, .{ .title = "Shots" }, .{});
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    const derived = try attachments_mod.refName(arena, created.id);
    _ = try A.fromRepo(a.sync.repo).add(arena, ref, .{
        .files = &.{.{ .name = "a.png", .data = samples.png }},
    }, .{});
    const first = try a.sync.sync(arena, "origin", .{});
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

    _ = try bob_att.add(
        arena,
        ref,
        .{ .files = &.{.{ .name = "b.webp", .data = samples.webp }} },
        .{},
    );
    try bob.sim.commit();
    a = try onClone(arena, &world, 0);
    _ = try A.fromRepo(a.sync.repo).add(arena, ref, .{
        .files = &.{.{ .name = "c.jpg", .data = samples.jpeg }},
    }, .{});
    _ = try a.sync.sync(arena, "origin", .{});
    try a.sim.commit();
    bob = try onClone(arena, &world, 1);
    _ = try bob.sync.sync(arena, "origin", .{}); // merges the issue, reconciles, pushes
    try bob.sim.commit();
    a = try onClone(arena, &world, 0);
    const last = try a.sync.sync(arena, "origin", .{});
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

test "a purge's derived ref doesn't take the remote's old history back" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();
    const samples = @import("../format/attachment.zig").samples;
    const A = attachments_mod.Attachments(GitSim);
    const P = purge_mod.Purge(GitSim);

    // One issue keeps an image, the other has none left after the purge.
    var a = try onClone(arena, &world, 0);
    const att = A.fromRepo(a.sync.repo);
    const refs = [_][]const u8{
        try std.fmt.allocPrint(
            arena,
            "refs/issues/{s}",
            .{(try a.sync.repo.create(arena, .{ .title = "Kept" }, .{})).id},
        ),
        try std.fmt.allocPrint(
            arena,
            "refs/issues/{s}",
            .{(try a.sync.repo.create(arena, .{ .title = "Empty" }, .{})).id},
        ),
    };
    _ = try att.add(arena, refs[0], .{
        .files = &.{.{ .name = "keep.webp", .data = samples.webp }},
    }, .{});
    var secrets: [2]Oid = undefined;
    for (refs, &secrets) |ref, *secret| {
        secret.* = (try att.add(arena, ref, .{
            .files = &.{.{ .name = "secret.png", .data = samples.png }},
            .comment = "Secret",
        }, .{})).tip;
    }
    _ = try a.sync.sync(arena, "origin", .{});
    try a.sim.commit();
    var bob = try onClone(arena, &world, 1);
    _ = try bob.sync.sync(arena, "origin", .{});
    try bob.sim.commit();

    a = try onClone(arena, &world, 0);
    const old_derived = (try a.sim.resolveRef(
        try attachments_mod.refName(arena, refs[0]["refs/issues/".len..]),
    )).?;
    for (refs, secrets) |ref, secret|
        _ = try P.fromRepo(a.sync.repo).comment(arena, ref, secret, .{}, .{});
    _ = try a.sync.sync(arena, "origin", .{});
    try a.sim.commit();
    bob = try onClone(arena, &world, 1);
    _ = try bob.sync.sync(arena, "origin", .{});
    try bob.sim.commit();

    const clean = struct {
        // No clone's derived ref has history from before the purge.
        fn check(a2: Allocator, w: *GitSim.World, names: []const []const u8) !void {
            for (0..3) |clone| {
                var at = try onClone(a2, w, clone);
                const here = attachments_mod.Attachments(GitSim).fromRepo(at.sync.repo);
                for (names) |ref| {
                    const tip = (try at.sim.resolveRef(ref)).?;
                    const issue = try at.sync.repo.load(a2, .{ .name = ref, .tip = tip });
                    const derived = (try at.sim.resolveRef(try attachments_mod.refName(
                        a2,
                        issue.id,
                    ))).?;
                    try testing.expect(!try here.hasOldTips(a2, derived, tip));
                }
            }
        }
    }.check;
    try clean(arena, &world, &refs);

    // The old history comes back, on the hub or in a clone: the next sync
    // replaces it.
    const name = try attachments_mod.refName(arena, refs[0]["refs/issues/".len..]);
    for ([_]usize{ 2, 0 }) |where| {
        var at = try onClone(arena, &world, where);
        const now = (try at.sim.resolveRef(name)).?;
        try at.sim.updateRefs(&.{.{
            .name = name,
            .op = .{ .update = .{ .new = old_derived, .old = now } },
        }});
        try at.sim.commit();
        for (0..2) |_| {
            a = try onClone(arena, &world, 0);
            _ = try a.sync.sync(arena, "origin", .{});
            try a.sim.commit();
            bob = try onClone(arena, &world, 1);
            _ = try bob.sync.sync(arena, "origin", .{});
            try bob.sim.commit();
        }
        try clean(arena, &world, &refs);
    }
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
    const created = try a.sync.repo.create(arena, .{ .title = "Shots" }, .{});
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    _ = try A.fromRepo(a.sync.repo).add(arena, ref, .{
        .files = &.{.{ .name = "a.png", .data = samples.png }},
    }, .{});

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
    try testing.expectError(error.BeforePushFailed, a.sync.push(arena, "origin", .{
        .before_push = .{ .context = &failing, .run = Hook.run },
    }));
    try a.sim.commit();
    try testing.expectEqual(@as(usize, 0), world.clones[1].refs.len);
    var ok: Hook = .{ .fail = false };
    a = try onClone(arena, &world, 0);
    const pushed = try a.sync.push(arena, "origin", .{
        .before_push = .{ .context = &ok, .run = Hook.run },
    });
    try testing.expectEqual(@as(usize, 1), ok.calls);
    try testing.expectEqual(@as(usize, 1), pushed.lfs_uploaded);
    // Only what the remote's derived ref doesn't list yet.
    _ = try A.fromRepo(a.sync.repo).add(arena, ref, .{
        .files = &.{.{ .name = "b.jpg", .data = samples.jpeg }},
    }, .{});
    _ = try a.sync.push(arena, "origin", .{
        .before_push = .{ .context = &ok, .run = Hook.run },
    });
    try testing.expectEqual(@as(usize, 2), ok.calls);

    // Without git-lfs: attachment calls refuse up front, and a push with
    // bytes to upload fails before any ref moves.
    _ = try A.fromRepo(a.sync.repo).add(arena, ref, .{
        .files = &.{.{ .name = "c.webp", .data = samples.webp }},
    }, .{});
    try a.sim.configAdd("sim.lfs", "false");
    const att = A.fromRepo(a.sync.repo);
    try testing.expectError(error.LfsUnavailable, att.add(arena, ref, .{
        .files = &.{.{ .name = "d.png", .data = samples.png }},
    }, .{}));
    const hub_before = world.clones[1].refs;
    try testing.expectError(error.LfsUnavailable, a.sync.push(arena, "origin", .{}));
    try a.sim.commit();
    try testing.expectEqualDeep(hub_before, world.clones[1].refs);
    // With nothing to upload, push needs no git-lfs.
    a = try onClone(arena, &world, 0);
    try a.sim.configAdd("sim.lfs", "true");
    _ = try a.sync.push(arena, "origin", .{});
    try a.sim.configAdd("sim.lfs", "false");
    _ = try a.sync.repo.create(arena, .{ .title = "No images" }, .{});
    const plain = try a.sync.push(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), plain.pushed);
}

test "a URL instead of a remote's name: its refs under url-<hash>" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // No remote configured: the clones name the hub by its URL.
    var world: GitSim.World = .{ .seed = 13, .clones = &.{
        .{ .name = "alice" },
        .{ .name = "bob" },
        .{ .name = "hub" },
    } };
    const url = "sim:hub";
    var a = try onClone(arena, &world, 0);
    const made = try a.sync.repo.create(arena, .{ .title = "By URL" }, .{});
    const pushed = try a.sync.sync(arena, url, .{});
    try testing.expectEqual(@as(usize, 1), pushed.push.pushed);
    try a.sim.commit();

    var bob = try onClone(arena, &world, 1);
    // `fetch = false` has no staging of its own to read: a URL fetches.
    const merged = try bob.sync.merge(arena, url, .{ .fetch = false });
    try testing.expectEqual(@as(usize, 1), merged.count(.created));
    const key = try remoteKey(arena, url);
    try testing.expect(std.mem.startsWith(u8, key, "url-") and key.len == 4 + 16);
    const seen = try recordRef(arena, key, .seen, .issues, made.id);
    try testing.expect(try bob.sim.resolveRef(seen) != null);
    try testing.expectEqual(@as(usize, 0), (try bob.sync.status(arena, url)).quarantined.len);

    try testing.expectError(error.InvalidRemoteName, bob.sync.merge(arena, "not a remote", .{}));
    try testing.expect(contract.isRemoteUrl("../hub.git") and contract.isRemoteUrl("file:///x"));
    try testing.expect(!contract.isRemoteUrl("-upload-pack=x:y"));
    try testing.expect(!contract.isRemoteUrl("a\nb/c"));
}

test "progress phases, counts and the default remote" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();
    const a = try onClone(arena, &world, 0);
    const issue = try a.sync.repo.create(arena, .{ .title = "New here" }, .{});
    const Catalog = @import("milestone.zig").Catalog(GitSim);
    _ = try Catalog.init(a.sim).create(arena, .{ .name = "v1" }, .{});

    var c = try a.sync.counts(arena, "origin");
    try testing.expectEqual(@as(usize, 2), c.unpushed);
    try testing.expectEqual(@as(usize, 0), c.quarantined);
    const before = try a.sync.unpushed(arena, "origin");
    try testing.expect(before[0].new and before[1].new);

    const Seen = struct {
        phases: [8]Phase = undefined,
        n: usize = 0,
        fn on(ctx: *anyopaque, p: Phase) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.phases[self.n] = p;
            self.n += 1;
        }
    };
    var seen: Seen = .{};
    _ = try a.sync.sync(arena, "origin", .{ .progress = .{ .context = &seen, .phase = Seen.on } });
    try testing.expectEqualSlices(
        Phase,
        &.{ .fetching, .merging, .pushing },
        seen.phases[0..seen.n],
    );
    c = try a.sync.counts(arena, "origin");
    try testing.expectEqual(@as(usize, 0), c.unpushed);
    // Edited after a push: unpushed, but not new.
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{issue.id});
    _ = try a.sync.repo.edit(arena, ref, .{ .title = "Renamed" }, .{});
    const after = try a.sync.unpushed(arena, "origin");
    try testing.expectEqual(@as(usize, 1), after.len);
    try testing.expect(!after[0].new);
    try testing.expectEqual(@as(usize, 1), (try a.sync.status(arena, "origin")).unpushed.len);

    try testing.expectEqualStrings("origin", (try defaultRemote(GitSim, arena, a.sim)).?);
}

test "defaultRemote" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world = testWorld();
    const sim = (try onClone(arena, &world, 2)).sim;
    try testing.expect(try defaultRemote(GitSim, arena, sim) == null);
    // Exactly one: that one, whatever its name.
    try sim.configAdd("remote.upstream.url", "sim:alice");
    try testing.expectEqualStrings("upstream", (try defaultRemote(GitSim, arena, sim)).?);
    // Several without origin: the first by name.
    try sim.configAdd("remote.backup.url", "sim:bob");
    try testing.expectEqualStrings("backup", (try defaultRemote(GitSim, arena, sim)).?);
    try sim.configAdd("remote.origin.url", "sim:alice");
    try testing.expectEqualStrings("origin", (try defaultRemote(GitSim, arena, sim)).?);
    try sim.configAdd(remote_key, "upstream");
    try testing.expectEqualStrings("upstream", (try defaultRemote(GitSim, arena, sim)).?);
    // A typo is an error, not another remote.
    try sim.configAdd(remote_key, "upstrem");
    try testing.expectError(error.UnknownIssueRemote, defaultRemote(GitSim, arena, sim));
    try sim.configAdd(remote_key, "-bad name");
    try testing.expectError(error.UnknownIssueRemote, defaultRemote(GitSim, arena, sim));
    try testing.expect(@import("errors.zig").describe(error.UnknownIssueRemote) != null);
}

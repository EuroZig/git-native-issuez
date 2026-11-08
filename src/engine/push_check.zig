//! Push check: may a push's ref updates be accepted (format.md §11)?
//!
//! For a host's pre-receive hook. It judges the format only and reads the
//! objects from the push's quarantine through the backend; nothing is
//! written. Permissions and locks stay the host's: the verdicts report
//! what it needs to decide (a missing number, commits to a locked issue).

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("../backend/object.zig");
const trailers = @import("../format/trailers.zig");
const uuid_fmt = @import("../format/uuid.zig");
const repo_mod = @import("repo.zig");
const purge_mod = @import("purge.zig");
const attachments_mod = @import("attachments.zig");
const issue_model = @import("../model/issue.zig");
const labels_fmt = @import("../format/labels.zig");

const Oid = object.Oid;
const CommitInput = issue_model.CommitInput;

pub const AuthorPolicy = enum {
    /// Checks nothing.
    any,
    /// Flags new commits not by the pusher, accepts them.
    warn,
    /// Rejects them.
    enforce,
};

pub const Policy = struct {
    /// The pusher's verified emails, compared ignoring case.
    pusher_emails: []const []const u8 = &.{},
    /// The pusher's host UUIDs. Under the author policy, a new commit's
    /// `X-Author-Id` must be one of them.
    pusher_ids: []const []const u8 = &.{},
    author_policy: AuthorPolicy = .any,
    /// Clients may give numbers. Off by default: numbers are the host's.
    allow_numbers: bool = false,
    /// The pusher may push tombstones, and the rewrites and deletes they
    /// allow.
    allow_purge: bool = false,
};

/// One line of the pre-receive hook's input.
pub const Update = struct {
    ref: []const u8,
    /// Null for a create.
    old: ?Oid,
    /// Null for a delete.
    new: ?Oid,
};

pub const Kind = enum {
    /// Not ours: the host's business.
    other,
    issue,
    milestone,
    attachments,
    tombstone,
    /// `refs/issuez-*` other than tombstones, and names under our
    /// prefixes that aren't UUIDs.
    invalid,
};

pub const Action = enum { ignored, create, fast_forward, rewrite, delete };

pub const ProblemKind = enum {
    /// A local-only ref (guards, sync bookkeeping, caches).
    local_ref,
    /// Not a canonical UUID under one of our prefixes.
    bad_ref_name,
    non_fast_forward,
    deleted,
    /// Fails fsck, or can't be read within the limits.
    invalid_history,
    format_version,
    /// A new commit carries `X-Number` and clients may not number.
    number_set,
    /// The issue had another number.
    number_changed,
    /// Another issue has it, here or in the same push.
    number_taken,
    author_mismatch,
    /// The issue is purged, or its history still has purged comments.
    purged,
    purge_not_allowed,
    /// A tombstone commit that isn't a purge.
    not_a_purge,
    /// An attachments commit that isn't what §7 derives.
    not_derived,
};

pub const Problem = struct {
    kind: ProblemKind,
    /// False for what is only flagged (an author under `warn`).
    rejects: bool = true,
    commit: ?Oid = null,
    /// The other issue involved.
    subject: []const u8 = "",
    message: []const u8,
};

pub const Verdict = struct {
    update: Update,
    kind: Kind,
    /// The UUID in the ref name, empty for other refs.
    id: []const u8,
    action: Action,
    accept: bool,
    problems: []const Problem,
    /// An issue that has no number after the push.
    needs_number: bool = false,
    /// Adds commits to an issue locked at its old tip.
    touches_locked: bool = false,
    /// Gives the issue a number it didn't have (clients may number).
    gives_number: bool = false,
    /// The new commits: those the old tip doesn't have.
    new_commits: []const CommitInput = &.{},
    /// The issue or milestone after the push, when it reads.
    issue: ?issue_model.Issue = null,
};

pub const prefixes = struct {
    pub const issues = repo_mod.issue_ref_prefix;
    pub const milestones = "refs/milestones/";
    pub const attachments = attachments_mod.ref_prefix;
    pub const tombstones = purge_mod.ref_prefix;
    pub const local = "refs/issuez-";
};

fn classify(ref: []const u8) struct { kind: Kind, id: []const u8 } {
    const ours = [_]struct { []const u8, Kind }{
        .{ prefixes.issues, .issue },
        .{ prefixes.milestones, .milestone },
        .{ prefixes.attachments, .attachments },
        .{ prefixes.tombstones, .tombstone },
    };
    for (ours) |o| if (std.mem.startsWith(u8, ref, o[0])) {
        const id = ref[o[0].len..];
        return .{ .kind = if (uuid_fmt.isCanonical(id)) o[1] else .invalid, .id = id };
    };
    if (std.mem.startsWith(u8, ref, prefixes.local)) return .{ .kind = .invalid, .id = "" };
    return .{ .kind = .other, .id = "" };
}

/// Hashes what `purge.rewrite` would write: checking writes nothing.
const HashOnly = struct {
    format: object.ObjectFormat,

    pub fn objectFormat(h: HashOnly) object.ObjectFormat {
        return h.format;
    }

    pub fn writeObject(h: HashOnly, kind: object.ObjectKind, data: []const u8) !Oid {
        return object.hashObject(h.format, kind, data);
    }
};

/// The commits of `commits` reachable from `start`, by OID.
const Reach = std.AutoHashMapUnmanaged([Oid.max_byte_len]u8, void);

fn reachable(arena: Allocator, commits: []const CommitInput, start: Oid) Allocator.Error!Reach {
    var index: std.AutoHashMapUnmanaged([Oid.max_byte_len]u8, usize) = .empty;
    for (commits, 0..) |c, i| try index.put(arena, c.oid.bytes, i);
    var out: Reach = .empty;
    var stack: std.ArrayList(Oid) = .empty;
    try stack.append(arena, start);
    while (stack.pop()) |oid| {
        const i = index.get(oid.bytes) orelse continue;
        if ((try out.getOrPut(arena, oid.bytes)).found_existing) continue;
        for (commits[i].parents) |p| try stack.append(arena, p);
    }
    return out;
}

fn contains(commits: []const CommitInput, oid: Oid) bool {
    for (commits) |c| if (c.oid.eql(oid)) return true;
    return false;
}

fn isSyncMerge(c: CommitInput) bool {
    return c.parents.len >= 2 and
        std.mem.eql(u8, c.author.email, @import("sync.zig").merge_identity_email);
}

/// Whether `value` is what the merge restates: sets in any order, since a
/// purge's rewrite sorts them (format.md §10).
fn sameRestated(arena: Allocator, want: trailers.Trailer, value: []const u8) Allocator.Error!bool {
    const is_set = std.mem.eql(u8, want.key, "Labels") or
        std.mem.eql(u8, want.key, "X-Blocked-By");
    if (!is_set) return std.mem.eql(u8, want.value, value);
    const lt = struct {
        fn f(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.f;
    const x = try arena.dupe([]const u8, try labels_fmt.parse(arena, want.value));
    const y = try arena.dupe([]const u8, try labels_fmt.parse(arena, value));
    std.mem.sort([]const u8, x, {}, lt);
    std.mem.sort([]const u8, y, {}, lt);
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

pub fn PushCheck(comptime B: type) type {
    return struct {
        const Self = @This();
        pub const Repo = repo_mod.Repo(B);
        pub const Error = Repo.Error;

        repo: Repo,

        pub fn init(backend: *B) Self {
            return .{ .repo = Repo.init(backend) };
        }

        pub fn fromRepo(repo: Repo) Self {
            return .{ .repo = repo };
        }

        const Run = struct {
            check: Self,
            arena: Allocator,
            policy: Policy,
            updates: []const Update,
            /// Per issue: the tombstone after the push.
            tombs: std.StringHashMapUnmanaged(purge_mod.Tombstone) = .empty,
            numbers: ?std.AutoHashMapUnmanaged(u64, std.ArrayList(repo_mod.IssueRef)) = null,

            fn b(r: *Run) *B {
                return r.check.repo.backend;
            }

            fn format(r: *Run) object.ObjectFormat {
                return r.b().objectFormat();
            }
        };

        /// One verdict per update, in order.
        pub fn check(
            self: Self,
            arena: Allocator,
            updates: []const Update,
            policy: Policy,
        ) Error![]Verdict {
            var run: Run = .{ .check = self, .arena = arena, .policy = policy, .updates = updates };
            const verdicts = try arena.alloc(Verdict, updates.len);
            // Tombstones first: the issue verdicts read them.
            for (try self.repo.backend.listRefs(arena, prefixes.tombstones)) |e| {
                const id = e.name[prefixes.tombstones.len..];
                if (!uuid_fmt.isCanonical(id)) continue;
                const t = try purge_mod.readAt(arena, self.repo.backend, e.oid);
                try run.tombs.put(arena, id, t);
            }
            for (updates, verdicts) |u, *v| {
                const c = classify(u.ref);
                if (c.kind != .tombstone) continue;
                v.* = try tombstone(&run, u, c.id);
                if (!v.accept) continue;
                const new = u.new orelse continue;
                const t = try purge_mod.readAt(arena, self.repo.backend, new);
                const merged = if (run.tombs.get(c.id)) |old| try purge_mod.unionOf(
                    arena,
                    old,
                    t,
                ) else t;
                try run.tombs.put(arena, c.id, merged);
            }
            for (updates, verdicts) |u, *v| {
                const c = classify(u.ref);
                v.* = switch (c.kind) {
                    .tombstone => continue,
                    .other => .{
                        .update = u,
                        .kind = .other,
                        .id = "",
                        .action = .ignored,
                        .accept = true,
                        .problems = &.{},
                    },
                    .invalid => try invalid(&run, u, c.id),
                    .issue, .milestone => try issueOrMilestone(&run, u, c.kind, c.id),
                    .attachments => try attachments(&run, u, c.id),
                };
            }
            try pushedNumbers(&run, verdicts);
            for (verdicts) |*v| v.accept = for (v.problems) |p| {
                if (p.rejects) break false;
            } else true;
            return verdicts;
        }

        const Problems = std.ArrayList(Problem);

        fn verdictOf(
            u: Update,
            kind: Kind,
            id: []const u8,
            action: Action,
            problems: *Problems,
        ) Verdict {
            return .{
                .update = u,
                .kind = kind,
                .id = id,
                .action = action,
                .accept = for (problems.items) |p| {
                    if (p.rejects) break false;
                } else true,
                .problems = problems.items,
            };
        }

        fn invalid(r: *Run, u: Update, id: []const u8) Error!Verdict {
            var problems: Problems = .empty;
            try problems.append(r.arena, if (std.mem.startsWith(u8, u.ref, prefixes.local) and
                !std.mem.startsWith(u8, u.ref, prefixes.tombstones))
                .{ .kind = .local_ref, .message = "a local-only ref" }
            else
                .{ .kind = .bad_ref_name, .message = "not a UUID" });
            return verdictOf(u, .invalid, id, try actionOf(r, u, null), &problems);
        }

        /// From the new tip's history, when it was read.
        fn actionOf(r: *Run, u: Update, history: ?[]const CommitInput) Error!Action {
            const old = u.old orelse return .create;
            const new = u.new orelse return .delete;
            if (old.eql(new)) return .fast_forward;
            if (history) |h| return if (contains(h, old)) .fast_forward else .rewrite;
            return if (try r.b().isAncestor(old, new)) .fast_forward else .rewrite;
        }

        /// Loads `tip`'s history, or adds why it can't be read.
        fn historyOf(r: *Run, tip: Oid, problems: *Problems) Error!?[]CommitInput {
            return r.check.repo.loadCommits(r.arena, tip) catch |e| switch (e) {
                error.CorruptIssue, error.HistoryTooLong => {
                    try problems.append(r.arena, .{
                        .kind = .invalid_history,
                        .message = if (e == error.HistoryTooLong)
                            "history too long"
                        else
                            "history unreadable",
                    });
                    return null;
                },
                else => |x| return x,
            };
        }

        /// The commits `history` has and `base`'s history doesn't.
        fn newCommits(
            r: *Run,
            history: []const CommitInput,
            base: ?[]const CommitInput,
        ) Error![]const CommitInput {
            const old = base orelse return history;
            var known: Reach = .empty;
            for (old) |c| try known.put(r.arena, c.oid.bytes, {});
            var out: std.ArrayList(CommitInput) = .empty;
            for (history) |c| if (!known.contains(c.oid.bytes)) try out.append(r.arena, c);
            return out.items;
        }

        /// A merge under this tool's identity that adds nothing to its
        /// parents, as sync writes them (format.md §4, §6, §10). The identity
        /// proves nothing: anyone can write it.
        fn mergeAddsNothing(
            r: *Run,
            c: CommitInput,
            kind: Kind,
            id: []const u8,
            history: []const CommitInput,
        ) Error!bool {
            if (!isSyncMerge(c)) return false;
            const a = r.arena;
            switch (kind) {
                .tombstone => return std.mem.eql(u8, c.message, purge_mod.merge_subject ++ "\n"),
                .milestone => return std.mem.eql(u8, c.message, "Merge milestone\n"),
                .issue => {},
                else => return false,
            }
            const subject = @import("sync.zig").merge_subject;
            const block = try trailers.parse(a, c.message, .{});
            if (block.first_line) |line| {
                // The subject, a blank line, the trailers.
                if (line != 2 or !std.mem.eql(u8, std.mem.sliceTo(c.message, '\n'), subject))
                    return false;
            } else if (!std.mem.eql(u8, std.mem.trimEnd(u8, c.message, "\n"), subject)) {
                return false;
            }
            var reach: Reach = .empty;
            for (c.parents) |p| {
                var from = try reachable(a, history, p);
                var keys = from.keyIterator();
                while (keys.next()) |k| try reach.put(a, k.*, {});
            }
            var before: std.ArrayList(CommitInput) = .empty;
            for (history) |h| if (reach.contains(h.oid.bytes)) try before.append(a, h);
            const resolved = issue_model.resolveMerge(
                a,
                id,
                before.items,
                c.parents,
                c.author,
                subject ++ "\n",
            ) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return false,
            };
            const restated = try issue_model.restatedTrailers(a, resolved);
            for (block.trailers) |t| {
                // Says nothing, or has its own check (§11).
                if (std.ascii.eqlIgnoreCase(t.key, "X-Number") or
                    std.ascii.eqlIgnoreCase(t.key, purge_mod.rewritten_from_key)) continue;
                const same = for (restated.items) |want| {
                    if (!std.ascii.eqlIgnoreCase(want.key, t.key)) continue;
                    break try sameRestated(a, want, t.value);
                } else false;
                if (!same) return false;
            }
            return true;
        }

        fn authors(
            r: *Run,
            commits: []const CommitInput,
            kind: Kind,
            issue_id: []const u8,
            history: []const CommitInput,
            problems: *Problems,
        ) Error!void {
            if (r.policy.author_policy == .any) return;
            for (commits) |c| {
                if (try mergeAddsNothing(r, c, kind, issue_id, history)) continue;
                // A host's UUID names its user whatever the email says.
                if (try issue_model.authorIdOf(r.arena, c.message)) |id| {
                    const own = for (r.policy.pusher_ids) |p| {
                        if (std.ascii.eqlIgnoreCase(p, id)) break true;
                    } else false;
                    if (!own) try problems.append(r.arena, .{
                        .kind = .author_mismatch,
                        .rejects = r.policy.author_policy == .enforce,
                        .commit = c.oid,
                        .message = try std.fmt.allocPrint(
                            r.arena,
                            "author id {s} isn't the pusher's",
                            .{id},
                        ),
                    });
                }
                const ok = for (r.policy.pusher_emails) |e| {
                    if (std.ascii.eqlIgnoreCase(e, c.author.email)) break true;
                } else false;
                if (ok) continue;
                try problems.append(r.arena, .{
                    .kind = .author_mismatch,
                    .rejects = r.policy.author_policy == .enforce,
                    .commit = c.oid,
                    .message = try std.fmt.allocPrint(
                        r.arena,
                        "author {s} isn't the pusher",
                        .{c.author.email},
                    ),
                });
            }
        }

        fn deleteVerdict(r: *Run, u: Update, kind: Kind, id: []const u8) Error!Verdict {
            var problems: Problems = .empty;
            const purged = if (r.tombs.get(id)) |t| t.issue else false;
            const purgeable = kind == .issue or kind == .attachments;
            if (!(purgeable and purged)) {
                try problems.append(r.arena, .{ .kind = .deleted, .message = "deletes a ref" });
            } else if (!r.policy.allow_purge) {
                try problems.append(r.arena, .{
                    .kind = .purge_not_allowed,
                    .message = "deleting a purged issue needs leave to purge",
                });
            }
            return verdictOf(u, kind, id, .delete, &problems);
        }

        fn tombstone(r: *Run, u: Update, id: []const u8) Error!Verdict {
            if (u.new == null) return deleteVerdict(r, u, .tombstone, id);
            const new = u.new.?;
            var problems: Problems = .empty;
            if (!r.policy.allow_purge) try problems.append(r.arena, .{
                .kind = .purge_not_allowed,
                .message = "the pusher may not purge",
            });
            const history = (try historyOf(r, new, &problems)) orelse
                return verdictOf(u, .tombstone, id, try actionOf(r, u, null), &problems);
            const action = try actionOf(r, u, history);
            if (action == .rewrite) try problems.append(r.arena, .{
                .kind = .non_fast_forward,
                .message = "not a fast-forward",
            });
            const base: ?[]const CommitInput = if (u.old) |o|
                (try historyOf(r, o, &problems)) orelse
                    return verdictOf(u, .tombstone, id, action, &problems)
            else
                null;
            const fresh = try newCommits(r, history, base);
            const empty = object.emptyTree(r.format());
            for (fresh) |c| {
                if (c.tree != null and !c.tree.?.eql(empty)) {
                    try problems.append(r.arena, .{
                        .kind = .not_a_purge,
                        .commit = c.oid,
                        .message = "a tombstone commit with files",
                    });
                    continue;
                }
                if (!try isPurge(r.arena, r.format(), c)) {
                    try problems.append(r.arena, .{
                        .kind = .not_a_purge,
                        .commit = c.oid,
                        .message = "a tombstone commit that isn't a purge",
                    });
                }
            }
            try authors(r, fresh, .tombstone, id, history, &problems);
            var v = verdictOf(u, .tombstone, id, action, &problems);
            v.new_commits = fresh;
            return v;
        }

        fn isPurge(arena: Allocator, format: object.ObjectFormat, c: CommitInput) !bool {
            if (c.parents.len >= 2) {
                const subject = std.mem.sliceTo(c.message, '\n');
                return isSyncMerge(c) and std.mem.eql(u8, subject, purge_mod.merge_subject);
            }
            const block = try trailers.parse(arena, c.message, .{});
            const kind = trailers.lastValue(block, purge_mod.purge_key) orelse return false;
            if (std.mem.eql(u8, kind, "issue")) return true;
            if (!std.mem.eql(u8, kind, "comment")) return false;
            for (block.trailers) |t| {
                if (!std.ascii.eqlIgnoreCase(t.key, purge_mod.purged_commit_key)) continue;
                if (t.value.len != format.hexLen()) continue;
                _ = Oid.parseHex(format, t.value) catch continue;
                return true;
            }
            return false;
        }

        fn issueOrMilestone(r: *Run, u: Update, kind: Kind, id: []const u8) Error!Verdict {
            if (u.new == null) return deleteVerdict(r, u, kind, id);
            const new = u.new.?;
            const a = r.arena;
            var problems: Problems = .empty;
            const tomb: ?purge_mod.Tombstone = if (kind == .issue) r.tombs.get(id) else null;
            if (tomb) |t| if (t.issue) {
                try problems.append(a, .{ .kind = .purged, .message = "the issue is purged" });
                return verdictOf(u, kind, id, try actionOf(r, u, null), &problems);
            };
            const history = (try historyOf(r, new, &problems)) orelse
                return verdictOf(u, kind, id, try actionOf(r, u, null), &problems);
            const action = try actionOf(r, u, history);
            const name = u.ref;
            const root_keys: []const []const u8 = if (kind == .issue)
                &.{ "State", "Format-Version" }
            else
                &.{ "Name", "Format-Version" };
            for (try r.check.repo.checkCommits(
                a,
                .{ .name = name, .tip = new },
                history,
                .{ .root_keys = root_keys },
            )) |p|
                try problems.append(a, .{
                    .kind = .invalid_history,
                    .commit = switch (p) {
                        .non_empty_tree => |oid| oid,
                        else => null,
                    },
                    .message = switch (p) {
                        .invalid_uuid => "not a UUID",
                        .non_empty_tree => "a commit with files",
                        .root_count => "not exactly one root commit",
                        .missing_state => "no State on the root",
                        .missing_format_version => "no Format-Version on the root",
                        .missing_root_trailer => "a root trailer is missing",
                        .unreadable => "history unreadable",
                    },
                });
            if (problems.items.len > 0) return verdictOf(u, kind, id, action, &problems);
            for (history) |c| if (c.parents.len == 0) {
                const block = try trailers.parse(a, c.message, .{});
                const v = trailers.lastValue(block, "Format-Version") orelse "";
                if (!std.mem.eql(u8, v, "1")) try problems.append(a, .{
                    .kind = .format_version,
                    .commit = c.oid,
                    .message = "Format-Version isn't 1",
                });
            };
            const loaded = issue_model.materialize(a, id, new, history) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try problems.append(a, .{
                        .kind = .invalid_history,
                        .message = "history unreadable",
                    });
                    return verdictOf(u, kind, id, action, &problems);
                },
            };
            const old_history: ?[]const CommitInput = if (u.old) |o|
                (try historyOf(r, o, &problems)) orelse
                    return verdictOf(u, kind, id, action, &problems)
            else
                null;
            const old_issue: ?issue_model.Issue = if (old_history) |h|
                issue_model.materialize(a, id, u.old.?, h) catch null
            else
                null;

            // What the new commits are counted from: the old tip, or for a
            // purge, the old tip purged.
            var base = old_history;
            if (action == .rewrite) {
                const purging = if (tomb) |t| t.comments.len > 0 else false;
                if (!purging) {
                    try problems.append(a, .{
                        .kind = .non_fast_forward,
                        .message = "not a fast-forward",
                    });
                } else if (!r.policy.allow_purge) {
                    try problems.append(a, .{
                        .kind = .purge_not_allowed,
                        .message = "replacing history needs leave to purge",
                    });
                } else {
                    const hash: HashOnly = .{ .format = r.format() };
                    const rw = purge_mod.rewrite(
                        a,
                        hash,
                        old_history.?,
                        u.old.?,
                        tomb.?.comments,
                    ) catch |e|
                        switch (e) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => null,
                        };
                    if (rw == null or !contains(history, rw.?.tip)) {
                        try problems.append(a, .{
                            .kind = .non_fast_forward,
                            .message = "doesn't contain the old history, purged",
                        });
                    } else {
                        const kept = try reachable(a, history, rw.?.tip);
                        var list: std.ArrayList(CommitInput) = .empty;
                        for (history) |c| if (kept.contains(c.oid.bytes)) try list.append(a, c);
                        base = list.items;
                    }
                }
            }
            const fresh = try newCommits(r, history, base);

            if (tomb) |t| if (t.comments.len > 0) {
                const hash: HashOnly = .{ .format = r.format() };
                const rw = purge_mod.rewrite(
                    a,
                    hash,
                    history,
                    new,
                    t.comments,
                ) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => null,
                };
                if (rw == null or !rw.?.tip.eql(new)) try problems.append(a, .{
                    .kind = .purged,
                    .message = "history has purged comments",
                });
            };

            var gives_number = false;
            if (kind == .issue) {
                const old_number = if (old_issue) |o| o.number else null;
                if (!r.policy.allow_numbers) {
                    for (fresh) |c| {
                        const block = try trailers.parse(a, c.message, .{});
                        for (block.trailers) |t| {
                            if (!std.ascii.eqlIgnoreCase(t.key, "X-Number")) continue;
                            const same = if (old_number) |n|
                                std.mem.eql(u8, t.value, try std.fmt.allocPrint(a, "{d}", .{n}))
                            else
                                false;
                            if (!same) try problems.append(a, .{
                                .kind = .number_set,
                                .commit = c.oid,
                                .message = "numbers are the host's to give",
                            });
                        }
                    }
                } else if (loaded.number) |n| {
                    if (old_number != null and old_number.? != n) {
                        try problems.append(a, .{
                            .kind = .number_changed,
                            .message = "the issue had another number",
                        });
                    } else if (old_number == null) {
                        gives_number = true;
                        if (r.numbers == null) r.numbers = try r.check.repo.numbers(a);
                        if (r.numbers.?.get(n)) |owners| for (owners.items) |o| {
                            if (std.mem.eql(u8, o.id(), id)) continue;
                            try problems.append(a, .{
                                .kind = .number_taken,
                                .subject = o.id(),
                                .message = "another issue has this number",
                            });
                            break;
                        };
                    }
                }
            }

            try authors(r, fresh, kind, id, history, &problems);
            var v = verdictOf(u, kind, id, action, &problems);
            v.new_commits = fresh;
            v.issue = loaded;
            v.gives_number = gives_number;
            if (kind == .issue) {
                v.needs_number = loaded.number == null;
                v.touches_locked = fresh.len > 0 and
                    if (old_issue) |o| o.locked else false;
            }
            return v;
        }

        /// Numbers given in this push, two issues to one.
        fn pushedNumbers(r: *Run, verdicts: []Verdict) Error!void {
            if (!r.policy.allow_numbers) return;
            for (verdicts, 0..) |*v, i| {
                if (!v.gives_number) continue;
                const n = (v.issue orelse continue).number orelse continue;
                for (verdicts, 0..) |w, j| {
                    if (i == j or !w.gives_number or std.mem.eql(u8, w.id, v.id)) continue;
                    const m = (w.issue orelse continue).number orelse continue;
                    if (m != n) continue;
                    v.problems = try std.mem.concat(r.arena, Problem, &.{ v.problems, &.{.{
                        .kind = .number_taken,
                        .subject = w.id,
                        .message = "another issue in this push has this number",
                    }} });
                    break;
                }
            }
        }

        /// The issue's tip once the push is in.
        fn issueTipAfter(r: *Run, id: []const u8) Error!?Oid {
            const name = try std.fmt.allocPrint(r.arena, "{s}{s}", .{ prefixes.issues, id });
            for (r.updates) |u| if (std.mem.eql(u8, u.ref, name)) return u.new;
            return r.b().resolveRef(name);
        }

        fn attachments(r: *Run, u: Update, id: []const u8) Error!Verdict {
            if (u.new == null) return deleteVerdict(r, u, .attachments, id);
            const new = u.new.?;
            const a = r.arena;
            var problems: Problems = .empty;
            const history = (try historyOf(r, new, &problems)) orelse
                return verdictOf(u, .attachments, id, try actionOf(r, u, null), &problems);
            const action = try actionOf(r, u, history);
            if (action == .rewrite) {
                if (r.tombs.get(id) == null) {
                    try problems.append(a, .{
                        .kind = .non_fast_forward,
                        .message = "not a fast-forward",
                    });
                } else if (!r.policy.allow_purge) try problems.append(a, .{
                    .kind = .purge_not_allowed,
                    .message = "replacing history needs leave to purge",
                });
            }
            const base = if (u.old) |o| r.check.repo.loadCommits(a, o) catch null else null;
            const fresh = try newCommits(r, history, base);

            const issue_tip = try issueTipAfter(r, id);
            const issue_history: []const CommitInput = if (issue_tip) |t|
                r.check.repo.loadCommits(a, t) catch &.{}
            else
                &.{};
            const att = attachments_mod.Attachments(B).fromRepo(r.check.repo);
            // The tip is what the issue derives; what led there need only
            // hold pointers (it may name tips a replaced history dropped).
            for (fresh) |c| {
                const ok = if (c.oid.eql(new))
                    try isDerived(r, att, id, c, issue_history)
                else
                    try pointersOnly(r, c);
                if (!ok) try problems.append(a, .{
                    .kind = .not_derived,
                    .commit = c.oid,
                    .message = if (c.oid.eql(new))
                        "not what the issue's attachments derive"
                    else
                        "a tree that isn't LFS pointers",
                });
            }
            var v = verdictOf(u, .attachments, id, action, &problems);
            v.new_commits = fresh;
            return v;
        }

        /// Every entry `<uuid>.<png|jpg|webp>`, a blob that is an LFS pointer.
        fn pointersOnly(r: *Run, c: CommitInput) Error!bool {
            const a = r.arena;
            const tree = c.tree orelse return false;
            if (tree.eql(object.emptyTree(r.format()))) return true;
            const o = (try r.b().readObject(a, tree)) orelse return false;
            if (o.kind != .tree) return false;
            const entries = object.Tree.parse(a, r.format(), o.data) catch return false;
            for (entries) |e| {
                const dot = std.mem.findScalar(u8, e.name, '.') orelse return false;
                if (!uuid_fmt.isCanonical(e.name[0..dot])) return false;
                const ext = e.name[dot + 1 ..];
                const known = for ([_][]const u8{ "png", "jpg", "webp" }) |x| {
                    if (std.mem.eql(u8, ext, x)) break true;
                } else false;
                if (!known) return false;
                const blob = (try r.b().readObject(a, e.oid)) orelse return false;
                if (blob.kind != .blob or !isPointer(blob.data)) return false;
            }
            return true;
        }

        fn isDerived(
            r: *Run,
            att: attachments_mod.Attachments(B),
            id: []const u8,
            c: CommitInput,
            issue_history: []const CommitInput,
        ) Error!bool {
            const a = r.arena;
            const block = try trailers.parse(a, c.message, .{});
            const hex = trailers.lastValue(block, "X-Issue-Tip") orelse return false;
            const tip = Oid.parseHex(r.format(), hex) catch return false;
            const tip_commit = for (issue_history) |h| {
                if (h.oid.eql(tip)) break h;
            } else return false;
            const kept = try reachable(a, issue_history, tip);
            var at_tip: std.ArrayList(CommitInput) = .empty;
            for (issue_history) |h| if (kept.contains(h.oid.bytes)) try at_tip.append(a, h);
            const issue = issue_model.materialize(a, id, tip, at_tip.items) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return false,
            };
            const tree = try att.derivedTree(a, issue.attachments);
            const want = try attachments_mod.derivedCommitOf(
                a,
                id,
                tip,
                tip_commit.committer.time,
                tree,
                c.parents,
            );
            const data = try want.serializeAlloc(a);
            return object.hashObject(r.format(), .commit, data).eql(c.oid);
        }
    };
}

/// `version ...`, `oid sha256:<hex>`, `size <n>`, as §7 writes them.
fn isPointer(data: []const u8) bool {
    const head = "version https://git-lfs.github.com/spec/v1\noid sha256:";
    if (!std.mem.startsWith(u8, data, head)) return false;
    const rest = data[head.len..];
    if (rest.len < 64 + "\nsize 0\n".len) return false;
    for (rest[0..64]) |ch| if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return false;
    const size_line = rest[64..];
    if (!std.mem.startsWith(u8, size_line, "\nsize ") or !std.mem.endsWith(u8, size_line, "\n"))
        return false;
    const digits = size_line["\nsize ".len .. size_line.len - 1];
    if (digits.len == 0 or (digits.len > 1 and digits[0] == '0')) return false;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

// ─── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;
const GitSim = @import("../backend/GitSim.zig");

const TestServer = struct {
    arena: Allocator,
    sim: *GitSim,
    repo: repo_mod.Repo(GitSim),

    fn init(arena: Allocator, seed: u64) !TestServer {
        const world = try arena.create(GitSim.World);
        world.* = .{ .seed = seed, .clones = &.{.{ .name = "server" }} };
        const sim = try arena.create(GitSim);
        sim.* = try GitSim.init(arena, world, 0);
        return .{ .arena = arena, .sim = sim, .repo = .init(sim) };
    }

    /// Sets a ref back, as if the newer objects had only just arrived.
    fn set(s: TestServer, name: []const u8, oid: ?Oid) !void {
        const cur = try s.sim.resolveRef(name);
        const op: @import("../backend/contract.zig").RefUpdate.Op = if (oid) |o|
            if (cur) |c| .{ .update = .{ .new = o, .old = c } } else .{ .create = o }
        else
            .{ .delete = cur.? };
        try s.sim.updateRefs(&.{.{ .name = name, .op = op }});
    }

    fn check(s: TestServer, updates: []const Update, policy: Policy) ![]Verdict {
        return PushCheck(GitSim).fromRepo(s.repo).check(s.arena, updates, policy);
    }

    fn issueRef(s: TestServer, id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(s.arena, "refs/issues/{s}", .{id});
    }
};

fn hasProblem(v: Verdict, kind: ProblemKind) bool {
    for (v.problems) |p| if (p.kind == kind) return true;
    return false;
}

test "fast-forwards and creates pass; deletes, rewrites and local refs don't" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try TestServer.init(arena, 5);
    const created = try s.repo.create(arena, .{ .title = "T" }, .{});
    const ref = try s.issueRef(created.id);
    const tip = try s.repo.comment(arena, ref, .{ .text = "more" }, .{});
    const other = try s.repo.create(arena, .{ .title = "Other" }, .{});
    try s.set(ref, created.tip);
    try s.set(try s.issueRef(other.id), null);

    const vs = try s.check(&.{
        .{ .ref = ref, .old = created.tip, .new = tip.tip },
        .{ .ref = try s.issueRef(other.id), .old = null, .new = other.tip },
        .{ .ref = "refs/heads/main", .old = null, .new = tip.tip },
        .{ .ref = "refs/issuez-guard/x", .old = null, .new = tip.tip },
        .{ .ref = "refs/issues/not-a-uuid", .old = null, .new = tip.tip },
    }, .{});
    try testing.expect(vs[0].accept);
    try testing.expectEqual(Action.fast_forward, vs[0].action);
    try testing.expectEqual(@as(usize, 1), vs[0].new_commits.len);
    try testing.expect(vs[0].needs_number);
    try testing.expect(vs[1].accept);
    try testing.expectEqual(Action.create, vs[1].action);
    try testing.expectEqual(@as(usize, 1), vs[1].new_commits.len);
    try testing.expectEqual(Action.ignored, vs[2].action);
    try testing.expect(vs[2].accept);
    try testing.expect(hasProblem(vs[3], .local_ref));
    try testing.expect(hasProblem(vs[4], .bad_ref_name));

    try s.set(ref, tip.tip);
    const back = try s.check(&.{.{ .ref = ref, .old = tip.tip, .new = created.tip }}, .{});
    try testing.expectEqual(Action.rewrite, back[0].action);
    try testing.expect(hasProblem(back[0], .non_fast_forward));
    const del = try s.check(&.{.{ .ref = ref, .old = tip.tip, .new = null }}, .{});
    try testing.expect(hasProblem(del[0], .deleted));
    // A milestone is no issue: a milestone's history under refs/issues/.
    const tree_commit = try s.sim.writeObject(.commit, try (object.Commit{
        .tree = try s.sim.writeObject(.tree, try object.Tree.serializeAlloc(arena, &.{.{
            .name = "f",
            .oid = try s.sim.writeObject(.blob, "x"),
        }})),
        .parents = &.{tip.tip},
        .author = .{ .name = "a", .email = "a@x", .time = 1, .tz_offset_minutes = 0 },
        .committer = .{ .name = "a", .email = "a@x", .time = 1, .tz_offset_minutes = 0 },
        .message = "Files\n",
    }).serializeAlloc(arena));
    const files = try s.check(&.{.{ .ref = ref, .old = tip.tip, .new = tree_commit }}, .{});
    try testing.expect(hasProblem(files[0], .invalid_history));
}

test "numbers, authors and locks" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try TestServer.init(arena, 6);
    const numbered = try s.repo.create(arena, .{ .title = "N", .number = 3 }, .{});
    const taken = try s.repo.create(arena, .{ .title = "Taken", .number = 4 }, .{});
    try s.set(try s.issueRef(numbered.id), null);
    const up: Update = .{ .ref = try s.issueRef(numbered.id), .old = null, .new = numbered.tip };

    const refused = try s.check(&.{up}, .{});
    try testing.expect(hasProblem(refused[0], .number_set));
    const allowed = try s.check(&.{up}, .{ .allow_numbers = true });
    try testing.expect(allowed[0].accept);
    try testing.expect(!allowed[0].needs_number);

    // Another clone gave #4 too.
    try s.set(try s.issueRef(taken.id), taken.tip);
    const dup = try s.repo.create(arena, .{ .title = "Dup" }, .{});
    _ = dup;
    const four = try s.repo.create(arena, .{ .title = "Four" }, .{});
    _ = four;
    const clash_issue = try s.repo.create(arena, .{ .title = "Clash" }, .{});
    const clash_ref = try s.issueRef(clash_issue.id);
    const given = try s.repo.edit(arena, clash_ref, .{ .number = 5 }, .{});
    try s.set(clash_ref, null);
    const clash = try s.check(&.{
        .{ .ref = clash_ref, .old = null, .new = given.tip },
        up,
    }, .{ .allow_numbers = true });
    try testing.expect(clash[0].accept);
    _ = try s.repo.create(arena, .{ .title = "x" }, .{});

    const author: object.Signature = .{
        .name = "Mallory",
        .email = "mallory@x",
        .time = 1_700_000_000,
        .tz_offset_minutes = 0,
    };
    const lockme = try s.repo.create(arena, .{ .title = "L" }, .{});
    const lref = try s.issueRef(lockme.id);
    const locked = try s.repo.edit(arena, lref, .{ .locked = true }, .{});
    const spoofed = try s.repo.comment(arena, lref, .{ .text = "hi", .author = author }, .{});
    try s.set(lref, locked.tip);
    const lup: Update = .{ .ref = lref, .old = locked.tip, .new = spoofed.tip };
    const warn = try s.check(
        &.{lup},
        .{ .pusher_emails = &.{"SIM@example.invalid"}, .author_policy = .warn },
    );
    try testing.expect(warn[0].accept);
    try testing.expect(hasProblem(warn[0], .author_mismatch));
    try testing.expect(warn[0].touches_locked);
    const enforce = try s.check(
        &.{lup},
        .{ .pusher_emails = &.{"sim@example.invalid"}, .author_policy = .enforce },
    );
    try testing.expect(!enforce[0].accept);
    const own = try s.check(
        &.{lup},
        .{ .pusher_emails = &.{"mallory@X"}, .author_policy = .enforce },
    );
    try testing.expect(own[0].accept);
}

test "authors: only a merge that adds nothing is exempt" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try TestServer.init(arena, 6);
    const sync = @import("sync.zig");
    const sim_author: object.Signature = .{
        .name = sync.merge_identity_name,
        .email = sync.merge_identity_email,
        .time = 1_700_000_000,
        .tz_offset_minutes = 0,
    };
    const created = try s.repo.create(arena, .{ .title = "T", .labels = &.{ "b", "a" } }, .{});
    const ref = try s.issueRef(created.id);
    const tip = (try s.repo.comment(arena, ref, .{ .text = "Second" }, .{})).tip;
    try s.set(ref, tip);
    const verdict = struct {
        fn f(
            server: anytype,
            a: Allocator,
            name: []const u8,
            old: Oid,
            sig: object.Signature,
            message: []const u8,
        ) !bool {
            const new = try server.repo.writeCommit(
                a,
                &.{ old, try parentOf(server.repo, a, old) },
                .{ .author = sig, .committer = sig },
                message,
            );
            const v = try server.check(&.{.{ .ref = name, .old = old, .new = new }}, .{
                .pusher_emails = &.{"mallory@x"},
                .author_policy = .enforce,
                .allow_numbers = true,
            });
            return v[0].accept;
        }
        fn parentOf(repo: anytype, a: Allocator, oid: Oid) !Oid {
            for (try repo.loadCommits(a, oid)) |c| if (c.oid.eql(oid)) return c.parents[0];
            unreachable;
        }
    }.f;
    // What sync writes, in either order of the set, with a kept number.
    for ([_][]const u8{
        "Merge issue\n",
        "Merge issue\n\nState: open\nLabels: b, a\n",
        "Merge issue\n\nState: open\nLabels: a, b\nX-Number: 7\n",
    }) |honest| try testing.expect(try verdict(s, arena, ref, tip, sim_author, honest));
    // A field the parents don't resolve to, text, or another subject.
    for ([_][]const u8{
        "Merge issue\n\nState: closed\n",
        "Merge issue\n\nLabels: pwned\n",
        "Merge issue\n\nState: open\nX-Assignees: mallory@x\n",
        "Merge issue\n\nState: open\nReason: forged\n",
        "Merge issue\n\nA comment\n\nState: open\n",
        "Merge issue\n\nA comment\n",
        "Something else\n\nState: open\n",
    }) |forged| try testing.expect(!try verdict(s, arena, ref, tip, sim_author, forged));
    // The identity is what makes it exempt.
    var other = sim_author;
    other.email = "alice@x";
    try testing.expect(!try verdict(s, arena, ref, tip, other, "Merge issue\n"));
}

test "authors: an X-Author-Id must be the pusher's, whatever the email" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = try TestServer.init(arena, 8);
    const ada = "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d";
    const mallory = "1d9e8b63-4a2f-4c7b-8e3d-6f5a4b3c2d1e";
    // The pusher's own email on someone else's UUID.
    const forged = try s.repo.create(arena, .{ .title = "As Ada" }, .{ .author_id = ada });
    const ref = try s.issueRef(forged.id);
    try s.set(ref, null);
    const up: Update = .{ .ref = ref, .old = null, .new = forged.tip };
    const email: []const []const u8 = &.{"sim@example.invalid"};

    const enforce = try s.check(&.{up}, .{
        .pusher_emails = email,
        .pusher_ids = &.{mallory},
        .author_policy = .enforce,
    });
    try testing.expect(!enforce[0].accept and hasProblem(enforce[0], .author_mismatch));
    // No UUID given: an X-Author-Id is never the pusher's.
    const unknown = try s.check(&.{up}, .{ .pusher_emails = email, .author_policy = .enforce });
    try testing.expect(!unknown[0].accept);
    const warn = try s.check(&.{up}, .{
        .pusher_emails = email,
        .pusher_ids = &.{mallory},
        .author_policy = .warn,
    });
    try testing.expect(warn[0].accept and hasProblem(warn[0], .author_mismatch));
    const own = try s.check(&.{up}, .{
        .pusher_emails = email,
        .pusher_ids = &.{"0C8D7A52-3F1E-4B6A-9D2C-5E4F3A2B1C0D"},
        .author_policy = .enforce,
    });
    try testing.expect(own[0].accept);
    // Unchecked under .any.
    try testing.expect((try s.check(&.{up}, .{}))[0].accept);
}

test "purges: tombstones need leave, and allow the rewrite and delete" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try TestServer.init(arena, 7);
    const created = try s.repo.create(arena, .{ .title = "T" }, .{});
    const ref = try s.issueRef(created.id);
    const bad = try s.repo.comment(arena, ref, .{ .text = "Abuse" }, .{});
    const old = try s.repo.comment(arena, ref, .{ .text = "Fine" }, .{});
    const purge = purge_mod.Purge(GitSim).fromRepo(s.repo);
    const r = try purge.comment(arena, ref, bad.tip, .{ .reason = "abuse" }, .{});
    const tomb_ref = try purge_mod.refName(arena, created.id);
    const tomb = (try s.sim.resolveRef(tomb_ref)).?;
    // The server before the push.
    try s.set(ref, old.tip);
    try s.set(tomb_ref, null);
    const push = [_]Update{
        .{ .ref = ref, .old = old.tip, .new = r.tip.? },
        .{ .ref = tomb_ref, .old = null, .new = tomb },
    };
    const no = try s.check(&push, .{});
    try testing.expect(hasProblem(
        no[0],
        .purge_not_allowed,
    ) or hasProblem(no[0], .non_fast_forward));
    try testing.expect(hasProblem(no[1], .purge_not_allowed));
    const yes = try s.check(&push, .{ .allow_purge = true });
    try testing.expect(yes[0].accept);
    try testing.expect(yes[1].accept);
    try testing.expectEqual(Action.rewrite, yes[0].action);
    try testing.expectEqual(@as(usize, 0), yes[0].new_commits.len);

    // Once the tombstone is in, the purged text can't come back.
    try s.set(tomb_ref, tomb);
    const later = try s.repo.create(arena, .{ .title = "Other" }, .{});
    _ = later;
    const back = try s.check(&.{.{ .ref = ref, .old = old.tip, .new = old.tip }}, .{});
    try testing.expect(hasProblem(back[0], .purged));
    // A forged tombstone commit isn't a purge.
    const forged = try s.sim.writeObject(.commit, try (object.Commit{
        .tree = object.emptyTree(s.sim.objectFormat()),
        .parents = &.{tomb},
        .author = .{ .name = "a", .email = "a@x", .time = 1, .tz_offset_minutes = 0 },
        .committer = .{ .name = "a", .email = "a@x", .time = 1, .tz_offset_minutes = 0 },
        .message = "Hello\n\nX-Purge: comment\nX-Purged-Commit: abc\n",
    }).serializeAlloc(arena));
    const f = try s.check(
        &.{.{ .ref = tomb_ref, .old = tomb, .new = forged }},
        .{ .allow_purge = true },
    );
    try testing.expect(hasProblem(f[0], .not_a_purge));

    // A whole issue: the delete needs the tombstone and leave to purge.
    const doomed = try s.repo.create(arena, .{ .title = "Doxxing" }, .{});
    const dref = try s.issueRef(doomed.id);
    _ = try purge.issue(arena, dref, .{}, .{});
    const dtomb_ref = try purge_mod.refName(arena, doomed.id);
    const dtomb = (try s.sim.resolveRef(dtomb_ref)).?;
    try s.set(dref, doomed.tip);
    try s.set(dtomb_ref, null);
    const gone = [_]Update{
        .{ .ref = dref, .old = doomed.tip, .new = null },
        .{ .ref = dtomb_ref, .old = null, .new = dtomb },
    };
    const d = try s.check(&gone, .{ .allow_purge = true });
    try testing.expect(d[0].accept);
    try testing.expect(d[1].accept);
    const plain = try s.check(gone[0..1], .{ .allow_purge = true });
    try testing.expect(hasProblem(plain[0], .deleted));
}

test "attachments refs must be derived" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try TestServer.init(arena, 8);
    const att = attachments_mod.Attachments(GitSim).fromRepo(s.repo);
    const created = try s.repo.create(arena, .{ .title = "Login broken" }, .{});
    const ref = try s.issueRef(created.id);
    const added = try att.add(arena, ref, .{
        .files = &.{.{
            .name = "shot.png",
            .data = @import("../format/attachment.zig").samples.png,
        }},
    }, .{});
    const dname = try attachments_mod.refName(arena, created.id);
    const dtip = (try s.sim.resolveRef(dname)).?;
    try s.set(ref, created.tip);
    try s.set(dname, null);
    const ok = try s.check(&.{
        .{ .ref = ref, .old = created.tip, .new = added.tip },
        .{ .ref = dname, .old = null, .new = dtip },
    }, .{});
    try testing.expect(ok[0].accept);
    try testing.expect(ok[1].accept);
    // Without the issue tip it names, it isn't derived.
    const early = try s.check(&.{.{ .ref = dname, .old = null, .new = dtip }}, .{});
    try testing.expect(hasProblem(early[0], .not_derived));
    // Nor is a commit with a tree of its own choosing.
    const d = (try s.sim.readObject(arena, dtip)).?;
    var c = try object.Commit.parse(arena, s.sim.objectFormat(), d.data);
    c.tree = object.emptyTree(s.sim.objectFormat());
    const fake = try s.sim.writeObject(.commit, try c.serializeAlloc(arena));
    const bad = try s.check(&.{
        .{ .ref = ref, .old = created.tip, .new = added.tip },
        .{ .ref = dname, .old = null, .new = fake },
    }, .{});
    try testing.expect(hasProblem(bad[1], .not_derived));
}

//! Push check: may a push's ref updates be accepted (format.md §11)?
//!
//! For a host's pre-receive hook. It judges the format only and reads the
//! objects from the push's quarantine through the backend; nothing is
//! written. Permissions and locks stay the host's: the verdicts report
//! what it needs to decide (a missing number, commits to a locked issue).

const std = @import("std");
const assert = std.debug.assert;
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
    /// Commits of history the push may walk to resolve merges by this
    /// tool's identity (each merge walks its own). Past it, no merge of the
    /// update is exempt from the author policy.
    max_merge_work: u32 = 1_000_000,
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
    /// Fails fsck, can't be read within the limits, or has an
    /// `X-Rewritten-From` that names one of its commits or another
    /// commit's first ID.
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

/// The ancestors of merges in one history: an index built once, and walks
/// that stamp a mark per commit, so none clears anything.
const Ancestry = struct {
    history: []const CommitInput,
    index: std.AutoHashMapUnmanaged([Oid.max_byte_len]u8, usize),
    marks: []u32,
    epoch: u32 = 0,
    stack: std.ArrayList(usize) = .empty,

    fn init(arena: Allocator, history: []const CommitInput) Allocator.Error!Ancestry {
        var index: std.AutoHashMapUnmanaged([Oid.max_byte_len]u8, usize) = .empty;
        try index.ensureTotalCapacity(arena, @intCast(history.len));
        for (history, 0..) |c, i| index.putAssumeCapacity(c.oid.bytes, i);
        const marks = try arena.alloc(u32, history.len);
        @memset(marks, 0);
        return .{ .history = history, .index = index, .marks = marks };
    }

    /// The indices of the commits `parents` reach, themselves included,
    /// into `out`. False once there are more than `cap`.
    fn walk(
        a: *Ancestry,
        arena: Allocator,
        parents: []const Oid,
        cap: usize,
        out: *std.ArrayList(usize),
    ) Allocator.Error!bool {
        a.epoch += 1;
        out.clearRetainingCapacity();
        a.stack.clearRetainingCapacity();
        for (parents) |p| if (a.index.get(p.bytes)) |i| try a.stack.append(arena, i);
        while (a.stack.pop()) |i| {
            if (a.marks[i] == a.epoch) continue;
            a.marks[i] = a.epoch;
            if (out.items.len == cap) return false;
            try out.append(arena, i);
            for (a.history[i].parents) |p| if (a.index.get(p.bytes)) |j| {
                if (a.marks[j] != a.epoch) try a.stack.append(arena, j);
            };
        }
        return true;
    }
};

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
            /// What is left of `Policy.max_merge_work`.
            merge_work_left: usize,
            /// Every tombstone's purged commits, whatever issue it names:
            /// true for a purged issue's root.
            purged: std.AutoHashMapUnmanaged([Oid.max_byte_len]u8, bool) = .empty,

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
            var run: Run = .{
                .check = self,
                .arena = arena,
                .policy = policy,
                .updates = updates,
                .merge_work_left = policy.max_merge_work,
            };
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
            var tombs = run.tombs.valueIterator();
            while (tombs.next()) |t| {
                for (t.comments) |oid| try run.purged.put(arena, oid.bytes, false);
                for (t.roots) |oid| try run.purged.put(arena, oid.bytes, true);
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

        const Problems = struct {
            arena: Allocator,
            list: std.ArrayList(Problem) = .empty,

            fn add(p: *Problems, kind: ProblemKind, message: []const u8) Allocator.Error!void {
                try p.list.append(p.arena, .{ .kind = kind, .message = message });
            }

            fn at(
                p: *Problems,
                kind: ProblemKind,
                commit: Oid,
                message: []const u8,
            ) Allocator.Error!void {
                try p.list.append(p.arena, .{ .kind = kind, .commit = commit, .message = message });
            }
        };

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
                .accept = for (problems.list.items) |p| {
                    if (p.rejects) break false;
                } else true,
                .problems = problems.list.items,
            };
        }

        fn invalid(r: *Run, u: Update, id: []const u8) Error!Verdict {
            var problems: Problems = .{ .arena = r.arena };
            if (std.mem.startsWith(u8, u.ref, prefixes.local) and
                !std.mem.startsWith(u8, u.ref, prefixes.tombstones))
                try problems.add(.local_ref, "a local-only ref")
            else
                try problems.add(.bad_ref_name, "not a UUID");
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
                    try problems.add(.invalid_history, if (e == error.HistoryTooLong)
                        "history too long"
                    else
                        "history unreadable");
                    return null;
                },
                else => |x| return x,
            };
        }

        /// `tip` with `purged` purged, hashed only; null when it can't be
        /// rewritten.
        fn purgedTip(
            r: *Run,
            history: []const CommitInput,
            tip: Oid,
            purged: []const Oid,
        ) Allocator.Error!?Oid {
            const hash: purge_mod.HashOnly = .{ .format = r.format() };
            const rw = purge_mod.rewrite(r.arena, hash, history, tip, purged) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
            return rw.tip;
        }

        /// Purged text in a history under any of our refs: a purged comment
        /// as it was, or a commit of a purged issue, which has its root.
        /// Tombstones name commits, not where they are, so another UUID
        /// can't bring them back.
        fn purgedHistory(
            r: *Run,
            history: []const CommitInput,
            problems: *Problems,
        ) Allocator.Error!void {
            if (r.purged.count() == 0) return;
            for (history) |c| if (r.purged.get(c.oid.bytes)) |root| try problems.at(
                .purged,
                c.oid,
                if (root) "a purged issue's history" else "a purged comment",
            );
        }

        /// A new commit's `X-Rewritten-From` (§10) names what a purge's
        /// rewrite replaced, so nothing in the history. One that names a
        /// commit of it (the root, another's comment), or another commit's
        /// first ID, would make a purge of the commit purge that one too.
        fn rewrittenFrom(
            r: *Run,
            fresh: []const CommitInput,
            history: []const CommitInput,
            problems: *Problems,
        ) Error!void {
            const a = r.arena;
            const claims = try a.alloc(?Oid, fresh.len);
            var any = false;
            for (fresh, claims) |c, *claim| {
                claim.* = try rewrittenFromOf(r, c);
                if (claim.* != null) any = true;
            }
            if (!any) return;
            var oids: Reach = .empty;
            for (history) |c| try oids.put(a, c.oid.bytes, {});
            var firsts: std.AutoHashMapUnmanaged([Oid.max_byte_len]u8, usize) = .empty;
            for (history) |c| if (try rewrittenFromOf(r, c)) |was| {
                if (oids.contains(was.bytes)) continue;
                const e = try firsts.getOrPut(a, was.bytes);
                e.value_ptr.* = if (e.found_existing) e.value_ptr.* + 1 else 1;
            };
            for (fresh, claims) |c, claim| {
                const was = claim orelse continue;
                if (oids.contains(was.bytes)) {
                    try problems.at(.invalid_history, c.oid, "X-Rewritten-From names a commit " ++
                        "of the history");
                } else if (firsts.get(was.bytes).? > 1) {
                    try problems.at(.invalid_history, c.oid, "X-Rewritten-From is another " ++
                        "commit's too");
                }
            }
        }

        fn rewrittenFromOf(r: *Run, c: CommitInput) Allocator.Error!?Oid {
            const block = try trailers.parse(r.arena, c.message, .{});
            const was = trailers.lastValue(block, purge_mod.rewritten_from_key) orelse return null;
            return Oid.parseHex(r.format(), was) catch null;
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

        const Shape = enum {
            /// Not a merge sync writes.
            no,
            /// Adds nothing whatever its parents hold.
            yes,
            /// Adds nothing if its trailers are what its parents resolve to.
            resolve,
        };

        /// A merge under this tool's identity that adds nothing to its
        /// parents, as sync writes them (format.md §4, §6, §10), as far as
        /// its message alone tells. The identity proves nothing: anyone can
        /// write it.
        fn mergeShape(a: Allocator, c: CommitInput, kind: Kind) Error!Shape {
            if (!isSyncMerge(c)) return .no;
            const exact = switch (kind) {
                .tombstone => purge_mod.merge_subject ++ "\n",
                .milestone => "Merge milestone\n",
                .issue => "",
                else => return .no,
            };
            if (exact.len > 0) return if (std.mem.eql(u8, c.message, exact)) .yes else .no;
            const subject = @import("sync.zig").merge_subject;
            const block = try trailers.parse(a, c.message, .{});
            if (block.first_line) |line| {
                // The subject, a blank line, the trailers.
                if (line != 2 or !std.mem.eql(u8, std.mem.sliceTo(c.message, '\n'), subject))
                    return .no;
            } else if (!std.mem.eql(u8, std.mem.trimEnd(u8, c.message, "\n"), subject)) {
                return .no;
            }
            for (block.trailers) |t| {
                if (!saysNothing(t.key)) return .resolve;
            }
            return .yes;
        }

        /// Says nothing, or has its own check (§11).
        fn saysNothing(key: []const u8) bool {
            return std.ascii.eqlIgnoreCase(key, "X-Number") or
                std.ascii.eqlIgnoreCase(key, purge_mod.rewritten_from_key);
        }

        /// Whether merge `c`'s trailers are what its parents resolve to,
        /// `ancestors` the indices in `history` of the commits they reach.
        fn restatesParents(
            scratch: Allocator,
            c: CommitInput,
            id: []const u8,
            history: []const CommitInput,
            ancestors: []usize,
        ) Error!bool {
            const subject = @import("sync.zig").merge_subject;
            std.mem.sortUnstable(usize, ancestors, {}, std.sort.asc(usize));
            const before = try scratch.alloc(CommitInput, ancestors.len);
            for (before, ancestors) |*x, i| x.* = history[i];
            const resolved = issue_model.resolveMerge(
                scratch,
                id,
                before,
                c.parents,
                c.author,
                subject ++ "\n",
            ) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return false,
            };
            const restated = try issue_model.restatedTrailers(scratch, resolved);
            const block = try trailers.parse(scratch, c.message, .{});
            for (block.trailers) |t| {
                if (saysNothing(t.key)) continue;
                const same = for (restated.items) |want| {
                    if (!std.ascii.eqlIgnoreCase(want.key, t.key)) continue;
                    break try sameRestated(scratch, want, t.value);
                } else false;
                if (!same) return false;
            }
            return true;
        }

        const Exemptions = struct {
            /// Per commit.
            exempt: []const bool,
            /// The push's merge budget ran out: none was resolved.
            over: bool,
        };

        /// Which of `commits` are merges that add nothing. Resolving a merge
        /// walks its history, so a push of many merges could cost the square
        /// of its commits: the walks are counted against the push's budget
        /// first, and past it the update's merges are all judged as
        /// commits. Each resolution gets a scratch arena of its own.
        fn exemptMerges(
            r: *Run,
            commits: []const CommitInput,
            kind: Kind,
            id: []const u8,
            history: []const CommitInput,
        ) Error!Exemptions {
            const a = r.arena;
            const exempt = try a.alloc(bool, commits.len);
            var pending: std.ArrayList(usize) = .empty;
            for (commits, exempt, 0..) |c, *e, i| {
                const shape = try mergeShape(a, c, kind);
                e.* = shape == .yes;
                if (shape == .resolve) try pending.append(a, i);
            }
            if (pending.items.len == 0) return .{ .exempt = exempt, .over = false };

            var ancestry = try Ancestry.init(a, history);
            var ancestors: std.ArrayList(usize) = .empty;
            var cost: usize = 0;
            for (pending.items) |i| {
                const left = r.merge_work_left - cost;
                if (!try ancestry.walk(a, commits[i].parents, left, &ancestors))
                    return .{ .exempt = exempt, .over = true };
                cost += ancestors.items.len;
            }
            r.merge_work_left -= cost;

            var scratch_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer scratch_state.deinit();
            for (pending.items) |i| {
                _ = scratch_state.reset(.retain_capacity);
                const all = try ancestry.walk(
                    a,
                    commits[i].parents,
                    std.math.maxInt(usize),
                    &ancestors,
                );
                assert(all);
                exempt[i] = try restatesParents(
                    scratch_state.allocator(),
                    commits[i],
                    id,
                    history,
                    ancestors.items,
                );
            }
            return .{ .exempt = exempt, .over = false };
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
            const rejects = r.policy.author_policy == .enforce;
            const merges = try exemptMerges(r, commits, kind, issue_id, history);
            if (merges.over) try problems.list.append(r.arena, .{
                .kind = .author_mismatch,
                .rejects = rejects,
                .message = try std.fmt.allocPrint(
                    r.arena,
                    "too many merges to check in this push (over {d} commits of their " ++
                        "history): none of this ref's is exempt",
                    .{r.policy.max_merge_work},
                ),
            });
            for (commits, merges.exempt) |c, exempt| {
                if (exempt) continue;
                // A host's UUID names its user whatever the email says.
                if (try issue_model.authorIdOf(r.arena, c.message)) |id| {
                    const own = for (r.policy.pusher_ids) |p| {
                        if (std.ascii.eqlIgnoreCase(p, id)) break true;
                    } else false;
                    if (!own) try problems.list.append(r.arena, .{
                        .kind = .author_mismatch,
                        .rejects = rejects,
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
                try problems.list.append(r.arena, .{
                    .kind = .author_mismatch,
                    .rejects = rejects,
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
            var problems: Problems = .{ .arena = r.arena };
            const purged = if (r.tombs.get(id)) |t| t.issue else false;
            const purgeable = kind == .issue or kind == .attachments;
            if (!(purgeable and purged)) {
                try problems.add(.deleted, "deletes a ref");
            } else if (!r.policy.allow_purge) {
                try problems.add(
                    .purge_not_allowed,
                    "deleting a purged issue needs leave to purge",
                );
            }
            return verdictOf(u, kind, id, .delete, &problems);
        }

        fn tombstone(r: *Run, u: Update, id: []const u8) Error!Verdict {
            if (u.new == null) return deleteVerdict(r, u, .tombstone, id);
            const new = u.new.?;
            var problems: Problems = .{ .arena = r.arena };
            if (!r.policy.allow_purge)
                try problems.add(.purge_not_allowed, "the pusher may not purge");
            const history = (try historyOf(r, new, &problems)) orelse
                return verdictOf(u, .tombstone, id, try actionOf(r, u, null), &problems);
            const action = try actionOf(r, u, history);
            if (action == .rewrite) try problems.add(.non_fast_forward, "not a fast-forward");
            const base: ?[]const CommitInput = if (u.old) |o|
                (try historyOf(r, o, &problems)) orelse
                    return verdictOf(u, .tombstone, id, action, &problems)
            else
                null;
            const fresh = try newCommits(r, history, base);
            const empty = object.emptyTree(r.format());
            for (fresh) |c| {
                if (c.tree != null and !c.tree.?.eql(empty)) {
                    try problems.at(.not_a_purge, c.oid, "a tombstone commit with files");
                    continue;
                }
                if (!try isPurge(r.arena, r.format(), c))
                    try problems.at(.not_a_purge, c.oid, "a tombstone commit that isn't a purge");
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
            var problems: Problems = .{ .arena = a };
            const tomb: ?purge_mod.Tombstone = if (kind == .issue) r.tombs.get(id) else null;
            if (tomb) |t| if (t.issue) {
                try problems.add(.purged, "the issue is purged");
                return verdictOf(u, kind, id, try actionOf(r, u, null), &problems);
            };
            const history = (try historyOf(r, new, &problems)) orelse
                return verdictOf(u, kind, id, try actionOf(r, u, null), &problems);
            const action = try actionOf(r, u, history);
            try purgedHistory(r, history, &problems);
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
                try problems.list.append(a, .{
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
            for (problems.list.items) |p| {
                if (p.kind == .invalid_history) return verdictOf(u, kind, id, action, &problems);
            }
            for (history) |c| if (c.parents.len == 0) {
                const block = try trailers.parse(a, c.message, .{});
                const v = trailers.lastValue(block, "Format-Version") orelse "";
                if (!std.mem.eql(u8, v, "1"))
                    try problems.at(.format_version, c.oid, "Format-Version isn't 1");
            };
            const loaded = issue_model.materialize(a, id, new, history) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try problems.add(.invalid_history, "history unreadable");
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
                    try problems.add(.non_fast_forward, "not a fast-forward");
                } else if (!r.policy.allow_purge) {
                    try problems.add(.purge_not_allowed, "replacing history needs leave to purge");
                } else {
                    const rw = try purgedTip(r, old_history.?, u.old.?, tomb.?.comments);
                    if (rw == null or !contains(history, rw.?)) {
                        const message = "doesn't contain the old history, purged";
                        try problems.add(.non_fast_forward, message);
                    } else {
                        const kept = try reachable(a, history, rw.?);
                        var list: std.ArrayList(CommitInput) = .empty;
                        for (history) |c| if (kept.contains(c.oid.bytes)) try list.append(a, c);
                        base = list.items;
                    }
                }
            }
            const fresh = try newCommits(r, history, base);
            if (kind == .issue) try rewrittenFrom(r, fresh, history, &problems);

            if (tomb) |t| if (t.comments.len > 0) {
                const rw = try purgedTip(r, history, new, t.comments);
                if (rw == null or !rw.?.eql(new))
                    try problems.add(.purged, "history has purged comments");
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
                            const message = "numbers are the host's to give";
                            if (!same) try problems.at(.number_set, c.oid, message);
                        }
                    }
                } else if (loaded.number) |n| {
                    if (old_number != null and old_number.? != n) {
                        try problems.add(.number_changed, "the issue had another number");
                    } else if (old_number == null) {
                        gives_number = true;
                        if (r.numbers == null) r.numbers = try r.check.repo.numbers(a);
                        if (r.numbers.?.get(n)) |owners| for (owners.items) |o| {
                            if (std.mem.eql(u8, o.id(), id)) continue;
                            try problems.list.append(a, .{
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
            var problems: Problems = .{ .arena = a };
            const history = (try historyOf(r, new, &problems)) orelse
                return verdictOf(u, .attachments, id, try actionOf(r, u, null), &problems);
            const action = try actionOf(r, u, history);
            if (action == .rewrite) {
                if (r.tombs.get(id) == null) {
                    try problems.add(.non_fast_forward, "not a fast-forward");
                } else if (!r.policy.allow_purge) {
                    try problems.add(.purge_not_allowed, "replacing history needs leave to purge");
                }
            }
            const base = if (u.old) |o| r.check.repo.loadCommits(a, o) catch null else null;
            const fresh = try newCommits(r, history, base);
            try purgedHistory(r, history, &problems);

            const issue_tip = try issueTipAfter(r, id);
            const issue_history: []const CommitInput = if (issue_tip) |t|
                r.check.repo.loadCommits(a, t) catch &.{}
            else
                &.{};
            const att = attachments_mod.Attachments(B).fromRepo(r.check.repo);
            // The tip is what the issue derives; what led there is derived
            // commits of this issue that hold pointers (they may name tips
            // a replaced history dropped), and nothing else.
            for (fresh) |c| {
                const ok = if (c.oid.eql(new))
                    try isDerived(r, att, id, c, issue_history)
                else
                    try isRegenerate(r, id, c) and try pointersOnly(r, c);
                if (!ok) try problems.at(.not_derived, c.oid, if (c.oid.eql(new))
                    "not what the issue's attachments derive"
                else
                    "not a derived commit of this issue holding LFS pointers");
            }
            var v = verdictOf(u, .attachments, id, action, &problems);
            v.new_commits = fresh;
            return v;
        }

        /// A commit §7 writes for issue `id`, for some issue tip: its
        /// message and identity, whatever its date.
        fn isRegenerate(r: *Run, id: []const u8, c: CommitInput) Error!bool {
            const a = r.arena;
            for ([_]object.Signature{ c.author, c.committer }) |sig| {
                if (!std.mem.eql(u8, sig.name, attachments_mod.derived_identity_name) or
                    !std.mem.eql(u8, sig.email, attachments_mod.derived_identity_email))
                    return false;
            }
            const block = try trailers.parse(a, c.message, .{});
            const hex = trailers.lastValue(block, "X-Issue-Tip") orelse return false;
            const tip = Oid.parseHex(r.format(), hex) catch return false;
            const tip_hex = tip.hex();
            const want = try std.fmt.allocPrint(
                a,
                "{s}\n\nX-Issue: {s}\nX-Issue-Tip: {s}\n",
                .{ attachments_mod.derived_subject, id, tip_hex.slice() },
            );
            return std.mem.eql(u8, c.message, want);
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
    try s.set(try s.issueRef(numbered.id), null);
    const up: Update = .{ .ref = try s.issueRef(numbered.id), .old = null, .new = numbered.tip };

    const refused = try s.check(&.{up}, .{});
    try testing.expect(hasProblem(refused[0], .number_set));
    const allowed = try s.check(&.{up}, .{ .allow_numbers = true });
    try testing.expect(allowed[0].accept);
    try testing.expect(!allowed[0].needs_number);

    // Two numbers given in one push: different, so no clash.
    const other = try s.repo.create(arena, .{ .title = "Other" }, .{});
    const other_ref = try s.issueRef(other.id);
    const given = try s.repo.edit(arena, other_ref, .{ .number = 5 }, .{});
    try s.set(other_ref, null);
    const both = try s.check(&.{
        .{ .ref = other_ref, .old = null, .new = given.tip },
        up,
    }, .{ .allow_numbers = true });
    try testing.expect(both[0].accept);

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

test "numbers: taken on the server or in the push, and changed" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try TestServer.init(arena, 9);
    const numbers: Policy = .{ .allow_numbers = true };

    // Another issue on the server has #4. Writes refuse that, so #4 is given first.
    const late = try s.repo.create(arena, .{ .title = "Late" }, .{});
    const late_ref = try s.issueRef(late.id);
    const four = try s.repo.edit(arena, late_ref, .{ .number = 4 }, .{});
    try s.set(late_ref, late.tip);
    const owner = try s.repo.create(arena, .{ .title = "Owner", .number = 4 }, .{});
    const owner_ref = try s.issueRef(owner.id);
    const taken = try s.check(&.{.{ .ref = late_ref, .old = late.tip, .new = four.tip }}, numbers);
    try testing.expect(!taken[0].accept and hasProblem(taken[0], .number_taken));
    try testing.expectEqualStrings(owner.id, taken[0].problems[0].subject);

    // #4 becomes #5 on the issue that has it: only a foreign commit can say so.
    const sig: object.Signature = .{
        .name = "a",
        .email = "a@x",
        .time = 1_700_000_000,
        .tz_offset_minutes = 0,
    };
    const five = try s.repo.writeCommit(
        arena,
        &.{owner.tip},
        .{ .author = sig, .committer = sig },
        "Number\n\nX-Number: 5\n",
    );
    const changed = try s.check(&.{.{ .ref = owner_ref, .old = owner.tip, .new = five }}, numbers);
    try testing.expect(!changed[0].accept and hasProblem(changed[0], .number_changed));

    // Two new issues give #9 in one push; neither is on the server yet.
    const one = try s.repo.create(arena, .{ .title = "One", .number = 9 }, .{});
    const one_ref = try s.issueRef(one.id);
    try s.set(one_ref, null);
    const two = try s.repo.create(arena, .{ .title = "Two", .number = 9 }, .{});
    const two_ref = try s.issueRef(two.id);
    try s.set(two_ref, null);
    const pushed = try s.check(&.{
        .{ .ref = one_ref, .old = null, .new = one.tip },
        .{ .ref = two_ref, .old = null, .new = two.tip },
    }, numbers);
    try testing.expect(!pushed[0].accept and hasProblem(pushed[0], .number_taken));
    try testing.expectEqualStrings(two.id, pushed[0].problems[0].subject);
    try testing.expect(!pushed[1].accept and hasProblem(pushed[1], .number_taken));
    try testing.expectEqualStrings(one.id, pushed[1].problems[0].subject);
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

test "authors: many merges cost the push's budget, not the square of the history" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try TestServer.init(arena, 11);
    const sync = @import("sync.zig");
    const ours: object.Signature = .{
        .name = sync.merge_identity_name,
        .email = sync.merge_identity_email,
        .time = 1_700_000_000,
        .tz_offset_minutes = 0,
    };
    const me: object.Signature = .{
        .name = "m",
        .email = "m@x",
        .time = 1,
        .tz_offset_minutes = 0,
    };
    const created = try s.repo.create(arena, .{ .title = "T" }, .{});
    const ref = try s.issueRef(created.id);
    // Each merge restates a field, so each needs its parents resolved.
    const merges = 300;
    var tip = created.tip;
    for (0..merges) |i| {
        var sides: [2]Oid = undefined;
        for (&sides, 0..) |*side, j| side.* = try s.repo.writeCommit(
            arena,
            &.{tip},
            .{ .author = me, .committer = me },
            try std.fmt.allocPrint(arena, "Side {d}.{d}\n", .{ i, j }),
        );
        tip = try s.repo.writeCommit(
            arena,
            &sides,
            .{ .author = ours, .committer = ours },
            "Merge issue\n\nState: open\n",
        );
    }
    try s.set(ref, null);
    const up: Update = .{ .ref = ref, .old = null, .new = tip };
    const policy: Policy = .{
        .pusher_emails = &.{ "m@x", "sim@example.invalid" },
        .author_policy = .enforce,
    };

    const before = arena_state.queryCapacity();
    const ok = try s.check(&.{up}, policy);
    // The square of 901 commits, materialized, is gigabytes.
    try testing.expect(arena_state.queryCapacity() - before < 64 << 20);
    try testing.expect(ok[0].accept);
    try testing.expectEqual(@as(usize, 1 + 3 * merges), ok[0].new_commits.len);

    // Past the budget no merge is exempt, and the verdict says why.
    var tight = policy;
    tight.max_merge_work = 1000;
    const over = try s.check(&.{up}, tight);
    try testing.expect(!over[0].accept);
    const said = for (over[0].problems) |p| {
        if (p.commit == null and p.kind == .author_mismatch) break true;
    } else false;
    try testing.expect(said);
    // Under warn it only flags.
    tight.author_policy = .warn;
    try testing.expect((try s.check(&.{up}, tight))[0].accept);
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

test "purges: purged text can't come back under another UUID" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try TestServer.init(arena, 12);
    const purge = purge_mod.Purge(GitSim).fromRepo(s.repo);
    const fresh = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    const fresh_ref = try s.issueRef(fresh);

    // A purged comment, as it was, under a new issue.
    const created = try s.repo.create(arena, .{ .title = "Doxxing" }, .{});
    const ref = try s.issueRef(created.id);
    const bad = try s.repo.comment(arena, ref, .{ .text = "Address: 5 Foo St" }, .{});
    _ = try purge.comment(arena, ref, bad.tip, .{}, .{});
    const copy = try s.check(&.{.{ .ref = fresh_ref, .old = null, .new = bad.tip }}, .{});
    try testing.expect(!copy[0].accept and hasProblem(copy[0], .purged));
    try testing.expect(copy[0].problems[0].commit.?.eql(bad.tip));

    // A purged issue, any commit of it.
    const doomed = try s.repo.create(arena, .{ .title = "Doxx" }, .{});
    const dref = try s.issueRef(doomed.id);
    const later = try s.repo.comment(arena, dref, .{ .text = "More" }, .{});
    _ = try purge.issue(arena, dref, .{}, .{});
    const again = try s.check(&.{.{ .ref = fresh_ref, .old = null, .new = later.tip }}, .{});
    try testing.expect(!again[0].accept and hasProblem(again[0], .purged));
    // Nor as a milestone, nor under a derived ref.
    for ([_][]const u8{ "refs/milestones/", "refs/attachments/" }) |prefix| {
        const name = try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, fresh });
        const v = try s.check(&.{.{ .ref = name, .old = null, .new = later.tip }}, .{});
        try testing.expect(!v[0].accept and hasProblem(v[0], .purged));
    }

    // A tombstone in the same push counts too.
    const third = try s.repo.create(arena, .{ .title = "Third" }, .{});
    const tref = try s.issueRef(third.id);
    _ = try purge.issue(arena, tref, .{}, .{});
    const tomb_ref = try purge_mod.refName(arena, third.id);
    const tomb = (try s.sim.resolveRef(tomb_ref)).?;
    try s.set(tomb_ref, null);
    const both = try s.check(&.{
        .{ .ref = tomb_ref, .old = null, .new = tomb },
        .{ .ref = fresh_ref, .old = null, .new = third.tip },
    }, .{ .allow_purge = true });
    try testing.expect(both[0].accept);
    try testing.expect(!both[1].accept and hasProblem(both[1], .purged));
    // Other issues are untouched.
    const fine = try s.repo.create(arena, .{ .title = "Fine" }, .{});
    const kept = try s.check(&.{.{ .ref = fresh_ref, .old = null, .new = fine.tip }}, .{});
    try testing.expect(kept[0].accept);
}

test "rewrites: a new X-Rewritten-From names no commit of the history" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try TestServer.init(arena, 13);
    const created = try s.repo.create(arena, .{ .title = "Important", .body = "Body" }, .{});
    const ref = try s.issueRef(created.id);
    const bob = try s.repo.comment(arena, ref, .{ .text = "Bob" }, .{});
    const purge = purge_mod.Purge(GitSim).fromRepo(s.repo);
    // A comment the purge of an earlier one rewrote: its first ID is taken.
    const bad = try s.repo.comment(arena, ref, .{ .text = "Bad" }, .{});
    _ = try s.repo.comment(arena, ref, .{ .text = "After" }, .{});
    const purged = try purge.comment(arena, ref, bad.tip, .{}, .{});
    const who = try s.repo.identity(arena, null);
    const sync = @import("sync.zig");
    const ours: object.Signature = .{
        .name = sync.merge_identity_name,
        .email = sync.merge_identity_email,
        .time = 1_700_000_000,
        .tz_offset_minutes = 0,
    };
    const tip = purged.tip.?;
    try s.set(ref, tip);
    // The comment after the purged one was rewritten: its old ID is its
    // rewrite's first ID.
    const rewritten = for (purged.moved) |m| {
        if (!m.old.eql(bad.tip)) break m.old;
    } else unreachable;
    for ([_]Oid{ created.tip, bob.tip, rewritten }) |claimed| {
        const hex = claimed.hex();
        const message = try std.fmt.allocPrint(arena, "Spam\n\nX-Rewritten-From: {s}\n", .{
            hex.slice(),
        });
        const spam = try s.repo.writeCommit(arena, &.{tip}, who, message);
        const v = try s.check(&.{.{ .ref = ref, .old = tip, .new = spam }}, .{});
        try testing.expect(!v[0].accept and hasProblem(v[0], .invalid_history));
        // A merge that adds nothing is no exception.
        const side = try s.repo.writeCommit(arena, &.{tip}, who, "Side\n");
        const merge = try s.repo.writeCommit(
            arena,
            &.{ side, tip },
            .{ .author = ours, .committer = ours },
            try std.fmt.allocPrint(arena, "Merge issue\n\nX-Rewritten-From: {s}\n", .{
                hex.slice(),
            }),
        );
        const m = try s.check(&.{.{ .ref = ref, .old = tip, .new = merge }}, .{});
        try testing.expect(!m[0].accept and hasProblem(m[0], .invalid_history));
    }
    // One that names nothing here is a rewrite's own business.
    const fine = try s.repo.writeCommit(
        arena,
        &.{tip},
        who,
        "Moved\n\nX-Rewritten-From: 0123456789abcdef0123456789abcdef01234567\n",
    );
    try testing.expect((try s.check(&.{.{ .ref = ref, .old = tip, .new = fine }}, .{}))[0].accept);
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

    // Under a derived tip, only derived commits of this issue: not the
    // issue's own commits, which a purge may have taken.
    const tip_time = for (try s.repo.loadCommits(arena, added.tip)) |h| {
        if (h.oid.eql(added.tip)) break h.committer.time;
    } else unreachable;
    const issue = try s.repo.load(arena, .{ .name = ref, .tip = added.tip });
    const tree = try att.derivedTree(arena, issue.attachments);
    const over = struct {
        fn f(
            server: TestServer,
            a: Allocator,
            issue_id: []const u8,
            tip: Oid,
            time: i64,
            tree_oid: Oid,
            parent: Oid,
        ) !Oid {
            const commit = try attachments_mod.derivedCommitOf(
                a,
                issue_id,
                tip,
                time,
                tree_oid,
                &.{parent},
            );
            return server.sim.writeObject(.commit, try commit.serializeAlloc(a));
        }
    }.f;
    const on_issue = try over(s, arena, created.id, added.tip, tip_time, tree, created.tip);
    const carried = try s.check(&.{
        .{ .ref = ref, .old = created.tip, .new = added.tip },
        .{ .ref = dname, .old = null, .new = on_issue },
    }, .{});
    try testing.expect(!carried[1].accept and hasProblem(carried[1], .not_derived));
    try testing.expect(carried[1].problems[0].commit.?.eql(created.tip));
    // On an earlier derived commit, of this issue, it passes; another
    // issue's doesn't.
    const on_derived = try over(s, arena, created.id, added.tip, tip_time, tree, dtip);
    const chained = try s.check(&.{
        .{ .ref = ref, .old = created.tip, .new = added.tip },
        .{ .ref = dname, .old = null, .new = on_derived },
    }, .{});
    try testing.expect(chained[1].accept);
    const stranger = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    const theirs = try over(s, arena, stranger, added.tip, tip_time, tree, created.tip);
    const on_theirs = try over(s, arena, created.id, added.tip, tip_time, tree, theirs);
    const foreign = try s.check(&.{
        .{ .ref = ref, .old = created.tip, .new = added.tip },
        .{ .ref = dname, .old = null, .new = on_theirs },
    }, .{});
    try testing.expect(!foreign[1].accept and hasProblem(foreign[1], .not_derived));
}

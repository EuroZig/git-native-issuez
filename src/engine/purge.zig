//! Purge: hard deletion for moderation and legal requests (format.md §10).
//!
//! Unlike every other write, a purge removes history. A whole issue goes:
//! its ref is deleted. A comment loses its text, attachments and
//! provenance: the issue's history is rewritten from that commit on, by a
//! deterministic rule, so every clone that applies the same purges gets
//! the same commits. A tombstone, `refs/issuez-purged/<uuid>`, records
//! what was purged; it syncs like an issue, and every clone that gets it
//! applies it and never brings the purged commits back.

const std = @import("std");
const stableSort = @import("../sort.zig").stable;
const Allocator = std.mem.Allocator;
const object = @import("../backend/object.zig");
const contract = @import("../backend/contract.zig");
const trailers = @import("../format/trailers.zig");
const uuid_fmt = @import("../format/uuid.zig");
const repo_mod = @import("repo.zig");
const issue_model = @import("../model/issue.zig");

const Oid = object.Oid;
const Signature = object.Signature;

pub const ref_prefix = "refs/issuez-purged/";
pub const purge_key = "X-Purge";
pub const purged_commit_key = "X-Purged-Commit";
pub const purged_root_key = "X-Purged-Root";
pub const purged_marker_key = "X-Purged";
pub const rewritten_from_key = "X-Rewritten-From";
pub const merge_subject = "Merge purges";

/// What a tombstone says, from every commit of its chain.
pub const Tombstone = struct {
    tip: Oid,
    /// The whole issue is gone.
    issue: bool,
    /// Comment commits whose text is gone, by their original IDs.
    comments: []const Oid,
    /// The root commits of the purged issues, from `X-Purged-Root`:
    /// tombstones older than it name none. Sorted.
    roots: []const Oid = &.{},
};

/// Trailers a purged comment loses: its text's, its images', its origin's.
const dropped_keys = [_][]const u8{
    "X-Attachment",  "X-Attachment-Removed", "X-Original-Author",
    "X-Original-Id", "Provider-Comment-ID",
};

fn dropped(key: []const u8) bool {
    for (dropped_keys) |k| if (std.ascii.eqlIgnoreCase(k, key)) return true;
    return false;
}

pub fn refName(arena: Allocator, id: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}", .{ ref_prefix, id });
}

/// Null when there's no tombstone. Commits that don't read as one are
/// ignored, so a damaged chain still purges what it can.
fn read(arena: Allocator, backend: anytype, id: []const u8) !?Tombstone {
    const tip = (try backend.resolveRef(try refName(arena, id))) orelse return null;
    return try readAt(arena, backend, tip);
}

/// Internal: the library's own plumbing, not API; it may change.
pub fn readAt(arena: Allocator, backend: anytype, tip: Oid) !Tombstone {
    return readUpTo(arena, backend, tip, 100_000);
}

/// At most `limit` commits, the same ones in every clone: anyone can push a
/// chain long enough to stop every sync if that were an error.
fn readUpTo(arena: Allocator, backend: anytype, tip: Oid, limit: usize) !Tombstone {
    var out: Tombstone = .{ .tip = tip, .issue = false, .comments = &.{} };
    var comments: std.ArrayList(Oid) = .empty;
    var roots: std.ArrayList(Oid) = .empty;
    var seen: std.AutoHashMapUnmanaged([Oid.max_byte_len]u8, void) = .empty;
    var stack: std.ArrayList(Oid) = .empty;
    try stack.append(arena, tip);
    var steps: usize = 0;
    while (stack.pop()) |oid| {
        if ((try seen.getOrPut(arena, oid.bytes)).found_existing) continue;
        steps += 1;
        if (steps > limit) break;
        const o = (try backend.readObject(arena, oid)) orelse continue;
        if (o.kind != .commit) continue;
        const c = object.Commit.parse(arena, backend.objectFormat(), o.data) catch continue;
        for (c.parents) |p| try stack.append(arena, p);
        const block = try trailers.parse(arena, c.message, .{});
        const kind = trailers.lastValue(block, purge_key) orelse continue;
        const list, const key = if (std.mem.eql(u8, kind, "issue")) blk: {
            out.issue = true;
            break :blk .{ &roots, purged_root_key };
        } else if (std.mem.eql(u8, kind, "comment"))
            .{ &comments, purged_commit_key }
        else
            continue;
        for (block.trailers) |t| {
            if (!std.ascii.eqlIgnoreCase(t.key, key)) continue;
            const target = Oid.parseHex(backend.objectFormat(), t.value) catch continue;
            if (!containsOid(list.items, target)) try list.append(arena, target);
        }
    }
    sortOids(comments.items);
    sortOids(roots.items);
    out.comments = comments.items;
    out.roots = roots.items;
    return out;
}

fn sortOids(list: []Oid) void {
    stableSort(Oid, list, {}, struct {
        fn lt(_: void, a: Oid, b: Oid) bool {
            return a.order(b) == .lt;
        }
    }.lt);
}

fn containsOid(list: []const Oid, oid: Oid) bool {
    for (list) |x| if (x.eql(oid)) return true;
    return false;
}

pub const Moved = struct { old: Oid, new: Oid };

pub const Rewritten = struct {
    tip: Oid,
    /// Old commit to new, for every commit that changed.
    map: []const Moved,
};

const Index = std.AutoHashMapUnmanaged([Oid.max_byte_len]u8, usize);

/// The ID a commit had before any purge: its `X-Rewritten-From`, or its own.
/// Tombstones name comments by it, so a purge recorded after another one
/// rewrote the comment still finds it on clones that rewrote differently.
/// Anyone can write the trailer: one that names a commit still in the
/// history (the root, another's comment) is ignored, or purging this
/// commit would purge that one too. A rewrite replaces what it names.
fn firstId(
    format: object.ObjectFormat,
    oid: Oid,
    block: trailers.Block,
    history: *const Index,
) Oid {
    const was = trailers.lastValue(block, rewritten_from_key) orelse return oid;
    const first = Oid.parseHex(format, was) catch return oid;
    return if (history.contains(first.bytes)) oid else first;
}

fn indexOf(arena: Allocator, commits: []const issue_model.CommitInput) Allocator.Error!Index {
    var index: Index = .empty;
    for (commits, 0..) |c, i| try index.put(arena, c.oid.bytes, i);
    return index;
}

/// Internal: the library's own plumbing, not API; it may change.
/// The issue's history with the purged comments' text gone (format.md
/// §10), a function of the commits and `purged` alone. A commit is
/// rewritten when it is purged, a parent was rewritten, or the comment its
/// `X-Comment` names was; the rest keep their IDs, so a second run with
/// the same purges changes nothing. A merge whose moved parents ended up
/// one behind the other is dropped: it merges nothing now. Our own merges
/// that stay restate what their new parents resolve to: what they restated
/// before can override newer values once the history changes.
pub fn rewrite(
    arena: Allocator,
    backend: anytype,
    commits: []const issue_model.CommitInput,
    tip: Oid,
    purged: []const Oid,
) !Rewritten {
    const format = backend.objectFormat();
    const n = commits.len;
    const index = try indexOf(arena, commits);
    const blocks = try arena.alloc(trailers.Block, n);
    const is_purged = try arena.alloc(bool, n);
    for (commits, blocks, is_purged) |c, *b, *x| {
        b.* = try trailers.parse(arena, c.message, .{});
        x.* = containsOid(purged, firstId(format, c.oid, b.*, &index));
    }
    const new = try arena.alloc(?Oid, n);
    @memset(new, null);
    // The commits as rewritten, for what a merge's new parents hold.
    var lineage: Lineage = .empty;

    // A commit is ready once its parents and its `X-Comment` target are.
    // Events never target events, so every pass makes progress.
    var remaining = n;
    var passes: usize = 0;
    while (remaining > 0) : (passes += 1) {
        if (passes > n) return error.CorruptIssue;
        for (commits, 0..) |c, i| {
            if (new[i] != null) continue;
            const ready = for (c.parents) |p| {
                const pi = index.get(p.bytes) orelse return error.CorruptIssue;
                if (new[pi] == null) break false;
            } else true;
            if (!ready) continue;
            const block = blocks[i];
            const target: ?Oid = if (trailers.lastValue(block, "X-Comment")) |h|
                Oid.parseHex(format, h) catch null
            else
                null;
            const target_index: ?usize = if (target) |t| index.get(t.bytes) else null;
            if (target_index) |ti| if (ti != i and new[ti] == null) continue;

            const parents = try arena.alloc(Oid, c.parents.len);
            var changed = false;
            for (c.parents, parents) |p, *o| {
                o.* = new[index.get(p.bytes).?].?;
                if (!o.eql(p)) changed = true;
            }
            if (changed and parents.len > 1 and !is_purged[i]) {
                if (try lineTip(arena, &lineage, parents)) |only| {
                    new[i] = only;
                    remaining -= 1;
                    continue;
                }
            }
            const first = firstId(format, c.oid, block, &index);
            var message = c.message;
            // purgedMessage writes `X-Rewritten-From` itself.
            var stamped = trailers.lastValue(block, rewritten_from_key) != null;
            if (is_purged[i]) {
                stamped = true;
                message = try purgedMessage(arena, block, "Purged comment", "", null, first);
            } else if (target_index) |ti| {
                const event = trailers.lastValue(block, "X-Event") orelse "";
                if (is_purged[ti] and std.mem.eql(u8, event, "comment-edit")) {
                    stamped = true;
                    message = try purgedMessage(
                        arena,
                        block,
                        "Edit comment",
                        "Purged comment",
                        new[ti].?,
                        first,
                    );
                } else if (!new[ti].?.eql(target.?)) {
                    message = try retarget(arena, message, target.?, new[ti].?);
                }
            }
            if (changed and !is_purged[i] and isOwnMerge(c)) {
                stamped = true;
                message = try restatedMerge(arena, &lineage, parents, c, block, first);
            }
            changed = changed or !std.mem.eql(u8, message, c.message);
            if (!changed) {
                new[i] = c.oid;
            } else {
                if (!stamped) message = try appendTrailer(
                    arena,
                    message,
                    rewritten_from_key,
                    first,
                );
                const commit: object.Commit = .{
                    .tree = c.tree orelse object.emptyTree(format),
                    .parents = parents,
                    .author = c.author,
                    .committer = c.committer,
                    .message = message,
                };
                new[i] = try backend.writeObject(.commit, try commit.serializeAlloc(arena));
            }
            try lineage.put(arena, new[i].?.bytes, .{
                .oid = new[i].?,
                .tree = c.tree,
                .parents = parents,
                .author = c.author,
                .committer = c.committer,
                .message = message,
            });
            remaining -= 1;
        }
    }
    var map: std.ArrayList(Moved) = .empty;
    for (commits, new) |c, x| {
        if (!c.oid.eql(x.?)) try map.append(arena, .{ .old = c.oid, .new = x.? });
    }
    const tip_index = index.get(tip.bytes) orelse return error.CorruptIssue;
    return .{ .tip = new[tip_index].?, .map = map.items };
}

const Lineage = std.AutoHashMapUnmanaged([Oid.max_byte_len]u8, issue_model.CommitInput);

/// What `tip` has in its history as rewritten, itself included.
fn historyOf(
    arena: Allocator,
    lineage: *const Lineage,
    tips: []const Oid,
) Allocator.Error!std.AutoArrayHashMapUnmanaged([Oid.max_byte_len]u8, issue_model.CommitInput) {
    var seen: std.AutoArrayHashMapUnmanaged([Oid.max_byte_len]u8, issue_model.CommitInput) = .empty;
    var stack: std.ArrayList(Oid) = .empty;
    try stack.appendSlice(arena, tips);
    while (stack.pop()) |x| {
        const c = lineage.get(x.bytes) orelse continue;
        if ((try seen.getOrPut(arena, x.bytes)).found_existing) continue;
        try seen.put(arena, x.bytes, c);
        try stack.appendSlice(arena, c.parents);
    }
    return seen;
}

/// The parent that has all the others in its history, if one does.
fn lineTip(arena: Allocator, lineage: *const Lineage, parents: []const Oid) !?Oid {
    for (parents) |p| {
        const seen = try historyOf(arena, lineage, &.{p});
        for (parents) |other| {
            if (!seen.contains(other.bytes)) break;
        } else return p;
    }
    return null;
}

/// A merge commit this tool wrote (format.md §4).
fn isOwnMerge(c: issue_model.CommitInput) bool {
    const sync = @import("sync.zig");
    if (c.parents.len != 2) return false;
    if (!std.mem.eql(u8, c.author.name, sync.merge_identity_name)) return false;
    if (!std.mem.eql(u8, c.author.email, sync.merge_identity_email)) return false;
    const subject = std.mem.sliceTo(c.message, '\n');
    return std.mem.eql(u8, subject, sync.merge_subject);
}

/// The message of an own merge with new parents: what they resolve to, and
/// the number it kept, if that isn't what they resolve to.
fn restatedMerge(
    arena: Allocator,
    lineage: *const Lineage,
    parents: []const Oid,
    c: issue_model.CommitInput,
    block: trailers.Block,
    first: Oid,
) ![]const u8 {
    const sync = @import("sync.zig");
    const commits = try historyOf(arena, lineage, parents);
    var resolved = try issue_model.resolveMerge(
        arena,
        "",
        commits.values(),
        parents,
        c.author,
        sync.merge_subject ++ "\n",
    );
    // Sets have no order of their own, and every clone must write the same.
    resolved.labels = try sortedCopy(arena, resolved.labels);
    resolved.blocked_by_written = try sortedCopy(arena, resolved.blocked_by_written);
    var list = try issue_model.restatedTrailers(arena, resolved);
    if (trailers.lastValue(block, "X-Number")) |kept| {
        const now = if (resolved.number) |n| try std.fmt.allocPrint(arena, "{d}", .{n}) else "";
        if (!std.mem.eql(u8, kept, now))
            try list.append(arena, .{ .key = "X-Number", .value = kept });
    }
    try list.append(arena, .{ .key = rewritten_from_key, .value = try first.hexAlloc(arena) });
    return trailers.build(arena, sync.merge_subject, "", list.items);
}

fn sortedCopy(arena: Allocator, set: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.dupe([]const u8, set);
    stableSort([]const u8, out, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return out;
}

/// The message with its `X-Comment: <old>` trailer lines pointing at
/// `new`. Nothing else changes, not even a subject that names `old`.
fn retarget(arena: Allocator, message: []const u8, old: Oid, new: Oid) ![]const u8 {
    const old_hex = old.hex();
    const new_hex = new.hex();
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, message, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        const sep = trailers.separatorPos(line);
        const is_target = if (sep) |p|
            std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, line[0..p], " \t"), "X-Comment") and
                std.mem.eql(u8, std.mem.trim(u8, line[p + 1 ..], " \t\r"), old_hex.slice())
        else
            false;
        if (is_target) {
            try out.print(arena, "X-Comment: {s}", .{new_hex.slice()});
        } else {
            try out.appendSlice(arena, line);
        }
    }
    return out.items;
}

/// `key: oid` added to the message's trailer block (trailers.append).
fn appendTrailer(arena: Allocator, message: []const u8, key: []const u8, oid: Oid) ![]const u8 {
    const hex = oid.hex();
    return (try trailers.append(arena, message, key, hex.slice())) orelse error.CorruptIssue;
}

/// `subject` and `body`, the commit's trailers the format gives a meaning
/// minus the dropped ones (a comment's last paragraph can parse as trailers,
/// and that text must go), `X-Comment` pointing at `target` when given, then `X-Purged: true` and
/// `X-Rewritten-From: <first>`, in that order however often it runs.
fn purgedMessage(
    arena: Allocator,
    block: trailers.Block,
    subject: []const u8,
    body: []const u8,
    target: ?Oid,
    first: Oid,
) ![]const u8 {
    var list: std.ArrayList(trailers.Trailer) = .empty;
    for (block.trailers) |t| {
        if (dropped(t.key) or std.ascii.eqlIgnoreCase(t.key, purged_marker_key) or
            std.ascii.eqlIgnoreCase(t.key, rewritten_from_key) or
            !issue_model.isFormatKey(t.key)) continue;
        if (target != null and std.ascii.eqlIgnoreCase(t.key, "X-Comment")) {
            const hex = target.?.hex();
            try list.append(arena, .{
                .key = "X-Comment",
                .value = try arena.dupe(u8, hex.slice()),
            });
            continue;
        }
        try list.append(arena, t);
    }
    try list.append(arena, .{ .key = purged_marker_key, .value = "true" });
    const hex = first.hex();
    try list.append(
        arena,
        .{ .key = rewritten_from_key, .value = try arena.dupe(u8, hex.slice()) },
    );
    return trailers.build(arena, subject, body, list.items);
}

/// The message of one tombstone commit: `purged` is the comment's first
/// ID, or the issue's root.
fn tombstoneMessage(
    arena: Allocator,
    kind: enum { issue, comment },
    purged: Oid,
    reason: []const u8,
) ![]const u8 {
    var list: std.ArrayList(trailers.Trailer) = .empty;
    try list.append(arena, .{ .key = purge_key, .value = @tagName(kind) });
    const hex = purged.hex();
    try list.append(arena, .{
        .key = if (kind == .issue) purged_root_key else purged_commit_key,
        .value = try arena.dupe(u8, hex.slice()),
    });
    if (reason.len > 0) try list.append(arena, .{ .key = "Reason", .value = reason });
    const subject = if (kind == .issue) "Purge issue" else "Purge comment";
    return trailers.build(arena, subject, "", list.items);
}

pub const Spec = struct {
    /// Why, for the record: `Reason` on the tombstone commit.
    reason: []const u8 = "",
    author: ?Signature = null,
    /// Only purge while the issue tip is this one.
    expect: ?Oid = null,
};

pub const Result = struct {
    tombstone: Oid,
    /// The issue's new tip; null when the whole issue went.
    tip: ?Oid,
    /// Commits the rewrite replaced, old to new.
    moved: []const Moved,
};

pub fn Purge(comptime B: type) type {
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

        /// The tombstone of issue `id`, if any.
        pub fn tombstone(self: Self, arena: Allocator, id: []const u8) Error!?Tombstone {
            return read(arena, self.repo.backend, id);
        }

        /// Deletes the issue with its derived and bookkeeping refs, and
        /// records it in the tombstone, in one transaction.
        /// `options` as for `Repo.update`: a dry run checks and rewrites
        /// in memory, and writes no object and no ref.
        pub fn issue(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            spec: Spec,
            options: repo_mod.WriteOptions,
        ) Error!Result {
            const ref_name = try repo_mod.refFor(arena, repo_mod.issue_ref_prefix, ref_or_id);
            return self.withOptions(options).run(arena, ref_name, null, spec);
        }

        fn withOptions(self: Self, options: repo_mod.WriteOptions) Self {
            var me = self;
            me.repo = self.repo.withOptions(options);
            return me;
        }

        /// Takes a comment's text, attachments and origin, rewriting the
        /// issue from it on. `comment` is the full ID of its commit now.
        /// The issue's root holds the title and description: purge the
        /// issue instead.
        pub fn comment(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            comment_oid: Oid,
            spec: Spec,
            options: repo_mod.WriteOptions,
        ) Error!Result {
            const ref_name = try repo_mod.refFor(arena, repo_mod.issue_ref_prefix, ref_or_id);
            return self.withOptions(options).run(arena, ref_name, comment_oid, spec);
        }

        fn run(
            self: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            target: ?Oid,
            spec: Spec,
        ) Error!Result {
            const prefix = repo_mod.issue_ref_prefix;
            const ref_name = try repo_mod.refFor(arena, prefix, ref_or_id);
            if (!std.mem.startsWith(u8, ref_name, prefix) or
                !uuid_fmt.isCanonical(ref_name[prefix.len..])) return error.InvalidIssueRef;
            if (spec.reason.len > self.repo.limits.max_trailer_value_bytes) return error.TooLong;
            if (std.mem.findAny(u8, spec.reason, "\r\n") != null) return error.InvalidText;
            const id = ref_name[prefix.len..];
            const backend = self.repo.backend;
            const tomb_name = try refName(arena, id);
            var attempt: u8 = 0;
            while (attempt < self.repo.limits.cas_retries) : (attempt += 1) {
                const tip = (try backend.resolveRef(ref_name)) orelse return error.IssueDisappeared;
                if (spec.expect) |want| if (!want.eql(tip)) return error.VersionMismatch;
                const old_tomb = try backend.resolveRef(tomb_name);
                // A purged issue that came back another way (upstream's
                // merge) is purged again, whatever this purge names.
                const whole = target == null or if (old_tomb) |ot|
                    (try readAt(arena, backend, ot)).issue
                else
                    false;
                const current = try self.repo.load(arena, .{ .name = ref_name, .tip = tip });
                var ops: std.ArrayList(contract.RefUpdate) = .empty;
                var new_tip: ?Oid = null;
                var moved: []const Moved = &.{};
                var first: ?Oid = null;
                var root: ?Oid = null;
                if (if (whole) null else target) |t| {
                    const c = for (current.comments) |c| {
                        if (c.oid.eql(t) and !c.is_merge) break c;
                    } else return error.CommentNotFound;
                    const commits = try self.repo.loadCommits(arena, tip);
                    const index = try indexOf(arena, commits);
                    for (commits) |ci| if (ci.oid.eql(t)) {
                        const block = try trailers.parse(arena, ci.message, .{});
                        first = firstId(backend.objectFormat(), ci.oid, block, &index);
                    };
                    if (c.purged) if (old_tomb) |ot| {
                        // Already purged here: only a tombstone that lacks
                        // it (another tool's rewrite) needs the record.
                        const known = try readAt(arena, backend, ot);
                        if (containsOid(known.comments, first.?)) return .{
                            .tombstone = ot,
                            .tip = tip,
                            .moved = &.{},
                        };
                    };
                    const purged_set = blk: {
                        var list: std.ArrayList(Oid) = .empty;
                        if (old_tomb) |ot| try list.appendSlice(
                            arena,
                            (try readAt(arena, backend, ot)).comments,
                        );
                        if (!containsOid(list.items, first.?)) try list.append(arena, first.?);
                        break :blk list.items;
                    };
                    const r = if (self.repo.call.dry_run)
                        try rewrite(
                            arena,
                            HashOnly{ .format = backend.objectFormat() },
                            commits,
                            tip,
                            purged_set,
                        )
                    else
                        try rewrite(arena, backend, commits, tip, purged_set);
                    new_tip = r.tip;
                    moved = r.map;
                    // Purged here already (another tool's rewrite): only
                    // the tombstone records it.
                    if (!r.tip.eql(tip)) {
                        try ops.append(arena, .{
                            .name = ref_name,
                            .op = .{ .update = .{ .new = r.tip, .old = tip } },
                        });
                        const guard = try self.repo.readGuardRef(arena, id);
                        try ops.append(
                            arena,
                            .{ .name = guard.name, .op = repo_mod.moveOp(guard.old, r.tip) },
                        );
                    }
                } else {
                    // Its root names it in the tombstone, so its history
                    // can't come back under another UUID either.
                    root = current.root;
                    try ops.append(arena, .{ .name = ref_name, .op = .{ .delete = tip } });
                    const guard = try self.repo.readGuardRef(arena, id);
                    if (guard.old) |old| try ops.append(
                        arena,
                        .{ .name = guard.name, .op = .{ .delete = old } },
                    );
                    if (current.number) |n| {
                        const name = try std.fmt.allocPrint(
                            arena,
                            "{s}number-{d}",
                            .{ repo_mod.guard_ref_prefix, n },
                        );
                        if (try backend.resolveRef(name)) |old|
                            try ops.append(arena, .{ .name = name, .op = .{ .delete = old } });
                    }
                }
                // Every other local ref that still reaches the old history.
                for (try self.staleRefs(arena, id)) |r|
                    try ops.append(arena, .{ .name = r.name, .op = .{ .delete = r.oid } });

                const who = try self.repo.identity(arena, spec.author);
                const message = try self.repo.stampAuthor(arena, try tombstoneMessage(
                    arena,
                    if (whole) .issue else .comment,
                    (if (whole) root else first) orelse return error.CorruptIssue,
                    spec.reason,
                ));
                const parents: []const Oid = if (old_tomb) |o| &.{o} else &.{};
                const tomb = try self.repo.writeCommit(arena, parents, who, message);
                try ops.append(
                    arena,
                    .{ .name = tomb_name, .op = repo_mod.moveOp(old_tomb, tomb) },
                );
                if (self.repo.call.dry_run) return .{
                    .tombstone = tomb,
                    .tip = new_tip,
                    .moved = moved,
                };
                backend.updateRefs(ops.items) catch |err| switch (err) {
                    error.RefConflict => if (spec.expect != null) {
                        const now = (try backend.resolveRef(ref_name)) orelse
                            return error.IssueDisappeared;
                        if (!now.eql(tip)) return error.VersionMismatch;
                        continue;
                    } else continue,
                    else => |e| return e,
                };
                // The purge happened, so this can't fail it. The stale ref
                // went with the update, and the next sync rebuilds it.
                if (new_tip) |nt| self.rederive(arena, ref_name, nt) catch {};
                return .{ .tombstone = tomb, .tip = new_tip, .moved = moved };
            }
            return error.ConcurrentModification;
        }

        /// The derived attachment ref, sync bookkeeping and plain-fetch
        /// refs of issue `id`. After a comment purge the derived ref is
        /// rebuilt from scratch, so its history forgets the images too.
        /// Sync's `seen/` refs stay: they are the remote's refs, which the
        /// next push replaces leased on them, and the next fetch updates.
        fn staleRefs(
            self: Self,
            arena: Allocator,
            id: []const u8,
        ) Error![]const contract.RefEntry {
            const backend = self.repo.backend;
            var out: std.ArrayList(contract.RefEntry) = .empty;
            const derived = try @import("attachments.zig").refName(arena, id);
            if (try backend.resolveRef(derived)) |oid| try out.append(
                arena,
                .{ .name = derived, .oid = oid },
            );
            for ([_][]const u8{ "refs/remotes/", "refs/issuez-sync/" }) |p| {
                for (try backend.listRefs(arena, p)) |r| {
                    if (namesIssue(r.name, id) and !isSeen(r.name)) try out.append(arena, r);
                }
            }
            return out.items;
        }

        /// Internal: the library's own plumbing, not API; it may change.
        /// Brings the local issue in line with a tombstone that sync
        /// brought: deletes or rewrites it, and drops the refs that still
        /// reach the old history. Writes no tombstone commit. Returns
        /// whether anything changed.
        pub fn apply(self: Self, arena: Allocator, id: []const u8, t: Tombstone) Error!bool {
            const backend = self.repo.backend;
            const ref_name = try repo_mod.refNameOf(arena, id);
            var attempt: u8 = 0;
            while (attempt < self.repo.limits.cas_retries) : (attempt += 1) {
                var ops: std.ArrayList(contract.RefUpdate) = .empty;
                var new_tip: ?Oid = null;
                const tip = try backend.resolveRef(ref_name);
                if (tip) |old| {
                    const guard = try self.repo.readGuardRef(arena, id);
                    if (t.issue) {
                        const current = try self.repo.load(
                            arena,
                            .{ .name = ref_name, .tip = old },
                        );
                        try ops.append(arena, .{ .name = ref_name, .op = .{ .delete = old } });
                        if (guard.old) |g| try ops.append(
                            arena,
                            .{ .name = guard.name, .op = .{ .delete = g } },
                        );
                        if (current.number) |n| {
                            const name = try std.fmt.allocPrint(
                                arena,
                                "{s}number-{d}",
                                .{ repo_mod.guard_ref_prefix, n },
                            );
                            if (try backend.resolveRef(name)) |g|
                                try ops.append(arena, .{ .name = name, .op = .{ .delete = g } });
                        }
                    } else if (t.comments.len > 0) {
                        const commits = try self.repo.loadCommits(arena, old);
                        const r = try rewrite(arena, backend, commits, old, t.comments);
                        if (!r.tip.eql(old)) {
                            new_tip = r.tip;
                            try ops.append(arena, .{
                                .name = ref_name,
                                .op = .{ .update = .{ .new = r.tip, .old = old } },
                            });
                            try ops.append(
                                arena,
                                .{ .name = guard.name, .op = repo_mod.moveOp(guard.old, r.tip) },
                            );
                        }
                    }
                }
                const whole_or_moved = t.issue or new_tip != null;
                if (whole_or_moved) for (try self.staleRefs(arena, id)) |r|
                    try ops.append(arena, .{ .name = r.name, .op = .{ .delete = r.oid } });
                if (ops.items.len == 0) return false;
                backend.updateRefs(ops.items) catch |err| switch (err) {
                    error.RefConflict => continue,
                    else => |e| return e,
                };
                if (new_tip) |nt| try self.rederive(arena, ref_name, nt);
                return true;
            }
            return error.ConcurrentModification;
        }

        /// A fresh derived ref for the rewritten issue, when it has
        /// attachments; needs no LFS store.
        fn rederive(self: Self, arena: Allocator, ref_name: []const u8, tip: Oid) Error!void {
            const attachments = @import("attachments.zig");
            const now = try self.repo.load(arena, .{ .name = ref_name, .tip = tip });
            _ = try attachments.Attachments(B).fromRepo(self.repo).reconcile(arena, now, null);
        }
    };
}

fn isSeen(name: []const u8) bool {
    const prefix = "refs/issuez-sync/";
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    const rest = name[prefix.len..];
    const slash = std.mem.findScalar(u8, rest, '/') orelse return false;
    return std.mem.startsWith(u8, rest[slash + 1 ..], "seen/");
}

/// Internal: the library's own plumbing, not API; it may change.
/// Both tombstones' purges.
pub fn unionOf(arena: Allocator, a: Tombstone, b: Tombstone) Allocator.Error!Tombstone {
    var comments: std.ArrayList(Oid) = .empty;
    try comments.appendSlice(arena, a.comments);
    for (b.comments) |c| if (!containsOid(comments.items, c)) try comments.append(arena, c);
    sortOids(comments.items);
    var roots: std.ArrayList(Oid) = .empty;
    try roots.appendSlice(arena, a.roots);
    for (b.roots) |c| if (!containsOid(roots.items, c)) try roots.append(arena, c);
    sortOids(roots.items);
    return .{
        .tip = b.tip,
        .issue = a.issue or b.issue,
        .comments = comments.items,
        .roots = roots.items,
    };
}

/// `.../issues/<id>`, `.../attachments/<id>`, or one of sync's
/// `.../issues/<id>/<tip>` refs.
fn namesIssue(name: []const u8, id: []const u8) bool {
    for ([_][]const u8{ "/issues/", "/attachments/" }) |ns| {
        var at: usize = 0;
        while (std.mem.findPos(u8, name, at, ns)) |i| : (at = i + 1) {
            const rest = name[i + ns.len ..];
            if (!std.mem.startsWith(u8, rest, id)) continue;
            if (rest.len == id.len or rest[id.len] == '/') return true;
        }
    }
    return false;
}

/// Internal: the library's own plumbing, not API; it may change.
/// `rewrite`'s backend when nothing may be written, a dry run or a check:
/// hashes the objects, writes none.
pub const HashOnly = struct {
    format: object.ObjectFormat,

    pub fn objectFormat(h: HashOnly) object.ObjectFormat {
        return h.format;
    }

    pub fn writeObject(h: HashOnly, kind: object.ObjectKind, data: []const u8) error{}!Oid {
        return object.hashObject(h.format, kind, data);
    }
};

const GitSim = @import("../backend/GitSim.zig");
const TestRepo = @import("test_repo.zig").TestRepo;

test "a tombstone chain past the limit is read up to it" {
    var fx: TestRepo = .{};
    defer fx.deinit();
    const arena, const sim, const repo = try fx.open(5);
    const who = try repo.identity(arena, null);
    const first = try repo.writeCommit(arena, &.{}, who, "Purge issue\n\nX-Purge: issue\n");
    const second = try repo.writeCommit(arena, &.{first}, who, "Other\n");
    const third = try repo.writeCommit(arena, &.{second}, who, "Other\n");
    try std.testing.expect((try readUpTo(arena, sim, third, 3)).issue);
    try std.testing.expect(!(try readUpTo(arena, sim, third, 2)).issue);
}

test "purging a comment rewrites the issue, twice changes nothing" {
    var fx: TestRepo = .{};
    defer fx.deinit();
    const arena, const sim, const repo = try fx.open(3);
    const created, const ref = try fx.issue(.{ .title = "T" });
    const bad = try repo.comment(arena, ref, .{ .text = "Abuse" }, .{});
    _ = try repo.commentEvent(
        arena,
        ref,
        .{ .target = bad.tip, .event = .edit, .text = "Worse abuse" },
        .{},
    );
    _ = try repo.react(arena, ref, .{ .target = bad.tip, .emoji = ":-1:", .present = true }, .{});
    const tip = try repo.comment(arena, ref, .{ .text = "Fine" }, .{});

    const purge = Purge(GitSim).fromRepo(repo);
    const r = try purge.comment(arena, ref, bad.tip, .{ .reason = "abuse" }, .{});
    try std.testing.expect(!r.tip.?.eql(tip.tip));
    try std.testing.expect((try sim.resolveRef(ref)).?.eql(r.tip.?));
    const t = (try purge.tombstone(arena, created.id)).?;
    try std.testing.expect(!t.issue);
    try std.testing.expectEqual(@as(usize, 1), t.comments.len);
    try std.testing.expect(t.comments[0].eql(bad.tip));

    const commits = try repo.loadCommits(arena, r.tip.?);
    const again = try rewrite(arena, sim, commits, r.tip.?, t.comments);
    try std.testing.expect(again.tip.eql(r.tip.?));
    try std.testing.expectEqual(@as(usize, 0), again.map.len);

    const issue = try repo.load(arena, .{ .name = ref, .tip = r.tip.? });
    try std.testing.expectEqual(@as(usize, 2), issue.comments.len);
    const gone = issue.comments[0];
    try std.testing.expect(gone.purged);
    try std.testing.expectEqualStrings("Purged comment", gone.subject);
    for (gone.history) |rev| try std.testing.expect(std.mem.find(u8, rev.text, "buse") == null);
    try std.testing.expectEqualStrings("Fine", issue.comments[1].subject);
    // The reaction moved with the comment.
    try std.testing.expectEqual(@as(usize, 1), issue.reactions.len);
    try std.testing.expect(issue.reactions[0].target.?.eql(gone.oid));
    for (commits) |c| try std.testing.expect(std.mem.find(u8, c.message, "buse") == null);

    // A second purge names the later comment by its first ID.
    const fine = issue.comments[1].oid;
    const r2 = try purge.comment(arena, ref, fine, .{}, .{});
    const t2 = (try purge.tombstone(arena, created.id)).?;
    try std.testing.expectEqual(@as(usize, 2), t2.comments.len);
    try std.testing.expect(containsOid(t2.comments, tip.tip));
    const from_scratch = try rewrite(
        arena,
        sim,
        try repo.loadCommits(arena, tip.tip),
        tip.tip,
        t2.comments,
    );
    try std.testing.expect(from_scratch.tip.eql(r2.tip.?));
}

test "a merge a purge leaves nothing to merge is dropped" {
    var fx: TestRepo = .{};
    defer fx.deinit();
    const arena, const sim, const repo = try fx.open(3);
    _, const ref = try fx.issue(.{ .title = "T" });
    const bad = try repo.comment(arena, ref, .{ .text = "Abuse" }, .{});
    const purged: []const Oid = &.{bad.tip};
    const other = try rewrite(arena, sim, try repo.loadCommits(arena, bad.tip), bad.tip, purged);
    const newer = try repo.comment(arena, ref, .{ .text = "Newer" }, .{});

    // Merging the purged copy with the unpurged one restates stale values.
    const sig: object.Signature = .{
        .name = "x",
        .email = "x@invalid",
        .time = 9,
        .tz_offset_minutes = 0,
    };
    const merge = try repo.writeCommit(
        arena,
        &.{ newer.tip, other.tip },
        .{ .author = sig, .committer = sig },
        "Merge issue\n\nState: closed\n",
    );
    const after = try repo.writeCommit(
        arena,
        &.{merge},
        .{ .author = sig, .committer = sig },
        "After\n",
    );
    const r = try rewrite(arena, sim, try repo.loadCommits(arena, after), after, purged);

    const linear = try rewrite(
        arena,
        sim,
        try repo.loadCommits(arena, newer.tip),
        newer.tip,
        purged,
    );
    const commits = try repo.loadCommits(arena, r.tip);
    for (commits) |c| try std.testing.expect(c.parents.len <= 1);
    const top = try object.Commit.parse(arena, .sha1, (try sim.readObject(arena, r.tip)).?.data);
    try std.testing.expect(top.parents[0].eql(linear.tip));
    for (r.map) |m| {
        if (m.old.eql(merge)) try std.testing.expect(m.new.eql(linear.tip));
    }
    const again = try rewrite(arena, sim, commits, r.tip, purged);
    try std.testing.expect(again.tip.eql(r.tip));
    try std.testing.expectEqual(@as(usize, 0), again.map.len);

    // Still concurrent after the purge: the merge stays.
    const side = try repo.writeCommit(
        arena,
        &.{other.tip},
        .{ .author = sig, .committer = sig },
        "Side\n",
    );
    const real = try repo.writeCommit(
        arena,
        &.{ newer.tip, side },
        .{ .author = sig, .committer = sig },
        "Merge issue\n",
    );
    const kept = try rewrite(arena, sim, try repo.loadCommits(arena, real), real, purged);
    const kept_object = (try sim.readObject(arena, kept.tip)).?;
    const kept_commit = try object.Commit.parse(arena, .sha1, kept_object.data);
    try std.testing.expectEqual(@as(usize, 2), kept_commit.parents.len);
}

test "an own merge that stays restates what its new parents resolve to" {
    const sync = @import("sync.zig");
    var fx: TestRepo = .{};
    defer fx.deinit();
    const arena, const sim, const repo = try fx.open(3);
    _, const ref = try fx.issue(.{ .title = "T" });
    const bad = try repo.comment(arena, ref, .{ .text = "Abuse" }, .{});
    const purged: []const Oid = &.{bad.tip};
    const person: object.Signature = .{
        .name = "x",
        .email = "x@invalid",
        .time = 9,
        .tz_offset_minutes = 0,
    };
    const ours: object.Signature = .{
        .name = sync.merge_identity_name,
        .email = sync.merge_identity_email,
        .time = 9,
        .tz_offset_minutes = 0,
    };
    const side = try repo.writeCommit(
        arena,
        &.{bad.tip},
        .{ .author = person, .committer = person },
        "Side\n\nPriority: low\n",
    );
    const closed = try repo.writeCommit(
        arena,
        &.{bad.tip},
        .{ .author = person, .committer = person },
        "Closed\n\nState: closed\nPriority: high\n",
    );
    // What it restates no longer holds: a stale merge, as a dropped one leaves.
    const merge = try repo.writeCommit(
        arena,
        &.{ side, closed },
        .{ .author = ours, .committer = ours },
        sync.merge_subject ++ "\n\nState: open\nX-Number: 7\n",
    );
    const r = try rewrite(arena, sim, try repo.loadCommits(arena, merge), merge, purged);
    const top = try object.Commit.parse(arena, .sha1, (try sim.readObject(arena, r.tip)).?.data);
    try std.testing.expectEqual(@as(usize, 2), top.parents.len);
    const block = try trailers.parse(arena, top.message, .{});
    try std.testing.expectEqualStrings("closed", trailers.lastValue(block, "State").?);
    try std.testing.expectEqualStrings("7", trailers.lastValue(block, "X-Number").?);
    try std.testing.expect(trailers.lastValue(block, rewritten_from_key) != null);

    const again = try rewrite(arena, sim, try repo.loadCommits(arena, r.tip), r.tip, purged);
    try std.testing.expect(again.tip.eql(r.tip));
    try std.testing.expectEqual(@as(usize, 0), again.map.len);
}

test "purging an issue deletes it and its refs" {
    var fx: TestRepo = .{};
    defer fx.deinit();
    const arena, const sim, const repo = try fx.open(3);
    const created, const ref = try fx.issue(.{ .title = "Doxxing", .number = 7 });
    const purge = Purge(GitSim).fromRepo(repo);
    const r = try purge.issue(arena, ref, .{ .reason = "legal" }, .{});
    try std.testing.expect(r.tip == null);
    try std.testing.expect(try sim.resolveRef(ref) == null);
    try std.testing.expect(try sim.resolveRef("refs/issuez-guard/number-7") == null);
    const t = (try purge.tombstone(arena, created.id)).?;
    try std.testing.expect(t.issue);
    // The root names the issue's history whatever its UUID.
    try std.testing.expectEqual(@as(usize, 1), t.roots.len);
    try std.testing.expect(t.roots[0].eql(created.tip));
    try std.testing.expectError(error.IssueDisappeared, purge.issue(arena, ref, .{}, .{}));

    // A tombstone written before roots were recorded still purges.
    const who = try repo.identity(arena, null);
    const old = try repo.writeCommit(arena, &.{}, who, "Purge issue\n\nX-Purge: issue\n");
    const back = try readAt(arena, sim, old);
    try std.testing.expect(back.issue and back.roots.len == 0);
}

test "a purged issue that came back is purged again, even by a comment purge" {
    var fx: TestRepo = .{};
    defer fx.deinit();
    const arena, const sim, const repo = try fx.open(3);
    const created, const ref = try fx.issue(.{ .title = "Doxxing" });
    const c = try repo.comment(arena, ref, .{ .text = "More" }, .{});
    const purge = Purge(GitSim).fromRepo(repo);
    _ = try purge.issue(arena, ref, .{}, .{});
    // Another tool (upstream's merge) brings the ref back.
    try sim.updateRefs(&.{.{ .name = ref, .op = .{ .create = c.tip } }});
    const r = try purge.comment(arena, ref, c.tip, .{}, .{});
    try std.testing.expect(r.tip == null);
    try std.testing.expect(try sim.resolveRef(ref) == null);
    try std.testing.expect((try purge.tombstone(arena, created.id)).?.issue);
}

test "a forged X-Rewritten-From purges only its own commit" {
    var fx: TestRepo = .{};
    defer fx.deinit();
    const arena, _, const repo = try fx.open(9);
    const created, const ref = try fx.issue(.{ .title = "Important", .body = "Body" });
    const bob = try repo.comment(arena, ref, .{ .text = "Bob's comment" }, .{});
    const who = try repo.identity(arena, null);
    // Spam that claims to be the root once, Bob's comment once.
    var spam: [2]Oid = undefined;
    var tip = bob.tip;
    for ([_]Oid{ created.tip, bob.tip }, &spam) |claimed, *out| {
        const hex = claimed.hex();
        const message = try std.fmt.allocPrint(arena, "Spam\n\n{s}: {s}\n", .{
            rewritten_from_key,
            hex.slice(),
        });
        tip = try repo.writeCommit(arena, &.{tip}, who, message);
        out.* = tip;
    }
    const op: contract.RefUpdate.Op = .{ .update = .{ .new = tip, .old = bob.tip } };
    try fx.sim.updateRefs(&.{.{ .name = ref, .op = op }});
    const purge = Purge(GitSim).fromRepo(repo);
    _ = try purge.comment(arena, ref, spam[0], .{}, .{});
    const now = (try fx.sim.resolveRef(ref)).?;
    const issue = try repo.load(arena, .{ .name = ref, .tip = now });
    try std.testing.expectEqual(spam[0], (try purge.tombstone(arena, created.id)).?.comments[0]);
    const r = try purge.comment(arena, ref, issue.comments[2].oid, .{}, .{});
    const after = try repo.load(arena, .{ .name = ref, .tip = r.tip.? });
    try std.testing.expectEqualStrings("Important", after.title);
    try std.testing.expectEqualStrings("Body", after.description);
    try std.testing.expect(!after.comments[0].purged);
    try std.testing.expectEqualStrings("Bob's comment", after.comments[0].subject);
    try std.testing.expect(after.comments[1].purged and after.comments[2].purged);
}

test "a purged comment loses its origin, keeps its fields" {
    var fx: TestRepo = .{};
    defer fx.deinit();
    const arena, _, const repo = try fx.open(5);
    _, const ref = try fx.issue(.{ .title = "T" });
    const bad = try repo.comment(arena, ref, .{
        .text = "Imported abuse",
        .original = .{ .author = "troll", .id = "gh-1" },
    }, .{});
    const r = try Purge(GitSim).fromRepo(repo).comment(arena, ref, bad.tip, .{}, .{});
    for (try repo.loadCommits(arena, r.tip.?)) |c| {
        try std.testing.expect(std.mem.find(u8, c.message, "troll") == null);
        try std.testing.expect(std.mem.find(u8, c.message, "gh-1") == null);
    }
    const issue = try repo.load(arena, .{ .name = ref, .tip = r.tip.? });
    try std.testing.expect(issue.comments[0].original_author == null);
}

test "a purged comment's text that parses as trailers goes, its fields stay" {
    var fx: TestRepo = .{};
    defer fx.deinit();
    const arena, const sim, const repo = try fx.open(5);
    const created, const ref = try fx.issue(.{ .title = "T" });
    const who = try repo.identity(arena, null);
    // As upstream writes it, which doesn't refuse such a comment.
    const bad = try repo.writeCommit(
        arena,
        &.{created.tip},
        who,
        "Call me\n\nPhone: 555-1234\nX-Home: 5 Foo St\nState: closed\n",
    );
    try sim.updateRefs(&.{.{
        .name = ref,
        .op = .{ .update = .{ .new = bad, .old = created.tip } },
    }});
    const r = try Purge(GitSim).fromRepo(repo).comment(arena, ref, bad, .{}, .{});
    for (try repo.loadCommits(arena, r.tip.?)) |c| {
        try std.testing.expect(std.mem.find(u8, c.message, "555-1234") == null);
        try std.testing.expect(std.mem.find(u8, c.message, "5 Foo St") == null);
    }
    const issue = try repo.load(arena, .{ .name = ref, .tip = r.tip.? });
    try std.testing.expectEqualStrings("closed", issue.state.text());
}

test "purge: a dry run rewrites in memory and writes nothing" {
    var fx: TestRepo = .{};
    defer fx.deinit();
    const arena, const sim, const repo = try fx.open(63);
    const created, const ref = try fx.issue(.{ .title = "T" });
    const bad = try repo.comment(arena, ref, .{ .text = "Abuse" }, .{});
    const tip = try repo.comment(arena, ref, .{ .text = "Fine" }, .{});
    const purge = Purge(GitSim).fromRepo(repo);

    const dry = try purge.comment(
        arena,
        ref,
        bad.tip,
        .{ .reason = "abuse" },
        .{ .dry_run = true },
    );
    try std.testing.expect(!dry.tip.?.eql(tip.tip));
    try std.testing.expect((try sim.resolveRef(ref)).?.eql(tip.tip));
    try std.testing.expect(try sim.readObject(arena, dry.tip.?) == null);
    try std.testing.expect(try purge.tombstone(arena, created.id) == null);
    _ = try purge.issue(arena, ref, .{}, .{ .dry_run = true });
    try std.testing.expect((try sim.resolveRef(ref)).?.eql(tip.tip));

    const ada = "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d";
    const done = try purge.comment(
        arena,
        ref,
        bad.tip,
        .{ .reason = "abuse" },
        .{ .author_id = ada },
    );
    const obj = (try sim.readObject(arena, done.tombstone)).?;
    try std.testing.expect(std.mem.find(u8, obj.data, ada) != null);
}

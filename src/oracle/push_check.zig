//! The oracle's own statement of the push check (format.md §11): what
//! each update of a push should get, from the raw objects of the receiving
//! clone with the push's objects added. Doesn't import the engine.

const std = @import("std");
const stableSort = @import("issuez").sort.stable;
const Allocator = std.mem.Allocator;
const issuez = @import("issuez");
const object = issuez.backend.object;
const trailers = issuez.format.trailers;
const commands = @import("commands.zig");
const purge = @import("purge.zig");

pub const Authors = enum { any, warn, enforce };

pub const Policy = struct {
    pusher_emails: []const []const u8 = &.{},
    authors: Authors = .any,
    allow_numbers: bool = false,
    allow_purge: bool = false,
};

/// Hex IDs; null for no ref.
pub const Update = struct { ref: []const u8, old: ?[]const u8, new: ?[]const u8 };

pub const Expect = struct {
    action: []const u8,
    accept: bool,
    /// Problem kinds by the engine's names, each once, sorted.
    kinds: []const []const u8,
    /// Kinds that only flag (an author under `warn`).
    flags: []const []const u8 = &.{},
    /// `<kind>@<commit hex>` for the problems of one commit: not_derived,
    /// not_a_purge, author_mismatch, number_set.
    at: []const []const u8 = &.{},
    needs_number: bool = false,
    touches_locked: bool = false,
    /// Null when not counted (refused before the history was read).
    new_count: ?usize = null,
    /// The oracle can't read this history: don't compare.
    skip: bool = false,
};

const merge_email = "git-issue@invalid";

const Kinds = struct {
    arena: Allocator,
    rejects: std.ArrayList([]const u8) = .empty,
    flags: std.ArrayList([]const u8) = .empty,
    at: std.ArrayList([]const u8) = .empty,

    fn addAt(k: *Kinds, kind: []const u8, hex: []const u8, rejects: bool) Allocator.Error!void {
        if (rejects) try k.add(kind) else try k.flag(kind);
        const tag = try std.fmt.allocPrint(k.arena, "{s}@{s}", .{ kind, hex });
        if (!commands.containsText(k.at.items, tag)) try k.at.append(k.arena, tag);
    }

    fn add(k: *Kinds, kind: []const u8) Allocator.Error!void {
        if (!commands.containsText(k.rejects.items, kind)) try k.rejects.append(k.arena, kind);
    }

    fn flag(k: *Kinds, kind: []const u8) Allocator.Error!void {
        if (!commands.containsText(k.flags.items, kind)) try k.flags.append(k.arena, kind);
    }

    fn done(k: *Kinds, action: []const u8) Allocator.Error!Expect {
        const all = try std.mem.concat(k.arena, []const u8, &.{ k.rejects.items, k.flags.items });
        var unique: std.ArrayList([]const u8) = .empty;
        for (all) |x| if (!commands.containsText(unique.items, x)) try unique.append(k.arena, x);
        stableSort([]const u8, unique.items, {}, lessText);
        return .{
            .action = action,
            .accept = k.rejects.items.len == 0,
            .kinds = unique.items,
            .flags = k.flags.items,
            .at = k.at.items,
        };
    }
};

fn lessText(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const Ours = enum { other, issue, milestone, attachments, tombstone, local, bad_name };

fn classify(ref: []const u8) struct { Ours, []const u8 } {
    const ours = [_]struct { []const u8, Ours }{
        .{ "refs/issues/", .issue },
        .{ "refs/milestones/", .milestone },
        .{ "refs/attachments/", .attachments },
        .{ "refs/issuez-purged/", .tombstone },
    };
    for (ours) |o| if (std.mem.startsWith(u8, ref, o[0])) {
        const id = ref[o[0].len..];
        return .{ if (isUuid(id)) o[1] else .bad_name, id };
    };
    if (std.mem.startsWith(u8, ref, "refs/issuez-")) return .{ .local, "" };
    return .{ .other, "" };
}

/// Lowercase, hyphenated, version 4, RFC variant.
fn isUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |ch, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (dash != (ch == '-')) return false;
        if (!dash and !std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return false;
    }
    return s[14] == '4' and std.mem.findScalar(u8, "89ab", s[19]) != null;
}

/// The commits reachable from `tip`, or null when one is missing.
fn history(
    c: commands.Clone,
    tip: []const u8,
) Allocator.Error!?std.StringArrayHashMapUnmanaged(object.Commit) {
    var out: std.StringArrayHashMapUnmanaged(object.Commit) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(c.arena, tip);
    while (stack.pop()) |hex| {
        if (out.contains(hex)) continue;
        const cm = c.commit(hex) orelse return null;
        try out.put(c.arena, hex, cm);
        for (cm.parents) |p| try stack.append(c.arena, try p.hexAlloc(c.arena));
    }
    return out;
}

/// Reachable from `tip` inside `within`.
fn reachIn(
    arena: Allocator,
    within: std.StringArrayHashMapUnmanaged(object.Commit),
    tip: []const u8,
) Allocator.Error!std.StringHashMapUnmanaged(void) {
    var out: std.StringHashMapUnmanaged(void) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(arena, tip);
    while (stack.pop()) |hex| {
        const cm = within.get(hex) orelse continue;
        if ((try out.getOrPut(arena, hex)).found_existing) continue;
        for (cm.parents) |p| try stack.append(arena, try p.hexAlloc(arena));
    }
    return out;
}

/// Reachable from `tip` as far as the objects go.
fn reachPartial(
    c: commands.Clone,
    tip: []const u8,
) Allocator.Error!std.StringHashMapUnmanaged(void) {
    var out: std.StringHashMapUnmanaged(void) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(c.arena, tip);
    while (stack.pop()) |hex| {
        if ((try out.getOrPut(c.arena, hex)).found_existing) continue;
        const cm = c.commit(hex) orelse continue;
        for (cm.parents) |p| try stack.append(c.arena, try p.hexAlloc(c.arena));
    }
    return out;
}

fn actionOf(c: commands.Clone, u: Update) Allocator.Error![]const u8 {
    const old = u.old orelse return "create";
    const new = u.new orelse return "delete";
    if (std.mem.eql(u8, old, new)) return "fast_forward";
    return if ((try reachPartial(c, new)).contains(old)) "fast_forward" else "rewrite";
}

const Run = struct {
    c: commands.Clone,
    policy: Policy,
    updates: []const Update,
    tombs: std.StringHashMapUnmanaged(purge.Tomb) = .empty,
    /// Per update index: the number it newly gives.
    given: []?[]const u8,
};

pub fn expect(
    c: commands.Clone,
    updates: []const Update,
    policy: Policy,
) (Allocator.Error || error{NoRule})![]Expect {
    const arena = c.arena;
    var run: Run = .{
        .c = c,
        .policy = policy,
        .updates = updates,
        .given = try arena.alloc(?[]const u8, updates.len),
    };
    @memset(run.given, null);
    for (c.clone.refs) |r| {
        if (!std.mem.startsWith(u8, r.name, purge.prefix)) continue;
        const id = r.name[purge.prefix.len..];
        if (!isUuid(id)) continue;
        try run.tombs.put(arena, id, try purge.read(c, r.oid));
    }
    const out = try arena.alloc(Expect, updates.len);
    for (updates, out) |u, *e| {
        const kind, const id = classify(u.ref);
        if (kind != .tombstone) continue;
        e.* = try tombstone(&run, u);
        if (!e.accept) continue;
        const new = u.new orelse continue;
        const t = try purge.read(c, new);
        const old = run.tombs.get(id) orelse purge.Tomb{};
        try run.tombs.put(arena, id, .{
            .issue = old.issue or t.issue,
            .comments = try unionText(arena, old.comments, t.comments),
        });
    }
    for (updates, out, 0..) |u, *e, i| {
        const kind, const id = classify(u.ref);
        e.* = switch (kind) {
            .tombstone => continue,
            .other => .{ .action = "ignored", .accept = true, .kinds = &.{} },
            .local, .bad_name => blk: {
                var k: Kinds = .{ .arena = arena };
                try k.add(if (kind == .local) "local_ref" else "bad_ref_name");
                break :blk try k.done(try actionOf(c, u));
            },
            .issue, .milestone => try issueOrMilestone(&run, u, kind, id, i),
            .attachments => try attachments(&run, u, id),
        };
    }
    // Two issues newly given one number in the same push.
    if (policy.allow_numbers) for (run.given, 0..) |g, i| {
        const n = g orelse continue;
        const own = classify(updates[i].ref)[1];
        for (run.given, 0..) |h, j| {
            if (i == j) continue;
            const m = h orelse continue;
            if (!std.mem.eql(
                u8,
                n,
                m,
            ) or std.mem.eql(u8, own, classify(updates[j].ref)[1])) continue;
            var k: Kinds = .{ .arena = arena };
            for (out[i].kinds) |x| {
                if (commands.containsText(out[i].flags, x)) try k.flag(x) else try k.add(x);
            }
            try k.add("number_taken");
            try k.at.appendSlice(arena, out[i].at);
            const was = out[i];
            out[i] = try k.done(was.action);
            out[i].needs_number = was.needs_number;
            out[i].touches_locked = was.touches_locked;
            out[i].new_count = was.new_count;
            out[i].skip = was.skip;
            break;
        }
    };
    return out;
}

fn unionText(
    arena: Allocator,
    a: []const []const u8,
    b: []const []const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(arena, a);
    for (b) |x| if (!commands.containsText(out.items, x)) try out.append(arena, x);
    return out.items;
}

fn deleteOf(r: *Run, kind: Ours, id: []const u8) Allocator.Error!Expect {
    var k: Kinds = .{ .arena = r.c.arena };
    const purged = if (r.tombs.get(id)) |t| t.issue else false;
    if (!((kind == .issue or kind == .attachments) and purged)) {
        try k.add("deleted");
    } else if (!r.policy.allow_purge) try k.add("purge_not_allowed");
    return k.done("delete");
}

/// format.md §11: a merge under the tool's identity is exempt when it adds
/// nothing: its subject, and at most what its parents resolve to, a kept
/// number and `X-Rewritten-From`.
fn mergeAddsNothing(r: *Run, cm: object.Commit, ours: Ours) Allocator.Error!bool {
    if (cm.parents.len < 2 or !std.mem.eql(u8, cm.author.email, merge_email)) return false;
    const arena = r.c.arena;
    switch (ours) {
        .tombstone => return std.mem.eql(u8, cm.message, "Merge purges\n"),
        .milestone => return std.mem.eql(u8, cm.message, "Merge milestone\n"),
        .issue => {},
        else => return false,
    }
    const rest = std.mem.trimEnd(u8, cm.message, "\n");
    if (std.mem.eql(u8, rest, "Merge issue")) return true;
    if (!std.mem.startsWith(u8, rest, "Merge issue\n\n")) return false;
    const lines = rest["Merge issue\n\n".len..];
    if (std.mem.find(u8, lines, "\n\n") != null) return false;
    const block = try commands.trailersOf(arena, cm.message);
    if (block.first_line == null) return false;
    var parents: std.ArrayList([]const u8) = .empty;
    for (cm.parents) |p| try parents.append(arena, try p.hexAlloc(arena));
    const n = r.c.naiveAt(parents.items) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // No rule for this history: don't judge it.
        else => return true,
    };
    const want = try commands.restatedBy(arena, n);
    for (block.trailers) |t| {
        if (std.ascii.eqlIgnoreCase(t.key, "X-Number") or
            std.ascii.eqlIgnoreCase(t.key, "X-Rewritten-From")) continue;
        const same = for (want.items) |w| {
            if (!std.ascii.eqlIgnoreCase(w.key, t.key)) continue;
            break try sameSet(arena, w.key, w.value, t.value);
        } else false;
        if (!same) return false;
    }
    return true;
}

/// Equal values; `Labels` and `X-Blocked-By` in any order.
fn sameSet(arena: Allocator, key: []const u8, a: []const u8, b: []const u8) Allocator.Error!bool {
    if (!std.mem.eql(u8, key, "Labels") and !std.mem.eql(u8, key, "X-Blocked-By"))
        return std.mem.eql(u8, a, b);
    var lists: [2]std.ArrayList([]const u8) = .{ .empty, .empty };
    for ([_][]const u8{ a, b }, &lists) |text, *list| {
        var it = std.mem.splitScalar(u8, text, ',');
        while (it.next()) |x| {
            const item = std.mem.trim(u8, x, " \t");
            if (item.len > 0) try list.append(arena, item);
        }
        stableSort([]const u8, list.items, {}, lessText);
    }
    if (lists[0].items.len != lists[1].items.len) return false;
    for (lists[0].items, lists[1].items) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn authors(r: *Run, fresh: []const Fresh, ours: Ours, k: *Kinds) Allocator.Error!void {
    if (r.policy.authors == .any) return;
    for (fresh) |f| {
        const cm = f.commit;
        if (try mergeAddsNothing(r, cm, ours)) continue;
        const own = for (r.policy.pusher_emails) |e| {
            if (std.ascii.eqlIgnoreCase(e, cm.author.email)) break true;
        } else false;
        if (own) continue;
        try k.addAt("author_mismatch", f.hex, r.policy.authors == .enforce);
    }
}

const Fresh = struct { hex: []const u8, commit: object.Commit };

/// The commits of `h` that `base`'s history doesn't have.
fn freshOf(
    r: *Run,
    h: std.StringArrayHashMapUnmanaged(object.Commit),
    base: ?std.StringHashMapUnmanaged(void),
) Allocator.Error![]const Fresh {
    var out: std.ArrayList(Fresh) = .empty;
    var it = h.iterator();
    while (it.next()) |e| {
        if (base) |b| if (b.contains(e.key_ptr.*)) continue;
        try out.append(r.c.arena, .{ .hex = e.key_ptr.*, .commit = e.value_ptr.* });
    }
    return out.items;
}

fn keysOf(
    arena: Allocator,
    h: std.StringArrayHashMapUnmanaged(object.Commit),
) Allocator.Error!std.StringHashMapUnmanaged(void) {
    var out: std.StringHashMapUnmanaged(void) = .empty;
    for (h.keys()) |key| try out.put(arena, key, {});
    return out;
}

fn tombstone(r: *Run, u: Update) Allocator.Error!Expect {
    const c = r.c;
    if (u.new == null) {
        var k: Kinds = .{ .arena = c.arena };
        try k.add("deleted");
        return k.done("delete");
    }
    var k: Kinds = .{ .arena = c.arena };
    if (!r.policy.allow_purge) try k.add("purge_not_allowed");
    const action = try actionOf(c, u);
    const h = (try history(c, u.new.?)) orelse {
        try k.add("invalid_history");
        return k.done(action);
    };
    if (std.mem.eql(u8, action, "rewrite")) try k.add("non_fast_forward");
    const base = if (u.old) |o| if (try history(
        c,
        o,
    )) |oh| try keysOf(c.arena, oh) else null else null;
    const fresh = try freshOf(r, h, base);
    const empty = object.emptyTree(c.format);
    for (fresh) |f| {
        if (!f.commit.tree.eql(empty) or !try isPurge(c, f.commit))
            try k.addAt("not_a_purge", f.hex, true);
    }
    try authors(r, fresh, .tombstone, &k);
    var e = try k.done(action);
    e.new_count = fresh.len;
    return e;
}

fn isPurge(c: commands.Clone, cm: object.Commit) Allocator.Error!bool {
    if (cm.parents.len >= 2) {
        const subject = std.mem.sliceTo(cm.message, '\n');
        return std.mem.eql(u8, cm.author.email, merge_email) and
            std.mem.eql(u8, subject, "Merge purges");
    }
    const block = try commands.trailersOf(c.arena, cm.message);
    const kind = trailers.lastValue(block, "X-Purge") orelse return false;
    if (std.mem.eql(u8, kind, "issue")) return true;
    if (!std.mem.eql(u8, kind, "comment")) return false;
    for (block.trailers) |t| {
        if (!std.ascii.eqlIgnoreCase(t.key, "X-Purged-Commit")) continue;
        if (isFullHex(c, t.value)) return true;
    }
    return false;
}

fn isFullHex(c: commands.Clone, s: []const u8) bool {
    if (s.len != c.format.hexLen()) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return false;
    return true;
}

fn rootOf(h: std.StringArrayHashMapUnmanaged(object.Commit)) struct { usize, ?object.Commit } {
    var n: usize = 0;
    var root: ?object.Commit = null;
    for (h.values()) |cm| if (cm.parents.len == 0) {
        n += 1;
        root = cm;
    };
    return .{ n, root };
}

/// The number as written, when it is a valid one.
fn numberOf(c: commands.Clone, tip: []const u8) commands.RuleError!?[]const u8 {
    const n = try c.naive(tip);
    return if (commands.validNumber(n.number)) n.number else null;
}

fn issueOrMilestone(
    r: *Run,
    u: Update,
    kind: Ours,
    id: []const u8,
    index: usize,
) (Allocator.Error || error{NoRule})!Expect {
    const c = r.c;
    const a = c.arena;
    if (u.new == null) return deleteOf(r, kind, id);
    const new = u.new.?;
    var k: Kinds = .{ .arena = a };
    const action = try actionOf(c, u);
    const tomb: ?purge.Tomb = if (kind == .issue) r.tombs.get(id) else null;
    if (tomb) |t| if (t.issue) {
        try k.add("purged");
        return k.done(action);
    };
    const h = (try history(c, new)) orelse {
        try k.add("invalid_history");
        return k.done(action);
    };

    // fsck, by the oracle's reading: empty trees, one root with its keys.
    const empty = object.emptyTree(c.format);
    for (h.values()) |cm| if (!cm.tree.eql(empty)) try k.add("invalid_history");
    const roots, const root = rootOf(h);
    if (roots != 1) try k.add("invalid_history");
    if (root) |rc| {
        const block = try commands.trailersOf(a, rc.message);
        const first_key = if (kind == .issue) "State" else "Name";
        for ([_][]const u8{ first_key, "Format-Version" }) |key| {
            if (!trailers.has(block, key)) try k.add("invalid_history");
        }
    }
    if (k.rejects.items.len > 0) return k.done(action);
    {
        const block = try commands.trailersOf(a, root.?.message);
        const v = trailers.lastValue(block, "Format-Version") orelse "";
        if (!std.mem.eql(u8, v, "1")) try k.add("format_version");
    }

    const old_h: ?std.StringArrayHashMapUnmanaged(object.Commit) = if (u.old) |o|
        (try history(c, o)) orelse {
            try k.add("invalid_history");
            return k.done(action);
        }
    else
        null;
    var base: ?std.StringHashMapUnmanaged(void) = if (old_h) |oh| try keysOf(a, oh) else null;
    if (std.mem.eql(u8, action, "rewrite")) {
        const purging = if (tomb) |t| t.comments.len > 0 else false;
        if (!purging) {
            try k.add("non_fast_forward");
        } else if (!r.policy.allow_purge) {
            try k.add("purge_not_allowed");
        } else {
            const rw = try purge.rewrite(c, u.old.?, tomb.?.comments);
            if (rw == null or !h.contains(rw.?)) {
                try k.add("non_fast_forward");
            } else base = try reachIn(a, h, rw.?);
        }
    }
    const fresh = try freshOf(r, h, base);

    if (tomb) |t| if (t.comments.len > 0) {
        const rw = try purge.rewrite(c, new, t.comments);
        if (rw == null or !std.mem.eql(u8, rw.?, new)) try k.add("purged");
    };

    var needs_number = false;
    var touches_locked = false;
    if (kind == .issue) {
        const old_number = if (u.old) |o| try numberOf(c, o) else null;
        const new_number = try numberOf(c, new);
        if (!r.policy.allow_numbers) {
            for (fresh) |f| {
                const block = try commands.trailersOf(a, f.commit.message);
                for (block.trailers) |t| {
                    if (!std.ascii.eqlIgnoreCase(t.key, "X-Number")) continue;
                    const same = if (old_number) |n| std.mem.eql(u8, n, t.value) else false;
                    if (!same) try k.addAt("number_set", f.hex, true);
                }
            }
        } else if (new_number) |n| {
            if (old_number != null and !std.mem.eql(u8, old_number.?, n)) {
                try k.add("number_changed");
            } else if (old_number == null) {
                r.given[index] = n;
                for (c.clone.refs) |ref| {
                    if (!std.mem.startsWith(u8, ref.name, "refs/issues/")) continue;
                    if (std.mem.eql(u8, ref.name["refs/issues/".len..], id)) continue;
                    const other = numberOf(c, ref.oid) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.NoRule => continue,
                    };
                    if (other != null and std.mem.eql(u8, other.?, n)) {
                        try k.add("number_taken");
                        break;
                    }
                }
            }
        }
        needs_number = new_number == null;
        if (fresh.len > 0) if (u.old) |o| {
            const n = try c.naive(o);
            touches_locked = std.mem.eql(u8, n.locked, "true");
        };
    }

    try authors(r, fresh, kind, &k);
    var e = try k.done(action);
    e.new_count = fresh.len;
    e.needs_number = needs_number;
    e.touches_locked = touches_locked;
    return e;
}

/// The issue's tip once the push is in.
fn issueTipAfter(r: *Run, id: []const u8) Allocator.Error!?[]const u8 {
    const name = try std.fmt.allocPrint(r.c.arena, "refs/issues/{s}", .{id});
    for (r.updates) |u| if (std.mem.eql(u8, u.ref, name)) return u.new;
    return r.c.ref(name);
}

fn attachments(r: *Run, u: Update, id: []const u8) (Allocator.Error || error{NoRule})!Expect {
    const c = r.c;
    const a = c.arena;
    if (u.new == null) return deleteOf(r, .attachments, id);
    var k: Kinds = .{ .arena = a };
    const action = try actionOf(c, u);
    const h = (try history(c, u.new.?)) orelse {
        try k.add("invalid_history");
        return k.done(action);
    };
    if (std.mem.eql(u8, action, "rewrite")) {
        if (r.tombs.get(id) == null) {
            try k.add("non_fast_forward");
        } else if (!r.policy.allow_purge) try k.add("purge_not_allowed");
    }
    const base = if (u.old) |o| if (try history(c, o)) |oh| try keysOf(a, oh) else null else null;
    const fresh = try freshOf(r, h, base);
    const issue_tip = try issueTipAfter(r, id);
    const issue_h = if (issue_tip) |t| try history(c, t) else null;
    // Only the tip must be exactly derived; earlier commits hold pointers.
    for (fresh) |f| {
        const ok = if (std.mem.eql(u8, f.hex, u.new.?))
            try isDerived(c, id, f, issue_h)
        else
            try pointersOnly(c, f.commit);
        if (!ok) try k.addAt("not_derived", f.hex, true);
    }
    var e = try k.done(action);
    e.new_count = fresh.len;
    return e;
}

fn pointersOnly(c: commands.Clone, cm: object.Commit) Allocator.Error!bool {
    if (cm.tree.eql(object.emptyTree(c.format))) return true;
    const t = c.objects.get(try cm.tree.hexAlloc(c.arena)) orelse return false;
    if (t.kind != .tree) return false;
    const entries = object.Tree.parse(c.arena, c.format, t.data) catch return false;
    for (entries) |e| {
        var parts = std.mem.splitScalar(u8, e.name, '.');
        const stem = parts.next().?;
        const ext = parts.next() orelse return false;
        if (parts.next() != null or !isUuid(stem)) return false;
        if (!std.mem.eql(u8, ext, "png") and !std.mem.eql(u8, ext, "jpg") and
            !std.mem.eql(u8, ext, "webp")) return false;
        const blob = c.objects.get(try e.oid.hexAlloc(c.arena)) orelse return false;
        if (blob.kind != .blob) return false;
        var lines = std.mem.splitScalar(u8, blob.data, '\n');
        if (!std.mem.eql(u8, lines.next().?, "version https://git-lfs.github.com/spec/v1"))
            return false;
        const oid_line = lines.next() orelse return false;
        if (!std.mem.startsWith(u8, oid_line, "oid sha256:")) return false;
        const sha = oid_line["oid sha256:".len..];
        if (sha.len != 64) return false;
        for (sha) |ch| if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return false;
        const size_line = lines.next() orelse return false;
        if (!std.mem.startsWith(u8, size_line, "size ")) return false;
        const n = size_line["size ".len..];
        if (n.len == 0 or (n.len > 1 and n[0] == '0')) return false;
        for (n) |ch| if (!std.ascii.isDigit(ch)) return false;
        const end = lines.next() orelse return false;
        if (end.len != 0 or lines.next() != null) return false;
    }
    return true;
}

/// Exactly the commit §7 derives for the issue tip it names.
fn isDerived(
    c: commands.Clone,
    id: []const u8,
    f: Fresh,
    issue_h: ?std.StringArrayHashMapUnmanaged(object.Commit),
) (Allocator.Error || error{NoRule})!bool {
    const a = c.arena;
    const cm = f.commit;
    const ih = issue_h orelse return false;
    const block = try commands.trailersOf(a, cm.message);
    const tip = trailers.lastValue(block, "X-Issue-Tip") orelse return false;
    const tip_commit = ih.get(tip) orelse return false;
    const naive = try c.naive(tip);
    var entries: std.ArrayList(object.Tree.Entry) = .empty;
    for (naive.attachments) |att| {
        const pointer = try std.fmt.allocPrint(
            a,
            "version https://git-lfs.github.com/spec/v1\noid sha256:{s}\nsize {s}\n",
            .{ att.sha256, att.size },
        );
        try entries.append(a, .{
            .name = try std.fmt.allocPrint(a, "{s}.{s}", .{ att.id, att.extension() }),
            .oid = object.hashObject(c.format, .blob, pointer),
        });
    }
    const tree = object.hashObject(
        c.format,
        .tree,
        try object.Tree.serializeAlloc(a, entries.items),
    );
    const parents = try a.dupe(object.Oid, cm.parents);
    stableSort(object.Oid, parents, {}, struct {
        fn lt(_: void, x: object.Oid, y: object.Oid) bool {
            return x.order(y) == .lt;
        }
    }.lt);
    const sig: object.Signature = .{
        .name = "git-issue",
        .email = merge_email,
        .time = tip_commit.committer.time,
        .tz_offset_minutes = 0,
    };
    const want: object.Commit = .{
        .tree = tree,
        .parents = parents,
        .author = sig,
        .committer = sig,
        .message = try std.fmt.allocPrint(
            a,
            "Regenerate attachments\n\nX-Issue: {s}\nX-Issue-Tip: {s}\n",
            .{ id, tip },
        ),
    };
    const hex = object.hashObject(c.format, .commit, try want.serializeAlloc(a)).hex();
    return std.mem.eql(u8, hex.slice(), f.hex);
}

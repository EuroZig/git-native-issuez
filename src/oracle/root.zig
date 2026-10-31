//! The oracle: a separate, simple statement of what a command may do to a
//! world. It must not import the engine, only object primitives and the
//! world format. When the two disagree, one of them has a bug.

const std = @import("std");
const Allocator = std.mem.Allocator;
const issuez = @import("issuez");
const object = issuez.backend.object;
const hex_fmt = issuez.format.hex;
const trailers = issuez.format.trailers;
const World = issuez.backend.GitSim.World;
const Oid = object.Oid;

pub const command = @import("command.zig");
pub const Command = command.Command;

/// Reasons a transition was rejected, and checks left out.
pub const Report = struct {
    arena: Allocator,
    violations: std.ArrayList([]const u8) = .empty,
    /// Parts of the transition the oracle has no rule for, so a gap in its
    /// coverage shows up in the fuzzer's statistics.
    skipped: std.ArrayList([]const u8) = .empty,

    pub fn fail(r: *Report, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try r.violations.append(r.arena, try std.fmt.allocPrint(r.arena, fmt, args));
    }

    pub fn skip(r: *Report, reason: []const u8) Allocator.Error!void {
        try r.skipped.append(r.arena, reason);
    }

    pub fn ok(r: Report) bool {
        return r.violations.items.len == 0;
    }
};

/// What git-native-issuez may write. Nothing else may change.
pub const owned_prefixes = [_][]const u8{
    "refs/issues/",
    "refs/milestones/",
    "refs/issuez-sync/",
    "refs/issuez-guard/",
};

pub fn isOwnedRef(name: []const u8) bool {
    for (owned_prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    // Fetch staging: refs/remotes/<remote>/{issues,milestones}/
    if (std.mem.startsWith(u8, name, "refs/remotes/")) {
        const rest = name["refs/remotes/".len..];
        const slash = std.mem.findScalar(u8, rest, '/') orelse return false;
        const ns = rest[slash + 1 ..];
        for ([_][]const u8{ "issues/", "milestones/" }) |p|
            if (std.mem.startsWith(u8, ns, p)) return true;
    }
    return false;
}

/// Local refs that serialize guarded writes, see the engine's
/// `guard_ref_prefix`. The per-command rules ignore them.
const guard_prefix = "refs/issuez-guard/";

/// Must hold whatever the command.
pub fn checkInvariants(
    arena: Allocator,
    before: World,
    after: World,
    report: *Report,
) Allocator.Error!void {
    if (before.format != after.format) try report.fail("object format changed", .{});
    if (!std.mem.eql(u8, before.identity.name, after.identity.name) or
        !std.mem.eql(u8, before.identity.email, after.identity.email))
        try report.fail("world identity changed", .{});
    if (after.clock.now < before.clock.now) try report.fail("clock went backwards", .{});
    if (before.clones.len != after.clones.len) {
        try report.fail(
            "number of clones changed ({d} -> {d})",
            .{ before.clones.len, after.clones.len },
        );
        return;
    }
    for (before.clones, after.clones) |b, a| {
        if (!std.mem.eql(u8, b.name, a.name)) {
            try report.fail("clone renamed or reordered ('{s}' -> '{s}')", .{ b.name, a.name });
            continue;
        }
        try checkClone(arena, before.format, b, a, report);
    }
}

fn checkClone(
    arena: Allocator,
    format: object.ObjectFormat,
    b: World.Clone,
    a: World.Clone,
    report: *Report,
) Allocator.Error!void {
    const before_objects = try objectSet(arena, format, b);
    const after_objects = try objectSet(arena, format, a);

    // Objects never disappear.
    var it = before_objects.keyIterator();
    while (it.next()) |hex| if (!after_objects.contains(hex.*))
        try report.fail("clone '{s}': object {s} disappeared", .{ a.name, hex.* });

    // Refs point at existing objects, issue refs only reach empty-tree
    // commits.
    for (a.refs) |r| {
        const o = after_objects.get(r.oid) orelse {
            try report.fail(
                "clone '{s}': ref {s} points at missing object {s}",
                .{ a.name, r.name, r.oid },
            );
            continue;
        };
        if (std.mem.startsWith(u8, r.name, "refs/issues/") or std.mem.startsWith(
            u8,
            r.name,
            "refs/milestones/",
        )) {
            try checkEmptyTreeHistory(arena, format, a.name, r.name, o, after_objects, report);
        }
    }

    // Guard refs stay, and only move to a tip this step wrote to an issue
    // or milestone.
    for (b.refs) |r| if (std.mem.startsWith(u8, r.name, guard_prefix)) {
        const kept = for (a.refs) |n| {
            if (std.mem.eql(u8, n.name, r.name)) break true;
        } else false;
        if (!kept) try report.fail("clone '{s}': guard ref {s} deleted", .{ a.name, r.name });
    };
    for (a.refs) |r| {
        if (!std.mem.startsWith(u8, r.name, guard_prefix)) continue;
        const old = for (b.refs) |o| {
            if (std.mem.eql(u8, o.name, r.name)) break o.oid;
        } else null;
        if (old != null and std.mem.eql(u8, old.?, r.oid)) continue;
        const written = for (a.refs) |t| {
            if (!std.mem.startsWith(u8, t.name, "refs/issues/") and
                !std.mem.startsWith(u8, t.name, "refs/milestones/")) continue;
            if (!std.mem.eql(u8, t.oid, r.oid)) continue;
            const was = for (b.refs) |o| {
                if (std.mem.eql(u8, o.name, t.name)) break o.oid;
            } else null;
            if (was == null or !std.mem.eql(u8, was.?, t.oid)) break true;
        } else false;
        if (!written) try report.fail(
            "clone '{s}': guard ref {s} moved to a commit no write made",
            .{ a.name, r.name },
        );
    }

    // Refs outside our namespaces never change.
    for (b.refs) |r| if (!isOwnedRef(r.name)) {
        const now = findRef(a, r.name);
        if (now == null or !std.mem.eql(u8, now.?, r.oid))
            try report.fail("clone '{s}': foreign ref {s} was changed", .{ a.name, r.name });
    };
    for (a.refs) |r| if (!isOwnedRef(r.name) and findRef(b, r.name) == null)
        try report.fail("clone '{s}': foreign ref {s} was created", .{ a.name, r.name });
}

/// Format 1 issues and milestones only use the empty tree.
fn checkEmptyTreeHistory(
    arena: Allocator,
    format: object.ObjectFormat,
    clone: []const u8,
    ref: []const u8,
    tip: World.StoredObject,
    objects: std.StringHashMapUnmanaged(World.StoredObject),
    report: *Report,
) Allocator.Error!void {
    const empty = object.emptyTree(format);
    var stack: std.ArrayList(World.StoredObject) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    try stack.append(arena, tip);
    while (stack.pop()) |o| {
        if (o.kind != .commit) {
            try report.fail("clone '{s}': {s} reaches a non-commit object", .{ clone, ref });
            return;
        }
        const c = object.Commit.parse(arena, format, o.data) catch {
            try report.fail("clone '{s}': {s} reaches an undecodable commit", .{ clone, ref });
            return;
        };
        if (!c.tree.eql(empty)) try report.fail(
            "clone '{s}': {s} has a commit with a non-empty tree",
            .{ clone, ref },
        );
        for (c.parents) |p| {
            const hex = try arena.dupe(u8, p.hex().slice());
            const gop = try seen.getOrPut(arena, hex);
            if (gop.found_existing) continue;
            const parent = objects.get(hex) orelse {
                try report.fail("clone '{s}': {s} has missing parent {s}", .{ clone, ref, hex });
                continue;
            };
            try stack.append(arena, parent);
        }
    }
}

fn objectSet(
    arena: Allocator,
    format: object.ObjectFormat,
    clone: World.Clone,
) Allocator.Error!std.StringHashMapUnmanaged(World.StoredObject) {
    var set: std.StringHashMapUnmanaged(World.StoredObject) = .empty;
    for (clone.objects) |o| {
        const oid = object.hashObject(format, o.kind, o.data);
        try set.put(arena, try arena.dupe(u8, oid.hex().slice()), o);
    }
    return set;
}

fn findRef(clone: World.Clone, name: []const u8) ?[]const u8 {
    for (clone.refs) |r| if (std.mem.eql(u8, r.name, name)) return r.oid;
    return null;
}

pub const commands = @import("commands.zig");
/// Upstream's merge commits, for the fuzzer. test/interop.zig checks the
/// model against real upstream.
pub const upstream = @import("upstream.zig");

/// Checks `command(before) == after` on clone `clone_name` (the first by
/// default). NoRule when there's no rule for the case yet.
pub fn checkTransition(
    arena: Allocator,
    before: World,
    after: World,
    clone_name: ?[]const u8,
    cmd: Command,
    exit_code: u8,
    report: *Report,
) (Allocator.Error || error{NoRule})!void {
    try checkInvariants(arena, before, after, report);
    if (before.clones.len != after.clones.len) return;
    const target = if (clone_name) |n| (before.cloneIndex(n) orelse return error.NoRule) else 0;

    // A command touches one clone, plus the remote for push and sync.
    const exempt = syncRemoteIndex(before, target, cmd);
    for (before.clones, after.clones, 0..) |b, a, i| {
        if (i == target or (exempt != null and i == exempt.?)) continue;
        try expectCloneUnchanged(arena, before.format, b, a, report, true);
    }
    const b = before.clones[target];
    const a = after.clones[target];

    if (exit_code != 0) {
        // A failed command may leave unreferenced objects, nothing else.
        return expectCloneUnchanged(arena, before.format, b, a, report, false);
    }
    if (cmd == .read) return expectCloneUnchanged(arena, before.format, b, a, report, true);
    const cb = try commands.Clone.init(arena, before.format, b);
    const ca = try commands.Clone.init(arena, after.format, a);
    switch (cmd) {
        .read => unreachable,
        .init => return checkInit(arena, cb, ca, report),
        .create => |x| return checkCreate(arena, after, cb, ca, x, report),
        .comment => |x| return checkComment(arena, after, cb, ca, x, report),
        .state => |x| return checkState(arena, after, cb, ca, x, report),
        .edit => |x| if (x.description.len > 0)
            return checkDescription(arena, after, cb, ca, x, report)
        else
            return checkEdit(arena, after, cb, ca, x, report),
        .merge, .push, .sync => |x| {
            try checkSync(arena, before, after, target, cmd, x, report);
        },
        .quarantine => |x| return checkResolve(arena, cb, ca, x, report),
        .close, .reopen => |x| return checkState(arena, after, cb, ca, .{
            .id = x.id,
            .state = if (cmd == .close) "closed" else "open",
            .message = x.message,
        }, report),
        .delete, .restore => |x| {
            return checkDeleted(arena, after, cb, ca, cmd == .delete, x, report);
        },
        .comment_event => |x| return checkCommentEvent(arena, after, cb, ca, x, report),
        .milestone => |x| return checkMilestone(arena, after, cb, ca, x, report),
    }
}

/// The remote is another clone of the world (`remote.<name>.url = sim:<clone>`).
fn checkSync(
    arena: Allocator,
    before: World,
    after: World,
    target: usize,
    which: Command,
    x: command.Sync,
    report: *Report,
) (Allocator.Error || error{NoRule})!void {
    const cmd = which.verb();
    const name = x.remote;
    const check_only = x.check;
    const no_fetch = x.no_fetch;
    const pushing = which != .merge;
    const lb = try commands.Clone.init(arena, before.format, before.clones[target]);
    const la = try commands.Clone.init(arena, after.format, after.clones[target]);

    // The remote's issues as merge sees them: from the remote clone, or with
    // --no-fetch from the staging refs already here.
    var remote_refs: std.ArrayList(World.Ref) = .empty;
    var ra: ?commands.Clone = null;
    var rb: ?commands.Clone = null;
    if (no_fetch and !pushing) {
        const staging = try std.fmt.allocPrint(arena, "refs/remotes/{s}/issues/", .{name});
        for (lb.clone.refs) |r| if (std.mem.startsWith(u8, r.name, staging)) {
            try remote_refs.append(arena, .{
                .name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{r.name[staging.len..]}),
                .oid = r.oid,
            });
        };
    } else {
        const url_key = try std.fmt.allocPrint(arena, "remote.{s}.url", .{name});
        var url: ?[]const u8 = null;
        for (before.clones[target].config) |e| if (std.mem.eql(u8, e.key, url_key)) {
            url = e.value;
        };
        const u = url orelse return error.NoRule; // the command can't have succeeded
        if (!std.mem.startsWith(u8, u, "sim:")) return error.NoRule;
        const remote_idx = before.cloneIndex(u["sim:".len..]) orelse return error.NoRule;
        rb = try commands.Clone.init(arena, before.format, before.clones[remote_idx]);
        ra = try commands.Clone.init(arena, after.format, after.clones[remote_idx]);
        for (rb.?.clone.refs) |r| if (std.mem.startsWith(
            u8,
            r.name,
            "refs/issues/",
        )) try remote_refs.append(
            arena,
            r,
        );
    }

    // checkTransition treated the remote like any other clone, so check
    // here only what a remote may do.
    if (!configEqual(before.clones[target], after.clones[target])) try report.fail(
        "{s} changed config",
        .{cmd},
    );

    // Remote issue refs are never deleted or rewound, and only push moves
    // them.
    if (rb) |rbc| for (rbc.clone.refs) |r| {
        if (!std.mem.startsWith(u8, r.name, "refs/issues/")) continue;
        const now = ra.?.ref(r.name) orelse {
            try report.fail("{s} deleted remote {s}", .{ cmd, r.name });
            continue;
        };
        if (std.mem.eql(u8, now, r.oid)) continue;
        if (!pushing or check_only) {
            try report.fail("{s} changed remote {s}", .{ cmd, r.name });
        } else if (!try isAncestorIn(ra.?, r.oid, now)) {
            try report.fail("{s} rewound remote {s}", .{ cmd, r.name });
        }
    };

    // Local issue refs are never deleted or rewound. --check changes nothing.
    for (lb.clone.refs) |r| {
        if (!std.mem.startsWith(u8, r.name, "refs/issues/")) continue;
        const now = la.ref(r.name) orelse {
            try report.fail("{s} deleted local {s}", .{ cmd, r.name });
            continue;
        };
        if (std.mem.eql(u8, now, r.oid)) continue;
        if (check_only) try report.fail("merge --check changed {s}", .{r.name});
        if (!try isAncestorIn(la, r.oid, now)) try report.fail(
            "{s} rewound local {s}",
            .{ cmd, r.name },
        );
    }
    if (check_only) return;

    // New merge commits have the deterministic shape and restate our own
    // resolution of their parents.
    for (la.clone.refs) |r| {
        if (!std.mem.startsWith(u8, r.name, "refs/issues/")) continue;
        const old = lb.ref(r.name);
        if (old != null and std.mem.eql(u8, old.?, r.oid)) continue;
        try checkNewMerges(arena, la, if (old) |o| o else null, r.oid, report);
    }

    // merge/sync: every issue the remote had is now here and contains the
    // remote tip, unless quarantined for a real reason. Push only merges
    // when rejected, so it can't promise this.
    const qprefix = try std.fmt.allocPrint(
        arena,
        "refs/issuez-sync/{s}/quarantined/issues/",
        .{name},
    );
    const merges_everything = which != .push;
    if (merges_everything) for (remote_refs.items) |r| {
        const id = r.name["refs/issues/".len..];
        const qref = try std.fmt.allocPrint(arena, "{s}{s}", .{ qprefix, id });
        if (la.ref(qref) != null) {
            try checkQuarantine(arena, lb, r.name, r.oid, report);
            continue;
        }
        const local_now = la.ref(r.name) orelse {
            try report.fail("{s}: remote issue {s} missing locally", .{ cmd, id });
            continue;
        };
        if (!try isAncestorIn(la, r.oid, local_now))
            try report.fail("{s}: local {s} doesn't contain the remote tip", .{ cmd, id });
    };

    if (pushing) {
        // After a successful push the remote has every non-quarantined local
        // tip.
        for (la.clone.refs) |r| {
            if (!std.mem.startsWith(u8, r.name, "refs/issues/")) continue;
            const id = r.name["refs/issues/".len..];
            if (la.ref(try std.fmt.allocPrint(arena, "{s}{s}", .{ qprefix, id })) != null) continue;
            // It may be further ahead if another clone pushed meanwhile.
            const remote_now = ra.?.ref(r.name);
            if (remote_now == null or !try isAncestorIn(ra.?, r.oid, remote_now.?))
                try report.fail("{s}: remote lacks local tip of {s}", .{ cmd, id });
        }
    }
}

/// Checks every merge commit added on top of `old`, or in the whole
/// history.
fn checkNewMerges(
    arena: Allocator,
    c: commands.Clone,
    old: ?[]const u8,
    tip: []const u8,
    report: *Report,
) (Allocator.Error || error{NoRule})!void {
    var stack: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    try stack.append(arena, tip);
    while (stack.pop()) |hex| {
        if (old != null and (std.mem.eql(
            u8,
            hex,
            old.?,
        ) or try isAncestorIn(c, hex, old.?))) continue;
        if ((try seen.getOrPut(arena, hex)).found_existing) continue;
        const cm = c.commit(hex) orelse return error.NoRule;
        for (cm.parents) |p| try stack.append(arena, try arena.dupe(u8, p.hex().slice()));
        if (cm.parents.len != 2) continue;
        if (!std.mem.eql(u8, cm.author.name, "git-issue")) continue; // not ours (e.g. upstream)
        const p0 = cm.parents[0].hex();
        const p1 = cm.parents[1].hex();
        if (std.mem.order(u8, p0.slice(), p1.slice()) != .lt) try report.fail(
            "merge {s}: parents not sorted",
            .{hex[0..7]},
        );
        if (!std.mem.eql(
            u8,
            cm.author.email,
            "git-issue@invalid",
        ) or cm.author.tz_offset_minutes != 0)
            try report.fail("merge {s}: wrong identity", .{hex[0..7]});
        const t0 = c.commit(p0.slice()).?.committer.time;
        const t1 = c.commit(p1.slice()).?.committer.time;
        if (cm.author.time != @max(t0, t1) or cm.committer.time != cm.author.time)
            try report.fail("merge {s}: time is not the latest parent's", .{hex[0..7]});
        // The oracle's own resolution of the two parents.
        const n = try c.naiveAt(&.{
            try arena.dupe(u8, p0.slice()),
            try arena.dupe(u8, p1.slice()),
        });
        // A field written before but empty now is restated empty.
        var want: std.ArrayList(commands.Trailer) = .empty;
        const was = struct {
            fn f(x: commands.NaiveIssue, key: []const u8) bool {
                for (x.cleared) |k| if (std.mem.eql(u8, k, key)) return true;
                return false;
            }
        }.f;
        try want.append(arena, .{ .key = "State", .value = n.state });
        if (n.title_override) |t| try want.append(arena, .{ .key = "Title", .value = t }) else if (was(n, "Title"))
            try want.append(arena, .{ .key = "Title", .value = "" });
        if (n.labels.len > 0) try want.append(
            arena,
            .{ .key = "Labels", .value = try std.mem.join(arena, ", ", n.labels) },
        ) else if (was(n, "Labels")) try want.append(arena, .{ .key = "Labels", .value = "" });
        for ([_]commands.Trailer{
            .{ .key = "Assignee", .value = n.assignee },
            .{ .key = "Priority", .value = n.priority },
            .{ .key = "Milestone", .value = n.milestone },
        }) |t| if (t.value.len > 0 or was(n, t.key)) try want.append(arena, t);
        // Extension fields as written, then the blockers.
        for ([_]commands.Trailer{
            .{ .key = "X-Parent", .value = n.parent },
            .{ .key = "X-Start-Date", .value = n.start },
            .{ .key = "X-Due-Date", .value = n.due },
            .{ .key = "X-Estimate-Minutes", .value = n.estimate },
            .{ .key = "X-Workflow-State", .value = n.workflow },
            .{ .key = "X-Milestone-Id", .value = n.milestone_id },
            .{ .key = "X-Milestone-Mode", .value = n.milestone_mode },
            .{ .key = "X-Deleted", .value = n.deleted },
        }) |t| if (t.value.len > 0 or was(n, t.key)) try want.append(arena, t);
        const block = try commands.trailersOf(arena, cm.message);
        if (n.blocked_by.len > 0) {
            // A set: the oracle doesn't model member order.
            var value: []const u8 = try std.mem.join(arena, ", ", n.blocked_by);
            if (trailers.lastValue(block, "X-Blocked-By")) |got| {
                if (sameMembers(try splitSet(arena, got), n.blocked_by)) value = got;
            }
            try want.append(arena, .{ .key = "X-Blocked-By", .value = value });
        } else if (was(n, "X-Blocked-By")) {
            try want.append(arena, .{ .key = "X-Blocked-By", .value = "" });
        }
        try expectBlock(report, "merge", block, want.items);
        // Restating changes nothing: the merge reads as its parents do.
        if (!sameNaive(try c.naive(hex), n)) try report.fail(
            "merge {s}: restating changed the resolved fields",
            .{hex[0..7]},
        );
    }
}

/// Every field the merge restates, compared as written.
fn sameNaive(a: commands.NaiveIssue, b: commands.NaiveIssue) bool {
    const eql = std.mem.eql;
    const scalars = [_][2][]const u8{
        .{ a.state, b.state },
        .{ a.title, b.title },
        .{ a.assignee, b.assignee },
        .{ a.priority, b.priority },
        .{ a.milestone, b.milestone },
        .{ a.parent, b.parent },
        .{ a.start, b.start },
        .{ a.due, b.due },
        .{ a.estimate, b.estimate },
        .{ a.workflow, b.workflow },
        .{ a.milestone_id, b.milestone_id },
        .{ a.milestone_mode, b.milestone_mode },
        .{ a.deleted, b.deleted },
    };
    for (scalars) |s| if (!eql(u8, s[0], s[1])) return false;
    return sameMembers(a.labels, b.labels) and sameMembers(a.blocked_by, b.blocked_by);
}

/// Same members, in any order. Members are unique.
fn sameMembers(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    outer: for (a) |x| {
        for (b) |y| if (std.mem.eql(u8, x, y)) continue :outer;
        return false;
    }
    return true;
}

fn splitSet(arena: Allocator, value: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |m| {
        const t = std.mem.trim(u8, m, " \t");
        if (t.len > 0) try out.append(arena, t);
    }
    return out.items;
}

/// Only unrelated histories, or a remote that lost what we merged before,
/// justify a quarantine.
fn checkQuarantine(
    arena: Allocator,
    local: commands.Clone,
    name: []const u8,
    remote_tip: []const u8,
    report: *Report,
) (Allocator.Error || error{NoRule})!void {
    const local_tip = local.ref(name) orelse return; // nothing local: only invalid issues qualify
    // With shared history only a rewrite does, and then neither tip can
    // contain the other: a fast-forward merges, and a remote reset to a tip
    // the local issue has loses nothing.
    if (!try sharesHistory(arena, local, local_tip, remote_tip)) return;
    if (try isAncestorIn(local, local_tip, remote_tip))
        try report.fail("quarantined {s} although it fast-forwards", .{name});
    if (try isAncestorIn(local, remote_tip, local_tip))
        try report.fail("quarantined {s} although the local issue has the remote tip", .{name});
}

fn sharesHistory(
    arena: Allocator,
    c: commands.Clone,
    a: []const u8,
    b: []const u8,
) Allocator.Error!bool {
    const ancestors_a = try closure(arena, c, a);
    const ancestors_b = try closure(arena, c, b);
    var it = ancestors_a.keyIterator();
    while (it.next()) |k| if (ancestors_b.contains(k.*)) return true;
    return false;
}

fn closure(
    arena: Allocator,
    c: commands.Clone,
    tip: []const u8,
) Allocator.Error!std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(arena, tip);
    while (stack.pop()) |hex| {
        if ((try set.getOrPut(arena, hex)).found_existing) continue;
        const cm = c.commit(hex) orelse continue;
        for (cm.parents) |p| try stack.append(arena, try arena.dupe(u8, p.hex().slice()));
    }
    return set;
}

fn isAncestorIn(
    c: commands.Clone,
    ancestor: []const u8,
    descendant: []const u8,
) Allocator.Error!bool {
    if (std.mem.eql(u8, ancestor, descendant)) return true;
    const set = try closure(c.arena, c, descendant);
    return set.contains(ancestor);
}

/// The clone `push` and `sync <remote>` may change.
fn syncRemoteIndex(world: World, target: usize, cmd: Command) ?usize {
    const name = switch (cmd) {
        .push, .sync => |x| x.remote,
        else => return null,
    };
    var key_buf: [300]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "remote.{s}.url", .{name}) catch return null;
    for (world.clones[target].config) |e| if (std.mem.eql(u8, e.key, key)) {
        if (!std.mem.startsWith(u8, e.value, "sim:")) return null;
        return world.cloneIndex(e.value["sim:".len..]);
    };
    return null;
}

const RefChange = struct { name: []const u8, old: ?[]const u8, new: ?[]const u8 };

fn refChanges(
    arena: Allocator,
    b: commands.Clone,
    a: commands.Clone,
) Allocator.Error![]const RefChange {
    var out: std.ArrayList(RefChange) = .empty;
    for (a.clone.refs) |r| {
        if (std.mem.startsWith(u8, r.name, guard_prefix)) continue;
        const old = b.ref(r.name);
        if (old == null or !std.mem.eql(u8, old.?, r.oid)) try out.append(
            arena,
            .{ .name = r.name, .old = old, .new = r.oid },
        );
    }
    for (b.clone.refs) |r| if (a.ref(r.name) == null) try out.append(
        arena,
        .{ .name = r.name, .old = r.oid, .new = null },
    );
    return out.items;
}

/// Whether an issue matching `prefix` is quarantined and that remote
/// version was already kept.
fn alreadyKept(
    arena: Allocator,
    b: commands.Clone,
    remote: []const u8,
    prefix: []const u8,
) Allocator.Error!bool {
    const qprefix = try std.fmt.allocPrint(arena, "refs/issuez-sync/{s}/quarantined/issues/", .{remote});
    for (b.clone.refs) |r| {
        if (!std.mem.startsWith(u8, r.name, qprefix)) continue;
        const id = r.name[qprefix.len..];
        if (!std.mem.startsWith(u8, id, prefix)) continue;
        const kept = b.ref(try std.fmt.allocPrint(
            arena,
            "refs/issuez-sync/{s}/kept/issues/{s}",
            .{ remote, id },
        )) orelse continue;
        if (std.mem.eql(u8, kept, r.oid)) return true;
    }
    return false;
}

/// Only the one quarantined issue's refs change. Accepting moves the local
/// issue to the refused tip and keeps the old one in `replaced/.../<tip>`,
/// keeping never touches the local issue.
fn checkResolve(
    arena: Allocator,
    b: commands.Clone,
    a: commands.Clone,
    x: command.Quarantine,
    report: *Report,
) Allocator.Error!void {
    const r = x.remote;
    const accept = x.accept;
    const qprefix = try std.fmt.allocPrint(arena, "refs/issuez-sync/{s}/quarantined/issues/", .{r});

    var id: ?[]const u8 = null;
    for (try refChanges(arena, b, a)) |ch| {
        const this = issueIdOf(ch.name, r) orelse {
            try report.fail("quarantine changed unrelated ref {s}", .{ch.name});
            continue;
        };
        if (id) |seen| {
            if (!std.mem.eql(u8, seen, this)) try report.fail("quarantine changed two issues", .{});
        } else id = this;
    }
    const which = id orelse {
        // Keeping a remote version that is already kept is a no-op.
        if (!accept and try alreadyKept(arena, b, r, x.id)) return;
        return report.fail("quarantine changed nothing", .{});
    };
    const marker = b.ref(try std.fmt.allocPrint(arena, "{s}{s}", .{ qprefix, which })) orelse
        return report.fail("quarantine resolved {s}, which wasn't quarantined", .{which});
    const issue_ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{which});
    const local_before = b.ref(issue_ref);
    const local_after = a.ref(issue_ref);
    if (accept) {
        if (local_after == null or !std.mem.eql(u8, local_after.?, marker))
            try report.fail("--accept-remote: {s} is not the remote tip", .{which});
        if (local_before) |old| {
            const backup = a.ref(try std.fmt.allocPrint(
                arena,
                "refs/issuez-sync/{s}/replaced/issues/{s}/{s}",
                .{ r, which, old },
            ));
            if (backup == null or !std.mem.eql(u8, backup.?, old))
                try report.fail("--accept-remote: old local tip of {s} not kept", .{which});
        }
    } else {
        const same = if (local_before) |old|
            local_after != null and std.mem.eql(u8, old, local_after.?)
        else
            local_after == null;
        if (!same) try report.fail("--keep-local changed the local issue {s}", .{which});
    }
}

/// When the ref is the issue's or one of its sync records for `remote`.
fn issueIdOf(name: []const u8, remote: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, name, "refs/issues/")) return name["refs/issues/".len..];
    const sync_prefix = "refs/issuez-sync/";
    if (!std.mem.startsWith(u8, name, sync_prefix)) return null;
    const rest = name[sync_prefix.len..];
    if (!std.mem.startsWith(u8, rest, remote) or rest.len <= remote.len or rest[remote.len] != '/')
        return null;
    const marker = "/issues/";
    const at = std.mem.find(u8, rest, marker) orelse return null;
    const id = rest[at + marker.len ..];
    // `replaced/issues/<id>/<tip>`
    return id[0 .. std.mem.findScalar(u8, id, '/') orelse id.len];
}

fn configEqual(b: World.Clone, a: World.Clone) bool {
    if (b.config.len != a.config.len) return false;
    for (b.config, a.config) |x, y| {
        if (!std.mem.eql(u8, x.key, y.key) or !std.mem.eql(u8, x.value, y.value)) return false;
    }
    return true;
}

fn checkInit(
    arena: Allocator,
    b: commands.Clone,
    a: commands.Clone,
    report: *Report,
) Allocator.Error!void {
    if ((try refChanges(arena, b, a)).len != 0) try report.fail("init changed refs", .{});
    // Only remote.<name>.fetch entries may be added or removed.
    for (a.clone.config) |e| if (!containsEntry(b.clone.config, e) and !isFetchKey(e.key))
        try report.fail("init added config '{s}'", .{e.key});
    for (b.clone.config) |e| if (!containsEntry(a.clone.config, e) and !isFetchKey(e.key))
        try report.fail("init removed config '{s}'", .{e.key});
    for (a.clone.config) |e| if (isFetchKey(e.key) and !containsEntry(b.clone.config, e)) {
        // And only the staging refspecs may be added.
        const remote = e.key["remote.".len .. e.key.len - ".fetch".len];
        var ok = false;
        for ([_][]const u8{ "issues", "milestones" }) |ns| {
            const expected = try std.fmt.allocPrint(
                arena,
                "+refs/{s}/*:refs/remotes/{s}/{s}/*",
                .{ ns, remote, ns },
            );
            if (std.mem.eql(u8, e.value, expected)) ok = true;
        }
        if (!ok) try report.fail(
            "init added unexpected refspec '{s}'",
            .{e.value},
        );
    };
}

fn isFetchKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "remote.") and std.mem.endsWith(u8, key, ".fetch");
}

fn containsEntry(list: []const World.ConfigEntry, e: World.ConfigEntry) bool {
    for (list) |x| if (std.mem.eql(u8, x.key, e.key) and std.mem.eql(
        u8,
        x.value,
        e.value,
    )) return true;
    return false;
}

fn checkCreate(
    arena: Allocator,
    world: World,
    b: commands.Clone,
    a: commands.Clone,
    x: command.Create,
    report: *Report,
) (Allocator.Error || error{NoRule})!void {
    if (!configEqual(b.clone, a.clone)) try report.fail("create changed config", .{});
    const changes = try refChanges(arena, b, a);
    if (changes.len != 1 or changes[0].old != null or changes[0].new == null) {
        try report.fail("create must add exactly one ref (changed {d})", .{changes.len});
        return;
    }
    const name = changes[0].name;
    if (!std.mem.startsWith(u8, name, "refs/issues/")) return report.fail(
        "create wrote {s}",
        .{name},
    );
    const id = name["refs/issues/".len..];
    if (!isV4Uuid(id)) try report.fail("create used a non-v4 UUID: {s}", .{id});
    const c = a.commit(changes[0].new.?) orelse return report.fail(
        "create: ref points at a non-commit",
        .{},
    );
    if (c.parents.len != 0) try report.fail("create: root commit has parents", .{});
    if (!c.tree.eql(object.emptyTree(world.format))) try report.fail("create: non-empty tree", .{});
    try checkIdentity(world, c, report);
    const resolved = (try commands.resolveExt(
        arena,
        b,
        x.ext,
        x.milestone,
        null,
    )) orelse return report.fail(
        "create succeeded with a reference, date, estimate, workflow state or milestone " ++
            "the oracle rejects",
        .{},
    );
    const expected = try commands.expectedCreateMessage(arena, x, resolved);
    if (!std.mem.eql(u8, c.message, expected))
        try report.fail("create wrote message\n{s}\nexpected\n{s}", .{ c.message, expected });
}

/// The one commit `cmd` must have added on top of issue `id`: a single
/// parent, the empty tree, the world identity. Null after reporting why not.
fn appendCommit(
    arena: Allocator,
    world: World,
    b: commands.Clone,
    a: commands.Clone,
    cmd: []const u8,
    id: []const u8,
    report: *Report,
) Allocator.Error!?object.Commit {
    if (!configEqual(b.clone, a.clone)) try report.fail("{s} changed config", .{cmd});
    const matches = try b.matching(id);
    if (matches.len != 1) {
        try report.fail(
            "{s} succeeded although '{s}' matches {d} issues",
            .{ cmd, id, matches.len },
        );
        return null;
    }
    const changes = try refChanges(arena, b, a);
    if (changes.len != 1 or !std.mem.eql(
        u8,
        changes[0].name,
        matches[0],
    ) or changes[0].new == null) {
        try report.fail("{s} must advance exactly {s}", .{ cmd, matches[0] });
        return null;
    }
    const c = a.commit(changes[0].new.?) orelse {
        try report.fail("{s}: new tip is not a commit", .{cmd});
        return null;
    };
    if (c.parents.len != 1 or !std.mem.eql(u8, c.parents[0].hex().slice(), changes[0].old.?)) {
        try report.fail("{s}: new commit's parent is not the previous tip", .{cmd});
        return null;
    }
    if (!c.tree.eql(object.emptyTree(world.format))) try report.fail("{s}: non-empty tree", .{cmd});
    try checkIdentity(world, c, report);
    return c;
}

fn checkComment(
    arena: Allocator,
    world: World,
    b: commands.Clone,
    a: commands.Clone,
    x: command.Comment,
    report: *Report,
) Allocator.Error!void {
    if (x.paragraphs.len == 0) return report.fail("comment without text succeeded", .{});
    const c = (try appendCommit(arena, world, b, a, "comment", x.id, report)) orelse return;
    const block = try commands.trailersOf(arena, c.message);
    if (block.first_line != null) try report.fail("comment message has a trailer block", .{});
    const text = try std.mem.join(arena, "\n\n", x.paragraphs);
    const want = try commands.contentLines(arena, text);
    const got = try commands.contentLines(arena, c.message);
    if (!sameLines(want, got)) try report.fail("comment text differs:\n{s}", .{c.message});
}

fn checkState(
    arena: Allocator,
    world: World,
    b: commands.Clone,
    a: commands.Clone,
    x: command.State,
    report: *Report,
) Allocator.Error!void {
    const c = (try appendCommit(arena, world, b, a, "state", x.id, report)) orelse return;
    const block = try commands.trailersOf(arena, c.message);
    try expectBlock(report, "state", block, try commands.expectedStateTrailers(arena, x));
    try expectSubject(arena, report, "state", x.message, c.message);
}

fn checkEdit(
    arena: Allocator,
    world: World,
    b: commands.Clone,
    a: commands.Clone,
    x: command.Edit,
    report: *Report,
) (Allocator.Error || error{NoRule})!void {
    const c = (try appendCommit(arena, world, b, a, "edit", x.id, report)) orelse return;
    const previous = try b.naive(c.parents[0].hex().slice());
    const resolved = (try commands.resolveExt(
        arena,
        b,
        x.ext,
        x.milestone,
        previous,
    )) orelse return report.fail(
        "edit succeeded with a reference, date, estimate, workflow state or milestone " ++
            "the oracle rejects",
        .{},
    );
    try expectBlock(
        report,
        "edit",
        try commands.trailersOf(arena, c.message),
        try commands.expectedEditTrailers(arena, x, resolved, previous),
    );
}

/// Subjects the CLI picks itself ("Close issue") are its own business. A
/// message the user gave has to be the subject.
fn expectSubject(
    arena: Allocator,
    report: *Report,
    cmd: []const u8,
    given: ?[]const u8,
    message: []const u8,
) Allocator.Error!void {
    const text = given orelse return;
    const want = try commands.subjectOf(arena, text);
    const got = try commands.subjectOf(arena, message);
    if (!std.mem.eql(u8, want, got))
        try report.fail("{s}: subject '{s}', expected '{s}'", .{ cmd, got, want });
}

/// What follows the subject: the body and the trailers.
fn afterSubject(message: []const u8) []const u8 {
    const at = std.mem.find(u8, message, "\n\n") orelse return "";
    return message[at + 2 ..];
}

/// Reads change nothing. Writes only touch refs/milestones/*, with the
/// exact root message on create and the status trailer otherwise.
fn checkMilestone(
    arena: Allocator,
    world: World,
    b: commands.Clone,
    a: commands.Clone,
    x: command.Milestone,
    report: *Report,
) Allocator.Error!void {
    const sub = @tagName(x.sub);
    const changes = try refChanges(arena, b, a);
    for (changes) |ch| if (!std.mem.startsWith(u8, ch.name, "refs/milestones/"))
        try report.fail("milestone {s} changed {s}", .{ sub, ch.name });
    if (changes.len != 1) {
        // A no-op ("already completed") writes nothing, anything else one ref.
        if (changes.len > 1)
            try report.fail("milestone {s} changed {d} refs", .{ sub, changes.len });
        return;
    }
    const ch = changes[0];
    const new = ch.new orelse return report.fail("milestone {s} deleted a ref", .{sub});
    const c = a.commit(new) orelse return report.fail("milestone: ref points at a non-commit", .{});
    try checkIdentity(world, c, report);
    if (!c.tree.eql(object.emptyTree(world.format)))
        try report.fail("milestone: non-empty tree", .{});
    if (x.sub == .create) {
        if (ch.old != null) return report.fail("milestone create moved an existing ref", .{});
        if (!isV4Uuid(ch.name["refs/milestones/".len..]))
            try report.fail("milestone: bad UUID", .{});
        // Body and trailers of the root message. The subject is the CLI's.
        var w: std.Io.Writer.Allocating = .init(arena);
        const ww = &w.writer;
        const d = std.mem.trimEnd(u8, x.message orelse "", " \t\r\n");
        if (d.len > 0) ww.print("{s}\n\n", .{d}) catch return error.OutOfMemory;
        ww.print("Name: {s}\n", .{x.name}) catch return error.OutOfMemory;
        if (x.due) |v| ww.print("X-Due-Date: {s}\n", .{v}) catch return error.OutOfMemory;
        ww.writeAll("X-Milestone-Status: open\nFormat-Version: 1\n") catch return error.OutOfMemory;
        if (!std.mem.eql(u8, w.written(), afterSubject(c.message)))
            try report.fail(
                "milestone create wrote\n{s}\nexpected after the subject\n{s}",
                .{ c.message, w.written() },
            );
        return;
    }
    const status: ?[]const u8 = switch (x.sub) {
        .complete => "completed",
        .retire => "retired",
        .reopen => "open",
        .create, .edit => null,
    };
    if (status) |s| {
        const block = try commands.trailersOf(arena, c.message);
        const want = [_]commands.Trailer{.{ .key = "X-Milestone-Status", .value = s }};
        try expectBlock(report, "milestone", block, &want);
        if (c.parents.len != 1 or !std.mem.eql(u8, c.parents[0].hex().slice(), ch.old.?))
            try report.fail("milestone {s}: not one commit on the old tip", .{sub});
    }
}

/// The one issue `id` names, as its ref. Null after reporting otherwise.
fn targetRef(
    b: commands.Clone,
    id: []const u8,
    report: *Report,
    cmd: []const u8,
) Allocator.Error!?[]const u8 {
    const m = try b.matching(id);
    if (m.len != 1) {
        try report.fail("{s} succeeded although '{s}' matches {d} issues", .{ cmd, id, m.len });
        return null;
    }
    return m[0];
}

/// Oldest first, along first parents.
fn appended(
    arena: Allocator,
    b: commands.Clone,
    a: commands.Clone,
    name: []const u8,
    report: *Report,
    cmd: []const u8,
) Allocator.Error!?[]const object.Commit {
    const changes = try refChanges(arena, b, a);
    if (changes.len != 1 or !std.mem.eql(u8, changes[0].name, name) or changes[0].new == null) {
        try report.fail("{s} must advance exactly {s}", .{ cmd, name });
        return null;
    }
    const old = changes[0].old.?;
    var chain: std.ArrayList(object.Commit) = .empty;
    var hex = changes[0].new.?;
    while (!std.mem.eql(u8, hex, old)) {
        const c = a.commit(hex) orelse {
            try report.fail("{s}: new tip is not a commit chain onto the old one", .{cmd});
            return null;
        };
        if (c.parents.len != 1 or chain.items.len > 2) {
            try report.fail("{s}: wrote something other than a short linear chain", .{cmd});
            return null;
        }
        try chain.insert(arena, 0, c);
        hex = try arena.dupe(u8, c.parents[0].hex().slice());
    }
    return chain.items;
}

fn checkDeleted(
    arena: Allocator,
    world: World,
    b: commands.Clone,
    a: commands.Clone,
    deleted: bool,
    x: command.Lifecycle,
    report: *Report,
) Allocator.Error!void {
    const cmd = if (deleted) "delete" else "restore";
    const name = (try targetRef(b, x.id, report, cmd)) orelse return;
    const before_tip = b.ref(name).?;
    const naive = b.naive(before_tip) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoRule => return report.skip("delete/restore on a history the oracle can't read"),
    };
    const was = std.mem.eql(u8, naive.deleted, "true");
    if (was == deleted) {
        // Already in that state, nothing to write.
        const changed = (try refChanges(arena, b, a)).len;
        if (changed != 0) try report.fail("{s}: no-op wrote refs", .{cmd});
        return;
    }
    const chain = (try appended(arena, b, a, name, report, cmd)) orelse return;
    if (chain.len != 1) return report.fail("{s}: expected one commit", .{cmd});
    try checkIdentity(world, chain[0], report);
    const block = try commands.trailersOf(arena, chain[0].message);
    try expectBlock(report, cmd, block, &.{.{
        .key = "X-Deleted",
        .value = if (deleted) "true" else "false",
    }});
    try expectSubject(arena, report, cmd, x.message, chain[0].message);
}

/// Non-root, single-parent commits without `X-Event`.
fn commentCommits(
    arena: Allocator,
    c: commands.Clone,
    tip: []const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(arena, tip);
    while (stack.pop()) |hex| {
        if ((try seen.getOrPut(arena, hex)).found_existing) continue;
        const cm = c.commit(hex) orelse continue;
        const block = try commands.trailersOf(arena, cm.message);
        var event = false;
        for (block.trailers) |t| if (std.ascii.eqlIgnoreCase(t.key, "X-Event")) {
            event = true;
        };
        if (cm.parents.len == 1 and !event) try out.append(arena, hex);
        for (cm.parents) |p| try stack.append(arena, try arena.dupe(u8, p.hex().slice()));
    }
    return out.items;
}

fn checkCommentEvent(
    arena: Allocator,
    world: World,
    b: commands.Clone,
    a: commands.Clone,
    x: command.CommentEvent,
    report: *Report,
) Allocator.Error!void {
    const kind = switch (x.kind) {
        .edit => "comment-edit",
        .delete => "comment-delete",
        .restore => "comment-restore",
    };
    const name = (try targetRef(b, x.id, report, "comment")) orelse return;
    // Resolves among the issue's comments, 4+ characters.
    var target: ?[]const u8 = null;
    for (try commentCommits(arena, b, b.ref(name).?)) |hex| {
        if (x.target.len >= 4 and std.mem.startsWith(u8, hex, x.target)) {
            if (target != null)
                return report.fail("comment event: '{s}' is ambiguous", .{x.target});
            target = hex;
        }
    }
    const t = target orelse
        return report.fail("comment event succeeded on unknown '{s}'", .{x.target});
    const chain = (try appended(arena, b, a, name, report, "comment")) orelse return;
    if (chain.len != 1) return report.fail("comment event: expected one commit", .{});
    try checkIdentity(world, chain[0], report);
    const block = try commands.trailersOf(arena, chain[0].message);
    try expectBlock(report, "comment", block, &.{
        .{ .key = "X-Event", .value = kind },
        .{ .key = "X-Comment", .value = t },
    });
    if (x.kind == .edit) {
        // The new text is the body, exactly.
        const want = try eventBody(arena, x.text orelse "", &.{
            .{ "X-Event", kind },
            .{ "X-Comment", t },
        });
        if (!std.mem.eql(u8, want, afterSubject(chain[0].message))) try report.fail(
            "comment edit wrote\n{s}\nexpected after the subject\n{s}",
            .{ chain[0].message, want },
        );
    }
}

fn checkDescription(
    arena: Allocator,
    world: World,
    b: commands.Clone,
    a: commands.Clone,
    x: command.Edit,
    report: *Report,
) (Allocator.Error || error{NoRule})!void {
    const name = (try targetRef(b, x.id, report, "edit")) orelse return;
    const chain = (try appended(arena, b, a, name, report, "edit")) orelse return;
    // One commit: the other changes ride along on the event.
    if (chain.len != 1) return report.fail("edit --description wrote {d} commits", .{chain.len});
    const desc = chain[0];
    try checkIdentity(world, desc, report);
    var want: std.ArrayList(commands.Trailer) = .empty;
    if (x.changesFields()) {
        const previous = try b.naive(desc.parents[0].hex().slice());
        const resolved = (try commands.resolveExt(arena, b, x.ext, x.milestone, previous)) orelse
            return report.fail("edit succeeded with values the oracle rejects", .{});
        try want.appendSlice(arena, try commands.expectedEditTrailers(arena, x, resolved, previous));
    }
    try want.append(arena, .{ .key = "X-Event", .value = "description-edit" });
    const block = try commands.trailersOf(arena, desc.message);
    try expectBlock(report, "edit", block, want.items);
    var pairs: std.ArrayList([2][]const u8) = .empty;
    for (want.items) |t| try pairs.append(arena, .{ t.key, t.value });
    const text = try std.mem.join(arena, "\n\n", x.description);
    const body = try eventBody(arena, text, pairs.items);
    if (!std.mem.eql(u8, body, afterSubject(desc.message))) try report.fail(
        "description edit wrote\n{s}\nexpected after the subject\n{s}",
        .{ desc.message, body },
    );
}

/// What follows the subject: `<text>\n\nK: v\n...`, with the text trimmed
/// at the end and left out when empty, the way format 1 messages are laid
/// out.
fn eventBody(
    arena: Allocator,
    text: []const u8,
    trailer_list: []const [2][]const u8,
) Allocator.Error![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    const body = std.mem.trimEnd(u8, text, " \t\r\n");
    if (body.len > 0) w.writer.print("{s}\n\n", .{body}) catch return error.OutOfMemory;
    for (trailer_list) |t| {
        w.writer.print("{s}: {s}\n", .{ t[0], t[1] }) catch return error.OutOfMemory;
    }
    return w.written();
}

fn expectBlock(
    report: *Report,
    cmd: []const u8,
    block: commands.Block,
    want: []const commands.Trailer,
) Allocator.Error!void {
    if (block.trailers.len != want.len) {
        try report.fail(
            "{s}: {d} trailers written, expected {d}",
            .{ cmd, block.trailers.len, want.len },
        );
        return;
    }
    for (block.trailers, want) |g, w| {
        // Label order doesn't matter.
        const same_value = if (std.mem.eql(
            u8,
            g.key,
            "Labels",
        ) and std.mem.eql(u8, w.key, "Labels"))
            sameLabelSet(g.value, w.value)
        else
            std.mem.eql(u8, g.value, w.value);
        if (!std.mem.eql(u8, g.key, w.key) or !same_value)
            try report.fail(
                "{s}: trailer '{s}: {s}', expected '{s}: {s}'",
                .{ cmd, g.key, g.value, w.key, w.value },
            );
    }
}

fn sameLabelSet(a: []const u8, b: []const u8) bool {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const arena = fba.allocator();
    const la = commands.splitLabels(arena, a) catch return false;
    const lb = commands.splitLabels(arena, b) catch return false;
    return commands.sameSet(la, lb);
}

fn sameLines(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn checkIdentity(world: World, c: object.Commit, report: *Report) Allocator.Error!void {
    if (!std.mem.eql(u8, c.author.name, world.identity.name) or !std.mem.eql(
        u8,
        c.author.email,
        world.identity.email,
    ))
        try report.fail("commit author is not the world identity", .{});
}

fn isV4Uuid(id: []const u8) bool {
    if (id.len != 36) return false;
    for (id, 0..) |ch, i| {
        const hyphen = i == 8 or i == 13 or i == 18 or i == 23;
        if (hyphen != (ch == '-')) return false;
        if (!hyphen and !hex_fmt.isLowerDigit(ch)) return false;
    }
    return id[14] == '4' and (id[19] == '8' or id[19] == '9' or id[19] == 'a' or id[19] == 'b');
}

fn expectCloneUnchanged(
    arena: Allocator,
    format: object.ObjectFormat,
    b: World.Clone,
    a: World.Clone,
    report: *Report,
    objects_too: bool,
) Allocator.Error!void {
    if (objects_too) {
        const bo = try objectSet(arena, format, b);
        const ao = try objectSet(arena, format, a);
        if (bo.count() != ao.count())
            try report.fail(
                "clone '{s}': objects changed ({d} -> {d})",
                .{ a.name, bo.count(), ao.count() },
            );
    }
    if (b.refs.len != a.refs.len) {
        try report.fail("clone '{s}': refs changed", .{a.name});
    } else for (b.refs) |r| {
        const now = findRef(a, r.name);
        if (now == null or !std.mem.eql(u8, now.?, r.oid))
            try report.fail("clone '{s}': ref {s} changed", .{ a.name, r.name });
    }
    if (!configEqual(b, a)) try report.fail("clone '{s}': config changed", .{a.name});
}

const testing = std.testing;

test isOwnedRef {
    try testing.expect(isOwnedRef("refs/issues/abc"));
    try testing.expect(isOwnedRef("refs/remotes/origin/issues/abc"));
    try testing.expect(isOwnedRef("refs/issuez-sync/origin/merged/issues/abc"));
    try testing.expect(!isOwnedRef("refs/heads/main"));
    try testing.expect(!isOwnedRef("refs/remotes/origin/main"));
}

test "foreign refs and lost objects" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msg = "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n" ++
        "author T <t@e.x> 1 +0000\ncommitter T <t@e.x> 1 +0000\n\nx\n";
    const oid = object.hashObject(.sha1, .commit, msg).hex();
    const obj: World.StoredObject = .{ .kind = .commit, .data = msg };

    const before: World = .{ .clones = &.{.{
        .name = "a",
        .objects = &.{obj},
        .refs = &.{.{ .name = "refs/heads/main", .oid = oid.slice() }},
    }} };
    const after: World = .{ .clones = &.{.{ .name = "a" }} };

    var report: Report = .{ .arena = arena };
    try checkTransition(arena, before, after, null, .{ .read = &.{"version"} }, 0, &report);
    try testing.expect(!report.ok());
    try testing.expect(report.violations.items.len >= 2);

    var report2: Report = .{ .arena = arena };
    try checkTransition(arena, before, before, null, .{ .read = &.{"version"} }, 0, &report2);
    try testing.expect(report2.ok());

    // Unknown commands fail in the CLI and change nothing.
    var report3: Report = .{ .arena = arena };
    try checkTransition(arena, before, after, null, .{ .read = &.{"frobnicate"} }, 1, &report3);
    try testing.expect(!report3.ok());
}

test {
    _ = command;
    _ = upstream;
}

//! Snapshots and diffs, milestones, purges, fsck and the push check.

const std = @import("std");
const stableSort = @import("issuez").sort.stable;
const api = @import("api.zig");
const rt = @import("rt.zig");
const repo_mod = @import("repo.zig");
const read = @import("read.zig");
const issuez = @import("issuez");

const Allocator = std.mem.Allocator;
const Code = api.Code;
const Str = api.Str;
const Call = repo_mod.Call;
const Oid = issuez.backend.object.Oid;
const uuid_fmt = issuez.format.uuid;

// ─── Snapshots ─────────────────────────────────────────────────────────

const SnapEntry = struct { kind: api.Kind, id: Str, tip: api.Oid };

pub const SnapshotObj = struct {
    arena: *std.heap.ArenaAllocator,
    /// Sorted by kind, then ID.
    entries: []const SnapEntry,
};

const snapshot_magic = "issuez-snapshot 1\n";

fn makeSnapshot(a: Allocator, entries: []const SnapEntry) !SnapshotObj {
    const out = try a.alloc(SnapEntry, entries.len);
    for (entries, out) |e, *o| {
        o.* = .{ .kind = e.kind, .id = try rt.dupeZ(a, e.id.slice()), .tip = e.tip };
    }
    return .{ .arena = undefined, .entries = out };
}

fn lessEntry(_: void, x: SnapEntry, y: SnapEntry) bool {
    if (x.kind != y.kind) return @intFromEnum(x.kind) < @intFromEnum(y.kind);
    return std.mem.lessThan(u8, x.id.slice(), y.id.slice());
}

pub fn issuez_snapshot_take(
    repo: ?*api.Repo,
    cancel: ?*api.Cancel,
    out: ?*?*api.Snapshot,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.badArgument(err, "out is NULL");
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const a = c.arena();
    var entries: std.ArrayList(SnapEntry) = .empty;
    for ([_]struct { []const u8, api.Kind }{
        .{ issuez.engine.issue_ref_prefix, .issue },
        .{ issuez.engine.milestone_ref_prefix, .milestone },
    }) |ns| {
        const refs = c.session.backend.listRefs(a, ns[0]) catch |e| return c.fail(err, e);
        for (refs) |r| {
            const id = r.name[ns[0].len..];
            if (!uuid_fmt.isCanonical(id)) continue;
            entries.append(a, .{ .kind = ns[1], .id = Str.of(id), .tip = rt.oidOf(r.oid) }) catch
                return rt.oom(err);
        }
    }
    stableSort(SnapEntry, entries.items, {}, lessEntry);
    return rt.give(o, rt.owned(SnapshotObj, makeSnapshot, .{entries.items}), err);
}

const SnapshotReads = rt.Reads(api.Snapshot, SnapshotObj);
pub const issuez_snapshot_free = SnapshotReads.free();
pub const issuez_snapshot_len = SnapshotReads.count("entries");
pub fn issuez_snapshot_at(
    s: ?*const api.Snapshot,
    i: usize,
    kind: ?*api.Kind,
    id: ?*Str,
    tip: ?*api.Oid,
) callconv(.c) void {
    if (kind) |p| p.* = .unknown;
    if (id) |p| p.* = .{};
    if (tip) |p| p.* = .{};
    const o = rt.obj(SnapshotObj, s) orelse return;
    if (i >= o.entries.len) return;
    const e = o.entries[i];
    if (kind) |p| p.* = e.kind;
    if (id) |p| p.* = e.id;
    if (tip) |p| p.* = e.tip;
}

pub fn issuez_snapshot_decode(
    bytes: Str,
    out: ?*?*api.Snapshot,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.badArgument(err, "out is NULL");
    var scratch: std.heap.ArenaAllocator = .init(rt.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var entries: std.ArrayList(SnapEntry) = .empty;
    const text = bytes.slice();
    if (text.len > 0) {
        if (!std.mem.startsWith(u8, text, snapshot_magic))
            return rt.badArgument(err, "not an issuez snapshot (or a newer version)");
        var lines = std.mem.tokenizeScalar(u8, text[snapshot_magic.len..], '\n');
        while (lines.next()) |line| {
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            const k = parts.next() orelse "";
            const id = parts.next() orelse "";
            const hex = parts.next() orelse "";
            const kind: api.Kind = if (std.mem.eql(
                u8,
                k,
                "i",
            )) .issue else if (std.mem.eql(u8, k, "m")) .milestone else .unknown;
            const format: issuez.backend.object.ObjectFormat = switch (hex.len) {
                40 => .sha1,
                64 => .sha256,
                else => return rt.badArgument(err, "damaged snapshot"),
            };
            const parsed = issuez.backend.object.Oid.parseHex(format, hex) catch
                return rt.badArgument(err, "damaged snapshot");
            if (kind == .unknown or !uuid_fmt.isCanonical(id))
                return rt.badArgument(err, "damaged snapshot");
            const tip = rt.oidOf(parsed);
            entries.append(a, .{ .kind = kind, .id = Str.of(id), .tip = tip }) catch
                return rt.oom(err);
        }
    }
    stableSort(SnapEntry, entries.items, {}, lessEntry);
    return rt.give(o, rt.owned(SnapshotObj, makeSnapshot, .{entries.items}), err);
}

// ─── Milestones ────────────────────────────────────────────────────────

const Milestone = issuez.milestone.Milestone;

pub const MilestoneObj = struct {
    arena: ?*std.heap.ArenaAllocator = null,
    info: api.MilestoneInfo,
    problems: *rt.ProblemList,
};

fn buildMilestone(a: Allocator, m: Milestone) !MilestoneObj {
    var problems: rt.Problems = .empty;
    for (m.conflicts) |c| try problems.append(a, .{
        .kind = .conflict,
        .key = try std.fmt.allocPrint(a, "{f}", .{c.target}),
        .value = c.value,
        .message = "clones disagree",
    });
    return .{
        .info = .{
            .id = try rt.dupeZ(a, m.id),
            .tip = rt.oidOf(m.tip),
            .name = try rt.dupeZ(a, m.name),
            .description = try rt.dupeZ(a, m.description),
            .status = @intFromEnum(rt.mirrored(api.MilestoneStatus, m.status)),
            .due_date = if (m.due) |d| rt.dateOf(d) else .{},
            .created = .{ .unix_seconds = m.created },
            .updated = .{ .unix_seconds = m.updated },
            .has_status_changed = m.status_changed != null,
            .status_changed = .{ .unix_seconds = m.status_changed orelse 0 },
            .author = try rt.newPerson(a, m.author, m.author_id),
        },
        .problems = try rt.borrowedProblems(a, problems.items),
    };
}

pub fn issuez_milestone_load(
    repo: ?*api.Repo,
    id: Str,
    cancel: ?*api.Cancel,
    out: ?*?*api.Milestone,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.badArgument(err, "out is NULL");
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const found = c.catalog().find(c.arena(), id.slice()) catch |e| return c.fail(err, e);
    const m = found orelse return rt.notFound(err, id.slice(), "no such milestone");
    return rt.give(o, rt.owned(MilestoneObj, buildMilestone, .{m}), err);
}

pub fn issuez_milestone_load_at(
    repo: ?*api.Repo,
    id: Str,
    tip: ?*const api.Oid,
    cancel: ?*api.Cancel,
    out: ?*?*api.Milestone,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.badArgument(err, "out is NULL");
    const t = rt.oidFrom((tip orelse
        return rt.badArgument(err, "tip is NULL")).*) orelse
        return rt.badArgument(err, "tip is invalid");
    if (!uuid_fmt.isCanonical(id.slice())) return rt.badArgument(err, "not a full milestone UUID");
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    if (t.object_format != c.session.backend.objectFormat())
        return rt.badArgument(err, "tip uses another object format");
    const name = issuez.engine.refFor(
        c.arena(),
        issuez.engine.milestone_ref_prefix,
        id.slice(),
    ) catch |e| return c.fail(err, e);
    const m = c.catalog().load(c.arena(), .{ .name = name, .tip = t }) catch |e|
        return c.fail(err, e);
    return rt.give(o, rt.owned(MilestoneObj, buildMilestone, .{m}), err);
}

pub const MilestoneListObj = rt.Items(MilestoneObj);

pub fn issuez_milestone_list_all(
    repo: ?*api.Repo,
    cancel: ?*api.Cancel,
    out: ?*?*api.MilestoneList,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.badArgument(err, "out is NULL");
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const all = c.catalog().list(c.arena()) catch |e| return c.fail(err, e);
    return rt.give(o, rt.owned(MilestoneListObj, makeMilestoneList, .{all}), err);
}

fn makeMilestoneList(a: Allocator, all: []const Milestone) !MilestoneListObj {
    const items = try a.alloc(MilestoneObj, all.len);
    for (all, items) |m, *x| x.* = try buildMilestone(a, m);
    return .{ .arena = undefined, .items = items };
}

fn getM(m: ?*const api.Milestone) ?*MilestoneObj {
    return rt.obj(MilestoneObj, m);
}

pub fn issuez_milestone_free(m: ?*api.Milestone) callconv(.c) void {
    const o = getM(m) orelse return;
    if (o.arena) |a| rt.freeArena(a);
}
const MilestoneListReads = rt.Reads(api.MilestoneList, MilestoneListObj);
pub const issuez_milestone_list_len = MilestoneListReads.count("items");
pub fn issuez_milestone_list_at(
    l: ?*const api.MilestoneList,
    i: usize,
) callconv(.c) ?*const api.Milestone {
    const o = rt.obj(MilestoneListObj, l) orelse return null;
    return if (i < o.items.len) @ptrCast(&o.items[i]) else null;
}
pub const issuez_milestone_list_free = MilestoneListReads.free();
const MilestoneReads = rt.Reads(api.Milestone, MilestoneObj);
pub const issuez_milestone_info_of = MilestoneReads.ref("info");
pub fn issuez_milestone_problems(m: ?*const api.Milestone) callconv(.c) ?*const api.Problems {
    const o = getM(m) orelse return null;
    return @ptrCast(o.problems);
}

// ─── Purge ─────────────────────────────────────────────────────────────

pub const PurgeResultObj = struct {
    arena: *std.heap.ArenaAllocator,
    new_tip: api.Oid,
    exposed: []const Str,
    /// UUIDs of the attachments the purge took out of history.
    removed_attachments: []const Str = &.{},
    /// Every attachment the issue had; the removed ones end up first.
    had: []Str = &.{},
};

pub fn issuez_purge_issue(
    repo: ?*api.Repo,
    id: Str,
    actor: ?*const api.Actor,
    reason: Str,
    cancel: ?*api.Cancel,
    out: ?*?*api.PurgeResult,
    err: ?*?*api.Error,
) callconv(.c) Code {
    return purge(repo, id, null, actor, reason, cancel, out, err);
}

pub fn issuez_purge_comment(
    repo: ?*api.Repo,
    id: Str,
    comment: ?*const api.Oid,
    actor: ?*const api.Actor,
    reason: Str,
    cancel: ?*api.Cancel,
    out: ?*?*api.PurgeResult,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const cm = comment orelse return rt.badArgument(err, "comment is NULL");
    const oid = rt.oidFrom(cm.*) orelse
        return rt.badArgument(err, "comment is not a full object ID");
    return purge(repo, id, oid, actor, reason, cancel, out, err);
}

fn purge(
    repo: ?*api.Repo,
    id: Str,
    comment: ?Oid,
    actor: ?*const api.Actor,
    reason: Str,
    cancel: ?*api.Cancel,
    out: ?*?*api.PurgeResult,
    err: ?*?*api.Error,
) Code {
    const o = out orelse return rt.badArgument(err, "out is NULL");
    const ident = id.slice();
    if (!uuid_fmt.isCanonical(ident)) return rt.badArgument(err, "not a full issue UUID");
    var author: ?issuez.backend.object.Signature = null;
    if (actor) |act| switch (rt.actorSignature(act.*)) {
        .bad => |message| return rt.fail(err, .e_invalid_argument, "{s}", .{message}),
        .sig => |sig| author = sig,
    };
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    if (actor) |act| {
        if (act.user_id.len > 0) c.author_id = act.user_id.slice();
    }
    const a = c.arena();
    const backend = &c.session.backend;
    const ref_name = c.issueRef(ident) catch return rt.oom(err);
    // Before the purge drops them: the remotes that saw the old history,
    // and the attachments it had.
    const exposed = exposedRemotes(a, backend, ident) catch |e| return c.fail(err, e);
    const had = attachmentIds(&c, ref_name, null) catch |e| return c.fail(err, e);
    // The result before the purge: once it landed, filling it in needs no
    // memory. The attachments it removes are some of those it had.
    const made = rt.owned(PurgeResultObj, makePurgeResult, .{ exposed, had }) catch |e|
        return rt.failError(err, e, .{});
    var given = false;
    defer if (!given) rt.freeArena(made.arena);
    const purger = issuez.purge.Purge(repo_mod.Backend).fromRepo(c.engine());
    const spec: issuez.purge.Spec = .{ .reason = reason.slice(), .author = author };
    const result = (if (comment) |cm|
        purger.comment(a, ref_name, cm, spec, .{})
    else
        purger.issue(a, ref_name, spec, .{})) catch |e| switch (e) {
        error.IssueDisappeared => return rt.notFound(err, ident, "no such issue"),
        else => return c.fail(err, e),
    };
    // It happened: the host needs the receipt, and cancelling can't stop it now.
    c.session.backend.cancel = null;
    c.session.git.cancel = null;
    // The one way a purge that landed fails: its issue can't be read back.
    const kept = if (result.tip) |t|
        attachmentIds(&c, ref_name, t) catch |e| return c.fail(err, e)
    else
        &.{};
    made.new_tip = if (result.tip) |t| rt.oidOf(t) else .{};
    var removed: usize = 0;
    for (made.had) |id_| {
        const still = for (kept) |k| {
            if (std.mem.eql(u8, k, id_.slice())) break true;
        } else false;
        if (still) continue;
        made.had[removed] = id_;
        removed += 1;
    }
    made.removed_attachments = made.had[0..removed];
    given = true;
    o.* = @ptrCast(made);
    return .ok;
}

/// The UUIDs of every attachment the issue has at tip (null: its ref's),
/// removed ones included.
fn attachmentIds(c: *Call, ref_name: []const u8, tip: ?Oid) ![]const []const u8 {
    const a = c.arena();
    const at = tip orelse (try c.session.backend.resolveRef(ref_name)) orelse return &.{};
    const issue = try c.engine().load(a, .{ .name = ref_name, .tip = at });
    var out: std.ArrayList([]const u8) = .empty;
    for (issue.attachments) |x| try out.append(a, x.id);
    for (issue.removed_attachments) |x| try out.append(a, x.id);
    return out.items;
}

/// Remotes with a fetched copy of the issue: they had the purged commits
/// and keep them until the next sync replaces them. One synced by URL or
/// path, by the `url-<hash>` its refs are kept under.
fn exposedRemotes(arena: Allocator, backend: anytype, id: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try backend.remoteNames(arena)) |remote| {
        // Fetched from it, or pushed to it.
        const seen = try issuez.sync.recordRef(arena, remote, .seen, .issues, id);
        const pushed = try issuez.sync.recordRef(arena, remote, .pushed, .issues, id);
        const fetched = try std.fmt.allocPrint(
            arena,
            "refs/remotes/{s}/issues/{s}",
            .{ remote, id },
        );
        for ([_][]const u8{ seen, pushed, fetched }) |name| {
            if (try backend.resolveRef(name) == null) continue;
            try out.append(arena, remote);
            break;
        }
    }
    const records = "refs/issuez-sync/";
    for (try backend.listRefs(arena, records)) |r| {
        const rest = r.name[records.len..];
        const slash = std.mem.findScalar(u8, rest, '/') orelse continue;
        const key = rest[0..slash];
        if (!std.mem.startsWith(u8, key, "url-")) continue;
        const seen = try issuez.sync.recordRef(arena, key, .seen, .issues, id);
        const pushed = try issuez.sync.recordRef(arena, key, .pushed, .issues, id);
        if (!std.mem.eql(u8, r.name, seen) and !std.mem.eql(u8, r.name, pushed)) continue;
        const known = for (out.items) |o| {
            if (std.mem.eql(u8, o, key)) break true;
        } else false;
        if (!known) try out.append(arena, key);
    }
    return out.items;
}

fn makePurgeResult(
    a: Allocator,
    exposed: []const []const u8,
    had: []const []const u8,
) !PurgeResultObj {
    const ids = try a.alloc(Str, had.len);
    for (had, ids) |id, *o| o.* = try rt.dupeZ(a, id);
    return .{
        .arena = undefined,
        .new_tip = .{},
        .exposed = try rt.strs(a, exposed),
        .had = ids,
    };
}

const PurgeResultReads = rt.Reads(api.PurgeResult, PurgeResultObj);
pub const issuez_purge_result_attachment_count = PurgeResultReads.count("removed_attachments");
pub const issuez_purge_result_attachment_at = PurgeResultReads.at("removed_attachments");
pub const issuez_purge_result_free = PurgeResultReads.free();
pub const issuez_purge_result_new_tip = PurgeResultReads.field("new_tip");
pub const issuez_purge_result_exposed_remote_count = PurgeResultReads.count("exposed");
pub const issuez_purge_result_exposed_remote_at = PurgeResultReads.at("exposed");

// ─── Fsck ──────────────────────────────────────────────────────────────

const Fsck = issuez.fsck.Fsck(repo_mod.Backend);

pub const FsckReportObj = struct {
    arena: *std.heap.ArenaAllocator,
    issues: usize,
    milestones: usize,
    errors: usize,
    findings: []const api.FsckFinding,
};

pub fn issuez_fsck(
    repo: ?*api.Repo,
    cancel: ?*api.Cancel,
    out: ?*?*api.FsckReport,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.badArgument(err, "out is NULL");
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const report = Fsck.run(c.arena(), c.engine(), .{
        .check_bytes = c.repo.store_attachments,
    }) catch |e| return c.fail(err, e);
    // Fsck skips what it can't load, which a cancelled call can't: what it
    // has then isn't the whole answer.
    if (rt.cancelled(cancel)) return c.fail(err, error.Canceled);
    return rt.give(o, rt.owned(FsckReportObj, fsckReportObj, .{report}), err);
}

fn fsckReportObj(a: Allocator, report: Fsck.Report) !FsckReportObj {
    var findings: std.ArrayList(api.FsckFinding) = .empty;
    for (report.events) |e| {
        const Head = struct { api.FsckKind, api.Kind, []const u8 };
        const head: Head = switch (e) {
            .ok => continue,
            // Only a repair reports it.
            .repaired => unreachable,
            .problem => |p| .{
                .integrity,
                if (p.subject.kind == .issue) .issue else .milestone,
                p.subject.id,
            },
            .milestone_status => |m| .{ .milestone_status, .milestone, m.id },
            .attachment_trailer => |t| .{ .attachment_trailer, .issue, t.id },
            .attachment_missing => |m| .{ .attachment_missing, .issue, m.id },
            .attachment_corrupt => |m| .{ .attachment_corrupt, .issue, m.id },
            .derived_ref => |d| .{ .derived_ref, .issue, d.id },
            .attachments_failed => |f| .{
                .attachments_failed,
                if (f.id != null) .issue else .unknown,
                f.id orelse "",
            },
            .bytes_unchecked => .{ .bytes_unchecked, .unknown, "" },
            .orphans => .{ .orphans, .unknown, "" },
            .quarantined => |q| .{ .quarantined, .unknown, q.remote },
            .projection => |p| .{ .projection, .issue, p.id },
        };
        const kind, const subject_kind, const subject = head;
        try findings.append(a, .{
            .kind = @intFromEnum(kind),
            .is_error = e.isError(),
            .subject_kind = @intFromEnum(subject_kind),
            .subject = try rt.optZ(a, if (subject.len > 0) subject else null),
            .message = try rt.dupeZ(a, try std.fmt.allocPrint(a, "{f}", .{e})),
        });
    }
    return .{
        .arena = undefined,
        .issues = report.issues,
        .milestones = report.milestones,
        .errors = report.errors(),
        .findings = findings.items,
    };
}

const FsckReportReads = rt.Reads(api.FsckReport, FsckReportObj);
pub const issuez_fsck_report_issue_count = FsckReportReads.field("issues");
pub const issuez_fsck_report_milestone_count = FsckReportReads.field("milestones");
pub const issuez_fsck_report_error_count = FsckReportReads.field("errors");
pub const issuez_fsck_report_len = FsckReportReads.count("findings");
pub const issuez_fsck_report_at = FsckReportReads.refAt("findings");
pub const issuez_fsck_report_free = FsckReportReads.free();

// ─── Push check ────────────────────────────────────────────────────────

const PushCheck = issuez.PushCheck(repo_mod.Backend);
const check_mod = issuez.push_check;

/// A verdict with its timeline entries, behind the public part.
pub const VerdictObj = extern struct {
    public: api.PushVerdict,
    entries: ?[*]const read.EntryObj,
    attachments: ?[*]const api.Attachment,
};

pub const PushVerdictsObj = rt.Items(VerdictObj);

pub const PushOps = struct {
    policy: check_mod.Policy,
    /// The quarantine, as git's environment.
    vars: []const [2][]const u8,
};

/// The push check options; problems with them go to `problems`.
pub fn parsePushOps(a: Allocator, ops: []const api.Op, problems: *rt.Problems) !PushOps {
    var policy: check_mod.Policy = .{};
    var emails: std.ArrayList([]const u8) = .empty;
    var ids: std.ArrayList([]const u8) = .empty;
    var vars: std.ArrayList([2][]const u8) = .empty;
    for (ops, 0..) |op, i| {
        const check: rt.OpCheck = .at(a, problems, i);
        if (rt.hasReserved(op)) {
            try check.add(.unknown_target, "reserved fields must be zero");
            continue;
        }
        const s = op.str.slice();
        switch (@as(api.Opt, @enumFromInt(op.target))) {
            .pusher => {
                const user_id = op.person.user_id.slice();
                if (op.person.email.len == 0) {
                    try check.add(.unknown_target, "the pusher needs an email");
                    continue;
                }
                try emails.append(a, op.person.email.slice());
                if (user_id.len > 0 and !uuid_fmt.isCanonical(user_id)) {
                    try check.add(.unknown_target, "user_id isn't a UUID");
                } else if (user_id.len > 0) {
                    try ids.append(a, user_id);
                }
            },
            .pusher_email => if (s.len == 0) {
                try check.add(.unknown_target, "empty email");
            } else {
                try emails.append(a, s);
            },
            .pusher_user_id => if (uuid_fmt.isCanonical(s)) {
                try ids.append(a, s);
            } else {
                try check.add(.unknown_target, "not a UUID");
            },
            .author_policy => switch (@as(
                api.AuthorPolicy,
                @enumFromInt(std.math.cast(u32, op.num) orelse 0),
            )) {
                .any => policy.author_policy = .any,
                .warn => policy.author_policy = .warn,
                .enforce => policy.author_policy = .enforce,
                else => try check.add(.unknown_target, "not an issuez_author_policy"),
            },
            .allow_numbers => policy.allow_numbers = op.num != 0,
            .allow_purge => policy.allow_purge = op.num != 0,
            .object_dir => try vars.append(a, .{ "GIT_OBJECT_DIRECTORY", s }),
            .alternate_object_dirs => try vars.append(
                a,
                .{ "GIT_ALTERNATE_OBJECT_DIRECTORIES", s },
            ),
            else => try check.add(.unknown_target, "not a push check option"),
        }
    }
    policy.pusher_emails = emails.items;
    policy.pusher_ids = ids.items;
    return .{ .policy = policy, .vars = vars.items };
}

pub fn issuez_push_check(
    repo: ?*api.Repo,
    updates: ?[*]const api.RefUpdate,
    n_updates: usize,
    opts: ?[*]const api.Op,
    n_opts: usize,
    cancel: ?*api.Cancel,
    out: ?*?*api.PushVerdicts,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.badArgument(err, "out is NULL");
    o.* = null;
    if (updates == null and n_updates > 0) return rt.badArgument(err, "updates is NULL");
    var scratch: std.heap.ArenaAllocator = .init(rt.gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var problems: rt.Problems = .empty;
    const parsed = parsePushOps(sa, rt.sliceOf(api.Op, opts, n_opts), &problems) catch
        return rt.oom(err);
    const policy = parsed.policy;
    const vars = parsed.vars;
    if (problems.items.len > 0) return rt.badOps(err, problems.items, "invalid options");
    const list = sa.alloc(check_mod.Update, n_updates) catch return rt.oom(err);
    for (rt.sliceOf(api.RefUpdate, updates, n_updates), list) |u, *x| {
        if (u.ref.len == 0) return rt.badArgument(err, "an update without a ref");
        if (rt.hasReserved(u)) return rt.badArgument(err, "reserved fields must be zero");
        const old: ?Oid = if (u.old_oid.len == 0) null else rt.oidFrom(u.old_oid) orelse
            return rt.badArgument(err, "old_oid is not a full object ID");
        const new: ?Oid = if (u.new_oid.len == 0) null else rt.oidFrom(u.new_oid) orelse
            return rt.badArgument(err, "new_oid is not a full object ID");
        if (old == null and new == null) return rt.badArgument(err, "an update without old or new");
        x.* = .{ .ref = u.ref.slice(), .old = old, .new = new };
    }

    var c = (if (vars.len > 0)
        Call.beginPrivate(repo, cancel, vars)
    else
        Call.begin(repo, cancel)) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const verdicts = PushCheck.fromRepo(c.engine()).check(c.arena(), list, policy) catch |e|
        return c.fail(err, e);
    const args = .{ verdicts, read.Context.of(c.repo) };
    const r = rt.owned(PushVerdictsObj, makeVerdicts, args) catch |e|
        return rt.failError(err, e, .{});
    o.* = @ptrCast(r);
    for (verdicts) |v| if (!v.accept) return rt.fail(
        err,
        .e_rejected,
        "the push check refused {s}",
        .{v.update.ref},
    );
    return .ok;
}

fn verdictKind(k: check_mod.Kind) api.Kind {
    return switch (k) {
        .issue => .issue,
        .milestone => .milestone,
        .attachments => .attachments,
        .tombstone => .tombstone,
        .other, .invalid => .unknown,
    };
}

fn verdictProblem(a: Allocator, p: check_mod.Problem) !rt.ProblemSpec {
    const kind: api.ProblemKind = switch (p.kind) {
        .local_ref => .local_ref,
        .bad_ref_name => .bad_ref_name,
        .non_fast_forward => .non_fast_forward,
        .deleted => .ref_deleted,
        .invalid_history => .invalid_history,
        .format_version => .unsupported_format,
        .number_set, .number_changed => .read_only_field,
        .number_taken => .duplicate_number,
        .author_mismatch => .author_mismatch,
        .purged => .purged,
        .purge_not_allowed => .purge_not_allowed,
        .not_a_purge => .not_a_purge,
        .not_derived => .not_derived,
    };
    const value: []const u8 = if (p.commit) |oid| try oid.hexAlloc(a) else "";
    return .{
        .kind = kind,
        .field = switch (p.kind) {
            .number_set, .number_changed, .number_taken => .number,
            else => .unknown,
        },
        .value = value,
        .subject = p.subject,
        .message = p.message,
    };
}

fn makeVerdicts(
    a: Allocator,
    verdicts: []const check_mod.Verdict,
    ctx: read.Context,
) !PushVerdictsObj {
    const items = try a.alloc(VerdictObj, verdicts.len);
    for (verdicts, items) |v, *x| {
        var specs: rt.Problems = .empty;
        for (v.problems) |p| try specs.append(a, try verdictProblem(a, p));
        var entries: std.ArrayList(read.EntryObj) = .empty;
        var added: std.ArrayList(api.Attachment) = .empty;
        var issue_author: ?*const api.Person = null;
        if (v.issue) |issue| if (v.kind == .issue) {
            const built = try read.build(a, issue, ctx);
            const isNew = struct {
                fn f(commits: anytype, oid: api.Oid) bool {
                    for (commits) |nc| if (rt.oidEql(&rt.oidOf(nc.oid), &oid)) return true;
                    return false;
                }
            }.f;
            for (built.timeline) |e| if (isNew(v.new_commits, e.public.commit)) {
                try entries.append(a, e);
            };
            for (built.attachments) |att| if (isNew(v.new_commits, att.added_in)) {
                try added.append(a, att);
            };
            issue_author = built.info.author;
        };
        x.* = .{
            .public = .{
                .ref = try rt.dupeZ(a, v.update.ref),
                .kind = @intFromEnum(verdictKind(v.kind)),
                .id = try rt.dupeZ(a, v.id),
                .action = @intFromEnum(rt.mirrored(api.PushAction, v.action)),
                .accept = v.accept,
                .problems = @ptrCast(try rt.borrowedProblems(a, specs.items)),
                .needs_number = v.needs_number,
                .touches_locked = v.touches_locked,
                .commit_count = if (v.kind == .issue) entries.items.len else v.new_commits.len,
                .entry_count = entries.items.len,
                .issue_author = issue_author,
                .attachment_count = added.items.len,
            },
            .entries = entries.items.ptr,
            .attachments = added.items.ptr,
        };
    }
    return .{ .arena = undefined, .items = items };
}

const PushVerdictsReads = rt.Reads(api.PushVerdicts, PushVerdictsObj);
pub const issuez_push_verdicts_len = PushVerdictsReads.count("items");
pub const issuez_push_verdicts_at = PushVerdictsReads.publicAt("items");
pub fn issuez_push_verdict_entry_at(
    v: ?*const api.PushVerdict,
    k: usize,
) callconv(.c) ?*const api.Entry {
    const p = v orelse return null;
    const x: *const VerdictObj = @fieldParentPtr("public", p);
    if (k >= p.entry_count) return null;
    return &x.entries.?[k].public;
}
pub fn issuez_push_verdict_attachment_at(
    v: ?*const api.PushVerdict,
    k: usize,
) callconv(.c) ?*const api.Attachment {
    const p = v orelse return null;
    const x: *const VerdictObj = @fieldParentPtr("public", p);
    if (k >= p.attachment_count) return null;
    return &x.attachments.?[k];
}
pub const issuez_push_verdicts_free = PushVerdictsReads.free();

pub fn issuez_repo_commit_import(
    staging: ?*api.Repo,
    cancel: ?*api.Cancel,
    adopted: ?*usize,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const r = rt.obj(repo_mod.RepoObj, staging) orelse
        return rt.badArgument(err, "staging is NULL");
    const state = r.import_state orelse return rt.badArgument(err, "not a staging repo");
    if (state.committed) return rt.badArgument(err, "import already committed");
    var c = Call.begin(@ptrCast(r.import_target.?), cancel) catch |e|
        return rt.failError(err, e, .{});
    defer c.end();
    var other = Call.begin(staging, cancel) catch |e| return rt.failError(err, e, .{});
    defer other.end();
    const n = c.engine().adoptFrom(c.arena(), other.engine()) catch |e| switch (e) {
        error.RefConflict => return rt.fail(
            err,
            .e_contended,
            "the repository has one of the refs already",
            .{},
        ),
        error.CorruptIssue => return rt.fail(
            err,
            .e_corrupt,
            "a tip's object isn't in the repository's store",
            .{},
        ),
        else => return c.fail(err, e),
    };
    state.committed = true;
    if (adopted) |d| d.* = n;
    return .ok;
}

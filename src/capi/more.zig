//! Snapshots and diffs, milestones, the projection and sync.

const std = @import("std");
const stableSort = @import("issuez").sort.stable;
const api = @import("api.zig");
const rt = @import("rt.zig");
const repo_mod = @import("repo.zig");
const read = @import("read.zig");
const cache_mod = @import("cache.zig");
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
    encoded: Str,
};

const snapshot_magic = "issuez-snapshot 1\n";

fn makeSnapshot(entries: []const SnapEntry) !*SnapshotObj {
    const arena = try rt.newArena();
    errdefer rt.freeArena(arena);
    const a = arena.allocator();
    const out = try a.alloc(SnapEntry, entries.len);
    var text: std.Io.Writer.Allocating = .init(a);
    try text.writer.writeAll(snapshot_magic);
    for (entries, out) |e, *o| {
        o.* = .{ .kind = e.kind, .id = try rt.dupeZ(a, e.id.slice()), .tip = e.tip };
        var hex: [65]u8 = undefined;
        const n = rt.issuez_oid_hex(&e.tip, &hex);
        try text.writer.print("{c} {s} {s}\n", .{
            @as(u8, if (e.kind == .issue) 'i' else 'm'),
            e.id.slice(),
            hex[0..n],
        });
    }
    const s = try a.create(SnapshotObj);
    s.* = .{ .arena = arena, .entries = out, .encoded = try rt.dupeZ(a, text.written()) };
    return s;
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
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
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
            if (!issuez.format.uuid.isCanonical(id)) continue;
            entries.append(a, .{ .kind = ns[1], .id = Str.of(id), .tip = rt.oidOf(r.oid) }) catch
                return rt.fail(err, .e_nomem, "out of memory", .{});
        }
    }
    stableSort(SnapEntry, entries.items, {}, lessEntry);
    const s = makeSnapshot(entries.items) catch |e| return rt.failError(err, e, .{});
    o.* = @ptrCast(s);
    return .ok;
}

pub fn issuez_snapshot_free(s: ?*api.Snapshot) callconv(.c) void {
    const o = rt.obj(SnapshotObj, s) orelse return;
    rt.freeArena(o.arena);
}
pub fn issuez_snapshot_len(s: ?*const api.Snapshot) callconv(.c) usize {
    const o = rt.obj(SnapshotObj, s) orelse return 0;
    return o.entries.len;
}
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
pub fn issuez_snapshot_tip(
    s: ?*const api.Snapshot,
    kind: api.Kind,
    id: Str,
    out: ?*api.Oid,
) callconv(.c) bool {
    const o = rt.obj(SnapshotObj, s) orelse return false;
    for (o.entries) |e| if (e.kind == kind and std.mem.eql(u8, e.id.slice(), id.slice())) {
        if (out) |p| p.* = e.tip;
        return true;
    };
    return false;
}
pub fn issuez_snapshot_encode(s: ?*const api.Snapshot) callconv(.c) Str {
    const o = rt.obj(SnapshotObj, s) orelse return .{};
    return o.encoded;
}

pub fn issuez_snapshot_decode(
    bytes: Str,
    out: ?*?*api.Snapshot,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    var scratch: std.heap.ArenaAllocator = .init(rt.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var entries: std.ArrayList(SnapEntry) = .empty;
    const text = bytes.slice();
    if (text.len > 0) {
        if (!std.mem.startsWith(u8, text, snapshot_magic))
            return rt.fail(
                err,
                .e_invalid_argument,
                "not an issuez snapshot (or a newer version)",
                .{},
            );
        var lines = std.mem.tokenizeScalar(u8, text[snapshot_magic.len..], '\n');
        while (lines.next()) |line| {
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            const k = parts.next() orelse "";
            const id = parts.next() orelse "";
            const hex = parts.next() orelse "";
            var tip: api.Oid = .{};
            const kind: api.Kind = if (std.mem.eql(
                u8,
                k,
                "i",
            )) .issue else if (std.mem.eql(u8, k, "m")) .milestone else .unknown;
            if (kind == .unknown or !issuez.format.uuid.isCanonical(id) or
                rt.issuez_oid_parse(Str.of(hex), &tip, null) != .ok)
                return rt.fail(err, .e_invalid_argument, "damaged snapshot", .{});
            entries.append(a, .{ .kind = kind, .id = Str.of(id), .tip = tip }) catch
                return rt.fail(err, .e_nomem, "out of memory", .{});
        }
    }
    stableSort(SnapEntry, entries.items, {}, lessEntry);
    const s = makeSnapshot(entries.items) catch |e| return rt.failError(err, e, .{});
    o.* = @ptrCast(s);
    return .ok;
}

// ─── Diffs ─────────────────────────────────────────────────────────────

pub const DiffObj = struct {
    arena: *std.heap.ArenaAllocator,
    entries: []const api.DiffEntry,
};

pub fn issuez_diff_new(
    old_snap: ?*const api.Snapshot,
    new_snap: ?*const api.Snapshot,
    out: ?*?*api.Diff,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    const new = rt.obj(
        SnapshotObj,
        new_snap,
    ) orelse return rt.fail(err, .e_invalid_argument, "new_snap is NULL", .{});
    const old: []const SnapEntry = if (rt.obj(SnapshotObj, old_snap)) |s| s.entries else &.{};
    const d = diff(old, new.entries) catch |e| return rt.failError(err, e, .{});
    o.* = @ptrCast(d);
    return .ok;
}

fn diff(old: []const SnapEntry, new: []const SnapEntry) !*DiffObj {
    const arena = try rt.newArena();
    errdefer rt.freeArena(arena);
    const a = arena.allocator();
    var out: std.ArrayList(api.DiffEntry) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < old.len or j < new.len) {
        const take_old = j == new.len or (i < old.len and lessEntry({}, old[i], new[j]));
        const take_new = i == old.len or (j < new.len and lessEntry({}, new[j], old[i]));
        if (take_old) {
            try out.append(a, .{
                .kind = @intFromEnum(old[i].kind),
                .change = @intFromEnum(api.ChangeKind.removed),
                .id = try rt.dupeZ(a, old[i].id.slice()),
                .old_tip = old[i].tip,
                .new_tip = .{},
            });
            i += 1;
        } else if (take_new) {
            try out.append(a, .{
                .kind = @intFromEnum(new[j].kind),
                .change = @intFromEnum(api.ChangeKind.created),
                .id = try rt.dupeZ(a, new[j].id.slice()),
                .old_tip = .{},
                .new_tip = new[j].tip,
            });
            j += 1;
        } else {
            if (!rt.issuez_oid_eq(&old[i].tip, &new[j].tip)) try out.append(a, .{
                .kind = @intFromEnum(new[j].kind),
                .change = @intFromEnum(api.ChangeKind.updated),
                .id = try rt.dupeZ(a, new[j].id.slice()),
                .old_tip = old[i].tip,
                .new_tip = new[j].tip,
            });
            i += 1;
            j += 1;
        }
    }
    const d = try a.create(DiffObj);
    d.* = .{ .arena = arena, .entries = out.items };
    return d;
}

pub fn issuez_diff_len(d: ?*const api.Diff) callconv(.c) usize {
    const o = rt.obj(DiffObj, d) orelse return 0;
    return o.entries.len;
}
pub fn issuez_diff_at(d: ?*const api.Diff, i: usize) callconv(.c) ?*const api.DiffEntry {
    const o = rt.obj(DiffObj, d) orelse return null;
    return if (i < o.entries.len) &o.entries[i] else null;
}
pub fn issuez_diff_free(d: ?*api.Diff) callconv(.c) void {
    const o = rt.obj(DiffObj, d) orelse return;
    rt.freeArena(o.arena);
}

// ─── Milestones ────────────────────────────────────────────────────────

const Milestone = issuez.milestone.Milestone;

pub const MilestoneObj = struct {
    arena: ?*std.heap.ArenaAllocator = null,
    id: Str,
    tip: api.Oid,
    name: Str,
    description: Str,
    status: api.MilestoneStatus,
    due: ?api.Date,
    created: api.Time,
    updated: api.Time,
    status_changed: ?api.Time,
    author: api.Person,
    problems: *rt.ProblemList,
};

fn buildMilestone(a: Allocator, m: Milestone) !MilestoneObj {
    var problems: std.ArrayList(rt.ProblemSpec) = .empty;
    for (m.conflicts) |c| try problems.append(a, .{
        .kind = .conflict,
        .key = try std.fmt.allocPrint(a, "{f}", .{c.target}),
        .value = c.value,
        .message = "clones disagree",
    });
    return .{
        .id = try rt.dupeZ(a, m.id),
        .tip = rt.oidOf(m.tip),
        .name = try rt.dupeZ(a, m.name),
        .description = try rt.dupeZ(a, m.description),
        .status = switch (m.status) {
            .open => .open,
            .completed => .completed,
            .retired => .retired,
        },
        .due = if (m.due) |d| .{
            .year = @intCast(d.year),
            .month = d.month,
            .day = d.day,
        } else null,
        .created = .{ .unix_seconds = m.created },
        .updated = .{ .unix_seconds = m.updated },
        .status_changed = if (m.status_changed) |t| .{ .unix_seconds = t } else null,
        .author = try rt.personOf(a, m.author, m.author_id),
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
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const found = c.catalog().find(c.arena(), id.slice()) catch |e| return c.fail(err, e);
    const m = found orelse return rt.failWith(
        err,
        .e_not_found,
        .{ .subject = id.slice() },
        "no such milestone",
        .{},
    );
    return ownMilestone(m, o, err);
}

pub fn issuez_milestone_load_at(
    repo: ?*api.Repo,
    id: Str,
    tip: ?*const api.Oid,
    cancel: ?*api.Cancel,
    out: ?*?*api.Milestone,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    const t = rt.oidFrom((tip orelse
        return rt.fail(err, .e_invalid_argument, "tip is NULL", .{})).*) orelse
        return rt.fail(err, .e_invalid_argument, "tip is invalid", .{});
    if (!uuid_fmt.isCanonical(id.slice()))
        return rt.fail(err, .e_invalid_argument, "not a full milestone UUID", .{});
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    if (t.object_format != c.session.backend.objectFormat())
        return rt.fail(err, .e_invalid_argument, "tip uses another object format", .{});
    const name = issuez.engine.refFor(
        c.arena(),
        issuez.engine.milestone_ref_prefix,
        id.slice(),
    ) catch |e|
        return c.fail(err, e);
    const m = c.catalog().load(c.arena(), .{ .name = name, .tip = t }) catch |e|
        return c.fail(err, e);
    return ownMilestone(m, o, err);
}

fn ownMilestone(m: issuez.milestone.Milestone, o: *?*api.Milestone, err: ?*?*api.Error) Code {
    const arena = rt.newArena() catch return rt.fail(err, .e_nomem, "out of memory", .{});
    const obj = arena.allocator().create(MilestoneObj) catch {
        rt.freeArena(arena);
        return rt.fail(err, .e_nomem, "out of memory", .{});
    };
    obj.* = buildMilestone(arena.allocator(), m) catch {
        rt.freeArena(arena);
        return rt.fail(err, .e_nomem, "out of memory", .{});
    };
    obj.arena = arena;
    o.* = @ptrCast(obj);
    return .ok;
}

pub const MilestoneListObj = struct {
    arena: *std.heap.ArenaAllocator,
    items: []const MilestoneObj,
};

pub fn issuez_milestone_list_all(
    repo: ?*api.Repo,
    cancel: ?*api.Cancel,
    out: ?*?*api.MilestoneList,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const all = c.catalog().list(c.arena()) catch |e| return c.fail(err, e);
    const list = makeMilestoneList(all) catch |e| return rt.failError(err, e, .{});
    o.* = @ptrCast(list);
    return .ok;
}

fn makeMilestoneList(all: []const Milestone) !*MilestoneListObj {
    const arena = try rt.newArena();
    errdefer rt.freeArena(arena);
    const a = arena.allocator();
    const items = try a.alloc(MilestoneObj, all.len);
    for (all, items) |m, *x| x.* = try buildMilestone(a, m);
    const l = try a.create(MilestoneListObj);
    l.* = .{ .arena = arena, .items = items };
    return l;
}

fn getM(m: ?*const api.Milestone) ?*MilestoneObj {
    return rt.obj(MilestoneObj, m);
}

pub fn issuez_milestone_free(m: ?*api.Milestone) callconv(.c) void {
    const o = getM(m) orelse return;
    if (o.arena) |a| rt.freeArena(a);
}
pub fn issuez_milestone_list_len(l: ?*const api.MilestoneList) callconv(.c) usize {
    const o = rt.obj(MilestoneListObj, l) orelse return 0;
    return o.items.len;
}
pub fn issuez_milestone_list_at(
    l: ?*const api.MilestoneList,
    i: usize,
) callconv(.c) ?*const api.Milestone {
    const o = rt.obj(MilestoneListObj, l) orelse return null;
    return if (i < o.items.len) @ptrCast(&o.items[i]) else null;
}
pub fn issuez_milestone_list_free(l: ?*api.MilestoneList) callconv(.c) void {
    const o = rt.obj(MilestoneListObj, l) orelse return;
    rt.freeArena(o.arena);
}
pub fn issuez_milestone_id(m: ?*const api.Milestone) callconv(.c) Str {
    return if (getM(m)) |o| o.id else .{};
}
pub fn issuez_milestone_tip(m: ?*const api.Milestone) callconv(.c) api.Oid {
    return if (getM(m)) |o| o.tip else .{};
}
pub fn issuez_milestone_name(m: ?*const api.Milestone) callconv(.c) Str {
    return if (getM(m)) |o| o.name else .{};
}
pub fn issuez_milestone_description(m: ?*const api.Milestone) callconv(.c) Str {
    return if (getM(m)) |o| o.description else .{};
}
pub fn issuez_milestone_status_of(m: ?*const api.Milestone) callconv(.c) api.MilestoneStatus {
    return if (getM(m)) |o| o.status else .unknown;
}
pub fn issuez_milestone_due_date(m: ?*const api.Milestone, out: ?*api.Date) callconv(.c) bool {
    const d = (getM(m) orelse return false).due orelse return false;
    if (out) |p| p.* = d;
    return true;
}
pub fn issuez_milestone_created(m: ?*const api.Milestone) callconv(.c) api.Time {
    return if (getM(m)) |o| o.created else .{};
}
pub fn issuez_milestone_updated(m: ?*const api.Milestone) callconv(.c) api.Time {
    return if (getM(m)) |o| o.updated else .{};
}
pub fn issuez_milestone_status_changed(
    m: ?*const api.Milestone,
    out: ?*api.Time,
) callconv(.c) bool {
    const t = (getM(m) orelse return false).status_changed orelse return false;
    if (out) |o| o.* = t;
    return true;
}
pub fn issuez_milestone_author(m: ?*const api.Milestone) callconv(.c) ?*const api.Person {
    const o = getM(m) orelse return null;
    return &o.author;
}
pub fn issuez_milestone_problems(m: ?*const api.Milestone) callconv(.c) ?*const api.Problems {
    const o = getM(m) orelse return null;
    return @ptrCast(o.problems);
}

// ─── Projection ────────────────────────────────────────────────────────

const Projection = issuez.projection.Projection;

pub const ProjectionObj = struct {
    arena: *std.heap.ArenaAllocator,
    list: read.ListObj,
    proj: Projection,
    active_blockers: []const []const u32,
    milestone_ids: []const Str,
    milestone_progress: std.StringHashMapUnmanaged(api.Progress),
    problems: *rt.ProblemList,
    problems_of: []const *rt.ProblemList,
};

fn problemKind(k: issuez.projection.Problem.Kind) api.ProblemKind {
    return switch (k) {
        .parent_missing, .blocker_missing, .milestone_missing => .missing_target,
        .parent_self, .blocker_self => .self_reference,
        .parent_cycle, .blocker_cycle => .cycle,
        .too_deep => .too_deep,
        .too_many_leaves => .too_many,
        .invalid_value, .invalid_event, .event_in_other_issue => .invalid_stored_value,
        .pending_event => .pending_event,
        .closed_with_open_descendants => .open_children,
        .open_under_closed_ancestor => .closed_ancestor,
        .parent_deleted => .deleted_target,
        .milestone_retired => .milestone_closed,
        .duplicate_number => .duplicate_number,
        .open_in_completed_milestone => .milestone_open_work,
    };
}

fn problemField(k: issuez.projection.Problem.Kind) api.Field {
    return switch (k) {
        .parent_missing,
        .parent_self,
        .parent_cycle,
        .too_deep,
        .parent_deleted,
        .closed_with_open_descendants,
        .open_under_closed_ancestor,
        => .parent,
        .blocker_missing, .blocker_self, .blocker_cycle => .blocked_by,
        .milestone_missing, .milestone_retired, .open_in_completed_milestone => .milestone,
        else => .unknown,
    };
}

fn projectionSpec(a: Allocator, p: issuez.projection.Problem) !rt.ProblemSpec {
    return .{
        .kind = problemKind(p.kind),
        .field = problemField(p.kind),
        .key = p.key orelse "",
        .value = p.value orelse "",
        .subject = p.other orelse p.id,
        .message = try std.fmt.allocPrint(a, "{f}", .{p}),
    };
}

fn buildProjection(c: *Call, around: ?[]const u8) !?*ProjectionObj {
    const arena = try rt.newArena();
    errdefer rt.freeArena(arena);
    const a = arena.allocator();
    const engine = c.engine();
    // The whole repo through the cache; the projection keeps its entries.
    var held: std.ArrayList(*cache_mod.Entry) = .empty;
    errdefer for (held.items) |e| e.release();
    const issues = if (around) |id| blk: {
        const name = try std.fmt.allocPrint(a, "{s}{s}", .{ issuez.engine.issue_ref_prefix, id });
        const tip = (try c.session.backend.resolveRef(name)) orelse {
            rt.freeArena(arena);
            return null;
        };
        break :blk try engine.loadAround(a, .{ .name = name, .tip = tip });
    } else blk: {
        const refs = try engine.refs(a);
        if (refs.len > engine.limits.max_guard_scan) return error.GuardScanTooLarge;
        var skipped: std.ArrayList([]const u8) = .empty;
        break :blk try c.repo.cache.loadAll(a, engine, refs, &held, &skipped, read.isDamaged);
    };
    const proj = try c.catalog().project(a, issues, .{});
    const ctx: read.Context = .of(c.repo);

    const objs = try a.alloc(read.IssueObj, proj.issues.len);
    for (proj.issues, objs) |issue, *o| o.* = try read.build(a, issue, ctx);
    const active = try a.alloc([]const u32, proj.issues.len);
    for (active, 0..) |*x, i| x.* = try proj.activeBlockers(a, @intCast(i));
    const ms = try a.alloc(Str, proj.issues.len);
    var progress: std.StringHashMapUnmanaged(api.Progress) = .empty;
    for (ms, 0..) |*x, i| {
        const m = proj.milestone[i] orelse {
            x.* = .{};
            continue;
        };
        x.* = try rt.dupeZ(a, m);
        const gop = try progress.getOrPut(a, x.slice());
        if (!gop.found_existing) {
            const pr = try proj.milestoneProgress(a, m);
            gop.value_ptr.* = .{ .done = pr.closed, .total = pr.total };
        }
    }
    var all: std.ArrayList(rt.ProblemSpec) = .empty;
    for (proj.problems) |p| try all.append(a, try projectionSpec(a, p));
    const per = try a.alloc(*rt.ProblemList, proj.issues.len);
    for (per, 0..) |*x, i| {
        var specs: std.ArrayList(rt.ProblemSpec) = .empty;
        for (proj.problemsOf(@intCast(i))) |p| try specs.append(a, try projectionSpec(a, p));
        x.* = try rt.borrowedProblems(a, specs.items);
    }
    const obj = try a.create(ProjectionObj);
    obj.* = .{
        .arena = arena,
        .list = .{
            .arena = arena,
            .issues = objs,
            .skipped = &.{},
            .borrowed = true,
            .held = held.items,
        },
        .proj = proj,
        .active_blockers = active,
        .milestone_ids = ms,
        .milestone_progress = progress,
        .problems = try rt.borrowedProblems(a, all.items),
        .problems_of = per,
    };
    return obj;
}

pub fn issuez_projection_build(
    repo: ?*api.Repo,
    cancel: ?*api.Cancel,
    out: ?*?*api.Projection,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const p = (buildProjection(&c, null) catch |e| return c.fail(err, e)).?;
    o.* = @ptrCast(p);
    return .ok;
}

pub fn issuez_projection_around(
    repo: ?*api.Repo,
    id: Str,
    cancel: ?*api.Cancel,
    out: ?*?*api.Projection,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    if (!issuez.format.uuid.isCanonical(id.slice())) return rt.fail(
        err,
        .e_invalid_argument,
        "not a full issue UUID",
        .{},
    );
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const p = (buildProjection(&c, id.slice()) catch |e| return c.fail(err, e)) orelse
        return rt.failWith(err, .e_not_found, .{ .subject = id.slice() }, "no such issue", .{});
    o.* = @ptrCast(p);
    return .ok;
}

fn getP(p: ?*const api.Projection) ?*ProjectionObj {
    return rt.obj(ProjectionObj, p);
}

fn indexOf(o: *const ProjectionObj, id: Str) ?u32 {
    return o.proj.find(id.slice());
}

fn idAt(o: *const ProjectionObj, i: u32) Str {
    return o.list.issues[i].id;
}

pub fn issuez_projection_free(p: ?*api.Projection) callconv(.c) void {
    const o = getP(p) orelse return;
    for (o.list.held) |e| e.release();
    rt.freeArena(o.arena);
}
pub fn issuez_projection_issues(p: ?*const api.Projection) callconv(.c) ?*const api.IssueList {
    const o = getP(p) orelse return null;
    return @ptrCast(&o.list);
}
pub fn issuez_projection_root_count(p: ?*const api.Projection) callconv(.c) usize {
    return if (getP(p)) |o| o.proj.roots.len else 0;
}
pub fn issuez_projection_root_at(p: ?*const api.Projection, i: usize) callconv(.c) Str {
    const o = getP(p) orelse return .{};
    return if (i < o.proj.roots.len) idAt(o, o.proj.roots[i]) else .{};
}
pub fn issuez_projection_child_count(p: ?*const api.Projection, id: Str) callconv(.c) usize {
    const o = getP(p) orelse return 0;
    const i = indexOf(o, id) orelse return 0;
    return o.proj.children[i].len;
}
pub fn issuez_projection_child_at(p: ?*const api.Projection, id: Str, k: usize) callconv(.c) Str {
    const o = getP(p) orelse return .{};
    const i = indexOf(o, id) orelse return .{};
    const list = o.proj.children[i];
    return if (k < list.len) idAt(o, list[k]) else .{};
}
pub fn issuez_projection_active_blocker_count(
    p: ?*const api.Projection,
    id: Str,
) callconv(.c) usize {
    const o = getP(p) orelse return 0;
    const i = indexOf(o, id) orelse return 0;
    return o.active_blockers[i].len;
}
pub fn issuez_projection_active_blocker_at(
    p: ?*const api.Projection,
    id: Str,
    k: usize,
) callconv(.c) Str {
    const o = getP(p) orelse return .{};
    const i = indexOf(o, id) orelse return .{};
    const list = o.active_blockers[i];
    return if (k < list.len) idAt(o, list[k]) else .{};
}
pub fn issuez_projection_blocking_count(p: ?*const api.Projection, id: Str) callconv(.c) usize {
    const o = getP(p) orelse return 0;
    const i = indexOf(o, id) orelse return 0;
    return o.proj.blocks[i].len;
}
pub fn issuez_projection_blocking_at(
    p: ?*const api.Projection,
    id: Str,
    k: usize,
) callconv(.c) Str {
    const o = getP(p) orelse return .{};
    const i = indexOf(o, id) orelse return .{};
    const list = o.proj.blocks[i];
    return if (k < list.len) idAt(o, list[k]) else .{};
}
pub fn issuez_projection_progress(
    p: ?*const api.Projection,
    id: Str,
    out: ?*api.Progress,
) callconv(.c) bool {
    const o = getP(p) orelse return false;
    const i = indexOf(o, id) orelse return false;
    const pr = o.proj.progress(i) orelse return false;
    if (out) |x| x.* = .{ .done = pr.closed, .total = pr.total };
    return true;
}
pub fn issuez_projection_milestone_of(p: ?*const api.Projection, id: Str) callconv(.c) Str {
    const o = getP(p) orelse return .{};
    const i = indexOf(o, id) orelse return .{};
    return o.milestone_ids[i];
}
pub fn issuez_projection_milestone_progress(
    p: ?*const api.Projection,
    milestone_id: Str,
) callconv(.c) api.Progress {
    const o = getP(p) orelse return .{};
    return o.milestone_progress.get(milestone_id.slice()) orelse .{};
}
pub fn issuez_projection_problems(
    p: ?*const api.Projection,
    id: Str,
) callconv(.c) ?*const api.Problems {
    const o = getP(p) orelse return null;
    if (id.len == 0) return @ptrCast(o.problems);
    const i = indexOf(o, id) orelse return null;
    return @ptrCast(o.problems_of[i]);
}

// ─── Sync ──────────────────────────────────────────────────────────────

pub const SyncReportObj = struct {
    arena: *std.heap.ArenaAllocator,
    items: []const api.SyncItem,
    ok: bool,
};

pub const SyncOps = struct { push: bool = true, attachments: bool = true };

/// The sync options; problems with them go to `problems`.
pub fn parseSyncOps(
    a: Allocator,
    ops: []const api.Op,
    problems: *std.ArrayList(rt.ProblemSpec),
) Allocator.Error!SyncOps {
    var out: SyncOps = .{};
    for (ops, 0..) |op, i| if (rt.hasReserved(op)) {
        try problems.append(a, rt.reservedProblem(@intCast(i)));
    } else switch (@as(api.Opt, @enumFromInt(op.target))) {
        .sync_push => out.push = op.num != 0,
        .sync_attachments => out.attachments = op.num != 0,
        else => try problems.append(a, .{
            .kind = .unknown_target,
            .message = "not a sync option",
            .op_index = @intCast(i),
        }),
    };
    return out;
}

pub fn issuez_sync(
    repo: ?*api.Repo,
    remote: Str,
    opts: ?[*]const api.Op,
    n_opts: usize,
    cancel: ?*api.Cancel,
    out: ?*?*api.SyncReport,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    var problems: std.ArrayList(rt.ProblemSpec) = .empty;
    var scratch: std.heap.ArenaAllocator = .init(rt.gpa);
    defer scratch.deinit();
    const so = parseSyncOps(
        scratch.allocator(),
        if (opts) |p| p[0..n_opts] else &.{},
        &problems,
    ) catch return rt.fail(err, .e_nomem, "out of memory", .{});
    const push = so.push;
    const attachments = so.attachments;
    if (problems.items.len > 0)
        return rt.failWith(
            err,
            .e_invalid_value,
            .{ .problems = problems.items },
            "invalid options",
            .{},
        );
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const a = c.arena();
    const sync = repo_mod.Sync.init(&c.session.backend);
    var entries: std.ArrayList(issuez.sync.Entry) = .empty;
    var sent: []const issuez.sync.PushReport.Pushed = &.{};
    if (push) {
        // Without attachments the derived refs still sync; their bytes
        // aren't uploaded.
        const options: issuez.sync.PushOptions = if (attachments) .{} else .{
            .before_push = .{ .context = undefined, .run = skipUploads },
        };
        const report = sync.sync(a, remote.slice(), options) catch |e| return c.fail(err, e);
        entries.appendSlice(
            a,
            report.merge.entries,
        ) catch return rt.fail(err, .e_nomem, "out of memory", .{});
        for (report.push.merges) |m| entries.appendSlice(
            a,
            m.entries,
        ) catch return rt.fail(err, .e_nomem, "out of memory", .{});
        sent = report.push.refs;
    } else {
        const report = sync.merge(a, remote.slice(), .{}) catch |e| return c.fail(err, e);
        entries.appendSlice(
            a,
            report.entries,
        ) catch return rt.fail(err, .e_nomem, "out of memory", .{});
    }
    const r = makeSyncReport(&c, remote.slice(), entries.items, sent) catch |e|
        return rt.failError(err, e, .{});
    o.* = @ptrCast(r);
    return .ok;
}

fn skipUploads(
    _: *anyopaque,
    _: []const u8,
    _: []const issuez.attachments.Upload,
) anyerror!void {}

/// One item per issue or milestone: its last merge outcome, PUSHED when
/// only the push touched it, with both tips after the sync.
fn makeSyncReport(
    c: *Call,
    remote: []const u8,
    entries: []const issuez.sync.Entry,
    sent: []const issuez.sync.PushReport.Pushed,
) !*SyncReportObj {
    const arena = try rt.newArena();
    errdefer rt.freeArena(arena);
    const a = arena.allocator();
    const Key = struct { issuez.sync.Namespace, []const u8 };
    var order: std.ArrayList(Key) = .empty;
    var outcomes: std.ArrayList(?issuez.sync.Outcome) = .empty;
    var pushed_tip: std.ArrayList(?Oid) = .empty;
    var was_pushed: std.ArrayList(bool) = .empty;
    const find = struct {
        fn f(keys: []const Key, ns: issuez.sync.Namespace, id: []const u8) ?usize {
            for (keys, 0..) |k, i| if (k[0] == ns and std.mem.eql(u8, k[1], id)) return i;
            return null;
        }
    }.f;
    for (entries) |e| {
        if (find(order.items, e.namespace, e.id)) |i| {
            outcomes.items[i] = e.outcome;
            continue;
        }
        try order.append(a, .{ e.namespace, e.id });
        try outcomes.append(a, e.outcome);
        try pushed_tip.append(a, null);
        try was_pushed.append(a, false);
    }
    for (sent) |p| {
        const i = find(order.items, p.namespace, p.id) orelse blk: {
            try order.append(a, .{ p.namespace, p.id });
            try outcomes.append(a, null);
            try pushed_tip.append(a, null);
            try was_pushed.append(a, false);
            break :blk order.items.len - 1;
        };
        pushed_tip.items[i] = p.tip;
        was_pushed.items[i] = true;
    }

    const items = try a.alloc(api.SyncItem, order.items.len);
    var ok = true;
    for (
        order.items,
        outcomes.items,
        pushed_tip.items,
        was_pushed.items,
        items,
    ) |k, o, pt, sent_it, *x| {
        const ns, const id = k;
        const kind: api.Kind = if (ns == .milestones) .milestone else .issue;
        const prefix = if (kind == .milestone)
            issuez.engine.milestone_ref_prefix
        else
            issuez.engine.issue_ref_prefix;
        const name = try std.fmt.allocPrint(c.arena(), "{s}{s}", .{ prefix, id });
        const tip: ?Oid = c.session.backend.resolveRef(name) catch null;
        const outcome: api.SyncOutcome = if (o) |known| switch (known) {
            .created => .new,
            .fast_forwarded => .fast_forward,
            .merged => .merged,
            .up_to_date, .local_ahead => if (sent_it) .pushed else .up_to_date,
            .quarantined => .quarantined,
            .purged => .purged,
        } else .pushed;
        if (outcome == .quarantined) ok = false;
        // The remote's tip: what was pushed, else what was last fetched.
        const remote_tip: ?Oid = if (sent_it) pt else blk: {
            const seen = try issuez.sync.recordRef(c.arena(), remote, .seen, ns, id);
            break :blk c.session.backend.resolveRef(seen) catch null;
        };
        x.* = .{
            .kind = @intFromEnum(kind),
            .id = try rt.dupeZ(a, id),
            .outcome = @intFromEnum(outcome),
            .local_tip = if (tip) |t| rt.oidOf(t) else .{},
            .remote_tip = if (remote_tip) |t| rt.oidOf(t) else .{},
            .reason = if (o) |known| switch (known) {
                .quarantined => |reason| try rt.dupeZ(a, reason.describe()),
                else => .{},
            } else .{},
        };
    }
    const r = try a.create(SyncReportObj);
    r.* = .{ .arena = arena, .items = items, .ok = ok };
    return r;
}

pub fn issuez_sync_report_len(r: ?*const api.SyncReport) callconv(.c) usize {
    const o = rt.obj(SyncReportObj, r) orelse return 0;
    return o.items.len;
}
pub fn issuez_sync_report_at(
    r: ?*const api.SyncReport,
    i: usize,
) callconv(.c) ?*const api.SyncItem {
    const o = rt.obj(SyncReportObj, r) orelse return null;
    return if (i < o.items.len) &o.items[i] else null;
}
pub fn issuez_sync_report_ok(r: ?*const api.SyncReport) callconv(.c) bool {
    const o = rt.obj(SyncReportObj, r) orelse return false;
    return o.ok;
}
pub fn issuez_sync_report_free(r: ?*api.SyncReport) callconv(.c) void {
    const o = rt.obj(SyncReportObj, r) orelse return;
    rt.freeArena(o.arena);
}

pub fn issuez_quarantine_resolve(
    repo: ?*api.Repo,
    remote: Str,
    kind: api.Kind,
    id: Str,
    choice: api.QuarantineChoice,
    cancel: ?*api.Cancel,
    err: ?*?*api.Error,
) callconv(.c) Code {
    _ = kind;
    const resolution: issuez.sync.Resolution = switch (choice) {
        .keep_local => .keep_local,
        .take_remote => .accept_remote,
        else => return rt.fail(err, .e_invalid_argument, "not a quarantine choice", .{}),
    };
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const sync = repo_mod.Sync.init(&c.session.backend);
    _ = sync.resolve(
        c.arena(),
        remote.slice(),
        id.slice(),
        resolution,
    ) catch |e|
        return c.fail(err, e);
    return .ok;
}

// ─── Purge ─────────────────────────────────────────────────────────────

pub const PurgeResultObj = struct {
    arena: *std.heap.ArenaAllocator,
    new_tip: api.Oid,
    exposed: []const Str,
    /// UUIDs of the attachments the purge took out of history.
    removed_attachments: []const Str = &.{},
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
    const cm = comment orelse return rt.fail(err, .e_invalid_argument, "comment is NULL", .{});
    const oid = rt.oidFrom(cm.*) orelse
        return rt.fail(err, .e_invalid_argument, "comment is not a full object ID", .{});
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
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    const ident = id.slice();
    if (!issuez.format.uuid.isCanonical(ident))
        return rt.fail(err, .e_invalid_argument, "not a full issue UUID", .{});
    var author: ?issuez.backend.object.Signature = null;
    if (actor) |act| {
        if (rt.hasReserved(act.*)) return rt.fail(
            err,
            .e_invalid_argument,
            "reserved fields must be zero",
            .{},
        );
        if (act.email.len == 0) return rt.fail(
            err,
            .e_invalid_argument,
            "the actor needs an email",
            .{},
        );
        const time = if (act.at) |t| t.* else api.Time{
            .unix_seconds = std.Io.Timestamp.now(rt.io(), .real).toSeconds(),
        };
        author = .{
            .name = if (act.name.len > 0) act.name.slice() else act.email.slice(),
            .email = act.email.slice(),
            .time = time.unix_seconds,
            .tz_offset_minutes = time.tz_offset_minutes,
        };
        if (act.user_id.len > 0 and !issuez.format.uuid.isCanonical(act.user_id.slice()))
            return rt.fail(err, .e_invalid_argument, "the actor's user_id must be a UUID", .{});
    }
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    if (actor) |act| {
        if (act.user_id.len > 0) c.author_id = act.user_id.slice();
    }
    const a = c.arena();
    const backend = &c.session.backend;
    const ref_name = std.fmt.allocPrint(
        a,
        "{s}{s}",
        .{ issuez.engine.issue_ref_prefix, ident },
    ) catch
        return rt.fail(err, .e_nomem, "out of memory", .{});
    // Before the purge drops them: the remotes that saw the old history,
    // and the attachments it had.
    const exposed = exposedRemotes(a, backend, ident) catch |e| return c.fail(err, e);
    const had = attachmentIds(&c, ref_name, null) catch |e| return c.fail(err, e);
    const purger = issuez.purge.Purge(repo_mod.Backend).fromRepo(c.engine());
    const spec: issuez.purge.Spec = .{ .reason = reason.slice(), .author = author };
    const result = (if (comment) |cm|
        purger.comment(a, ref_name, cm, spec, .{})
    else
        purger.issue(a, ref_name, spec, .{})) catch |e| switch (e) {
        error.IssueDisappeared => return rt.failWith(
            err,
            .e_not_found,
            .{ .subject = ident },
            "no such issue",
            .{},
        ),
        else => return c.fail(err, e),
    };
    // It happened: the host needs the receipt, and cancelling can't stop it now.
    c.session.backend.cancel = null;
    c.session.git.cancel = null;
    const kept = if (result.tip) |t|
        attachmentIds(&c, ref_name, t) catch |e| return c.fail(err, e)
    else
        &.{};
    var removed: std.ArrayList([]const u8) = .empty;
    for (had) |id_| {
        const still = for (kept) |k| {
            if (std.mem.eql(u8, k, id_)) break true;
        } else false;
        if (!still) removed.append(
            a,
            id_,
        ) catch return rt.fail(err, .e_nomem, "out of memory", .{});
    }
    const r = makePurgeResult(result, exposed, removed.items) catch |e|
        return rt.failError(err, e, .{});
    o.* = @ptrCast(r);
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
    result: issuez.purge.Result,
    exposed: []const []const u8,
    removed: []const []const u8,
) !*PurgeResultObj {
    const arena = try rt.newArena();
    errdefer rt.freeArena(arena);
    const a = arena.allocator();
    const names = try a.alloc(Str, exposed.len);
    for (exposed, names) |e, *n| n.* = try rt.dupeZ(a, e);
    const ids = try a.alloc(Str, removed.len);
    for (removed, ids) |x, *n| n.* = try rt.dupeZ(a, x);
    const r = try a.create(PurgeResultObj);
    r.* = .{
        .arena = arena,
        .new_tip = if (result.tip) |t| rt.oidOf(t) else .{},
        .exposed = names,
        .removed_attachments = ids,
    };
    return r;
}

pub fn issuez_purge_result_attachment_count(r: ?*const api.PurgeResult) callconv(.c) usize {
    const o = rt.obj(PurgeResultObj, r) orelse return 0;
    return o.removed_attachments.len;
}
pub fn issuez_purge_result_attachment_at(r: ?*const api.PurgeResult, i: usize) callconv(.c) Str {
    const o = rt.obj(PurgeResultObj, r) orelse return .{};
    return if (i < o.removed_attachments.len) o.removed_attachments[i] else .{};
}

pub fn issuez_purge_result_free(r: ?*api.PurgeResult) callconv(.c) void {
    const o = rt.obj(PurgeResultObj, r) orelse return;
    rt.freeArena(o.arena);
}
pub fn issuez_purge_result_new_tip(r: ?*const api.PurgeResult) callconv(.c) api.Oid {
    const o = rt.obj(PurgeResultObj, r) orelse return .{};
    return o.new_tip;
}
pub fn issuez_purge_result_exposed_remote_count(r: ?*const api.PurgeResult) callconv(.c) usize {
    const o = rt.obj(PurgeResultObj, r) orelse return 0;
    return o.exposed.len;
}
pub fn issuez_purge_result_exposed_remote_at(
    r: ?*const api.PurgeResult,
    i: usize,
) callconv(.c) Str {
    const o = rt.obj(PurgeResultObj, r) orelse return .{};
    return if (i < o.exposed.len) o.exposed[i] else .{};
}

// ─── Attachment bytes ──────────────────────────────────────────────────

pub const BytesObj = struct {
    arena: *std.heap.ArenaAllocator,
    data: Str,
};

pub fn makeBytes(data: []const u8) !*BytesObj {
    const arena = try rt.newArena();
    errdefer rt.freeArena(arena);
    const a = arena.allocator();
    const b = try a.create(BytesObj);
    b.* = .{ .arena = arena, .data = try rt.dupeZ(a, data) };
    return b;
}

pub fn issuez_bytes_data(b: ?*const api.Bytes) callconv(.c) Str {
    const o = rt.obj(BytesObj, b) orelse return .{};
    return o.data;
}

pub fn issuez_bytes_free(b: ?*api.Bytes) callconv(.c) void {
    const o = rt.obj(BytesObj, b) orelse return;
    rt.freeArena(o.arena);
}

const AttachmentStore = issuez.Attachments(repo_mod.Backend);

pub fn issuez_attachment_read(
    repo: ?*api.Repo,
    issue_id: Str,
    attachment_id: Str,
    cancel: ?*api.Cancel,
    out: ?*?*api.Bytes,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    if (!issuez.format.uuid.isCanonical(issue_id.slice()))
        return rt.fail(err, .e_invalid_argument, "not a full issue UUID", .{});
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const a = c.arena();
    const prefix = issuez.engine.issue_ref_prefix;
    const ref_name = std.fmt.allocPrint(a, "{s}{s}", .{ prefix, issue_id.slice() }) catch
        return rt.fail(err, .e_nomem, "out of memory", .{});
    const tip = (c.session.backend.resolveRef(ref_name) catch |e| return c.fail(err, e)) orelse
        return rt.failWith(err, .e_not_found, .{
            .subject = issue_id.slice(),
        }, "no such issue", .{});
    const issue = c.engine().load(a, .{ .name = ref_name, .tip = tip }) catch |e|
        return c.fail(err, e);
    const want = attachment_id.slice();
    var hit: ?issuez.model.issue.Attachment = null;
    for (issue.attachments) |x| if (std.mem.eql(u8, x.id, want)) {
        hit = x;
    };
    for (issue.removed_attachments) |x| if (std.mem.eql(u8, x.id, want)) {
        hit = x;
    };
    const att = hit orelse
        return rt.failWith(err, .e_not_found, .{ .subject = want }, "no such attachment", .{});
    const store = AttachmentStore.fromRepo(c.engine());
    const content = store.read(a, att) catch |e| return c.fail(err, e);
    switch (content) {
        .bytes => |data| {
            const b = makeBytes(data) catch |e| return rt.failError(err, e, .{});
            o.* = @ptrCast(b);
            return .ok;
        },
        .missing => return rt.failWith(err, .e_lfs, .{ .subject = want }, "the " ++
            "attachment's bytes aren't in this clone (git lfs fetch)", .{}),
        .corrupt => return rt.failWith(err, .e_corrupt, .{ .subject = want }, "the " ++
            "attachment's stored bytes don't match it", .{}),
    }
}

// ─── Settings ──────────────────────────────────────────────────────────

const settings_mod = issuez.settings;

fn parseSettingsOps(
    a: Allocator,
    ops: []const api.Op,
    problems: *std.ArrayList(rt.ProblemSpec),
) Allocator.Error!settings_mod.WriteSpec {
    var done: ?std.ArrayList([]const u8) = null;
    var workflow: ?std.ArrayList([]const u8) = null;
    var done_unset = false;
    var workflow_unset = false;
    for (ops, 0..) |op, i| {
        const index: i64 = @intCast(i);
        if (rt.hasReserved(op)) {
            try problems.append(a, rt.reservedProblem(index));
            continue;
        }
        const verb: api.Verb = @enumFromInt(op.verb);
        const target: api.Opt = @enumFromInt(op.target);
        const list, const unset = switch (target) {
            .done_state => .{ &done, &done_unset },
            .workflow_state => .{ &workflow, &workflow_unset },
            else => {
                try problems.append(a, .{
                    .kind = .unknown_target,
                    .message = "not a setting",
                    .op_index = index,
                });
                continue;
            },
        };
        switch (verb) {
            .add => {
                if (list.* == null) list.* = .empty;
                try list.*.?.append(a, op.str.slice());
            },
            .clear => unset.* = true,
            else => try problems.append(a, .{
                .kind = .unknown_target,
                .message = "settings take ADD or CLEAR",
                .op_index = index,
            }),
        }
    }
    return .{
        .done_states = if (done) |l| .{ .set = l.items } else if (done_unset) .unset else null,
        .workflow_states = if (workflow) |l|
            .{ .set = l.items }
        else if (workflow_unset) .unset else null,
    };
}

pub fn validateSettings(
    a: Allocator,
    ops: []const api.Op,
    problems: *std.ArrayList(rt.ProblemSpec),
) Allocator.Error!void {
    _ = try parseSettingsOps(a, ops, problems);
}

pub fn issuez_settings_write(
    repo: ?*api.Repo,
    ops: ?[*]const api.Op,
    n: usize,
    cancel: ?*api.Cancel,
    err: ?*?*api.Error,
) callconv(.c) Code {
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const a = c.arena();
    var problems: std.ArrayList(rt.ProblemSpec) = .empty;
    const spec = parseSettingsOps(a, if (ops) |p| p[0..n] else &.{}, &problems) catch
        return rt.fail(err, .e_nomem, "out of memory", .{});
    if (problems.items.len > 0) return rt.failWith(
        err,
        .e_invalid_value,
        .{ .problems = problems.items },
        "invalid settings",
        .{},
    );
    settings_mod.write(repo_mod.Backend, a, &c.session.backend, spec) catch |e| switch (e) {
        error.InvalidValue => return rt.failWith(err, .e_invalid_value, .{ .problems = &.{.{
            .kind = .bad_format,
            .message = settings_mod.done_states_rule ++ "; " ++ settings_mod.workflow_states_rule,
        }} }, "a state isn't allowed", .{}),
        else => return c.fail(err, e),
    };
    return .ok;
}

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
    flags: u32,
    cancel: ?*api.Cancel,
    out: ?*?*api.FsckReport,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    if (rt.unknownFlags(api.FsckFlag, flags))
        return rt.fail(err, .e_invalid_argument, "unknown flags", .{});
    const repair = rt.hasFlag(flags, api.FsckFlag.repair);
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const report = Fsck.run(c.arena(), c.engine(), .{ .repair = repair }) catch |e|
        return c.fail(err, e);
    const obj = fsckReportObj(report) catch |e| return rt.failError(err, e, .{});
    o.* = @ptrCast(obj);
    return .ok;
}

fn fsckReportObj(report: Fsck.Report) !*FsckReportObj {
    const arena = try rt.newArena();
    errdefer rt.freeArena(arena);
    const a = arena.allocator();
    var findings: std.ArrayList(api.FsckFinding) = .empty;
    for (report.events) |e| {
        if (e == .ok) continue;
        const Head = struct { api.FsckKind, api.Kind, []const u8 };
        const head: Head = switch (e) {
            .ok => unreachable,
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
            .repaired => |id| .{ .repaired, .issue, id },
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
    const obj = try a.create(FsckReportObj);
    obj.* = .{
        .arena = arena,
        .issues = report.issues,
        .milestones = report.milestones,
        .errors = report.errors(),
        .findings = findings.items,
    };
    return obj;
}

pub fn issuez_fsck_report_issue_count(r: ?*const api.FsckReport) callconv(.c) usize {
    return if (rt.obj(FsckReportObj, r)) |o| o.issues else 0;
}
pub fn issuez_fsck_report_milestone_count(r: ?*const api.FsckReport) callconv(.c) usize {
    return if (rt.obj(FsckReportObj, r)) |o| o.milestones else 0;
}
pub fn issuez_fsck_report_error_count(r: ?*const api.FsckReport) callconv(.c) usize {
    return if (rt.obj(FsckReportObj, r)) |o| o.errors else 0;
}
pub fn issuez_fsck_report_len(r: ?*const api.FsckReport) callconv(.c) usize {
    return if (rt.obj(FsckReportObj, r)) |o| o.findings.len else 0;
}
pub fn issuez_fsck_report_at(
    r: ?*const api.FsckReport,
    i: usize,
) callconv(.c) ?*const api.FsckFinding {
    const o = rt.obj(FsckReportObj, r) orelse return null;
    return if (i < o.findings.len) &o.findings[i] else null;
}
pub fn issuez_fsck_report_free(r: ?*api.FsckReport) callconv(.c) void {
    if (rt.obj(FsckReportObj, r)) |o| rt.freeArena(o.arena);
}

// ─── Remote setup ──────────────────────────────────────────────────────

const remote_mod = issuez.remote;

pub fn issuez_remote_default(
    repo: ?*api.Repo,
    cancel: ?*api.Cancel,
    out: ?*?*api.Matches,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const backend = &c.session.backend;
    const found = remote_mod.default(repo_mod.Backend, c.arena(), backend) catch |e|
        return c.fail(err, e);
    const names: []const []const u8 = switch (found) {
        .none => &.{},
        .one => |r| &.{r},
        .many => |rs| rs,
    };
    const m = read.makeMatches(names) catch |e| return rt.failError(err, e, .{});
    o.* = @ptrCast(m);
    return .ok;
}

pub fn issuez_remote_configure(
    repo: ?*api.Repo,
    remote: Str,
    flags: u32,
    cancel: ?*api.Cancel,
    out: ?*api.RemoteSetup,
    err: ?*?*api.Error,
) callconv(.c) Code {
    if (rt.unknownFlags(api.RemoteFlag, flags))
        return rt.fail(err, .e_invalid_argument, "unknown flags", .{});
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const options: remote_mod.Options = .{
        .fix_unsafe = rt.hasFlag(flags, api.RemoteFlag.fix_unsafe),
    };
    const setup = remote_mod.configure(
        repo_mod.Backend,
        c.arena(),
        &c.session.backend,
        remote.slice(),
        options,
    ) catch |e|
        switch (e) {
            error.NoSuchRemote, error.InvalidRemoteName => return rt.failWith(err, .e_not_found, .{
                .subject = remote.slice(),
            }, "no such remote", .{}),
            else => return c.fail(err, e),
        };
    if (out) |o| o.* = .{
        .configured = setup.configured,
        .removed_unsafe = setup.removed_unsafe,
        .unsafe = setup.unsafe,
    };
    return .ok;
}

// ─── JSON ──────────────────────────────────────────────────────────────

fn jsonBytes(
    issues: []const issuez.engine.Issue,
    full: bool,
    array: bool,
    done_states: []const []const u8,
    scratch: Allocator,
) !*BytesObj {
    var out: std.Io.Writer.Allocating = .init(scratch);
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    if (array) try s.beginArray();
    for (issues) |issue| try issuez.json.issue(&s, scratch, issue, .{
        .full = full,
        .done_states = done_states,
    });
    if (array) try s.endArray();
    return makeBytes(out.written());
}

pub fn issuez_issue_json(
    repo: ?*api.Repo,
    id: Str,
    flags: u32,
    cancel: ?*api.Cancel,
    out: ?*?*api.Bytes,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    if (rt.unknownFlags(api.JsonFlag, flags))
        return rt.fail(err, .e_invalid_argument, "unknown flags", .{});
    const full = rt.hasFlag(flags, api.JsonFlag.full);
    if (!issuez.format.uuid.isCanonical(id.slice()))
        return rt.fail(err, .e_invalid_argument, "not a full issue UUID", .{});
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const a = c.arena();
    const issue = (c.engine().find(a, id.slice()) catch |e| return c.fail(err, e)) orelse
        return rt.failWith(err, .e_not_found, .{ .subject = id.slice() }, "no such issue", .{});
    const done = c.engine().doneStates();
    const b = jsonBytes(&.{issue}, full, false, done, a) catch |e| return rt.failError(err, e, .{});
    o.* = @ptrCast(b);
    return .ok;
}

pub fn issuez_issue_json_many(
    repo: ?*api.Repo,
    ids: ?[*]const Str,
    n: usize,
    flags: u32,
    cancel: ?*api.Cancel,
    out: ?*?*api.Bytes,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    if (rt.unknownFlags(api.JsonFlag, flags))
        return rt.fail(err, .e_invalid_argument, "unknown flags", .{});
    const full = rt.hasFlag(flags, api.JsonFlag.full);
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const a = c.arena();
    var list: std.ArrayList(issuez.engine.Issue) = .empty;
    if (ids == null or n == 0) {
        var skipped: std.ArrayList([]const u8) = .empty;
        const every = read.loadEvery(&c, &skipped) catch |e| return c.fail(err, e);
        for (every) |issue| if (!issue.deleted) {
            list.append(a, issue) catch return rt.fail(err, .e_nomem, "out of memory", .{});
        };
    } else for (ids.?[0..n]) |id| {
        if (!issuez.format.uuid.isCanonical(id.slice()))
            return rt.fail(err, .e_invalid_argument, "not a full issue UUID", .{});
        const issue = c.engine().find(a, id.slice()) catch |e| switch (e) {
            error.OutOfMemory => return rt.fail(err, .e_nomem, "out of memory", .{}),
            else => if (read.isDamaged(e)) continue else return c.fail(err, e),
        };
        if (issue) |x| list.append(a, x) catch return rt.fail(err, .e_nomem, "out of memory", .{});
    }
    const done = c.engine().doneStates();
    const b = jsonBytes(list.items, full, true, done, a) catch |e| return rt.failError(err, e, .{});
    o.* = @ptrCast(b);
    return .ok;
}

// ─── Sync status ───────────────────────────────────────────────────────

pub const SyncStatusObj = struct {
    arena: *std.heap.ArenaAllocator,
    quarantined: []const api.Quarantined,
    pending: []const Str,
};

pub fn issuez_sync_status_take(
    repo: ?*api.Repo,
    remote: Str,
    cancel: ?*api.Cancel,
    out: ?*?*api.SyncStatus,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const st = repo_mod.Sync.init(&c.session.backend).status(c.arena(), remote.slice()) catch |e|
        return c.fail(err, e);
    const obj = syncStatusObj(st) catch |e| return rt.failError(err, e, .{});
    o.* = @ptrCast(obj);
    return .ok;
}

fn syncStatusObj(st: issuez.sync.Status) !*SyncStatusObj {
    const arena = try rt.newArena();
    errdefer rt.freeArena(arena);
    const a = arena.allocator();
    const q = try a.alloc(api.Quarantined, st.quarantined.len);
    for (st.quarantined, q) |x, *y| y.* = .{
        .kind = @intFromEnum(@as(api.Kind, if (x.namespace == .milestones) .milestone else .issue)),
        .id = try rt.dupeZ(a, x.id),
        .title = try rt.dupeZ(a, x.title),
        .remote_tip = rt.oidOf(x.remote_tip),
        .reason = @intFromEnum(@as(api.QuarantineReason, if (x.reason) |r| switch (r) {
            .unrelated_history => .unrelated_history,
            .rewound => .rewound,
            .invalid_issue => .invalid_issue,
        } else .unknown)),
        .kept_local = x.kept_local,
    };
    const p = try a.alloc(Str, st.pending.len);
    for (st.pending, p) |x, *y| y.* = try rt.dupeZ(a, x.id());
    const obj = try a.create(SyncStatusObj);
    obj.* = .{ .arena = arena, .quarantined = q, .pending = p };
    return obj;
}

pub fn issuez_sync_status_quarantined_count(s: ?*const api.SyncStatus) callconv(.c) usize {
    return if (rt.obj(SyncStatusObj, s)) |o| o.quarantined.len else 0;
}
pub fn issuez_sync_status_quarantined_at(
    s: ?*const api.SyncStatus,
    i: usize,
) callconv(.c) ?*const api.Quarantined {
    const o = rt.obj(SyncStatusObj, s) orelse return null;
    return if (i < o.quarantined.len) &o.quarantined[i] else null;
}
pub fn issuez_sync_status_pending_count(s: ?*const api.SyncStatus) callconv(.c) usize {
    return if (rt.obj(SyncStatusObj, s)) |o| o.pending.len else 0;
}
pub fn issuez_sync_status_pending_at(s: ?*const api.SyncStatus, i: usize) callconv(.c) Str {
    const o = rt.obj(SyncStatusObj, s) orelse return .{};
    return if (i < o.pending.len) o.pending[i] else .{};
}
pub fn issuez_sync_status_free(s: ?*api.SyncStatus) callconv(.c) void {
    if (rt.obj(SyncStatusObj, s)) |o| rt.freeArena(o.arena);
}

// ─── Search ────────────────────────────────────────────────────────────

pub const SearchHitsObj = struct {
    arena: *std.heap.ArenaAllocator,
    hits: []const api.SearchHit,
};

pub fn issuez_search(
    repo: ?*api.Repo,
    needle: Str,
    flags: u32,
    cancel: ?*api.Cancel,
    out: ?*?*api.SearchHits,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    if (rt.unknownFlags(api.SearchFlag, flags))
        return rt.fail(err, .e_invalid_argument, "unknown flags", .{});
    const ignore_case = rt.hasFlag(flags, api.SearchFlag.ignore_case);
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const a = c.arena();
    var skipped: std.ArrayList([]const u8) = .empty;
    const issues = read.loadEvery(&c, &skipped) catch |e| return c.fail(err, e);
    const arena = rt.newArena() catch return rt.fail(err, .e_nomem, "out of memory", .{});
    const hits = searchHits(a, arena.allocator(), issues, needle.slice(), ignore_case) catch {
        rt.freeArena(arena);
        return rt.fail(err, .e_nomem, "out of memory", .{});
    };
    const obj = arena.allocator().create(SearchHitsObj) catch {
        rt.freeArena(arena);
        return rt.fail(err, .e_nomem, "out of memory", .{});
    };
    obj.* = .{ .arena = arena, .hits = hits };
    o.* = @ptrCast(obj);
    return .ok;
}

fn searchHits(
    scratch: Allocator,
    a: Allocator,
    issues: []const issuez.engine.Issue,
    needle: []const u8,
    ignore_case: bool,
) ![]const api.SearchHit {
    var out: std.ArrayList(api.SearchHit) = .empty;
    for (issues) |issue| {
        if (issue.deleted) continue;
        const options: issuez.query.SearchOptions = .{ .ignore_case = ignore_case };
        const lines = try issuez.query.searchLines(scratch, issue, needle, options);
        if (lines.len == 0) continue;
        const id = try rt.dupeZ(a, issue.id);
        for (lines) |l| try out.append(a, .{ .issue_id = id, .line = try rt.dupeZ(a, l) });
    }
    return out.items;
}

pub fn issuez_search_hits_len(h: ?*const api.SearchHits) callconv(.c) usize {
    return if (rt.obj(SearchHitsObj, h)) |o| o.hits.len else 0;
}
pub fn issuez_search_hits_at(
    h: ?*const api.SearchHits,
    i: usize,
) callconv(.c) ?*const api.SearchHit {
    const o = rt.obj(SearchHitsObj, h) orelse return null;
    return if (i < o.hits.len) &o.hits[i] else null;
}
pub fn issuez_search_hits_free(h: ?*api.SearchHits) callconv(.c) void {
    if (rt.obj(SearchHitsObj, h)) |o| rt.freeArena(o.arena);
}

// ─── Dropping everything ───────────────────────────────────────────────

pub fn issuez_repo_drop_all(
    repo: ?*api.Repo,
    cancel: ?*api.Cancel,
    dropped: ?*usize,
    err: ?*?*api.Error,
) callconv(.c) Code {
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const n = c.engine().dropAll(c.arena()) catch |e| switch (e) {
        error.RefConflict => return rt.fail(
            err,
            .e_contended,
            "a ref changed while they were dropped",
            .{},
        ),
        else => return c.fail(err, e),
    };
    if (dropped) |d| d.* = n;
    return .ok;
}

pub fn issuez_repo_adopt_refs(
    repo: ?*api.Repo,
    from: ?*api.Repo,
    cancel: ?*api.Cancel,
    adopted: ?*usize,
    err: ?*?*api.Error,
) callconv(.c) Code {
    if (from == null or from == repo)
        return rt.fail(err, .e_invalid_argument, "from is NULL or repo itself", .{});
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    var other = Call.begin(from, cancel) catch |e| return rt.failError(err, e, .{});
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
    if (adopted) |d| d.* = n;
    return .ok;
}

// ─── Push check ────────────────────────────────────────────────────────

const PushCheck = issuez.PushCheck(repo_mod.Backend);
const check_mod = issuez.push_check;

/// A verdict with its timeline entries, behind the public part.
pub const VerdictObj = extern struct {
    public: api.PushVerdict,
    entries: ?[*]const read.EntryObj,
    attachments: ?[*]const api.Attachment,
};

pub const PushVerdictsObj = struct {
    arena: *std.heap.ArenaAllocator,
    items: []const VerdictObj,
};

pub const PushOps = struct {
    policy: check_mod.Policy,
    /// The quarantine, as git's environment.
    vars: []const [2][]const u8,
};

/// The push check options; problems with them go to `problems`.
pub fn parsePushOps(
    a: Allocator,
    ops: []const api.Op,
    problems: *std.ArrayList(rt.ProblemSpec),
) Allocator.Error!PushOps {
    var policy: check_mod.Policy = .{};
    var emails: std.ArrayList([]const u8) = .empty;
    var ids: std.ArrayList([]const u8) = .empty;
    var vars: std.ArrayList([2][]const u8) = .empty;
    for (ops, 0..) |op, i| {
        const bad: ?[]const u8 = if (rt.hasReserved(op))
            "reserved fields must be zero"
        else switch (@as(api.Opt, @enumFromInt(op.target))) {
            .pusher => blk: {
                if (op.person.email.len == 0) break :blk "the pusher needs an email";
                try emails.append(a, op.person.email.slice());
                if (op.person.user_id.len > 0) {
                    const user_id = op.person.user_id.slice();
                    if (!uuid_fmt.isCanonical(user_id)) break :blk "user_id isn't a UUID";
                    try ids.append(a, op.person.user_id.slice());
                }
                break :blk null;
            },
            .pusher_email => blk: {
                if (op.str.len == 0) break :blk "empty email";
                try emails.append(a, op.str.slice());
                break :blk null;
            },
            .pusher_user_id => blk: {
                if (!uuid_fmt.isCanonical(op.str.slice())) break :blk "not a UUID";
                try ids.append(a, op.str.slice());
                break :blk null;
            },
            .author_policy => switch (@as(
                api.AuthorPolicy,
                @enumFromInt(std.math.cast(u32, op.num) orelse 0),
            )) {
                .any => blk: {
                    policy.author_policy = .any;
                    break :blk null;
                },
                .warn => blk: {
                    policy.author_policy = .warn;
                    break :blk null;
                },
                .enforce => blk: {
                    policy.author_policy = .enforce;
                    break :blk null;
                },
                else => "not an issuez_author_policy",
            },
            .allow_numbers => blk: {
                policy.allow_numbers = op.num != 0;
                break :blk null;
            },
            .allow_purge => blk: {
                policy.allow_purge = op.num != 0;
                break :blk null;
            },
            .object_dir, .alternate_object_dirs => |t| blk: {
                const name = if (t == .object_dir)
                    "GIT_OBJECT_DIRECTORY"
                else
                    "GIT_ALTERNATE_OBJECT_DIRECTORIES";
                try vars.append(a, .{ name, op.str.slice() });
                break :blk null;
            },
            else => "not a push check option",
        };
        if (bad) |msg| try problems.append(a, .{
            .kind = .unknown_target,
            .message = msg,
            .op_index = @intCast(i),
        });
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
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    o.* = null;
    if (updates == null and n_updates > 0)
        return rt.fail(err, .e_invalid_argument, "updates is NULL", .{});
    var scratch: std.heap.ArenaAllocator = .init(rt.gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var problems: std.ArrayList(rt.ProblemSpec) = .empty;
    const parsed = parsePushOps(sa, if (opts) |p| p[0..n_opts] else &.{}, &problems) catch
        return rt.fail(err, .e_nomem, "out of memory", .{});
    const policy = parsed.policy;
    const vars = parsed.vars;
    if (problems.items.len > 0) return rt.failWith(
        err,
        .e_invalid_value,
        .{ .problems = problems.items },
        "invalid options",
        .{},
    );
    const list = sa.alloc(check_mod.Update, n_updates) catch
        return rt.fail(err, .e_nomem, "out of memory", .{});
    for (if (updates) |u| u[0..n_updates] else &.{}, list) |u, *x| {
        if (u.ref.len == 0) return rt.fail(
            err,
            .e_invalid_argument,
            "an update without a ref",
            .{},
        );
        if (rt.hasReserved(u))
            return rt.fail(err, .e_invalid_argument, "reserved fields must be zero", .{});
        const old: ?Oid = if (u.old_oid.len == 0) null else rt.oidFrom(u.old_oid) orelse
            return rt.fail(err, .e_invalid_argument, "old_oid is not a full object ID", .{});
        const new: ?Oid = if (u.new_oid.len == 0) null else rt.oidFrom(u.new_oid) orelse
            return rt.fail(err, .e_invalid_argument, "new_oid is not a full object ID", .{});
        if (old == null and new == null)
            return rt.fail(err, .e_invalid_argument, "an update without old or new", .{});
        x.* = .{ .ref = u.ref.slice(), .old = old, .new = new };
    }

    var c = (if (vars.len > 0)
        Call.beginPrivate(repo, cancel, vars)
    else
        Call.begin(repo, cancel)) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const verdicts = PushCheck.fromRepo(c.engine()).check(c.arena(), list, policy) catch |e|
        return c.fail(err, e);
    const r = makeVerdicts(verdicts, read.Context.of(c.repo)) catch |e|
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

fn makeVerdicts(verdicts: []const check_mod.Verdict, ctx: read.Context) !*PushVerdictsObj {
    const arena = try rt.newArena();
    errdefer rt.freeArena(arena);
    const a = arena.allocator();
    const items = try a.alloc(VerdictObj, verdicts.len);
    for (verdicts, items) |v, *x| {
        var specs: std.ArrayList(rt.ProblemSpec) = .empty;
        for (v.problems) |p| try specs.append(a, try verdictProblem(a, p));
        var entries: std.ArrayList(read.EntryObj) = .empty;
        var added: std.ArrayList(api.Attachment) = .empty;
        var issue_author: ?*const api.Person = null;
        if (v.issue) |issue| if (v.kind == .issue) {
            const built = try read.build(a, issue, ctx);
            const isNew = struct {
                fn f(commits: anytype, oid: api.Oid) bool {
                    for (commits) |nc| if (rt.issuez_oid_eq(&rt.oidOf(nc.oid), &oid)) return true;
                    return false;
                }
            }.f;
            for (built.timeline) |e| if (isNew(v.new_commits, e.public.commit)) {
                try entries.append(a, e);
            };
            for (built.attachments) |att| if (isNew(v.new_commits, att.added_in)) {
                try added.append(a, att);
            };
            const author = try a.create(api.Person);
            author.* = built.author;
            issue_author = author;
        };
        x.* = .{
            .public = .{
                .ref = try rt.dupeZ(a, v.update.ref),
                .kind = @intFromEnum(verdictKind(v.kind)),
                .id = try rt.dupeZ(a, v.id),
                .action = @intFromEnum(switch (v.action) {
                    .ignored => api.PushAction.ignored,
                    .create => .create,
                    .fast_forward => .fast_forward,
                    .rewrite => .rewrite,
                    .delete => .delete,
                }),
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
    const r = try a.create(PushVerdictsObj);
    r.* = .{ .arena = arena, .items = items };
    return r;
}

pub fn issuez_push_verdicts_len(v: ?*const api.PushVerdicts) callconv(.c) usize {
    const o = rt.obj(PushVerdictsObj, v) orelse return 0;
    return o.items.len;
}
pub fn issuez_push_verdicts_at(
    v: ?*const api.PushVerdicts,
    i: usize,
) callconv(.c) ?*const api.PushVerdict {
    const o = rt.obj(PushVerdictsObj, v) orelse return null;
    return if (i < o.items.len) &o.items[i].public else null;
}
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
pub fn issuez_push_verdicts_free(v: ?*api.PushVerdicts) callconv(.c) void {
    const o = rt.obj(PushVerdictsObj, v) orelse return;
    rt.freeArena(o.arena);
}

pub fn issuez_repo_commit_import(
    staging: ?*api.Repo,
    cancel: ?*api.Cancel,
    adopted: ?*usize,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const r = rt.obj(repo_mod.RepoObj, staging) orelse
        return rt.fail(err, .e_invalid_argument, "staging is NULL", .{});
    const state = r.import_state orelse
        return rt.fail(err, .e_invalid_argument, "not a staging repo", .{});
    if (state.committed) return rt.fail(err, .e_invalid_argument, "import already committed", .{});
    const code = issuez_repo_adopt_refs(@ptrCast(r.import_target.?), staging, cancel, adopted, err);
    if (code == .ok) state.committed = true;
    return code;
}

//! `issuez_store`: the live view of a repository's issues for a front end
//! on the C API. A refresh reads the refs, and loads only the issues whose
//! tip moved; the issue handles of the others are kept.

const std = @import("std");
const api = @import("api.zig");
const rt = @import("rt.zig");
const repo_mod = @import("repo.zig");
const read = @import("read.zig");
const issuez = @import("issuez");
const Code = api.Code;
const Str = api.Str;
const Call = repo_mod.Call;
const RepoObj = repo_mod.RepoObj;
const changes = issuez.changes;

pub const StoreObj = struct {
    repo: *RepoObj,
    generation: u32 = 0,
    refs: changes.RefState = .{},
    /// By UUID; each issue owns its handle (`read.ownedIssue`).
    issues: std.StringArrayHashMapUnmanaged(*read.IssueObj) = .empty,
    /// What the last refresh found changed, owned by `changed_arena`.
    changed: []const Str = &.{},
    changed_arena: std.heap.ArenaAllocator,
};

pub fn issuez_store_new(
    repo: ?*api.Repo,
    out: ?*?*api.Store,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    const r = rt.obj(
        RepoObj,
        repo,
    ) orelse return rt.fail(err, .e_invalid_argument, "repo is NULL", .{});
    const s = rt.gpa.create(StoreObj) catch return rt.fail(err, .e_nomem, "out of memory", .{});
    s.* = .{ .repo = r, .changed_arena = .init(rt.gpa) };
    r.retain();
    o.* = @ptrCast(s);
    return .ok;
}

pub fn issuez_store_free(store: ?*api.Store) callconv(.c) void {
    const s = rt.obj(StoreObj, store) orelse return;
    for (s.issues.values()) |i| read.issuez_issue_free(@ptrCast(i));
    s.issues.deinit(rt.gpa);
    s.refs.deinit(rt.gpa);
    s.changed_arena.deinit();
    const r = s.repo;
    rt.gpa.destroy(s);
    r.release();
}

pub fn issuez_store_refresh(
    store: ?*api.Store,
    cancel: ?*api.Cancel,
    changed: ?*bool,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const s = rt.obj(
        StoreObj,
        store,
    ) orelse return rt.fail(err, .e_invalid_argument, "store is NULL", .{});
    var c = Call.begin(@ptrCast(s.repo), cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const moved = refresh(&c, s) catch |e| return c.fail(err, e);
    if (changed) |p| p.* = moved;
    return .ok;
}

fn refresh(c: *Call, s: *StoreObj) !bool {
    const a = c.arena();
    const now = try changes.RefState.read(repo_mod.Backend, a, &c.session.backend);
    const d = try changes.diff(a, s.refs, now);
    if (s.generation > 0 and d.isEmpty()) return false;

    const ctx: read.Context = .of(c.repo);
    var next: std.StringArrayHashMapUnmanaged(*read.IssueObj) = .empty;
    errdefer next.deinit(rt.gpa);
    var fresh: std.ArrayList(*read.IssueObj) = .empty;
    errdefer for (fresh.items) |i| read.issuez_issue_free(@ptrCast(i));
    for (try c.engine().refs(a)) |ref| {
        const id = ref.id();
        if (s.issues.get(id)) |old| {
            if (rt.issuez_oid_eq(&old.tip, &rt.oidOf(ref.tip))) {
                try next.put(rt.gpa, old.id.slice(), old);
                continue;
            }
        }
        const issue = c.engine().load(a, ref) catch |e| {
            if (read.isDamaged(e)) continue;
            return e;
        };
        const obj = try read.ownedIssue(issue, ctx);
        try fresh.append(a, obj);
        try next.put(rt.gpa, obj.id.slice(), obj);
    }
    const refs = try now.clone(rt.gpa);
    // The diff's IDs may point into the old ref state: copy them first.
    _ = s.changed_arena.reset(.retain_capacity);
    const ca = s.changed_arena.allocator();
    s.changed = &.{};
    if (ca.alloc(Str, d.issues.len)) |ids| {
        for (d.issues, ids) |id, *o| o.* = rt.dupeZ(ca, id) catch .{};
        s.changed = ids;
    } else |_| {}
    // Nothing fails from here on.
    for (s.issues.values()) |old| {
        const kept = next.get(old.id.slice());
        if (kept == null or kept.? != old) read.issuez_issue_free(@ptrCast(old));
    }
    s.issues.deinit(rt.gpa);
    s.issues = next;
    s.refs.deinit(rt.gpa);
    s.refs = refs;
    s.generation +%= 1;
    return true;
}

pub fn issuez_store_generation(store: ?*const api.Store) callconv(.c) u32 {
    return if (rt.obj(StoreObj, store)) |s| s.generation else 0;
}

pub fn issuez_store_issue_count(store: ?*const api.Store) callconv(.c) usize {
    return if (rt.obj(StoreObj, store)) |s| s.issues.count() else 0;
}

pub fn issuez_store_issue_at(store: ?*const api.Store, i: usize) callconv(.c) ?*const api.Issue {
    const s = rt.obj(StoreObj, store) orelse return null;
    return if (i < s.issues.count()) @ptrCast(s.issues.values()[i]) else null;
}

pub fn issuez_store_find(store: ?*const api.Store, id: Str) callconv(.c) ?*const api.Issue {
    const s = rt.obj(StoreObj, store) orelse return null;
    return if (s.issues.get(id.slice())) |i| @ptrCast(i) else null;
}

pub fn issuez_store_changed_count(store: ?*const api.Store) callconv(.c) usize {
    return if (rt.obj(StoreObj, store)) |s| s.changed.len else 0;
}

pub fn issuez_store_changed_at(store: ?*const api.Store, i: usize) callconv(.c) Str {
    const s = rt.obj(StoreObj, store) orelse return .{};
    return if (i < s.changed.len) s.changed[i] else .{};
}

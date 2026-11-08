//! Live updates: `issuez_watch` over the TUI's `RepoWatcher`.

const std = @import("std");
const api = @import("api.zig");
const rt = @import("rt.zig");
const repo_mod = @import("repo.zig");
const capi_options = @import("capi_options");
const Code = api.Code;
const RepoObj = repo_mod.RepoObj;

const RepoWatcher = if (capi_options.watch) @import("RepoWatcher") else void;

pub const WatchObj = struct {
    watcher: RepoWatcher,
    repo: *RepoObj,
    cb: *const fn (userdata: ?*anyopaque, changes: u32) callconv(.c) void,
    userdata: ?*anyopaque,

    fn changed(context: *anyopaque, change: RepoWatcher.Change) void {
        const o: *WatchObj = @ptrCast(@alignCast(context));
        var bits: u32 = 0;
        if (change.refs) bits |= @intFromEnum(api.WatchChange.refs);
        if (change.config) bits |= @intFromEnum(api.WatchChange.config);
        o.cb(o.userdata, bits);
    }
};

pub fn issuez_watch_start(
    repo: ?*api.Repo,
    cb: api.WatchFn,
    userdata: ?*anyopaque,
    out: ?*?*api.Watch,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.fail(err, .e_invalid_argument, "out is NULL", .{});
    const callback = cb orelse return rt.fail(err, .e_invalid_argument, "cb is NULL", .{});
    const r = rt.obj(
        RepoObj,
        repo,
    ) orelse return rt.fail(err, .e_invalid_argument, "repo is NULL", .{});
    if (!capi_options.watch) return rt.fail(err, .e_unsupported, "built without watching", .{});
    const dir = r.git_dir.slice();
    if (!std.fs.path.isAbsolute(dir))
        return rt.fail(err, .e_unsupported, "the git dir isn't an absolute path", .{});
    const w = rt.gpa.create(WatchObj) catch return rt.fail(err, .e_nomem, "out of memory", .{});
    w.* = .{ .watcher = undefined, .repo = r, .cb = callback, .userdata = userdata };
    w.watcher.init(
        rt.io(),
        rt.gpa,
        dir,
        .{ .context = w, .changed = WatchObj.changed },
        .{},
    ) catch |e| {
        rt.gpa.destroy(w);
        return rt.fail(err, .e_internal, "can't watch the repository: {t}", .{e});
    };
    r.retain();
    o.* = @ptrCast(w);
    return .ok;
}

pub fn issuez_watch_stop(w: ?*api.Watch) callconv(.c) void {
    const o = rt.obj(WatchObj, w) orelse return;
    if (capi_options.watch) o.watcher.deinit();
    const r = o.repo;
    rt.gpa.destroy(o);
    r.release();
}

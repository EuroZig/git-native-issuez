//! Repositories, git, and the leak check for the C API tests
//! (docs/test-plan.md §2.3).

const std = @import("std");
const testing = std.testing;
pub const c = @import("c");

pub const Allocator = std.mem.Allocator;

extern fn issuez__debug_live_allocations() i64;

/// Live allocations in the library: the same before a test and after it
/// freed what it got.
pub fn live() i64 {
    return issuez__debug_live_allocations();
}

/// `defer leaks.check()` after `const leaks = Leaks.start();`.
pub const Leaks = struct {
    before: i64,

    pub fn start() Leaks {
        ensureInit();
        return .{ .before = live() };
    }

    pub fn check(l: Leaks) void {
        const now = live();
        if (now != l.before) std.debug.panic(
            "the library leaked {d} allocation(s)",
            .{now - l.before},
        );
    }
};

var initialized: std.atomic.Value(bool) = .init(false);

pub fn ensureInit() void {
    if (initialized.swap(true, .acq_rel)) return;
    if (c.issuez_init(c.ISSUEZ_ABI_VERSION, null) != c.ISSUEZ_OK) @panic("issuez_init failed");
}

pub fn str(s: []const u8) c.issuez_str {
    return .{ .ptr = s.ptr, .len = s.len };
}

pub fn slice(s: c.issuez_str) []const u8 {
    const p = s.ptr orelse return "";
    return p[0..s.len];
}

/// Identity and config isolated from the user's.
pub const env_vars = [_][2][]const u8{
    .{ "GIT_CONFIG_NOSYSTEM", "1" },
    .{ "GIT_CONFIG_GLOBAL", "/dev/null" },
    .{ "GIT_AUTHOR_NAME", "Tester" },
    .{ "GIT_AUTHOR_EMAIL", "tester@example.invalid" },
    .{ "GIT_COMMITTER_NAME", "Tester" },
    .{ "GIT_COMMITTER_EMAIL", "tester@example.invalid" },
};

pub fn envOps(out: []c.issuez_op) []c.issuez_op {
    for (env_vars, 0..) |kv, i| {
        out[i] = std.mem.zeroes(c.issuez_op);
        out[i].verb = c.ISSUEZ_OP_SET;
        out[i].target = c.ISSUEZ_OPT_ENV;
        out[i].name = str(kv[0]);
        out[i].str = str(kv[1]);
    }
    return out[0..env_vars.len];
}

/// Runs git in `dir`, failing the test with git's stderr.
pub fn runGit(arena: Allocator, dir: []const u8, args: []const []const u8) ![]const u8 {
    var env = try testing.environ.createMap(arena);
    for (env_vars) |kv| try env.put(kv[0], kv[1]);
    const argv = try std.mem.concat(arena, []const u8, &.{ &.{"git"}, args });
    const r = try std.process.run(arena, testing.io, .{
        .argv = argv,
        .cwd = .{ .path = dir },
        .environ_map = &env,
    });
    switch (r.term) {
        .exited => |code| if (code == 0) return std.mem.trimEnd(u8, r.stdout, "\n"),
        else => {},
    }
    std.debug.print("git {s} failed: {s}\n", .{ try std.mem.join(arena, " ", args), r.stderr });
    return error.GitFailed;
}

pub const Options = struct {
    bare: bool = false,
    init_flags: []const []const u8 = &.{},
    /// More open options, after the environment's.
    ops: []const c.issuez_op = &.{},
};

/// A new repository in a temp dir, opened.
pub const Repo = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    /// Absolute.
    root: []const u8,
    /// The repository: the work tree, or the bare repo.
    path: []const u8,
    handle: *c.issuez_repo,

    pub fn init(r: *Repo, options: Options) !void {
        r.arena_state = .init(testing.allocator);
        errdefer r.arena_state.deinit();
        const a = r.arena_state.allocator();
        r.tmp = testing.tmpDir(.{});
        errdefer r.tmp.cleanup();
        r.root = try r.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        r.path = try std.fs.path.join(a, &.{ r.root, if (options.bare) "repo.git" else "repo" });
        const flags = try std.mem.concat(a, []const u8, &.{
            &.{ "init", "-q" },
            if (options.bare) &.{"--bare"} else &.{},
            options.init_flags,
            &.{r.path},
        });
        _ = try runGit(a, r.root, flags);
        r.handle = try r.open(options.ops);
    }

    /// Another handle on the same repository.
    pub fn open(r: *Repo, extra: []const c.issuez_op) !*c.issuez_repo {
        ensureInit();
        const a = r.arena_state.allocator();
        var env: [env_vars.len]c.issuez_op = undefined;
        const ops = try std.mem.concat(a, c.issuez_op, &.{ envOps(&env), extra });
        var out: ?*c.issuez_repo = null;
        var err: ?*c.issuez_error = null;
        const rc = c.issuez_repo_open(str(r.path), ops.ptr, ops.len, &out, &err);
        if (rc != c.ISSUEZ_OK) {
            std.debug.print("open: {s}\n", .{slice(c.issuez_error_message(err))});
            c.issuez_error_free(err);
            return error.OpenFailed;
        }
        return out.?;
    }

    pub fn deinit(r: *Repo) void {
        c.issuez_repo_close(r.handle);
        r.tmp.cleanup();
        r.arena_state.deinit();
    }

    pub fn arena(r: *Repo) Allocator {
        return r.arena_state.allocator();
    }

    pub fn git(r: *Repo, args: []const []const u8) ![]const u8 {
        return runGit(r.arena(), r.path, args);
    }
};

pub const ada: c.issuez_actor = .{
    .name = .{ .ptr = "Ada", .len = 3 },
    .email = .{ .ptr = "ada@example.invalid", .len = 19 },
    .user_id = .{},
    .at = null,
    .reserved = .{ 0, 0, 0, 0 },
};

pub const Created = struct {
    /// NUL-terminated UUID.
    id: [37]u8,
    tip: c.issuez_oid,

    pub fn idStr(x: *const Created) c.issuez_str {
        return .{ .ptr = &x.id, .len = 36 };
    }

    pub fn idSlice(x: *const Created) []const u8 {
        return x.id[0..36];
    }
};

/// Creates an issue with `ops` (a title at least), as Ada.
pub fn create(repo: *c.issuez_repo, ops: []const c.issuez_op) !Created {
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    const rc = c.issuez_issue_create(repo, ops.ptr, ops.len, &ada, null, &w, &err);
    if (rc != c.ISSUEZ_OK) {
        std.debug.print("create: {s}\n", .{slice(c.issuez_error_message(err))});
        c.issuez_error_free(err);
        return error.CreateFailed;
    }
    defer c.issuez_write_free(w);
    var out: Created = .{ .id = @splat(0), .tip = c.issuez_write_new_tip(w) };
    @memcpy(out.id[0..36], slice(c.issuez_write_id(w)));
    return out;
}

pub fn titled(repo: *c.issuez_repo, title: []const u8) !Created {
    return create(repo, &.{c.issuez_set_title(str(title))});
}

/// Applies `ops` to an issue as Ada; returns the new tip.
pub fn update(repo: *c.issuez_repo, id: c.issuez_str, ops: []const c.issuez_op) !c.issuez_oid {
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    const rc = c.issuez_issue_update(repo, id, ops.ptr, ops.len, &ada, null, &w, &err);
    if (rc != c.ISSUEZ_OK) {
        std.debug.print("update: {s}\n", .{slice(c.issuez_error_message(err))});
        c.issuez_error_free(err);
        return error.UpdateFailed;
    }
    defer c.issuez_write_free(w);
    return c.issuez_write_new_tip(w);
}

/// issuez_issue_update over a slice of ops.
pub fn updateRc(
    repo: ?*c.issuez_repo,
    id: c.issuez_str,
    ops: []const c.issuez_op,
    actor: ?*const c.issuez_actor,
    cancel: ?*c.issuez_cancel,
    out: ?*?*c.issuez_write,
    err: ?*?*c.issuez_error,
) c.issuez_code {
    return c.issuez_issue_update(repo, id, ops.ptr, ops.len, actor, cancel, out, err);
}

/// An executable script in `dir`; returns its path.
pub fn script(arena: Allocator, dir: []const u8, name: []const u8, body: []const u8) ![]const u8 {
    const path = try std.fs.path.join(arena, &.{ dir, name });
    const d = try std.Io.Dir.cwd().openDir(testing.io, dir, .{});
    defer d.close(testing.io);
    try d.writeFile(testing.io, .{
        .sub_path = name,
        .data = body,
        .flags = .{ .permissions = .executable_file },
    });
    return path;
}

/// A git that hangs on `fetch` and is git otherwise.
pub fn slowGit(arena: Allocator, dir: []const u8) ![]const u8 {
    return script(arena, dir, "slow-git",
        \\#!/bin/sh
        \\for a; do [ "$a" = fetch ] && exec sleep 30; done
        \\exec git "$@"
        \\
    );
}

pub fn opStr(target: c_uint, verb: c_uint, s: []const u8) c.issuez_op {
    var o = std.mem.zeroes(c.issuez_op);
    o.verb = verb;
    o.target = target;
    o.str = str(s);
    return o;
}

pub fn opNum(target: c_uint, n: i64) c.issuez_op {
    var o = std.mem.zeroes(c.issuez_op);
    o.verb = c.ISSUEZ_OP_SET;
    o.target = target;
    o.num = n;
    return o;
}

/// Tries to open `path` with `ops` (after the environment's); the code,
/// and the handle when it opened.
pub fn tryOpen(
    path: []const u8,
    ops: []const c.issuez_op,
    err: ?*?*c.issuez_error,
) struct { c.issuez_code, ?*c.issuez_repo } {
    ensureInit();
    var all: [64]c.issuez_op = undefined;
    var env: [env_vars.len]c.issuez_op = undefined;
    const e = envOps(&env);
    @memcpy(all[0..e.len], e);
    @memcpy(all[e.len..][0..ops.len], ops);
    var out: ?*c.issuez_repo = null;
    const rc = c.issuez_repo_open(str(path), &all, e.len + ops.len, &out, err);
    return .{ rc, out };
}

/// A milestone named `name`, as Ada.
pub fn milestone(repo: *c.issuez_repo, name: []const u8) !Created {
    const ops = [_]c.issuez_op{c.issuez_set_name(str(name))};
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    if (c.issuez_milestone_create(repo, &ops, 1, &ada, null, &w, &err) != c.ISSUEZ_OK) {
        std.debug.print("milestone: {s}\n", .{slice(c.issuez_error_message(err))});
        c.issuez_error_free(err);
        return error.CreateFailed;
    }
    defer c.issuez_write_free(w);
    var out: Created = .{ .id = @splat(0), .tip = c.issuez_write_new_tip(w) };
    @memcpy(out.id[0..36], slice(c.issuez_write_id(w)));
    return out;
}

/// The matches of `input`, owned by the caller (testing.allocator).
pub fn resolve(repo: *c.issuez_repo, kind: c.issuez_kind, input: []const u8) ![]const []const u8 {
    var m: ?*c.issuez_matches = null;
    var err: ?*c.issuez_error = null;
    if (c.issuez_resolve(repo, kind, str(input), null, &m, &err) != c.ISSUEZ_OK) {
        c.issuez_error_free(err);
        return error.ResolveFailed;
    }
    defer c.issuez_matches_free(m);
    const out = try testing.allocator.alloc([]const u8, c.issuez_matches_len(m));
    for (out, 0..) |*o, i| o.* = try testing.allocator.dupe(u8, slice(c.issuez_matches_at(m, i)));
    return out;
}

pub fn freeAll(list: []const []const u8) void {
    for (list) |x| testing.allocator.free(x);
    testing.allocator.free(list);
}

pub const Wrote = struct { tip: c.issuez_oid, commit: c.issuez_oid };

/// Checks a write call's result and frees its receipt.
pub fn wrote(
    rc: c.issuez_code,
    w: ?*c.issuez_write,
    err: ?*c.issuez_error,
    what: []const u8,
) !Wrote {
    if (rc != c.ISSUEZ_OK) {
        std.debug.print("{s}: {s}\n", .{ what, slice(c.issuez_error_message(err)) });
        c.issuez_error_free(err);
        return error.WriteFailed;
    }
    defer c.issuez_write_free(w);
    return .{ .tip = c.issuez_write_new_tip(w), .commit = c.issuez_write_commit(w) };
}

/// A comment as Ada; its ID is the commit.
pub fn comment(repo: *c.issuez_repo, id: c.issuez_str, text: []const u8) !Wrote {
    const ops = [_]c.issuez_op{c.issuez_set_comment(str(text))};
    var w: ?*c.issuez_write = null;
    var err: ?*c.issuez_error = null;
    return wrote(c.issuez_issue_update(repo, id, &ops, 1, &ada, null, &w, &err), w, err, "comment");
}

pub fn load(repo: *c.issuez_repo, id: c.issuez_str) !*c.issuez_issue {
    var issue: ?*c.issuez_issue = null;
    var err: ?*c.issuez_error = null;
    if (c.issuez_issue_load(repo, id, null, &issue, &err) != c.ISSUEZ_OK) {
        std.debug.print("load: {s}\n", .{slice(c.issuez_error_message(err))});
        c.issuez_error_free(err);
        return error.LoadFailed;
    }
    return issue.?;
}

/// A commit on an issue written with git, as another tool would.
pub fn foreignCommit(r: *Repo, id: []const u8, message: []const u8) !void {
    const ref = try std.fmt.allocPrint(r.arena(), "refs/issues/{s}", .{id});
    const tree = try r.git(&.{ "hash-object", "-t", "tree", "-w", "/dev/null" });
    const tip = try r.git(&.{ "commit-tree", tree, "-p", ref, "-m", message });
    _ = try r.git(&.{ "update-ref", ref, tip });
}

pub fn oidHex(o: c.issuez_oid) [65]u8 {
    var buf: [65]u8 = undefined;
    _ = c.issuez_oid_hex(&o, &buf);
    return buf;
}

/// A bare hub next to `r`, and `r`'s origin pointing at it.
pub fn hub(r: *Repo, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(r.arena(), &.{ r.root, name });
    _ = try runGit(r.arena(), r.root, &.{ "init", "-q", "--bare", path });
    _ = try r.git(&.{ "remote", "add", "origin", path });
    return path;
}

/// Another repository in `r`'s temp dir with origin `hub_path`, opened.
pub fn second(r: *Repo, name: []const u8, hub_path: []const u8) !*c.issuez_repo {
    const path = try std.fs.path.join(r.arena(), &.{ r.root, name });
    _ = try runGit(r.arena(), r.root, &.{ "init", "-q", path });
    _ = try runGit(r.arena(), path, &.{ "remote", "add", "origin", hub_path });
    const res = tryOpen(path, &.{}, null);
    if (res[0] != c.ISSUEZ_OK) return error.OpenFailed;
    return res[1].?;
}

pub const Synced = struct {
    report: *c.issuez_sync_report,

    pub fn deinit(s: Synced) void {
        c.issuez_sync_report_free(s.report);
    }

    pub fn item(s: Synced, id: []const u8) ?c.issuez_sync_item {
        for (0..c.issuez_sync_report_len(s.report)) |i| {
            const it = c.issuez_sync_report_at(s.report, i).*;
            if (std.mem.eql(u8, slice(it.id), id)) return it;
        }
        return null;
    }
};

pub fn sync(repo: *c.issuez_repo, ops: []const c.issuez_op) !Synced {
    var out: ?*c.issuez_sync_report = null;
    var err: ?*c.issuez_error = null;
    if (c.issuez_sync(repo, str("origin"), ops.ptr, ops.len, null, &out, &err) != c.ISSUEZ_OK) {
        std.debug.print(
            "sync: {s}: {s}\n",
            .{ slice(c.issuez_error_message(err)), slice(c.issuez_error_git_stderr(err)) },
        );
        c.issuez_error_free(err);
        return error.SyncFailed;
    }
    return .{ .report = out.? };
}

/// `git rev-parse --verify -q <ref>` in `dir`: null when there's no such ref.
pub fn revParse(arena: Allocator, dir: []const u8, ref: []const u8) !?[]const u8 {
    var env = try testing.environ.createMap(arena);
    for (env_vars) |kv| try env.put(kv[0], kv[1]);
    const r = try std.process.run(arena, testing.io, .{
        .argv = &.{ "git", "rev-parse", "--verify", "-q", ref },
        .cwd = .{ .path = dir },
        .environ_map = &env,
    });
    return switch (r.term) {
        .exited => |code| if (code == 0) std.mem.trimEnd(u8, r.stdout, "\n") else null,
        else => null,
    };
}

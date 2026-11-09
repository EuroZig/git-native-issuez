//! `issuez_repo`: the open options, the pool of git sessions, and the
//! backend each session runs the engine on.

const std = @import("std");
const assert = std.debug.assert;
const api = @import("api.zig");
const rt = @import("rt.zig");
const cache_mod = @import("cache.zig");
const issuez = @import("issuez");

const Allocator = std.mem.Allocator;
const Code = api.Code;
const Str = api.Str;
const GitProcess = issuez.backend.GitProcess;
const contract = issuez.backend.contract;

// ─── The backend ───────────────────────────────────────────────────────

/// `GitProcess` with what an embedder needs on top: the call's cancel token
/// is checked before every git request, writes are committed as the repo's
/// committer, and git requests are logged at debug level.
pub const Backend = struct {
    git: *GitProcess,
    repo: *RepoObj,
    cancel: ?*api.Cancel = null,

    pub const Error = GitProcess.Error;
    const Self = @This();

    fn check(self: *Self, comptime operation: []const u8) Error!Timer {
        if (rt.cancelled(self.cancel)) return error.Canceled;
        return .{ .operation = operation, .repo = self.repo, .start = now() };
    }

    /// A git request: the cancel token checked first, the time logged after.
    fn traced(
        self: *Self,
        comptime operation: []const u8,
        comptime request: anytype,
        args: anytype,
    ) @typeInfo(@TypeOf(request)).@"fn".return_type.? {
        const t = try self.check(operation);
        defer t.done();
        return @call(.auto, request, .{self.git} ++ args);
    }

    const Timer = struct {
        operation: []const u8,
        repo: *RepoObj,
        start: ?std.Io.Timestamp,

        fn done(t: Timer) void {
            const start = t.start orelse return;
            const elapsed = start.untilNow(rt.io(), .awake);
            rt.log(.debug, .{
                .operation = t.operation,
                .repo_path = t.repo.git_dir.slice(),
                .duration_ns = @intCast(elapsed.toNanoseconds()),
            });
        }
    };

    fn now() ?std.Io.Timestamp {
        if (!rt.logging(.debug)) return null;
        return std.Io.Timestamp.now(rt.io(), .awake);
    }

    pub fn objectFormat(self: *const Self) issuez.backend.object.ObjectFormat {
        return self.git.objectFormat();
    }
    pub fn readObject(self: *Self, arena: Allocator, oid: contract.Oid) Error!?contract.Object {
        return self.traced("git.read-object", GitProcess.readObject, .{ arena, oid });
    }
    pub fn writeObject(
        self: *Self,
        kind: contract.ObjectKind,
        data: []const u8,
    ) Error!contract.Oid {
        return self.traced("git.write-object", GitProcess.writeObject, .{ kind, data });
    }
    pub fn resolveRef(self: *Self, name: []const u8) Error!?contract.Oid {
        return self.traced("git.resolve-ref", GitProcess.resolveRef, .{name});
    }
    pub fn listRefs(self: *Self, arena: Allocator, prefix: []const u8) Error![]contract.RefEntry {
        return self.traced("git.for-each-ref", GitProcess.listRefs, .{ arena, prefix });
    }
    pub fn updateRefs(
        self: *Self,
        updates: []const contract.RefUpdate,
    ) (Error || error{RefConflict})!void {
        return self.traced("git.update-ref", GitProcess.updateRefs, .{updates});
    }
    pub fn isAncestor(self: *Self, a: contract.Oid, b: contract.Oid) Error!bool {
        return self.traced("git.merge-base", GitProcess.isAncestor, .{ a, b });
    }
    pub fn mergeBases(
        self: *Self,
        arena: Allocator,
        a: contract.Oid,
        b: contract.Oid,
    ) Error![]contract.Oid {
        return self.traced("git.merge-base", GitProcess.mergeBases, .{ arena, a, b });
    }
    pub fn configGet(self: *Self, arena: Allocator, key: []const u8) Error!?[]const u8 {
        return self.traced("git.config", GitProcess.configGet, .{ arena, key });
    }
    pub fn configGetAll(self: *Self, arena: Allocator, key: []const u8) Error![]const []const u8 {
        return self.traced("git.config", GitProcess.configGetAll, .{ arena, key });
    }
    pub fn configAdd(self: *Self, key: []const u8, value: []const u8) Error!void {
        return self.traced("git.config", GitProcess.configAdd, .{ key, value });
    }
    pub fn configUnsetValue(self: *Self, key: []const u8, value: []const u8) Error!void {
        return self.traced("git.config", GitProcess.configUnsetValue, .{ key, value });
    }
    pub fn configList(self: *Self, arena: Allocator) Error![]const GitProcess.ConfigEntry {
        return self.traced("git.config", GitProcess.configList, .{arena});
    }
    pub fn remoteNames(self: *Self, arena: Allocator) Error![]const []const u8 {
        return self.traced("git.remote", GitProcess.remoteNames, .{arena});
    }
    /// The repo's committer when it has one; the author is the call's
    /// actor (the engine passes it) or that committer.
    pub fn identity(
        self: *Self,
        arena: Allocator,
    ) (Error || error{IdentityUnknown})!contract.Identity {
        if (self.repo.committer) |c| {
            const sig: contract.Signature = .{
                .name = c.name,
                .email = c.email,
                .time = std.Io.Timestamp.now(rt.io(), .real).toSeconds(),
                .tz_offset_minutes = 0,
            };
            return .{ .author = sig, .committer = sig };
        }
        const t = try self.check("git.var");
        defer t.done();
        return self.git.identity(arena);
    }
    pub fn randomBytes(self: *Self, buf: []u8) void {
        self.git.randomBytes(buf);
    }
    pub fn fetch(
        self: *Self,
        arena: Allocator,
        remote: []const u8,
        refspecs: []const []const u8,
        options: contract.FetchOptions,
    ) (Error || error{FetchFailed})!void {
        return self.traced("git.fetch", GitProcess.fetch, .{ arena, remote, refspecs, options });
    }
    pub fn push(
        self: *Self,
        arena: Allocator,
        remote: []const u8,
        refspecs: []const []const u8,
        options: contract.PushOptions,
    ) (Error || error{PushFailed})!contract.PushResult {
        return self.traced("git.push", GitProcess.push, .{ arena, remote, refspecs, options });
    }
    pub fn pushLeased(
        self: *Self,
        arena: Allocator,
        remote: []const u8,
        updates: []const contract.LeasedRef,
    ) (Error || error{PushFailed})!contract.PushResult {
        return self.traced("git.push", GitProcess.pushLeased, .{ arena, remote, updates });
    }

    // Attachments: the issuez store, and git-lfs for transfers.
    pub fn lfsRead(self: *Self, arena: Allocator, sha256: []const u8) Error!?[]const u8 {
        return self.traced("lfs.read", GitProcess.lfsRead, .{ arena, sha256 });
    }
    pub fn lfsSize(self: *Self, sha256: []const u8) Error!?u64 {
        return self.traced("lfs.size", GitProcess.lfsSize, .{sha256});
    }
    pub fn lfsWrite(self: *Self, sha256: []const u8, data: []const u8) Error!void {
        return self.traced("lfs.write", GitProcess.lfsWrite, .{ sha256, data });
    }
    pub fn lfsList(self: *Self, arena: Allocator) Error![]const []const u8 {
        return self.traced("lfs.list", GitProcess.lfsList, .{arena});
    }
    pub fn lfsAvailable(self: *Self, arena: Allocator) Error!bool {
        return self.traced("lfs.available", GitProcess.lfsAvailable, .{arena});
    }
    pub fn lfsPush(
        self: *Self,
        arena: Allocator,
        remote: []const u8,
        shas: []const []const u8,
    ) (Error || contract.LfsTransportError)!void {
        return self.traced("lfs.push", GitProcess.lfsPush, .{ arena, remote, shas });
    }
    pub fn lfsFetch(
        self: *Self,
        arena: Allocator,
        remote: []const u8,
        local_refs: []const []const u8,
    ) (Error || contract.LfsTransportError)!void {
        return self.traced("lfs.fetch", GitProcess.lfsFetch, .{ arena, remote, local_refs });
    }

    comptime {
        contract.assertBackend(Self);
        assert(contract.hasLfsTransport(Self));
    }
};

pub const IssueRepo = issuez.Repo(Backend);
pub const Catalog = issuez.Catalog(Backend);

// ─── The repo ──────────────────────────────────────────────────────────

pub const Session = struct {
    git: GitProcess,
    backend: Backend,
};

const Committer = struct { name: []const u8, email: []const u8 };

pub const RepoObj = struct {
    refs: std.atomic.Value(u32) = .init(1),
    /// Settings and strings that live as long as the repo.
    arena: *std.heap.ArenaAllocator,
    open_path: []const u8,
    git_dir: Str = .{},
    env: std.process.Environ.Map,
    git_path: []const u8 = "git",
    committer: ?Committer = null,
    timeouts: GitProcess.Timeouts = .{},
    limits: issuez.engine.Limits = .{},
    pool_size: u32 = 4,
    done_override: ?[]const []const u8 = null,
    workflow_override: ?[]const []const u8 = null,
    exclusive_scopes: []const []const u8 = &.{},
    extra_prefixes: []const []const u8 = &.{"X-Forgejo-"},
    /// false: the caller keeps attachment bytes (ISSUEZ_OPT_ATTACHMENT_STORE).
    store_attachments: bool = true,
    import_state: ?*GitProcess.Import = null,
    import_target: ?*RepoObj = null,
    /// The effective settings.
    settings: issuez.Settings = .{},
    /// Issues kept loaded for queries.
    cache: cache_mod.Cache = .{},
    /// issuez_repo_set_logger: this repo's calls log here.
    logger: rt.ScopedLogger = .{},

    mutex: std.Io.Mutex = .init,
    available: std.Io.Condition = .init,
    idle: std.ArrayList(*Session) = .empty,
    live: u32 = 0,

    pub fn retain(r: *RepoObj) void {
        _ = r.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(r: *RepoObj) void {
        if (r.refs.fetchSub(1, .acq_rel) != 1) return;
        for (r.idle.items) |s| {
            s.git.close();
            rt.gpa.destroy(s);
        }
        r.idle.deinit(rt.gpa);
        r.cache.deinit();
        r.env.deinit();
        if (r.import_state) |stage| {
            stage.deinit();
            rt.gpa.destroy(stage);
        }
        if (r.import_target) |target| target.release();
        rt.freeArena(r.arena);
    }

    /// A session for one call, waiting while all are busy. Each starts
    /// with a fresh view of the refs.
    pub fn acquire(r: *RepoObj, cancel: ?*api.Cancel) !*Session {
        const io = rt.io();
        r.mutex.lockUncancelable(io);
        while (r.idle.items.len == 0 and r.live >= r.pool_size) {
            if (cancel == null) {
                r.available.waitUncancelable(io, &r.mutex);
                continue;
            }
            // A token can fire while every session is busy: look again
            // every 50 ms.
            if (rt.cancelled(cancel)) {
                r.mutex.unlock(io);
                return error.Canceled;
            }
            r.mutex.unlock(io);
            std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
            r.mutex.lockUncancelable(io);
        }
        if (r.idle.pop()) |s| {
            r.mutex.unlock(io);
            s.git.refresh();
            s.backend.cancel = cancel;
            s.git.cancel = rt.cancelFlag(cancel);
            return s;
        }
        r.live += 1;
        r.mutex.unlock(io);
        errdefer {
            r.mutex.lockUncancelable(io);
            r.live -= 1;
            r.available.signal(io);
            r.mutex.unlock(io);
        }
        const s = try rt.gpa.create(Session);
        errdefer rt.gpa.destroy(s);
        s.git = try GitProcess.open(io, rt.gpa, .{
            .path = r.open_path,
            .environ_map = &r.env,
            .timeouts = r.timeouts,
            .git = r.git_path,
            .cancel = rt.cancelFlag(cancel),
        });
        s.backend = .{ .git = &s.git, .repo = r, .cancel = cancel };
        s.git.cancel = rt.cancelFlag(cancel);
        return s;
    }

    /// A session outside the pool, with `vars` set in its environment:
    /// the push check reads a push's quarantine this way.
    pub fn openPrivate(r: *RepoObj, cancel: ?*api.Cancel, vars: []const [2][]const u8) !*Session {
        var env = try r.env.clone(rt.gpa);
        defer env.deinit();
        for (vars) |v| try env.put(v[0], v[1]);
        const s = try rt.gpa.create(Session);
        errdefer rt.gpa.destroy(s);
        s.git = try GitProcess.open(rt.io(), rt.gpa, .{
            .path = r.open_path,
            .environ_map = &env,
            .timeouts = r.timeouts,
            .git = r.git_path,
            .cancel = rt.cancelFlag(cancel),
        });
        s.backend = .{ .git = &s.git, .repo = r, .cancel = cancel };
        s.git.cancel = rt.cancelFlag(cancel);
        return s;
    }

    pub fn putBack(r: *RepoObj, s: *Session) void {
        const io = rt.io();
        s.backend.cancel = null;
        s.git.cancel = null;
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        r.idle.append(rt.gpa, s) catch {
            // No room to keep it: close it.
            s.git.close();
            rt.gpa.destroy(s);
            r.live -= 1;
        };
        r.available.signal(io);
    }

    /// The engine's repo over a session, with this repo's settings.
    pub fn engine(r: *RepoObj, s: *Session) IssueRepo {
        var e: IssueRepo = .init(&s.backend);
        e.limits = r.limits;
        e.settings = r.settings;
        return e;
    }
};

/// One call: the repo, a session and an arena, released together.
pub const Call = struct {
    repo: *RepoObj,
    session: *Session,
    arena_state: std.heap.ArenaAllocator,
    /// From `beginPrivate`: closed at the end, not pooled.
    private: bool = false,
    /// Retries of the call's write, for its receipt.
    retries: u32 = 0,
    /// The engine skipped the call's write: it changed nothing.
    skipped: bool = false,
    /// The actor's `user_id`, for `X-Author-Id` on the call's commits.
    author_id: ?[]const u8 = null,
    /// Cache entries the call reads, released at its end.
    held: std.ArrayList(*cache_mod.Entry) = .empty,
    /// The thread's logger before the call, put back at its end.
    outer_logger: rt.ScopedLogger = .{},
    /// What the call's write refused, with the field and value.
    diagnostics: ?issuez.errors.Diagnostics = null,

    /// Fails with NullHandle, Canceled or what opening a
    /// session fails with.
    pub fn begin(repo: ?*api.Repo, cancel: ?*api.Cancel) !Call {
        rt.ensure();
        const r = rt.obj(RepoObj, repo) orelse return error.NullHandle;
        if (rt.cancelled(cancel)) return error.Canceled;
        // Held to the end: issuez_repo_close may come while the call runs.
        r.retain();
        errdefer r.release();
        const s = try r.acquire(cancel);
        const outer = rt.scoped;
        rt.scoped = rt.readScoped(&r.logger);
        return .{ .repo = r, .session = s, .arena_state = .init(rt.gpa), .outer_logger = outer };
    }

    /// Like `begin`, on a session of its own with `vars` in its
    /// environment.
    pub fn beginPrivate(repo: ?*api.Repo, cancel: ?*api.Cancel, vars: []const [2][]const u8) !Call {
        rt.ensure();
        const r = rt.obj(RepoObj, repo) orelse return error.NullHandle;
        if (rt.cancelled(cancel)) return error.Canceled;
        r.retain();
        errdefer r.release();
        const s = try r.openPrivate(cancel, vars);
        const outer = rt.scoped;
        rt.scoped = rt.readScoped(&r.logger);
        return .{
            .repo = r,
            .session = s,
            .arena_state = .init(rt.gpa),
            .private = true,
            .outer_logger = outer,
        };
    }

    pub fn end(c: *Call) void {
        rt.scoped = c.outer_logger;
        for (c.held.items) |e| e.release();
        c.arena_state.deinit();
        if (c.private) {
            c.session.git.close();
            rt.gpa.destroy(c.session);
        } else c.repo.putBack(c.session);
        c.repo.release();
    }

    pub fn arena(c: *Call) Allocator {
        return c.arena_state.allocator();
    }

    /// An issue's ref, whatever `id` is.
    pub fn issueRef(c: *Call, id: []const u8) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(c.arena(), "{s}{s}", .{ issuez.engine.issue_ref_prefix, id });
    }

    pub fn engine(c: *Call) IssueRepo {
        if (c.diagnostics == null) c.diagnostics = .{ .arena = c.arena_state.allocator() };
        var e = c.repo.engine(c.session).withOptions(.{
            .diagnostics = &c.diagnostics.?,
            .author_id = c.author_id,
        });
        e.call.retries = &c.retries;
        e.call.skipped = &c.skipped;
        return e;
    }

    pub fn catalog(c: *Call) Catalog {
        return .fromRepo(c.engine());
    }

    /// An engine error, with git's stderr when git said something.
    pub fn fail(c: *Call, err: ?*?*api.Error, e: anyerror) Code {
        return rt.failError(err, e, .{ .git_stderr = c.session.git.lastStderr() });
    }
};

// ─── Open ──────────────────────────────────────────────────────────────

const Opt = api.Opt;

pub fn issuez_repo_open(
    path: Str,
    opts: ?[*]const api.Op,
    n_opts: usize,
    out: ?*?*api.Repo,
    err: ?*?*api.Error,
) callconv(.c) Code {
    rt.ensure();
    const o = out orelse return rt.badArgument(err, "out is NULL");
    if (path.len == 0) return rt.badArgument(err, "path is empty");
    return open(path.slice(), rt.sliceOf(api.Op, opts, n_opts), null, o, err) catch |e|
        rt.failError(err, e, .{});
}

/// Sets `r` from the open options; problems with them go to `problems`.
fn applyOptions(r: *RepoObj, arena: Allocator, ops: []const api.Op, problems: *rt.Problems) !void {
    var done: std.ArrayList([]const u8) = .empty;
    var workflow: std.ArrayList([]const u8) = .empty;
    var scopes: std.ArrayList([]const u8) = .empty;
    var prefixes: std.ArrayList([]const u8) = .empty;
    for (ops, 0..) |op, i| {
        const check: rt.OpCheck = .at(arena, problems, i);
        if (try check.reserved(op)) continue;
        const verb: api.Verb = @enumFromInt(op.verb);
        const target: Opt = @enumFromInt(op.target);
        const s = op.str.slice();
        switch (target) {
            .git_path => r.git_path = try arena.dupe(u8, s),
            .env => switch (verb) {
                .clear => if (op.name.len == 0) {
                    r.env.deinit();
                    r.env = .init(rt.gpa);
                } else {
                    _ = r.env.swapRemove(op.name.slice());
                },
                else => try r.env.put(op.name.slice(), s),
            },
            .committer => {
                // Every commit is signed with it, at UTC.
                const sig: issuez.backend.object.Signature = .{
                    .name = op.person.name.slice(),
                    .email = op.person.email.slice(),
                    .time = 0,
                    .tz_offset_minutes = 0,
                };
                if (!sig.isValid()) {
                    try check.add(.bad_format, "a committer can't hold <, >, a newline or a NUL");
                    continue;
                }
                r.committer = .{
                    .name = try arena.dupe(u8, sig.name),
                    .email = try arena.dupe(u8, sig.email),
                };
            },
            .done_state => try done.append(arena, try arena.dupe(u8, s)),
            .workflow_state => try workflow.append(arena, try arena.dupe(u8, s)),
            .exclusive_scope => try scopes.append(arena, try arena.dupe(u8, s)),
            .extra_prefix => try prefixes.append(arena, try arena.dupe(u8, s)),
            .pool_size => if (op.num < 1 or op.num > 64) {
                try check.add(.bad_format, "pool size is 1 to 64");
            } else {
                r.pool_size = @intCast(op.num);
            },
            .timeout_local_ms => if (op.num > 0) {
                const d: std.Io.Duration = .fromMilliseconds(op.num);
                r.timeouts.command = d;
                r.timeouts.request = d;
            },
            .cache_issues => if (op.num < 0) {
                try check.add(.bad_format, "the cache size can't be negative");
            } else {
                r.cache.max = @intCast(op.num);
            },
            .attachment_store => r.store_attachments = op.num != 0,
            .limit => if (!setLimit(&r.limits, op.name.slice(), op.num)) {
                try problems.append(arena, .{
                    .kind = .unknown_target,
                    .key = try arena.dupe(u8, op.name.slice()),
                    .message = "no such limit",
                    .op_index = check.index,
                });
            },
            else => try check.add(.unknown_target, "not an option of issuez_repo_open"),
        }
    }
    if (!r.limits.valid()) try problems.append(arena, .{
        .kind = .bad_format,
        .message = "a limit is out of range",
    });
    if (done.items.len > 0) r.done_override = done.items;
    if (workflow.items.len > 0) r.workflow_override = workflow.items;
    r.exclusive_scopes = scopes.items;
    if (prefixes.items.len > 0) r.extra_prefixes = prefixes.items;
}

/// `issuez_ops_validate` for ISSUEZ_LIST_OPEN: the options on a repo that
/// is never opened.
pub fn validateOpen(arena: Allocator, ops: []const api.Op, problems: *rt.Problems) !void {
    var r: RepoObj = .{ .arena = undefined, .open_path = "", .env = .init(rt.gpa) };
    defer r.env.deinit();
    try applyOptions(&r, arena, ops, problems);
}

fn open(
    path: []const u8,
    ops: []const api.Op,
    cancel: ?*api.Cancel,
    out: *?*api.Repo,
    err: ?*?*api.Error,
) !Code {
    const arena_state = try rt.newArena();
    errdefer rt.freeArena(arena_state);
    const arena = arena_state.allocator();
    const r = try arena.create(RepoObj);
    r.* = .{
        .arena = arena_state,
        .open_path = try arena.dupe(u8, path),
        .env = try std.process.Environ.createMap(rt.processEnviron(), rt.gpa),
    };
    errdefer r.env.deinit();

    var problems: rt.Problems = .empty;
    try applyOptions(r, arena, ops, &problems);
    if (problems.items.len > 0) {
        // The problems point into the arena: copy them out first.
        const code = rt.badOps(err, problems.items, "invalid options");
        r.env.deinit();
        rt.freeArena(arena_state);
        return code;
    }

    // The first session checks git and the repository now, and stays.
    const s = try r.acquire(cancel);
    errdefer {
        s.git.close();
        rt.gpa.destroy(s);
    }
    var scratch: std.heap.ArenaAllocator = .init(rt.gpa);
    defer scratch.deinit();
    const configured = issuez.settings.read(Backend, scratch.allocator(), &s.backend) catch |e| {
        const code = rt.failError(err, e, .{ .git_stderr = s.git.lastStderr() });
        s.git.close();
        rt.gpa.destroy(s);
        r.env.deinit();
        rt.freeArena(arena_state);
        return code;
    };
    r.settings = .{
        .done_states = try dupeList(arena, r.done_override orelse configured.done_states),
        .workflow_states = try dupeList(
            arena,
            r.workflow_override orelse configured.workflow_states,
        ),
        .invalid_done_state = if (r.done_override != null) null else configured.invalid_done_state,
        .invalid_workflow_state = if (r.workflow_override != null)
            null
        else
            configured.invalid_workflow_state,
    };
    r.git_dir = try rt.dupeZ(arena, s.git.common_dir orelse r.open_path);
    r.putBack(s);
    rt.log(.info, .{ .operation = "repo.open", .repo_path = r.git_dir.slice() });
    out.* = @ptrCast(r);
    return .ok;
}

fn dupeList(arena: Allocator, list: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, list.len);
    for (list, out) |s, *o| o.* = try arena.dupe(u8, s);
    return out;
}

fn setLimit(limits: *issuez.engine.Limits, name: []const u8, value: i64) bool {
    inline for (std.meta.fields(issuez.engine.Limits)) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            @field(limits, f.name) = std.math.cast(f.type, value) orelse return false;
            return true;
        }
    }
    return false;
}

pub fn issuez_repo_close(repo: ?*api.Repo) callconv(.c) void {
    const r = rt.obj(RepoObj, repo) orelse return;
    r.release();
}

pub fn issuez_repo_set_logger(
    repo: ?*api.Repo,
    min_level: api.LogLevel,
    cb: api.LogFn,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const r = rt.obj(RepoObj, repo) orelse return;
    rt.setScoped(&r.logger, min_level, cb, userdata);
}

const RepoReads = rt.Reads(api.Repo, RepoObj);
pub const issuez_repo_git_dir = RepoReads.field("git_dir");

pub fn issuez_repo_limit(repo: ?*const api.Repo, name: Str, out: ?*u64) callconv(.c) bool {
    const r = rt.obj(RepoObj, repo) orelse return false;
    inline for (std.meta.fields(issuez.engine.Limits)) |f| {
        if (std.mem.eql(u8, f.name, name.slice())) {
            if (out) |o| o.* = @field(r.limits, f.name);
            return true;
        }
    }
    return false;
}

/// Rebuild the immutable open options so staging uses the same policy.
fn importOptions(a: Allocator, r: *RepoObj, env: *const std.process.Environ.Map) ![]api.Op {
    var ops: OpBuilder = .{ .a = a };
    try ops.add(.clear, .env, .{});
    var it = env.iterator();
    while (it.next()) |kv|
        try ops.add(.set, .env, .{ .name = Str.of(kv.key_ptr.*), .str = Str.of(kv.value_ptr.*) });
    try ops.add(.set, .git_path, .{ .str = Str.of(r.git_path) });
    if (r.committer) |who| try ops.add(.set, .committer, .{
        .person = .{ .name = Str.of(who.name), .email = Str.of(who.email) },
    });
    for (r.settings.done_states) |v| try ops.add(.add, .done_state, .{ .str = Str.of(v) });
    for (r.settings.workflow_states) |v| try ops.add(.add, .workflow_state, .{ .str = Str.of(v) });
    for (r.exclusive_scopes) |v| try ops.add(.add, .exclusive_scope, .{ .str = Str.of(v) });
    for (r.extra_prefixes) |v| try ops.add(.add, .extra_prefix, .{ .str = Str.of(v) });
    inline for (@typeInfo(issuez.engine.Limits).@"struct".fields) |field| {
        try ops.add(.set, .limit, .{
            .name = Str.of(field.name),
            .num = @intCast(@field(r.limits, field.name)),
        });
    }
    try ops.add(.set, .attachment_store, .{ .num = @intFromBool(r.store_attachments) });
    try ops.add(.set, .pool_size, .{ .num = r.pool_size });
    try ops.add(.set, .cache_issues, .{ .num = @intCast(r.cache.max) });
    try ops.add(.set, .timeout_local_ms, .{ .num = r.timeouts.command.toMilliseconds() });
    return ops.list.items;
}

const OpBuilder = struct {
    a: Allocator,
    list: std.ArrayList(api.Op) = .empty,

    /// `value` with the verb and the target set.
    fn add(b: *OpBuilder, verb: api.Verb, target: Opt, value: api.Op) !void {
        var op = value;
        op.verb = @intFromEnum(verb);
        op.target = @intFromEnum(target);
        try b.list.append(b.a, op);
    }
};

pub fn issuez_repo_begin_import(
    repo: ?*api.Repo,
    cancel: ?*api.Cancel,
    out: ?*?*api.Repo,
    err: ?*?*api.Error,
) callconv(.c) Code {
    const o = out orelse return rt.badArgument(err, "out is NULL");
    var c = Call.begin(repo, cancel) catch |e| return rt.failError(err, e, .{});
    defer c.end();
    const stage = rt.gpa.create(GitProcess.Import) catch |e| return rt.failError(err, e, .{});
    stage.* = c.session.git.beginImport(c.arena()) catch |e| {
        rt.gpa.destroy(stage);
        return c.fail(err, e);
    };
    var adopted = false;
    defer if (!adopted) {
        stage.deinit();
        rt.gpa.destroy(stage);
    };
    const ops = importOptions(c.arena(), c.repo, &stage.git.env) catch |e| return c.fail(err, e);
    var handle: ?*api.Repo = null;
    const code = open(stage.path, ops, cancel, &handle, err) catch |e| return c.fail(err, e);
    if (code != .ok) return code;
    const r = rt.obj(RepoObj, handle).?;
    r.timeouts = c.repo.timeouts;
    r.pool_size = c.repo.pool_size;
    r.cache.max = c.repo.cache.max;
    r.import_state = stage;
    r.import_target = c.repo;
    c.repo.retain();
    adopted = true;
    o.* = handle;
    return .ok;
}

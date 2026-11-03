//! `git issue mcp`: a Model Context Protocol server on stdio, for coding
//! agents. The tools are in tools.zig.

const std = @import("std");
const issuez = @import("issuez");
const mcp = @import("blitzmcp");
pub const tools = @import("tools.zig");
const install = @import("install.zig");
const RepoWatcher = @import("RepoWatcher");

const GitProcess = issuez.backend.GitProcess;
const changes = issuez.changes;

/// In help.zig, which builds without the MCP server have too.
pub const help = @import("mcp_help").text;

const version: []const u8 = @import("build.zig.zon").version;

/// The repository at `path`, and those that tool calls name with `repo`.
/// Each is opened on the first call that needs it rather than at start: a
/// client may start the server outside a repository, and it should then
/// still run and say so on each call. One `GitProcess` per repository after
/// that, refreshed for each call so that every call reads the refs as they
/// are now.
const ProcessRepos = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    git: ?GitProcess = null,
    /// By the `repo` path as given, oldest first. Owns keys and values.
    others: std.StringArrayHashMapUnmanaged(*GitProcess) = .empty,
    /// Where notifications go; null leaves subscriptions unwatched.
    /// Written from the watcher's thread too, so thread-safe for writes.
    transport: ?*mcp.Transport = null,
    /// Watches the server's repository from the first subscription on.
    live: ?*Live = null,

    pub const Backend = GitProcess;

    /// Repositories named by `repo` kept open; more close the oldest.
    const max_others = 16;

    pub fn open(r: *ProcessRepos, ctx: *mcp.Context, repo: ?[]const u8) !*GitProcess {
        const path = repo orelse {
            if (r.git) |*git| {
                git.refresh();
                return git;
            }
            r.git = try r.openPath(ctx, r.path, true);
            return &r.git.?;
        };
        if (!std.fs.path.isAbsolute(path)) return ctx.fail(
            error.InvalidValue,
            "repo must be an absolute path, not '{s}'",
            .{path},
        );
        if (r.others.get(path)) |git| {
            git.refresh();
            return git;
        }
        const git = try r.gpa.create(GitProcess);
        errdefer r.gpa.destroy(git);
        git.* = try r.openPath(ctx, path, false);
        errdefer git.close();
        const key = try r.gpa.dupe(u8, path);
        errdefer r.gpa.free(key);
        if (r.others.count() == max_others) r.closeOther(0);
        try r.others.put(r.gpa, key, git);
        return git;
    }

    pub fn close(_: *ProcessRepos, _: *GitProcess) void {}

    /// For `resources/subscribe`: starts watching the server's repository.
    pub fn watch(r: *ProcessRepos, ctx: *mcp.Context, subscriptions: *tools.Subscriptions) !void {
        if (r.live != null) return;
        const transport = r.transport orelse return;
        const live = try r.gpa.create(Live);
        errdefer r.gpa.destroy(live);
        // Its own process: the watcher's thread reads the refs with it.
        var git = try r.openPath(ctx, r.path, true);
        errdefer git.close();
        live.start(r.io, r.gpa, git, transport, subscriptions) catch |e| return switch (e) {
            error.OutOfMemory => e,
            else => ctx.fail(e, "can't watch the repository for changes: {t}", .{e}),
        };
        r.live = live;
    }

    fn openPath(r: *ProcessRepos, ctx: *mcp.Context, path: []const u8, default: bool) !GitProcess {
        return GitProcess.open(r.io, r.gpa, .{ .path = path, .environ_map = r.environ_map }) catch |e| switch (e) {
            error.NotARepository => ctx.fail(e, "not a git repository: {s}{s}", .{
                path,
                if (default) "; give repo, the repository's absolute path" else "",
            }),
            else => tools.failWith(ctx, e, .{}, null),
        };
    }

    fn closeOther(r: *ProcessRepos, index: usize) void {
        const key = r.others.keys()[index];
        const git = r.others.values()[index];
        r.others.orderedRemoveAt(index);
        git.close();
        r.gpa.destroy(git);
        r.gpa.free(key);
    }

    fn deinit(r: *ProcessRepos) void {
        if (r.live) |live| {
            live.stop();
            r.gpa.destroy(live);
        }
        if (r.git) |*git| git.close();
        while (r.others.count() > 0) r.closeOther(r.others.count() - 1);
        r.others.deinit(r.gpa);
    }
};

/// Tells the client which subscribed resources others changed (or this
/// server did), with `notifications/resources/updated`: a RepoWatcher on
/// the repository, and the refs read again on its thread to see what
/// moved.
const Live = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    git: GitProcess,
    transport: *mcp.Transport,
    subscriptions: *tools.Subscriptions,
    /// As last read, owned.
    refs: changes.RefState,
    watcher: RepoWatcher,

    /// In place. Owns `git` from here on, also on failure.
    fn start(
        live: *Live,
        io: std.Io,
        gpa: std.mem.Allocator,
        git: GitProcess,
        transport: *mcp.Transport,
        subscriptions: *tools.Subscriptions,
    ) !void {
        live.* = .{
            .io = io,
            .gpa = gpa,
            .git = git,
            .transport = transport,
            .subscriptions = subscriptions,
            .refs = .{},
            .watcher = undefined,
        };
        errdefer live.git.close();
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        live.refs = try (try changes.RefState.read(arena_state.allocator(), &live.git)).clone(gpa);
        errdefer live.refs.deinit(gpa);
        try live.watcher.init(io, gpa, live.git.common_dir.?, .{ .context = live, .changed = changed }, .{});
    }

    fn stop(live: *Live) void {
        live.watcher.deinit();
        live.refs.deinit(live.gpa);
        live.git.close();
        live.* = undefined;
    }

    /// On the watcher's thread.
    fn changed(context: *anyopaque, change: RepoWatcher.Change) void {
        const live: *Live = @ptrCast(@alignCast(context));
        live.notify(change.config) catch |e| std.log.scoped(.mcp).warn("watching the repository: {t}", .{e});
    }

    fn notify(live: *Live, settings: bool) !void {
        var arena_state: std.heap.ArenaAllocator = .init(live.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const now = try changes.RefState.read(arena, &live.git);
        const d = try changes.diff(arena, live.refs, now);
        if (d.empty() and !settings) return;
        // Before the client hears of it, so a read it makes then and a
        // change after it are told apart.
        const uris = try live.subscriptions.affected(live.io, arena, d, settings);
        var next = try now.clone(live.gpa);
        std.mem.swap(changes.RefState, &live.refs, &next);
        next.deinit(live.gpa);
        for (uris) |uri| try live.transport.writeNotification(
            live.io,
            arena,
            "notifications/resources/updated",
            mcp.types.ResourceUpdatedNotificationParams,
            .{ .uri = uri },
            .{ .emit_null_optional_fields = false },
        );
    }
};

const Server = tools.Server(ProcessRepos, version);

/// Responses from the server, notifications from the watcher's thread.
const SafeTransport = mcp.Transport.ThreadSafe(.{ .thread_safe_read = false, .thread_safe_write = true });

pub fn main(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    args: []const []const u8,
) u8 {
    if (args.len > 0 and std.mem.eql(u8, args[0], "install")) return installMain(io, gpa, environ_map, out, err, args[1..]);
    var path: []const u8 = ".";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            out.writeAll(help) catch {};
            return 0;
        } else if (std.mem.eql(u8, arg, "--repo")) {
            i += 1;
            if (i == args.len) {
                err.writeAll("error: --repo requires a value\n") catch {};
                return 1;
            }
            path = args[i];
        } else {
            err.print(
                "error: unknown option '{s}'\nRun 'git issue mcp --help' for usage.\n",
                .{arg},
            ) catch {};
            return 1;
        }
    }

    var read_buffer: [64 * 1024]u8 = undefined;
    var stdio: mcp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    var transport: SafeTransport = .init(&stdio.transport);
    var repos: ProcessRepos = .{
        .io = io,
        .gpa = gpa,
        .environ_map = environ_map,
        .path = path,
        .transport = &transport.transport,
    };
    defer repos.deinit();
    var handler: tools.Handler(ProcessRepos) = .{ .repos = &repos };
    var server: Server = .init(&handler);
    server.run(io, gpa, &transport.transport) catch |e| {
        err.print("git-issue: mcp server stopped: {t}\n", .{e}) catch {};
        return 1;
    };
    return 0;
}

fn installMain(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    args: []const []const u8,
) u8 {
    var options: install.Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            out.writeAll(help) catch {};
            return 0;
        } else if (std.mem.eql(u8, arg, "--print")) {
            options.print = true;
        } else if (std.mem.eql(u8, arg, "--name")) {
            options.name = value(args, &i, err) orelse return 1;
        } else if (std.mem.eql(u8, arg, "--scope")) {
            const v = value(args, &i, err) orelse return 1;
            options.scope = std.meta.stringToEnum(install.Scope, v) orelse {
                err.print("error: --scope must be user, local or project, not '{s}'\n", .{v}) catch {};
                return 1;
            };
        } else {
            err.print(
                "error: unknown option '{s}'\nRun 'git issue mcp --help' for usage.\n",
                .{arg},
            ) catch {};
            return 1;
        }
    }
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    return install.run(io, arena_state.allocator(), environ_map, out, err, options) catch |e| {
        err.print("error: git issue mcp install: {t}\n", .{e}) catch {};
        return 1;
    };
}

/// The value after option `args[i.*]`, which `i` then points to.
fn value(args: []const []const u8, i: *usize, err: *std.Io.Writer) ?[]const u8 {
    const option = args[i.*];
    i.* += 1;
    if (i.* == args.len) {
        err.print("error: {s} requires a value\n", .{option}) catch {};
        return null;
    }
    return args[i.*];
}

test {
    _ = tools;
    _ = install;
    _ = @import("tools_test.zig");
}

const testing = std.testing;

/// The `result` of a `tools/call` to `server`.
fn testCall(arena: std.mem.Allocator, server: *Server, name: []const u8, arguments: []const u8) !std.json.ObjectMap {
    var reader: std.Io.Reader = .fixed("");
    var out: std.Io.Writer.Allocating = .init(arena);
    var stream: mcp.Transport.Stream = .init(&reader, &out.writer);
    const msg = try std.fmt.allocPrint(
        arena,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}",
        .{ name, arguments },
    );
    try server.handleMessage(testing.io, testing.allocator, &stream.transport, msg);
    const response = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    return response.object.get("result").?.object;
}

fn testError(result: std.json.ObjectMap) ![]const u8 {
    try testing.expect(result.get("isError").?.bool);
    return result.get("content").?.array.items[0].object.get("text").?.string;
}

fn testTotal(result: std.json.ObjectMap) !i64 {
    try testing.expect(result.get("isError") == null);
    return result.get("structuredContent").?.object.get("total").?.integer;
}

fn testGitInit(arena: std.mem.Allocator, env: *const std.process.Environ.Map, dir: []const u8) !void {
    const init = try std.process.run(arena, testing.io, .{
        .argv = &.{ "git", "init", "-q", dir },
        .environ_map = env,
    });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, init.term);
}

test "repositories: outside one, named by repo, made since" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(testing.io, arena);
    const dir = try std.fmt.allocPrint(arena, "{s}/.zig-cache/tmp/{s}", .{ cwd, tmp.sub_path });
    var env = try testing.environ.createMap(arena);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("GIT_AUTHOR_NAME", "Ada");
    try env.put("GIT_AUTHOR_EMAIL", "ada@example.invalid");
    try env.put("GIT_COMMITTER_NAME", "Ada");
    try env.put("GIT_COMMITTER_EMAIL", "ada@example.invalid");
    // Not inside the build's own repository.
    try env.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(dir).?);

    var repos: ProcessRepos = .{ .io = testing.io, .gpa = testing.allocator, .environ_map = &env, .path = dir };
    defer repos.deinit();
    var handler: tools.Handler(ProcessRepos) = .{ .repos = &repos };
    var server: Server = .init(&handler);
    server.connection.markInitialized(.{
        .protocolVersion = mcp.types.latest_protocol_version,
        .capabilities = .{},
        .clientInfo = .{ .name = "test", .version = "0" },
    });

    // The server runs outside a repository, and each call says so.
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "not a git repository: {s}; give repo, the repository's absolute path", .{dir}),
        try testError(try testCall(arena, &server, "list_issues", "{}")),
    );

    // Another repository, by repo.
    const other = try std.fmt.allocPrint(arena, "{s}/other", .{dir});
    try testGitInit(arena, &env, other);
    const in_other = try std.fmt.allocPrint(arena, "{{\"repo\":\"{s}\"}}", .{other});
    const create = try std.fmt.allocPrint(arena, "{{\"repo\":\"{s}\",\"title\":\"In the other one\"}}", .{other});
    try testing.expect((try testCall(arena, &server, "create_issue", create)).get("isError") == null);
    try testing.expectEqual(@as(i64, 1), try testTotal(try testCall(arena, &server, "list_issues", in_other)));
    const missing = try std.fmt.allocPrint(arena, "{s}/missing", .{dir});
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "not a git repository: {s}", .{missing}),
        try testError(try testCall(arena, &server, "list_issues", try std.fmt.allocPrint(arena, "{{\"repo\":\"{s}\"}}", .{missing}))),
    );
    try testing.expectEqualStrings(
        "repo must be an absolute path, not 'other'",
        try testError(try testCall(arena, &server, "list_issues", "{\"repo\":\"other\"}")),
    );

    // The server's repository, made since, is found on the next call.
    try testGitInit(arena, &env, dir);
    try testing.expectEqual(@as(i64, 0), try testTotal(try testCall(arena, &server, "list_issues", "{}")));
}

test "a subscription hears of changes, its own and others'" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, arena);
    const dir = try std.fmt.allocPrint(arena, "{s}/.zig-cache/tmp/{s}", .{ cwd, tmp.sub_path });
    var env = try testing.environ.createMap(arena);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("GIT_AUTHOR_NAME", "Ada");
    try env.put("GIT_AUTHOR_EMAIL", "ada@example.invalid");
    try env.put("GIT_COMMITTER_NAME", "Ada");
    try env.put("GIT_COMMITTER_EMAIL", "ada@example.invalid");
    try env.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(dir).?);
    try testGitInit(arena, &env, dir);

    // What the server writes, notifications included.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var reader: std.Io.Reader = .fixed("");
    var stream: mcp.Transport.Stream = .init(&reader, &out.writer);
    var transport: SafeTransport = .init(&stream.transport);

    var repos: ProcessRepos = .{
        .io = io,
        .gpa = testing.allocator,
        .environ_map = &env,
        .path = dir,
        .transport = &transport.transport,
    };
    defer repos.deinit();
    var handler: tools.Handler(ProcessRepos) = .{ .repos = &repos };
    var server: Server = .init(&handler);
    server.connection.markInitialized(.{
        .protocolVersion = mcp.types.latest_protocol_version,
        .capabilities = .{},
        .clientInfo = .{ .name = "test", .version = "0" },
    });

    const subscribe =
        \\{"jsonrpc":"2.0","id":1,"method":"resources/subscribe","params":{"uri":"git-issue://issues"}}
    ;
    try server.handleMessage(io, testing.allocator, &transport.transport, subscribe);
    try testing.expect(repos.live != null);

    // Another process writes.
    var other = try GitProcess.open(io, testing.allocator, .{ .path = dir, .environ_map = &env });
    defer other.close();
    _ = try issuez.Repo(GitProcess).init(&other).create(arena, .{ .title = "Elsewhere" });

    const updated =
        \\{"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"git-issue://issues"}}
    ;
    var waited: u32 = 0;
    while (true) : (waited += 1) {
        transport.out_mutex.lockUncancelable(io);
        const seen = std.mem.find(u8, out.written(), updated) != null;
        transport.out_mutex.unlock(io);
        if (seen) break;
        if (waited == 500) return error.Timeout;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
}

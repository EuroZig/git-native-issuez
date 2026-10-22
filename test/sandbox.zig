//! A fresh git repository in a temporary directory, with git isolated from
//! user and system config, for tests that run our binaries against real git.

const std = @import("std");
const testing = std.testing;

const io = testing.io;

const Sandbox = @This();

tmp: testing.TmpDir,
repo: []const u8,
env: std.process.Environ.Map,
arena_state: std.heap.ArenaAllocator,

pub const Options = struct {
    /// Set GIT_AUTHOR_*/GIT_COMMITTER_* to a fixed identity.
    identity: bool = true,
};

pub const identity_name = "Example Tester";
pub const identity_email = "example@example.invalid";

pub fn init(options: Options) !Sandbox {
    var sb: Sandbox = .{
        .tmp = testing.tmpDir(.{}),
        .repo = undefined,
        .env = try testing.environ.createMap(testing.allocator),
        .arena_state = .init(testing.allocator),
    };
    errdefer sb.deinit();
    const cwd = try std.process.currentPathAlloc(io, sb.arena());
    sb.repo = try std.fmt.allocPrint(
        sb.arena(),
        "{s}/.zig-cache/tmp/{s}/repo",
        .{ cwd, sb.tmp.sub_path },
    );

    try sb.env.put("GIT_CONFIG_NOSYSTEM", "1");
    try sb.env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    for ([_][]const u8{
        "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "EMAIL",
    }) |name| _ = sb.env.swapRemove(name);
    if (options.identity) {
        try sb.env.put("GIT_AUTHOR_NAME", identity_name);
        try sb.env.put("GIT_AUTHOR_EMAIL", identity_email);
        try sb.env.put("GIT_COMMITTER_NAME", identity_name);
        try sb.env.put("GIT_COMMITTER_EMAIL", identity_email);
    }

    try sb.git(&.{ "init", "-q", sb.repo });
    return sb;
}

pub fn deinit(sb: *Sandbox) void {
    sb.env.deinit();
    sb.arena_state.deinit();
    sb.tmp.cleanup();
}

pub fn arena(sb: *Sandbox) std.mem.Allocator {
    return sb.arena_state.allocator();
}

pub const Output = struct { stdout: []const u8, stderr: []const u8, code: u8 };

/// Runs `argv` with the sandbox environment, in `cwd` (default: the repo).
pub fn runIn(sb: *Sandbox, cwd: ?[]const u8, argv: []const []const u8) !Output {
    const result = try std.process.run(sb.arena(), io, .{
        .argv = argv,
        .cwd = .{ .path = cwd orelse sb.repo },
        .environ_map = &sb.env,
    });
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .code = code };
}

pub fn run(sb: *Sandbox, argv: []const []const u8) !Output {
    return sb.runIn(null, argv);
}

/// Runs `git args...` in the repo. Fails the test if git fails.
pub fn git(sb: *Sandbox, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(sb.arena(), "git");
    try argv.appendSlice(sb.arena(), args);
    // `git init <path>` runs before the repo exists.
    const out = try sb.runIn(if (std.mem.eql(u8, args[0], "init")) "." else null, argv.items);
    if (out.code != 0) {
        std.debug.print("git {s} failed: {s}\n", .{ args[0], out.stderr });
        return error.GitFailed;
    }
}

/// Runs `exe args...` in the repo.
pub fn tool(sb: *Sandbox, exe: []const u8, args: []const []const u8) !Output {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(sb.arena(), exe);
    try argv.appendSlice(sb.arena(), args);
    return sb.run(argv.items);
}

pub fn expectSuccess(out: Output) !void {
    if (out.code != 0) std.debug.print("command failed ({d}): {s}\n", .{ out.code, out.stderr });
    try testing.expectEqual(@as(u8, 0), out.code);
}

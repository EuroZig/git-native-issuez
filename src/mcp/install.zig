//! `git issue mcp install`: registers the server with Claude Code (`claude
//! mcp add`), or prints the configuration other clients take.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Scope = enum { user, local, project };

pub const Options = struct {
    scope: Scope = .user,
    name: []const u8 = "git-issue",
    /// Print the JSON configuration instead of running `claude`.
    print: bool = false,
};

/// The command a client runs. In the repository's `.mcp.json` (project
/// scope), `git issue mcp`, which works on every machine; otherwise this
/// binary by its absolute path, since clients started from a desktop
/// often have a shorter PATH than a terminal.
pub const Command = struct {
    command: []const u8,
    args: []const []const u8,
};

pub fn command(scope: Scope, exe: []const u8) Command {
    return switch (scope) {
        .project => .{ .command = "git", .args = &.{ "issue", "mcp" } },
        .user, .local => .{ .command = exe, .args = &.{"mcp"} },
    };
}

/// `claude mcp add` for `cmd`.
pub fn claudeArgv(arena: Allocator, options: Options, cmd: Command) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "claude", "mcp", "add", "--scope", @tagName(options.scope), options.name, "--", cmd.command });
    try argv.appendSlice(arena, cmd.args);
    return argv.items;
}

/// The `mcpServers` entry that Claude Desktop, Cursor and others read.
pub fn writeJson(out: *Io.Writer, name: []const u8, cmd: Command) Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("mcpServers");
    try s.beginObject();
    try s.objectField(name);
    try s.write(cmd);
    try s.endObject();
    try s.endObject();
    try out.writeByte('\n');
}

/// This program by a stable path: `git-issue` on PATH if that is this
/// binary (a package manager's link survives upgrades), else the binary
/// itself.
fn exePath(io: Io, arena: Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    const self = try std.process.executablePathAlloc(io, arena);
    const path = environ_map.get("PATH") orelse return self;
    var dirs = std.mem.tokenizeScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        if (!std.fs.path.isAbsolute(dir)) continue;
        const candidate = try std.fs.path.join(arena, &.{ dir, "git-issue" });
        const real = Io.Dir.realPathFileAbsoluteAlloc(io, candidate, arena) catch continue;
        if (std.mem.eql(u8, real, self)) return candidate;
    }
    return self;
}

/// The top of the work tree, where `claude` writes `.mcp.json`.
fn topLevel(io: Io, arena: Allocator, environ_map: *const std.process.Environ.Map) !?[]const u8 {
    const result = try std.process.run(arena, io, .{
        .argv = &.{ "git", "rev-parse", "--show-toplevel" },
        .environ_map = environ_map,
    });
    if (result.term != .exited or result.term.exited != 0) return null;
    return std.mem.trimEnd(u8, result.stdout, "\n");
}

pub fn run(
    io: Io,
    arena: Allocator,
    environ_map: *const std.process.Environ.Map,
    out: *Io.Writer,
    err: *Io.Writer,
    options: Options,
) !u8 {
    const cmd = command(options.scope, try exePath(io, arena, environ_map));
    if (options.print) {
        try writeJson(out, options.name, cmd);
        return 0;
    }

    var cwd: std.process.Child.Cwd = .inherit;
    if (options.scope == .project) {
        const top = try topLevel(io, arena, environ_map) orelse {
            try err.writeAll("fatal: --scope project needs a work tree: it writes .mcp.json at its top\n");
            return 128;
        };
        cwd = .{ .path = top };
    }
    const argv = try claudeArgv(arena, options, cmd);
    const result = std.process.run(arena, io, .{ .argv = argv, .cwd = cwd, .environ_map = environ_map }) catch |e| switch (e) {
        error.FileNotFound => {
            try err.writeAll(
                \\error: 'claude' is not on PATH. Install Claude Code, or run
                \\'git issue mcp install --print' for the configuration other clients take.
                \\
            );
            return 1;
        },
        else => return e,
    };
    try out.writeAll(result.stdout);
    try err.writeAll(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        try err.print("error: '{s}' failed\n", .{try std.mem.join(arena, " ", argv)});
        return 1;
    }
    return 0;
}

const testing = std.testing;

test "the command by scope" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const user = command(.user, "/opt/bin/git-issue");
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "claude", "mcp", "add", "--scope", "user", "git-issue", "--", "/opt/bin/git-issue", "mcp" }),
        try claudeArgv(arena, .{}, user),
    );
    const project = command(.project, "/opt/bin/git-issue");
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "claude", "mcp", "add", "--scope", "project", "issues", "--", "git", "issue", "mcp" }),
        try claudeArgv(arena, .{ .scope = .project, .name = "issues" }, project),
    );

    var json: Io.Writer.Allocating = .init(arena);
    try writeJson(&json.writer, "git-issue", command(.user, "/a \"b\"/git-issue"));
    try testing.expectEqualStrings(
        \\{
        \\  "mcpServers": {
        \\    "git-issue": {
        \\      "command": "/a \"b\"/git-issue",
        \\      "args": [
        \\        "mcp"
        \\      ]
        \\    }
        \\  }
        \\}
        \\
    , json.written());
}

//! `git-issue-sim`: the real command code running against `GitSim`.

const std = @import("std");
const issuez = @import("issuez");
const fatal = @import("fatal.zig");
const simulate = @import("simulate.zig");

const GitSim = issuez.backend.GitSim;
const World = GitSim.World;

const help =
    \\usage: git-issue-sim [--clone NAME] <command> [<args>]
    \\
    \\Runs one git-issue command against a simulated repository instead of
    \\real git. Reads a world document (ZON, see GitSim.World) on stdin, runs
    \\the command against clone NAME (default: the first clone), and writes
    \\the resulting world to stdout. Command output goes to stderr.
    \\
    \\The exit status is the command's exit status.
    \\
;

var stdout_buffer: [64 * 1024]u8 = undefined;
var stderr_buffer: [4 * 1024]u8 = undefined;

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch |err| switch (err) {
        error.OutOfMemory => |e| fatal.oom(e),
        else => fatal.msg("unable to read command line arguments", .{}),
    };

    var clone_name: ?[]const u8 = null;
    var first: usize = 1;
    while (first < args.len) {
        const arg = args[first];
        if (std.mem.eql(u8, arg, "--clone")) {
            if (first + 1 >= args.len) fatal.msg("--clone needs a value", .{});
            clone_name = args[first + 1];
            first += 2;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{help});
            return 0;
        } else break;
    }
    if (first >= args.len) {
        std.debug.print("error: missing command\n\n{s}", .{help});
        return 2;
    }

    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &.{});
    const source = stdin_reader.interface.allocRemainingAlignedSentinel(
        arena,
        .limited(256 * 1024 * 1024),
        .@"1",
        0,
    ) catch |err| fatal.msg("reading world from stdin: {t}", .{err});

    var diag: std.zon.parse.Diagnostics = .{};
    var world = World.parse(arena, source, &diag) catch |err| switch (err) {
        error.OutOfMemory => |e| fatal.oom(e),
        error.ParseZon => fatal.msg("invalid world document:\n{f}", .{diag}),
    };
    if (world.clones.len == 0) fatal.msg("world has no clones", .{});
    const clone_index = if (clone_name) |name|
        world.cloneIndex(name) orelse fatal.msg("world has no clone named '{s}'", .{name})
    else
        0;

    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const invocation: []const []const u8 = @ptrCast(args[first..]);
    const code = simulate.run(
        io,
        init.gpa,
        arena,
        init.environ_map,
        &world,
        clone_index,
        invocation,
        &stderr_writer.interface,
        &stderr_writer.interface,
    ) catch |err| fatal.oom(err);
    stderr_writer.interface.flush() catch {};

    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    world.write(&stdout_writer.interface) catch |err| fatal.msg("writing world: {t}", .{err});
    stdout_writer.interface.flush() catch |err| fatal.msg("writing world: {t}", .{err});
    return code;
}

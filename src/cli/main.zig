//! `git-issue`: the drop-in CLI.

const std = @import("std");
const issuez = @import("issuez");
const context = @import("context.zig");
const dispatch = @import("dispatch.zig");
const fatal = @import("fatal.zig");

const GitProcess = issuez.backend.GitProcess;

var stdout_buffer: [16 * 1024]u8 = undefined;
var stderr_buffer: [4 * 1024]u8 = undefined;

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch |err| switch (err) {
        error.OutOfMemory => |e| fatal.oom(e),
        else => fatal.msg("unable to read command line arguments", .{}),
    };
    std.debug.assert(args.len >= 1);

    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);

    // Opened up front. Commands that need a repository report a failure.
    var git = GitProcess.open(io, init.gpa, .{ .path = ".", .environ_map = init.environ_map });
    defer if (git) |*g| g.close() else |_| {};

    var ctx: context.Context(GitProcess) = .{
        .io = io,
        .gpa = init.gpa,
        .arena = arena,
        .out = &stdout_writer.interface,
        .err = &stderr_writer.interface,
        .environ_map = init.environ_map,
        .backend = if (git) |*g| g else |e| e,
    };

    const rest: []const []const u8 = @ptrCast(args[1..]);
    const code = dispatch.run(GitProcess, &ctx, args[0], rest);
    stdout_writer.interface.flush() catch {};
    stderr_writer.interface.flush() catch {};
    return code;
}

test {
    _ = dispatch;
    _ = @import("simulate.zig");
    _ = @import("completion.zig");
    _ = @import("manpage.zig");
}

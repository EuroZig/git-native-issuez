//! Use the library on a real git repository through the `GitProcess`
//! backend (which drives the `git` binary on PATH).
//!
//!   zig build example-real-repo -- <repo-path> ls
//!   zig build example-real-repo -- <repo-path> create "Some title" [label...]
//!
//! Issues written here are ordinary `refs/issues/*` refs: `git issue ls`
//! (this project's CLI or upstream's) shows them too.

const std = @import("std");
const issuez = @import("issuez");

const GitProcess = issuez.backend.GitProcess;
const Repo = issuez.Repo(GitProcess);

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    const err_out = &stderr_writer.interface;
    defer err_out.flush() catch {};

    if (args.len < 3) {
        try err_out.writeAll("usage: real_repo <repo-path> ls | create <title> [label...]\n");
        return 2;
    }

    var git = GitProcess.open(init.io, init.gpa, .{
        .path = args[1],
        .environ_map = init.environ_map,
    }) catch |err| {
        try err_out.print("cannot open repository '{s}': {t}\n", .{ args[1], err });
        return 1;
    };
    defer git.close();
    const repo = Repo.init(&git);

    const command: []const u8 = args[2];
    if (std.mem.eql(u8, command, "create") and args.len >= 4) {
        const labels: []const []const u8 = @ptrCast(args[4..]);
        // The author defaults to git's configured identity. Pass `.author`
        // to commit as someone else.
        const created = repo.create(arena, .{ .title = args[3], .labels = labels }) catch |err| {
            try err_out.print("create failed: {t} {s}\n", .{ err, git.lastStderr() });
            return 1;
        };
        try out.print("Created issue {s}\n", .{created.id.short()});
    } else if (std.mem.eql(u8, command, "ls")) {
        const issues = try repo.loadAll(arena);
        // Newest first, like `git issue ls`.
        std.mem.sort(issuez.model.issue.Issue, issues, {}, struct {
            fn newer(_: void, a: issuez.model.issue.Issue, b: issuez.model.issue.Issue) bool {
                return a.created > b.created;
            }
        }.newer);
        for (issues) |issue| {
            try out.print("{s} [{s}] {s}", .{
                issuez.format.uuid.shortId(issue.id),
                issue.state.text(),
                issue.title,
            });
            if (issue.labels.len > 0) {
                try out.writeAll(" (");
                for (issue.labels, 0..) |l, i| {
                    if (i > 0) try out.writeAll(", ");
                    try out.writeAll(l);
                }
                try out.writeAll(")");
            }
            try out.writeAll("\n");
        }
    } else {
        try err_out.print("unknown command '{s}'\n", .{command});
        return 2;
    }
    return 0;
}

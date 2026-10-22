//! Quickstart: create, list, comment on, edit and close issues.
//!
//! Runs on the in-memory simulator, so it needs no git. The same `Repo`
//! API works on a real repository with `GitProcess` (see real_repo.zig).
//!
//!   zig build example-quickstart

const std = @import("std");
const issuez = @import("issuez");

const GitSim = issuez.backend.GitSim;
const Repo = issuez.Repo(GitSim);

pub fn main(init: std.process.Init) !void {
    // The library allocates everything from a caller-provided arena.
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    // Time, identity and randomness come from the world, so every run
    // produces the same IDs and commits.
    var world: GitSim.World = .{
        .identity = .{ .name = "Ada", .email = "ada@example.invalid" },
        .clones = &.{.{ .name = "local" }},
    };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo.init(&sim);

    // Create.
    const login = try repo.create(arena, .{
        .title = "Login page crashes",
        .body = "Clicking \"Sign in\" with an empty password crashes the app.",
        .labels = &.{ "bug", "ui" },
        .priority = "high",
    });
    const docs = try repo.create(arena, .{
        .title = "Document the sync protocol",
        .labels = &.{"docs"},
        .assignee = "ada@example.invalid",
    });
    try out.print("created {s} and {s}\n\n", .{ login.id.short(), docs.id.short() });

    // Look an issue up by ID prefix, as `git issue show <prefix>` does.
    const ref = switch (try repo.resolve(arena, login.id.short())) {
        .one => |r| r,
        .none, .many => unreachable,
    };

    // Comment, edit and close. Mutations take the full ref name.
    _ = try repo.comment(arena, ref.name, .{
        .text = "Reproduced on 1.4.2.\n\nStack trace attached.",
    });
    _ = try repo.edit(arena, ref.name, .{
        .add_labels = &.{"regression"},
        .remove_labels = &.{"ui"},
        .assignee = "ada@example.invalid",
    });
    _ = try repo.setState(arena, ref.name, .{ .state = "closed", .fixed_by = "abc1234" });

    // List.
    try out.writeAll("ID       STATE   TITLE\n");
    for (try repo.loadAll(arena)) |issue| {
        try out.print("{s}  {s:<6}  {s}\n", .{
            issuez.format.uuid.shortId(issue.id),
            issue.state,
            issue.title,
        });
    }

    // Show one issue in full.
    const issue = try repo.load(arena, (try repo.resolve(arena, login.id.short())).one);
    try out.print("\n{s} ({s})\n", .{ issue.title, issue.state });
    try out.writeAll("labels:");
    for (issue.labels) |l| try out.print(" {s}", .{l});
    try out.writeAll("\n");
    for (issue.fields) |f| try out.print("{s}: {s}\n", .{ f.key, f.value });
    try out.print("\n{s}\n", .{issue.description});
    for (issue.comments) |c| {
        try out.print("\n--- {s} <{s}>: {s}\n", .{ c.author.name, c.author.email, c.subject });
        for (c.text) |line| try out.print("{s}\n", .{line});
    }
}

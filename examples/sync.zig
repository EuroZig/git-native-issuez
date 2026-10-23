//! Sync between two clones through a shared remote: push, merge and
//! concurrent edits.
//!
//! On the simulator, `remote.origin.url = sim:hub` stands in for a git
//! remote. With `GitProcess` the same calls work on real remotes.
//!
//!   zig build example-sync

const std = @import("std");
const issuez = @import("issuez");

const GitSim = issuez.backend.GitSim;
const Sync = issuez.Sync(GitSim);

const origin: []const GitSim.World.ConfigEntry = &.{
    .{ .key = "remote.origin.url", .value = "sim:hub" },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    var world: GitSim.World = .{ .clones = &.{
        .{ .name = "alice", .config = origin },
        .{ .name = "bob", .config = origin },
        .{ .name = "hub" },
    } };

    // Alice files an issue and pushes it.
    var alice = try Clone.open(arena, &world, "alice");
    const created = try alice.sync.repo.create(arena, .{ .title = "Flaky CI", .labels = &.{"ci"} });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});
    const pushed = try alice.sync.push(arena, "origin");
    try out.print("alice: created {s}, pushed {d}\n", .{ created.id.short(), pushed.pushed });
    try alice.close();

    // Bob fetches and merges it.
    var bob = try Clone.open(arena, &world, "bob");
    const fetched = try bob.sync.merge(arena, "origin", .{});
    try out.print("bob: merge created {d}\n", .{fetched.count(.created)});
    try bob.close();

    // Both edit the issue without talking to each other.
    alice = try Clone.open(arena, &world, "alice");
    _ = try alice.sync.repo.edit(arena, ref_name, .{ .priority = "high" });
    try alice.close();

    bob = try Clone.open(arena, &world, "bob");
    _ = try bob.sync.repo.edit(arena, ref_name, .{ .assignee = "bob@example.invalid" });
    _ = try bob.sync.push(arena, "origin");
    try bob.close();

    // Alice's push is rejected (the hub moved), so push merges and retries.
    alice = try Clone.open(arena, &world, "alice");
    const retried = try alice.sync.push(arena, "origin");
    try out.print("alice: push needed {d} merge(s), pushed {d}\n", .{
        retried.merges.len,
        retried.pushed,
    });
    const tip = (try alice.sim.resolveRef(ref_name)).?;
    const issue = try alice.sync.repo.load(arena, .{ .name = ref_name, .tip = tip });
    try out.print("alice: priority={s} assignee={s}\n", .{
        issue.field("Priority").?,
        issue.field("Assignee").?,
    });
    try alice.close();

    // Bob fast-forwards to the merged result.
    bob = try Clone.open(arena, &world, "bob");
    const ff = try bob.sync.merge(arena, "origin", .{});
    try out.print("bob: fast-forwarded {d}\n", .{ff.count(.fast_forwarded)});
    try bob.close();
}

/// A working copy of one clone of the world. `close` writes it back so the
/// other clones see it.
const Clone = struct {
    sim: *GitSim,
    sync: Sync,

    fn open(arena: std.mem.Allocator, world: *GitSim.World, name: []const u8) !Clone {
        const sim = try arena.create(GitSim);
        sim.* = try GitSim.init(arena, world, world.cloneIndex(name).?);
        return .{ .sim = sim, .sync = Sync.init(sim) };
    }

    fn close(clone: *Clone) !void {
        try clone.sim.commit();
    }
};

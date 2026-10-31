//! Attachments: write an issue with images and read them back.
//!
//! The API works on bytes: the caller reads files itself and gets bytes
//! back, or the reason there are none. With `GitProcess` the bytes are
//! stored under `.git/issuez/lfs/objects/` (see docs/attachments.md).
//!
//!   zig build example-attachments

const std = @import("std");
const issuez = @import("issuez");

const GitSim = issuez.backend.GitSim;
const Repo = issuez.Repo(GitSim);
const Attachments = issuez.Attachments(GitSim);

/// A 1x1 PNG, standing in for a screenshot read from disk.
const screenshot = issuez.format.attachment.samples.png;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    var world: GitSim.World = .{
        .identity = .{ .name = "Ada", .email = "ada@example.invalid" },
        .clones = &.{.{ .name = "local" }},
    };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo.init(&sim);
    const att = Attachments.fromRepo(repo);

    const created = try repo.create(arena, .{ .title = "Login button is cut off" });
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});

    // Check a file before accepting it.
    const input: Attachments.Input = .{ .name = "/home/ada/login.png", .data = screenshot };
    const media = try att.validate(input);
    try out.print("accepted: {s}\n", .{media.mediaType()});

    // Each rejection is its own error.
    if (att.validate(.{ .name = "notes.txt", .data = "not an image" })) |_| {} else |e| {
        try out.print("rejected: {t}\n", .{e});
    }

    // One commit: the comment text and the image arrive together.
    const added = try att.add(arena, ref, .{
        .files = &.{input},
        .comment = "Here's what it looks like on a small screen.",
    });
    try out.print("attached {s}\n\n", .{added.ids[0][0..8]});

    const issue = try repo.load(arena, .{ .name = ref, .tip = added.tip });

    // All present attachments of the issue...
    for (issue.attachments) |a| {
        try out.print("{s}  {s}  {d} bytes  {s}\n", .{
            a.id[0..8], a.media.mediaType(), a.size, a.name,
        });
        // ...and their bytes, verified against the hash in the history.
        switch (try att.read(arena, a)) {
            .bytes => |b| try out.print("  read {d} bytes, same as written: {}\n", .{
                b.len, std.mem.eql(u8, b, screenshot),
            }),
            .missing => try out.writeAll("  not in this clone yet (fetch with git lfs)\n"),
            .corrupt => try out.writeAll("  stored bytes are damaged\n"),
        }
    }

    // Each comment lists the attachments it added, to show them inline.
    for (issue.comments) |c| {
        try out.print("\ncomment: {s}\n", .{c.subject});
        for (c.attachments) |id| try out.print("  [image {s}]\n", .{id[0..8]});
    }

    // Rename and remove are ordinary commits too.
    _ = try att.rename(arena, ref, added.ids[0], "login-small-screen.png", .{});
    _ = try att.remove(arena, ref, &.{added.ids[0]}, .{});
    const after = try repo.load(arena, .{ .name = ref, .tip = (try sim.resolveRef(ref)).? });
    try out.print("\nafter removal: {d} present, {d} removed\n", .{
        after.attachments.len, after.removed_attachments.len,
    });
}

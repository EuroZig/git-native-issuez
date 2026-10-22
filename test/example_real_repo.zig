//! Runs examples/real_repo.zig (built by `zig build`, path passed in through
//! the `paths` options module) against a fresh git repository in a temporary
//! directory, and checks the result through the library as well.

const std = @import("std");
const testing = std.testing;
const issuez = @import("issuez");
const paths = @import("paths");
const Sandbox = @import("sandbox.zig");
const GitProcess = issuez.backend.GitProcess;

const io = testing.io;
const expectSuccess = Sandbox.expectSuccess;

fn example(sb: *Sandbox, args: []const []const u8) !Sandbox.Output {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(sb.arena(), sb.repo);
    try argv.appendSlice(sb.arena(), args);
    return sb.tool(paths.example_exe, argv.items);
}

test "real-repo example" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    const arena = sb.arena();

    const empty = try example(&sb, &.{"ls"});
    try expectSuccess(empty);
    try testing.expectEqualStrings("", empty.stdout);

    const first = try example(&sb, &.{ "create", "Login page crashes", "bug", "ui" });
    try expectSuccess(first);
    try testing.expect(std.mem.startsWith(u8, first.stdout, "Created issue "));
    const id = std.mem.trimEnd(u8, first.stdout["Created issue ".len..], "\n");
    try testing.expectEqual(@as(usize, 7), id.len);

    try expectSuccess(try example(&sb, &.{ "create", "Write docs" }));

    const listed = try example(&sb, &.{"ls"});
    try expectSuccess(listed);
    const login_line = try std.fmt.allocPrint(
        arena,
        "{s} [open] Login page crashes (bug, ui)\n",
        .{id},
    );
    try testing.expect(std.mem.find(u8, listed.stdout, login_line) != null);
    try testing.expect(std.mem.find(u8, listed.stdout, "[open] Write docs\n") != null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, listed.stdout, "\n"));

    // What the example wrote is a regular issue, with git's identity.
    var git = try GitProcess.open(io, testing.allocator, .{
        .path = sb.repo,
        .environ_map = &sb.env,
    });
    defer git.close();
    const repo = issuez.Repo(GitProcess).init(&git);
    const issue = try repo.load(arena, (try repo.resolve(arena, id)).one);
    try testing.expectEqualStrings("Login page crashes", issue.title);
    try testing.expectEqualStrings(Sandbox.identity_name, issue.author.name);
    try testing.expectEqual(@as(usize, 2), (try repo.refs(arena)).len);
}

test "real-repo example: usage and repository errors" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();

    const usage = try sb.tool(paths.example_exe, &.{});
    try testing.expectEqual(@as(u8, 2), usage.code);
    try testing.expect(std.mem.startsWith(u8, usage.stderr, "usage: "));

    const unknown = try example(&sb, &.{"frobnicate"});
    try testing.expectEqual(@as(u8, 2), unknown.code);

    const missing = try sb.tool(paths.example_exe, &.{ "/nonexistent/repo", "ls" });
    try testing.expectEqual(@as(u8, 1), missing.code);
    try testing.expect(std.mem.startsWith(u8, missing.stderr, "cannot open repository"));
}

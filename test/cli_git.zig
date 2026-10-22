//! `git-issue` against real git in a temporary repository, for behaviour the
//! simulator can't show (git's identity rules, git config, the environment).
//! The binary's path comes in through the `paths` options module.

const std = @import("std");
const testing = std.testing;
const paths = @import("paths");
const Sandbox = @import("sandbox.zig");

const expectSuccess = Sandbox.expectSuccess;

fn gitIssue(sb: *Sandbox, args: []const []const u8) !Sandbox.Output {
    return sb.tool(paths.git_issue_exe, args);
}

fn expectFailure(out: Sandbox.Output, code: u8, stderr: []const u8) !void {
    testing.expectEqual(code, out.code) catch |err| {
        std.debug.print("stderr: {s}\n", .{out.stderr});
        return err;
    };
    try testing.expectEqualStrings(stderr, out.stderr);
}

test "missing identity" {
    var sb = try Sandbox.init(.{ .identity = false });
    defer sb.deinit();

    // git would otherwise invent an identity from the login and hostname.
    try expectFailure(try gitIssue(&sb, &.{ "create", "No identity" }), 128,
        \\fatal: user.name not set
        \\       run: git config user.name "Your Name"
        \\
    );
    try sb.git(&.{ "config", "user.name", "Only Name" });
    try expectFailure(try gitIssue(&sb, &.{ "create", "No email" }), 128,
        \\fatal: user.email not set
        \\       run: git config user.email "you@example.com"
        \\
    );
    try sb.git(&.{ "config", "user.email", "only@example.invalid" });
    try expectSuccess(try gitIssue(&sb, &.{ "create", "Now it works" }));
}

test "identity from the environment needs no config" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    const created = try gitIssue(&sb, &.{ "create", "From env" });
    try expectSuccess(created);
    const id = std.mem.trimEnd(u8, created.stdout["Created issue ".len..], "\n");
    const shown = try gitIssue(&sb, &.{ "show", id });
    try expectSuccess(shown);
    try testing.expect(std.mem.find(
        u8,
        shown.stdout,
        "Author:  " ++ Sandbox.identity_name ++ " <" ++ Sandbox.identity_email ++ ">",
    ) != null);
}

test "init remotes" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();

    const none = try gitIssue(&sb, &.{"init"});
    try expectSuccess(none);
    const manual = "git push <remote> 'refs/issues/*'";
    try testing.expect(std.mem.find(u8, none.stderr, manual) != null);

    try sb.git(&.{ "remote", "add", "origin", "/nonexistent/origin" });
    try sb.git(&.{ "remote", "add", "upstream", "/nonexistent/upstream" });
    try expectFailure(try gitIssue(&sb, &.{ "init", "origin", "upstream" }), 1,
        \\error: only one remote can be given
        \\Run 'git issue init --help' for usage.
        \\
    );
}

test "parallel writers" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    const arena = sb.arena();
    const io = testing.io;
    const created = try gitIssue(&sb, &.{ "create", "Contended" });
    try expectSuccess(created);
    const id = std.mem.trimEnd(u8, created.stdout["Created issue ".len..], "\n");

    // Four commenters and four label adders, all at once.
    const writers = 8;
    var children: [writers]std.process.Child = undefined;
    var spawned: usize = 0;
    defer for (children[0..spawned]) |*c| c.kill(io);
    for (0..writers) |i| {
        const exe = paths.git_issue_exe;
        const argv: []const []const u8 = if (i % 2 == 0)
            &.{ exe, "comment", id, "-m", try std.fmt.allocPrint(arena, "note {d}", .{i}) }
        else
            &.{ exe, "edit", id, "--add-label", try std.fmt.allocPrint(arena, "l{d}", .{i}) };
        children[i] = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = .{ .path = sb.repo },
            .environ_map = &sb.env,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        spawned += 1;
    }
    var ok: [writers]bool = undefined;
    for (&children, &ok) |*c, *o| {
        const term = try c.wait(io);
        o.* = term == .exited and term.exited == 0;
    }
    spawned = 0;

    const shown = try gitIssue(&sb, &.{ "show", id });
    try expectSuccess(shown);
    var successes: usize = 0;
    for (ok, 0..) |o, i| {
        if (!o) continue; // gave up after its CAS retries: allowed, reported
        successes += 1;
        const needle = if (i % 2 == 0)
            try std.fmt.allocPrint(arena, "note {d}", .{i})
        else
            try std.fmt.allocPrint(arena, "l{d}", .{i});
        testing.expect(std.mem.find(u8, shown.stdout, needle) != null) catch |err| {
            std.debug.print("lost update from writer {d}:\n{s}\n", .{ i, shown.stdout });
            return err;
        };
    }
    try testing.expect(successes > 0);
    try expectSuccess(try gitIssue(&sb, &.{"fsck"}));
}

test "sha256 and reftable" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    const arena = sb.arena();
    const version = try sb.run(&.{ "git", "version" });
    const kinds = [_][]const u8{ "--object-format=sha256", "--ref-format=reftable" };
    for (kinds) |flag| {
        const reftable = std.mem.eql(u8, flag, "--ref-format=reftable");
        if (reftable and !atLeast(version.stdout, 2, 45)) continue;
        const repo = try std.fmt.allocPrint(arena, "{s}{s}", .{ sb.repo, flag[2..10] });
        try sb.git(&.{ "init", "-q", flag, repo });
        const run = struct {
            fn f(s: *Sandbox, dir: []const u8, args: []const []const u8) !Sandbox.Output {
                var argv: std.ArrayList([]const u8) = .empty;
                try argv.append(s.arena(), paths.git_issue_exe);
                try argv.appendSlice(s.arena(), args);
                return s.runIn(dir, argv.items);
            }
        }.f;
        const created = try run(&sb, repo, &.{ "create", "Formats", "-l", "bug" });
        try expectSuccess(created);
        const id = std.mem.trimEnd(u8, created.stdout["Created issue ".len..], "\n");
        try expectSuccess(try run(&sb, repo, &.{ "comment", id, "-m", "hello" }));
        try expectSuccess(try run(&sb, repo, &.{ "state", id, "--close" }));
        const listed = try run(&sb, repo, &.{ "ls", "--all" });
        try testing.expect(std.mem.find(u8, listed.stdout, "[closed] Formats") != null);
        try expectSuccess(try run(&sb, repo, &.{"fsck"}));
    }
}

fn atLeast(git_version_output: []const u8, major: u32, minor: u32) bool {
    var it = std.mem.tokenizeAny(u8, git_version_output, " .\n");
    _ = it.next(); // git
    _ = it.next(); // version
    const ma = std.fmt.parseInt(u32, it.next() orelse return false, 10) catch return false;
    const mi = std.fmt.parseInt(u32, it.next() orelse return false, 10) catch return false;
    return ma > major or (ma == major and mi >= minor);
}

/// The trimmed stdout of a command that must succeed.
fn output(sb: *Sandbox, argv: []const []const u8) ![]const u8 {
    const out = try sb.run(argv);
    try expectSuccess(out);
    return std.mem.trimEnd(u8, out.stdout, "\n");
}

test "ls --conflicts" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();

    // Two edits on top of the same commit, joined by a merge commit, like
    // two clones that both changed the priority.
    const created = try gitIssue(&sb, &.{ "create", "Contested", "-p", "low" });
    const id = std.mem.trimEnd(u8, created.stdout["Created issue ".len..], "\n");
    const name = try output(&sb, &.{ "git", "for-each-ref", "--format=%(refname)", "refs/issues/" });
    const root = try output(&sb, &.{ "git", "rev-parse", name });
    try expectSuccess(try gitIssue(&sb, &.{ "edit", id, "-p", "high" }));
    const high = try output(&sb, &.{ "git", "rev-parse", name });
    try sb.git(&.{ "update-ref", name, root, high });
    try expectSuccess(try gitIssue(&sb, &.{ "edit", id, "-p", "critical" }));
    const critical = try output(&sb, &.{ "git", "rev-parse", name });
    const empty_tree = try output(&sb, &.{ "git", "hash-object", "-t", "tree", "/dev/null" });
    const merge = try output(&sb, &.{
        "git", "commit-tree", empty_tree, "-p", high, "-p", critical, "-m", "Merge issue",
    });
    try sb.git(&.{ "update-ref", name, merge, critical });

    const listed = try gitIssue(&sb, &.{ "ls", "--conflicts" });
    try expectSuccess(listed);
    try testing.expect(std.mem.startsWith(u8, listed.stdout, id));
    const line = "       conflict: Priority kept '";
    try testing.expect(std.mem.find(u8, listed.stdout, line) != null);
    const none = try gitIssue(&sb, &.{ "ls", "--conflicts", "-s", "closed" });
    try testing.expectEqualStrings("", none.stdout);
}

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
    try testing.expect(std.mem.find(u8, none.stderr, "git issue sync <remote>") != null);
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

test "quarantine" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    const arena = sb.arena();
    const hub = try std.fmt.allocPrint(arena, "{s}-hub.git", .{sb.repo});
    const bob = try std.fmt.allocPrint(arena, "{s}-bob", .{sb.repo});
    try sb.git(&.{ "init", "-q", "--bare", hub });
    try sb.git(&.{ "init", "-q", bob });
    try sb.git(&.{ "remote", "add", "origin", hub });
    try expectSuccess(try sb.runIn(bob, &.{ "git", "remote", "add", "origin", hub }));
    const inBob = struct {
        fn run(s: *Sandbox, dir: []const u8, args: []const []const u8) !Sandbox.Output {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(s.arena(), try s.exe(paths.git_issue_exe));
            try argv.appendSlice(s.arena(), args);
            return s.runIn(dir, argv.items);
        }
    }.run;

    // Alice's issue reaches the hub.
    try expectSuccess(try gitIssue(&sb, &.{ "create", "Alice's" }));
    try expectSuccess(try gitIssue(&sb, &.{ "push", "origin" }));
    const list = [_][]const u8{
        "git", "for-each-ref", "--format=%(refname) %(objectname)", "refs/issues/",
    };
    const refs = try sb.run(&list);
    var parts = std.mem.tokenizeAny(u8, refs.stdout, " \n");
    const ref_name = parts.next().?;
    const alice_tip = parts.next().?;
    const short = ref_name["refs/issues/".len..][0..7];

    // Bob has an unrelated issue under the same ID.
    try expectSuccess(try inBob(&sb, bob, &.{ "create", "Bob's" }));
    const own = try sb.runIn(bob, &list);
    var own_parts = std.mem.tokenizeAny(u8, own.stdout, " \n");
    const own_ref = own_parts.next().?;
    const bob_tip = own_parts.next().?;
    try expectSuccess(try sb.runIn(bob, &.{ "git", "update-ref", ref_name, bob_tip }));
    try expectSuccess(try sb.runIn(bob, &.{ "git", "update-ref", "-d", own_ref }));

    const merged = try inBob(&sb, bob, &.{ "merge", "origin" });
    try expectSuccess(merged);
    try testing.expect(std.mem.find(u8, merged.stderr, "Quarantined ") != null);
    try testing.expect(std.mem.find(u8, merged.stderr, "git issue status") != null);

    const status = try inBob(&sb, bob, &.{"status"});
    try expectSuccess(status);
    try testing.expect(std.mem.find(u8, status.stdout, "quarantined: 1") != null);
    try testing.expect(std.mem.find(u8, status.stdout, "unrelated history") != null);
    const hint = try std.fmt.allocPrint(arena, "--accept-remote {s}", .{short});
    try testing.expect(std.mem.find(u8, status.stdout, hint) != null);

    const fsck = try inBob(&sb, bob, &.{"fsck"});
    try expectSuccess(fsck); // a sync state, not an error
    try testing.expect(std.mem.find(u8, fsck.stderr, "note: 1 issue(s) quarantined") != null);

    // Keep local: still unpushed, but merges stop warning.
    try expectSuccess(try inBob(&sb, bob, &.{ "quarantine", "origin", "--keep-local", short }));
    const quiet = try inBob(&sb, bob, &.{ "merge", "origin" });
    try expectSuccess(quiet);
    try testing.expect(std.mem.find(u8, quiet.stderr, "Quarantined") == null);
    try testing.expect(std.mem.find(
        u8,
        (try inBob(&sb, bob, &.{"status"})).stdout,
        "; kept local",
    ) != null);

    // Accept remote: Alice's version, Bob's kept in a ref.
    try expectSuccess(try inBob(
        &sb,
        bob,
        &.{ "quarantine", "origin", "--accept-remote", short },
    ));
    const now = try sb.runIn(bob, &.{ "git", "rev-parse", ref_name });
    try testing.expectEqualStrings(alice_tip, std.mem.trimEnd(u8, now.stdout, "\n"));
    const backup = try std.fmt.allocPrint(
        arena,
        "refs/issuez-sync/origin/replaced/issues/{s}/{s}",
        .{ ref_name["refs/issues/".len..], bob_tip },
    );
    const kept = try sb.runIn(bob, &.{ "git", "rev-parse", backup });
    try testing.expectEqualStrings(bob_tip, std.mem.trimEnd(u8, kept.stdout, "\n"));
    try testing.expect(std.mem.find(
        u8,
        (try inBob(&sb, bob, &.{"status"})).stdout,
        "in sync",
    ) != null);

    const again = try inBob(&sb, bob, &.{ "quarantine", "origin", "--keep-local", short });
    try testing.expectEqual(@as(u8, 1), again.code);
}

test "upstream's fetch refspec doesn't reset unpushed changes" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    const arena = sb.arena();
    const hub = try std.fmt.allocPrint(arena, "{s}-hub.git", .{sb.repo});
    try sb.git(&.{ "init", "-q", "--bare", hub });
    try sb.git(&.{ "remote", "add", "origin", hub });
    const created = try gitIssue(&sb, &.{ "create", "Shared" });
    try expectSuccess(created);
    const id = std.mem.trimEnd(u8, created.stdout["Created issue ".len..], "\n");
    try expectSuccess(try gitIssue(&sb, &.{ "push", "origin" }));

    // What upstream's `git issue init` writes. A fetch through it would
    // reset the issue to the hub's version.
    try sb.git(&.{ "config", "--add", "remote.origin.fetch", "+refs/issues/*:refs/issues/*" });
    try expectSuccess(try gitIssue(&sb, &.{ "comment", id, "-m", "Not pushed yet" }));
    const tips = [_][]const u8{ "git", "for-each-ref", "--format=%(objectname)", "refs/issues/" };
    const local = (try sb.run(&tips)).stdout;

    try expectSuccess(try gitIssue(&sb, &.{ "merge", "origin" }));
    try testing.expectEqualStrings(local, (try sb.run(&tips)).stdout);
    try expectSuccess(try gitIssue(&sb, &.{ "sync", "origin" }));
    try testing.expectEqualStrings(local, (try sb.run(&tips)).stdout);
    const on_hub = try sb.run(&.{
        "git", "--git-dir", hub, "for-each-ref", "--format=%(objectname)", "refs/issues/",
    });
    try testing.expectEqualStrings(local, on_hub.stdout);
}

test "remote branches named issues/ are not issues" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    const arena = sb.arena();
    const hub = try std.fmt.allocPrint(arena, "{s}-hub.git", .{sb.repo});
    try sb.git(&.{ "init", "-q", "--bare", hub });
    try sb.git(&.{ "remote", "add", "origin", hub });
    try sb.git(&.{ "commit", "-q", "--allow-empty", "-m", "Fix login" });
    try sb.git(&.{ "push", "-q", "origin", "HEAD:refs/heads/issues/123-fix-login" });
    // The default refspec tracks it as refs/remotes/origin/issues/123-fix-login.
    try sb.git(&.{ "fetch", "-q", "origin" });
    try expectSuccess(try gitIssue(&sb, &.{ "create", "Shared" }));

    const synced = try gitIssue(&sb, &.{ "sync", "origin" });
    try expectSuccess(synced);
    try testing.expect(std.mem.find(u8, synced.stdout, "uarantine") == null);
    try testing.expect(std.mem.find(u8, synced.stderr, "uarantine") == null);
    const branch = "refs/remotes/origin/issues/123-fix-login";
    try expectSuccess(try sb.run(&.{ "git", "rev-parse", "--verify", "-q", branch }));
}

test "a push the remote refuses" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    const arena = sb.arena();
    const hub = try std.fmt.allocPrint(arena, "{s}-hub.git", .{sb.repo});
    try sb.git(&.{ "init", "-q", "--bare", hub });
    try sb.git(&.{ "remote", "add", "origin", hub });
    const hook = try std.fmt.allocPrint(arena, "{s}/hooks/pre-receive", .{hub});
    try expectSuccess(try sb.run(&.{
        "sh", "-c", "printf '#!/bin/sh\\necho no issues here >&2\\nexit 1\\n' > \"$1\" && chmod +x \"$1\"",
        "sh", hook,
    }));
    try expectSuccess(try gitIssue(&sb, &.{ "create", "Refused" }));

    // No retry rounds: the reason comes straight from the remote.
    const pushed = try gitIssue(&sb, &.{ "push", "origin" });
    try testing.expectEqual(@as(u8, 1), pushed.code);
    try testing.expect(std.mem.startsWith(u8, pushed.stderr, "error: failed to push issues to 'origin'\n"));
    try testing.expect(std.mem.find(u8, pushed.stderr, "no issues here") != null);
}

test "one remote per merge, push and sync" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    for ([_][]const u8{ "merge", "push", "sync" }) |verb| {
        const out = try gitIssue(&sb, &.{ verb, "origin", "upstream" });
        const want = try std.fmt.allocPrint(
            sb.arena(),
            "error: unexpected argument\nRun 'git issue {s} --help' for usage.\n",
            .{verb},
        );
        try expectFailure(out, 1, want);
    }
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
        const exe = try sb.exe(paths.git_issue_exe);
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
        const hub = try std.fmt.allocPrint(arena, "{s}-hub.git", .{repo});
        try sb.git(&.{ "init", "-q", flag, repo });
        try sb.git(&.{ "init", "-q", "--bare", flag, hub });
        try expectSuccess(try sb.runIn(repo, &.{ "git", "remote", "add", "origin", hub }));
        const run = struct {
            fn f(s: *Sandbox, dir: []const u8, args: []const []const u8) !Sandbox.Output {
                var argv: std.ArrayList([]const u8) = .empty;
                try argv.append(s.arena(), try s.exe(paths.git_issue_exe));
                try argv.appendSlice(s.arena(), args);
                return s.runIn(dir, argv.items);
            }
        }.f;
        const created = try run(&sb, repo, &.{ "create", "Formats", "-l", "bug" });
        try expectSuccess(created);
        const id = std.mem.trimEnd(u8, created.stdout["Created issue ".len..], "\n");
        try expectSuccess(try run(&sb, repo, &.{ "comment", id, "-m", "hello" }));
        try expectSuccess(try run(&sb, repo, &.{ "state", id, "--close" }));
        try expectSuccess(try run(&sb, repo, &.{ "sync", "origin" }));
        const listed = try run(&sb, repo, &.{ "ls", "--all" });
        try testing.expect(std.mem.find(u8, listed.stdout, "[closed] Formats") != null);
        try expectSuccess(try run(&sb, repo, &.{"fsck"}));
        const on_hub = try sb.runIn(
            repo,
            &.{ "git", "--git-dir", hub, "for-each-ref", "refs/issues/" },
        );
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, on_hub.stdout, "\n"));
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

fn have(sb: *Sandbox, tool: []const u8) bool {
    const out = sb.run(&.{ "sh", "-c", std.fmt.allocPrint(
        sb.arena(),
        "command -v {s}",
        .{tool},
    ) catch return false }) catch return false;
    return out.code == 0;
}

test "tree and problems" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    const idOf = struct {
        fn f(out: Sandbox.Output) []const u8 {
            return std.mem.trimEnd(u8, out.stdout["Created issue ".len..], "\n");
        }
    }.f;
    // Distinct creation times: siblings are ordered by them.
    const at = struct {
        fn set(s: *Sandbox, t: []const u8) !void {
            try s.env.put("GIT_AUTHOR_DATE", t);
            try s.env.put("GIT_COMMITTER_DATE", t);
        }
    }.set;
    try at(&sb, "1700000001 +0000");
    const epic = idOf(try gitIssue(&sb, &.{ "create", "Epic" }));
    try at(&sb, "1700000002 +0000");
    const blocker = idOf(try gitIssue(&sb, &.{ "create", "Blocker" }));
    try at(&sb, "1700000003 +0000");
    const a = idOf(try gitIssue(
        &sb,
        &.{ "create", "Task A", "--parent", epic, "--blocked-by", blocker },
    ));
    try at(&sb, "1700000004 +0000");
    const b = idOf(try gitIssue(&sb, &.{ "create", "Task B", "--parent", epic }));
    try expectSuccess(try gitIssue(&sb, &.{ "state", b, "--close" }));

    // Closed issues without open descendants show with --all only. Progress
    // counts them either way.
    const tree = try gitIssue(&sb, &.{"tree"});
    try expectSuccess(tree);
    const want = try std.fmt.allocPrint(sb.arena(),
        \\{s} [open] Epic  (1/2 done)
        \\└── {s} [open] Task A  [blocked by {s}]
        \\{s} [open] Blocker
        \\
    , .{ epic, a, blocker, blocker });
    try testing.expectEqualStrings(want, tree.stdout);
    const full = try gitIssue(&sb, &.{ "tree", "--all" });
    const want_all = try std.fmt.allocPrint(sb.arena(),
        \\{s} [open] Epic  (1/2 done)
        \\├── {s} [open] Task A  [blocked by {s}]
        \\└── {s} [closed] Task B
        \\{s} [open] Blocker
        \\
    , .{ epic, a, blocker, b, blocker });
    try testing.expectEqualStrings(want_all, full.stdout);

    // Another writer adds an issue whose parent isn't here.
    const tip = try sb.run(&.{
        "sh", "-c",
        "printf 'Orphan\\n\\nState: open\\nX-Parent: 0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f\\n" ++
            "Format-Version: 1\\n' | git commit-tree $(git hash-object -t tree /dev/null)",
    });
    try expectSuccess(tip);
    const orphan_ref = "refs/issues/1e1e1e1e-1e1e-4e1e-8e1e-1e1e1e1e1e1e";
    try sb.git(&.{ "update-ref", orphan_ref, std.mem.trimEnd(u8, tip.stdout, "\n") });

    const problems = try gitIssue(&sb, &.{ "ls", "--problems" });
    try expectSuccess(problems);
    try testing.expectEqualStrings(
        "1e1e1e1 [open] Orphan\n       problem: parent not found (0f0f0f0)\n",
        problems.stdout,
    );
    const fsck = try gitIssue(&sb, &.{"fsck"});
    try expectSuccess(fsck); // noted, not an error
    try testing.expect(std.mem.find(u8, fsck.stderr, "note: 1e1e1e1: parent not found") != null);
}

test "ls --conflicts" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    const arena = sb.arena();
    const hub = try std.fmt.allocPrint(arena, "{s}-hub.git", .{sb.repo});
    const other = try std.fmt.allocPrint(arena, "{s}-other", .{sb.repo});
    try sb.git(&.{ "init", "-q", "--bare", hub });
    try sb.git(&.{ "init", "-q", other });
    try sb.git(&.{ "remote", "add", "origin", hub });
    try expectSuccess(try sb.runIn(other, &.{ "git", "remote", "add", "origin", hub }));
    const inOther = struct {
        fn run(s: *Sandbox, dir: []const u8, args: []const []const u8) !Sandbox.Output {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(s.arena(), try s.exe(paths.git_issue_exe));
            try argv.appendSlice(s.arena(), args);
            return s.runIn(dir, argv.items);
        }
    }.run;

    const created = try gitIssue(&sb, &.{ "create", "Contested", "-p", "low" });
    const id = std.mem.trimEnd(u8, created.stdout["Created issue ".len..], "\n");
    try expectSuccess(try gitIssue(&sb, &.{ "sync", "origin" }));
    try expectSuccess(try inOther(&sb, other, &.{ "sync", "origin" }));
    try expectSuccess(try inOther(&sb, other, &.{ "edit", id, "-p", "high" }));
    try expectSuccess(try inOther(&sb, other, &.{ "sync", "origin" }));
    try expectSuccess(try gitIssue(&sb, &.{ "edit", id, "-p", "critical" }));
    try expectSuccess(try gitIssue(&sb, &.{ "sync", "origin" }));

    const listed = try gitIssue(&sb, &.{ "ls", "--conflicts" });
    try expectSuccess(listed);
    try testing.expect(std.mem.startsWith(u8, listed.stdout, id));
    const line = "       conflict: Priority kept '";
    try testing.expect(std.mem.find(u8, listed.stdout, line) != null);
    const none = try gitIssue(&sb, &.{ "ls", "--conflicts", "-s", "closed" });
    try testing.expectEqualStrings("", none.stdout);
}

test "lifecycle commands" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    const idOf = struct {
        fn f(out: Sandbox.Output) []const u8 {
            return std.mem.trimEnd(u8, out.stdout["Created issue ".len..], "\n");
        }
    }.f;
    const top = idOf(try gitIssue(&sb, &.{ "create", "Top" }));
    const mid = idOf(try gitIssue(&sb, &.{ "create", "Mid", "--parent", top }));
    const leaf = idOf(try gitIssue(&sb, &.{ "create", "Leaf", "--parent", mid }));

    try expectSuccess(try gitIssue(&sb, &.{ "close", leaf, "--reason", "completed" }));
    try expectSuccess(try gitIssue(&sb, &.{ "reopen", leaf }));
    try expectSuccess(try gitIssue(&sb, &.{ "comment", leaf, "-m", "Tpyo" }));
    // The comment is the leaf's tip right now. --ids shows its ID.
    const pattern = try std.fmt.allocPrint(sb.arena(), "refs/issues/{s}*", .{leaf});
    const tip = try sb.run(&.{ "git", "for-each-ref", "--format=%(objectname)", pattern });
    const cid = tip.stdout[0..7];
    const ids = try gitIssue(&sb, &.{ "show", leaf, "--ids" });
    try testing.expect(std.mem.find(u8, ids.stdout, cid) != null);
    try expectSuccess(try gitIssue(&sb, &.{ "comment", leaf, "--edit", cid, "-m", "Typo fixed" }));
    var shown = try gitIssue(&sb, &.{ "show", leaf });
    try testing.expect(std.mem.find(u8, shown.stdout, "(edited):\n  Typo fixed") != null);
    try expectSuccess(try gitIssue(&sb, &.{ "comment", leaf, "--delete", cid }));
    shown = try gitIssue(&sb, &.{ "show", leaf });
    try testing.expect(std.mem.find(u8, shown.stdout, "Typo fixed") == null);

    const refused = try gitIssue(&sb, &.{ "delete", mid });
    try testing.expectEqual(@as(u8, 1), refused.code);
    const why = "sub-issues that aren't deleted";
    try testing.expect(std.mem.find(u8, refused.stderr, why) != null);
    try expectSuccess(try gitIssue(&sb, &.{ "delete", leaf }));
    try expectSuccess(try gitIssue(&sb, &.{ "delete", mid }));
    const listed = try gitIssue(&sb, &.{ "ls", "-f", "oneline" });
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, listed.stdout, "\n"));
    const gone = try gitIssue(&sb, &.{ "ls", "--deleted", "-f", "oneline" });
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, gone.stdout, "\n"));
    // Restoring the leaf under its deleted parent is allowed and reported.
    try expectSuccess(try gitIssue(&sb, &.{ "restore", leaf }));
    const tree = try gitIssue(&sb, &.{"tree"});
    try testing.expect(std.mem.find(u8, tree.stdout, "Leaf") != null); // lifted to Top
    try testing.expect(std.mem.find(u8, tree.stdout, "Mid") == null);
    const problems = try gitIssue(&sb, &.{ "ls", "--problems" });
    try testing.expect(std.mem.find(u8, problems.stdout, "parent is deleted") != null);
}

test "milestone commands and sync" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    const arena = sb.arena();
    const hub = try std.fmt.allocPrint(arena, "{s}-hub.git", .{sb.repo});
    const other = try std.fmt.allocPrint(arena, "{s}-other", .{sb.repo});
    try sb.git(&.{ "init", "-q", "--bare", hub });
    try sb.git(&.{ "init", "-q", other });
    try sb.git(&.{ "remote", "add", "origin", hub });
    try expectSuccess(try sb.runIn(other, &.{ "git", "remote", "add", "origin", hub }));
    const inOther = struct {
        fn run(s: *Sandbox, dir: []const u8, args: []const []const u8) !Sandbox.Output {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(s.arena(), try s.exe(paths.git_issue_exe));
            try argv.appendSlice(s.arena(), args);
            return s.runIn(dir, argv.items);
        }
    }.run;

    const create = [_][]const u8{ "milestone", "create", "v1.0", "--due", "2026-12-01" };
    const created = try gitIssue(&sb, &create);
    try expectSuccess(created);
    try testing.expect(std.mem.startsWith(u8, created.stdout, "Created milestone "));
    try expectSuccess(try gitIssue(&sb, &.{ "init", "origin" }));
    const fetch = try sb.run(&.{ "git", "config", "--get-all", "remote.origin.fetch" });
    const spec = "+refs/milestones/*:refs/remotes/origin/milestones/*";
    try testing.expect(std.mem.find(u8, fetch.stdout, spec) != null);
    try expectSuccess(try gitIssue(&sb, &.{ "sync", "origin" }));

    // The other clone gets it, completes it, pushes it back.
    const merged = try inOther(&sb, other, &.{ "sync", "origin" });
    try expectSuccess(merged);
    try testing.expect(std.mem.find(u8, merged.stdout, "Created milestone ") != null);
    try expectSuccess(try inOther(&sb, other, &.{ "milestone", "complete", "v1.0" }));
    try expectSuccess(try inOther(&sb, other, &.{ "sync", "origin" }));
    try expectSuccess(try gitIssue(&sb, &.{ "sync", "origin" }));

    const ls = try gitIssue(&sb, &.{ "milestone", "ls", "--all" });
    const line = "[completed] v1.0  (due 2026-12-01)";
    try testing.expect(std.mem.find(u8, ls.stdout, line) != null);
    const open = try gitIssue(&sb, &.{ "milestone", "ls" });
    try testing.expectEqualStrings("", open.stdout);
}

test "issues in milestones" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    const created = struct {
        fn id(out: Sandbox.Output) ![]const u8 {
            try expectSuccess(out);
            return std.mem.trimEnd(u8, out.stdout["Created issue ".len..], "\n");
        }
    }.id;
    try expectSuccess(try gitIssue(&sb, &.{ "milestone", "create", "v1" }));
    const epic = try created(try gitIssue(&sb, &.{ "create", "Epic", "--milestone", "v1" }));
    const task = try created(try gitIssue(&sb, &.{ "create", "Task", "--parent", epic }));

    // By name: the catalog ID is written next to the readable name.
    const log = try sb.run(&.{ "git", "log", "--all", "--format=%B" });
    try testing.expect(std.mem.find(u8, log.stdout, "Milestone: v1\n") != null);
    try testing.expect(std.mem.find(u8, log.stdout, "X-Milestone-Mode: explicit\n") != null);

    const show = try gitIssue(&sb, &.{ "milestone", "show", "v1" });
    try expectSuccess(show);
    try testing.expect(std.mem.find(u8, show.stdout, "Progress: 0/1 done\n") != null);
    try testing.expect(std.mem.find(u8, show.stdout, "Issues (2):\n") != null);

    try expectFailure(
        try gitIssue(&sb, &.{ "milestone", "complete", "v1" }),
        1,
        "error: the milestone still has open issues; close or move them first " ++
            "(see 'git issue milestone show')\n",
    );
    try expectSuccess(try gitIssue(&sb, &.{ "close", task }));
    try expectSuccess(try gitIssue(&sb, &.{ "close", epic }));
    try expectSuccess(try gitIssue(&sb, &.{ "milestone", "complete", "v1" }));
    try expectFailure(
        try gitIssue(&sb, &.{ "reopen", epic }),
        1,
        "error: the milestone is completed; reopen it first ('git issue milestone reopen')\n",
    );
    try expectFailure(
        try gitIssue(&sb, &.{ "create", "Late", "--milestone", "v1" }),
        1,
        "error: milestone 'v1' is completed; reopen it first\n",
    );

    // Unknown names stay text (as upstream writes them), with a hint.
    const free = try gitIssue(&sb, &.{ "create", "Free", "--milestone", "someday" });
    try expectSuccess(free);
    try testing.expectEqualStrings(
        "hint: no open milestone is named 'someday'; it is kept as text only " ++
            "(see 'git issue milestone ls')\n",
        free.stderr,
    );
}

test "attachments" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    const arena = sb.arena();
    // A 1x1 PNG (format/attachment.zig `samples.png`).
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01" ++
        "\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x00IEND\xaeB`\x82";
    const path = try std.fmt.allocPrint(arena, "{s}/shot.png", .{sb.repo});
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = png });
    const created = try gitIssue(&sb, &.{ "create", "Shots" });
    try expectSuccess(created);
    const id = std.mem.trimEnd(u8, created.stdout["Created issue ".len..], "\n");

    try expectSuccess(try gitIssue(&sb, &.{ "comment", id, "-m", "Look", "--attach", path }));
    try expectFailure(
        try gitIssue(&sb, &.{ "attach", "add", id, "build.zig.zon" }),
        1,
        "error: cannot read 'build.zig.zon': no such file\n",
    );
    const ls = try gitIssue(&sb, &.{ "attach", "ls", id });
    try expectSuccess(ls);
    try testing.expect(std.mem.find(u8, ls.stdout, "image/png   45 B  shot.png") != null);
    const att = ls.stdout[0..7];
    const cat = try gitIssue(&sb, &.{ "attach", "cat", id, att });
    try expectSuccess(cat);
    try testing.expectEqualSlices(u8, png, cat.stdout);
    const show = try gitIssue(&sb, &.{ "show", id });
    try testing.expect(std.mem.find(u8, show.stdout, "Attachments (1):\n") != null);
    try testing.expect(std.mem.find(u8, show.stdout, "  [attached ") != null);

    // The bytes are in the library's store, not git-lfs's.
    const sha = "6422564120b76bbc05819b296f96f7e82593e60bb33f3ecf2abaad1cdbf85339";
    const stored = try std.fmt.allocPrint(
        arena,
        "{s}/.git/issuez/lfs/objects/64/22/{s}",
        .{ sb.repo, sha },
    );
    try std.Io.Dir.cwd().access(testing.io, stored, .{});

    // Losing the derived ref: fsck notes it, --repair brings it back.
    const refs = try sb.run(&.{
        "git", "for-each-ref", "--format=%(refname)", "refs/attachments/",
    });
    const derived = std.mem.trimEnd(u8, refs.stdout, "\n");
    try sb.git(&.{ "update-ref", "-d", derived });
    const fsck = try gitIssue(&sb, &.{ "fsck", "-q" });
    try expectSuccess(fsck);
    const note = "is missing (run 'git issue fsck --repair')";
    try testing.expect(std.mem.find(u8, fsck.stderr, note) != null);
    try expectSuccess(try gitIssue(&sb, &.{ "fsck", "--repair", "-q" }));
    const tree = try std.fmt.allocPrint(arena, "{s}^{{tree}}", .{derived});
    const back = try sb.run(&.{ "git", "cat-file", "-p", tree });
    try testing.expect(std.mem.find(u8, back.stdout, ".png") != null);
}

test "attachments over git-lfs" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    if (!have(&sb, "git-lfs")) return error.SkipZigTest;
    const arena = sb.arena();
    const hub = try std.fmt.allocPrint(arena, "{s}-hub.git", .{sb.repo});
    const other = try std.fmt.allocPrint(arena, "{s}-other", .{sb.repo});
    const url = try std.fmt.allocPrint(arena, "file://{s}", .{hub});
    try sb.git(&.{ "init", "-q", "--bare", hub });
    try sb.git(&.{ "init", "-q", other });
    try sb.git(&.{ "remote", "add", "origin", url });
    try expectSuccess(try sb.runIn(other, &.{ "git", "remote", "add", "origin", url }));
    const inOther = struct {
        fn run(s: *Sandbox, dir: []const u8, args: []const []const u8) !Sandbox.Output {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(s.arena(), try s.exe(paths.git_issue_exe));
            try argv.appendSlice(s.arena(), args);
            return s.runIn(dir, argv.items);
        }
    }.run;
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01" ++
        "\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x00IEND\xaeB`\x82";
    const path = try std.fmt.allocPrint(arena, "{s}/shot.png", .{sb.repo});
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = png });

    try expectSuccess(try gitIssue(&sb, &.{ "init", "origin" }));
    const created = try gitIssue(&sb, &.{ "create", "Shots" });
    try expectSuccess(created);
    const id = std.mem.trimEnd(u8, created.stdout["Created issue ".len..], "\n");
    try expectSuccess(try gitIssue(&sb, &.{ "attach", "add", id, path }));
    const synced = try gitIssue(&sb, &.{ "sync", "origin" });
    try expectSuccess(synced);
    const uploaded = "Uploaded 1 attachment object(s) to origin's LFS server.";
    try testing.expect(std.mem.find(u8, synced.stdout, uploaded) != null);

    try expectSuccess(try inOther(&sb, other, &.{ "init", "origin" }));
    try expectSuccess(try inOther(&sb, other, &.{ "sync", "origin" }));
    const ls = try inOther(&sb, other, &.{ "attach", "ls", id });
    try testing.expect(std.mem.find(u8, ls.stdout, "(bytes not here)") != null);
    const att = ls.stdout[0..7];
    const cat = try inOther(&sb, other, &.{ "attach", "cat", id, att });
    try expectSuccess(cat);
    try testing.expectEqualSlices(u8, png, cat.stdout);

    // `git lfs prune` empties git-lfs's store, since it ignores custom refs.
    // Our own store keeps the bytes.
    try expectSuccess(try sb.runIn(other, &.{ "git", "commit", "-q", "--allow-empty", "-m", "x" }));
    try expectSuccess(try sb.runIn(other, &.{
        "git",                   "-c",                           "lfs.fetchrecentrefsdays=0",
        "-c",                    "lfs.fetchrecentcommitsdays=0", "-c",
        "lfs.pruneoffsetdays=0", "lfs",                          "prune",
    }));
    const after = try inOther(&sb, other, &.{ "attach", "cat", id, att });
    try expectSuccess(after);
    try testing.expectEqualSlices(u8, png, after.stdout);
}

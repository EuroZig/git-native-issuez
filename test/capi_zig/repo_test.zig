//! Opening and closing repositories.

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

// covers: issuez_repo_close, issuez_repo_git_dir
test "issuez_repo_open: work tree, subdirectory, bare, sha256" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const a = r.arena();
    const git_dir = try std.fs.path.join(a, &.{ r.path, ".git" });
    try expect.str(git_dir, c.issuez_repo_git_dir(r.handle));
    // A subdirectory of the work tree opens the same repository.
    const sub = try std.fs.path.join(a, &.{ r.path, "docs" });
    try std.Io.Dir.cwd().createDirPath(testing.io, sub);
    const opened = fixture.tryOpen(sub, &.{}, null);
    try expect.code(c.ISSUEZ_OK, opened[0], null);
    try expect.str(git_dir, c.issuez_repo_git_dir(opened[1]));
    c.issuez_repo_close(opened[1]);
    c.issuez_repo_close(null);
    try expect.str("", c.issuez_repo_git_dir(null));

    var bare = try fixture.Repo.init(.{ .bare = true });
    defer bare.deinit();
    try expect.str(bare.path, c.issuez_repo_git_dir(bare.handle));
    _ = try fixture.titled(bare.handle, "In a bare repo");

    var long = try fixture.Repo.init(.{ .init_flags = &.{"--object-format=sha256"} });
    defer long.deinit();
    const made = try fixture.titled(long.handle, "SHA-256");
    try testing.expectEqual(@as(u8, 32), made.tip.len);
}

test "issuez_repo_open: not a repository, an unknown option, bad values" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(path);
    // Not the repository this test runs in either.
    var ceiling = fixture.opStr(c.ISSUEZ_OPT_ENV, c.ISSUEZ_OP_SET, std.fs.path.dirname(path).?);
    ceiling.name = fixture.str("GIT_CEILING_DIRECTORIES");
    var err: ?*c.issuez_error = null;
    var res = fixture.tryOpen(path, &.{ceiling}, &err);
    try expect.code(c.ISSUEZ_E_NOT_A_REPOSITORY, res[0], err);
    try testing.expect(res[1] == null);
    c.issuez_error_free(err);

    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    var limit = fixture.opNum(c.ISSUEZ_OPT_LIMIT, 3);
    limit.name = fixture.str("no_such_limit");
    const bad = [_]c.issuez_op{
        c.issuez_q_limit(3),
        fixture.opNum(c.ISSUEZ_OPT_POOL_SIZE, 0),
        fixture.opNum(c.ISSUEZ_OPT_POOL_SIZE, 65),
        limit,
        fixture.opNum(c.ISSUEZ_OPT_CACHE_ISSUES, -1),
    };
    err = null;
    res = fixture.tryOpen(r.path, &bad, &err);
    try expect.code(c.ISSUEZ_E_INVALID_VALUE, res[0], err);
    const ps = c.issuez_error_problems(err);
    try testing.expectEqual(@as(usize, bad.len), c.issuez_problems_len(ps));
    for (0..bad.len) |i| {
        // After the environment's ops.
        try testing.expectEqual(
            @as(i64, @intCast(fixture.env_vars.len + i)),
            c.issuez_problems_at(ps, i).*.op_index,
        );
    }
    try expect.str("no_such_limit", c.issuez_problems_at(ps, 3).*.key);
    c.issuez_error_free(err);
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_repo_open(fixture.str(r.path), null, 0, null, null),
        null,
    );
}

test "issuez_repo_open: a git too old, a git that isn't there" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const old = try fixture.script(r.arena(), r.root, "old-git",
        \\#!/bin/sh
        \\[ "$1" = version ] && { echo "git version 2.10.0"; exit 0; }
        \\[ "$1" = --version ] && { echo "git version 2.10.0"; exit 0; }
        \\exec git "$@"
        \\
    );
    var err: ?*c.issuez_error = null;
    var res = fixture.tryOpen(r.path, &.{c.issuez_opt_git_path(fixture.str(old))}, &err);
    try expect.code(c.ISSUEZ_E_GIT_VERSION, res[0], err);
    c.issuez_error_free(err);
    err = null;
    res = fixture.tryOpen(r.path, &.{c.issuez_opt_git_path(fixture.str("/nonexistent/git"))}, &err);
    try expect.code(c.ISSUEZ_E_GIT, res[0], err);
    c.issuez_error_free(err);
}

test "issuez_repo_limit: the effective limits, set and default" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    var limit = fixture.opNum(c.ISSUEZ_OPT_LIMIT, 2);
    limit.name = fixture.str("max_labels");
    const res = fixture.tryOpen(r.path, &.{limit}, null);
    try expect.code(c.ISSUEZ_OK, res[0], null);
    const h = res[1].?;
    defer c.issuez_repo_close(h);
    var v: u64 = 0;
    try testing.expect(c.issuez_repo_limit(h, fixture.str("max_labels"), &v));
    try testing.expectEqual(@as(u64, 2), v);
    try testing.expect(c.issuez_repo_limit(h, fixture.str("cas_retries"), &v));
    try testing.expectEqual(@as(u64, 8), v);
    try testing.expect(c.issuez_repo_limit(h, fixture.str("max_attachment_bytes"), null));
    try testing.expect(!c.issuez_repo_limit(h, fixture.str("no_such_limit"), &v));
    try testing.expect(!c.issuez_repo_limit(null, fixture.str("max_labels"), &v));
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "issuez_repo_open: the process environment as it is at the open" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    // A git that says what it finds. The variable is new, so the C library
    // moves the environment to fit it, and other tests never see it.
    const a = r.arena();
    const found = try std.fs.path.join(a, &.{ r.root, "found" });
    const script = try std.fmt.allocPrint(
        a,
        "#!/bin/sh\nprintf %s \"$ISSUEZ_TEST_SET_LATER\" > '{s}'\nexec git \"$@\"\n",
        .{found},
    );
    try r.tmp.dir.writeFile(testing.io, .{
        .sub_path = "probe-git",
        .data = script,
        .flags = .{ .permissions = .executable_file },
    });
    const probe = try std.fs.path.join(a, &.{ r.root, "probe-git" });

    try testing.expectEqual(@as(c_int, 0), setenv("ISSUEZ_TEST_SET_LATER", "yes", 1));
    defer _ = unsetenv("ISSUEZ_TEST_SET_LATER");
    const res = fixture.tryOpen(r.path, &.{c.issuez_opt_git_path(fixture.str(probe))}, null);
    try expect.code(c.ISSUEZ_OK, res[0], null);
    defer c.issuez_repo_close(res[1]);
    _ = try fixture.titled(res[1].?, "Runs git");
    const got = try r.tmp.dir.readFileAlloc(testing.io, "found", a, .limited(16));
    try testing.expectEqualStrings("yes", got);
}

test "issuez_repo_open: a committer no git signature can hold" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const people = [_]struct { []const u8, []const u8 }{
        .{ "Server <x>", "s@example.invalid" },
        .{ "Server", "s@example.invalid\n" },
        .{ "S\x00", "s@example.invalid" },
    };
    for (people) |person| {
        var committer = std.mem.zeroes(c.issuez_op);
        committer.verb = c.ISSUEZ_OP_SET;
        committer.target = c.ISSUEZ_OPT_COMMITTER;
        committer.person.name = fixture.str(person[0]);
        committer.person.email = fixture.str(person[1]);
        var err: ?*c.issuez_error = null;
        const res = fixture.tryOpen(r.path, &.{committer}, &err);
        defer c.issuez_error_free(err);
        // Like every option's problem.
        try expect.code(c.ISSUEZ_E_INVALID_VALUE, res[0], err);
        try testing.expect(res[1] == null);
    }
}

test "issuez_repo_open: committer, environment, scopes and host prefixes" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    var committer = std.mem.zeroes(c.issuez_op);
    committer.verb = c.ISSUEZ_OP_SET;
    committer.target = c.ISSUEZ_OPT_COMMITTER;
    committer.person = .{
        .name = fixture.str("Server"),
        .email = fixture.str("server@example.invalid"),
        .user_id = .{},
    };
    var env_var = fixture.opStr(c.ISSUEZ_OPT_ENV, c.ISSUEZ_OP_SET, "1");
    env_var.name = fixture.str("ISSUEZ_TEST_MARKER");
    const ops = [_]c.issuez_op{
        committer,
        fixture.opStr(c.ISSUEZ_OPT_EXCLUSIVE_SCOPE, c.ISSUEZ_OP_ADD, "kind"),
        fixture.opStr(c.ISSUEZ_OPT_EXTRA_PREFIX, c.ISSUEZ_OP_ADD, "X-Acme-"),
        env_var,
    };
    const res = fixture.tryOpen(r.path, &ops, null);
    try expect.code(c.ISSUEZ_OK, res[0], null);
    const h = res[1].?;
    defer c.issuez_repo_close(h);

    const made = try fixture.create(h, &.{
        c.issuez_set_title(fixture.str("Committed by the server")),
        c.issuez_set_extra(fixture.str("X-Acme-Ticket"), fixture.str("7")),
    });
    const who = try r.git(
        &.{
            "log",
            "-1",
            "--format=%cn <%ce> / %an",
            try std.fmt.allocPrint(r.arena(), "refs/issues/{s}", .{made.idSlice()}),
        },
    );
    try testing.expectEqualStrings("Server <server@example.invalid> / Ada", who);

    // Two labels of one exclusive scope; a host key the
    // repo doesn't allow.
    const cases = [_]struct { []const c.issuez_op, c.issuez_code }{
        .{
            &.{
                c.issuez_set_title(fixture.str("T")),
                c.issuez_add_label(fixture.str("kind/bug")),
                c.issuez_add_label(fixture.str("kind/idea")),
            },
            c.ISSUEZ_E_INVALID_VALUE,
        },
        .{
            &.{
                c.issuez_set_title(fixture.str("T")),
                c.issuez_set_extra(fixture.str("X-Forgejo-Project"), fixture.str("1")),
            },
            c.ISSUEZ_E_INVALID_VALUE,
        },
    };
    for (cases) |case| {
        var w: ?*c.issuez_write = null;
        var err: ?*c.issuez_error = null;
        try expect.code(
            case[1],
            c.issuez_issue_create(h, case[0].ptr, case[0].len, &fixture.ada, null, &w, &err),
            err,
        );
        c.issuez_error_free(err);
    }

    // Adding a label of an exclusive scope takes the other one off.
    const scoped = try fixture.create(h, &.{
        c.issuez_set_title(fixture.str("Scoped")),
        c.issuez_add_label(fixture.str("kind/bug")),
        c.issuez_add_label(fixture.str("ui")),
    });
    _ = try fixture.update(h, scoped.idStr(), &.{c.issuez_add_label(fixture.str("kind/idea"))});
    var issue: ?*c.issuez_issue = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_issue_load(h, scoped.idStr(), null, &issue, null), null);
    defer c.issuez_issue_free(issue);
    try testing.expect(fixture.hasLabel(issue.?, "kind/idea"));
    try testing.expect(!fixture.hasLabel(issue.?, "kind/bug"));
    try testing.expect(fixture.hasLabel(issue.?, "ui"));
}

test "issuez_repo_open: timeouts end a hanging git" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const slow = try fixture.slowGit(r.arena(), r.root);
    const res = fixture.tryOpen(r.path, &.{
        c.issuez_opt_git_path(fixture.str(slow)),
        c.issuez_opt_timeout_local_ms(2000),
    }, null);
    try expect.code(c.ISSUEZ_OK, res[0], null);
    defer c.issuez_repo_close(res[1]);
    var snap: ?*c.issuez_snapshot = null;
    var err: ?*c.issuez_error = null;
    const start = std.Io.Timestamp.now(testing.io, .awake);
    try expect.code(
        c.ISSUEZ_E_TIMEOUT,
        c.issuez_snapshot_take(res[1], null, &snap, &err),
        err,
    );
    c.issuez_error_free(err);
    const took = start.untilNow(testing.io, .awake).toMilliseconds();
    try testing.expect(took < 5000);
}

/// A new issue in `h` starts in `first`; `other` is a workflow state and `unknown` isn't; `done`
/// counts as done and `not_done` doesn't.
fn expectStates(
    h: *c.issuez_repo,
    first: []const u8,
    other: []const u8,
    unknown: []const u8,
    done: []const u8,
    not_done: []const u8,
) !void {
    const x = try fixture.titled(h, "States");
    var i = try fixture.load(h, x.idStr());
    try expect.str(first, c.issuez_issue_info_of(i).*.workflow_state);
    c.issuez_issue_free(i);
    _ = try fixture.update(h, x.idStr(), &.{c.issuez_set_workflow_state(fixture.str(other))});
    var w: ?*c.issuez_write = null;
    const refused = [_]c.issuez_op{c.issuez_set_workflow_state(fixture.str(unknown))};
    try expect.code(
        c.ISSUEZ_E_INVALID_VALUE,
        fixture.updateRc(h, x.idStr(), &refused, &fixture.ada, null, &w, null),
        null,
    );
    _ = try fixture.update(h, x.idStr(), &.{c.issuez_set_state(fixture.str(not_done))});
    i = try fixture.load(h, x.idStr());
    try testing.expect(!c.issuez_issue_info_of(i).*.is_done);
    c.issuez_issue_free(i);
    _ = try fixture.update(h, x.idStr(), &.{c.issuez_set_state(fixture.str(done))});
    i = try fixture.load(h, x.idStr());
    defer c.issuez_issue_free(i);
    try testing.expect(c.issuez_issue_info_of(i).*.is_done);
}

test "issuez_repo_open: done and workflow states from defaults, config, options" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    // `closed` is always done; wontfix and duplicate are the others.
    try expectStates(r.handle, "backlog", "review", "doing", "duplicate", "shipped");

    // From git config.
    _ = try r.git(&.{ "config", "issue.workflowStates", "todo, doing" });
    _ = try r.git(&.{ "config", "issue.doneStates", "shipped" });
    const configured = fixture.tryOpen(r.path, &.{}, null);
    defer c.issuez_repo_close(configured[1]);
    try expectStates(configured[1].?, "todo", "doing", "review", "shipped", "wontfix");

    // Options win over config.
    const overridden = fixture.tryOpen(r.path, &.{
        fixture.opStr(c.ISSUEZ_OPT_WORKFLOW_STATE, c.ISSUEZ_OP_ADD, "new"),
        fixture.opStr(c.ISSUEZ_OPT_WORKFLOW_STATE, c.ISSUEZ_OP_ADD, "later"),
        fixture.opStr(c.ISSUEZ_OPT_DONE_STATE, c.ISSUEZ_OP_ADD, "merged"),
        fixture.opStr(c.ISSUEZ_OPT_DONE_STATE, c.ISSUEZ_OP_ADD, "rejected"),
    }, null);
    defer c.issuez_repo_close(overridden[1]);
    try expectStates(overridden[1].?, "new", "later", "todo", "rejected", "shipped");
}

// covers: issuez_fsck_report_issue_count, issuez_fsck_report_milestone_count
// covers: issuez_fsck_report_error_count, issuez_fsck_report_len, issuez_fsck_report_at
// covers: issuez_fsck_report_free
test "issuez_fsck: a clean repository, a damaged issue, nothing written" {
    var r = try fixture.Repo.init(.{});
    defer r.deinit();
    const h = r.handle;
    _ = try fixture.titled(h, "Fine");
    _ = try fixture.milestone(h, "v1");
    var rep: ?*c.issuez_fsck_report = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_fsck(h, null, &rep, null), null);
    try testing.expectEqual(@as(usize, 1), c.issuez_fsck_report_issue_count(rep));
    try testing.expectEqual(@as(usize, 1), c.issuez_fsck_report_milestone_count(rep));
    try testing.expectEqual(@as(usize, 0), c.issuez_fsck_report_error_count(rep));
    c.issuez_fsck_report_free(rep);
    try expect.code(c.ISSUEZ_E_INVALID_ARGUMENT, c.issuez_fsck(h, null, null, null), null);

    // A ref that isn't a UUID.
    const tree = try r.git(&.{ "hash-object", "-t", "tree", "-w", "/dev/null" });
    const commit = try r.git(&.{ "commit-tree", tree, "-m", "Odd" });
    _ = try r.git(&.{ "update-ref", "refs/issues/not-a-uuid", commit });
    const refs = try r.git(&.{"for-each-ref"});
    const objects = try r.git(&.{ "count-objects", "-v" });
    try expect.code(c.ISSUEZ_OK, c.issuez_fsck(h, null, &rep, null), null);
    defer c.issuez_fsck_report_free(rep);
    try testing.expect(c.issuez_fsck_report_error_count(rep) >= 1);
    var saw = false;
    for (0..c.issuez_fsck_report_len(rep)) |i| {
        const f = c.issuez_fsck_report_at(rep, i).*;
        try testing.expect(f.message.len > 0);
        if (f.kind == c.ISSUEZ_FSCK_INTEGRITY and f.is_error) {
            saw = true;
            try expect.str("not-a-uuid", f.subject);
        }
    }
    try testing.expect(saw);
    try testing.expect(c.issuez_fsck_report_at(rep, 99) == null);
    try testing.expectEqualStrings(refs, try r.git(&.{"for-each-ref"}));
    try testing.expectEqualStrings(objects, try r.git(&.{ "count-objects", "-v" }));
}

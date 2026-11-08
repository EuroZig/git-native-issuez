//! Opening and closing repositories.

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

// covers: issuez_repo_close, issuez_repo_git_dir
test "issuez_repo_open: work tree, subdirectory, bare, sha256" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
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

    var bare: fixture.Repo = undefined;
    try bare.init(.{ .bare = true });
    defer bare.deinit();
    try expect.str(bare.path, c.issuez_repo_git_dir(bare.handle));
    _ = try fixture.titled(bare.handle, "In a bare repo");

    var long: fixture.Repo = undefined;
    try long.init(.{ .init_flags = &.{"--object-format=sha256"} });
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

    var r: fixture.Repo = undefined;
    try r.init(.{});
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
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
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
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
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
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
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

test "issuez_repo_open: committer, environment, limits, scopes and host prefixes" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    var limit = fixture.opNum(c.ISSUEZ_OPT_LIMIT, 2);
    limit.name = fixture.str("max_labels");
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
        limit,
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

    // Over max_labels; two labels of one exclusive scope; a host key the
    // repo doesn't allow.
    const cases = [_]struct { []const c.issuez_op, c.issuez_code }{
        .{
            &.{
                c.issuez_set_title(fixture.str("T")),
                c.issuez_add_label(fixture.str("a")),
                c.issuez_add_label(fixture.str("b")),
                c.issuez_add_label(fixture.str("c")),
            },
            c.ISSUEZ_E_LIMIT,
        },
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
    try testing.expect(c.issuez_issue_has_label(issue, fixture.str("kind/idea")));
    try testing.expect(!c.issuez_issue_has_label(issue, fixture.str("kind/bug")));
    try testing.expect(c.issuez_issue_has_label(issue, fixture.str("ui")));
}

test "issuez_repo_open: timeouts end a hanging git" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    _ = try r.git(&.{ "remote", "add", "origin", "/nonexistent" });
    const slow = try fixture.slowGit(r.arena(), r.root);
    const res = fixture.tryOpen(r.path, &.{
        c.issuez_opt_git_path(fixture.str(slow)),
        fixture.opNum(c.ISSUEZ_OPT_TIMEOUT_NETWORK_MS, 200),
    }, null);
    try expect.code(c.ISSUEZ_OK, res[0], null);
    defer c.issuez_repo_close(res[1]);
    var report: ?*c.issuez_sync_report = null;
    var err: ?*c.issuez_error = null;
    const start = std.Io.Timestamp.now(testing.io, .awake);
    try expect.code(
        c.ISSUEZ_E_TIMEOUT,
        c.issuez_sync(res[1], fixture.str("origin"), null, 0, null, &report, &err),
        err,
    );
    c.issuez_error_free(err);
    const took = start.untilNow(testing.io, .awake).toMilliseconds();
    try testing.expect(took < 5000);
}

// covers: issuez_repo_workflow_state_at, issuez_repo_done_state_count, issuez_repo_done_state_at
test "issuez_repo_workflow_state_count: defaults, config, options" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    try testing.expectEqual(@as(usize, 4), c.issuez_repo_workflow_state_count(r.handle));
    try expect.str("backlog", c.issuez_repo_workflow_state_at(r.handle, 0));
    try expect.str("review", c.issuez_repo_workflow_state_at(r.handle, 3));
    try expect.str("", c.issuez_repo_workflow_state_at(r.handle, 4));
    // `closed` is always done; these are the others.
    try testing.expectEqual(@as(usize, 2), c.issuez_repo_done_state_count(r.handle));
    try expect.str("wontfix", c.issuez_repo_done_state_at(r.handle, 0));
    try expect.str("duplicate", c.issuez_repo_done_state_at(r.handle, 1));
    try expect.str("", c.issuez_repo_done_state_at(r.handle, 2));
    try testing.expectEqual(@as(usize, 0), c.issuez_repo_done_state_count(null));
    try testing.expectEqual(@as(usize, 0), c.issuez_repo_workflow_state_count(null));

    // From git config.
    _ = try r.git(&.{ "config", "issue.workflowStates", "todo, doing" });
    _ = try r.git(&.{ "config", "issue.doneStates", "shipped" });
    const configured = fixture.tryOpen(r.path, &.{}, null);
    defer c.issuez_repo_close(configured[1]);
    try testing.expectEqual(@as(usize, 2), c.issuez_repo_workflow_state_count(configured[1]));
    try expect.str("doing", c.issuez_repo_workflow_state_at(configured[1], 1));
    try expect.str("shipped", c.issuez_repo_done_state_at(configured[1], 0));

    // Options win over config.
    const overridden = fixture.tryOpen(r.path, &.{
        fixture.opStr(c.ISSUEZ_OPT_WORKFLOW_STATE, c.ISSUEZ_OP_ADD, "new"),
        fixture.opStr(c.ISSUEZ_OPT_DONE_STATE, c.ISSUEZ_OP_ADD, "merged"),
        fixture.opStr(c.ISSUEZ_OPT_DONE_STATE, c.ISSUEZ_OP_ADD, "rejected"),
    }, null);
    defer c.issuez_repo_close(overridden[1]);
    try testing.expectEqual(@as(usize, 1), c.issuez_repo_workflow_state_count(overridden[1]));
    try expect.str("new", c.issuez_repo_workflow_state_at(overridden[1], 0));
    try testing.expectEqual(@as(usize, 2), c.issuez_repo_done_state_count(overridden[1]));
    try expect.str("rejected", c.issuez_repo_done_state_at(overridden[1], 1));
}

test "issuez_repo_close: results outlive the handle" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const made = try fixture.titled(r.handle, "Outlives");
    const other = try r.open(&.{});
    var issue: ?*c.issuez_issue = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_issue_load(other, made.idStr(), null, &issue, null),
        null,
    );
    var list: ?*c.issuez_issue_list = null;
    var q = [_]c.issuez_op{c.issuez_q_done(-1)};
    try expect.code(c.ISSUEZ_OK, c.issuez_query_run(other, &q, 1, null, &list, null), null);
    c.issuez_repo_close(other);
    try expect.str("Outlives", c.issuez_issue_title(issue));
    try expect.str("Outlives", c.issuez_issue_title(c.issuez_issue_list_at(list, 0)));
    c.issuez_issue_list_free(list);
    c.issuez_issue_free(issue);
}

test "issuez_repo_drop_all: every ref of the library's, in one go" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    _ = try fixture.titled(h, "One");
    _ = try fixture.milestone(h, "v1");
    var n: usize = 0;
    try expect.code(c.ISSUEZ_OK, c.issuez_repo_drop_all(h, null, &n, null), null);
    try testing.expect(n >= 2);
    const left = try r.git(&.{ "for-each-ref", "refs/issues/", "refs/milestones/" });
    try testing.expectEqualStrings("", left);
    try expect.code(c.ISSUEZ_OK, c.issuez_repo_drop_all(h, null, &n, null), null);
    try testing.expectEqual(@as(usize, 0), n);
    try expect.code(c.ISSUEZ_OK, c.issuez_repo_drop_all(h, null, null, null), null);
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_repo_drop_all(null, null, &n, null),
        null,
    );
}

test "issuez_repo_adopt_refs: an import from a scratch repository on our objects, at once" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const a = r.arena();
    const objects = try std.fs.path.join(a, &.{ r.path, ".git", "objects" });
    const scratch_path = try std.fs.path.join(a, &.{ r.root, "scratch.git" });
    _ = try fixture.runGit(a, r.root, &.{ "init", "-q", "--bare", scratch_path });
    var shared = fixture.opStr(c.ISSUEZ_OPT_ENV, c.ISSUEZ_OP_SET, objects);
    shared.name = fixture.str("GIT_OBJECT_DIRECTORY");
    const opened = fixture.tryOpen(scratch_path, &.{shared}, null);
    try expect.code(c.ISSUEZ_OK, opened[0], null);
    const scratch = opened[1].?;
    defer c.issuez_repo_close(scratch);
    const x = try fixture.titled(scratch, "Imported");
    _ = try fixture.milestone(scratch, "v1");

    var n: usize = 0;
    try expect.code(c.ISSUEZ_OK, c.issuez_repo_adopt_refs(r.handle, scratch, null, &n, null), null);
    try testing.expectEqual(@as(usize, 2), n);
    const i = try fixture.load(r.handle, x.idStr());
    try expect.str("Imported", c.issuez_issue_title(i));
    c.issuez_issue_free(i);
    // The refs are there now: nothing is taken.
    try expect.code(
        c.ISSUEZ_E_CONTENDED,
        c.issuez_repo_adopt_refs(r.handle, scratch, null, &n, null),
        null,
    );

    // A scratch repository with objects of its own.
    const own_path = try std.fs.path.join(a, &.{ r.root, "own.git" });
    _ = try fixture.runGit(a, r.root, &.{ "init", "-q", "--bare", own_path });
    const own = fixture.tryOpen(own_path, &.{}, null);
    try expect.code(c.ISSUEZ_OK, own[0], null);
    defer c.issuez_repo_close(own[1].?);
    _ = try fixture.titled(own[1].?, "Elsewhere");
    try expect.code(
        c.ISSUEZ_E_CORRUPT,
        c.issuez_repo_adopt_refs(r.handle, own[1].?, null, &n, null),
        null,
    );
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_repo_adopt_refs(r.handle, null, null, &n, null),
        null,
    );
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_repo_adopt_refs(r.handle, r.handle, null, &n, null),
        null,
    );
}

test "issuez_settings_write: done and workflow states in git config, checked" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    const ops = [_]c.issuez_op{
        fixture.opStr(c.ISSUEZ_OPT_DONE_STATE, c.ISSUEZ_OP_ADD, "wontfix"),
        fixture.opStr(c.ISSUEZ_OPT_DONE_STATE, c.ISSUEZ_OP_ADD, "cancelled"),
        fixture.opStr(c.ISSUEZ_OPT_WORKFLOW_STATE, c.ISSUEZ_OP_ADD, "todo"),
        fixture.opStr(c.ISSUEZ_OPT_WORKFLOW_STATE, c.ISSUEZ_OP_ADD, "doing"),
    };
    try expect.code(c.ISSUEZ_OK, c.issuez_settings_write(h, &ops, ops.len, null, null), null);
    try testing.expectEqualStrings(
        "wontfix, cancelled",
        try r.git(&.{ "config", "issue.doneStates" }),
    );
    // A handle opened now sees them.
    const again = try r.open(&.{});
    defer c.issuez_repo_close(again);
    try testing.expectEqual(@as(usize, 2), c.issuez_repo_workflow_state_count(again));
    // CLEAR unsets the key.
    var unset = std.mem.zeroes(c.issuez_op);
    unset.verb = c.ISSUEZ_OP_CLEAR;
    unset.target = c.ISSUEZ_OPT_WORKFLOW_STATE;
    const unsets = [_]c.issuez_op{unset};
    try expect.code(c.ISSUEZ_OK, c.issuez_settings_write(h, &unsets, 1, null, null), null);
    const left = try r.git(&.{ "config", "--get", "--default", "unset", "issue.workflowStates" });
    try testing.expectEqualStrings("unset", left);
    const bad = [_]c.issuez_op{fixture.opStr(c.ISSUEZ_OPT_DONE_STATE, c.ISSUEZ_OP_ADD, "open")};
    var err: ?*c.issuez_error = null;
    try expect.code(c.ISSUEZ_E_INVALID_VALUE, c.issuez_settings_write(h, &bad, 1, null, &err), err);
    c.issuez_error_free(err);
    const wrong = [_]c.issuez_op{c.issuez_set_title(fixture.str("x"))};
    try expect.code(
        c.ISSUEZ_E_INVALID_VALUE,
        c.issuez_settings_write(h, &wrong, 1, null, null),
        null,
    );
    var ps: ?*c.issuez_problems = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_ops_validate(c.ISSUEZ_LIST_SETTINGS, &ops, ops.len, &ps, null),
        null,
    );
    try testing.expectEqual(@as(usize, 0), c.issuez_problems_len(ps));
    c.issuez_problems_free(ps);
}

// covers: issuez_fsck_report_issue_count, issuez_fsck_report_milestone_count
// covers: issuez_fsck_report_error_count, issuez_fsck_report_len, issuez_fsck_report_at
// covers: issuez_fsck_report_free
test "issuez_fsck: a clean repository, a damaged issue" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    const h = r.handle;
    _ = try fixture.titled(h, "Fine");
    _ = try fixture.milestone(h, "v1");
    var rep: ?*c.issuez_fsck_report = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_fsck(h, 0, null, &rep, null), null);
    try testing.expectEqual(@as(usize, 1), c.issuez_fsck_report_issue_count(rep));
    try testing.expectEqual(@as(usize, 1), c.issuez_fsck_report_milestone_count(rep));
    try testing.expectEqual(@as(usize, 0), c.issuez_fsck_report_error_count(rep));
    c.issuez_fsck_report_free(rep);
    // A flag this library doesn't know.
    try expect.code(c.ISSUEZ_E_INVALID_ARGUMENT, c.issuez_fsck(h, 1 << 31, null, &rep, null), null);

    // A ref that isn't a UUID, on a commit with a file in its tree.
    const tree = try r.git(&.{ "hash-object", "-t", "tree", "-w", "/dev/null" });
    const commit = try r.git(&.{ "commit-tree", tree, "-m", "Odd" });
    _ = try r.git(&.{ "update-ref", "refs/issues/not-a-uuid", commit });
    try expect.code(c.ISSUEZ_OK, c.issuez_fsck(h, 0, null, &rep, null), null);
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
}

var watch_calls: std.atomic.Value(u32) = .init(0);
var watch_bits: std.atomic.Value(u32) = .init(0);

fn onWatch(_: ?*anyopaque, changes: u32) callconv(.c) void {
    _ = watch_calls.fetchAdd(1, .acq_rel);
    _ = watch_bits.fetchOr(changes, .acq_rel);
}

test "issuez_watch_start, issuez_watch_stop: another process's write is reported" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var r: fixture.Repo = undefined;
    try r.init(.{});
    defer r.deinit();
    var w: ?*c.issuez_watch = null;
    var err: ?*c.issuez_error = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_watch_start(r.handle, onWatch, null, &w, &err), err);
    // Another handle, as another process would write.
    const other = try r.open(&.{});
    defer c.issuez_repo_close(other);
    _ = try fixture.titled(other, "Watched");
    var waited: usize = 0;
    while (watch_calls.load(.acquire) == 0 and waited < 300) : (waited += 1) {
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }
    c.issuez_watch_stop(w);
    try testing.expect(watch_calls.load(.acquire) > 0);
    try testing.expect(watch_bits.load(.acquire) & c.ISSUEZ_WATCH_REFS != 0);
    c.issuez_watch_stop(null);
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_watch_start(r.handle, null, null, &w, null),
        null,
    );
}

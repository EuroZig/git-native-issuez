//! GitProcess against real git, in temporary repositories. One cat-file
//! session has to serve many reads, and `GitSim` has to agree with git on
//! OIDs and merge bases.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const issuez = @import("issuez");
const GitProcess = issuez.backend.GitProcess;
const GitSim = issuez.backend.GitSim;
const object = issuez.backend.object;
const Oid = object.Oid;

const io = testing.io;

const Repo = struct {
    tmp: testing.TmpDir,
    path: []const u8,
    env: std.process.Environ.Map,

    fn init(gpa: Allocator, init_args: []const []const u8) !Repo {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        errdefer gpa.free(path);

        var env = try testing.environ.createMap(gpa);
        errdefer env.deinit();
        try isolateGit(&env);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "git", "init", "-q" });
        try argv.appendSlice(gpa, init_args);
        try argv.append(gpa, path);
        try runGit(gpa, &env, ".", argv.items);
        return .{ .tmp = tmp, .path = path, .env = env };
    }

    fn deinit(r: *Repo, gpa: Allocator) void {
        r.env.deinit();
        gpa.free(r.path);
        r.tmp.cleanup();
    }

    fn open(r: *Repo, gpa: Allocator) !GitProcess {
        return GitProcess.open(io, gpa, .{ .path = r.path, .environ_map = &r.env });
    }
};

/// Deterministic identity, no user/system config influence.
fn isolateGit(env: *std.process.Environ.Map) !void {
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("GIT_AUTHOR_NAME", "Test Author");
    try env.put("GIT_AUTHOR_EMAIL", "author@example.invalid");
    try env.put("GIT_AUTHOR_DATE", "1700000000 +0100");
    try env.put("GIT_COMMITTER_NAME", "Test Author");
    try env.put("GIT_COMMITTER_EMAIL", "author@example.invalid");
    try env.put("GIT_COMMITTER_DATE", "1700000000 +0100");
}

fn runGit(
    gpa: Allocator,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
    argv: []const []const u8,
) !void {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("git failed: {s}\n", .{result.stderr});
        return error.GitFailed;
    }
}

const sig: object.Signature = .{
    .name = "T",
    .email = "t@example.invalid",
    .time = 1700000000,
    .tz_offset_minutes = 60,
};

fn commitBytes(
    arena: Allocator,
    format: object.ObjectFormat,
    parents: []const Oid,
    msg: []const u8,
) ![]u8 {
    const c: object.Commit = .{
        .tree = object.emptyTree(format),
        .parents = parents,
        .author = sig,
        .committer = sig,
        .message = msg,
    };
    return c.serializeAlloc(arena);
}

test "open" {
    const gpa = testing.allocator;
    var repo = try Repo.init(gpa, &.{});
    defer repo.deinit(gpa);
    var git = try repo.open(gpa);
    defer git.close();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqual(object.ObjectFormat.sha1, git.objectFormat());
    const who = (try git.identity(arena)).author;
    try testing.expectEqualStrings("Test Author", who.name);
    try testing.expectEqualStrings("author@example.invalid", who.email);
    try testing.expectEqual(@as(i64, 1700000000), who.time);
    try testing.expectEqual(@as(i16, 60), who.tz_offset_minutes);

    // A plain directory, with discovery stopped above it.
    var plain = testing.tmpDir(.{});
    defer plain.cleanup();
    const plain_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{plain.sub_path});
    const cwd = try std.process.currentPathAlloc(io, arena);
    var env = try repo.env.clone(gpa);
    defer env.deinit();
    try env.put(
        "GIT_CEILING_DIRECTORIES",
        try std.fmt.allocPrint(arena, "{s}/.zig-cache/tmp", .{cwd}),
    );
    try testing.expectError(
        error.NotARepository,
        GitProcess.open(io, gpa, .{ .path = plain_path, .environ_map = &env }),
    );
    // A path that doesn't exist: not "could not run git".
    try testing.expectError(
        error.NotARepository,
        GitProcess.open(io, gpa, .{ .path = "/nonexistent/issuez-test", .environ_map = &env }),
    );
}

test "the git binary is configurable" {
    const gpa = testing.allocator;
    var repo = try Repo.init(gpa, &.{});
    defer repo.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A wrapper that logs each command, so the test sees which git ran:
    // the commands and the long-lived sessions alike.
    var bin = testing.tmpDir(.{});
    defer bin.cleanup();
    const cwd = try std.process.currentPathAlloc(io, arena);
    const dir = try std.fmt.allocPrint(arena, "{s}/.zig-cache/tmp/{s}", .{ cwd, bin.sub_path });
    const script = try std.fmt.allocPrint(
        arena,
        "#!/bin/sh\necho \"$1\" >> '{s}/log'\nexec git \"$@\"\n",
        .{dir},
    );
    try bin.dir.writeFile(io, .{
        .sub_path = "git-wrapper",
        .data = script,
        .flags = .{ .permissions = .executable_file },
    });
    const wrapper = try std.fmt.allocPrint(arena, "{s}/git-wrapper", .{dir});

    var git = try GitProcess.open(io, gpa, .{
        .path = repo.path,
        .environ_map = &repo.env,
        .git = wrapper,
    });
    defer git.close();
    _ = try git.writeObject(.blob, "hello\n");
    _ = try git.resolveRef("refs/heads/none");
    const log = try bin.dir.readFileAlloc(io, "log", arena, .limited(1 << 16));
    for ([_][]const u8{ "version", "hash-object", "cat-file" }) |command| {
        if (std.mem.indexOf(u8, log, command) == null) {
            std.debug.print("{s} didn't run through the wrapper:\n{s}", .{ command, log });
            return error.TestUnexpectedResult;
        }
    }

    try testing.expectError(error.GitSpawnFailed, GitProcess.open(io, gpa, .{
        .path = repo.path,
        .environ_map = &repo.env,
        .git = "/nonexistent/git",
    }));
}

test "open without a terminal: no git on PATH fails, leaving no fd open" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var repo = try Repo.init(gpa, &.{});
    defer repo.deinit(gpa);
    var env = try repo.env.clone(gpa);
    defer env.deinit();
    try env.put("PATH", "/nonexistent/issuez-test");
    const probe = struct {
        fn fd() !std.posix.fd_t {
            const f = try std.Io.Dir.openFileAbsolute(io, "/dev/null", .{});
            defer f.close(io);
            return f.handle;
        }
    };
    const before = try probe.fd();
    for (0..3) |_| try testing.expectError(
        error.GitSpawnFailed,
        GitProcess.open(io, gpa, .{ .path = repo.path, .environ_map = &env, .no_terminal = true }),
    );
    try testing.expectEqual(before, try probe.fd());
}

test "cat-file session" {
    const gpa = testing.allocator;
    var repo = try Repo.init(gpa, &.{});
    defer repo.deinit(gpa);
    var git = try repo.open(gpa);
    defer git.close();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const n = 300;
    var oids: [n]Oid = undefined;
    var datas: [n][]u8 = undefined;
    var parent: ?Oid = null;
    for (0..n) |i| {
        const msg = try std.fmt.allocPrint(arena, "Commit {d}\n\n{s}\n", .{ i, "x" ** 100 });
        const parents: []const Oid = if (parent) |p| &.{p} else &.{};
        datas[i] = try commitBytes(arena, .sha1, parents, msg);
        oids[i] = try git.writeObject(.commit, datas[i]);
        try testing.expect(oids[i].eql(object.hashObject(.sha1, .commit, datas[i])));
        parent = oids[i];
    }
    // Written through one `hash-object` session.
    try testing.expect(git.hash_objects[@intFromEnum(object.ObjectKind.commit)] != null);
    // Interleave reads in reverse order through the same session.
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        const o = (try git.readObject(arena, oids[i])).?;
        try testing.expectEqual(object.ObjectKind.commit, o.kind);
        try testing.expectEqualStrings(datas[i], o.data);
    }
    const session = git.cat_file;
    try testing.expect(session != null);
    _ = (try git.readObject(arena, oids[0])).?;
    try testing.expect(git.cat_file == session); // still the same process

    // A large object (bigger than the session's read buffer).
    const big_msg = try arena.alloc(u8, 300 * 1024);
    @memset(big_msg, 'b');
    big_msg[big_msg.len - 1] = '\n';
    const big = try commitBytes(arena, .sha1, &.{}, big_msg);
    const big_oid = try git.writeObject(.commit, big);
    try testing.expectEqualStrings(big, (try git.readObject(arena, big_oid)).?.data);

    const missing = try Oid.parseHex(.sha1, "0123456789abcdef0123456789abcdef01234567");
    try testing.expect(try git.readObject(arena, missing) == null);
    // The session survives a miss.
    try testing.expectEqualStrings(datas[5], (try git.readObject(arena, oids[5])).?.data);

    // git itself accepts every object we wrote.
    try runGit(gpa, &repo.env, repo.path, &.{ "git", "fsck", "--strict", "--no-dangling" });
}

test "ref transactions" {
    const gpa = testing.allocator;
    var repo = try Repo.init(gpa, &.{});
    defer repo.deinit(gpa);
    var git = try repo.open(gpa);
    defer git.close();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const c1 = try git.writeObject(.commit, try commitBytes(arena, .sha1, &.{}, "one\n"));
    const c2 = try git.writeObject(.commit, try commitBytes(arena, .sha1, &.{c1}, "two\n"));
    const a = "refs/issues/a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e";
    const b = "refs/issues/b8e4c3d2-5f6e-4b9c-8d2f-3a4b5c6d7e8f";

    try testing.expect(try git.resolveRef(a) == null);
    try git.updateRefs(&.{.{ .name = a, .op = .{ .create = c1 } }});
    try testing.expect((try git.resolveRef(a)).?.eql(c1));

    // Creating an existing ref is a conflict.
    try testing.expectError(
        error.RefConflict,
        git.updateRefs(&.{.{ .name = a, .op = .{ .create = c2 } }}),
    );
    // Stale expectation is a conflict and changes nothing.
    try testing.expectError(
        error.RefConflict,
        git.updateRefs(&.{.{ .name = a, .op = .{ .update = .{ .new = c2, .old = c2 } } }}),
    );
    try testing.expect((try git.resolveRef(a)).?.eql(c1));

    // All or nothing: the failing verify must roll back the create of `b`.
    try testing.expectError(error.RefConflict, git.updateRefs(&.{
        .{ .name = b, .op = .{ .create = c1 } },
        .{ .name = a, .op = .{ .verify = c2 } },
    }));
    try testing.expect(try git.resolveRef(b) == null);

    // A passing verify (guard read) alongside an update.
    try git.updateRefs(&.{
        .{ .name = b, .op = .{ .create = c2 } },
        .{ .name = a, .op = .{ .verify = c1 } },
    });

    const refs = try git.listRefs(arena, "refs/issues/");
    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqualStrings(a, refs[0].name);
    try testing.expectEqualStrings(b, refs[1].name);
    try testing.expectEqual(@as(usize, 0), (try git.listRefs(arena, "refs/milestones/")).len);

    try git.updateRefs(&.{.{ .name = a, .op = .{ .delete = c1 } }});
    try testing.expect(try git.resolveRef(a) == null);
    try testing.expectError(
        error.RefConflict,
        git.updateRefs(&.{.{ .name = a, .op = .{ .verify = c1 } }}),
    );
}

test "config lookup" {
    const gpa = testing.allocator;
    var repo = try Repo.init(gpa, &.{});
    defer repo.deinit(gpa);
    try runGit(
        gpa,
        &repo.env,
        repo.path,
        &.{ "git", "config", "issue.workflowStates", "backlog,ready,done" },
    );
    var git = try repo.open(gpa);
    defer git.close();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    try testing.expectEqualStrings(
        "backlog,ready,done",
        (try git.configGet(arena_state.allocator(), "issue.workflowStates")).?,
    );
    try testing.expect(try git.configGet(arena_state.allocator(), "issue.doesNotExist") == null);
}

test "GitSim agrees with git" {
    const gpa = testing.allocator;
    for ([_]object.ObjectFormat{ .sha1, .sha256 }) |format| {
        var repo = try Repo.init(
            gpa,
            if (format == .sha256) &.{"--object-format=sha256"} else &.{},
        );
        defer repo.deinit(gpa);
        var git = try repo.open(gpa);
        defer git.close();
        try testing.expectEqual(format, git.objectFormat());

        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var world: GitSim.World = .{ .format = format, .clones = &.{.{ .name = "a" }} };
        var sim = try GitSim.init(arena, &world, 0);

        // root - left -+- m1 (left,right)
        //      \ right +- m2 (right,left)   criss-cross between m1 and m2
        const Spec = struct { msg: []const u8, parents: []const usize };
        const specs = [_]Spec{
            .{ .msg = "root\n", .parents = &.{} },
            .{ .msg = "left\n", .parents = &.{0} },
            .{ .msg = "right\n", .parents = &.{0} },
            .{ .msg = "m1\n", .parents = &.{ 1, 2 } },
            .{ .msg = "m2\n", .parents = &.{ 2, 1 } },
            .{ .msg = "tip1\n", .parents = &.{3} },
            .{ .msg = "tip2\n", .parents = &.{4} },
        };
        var oids: [specs.len]Oid = undefined;
        for (specs, 0..) |s, i| {
            var parents: [2]Oid = undefined;
            for (s.parents, 0..) |p, j| parents[j] = oids[p];
            const data = try commitBytes(arena, format, parents[0..s.parents.len], s.msg);
            const real = try git.writeObject(.commit, data);
            const simulated = try sim.writeObject(.commit, data);
            try testing.expect(real.eql(simulated));
            oids[i] = real;
        }
        for (oids) |x| for (oids) |y| {
            try testing.expectEqual(try git.isAncestor(x, y), try sim.isAncestor(x, y));
            const real_bases = try git.mergeBases(arena, x, y);
            const sim_bases = try sim.mergeBases(arena, x, y);
            try testing.expectEqual(real_bases.len, sim_bases.len);
            for (real_bases, sim_bases) |rb, sb| try testing.expect(rb.eql(sb));
        };
        const criss = try git.mergeBases(arena, oids[5], oids[6]);
        try testing.expectEqual(@as(usize, 2), criss.len);
    }
}

test "push and fetch" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hub = try Repo.init(gpa, &.{"--bare"});
    defer hub.deinit(gpa);
    var a = try Repo.init(gpa, &.{});
    defer a.deinit(gpa);
    var b = try Repo.init(gpa, &.{});
    defer b.deinit(gpa);
    const cwd = try std.process.currentPathAlloc(io, arena);
    const hub_url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ cwd, hub.path });
    try runGit(gpa, &a.env, a.path, &.{ "git", "remote", "add", "origin", hub_url });
    try runGit(gpa, &b.env, b.path, &.{ "git", "remote", "add", "origin", hub_url });

    var ga = try a.open(gpa);
    defer ga.close();
    var gb = try b.open(gpa);
    defer gb.close();
    const remotes = try ga.remoteNames(arena);
    try testing.expectEqual(@as(usize, 1), remotes.len);
    try testing.expectEqualStrings("origin", remotes[0]);

    const name = "refs/issues/a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e";
    const root = try ga.writeObject(.commit, try commitBytes(arena, .sha1, &.{}, "root\n"));
    try ga.updateRefs(&.{.{ .name = name, .op = .{ .create = root } }});
    const spec = name ++ ":" ++ name;
    const first = try ga.push(arena, "origin", &.{spec}, .{ .atomic = true });
    try testing.expectEqual(@as(usize, 1), first.refs.len);
    try testing.expectEqual(issuez.backend.contract.PushedRef.Status.ok, first.refs[0].status);
    const again = try ga.push(arena, "origin", &.{spec}, .{ .atomic = true });
    try testing.expectEqual(
        issuez.backend.contract.PushedRef.Status.up_to_date,
        again.refs[0].status,
    );

    // b fetches into staging, builds on it, pushes.
    try gb.fetch(arena, "origin", &.{"+refs/issues/*:refs/remotes/origin/issues/*"}, .{});
    const staged_name = "refs/remotes/origin/issues/a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e";
    const staged = (try gb.resolveRef(staged_name)).?;
    try testing.expect(staged.eql(root));
    const b_child = try gb.writeObject(
        .commit,
        try commitBytes(arena, .sha1, &.{root}, "from b\n"),
    );
    try gb.updateRefs(&.{.{ .name = name, .op = .{ .create = b_child } }});
    try testing.expect(!(try gb.push(arena, "origin", &.{spec}, .{ .atomic = true })).rejected());

    // a's diverging commit is not a fast-forward: rejected, and with
    // --atomic the other ref in the same push isn't applied either.
    const a_child = try ga.writeObject(
        .commit,
        try commitBytes(arena, .sha1, &.{root}, "from a\n"),
    );
    try ga.updateRefs(&.{.{ .name = name, .op = .{ .update = .{ .new = a_child, .old = root } } }});
    const other = "refs/issues/b8e4c3d2-5f6e-4b9c-8d2f-3a4b5c6d7e8f";
    try ga.updateRefs(&.{.{ .name = other, .op = .{ .create = root } }});
    const rejected = try ga.push(
        arena,
        "origin",
        &.{ spec, other ++ ":" ++ other },
        .{ .atomic = true },
    );
    try testing.expect(rejected.rejected());
    try gb.fetch(arena, "origin", &.{"+refs/issues/*:refs/remotes/origin/issues/*"}, .{});
    const other_staged = "refs/remotes/origin/issues/b8e4c3d2-5f6e-4b9c-8d2f-3a4b5c6d7e8f";
    try testing.expect(try gb.resolveRef(other_staged) == null);

    // An unknown remote is a fetch failure with git's explanation kept.
    try testing.expectError(
        error.FetchFailed,
        ga.fetch(arena, "nosuchremote", &.{"+refs/issues/*:refs/remotes/x/issues/*"}, .{}),
    );
    try testing.expect(ga.lastStderr().len > 0);
}

test "object writes ignore attributes and filters" {
    const gpa = testing.allocator;
    var repo = try Repo.init(gpa, &.{});
    defer repo.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A clean filter and eol conversion for every path, the temp files
    // included. The object has to be the bytes, as with `--stdin`.
    const attributes = try std.fs.path.join(arena, &.{ repo.path, ".git", "info", "attributes" });
    try std.Io.Dir.cwd().writeFile(
        io,
        .{ .sub_path = attributes, .data = "* filter=up text eol=crlf\n" },
    );
    try runGit(gpa, &repo.env, repo.path, &.{ "git", "config", "filter.up.clean", "tr a-z A-Z" });
    // A temp file a dead process left behind a day ago is swept.
    const tmp = try std.fs.path.join(arena, &.{ repo.path, ".git", "issuez", "tmp" });
    try std.Io.Dir.cwd().createDirPath(io, tmp);
    const stale = try std.fs.path.join(arena, &.{ tmp, "object-stale" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = stale, .data = "x" });
    try runGit(gpa, &repo.env, ".", &.{ "touch", "-t", "202001010000", stale });

    var git = try repo.open(gpa);
    defer git.close();
    const data = "hello\nworld\n";
    const oid = try git.writeObject(.blob, data);
    try testing.expect(oid.eql(object.hashObject(.sha1, .blob, data)));
    try testing.expectEqualStrings(data, (try git.readObject(arena, oid)).?.data);
    // Through the session, not the one-off fallback (which drops it).
    try testing.expect(git.hash_objects[@intFromEnum(object.ObjectKind.blob)] != null);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, stale, .{}));
}

test "a ref to a missing object still resolves" {
    const gpa = testing.allocator;
    var repo = try Repo.init(gpa, &.{});
    defer repo.deinit(gpa);
    var git = try repo.open(gpa);
    defer git.close();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const name = "refs/issues/a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e";
    const oid = try git.writeObject(.commit, try commitBytes(arena, .sha1, &.{}, "root\n"));
    try git.updateRefs(&.{.{ .name = name, .op = .{ .create = oid } }});
    const hex = oid.hex();
    const loose = try std.fmt.allocPrint(arena, "{s}/.git/objects/{s}/{s}", .{
        repo.path, hex.slice()[0..2], hex.slice()[2..],
    });
    try std.Io.Dir.cwd().deleteFile(io, loose);

    // cat-file says "missing" for both; the ref is there, its object isn't.
    try testing.expect((try git.resolveRef(name)).?.eql(oid));
    try testing.expect(try git.readObject(arena, oid) == null);
    try testing.expect(
        try git.resolveRef("refs/issues/b8e4c3d2-5f6e-4b9c-8d2f-3a4b5c6d7e8f") == null,
    );
}

test "fetch with prune" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hub = try Repo.init(gpa, &.{});
    defer hub.deinit(gpa);
    var b = try Repo.init(gpa, &.{});
    defer b.deinit(gpa);
    const cwd = try std.process.currentPathAlloc(io, arena);
    const hub_url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ cwd, hub.path });
    try runGit(gpa, &b.env, b.path, &.{ "git", "remote", "add", "origin", hub_url });

    var gh = try hub.open(gpa);
    defer gh.close();
    var gb = try b.open(gpa);
    defer gb.close();
    const one = "refs/issues/a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e";
    const two = "refs/issues/b8e4c3d2-5f6e-4b9c-8d2f-3a4b5c6d7e8f";
    const root = try gh.writeObject(.commit, try commitBytes(arena, .sha1, &.{}, "root\n"));
    try gh.updateRefs(&.{
        .{ .name = one, .op = .{ .create = root } },
        .{ .name = two, .op = .{ .create = root } },
    });

    const specs: []const []const u8 = &.{
        "+refs/issues/*:refs/issuez-sync/origin/seen/issues/*",
        "+refs/milestones/*:refs/issuez-sync/origin/seen/milestones/*",
    };
    try gb.fetch(arena, "origin", specs, .{ .prune = true });
    try testing.expectEqual(@as(usize, 2), (try gb.listRefs(arena, "refs/issuez-sync/")).len);
    // Refs outside the destinations stay.
    try gb.updateRefs(
        &.{.{ .name = "refs/issuez-sync/origin/merged/issues/x", .op = .{ .create = root } }},
    );

    try gh.updateRefs(&.{.{ .name = two, .op = .{ .delete = root } }});
    try gb.fetch(arena, "origin", specs, .{ .prune = true });
    const left = try gb.listRefs(arena, "refs/issuez-sync/");
    try testing.expectEqual(@as(usize, 2), left.len);
    try testing.expectEqualStrings("refs/issuez-sync/origin/merged/issues/x", left[0].name);
    try testing.expectEqualStrings(
        "refs/issuez-sync/origin/seen/issues/" ++ one["refs/issues/".len..],
        left[1].name,
    );
}

test "leased push replaces and deletes, and refuses a stale lease" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const LeasedRef = issuez.backend.contract.LeasedRef;

    var hub = try Repo.init(gpa, &.{"--bare"});
    defer hub.deinit(gpa);
    var a = try Repo.init(gpa, &.{});
    defer a.deinit(gpa);
    const cwd = try std.process.currentPathAlloc(io, arena);
    const hub_url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ cwd, hub.path });
    try runGit(gpa, &a.env, a.path, &.{ "git", "remote", "add", "origin", hub_url });
    var ga = try a.open(gpa);
    defer ga.close();

    const name = "refs/issues/a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e";
    const gone = "refs/issues/b8e4c3d2-5f6e-4b9c-8d2f-3a4b5c6d7e8f";
    const old = try ga.writeObject(.commit, try commitBytes(arena, .sha1, &.{}, "old\n"));
    try ga.updateRefs(&.{
        .{ .name = name, .op = .{ .create = old } },
        .{ .name = gone, .op = .{ .create = old } },
    });
    _ = try ga.push(
        arena,
        "origin",
        &.{ name ++ ":" ++ name, gone ++ ":" ++ gone },
        .{ .atomic = true },
    );

    // Not a fast-forward: only a lease replaces it.
    const new = try ga.writeObject(.commit, try commitBytes(arena, .sha1, &.{}, "new\n"));
    try ga.updateRefs(&.{.{ .name = name, .op = .{ .update = .{ .new = new, .old = old } } }});
    const stale = try ga.pushLeased(arena, "origin", &[_]LeasedRef{
        .{ .src = name, .dst = name, .expect = new },
        .{ .src = null, .dst = gone, .expect = old },
    });
    try testing.expect(stale.rejected());
    var gh = try hub.open(gpa);
    defer gh.close();
    try testing.expect((try gh.resolveRef(gone)).?.eql(old));

    const done = try ga.pushLeased(arena, "origin", &[_]LeasedRef{
        .{ .src = name, .dst = name, .expect = old },
        .{ .src = null, .dst = gone, .expect = old },
    });
    try testing.expect(!done.rejected());
    gh.close();
    gh = try hub.open(gpa);
    try testing.expect((try gh.resolveRef(name)).?.eql(new));
    try testing.expect(try gh.resolveRef(gone) == null);
}

test "pre-push hook" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hub = try Repo.init(gpa, &.{"--bare"});
    defer hub.deinit(gpa);
    var a = try Repo.init(gpa, &.{});
    defer a.deinit(gpa);
    const cwd = try std.process.currentPathAlloc(io, arena);
    const hub_url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ cwd, hub.path });
    try runGit(gpa, &a.env, a.path, &.{ "git", "remote", "add", "origin", hub_url });

    // The hook records the refs it is told about. It refuses while
    // `refuse` exists.
    const seen = try std.fmt.allocPrint(arena, "{s}/hook-seen", .{cwd});
    const refuse = try std.fmt.allocPrint(arena, "{s}/{s}/refuse", .{ cwd, a.path });
    const hook = try std.fmt.allocPrint(
        arena,
        "#!/bin/sh\ncat >> '{s}'\ntest ! -e '{s}'\n",
        .{ seen, refuse },
    );
    const hook_path = try std.fmt.allocPrint(arena, "{s}/.git/hooks/pre-push", .{a.path});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = hook_path, .data = hook });
    try runGit(gpa, &a.env, ".", &.{ "chmod", "+x", hook_path });
    defer std.Io.Dir.cwd().deleteFile(io, seen) catch {};

    var ga = try a.open(gpa);
    defer ga.close();
    const name = "refs/issues/a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e";
    const root = try ga.writeObject(.commit, try commitBytes(arena, .sha1, &.{}, "root\n"));
    try ga.updateRefs(&.{.{ .name = name, .op = .{ .create = root } }});

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = refuse, .data = "" });
    const refused = ga.push(arena, "origin", &.{name ++ ":" ++ name}, .{ .atomic = true });
    if (refused) |r| try testing.expect(r.rejected()) else |err| {
        try testing.expectEqual(error.PushFailed, err);
    }
    var gh = try hub.open(gpa);
    defer gh.close();
    try testing.expect(try gh.resolveRef(name) == null);

    try std.Io.Dir.cwd().deleteFile(io, refuse);
    const pushed = try ga.push(arena, "origin", &.{name ++ ":" ++ name}, .{ .atomic = true });
    try testing.expect(!pushed.rejected());
    const log = try std.Io.Dir.cwd().readFileAlloc(io, seen, arena, .limited(4096));
    try testing.expect(std.mem.find(u8, log, name) != null);
}

test "a hung git times out" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hub = try Repo.init(gpa, &.{"--bare"});
    defer hub.deinit(gpa);
    var a = try Repo.init(gpa, &.{});
    defer a.deinit(gpa);
    const cwd = try std.process.currentPathAlloc(io, arena);
    const hub_url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ cwd, hub.path });
    try runGit(gpa, &a.env, a.path, &.{ "git", "remote", "add", "origin", hub_url });
    // Would hold back the sessions' answers.
    try a.env.put("GIT_FLUSH", "0");

    var ga = try a.open(gpa);
    defer ga.close();
    ga.timeouts.request = .fromSeconds(5);
    const one = "refs/issues/a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e";
    const two = "refs/issues/b8e4c3d2-5f6e-4b9c-8d2f-3a4b5c6d7e8f";
    const root = try ga.writeObject(.commit, try commitBytes(arena, .sha1, &.{}, "root\n"));
    try testing.expect(ga.hash_objects[@intFromEnum(object.ObjectKind.commit)] != null);

    const hooks = try std.fmt.allocPrint(arena, "{s}/.git/hooks", .{a.path});
    const rt = try std.fmt.allocPrint(arena, "{s}/reference-transaction", .{hooks});
    const pp = try std.fmt.allocPrint(arena, "{s}/pre-push", .{hooks});
    // Long enough for git to reach its hook on a loaded machine.
    const short: GitProcess.Timeouts = .{
        .command = .fromSeconds(1),
        .network = .fromSeconds(1),
    };
    const started = std.Io.Clock.awake.now(io);

    // update-ref, with its input on stdin, waits on its hook before the
    // refs move...
    try writeHook(gpa, &a.env, rt, "#!/bin/sh\nexec sleep 10\n");
    ga.timeouts = short;
    try testing.expectError(
        error.GitTimedOut,
        ga.updateRefs(&.{.{ .name = one, .op = .{ .create = root } }}),
    );
    ga.timeouts = .{};
    try testing.expect(try ga.resolveRef(one) == null);

    // ...or after: then the update is done.
    try writeHook(gpa, &a.env, rt, "#!/bin/sh\ntest \"$1\" = committed && exec sleep 10\nexit 0\n");
    ga.timeouts = short;
    try ga.updateRefs(&.{.{ .name = one, .op = .{ .create = root } }});
    ga.timeouts = .{};
    try testing.expect((try ga.resolveRef(one)).?.eql(root));
    try std.Io.Dir.cwd().deleteFile(io, rt);
    try ga.updateRefs(&.{.{ .name = two, .op = .{ .create = root } }});

    // push, under the network limit.
    try writeHook(gpa, &a.env, pp, "#!/bin/sh\nexec sleep 10\n");
    ga.timeouts = short;
    try testing.expectError(
        error.GitTimedOut,
        ga.push(arena, "origin", &.{one ++ ":" ++ one}, .{ .atomic = true }),
    );
    // Each hook sleeps 10 s: none was waited out.
    const took = started.durationTo(std.Io.Clock.awake.now(io));
    try testing.expect(took.toSeconds() < 8);
}

fn writeHook(
    gpa: Allocator,
    env: *const std.process.Environ.Map,
    path: []const u8,
    script: []const u8,
) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = script });
    try runGit(gpa, env, ".", &.{ "chmod", "+x", path });
}

test "GitProcess.beginImport: SHA-1 and SHA-256 publish atomically and remove staging" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "--object-format=sha1", "--object-format=sha256" }) |format| {
        var fixture = try Repo.init(gpa, &.{ "--bare", format });
        defer fixture.deinit(gpa);
        var git = try fixture.open(gpa);
        defer git.close();
        const main = issuez.Repo(GitProcess).init(&git);
        var stage = try git.beginImport(arena);
        const path = try arena.dupe(u8, stage.path);
        {
            defer stage.deinit();
            const scratch = issuez.Repo(GitProcess).init(&stage.git);
            const made = try scratch.create(arena, .{ .title = "Staged" }, .{});
            try testing.expect((try main.find(arena, made.id)) == null);
            try testing.expectEqual(@as(usize, 1), try stage.commit(arena, &git));
            try testing.expectError(error.InvalidValue, stage.commit(arena, &git));
            const published = (try main.find(arena, made.id)).?;
            try testing.expectEqualStrings("Staged", published.title);
        }
        try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, path, .{}));
    }
}

test "GitProcess.open: past Apple's git stub, and only that" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const gpa = testing.allocator;
    var repo = try Repo.init(gpa, &.{});
    defer repo.deinit(gpa);
    var env = try repo.env.clone(gpa);
    defer env.deinit();

    try env.put("PATH", "/usr/bin:/bin");
    var stubbed = try GitProcess.open(io, gpa, .{ .path = repo.path, .environ_map = &env });
    defer stubbed.close();
    try testing.expect(std.mem.endsWith(u8, stubbed.git_exe, "/git"));
    try testing.expect(!std.mem.startsWith(u8, stubbed.git_exe, "/usr/bin/"));
    // It really is a git, for reads and the long-lived sessions alike.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const blob = try stubbed.writeObject(.blob, "hello\n");
    try testing.expect(try stubbed.readObject(arena_state.allocator(), blob) != null);

    // A git chosen some other way stays what it was.
    var named = try GitProcess.open(io, gpa, .{
        .path = repo.path,
        .environ_map = &env,
        .git = stubbed.git_exe,
    });
    defer named.close();
    try testing.expectEqualStrings(stubbed.git_exe, named.git_exe);
}

test "GitProcess.open: cancellation during opening is not retained" {
    const gpa = testing.allocator;
    var repo = try Repo.init(gpa, &.{});
    defer repo.deinit(gpa);
    var flag: std.atomic.Value(bool) = .init(true);
    try testing.expectError(error.Canceled, GitProcess.open(io, gpa, .{
        .path = repo.path,
        .environ_map = &repo.env,
        .cancel = &flag,
    }));
    flag.store(false, .release);
    var git = try GitProcess.open(io, gpa, .{
        .path = repo.path,
        .environ_map = &repo.env,
        .cancel = &flag,
    });
    defer git.close();
    try testing.expect(git.cancel == null);
}

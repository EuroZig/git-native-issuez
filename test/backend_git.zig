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
    try testing.expectEqual(@as(usize, 0), (try git.listRefs(arena, "refs/notes/")).len);

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

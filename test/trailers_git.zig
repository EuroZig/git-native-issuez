//! Our trailer parser, subject and body against
//! `git log --format=%s / %b / %(trailers:only,unfold)` on random messages.

const std = @import("std");
const testing = std.testing;
const issuez = @import("issuez");
const trailers = issuez.format.trailers;
const GitProcess = issuez.backend.GitProcess;
const object = issuez.backend.object;

const io = testing.io;

const fragments = [_][]const u8{
    "State: open",
    "State: closed",
    "Labels: bug, auth",
    "Assignee: a@e.x",
    "Assignee:",
    "X-Parent: 0b6c4f63",
    "X-Long: first",
    "  continued",
    "\tcontinued tab",
    "prose text here",
    "Just one more line.",
    "# a comment line",
    "Signed-off-by: A <a@b>",
    "---",
    "State : spaced",
    "State:tight",
    "Fixes bug: no",
    "1Key: digit",
    "X_Under: no",
    "Priorit\xc3\xa4t: hoch",
    "(cherry picked from commit abc)",
    "Key:",
    ":nokey",
    "State# hash",
    "X-Url: http://a:b/c",
    "Trailing: spaces   ",
    "  ",
    "Title: Renamed",
};

/// `n` keeps every message unique: identical messages would be one commit,
/// which `git log --stdin` prints only once.
fn randomMessage(arena: std.mem.Allocator, rand: std.Random, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "Subject line {d}", .{n});
    if (rand.uintLessThan(u8, 4) == 0) try out.appendSlice(arena, "\ncontinued subject");
    const paragraphs = rand.uintAtMost(usize, 4);
    for (0..paragraphs) |_| {
        try out.appendSlice(arena, "\n\n");
        if (rand.uintLessThan(u8, 6) == 0) try out.appendSlice(arena, "\n"); // extra blank
        const lines = rand.intRangeAtMost(usize, 1, 5);
        for (0..lines) |li| {
            if (li > 0) try out.append(arena, '\n');
            try out.appendSlice(arena, fragments[rand.uintLessThan(usize, fragments.len)]);
        }
    }
    try out.append(arena, '\n');
    if (rand.uintLessThan(u8, 8) == 0) try out.appendSlice(arena, "\n\n");
    return out.items;
}

fn envInt(env: *const std.process.Environ.Map, key: []const u8) ?u64 {
    const v = env.get(key) orelse return null;
    return std.fmt.parseInt(u64, v, 10) catch null;
}

fn ours(arena: std.mem.Allocator, message: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    const subject = try trailers.subject(arena, message);
    const body = try trailers.bodyLines(arena, message);
    const block = try trailers.parse(arena, message, .{});
    try w.writer.print("{s}\x01", .{subject});
    for (body) |line| try w.writer.print("{s}\n", .{line});
    try w.writer.writeAll("\x01");
    for (block.trailers) |t| try w.writer.print("{s}: {s}\n", .{ t.key, t.value });
    return w.written();
}

test "parser matches git log on random messages" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var env = try testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    const init_result = try std.process.run(
        arena,
        io,
        .{ .argv = &.{ "git", "init", "-q", path }, .environ_map = &env },
    );
    try testing.expect(init_result.term == .exited and init_result.term.exited == 0);

    var git = try GitProcess.open(io, gpa, .{ .path = path, .environ_map = &env });
    defer git.close();

    // Defaults keep `zig build test` fast. CI runs more with
    // ISSUEZ_TRAILER_CASES=<n> and a fresh ISSUEZ_TRAILER_SEED.
    const count = envInt(&env, "ISSUEZ_TRAILER_CASES") orelse 600;
    const seed = envInt(&env, "ISSUEZ_TRAILER_SEED") orelse 20261018;
    if (count != 600 or seed != 20261018) std.debug.print(
        "trailers_git: {d} cases, seed {d}\n",
        .{ count, seed },
    );
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();
    const messages = try arena.alloc([]const u8, count);
    var stdin: std.Io.Writer.Allocating = .init(arena);
    const sig: object.Signature = .{
        .name = "T",
        .email = "t@e.x",
        .time = 1,
        .tz_offset_minutes = 0,
    };
    for (messages, 0..) |*m, n| {
        m.* = try randomMessage(arena, rand, n);
        const c: object.Commit = .{
            .tree = object.emptyTree(.sha1),
            .parents = &.{},
            .author = sig,
            .committer = sig,
            .message = m.*,
        };
        const oid = try git.writeObject(.commit, try c.serializeAlloc(arena));
        try stdin.writer.print("{f}\n", .{oid});
    }

    // One git process formats all commits, in input order.
    var child = try std.process.spawn(io, .{
        .argv = &.{
            "git",
            "log",
            "--no-walk=unsorted",
            "--stdin",
            "--format=%s%x01%b%x01%(trailers:only,unfold)%x02",
        },
        .cwd = .{ .path = path },
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer child.kill(io);
    var sw = child.stdin.?.writerStreaming(io, &.{});
    try sw.interface.writeAll(stdin.written());
    child.stdin.?.close(io);
    child.stdin = null;
    var reader_buf: [4096]u8 = undefined;
    var sr = child.stdout.?.readerStreaming(io, &reader_buf);
    const out = try sr.interface.allocRemaining(arena, .limited(16 * 1024 * 1024));
    _ = try child.wait(io);

    var records = std.mem.splitScalar(u8, out, '\x02');
    var mismatches: usize = 0;
    for (messages, 0..) |m, i| {
        var raw = records.next() orelse return error.MissingRecord;
        raw = std.mem.trimStart(u8, raw, "\n"); // git separates records with LF
        var git_parts = std.mem.splitScalar(u8, raw, '\x01');
        const git_subject = git_parts.next() orelse "";
        const git_body = std.mem.trimEnd(u8, git_parts.next() orelse "", "\n");
        const git_trailers = git_parts.next() orelse "";

        const mine = try ours(arena, m);
        var my_parts = std.mem.splitScalar(u8, mine, '\x01');
        const my_subject = my_parts.next().?;
        const my_body = std.mem.trimEnd(u8, my_parts.next().?, "\n");
        const my_trailers = my_parts.next().?;

        const ok = std.mem.eql(u8, git_subject, my_subject) and
            std.mem.eql(u8, git_body, my_body) and
            std.mem.eql(u8, git_trailers, my_trailers);
        if (!ok) {
            mismatches += 1;
            if (mismatches <= 3) std.debug.print(
                "MISMATCH #{d}\n--- message ---\n{s}" ++
                    "--- git ---\n[{s}]\n[{s}]\n[{s}]\n" ++
                    "--- ours ---\n[{s}]\n[{s}]\n[{s}]\n",
                .{ i, m, git_subject, git_body, git_trailers, my_subject, my_body, my_trailers },
            );
        }
    }
    try testing.expectEqual(@as(usize, 0), mismatches);
}

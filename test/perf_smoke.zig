//! A repository with N issues (a root and one comment each, written with
//! `git fast-import`), then `git-issue ls -a`, best of three warm runs.
//!
//!   perf-smoke <git-issue> [--issues N] [--budget-ms MS]
//!
//! Defaults to 10 000 issues and 2 000 ms. Exits 1 when over budget.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: perf-smoke <git-issue> [--issues N] [--budget-ms MS]\n", .{});
        return 2;
    }
    const cwd = try std.process.currentPathAlloc(io, arena);
    // It runs in the test repository, so a path relative to here would miss.
    const exe = if (std.fs.path.isAbsolute(args[1]))
        args[1]
    else
        try std.fs.path.join(arena, &.{ cwd, args[1] });
    var issues: u32 = 10_000;
    var budget_ms: u64 = 2_000;
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        const value = args[i + 1];
        if (std.mem.eql(u8, args[i], "--issues")) issues = try std.fmt.parseInt(u32, value, 10);
        if (std.mem.eql(u8, args[i], "--budget-ms")) {
            budget_ms = try std.fmt.parseInt(u64, value, 10);
        }
    }

    var env = try init.environ_map.clone(arena);
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    for ([_][]const u8{ "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME" }) |k| try env.put(k, "Perf");
    for ([_][]const u8{ "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL" }) |k| try env.put(k, "p@e.x");

    var rnd: [6]u8 = undefined;
    io.random(&rnd);
    const repo = try std.fmt.allocPrint(arena, "{s}/.zig-cache/tmp/perf-{x}", .{ cwd, rnd });
    defer Io.Dir.cwd().deleteTree(io, repo) catch {};
    try check(try std.process.run(arena, io, .{
        .argv = &.{ "git", "init", "-q", repo },
        .environ_map = &env,
    }));

    // fast-import stream: deterministic UUIDs and timestamps.
    var stream: Io.Writer.Allocating = .init(arena);
    const w = &stream.writer;
    var prng: std.Random.DefaultPrng = .init(1);
    const prios = [_][]const u8{ "low", "medium", "high", "critical" };
    for (0..issues) |n| {
        var b: [16]u8 = undefined;
        prng.random().bytes(&b);
        b[6] = (b[6] & 0x0f) | 0x40;
        b[8] = (b[8] & 0x3f) | 0x80;
        const hex = std.fmt.bytesToHex(b, .lower);
        const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}-{s}-{s}-{s}-{s}", .{
            hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32],
        });
        const msg = try std.fmt.allocPrint(
            arena,
            "Issue number {d}\n\nDescription {d}.\n\nState: {s}\nLabels: bug, area-{d}\n" ++
                "Priority: {s}\nFormat-Version: 1\n",
            .{ n, n, if (n % 3 == 0) "closed" else "open", n % 17, prios[n % 4] },
        );
        const t = 1_700_000_000 + 2 * n;
        try w.print("commit {s}\ncommitter Perf <p@e.x> {d} +0000\ndata {d}\n{s}\n", .{
            ref, t, msg.len, msg,
        });
        const c = try std.fmt.allocPrint(arena, "Comment on {d}\n", .{n});
        try w.print("commit {s}\ncommitter Perf <p@e.x> {d} +0000\ndata {d}\n{s}\n", .{
            ref, t + 1, c.len, c,
        });
    }
    var importer = try std.process.spawn(io, .{
        .argv = &.{ "git", "fast-import", "--quiet" },
        .cwd = .{ .path = repo },
        .environ_map = &env,
        .stdin = .pipe,
    });
    try importer.stdin.?.writeStreamingAll(io, stream.written());
    importer.stdin.?.close(io);
    importer.stdin = null;
    const term = try importer.wait(io);
    if (term != .exited or term.exited != 0) return error.FastImportFailed;

    var best: u64 = std.math.maxInt(u64);
    for (0..3) |run| {
        const start = Io.Clock.awake.now(io);
        const out = try std.process.run(arena, io, .{
            .argv = &.{ exe, "ls", "-a" },
            .cwd = .{ .path = repo },
            .environ_map = &env,
            .stdout_limit = .limited(64 * 1024 * 1024),
        });
        const ms: u64 = @intCast(start.durationTo(Io.Clock.awake.now(io)).toMilliseconds());
        try check(out);
        const lines = std.mem.count(u8, out.stdout, "\n");
        if (lines != issues) {
            std.debug.print("ls listed {d} issues, expected {d}\n", .{ lines, issues });
            return 1;
        }
        std.debug.print("run {d}: ls -a over {d} issues: {d} ms\n", .{ run + 1, issues, ms });
        best = @min(best, ms);
    }
    if (best > budget_ms) {
        std.debug.print("FAIL: best {d} ms is over the {d} ms budget\n", .{ best, budget_ms });
        return 1;
    }
    std.debug.print("ok: best {d} ms (budget {d} ms)\n", .{ best, budget_ms });
    return 0;
}

fn check(r: std.process.RunResult) !void {
    if (r.term != .exited or r.term.exited != 0) {
        std.debug.print("command failed: {s}\n", .{r.stderr});
        return error.CommandFailed;
    }
}

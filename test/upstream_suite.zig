//! Runs upstream's test suite (t/*.sh) against our binary.
//!
//!   upstream-suite UPSTREAM_ROOT GIT_ISSUE_EXE EXPECTED_FILE ALLOWLIST_FILE
//!
//! Upstream's tests call `$(dirname $0)/../bin/git-issue-<sub>` directly,
//! so we build a work tree with a copy of t/ and a bin/ whose
//! `git-issue` and `git-issue-<sub>` all point at our binary. Results come
//! from the `PASS <name>` and `FAIL <name>` lines upstream prints.
//!
//! EXPECTED_FILE lists `<file>::<test name>` entries that have to pass.
//! ALLOWLIST_FILE lists tests where we differ on purpose
//! (`<file>::<test name>  # reason`) and files to skip
//! (`skip-file <file>  # reason`). Tests in neither list are reported but
//! don't fail the run, so newly passing ones are easy to spot.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const subcommands = [_][]const u8{
    "create", "ls",     "show", "comment", "edit", "state", "search",
    "import", "export", "sync", "merge",   "fsck", "init",
};

const per_file_timeout_seconds = 180;

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("upstream-suite: {t}\n", .{err});
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) {
        std.debug.print(
            "usage: upstream-suite UPSTREAM_ROOT GIT_ISSUE_EXE EXPECTED_FILE ALLOWLIST_FILE\n",
            .{},
        );
        return 2;
    }
    const upstream_root = args[1];
    const exe = try absolute(io, arena, args[2]);
    const expected = try readList(io, arena, args[3]);
    const allow = try readAllowlist(io, arena, args[4]);

    for (expected.keys()) |key| if (allow.tests.contains(key)) {
        std.debug.print("error: '{s}' is both expected and allowlisted\n", .{key});
        return 1;
    };

    // Assemble the work tree.
    const cwd = try std.process.currentPathAlloc(io, arena);
    var rnd: [6]u8 = undefined;
    io.random(&rnd);
    const work = try std.fmt.allocPrint(
        arena,
        "{s}/.zig-cache/tmp/upstream-suite-{x}",
        .{ cwd, rnd },
    );
    const bin = try std.fmt.allocPrint(arena, "{s}/bin", .{work});
    try Io.Dir.cwd().createDirPath(io, bin);
    defer Io.Dir.cwd().deleteTree(io, work) catch {};
    try runChecked(
        io,
        arena,
        &.{ "cp", "-R", try std.fmt.allocPrint(arena, "{s}/t", .{upstream_root}), work },
        null,
    );
    try Io.Dir.cwd().symLink(io, exe, try std.fmt.allocPrint(arena, "{s}/git-issue", .{bin}), .{});
    for (subcommands) |sub| {
        try Io.Dir.cwd().symLink(
            io,
            exe,
            try std.fmt.allocPrint(arena, "{s}/git-issue-{s}", .{ bin, sub }),
            .{},
        );
    }

    // Isolated, deterministic environment.
    var env = try init.environ_map.clone(arena);
    const old_path = env.get("PATH") orelse "/usr/bin:/bin";
    try env.put("PATH", try std.fmt.allocPrint(arena, "{s}:{s}", .{ bin, old_path }));
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("GIT_AUTHOR_NAME", "Suite Runner");
    try env.put("GIT_AUTHOR_EMAIL", "suite@example.invalid");
    try env.put("GIT_COMMITTER_NAME", "Suite Runner");
    try env.put("GIT_COMMITTER_EMAIL", "suite@example.invalid");
    try env.put("NO_COLOR", "1");
    // No GitHub login, so the tests that need one skip themselves everywhere,
    // as they do on CI.
    try env.put("GH_CONFIG_DIR", try std.fmt.allocPrint(arena, "{s}/gh", .{work}));
    for ([_][]const u8{ "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN" }) |k| _ = env.swapRemove(k);

    // Discover test files.
    const t_dir = try std.fmt.allocPrint(arena, "{s}/t", .{work});
    var files: std.ArrayList([]const u8) = .empty;
    {
        var dir = try Io.Dir.cwd().openDir(io, t_dir, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(
                u8,
                entry.name,
                "test-",
            ) or !std.mem.endsWith(u8, entry.name, ".sh")) continue;
            try files.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, files.items, {}, lessThan);

    var results: std.array_hash_map.String(bool) = .empty;
    var total_pass: usize = 0;
    var total_fail: usize = 0;
    for (files.items) |file| {
        if (allow.skip_files.get(file)) |reason| {
            std.debug.print("  skip {s}  ({s})\n", .{ file, reason });
            continue;
        }
        const script = try std.fmt.allocPrint(arena, "{s}/{s}", .{ t_dir, file });
        const result = std.process.run(arena, io, .{
            .argv = &.{ "sh", script },
            .cwd = .{ .path = work },
            .environ_map = &env,
            .timeout = .{ .duration = .{
                .raw = .fromSeconds(per_file_timeout_seconds),
                .clock = .awake,
            } },
        }) catch |err| {
            std.debug.print("  {s}: could not run ({t})\n", .{ file, err });
            continue;
        };
        var pass: usize = 0;
        var fail: usize = 0;
        var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
        while (lines.next()) |raw| {
            const line = try stripAnsi(arena, raw);
            const trimmed = std.mem.trim(u8, line, " \t\r");
            const outcome: ?bool = if (std.mem.startsWith(u8, trimmed, "PASS "))
                true
            else if (std.mem.startsWith(u8, trimmed, "FAIL "))
                false
            else
                null;
            const ok = outcome orelse continue;
            const name = std.mem.trim(u8, trimmed[5..], " ");
            const key = try std.fmt.allocPrint(arena, "{s}::{s}", .{ file, name });
            // A name may repeat inside a file. A single failure counts.
            const gop = try results.getOrPut(arena, key);
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* and ok else ok;
            if (ok) pass += 1 else fail += 1;
        }
        total_pass += pass;
        total_fail += fail;
        // Upstream files end with a "Tests: N | Passed: ..." summary. Files
        // under `set -e` abort at the first failing command and never print it.
        const finished = std.mem.find(u8, result.stdout, "Tests: ") != null;
        std.debug.print("  {s}: {d} pass, {d} fail{s}\n", .{
            file, pass, fail, if (finished) "" else " (aborted early; later tests did not run)",
        });
    }

    // Verdict.
    var required_failed: usize = 0;
    for (expected.keys()) |key| {
        const outcome = results.get(key);
        if (outcome == null) {
            std.debug.print("REQUIRED MISSING: {s}\n", .{key});
            required_failed += 1;
        } else if (!outcome.?) {
            std.debug.print("REQUIRED FAILED: {s}\n", .{key});
            required_failed += 1;
        }
    }
    var newly_passing: usize = 0;
    for (results.keys(), results.values()) |key, ok| {
        if (ok and !expected.contains(key) and !allow.tests.contains(key)) {
            if (newly_passing == 0) std.debug.print(
                "passing but not yet required. Check that each passes for the right reason\n" ++
                    "(not just because a stub rejects everything) before adding it to the\n" ++
                    "expected file:\n",
                .{},
            );
            std.debug.print("  {s}\n", .{key});
            newly_passing += 1;
        }
    }
    std.debug.print(
        "upstream suite: {d} pass, {d} fail overall; required {d}/{d} passing\n",
        .{ total_pass, total_fail, expected.count() - required_failed, expected.count() },
    );
    return if (required_failed == 0) 0 else 1;
}

fn absolute(io: Io, arena: Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    const cwd = try std.process.currentPathAlloc(io, arena);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ cwd, path });
}

fn runChecked(
    io: Io,
    arena: Allocator,
    argv: []const []const u8,
    env: ?*const std.process.Environ.Map,
) !void {
    const result = try std.process.run(arena, io, .{ .argv = argv, .environ_map = env });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("command failed: {s}: {s}\n", .{ argv[0], result.stderr });
        return error.CommandFailed;
    }
}

/// Entries are one per line. `#` starts a comment. Blank lines ignored.
fn readList(io: Io, arena: Allocator, path: []const u8) !std.array_hash_map.String(void) {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024));
    var set: std.array_hash_map.String(void) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, stripComment(raw), " \t\r");
        if (line.len == 0) continue;
        try set.put(arena, line, {});
    }
    return set;
}

const Allowlist = struct {
    tests: std.array_hash_map.String([]const u8) = .empty,
    skip_files: std.array_hash_map.String([]const u8) = .empty,
};

fn readAllowlist(io: Io, arena: Allocator, path: []const u8) !Allowlist {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024));
    var allow: Allowlist = .{};
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const hash = std.mem.findScalar(u8, raw, '#');
        const reason = if (hash) |h| std.mem.trim(u8, raw[h + 1 ..], " \t\r") else "";
        const line = std.mem.trim(u8, stripComment(raw), " \t\r");
        if (line.len == 0) continue;
        if (reason.len == 0) {
            std.debug.print("error: allowlist entry without a reason: '{s}'\n", .{line});
            return error.AllowlistEntryWithoutReason;
        }
        if (std.mem.startsWith(u8, line, "skip-file ")) {
            try allow.skip_files.put(
                arena,
                std.mem.trim(u8, line["skip-file ".len..], " "),
                reason,
            );
        } else {
            try allow.tests.put(arena, line, reason);
        }
    }
    return allow;
}

fn stripComment(line: []const u8) []const u8 {
    return if (std.mem.findScalar(u8, line, '#')) |h| line[0..h] else line;
}

/// Removes ANSI CSI sequences (`ESC [ ... letter`).
fn stripAnsi(arena: Allocator, line: []const u8) ![]const u8 {
    if (std.mem.findScalar(u8, line, 0x1b) == null) return line;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            i += 2;
            while (i < line.len and !std.ascii.isAlphabetic(line[i])) i += 1;
            i += 1;
            continue;
        }
        try out.append(arena, line[i]);
        i += 1;
    }
    return out.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

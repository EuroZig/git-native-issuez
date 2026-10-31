//! Both tools on the same repositories: upstream git-native-issue (shell
//! scripts) and git-native-issuez (this library and its CLI). Every test
//! writes with one and reads with the other. `zig build test-interop`.
//!
//! Upstream is fetched lazily and never vendored. The helpers at the top
//! make throwaway repositories and run either tool in them, so each test
//! reads like a terminal session:
//!
//!     try repo.ours("comment {s} -m 'Repro on Firefox'", .{id});

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const issuez = @import("issuez");
const paths = @import("paths");
const oracle = @import("oracle");

const GitProcess = issuez.backend.GitProcess;
const object = issuez.backend.object;
const Oid = object.Oid;
const Repo = issuez.Repo(GitProcess);

const io = testing.io;

const Output = struct { stdout: []const u8, stderr: []const u8, code: u8 };

/// A scratch directory for repositories. Git sees a fixed identity and no
/// user or system config, so results don't depend on the machine.
const Sandbox = struct {
    tmp: testing.TmpDir,
    root: []const u8,
    /// Holds our binary as `git-issue`, to put first on PATH.
    ours_bin: []const u8,
    env: std.process.Environ.Map,
    arena_state: std.heap.ArenaAllocator,

    fn init() !Sandbox {
        var sb: Sandbox = .{
            .tmp = testing.tmpDir(.{}),
            .root = undefined,
            .ours_bin = undefined,
            .env = try testing.environ.createMap(testing.allocator),
            .arena_state = .init(testing.allocator),
        };
        errdefer sb.deinit();
        const arena = sb.allocator();
        const cwd = try std.process.currentPathAlloc(io, arena);
        sb.root = try sb.tmp.dir.realPathFileAlloc(io, ".", arena);

        try sb.env.put("GIT_CONFIG_NOSYSTEM", "1");
        try sb.env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try sb.env.put("GIT_AUTHOR_NAME", "Interop Tester");
        try sb.env.put("GIT_AUTHOR_EMAIL", "interop@example.invalid");
        try sb.env.put("GIT_COMMITTER_NAME", "Interop Tester");
        try sb.env.put("GIT_COMMITTER_EMAIL", "interop@example.invalid");

        sb.ours_bin = try std.fmt.allocPrint(arena, "{s}/ours-bin", .{sb.root});
        try std.Io.Dir.cwd().createDirPath(io, sb.ours_bin);
        // The build may hand us a cache-relative path. A relative symlink
        // target would resolve against the link's directory instead.
        const target = if (std.fs.path.isAbsolute(paths.git_issue_exe))
            paths.git_issue_exe
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ cwd, paths.git_issue_exe });
        const link = try std.fmt.allocPrint(arena, "{s}/git-issue", .{sb.ours_bin});
        try std.Io.Dir.cwd().symLink(io, target, link, .{});
        return sb;
    }

    fn deinit(sb: *Sandbox) void {
        sb.env.deinit();
        sb.arena_state.deinit();
        sb.tmp.cleanup();
    }

    fn allocator(sb: *Sandbox) Allocator {
        return sb.arena_state.allocator();
    }

    const RepoOptions = struct {
        /// Extra `git init` flags, such as `--object-format=sha256`.
        init_flags: []const []const u8 = &.{},
        /// The `origin` remote.
        origin: ?[]const u8 = null,
    };

    /// A new repository with one empty commit.
    fn repo(sb: *Sandbox, name: []const u8, options: RepoOptions) !Clone {
        const path = try std.fmt.allocPrint(sb.allocator(), "{s}/{s}", .{ sb.root, name });
        _ = try sb.git(sb.root, try std.mem.concat(sb.allocator(), []const u8, &.{
            &.{ "init", "-q" }, options.init_flags, &.{path},
        }));
        const clone: Clone = .{ .sb = sb, .path = path };
        _ = try clone.git("commit -q --allow-empty -m initial", .{});
        if (options.origin) |url| _ = try clone.git("remote add origin {s}", .{url});
        return clone;
    }

    /// A bare repository for clones to push to and fetch from.
    fn hub(sb: *Sandbox, name: []const u8, init_flags: []const []const u8) ![]const u8 {
        const path = try std.fmt.allocPrint(sb.allocator(), "{s}/{s}", .{ sb.root, name });
        _ = try sb.git(sb.root, try std.mem.concat(sb.allocator(), []const u8, &.{
            &.{ "init", "-q", "--bare" }, init_flags, &.{path},
        }));
        return path;
    }

    fn exec(
        sb: *Sandbox,
        cwd: []const u8,
        argv: []const []const u8,
        env: *const std.process.Environ.Map,
    ) !Output {
        const result = try std.process.run(sb.allocator(), io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .environ_map = env,
        });
        const code: u8 = switch (result.term) {
            .exited => |c| c,
            else => 255,
        };
        return .{ .stdout = result.stdout, .stderr = result.stderr, .code = code };
    }

    /// `git <args>`, which has to succeed. Returns stdout without the final
    /// newline.
    fn git(sb: *Sandbox, cwd: []const u8, args: []const []const u8) ![]const u8 {
        const argv = try std.mem.concat(sb.allocator(), []const u8, &.{ &.{"git"}, args });
        const out = try succeed(sb.allocator(), argv, try sb.exec(cwd, argv, &sb.env));
        return std.mem.trimEnd(u8, out, "\n");
    }
};

/// Splits a command line into words the way a shell would, without its
/// expansions: `'...'` or `"..."` quote a word with spaces or an empty one.
fn split(arena: Allocator, line: []const u8) ![]const []const u8 {
    var it = try std.process.Args.IteratorGeneral(.{ .single_quotes = true }).init(arena, line);
    var words: std.ArrayList([]const u8) = .empty;
    while (it.next()) |word| try words.append(arena, word);
    return words.items;
}

const Tool = enum { ours, upstream };

/// One repository, and both tools to run in it.
///
/// Commands are written as they would be typed: `command` is formatted
/// with `args`, then split into words. Formatted values are split as well,
/// so pass IDs and flags through `args`, and write text into `command`.
const Clone = struct {
    sb: *Sandbox,
    path: []const u8,
    /// Author and committer date of everything written, so merges are
    /// reproducible. Unset, git uses the current time.
    date: ?[]const u8 = null,

    /// `git issue <command>` with our CLI, which has to succeed.
    fn ours(c: Clone, comptime command: []const u8, args: anytype) !void {
        _ = try c.read(.ours, command, args);
    }

    /// `git issue <command>` with upstream's, which has to succeed.
    fn upstream(c: Clone, comptime command: []const u8, args: anytype) !void {
        _ = try c.read(.upstream, command, args);
    }

    /// `git issue <command>` with `tool`, which has to succeed. Returns
    /// stdout.
    fn read(c: Clone, tool: Tool, comptime command: []const u8, args: anytype) ![]const u8 {
        const argv = try c.words(command, args);
        return succeed(c.sb.allocator(), argv, try c.runArgv(tool, argv));
    }

    /// `git issue <command>` with `tool`, whatever the outcome.
    fn run(c: Clone, tool: Tool, comptime command: []const u8, args: anytype) !Output {
        return c.runArgv(tool, try c.words(command, args));
    }

    /// `git issue <args...>` with `tool` first on PATH, for arguments that
    /// can't be written as a command line.
    fn runArgv(c: Clone, tool: Tool, args: []const []const u8) !Output {
        const arena = c.sb.allocator();
        var env = try c.sb.env.clone(testing.allocator);
        defer env.deinit();
        const bin = switch (tool) {
            .ours => c.sb.ours_bin,
            .upstream => paths.upstream_bin,
        };
        const path = env.get("PATH") orelse "/usr/bin:/bin";
        try env.put("PATH", try std.fmt.allocPrint(arena, "{s}:{s}", .{ bin, path }));
        if (c.date) |date| {
            try env.put("GIT_AUTHOR_DATE", date);
            try env.put("GIT_COMMITTER_DATE", date);
            try env.put("LC_ALL", "C"); // upstream sorts labels with sort(1)
        }
        const argv = try std.mem.concat(arena, []const u8, &.{ &.{ "git", "issue" }, args });
        return c.sb.exec(c.path, argv, &env);
    }

    /// The same clone, writing with a fixed date ("1700000000 +0000").
    fn at(c: Clone, date: []const u8) Clone {
        var dated = c;
        dated.date = date;
        return dated;
    }

    /// `git issue create <command>` with `tool`. Returns the short ID.
    fn create(c: Clone, tool: Tool, comptime command: []const u8, args: anytype) ![]const u8 {
        const out = try c.read(tool, "create " ++ command, args);
        // Both tools print "Created issue <short id>".
        const line = std.mem.trimEnd(u8, out, "\n");
        return line[line.len - 7 ..];
    }

    /// `git <command>`, which has to succeed. Returns stdout without the
    /// final newline.
    fn git(c: Clone, comptime command: []const u8, args: anytype) ![]const u8 {
        return c.sb.git(c.path, try c.words(command, args));
    }

    /// Any program, run in this repository.
    fn exec(c: Clone, argv: []const []const u8) !Output {
        return c.sb.exec(c.path, argv, &c.sb.env);
    }

    /// The repository as the library sees it. Close it when done.
    fn open(c: Clone) !GitProcess {
        return GitProcess.open(io, testing.allocator, .{
            .path = c.path,
            .environ_map = &c.sb.env,
        });
    }

    fn words(c: Clone, comptime command: []const u8, args: anytype) ![]const []const u8 {
        const arena = c.sb.allocator();
        return split(arena, try std.fmt.allocPrint(arena, command, args));
    }
};

fn succeed(arena: Allocator, argv: []const []const u8, out: Output) ![]const u8 {
    if (out.code != 0) {
        std.debug.print("'{s}' failed ({d}):\n{s}{s}\n", .{
            try std.mem.join(arena, " ", argv), out.code, out.stdout, out.stderr,
        });
        return error.CommandFailed;
    }
    return out.stdout;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, haystack, needle) == null) {
        std.debug.print("expected \"{s}\" in:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

fn expectLacks(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, haystack, needle) != null) {
        std.debug.print("unexpected \"{s}\" in:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedContains;
    }
}

/// Runs `git issue <command>` with both tools and expects the same stdout.
/// Returns it.
fn expectSameStdout(c: Clone, comptime command: []const u8, args: anytype) ![]const u8 {
    const ours = try c.run(.ours, command, args);
    const theirs = try c.run(.upstream, command, args);
    testing.expectEqualStrings(theirs.stdout, ours.stdout) catch |err| {
        const line = try std.fmt.allocPrint(c.sb.allocator(), command, args);
        std.debug.print("stdout differs for 'git issue {s}' in {s}\n", .{ line, c.path });
        return err;
    };
    return ours.stdout;
}

/// Looks an issue up by a unique ID prefix, as `git issue show a7f3` does.
fn findIssue(issues: Repo, arena: Allocator, prefix: []const u8) !issuez.engine.IssueRef {
    return switch (try issues.resolve(arena, prefix)) {
        .one => |ref| ref,
        .none => error.IssueNotFound,
        .many => error.AmbiguousPrefix,
    };
}

test "we read upstream's issues" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const arena = sb.allocator();
    const repo = try sb.repo("repo", .{});

    // Upstream writes an issue and a comment.
    const id = try repo.create(.upstream, "'Upstream made this' -l bug -p high -m Body", .{});
    try repo.upstream("comment {s} -m 'A comment from upstream'", .{id});

    // The library reads it like any issue of its own.
    var git = try repo.open();
    defer git.close();
    const issues = Repo.init(&git);
    const ref = try findIssue(issues, arena, id);
    const issue = try issues.load(arena, ref);

    try testing.expectEqualStrings("Upstream made this", issue.title);
    try testing.expectEqualStrings("Body", issue.description);
    try testing.expectEqualStrings("open", issue.state.text());
    try testing.expectEqual(@as(usize, 1), issue.labels.len);
    try testing.expectEqualStrings("bug", issue.labels[0]);
    try testing.expectEqualStrings("high", issue.field("Priority").?);
    try testing.expectEqualStrings("Interop Tester", issue.author.name);
    try testing.expectEqual(@as(usize, 1), issue.comments.len);
    try testing.expectEqualStrings("A comment from upstream", issue.comments[0].subject);
    // Valid format 1 by our own check, too.
    try testing.expectEqual(@as(usize, 0), (try issues.check(arena, ref)).len);
}

test "upstream reads our issues" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const arena = sb.allocator();
    const repo = try sb.repo("repo", .{});

    // The library writes an issue, comments on it and closes it.
    var git = try repo.open();
    defer git.close();
    const issues = Repo.init(&git);
    const created = try issues.create(arena, .{
        .title = "Written by git-native-issuez",
        .body = "Created through the library.",
        .labels = &.{ "interop", "p0" },
        .priority = .medium,
    });
    const id = created.id.short();
    const ref = try findIssue(issues, arena, id);
    _ = try issues.comment(arena, ref.name, .{ .text = "Reproduced on main." });
    _ = try issues.setState(arena, ref.name, .{ .state = .closed, .fixed_by = "abc1234" });

    // Upstream lists, shows and checks it.
    try expectContains(try repo.read(.upstream, "ls -s closed", .{}), id);
    const shown = try repo.read(.upstream, "show {s}", .{id});
    try expectContains(shown, "Written by git-native-issuez");
    try expectContains(shown, "Created through the library.");
    try expectContains(shown, "Reproduced on main.");
    try expectContains(shown, "interop, p0");
    try repo.upstream("fsck", .{});

    // Upstream adds to it, and the library sees that on top.
    try repo.upstream("comment {s} -m 'Upstream replies'", .{id});
    const issue = try issues.load(arena, try findIssue(issues, arena, id));
    try testing.expectEqualStrings("closed", issue.state.text());
    try testing.expectEqual(@as(usize, 3), issue.comments.len);
    try testing.expectEqualStrings("Upstream replies", issue.comments[2].subject);
}

test "top-level dispatcher parity with upstream" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const arena = sb.allocator();
    const repo = try sb.repo("repo", .{});

    // Through git, as people type it: git finds our `git-issue` on PATH.
    const version = try repo.read(.ours, "version", .{});
    try testing.expect(std.mem.startsWith(u8, version, "git-issue version "));
    try expectLacks(version, "1.3.3"); // upstream's version number

    // Each tool's `git-issue` directly from here on: git itself turns
    // `git issue --help` into `git help issue`.
    const Expect = enum { usage, version, unknown_command };
    const cases = [_]struct { args: []const u8, expect: Expect }{
        .{ .args = "", .expect = .usage },
        .{ .args = "--help", .expect = .usage },
        .{ .args = "-h", .expect = .usage },
        .{ .args = "version", .expect = .version },
        .{ .args = "--version", .expect = .version },
        .{ .args = "-v", .expect = .version },
        .{ .args = "frobnicate", .expect = .unknown_command },
    };
    for (cases) |case| {
        const args = try split(arena, case.args);
        const ours_exe = try std.fmt.allocPrint(arena, "{s}/git-issue", .{sb.ours_bin});
        const ours = try repo.exec(try std.mem.concat(arena, []const u8, &.{ &.{ours_exe}, args }));
        const upstream_exe = try std.fmt.allocPrint(arena, "{s}/git-issue", .{paths.upstream_bin});
        const theirs = try repo.exec(
            try std.mem.concat(arena, []const u8, &.{ &.{upstream_exe}, args }),
        );

        testing.expectEqual(theirs.code, ours.code) catch |err| {
            std.debug.print("exit code differs for '{s}'\n", .{case.args});
            return err;
        };
        switch (case.expect) {
            // Both on stdout, same first line. The command lists differ.
            .usage => for ([_]Output{ ours, theirs }) |out| {
                try testing.expect(std.mem.startsWith(u8, out.stdout, "usage: git issue "));
            },
            // Same prefix, each tool's own version number.
            .version => for ([_]Output{ ours, theirs }) |out| {
                try testing.expect(std.mem.startsWith(u8, out.stdout, "git-issue version "));
            },
            // Upstream's exact error line is the contract.
            .unknown_command => {
                try testing.expectEqualStrings(theirs.stderr, ours.stderr);
                try testing.expectEqualStrings("", ours.stdout);
            },
        }
    }
}

/// `show` reduced to what both tools must print identically: of the header,
/// the lines upstream always prints (our extra fields, and the ones upstream
/// drops after later updates, are improvements). The rest verbatim.
fn commonShow(arena: Allocator, text: []const u8) ![]const u8 {
    const common_header = [_][]const u8{
        "Issue ", "=====", "Title:", "Author:", "Created:", "Labels:",
    };
    var out: std.ArrayList(u8) = .empty;
    var in_header = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) in_header = false;
        if (in_header) {
            const keep = for (common_header) |p| {
                if (std.mem.startsWith(u8, line, p)) break true;
            } else false;
            if (!keep) continue;
        }
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    return out.items;
}

/// Both tools list, filter, sort and show the issues the same way.
fn expectSameReads(repo: Clone, ids: []const []const u8) !void {
    const arena = repo.sb.allocator();
    const reads = [_][]const u8{
        "ls",
        "ls --all",
        "ls -a -f full",
        "ls -a -f oneline",
        "ls -s closed",
        "ls -a --sort priority",
        "ls -a --sort updated --reverse",
        "ls -a -l bug",
        "ls -a --priority high",
        "fsck",
    };
    for (reads) |command| {
        const args = try split(arena, command);
        const ours = try repo.runArgv(.ours, args);
        const theirs = try repo.runArgv(.upstream, args);
        // Upstream's `ls -f full` exits 1 when the last row has no detail
        // line (its bug). Ours exits 0. Only the output is compared then.
        const upstream_full_bug = std.mem.find(u8, command, "full") != null and
            theirs.code == 1 and ours.code == 0;
        if (!upstream_full_bug) testing.expectEqual(theirs.code, ours.code) catch |err| {
            std.debug.print("exit codes differ for 'git issue {s}'\n", .{command});
            return err;
        };
        testing.expectEqualStrings(theirs.stdout, ours.stdout) catch |err| {
            std.debug.print("stdout differs for 'git issue {s}'\n", .{command});
            return err;
        };
    }
    for (ids) |id| {
        const ours = try repo.read(.ours, "show {s}", .{id});
        const theirs = try repo.read(.upstream, "show {s}", .{id});
        try testing.expectEqualStrings(try commonShow(arena, theirs), try commonShow(arena, ours));
    }
}

test "round trip" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const repo = try sb.repo("repo", .{});

    // Our CLI writes one issue...
    const a = try repo.create(.ours, "'Crash on login' -l bug -l auth -a bob@e.x -p high" ++
        " --milestone v1 -m 'First paragraph.' -m 'Second\nparagraph'", .{});
    try repo.ours("comment {s} -m 'Repro on Firefox' -m Detail", .{a});
    try repo.ours("state {s} --close -m Fixed --fixed-by abc1234 --reason completed", .{a});
    try repo.ours("edit {s} --add-label regression -p critical -t 'Crash on login page'", .{a});

    // ...and upstream another.
    const b = try repo.create(.upstream, "'Made upstream' -l ui -p low -m Desc", .{});
    try repo.upstream("comment {s} -m 'upstream comment'", .{b});
    try repo.upstream("edit {s} -l ui -l bug -a carol@e.x", .{b});
    try repo.upstream("state {s} --state wontfix", .{b});

    // Each tool continues on the other's issue.
    try repo.ours("comment {s} -m \"ours on upstream's issue\"", .{b});
    try repo.upstream("comment {s} -m 'upstream on our issue'", .{a});
    try repo.ours("state {s} --open", .{b});

    try expectSameReads(repo, &.{ a, b });

    // Ours keeps the fields upstream's show drops after later updates.
    const shown = try repo.read(.ours, "show {s}", .{a});
    try expectContains(shown, "Assignee: bob@e.x");
    try expectContains(shown, "Milestone: v1");
    try expectContains(shown, "Fixed-By: abc1234");
    try expectContains(try repo.read(.ours, "show {s}", .{b}), "Assignee: carol@e.x");

    // Upstream's integrity check accepts everything we wrote.
    try repo.upstream("fsck", .{});
}

test "clearing fields" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const repo = try sb.repo("repo", .{});

    const a = try repo.create(.upstream, "'To clear' -l bug -a a@e.x", .{});
    try repo.upstream("edit {s} -a ''", .{a});
    try repo.upstream("edit {s} --remove-label bug", .{a});

    // Upstream's `ls -f full` exits 1 when the last row has no details (its
    // bug), so only its output counts here.
    const ours_full = try repo.read(.ours, "ls -f full", .{});
    const upstream_full = (try repo.run(.upstream, "ls -f full", .{})).stdout;
    // Both drop the assignee.
    try expectLacks(ours_full, "assignee:");
    try expectLacks(upstream_full, "assignee:");
    // An explicit empty `Labels:` clears the labels for us. Upstream skips
    // empty values and still shows "bug" (a documented difference).
    try expectLacks(ours_full, "labels:");
    try expectContains(upstream_full, "labels:bug");

    // Our own clears are written so that upstream sees them too (`Assignee: `).
    const b = try repo.create(.ours, "'Ours to clear' -a b@e.x", .{});
    try repo.ours("edit {s} -a ''", .{b});
    try expectLacks((try repo.run(.upstream, "ls -f full", .{})).stdout, "assignee:b@e.x");
}

test "messages upstream mangles stay intact with ours" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const repo = try sb.repo("repo", .{});

    // A `---` line in the description: upstream's create would hide every
    // trailer. Ours keeps them readable by both tools.
    const id = try repo.create(.ours, "Dashes -l bug -p high -m 'Intro\n---\nMore'", .{});
    try expectContains(try repo.read(.upstream, "ls -f full", .{}), "labels:bug priority:high");
    try expectContains(try repo.read(.ours, "show {s}", .{id}), "Intro\n---\nMore");

    // A comment whose last paragraph would read as metadata is refused.
    const refused = try repo.run(.ours, "comment {s} -m 'I agree.' -m 'X-Deleted: true'", .{id});
    try testing.expectEqual(@as(u8, 1), refused.code);
}

test "sync with upstream" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    // `a` works with our CLI, `b` with upstream's, both through one hub.
    const hub = try sb.hub("hub.git", &.{});
    const a = try sb.repo("a", .{ .origin = hub });
    const b = try sb.repo("b", .{ .origin = hub });

    // a creates and pushes, b merges it in.
    const id = try a.create(.ours, "Shared -l bug -p low", .{});
    try a.ours("push origin", .{});
    try b.upstream("merge origin", .{});

    // Round 1, resolved by our merge: b edits and pushes, a comments
    // locally, then syncs and writes a merge commit.
    try b.upstream("edit {s} -p high --add-label ui", .{id});
    _ = try b.git("push -q origin refs/issues/*:refs/issues/*", .{});
    try a.ours("comment {s} -m 'from ours'", .{id});
    try expectContains(try a.read(.ours, "sync origin", .{}), "Merged ");
    // b fast-forwards onto our merge commit.
    try expectContains(try b.read(.upstream, "merge origin", .{}), "Fast-forwarded");

    // Round 2, resolved by upstream's merge: a edits and pushes, b comments
    // locally, merges and pushes.
    try a.ours("edit {s} -a alice@e.x --remove-label bug", .{id});
    try a.ours("push origin", .{});
    try b.upstream("comment {s} -m 'from upstream'", .{id});
    try expectContains(try b.read(.upstream, "merge origin", .{}), "Merged ");
    _ = try b.git("push -q origin refs/issues/*:refs/issues/*", .{});
    try expectContains(try a.read(.ours, "sync origin", .{}), "Fast-forwarded");

    // Both clones hold the same tip, and both tools read the same state.
    for ([_]Clone{ a, b }) |clone| {
        const listed = try expectSameStdout(clone, "ls -a -f full", .{});
        try expectContains(listed, "labels:ui assignee:alice@e.x priority:high");
        try clone.upstream("fsck", .{});
        try clone.ours("fsck", .{});

        // The history has merge commits from both tools, and `show` counts
        // and prints the same updates (upstream: rev-list <root>..<tip>).
        const ours_show = try clone.read(.ours, "show {s}", .{id});
        const upstream_show = try clone.read(.upstream, "show {s}", .{id});
        const ours_updates = ours_show[std.mem.find(u8, ours_show, "Updates (").?..];
        const upstream_updates = upstream_show[std.mem.find(u8, upstream_show, "Updates (").?..];
        try testing.expectEqualStrings(upstream_updates, ours_updates);
        try expectContains(ours_updates, "  Merge issue\n");
        try expectContains(ours_updates, "  Merge issue from origin\n");
    }
    const shown = try a.read(.ours, "show {s}", .{id});
    try expectContains(shown, "from ours");
    try expectContains(shown, "from upstream");
    try expectLacks(shown, "Conflict:");
}

test "quarantine" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const hub = try sb.hub("hub.git", &.{});
    const repo = try sb.repo("repo", .{ .origin = hub });

    // A local issue, and an unrelated commit under the same ref on the hub,
    // as a broken tool might push it.
    _ = try repo.create(.ours, "'Local version'", .{});
    const ref = try repo.git("for-each-ref --format=%(refname) refs/issues/", .{});
    const empty_tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
    const impostor = try repo.git(
        "commit-tree {s} -m 'Impostor\n\nState: open\nFormat-Version: 1'",
        .{empty_tree},
    );
    _ = try repo.git("push -q origin {s}:{s}", .{ impostor, ref });
    const local_tip = try repo.git("rev-parse {s}", .{ref});

    // merge sets the stranger aside and keeps the local issue...
    const merged = try repo.run(.ours, "merge origin", .{});
    try testing.expectEqual(@as(u8, 0), merged.code);
    try expectContains(merged.stderr, "Quarantined");
    try expectContains(merged.stdout, "1 quarantined");
    try testing.expectEqualStrings(local_tip, try repo.git("rev-parse {s}", .{ref}));

    // ...and push leaves the hub's version alone.
    const pushed = try repo.run(.ours, "push origin", .{});
    try testing.expectEqual(@as(u8, 0), pushed.code);
    try expectContains(pushed.stderr, "quarantined");
    const hub_tip = try repo.git("--git-dir {s} rev-parse {s}", .{ hub, ref });
    try testing.expectEqualStrings(impostor, hub_tip);
}

test "email validation" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const arena = sb.allocator();
    const repo = try sb.repo("repo", .{});

    // Every string up to length 5 over the characters the checks look at,
    // plus hand-picked shapes with other characters.
    var cases: std.ArrayList([]const u8) = .empty;
    const alphabet = "a@.";
    for (1..6) |len| {
        const count = std.math.pow(usize, alphabet.len, len);
        for (0..count) |index| {
            const s = try arena.alloc(u8, len);
            var rest = index;
            for (s) |*c| {
                c.* = alphabet[rest % alphabet.len];
                rest /= alphabet.len;
            }
            try cases.append(arena, s);
        }
    }
    try cases.appendSlice(arena, &.{
        "user@example.com", "first.last@sub.example.co.uk", "a+tag@b.c",
        "a@b@c.d",          "a.b@c",                        "@example.com",
        "user@.com",        "user@com.",                    "user@example",
        "user example@x.y", " a@b.c",                       "a@b.c ",
        "ü@exämple.de",
        "a@b..c",           "a@@b.c",                       "a@.b.c",
        "a@b.",             "a@b.c.",
    });

    const lib = try std.fmt.allocPrint(arena, "{s}/git-issue-lib", .{paths.upstream_bin});
    for (cases.items) |email| {
        // Upstream: the real validate_email from its git-issue-lib.
        const theirs = try repo.exec(&.{
            "sh", "-c", ". \"$0\" && validate_email \"$1\" assignee", lib, email,
        });
        // Ours: validation runs before the issue is looked up, so a valid
        // address ends in "not found" and nothing is written.
        const ours = try repo.runArgv(.ours, &.{ "edit", "ffff", "-a", email });

        const upstream_ok = theirs.code == 0;
        const ours_ok = !std.mem.startsWith(u8, ours.stderr, "error: assignee");
        if (upstream_ok != ours_ok or (!ours_ok and !std.mem.eql(u8, theirs.stderr, ours.stderr))) {
            const verdict = [_][]const u8{ "rejects", "accepts" };
            std.debug.print("email '{s}': upstream {s} \"{s}\", ours {s} \"{s}\"\n", .{
                email,
                verdict[@intFromBool(upstream_ok)],
                std.mem.trimEnd(u8, theirs.stderr, "\n"),
                verdict[@intFromBool(ours_ok)],
                std.mem.trimEnd(u8, ours.stderr, "\n"),
            });
            return error.EmailValidationDiffers;
        }
    }
}

test "sha256 and reftable" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const arena = sb.allocator();

    const version = try sb.git(sb.root, &.{"version"});
    const reftable_ok = if (GitProcess.parseGitVersion(version)) |v|
        v.order(.{ .major = 2, .minor = 45, .patch = 0 }) != .lt
    else
        false;

    const formats = [_]struct { name: []const u8, flag: []const u8, needs_reftable: bool }{
        .{ .name = "sha256", .flag = "--object-format=sha256", .needs_reftable = false },
        .{ .name = "reftable", .flag = "--ref-format=reftable", .needs_reftable = true },
    };
    for (formats) |f| {
        if (f.needs_reftable and !reftable_ok) continue;
        const hub = try sb.hub(try std.fmt.allocPrint(arena, "{s}-hub.git", .{f.name}), &.{f.flag});
        const a = try sb.repo(try std.fmt.allocPrint(arena, "{s}-a", .{f.name}), .{
            .init_flags = &.{f.flag},
            .origin = hub,
        });
        const b = try sb.repo(try std.fmt.allocPrint(arena, "{s}-b", .{f.name}), .{
            .init_flags = &.{f.flag},
            .origin = hub,
        });

        // Created by us, changed by both tools in one clone.
        const id = try a.create(.ours, "'Format test' -l bug", .{});
        try a.upstream("comment {s} -m 'From upstream'", .{id});
        try a.ours("edit {s} -p high", .{id});
        try a.ours("push origin", .{});

        // The other clone gets it with upstream's merge, closes it, pushes.
        try b.upstream("merge origin", .{});
        try b.upstream("state {s} --close", .{id});
        _ = try b.git("push -q origin refs/issues/*:refs/issues/*", .{});
        try expectContains(try a.read(.ours, "sync origin", .{}), "Fast-forwarded");

        for ([_]Clone{ a, b }) |clone| {
            const listed = try expectSameStdout(clone, "ls -a -f full", .{});
            try expectContains(listed, "[closed] Format test");
            try clone.upstream("fsck", .{});
            try clone.ours("fsck", .{});
        }
        if (std.mem.eql(u8, f.name, "sha256")) {
            // Real SHA-256 object IDs end to end.
            const tip = try a.git("for-each-ref --format=%(objectname) refs/issues/", .{});
            try testing.expectEqual(@as(usize, 64), tip.len);
        }
    }
}

/// What upstream's `merge` will write for the clone's one issue, by the
/// oracle's model of it: fetches the hub's version and predicts the merge
/// commit message. Also returns both parents.
fn predictUpstreamMerge(
    clone: Clone,
    git: *GitProcess,
) !struct { message: []const u8, local: Oid, remote: Oid, ref: []const u8 } {
    const arena = clone.sb.allocator();
    _ = try clone.git("fetch -q origin +refs/issues/*:refs/remotes/origin/issues/*", .{});
    const local = (try git.listRefs(arena, "refs/issues/"))[0];
    const remote_ref = try std.fmt.allocPrint(
        arena,
        "refs/remotes/origin/issues/{s}",
        .{local.name["refs/issues/".len..]},
    );
    const remote = (try git.resolveRef(remote_ref)).?;
    const message = try oracle.upstream.mergeMessage(arena, git, local.oid, remote, "origin");
    return .{ .message = message, .local = local.oid, .remote = remote, .ref = local.name };
}

test "upstream merge model" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const arena = sb.allocator();

    // Each case edits one issue in two clones at once, then upstream merges
    // them. The oracle's model of upstream's merge has to predict the merge
    // commit exactly.
    const Case = struct {
        name: []const u8,
        /// Edit flags and date, in clone a and b.
        a: []const u8,
        a_at: []const u8,
        b: []const u8,
        b_at: []const u8,
    };
    const cases = [_]Case{
        .{
            .name = "labels three-way, scalars one- and two-sided",
            .a = "--add-label c -p high",
            .b = "--remove-label a -p medium -a bob@e.x",
            .a_at = "1700000100 +0000",
            .b_at = "1700000200 +0000",
        },
        .{
            .name = "both changed at the same second: commit ID decides",
            .a = "-p critical --milestone v1",
            .b = "-p low --milestone v2",
            .a_at = "1700000300 +0000",
            .b_at = "1700000300 +0000",
        },
        .{
            .name = "local is newer",
            .a = "-a carol@e.x",
            .b = "-a dave@e.x --add-label z",
            .a_at = "1700000500 +0000",
            .b_at = "1700000400 +0000",
        },
    };
    for (cases, 0..) |case, n| {
        const hub = try sb.hub(try std.fmt.allocPrint(arena, "m{d}-hub.git", .{n}), &.{});
        const a = (try sb.repo(try std.fmt.allocPrint(arena, "m{d}-a", .{n}), .{ .origin = hub }))
            .at("1700000000 +0000");
        const b = (try sb.repo(try std.fmt.allocPrint(arena, "m{d}-b", .{n}), .{ .origin = hub }))
            .at("1700000000 +0000");
        const id = try a.create(.ours, "Merged -l a -l b -p low", .{});
        try a.ours("push origin", .{});
        try b.ours("merge origin", .{});

        // Concurrent edits; b's reaches the hub first.
        try a.at(case.a_at).ours("edit {s} {s}", .{ id, case.a });
        try b.at(case.b_at).ours("edit {s} {s}", .{ id, case.b });
        try b.at(case.b_at).ours("push origin", .{});

        var git = try a.open();
        defer git.close();
        const predicted = try predictUpstreamMerge(a, &git);

        // Upstream merges for real.
        const merged = try a.at("1700000900 +0000").read(.upstream, "merge origin", .{});
        try expectContains(merged, "Merged ");
        const tip = (try git.resolveRef(predicted.ref)).?;
        const merge = try object.Commit.parse(
            arena,
            git.objectFormat(),
            (try git.readObject(arena, tip)).?.data,
        );
        testing.expectEqualStrings(predicted.message, merge.message) catch |err| {
            std.debug.print("case: {s}\n", .{case.name});
            return err;
        };
        try testing.expectEqual(@as(usize, 2), merge.parents.len);
        try testing.expect(merge.parents[0].eql(predicted.local));
        try testing.expect(merge.parents[1].eql(predicted.remote));
    }
}

test "extension fields survive upstream" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const hub = try sb.hub("hub.git", &.{});
    const a = (try sb.repo("a", .{ .origin = hub })).at("1700000000 +0000");
    const b = (try sb.repo("b", .{ .origin = hub })).at("1700000000 +0000");

    // Our CLI writes an issue with every planning field.
    const epic = try a.create(.ours, "Epic", .{});
    const blocker = try a.create(.ours, "Blocker", .{});
    const id = try a.create(.ours, "Child -l bug --parent {s} --blocked-by {s}" ++
        " --due 2026-12-01 --estimate 2h --workflow ready", .{ epic, blocker });
    try a.ours("push origin", .{});
    try b.upstream("merge origin", .{});

    // Upstream changes it in both clones, so its next merge diverges.
    try a.at("1700000100 +0000").upstream("comment {s} -m 'From a'", .{id});
    try a.at("1700000110 +0000").upstream("edit {s} -p high", .{id});
    try b.at("1700000120 +0000").upstream("state {s} --close", .{id});
    _ = try b.git("push -q origin refs/issues/*:refs/issues/*", .{});
    const merged = try a.at("1700000200 +0000").read(.upstream, "merge origin", .{});
    try expectContains(merged, "Merged ");

    // Our fields come through upstream's edits and merge.
    const shown = try a.read(.ours, "show {s}", .{id});
    for ([_][]const u8{
        "[closed]",        "Priority: high", "Due:     2026-12-01", "Estimate: 120 min (2h)",
        "Workflow: ready", "Parent:  ",      "Blocked by: ",
    }) |want| try expectContains(shown, want);
    try a.upstream("fsck", .{});
}

test "lifecycle events" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const repo = (try sb.repo("repo", .{})).at("1700000000 +0000");

    const id = try repo.create(.ours, "Events", .{});
    try repo.ours("comment {s} -m Tpyo", .{id});
    // The comment is the issue's tip right now.
    const comment = try repo.git("for-each-ref --format=%(objectname:short=8) refs/issues/", .{});
    try repo.ours("comment {s} --edit {s} -m 'Typo fixed'", .{ id, comment });
    try repo.ours("edit {s} --description 'Described now.'", .{id});
    try repo.ours("delete {s}", .{id});

    // Upstream: still a valid issue. The events read as ordinary updates.
    try repo.upstream("fsck", .{});
    const upstream_show = try repo.read(.upstream, "show {s}", .{id});
    try expectContains(upstream_show, "Edit comment ");
    try expectContains(upstream_show, "Edit description");
    try expectContains(upstream_show, "Delete issue");

    // An upstream comment afterwards doesn't undo any of it.
    try repo.upstream("comment {s} -m 'From upstream'", .{id});
    const shown = try repo.read(.ours, "show {s}", .{id});
    for ([_][]const u8{ "(deleted)", "Described now.", "Typo fixed", "From upstream" }) |want| {
        try expectContains(shown, want);
    }
    try expectLacks(shown, "Tpyo");
    try testing.expectEqualStrings("", try repo.read(.ours, "ls", .{}));
}

test "attachments" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const hub = try sb.hub("hub.git", &.{});
    // a uses both tools. b uses upstream only, whose refspec doesn't fetch
    // refs/attachments/*.
    const a = (try sb.repo("a", .{ .origin = hub })).at("1700000000 +0000");
    const b = (try sb.repo("b", .{ .origin = hub })).at("1700000000 +0000");
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(sb.allocator(), "{s}/shot.png", .{a.path}),
        .data = issuez.format.attachment.samples.png,
    });

    const id = try a.create(.ours, "Shots", .{});
    try a.ours("comment {s} -m 'Screenshot attached' --attach shot.png", .{id});
    try a.upstream("fsck", .{});
    try a.ours("push origin", .{});

    // Upstream works on it in both clones and merges.
    try b.upstream("merge origin", .{});
    try a.at("1700000100 +0000").upstream("comment {s} -m 'From a'", .{id});
    try b.at("1700000120 +0000").upstream("edit {s} -p high", .{id});
    try b.at("1700000130 +0000").upstream("state {s} --close", .{id});
    _ = try b.git("push -q origin refs/issues/*:refs/issues/*", .{});
    try a.at("1700000200 +0000").upstream("merge origin", .{});
    try a.upstream("fsck", .{});

    // In a, the attachment and its bytes are still there.
    const listed = try a.read(.ours, "attach ls {s}", .{id});
    try expectContains(listed, "image/png");
    try expectContains(listed, "shot.png");
    try expectLacks(listed, "not here");
    try expectContains(try a.read(.upstream, "show {s}", .{id}), "Screenshot attached");

    // In b, the attachment is listed but its bytes and derived ref are
    // missing. fsck notes both, and --repair regenerates the ref.
    try expectContains(try b.read(.ours, "attach ls {s}", .{id}), "(bytes not here)");
    const fsck = try b.run(.ours, "fsck", .{});
    try testing.expectEqual(@as(u8, 0), fsck.code);
    try expectContains(fsck.stderr, "is missing (run 'git issue fsck --repair')");
    try expectContains(try b.read(.ours, "fsck --repair -q", .{}), "repaired refs/attachments/");
    try expectLacks((try b.run(.ours, "fsck -q", .{})).stderr, "--repair");
}

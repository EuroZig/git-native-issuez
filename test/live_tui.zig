//! Live updates in `git-issue tui`, end to end: two TUIs on one
//! repository, each on a pseudo-terminal of its own read into a `Screen`,
//! so the test sees what a user sees. The TUIs, the command line and an
//! MCP server write; every TUI shows what the others did with no key
//! pressed. POSIX only (pseudo-terminals); the paths of `git-issue` and
//! `tty-exec` come in through the `paths` options module.

const std = @import("std");
const testing = std.testing;
const c = std.c;
const paths = @import("paths");
const Sandbox = @import("sandbox.zig");
const Screen = @import("tui_e2e/Screen.zig");

const io = testing.io;
const expectSuccess = Sandbox.expectSuccess;

const rows = 30;
const cols = 120;
/// How long a change may take to show: the watcher, a reload, a frame.
const timeout_ms = 5000;

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;

/// `git issue tui` on a pseudo-terminal.
const Tui = struct {
    name: []const u8,
    /// The terminal's side of the pseudo-terminal.
    master: c.fd_t,
    child: std.process.Child,
    screen: Screen,
    /// The TUI closed its side of the terminal.
    closed: bool = false,
    exited: bool = false,

    fn start(t: *Tui, sb: *Sandbox, name: []const u8) !void {
        return t.startWith(sb, name, &.{ try sb.exe(paths.git_issue_exe), "tui" }, .inherit);
    }

    /// Any program on the pseudo-terminal, in the repository, with its
    /// stderr (where leaks show) at `stderr`.
    fn startWith(
        t: *Tui,
        sb: *Sandbox,
        name: []const u8,
        program: []const []const u8,
        stderr: std.process.SpawnOptions.StdIo,
    ) !void {
        const flags: c.O = .{ .ACCMODE = .RDWR, .NOCTTY = true };
        const master = posix_openpt(@bitCast(flags));
        if (master < 0) return error.OpenPtyFailed;
        errdefer _ = c.close(master);
        if (grantpt(master) != 0 or unlockpt(master) != 0) return error.OpenPtyFailed;
        const tty_name = ptsname(master) orelse return error.OpenPtyFailed;
        const tty = try sb.arena().dupe(u8, std.mem.span(tty_name));

        t.* = .{
            .name = name,
            .master = master,
            .child = try std.process.spawn(io, .{
                .argv = try std.mem.concat(sb.arena(), []const u8, &.{
                    &.{
                        try sb.exe(paths.tty_exec),
                        tty,
                        std.fmt.comptimePrint("{d}", .{rows}),
                        std.fmt.comptimePrint("{d}", .{cols}),
                    },
                    program,
                }),
                .cwd = .{ .path = sb.repo },
                .environ_map = &sb.env,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = stderr,
            }),
            .screen = try .init(testing.allocator, rows, cols),
        };
    }

    fn deinit(t: *Tui) void {
        // The terminal first: a program still writing to it gets SIGHUP
        // and EIO instead of blocking on output nobody reads.
        _ = c.close(t.master);
        if (!t.exited) {
            t.child.kill(io);
        }
        t.screen.deinit();
    }

    /// Reads what is there, answering the TUI's queries.
    fn read(t: *Tui) !void {
        var buf: [16 * 1024]u8 = undefined;
        const n = c.read(t.master, &buf, buf.len);
        // The TUI exited: the other side is closed (EIO on Linux).
        if (n <= 0) {
            t.closed = true;
            return;
        }
        try t.screen.feed(buf[0..@intCast(n)]);
        if (t.screen.replies.items.len > 0) {
            try t.type(t.screen.replies.items);
            t.screen.replies.clearRetainingCapacity();
        }
    }

    fn @"type"(t: *Tui, keys: []const u8) !void {
        var rest = keys;
        while (rest.len > 0) {
            const n = c.write(t.master, rest.ptr, rest.len);
            if (n <= 0) return error.WriteFailed;
            rest = rest[@intCast(n)..];
        }
    }

    fn status(t: *const Tui, buf: []u8) []const u8 {
        return t.screen.line(buf, rows - 1);
    }

    fn quit(t: *Tui, all: []const *Tui) !u8 {
        try t.type("q");
        // Until the TUI closes its side, so it never blocks on output.
        const deadline = now() + timeout_ms;
        while (!t.closed) {
            if (now() > deadline) return error.Timeout;
            try pump(all, 50);
        }
        t.exited = true;
        return switch (try t.child.wait(io)) {
            .exited => |code| code,
            else => 255,
        };
    }
};

fn now() i64 {
    const ts = std.Io.Timestamp.now(io, .awake);
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_ms));
}

/// Waits up to `ms` for output from any of `tuis`, and reads it all. Every
/// TUI is read, so none blocks on a full terminal while the test waits.
fn pump(tuis: []const *Tui, ms: c_int) !void {
    var fds: [4]c.pollfd = undefined;
    for (tuis, fds[0..tuis.len]) |t, *fd| fd.* = .{
        // A closed one would always be ready.
        .fd = if (t.closed) -1 else t.master,
        .events = c.POLL.IN,
        .revents = 0,
    };
    if (c.poll(&fds, @intCast(tuis.len), ms) < 0) return error.PollFailed;
    for (tuis, fds[0..tuis.len]) |t, fd| {
        if (fd.revents & (c.POLL.IN | c.POLL.HUP | c.POLL.ERR) != 0) try t.read();
    }
}

/// Waits until `t` shows `text`; `why` is what should have made it.
fn expectShows(all: []const *Tui, t: *Tui, text: []const u8, why: []const u8) !void {
    const deadline = now() + timeout_ms;
    while (!t.screen.contains(text)) {
        if (now() > deadline) return failScreen(t, "doesn't show", text, why);
        try pump(all, 25);
    }
}

/// Waits until `t` no longer shows `text`.
fn expectGone(all: []const *Tui, t: *Tui, text: []const u8, why: []const u8) !void {
    const deadline = now() + timeout_ms;
    while (t.screen.contains(text)) {
        if (now() > deadline) return failScreen(t, "still shows", text, why);
        try pump(all, 25);
    }
}

fn failScreen(
    t: *Tui,
    what: []const u8,
    text: []const u8,
    why: []const u8,
) error{TestUnexpectedResult} {
    const screen = t.screen.text(testing.allocator) catch "";
    defer testing.allocator.free(screen);
    std.debug.print("{s} {s} '{s}' after {s}:\n{s}\n", .{ t.name, what, text, why, screen });
    return error.TestUnexpectedResult;
}

fn gitIssue(sb: *Sandbox, args: []const []const u8) ![]const u8 {
    const out = try sb.tool(paths.git_issue_exe, args);
    try expectSuccess(out);
    return out.stdout;
}

/// An agent: `create_issue` through `git issue mcp`, one JSON-RPC line
/// at a time.
fn agentCreates(sb: *Sandbox, title: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ try sb.exe(paths.git_issue_exe), "mcp" },
        .cwd = .{ .path = sb.repo },
        .environ_map = &sb.env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer _ = child.wait(io) catch {};
    const a = sb.arena();
    // One message per line.
    const messages = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1," ++
        "\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"2025-11-25\"," ++
        "\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"agent\",\"version\":\"0\"}}}}}}\n" ++
        "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}}\n" ++
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":" ++
        "{{\"name\":\"create_issue\",\"arguments\":{{\"title\":\"{s}\"}}}}}}\n", .{title});
    try child.stdin.?.writeStreamingAll(io, messages);
    var buf: [64 * 1024]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buf);
    while (true) {
        const response = try reader.interface.takeDelimiterInclusive('\n');
        if (std.mem.find(u8, response, "\"id\":2") == null) continue;
        try testing.expect(std.mem.find(u8, response, "\"isError\":true") == null);
        break;
    }
    child.stdin.?.close(io);
    child.stdin = null;
}

test "two TUIs follow what the command line, each other and an agent write" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    _ = try gitIssue(&sb, &.{ "create", "There before the TUIs" });

    var alice: Tui = undefined;
    try alice.start(&sb, "alice");
    defer alice.deinit();
    var bob: Tui = undefined;
    try bob.start(&sb, "bob");
    defer bob.deinit();
    const both = [_]*Tui{ &alice, &bob };

    for (both) |t| try expectShows(&both, t, "There before the TUIs", "starting");

    // The command line creates one: both show it, and say so.
    const created = try gitIssue(&sb, &.{ "create", "Created on the command line" });
    const short = std.mem.trimEnd(u8, created["Created issue ".len..], "\n");
    const changed = try std.fmt.allocPrint(sb.arena(), "#{s} changed elsewhere", .{short});
    for (both) |t| {
        try expectShows(&both, t, "Created on the command line", "git issue create");
        try expectShows(&both, t, changed, "git issue create");
    }

    // Alice creates one in her TUI: Bob's shows it, hers isn't told.
    try alice.type("n");
    try expectShows(&both, &alice, "ctrl+s create", "n");
    try alice.type("Created in Alice's TUI");
    try alice.type("\x13"); // ctrl+s
    try expectShows(&both, &alice, "created #", "ctrl+s");
    try expectShows(&both, &bob, "Created in Alice's TUI", "alice's ctrl+s");
    var buf: [512]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, bob.status(&buf), "changed elsewhere"));
    try testing.expect(!std.mem.endsWith(u8, alice.status(&buf), "changed elsewhere"));

    // The command line renames and closes: both follow.
    _ = try gitIssue(&sb, &.{ "edit", short, "--title", "Renamed on the command line" });
    for (both) |t| try expectShows(&both, t, "Renamed on the command line", "git issue edit");
    _ = try gitIssue(&sb, &.{ "close", short });
    // The list shows the issues that aren't done.
    for (both) |t| try expectGone(&both, t, "Renamed on the command line", "git issue close");

    // An agent, through the MCP server.
    try agentCreates(&sb, "Created by an agent");
    for (both) |t| try expectShows(&both, t, "Created by an agent", "the agent's create_issue");

    for (both) |t| try testing.expectEqual(@as(u8, 0), try t.quit(&both));
}

/// Today in UTC, plus `days`, as `YYYY-MM-DD`.
fn dayFromToday(buf: []u8, days: i64) []const u8 {
    const t = std.Io.Timestamp.now(io, .real);
    const secs: u64 = @intCast(
        @divFloor(t.nanoseconds, std.time.ns_per_s) + days * std.time.s_per_day,
    );
    const yd = (std.time.epoch.EpochSeconds{ .secs = secs }).getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2}",
        .{ yd.year, md.month.numeric(), md.day_index + 1 },
    ) catch unreachable;
}

test "the timeline's draft sees a change made elsewhere, and applies over it when asked" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    var b3: [16]u8 = undefined;
    const created = try gitIssue(
        &sb,
        &.{ "create", "Design", "--start", dayFromToday(&b1, 0), "--due", dayFromToday(&b2, 4) },
    );
    const short = std.mem.trimEnd(u8, created["Created issue ".len..], "\n");

    var tui: Tui = undefined;
    try tui.start(&sb, "tui");
    defer tui.deinit();
    const all = [_]*Tui{&tui};
    try expectShows(&all, &tui, "Design", "starting");
    try tui.type("4");
    try expectShows(&all, &tui, "(no milestone)", "4");
    try tui.type("jE");
    try expectShows(&all, &tui, "EDIT MODE", "E");
    try tui.type("l");
    try expectShows(&all, &tui, "1 change not applied", "l");

    // Someone renames it meanwhile: the draft says so, with no key pressed.
    _ = try gitIssue(&sb, &.{ "edit", short, "--title", "Design, renamed" });
    try expectShows(&all, &tui, "! 1 changed elsewhere", "git issue edit");
    try tui.type("\x13"); // ctrl+s
    try expectShows(&all, &tui, "r keeps your change", "ctrl+s on a stale draft");
    try tui.type("r\x13");
    try expectShows(&all, &tui, "Apply 1 change?", "r, ctrl+s");
    try tui.type("\r");
    try expectShows(&all, &tui, "applied 1 change", "Apply");

    const shown = try gitIssue(&sb, &.{ "show", short });
    try testing.expect(std.mem.find(u8, shown, "Design, renamed") != null);
    const want = try std.fmt.allocPrint(sb.arena(), "Start:   {s}", .{dayFromToday(&b3, 1)});
    try testing.expect(std.mem.find(u8, shown, want) != null);
    try testing.expectEqual(@as(u8, 0), try tui.quit(&all));
}

/// An executable shell script at `path`.
fn writeScript(sb: *Sandbox, path: []const u8, script: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = script });
    try expectSuccess(try sb.run(&.{ "chmod", "+x", path }));
}

/// ssh without the developer's ~/.ssh/config, first in PATH: ssh reads
/// the config from the home directory of the user, whatever HOME says.
fn isolateSsh(sb: *Sandbox) !void {
    const a = sb.arena();
    const found = try sb.run(&.{ "sh", "-c", "command -v ssh" });
    try expectSuccess(found);
    const bin = try std.fmt.allocPrint(a, "{s}-bin", .{sb.repo});
    try std.Io.Dir.cwd().createDir(io, bin, .default_dir);
    try writeScript(sb, try std.fmt.allocPrint(a, "{s}/ssh", .{bin}), try std.fmt.allocPrint(
        a,
        "#!/bin/sh\nexec '{s}' -F /dev/null \"$@\"\n",
        .{std.mem.trimEnd(u8, found.stdout, "\n")},
    ));
    try sb.env.put(
        "PATH",
        try std.fmt.allocPrint(a, "{s}:{s}", .{ bin, sb.env.get("PATH") orelse "/usr/bin:/bin" }),
    );
}

test "y syncs with a real remote; a dead one fails without a prompt" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    try isolateSsh(&sb);
    const a = sb.arena();
    const hub = try std.fmt.allocPrint(a, "{s}-hub.git", .{sb.repo});
    const bob = try std.fmt.allocPrint(a, "{s}-bob", .{sb.repo});
    try sb.git(&.{ "init", "-q", "--bare", hub });
    try sb.git(&.{ "remote", "add", "origin", hub });
    try sb.git(&.{ "clone", "-q", hub, bob });
    const exe = try sb.exe(paths.git_issue_exe);
    _ = try gitIssue(&sb, &.{ "create", "Made here" });
    try expectSuccess(try sb.runIn(bob, &.{ exe, "create", "Made by Bob" }));
    try expectSuccess(try sb.runIn(bob, &.{ exe, "sync", "origin" }));

    var tui: Tui = undefined;
    try tui.start(&sb, "tui");
    defer tui.deinit();
    const all = [_]*Tui{&tui};
    try expectShows(&all, &tui, "⇅ origin ↑1", "starting");
    try tui.type("y");
    try expectShows(&all, &tui, "synced with origin: 1 in, 1 out", "y");
    try expectShows(&all, &tui, "Made by Bob", "y");
    try expectShows(&all, &tui, "⇅ origin ✓", "y");

    try expectSuccess(try sb.runIn(bob, &.{ exe, "merge", "origin" }));
    const listed = try sb.runIn(bob, &.{ exe, "ls" });
    try testing.expect(std.mem.find(u8, listed.stdout, "Made here") != null);

    // A CLI push moves only sync records: the badge still updates live.
    _ = try gitIssue(&sb, &.{ "create", "Pushed from the CLI" });
    try expectShows(&all, &tui, "⇅ origin ↑1", "an external create");
    _ = try gitIssue(&sb, &.{ "push", "origin" });
    try expectShows(&all, &tui, "⇅ origin ✓", "an external push");

    // A remote nobody answers on: it fails, says why, and asks nothing.
    try sb.git(&.{ "remote", "add", "dead", "ssh://nobody@127.0.0.1:1/x.git" });
    try sb.git(&.{ "config", "issue.remote", "dead" });
    try tui.type("\x12"); // ctrl+r: reread it all, the remote too
    try expectShows(&all, &tui, "⇅ dead", "issue.remote");
    try tui.type("y");
    try expectShows(&all, &tui, "sync with dead failed", "y on a dead remote");
    try expectShows(&all, &tui, "⇅ dead ⚠", "the failure");
    try testing.expectEqual(@as(u8, 0), try tui.quit(&all));
}

test "quitting while a sync runs stops it; the user's own ssh runs without the terminal" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    const a = sb.arena();
    const dir = try std.fmt.allocPrint(a, "{s}-ssh", .{sb.repo});
    try std.Io.Dir.cwd().createDir(io, dir, .default_dir);
    // An ssh that says where it runs, then hangs like a host that never
    // answers.
    const ssh = try std.fmt.allocPrint(a, "{s}/my-ssh", .{dir});
    try writeScript(&sb, ssh, try std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\if (exec </dev/tty) 2>/dev/null; then echo tty; else echo none; fi > '{0s}/tty'
        \\echo "$SSH_ASKPASS_REQUIRE" > '{0s}/askpass'
        \\echo "$@" > '{0s}/args'
        \\echo $$ > '{0s}/pid.tmp' && mv '{0s}/pid.tmp' '{0s}/pid'
        \\exec sleep 60
        \\
    , .{dir}));
    try sb.git(&.{ "remote", "add", "origin", "ssh://git@example.invalid/x.git" });
    try sb.git(&.{ "config", "core.sshCommand", ssh });
    // No probing of what kind of ssh it is: that would hang too.
    try sb.git(&.{ "config", "ssh.variant", "ssh" });
    _ = try gitIssue(&sb, &.{ "create", "Made here" });

    const log_path = try std.fmt.allocPrint(a, "{s}/stderr", .{dir});
    const log = try std.Io.Dir.cwd().createFile(io, log_path, .{});
    defer log.close(io);
    var tui: Tui = undefined;
    try tui.startWith(&sb, "tui", &.{ try sb.exe(paths.git_issue_exe), "tui" }, .{ .file = log });
    defer tui.deinit();
    const all = [_]*Tui{&tui};
    try expectShows(&all, &tui, "⇅ origin ↑1", "starting");
    try tui.type("y");
    try expectShows(&all, &tui, "origin fetching…", "y");
    const pid_path = try std.fmt.allocPrint(a, "{s}/pid", .{dir});
    const deadline = now() + timeout_ms;
    while (true) {
        std.Io.Dir.cwd().access(io, pid_path, .{}) catch {
            if (now() > deadline) return failScreen(&tui, "never ran", "my-ssh", "y");
            try pump(&all, 25);
            continue;
        };
        break;
    }
    const read = struct {
        fn f(al: std.mem.Allocator, d: []const u8, name: []const u8) ![]const u8 {
            const path = try std.fmt.allocPrint(al, "{s}/{s}", .{ d, name });
            const text = try std.Io.Dir.cwd().readFileAlloc(io, path, al, .limited(4096));
            return std.mem.trimEnd(u8, text, "\n");
        }
    }.f;
    // Theirs, as they set it, with no terminal to prompt on.
    try testing.expectEqualStrings("none", try read(a, dir, "tty"));
    try testing.expectEqualStrings("never", try read(a, dir, "askpass"));
    try testing.expect(std.mem.find(u8, try read(a, dir, "args"), "BatchMode") == null);
    const pid = try std.fmt.parseInt(c.pid_t, try read(a, dir, "pid"), 10);

    try tui.type("q");
    try expectShows(&all, &tui, "q again quits and stops it", "q while syncing");
    try testing.expectEqual(@as(u8, 0), try tui.quit(&all));
    // The ssh is gone with the git that ran it.
    const gone_by = now() + timeout_ms;
    while (c.kill(pid, @fromBackingInt(@intCast(0))) == 0) {
        if (now() > gone_by) return error.SshStillRunning;
        try io.sleep(.fromMilliseconds(25), .awake);
    }
    // Nothing leaked: the debug allocator would say so on stderr.
    const errors = try std.Io.Dir.cwd().readFileAlloc(io, log_path, a, .limited(64 * 1024));
    if (errors.len > 0) std.debug.print("tui stderr:\n{s}\n", .{errors});
    try testing.expect(std.mem.find(u8, errors, "leak") == null);
}

test {
    _ = Screen;
}

/// The YAML of docs/lazygit.md's configuration block.
fn lazygitMenu(arena: std.mem.Allocator) ![]const u8 {
    const doc = try std.Io.Dir.cwd().readFileAlloc(io, paths.lazygit_doc, arena, .limited(1 << 20));
    const start = (std.mem.find(u8, doc, "```yaml\n") orelse return error.NoYaml) + "```yaml\n".len;
    const end = std.mem.findPos(u8, doc, start, "```") orelse return error.NoYaml;
    return doc[start..end];
}

test "lazygit: docs/lazygit.md's menu, in lazygit itself" {
    var sb = try Sandbox.init(.{});
    defer sb.deinit();
    const arena = sb.arena();
    const lazygit = (try sb.run(&.{ "sh", "-c", "command -v lazygit" })).stdout;
    if (lazygit.len == 0) return error.SkipZigTest;
    _ = try gitIssue(&sb, &.{ "create", "Seen from lazygit" });

    // `git issue` is git-issue on the PATH; lazygit reads only this config.
    const bin = std.fs.path.dirname(try sb.exe(paths.git_issue_exe)).?;
    const path = try std.fmt.allocPrint(arena, "{s}:{s}", .{ bin, sb.env.get("PATH") orelse "" });
    try sb.env.put("PATH", path);
    const config = try std.fmt.allocPrint(arena, "{s}-lazygit.yml", .{sb.repo});
    const yaml = try std.mem.concat(arena, u8, &.{
        "disableStartupPopups: true\nupdate:\n  method: never\n",
        try lazygitMenu(arena),
    });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config, .data = yaml });
    try sb.env.put("LG_CONFIG_FILE", config);

    var lg: Tui = undefined;
    try lg.startWith(&sb, "lazygit", &.{std.mem.trimEnd(u8, lazygit, "\n")}, .inherit);
    defer lg.deinit();
    const all = [_]*Tui{&lg};
    try expectShows(&all, &lg, "Files", "starting");
    try lg.type("I");
    try expectShows(&all, &lg, "List open issues", "I");
    try expectShows(&all, &lg, "New issue", "I");
    try lg.type("l");
    try expectShows(&all, &lg, "Seen from lazygit", "l: git issue ls");

    // n: title, priority (high is the fourth), label; then git issue create.
    try lg.type("\x1b");
    try expectGone(&all, &lg, "Open issues", "esc");
    try lg.type("I");
    try expectShows(&all, &lg, "New issue", "I");
    try lg.type("n");
    try expectShows(&all, &lg, "Title", "n");
    try lg.type("Made in lazygit\r");
    try expectShows(&all, &lg, "Priority", "the title");
    try lg.type("jjj\r");
    try expectShows(&all, &lg, "Label", "the priority");
    try lg.type("ui\r");
    const deadline = now() + timeout_ms;
    while (true) {
        const listed = try gitIssue(
            &sb,
            &.{ "ls", "--format", "oneline", "--priority", "high", "-l", "ui" },
        );
        if (std.mem.find(u8, listed, "Made in lazygit") != null) break;
        if (now() > deadline) return failScreen(&lg, "didn't create", "Made in lazygit", "n");
        try pump(&all, 50);
    }
    try testing.expectEqual(@as(u8, 0), try lg.quit(&all));
}

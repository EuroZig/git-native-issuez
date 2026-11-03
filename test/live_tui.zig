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
                .argv = &.{
                    try sb.exe(paths.tty_exec),
                    tty,
                    std.fmt.comptimePrint("{d}", .{rows}),
                    std.fmt.comptimePrint("{d}", .{cols}),
                    try sb.exe(paths.git_issue_exe),
                    "tui",
                },
                .cwd = .{ .path = sb.repo },
                .environ_map = &sb.env,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .inherit,
            }),
            .screen = try .init(testing.allocator, rows, cols),
        };
    }

    fn deinit(t: *Tui) void {
        if (!t.exited) {
            t.child.kill(io);
        }
        _ = c.close(t.master);
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
    const messages = try std.fmt.allocPrint(a,
        \\{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{{"protocolVersion":"2025-11-25","capabilities":{{}},"clientInfo":{{"name":"agent","version":"0"}}}}}}
        \\{{"jsonrpc":"2.0","method":"notifications/initialized"}}
        \\{{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{{"name":"create_issue","arguments":{{"title":"{s}"}}}}}}
        \\
    , .{title});
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

test {
    _ = Screen;
}

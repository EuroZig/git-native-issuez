//! `git issue tui`: the issues of the repository in a terminal UI, with
//! a list, a kanban board and a detail view, all usable with the mouse.

const std = @import("std");
const vaxis = @import("vaxis");
const issuez = @import("issuez");

const RepoWatcher = @import("RepoWatcher");

const app_mod = @import("app.zig");
const State = @import("State.zig");

const GitProcess = issuez.backend.GitProcess;
const App = app_mod.App(GitProcess);

/// completion.zig keeps a copy for builds without the TUI.
pub const help =
    \\usage: git issue tui
    \\
    \\Interactive terminal UI: a list, a kanban board and a detail view.
    \\Press ? inside for the keys; the mouse works everywhere.
    \\
    \\Options:
    \\   -h, --help    Show this help
    \\
;

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    focus_in,
    paste_start,
    paste_end,
    /// The watcher saw others write; what they changed is in `Live`.
    repo_changed,
};

/// Live updates: the watcher's listener, on the watcher's thread.
const Live = struct {
    loop: *vaxis.Loop(Event),
    /// `RepoWatcher.Change` bits not handled yet.
    pending: std.atomic.Value(u8) = .init(0),

    fn changed(context: *anyopaque, change: RepoWatcher.Change) void {
        const live: *Live = @ptrCast(@alignCast(context));
        _ = live.pending.fetchOr(@bitCast(change), .acq_rel);
        // Never blocks, so the watcher can always stop. With the queue
        // full the loop wakes anyway, and checks `pending` after every
        // event.
        _ = live.loop.tryPostEvent(.repo_changed) catch {};
    }

    fn take(live: *Live) ?RepoWatcher.Change {
        const change: RepoWatcher.Change = @bitCast(live.pending.swap(0, .acq_rel));
        return if (change.any()) change else null;
    }
};

pub fn main(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    args: []const []const u8,
) u8 {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            out.writeAll(help) catch {};
            return 0;
        }
        err.print("git-issue: tui takes no arguments, not '{s}'\n", .{arg}) catch {};
        return 2;
    }
    const interactive = (std.Io.File.stdin().isTty(io) catch false) and
        (std.Io.File.stdout().isTty(io) catch false);
    if (!interactive) {
        err.writeAll("git-issue: 'tui' needs an interactive terminal.\n") catch {};
        return 1;
    }

    var git = GitProcess.open(io, gpa, .{ .path = ".", .environ_map = environ_map }) catch |e| {
        err.print("git-issue: {f}\n", .{issuez.errors.Description{ .err = e, .limits = .{} }}) catch {};
        return 1;
    };
    defer git.close();

    const app = gpa.create(App) catch {
        err.writeAll("git-issue: out of memory\n") catch {};
        return 1;
    };
    defer gpa.destroy(app);
    app.init(gpa, &git);
    defer app.deinit();
    // Before taking over the terminal, so a failure is readable.
    app.store.reload() catch |e| {
        var buf: [400]u8 = undefined;
        err.print("git-issue: {s}\n", .{app.store.describe(e, &buf)}) catch {};
        return 1;
    };

    run(io, gpa, environ_map, app, git.common_dir.?) catch |e| {
        err.print("git-issue: tui failed: {t}\n", .{e}) catch {};
        return 1;
    };
    return 0;
}

/// For double-clicks: a clock that doesn't jump.
fn nowMs(io: std.Io) i64 {
    const t = std.Io.Timestamp.now(io, .awake);
    return @intCast(@divFloor(t.nanoseconds, std.time.ns_per_ms));
}

/// Unix seconds, for "5m ago".
fn nowS(io: std.Io) i64 {
    const t = std.Io.Timestamp.now(io, .real);
    return @intCast(@divFloor(t.nanoseconds, std.time.ns_per_s));
}

fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    app: *App,
    git_dir: []const u8,
) !void {
    var buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buffer);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, gpa, environ_map, .{});
    defer vx.deinit(gpa, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(writer);
    try writer.flush();
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    // Also turns on focus reports, for `.focus_in`.
    try vx.setMouseMode(writer, true);
    try vx.setBracketedPaste(writer, true);
    try vx.setTitle(writer, "git issue");

    // Without it, what others write shows when the terminal gets the
    // focus back, or on `r`.
    var live: Live = .{ .loop = &loop };
    var watcher: RepoWatcher = undefined;
    var watching = true;
    watcher.init(io, gpa, git_dir, .{ .context = &live, .changed = Live.changed }, .{}) catch |e| {
        watching = false;
        app.state.fail("live updates are off: {t}", .{e});
    };
    // Before the loop stops: the listener posts to it.
    defer if (watching) watcher.deinit();
    // What was written since the first load, before the watcher.
    if (watching) app.changedElsewhere(false);

    // An event loop: runs until the user quits.
    while (true) {
        const input: ?State.Input = switch (try loop.nextEvent()) {
            .key_press => |k| .{ .key = k },
            // The loop has already turned pixel positions into cells.
            // The pointer moving with no button held changes nothing:
            // no frame for it.
            .mouse => |m| if (m.type == .motion and m.button == .none) continue else .{ .mouse = m },
            .paste_start => .paste_start,
            .paste_end => .paste_end,
            .winsize => |ws| blk: {
                try vx.resize(gpa, tty.writer(), ws);
                break :blk null;
            },
            .focus_in => blk: {
                // Others may have written meanwhile, git config too.
                app.changedElsewhere(true);
                break :blk null;
            },
            .repo_changed => null,
        };
        if (input) |in| if (!try app.handle(in, nowMs(io))) break;
        if (live.take()) |change| app.changedElsewhere(change.config);
        try app.draw(vx.window(), nowS(io));
        try vx.render(writer);
        try writer.flush();
    }
}

test {
    _ = @import("text.zig");
    _ = @import("filter.zig");
    _ = @import("ui.zig");
    _ = @import("store.zig");
    _ = app_mod;
}

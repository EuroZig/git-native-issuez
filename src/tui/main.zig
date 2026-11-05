//! `git issue tui`: the issues of the repository in a terminal UI, with
//! a list, a kanban board, the milestones, a timeline and a detail view,
//! all usable with the mouse.

const std = @import("std");
const vaxis = @import("vaxis");
const issuez = @import("issuez");

const RepoWatcher = @import("RepoWatcher");

const app_mod = @import("app.zig");
const State = @import("State.zig");
const sync_job = @import("sync_job.zig");
const local_time = issuez.local_time;

const GitProcess = issuez.backend.GitProcess;
const App = app_mod.App(GitProcess);

/// completion.zig keeps a copy for builds without the TUI.
pub const help =
    \\usage: git issue tui
    \\
    \\Interactive terminal UI: a list, a kanban board, milestones, a timeline
    \\and a detail view.
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
    /// The sync job moved on: `SyncWorker.phase`.
    sync_phase,
    /// The sync job is done: `SyncWorker.summary`.
    sync_done,
    /// Every few seconds, for automatic syncs.
    tick,
};

/// Syncs as a task of their own with a git of their own, so the UI
/// keeps going while git talks to the remote. Quitting cancels the task,
/// which kills the git it waits on.
const SyncWorker = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// The TUI's environment.
    environ_map: *const std.process.Environ.Map,
    loop: *vaxis.Loop(Event),
    /// The TUI's git, for git config, on the UI's thread.
    config: *GitProcess,
    task: ?std.Io.Future(void) = null,
    /// Set before cancelling: the task posts nothing more.
    stopping: std.atomic.Value(bool) = .init(false),
    remote_buf: [256]u8 = undefined,
    remote_len: usize = 0,
    kind: sync_job.Kind = .sync,
    auto: bool = false,
    fetched: bool = false,
    /// The user set their own ssh command: it runs as they set it.
    own_ssh: bool = false,
    /// Whether ssh may share connections, and where: found by the first
    /// sync, read by the next ones only.
    ssh_checked: bool = false,
    control_buf: [128]u8 = undefined,
    control: ?[]const u8 = null,
    phase: std.atomic.Value(u8) = .init(0),
    /// Written by the task before it posts `sync_done`.
    summary: sync_job.Summary = .{},

    /// error.SyncRunning when one runs already.
    fn start(context: *anyopaque, remote: []const u8, kind: sync_job.Kind, auto: bool, fetched: bool) anyerror!void {
        const w: *SyncWorker = @ptrCast(@alignCast(context));
        if (w.task != null) return error.SyncRunning;
        w.remote_len = @min(remote.len, w.remote_buf.len);
        @memcpy(w.remote_buf[0..w.remote_len], remote[0..w.remote_len]);
        w.kind = kind;
        w.auto = auto;
        w.fetched = fetched;
        // Read each time: git config may have changed meanwhile.
        var arena_state: std.heap.ArenaAllocator = .init(w.gpa);
        defer arena_state.deinit();
        w.own_ssh = w.environ_map.get("GIT_SSH_COMMAND") != null or w.environ_map.get("GIT_SSH") != null or
            (w.config.configGet(arena_state.allocator(), "core.sshCommand") catch null) != null;
        w.task = try w.io.concurrent(work, .{w});
    }

    fn work(w: *SyncWorker) void {
        var arena_state: std.heap.ArenaAllocator = .init(w.gpa);
        defer arena_state.deinit();
        w.summary = w.job(arena_state.allocator());
        w.post(.sync_done);
    }

    fn job(w: *SyncWorker, a: std.mem.Allocator) sync_job.Summary {
        const remote = w.remote_buf[0..w.remote_len];
        var out: sync_job.Summary = .{ .kind = w.kind, .auto = w.auto };
        out.setRemote(remote);
        const git_or_error = blk: {
            // Without the terminal (`no_terminal`), ssh can't ask there,
            // and no askpass window asks instead.
            var env = w.environ_map.clone(a) catch |e| break :blk e;
            env.put("SSH_ASKPASS_REQUIRE", "never") catch |e| break :blk e;
            if (!w.own_ssh) {
                var ssh_buf: [512]u8 = undefined;
                env.put("GIT_SSH_COMMAND", sync_job.sshCommand(&ssh_buf, w.controlDir(a))) catch |e| break :blk e;
            }
            break :blk GitProcess.open(w.io, w.gpa, .{ .path = ".", .environ_map = &env, .no_terminal = true });
        };
        var git = git_or_error catch |e| {
            out.fail("{s} with {s} failed: {f}", .{ w.kind.label(), remote, issuez.errors.Description{ .err = e, .limits = .{} } });
            return out;
        };
        defer git.close();
        return sync_job.run(GitProcess, &git, a, remote, w.kind, w.auto, w.fetched, .{
            .context = w,
            .phase = onPhase,
        });
    }

    /// Where ssh keeps the connection it shares, or null for none: never
    /// on Windows, whose ssh can't share, nor with an ssh that would
    /// hold git up, nor without a directory only we can enter.
    fn controlDir(w: *SyncWorker, a: std.mem.Allocator) ?[]const u8 {
        if (@import("builtin").os.tag == .windows) return null;
        if (w.ssh_checked) return w.control;
        w.ssh_checked = true;
        const version = std.process.run(a, w.io, .{ .argv = &.{ "ssh", "-V" } }) catch |e| {
            // Quitting: the sync's git must see it too.
            if (e == error.Canceled) w.io.recancel();
            return null;
        };
        if (!sync_job.sshSharesSafely(version.stderr)) return null;
        w.control = sync_job.controlDir(w.io, &w.control_buf, w.environ_map.get("XDG_RUNTIME_DIR"), sync_job.currentUid());
        return w.control;
    }

    fn onPhase(context: *anyopaque, phase: issuez.sync.Phase) void {
        const w: *SyncWorker = @ptrCast(@alignCast(context));
        w.phase.store(@intFromEnum(phase), .release);
        w.post(.sync_phase);
    }

    /// Blocks while the queue is full: the loop always drains it, until
    /// quitting, which cancels the wait. The cancel is delivered once:
    /// re-armed, so the sync's next git call stops too.
    fn post(w: *SyncWorker, e: Event) void {
        if (w.stopping.load(.acquire)) return;
        w.loop.postEvent(e) catch |err| if (err == error.Canceled) w.io.recancel();
    }

    /// After `sync_done`: the task is over.
    fn finish(w: *SyncWorker) sync_job.Summary {
        if (w.task) |*t| t.await(w.io);
        w.task = null;
        return w.summary;
    }

    /// Quitting: a sync still running is cancelled, and over before what
    /// it uses goes.
    fn stop(w: *SyncWorker) void {
        w.stopping.store(true, .release);
        if (w.task) |*t| t.cancel(w.io);
        w.task = null;
    }
};

/// Posts `tick` every few seconds until stopped.
const Ticker = struct {
    io: std.Io,
    loop: *vaxis.Loop(Event),
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    const every_s = 15;

    fn run(t: *Ticker) void {
        var n: u32 = 0;
        while (!t.stop.load(.acquire)) {
            t.io.sleep(.fromMilliseconds(250), .awake) catch {};
            n += 1;
            if (n % (every_s * 4) == 0) _ = t.loop.tryPostEvent(.tick) catch {};
        }
    }
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

/// The panic handler of a program with the TUI: the terminal back to
/// how it was, if the TUI has it, then the default handler.
pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    vaxis.recover();
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// For double-clicks: a clock that doesn't jump.
fn nowMs(io: std.Io) i64 {
    const t = std.Io.Timestamp.now(io, .awake);
    return @intCast(@divFloor(t.nanoseconds, std.time.ns_per_ms));
}

/// Unix seconds, for "5m ago".
const nowS = local_time.nowS;

fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    app: *App,
    git_dir: []const u8,
) !void {
    var buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buffer);
    defer {
        tty.deinit();
        // Given back: a panic after this leaves the terminal alone.
        vaxis.tty.global_tty = null;
    }
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

    // Syncs in the background, with git that never prompts.
    var worker: SyncWorker = .{ .io = io, .gpa = gpa, .environ_map = environ_map, .loop = &loop, .config = app.store.backend };
    app.runner = .{ .context = &worker, .start = SyncWorker.start };
    // Before the loop stops: the task posts to it.
    defer {
        app.runner = null;
        worker.stop();
    }
    var ticker: Ticker = .{ .io = io, .loop = &loop };
    ticker.thread = std.Thread.spawn(.{}, Ticker.run, .{&ticker}) catch null;
    defer if (ticker.thread) |t| {
        ticker.stop.store(true, .release);
        t.join();
    };

    // What today is where the user is.
    var zone = local_time.load(io, gpa, environ_map);
    defer zone.deinit(gpa);

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
            .sync_phase => blk: {
                app.syncPhase(@enumFromInt(worker.phase.load(.acquire)));
                break :blk null;
            },
            .sync_done => blk: {
                app.syncDone(worker.finish(), nowS(io));
                break :blk null;
            },
            .tick => blk: {
                app.tick(nowS(io));
                break :blk null;
            },
        };
        if (input) |in| if (!try app.handle(in, nowMs(io))) break;
        if (live.take()) |change| app.changedElsewhere(change.config);
        const now = nowS(io);
        app.state.utc_offset_s = zone.offsetAt(now);
        try app.draw(vx.window(), now);
        try vx.render(writer);
        try writer.flush();
    }
}

test {
    _ = @import("text.zig");
    _ = @import("filter.zig");
    _ = @import("ui.zig");
    _ = @import("store.zig");
    _ = @import("milestone_filter.zig");
    _ = @import("timeline_view.zig");
    _ = @import("timeline_draft.zig");
    _ = @import("sync_job.zig");
    _ = app_mod;
}

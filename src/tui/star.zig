//! Asking now and then for a star on GitHub: a notice in the status bar,
//! never in a session's first minutes nor in the first days, at most once
//! a month and a few times in all, and never again once starred or
//! declined. `gh`, when installed and logged in, says whether the project
//! is starred already, and stars it in one click; without it, the click
//! opens the project's page in the browser.
//!
//! What it asked when is kept with the TUI's state, in `user_state.zig`'s
//! file.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

const user_state = @import("user_state.zig");

pub const repo = "EuroZig/git-native-issuez";
pub const url = "https://github.com/" ++ repo;

/// Notices before it stops asking.
pub const max_times = 4;

/// When it asks, in seconds.
pub const Timing = struct {
    /// How long a session runs before it may ask.
    session_s: i64 = 10 * 60,
    /// From the first session that long to the first notice.
    settle_s: i64 = 3 * 86400,
    /// Between two notices.
    every_s: i64 = 30 * 86400,
    /// How long a notice stays when nobody clicks it.
    visible_s: i64 = 3 * 60,

    /// To try it out: `GIT_ISSUE_STAR_NOW` set, in a Debug build only.
    /// Ticks come every 15 seconds, so it shows within half a minute.
    pub const fast: Timing = .{ .session_s = 10, .settle_s = 0, .every_s = 0, .visible_s = 30 };

    pub fn fromEnv(environ_map: *const Environ.Map) Timing {
        if (builtin.mode != .debug) return .{};
        return if (environ_map.get("GIT_ISSUE_STAR_NOW") != null) .fast else .{};
    }
};

/// The notice as the UI has it.
pub const Ui = struct {
    phase: Phase = .idle,
    timing: Timing = .{},
    /// Clicking stars it with `gh`; else it opens the browser.
    gh: bool = false,
    /// Unix seconds of the first tick, and of the notice showing.
    started_at: i64 = 0,
    shown_at: i64 = 0,

    pub const Phase = enum {
        idle,
        /// Whether to ask: the record, then `gh`.
        checking,
        shown,
        starring,
        /// Not in this session again.
        off,
    };
};

/// What the check found.
pub const Check = enum { off, ask_gh, ask_browser };

/// What a click on the star did.
pub const Outcome = enum {
    starred,
    opened,
    /// No browser to open here, as over ssh: the URL shows instead.
    no_browser,
};

/// What it asked when, kept between sessions.
pub const Record = struct {
    /// Unix seconds; 0 for never.
    first_seen: i64 = 0,
    last_shown: i64 = 0,
    shown: u32 = 0,
    done: Done = .no,

    pub const Done = enum { no, starred, opened, never };
};

pub const Decision = enum {
    wait,
    /// The first session long enough: the days count from now.
    start_clock,
    ask,
};

/// Once a session has run `t.session_s`.
pub fn decide(r: Record, now_s: i64, t: Timing) Decision {
    if (r.done != .no or r.shown >= max_times) return .wait;
    // A clock set back counts from now.
    if (r.first_seen == 0 or r.first_seen > now_s) return .start_clock;
    if (now_s - r.first_seen < t.settle_s) return .wait;
    const recent = r.last_shown > 0 and r.last_shown <= now_s and now_s - r.last_shown < t.every_s;
    if (recent) return .wait;
    return .ask;
}

/// Whether to show the notice, and how a click stars: once a session has
/// run `t.session_s`. Writes down that it asked before asking, so a record
/// that can't be written never asks.
pub fn check(
    io: std.Io,
    a: Allocator,
    environ_map: *const Environ.Map,
    now_s: i64,
    t: Timing,
) Check {
    const file = user_state.path(io, a, environ_map) orelse return .off;
    var state = user_state.load(io, a, file) orelse return .off;
    const r = &state.star;
    switch (decide(r.*, now_s, t)) {
        .wait => return .off,
        .start_clock => {
            r.first_seen = now_s;
            _ = user_state.save(io, a, file, state);
            // Without days to settle, it asks at once.
            if (decide(r.*, now_s, t) != .ask) return .off;
        },
        .ask => {},
    }
    const gh = ghStatus(io, a, environ_map);
    if (gh == .starred) {
        r.done = .starred;
        _ = user_state.save(io, a, file, state);
        return .off;
    }
    r.last_shown = now_s;
    r.shown += 1;
    if (!user_state.save(io, a, file, state)) return .off;
    return if (gh == .not_starred) .ask_gh else .ask_browser;
}

/// The click: with `gh` when it can, else in the browser. Either way it
/// doesn't ask again.
pub fn star(io: std.Io, a: Allocator, environ_map: *const Environ.Map, gh: bool) Outcome {
    const outcome: Outcome = if (gh and ghStar(io, a, environ_map))
        .starred
    else
        openBrowser(io, a, environ_map);
    setDone(io, a, environ_map, if (outcome == .starred) .starred else .opened);
    return outcome;
}

/// "Never".
pub fn decline(io: std.Io, a: Allocator, environ_map: *const Environ.Map) void {
    setDone(io, a, environ_map, .never);
}

fn setDone(io: std.Io, a: Allocator, environ_map: *const Environ.Map, done: Record.Done) void {
    const file = user_state.path(io, a, environ_map) orelse return;
    var state = user_state.load(io, a, file) orelse return;
    state.star.done = done;
    _ = user_state.save(io, a, file, state);
}

const GhStatus = enum { starred, not_starred, unusable };

/// `gh` not installed, not logged in, offline: unusable.
fn ghStatus(io: std.Io, a: Allocator, environ_map: *const Environ.Map) GhStatus {
    const result = ghApi(io, a, environ_map, &.{"user/starred/" ++ repo}) orelse return .unusable;
    if (exitedWith(result.term, 0)) return .starred;
    // Not starred is a 404; not logged in and the like aren't.
    if (exitedWith(result.term, 1) and std.mem.find(u8, result.stderr, "(HTTP 404)") != null)
        return .not_starred;
    return .unusable;
}

fn ghStar(io: std.Io, a: Allocator, environ_map: *const Environ.Map) bool {
    const result = ghApi(io, a, environ_map, &.{ "-X", "PUT", "user/starred/" ++ repo }) orelse
        return false;
    return exitedWith(result.term, 0);
}

/// `gh api` on github.com, whatever host `gh` defaults to, never asking.
fn ghApi(
    io: std.Io,
    a: Allocator,
    environ_map: *const Environ.Map,
    args: []const []const u8,
) ?std.process.RunResult {
    var env = environ_map.clone(a) catch return null;
    env.put("GH_PROMPT_DISABLED", "1") catch return null;
    env.put("GH_NO_UPDATE_NOTIFIER", "1") catch return null;
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{ "gh", "api", "--hostname", "github.com" }) catch return null;
    argv.appendSlice(a, args) catch return null;
    return std.process.run(a, io, .{
        .argv = argv.items,
        .environ_map = &env,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(20), .clock = .awake } },
    }) catch |e| {
        // Quitting: whoever waits on the task must see it too.
        if (e == error.Canceled) io.recancel();
        return null;
    };
}

fn exitedWith(term: std.process.Child.Term, code: u8) bool {
    return term == .exited and term.exited == code;
}

/// Not over ssh, nor on Linux and the BSDs without a display: the
/// browser would open where the user isn't, or in this terminal.
fn openBrowser(io: std.Io, a: Allocator, environ_map: *const Environ.Map) Outcome {
    const remote = environ_map.get("SSH_CONNECTION") != null or environ_map.get("SSH_TTY") != null;
    const display = environ_map.get("DISPLAY") != null or
        environ_map.get("WAYLAND_DISPLAY") != null;
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "rundll32", "url.dll,FileProtocolHandler", url },
        .macos => if (remote) return .no_browser else &.{ "open", url },
        else => if (remote or !display) return .no_browser else &.{ "xdg-open", url },
    };
    const result = std.process.run(a, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        // Some openers wait for the browser: it's open by then.
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    }) catch |e| switch (e) {
        error.Timeout => return .opened,
        error.Canceled => {
            io.recancel();
            return .no_browser;
        },
        else => return .no_browser,
    };
    // `rundll32` says nothing either way.
    if (builtin.os.tag == .windows) return .opened;
    return if (exitedWith(result.term, 0)) .opened else .no_browser;
}

const testing = std.testing;

test "decide: not early, not often, not forever" {
    const day = 86400;
    const t0: i64 = 1_700_000_000;
    const t: Timing = .{};
    try testing.expectEqual(Decision.start_clock, decide(.{}, t0, t));
    var r: Record = .{ .first_seen = t0 };
    try testing.expectEqual(Decision.wait, decide(r, t0 + t.settle_s - 1, t));
    try testing.expectEqual(Decision.ask, decide(r, t0 + t.settle_s, t));
    r.last_shown = t0 + 3 * day;
    r.shown = 1;
    try testing.expectEqual(Decision.wait, decide(r, r.last_shown + t.every_s - 1, t));
    try testing.expectEqual(Decision.ask, decide(r, r.last_shown + t.every_s, t));
    // A clock set back.
    try testing.expectEqual(Decision.start_clock, decide(r, t0 - day, t));
    r.shown = max_times;
    try testing.expectEqual(Decision.wait, decide(r, t0 + 365 * day, t));
    r.shown = 1;
    for ([_]Record.Done{ .starred, .opened, .never }) |done| {
        r.done = done;
        try testing.expectEqual(Decision.wait, decide(r, t0 + 365 * day, t));
    }
}

test "fast: asks on the first check, and again right away, but not past max_times" {
    const t0: i64 = 1_700_000_000;
    var r: Record = .{ .first_seen = t0 };
    try testing.expectEqual(Decision.ask, decide(r, t0, .fast));
    r.last_shown = t0;
    r.shown = 1;
    try testing.expectEqual(Decision.ask, decide(r, t0, .fast));
    r.shown = max_times;
    try testing.expectEqual(Decision.wait, decide(r, t0, .fast));
}

test "fromEnv: GIT_ISSUE_STAR_NOW in Debug builds only" {
    var env: Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expectEqual(Timing{}, Timing.fromEnv(&env));
    try env.put("GIT_ISSUE_STAR_NOW", "1");
    const want: Timing = if (builtin.mode == .debug) .fast else .{};
    try testing.expectEqual(want, Timing.fromEnv(&env));
}

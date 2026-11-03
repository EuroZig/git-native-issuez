//! Watches a repository's issues on disk and tells a listener when other
//! processes changed them: `git issue`, another TUI, an agent, a sync.
//!
//! The issues live in refs, and git writes a ref as `<ref>.lock` renamed
//! over `<ref>`, so changes show as directory entries coming and going
//! under the git dir. Only the paths that hold issue state are watched:
//! the issue, milestone and attachment refs, `packed-refs`, `reftable/`
//! and `config` (the issue.* settings). `objects/`, `logs/` and the other
//! refs are never registered, so a big repository costs a few watches.
//!
//! Events come in bursts (a lock, a rename, a sync of a hundred issues).
//! A thread of its own coalesces them: the listener is called once things
//! have been quiet for `Options.quiet`, and at least every
//! `Options.max_delay` while they aren't. It is called on that thread.
//!
//! A changed path says that something may have changed, not what: the
//! listener reads the refs again (see `issuez.changes`). Our own writes
//! are reported too.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const nightwatch = @import("nightwatch");

const RepoWatcher = @This();

/// Directory-only kqueue watches on macOS and the BSDs: git never writes
/// a ref in place, so the directory entries say everything, at one
/// descriptor per directory instead of one per issue.
const Watcher = nightwatch.Create(switch (builtin.os.tag) {
    .linux => .threaded,
    .windows => .windows,
    else => .kqueuedir,
});

/// What changed, as far as the paths tell.
pub const Change = packed struct(u8) {
    /// Issue, milestone or attachment refs.
    refs: bool = false,
    /// The repository's config, which has the issue.* settings.
    config: bool = false,
    _: u6 = 0,

    pub fn any(c: Change) bool {
        return c.refs or c.config;
    }

    pub fn merge(a: Change, b: Change) Change {
        return @bitCast(@as(u8, @bitCast(a)) | @as(u8, @bitCast(b)));
    }
};

pub const Listener = struct {
    context: *anyopaque,
    /// On the watcher's thread. Must not call `deinit`.
    changed: *const fn (context: *anyopaque, change: Change) void,
};

pub const Options = struct {
    /// No event for this long ends a burst.
    quiet: Io.Duration = .fromMilliseconds(40),
    /// A burst that goes on is reported this often.
    max_delay: Io.Duration = .fromMilliseconds(400),
};

io: Io,
gpa: Allocator,
/// Absolute, as `watch` was given it: nightwatch reports paths under it.
git_dir: []u8,
listener: Listener,
options: Options,
handler: Watcher.Handler,
watcher: Watcher,
thread: std.Thread,
/// `Change` bits seen since the listener was last called.
pending: std.atomic.Value(u8) = .init(0),
wake: Io.Event = .unset,
stopping: std.atomic.Value(bool) = .init(false),

/// Starts watching `git_dir`, the repository's common git dir (absolute).
/// In place: nightwatch keeps a pointer to `handler`.
pub fn init(
    self: *RepoWatcher,
    io: Io,
    gpa: Allocator,
    git_dir: []const u8,
    listener: Listener,
    options: Options,
) !void {
    assert(std.fs.path.isAbsolute(git_dir));
    const dir = try gpa.dupe(u8, std.mem.trimEnd(u8, git_dir, "/\\"));
    errdefer gpa.free(dir);
    self.* = .{
        .io = io,
        .gpa = gpa,
        .git_dir = dir,
        .listener = listener,
        .options = options,
        .handler = .{ .vtable = &vtable },
        .watcher = undefined,
        .thread = undefined,
    };
    self.thread = try std.Thread.spawn(.{}, run, .{self});
    errdefer self.stopThread();
    self.watcher = try Watcher.init(io, gpa, &self.handler);
    errdefer self.watcher.deinit();
    try self.watcher.watch(self.git_dir);
}

pub fn deinit(self: *RepoWatcher) void {
    // No more events once nightwatch's thread is joined.
    self.watcher.deinit();
    self.stopThread();
    self.gpa.free(self.git_dir);
    self.* = undefined;
}

fn stopThread(self: *RepoWatcher) void {
    self.stopping.store(true, .release);
    self.wake.set(self.io);
    self.thread.join();
}

const vtable: Watcher.Handler.VTable = .{
    .change = onChange,
    .rename = onRename,
    .should_watch = shouldWatch,
};

fn onChange(
    h: *Watcher.Handler,
    path: []const u8,
    _: nightwatch.EventType,
    _: nightwatch.ObjectType,
) error{HandlerFailed}!void {
    const self: *RepoWatcher = @alignCast(@fieldParentPtr("handler", h));
    self.note(path);
}

fn onRename(
    h: *Watcher.Handler,
    src: []const u8,
    dst: []const u8,
    _: nightwatch.ObjectType,
) error{HandlerFailed}!void {
    const self: *RepoWatcher = @alignCast(@fieldParentPtr("handler", h));
    self.note(src);
    self.note(dst);
}

fn shouldWatch(h: *Watcher.Handler, path: []const u8, kind: nightwatch.ObjectType) bool {
    const self: *RepoWatcher = @alignCast(@fieldParentPtr("handler", h));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = self.relative(path, &buf) orelse return false;
    return switch (kind) {
        .dir => watchesDir(rel),
        .file, .unknown => classify(rel).any(),
    };
}

fn note(self: *RepoWatcher, path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = self.relative(path, &buf) orelse return;
    self.poke(classify(rel));
}

/// Reports `change` as if the paths had shown it, coalesced with what
/// they do show: for a listener that may have missed writes, such as
/// those between its first read and `init`.
pub fn poke(self: *RepoWatcher, change: Change) void {
    if (!change.any()) return;
    _ = self.pending.fetchOr(@bitCast(change), .acq_rel);
    self.wake.set(self.io);
}

/// `path` under the git dir, with `/` separators; null outside it.
fn relative(self: *const RepoWatcher, path: []const u8, buf: []u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, self.git_dir)) return null;
    const rest = path[self.git_dir.len..];
    if (rest.len == 0) return "";
    if (!std.fs.path.isSep(rest[0])) return null;
    const rel = rest[1..];
    if (rel.len > buf.len) return null;
    for (rel, buf[0..rel.len]) |c, *o| o.* = if (c == '\\') '/' else c;
    return buf[0..rel.len];
}

/// Ref namespaces that hold issue state. The guard and cache refs are
/// derived and never change what an issue shows.
const watched_refs = [_][]const u8{ "refs/issues", "refs/milestones", "refs/attachments" };

/// Directories to register, by path under the git dir: the way down to
/// the watched refs, and everything below them.
fn watchesDir(rel: []const u8) bool {
    if (std.mem.eql(u8, rel, "refs") or std.mem.eql(u8, rel, "reftable")) return true;
    for (watched_refs) |prefix| if (under(rel, prefix)) return true;
    return false;
}

/// What a change to `rel`, a path under the git dir, may have changed.
/// A lock file counts as the file it locks: some backends only see the
/// lock come and go.
pub fn classify(rel_in: []const u8) Change {
    const rel = if (std.mem.endsWith(u8, rel_in, ".lock")) rel_in[0 .. rel_in.len - ".lock".len] else rel_in;
    if (std.mem.eql(u8, rel, "config")) return .{ .config = true };
    if (std.mem.eql(u8, rel, "packed-refs") or under(rel, "reftable")) return .{ .refs = true };
    for (watched_refs) |prefix| if (under(rel, prefix)) return .{ .refs = true };
    return .{};
}

/// `path` is `dir` or below it.
fn under(path: []const u8, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return path.len == dir.len or path[dir.len] == '/';
}

fn now(io: Io) Io.Timestamp {
    return Io.Timestamp.now(io, .awake);
}

/// The debounce thread.
fn run(self: *RepoWatcher) void {
    const io = self.io;
    while (true) {
        self.wake.waitUncancelable(io);
        if (self.stopping.load(.acquire)) return;
        const start = now(io);
        while (true) {
            self.wake.reset();
            io.sleep(self.options.quiet, .awake) catch {};
            if (self.stopping.load(.acquire)) return;
            if (!self.wake.isSet()) break;
            if (start.durationTo(now(io)).nanoseconds >= self.options.max_delay.nanoseconds) break;
        }
        // Still set after `max_delay`: the next round reports the rest.
        const change: Change = @bitCast(self.pending.swap(0, .acq_rel));
        if (change.any()) self.listener.changed(self.listener.context, change);
    }
}

const testing = std.testing;

test classify {
    try testing.expectEqual(Change{ .refs = true }, classify("refs/issues/0b8c7a52-3f1e-4d2a-9b6c-5e4f3a2b1c0d"));
    try testing.expectEqual(Change{ .refs = true }, classify("refs/issues/0b8c7a52.lock"));
    try testing.expectEqual(Change{ .refs = true }, classify("refs/issues"));
    try testing.expectEqual(Change{ .refs = true }, classify("refs/milestones/x"));
    try testing.expectEqual(Change{ .refs = true }, classify("refs/attachments/x/y"));
    try testing.expectEqual(Change{ .refs = true }, classify("packed-refs"));
    try testing.expectEqual(Change{ .refs = true }, classify("packed-refs.lock"));
    try testing.expectEqual(Change{ .refs = true }, classify("reftable/tables.list"));
    try testing.expectEqual(Change{ .config = true }, classify("config.lock"));
    for ([_][]const u8{
        "",
        "HEAD",
        "index",
        "index.lock",
        "refs",
        "refs/heads/main",
        "refs/issuesx/a",
        "refs/issuez-guard/x",
        "objects/ab/cdef",
        "logs/refs/issues/x",
        "issuez/tmp/x",
        "config.worktree",
        "FETCH_HEAD",
    }) |rel| try testing.expect(!classify(rel).any());
}

test watchesDir {
    for ([_][]const u8{ "refs", "refs/issues", "refs/milestones/a", "reftable" }) |rel|
        try testing.expect(watchesDir(rel));
    for ([_][]const u8{ "", "objects", "refs/heads", "refs/tags", "refs/remotes/origin", "logs", "hooks", "issuez" }) |rel|
        try testing.expect(!watchesDir(rel));
}

const Recorder = struct {
    seen: std.atomic.Value(u8) = .init(0),
    calls: std.atomic.Value(u32) = .init(0),

    fn changed(context: *anyopaque, change: Change) void {
        const r: *Recorder = @ptrCast(@alignCast(context));
        _ = r.seen.fetchOr(@bitCast(change), .acq_rel);
        _ = r.calls.fetchAdd(1, .acq_rel);
    }

    /// Waits up to 5 s for a call, then takes what was seen.
    fn take(r: *Recorder, io: Io) !Change {
        var waited: u32 = 0;
        while (r.calls.load(.acquire) == 0) : (waited += 1) {
            if (waited == 500) return error.Timeout;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        r.calls.store(0, .release);
        return @bitCast(r.seen.swap(0, .acq_rel));
    }
};

/// What git does to write a file: a lock, renamed over it.
fn gitWrite(io: Io, dir: Io.Dir, path: []const u8, data: []const u8) !void {
    var lock_buf: [256]u8 = undefined;
    const lock = try std.fmt.bufPrint(&lock_buf, "{s}.lock", .{path});
    try dir.writeFile(io, .{ .sub_path = lock, .data = data });
    try dir.rename(lock, dir, path, io);
}

test "reports ref and config writes, not other files" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/ab");
    try tmp.dir.createDirPath(io, "refs/heads");
    try tmp.dir.writeFile(io, .{ .sub_path = "config", .data = "[core]\n" });
    const git_dir = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(git_dir);

    var recorder: Recorder = .{};
    var w: RepoWatcher = undefined;
    try w.init(io, testing.allocator, git_dir, .{ .context = &recorder, .changed = Recorder.changed }, .{});
    defer w.deinit();

    // The first issue makes refs/issues, which nothing watched yet.
    try tmp.dir.createDirPath(io, "refs/issues");
    try gitWrite(io, tmp.dir, "refs/issues/a", "1111\n");
    try testing.expectEqual(Change{ .refs = true }, try recorder.take(io));

    // Then one inside the new directory.
    try io.sleep(.fromMilliseconds(100), .awake);
    try gitWrite(io, tmp.dir, "refs/issues/b", "2222\n");
    try testing.expectEqual(Change{ .refs = true }, try recorder.take(io));

    try gitWrite(io, tmp.dir, "config", "[issue]\n\tdoneStates = done\n");
    try testing.expectEqual(Change{ .config = true }, try recorder.take(io));

    // Branches and objects aren't issues.
    try gitWrite(io, tmp.dir, "refs/heads/main", "3333\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "objects/ab/cdef", .data = "x" });
    try io.sleep(.fromMilliseconds(300), .awake);
    try testing.expectEqual(@as(u32, 0), recorder.calls.load(.acquire));

    // A burst is reported once.
    for (0..20) |i| {
        var name: [32]u8 = undefined;
        try gitWrite(io, tmp.dir, try std.fmt.bufPrint(&name, "refs/issues/c{d}", .{i}), "4444\n");
    }
    try testing.expectEqual(Change{ .refs = true }, try recorder.take(io));
    try io.sleep(.fromMilliseconds(200), .awake);
    try testing.expect(recorder.calls.load(.acquire) <= 1);
}

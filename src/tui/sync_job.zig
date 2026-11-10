//! One sync with a remote, as `git issue sync`, `merge` or `push` runs
//! it, summed up for the status line. Runs on any backend: the TUI's
//! worker thread opens its own, the tests run it inline on the simulator.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const issuez = @import("issuez");

const sync = issuez.sync;

pub const Kind = enum {
    /// Fetch and merge, then push.
    sync,
    /// Fetch and merge only: what automatic syncs do.
    merge,
    push,

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .sync => "sync",
            .merge => "fetch and merge",
            .push => "push",
        };
    }
};

/// What a sync did, in fixed buffers: it outlives the job's memory.
pub const Summary = struct {
    remote_buf: [256]u8 = undefined,
    remote_len: u16 = 0,
    kind: Kind = .sync,
    /// Started by `issue.autoSync`, not by the user.
    auto: bool = false,
    ok: bool = true,
    /// It fetched from the remote and merged, even if a push after failed.
    fetched: bool = false,
    /// Why it failed.
    message_buf: [400]u8 = undefined,
    message_len: u16 = 0,
    /// Issues and milestones created, fast-forwarded or merged here.
    incoming: u32 = 0,
    /// Pushed to the remote.
    outgoing: u32 = 0,
    /// Refused by this sync.
    quarantined: u32 = 0,
    /// Merged with fields still in conflict.
    conflicts: u32 = 0,

    pub fn remote(s: *const Summary) []const u8 {
        return s.remote_buf[0..s.remote_len];
    }

    pub fn message(s: *const Summary) []const u8 {
        return s.message_buf[0..s.message_len];
    }

    pub fn setRemote(s: *Summary, name: []const u8) void {
        s.remote_len = @intCast(@min(name.len, s.remote_buf.len));
        @memcpy(s.remote_buf[0..s.remote_len], name[0..s.remote_len]);
    }

    /// Too long, it is cut at a character, with an ellipsis.
    pub fn fail(s: *Summary, comptime format: []const u8, args: anytype) void {
        s.ok = false;
        var w: std.Io.Writer = .fixed(&s.message_buf);
        w.print(format, args) catch {
            const ellipsis = "\u{2026}";
            var end = s.message_buf.len - ellipsis.len;
            while (end > 0 and s.message_buf[end] & 0xc0 == 0x80) end -= 1;
            @memcpy(s.message_buf[end..][0..ellipsis.len], ellipsis);
            s.message_len = @intCast(end + ellipsis.len);
            return;
        };
        s.message_len = @intCast(w.end);
    }

    fn add(s: *Summary, r: sync.MergeReport) void {
        for (r.entries) |e| switch (e.outcome) {
            .created, .fast_forwarded, .merged => s.incoming += 1,
            .quarantined => if (!e.kept_local) {
                s.quarantined += 1;
            },
            .up_to_date, .local_ahead, .purged => {},
        };
        for (r.entries) |e| {
            if (e.conflicts.len > 0) s.conflicts += 1;
        }
    }
};

/// How long one ssh connection is kept for the next sync to reuse.
pub const ssh_persist_s = 300;

const ssh_base =
    "ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=2";

/// The ssh the sync's git runs, unless the user set their own: it never
/// prompts (the terminal is the TUI's), and gives up on a host that
/// doesn't answer within seconds. With `control_dir`, the first
/// connection to a host is shared by the fetch, the push and the syncs of
/// the next few minutes, so each pays the handshake once.
pub fn sshCommand(buf: []u8, control_dir: ?[]const u8) []const u8 {
    const dir = control_dir orelse return ssh_base;
    return std.fmt.bufPrint(
        buf,
        ssh_base ++ " -o ControlMaster=auto -o ControlPath={s}/%C -o ControlPersist={d}",
        .{ dir, ssh_persist_s },
    ) catch ssh_base;
}

/// A socket path's longest, macOS's: `sockaddr_un.sun_path`, with its 0.
const max_socket_path = 104;
/// What ssh adds to the socket directory: `/` and `%C`, 40 hex digits,
/// then while it sets up a master a temporary suffix, `.` and 16 more.
const socket_suffix = 1 + 40 + 1 + 16;

/// The directory for the shared ssh sockets, null if there is none to
/// trust: `$XDG_RUNTIME_DIR/issuez`, else `/tmp/issuez-<uid>`, made if
/// missing. Another user who could enter it could make our ssh talk
/// through their socket, so it must be a directory, not a link, ours,
/// and closed to everyone else. Short enough for the sockets too.
pub fn controlDir(io: std.Io, buf: []u8, runtime_dir: ?[]const u8, uid: u32) ?[:0]const u8 {
    const dir = if (runtime_dir) |r|
        std.fmt.bufPrintSentinel(
            buf,
            "{s}/issuez",
            .{std.mem.trimEnd(u8, r, "/")},
            0,
        ) catch return null
    else
        std.fmt.bufPrintSentinel(buf, "/tmp/issuez-{d}", .{uid}, 0) catch return null;
    if (dir.len + socket_suffix + 1 > max_socket_path or !std.fs.path.isAbsolute(dir)) return null;
    // It goes unquoted into `GIT_SSH_COMMAND`, which a shell runs, and
    // into ssh's `ControlPath`, which expands `%` and splits on spaces.
    for (dir) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '/', '.', '_', '-' => {},
        else => return null,
    };
    std.Io.Dir.cwd().createDir(io, dir, @fromBackingInt(@intCast(0o700))) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return null,
    };
    return if (isPrivateDir(dir, uid)) dir else null;
}

/// A directory, not a link to one, owned by `uid`, that nobody else may
/// enter, read or write.
fn isPrivateDir(path: [*:0]const u8, uid: u32) bool {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stx: linux.Statx = undefined;
        const rc = linux.statx(
            linux.AT.FDCWD,
            path,
            linux.AT.SYMLINK_NOFOLLOW,
            .{ .TYPE = true, .MODE = true, .UID = true },
            &stx,
        );
        if (linux.errno(rc) != .SUCCESS) return false;
        return linux.S.ISDIR(stx.mode) and stx.uid == uid and stx.mode & 0o077 == 0;
    } else {
        var st: std.c.Stat = undefined;
        if (std.c.fstatat(std.c.AT.FDCWD, path, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return false;
        return std.c.S.ISDIR(st.mode) and st.uid == uid and st.mode & 0o077 == 0;
    }
}

/// The user ID, for the socket directory.
pub fn currentUid() u32 {
    if (builtin.os.tag == .linux) return std.os.linux.getuid();
    return std.c.getuid();
}

/// Whether `ssh -V` says OpenSSH 8.4 or newer. Older ones keep git's
/// stderr open in the master they leave running for the next sync, and
/// git's output only ends when the master exits, minutes later.
pub fn sshSharesSafely(version: []const u8) bool {
    const at = std.mem.find(u8, version, "OpenSSH_") orelse return false;
    var it = std.mem.tokenizeAny(u8, version[at + "OpenSSH_".len ..], ".p, ");
    const major = std.fmt.parseInt(u32, it.next() orelse return false, 10) catch return false;
    const minor = std.fmt.parseInt(u32, it.next() orelse return false, 10) catch return false;
    return major > 8 or (major == 8 and minor >= 4);
}

/// A push this soon after a fetch skips fetching again: what the remote
/// had is still known, and a push the remote moved under is rejected and
/// merged anyway.
pub const fetch_fresh_s = 60;

/// Runs `kind` against `remote` on `backend`. Never fails: errors are in
/// the summary, with git's own words when it has some. `fetched` says the
/// last fetch from `remote` is fresh: a push then doesn't fetch again.
pub fn run(
    comptime B: type,
    backend: *B,
    arena: Allocator,
    remote: []const u8,
    kind: Kind,
    auto: bool,
    fetched: bool,
    progress: ?sync.Progress,
) Summary {
    var out: Summary = .{ .kind = kind, .auto = auto };
    out.setRemote(remote);
    const s = issuez.Sync(B).init(backend);
    const err: anyerror = blk: {
        switch (kind) {
            .sync => {
                const merged = s.merge(
                    arena,
                    remote,
                    .{ .progress = progress },
                ) catch |e| break :blk e;
                out.add(merged);
                out.fetched = true;
                const pushed = s.push(
                    arena,
                    remote,
                    .{ .progress = progress, .fetch = false },
                ) catch |e| break :blk e;
                out.outgoing = @intCast(pushed.pushed);
                for (pushed.merges) |m| out.add(m);
            },
            .merge => {
                out.add(s.merge(arena, remote, .{ .progress = progress }) catch |e| break :blk e);
                out.fetched = true;
            },
            .push => {
                const options: sync.PushOptions = .{ .progress = progress, .fetch = !fetched };
                const pushed = s.push(arena, remote, options) catch |e| break :blk e;
                out.outgoing = @intCast(pushed.pushed);
                for (pushed.merges) |m| out.add(m);
            },
        }
        return out;
    };
    describe(B, backend, &out, err, remote);
    return out;
}

fn describe(comptime B: type, backend: *B, out: *Summary, err: anyerror, remote: []const u8) void {
    const detail = issuez.errors.gitDetail(backend, err);
    // The last line says why; the rest is git's preamble.
    const last = if (detail) |d| blk: {
        var it = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, d, "\n"), '\n');
        break :blk it.first();
    } else null;
    const hint: []const u8 = if (last) |l|
        if (std.ascii.findIgnoreCase(
            l,
            "passphrase",
        ) != null or std.mem.find(u8, l, "Permission denied (") != null or
            std.ascii.findIgnoreCase(l, "Host key verification") != null)
            " (ssh can't ask here: ssh-add the key, or run git issue sync in a terminal once)"
        else if (std.ascii.findIgnoreCase(
            l,
            "terminal prompts disabled",
        ) != null or std.ascii.findIgnoreCase(l, "could not read Username") != null)
            " (the remote wants credentials: set up a credential helper)"
        else
            ""
    else
        "";
    switch (err) {
        error.UnknownRemote => out.fail("no remote '{s}'", .{remote}),
        else => if (last) |l|
            out.fail("{s} with {s} failed: {s}{s}", .{ out.kind.label(), remote, l, hint })
        else
            out.fail(
                "{s} with {s} failed: {f}",
                .{
                    out.kind.label(),
                    remote,
                    issuez.errors.Description{ .err = err, .limits = .{} },
                },
            ),
    }
}

test sshCommand {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 " ++
            "-o ServerAliveCountMax=2 -o ControlMaster=auto " ++
            "-o ControlPath=/run/user/501/issuez/%C -o ControlPersist=300",
        sshCommand(&buf, "/run/user/501/issuez"),
    );
    try std.testing.expectEqualStrings(ssh_base, sshCommand(&buf, null));
}

test controlDir {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    // Short, unlike the test's temporary directory: socket paths are.
    var root_buf: [64]u8 = undefined;
    const t = std.Io.Timestamp.now(io, .real);
    const root = try std.fmt.bufPrint(
        &root_buf,
        "/tmp/issuez-test-{x}",
        .{@as(u64, @intCast(t.nanoseconds))},
    );
    const cwd = std.Io.Dir.cwd();
    try cwd.createDir(io, root, @fromBackingInt(@intCast(0o700)));
    defer cwd.deleteTree(io, root) catch {};
    var tmp = try cwd.openDir(io, root, .{});
    defer tmp.close(io);
    const uid = currentUid();
    var buf: [256]u8 = undefined;
    // Made, private, reused.
    const dir = controlDir(io, &buf, root, uid) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.endsWith(u8, dir, "/issuez"));
    try std.testing.expect(controlDir(io, &buf, root, uid) != null);
    // Someone else's, or open to others: not used.
    try std.testing.expect(controlDir(io, &buf, root, uid +% 1) == null);
    try tmp.setFilePermissions(io, "issuez", @fromBackingInt(@intCast(0o755)), .{});
    try std.testing.expect(controlDir(io, &buf, root, uid) == null);
    // A link to a private directory isn't one.
    try tmp.deleteDir(io, "issuez");
    try tmp.createDir(io, "real", @fromBackingInt(@intCast(0o700)));
    try tmp.symLink(io, "real", "issuez", .{});
    try std.testing.expect(controlDir(io, &buf, root, uid) == null);
    // Too long for a socket.
    try std.testing.expect(controlDir(io, &buf, "/" ++ @as([60]u8, @splat('x')), uid) == null);
    // What a shell or ssh would read as more than a path, though private.
    for ([_][]const u8{ "a b", "a;id", "$(id)", "a%h", "'q" }) |name| {
        try tmp.createDir(io, name, @fromBackingInt(@intCast(0o700)));
        var bad_buf: [128]u8 = undefined;
        const bad = try std.fmt.bufPrint(&bad_buf, "{s}/{s}", .{ root, name });
        try std.testing.expect(controlDir(io, &buf, bad, uid) == null);
    }
}

test sshSharesSafely {
    try std.testing.expect(sshSharesSafely("OpenSSH_9.9p1, LibreSSL 3.3.6"));
    try std.testing.expect(
        sshSharesSafely("OpenSSH_8.4p1 Debian-5+deb11u3, OpenSSL 1.1.1w  11 Sep 2023"),
    );
    try std.testing.expect(
        !sshSharesSafely("OpenSSH_8.2p1 Ubuntu-4ubuntu0.11, OpenSSL 1.1.1f  31 Mar 2020"),
    );
    try std.testing.expect(!sshSharesSafely("OpenSSH_7.4p1, OpenSSL 1.0.2k-fips"));
    try std.testing.expect(!sshSharesSafely("ssh: command not found"));
}

test "failures say what failed, cut at a character" {
    var s: Summary = .{ .kind = .push };
    s.fail("{s}", .{@as([396]u8, @splat('x')) ++ "é and more"});
    try std.testing.expect(std.unicode.utf8ValidateSlice(s.message()));
    try std.testing.expect(std.mem.endsWith(u8, s.message(), "x\u{2026}"));
    try std.testing.expect(s.message().len <= s.message_buf.len);
}

/// What the status line says when it's done.
pub fn report(buf: []u8, s: *const Summary) []const u8 {
    if (!s.ok) return s.message();
    var w: std.Io.Writer = .fixed(buf);
    const verb: []const u8 = switch (s.kind) {
        .sync => "synced with",
        .merge => "fetched from",
        .push => "pushed to",
    };
    w.print("{s} {s}: {d} in, {d} out", .{ verb, s.remote(), s.incoming, s.outgoing }) catch {};
    if (s.quarantined > 0) w.print(" · {d} quarantined", .{s.quarantined}) catch {};
    if (s.conflicts > 0) w.print(" · {d} in conflict", .{s.conflicts}) catch {};
    if (s.quarantined > 0 or s.conflicts > 0) w.writeAll(" (Y)") catch {};
    return w.buffered();
}

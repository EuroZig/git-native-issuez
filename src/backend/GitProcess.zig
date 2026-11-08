//! Backend that runs the `git` binary found in PATH.
//!
//! Children get `LC_ALL=C`, `GIT_TERMINAL_PROMPT=0` and `GIT_FLUSH=1` and run in the
//! repository, and their output and time are bounded. Reads go through one long-lived
//! `git cat-file --batch`, object writes through one long-lived
//! `git hash-object --stdin-paths` per type, ref changes through
//! `git update-ref --stdin`.

const GitProcess = @This();

const std = @import("std");
const stableSort = @import("../sort.zig").stable;
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const contract = @import("contract.zig");
const object = @import("object.zig");
const hex_fmt = @import("../format/hex.zig");
const attachment_fmt = @import("../format/attachment.zig");
const Oid = object.Oid;
const ObjectFormat = object.ObjectFormat;
const ObjectKind = object.ObjectKind;
const Signature = object.Signature;

io: Io,
gpa: Allocator,
env: std.process.Environ.Map,
repo_path: []u8,
/// `OpenOptions.git`, owned.
git_exe: []u8,
format: ObjectFormat,
timeouts: Timeouts,
cat_file: ?*CatFile,
/// One per object type, started on first use.
hash_objects: [std.enums.values(ObjectKind).len]?*HashObject = @splat(null),
/// Absolute, resolved at open.
common_dir: ?[]u8 = null,
/// `$GIT_DIR/issuez/tmp`, created and swept on the first object write.
tmp_dir: ?[]u8 = null,
/// git-lfs's object directory, resolved on first use.
git_lfs_dir: ?[]u8 = null,
/// See `OpenOptions.no_terminal`.
no_terminal: bool = false,
/// Whether `git lfs version` runs, checked once.
git_lfs: ?bool = null,
/// stderr of the last failed command, for error messages.
last_stderr: [max_stderr_kept]u8,
last_stderr_len: u16,
/// Set by an embedder around a call: once it reads true, a git request
/// that is running is killed and fails with Canceled. Waits look at it
/// every `cancel_poll`.
cancel: ?*const std.atomic.Value(bool) = null,

const cancel_poll: Io.Duration = .fromMilliseconds(50);

pub const Error = error{
    OutOfMemory,
    /// Not in PATH or not executable.
    GitSpawnFailed,
    /// Failed, or printed something we couldn't parse.
    GitFailed,
    GitTooOld,
    /// Not inside a repository, or the path doesn't exist.
    NotARepository,
    OutputTooLong,
    /// Took longer than its `Timeouts` allow, and was killed.
    GitTimedOut,
    Canceled,
    /// Reading or writing an LFS store file failed.
    StoreFailed,
};

/// The oldest git whose trailer parsing matches current git, and that has
/// every plumbing feature we use. CI runs it on Debian 11.
pub const min_git_version: std.SemanticVersion = .{ .major = 2, .minor = 30, .patch = 0 };

const max_stdout_bytes = 64 * 1024 * 1024;
const max_stderr_bytes = 64 * 1024;
const max_stderr_kept = 1024;
const max_object_bytes = 64 * 1024 * 1024;
/// POSIX's PIPE_BUF.
const pipe_buf = if (builtin.os.tag == .linux) 4096 else 512;

pub const OpenOptions = struct {
    /// Any directory inside the repository, or the git dir of a bare one.
    path: []const u8,
    environ_map: *const std.process.Environ.Map,
    timeouts: Timeouts = .{},
    /// The git to run: a name looked up on the environment's PATH, or a
    /// path. Embedders pass the one they already use.
    git: []const u8 = "git",
    /// Checked while opening; not retained by the returned backend.
    cancel: ?*const std.atomic.Value(bool) = null,
    /// git runs in a session of its own, without a controlling terminal,
    /// so nothing it starts (ssh, a credential helper) can prompt on the
    /// terminal or read from it: for a program that owns the terminal,
    /// like a TUI. On Windows git gets no console.
    no_terminal: bool = false,
};

/// The longest a call may take, start to finish, before git is stopped and
/// the call fails with `GitTimedOut`. Generous, so that a slow call still
/// finishes: they are there for a git that hangs, on a hook, a credential
/// helper or a dead connection. git gets SIGTERM, so it removes its locks.
pub const Timeouts = struct {
    /// A local command, from start to exit.
    command: Io.Duration = .fromSeconds(120),
    /// One request to the long-lived `cat-file` or `hash-object`.
    request: Io.Duration = .fromSeconds(60),
    /// `fetch` and `push`, from start to exit.
    network: Io.Duration = .fromSeconds(600),
    /// One batch of git-lfs transfers, from start to exit.
    transfer: Io.Duration = .fromSeconds(1800),
};

pub fn open(io: Io, gpa: Allocator, options: OpenOptions) Error!GitProcess {
    if (options.cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
    var env = try options.environ_map.clone(gpa);
    errdefer env.deinit();
    try env.put("LC_ALL", "C");
    try env.put("GIT_TERMINAL_PROMPT", "0");
    // The sessions wait for each answer; `GIT_FLUSH=0` would hold them back.
    try env.put("GIT_FLUSH", "1");

    // git runs in `path`; a missing one would fail as `GitSpawnFailed`,
    // which says git isn't installed.
    Io.Dir.cwd().access(io, options.path, .{}) catch |e| switch (e) {
        error.FileNotFound => return error.NotARepository,
        else => {},
    };

    const repo_path = try gpa.dupe(u8, options.path);
    errdefer gpa.free(repo_path);
    var git_exe = try gpa.dupe(u8, options.git);
    errdefer gpa.free(git_exe);

    var gp: GitProcess = .{
        .io = io,
        .gpa = gpa,
        .env = env,
        .repo_path = repo_path,
        .git_exe = git_exe,
        .format = .sha1,
        .timeouts = options.timeouts,
        .cancel = options.cancel,
        .no_terminal = options.no_terminal,
        .cat_file = null,
        .last_stderr = undefined,
        .last_stderr_len = 0,
    };

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (builtin.os.tag == .macos and std.mem.eql(u8, options.git, "git") and gitIsAppleStub(gp)) {
        if (try realGit(&gp, arena)) |real| {
            gpa.free(git_exe);
            git_exe = real;
            gp.git_exe = real;
        }
    }

    const both = try gp.runPair(
        arena,
        &.{ "git", "version" },
        &.{ "git", "rev-parse", "--show-object-format", "--git-common-dir" },
    );
    if (!both[0].ok()) {
        gp.keepStderr(both[0].stderr);
        return error.GitFailed;
    }
    const version = parseGitVersion(both[0].stdout) orelse return error.GitFailed;
    if (version.order(min_git_version) == .lt) return error.GitTooOld;

    const rp = both[1];
    if (!rp.ok()) return error.NotARepository;
    var lines = std.mem.splitScalar(u8, rp.stdout, '\n');
    gp.format = ObjectFormat.parse(lines.next() orelse "") orelse return error.GitFailed;
    const common = lines.next() orelse return error.GitFailed;
    if (common.len == 0) return error.GitFailed;
    // Absolute for real: git reads the temp files' paths from its own cwd.
    const cwd = std.process.currentPathAlloc(io, arena) catch return error.GitFailed;
    gp.common_dir = try std.fs.path.resolve(gpa, &.{ cwd, repo_path, common });
    gp.cancel = null;
    return gp;
}

/// Whether `git` on the PATH is /usr/bin/git, which on macOS only looks up the
/// real one: 5 ms per run, and a program runs many. Not any other git the
/// user chose, and not under `git issue`, where git put its own first.
fn gitIsAppleStub(gp: GitProcess) bool {
    const path = gp.env.get("PATH") orelse "/usr/bin:/bin";
    var dirs = std.mem.tokenizeScalar(u8, path, ':');
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    while (dirs.next()) |dir| {
        const git = std.fmt.bufPrint(&buffer, "{s}/git", .{dir}) catch continue;
        Io.Dir.cwd().access(gp.io, git, .{ .execute = true }) catch continue;
        return std.mem.eql(u8, dir, "/usr/bin");
    }
    return false;
}

/// The git behind `git`, or null if it can't say: then `git` it stays.
fn realGit(gp: *GitProcess, arena: Allocator) Allocator.Error!?[]u8 {
    const result = gp.run(arena, &.{ "git", "--exec-path" }, null) catch |e| switch (e) {
        error.OutOfMemory => |oom| return oom,
        else => return null,
    };
    if (!result.ok()) return null;
    const dir = std.mem.trimEnd(u8, result.stdout, "\n");
    const git = try std.fs.path.join(gp.gpa, &.{ dir, "git" });
    Io.Dir.cwd().access(gp.io, git, .{ .execute = true }) catch {
        gp.gpa.free(git);
        return null;
    };
    return git;
}

/// A private repository sharing the target's objects. Deinit aborts an
/// unpublished import; unreachable objects are left for normal Git GC.
/// Do not write to the staging repository concurrently with commit/deinit.
pub const Import = struct {
    git: GitProcess,
    path: []u8,
    target_dir: []u8,
    committed: bool = false,

    pub const CommitError = @import("../engine/repo.zig").Repo(GitProcess).Error ||
        error{RefConflict};

    pub fn commit(stage: *Import, arena: Allocator, target: *GitProcess) CommitError!usize {
        if (stage.committed or !std.mem.eql(u8, stage.target_dir, target.common_dir.?))
            return error.InvalidValue;
        const Repo = @import("../engine/repo.zig").Repo(GitProcess);
        const n = try Repo.init(target).adoptFrom(arena, Repo.init(&stage.git));
        stage.committed = true;
        return n;
    }

    pub fn deinit(stage: *Import) void {
        const io = stage.git.io;
        const gpa = stage.git.gpa;
        stage.git.close();
        Io.Dir.cwd().deleteTree(io, stage.path) catch {};
        gpa.free(stage.path);
        gpa.free(stage.target_dir);
        stage.* = undefined;
    }
};

/// Stages an import with the same git, environment and object format.
/// Publish with Import.commit; deinit always removes its private refs.
pub fn beginImport(gp: *GitProcess, arena: Allocator) Error!Import {
    var random: [16]u8 = undefined;
    gp.randomBytes(&random);
    const path = try std.fmt.allocPrint(gp.gpa, "{s}/issuez/import-{s}", .{
        gp.common_dir.?,
        std.fmt.bytesToHex(random, .lower),
    });
    errdefer gp.gpa.free(path);
    const parent = std.fs.path.dirname(path).?;
    Io.Dir.cwd().createDirPath(gp.io, parent) catch return error.GitFailed;
    Io.Dir.cwd().createDir(gp.io, path, .default_dir) catch return error.GitFailed;
    errdefer Io.Dir.cwd().deleteTree(gp.io, path) catch {};
    var env = try gp.env.clone(gp.gpa);
    defer env.deinit();
    for ([_][]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE" }) |key|
        _ = env.swapRemove(key);
    // Local user config is not present in a fresh bare repo.
    inline for (.{
        .{ "user.name", "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME" },
        .{ "user.email", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL" },
    }) |keys| {
        if (try gp.configGet(arena, keys[0])) |value| {
            for ([_][]const u8{ keys[1], keys[2] }) |key| if (env.get(key) == null) {
                try env.put(key, value);
            };
        }
    }
    const result = try gp.run(arena, &.{ "git", "rev-parse", "--git-path", "objects" }, null);
    if (!result.ok()) return error.GitFailed;
    // --git-path is relative to git's cwd, even with an external object store.
    const cwd = std.process.currentPathAlloc(gp.io, arena) catch return error.GitFailed;
    const objects = try std.fs.path.resolve(arena, &.{
        cwd,
        gp.repo_path,
        std.mem.trimEnd(u8, result.stdout, "\n"),
    });
    try env.put("GIT_OBJECT_DIRECTORY", objects);
    var init_git = gp.*;
    init_git.env = env;
    init_git.repo_path = path;
    const format_arg = try std.fmt.allocPrint(arena, "--object-format={s}", .{@tagName(gp.format)});
    const initialized = try init_git.run(
        arena,
        &.{ "git", "init", "--bare", format_arg, "." },
        null,
    );
    if (!initialized.ok()) return error.GitFailed;
    var git = try GitProcess.open(gp.io, gp.gpa, .{
        .path = path,
        .environ_map = &env,
        .git = gp.git_exe,
        .timeouts = gp.timeouts,
        .cancel = gp.cancel,
    });
    errdefer git.close();
    return .{ .git = git, .path = path, .target_dir = try gp.gpa.dupe(u8, gp.common_dir.?) };
}

pub fn close(gp: *GitProcess) void {
    if (gp.cat_file) |cf| cf.deinit(gp.io, gp.gpa);
    for (gp.hash_objects) |h| if (h) |ho| ho.deinit(gp.io, gp.gpa);
    if (gp.common_dir) |d| gp.gpa.free(d);
    if (gp.tmp_dir) |d| gp.gpa.free(d);
    if (gp.git_lfs_dir) |d| gp.gpa.free(d);
    gp.env.deinit();
    gp.gpa.free(gp.repo_path);
    gp.gpa.free(gp.git_exe);
    gp.* = undefined;
}

/// Ends the long-lived `cat-file` session; the next read starts a new one.
/// For a long-running program between operations: the session may keep
/// its view of the refs, and others write them meanwhile. The
/// `hash-object` sessions only write objects, so they stay, and the
/// repository isn't looked up again.
pub fn refresh(gp: *GitProcess) void {
    if (gp.cat_file) |cf| cf.deinit(gp.io, gp.gpa);
    gp.cat_file = null;
}

/// The error output of the latest git command if it failed, up to 1 KiB;
/// empty after a command that succeeded. Read it right after the failing
/// call, before anything else runs git. See `issuez.errors.gitDetail`.
pub fn lastStderr(gp: *const GitProcess) []const u8 {
    return gp.last_stderr[0..gp.last_stderr_len];
}

pub fn objectFormat(gp: *const GitProcess) ObjectFormat {
    return gp.format;
}

pub fn readObject(gp: *GitProcess, arena: Allocator, oid: Oid) Error!?contract.Object {
    assert(oid.object_format == gp.format);
    const cf = try gp.catFile();
    cf.reader.cancel = gp.cancel;
    return cf.read(arena, oid, gp.deadline(gp.timeouts.request)) catch |err| {
        // A broken session can't be reused. The next read starts a new one.
        cf.deinit(gp.io, gp.gpa);
        gp.cat_file = null;
        return err;
    };
}

/// git writes the object, so its permissions, fsync and checks apply. The
/// data goes through a temporary file to the type's `hash-object` session;
/// if that fails, a one-off `hash-object` says why.
pub fn writeObject(gp: *GitProcess, kind: ObjectKind, data: []const u8) Error!Oid {
    if (gp.writeObjectSession(kind, data)) |oid| {
        assert(oid.eql(object.hashObject(gp.format, kind, data)));
        return oid;
    } else |err| switch (err) {
        // Another git would wait on whatever this one waited on.
        error.OutOfMemory, error.Canceled, error.GitTimedOut => |e| return e,
        else => {},
    }
    var arena_state: std.heap.ArenaAllocator = .init(gp.gpa);
    defer arena_state.deinit();
    const out = try gp.runOk(
        arena_state.allocator(),
        &.{ "git", "hash-object", "-w", "-t", @tagName(kind), "--stdin" },
        data,
    );
    const oid = Oid.parseHex(
        gp.format,
        std.mem.trimEnd(u8, out, "\n"),
    ) catch return error.GitFailed;
    assert(oid.eql(object.hashObject(gp.format, kind, data)));
    return oid;
}

fn writeObjectSession(gp: *GitProcess, kind: ObjectKind, data: []const u8) Error!Oid {
    var arena_state: std.heap.ArenaAllocator = .init(gp.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try gp.tmpDir();
    var suffix: [8]u8 = undefined;
    gp.io.random(&suffix);
    const path = try std.fmt.allocPrint(arena, "{s}/object-{x}", .{ dir, suffix });
    // git reads one path per line and unquotes a line starting with '"';
    // the one-off fallback takes such a repository path.
    if (std.mem.findScalar(u8, path, '\n') != null or path[0] == '"') return error.GitFailed;
    const slot = &gp.hash_objects[@intFromEnum(kind)];
    if (slot.* == null) slot.* = try HashObject.start(gp, kind);
    const ho = slot.*.?;

    const cwd = Io.Dir.cwd();
    {
        const file = cwd.createFile(gp.io, path, .{ .exclusive = true }) catch
            return error.GitFailed;
        defer file.close(gp.io);
        file.writeStreamingAll(gp.io, data) catch {
            cwd.deleteFile(gp.io, path) catch {};
            return error.GitFailed;
        };
    }
    defer cwd.deleteFile(gp.io, path) catch {};
    ho.reader.cancel = gp.cancel;
    return ho.hash(path, gp.deadline(gp.timeouts.request)) catch |err| {
        ho.deinit(gp.io, gp.gpa);
        slot.* = null;
        return err;
    };
}

/// Temporary files older than this are left over from a process that
/// died mid-write.
const tmp_max_age_ns = 24 * std.time.ns_per_hour;

fn tmpDir(gp: *GitProcess) Error![]const u8 {
    if (gp.tmp_dir) |d| return d;
    const dir = try std.fs.path.join(gp.gpa, &.{ gp.common_dir.?, "issuez", "tmp" });
    errdefer gp.gpa.free(dir);
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(gp.io, dir) catch return error.GitFailed;
    gp.tmp_dir = dir;
    gp.sweepTmp(dir);
    return dir;
}

/// Best effort: a stale file only takes space.
fn sweepTmp(gp: *GitProcess, dir_path: []const u8) void {
    var dir = Io.Dir.cwd().openDir(gp.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(gp.io);
    const now = Io.Clock.real.now(gp.io).nanoseconds;
    var it = dir.iterate();
    while (it.next(gp.io) catch return) |e| {
        if (e.kind != .file or !std.mem.startsWith(u8, e.name, "object-")) continue;
        const st = dir.statFile(gp.io, e.name, .{}) catch continue;
        if (now - st.mtime.nanoseconds < tmp_max_age_ns) continue;
        dir.deleteFile(gp.io, e.name) catch {};
    }
}

/// Through the `cat-file` session rather than a `rev-parse` per ref. It
/// reads the ref each time, so it sees changes made since.
pub fn resolveRef(gp: *GitProcess, name: []const u8) Error!?Oid {
    assert(contract.isValidRefName(name));
    const cf = try gp.catFile();
    cf.reader.cancel = gp.cancel;
    const found = cf.resolve(name, gp.deadline(gp.timeouts.request)) catch |err| {
        cf.deinit(gp.io, gp.gpa);
        gp.cat_file = null;
        return err;
    };
    return switch (found) {
        .oid => |oid| oid,
        // No such ref, or one whose object is missing: only `rev-parse`
        // tells them apart, and a missing object is still the ref's value.
        .missing => gp.revParseRef(name),
    };
}

fn revParseRef(gp: *GitProcess, name: []const u8) Error!?Oid {
    var arena_state: std.heap.ArenaAllocator = .init(gp.gpa);
    defer arena_state.deinit();
    const result = try gp.run(
        arena_state.allocator(),
        &.{ "git", "rev-parse", "-q", "--verify", "--end-of-options", name },
        null,
    );
    if (!result.ok()) return null;
    return Oid.parseHex(gp.format, std.mem.trimEnd(u8, result.stdout, "\n")) catch
        error.GitFailed;
}

pub fn listRefs(gp: *GitProcess, arena: Allocator, prefix: []const u8) Error![]contract.RefEntry {
    assert(std.mem.startsWith(u8, prefix, "refs/"));
    const out = try gp.runOk(arena, &.{
        "git",                               "for-each-ref",
        "--format=%(objectname) %(refname)", "--sort=refname",
        "--",                                prefix,
    }, null);
    var entries: std.ArrayList(contract.RefEntry) = .empty;
    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const sp = std.mem.findScalar(u8, line, ' ') orelse return error.GitFailed;
        const oid = Oid.parseHex(gp.format, line[0..sp]) catch return error.GitFailed;
        try entries.append(arena, .{ .name = line[sp + 1 ..], .oid = oid });
    }
    return entries.toOwnedSlice(arena);
}

pub fn updateRefs(
    gp: *GitProcess,
    updates: []const contract.RefUpdate,
) (Error || error{RefConflict})!void {
    assert(updates.len > 0);
    // Never cancelled halfway: a transaction killed mid-commit leaves the
    // caller unable to tell whether it landed. It's local and quick.
    const cancel = gp.cancel;
    gp.cancel = null;
    defer gp.cancel = cancel;
    var arena_state: std.heap.ArenaAllocator = .init(gp.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zero = zeroOid(gp.format);
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    for (updates) |u| {
        assert(contract.isValidRefName(u.name));
        const written = switch (u.op) {
            .create => |new| w.print("create {s} {f}\n", .{ u.name, new }),
            .update => |x| w.print("update {s} {f} {f}\n", .{ u.name, x.new, x.old }),
            .delete => |old| w.print("delete {s} {f}\n", .{ u.name, old }),
            .verify => |old| w.print("verify {s} {f}\n", .{ u.name, old orelse zero }),
        };
        written catch return error.OutOfMemory;
    }

    const result = gp.run(arena, &.{ "git", "update-ref", "--stdin" }, aw.written()) catch |err|
        switch (err) {
            // Hooks also run once the refs have moved, so it may be done.
            error.GitTimedOut => if (try gp.refsAre(updates, .new)) return else return err,
            else => return err,
        };
    if (result.ok()) return;

    // Tell a lost CAS race from other failures by re-reading the expected
    // values.
    if (!try gp.refsAre(updates, .old)) return error.RefConflict;
    gp.keepStderr(result.stderr);
    return error.GitFailed;
}

/// Whether every ref has the value it should have before, or after, the
/// updates.
fn refsAre(
    gp: *GitProcess,
    updates: []const contract.RefUpdate,
    side: enum { old, new },
) Error!bool {
    for (updates) |u| {
        const expected: ?Oid = switch (u.op) {
            .create => |new| if (side == .new) new else null,
            .update => |x| if (side == .new) x.new else x.old,
            .delete => |old| if (side == .new) null else old,
            .verify => |old| old,
        };
        const actual = try gp.resolveRef(u.name);
        const same = if (expected) |e| (actual != null and actual.?.eql(e)) else actual == null;
        if (!same) return false;
    }
    return true;
}

pub fn isAncestor(gp: *GitProcess, ancestor: Oid, descendant: Oid) Error!bool {
    var arena_state: std.heap.ArenaAllocator = .init(gp.gpa);
    defer arena_state.deinit();
    const a = ancestor.hex();
    const d = descendant.hex();
    const result = try gp.run(
        arena_state.allocator(),
        &.{ "git", "merge-base", "--is-ancestor", a.slice(), d.slice() },
        null,
    );
    if (result.ok()) return true;
    if (result.exitCode() == 1) return false;
    gp.keepStderr(result.stderr);
    return error.GitFailed;
}

pub fn mergeBases(gp: *GitProcess, arena: Allocator, a: Oid, b: Oid) Error![]Oid {
    const ah = a.hex();
    const bh = b.hex();
    const result = try gp.run(
        arena,
        &.{ "git", "merge-base", "--all", ah.slice(), bh.slice() },
        null,
    );
    if (!result.ok()) {
        if (result.exitCode() == 1) return &.{}; // unrelated histories
        gp.keepStderr(result.stderr);
        return error.GitFailed;
    }
    var bases: std.ArrayList(Oid) = .empty;
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        try bases.append(arena, Oid.parseHex(gp.format, line) catch return error.GitFailed);
    }
    stableSort(Oid, bases.items, {}, oidLessThan);
    return bases.toOwnedSlice(arena);
}

pub fn configGet(gp: *GitProcess, arena: Allocator, key: []const u8) Error!?[]const u8 {
    const result = try gp.run(arena, &.{ "git", "config", "--get", "--", key }, null);
    if (!result.ok()) {
        if (result.exitCode() == 1) return null;
        gp.keepStderr(result.stderr);
        return error.GitFailed;
    }
    return std.mem.trimEnd(u8, result.stdout, "\n");
}

pub fn configGetAll(gp: *GitProcess, arena: Allocator, key: []const u8) Error![]const []const u8 {
    const result = try gp.run(arena, &.{ "git", "config", "--get-all", "--", key }, null);
    if (!result.ok()) {
        if (result.exitCode() == 1) return &.{};
        gp.keepStderr(result.stderr);
        return error.GitFailed;
    }
    return splitLines(arena, result.stdout);
}

pub fn configAdd(gp: *GitProcess, key: []const u8, value: []const u8) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gp.gpa);
    defer arena_state.deinit();
    _ = try gp.runOk(
        arena_state.allocator(),
        &.{ "git", "config", "--add", "--", key, value },
        null,
    );
}

/// Removes every value of `key` equal to `value`.
pub fn configUnsetValue(gp: *GitProcess, key: []const u8, value: []const u8) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gp.gpa);
    defer arena_state.deinit();
    const result = try gp.run(
        arena_state.allocator(),
        &.{ "git", "config", "--fixed-value", "--unset-all", "--", key, value },
        null,
    );
    // 5 means nothing matched.
    if (!result.ok() and result.exitCode() != 5) {
        gp.keepStderr(result.stderr);
        return error.GitFailed;
    }
}

pub const ConfigEntry = contract.ConfigEntry;

/// Every config entry in git's order, keys as `git config --list` prints
/// them (section and name lowercase): the contract's optional
/// `configList`, which reads the settings in one git call.
pub fn configList(gp: *GitProcess, arena: Allocator) Error![]const ConfigEntry {
    const out = try gp.runOk(arena, &.{ "git", "config", "--list", "-z" }, null);
    var entries: std.ArrayList(ConfigEntry) = .empty;
    var it = std.mem.tokenizeScalar(u8, out, 0);
    while (it.next()) |item| {
        // A key without `=` in the file has no value, and no newline here.
        const nl = std.mem.findScalar(u8, item, '\n');
        try entries.append(arena, .{
            .key = if (nl) |n| item[0..n] else item,
            .value = if (nl) |n| item[n + 1 ..] else "",
        });
    }
    return entries.items;
}

pub fn remoteNames(gp: *GitProcess, arena: Allocator) Error![]const []const u8 {
    return splitLines(arena, try gp.runOk(arena, &.{ "git", "remote" }, null));
}

/// Only the given refspecs write refs: `--refmap=` stops git from also
/// updating refs through `remote.<name>.fetch`, which with upstream's
/// `+refs/issues/*:refs/issues/*` would reset unpushed local issues. Tags
/// and FETCH_HEAD are left alone. `prune` deletes the refs under the
/// refspecs' destinations that the remote no longer has.
pub fn fetch(
    gp: *GitProcess,
    arena: Allocator,
    remote: []const u8,
    refspecs: []const []const u8,
    options: contract.FetchOptions,
) (Error || error{FetchFailed})!void {
    assert(contract.isValidRemoteTarget(remote));
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "git", "fetch", "--no-tags", "--no-write-fetch-head" });
    if (options.prune) try argv.append(arena, "--prune");
    try argv.appendSlice(arena, &.{ "--refmap=", "--quiet", "--", remote });
    try argv.appendSlice(arena, refspecs);
    const result = try gp.runWithin(arena, argv.items, null, gp.timeouts.network);
    if (!result.ok()) {
        gp.keepStderr(result.stderr);
        return error.FetchFailed;
    }
}

/// Never forced. Falls back to a plain push when the remote can't do
/// atomic pushes.
pub fn push(
    gp: *GitProcess,
    arena: Allocator,
    remote: []const u8,
    refspecs: []const []const u8,
    options: contract.PushOptions,
) (Error || error{PushFailed})!contract.PushResult {
    assert(contract.isValidRemoteTarget(remote));
    assert(refspecs.len > 0);
    var argv: std.ArrayList([]const u8) = .empty;
    // Hooks run like for any push, so the user's pre-push policies apply.
    // git-lfs's would refuse derived refs whose history points at objects
    // nobody has, e.g. one removed before its first push. Sync uploads
    // what is needed itself, before the refs.
    try gp.env.put("GIT_LFS_SKIP_PUSH", "1");
    defer _ = gp.env.swapRemove("GIT_LFS_SKIP_PUSH");
    try argv.appendSlice(arena, &.{ "git", "push", "--porcelain" });
    if (options.atomic) try argv.append(arena, "--atomic");
    try argv.appendSlice(arena, &.{ "--", remote });
    try argv.appendSlice(arena, refspecs);
    const result = try gp.runWithin(arena, argv.items, null, gp.timeouts.network);
    if (options.atomic and !result.ok() and std.mem.find(
        u8,
        result.stderr,
        "does not support --atomic",
    ) != null) {
        return gp.push(arena, remote, refspecs, .{});
    }
    return gp.pushResult(arena, result);
}

/// `git push --atomic --force-with-lease=<dst>:<expect> <src>:<dst>`, or
/// `:<dst>` to delete. Not `+<src>`: that would force past the lease. No
/// fallback without `--atomic`: a partial purge would leave the remote half
/// rewritten.
pub fn pushLeased(
    gp: *GitProcess,
    arena: Allocator,
    remote: []const u8,
    updates: []const contract.LeasedRef,
) (Error || error{PushFailed})!contract.PushResult {
    assert(contract.isValidRemoteTarget(remote));
    assert(updates.len > 0);
    var argv: std.ArrayList([]const u8) = .empty;
    try gp.env.put("GIT_LFS_SKIP_PUSH", "1");
    defer _ = gp.env.swapRemove("GIT_LFS_SKIP_PUSH");
    try argv.appendSlice(arena, &.{ "git", "push", "--porcelain", "--atomic" });
    for (updates) |u| {
        assert(contract.isValidRefName(u.dst));
        const hex = if (u.expect) |e| e.hex() else null;
        try argv.append(arena, try std.fmt.allocPrint(arena, "--force-with-lease={s}:{s}", .{
            u.dst,
            if (hex) |*h| h.slice() else "",
        }));
    }
    try argv.appendSlice(arena, &.{ "--", remote });
    for (updates) |u| try argv.append(arena, if (u.src) |src|
        try std.fmt.allocPrint(arena, "{s}:{s}", .{ src, u.dst })
    else
        try std.fmt.allocPrint(arena, ":{s}", .{u.dst}));
    const result = try gp.runWithin(arena, argv.items, null, gp.timeouts.network);
    return gp.pushResult(arena, result);
}

fn pushResult(
    gp: *GitProcess,
    arena: Allocator,
    result: anytype,
) (Error || error{PushFailed})!contract.PushResult {
    // "<flag>\t<src>:<dst>\t<summary>" per ref
    var refs: std.ArrayList(contract.PushedRef) = .empty;
    var refused = false;
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 3 or line[1] != '\t') continue;
        var fields = std.mem.splitScalar(u8, line[2..], '\t');
        const spec = fields.next() orelse continue;
        const colon = std.mem.findScalar(u8, spec, ':') orelse continue;
        const status: contract.PushedRef.Status = switch (line[0]) {
            ' ', '*', '+', '-' => .ok,
            '=' => .up_to_date,
            else => .rejected,
        };
        if (refusedBy(fields.next() orelse "")) refused = true;
        try refs.append(arena, .{ .name = spec[colon + 1 ..], .status = status });
    }
    if (refused or (!result.ok() and refs.items.len == 0)) {
        gp.keepStderr(result.stderr);
        return error.PushFailed;
    }
    return .{ .refs = refs.items };
}

/// Whether a ref's push summary is the server refusing it for good.
/// "[rejected]" comes from git itself: the remote moved. "[remote
/// rejected]" is the server refusing (a hook, permissions), which no
/// retry fixes, unless the ref only failed with another one, or the
/// remote moved while it received the push (its ref transaction lost the
/// race to another writer).
fn refusedBy(summary: []const u8) bool {
    if (!std.mem.startsWith(u8, summary, "[remote rejected]")) return false;
    const moved = [_][]const u8{
        "atomic push fail",
        // The ref changed between the advertisement and the update, with
        // --atomic and without.
        "atomic transaction failed",
        "failed to update ref",
        "cannot lock ref",
    };
    for (moved) |m| if (std.mem.find(u8, summary, m) != null) return false;
    return true;
}

test refusedBy {
    try std.testing.expect(!refusedBy("[rejected] (non-fast-forward)"));
    try std.testing.expect(!refusedBy("[rejected] (stale info)"));
    try std.testing.expect(!refusedBy("[remote rejected] (atomic push failure)"));
    try std.testing.expect(!refusedBy("[remote rejected] (atomic transaction failed)"));
    try std.testing.expect(!refusedBy("[remote rejected] (failed to update ref)"));
    try std.testing.expect(refusedBy("[remote rejected] (pre-receive hook declined)"));
    try std.testing.expect(refusedBy("[remote rejected] (deny updating a hidden ref)"));
    try std.testing.expect(!refusedBy("[new branch]"));
}

fn splitLines(arena: Allocator, text: []const u8) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| try out.append(arena, line);
    return out.items;
}

/// Author and committer as git would pick them, with the current time.
/// IdentityUnknown when git has none.
pub fn identity(
    gp: *GitProcess,
    arena: Allocator,
) (Error || error{IdentityUnknown})!contract.Identity {
    // Like upstream, insist on a configured identity. Without useConfigOnly
    // git makes one up from the login and hostname, and that would end up
    // in the issue history. (`git var -l` ignores it, so two calls.)
    const both = try gp.runPair(
        arena,
        &.{ "git", "-c", "user.useConfigOnly=true", "var", "GIT_AUTHOR_IDENT" },
        &.{ "git", "-c", "user.useConfigOnly=true", "var", "GIT_COMMITTER_IDENT" },
    );
    return .{
        .author = try gp.ident(both[0]),
        .committer = try gp.ident(both[1]),
    };
}

fn ident(gp: *GitProcess, result: RunResult) (Error || error{IdentityUnknown})!Signature {
    if (!result.ok()) {
        gp.keepStderr(result.stderr);
        return error.IdentityUnknown;
    }
    return Signature.parse(std.mem.trimEnd(u8, result.stdout, "\n")) catch error.GitFailed;
}

pub fn randomBytes(gp: *GitProcess, buf: []u8) void {
    gp.io.random(buf);
}

/// `issuez` is `$GIT_DIR/issuez/lfs/objects/`, the store; `git lfs prune`
/// doesn't look there. `git_lfs` is git-lfs's (`$GIT_DIR/lfs/objects/` or
/// `lfs.storage`), only a copy for transfers.
const Store = enum { issuez, git_lfs };

/// The directory holding `ab/cd/<sha256>`.
fn lfsObjectsDir(gp: *GitProcess, arena: Allocator, store: Store) Error![]const u8 {
    const common = gp.common_dir.?;
    switch (store) {
        .issuez => return std.fs.path.join(arena, &.{ common, "issuez", "lfs", "objects" }),
        .git_lfs => {
            if (gp.git_lfs_dir == null) {
                // Relative to the git dir, like git-lfs does it. Empty
                // means the default for git-lfs too.
                const storage = (try gp.configGet(arena, "lfs.storage")) orelse "";
                gp.git_lfs_dir = try if (storage.len > 0)
                    std.fs.path.resolve(gp.gpa, &.{ common, storage, "objects" })
                else
                    std.fs.path.join(gp.gpa, &.{ common, "lfs", "objects" });
            }
            return gp.git_lfs_dir.?;
        },
    }
}

fn lfsPath(arena: Allocator, objects: []const u8, sha256: []const u8) Error![]const u8 {
    assert(isSha256Hex(sha256));
    return std.fs.path.join(arena, &.{ objects, sha256[0..2], sha256[2..4], sha256 });
}

fn isSha256Hex(s: []const u8) bool {
    return s.len == 64 and hex_fmt.isLower(s);
}

/// Our copy when it hashes right. Otherwise git-lfs's, e.g. after a
/// `git lfs fetch`, put into our store when it hashes right; else whatever
/// we have.
pub fn lfsRead(gp: *GitProcess, arena: Allocator, sha256: []const u8) Error!?[]const u8 {
    const ours = try gp.readStore(arena, .issuez, sha256);
    if (ours) |data| if (hashes(data, sha256)) return data;
    const theirs = (try gp.readStore(arena, .git_lfs, sha256)) orelse return ours;
    if (!hashes(theirs, sha256)) return ours orelse theirs;
    try gp.writeStore(.issuez, sha256, theirs);
    return theirs;
}

/// The size of our copy, without reading it.
pub fn lfsSize(gp: *GitProcess, sha256: []const u8) Error!?u64 {
    var arena_state: std.heap.ArenaAllocator = .init(gp.gpa);
    defer arena_state.deinit();
    return gp.storeSize(arena_state.allocator(), .issuez, sha256);
}

fn storeSize(gp: *GitProcess, arena: Allocator, store: Store, sha256: []const u8) Error!?u64 {
    const path = try lfsPath(arena, try gp.lfsObjectsDir(arena, store), sha256);
    const st = Io.Dir.cwd().statFile(gp.io, path, .{}) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return null,
        else => return storeError(e),
    };
    return if (st.kind == .file) st.size else null;
}

fn hashes(data: []const u8, sha256: []const u8) bool {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, &hex, sha256);
}

fn readStore(
    gp: *GitProcess,
    arena: Allocator,
    store: Store,
    sha256: []const u8,
) Error!?[]const u8 {
    const path = try lfsPath(arena, try gp.lfsObjectsDir(arena, store), sha256);
    // The limit fails once reached, and a maximal object is valid.
    const limit: Io.Limit = .limited(attachment_fmt.max_object_bytes + 1);
    return Io.Dir.cwd().readFileAlloc(gp.io, path, arena, limit) catch |e|
        switch (e) {
            error.FileNotFound, error.NotDir => null,
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => error.StoreFailed,
        };
}

pub fn lfsWrite(gp: *GitProcess, sha256: []const u8, data: []const u8) Error!void {
    return gp.writeStore(.issuez, sha256, data);
}

/// Temp file, fsync, rename, so a crash leaves nothing or the whole
/// object. Replaces an existing copy, which may be damaged.
fn writeStore(gp: *GitProcess, store: Store, sha256: []const u8, data: []const u8) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gp.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try lfsPath(arena, try gp.lfsObjectsDir(arena, store), sha256);
    const cwd = Io.Dir.cwd();
    const dir = std.fs.path.dirname(path).?;
    cwd.createDirPath(gp.io, dir) catch |e| return storeError(e);
    var suffix: [8]u8 = undefined;
    gp.io.random(&suffix);
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp-{x}", .{ path, suffix });
    {
        const file = cwd.createFile(gp.io, tmp, .{ .exclusive = true }) catch |e|
            return storeError(e);
        defer file.close(gp.io);
        file.writeStreamingAll(gp.io, data) catch |e| {
            cwd.deleteFile(gp.io, tmp) catch {};
            return storeError(e);
        };
        file.sync(gp.io) catch |e| {
            cwd.deleteFile(gp.io, tmp) catch {};
            return storeError(e);
        };
    }
    Io.Dir.rename(cwd, tmp, cwd, path, gp.io) catch |e| {
        cwd.deleteFile(gp.io, tmp) catch {};
        return storeError(e);
    };
}

/// Copies each object into git-lfs's store first, where `git lfs push`
/// looks. Only uploads what the server doesn't have yet.
pub fn lfsPush(
    gp: *GitProcess,
    arena: Allocator,
    remote: []const u8,
    shas: []const []const u8,
) (Error || contract.LfsTransportError)!void {
    assert(contract.isValidRemoteTarget(remote));
    try gp.requireGitLfs(arena);
    for (shas) |s| {
        assert(isSha256Hex(s));
        if (try gp.storeSize(arena, .git_lfs, s) != null) continue;
        const data = (try gp.readStore(arena, .issuez, s)) orelse return error.LfsTransferFailed;
        try gp.writeStore(.git_lfs, s, data);
    }
    var start: usize = 0;
    while (start < shas.len) : (start += 64) {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "git", "lfs", "push", "--object-id", remote });
        for (shas[start..@min(start + 64, shas.len)]) |s| {
            assert(isSha256Hex(s));
            try argv.append(arena, s);
        }
        const r = try gp.runWithin(arena, argv.items, null, gp.timeouts.transfer);
        if (!r.ok()) {
            gp.keepStderr(r.stderr);
            return error.LfsTransferFailed;
        }
    }
}

/// Downloads into git-lfs's store, where `lfsRead` finds them, in batches, the objects the trees of
/// these refs or commit OIDs point at. Objects that arrived stay when a
/// later batch, or an object in the same batch, fails.
pub fn lfsFetch(
    gp: *GitProcess,
    arena: Allocator,
    remote: []const u8,
    local_refs: []const []const u8,
) (Error || contract.LfsTransportError)!void {
    assert(contract.isValidRemoteTarget(remote));
    try gp.requireGitLfs(arena);
    // The first failing batch's output, which later batches would clear.
    var failure: ?[]const u8 = null;
    var start: usize = 0;
    while (start < local_refs.len) : (start += 32) {
        var argv: std.ArrayList([]const u8) = .empty;
        // Every object, whatever lfs.fetchinclude and lfs.fetchexclude say.
        try argv.appendSlice(arena, &.{ "git", "lfs", "fetch", "-I", "*", "-X", "", remote });
        for (local_refs[start..@min(start + 32, local_refs.len)]) |r| {
            const oid = if (Oid.parseHex(gp.format, r)) |_| true else |_| false;
            assert(oid or contract.isValidRefName(r));
            try argv.append(arena, r);
        }
        const r = try gp.runWithin(arena, argv.items, null, gp.timeouts.transfer);
        if (!r.ok() and failure == null) failure = r.stderr;
    }
    if (failure) |f| {
        gp.keepStderr(f);
        return error.LfsTransferFailed;
    }
}

pub fn lfsAvailable(gp: *GitProcess, arena: Allocator) Error!bool {
    if (gp.git_lfs) |known| return known;
    const r = gp.run(arena, &.{ "git", "lfs", "version" }, null) catch |e| switch (e) {
        error.GitSpawnFailed => {
            gp.git_lfs = false;
            return false;
        },
        else => |x| return x,
    };
    gp.git_lfs = r.ok();
    return gp.git_lfs.?;
}

fn requireGitLfs(gp: *GitProcess, arena: Allocator) (Error || contract.LfsTransportError)!void {
    if (!try gp.lfsAvailable(arena)) return error.LfsUnavailable;
}

fn storeError(e: anyerror) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.StoreFailed,
    };
}

/// Our store only.
pub fn lfsList(gp: *GitProcess, arena: Allocator) Error![]const []const u8 {
    const objects = try gp.lfsObjectsDir(arena, .issuez);
    var out: std.ArrayList([]const u8) = .empty;
    var root = Io.Dir.cwd().openDir(gp.io, objects, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return &.{},
        else => return storeError(e),
    };
    defer root.close(gp.io);
    var level1 = root.iterate();
    while (level1.next(gp.io) catch |e| return storeError(e)) |a| {
        if (a.kind != .directory or a.name.len != 2) continue;
        var da = root.openDir(gp.io, a.name, .{ .iterate = true }) catch continue;
        defer da.close(gp.io);
        var level2 = da.iterate();
        while (level2.next(gp.io) catch |e| return storeError(e)) |b| {
            if (b.kind != .directory or b.name.len != 2) continue;
            var db = da.openDir(gp.io, b.name, .{ .iterate = true }) catch continue;
            defer db.close(gp.io);
            var files = db.iterate();
            while (files.next(gp.io) catch |e| return storeError(e)) |f| {
                if (f.kind == .file and isSha256Hex(f.name)) try out.append(
                    arena,
                    try arena.dupe(u8, f.name),
                );
            }
        }
    }
    stableSort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out.items;
}

comptime {
    contract.assertBackend(GitProcess);
}

const RunResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn ok(r: RunResult) bool {
        return r.exitCode() == 0;
    }

    fn exitCode(r: RunResult) ?u8 {
        return switch (r.term) {
            .exited => |code| code,
            else => null,
        };
    }
};

/// `stdin` is written in full before reading output, so only use it with
/// commands that read all input first (hash-object, update-ref).
fn run(
    gp: *GitProcess,
    arena: Allocator,
    argv: []const []const u8,
    stdin: ?[]const u8,
) Error!RunResult {
    return gp.runWithin(arena, argv, stdin, gp.timeouts.command);
}

fn runWithin(
    gp: *GitProcess,
    arena: Allocator,
    argv: []const []const u8,
    stdin: ?[]const u8,
    limit: Io.Duration,
) Error!RunResult {
    const io = gp.io;
    const by = gp.deadline(limit);
    var child = try gp.spawn(argv, stdin != null);
    defer gp.stop(&child);

    if (stdin) |data| {
        var rest = data;
        while (rest.len > 0) {
            // A writable pipe takes this much without blocking, so the
            // deadline holds while git isn't reading.
            const done = try operateBy(io, gp.cancel, .{ .file_write_streaming = .{
                .file = child.stdin.?,
                .data = &.{rest[0..@min(rest.len, pipe_buf)]},
            } }, by);
            rest = rest[done.file_write_streaming catch return error.GitFailed ..];
        }
        child.stdin.?.close(io);
        child.stdin = null;
    }
    return gp.collect(arena, &child, by);
}

/// Two commands at once, for the cost of about one: git's startup is
/// most of a short command's time.
fn runPair(
    gp: *GitProcess,
    arena: Allocator,
    a: []const []const u8,
    b: []const []const u8,
) Error![2]RunResult {
    const by = gp.deadline(gp.timeouts.command);
    var first = try gp.spawn(a, false);
    defer gp.stop(&first);
    var second = try gp.spawn(b, false);
    defer gp.stop(&second);
    return .{ try gp.collect(arena, &first, by), try gp.collect(arena, &second, by) };
}

fn deadline(gp: *GitProcess, limit: Io.Duration) Io.Timeout {
    const t: Io.Timeout = .{ .duration = .{ .raw = limit, .clock = .awake } };
    return t.toDeadline(gp.io);
}

/// One operation that fails with `GitTimedOut` at `by`, or `Canceled`
/// soon after `cancel` reads true.
fn operateBy(
    io: Io,
    cancel: ?*const std.atomic.Value(bool),
    op: Io.Operation,
    by: Io.Timeout,
) Error!Io.Operation.Result {
    var storage: [1]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    batch.addAt(0, op);
    while (true) {
        batch.awaitConcurrent(io, waitSlice(io, cancel, by)) catch |err| {
            const failure: Error = switch (err) {
                error.Timeout => if (stillWaiting(io, cancel, by)) |why| why else continue,
                error.Canceled => error.Canceled,
                else => error.GitFailed,
            };
            batch.cancel(io);
            return failure;
        };
        return batch.next().?.result;
    }
}

/// The next wait: up to `by`, or up to `cancel_poll` while a cancel token
/// is set.
fn waitSlice(io: Io, cancel: ?*const std.atomic.Value(bool), by: Io.Timeout) Io.Timeout {
    if (cancel == null) return by;
    const soon: Io.Clock.Timestamp = .fromNow(io, .{ .raw = cancel_poll, .clock = .awake });
    return switch (by) {
        .deadline => |d| if (soon.durationTo(d).raw.nanoseconds < 0) by else .{ .deadline = soon },
        else => .{ .deadline = soon },
    };
}

/// After a wait slice ran out: why to stop, or null to wait on.
fn stillWaiting(io: Io, cancel: ?*const std.atomic.Value(bool), by: Io.Timeout) ?Error {
    if (cancel) |c| if (c.load(.acquire)) return error.Canceled;
    return switch (by) {
        .none => null,
        .deadline => |d| if (d.durationFromNow(io).raw.nanoseconds <= 0)
            error.GitTimedOut
        else
            null,
        .duration => error.GitTimedOut,
    };
}

fn spawn(gp: *GitProcess, argv: []const []const u8, stdin: bool) Error!std.process.Child {
    assert(argv.len > 0 and std.mem.eql(u8, argv[0], "git"));
    // `lastStderr` belongs to the latest command.
    gp.last_stderr_len = 0;
    // Commands are written with "git" first; run the configured one.
    const actual = try gp.gpa.dupe([]const u8, argv);
    defer gp.gpa.free(actual);
    actual[0] = gp.git_exe;
    if (builtin.os.tag != .windows and gp.no_terminal) return gp.spawnDetached(actual, stdin);
    return std.process.spawn(gp.io, .{
        .argv = actual,
        .cwd = .{ .path = gp.repo_path },
        .environ_map = &gp.env,
        .stdin = if (stdin) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = gp.no_terminal,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.GitSpawnFailed,
    };
}

/// Stops a command from `spawn` unless it is over. A detached one leads a
/// process group of its own, and what it started (ssh) stops with it.
fn stop(gp: *GitProcess, child: *std.process.Child) void {
    if (builtin.os.tag != .windows and gp.no_terminal) {
        if (child.id) |pid| _ = std.posix.system.kill(-pid, .TERM);
    }
    child.kill(gp.io);
}

/// `spawn` in a new session (`setsid`): std's spawn can't. Everything is
/// allocated before the fork, as the child may only make system calls:
/// another thread may hold the allocator's lock.
fn spawnDetached(gp: *GitProcess, argv: []const []const u8, stdin: bool) Error!std.process.Child {
    const sys = std.posix.system;
    const errno = std.posix.errno;
    var arena_state: std.heap.ArenaAllocator = .init(gp.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const argv_z = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, argv_z) |arg, *z| z.* = (try a.dupeZ(u8, arg)).ptr;
    const env = try gp.env.createPosixBlock(a, .{});
    const cwd = try a.dupeZ(u8, gp.repo_path);
    // Where `git` may be: the configured path itself, else in PATH order.
    var programs: std.ArrayList([*:0]const u8) = .empty;
    if (std.mem.indexOfScalar(u8, argv[0], '/') != null) {
        try programs.append(a, try a.dupeZ(u8, argv[0]));
    } else {
        const path = gp.env.get("PATH") orelse "/usr/bin:/bin";
        var dirs = std.mem.tokenizeScalar(u8, path, ':');
        while (dirs.next()) |dir| try programs.append(
            a,
            try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, argv[0] }, 0),
        );
    }

    const pipe = struct {
        fn make() Error![2]std.posix.fd_t {
            return Io.Threaded.pipe2(.{ .CLOEXEC = true }) catch error.GitSpawnFailed;
        }
        fn close(fds: [2]std.posix.fd_t) void {
            _ = sys.close(fds[0]);
            _ = sys.close(fds[1]);
        }
    };
    const null_in = Io.Dir.openFileAbsolute(
        gp.io,
        "/dev/null",
        .{},
    ) catch return error.GitSpawnFailed;
    defer null_in.close(gp.io);
    // Once forked, the fds are the child's or `child`'s to close.
    var forked_ok = false;
    const in: ?[2]std.posix.fd_t = if (stdin) try pipe.make() else null;
    errdefer if (!forked_ok) if (in) |p| pipe.close(p);
    const out = try pipe.make();
    errdefer if (!forked_ok) pipe.close(out);
    const err = try pipe.make();
    errdefer if (!forked_ok) pipe.close(err);
    // Written to by the child only when exec fails.
    const report = try pipe.make();
    defer _ = sys.close(report[0]);

    const forked = sys.fork();
    if (errno(forked) != .SUCCESS) {
        _ = sys.close(report[1]);
        return error.GitSpawnFailed;
    }
    if (forked == 0) {
        _ = sys.setsid();
        const stdin_fd = if (in) |p| p[0] else null_in.handle;
        if (errno(sys.dup2(stdin_fd, 0)) == .SUCCESS and errno(sys.dup2(out[1], 1)) == .SUCCESS and
            errno(sys.dup2(err[1], 2)) == .SUCCESS and errno(sys.chdir(cwd)) == .SUCCESS)
        {
            for (programs.items) |program| _ = sys.execve(program, argv_z.ptr, env.slice.ptr);
        }
        _ = sys.write(report[1], "x", 1);
        if (builtin.link_libc) std.c._exit(127) else std.os.linux.exit_group(127);
    }
    forked_ok = true;
    _ = sys.close(report[1]);
    if (in) |p| _ = sys.close(p[0]);
    _ = sys.close(out[1]);
    _ = sys.close(err[1]);
    var child: std.process.Child = .{
        .id = @intCast(forked),
        .thread_handle = {},
        .stdin = if (in) |p| .{ .handle = p[1], .flags = .{ .nonblocking = false } } else null,
        .stdout = .{ .handle = out[0], .flags = .{ .nonblocking = false } },
        .stderr = .{ .handle = err[0], .flags = .{ .nonblocking = false } },
        .request_resource_usage_statistics = false,
    };
    // EOF: exec worked, and closed the child's end.
    var byte: [1]u8 = undefined;
    while (true) {
        const n = sys.read(report[0], &byte, 1);
        switch (errno(n)) {
            .SUCCESS => if (n == 0) return child else break,
            .INTR => continue,
            else => break,
        }
    }
    // Reaps it, even when canceled, and closes our ends of the pipes.
    child.kill(gp.io);
    return error.GitSpawnFailed;
}

/// Reads a started command's output to the end and waits for it.
fn collect(
    gp: *GitProcess,
    arena: Allocator,
    child: *std.process.Child,
    by: Io.Timeout,
) Error!RunResult {
    const io = gp.io;
    var mr_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(arena, io, mr_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();

    while (true) {
        mr.fill(256, waitSlice(io, gp.cancel, by)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => if (stillWaiting(io, gp.cancel, by)) |why| return why else continue,
            error.Canceled => return error.Canceled,
            else => return error.GitFailed,
        };
        if (mr.reader(0).buffered().len > max_stdout_bytes) return error.OutputTooLong;
        if (mr.reader(1).buffered().len > max_stderr_bytes) return error.OutputTooLong;
    }
    mr.checkAnyError() catch return error.GitFailed;

    const term = child.wait(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.GitFailed,
    };
    return .{
        .term = term,
        .stdout = try mr.toOwnedSlice(0),
        .stderr = try mr.toOwnedSlice(1),
    };
}

/// Any non-zero exit is GitFailed. Returns stdout.
fn runOk(
    gp: *GitProcess,
    arena: Allocator,
    argv: []const []const u8,
    stdin: ?[]const u8,
) Error![]u8 {
    const result = try gp.run(arena, argv, stdin);
    if (!result.ok()) {
        gp.keepStderr(result.stderr);
        return error.GitFailed;
    }
    return result.stdout;
}

fn keepStderr(gp: *GitProcess, stderr: []const u8) void {
    const n: u16 = @intCast(@min(stderr.len, max_stderr_kept));
    @memcpy(gp.last_stderr[0..n], stderr[0..n]);
    gp.last_stderr_len = n;
}

fn catFile(gp: *GitProcess) Error!*CatFile {
    if (gp.cat_file) |cf| return cf;
    const cf = try CatFile.start(gp);
    gp.cat_file = cf;
    return cf;
}

/// One request at a time, each response read in full before the next.
/// Without `--buffer` git flushes after every object, so this can't
/// deadlock. cat-file reports problems in-band, stderr is dropped.
const CatFile = struct {
    child: std.process.Child,
    format: ObjectFormat,
    writer: Io.File.Writer,
    reader: PipeReader,
    write_buf: [256]u8,
    read_buf: [64 * 1024]u8,

    fn start(gp: *GitProcess) Error!*CatFile {
        const cf = try gp.gpa.create(CatFile);
        errdefer gp.gpa.destroy(cf);
        cf.child = std.process.spawn(gp.io, .{
            .argv = &.{ gp.git_exe, "cat-file", "--batch" },
            .cwd = .{ .path = gp.repo_path },
            .environ_map = &gp.env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.GitSpawnFailed,
        };
        cf.format = gp.format;
        cf.writer = cf.child.stdin.?.writerStreaming(gp.io, &cf.write_buf);
        cf.reader = .init(gp.io, cf.child.stdout.?, &cf.read_buf);
        return cf;
    }

    fn deinit(cf: *CatFile, io: Io, gpa: Allocator) void {
        cf.child.kill(io);
        gpa.destroy(cf);
    }

    fn read(cf: *CatFile, arena: Allocator, oid: Oid, by: Io.Timeout) Error!?contract.Object {
        cf.reader.by = by;
        const w = &cf.writer.interface;
        w.print("{f}\n", .{oid}) catch return error.GitFailed;
        w.flush() catch return error.GitFailed;

        const r = &cf.reader.interface;
        const line_raw = r.takeDelimiterInclusive('\n') catch return cf.reader.failure();
        const line = line_raw[0 .. line_raw.len - 1];

        // "<oid> missing" or "<oid> <type> <size>"
        var it = std.mem.splitScalar(u8, line, ' ');
        const oid_str = it.next() orelse return error.GitFailed;
        const second = it.next() orelse return error.GitFailed;
        if (std.mem.eql(u8, second, "missing")) return null;
        const got = Oid.parseHex(cf.format, oid_str) catch return error.GitFailed;
        if (!got.eql(oid)) return error.GitFailed;
        const kind = ObjectKind.parse(second) orelse return error.GitFailed;
        const size_str = it.next() orelse return error.GitFailed;
        if (it.next() != null) return error.GitFailed;
        const size = std.fmt.parseInt(usize, size_str, 10) catch return error.GitFailed;
        if (size > max_object_bytes) return error.OutputTooLong;

        const data = r.readAlloc(arena, size) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return cf.reader.failure(),
        };
        const nl = r.takeByte() catch return cf.reader.failure();
        if (nl != '\n') return error.GitFailed;
        return .{ .kind = kind, .data = data };
    }

    /// What `name` points at. `missing` when there is no such ref or its
    /// object is missing. The object comes along and is skipped.
    fn resolve(
        cf: *CatFile,
        name: []const u8,
        by: Io.Timeout,
    ) Error!union(enum) { oid: Oid, missing } {
        cf.reader.by = by;
        const w = &cf.writer.interface;
        w.print("{s}\n", .{name}) catch return error.GitFailed;
        w.flush() catch return error.GitFailed;

        const r = &cf.reader.interface;
        const line_raw = r.takeDelimiterInclusive('\n') catch return cf.reader.failure();
        const line = line_raw[0 .. line_raw.len - 1];

        // "<name> missing", or "<oid> <type> <size>" and the object.
        if (std.mem.endsWith(u8, line, " missing") and
            std.mem.eql(u8, line[0 .. line.len - " missing".len], name)) return .missing;
        var it = std.mem.splitScalar(u8, line, ' ');
        const oid = Oid.parseHex(cf.format, it.next() orelse return error.GitFailed) catch
            return error.GitFailed;
        _ = ObjectKind.parse(it.next() orelse return error.GitFailed) orelse
            return error.GitFailed;
        const size = std.fmt.parseInt(usize, it.next() orelse return error.GitFailed, 10) catch
            return error.GitFailed;
        if (it.next() != null) return error.GitFailed;
        r.discardAll(size + 1) catch return cf.reader.failure();
        return .{ .oid = oid };
    }
};

/// `git hash-object -w -t <kind> --no-filters --stdin-paths`: a path per
/// line in, an OID per line out, flushed after each. `--no-filters`, since
/// the data is the object, as with `--stdin`: no attributes or eol
/// conversion apply. stderr is dropped; the one-off fallback in
/// `writeObject` reports errors.
const HashObject = struct {
    child: std.process.Child,
    format: ObjectFormat,
    writer: Io.File.Writer,
    reader: PipeReader,
    write_buf: [512]u8,
    read_buf: [256]u8,

    fn start(gp: *GitProcess, kind: ObjectKind) Error!*HashObject {
        const ho = try gp.gpa.create(HashObject);
        errdefer gp.gpa.destroy(ho);
        ho.child = std.process.spawn(gp.io, .{
            .argv = &.{
                gp.git_exe,      "hash-object",
                "-w",            "-t",
                @tagName(kind),  "--no-filters",
                "--stdin-paths",
            },
            .cwd = .{ .path = gp.repo_path },
            .environ_map = &gp.env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.GitSpawnFailed,
        };
        ho.format = gp.format;
        ho.writer = ho.child.stdin.?.writerStreaming(gp.io, &ho.write_buf);
        ho.reader = .init(gp.io, ho.child.stdout.?, &ho.read_buf);
        return ho;
    }

    fn deinit(ho: *HashObject, io: Io, gpa: Allocator) void {
        ho.child.kill(io);
        gpa.destroy(ho);
    }

    fn hash(ho: *HashObject, path: []const u8, by: Io.Timeout) Error!Oid {
        assert(std.mem.findScalar(u8, path, '\n') == null and path[0] != '"');
        ho.reader.by = by;
        const w = &ho.writer.interface;
        w.print("{s}\n", .{path}) catch return error.GitFailed;
        w.flush() catch return error.GitFailed;
        const r = &ho.reader.interface;
        const line = r.takeDelimiterInclusive('\n') catch return ho.reader.failure();
        return Oid.parseHex(ho.format, line[0 .. line.len - 1]) catch error.GitFailed;
    }
};

/// A session's stdout. Each read waits until `by` at most, so a git that
/// stops answering fails the request instead of hanging the caller. The
/// requests are single lines that git reads right away, so the writes
/// can't block.
const PipeReader = struct {
    io: Io,
    file: Io.File,
    by: Io.Timeout = .none,
    cancel: ?*const std.atomic.Value(bool) = null,
    err: ?Error = null,
    interface: Io.Reader,

    fn init(io: Io, file: Io.File, buffer: []u8) PipeReader {
        return .{
            .io = io,
            .file = file,
            .interface = .{
                .vtable = &.{ .stream = stream, .readVec = readVec },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    /// Why the last read failed.
    fn failure(p: *const PipeReader) Error {
        return p.err orelse error.GitFailed;
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        var data: [1][]u8 = .{limit.slice(try w.writableSliceGreedy(1))};
        const n = try readVec(r, &data);
        w.advance(n);
        return n;
    }

    fn readVec(r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const p: *PipeReader = @alignCast(@fieldParentPtr("interface", r));
        var vecs: [8][]u8 = undefined;
        const dest_n, const data_size = try r.writableVector(&vecs, data);
        const done = operateBy(p.io, p.cancel, .{ .file_read_streaming = .{
            .file = p.file,
            .data = vecs[0..dest_n],
        } }, p.by) catch |err| {
            p.err = err;
            return error.ReadFailed;
        };
        const n = done.file_read_streaming catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => return error.ReadFailed,
        };
        if (n > data_size) {
            r.end += n - data_size;
            return data_size;
        }
        return n;
    }
};

fn zeroOid(format: ObjectFormat) Oid {
    return .{ .object_format = format, .bytes = @splat(0) };
}

fn oidLessThan(_: void, a: Oid, b: Oid) bool {
    return a.order(b) == .lt;
}

/// Internal: the library's own plumbing, not API; it may change.
/// "git version 2.54.0 (Apple Git-157)", "git version 2.45.1.windows.1"
pub fn parseGitVersion(out: []const u8) ?std.SemanticVersion {
    const prefix = "git version ";
    const line = std.mem.trimEnd(u8, out, "\r\n");
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var it = std.mem.splitScalar(u8, line[prefix.len..], '.');
    var parts: [3]usize = .{ 0, 0, 0 };
    for (&parts) |*p| {
        const raw = it.next() orelse return null;
        const end = std.mem.findNone(u8, raw, "0123456789") orelse raw.len;
        if (end == 0) return null;
        p.* = std.fmt.parseInt(usize, raw[0..end], 10) catch return null;
    }
    return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
}

test parseGitVersion {
    const t = std.testing;
    const v = parseGitVersion("git version 2.54.0 (Apple Git-157)\n").?;
    try t.expectEqual(@as(usize, 54), v.minor);
    const w = parseGitVersion("git version 2.45.1.windows.1").?;
    try t.expectEqual(@as(usize, 1), w.patch);
    try t.expect(parseGitVersion("hub version 2") == null);
}

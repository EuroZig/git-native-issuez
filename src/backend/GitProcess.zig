//! Backend that runs the `git` binary found in PATH.
//!
//! Children get `LC_ALL=C` and `GIT_TERMINAL_PROMPT=0` and run in the
//! repository, and their output is bounded. Reads go through one long-lived
//! `git cat-file --batch`, ref changes through `git update-ref --stdin`.

const GitProcess = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const contract = @import("contract.zig");
const object = @import("object.zig");
const Oid = object.Oid;
const ObjectFormat = object.ObjectFormat;
const ObjectKind = object.ObjectKind;
const Signature = object.Signature;

io: Io,
gpa: Allocator,
env: std.process.Environ.Map,
repo_path: []u8,
format: ObjectFormat,
cat_file: ?*CatFile,
/// stderr of the last failed command, for error messages.
last_stderr: [max_stderr_kept]u8,
last_stderr_len: u16,

pub const Error = error{
    OutOfMemory,
    /// Not in PATH or not executable.
    GitSpawnFailed,
    /// Failed, or printed something we couldn't parse.
    GitFailed,
    GitTooOld,
    NotARepository,
    OutputTooLong,
    Canceled,
};

/// The oldest git whose trailer parsing matches current git, and that has
/// every plumbing feature we use. CI runs it on Debian 11.
pub const min_git_version: std.SemanticVersion = .{ .major = 2, .minor = 30, .patch = 0 };

const max_stdout_bytes = 64 * 1024 * 1024;
const max_stderr_bytes = 64 * 1024;
const max_stderr_kept = 1024;
const max_object_bytes = 64 * 1024 * 1024;

pub const OpenOptions = struct {
    /// Any directory inside the repository, or the git dir of a bare one.
    path: []const u8,
    environ_map: *const std.process.Environ.Map,
};

pub fn open(io: Io, gpa: Allocator, options: OpenOptions) Error!GitProcess {
    var env = try options.environ_map.clone(gpa);
    errdefer env.deinit();
    try env.put("LC_ALL", "C");
    try env.put("GIT_TERMINAL_PROMPT", "0");

    const repo_path = try gpa.dupe(u8, options.path);
    errdefer gpa.free(repo_path);

    var gp: GitProcess = .{
        .io = io,
        .gpa = gpa,
        .env = env,
        .repo_path = repo_path,
        .format = .sha1,
        .cat_file = null,
        .last_stderr = undefined,
        .last_stderr_len = 0,
    };

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const version_out = try gp.runOk(arena, &.{ "git", "version" }, null);
    const version = parseGitVersion(version_out) orelse return error.GitFailed;
    if (version.order(min_git_version) == .lt) return error.GitTooOld;

    const fmt = gp.run(arena, &.{ "git", "rev-parse", "--show-object-format" }, null) catch |err|
        return err;
    if (!fmt.ok()) return error.NotARepository;
    gp.format = ObjectFormat.parse(std.mem.trimEnd(u8, fmt.stdout, "\n")) orelse
        return error.GitFailed;
    return gp;
}

pub fn close(gp: *GitProcess) void {
    if (gp.cat_file) |cf| cf.deinit(gp.io, gp.gpa);
    gp.env.deinit();
    gp.gpa.free(gp.repo_path);
    gp.* = undefined;
}

pub fn lastStderr(gp: *const GitProcess) []const u8 {
    return gp.last_stderr[0..gp.last_stderr_len];
}

pub fn objectFormat(gp: *const GitProcess) ObjectFormat {
    return gp.format;
}

pub fn readObject(gp: *GitProcess, arena: Allocator, oid: Oid) Error!?contract.Object {
    assert(oid.object_format == gp.format);
    const cf = try gp.catFile();
    return cf.read(arena, oid) catch |err| {
        // A broken session can't be reused. The next read starts a new one.
        cf.deinit(gp.io, gp.gpa);
        gp.cat_file = null;
        return err;
    };
}

pub fn writeObject(gp: *GitProcess, kind: ObjectKind, data: []const u8) Error!Oid {
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

pub fn resolveRef(gp: *GitProcess, name: []const u8) Error!?Oid {
    assert(contract.isValidRefName(name));
    var arena_state: std.heap.ArenaAllocator = .init(gp.gpa);
    defer arena_state.deinit();
    const result = try gp.run(
        arena_state.allocator(),
        &.{ "git", "rev-parse", "--verify", "--quiet", "--end-of-options", name },
        null,
    );
    if (!result.ok()) {
        if (result.exitCode() == 1) return null;
        gp.keepStderr(result.stderr);
        return error.GitFailed;
    }
    return Oid.parseHex(gp.format, std.mem.trimEnd(u8, result.stdout, "\n")) catch error.GitFailed;
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

    const result = try gp.run(arena, &.{ "git", "update-ref", "--stdin" }, aw.written());
    if (result.ok()) return;

    // Tell a lost CAS race from other failures by re-reading the expected
    // values.
    for (updates) |u| {
        const expected: ?Oid = switch (u.op) {
            .create => null,
            .update => |x| x.old,
            .delete => |old| old,
            .verify => |old| old,
        };
        const actual = try gp.resolveRef(u.name);
        const same = if (expected) |e| (actual != null and actual.?.eql(e)) else actual == null;
        if (!same) return error.RefConflict;
    }
    gp.keepStderr(result.stderr);
    return error.GitFailed;
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
    std.mem.sort(Oid, bases.items, {}, oidLessThan);
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

pub fn remoteNames(gp: *GitProcess, arena: Allocator) Error![]const []const u8 {
    return splitLines(arena, try gp.runOk(arena, &.{ "git", "remote" }, null));
}

/// Only the given refspecs write refs: `--refmap=` stops git from also
/// updating refs through `remote.<name>.fetch`, which with upstream's
/// `+refs/issues/*:refs/issues/*` would reset unpushed local issues. Tags
/// and FETCH_HEAD are left alone.
pub fn fetch(
    gp: *GitProcess,
    arena: Allocator,
    remote: []const u8,
    refspecs: []const []const u8,
) (Error || error{FetchFailed})!void {
    assert(contract.isValidRemoteName(remote));
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(
        arena,
        &.{
            "git",     "fetch", "--no-tags", "--no-write-fetch-head", "--refmap=",
            "--quiet", "--",    remote,
        },
    );
    try argv.appendSlice(arena, refspecs);
    const result = try gp.run(arena, argv.items, null);
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
    atomic: bool,
) (Error || error{PushFailed})!contract.PushResult {
    assert(contract.isValidRemoteName(remote));
    assert(refspecs.len > 0);
    var argv: std.ArrayList([]const u8) = .empty;
    // Hooks run like for any push, so the user's pre-push policies apply.
    try argv.appendSlice(arena, &.{ "git", "push", "--porcelain" });
    if (atomic) try argv.append(arena, "--atomic");
    try argv.appendSlice(arena, &.{ "--", remote });
    try argv.appendSlice(arena, refspecs);
    const result = try gp.run(arena, argv.items, null);
    if (atomic and !result.ok() and std.mem.find(
        u8,
        result.stderr,
        "does not support --atomic",
    ) != null) {
        return gp.push(arena, remote, refspecs, false);
    }
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
            ' ', '*', '+' => .ok,
            '=' => .up_to_date,
            else => .rejected,
        };
        // "[rejected]" comes from git itself: the remote moved. "[remote
        // rejected]" is the server refusing (a hook, permissions), which
        // no retry fixes, unless it only failed with another ref.
        const summary = fields.next() orelse "";
        if (std.mem.startsWith(u8, summary, "[remote rejected]") and
            std.mem.find(u8, summary, "atomic push fail") == null) refused = true;
        try refs.append(arena, .{ .name = spec[colon + 1 ..], .status = status });
    }
    if (refused or (!result.ok() and refs.items.len == 0)) {
        gp.keepStderr(result.stderr);
        return error.PushFailed;
    }
    return .{ .refs = refs.items };
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
    return .{
        .author = try gp.ident(arena, "GIT_AUTHOR_IDENT"),
        .committer = try gp.ident(arena, "GIT_COMMITTER_IDENT"),
    };
}

fn ident(
    gp: *GitProcess,
    arena: Allocator,
    variable: []const u8,
) (Error || error{IdentityUnknown})!Signature {
    // Like upstream, insist on a configured identity. Without useConfigOnly
    // git makes one up from the login and hostname, and that would end up
    // in the issue history.
    const result = try gp.run(
        arena,
        &.{ "git", "-c", "user.useConfigOnly=true", "var", variable },
        null,
    );
    if (!result.ok()) {
        gp.keepStderr(result.stderr);
        return error.IdentityUnknown;
    }
    return Signature.parse(std.mem.trimEnd(u8, result.stdout, "\n")) catch error.GitFailed;
}

pub fn randomBytes(gp: *GitProcess, buf: []u8) void {
    gp.io.random(buf);
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
    assert(argv.len > 0 and std.mem.eql(u8, argv[0], "git"));
    const io = gp.io;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = gp.repo_path },
        .environ_map = &gp.env,
        .stdin = if (stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.GitSpawnFailed,
    };
    defer child.kill(io);

    if (stdin) |data| {
        var stdin_writer = child.stdin.?.writerStreaming(io, &.{});
        stdin_writer.interface.writeAll(data) catch return error.GitFailed;
        child.stdin.?.close(io);
        child.stdin = null;
    }

    var mr_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(arena, io, mr_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();

    while (mr.fill(256, .none)) |_| {
        if (mr.reader(0).buffered().len > max_stdout_bytes) return error.OutputTooLong;
        if (mr.reader(1).buffered().len > max_stderr_bytes) return error.OutputTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Canceled => return error.Canceled,
        else => return error.GitFailed,
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
    reader: Io.File.Reader,
    write_buf: [256]u8,
    read_buf: [64 * 1024]u8,

    fn start(gp: *GitProcess) Error!*CatFile {
        const cf = try gp.gpa.create(CatFile);
        errdefer gp.gpa.destroy(cf);
        cf.child = std.process.spawn(gp.io, .{
            .argv = &.{ "git", "cat-file", "--batch" },
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
        cf.reader = cf.child.stdout.?.readerStreaming(gp.io, &cf.read_buf);
        return cf;
    }

    fn deinit(cf: *CatFile, io: Io, gpa: Allocator) void {
        cf.child.kill(io);
        gpa.destroy(cf);
    }

    fn read(cf: *CatFile, arena: Allocator, oid: Oid) Error!?contract.Object {
        const w = &cf.writer.interface;
        w.print("{f}\n", .{oid}) catch return error.GitFailed;
        w.flush() catch return error.GitFailed;

        const r = &cf.reader.interface;
        const line_raw = r.takeDelimiterInclusive('\n') catch return error.GitFailed;
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
            else => return error.GitFailed,
        };
        const nl = r.takeByte() catch return error.GitFailed;
        if (nl != '\n') return error.GitFailed;
        return .{ .kind = kind, .data = data };
    }
};

fn zeroOid(format: ObjectFormat) Oid {
    return .{ .object_format = format, .bytes = @splat(0) };
}

fn oidLessThan(_: void, a: Oid, b: Oid) bool {
    return a.order(b) == .lt;
}

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

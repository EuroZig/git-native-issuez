//! What every part of the C library shares: the process-wide runtime
//! (allocator, `Io`, logger), errors and problems, cancel tokens, and the
//! helpers that turn handles and strings into C values and back.

const std = @import("std");
const api = @import("api.zig");
const issuez = @import("issuez");

const Allocator = std.mem.Allocator;
const Code = api.Code;
const Str = api.Str;

/// Thread-safe, and what a C host expects memory to come from. Debug
/// builds (`-Dcapi-debug`) count what is live, for the tests' leak check.
pub const gpa: Allocator = if (capi_options.debug) counting.allocator() else std.heap.c_allocator;

const capi_options = @import("capi_options");

var counting: Counting = .{};

/// `c_allocator` that counts live allocations.
const Counting = struct {
    live: std.atomic.Value(i64) = .init(0),
    /// Allocations that succeed before one fails; negative: none fails.
    fail_in: std.atomic.Value(i64) = .init(-1),

    fn allocator(c: *Counting) Allocator {
        return .{ .ptr = c, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn of(ctx: *anyopaque) *Counting {
        return @ptrCast(@alignCast(ctx));
    }

    fn alloc(ctx: *anyopaque, n: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c = of(ctx);
        if (c.fail_in.load(.monotonic) >= 0 and c.fail_in.fetchSub(1, .monotonic) == 0)
            return null;
        const p = std.heap.c_allocator.rawAlloc(n, a, ra) orelse return null;
        _ = of(ctx).live.fetchAdd(1, .monotonic);
        return p;
    }

    fn resize(_: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        return std.heap.c_allocator.rawResize(m, a, n, ra);
    }

    fn remap(_: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        return std.heap.c_allocator.rawRemap(m, a, n, ra);
    }

    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        std.heap.c_allocator.rawFree(m, a, ra);
        _ = of(ctx).live.fetchSub(1, .monotonic);
    }
};

/// Live allocations, in `-Dcapi-debug` builds.
pub fn liveAllocations() i64 {
    return counting.live.load(.monotonic);
}

/// In `-Dcapi-debug` builds, the allocation after the next `n` fails
/// (once); negative: none does.
pub fn failAllocation(n: i64) void {
    counting.fail_in.store(n, .monotonic);
}

var threaded: std.Io.Threaded = undefined;
/// 0 not yet, 1 starting, 2 ready.
var init_state: std.atomic.Value(u8) = .init(0);

pub fn io() std.Io {
    ensure();
    return threaded.io();
}

/// The process environment now: a host may change it between opens, and
/// doing so can move and free what an earlier read saw.
pub fn processEnviron() std.process.Environ {
    return .{ .block = .{ .slice = std.mem.sliceTo(std.c.environ, null) } };
}

/// Initialises on first use: issuez_init is only needed to check the
/// header's version against the library's.
pub fn ensure() void {
    if (init_state.load(.acquire) != 2) startOnce();
}

// ─── Version and init ──────────────────────────────────────────────────

const version_z = std.fmt.comptimePrint("{s}", .{issuez.version});

pub fn issuez_version() callconv(.c) [*:0]const u8 {
    return version_z;
}

/// The header's ABI version works with this library: the same major, and
/// a minor no newer than ours (before 1.0, the same minor).
pub fn compatible(header: u32) bool {
    const major = header >> 16;
    const minor = header & 0xffff;
    if (major != api.version.major) return false;
    if (api.version.major == 0) return minor == api.version.minor;
    return minor <= api.version.minor;
}

pub fn issuez_init(abi_version: u32, err: ?*?*api.Error) callconv(.c) Code {
    if (!compatible(abi_version)) return fail(err, .e_abi, "issuez.h is version {d}.{d}, the " ++
        "library {d}.{d}", .{
        abi_version >> 16,
        abi_version & 0xffff,
        api.version.major,
        api.version.minor,
    });
    startOnce();
    return .ok;
}

/// Once, from whichever thread gets here first.
fn startOnce() void {
    while (true) {
        switch (init_state.cmpxchgStrong(0, 1, .acquire, .acquire) orelse 0) {
            0 => break,
            1 => std.atomic.spinLoopHint(),
            else => return,
        }
    }
    // Its thread pool's memory isn't the API's: not counted.
    threaded = .init(std.heap.c_allocator, .{ .environ = environSnapshot() });
    restoreSignals();
    init_state.store(2, .release);
}

/// A copy for `Threaded`, which reads its environment later, once, to find
/// programs on PATH: the host may have moved the original by then. Lives as
/// long as the process. Without memory, Threaded falls back to its default
/// PATH.
fn environSnapshot() std.process.Environ {
    const a = std.heap.c_allocator;
    const from = std.mem.sliceTo(std.c.environ, null);
    const entries = a.allocSentinel(?[*:0]const u8, from.len, null) catch return .empty;
    for (from, entries) |entry, *to| {
        const copy = a.dupeZ(u8, std.mem.span(entry.?)) catch return .empty;
        to.* = copy.ptr;
    }
    return .{ .block = .{ .slice = entries } };
}

/// `Io.Threaded.init` installs handlers for SIGIO and SIGPIPE, for
/// interrupting its own blocking calls. In a host process they would
/// replace the host's, which the Go runtime, for one, treats as fatal.
/// Cancellation here checks a token between git requests instead, so put
/// the host's handlers back.
fn restoreSignals() void {
    const posix = std.posix;
    if (posix.Sigaction == void or !threaded.have_signal_handler) return;
    if (@TypeOf(threaded.old_sig_io) != void) posix.sigaction(.IO, &threaded.old_sig_io, null);
    if (@TypeOf(threaded.old_sig_pipe) != void) posix.sigaction(
        .PIPE,
        &threaded.old_sig_pipe,
        null,
    );
    threaded.have_signal_handler = false;
}

pub fn issuez_code_name(code: Code) callconv(.c) [*:0]const u8 {
    return switch (code) {
        .ok => "OK",
        _ => "UNKNOWN",
        inline else => |tag| comptime upperZ(@tagName(tag)[2..]),
    };
}

pub fn issuez_field_key(field: api.Field) callconv(.c) [*:0]const u8 {
    return switch (field) {
        _ => "",
        inline else => |tag| comptime (api.Field.key(tag) ++ "").ptr,
    };
}

fn upperZ(comptime s: []const u8) [*:0]const u8 {
    comptime {
        var buf: [s.len:0]u8 = undefined;
        for (s, buf[0..s.len]) |c, *o| o.* = std.ascii.toUpper(c);
        buf[s.len] = 0;
        const out = buf;
        return &out;
    }
}

// ─── Strings and handles ───────────────────────────────────────────────

/// A copy with a NUL after it, as every returned string has.
pub fn dupeZ(arena: Allocator, s: []const u8) Allocator.Error!Str {
    const z = try arena.dupeZ(u8, s);
    return .{ .ptr = z.ptr, .len = s.len };
}

/// {NULL,0} for null.
pub fn optZ(arena: Allocator, s: ?[]const u8) Allocator.Error!Str {
    return if (s) |v| dupeZ(arena, v) else .{};
}

/// Copies of `list`, each with a NUL after it.
pub fn strs(arena: Allocator, list: []const []const u8) Allocator.Error![]const Str {
    const out = try arena.alloc(Str, list.len);
    for (list, out) |s, *o| o.* = try dupeZ(arena, s);
    return out;
}

/// A C array: `n` items at `p`, none at NULL.
pub fn sliceOf(comptime T: type, p: ?[*]const T, n: usize) []const T {
    return if (p) |x| x[0..n] else &.{};
}

/// A handle's object from its opaque pointer.
pub fn obj(comptime T: type, p: anytype) ?*T {
    const raw = p orelse return null;
    return @ptrCast(@alignCast(@constCast(raw)));
}

/// The accessors that do nothing but read a handle's object, `Obj`: its
/// C functions, by the name of the field. A NULL handle or an index out of
/// range reads as zero.
pub fn Reads(comptime H: type, comptime Obj: type) type {
    return struct {
        fn Field(comptime name: []const u8) type {
            return @FieldType(Obj, name);
        }

        fn Elem(comptime name: []const u8) type {
            return @typeInfo(Field(name)).pointer.child;
        }

        fn Public(comptime name: []const u8) type {
            return @FieldType(Elem(name), "public");
        }

        pub fn field(comptime name: []const u8) fn (?*const H) callconv(.c) Field(name) {
            return struct {
                fn read(h: ?*const H) callconv(.c) Field(name) {
                    const o = obj(Obj, h) orelse return std.mem.zeroes(Field(name));
                    return @field(o, name);
                }
            }.read;
        }

        pub fn ref(comptime name: []const u8) fn (?*const H) callconv(.c) ?*const Field(name) {
            return struct {
                fn read(h: ?*const H) callconv(.c) ?*const Field(name) {
                    const o = obj(Obj, h) orelse return null;
                    return &@field(o, name);
                }
            }.read;
        }

        pub fn count(comptime name: []const u8) fn (?*const H) callconv(.c) usize {
            return struct {
                fn read(h: ?*const H) callconv(.c) usize {
                    const o = obj(Obj, h) orelse return 0;
                    return @field(o, name).len;
                }
            }.read;
        }

        pub fn at(comptime name: []const u8) fn (?*const H, usize) callconv(.c) Elem(name) {
            return struct {
                fn read(h: ?*const H, i: usize) callconv(.c) Elem(name) {
                    const o = obj(Obj, h) orelse return std.mem.zeroes(Elem(name));
                    const list = @field(o, name);
                    return if (i < list.len) list[i] else std.mem.zeroes(Elem(name));
                }
            }.read;
        }

        pub fn refAt(
            comptime name: []const u8,
        ) fn (?*const H, usize) callconv(.c) ?*const Elem(name) {
            return struct {
                fn read(h: ?*const H, i: usize) callconv(.c) ?*const Elem(name) {
                    const o = obj(Obj, h) orelse return null;
                    const list = @field(o, name);
                    return if (i < list.len) &list[i] else null;
                }
            }.read;
        }

        /// `refAt` of a list whose items keep their public part in `public`.
        pub fn publicAt(
            comptime name: []const u8,
        ) fn (?*const H, usize) callconv(.c) ?*const Public(name) {
            return struct {
                fn read(h: ?*const H, i: usize) callconv(.c) ?*const Public(name) {
                    const o = obj(Obj, h) orelse return null;
                    const list = @field(o, name);
                    return if (i < list.len) &list[i].public else null;
                }
            }.read;
        }

        /// For handles that are nothing but their arena.
        pub fn free() fn (?*H) callconv(.c) void {
            return struct {
                fn f(h: ?*H) callconv(.c) void {
                    const o = obj(Obj, h) orelse return;
                    freeArena(o.arena);
                }
            }.f;
        }
    };
}

/// The tag of `To` named as `from` is, for an enum that mirrors another: a
/// tag missing from `To` doesn't compile.
pub fn mirrored(comptime To: type, from: anytype) To {
    return switch (from) {
        inline else => |tag| @field(To, @tagName(tag)),
    };
}

pub fn handle(comptime H: type, p: anytype) *H {
    return @ptrCast(p);
}

pub fn oidOf(oid: issuez.backend.object.Oid) api.Oid {
    var out: api.Oid = .{ .len = oid.object_format.byteLen() };
    @memcpy(out.bytes[0..out.len], oid.bytes[0..out.len]);
    return out;
}

pub fn oidFrom(oid: api.Oid) ?issuez.backend.object.Oid {
    const format: issuez.backend.object.ObjectFormat = switch (oid.len) {
        20 => .sha1,
        32 => .sha256,
        else => return null,
    };
    var out: issuez.backend.object.Oid = .{ .object_format = format, .bytes = @splat(0) };
    @memcpy(out.bytes[0..oid.len], oid.bytes[0..oid.len]);
    return out;
}

pub fn timeOf(sig: issuez.backend.object.Signature) api.Time {
    return .{ .unix_seconds = sig.time, .tz_offset_minutes = sig.tz_offset_minutes };
}

/// The commits' author for a call's actor, or why it can't be one: git's
/// signature has no room for `<`, `>`, a newline or a NUL, nor for a time
/// zone a day or more off UTC.
pub fn actorSignature(act: api.Actor) union(enum) {
    sig: issuez.backend.object.Signature,
    bad: []const u8,
} {
    if (hasReserved(act)) return .{ .bad = "reserved fields must be zero" };
    if (act.email.len == 0) return .{ .bad = "the actor needs an email" };
    if (act.user_id.len > 0 and !issuez.format.uuid.isCanonical(act.user_id.slice()))
        return .{ .bad = "the actor's user_id must be a UUID" };
    const time = if (act.at) |t| t.* else api.Time{
        .unix_seconds = std.Io.Timestamp.now(io(), .real).toSeconds(),
    };
    const sig: issuez.backend.object.Signature = .{
        .name = if (act.name.len > 0) act.name.slice() else act.email.slice(),
        .email = act.email.slice(),
        .time = time.unix_seconds,
        .tz_offset_minutes = time.tz_offset_minutes,
    };
    if (!sig.isValid()) return .{
        .bad = "the actor's name and email can't hold <, >, a newline or a NUL, " ++
            "and its time zone is less than a day off UTC",
    };
    return .{ .sig = sig };
}

/// A commit's author: its signature, and its `X-Author-Id` when it has
/// one.
pub fn personOf(
    arena: Allocator,
    sig: issuez.backend.object.Signature,
    id: ?[]const u8,
) Allocator.Error!api.Person {
    return .{
        .name = try dupeZ(arena, sig.name),
        .email = try dupeZ(arena, sig.email),
        .user_id = if (id) |x| try dupeZ(arena, x) else .{},
    };
}

/// `personOf`, in a record of its own.
pub fn newPerson(
    arena: Allocator,
    sig: issuez.backend.object.Signature,
    id: ?[]const u8,
) Allocator.Error!*const api.Person {
    const person = try arena.create(api.Person);
    person.* = try personOf(arena, sig, id);
    return person;
}

pub fn dateOf(d: issuez.format.fields.Date) api.Date {
    return .{ .year = @intCast(d.year), .month = d.month, .day = d.day };
}

pub fn oidEql(a: *const api.Oid, b: *const api.Oid) bool {
    return a.len == b.len and std.mem.eql(u8, a.bytes[0..a.len], b.bytes[0..b.len]);
}

// ─── Problems ──────────────────────────────────────────────────────────

/// A problem list. Owned ones carry their arena; borrowed ones live in
/// their parent's.
pub const ProblemList = struct {
    arena: ?*std.heap.ArenaAllocator = null,
    items: []const api.Problem = &.{},
};

pub const ProblemSpec = struct {
    kind: api.ProblemKind,
    field: api.Field = .unknown,
    key: []const u8 = "",
    value: []const u8 = "",
    subject: []const u8 = "",
    message: []const u8,
    op_index: i64 = -1,
};

pub const Problems = std.ArrayList(ProblemSpec);

/// The problems of one op of a list being checked.
pub const OpCheck = struct {
    a: Allocator,
    problems: *Problems,
    index: i64,
    field: api.Field = .unknown,

    pub fn at(a: Allocator, problems: *Problems, index: usize) OpCheck {
        return .{ .a = a, .problems = problems, .index = @intCast(index) };
    }

    /// The same list's problems about `field` of the op at `index`; -1: no one op's.
    pub fn on(c: OpCheck, field: api.Field, index: i64) OpCheck {
        return .{ .a = c.a, .problems = c.problems, .index = index, .field = field };
    }

    pub fn add(c: OpCheck, kind: api.ProblemKind, message: []const u8) !void {
        try c.addValue(kind, "", message);
    }

    pub fn addValue(
        c: OpCheck,
        kind: api.ProblemKind,
        value: []const u8,
        message: []const u8,
    ) !void {
        try c.problems.append(c.a, .{
            .kind = kind,
            .field = c.field,
            .value = value,
            .message = message,
            .op_index = c.index,
        });
    }

    /// Input types carry reserved space, which must be zero: a later minor
    /// version may give it a meaning. True when the op's isn't.
    pub fn reserved(c: OpCheck, op: api.Op) !bool {
        if (!hasReserved(op)) return false;
        try c.add(.bad_format, "reserved fields must be zero");
        return true;
    }
};

pub fn problem(arena: Allocator, p: ProblemSpec) Allocator.Error!api.Problem {
    return .{
        .kind = @intFromEnum(p.kind),
        .field = @intFromEnum(p.field),
        .key = try dupeZ(arena, if (p.key.len > 0) p.key else p.field.key()),
        .value = try dupeZ(arena, p.value),
        .subject = try dupeZ(arena, p.subject),
        .message = try dupeZ(arena, p.message),
        .op_index = p.op_index,
    };
}

/// A new owned list, for `issuez_problems **out`.
pub fn ownedProblems(items: []const ProblemSpec) Allocator.Error!*ProblemList {
    return owned(ProblemList, problemList, .{items});
}

pub fn borrowedProblems(arena: Allocator, items: []const ProblemSpec) Allocator.Error!*ProblemList {
    const list = try arena.create(ProblemList);
    list.* = try problemList(arena, items);
    return list;
}

fn problemList(arena: Allocator, items: []const ProblemSpec) Allocator.Error!ProblemList {
    const out = try arena.alloc(api.Problem, items.len);
    for (items, out) |p, *o| o.* = try problem(arena, p);
    return .{ .items = out };
}

const ProblemListReads = Reads(api.Problems, ProblemList);
pub const issuez_problems_len = ProblemListReads.count("items");

pub fn issuez_problems_at(p: ?*const api.Problems, i: usize) callconv(.c) ?*const api.Problem {
    const list = obj(ProblemList, p) orelse return null;
    if (i >= list.items.len) return null;
    return &list.items[i];
}

pub fn issuez_problems_free(p: ?*api.Problems) callconv(.c) void {
    const list = obj(ProblemList, p) orelse return;
    if (list.arena) |a| freeArena(a);
}

// ─── Errors ────────────────────────────────────────────────────────────

pub const ErrorObj = struct {
    arena: *std.heap.ArenaAllocator,
    code: Code,
    message: Str,
    subject: Str = .{},
    git_stderr: Str = .{},
    current_tip: ?api.Oid = null,
    problems: ?*ProblemList = null,
    write: ?*anyopaque = null,
    free_write: ?*const fn (*anyopaque) void = null,
};

pub const Detail = struct {
    subject: []const u8 = "",
    git_stderr: []const u8 = "",
    current_tip: ?api.Oid = null,
    problems: []const ProblemSpec = &.{},
    /// A write receipt that the error takes over.
    write: ?*anyopaque = null,
    free_write: ?*const fn (*anyopaque) void = null,
};

/// Sets *err (when wanted) and returns code.
pub fn fail(err: ?*?*api.Error, code: Code, comptime fmt: []const u8, args: anytype) Code {
    return failWith(err, code, .{}, fmt, args);
}

pub fn badArgument(err: ?*?*api.Error, comptime message: []const u8) Code {
    return fail(err, .e_invalid_argument, message, .{});
}

pub fn notFound(err: ?*?*api.Error, subject: []const u8, comptime message: []const u8) Code {
    return failWith(err, .e_not_found, .{ .subject = subject }, message, .{});
}

/// INVALID_VALUE with the problems an op list has.
pub fn badOps(
    err: ?*?*api.Error,
    problems: []const ProblemSpec,
    comptime message: []const u8,
) Code {
    return failWith(err, .e_invalid_value, .{ .problems = problems }, message, .{});
}

pub fn oom(err: ?*?*api.Error) Code {
    return fail(err, .e_nomem, "out of memory", .{});
}

/// The end of most calls: a new handle goes to the caller's `out`.
pub fn give(out: anytype, made: anytype, err: ?*?*api.Error) Code {
    out.* = @ptrCast(made catch |e| return failError(err, e, .{}));
    return .ok;
}

pub fn failWith(
    err: ?*?*api.Error,
    code: Code,
    detail: Detail,
    comptime fmt: []const u8,
    args: anytype,
) Code {
    const out = err orelse {
        if (detail.write) |w| detail.free_write.?(w);
        return code;
    };
    out.* = makeError(code, detail, fmt, args) catch null;
    return code;
}

fn makeError(code: Code, detail: Detail, comptime fmt: []const u8, args: anytype) !*api.Error {
    const arena = try newArena();
    errdefer freeArena(arena);
    const a = arena.allocator();
    const e = try a.create(ErrorObj);
    const message = try std.fmt.allocPrint(a, fmt, args);
    e.* = .{
        .arena = arena,
        .code = code,
        .message = try dupeZ(a, message),
        .subject = try dupeZ(a, detail.subject),
        .git_stderr = try dupeZ(a, std.mem.trim(u8, detail.git_stderr, " \t\r\n")),
        .current_tip = detail.current_tip,
        .write = detail.write,
        .free_write = detail.free_write,
    };
    if (detail.problems.len > 0) e.problems = try borrowedProblems(a, detail.problems);
    return @ptrCast(e);
}

pub fn issuez_error_free(err: ?*api.Error) callconv(.c) void {
    const e = obj(ErrorObj, err) orelse return;
    if (e.write) |w| e.free_write.?(w);
    freeArena(e.arena);
}

const ErrorReads = Reads(api.Error, ErrorObj);
pub const issuez_error_code = ErrorReads.field("code");
pub const issuez_error_message = ErrorReads.field("message");
pub const issuez_error_subject = ErrorReads.field("subject");
pub const issuez_error_git_stderr = ErrorReads.field("git_stderr");

pub fn issuez_error_current_tip(err: ?*const api.Error, out: ?*api.Oid) callconv(.c) bool {
    const e = obj(ErrorObj, err) orelse return false;
    const tip = e.current_tip orelse return false;
    if (out) |o| o.* = tip;
    return true;
}

pub fn issuez_error_problems(err: ?*const api.Error) callconv(.c) ?*const api.Problems {
    const e = obj(ErrorObj, err) orelse return null;
    return if (e.problems) |p| @ptrCast(p) else null;
}

pub fn issuez_error_write(err: ?*const api.Error) callconv(.c) ?*const api.Write {
    const e = obj(ErrorObj, err) orelse return null;
    return if (e.write) |w| @ptrCast(w) else null;
}

/// Library errors to codes and messages.
pub fn failError(err: ?*?*api.Error, e: anyerror, detail: Detail) Code {
    const code = codeOf(e);
    const text = switch (e) {
        error.NullHandle => "a required handle or out pointer is NULL",
        error.UnknownKind => "not an issue or milestone kind",
        else => issuez.errors.describe(e) orelse @errorName(e),
    };
    return failWith(err, code, detail, "{s}", .{text});
}

pub fn codeOf(e: anyerror) Code {
    return switch (e) {
        error.OutOfMemory => .e_nomem,
        error.NullHandle => .e_invalid_argument,
        error.Canceled => .e_cancelled,
        error.GitTimedOut => .e_timeout,
        error.GitSpawnFailed, error.GitFailed, error.OutputTooLong, error.StoreFailed => .e_git,
        error.GitTooOld => .e_git_version,
        error.NotARepository => .e_not_a_repository,
        error.LfsUnavailable, error.LfsTransferFailed, error.LfsUploadFailed => .e_lfs,
        error.AttachmentTooLarge, error.TooManyAttachments => .e_limit,
        error.UnsupportedType,
        error.AnimatedImage,
        error.MediaMismatch,
        error.EmptyAttachment,
        error.AttachmentExists,
        => .e_invalid_value,
        error.AttachmentNotFound => .e_not_found,
        error.NoAttachments => .e_invalid_argument,
        error.HistoryTooLong,
        error.TooManyIssues,
        error.TooLong,
        error.TooManyLabels,
        error.TooManyBlockers,
        error.GuardScanTooLarge,
        error.TooDeep,
        => .e_limit,
        error.CorruptIssue, error.MissingParent, error.NoRoot => .e_corrupt,
        error.ConcurrentModification, error.RefConflict => .e_contended,
        error.VersionMismatch => .e_version_mismatch,
        error.IssueDisappeared,
        error.ReferenceNotFound,
        error.CommentNotFound,
        => .e_not_found,
        error.ParentIsSelf,
        error.ParentCycle,
        error.BlocksItself,
        error.BlockerCycle,
        error.OpenDescendants,
        error.ClosedAncestor,
        error.ActiveChildren,
        error.ParentDeleted,
        error.MilestoneCompleted,
        error.MilestoneRetired,
        error.OpenWorkInMilestone,
        error.NumberTaken,
        => .e_guard,
        error.InvalidText,
        error.BodyLooksLikeTrailers,
        error.MessageHasBody,
        error.CommentNotAlone,
        error.NumberAlreadySet,
        error.EmptyText,
        error.InvalidLabel,
        error.InvalidValue,
        error.UnknownWorkflowState,
        error.InvalidWorkflowStates,
        error.NothingToEdit,
        error.IdentityUnknown,
        => .e_invalid_value,
        error.InvalidLimits, error.InvalidIssueRef, error.UnknownKind => .e_invalid_argument,
        error.AttachmentsUnsupported => .e_unsupported,
        else => .e_internal,
    };
}

/// The problem a write error stands for, on the field it is about.
pub fn problemOf(e: anyerror, field: api.Field, op_index: i64) ProblemSpec {
    const kind: api.ProblemKind = switch (e) {
        error.InvalidText => .newline,
        error.CommentNotAlone => .incompatible,
        error.NumberAlreadySet => .read_only_field,
        error.NumberTaken => .duplicate_number,
        error.BodyLooksLikeTrailers => .trailer_body,
        error.EmptyText => .empty,
        error.TooLong => .too_long,
        error.TooManyLabels,
        error.TooManyBlockers,
        error.TooManyAssignees,
        error.TooManyAttachments,
        => .too_many,
        error.AttachmentTooLarge => .too_long,
        error.EmptyAttachment => .empty,
        error.UnknownWorkflowState, error.InvalidWorkflowStates => .unknown_workflow_state,
        error.ParentIsSelf, error.BlocksItself => .self_reference,
        error.ParentCycle, error.BlockerCycle => .cycle,
        error.TooDeep => .too_deep,
        error.ReferenceNotFound => .missing_target,
        error.ParentDeleted => .deleted_target,
        error.OpenDescendants, error.ActiveChildren => .open_children,
        error.ClosedAncestor => .closed_ancestor,
        error.MilestoneCompleted, error.MilestoneRetired => .milestone_closed,
        error.OpenWorkInMilestone => .milestone_open_work,
        else => .bad_format,
    };
    return .{
        .kind = kind,
        .field = field,
        .message = issuez.errors.describe(e) orelse @errorName(e),
        .op_index = op_index,
    };
}

// ─── Arenas ────────────────────────────────────────────────────────────

pub fn newArena() Allocator.Error!*std.heap.ArenaAllocator {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    return arena;
}

pub fn freeArena(arena: *std.heap.ArenaAllocator) void {
    arena.deinit();
    gpa.destroy(arena);
}

/// A handle in an arena of its own: `build`, given the arena, makes the
/// object, and the handle's `arena` is set after it. A failure frees the arena.
pub fn owned(comptime Obj: type, comptime build: anytype, args: anytype) !*Obj {
    const arena = try newArena();
    errdefer freeArena(arena);
    const a = arena.allocator();
    const made = try a.create(Obj);
    made.* = try @call(.auto, build, .{a} ++ args);
    made.arena = arena;
    return made;
}

/// A handle that is nothing but a list.
pub fn Items(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        items: []const T,
    };
}

// ─── Cancel ────────────────────────────────────────────────────────────

pub const CancelObj = struct {
    triggered: std.atomic.Value(bool) = .init(false),
};

pub fn issuez_cancel_new() callconv(.c) ?*api.Cancel {
    const c = gpa.create(CancelObj) catch return null;
    c.* = .{};
    return @ptrCast(c);
}

pub fn issuez_cancel_trigger(c: ?*api.Cancel) callconv(.c) void {
    const t = obj(CancelObj, c) orelse return;
    t.triggered.store(true, .release);
}

pub fn issuez_cancel_free(c: ?*api.Cancel) callconv(.c) void {
    const t = obj(CancelObj, c) orelse return;
    gpa.destroy(t);
}

pub fn hasReserved(x: anytype) bool {
    for (x.reserved) |r| if (r != 0) return true;
    return false;
}

pub fn cancelled(c: ?*api.Cancel) bool {
    const t = obj(CancelObj, c) orelse return false;
    return t.triggered.load(.acquire);
}

/// What a running git request watches, so triggering kills it.
pub fn cancelFlag(c: ?*api.Cancel) ?*const std.atomic.Value(bool) {
    const t = obj(CancelObj, c) orelse return null;
    return &t.triggered;
}

// ─── Logging ───────────────────────────────────────────────────────────

pub const Logger = struct { cb: api.LogFn, userdata: ?*anyopaque };

/// A repo's own logger and its level, for the calls on it.
pub const ScopedLogger = struct {
    logger: Logger = .{ .cb = null, .userdata = null },
    /// 0: none, the process-wide one logs.
    level: u32 = 0,
};

/// The logger of the repo whose call runs on this thread.
pub threadlocal var scoped: ScopedLogger = .{};

var log_level: std.atomic.Value(u32) = .init(0);
/// A spin lock: setting the logger is rare and may come before init.
var logger_lock: std.atomic.Value(bool) = .init(false);
var logger: Logger = .{ .cb = null, .userdata = null };

fn lockLogger() void {
    while (logger_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null)
        std.atomic.spinLoopHint();
}

fn unlockLogger() void {
    logger_lock.store(false, .release);
}

pub fn issuez_set_logger(
    min_level: api.LogLevel,
    cb: api.LogFn,
    userdata: ?*anyopaque,
) callconv(.c) void {
    lockLogger();
    defer unlockLogger();
    logger = .{ .cb = cb, .userdata = userdata };
    log_level.store(if (cb == null) 0 else @intFromEnum(min_level), .release);
}

pub fn logging(level: api.LogLevel) bool {
    if (scoped.level != 0) return @intFromEnum(level) <= scoped.level;
    const min = log_level.load(.acquire);
    return min != 0 and @intFromEnum(level) <= min;
}

/// Sets a repo's logger; `target` is the repo's field.
pub fn setScoped(
    target: *ScopedLogger,
    min_level: api.LogLevel,
    cb: api.LogFn,
    userdata: ?*anyopaque,
) void {
    lockLogger();
    defer unlockLogger();
    target.* = .{
        .logger = .{ .cb = cb, .userdata = userdata },
        .level = if (cb == null) 0 else @intFromEnum(min_level),
    };
}

/// A repo's logger as it is now, for a call to log through.
pub fn readScoped(from: *const ScopedLogger) ScopedLogger {
    lockLogger();
    defer unlockLogger();
    return from.*;
}

pub const LogSpec = struct {
    operation: []const u8,
    message: []const u8 = "",
    repo_path: []const u8 = "",
    subject: []const u8 = "",
    duration_ns: i64 = -1,
    attempt: u32 = 0,
};

pub fn log(level: api.LogLevel, spec: LogSpec) void {
    if (!logging(level)) return;
    const l = if (scoped.level != 0) scoped.logger else blk: {
        lockLogger();
        defer unlockLogger();
        break :blk logger;
    };
    const cb = l.cb orelse return;
    // Every issuez_str is NUL-terminated, these too: copied for the call,
    // a long message cut short.
    var buf: [log_buf_bytes]u8 = undefined;
    var used: usize = 0;
    const event: api.LogEvent = .{
        .level = @intFromEnum(level),
        .operation = terminated(&buf, &used, spec.operation),
        .message = terminated(&buf, &used, spec.message),
        .repo_path = terminated(&buf, &used, spec.repo_path),
        .subject = terminated(&buf, &used, spec.subject),
        .duration_ns = spec.duration_ns,
        .attempt = spec.attempt,
    };
    cb(l.userdata, &event);
}

const log_buf_bytes = 8 * 1024;

/// `s` and a NUL in what's left of `buf`, as much as fits.
fn terminated(buf: *[log_buf_bytes]u8, used: *usize, s: []const u8) Str {
    const room = buf.len - used.*;
    if (room == 0) return .{};
    const n = @min(s.len, room - 1);
    const start = used.*;
    @memcpy(buf[start..][0..n], s[0..n]);
    buf[start + n] = 0;
    used.* += n + 1;
    return .{ .ptr = buf[start..].ptr, .len = n };
}

test "log strings are NUL-terminated" {
    var buf: [log_buf_bytes]u8 = undefined;
    var used: usize = 0;
    const a = terminated(&buf, &used, "git.read-object");
    const b = terminated(&buf, &used, "");
    try std.testing.expectEqualStrings("git.read-object", a.slice());
    try std.testing.expectEqual(@as(u8, 0), a.ptr.?[a.len]);
    try std.testing.expectEqual(@as(u8, 0), b.ptr.?[0]);
    const long = [_]u8{'x'} ** (2 * log_buf_bytes);
    const c = terminated(&buf, &used, &long);
    try std.testing.expectEqual(@as(u8, 0), c.ptr.?[c.len]);
    try std.testing.expectEqual(@as(usize, log_buf_bytes), used);
}

test compatible {
    try std.testing.expect(compatible(api.abi_version));
    try std.testing.expect(!compatible(api.abi_version + (1 << 16)));
}

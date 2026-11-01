//! Helpers shared by subcommands.

const std = @import("std");
const issuez = @import("issuez");
const context = @import("context.zig");

pub const engine = issuez.engine;

/// Like upstream (and git): 1 for user errors, 128 for "not a repository"
/// and a missing identity.
pub const exit_ok: u8 = 0;
pub const exit_error: u8 = 1;
pub const exit_fatal: u8 = 128;

pub const Args = struct {
    list: []const []const u8,
    i: usize = 0,
    options_done: bool = false,
    /// Set right after the `--` that ends options. A later `--` is a plain
    /// argument.
    was_separator: bool = false,

    pub fn next(a: *Args) ?[]const u8 {
        if (a.i >= a.list.len) return null;
        defer a.i += 1;
        return a.list[a.i];
    }

    /// Consumes `--` itself.
    pub fn isOption(a: *Args, arg: []const u8) bool {
        a.was_separator = false;
        if (a.options_done) return false;
        if (std.mem.eql(u8, arg, "--")) {
            a.options_done = true;
            a.was_separator = true;
            return false;
        }
        return arg.len > 1 and arg[0] == '-';
    }

    pub fn value(a: *Args, err: *std.Io.Writer, flag: []const u8) ?[]const u8 {
        if (a.i >= a.list.len) {
            err.print("error: {s} requires a value\n", .{flag}) catch {};
            return null;
        }
        defer a.i += 1;
        return a.list[a.i];
    }
};

/// `-s/--state` of `ls` and `search`: a state, or `all` (null).
pub fn stateFilter(value: []const u8) ?issuez.format.core.State {
    if (std.mem.eql(u8, value, "all")) return null;
    return issuez.format.core.State.parse(value);
}

pub fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

pub fn unknownOption(err: *std.Io.Writer, cmd: []const u8, arg: []const u8) u8 {
    err.print(
        "error: unknown option '{s}'\nRun 'git issue {s} --help' for usage.\n",
        .{ arg, cmd },
    ) catch {};
    return exit_error;
}

pub fn missing(err: *std.Io.Writer, cmd: []const u8, what: []const u8) u8 {
    err.print("error: {s}\nRun 'git issue {s} --help' for usage.\n", .{ what, cmd }) catch {};
    return exit_error;
}

/// `msg` is a complete line, like "error: title must not be empty\n".
pub fn fail(err: *std.Io.Writer, msg: []const u8) u8 {
    err.writeAll(msg) catch {};
    return exit_error;
}

pub fn oom(err: *std.Io.Writer) u8 {
    return fail(err, "error: out of memory\n");
}

/// For any error from the library.
pub fn repoFailed(comptime B: type, ctx: *context.Context(B), e: anyerror) u8 {
    reportRepoError(B, ctx, e);
    return engineExitCode(e);
}

pub fn openRepo(comptime B: type, ctx: *context.Context(B)) ?engine.Repo(B) {
    const backend = ctx.backend catch |err| {
        reportOpenError(ctx.err, err);
        return null;
    };
    warnUnsafeRefspecs(B, backend, ctx.arena, ctx.err);
    var repo = engine.Repo(B).init(backend);
    repo.done_states = doneStates(B, backend, ctx.arena, ctx.err) orelse return null;
    return repo;
}

/// `git config issue.doneStates "wontfix,duplicate"`: the states besides
/// `closed` that count as done. Empty for none.
fn doneStates(
    comptime B: type,
    backend: *B,
    arena: std.mem.Allocator,
    err: *std.Io.Writer,
) ?[]const []const u8 {
    const raw = backend.configGet(arena, "issue.doneStates") catch {
        err.writeAll("error: could not read git config issue.doneStates\n") catch {};
        return null;
    } orelse return &issuez.format.core.default_done_states;
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const s = std.mem.trim(u8, part, " \t");
        if (s.len == 0) continue;
        if (!issuez.format.core.isState(s) or std.mem.eql(u8, s, "open")) {
            err.print(
                "error: issue.doneStates has '{s}'; states are letters, digits, '-' " ++
                    "and '_', and 'open' can't be done\n",
                .{s},
            ) catch {};
            return null;
        }
        out.append(arena, s) catch return null;
    }
    return out.items;
}

/// For `init`, which deals with the refspec itself.
pub fn openRepoQuiet(comptime B: type, ctx: *context.Context(B)) ?engine.Repo(B) {
    const backend = ctx.backend catch |err| {
        reportOpenError(ctx.err, err);
        return null;
    };
    return engine.Repo(B).init(backend);
}

/// Upstream's `init` sets `+refs/issues/*:refs/issues/*`, so a plain
/// `git fetch` can overwrite local issue refs and lose unpushed commits.
/// We warn on every command until it is fixed.
fn warnUnsafeRefspecs(
    comptime B: type,
    backend: *B,
    arena: std.mem.Allocator,
    err: *std.Io.Writer,
) void {
    const remotes = backend.remoteNames(arena) catch return;
    for (remotes) |remote| {
        const key = std.fmt.allocPrint(arena, "remote.{s}.fetch", .{remote}) catch return;
        const specs = backend.configGetAll(arena, key) catch continue;
        for (specs) |spec| {
            if (!std.mem.eql(
                u8,
                std.mem.trimStart(u8, spec, "+"),
                "refs/issues/*:refs/issues/*",
            )) continue;
            err.print(
                "warning: remote '{s}' fetches straight into refs/issues/*\n" ++
                    "         (set by upstream git-issue init). A plain 'git fetch' can then\n" ++
                    "         overwrite local issues and drop unpushed changes.\n" ++
                    "         Fix with: git issue init {s} --fix-refspec\n",
                .{ remote, remote },
            ) catch {};
            break;
        }
    }
}

fn reportOpenError(err: *std.Io.Writer, e: anyerror) void {
    switch (e) {
        error.NotARepository => err.writeAll("fatal: not a git repository\n") catch {},
        error.GitTooOld => err.print("fatal: git {d}.{d} or newer is required\n", .{
            issuez.backend.GitProcess.min_git_version.major,
            issuez.backend.GitProcess.min_git_version.minor,
        }) catch {},
        error.GitSpawnFailed => err.writeAll(
            "fatal: could not run git (is it installed and on PATH?)\n",
        ) catch {},
        else => err.print("fatal: could not open the repository ({t})\n", .{e}) catch {},
    }
}

pub fn resolveOne(
    comptime B: type,
    repo: engine.Repo(B),
    arena: std.mem.Allocator,
    err: *std.Io.Writer,
    prefix: []const u8,
) ?engine.IssueRef {
    const resolution = repo.resolve(arena, prefix) catch |e| {
        reportEngineError(err, e);
        return null;
    };
    switch (resolution) {
        .one => |r| return r,
        .none => {
            err.print("error: issue '{s}' not found\n", .{prefix}) catch {};
            return null;
        },
        .many => |matches| {
            err.print("error: ambiguous issue prefix '{s}', matches:\n", .{prefix}) catch {};
            for (matches) |m| {
                const title = if (repo.load(arena, m)) |issue| issue.title else |_| "?";
                err.print("  {s}  {s}\n", .{ issuez.format.uuid.shortId(m.id()), title }) catch {};
            }
            return null;
        },
    }
}

pub fn reportEngineError(err: *std.Io.Writer, e: anyerror) void {
    const msg: []const u8 = switch (e) {
        error.IdentityUnknown => "fatal: no git identity configured\n" ++
            "       run: git config user.name \"Your Name\"\n" ++
            "            git config user.email \"you@example.com\"\n",
        error.ConcurrentModification => "error: the issue kept changing while it was being " ++
            "updated; try again\n",
        error.IssueDisappeared => "error: the issue was deleted while it was being updated\n",
        error.BodyLooksLikeTrailers => "error: the last paragraph of the text would be read " ++
            "as issue metadata\n" ++
            "       (lines like 'Key: value'); reword it or add a sentence after it\n",
        error.InvalidText => "error: values must not contain newlines\n",
        error.TooLong => "error: text is too long\n",
        error.TooManyLabels => "error: too many labels\n",
        error.TooManyBlockers => "error: too many blockers\n",
        error.InvalidValue => "error: invalid value\n",
        error.ReferenceNotFound => "error: the referenced issue doesn't exist here\n",
        error.ParentIsSelf => "error: an issue can't be its own parent\n",
        error.ParentCycle => "error: that parent is the issue itself or one of its " ++
            "descendants (the hierarchy would loop)\n",
        error.TooDeep => "error: the hierarchy would be nested deeper than 8 levels\n",
        error.BlocksItself => "error: an issue can't block itself\n",
        error.BlockerCycle => "error: that issue is (transitively) blocked by this one; " ++
            "blocking it back would be a cycle\n",
        error.OpenDescendants => "error: the issue has open sub-issues; close them first " ++
            "(see 'git issue tree <id>')\n",
        error.ClosedAncestor => "error: a parent (or one above it) is closed; " ++
            "reopen it first\n",
        error.GuardScanTooLarge => "error: checking the hierarchy would read more issues " ++
            "than allowed\n",
        error.ActiveChildren => "error: the issue has sub-issues that aren't deleted; " ++
            "delete or move them first (see 'git issue tree <id>')\n",
        error.CommentNotFound => "error: that isn't a comment of this issue\n",
        error.ParentDeleted => "error: that parent is deleted; restore it first\n",
        error.MilestoneCompleted => "error: the milestone is completed; reopen it first " ++
            "('git issue milestone reopen')\n",
        error.MilestoneRetired => "error: the milestone is retired; pick another one\n",
        error.AttachmentsUnsupported => "error: this backend has no attachment store\n",
        error.UnsupportedType => "not a PNG, JPEG or WebP image\n",
        error.AnimatedImage => "animated images aren't supported\n",
        error.MediaMismatch => "the file's type doesn't match its contents\n",
        error.AttachmentTooLarge => "larger than the attachment limit (5 MiB)\n",
        error.EmptyAttachment => "the file is empty\n",
        error.TooManyAttachments => "error: an issue can have at most 30 attachments\n",
        error.AttachmentNotFound => "error: no such attachment on this issue\n",
        error.NoAttachments => "error: no attachments given\n",
        error.StoreFailed => "error: could not read or write the LFS store\n",
        error.LfsUploadFailed => "error: git-lfs couldn't upload the attachments' objects, so " ++
            "nothing was pushed\n" ++
            "       (does the remote have an LFS server? see 'git lfs env')\n",
        error.LfsUnavailable => "error: attachments need git-lfs, which isn't installed " ++
            "(https://git-lfs.com)\n",
        error.LfsTransferFailed => "error: git-lfs couldn't transfer the attachment objects\n",
        error.OpenWorkInMilestone => "error: the milestone still has open issues; close or " ++
            "move them first (see 'git issue milestone show')\n",
        error.NothingToEdit => "error: at least one edit option is required\n",
        error.InvalidIssueRef => "error: not an issue ref\n",
        error.VersionMismatch => "error: the issue changed since it was read\n",
        error.TooManyIssues => "error: more issues than the configured limit\n",
        error.InvalidLimits => "error: invalid limits\n",
        error.HistoryTooLong => "error: issue history is too long to load\n",
        error.CorruptIssue => "error: issue data is damaged (run 'git issue fsck')\n",
        error.GitFailed => "error: a git command failed\n",
        error.GitSpawnFailed => "fatal: could not run git (is it installed and on PATH?)\n",
        error.OutputTooLong => "error: git produced more output than allowed\n",
        else => {
            err.print("error: {t}\n", .{e}) catch {};
            return;
        },
    };
    err.writeAll(msg) catch {};
}

/// Also prints git's own stderr when a git command failed, so users see
/// e.g. "Permission denied".
pub fn reportRepoError(comptime B: type, ctx: *context.Context(B), e: anyerror) void {
    if (e == error.IdentityUnknown) if (reportMissingIdentity(B, ctx)) return;
    reportEngineError(ctx.err, e);
    const has_detail = e == error.GitFailed or e == error.LfsTransferFailed or
        e == error.LfsUploadFailed;
    if (!has_detail) return;
    if (!@hasDecl(B, "lastStderr")) return;
    const backend = ctx.backend catch return;
    const detail = std.mem.trim(u8, backend.lastStderr(), " \t\r\n");
    if (detail.len == 0) return;
    var lines = std.mem.splitScalar(u8, detail, '\n');
    while (lines.next()) |line| ctx.err.print("       git: {s}\n", .{line}) catch {};
}

/// Upstream's `validate_git_identity` messages. Returns false when both
/// name and email are set and git refused the identity for another reason.
fn reportMissingIdentity(comptime B: type, ctx: *context.Context(B)) bool {
    const parts = [_]struct { key: []const u8, env: [2][]const u8, hint: []const u8 }{
        .{
            .key = "user.name",
            .env = .{ "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME" },
            .hint = "git config user.name \"Your Name\"",
        },
        .{
            .key = "user.email",
            .env = .{ "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL" },
            .hint = "git config user.email \"you@example.com\"",
        },
    };
    const backend = ctx.backend catch return false;
    for (parts) |part| {
        const set = for (part.env) |name| {
            if (ctx.environ_map.get(name)) |v| if (v.len > 0) break true;
        } else blk: {
            const value = backend.configGet(ctx.arena, part.key) catch break :blk true;
            break :blk value != null and value.?.len > 0;
        };
        if (set) continue;
        ctx.err.print("fatal: {s} not set\n       run: {s}\n", .{ part.key, part.hint }) catch {};
        return true;
    }
    return false;
}

pub fn engineExitCode(e: anyerror) u8 {
    return switch (e) {
        error.IdentityUnknown => exit_fatal,
        else => exit_error,
    };
}

/// An email, or `<uuid> <email>`.
pub fn validateAssignee(err: *std.Io.Writer, value: []const u8) bool {
    const space = std.mem.findScalar(u8, value, ' ') orelse
        return validateEmail(err, "assignee", value);
    if (!issuez.format.uuid.isCanonical(value[0..space]))
        return validateEmail(err, "assignee", value);
    const a = issuez.format.fields.Assignee.parse(value) orelse {
        err.writeAll("error: assignee must be an email or '<uuid> <email>'\n") catch {};
        return false;
    };
    return validateEmail(err, "assignee", a.email);
}

/// Upstream's `validate_email` messages. Empty is allowed and clears the
/// assignee.
pub fn validateEmail(err: *std.Io.Writer, field: []const u8, email: []const u8) bool {
    if (email.len == 0) return true;
    const problem = issuez.format.core.checkEmail(email) orelse return true;
    const what = switch (problem) {
        .not_an_email => "must be a valid email address (format: user@domain.com)",
        .missing_local_part => "email missing local part (before @)",
        .missing_domain => "email missing domain (between @ and .)",
        .missing_tld => "email missing TLD (after final .)",
    };
    err.print("error: {s} {s}\n", .{ field, what }) catch {};
    return false;
}

pub fn hasNewline(s: []const u8) bool {
    return std.mem.findAny(u8, s, "\r\n") != null;
}

pub fn hasBlankLine(s: []const u8) bool {
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, s, "\n"), '\n');
    while (lines.next()) |line| if (std.mem.trim(u8, line, " \t\r").len == 0) return true;
    return false;
}

/// git's `%ai` format, in the signature's own time zone.
pub const IsoDate = struct {
    time: i64,
    tz: i16,

    pub fn format(d: IsoDate, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const local = d.time + @as(i64, d.tz) * 60;
        const days = @divFloor(local, 86400);
        const secs: u32 = @intCast(local - days * 86400);
        const civil = civilFromDays(days);
        const abs_tz: u16 = @abs(d.tz);
        try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {c}{d:0>2}{d:0>2}", .{
            @as(u32, @intCast(civil.year)),      civil.month,      civil.day,
            secs / 3600,                         (secs / 60) % 60, secs % 60,
            @as(u8, if (d.tz < 0) '-' else '+'), abs_tz / 60,      abs_tz % 60,
        });
    }
};

/// Howard Hinnant's days-from-civil, inverted.
fn civilFromDays(z_in: i64) struct { year: i64, month: u8, day: u8 } {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097;
    const yoe = @divFloor(
        doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096),
        365,
    );
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = if (m <= 2) y + 1 else y, .month = m, .day = d };
}

test IsoDate {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f}", .{IsoDate{ .time = 1760799642, .tz = 330 }});
    try t.expectEqualStrings("2025-10-18 20:30:42 +0530", w.buffered());
    w = .fixed(&buf);
    try w.print("{f}", .{IsoDate{ .time = 0, .tz = -60 }});
    try t.expectEqualStrings("1969-12-31 23:00:00 -0100", w.buffered());
}

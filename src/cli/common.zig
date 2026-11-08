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
    // One git call for every setting read here.
    const config = backend.configList(ctx.arena) catch {
        ctx.err.writeAll("error: could not read git config\n") catch {};
        return null;
    };
    warnUnsafeRefspecs(ctx.arena, config, ctx.err);
    const settings = issuez.settings.fromConfig(ctx.arena, config) catch {
        _ = oom(ctx.err);
        return null;
    };
    var repo = engine.Repo(B).fromSettings(backend, settings) catch {
        ctx.err.print(
            "error: issue.doneStates has '{s}'; " ++ issuez.settings.done_states_rule ++ "\n",
            .{settings.invalid_done_state.?},
        ) catch {};
        return null;
    };
    ctx.settings = settings;
    // One listing of the issues per command, until a write.
    repo.call.listing = ctx.arena.create(engine.Repo(B).Listing) catch {
        _ = oom(ctx.err);
        return null;
    };
    repo.call.listing.?.* = .{};
    return repo;
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
    arena: std.mem.Allocator,
    config: []const issuez.backend.contract.ConfigEntry,
    err: *std.Io.Writer,
) void {
    var warned: std.ArrayList([]const u8) = .empty;
    for (config) |e| {
        if (!std.mem.startsWith(u8, e.key, "remote.") or !std.mem.endsWith(u8, e.key, ".fetch"))
            continue;
        if (e.key.len <= "remote.".len + ".fetch".len) continue;
        const remote = e.key["remote.".len .. e.key.len - ".fetch".len];
        if (!std.mem.eql(u8, std.mem.trimStart(u8, e.value, "+"), "refs/issues/*:refs/issues/*"))
            continue;
        const seen = for (warned.items) |w| {
            if (std.mem.eql(u8, w, remote)) break true;
        } else false;
        if (seen) continue;
        warned.append(arena, remote) catch return;
        err.print(
            "warning: remote '{s}' fetches straight into refs/issues/*\n" ++
                "         (set by upstream git-issue init). A plain 'git fetch' can then\n" ++
                "         overwrite local issues and drop unpushed changes.\n" ++
                "         Fix with: git issue init {s} --fix-refspec\n",
            .{ remote, remote },
        ) catch {};
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

/// `issuez.errors.describe`, with the CLI's own wording where it says
/// more (a command to run, `fatal:` for setup problems).
/// The CLI's repos run with the default limits.
pub fn reportEngineError(err: *std.Io.Writer, e: anyerror) void {
    const msg: []const u8 = switch (e) {
        error.IdentityUnknown => "fatal: no git identity configured\n" ++
            "       run: git config user.name \"Your Name\"\n" ++
            "            git config user.email \"you@example.com\"\n",
        error.BodyLooksLikeTrailers => "error: the last paragraph of the text would be read " ++
            "as issue metadata\n" ++
            "       (lines like 'Key: value'); reword it or add a sentence after it\n",
        error.OpenDescendants => "error: the issue has open sub-issues; close them first " ++
            "(see 'git issue tree <id>')\n",
        error.ActiveChildren => "error: the issue has sub-issues that aren't deleted; " ++
            "delete or move them first (see 'git issue tree <id>')\n",
        error.MilestoneCompleted => "error: the milestone is completed; reopen it first " ++
            "('git issue milestone reopen')\n",
        error.UnsupportedType => "not a PNG, JPEG or WebP image\n",
        error.AnimatedImage => "animated images aren't supported\n",
        error.MediaMismatch => "the file's type doesn't match its contents\n",
        // After the file's name, like the ones above.
        error.AttachmentTooLarge => {
            err.print("{f}\n", .{issuez.errors.Description{ .err = e, .limits = .{} }}) catch {};
            return;
        },
        error.EmptyAttachment => "the file is empty\n",
        error.LfsUploadFailed => "error: git-lfs couldn't upload the attachments' objects, so " ++
            "nothing was pushed\n" ++
            "       (does the remote have an LFS server? see 'git lfs env')\n",
        error.OpenWorkInMilestone => "error: the milestone still has open issues; close or " ++
            "move them first (see 'git issue milestone show')\n",
        error.NothingToEdit => "error: at least one edit option is required\n",
        // Its own messages say which value; this is the rest.
        error.InvalidValue => "error: invalid value\n",
        error.MessageHasBody => "error: with --description, -m is only the subject (no blank " ++
            "lines)\n",
        error.CorruptIssue => "error: issue data is damaged (run 'git issue fsck')\n",
        error.GitSpawnFailed => "fatal: could not run git (is it installed and on PATH?)\n",
        else => {
            err.print(
                "error: {f}\n",
                .{issuez.errors.Description{ .err = e, .limits = .{} }},
            ) catch {};
            return;
        },
    };
    err.writeAll(msg) catch {};
}

/// Also prints git's own stderr when a git command failed, so users see
/// e.g. "Permission denied".
pub fn reportRepoError(comptime B: type, ctx: *context.Context(B), e: anyerror) void {
    // Before reportMissingIdentity runs git again.
    const detail = gitDetail(B, ctx, e);
    if (e == error.IdentityUnknown) if (reportMissingIdentity(B, ctx)) return;
    reportEngineError(ctx.err, e);
    printDetail(ctx.err, detail);
}

/// git's error output for `e`, as `git:` lines (`issuez.errors.gitDetail`).
pub fn printGitDetail(comptime B: type, ctx: *context.Context(B), e: anyerror) void {
    printDetail(ctx.err, gitDetail(B, ctx, e));
}

/// A copy, since the next git command replaces the backend's.
fn gitDetail(comptime B: type, ctx: *context.Context(B), e: anyerror) ?[]const u8 {
    const backend = ctx.backend catch return null;
    const d = issuez.errors.gitDetail(backend, e) orelse return null;
    return ctx.arena.dupe(u8, d) catch null;
}

fn printDetail(err: *std.Io.Writer, detail: ?[]const u8) void {
    var lines = std.mem.splitScalar(u8, detail orelse return, '\n');
    while (lines.next()) |line| if (line.len > 0) err.print("       git: {s}\n", .{line}) catch {};
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
/// A value `validateAssignee` passed.
pub fn assigneeOf(value: []const u8) issuez.format.fields.Assignee {
    return issuez.format.fields.Assignee.parse(value).?;
}

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

pub const IsoDate = issuez.format.time.IsoDate;

/// `--field KEY=VALUE` and `--original-author`/`--original-id`, shared by
/// create, edit and comment.
pub const Extras = struct {
    fields: std.ArrayList(issuez.engine.HostField) = .empty,
    original: issuez.engine.Original = .{},

    /// True when `arg` was one of them; false otherwise. Null on an error,
    /// already reported.
    pub fn parse(
        x: *Extras,
        arena: std.mem.Allocator,
        err: *std.Io.Writer,
        args: *Args,
        arg: []const u8,
    ) ?bool {
        if (std.mem.eql(u8, arg, "--field")) {
            const v = args.value(err, arg) orelse return null;
            const eq = std.mem.findScalar(u8, v, '=') orelse {
                err.writeAll("error: --field takes KEY=VALUE\n") catch {};
                return null;
            };
            if (hasNewline(v)) {
                err.writeAll("error: --field value must be one line\n") catch {};
                return null;
            }
            x.fields.append(arena, .{ .key = v[0..eq], .value = v[eq + 1 ..] }) catch return null;
            return true;
        }
        if (std.mem.eql(u8, arg, "--original-author") or std.mem.eql(u8, arg, "--original-id")) {
            const v = args.value(err, arg) orelse return null;
            if (hasNewline(v) or v.len == 0) {
                err.print("error: {s} takes one line of text\n", .{arg}) catch {};
                return null;
            }
            if (std.mem.eql(
                u8,
                arg,
                "--original-author",
            )) x.original.author = v else x.original.id = v;
            return true;
        }
        return false;
    }
};

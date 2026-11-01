//! `git issue attach <subcommand> <issue-id> ...`, see docs/attachments.md.

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const issuez = @import("issuez");
const json = @import("../json.zig");
const uuid = issuez.format.uuid;

pub const help =
    \\usage: git issue attach <subcommand> <issue-id> [args]
    \\
    \\Attach PNG, JPEG or WebP images to an issue. The images are stored in
    \\the repository's LFS store (git-lfs compatible) and listed in the issue
    \\history, so every tool that reads the issue sees them. An attachment is
    \\named by a unique prefix of its ID (at least 4 characters).
    \\
    \\Subcommands:
    \\   add <issue-id> <file>...       Attach files (-m: post a comment with them)
    \\   ls <issue-id>                  List the attachments
    \\   cat <issue-id> <attachment>    Write an attachment's bytes to stdout
    \\   rename <issue-id> <attachment> <name>  Rename an attachment
    \\   rm <issue-id> <attachment>...  Remove attachments
    \\   fetch [<issue-id>]             Download missing bytes (all issues by default)
    \\
    \\Attachments need git-lfs (https://git-lfs.com); every subcommand refuses
    \\without it. `cat` downloads missing bytes by itself. Downloading needs a
    \\remote with an LFS server; `git issue sync` uploads the bytes.
    \\
    \\Options:
    \\   -m, --message <text>  Comment text (add) or commit message (rm, rename)
    \\   --name <name>         Display name instead of the file name (add, one file)
    \\   --remote <remote>     Fetch from this remote (default: every remote)
    \\   --json                JSON array of attachments (ls; docs/json.md)
    \\   -h, --help            Show this help
    \\
;

const Sub = enum { add, ls, cat, rename, rm, fetch };

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    if (argv.len == 0) return common.missing(ctx.err, "attach", "subcommand is required");
    if (common.isHelp(argv[0])) {
        ctx.out.writeAll(help) catch {};
        return common.exit_ok;
    }
    const sub = std.meta.stringToEnum(Sub, argv[0]) orelse {
        ctx.err.print("error: unknown attach subcommand '{s}'\n", .{argv[0]}) catch {};
        return common.exit_error;
    };
    var words: std.ArrayList([]const u8) = .empty;
    var paragraphs: std.ArrayList([]const u8) = .empty;
    var name: ?[]const u8 = null;
    var remote: ?[]const u8 = null;
    var as_json = false;
    var args: common.Args = .{ .list = argv[1..] };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            if (args.was_separator) continue;
            words.append(arena, arg) catch return common.oom(ctx.err);
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            const v = args.value(ctx.err, "-m") orelse return common.exit_error;
            paragraphs.append(arena, v) catch return common.oom(ctx.err);
        } else if (std.mem.eql(u8, arg, "--name")) {
            name = args.value(ctx.err, arg) orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "--remote")) {
            remote = args.value(ctx.err, arg) orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
        } else return common.unknownOption(ctx.err, "attach", arg);
    }
    const w = words.items;
    if (as_json and sub != .ls) return common.missing(ctx.err, "attach", "--json goes with ls");
    if (remote != null and sub != .fetch and sub != .cat)
        return common.missing(ctx.err, "attach", "--remote goes with fetch and cat");
    if (sub == .fetch) {
        if (w.len > 1) return common.missing(ctx.err, "attach", "too many arguments");
        return fetchCmd(B, ctx, if (w.len == 1) w[0] else null, remote);
    }
    const need: usize = switch (sub) {
        .fetch => unreachable,
        .ls => 1,
        .add, .cat, .rm => 2,
        .rename => 3,
    };
    if (w.len < need) return common.missing(ctx.err, "attach", switch (sub) {
        .fetch => unreachable,
        .ls => "issue ID is required",
        .add => "issue ID and at least one file are required",
        .cat, .rm => "issue ID and attachment ID are required",
        .rename => "issue ID, attachment ID and new name are required",
    });
    if ((sub == .ls or sub == .cat or sub == .rename) and w.len > need)
        return common.missing(ctx.err, "attach", "too many arguments");
    if (name != null and (sub != .add or w.len != 2))
        return common.missing(ctx.err, "attach", "--name goes with 'add' and one file");
    if (paragraphs.items.len > 0 and (sub == .ls or sub == .cat))
        return common.missing(ctx.err, "attach", "-m goes with add, rm and rename");
    const text: ?[]const u8 = if (paragraphs.items.len == 0)
        null
    else
        std.mem.join(arena, "\n\n", paragraphs.items) catch return common.oom(ctx.err);
    if (text) |t| if (std.mem.trim(u8, t, " \t\r\n").len == 0)
        return common.missing(ctx.err, "attach", "message is empty");

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const att = issuez.Attachments(B).fromRepo(repo);
    att.ready(arena) catch |e| return common.repoFailed(B, ctx, e);
    const ref = common.resolveOne(B, repo, arena, ctx.err, w[0]) orelse
        return common.exit_error;
    const short = uuid.shortId(ref.id());
    switch (sub) {
        .add => {
            const inputs = readInputs(B, ctx, att, w[1..], name) orelse return common.exit_error;
            const added = att.add(arena, ref.name, .{
                .files = inputs,
                .comment = text,
            }) catch |e| return common.repoFailed(B, ctx, e);
            for (added.ids) |id| {
                ctx.out.print("Attached {s} to {s}\n", .{ uuid.shortId(id), short }) catch {};
            }
        },
        .ls => {
            const issue = repo.load(arena, ref) catch |e| return common.repoFailed(B, ctx, e);
            const entries = att.list(arena, issue) catch |e| return common.repoFailed(B, ctx, e);
            if (as_json) {
                var s = json.begin(ctx.out);
                s.beginArray() catch return common.exit_error;
                for (entries) |e| json.attachment(&s, e.attachment, @tagName(e.availability)) catch
                    return common.exit_error;
                s.endArray() catch return common.exit_error;
                json.end(&s);
                return common.exit_ok;
            }
            for (entries) |e| {
                const a = e.attachment;
                ctx.out.print("{s}  {s:<10}  {f}  {s}", .{
                    uuid.shortId(a.id),
                    a.media.mediaType(),
                    Size{ .bytes = a.size },
                    a.name,
                }) catch {};
                switch (e.availability) {
                    .local => {},
                    .missing => ctx.out.writeAll("  (bytes not here)") catch {},
                    .corrupt => ctx.out.writeAll("  (bytes damaged)") catch {},
                }
                ctx.out.writeAll("\n") catch {};
            }
        },
        .cat => {
            const issue = repo.load(arena, ref) catch |e| return common.repoFailed(B, ctx, e);
            const a = findOne(B, ctx, issue, w[1]) orelse return common.exit_error;
            var content = att.read(arena, a) catch |e| return common.repoFailed(B, ctx, e);
            if (content != .bytes) {
                fetchQuietly(B, ctx, att, issue, remote);
                content = att.read(arena, a) catch |e| return common.repoFailed(B, ctx, e);
            }
            switch (content) {
                .bytes => |b| ctx.out.writeAll(b) catch return common.exit_error,
                .missing => {
                    ctx.err.print(
                        "error: the bytes of {s} aren't in this repository and couldn't be\n" ++
                            "       fetched (see 'git issue attach fetch' for why)\n",
                        .{uuid.shortId(a.id)},
                    ) catch {};
                    return common.exit_error;
                },
                .corrupt => {
                    ctx.err.print(
                        "error: the stored bytes of {s} don't match its hash " ++
                            "(run 'git issue fsck')\n",
                        .{uuid.shortId(a.id)},
                    ) catch {};
                    return common.exit_error;
                },
            }
        },
        .rename => {
            const issue = repo.load(arena, ref) catch |e| return common.repoFailed(B, ctx, e);
            const a = findOne(B, ctx, issue, w[1]) orelse return common.exit_error;
            _ = att.rename(arena, ref.name, a.id, w[2], .{ .message = text }) catch |e|
                return common.repoFailed(B, ctx, e);
            ctx.out.print("Renamed {s} on {s}\n", .{ uuid.shortId(a.id), short }) catch {};
        },
        .fetch => unreachable,
        .rm => {
            const issue = repo.load(arena, ref) catch |e| return common.repoFailed(B, ctx, e);
            var ids: std.ArrayList([]const u8) = .empty;
            for (w[1..]) |p| {
                const a = findOne(B, ctx, issue, p) orelse return common.exit_error;
                ids.append(arena, a.id) catch return common.oom(ctx.err);
            }
            _ = att.remove(arena, ref.name, ids.items, .{ .message = text }) catch |e|
                return common.repoFailed(B, ctx, e);
            for (ids.items) |id| {
                ctx.out.print("Removed {s} from {s}\n", .{ uuid.shortId(id), short }) catch {};
            }
        },
    }
    return common.exit_ok;
}

fn fetchCmd(
    comptime B: type,
    ctx: *context.Context(B),
    prefix: ?[]const u8,
    remote: ?[]const u8,
) u8 {
    const arena = ctx.arena;
    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const att = issuez.Attachments(B).fromRepo(repo);
    att.ready(arena) catch |e| return common.repoFailed(B, ctx, e);
    var issues: std.ArrayList(issuez.engine.Issue) = .empty;
    if (prefix) |p| {
        const ref = common.resolveOne(B, repo, arena, ctx.err, p) orelse
            return common.exit_error;
        const issue = repo.load(arena, ref) catch |e| return common.repoFailed(B, ctx, e);
        issues.append(arena, issue) catch return common.oom(ctx.err);
    } else {
        const all = repo.loadAll(arena) catch |e| return common.repoFailed(B, ctx, e);
        issues.appendSlice(arena, all) catch return common.oom(ctx.err);
    }
    const remotes = remotesFor(B, ctx, att, remote) orelse return common.exit_error;
    var total: usize = 0;
    // Unknown until one remote answers.
    var missing: ?usize = null;
    for (remotes) |r| {
        const report = att.fetch(arena, r, issues.items) catch |e| {
            ctx.err.print("error: fetching from '{s}': ", .{r}) catch {};
            common.reportRepoError(B, ctx, e);
            continue;
        };
        if (report.transfer_failed) {
            ctx.err.print("warning: git-lfs failed for some objects from '{s}':\n", .{r}) catch {};
            printBackendDetail(B, ctx);
        }
        total += report.fetched;
        missing = report.missing.len;
        if (report.missing.len == 0) break;
        // Only what is still missing goes to the next remote.
    }
    ctx.out.print("Fetched {d} attachment(s).\n", .{total}) catch {};
    const left = missing orelse {
        ctx.err.writeAll("error: no remote could be asked for the bytes\n") catch {};
        return common.exit_error;
    };
    if (left > 0) {
        ctx.err.print("error: {d} attachment(s) are still missing\n", .{left}) catch {};
        return common.exit_error;
    }
    return common.exit_ok;
}

/// `--remote`, or every configured remote that sync could use too.
fn remotesFor(
    comptime B: type,
    ctx: *context.Context(B),
    att: issuez.Attachments(B),
    remote: ?[]const u8,
) ?[]const []const u8 {
    const arena = ctx.arena;
    const valid = issuez.backend.contract.isValidRemoteName;
    if (remote) |r| {
        if (!valid(r)) {
            ctx.err.print("error: invalid remote name '{s}'\n", .{r}) catch {};
            return null;
        }
        const one = arena.alloc([]const u8, 1) catch return null;
        one[0] = r;
        return one;
    }
    const names = att.repo.backend.remoteNames(arena) catch |e| {
        common.reportRepoError(B, ctx, e);
        return null;
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |n| {
        if (valid(n)) {
            out.append(arena, n) catch return null;
        } else ctx.err.print("note: skipping remote '{s}' (name not supported)\n", .{n}) catch {};
    }
    if (out.items.len == 0) {
        ctx.err.writeAll("error: no remote to fetch attachment bytes from\n") catch {};
        return null;
    }
    return out.items;
}

fn printBackendDetail(comptime B: type, ctx: *context.Context(B)) void {
    if (!@hasDecl(B, "lastStderr")) return;
    const backend = ctx.backend catch return;
    const detail = std.mem.trim(u8, backend.lastStderr(), " \t\r\n");
    var lines = std.mem.splitScalar(u8, detail, '\n');
    while (lines.next()) |line| if (line.len > 0)
        ctx.err.print("       git: {s}\n", .{line}) catch {};
}

/// Errors only matter if the bytes are still missing afterwards.
fn fetchQuietly(
    comptime B: type,
    ctx: *context.Context(B),
    att: issuez.Attachments(B),
    issue: issuez.engine.Issue,
    remote: ?[]const u8,
) void {
    const remotes = remotesFor(B, ctx, att, remote) orelse return;
    for (remotes) |r| {
        const report = att.fetch(ctx.arena, r, &.{issue}) catch continue;
        if (report.missing.len == 0) return;
    }
}

/// Reads and checks the files for `add` and `comment --attach`. Prints
/// the problem and returns null on the first bad one.
pub fn readInputs(
    comptime B: type,
    ctx: *context.Context(B),
    att: issuez.Attachments(B),
    paths: []const []const u8,
    name: ?[]const u8,
) ?[]const issuez.Attachments(B).Input {
    var inputs: std.ArrayList(issuez.Attachments(B).Input) = .empty;
    for (paths) |path| {
        const data = ctx.readFile(path, att.repo.limits.max_attachment_bytes) catch |e| {
            ctx.err.print("error: cannot read '{s}': {s}\n", .{ path, switch (e) {
                error.FileNotFound => "no such file",
                error.FileTooLarge => "larger than the attachment limit",
                error.OutOfMemory => "out of memory",
                error.ReadFailed => "read failed",
            } }) catch {};
            return null;
        };
        const input: issuez.Attachments(B).Input = .{ .name = name orelse path, .data = data };
        _ = att.validate(input) catch |e| {
            ctx.err.print("error: '{s}': ", .{path}) catch {};
            common.reportRepoError(B, ctx, e);
            return null;
        };
        inputs.append(ctx.arena, input) catch {
            _ = common.oom(ctx.err);
            return null;
        };
    }
    return inputs.items;
}

pub const Size = struct {
    bytes: u64,

    pub fn format(s: Size, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (s.bytes < 1024) return w.print("{d} B", .{s.bytes});
        const kib = @as(f64, @floatFromInt(s.bytes)) / 1024.0;
        if (kib < 1024) return w.print("{d:.1} KiB", .{kib});
        return w.print("{d:.1} MiB", .{kib / 1024.0});
    }
};

fn findOne(
    comptime B: type,
    ctx: *context.Context(B),
    issue: issuez.engine.Issue,
    prefix: []const u8,
) ?issuez.model.issue.Attachment {
    const A = issuez.Attachments(B);
    if (prefix.len < 4) {
        ctx.err.writeAll("error: an attachment ID needs at least 4 characters\n") catch {};
        return null;
    }
    switch (A.find(ctx.arena, issue, prefix) catch return null) {
        .one => |a| return a,
        .none => ctx.err.print(
            "error: no attachment '{s}' on this issue (see 'git issue attach ls')\n",
            .{prefix},
        ) catch {},
        .many => ctx.err.print("error: ambiguous attachment ID '{s}'\n", .{prefix}) catch {},
    }
    return null;
}

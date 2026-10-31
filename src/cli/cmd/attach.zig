//! `git issue attach <subcommand> <issue-id> ...`, see docs/attachments.md.

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const issuez = @import("issuez");
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
    \\`cat` downloads missing bytes by itself. Downloading needs git-lfs and a
    \\remote with an LFS server; `git issue sync` uploads the bytes.
    \\
    \\Options:
    \\   -m, --message <text>  Comment text (add) or commit message (rm, rename)
    \\   --name <name>         Display name instead of the file name (add, one file)
    \\   --remote <remote>     Fetch from this remote (default: every remote)
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
        } else return common.unknownOption(ctx.err, "attach", arg);
    }
    const w = words.items;
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

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const att = issuez.Attachments(B).fromRepo(repo);
    const ref = common.resolveOne(B, repo, arena, ctx.err, w[0]) orelse
        return common.exit_error;
    const short = uuid.shortId(ref.id());
    switch (sub) {
        .add => {
            var inputs: std.ArrayList(issuez.Attachments(B).Input) = .empty;
            for (w[1..]) |path| {
                const limit = repo.limits.max_attachment_bytes;
                const data = ctx.readFile(path, limit) catch |e| {
                    ctx.err.print("error: cannot read '{s}': {s}\n", .{ path, switch (e) {
                        error.FileNotFound => "no such file",
                        error.FileTooLarge => "larger than the attachment limit",
                        error.OutOfMemory => "out of memory",
                        error.ReadFailed => "read failed",
                    } }) catch {};
                    return common.exit_error;
                };
                const input: issuez.Attachments(B).Input = .{
                    .name = name orelse path,
                    .data = data,
                };
                _ = att.validate(input) catch |e| {
                    ctx.err.print("error: '{s}': ", .{path}) catch {};
                    common.reportRepoError(B, ctx, e);
                    return common.exit_error;
                };
                inputs.append(arena, input) catch return common.oom(ctx.err);
            }
            const added = att.add(arena, ref.name, .{
                .files = inputs.items,
                .comment = text,
            }) catch |e| return common.repoFailed(B, ctx, e);
            for (added.ids) |id| {
                ctx.out.print("Attached {s} to {s}\n", .{ uuid.shortId(id), short }) catch {};
            }
        },
        .ls => {
            const issue = repo.load(arena, ref) catch |e| return common.repoFailed(B, ctx, e);
            const entries = att.list(arena, issue) catch |e| return common.repoFailed(B, ctx, e);
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
            if (content == .missing) {
                fetchQuietly(B, ctx, att, issue, remote);
                content = att.read(arena, a) catch |e| return common.repoFailed(B, ctx, e);
            }
            switch (content) {
                .bytes => |b| ctx.out.writeAll(b) catch return common.exit_error,
                .missing => {
                    ctx.err.print(
                        "error: the bytes of {s} aren't in this repository, and no remote's\n" ++
                            "       LFS server had them (needs git-lfs; see " ++
                            "'git issue attach fetch')\n",
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
    const remotes = remotesFor(B, att, arena, remote) orelse return common.exit_error;
    if (remotes.len == 0) {
        ctx.err.writeAll("error: no remote to fetch attachment bytes from\n") catch {};
        return common.exit_error;
    }
    var total: usize = 0;
    var missing: usize = 0;
    for (remotes) |r| {
        const report = att.fetch(arena, r, issues.items) catch |e| {
            common.reportRepoError(B, ctx, e);
            if (e == error.LfsUnavailable) return common.exit_error;
            continue;
        };
        total += report.fetched;
        missing = report.missing.len;
        if (missing == 0) break;
    }
    ctx.out.print("Fetched {d} attachment(s).\n", .{total}) catch {};
    if (missing > 0) {
        ctx.err.print("warning: {d} attachment(s) are still missing\n", .{missing}) catch {};
        return common.exit_error;
    }
    return common.exit_ok;
}

fn remotesFor(
    comptime B: type,
    att: issuez.Attachments(B),
    arena: std.mem.Allocator,
    remote: ?[]const u8,
) ?[]const []const u8 {
    if (remote) |r| {
        const one = arena.alloc([]const u8, 1) catch return null;
        one[0] = r;
        return one;
    }
    return att.repo.backend.remoteNames(arena) catch null;
}

/// Errors only matter if the bytes are still missing afterwards.
fn fetchQuietly(
    comptime B: type,
    ctx: *context.Context(B),
    att: issuez.Attachments(B),
    issue: issuez.engine.Issue,
    remote: ?[]const u8,
) void {
    const remotes = remotesFor(B, att, ctx.arena, remote) orelse return;
    for (remotes) |r| {
        const report = att.fetch(ctx.arena, r, &.{issue}) catch continue;
        if (report.missing.len == 0) return;
    }
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

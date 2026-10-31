//! `git issue comment <issue-id> -m <text>`
//! `git issue comment <issue-id> --edit <comment-id> -m <text>`
//! `git issue comment <issue-id> --delete | --restore <comment-id>`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const issuez = @import("issuez");
const uuid = issuez.format.uuid;

pub const help =
    \\usage: git issue comment <issue-id> -m <text>
    \\
    \\Add a comment to an issue, or edit, delete or restore one of its
    \\comments. Comment IDs are shown by `git issue show --ids`; a unique
    \\prefix of at least 4 characters is enough. Edits and deletions are new
    \\commits: nothing is rewritten, and a restore brings a comment back.
    \\
    \\Options:
    \\   -m, --message <text>       Comment text; repeat for more paragraphs
    \\   --edit <comment-id>        Replace a comment's text with -m
    \\   --delete <comment-id>      Hide a comment
    \\   --restore <comment-id>     Show a deleted comment again
    \\   --attach <file>            Attach an image with the comment (repeatable)
    \\   -h, --help                 Show this help
    \\
;

const Action = enum { add, edit, delete, restore };

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var issue_prefix: ?[]const u8 = null;
    var paragraphs: std.ArrayList([]const u8) = .empty;
    var action: Action = .add;
    var target: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;

    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            if (args.was_separator) continue;
            if (issue_prefix == null) issue_prefix = arg;
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            const v = args.value(ctx.err, "-m") orelse return common.exit_error;
            paragraphs.append(arena, v) catch return common.oom(ctx.err);
        } else if (std.mem.eql(u8, arg, "--attach")) {
            const v = args.value(ctx.err, arg) orelse return common.exit_error;
            files.append(arena, v) catch return common.oom(ctx.err);
        } else if (std.meta.stringToEnum(Action, if (arg.len > 2) arg[2..] else "")) |a| {
            if (a == .add or !std.mem.startsWith(u8, arg, "--")) {
                return common.unknownOption(ctx.err, "comment", arg);
            }
            if (action != .add) return common.missing(
                ctx.err,
                "comment",
                "only one of --edit, --delete, --restore",
            );
            action = a;
            target = args.value(ctx.err, arg) orelse return common.exit_error;
        } else {
            return common.unknownOption(ctx.err, "comment", arg);
        }
    }
    const prefix = issue_prefix orelse return common.missing(
        ctx.err,
        "comment",
        "issue ID is required",
    );
    if (files.items.len > 0 and action != .add) return common.missing(
        ctx.err,
        "comment",
        "--attach goes with a new comment",
    );
    const needs_text = action == .add or action == .edit;
    if (needs_text and paragraphs.items.len == 0) return common.missing(
        ctx.err,
        "comment",
        "comment message is required (-m)",
    );
    if (!needs_text and paragraphs.items.len > 0) return common.missing(
        ctx.err,
        "comment",
        "-m doesn't go with --delete or --restore",
    );
    const text = std.mem.join(arena, "\n\n", paragraphs.items) catch return common.oom(ctx.err);
    if (needs_text and std.mem.trim(u8, text, " \t\r\n").len == 0) return common.missing(
        ctx.err,
        "comment",
        "comment message is empty",
    );

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const ref = common.resolveOne(
        B,
        repo,
        arena,
        ctx.err,
        prefix,
    ) orelse return common.exit_error;
    const short = uuid.shortId(ref.id());
    if (action == .add and files.items.len > 0) {
        const A = issuez.Attachments(B);
        const att = A.fromRepo(repo);
        var inputs: std.ArrayList(A.Input) = .empty;
        for (files.items) |path| {
            const data = ctx.readFile(path, repo.limits.max_attachment_bytes) catch {
                ctx.err.print(
                    "error: cannot read '{s}' (missing, unreadable or too large)\n",
                    .{path},
                ) catch {};
                return common.exit_error;
            };
            const input: A.Input = .{ .name = path, .data = data };
            _ = att.validate(input) catch |e| {
                ctx.err.print("error: '{s}': ", .{path}) catch {};
                common.reportRepoError(B, ctx, e);
                return common.exit_error;
            };
            inputs.append(arena, input) catch return common.oom(ctx.err);
        }
        _ = att.add(arena, ref.name, .{ .files = inputs.items, .comment = text }) catch |e|
            return common.repoFailed(B, ctx, e);
        ctx.out.print("Added comment to {s}\n", .{short}) catch {};
        return common.exit_ok;
    }
    if (action == .add) {
        _ = repo.comment(arena, ref.name, .{ .text = text }) catch |e|
            return common.repoFailed(B, ctx, e);
        ctx.out.print("Added comment to {s}\n", .{short}) catch {};
        return common.exit_ok;
    }

    const issue = repo.load(arena, ref) catch |e| return common.repoFailed(B, ctx, e);
    const comment = resolveComment(ctx, issue, target.?) orelse return common.exit_error;
    const event: issuez.engine.Repo(B).CommentEvent = switch (action) {
        .edit => .edit,
        .delete => .delete,
        .restore => .restore,
        .add => unreachable,
    };
    _ = repo.commentEvent(arena, ref.name, comment.oid, event, text, .{}) catch |e|
        return common.repoFailed(B, ctx, e);
    const hex = comment.oid.hex();
    const verb = switch (action) {
        .edit => "Edited",
        .delete => "Deleted",
        .restore => "Restored",
        .add => unreachable,
    };
    ctx.out.print("{s} comment {s} on {s}\n", .{ verb, hex.short(), short }) catch {};
    return common.exit_ok;
}

/// The comment whose ID starts with `prefix` (at least 4 hex characters).
fn resolveComment(
    ctx: anytype,
    issue: issuez.engine.Issue,
    prefix: []const u8,
) ?issuez.model.issue.Comment {
    if (prefix.len < 4) {
        ctx.err.writeAll("error: a comment ID needs at least 4 characters\n") catch {};
        return null;
    }
    var found: ?issuez.model.issue.Comment = null;
    for (issue.comments) |c| {
        if (c.is_merge) continue;
        const hex = c.oid.hex();
        if (!std.mem.startsWith(u8, hex.slice(), prefix)) continue;
        if (found != null) {
            ctx.err.print("error: ambiguous comment ID '{s}'\n", .{prefix}) catch {};
            return null;
        }
        found = c;
    }
    return found orelse {
        ctx.err.print(
            "error: no comment '{s}' on this issue (see 'git issue show --ids')\n",
            .{prefix},
        ) catch {};
        return null;
    };
}

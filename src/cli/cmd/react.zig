//! `git issue react <issue-id> <emoji> [--on <comment-id>] [--undo]`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const issuez = @import("issuez");
const uuid = issuez.format.uuid;

pub const help =
    \\usage: git issue react <issue-id> <emoji> [options]
    \\
    \\Add your reaction to an issue or one of its comments, or take it back.
    \\The emoji is a name like :+1: or the character itself. Reacting the
    \\same way twice writes nothing.
    \\
    \\Options:
    \\   --on <comment-id>      React to this comment (see show --ids)
    \\   --undo                 Take the reaction back
    \\   -h, --help             Show this help
    \\
;

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var words: std.ArrayList([]const u8) = .empty;
    var on: ?[]const u8 = null;
    var undo = false;
    if (common.parseArgs(ctx, argv, .{
        .command = "react",
        .help = help,
        .positionals = .{ .words = &words },
        .flags = &.{
            .{ "--on", .{ .text = &on } },
            .{ "--undo", .{ .on = &undo } },
        },
    })) |exit| return exit;
    if (words.items.len < 1) return common.missing(ctx.err, "react", "issue ID is required");
    if (words.items.len < 2) return common.missing(ctx.err, "react", "an emoji is required");
    const prefix = words.items[0];
    const e = words.items[1];
    if (!issuez.format.fields.isEmoji(e)) return common.fail(
        ctx.err,
        "error: an emoji is 1 to 64 bytes without whitespace or commas\n",
    );

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const ref = common.resolveOne(B, repo, arena, ctx.err, prefix) orelse return common.exit_error;
    var target: ?issuez.engine.Oid = null;
    if (on) |c| {
        const issue = repo.load(arena, ref) catch |err| return common.repoFailed(B, ctx, err);
        target = common.findCommentOid(ctx.err, issue, c) orelse return common.exit_error;
    }
    const tip = repo.react(
        arena,
        ref.name,
        .{ .target = target, .emoji = e, .present = !undo },
        .{},
    ) catch |err|
        return common.repoFailed(B, ctx, err);
    const short = uuid.shortId(ref.id());
    if (!tip.wrote) {
        ctx.out.print("Nothing to change on {s}\n", .{short}) catch {};
    } else {
        ctx.out.print(
            "{s} {s} on {s}\n",
            .{ if (undo) "Took back" else "Reacted", e, short },
        ) catch {};
    }
    return common.exit_ok;
}

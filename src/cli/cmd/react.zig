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
    var issue_prefix: ?[]const u8 = null;
    var emoji: ?[]const u8 = null;
    var on: ?[]const u8 = null;
    var undo = false;
    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            if (args.was_separator) continue;
            if (issue_prefix == null) {
                issue_prefix = arg;
            } else if (emoji == null) emoji = arg;
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "--on")) {
            on = args.value(ctx.err, arg) orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "--undo")) {
            undo = true;
        } else {
            return common.unknownOption(ctx.err, "react", arg);
        }
    }
    const prefix = issue_prefix orelse return common.missing(
        ctx.err,
        "react",
        "issue ID is required",
    );
    const e = emoji orelse return common.missing(ctx.err, "react", "an emoji is required");
    if (!issuez.format.fields.isEmoji(e)) return common.fail(
        ctx.err,
        "error: an emoji is 1 to 64 bytes without whitespace or commas\n",
    );

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const ref = common.resolveOne(B, repo, arena, ctx.err, prefix) orelse return common.exit_error;
    var target: ?issuez.engine.Oid = null;
    if (on) |c| {
        const issue = repo.load(arena, ref) catch |err| return common.repoFailed(B, ctx, err);
        var found: ?issuez.engine.Oid = null;
        for (issue.comments) |cm| {
            if (cm.is_merge) continue;
            const hex = cm.oid.hex();
            if (!std.mem.startsWith(u8, hex.slice(), c)) continue;
            if (found != null) return common.fail(ctx.err, "error: ambiguous comment ID\n");
            found = cm.oid;
        }
        target = found orelse return common.fail(ctx.err, "error: no such comment on this issue\n");
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

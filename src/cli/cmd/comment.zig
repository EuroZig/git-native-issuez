//! `git issue comment <issue-id> -m <text>`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const issuez = @import("issuez");
const uuid = issuez.format.uuid;

pub const help =
    \\usage: git issue comment <issue-id> -m <text>
    \\
    \\Add a comment to an issue.
    \\
    \\Options:
    \\   -m, --message <text>       Comment text; repeat for more paragraphs
    \\   -h, --help                 Show this help
    \\
;

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var issue_prefix: ?[]const u8 = null;
    var paragraphs: std.ArrayList([]const u8) = .empty;

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
        } else {
            return common.unknownOption(ctx.err, "comment", arg);
        }
    }
    const prefix = issue_prefix orelse return common.missing(
        ctx.err,
        "comment",
        "issue ID is required",
    );
    if (paragraphs.items.len == 0) return common.missing(
        ctx.err,
        "comment",
        "comment message is required (-m)",
    );
    const text = std.mem.join(arena, "\n\n", paragraphs.items) catch return common.oom(ctx.err);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return common.missing(
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
    _ = repo.comment(arena, ref.name, .{ .text = text }) catch |e| return common.repoFailed(B, ctx, e);
    ctx.out.print("Added comment to {s}\n", .{short}) catch {};
    return common.exit_ok;
}

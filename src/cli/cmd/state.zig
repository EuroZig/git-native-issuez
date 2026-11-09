//! `git issue state <issue-id> --open | --close | --state <value> [options]`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const core = @import("issuez").format.core;
const uuid = @import("issuez").format.uuid;

pub const help =
    \\usage: git issue state <issue-id> [options]
    \\
    \\Change the state of an issue.
    \\
    \\Options:
    \\   --open                 Reopen the issue
    \\   --close                Close the issue
    \\   --state <value>        Set a custom state (letters, digits, - and _)
    \\   -m, --message <text>   Message for the state change
    \\   -c, --comment <text>   A comment in the same commit; repeat for paragraphs
    \\   --fixed-by <sha>       Commit that fixes the issue
    \\   --release <version>    Release that ships the fix
    \\   --reason <reason>      Why it was closed (duplicate, wontfix, invalid, completed)
    \\   -h, --help             Show this help
    \\
;

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var issue_prefix: ?[]const u8 = null;
    var new_state: ?[]const u8 = null;
    var message: ?[]const u8 = null;
    var fixed_by: ?[]const u8 = null;
    var release: ?[]const u8 = null;
    var reason: ?[]const u8 = null;
    var comment: std.ArrayList([]const u8) = .empty;

    if (common.parseArgs(ctx, argv, .{
        .command = "state",
        .help = help,
        .positionals = .{ .first = &issue_prefix },
        .flags = &.{
            .{ "--open", .{ .constant = .{ &new_state, "open" } } },
            .{ "--close", .{ .constant = .{ &new_state, "closed" } } },
            .{ "--state", .{ .text = &new_state } },
            .{ "-m --message", .{ .text = &message } },
            .{ "--fixed-by", .{ .text = &fixed_by } },
            .{ "--release", .{ .text = &release } },
            .{ "--reason", .{ .text = &reason } },
            .{ "-c --comment", .{ .list = &comment } },
        },
    })) |exit| return exit;
    const prefix = issue_prefix orelse
        return common.missing(ctx.err, "state", "issue ID is required");
    // Like upstream, an empty `--state ""` counts as no state given.
    if (new_state) |s| if (s.len == 0) {
        new_state = null;
    };
    const state = new_state orelse return common.missing(
        ctx.err,
        "state",
        "state is required (--open, --close, or --state <value>)",
    );
    if (!core.isState(state)) {
        ctx.err.writeAll(
            "error: state must contain only alphanumeric characters, hyphens, or underscores\n",
        ) catch {};
        return common.exit_error;
    }
    for ([_]struct { []const u8, ?[]const u8 }{
        .{ "--fixed-by", fixed_by },
        .{ "--release", release },
        .{ "--reason", reason },
    }) |opt| {
        if (opt[1]) |v| if (common.hasNewline(v)) {
            ctx.err.print("error: {s} value must not contain newlines\n", .{opt[0]}) catch {};
            return common.exit_error;
        };
    }

    var repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    var skipped = false;
    repo.call.skipped = &skipped;
    const ref = common.resolveOne(B, repo, arena, ctx.err, prefix) orelse return common.exit_error;
    const parsed = core.State.parse(state);
    if (comment.items.len > 0) {
        if (message != null) return common.fail(ctx.err, "error: --comment can't go with -m\n");
        const text = std.mem.join(arena, "\n\n", comment.items) catch return common.oom(ctx.err);
        // One commit: the comment is its text, the state change its fields.
        _ = repo.edit(arena, ref.name, .{
            .state = parsed,
            .fixed_by = fixed_by,
            .release = release,
            .reason = reason,
            .comment = text,
        }, .{}) catch |e| return common.repoFailed(B, ctx, e);
    } else _ = repo.setState(arena, ref.name, .{
        .state = parsed,
        .message = message,
        .fixed_by = fixed_by,
        .release = release,
        .reason = reason,
    }, .{}) catch |e| return common.repoFailed(B, ctx, e);
    const short = uuid.shortId(ref.id());
    if (skipped) {
        ctx.out.print("Issue {s} is already {s}\n", .{ short, parsed.text() }) catch {};
        return common.exit_ok;
    }
    switch (parsed) {
        .open => ctx.out.print("Reopened issue {s}\n", .{short}) catch {},
        .closed => ctx.out.print("Closed issue {s}\n", .{short}) catch {},
        .other => |s| ctx.out.print("Changed state of {s} to {s}\n", .{ short, s }) catch {},
    }
    return common.exit_ok;
}

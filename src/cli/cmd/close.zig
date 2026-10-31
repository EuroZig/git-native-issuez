//! `git issue close` and `git issue reopen`: `state --close` / `--open`.

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const cmd_state = @import("state.zig");

pub const close_help =
    \\usage: git issue close <issue-id> [options]
    \\
    \\Close an issue (the same as `git issue state <issue-id> --close`).
    \\
    \\Options:
    \\   -m, --message <text>   Message for the state change
    \\   --fixed-by <sha>       Commit that fixes the issue
    \\   --release <version>    Release that ships the fix
    \\   --reason <reason>      Why it was closed (duplicate, wontfix, invalid, completed)
    \\   -h, --help             Show this help
    \\
;

pub const reopen_help =
    \\usage: git issue reopen <issue-id> [options]
    \\
    \\Reopen an issue (the same as `git issue state <issue-id> --open`).
    \\
    \\Options:
    \\   -m, --message <text>   Message for the state change
    \\   -h, --help             Show this help
    \\
;

pub fn main(
    comptime B: type,
    ctx: *context.Context(B),
    argv: []const []const u8,
    close: bool,
) u8 {
    for (argv) |a| if (common.isHelp(a)) {
        ctx.out.writeAll(if (close) close_help else reopen_help) catch {};
        return common.exit_ok;
    };
    var args: std.ArrayList([]const u8) = .empty;
    args.appendSlice(ctx.arena, argv) catch return common.oom(ctx.err);
    args.append(ctx.arena, if (close) "--close" else "--open") catch return common.oom(ctx.err);
    return cmd_state.main(B, ctx, args.items);
}

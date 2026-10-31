//! `git issue delete <issue-id> [-m <text>]`
//! `git issue restore <issue-id> [-m <text>]`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const issuez = @import("issuez");
const uuid = issuez.format.uuid;

pub const delete_help =
    \\usage: git issue delete <issue-id> [options]
    \\
    \\Delete an issue: it disappears from ls, tree and search, and
    \\`git issue restore` brings it back. Nothing is removed from history.
    \\An issue with sub-issues that aren't deleted can't be deleted.
    \\
    \\Options:
    \\   -m, --message <text>   Message for the deletion
    \\   -h, --help             Show this help
    \\
;

pub const restore_help =
    \\usage: git issue restore <issue-id> [options]
    \\
    \\Restore a deleted issue (see `git issue ls --deleted`).
    \\
    \\Options:
    \\   -m, --message <text>   Message for the restore
    \\   -h, --help             Show this help
    \\
;

pub fn main(
    comptime B: type,
    ctx: *context.Context(B),
    argv: []const []const u8,
    deleted: bool,
) u8 {
    const name = if (deleted) "delete" else "restore";
    var prefix: ?[]const u8 = null;
    var message: ?[]const u8 = null;
    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            if (args.was_separator) continue;
            if (prefix == null) prefix = arg;
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(if (deleted) delete_help else restore_help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            message = args.value(ctx.err, "-m") orelse return common.exit_error;
        } else {
            return common.unknownOption(ctx.err, name, arg);
        }
    }
    const p = prefix orelse return common.missing(ctx.err, name, "issue ID is required");
    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const ref = common.resolveOne(B, repo, ctx.arena, ctx.err, p) orelse
        return common.exit_error;
    const issue = repo.load(ctx.arena, ref) catch |e| return common.repoFailed(B, ctx, e);
    const short = uuid.shortId(ref.id());
    if (issue.deleted == deleted) {
        ctx.out.print("Issue {s} is already {s}\n", .{
            short,
            if (deleted) "deleted" else "not deleted",
        }) catch {};
        return common.exit_ok;
    }
    _ = repo.setDeleted(ctx.arena, ref.name, deleted, .{ .message = message }) catch |e|
        return common.repoFailed(B, ctx, e);
    ctx.out.print("{s} issue {s}\n", .{ if (deleted) "Deleted" else "Restored", short }) catch {};
    return common.exit_ok;
}

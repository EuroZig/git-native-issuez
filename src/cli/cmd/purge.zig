//! `git issue purge <issue-id> [--comment <comment-id>] --yes`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const issuez = @import("issuez");
const uuid = issuez.format.uuid;

pub const help =
    \\usage: git issue purge <issue-id> [options] --yes
    \\
    \\Remove an issue, or one comment's text and images, from history for
    \\good: for abuse or a legal request. Unlike delete, nothing can bring
    \\it back. A comment's later commits are rewritten; its fields stay. A
    \\tombstone records the purge, and sync takes it to the remote and to
    \\every clone, which purge the same way.
    \\
    \\Options:
    \\   --comment <id>         Purge this comment only (see show --ids)
    \\   --reason <text>        Why, recorded in the tombstone
    \\   -y, --yes              Confirm: purging can't be undone
    \\   -h, --help             Show this help
    \\
;

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var prefix: ?[]const u8 = null;
    var comment: ?[]const u8 = null;
    var reason: ?[]const u8 = null;
    var yes = false;
    if (common.parseArgs(ctx, argv, .{
        .command = "purge",
        .help = help,
        .positionals = .{ .first = &prefix },
        .flags = &.{
            .{ "--comment", .{ .text = &comment } },
            .{ "--reason", .{ .text = &reason } },
            .{ "-y --yes", .{ .on = &yes } },
        },
    })) |exit| return exit;
    const p = prefix orelse return common.missing(ctx.err, "purge", "issue ID is required");
    if (!yes) return common.fail(
        ctx.err,
        "error: purging can't be undone; pass --yes to confirm\n",
    );

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const ref = common.resolveOne(B, repo, arena, ctx.err, p) orelse return common.exit_error;
    const purge = issuez.purge.Purge(B).fromRepo(repo);
    const short = uuid.shortId(ref.id());
    const spec: issuez.purge.Spec = .{ .reason = reason orelse "" };
    if (comment) |c| {
        const issue = repo.load(arena, ref) catch |err| return common.repoFailed(B, ctx, err);
        const oid = common.findCommentOid(ctx.err, issue, c) orelse return common.exit_error;
        const r = purge.comment(arena, ref.name, oid, spec, .{}) catch |err|
            return common.repoFailed(B, ctx, err);
        ctx.out.print("Purged a comment of {s}, {d} commits rewritten\n", .{
            short,
            r.moved.len,
        }) catch {};
    } else {
        _ = purge.issue(
            arena,
            ref.name,
            spec,
            .{},
        ) catch |err| return common.repoFailed(B, ctx, err);
        ctx.out.print("Purged issue {s}\n", .{short}) catch {};
    }
    return common.exit_ok;
}

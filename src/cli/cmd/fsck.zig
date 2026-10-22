//! `git issue fsck [--quiet]`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const issuez = @import("issuez");
const uuid = issuez.format.uuid;

pub const help =
    \\usage: git issue fsck [options]
    \\
    \\Check every issue for data integrity:
    \\   - ref names are UUIDs
    \\   - every commit uses the empty tree
    \\   - one root commit, carrying State: and Format-Version: trailers
    \\   - the whole history is readable
    \\
    \\Options:
    \\   -q, --quiet  Only report problems
    \\   -h, --help   Show this help
    \\
;

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var quiet = false;
    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        } else {
            return common.unknownOption(ctx.err, "fsck", arg);
        }
    }

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const refs = repo.refs(arena) catch |e| return common.repoFailed(B, ctx, e);
    if (refs.len == 0) {
        ctx.out.writeAll("No issues found.\n") catch {};
        return common.exit_ok;
    }

    var errors: usize = 0;
    for (refs) |ref| {
        const short = uuid.shortId(ref.id());
        const problems = repo.check(arena, ref) catch return common.oom(ctx.err);
        for (problems) |p| {
            errors += 1;
            switch (p) {
                .invalid_uuid => ctx.err.print(
                    "error: {s}: invalid UUID format: {s}\n",
                    .{ short, ref.id() },
                ) catch {},
                .non_empty_tree => |oid| ctx.err.print(
                    "error: {s}: commit {s} does not use empty tree\n",
                    .{ short, oid.hex().short() },
                ) catch {},
                .root_count => |n| ctx.err.print(
                    "error: {s}: expected 1 root commit, found {d}\n",
                    .{ short, n },
                ) catch {},
                .missing_state => ctx.err.print(
                    "error: {s}: root commit missing State: trailer\n",
                    .{short},
                ) catch {},
                .missing_format_version => ctx.err.print(
                    "error: {s}: root commit missing Format-Version: trailer\n",
                    .{short},
                ) catch {},
                .unreadable => |e| ctx.err.print(
                    "error: {s}: history unreadable ({t})\n",
                    .{ short, e },
                ) catch {},
            }
        }
        if (problems.len == 0 and !quiet) ctx.out.print("ok {s}\n", .{short}) catch {};
    }
    if (errors == 0) {
        ctx.out.print("Checked {d} issues, no errors found.\n", .{refs.len}) catch {};
        return common.exit_ok;
    }
    ctx.err.print("Checked {d} issues, {d} errors found.\n", .{ refs.len, errors }) catch {};
    return common.exit_error;
}

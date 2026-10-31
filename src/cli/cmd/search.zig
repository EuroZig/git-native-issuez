//! `git issue search <pattern> [options]`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const issuez = @import("issuez");
const uuid = issuez.format.uuid;

pub const help =
    \\usage: git issue search <pattern> [options]
    \\
    \\Search issue titles, descriptions and comments for a fixed string.
    \\
    \\Options:
    \\   -s, --state <state>   open, closed, any custom state, or all [default: all]
    \\   -i, --ignore-case     Case-insensitive search
    \\   -h, --help            Show this help
    \\
;

const max_shown = 5;

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var pattern: ?[]const u8 = null;
    var state_filter: []const u8 = "all";
    var ignore_case = false;

    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            if (args.was_separator) continue;
            if (pattern == null) pattern = arg;
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--state")) {
            state_filter = args.value(ctx.err, "-s") orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
            ignore_case = true;
        } else {
            return common.unknownOption(ctx.err, "search", arg);
        }
    }
    const needle = pattern orelse return common.missing(
        ctx.err,
        "search",
        "search pattern is required",
    );
    if (needle.len == 0) return common.missing(ctx.err, "search", "search pattern is required");

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const issues = repo.loadAll(arena) catch |e| return common.repoFailed(B, ctx, e);
    if (issues.len == 0) {
        ctx.out.writeAll("No issues found.\n") catch {};
        return common.exit_ok;
    }

    for (issues) |issue| {
        if (issue.deleted) continue;
        if (!std.mem.eql(u8, state_filter, "all") and !std.mem.eql(
            u8,
            issue.state,
            state_filter,
        )) continue;
        const lines = issuez.query.searchLines(arena, issue, needle, .{
            .ignore_case = ignore_case,
        }) catch return common.oom(ctx.err);
        if (lines.len == 0) continue;
        ctx.out.print(
            "{s} [{s}] {s}\n",
            .{ uuid.shortId(issue.id), issue.state, issue.title },
        ) catch {};
        for (lines[0..@min(lines.len, max_shown)], 1..) |line, n| {
            ctx.out.print("       {d}:{s}\n", .{ n, line }) catch {};
        }
        const shown = lines.len;
        if (shown > max_shown) ctx.out.print(
            "       ... {d} more matching lines\n",
            .{shown - max_shown},
        ) catch {};
    }
    return common.exit_ok;
}

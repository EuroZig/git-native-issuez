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

    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            if (args.was_separator) continue;
            if (issue_prefix == null) issue_prefix = arg;
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "--open")) {
            new_state = "open";
        } else if (std.mem.eql(u8, arg, "--close")) {
            new_state = "closed";
        } else if (std.mem.eql(u8, arg, "--state")) {
            new_state = args.value(ctx.err, "--state") orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            message = args.value(ctx.err, "-m") orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "--fixed-by")) {
            fixed_by = args.value(ctx.err, "--fixed-by") orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "--release")) {
            release = args.value(ctx.err, "--release") orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "--reason")) {
            reason = args.value(ctx.err, "--reason") orelse return common.exit_error;
        } else {
            return common.unknownOption(ctx.err, "state", arg);
        }
    }
    const prefix = issue_prefix orelse return common.missing(
        ctx.err,
        "state",
        "issue ID is required",
    );
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

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const ref = common.resolveOne(
        B,
        repo,
        arena,
        ctx.err,
        prefix,
    ) orelse return common.exit_error;
    _ = repo.setState(arena, ref.name, .{
        .state = state,
        .message = message,
        .fixed_by = fixed_by,
        .release = release,
        .reason = reason,
    }) catch |e| return common.repoFailed(B, ctx, e);
    const short = uuid.shortId(ref.id());
    if (std.mem.eql(u8, state, "open")) {
        ctx.out.print("Reopened issue {s}\n", .{short}) catch {};
    } else if (std.mem.eql(u8, state, "closed")) {
        ctx.out.print("Closed issue {s}\n", .{short}) catch {};
    } else {
        ctx.out.print("Changed state of {s} to {s}\n", .{ short, state }) catch {};
    }
    return common.exit_ok;
}

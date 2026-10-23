//! `git issue merge <remote> [--check] [--no-fetch]`
//! `git issue push <remote>`
//! `git issue sync <remote>` (merge, then push)

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const output = @import("../sync_output.zig");
const issuez = @import("issuez");

pub const merge_help =
    \\usage: git issue merge <remote> [options]
    \\
    \\Fetch issues from a remote and merge them into the local issues.
    \\Divergent issues get a merge commit; issues whose remote history is
    \\unrelated or was rewritten are quarantined (left alone, reported).
    \\
    \\Options:
    \\   --check       Report what would happen; change nothing
    \\   --no-fetch    Use the already fetched refs/remotes/<remote>/issues/
    \\   -h, --help    Show this help
    \\
;

pub const push_help =
    \\usage: git issue push <remote>
    \\
    \\Push local issue changes to a remote. If the remote has newer changes,
    \\they are merged first and the push is retried.
    \\
    \\Options:
    \\   -h, --help    Show this help
    \\
;

pub const sync_help =
    \\usage: git issue sync <remote>
    \\
    \\Merge issues from a remote, then push local changes to it.
    \\
    \\Options:
    \\   -h, --help    Show this help
    \\
;

pub const Mode = enum { merge, push, sync };

pub fn main(
    comptime B: type,
    ctx: *context.Context(B),
    argv: []const []const u8,
    mode: Mode,
) u8 {
    const arena = ctx.arena;
    const name = @tagName(mode);
    var remote: ?[]const u8 = null;
    var check = false;
    var fetch = true;
    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            if (args.was_separator) continue;
            if (remote == null) remote = arg;
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(switch (mode) {
                .merge => merge_help,
                .push => push_help,
                .sync => sync_help,
            }) catch {};
            return common.exit_ok;
        } else if (mode == .merge and std.mem.eql(u8, arg, "--check")) {
            check = true;
        } else if (mode == .merge and std.mem.eql(u8, arg, "--no-fetch")) {
            fetch = false;
        } else {
            return common.unknownOption(ctx.err, name, arg);
        }
    }
    const r = remote orelse return common.missing(ctx.err, name, "remote name is required");
    if (!issuez.backend.contract.isValidRemoteName(r)) {
        // Only named remotes: staging and bookkeeping refs are named after
        // the remote. Upstream fails here too.
        ctx.err.print("error: invalid remote name '{s}'\n", .{r}) catch {};
        remoteHint(ctx.err);
        return common.exit_error;
    }

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const s = issuez.Sync(B).init(repo.backend);

    if (mode == .merge or mode == .sync) {
        const report = s.merge(arena, r, .{ .fetch = fetch, .check = check }) catch |e|
            return syncError(B, ctx, e, r);
        output.printMerge(ctx.out, ctx.err, r, report, check);
    }
    if (mode == .push or mode == .sync) {
        const report = s.push(arena, r) catch |e| return syncError(B, ctx, e, r);
        output.printPush(ctx.out, ctx.err, r, report);
    }
    return common.exit_ok;
}

fn remoteHint(err: *std.Io.Writer) void {
    err.writeAll(
        "       issues sync through a named remote; add one with:\n" ++
            "       git remote add <name> <url-or-path>\n",
    ) catch {};
}

fn syncError(comptime B: type, ctx: *context.Context(B), e: anyerror, remote: []const u8) u8 {
    switch (e) {
        error.UnknownRemote => {
            ctx.err.print("error: remote '{s}' does not exist\n", .{remote}) catch {};
            remoteHint(ctx.err);
            return common.exit_error;
        },
        error.FetchFailed => ctx.err.print(
            "error: failed to fetch issues from '{s}'\n",
            .{remote},
        ) catch {},
        error.PushFailed => ctx.err.print(
            "error: failed to push issues to '{s}'\n",
            .{remote},
        ) catch {},
        error.PushRoundsExhausted => ctx.err.print(
            "error: '{s}' kept changing while pushing; try again\n",
            .{remote},
        ) catch {},
        else => return common.repoFailed(B, ctx, e),
    }
    if (@hasDecl(B, "lastStderr")) {
        if (ctx.backend) |backend| {
            const detail = std.mem.trim(u8, backend.lastStderr(), " \t\r\n");
            var lines = std.mem.splitScalar(u8, detail, '\n');
            while (lines.next()) |line| if (line.len > 0) ctx.err.print(
                "       git: {s}\n",
                .{line},
            ) catch {};
        } else |_| {}
    }
    return common.exit_error;
}

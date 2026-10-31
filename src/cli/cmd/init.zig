//! `git issue init [<remote>] [--fix-refspec]`
//!
//! Fetches into a staging namespace instead of upstream's direct refspec,
//! so a plain `git fetch` can't overwrite local issues. `merge` takes it
//! from there.

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");

pub const help =
    \\usage: git issue init [<remote>] [--fix-refspec]
    \\
    \\Configure a remote so `git fetch` also fetches issues, into
    \\refs/remotes/<remote>/issues/ (merge them with `git issue merge`).
    \\
    \\Without <remote>: the only remote, else `origin`.
    \\
    \\Options:
    \\   --fix-refspec   Replace upstream git-issue's refspec, which makes a
    \\                   plain `git fetch` overwrite local issue refs
    \\   -h, --help      Show this help
    \\
    \\init is optional: every command works without a remote.
    \\
;

/// Upstream's refspec. Forced and direct, so fetching can drop unpushed
/// issue commits.
pub const unsafe_refspec = "+refs/issues/*:refs/issues/*";

pub fn milestoneRefspec(arena: std.mem.Allocator, remote: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "+refs/milestones/*:refs/remotes/{s}/milestones/*", .{remote});
}

pub fn stagingRefspec(arena: std.mem.Allocator, remote: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "+refs/issues/*:refs/remotes/{s}/issues/*", .{remote});
}

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var remote_arg: ?[]const u8 = null;
    var fix = false;
    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            if (args.was_separator) continue;
            // Upstream silently takes the last one.
            if (remote_arg != null) return common.missing(
                ctx.err,
                "init",
                "only one remote can be given",
            );
            remote_arg = arg;
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "--fix-refspec")) {
            fix = true;
        } else {
            return common.unknownOption(ctx.err, "init", arg);
        }
    }

    const repo = common.openRepoQuiet(B, ctx) orelse return common.exit_fatal;
    const backend = repo.backend;
    const remotes = backend.remoteNames(arena) catch return gitError(ctx);

    const remote = remote_arg orelse switch (remotes.len) {
        0 => {
            ctx.err.writeAll(
                \\git-issue: No remotes configured.
                \\
                \\Note: git issue init is OPTIONAL. You can use git-issue without any remote:
                \\  - All core commands (create, ls, show, comment, edit, state) work locally
                \\  - To share issues with a remote later, without init:
                \\    git issue sync <remote>
                \\    (or: git push <remote> 'refs/issues/*' and git issue merge <remote>)
                \\
                \\To configure automatic fetch when you add a remote, run:
                \\  git issue init <remote-name>
                \\
            ) catch {};
            return common.exit_ok;
        },
        1 => blk: {
            ctx.out.print("git-issue: Auto-detected remote '{s}'\n", .{remotes[0]}) catch {};
            break :blk remotes[0];
        },
        else => blk: {
            for (remotes) |r| if (std.mem.eql(u8, r, "origin")) {
                ctx.out.writeAll("git-issue: Auto-detected remote 'origin'\n") catch {};
                break :blk "origin";
            };
            ctx.err.writeAll(
                "git-issue: Multiple remotes found. Please specify which one to use:\n",
            ) catch {};
            for (remotes) |r| ctx.err.print("    - {s}\n", .{r}) catch {};
            ctx.err.print(
                "\nUsage:\n  git issue init <remote-name>\n\nExample:\n  git issue init {s}\n",
                .{remotes[0]},
            ) catch {};
            return common.exit_error;
        },
    };

    var exists = false;
    for (remotes) |r| if (std.mem.eql(u8, r, remote)) {
        exists = true;
    };
    if (!exists) {
        ctx.err.print("error: remote '{s}' does not exist\n", .{remote}) catch {};
        const list = std.mem.join(arena, ", ", remotes) catch "";
        ctx.err.print("       available remotes: {s}\n", .{list}) catch {};
        return common.exit_error;
    }

    const key = std.fmt.allocPrint(
        arena,
        "remote.{s}.fetch",
        .{remote},
    ) catch return common.oom(ctx.err);
    const staging = stagingRefspec(arena, remote) catch return common.oom(ctx.err);
    const fetch = backend.configGetAll(arena, key) catch return gitError(ctx);
    var has_staging = false;
    var has_unsafe = false;
    const milestones = milestoneRefspec(arena, remote) catch return common.oom(ctx.err);
    var has_milestones = false;
    for (fetch) |spec| {
        if (std.mem.eql(u8, spec, staging)) has_staging = true;
        if (std.mem.eql(u8, spec, milestones)) has_milestones = true;
        if (std.mem.eql(
            u8,
            std.mem.trimStart(u8, spec, "+"),
            unsafe_refspec[1..],
        )) has_unsafe = true;
    }

    if (has_unsafe and fix) {
        backend.configUnsetValue(key, unsafe_refspec) catch return gitError(ctx);
        backend.configUnsetValue(key, unsafe_refspec[1..]) catch return gitError(ctx);
        has_unsafe = false;
        ctx.out.print(
            "git-issue: removed the unsafe refspec '{s}' from {s}.\n",
            .{ unsafe_refspec, remote },
        ) catch {};
    }
    if (!has_milestones) backend.configAdd(key, milestones) catch return gitError(ctx);
    if (!has_staging) {
        backend.configAdd(key, staging) catch return gitError(ctx);
        ctx.out.print(
            "git-issue: configured. Issues will be fetched from {s} into " ++
                "refs/remotes/{s}/issues/.\n",
            .{ remote, remote },
        ) catch {};
        ctx.out.print("Run 'git fetch {s}' to fetch them.\n", .{remote}) catch {};
    } else if (!fix) {
        ctx.out.print("git-issue: already configured for remote '{s}'.\n", .{remote}) catch {};
    }
    if (has_unsafe) {
        ctx.err.print(
            "warning: remote '{s}' also has '{s}' (set by upstream git-issue init).\n" ++
                "         A plain 'git fetch' then overwrites local issue refs and can drop\n" ++
                "         unpushed issue changes. Run 'git issue init {s} --fix-refspec'\n" ++
                "         to remove it.\n",
            .{ remote, unsafe_refspec, remote },
        ) catch {};
    }
    return common.exit_ok;
}

fn gitError(ctx: anytype) u8 {
    ctx.err.writeAll("error: could not read or change the git configuration\n") catch {};
    return common.exit_error;
}

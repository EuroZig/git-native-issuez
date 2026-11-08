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

const remote_mod = @import("issuez").remote;

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
    const found = remote_mod.default(B, arena, backend) catch return gitError(ctx);

    const remote = remote_arg orelse switch (found) {
        .none => {
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
        .one => |r| blk: {
            ctx.out.print("git-issue: Auto-detected remote '{s}'\n", .{r}) catch {};
            break :blk r;
        },
        .many => |remotes| {
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

    const options: remote_mod.Options = .{ .fix_unsafe = fix };
    const setup = remote_mod.configure(B, arena, backend, remote, options) catch |e| {
        if (e == error.NoSuchRemote or e == error.InvalidRemoteName) {
            ctx.err.print("error: remote '{s}' does not exist\n", .{remote}) catch {};
            const remotes = backend.remoteNames(arena) catch &.{};
            const list = std.mem.join(arena, ", ", remotes) catch "";
            ctx.err.print("       available remotes: {s}\n", .{list}) catch {};
            return common.exit_error;
        }
        if (e == error.OutOfMemory) return common.oom(ctx.err);
        return gitError(ctx);
    };
    if (setup.removed_unsafe) ctx.out.print(
        "git-issue: removed the unsafe refspec '{s}' from {s}.\n",
        .{ remote_mod.unsafe_refspec, remote },
    ) catch {};
    if (setup.configured) {
        ctx.out.print(
            "git-issue: configured. Issues will be fetched from {s} into " ++
                "refs/remotes/{s}/issues/.\n",
            .{ remote, remote },
        ) catch {};
        ctx.out.print("Run 'git fetch {s}' to fetch them.\n", .{remote}) catch {};
    } else if (!fix) {
        ctx.out.print("git-issue: already configured for remote '{s}'.\n", .{remote}) catch {};
    }
    if (setup.unsafe) {
        ctx.err.print(
            "warning: remote '{s}' also has '{s}' (set by upstream git-issue init).\n" ++
                "         A plain 'git fetch' then overwrites local issue refs and can drop\n" ++
                "         unpushed issue changes. Run 'git issue init {s} --fix-refspec'\n" ++
                "         to remove it.\n",
            .{ remote, remote_mod.unsafe_refspec, remote },
        ) catch {};
    }
    return common.exit_ok;
}

fn gitError(ctx: anytype) u8 {
    ctx.err.writeAll("error: could not read or change the git configuration\n") catch {};
    return common.exit_error;
}

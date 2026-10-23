//! `git issue quarantine <remote> --accept-remote | --keep-local <issue-id>`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const issuez = @import("issuez");
const uuid = issuez.format.uuid;

pub const help =
    \\usage: git issue quarantine <remote> (--accept-remote | --keep-local) <issue-id>
    \\
    \\Resolve an issue that a merge from <remote> quarantined (see
    \\`git issue status`). Sync never force-pushes and never drops a version:
    \\--accept-remote keeps the replaced local version in
    \\refs/issuez-sync/<remote>/replaced/issues/<id>/<commit>.
    \\
    \\Options:
    \\   --accept-remote <issue-id>  Replace the local issue with the remote version
    \\   --keep-local <issue-id>     Keep the local issue: a rewound remote becomes the
    \\                               new baseline and the next sync pushes the local
    \\                               version; for unrelated or invalid remote history
    \\                               the issue stays unpushed and this remote version
    \\                               is no longer reported
    \\   -h, --help                  Show this help
    \\
;

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var remote: ?[]const u8 = null;
    var how: ?issuez.sync.Resolution = null;
    var prefix: ?[]const u8 = null;
    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            if (args.was_separator) continue;
            if (remote != null) return common.missing(ctx.err, "quarantine", "unexpected argument");
            remote = arg;
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "--accept-remote") or
            std.mem.eql(u8, arg, "--keep-local"))
        {
            if (how != null) return common.missing(
                ctx.err,
                "quarantine",
                "give one of --accept-remote or --keep-local",
            );
            how = if (std.mem.eql(u8, arg, "--accept-remote")) .accept_remote else .keep_local;
            prefix = args.value(ctx.err, arg) orelse return common.exit_error;
        } else {
            return common.unknownOption(ctx.err, "quarantine", arg);
        }
    }
    const r = remote orelse return common.missing(ctx.err, "quarantine", "remote name is required");
    const resolution = how orelse return common.missing(
        ctx.err,
        "quarantine",
        "--accept-remote <issue-id> or --keep-local <issue-id> is required",
    );

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const s = issuez.Sync(B).init(repo.backend);
    const st = s.status(arena, r) catch |e| return common.repoFailed(B, ctx, e);

    // The issue may only exist on the remote, so match the quarantined IDs.
    var found: ?issuez.sync.Quarantined = null;
    for (st.quarantined) |q| if (std.mem.startsWith(u8, q.id, prefix.?)) {
        if (found != null) {
            ctx.err.print("error: ambiguous issue prefix '{s}'\n", .{prefix.?}) catch {};
            return common.exit_error;
        }
        found = q;
    };
    const q = found orelse {
        ctx.err.print(
            "error: no issue matching '{s}' is quarantined for '{s}' (see 'git issue status')\n",
            .{ prefix.?, r },
        ) catch {};
        return common.exit_error;
    };

    const replaced = s.resolve(arena, r, q.id, resolution) catch |e| switch (e) {
        error.RemoteIssueInvalid => {
            ctx.err.print(
                "error: the remote version of {s} fails integrity checks; " ++
                    "there is nothing valid to accept\n",
                .{uuid.shortId(q.id)},
            ) catch {};
            return common.exit_error;
        },
        else => return common.repoFailed(B, ctx, e),
    };
    const short = uuid.shortId(q.id);
    switch (resolution) {
        .accept_remote => if (replaced) |tip| {
            const backup = issuez.sync.replacedRef(arena, r, q.id, tip) catch
                return common.exit_fatal;
            ctx.out.print(
                "Accepted the remote version of {s}; the local one is kept in {s}\n",
                .{ short, backup },
            ) catch {};
        } else ctx.out.print("Accepted the remote version of {s}\n", .{short}) catch {},
        .keep_local => if (q.reason == .rewound)
            ctx.out.print(
                "Kept the local version of {s}; the next 'git issue sync {s}' pushes it\n",
                .{ short, r },
            ) catch {}
        else
            ctx.out.print(
                "Kept the local version of {s}; it stays unpushed to {s} " ++
                    "and this remote version is no longer reported\n",
                .{ short, r },
            ) catch {},
    }
    return common.exit_ok;
}

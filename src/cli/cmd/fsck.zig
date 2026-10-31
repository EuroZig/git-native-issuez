//! `git issue fsck [--quiet]`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const ext_flags = @import("../ext_flags.zig");
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
    \\Quarantined issues (see `git issue status`) and hierarchy or blocker
    \\problems (see `git issue ls --problems`) are noted, not counted as errors.
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
    reportQuarantine(B, ctx, repo.backend);
    reportProjection(B, ctx, repo);
    if (errors == 0) {
        ctx.out.print("Checked {d} issues, no errors found.\n", .{refs.len}) catch {};
        return common.exit_ok;
    }
    ctx.err.print("Checked {d} issues, {d} errors found.\n", .{ refs.len, errors }) catch {};
    return common.exit_error;
}

/// Quarantine is a sync state, not damage: noted, not counted.
fn reportQuarantine(comptime B: type, ctx: *context.Context(B), backend: *B) void {
    const s = issuez.Sync(B).init(backend);
    const remotes = backend.remoteNames(ctx.arena) catch return;
    for (remotes) |r| {
        const st = s.status(ctx.arena, r) catch continue;
        var open: usize = 0;
        for (st.quarantined) |q| if (!q.kept_local) {
            open += 1;
        };
        if (open > 0) ctx.err.print(
            "note: {d} issue(s) quarantined from '{s}' (see 'git issue status {s}')\n",
            .{ open, r, r },
        ) catch {};
    }
}

/// Same for hierarchy and blocker problems, which upstream's fsck doesn't
/// know about.
fn reportProjection(
    comptime B: type,
    ctx: *context.Context(B),
    repo: issuez.engine.Repo(B),
) void {
    const proj = ext_flags.project(B, ctx, repo) orelse return;
    for (proj.problems) |p| ctx.err.print("note: {s}: {s}\n", .{
        uuid.shortId(p.id),
        ext_flags.describeProblem(ctx.arena, p),
    }) catch {};
}

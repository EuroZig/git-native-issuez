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
    \\   - stored attachment bytes match their hashes
    \\
    \\Milestones get the same checks, with Name: in place of State:.
    \\
    \\Quarantined issues (see `git issue status`), hierarchy or blocker
    \\problems (see `git issue ls --problems`), attachments whose bytes aren't
    \\here yet, ignored attachment trailers and out-of-date derived
    \\refs/attachments/* are noted, not counted as errors.
    \\
    \\Options:
    \\   --repair     Regenerate out-of-date refs/attachments/* (never touches issues)
    \\   -q, --quiet  Only report problems
    \\   -h, --help   Show this help
    \\
;

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var quiet = false;
    var repair = false;
    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--repair")) {
            repair = true;
        } else {
            return common.unknownOption(ctx.err, "fsck", arg);
        }
    }

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const F = issuez.fsck.Fsck(B);
    const report = F.run(
        arena,
        repo,
        .{ .repair = repair },
    ) catch |e| return common.repoFailed(B, ctx, e);
    if (report.issues == 0 and report.milestones == 0) {
        ctx.out.writeAll("No issues found.\n") catch {};
        return common.exit_ok;
    }
    // Projection notes come last, after a bad issue.workflowStates, as
    // every command that projects says it.
    var warned = false;
    for (report.events) |e| {
        if (e == .projection and !warned) {
            ext_flags.warnBadWorkflowStates(B, ctx, repo);
            warned = true;
        }
        render(B, ctx, F, e, quiet);
    }
    if (!warned) ext_flags.warnBadWorkflowStates(B, ctx, repo);
    const errors = report.errors();
    if (errors == 0) {
        ctx.out.print("Checked {d} issues, no errors found.\n", .{report.issues}) catch {};
        return common.exit_ok;
    }
    ctx.err.print("Checked {d} issues, {d} errors found.\n", .{ report.issues, errors }) catch {};
    return common.exit_error;
}

/// What an issue or milestone is called in the output.
fn label(arena: std.mem.Allocator, kind: anytype, id: []const u8) []const u8 {
    if (kind == .issue) return uuid.shortId(id);
    return std.fmt.allocPrint(arena, "milestone {s}", .{uuid.shortId(id)}) catch "milestone";
}

fn render(
    comptime B: type,
    ctx: *context.Context(B),
    comptime F: type,
    e: F.Event,
    quiet: bool,
) void {
    const a = ctx.arena;
    const err = ctx.err;
    switch (e) {
        .ok => |s| if (!quiet) ctx.out.print("ok {s}\n", .{label(a, s.kind, s.id)}) catch {},
        .problem => |p| {
            const short = label(a, p.subject.kind, p.subject.id);
            if (p.problem == .invalid_uuid) {
                err.print(
                    "error: {s}: invalid UUID format: {s}\n",
                    .{ short, p.subject.id },
                ) catch {};
            } else {
                const what = std.fmt.allocPrint(a, "{f}", .{p.problem}) catch "unreadable";
                err.print("error: {s}: {s}\n", .{ short, what }) catch {};
            }
        },
        .milestone_status => |m| err.print(
            "note: {s}: X-Milestone-Status '{s}' is not valid and reads as open\n",
            .{ label(a, .milestone, m.id), m.value },
        ) catch {},
        .attachment_trailer => |t| err.print(
            "note: {s}: commit {s}: {s} attachment trailer ignored: {s}\n",
            .{
                uuid.shortId(t.id),
                t.problem.oid.hex().short(),
                t.problem.kind.text(),
                t.problem.value,
            },
        ) catch {},
        .attachment_missing => |m| err.print(
            "note: {s}: attachment {s} ({s}): bytes not in this repository\n",
            .{ uuid.shortId(m.id), uuid.shortId(m.attachment.id), m.attachment.name },
        ) catch {},
        .attachment_corrupt => |m| err.print(
            "error: {s}: attachment {s} ({s}): stored bytes don't match the hash\n" ++
                "       ('git issue attach fetch' gets a good copy)\n",
            .{ uuid.shortId(m.id), uuid.shortId(m.attachment.id), m.attachment.name },
        ) catch {},
        .derived_ref => |d| err.print(
            "note: {s}: refs/attachments/{s} is {s} (run 'git issue fsck --repair')\n",
            .{ uuid.shortId(d.id), d.id, if (d.missing) "missing" else "out of date" },
        ) catch {},
        .repaired => |id| ctx.out.print("repaired refs/attachments/{s}\n", .{id}) catch {},
        .attachments_failed => |f| common.reportRepoError(B, ctx, f.err),
        .bytes_unchecked => err.writeAll(
            "note: git-lfs isn't installed, so attachment bytes weren't checked " ++
                "(https://git-lfs.com)\n",
        ) catch {},
        .orphans => |n| err.print(
            "note: {d} stored attachment object(s) no issue references (from failed writes)\n",
            .{n},
        ) catch {},
        .quarantined => |q| err.print(
            "note: {d} issue(s) quarantined from '{s}' (see 'git issue status {s}')\n",
            .{ q.count, q.remote, q.remote },
        ) catch {},
        .projection => |p| err.print("note: {s}: {s}\n", .{
            uuid.shortId(p.id),
            ext_flags.describeProblem(a, p),
        }) catch {},
    }
}

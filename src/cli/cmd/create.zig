//! `git issue create [options] <title>`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const core = @import("issuez").format.core;
const ext_flags = @import("../ext_flags.zig");

pub const help =
    \\usage: git issue create [options] <title>
    \\
    \\Create a new issue. Title words are joined with spaces.
    \\
    \\Options:
    \\   -m, --message <text>      Description; repeat for more paragraphs
    \\   -l, --label <label>       Add a label (repeatable)
    \\   -a, --assignee <email>    Assign to someone ("<uuid> <email>" also works)
    \\   -p, --priority <level>    low, medium, high or critical
    \\   --milestone <name>        Set the milestone
    \\
++ ext_flags.help_create ++
    \\   -h, --help                Show this help
    \\
;

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var title: std.ArrayList([]const u8) = .empty;
    var body: std.ArrayList([]const u8) = .empty;
    var labels: std.ArrayList([]const u8) = .empty;
    var assignee: ?[]const u8 = null;
    var priority: ?core.Priority = null;
    var milestone: ?[]const u8 = null;
    var ext: ext_flags.Flags = .{};

    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            if (args.was_separator) continue;
            title.append(arena, arg) catch return common.oom(ctx.err);
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            const v = args.value(ctx.err, "-m") orelse return common.exit_error;
            body.append(arena, v) catch return common.oom(ctx.err);
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--label")) {
            const v = args.value(ctx.err, "-l") orelse return common.exit_error;
            if (common.hasNewline(v)) return common.fail(
                ctx.err,
                "error: label must not contain newlines\n",
            );
            if (std.mem.findScalar(u8, v, ',') != null) {
                ctx.err.print(
                    "error: label '{s}' contains a comma (use multiple -l flags instead)\n",
                    .{v},
                ) catch {};
                return common.exit_error;
            }
            labels.append(arena, v) catch return common.oom(ctx.err);
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--assignee")) {
            const v = args.value(ctx.err, "-a") orelse return common.exit_error;
            if (common.hasNewline(v)) return common.fail(
                ctx.err,
                "error: assignee must not contain newlines\n",
            );
            if (!common.validateAssignee(ctx.err, v)) return common.exit_error;
            assignee = v;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--priority")) {
            const v = args.value(ctx.err, "-p") orelse return common.exit_error;
            const p = core.Priority.parse(v) orelse return common.fail(
                ctx.err,
                "error: priority must be low, medium, high, or critical\n",
            );
            priority = p;
        } else if (std.mem.eql(u8, arg, "--milestone")) {
            const v = args.value(ctx.err, "--milestone") orelse return common.exit_error;
            if (common.hasNewline(v)) return common.fail(
                ctx.err,
                "error: milestone must not contain newlines\n",
            );
            milestone = v;
        } else switch (ext.parse(arena, ctx.err, &args, arg, false)) {
            .yes => {},
            .failed => return common.exit_error,
            .no => return common.unknownOption(ctx.err, "create", arg),
        }
    }

    const title_text = std.mem.join(arena, " ", title.items) catch return common.oom(ctx.err);
    if (title_text.len == 0) return common.missing(ctx.err, "create", "issue title is required");
    if (common.hasNewline(title_text)) return common.fail(
        ctx.err,
        "error: title must not contain newlines\n",
    );

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const body_text = std.mem.join(arena, "\n\n", body.items) catch return common.oom(ctx.err);
    const x = ext.resolve(B, ctx, repo) orelse return common.exit_error;
    const ms = ext_flags.resolveMilestone(B, ctx, repo, ext, milestone, null) orelse
        return common.exit_error;
    const created = repo.create(arena, .{
        .title = title_text,
        .body = body_text,
        .labels = labels.items,
        .assignee = assignee,
        .priority = priority,
        .milestone = ms.text,
        .milestone_id = ms.id,
        .milestone_mode = ms.mode,
        .parent = x.parent,
        .blocked_by = x.blocked_by,
        .start_date = x.start,
        .due_date = x.due,
        .estimate_minutes = x.estimate,
        .workflow = x.workflow,
    }) catch |e| return common.repoFailed(B, ctx, e);
    ctx.out.print("Created issue {s}\n", .{created.id.short()}) catch {};
    return common.exit_ok;
}

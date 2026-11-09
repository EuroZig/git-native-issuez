//! `git issue create [options] <title>`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const issuez = @import("issuez");
const core = issuez.format.core;
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
    \\   --add-assignee <email>    Assign to someone more (repeatable)
    \\   --number <n>              The issue's number in its host (#n); unique here
    \\   --field <key>=<value>     A host field (an X- key the format doesn't use)
    \\   --original-author <name>  Imported: its author in the other tracker
    \\   --original-id <id>        Imported: its ID in the other tracker
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
    // `-a` first, then `--add-assignee`s.
    var assignee: ?issuez.format.fields.Assignee = null;
    var more: std.ArrayList(issuez.format.fields.Assignee) = .empty;
    var number: ?u64 = null;
    var extras: common.Extras = .{};
    var priority: ?core.Priority = null;
    var milestone: ?[]const u8 = null;
    var ext: ext_flags.Flags = .{};

    const flags = [_]common.Flag{
        .{ "-m --message", .{ .list = &body } },
        .{ "-l --label", .{ .label = &labels } },
        .{ "--milestone", .{ .line = .{ &milestone, "milestone" } } },
    } ++ ext.table();
    var parser = common.argParser(ctx, argv, .{
        .command = "create",
        .help = help,
        .positionals = .{ .words = &title },
        .flags = &flags,
    });
    while (parser.next()) |arg| {
        if (common.isFlag(arg, "-a --assignee")) {
            const v = parser.value("-a") orelse return common.exit_error;
            if (!common.validateAssigneeLine(ctx.err, v)) return common.exit_error;
            if (v.len > 0) assignee = common.assigneeOf(v);
        } else if (common.isFlag(arg, "--field") or std.mem.startsWith(u8, arg, "--original-")) {
            const was = extras.parse(arena, ctx.err, &parser.args, arg) orelse
                return common.exit_error;
            if (!was) return parser.unknown(arg);
        } else if (common.isFlag(arg, "--number")) {
            const v = parser.value(arg) orelse return common.exit_error;
            number = common.numberOf(ctx.err, v) orelse return common.exit_error;
        } else if (common.isFlag(arg, "--add-assignee")) {
            const v = parser.value(arg) orelse return common.exit_error;
            if (common.hasNewline(v) or !common.validateAssignee(ctx.err, v))
                return common.exit_error;
            if (v.len > 0)
                more.append(arena, common.assigneeOf(v)) catch return common.oom(ctx.err);
        } else if (common.isFlag(arg, "-p --priority")) {
            const v = parser.value("-p") orelse return common.exit_error;
            priority = common.priorityOf(ctx.err, v) orelse return common.exit_error;
        } else return parser.unknown(arg);
    }
    if (parser.exit) |exit| return exit;

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
        .assignees = if (assignee) |a|
            std.mem.concat(arena, issuez.format.fields.Assignee, &.{ &.{a}, more.items }) catch
                return common.oom(ctx.err)
        else
            more.items,
        .number = number,
        .extra = extras.fields.items,
        .original = extras.original,
        .priority = priority,
        .milestone = ms.edit(),
        .parent = x.parent,
        .blocked_by = x.blocked_by,
        .start_date = x.start,
        .due_date = x.due,
        .estimate_minutes = x.estimate,
        .workflow = x.workflow,
    }, .{}) catch |e| return common.repoFailed(B, ctx, e);
    ctx.out.print("Created issue {s}\n", .{issuez.shortId(created.id)}) catch {};
    return common.exit_ok;
}

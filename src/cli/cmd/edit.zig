//! `git issue edit <issue-id> [options]`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const core = @import("issuez").format.core;
const issuez = @import("issuez");
const uuid = issuez.format.uuid;
const ext_flags = @import("../ext_flags.zig");

pub const help =
    \\usage: git issue edit <issue-id> [options]
    \\
    \\Change issue metadata.
    \\
    \\Options:
    \\   -t, --title <text>        Change the title
    \\   -l, --label <label>       Set labels (repeatable; replaces all labels)
    \\   --add-label <label>       Add a label
    \\   --remove-label <label>    Remove a label
    \\   -a, --assignee <email>    Change the assignee ("" unassigns everyone)
    \\   --add-assignee <email>    Assign to someone more (repeatable)
    \\   --unassign <email>        Unassign someone (repeatable)
    \\   --number <n>              Give the issue its number (#n), once; unique here
    \\   --lock                    Lock the conversation
    \\   --lock-reason <text>      With --lock: why
    \\   --unlock                  Unlock it
    \\   --ref <ref>               The branch or tag it is about ("" clears)
    \\   -p, --priority <level>    low, medium, high or critical
    \\   --milestone <name>        Change the milestone
    \\   -m, --message <text>      Commit message for the edit
    \\   --description <text>      Replace the description; repeat for paragraphs.
    \\                             Written in the same commit as the other changes
    \\   -c, --comment <text>      A comment in the same commit; repeat for
    \\                             paragraphs. Not with --description or -m
    \\   --state <value>           Change the state in the same commit
    \\   --fixed-by <sha>          With --state: commit that fixes the issue
    \\   --release <version>       With --state: release that ships the fix
    \\   --reason <reason>         With --state: why it changed
    \\
++ ext_flags.help_edit ++
    \\   -h, --help                Show this help
    \\
;

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var issue_prefix: ?[]const u8 = null;
    var spec: issuez.engine.EditSpec = .{};
    var set_labels: std.ArrayList([]const u8) = .empty;
    var add: std.ArrayList([]const u8) = .empty;
    var remove: std.ArrayList([]const u8) = .empty;
    var ext: ext_flags.Flags = .{};
    var description: std.ArrayList([]const u8) = .empty;
    var comment: std.ArrayList([]const u8) = .empty;
    var add_assignees: std.ArrayList(issuez.format.fields.Assignee) = .empty;
    // `--milestone`, chosen once the repository is open.
    var milestone: ?[]const u8 = null;
    var remove_assignees: std.ArrayList([]const u8) = .empty;

    const flags = [_]common.Flag{
        .{ "-l --label", .{ .label = &set_labels } },
        .{ "--add-label", .{ .label = &add } },
        .{ "--milestone", .{ .line = .{ &milestone, "milestone" } } },
        .{ "-m --message", .{ .text = &spec.message } },
        .{ "--description", .{ .list = &description } },
        .{ "-c --comment", .{ .list = &comment } },
        .{ "--fixed-by", .{ .line = .{ &spec.fixed_by, "--fixed-by value" } } },
        .{ "--release", .{ .line = .{ &spec.release, "--release value" } } },
        .{ "--reason", .{ .line = .{ &spec.reason, "--reason value" } } },
        .{ "--unblock", .{ .list = &ext.unblock } },
    } ++ ext.table();
    var parser = common.argParser(ctx, argv, .{
        .command = "edit",
        .help = help,
        .positionals = .{ .first = &issue_prefix },
        .flags = &flags,
    });
    while (parser.next()) |arg| {
        if (common.isFlag(arg, "-t --title")) {
            const v = parser.value("-t") orelse return common.exit_error;
            if (common.hasNewline(v))
                return common.fail(ctx.err, "error: title must not contain newlines\n");
            if (std.mem.trim(u8, v, " \t").len == 0)
                return common.fail(ctx.err, "error: title must not be empty\n");
            spec.title = v;
        } else if (common.isFlag(arg, "--remove-label")) {
            const v = parser.value(arg) orelse return common.exit_error;
            if (common.hasNewline(v))
                return common.fail(ctx.err, "error: label must not contain newlines\n");
            // Like upstream, a comma-separated value removes each label.
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |part| remove.append(
                arena,
                std.mem.trim(u8, part, " \t"),
            ) catch return common.oom(ctx.err);
        } else if (common.isFlag(arg, "-a --assignee")) {
            const v = parser.value("-a") orelse return common.exit_error;
            if (!common.validateAssigneeLine(ctx.err, v)) return common.exit_error;
            spec.set_assignees = &.{};
            if (v.len > 0) {
                const one = arena.alloc(issuez.format.fields.Assignee, 1) catch
                    return common.oom(ctx.err);
                one[0] = common.assigneeOf(v);
                spec.set_assignees = one;
            }
        } else if (common.isFlag(arg, "--lock --unlock")) {
            spec.locked = std.mem.eql(u8, arg, "--lock");
        } else if (common.isFlag(arg, "--lock-reason")) {
            spec.lock_reason = parser.value(arg) orelse return common.exit_error;
            if (common.hasNewline(spec.lock_reason.?))
                return common.fail(ctx.err, "error: lock reason must be one line\n");
        } else if (common.isFlag(arg, "--ref")) {
            const v = parser.value(arg) orelse return common.exit_error;
            if (v.len > 0 and !issuez.format.fields.isRefName(v))
                return common.fail(ctx.err, "error: --ref takes a branch or tag name\n");
            spec.ref = .fromInput(v);
        } else if (common.isFlag(arg, "--number")) {
            const v = parser.value(arg) orelse return common.exit_error;
            spec.number = common.numberOf(ctx.err, v) orelse return common.exit_error;
        } else if (common.isFlag(arg, "--add-assignee")) {
            const v = parser.value(arg) orelse return common.exit_error;
            if (!common.validateAssigneeLine(ctx.err, v)) return common.exit_error;
            if (v.len > 0) add_assignees.append(arena, common.assigneeOf(v)) catch
                return common.oom(ctx.err);
        } else if (common.isFlag(arg, "--unassign")) {
            const v = parser.value(arg) orelse return common.exit_error;
            if (common.hasNewline(v))
                return common.fail(ctx.err, "error: assignee must not contain newlines\n");
            remove_assignees.append(arena, v) catch return common.oom(ctx.err);
        } else if (common.isFlag(arg, "-p --priority")) {
            const v = parser.value("-p") orelse return common.exit_error;
            const p = common.priorityOf(ctx.err, v) orelse return common.exit_error;
            spec.priority = .{ .set = p };
        } else if (common.isFlag(arg, "--state")) {
            const v = parser.value(arg) orelse return common.exit_error;
            if (!core.isState(v)) return common.fail(
                ctx.err,
                "error: state must contain only alphanumeric characters, hyphens, or underscores\n",
            );
            spec.state = core.State.parse(v);
        } else if (!ext.clear(arg)) return parser.unknown(arg);
    }
    if (parser.exit) |exit| return exit;
    const prefix = issue_prefix orelse
        return common.missing(ctx.err, "edit", "issue ID is required");
    if (set_labels.items.len > 0) spec.set_labels = set_labels.items;
    spec.add_labels = add.items;
    spec.remove_labels = remove.items;
    spec.add_assignees = add_assignees.items;
    spec.remove_assignees = remove_assignees.items;
    const clears = ext.no;
    if (clears.contains(.assignee)) spec.set_assignees = &.{};
    if (clears.contains(.priority)) spec.priority = .clear;
    if (clears.contains(.labels)) spec.set_labels = &.{};
    if (description.items.len > 0) {
        spec.description = std.mem.join(arena, "\n\n", description.items) catch
            return common.oom(ctx.err);
    }
    if (comment.items.len > 0) {
        if (description.items.len > 0 or spec.message != null) return common.fail(
            ctx.err,
            "error: --comment can't go with --description or -m\n",
        );
        spec.comment = std.mem.join(arena, "\n\n", comment.items) catch return common.oom(ctx.err);
    }
    if (spec.lock_reason != null and (spec.locked == null or !spec.locked.?))
        return common.fail(ctx.err, "error: --lock-reason needs --lock\n");
    const closing_field = spec.fixed_by != null or spec.release != null or spec.reason != null;
    if (spec.state == null and closing_field)
        return common.fail(ctx.err, "error: --fixed-by, --release and --reason need --state\n");
    if (spec.isEmpty() and milestone == null and !ext.any()) return common.missing(
        ctx.err,
        "edit",
        "at least one edit option is required",
    );

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const ref = common.resolveOne(B, repo, arena, ctx.err, prefix) orelse return common.exit_error;
    const x = ext.resolve(B, ctx, repo) orelse return common.exit_error;
    const current = repo.load(arena, ref) catch |e| return common.repoFailed(B, ctx, e);
    const ms = ext_flags.resolveMilestone(B, ctx, repo, ext, milestone, current) orelse
        return common.exit_error;
    spec.milestone = ms.edit();
    if (x.parent) |p| spec.parent = .{ .set = p };
    if (clears.contains(.parent)) spec.parent = .clear;
    spec.add_blocked_by = x.blocked_by;
    spec.remove_blocked_by = x.unblock;
    if (clears.contains(.blockers)) spec.set_blocked_by = &.{};
    if (x.start) |v| spec.start_date = .{ .set = v };
    if (clears.contains(.start)) spec.start_date = .clear;
    if (x.due) |v| spec.due_date = .{ .set = v };
    if (clears.contains(.due)) spec.due_date = .clear;
    if (x.estimate) |m| spec.estimate_minutes = .{ .set = m };
    if (clears.contains(.estimate)) spec.estimate_minutes = .clear;
    if (x.workflow) |v| spec.workflow = .{ .set = v };
    if (clears.contains(.workflow)) spec.workflow = .clear;
    var names: std.ArrayList([]const u8) = .empty;
    if (!spec.isEmpty()) {
        const result = repo.edit(arena, ref.name, spec, .{}) catch |e|
            return common.repoFailed(B, ctx, e);
        if (!result.wrote) {
            ctx.out.print("Nothing to change in {s}\n", .{uuid.shortId(ref.id())}) catch {};
            return common.exit_ok;
        }
        for (result.changes) |c| names.append(arena, c.name()) catch return common.oom(ctx.err);
    }
    const joined = std.mem.join(arena, ", ", names.items) catch return common.oom(ctx.err);
    ctx.out.print("Updated {s} ({s})\n", .{ uuid.shortId(ref.id()), joined }) catch {};
    return common.exit_ok;
}

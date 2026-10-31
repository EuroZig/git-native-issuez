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
    \\   -a, --assignee <email>    Change the assignee ("" unassigns)
    \\   -p, --priority <level>    low, medium, high or critical
    \\   --milestone <name>        Change the milestone
    \\   -m, --message <text>      Commit message for the edit
    \\   --description <text>      Replace the description; repeat for paragraphs
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
    var labels_given = false;
    var add: std.ArrayList([]const u8) = .empty;
    var remove: std.ArrayList([]const u8) = .empty;
    var ext: ext_flags.Flags = .{};
    var description: std.ArrayList([]const u8) = .empty;

    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            if (args.was_separator) continue;
            if (issue_prefix == null) issue_prefix = arg;
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--title")) {
            const v = args.value(ctx.err, "-t") orelse return common.exit_error;
            if (common.hasNewline(v)) return common.fail(
                ctx.err,
                "error: title must not contain newlines\n",
            );
            if (std.mem.trim(u8, v, " \t").len == 0) return common.fail(
                ctx.err,
                "error: title must not be empty\n",
            );
            spec.title = v;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--label") or
            std.mem.eql(u8, arg, "--add-label") or std.mem.eql(u8, arg, "--remove-label"))
        {
            const flag = if (std.mem.eql(u8, arg, "--label")) "-l" else arg;
            const v = args.value(ctx.err, flag) orelse return common.exit_error;
            if (common.hasNewline(v)) return common.fail(
                ctx.err,
                "error: label must not contain newlines\n",
            );
            if (!std.mem.eql(
                u8,
                arg,
                "--remove-label",
            ) and std.mem.findScalar(u8, v, ',') != null) {
                ctx.err.print(
                    "error: label '{s}' contains a comma (use multiple -l flags instead)\n",
                    .{v},
                ) catch {};
                return common.exit_error;
            }
            const list = if (std.mem.eql(u8, arg, "--add-label"))
                &add
            else if (std.mem.eql(u8, arg, "--remove-label"))
                &remove
            else blk: {
                labels_given = true;
                break :blk &set_labels;
            };
            if (std.mem.eql(u8, arg, "--remove-label")) {
                // Like upstream, a comma-separated value removes each label.
                var it = std.mem.splitScalar(u8, v, ',');
                while (it.next()) |part| list.append(
                    arena,
                    std.mem.trim(u8, part, " \t"),
                ) catch return common.oom(ctx.err);
            } else {
                list.append(arena, v) catch return common.oom(ctx.err);
            }
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--assignee")) {
            const v = args.value(ctx.err, "-a") orelse return common.exit_error;
            if (common.hasNewline(v)) return common.fail(
                ctx.err,
                "error: assignee must not contain newlines\n",
            );
            if (!common.validateAssignee(ctx.err, v)) return common.exit_error;
            spec.assignee = v;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--priority")) {
            const v = args.value(ctx.err, "-p") orelse return common.exit_error;
            if (!core.isPriority(v)) return common.fail(
                ctx.err,
                "error: priority must be low, medium, high, or critical\n",
            );
            spec.priority = v;
        } else if (std.mem.eql(u8, arg, "--milestone")) {
            const v = args.value(ctx.err, "--milestone") orelse return common.exit_error;
            if (common.hasNewline(v)) return common.fail(
                ctx.err,
                "error: milestone must not contain newlines\n",
            );
            spec.milestone = v;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            spec.message = args.value(ctx.err, "-m") orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "--description")) {
            const v = args.value(ctx.err, arg) orelse return common.exit_error;
            description.append(arena, v) catch return common.oom(ctx.err);
        } else switch (ext.parse(arena, ctx.err, &args, arg, true)) {
            .yes => {},
            .failed => return common.exit_error,
            .no => return common.unknownOption(ctx.err, "edit", arg),
        }
    }
    const prefix = issue_prefix orelse return common.missing(
        ctx.err,
        "edit",
        "issue ID is required",
    );
    if (labels_given) spec.set_labels = set_labels.items;
    spec.add_labels = add.items;
    spec.remove_labels = remove.items;
    const clears = ext.no;
    if (clears.contains(.assignee)) spec.assignee = "";
    if (clears.contains(.priority)) spec.priority = "";
    if (clears.contains(.milestone)) spec.milestone = "";
    if (clears.contains(.labels)) spec.set_labels = &.{};
    if (spec.isEmpty() and !ext.any() and description.items.len == 0) return common.missing(
        ctx.err,
        "edit",
        "at least one edit option is required",
    );

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const ref = common.resolveOne(
        B,
        repo,
        arena,
        ctx.err,
        prefix,
    ) orelse return common.exit_error;
    const x = ext.resolve(B, ctx, repo) orelse return common.exit_error;
    if (x.parent) |p| spec.parent = p;
    if (clears.contains(.parent)) spec.parent = "";
    spec.add_blocked_by = x.blocked_by;
    spec.remove_blocked_by = x.unblock;
    if (clears.contains(.blockers)) spec.set_blocked_by = &.{};
    if (x.start) |v| spec.start_date = v;
    if (clears.contains(.start)) spec.start_date = "";
    if (x.due) |v| spec.due_date = v;
    if (clears.contains(.due)) spec.due_date = "";
    if (x.estimate) |m| spec.estimate_minutes = .{ .set = m };
    if (clears.contains(.estimate)) spec.estimate_minutes = .clear;
    if (x.workflow) |v| spec.workflow = v;
    if (clears.contains(.workflow)) spec.workflow = "";
    var names: std.ArrayList([]const u8) = .empty;
    if (!spec.isEmpty()) {
        const result = repo.edit(arena, ref.name, spec) catch |e|
            return common.repoFailed(B, ctx, e);
        for (result.changes) |c| names.append(arena, c.name()) catch return common.oom(ctx.err);
    }
    if (description.items.len > 0) {
        const text = std.mem.join(arena, "\n\n", description.items) catch
            return common.oom(ctx.err);
        _ = repo.editDescription(arena, ref.name, text, .{}) catch |e|
            return common.repoFailed(B, ctx, e);
        names.append(arena, "description") catch return common.oom(ctx.err);
    }
    const joined = std.mem.join(arena, ", ", names.items) catch return common.oom(ctx.err);
    ctx.out.print("Updated {s} ({s})\n", .{ uuid.shortId(ref.id()), joined }) catch {};
    return common.exit_ok;
}

//! `git issue ls [options]`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const core = @import("issuez").format.core;
const issuez = @import("issuez");
const query = issuez.query;
const labels_fmt = issuez.format.labels;
const uuid = issuez.format.uuid;

pub const help =
    \\usage: git issue ls [options]
    \\
    \\List issues.
    \\
    \\Options:
    \\   -s, --state <state>     open, closed, any custom state, or all [default: open]
    \\   -l, --label <label>     Only issues with this label
    \\   --assignee <email>      Only issues assigned to this address
    \\   --priority <level>      Only issues with this priority
    \\   -a, --all               Same as --state all
    \\   -f, --format <format>   short (default), full or oneline
    \\   --sort <field>          created (default), updated, priority or state
    \\   --reverse               Reverse the sort order
    \\   --conflicts             Only issues with fields edited concurrently, each
    \\                           with the conflict
    \\   -h, --help              Show this help
    \\
    \\Formats:
    \\   short    <id> [<state>] <title>
    \\   full     short, plus labels, assignee, priority and milestone
    \\   oneline  <id> <state> <title> (no brackets, for scripts)
    \\
;

const Format = enum { short, full, oneline };

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var state_filter: []const u8 = "open";
    var label_filter: ?[]const u8 = null;
    var assignee_filter: ?[]const u8 = null;
    var priority_filter: ?[]const u8 = null;
    var format: Format = .short;
    var sort: query.SortKey = .created;
    var reverse = false;
    var only_conflicts = false;

    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--state")) {
            state_filter = args.value(ctx.err, "-s") orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--label")) {
            label_filter = args.value(ctx.err, "-l") orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "--assignee")) {
            assignee_filter = args.value(ctx.err, "--assignee") orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "--priority")) {
            const v = args.value(ctx.err, "--priority") orelse return common.exit_error;
            if (!core.isPriority(v)) return common.fail(
                ctx.err,
                "error: priority must be low, medium, high, or critical\n",
            );
            priority_filter = v;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            state_filter = "all";
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
            const v = args.value(ctx.err, "-f") orelse return common.exit_error;
            format = std.meta.stringToEnum(Format, v) orelse return common.fail(
                ctx.err,
                "error: format must be short, full, or oneline\n",
            );
        } else if (std.mem.eql(u8, arg, "--sort")) {
            const v = args.value(ctx.err, "--sort") orelse return common.exit_error;
            sort = std.meta.stringToEnum(query.SortKey, v) orelse return common.fail(
                ctx.err,
                "error: sort must be created, updated, priority, or state\n",
            );
        } else if (std.mem.eql(u8, arg, "--reverse")) {
            reverse = true;
        } else if (std.mem.eql(u8, arg, "--conflicts")) {
            only_conflicts = true;
        } else {
            return common.unknownOption(ctx.err, "ls", arg);
        }
    }

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const all = repo.loadAll(arena) catch |e| return common.repoFailed(B, ctx, e);

    const filter: query.Filter = .{
        .state = if (std.mem.eql(u8, state_filter, "all")) null else state_filter,
        .label = label_filter,
        .assignee = assignee_filter,
        .priority = priority_filter,
    };
    const sorted = query.list(arena, all, filter, .{ .key = sort, .reverse = reverse }) catch
        return common.exit_error;
    var kept: std.ArrayList(issuez.engine.Issue) = .empty;
    for (sorted) |issue| {
        if (only_conflicts and issue.conflicts.len == 0) continue;
        kept.append(arena, issue) catch return common.oom(ctx.err);
    }
    const listed = kept.items;

    for (listed) |issue| {
        const short = uuid.shortId(issue.id);
        switch (format) {
            .oneline => ctx.out.print(
                "{s} {s} {s}\n",
                .{ short, issue.state, issue.title },
            ) catch {},
            .short => ctx.out.print(
                "{s} [{s}] {s}\n",
                .{ short, issue.state, issue.title },
            ) catch {},
            .full => {
                ctx.out.print("{s} [{s}] {s}\n", .{ short, issue.state, issue.title }) catch {};
                var detail: std.Io.Writer.Allocating = .init(arena);
                if (issue.labels.len > 0) detail.writer.print(
                    " labels:{s}",
                    .{labels_fmt.join(arena, issue.labels) catch ""},
                ) catch {};
                if (issue.field("Assignee")) |v| detail.writer.print(
                    " assignee:{s}",
                    .{v},
                ) catch {};
                if (issue.field("Priority")) |v| detail.writer.print(
                    " priority:{s}",
                    .{v},
                ) catch {};
                if (issue.field("Milestone")) |v| detail.writer.print(
                    " milestone:{s}",
                    .{v},
                ) catch {};
                if (detail.written().len > 0) ctx.out.print(
                    "       {s}\n",
                    .{detail.written()},
                ) catch {};
            },
        }
        if (format == .oneline) continue;
        if (only_conflicts) for (issue.conflicts) |c| ctx.out.print(
            "       conflict: {s} kept '{s}', not '{s}'\n",
            .{ c.field, c.value, c.lost },
        ) catch {};
    }
    return common.exit_ok;
}

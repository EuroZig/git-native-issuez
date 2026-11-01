//! `git issue ls [options]`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const core = @import("issuez").format.core;
const issuez = @import("issuez");
const query = issuez.query;
const ext_flags = @import("../ext_flags.zig");
const json = @import("../json.zig");
const labels_fmt = issuez.format.labels;
const uuid = issuez.format.uuid;

pub const help =
    \\usage: git issue ls [options]
    \\
    \\List issues.
    \\
    \\Options:
    \\   -s, --state <state>     open, closed, any custom state, or all [default: every
    \\                           issue that isn't done; git config issue.doneStates
    \\                           lists the states besides closed that are done,
    \\                           default wontfix,duplicate]
    \\   -l, --label <label>     Only issues with this label
    \\   --assignee <email>      Only issues assigned to this address
    \\   --priority <level>      Only issues with this priority
    \\   -a, --all               Same as --state all
    \\   -f, --format <format>   short (default), full or oneline
    \\   --sort <field>          created (default), updated, priority or state
    \\   --reverse               Reverse the sort order
    \\   --problems              Only issues with problems (a parent or blocker that
    \\                           is missing or loops back, invalid values, ...), each
    \\                           with the problem, in any state unless --state
    \\   --conflicts             Only issues with fields edited concurrently, each
    \\                           with the conflict
    \\   --deleted               Only deleted issues (see git issue restore)
    \\   --json                  JSON array of issues (docs/json.md); ignores -f
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
    // Unset: what isn't done.
    var state_filter: ?core.State = null;
    var state_given = false;
    var label_filter: ?[]const u8 = null;
    var assignee_filter: ?[]const u8 = null;
    var priority_filter: ?core.Priority = null;
    var format: Format = .short;
    var sort: query.SortKey = .created;
    var reverse = false;
    var only_problems = false;
    var only_conflicts = false;
    var only_deleted = false;
    var as_json = false;

    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--state")) {
            state_filter = common.stateFilter(args.value(ctx.err, "-s") orelse return common.exit_error);
            state_given = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--label")) {
            label_filter = args.value(ctx.err, "-l") orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "--assignee")) {
            assignee_filter = args.value(ctx.err, "--assignee") orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "--priority")) {
            const v = args.value(ctx.err, "--priority") orelse return common.exit_error;
            const p = core.Priority.parse(v) orelse return common.fail(
                ctx.err,
                "error: priority must be low, medium, high, or critical\n",
            );
            priority_filter = p;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            state_filter = null;
            state_given = true;
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
        } else if (std.mem.eql(u8, arg, "--problems")) {
            only_problems = true;
        } else if (std.mem.eql(u8, arg, "--conflicts")) {
            only_conflicts = true;
        } else if (std.mem.eql(u8, arg, "--deleted")) {
            only_deleted = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
        } else {
            return common.unknownOption(ctx.err, "ls", arg);
        }
    }

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const all = repo.loadAll(arena) catch |e| return common.repoFailed(B, ctx, e);

    const filter: query.Filter = .{
        .state = state_filter,
        .done = if (state_given or only_problems) null else false,
        .done_states = repo.done_states,
        .label = label_filter,
        .assignee = assignee_filter,
        .priority = priority_filter,
        .deleted = only_deleted,
    };
    const sorted = query.list(arena, all, filter, .{
        .key = sort,
        .reverse = reverse,
        .done_states = repo.done_states,
    }) catch return common.exit_error;
    const proj = if (only_problems or as_json)
        ext_flags.projectIssues(B, ctx, repo, all) orelse return common.exit_error
    else
        null;
    var kept: std.ArrayList(issuez.engine.Issue) = .empty;
    for (sorted) |issue| {
        if (only_conflicts and issue.conflicts.len == 0) continue;
        if (only_problems) {
            const p = proj.?;
            if (p.problemsOf(p.find(issue.id).?).len == 0) continue;
        }
        kept.append(arena, issue) catch return common.oom(ctx.err);
    }
    const listed = kept.items;
    if (as_json) {
        var s = json.begin(ctx.out);
        writeJson(&s, arena, listed, proj.?) catch |e| return json.failed(ctx.err, e);
        json.end(&s);
        return common.exit_ok;
    }

    for (listed) |issue| {
        const short = uuid.shortId(issue.id);
        switch (format) {
            .oneline => ctx.out.print(
                "{s} {s} {s}\n",
                .{ short, issue.state.text(), issue.title },
            ) catch {},
            .short => ctx.out.print(
                "{s} [{s}] {s}\n",
                .{ short, issue.state.text(), issue.title },
            ) catch {},
            .full => {
                ctx.out.print("{s} [{s}] {s}\n", .{ short, issue.state.text(), issue.title }) catch {};
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
        if (proj) |p| {
            for (p.problemsOf(p.find(issue.id).?)) |pr| ctx.out.print(
                "       problem: {s}\n",
                .{ext_flags.describeProblem(arena, pr)},
            ) catch {};
        }
        if (only_conflicts) for (issue.conflicts) |c| ctx.out.print(
            "       conflict: {f} kept '{s}', not '{s}'\n",
            .{ c.target, c.value, c.lost },
        ) catch {};
    }
    return common.exit_ok;
}

fn writeJson(
    s: *json.Stringify,
    arena: std.mem.Allocator,
    listed: []const issuez.engine.Issue,
    proj: issuez.projection.Projection,
) json.Error!void {
    try s.beginArray();
    for (listed) |issue| try json.issue(s, arena, issue, .{ .projection = proj });
    try s.endArray();
}

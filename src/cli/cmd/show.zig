//! `git issue show <issue-id>`
//!
//! Upstream's layout. Values come from the whole history, so Assignee,
//! Priority and Milestone don't vanish after later updates like they do
//! upstream.

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const issuez = @import("issuez");
const labels_fmt = issuez.format.labels;
const uuid = issuez.format.uuid;

pub const help =
    \\usage: git issue show <issue-id>
    \\
    \\Show an issue with its comments and updates.
    \\
    \\   <issue-id>    Full UUID or a unique prefix
    \\   -h, --help    Show this help
    \\
;

const rule_heavy = "============================================================";
const rule_light = "------------------------------------------------------------";

const header_fields = [_][]const u8{ "Assignee", "Priority", "Milestone" };

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var issue_prefix: ?[]const u8 = null;
    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            if (args.was_separator) continue;
            if (issue_prefix == null) issue_prefix = arg;
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else {
            return common.unknownOption(ctx.err, "show", arg);
        }
    }
    const prefix = issue_prefix orelse return common.missing(
        ctx.err,
        "show",
        "issue ID is required",
    );

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const ref = common.resolveOne(
        B,
        repo,
        arena,
        ctx.err,
        prefix,
    ) orelse return common.exit_error;
    const issue = repo.load(arena, ref) catch |e| return common.repoFailed(B, ctx, e);

    const w = ctx.out;
    w.print(
        "Issue {s} [{s}]\n{s}\n",
        .{ uuid.shortId(issue.id), issue.state, rule_heavy },
    ) catch {};
    w.print("Title:   {s}\n", .{issue.title}) catch {};
    w.print("Author:  {s} <{s}>\n", .{ issue.author.name, issue.author.email }) catch {};
    w.print(
        "Created: {f}\n",
        .{common.IsoDate{ .time = issue.author.time, .tz = issue.author.tz_offset_minutes }},
    ) catch {};
    if (issue.labels.len > 0) w.print(
        "Labels:  {s}\n",
        .{labels_fmt.join(arena, issue.labels) catch ""},
    ) catch {};
    for (header_fields) |key| {
        if (issue.field(key)) |v| w.print("{s}: {s}\n", .{ key, v }) catch {};
    }
    for (issue.fields) |f| {
        if (isHeaderField(f.key)) continue;
        w.print("{s}: {s}\n", .{ f.key, f.value }) catch {};
    }
    for (issue.conflicts) |c| {
        w.print(
            "Conflict: {s} was edited concurrently; kept '{s}', not '{s}'\n",
            .{ c.field, c.value, c.lost },
        ) catch {};
    }
    if (issue.description.len > 0) w.print("\n{s}\n", .{issue.description}) catch {};

    if (issue.comments.len > 0) {
        w.print(
            "\n{s}\nUpdates ({d}):\n{s}\n",
            .{ rule_light, issue.comments.len, rule_light },
        ) catch {};
        for (issue.comments) |c| {
            w.print(
                "\n  {s} ({f}):\n",
                .{
                    c.author.name,
                    common.IsoDate{ .time = c.author.time, .tz = c.author.tz_offset_minutes },
                },
            ) catch {};
            if (c.state_change) |s| w.print("  [State changed to: {s}]\n", .{s}) catch {};
            w.print("  {s}\n", .{c.subject}) catch {};
            for (c.text) |line| {
                if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
                w.print("  {s}\n", .{line}) catch {};
            }
        }
    }
    return common.exit_ok;
}

fn isHeaderField(key: []const u8) bool {
    for (header_fields) |h| if (std.mem.eql(u8, h, key)) return true;
    return false;
}

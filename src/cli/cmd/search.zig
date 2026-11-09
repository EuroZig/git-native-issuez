//! `git issue search <pattern> [options]`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const issuez = @import("issuez");
const json = @import("../json.zig");
const uuid = issuez.format.uuid;

pub const help =
    \\usage: git issue search <pattern> [options]
    \\
    \\Search issue titles, fields, descriptions and comments for a fixed string.
    \\Edited text is searched as edited; deleted comments are left out.
    \\
    \\Options:
    \\   -s, --state <state>   open, closed, any custom state, or all [default: all]
    \\   -i, --ignore-case     Case-insensitive search
    \\   --json                JSON array of {issue, matches} (docs/json.md)
    \\   -h, --help            Show this help
    \\
;

const max_shown = 5;

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var pattern: ?[]const u8 = null;
    var state_filter: ?issuez.format.core.State = null;
    var ignore_case = false;
    var as_json = false;

    const flags = [_]common.Flag{
        .{ "-i --ignore-case", .{ .on = &ignore_case } },
        .{ "--json", .{ .on = &as_json } },
    };
    var parser = common.argParser(ctx, argv, .{
        .command = "search",
        .help = help,
        .positionals = .{ .first = &pattern },
        .flags = &flags,
    });
    while (parser.next()) |arg| {
        if (!common.isFlag(arg, "-s --state")) return parser.unknown(arg);
        state_filter = common.stateFilter(parser.value("-s") orelse return common.exit_error);
    }
    if (parser.exit) |exit| return exit;
    const needle = pattern orelse
        return common.missing(ctx.err, "search", "search pattern is required");
    if (needle.len == 0) return common.missing(ctx.err, "search", "search pattern is required");

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const issues = repo.loadAll(arena) catch |e| return common.repoFailed(B, ctx, e);
    if (issues.len == 0 and !as_json) {
        ctx.out.writeAll("No issues found.\n") catch {};
        return common.exit_ok;
    }
    var s = json.begin(ctx.out);
    if (as_json) s.beginArray() catch |e| return json.failed(ctx.err, e);

    const filter: issuez.query.Filter = .{ .state = state_filter, .done = null };
    for (issues) |issue| {
        if (!filter.matches(issue)) continue;
        const lines = issuez.query.searchLines(arena, issue, needle, .{
            .ignore_case = ignore_case,
        }) catch return common.oom(ctx.err);
        if (lines.len == 0) continue;
        if (as_json) {
            writeMatch(&s, arena, issue, lines, repo.doneStates()) catch |e|
                return json.failed(ctx.err, e);
            continue;
        }
        ctx.out.print(
            "{s} [{s}] {s}\n",
            .{ uuid.shortId(issue.id), issue.state.text(), issue.title },
        ) catch {};
        for (lines[0..@min(lines.len, max_shown)], 1..) |line, n| {
            ctx.out.print("       {d}:{s}\n", .{ n, line }) catch {};
        }
        const shown = lines.len;
        if (shown > max_shown) ctx.out.print(
            "       ... {d} more matching lines\n",
            .{shown - max_shown},
        ) catch {};
    }
    if (as_json) {
        s.endArray() catch |e| return json.failed(ctx.err, e);
        json.end(&s) catch |e| return json.failed(ctx.err, e);
    }
    return common.exit_ok;
}

fn writeMatch(
    s: *json.Stringify,
    arena: std.mem.Allocator,
    issue: issuez.engine.Issue,
    lines: []const []const u8,
    done_states: []const []const u8,
) json.Error!void {
    try s.beginObject();
    try s.objectField("issue");
    try json.issue(s, arena, issue, .{ .done_states = done_states });
    try json.field(s, "matches", lines);
    try s.endObject();
}

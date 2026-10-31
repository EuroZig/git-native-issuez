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
const attach = @import("attach.zig");
const ext_flags = @import("../ext_flags.zig");

pub const help =
    \\usage: git issue show <issue-id>
    \\
    \\Show an issue with its comments and updates. Deleted comments are left
    \\out; edited ones show their current text.
    \\
    \\   <issue-id>    Full UUID or a unique prefix
    \\   --ids         Show each update's comment ID (for comment --edit, ...)
    \\   -h, --help    Show this help
    \\
;

const rule_heavy = "============================================================";
const rule_light = "------------------------------------------------------------";

const header_fields = [_][]const u8{ "Assignee", "Priority", "Milestone" };

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var issue_prefix: ?[]const u8 = null;
    var ids = false;
    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            if (args.was_separator) continue;
            if (issue_prefix == null) issue_prefix = arg;
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "--ids")) {
            ids = true;
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
        "Issue {s} [{s}]{s}\n{s}\n",
        .{
            uuid.shortId(issue.id),
            issue.state.text(),
            if (issue.deleted) " (deleted)" else "",
            rule_heavy,
        },
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
        if (isHeaderField(f.key) or isExtensionField(f.key)) continue;
        w.print("{s}: {s}\n", .{ f.key, f.value }) catch {};
    }
    printExtensions(B, repo, arena, w, issue);
    for (issue.conflicts) |c| {
        w.print(
            "Conflict: {f} was edited concurrently; kept '{s}', not '{s}'\n",
            .{ c.target, c.value, c.lost },
        ) catch {};
    }
    printProblems(B, ctx, repo, issue);
    if (issue.attachments.len > 0) {
        w.print("Attachments ({d}):\n", .{issue.attachments.len}) catch {};
        for (issue.attachments) |a| w.print("  {s}  {s:<10}  {f}  {s}\n", .{
            uuid.shortId(a.id),
            a.media.mediaType(),
            attach.Size{ .bytes = a.size },
            a.name,
        }) catch {};
    }
    if (issue.description.len > 0) w.print("\n{s}\n", .{issue.description}) catch {};

    var shown: usize = 0;
    for (issue.comments) |c| {
        if (!c.deleted) shown += 1;
    }
    if (shown > 0) {
        w.print(
            "\n{s}\nUpdates ({d}):\n{s}\n",
            .{ rule_light, shown, rule_light },
        ) catch {};
        for (issue.comments) |c| {
            if (c.deleted) continue;
            const hex = c.oid.hex();
            w.print(
                "\n  {s} ({f}){s}{s}{s}:\n",
                .{
                    c.author.name,
                    common.IsoDate{ .time = c.author.time, .tz = c.author.tz_offset_minutes },
                    if (c.edited) " (edited)" else "",
                    if (ids) " " else "",
                    if (ids) hex.short() else "",
                },
            ) catch {};
            if (c.state_change) |s| w.print("  [State changed to: {s}]\n", .{s.text()}) catch {};
            w.print("  {s}\n", .{c.subject}) catch {};
            for (c.text) |line| {
                if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
                // Listed below instead.
                if (std.ascii.startsWithIgnoreCase(line, "X-Attachment")) continue;
                w.print("  {s}\n", .{line}) catch {};
            }
            for (c.attachments) |id| {
                const a = for (issue.attachments) |x| {
                    if (std.mem.eql(u8, x.id, id)) break x;
                } else continue;
                w.print("  [attached {s} {s}]\n", .{ uuid.shortId(a.id), a.name }) catch {};
            }
        }
    }
    return common.exit_ok;
}

/// Shown by `printExtensions` instead of verbatim.
const extension_fields = [_][]const u8{
    "X-Parent",           "X-Start-Date",     "X-Due-Date",
    "X-Estimate-Minutes", "X-Workflow-State",
};

fn isExtensionField(key: []const u8) bool {
    for (extension_fields) |e| if (std.mem.eql(u8, e, key)) return true;
    return false;
}

fn printExtensions(
    comptime B: type,
    repo: issuez.engine.Repo(B),
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    issue: issuez.engine.Issue,
) void {
    const x = issue.ext;
    if (x.parent) |p| w.print("Parent:  {s}\n", .{reference(B, repo, arena, p)}) catch {};
    for (x.blocked_by, 0..) |b, i| w.print("{s}{s}\n", .{
        if (i == 0) "Blocked by: " else "            ",
        reference(B, repo, arena, b),
    }) catch {};
    if (x.start_date) |d| w.print("Start:   {f}\n", .{d}) catch {};
    if (x.due_date) |d| w.print("Due:     {f}\n", .{d}) catch {};
    if (x.estimate_minutes) |m| {
        w.print("Estimate: {d} min", .{m}) catch {};
        if (m >= 60) w.print(" ({d}h{s})", .{
            m / 60,
            if (m % 60 == 0) "" else std.fmt.allocPrint(arena, "{d}m", .{m % 60}) catch "",
        }) catch {};
        w.writeAll("\n") catch {};
    }
    if (x.workflow) |s| w.print("Workflow: {s}\n", .{s}) catch {};
}

fn reference(
    comptime B: type,
    repo: issuez.engine.Repo(B),
    arena: std.mem.Allocator,
    id: []const u8,
) []const u8 {
    const short = uuid.shortId(id);
    const res = repo.resolve(arena, id) catch return short;
    const ref = switch (res) {
        .one => |r| r,
        else => return std.fmt.allocPrint(arena, "{s} (not found locally)", .{short}) catch short,
    };
    const target = repo.load(arena, ref) catch return short;
    return std.fmt.allocPrint(arena, "{s} {s}", .{ short, target.title }) catch short;
}

/// Problems can come from other issues too, like an open child of a
/// closed issue, so this always builds the projection.
fn printProblems(
    comptime B: type,
    ctx: *context.Context(B),
    repo: issuez.engine.Repo(B),
    issue: issuez.engine.Issue,
) void {
    const proj = ext_flags.project(B, ctx, repo) orelse return;
    const i = proj.find(issue.id) orelse return;
    for (proj.problemsOf(i)) |p| ctx.out.print(
        "Problem: {s}\n",
        .{ext_flags.describeProblem(ctx.arena, p)},
    ) catch {};
}

fn isHeaderField(key: []const u8) bool {
    for (header_fields) |h| if (std.mem.eql(u8, h, key)) return true;
    return false;
}

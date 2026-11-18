//! `git issue show <issue-id>`
//!
//! Upstream's layout. Values come from the whole history, so Assignee,
//! Priority and Milestone don't vanish after later updates like they do
//! upstream. On a terminal the description and comments are rendered as
//! Markdown; anywhere else they are the text as it is, like upstream's.

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const issuez = @import("issuez");
const labels_fmt = issuez.format.labels;
const uuid = issuez.format.uuid;
const attach = @import("attach.zig");
const ext_flags = @import("../ext_flags.zig");
const json = @import("../json.zig");
const build_options = @import("build_options");
const term = if (build_options.markdown) @import("markdown-term") else struct {};

pub const help =
    \\usage: git issue show <issue-id>
    \\
    \\Show an issue with its comments and updates. Deleted comments are left
    \\out; edited ones show their current text.
    \\
    \\   <issue-id>    Full UUID or a unique prefix
    \\   --ids         Show each update's comment ID (for comment --edit, ...)
    \\   --history     Also every earlier version of the description and of
    \\                 edited, deleted or restored comments
    \\   --json        The issue as JSON, comments included (docs/json.md)
    \\   --raw         The description and comments as they are, not rendered
    \\   --color <when>
    \\                 auto (the default): rendered as Markdown on a terminal,
    \\                 styled unless NO_COLOR is set; always: rendered and
    \\                 styled, a pipe too; never: not styled
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
    var with_history = false;
    var as_json = false;
    var raw = false;
    var color_mode: ?[]const u8 = null;
    if (common.parseArgs(ctx, argv, .{
        .command = "show",
        .help = help,
        .positionals = .{ .first = &issue_prefix },
        .flags = &.{
            .{ "--ids", .{ .on = &ids } },
            .{ "--history", .{ .on = &with_history } },
            .{ "--json", .{ .on = &as_json } },
            .{ "--raw", .{ .on = &raw } },
            .{ "--color", .{ .text = &color_mode } },
        },
    })) |exit| return exit;
    const color = std.meta.stringToEnum(Color, color_mode orelse "auto") orelse
        return common.fail(ctx.err, "error: --color takes auto, always or never\n");
    const prefix = issue_prefix orelse
        return common.missing(ctx.err, "show", "issue ID is required");

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const ref = common.resolveOne(B, repo, arena, ctx.err, prefix) orelse return common.exit_error;
    const issue = repo.load(arena, ref) catch |e| return common.repoFailed(B, ctx, e);

    if (as_json) {
        const proj = ext_flags.projectAround(B, ctx, repo, ref) orelse return common.exit_error;
        var s = json.begin(ctx.out);
        json.issue(&s, arena, issue, .{ .full = true, .projection = proj }) catch |e|
            return json.failed(ctx.err, e);
        json.end(&s) catch |e| return json.failed(ctx.err, e);
        return common.exit_ok;
    }
    const w = ctx.out;
    const style = styleFor(B, ctx, raw, color);
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
    if (issue.number) |n| w.print("Number:  #{d}\n", .{n}) catch {};
    if (issue.locked) w.print("Locked{s}{s}\n", .{
        if (issue.lock_reason != null) ": " else "",
        issue.lock_reason orelse "",
    }) catch {};
    if (issue.ref) |r| w.print("Ref:     {s}\n", .{r}) catch {};
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
    if (issue.assignees.len > 1) {
        w.writeAll("Assignees:") catch {};
        for (
            issue.assignees,
            0..,
        ) |a, k| w.print("{s} {s}", .{ if (k == 0) "" else ",", a.email }) catch {};
        w.writeAll("\n") catch {};
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
    printProblems(B, ctx, repo, ref, issue);
    if (issue.attachments.len > 0) {
        w.print("Attachments ({d}):\n", .{issue.attachments.len}) catch {};
        for (issue.attachments) |a| w.print("  {s}  {s:<10}  {f}  {s}\n", .{
            uuid.shortId(a.id),
            a.media.mediaType(),
            attach.Size{ .bytes = a.size },
            a.name,
        }) catch {};
    }
    for (issue.reactions) |r| if (r.target == null) {
        w.print("Reaction {s}: {d}\n", .{ r.emoji, r.users.len }) catch {};
    };
    if (issue.description.len > 0) {
        w.writeAll("\n") catch {};
        if (style) |st| {
            render(ctx, w, issue.description, st, 0);
        } else w.print("{s}\n", .{issue.description}) catch {};
    }
    if (with_history and issue.description_history.len > 1) {
        w.writeAll("\nDescription history:\n") catch {};
        printHistory(w, issue.description_history);
    }

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
                "\n  {s} ({f}){s}{s}{s}{s}:\n",
                .{
                    c.author.name,
                    common.IsoDate{ .time = c.author.time, .tz = c.author.tz_offset_minutes },
                    if (c.edited) " (edited)" else "",
                    if (c.purged) " (purged)" else "",
                    if (ids) " " else "",
                    if (ids) hex.short() else "",
                },
            ) catch {};
            if (c.state_change) |s| w.print("  [State changed to: {s}]\n", .{s.text()}) catch {};
            if (style) |st| {
                var text: std.ArrayList(u8) = .empty;
                // The subject is the text's first paragraph.
                text.appendSlice(arena, c.subject) catch {};
                if (c.body.len > 0) text.append(arena, '\n') catch {};
                for (c.body) |line| {
                    if (isPurgeLine(line)) continue;
                    text.append(arena, '\n') catch {};
                    text.appendSlice(arena, line) catch {};
                }
                render(ctx, w, text.items, st, 2);
            } else w.print("  {s}\n", .{c.subject}) catch {};
            if (style == null) for (c.text) |line| {
                if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
                if (isPurgeLine(line)) continue;
                w.print("  {s}\n", .{line}) catch {};
            };
            for (c.attachments) |id| {
                const a = for (issue.attachments) |x| {
                    if (std.mem.eql(u8, x.id, id)) break x;
                } else continue;
                w.print("  [attached {s} {s}]\n", .{ uuid.shortId(a.id), a.name }) catch {};
            }
            if (with_history and c.history.len > 1) printHistory(w, c.history);
        }
    }
    if (with_history) for (issue.comments) |c| {
        if (!c.deleted or c.history.len < 2) continue;
        const hex = c.oid.hex();
        w.print("\n  Deleted comment {s}:\n", .{hex.short()}) catch {};
        printHistory(w, c.history);
    };
    return common.exit_ok;
}

const Color = enum { auto, always, never };

/// How the description and comments are rendered: null for as they are.
const Style = struct { width: u16, color: bool };

/// Rendered on a terminal (or with --color always), not with --raw; styled
/// unless NO_COLOR is set or --color=never. Only git-issue renders, not
/// the simulator.
fn styleFor(comptime B: type, ctx: anytype, raw: bool, color: Color) ?Style {
    if (!build_options.markdown or raw) return null;
    if (B != issuez.backend.GitProcess) return null;
    const stdout = std.Io.File.stdout();
    const tty = stdout.isTty(ctx.io) catch false;
    if (!tty and color != .always) return null;
    const no_color = if (ctx.environ_map.get("NO_COLOR")) |v| v.len > 0 else false;
    return .{
        .width = terminalWidth(ctx, stdout) orelse 80,
        .color = switch (color) {
            .always => true,
            .never => false,
            .auto => !no_color,
        },
    };
}

/// The terminal's columns, else $COLUMNS.
fn terminalWidth(ctx: anytype, file: std.Io.File) ?u16 {
    if (@import("builtin").os.tag != .windows) {
        var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const rc = std.posix.system.ioctl(
            file.handle,
            std.posix.T.IOCGWINSZ,
            @intFromPtr(&ws),
        );
        if (std.posix.errno(rc) == .SUCCESS and ws.col > 0) return ws.col;
    }
    const columns = ctx.environ_map.get("COLUMNS") orelse return null;
    const n = std.fmt.parseInt(u16, columns, 10) catch return null;
    return if (n > 0) n else null;
}

/// `text` as Markdown, each line indented by `indent` columns. A text larger
/// than git issue writes is shown as it is.
fn render(ctx: anytype, w: *std.Io.Writer, text: []const u8, style: Style, indent: u16) void {
    if (!build_options.markdown) unreachable;
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    if (text.len > (issuez.Limits{}).max_body_bytes) {
        out.writer.writeAll(text) catch {};
    } else term.renderText(ctx.gpa, &out.writer, text, .{
        .width = @max(style.width -| indent, 20),
        .color = style.color,
    }) catch {
        w.print("{s}\n", .{text}) catch {};
        return;
    };
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out.written(), "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len > 0) w.splatByteAll(' ', indent) catch {};
        w.print("{s}\n", .{line}) catch {};
    }
}

/// Each version with its author and date, the text indented.
fn printHistory(w: *std.Io.Writer, list: []const issuez.model.issue.Revision) void {
    for (list) |r| {
        const hex = r.oid.hex();
        w.print("    {s} {s} by {s} ({f}):\n", .{
            @tagName(r.kind),
            hex.short(),
            r.author.name,
            common.IsoDate{ .time = r.author.time, .tz = r.author.tz_offset_minutes },
        }) catch {};
        var lines = std.mem.splitScalar(u8, r.text, '\n');
        while (lines.next()) |line| w.print("      {s}\n", .{line}) catch {};
    }
}

/// Shown by `printExtensions` instead of verbatim.
const extension_fields = [_][]const u8{
    "X-Parent", "X-Start-Date",       "X-Due-Date",
    "X-Number", "X-Locked",           "X-Lock-Reason",
    "X-Ref",    "X-Estimate-Minutes", "X-Workflow-State",
    "X-Rank",
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
    const x = issue.extensions();
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
    if (x.rank) |r| w.print("Rank:    {s}\n", .{r}) catch {};
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
/// closed issue, so this always projects the issues around it.
fn printProblems(
    comptime B: type,
    ctx: *context.Context(B),
    repo: issuez.engine.Repo(B),
    ref: issuez.engine.IssueRef,
    issue: issuez.engine.Issue,
) void {
    const proj = ext_flags.projectAround(B, ctx, repo, ref) orelse return;
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

/// What a purge wrote about the commit (format.md §10), not its text.
fn isPurgeLine(line: []const u8) bool {
    const sep = issuez.format.trailers.separatorPos(line) orelse return false;
    const key = std.mem.trimEnd(u8, line[0..sep], " \t");
    return std.ascii.eqlIgnoreCase(key, "X-Purged") or
        std.ascii.eqlIgnoreCase(key, "X-Rewritten-From");
}

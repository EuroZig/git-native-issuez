//! `git issue tree [<issue-id>] [--all]`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const ext_flags = @import("../ext_flags.zig");
const issuez = @import("issuez");
const uuid = issuez.format.uuid;
const Projection = issuez.projection.Projection;

pub const help =
    \\usage: git issue tree [<issue-id>] [options]
    \\
    \\Show issues as a parent/child tree (--parent), with progress over each
    \\parent's leaves, blockers (--blocked-by) and problems such as a parent
    \\that loops back. Without <issue-id>, every top-level issue.
    \\
    \\Options:
    \\   -a, --all     Also show closed issues without open descendants, and
    \\                 deleted issues (otherwise their sub-issues take their place)
    \\   -h, --help    Show this help
    \\
;

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    var prefix: ?[]const u8 = null;
    var all = false;
    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            if (args.was_separator) continue;
            if (prefix != null) return common.missing(ctx.err, "tree", "only one issue");
            prefix = arg;
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else {
            return common.unknownOption(ctx.err, "tree", arg);
        }
    }

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const proj = ext_flags.project(B, ctx, repo) orelse return common.exit_error;
    var start: []const u32 = proj.roots;
    var single: [1]u32 = undefined;
    if (prefix) |p| {
        const ref = common.resolveOne(B, repo, ctx.arena, ctx.err, p) orelse
            return common.exit_error;
        single[0] = proj.find(ref.id()).?;
        start = &single;
        all = true; // an explicit subtree is shown whole
    }
    var printer: Printer = .{ .ctx_out = ctx.out, .arena = ctx.arena, .proj = proj, .all = all };
    var top: std.ArrayList(u32) = .empty;
    for (start) |r| {
        if (!all and proj.issues[r].deleted) {
            printer.shownChildren(r, &top) catch return common.oom(ctx.err);
        } else if (printer.visible(r)) top.append(ctx.arena, r) catch return common.oom(ctx.err);
    }
    if (proj.issues.len == 0) {
        ctx.out.writeAll("No issues found.\n") catch {};
        return common.exit_ok;
    }
    for (top.items) |r| printer.node(r, "", "") catch return common.exit_error;
    return common.exit_ok;
}

const branch = "├── ";
const last_branch = "└── ";
const pipe = "│   ";
const gap = "    ";

const Printer = struct {
    ctx_out: *std.Io.Writer,
    arena: std.mem.Allocator,
    proj: Projection,
    all: bool,

    /// Closed issues with nothing open below them are hidden without --all.
    fn visible(p: Printer, i: u32) bool {
        if (p.all) return true;
        const issue = p.proj.issues[i];
        if (!issuez.projection.isClosed(issue) and !issue.deleted) return true;
        for (p.proj.children[i]) |c| if (p.visible(c)) return true;
        return false;
    }

    /// Without --all, a deleted child is replaced by its own children.
    fn shownChildren(p: *Printer, i: u32, out: *std.ArrayList(u32)) !void {
        for (p.proj.children[i]) |c| {
            if (!p.all and p.proj.issues[c].deleted) {
                try p.shownChildren(c, out);
            } else if (p.visible(c)) try out.append(p.arena, c);
        }
    }

    fn node(p: *Printer, i: u32, lead: []const u8, child_lead: []const u8) !void {
        const issue = p.proj.issues[i];
        const w = p.ctx_out;
        const short = uuid.shortId(issue.id);
        try w.print("{s}{s} [{s}] {s}{s}", .{
            lead,
            short,
            issue.state.text(),
            issue.title,
            if (issue.deleted) " (deleted)" else "",
        });
        if (try p.proj.progress(p.arena, i)) |pr| if (pr.total > 0) {
            try w.print("  ({d}/{d} done)", .{ pr.closed, pr.total });
        };
        if (p.proj.activelyBlocked(i)) {
            try w.writeAll("  [blocked by");
            for (p.proj.blockers[i]) |b| {
                if (!issuez.projection.isClosed(p.proj.issues[b]))
                    try w.print(" {s}", .{uuid.shortId(p.proj.issues[b].id)});
            }
            try w.writeAll("]");
        }
        try w.writeAll("\n");
        for (try p.proj.problemsOf(p.arena, i)) |pr| {
            try w.print("{s}  ! {s}\n", .{ child_lead, ext_flags.describeProblem(p.arena, pr) });
        }
        var shown: std.ArrayList(u32) = .empty;
        try p.shownChildren(i, &shown);
        for (shown.items, 0..) |c, k| {
            const last = k + 1 == shown.items.len;
            const own = if (last) last_branch else branch;
            const below = if (last) gap else pipe;
            try p.node(
                c,
                try std.mem.concat(p.arena, u8, &.{ child_lead, own }),
                try std.mem.concat(p.arena, u8, &.{ child_lead, below }),
            );
        }
    }
};

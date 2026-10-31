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
    var printer: Printer = .{
        .ctx_out = ctx.out,
        .arena = ctx.arena,
        .proj = proj,
        .all = all,
        .shown = Printer.visibility(ctx.arena, proj, all) catch return common.oom(ctx.err),
    };
    var top: std.ArrayList(u32) = .empty;
    for (start) |r| {
        if (!all and proj.issues[r].deleted) {
            printer.shownChildren(r, &top) catch return common.oom(ctx.err);
        } else if (printer.shown[r]) top.append(ctx.arena, r) catch return common.oom(ctx.err);
    }
    if (proj.issues.len == 0) {
        ctx.out.writeAll("No issues found.\n") catch {};
        return common.exit_ok;
    }
    printer.nodes(top.items) catch return common.exit_error;
    return common.exit_ok;
}

const branch = "├── ";
const last_branch = "└── ";
const pipe = "│   ";
const gap = "    ";

/// Iterative throughout: graphs from other tools can be deep.
const Printer = struct {
    ctx_out: *std.Io.Writer,
    arena: std.mem.Allocator,
    proj: Projection,
    all: bool,
    /// Per issue. Without --all, done issues with nothing open below them
    /// are hidden.
    shown: []const bool,

    fn visibility(arena: std.mem.Allocator, proj: Projection, all: bool) ![]const bool {
        const out = try arena.alloc(bool, proj.issues.len);
        var order: std.ArrayList(u32) = .empty;
        var stack: std.ArrayList(u32) = .empty;
        try stack.appendSlice(arena, proj.roots);
        while (stack.pop()) |i| {
            try order.append(arena, i);
            try stack.appendSlice(arena, proj.children[i]);
        }
        var k = order.items.len;
        while (k > 0) { // children first
            k -= 1;
            const i = order.items[k];
            out[i] = all or proj.isActive(i);
            for (proj.children[i]) |c| if (out[c]) {
                out[i] = true;
            };
        }
        return out;
    }

    /// Without --all, a deleted child is replaced by its own children.
    fn shownChildren(p: *Printer, i: u32, out: *std.ArrayList(u32)) !void {
        var stack: std.ArrayList(u32) = .empty;
        var k = p.proj.children[i].len;
        while (k > 0) : (k -= 1) try stack.append(p.arena, p.proj.children[i][k - 1]);
        while (stack.pop()) |c| {
            if (!p.all and p.proj.issues[c].deleted) {
                var j = p.proj.children[c].len;
                while (j > 0) : (j -= 1) try stack.append(p.arena, p.proj.children[c][j - 1]);
            } else if (p.shown[c]) try out.append(p.arena, c);
        }
    }

    fn nodes(p: *Printer, top: []const u32) !void {
        const Frame = struct { nodes: []const u32, next: usize = 0, lead: ?[]const u8 };
        var stack: std.ArrayList(Frame) = .empty;
        try stack.append(p.arena, .{ .nodes = top, .lead = null });
        while (stack.items.len > 0) {
            const f = &stack.items[stack.items.len - 1];
            if (f.next == f.nodes.len) {
                _ = stack.pop();
                continue;
            }
            const i = f.nodes[f.next];
            f.next += 1;
            // Top-level nodes have no branch.
            var lead: []const u8 = "";
            var child_lead: []const u8 = "";
            if (f.lead) |base| {
                const last = f.next == f.nodes.len;
                lead = try std.mem.concat(p.arena, u8, &.{ base, if (last) last_branch else branch });
                child_lead = try std.mem.concat(p.arena, u8, &.{ base, if (last) gap else pipe });
            }
            try p.line(i, lead, child_lead);
            var shown: std.ArrayList(u32) = .empty;
            try p.shownChildren(i, &shown);
            try stack.append(p.arena, .{ .nodes = shown.items, .lead = child_lead });
        }
    }

    fn line(p: *Printer, i: u32, lead: []const u8, child_lead: []const u8) !void {
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
        if (p.proj.progress(i)) |pr| {
            try w.print("  ({d}/{d} done)", .{ pr.closed, pr.total });
        }
        const blockers = try p.proj.activeBlockers(p.arena, i);
        if (p.proj.activelyBlocked(i)) {
            try w.writeAll("  [blocked by");
            for (blockers) |b| try w.print(" {s}", .{uuid.shortId(p.proj.issues[b].id)});
            try w.writeAll("]");
        }
        try w.writeAll("\n");
        for (p.proj.problemsOf(i)) |pr| {
            try w.print("{s}  ! {s}\n", .{ child_lead, ext_flags.describeProblem(p.arena, pr) });
        }
    }
};

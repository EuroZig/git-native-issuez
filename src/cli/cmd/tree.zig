//! `git issue tree [<issue-id>] [--all]`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const ext_flags = @import("../ext_flags.zig");
const issuez = @import("issuez");
const json = @import("../json.zig");
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
    \\   --json        Nested {issue, children} nodes as JSON (docs/json.md)
    \\   -h, --help    Show this help
    \\
;

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    var prefix: ?[]const u8 = null;
    var all = false;
    var as_json = false;
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
        } else if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
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
    const top = printer.topNodes(start) catch return common.oom(ctx.err);
    if (as_json) {
        var s = json.begin(ctx.out);
        printer.jsonNodes(&s, top) catch |e| return json.failed(ctx.err, e);
        json.end(&s);
        return common.exit_ok;
    }
    if (proj.issues.len == 0) {
        ctx.out.writeAll("No issues found.\n") catch {};
        return common.exit_ok;
    }
    printer.nodes(top) catch return common.exit_error;
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

    /// The shown ones of `start`, a deleted one replaced like a child.
    fn topNodes(p: *Printer, start: []const u32) ![]const u32 {
        var top: std.ArrayList(u32) = .empty;
        for (start) |r| {
            if (!p.all and p.proj.issues[r].deleted) {
                try p.shownChildren(r, &top);
            } else if (p.shown[r]) try top.append(p.arena, r);
        }
        return top.items;
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

    /// Depth first over the shown nodes, children in order: `v.enter`
    /// before a node's children gets the state its parent's `enter`
    /// returned (null at the top), `v.leave` after them.
    fn walk(p: *Printer, top: []const u32, v: anytype) !void {
        const State = @TypeOf(v.*).State;
        const Frame = struct { nodes: []const u32, next: usize = 0, state: ?State };
        var stack: std.ArrayList(Frame) = .empty;
        try stack.append(p.arena, .{ .nodes = top, .state = null });
        while (stack.items.len > 0) {
            const f = &stack.items[stack.items.len - 1];
            if (f.next == f.nodes.len) {
                _ = stack.pop();
                // The node that owned these children.
                if (stack.items.len > 0) try v.leave();
                continue;
            }
            const i = f.nodes[f.next];
            f.next += 1;
            const state = try v.enter(i, f.next == f.nodes.len, f.state);
            var shown: std.ArrayList(u32) = .empty;
            try p.shownChildren(i, &shown);
            try stack.append(p.arena, .{ .nodes = shown.items, .state = state });
        }
    }

    fn jsonNodes(p: *Printer, s: *json.Stringify, top: []const u32) !void {
        const Nodes = struct {
            p: *Printer,
            s: *json.Stringify,
            const State = void;
            fn enter(n: *@This(), i: u32, _: bool, _: ?void) !void {
                try n.s.beginObject();
                try n.s.objectField("issue");
                try json.issue(n.s, n.p.arena, n.p.proj.issues[i], .{ .projection = n.p.proj });
                try n.s.objectField("children");
                try n.s.beginArray();
            }
            fn leave(n: *@This()) !void {
                try n.s.endArray();
                try n.s.endObject();
            }
        };
        var v: Nodes = .{ .p = p, .s = s };
        try s.beginArray();
        try p.walk(top, &v);
        try s.endArray();
    }

    fn nodes(p: *Printer, top: []const u32) !void {
        const Lines = struct {
            p: *Printer,
            /// The lead of the children's lines. Top-level nodes have no branch.
            const State = []const u8;
            fn enter(l: *@This(), i: u32, last: bool, base: ?[]const u8) ![]const u8 {
                const arena = l.p.arena;
                var lead: []const u8 = "";
                var child_lead: []const u8 = "";
                if (base) |b| {
                    lead = try std.mem.concat(arena, u8, &.{ b, if (last) last_branch else branch });
                    child_lead = try std.mem.concat(arena, u8, &.{ b, if (last) gap else pipe });
                }
                try l.p.line(i, lead, child_lead);
                return child_lead;
            }
            fn leave(_: *@This()) !void {}
        };
        var v: Lines = .{ .p = p };
        try p.walk(top, &v);
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

const testing = std.testing;
const GitSim = issuez.backend.GitSim;

test "tree --json nodes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 11, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = issuez.Repo(GitSim).init(&sim);
    const root = try repo.create(arena, .{ .title = "Root" });
    for ([_][]const u8{ "Open", "Done", "Gone" }) |t| {
        _ = try repo.create(arena, .{ .title = t, .parent = root.id.slice() });
    }
    const gone = for (try repo.loadAll(arena)) |i| {
        if (std.mem.eql(u8, i.title, "Gone")) break i.id;
    } else unreachable;
    _ = try repo.create(arena, .{ .title = "Orphan", .parent = gone });
    _ = try repo.create(arena, .{ .title = "Old" });
    const issues = try repo.loadAll(arena);
    for (issues) |*i| {
        if (std.mem.eql(u8, i.title, "Done") or std.mem.eql(u8, i.title, "Old")) i.state = .closed;
        if (std.mem.eql(u8, i.title, "Gone")) i.deleted = true;
    }
    const proj = try issuez.projection.build(arena, issues, .{});

    const Node = struct { title: []const u8, children: []const @This() };
    const render = struct {
        fn f(a: std.mem.Allocator, pr: Projection, all: bool) ![]const Node {
            var p: Printer = .{
                .ctx_out = undefined,
                .arena = a,
                .proj = pr,
                .all = all,
                .shown = try Printer.visibility(a, pr, all),
            };
            var out: std.Io.Writer.Allocating = .init(a);
            var s = json.begin(&out.writer);
            try p.jsonNodes(&s, try p.topNodes(pr.roots));
            const v = try std.json.parseFromSliceLeaky(std.json.Value, a, out.written(), .{});
            return nodes(a, v);
        }
        fn nodes(a: std.mem.Allocator, v: std.json.Value) ![]const Node {
            var list: std.ArrayList(Node) = .empty;
            for (v.array.items) |n| {
                const keys = n.object.keys();
                try testing.expectEqual(@as(usize, 2), keys.len);
                try testing.expectEqualStrings("issue", keys[0]);
                try testing.expectEqualStrings("children", keys[1]);
                const issue = n.object.get("issue").?.object;
                // Issues carry the projection fields.
                try testing.expect(issue.get("progress") != null);
                try list.append(a, .{
                    .title = issue.get("title").?.string,
                    .children = try nodes(a, n.object.get("children").?),
                });
            }
            // The projection's order isn't the point here.
            std.mem.sort(Node, list.items, {}, struct {
                fn lt(_: void, x: Node, y: Node) bool {
                    return std.mem.lessThan(u8, x.title, y.title);
                }
            }.lt);
            return list.items;
        }
    }.f;
    const expect = struct {
        fn f(want: []const u8, got: []const Node) !void {
            var buf: std.Io.Writer.Allocating = .init(testing.allocator);
            defer buf.deinit();
            try show(&buf.writer, got);
            try testing.expectEqualStrings(want, buf.written());
        }
        fn show(w: *std.Io.Writer, got: []const Node) !void {
            for (got, 0..) |n, k| {
                if (k > 0) try w.writeAll(" ");
                try w.writeAll(n.title);
                if (n.children.len == 0) continue;
                try w.writeAll("(");
                try show(w, n.children);
                try w.writeAll(")");
            }
        }
    }.f;
    // Done subtrees with nothing open are left out; a deleted issue's
    // children take its place.
    try expect("Root(Open Orphan)", try render(arena, proj, false));
    try expect("Old Root(Done Gone(Orphan) Open)", try render(arena, proj, true));
}

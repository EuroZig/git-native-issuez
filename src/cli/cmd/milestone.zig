//! `git issue milestone <subcommand> ...`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const ext_flags = @import("../ext_flags.zig");
const json = @import("../json.zig");
const issuez = @import("issuez");
const uuid = issuez.format.uuid;
const Status = issuez.format.fields.MilestoneStatus;

pub const help =
    \\usage: git issue milestone <subcommand> [options]
    \\
    \\Manage milestones. They live in refs/milestones/ and sync with the
    \\issues. A milestone is named by an ID prefix or its exact name (a
    \\retired one by its ID only).
    \\
    \\Subcommands:
    \\   create <name>       Create a milestone (--due, -m)
    \\   ls                  List open milestones (--all: completed and retired too)
    \\   show <milestone>    Show a milestone, its progress and its issues
    \\   edit <milestone>    Rename (--name), change --due / --no-due or --description
    \\   complete <milestone>  Mark it completed (all its issues must be closed)
    \\   reopen <milestone>  Mark a completed or retired milestone open again
    \\   retire <milestone>  Retire it: no new issues can be added
    \\
    \\Options:
    \\   --name <name>         New name (edit)
    \\   --due <date>          Due date, YYYY-MM-DD (create, edit)
    \\   --no-due              Clear the due date (edit)
    \\   --description <text>  The description (create), or replace it (edit)
    \\   -m, --message <text>  Description (create) or commit message
    \\   -a, --all             Include completed and retired milestones (ls)
    \\   --json                As JSON (ls, show; docs/json.md)
    \\   -h, --help            Show this help
    \\
;

const Sub = enum { create, ls, show, edit, complete, reopen, retire };

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    if (argv.len == 0) return common.missing(ctx.err, "milestone", "subcommand is required");
    if (common.isHelp(argv[0])) {
        ctx.out.writeAll(help) catch {};
        return common.exit_ok;
    }
    const sub = std.meta.stringToEnum(Sub, argv[0]) orelse {
        ctx.err.print("error: unknown milestone subcommand '{s}'\n", .{argv[0]}) catch {};
        return common.exit_error;
    };

    var words: std.ArrayList([]const u8) = .empty;
    var name: ?[]const u8 = null;
    var due: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var message: ?[]const u8 = null;
    var all = false;
    var as_json = false;
    var args: common.Args = .{ .list = argv[1..] };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            if (args.was_separator) continue;
            words.append(arena, arg) catch return common.oom(ctx.err);
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "--name")) {
            name = args.value(ctx.err, arg) orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "--due")) {
            due = args.value(ctx.err, arg) orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "--no-due")) {
            due = "";
        } else if (std.mem.eql(u8, arg, "--description")) {
            description = args.value(ctx.err, arg) orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            message = args.value(ctx.err, "-m") orelse return common.exit_error;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
        } else {
            return common.unknownOption(ctx.err, "milestone", arg);
        }
    }
    if (due) |d| if (d.len > 0 and issuez.format.fields.Date.parse(d) == null) {
        ctx.err.print("error: --due must be a date as YYYY-MM-DD, not '{s}'\n", .{d}) catch {};
        return common.exit_error;
    };

    if (as_json and sub != .ls and sub != .show)
        return common.missing(ctx.err, "milestone", "--json goes with ls and show");
    if (all and sub != .ls) return common.missing(ctx.err, "milestone", "--all goes with ls");
    if (name != null and sub != .edit)
        return common.missing(ctx.err, "milestone", "--name goes with edit");
    if (due != null and sub != .create and sub != .edit)
        return common.missing(ctx.err, "milestone", "--due goes with create and edit");
    if (due != null and due.?.len == 0 and sub == .create)
        return common.missing(ctx.err, "milestone", "--no-due goes with edit");
    if (description != null and sub != .create and sub != .edit)
        return common.missing(ctx.err, "milestone", "--description goes with create and edit");
    if (message != null and (sub == .ls or sub == .show))
        return common.missing(ctx.err, "milestone", "-m doesn't go with ls and show");
    if (sub == .create and description != null and message != null)
        return common.missing(ctx.err, "milestone", "give the description once");
    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const cat = issuez.Catalog(B).of(repo);
    const w = ctx.out;

    switch (sub) {
        .create => {
            const text = std.mem.join(arena, " ", words.items) catch return common.oom(ctx.err);
            if (text.len == 0) return common.missing(ctx.err, "milestone", "a name is required");
            const created = cat.create(arena, .{
                .name = text,
                .due = due,
                .description = description orelse message orelse "",
            }) catch |e| return common.repoFailed(B, ctx, e);
            w.print("Created milestone {s}: {s}\n", .{ created.id.short(), text }) catch {};
        },
        .ls => {
            const list = cat.list(arena) catch |e| return common.repoFailed(B, ctx, e);
            if (as_json) {
                var s = json.begin(w);
                s.beginArray() catch return common.exit_error;
                for (list) |m| if (all or m.status == .open) {
                    json.milestone(&s, m) catch return common.exit_error;
                };
                s.endArray() catch return common.exit_error;
                json.end(&s);
                return common.exit_ok;
            }
            for (list) |m| {
                if (!all and m.status != .open) continue;
                w.print("{s} [{t}] {s}", .{ uuid.shortId(m.id), m.status, m.name }) catch {};
                if (m.due) |d| w.print("  (due {f})", .{d}) catch {};
                w.writeAll("\n") catch {};
            }
        },
        .show, .edit, .complete, .reopen, .retire => {
            if (words.items.len == 0) {
                return common.missing(ctx.err, "milestone", "which milestone?");
            }
            const key = std.mem.join(arena, " ", words.items) catch return common.oom(ctx.err);
            const m = ext_flags.findMilestone(B, ctx, cat, key) orelse return common.exit_error;
            const short = uuid.shortId(m.id);
            switch (sub) {
                .show => if (as_json) {
                    const proj = ext_flags.project(B, ctx, repo) orelse return common.exit_error;
                    var s = json.begin(w);
                    json.milestoneDetail(&s, arena, m, proj) catch return common.exit_error;
                    json.end(&s);
                } else {
                    w.print("Milestone {s} [{t}]\n", .{ short, m.status }) catch {};
                    w.writeAll("=" ** 60 ++ "\n") catch {};
                    w.print("Name:    {s}\n", .{m.name}) catch {};
                    if (m.due) |d| w.print("Due:     {f}\n", .{d}) catch {};
                    for (m.conflicts) |c| w.print(
                        "Conflict: {f} was edited concurrently; kept '{s}', not '{s}'\n",
                        .{ c.target, c.value, c.lost },
                    ) catch {};
                    if (m.description.len > 0) w.print("\n{s}\n", .{m.description}) catch {};
                    const proj = ext_flags.project(B, ctx, repo) orelse return common.exit_error;
                    const leaves = proj.milestoneLeaves(arena, m.id) catch
                        return common.oom(ctx.err);
                    var done: usize = 0;
                    for (leaves) |i| {
                        if (proj.isDone(i)) done += 1;
                    }
                    var members: std.ArrayList(issuez.engine.Issue) = .empty;
                    for (proj.issues, proj.milestone) |issue, in| {
                        if (issue.deleted) continue;
                        if (!std.mem.eql(u8, in orelse continue, m.id)) continue;
                        members.append(arena, issue) catch return common.oom(ctx.err);
                    }
                    w.print("\nProgress: {d}/{d} done\n", .{ done, leaves.len }) catch {};
                    if (members.items.len > 0) {
                        w.print("\nIssues ({d}):\n", .{members.items.len}) catch {};
                    }
                    for (members.items) |issue| w.print(
                        "  {s} [{s}] {s}\n",
                        .{ uuid.shortId(issue.id), issue.state.text(), issue.title },
                    ) catch {};
                },
                .edit => {
                    if (name == null and due == null and description == null) {
                        return common.missing(ctx.err, "milestone", "nothing to edit");
                    }
                    _ = cat.edit(arena, m.id, .{
                        .name = name,
                        .due = due,
                        .description = description,
                        .message = message,
                    }) catch |e| return common.repoFailed(B, ctx, e);
                    w.print("Updated milestone {s}\n", .{short}) catch {};
                },
                .complete, .reopen, .retire => {
                    const to: Status = switch (sub) {
                        .complete => .completed,
                        .retire => .retired,
                        else => .open,
                    };
                    if (m.status == to) {
                        w.print("Milestone {s} is already {t}\n", .{ short, to }) catch {};
                        return common.exit_ok;
                    }
                    _ = cat.edit(arena, m.id, .{ .status = to, .message = message }) catch |e|
                        return common.repoFailed(B, ctx, e);
                    w.print("Milestone {s} is {t}\n", .{ short, to }) catch {};
                },
                else => unreachable,
            }
        },
    }
    return common.exit_ok;
}

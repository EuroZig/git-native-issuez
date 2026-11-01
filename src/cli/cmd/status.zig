//! `git issue status [<remote>]`, from local state only.

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const issuez = @import("issuez");
const json = @import("../json.zig");
const sync_output = @import("../sync_output.zig");
const uuid = issuez.format.uuid;

pub const help =
    \\usage: git issue status [<remote>]
    \\
    \\Show, for each remote (or the given one), the issues not pushed yet and
    \\the quarantined issues with how to resolve them, then the local issues
    \\with fields in conflict. Uses local state only: run
    \\`git issue merge <remote>` first to see the remote's latest changes.
    \\
    \\Options:
    \\   --json        The same as JSON (docs/json.md)
    \\   -h, --help    Show this help
    \\
;

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var only: ?[]const u8 = null;
    var as_json = false;
    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            if (args.was_separator) continue;
            if (only != null) return common.missing(ctx.err, "status", "only one remote");
            only = arg;
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
        } else {
            return common.unknownOption(ctx.err, "status", arg);
        }
    }

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    const s = issuez.Sync(B).init(repo.backend);
    const w = ctx.out;
    const configured = repo.backend.remoteNames(arena) catch |e|
        return common.repoFailed(B, ctx, e);
    const remotes: []const []const u8 = if (only) |r| blk: {
        for (configured) |c| if (std.mem.eql(u8, c, r)) break :blk &.{r};
        ctx.err.print("error: remote '{s}' does not exist\n", .{r}) catch {};
        return common.exit_error;
    } else configured;
    if (as_json) {
        // All read first, so a failure leaves no partial JSON.
        const statuses = arena.alloc(issuez.sync.Status, remotes.len) catch
            return common.oom(ctx.err);
        for (remotes, statuses) |remote, *st| {
            st.* = s.status(arena, remote) catch |e| return common.repoFailed(B, ctx, e);
        }
        const issues = repo.loadAll(arena) catch |e| return common.repoFailed(B, ctx, e);
        var js = json.begin(w);
        writeJson(&js, remotes, statuses, issues) catch |e| return json.failed(ctx.err, e);
        json.end(&js);
        return common.exit_ok;
    }
    if (remotes.len == 0) w.writeAll("No remotes configured.\n") catch {};

    for (remotes) |remote| {
        const st = s.status(arena, remote) catch |e| return common.repoFailed(B, ctx, e);
        w.print("Remote {s}:\n", .{remote}) catch {};
        if (st.pending.len == 0 and st.quarantined.len == 0) {
            w.writeAll("  in sync (as of the last merge)\n") catch {};
            continue;
        }
        if (st.pending.len > 0) {
            w.print("  not pushed yet: {d}\n", .{st.pending.len}) catch {};
            for (st.pending) |ref| {
                const issue = repo.load(arena, ref) catch |e| return common.repoFailed(B, ctx, e);
                w.print("    {s} {s}\n", .{ uuid.shortId(ref.id()), issue.title }) catch {};
            }
        }
        if (st.quarantined.len > 0) {
            w.print("  quarantined: {d}\n", .{st.quarantined.len}) catch {};
            for (st.quarantined) |q| {
                var buf: [32]u8 = undefined;
                const label = sync_output.label(&buf, q.namespace, q.id);
                const short = uuid.shortId(q.id);
                const why = if (q.reason) |r| r.describe() else "clears on the next merge";
                w.print("    {s} {s} ({s}{s})\n", .{
                    label,
                    q.title,
                    why,
                    if (q.kept_local) "; kept local" else "",
                }) catch {};
                if (q.reason != null and !q.kept_local) w.print(
                    "      resolve: git issue quarantine {s} --accept-remote {s}\n" ++
                        "           or: git issue quarantine {s} --keep-local {s}\n",
                    .{ remote, short, remote, short },
                ) catch {};
            }
        }
    }

    const issues = repo.loadAll(arena) catch |e| return common.repoFailed(B, ctx, e);
    var header = false;
    for (issues) |issue| for (issue.conflicts) |c| {
        if (!header) w.writeAll("Conflicts (concurrent edits, decided by last writer):\n") catch {};
        header = true;
        w.print("  {s} {f}: kept '{s}', not '{s}'\n", .{
            uuid.shortId(issue.id),
            c.target,
            c.value,
            c.lost,
        }) catch {};
    };
    return common.exit_ok;
}

fn writeJson(
    js: *json.Stringify,
    remotes: []const []const u8,
    statuses: []const issuez.sync.Status,
    issues: []const issuez.engine.Issue,
) json.Error!void {
    try js.beginObject();
    try js.objectField("remotes");
    try js.beginArray();
    for (remotes, statuses) |remote, st| {
        try js.beginObject();
        try json.field(js, "name", remote);
        try js.objectField("pending");
        try js.beginArray();
        for (st.pending) |ref| try js.write(ref.id());
        try js.endArray();
        try js.objectField("quarantined");
        try js.beginArray();
        for (st.quarantined) |q| {
            try js.beginObject();
            try json.field(js, "id", q.id);
            try json.field(js, "kind", if (q.namespace == .milestones) "milestone" else "issue");
            try json.field(js, "title", q.title);
            const hex = q.remote_tip.hex();
            try json.field(js, "remote_tip", hex.slice());
            try json.optional(js, "reason", if (q.reason) |r| @tagName(r) else null);
            try json.field(js, "kept_local", q.kept_local);
            try js.endObject();
        }
        try js.endArray();
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("conflicts");
    try js.beginArray();
    for (issues) |issue| for (issue.conflicts) |c| try json.conflict(js, c, issue.id);
    try js.endArray();
    try js.endObject();
}

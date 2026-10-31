//! Extension flags shared by `create` and `edit`: parsed first, then
//! resolved against the repository (ID prefixes, workflow states).

const std = @import("std");
const context = @import("context.zig");
const common = @import("common.zig");
const issuez = @import("issuez");
const fields = issuez.format.fields;
const Allocator = std.mem.Allocator;

pub const help_create =
    \\   --parent <issue-id>       Make it a child of another issue
    \\   --blocked-by <issue-id>   Blocked by another issue (repeatable)
    \\   --start <date>            Start date, YYYY-MM-DD
    \\   --due <date>              Due date, YYYY-MM-DD
    \\   --estimate <duration>     Minutes, or e.g. 2h, 90m, 1h30m
    \\   --workflow <state>        Workflow state (git config issue.workflowStates;
    \\                             default backlog, ready, in-progress, review)
    \\
;

pub const help_edit = help_create ++
    \\   --unblock <issue-id>      Remove a blocker (repeatable)
    \\   --no-parent               Clear the parent
    \\   --no-blockers             Remove every blocker
    \\   --no-start                Clear the start date
    \\   --no-due                  Clear the due date
    \\   --no-estimate             Clear the estimate
    \\   --no-workflow             Clear the workflow state
    \\   --no-assignee             Clear the assignee
    \\   --no-priority             Clear the priority
    \\   --no-milestone            Clear the milestone
    \\   --no-labels               Remove every label
    \\
;

pub const Flags = struct {
    parent: ?[]const u8 = null,
    blocked_by: std.ArrayList([]const u8) = .empty,
    unblock: std.ArrayList([]const u8) = .empty,
    start: ?[]const u8 = null,
    due: ?[]const u8 = null,
    estimate: ?[]const u8 = null,
    workflow: ?[]const u8 = null,
    // edit only
    no: std.EnumSet(Clear) = .initEmpty(),

    pub const Clear = enum {
        parent,
        blockers,
        start,
        due,
        estimate,
        workflow,
        assignee,
        priority,
        milestone,
        labels,
    };

    pub const Parsed = enum { no, yes, failed };

    /// Consumes `arg` and its value when it is an extension flag.
    pub fn parse(
        f: *Flags,
        arena: Allocator,
        err: *std.Io.Writer,
        args: *common.Args,
        arg: []const u8,
        edit: bool,
    ) Parsed {
        const eql = std.mem.eql;
        const single = [_]struct { []const u8, *?[]const u8 }{
            .{ "--parent", &f.parent },
            .{ "--start", &f.start },
            .{ "--due", &f.due },
            .{ "--estimate", &f.estimate },
            .{ "--workflow", &f.workflow },
        };
        for (single) |s| if (eql(u8, arg, s[0])) {
            s[1].* = args.value(err, s[0]) orelse return .failed;
            return .yes;
        };
        if (eql(u8, arg, "--blocked-by") or (edit and eql(u8, arg, "--unblock"))) {
            const v = args.value(err, arg) orelse return .failed;
            const list = if (eql(u8, arg, "--unblock")) &f.unblock else &f.blocked_by;
            list.append(arena, v) catch return .failed;
            return .yes;
        }
        if (edit and std.mem.startsWith(u8, arg, "--no-")) {
            const which = std.meta.stringToEnum(Clear, arg["--no-".len..]) orelse return .no;
            f.no.insert(which);
            return .yes;
        }
        return .no;
    }

    pub fn any(f: Flags) bool {
        return f.parent != null or f.blocked_by.items.len > 0 or f.unblock.items.len > 0 or
            f.start != null or f.due != null or f.estimate != null or f.workflow != null or
            f.no.count() > 0;
    }

    pub const Resolved = struct {
        parent: ?[]const u8 = null,
        blocked_by: []const []const u8 = &.{},
        unblock: []const []const u8 = &.{},
        start: ?[]const u8 = null,
        due: ?[]const u8 = null,
        estimate: ?u32 = null,
        workflow: ?[]const u8 = null,
    };

    /// Reports and returns null on the first bad value.
    pub fn resolve(
        f: Flags,
        comptime B: type,
        ctx: *context.Context(B),
        repo: issuez.engine.Repo(B),
    ) ?Resolved {
        const arena = ctx.arena;
        var out: Resolved = .{};
        if (f.parent) |p| out.parent = resolveRef(B, ctx, repo, p) orelse return null;
        var blockers: std.ArrayList([]const u8) = .empty;
        for (f.blocked_by.items) |b| blockers.append(
            arena,
            resolveRef(B, ctx, repo, b) orelse return null,
        ) catch return null;
        out.blocked_by = blockers.items;
        var unblock: std.ArrayList([]const u8) = .empty;
        for (f.unblock.items) |b| unblock.append(
            arena,
            resolveRef(B, ctx, repo, b) orelse return null,
        ) catch return null;
        out.unblock = unblock.items;
        for ([_]struct { []const u8, ?[]const u8, *?[]const u8 }{
            .{ "--start", f.start, &out.start },
            .{ "--due", f.due, &out.due },
        }) |d| if (d[1]) |v| {
            if (fields.Date.parse(v) == null) {
                ctx.err.print(
                    "error: {s} must be a date as YYYY-MM-DD, not '{s}'\n",
                    .{ d[0], v },
                ) catch {};
                return null;
            }
            d[2].* = v;
        };
        if (f.estimate) |e| out.estimate = fields.parseDuration(e) orelse {
            ctx.err.print(
                "error: --estimate must be minutes or a duration like 2h, 90m, 1h30m, not '{s}'\n",
                .{e},
            ) catch {};
            return null;
        };
        if (f.workflow) |w| {
            const states = workflowStates(B, ctx, repo) orelse return null;
            for (states) |s| {
                if (std.mem.eql(u8, s, w)) out.workflow = w;
            }
            if (out.workflow == null) {
                ctx.err.print("error: unknown workflow state '{s}' (one of: {s})\n", .{
                    w,
                    std.mem.join(arena, ", ", states) catch "",
                }) catch {};
                return null;
            }
        }
        return out;
    }
};

pub fn workflowStates(
    comptime B: type,
    ctx: *context.Context(B),
    repo: issuez.engine.Repo(B),
) ?[]const []const u8 {
    const raw = repo.backend.configGet(ctx.arena, "issue.workflowStates") catch {
        ctx.err.writeAll("error: could not read git config issue.workflowStates\n") catch {};
        return null;
    } orelse return &fields.default_workflow;
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const s = std.mem.trim(u8, part, " \t");
        if (s.len == 0) continue;
        if (!fields.isSlug(s)) {
            ctx.err.print(
                "error: issue.workflowStates has '{s}'; states are lowercase letters, " ++
                    "digits and '-'\n",
                .{s},
            ) catch {};
            return null;
        }
        out.append(ctx.arena, s) catch return null;
    }
    if (out.items.len == 0) return &fields.default_workflow;
    return out.items;
}

fn resolveRef(
    comptime B: type,
    ctx: *context.Context(B),
    repo: issuez.engine.Repo(B),
    prefix: []const u8,
) ?[]const u8 {
    const ref = common.resolveOne(B, repo, ctx.arena, ctx.err, prefix) orelse
        return null;
    return ref.id();
}

pub fn project(
    comptime B: type,
    ctx: *context.Context(B),
    repo: issuez.engine.Repo(B),
) ?issuez.projection.Projection {
    const issues = repo.loadAll(ctx.arena) catch |e| {
        common.reportRepoError(B, ctx, e);
        return null;
    };
    const states = workflowStates(B, ctx, repo) orelse return null;
    return issuez.projection.build(ctx.arena, issues, .{
        .workflow = states,
        .done_states = repo.done_states,
    }) catch null;
}

pub fn describeProblem(arena: Allocator, p: issuez.projection.Problem) []const u8 {
    const uuid = issuez.format.uuid;
    if (p.kind == .invalid_value) return std.fmt.allocPrint(
        arena,
        "{s} '{s}' is not valid and is ignored",
        .{ p.key.?, p.value.? },
    ) catch "invalid value";
    if (p.other) |o| return std.fmt.allocPrint(
        arena,
        "{s} ({s})",
        .{ p.kind.describe(), uuid.shortId(o) },
    ) catch p.kind.describe();
    return p.kind.describe();
}

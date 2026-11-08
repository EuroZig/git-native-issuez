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
    \\   --start <date>            Start date: YYYY-MM-DD, today, +3d, fri, eom
    \\   --due <date>              Due date: YYYY-MM-DD, today, +3d, fri, eom
    \\   --estimate <duration>     Minutes, or e.g. 2h, 90m, 1h30m
    \\   --workflow <state>        Workflow state (git config issue.workflowStates;
    \\                             default backlog, ready, in-progress, review)
    \\   --milestone-id <id>       Put it in a catalog milestone (ID prefix or name)
    \\   --milestone-mode <mode>   inherit (the parent's milestone), none or explicit
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
    \\   --no-milestone            Clear the milestone (and stop inheriting one)
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
    milestone_id: ?[]const u8 = null,
    milestone_mode: ?[]const u8 = null,
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
            .{ "--milestone-id", &f.milestone_id },
            .{ "--milestone-mode", &f.milestone_mode },
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
            f.milestone_id != null or f.milestone_mode != null or f.no.count() > 0;
    }

    pub const Resolved = struct {
        parent: ?[]const u8 = null,
        blocked_by: []const []const u8 = &.{},
        unblock: []const []const u8 = &.{},
        start: ?fields.Date = null,
        due: ?fields.Date = null,
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
        for ([_]struct { []const u8, ?[]const u8, *?fields.Date }{
            .{ "--start", f.start, &out.start },
            .{ "--due", f.due, &out.due },
        }) |d| if (d[1]) |v| {
            d[2].* = ctx.date(v) orelse {
                ctx.err.print(
                    "error: {s} must be a date as YYYY-MM-DD, or like today, +3d, fri, eom, not " ++
                        "'{s}'\n",
                    .{ d[0], v },
                ) catch {};
                return null;
            };
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
            if (issuez.format.labels.contains(states, w)) out.workflow = w else {
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

pub const MilestoneChoice = struct {
    /// null means unchanged.
    text: ?[]const u8 = null,
    id: ?[]const u8 = null,
    mode: ?fields.MilestoneMode = null,

    pub fn edit(c: MilestoneChoice) ?issuez.engine.MilestoneEdit {
        return .fromParts(.{ .text = c.text, .id = c.id, .mode = c.mode });
    }
};

/// `--milestone <name>` links a catalog milestone when exactly one open
/// milestone has that name, otherwise it stays plain text like upstream
/// writes it. `current` is null on create. See `Catalog.choose`.
pub fn resolveMilestone(
    comptime B: type,
    ctx: *context.Context(B),
    repo: issuez.engine.Repo(B),
    f: Flags,
    text: ?[]const u8,
    current: ?issuez.engine.Issue,
) ?MilestoneChoice {
    const uuid = issuez.format.uuid;
    const mode = if (f.milestone_mode) |m| fields.MilestoneMode.parse(m) orelse {
        ctx.err.print(
            "error: --milestone-mode must be inherit, none or explicit, not '{s}'\n",
            .{m},
        ) catch {};
        return null;
    } else null;
    const cat = issuez.Catalog(B).fromRepo(repo);
    const chosen = cat.choose(ctx.arena, .{
        .name = if (f.no.contains(.milestone)) "" else text,
        .id = f.milestone_id,
        .mode = mode,
        .current = current,
        .parent_given = f.parent != null,
    }) catch |e| {
        common.reportRepoError(B, ctx, e);
        return null;
    };
    const w = ctx.err;
    switch (chosen) {
        .ok => |c| {
            if (c.text_only) w.print(
                "hint: no open milestone is named '{s}'; it is kept as text only " ++
                    "(see 'git issue milestone ls')\n",
                .{c.text.?},
            ) catch {};
            return .{ .text = c.text, .id = c.id, .mode = c.mode };
        },
        .refused => |r| switch (r) {
            .id_with_name => w.writeAll(
                "error: --milestone-id doesn't go with --milestone or --no-milestone\n",
            ) catch {},
            .id_with_mode => |m| w.print(
                "error: --milestone-id doesn't go with --milestone-mode {t}\n",
                .{m},
            ) catch {},
            .explicit_needs_milestone => w.writeAll(
                "error: --milestone-mode explicit needs a milestone\n",
            ) catch {},
            .explicit_needs_id => w.writeAll(
                "error: --milestone-mode explicit needs a milestone (--milestone-id)\n",
            ) catch {},
            .no_such_milestone, .retired_name, .ambiguous_id => reportLookup(
                B,
                w,
                f.milestone_id.?,
                r,
            ),
            .not_open => |m| w.print("error: milestone '{s}' is {t}{s}\n", .{
                m.name,
                m.status,
                if (m.status == .completed) "; reopen it first" else "",
            }) catch {},
            .no_open_named => |n| w.print(
                "error: no open milestone is named '{s}'\n",
                .{n},
            ) catch {},
            .ambiguous_name => |ms| {
                w.print(
                    "error: several open milestones are named '{s}':\n",
                    .{ms[0].name},
                ) catch {};
                for (ms) |m| w.print("  {s} {s}\n", .{ uuid.shortId(m.id), m.name }) catch {};
                w.writeAll("Name one with --milestone-id <id>.\n") catch {};
            },
        },
    }
    return null;
}

/// By ID prefix or exact name.
pub fn findMilestone(
    comptime B: type,
    ctx: *context.Context(B),
    cat: issuez.Catalog(B),
    key: []const u8,
) ?issuez.milestone.Milestone {
    const found = cat.resolve(ctx.arena, key) catch |e| {
        common.reportRepoError(B, ctx, e);
        return null;
    };
    switch (found) {
        .one => |m| return m,
        .retired_name => |m| reportLookup(B, ctx.err, key, .{ .retired_name = m }),
        .none => reportLookup(B, ctx.err, key, .{ .no_such_milestone = key }),
        .many => |ms| reportLookup(B, ctx.err, key, .{ .ambiguous_id = ms }),
    }
    return null;
}

fn reportLookup(
    comptime B: type,
    w: *std.Io.Writer,
    key: []const u8,
    r: issuez.Catalog(B).Refusal,
) void {
    const uuid = issuez.format.uuid;
    switch (r) {
        .retired_name => |m| w.print(
            "error: milestone '{s}' is retired; name it by its ID ({s})\n",
            .{ key, uuid.shortId(m.id) },
        ) catch {},
        .no_such_milestone => w.print(
            "error: no milestone '{s}' (see 'git issue milestone ls -a')\n",
            .{key},
        ) catch {},
        .ambiguous_id => |ms| {
            w.print("error: '{s}' matches several milestones:\n", .{key}) catch {};
            for (ms) |m| w.print(
                "  {s} [{t}] {s}\n",
                .{ uuid.shortId(m.id), m.status, m.name },
            ) catch {};
        },
        else => unreachable,
    }
}

/// Null after printing why. Writes check against these states.
pub fn workflowStates(
    comptime B: type,
    ctx: *context.Context(B),
    repo: issuez.engine.Repo(B),
) ?[]const []const u8 {
    return readWorkflowStates(B, ctx, repo, "error: ", "\n");
}

/// For reads: a bad setting is a warning, and the default states stand in
/// (`Catalog.project`), so listing never fails on it.
pub fn warnBadWorkflowStates(
    comptime B: type,
    ctx: *context.Context(B),
    repo: issuez.engine.Repo(B),
) void {
    _ = readWorkflowStates(B, ctx, repo, "warning: ", "; using the default states\n");
}

fn readWorkflowStates(
    comptime B: type,
    ctx: *context.Context(B),
    repo: issuez.engine.Repo(B),
    comptime prefix: []const u8,
    comptime suffix: []const u8,
) ?[]const []const u8 {
    const settings = ctx.settings orelse issuez.settings.read(B, ctx.arena, repo.backend) catch {
        ctx.err.writeAll(
            prefix ++ "could not read git config issue.workflowStates" ++ suffix,
        ) catch {};
        return null;
    };
    if (settings.invalid_workflow_state) |s| {
        ctx.err.print(
            prefix ++ "issue.workflowStates has '{s}'; " ++
                issuez.settings.workflow_states_rule ++ suffix,
            .{s},
        ) catch {};
        return null;
    }
    return settings.workflow_states;
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

/// Null after printing why.
pub fn project(
    comptime B: type,
    ctx: *context.Context(B),
    repo: issuez.engine.Repo(B),
) ?issuez.projection.Projection {
    const issues = repo.loadAll(ctx.arena) catch |e| {
        common.reportRepoError(B, ctx, e);
        return null;
    };
    return projectIssues(B, ctx, repo, issues);
}

/// `project` for one issue: the same answers for it, from the issues
/// around it (`Repo.loadAround`).
pub fn projectAround(
    comptime B: type,
    ctx: *context.Context(B),
    repo: issuez.engine.Repo(B),
    ref: issuez.engine.IssueRef,
) ?issuez.projection.Projection {
    const issues = repo.loadAround(ctx.arena, ref) catch |e| {
        common.reportRepoError(B, ctx, e);
        return null;
    };
    return projectIssues(B, ctx, repo, issues);
}

/// `project` over issues the caller already loaded (every issue).
pub fn projectIssues(
    comptime B: type,
    ctx: *context.Context(B),
    repo: issuez.engine.Repo(B),
    issues: []const issuez.engine.Issue,
) ?issuez.projection.Projection {
    // The repo has the states (`Repo.settings`).
    warnBadWorkflowStates(B, ctx, repo);
    const cat = issuez.Catalog(B).fromRepo(repo);
    return cat.project(ctx.arena, issues, .{}) catch |e| {
        common.reportRepoError(B, ctx, e);
        return null;
    };
}

pub fn describeProblem(arena: Allocator, p: issuez.projection.Problem) []const u8 {
    return std.fmt.allocPrint(arena, "{f}", .{p}) catch
        if (p.kind == .invalid_value) "invalid value" else p.kind.describe();
}

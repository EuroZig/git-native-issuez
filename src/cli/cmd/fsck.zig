//! `git issue fsck [--quiet]`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const ext_flags = @import("../ext_flags.zig");
const issuez = @import("issuez");
const uuid = issuez.format.uuid;

pub const help =
    \\usage: git issue fsck [options]
    \\
    \\Check every issue for data integrity:
    \\   - ref names are UUIDs
    \\   - every commit uses the empty tree
    \\   - one root commit, carrying State: and Format-Version: trailers
    \\   - the whole history is readable
    \\
    \\   - stored attachment bytes match their hashes
    \\
    \\Milestones get the same checks, with Name: in place of State:.
    \\
    \\Quarantined issues (see `git issue status`), hierarchy or blocker
    \\problems (see `git issue ls --problems`), attachments whose bytes aren't
    \\here yet, ignored attachment trailers and out-of-date derived
    \\refs/attachments/* are noted, not counted as errors.
    \\
    \\Options:
    \\   --repair     Regenerate out-of-date refs/attachments/* (never touches issues)
    \\   -q, --quiet  Only report problems
    \\   -h, --help   Show this help
    \\
;

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var quiet = false;
    var repair = false;
    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--repair")) {
            repair = true;
        } else {
            return common.unknownOption(ctx.err, "fsck", arg);
        }
    }

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    // --repair writes attachment refs, so it needs git-lfs like every
    // attachment action.
    if (repair) issuez.Attachments(B).fromRepo(repo).ready(arena) catch |e|
        return common.repoFailed(B, ctx, e);
    const refs = repo.refs(arena) catch |e| return common.repoFailed(B, ctx, e);
    const milestones = issuez.Catalog(B).of(repo).refs(arena) catch |e|
        return common.repoFailed(B, ctx, e);
    if (refs.len == 0 and milestones.len == 0) {
        ctx.out.writeAll("No issues found.\n") catch {};
        return common.exit_ok;
    }

    var errors: usize = 0;
    for (refs) |ref| {
        const short = uuid.shortId(ref.id());
        const problems = repo.check(arena, ref) catch return common.oom(ctx.err);
        errors += problems.len;
        printProblems(B, ctx.err, short, ref, problems);
        if (problems.len == 0 and !quiet) ctx.out.print("ok {s}\n", .{short}) catch {};
    }
    errors += checkMilestones(B, ctx, repo, milestones, quiet) orelse return common.oom(ctx.err);
    errors += checkAttachments(B, ctx, repo, refs, repair);
    reportQuarantine(B, ctx, repo.backend);
    reportProjection(B, ctx, repo);
    if (errors == 0) {
        ctx.out.print("Checked {d} issues, no errors found.\n", .{refs.len}) catch {};
        return common.exit_ok;
    }
    ctx.err.print("Checked {d} issues, {d} errors found.\n", .{ refs.len, errors }) catch {};
    return common.exit_error;
}

/// Like issues, with `Name:` in place of `State:`. Returns the error
/// count, null when out of memory.
fn checkMilestones(
    comptime B: type,
    ctx: *context.Context(B),
    repo: issuez.engine.Repo(B),
    refs: []const issuez.engine.IssueRef,
    quiet: bool,
) ?usize {
    var errors: usize = 0;
    for (refs) |ref| {
        const id = uuid.shortId(ref.id());
        const short = std.fmt.allocPrint(ctx.arena, "milestone {s}", .{id}) catch return null;
        const problems = repo.checkWith(ctx.arena, ref, &.{ "Name", "Format-Version" }) catch
            return null;
        errors += problems.len;
        printProblems(B, ctx.err, short, ref, problems);
        if (problems.len == 0 and !quiet) ctx.out.print("ok {s}\n", .{short}) catch {};
        // Readers take an unknown status as `open`: worth a note.
        const m = repo.load(ctx.arena, ref) catch continue;
        const status = m.field("X-Milestone-Status") orelse continue;
        if (issuez.format.fields.MilestoneStatus.parse(status) == null) ctx.err.print(
            "note: {s}: X-Milestone-Status '{s}' is not valid and reads as open\n",
            .{ short, status },
        ) catch {};
    }
    return errors;
}

fn printProblems(
    comptime B: type,
    err: *std.Io.Writer,
    short: []const u8,
    ref: issuez.engine.IssueRef,
    problems: []const issuez.engine.Repo(B).Problem,
) void {
    for (problems) |p| switch (p) {
        .invalid_uuid => err.print(
            "error: {s}: invalid UUID format: {s}\n",
            .{ short, ref.id() },
        ) catch {},
        .non_empty_tree => |oid| err.print(
            "error: {s}: commit {s} does not use empty tree\n",
            .{ short, oid.hex().short() },
        ) catch {},
        .root_count => |n| err.print(
            "error: {s}: expected 1 root commit, found {d}\n",
            .{ short, n },
        ) catch {},
        .missing_state => err.print(
            "error: {s}: root commit missing State: trailer\n",
            .{short},
        ) catch {},
        .missing_format_version => err.print(
            "error: {s}: root commit missing Format-Version: trailer\n",
            .{short},
        ) catch {},
        .missing_root_trailer => |k| err.print(
            "error: {s}: root commit missing {s}: trailer\n",
            .{ short, k },
        ) catch {},
        .unreadable => |e| err.print(
            "error: {s}: history unreadable ({t})\n",
            .{ short, e },
        ) catch {},
    };
}

/// Damaged bytes are errors, the rest are notes. Returns the error count.
fn checkAttachments(
    comptime B: type,
    ctx: *context.Context(B),
    repo: issuez.engine.Repo(B),
    refs: []const issuez.engine.IssueRef,
    repair: bool,
) usize {
    const A = issuez.Attachments(B);
    const att = A.fromRepo(repo);
    var errors: usize = 0;
    var issues: std.ArrayList(issuez.engine.Issue) = .empty;
    const check_bytes = if (att.ready(ctx.arena)) |_| true else |e| switch (e) {
        error.LfsUnavailable => false,
        error.AttachmentsUnsupported => return errors,
        else => {
            common.reportRepoError(B, ctx, e);
            return errors + 1;
        },
    };
    var unchecked = false;
    for (refs) |ref| {
        const issue = repo.load(ctx.arena, ref) catch continue;
        issues.append(ctx.arena, issue) catch return errors;
        const short = uuid.shortId(issue.id);
        for (issue.attachment_problems) |p| ctx.err.print(
            "note: {s}: commit {s}: {s} attachment trailer ignored: {s}\n",
            .{
                short,
                p.oid.hex().short(),
                switch (p.kind) {
                    .malformed => "malformed",
                    .changed_object => "object-changing",
                },
                p.value,
            },
        ) catch {};
        if (issue.attachments.len == 0 and issue.removed_attachments.len == 0) continue;
        if (!check_bytes) unchecked = true;
        const entries: []const A.Entry = if (!check_bytes)
            &.{}
        else
            att.list(ctx.arena, issue) catch |e| {
                common.reportRepoError(B, ctx, e);
                errors += 1;
                continue;
            };
        for (entries) |e| switch (e.availability) {
            .local => {},
            .missing => ctx.err.print(
                "note: {s}: attachment {s} ({s}): bytes not in this repository\n",
                .{ short, uuid.shortId(e.attachment.id), e.attachment.name },
            ) catch {},
            .corrupt => {
                errors += 1;
                ctx.err.print(
                    "error: {s}: attachment {s} ({s}): stored bytes don't match the hash\n" ++
                        "       ('git issue attach fetch' gets a good copy)\n",
                    .{ short, uuid.shortId(e.attachment.id), e.attachment.name },
                ) catch {};
            },
        };
        const state = att.derivedState(ctx.arena, issue) catch continue;
        if (state == .ok) continue;
        if (repair) {
            if (att.repair(ctx.arena, issue)) |_| {
                ctx.out.print("repaired refs/attachments/{s}\n", .{issue.id}) catch {};
            } else |e| {
                common.reportRepoError(B, ctx, e);
                errors += 1;
            }
        } else ctx.err.print(
            "note: {s}: refs/attachments/{s} is {s} (run 'git issue fsck --repair')\n",
            .{ short, issue.id, if (state == .absent) "missing" else "out of date" },
        ) catch {};
    }
    if (unchecked) ctx.err.writeAll(
        "note: git-lfs isn't installed, so attachment bytes weren't checked " ++
            "(https://git-lfs.com)\n",
    ) catch {};
    if (!check_bytes) return errors;
    const orphans = att.orphans(ctx.arena, issues.items) catch return errors;
    if (orphans.len > 0) ctx.err.print(
        "note: {d} stored attachment object(s) no issue references (from failed writes)\n",
        .{orphans.len},
    ) catch {};
    return errors;
}

/// Quarantine is a sync state, not damage: noted, not counted.
fn reportQuarantine(comptime B: type, ctx: *context.Context(B), backend: *B) void {
    const s = issuez.Sync(B).init(backend);
    const remotes = backend.remoteNames(ctx.arena) catch return;
    for (remotes) |r| {
        const st = s.status(ctx.arena, r) catch continue;
        var open: usize = 0;
        for (st.quarantined) |q| if (!q.kept_local) {
            open += 1;
        };
        if (open > 0) ctx.err.print(
            "note: {d} issue(s) quarantined from '{s}' (see 'git issue status {s}')\n",
            .{ open, r, r },
        ) catch {};
    }
}

/// Same for hierarchy and blocker problems, which upstream's fsck doesn't
/// know about.
fn reportProjection(
    comptime B: type,
    ctx: *context.Context(B),
    repo: issuez.engine.Repo(B),
) void {
    const proj = ext_flags.project(B, ctx, repo) orelse return;
    for (proj.problems) |p| ctx.err.print("note: {s}: {s}\n", .{
        uuid.shortId(p.id),
        ext_flags.describeProblem(ctx.arena, p),
    }) catch {};
}

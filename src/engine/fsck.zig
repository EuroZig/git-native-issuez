//! Checking a repository's issue data (`git issue fsck`): upstream fsck's
//! checks on every issue and milestone, attachment trailers and bytes, the
//! derived attachment refs, quarantined remote versions and the problems
//! across issues (hierarchy, blockers). A report of events in order, which
//! a front end shows as it likes; `describe` words each one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const repo_mod = @import("repo.zig");
const issue_model = @import("../model/issue.zig");
const projection_mod = @import("projection.zig");
const fields_fmt = @import("../format/fields.zig");
const uuid_fmt = @import("../format/uuid.zig");
const errors_mod = @import("errors.zig");

pub const Options = struct {
    /// Rewrite derived attachment refs that are missing or stale. Needs
    /// the attachment store (git-lfs with GitProcess).
    repair: bool = false,
    /// False for a host that keeps attachment bytes itself: they are
    /// neither read nor noted, and the repository's store isn't looked at.
    check_bytes: bool = true,
};

pub fn Fsck(comptime B: type) type {
    const Repo = repo_mod.Repo(B);
    const Catalog = @import("milestone.zig").Catalog(B);
    const Attachments = @import("attachments.zig").Attachments(B);
    const Sync = @import("sync.zig").Sync(B);

    return struct {
        pub const Problem = Repo.Problem;

        pub const Subject = struct {
            kind: enum { issue, milestone },
            id: []const u8,
        };

        pub const Event = union(enum) {
            /// Passed upstream's checks.
            ok: Subject,
            /// An error: fails one of upstream's checks.
            problem: struct { subject: Subject, problem: Problem },
            /// A note: an `X-Milestone-Status` no reader takes; it reads
            /// as open.
            milestone_status: struct { id: []const u8, value: []const u8 },
            /// A note: an attachment trailer the fold ignored.
            attachment_trailer: struct { id: []const u8, problem: issue_model.AttachmentProblem },
            /// A note: the bytes aren't in this repository.
            attachment_missing: struct { id: []const u8, attachment: issue_model.Attachment },
            /// An error: the stored bytes don't match the trailer.
            attachment_corrupt: struct { id: []const u8, attachment: issue_model.Attachment },
            /// A note: the derived `refs/attachments/<id>` is missing or
            /// stale (`Options.repair` rewrites it).
            derived_ref: struct { id: []const u8, missing: bool },
            /// The derived ref was rewritten.
            repaired: []const u8,
            /// An error: checking or repairing an issue's attachments
            /// failed (`id` null: the store itself).
            attachments_failed: struct { id: ?[]const u8, err: anyerror },
            /// A note: without git-lfs the bytes weren't checked.
            bytes_unchecked,
            /// A note: stored objects no issue references (failed writes).
            orphans: usize,
            /// A note: remote versions refused by a merge, not acknowledged.
            quarantined: struct { remote: []const u8, count: usize },
            /// A note: hierarchy and blocker problems across issues.
            projection: projection_mod.Problem,

            pub fn isError(e: Event) bool {
                return switch (e) {
                    .problem, .attachment_corrupt, .attachments_failed => true,
                    else => false,
                };
            }

            /// One sentence, without a front end's commands.
            pub fn format(e: Event, w: *std.Io.Writer) std.Io.Writer.Error!void {
                switch (e) {
                    .ok => try w.writeAll("ok"),
                    .problem => |p| try w.print("{f}", .{p.problem}),
                    .milestone_status => |m| try w.print(
                        "X-Milestone-Status '{s}' is not valid and reads as open",
                        .{m.value},
                    ),
                    .attachment_trailer => |a| try w.print(
                        "commit {s}: {s} attachment trailer ignored: {s}",
                        .{ a.problem.oid.hex().short(), a.problem.kind.text(), a.problem.value },
                    ),
                    .attachment_missing => |a| try w.print(
                        "attachment {s} ({s}): bytes not in this repository",
                        .{ uuid_fmt.shortId(a.attachment.id), a.attachment.name },
                    ),
                    .attachment_corrupt => |a| try w.print(
                        "attachment {s} ({s}): stored bytes don't match the hash",
                        .{ uuid_fmt.shortId(a.attachment.id), a.attachment.name },
                    ),
                    .derived_ref => |d| try w.print(
                        "refs/attachments/{s} is {s}",
                        .{ d.id, if (d.missing) "missing" else "out of date" },
                    ),
                    .repaired => |id| try w.print("repaired refs/attachments/{s}", .{id}),
                    .attachments_failed => |f| try w.writeAll(
                        errors_mod.describe(f.err) orelse @errorName(f.err),
                    ),
                    .bytes_unchecked => try w.writeAll(
                        "git-lfs isn't installed, so attachment bytes weren't checked",
                    ),
                    .orphans => |n| try w.print(
                        "{d} stored attachment object(s) no issue references (from failed writes)",
                        .{n},
                    ),
                    .quarantined => |q| try w.print(
                        "{d} issue(s) quarantined from '{s}'",
                        .{ q.count, q.remote },
                    ),
                    .projection => |p| try w.print("{f}", .{p}),
                }
            }
        };

        pub const Report = struct {
            issues: usize,
            milestones: usize,
            events: []const Event,

            pub fn errors(r: Report) usize {
                var n: usize = 0;
                for (r.events) |e| {
                    if (e.isError()) n += 1;
                }
                return n;
            }
        };

        pub fn run(
            arena: Allocator,
            repo: Repo,
            options: Options,
        ) (Repo.Error || error{InvalidLimits})!Report {
            const att = Attachments.fromRepo(repo);
            if (options.repair) try att.ready(arena);
            const refs = try repo.refs(arena);
            const milestones = try Catalog.fromRepo(repo).refs(arena);
            var out: std.ArrayList(Event) = .empty;
            for (refs) |ref| {
                const subject: Subject = .{ .kind = .issue, .id = ref.id() };
                const problems = try repo.check(arena, ref, .{});
                for (problems) |p| try out.append(
                    arena,
                    .{ .problem = .{ .subject = subject, .problem = p } },
                );
                if (problems.len == 0) try out.append(arena, .{ .ok = subject });
            }
            for (milestones) |ref| {
                const subject: Subject = .{ .kind = .milestone, .id = ref.id() };
                const problems = try repo.check(arena, ref, .{
                    .root_keys = &.{ "Name", "Format-Version" },
                });
                for (problems) |p| try out.append(
                    arena,
                    .{ .problem = .{ .subject = subject, .problem = p } },
                );
                if (problems.len == 0) try out.append(arena, .{ .ok = subject });
                const m = repo.load(arena, ref) catch continue;
                const status = m.field("X-Milestone-Status") orelse continue;
                if (fields_fmt.MilestoneStatus.parse(status) == null)
                    try out.append(
                        arena,
                        .{ .milestone_status = .{ .id = ref.id(), .value = status } },
                    );
            }
            try checkAttachments(arena, repo, att, refs, options, &out);
            try quarantine(arena, repo, &out);
            const issues = repo.loadAll(arena) catch null;
            if (issues) |list| {
                if (Catalog.fromRepo(repo).project(arena, list, .{})) |proj| {
                    for (proj.problems) |p| try out.append(arena, .{ .projection = p });
                } else |_| {}
            }
            return .{ .issues = refs.len, .milestones = milestones.len, .events = out.items };
        }

        fn checkAttachments(
            arena: Allocator,
            repo: Repo,
            att: Attachments,
            refs: []const repo_mod.IssueRef,
            options: Options,
            out: *std.ArrayList(Event),
        ) Allocator.Error!void {
            var issues: std.ArrayList(issue_model.Issue) = .empty;
            const check_bytes = if (!options.check_bytes)
                false
            else if (att.ready(arena)) |_|
                true
            else |e| switch (e) {
                error.LfsUnavailable => false,
                error.AttachmentsUnsupported => return,
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try out.append(arena, .{ .attachments_failed = .{ .id = null, .err = e } });
                    return;
                },
            };
            var unchecked = false;
            for (refs) |ref| {
                const issue = repo.load(arena, ref) catch continue;
                try issues.append(arena, issue);
                for (issue.attachment_problems) |p|
                    try out.append(
                        arena,
                        .{ .attachment_trailer = .{ .id = issue.id, .problem = p } },
                    );
                if (issue.attachments.len == 0 and issue.removed_attachments.len == 0) continue;
                if (!check_bytes and options.check_bytes) unchecked = true;
                const entries: []const @import("attachments.zig").Entry = if (!check_bytes)
                    &.{}
                else
                    att.list(arena, issue, .{ .verify = true }) catch |e| {
                        if (e == error.OutOfMemory) return error.OutOfMemory;
                        try out.append(
                            arena,
                            .{ .attachments_failed = .{ .id = issue.id, .err = e } },
                        );
                        continue;
                    };
                for (entries) |e| switch (e.availability) {
                    .local => {},
                    .missing => try out.append(arena, .{ .attachment_missing = .{
                        .id = issue.id,
                        .attachment = e.attachment,
                    } }),
                    .corrupt => try out.append(arena, .{ .attachment_corrupt = .{
                        .id = issue.id,
                        .attachment = e.attachment,
                    } }),
                };
                const state = att.derivedState(arena, issue) catch continue;
                if (state == .ok) continue;
                if (options.repair) {
                    if (att.repair(arena, issue)) |_| {
                        try out.append(arena, .{ .repaired = issue.id });
                    } else |e| {
                        if (e == error.OutOfMemory) return error.OutOfMemory;
                        try out.append(
                            arena,
                            .{ .attachments_failed = .{ .id = issue.id, .err = e } },
                        );
                    }
                } else try out.append(arena, .{ .derived_ref = .{
                    .id = issue.id,
                    .missing = state == .absent,
                } });
            }
            if (unchecked) try out.append(arena, .bytes_unchecked);
            if (!check_bytes) return;
            const orphans = att.orphans(arena, issues.items) catch return;
            if (orphans.len > 0) try out.append(arena, .{ .orphans = orphans.len });
        }

        /// A sync state, not damage: noted, not counted.
        fn quarantine(
            arena: Allocator,
            repo: Repo,
            out: *std.ArrayList(Event),
        ) Allocator.Error!void {
            const s = Sync.init(repo.backend);
            const remotes = repo.backend.remoteNames(arena) catch return;
            for (remotes) |r| {
                const st = s.status(arena, r) catch continue;
                var open: usize = 0;
                for (st.quarantined) |q| if (!q.kept_local) {
                    open += 1;
                };
                if (open > 0) try out.append(
                    arena,
                    .{ .quarantined = .{ .remote = r, .count = open } },
                );
            }
        }
    };
}

const testing = std.testing;

test "Fsck: ok, a bad root, a note for a milestone status" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const GitSim = @import("../backend/GitSim.zig");
    var world: GitSim.World = .{ .seed = 79, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo: repo_mod.Repo(GitSim) = .init(&sim);
    const made = try repo.create(arena, .{ .title = "Fine" }, .{});
    const F = Fsck(GitSim);
    const report = try F.run(arena, repo, .{});
    try testing.expectEqual(@as(usize, 1), report.issues);
    try testing.expectEqual(@as(usize, 0), report.errors());
    try testing.expectEqualStrings(made.id, report.events[0].ok.id);
    try testing.expectFmt("ok", "{f}", .{report.events[0]});
}

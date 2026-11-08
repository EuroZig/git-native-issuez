//! The milestone catalog: `refs/milestones/<uuid>`, written and merged by
//! the same engine as issues.
//!
//!     Create milestone v1.0
//!
//!     <optional description>
//!
//!     Name: v1.0
//!     X-Due-Date: 2026-12-01
//!     X-Milestone-Status: open        # open, completed or retired
//!     Format-Version: 1
//!
//! A rename writes a new `Name:`. UUIDs are never reused.

const std = @import("std");
const stableSort = @import("../sort.zig").stable;
const Allocator = std.mem.Allocator;
const object = @import("../backend/object.zig");
const trailers = @import("../format/trailers.zig");
const fields_fmt = @import("../format/fields.zig");
const uuid_fmt = @import("../format/uuid.zig");
const repo_mod = @import("repo.zig");
const projection_mod = @import("projection.zig");
const issue_model = @import("../model/issue.zig");
const Issue = issue_model.Issue;

const Oid = object.Oid;

pub const ref_prefix = repo_mod.milestone_ref_prefix;

pub const Milestone = struct {
    id: []const u8,
    tip: Oid,
    name: []const u8,
    description: []const u8,
    due: ?fields_fmt.Date,
    /// `open` when missing or unknown.
    status: fields_fmt.MilestoneStatus,
    created: i64,
    /// The tip's author time.
    updated: i64 = 0,
    /// Who created it, with their host UUID if the commit has one.
    author: object.Signature = .{ .name = "", .email = "", .time = 0, .tz_offset_minutes = 0 },
    author_id: ?[]const u8 = null,
    /// When the status it has was set, by the commit that set it last;
    /// null when no commit after the root changed it.
    status_changed: ?i64 = null,
    conflicts: []const @import("../model/issue.zig").Conflict,
};

/// The author time of the last commit after the root that set the status.
fn statusChanged(m: Issue) ?i64 {
    var at: ?i64 = null;
    for (m.comments) |c| for (c.changes) |ch| {
        if (std.ascii.eqlIgnoreCase(ch.key, "X-Milestone-Status")) at = c.author.time;
    };
    return at;
}

pub fn Catalog(comptime B: type) type {
    const R = repo_mod.Repo(B);
    return struct {
        const Self = @This();

        repo: R,

        pub const Error = R.Error;

        pub fn init(backend: *B) Self {
            return .{ .repo = R.init(backend) };
        }

        /// With the repo's limits and settings, as the other parts'
        /// `fromRepo`.
        pub fn fromRepo(repo: R) Self {
            return .{ .repo = repo };
        }

        fn b(self: Self) *B {
            return self.repo.backend;
        }

        pub fn refs(self: Self, arena: Allocator) Error![]const repo_mod.IssueRef {
            const entries = try self.b().listRefs(arena, ref_prefix);
            const out = try arena.alloc(repo_mod.IssueRef, entries.len);
            for (entries, out) |e, *r| r.* = .{ .name = e.name, .tip = e.oid };
            return out;
        }

        pub fn load(self: Self, arena: Allocator, ref: repo_mod.IssueRef) Error!Milestone {
            const m = try self.repo.load(arena, ref);
            const header = repo_mod.milestoneHeader(m);
            return .{
                .id = ref.id(),
                .tip = ref.tip,
                .name = header.name,
                .description = m.description,
                .due = m.due_date,
                .status = header.status,
                .created = m.created,
                .updated = m.updated,
                .author = m.author,
                .author_id = m.author_id,
                .status_changed = statusChanged(m),
                .conflicts = m.conflicts,
            };
        }

        /// By due date (none last), then name. Milestones whose history
        /// can't be read are left out; `git issue fsck` reports them.
        pub fn list(self: Self, arena: Allocator) Error![]Milestone {
            var loaded: std.ArrayList(Milestone) = .empty;
            for (try self.refs(arena)) |r| {
                try loaded.append(arena, self.load(arena, r) catch |err| switch (err) {
                    error.CorruptIssue,
                    error.HistoryTooLong,
                    error.MissingParent,
                    error.NoRoot,
                    => continue,
                    else => |e| return e,
                });
            }
            const out = loaded.items;
            stableSort(Milestone, out, {}, struct {
                fn lt(_: void, x: Milestone, y: Milestone) bool {
                    if (x.due != null and y.due != null) {
                        const o = x.due.?.order(y.due.?);
                        if (o != .eq) return o == .lt;
                    } else if ((x.due == null) != (y.due == null)) return x.due != null;
                    return std.mem.lessThan(u8, x.name, y.name);
                }
            }.lt);
            return out;
        }

        pub fn find(self: Self, arena: Allocator, id: []const u8) Error!?Milestone {
            if (!uuid_fmt.isCanonical(id)) return null;
            const name = try repo_mod.milestoneRefName(arena, id);
            const tip = (try self.b().resolveRef(name)) orelse return null;
            return try self.load(arena, .{ .name = name, .tip = tip });
        }

        pub const Match = union(enum) {
            one: Milestone,
            /// Nothing matches, but a retired milestone has this name:
            /// name it by its ID.
            retired_name: Milestone,
            none,
            many: []const Milestone,
        };

        /// By ID prefix, else by exact name. Retired ones only match by ID;
        /// a retired one's name is `retired_name`.
        pub fn resolve(self: Self, arena: Allocator, key: []const u8) Error!Match {
            const all = try self.list(arena);
            return switch (try match(arena, all, key)) {
                .none => for (all) |m| {
                    if (std.mem.eql(u8, m.name, key)) break .{ .retired_name = m };
                } else .none,
                else => |found| found,
            };
        }

        /// By ID prefix, else by the name of one that isn't retired.
        fn match(arena: Allocator, all: []const Milestone, key: []const u8) Allocator.Error!Match {
            var hits: std.ArrayList(Milestone) = .empty;
            if (key.len >= 4) for (all) |m| {
                if (std.mem.startsWith(u8, m.id, key)) try hits.append(arena, m);
            };
            if (hits.items.len == 0) for (all) |m| {
                const named = m.status != .retired and std.mem.eql(u8, m.name, key);
                if (named) try hits.append(arena, m);
            };
            return switch (hits.items.len) {
                0 => .none,
                1 => .{ .one = hits.items[0] },
                else => .{ .many = hits.items },
            };
        }

        /// What an issue write asks for. Null leaves a part unchanged.
        pub const ChoiceSpec = struct {
            /// A milestone name, like `--milestone`: it links the one open
            /// milestone with exactly this name, else it is written as plain
            /// text (as upstream writes it). Empty clears the milestone, and
            /// stops inheriting one.
            name: ?[]const u8 = null,
            /// A catalog milestone by ID prefix or name, like `--milestone-id`.
            /// Doesn't go with `name`.
            id: ?[]const u8 = null,
            mode: ?fields_fmt.MilestoneMode = null,
            /// The issue being edited. Null on create.
            current: ?Issue = null,
            /// The same write sets a parent, so the issue may inherit.
            parent_given: bool = false,
        };

        /// What to write; `edit` is `CreateSpec`/`EditSpec`'s `milestone`.
        pub const Choice = struct {
            text: ?[]const u8 = null,
            id: ?[]const u8 = null,
            mode: ?fields_fmt.MilestoneMode = null,
            /// `name` matched no open milestone of a non-empty catalog and is
            /// kept as text only.
            text_only: bool = false,

            pub fn edit(c: Choice) ?repo_mod.MilestoneEdit {
                return .fromParts(.{ .text = c.text, .id = c.id, .mode = c.mode });
            }
        };

        pub const Refusal = union(enum) {
            /// `id` and `name` both given.
            id_with_name,
            /// `id` with mode `inherit` or `none`.
            id_with_mode: fields_fmt.MilestoneMode,
            /// Mode `explicit` with an empty name.
            explicit_needs_milestone,
            /// Mode `explicit` with neither a name nor an `id`, and the issue
            /// isn't linked to a catalog milestone yet.
            explicit_needs_id,
            /// `id` matches no milestone.
            no_such_milestone: []const u8,
            /// `id` names a retired milestone, which only matches by ID.
            retired_name: Milestone,
            ambiguous_id: []const Milestone,
            /// `name` belongs to a completed or retired milestone only.
            not_open: Milestone,
            /// Mode `explicit` with a `name` no open milestone has.
            no_open_named: []const u8,
            ambiguous_name: []const Milestone,
        };

        pub const Chosen = union(enum) { ok: Choice, refused: Refusal };

        /// Turns a milestone name, ID and mode into what to write. The same
        /// rules as `git issue create/edit --milestone`, `--milestone-id`,
        /// `--milestone-mode` and `--no-milestone`.
        pub fn choose(self: Self, arena: Allocator, spec: ChoiceSpec) Error!Chosen {
            var out: Choice = .{ .text = spec.name, .mode = spec.mode };
            if (spec.id) |key| {
                if (spec.name != null) return .{ .refused = .id_with_name };
                if (spec.mode) |m| if (m != .explicit) return .{
                    .refused = .{ .id_with_mode = m },
                };
                return switch (try self.resolve(arena, key)) {
                    .one => |m| .{ .ok = .{ .id = m.id } },
                    .retired_name => |m| .{ .refused = .{ .retired_name = m } },
                    .none => .{ .refused = .{ .no_such_milestone = key } },
                    .many => |ms| .{ .refused = .{ .ambiguous_id = ms } },
                };
            }
            const current_id = if (spec.current) |c| c.milestone_id != null else false;
            if (out.mode == .explicit) {
                if (out.text) |t| {
                    if (t.len == 0) return .{ .refused = .explicit_needs_milestone };
                } else if (!current_id) return .{ .refused = .explicit_needs_id };
            }
            const has_link = spec.parent_given or if (spec.current) |c|
                c.milestone_id != null or c.milestone_mode != null or c.parent != null
            else
                false;
            const name = out.text orelse return .{ .ok = out };
            if (name.len == 0) {
                if (out.mode == null and has_link) out.mode = .none;
                return .{ .ok = out };
            }
            // inherit/none with a name: keep the text, no catalog link.
            if (out.mode != null and out.mode.? != .explicit) return .{ .ok = out };
            const all = try self.list(arena);
            var hits: std.ArrayList(Milestone) = .empty;
            for (all) |m| if (m.status == .open and std.mem.eql(u8, m.name, name)) {
                try hits.append(arena, m);
            };
            switch (hits.items.len) {
                0 => {
                    for (all) |m| if (std.mem.eql(u8, m.name, name)) return .{
                        .refused = .{ .not_open = m },
                    };
                    if (out.mode == .explicit) return .{ .refused = .{ .no_open_named = name } };
                    out.text_only = all.len > 0;
                    // The text replaces a catalog link.
                    if (current_id) out.mode = .none;
                    return .{ .ok = out };
                },
                1 => return .{ .ok = .{ .id = hits.items[0].id } },
                else => return .{ .refused = .{ .ambiguous_name = hits.items } },
            }
        }

        pub const CreateSpec = struct {
            name: []const u8,
            description: []const u8 = "",
            due: ?fields_fmt.Date = null,
            author: ?repo_mod.Signature = null,
            /// Imports bring completed and retired ones.
            status: fields_fmt.MilestoneStatus = .open,
        };

        /// `id` is the full UUID.
        pub const Created = struct { id: []const u8, tip: Oid };

        /// `options` as for `Repo.update`.
        pub fn create(
            self_in: Self,
            arena: Allocator,
            spec: CreateSpec,
            options: repo_mod.WriteOptions,
        ) Error!Created {
            const self = self_in.withOptions(options);
            try checkName(spec.name);
            var tl: std.ArrayList(trailers.Trailer) = .empty;
            try tl.append(arena, .{ .key = "Name", .value = spec.name });
            if (spec.due) |d| {
                if (!d.isValid()) return error.InvalidValue;
                const text = try std.fmt.allocPrint(arena, "{f}", .{d});
                try tl.append(arena, .{ .key = "X-Due-Date", .value = text });
            }
            try tl.append(arena, .{ .key = "X-Milestone-Status", .value = @tagName(spec.status) });
            if (self.repo.call.author_id) |id| {
                if (!uuid_fmt.isCanonical(id)) return error.InvalidValue;
                try tl.append(arena, .{ .key = issue_model.author_id_key, .value = id });
            }
            try tl.append(arena, .{ .key = "Format-Version", .value = "1" });
            const subject = try std.fmt.allocPrint(arena, "Create milestone {s}", .{spec.name});
            const message = try trailers.build(arena, subject, spec.description, tl.items);
            const who = try self.repo.identity(arena, spec.author);
            const oid = try self.repo.writeCommit(arena, &.{}, who, message);
            var attempt: u8 = 0;
            while (attempt < self.repo.limits.cas_retries) : (attempt += 1) {
                var random: [16]u8 = undefined;
                self.b().randomBytes(&random);
                const id = uuid_fmt.Uuid.fromRandom(random);
                const name = try repo_mod.milestoneRefName(arena, id.slice());
                const created: Created = .{ .id = name[name.len - id.text.len ..], .tip = oid };
                if (self.repo.call.dry_run) return created;
                self.b().updateRefs(&.{.{ .name = name, .op = .{ .create = oid } }}) catch |err|
                    switch (err) {
                        error.RefConflict => continue,
                        else => |e| return e,
                    };
                if (self.repo.call.retries) |r| r.* = attempt;
                return created;
            }
            return error.ConcurrentModification;
        }

        pub const EditSpec = struct {
            name: ?[]const u8 = null,
            due: ?repo_mod.EditSpec.DateEdit = null,
            status: ?fields_fmt.MilestoneStatus = null,
            /// Replaces the description, with `X-Event: description-edit`.
            description: ?[]const u8 = null,
            /// The commit message. Defaults to "Complete milestone", ...
            message: ?[]const u8 = null,
            author: ?repo_mod.Signature = null,
            expect: ?Oid = null,
        };

        /// The catalog with `options` for its next write.
        fn withOptions(self: Self, options: repo_mod.WriteOptions) Self {
            var me = self;
            me.repo = self.repo.withOptions(options);
            return me;
        }

        /// One commit for all of it. `options` as for `Repo.update`.
        pub fn edit(
            self_in: Self,
            arena: Allocator,
            id: []const u8,
            spec: EditSpec,
            options: repo_mod.WriteOptions,
        ) Error!Oid {
            const self = self_in.withOptions(options);
            const limits = self.repo.limits;
            var tl: std.ArrayList(trailers.Trailer) = .empty;
            var what: std.ArrayList([]const u8) = .empty;
            if (spec.name) |n| {
                try checkName(n);
                try tl.append(arena, .{ .key = "Name", .value = n });
                try what.append(arena, "name");
            }
            if (spec.due) |d| {
                const text = switch (d) {
                    .set => |date| if (date.isValid())
                        try std.fmt.allocPrint(arena, "{f}", .{date})
                    else
                        return error.InvalidValue,
                    .clear => "",
                };
                try tl.append(arena, .{ .key = "X-Due-Date", .value = text });
                try what.append(arena, "due date");
            }
            if (spec.status) |s| {
                try tl.append(arena, .{ .key = "X-Milestone-Status", .value = @tagName(s) });
            }
            if (spec.description) |d| {
                if (d.len > limits.max_body_bytes) return error.TooLong;
                const event = fields_fmt.Event.description_edit.text();
                try tl.append(arena, .{ .key = "X-Event", .value = event });
                try what.append(arena, "description");
            }
            if (tl.items.len == 0) return error.NothingToEdit;
            for (tl.items) |x| if (x.value.len > limits.max_trailer_value_bytes)
                return error.TooLong;
            const given = repo_mod.givenMessage(spec.message);
            const subject = given orelse if (spec.status) |s| switch (s) {
                .completed => "Complete milestone",
                .retired => "Retire milestone",
                .open => "Reopen milestone",
            } else try std.fmt.allocPrint(
                arena,
                "Update {s}",
                .{try std.mem.join(arena, ", ", what.items)},
            );
            // With a new description, that is the body. Otherwise the
            // message may have a body of its own, as for issues.
            const message = if (spec.description) |d|
                try trailers.build(arena, repo_mod.splitMessage(subject).subject, d, tl.items)
            else blk: {
                const split = repo_mod.splitMessage(subject);
                break :blk try trailers.build(arena, split.subject, split.body, tl.items);
            };
            const name = try repo_mod.milestoneRefName(arena, id);
            if (spec.status == .completed) return self.repo.appendMilestone(
                arena,
                name,
                spec.author,
                spec.expect,
                CompleteBuilder{ .catalog = self, .id = id, .text = message },
            );
            const fixed: R.FixedEdit = .{ .text = message };
            return self.repo.appendMilestone(arena, name, spec.author, spec.expect, fixed);
        }

        /// A milestone's new due date, for `editBatch`.
        pub const DueEdit = struct {
            id: []const u8,
            due: repo_mod.EditSpec.DateEdit,
            expect: ?Oid = null,
            author: ?repo_mod.Signature = null,
        };

        /// What `editBatch` wrote.
        pub const BatchResult = struct {
            issues: []R.EditResult,
            /// The milestones' new tips, in the order of the due edits.
            milestones: []Oid,
        };

        /// Issue edits and milestones' due dates, in one ref transaction:
        /// all of it or none. See `Repo.editBatch`; `options` as for
        /// `Repo.update`.
        pub fn editBatch(
            self_in: Self,
            arena: Allocator,
            issue_edits: []const R.BatchEdit,
            dues: []const DueEdit,
            options: repo_mod.WriteOptions,
        ) Error!BatchResult {
            const self = self_in.withOptions(options);
            for (dues, 0..) |d, n| {
                if (!uuid_fmt.isCanonical(d.id)) return error.ReferenceNotFound;
                if (d.due == .set and !d.due.set.isValid()) return error.InvalidValue;
                for (dues[0..n]) |prev| if (std.mem.eql(
                    u8,
                    prev.id,
                    d.id,
                )) return error.DuplicateEdit;
            }
            const tips = try arena.alloc(Oid, dues.len);
            const more: DueCommits = .{ .catalog = self, .dues = dues, .tips = tips };
            const issues = try self.repo.editBatchWith(arena, issue_edits, more);
            return .{ .issues = issues, .milestones = tips };
        }

        const DueCommits = struct {
            catalog: Self,
            dues: []const DueEdit,
            /// Each attempt's new tips.
            tips: []Oid,

            pub fn ops(
                c: DueCommits,
                arena: Allocator,
                out: *std.ArrayList(@import("../backend/contract.zig").RefUpdate),
            ) Error!void {
                const repo = c.catalog.repo;
                for (c.dues, c.tips) |d, *new| {
                    const name = try repo_mod.milestoneRefName(arena, d.id);
                    const tip = (try repo.backend.resolveRef(
                        name,
                    )) orelse return error.ReferenceNotFound;
                    if (d.expect) |want| if (!want.eql(tip)) return error.VersionMismatch;
                    // Loaded like any write's, for the history limits.
                    _ = try repo.load(arena, .{ .name = name, .tip = tip });
                    const text = switch (d.due) {
                        .set => |date| try std.fmt.allocPrint(arena, "{f}", .{date}),
                        .clear => "",
                    };
                    const message = try repo.stampAuthor(arena, try trailers.build(
                        arena,
                        "Update due date",
                        "",
                        &.{.{ .key = "X-Due-Date", .value = text }},
                    ));
                    const who = try repo.identity(arena, d.author);
                    new.* = try repo.writeCommit(arena, &.{tip}, who, message);
                    try out.append(
                        arena,
                        .{ .name = name, .op = .{ .update = .{ .new = new.*, .old = tip } } },
                    );
                }
            }

            pub fn moved(c: DueCommits) Error!bool {
                const repo = c.catalog.repo;
                var buf: [128]u8 = undefined;
                for (c.dues) |d| if (d.expect) |want| {
                    const name = std.fmt.bufPrint(
                        &buf,
                        "{s}{s}",
                        .{ ref_prefix, d.id },
                    ) catch return true;
                    const now = (try repo.backend.resolveRef(
                        name,
                    )) orelse return error.ReferenceNotFound;
                    if (!now.eql(want)) return true;
                };
                return false;
            }
        };

        /// Every non-deleted issue in the milestone has to be done, and
        /// each gets a verify line. Writes that add work pin the milestone
        /// ref and move its guard ref, see `repo.guard_ref_prefix`.
        const CompleteBuilder = struct {
            /// A commit that changes nothing isn't written.
            pub const skip_unchanged = true;

            catalog: Self,
            id: []const u8,
            text: []const u8,

            pub fn message(
                c: CompleteBuilder,
                arena: Allocator,
                current: Issue,
            ) Error![]const u8 {
                _ = arena;
                _ = current;
                return c.text;
            }

            pub fn guard(
                c: CompleteBuilder,
                arena: Allocator,
                current: Issue,
            ) Error!repo_mod.Guarded {
                _ = current;
                // Before reading the issues, so new work conflicts.
                const bump = try arena.dupe(repo_mod.Guarded.Bump, &.{
                    try c.catalog.repo.readGuardRef(arena, c.id),
                });
                // A retired milestone has no issues in the projection, but
                // completing it brings them back: count them as if open.
                const known = try c.catalog.infos(arena);
                for (known) |*info| {
                    if (std.mem.eql(u8, info.id, c.id)) info.status = .open;
                }
                const issues = try c.catalog.repo.loadForGuards(arena);
                const proj = try c.catalog.projectWith(arena, issues, known, null);
                var verify: std.ArrayList(@import("../backend/contract.zig").RefUpdate) = .empty;
                for (proj.issues, proj.milestone, 0..) |issue, m, i| {
                    if (issue.deleted) continue;
                    if (!std.mem.eql(u8, m orelse continue, c.id)) continue;
                    if (!proj.isDone(@intCast(i))) return error.OpenWorkInMilestone;
                    try verify.append(arena, .{
                        .name = try std.fmt.allocPrint(
                            arena,
                            "{s}{s}",
                            .{ repo_mod.issue_ref_prefix, issue.id },
                        ),
                        .op = .{ .verify = issue.tip },
                    });
                }
                return .{ .verify = verify.items, .bump = bump };
            }
        };

        /// For projection options.
        pub fn infos(self: Self, arena: Allocator) Error![]projection_mod.MilestoneInfo {
            return infosOf(arena, try self.list(arena));
        }

        fn infosOf(
            arena: Allocator,
            all: []const Milestone,
        ) Allocator.Error![]projection_mod.MilestoneInfo {
            const out = try arena.alloc(projection_mod.MilestoneInfo, all.len);
            for (all, out) |m, *info| info.* = .{ .id = m.id, .status = m.status };
            return out;
        }

        pub const ProjectOptions = struct {
            /// For the default workflow state. Null takes the repo's
            /// `workflow_states`, or the built-in states without valid ones.
            workflow: ?[]const []const u8 = null,
            /// The milestones, if already loaded. Null loads them.
            milestones: ?[]const Milestone = null,
        };

        /// `projection.build` over `issues` (every issue, or `loadAround`'s)
        /// with the repo's limits and done states and the milestones'
        /// statuses: what front ends show.
        pub fn project(
            self: Self,
            arena: Allocator,
            issues: []const Issue,
            options: ProjectOptions,
        ) Error!projection_mod.Projection {
            const milestones = if (options.milestones) |ms|
                try infosOf(arena, ms)
            else
                try self.infos(arena);
            return self.projectWith(arena, issues, milestones, options.workflow);
        }

        fn projectWith(
            self: Self,
            arena: Allocator,
            issues: []const Issue,
            milestones: []const projection_mod.MilestoneInfo,
            workflow: ?[]const []const u8,
        ) Error!projection_mod.Projection {
            return projection_mod.build(arena, issues, .{
                .max_depth = self.repo.limits.max_depth,
                .workflow = workflow orelse self.repo.workflowStates() orelse
                    &fields_fmt.default_workflow,
                .milestones = milestones,
                .done_states = self.repo.doneStates(),
            });
        }

        /// Issues that can't be loaded are left out, as in the guards.
        fn projection(self: Self, arena: Allocator) Error!projection_mod.Projection {
            return self.project(arena, try self.repo.loadForGuards(arena), .{});
        }

        /// Closed and total leaves.
        pub fn progress(
            self: Self,
            arena: Allocator,
            id: []const u8,
        ) Error!projection_mod.Progress {
            const proj = try self.projection(arena);
            return proj.milestoneProgress(arena, id);
        }
    };
}

fn checkName(n: []const u8) error{InvalidText}!void {
    if (std.mem.trim(u8, n, " \t").len == 0 or std.mem.findAny(u8, n, "\r\n") != null or
        n.len > 256) return error.InvalidText;
}

const testing = std.testing;
const GitSim = @import("../backend/GitSim.zig");

test "catalog" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 51, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const cat = Catalog(GitSim).init(&sim);

    const v1 = try cat.create(arena, .{
        .name = "v1.0",
        .due = .{ .year = 2026, .month = 12, .day = 1 },
        .description = "First.",
    }, .{});
    const later = try cat.create(arena, .{ .name = "Later" }, .{});
    _ = later;
    const all = try cat.list(arena);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("v1.0", all[0].name); // dated first
    try testing.expectEqual(fields_fmt.MilestoneStatus.open, all[0].status);
    try testing.expectEqualStrings("First.", all[0].description);

    try testing.expectEqualStrings("v1.0", (try cat.resolve(arena, "v1.0")).one.name);
    try testing.expectEqualStrings(
        "v1.0",
        (try cat.resolve(arena, uuid_fmt.shortId(v1.id))).one.name,
    );
    try testing.expect(try cat.resolve(arena, "nope") == .none);

    _ = try cat.edit(arena, v1.id, .{ .name = "v1.0 GA", .due = .clear }, .{});
    _ = try cat.edit(arena, v1.id, .{ .description = "Ships it." }, .{});
    _ = try cat.edit(arena, v1.id, .{ .status = .retired }, .{});
    const m = (try cat.find(arena, v1.id)).?;
    try testing.expectEqualStrings("v1.0 GA", m.name);
    try testing.expect(m.due == null);
    try testing.expectEqual(fields_fmt.MilestoneStatus.retired, m.status);
    try testing.expectEqualStrings("Ships it.", m.description);
    try testing.expect(try cat.resolve(arena, "v1.0 GA") == .retired_name);
    try testing.expectError(
        error.InvalidValue,
        cat.create(arena, .{ .name = "x", .due = .{ .year = 2026, .month = 2, .day = 30 } }, .{}),
    );
    try testing.expectError(error.NothingToEdit, cat.edit(arena, v1.id, .{}, .{}));
}

test "milestone sync" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const origin: []const GitSim.World.ConfigEntry = &.{
        .{ .key = "remote.origin.url", .value = "sim:hub" },
    };
    var world: GitSim.World = .{ .seed = 53, .clones = &.{
        .{ .name = "alice", .config = origin },
        .{ .name = "bob", .config = origin },
        .{ .name = "hub" },
    } };
    const Sync = @import("sync.zig").Sync(GitSim);

    var a = try GitSim.init(arena, &world, 0);
    const v1 = try Catalog(GitSim).init(&a).create(arena, .{ .name = "v1" }, .{});
    _ = try Sync.init(&a).sync(arena, "origin", .{});
    try a.commit();

    var bob = try GitSim.init(arena, &world, 1);
    const first = try Sync.init(&bob).sync(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), first.merge.count(.created));
    const Ns = @import("sync.zig").Namespace;
    try testing.expectEqual(Ns.milestones, first.merge.entries[0].namespace);
    _ = try Catalog(GitSim).init(&bob).edit(arena, v1.id, .{ .name = "v1 (bob)" }, .{});
    _ = try Sync.init(&bob).sync(arena, "origin", .{});
    try bob.commit();

    a = try GitSim.init(arena, &world, 0);
    _ = try Catalog(GitSim).init(&a).edit(arena, v1.id, .{ .name = "v1 (alice)" }, .{});
    const merged = try Sync.init(&a).sync(arena, "origin", .{});
    try testing.expectEqual(@as(usize, 1), (try merged.conflicted(arena)).len);
    const m = (try Catalog(GitSim).init(&a).find(arena, v1.id)).?;
    try testing.expectEqual(@as(usize, 1), m.conflicts.len); // one name kept, the other reported
    const tip = (try a.readObject(arena, m.tip)).?;
    try testing.expect(std.mem.find(u8, tip.data, "Merge milestone\n") != null);
}

fn complete(cat: Catalog(GitSim), arena: Allocator, id: []const u8) !Oid {
    return cat.edit(arena, id, .{ .status = .completed }, .{});
}

test "issues in milestones" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 53, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const cat = Catalog(GitSim).init(&sim);
    const repo = repo_mod.Repo(GitSim).init(&sim);
    const refOf = struct {
        fn f(a: Allocator, id: []const u8) ![]const u8 {
            return std.fmt.allocPrint(a, "refs/issues/{s}", .{id});
        }
    }.f;

    const v1 = try cat.create(arena, .{ .name = "v1" }, .{});
    const mid = v1.id;
    const epic = try repo.create(arena, .{ .title = "Epic", .milestone = .linked(mid) }, .{});
    const task = try repo.create(arena, .{ .title = "Task", .parent = epic.id }, .{});
    const other = try repo.create(arena, .{
        .title = "Other",
        .parent = epic.id,
        .milestone = .{ .link = .none },
    }, .{});

    // The catalog name is the readable Milestone. Task inherits, Other opts
    // out.
    var proj = try cat.projection(arena);
    const e = proj.find(epic.id).?;
    try testing.expectEqualStrings("v1", proj.issues[e].field("Milestone").?);
    try testing.expectEqualStrings(mid, proj.milestone[proj.find(task.id).?].?);
    try testing.expect(proj.milestone[proj.find(other.id).?] == null);
    try testing.expectEqual(
        projection_mod.Progress{ .closed = 0, .total = 1 },
        try cat.progress(arena, mid),
    );

    // Every member has to be closed, Epic too, not only the leaf.
    try testing.expectError(error.OpenWorkInMilestone, complete(cat, arena, mid));
    _ = try repo.setState(arena, try refOf(arena, task.id), .{ .state = .closed }, .{});
    try testing.expectError(error.OpenWorkInMilestone, complete(cat, arena, mid));
    _ = try repo.setState(arena, try refOf(arena, other.id), .{ .state = .closed }, .{});
    _ = try repo.setState(arena, try refOf(arena, epic.id), .{ .state = .closed }, .{});
    _ = try cat.edit(arena, mid, .{ .status = .completed }, .{});

    try testing.expectError(
        error.MilestoneCompleted,
        repo.setState(arena, try refOf(arena, epic.id), .{ .state = .open }, .{}),
    );
    try testing.expectError(
        error.MilestoneCompleted,
        repo.create(arena, .{ .title = "Late", .milestone = .linked(mid) }, .{}),
    );
    const loose = try repo.create(arena, .{ .title = "Loose" }, .{});
    try testing.expectError(error.MilestoneCompleted, repo.edit(
        arena,
        try refOf(arena, loose.id),
        .{ .milestone = .linked(mid) },
        .{},
    ));
    _ = try repo.setDeleted(arena, try refOf(arena, loose.id), .{}, .{});
    _ = try cat.edit(arena, mid, .{ .status = .open }, .{});
    _ = try repo.setDeleted(arena, try refOf(arena, loose.id), .{ .deleted = false }, .{});
    _ = try repo.edit(arena, try refOf(arena, loose.id), .{ .milestone = .linked(mid) }, .{});
    _ = try repo.setDeleted(arena, try refOf(arena, loose.id), .{}, .{});
    _ = try cat.edit(arena, mid, .{ .status = .completed }, .{});
    try testing.expectError(
        error.MilestoneCompleted,
        repo.setDeleted(arena, try refOf(arena, loose.id), .{ .deleted = false }, .{}),
    );

    // Retired: can't be selected, members show the problem.
    _ = try cat.edit(arena, mid, .{ .status = .retired }, .{});
    try testing.expectError(error.MilestoneRetired, repo.edit(
        arena,
        try refOf(arena, other.id),
        .{ .milestone = .linked(mid) },
        .{},
    ));
    proj = try cat.projection(arena);
    var retired: usize = 0;
    for (proj.problems) |p| {
        if (p.kind == .milestone_retired) retired += 1;
    }
    try testing.expectEqual(@as(usize, 1), retired); // Epic: the explicit one
}

test "milestone guards: retired, inherited work, damaged issues" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 57, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const cat = Catalog(GitSim).init(&sim);
    const repo = repo_mod.Repo(GitSim).init(&sim);
    const refOf = struct {
        fn f(a: Allocator, id: []const u8) ![]const u8 {
            return std.fmt.allocPrint(a, "refs/issues/{s}", .{id});
        }
    }.f;

    // Issue writes don't reach milestones, and an ID goes with explicit.
    const m1 = (try cat.create(arena, .{ .name = "m1" }, .{})).id;
    const m2 = (try cat.create(arena, .{ .name = "m2" }, .{})).id;
    const m2_ref = try repo_mod.milestoneRefName(arena, m2);
    try testing.expectError(
        error.InvalidIssueRef,
        repo.setState(arena, m2_ref, .{ .state = .closed }, .{}),
    );
    try testing.expectError(
        error.InvalidValue,
        repo.create(
            arena,
            .{ .title = "x", .milestone = .{ .text = "x", .link = .{ .id = m1 } } },
            .{},
        ),
    );

    // A retired milestone still needs its work closed to complete.
    const open = try repo.create(arena, .{ .title = "Open", .milestone = .linked(m2) }, .{});
    _ = try cat.edit(arena, m2, .{ .status = .retired }, .{});
    try testing.expectError(error.OpenWorkInMilestone, complete(cat, arena, m2));
    _ = try cat.edit(arena, m2, .{ .status = .open }, .{});
    _ = try repo.setState(arena, try refOf(arena, open.id), .{ .state = .closed }, .{});

    // Restoring a closed issue would bring the open work below it along:
    // refused, the issue would be closed over open work.
    const root = try repo.create(arena, .{ .title = "Root", .milestone = .linked(m1) }, .{});
    const mid = try repo.create(arena, .{
        .title = "Mid",
        .parent = root.id,
        .milestone = .linked(m2),
    }, .{});
    const leaf = try repo.create(arena, .{ .title = "Leaf", .parent = mid.id }, .{});
    for ([_][]const u8{ leaf.id, mid.id }) |id| {
        _ = try repo.setState(arena, try refOf(arena, id), .{ .state = .closed }, .{});
    }
    for ([_][]const u8{ leaf.id, mid.id }) |id| {
        _ = try repo.setDeleted(arena, try refOf(arena, id), .{}, .{});
    }
    // A damaged issue doesn't stop completing.
    const blob = try sim.writeObject(.blob, "not a commit");
    const damaged = "refs/issues/0b8c7a52-3f1e-4d2a-9b6c-5e4f3a2b1c0d";
    try sim.updateRefs(&.{.{ .name = damaged, .op = .{ .create = blob } }});
    _ = try complete(cat, arena, m2);
    _ = try repo.setDeleted(arena, try refOf(arena, leaf.id), .{ .deleted = false }, .{});
    _ = try repo.setState(arena, try refOf(arena, leaf.id), .{ .state = .open }, .{});
    try testing.expectError(
        error.OpenDescendants,
        repo.setDeleted(arena, try refOf(arena, mid.id), .{ .deleted = false }, .{}),
    );

    // A name, a due date and a description in one commit.
    const before = (try cat.find(arena, m1)).?.tip;
    const tip = try cat.edit(arena, m1, .{
        .name = "m1 GA",
        .due = .{ .set = .{ .year = 2026, .month = 12, .day = 1 } },
        .description = "All of it.",
        .message = "Rename\n\nFor the release.",
    }, .{});
    const raw = (try sim.readObject(arena, tip)).?;
    const c = try object.Commit.parse(arena, sim.objectFormat(), raw.data);
    try testing.expect(c.parents.len == 1 and c.parents[0].eql(before));
    const m = (try cat.find(arena, m1)).?;
    try testing.expectEqualStrings("m1 GA", m.name);
    try testing.expectEqualStrings("All of it.", m.description);
}

test "Catalog.choose" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 52, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = repo_mod.Repo(GitSim).init(&sim);
    const cat = Catalog(GitSim).fromRepo(repo);

    const v1 = try cat.create(arena, .{ .name = "v1" }, .{});
    const v1_id = v1.id;
    // A name that is another milestone's ID prefix.
    const prefix = try arena.dupe(u8, v1_id[0..4]);
    const named = try cat.create(arena, .{ .name = prefix }, .{});

    // Names match by name only, never as an ID prefix.
    const by_name = (try cat.choose(arena, .{ .name = prefix })).ok;
    try testing.expectEqualStrings(named.id, by_name.id.?);
    // `id` takes the prefix.
    try testing.expectEqualStrings(v1_id, (try cat.choose(arena, .{ .id = prefix })).ok.id.?);

    // Plain text on an issue linked to the catalog drops the link.
    const linked_ref = try repo.create(
        arena,
        .{ .title = "Linked", .milestone = .linked(v1_id) },
        .{},
    );
    const linked = try repo.load(arena, .{
        .name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{linked_ref.id}),
        .tip = linked_ref.tip,
    });
    const text = (try cat.choose(arena, .{ .name = "someday", .current = linked })).ok;
    try testing.expectEqualStrings("someday", text.text.?);
    try testing.expectEqual(fields_fmt.MilestoneMode.none, text.mode.?);
    try testing.expect(text.text_only);

    // Clearing stops inheriting through a parent given in the same write.
    const cleared = (try cat.choose(arena, .{ .name = "", .parent_given = true })).ok;
    try testing.expectEqual(fields_fmt.MilestoneMode.none, cleared.mode.?);
    try testing.expect((try cat.choose(arena, .{ .name = "" })).ok.mode == null);

    try testing.expect(
        (try cat.choose(arena, .{ .name = "v1", .id = prefix })).refused == .id_with_name,
    );
    try testing.expect(
        (try cat.choose(arena, .{ .mode = .explicit })).refused == .explicit_needs_id,
    );
    try testing.expect(
        (try cat.choose(arena, .{ .name = "v9", .mode = .explicit })).refused == .no_open_named,
    );

    _ = try cat.edit(arena, v1_id, .{ .status = .retired }, .{});
    try testing.expect((try cat.choose(arena, .{ .name = "v1" })).refused == .not_open);
    try testing.expect((try cat.choose(arena, .{ .id = "v1" })).refused == .retired_name);
}

test "Milestone: updated, author and when its status changed" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 59, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const cat = Catalog(GitSim).init(&sim);
    const made = try cat.create(arena, .{ .name = "v1" }, .{});
    var m = (try cat.find(arena, made.id)).?;
    try testing.expect(m.status_changed == null);
    try testing.expectEqual(m.created, m.updated);
    try testing.expect(m.author.email.len > 0);
    _ = try cat.edit(arena, made.id, .{ .status = .completed }, .{});
    _ = try cat.edit(arena, made.id, .{ .description = "Shipped." }, .{});
    m = (try cat.find(arena, made.id)).?;
    try testing.expect(m.status_changed.? > m.created);
    try testing.expect(m.updated > m.status_changed.?);
}

test "editBatch: issues and due dates together" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 52, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const cat = Catalog(GitSim).init(&sim);
    const v1 = try cat.create(arena, .{ .name = "v1", .due = day("2026-12-01") }, .{});
    const issue = try cat.repo.create(arena, .{ .title = "Work" }, .{});
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{issue.id});

    _ = try cat.editBatch(arena, &.{
        .{ .ref_name = ref, .spec = .{ .due_date = .{ .set = day("2026-11-20") } } },
    }, &.{
        .{ .id = v1.id, .due = .{ .set = day("2026-12-15") }, .expect = v1.tip },
    }, .{});
    const m = (try cat.find(arena, v1.id)).?;
    try testing.expectEqual(@as(u8, 15), m.due.?.day);
    // Only a due date; a stale one writes nothing, the issue neither.
    const before = (try sim.resolveRef(ref)).?;
    try testing.expectError(error.VersionMismatch, cat.editBatch(arena, &.{
        .{ .ref_name = ref, .spec = .{ .due_date = .{ .set = day("2026-11-21") } } },
    }, &.{
        .{ .id = v1.id, .due = .clear, .expect = v1.tip },
    }, .{}));
    try testing.expect(before.eql((try sim.resolveRef(ref)).?));
    const cleared = try cat.editBatch(arena, &.{}, &.{.{ .id = v1.id, .due = .clear }}, .{});
    try testing.expect((try cat.find(arena, v1.id)).?.due == null);
    try testing.expect(
        cleared.milestones[0].eql(
            (try sim.resolveRef(try repo_mod.milestoneRefName(arena, v1.id))).?,
        ),
    );

    // Into the milestone and its new due date at once: the guard reads the
    // milestone the batch updates, which checks it.
    const moved = try cat.editBatch(arena, &.{
        .{ .ref_name = ref, .spec = .{ .milestone = .linked(v1.id) } },
    }, &.{
        .{ .id = v1.id, .due = .{ .set = day("2027-01-15") } },
    }, .{});
    try testing.expectEqual(@as(usize, 1), moved.issues.len);
    const linked = try cat.repo.load(arena, .{ .name = ref, .tip = moved.issues[0].tip });
    try testing.expectEqualStrings(v1.id, linked.milestone_id.?);
    const m_after = (try cat.find(arena, v1.id)).?;
    try testing.expect(m_after.tip.eql(moved.milestones[0]));
    try testing.expectEqual(@as(u16, 2027), m_after.due.?.year);

    // A milestone that is gone: not found, whether or not expected.
    const gone = "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f";
    try testing.expectError(
        error.ReferenceNotFound,
        cat.editBatch(arena, &.{}, &.{.{ .id = gone, .due = .clear }}, .{}),
    );
    try testing.expectError(error.DuplicateEdit, cat.editBatch(arena, &.{}, &.{
        .{ .id = v1.id, .due = .clear },
        .{ .id = v1.id, .due = .clear },
    }, .{}));
}

test "editBatch: a milestone deleted after a conflict is not found" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 53, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const cat = Catalog(GitSim).init(&sim);
    const v1 = try cat.create(arena, .{ .name = "v1" }, .{});
    const name = try repo_mod.milestoneRefName(arena, v1.id);
    try sim.updateRefs(&.{.{ .name = name, .op = .{ .delete = v1.tip } }});
    const more: Catalog(
        GitSim,
    ).DueCommits = .{
        .catalog = cat,
        .dues = &.{.{ .id = v1.id, .due = .clear, .expect = v1.tip }},
        .tips = &.{},
    };
    try testing.expectError(error.ReferenceNotFound, more.moved());
}

fn day(text: []const u8) fields_fmt.Date {
    return fields_fmt.Date.parse(text).?;
}

test "WriteOptions: milestone writes and batches take a dry run and an author ID" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 64, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const cat = Catalog(GitSim).init(&sim);
    const dry = try cat.create(arena, .{ .name = "v0" }, .{ .dry_run = true });
    try testing.expect(try cat.find(arena, dry.id) == null);

    const ada = "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d";
    const v1 = try cat.create(arena, .{ .name = "v1" }, .{ .author_id = ada });
    const edited = try cat.edit(arena, v1.id, .{ .name = "v1.0" }, .{ .dry_run = true });
    try testing.expect(!edited.eql(v1.tip));
    try testing.expectEqualStrings("v1", (try cat.find(arena, v1.id)).?.name);

    const dues = [_]Catalog(GitSim).DueEdit{.{ .id = v1.id, .due = .{ .set = day("2027-01-15") } }};
    const batch = try cat.editBatch(arena, &.{}, &dues, .{ .dry_run = true });
    try testing.expect((try cat.find(arena, v1.id)).?.due == null);
    try testing.expect(try sim.readObject(arena, batch.milestones[0]) == null);
    const done = try cat.editBatch(arena, &.{}, &dues, .{ .author_id = ada });
    const obj = (try sim.readObject(arena, done.milestones[0])).?;
    try testing.expect(std.mem.find(u8, obj.data, ada) != null);
}

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
const Allocator = std.mem.Allocator;
const object = @import("../backend/object.zig");
const trailers = @import("../format/trailers.zig");
const fields_fmt = @import("../format/fields.zig");
const uuid_fmt = @import("../format/uuid.zig");
const repo_mod = @import("repo.zig");
const projection_mod = @import("projection.zig");

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
    conflicts: []const @import("../model/issue.zig").Conflict,
};

pub fn Catalog(comptime B: type) type {
    const R = repo_mod.Repo(B);
    return struct {
        const Self = @This();

        repo: R,

        pub const Error = R.Error;

        pub fn init(backend: *B) Self {
            return .{ .repo = R.init(backend) };
        }

        /// With the repo's limits and done states.
        pub fn of(repo: R) Self {
            return .{ .repo = repo };
        }

        fn b(self: Self) *B {
            return self.repo.backend;
        }

        pub fn refs(self: Self, arena: Allocator) Error![]repo_mod.IssueRef {
            const entries = try self.b().listRefs(arena, ref_prefix);
            const out = try arena.alloc(repo_mod.IssueRef, entries.len);
            for (entries, out) |e, *r| r.* = .{ .name = e.name, .tip = e.oid };
            return out;
        }

        pub fn load(self: Self, arena: Allocator, ref: repo_mod.IssueRef) Error!Milestone {
            const m = try self.repo.load(arena, ref);
            return .{
                .id = ref.id(),
                .tip = ref.tip,
                .name = m.field("Name") orelse m.title,
                .description = m.description,
                .due = m.ext.due_date,
                .status = fields_fmt.MilestoneStatus.parse(m.field("X-Milestone-Status")),
                .created = m.created,
                .conflicts = m.conflicts,
            };
        }

        /// By due date (none last), then name.
        pub fn list(self: Self, arena: Allocator) Error![]Milestone {
            const all = try self.refs(arena);
            const out = try arena.alloc(Milestone, all.len);
            for (all, out) |r, *m| m.* = try self.load(arena, r);
            std.mem.sort(Milestone, out, {}, struct {
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
            const name = try std.fmt.allocPrint(arena, "{s}{s}", .{ ref_prefix, id });
            const tip = (try self.b().resolveRef(name)) orelse return null;
            return try self.load(arena, .{ .name = name, .tip = tip });
        }

        pub const Match = union(enum) {
            none,
            one: Milestone,
            many: []const Milestone,
        };

        /// By ID prefix, else by exact name. Retired ones only match by ID.
        pub fn resolve(self: Self, arena: Allocator, key: []const u8) Error!Match {
            const all = try self.list(arena);
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

        pub const CreateSpec = struct {
            name: []const u8,
            description: []const u8 = "",
            due: ?[]const u8 = null,
            author: ?repo_mod.Signature = null,
        };

        pub const Created = struct { id: uuid_fmt.Uuid, tip: Oid };

        pub fn create(self: Self, arena: Allocator, spec: CreateSpec) Error!Created {
            try checkName(spec.name);
            var tl: std.ArrayList(trailers.Trailer) = .empty;
            try tl.append(arena, .{ .key = "Name", .value = spec.name });
            if (spec.due) |d| {
                if (fields_fmt.Date.parse(d) == null) return error.InvalidValue;
                try tl.append(arena, .{ .key = "X-Due-Date", .value = d });
            }
            try tl.append(arena, .{ .key = "X-Milestone-Status", .value = @tagName(fields_fmt.MilestoneStatus.open) });
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
                const name = try std.fmt.allocPrint(arena, "{s}{s}", .{ ref_prefix, id.slice() });
                self.b().updateRefs(&.{.{ .name = name, .op = .{ .create = oid } }}) catch |err|
                    switch (err) {
                        error.RefConflict => continue,
                        else => |e| return e,
                    };
                return .{ .id = id, .tip = oid };
            }
            return error.ConcurrentModification;
        }

        pub const EditSpec = struct {
            name: ?[]const u8 = null,
            /// "" clears it.
            due: ?[]const u8 = null,
            status: ?fields_fmt.MilestoneStatus = null,
            message: ?[]const u8 = null,
            author: ?repo_mod.Signature = null,
            expect: ?Oid = null,
        };

        /// One commit for all of it.
        pub fn edit(self: Self, arena: Allocator, id: []const u8, spec: EditSpec) Error!Oid {
            var tl: std.ArrayList(trailers.Trailer) = .empty;
            var what: std.ArrayList([]const u8) = .empty;
            if (spec.name) |n| {
                try checkName(n);
                try tl.append(arena, .{ .key = "Name", .value = n });
                try what.append(arena, "name");
            }
            if (spec.due) |d| {
                if (d.len > 0 and fields_fmt.Date.parse(d) == null) return error.InvalidValue;
                try tl.append(arena, .{ .key = "X-Due-Date", .value = d });
                try what.append(arena, "due date");
            }
            if (spec.status) |s| {
                try tl.append(arena, .{ .key = "X-Milestone-Status", .value = @tagName(s) });
            }
            if (tl.items.len == 0) return error.NothingToEdit;
            const subject = spec.message orelse if (spec.status) |s| switch (s) {
                .completed => "Complete milestone",
                .retired => "Retire milestone",
                .open => "Reopen milestone",
            } else try std.fmt.allocPrint(
                arena,
                "Update {s}",
                .{try std.mem.join(arena, ", ", what.items)},
            );
            const message = try trailers.build(arena, subject, "", tl.items);
            const name = try refName(arena, id);
            if (spec.status == .completed) return self.repo.appendWith(
                arena,
                name,
                spec.author,
                spec.expect,
                CompleteBuilder{ .catalog = self, .id = id, .text = message },
            );
            return self.repo.appendRaw(arena, name, spec.author, spec.expect, message);
        }

        /// Every non-deleted issue in the milestone has to be done, and
        /// each gets a verify line. Writes that add work pin the milestone
        /// ref and move its guard ref, see `repo.guard_ref_prefix`.
        const CompleteBuilder = struct {
            catalog: Self,
            id: []const u8,
            text: []const u8,

            pub fn message(
                c: CompleteBuilder,
                arena: Allocator,
                current: anytype,
            ) Error![]const u8 {
                _ = arena;
                _ = current;
                return c.text;
            }

            pub fn guard(
                c: CompleteBuilder,
                arena: Allocator,
                current: anytype,
            ) Error!repo_mod.Guarded {
                _ = current;
                // Before reading the issues, so new work conflicts.
                const bump = try arena.dupe(repo_mod.Guarded.Bump, &.{
                    try repo_mod.readGuardRef(c.catalog.repo.backend, arena, c.id),
                });
                const proj = try c.catalog.projection(arena);
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
        pub fn infos(self: Self, arena: Allocator) Error![]const projection_mod.MilestoneInfo {
            const all = try self.list(arena);
            const out = try arena.alloc(projection_mod.MilestoneInfo, all.len);
            for (all, out) |m, *info| info.* = .{ .id = m.id, .status = switch (m.status) {
                .open => .open,
                .completed => .completed,
                .retired => .retired,
            } };
            return out;
        }

        pub fn projection(self: Self, arena: Allocator) Error!projection_mod.Projection {
            const issues = try self.repo.loadAll(arena);
            if (issues.len > self.repo.limits.max_guard_scan) return error.GuardScanTooLarge;
            return projection_mod.build(arena, issues, .{
                .milestones = try self.infos(arena),
                .done_states = self.repo.done_states,
            });
        }

        /// Closed and total leaves.
        pub fn progress(
            self: Self,
            arena: Allocator,
            id: []const u8,
        ) Error!projection_mod.Progress {
            const proj = try self.projection(arena);
            var closed: u32 = 0;
            const leaves = try proj.milestoneLeaves(arena, id);
            for (leaves) |i| {
                if (proj.isDone(i)) closed += 1;
            }
            return .{ .closed = closed, .total = @intCast(leaves.len) };
        }

        pub fn editDescription(
            self: Self,
            arena: Allocator,
            id: []const u8,
            text: []const u8,
        ) Error!Oid {
            return self.repo.editDescription(arena, try refName(arena, id), text, .{});
        }
    };
}

fn refName(arena: Allocator, id: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}", .{ ref_prefix, id });
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
        .due = "2026-12-01",
        .description = "First.",
    });
    const later = try cat.create(arena, .{ .name = "Later" });
    _ = later;
    const all = try cat.list(arena);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("v1.0", all[0].name); // dated first
    try testing.expectEqual(fields_fmt.MilestoneStatus.open, all[0].status);
    try testing.expectEqualStrings("First.", all[0].description);

    try testing.expectEqualStrings("v1.0", (try cat.resolve(arena, "v1.0")).one.name);
    try testing.expectEqualStrings("v1.0", (try cat.resolve(arena, v1.id.short())).one.name);
    try testing.expect(try cat.resolve(arena, "nope") == .none);

    _ = try cat.edit(arena, v1.id.slice(), .{ .name = "v1.0 GA", .due = "" });
    _ = try cat.editDescription(arena, v1.id.slice(), "Ships it.");
    _ = try cat.edit(arena, v1.id.slice(), .{ .status = .retired });
    const m = (try cat.find(arena, v1.id.slice())).?;
    try testing.expectEqualStrings("v1.0 GA", m.name);
    try testing.expect(m.due == null);
    try testing.expectEqual(fields_fmt.MilestoneStatus.retired, m.status);
    try testing.expectEqualStrings("Ships it.", m.description);
    try testing.expect(try cat.resolve(arena, "v1.0 GA") == .none);
    try testing.expectError(error.InvalidValue, cat.create(arena, .{ .name = "x", .due = "soon" }));
    try testing.expectError(error.NothingToEdit, cat.edit(arena, v1.id.slice(), .{}));
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
    const v1 = try Catalog(GitSim).init(&a).create(arena, .{ .name = "v1" });
    _ = try Sync.init(&a).sync(arena, "origin");
    try a.commit();

    var bob = try GitSim.init(arena, &world, 1);
    const first = try Sync.init(&bob).sync(arena, "origin");
    try testing.expectEqual(@as(usize, 1), first.merge.count(.created));
    const Ns = @import("sync.zig").Namespace;
    try testing.expectEqual(Ns.milestones, first.merge.entries[0].namespace);
    _ = try Catalog(GitSim).init(&bob).edit(arena, v1.id.slice(), .{ .name = "v1 (bob)" });
    _ = try Sync.init(&bob).sync(arena, "origin");
    try bob.commit();

    a = try GitSim.init(arena, &world, 0);
    _ = try Catalog(GitSim).init(&a).edit(arena, v1.id.slice(), .{ .name = "v1 (alice)" });
    const merged = try Sync.init(&a).sync(arena, "origin");
    try testing.expectEqual(@as(usize, 1), (try merged.conflicted(arena)).len);
    const m = (try Catalog(GitSim).init(&a).find(arena, v1.id.slice())).?;
    try testing.expectEqual(@as(usize, 1), m.conflicts.len); // one name kept, the other reported
    const tip = (try a.readObject(arena, m.tip)).?;
    try testing.expect(std.mem.find(u8, tip.data, "Merge milestone\n") != null);
}

fn complete(cat: Catalog(GitSim), arena: Allocator, id: []const u8) !Oid {
    return cat.edit(arena, id, .{ .status = .completed });
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

    const v1 = try cat.create(arena, .{ .name = "v1" });
    const mid = v1.id.slice();
    const epic = try repo.create(arena, .{ .title = "Epic", .milestone_id = mid });
    const task = try repo.create(arena, .{ .title = "Task", .parent = epic.id.slice() });
    const other = try repo.create(arena, .{
        .title = "Other",
        .parent = epic.id.slice(),
        .milestone_mode = .none,
    });

    // The catalog name is the readable Milestone. Task inherits, Other opts
    // out.
    var proj = try cat.projection(arena);
    const e = proj.find(epic.id.slice()).?;
    try testing.expectEqualStrings("v1", proj.issues[e].field("Milestone").?);
    try testing.expectEqualStrings(mid, proj.milestone[proj.find(task.id.slice()).?].?);
    try testing.expect(proj.milestone[proj.find(other.id.slice()).?] == null);
    try testing.expectEqual(
        projection_mod.Progress{ .closed = 0, .total = 1 },
        try cat.progress(arena, mid),
    );

    // Every member has to be closed, Epic too, not only the leaf.
    try testing.expectError(error.OpenWorkInMilestone, complete(cat, arena, mid));
    _ = try repo.setState(arena, try refOf(arena, task.id.slice()), .{ .state = .closed });
    try testing.expectError(error.OpenWorkInMilestone, complete(cat, arena, mid));
    _ = try repo.setState(arena, try refOf(arena, other.id.slice()), .{ .state = .closed });
    _ = try repo.setState(arena, try refOf(arena, epic.id.slice()), .{ .state = .closed });
    _ = try cat.edit(arena, mid, .{ .status = .completed });

    try testing.expectError(
        error.MilestoneCompleted,
        repo.setState(arena, try refOf(arena, epic.id.slice()), .{ .state = .open }),
    );
    try testing.expectError(
        error.MilestoneCompleted,
        repo.create(arena, .{ .title = "Late", .milestone_id = mid }),
    );
    const loose = try repo.create(arena, .{ .title = "Loose" });
    try testing.expectError(error.MilestoneCompleted, repo.edit(
        arena,
        try refOf(arena, loose.id.slice()),
        .{ .milestone_id = mid },
    ));
    _ = try repo.setDeleted(arena, try refOf(arena, loose.id.slice()), true, .{});
    _ = try cat.edit(arena, mid, .{ .status = .open });
    _ = try repo.setDeleted(arena, try refOf(arena, loose.id.slice()), false, .{});
    _ = try repo.edit(arena, try refOf(arena, loose.id.slice()), .{ .milestone_id = mid });
    _ = try repo.setDeleted(arena, try refOf(arena, loose.id.slice()), true, .{});
    _ = try cat.edit(arena, mid, .{ .status = .completed });
    try testing.expectError(
        error.MilestoneCompleted,
        repo.setDeleted(arena, try refOf(arena, loose.id.slice()), false, .{}),
    );

    // Retired: can't be selected, members show the problem.
    _ = try cat.edit(arena, mid, .{ .status = .retired });
    try testing.expectError(error.MilestoneRetired, repo.edit(
        arena,
        try refOf(arena, other.id.slice()),
        .{ .milestone_id = mid },
    ));
    proj = try cat.projection(arena);
    var retired: usize = 0;
    for (proj.problems) |p| {
        if (p.kind == .milestone_retired) retired += 1;
    }
    try testing.expectEqual(@as(usize, 1), retired); // Epic: the explicit one
}

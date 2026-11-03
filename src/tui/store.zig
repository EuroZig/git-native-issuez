//! The TUI's view of the repository: every issue, loaded at once, and the
//! writes. Generic over the backend so tests run on the simulator.
//!
//! A snapshot lives in its own arena and is replaced whole by `reload`,
//! which every write is followed by. Nothing outside may keep pointers
//! into it across a reload: views keep issue IDs (`Id`), not slices.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const issuez = @import("issuez");

const Issue = issuez.engine.Issue;
const Oid = issuez.engine.Oid;
const Projection = issuez.projection.Projection;
const Milestone = issuez.milestone.Milestone;
const core = issuez.format.core;

/// An issue ID kept across reloads. IDs are UUIDs; longer ones (another
/// tool's refs) are cut, and then simply aren't found again.
pub const Id = struct {
    buf: [64]u8 = undefined,
    len: u8 = 0,

    pub fn of(id: []const u8) Id {
        var out: Id = .{};
        out.len = @intCast(@min(id.len, out.buf.len));
        @memcpy(out.buf[0..out.len], id[0..out.len]);
        return out;
    }

    pub fn slice(i: *const Id) []const u8 {
        return i.buf[0..i.len];
    }

    pub fn eql(a: *const Id, b: []const u8) bool {
        return std.mem.eql(u8, a.slice(), b);
    }
};

pub const Snapshot = struct {
    /// Not deleted ones too; views leave those out.
    issues: []const Issue = &.{},
    proj: Projection,
    settings: issuez.Settings = .{},
    /// The catalog, by due date then name.
    milestones: []const Milestone = &.{},

    pub fn find(s: *const Snapshot, id: []const u8) ?u32 {
        return s.proj.find(id);
    }

    pub fn isDone(s: *const Snapshot, i: u32) bool {
        return s.proj.isDone(i);
    }

    /// The issue whose ID starts with `prefix`. Deleted ones count only
    /// when no other matches.
    pub fn resolve(s: *const Snapshot, prefix: []const u8) Resolved {
        if (prefix.len == 0) return .none;
        var live: ?u32 = null;
        var live_count: u32 = 0;
        var deleted: ?u32 = null;
        var deleted_count: u32 = 0;
        for (s.issues, 0..) |issue, i| {
            if (!std.mem.startsWith(u8, issue.id, prefix)) continue;
            if (issue.deleted) {
                deleted_count += 1;
                deleted = @intCast(i);
            } else {
                live_count += 1;
                live = @intCast(i);
            }
        }
        if (live_count == 1) return .{ .one = live.? };
        if (live_count > 1 or deleted_count > 1) return .many;
        if (deleted_count == 1) return .{ .one = deleted.? };
        return .none;
    }

    pub const Resolved = union(enum) { none, many, one: u32 };

    /// The milestone's name, for an issue's effective milestone.
    pub fn milestoneName(s: *const Snapshot, i: u32) ?[]const u8 {
        if (s.proj.milestone[i]) |mid| {
            for (s.milestones) |m| if (std.mem.eql(u8, m.id, mid)) return m.name;
        }
        return s.issues[i].field("Milestone");
    }
};

/// What the create form asks for. References are full IDs.
pub const CreateInput = struct {
    title: []const u8,
    body: []const u8 = "",
    labels: []const []const u8 = &.{},
    assignee: ?[]const u8 = null,
    priority: ?core.Priority = null,
    workflow: ?[]const u8 = null,
    parent: ?[]const u8 = null,
};

pub fn Store(comptime B: type) type {
    const Repo = issuez.Repo(B);
    const Catalog = issuez.Catalog(B);

    return struct {
        const Self = @This();

        gpa: Allocator,
        backend: *B,
        snap_arena: std.heap.ArenaAllocator,
        snap: Snapshot,
        /// For one write, reset after it.
        scratch: std.heap.ArenaAllocator,
        /// Bumped by every reload that worked, so views can tell.
        generation: u32 = 0,
        /// The refs as the snapshot read them, in its arena.
        refs: issuez.changes.RefState = .{},
        /// Why the reload after a write that worked failed, until taken.
        reload_error: ?anyerror = null,

        pub fn init(gpa: Allocator, backend: *B) Self {
            return .{
                .gpa = gpa,
                .backend = backend,
                .snap_arena = .init(gpa),
                .snap = .{ .proj = emptyProjection() },
                .scratch = .init(gpa),
            };
        }

        pub fn deinit(self: *Self) void {
            self.snap_arena.deinit();
            self.scratch.deinit();
            self.* = undefined;
        }

        fn emptyProjection() Projection {
            return .{
                .issues = &.{},
                .parent = &.{},
                .children = &.{},
                .blockers = &.{},
                .blocks = &.{},
                .depth = &.{},
                .problems = &.{},
                .roots = &.{},
                .options = .{},
                .index = .empty,
                .milestone = &.{},
                .leaves = &.{},
                .problems_of = &.{},
            };
        }

        fn repo(self: *Self) Repo {
            var r = Repo.init(self.backend);
            self.snap.settings.apply(&r);
            return r;
        }

        /// Reads everything again. On failure the old snapshot stays.
        pub fn reload(self: *Self) !void {
            if (@hasDecl(B, "refresh")) self.backend.refresh();
            var next: std.heap.ArenaAllocator = .init(self.gpa);
            errdefer next.deinit();
            const a = next.allocator();

            // Before the issues: a write in between then shows as a change
            // next time, never the other way round.
            const refs = try issuez.changes.RefState.read(a, self.backend);
            const settings = try issuez.settings.read(a, self.backend);
            if (settings.invalid_done_state != null) return error.InvalidDoneStates;
            var r = Repo.init(self.backend);
            settings.apply(&r);
            // Issues that can't be loaded are left out; `git issue fsck`
            // reports them.
            const issues = try r.loadForGuards(a);
            const cat = Catalog.of(r);
            const milestones = try cat.list(a);
            const proj = try cat.project(a, issues, .{ .milestones = milestones });
            assert(proj.issues.len == issues.len);

            self.snap_arena.deinit();
            self.snap_arena = next;
            self.snap = .{ .issues = issues, .proj = proj, .settings = settings, .milestones = milestones };
            self.refs = refs;
            self.generation +%= 1;
        }

        /// What `reloadIfChanged` found.
        pub const Outside = struct {
            /// Issues created, changed or deleted.
            issues: u32 = 0,
            /// One of them.
            first: Id = .{},
            milestones: bool = false,
        };

        /// Reads the refs, and everything again if they moved since the
        /// last reload or `settings` says git config may have changed.
        /// Null when it didn't reload.
        pub fn reloadIfChanged(self: *Self, settings: bool) !?Outside {
            const a = self.begin();
            const now = try issuez.changes.RefState.read(a, self.backend);
            const d = try issuez.changes.diff(a, self.refs, now);
            if (d.empty() and !settings) return null;
            var out: Outside = .{ .issues = @intCast(d.issues.len), .milestones = d.milestones };
            if (d.issues.len > 0) out.first = .of(d.issues[0]);
            try self.reload();
            return out;
        }

        fn begin(self: *Self) Allocator {
            _ = self.scratch.reset(.retain_capacity);
            return self.scratch.allocator();
        }

        fn refName(a: Allocator, id: []const u8) Allocator.Error![]const u8 {
            return std.fmt.allocPrint(a, "{s}{s}", .{ issuez.engine.issue_ref_prefix, id });
        }

        /// The tip a write expects, so it fails instead of overwriting a
        /// change made meanwhile: `given` (what a dialog showed when it
        /// opened), else what the snapshot shows.
        fn expect(self: *Self, id: []const u8, given: ?Oid) ?Oid {
            if (given) |g| return g;
            const i = self.snap.find(id) orelse return null;
            return self.snap.issues[i].tip;
        }

        /// After a write that worked. A failed reload isn't the write's
        /// failure: it would keep the dialog open, and saving again would
        /// write twice. `takeReloadError` has it.
        fn reloadAfterWrite(self: *Self) void {
            self.reload() catch |e| {
                self.reload_error = e;
            };
        }

        pub fn takeReloadError(self: *Self) ?anyerror {
            defer self.reload_error = null;
            return self.reload_error;
        }

        /// Returns the new issue's ID.
        pub fn create(self: *Self, input: CreateInput) !Id {
            const a = self.begin();
            if (input.workflow) |w| try self.snap.settings.checkWorkflow(w);
            const created = try self.repo().create(a, .{
                .title = input.title,
                .body = input.body,
                .labels = input.labels,
                .assignee = input.assignee,
                .priority = input.priority,
                .workflow = input.workflow,
                .parent = input.parent,
            });
            const id: Id = .of(created.id.slice());
            self.reloadAfterWrite();
            return id;
        }

        /// `spec.expect` null: what the snapshot shows.
        pub fn edit(self: *Self, id: []const u8, spec_in: issuez.engine.EditSpec) !void {
            const a = self.begin();
            var spec = spec_in;
            spec.expect = self.expect(id, spec.expect);
            if (spec.workflow) |w| if (w.len > 0) try self.snap.settings.checkWorkflow(w);
            _ = try self.repo().edit(a, try refName(a, id), spec);
            self.reloadAfterWrite();
        }

        /// Links an open catalog milestone of that name, else writes the
        /// text, like `git issue edit --milestone`. Empty clears it.
        pub fn setMilestone(self: *Self, id: []const u8, name: []const u8, expected: ?Oid) !void {
            const a = self.begin();
            const i = self.snap.find(id) orelse return error.IssueDisappeared;
            const chosen = try Catalog.of(self.repo()).choose(a, .{
                .name = name,
                .current = self.snap.issues[i],
            });
            const c = switch (chosen) {
                .ok => |c| c,
                .refused => return error.InvalidMilestone,
            };
            _ = try self.repo().edit(a, try refName(a, id), .{
                .milestone = c.text,
                .milestone_id = c.id,
                .milestone_mode = c.mode,
                .expect = self.expect(id, expected),
            });
            self.reloadAfterWrite();
        }

        /// `expected` null: what the snapshot shows.
        pub fn setState(self: *Self, id: []const u8, state: core.State, expected: ?Oid) !void {
            const a = self.begin();
            _ = try self.repo().setState(a, try refName(a, id), .{
                .state = state,
                .expect = self.expect(id, expected),
            });
            self.reloadAfterWrite();
        }

        pub fn comment(self: *Self, id: []const u8, text: []const u8) !void {
            const a = self.begin();
            _ = try self.repo().comment(a, try refName(a, id), .{
                .text = text,
                .expect = self.expect(id, null),
            });
            self.reloadAfterWrite();
        }

        /// What went wrong, for the status line, in `buf`.
        pub fn describe(self: *Self, err: anyerror, buf: []u8) []const u8 {
            var w: std.Io.Writer = .fixed(buf);
            switch (err) {
                error.InvalidDoneStates => w.print(
                    "git config issue.doneStates is invalid: " ++ issuez.settings.done_states_rule,
                    .{},
                ) catch {},
                error.InvalidMilestone => w.writeAll(
                    "no single open milestone has that name (see `git issue milestone ls`)",
                ) catch {},
                error.UnknownWorkflowState => w.print("not one of the workflow states ({s})", .{
                    std.mem.join(self.begin(), ", ", self.snap.settings.workflow_states) catch "",
                }) catch {},
                error.VersionMismatch => w.writeAll(
                    "the issue changed meanwhile; reloaded, try again",
                ) catch {},
                else => {
                    w.print("{f}", .{issuez.errors.Description{ .err = err, .limits = .{} }}) catch {};
                    if (issuez.errors.gitDetail(self.backend, err)) |d| w.print(": {s}", .{d}) catch {};
                },
            }
            return w.buffered();
        }
    };
}

const testing = std.testing;
const GitSim = issuez.backend.GitSim;

test "create, edit, comment and close through the store" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var world: GitSim.World = .{ .clones = &.{.{ .name = "local" }} };
    var sim = try GitSim.init(arena_state.allocator(), &world, 0);

    var store: Store(GitSim) = .init(testing.allocator, &sim);
    defer store.deinit();
    try store.reload();
    try testing.expectEqual(@as(usize, 0), store.snap.issues.len);

    const parent = try store.create(.{ .title = "Parent", .priority = .high });
    const child = try store.create(.{ .title = "Child", .parent = parent.slice(), .workflow = "ready" });
    try testing.expectEqual(@as(usize, 2), store.snap.issues.len);
    const pi = store.snap.find(parent.slice()).?;
    const ci = store.snap.find(child.slice()).?;
    try testing.expectEqual(@as(usize, 1), store.snap.proj.children[pi].len);
    try testing.expectEqual(ci, store.snap.proj.children[pi][0]);

    try store.edit(child.slice(), .{ .title = "Child, renamed", .add_labels = &.{"ui"} });
    try store.comment(child.slice(), "Looks good.");
    try store.setState(child.slice(), .closed, null);
    const c = store.snap.issues[store.snap.find(child.slice()).?];
    try testing.expectEqualStrings("Child, renamed", c.title);
    try testing.expect(store.snap.isDone(store.snap.find(child.slice()).?));

    var buf: [256]u8 = undefined;
    try testing.expectError(error.UnknownWorkflowState, store.create(.{ .title = "x", .workflow = "nope" }));
    try testing.expect(std.mem.startsWith(u8, store.describe(error.UnknownWorkflowState, &buf), "not one of"));
}

test "reloadIfChanged: only when the refs moved" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .clones = &.{.{ .name = "local" }} };
    var sim = try GitSim.init(arena, &world, 0);

    var store: Store(GitSim) = .init(testing.allocator, &sim);
    defer store.deinit();
    try store.reload();
    try testing.expectEqual(@as(?Store(GitSim).Outside, null), try store.reloadIfChanged(false));

    // Our own writes reload already.
    const mine = try store.create(.{ .title = "Mine" });
    try testing.expectEqual(@as(?Store(GitSim).Outside, null), try store.reloadIfChanged(false));

    // Another process's.
    const theirs = try issuez.Repo(GitSim).init(&sim).create(arena, .{ .title = "Theirs" });
    const generation = store.generation;
    const out = (try store.reloadIfChanged(false)).?;
    try testing.expectEqual(@as(u32, 1), out.issues);
    try testing.expect(out.first.eql(theirs.id.slice()));
    try testing.expect(store.generation != generation);
    try testing.expectEqual(@as(usize, 2), store.snap.issues.len);
    try testing.expect(store.snap.find(mine.slice()) != null);

    // Settings reload whatever the refs say.
    try testing.expectEqual(@as(u32, 0), (try store.reloadIfChanged(true)).?.issues);
}

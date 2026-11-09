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
    /// Against the remote syncs go to, from local refs.
    remote: RemoteState = .{},

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
    /// A catalog milestone's position in `milestones`.
    pub fn findMilestone(s: *const Snapshot, id: []const u8) ?u32 {
        for (s.milestones, 0..) |m, n| if (std.mem.eql(u8, m.id, id)) return @intCast(n);
        return null;
    }

    pub fn milestoneName(s: *const Snapshot, i: u32) ?[]const u8 {
        if (s.proj.milestone[i]) |mid| {
            for (s.milestones) |m| if (std.mem.eql(u8, m.id, mid)) return m.name;
        }
        return s.issues[i].field("Milestone");
    }
};

pub const RemoteState = struct {
    remotes: []const []const u8 = &.{},
    /// The one syncs go to; null without remotes.
    name: ?[]const u8 = null,
    /// Not pushed yet, by ID: true when never pushed.
    unpushed: std.StringHashMapUnmanaged(bool) = .empty,
    quarantined: std.StringHashMapUnmanaged(void) = .empty,
    /// Why the remote, or what isn't pushed or is quarantined, couldn't
    /// be read; empty when all was.
    problem: []const u8 = "",

    pub fn isUnpushed(r: *const RemoteState, id: []const u8) bool {
        return r.unpushed.contains(id);
    }

    pub fn isQuarantined(r: *const RemoteState, id: []const u8) bool {
        return r.quarantined.contains(id);
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
    /// A catalog milestone's full ID.
    milestone_id: ?[]const u8 = null,
};

/// One issue's part of `editBatch`: a full ID.
pub const BatchItem = struct { id: []const u8, spec: issuez.engine.EditSpec };

/// A milestone's due date in `applyPlan`; empty clears it.
pub const DueItem = struct {
    id: []const u8,
    due: issuez.engine.EditSpec.DateEdit,
    expect: ?Oid = null,
};

/// Where an issue's milestone comes from.
pub const MilestoneLink = union(enum) {
    /// A catalog milestone, by full ID.
    id: []const u8,
    /// None, and sub-issues that inherit get none either.
    none,
    /// The parent's.
    inherit,
};

/// What a milestone edit changes; null leaves a part alone. `due` empty
/// clears it.
pub const MilestoneEdit = struct {
    name: ?[]const u8 = null,
    due: ?issuez.engine.EditSpec.DateEdit = null,
    description: ?[]const u8 = null,
    status: ?issuez.format.fields.MilestoneStatus = null,
    /// Null: the tip the snapshot shows.
    expect: ?Oid = null,
};

/// A new milestone. Strings are copied by the write.
pub const MilestoneInput = struct {
    name: []const u8,
    due: ?issuez.format.fields.Date = null,
    description: []const u8 = "",
};

pub fn Store(comptime B: type) type {
    const Repo = issuez.Repo(B);
    const Catalog = issuez.Catalog(B);

    return struct {
        const Self = @This();

        gpa: Allocator,
        backend: *B,
        /// Issues, milestones and settings, and their refresh.
        live: issuez.Store(B),
        /// The remote state, which `snap` adds to `live`'s snapshot.
        snap_arena: std.heap.ArenaAllocator,
        snap: Snapshot,
        /// For one write, reset after it.
        scratch: std.heap.ArenaAllocator,
        /// Bumped by every reload that worked, so views can tell.
        generation: u32 = 0,
        /// Sync records change the badge even when no issue tip moves.
        sync_refs: issuez.changes.RefState = .{},
        /// Why the reload after a write that worked failed, until taken.
        reload_error: ?anyerror = null,
        /// The remote picked for this session, over `sync.chooseRemote`.
        remote_buf: [256]u8 = undefined,
        remote_len: u16 = 0,

        pub fn init(gpa: Allocator, backend: *B) Self {
            return .{
                .gpa = gpa,
                .backend = backend,
                .live = .init(gpa, backend),
                .snap_arena = .init(gpa),
                .snap = .{ .proj = .empty },
                .scratch = .init(gpa),
            };
        }

        pub fn deinit(self: *Self) void {
            self.live.deinit();
            self.snap_arena.deinit();
            self.scratch.deinit();
            self.* = undefined;
        }

        fn repo(self: *Self) Repo {
            return self.live.repo();
        }

        /// Brings the snapshot up to date: loads the issues that moved and
        /// reads the remote state again. On failure the old snapshot stays.
        pub fn reload(self: *Self) !void {
            var next: std.heap.ArenaAllocator = .init(self.gpa);
            errdefer next.deinit();
            const a = next.allocator();
            const sync_refs = try self.readSyncRefs(a);
            _ = try self.live.refresh();
            self.adopt(next, sync_refs);
        }

        fn readSyncRefs(self: *Self, a: Allocator) !issuez.changes.RefState {
            return .{ .refs = try self.backend.listRefs(a, "refs/issuez-sync/") };
        }

        /// `live`'s snapshot with the remote state read into `next`.
        fn adopt(
            self: *Self,
            next: std.heap.ArenaAllocator,
            sync_refs: issuez.changes.RefState,
        ) void {
            var arena = next;
            const remote = self.readRemote(arena.allocator());
            self.snap_arena.deinit();
            self.snap_arena = arena;
            const l = &self.live.snap;
            self.snap = .{
                .issues = l.issues,
                .proj = l.proj,
                .settings = l.settings,
                .milestones = l.milestones,
                .remote = remote,
            };
            self.sync_refs = sync_refs;
            self.generation +%= 1;
        }

        /// What is unpushed and quarantined, for the remote syncs go to.
        /// A failure here doesn't fail the reload: it's a hint, not the
        /// data. What was read stays, and the problem says what wasn't.
        fn readRemote(self: *Self, a: Allocator) RemoteState {
            var out: RemoteState = .{};
            out.remotes = self.backend.remoteNames(
                a,
            ) catch |e| return self.remoteProblem(a, out, "can't list the remotes", e);
            if (out.remotes.len == 0) return out;
            const chosen = self.remote_buf[0..self.remote_len];
            out.name = for (out.remotes) |n| {
                if (chosen.len > 0 and std.mem.eql(u8, n, chosen)) break n;
            } else blk: {
                const configured = self.backend.configGet(a, issuez.sync.remote_key) catch |e|
                    return self.remoteProblem(a, out, "git config issue.remote", e);
                break :blk issuez.sync.chooseRemote(out.remotes, configured) catch |e|
                    return self.remoteProblem(a, out, "git config issue.remote", e);
            };
            const name = out.name orelse return out;
            self.readCounts(a, name, &out) catch |e| {
                out.unpushed = .empty;
                out.quarantined = .empty;
                return self.remoteProblem(a, out, "can't tell what isn't pushed", e);
            };
            return out;
        }

        fn readCounts(self: *Self, a: Allocator, name: []const u8, out: *RemoteState) !void {
            const s = issuez.Sync(B).init(self.backend);
            for (try s.unpushed(a, name)) |u| try out.unpushed.put(a, u.id, u.new);
            for (issuez.sync.namespaces) |ns| {
                const prefix = try issuez.sync.recordRef(a, name, .quarantined, ns, "");
                for (try self.backend.listRefs(a, prefix)) |m| try out.quarantined.put(
                    a,
                    m.name[prefix.len..],
                    {},
                );
            }
        }

        fn remoteProblem(
            self: *Self,
            a: Allocator,
            out: RemoteState,
            what: []const u8,
            err: anyerror,
        ) RemoteState {
            var with = out;
            var buf: [400]u8 = undefined;
            with.problem = std.fmt.allocPrint(
                a,
                "{s}: {s}",
                .{ what, self.describe(err, &buf) },
            ) catch what;
            return with;
        }

        /// The remote's URL, for showing; empty when unknown.
        pub fn remoteUrl(self: *Self, a: Allocator, name: []const u8) []const u8 {
            const key = std.fmt.allocPrint(a, "remote.{s}.url", .{name}) catch return "";
            return (self.backend.configGet(a, key) catch return "") orelse "";
        }

        /// Syncs go to `name` from now on, this session.
        pub fn chooseRemote(self: *Self, name: []const u8) !void {
            self.remote_len = @intCast(@min(name.len, self.remote_buf.len));
            @memcpy(self.remote_buf[0..self.remote_len], name[0..self.remote_len]);
            try self.reload();
        }

        /// What a sync panel shows, read now from local refs.
        pub fn syncStatus(self: *Self, a: Allocator) !?issuez.sync.Status {
            const name = self.snap.remote.name orelse return null;
            return try issuez.Sync(B).init(self.backend).status(a, name);
        }

        /// A quarantined remote version: taken, or our own kept.
        pub fn resolve(self: *Self, id: []const u8, how: issuez.sync.Resolution) !void {
            const name = self.snap.remote.name orelse return error.UnknownRemote;
            _ = try issuez.Sync(B).init(self.backend).resolve(self.begin(), name, id, how);
            self.reloadAfterWrite();
        }

        /// What `reloadIfChanged` found.
        pub const Outside = struct {
            /// Issues created, changed or deleted.
            issues: u32 = 0,
            /// One of them.
            first: Id = .{},
            milestones: bool = false,
        };

        /// Reads issue and sync refs, and everything again if they moved
        /// since the last reload or git config may have changed.
        /// Null when it didn't reload.
        pub fn reloadIfChanged(self: *Self, settings: bool) !?Outside {
            var next: std.heap.ArenaAllocator = .init(self.gpa);
            errdefer next.deinit();
            const a = next.allocator();
            const sync_refs = try self.readSyncRefs(a);
            const changed = if (settings)
                try self.live.reproject()
            else
                try self.live.refresh();
            const d = changed orelse {
                if (self.sync_refs.eql(sync_refs)) {
                    next.deinit();
                    return null;
                }
                self.adopt(next, sync_refs);
                return .{};
            };
            var out: Outside = .{ .issues = @intCast(d.issues.len), .milestones = d.milestones };
            if (d.issues.len > 0) out.first = .of(d.issues[0]);
            self.adopt(next, sync_refs);
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
            var people: []const issuez.format.fields.Assignee = &.{};
            if (input.assignee) |v| {
                const one = try a.alloc(issuez.format.fields.Assignee, 1);
                one[0] = issuez.format.fields.Assignee.parse(v) orelse return error.InvalidValue;
                people = one;
            }
            const created = try self.repo().create(a, .{
                .title = input.title,
                .body = input.body,
                .labels = input.labels,
                .assignees = people,
                .priority = input.priority,
                .workflow = input.workflow,
                .parent = input.parent,
                .milestone = if (input.milestone_id) |m| .linked(m) else null,
            }, .{});
            const id: Id = .of(created.id);
            self.reloadAfterWrite();
            return id;
        }

        /// Every write to an existing issue goes through here, then
        /// reloads. `u.edit.expect` null: what the snapshot shows.
        pub fn update(self: *Self, id: []const u8, u: issuez.Update) !issuez.Receipt {
            return self.write(self.begin(), id, u);
        }

        /// `update` in a scratch arena already begun.
        fn write(self: *Self, a: Allocator, id: []const u8, u_in: issuez.Update) !issuez.Receipt {
            var u = u_in;
            u.edit.expect = self.expect(id, u.edit.expect);
            const settings = self.snap.settings;
            if (u.edit.workflow) |w| if (w == .set) try settings.checkWorkflow(w.set);
            const receipt = try self.repo().update(a, id, u, .{});
            if (receipt.wrote) self.reloadAfterWrite();
            return receipt;
        }

        /// `spec.expect` null: what the snapshot shows.
        pub fn edit(self: *Self, id: []const u8, spec: issuez.engine.EditSpec) !void {
            _ = try self.update(id, .{ .edit = spec });
        }

        /// Links an open catalog milestone of that name, else writes the
        /// text, like `git issue edit --milestone`. Empty clears it.
        pub fn setMilestone(self: *Self, id: []const u8, name: []const u8, expected: ?Oid) !void {
            const a = self.begin();
            const i = self.snap.find(id) orelse return error.IssueDisappeared;
            const chosen = try Catalog.fromRepo(self.repo()).choose(a, .{
                .name = name,
                .current = self.snap.issues[i],
            });
            const c = switch (chosen) {
                .ok => |c| c,
                .refused => return error.InvalidMilestone,
            };
            _ = try self.write(a, id, .{ .edit = .{ .milestone = c.edit(), .expect = expected } });
        }

        /// Links the issue as `link` says, like `git issue edit
        /// --milestone-id`, `--no-milestone` and `--milestone-mode inherit`.
        pub fn setMilestoneLink(
            self: *Self,
            id: []const u8,
            link: MilestoneLink,
            expected: ?Oid,
        ) !void {
            const m: issuez.MilestoneEdit = switch (link) {
                .id => |mid| .linked(mid),
                .none => .{ .link = .none },
                .inherit => .{ .link = .inherit },
            };
            _ = try self.update(id, .{ .edit = .{ .milestone = m, .expect = expected } });
        }

        /// Every edit or none. `spec.expect` null: what the snapshot shows.
        pub fn editBatch(self: *Self, items: []const BatchItem) !void {
            const a = self.begin();
            const edits = try a.alloc(Repo.BatchEdit, items.len);
            for (items, edits) |it, *e| {
                var spec = it.spec;
                spec.expect = self.expect(it.id, spec.expect);
                if (spec.workflow) |w| if (w == .set) try self.snap.settings.checkWorkflow(w.set);
                e.* = .{ .ref_name = try refName(a, it.id), .spec = spec };
            }
            _ = try self.repo().editBatch(a, edits, .{});
            self.reloadAfterWrite();
        }

        /// Issue edits and milestones' due dates, all or none.
        pub fn applyPlan(self: *Self, items: []const BatchItem, dues: []const DueItem) !void {
            const a = self.begin();
            const edits = try a.alloc(Repo.BatchEdit, items.len);
            for (items, edits) |it, *e| {
                var spec = it.spec;
                spec.expect = self.expect(it.id, spec.expect);
                e.* = .{ .ref_name = try refName(a, it.id), .spec = spec };
            }
            const due_edits = try a.alloc(Catalog.DueEdit, dues.len);
            for (dues, due_edits) |d, *e| e.* = .{ .id = d.id, .due = d.due, .expect = d.expect };
            _ = try Catalog.fromRepo(self.repo()).editBatch(a, edits, due_edits, .{});
            self.reloadAfterWrite();
        }

        /// Returns the new milestone's ID.
        pub fn createMilestone(self: *Self, input: MilestoneInput) !Id {
            const a = self.begin();
            const created = try Catalog.fromRepo(self.repo()).create(a, .{
                .name = input.name,
                .due = input.due,
                .description = input.description,
            }, .{});
            const id: Id = .of(created.id);
            self.reloadAfterWrite();
            return id;
        }

        pub fn editMilestone(self: *Self, id: []const u8, e: MilestoneEdit) !void {
            const a = self.begin();
            var expected = e.expect;
            if (expected == null) {
                if (self.snap.findMilestone(id)) |n| expected = self.snap.milestones[n].tip;
            }
            _ = try Catalog.fromRepo(self.repo()).edit(a, id, .{
                .name = e.name,
                .due = e.due,
                .description = e.description,
                .status = e.status,
                .expect = expected,
            }, .{});
            self.reloadAfterWrite();
        }

        /// `expected` null: what the snapshot shows.
        pub fn setState(self: *Self, id: []const u8, state: core.State, expected: ?Oid) !void {
            _ = try self.update(id, .{ .edit = .{ .state = state, .expect = expected } });
        }

        pub fn comment(self: *Self, id: []const u8, text: []const u8) !void {
            _ = try self.update(id, .{ .edit = .{ .comment = text } });
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
                    "it changed meanwhile; reloaded, try again",
                ) catch {},
                else => {
                    w.print(
                        "{f}",
                        .{issuez.errors.Description{ .err = err, .limits = .{} }},
                    ) catch {};
                    if (issuez.errors.gitDetail(self.backend, err)) |d| w.print(
                        ": {s}",
                        .{d},
                    ) catch {};
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
    const child = try store.create(
        .{ .title = "Child", .parent = parent.slice(), .workflow = "ready" },
    );
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
    try testing.expectError(
        error.UnknownWorkflowState,
        store.create(.{ .title = "x", .workflow = "nope" }),
    );
    try testing.expect(
        std.mem.startsWith(u8, store.describe(error.UnknownWorkflowState, &buf), "not one of"),
    );
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
    const theirs = try issuez.Repo(GitSim).init(&sim).create(arena, .{ .title = "Theirs" }, .{});
    const generation = store.generation;
    const out = (try store.reloadIfChanged(false)).?;
    try testing.expectEqual(@as(u32, 1), out.issues);
    try testing.expect(out.first.eql(theirs.id));
    try testing.expect(store.generation != generation);
    try testing.expectEqual(@as(usize, 2), store.snap.issues.len);
    try testing.expect(store.snap.find(mine.slice()) != null);

    // Settings reload whatever the refs say.
    try testing.expectEqual(@as(u32, 0), (try store.reloadIfChanged(true)).?.issues);
}

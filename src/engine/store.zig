//! A live view of a repository's issues for a long-running front end (a
//! TUI, a GUI, a server): every issue and milestone with the projection
//! over them, kept up to date by `refresh`, which loads only the issues
//! whose refs moved. Others may write under it; a file watcher, a timer or
//! the focus coming back is the cue to refresh.
//!
//! A snapshot is replaced whole by each refresh that finds a change.
//! Nothing outside may keep pointers into it across a refresh: keep issue
//! IDs, and look them up again (`Snapshot.find`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const repo_mod = @import("repo.zig");
const changes = @import("changes.zig");
const settings_mod = @import("settings.zig");
const projection_mod = @import("projection.zig");
const milestone_mod = @import("milestone.zig");
const issue_model = @import("../model/issue.zig");

const Issue = issue_model.Issue;
const Projection = projection_mod.Projection;
const Milestone = milestone_mod.Milestone;
const Oid = @import("../backend/object.zig").Oid;

pub const Snapshot = struct {
    /// Deleted ones too; views leave those out.
    issues: []const Issue = &.{},
    proj: Projection,
    settings: settings_mod.Settings = .{},
    /// By due date, then name.
    milestones: []const Milestone = &.{},

    pub fn find(s: *const Snapshot, id: []const u8) ?u32 {
        return s.proj.find(id);
    }

    pub fn isDone(s: *const Snapshot, i: u32) bool {
        return s.proj.isDone(i);
    }

    pub const Resolved = union(enum) { none, many, one: u32 };

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

    /// The name of issue `i`'s effective milestone.
    pub fn milestoneName(s: *const Snapshot, i: u32) ?[]const u8 {
        if (s.proj.milestone[i]) |mid| {
            for (s.milestones) |m| if (std.mem.eql(u8, m.id, mid)) return m.name;
        }
        return s.issues[i].milestone;
    }
};

/// What a refresh found changed since the snapshot before it.
pub const Changed = struct {
    /// Issues created, changed or deleted, by UUID.
    issues: []const []const u8 = &.{},
    milestones: bool = false,
    settings: bool = false,
};

pub fn Store(comptime B: type) type {
    const Repo = repo_mod.Repo(B);
    const Catalog = milestone_mod.Catalog(B);

    return struct {
        const Self = @This();

        /// An issue loaded at a tip, in an arena of its own so a refresh
        /// keeps the ones that didn't move.
        const Loaded = struct {
            tip: Oid,
            arena: std.heap.ArenaAllocator,
            issue: Issue,
        };

        gpa: Allocator,
        backend: *B,
        snap_arena: std.heap.ArenaAllocator,
        snap: Snapshot,
        /// By UUID; the keys live in the entries' arenas.
        loaded: std.StringHashMapUnmanaged(*Loaded) = .empty,
        /// The refs as the snapshot read them, in `snap_arena`.
        refs: changes.RefState = .{},
        /// Bumped by every refresh that changed the snapshot.
        generation: u32 = 0,
        /// Issue loads the last refresh did, for tests and logs.
        last_loads: usize = 0,

        pub fn init(gpa: Allocator, backend: *B) Self {
            return .{
                .gpa = gpa,
                .backend = backend,
                .snap_arena = .init(gpa),
                .snap = .{ .proj = .empty },
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.loaded.valueIterator();
            while (it.next()) |l| self.free(l.*);
            self.loaded.deinit(self.gpa);
            self.snap_arena.deinit();
            self.* = undefined;
        }

        fn free(self: *Self, l: *Loaded) void {
            l.arena.deinit();
            self.gpa.destroy(l);
        }

        /// A repo for writes, with the snapshot's settings.
        pub fn repo(self: *const Self) Repo {
            var r = Repo.init(self.backend);
            r.settings = self.snap.settings;
            return r;
        }

        /// What `refresh` and `reproject` fail with: reading the repository
        /// (its settings, issues and milestones).
        pub const Error = Repo.OpenError || Repo.LoadError || Catalog.Error;

        /// Reads the refs and settings, and when anything moved the issues
        /// that did, then projects again. Null when nothing changed and
        /// the snapshot stays; on failure the old snapshot stays too.
        pub fn refresh(self: *Self) Error!?Changed {
            return self.refreshIf(false);
        }

        /// `refresh` that projects again even when nothing moved: for
        /// when something outside the refs may have changed what shows.
        pub fn reproject(self: *Self) Error!Changed {
            return (try self.refreshIf(true)).?;
        }

        fn refreshIf(self: *Self, force: bool) Error!?Changed {
            if (@hasDecl(B, "refresh")) self.backend.refresh();
            var next: std.heap.ArenaAllocator = .init(self.gpa);
            errdefer next.deinit();
            const a = next.allocator();
            // Before the issues: a write in between then shows as a change
            // next time, never the other way round.
            const refs = try changes.RefState.read(B, a, self.backend);
            const r = try Repo.open(a, self.backend);
            const settings_changed = self.generation == 0 or
                !self.snap.settings.eql(r.settings);
            const d = try changes.diff(a, self.refs, refs);
            if (!force and self.generation > 0 and d.isEmpty() and !settings_changed) {
                next.deinit();
                return null;
            }

            // The diff's IDs may point into the old snapshot's arena.
            const changed_ids = try a.alloc([]const u8, d.issues.len);
            for (d.issues, changed_ids) |id, *o| o.* = try a.dupe(u8, id);
            self.last_loads = 0;
            const current = try r.refs(a);
            var keep: std.StringHashMapUnmanaged(void) = .empty;
            var issues: std.ArrayList(Issue) = .empty;
            for (current) |ref| {
                const id = ref.id();
                try keep.put(a, id, {});
                if (self.loaded.get(id)) |l| if (l.tip.eql(ref.tip)) {
                    try issues.append(a, l.issue);
                    continue;
                };
                const l = try self.loadOne(r, ref) orelse continue;
                try issues.append(a, l.issue);
            }
            // Issues gone from the refs.
            var gone: std.ArrayList([]const u8) = .empty;
            var it = self.loaded.iterator();
            while (it.next()) |e| if (!keep.contains(e.key_ptr.*)) try gone.append(a, e.key_ptr.*);
            for (gone.items) |id| if (self.loaded.fetchRemove(id)) |kv| self.free(kv.value);

            const cat = Catalog.fromRepo(r);
            const milestones = try cat.list(a);
            const proj = try cat.project(a, issues.items, .{ .milestones = milestones });
            self.snap_arena.deinit();
            self.snap_arena = next;
            self.snap = .{
                .issues = issues.items,
                .proj = proj,
                .settings = r.settings,
                .milestones = milestones,
            };
            self.refs = refs;
            self.generation +%= 1;
            return .{
                .issues = changed_ids,
                .milestones = d.milestones,
                .settings = settings_changed,
            };
        }

        /// Loads `ref` into an entry of its own, replacing the old one;
        /// null for an issue that can't be loaded (`git issue fsck` says
        /// why), which is left out.
        fn loadOne(self: *Self, r: Repo, ref: repo_mod.IssueRef) Repo.LoadError!?*Loaded {
            const l = try self.gpa.create(Loaded);
            errdefer self.gpa.destroy(l);
            l.* = .{ .tip = ref.tip, .arena = .init(self.gpa), .issue = undefined };
            errdefer l.arena.deinit();
            const la = l.arena.allocator();
            const owned: repo_mod.IssueRef = .{ .name = try la.dupe(u8, ref.name), .tip = ref.tip };
            self.last_loads += 1;
            l.issue = r.load(la, owned) catch |err| switch (err) {
                error.CorruptIssue, error.HistoryTooLong, error.MissingParent, error.NoRoot => {
                    l.arena.deinit();
                    self.gpa.destroy(l);
                    if (self.loaded.fetchRemove(ref.id())) |kv| self.free(kv.value);
                    return null;
                },
                else => |e| return e,
            };
            const e = try self.loaded.getOrPut(self.gpa, l.issue.id);
            if (e.found_existing) self.free(e.value_ptr.*);
            e.key_ptr.* = l.issue.id;
            e.value_ptr.* = l;
            return l;
        }
    };
}

const testing = std.testing;

test "Store: refresh loads what moved, and nothing when nothing did" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const GitSim = @import("../backend/GitSim.zig");
    var world: GitSim.World = .{ .seed = 101, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const writer = repo_mod.Repo(GitSim).init(&sim);
    const one = try writer.create(arena, .{ .title = "One" }, .{});
    _ = try writer.create(arena, .{ .title = "Two" }, .{});

    var store = Store(GitSim).init(testing.allocator, &sim);
    defer store.deinit();
    const first = (try store.refresh()).?;
    try testing.expect(first.settings);
    try testing.expectEqual(@as(usize, 2), store.snap.issues.len);
    try testing.expectEqual(@as(usize, 2), store.last_loads);
    try testing.expect(try store.refresh() == null);
    try testing.expectEqual(@as(usize, 0), (try store.reproject()).issues.len);
    try testing.expectEqual(@as(usize, 0), store.last_loads);

    _ = try writer.edit(arena, one.id, .{ .title = "One, renamed" }, .{});
    const changed = (try store.refresh()).?;
    try testing.expectEqual(@as(usize, 1), changed.issues.len);
    try testing.expectEqualStrings(one.id, changed.issues[0]);
    try testing.expectEqual(@as(usize, 1), store.last_loads);
    const i = store.snap.find(one.id).?;
    try testing.expectEqualStrings("One, renamed", store.snap.issues[i].title);
    try testing.expect(store.snap.resolve(one.id[0..8]) == .one);
    try testing.expectEqual(@as(u32, 3), store.generation);
}

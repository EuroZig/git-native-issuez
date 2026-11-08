//! One entry to the library: a repository opened with its settings, and
//! every part of the library over it. Each part's own type (`Repo`,
//! `Catalog`, `Sync`, ...) still works alone.
//!
//!     const h = try issuez.open(GitProcess, arena, &backend);
//!     const issue = try h.repo.find(arena, id);
//!     _ = try h.repo.update(arena, id, .{ .edit = .{ .comment = "Seen." } }, .{});
//!     const report = try h.sync().sync(arena, "origin");

const std = @import("std");
const Allocator = std.mem.Allocator;
const repo_mod = @import("repo.zig");

pub fn Handle(comptime B: type) type {
    return struct {
        const Self = @This();

        /// Issues: loading, writing, guards. Its settings are git config's.
        repo: repo_mod.Repo(B),

        pub fn open(arena: Allocator, backend: *B) repo_mod.Repo(B).OpenError!Self {
            return .{ .repo = try .open(arena, backend) };
        }

        pub fn milestones(self: Self) @import("milestone.zig").Catalog(B) {
            return .fromRepo(self.repo);
        }

        pub fn sync(self: Self) @import("sync.zig").Sync(B) {
            return .fromRepo(self.repo);
        }

        pub fn attachments(self: Self) @import("attachments.zig").Attachments(B) {
            return .fromRepo(self.repo);
        }

        pub fn purge(self: Self) @import("purge.zig").Purge(B) {
            return .fromRepo(self.repo);
        }

        pub fn pushCheck(self: Self) @import("push_check.zig").PushCheck(B) {
            return .fromRepo(self.repo);
        }

        pub fn fsck(
            self: Self,
            arena: Allocator,
            options: @import("fsck.zig").Options,
        ) (repo_mod.Repo(B).Error || error{InvalidLimits})!@import("fsck.zig").Fsck(B).Report {
            return @import("fsck.zig").Fsck(B).run(arena, self.repo, options);
        }

        /// A live view over the same backend; deinit it when done.
        pub fn store(self: Self, gpa: Allocator) @import("store.zig").Store(B) {
            return .init(gpa, self.repo.backend);
        }

        pub fn configureRemote(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            options: @import("remote.zig").Options,
        ) (B.Error || error{ NoSuchRemote, InvalidRemoteName })!@import("remote.zig").Setup {
            return @import("remote.zig").configure(B, arena, self.repo.backend, remote, options);
        }
    };
}

/// `Handle(B).open`.
pub fn open(comptime B: type, arena: Allocator, backend: *B) repo_mod.Repo(B).OpenError!Handle(B) {
    return Handle(B).open(arena, backend);
}

const testing = std.testing;

test "open: every part over one repo" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const GitSim = @import("../backend/GitSim.zig");
    var world: GitSim.World = .{ .seed = 109, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const h = try open(GitSim, arena, &sim);
    const made = try h.repo.create(arena, .{ .title = "Through the handle" }, .{});
    _ = try h.milestones().create(arena, .{ .name = "v1" }, .{});
    try testing.expectEqual(@as(usize, 1), (try h.milestones().list(arena)).len);
    try testing.expectEqual(@as(usize, 0), (try h.fsck(arena, .{})).errors());
    var s = h.store(testing.allocator);
    defer s.deinit();
    _ = try s.refresh();
    try testing.expect(s.snap.find(made.id) != null);
    _ = h.sync();
    _ = h.attachments();
    _ = h.purge();
    _ = h.pushCheck();
}

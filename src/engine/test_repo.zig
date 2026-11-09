//! What most engine tests start from: a repository on one simulated clone,
//! freed with its arena. Only tests import it; `root.zig` doesn't export it.
//!
//! ```
//! var fx: TestRepo = .{};
//! defer fx.deinit();
//! const arena, const sim, const repo = try fx.open(3);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const GitSim = @import("../backend/GitSim.zig");
const repo_mod = @import("repo.zig");
const Repo = repo_mod.Repo(GitSim);

pub const TestRepo = struct {
    arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator),
    world: GitSim.World = undefined,
    sim: GitSim = undefined,
    repo: Repo = undefined,

    pub fn deinit(t: *TestRepo) void {
        t.arena_state.deinit();
    }

    pub fn open(t: *TestRepo, seed: u64) !struct { Allocator, *GitSim, Repo } {
        const arena = t.arena_state.allocator();
        t.world = .{ .seed = seed, .clones = &.{.{ .name = "a" }} };
        t.sim = try GitSim.init(arena, &t.world, 0);
        t.repo = .init(&t.sim);
        return .{ arena, &t.sim, t.repo };
    }

    /// A new issue and its ref name.
    pub fn issue(t: *TestRepo, spec: repo_mod.CreateSpec) !struct { repo_mod.Created, []const u8 } {
        const arena = t.arena_state.allocator();
        const created = try t.repo.create(arena, spec, .{});
        return .{ created, try repo_mod.refFor(arena, repo_mod.issue_ref_prefix, created.id) };
    }
};

//! Issues a repo handle keeps materialized between calls, keyed by ID and
//! tip, so a query only loads the issues that changed since the last one.
//! Shared by every thread using the handle. Each entry owns its memory and
//! is refcounted: a call or a returned list holds the entries it uses, so
//! replacing or dropping one never frees an issue someone still reads.

const std = @import("std");
const issuez = @import("issuez");
const rt = @import("rt.zig");

const Allocator = std.mem.Allocator;
const Issue = issuez.model.issue.Issue;
const Oid = issuez.backend.object.Oid;

pub const Entry = struct {
    refs: std.atomic.Value(u32) = .init(1),
    arena: std.heap.ArenaAllocator,
    tip: Oid,
    issue: Issue,
    /// The query that last used it.
    generation: u64 = 0,

    pub fn retain(e: *Entry) void {
        _ = e.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(e: *Entry) void {
        if (e.refs.fetchSub(1, .acq_rel) != 1) return;
        e.arena.deinit();
        rt.gpa.destroy(e);
    }
};

pub const Cache = struct {
    /// At most this many entries; 0 keeps none.
    max: usize = 10_000,
    mutex: std.Io.Mutex = .init,
    /// Keys live in their entry's arena.
    map: std.StringHashMapUnmanaged(*Entry) = .empty,
    generation: u64 = 0,
    hits: u64 = 0,
    loads: u64 = 0,

    pub fn deinit(c: *Cache) void {
        var it = c.map.valueIterator();
        while (it.next()) |e| e.*.release();
        c.map.deinit(rt.gpa);
    }

    /// Every issue at `refs`, from the cache or loaded with `engine`; the
    /// entries are retained into `held`. Issues that can't be loaded go to
    /// `skipped`.
    pub fn loadAll(
        c: *Cache,
        arena: Allocator,
        engine: anytype,
        refs: []const issuez.engine.IssueRef,
        held: *std.ArrayList(*Entry),
        skipped: *std.ArrayList([]const u8),
        isDamaged: *const fn (anyerror) bool,
    ) ![]Issue {
        const io = rt.io();
        var out: std.ArrayList(Issue) = try .initCapacity(arena, refs.len);
        // Room first: an entry is retained only once it can be held.
        try held.ensureUnusedCapacity(arena, refs.len);
        var misses: std.ArrayList(issuez.engine.IssueRef) = .empty;
        const generation = generation: {
            c.mutex.lockUncancelable(io);
            defer c.mutex.unlock(io);
            c.generation += 1;
            for (refs) |r| {
                const e = c.map.get(r.id()) orelse {
                    try misses.append(arena, r);
                    continue;
                };
                if (!e.tip.eql(r.tip)) {
                    try misses.append(arena, r);
                    continue;
                }
                e.generation = c.generation;
                e.retain();
                held.appendAssumeCapacity(e);
                out.appendAssumeCapacity(e.issue);
            }
            c.hits += refs.len - misses.items.len;
            break :generation c.generation;
        };

        // Loaded without the lock: git is the slow part.
        var fresh: std.ArrayList(*Entry) = .empty;
        defer for (fresh.items) |e| e.release();
        for (misses.items) |r| {
            const e = try rt.gpa.create(Entry);
            e.* = .{ .arena = .init(rt.gpa), .tip = r.tip, .issue = undefined };
            const ea = e.arena.allocator();
            const name = ea.dupe(u8, r.name) catch |err| {
                e.release();
                return err;
            };
            e.issue = engine.load(ea, .{ .name = name, .tip = r.tip }) catch |err| {
                e.release();
                if (!isDamaged(err)) return err;
                try skipped.append(arena, try arena.dupe(u8, r.id()));
                continue;
            };
            e.generation = generation;
            fresh.append(arena, e) catch |err| {
                e.release();
                return err;
            };
            e.retain();
            held.appendAssumeCapacity(e);
            out.appendAssumeCapacity(e.issue);
        }

        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        c.loads += fresh.items.len;
        // Gone from the refs: deleted, purged, or replaced by a newer tip.
        var stale: std.ArrayList([]const u8) = .empty;
        var it = c.map.iterator();
        while (it.next()) |kv| if (kv.value_ptr.*.generation < generation) {
            try stale.append(arena, kv.key_ptr.*);
        };
        for (stale.items) |k| if (c.map.fetchRemove(k)) |kv| kv.value.release();
        for (fresh.items) |e| {
            const key = e.issue.id;
            if (c.map.fetchRemove(key)) |kv| kv.value.release();
            if (c.map.count() >= c.max) continue;
            e.retain();
            c.map.put(rt.gpa, key, e) catch {
                e.release();
                continue;
            };
        }
        return out.items;
    }
};

test "loadAll: running out of memory doesn't leave the cache locked" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    // The result list gets its memory, the list of misses doesn't.
    var failing: std.testing.FailingAllocator = .init(
        arena_state.allocator(),
        .{ .fail_index = 1 },
    );
    const arena = failing.allocator();
    const engine = struct {
        fn load(_: @This(), _: Allocator, _: issuez.engine.IssueRef) !Issue {
            unreachable;
        }
    }{};
    const never = struct {
        fn f(_: anyerror) bool {
            return false;
        }
    }.f;
    const refs = [_]issuez.engine.IssueRef{.{
        .name = "refs/issues/x",
        .tip = .{ .object_format = .sha1, .bytes = @splat(1) },
    }};
    var cache: Cache = .{};
    defer cache.deinit();
    var held: std.ArrayList(*Entry) = .empty;
    var skipped: std.ArrayList([]const u8) = .empty;
    try std.testing.expectError(
        error.OutOfMemory,
        cache.loadAll(arena, engine, &refs, &held, &skipped, &never),
    );
    try std.testing.expect(cache.mutex.tryLock());
    cache.mutex.unlock(rt.io());
}

test "loadAll: running out of memory leaves no entry retained by no one" {
    const io = rt.io();
    const Spy = struct {
        /// Retained once more here, so it outlives the call.
        loaded: ?*Entry = null,

        fn load(spy: *@This(), ea: Allocator, ref: issuez.engine.IssueRef) !Issue {
            const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(ea.ptr));
            const e: *Entry = @fieldParentPtr("arena", arena);
            e.retain();
            spy.loaded = e;
            return std.mem.zeroInit(Issue, .{ .id = ref.id(), .state = .open });
        }
    };
    const never = struct {
        fn f(_: anyerror) bool {
            return false;
        }
    }.f;
    const refs = [_]issuez.engine.IssueRef{.{
        .name = "refs/issues/0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d",
        .tip = .{ .object_format = .sha1, .bytes = @splat(1) },
    }};
    for (0..8) |fail_index| {
        var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena_state.deinit();
        var failing: std.testing.FailingAllocator = .init(
            arena_state.allocator(),
            .{ .fail_index = fail_index },
        );
        var cache: Cache = .{};
        var held: std.ArrayList(*Entry) = .empty;
        var skipped: std.ArrayList([]const u8) = .empty;
        var spy: Spy = .{};
        const engine = struct {
            spy: *Spy,
            fn load(self: @This(), ea: Allocator, ref: issuez.engine.IssueRef) !Issue {
                return self.spy.load(ea, ref);
            }
        }{ .spy = &spy };
        _ = cache.loadAll(failing.allocator(), engine, &refs, &held, &skipped, &never) catch {};
        if (spy.loaded) |e| {
            var holders: u32 = 1;
            for (held.items) |h| holders += @intFromBool(h == e);
            cache.mutex.lockUncancelable(io);
            if (cache.map.get(e.issue.id)) |m| holders += @intFromBool(m == e);
            cache.mutex.unlock(io);
            try std.testing.expectEqual(holders, e.refs.load(.monotonic));
            e.release();
        }
        for (held.items) |e| e.release();
        cache.deinit();
    }
}

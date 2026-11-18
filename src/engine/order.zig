//! Placing an issue in an order set by hand (`X-Rank`, format.md §3):
//! which keys a move writes. Most moves write the moved issue's key
//! alone. Issues without a key come after those with one, so a move below
//! some of them gives them keys too; neighbours with the same key (two
//! clones that moved cards to the same place) give that run of keys new
//! ones, and a key that would be too long the whole column.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const rank = @import("../format/rank.zig");

pub const Error = Allocator.Error || error{
    /// A key after an issue without one, or after a greater key: the column
    /// isn't in rank order.
    NotInOrder,
};

/// What your order goes by.
pub const Item = struct {
    rank: ?[]const u8,
    /// Unix seconds.
    created: i64,
    id: []const u8,

    /// From an `Issue`, or anything with these fields.
    pub fn of(issue: anytype) Item {
        return .{ .rank = issue.rank, .created = issue.created, .id = issue.id };
    }
};

/// Your order (format.md §3): issues with a key first, by key, then those
/// without, oldest first, so new ones come last; equal keys by ID.
pub fn compare(a: Item, b: Item) std.math.Order {
    const ord: std.math.Order = if (a.rank != null and b.rank != null)
        rank.order(a.rank.?, b.rank.?)
    else if (a.rank != null or b.rank != null)
        (if (a.rank != null) .lt else .gt)
    else
        std.math.order(a.created, b.created);
    return ord.differ() orelse std.mem.order(u8, a.id, b.id);
}

pub const Placement = struct {
    /// The moved issue's key.
    key: []const u8,
    /// Other issues' new keys, by their index in the column given.
    others: []const Other = &.{},

    pub const Other = struct { index: usize, key: []const u8 };
};

/// Where an issue goes at `at` in a column, `ranks` the keys of the
/// column's other issues in rank order: keys first, by key, then those
/// without, as shown. `at` is 0 for the top, `ranks.len` for the bottom.
pub fn place(arena: Allocator, ranks: []const ?[]const u8, at: usize) Error!Placement {
    assert(at <= ranks.len);
    var ranked: usize = 0;
    while (ranked < ranks.len and ranks[ranked] != null) ranked += 1;
    for (ranks[ranked..]) |r| if (r != null) return error.NotInOrder;
    for (ranks[0..ranked], 0..) |r, n| {
        assert(rank.valid(r.?));
        if (n > 0 and rank.order(ranks[n - 1].?, r.?) == .gt) return error.NotInOrder;
    }
    // No key fits: the whole column anew.
    return fits(arena, ranks, ranked, at) catch |e| switch (e) {
        error.TooLong => anew(arena, ranks.len, at),
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// `place` in a column in order, `ranked` of its issues with keys.
fn fits(
    arena: Allocator,
    ranks: []const ?[]const u8,
    ranked: usize,
    at: usize,
) rank.Error!Placement {
    if (at <= ranked) {
        const lo = if (at > 0) ranks[at - 1].? else null;
        const hi = if (at < ranked) ranks[at].? else null;
        if (lo == null or hi == null or rank.order(lo.?, hi.?) == .lt)
            return .{ .key = try rank.between(arena, lo, hi) };
        // Between equal keys.
        return rekeyRun(arena, ranks[0..ranked], at);
    }
    // Below issues without a key: those above it get keys, after the last
    // key, in the order shown.
    const lo = if (ranked > 0) ranks[ranked - 1].? else null;
    const keys = try rank.spread(arena, lo, null, at - ranked + 1);
    const others = try arena.alloc(Placement.Other, at - ranked);
    for (others, keys[0 .. keys.len - 1], ranked..) |*o, k, n| o.* = .{ .index = n, .key = k };
    return .{ .key = keys[keys.len - 1], .others = others };
}

/// New keys for the run of equal keys around `at`, between the keys on
/// either side of it, so the rest of the column keeps its own.
fn rekeyRun(arena: Allocator, ranked: []const ?[]const u8, at: usize) rank.Error!Placement {
    assert(at > 0 and at < ranked.len);
    const key = ranked[at].?;
    var start = at;
    while (start > 0 and std.mem.eql(u8, ranked[start - 1].?, key)) start -= 1;
    var end = at;
    while (end < ranked.len and std.mem.eql(u8, ranked[end].?, key)) end += 1;
    const lo = if (start > 0) ranked[start - 1] else null;
    const hi = if (end < ranked.len) ranked[end] else null;
    const keys = try rank.spread(arena, lo, hi, end - start + 1);
    const others = try arena.alloc(Placement.Other, end - start);
    for (others, start..) |*o, n| {
        o.* = .{ .index = n, .key = keys[n - start + @intFromBool(n >= at)] };
    }
    return .{ .key = keys[at - start], .others = others };
}

/// Keys anew for the whole column, the moved issue at `at`.
fn anew(arena: Allocator, len: usize, at: usize) Error!Placement {
    const keys = rank.spread(arena, null, null, len + 1) catch |e| switch (e) {
        // Halving from the whole range stays far below the limit.
        error.TooLong => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const others = try arena.alloc(Placement.Other, len);
    for (others, 0..) |*o, n| o.* = .{ .index = n, .key = keys[if (n < at) n else n + 1] };
    return .{ .key = keys[at], .others = others };
}

const testing = std.testing;

test compare {
    const at = struct {
        fn f(r: ?[]const u8, created: i64, id: []const u8) Item {
            return .{ .rank = r, .created = created, .id = id };
        }
    }.f;
    try testing.expectEqual(.lt, compare(at("a", 9, "x"), at("b", 1, "a")));
    try testing.expectEqual(.lt, compare(at("z", 9, "x"), at(null, 1, "a")));
    try testing.expectEqual(.lt, compare(at(null, 1, "x"), at(null, 2, "a")));
    try testing.expectEqual(.lt, compare(at("a", 9, "a"), at("a", 1, "b")));
}

test "between two keys: the moved one alone" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ranks: []const ?[]const u8 = &.{ "a", "c", null };
    const p = try place(a, ranks, 1);
    try testing.expectEqualStrings("b", p.key);
    try testing.expectEqual(0, p.others.len);
    try testing.expectEqualStrings("5", (try place(a, ranks, 0)).key);
    // Right after the last key, above those without.
    try testing.expectEqualStrings("o", (try place(a, ranks, 2)).key);
    try testing.expectEqualStrings("i", (try place(a, &.{}, 0)).key);
}

test "below issues without a key: they get keys, in the order shown" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const p = try place(a, &.{ "a", null, null, null }, 3);
    try testing.expectEqual(2, p.others.len);
    try testing.expectEqual(1, p.others[0].index);
    try testing.expectEqual(2, p.others[1].index);
    try testing.expectEqual(.lt, rank.order("a", p.others[0].key));
    try testing.expectEqual(.lt, rank.order(p.others[0].key, p.others[1].key));
    try testing.expectEqual(.lt, rank.order(p.others[1].key, p.key));
    // None with a key: from the start.
    const q = try place(a, &.{ null, null }, 2);
    try testing.expectEqual(2, q.others.len);
    try testing.expectEqual(.lt, rank.order(q.others[1].key, q.key));
}

test "the same key on both sides: that run anew; too long: the column" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The two b's get keys between a and c; a, c and d keep theirs.
    const p = try place(a, &.{ "a", "b", "b", "c", "d" }, 2);
    try testing.expectEqual(2, p.others.len);
    try testing.expectEqual(1, p.others[0].index);
    try testing.expectEqual(2, p.others[1].index);
    try testing.expectEqual(.lt, rank.order("a", p.others[0].key));
    try testing.expectEqual(.lt, rank.order(p.others[0].key, p.key));
    try testing.expectEqual(.lt, rank.order(p.key, p.others[1].key));
    try testing.expectEqual(.lt, rank.order(p.others[1].key, "c"));
    // A run at the top.
    const top = try place(a, &.{ "b", "b", "b", "c" }, 1);
    try testing.expectEqual(3, top.others.len);
    try testing.expectEqual(.lt, rank.order(top.others[0].key, top.key));
    try testing.expectEqual(.lt, rank.order(top.key, top.others[1].key));
    try testing.expectEqual(.lt, rank.order(top.others[2].key, "c"));
    // No key of at most `max_len` bytes fits between these two.
    var lo: [rank.max_len]u8 = @splat('0');
    var hi: [rank.max_len]u8 = @splat('0');
    lo[rank.max_len - 1] = '1';
    hi[rank.max_len - 1] = '2';
    const q = try place(a, &.{ &lo, &hi }, 1);
    try testing.expectEqual(2, q.others.len);
    try testing.expect(q.key.len < 8);
    try testing.expectError(error.NotInOrder, place(a, &.{ null, "a" }, 0));
    try testing.expectError(error.NotInOrder, place(a, &.{ "d", "b", "b", "a" }, 2));
}

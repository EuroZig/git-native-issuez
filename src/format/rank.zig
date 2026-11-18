//! `X-Rank` (format.md §3): where an issue goes in an order set by hand,
//! as a fractional key. Keys are digits and lowercase letters, base 36 in
//! that order, read as the digits after a point: `i` is half way, `0i` a
//! 36th of that. None ends in `0`, so another always fits between two.
//! Bytewise order is their order.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// A key's bytes at most.
pub const max_len = 128;

/// What `valid` takes, for messages.
pub const rule =
    std.fmt.comptimePrint("0-9 and a-z, at most {d} bytes, not ending in 0", .{max_len});

const base = 36;

pub const Error = Allocator.Error || error{
    /// The key would be longer than `max_len`: what is around it needs
    /// keys anew (`spread`).
    TooLong,
};

pub fn valid(key: []const u8) bool {
    if (key.len == 0 or key.len > max_len or key[key.len - 1] == '0') return false;
    for (key) |c| if (!std.ascii.isDigit(c) and !std.ascii.isLower(c)) return false;
    return true;
}

pub fn order(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

fn digit(c: u8) u8 {
    return if (std.ascii.isDigit(c)) c - '0' else c - 'a' + 10;
}

fn char(d: u8) u8 {
    assert(d < base);
    return if (d < 10) '0' + d else 'a' + d - 10;
}

/// The shortest key after `a` and before `b`: null `a` is the start, null
/// `b` the end. The same pair gives the same key.
pub fn between(arena: Allocator, a: ?[]const u8, b: ?[]const u8) Error![]u8 {
    const lo = a orelse "";
    if (a) |x| assert(valid(x));
    if (b) |y| {
        assert(valid(y));
        assert(order(lo, y) == .lt);
    }
    var out: std.ArrayList(u8) = .empty;
    var hi = b;
    var i: usize = 0;
    // What both start with; `lo` is `0`s past its end.
    if (hi) |y| while (i < y.len and (if (i < lo.len) lo[i] else '0') == y[i]) : (i += 1) {
        try out.append(arena, y[i]);
    };
    while (true) : (i += 1) {
        if (out.items.len >= max_len) return error.TooLong;
        const dl: u8 = if (i < lo.len) digit(lo[i]) else 0;
        const dh: u8 = if (hi) |y| digit(y[i]) else base;
        assert(dh > dl);
        if (dh - dl > 1) {
            try out.append(arena, char((dl + dh) / 2));
            break;
        }
        // Next to each other: `b` cut after this digit, when it goes on,
        // is between; else past `a`'s digit, up to the end.
        if (hi) |y| if (y.len > i + 1) {
            try out.append(arena, y[i]);
            break;
        };
        try out.append(arena, char(dl));
        hi = null;
    }
    assert(valid(out.items));
    return out.items;
}

/// `n` keys after `a` and before `b`, in order, as evenly as halving
/// gives: for keys anew, or for issues placed together.
pub fn spread(arena: Allocator, a: ?[]const u8, b: ?[]const u8, n: usize) Error![]const []const u8 {
    const out = try arena.alloc([]const u8, n);
    try fill(arena, a, b, out);
    return out;
}

fn fill(arena: Allocator, a: ?[]const u8, b: ?[]const u8, out: [][]const u8) Error!void {
    if (out.len == 0) return;
    const mid = out.len / 2;
    out[mid] = try between(arena, a, b);
    try fill(arena, a, out[mid], out[0..mid]);
    try fill(arena, out[mid], b, out[mid + 1 ..]);
}

const testing = std.testing;

test valid {
    try testing.expect(valid("i"));
    try testing.expect(valid("0z9"));
    try testing.expect(!valid(""));
    try testing.expect(!valid("a0"));
    try testing.expect(!valid("A"));
    try testing.expect(!valid("a-b"));
    const long: [max_len + 1]u8 = @splat('i');
    try testing.expect(!valid(&long));
    try testing.expect(valid(long[0..max_len]));
}

test between {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("i", try between(a, null, null));
    try testing.expectEqualStrings("r", try between(a, "i", null));
    try testing.expectEqualStrings("9", try between(a, null, "i"));
    try testing.expectEqualStrings("b", try between(a, "a", "c"));
    // Next to each other: one digit more.
    try testing.expectEqualStrings("ai", try between(a, "a", "b"));
    try testing.expectEqualStrings("1", try between(a, "0z", "10a"));
    try testing.expectEqualStrings("0zi", try between(a, "0z", "1"));
    try testing.expectEqualStrings("0i", try between(a, null, "1"));
    try testing.expectEqualStrings("01", try between(a, null, "02"));
    try testing.expectEqualStrings("zi", try between(a, "z", null));
    try testing.expectEqualStrings("a0i", try between(a, "a", "a1"));
}

test "between: always valid and between, for any pair" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var keys: std.ArrayList([]const u8) = .empty;
    try keys.append(a, try between(a, null, null));
    for (0..2000) |_| {
        // A random gap of the ordered keys: the start, between two, the end.
        const gap = r.uintAtMost(usize, keys.items.len);
        const lo = if (gap == 0) null else keys.items[gap - 1];
        const hi = if (gap == keys.items.len) null else keys.items[gap];
        const k = between(a, lo, hi) catch |e| switch (e) {
            error.TooLong => continue,
            else => return e,
        };
        try testing.expect(valid(k));
        if (lo) |x| try testing.expectEqual(.lt, order(x, k));
        if (hi) |y| try testing.expectEqual(.lt, order(k, y));
        try keys.insert(a, gap, k);
    }
}

test "between: always at one place, keys grow slowly, then refuse" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Each new card on top: before the last one.
    var top: []const u8 = try between(a, null, null);
    for (0..200) |_| top = try between(a, null, top);
    try testing.expect(top.len <= 64);
    // Each new card right below the first.
    const first = try between(a, null, null);
    var below: []const u8 = try between(a, first, null);
    var n: usize = 0;
    while (between(a, first, below)) |k| : (n += 1) below = k else |e| {
        try testing.expectEqual(error.TooLong, e);
    }
    try testing.expect(n >= max_len);
}

test spread {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqual(0, (try spread(a, null, null, 0)).len);
    const keys = try spread(a, "a", "b", 1000);
    var prev: []const u8 = "a";
    for (keys) |k| {
        try testing.expect(valid(k));
        try testing.expect(k.len <= 16);
        try testing.expectEqual(.lt, order(prev, k));
        prev = k;
    }
    try testing.expectEqual(.lt, order(prev, "b"));
}

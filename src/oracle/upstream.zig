//! Upstream's merge commit (`bin/git-issue-merge` at 004c0f9), so the
//! fuzzer can mix upstream merges into its histories. test/interop.zig
//! runs real upstream merges and compares them with this.
//!
//! Each field (State, Labels, Assignee, Priority, Milestone) is the first
//! non-empty value in `git log` order, read at the merge base and both
//! tips. A scalar changed on one side takes that side's value. Changed on
//! both, the later author time wins, then the greater commit ID. Labels
//! merge three-way, adds win over removals, sorted. The message is
//! `Merge issue from <remote>` plus the non-empty fields, parents local
//! then remote.

const std = @import("std");
const Allocator = std.mem.Allocator;
const issuez = @import("issuez");
const object = issuez.backend.object;
const trailers = issuez.format.trailers;
const Oid = object.Oid;

pub const Error = error{
    /// Upstream would pick one in git's internal order, which we don't
    /// reproduce.
    AmbiguousBase,
    /// Upstream would merge anyway, we never ask it to.
    NoBase,
    MissingCommit,
} || Allocator.Error;

const keys = [_][]const u8{ "State", "Labels", "Assignee", "Priority", "Milestone" };

pub const Fields = [keys.len][]const u8;

pub fn mergeMessage(
    arena: Allocator,
    backend: anytype,
    local: Oid,
    remote: Oid,
    remote_name: []const u8,
) (Error || @TypeOf(backend.*).Error)![]const u8 {
    const bases = try backend.mergeBases(arena, local, remote);
    if (bases.len == 0) return error.NoBase;
    if (bases.len > 1) return error.AmbiguousBase;
    const base = try fieldsAt(arena, backend, bases[0]);
    const ours = try fieldsAt(arena, backend, local);
    const theirs = try fieldsAt(arena, backend, remote);

    const local_c = try commitOf(arena, backend, local);
    const remote_c = try commitOf(arena, backend, remote);
    const remote_wins_ties = remote_c.author.time > local_c.author.time or
        (remote_c.author.time == local_c.author.time and
            std.mem.order(u8, remote.hex().slice(), local.hex().slice()) == .gt);

    var resolved: Fields = undefined;
    for (keys, 0..) |key, i| {
        resolved[i] = if (std.mem.eql(u8, key, "Labels"))
            try mergeLabels(arena, base[i], ours[i], theirs[i])
        else
            resolveScalar(base[i], ours[i], theirs[i], remote_wins_ties);
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.print("Merge issue from {s}\n", .{remote_name}) catch return error.OutOfMemory;
    var first = true;
    for (keys, resolved) |key, value| {
        if (value.len == 0) continue;
        if (first) w.writeAll("\n") catch return error.OutOfMemory;
        first = false;
        w.print("{s}: {s}\n", .{ key, value }) catch return error.OutOfMemory;
    }
    return out.written();
}

fn resolveScalar(
    base: []const u8,
    local: []const u8,
    remote: []const u8,
    remote_wins: bool,
) []const u8 {
    if (std.mem.eql(u8, local, remote)) return local;
    if (std.mem.eql(u8, local, base)) return remote;
    if (std.mem.eql(u8, remote, base)) return local;
    return if (remote_wins) remote else local;
}

fn mergeLabels(
    arena: Allocator,
    base_v: []const u8,
    local_v: []const u8,
    remote_v: []const u8,
) Allocator.Error![]const u8 {
    const base = try labelSet(arena, base_v);
    const local = try labelSet(arena, local_v);
    const remote = try labelSet(arena, remote_v);
    var result: std.ArrayList([]const u8) = .empty;
    // base + additions - (removals that aren't also additions)
    var all: std.ArrayList([]const u8) = .empty;
    try all.appendSlice(arena, base);
    try all.appendSlice(arena, local);
    try all.appendSlice(arena, remote);
    std.mem.sort([]const u8, all.items, {}, lessThan);
    var prev: ?[]const u8 = null;
    for (all.items) |l| {
        if (prev != null and std.mem.eql(u8, prev.?, l)) continue;
        prev = l;
        const in_base = contains(base, l);
        const added = (!in_base and (contains(local, l) or contains(remote, l)));
        const removed = in_base and (!contains(local, l) or !contains(remote, l));
        if (added or (in_base and !removed)) try result.append(arena, l);
    }
    return std.mem.join(arena, ", ", result.items);
}

fn labelSet(arena: Allocator, value: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t");
        if (l.len > 0 and !contains(out.items, l)) try out.append(arena, l);
    }
    return out.items;
}

fn contains(set: []const []const u8, x: []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn fieldsAt(arena: Allocator, backend: anytype, tip: Oid) !Fields {
    var fields: Fields = @splat("");
    for (try logOrder(arena, backend, tip)) |c| {
        const block = try trailers.parse(arena, c.message, .{});
        for (block.trailers) |t| for (keys, 0..) |key, i| {
            // awk's /^Key: / on %(trailers): exact key, non-empty value.
            if (fields[i].len == 0 and std.mem.eql(u8, t.key, key) and t.value.len > 0)
                fields[i] = t.value;
        };
    }
    return fields;
}

/// git's default walk: newest committer date first, ties in insertion
/// order.
fn logOrder(arena: Allocator, backend: anytype, tip: Oid) ![]const object.Commit {
    const Item = struct { c: object.Commit, seq: usize };
    var queue: std.ArrayList(Item) = .empty;
    var seen: std.AutoHashMapUnmanaged([Oid.max_byte_len]u8, void) = .empty;
    var out: std.ArrayList(object.Commit) = .empty;
    var seq: usize = 0;
    try queue.append(arena, .{ .c = try commitOf(arena, backend, tip), .seq = seq });
    try seen.put(arena, tip.bytes, {});
    while (queue.items.len > 0) {
        var best: usize = 0;
        for (queue.items, 0..) |it, i| {
            const b = queue.items[best];
            if (it.c.committer.time > b.c.committer.time or
                (it.c.committer.time == b.c.committer.time and it.seq < b.seq)) best = i;
        }
        const item = queue.orderedRemove(best);
        try out.append(arena, item.c);
        for (item.c.parents) |p| {
            if ((try seen.getOrPut(arena, p.bytes)).found_existing) continue;
            seq += 1;
            try queue.append(arena, .{ .c = try commitOf(arena, backend, p), .seq = seq });
        }
    }
    return out.items;
}

fn commitOf(arena: Allocator, backend: anytype, oid: Oid) !object.Commit {
    const o = (try backend.readObject(arena, oid)) orelse return error.MissingCommit;
    return object.Commit.parse(arena, backend.objectFormat(), o.data) catch error.MissingCommit;
}

const testing = std.testing;

test "labels: three-way, additions win, sorted" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("bug, ui", try mergeLabels(a, "bug", "bug, ui", "bug"));
    try testing.expectEqualStrings("ui", try mergeLabels(a, "bug", "ui", "bug"));
    try testing.expectEqualStrings("", try mergeLabels(a, "bug", "", "bug"));
    try testing.expectEqualStrings("a, b, z", try mergeLabels(a, "a", "a, z", "a, b"));
}

test "scalars" {
    try testing.expectEqualStrings("high", resolveScalar("low", "high", "low", false));
    try testing.expectEqualStrings("high", resolveScalar("low", "low", "high", false));
    try testing.expectEqualStrings("a", resolveScalar("low", "a", "b", false));
    try testing.expectEqualStrings("b", resolveScalar("low", "a", "b", true));
}

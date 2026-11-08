//! Internal: sorting that doesn't pay for buffers it won't use.
//!
//! `std.mem.sort` declares a 512-item cache before it looks at the list. In
//! Debug and ReleaseSafe that cache is filled with `undefined` on every call,
//! so sorting an empty list of 200-byte items writes 100 KiB. Most lists here
//! are short, and that fill took half the time of `git issue ls -a` on a
//! ReleaseSafe build.

const std = @import("std");

/// Up to here insertion sort is the better sort anyway.
const insertion_max = 32;

/// `std.mem.sort`, stable like it: equal items keep their order.
pub fn stable(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime lessThanFn: fn (@TypeOf(context), lhs: T, rhs: T) bool,
) void {
    if (items.len <= insertion_max) {
        std.sort.insertion(T, items, context, lessThanFn);
    } else {
        std.mem.sort(T, items, context, lessThanFn);
    }
}

const Pair = struct {
    key: u8,
    index: u32,

    fn keyLess(_: void, a: Pair, b: Pair) bool {
        return a.key < b.key;
    }
};

test stable {
    // On both sides of the switch to `std.mem.sort`.
    for ([_]usize{ 0, 1, 2, 3, insertion_max, insertion_max + 1, 1000 }) |len| {
        const items = try std.testing.allocator.alloc(Pair, len);
        defer std.testing.allocator.free(items);
        for (items, 0..) |*item, i| item.* = .{
            .key = @intCast((i * 7) % 5),
            .index = @intCast(i),
        };
        stable(Pair, items, {}, Pair.keyLess);
        for (items, 0..) |item, i| {
            if (i == 0) continue;
            const before = items[i - 1];
            try std.testing.expect(before.key <= item.key);
            if (before.key == item.key) try std.testing.expect(before.index < item.index);
        }
    }
}

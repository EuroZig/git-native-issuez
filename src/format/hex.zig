//! Lowercase hex, the way git writes object IDs and how we write sha256
//! sums and UUIDs. Uppercase is rejected, because these values are
//! compared as text.

const std = @import("std");

/// Every byte is 0-9 or a-f. Checks 16 bytes at a time.
pub fn isLower(s: []const u8) bool {
    var rest = s;
    while (rest.len >= 16) : (rest = rest[16..]) {
        if (!@reduce(.And, lowerMask(16, rest[0..16].*))) return false;
    }
    for (rest) |c| if (!isLowerDigit(c)) return false;
    return true;
}

/// True in each lane holding 0-9 or a-f.
pub fn lowerMask(comptime n: comptime_int, v: @Vector(n, u8)) @Vector(n, bool) {
    const V = @Vector(n, u8);
    const digit = v -% @as(V, @splat('0')) < @as(V, @splat(10));
    const letter = v -% @as(V, @splat('a')) < @as(V, @splat(6));
    return digit | letter;
}

pub fn isLowerDigit(c: u8) bool {
    return c -% '0' < 10 or c -% 'a' < 6;
}

test isLower {
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        const want = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expectEqual(want, isLowerDigit(c));
        // In the vector part, and in the tail.
        var buf: [40]u8 = @splat('a');
        buf[17] = c;
        try std.testing.expectEqual(want, isLower(&buf));
        buf[17] = 'a';
        buf[38] = c;
        try std.testing.expectEqual(want, isLower(&buf));
    }
    try std.testing.expect(isLower(""));
}

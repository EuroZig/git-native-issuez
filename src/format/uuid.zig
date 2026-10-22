//! Version 4 UUIDs, lowercase and hyphenated.

const std = @import("std");
const hex_fmt = @import("hex.zig");

pub const Uuid = struct {
    text: [36]u8,

    pub fn fromRandom(random: [16]u8) Uuid {
        var b = random;
        b[6] = (b[6] & 0x0f) | 0x40; // version 4
        b[8] = (b[8] & 0x3f) | 0x80; // RFC 4122 variant
        var u: Uuid = .{ .text = undefined };
        _ = std.fmt.bufPrint(&u.text, "{x}-{x}-{x}-{x}-{x}", .{
            b[0..4], b[4..6], b[6..8], b[8..10], b[10..16],
        }) catch unreachable;
        std.debug.assert(isCanonical(&u.text));
        return u;
    }

    pub fn slice(u: *const Uuid) []const u8 {
        return &u.text;
    }

    /// The 7-character ID upstream prints.
    pub fn short(u: *const Uuid) []const u8 {
        return u.text[0..7];
    }
};

/// Any version, only the shape is checked, like upstream's fsck does.
pub fn isCanonical(s: []const u8) bool {
    if (s.len != 36) return false;
    const hyphens: @Vector(36, bool) = comptime blk: {
        var m: [36]bool = @splat(false);
        for ([_]usize{ 8, 13, 18, 23 }) |i| m[i] = true;
        break :blk m;
    };
    const v: @Vector(36, u8) = s[0..36].*;
    const is_hyphen = v == @as(@Vector(36, u8), @splat('-'));
    return @reduce(.And, @select(bool, hyphens, is_hyphen, hex_fmt.lowerMask(36, v)));
}

/// Upstream uses `cut -c1-7`.
pub fn shortId(id: []const u8) []const u8 {
    return id[0..@min(7, id.len)];
}

test "fromRandom sets version and variant" {
    const t = std.testing;
    const u = Uuid.fromRandom(@splat(0xff));
    try t.expectEqualStrings("ffffffff-ffff-4fff-bfff-ffffffffffff", u.slice());
    const z = Uuid.fromRandom(@splat(0));
    try t.expectEqualStrings("00000000-0000-4000-8000-000000000000", z.slice());
    try t.expectEqualStrings("0000000", z.short());
}

test isCanonical {
    const t = std.testing;
    try t.expect(isCanonical("a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e"));
    try t.expect(!isCanonical("A7F3B2C1-4E5D-4A8B-9C1E-2F3A4B5C6D7E"));
    try t.expect(!isCanonical("a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7"));
    try t.expect(!isCanonical("a7f3b2c14e5d-4a8b-9c1e-2f3a4b5c6d7e0"));
}

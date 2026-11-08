//! Object IDs (docs/test-plan.md §2.5.2).

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

const sha1 = "5186cff79af42ee5c6a80d822eec95a842832b34";
const sha256 = "a7f3" ++ "0" ** 56 ++ "beef";

test "issuez_oid_parse, issuez_oid_hex: round trip for both formats" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    for ([_][]const u8{ sha1, sha256 }) |hex| {
        var oid: c.issuez_oid = undefined;
        try expect.code(c.ISSUEZ_OK, c.issuez_oid_parse(fixture.str(hex), &oid, null), null);
        try testing.expectEqual(hex.len / 2, oid.len);
        var buf: [65]u8 = undefined;
        try testing.expectEqual(hex.len, c.issuez_oid_hex(&oid, &buf));
        try testing.expectEqualStrings(hex, buf[0..hex.len]);
        try testing.expectEqual(@as(u8, 0), buf[hex.len]);
    }
    // None: empty text, a NUL.
    var buf: [65]u8 = @splat('x');
    const none = std.mem.zeroes(c.issuez_oid);
    try testing.expectEqual(@as(usize, 0), c.issuez_oid_hex(&none, &buf));
    try testing.expectEqual(@as(u8, 0), buf[0]);
    try testing.expectEqual(@as(usize, 0), c.issuez_oid_hex(null, &buf));
    try testing.expectEqual(@as(usize, 0), c.issuez_oid_hex(&none, null));
}

test "issuez_oid_parse: full lowercase hex only" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    const bad = [_][]const u8{
        "",
        "abc",
        sha1[0..39],
        sha1 ++ "0",
        "5186CFF79AF42EE5C6A80D822EEC95A842832B34",
        "g" ++ sha1[1..],
    };
    for (bad) |hex| {
        var oid: c.issuez_oid = undefined;
        var err: ?*c.issuez_error = null;
        try expect.code(
            c.ISSUEZ_E_INVALID_ARGUMENT,
            c.issuez_oid_parse(fixture.str(hex), &oid, &err),
            err,
        );
        c.issuez_error_free(err);
    }
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_oid_parse(fixture.str(sha1), null, null),
        null,
    );
}

test "issuez_oid_eq: bytes and length" {
    var a: c.issuez_oid = undefined;
    var b: c.issuez_oid = undefined;
    var long: c.issuez_oid = undefined;
    _ = c.issuez_oid_parse(fixture.str(sha1), &a, null);
    _ = c.issuez_oid_parse(fixture.str(sha1), &b, null);
    _ = c.issuez_oid_parse(fixture.str(sha256), &long, null);
    try testing.expect(c.issuez_oid_eq(&a, &b));
    b.bytes[19] ^= 1;
    try testing.expect(!c.issuez_oid_eq(&a, &b));
    try testing.expect(!c.issuez_oid_eq(&a, &long));
    const none = std.mem.zeroes(c.issuez_oid);
    try testing.expect(c.issuez_oid_eq(&none, &none));
    try testing.expect(c.issuez_oid_eq(null, null));
    try testing.expect(!c.issuez_oid_eq(&a, null));
}

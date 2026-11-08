//! Version and init (docs/test-plan.md §2.5.1).

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

test "issuez_version: starts with the header's version, as text" {
    const v = std.mem.span(c.issuez_version());
    const want = try std.fmt.allocPrint(testing.allocator, "{d}.{d}.{d}", .{
        c.ISSUEZ_VERSION_MAJOR,
        c.ISSUEZ_VERSION_MINOR,
        c.ISSUEZ_VERSION_PATCH,
    });
    defer testing.allocator.free(want);
    try testing.expect(std.mem.startsWith(u8, v, want));
}

test "issuez_abi_version: the header's" {
    try testing.expectEqual(@as(u32, c.ISSUEZ_ABI_VERSION), c.issuez_abi_version());
}

test "issuez_init: idempotent; another major refused with a message" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    try expect.code(c.ISSUEZ_OK, c.issuez_init(c.ISSUEZ_ABI_VERSION, null), null);
    var err: ?*c.issuez_error = null;
    try expect.code(c.ISSUEZ_OK, c.issuez_init(c.ISSUEZ_ABI_VERSION, &err), err);
    try testing.expect(err == null);
    const newer: u32 = c.ISSUEZ_ABI_VERSION + (1 << 16);
    try expect.code(c.ISSUEZ_E_ABI, c.issuez_init(newer, &err), err);
    try testing.expectEqual(@as(c.issuez_code, c.ISSUEZ_E_ABI), c.issuez_error_code(err));
    try testing.expect(fixture.slice(c.issuez_error_message(err)).len > 0);
    c.issuez_error_free(err);
    try expect.code(c.ISSUEZ_E_ABI, c.issuez_init(newer, null), null);
}

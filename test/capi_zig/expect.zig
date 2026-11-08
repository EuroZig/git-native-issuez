//! Assertions for C API results.

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const c = fixture.c;

/// The call returned `want`; on another code, prints the error's message.
pub fn code(want: c.issuez_code, got: c.issuez_code, err: ?*c.issuez_error) !void {
    if (want == got) return;
    std.debug.print("expected {s}, got {s}: {s}\n", .{
        std.mem.span(c.issuez_code_name(want)),
        std.mem.span(c.issuez_code_name(got)),
        fixture.slice(c.issuez_error_message(err)),
    });
    return error.TestUnexpectedCode;
}

/// Every `issuez_str` from the library is NUL-terminated; empty ones may
/// be `{NULL, 0}`.
pub fn terminated(s: c.issuez_str) !void {
    const p = s.ptr orelse return testing.expectEqual(@as(usize, 0), s.len);
    try testing.expectEqual(@as(u8, 0), p[s.len]);
}

/// `s` reads `want` and is terminated.
pub fn str(want: []const u8, s: c.issuez_str) !void {
    try terminated(s);
    try testing.expectEqualStrings(want, fixture.slice(s));
}

//! Value rules for format 1's core fields, as upstream's commands enforce
//! them when writing. Readers accept any value; these only guard writes.

const std = @import("std");

pub const priorities = [_][]const u8{ "low", "medium", "high", "critical" };

pub fn isPriority(s: []const u8) bool {
    for (priorities) |p| if (std.mem.eql(u8, p, s)) return true;
    return false;
}

/// Letters, digits, `-` and `_`, like upstream's `state --state`.
pub fn isState(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}

/// Why upstream's `validate_email` refuses an address, checked in its order.
pub const EmailProblem = enum { not_an_email, missing_local_part, missing_domain, missing_tld };

/// Null when `email` passes upstream's `validate_email`.
pub fn checkEmail(email: []const u8) ?EmailProblem {
    const at = std.mem.findScalar(u8, email, '@') orelse return .not_an_email;
    const after_at = email[at + 1 ..];
    if (std.mem.findScalar(u8, after_at, '.') == null) return .not_an_email;
    if (at == 0) return .missing_local_part;
    if (after_at[0] == '.') return .missing_domain;
    if (email[email.len - 1] == '.') return .missing_tld;
    return null;
}

test checkEmail {
    const t = std.testing;
    try t.expectEqual(null, checkEmail("ada@example.com"));
    try t.expectEqual(null, checkEmail("first last@example.com"));
    try t.expectEqual(EmailProblem.not_an_email, checkEmail(""));
    try t.expectEqual(EmailProblem.not_an_email, checkEmail("ada@example"));
    try t.expectEqual(EmailProblem.missing_local_part, checkEmail("@example.com"));
    try t.expectEqual(EmailProblem.missing_domain, checkEmail("ada@.com"));
    try t.expectEqual(EmailProblem.missing_tld, checkEmail("ada@example."));
}

test isState {
    try std.testing.expect(isState("in-progress_2"));
    try std.testing.expect(!isState(""));
    try std.testing.expect(!isState("in progress"));
}

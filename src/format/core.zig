//! Value rules for format 1's core fields, as upstream's commands enforce
//! them when writing. Readers accept any value; these only guard writes.

const std = @import("std");

/// Upstream's four levels, lowest first.
pub const Priority = enum {
    low,
    medium,
    high,
    critical,

    /// Exactly one of the four names. Readers keep other values as text.
    pub fn parse(s: []const u8) ?Priority {
        return std.meta.stringToEnum(Priority, s);
    }

    pub fn text(p: Priority) []const u8 {
        return @tagName(p);
    }

    /// 1 (low) to 4 (critical).
    pub fn rank(p: Priority) u8 {
        return @as(u8, @intFromEnum(p)) + 1;
    }
};

/// States besides `closed` that count as done when `issue.doneStates`
/// isn't set.
pub const default_done_states = [_][]const u8{ "wontfix", "duplicate" };

/// An issue's state. Format 1 knows `open` and `closed` and allows others
/// (`wontfix`, `in-review`, ...). `closed` and the configured done states
/// count as done: `ls` hides them, and parents, blockers and progress treat
/// them as closed. Every other state is open work.
pub const State = union(enum) {
    open,
    closed,
    other: []const u8,

    /// Any text, as read. `open` and `closed` get their own tags.
    pub fn parse(s: []const u8) State {
        if (std.mem.eql(u8, s, "open")) return .open;
        if (std.mem.eql(u8, s, "closed")) return .closed;
        return .{ .other = s };
    }

    pub fn text(s: State) []const u8 {
        return switch (s) {
            .open => "open",
            .closed => "closed",
            .other => |t| t,
        };
    }

    /// Exactly `open`, also as `.{ .other = "open" }`.
    pub fn isOpen(s: State) bool {
        return std.mem.eql(u8, s.text(), "open");
    }

    /// `closed`, or one of `done_states`.
    pub fn isDone(s: State, done_states: []const []const u8) bool {
        const t = s.text();
        if (std.mem.eql(u8, t, "closed")) return true;
        for (done_states) |d| if (std.mem.eql(u8, d, t)) return true;
        return false;
    }

    /// Same text. `.{ .other = "open" }` equals `.open`.
    pub fn eql(a: State, b: State) bool {
        return std.mem.eql(u8, a.text(), b.text());
    }
};

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

test Priority {
    try std.testing.expectEqual(Priority.high, Priority.parse("high").?);
    try std.testing.expect(Priority.parse("urgent") == null);
    try std.testing.expect(Priority.parse("High") == null);
    try std.testing.expectEqual(@as(u8, 4), Priority.critical.rank());
    try std.testing.expectEqual(@as(u8, 1), Priority.low.rank());
}

test State {
    try std.testing.expectEqual(State.open, State.parse("open"));
    try std.testing.expectEqual(State.closed, State.parse("closed"));
    const wontfix = State.parse("wontfix");
    try std.testing.expectEqualStrings("wontfix", wontfix.text());
    try std.testing.expect(!wontfix.isOpen());
    try std.testing.expect(State.eql(.{ .other = "open" }, .open));
    try std.testing.expect((State{ .other = "open" }).isOpen());
    try std.testing.expect(wontfix.isDone(&default_done_states));
    try std.testing.expect(!wontfix.isDone(&.{}));
    try std.testing.expect((State{ .closed = {} }).isDone(&.{}));
    try std.testing.expect(!State.parse("in-review").isDone(&default_done_states));
    try std.testing.expect((State{ .other = "closed" }).isDone(&.{}));
    try std.testing.expect(!State.eql(wontfix, .closed));
}

test isState {
    try std.testing.expect(isState("in-progress_2"));
    try std.testing.expect(!isState(""));
    try std.testing.expect(!isState("in progress"));
}

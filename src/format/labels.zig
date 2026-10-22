//! `Labels: a, b`: comma-separated, trimmed, case-sensitive, no empty or
//! duplicate labels, written with ", " like upstream's `normalize_labels`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Keeps the first of duplicates, in order.
pub fn parse(arena: Allocator, value: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const label = std.mem.trim(u8, raw, " \t\r\n");
        if (label.len == 0) continue;
        if (contains(out.items, label)) continue;
        try out.append(arena, label);
    }
    return out.toOwnedSlice(arena);
}

pub fn join(arena: Allocator, labels: []const []const u8) Allocator.Error![]const u8 {
    return std.mem.join(arena, ", ", labels);
}

pub fn contains(labels: []const []const u8, label: []const u8) bool {
    for (labels) |l| if (std.mem.eql(u8, l, label)) return true;
    return false;
}

/// A user-supplied label can't contain the separator or a newline.
pub fn validate(label: []const u8) error{ LabelContainsComma, LabelContainsNewline }!void {
    if (std.mem.findScalar(u8, label, ',') != null) return error.LabelContainsComma;
    if (std.mem.findAny(u8, label, "\r\n") != null) return error.LabelContainsNewline;
}

test parse {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const labels = try parse(arena, " bug,auth , bug,, Bug ");
    try t.expectEqual(@as(usize, 3), labels.len);
    try t.expectEqualStrings("bug", labels[0]);
    try t.expectEqualStrings("auth", labels[1]);
    try t.expectEqualStrings("Bug", labels[2]);
    try t.expectEqualStrings("bug, auth, Bug", try join(arena, labels));
    try t.expectEqual(@as(usize, 0), (try parse(arena, "")).len);
    try t.expectError(error.LabelContainsComma, validate("a,b"));
}

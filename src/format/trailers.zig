//! Subject, body and trailers, parsed like git's trailer.c does it.
//!
//! Upstream reads every field through `git log --format=%(trailers)`, so
//! any difference here would make the two tools disagree about an issue.
//! The block is the last paragraph (never the subject paragraph), ignoring
//! trailing blank and `#` lines. A trailer line starts with a token of
//! letters, digits or `-`, optional spaces and `:`. Lines starting with
//! whitespace continue the previous trailer. The block counts when all its
//! lines are trailers, or when it has a git-generated line like
//! `Signed-off-by:` and at least 25% trailers. `git log` has no patch
//! divider, so `---` is plain text unless `Options.divider` is set, which
//! matches `interpret-trailers --parse`.
//!
//! test/trailers_git.zig compares the results with git.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const Trailer = struct {
    /// As written, trailing whitespace removed.
    key: []const u8,
    /// Trimmed, continuation lines unfolded. Empty clears a field.
    value: []const u8,
};

pub const Options = struct {
    /// The first paragraph is a title and can't hold trailers. True for
    /// whole commit messages.
    has_title: bool = true,
    /// Stop at `---` like `git interpret-trailers`.
    divider: bool = false,
};

pub const Block = struct {
    trailers: []const Trailer,
    /// Index of the block's first line, null without a block. The lines
    /// before it, minus the blank separator, are the text.
    first_line: ?usize,
};

/// Lines git generates itself. They count when detecting the block, and
/// make the 25% rule apply, but only lines with a separator are returned.
const git_generated_prefixes = [_][]const u8{ "Signed-off-by: ", "(cherry picked from commit " };

pub fn parse(arena: Allocator, message: []const u8, options: Options) Allocator.Error!Block {
    var lines: std.ArrayList([]const u8) = .empty;
    try splitLines(arena, message, &lines);
    return parseLines(arena, lines.items, options);
}

pub fn parseLines(
    arena: Allocator,
    all_lines: []const []const u8,
    options: Options,
) Allocator.Error!Block {
    const none: Block = .{ .trailers = &.{}, .first_line = null };

    // End of the message: the divider if enabled, then trailing blank and
    // comment lines.
    var end = all_lines.len;
    if (options.divider) {
        for (all_lines, 0..) |line, i| {
            if (std.mem.startsWith(u8, line, "---") and (line.len == 3 or isSpace(line[3]))) {
                end = i;
                break;
            }
        }
    }
    while (end > 0 and (isBlank(all_lines[end - 1]) or isComment(all_lines[end - 1]))) end -= 1;
    const lines = all_lines[0..end];

    var title_end: usize = 0;
    if (options.has_title) {
        while (title_end < lines.len and isBlank(lines[title_end])) title_end += 1;
        while (title_end < lines.len and !isBlank(lines[title_end])) title_end += 1;
        if (title_end >= lines.len) return none;
    }

    var start = lines.len;
    var trailer_lines: usize = 0;
    var non_trailer_lines: usize = 0;
    var possible_continuation: usize = 0;
    var recognized_prefix = false;
    while (start > title_end) {
        const line = lines[start - 1];
        if (isComment(line)) {
            // Continuation lines below a comment have nothing to continue.
            non_trailer_lines += possible_continuation;
            possible_continuation = 0;
            start -= 1;
            continue;
        }
        if (isBlank(line)) break;
        if (isGitGenerated(line)) {
            trailer_lines += 1;
            possible_continuation = 0;
            recognized_prefix = true;
        } else if (isSpace(line[0])) {
            possible_continuation += 1;
        } else if (separatorPos(line) != null) {
            trailer_lines += 1;
            possible_continuation = 0;
        } else {
            non_trailer_lines += possible_continuation + 1;
            possible_continuation = 0;
        }
        start -= 1;
    }
    // Indented lines with no trailer above them aren't trailers.
    non_trailer_lines += possible_continuation;

    const accepted = trailer_lines > 0 and
        (non_trailer_lines == 0 or (recognized_prefix and trailer_lines * 3 >= non_trailer_lines));
    if (!accepted) return none;

    // Each newline plus indentation becomes one space, then the whole value
    // is trimmed, so trailing spaces before a continuation stay, as in git.
    var trailers: std.ArrayList(Trailer) = .empty;
    var i = start;
    // A continuation only extends the trailer right above it.
    var can_continue = false;
    while (i < lines.len) : (i += 1) {
        const line = lines[i];
        if (isComment(line)) {
            can_continue = false;
            continue;
        }
        const sep = separatorPos(line) orelse {
            if (isSpace(line[0]) and can_continue) {
                const last = &trailers.items[trailers.items.len - 1];
                last.value = try std.mem.concat(arena, u8, &.{ last.value, " ", trimStart(line) });
            } else if (!isSpace(line[0])) {
                can_continue = false;
            }
            continue;
        };
        can_continue = true;
        try trailers.append(arena, .{
            .key = std.mem.trimEnd(u8, line[0..sep], " \t"),
            .value = trimStart(line[sep + 1 ..]),
        });
    }
    for (trailers.items) |*t| finishValue(t);
    return .{ .trailers = try trailers.toOwnedSlice(arena), .first_line = start };
}

/// Position of `:` if `line` starts with a trailer token (git's
/// find_separator with the default separators).
pub fn separatorPos(line: []const u8) ?usize {
    var whitespace_found = false;
    for (line, 0..) |c, i| {
        if (c == ':') return if (i >= 1) i else null;
        if (!whitespace_found and (std.ascii.isAlphanumeric(c) or c == '-')) continue;
        if (i != 0 and (c == ' ' or c == '\t')) {
            whitespace_found = true;
            continue;
        }
        return null;
    }
    return null;
}

/// Case-insensitive like `%(trailers:key=...)`. Empty means present but
/// empty, null means absent.
pub fn lastValue(block: Block, key: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (block.trailers) |t| if (std.ascii.eqlIgnoreCase(t.key, key)) {
        found = t.value;
    };
    return found;
}

pub fn has(block: Block, key: []const u8) bool {
    return lastValue(block, key) != null;
}

/// `%s`: the first paragraph, lines joined with spaces.
pub fn subject(arena: Allocator, message: []const u8) Allocator.Error![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    try splitLines(arena, message, &lines);
    var parts: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < lines.items.len and isBlank(lines.items[i])) i += 1;
    while (i < lines.items.len and !isBlank(lines.items[i])) : (i += 1) {
        try parts.append(arena, std.mem.trimEnd(u8, lines.items[i], " \t\r"));
    }
    return std.mem.join(arena, " ", parts.items);
}

/// `%b` as lines. git keeps trailing whitespace-only lines, so only empty
/// ones are dropped.
pub fn bodyLines(arena: Allocator, message: []const u8) Allocator.Error![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    try splitLines(arena, message, &lines);
    var i: usize = 0;
    while (i < lines.items.len and isBlank(lines.items[i])) i += 1;
    while (i < lines.items.len and !isBlank(lines.items[i])) i += 1;
    while (i < lines.items.len and isBlank(lines.items[i])) i += 1;
    var end = lines.items.len;
    while (end > i and lines.items[end - 1].len == 0) end -= 1;
    return lines.items[i..end];
}

/// The body without its trailer block. See `Options.has_title` for
/// `body_has_title`.
pub fn textLines(
    arena: Allocator,
    body: []const []const u8,
    body_has_title: bool,
) Allocator.Error![]const []const u8 {
    const block = try parseLines(arena, body, .{ .has_title = body_has_title, .divider = true });
    const first = block.first_line orelse return body;
    var end = first;
    while (end > 0 and isBlank(body[end - 1])) end -= 1;
    return body[0..end];
}

pub const WriteError = error{
    /// A newline in a subject or value, or a bad trailer key.
    InvalidText,
    /// The body's last paragraph would parse as trailers, so user text would
    /// be read as metadata.
    BodyLooksLikeTrailers,
} || Allocator.Error;

/// Empty values are written as `K: ` with the space, like
/// `git interpret-trailers`, because upstream's `ls` matches `^K: `.
pub fn build(
    arena: Allocator,
    subject_text: []const u8,
    body: []const u8,
    trailer_list: []const Trailer,
) WriteError![]const u8 {
    if (subject_text.len == 0) return error.InvalidText;
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    const body_trimmed = std.mem.trimEnd(u8, body, " \t\r\n");
    // The subject may span lines (upstream's -m) but not contain a blank
    // line, which would move text into the body.
    const subject_trimmed = std.mem.trimEnd(u8, subject_text, " \t\r\n");
    if (subject_trimmed.len == 0) return error.InvalidText;
    w.writeAll(subject_trimmed) catch return error.OutOfMemory;
    if (body_trimmed.len > 0) w.print("\n\n{s}", .{body_trimmed}) catch return error.OutOfMemory;
    if (trailer_list.len > 0) {
        w.writeAll("\n\n") catch return error.OutOfMemory;
        for (trailer_list) |t| {
            if (!isValidKey(t.key)) return error.InvalidText;
            if (std.mem.findAny(u8, t.value, "\r\n") != null) return error.InvalidText;
            w.print("{s}: {s}\n", .{ t.key, t.value }) catch return error.OutOfMemory;
        }
    } else {
        w.writeAll("\n") catch return error.OutOfMemory;
    }
    const message = aw.written();

    // It has to parse back to exactly our trailers.
    const back = try parse(arena, message, .{});
    if (trailer_list.len == 0) {
        if (back.first_line != null) return error.BodyLooksLikeTrailers;
    } else if (back.trailers.len != trailer_list.len) {
        return error.BodyLooksLikeTrailers;
    }
    return message;
}

pub fn isValidKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    return true;
}

/// Drops a final empty line and trailing CRs.
fn splitLines(
    arena: Allocator,
    message: []const u8,
    out: *std.ArrayList([]const u8),
) Allocator.Error!void {
    var it = std.mem.splitScalar(u8, message, '\n');
    while (it.next()) |raw| try out.append(arena, std.mem.trimEnd(u8, raw, "\r"));
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0) _ = out.pop();
}

fn isGitGenerated(line: []const u8) bool {
    for (git_generated_prefixes) |p| if (std.mem.startsWith(u8, line, p)) return true;
    return false;
}

fn isBlank(line: []const u8) bool {
    for (line) |c| if (!isSpace(c)) return false;
    return true;
}

fn isComment(line: []const u8) bool {
    return line.len > 0 and line[0] == '#';
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\x0b' or c == '\x0c';
}

fn trimStart(s: []const u8) []const u8 {
    return std.mem.trimStart(u8, s, " \t\r\x0b\x0c");
}

fn finishValue(t: *Trailer) void {
    t.value = trim(t.value);
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\x0b\x0c");
}

// Expected values measured with git 2.30 to 2.54.

const testing = std.testing;

fn expectTrailers(message: []const u8, expected: []const [2][]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const block = try parse(arena_state.allocator(), message, .{});
    testing.expectEqual(expected.len, block.trailers.len) catch |err| {
        std.debug.print("message: {s}\ngot {d} trailers\n", .{ message, block.trailers.len });
        return err;
    };
    for (expected, block.trailers) |e, t| {
        try testing.expectEqualStrings(e[0], t.key);
        try testing.expectEqualStrings(e[1], t.value);
    }
}

test "S2 corpus: git log %(trailers) semantics" {
    try expectTrailers("State: closed\n", &.{});
    try expectTrailers(
        "Title\n\nState: closed\nLabels: bug\n",
        &.{ .{ "State", "closed" }, .{ "Labels", "bug" } },
    );
    try expectTrailers("Title\n\nJust prose.\n", &.{});
    try expectTrailers("Title\n\nState: closed\nnot a trailer\n", &.{});
    try expectTrailers("Title\n\nState: closed\nLabels: a\nPriority: high\nprose line\n", &.{});
    try expectTrailers(
        "Title\n\nSigned-off-by: A <a@b>\nline\nline\nline\n",
        &.{.{ "Signed-off-by", "A <a@b>" }},
    );
    try expectTrailers("Title\n\nX-Foo: a\nline\nline\nline\n", &.{});
    try expectTrailers(
        "Title\n\nState: closed\nX-Long: first\n  second\n",
        &.{ .{ "State", "closed" }, .{ "X-Long", "first second" } },
    );
    try expectTrailers("Title\n\nFixes bug: x\nState: open\n", &.{});
    try expectTrailers("Title\n\nState:closed\n", &.{.{ "State", "closed" }});
    try expectTrailers("Title\n\nState# closed\n", &.{});
    try expectTrailers(
        "Title\n\nState: open\nAssignee:\n",
        &.{ .{ "State", "open" }, .{ "Assignee", "" } },
    );
    try expectTrailers("Title\n\nState: open\n---\nX-After: 1\n", &.{});
    try expectTrailers("Title\n\nState: open\n\n", &.{.{ "State", "open" }});
    try expectTrailers(
        "Title\n\nBody para\n\nState: open\nX-Parent: abc\n",
        &.{ .{ "State", "open" }, .{ "X-Parent", "abc" } },
    );
    try expectTrailers("Comment\n\nI think\nX-Deleted: true\n", &.{});
    try expectTrailers("Comment\n\nI think so.\n\nX-Deleted: true\n", &.{.{ "X-Deleted", "true" }});
    try expectTrailers("Title\n\nPriorit\xc3\xa4t: hoch\n", &.{});
    try expectTrailers("Title\n\n# comment\nState: open\n", &.{.{ "State", "open" }});
    try expectTrailers("Title\r\n\r\nState: open\r\n", &.{.{ "State", "open" }});
    try expectTrailers("T\n\nX_Foo: a\n", &.{});
    try expectTrailers("T\n\n1Key: a\n", &.{.{ "1Key", "a" }});
    try expectTrailers("T\n\nState : open\n", &.{.{ "State", "open" }});
    try expectTrailers("T\n\n State: open\n", &.{});
    try expectTrailers("T\n\nX-Url: http://a:b/c\n", &.{.{ "X-Url", "http://a:b/c" }});
    try expectTrailers("T\n\nState:\topen\n", &.{.{ "State", "open" }});
    try expectTrailers("T\n\n(cherry picked from commit abc)\nx\ny\nz\n", &.{});
    try expectTrailers("T\n\nState: open   \n", &.{.{ "State", "open" }});
}

test "divider and title options" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const with_divider = try parse(
        arena,
        "Title\n\nState: open\n---\nX-After: 1\n",
        .{ .divider = true },
    );
    try testing.expectEqual(@as(usize, 1), with_divider.trailers.len);
    // Only trailers: as a message its one paragraph is the title, so none
    // of it is a trailer. Upstream's `show` behaves the same way.
    const body_only = try parse(arena, "State: closed\n", .{ .has_title = true });
    try testing.expectEqual(@as(usize, 0), body_only.trailers.len);
    const no_title = try parse(arena, "State: closed\n", .{ .has_title = false });
    try testing.expectEqual(@as(usize, 1), no_title.trailers.len);
}

test "subject and body follow %s / %b" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const msg = "line one\nline two\n\n\nbody a\n\nbody b\n\nState: open\nAssignee:\n";
    try testing.expectEqualStrings("line one line two", try subject(arena, msg));
    const body = try bodyLines(arena, msg);
    try testing.expectEqual(@as(usize, 6), body.len);
    try testing.expectEqualStrings("body a", body[0]);
    const text = try textLines(arena, body, false);
    try testing.expectEqual(@as(usize, 3), text.len);
    try testing.expectEqualStrings("body b", text[2]);
}

test "build" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const msg = try build(arena, "Crash on login", "First.\n\nSecond.", &.{
        .{ .key = "State", .value = "open" },
        .{ .key = "Assignee", .value = "" },
        .{ .key = "Format-Version", .value = "1" },
    });
    try testing.expectEqualStrings(
        "Crash on login\n\nFirst.\n\nSecond.\n\nState: open\nAssignee: \nFormat-Version: 1\n",
        msg,
    );
    try testing.expectEqualStrings("Comment\n", try build(arena, "Comment", "", &.{}));
    try testing.expectError(
        error.BodyLooksLikeTrailers,
        build(arena, "Hi", "I think so.\n\nX-Deleted: true", &.{}),
    );
    // Followed by our own block, a trailer-like paragraph is just text.
    const harmless = try build(arena, "Hi", "Fixes: 12", &.{.{ .key = "State", .value = "open" }});
    const harmless_block = try parse(arena, harmless, .{});
    try testing.expectEqual(@as(usize, 1), harmless_block.trailers.len);
    try testing.expect(lastValue(harmless_block, "Fixes") == null);
    try testing.expectError(
        error.InvalidText,
        build(arena, "Hi", "", &.{.{ .key = "State", .value = "a\nb" }}),
    );
    // A `---` line in the body doesn't hide our trailers, unlike
    // upstream's writer.
    const dashes = try build(
        arena,
        "Dashes",
        "Intro\n---\nMore",
        &.{.{ .key = "Labels", .value = "bug" }},
    );
    const back = try parse(arena, dashes, .{});
    try testing.expectEqualStrings("bug", lastValue(back, "Labels").?);
}

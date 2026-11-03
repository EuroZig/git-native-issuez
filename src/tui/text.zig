//! Wrapping text into rows, and the text box every input uses.
//!
//! One wrapping rule for showing text and for editing it, so the cursor
//! lands where the text is drawn.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

/// A visual row: `text[start..end]`, without the newline.
pub const Row = struct {
    start: u32,
    end: u32,
    /// The next row continues this line: the break isn't a newline.
    soft: bool,
};

/// Rows at most this many columns wide, so a huge description can't
/// stall a frame.
pub const max_rows = 20_000;

/// Columns a tab takes. Terminals' tab stops don't apply to cells, so a
/// tab is drawn as this many spaces: see `expandTabs`.
pub const tab_width = 4;

/// The display width of one grapheme cluster's UTF-8 bytes.
pub fn width(bytes: []const u8) u16 {
    if (bytes.len == 1 and bytes[0] == '\t') return tab_width;
    return vaxis.gwidth.gwidth(bytes, .unicode);
}

/// `text` with each tab as `tab_width` spaces, for drawing: vaxis drops
/// control characters.
pub fn expandTabs(arena: Allocator, text: []const u8) []const u8 {
    const tabs = std.mem.countScalar(u8, text, '\t');
    if (tabs == 0) return text;
    const out = arena.alloc(u8, text.len + tabs * (tab_width - 1)) catch return text;
    var n: usize = 0;
    for (text) |c| {
        if (c == '\t') {
            @memset(out[n..][0..tab_width], ' ');
            n += tab_width;
        } else {
            out[n] = c;
            n += 1;
        }
    }
    assert(n == out.len);
    return out;
}

/// The byte length of the UTF-8 sequence starting at `text[i]`, 1 for an
/// invalid byte, so every byte is passed exactly once.
pub fn seqLen(text: []const u8, i: usize) u32 {
    assert(i < text.len);
    const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return 1;
    if (i + n > text.len) return 1;
    return n;
}

/// The byte length of the grapheme cluster starting at `text[i]`, what
/// vaxis draws as one cell or two: an emoji with a skin tone or joined
/// ones, a letter with its accents. Never into a newline, at least 1.
pub fn clusterLen(text: []const u8, i: usize) u32 {
    assert(i < text.len);
    const first = seqLen(text, i);
    // ASCII followed by ASCII (or the end) is a cluster of its own.
    if (text[i] < 0x80 and (i + 1 == text.len or text[i + 1] < 0x80)) return 1;
    const line_end = std.mem.findScalarPos(u8, text, i, '\n') orelse text.len;
    if (line_end == i) return 1;
    var it = vaxis.unicode.graphemeIterator(text[i..line_end]);
    const g = it.next() orelse return first;
    return @intCast(@max(g.len, 1));
}

/// Wraps `text` at `cols` columns, at a space where one is on the row.
/// An empty text is one empty row.
pub fn layout(arena: Allocator, text: []const u8, cols: u16) Allocator.Error![]const Row {
    assert(text.len <= std.math.maxInt(u32));
    const w: u16 = @max(cols, 1);
    var rows: std.ArrayList(Row) = .empty;
    var line_start: u32 = 0;
    const n: u32 = @intCast(text.len);
    while (rows.items.len < max_rows) {
        const line_end: u32 = if (std.mem.findScalarPos(u8, text, line_start, '\n')) |p|
            @intCast(p)
        else
            n;
        // Greedy rows within the line.
        var row_start = line_start;
        while (rows.items.len < max_rows) {
            var col: u32 = 0;
            var i = row_start;
            var last_space: ?u32 = null;
            while (i < line_end) {
                const len = clusterLen(text, i);
                const cw = width(text[i .. i + len]);
                if (col + cw > w and i > row_start) break;
                col += cw;
                if (text[i] == ' ') last_space = i;
                i += len;
            }
            if (i >= line_end) {
                try rows.append(arena, .{ .start = row_start, .end = line_end, .soft = false });
                break;
            }
            // Break after the last space, unless the row would be empty.
            const cut = if (last_space) |s| if (s + 1 > row_start) s + 1 else i else i;
            try rows.append(arena, .{ .start = row_start, .end = cut, .soft = true });
            row_start = cut;
        }
        if (line_end >= n) break;
        line_start = line_end + 1;
    }
    assert(rows.items.len >= 1);
    return rows.items;
}

/// The row `pos` is drawn on. At a soft break the cursor goes to the start
/// of the next row.
pub fn rowOf(rows: []const Row, pos: u32) u32 {
    assert(rows.len > 0);
    for (rows, 0..) |r, i| {
        if (pos < r.start) continue;
        if (pos < r.end) return @intCast(i);
        if (pos == r.end and !r.soft) return @intCast(i);
    }
    return @intCast(rows.len - 1);
}

/// Columns from the row's start to `pos`. A `pos` past the row, as in
/// text beyond `max_rows`, counts as its end.
pub fn colOf(text: []const u8, row: Row, pos: u32) u16 {
    assert(pos >= row.start);
    const end = @min(pos, row.end);
    var col: u16 = 0;
    var i = row.start;
    while (i < end) {
        const len = clusterLen(text, i);
        col +|= width(text[i .. i + len]);
        i += len;
    }
    return col;
}

/// The byte offset in `row` nearest to column `col`.
pub fn posAt(text: []const u8, row: Row, col: u32) u32 {
    var c: u32 = 0;
    var i = row.start;
    // A soft row ends with the space it broke at; stay before it.
    const end = if (row.soft and row.end > row.start and text[row.end - 1] == ' ') row.end - 1 else row.end;
    while (i < end) {
        const len = clusterLen(text, i);
        const cw = width(text[i .. i + len]);
        if (c + cw > col) break;
        c += cw;
        i += len;
    }
    return i;
}

/// An editable text. Single-line boxes take no newlines: Enter is the
/// caller's to handle.
pub const TextArea = struct {
    buf: std.ArrayList(u8) = .empty,
    /// A byte offset, always at a grapheme cluster boundary.
    cursor: u32 = 0,
    multiline: bool,
    /// The first visual row shown.
    scroll: u32 = 0,
    /// Set by `draw`, for `click` and up and down.
    cols: u16 = 1,
    /// `draw` scrolls the cursor into view. The wheel turns this off,
    /// moving the cursor turns it on again.
    follow: bool = true,

    pub const max_bytes = 1024 * 1024;
    /// What PageUp and PageDown move.
    const page_rows = 10;

    pub fn init(multiline: bool) TextArea {
        return .{ .multiline = multiline };
    }

    pub fn deinit(t: *TextArea, gpa: Allocator) void {
        t.buf.deinit(gpa);
        t.* = undefined;
    }

    pub fn text(t: *const TextArea) []const u8 {
        return t.buf.items;
    }

    pub fn set(t: *TextArea, gpa: Allocator, value: []const u8) Allocator.Error!void {
        t.buf.clearRetainingCapacity();
        t.cursor = 0;
        try t.insert(gpa, value);
        t.scroll = 0;
        t.follow = true;
    }

    pub fn clear(t: *TextArea) void {
        t.buf.clearRetainingCapacity();
        t.cursor = 0;
        t.scroll = 0;
        t.follow = true;
    }

    /// Inserts at the cursor. A single-line box turns newlines into spaces.
    pub fn insert(t: *TextArea, gpa: Allocator, value: []const u8) Allocator.Error!void {
        assert(t.cursor <= t.buf.items.len);
        const room = max_bytes -| t.buf.items.len;
        var n = @min(value.len, room);
        // Not in the middle of a codepoint.
        if (n < value.len) while (n > 0 and (value[n] & 0xC0) == 0x80) {
            n -= 1;
        };
        const v = value[0..n];
        try t.buf.insertSlice(gpa, t.cursor, v);
        if (!t.multiline) {
            for (t.buf.items[t.cursor..][0..v.len]) |*c| {
                if (c.* == '\n' or c.* == '\r' or c.* == '\t') c.* = ' ';
            }
        } else for (t.buf.items[t.cursor..][0..v.len]) |*c| {
            if (c.* == '\r') c.* = '\n';
        }
        t.cursor += @intCast(v.len);
        assert(t.cursor <= t.buf.items.len);
    }

    /// The cluster boundary before `pos`: clusters only read forward, so
    /// from the line's start.
    fn prevPos(t: *const TextArea, pos: u32) u32 {
        if (pos == 0) return 0;
        const s = t.buf.items;
        if (s[pos - 1] == '\n') return pos - 1;
        var p = t.lineStart(pos - 1);
        while (true) {
            const next = p + clusterLen(s, p);
            if (next >= pos) return p;
            p = next;
        }
    }

    fn nextPos(t: *const TextArea, pos: u32) u32 {
        const s = t.buf.items;
        if (pos >= s.len) return @intCast(s.len);
        return pos + clusterLen(s, pos);
    }

    fn wordLeft(t: *const TextArea, pos: u32) u32 {
        const s = t.buf.items;
        var p = pos;
        while (p > 0 and !isWord(s[p - 1])) p -= 1;
        while (p > 0 and isWord(s[p - 1])) p -= 1;
        return p;
    }

    fn wordRight(t: *const TextArea, pos: u32) u32 {
        const s = t.buf.items;
        var p = pos;
        while (p < s.len and !isWord(s[p])) p += 1;
        while (p < s.len and isWord(s[p])) p += 1;
        return p;
    }

    fn isWord(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
    }

    fn lineStart(t: *const TextArea, pos: u32) u32 {
        const s = t.buf.items[0..pos];
        return if (std.mem.findScalarLast(u8, s, '\n')) |p| @intCast(p + 1) else 0;
    }

    fn lineEnd(t: *const TextArea, pos: u32) u32 {
        const s = t.buf.items;
        return if (std.mem.findScalarPos(u8, s, pos, '\n')) |p| @intCast(p) else @intCast(s.len);
    }

    fn remove(t: *TextArea, from: u32, to: u32) void {
        assert(from <= to and to <= t.buf.items.len);
        const n = to - from;
        if (n == 0) return;
        std.mem.copyForwards(u8, t.buf.items[from..], t.buf.items[to..]);
        t.buf.items.len -= n;
        t.cursor = from;
    }

    /// Moves the cursor `n` visual rows up or down, keeping the column.
    fn vertical(t: *TextArea, arena: Allocator, down: bool, n: u32) Allocator.Error!void {
        const rows = try layout(arena, t.buf.items, t.cols);
        const r = rowOf(rows, t.cursor);
        const col = colOf(t.buf.items, rows[r], t.cursor);
        if (down) {
            if (r + n >= rows.len) {
                t.cursor = @intCast(t.buf.items.len);
                return;
            }
            t.cursor = posAt(t.buf.items, rows[r + n], col);
        } else {
            if (r < n) {
                t.cursor = 0;
                return;
            }
            t.cursor = posAt(t.buf.items, rows[r - n], col);
        }
    }

    pub const Outcome = enum { handled, ignored };

    /// Editing keys. Enter in a single-line box, Escape, Tab and anything
    /// with Ctrl it doesn't know are `ignored`, for the caller.
    pub fn key(t: *TextArea, gpa: Allocator, arena: Allocator, k: vaxis.Key) Allocator.Error!Outcome {
        const K = vaxis.Key;
        const ctrl: K.Modifiers = .{ .ctrl = true };
        const alt: K.Modifiers = .{ .alt = true };
        if (k.matches(K.left, .{})) {
            t.cursor = t.prevPos(t.cursor);
        } else if (k.matches(K.right, .{})) {
            t.cursor = t.nextPos(t.cursor);
        } else if (k.matches(K.left, ctrl) or k.matches(K.left, alt) or k.matches('b', alt)) {
            t.cursor = t.wordLeft(t.cursor);
        } else if (k.matches(K.right, ctrl) or k.matches(K.right, alt) or k.matches('f', alt)) {
            t.cursor = t.wordRight(t.cursor);
        } else if (k.matches(K.home, .{}) or k.matches('a', ctrl)) {
            t.cursor = t.lineStart(t.cursor);
        } else if (k.matches(K.end, .{}) or k.matches('e', ctrl)) {
            t.cursor = t.lineEnd(t.cursor);
        } else if (k.matches(K.home, ctrl)) {
            t.cursor = 0;
        } else if (k.matches(K.end, ctrl)) {
            t.cursor = @intCast(t.buf.items.len);
        } else if (t.multiline and k.matches(K.up, .{})) {
            try t.vertical(arena, false, 1);
        } else if (t.multiline and k.matches(K.down, .{})) {
            try t.vertical(arena, true, 1);
        } else if (t.multiline and k.matches(K.page_up, .{})) {
            try t.vertical(arena, false, page_rows);
        } else if (t.multiline and k.matches(K.page_down, .{})) {
            try t.vertical(arena, true, page_rows);
        } else if (k.matches(K.backspace, .{}) or k.matches('h', ctrl)) {
            t.remove(t.prevPos(t.cursor), t.cursor);
        } else if (k.matches(K.backspace, alt) or k.matches('w', ctrl) or k.matches(K.backspace, ctrl)) {
            t.remove(t.wordLeft(t.cursor), t.cursor);
        } else if (k.matches(K.delete, .{}) or k.matches('d', ctrl)) {
            t.remove(t.cursor, t.nextPos(t.cursor));
        } else if (k.matches('u', ctrl)) {
            t.remove(t.lineStart(t.cursor), t.cursor);
        } else if (k.matches('k', ctrl)) {
            const end = t.lineEnd(t.cursor);
            t.remove(t.cursor, if (end == t.cursor and end < t.buf.items.len) end + 1 else end);
        } else if (t.multiline and k.matches(K.enter, .{})) {
            try t.insert(gpa, "\n");
        } else if (k.text) |s| {
            if (k.mods.ctrl or k.mods.super) return .ignored;
            try t.insert(gpa, s);
        } else return .ignored;
        t.follow = true;
        return .handled;
    }

    /// A key from a bracketed paste, which is text: Tab, Enter and a line
    /// feed (vaxis reads 0x0a as ctrl+j) are inserted, other control keys
    /// dropped. A single-line box turns them into spaces.
    pub fn pasteKey(t: *TextArea, gpa: Allocator, k: vaxis.Key) Allocator.Error!void {
        const K = vaxis.Key;
        const value: []const u8 = if (k.matches(K.tab, .{}))
            "\t"
        else if (k.matches(K.enter, .{}) or k.matches('j', .{ .ctrl = true }))
            "\n"
        else if (k.mods.ctrl or k.mods.alt or k.mods.super)
            return
        else
            k.text orelse return;
        try t.insert(gpa, value);
        t.follow = true;
    }

    /// Puts the cursor at a cell of the area last drawn.
    pub fn click(t: *TextArea, arena: Allocator, row: u16, col: u16) Allocator.Error!void {
        const rows = try layout(arena, t.buf.items, t.cols);
        const r = @min(t.scroll + row, rows.len - 1);
        t.cursor = posAt(t.buf.items, rows[r], col);
        t.follow = true;
    }

    pub fn scrollBy(t: *TextArea, arena: Allocator, delta: i32) Allocator.Error!void {
        const rows = try layout(arena, t.buf.items, t.cols);
        const max: i64 = @intCast(rows.len -| 1);
        t.scroll = @intCast(std.math.clamp(@as(i64, t.scroll) + delta, 0, max));
        t.follow = false;
    }

    /// Draws into `win`, scrolled so the cursor shows, and places the
    /// terminal cursor when `focused`. `placeholder` shows when empty.
    pub fn draw(
        t: *TextArea,
        arena: Allocator,
        win: vaxis.Window,
        style: vaxis.Style,
        focused: bool,
        placeholder: []const u8,
    ) Allocator.Error!void {
        if (win.width == 0 or win.height == 0) return;
        win.fill(.{ .style = style });
        // Single-line boxes scroll sideways instead of wrapping.
        if (!t.multiline) return t.drawLine(win, style, focused, placeholder);
        t.cols = win.width -| 1;
        const s = t.buf.items;
        const rows = try layout(arena, s, t.cols);
        const cur = rowOf(rows, t.cursor);
        if (t.follow) {
            if (cur < t.scroll) t.scroll = cur;
            if (cur >= t.scroll + win.height) t.scroll = cur - win.height + 1;
        }
        if (t.scroll >= rows.len) t.scroll = @intCast(rows.len - 1);
        if (s.len == 0) {
            _ = win.printSegment(.{ .text = placeholder, .style = dimmed(style) }, .{ .wrap = .word });
        }
        var y: u16 = 0;
        while (y < win.height and t.scroll + y < rows.len) : (y += 1) {
            const r = rows[t.scroll + y];
            _ = win.printSegment(.{ .text = expandTabs(arena, s[r.start..r.end]), .style = style }, .{
                .row_offset = y,
                .wrap = .none,
            });
        }
        if (focused and cur >= t.scroll and cur - t.scroll < win.height) {
            win.showCursor(colOf(s, rows[cur], t.cursor), @intCast(cur - t.scroll));
        }
    }

    fn drawLine(t: *TextArea, win: vaxis.Window, style: vaxis.Style, focused: bool, placeholder: []const u8) void {
        const s = t.buf.items;
        const row: Row = .{ .start = 0, .end = @intCast(s.len), .soft = false };
        const visible = win.width -| 1;
        t.cols = win.width;
        const col = colOf(s, row, t.cursor);
        // `scroll` is the first column shown.
        if (col < t.scroll) t.scroll = col;
        if (col > t.scroll + visible) t.scroll = col - visible;
        if (s.len == 0) {
            _ = win.printSegment(.{ .text = placeholder, .style = dimmed(style) }, .{ .wrap = .none });
        }
        const from = posAt(s, row, @intCast(t.scroll));
        _ = win.printSegment(.{ .text = s[from..], .style = style }, .{ .wrap = .none });
        if (focused) win.showCursor(col - @as(u16, @intCast(t.scroll)), 0);
    }

    /// For single-line boxes, where `click` doesn't apply.
    pub fn clickLine(t: *TextArea, col: u16) void {
        const s = t.buf.items;
        const row: Row = .{ .start = 0, .end = @intCast(s.len), .soft = false };
        t.cursor = posAt(s, row, @as(u32, col) + t.scroll);
    }
};

fn dimmed(style: vaxis.Style) vaxis.Style {
    var s = style;
    s.dim = true;
    s.italic = true;
    return s;
}

const testing = std.testing;

test layout {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try layout(arena, "hello world foo\nbar", 11);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("hello ", "hello world foo\nbar"[rows[0].start..rows[0].end]);
    try testing.expect(rows[0].soft);
    try testing.expectEqualStrings("world foo", "hello world foo\nbar"[rows[1].start..rows[1].end]);
    try testing.expect(!rows[1].soft);
    try testing.expectEqual(@as(u32, 16), rows[2].start);

    // No space: cut mid-word. Empty text: one row.
    const long = try layout(arena, "abcdefgh", 3);
    try testing.expectEqual(@as(usize, 3), long.len);
    try testing.expectEqual(@as(usize, 1), (try layout(arena, "", 10)).len);
    // A trailing newline makes an empty last row.
    try testing.expectEqual(@as(usize, 2), (try layout(arena, "a\n", 10)).len);
}

test "TextArea editing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = testing.allocator;
    const K = vaxis.Key;

    var t: TextArea = .init(true);
    defer t.deinit(gpa);
    t.cols = 80;
    try t.set(gpa, "héllo");
    try testing.expectEqual(@as(u32, 6), t.cursor);
    _ = try t.key(gpa, arena, .{ .codepoint = K.left });
    _ = try t.key(gpa, arena, .{ .codepoint = K.left });
    _ = try t.key(gpa, arena, .{ .codepoint = K.backspace });
    try testing.expectEqualStrings("hélo", t.text());
    _ = try t.key(gpa, arena, .{ .codepoint = K.backspace });
    try testing.expectEqualStrings("hlo", t.text());
    _ = try t.key(gpa, arena, .{ .codepoint = K.enter });
    _ = try t.key(gpa, arena, .{ .codepoint = 'x', .text = "x" });
    try testing.expectEqualStrings("h\nxlo", t.text());
    _ = try t.key(gpa, arena, .{ .codepoint = K.up });
    try testing.expectEqual(@as(u32, 1), t.cursor);
    _ = try t.key(gpa, arena, .{ .codepoint = 'w', .mods = .{ .ctrl = true } });
    try testing.expectEqualStrings("\nxlo", t.text());
    try testing.expectEqual(TextArea.Outcome.ignored, try t.key(gpa, arena, .{ .codepoint = K.escape }));

    var line: TextArea = .init(false);
    defer line.deinit(gpa);
    try line.set(gpa, "a\nb");
    try testing.expectEqualStrings("a b", line.text());
    try testing.expectEqual(TextArea.Outcome.ignored, try line.key(gpa, arena, .{ .codepoint = K.enter }));
}

test "an emoji with a skin tone or joined ones is one cluster, as drawn" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = testing.allocator;
    const K = vaxis.Key;
    const thumb = "👍🏽";
    const family = "👨\u{200d}👩\u{200d}👧";
    const accent = "e\u{301}";
    try testing.expectEqual(@as(u32, thumb.len), clusterLen(thumb, 0));
    try testing.expectEqual(@as(u32, family.len), clusterLen(family, 0));
    try testing.expectEqual(@as(u32, accent.len), clusterLen(accent, 0));
    try testing.expectEqual(@as(u32, 1), clusterLen("ab", 0));
    try testing.expectEqual(@as(u32, 1), clusterLen("\n\n", 0));

    const text = "a" ++ thumb ++ family ++ "b";
    const row: Row = .{ .start = 0, .end = text.len, .soft = false };
    const w_thumb = width(thumb);
    const w_family = width(family);
    try testing.expectEqual(@as(u16, 1 + w_thumb + w_family + 1), colOf(text, row, text.len));
    try testing.expectEqual(@as(u32, 1 + thumb.len), posAt(text, row, 1 + w_thumb));

    var t: TextArea = .init(true);
    defer t.deinit(gpa);
    t.cols = 80;
    try t.set(gpa, text);
    _ = try t.key(gpa, arena, .{ .codepoint = K.left });
    _ = try t.key(gpa, arena, .{ .codepoint = K.left });
    try testing.expectEqual(@as(u32, 1 + thumb.len), t.cursor);
    _ = try t.key(gpa, arena, .{ .codepoint = K.backspace });
    try testing.expectEqualStrings("a" ++ family ++ "b", t.text());
    _ = try t.key(gpa, arena, .{ .codepoint = K.delete });
    try testing.expectEqualStrings("ab", t.text());
}

test "a click far into a long line doesn't overflow" {
    const gpa = testing.allocator;
    var t: TextArea = .init(false);
    defer t.deinit(gpa);
    const long = try gpa.alloc(u8, 70_000);
    defer gpa.free(long);
    @memset(long, 'x');
    try t.set(gpa, long);
    t.scroll = 69_000;
    t.clickLine(std.math.maxInt(u16));
    try testing.expectEqual(@as(u32, @intCast(long.len)), t.cursor);
}

test "text past max_rows: the cursor stays usable" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = testing.allocator;
    const K = vaxis.Key;

    const big = try arena.alloc(u8, max_rows + 100);
    @memset(big, '\n');
    var t: TextArea = .init(true);
    defer t.deinit(gpa);
    t.cols = 40;
    try t.set(gpa, big);
    try testing.expectEqual(@as(u32, @intCast(big.len)), t.cursor);
    // Up from beyond the last row lands on the row above it; down twice
    // goes back to the end.
    _ = try t.key(gpa, arena, .{ .codepoint = K.up });
    try testing.expectEqual(@as(u32, max_rows - 2), t.cursor);
    _ = try t.key(gpa, arena, .{ .codepoint = K.down });
    _ = try t.key(gpa, arena, .{ .codepoint = K.down });
    try testing.expectEqual(@as(u32, @intCast(big.len)), t.cursor);

    // Set again with the cursor far along: it starts over.
    try t.set(gpa, "ab");
    try testing.expectEqualStrings("ab", t.text());
}

test "tabs are drawn as spaces and counted so" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("    x", expandTabs(arena, "\tx"));
    const rows = try layout(arena, "\tx", 40);
    try testing.expectEqual(@as(u16, 5), colOf("\tx", rows[0], 2));
}

test "page keys move ten rows; a cut paste stays valid UTF-8" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = testing.allocator;
    const K = vaxis.Key;

    var t: TextArea = .init(true);
    defer t.deinit(gpa);
    t.cols = 40;
    try t.set(gpa, "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12");
    t.cursor = 0;
    _ = try t.key(gpa, arena, .{ .codepoint = K.page_down });
    try testing.expectEqual(@as(u32, 20), t.cursor); // the start of "10"
    _ = try t.key(gpa, arena, .{ .codepoint = K.page_down });
    try testing.expectEqual(@as(u32, @intCast(t.text().len)), t.cursor);
    t.cursor = 6; // "3"
    _ = try t.key(gpa, arena, .{ .codepoint = K.page_up });
    try testing.expectEqual(@as(u32, 0), t.cursor);

    const full = try arena.alloc(u8, TextArea.max_bytes - 1);
    @memset(full, 'a');
    try t.set(gpa, full);
    try t.insert(gpa, "é");
    try testing.expectEqual(TextArea.max_bytes - 1, t.text().len);
}

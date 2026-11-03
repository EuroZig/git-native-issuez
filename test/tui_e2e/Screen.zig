//! Just enough of a terminal to read what a TUI shows: the cursor moves,
//! erases, printing and wrapping its output uses, and answers to the
//! queries it waits for at start (primary device attributes, the cursor
//! position). Colours, modes and titles are read and dropped.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const Screen = @This();

rows: u16,
cols: u16,
/// Row by row. A wide character's second cell is `wide_tail`.
cells: []u21,
row: u16 = 0,
col: u16 = 0,
/// The last column was written: the next character goes to the next row.
pending_wrap: bool = false,
state: State = .ground,
/// Parameter and intermediate bytes of the CSI sequence being read.
csi: [64]u8 = undefined,
csi_len: u8 = 0,
utf8: [4]u8 = undefined,
utf8_len: u3 = 0,
utf8_want: u3 = 0,
/// What the terminal answers, for the caller to send to the program.
replies: std.ArrayList(u8) = .empty,
gpa: Allocator,

const wide_tail: u21 = 0;

const State = enum {
    ground,
    esc,
    /// ESC with an intermediate byte, as in ESC ( B: one more byte.
    esc_intermediate,
    csi,
    /// OSC: to BEL or ST.
    osc,
    /// DCS, APC, PM, SOS: to ST.
    string,
    /// ESC inside a string: ST if a backslash follows.
    string_esc,
};

pub fn init(gpa: Allocator, rows: u16, cols: u16) !Screen {
    const cells = try gpa.alloc(u21, @as(usize, rows) * cols);
    @memset(cells, ' ');
    return .{ .rows = rows, .cols = cols, .cells = cells, .gpa = gpa };
}

pub fn deinit(s: *Screen) void {
    s.gpa.free(s.cells);
    s.replies.deinit(s.gpa);
    s.* = undefined;
}

/// The program's output.
pub fn feed(s: *Screen, bytes: []const u8) Allocator.Error!void {
    for (bytes) |b| try s.byte(b);
}

fn byte(s: *Screen, b: u8) Allocator.Error!void {
    switch (s.state) {
        .ground => s.ground(b),
        .esc => switch (b) {
            '[' => {
                s.csi_len = 0;
                s.state = .csi;
            },
            ']' => s.state = .osc,
            'P', '_', '^', 'X' => s.state = .string,
            0x20...0x2F => s.state = .esc_intermediate,
            else => s.state = .ground,
        },
        .esc_intermediate => s.state = .ground,
        .csi => switch (b) {
            0x20...0x3F => {
                if (s.csi_len < s.csi.len) {
                    s.csi[s.csi_len] = b;
                    s.csi_len += 1;
                }
            },
            0x40...0x7E => {
                s.state = .ground;
                try s.dispatch(b);
            },
            0x1B => s.state = .esc,
            else => s.state = .ground,
        },
        .osc => switch (b) {
            0x07 => s.state = .ground,
            0x1B => s.state = .string_esc,
            else => {},
        },
        .string => if (b == 0x1B) {
            s.state = .string_esc;
        },
        .string_esc => s.state = if (b == '\\') .ground else .string,
    }
}

fn ground(s: *Screen, b: u8) void {
    if (s.utf8_want > 0) {
        if (b & 0xC0 == 0x80) {
            s.utf8[s.utf8_len] = b;
            s.utf8_len += 1;
            if (s.utf8_len == s.utf8_want) {
                s.utf8_want = 0;
                const cp = std.unicode.utf8Decode(s.utf8[0..s.utf8_len]) catch 0xFFFD;
                s.print(cp, s.utf8[0..s.utf8_len]);
            }
            return;
        }
        s.utf8_want = 0;
        s.print(0xFFFD, "\u{FFFD}");
    }
    switch (b) {
        0x1B => s.state = .esc,
        '\r' => s.carriageReturn(),
        '\n', 0x0B, 0x0C => s.lineFeed(),
        0x08 => {
            s.col -|= 1;
            s.pending_wrap = false;
        },
        '\t' => {
            s.col = @min(s.cols - 1, (s.col / 8 + 1) * 8);
            s.pending_wrap = false;
        },
        0x00...0x07, 0x0E...0x1A, 0x1C...0x1F, 0x7F => {},
        0x20...0x7E => s.print(b, &.{b}),
        else => {
            const len = std.unicode.utf8ByteSequenceLength(b) catch {
                s.print(0xFFFD, "\u{FFFD}");
                return;
            };
            s.utf8[0] = b;
            s.utf8_len = 1;
            s.utf8_want = @intCast(len);
        },
    }
}

fn at(s: *Screen, row: u16, col: u16) *u21 {
    assert(row < s.rows and col < s.cols);
    return &s.cells[@as(usize, row) * s.cols + col];
}

fn print(s: *Screen, cp: u21, bytes: []const u8) void {
    const width = vaxis.gwidth.gwidth(bytes, .wcwidth);
    // Combining marks join the cell before.
    if (width == 0) return;
    if (s.pending_wrap or s.col + width > s.cols) {
        s.carriageReturn();
        s.lineFeed();
    }
    s.at(s.row, s.col).* = cp;
    if (width == 2 and s.col + 1 < s.cols) s.at(s.row, s.col + 1).* = wide_tail;
    const next = s.col + width;
    if (next >= s.cols) {
        s.col = s.cols - 1;
        s.pending_wrap = true;
    } else s.col = @intCast(next);
}

fn carriageReturn(s: *Screen) void {
    s.col = 0;
    s.pending_wrap = false;
}

fn lineFeed(s: *Screen) void {
    s.pending_wrap = false;
    if (s.row + 1 < s.rows) {
        s.row += 1;
        return;
    }
    // Scroll up one row.
    const cols: usize = s.cols;
    std.mem.copyForwards(u21, s.cells[0 .. s.cells.len - cols], s.cells[cols..]);
    @memset(s.cells[s.cells.len - cols ..], ' ');
}

/// The CSI sequence just read, ending in `final`.
fn dispatch(s: *Screen, final: u8) Allocator.Error!void {
    var raw = s.csi[0..s.csi_len];
    var private: u8 = 0;
    if (raw.len > 0 and raw[0] >= 0x3C and raw[0] <= 0x3F) {
        private = raw[0];
        raw = raw[1..];
    }
    // Intermediates (DECRQM's `$`, ...): nothing this terminal does.
    for (raw) |b| if (b < 0x30) return;
    var params: [16]u16 = @splat(0);
    var count: usize = 0;
    var it = std.mem.splitAny(u8, raw, ";:");
    while (it.next()) |p| : (count += 1) {
        if (count == params.len) break;
        params[count] = std.fmt.parseInt(u16, p, 10) catch 0;
    }
    // A missing or zero count is one.
    const n: u16 = @max(params[0], 1);
    if (private != 0) return;
    switch (final) {
        'c' => try s.replies.appendSlice(s.gpa, "\x1b[?62;22c"),
        'n' => if (params[0] == 6) {
            try s.replies.print(s.gpa, "\x1b[{d};{d}R", .{ s.row + 1, s.col + 1 });
        },
        'H', 'f' => s.moveTo(@max(params[0], 1) - 1, @max(params[1], 1) - 1),
        'A' => s.moveTo(s.row -| n, s.col),
        'B' => s.moveTo(s.row +| n, s.col),
        'C' => s.moveTo(s.row, s.col +| n),
        'D' => s.moveTo(s.row, s.col -| n),
        'E' => s.moveTo(s.row +| n, 0),
        'F' => s.moveTo(s.row -| n, 0),
        'G', '`' => s.moveTo(s.row, n - 1),
        'd' => s.moveTo(n - 1, s.col),
        'J' => switch (params[0]) {
            0 => {
                s.eraseRow(s.row, s.col, s.cols);
                for (s.row + 1..s.rows) |r| s.eraseRow(@intCast(r), 0, s.cols);
            },
            1 => {
                for (0..s.row) |r| s.eraseRow(@intCast(r), 0, s.cols);
                s.eraseRow(s.row, 0, s.col + 1);
            },
            else => @memset(s.cells, ' '),
        },
        'K' => switch (params[0]) {
            0 => s.eraseRow(s.row, s.col, s.cols),
            1 => s.eraseRow(s.row, 0, s.col + 1),
            else => s.eraseRow(s.row, 0, s.cols),
        },
        'X' => s.eraseRow(s.row, s.col, @min(s.cols, s.col +| n)),
        else => {},
    }
}

fn moveTo(s: *Screen, row: u16, col: u16) void {
    s.row = @min(row, s.rows - 1);
    s.col = @min(col, s.cols - 1);
    s.pending_wrap = false;
}

fn eraseRow(s: *Screen, row: u16, from: u16, to: u16) void {
    for (from..@min(to, s.cols)) |c| s.at(row, @intCast(c)).* = ' ';
}

/// One row's text, without trailing spaces.
pub fn line(s: *const Screen, buf: []u8, row: u16) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (s.cells[@as(usize, row) * s.cols ..][0..s.cols]) |cp| {
        if (cp == wide_tail) continue;
        var tmp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &tmp) catch continue;
        w.writeAll(tmp[0..len]) catch break;
    }
    return std.mem.trimEnd(u8, w.buffered(), " ");
}

/// The whole screen, row by row.
pub fn text(s: *const Screen, gpa: Allocator) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    for (0..s.rows) |r| {
        try out.appendSlice(gpa, s.line(&buf, @intCast(r)));
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

pub fn contains(s: *const Screen, needle: []const u8) bool {
    var buf: [4096]u8 = undefined;
    for (0..s.rows) |r| {
        if (std.mem.find(u8, s.line(&buf, @intCast(r)), needle) != null) return true;
    }
    return false;
}

const testing = std.testing;

test "prints, moves, erases, wraps and answers" {
    var s = try Screen.init(testing.allocator, 3, 10);
    defer s.deinit();
    try s.feed("\x1b[?1049h\x1b]0;title\x07\x1b[1;31mhello\x1b[0m\x1b[2;3Hwörld\x1b[3;1H→ x");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("hello", s.line(&buf, 0));
    try testing.expectEqualStrings("  wörld", s.line(&buf, 1));
    try testing.expectEqualStrings("→ x", s.line(&buf, 2));
    try s.feed("\x1b[2;5H\x1b[K\x1b[1;2H\x1b[2X");
    try testing.expectEqualStrings("h  lo", s.line(&buf, 0));
    try testing.expectEqualStrings("  wö", s.line(&buf, 1));
    try testing.expect(s.contains("→ x"));

    try s.feed("\x1b[c\x1b[?u\x1b[?2026$p\x1b[2;4H\x1b[6n\x1bP>|x\x1b\\");
    try testing.expectEqualStrings("\x1b[?62;22c\x1b[2;4R", s.replies.items);

    try s.feed("\x1b[2J\x1b[3;9Habcd");
    try testing.expectEqualStrings("        ab", s.line(&buf, 1));
    try testing.expectEqualStrings("cd", s.line(&buf, 2));
}

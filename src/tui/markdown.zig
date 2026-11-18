//! Descriptions and comments as Markdown in the detail view: markdown-term's
//! blocks, wrapped with the widths vaxis draws and painted in the palette.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const issuez = @import("issuez");
const term = @import("markdown-term");

const ui = @import("ui.zig");
const text_mod = @import("text.zig");

const palette = ui.palette;

/// A text's blocks, measured for one width.
pub const Doc = struct {
    blocks: []const term.Block,
    layouts: []const term.BlockLayout,
    /// The row each block starts on, after its gap.
    starts: []const usize,
    /// Rows, gaps included.
    height: usize,
};

/// `text` rendered `width` columns wide, allocated in `arena` (one frame's);
/// null when it is larger than git issue writes, to show it as it is.
pub fn layout(
    arena: Allocator,
    text: []const u8,
    width: u16,
    measure: term.Measure,
) Allocator.Error!?Doc {
    if (text.len > (issuez.Limits{}).max_body_bytes) return null;
    const nodes = try term.markdown.parse(arena, text_mod.expandTabs(arena, text), .{});
    const doc = try term.build(arena, nodes);
    const layouts = try arena.alloc(term.BlockLayout, doc.blocks.len);
    const starts = try arena.alloc(usize, doc.blocks.len);
    var row: usize = 0;
    for (doc.blocks, layouts, starts, 0..) |block, *l, *start, n| {
        if (n > 0) row += block.gap_before;
        const options: term.LayoutOptions = .{ .width = @max(width, 1), .measure = measure };
        l.* = try term.layoutBlock(arena, block, options);
        start.* = row;
        row += l.height;
    }
    return .{ .blocks = doc.blocks, .layouts = layouts, .starts = starts, .height = row };
}

/// Paints `doc` from its row `from` on into `win`, which is as wide as the
/// width it was measured for.
pub fn paint(win: ui.Window, doc: Doc, from: usize, measure: term.Measure) void {
    const region: term.Region = .{
        .surface = .{ .context = @constCast(&win), .writeCellFn = writeCell },
        .width = win.width,
        .height = win.height,
    };
    for (doc.blocks, doc.layouts, doc.starts) |block, l, start| {
        const end = start + l.height;
        if (end <= from) continue;
        if (start >= from + win.height) break;
        const skipped = from -| start;
        const y: u16 = @intCast(start -| from);
        const height: u16 = @intCast(@min(l.height - skipped, win.height - y));
        term.paintBlock(
            region.child(.{ .y_off = y, .height = height }),
            block,
            l,
            skipped,
            measure,
        );
    }
}

/// Measures with the width method vaxis detected, so wrapping matches what
/// it draws. `win` must outlive the measure.
pub fn measureOf(win: *const ui.Window) term.Measure {
    return .{ .context = &win.screen.width_method, .widthFn = measureWidth };
}

fn measureWidth(context: ?*const anyopaque, grapheme: []const u8) u16 {
    const method: *const vaxis.gwidth.Method = @ptrCast(@alignCast(context.?));
    return vaxis.gwidth.gwidth(grapheme, method.*);
}

fn writeCell(context: *anyopaque, col: u16, row: u16, cell: term.Cell) void {
    const win: *const ui.Window = @ptrCast(@alignCast(context));
    win.writeCell(col, row, .{
        .char = .{ .grapheme = cell.grapheme, .width = cell.width },
        .style = styleOf(cell.style),
        .link = if (cell.link) |uri| .{ .uri = uri } else .{},
        .wrapped = cell.wrapped,
    });
}

fn styleOf(style: term.Style) ui.Style {
    return .{
        .fg = fgOf(style.fg),
        .bg = bgOf(style.bg),
        .ul_style = if (style.underline) .single else .off,
        .bold = style.bold,
        .dim = style.dim,
        .italic = style.italic,
        .reverse = style.reverse,
        .strikethrough = style.strikethrough,
    };
}

/// markdown-term's ANSI colors as the palette's.
fn fgOf(color: term.Color) vaxis.Color {
    return switch (color) {
        .default => .default,
        .rgb => |rgb| .{ .rgb = rgb },
        .index => |n| switch (n) {
            // Code.
            2 => palette.ok,
            // Level 4 headings, alerts.
            3 => palette.medium,
            // Links, and markers and quote bars.
            4, 6 => palette.accent,
            // Emoji shortcodes.
            5 => palette.done,
            // Table borders.
            8 => palette.faint,
            // On a heading's or a table header's bar.
            15 => .default,
            else => .{ .index = n },
        },
    };
}

fn bgOf(color: term.Color) vaxis.Color {
    return switch (color) {
        .default => .default,
        .rgb => |rgb| .{ .rgb = rgb },
        .index => |n| switch (n) {
            // Code blocks and spans, striped table rows.
            0 => palette.panel_bg,
            // Headings and table headers.
            4, 5 => palette.accent_bg,
            else => .{ .index = n },
        },
    };
}

test "layout: any bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(0x6d64);
    const alphabet = "#*_`[]()!>-+|:~=\\ \n\tab1.\xc3\xa4\xff";
    var buf: [256]u8 = undefined;
    for (0..2000) |_| {
        const len = prng.random().uintAtMost(usize, buf.len);
        for (buf[0..len]) |*c| c.* = alphabet[prng.random().uintLessThan(usize, alphabet.len)];
        _ = try layout(arena.allocator(), buf[0..len], 20, .unicode);
    }
}

test "layout: larger than git issue writes is shown as it is" {
    const text = try std.testing.allocator.alloc(u8, (issuez.Limits{}).max_body_bytes + 1);
    defer std.testing.allocator.free(text);
    @memset(text, '*');
    try std.testing.expectEqual(null, try layout(std.testing.allocator, text, 20, .unicode));
}

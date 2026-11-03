//! Drawing helpers, colors, and the hit map that makes everything
//! clickable: whatever a frame draws as clickable is recorded with what a
//! click on it means, and mouse events are looked up there.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const filter = @import("filter.zig");

pub const Window = vaxis.Window;
pub const Style = vaxis.Style;

pub const View = enum { list, board, detail };

/// What a click means. One union for every view, so the hit map is shared.
pub const Target = union(enum) {
    tab: View,
    command: Command,
    scope: filter.Scope,
    tree,
    sort: filter.SortKey,
    sort_reverse,
    search,
    /// A list row, by position in the rows.
    row: u32,
    card: Card,
    /// A board column's body, for drops and scrolling.
    column: u16,
    /// A detail view item, by position in its items.
    item: u16,
    /// Modals.
    modal: ModalTarget,
    /// Anywhere outside the open modal.
    backdrop,

    pub const Card = struct { column: u16, index: u32 };

    pub fn eql(a: Target, b: Target) bool {
        return std.meta.eql(a, b);
    }
};

pub const Command = enum { new_issue, reload, help, sort, quit, back };

pub const ModalTarget = union(enum) {
    ok,
    cancel,
    /// A menu entry.
    choice: u16,
    /// A form field, to focus it.
    field: u8,
    /// One of a form field's options.
    option: struct { field: u8, option: u8 },
};

pub const Hit = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    target: Target,
};

/// Rebuilt by every frame, drawn order: later hits are on top.
pub const Hits = struct {
    items: std.ArrayList(Hit) = .empty,
    /// Hits before this are under the open modal and don't take clicks.
    barrier: usize = 0,

    pub const max = 4096;

    pub fn deinit(h: *Hits, gpa: Allocator) void {
        h.items.deinit(gpa);
    }

    pub fn reset(h: *Hits) void {
        h.items.clearRetainingCapacity();
        h.barrier = 0;
    }

    /// The whole of `win`. Off-screen and empty windows take no clicks.
    pub fn add(h: *Hits, gpa: Allocator, win: Window, target: Target) Allocator.Error!void {
        if (win.width == 0 or win.height == 0) return;
        if (win.x_off < 0 or win.y_off < 0) return;
        if (h.items.items.len >= max) return;
        try h.items.append(gpa, .{
            .x = @intCast(win.x_off),
            .y = @intCast(win.y_off),
            .w = win.width,
            .h = win.height,
            .target = target,
        });
    }

    /// From here on, only hits added later take clicks.
    pub fn modal(h: *Hits) void {
        h.barrier = h.items.items.len;
    }

    pub const Found = struct { target: Target, x: u16, y: u16 };

    /// The topmost hit at a cell, and the cell relative to it.
    pub fn find(h: *const Hits, col: i16, row: i16) ?Found {
        if (col < 0 or row < 0) return null;
        const x: u16 = @intCast(col);
        const y: u16 = @intCast(row);
        var i = h.items.items.len;
        while (i > h.barrier) {
            i -= 1;
            const hit = h.items.items[i];
            if (x >= hit.x and x < hit.x + hit.w and y >= hit.y and y < hit.y + hit.h) {
                return .{ .target = hit.target, .x = x - hit.x, .y = y - hit.y };
            }
        }
        return if (h.barrier > 0) .{ .target = .backdrop, .x = x, .y = y } else null;
    }
};

/// What drawing needs besides the window.
pub const Frame = struct {
    gpa: Allocator,
    /// Lives until the frame is rendered: cells point into it.
    arena: Allocator,
    hits: *Hits,
    /// Unix seconds, for relative times.
    now: i64,

    pub fn hit(f: Frame, win: Window, target: Target) Allocator.Error!void {
        return f.hits.add(f.gpa, win, target);
    }

    pub fn fmt(f: Frame, comptime format: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(f.arena, format, args) catch "…";
    }
};

// Colors from the 256-color palette, which terminals without truecolor
// still have.
pub const palette = struct {
    pub const accent: vaxis.Color = .{ .index = 75 };
    pub const accent_bg: vaxis.Color = .{ .index = 24 };
    pub const bar_bg: vaxis.Color = .{ .index = 236 };
    pub const panel_bg: vaxis.Color = .{ .index = 235 };
    pub const input_bg: vaxis.Color = .{ .index = 238 };
    pub const select_bg: vaxis.Color = .{ .index = 237 };
    pub const hover_bg: vaxis.Color = .{ .index = 239 };
    pub const button_bg: vaxis.Color = .{ .index = 240 };
    pub const muted: vaxis.Color = .{ .index = 245 };
    pub const faint: vaxis.Color = .{ .index = 241 };
    pub const open: vaxis.Color = .{ .index = 114 };
    pub const done: vaxis.Color = .{ .index = 140 };
    pub const err: vaxis.Color = .{ .index = 203 };
    pub const ok: vaxis.Color = .{ .index = 114 };
    pub const critical: vaxis.Color = .{ .index = 196 };
    pub const high: vaxis.Color = .{ .index = 208 };
    pub const medium: vaxis.Color = .{ .index = 220 };
    pub const low: vaxis.Color = .{ .index = 110 };
    pub const label: vaxis.Color = .{ .index = 180 };
    pub const id: vaxis.Color = .{ .index = 109 };
};

pub fn priorityColor(p: ?[]const u8) vaxis.Color {
    const v = p orelse return palette.faint;
    if (std.mem.eql(u8, v, "critical")) return palette.critical;
    if (std.mem.eql(u8, v, "high")) return palette.high;
    if (std.mem.eql(u8, v, "medium")) return palette.medium;
    if (std.mem.eql(u8, v, "low")) return palette.low;
    return palette.muted;
}

/// Prints one line at a cell, clipped to the window, with `…` when cut.
/// Returns the columns used.
pub fn text(win: Window, col: u16, row: u16, s: []const u8, style: Style) u16 {
    if (col >= win.width or row >= win.height or s.len == 0) return 0;
    const res = win.printSegment(.{ .text = s, .style = style }, .{
        .row_offset = row,
        .col_offset = col,
        .wrap = .none,
    });
    if (res.overflow and win.width > 0) {
        win.writeCell(win.width - 1, row, .{ .char = .{ .grapheme = "…", .width = 1 }, .style = style });
        return win.width - col;
    }
    return res.col -| col;
}

/// `text`, then a gap of one column.
pub fn word(win: Window, col: *u16, row: u16, s: []const u8, style: Style) void {
    col.* += text(win, col.*, row, s, style);
    col.* += 1;
}

/// Paints a row's background.
pub fn fillRow(win: Window, row: u16, style: Style) void {
    if (row >= win.height) return;
    win.child(.{ .y_off = row, .height = 1 }).fill(.{ .style = style });
}

/// ` label ` on a button background, clickable. Returns its width.
pub fn button(f: Frame, win: Window, col: u16, row: u16, label: []const u8, target: Target, style: Style) Allocator.Error!u16 {
    if (col >= win.width or row >= win.height) return 0;
    const w: u16 = @intCast(@min(win.gwidth(label) + 2, win.width - col));
    const b = win.child(.{ .x_off = col, .y_off = row, .width = w, .height = 1 });
    b.fill(.{ .style = style });
    _ = text(b, 1, 0, label, style);
    try f.hit(b, target);
    return w;
}

pub fn buttonStyle(active: bool) Style {
    return if (active)
        .{ .fg = .{ .index = 231 }, .bg = palette.accent_bg, .bold = true }
    else
        .{ .fg = .{ .index = 252 }, .bg = palette.button_bg };
}

/// A box with a title in its top border; returns the inside.
pub fn panel(win: Window, title: []const u8, style: Style) Window {
    win.fill(.{ .style = style });
    const inner = win.child(.{
        .border = .{ .where = .all, .style = .{ .fg = palette.accent, .bg = style.bg } },
    });
    if (title.len > 0 and win.width > 4) {
        _ = text(win, 2, 0, title, .{ .fg = palette.accent, .bg = style.bg, .bold = true });
    }
    return inner;
}

/// A centered child of at most `w` by `h`.
pub fn centered(win: Window, w: u16, h: u16) Window {
    const cw = @min(w, win.width);
    const ch = @min(h, win.height);
    return win.child(.{
        .x_off = @intCast((win.width - cw) / 2),
        .y_off = @intCast((win.height - ch) / 2),
        .width = cw,
        .height = ch,
    });
}

/// "5m", "3h", "2d", "4w", or the date for older times.
pub fn ago(f: Frame, t: i64) []const u8 {
    const d = f.now - t;
    if (d < 60) return "now";
    if (d < 3600) return f.fmt("{d}m", .{@divFloor(d, 60)});
    if (d < 86400) return f.fmt("{d}h", .{@divFloor(d, 3600)});
    if (d < 86400 * 14) return f.fmt("{d}d", .{@divFloor(d, 86400)});
    if (d < 86400 * 60) return f.fmt("{d}w", .{@divFloor(d, 86400 * 7)});
    return date(f, t);
}

/// `YYYY-MM-DD`, in UTC.
pub fn date(f: Frame, t: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(t, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return f.fmt("{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 });
}

/// "1h30m", like `git issue` writes estimates.
pub fn duration(f: Frame, minutes: u32) []const u8 {
    const h = minutes / 60;
    const m = minutes % 60;
    if (h == 0) return f.fmt("{d}m", .{m});
    if (m == 0) return f.fmt("{d}h", .{h});
    return f.fmt("{d}h{d}m", .{ h, m });
}

test "hits: topmost wins, modal barrier" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 10, .cols = 20, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 20,
        .height = 10,
        .screen = &screen,
    };
    var hits: Hits = .{};
    defer hits.deinit(gpa);
    try hits.add(gpa, win, .{ .row = 0 });
    try hits.add(gpa, win.child(.{ .x_off = 2, .y_off = 3, .width = 4, .height = 1 }), .tree);
    try std.testing.expect(hits.find(3, 3).?.target.eql(.tree));
    try std.testing.expectEqual(@as(u16, 1), hits.find(3, 3).?.x);
    try std.testing.expect(hits.find(0, 0).?.target.eql(.{ .row = 0 }));
    hits.modal();
    try std.testing.expect(hits.find(0, 0).?.target.eql(.backdrop));
}

//! The kanban board: a column per workflow state, and done work last.
//! Cards move with `<` and `>`, or by dragging them to another column.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const issuez = @import("issuez");

const ui = @import("ui.zig");
const filter = @import("filter.zig");
const store = @import("store.zig");
const text_mod = @import("text.zig");
const list_view = @import("list_view.zig");
const AppState = @import("State.zig");

const Id = store.Id;
const Snapshot = store.Snapshot;
const K = vaxis.Key;
const palette = ui.palette;

const max_columns = 64;
const card_height = 4;
const card_gap = 1;
const min_column_width = 26;

pub const State = struct {
    column: u16 = 0,
    index: u32 = 0,
    selected_id: ?Id = null,
    follow: bool = false,
    /// The last frame's.
    columns: []const filter.Column = &.{},
    /// The first card shown, per column.
    scroll: [max_columns]u32 = @splat(0),
    /// The first column shown, when not all fit.
    first: u16 = 0,
    /// Cards that fit in a column.
    visible: u16 = 1,

    pub fn selectedIssue(b: *const State) ?u32 {
        if (b.column >= b.columns.len) return null;
        const cards = b.columns[b.column].cards;
        if (b.index >= cards.len) return null;
        return cards[b.index];
    }

    fn select(b: *State, snap: *const Snapshot, column: i64, index: i64) void {
        if (b.columns.len == 0) return;
        const last_col: i64 = @intCast(b.columns.len - 1);
        b.column = @intCast(std.math.clamp(column, 0, last_col));
        const cards = b.columns[b.column].cards;
        b.index = if (cards.len == 0) 0 else @intCast(std.math.clamp(index, 0, @as(i64, @intCast(cards.len - 1))));
        b.selected_id = if (b.selectedIssue()) |i| Id.of(snap.issues[i].id) else null;
        b.follow = true;
    }
};

pub fn draw(s: *AppState, f: ui.Frame, win: ui.Window) Allocator.Error!void {
    const b = &s.board;
    const snap = s.snap;
    try list_view.drawFilterBar(s, f, win.child(.{ .height = 1 }), false);
    var q = s.currentQuery();
    q.tree = false;
    b.columns = try capped(f.arena, try filter.board(f.arena, snap, q));
    const ncols: u16 = @intCast(b.columns.len);

    // Keep the selection on its card.
    if (b.selected_id) |*id| {
        find: for (b.columns[0..ncols], 0..) |col, c| {
            for (col.cards, 0..) |i, n| {
                if (!id.eql(snap.issues[i].id)) continue;
                b.column = @intCast(c);
                b.index = @intCast(n);
                break :find;
            }
        }
    }
    if (b.column >= ncols) b.column = ncols -| 1;
    const cards_here = b.columns[b.column].cards.len;
    if (b.index >= cards_here) b.index = @intCast(cards_here -| 1);
    if (b.selectedIssue()) |i| b.selected_id = .of(snap.issues[i].id);

    const area = win.child(.{ .y_off = 1, .height = win.height -| 1 });
    const fit: u16 = @max(1, @min(ncols, area.width / min_column_width));
    if (b.column < b.first) b.first = b.column;
    if (b.column >= b.first + fit) b.first = b.column - fit + 1;
    b.first = @min(b.first, ncols -| fit);
    const col_w: u16 = area.width / fit;
    b.visible = @max(1, (area.height -| 2) / (card_height + card_gap));

    var c: u16 = b.first;
    while (c < b.first + fit and c < ncols) : (c += 1) {
        const x: u16 = (c - b.first) * col_w;
        const w = if (c - b.first == fit - 1) area.width - x else col_w;
        const cw = area.child(.{ .x_off = x, .width = w, .height = area.height });
        try drawColumn(s, f, cw, c);
    }
    // More columns than fit.
    if (b.first > 0) _ = ui.text(area, 0, 0, "‹", .{ .fg = palette.accent, .bold = true });
    if (b.first + fit < ncols) _ = ui.text(area, area.width - 1, 0, "›", .{ .fg = palette.accent, .bold = true });
    b.follow = false;
}

/// At most `max_columns`, done work always among them.
fn capped(arena: Allocator, columns: []const filter.Column) Allocator.Error![]const filter.Column {
    if (columns.len <= max_columns) return columns;
    const out = try arena.alloc(filter.Column, max_columns);
    @memcpy(out[0 .. max_columns - 1], columns[0 .. max_columns - 1]);
    out[max_columns - 1] = columns[columns.len - 1];
    return out;
}

/// Whether a card can't go to `col`, saying why in the status line.
fn refused(s: *AppState, col: filter.Column) bool {
    if (col.target) return false;
    s.fail("'{s}' isn't one of the workflow states (git config issue.workflowStates)", .{col.name});
    return true;
}

fn drawColumn(s: *AppState, f: ui.Frame, win: ui.Window, c: u16) Allocator.Error!void {
    const b = &s.board;
    const col = b.columns[c];
    const inner = win.child(.{ .x_off = 1, .width = win.width -| 2 });
    try f.hit(win, .{ .column = c });

    const target = if (s.drag) |d|
        col.target and d.moved and d.over != null and d.over.? == c and d.card.column != c
    else
        false;
    const head_bg: vaxis.Color = if (target) palette.accent_bg else palette.bar_bg;
    const head = inner.child(.{ .height = 1 });
    head.fill(.{ .style = .{ .bg = head_bg } });
    const fg = if (col.done) palette.done else palette.accent;
    var hx = ui.text(head, 1, 0, col.name, .{ .fg = fg, .bg = head_bg, .bold = true });
    hx += 2;
    _ = ui.text(head, hx, 0, f.fmt("{d}", .{col.cards.len}), .{ .fg = palette.muted, .bg = head_bg });
    if (target) _ = ui.text(head, head.width -| 8, 0, "drop ⤓", .{ .fg = .{ .index = 231 }, .bg = head_bg });

    const body = inner.child(.{ .y_off = 2, .height = inner.height -| 2 });
    if (col.done and s.query.scope == .open) {
        _ = ui.text(body, 1, 0, "Done work is hidden.", .{ .fg = palette.muted, .italic = true });
        _ = try ui.button(f, body, 1, 2, "Show all", .{ .scope = .all }, ui.buttonStyle(false));
        return;
    }
    if (col.cards.len == 0) {
        _ = ui.text(body, 1, 0, "No cards", .{ .fg = palette.faint, .italic = true });
        return;
    }
    // Scroll the selected card into view.
    const top = &b.scroll[c];
    if (b.follow and c == b.column) {
        if (b.index < top.*) top.* = b.index;
        if (b.index >= top.* + b.visible) top.* = b.index - b.visible + 1;
    }
    top.* = @min(top.*, @as(u32, @intCast(col.cards.len -| b.visible)));
    var n: u32 = 0;
    while (n < b.visible and top.* + n < col.cards.len) : (n += 1) {
        const index = top.* + n;
        const y: u16 = @intCast(n * (card_height + card_gap));
        const card = body.child(.{ .y_off = y, .height = card_height });
        const selected = c == b.column and index == b.index;
        const dragged = if (s.drag) |d| d.moved and d.card.column == c and d.card.index == index else false;
        try drawCard(s, f, card, col.cards[index], selected, dragged);
        try f.hit(card, .{ .card = .{ .column = c, .index = index } });
    }
    const hidden = col.cards.len - top.* - n;
    if (top.* > 0) _ = ui.text(inner, inner.width -| 4, 1, f.fmt("↑{d}", .{top.*}), .{ .fg = palette.muted });
    if (hidden > 0) _ = ui.text(inner, inner.width -| 4, inner.height -| 1, f.fmt("↓{d}", .{hidden}), .{ .fg = palette.muted });
}

fn drawCard(s: *AppState, f: ui.Frame, win: ui.Window, i: u32, selected: bool, dragged: bool) Allocator.Error!void {
    const snap = s.snap;
    const issue = snap.issues[i];
    const bg: vaxis.Color = if (dragged) palette.hover_bg else if (selected) palette.select_bg else palette.panel_bg;
    win.fill(.{ .style = .{ .bg = bg } });
    const edge: ui.Style = .{ .fg = if (selected) palette.accent else ui.priorityColor(issue.field("Priority")), .bg = bg };
    var y: u16 = 0;
    while (y < win.height) : (y += 1) _ = ui.text(win, 0, y, if (selected) "┃" else "│", edge);
    const inner = win.child(.{ .x_off = 2, .width = win.width -| 3 });

    // ID, priority, progress.
    var x: u16 = 0;
    x += ui.text(inner, x, 0, issuez.format.uuid.shortId(issue.id), .{ .fg = palette.id, .bg = bg });
    x += 1;
    if (issue.field("Priority")) |p| {
        x += ui.text(inner, x, 0, p, .{ .fg = ui.priorityColor(p), .bg = bg });
        x += 1;
    }
    if (snap.proj.activelyBlocked(i)) {
        x += ui.text(inner, x, 0, "blocked", .{ .fg = palette.err, .bg = bg });
        x += 1;
    }
    if (snap.proj.progress(i)) |p| {
        _ = ui.text(inner, x, 0, f.fmt("{d}/{d}", .{ p.closed, p.total }), .{ .fg = palette.muted, .bg = bg });
    }

    // Title, two rows.
    const rows = try text_mod.layout(f.arena, issue.title, inner.width);
    const ts: ui.Style = .{ .bg = bg, .bold = true, .fg = if (snap.isDone(i)) palette.muted else .default };
    for (rows[0..@min(rows.len, 2)], 1..) |r, ry| {
        const line = issue.title[r.start..r.end];
        _ = ui.text(inner, 0, @intCast(ry), line, ts);
    }
    if (rows.len > 2) _ = ui.text(inner, inner.width -| 1, 2, "…", ts);

    // Labels, assignee.
    x = 0;
    for (issue.labels) |l| {
        if (x >= inner.width) break;
        x += ui.text(inner, x, 3, l, .{ .fg = palette.label, .bg = bg });
        x += 1;
    }
    if (issue.ext.assignee) |a| {
        const who = f.fmt("@{s}", .{a.email[0 .. std.mem.findScalar(u8, a.email, '@') orelse a.email.len]});
        const ww = inner.gwidth(who);
        if (x + ww < inner.width) _ = ui.text(inner, inner.width - ww, 3, who, .{ .fg = palette.muted, .bg = bg });
    }
}

pub fn key(s: *AppState, k: vaxis.Key) Allocator.Error!AppState.Action {
    const b = &s.board;
    const snap = s.snap;
    const col: i64 = b.column;
    const idx: i64 = b.index;
    if (k.matches(K.left, .{}) or k.matches('h', .{})) {
        b.select(snap, col - 1, idx);
    } else if (k.matches(K.right, .{}) or k.matches('l', .{})) {
        b.select(snap, col + 1, idx);
    } else if (k.matches(K.down, .{}) or k.matches('j', .{})) {
        b.select(snap, col, idx + 1);
    } else if (k.matches(K.up, .{}) or k.matches('k', .{})) {
        b.select(snap, col, idx - 1);
    } else if (k.matches(K.home, .{}) or k.matches('g', .{})) {
        b.select(snap, col, 0);
    } else if (k.matches(K.end, .{}) or k.matches('G', .{})) {
        b.select(snap, col, std.math.maxInt(i32));
    } else if (k.matches(K.enter, .{})) {
        if (b.selectedIssue()) |i| s.openIssue(snap.issues[i].id);
    } else if (k.matches('<', .{}) or k.matches('H', .{}) or k.matches(K.left, .{ .shift = true })) {
        return move(s, -1);
    } else if (k.matches('>', .{}) or k.matches('L', .{}) or k.matches(K.right, .{ .shift = true })) {
        return move(s, 1);
    } else if (k.matches('a', .{})) {
        if (b.selectedIssue()) |i| s.newIssue(i);
    } else if (k.matches('x', .{})) {
        if (b.selectedIssue()) |i| return s.toggleAction(i);
    }
    return .none;
}

fn move(s: *AppState, delta: i32) AppState.Action {
    const b = &s.board;
    const i = b.selectedIssue() orelse return .none;
    const to: i64 = @as(i64, b.column) + delta;
    if (to < 0 or to >= b.columns.len) return .none;
    const col = b.columns[@intCast(to)];
    if (refused(s, col)) return .none;
    // Follow the card.
    b.column = @intCast(to);
    return .{ .move = .{ .id = .of(s.snap.issues[i].id), .column = col.name, .done = col.done } };
}

pub fn click(s: *AppState, card: ui.Target.Card, double: bool) AppState.Action {
    const b = &s.board;
    if (card.column >= b.columns.len) return .none;
    b.select(s.snap, card.column, card.index);
    const i = b.selectedIssue() orelse return .none;
    if (double) {
        s.openIssue(s.snap.issues[i].id);
        return .none;
    }
    s.drag = .{ .card = card, .id = .of(s.snap.issues[i].id) };
    return .none;
}

pub fn clickColumn(s: *AppState, c: u16) void {
    const b = &s.board;
    if (c >= b.columns.len or c == b.column) return;
    b.select(s.snap, c, b.index);
}

pub fn wheel(s: *AppState, found: ?ui.Hits.Found, delta: i32) void {
    const b = &s.board;
    const c: u16 = if (found) |h| switch (h.target) {
        .column => |c| c,
        .card => |card| card.column,
        else => b.column,
    } else b.column;
    if (c >= b.columns.len) return;
    const len: i64 = @intCast(b.columns[c].cards.len);
    const step: i64 = if (delta < 0) -1 else 1;
    b.scroll[c] = @intCast(std.math.clamp(@as(i64, b.scroll[c]) + step, 0, @max(len - b.visible, 0)));
}

pub fn drop(s: *AppState, d: AppState.Drag) AppState.Action {
    const b = &s.board;
    const to = d.over orelse return .none;
    if (to == d.card.column or to >= b.columns.len) return .none;
    const col = b.columns[to];
    if (refused(s, col)) return .none;
    b.column = to;
    return .{ .move = .{ .id = d.id, .column = col.name, .done = col.done } };
}

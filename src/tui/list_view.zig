//! The issue list: a sortable, filterable table, optionally as a tree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const issuez = @import("issuez");

const ui = @import("ui.zig");
const filter = @import("filter.zig");
const store = @import("store.zig");
const AppState = @import("State.zig");

const Id = store.Id;
const Snapshot = store.Snapshot;
const K = vaxis.Key;
const palette = ui.palette;

pub const State = struct {
    /// A position in `rows`.
    selected: u32 = 0,
    /// The first row shown.
    scroll: u32 = 0,
    /// Kept across reloads and filter changes, so the selection stays on
    /// the same issue while it is shown.
    selected_id: ?Id = null,
    /// Scroll to `selected_id` on the next frame.
    follow: bool = false,
    /// The last frame's.
    rows: []const filter.Row = &.{},
    visible: u16 = 1,

    pub fn selectedIssue(l: *const State) ?u32 {
        if (l.selected >= l.rows.len) return null;
        return l.rows[l.selected].issue;
    }

    pub fn scrollBy(l: *State, delta: i32) void {
        const max: i64 = @intCast(l.rows.len -| l.visible);
        l.scroll = @intCast(std.math.clamp(@as(i64, l.scroll) + delta, 0, max));
    }

    fn moveTo(l: *State, snap: *const Snapshot, row: i64) void {
        if (l.rows.len == 0) return;
        l.selected = @intCast(std.math.clamp(row, 0, @as(i64, @intCast(l.rows.len - 1))));
        l.selected_id = .of(snap.issues[l.rows[l.selected].issue].id);
        l.follow = true;
    }
};

const Column = enum { marker, id, title, labels, priority, workflow, assignee, due, updated };

const Layout = struct {
    widths: std.EnumArray(Column, u16),

    fn of(total: u16) Layout {
        var w: std.EnumArray(Column, u16) = .initFill(0);
        w.set(.marker, 3);
        w.set(.id, 8);
        if (total >= 60) w.set(.updated, 6);
        if (total >= 72) w.set(.priority, 11);
        if (total >= 88) w.set(.workflow, 12);
        if (total >= 104) w.set(.labels, 18);
        if (total >= 124) w.set(.assignee, 18);
        if (total >= 140) w.set(.due, 11);
        var used: u16 = 0;
        for (std.enums.values(Column)) |c| used += w.get(c);
        w.set(.title, total -| used -| 1);
        return .{ .widths = w };
    }
};

/// The filter text, scope, tree and sort controls, shared with the board.
pub fn drawFilterBar(s: *AppState, f: ui.Frame, bar: ui.Window, tree: bool) Allocator.Error!void {
    const bg: ui.Style = .{ .bg = palette.panel_bg };
    bar.fill(.{ .style = bg });
    var col: u16 = 1;
    const search_icon: ui.Style = .{ .fg = if (s.search_focused) palette.accent else palette.muted, .bg = palette.panel_bg };
    col += ui.text(bar, col, 0, "/ ", search_icon);
    const box_w: u16 = @min(@max(bar.width / 3, 20), 48);
    const box = bar.child(.{ .x_off = col, .width = box_w, .height = 1 });
    try s.search.draw(f.arena, box, .{ .bg = palette.input_bg }, s.search_focused, "filter: words, label:x, @who, p:high, is:blocked");
    try f.hit(box, .search);
    col += box_w + 2;

    for ([_]filter.Scope{ .open, .done, .all }) |sc| {
        col += try ui.button(f, bar, col, 0, sc.label(), .{ .scope = sc }, ui.buttonStyle(s.query.scope == sc));
    }
    col += 2;
    if (tree) {
        col += try ui.button(f, bar, col, 0, if (s.query.tree) "▾ Tree" else "▸ Tree", .tree, ui.buttonStyle(s.query.tree));
        col += 2;
    }
    col += ui.text(bar, col, 0, "Sort ", .{ .fg = palette.muted, .bg = palette.panel_bg });
    const sort_label = switch (s.query.key) {
        inline else => |k| @tagName(k) ++ " ▾",
    };
    col += try ui.button(f, bar, col, 0, sort_label, .{ .command = .sort }, ui.buttonStyle(false));
    col += try ui.button(f, bar, col, 0, if (s.query.reverse) "↑" else "↓", .sort_reverse, ui.buttonStyle(false));
}

pub fn draw(s: *AppState, f: ui.Frame, win: ui.Window) Allocator.Error!void {
    const l = &s.list;
    const snap = s.snap;
    try drawFilterBar(s, f, win.child(.{ .height = 1 }), true);
    l.rows = try filter.rows(f.arena, snap, s.currentQuery());

    // Keep the selection on its issue.
    if (l.selected_id) |*id| {
        for (l.rows, 0..) |r, i| if (id.eql(snap.issues[r.issue].id)) {
            l.selected = @intCast(i);
            break;
        };
    }
    if (l.selected >= l.rows.len) l.selected = @intCast(l.rows.len -| 1);
    if (l.rows.len > 0) l.selected_id = .of(snap.issues[l.rows[l.selected].issue].id);

    const head = win.child(.{ .y_off = 1, .height = 1 });
    const lay = Layout.of(win.width);
    try drawHeader(s, f, head, lay);

    const body = win.child(.{ .y_off = 2, .height = win.height -| 2 });
    l.visible = @max(body.height, 1);
    if (l.follow) {
        if (l.selected < l.scroll) l.scroll = l.selected;
        if (l.selected >= l.scroll + l.visible) l.scroll = l.selected - l.visible + 1;
        l.follow = false;
    }
    l.scroll = @min(l.scroll, @as(u32, @intCast(l.rows.len -| l.visible)));

    if (l.rows.len == 0) {
        const msg = if (snap.issues.len == 0) "No issues yet." else "No issues match the filter.";
        const mid = body.height / 2;
        const mw = body.gwidth(msg);
        _ = ui.text(body, (body.width -| mw) / 2, mid -| 1, msg, .{ .fg = palette.muted });
        _ = try ui.button(f, body, (body.width -| 14) / 2, mid + 1, "+ New issue", .{ .command = .new_issue }, ui.buttonStyle(true));
        return;
    }

    var y: u16 = 0;
    while (y < body.height and l.scroll + y < l.rows.len) : (y += 1) {
        const index = l.scroll + y;
        const row_win = body.child(.{ .y_off = y, .height = 1 });
        drawRow(s, f, row_win, lay, l.rows[index], index == l.selected);
        try f.hit(row_win, .{ .row = index });
    }
    // Scroll position.
    if (l.rows.len > body.height and body.height > 0) {
        const total: u32 = @intCast(l.rows.len);
        const pos: u16 = @intCast(@as(u64, l.scroll) * (body.height - 1) / @max(total - body.height, 1));
        body.writeCell(body.width - 1, pos, .{ .char = .{ .grapheme = "┃" }, .style = .{ .fg = palette.faint } });
    }
}

fn drawHeader(s: *AppState, f: ui.Frame, head: ui.Window, lay: Layout) Allocator.Error!void {
    const style: ui.Style = .{ .fg = palette.muted, .bold = true };
    head.fill(.{ .style = .{} });
    var x: u16 = 0;
    for (std.enums.values(Column)) |c| {
        const w = lay.widths.get(c);
        if (w == 0) continue;
        const sort_key: ?filter.SortKey = switch (c) {
            .id => .id,
            .title => .title,
            .priority => .priority,
            .workflow => .state,
            .due => .due,
            .updated => .updated,
            else => null,
        };
        const name: []const u8 = switch (c) {
            .marker => "",
            .id => "ID",
            .title => "Title",
            .labels => "Labels",
            .priority => "Priority",
            .workflow => "State",
            .assignee => "Assignee",
            .due => "Due",
            .updated => "Upd",
        };
        const cell = head.child(.{ .x_off = x, .width = w, .height = 1 });
        var cx = ui.text(cell, 0, 0, name, if (sort_key != null and sort_key.? == s.query.key) .{ .fg = palette.accent, .bold = true } else style);
        if (sort_key) |k| {
            if (k == s.query.key) cx += ui.text(cell, cx, 0, if (s.query.reverse) " ↑" else " ↓", .{ .fg = palette.accent });
            try f.hit(cell, .{ .sort = k });
        }
        x += w;
    }
}

fn drawRow(s: *AppState, f: ui.Frame, win: ui.Window, lay: Layout, row: filter.Row, selected: bool) void {
    const snap = s.snap;
    const i = row.issue;
    const issue = snap.issues[i];
    const done = snap.isDone(i);
    const bg: vaxis.Color = if (selected) palette.select_bg else .default;
    if (selected) win.fill(.{ .style = .{ .bg = bg } });
    const dim = row.context;

    var x: u16 = 0;
    for (std.enums.values(Column)) |c| {
        const w = lay.widths.get(c);
        if (w == 0) continue;
        const cell = win.child(.{ .x_off = x, .width = w -| 1, .height = 1 });
        x += w;
        switch (c) {
            .marker => {
                const blocked = snap.proj.activelyBlocked(i);
                // Deleted: only as the context of a sub-issue in the tree.
                const glyph: []const u8 = if (issue.deleted) "✗" else if (done) "✓" else if (blocked) "⊘" else "●";
                const fg = if (issue.deleted) palette.err else if (done) palette.done else if (blocked) palette.err else palette.open;
                _ = ui.text(cell, 0, 0, if (selected) "▌" else " ", .{ .fg = palette.accent, .bg = bg });
                _ = ui.text(win, 1, 0, glyph, .{ .fg = fg, .bg = bg, .dim = dim });
            },
            .id => _ = ui.text(cell, 0, 0, issuez.format.uuid.shortId(issue.id), .{ .fg = palette.id, .bg = bg, .dim = dim }),
            .title => {
                var tx: u16 = 0;
                if (row.depth > 0) {
                    const indent: u16 = @intCast(@min(@as(u32, row.depth - 1) * 2, cell.width / 2));
                    tx += indent;
                    tx += ui.text(cell, tx, 0, "└ ", .{ .fg = palette.faint, .bg = bg });
                }
                const ts: ui.Style = .{
                    .fg = if (done or dim) palette.muted else .default,
                    .bg = bg,
                    .bold = selected and !dim,
                    .strikethrough = (done and issue.state == .closed) or issue.deleted,
                };
                tx += ui.text(cell, tx, 0, issue.title, ts);
                if (snap.proj.progress(i)) |p| {
                    _ = ui.text(cell, tx + 1, 0, f.fmt("{d}/{d}", .{ p.closed, p.total }), .{ .fg = palette.muted, .bg = bg });
                }
            },
            .labels => {
                var lx: u16 = 0;
                for (issue.labels) |lab| {
                    if (lx >= cell.width) break;
                    lx += ui.text(cell, lx, 0, lab, .{ .fg = palette.label, .bg = bg, .dim = dim });
                    lx += 1;
                }
            },
            .priority => {
                const p = issue.field("Priority");
                _ = ui.text(cell, 0, 0, p orelse "·", .{ .fg = ui.priorityColor(p), .bg = bg, .dim = dim });
            },
            .workflow => {
                const t = if (done) issue.state.text() else snap.proj.workflow(i) orelse issue.state.text();
                _ = ui.text(cell, 0, 0, t, .{ .fg = if (done) palette.done else palette.muted, .bg = bg, .dim = dim });
            },
            .assignee => {
                const a = issue.field("Assignee") orelse "";
                const shown = if (issue.ext.assignee) |p| p.email else a;
                _ = ui.text(cell, 0, 0, shown, .{ .fg = palette.muted, .bg = bg, .dim = dim });
            },
            .due => if (issue.ext.due_date) |d| {
                _ = ui.text(cell, 0, 0, f.fmt("{f}", .{d}), .{ .fg = palette.muted, .bg = bg, .dim = dim });
            },
            .updated => _ = ui.text(cell, 0, 0, ui.ago(f, issue.updated), .{ .fg = palette.muted, .bg = bg, .dim = dim }),
        }
    }
}

pub fn key(s: *AppState, k: vaxis.Key) Allocator.Error!AppState.Action {
    const l = &s.list;
    const snap = s.snap;
    const sel: i64 = l.selected;
    const page: i64 = @max(l.visible, 2) - 1;
    if (k.matches(K.down, .{}) or k.matches('j', .{})) {
        l.moveTo(snap, sel + 1);
    } else if (k.matches(K.up, .{}) or k.matches('k', .{})) {
        l.moveTo(snap, sel - 1);
    } else if (k.matches(K.page_down, .{}) or k.matches('d', .{ .ctrl = true })) {
        l.moveTo(snap, sel + page);
    } else if (k.matches(K.page_up, .{}) or k.matches('u', .{ .ctrl = true })) {
        l.moveTo(snap, sel - page);
    } else if (k.matches(K.home, .{}) or k.matches('g', .{})) {
        l.moveTo(snap, 0);
    } else if (k.matches(K.end, .{}) or k.matches('G', .{})) {
        l.moveTo(snap, @as(i64, @intCast(l.rows.len)) - 1);
    } else if (k.matches(K.enter, .{}) or k.matches(K.right, .{}) or k.matches('l', .{})) {
        if (l.selectedIssue()) |i| s.openIssue(snap.issues[i].id);
    } else if (k.matches('t', .{})) {
        s.query.tree = !s.query.tree;
        l.follow = true;
    } else if (k.matches('a', .{})) {
        if (l.selectedIssue()) |i| s.newIssue(i);
    } else if (k.matches('x', .{})) {
        if (l.selectedIssue()) |i| return s.toggleAction(i);
    }
    return .none;
}

pub fn click(s: *AppState, row: u32, double: bool) AppState.Action {
    const l = &s.list;
    if (row >= l.rows.len) return .none;
    l.moveTo(s.snap, row);
    if (double) s.openIssue(s.snap.issues[l.rows[row].issue].id);
    return .none;
}

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

    pub fn moveTo(l: *State, snap: *const Snapshot, row: i64) void {
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

/// The filter text, scope, tree and sort controls of the view's issue
/// query, shared with the board and the milestone view. Returns the
/// columns used.
pub fn drawFilterBar(s: *AppState, f: ui.Frame, bar: ui.Window, tree: bool) Allocator.Error!u16 {
    const q = s.issueQuery();
    const bg: ui.Style = .{ .bg = palette.panel_bg };
    bar.fill(.{ .style = bg });
    var col: u16 = 1;
    const search_icon: ui.Style = .{
        .fg = if (s.search_focused) palette.accent else palette.muted,
        .bg = palette.panel_bg,
    };
    col += ui.text(bar, col, 0, "/ ", search_icon);
    const box_w: u16 = @min(@max(bar.width / 3, 20), 48);
    const box = bar.child(.{ .x_off = col, .width = box_w, .height = 1 });
    try s.searchBox().draw(
        f.arena,
        box,
        .{ .bg = palette.input_bg },
        s.search_focused,
        "filter: words, label:x, @who, p:high, is:blocked",
    );
    try f.hit(box, .search);
    col += box_w + 2;

    for ([_]filter.Scope{ .open, .done, .all }) |sc| {
        col += try ui.button(
            f,
            bar,
            col,
            0,
            sc.label(),
            .{ .scope = sc },
            ui.buttonStyle(q.scope == sc),
        );
    }
    col += 2;
    if (tree) {
        col += try ui.button(
            f,
            bar,
            col,
            0,
            if (q.tree) "▾ Tree" else "▸ Tree",
            .tree,
            ui.buttonStyle(q.tree),
        );
        col += 2;
    }
    col += ui.text(bar, col, 0, "Sort ", .{ .fg = palette.muted, .bg = palette.panel_bg });
    const sort_label = switch (q.key) {
        inline else => |k| @tagName(k) ++ " ▾",
    };
    col += try ui.button(f, bar, col, 0, sort_label, .{ .command = .sort }, ui.buttonStyle(false));
    col += try ui.button(
        f,
        bar,
        col,
        0,
        if (q.reverse) "↑" else "↓",
        .sort_reverse,
        ui.buttonStyle(false),
    );
    return col;
}

pub fn draw(s: *AppState, f: ui.Frame, win: ui.Window) Allocator.Error!void {
    _ = try drawFilterBar(s, f, win.child(.{ .height = 1 }), true);
    const rows = try filter.rows(f.arena, s.snap, s.currentQuery());
    try drawTable(
        s,
        f,
        win.child(.{ .y_off = 1, .height = win.height -| 1 }),
        .{ .l = &s.list, .rows = rows, .query = s.query },
    );
}

/// One issue table: the list, or a pane of the milestone view.
pub const Table = struct {
    l: *State,
    rows: []const filter.Row,
    /// For the header's sort marks.
    query: filter.Query,
    /// A pane of the milestone view: its rows' targets are `.mrow`.
    pane: ?u16 = null,
    /// Issues shown with a mark.
    marks: []const Id = &.{},
    /// Without the focus the selection shows dimmer.
    focused: bool = true,
    /// What it says without rows; null: the list's messages.
    empty: ?[]const u8 = null,
    /// Draws a drop target's highlight.
    drop: bool = false,
};

/// The header and the rows, keeping the selection on its issue.
pub fn drawTable(s: *AppState, f: ui.Frame, win: ui.Window, t: Table) Allocator.Error!void {
    const l = t.l;
    const snap = s.snap;
    l.rows = t.rows;

    // Keep the selection on its issue.
    if (l.selected_id) |*id| {
        for (l.rows, 0..) |r, i| if (id.eql(snap.issues[r.issue].id)) {
            l.selected = @intCast(i);
            break;
        };
    }
    if (l.selected >= l.rows.len) l.selected = @intCast(l.rows.len -| 1);
    if (l.rows.len > 0) l.selected_id = .of(snap.issues[l.rows[l.selected].issue].id);

    const head = win.child(.{ .height = 1 });
    const lay = Layout.of(win.width);
    try drawHeader(f, head, lay, t.query);

    const body = win.child(.{ .y_off = 1, .height = win.height -| 1 });
    if (t.drop) body.fill(.{ .style = .{ .bg = palette.hover_bg } });
    l.visible = @max(body.height, 1);
    if (l.follow) {
        if (l.selected < l.scroll) l.scroll = l.selected;
        if (l.selected >= l.scroll + l.visible) l.scroll = l.selected - l.visible + 1;
        l.follow = false;
    }
    l.scroll = @min(l.scroll, @as(u32, @intCast(l.rows.len -| l.visible)));

    if (t.pane) |p| try f.hit(body, .{ .mpane = p });
    if (l.rows.len == 0) {
        const msg = t.empty orelse if (snap.issues.len == 0) "No issues yet." else "No issues " ++
            "match the filter.";
        const mid = body.height / 2;
        const mw = body.gwidth(msg);
        _ = ui.text(body, (body.width -| mw) / 2, mid -| 1, msg, .{ .fg = palette.muted });
        if (t.pane == null) _ = try ui.button(
            f,
            body,
            (body.width -| 14) / 2,
            mid + 1,
            "+ New issue",
            .{ .command = .new_issue },
            ui.buttonStyle(true),
        );
        return;
    }

    var y: u16 = 0;
    while (y < body.height and l.scroll + y < l.rows.len) : (y += 1) {
        const index = l.scroll + y;
        const row_win = body.child(.{ .y_off = y, .height = 1 });
        const r = l.rows[index];
        const marked = for (t.marks) |*m| {
            if (m.eql(snap.issues[r.issue].id)) break true;
        } else false;
        const dragged = if (s.drag) |d| d.moved and t.pane != null and d.card.column == t.pane.? and
            d.card.index == index else false;
        drawRow(
            s,
            f,
            row_win,
            lay,
            r,
            .{
                .selected = index == l.selected,
                .focused = t.focused,
                .marked = marked,
                .dragged = dragged,
            },
        );
        try f.hit(
            row_win,
            if (t.pane) |p| .{ .mrow = .{ .column = p, .index = index } } else .{ .row = index },
        );
    }
    // Scroll position.
    if (l.rows.len > body.height and body.height > 0) {
        const total: u32 = @intCast(l.rows.len);
        const pos: u16 = @intCast(
            @as(u64, l.scroll) * (body.height - 1) / @max(total - body.height, 1),
        );
        body.writeCell(
            body.width - 1,
            pos,
            .{ .char = .{ .grapheme = "┃" }, .style = .{ .fg = palette.faint } },
        );
    }
}

fn drawHeader(f: ui.Frame, head: ui.Window, lay: Layout, q: filter.Query) Allocator.Error!void {
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
        var cx = ui.text(
            cell,
            0,
            0,
            name,
            if (sort_key != null and sort_key.? == q.key) .{
                .fg = palette.accent,
                .bold = true,
            } else style,
        );
        if (sort_key) |k| {
            if (k == q.key) cx += ui.text(
                cell,
                cx,
                0,
                if (q.reverse) " ↑" else " ↓",
                .{ .fg = palette.accent },
            );
            try f.hit(cell, .{ .sort = k });
        }
        x += w;
    }
}

const RowLook = struct {
    selected: bool,
    focused: bool = true,
    marked: bool = false,
    dragged: bool = false,
};

fn drawRow(
    s: *AppState,
    f: ui.Frame,
    win: ui.Window,
    lay: Layout,
    row: filter.Row,
    look: RowLook,
) void {
    const snap = s.snap;
    const i = row.issue;
    const issue = snap.issues[i];
    const done = snap.isDone(i);
    const selected = look.selected;
    const bg: vaxis.Color = if (look.dragged) palette.hover_bg else if (selected and
        look.focused) palette.select_bg else if (look.marked) palette.mark_bg else .default;
    if (bg != .default) win.fill(.{ .style = .{ .bg = bg } });
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
                const glyph: []const u8 =
                    if (issue.deleted) "✗" else if (done) "✓" else if (blocked) "⊘" else "●";
                const fg = if (issue.deleted or blocked)
                    palette.err
                else if (done)
                    palette.done
                else
                    palette.open;
                _ = ui.text(
                    cell,
                    0,
                    0,
                    if (look.marked) "✓" else if (selected) "▌" else " ",
                    .{
                        .fg = if (look.marked)
                            palette.ok
                        else if (look.focused)
                            palette.accent
                        else
                            palette.muted,
                        .bg = bg,
                    },
                );
                _ = ui.text(win, 1, 0, glyph, .{ .fg = fg, .bg = bg, .dim = dim });
                // Not pushed yet, or refused by the remote.
                if (snap.remote.isQuarantined(issue.id)) {
                    _ = ui.text(win, 2, 0, "!", .{ .fg = palette.err, .bg = bg, .bold = true });
                } else if (snap.remote.isUnpushed(issue.id)) {
                    _ = ui.text(win, 2, 0, "↑", .{ .fg = palette.faint, .bg = bg });
                }
            },
            .id => _ = ui.text(
                cell,
                0,
                0,
                issuez.format.uuid.shortId(issue.id),
                .{ .fg = palette.id, .bg = bg, .dim = dim },
            ),
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
                    .bold = selected and look.focused and !dim,
                    .strikethrough = (done and issue.state == .closed) or issue.deleted,
                };
                tx += ui.text(cell, tx, 0, issue.title, ts);
                if (snap.proj.progress(i)) |p| {
                    tx += 1;
                    tx += ui.text(
                        cell,
                        tx,
                        0,
                        f.fmt("{d}/{d}", .{ p.closed, p.total }),
                        .{ .fg = palette.muted, .bg = bg },
                    );
                }
                if (row.inherited) _ = ui.text(
                    cell,
                    tx + 1,
                    0,
                    "↳ inherited",
                    .{ .fg = palette.faint, .bg = bg, .italic = true },
                );
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
                _ = ui.text(
                    cell,
                    0,
                    0,
                    p orelse "·",
                    .{ .fg = ui.priorityColor(p), .bg = bg, .dim = dim },
                );
            },
            .workflow => {
                const workflow = snap.proj.workflow(i) orelse issue.state.text();
                const t = if (done) issue.state.text() else workflow;
                _ = ui.text(
                    cell,
                    0,
                    0,
                    t,
                    .{ .fg = if (done) palette.done else palette.muted, .bg = bg, .dim = dim },
                );
            },
            .assignee => {
                const a = issue.field("Assignee") orelse "";
                const shown = if (issue.assignee) |p| p.email else a;
                _ = ui.text(cell, 0, 0, shown, .{ .fg = palette.muted, .bg = bg, .dim = dim });
            },
            .due => if (issue.due_date) |d| {
                _ = ui.text(
                    cell,
                    0,
                    0,
                    f.fmt("{f}", .{d}),
                    .{ .fg = palette.muted, .bg = bg, .dim = dim },
                );
            },
            .updated => _ = ui.text(
                cell,
                0,
                0,
                ui.ago(f, issue.updated),
                .{ .fg = palette.muted, .bg = bg, .dim = dim },
            ),
        }
    }
}

pub fn key(s: *AppState, k: vaxis.Key) Allocator.Error!AppState.Action {
    return tableKey(s, &s.list, k) orelse .none;
}

/// Keys on an issue table; null when the key isn't one of them.
pub fn tableKey(s: *AppState, l: *State, k: vaxis.Key) ?AppState.Action {
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
        const q = s.issueQuery();
        q.tree = !q.tree;
        l.follow = true;
    } else if (k.matches('a', .{})) {
        if (l.selectedIssue()) |i| s.newIssue(i);
    } else if (k.matches('x', .{})) {
        if (l.selectedIssue()) |i| return s.toggleAction(i);
    } else return null;
    return .none;
}

pub fn click(s: *AppState, row: u32, double: bool) AppState.Action {
    const l = &s.list;
    if (row >= l.rows.len) return .none;
    l.moveTo(s.snap, row);
    if (double) s.openIssue(s.snap.issues[l.rows[row].issue].id);
    return .none;
}

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
    /// The last frame's: the first row shown with the last one in view,
    /// dividers counted.
    max_scroll: u32 = 0,

    pub fn selectedIssue(l: *const State) ?u32 {
        if (l.selected >= l.rows.len) return null;
        return l.rows[l.selected].issue;
    }

    pub fn scrollBy(l: *State, delta: i32) void {
        const max: i64 = l.max_scroll;
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
    const box_w: u16 = @min(@max(bar.width / 3, 20), 48);
    const hint = "filter: words, label:x, @who, p:high, is:blocked";
    const x = try ui.filterBox(f, bar, s.searchBox(), s.search_focused, box_w, hint);
    var l: ui.Line = .{ .f = f, .win = bar, .x = x };
    for ([_]filter.Scope{ .open, .done, .all }) |sc| {
        try l.button(sc.label(), .{ .scope = sc }, ui.buttonStyle(q.scope == sc));
    }
    l.x += 2;
    if (tree) {
        try l.button(if (q.tree) "▾ Tree" else "▸ Tree", .tree, ui.buttonStyle(q.tree));
        l.x += 2;
    }
    l.text("Sort ", .{ .fg = palette.muted, .bg = palette.panel_bg });
    const sort_label = switch (q.key) {
        inline else => |k| @tagName(k) ++ " ▾",
    };
    try l.button(sort_label, .{ .command = .sort }, ui.buttonStyle(false));
    try l.button(if (q.reverse) "↑" else "↓", .sort_reverse, ui.buttonStyle(false));
    l.x += 1;
    l.text("then ", .{ .fg = palette.muted, .bg = palette.panel_bg });
    const then_label = if (q.then) |t| switch (t) {
        inline else => |k| @tagName(k) ++ " ▾",
    } else "…";
    try l.button(then_label, .{ .command = .then_sort }, ui.buttonStyle(false));
    if (q.then != null) {
        try l.button(if (q.then_reverse) "↑" else "↓", .then_reverse, ui.buttonStyle(false));
    }
    return l.x;
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
    var q = t.query;
    q.utc_offset_s = s.utc_offset_s;
    const grouped = filter.grouped(q);

    const body = win.child(.{ .y_off = 1, .height = win.height -| 1 });
    if (t.drop) body.fill(.{ .style = .{ .bg = palette.hover_bg } });
    l.visible = @max(body.height, 1);
    const follow = l.follow;
    const was = l.scroll;
    ui.settleScroll(&l.scroll, &l.follow, l.selected, l.rows.len, l.visible);
    l.max_scroll = @intCast(l.rows.len -| l.visible);
    // Dividers take lines of their own: fewer rows fit, so the scroll may
    // go further than settleScroll lets it.
    if (grouped) {
        l.max_scroll = maxScroll(snap, q, l.rows, body.height);
        if (follow) {
            while (l.scroll < l.selected and
                linesFor(snap, q, l.rows, l.scroll, l.selected, body.height) > body.height)
                l.scroll += 1;
        } else l.scroll = was;
        l.scroll = @min(l.scroll, l.max_scroll);
    }

    if (t.pane) |p| try f.hit(body, .{ .mpane = p });
    // Where a dragged row lands in your order.
    const lands = if (s.drag) |d| landsAt(s, d) else null;
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
    var index = l.scroll;
    while (y < body.height and index < l.rows.len) : ({
        y += 1;
        index += 1;
    }) {
        if (grouped and startsGroup(snap, q, l.rows, index)) {
            ui.divider(
                body.child(.{ .y_off = y, .width = body.width -| 1, .height = 1 }),
                try filter.groupName(f.arena, snap, q, l.rows[index].issue),
            );
            y += 1;
            if (y >= body.height) break;
        }
        const row_win = body.child(.{ .y_off = y, .height = 1 });
        const r = l.rows[index];
        const marked = for (t.marks) |*m| {
            if (m.eql(snap.issues[r.issue].id)) break true;
        } else false;
        const dragged = if (s.drag) |d| d.moved and d.card.index == index and
            (if (t.pane) |p| d.card.column == p else s.view == .list) else false;
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
        if (t.pane == null and lands == index) row_win.writeCell(0, 0, .{
            .char = .{ .grapheme = "▶" },
            .style = .{ .fg = palette.accent, .bold = true },
        });
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
            ) else if (k == q.then) cx += ui.text(
                cell,
                cx,
                0,
                if (q.then_reverse) " ↑" else " ↓",
                .{ .fg = palette.muted },
            );
            try f.hit(cell, .{ .sort = k });
        }
        x += w;
    }
}

/// The first row shown of its group: a divider above it.
fn startsGroup(
    snap: *const Snapshot,
    q: filter.Query,
    rows: []const filter.Row,
    index: usize,
) bool {
    return index == 0 or !filter.sameGroup(snap, q, rows[index - 1].issue, rows[index].issue);
}

/// Screen lines from `from` to `to`, both rows and the dividers above them;
/// counted up to just past `cap`.
fn linesFor(
    snap: *const Snapshot,
    q: filter.Query,
    rows: []const filter.Row,
    from: usize,
    to: usize,
    cap: usize,
) usize {
    var n: usize = 0;
    for (from..to + 1) |i| {
        n += @as(usize, 1) + @intFromBool(startsGroup(snap, q, rows, i));
        if (n > cap) break;
    }
    return n;
}

/// The first row from which the rest fit in `height` lines, dividers
/// counted.
fn maxScroll(snap: *const Snapshot, q: filter.Query, rows: []const filter.Row, height: u16) u32 {
    var lines: usize = 0;
    var i = rows.len;
    while (i > 0) : (i -= 1) {
        lines += @as(usize, 1) + @intFromBool(startsGroup(snap, q, rows, i - 1));
        if (lines > height) break;
    }
    return @intCast(i);
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
    const muted: ui.Style = .{ .fg = palette.muted, .bg = bg, .dim = dim };

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
                var l: ui.Line = .{ .f = f, .win = cell };
                if (row.depth > 0) {
                    l.x = @intCast(@min(@as(u32, row.depth - 1) * 2, cell.width / 2));
                    l.text("└ ", .{ .fg = palette.faint, .bg = bg });
                }
                l.word(issue.title, .{
                    .fg = if (done or dim) palette.muted else .default,
                    .bg = bg,
                    .bold = selected and look.focused and !dim,
                    .strikethrough = (done and issue.state == .closed) or issue.deleted,
                });
                if (snap.proj.progress(i)) |p| l.word(
                    f.fmt("{d}/{d}", .{ p.closed, p.total }),
                    .{ .fg = palette.muted, .bg = bg },
                );
                if (row.inherited) l.text(
                    "↳ inherited",
                    .{ .fg = palette.faint, .bg = bg, .italic = true },
                );
            },
            .labels => {
                var l: ui.Line = .{ .f = f, .win = cell };
                for (issue.labels) |lab| {
                    if (l.x >= cell.width) break;
                    l.word(lab, .{ .fg = palette.label, .bg = bg, .dim = dim });
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
                _ = ui.text(cell, 0, 0, shown, muted);
            },
            .due => if (issue.due_date) |d| {
                _ = ui.text(cell, 0, 0, f.fmt("{f}", .{d}), muted);
            },
            .updated => _ = ui.text(cell, 0, 0, ui.ago(f, issue.updated), muted),
        }
    }
}

pub fn key(s: *AppState, k: vaxis.Key) Allocator.Error!AppState.Action {
    if (k.matches('K', .{}) or k.matches(K.up, .{ .shift = true })) return reorder(s, -1);
    if (k.matches('J', .{}) or k.matches(K.down, .{ .shift = true })) return reorder(s, 1);
    return tableKey(s, &s.list, k) orelse .none;
}

/// Why rows can't be ordered by hand now; null when they can.
fn notInYourOrder(s: *const AppState) ?[]const u8 {
    const q = s.query;
    if (!filter.byHand(q)) {
        if (q.key == .rank) return "S first: rows are ordered by hand top to bottom";
        if (q.then == .rank and q.then_reverse)
            return "B first: rows are ordered by hand top to bottom";
        return "s → rank orders rows by hand, b → rank within groups";
    }
    if (q.tree) return "t first: rows are ordered by hand without the tree";
    return null;
}

/// The rows' issues, in the input arena.
fn rowIssues(s: *AppState) Allocator.Error![]const u32 {
    const out = try s.input_arena.allocator().alloc(u32, s.list.rows.len);
    for (s.list.rows, out) |r, *i| i.* = r.issue;
    return out;
}

/// The rows of `i`'s group, sorted by a key then by rank: where they are.
fn groupOf(s: *const AppState, i: u32) filter.Range {
    const rows = s.list.rows;
    const q = s.currentQuery();
    if (q.key == .rank) return .{ .start = 0, .end = rows.len };
    var start: usize = 0;
    while (start < rows.len and !filter.sameGroup(s.snap, q, rows[start].issue, i)) start += 1;
    var end = start;
    while (end < rows.len and filter.sameGroup(s.snap, q, rows[end].issue, i)) end += 1;
    return .{ .start = start, .end = end };
}

/// Why a row can't go to `to`: out of its group, which rank doesn't leave.
fn outsideGroup(s: *AppState, i: u32, to: usize) Allocator.Error!?[]const u8 {
    const g = groupOf(s, i);
    if (to >= g.start and to < g.end) return null;
    return try filter.groupName(s.input_arena.allocator(), s.snap, s.currentQuery(), i);
}

/// Where the issue's row is now, if it is shown.
fn rowOf(s: *const AppState, id: Id) ?usize {
    for (s.list.rows, 0..) |r, n| if (id.eql(s.snap.issues[r.issue].id)) return n;
    return null;
}

/// J and K: the selected row a place down or up.
fn reorder(s: *AppState, delta: i32) Allocator.Error!AppState.Action {
    const l = &s.list;
    const i = l.selectedIssue() orelse return .none;
    if (notInYourOrder(s)) |why| return s.noted("{s}", .{why});
    const to = @as(i64, l.selected) + delta;
    if (to >= 0 and to < l.rows.len) if (try outsideGroup(s, i, @intCast(to))) |group|
        return s.noted("rank orders rows within {s}", .{group});
    const g = groupOf(s, i);
    const rows = (try rowIssues(s))[g.start..g.end];
    const action = try s.reorderStep(rows, l.selected - g.start, delta);
    if (action != .none) l.follow = true;
    return action;
}

/// The row a drag on the list is over.
pub fn slotAt(found: ?ui.Hits.Found) ?u32 {
    const h = found orelse return null;
    return switch (h.target) {
        .row => |r| r,
        else => null,
    };
}

/// Where the dragged row would go: the place of the row under the
/// pointer. Null when it wouldn't move or the list isn't in your order.
fn landsAt(s: *const AppState, d: AppState.Drag) ?u32 {
    if (s.view != .list or !d.moved or notInYourOrder(s) != null) return null;
    const slot = d.slot orelse return null;
    // The rows may be of a newer snapshot than the press: by its ID.
    const from = rowOf(s, d.id) orelse return null;
    if (slot == from or slot >= s.list.rows.len) return null;
    const g = groupOf(s, s.list.rows[from].issue);
    if (slot < g.start or slot >= g.end) return null;
    return slot;
}

/// A row let go of over another takes its place.
pub fn drop(s: *AppState, d: AppState.Drag) Allocator.Error!AppState.Action {
    const slot = d.slot orelse return .none;
    const from = rowOf(s, d.id) orelse return .none;
    if (from == slot) return .none;
    if (notInYourOrder(s)) |why| return s.noted("{s}", .{why});
    const i = s.list.rows[from].issue;
    if (slot < s.list.rows.len) if (try outsideGroup(s, i, slot)) |group|
        return s.noted("rank orders rows within {s}", .{group});
    const at = landsAt(s, d) orelse return .none;
    s.list.follow = true;
    const g = groupOf(s, i);
    const others = try s.othersBut((try rowIssues(s))[g.start..g.end], d.id);
    return .{ .reorder = .{ .id = d.id, .others = others, .at = @intCast(at - g.start) } };
}

/// Keys on an issue table; null when the key isn't one of them.
pub fn tableKey(s: *AppState, l: *State, k: vaxis.Key) ?AppState.Action {
    const snap = s.snap;
    if (ui.rowKey(k, l.selected, l.rows.len, l.visible)) |row| {
        l.moveTo(snap, row);
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
    const id = s.snap.issues[l.rows[row].issue].id;
    if (double) {
        s.openIssue(id);
        return .none;
    }
    // Held, it may be dragged to another place.
    s.drag = .{ .card = .{ .column = 0, .index = row }, .id = .of(id) };
    return .none;
}

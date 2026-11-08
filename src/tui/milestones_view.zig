//! The milestones: one table with progress and health at a glance,
//! sortable and filterable, with keys to create, edit and complete them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const issuez = @import("issuez");

const ui = @import("ui.zig");
const store = @import("store.zig");
const dates = issuez.format.dates;
const mf = @import("milestone_filter.zig");
const modal_mod = @import("modal.zig");
const AppState = @import("State.zig");

const Id = store.Id;
const Snapshot = store.Snapshot;
const K = vaxis.Key;
const palette = ui.palette;
const shortId = issuez.format.uuid.shortId;

pub const State = struct {
    /// A position in `rows`.
    selected: u32 = 0,
    scroll: u32 = 0,
    /// Kept across reloads and filter changes, also while the filter
    /// hides it, until the user moves. Null with the "no milestone" row
    /// selected, or nothing.
    selected_id: ?Id = null,
    /// The "no milestone" row is selected.
    selected_none: bool = false,
    follow: bool = false,
    /// The last frame's: positions in the snapshot's milestones, the
    /// count for "no milestone".
    rows: []const u32 = &.{},
    visible: u16 = 1,
    /// Progress bars show work in progress too.
    in_progress: bool = false,

    /// The selected milestone's position in the catalog; null for none.
    pub fn selectedMilestone(m: *const State, snap: *const Snapshot) ?u32 {
        if (m.selected >= m.rows.len) return null;
        const n = m.rows[m.selected];
        return if (n < snap.milestones.len) n else null;
    }

    pub fn scrollBy(m: *State, delta: i32) void {
        const max: i64 = @intCast(m.rows.len -| m.visible);
        m.scroll = @intCast(std.math.clamp(@as(i64, m.scroll) + delta, 0, max));
    }

    pub fn moveTo(m: *State, snap: *const Snapshot, row: i64) void {
        if (m.rows.len == 0) return;
        m.selected = @intCast(std.math.clamp(row, 0, @as(i64, @intCast(m.rows.len - 1))));
        m.remember(snap);
        m.follow = true;
    }

    fn remember(m: *State, snap: *const Snapshot) void {
        const n = m.rows[m.selected];
        m.selected_none = n >= snap.milestones.len;
        m.selected_id = if (m.selected_none) null else .of(snap.milestones[n].id);
    }

    /// After a create: show it.
    pub fn select(m: *State, id: Id) void {
        m.selected_id = id;
        m.selected_none = false;
        m.follow = true;
    }
};

const Column = enum { marker, name, progress, open, done, blocked, due, health, id };

const Layout = struct {
    widths: std.EnumArray(Column, u16),
    bar: u16,

    fn of(total: u16) Layout {
        var w: std.EnumArray(Column, u16) = .initFill(0);
        w.set(.marker, 3);
        w.set(.progress, 16);
        if (total >= 60) w.set(.open, 6);
        // A date, then "in 16d" or "12d late".
        if (total >= 72) w.set(.due, 22);
        if (total >= 84) w.set(.done, 6);
        if (total >= 92) w.set(.health, 12);
        if (total >= 100) w.set(.blocked, 5);
        if (total >= 112) w.set(.id, 9);
        if (total >= 130) w.set(.progress, 28);
        var used: u16 = 0;
        for (std.enums.values(Column)) |c| used += w.get(c);
        w.set(.name, @max(total -| used -| 1, 8));
        return .{ .widths = w, .bar = w.get(.progress) -| 6 };
    }
};

fn drawFilterBar(s: *AppState, f: ui.Frame, bar: ui.Window) Allocator.Error!void {
    const bg: ui.Style = .{ .bg = palette.panel_bg };
    bar.fill(.{ .style = bg });
    var col: u16 = 1;
    col += ui.text(
        bar,
        col,
        0,
        "/ ",
        .{ .fg = if (s.search_focused) palette.accent else palette.muted, .bg = palette.panel_bg },
    );
    const box_w: u16 = @min(@max(bar.width / 3, 20), 48);
    const box = bar.child(.{ .x_off = col, .width = box_w, .height = 1 });
    try s.ms_search.draw(
        f.arena,
        box,
        .{ .bg = palette.input_bg },
        s.search_focused,
        "filter: words, is:overdue, is:at-risk, due:<2026-12-31",
    );
    try f.hit(box, .search);
    col += box_w + 2;
    for (std.enums.values(mf.Scope)) |sc| {
        col += try ui.button(
            f,
            bar,
            col,
            0,
            sc.label(),
            .{ .ms_scope = sc },
            ui.buttonStyle(s.ms_query.scope == sc),
        );
    }
    col += 2;
    col += ui.text(bar, col, 0, "Sort ", .{ .fg = palette.muted, .bg = palette.panel_bg });
    const sort_label = switch (s.ms_query.key) {
        inline else => |k| @tagName(k) ++ " ▾",
    };
    col += try ui.button(f, bar, col, 0, sort_label, .{ .command = .sort }, ui.buttonStyle(false));
    col += try ui.button(
        f,
        bar,
        col,
        0,
        if (s.ms_query.reverse) "↑" else "↓",
        .sort_reverse,
        ui.buttonStyle(false),
    );
}

pub fn draw(s: *AppState, f: ui.Frame, win: ui.Window) Allocator.Error!void {
    const v = &s.milestones;
    const snap = s.snap;
    try drawFilterBar(s, f, win.child(.{ .height = 1 }));
    const data = try mf.Data.of(f.arena, snap, s.today, s.utc_offset_s);
    const q = s.currentMilestoneQuery();
    v.rows = try mf.rows(f.arena, snap, q, data);
    var why: [160]u8 = undefined;
    if (s.status_len == 0) if (mf.problem(&why, q.text)) |msg| s.fail("filter: {s}", .{msg});

    // Keep the selection on its milestone; while the filter hides it, only
    // the row shown moves.
    const found = for (v.rows, 0..) |n, r| {
        const hit =
            if (n >= snap.milestones.len) v.selected_none else if (v.selected_id) |*id| id.eql(
                snap.milestones[n].id,
            ) else false;
        if (hit) {
            v.selected = @intCast(r);
            break true;
        }
    } else false;
    if (v.selected >= v.rows.len) v.selected = @intCast(v.rows.len -| 1);
    if (v.rows.len > 0 and !found and v.selected_id == null and !v.selected_none) v.remember(snap);

    const lay = Layout.of(win.width);
    try drawHeader(s, f, win.child(.{ .y_off = 1, .height = 1 }), lay);
    const body = win.child(.{ .y_off = 2, .height = win.height -| 2 });
    v.visible = @max(body.height, 1);
    if (v.follow) {
        if (v.selected < v.scroll) v.scroll = v.selected;
        if (v.selected >= v.scroll + v.visible) v.scroll = v.selected - v.visible + 1;
        v.follow = false;
    }
    v.scroll = @min(v.scroll, @as(u32, @intCast(v.rows.len -| v.visible)));

    const only_none = v.rows.len <= 1 and snap.milestones.len == 0;
    if (v.rows.len == 0 or only_none) {
        const msg = if (snap.milestones.len == 0) "No milestones yet." else "No milestones " ++
            "match the filter.";
        const mid = body.height / 2;
        // The "no milestone" row, selectable, takes the last line.
        const shown = only_none and v.rows.len == 1 and body.height > 0;
        const free = if (shown) body.height - 1 else body.height;
        if (mid -| 1 < free) _ = ui.text(
            body,
            (body.width -| body.gwidth(msg)) / 2,
            mid -| 1,
            msg,
            .{ .fg = palette.muted },
        );
        if (mid + 1 < free) _ = try ui.button(
            f,
            body,
            (body.width -| 18) / 2,
            mid + 1,
            "+ New milestone",
            .{ .command = .new_milestone },
            ui.buttonStyle(true),
        );
        if (shown) {
            const row = body.child(.{ .y_off = body.height - 1, .height = 1 });
            drawRow(s, f, row, lay, data, v.rows[0], v.selected == 0);
            try f.hit(row, .{ .ms_row = 0 });
        }
        return;
    }

    var y: u16 = 0;
    while (y < body.height and v.scroll + y < v.rows.len) : (y += 1) {
        const r = v.scroll + y;
        const n = v.rows[r];
        const row_win = body.child(.{ .y_off = y, .height = 1 });
        drawRow(s, f, row_win, lay, data, n, r == v.selected);
        try f.hit(row_win, .{ .ms_row = r });
    }
    if (v.rows.len > body.height and body.height > 0) {
        const total: u32 = @intCast(v.rows.len);
        const pos: u16 = @intCast(
            @as(u64, v.scroll) * (body.height - 1) / @max(total - body.height, 1),
        );
        body.writeCell(
            body.width - 1,
            pos,
            .{ .char = .{ .grapheme = "┃" }, .style = .{ .fg = palette.faint } },
        );
    }
}

fn drawHeader(s: *AppState, f: ui.Frame, head: ui.Window, lay: Layout) Allocator.Error!void {
    const style: ui.Style = .{ .fg = palette.muted, .bold = true };
    var x: u16 = 0;
    for (std.enums.values(Column)) |c| {
        const w = lay.widths.get(c);
        if (w == 0) continue;
        const sort_key: ?mf.SortKey = switch (c) {
            .name => .name,
            .progress => .progress,
            .open => .open,
            .due => .due,
            .health => .health,
            else => null,
        };
        const name: []const u8 = switch (c) {
            .marker => "",
            .name => "Name",
            .progress => "Progress",
            .open => "Open",
            .done => "Done",
            .blocked => "Blk",
            .due => "Due",
            .health => "Health",
            .id => "ID",
        };
        const cell = head.child(.{ .x_off = x, .width = w, .height = 1 });
        const active = sort_key != null and sort_key.? == s.ms_query.key;
        var cx = ui.text(
            cell,
            0,
            0,
            name,
            if (active) .{ .fg = palette.accent, .bold = true } else style,
        );
        if (sort_key) |k| {
            if (active) cx += ui.text(
                cell,
                cx,
                0,
                if (s.ms_query.reverse) " ↑" else " ↓",
                .{ .fg = palette.accent },
            );
            try f.hit(cell, .{ .ms_sort = k });
        }
        x += w;
    }
}

fn drawRow(
    s: *AppState,
    f: ui.Frame,
    win: ui.Window,
    lay: Layout,
    data: mf.Data,
    n: u32,
    selected: bool,
) void {
    const snap = s.snap;
    const none = n >= snap.milestones.len;
    const sum = data.summaries[n];
    const bg: vaxis.Color = if (selected) palette.select_bg else .default;
    if (selected) win.fill(.{ .style = .{ .bg = bg } });
    const m = if (none) null else snap.milestones[n];
    const h: ?issuez.schedule.Health = if (none) null else data.health[n];
    const retired = if (m) |x| x.status == .retired else false;
    const dim = none or retired;

    var x: u16 = 0;
    for (std.enums.values(Column)) |c| {
        const w = lay.widths.get(c);
        if (w == 0) continue;
        const cell = win.child(.{ .x_off = x, .width = w -| 1, .height = 1 });
        x += w;
        switch (c) {
            .marker => {
                _ = ui.text(
                    cell,
                    0,
                    0,
                    if (selected) "▌" else " ",
                    .{ .fg = palette.accent, .bg = bg },
                );
                if (h) |hh| _ = ui.text(
                    cell,
                    1,
                    0,
                    ui.healthGlyph(hh),
                    .{ .fg = ui.healthColor(hh), .bg = bg },
                );
            },
            .name => if (m) |ms| {
                _ = ui.text(cell, 0, 0, ms.name, .{
                    .fg = if (dim) palette.muted else .default,
                    .bg = bg,
                    .bold = selected,
                    .strikethrough = retired,
                });
            } else {
                _ = ui.text(
                    cell,
                    0,
                    0,
                    "(no milestone)",
                    .{ .fg = palette.muted, .bg = bg, .italic = true },
                );
            },
            .progress => if (sum.leaves.total == 0) {
                _ = ui.text(cell, 0, 0, "\u{2014}", .{ .fg = palette.faint, .bg = bg });
            } else if (!none) {
                const active = if (s.milestones.in_progress) sum.leaves_active else 0;
                ui.progressBar(
                    cell,
                    0,
                    0,
                    lay.bar,
                    sum.leaves.closed,
                    active,
                    sum.leaves.total,
                    bg,
                );
                const pct = sum.leaves.closed * 100 / sum.leaves.total;
                _ = ui.text(
                    cell,
                    lay.bar + 1,
                    0,
                    f.fmt("{d: >3}%", .{pct}),
                    .{ .fg = palette.muted, .bg = bg },
                );
            },
            // Leaves, as the progress counts them.
            .open => _ = ui.text(
                cell,
                0,
                0,
                f.fmt("{d: >4}", .{mf.openLeaves(sum)}),
                .{ .fg = if (mf.openLeaves(sum) > 0) .default else palette.faint, .bg = bg },
            ),
            .done => _ = ui.text(
                cell,
                0,
                0,
                f.fmt("{d: >4}", .{sum.leaves.closed}),
                .{ .fg = palette.done, .bg = bg },
            ),
            .blocked => if (sum.blocked > 0) {
                _ = ui.text(
                    cell,
                    0,
                    0,
                    f.fmt("{d: >3}", .{sum.blocked}),
                    .{ .fg = palette.err, .bg = bg },
                );
            },
            .due => if (m) |ms| if (ms.due) |d| {
                var buf: [24]u8 = undefined;
                const rel = dates.relative(&buf, d, data.today);
                const late = d.order(data.today) == .lt and ms.status == .open;
                const soon = !late and data.today.daysBetween(d) <= 1 and ms.status == .open;
                var cx = ui.text(
                    cell,
                    0,
                    0,
                    f.fmt("{f}", .{d}),
                    .{ .fg = palette.muted, .bg = bg },
                );
                cx += 1;
                if (ms.status == .open) _ = ui.text(cell, cx, 0, f.fmt("{s}", .{rel}), .{
                    .fg = if (late) palette.err else if (soon) palette.medium else palette.faint,
                    .bg = bg,
                    .bold = late,
                });
            } else {
                _ = ui.text(cell, 0, 0, "\u{2014}", .{ .fg = palette.faint, .bg = bg });
            },
            .health => if (h) |hh| {
                _ = ui.text(
                    cell,
                    0,
                    0,
                    f.fmt("{s} {s}", .{ ui.healthGlyph(hh), hh.label() }),
                    .{ .fg = ui.healthColor(hh), .bg = bg },
                );
            },
            .id => if (m) |ms| {
                _ = ui.text(cell, 0, 0, shortId(ms.id), .{ .fg = palette.id, .bg = bg });
            },
        }
    }
}

pub fn key(s: *AppState, k: vaxis.Key) Allocator.Error!AppState.Action {
    const v = &s.milestones;
    const snap = s.snap;
    const sel: i64 = v.selected;
    const page: i64 = @max(v.visible, 2) - 1;
    if (k.matches(K.down, .{}) or k.matches('j', .{})) {
        v.moveTo(snap, sel + 1);
    } else if (k.matches(K.up, .{}) or k.matches('k', .{})) {
        v.moveTo(snap, sel - 1);
    } else if (k.matches(K.page_down, .{}) or k.matches('d', .{ .ctrl = true })) {
        v.moveTo(snap, sel + page);
    } else if (k.matches(K.page_up, .{}) or k.matches('u', .{ .ctrl = true })) {
        v.moveTo(snap, sel - page);
    } else if (k.matches(K.home, .{}) or k.matches('g', .{})) {
        v.moveTo(snap, 0);
    } else if (k.matches(K.end, .{}) or k.matches('G', .{})) {
        v.moveTo(snap, @as(i64, @intCast(v.rows.len)) - 1);
    } else if (k.matches('n', .{})) {
        modal_mod.newMilestone(s);
    } else if (k.matches('s', .{})) {
        modal_mod.openMilestoneSort(s);
    } else if (k.matches('S', .{})) {
        s.ms_query.reverse = !s.ms_query.reverse;
        v.follow = true;
    } else if (k.matches('f', .{})) {
        s.ms_query.scope = s.ms_query.scope.next();
        v.follow = true;
    } else if (k.matches('w', .{})) {
        v.in_progress = !v.in_progress;
        s.info(
            "progress bars {s}",
            .{if (v.in_progress) "show work in progress too" else "show done work only"},
        );
    } else if (k.matches(K.enter, .{}) or k.matches(K.right, .{}) or k.matches('l', .{})) {
        if (v.selected < v.rows.len) s.openMilestoneRow(v.rows[v.selected]);
    } else if (k.matches('T', .{})) {
        if (v.selected < v.rows.len) {
            const n = v.rows[v.selected];
            s.openTimeline(
                if (n < snap.milestones.len) .{ .id = .of(snap.milestones[n].id) } else .none,
            );
        }
    } else if (v.selectedMilestone(snap)) |n| {
        return milestoneKey(s, k, n);
    }
    return .none;
}

/// Keys on one milestone, shared with its detail view.
pub fn milestoneKey(s: *AppState, k: vaxis.Key, n: u32) AppState.Action {
    if (k.matches('e', .{})) {
        modal_mod.editMilestone(s, n);
    } else if (k.matches('r', .{})) {
        modal_mod.editMilestonePart(s, n, .name);
    } else if (k.matches('d', .{})) {
        modal_mod.editMilestonePart(s, n, .due);
    } else if (k.matches('c', .{})) {
        confirmComplete(s, n);
    } else if (k.matches('R', .{})) {
        confirmRetire(s, n);
    } else if (k.matches('o', .{})) {
        const m = s.snap.milestones[n];
        if (m.status == .open) {
            s.info("{s} is open already", .{m.name});
            return .none;
        }
        return .{
            .edit_milestone = .{ .id = .of(m.id), .edit = .{ .status = .open, .expect = m.tip } },
        };
    }
    return .none;
}

/// Completing needs every issue in it done: say so before trying.
pub fn confirmComplete(s: *AppState, n: u32) void {
    const m = s.snap.milestones[n];
    if (m.status == .completed) return s.info("{s} is completed already", .{m.name});
    const a = s.input_arena.allocator();
    const sum = (issuez.schedule.summarize(
        a,
        &s.snap.proj,
        s.snap.milestones,
        s.today,
    ) catch return s.fail("out of memory", .{}))[n];
    const action: AppState.Action = .{
        .edit_milestone = .{ .id = .of(m.id), .edit = .{ .status = .completed, .expect = m.tip } },
    };
    if (sum.open > 0) {
        const line = std.fmt.allocPrint(
            a,
            "{d} of its {d} issues are still open: close or move them first.",
            .{ sum.open, sum.issues },
        ) catch "";
        modal_mod.openConfirm(s, s.fmtInput("Complete {s}?", .{m.name}), &.{line}, &.{
            .{
                .label = "Show open issues",
                .action = .{ .show_milestone = .{ .id = .of(m.id), .open_only = true } },
            },
            .{ .label = "Cancel", .action = .none },
        });
        return;
    }
    const line = std.fmt.allocPrint(a, "All {d} issues are done.", .{sum.issues}) catch "";
    modal_mod.openConfirm(s, s.fmtInput("Complete {s}?", .{m.name}), &.{line}, &.{
        .{ .label = "Complete", .action = action },
        .{ .label = "Cancel", .action = .none },
    });
}

pub fn confirmRetire(s: *AppState, n: u32) void {
    const m = s.snap.milestones[n];
    if (m.status == .retired) return s.info("{s} is retired already", .{m.name});
    modal_mod.openConfirm(s, s.fmtInput("Retire {s}?", .{m.name}), &.{
        "For a milestone that won't be finished: its issues keep",
        "their link, but stop counting as in it, and none can be added.",
    }, &.{
        .{
            .label = "Retire",
            .action = .{
                .edit_milestone = .{
                    .id = .of(m.id),
                    .edit = .{ .status = .retired, .expect = m.tip },
                },
            },
        },
        .{ .label = "Cancel", .action = .none },
    });
}

pub fn click(s: *AppState, row: u32, double: bool) AppState.Action {
    const v = &s.milestones;
    if (row >= v.rows.len) return .none;
    v.moveTo(s.snap, row);
    if (double) s.openMilestoneRow(v.rows[row]);
    return .none;
}

test Layout {
    const t = std.testing;
    var total: u16 = 20;
    while (total <= 260) : (total += 1) {
        const lay = Layout.of(total);
        // Health only where it has room for its label.
        const health = lay.widths.get(.health);
        try t.expect(health == 0 or health == 12);
        try t.expectEqual(total >= 92, health > 0);
        // A date, a space and "123d late" in the cell.
        const due = lay.widths.get(.due);
        try t.expect(due == 0 or due - 1 >= "2026-12-01 123d late".len);
        var used: u16 = 0;
        for (std.enums.values(Column)) |c| used += lay.widths.get(c);
        try t.expect(lay.widths.get(.name) >= 8);
        if (total >= 50) try t.expect(used <= total);
    }
}

//! One milestone's work, or the issues in none: its progress, its
//! issues as a table, and quick ways to move them between milestones
//! (a menu, `[` and `]`, marks, a second pane to drag them to) and to
//! create issues in it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const issuez = @import("issuez");

const ui = @import("ui.zig");
const store = @import("store.zig");
const filter = @import("filter.zig");
const dates = issuez.format.dates;
const mf = @import("milestone_filter.zig");
const list_view = @import("list_view.zig");
const milestones_view = @import("milestones_view.zig");
const modal_mod = @import("modal.zig");
const AppState = @import("State.zig");

const Id = store.Id;
const Snapshot = store.Snapshot;
const Scope = filter.MilestoneScope;
const K = vaxis.Key;
const palette = ui.palette;
const shortId = issuez.format.uuid.shortId;
const none = std.math.maxInt(u32);

pub const State = struct {
    /// The milestone shown, or the issues in none.
    scope: Scope = .none,
    /// The second pane's, when split.
    other: Scope = .none,
    split: bool = false,
    /// The focused pane: 0 left, 1 right.
    pane: u16 = 0,
    panes: [2]list_view.State = .{ .{}, .{} },
    /// Marked issues, for moving several at once.
    marks: std.ArrayList(Id) = .empty,
    /// The issue scope to restore when leaving: this opening shows open
    /// issues only.
    saved_scope: ?filter.Scope = null,

    pub fn deinit(v: *State, gpa: Allocator) void {
        v.marks.deinit(gpa);
    }

    pub fn paneScope(v: *const State, p: u16) Scope {
        return if (p == 0) v.scope else v.other;
    }

    pub fn focusedScope(v: *const State) Scope {
        return if (v.split) v.paneScope(v.pane) else v.scope;
    }

    pub fn focused(v: *State) *list_view.State {
        return &v.panes[v.pane];
    }

    pub fn isMarked(v: *const State, id: []const u8) bool {
        for (v.marks.items) |*m| if (m.eql(id)) return true;
        return false;
    }

    fn toggleMark(v: *State, gpa: Allocator, id: []const u8) Allocator.Error!void {
        for (v.marks.items, 0..) |*m, n| if (m.eql(id)) {
            _ = v.marks.orderedRemove(n);
            return;
        };
        try v.marks.append(gpa, .of(id));
    }

    /// The marked issues, by position in the snapshot.
    fn markedSet(v: *const State, arena: Allocator, snap: *const Snapshot) Allocator.Error![]bool {
        const set = try arena.alloc(bool, snap.issues.len);
        @memset(set, false);
        for (v.marks.items) |*m| if (snap.find(m.slice())) |i| {
            set[i] = true;
        };
        return set;
    }

    /// Drops the marks of `ids`, once they moved.
    pub fn unmark(v: *State, arena: Allocator, snap: *const Snapshot, ids: []const Id) Allocator.Error!void {
        const set = try arena.alloc(bool, snap.issues.len);
        @memset(set, false);
        for (ids) |*id| if (snap.find(id.slice())) |i| {
            set[i] = true;
        };
        var kept: usize = 0;
        for (v.marks.items) |m| {
            const i = snap.find(m.slice());
            if (i != null and set[i.?]) continue;
            v.marks.items[kept] = m;
            kept += 1;
        }
        v.marks.shrinkRetainingCapacity(kept);
    }
};

/// The milestone's position in the catalog; null for none, or when it
/// went away.
pub fn milestoneOf(snap: *const Snapshot, scope: Scope) ?u32 {
    return switch (scope) {
        .none => null,
        .id => |id| snap.findMilestone(id.slice()),
    };
}

pub fn scopeName(snap: *const Snapshot, scope: Scope) []const u8 {
    return switch (scope) {
        .none => "(no milestone)",
        .id => |id| if (snap.findMilestone(id.slice())) |n| snap.milestones[n].name else "(gone)",
    };
}

/// Shows `scope`'s issues, from the left pane.
pub fn open(s: *AppState, scope: Scope) void {
    const v = &s.milestone;
    if (!v.scope.eql(scope)) {
        v.panes[0] = .{};
        v.marks.clearRetainingCapacity();
        leave(s);
    }
    v.scope = scope;
    v.pane = 0;
    if (v.split and v.other.eql(scope)) v.split = false;
}

/// This opening shows open issues only; the user's scope comes back on
/// leaving.
pub fn showOpenOnly(s: *AppState) void {
    if (s.milestone.saved_scope == null) s.milestone.saved_scope = s.mv_query.scope;
    s.mv_query.scope = .open;
}

/// Leaving the milestone: the scope `showOpenOnly` replaced comes back.
pub fn leave(s: *AppState) void {
    const saved = s.milestone.saved_scope orelse return;
    s.mv_query.scope = saved;
    s.milestone.saved_scope = null;
}

pub fn draw(s: *AppState, f: ui.Frame, win: ui.Window) Allocator.Error!void {
    const v = &s.milestone;
    const snap = s.snap;
    // Gone elsewhere: back to the milestones.
    if (v.scope == .id and milestoneOf(snap, v.scope) == null) {
        s.info("the milestone was removed elsewhere", .{});
        s.back();
        v.scope = .none;
        return s.drawView(f, win);
    }
    if (v.split and v.other == .id and milestoneOf(snap, v.other) == null) v.other = .none;

    if (!v.split) v.pane = 0;

    const data = try mf.Data.of(f.arena, snap, s.today, s.utc_offset_s);
    const head_rows: u16 = try drawHeader(s, f, win, data);
    const bar = win.child(.{ .y_off = head_rows, .height = 1 });
    const used = try list_view.drawFilterBar(s, f, bar, true);
    const body = win.child(.{ .y_off = head_rows + 1, .height = win.height -| (head_rows + 1) });

    // Drops go to the pane under the pointer.
    const over: ?u16 = if (s.drag) |d| if (d.moved) d.over else null else null;
    const from: ?u16 = if (s.drag) |d| d.card.column else null;
    if (!v.split) {
        try drawPane(s, f, body, 0, false);
    } else {
        const left_w = body.width / 2;
        const left = body.child(.{ .width = left_w -| 1 });
        const right = body.child(.{ .x_off = left_w, .width = body.width -| left_w });
        for (0..body.height) |y| _ = ui.text(body, left_w -| 1, @intCast(y), "│", .{ .fg = palette.faint });
        try drawPane(s, f, left, 0, over != null and over.? == 0 and from != null and from.? != 0);
        try drawPane(s, f, right, 1, over != null and over.? == 1 and from != null and from.? != 1);
    }

    // The marks the panes show are what moves; the others wait.
    if (v.marks.items.len > 0) {
        const shown = (try shownMarks(s, f.arena)).len;
        const hidden = v.marks.items.len - shown;
        const what = if (hidden > 0) f.fmt("{d} marked, {d} hidden", .{ shown, hidden }) else f.fmt("{d} marked", .{shown});
        _ = ui.text(bar, used + 2, 0, what, .{ .fg = palette.ok, .bg = palette.panel_bg, .bold = true });
    }
}

/// The focused pane's milestone: its name, state, dates and progress;
/// returns its rows.
fn drawHeader(s: *AppState, f: ui.Frame, win: ui.Window, data: mf.Data) Allocator.Error!u16 {
    const v = &s.milestone;
    const snap = s.snap;
    const n = milestoneOf(snap, v.focusedScope());
    const sum = data.summaries[n orelse snap.milestones.len];
    const top = win.child(.{ .height = 1 });
    var x: u16 = 0;
    x += try ui.button(f, top, x, 0, "← Milestones", .{ .command = .back }, ui.buttonStyle(false));
    x += 2;
    if (n) |idx| {
        const m = snap.milestones[idx];
        const h = data.health[idx];
        x += ui.text(top, x, 0, m.name, .{ .fg = palette.accent, .bold = true });
        x += 2;
        x += ui.text(top, x, 0, @tagName(m.status), .{ .fg = if (m.status == .open) palette.open else palette.done });
        if (m.due) |d| {
            var buf: [24]u8 = undefined;
            const rel = dates.relative(&buf, d, data.today);
            x += ui.text(top, x, 0, f.fmt(" · due {f} ({s})", .{ d, rel }), .{ .fg = palette.muted });
        } else x += ui.text(top, x, 0, " · no due date", .{ .fg = palette.faint });
        x += ui.text(top, x, 0, " · ", .{ .fg = palette.faint });
        x += ui.text(top, x, 0, f.fmt("{s} {s}", .{ ui.healthGlyph(h), h.label() }), .{ .fg = ui.healthColor(h) });
    } else {
        x += ui.text(top, x, 0, "Issues in no milestone", .{ .fg = palette.accent, .bold = true });
    }
    // Actions, right-aligned; the milestone's own with one.
    const acts = [_]struct { []const u8, ui.Command, bool }{
        .{ "+ Add issues", .ms_add, true },
        .{ "→ Move to…  m", .ms_move, true },
        .{ "e edit", .ms_edit, n != null },
        .{ "c complete", .ms_complete, n != null },
    };
    var w: u16 = 0;
    for (acts) |a| if (a[2]) {
        w += top.gwidth(a[0]) + 3;
    };
    if (top.width > x + w + 2) {
        var ax = top.width - w;
        for (acts, 0..) |a, idx| if (a[2]) {
            ax += try ui.button(f, top, ax, 0, a[0], .{ .command = a[1] }, ui.buttonStyle(idx == 0));
            ax += 1;
        };
    }

    // Progress and counts, of leaves.
    const line = win.child(.{ .y_off = 1, .height = 1 });
    var lx: u16 = 1;
    if (sum.leaves.total > 0) {
        const bw: u16 = @min(24, line.width / 4);
        const active = if (s.milestones.in_progress) sum.leaves_active else 0;
        ui.progressBar(line, lx, 0, bw, sum.leaves.closed, active, sum.leaves.total, .default);
        lx += bw + 1;
        lx += ui.text(line, lx, 0, f.fmt("{d}/{d} done", .{ sum.leaves.closed, sum.leaves.total }), .{ .bold = true });
    } else lx += ui.text(line, lx, 0, "no issues yet", .{ .fg = palette.muted });
    if (sum.leaves.total > 0) lx += ui.text(line, lx, 0, f.fmt(" · {d} open", .{mf.openLeaves(sum)}), .{ .fg = palette.muted });
    if (sum.blocked > 0) lx += ui.text(line, lx, 0, f.fmt(" · {d} blocked", .{sum.blocked}), .{ .fg = palette.err });
    if (sum.overdue > 0) lx += ui.text(line, lx, 0, f.fmt(" · {d} overdue", .{sum.overdue}), .{ .fg = palette.err });
    if (sum.estimate_total > 0) {
        lx += ui.text(line, lx, 0, f.fmt(" · est {s}, {s} done", .{
            ui.duration(f, @intCast(@min(sum.estimate_total, std.math.maxInt(u32)))),
            ui.duration(f, @intCast(@min(sum.estimate_done, std.math.maxInt(u32)))),
        }), .{ .fg = palette.muted });
    }
    var rows: u16 = 2;
    if (n) |idx| {
        const desc = snap.milestones[idx].description;
        if (desc.len > 0 and win.height > 14) {
            const first = try f.arena.dupe(u8, desc[0 .. std.mem.findAny(u8, desc, "\r\n") orelse desc.len]);
            for (first) |*c| if (c.* < 0x20 or c.* == 0x7f) {
                c.* = ' ';
            };
            _ = ui.text(win.child(.{ .y_off = 2, .height = 1 }), 1, 0, first, .{ .fg = palette.muted, .italic = true });
            rows += 1;
        }
    }
    return rows;
}

fn drawPane(s: *AppState, f: ui.Frame, win: ui.Window, p: u16, dropping: bool) Allocator.Error!void {
    const v = &s.milestone;
    const scope = v.paneScope(p);
    var q = s.currentQuery();
    q.milestone = scope;
    const rows = try filter.rows(f.arena, s.snap, q);
    var table = win;
    if (v.split) {
        // The pane's title, which picks its milestone in the right one.
        const title = win.child(.{ .height = 1 });
        const name = scopeName(s.snap, scope);
        const focused = v.pane == p;
        title.fill(.{ .style = .{ .bg = if (focused) palette.accent_bg else palette.bar_bg } });
        const st: ui.Style = .{ .fg = if (focused) .{ .index = 231 } else palette.muted, .bg = if (focused) palette.accent_bg else palette.bar_bg, .bold = focused };
        var count: u32 = 0;
        for (rows) |r| count += @intFromBool(!r.context);
        _ = ui.text(title, 1, 0, f.fmt("{s} · {d}", .{ name, count }), st);
        // The title first: the button on it takes its own clicks.
        try f.hit(title, .{ .mpane = p });
        if (p == 1) {
            const pick = "p pick ▾";
            _ = try ui.button(f, title, title.width -| (title.gwidth(pick) + 3), 0, pick, .{ .command = .pick_pane }, ui.buttonStyle(false));
        }
        table = win.child(.{ .y_off = 1, .height = win.height -| 1 });
    }
    const empty = if (rows.len == 0) emptyMessage(s, f, scope) else "";
    try list_view.drawTable(s, f, table, .{
        .l = &v.panes[p],
        .rows = rows,
        .query = q,
        .pane = p,
        .marks = v.marks.items,
        .focused = !v.split or v.pane == p,
        .empty = empty,
        .drop = dropping,
    });
}

/// Why a pane has no rows: nothing in it, or nothing that the filter
/// and the scope let through.
fn emptyMessage(s: *AppState, f: ui.Frame, scope: Scope) []const u8 {
    const snap = s.snap;
    var total: u32 = 0;
    for (snap.issues, 0..) |issue, i| {
        if (!issue.deleted and scope.holds(snap, @intCast(i))) total += 1;
    }
    if (total > 0) return f.fmt("None of the {d} issues here match: f changes the scope, / the filter.", .{total});
    const n = milestoneOf(snap, scope) orelse return "Nothing outside the milestones.";
    const status = snap.milestones[n].status;
    if (status != .open) return f.fmt("No issues in this milestone: it is {s}.", .{@tagName(status)});
    return "No issues in this milestone yet: n adds one.";
}

// Moving.

/// The focused pane's selected row.
fn selectedRow(v: *State) ?filter.Row {
    const l = v.focused();
    return if (l.selected < l.rows.len) l.rows[l.selected] else null;
}

/// The marked issues the panes show, not as context: the ones an action
/// is for.
fn shownMarks(s: *AppState, arena: Allocator) Allocator.Error![]const Id {
    const v = &s.milestone;
    const snap = s.snap;
    const shown = try arena.alloc(bool, snap.issues.len);
    @memset(shown, false);
    const panes: usize = if (v.split) 2 else 1;
    for (v.panes[0..panes]) |*l| {
        for (l.rows) |r| if (!r.context) {
            shown[r.issue] = true;
        };
    }
    var out: std.ArrayList(Id) = .empty;
    for (v.marks.items) |m| if (snap.find(m.slice())) |i| if (shown[i]) {
        try out.append(arena, m);
    };
    return out.items;
}

/// The issues an action is for: the marked ones shown, else the
/// selected. In the modal arena, which a dialog opened afterwards keeps.
/// Empty when there are none, after saying why.
fn targets(s: *AppState) []const Id {
    const v = &s.milestone;
    const a = s.modalArena();
    const marked = shownMarks(s, a) catch &.{};
    if (marked.len > 0) return marked;
    const r = selectedRow(v) orelse {
        s.info("no issue selected", .{});
        return &.{};
    };
    const id = s.snap.issues[r.issue].id;
    if (r.context) {
        s.info("#{s} isn't in {s}: it shows for its sub-issues", .{ shortId(id), scopeName(s.snap, v.focusedScope()) });
        return &.{};
    }
    const one = a.alloc(Id, 1) catch return &.{};
    one[0] = .of(id);
    return one;
}

/// The issue whose own link gives `i` its milestone: itself, or the
/// nearest ancestor that doesn't inherit.
pub fn linkOwner(snap: *const Snapshot, i: u32) u32 {
    var cur = i;
    var guard: u32 = 0;
    while (filter.inherits(snap, cur) and guard < 64) : (guard += 1) {
        const p = snap.proj.parent[cur];
        if (p == none) break;
        cur = p;
    }
    return cur;
}

fn linkLabel(snap: *const Snapshot, link: store.MilestoneLink) []const u8 {
    return switch (link) {
        .none => "no milestone",
        .inherit => "the parent's milestone",
        .id => |id| if (snap.findMilestone(id)) |n| snap.milestones[n].name else "?",
    };
}

fn scopeLink(s: *AppState, scope: Scope) store.MilestoneLink {
    return switch (scope) {
        .none => .none,
        .id => |id| .{ .id = s.modalArena().dupe(u8, id.slice()) catch "" },
    };
}

/// Moves `ids` as `link` says, asking first when some of them only
/// inherit their milestone: moving them alone overrides their parent.
/// Only open milestones take work.
pub fn requestMove(s: *AppState, ids: []const Id, link: store.MilestoneLink) AppState.Action {
    if (ids.len == 0) return .none;
    const snap = s.snap;
    if (link == .id) if (snap.findMilestone(link.id)) |n| if (snap.milestones[n].status != .open) {
        s.fail("{s} is {s}: reopen it to add work (o)", .{ snap.milestones[n].name, @tagName(snap.milestones[n].status) });
        return .none;
    };
    const a = s.modalArena();
    const seen = a.alloc(bool, snap.issues.len) catch return .none;
    @memset(seen, false);
    const marked = s.milestone.markedSet(a, snap) catch return .none;
    var all_marked = true;
    var inherited: u32 = 0;
    var owners: std.ArrayList(Id) = .empty;
    for (ids) |id| {
        const i = snap.find(id.slice()) orelse continue;
        if (!marked[i]) all_marked = false;
        const o = linkOwner(snap, i);
        if (o != i) inherited += 1;
        if (seen[o]) continue;
        seen[o] = true;
        owners.append(a, .of(snap.issues[o].id)) catch {};
    }
    // Moved, the marks they came from are done.
    const unmark: []const Id = if (all_marked) ids else &.{};
    const action: AppState.Action = .{ .move_issues = .{ .ids = ids, .link = link, .unmark = unmark } };
    if (inherited == 0 or link == .inherit) return action;
    const what = if (ids.len == 1) "It inherits its milestone from a parent." else s.fmtInput("{d} of them inherit their milestone from a parent.", .{inherited});
    modal_mod.openConfirm(s, s.fmtInput("Move to {s}", .{linkLabel(snap, link)}), &.{
        what,
        "Moving alone gives them a link of their own; moving the",
        "parents moves every sub-issue that inherits too.",
    }, &.{
        .{ .label = "Alone", .action = action },
        .{ .label = "With the parents", .action = .{ .move_issues = .{ .ids = owners.items, .link = link, .unmark = unmark } } },
        .{ .label = "Cancel", .action = .none },
    });
    return .none;
}

/// Where the selected or marked issues can go: a list to search.
pub fn openMoveMenu(s: *AppState) void {
    const snap = s.snap;
    s.closeModal();
    const ids = targets(s);
    if (ids.len == 0) return;
    const a = s.modalArena();
    var items: std.ArrayList(modal_mod.Picker.Item) = .empty;
    for (snap.milestones) |m| {
        if (m.status == .retired) continue;
        const due = if (m.due) |d| std.fmt.allocPrint(a, "due {f}", .{d}) catch "" else "no due date";
        items.append(a, .{
            .label = a.dupe(u8, m.name) catch "",
            .detail = if (m.status == .completed) "completed" else due,
            .value = a.dupe(u8, m.id) catch "",
            .current = allIn(snap, ids, .{ .id = .of(m.id) }),
            .disabled = m.status == .completed,
        }) catch {};
    }
    items.append(a, .{ .label = "(no milestone)", .value = modal_mod.link_none, .current = allIn(snap, ids, .none) }) catch {};
    const all_children = for (ids) |id| {
        const i = snap.find(id.slice()) orelse continue;
        if (snap.proj.parent[i] == none) break false;
    } else true;
    if (all_children) items.append(a, .{ .label = "(inherit from parent)", .value = modal_mod.link_inherit }) catch {};
    // The first that isn't where they are now.
    var selected: u32 = 0;
    for (items.items, 0..) |it, n| if (!it.current and !it.disabled) {
        selected = @intCast(n);
        break;
    };
    const title = if (ids.len == 1)
        std.fmt.allocPrint(a, "Move #{s} to", .{shortId(ids[0].slice())}) catch "Move to"
    else
        std.fmt.allocPrint(a, "Move {d} issues to", .{ids.len}) catch "Move to";
    s.openModal(.{ .picker = .{ .title = title, .items = items.items, .selected = selected, .purpose = .{ .move = ids }, .verb = "Move" } });
}

/// Every one of `ids` is in `scope` already.
fn allIn(snap: *const Snapshot, ids: []const Id, scope: Scope) bool {
    for (ids) |*id| {
        const i = snap.find(id.slice()) orelse return false;
        if (!scope.holds(snap, i)) return false;
    }
    return true;
}

/// Existing issues to bring into the focused pane's milestone: every
/// issue elsewhere, open ones first, to search and mark.
pub fn openAddPicker(s: *AppState) void {
    const snap = s.snap;
    const scope = s.milestone.focusedScope();
    if (milestoneOf(snap, scope)) |n| if (snap.milestones[n].status != .open) {
        return s.fail("{s} is {s}: reopen it to add work (o)", .{ snap.milestones[n].name, @tagName(snap.milestones[n].status) });
    };
    s.closeModal();
    const a = s.modalArena();
    var order: std.ArrayList(u32) = .empty;
    for (snap.issues, 0..) |issue, n| {
        const i: u32 = @intCast(n);
        if (issue.deleted or scope.holds(snap, i)) continue;
        order.append(a, i) catch {};
    }
    // Open first, then the most recently touched.
    std.mem.sort(u32, order.items, snap, struct {
        fn lt(sn: *const Snapshot, x: u32, y: u32) bool {
            const dx = sn.isDone(x);
            const dy = sn.isDone(y);
            if (dx != dy) return !dx;
            return sn.issues[x].updated > sn.issues[y].updated;
        }
    }.lt);
    const items = a.alloc(modal_mod.Picker.Item, order.items.len) catch return s.fail("out of memory", .{});
    for (order.items, items) |i, *it| {
        const issue = snap.issues[i];
        const where = snap.milestoneName(i) orelse "no milestone";
        it.* = .{
            .label = std.fmt.allocPrint(a, "#{s} {s}", .{ shortId(issue.id), issue.title }) catch "",
            .detail = std.fmt.allocPrint(a, "{s}{s}", .{ where, if (filter.inherits(snap, i)) " (inherited)" else "" }) catch "",
            .value = a.dupe(u8, issue.id) catch "",
            .done = snap.isDone(i),
        };
    }
    if (items.len == 0) return s.info("every issue is in {s} already", .{scopeName(snap, scope)});
    const title = std.fmt.allocPrint(a, "Add issues to {s}", .{scopeName(snap, scope)}) catch "Add issues";
    s.openModal(.{ .picker = .{ .title = title, .items = items, .multi = true, .purpose = .{ .add_to = scope }, .verb = "Add" } });
}

/// The open milestone before or after `scope` in due order; none comes
/// before the first.
fn neighbour(snap: *const Snapshot, scope: Scope, by: i32) ?Scope {
    var pos: i32 = -1;
    var count: i32 = 0;
    for (snap.milestones) |m| {
        if (m.status != .open) continue;
        if (scope == .id and scope.id.eql(m.id)) pos = count;
        count += 1;
    }
    const next = pos + by;
    if (next < -1 or next >= count) return null;
    if (next == -1) return .none;
    var seen: i32 = 0;
    for (snap.milestones) |m| {
        if (m.status != .open) continue;
        if (seen == next) return .{ .id = .of(m.id) };
        seen += 1;
    }
    return null;
}

fn step(s: *AppState, delta: i32) AppState.Action {
    s.closeModal();
    const ids = targets(s);
    if (ids.len == 0) return .none;
    const to = neighbour(s.snap, s.milestone.focusedScope(), delta) orelse {
        s.info("no open milestone {s} this one", .{if (delta > 0) "after" else "before"});
        return .none;
    };
    return requestMove(s, ids, scopeLink(s, to));
}

pub fn key(s: *AppState, k: vaxis.Key) Allocator.Error!AppState.Action {
    const v = &s.milestone;
    const snap = s.snap;
    if (k.matches(K.escape, .{}) or k.matches(K.left, .{}) or k.matches('h', .{})) {
        if (k.matches(K.escape, .{}) and v.marks.items.len > 0) {
            v.marks.clearRetainingCapacity();
            return .none;
        }
        s.back();
        return .none;
    }
    if (v.split and k.matches(K.tab, .{})) {
        v.pane = 1 - v.pane;
        return .none;
    }
    if (k.matches(K.space, .{})) {
        const r = selectedRow(v) orelse return .none;
        const id = snap.issues[r.issue].id;
        if (r.context) {
            s.info("#{s} isn't in {s}: it shows for its sub-issues", .{ shortId(id), scopeName(snap, v.focusedScope()) });
            return .none;
        }
        try v.toggleMark(s.gpa, id);
        v.focused().moveTo(snap, @as(i64, v.focused().selected) + 1);
        return .none;
    }
    if (k.matches('*', .{})) {
        const marked = try v.markedSet(s.input_arena.allocator(), snap);
        for (v.focused().rows) |r| if (!r.context and !marked[r.issue]) {
            marked[r.issue] = true;
            try v.marks.append(s.gpa, .of(snap.issues[r.issue].id));
        };
        return .none;
    }
    if (k.matches('u', .{})) {
        v.marks.clearRetainingCapacity();
        return .none;
    }
    if (k.matches('m', .{})) {
        openMoveMenu(s);
        return .none;
    }
    if (k.matches('+', .{}) or k.matches('A', .{})) {
        openAddPicker(s);
        return .none;
    }
    if (k.matches(']', .{})) return step(s, 1);
    if (k.matches('[', .{})) return step(s, -1);
    if (k.matches('v', .{})) {
        v.split = !v.split;
        if (v.split and v.other.eql(v.scope)) v.other = if (v.scope == .none) (neighbour(snap, .none, 1) orelse .none) else .none;
        v.pane = 0;
        return .none;
    }
    if (v.split and (k.matches('>', .{}) or k.matches('<', .{}))) {
        const to: u16 = if (k.matches('>', .{})) 1 else 0;
        if (to == v.pane) return .none;
        s.closeModal();
        return requestMove(s, targets(s), scopeLink(s, v.paneScope(to)));
    }
    if (k.matches('p', .{})) {
        openPaneMenu(s);
        return .none;
    }
    if (k.matches('T', .{})) {
        s.openTimeline(v.focusedScope());
        return .none;
    }
    if (k.matches('N', .{})) {
        quickAdd(s);
        return .none;
    }
    if (list_view.tableKey(s, v.focused(), k)) |act| return act;
    if (milestoneOf(snap, v.focusedScope())) |n| return milestones_view.milestoneKey(s, k, n);
    return .none;
}

/// Picks the right pane's milestone, splitting once one is chosen. Only
/// open milestones: the pane is for moving work into.
pub fn openPaneMenu(s: *AppState) void {
    const snap = s.snap;
    const v = &s.milestone;
    s.closeModal();
    const a = s.modalArena();
    var options: std.ArrayList(modal_mod.Menu.Option) = .empty;
    for (snap.milestones) |m| {
        if (m.status == .retired) continue;
        options.append(a, .{
            .label = a.dupe(u8, m.name) catch "",
            .value = a.dupe(u8, m.id) catch "",
            .current = v.split and v.other == .id and v.other.id.eql(m.id),
            .disabled = m.status == .completed,
        }) catch {};
    }
    options.append(a, .{ .label = "(no milestone)", .value = modal_mod.link_none, .current = v.split and v.other == .none }) catch {};
    var selected: u16 = 0;
    for (options.items, 0..) |o, n| if (o.current) {
        selected = @intCast(n);
    };
    s.openModal(.{ .menu = .{ .title = "Second pane shows", .options = options.items, .selected = selected, .purpose = .pane_pick } });
}

/// Titles one after another, each created in the milestone.
fn quickAdd(s: *AppState) void {
    const scope = s.milestone.focusedScope();
    if (milestoneOf(s.snap, scope)) |n| if (s.snap.milestones[n].status != .open) {
        return s.fail("{s} is {s}: reopen it to add work (o)", .{ s.snap.milestones[n].name, @tagName(s.snap.milestones[n].status) });
    };
    s.closeModal();
    const title = s.modalArena().dupe(u8, s.fmtInput("Quick add to {s}", .{scopeName(s.snap, scope)})) catch "Quick add";
    s.openModal(.{ .prompt = .{
        .title = title,
        .hint = "a title, ⏎ creates it and asks for the next; esc when done",
        .purpose = .{ .quick_add = scope },
    } });
}

pub fn click(s: *AppState, row: ui.Target.Card, double: bool) AppState.Action {
    const v = &s.milestone;
    if (row.column > 1) return .none;
    v.pane = row.column;
    const l = &v.panes[row.column];
    if (row.index >= l.rows.len) return .none;
    l.moveTo(s.snap, row.index);
    const i = l.rows[row.index].issue;
    if (double) {
        s.openIssue(s.snap.issues[i].id);
        return .none;
    }
    // A context row isn't in the pane's milestone: nothing to drag out.
    if (l.rows[row.index].context) return .none;
    s.drag = .{ .card = row, .id = .of(s.snap.issues[i].id) };
    return .none;
}

pub fn clickPane(s: *AppState, p: u16) void {
    if (p <= 1) s.milestone.pane = p;
}

pub fn wheel(s: *AppState, found: ?ui.Hits.Found, delta: i32) void {
    const v = &s.milestone;
    const p: u16 = if (found) |h| switch (h.target) {
        .mrow => |r| r.column,
        .mpane => |x| x,
        else => v.pane,
    } else v.pane;
    if (p <= 1) v.panes[p].scrollBy(delta);
}

/// A row dropped on the other pane: it moves there, with the marks when
/// it is one of them.
pub fn drop(s: *AppState, d: AppState.Drag) AppState.Action {
    const v = &s.milestone;
    const to = d.over orelse return .none;
    if (!v.split or to > 1 or to == d.card.column) return .none;
    v.pane = to;
    s.closeModal();
    const ids = if (v.isMarked(d.id.slice())) targets(s) else blk: {
        const one = s.modalArena().alloc(Id, 1) catch return .none;
        one[0] = d.id;
        break :blk one;
    };
    return requestMove(s, ids, scopeLink(s, v.paneScope(to)));
}

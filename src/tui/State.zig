//! Everything the TUI shows and how input changes it, without the
//! repository: input returns an `Action` for `App` to carry out against
//! the store. Views read the snapshot through `snap`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const issuez = @import("issuez");

const ui = @import("ui.zig");
const filter = @import("filter.zig");
const store = @import("store.zig");
const text_mod = @import("text.zig");
const list_view = @import("list_view.zig");
const board_view = @import("board_view.zig");
const detail_view = @import("detail_view.zig");
const milestones_view = @import("milestones_view.zig");
const milestone_view = @import("milestone_view.zig");
const milestone_filter = @import("milestone_filter.zig");
const timeline_view = @import("timeline_view.zig");
const sync_job = @import("sync_job.zig");
const modal_mod = @import("modal.zig");

const State = @This();
const Id = store.Id;
const Snapshot = store.Snapshot;
const TextArea = text_mod.TextArea;
pub const Modal = modal_mod.Modal;
pub const Field = modal_mod.Field;

const K = vaxis.Key;

pub const Input = union(enum) {
    key: vaxis.Key,
    mouse: vaxis.Mouse,
    paste_start,
    paste_end,
};

/// What `App` does with the repository. Strings live in the open modal's
/// arena, or are static; `move`'s column name is the snapshot's, which
/// the write replaces.
pub const Action = union(enum) {
    none,
    quit,
    reload,
    create: store.CreateInput,
    edit: struct { id: Id, spec: issuez.engine.EditSpec },
    milestone: struct { id: Id, name: []const u8 },
    milestone_link: struct { id: Id, link: store.MilestoneLink },
    state: struct { id: Id, state: []const u8 },
    comment: struct { id: Id, text: []const u8 },
    /// Close an open issue, reopen a done one.
    toggle: Id,
    /// To a board column: a workflow state, or done.
    move: struct { id: Id, column: []const u8, done: bool },
    create_milestone: store.MilestoneInput,
    edit_milestone: struct { id: Id, edit: store.MilestoneEdit },
    /// The milestone view, for a catalog milestone.
    show_milestone: struct { id: Id, open_only: bool = false },
    /// Several issues to a milestone, all or none. `unmark`: the marks
    /// they came from, cleared once moved.
    move_issues: struct { ids: []const Id, link: store.MilestoneLink, unmark: []const Id = &.{} },
    /// Several issues under one parent, all or none.
    adopt: struct { parent: Id, ids: []const Id },
    /// `create`, keeping the quick-add prompt open for the next one.
    quick_create: store.CreateInput,
    /// Into the timeline's draft.
    stage: @import("timeline_draft.zig").Op,
    /// Writes the timeline's draft, all or none.
    apply_draft,
    /// Applies or discards the draft, then goes on to `then`.
    leave_timeline: struct { apply: bool, then: timeline_view.edit.Leave },
    /// With the remote, in the background.
    sync: sync_job.Kind,
    open_sync_panel,
    /// A quarantined issue or milestone, by full ID.
    resolve: struct { id: Id, how: issuez.sync.Resolution },
    /// The remote syncs go to; in the modal arena.
    choose_remote: []const u8,
};

/// Where syncing stands, for the badge and the panel.
pub const SyncUi = struct {
    running: ?sync_job.Kind = null,
    auto: bool = false,
    phase: ?issuez.sync.Phase = null,
    last: ?sync_job.Summary = null,
    /// Unix seconds the last one finished.
    last_at: i64 = 0,
    /// The last one failed and nobody looked yet: the badge is red.
    failed: bool = false,
    /// The last automatic one started, unix seconds.
    auto_at: i64 = 0,
    /// The last fetch that worked: when, and from where.
    fetched_at: i64 = 0,
    fetched_buf: [256]u8 = undefined,
    fetched_len: u16 = 0,
    /// The remote of the one running.
    remote_buf: [256]u8 = undefined,
    remote_len: u16 = 0,

    pub fn fetchedFrom(u: *const SyncUi) []const u8 {
        return u.fetched_buf[0..u.fetched_len];
    }

    pub fn setFetched(u: *SyncUi, remote: []const u8, at: i64) void {
        u.fetched_len = @intCast(@min(remote.len, u.fetched_buf.len));
        @memcpy(u.fetched_buf[0..u.fetched_len], remote[0..u.fetched_len]);
        u.fetched_at = at;
    }

    pub fn runningRemote(u: *const SyncUi) []const u8 {
        return u.remote_buf[0..u.remote_len];
    }

    pub fn setRunningRemote(u: *SyncUi, name: []const u8) void {
        u.remote_len = @intCast(@min(name.len, u.remote_buf.len));
        @memcpy(u.remote_buf[0..u.remote_len], name[0..u.remote_len]);
    }
};

gpa: Allocator,
snap: *const Snapshot,
view: ui.View = .list,
/// The views to go back to, the last one first: from an issue to the
/// milestone it was opened from, to the milestones.
nav: [max_nav]ui.View = undefined,
nav_len: u8 = 0,
/// Without the text, which is `search`'s: see `currentQuery`.
query: filter.Query = .{},
search: TextArea = .init(false),
search_focused: bool = false,
list: list_view.State = .{},
board: board_view.State = .{},
detail: detail_view.State = .{},
milestones: milestones_view.State = .{},
/// The milestones view's query, without the text, which is `ms_search`'s.
ms_query: milestone_filter.Query = .{},
ms_search: TextArea = .init(false),
milestone: milestone_view.State = .{},
/// The milestone view's issue query, in tree mode first: milestones
/// follow the tree. Its text is `mv_search`'s.
mv_query: filter.Query = .{ .tree = true },
mv_search: TextArea = .init(false),
timeline: timeline_view.State = .{},
/// The timeline's issue query, by start date; its text is `tl_search`'s.
tl_query: filter.Query = .{ .tree = true, .key = .start },
tl_search: TextArea = .init(false),
/// For dates typed as `+3d` and for what is late: the date of the last
/// frame drawn, where the user is.
today: issuez.format.fields.Date = .{ .year = 1970, .month = 1, .day = 1 },
/// Seconds the local clock is ahead of UTC, set before each frame: it
/// changes with summer time.
utc_offset_s: i32 = 0,
sync: SyncUi = .{},
/// Unix seconds of the last frame drawn.
now_s: i64 = 0,
/// A second q or ctrl+c quits while a sync runs.
quit_armed: bool = false,
modal: ?Modal = null,
/// The issue the open modal edits, at the tip it showed when it opened:
/// what its write expects, so a change made meanwhile isn't overwritten.
modal_tip: ?ModalTip = null,
/// Strings of the open modal and its action.
modal_arena: std.heap.ArenaAllocator,
hits: ui.Hits = .{},
/// One frame's strings, rows and columns. Input reads the rows and
/// columns of the frame last drawn: what the user sees.
frame_arena: std.heap.ArenaAllocator,
/// For arena use while handling input, reset per input.
input_arena: std.heap.ArenaAllocator,
status_buf: [512]u8 = undefined,
status_len: u16 = 0,
status_kind: enum { info, err } = .info,
last_click: ?Click = null,
drag: ?Drag = null,
pasting: bool = false,
/// A second Escape in a form with text in it discards it.
discard_armed: bool = false,
/// The last frame showed nothing but "Terminal too small": keys act on
/// nothing but quitting.
too_small: bool = false,

const Click = struct { target: ui.Target, ms: i64 };

pub const ModalTip = struct { id: Id, tip: ?issuez.engine.Oid };

/// A card held with the mouse.
pub const Drag = struct {
    card: ui.Target.Card,
    id: Id,
    /// The column under the pointer.
    over: ?u16 = null,
    moved: bool = false,
};

pub const double_click_ms = 400;
const max_nav = 8;

pub fn init(gpa: Allocator, snap: *const Snapshot) State {
    return .{
        .gpa = gpa,
        .snap = snap,
        .modal_arena = .init(gpa),
        .frame_arena = .init(gpa),
        .input_arena = .init(gpa),
    };
}

pub fn deinit(s: *State) void {
    s.closeModal();
    s.search.deinit(s.gpa);
    s.ms_search.deinit(s.gpa);
    s.mv_search.deinit(s.gpa);
    s.tl_search.deinit(s.gpa);
    s.timeline.deinit(s.gpa);
    s.milestone.deinit(s.gpa);
    s.hits.deinit(s.gpa);
    s.detail.deinit(s.gpa);
    s.modal_arena.deinit();
    s.frame_arena.deinit();
    s.input_arena.deinit();
    s.* = undefined;
}

// Status line.

pub fn info(s: *State, comptime format: []const u8, args: anytype) void {
    s.setStatus(.info, format, args);
}

pub fn fail(s: *State, comptime format: []const u8, args: anytype) void {
    s.setStatus(.err, format, args);
}

/// A message too long for the buffer is cut, ending in `…`.
fn setStatus(s: *State, kind: @TypeOf(s.status_kind), comptime format: []const u8, args: anytype) void {
    const ellipsis = "…";
    var w: std.Io.Writer = .fixed(&s.status_buf);
    var len: usize = 0;
    if (w.print(format, args)) |_| {
        len = w.buffered().len;
    } else |_| {
        // Back to a codepoint boundary with room for the ellipsis.
        len = s.status_buf.len - ellipsis.len;
        while (len > 0 and (s.status_buf[len] & 0xC0) == 0x80) len -= 1;
        @memcpy(s.status_buf[len..][0..ellipsis.len], ellipsis);
        len += ellipsis.len;
    }
    s.status_len = @intCast(len);
    s.status_kind = kind;
}

pub fn status(s: *const State) []const u8 {
    return s.status_buf[0..s.status_len];
}

pub fn clearStatus(s: *State) void {
    s.status_len = 0;
}

// Modals.

/// Keeps the modal arena: `m` was built in it. Openers that replace a
/// dialog call `closeModal` before building the new one.
pub fn openModal(s: *State, m: Modal) void {
    if (s.modal) |*old| old.deinit(s.gpa);
    s.modal = m;
    s.discard_armed = false;
    s.modal_tip = if (m.issue()) |id| .{ .id = id, .tip = s.tipOf(id.slice()) } else null;
}

pub fn closeModal(s: *State) void {
    if (s.modal) |*m| m.deinit(s.gpa);
    s.modal = null;
    s.modal_tip = null;
    _ = s.modal_arena.reset(.retain_capacity);
    s.discard_armed = false;
}

/// The issue's tip in the snapshot shown; null when it isn't there.
pub fn tipOf(s: *const State, id: []const u8) ?issuez.engine.Oid {
    const i = s.snap.find(id) orelse return null;
    return s.snap.issues[i].tip;
}

/// What a write to `id` expects: the tip the open modal showed, else the
/// one shown now.
pub fn expectedTip(s: *const State, id: []const u8) ?issuez.engine.Oid {
    if (s.modal_tip) |t| if (t.id.eql(id)) return t.tip;
    return s.tipOf(id);
}

/// Whether the issue the open modal edits changed since it opened.
pub fn modalStale(s: *const State) bool {
    const t = s.modal_tip orelse return false;
    const now = s.tipOf(t.id.slice());
    if (t.tip == null or now == null) return t.tip != null or now != null;
    return !t.tip.?.eql(now.?);
}

/// After the user was told the issue changed: the next save is meant to
/// replace what is there now.
pub fn rebaseModal(s: *State) void {
    if (s.modal == null) return;
    if (s.modal_tip) |*t| t.tip = s.tipOf(t.id.slice());
    modal_mod.rebase(s);
}

pub fn modalArena(s: *State) Allocator {
    return s.modal_arena.allocator();
}

// Navigation.

fn push(s: *State, v: ui.View) void {
    if (s.nav_len == max_nav) {
        std.mem.copyForwards(ui.View, s.nav[0 .. max_nav - 1], s.nav[1..max_nav]);
        s.nav_len -= 1;
    }
    s.nav[s.nav_len] = v;
    s.nav_len += 1;
}

fn pop(s: *State) ?ui.View {
    if (s.nav_len == 0) return null;
    s.nav_len -= 1;
    return s.nav[s.nav_len];
}

pub fn openIssue(s: *State, id: []const u8) void {
    if (!timeline_view.edit.mayLeave(s, .{ .issue = .of(id) })) return;
    if (s.view != .detail) {
        s.push(s.view);
        s.detail.clear();
    }
    s.detail.push(id);
    s.view = .detail;
    s.search_focused = false;
}

/// One milestone's view, or the issues in none.
pub fn openMilestone(s: *State, scope: filter.MilestoneScope) void {
    if (!timeline_view.edit.mayLeave(s, .{ .milestone = scope })) return;
    if (s.view != .milestone) s.push(s.view);
    milestone_view.open(s, scope);
    s.view = .milestone;
    s.search_focused = false;
}

/// The timeline, at a milestone's group.
pub fn openTimeline(s: *State, scope: filter.MilestoneScope) void {
    s.switchView(.timeline);
    timeline_view.showGroup(s, scope);
}

/// A milestones view row: a milestone, or none past the catalog.
pub fn openMilestoneRow(s: *State, n: u32) void {
    if (n >= s.snap.milestones.len) return s.openMilestone(.none);
    s.openMilestone(.{ .id = .of(s.snap.milestones[n].id) });
}

pub fn back(s: *State) void {
    switch (s.view) {
        .detail => if (s.detail.pop()) return,
        .milestone => milestone_view.leave(s),
        else => return,
    }
    s.view = s.pop() orelse if (s.view == .milestone) .milestones else .list;
    s.search_focused = false;
}

/// Quits, asking once while a sync runs: quitting stops it.
pub fn quitUnlessSyncing(s: *State) Action {
    const kind = s.sync.running orelse return .quit;
    if (s.quit_armed) return .quit;
    s.quit_armed = true;
    s.fail("a {s} with {s} is running: q again quits and stops it", .{ kind.label(), s.sync.runningRemote() });
    return .none;
}

/// What the timeline's draft would change, now: a frame may not have
/// counted it, as on a terminal too small.
fn timelineChanges(s: *State) usize {
    const t = &s.timeline;
    if (!t.editing) return 0;
    const plan = t.draft.plan(s.input_arena.allocator(), s.snap) catch return t.draft.len;
    return plan.count();
}

/// To a tab, unless the timeline's draft holds the user back.
pub fn goTo(s: *State, v: ui.View) void {
    if (v == s.view) return;
    if (!timeline_view.edit.mayLeave(s, .{ .view = v })) return;
    s.switchView(v);
}

/// To a tab: what was open behind it is forgotten.
pub fn switchView(s: *State, v: ui.View) void {
    assert(v != .detail and v != .milestone);
    milestone_view.leave(s);
    s.view = v;
    s.nav_len = 0;
    s.search_focused = false;
}

/// The issue the current view points at, if any.
pub fn current(s: *const State) ?u32 {
    return switch (s.view) {
        .list => s.list.selectedIssue(),
        .board => s.board.selectedIssue(),
        .milestones => null,
        .timeline => s.timeline.selectedIssue(),
        .milestone => s.milestone.panes[s.milestone.pane].selectedIssue(),
        .detail => s.detail.issue(s.snap),
    };
}

/// The issue query of the view: the milestone view has its own.
pub fn issueQuery(s: *State) *filter.Query {
    return switch (s.view) {
        .milestone => &s.mv_query,
        .timeline => &s.tl_query,
        else => &s.query,
    };
}

/// The filter text box of the view.
pub fn searchBox(s: *State) *TextArea {
    return switch (s.view) {
        .milestones => &s.ms_search,
        .milestone => &s.mv_search,
        .timeline => &s.tl_search,
        else => &s.search,
    };
}

pub fn currentMilestoneQuery(s: *const State) milestone_filter.Query {
    var q = s.ms_query;
    q.text = s.ms_search.text();
    return q;
}

/// Formatted into the input arena: for one input's dialogs.
pub fn fmtInput(s: *State, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(s.input_arena.allocator(), format, args) catch "…";
}

/// After a create: show the new issue where the user is.
pub fn select(s: *State, id: Id) void {
    s.list.selected_id = id;
    s.list.follow = true;
    s.board.selected_id = id;
    s.board.follow = true;
    const pane = &s.milestone.panes[s.milestone.pane];
    pane.selected_id = id;
    pane.follow = true;
}

/// The create form, with a parent for a sub-issue.
pub fn newIssue(s: *State, parent: ?u32) void {
    const m = modal_mod.Form.init(s, parent) catch return s.fail("out of memory", .{});
    s.openModal(.{ .form = m });
}

/// The view's issue query with the filter text as typed.
pub fn currentQuery(s: *const State) filter.Query {
    if (s.view == .milestone) {
        var q = s.mv_query;
        q.text = s.mv_search.text();
        return q;
    }
    if (s.view == .timeline) {
        var q = s.tl_query;
        q.text = s.tl_search.text();
        return q;
    }
    var q = s.query;
    q.text = s.search.text();
    return q;
}

/// After the filter or scope changed: the selection stays on its issue
/// when that is still shown, else goes to the top, and is scrolled to.
fn filterChanged(s: *State) void {
    s.list.selected = 0;
    s.list.follow = true;
    s.board.follow = true;
    s.milestones.selected = 0;
    s.milestones.follow = true;
    s.timeline.follow = true;
    for (&s.milestone.panes) |*p| {
        p.selected = 0;
        p.follow = true;
    }
}

// Drawing.

pub fn draw(s: *State, win: ui.Window, now_s: i64) Allocator.Error!void {
    _ = s.frame_arena.reset(.retain_capacity);
    s.hits.reset();
    const f: ui.Frame = .{ .gpa = s.gpa, .arena = s.frame_arena.allocator(), .hits = &s.hits, .now = now_s };
    s.today = .fromUnixLocal(now_s, s.utc_offset_s);
    s.now_s = now_s;
    win.clear();
    win.hideCursor();
    s.too_small = win.width < 20 or win.height < 6;
    if (s.too_small) {
        // Nothing shown: the rows and columns were in the frame arena.
        s.list.rows = &.{};
        s.board.columns = &.{};
        s.milestones.rows = &.{};
        s.timeline.rows = &.{};
        for (&s.milestone.panes) |*p| p.rows = &.{};
        _ = ui.text(win, 0, 0, "Terminal too small", .{ .fg = ui.palette.err });
        return;
    }
    // The view first: the top bar shows what it found, like the
    // timeline's pending changes.
    try s.drawView(f, win.child(.{ .y_off = 1, .height = win.height - 2 }));
    try s.drawTopBar(f, win.child(.{ .height = 1 }));
    s.drawStatusBar(f, win.child(.{ .y_off = @intCast(win.height - 1), .height = 1 }));
    if (s.modal) |*m| {
        s.hits.modal();
        try m.draw(s, f, win);
    }
}

/// The body of the current view.
pub fn drawView(s: *State, f: ui.Frame, body: ui.Window) Allocator.Error!void {
    switch (s.view) {
        .list => try list_view.draw(s, f, body),
        .board => try board_view.draw(s, f, body),
        .milestones => try milestones_view.draw(s, f, body),
        .timeline => try timeline_view.draw(s, f, body),
        .milestone => try milestone_view.draw(s, f, body),
        .detail => try detail_view.draw(s, f, body),
    }
}

fn drawTopBar(s: *State, f: ui.Frame, bar: ui.Window) Allocator.Error!void {
    if (s.view == .timeline and s.timeline.editing) return s.drawEditBanner(f, bar);
    const bg: ui.Style = .{ .bg = ui.palette.bar_bg };
    bar.fill(.{ .style = bg });
    var col: u16 = 0;
    col += ui.text(bar, 1, 0, "◆ issues", .{ .fg = ui.palette.accent, .bg = ui.palette.bar_bg, .bold = true });
    col += 3;
    const tabs = [_]struct { ui.View, []const u8 }{ .{ .list, "List" }, .{ .board, "Board" }, .{ .milestones, "Milestones" }, .{ .timeline, "Timeline" } };
    for (tabs, 1..) |t, n| {
        const active = s.view == t[0] or (t[0] == .milestones and s.view == .milestone);
        col += try ui.button(f, bar, col, 0, f.fmt("{d} {s}", .{ n, t[1] }), .{ .tab = t[0] }, ui.buttonStyle(active));
        col += 1;
    }
    if (s.view == .milestone) {
        const name = milestone_view.scopeName(s.snap, s.milestone.scope);
        col += try ui.button(f, bar, col, 0, f.fmt("◆ {s}", .{name}), .{ .command = .back }, ui.buttonStyle(true));
    }
    if (s.view == .detail) {
        if (s.detail.issue(s.snap)) |i| {
            const label = f.fmt("#{s}", .{issuez.format.uuid.shortId(s.snap.issues[i].id)});
            col += try ui.button(f, bar, col, 0, label, .{ .command = .back }, ui.buttonStyle(true));
        }
    }
    // Counts.
    var open: u32 = 0;
    var done: u32 = 0;
    for (s.snap.issues, 0..) |issue, i| {
        if (issue.deleted) continue;
        if (s.snap.isDone(@intCast(i))) done += 1 else open += 1;
    }
    const counts = f.fmt("{d} open · {d} done", .{ open, done });
    const badge = s.syncBadge(f);
    // Right side buttons.
    const buttons = [_]struct { []const u8, ui.Command }{
        .{ if (s.view == .milestones) "+ Milestone" else "+ New", if (s.view == .milestones) .new_milestone else .new_issue },
        .{ "⟳", .reload },
        .{ "?", .help },
        .{ "✕", .quit },
    };
    var right: u16 = 0;
    for (buttons) |b| right += bar.gwidth(b[0]) + 3;
    right += bar.gwidth(badge.text) + 3;
    if (bar.width > right + col + 2) {
        var x = bar.width - right;
        const cw = bar.gwidth(counts);
        if (x > col + cw + 2) _ = ui.text(bar, x - cw - 2, 0, counts, .{ .fg = ui.palette.muted, .bg = ui.palette.bar_bg });
        x += try ui.button(f, bar, x, 0, badge.text, .{ .command = .sync_panel }, badge.style);
        x += 1;
        for (buttons) |b| {
            const st = if (b[1] == .new_issue or b[1] == .new_milestone) ui.buttonStyle(true) else ui.buttonStyle(false);
            x += try ui.button(f, bar, x, 0, b[0], .{ .command = b[1] }, st);
            x += 1;
        }
    }
}

/// `⇅ origin ↑3 !1 ✕2`: what isn't pushed, is quarantined or in
/// conflict; the phase while syncing; red after a failure, or when the
/// remote couldn't be read.
fn syncBadge(s: *State, f: ui.Frame) struct { text: []const u8, style: ui.Style } {
    const r = &s.snap.remote;
    const failed: ui.Style = .{ .fg = .{ .index = 231 }, .bg = ui.palette.err, .bold = true };
    if (s.sync.running) |_| {
        const what = if (s.sync.phase) |p| switch (p) {
            .fetching => "fetching",
            .merging => "merging",
            .pushing => "pushing",
        } else "starting";
        return .{ .text = f.fmt("⇅ {s} {s}…", .{ s.sync.runningRemote(), what }), .style = .{ .fg = ui.palette.accent, .bg = ui.palette.bar_bg, .bold = true } };
    }
    const name = r.name orelse {
        if (r.problem.len > 0) return .{ .text = "⇅ remote ⚠", .style = failed };
        return .{ .text = "⇅ no remote", .style = .{ .fg = ui.palette.faint, .bg = ui.palette.bar_bg } };
    };
    var conflicts: usize = 0;
    for (s.snap.issues) |issue| {
        if (!issue.deleted and issue.conflicts.len > 0) conflicts += 1;
    }
    const up = r.unpushed.count();
    const q = r.quarantined.count();
    if (s.sync.failed or r.problem.len > 0) return .{ .text = f.fmt("⇅ {s} ⚠", .{name}), .style = failed };
    if (up == 0 and q == 0 and conflicts == 0) return .{ .text = f.fmt("⇅ {s} ✓", .{name}), .style = .{ .fg = ui.palette.ok, .bg = ui.palette.bar_bg } };
    var buf: std.ArrayList(u8) = .empty;
    buf.print(f.arena, "⇅ {s}", .{name}) catch {};
    if (up > 0) buf.print(f.arena, " ↑{d}", .{up}) catch {};
    if (q > 0) buf.print(f.arena, " !{d}", .{q}) catch {};
    if (conflicts > 0) buf.print(f.arena, " ✕{d}", .{conflicts}) catch {};
    const trouble = q > 0 or conflicts > 0;
    return .{ .text = buf.items, .style = .{ .fg = if (trouble) ui.palette.medium else .{ .index = 252 }, .bg = ui.palette.button_bg, .bold = trouble } };
}

/// Edit mode can't be missed: the bar turns amber and says what is
/// pending, with the ways out.
fn drawEditBanner(s: *State, f: ui.Frame, bar: ui.Window) Allocator.Error!void {
    const t = &s.timeline;
    const st: ui.Style = .{ .fg = .{ .index = 16 }, .bg = ui.palette.medium, .bold = true };
    bar.fill(.{ .style = st });
    var col: u16 = 1;
    col += ui.text(bar, col, 0, "✎ EDIT MODE", st);
    col += 2;
    const n = t.changes();
    const what = if (n == 0) "no changes yet" else f.fmt("{d} {s} not applied", .{ n, if (n == 1) "change" else "changes" });
    col += ui.text(bar, col, 0, what, .{ .fg = .{ .index = 16 }, .bg = ui.palette.medium });
    if (t.plan) |p| if (p.stale.len > 0) {
        col += 2;
        col += ui.text(bar, col, 0, f.fmt("! {d} changed elsewhere", .{p.stale.len}), .{ .fg = .{ .index = 160 }, .bg = ui.palette.medium, .bold = true });
    };
    if (t.linking) |id| {
        col += 2;
        col += ui.text(bar, col, 0, f.fmt("linking #{s}: pick its blocker", .{issuez.format.uuid.shortId(id.slice())}), .{ .fg = .{ .index = 16 }, .bg = ui.palette.medium, .italic = true });
    }
    const buttons = [_]struct { []const u8, ui.TimelineCommand, bool }{
        .{ "Apply  ctrl+s", .apply, true },
        .{ "Discard  esc", .discard, false },
        .{ "↶ Undo  u", .undo, false },
        .{ "↷ Redo  U", .redo, false },
    };
    var w: u16 = 0;
    for (buttons) |b| w += bar.gwidth(b[0]) + 3;
    if (bar.width > col + w + 2) {
        var x = bar.width - w;
        for (buttons) |b| {
            const style: ui.Style = if (b[2]) .{ .fg = .{ .index = 231 }, .bg = .{ .index = 28 }, .bold = true } else .{ .fg = .{ .index = 16 }, .bg = .{ .index = 179 } };
            x += try ui.button(f, bar, x, 0, b[0], .{ .tl_command = b[1] }, style);
            x += 1;
        }
    }
}

fn drawStatusBar(s: *State, f: ui.Frame, bar: ui.Window) void {
    _ = f;
    bar.fill(.{ .style = .{ .bg = ui.palette.bar_bg } });
    if (s.status_len > 0) {
        const fg = if (s.status_kind == .err) ui.palette.err else ui.palette.ok;
        _ = ui.text(bar, 1, 0, s.status(), .{ .fg = fg, .bg = ui.palette.bar_bg, .bold = s.status_kind == .err });
        return;
    }
    const hint: []const u8 = if (s.modal) |m| m.hint() else switch (s.view) {
        .list => "↑↓ move  ⏎ open  n new  a sub-issue  x close/reopen  / filter  s sort  t tree  f scope  2 board  ? help  q quit",
        .board => "←→ column  ↑↓ card  ⏎ open  < > move card  n new  x close/reopen  / filter  s sort  1 list  ? help",
        .milestones => "↑↓ move  ⏎ open  n new  e edit  r rename  d due  c complete  R retire  o reopen  / filter  s sort  f scope  w progress  ? help",
        .timeline => if (s.timeline.editing)
            "←→ move  shift week  < > due  { } start  ( ) scroll  d s e type  ⏎ schedule  m milestone  b/B blocker  u U undo  ctrl+s apply  esc leave"
        else
            "↑↓ row  ←→ scroll  z Z zoom  . today  [ ] group  space fold  ⏎ open  D deps  v grouping  E edit  / filter",
        .milestone => if (s.milestone.split)
            "+ add existing  m move to…  space mark  > < move across  tab pane  p pick pane  [ ] prev/next  n new  v single  esc back"
        else
            "↑↓ move  + add existing  m move to…  space mark  [ ] prev/next milestone  n new  N quick add  v split  ⏎ open  esc back",
        .detail => "↑↓ select  ⏎ edit/open  e description  c comment  a sub-issue  A add existing  x close/reopen  t title  esc back  ? help",
    };
    _ = ui.text(bar, 1, 0, hint, .{ .fg = ui.palette.muted, .bg = ui.palette.bar_bg });
}

// Input.

pub fn handle(s: *State, input: Input, now_ms: i64) Allocator.Error!Action {
    _ = s.input_arena.reset(.retain_capacity);
    switch (input) {
        .paste_start => {
            s.pasting = true;
            return .none;
        },
        .paste_end => {
            s.pasting = false;
            return .none;
        },
        .key => |k| {
            s.clearStatus();
            const had_confirm = s.modal != null and s.modal.? == .confirm;
            const action = try s.handleKey(k);
            modal_mod.noteOpener(s, had_confirm, k);
            return action;
        },
        .mouse => |m| return s.handleMouse(m, now_ms),
    }
}

fn handleKey(s: *State, k: vaxis.Key) Allocator.Error!Action {
    if (k.matches('c', .{ .ctrl = true })) {
        // One warning for all that would be lost.
        const text = if (s.modal) |*m| m.unsaved() else false;
        const changes = s.timelineChanges();
        if ((text or changes > 0) and !s.discard_armed) {
            s.discard_armed = true;
            if (text and changes > 0) {
                s.fail("unsaved text and {d} timeline changes not applied: ctrl+c again quits without them", .{changes});
            } else if (text) {
                s.fail("unsaved text: ctrl+c again quits without it, ctrl+s saves", .{});
            } else {
                s.fail("{d} timeline changes aren't applied: ctrl+c again quits without them, ctrl+s applies", .{changes});
            }
            return .none;
        }
        return s.quitUnlessSyncing();
    }
    if (s.too_small) {
        if (!k.matches('q', .{})) return .none;
        // No room to ask: what would be lost holds it back.
        if (s.timelineChanges() > 0 or (if (s.modal) |*m| m.unsaved() else false)) {
            s.fail("unsaved changes: make the terminal larger to keep or drop them", .{});
            return .none;
        }
        return s.quitUnlessSyncing();
    }
    if (s.modal != null) return modal_mod.key(s, k);
    if (s.search_focused) return s.searchKey(k);
    // Pasted text isn't commands.
    if (s.pasting) return .none;

    // Shared keys.
    // Keys other than ctrl+c disarm it.
    s.discard_armed = false;
    const armed = s.quit_armed;
    s.quit_armed = false;
    // Edit mode's keys first: `s` is a start date there, not the sort,
    // and nothing is written before it is applied.
    if (s.view == .timeline and s.timeline.editing) {
        if (try timeline_view.edit.key(s, k)) |act| return act;
    }
    if (k.matches('q', .{})) {
        if (s.view == .detail or s.view == .milestone) {
            s.back();
            return .none;
        }
        if (!timeline_view.edit.mayLeave(s, .quit)) return .none;
        s.quit_armed = armed;
        return s.quitUnlessSyncing();
    }
    if (k.matches('y', .{})) return .{ .sync = .sync };
    if (k.matches('Y', .{})) return .open_sync_panel;
    if (k.matches('?', .{}) or k.matches(K.f1, .{})) {
        s.openModal(.{ .help = .{} });
        return .none;
    }
    if (k.matches('r', .{ .ctrl = true }) or k.matches(K.f5, .{})) return .reload;
    const tabs = [_]struct { u21, ui.View }{ .{ '1', .list }, .{ '2', .board }, .{ '3', .milestones }, .{ '4', .timeline } };
    for (tabs) |t| if (k.matches(t[0], .{})) {
        s.goTo(t[1]);
        return .none;
    };
    if (s.view != .detail) {
        if (k.matches('/', .{})) {
            s.search_focused = true;
            return .none;
        }
        if (k.matches(K.escape, .{}) and s.searchBox().text().len > 0) {
            s.searchBox().clear();
            s.filterChanged();
            return .none;
        }
        if (k.matches(K.tab, .{}) and s.view != .milestone) {
            s.goTo(switch (s.view) {
                .list => .board,
                .board => .milestones,
                .milestones => .timeline,
                else => .list,
            });
            return .none;
        }
    }
    // The issue tables' keys; not the timeline's edit mode: they sort,
    // filter and create.
    const timeline = s.view == .timeline and !s.timeline.editing;
    if (s.view == .list or s.view == .board or s.view == .milestone or timeline) {
        const q = s.issueQuery();
        if (k.matches('n', .{})) {
            s.newIssue(null);
            return .none;
        }
        if (k.matches('s', .{})) {
            modal_mod.openSort(s);
            return .none;
        }
        if (k.matches('S', .{})) {
            q.reverse = !q.reverse;
            return .none;
        }
        if (k.matches('f', .{})) {
            q.scope = switch (q.scope) {
                .open => .done,
                .done => .all,
                .all => .open,
            };
            s.filterChanged();
            return .none;
        }
    }
    return switch (s.view) {
        .list => list_view.key(s, k),
        .board => board_view.key(s, k),
        .milestones => milestones_view.key(s, k),
        .timeline => timeline_view.key(s, k),
        .milestone => milestone_view.key(s, k),
        .detail => detail_view.key(s, k),
    };
}

fn searchKey(s: *State, k: vaxis.Key) Allocator.Error!Action {
    const box = s.searchBox();
    if (s.pasting) {
        try box.pasteKey(s.gpa, k);
        s.filterChanged();
        return .none;
    }
    if (k.matches(K.escape, .{})) {
        if (box.text().len > 0) {
            box.clear();
            s.filterChanged();
        } else s.search_focused = false;
        return .none;
    }
    if (k.matches(K.enter, .{}) or k.matches(K.down, .{}) or k.matches(K.tab, .{})) {
        s.search_focused = false;
        return .none;
    }
    _ = try box.key(s.gpa, s.input_arena.allocator(), k);
    s.filterChanged();
    return .none;
}

fn handleMouse(s: *State, m: vaxis.Mouse, now_ms: i64) Allocator.Error!Action {
    const found = s.hits.find(m.col, m.row);
    switch (m.button) {
        .wheel_up, .wheel_down, .wheel_left, .wheel_right => {
            const delta: i32 = if (m.button == .wheel_up) -3 else 3;
            if (s.modal) |*md| return md.wheel(s, found, delta);
            if (s.view == .timeline) {
                timeline_view.wheel(s, m, delta);
                return .none;
            }
            if (m.button == .wheel_left or m.button == .wheel_right) return .none;
            switch (s.view) {
                .list => s.list.scrollBy(delta),
                .board => board_view.wheel(s, found, delta),
                .milestones => s.milestones.scrollBy(delta),
                .timeline => {},
                .milestone => milestone_view.wheel(s, found, delta),
                .detail => s.detail.scrollBy(delta),
            }
            return .none;
        },
        .left => {},
        else => return .none,
    }

    switch (m.type) {
        .press => {},
        .drag, .motion => {
            if (s.view == .timeline and (s.timeline.bar_drag != null or s.timeline.row_drag != null)) {
                timeline_view.edit.dragTo(s, found);
                return .none;
            }
            if (s.drag) |*d| {
                d.moved = true;
                d.over = if (found) |h| switch (h.target) {
                    .column => |c| c,
                    .card => |c| c.column,
                    .mrow => |c| c.column,
                    .mpane => |p| p,
                    else => null,
                } else null;
            }
            return .none;
        },
        .release => {
            if (s.timeline.bar_drag != null or s.timeline.row_drag != null) {
                timeline_view.edit.release(s);
                return .none;
            }
            const d = s.drag orelse return .none;
            s.drag = null;
            if (!d.moved) return .none;
            if (s.view == .milestone) return milestone_view.drop(s, d);
            return board_view.drop(s, d);
        },
    }

    // A press starts afresh: a drag whose release never came is over.
    s.drag = null;
    s.clearStatus();
    const h = found orelse return .none;
    const double = if (s.last_click) |c|
        c.target.eql(h.target) and now_ms - c.ms <= double_click_ms
    else
        false;
    s.last_click = if (double) null else .{ .target = h.target, .ms = now_ms };

    if (s.modal) |*md| return md.click(s, h);
    if (s.search_focused and h.target != .search) s.search_focused = false;

    const q = s.issueQuery();
    switch (h.target) {
        .tab => |v| s.goTo(v),
        .command => |c| return s.command(c),
        .scope => |sc| {
            q.scope = sc;
            s.filterChanged();
        },
        .tree => q.tree = !q.tree,
        .sort => |key| {
            if (q.key == key) q.reverse = !q.reverse else {
                q.key = key;
                q.reverse = false;
            }
        },
        .sort_reverse => if (s.view == .milestones) {
            s.ms_query.reverse = !s.ms_query.reverse;
            s.milestones.follow = true;
        } else {
            q.reverse = !q.reverse;
        },
        .search => {
            s.search_focused = true;
            s.searchBox().clickLine(h.x);
        },
        .row => |r| return list_view.click(s, r, double),
        .card => |c| return board_view.click(s, c, double),
        .column => |c| board_view.clickColumn(s, c),
        .item => |i| return detail_view.click(s, i),
        .ms_row => |r| return milestones_view.click(s, r, double),
        .ms_scope => |sc| {
            s.ms_query.scope = sc;
            s.filterChanged();
        },
        .ms_sort => |key| {
            const mq = &s.ms_query;
            if (mq.key == key) mq.reverse = !mq.reverse else {
                mq.key = key;
                mq.reverse = false;
            }
            s.milestones.follow = true;
        },
        .mrow => |r| return milestone_view.click(s, r, double),
        .mpane => |p| milestone_view.clickPane(s, p),
        .tl_row => |r| return timeline_view.click(s, r, h.x, double),
        .tl_header => timeline_view.clickHeader(s, h.x),
        .tl_zoom => |z| timeline_view.setZoom(s, z),
        .tl_command => |c| timeline_view.command(s, c),
        .modal, .backdrop => {},
    }
    return .none;
}

pub fn command(s: *State, c: ui.Command) Action {
    switch (c) {
        .new_issue => if (s.view == .milestones) modal_mod.newMilestone(s) else s.newIssue(null),
        .new_milestone => modal_mod.newMilestone(s),
        .reload => return .reload,
        .help => s.openModal(.{ .help = .{} }),
        .sort => if (s.view == .milestones) modal_mod.openMilestoneSort(s) else modal_mod.openSort(s),
        .quit => return if (timeline_view.edit.mayLeave(s, .quit)) s.quitUnlessSyncing() else .none,
        .sync_panel => return .open_sync_panel,
        .back => s.back(),
        .ms_edit => if (milestone_view.milestoneOf(s.snap, s.milestone.focusedScope())) |n| modal_mod.editMilestone(s, n),
        .ms_complete => if (milestone_view.milestoneOf(s.snap, s.milestone.focusedScope())) |n| milestones_view.confirmComplete(s, n),
        .pick_pane => milestone_view.openPaneMenu(s),
        .ms_add => milestone_view.openAddPicker(s),
        .ms_move => milestone_view.openMoveMenu(s),
    }
    return .none;
}

/// The issue's state flipped, as an action.
pub fn toggleAction(s: *const State, i: u32) Action {
    return .{ .toggle = .of(s.snap.issues[i].id) };
}

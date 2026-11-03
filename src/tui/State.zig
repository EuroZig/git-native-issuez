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
    state: struct { id: Id, state: []const u8 },
    comment: struct { id: Id, text: []const u8 },
    /// Close an open issue, reopen a done one.
    toggle: Id,
    /// To a board column: a workflow state, or done.
    move: struct { id: Id, column: []const u8, done: bool },
};

gpa: Allocator,
snap: *const Snapshot,
view: ui.View = .list,
/// Where the detail view goes back to.
home: ui.View = .list,
/// Without the text, which is `search`'s: see `currentQuery`.
query: filter.Query = .{},
search: TextArea = .init(false),
search_focused: bool = false,
list: list_view.State = .{},
board: board_view.State = .{},
detail: detail_view.State = .{},
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
    if (s.modal_tip) |*t| t.tip = s.tipOf(t.id.slice()) else return;
    modal_mod.rebase(s);
}

pub fn modalArena(s: *State) Allocator {
    return s.modal_arena.allocator();
}

// Navigation.

pub fn openIssue(s: *State, id: []const u8) void {
    if (s.view != .detail) {
        s.home = s.view;
        s.detail.clear();
    }
    s.detail.push(id);
    s.view = .detail;
    s.search_focused = false;
}

pub fn back(s: *State) void {
    if (s.view != .detail) return;
    if (!s.detail.pop()) s.view = s.home;
}

pub fn switchView(s: *State, v: ui.View) void {
    assert(v != .detail);
    s.view = v;
    s.search_focused = false;
}

/// The issue the current view points at, if any.
pub fn current(s: *const State) ?u32 {
    return switch (s.view) {
        .list => s.list.selectedIssue(),
        .board => s.board.selectedIssue(),
        .detail => s.detail.issue(s.snap),
    };
}

/// After a create: show the new issue where the user is.
pub fn select(s: *State, id: Id) void {
    s.list.selected_id = id;
    s.list.follow = true;
    s.board.selected_id = id;
    s.board.follow = true;
}

/// The create form, with a parent for a sub-issue.
pub fn newIssue(s: *State, parent: ?u32) void {
    const m = modal_mod.Form.init(s, parent) catch return s.fail("out of memory", .{});
    s.openModal(.{ .form = m });
}

/// The query with the filter text as typed.
pub fn currentQuery(s: *const State) filter.Query {
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
}

// Drawing.

pub fn draw(s: *State, win: ui.Window, now_s: i64) Allocator.Error!void {
    _ = s.frame_arena.reset(.retain_capacity);
    s.hits.reset();
    const f: ui.Frame = .{ .gpa = s.gpa, .arena = s.frame_arena.allocator(), .hits = &s.hits, .now = now_s };
    win.clear();
    win.hideCursor();
    s.too_small = win.width < 20 or win.height < 6;
    if (s.too_small) {
        // Nothing shown: the rows and columns were in the frame arena.
        s.list.rows = &.{};
        s.board.columns = &.{};
        _ = ui.text(win, 0, 0, "Terminal too small", .{ .fg = ui.palette.err });
        return;
    }
    try s.drawTopBar(f, win.child(.{ .height = 1 }));
    const body = win.child(.{ .y_off = 1, .height = win.height - 2 });
    switch (s.view) {
        .list => try list_view.draw(s, f, body),
        .board => try board_view.draw(s, f, body),
        .detail => try detail_view.draw(s, f, body),
    }
    s.drawStatusBar(f, win.child(.{ .y_off = @intCast(win.height - 1), .height = 1 }));
    if (s.modal) |*m| {
        s.hits.modal();
        try m.draw(s, f, win);
    }
}

fn drawTopBar(s: *State, f: ui.Frame, bar: ui.Window) Allocator.Error!void {
    const bg: ui.Style = .{ .bg = ui.palette.bar_bg };
    bar.fill(.{ .style = bg });
    var col: u16 = 0;
    col += ui.text(bar, 1, 0, "◆ issues", .{ .fg = ui.palette.accent, .bg = ui.palette.bar_bg, .bold = true });
    col += 3;
    const tabs = [_]struct { ui.View, []const u8 }{ .{ .list, "List" }, .{ .board, "Board" } };
    for (tabs, 1..) |t, n| {
        const active = s.view == t[0];
        col += try ui.button(f, bar, col, 0, f.fmt("{d} {s}", .{ n, t[1] }), .{ .tab = t[0] }, ui.buttonStyle(active));
        col += 1;
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
    // Right side buttons.
    const buttons = [_]struct { []const u8, ui.Command }{
        .{ "+ New", .new_issue },
        .{ "⟳", .reload },
        .{ "?", .help },
        .{ "✕", .quit },
    };
    var right: u16 = 0;
    for (buttons) |b| right += bar.gwidth(b[0]) + 3;
    if (bar.width > right + col + 2) {
        var x = bar.width - right;
        const cw = bar.gwidth(counts);
        if (x > col + cw + 2) _ = ui.text(bar, x - cw - 2, 0, counts, .{ .fg = ui.palette.muted, .bg = ui.palette.bar_bg });
        for (buttons) |b| {
            const st = if (b[1] == .new_issue) ui.buttonStyle(true) else ui.buttonStyle(false);
            x += try ui.button(f, bar, x, 0, b[0], .{ .command = b[1] }, st);
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
        .detail => "↑↓ select  ⏎ edit/open  e description  c comment  a sub-issue  x close/reopen  t title  esc back  ? help",
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
            return s.handleKey(k);
        },
        .mouse => |m| return s.handleMouse(m, now_ms),
    }
}

fn handleKey(s: *State, k: vaxis.Key) Allocator.Error!Action {
    if (k.matches('c', .{ .ctrl = true })) {
        if (s.modal) |*m| if (!s.discard_armed and m.unsaved()) {
            s.discard_armed = true;
            s.fail("unsaved text: ctrl+c again quits without it, ctrl+s saves", .{});
            return .none;
        };
        return .quit;
    }
    if (s.too_small) return if (k.matches('q', .{})) .quit else .none;
    if (s.modal != null) return modal_mod.key(s, k);
    if (s.search_focused) return s.searchKey(k);
    // Pasted text isn't commands.
    if (s.pasting) return .none;

    // Shared keys.
    if (k.matches('q', .{})) {
        if (s.view == .detail) {
            s.back();
            return .none;
        }
        return .quit;
    }
    if (k.matches('?', .{}) or k.matches(K.f1, .{})) {
        s.openModal(.{ .help = 0 });
        return .none;
    }
    if (k.matches('r', .{ .ctrl = true }) or k.matches(K.f5, .{})) return .reload;
    if (k.matches('1', .{})) {
        s.switchView(.list);
        return .none;
    }
    if (k.matches('2', .{})) {
        s.switchView(.board);
        return .none;
    }
    if (s.view != .detail) {
        if (k.matches('/', .{})) {
            s.search_focused = true;
            return .none;
        }
        if (k.matches(K.tab, .{})) {
            s.switchView(if (s.view == .list) .board else .list);
            return .none;
        }
        if (k.matches('n', .{})) {
            s.newIssue(null);
            return .none;
        }
        if (k.matches('s', .{})) {
            modal_mod.openSort(s);
            return .none;
        }
        if (k.matches('S', .{})) {
            s.query.reverse = !s.query.reverse;
            return .none;
        }
        if (k.matches('f', .{})) {
            s.query.scope = switch (s.query.scope) {
                .open => .done,
                .done => .all,
                .all => .open,
            };
            s.filterChanged();
            return .none;
        }
        if (k.matches(K.escape, .{}) and s.search.text().len > 0) {
            s.search.clear();
            s.filterChanged();
            return .none;
        }
    }
    return switch (s.view) {
        .list => list_view.key(s, k),
        .board => board_view.key(s, k),
        .detail => detail_view.key(s, k),
    };
}

fn searchKey(s: *State, k: vaxis.Key) Allocator.Error!Action {
    if (s.pasting) {
        try s.search.pasteKey(s.gpa, k);
        s.filterChanged();
        return .none;
    }
    if (k.matches(K.escape, .{})) {
        if (s.search.text().len > 0) {
            s.search.clear();
            s.filterChanged();
        } else s.search_focused = false;
        return .none;
    }
    if (k.matches(K.enter, .{}) or k.matches(K.down, .{}) or k.matches(K.tab, .{})) {
        s.search_focused = false;
        return .none;
    }
    _ = try s.search.key(s.gpa, s.input_arena.allocator(), k);
    s.filterChanged();
    return .none;
}

fn handleMouse(s: *State, m: vaxis.Mouse, now_ms: i64) Allocator.Error!Action {
    const found = s.hits.find(m.col, m.row);
    switch (m.button) {
        .wheel_up, .wheel_down => {
            const delta: i32 = if (m.button == .wheel_up) -3 else 3;
            if (s.modal) |*md| return md.wheel(s, found, delta);
            switch (s.view) {
                .list => s.list.scrollBy(delta),
                .board => board_view.wheel(s, found, delta),
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
            if (s.drag) |*d| {
                d.moved = true;
                d.over = if (found) |h| switch (h.target) {
                    .column => |c| c,
                    .card => |c| c.column,
                    else => null,
                } else null;
            }
            return .none;
        },
        .release => {
            const d = s.drag orelse return .none;
            s.drag = null;
            if (!d.moved) return .none;
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

    switch (h.target) {
        .tab => |v| s.switchView(v),
        .command => |c| return s.command(c),
        .scope => |sc| {
            s.query.scope = sc;
            s.filterChanged();
        },
        .tree => s.query.tree = !s.query.tree,
        .sort => |key| {
            if (s.query.key == key) s.query.reverse = !s.query.reverse else {
                s.query.key = key;
                s.query.reverse = false;
            }
        },
        .sort_reverse => s.query.reverse = !s.query.reverse,
        .search => {
            s.search_focused = true;
            s.search.clickLine(h.x);
        },
        .row => |r| return list_view.click(s, r, double),
        .card => |c| return board_view.click(s, c, double),
        .column => |c| board_view.clickColumn(s, c),
        .item => |i| return detail_view.click(s, i),
        .modal, .backdrop => {},
    }
    return .none;
}

pub fn command(s: *State, c: ui.Command) Action {
    switch (c) {
        .new_issue => s.newIssue(null),
        .reload => return .reload,
        .help => s.openModal(.{ .help = 0 }),
        .sort => modal_mod.openSort(s),
        .quit => return .quit,
        .back => s.back(),
    }
    return .none;
}

/// The issue's state flipped, as an action.
pub fn toggleAction(s: *const State, i: u32) Action {
    return .{ .toggle = .of(s.snap.issues[i].id) };
}

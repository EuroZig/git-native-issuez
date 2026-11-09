//! One issue: its title, fields, description, sub-issues, relations and
//! activity. Everything editable is an item: clicked, or selected with the
//! arrows and opened with Enter.

const std = @import("std");
const stableSort = @import("issuez").sort.stable;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const issuez = @import("issuez");

const ui = @import("ui.zig");
const store = @import("store.zig");
const text_mod = @import("text.zig");
const modal = @import("modal.zig");
const AppState = @import("State.zig");

const Id = store.Id;
const Snapshot = store.Snapshot;
const Field = modal.Field;
const K = vaxis.Key;
const palette = ui.palette;
const shortId = issuez.format.uuid.shortId;

const max_stack = 32;
/// What an empty field shows: an em dash.
const unset = "\u{2014}";
const none = std.math.maxInt(u32);

pub const Item = union(enum) {
    back,
    title,
    field: Field,
    description,
    comment,
    add_child,
    /// Existing issues as sub-issues.
    add_existing,
    toggle,
    /// Another issue, by snapshot index.
    open: u32,
};

/// The focused item across reloads, which move items around. An issue
/// shown twice, as a sub-issue that also blocks, is told apart by `nth`.
pub const Focus = union(enum) {
    /// The first content item.
    none,
    item: Item,
    open: struct { id: Id, nth: u8 },
};

pub const State = struct {
    /// Issues opened from one another, the current one last.
    stack: [max_stack]Id = undefined,
    depth: u8 = 0,
    /// A position in `items`, kept on `focused` by every frame.
    focus: u16 = 0,
    focused: Focus = .none,
    /// The first content row shown.
    scroll: u32 = 0,
    /// Scroll the focused item into view on the next frame.
    follow: bool = false,
    /// The last frame's. Items before `first` are the action bar's.
    items: std.ArrayList(Item) = .empty,
    first: u16 = 0,
    content_rows: u32 = 0,
    visible: u16 = 1,

    pub fn deinit(d: *State, gpa: Allocator) void {
        d.items.deinit(gpa);
    }

    pub fn clear(d: *State) void {
        d.depth = 0;
    }

    pub fn push(d: *State, id: []const u8) void {
        if (d.depth > 0 and d.stack[d.depth - 1].eql(id)) return;
        if (d.depth == max_stack) {
            std.mem.copyForwards(Id, d.stack[0 .. max_stack - 1], d.stack[1..]);
            d.depth -= 1;
        }
        d.stack[d.depth] = .of(id);
        d.depth += 1;
        d.focus = 0;
        d.focused = .none;
        d.scroll = 0;
    }

    /// False when there is nothing to go back to.
    pub fn pop(d: *State) bool {
        if (d.depth <= 1) return false;
        d.depth -= 1;
        d.focus = 0;
        d.focused = .none;
        d.scroll = 0;
        return true;
    }

    pub fn issue(d: *const State, snap: *const Snapshot) ?u32 {
        if (d.depth == 0) return null;
        return snap.find(d.stack[d.depth - 1].slice());
    }

    pub fn scrollBy(d: *State, delta: i32) void {
        const max: i64 = @intCast(d.content_rows -| d.visible);
        d.scroll = @intCast(std.math.clamp(@as(i64, d.scroll) + delta, 0, max));
    }

    /// Moves the focus to a position in the last frame's items.
    pub fn focusOn(d: *State, snap: *const Snapshot, index: u16) void {
        if (index >= d.items.items.len) return;
        d.focus = index;
        d.focused = d.keyAt(snap, index);
    }

    fn keyAt(d: *const State, snap: *const Snapshot, index: u16) Focus {
        const items = d.items.items;
        return switch (items[index]) {
            .open => |k| blk: {
                var nth: u8 = 0;
                for (items[0..index]) |it| switch (it) {
                    .open => |o| if (o == k) {
                        nth +|= 1;
                    },
                    else => {},
                };
                break :blk .{ .open = .{ .id = .of(snap.issues[k].id), .nth = nth } };
            },
            else => |it| .{ .item = it },
        };
    }

    fn focusItem(d: *State) ?Item {
        if (d.focus >= d.items.items.len) return null;
        return d.items.items[d.focus];
    }
};

/// Content drawn on virtual rows, of which only those in view reach the
/// screen.
const Canvas = struct {
    s: *AppState,
    f: ui.Frame,
    win: ui.Window,
    scroll: u32,
    y: u32 = 0,
    /// Where the focused item was drawn.
    focus_top: ?u32 = null,
    focus_bottom: u32 = 0,
    /// Whether an item matched `focused`.
    found: bool = false,
    /// Items so far showing the focused issue.
    seen: u8 = 0,

    /// The next row, if in view.
    fn line(c: *Canvas) ?ui.Window {
        defer c.y += 1;
        if (c.y < c.scroll or c.y - c.scroll >= c.win.height) return null;
        return c.win.child(.{ .y_off = @intCast(c.y - c.scroll), .height = 1 });
    }

    /// The next row with one text on it, if in view.
    fn text(c: *Canvas, indent: u16, s: []const u8, style: ui.Style) void {
        if (c.line()) |l| _ = ui.text(l, indent, 0, s, style);
    }

    /// The next row of an item, marked when focused, with one text on it.
    fn itemText(c: *Canvas, span: Span, s: []const u8, style: ui.Style) void {
        const l = c.line() orelse return;
        l.fill(.{ .style = itemStyle(span) });
        var st = style;
        st.bg = itemStyle(span).bg;
        _ = ui.text(l, 2, 0, s, st);
    }

    fn skip(c: *Canvas, n: u32) void {
        c.y += n;
    }

    /// Starts an item; its rows follow until `end`.
    fn begin(c: *Canvas, it: Item) Allocator.Error!Span {
        const d = &c.s.detail;
        const index: u16 = @intCast(d.items.items.len);
        try d.items.append(c.s.gpa, it);
        const focused = !c.found and c.isFocused(it);
        if (focused) {
            c.found = true;
            d.focus = index;
        }
        return .{ .index = index, .top = c.y, .focused = focused };
    }

    fn isFocused(c: *Canvas, it: Item) bool {
        const d = &c.s.detail;
        switch (d.focused) {
            .none => return false,
            .item => |want| return std.meta.eql(want, it),
            .open => |want| {
                const k = switch (it) {
                    .open => |k| k,
                    else => return false,
                };
                if (!want.id.eql(c.s.snap.issues[k].id)) return false;
                defer c.seen +|= 1;
                return c.seen == want.nth;
            },
        }
    }

    fn end(c: *Canvas, span: Span) Allocator.Error!void {
        if (span.focused) {
            c.focus_top = span.top;
            c.focus_bottom = c.y;
        }
        // Clickable over the rows in view.
        const top = @max(span.top, c.scroll);
        const bottom = @min(c.y, c.scroll + c.win.height);
        if (bottom <= top) return;
        const w = c.win.child(
            .{ .y_off = @intCast(top - c.scroll), .height = @intCast(bottom - top) },
        );
        try c.f.hit(w, .{ .item = span.index });
    }

    const Span = struct { index: u16, top: u32, focused: bool };
};

pub fn draw(s: *AppState, f: ui.Frame, win: ui.Window) Allocator.Error!void {
    const d = &s.detail;
    d.items.clearRetainingCapacity();
    const i = d.issue(s.snap) orelse {
        try d.items.append(s.gpa, .back);
        d.first = 1;
        _ = ui.text(win, 2, 1, "This issue isn't here (any more).", .{ .fg = palette.err });
        _ = try ui.button(f, win, 2, 3, "‹ Back", .{ .item = 0 }, ui.buttonStyle(true));
        return;
    };
    try drawActions(s, f, win.child(.{ .height = 1 }), i);
    d.first = @intCast(d.items.items.len);

    const content = win.child(
        .{ .y_off = 2, .x_off = 2, .width = win.width -| 4, .height = win.height -| 2 },
    );
    d.visible = @max(content.height, 1);
    const hits_before = s.hits.items.items.len;
    const items_before = d.items.items.len;
    // Again when the focused item is gone, then when it is out of view.
    for (0..3) |_| {
        var c: Canvas = .{ .s = s, .f = f, .win = content, .scroll = d.scroll };
        content.clear();
        try drawContent(&c, i);
        d.content_rows = c.y;
        assert(d.items.items.len > d.first);
        if (!c.found) {
            // The item now where it was, or the first.
            d.focus = std.math.clamp(d.focus, d.first, @as(u16, @intCast(d.items.items.len - 1)));
            d.focused = d.keyAt(s.snap, d.focus);
        } else {
            if (!d.follow) break;
            d.follow = false;
            const top = c.focus_top orelse break;
            const bottom = c.focus_bottom;
            var scroll = d.scroll;
            if (bottom > scroll + d.visible) scroll = bottom -| d.visible;
            if (top < scroll) scroll = top;
            if (scroll == d.scroll) break;
            d.scroll = scroll;
        }
        s.hits.items.shrinkRetainingCapacity(hits_before);
        d.items.shrinkRetainingCapacity(items_before);
    }
    d.follow = false;
    d.scroll = @min(d.scroll, d.content_rows -| d.visible);
}

fn drawActions(s: *AppState, f: ui.Frame, bar: ui.Window, i: u32) Allocator.Error!void {
    const d = &s.detail;
    const done = s.snap.isDone(i);
    bar.fill(.{ .style = .{ .bg = palette.panel_bg } });
    const buttons = [_]struct { Item, []const u8 }{
        .{ .back, "‹ Back" },
        .{ .title, "✎ Title  t" },
        .{ .description, "✎ Description  e" },
        .{ .comment, "✉ Comment  c" },
        .{ .add_child, "+ Sub-issue  a" },
        .{ .add_existing, "+ Existing  A" },
        .{ .toggle, if (done) "↺ Reopen  x" else "✓ Close  x" },
    };
    var l: ui.Line = .{ .f = f, .win = bar, .x = 1 };
    for (buttons) |b| {
        const index: u16 = @intCast(d.items.items.len);
        try d.items.append(s.gpa, b[0]);
        try l.button(b[1], .{ .item = index }, ui.buttonStyle(b[0] == .add_child));
        l.x += 1;
    }
}

fn itemStyle(span: Canvas.Span) ui.Style {
    return if (span.focused) .{ .bg = palette.select_bg } else .{};
}

fn drawContent(c: *Canvas, i: u32) Allocator.Error!void {
    const s = c.s;
    const f = c.f;
    const snap = s.snap;
    const issue = snap.issues[i];
    const done = snap.isDone(i);
    const w = c.win.width;

    // Title.
    {
        const span = try c.begin(.title);
        const rows = try text_mod.layout(f.arena, issue.title, w -| 2);
        for (rows) |r| if (c.line()) |l| {
            const st = itemStyle(span);
            l.fill(.{ .style = st });
            _ = ui.text(l, 0, 0, issue.title[r.start..r.end], .{ .bold = true, .bg = st.bg });
        };
        try c.end(span);
    }
    if (c.line()) |row| {
        var l: ui.Line = .{ .f = f, .win = row };
        const badge_bg: vaxis.Color = if (done) palette.done else palette.open;
        l.word(
            f.fmt(" {s} ", .{issue.state.text()}),
            .{ .fg = .{ .index = 16 }, .bg = badge_bg, .bold = true },
        );
        if (snap.proj.workflow(i)) |wf| l.word(wf, .{ .fg = palette.accent });
        l.word(f.fmt("#{s}", .{shortId(issue.id)}), .{ .fg = palette.id });
        if (issue.number) |num| l.word(f.fmt("#{d}", .{num}), .{ .fg = palette.id, .bold = true });
        const updated = ui.ago(f, issue.updated);
        l.word(f.fmt("opened by {s} on {s}, updated {s}{s}", .{
            issue.author.name,
            ui.date(f, issue.created),
            updated,
            if (std.ascii.isDigit(updated[0]) and updated.len < 5) " ago" else "",
        }), .{ .fg = palette.muted });
        if (snap.proj.activelyBlocked(i)) l.word("⊘ blocked", .{ .fg = palette.err, .bold = true });
        if (issue.deleted) l.word(
            " deleted ",
            .{ .fg = .{ .index = 16 }, .bg = palette.err, .bold = true },
        );
        if (issue.locked) l.word(
            " locked ",
            .{ .fg = .{ .index = 16 }, .bg = palette.medium, .bold = true },
        );
    }
    // What the issue is about, where it came from, who reacted.
    {
        var parts: std.ArrayList([]const u8) = .empty;
        if (issue.lock_reason) |r| try parts.append(f.arena, f.fmt("locked: {s}", .{r}));
        if (issue.ref) |r| try parts.append(f.arena, f.fmt("ref {s}", .{r}));
        if (issue.original_author) |a| try parts.append(f.arena, if (issue.original_id) |oid|
            f.fmt("imported from {s} ({s})", .{ a, oid })
        else
            f.fmt("imported from {s}", .{a}));
        const rx = try reactionsText(f, issue, null);
        if (rx.len > 0) try parts.append(f.arena, rx);
        const joined = try std.mem.join(f.arena, " · ", parts.items);
        if (parts.items.len > 0) c.text(0, joined, .{ .fg = palette.muted });
    }
    c.skip(1);

    // Fields, in two columns when there is room.
    try drawFields(c, i);
    c.skip(1);

    // Where it stands with the remote.
    if (snap.remote.name) |remote| {
        if (snap.remote.isQuarantined(issue.id)) {
            c.text(
                0,
                f.fmt("! {s} refused the remote's version: Y shows why and what to do", .{remote}),
                .{ .fg = palette.err },
            );
            c.skip(1);
        } else if (snap.remote.unpushed.get(issue.id)) |new| {
            const what = if (new) "not" else "these changes aren't";
            const note = f.fmt("↑ {s} on {s} yet: y syncs", .{ what, remote });
            c.text(0, note, .{ .fg = palette.muted });
            c.skip(1);
        }
    }

    // Problems and conflicts.
    for (snap.proj.problemsOf(i)) |p| c.text(0, f.fmt("⚠ {f}", .{p}), .{ .fg = palette.err });
    for (issue.conflicts) |cf| c.text(0, f.fmt(
        "⚠ concurrent edits to {f}: kept '{s}', lost '{s}'",
        .{ cf.target, cf.value, cf.lost },
    ), .{ .fg = palette.medium });
    if (snap.proj.problemsOf(i).len > 0 or issue.conflicts.len > 0) c.skip(1);

    // Description.
    {
        const span = try c.begin(.description);
        try sectionHeader(c, span, "Description", "✎ edit  e");
        if (std.mem.trim(u8, issue.description, " \n").len == 0) {
            c.itemText(
                span,
                "No description. Click or press e to write one.",
                .{ .fg = palette.faint, .italic = true },
            );
        } else try paragraph(c, issue.description, 2, .{});
        try c.end(span);
    }
    c.skip(1);

    // Sub-issues.
    {
        const kids = try sortedChildren(f.arena, snap, i);
        const span = try c.begin(.add_child);
        const title = if (snap.proj.progress(i)) |p|
            f.fmt("Sub-issues  {d}/{d} done", .{ p.closed, p.total })
        else
            f.fmt("Sub-issues  {d}", .{kids.len});
        try sectionHeader(c, span, title, "+ new sub-issue  a");
        if (kids.len == 0) c.itemText(
            span,
            "None yet. Click or press a to break this issue down.",
            .{ .fg = palette.faint, .italic = true },
        );
        try c.end(span);
        if (snap.proj.progress(i)) |p| if (c.line()) |l| progressBar(l, p);
        for (kids) |k| try issueLine(c, k, "");
        const existing = try c.begin(.add_existing);
        c.itemText(
            existing,
            "+ add existing issues  A",
            .{ .fg = if (existing.focused) palette.accent else palette.muted },
        );
        try c.end(existing);
    }
    c.skip(1);

    // Relations.
    const blockers = snap.proj.blockers[i];
    const blocks = snap.proj.blocks[i];
    const parent = snap.proj.parent[i];
    if (parent != none or blockers.len > 0 or blocks.len > 0) {
        c.text(0, "Relations", .{ .fg = palette.accent, .bold = true });
        if (parent != none) try issueLine(c, parent, "parent     ");
        for (blockers) |b| try issueLine(c, b, "blocked by ");
        for (blocks) |b| try issueLine(c, b, "blocks     ");
        c.skip(1);
    }

    // Activity.
    {
        const span = try c.begin(.comment);
        var n: u32 = 0;
        for (issue.comments) |cm| {
            if (!cm.deleted) n += 1;
        }
        try sectionHeader(c, span, f.fmt("Activity  {d}", .{n}), "✉ comment  c");
        try c.end(span);
        for (issue.comments) |cm| {
            if (cm.deleted) continue;
            const when = ui.ago(f, cm.author.time);
            if (cm.kind == .update) {
                if (c.line()) |row| {
                    var l: ui.Line = .{ .f = f, .win = row, .x = 2 };
                    l.word("·", .{ .fg = palette.faint });
                    l.word(cm.author.name, .{ .fg = palette.muted });
                    l.word(cm.subject, .{ .fg = palette.muted });
                    l.word(when, .{ .fg = palette.faint });
                }
                continue;
            }
            c.skip(1);
            if (c.line()) |row| {
                var l: ui.Line = .{ .f = f, .win = row, .x = 2 };
                l.word(cm.author.name, .{ .bold = true });
                l.word(when, .{ .fg = palette.muted });
                if (cm.original_author) |a| {
                    l.word(f.fmt("(via {s})", .{a}), .{ .fg = palette.faint });
                }
                if (cm.edited) l.word("(edited)", .{ .fg = palette.faint });
                if (cm.purged) l.word("(purged)", .{ .fg = palette.err });
                if (cm.state_change) |st| {
                    l.word(f.fmt("→ {s}", .{st.text()}), .{ .fg = palette.done });
                }
            }
            const body = try std.mem.join(f.arena, "\n", cm.body);
            const shown = if (std.mem.trim(u8, body, " \n").len == 0) cm.subject else body;
            try paragraph(c, std.mem.trimEnd(u8, shown, "\n"), 4, .{});
            const rx = try reactionsText(f, issue, cm.oid);
            if (rx.len > 0) c.text(4, rx, .{ .fg = palette.muted });
        }
    }
    c.skip(1);
}

/// `:+1: 2  heart 1` for the reactions on `target` (null: the issue).
fn reactionsText(
    f: ui.Frame,
    issue: issuez.engine.Issue,
    target: ?issuez.engine.Oid,
) Allocator.Error![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (issue.reactions) |r| {
        const same = if (r.target) |t| (target != null and t.eql(target.?)) else target == null;
        if (same) try parts.append(f.arena, f.fmt("{s} {d}", .{ r.emoji, r.users.len }));
    }
    return std.mem.join(f.arena, "  ", parts.items);
}

fn sectionHeader(
    c: *Canvas,
    span: Canvas.Span,
    title: []const u8,
    action: []const u8,
) Allocator.Error!void {
    const l = c.line() orelse return;
    l.fill(.{ .style = itemStyle(span) });
    const bg = itemStyle(span).bg;
    var x = ui.text(l, 0, 0, title, .{ .fg = palette.accent, .bold = true, .bg = bg });
    x += 1;
    const aw = l.gwidth(action) + 2;
    const rule_end = l.width -| aw;
    while (x < rule_end) : (x += 1) _ = ui.text(l, x, 0, "─", .{ .fg = palette.faint, .bg = bg });
    _ = ui.text(
        l,
        rule_end + 1,
        0,
        action,
        .{ .fg = if (span.focused) palette.accent else palette.muted, .bg = bg },
    );
}

fn paragraph(c: *Canvas, body: []const u8, indent: u16, style: ui.Style) Allocator.Error!void {
    const rows = try text_mod.layout(c.f.arena, body, c.win.width -| indent -| 1);
    for (rows) |r| if (c.line()) |l| {
        _ = ui.text(l, indent, 0, text_mod.expandTabs(c.f.arena, body[r.start..r.end]), style);
    };
}

fn progressBar(l: ui.Window, p: issuez.projection.Progress) void {
    const w: u16 = @min(l.width -| 4, 40);
    const filled: u16 = if (p.total == 0) 0 else @intCast(@as(u32, w) * p.closed / p.total);
    var x: u16 = 0;
    while (x < w) : (x += 1) {
        _ = ui.text(
            l,
            2 + x,
            0,
            if (x < filled) "━" else "─",
            .{ .fg = if (x < filled) palette.done else palette.faint },
        );
    }
}

fn issueLine(c: *Canvas, k: u32, prefix: []const u8) Allocator.Error!void {
    const snap = c.s.snap;
    const issue = snap.issues[k];
    const done = snap.isDone(k);
    const span = try c.begin(.{ .open = k });
    if (c.line()) |row| {
        const bg = itemStyle(span).bg;
        row.fill(.{ .style = itemStyle(span) });
        var l: ui.Line = .{ .f = c.f, .win = row, .x = 2 };
        if (prefix.len > 0) l.word(prefix, .{ .fg = palette.muted, .bg = bg });
        const blocked = snap.proj.activelyBlocked(k);
        const glyph = if (issue.deleted) "✗" else if (done) "✓" else if (blocked) "⊘" else "●";
        l.word(glyph, .{
            .fg = if (issue.deleted) palette.err else if (done) palette.done else palette.open,
            .bg = bg,
        });
        l.word(shortId(issue.id), .{ .fg = palette.id, .bg = bg });
        const workflow = snap.proj.workflow(k) orelse issue.state.text();
        const state = if (done) issue.state.text() else workflow;
        const right = c.f.fmt("{s}  {s}", .{ issue.field("Priority") orelse "", state });
        const rw = row.gwidth(right);
        const title_win = row.child(.{ .width = row.width -| rw -| 2 });
        _ = ui.text(title_win, l.x, 0, issue.title, .{
            .fg = if (done or issue.deleted) palette.muted else .default,
            .bg = bg,
            .bold = span.focused,
            .strikethrough = issue.deleted,
        });
        if (snap.proj.progress(k)) |p| {
            const tw = row.gwidth(issue.title);
            _ = ui.text(
                title_win,
                l.x + tw + 1,
                0,
                c.f.fmt("{d}/{d}", .{ p.closed, p.total }),
                .{ .fg = palette.muted, .bg = bg },
            );
        }
        _ = ui.text(row, row.width -| rw, 0, right, .{ .fg = palette.muted, .bg = bg });
    }
    try c.end(span);
}

fn sortedChildren(arena: Allocator, snap: *const Snapshot, i: u32) Allocator.Error![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    for (snap.proj.children[i]) |k| if (!snap.issues[k].deleted) try out.append(arena, k);
    stableSort(u32, out.items, snap, struct {
        fn lt(sn: *const Snapshot, a: u32, b: u32) bool {
            const da = sn.isDone(a);
            const db = sn.isDone(b);
            if (da != db) return !da;
            return sn.issues[a].created < sn.issues[b].created;
        }
    }.lt);
    return out.items;
}

const field_order = std.enums.values(Field);

fn drawFields(c: *Canvas, i: u32) Allocator.Error!void {
    const two = c.win.width >= 90;
    const col_w: u16 = if (two) c.win.width / 2 else c.win.width;
    var n: usize = 0;
    while (n < field_order.len) {
        const per_row: usize = if (two) 2 else 1;
        // Both fields of a row are items on the same line.
        const y = c.y;
        var spans: [2]Canvas.Span = undefined;
        var m: usize = 0;
        while (m < per_row and n + m < field_order.len) : (m += 1) {
            spans[m] = try c.begin(.{ .field = field_order[n + m] });
        }
        const l = c.line();
        for (spans[0..m], 0..) |span, k| {
            const field = field_order[n + k];
            const x: u16 = @intCast(k * col_w);
            if (l) |row| {
                const cell = row.child(.{ .x_off = x, .width = col_w -| 1 });
                if (span.focused) cell.fill(.{ .style = .{ .bg = palette.select_bg } });
                drawField(c, cell, i, field, span.focused);
            }
            if (span.focused) {
                c.focus_top = y;
                c.focus_bottom = y + 1;
            }
            if (l) |row| try c.f.hit(
                row.child(.{ .x_off = x, .width = col_w -| 1 }),
                .{ .item = span.index },
            );
        }
        n += m;
    }
}

fn drawField(c: *Canvas, cell: ui.Window, i: u32, field: Field, focused: bool) void {
    const f = c.f;
    const snap = c.s.snap;
    const issue = snap.issues[i];
    const bg: vaxis.Color = if (focused) palette.select_bg else .default;
    _ = ui.text(cell, 0, 0, field.label(), .{ .fg = palette.muted, .bg = bg });
    const v = cell.child(.{ .x_off = 12 });
    const empty: ui.Style = .{ .fg = palette.faint, .bg = bg };
    const plain: ui.Style = .{ .bg = bg };
    switch (field) {
        .state => {
            const fg = if (snap.isDone(i)) palette.done else palette.open;
            _ = ui.text(v, 0, 0, issue.state.text(), .{ .fg = fg, .bg = bg, .bold = true });
        },
        .workflow => {
            if (snap.proj.workflow(i)) |wf| {
                const x = ui.text(v, 0, 0, wf, .{ .fg = palette.accent, .bg = bg });
                if (issue.workflow == null) _ = ui.text(v, x + 1, 0, "(default)", empty);
            } else _ = ui.text(v, 0, 0, unset, empty);
        },
        .priority => {
            const p = issue.field("Priority");
            const set: ui.Style = .{ .fg = ui.priorityColor(p), .bg = bg, .bold = true };
            _ = fieldValue(v, p, set, empty);
        },
        .assignee => {
            // Everyone assigned; upstream's single `Assignee` otherwise.
            var emails: std.ArrayList([]const u8) = .empty;
            for (issue.assignees) |a| emails.append(f.arena, a.email) catch {};
            const shown = if (emails.items.len > 0)
                std.mem.join(f.arena, ", ", emails.items) catch ""
            else
                issue.field("Assignee") orelse "";
            _ = fieldValue(v, if (shown.len > 0) shown else null, plain, empty);
        },
        .labels => {
            if (issue.labels.len == 0) {
                _ = ui.text(v, 0, 0, unset, empty);
                return;
            }
            var l: ui.Line = .{ .f = f, .win = v };
            for (issue.labels) |lab| {
                l.word(f.fmt(" {s} ", .{lab}), .{ .fg = .{ .index = 16 }, .bg = palette.label });
            }
        },
        .milestone => {
            const m = snap.milestoneName(i);
            const x = fieldValue(v, m, plain, empty);
            if (m != null and issue.milestone_id == null and snap.proj.milestone[i] != null) {
                _ = ui.text(v, x + 1, 0, "(inherited)", empty);
            }
        },
        .parent => {
            const p = snap.proj.parent[i];
            if (p == none) {
                _ = ui.text(v, 0, 0, unset, empty);
            } else {
                var l: ui.Line = .{ .f = f, .win = v };
                l.word(shortId(snap.issues[p].id), .{ .fg = palette.id, .bg = bg });
                l.text(snap.issues[p].title, plain);
            }
        },
        .blocked_by => {
            const bs = snap.proj.blockers[i];
            if (bs.len == 0) {
                _ = ui.text(v, 0, 0, unset, empty);
                return;
            }
            var l: ui.Line = .{ .f = f, .win = v };
            for (bs) |b| l.word(shortId(snap.issues[b].id), .{
                .fg = if (snap.proj.isActive(b)) palette.err else palette.muted,
                .bg = bg,
                .strikethrough = !snap.proj.isActive(b),
            });
        },
        .start, .due => {
            const d = if (field == .start) issue.start_date else issue.due_date;
            _ = fieldValue(v, if (d) |date| f.fmt("{f}", .{date}) else null, plain, empty);
        },
        .estimate => {
            const m = issue.estimate_minutes;
            _ = fieldValue(v, if (m) |minutes| ui.duration(f, minutes) else null, plain, empty);
        },
    }
}

/// A field's value, or what an empty one shows. Returns the columns used.
fn fieldValue(v: ui.Window, value: ?[]const u8, set: ui.Style, empty: ui.Style) u16 {
    return ui.text(v, 0, 0, value orelse unset, if (value != null) set else empty);
}

pub fn key(s: *AppState, k: vaxis.Key) Allocator.Error!AppState.Action {
    const d = &s.detail;
    const i = d.issue(s.snap) orelse {
        if (k.matches(K.escape, .{}) or k.matches(K.backspace, .{}) or k.matches(K.enter, .{}))
            s.back();
        return .none;
    };
    const count: u16 = @intCast(d.items.items.len);
    if (k.matches(K.escape, .{}) or k.matches(K.backspace, .{}) or
        k.matches(K.left, .{}) or k.matches('h', .{}))
    {
        s.back();
    } else if (k.matches(K.down, .{}) or k.matches('j', .{}) or k.matches(K.tab, .{})) {
        if (d.focus + 1 < count) d.focusOn(s.snap, d.focus + 1);
        d.follow = true;
    } else if (k.matches(K.up, .{}) or k.matches('k', .{}) or
        k.matches(K.tab, .{ .shift = true }))
    {
        if (d.focus > d.first) d.focusOn(s.snap, d.focus - 1);
        d.follow = true;
    } else if (k.matches(K.page_down, .{}) or k.matches('d', .{ .ctrl = true })) {
        d.scrollBy(@intCast(d.visible / 2));
    } else if (k.matches(K.page_up, .{}) or k.matches('u', .{ .ctrl = true })) {
        d.scrollBy(-@as(i32, @intCast(d.visible / 2)));
    } else if (k.matches(K.home, .{}) or k.matches('g', .{})) {
        d.focusOn(s.snap, d.first);
        d.scroll = 0;
    } else if (k.matches(K.end, .{}) or k.matches('G', .{})) {
        d.focusOn(s.snap, count -| 1);
        d.follow = true;
    } else if (k.matches(K.enter, .{}) or k.matches(K.space, .{}) or k.matches(K.right, .{})) {
        if (d.focusItem()) |it| return activate(s, i, it);
    } else if (k.matches('t', .{})) {
        return activate(s, i, .title);
    } else if (k.matches('e', .{})) {
        return activate(s, i, .description);
    } else if (k.matches('c', .{})) {
        return activate(s, i, .comment);
    } else if (k.matches('a', .{})) {
        return activate(s, i, .add_child);
    } else if (k.matches('A', .{}) or k.matches('+', .{})) {
        return activate(s, i, .add_existing);
    } else if (k.matches('x', .{})) {
        return activate(s, i, .toggle);
    } else if (k.matches('o', .{})) {
        if (s.snap.proj.parent[i] != none) s.openIssue(s.snap.issues[s.snap.proj.parent[i]].id);
    } else {
        const shortcuts = [_]struct { u21, Field }{
            .{ 's', .state },  .{ 'w', .workflow },  .{ 'p', .priority }, .{ 'u', .assignee },
            .{ 'l', .labels }, .{ 'm', .milestone }, .{ 'P', .parent },   .{ 'b', .blocked_by },
            .{ 'S', .start },  .{ 'd', .due },       .{ 'E', .estimate },
        };
        for (shortcuts) |sc| if (k.matches(sc[0], .{})) return activate(s, i, .{ .field = sc[1] });
    }
    return .none;
}

pub fn click(s: *AppState, index: u16) AppState.Action {
    const d = &s.detail;
    if (index >= d.items.items.len) return .none;
    const it = d.items.items[index];
    if (index >= d.first) d.focusOn(s.snap, index);
    const i = d.issue(s.snap) orelse {
        s.back();
        return .none;
    };
    return activate(s, i, it);
}

fn activate(s: *AppState, i: u32, it: Item) AppState.Action {
    switch (it) {
        .back => s.back(),
        .title => modal.editTitle(s, i),
        .field => |field| modal.editField(s, i, field),
        .description => modal.editDescription(s, i),
        .comment => modal.addComment(s, i),
        .add_child => s.newIssue(i),
        .add_existing => openAdoptPicker(s, i),
        .toggle => return s.toggleAction(i),
        .open => |k| s.openIssue(s.snap.issues[k].id),
    }
    return .none;
}

/// Existing issues to make sub-issues of `i`: any but `i`, its
/// ancestors, which would loop, and its sub-issues already.
pub fn openAdoptPicker(s: *AppState, i: u32) void {
    const snap = s.snap;
    s.closeModal();
    const a = s.modalArena();
    var order: std.ArrayList(u32) = .empty;
    for (snap.issues, 0..) |issue, n| {
        const k: u32 = @intCast(n);
        if (issue.deleted or k == i or snap.proj.parent[k] == i or isAncestor(snap, k, i)) continue;
        order.append(a, k) catch {};
    }
    // Open first, then the most recently touched.
    stableSort(u32, order.items, snap, struct {
        fn lt(sn: *const Snapshot, x: u32, y: u32) bool {
            const dx = sn.isDone(x);
            const dy = sn.isDone(y);
            if (dx != dy) return !dx;
            return sn.issues[x].updated > sn.issues[y].updated;
        }
    }.lt);
    const items = a.alloc(
        modal.Picker.Item,
        order.items.len,
    ) catch return s.fail("out of memory", .{});
    for (order.items, items) |k, *it| {
        const issue = snap.issues[k];
        const p = snap.proj.parent[k];
        it.* = .{
            .label = std.fmt.allocPrint(
                a,
                "#{s} {s}",
                .{ shortId(issue.id), issue.title },
            ) catch "",
            .detail = if (p == none) "" else std.fmt.allocPrint(
                a,
                "sub-issue of #{s}",
                .{shortId(snap.issues[p].id)},
            ) catch "",
            .value = a.dupe(u8, issue.id) catch "",
            .done = snap.isDone(k),
        };
    }
    if (items.len == 0) return s.info(
        "no other issue can be a sub-issue of #{s}",
        .{shortId(snap.issues[i].id)},
    );
    const title = std.fmt.allocPrint(
        a,
        "Add sub-issues to #{s}",
        .{shortId(snap.issues[i].id)},
    ) catch "Add sub-issues";
    s.openModal(.{ .picker = .{
        .title = title,
        .items = items,
        .multi = true,
        .purpose = .{ .adopt = .of(snap.issues[i].id) },
        .verb = "Add",
    } });
}

/// Whether `k` is `i`'s parent, its parent's, and so on.
fn isAncestor(snap: *const Snapshot, k: u32, i: u32) bool {
    var at = snap.proj.parent[i];
    var steps: usize = 0;
    // Bounded: a parent cycle in the data would loop.
    while (at != none and steps < snap.issues.len) : (steps += 1) {
        if (at == k) return true;
        at = snap.proj.parent[at];
    }
    return false;
}

/// Puts the focus on one of the issue's fields, for the next frame.
pub fn focusField(s: *AppState, field: Field) void {
    s.detail.focused = .{ .item = .{ .field = field } };
    s.detail.follow = true;
}

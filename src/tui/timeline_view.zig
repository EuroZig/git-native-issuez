//! The timeline: milestones and issues as bars over the days, with
//! their blockers. Grouped by milestone, zoomable by day, week or month,
//! scrolled with the keys or the wheel.

const std = @import("std");
const stableSort = @import("issuez").sort.stable;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const issuez = @import("issuez");

const ui = @import("ui.zig");
const store = @import("store.zig");
const filter = @import("filter.zig");
const draft_mod = @import("timeline_draft.zig");
const AppState = @import("State.zig");

const Id = store.Id;
const Snapshot = store.Snapshot;
const Scope = filter.MilestoneScope;
const Date = issuez.format.fields.Date;
const schedule = issuez.schedule;
const Span = schedule.Span;
const Projection = issuez.projection.Projection;
const Draft = draft_mod.Draft;
const Op = draft_mod.Op;
const K = vaxis.Key;
const palette = ui.palette;
const shortId = issuez.format.uuid.shortId;
const none = std.math.maxInt(u32);

pub const Zoom = enum {
    day,
    week,
    month,

    /// Cells per day, as a fraction.
    fn num(z: Zoom) i32 {
        return switch (z) {
            .day => 3,
            .week, .month => 1,
        };
    }

    fn den(z: Zoom) i32 {
        return switch (z) {
            .day, .week => 1,
            .month => 4,
        };
    }

    /// What one step of ← → scrolls, in days.
    fn unit(z: Zoom) i32 {
        return switch (z) {
            .day => 1,
            .week => 7,
            .month => 28,
        };
    }

    pub fn label(z: Zoom) []const u8 {
        return switch (z) {
            .day => "Day",
            .week => "Week",
            .month => "Month",
        };
    }
};

pub const Deps = enum {
    selected,
    all,
    off,

    pub fn label(d: Deps) []const u8 {
        return switch (d) {
            .selected => "selected",
            .all => "all",
            .off => "off",
        };
    }
};

pub const Grouping = enum {
    milestone,
    none,

    pub fn label(g: Grouping) []const u8 {
        return switch (g) {
            .milestone => "milestone",
            .none => "none",
        };
    }
};

pub const Row = struct {
    kind: Kind,
    /// Its group, in `groups`.
    group: u32,
    issue: u32 = none,
    depth: u8 = 0,
    /// Shown for a descendant that matches.
    context: bool = false,

    pub const Kind = enum { group, issue, unscheduled, unscheduled_issue };
};

pub const Group = struct {
    scope: Scope,
    /// In the catalog; null for none.
    milestone: ?u32,
    span: ?Span,
    issues: u32 = 0,
    unscheduled: u32 = 0,
};

/// What the selection is on, kept across frames.
pub const Key = union(enum) {
    group: Scope,
    issue: IssueKey,
    unscheduled: Scope,

    /// An issue can show in more than one group: as itself, and above
    /// its sub-issues in others. Null: wherever it is itself.
    pub const IssueKey = struct { id: Id, group: ?Scope = null };

    fn eql(a: Key, b: Key) bool {
        return switch (a) {
            .group => |x| b == .group and x.eql(b.group),
            .unscheduled => |x| b == .unscheduled and x.eql(b.unscheduled),
            .issue => |x| b == .issue and x.id.eql(b.issue.id.slice()) and
                x.group != null and b.issue.group != null and x.group.?.eql(b.issue.group.?),
        };
    }
};

pub const State = struct {
    zoom: Zoom = .week,
    deps: Deps = .selected,
    grouping: Grouping = .milestone,
    /// The day at the chart's left edge, in days since the epoch.
    origin: i32 = 0,
    /// The origin was set: on the first frame, it goes near today.
    placed: bool = false,
    /// Center this day on the next frame.
    center_on: ?i32 = null,
    /// Place the chart at this group's start on the next frame.
    pending_group: ?Scope = null,
    selected: u32 = 0,
    scroll: u32 = 0,
    selected_key: ?Key = null,
    follow: bool = false,
    folded: std.ArrayList(Scope) = .empty,
    /// Groups whose issues without dates are shown.
    unfolded_unscheduled: std.ArrayList(Scope) = .empty,
    // The last frame's.
    rows: []const Row = &.{},
    groups: []const Group = &.{},
    spans: []const ?Span = &.{},
    visible: u16 = 1,
    chart_width: u16 = 1,
    /// Where the chart starts in a row.
    chart_x: u16 = 0,

    /// Edit mode: changes go to `draft`, written when applied.
    editing: bool = false,
    draft: Draft = .{},
    /// Picking the blocker of this issue.
    linking: ?Id = null,
    /// A bar held with the mouse, and what letting go stages.
    bar_drag: ?BarDrag = null,
    preview: ?Op = null,
    /// An issue's row held by its title, to drop on another milestone's
    /// group; the group under the pointer. By ID: a reload while it is
    /// held may move things in the snapshot.
    row_drag: ?struct { issue: Id, from: Scope, over: ?Scope = null } = null,
    // The last frame's, with the draft: dates, blockers and milestones.
    overlay: []const ?schedule.Dates = &.{},
    proj: ?Projection = null,
    plan: ?Draft.Plan = null,
    effective: ?[]const ?[]const u8 = null,

    pub const BarDrag = struct {
        /// By ID, like `row_drag`.
        target: union(enum) { issue: Id, milestone: Id },
        part: enum { body, start, end },
        /// The day under the pointer when pressed.
        anchor: i32,
        /// Where the bar starts and ends as drawn.
        start: ?Date,
        due: ?Date,
        /// What the issue has, or the draft.
        written_start: ?Date,
        written_due: ?Date,
        /// Its tip when pressed: a write elsewhere before letting go
        /// marks the move stale rather than overwriting it.
        tip: ?issuez.engine.Oid = null,
        moved: bool = false,
        /// Days from the anchor, as last dragged.
        delta: i32 = 0,
    };

    pub fn zoomUnit(t: *const State) i32 {
        return t.zoom.unit();
    }

    pub fn deinit(t: *State, gpa: Allocator) void {
        t.folded.deinit(gpa);
        t.unfolded_unscheduled.deinit(gpa);
        t.draft.deinit(gpa);
    }

    /// Net changes in the draft, as of the last frame.
    pub fn changes(t: *const State) usize {
        return if (t.plan) |p| p.count() else 0;
    }

    /// The projection with the draft's blockers.
    pub fn projection(t: *const State, snap: *const Snapshot) *const Projection {
        if (t.proj) |*p| return p;
        return &snap.proj;
    }

    pub fn selectedIssue(t: *const State) ?u32 {
        if (t.selected >= t.rows.len) return null;
        const r = t.rows[t.selected];
        return if (r.kind == .issue or r.kind == .unscheduled_issue) r.issue else null;
    }

    fn keyOf(t: *const State, snap: *const Snapshot, r: Row) Key {
        const g = t.groups[r.group].scope;
        return switch (r.kind) {
            .group => .{ .group = g },
            .unscheduled => .{ .unscheduled = g },
            .issue, .unscheduled_issue => .{
                .issue = .{ .id = .of(snap.issues[r.issue].id), .group = g },
            },
        };
    }

    /// The row of `want`: exactly, else its issue where it is itself, as
    /// after a move to another group.
    fn rowOfKey(t: *const State, snap: *const Snapshot, want: Key) ?u32 {
        for (t.rows, 0..) |r, n| if (t.keyOf(snap, r).eql(want)) return @intCast(n);
        if (want != .issue) return null;
        for (t.rows, 0..) |r, n| {
            if (r.issue == none or r.context) continue;
            if (want.issue.id.eql(snap.issues[r.issue].id)) return @intCast(n);
        }
        return null;
    }

    pub fn moveTo(t: *State, snap: *const Snapshot, row: i64) void {
        if (t.rows.len == 0) return;
        t.selected = @intCast(std.math.clamp(row, 0, @as(i64, @intCast(t.rows.len - 1))));
        t.selected_key = t.keyOf(snap, t.rows[t.selected]);
        t.follow = true;
    }

    pub fn scrollBy(t: *State, delta: i32) void {
        const max: i64 = @intCast(t.rows.len -| t.visible);
        t.scroll = @intCast(std.math.clamp(@as(i64, t.scroll) + delta, 0, max));
    }

    fn visibleDays(t: *const State) i32 {
        return @divFloor(@as(i32, t.chart_width) * t.zoom.den(), t.zoom.num());
    }

    pub fn scrollDays(t: *State, days: i32) void {
        t.origin = std.math.clamp(t.origin +| days, Date.min_days, Date.max_days - t.visibleDays());
    }

    pub fn x(t: *const State, day: i32) i32 {
        return @divFloor((day - t.origin) * t.zoom.num(), t.zoom.den());
    }

    pub fn dayAt(t: *const State, col: i32) i32 {
        return t.origin + @divFloor(col * t.zoom.den(), t.zoom.num());
    }

    fn isFolded(t: *const State, scope: Scope) bool {
        for (t.folded.items) |f| if (f.eql(scope)) return true;
        return false;
    }

    fn showsUnscheduled(t: *const State, scope: Scope) bool {
        for (t.unfolded_unscheduled.items) |f| if (f.eql(scope)) return true;
        return false;
    }

    fn toggle(list: *std.ArrayList(Scope), gpa: Allocator, scope: Scope) Allocator.Error!void {
        for (list.items, 0..) |f, n| if (f.eql(scope)) {
            _ = list.swapRemove(n);
            return;
        };
        try list.append(gpa, scope);
    }

    /// The selected row's span, or today: what zooming keeps in place.
    fn anchor(t: *const State, today: Date) i32 {
        if (t.selected < t.rows.len) {
            const r = t.rows[t.selected];
            if (r.issue != none) if (t.spans[r.issue]) |sp| return sp.start.toDays();
            if (r.kind == .group) if (t.groups[r.group].span) |sp| return sp.start.toDays();
        }
        return today.toDays();
    }
};

/// What the timeline shows for an issue: its own dates, or the draft's.
pub fn datesOf(s: *const AppState, i: u32) schedule.Dates {
    const t = &s.timeline;
    if (i < t.overlay.len) if (t.overlay[i]) |d| return d;
    return schedule.Dates.of(&s.snap.issues[i]);
}

/// A milestone's due date, or the draft's.
pub fn milestoneDue(s: *const AppState, n: u32) ?Date {
    const m = s.snap.milestones[n];
    const t = &s.timeline;
    if (t.editing) {
        if (t.preview) |p| if (p == .milestone_due and p.milestone_due.id.eql(
            m.id,
        )) return p.milestone_due.due;
        if (t.draft.milestoneDue(m.id)) |d| return d;
    }
    return m.due;
}

/// The draft's dates, blockers and milestones over the snapshot, for one
/// frame: a dragged bar's preview last.
fn buildOverlay(s: *AppState, arena: Allocator) Allocator.Error!?[]const ?[]const u8 {
    const t = &s.timeline;
    const snap = s.snap;
    t.overlay = &.{};
    t.proj = null;
    t.plan = null;
    if (!t.editing) return null;
    // Gone elsewhere: their changes go too.
    t.plan = try t.draft.plan(arena, snap);
    const deleted = t.plan.?.gone;
    if (deleted.len > 0) {
        for (deleted) |g| t.draft.drop(g.slice());
        s.info(
            "{d} edited issues were deleted elsewhere: their changes are dropped",
            .{deleted.len},
        );
        t.plan = try t.draft.plan(arena, snap);
    }
    const ov = try arena.alloc(?schedule.Dates, snap.issues.len);
    @memset(ov, null);
    var blockers_changed = false;
    const ops = t.draft.active();
    for (0..ops.len + 1) |n| {
        const op = if (n < ops.len) ops[n] else t.preview orelse break;
        const i = snap.find(op.target().slice()) orelse continue;
        switch (op) {
            .dates => |x| {
                var d = ov[i] orelse schedule.Dates.of(&snap.issues[i]);
                if (x.start) |v| d.start = v;
                if (x.due) |v| d.due = v;
                ov[i] = d;
            },
            .estimate => |x| {
                var d = ov[i] orelse schedule.Dates.of(&snap.issues[i]);
                d.estimate_minutes = x.minutes;
                ov[i] = d;
            },
            .add_blocker, .remove_blocker => blockers_changed = true,
            .milestone, .milestone_due => {},
        }
    }
    t.overlay = ov;
    if (blockers_changed) {
        var p = snap.proj;
        const blockers = try arena.dupe([]const u32, p.blockers);
        for (t.plan.?.issues) |c| {
            if (c.add.len == 0 and c.remove.len == 0) continue;
            const i = snap.find(c.id.slice()) orelse continue;
            var list: std.ArrayList(u32) = .empty;
            for (blockers[i]) |b| {
                const gone = for (c.remove) |*x| {
                    if (x.eql(snap.issues[b].id)) break true;
                } else false;
                if (!gone) try list.append(arena, b);
            }
            for (c.add) |*x| if (snap.find(x.slice())) |b| try list.append(arena, b);
            blockers[i] = list.items;
        }
        const blocks = try arena.alloc(std.ArrayList(u32), blockers.len);
        for (blocks) |*b| b.* = .empty;
        for (blockers, 0..) |list, i| for (list) |b| try blocks[b].append(arena, @intCast(i));
        const blocks_out = try arena.alloc([]const u32, blockers.len);
        for (blocks, blocks_out) |b, *o| o.* = b.items;
        p.blockers = blockers;
        p.blocks = blocks_out;
        t.proj = p;
    }
    return try draft_mod.effectiveMilestones(arena, &t.draft, snap);
}

pub fn calendar(s: *const AppState) schedule.Calendar {
    return .{
        .work_days = s.snap.settings.work_days,
        .hours_per_day = s.snap.settings.hours_per_day,
    };
}

/// Opens the timeline on a milestone's group, or on the issues in none.
pub fn showGroup(s: *AppState, scope: Scope) void {
    const t = &s.timeline;
    t.grouping = .milestone;
    t.selected_key = .{ .group = scope };
    t.follow = true;
    for (t.folded.items, 0..) |f, n| if (f.eql(scope)) {
        _ = t.folded.swapRemove(n);
        break;
    };
    // Its start, once the frame knows the spans.
    t.center_on = null;
    t.placed = false;
    t.pending_group = scope;
}

// Spans.

/// Each issue's own span, else its sub-issues' together: a parent
/// without dates shows over its work.
fn treeSpans(arena: Allocator, snap: *const Snapshot, own: []const ?Span) Allocator.Error![]?Span {
    const out = try arena.dupe(?Span, own);
    // Deepest first, so children are done before their parents: by
    // depth, counted.
    const depth = snap.proj.depth;
    var max_depth: u32 = 0;
    for (depth) |d| max_depth = @max(max_depth, d);
    const ends = try arena.alloc(u32, @as(usize, max_depth) + 1);
    @memset(ends, 0);
    for (depth) |d| ends[max_depth - d] += 1;
    var sum: u32 = 0;
    for (ends) |*e| {
        sum += e.*;
        e.* = sum;
    }
    const order = try arena.alloc(u32, snap.issues.len);
    var n = depth.len;
    while (n > 0) {
        n -= 1;
        const slot = &ends[max_depth - depth[n]];
        slot.* -= 1;
        order[slot.*] = @intCast(n);
    }
    const merged = try arena.alloc(?Span, snap.issues.len);
    @memset(merged, null);
    for (order) |i| {
        if (snap.issues[i].deleted) continue;
        const mine = merged[i];
        if (out[i] == null) out[i] = mine;
        // Up to the parent: its children's union.
        const p = snap.proj.parent[i];
        if (p == none) continue;
        const sp = out[i] orelse continue;
        if (merged[p]) |*m| {
            if (sp.start.order(m.start) == .lt) m.start = sp.start;
            if (sp.end.order(m.end) == .gt) m.end = sp.end;
        } else merged[p] = .{
            .start = sp.start,
            .end = sp.end,
            .shape = .bar,
            .derived_start = true,
            .derived_end = true,
        };
    }
    return out;
}

// Rows.

fn buildRows(
    s: *AppState,
    arena: Allocator,
    tree: []const ?Span,
    effective: ?[]const ?[]const u8,
) Allocator.Error!void {
    const t = &s.timeline;
    const snap = s.snap;
    var groups: std.ArrayList(Group) = .empty;
    var rows: std.ArrayList(Row) = .empty;
    var q = s.currentQuery();
    q.tree = true;
    q.effective = effective;
    var proj = snap.proj;
    if (effective) |e| proj.milestone = e;

    // Every match with its ancestors, sorted, once: each group takes its
    // own matches from it, with their ancestors as context.
    q.milestone = null;
    const all = try filter.rows(arena, snap, q);
    const n = snap.issues.len;
    var scopes: std.ArrayList(Scope) = .empty;
    // Each issue's group, by its effective milestone; none when not shown.
    const group_of = try arena.alloc(u32, n);
    @memset(group_of, none);
    if (t.grouping == .milestone) {
        var index: std.StringHashMapUnmanaged(u32) = .empty;
        for (snap.milestones) |m| {
            // Keep a staged milestone reachable if its status changed elsewhere.
            const staged = t.editing and t.draft.milestoneDue(m.id) != null;
            if (!staged and m.status == .retired) continue;
            if (!staged and m.status == .completed and q.scope == .open) continue;
            try index.put(arena, m.id, @intCast(scopes.items.len));
            try scopes.append(arena, .{ .id = .of(m.id) });
        }
        const in_none: u32 = @intCast(scopes.items.len);
        try scopes.append(arena, .none);
        for (all) |r| {
            group_of[r.issue] = if (proj.milestone[r.issue]) |m| index.get(
                m,
            ) orelse none else in_none;
        }
    }
    const pos = try arena.alloc(u32, n);
    for (all, 0..) |r, k| pos[r.issue] = @intCast(k);
    const mark = try arena.alloc(u32, n);
    @memset(mark, none);
    var picked: std.ArrayList(u32) = .empty;

    const group_count = if (t.grouping == .milestone) scopes.items.len else 1;
    for (0..group_count) |gi| {
        const scope: ?Scope = if (t.grouping == .milestone) scopes.items[gi] else null;
        // Its rows, as positions in `all`.
        picked.clearRetainingCapacity();
        if (scope == null) {
            for (0..all.len) |k| try picked.append(arena, @intCast(k));
        } else {
            for (all) |r| {
                if (r.context or group_of[r.issue] != gi) continue;
                var x = r.issue;
                var guard: usize = 0;
                while (x != none and mark[x] != gi and guard <= n) : (guard += 1) {
                    mark[x] = @intCast(gi);
                    try picked.append(arena, pos[x]);
                    x = snap.proj.parent[x];
                }
            }
            stableSort(u32, picked.items, {}, std.sort.asc(u32));
        }
        const m: ?u32 = if (scope) |sc| switch (sc) {
            .none => null,
            .id => |id| snap.findMilestone(id.slice()),
        } else null;
        var g: Group = .{
            .scope = scope orelse .none,
            .milestone = m,
            .span = if (m) |x| schedule.milestoneSpan(
                &proj,
                tree,
                snap.milestones[x].id,
                milestoneDue(s, x),
            ) else null,
        };
        // The issues in none: shown when there are some.
        if (scope != null and scope.? == .none and picked.items.len == 0) continue;
        const g_index: u32 = @intCast(groups.items.len);
        if (scope != null) try rows.append(arena, .{ .kind = .group, .group = g_index });
        const folded = scope != null and t.isFolded(scope.?);
        var unscheduled: std.ArrayList(Row) = .empty;
        for (picked.items) |k| {
            const r = all[k];
            const context = r.context or (scope != null and group_of[r.issue] != gi);
            if (!context) g.issues += 1;
            const row: Row = .{
                .kind = .issue,
                .group = g_index,
                .issue = r.issue,
                .depth = r.depth,
                .context = context,
            };
            if (tree[r.issue] == null) {
                if (!context) {
                    g.unscheduled += 1;
                    try unscheduled.append(
                        arena,
                        .{ .kind = .unscheduled_issue, .group = g_index, .issue = r.issue },
                    );
                }
                continue;
            }
            if (!folded) try rows.append(arena, row);
        }
        if (!folded and g.unscheduled > 0) {
            try rows.append(arena, .{ .kind = .unscheduled, .group = g_index });
            if (t.showsUnscheduled(g.scope)) try rows.appendSlice(arena, unscheduled.items);
        }
        try groups.append(arena, g);
    }
    t.groups = groups.items;
    t.rows = rows.items;
}

// Drawing.

/// Cells a bar covers, clipped to the chart.
fn cells(
    t: *const State,
    sp: Span,
    width: u16,
) ?struct { from: u16, to: u16, cut_left: bool, cut_right: bool } {
    const a = t.x(sp.start.toDays());
    const b = @max(t.x(sp.end.toDays() + 1) - 1, a);
    if (b < 0 or a >= width) return null;
    return .{
        .from = @intCast(@max(a, 0)),
        .to = @intCast(@min(b, @as(i32, width) - 1)),
        .cut_left = a < 0,
        .cut_right = b >= width,
    };
}

const Grid = struct {
    taken: []bool,
    width: u16,

    fn set(g: Grid, row: u16, col: u16) void {
        g.taken[@as(usize, row) * g.width + col] = true;
    }

    fn get(g: Grid, row: u16, col: u16) bool {
        return g.taken[@as(usize, row) * g.width + col];
    }
};

pub fn draw(s: *AppState, f: ui.Frame, win: ui.Window) Allocator.Error!void {
    const t = &s.timeline;
    const snap = s.snap;
    const cal = calendar(s);
    const today = s.today;

    const effective = try buildOverlay(s, f.arena);
    const own = try f.arena.alloc(?Span, snap.issues.len);
    for (own, 0..) |*o, n| o.* = schedule.span(datesOf(s, @intCast(n)), cal);
    const tree = try treeSpans(f.arena, snap, own);
    t.spans = tree;
    t.effective = effective;
    try buildRows(s, f.arena, tree, effective);

    // Keep the selection on its row.
    if (t.selected_key) |want| {
        if (t.rowOfKey(snap, want)) |n| t.selected = n;
    }
    if (t.selected >= t.rows.len) t.selected = @intCast(t.rows.len -| 1);
    if (t.rows.len > 0) t.selected_key = t.keyOf(snap, t.rows[t.selected]);

    try drawBar(s, f, win.child(.{ .height = 1 }));
    const panel_h: u16 = if (win.height > 16) 2 else 0;
    const left_w: u16 = std.math.clamp(win.width / 4, 16, 40);
    const chart_x = left_w + 1;
    t.chart_x = chart_x;
    const chart_w: u16 = win.width -| chart_x;
    t.chart_width = @max(chart_w, 1);
    const head = win.child(.{ .x_off = chart_x, .y_off = 1, .width = chart_w, .height = 2 });
    const body_h = win.height -| (3 + panel_h);
    const body = win.child(.{ .y_off = 3, .height = body_h });
    t.visible = @max(body_h, 1);

    if (!t.placed) {
        t.placed = true;
        const start = if (t.pending_group) |pg| blk: {
            t.pending_group = null;
            for (t.groups) |g| if (g.scope.eql(pg)) if (g.span) |sp| break :blk sp.start.toDays();
            break :blk today.toDays();
        } else today.toDays();
        t.origin = start - @divFloor(t.visibleDays(), 5);
    }
    if (t.center_on) |c| {
        t.origin = c - @divFloor(t.visibleDays(), 2);
        t.center_on = null;
    }
    if (t.follow) {
        if (t.selected < t.scroll) t.scroll = t.selected;
        if (t.selected >= t.scroll + t.visible) t.scroll = t.selected - t.visible + 1;
        t.follow = false;
    }
    t.scroll = @min(t.scroll, @as(u32, @intCast(t.rows.len -| t.visible)));

    try drawHeader(s, f, head, today);
    if (t.rows.len == 0) {
        const msg =
            if (snap.issues.len == 0) "No issues yet." else "Nothing to show: no issues match.";
        _ = ui.text(
            body,
            (body.width -| body.gwidth(msg)) / 2,
            body.height / 2,
            msg,
            .{ .fg = palette.muted },
        );
        return;
    }

    const grid_w: u16 = @max(chart_w, 1);
    const grid: Grid = .{
        .taken = try f.arena.alloc(bool, @as(usize, body.height) * grid_w),
        .width = grid_w,
    };
    @memset(grid.taken, false);
    const chart = body.child(.{ .x_off = chart_x, .width = chart_w });

    // Days: non-working ones shaded at day zoom, and today.
    const today_x = t.x(today.toDays());
    var cx: u16 = 0;
    while (cx < chart_w) : (cx += 1) {
        const d = Date.fromDays(t.dayAt(cx));
        const off = t.zoom == .day and !cal.work_days.isWorkDay(d);
        if (off) chart.child(
            .{ .x_off = cx, .width = 1 },
        ).fill(.{ .style = .{ .bg = palette.panel_bg } });
    }

    const sel_issue = t.selectedIssue();
    var y: u16 = 0;
    while (y < body.height and t.scroll + y < t.rows.len) : (y += 1) {
        const index = t.scroll + y;
        const r = t.rows[index];
        const selected = index == t.selected;
        const row_win = body.child(.{ .y_off = y, .height = 1 });
        if (selected) row_win.fill(.{ .style = .{ .bg = palette.select_bg } });
        // The group a held row would go to.
        if (t.row_drag) |rd| if (rd.over) |o| if (r.kind == .group and !o.eql(
            rd.from,
        ) and o.eql(t.groups[r.group].scope)) {
            row_win.fill(.{ .style = .{ .bg = palette.hover_bg } });
        };
        if (today_x >= 0 and today_x < chart_w) {
            _ = ui.text(
                chart,
                @intCast(today_x),
                y,
                "┊",
                .{ .fg = palette.accent_bg, .bg = if (selected) palette.select_bg else .default },
            );
        }
        try drawLabel(s, f, row_win.child(.{ .width = left_w }), r, selected);
        try drawChartRow(
            s,
            f,
            chart.child(.{ .y_off = y, .height = 1 }),
            grid,
            y,
            r,
            selected,
            own,
        );
        try f.hit(row_win, .{ .tl_row = index });
        // The gutter: blockers of the selected issue, what it blocks,
        // and what doesn't fit.
        if (r.issue != none and
            (r.kind == .issue or (t.editing and r.kind == .unscheduled_issue)))
        {
            const gutter = row_win.child(.{ .x_off = left_w, .width = 1 });
            const proj = t.projection(snap);
            const mark: ?struct { []const u8, vaxis.Color } = blk: {
                if (t.editing) {
                    const id = snap.issues[r.issue].id;
                    if (isStale(t, id)) break :blk .{ "!", palette.err };
                    if (isChanged(t, id)) break :blk .{ "✎", palette.medium };
                }
                if (sel_issue) |si| if (si != r.issue) {
                    for (proj.blockers[si]) |b| if (b == r.issue) break :blk .{ "◀", palette.err };
                    for (proj.blocks[si]) |b| if (b == r.issue) break :blk .{ "▶", palette.medium };
                };
                var wbuf: [4]schedule.Warning = undefined;
                if (warningsOf(s, r.issue, &wbuf).len > 0) break :blk .{ "⚠", palette.medium };
                break :blk null;
            };
            if (mark) |m| _ = ui.text(
                gutter,
                0,
                0,
                m[0],
                .{ .fg = m[1], .bg = if (selected) palette.select_bg else .default },
            );
        }
    }
    if (t.deps != .off) try drawDeps(s, f.arena, chart, grid);

    if (panel_h > 0) try drawPanel(
        s,
        f,
        win.child(.{ .y_off = win.height - panel_h, .height = panel_h }),
    );
}

pub fn warningsOf(s: *const AppState, i: u32, buf: []schedule.Warning) []const schedule.Warning {
    const t = &s.timeline;
    const snap = s.snap;
    // Its milestone with the draft's moves.
    const milestone = if (t.effective) |e| e[i] else snap.proj.milestone[i];
    const due: ?Date = if (milestone) |mid| if (snap.findMilestone(mid)) |n| milestoneDue(
        s,
        n,
    ) else null else null;
    return schedule.warnings(t.projection(snap), t.spans, datesOf(s, i), due, i, buf);
}

fn isChanged(t: *const State, id: []const u8) bool {
    const p = t.plan orelse return false;
    for (p.issues) |*c| if (c.id.eql(id)) return true;
    for (p.milestones) |*c| if (c.id.eql(id)) return true;
    return false;
}

fn isStale(t: *const State, id: []const u8) bool {
    const p = t.plan orelse return false;
    for (p.stale) |*x| if (x.eql(id)) return true;
    return false;
}

fn drawBar(s: *AppState, f: ui.Frame, bar: ui.Window) Allocator.Error!void {
    const t = &s.timeline;
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
    const box_w: u16 = @min(@max(bar.width / 4, 16), 40);
    const box = bar.child(.{ .x_off = col, .width = box_w, .height = 1 });
    try s.tl_search.draw(
        f.arena,
        box,
        .{ .bg = palette.input_bg },
        s.search_focused,
        "filter: words, label:x, @who, is:blocked",
    );
    try f.hit(box, .search);
    col += box_w + 2;
    const q = s.tl_query;
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
    for (std.enums.values(Zoom)) |z| {
        col += try ui.button(
            f,
            bar,
            col,
            0,
            z.label(),
            .{ .tl_zoom = z },
            ui.buttonStyle(t.zoom == z),
        );
    }
    col += 1;
    col += try ui.button(f, bar, col, 0, "◀", .{ .tl_command = .earlier }, ui.buttonStyle(false));
    col += try ui.button(f, bar, col, 0, "Today", .{ .tl_command = .today }, ui.buttonStyle(false));
    col += try ui.button(f, bar, col, 0, "▶", .{ .tl_command = .later }, ui.buttonStyle(false));
    col += 2;
    col += try ui.button(
        f,
        bar,
        col,
        0,
        f.fmt("Deps: {s}", .{t.deps.label()}),
        .{ .tl_command = .deps },
        ui.buttonStyle(false),
    );
    col += 1;
    col += try ui.button(
        f,
        bar,
        col,
        0,
        f.fmt("Group: {s}", .{t.grouping.label()}),
        .{ .tl_command = .grouping },
        ui.buttonStyle(false),
    );
    if (!t.editing) {
        const label = "✎ E edit";
        const w = bar.gwidth(label) + 2;
        if (bar.width > col +| w +| 2) _ = try ui.button(
            f,
            bar,
            bar.width - w - 1,
            0,
            label,
            .{ .tl_command = .edit },
            ui.buttonStyle(true),
        );
    }
}

const months = [_][]const u8{
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
};

fn drawHeader(s: *AppState, f: ui.Frame, head: ui.Window, today: Date) Allocator.Error!void {
    const t = &s.timeline;
    try f.hit(head, .tl_header);
    const today_x = t.x(today.toDays());
    var month_free: u16 = 0;
    var day_free: u16 = 0;
    var cx: u16 = 0;
    while (cx < head.width) : (cx += 1) {
        const day = t.dayAt(cx);
        // Only the first cell of a day, and at month zoom of four.
        if (cx > 0 and t.dayAt(cx - 1) == day) continue;
        const d = Date.fromDays(day);
        // Months: where one starts, and at the left edge unless one
        // starts right after.
        const starts = d.day == 1 or (t.zoom == .month and d.day <= 4 and cx > 0);
        // At month zoom a month is a few cells: the year only in January.
        const label = if (t.zoom == .month)
            (if (d.month == 1) f.fmt("{d}", .{d.year}) else months[d.month - 1])
        else
            f.fmt("{s} {d}", .{ months[d.month - 1], d.year });
        const room: i32 = @intCast(head.gwidth(label) + 2);
        const next_month = Date{ .year = d.year, .month = d.month, .day = 1 };
        const next_x = t.x(next_month.addDays(next_month.daysInMonth()).toDays());
        const edge = cx == 0 and next_x - @as(i32, cx) > room;
        if ((starts or edge) and cx >= month_free) {
            _ = ui.text(head, cx, 0, "│", .{ .fg = palette.faint });
            const w = ui.text(head, cx + 1, 0, label, .{ .fg = palette.accent, .bold = true });
            month_free = cx +| w +| 2;
        }
        const show = switch (t.zoom) {
            .day => true,
            .week => d.weekday() == .mon,
            .month => false,
        };
        if (!show or cx < day_free) continue;
        const text = if (t.zoom == .day) f.fmt("{d: >2}", .{d.day}) else f.fmt("{d}", .{d.day});
        const w: i32 = @intCast(head.gwidth(text));
        const is_today = d.eql(today);
        // At day zoom today is its number; otherwise a mark goes there.
        if (t.zoom != .day and today_x >= cx and today_x < @as(i32, cx) + w) continue;
        _ = ui.text(
            head,
            cx,
            1,
            text,
            if (is_today) .{
                .fg = .{ .index = 231 },
                .bg = palette.accent_bg,
                .bold = true,
            } else .{ .fg = palette.muted },
        );
        day_free = cx +| @as(u16, @intCast(w)) +| 1;
    }
    if (t.zoom != .day and today_x >= 0 and today_x < head.width) {
        _ = ui.text(head, @intCast(today_x), 1, "▼", .{ .fg = palette.accent, .bold = true });
    }
}

fn drawLabel(
    s: *AppState,
    f: ui.Frame,
    win: ui.Window,
    r: Row,
    selected: bool,
) Allocator.Error!void {
    const t = &s.timeline;
    const snap = s.snap;
    const bg: vaxis.Color = if (selected) palette.select_bg else .default;
    _ = ui.text(win, 0, 0, if (selected) "▌" else " ", .{ .fg = palette.accent, .bg = bg });
    switch (r.kind) {
        .group => {
            const g = t.groups[r.group];
            const folded = t.isFolded(g.scope);
            var x: u16 = 1;
            x += ui.text(win, x, 0, if (folded) "▸ " else "▾ ", .{ .fg = palette.muted, .bg = bg });
            if (g.milestone) |n| {
                const m = snap.milestones[n];
                x += ui.text(win, x, 0, "◆ ", .{ .fg = palette.accent, .bg = bg });
                x += ui.text(win, x, 0, m.name, .{ .fg = palette.accent, .bg = bg, .bold = true });
            } else x += ui.text(
                win,
                x,
                0,
                "(no milestone)",
                .{ .fg = palette.muted, .bg = bg, .italic = true },
            );
            _ = ui.text(
                win,
                x + 1,
                0,
                f.fmt("{d}", .{g.issues}),
                .{ .fg = palette.faint, .bg = bg },
            );
        },
        .issue, .unscheduled_issue => {
            const i = r.issue;
            const issue = snap.issues[i];
            const done = snap.isDone(i);
            var x: u16 = 1 + @as(u16, @min(r.depth, 6)) * 2;
            if (t.grouping == .milestone) x += 2;
            if (r.kind == .unscheduled_issue) x += 2;
            const blocked = t.projection(snap).activelyBlocked(i);
            x += ui.text(
                win,
                x,
                0,
                if (done) "✓ " else if (blocked) "⊘ " else "● ",
                .{
                    .fg = if (done) palette.done else if (blocked) palette.err else palette.open,
                    .bg = bg,
                    .dim = r.context,
                },
            );
            _ = ui.text(win, x, 0, issue.title, .{
                .fg = if (done or r.context) palette.muted else .default,
                .bg = bg,
                .bold = selected,
                .strikethrough = done and issue.state == .closed,
            });
        },
        .unscheduled => {
            const g = t.groups[r.group];
            const open = t.showsUnscheduled(g.scope);
            const x: u16 = if (t.grouping == .milestone) 3 else 1;
            _ = ui.text(
                win,
                x,
                0,
                f.fmt("{s} {d} without dates", .{ if (open) "▾" else "▸", g.unscheduled }),
                .{ .fg = palette.muted, .bg = bg, .italic = true },
            );
        },
    }
}

fn drawChartRow(
    s: *AppState,
    f: ui.Frame,
    win: ui.Window,
    grid: Grid,
    y: u16,
    r: Row,
    selected: bool,
    own: []const ?Span,
) Allocator.Error!void {
    _ = f;
    const t = &s.timeline;
    const snap = s.snap;
    const bg: vaxis.Color = if (selected) palette.select_bg else .default;
    switch (r.kind) {
        .unscheduled, .unscheduled_issue => {},
        .group => {
            const g = t.groups[r.group];
            const n = g.milestone orelse return;
            const m = snap.milestones[n];
            if (g.span) |sp| if (cells(t, sp, win.width)) |c| {
                var cx = c.from;
                while (cx <= c.to) : (cx += 1) {
                    _ = ui.text(win, cx, 0, "━", .{ .fg = palette.accent, .bg = bg });
                    grid.set(y, cx);
                }
            };
            if (t.editing and m.due != null) if (milestoneDue(s, n)) |due| if (!due.eql(m.due.?)) {
                // Where it was.
                const ox = t.x(m.due.?.toDays());
                if (ox >= 0 and ox < win.width) _ = ui.text(
                    win,
                    @intCast(ox),
                    0,
                    "◇",
                    .{ .fg = palette.faint, .bg = bg },
                );
            };
            if (milestoneDue(s, n)) |due| {
                const dx = t.x(due.toDays());
                if (dx >= 0 and dx < win.width) {
                    const moved = t.editing and isChanged(t, m.id);
                    _ = ui.text(
                        win,
                        @intCast(dx),
                        0,
                        "◆",
                        .{
                            .fg = if (moved)
                                palette.medium
                            else if (m.status == .completed)
                                palette.done
                            else
                                palette.accent,
                            .bg = bg,
                            .bold = true,
                        },
                    );
                    grid.set(y, @intCast(dx));
                }
            }
        },
        .issue => {
            const i = r.issue;
            const sp = t.spans[i] orelse return;
            const done = snap.isDone(i);
            const blocked = t.projection(snap).activelyBlocked(i);
            const late = !done and sp.end.order(s.today) == .lt;
            const changed = t.editing and isChanged(t, snap.issues[i].id);
            const color: vaxis.Color = if (changed)
                palette.medium
            else if (done)
                palette.done
            else if (blocked)
                palette.err
            else if (selected)
                palette.accent
            else
                palette.open;
            // Where a changed bar was.
            if (changed) if (schedule.span(
                schedule.Dates.of(&snap.issues[i]),
                calendar(s),
            )) |old| if (cells(t, old, win.width)) |oc| {
                var cx = oc.from;
                while (cx <= oc.to) : (cx += 1) _ = ui.text(
                    win,
                    cx,
                    0,
                    "┄",
                    .{ .fg = palette.faint, .bg = bg },
                );
            };
            const c = cells(t, sp, win.width) orelse return;
            // A parent with no dates of its own spans its work.
            if (own[i] == null) {
                var cx = c.from;
                while (cx <= c.to) : (cx += 1) {
                    const glyph: []const u8 = if (cx == c.from and
                        !c.cut_left) "▕" else if (cx == c.to and !c.cut_right) "▏" else "━";
                    _ = ui.text(win, cx, 0, glyph, .{ .fg = palette.muted, .bg = bg });
                    grid.set(y, cx);
                }
                return;
            }
            switch (sp.shape) {
                .due => {
                    _ = ui.text(
                        win,
                        c.from,
                        0,
                        "◇",
                        .{ .fg = if (late) palette.err else color, .bg = bg, .bold = true },
                    );
                    grid.set(y, c.from);
                },
                .start => {
                    _ = ui.text(win, c.from, 0, "▶", .{ .fg = color, .bg = bg });
                    grid.set(y, c.from);
                    var cx = c.from + 1;
                    while (cx < win.width and cx <= c.from +| 3) : (cx += 1) {
                        _ = ui.text(win, cx, 0, "┄", .{ .fg = palette.faint, .bg = bg });
                        grid.set(y, cx);
                    }
                },
                .bar => {
                    // The done share of its leaves fills from the left.
                    const share: f32 = if (snap.proj.progress(i)) |p| @as(
                        f32,
                        @floatFromInt(p.closed),
                    ) / @as(f32, @floatFromInt(@max(p.total, 1))) else if (done) 1 else 0;
                    const full_to = t.x(
                        sp.start.toDays(),
                    ) + @as(
                        i32,
                        @intFromFloat(
                            @round(
                                share * @as(f32, @floatFromInt(@max(
                                    t.x(sp.end.toDays() + 1) - t.x(sp.start.toDays()),
                                    1,
                                ))),
                            ),
                        ),
                    );
                    var cx = c.from;
                    while (cx <= c.to) : (cx += 1) {
                        const derived =
                            (sp.derived_start and cx == c.from) or (sp.derived_end and cx == c.to);
                        const filled = done or cx < full_to;
                        const parent = snap.proj.progress(i) != null;
                        const glyph: []const u8 =
                            if (derived) "▒" else if (parent and !filled) "▒" else "█";
                        const fg = if (late and cx == c.to) palette.err else color;
                        _ = ui.text(win, cx, 0, glyph, .{ .fg = fg, .bg = bg });
                        grid.set(y, cx);
                    }
                },
            }
        },
    }
}

/// Lines from a blocker's end to the start of what it blocks, through
/// free cells only.
fn drawDeps(s: *AppState, arena: Allocator, chart: ui.Window, grid: Grid) Allocator.Error!void {
    const t = &s.timeline;
    const snap = s.snap;
    const proj = t.projection(snap);
    const sel = t.selectedIssue();
    // Where each shown issue's row is: its first.
    const row_of = try arena.alloc(u32, snap.issues.len);
    @memset(row_of, none);
    var n = t.rows.len;
    while (n > 0) {
        n -= 1;
        const r = t.rows[n];
        if (r.kind == .issue) row_of[r.issue] = @intCast(n);
    }
    var y: u16 = 0;
    while (y < chart.height and t.scroll + y < t.rows.len) : (y += 1) {
        const r = t.rows[t.scroll + y];
        if (r.kind != .issue) continue;
        const i = r.issue;
        for (proj.blockers[i]) |b| {
            if (t.deps == .selected and sel != i and sel != b) continue;
            if (!proj.isActive(b)) continue;
            const by = row_of[b];
            if (by == none) continue;
            if (by < t.scroll or by >= t.scroll + chart.height) continue;
            const from = t.spans[b] orelse continue;
            const to = t.spans[i] orelse continue;
            const x1 = t.x(from.end.toDays() + 1);
            const x2 = t.x(to.start.toDays()) - 1;
            const faint = t.deps == .all and sel != i and sel != b;
            const fg = if (faint) palette.faint else if (x2 < x1) palette.err else palette.medium;
            line(chart, grid, @intCast(by - t.scroll), y, x1, x2, fg);
        }
    }
}

fn put(chart: ui.Window, grid: Grid, row: u16, col: i32, glyph: []const u8, fg: vaxis.Color) void {
    if (col < 0 or col >= chart.width or row >= chart.height) return;
    const c: u16 = @intCast(col);
    if (grid.get(row, c)) return;
    _ = ui.text(chart, c, row, glyph, .{ .fg = fg });
}

/// From (r1, x1) across, down or up at x1, then across to x2 with an
/// arrow. With x2 before x1 the dependent starts too early: the line
/// goes back.
fn line(chart: ui.Window, grid: Grid, r1: u16, r2: u16, x1: i32, x2: i32, fg: vaxis.Color) void {
    if (r1 == r2) return;
    const down = r2 > r1;
    put(chart, grid, r1, x1, if (down) "┐" else "┘", fg);
    var r = if (down) r1 + 1 else r2 + 1;
    const end = if (down) r2 else r1;
    while (r < end) : (r += 1) put(chart, grid, r, x1, "│", fg);
    // Across: only where the chart is.
    const w: i32 = chart.width;
    if (x2 >= x1) {
        put(chart, grid, r2, x1, if (down) "└" else "┌", fg);
        var x = @max(x1 + 1, -1);
        while (x < @min(x2, w)) : (x += 1) put(chart, grid, r2, x, "─", fg);
        put(chart, grid, r2, x2, "▶", fg);
    } else {
        put(chart, grid, r2, x1, if (down) "┘" else "┐", fg);
        var x = @min(x1 - 1, w);
        while (x > @max(x2, -1)) : (x -= 1) put(chart, grid, r2, x, "─", fg);
        put(chart, grid, r2, x2, "▶", fg);
    }
}

fn drawPanel(s: *AppState, f: ui.Frame, win: ui.Window) Allocator.Error!void {
    const t = &s.timeline;
    const snap = s.snap;
    win.fill(.{ .style = .{ .bg = palette.bar_bg } });
    const st: ui.Style = .{ .bg = palette.bar_bg };
    if (t.selected >= t.rows.len) return;
    const r = t.rows[t.selected];
    switch (r.kind) {
        .group => {
            const g = t.groups[r.group];
            const n = g.milestone orelse {
                _ = ui.text(
                    win,
                    1,
                    0,
                    f.fmt(
                        "Issues in no milestone: {d}, {d} without dates",
                        .{ g.issues, g.unscheduled },
                    ),
                    st,
                );
                return;
            };
            const m = snap.milestones[n];
            const due = milestoneDue(s, n);
            var x: u16 = 1;
            x += ui.text(
                win,
                x,
                0,
                m.name,
                .{ .fg = palette.accent, .bg = palette.bar_bg, .bold = true },
            );
            if (due) |d| x += ui.text(
                win,
                x,
                0,
                f.fmt(" · due {f}", .{d}),
                st,
            ) else x += ui.text(win, x, 0, " · no due date", st);
            if (g.span) |sp| x += ui.text(
                win,
                x,
                0,
                f.fmt(" · work from {f} to {f}", .{ sp.start, sp.end }),
                st,
            );
            if (g.span != null and due != null and g.span.?.end.order(due.?) == .gt) {
                _ = ui.text(
                    win,
                    x,
                    0,
                    " · ⚠ work ends after the due date",
                    .{ .fg = palette.medium, .bg = palette.bar_bg },
                );
            }
            _ = ui.text(
                win,
                1,
                1,
                f.fmt(
                    "{d} issues, {d} without dates · ⏎ its issues · space fold",
                    .{ g.issues, g.unscheduled },
                ),
                .{ .fg = palette.muted, .bg = palette.bar_bg },
            );
        },
        .unscheduled => _ = ui.text(
            win,
            1,
            0,
            "Issues without a start or due date · space shows them",
            .{ .fg = palette.muted, .bg = palette.bar_bg },
        ),
        .issue, .unscheduled_issue => {
            const i = r.issue;
            const issue = snap.issues[i];
            var x: u16 = 1;
            x += ui.text(
                win,
                x,
                0,
                f.fmt("#{s} ", .{shortId(issue.id)}),
                .{ .fg = palette.id, .bg = palette.bar_bg },
            );
            x += ui.text(win, x, 0, issue.title, .{ .bg = palette.bar_bg, .bold = true });
            const d = datesOf(s, i);
            if (t.spans[i]) |sp| {
                x += ui.text(win, x, 0, f.fmt(" · {f} → {f}", .{ sp.start, sp.end }), st);
                if (sp.derived_start or sp.derived_end) x += ui.text(
                    win,
                    x,
                    0,
                    if (d.start == null and
                        d.due == null) " (its work)" else " (from the estimate)",
                    .{ .fg = palette.muted, .bg = palette.bar_bg, .italic = true },
                );
            } else x += ui.text(
                win,
                x,
                0,
                " · no dates",
                .{ .fg = palette.muted, .bg = palette.bar_bg },
            );
            if (d.estimate_minutes) |m| x += ui.text(
                win,
                x,
                0,
                f.fmt(" · est {s}", .{ui.duration(f, m)}),
                st,
            );
            if (snap.milestoneName(i)) |name| x += ui.text(
                win,
                x,
                0,
                f.fmt(" · {s}", .{name}),
                .{ .fg = palette.accent, .bg = palette.bar_bg },
            );
            // Line two: blockers and warnings.
            var x2: u16 = 1;
            const proj = t.projection(snap);
            if (t.editing and isStale(t, issue.id)) {
                x2 += ui.text(
                    win,
                    x2,
                    1,
                    "! changed elsewhere since you edited it: r keeps your change, X drops it",
                    .{ .fg = palette.err, .bg = palette.bar_bg, .bold = true },
                );
                x2 += 2;
            }
            if (proj.blockers[i].len > 0) {
                x2 += ui.text(
                    win,
                    x2,
                    1,
                    "blocked by",
                    .{ .fg = palette.muted, .bg = palette.bar_bg },
                );
                for (proj.blockers[i]) |b| x2 += ui.text(
                    win,
                    x2,
                    1,
                    f.fmt(" #{s}", .{shortId(snap.issues[b].id)}),
                    .{
                        .fg = if (proj.isActive(b)) palette.err else palette.done,
                        .bg = palette.bar_bg,
                    },
                );
                x2 += 2;
            }
            if (proj.blocks[i].len > 0) {
                x2 += ui.text(win, x2, 1, "blocks", .{ .fg = palette.muted, .bg = palette.bar_bg });
                for (proj.blocks[i]) |b| x2 += ui.text(
                    win,
                    x2,
                    1,
                    f.fmt(" #{s}", .{shortId(snap.issues[b].id)}),
                    .{ .fg = palette.medium, .bg = palette.bar_bg },
                );
                x2 += 2;
            }
            var wbuf: [4]schedule.Warning = undefined;
            for (warningsOf(s, i, &wbuf)) |w| {
                const text = switch (w) {
                    .before_blocker => |b| f.fmt(
                        "⚠ starts before #{s} is done",
                        .{shortId(snap.issues[b].id)},
                    ),
                    else => f.fmt("⚠ {s}", .{w.describe()}),
                };
                x2 += ui.text(win, x2, 1, text, .{ .fg = palette.medium, .bg = palette.bar_bg });
                x2 += 2;
            }
        },
    }
}

// Input.

/// After edit mode's own keys, which `State` gives it first.
pub fn key(s: *AppState, k: vaxis.Key) Allocator.Error!AppState.Action {
    const t = &s.timeline;
    const snap = s.snap;
    if (!t.editing and k.matches('E', .{})) {
        edit.enter(s);
        return .none;
    }
    const sel: i64 = t.selected;
    const page: i64 = @max(t.visible, 2) - 1;
    if (k.matches(K.down, .{}) or k.matches('j', .{})) {
        t.moveTo(snap, sel + 1);
    } else if (k.matches(K.up, .{}) or k.matches('k', .{})) {
        t.moveTo(snap, sel - 1);
    } else if (k.matches(K.page_down, .{}) or k.matches('d', .{ .ctrl = true })) {
        t.moveTo(snap, sel + page);
    } else if (k.matches(K.page_up, .{}) or k.matches('u', .{ .ctrl = true })) {
        t.moveTo(snap, sel - page);
    } else if (k.matches(K.home, .{}) or k.matches('g', .{})) {
        t.moveTo(snap, 0);
    } else if (k.matches(K.end, .{}) or k.matches('G', .{})) {
        t.moveTo(snap, @as(i64, @intCast(t.rows.len)) - 1);
    } else if (k.matches(K.left, .{}) or k.matches('h', .{}) or k.matches('(', .{})) {
        t.scrollDays(-t.zoom.unit());
    } else if (k.matches(K.right, .{}) or k.matches('l', .{}) or k.matches(')', .{})) {
        t.scrollDays(t.zoom.unit());
    } else if (k.matches(K.left, .{ .shift = true }) or k.matches('H', .{})) {
        t.scrollDays(-@as(i32, @max(t.visibleDays() - t.zoom.unit(), 1)));
    } else if (k.matches(K.right, .{ .shift = true }) or k.matches('L', .{})) {
        t.scrollDays(@max(t.visibleDays() - t.zoom.unit(), 1));
    } else if (k.matches('.', .{})) {
        t.center_on = s.today.toDays();
    } else if (k.matches('z', .{})) {
        zoom(s, -1);
    } else if (k.matches('Z', .{})) {
        zoom(s, 1);
    } else if (k.matches('D', .{})) {
        t.deps = switch (t.deps) {
            .selected => .all,
            .all => .off,
            .off => .selected,
        };
        s.info("blocker lines: {s}", .{t.deps.label()});
    } else if (k.matches('v', .{})) {
        t.grouping = if (t.grouping == .milestone) .none else .milestone;
        t.follow = true;
    } else if (k.matches(']', .{})) {
        jumpGroup(s, 1);
    } else if (k.matches('[', .{})) {
        jumpGroup(s, -1);
    } else if (k.matches(K.space, .{})) {
        try fold(s);
    } else if (k.matches(K.enter, .{})) {
        // In edit mode only the "without dates" row's: it folds.
        const on_unscheduled = t.selected < t.rows.len and
            t.rows[t.selected].kind == .unscheduled;
        if (t.editing and !on_unscheduled) return .none;
        return activate(s);
    } else if (t.editing) {
        // Writes at once: refused in edit mode before this.
    } else if (k.matches('x', .{})) {
        if (t.selectedIssue()) |i| return s.toggleAction(i);
    } else if (k.matches('a', .{})) {
        if (t.selectedIssue()) |i| s.newIssue(i);
    }
    return .none;
}

/// In (-1) or out (+1), keeping the selected bar, or today, in place.
pub fn zoom(s: *AppState, by: i32) void {
    const t = &s.timeline;
    const z: i32 = @intFromEnum(t.zoom);
    const next = std.math.clamp(z + by, 0, 2);
    if (next == z) return;
    const keep = t.anchor(s.today);
    const at = t.x(keep);
    t.zoom = @enumFromInt(next);
    // The same day under the same column, if it was on screen.
    const col = if (at >= 0 and at < t.chart_width) at else @divFloor(@as(i32, t.chart_width), 2);
    t.origin = keep - @divFloor(col * t.zoom.den(), t.zoom.num());
}

fn jumpGroup(s: *AppState, by: i32) void {
    const t = &s.timeline;
    if (t.rows.len == 0) return;
    var n: i64 = t.selected;
    while (true) {
        n += by;
        if (n < 0 or n >= t.rows.len) return;
        if (t.rows[@intCast(n)].kind == .group) break;
    }
    t.moveTo(s.snap, n);
    const g = t.groups[t.rows[@intCast(n)].group];
    if (g.span) |sp| t.center_on = sp.start.toDays();
}

fn fold(s: *AppState) Allocator.Error!void {
    const t = &s.timeline;
    if (t.selected >= t.rows.len) return;
    const r = t.rows[t.selected];
    const scope = t.groups[r.group].scope;
    switch (r.kind) {
        .group => try State.toggle(&t.folded, s.gpa, scope),
        .unscheduled, .unscheduled_issue => {
            try State.toggle(&t.unfolded_unscheduled, s.gpa, scope);
            t.selected_key = .{ .unscheduled = scope };
        },
        .issue => {},
    }
}

fn activate(s: *AppState) AppState.Action {
    const t = &s.timeline;
    if (t.selected >= t.rows.len) return .none;
    const r = t.rows[t.selected];
    switch (r.kind) {
        .group => s.openMilestone(t.groups[r.group].scope),
        .unscheduled => fold(s) catch {},
        .issue, .unscheduled_issue => {
            // Its bar to the middle, then the issue itself.
            s.openIssue(s.snap.issues[r.issue].id);
        },
    }
    return .none;
}

pub fn click(s: *AppState, row: u32, x: u16, double: bool) Allocator.Error!AppState.Action {
    const t = &s.timeline;
    if (row >= t.rows.len) return .none;
    t.moveTo(s.snap, row);
    if (t.editing) {
        if (t.linking != null) return edit.pickBlocker(s);
        edit.press(s, row, x);
        return .none;
    }
    if (double) {
        const r = t.rows[row];
        if (r.kind == .group or r.kind == .unscheduled) {
            try fold(s);
            return .none;
        }
        return activate(s);
    }
    return .none;
}

/// A click in the header centers its day.
pub fn clickHeader(s: *AppState, x: u16) void {
    const t = &s.timeline;
    t.center_on = t.dayAt(x);
}

pub fn wheel(s: *AppState, m: vaxis.Mouse, delta: i32) void {
    const t = &s.timeline;
    switch (m.button) {
        .wheel_left => t.scrollDays(-t.zoom.unit()),
        .wheel_right => t.scrollDays(t.zoom.unit()),
        else => if (m.mods.shift) t.scrollDays(
            std.math.sign(delta) * t.zoom.unit(),
        ) else t.scrollBy(delta),
    }
}

pub fn command(s: *AppState, c: ui.TimelineCommand) void {
    const t = &s.timeline;
    switch (c) {
        .earlier => t.scrollDays(-@as(i32, @max(t.visibleDays() - t.zoom.unit(), 1))),
        .later => t.scrollDays(@max(t.visibleDays() - t.zoom.unit(), 1)),
        .today => t.center_on = s.today.toDays(),
        .deps => t.deps = switch (t.deps) {
            .selected => .all,
            .all => .off,
            .off => .selected,
        },
        .grouping => t.grouping = if (t.grouping == .milestone) .none else .milestone,
        .edit => edit.enter(s),
        .apply => edit.confirmApply(s),
        .discard => edit.confirmDiscard(s, null),
        .undo => edit.undo(s),
        .redo => edit.redo(s),
    }
}

pub const edit = @import("timeline_edit.zig");

pub fn setZoom(s: *AppState, z: Zoom) void {
    const want: i32 = @intFromEnum(z);
    const have: i32 = @intFromEnum(s.timeline.zoom);
    if (want != have) zoom(s, want - have);
}

test "zoom keeps the anchor day under its column" {
    var t: State = .{ .chart_width = 80, .origin = 1000 };
    try std.testing.expectEqual(@as(i32, 10), t.x(1010));
    t.zoom = .day;
    try std.testing.expectEqual(@as(i32, 30), t.x(1010));
    try std.testing.expectEqual(@as(i32, 1010), t.dayAt(30));
    t.zoom = .month;
    try std.testing.expectEqual(@as(i32, 2), t.x(1010));
}

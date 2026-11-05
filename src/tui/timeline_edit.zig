//! The timeline's edit mode: keys and drags stage changes in the draft,
//! nothing is written until they are applied, and the view can't be left
//! with changes that are neither applied nor discarded.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const issuez = @import("issuez");

const ui = @import("ui.zig");
const store = @import("store.zig");
const filter = @import("filter.zig");
const dates = issuez.format.dates;
const draft_mod = @import("timeline_draft.zig");
const modal_mod = @import("modal.zig");
const view = @import("timeline_view.zig");
const AppState = @import("State.zig");

const Id = store.Id;
const Date = issuez.format.fields.Date;
const schedule = issuez.schedule;
const Op = draft_mod.Op;
const K = vaxis.Key;
const shortId = issuez.format.uuid.shortId;
const none = std.math.maxInt(u32);

/// Where the user was going when the draft stopped them.
pub const Leave = union(enum) {
    view: ui.View,
    quit,
    issue: Id,
    milestone: filter.MilestoneScope,
};

pub fn enter(s: *AppState) void {
    const t = &s.timeline;
    if (t.editing) return leaveEditing(s);
    reset(t);
    t.editing = true;
    s.info("edit mode: changes are staged; ctrl+s applies them, esc discards", .{});
}

/// Out of edit mode, asking first with changes.
fn leaveEditing(s: *AppState) void {
    const t = &s.timeline;
    if (t.changes() > 0) return confirmDiscard(s, null);
    reset(t);
    s.info("edit mode off", .{});
}

/// Out of edit mode as it is: the draft, the blocker being picked and
/// what the mouse holds are gone.
pub fn reset(t: *view.State) void {
    t.editing = false;
    t.draft.clear();
    t.linking = null;
    t.bar_drag = null;
    t.preview = null;
    t.row_drag = null;
}

/// Whether the view may be left for `then` now. With changes, the user
/// is asked: apply, discard or keep editing.
pub fn mayLeave(s: *AppState, then: Leave) bool {
    const t = &s.timeline;
    if (s.view != .timeline or !t.editing) return true;
    if (t.changes() == 0) {
        reset(t);
        return true;
    }
    const n = t.changes();
    modal_mod.openConfirm(s, "Timeline changes", &.{
        s.fmtInput("{d} {s} not applied yet.", .{ n, if (n == 1) "change is" else "changes are" }),
        "Apply them, or discard them, before leaving.",
    }, &.{
        .{ .label = "Keep editing", .action = .none },
        .{ .label = "Apply", .action = .{ .leave_timeline = .{ .apply = true, .then = then } } },
        .{ .label = "Discard", .action = .{ .leave_timeline = .{ .apply = false, .then = then } } },
    });
    return false;
}

pub fn confirmDiscard(s: *AppState, then: ?Leave) void {
    const t = &s.timeline;
    const n = t.changes();
    if (n == 0) {
        reset(t);
        return;
    }
    modal_mod.openConfirm(s, "Discard timeline changes?", &.{
        s.fmtInput("{d} {s} will be lost; nothing was written.", .{ n, if (n == 1) "change" else "changes" }),
    }, &.{
        .{ .label = "Keep editing", .action = .none },
        .{ .label = "Discard", .action = .{ .leave_timeline = .{ .apply = false, .then = then orelse .{ .view = .timeline } } } },
    });
}

/// What applying writes, then the question.
pub fn confirmApply(s: *AppState) void {
    const t = &s.timeline;
    const snap = s.snap;
    const a = s.input_arena.allocator();
    const plan = t.draft.plan(a, snap) catch return s.fail("out of memory", .{});
    if (plan.count() == 0) return s.info("nothing to apply", .{});
    if (plan.stale.len > 0) {
        selectId(s, plan.stale[0].slice());
        return s.fail("{d} changed elsewhere since you edited {s}: r keeps your change, X drops it", .{ plan.stale.len, if (plan.stale.len == 1) "it" else "them" });
    }
    if (plan.inverted.len > 0) {
        selectId(s, plan.inverted[0].slice());
        return s.fail("#{s} would start after its due date: move one of them", .{shortId(plan.inverted[0].slice())});
    }
    var lines: std.ArrayList([]const u8) = .empty;
    const max_lines = 10;
    for (plan.issues, 0..) |c, n| {
        if (n == max_lines) break;
        const i = snap.find(c.id.slice()) orelse continue;
        lines.append(a, describe(s, a, i, c) catch "") catch {};
    }
    for (plan.milestones) |c| {
        if (lines.items.len >= max_lines) break;
        const n = snap.findMilestone(c.id.slice()) orelse continue;
        const m = snap.milestones[n];
        lines.append(a, std.fmt.allocPrint(a, "{s}  due {s} → {s}", .{ m.name, dateText(a, m.due), dateText(a, c.due) }) catch "") catch {};
    }
    if (plan.count() > max_lines) lines.append(a, std.fmt.allocPrint(a, "… and {d} more", .{plan.count() - max_lines}) catch "") catch {};
    lines.append(a, "All of it is written at once, or none of it.") catch {};
    modal_mod.openConfirm(s, s.fmtInput("Apply {d} {s}?", .{ plan.count(), if (plan.count() == 1) "change" else "changes" }), lines.items, &.{
        .{ .label = "Apply", .action = .apply_draft },
        .{ .label = "Back", .action = .none },
    });
}

fn dateText(a: Allocator, d: ?Date) []const u8 {
    const v = d orelse return "none";
    return std.fmt.allocPrint(a, "{f}", .{v}) catch "";
}

fn describe(s: *AppState, a: Allocator, i: u32, c: draft_mod.IssueChange) Allocator.Error![]const u8 {
    const snap = s.snap;
    const issue = snap.issues[i];
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "#{s}", .{shortId(issue.id)});
    if (c.start) |v| try out.print(a, " start {s} → {s}", .{ dateText(a, issue.ext.start_date), dateText(a, v) });
    if (c.due) |v| try out.print(a, " due {s} → {s}", .{ dateText(a, issue.ext.due_date), dateText(a, v) });
    if (c.estimate) |v| {
        if (v) |m| try out.print(a, " estimate {s}", .{fmtMinutes(a, m)}) else try out.appendSlice(a, " no estimate");
    }
    if (c.link) |l| switch (l) {
        .id => |id| try out.print(a, " → {s}", .{if (snap.findMilestone(id.slice())) |n| snap.milestones[n].name else "?"}),
        .none => try out.appendSlice(a, " → no milestone"),
        .inherit => try out.appendSlice(a, " → its parent's milestone"),
    };
    for (c.add) |*b| try out.print(a, " +blocked by #{s}", .{shortId(b.slice())});
    for (c.remove) |*b| try out.print(a, " −blocked by #{s}", .{shortId(b.slice())});
    return out.items;
}

fn fmtMinutes(a: Allocator, m: u32) []const u8 {
    const h = m / 60;
    const r = m % 60;
    if (h == 0) return std.fmt.allocPrint(a, "{d}m", .{r}) catch "";
    if (r == 0) return std.fmt.allocPrint(a, "{d}h", .{h}) catch "";
    return std.fmt.allocPrint(a, "{d}h{d}m", .{ h, r }) catch "";
}

fn selectId(s: *AppState, id: []const u8) void {
    const t = &s.timeline;
    if (s.snap.find(id) != null) {
        t.selected_key = .{ .issue = .{ .id = .of(id) } };
        t.follow = true;
    }
}

pub fn undo(s: *AppState) void {
    if (s.timeline.draft.undo()) s.info("undone", .{}) else s.info("nothing to undo", .{});
}

pub fn redo(s: *AppState) void {
    if (s.timeline.draft.redo()) s.info("redone", .{}) else s.info("nothing to redo", .{});
}

/// Into the draft, expecting the tip shown now when first touched. False,
/// with the failure shown, when it couldn't be.
pub fn stage(s: *AppState, op: Op) bool {
    const snap = s.snap;
    const id = op.target().slice();
    const tip = if (snap.find(id)) |i| snap.issues[i].tip else if (snap.findMilestone(id)) |n| snap.milestones[n].tip else null;
    s.timeline.draft.push(s.gpa, op, tip) catch {
        s.fail("out of memory", .{});
        return false;
    };
    return true;
}

// Moving bars.

const Which = enum { both, start, due };

/// Moves the selected issue's dates, or the selected milestone's due
/// date, by `n` working days.
fn shift(s: *AppState, which: Which, n: i32) void {
    const t = &s.timeline;
    const snap = s.snap;
    const cal = view.calendar(s);
    if (t.selected >= t.rows.len) return;
    const r = t.rows[t.selected];
    if (r.kind == .group) {
        const g = t.groups[r.group];
        const m = g.milestone orelse return;
        if (which == .start) return s.info("a milestone has no start of its own: move its issues", .{});
        const due = view.milestoneDue(s, m) orelse s.today;
        _ = stage(s, .{ .milestone_due = .{ .id = .of(snap.milestones[m].id), .due = cal.work_days.add(due, n) } });
        return;
    }
    const i = t.selectedIssue() orelse return;
    const d = view.datesOf(s, i);
    const sp = schedule.span(d, cal) orelse return s.info("no dates yet: ⏎ schedules it from today, s and d type them", .{});
    // Only the dates it moves: the others stay what they are when applied.
    var op: @FieldType(Op, "dates") = .{ .id = .of(snap.issues[i].id) };
    switch (which) {
        .both => {
            if (d.start) |v| op.start = cal.work_days.add(v, n);
            if (d.due) |v| op.due = cal.work_days.add(v, n);
        },
        .start => op.start = cal.work_days.add(d.start orelse sp.start, n),
        .due => op.due = cal.work_days.add(d.due orelse sp.end, n),
    }
    const start = if (op.start) |v| v else d.start;
    const due = if (op.due) |v| v else d.due;
    // A bar already the wrong way round may still move.
    if (inverted(start, due) and !inverted(d.start, d.due)) {
        return s.fail("the start can't be after the due date", .{});
    }
    _ = stage(s, .{ .dates = op });
}

fn inverted(start: ?Date, due: ?Date) bool {
    return start != null and due != null and start.?.order(due.?) == .gt;
}

/// An issue without dates onto the timeline: from today, as long as its
/// estimate says.
fn schedule_(s: *AppState, i: u32) void {
    const cal = view.calendar(s);
    const d = view.datesOf(s, i);
    var start = s.today;
    if (!cal.work_days.isWorkDay(start)) start = cal.work_days.add(start, 1);
    const days: i32 = @intCast(if (d.estimate_minutes) |m| @min(cal.days(m), 1000) else 1);
    if (!stage(s, .{ .dates = .{ .id = .of(s.snap.issues[i].id), .start = start, .due = cal.work_days.add(start, days - 1) } })) return;
    s.info("scheduled from today", .{});
}

pub fn key(s: *AppState, k: vaxis.Key) Allocator.Error!?AppState.Action {
    const t = &s.timeline;
    const snap = s.snap;
    // With no working days set, every day is one.
    const bits = s.snap.settings.work_days.bits;
    const week: i32 = if (bits == 0) 7 else @popCount(bits);
    // Writes that can't wait for apply.
    if (k.matches('x', .{})) {
        s.info("closing writes at once: apply or leave edit mode first (esc)", .{});
        return .none;
    }
    if (k.matches('n', .{}) or k.matches('a', .{})) {
        s.info("creating writes at once: apply or leave edit mode first (esc)", .{});
        return .none;
    }
    if (t.linking != null) {
        if (k.matches(K.escape, .{})) {
            t.linking = null;
            s.info("not linked", .{});
            return .none;
        }
        if (k.matches(K.enter, .{}) or k.matches('b', .{})) return pickBlocker(s);
        return null;
    }
    if (k.matches(K.escape, .{}) or k.matches('E', .{})) {
        leaveEditing(s);
        return .none;
    }
    if (k.matches('s', .{ .ctrl = true })) {
        confirmApply(s);
        return .none;
    }
    if (k.matches('u', .{})) {
        undo(s);
        return .none;
    }
    // ctrl+r reloads, as everywhere.
    if (k.matches('U', .{})) {
        redo(s);
        return .none;
    }
    if (k.matches(K.left, .{ .ctrl = true })) {
        t.scrollDays(-t.zoomUnit());
        return .none;
    }
    if (k.matches(K.right, .{ .ctrl = true })) {
        t.scrollDays(t.zoomUnit());
        return .none;
    }
    const moves = [_]struct { u21, vaxis.Key.Modifiers, Which, i32 }{
        .{ K.left, .{}, .both, -1 },                   .{ K.right, .{}, .both, 1 },
        .{ 'h', .{}, .both, -1 },                      .{ 'l', .{}, .both, 1 },
        .{ K.left, .{ .shift = true }, .both, -week }, .{ K.right, .{ .shift = true }, .both, week },
        .{ 'H', .{}, .both, -week },                   .{ 'L', .{}, .both, week },
        .{ '<', .{}, .due, -1 },                       .{ '>', .{}, .due, 1 },
        .{ '{', .{}, .start, -1 },                     .{ '}', .{}, .start, 1 },
        .{ K.left, .{ .alt = true }, .start, -1 },     .{ K.right, .{ .alt = true }, .start, 1 },
        // What many terminals send for alt+← →.
        .{ 'b', .{ .alt = true }, .start, -1 },        .{ 'f', .{ .alt = true }, .start, 1 },
    };
    for (moves) |m| if (k.matches(m[0], m[1])) {
        shift(s, m[2], m[3]);
        return .none;
    };
    const i = t.selectedIssue();
    const row = if (t.selected < t.rows.len) t.rows[t.selected] else null;
    if (k.matches(K.enter, .{})) {
        if (row) |r| switch (r.kind) {
            .unscheduled_issue => schedule_(s, r.issue),
            .group => if (t.groups[r.group].milestone) |n| promptMilestoneDue(s, n),
            .unscheduled => return null,
            .issue => {},
        };
        return .none;
    }
    if (k.matches('d', .{})) {
        if (i) |x| promptDate(s, x, .due) else if (row) |r| if (r.kind == .group) if (t.groups[r.group].milestone) |n| promptMilestoneDue(s, n);
        return .none;
    }
    if (k.matches('s', .{})) {
        if (i) |x| promptDate(s, x, .start);
        return .none;
    }
    if (k.matches('e', .{})) {
        if (i) |x| promptEstimate(s, x);
        return .none;
    }
    if (k.matches('m', .{})) {
        if (i) |x| milestoneMenu(s, x);
        return .none;
    }
    if (k.matches('b', .{})) {
        const x = i orelse return .none;
        t.linking = .of(snap.issues[x].id);
        s.info("#{s} waits for…: select its blocker, ⏎ links, esc cancels", .{shortId(snap.issues[x].id)});
        return .none;
    }
    if (k.matches('B', .{})) {
        if (i) |x| unblockMenu(s, x);
        return .none;
    }
    if (k.matches('r', .{})) {
        if (i) |x| {
            const id = snap.issues[x].id;
            t.draft.rebase(snap, id);
            s.info("#{s}: your change now applies over what changed elsewhere", .{shortId(id)});
        }
        return .none;
    }
    if (k.matches('X', .{})) {
        if (i) |x| {
            t.draft.drop(snap.issues[x].id);
            s.info("#{s}: your changes dropped", .{shortId(snap.issues[x].id)});
        }
        return .none;
    }
    return null;
}

/// The selected issue as the blocker of the one being linked.
pub fn pickBlocker(s: *AppState) AppState.Action {
    const t = &s.timeline;
    const snap = s.snap;
    const id = t.linking orelse return .none;
    const b = t.selectedIssue() orelse {
        s.info("select an issue to wait for", .{});
        return .none;
    };
    const i = snap.find(id.slice()) orelse {
        t.linking = null;
        return .none;
    };
    if (b == i) {
        s.fail("an issue can't wait for itself", .{});
        return .none;
    }
    const proj = t.projection(snap);
    for (proj.blockers[i]) |x| if (x == b) {
        t.linking = null;
        s.info("already blocked by it", .{});
        return .none;
    };
    // Waiting for something that waits for it would be a loop.
    if (reaches(s, proj, b, i)) {
        s.fail("#{s} already waits for #{s}: that would be a loop", .{ shortId(snap.issues[b].id), shortId(id.slice()) });
        return .none;
    }
    t.linking = null;
    if (!stage(s, .{ .add_blocker = .{ .id = id, .blocker = .of(snap.issues[b].id) } })) return .none;
    s.info("#{s} now waits for #{s}", .{ shortId(id.slice()), shortId(snap.issues[b].id) });
    return .none;
}

/// Whether `from` waits for `to`, directly or not.
fn reaches(s: *AppState, proj: *const issuez.projection.Projection, from: u32, to: u32) bool {
    const a = s.input_arena.allocator();
    var seen = a.alloc(bool, proj.issues.len) catch return false;
    @memset(seen, false);
    var stack: std.ArrayList(u32) = .empty;
    stack.append(a, from) catch return false;
    while (stack.pop()) |x| {
        if (x == to) return true;
        if (seen[x]) continue;
        seen[x] = true;
        stack.appendSlice(a, proj.blockers[x]) catch return false;
    }
    return false;
}

// Dialogs that stage.

fn promptDate(s: *AppState, i: u32, which: enum { start, due }) void {
    const issue = s.snap.issues[i];
    const d = view.datesOf(s, i);
    const v = if (which == .start) d.start else d.due;
    const value = if (v) |x| s.fmtInput("{f}", .{x}) else "";
    const title = s.fmtInput("{s} of #{s} (staged)", .{ if (which == .start) "Start" else "Due", shortId(issue.id) });
    modal_mod.openPrompt(s, title, dates.hint, value, .{ .stage_date = .{ .id = .of(issue.id), .start = which == .start } }, true);
    s.modal.?.prompt.date = true;
}

fn promptMilestoneDue(s: *AppState, n: u32) void {
    const m = s.snap.milestones[n];
    const v = view.milestoneDue(s, n);
    const value = if (v) |x| s.fmtInput("{f}", .{x}) else "";
    modal_mod.openPrompt(s, s.fmtInput("Due date of {s} (staged)", .{m.name}), dates.hint, value, .{ .stage_ms_due = .of(m.id) }, true);
    s.modal.?.prompt.date = true;
}

fn promptEstimate(s: *AppState, i: u32) void {
    const issue = s.snap.issues[i];
    const d = view.datesOf(s, i);
    const value = if (d.estimate_minutes) |m| fmtMinutes(s.input_arena.allocator(), m) else "";
    modal_mod.openPrompt(s, s.fmtInput("Estimate of #{s} (staged)", .{shortId(issue.id)}), "like 90m, 2h or 1h30m; empty clears", value, .{ .stage_estimate = .of(issue.id) }, true);
}

fn milestoneMenu(s: *AppState, i: u32) void {
    const snap = s.snap;
    s.closeModal();
    const a = s.modalArena();
    var options: std.ArrayList(modal_mod.Menu.Option) = .empty;
    for (snap.milestones) |m| {
        if (m.status == .retired) continue;
        options.append(a, .{
            .label = std.fmt.allocPrint(a, "{s}{s}", .{ m.name, if (m.status == .completed) "  (completed)" else "" }) catch "",
            .value = a.dupe(u8, m.id) catch "",
            .disabled = m.status == .completed,
        }) catch {};
    }
    options.append(a, .{ .label = "(no milestone)", .value = modal_mod.link_none }) catch {};
    if (snap.proj.parent[i] != none) options.append(a, .{ .label = "(inherit from parent)", .value = modal_mod.link_inherit }) catch {};
    const title = std.fmt.allocPrint(a, "Milestone of #{s} (staged)", .{shortId(snap.issues[i].id)}) catch "";
    s.openModal(.{ .menu = .{ .title = title, .options = options.items, .purpose = .{ .stage_milestone = .of(snap.issues[i].id) } } });
}

fn unblockMenu(s: *AppState, i: u32) void {
    const snap = s.snap;
    const proj = s.timeline.projection(snap);
    if (proj.blockers[i].len == 0) return s.info("it waits for nothing", .{});
    s.closeModal();
    const a = s.modalArena();
    var options: std.ArrayList(modal_mod.Menu.Option) = .empty;
    for (proj.blockers[i]) |b| {
        options.append(a, .{
            .label = std.fmt.allocPrint(a, "#{s} {s}", .{ shortId(snap.issues[b].id), snap.issues[b].title }) catch "",
            .value = a.dupe(u8, snap.issues[b].id) catch "",
        }) catch {};
    }
    const title = std.fmt.allocPrint(a, "#{s} stops waiting for (staged)", .{shortId(snap.issues[i].id)}) catch "";
    s.openModal(.{ .menu = .{ .title = title, .options = options.items, .purpose = .{ .stage_unblock = .of(snap.issues[i].id) } } });
}

// Dragging.

/// A press on a bar starts a drag: its body moves it, its ends move one
/// date. On a milestone row, its due date.
pub fn press(s: *AppState, row: u32, x: u16) void {
    const t = &s.timeline;
    const snap = s.snap;
    t.bar_drag = null;
    t.preview = null;
    t.row_drag = null;
    // By its title: to another milestone.
    if (x < t.chart_x) {
        const r = t.rows[row];
        if (t.grouping == .milestone and (r.kind == .issue or r.kind == .unscheduled_issue) and !r.context) {
            t.row_drag = .{ .issue = .of(snap.issues[r.issue].id), .from = t.groups[r.group].scope };
        }
        return;
    }
    const col: i32 = x - t.chart_x;
    const r = t.rows[row];
    const day = t.dayAt(col);
    switch (r.kind) {
        .group => {
            const n = t.groups[r.group].milestone orelse return;
            const due = view.milestoneDue(s, n) orelse return;
            if (@abs(t.x(due.toDays()) - col) > 1) return;
            t.bar_drag = .{ .target = .{ .milestone = .of(snap.milestones[n].id) }, .part = .end, .anchor = day, .start = null, .due = due, .written_start = null, .written_due = due };
        },
        .issue => {
            const i = r.issue;
            const d = view.datesOf(s, i);
            const sp = schedule.span(d, view.calendar(s)) orelse return;
            const from = t.x(sp.start.toDays());
            const to = @max(t.x(sp.end.toDays() + 1) - 1, from);
            if (col < from or col > to) return;
            // A bar the wrong way round is drawn from its due date.
            const flipped = inverted(d.start, d.due);
            const left: @FieldType(view.State.BarDrag, "part") = if (flipped) .end else .start;
            const right: @FieldType(view.State.BarDrag, "part") = if (flipped) .start else .end;
            const part: @FieldType(view.State.BarDrag, "part") = if (to > from and col == from) left else if (to > from and col == to) right else .body;
            t.bar_drag = .{
                .target = .{ .issue = .of(snap.issues[i].id) },
                .part = part,
                .anchor = day,
                // An end drags from where it is drawn.
                .start = d.start orelse sp.start,
                .due = d.due orelse sp.end,
                .written_start = d.start,
                .written_due = d.due,
            };
        },
        else => {},
    }
}

pub fn dragTo(s: *AppState, found: ?ui.Hits.Found) void {
    const t = &s.timeline;
    if (t.row_drag) |*rd| {
        const h = found orelse return;
        if (h.target == .tl_row and h.target.tl_row < t.rows.len) rd.over = t.groups[t.rows[h.target.tl_row].group].scope;
        return;
    }
    const d = &(t.bar_drag orelse return);
    const h = found orelse return;
    if (h.target != .tl_row or h.x < t.chart_x) return;
    const delta = t.dayAt(h.x - t.chart_x) - d.anchor;
    if (delta != 0) d.moved = true;
    if (!d.moved) return;
    d.delta = delta;
    switch (d.target) {
        .milestone => |id| t.preview = .{ .milestone_due = .{ .id = id, .due = d.due.?.addDays(delta) } },
        .issue => |id| {
            // What it has moves with the body; an end sets that date. A
            // bar already the wrong way round isn't held to the order.
            const keep_order = !inverted(d.start, d.due);
            var op: @FieldType(Op, "dates") = .{ .id = id };
            switch (d.part) {
                .body => {
                    if (d.written_start) |v| op.start = v.addDays(delta);
                    if (d.written_due) |v| op.due = v.addDays(delta);
                },
                .start => {
                    var start = d.start.?.addDays(delta);
                    if (keep_order and start.order(d.due.?) == .gt) start = d.due.?;
                    op.start = start;
                },
                .end => {
                    var due = d.due.?.addDays(delta);
                    if (keep_order and due.order(d.start.?) == .lt) due = d.start.?;
                    op.due = due;
                },
            }
            t.preview = .{ .dates = op };
        },
    }
}

pub fn release(s: *AppState) void {
    const t = &s.timeline;
    const snap = s.snap;
    const row_drag = t.row_drag;
    const bar_drag = t.bar_drag;
    const preview = t.preview;
    t.row_drag = null;
    t.bar_drag = null;
    t.preview = null;
    // Edit mode ended while it was held: nothing to stage into.
    if (!t.editing) return;
    if (row_drag) |rd| {
        const over = rd.over orelse return;
        if (over.eql(rd.from)) return;
        // Gone meanwhile.
        if (snap.find(rd.issue.slice()) == null) return;
        if (over == .id) if (snap.findMilestone(over.id.slice())) |n| if (snap.milestones[n].status != .open) {
            return s.fail("{s} is {s}: reopen it first to add work", .{ snap.milestones[n].name, @tagName(snap.milestones[n].status) });
        };
        if (!stage(s, .{ .milestone = .{ .id = rd.issue, .link = switch (over) {
            .none => .none,
            .id => |m| .{ .id = m },
        } } })) return;
        s.info("#{s} → {s} (staged)", .{ shortId(rd.issue.slice()), @import("milestone_view.zig").scopeName(snap, over) });
        return;
    }
    const d = bar_drag orelse return;
    const p = preview orelse return;
    if (!d.moved or d.delta == 0 or !changes(d, p)) return;
    const there = switch (d.target) {
        .issue => |id| snap.find(id.slice()) != null,
        .milestone => |id| snap.findMilestone(id.slice()) != null,
    };
    if (!there) return s.fail("it was deleted elsewhere meanwhile", .{});
    _ = stage(s, p);
}

/// Whether letting go of `d` with preview `p` changes a date.
fn changes(d: view.State.BarDrag, p: Op) bool {
    return switch (p) {
        .dates => |x| (x.start != null and !dateEql(x.start.?, d.written_start)) or
            (x.due != null and !dateEql(x.due.?, d.written_due)),
        .milestone_due => |x| !dateEql(x.due, d.written_due),
        else => true,
    };
}

fn dateEql(a: ?Date, b: ?Date) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

//! Dialogs over the views: a one-line prompt, a multi-line editor, a menu
//! of choices, the create form and the help. A dialog stays open when its
//! write fails, so nothing typed is lost.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const issuez = @import("issuez");

const ui = @import("ui.zig");
const store = @import("store.zig");
const filter = @import("filter.zig");
const text_mod = @import("text.zig");
const dates = issuez.format.dates;
const milestone_filter = @import("milestone_filter.zig");
const draft_mod = @import("timeline_draft.zig");
const star = @import("star.zig");
const AppState = @import("State.zig");

const Id = store.Id;
const TextArea = text_mod.TextArea;
const Action = AppState.Action;
const K = vaxis.Key;
const palette = ui.palette;
const fields_fmt = issuez.format.fields;
const Date = fields_fmt.Date;
const core = issuez.format.core;
const shortId = issuez.format.uuid.shortId;

pub const Field = enum {
    state,
    workflow,
    priority,
    assignee,
    labels,
    milestone,
    parent,
    blocked_by,
    start,
    due,
    estimate,

    pub fn label(f: Field) []const u8 {
        return switch (f) {
            .state => "State",
            .workflow => "Workflow",
            .priority => "Priority",
            .assignee => "Assignee",
            .labels => "Labels",
            .milestone => "Milestone",
            .parent => "Parent",
            .blocked_by => "Blocked by",
            .start => "Start",
            .due => "Due",
            .estimate => "Estimate",
        };
    }
};

/// What a dialog's answer is for.
pub const Purpose = union(enum) {
    title: Id,
    field: struct { id: Id, field: Field },
    description: Id,
    comment: Id,
    /// The list and board order, not a write.
    sort,
    /// A milestone to filter by, not a write.
    milestones,
    /// The milestones view's order.
    milestone_sort,
    /// A milestone's name or due date, at the tip the dialog showed.
    milestone: MilestonePart,
    /// Where these issues go, by milestone.
    move: []const Id,
    /// What the milestone view's second pane shows.
    pane_pick,
    /// Titles for new issues in a milestone, one after another.
    quick_add: filter.MilestoneScope,
    /// Existing issues into this milestone, or out of every one.
    add_to: filter.MilestoneScope,
    /// Existing issues as sub-issues of this one.
    adopt: Id,
    // Into the timeline's draft, not written.
    stage_date: struct { id: Id, start: bool },
    stage_estimate: Id,
    stage_ms_due: Id,
    stage_milestone: Id,
    stage_unblock: Id,

    pub const MilestonePart = struct { id: Id, tip: issuez.engine.Oid, what: enum { name, due } };

    /// The issue whose fields the answer replaces, so its write expects
    /// the tip the dialog showed. A comment replaces nothing.
    pub fn issue(p: Purpose) ?Id {
        return switch (p) {
            .title, .description => |id| id,
            .field => |fp| fp.id,
            .comment, .sort, .milestones, .milestone_sort, .milestone => null,
            .move, .pane_pick, .quick_add, .add_to, .adopt => null,
            .stage_date, .stage_estimate, .stage_ms_due, .stage_milestone, .stage_unblock => null,
        };
    }
};

pub const Prompt = struct {
    title: []const u8,
    hint: []const u8,
    input: TextArea = .init(false),
    /// Takes a date (`dates.parse`): shows which one as it is typed.
    date: bool = false,
    /// The value it started with: saving that again writes nothing. Null
    /// when any answer is a change.
    original: ?[]const u8 = null,
    /// The text it opened with: closing with that loses nothing.
    opened: []const u8 = "",
    purpose: Purpose,
};

pub const Editor = struct {
    title: []const u8,
    input: TextArea = .init(true),
    /// What it started with, to tell whether there is anything to lose.
    original: []const u8,
    purpose: Purpose,
};

pub const Menu = struct {
    title: []const u8,
    options: []Option,
    selected: u16 = 0,
    scroll: u16 = 0,
    purpose: Purpose,

    pub const Option = struct {
        label: []const u8,
        /// What choosing it writes. `other` asks for text instead.
        value: []const u8,
        other: bool = false,
        current: bool = false,
        /// Shown, but choosing it only says why not.
        disabled: bool = false,
    };
};

/// A question with a few answers, each an action; the first is what ⏎
/// picks, Esc cancels.
pub const Confirm = struct {
    title: []const u8,
    lines: []const []const u8,
    choices: []Choice,
    selected: u16 = 0,
    /// The letter whose key opened it: pressed again, or held, it picks
    /// nothing, so a doubled key doesn't answer unread.
    opener: ?u21 = null,

    pub const Choice = struct {
        label: []const u8,
        /// `.none` just closes the dialog. Strings in the modal arena.
        action: Action,
    };
};

/// A list to search as you type: one item, or several marked with Tab.
pub const Picker = struct {
    title: []const u8,
    items: []Item,
    filter: TextArea = .init(false),
    /// Several can be marked.
    multi: bool = false,
    /// A position among the shown items.
    selected: u32 = 0,
    scroll: u32 = 0,
    purpose: Purpose,
    /// What OK says: "Add", "Move".
    verb: []const u8,

    pub const Item = struct {
        label: []const u8,
        /// Muted, after the label: where it is now, its due date.
        detail: []const u8 = "",
        /// What choosing it means, in the modal arena.
        value: []const u8,
        current: bool = false,
        disabled: bool = false,
        done: bool = false,
        marked: bool = false,
    };

    /// The items the filter text matches, in order: every word in the
    /// label or the detail, ignoring case.
    pub fn shown(p: *const Picker, a: Allocator) Allocator.Error![]const u32 {
        var out: std.ArrayList(u32) = .empty;
        next: for (p.items, 0..) |it, n| {
            var words = std.mem.tokenizeAny(u8, p.filter.text(), " \t");
            while (words.next()) |w| {
                const w_ = std.mem.trimStart(u8, w, "#");
                if (std.ascii.findIgnoreCase(
                    it.label,
                    w_,
                ) == null and std.ascii.findIgnoreCase(it.detail, w_) == null) continue :next;
            }
            try out.append(a, @intCast(n));
        }
        return out.items;
    }

    fn marked(p: *const Picker) usize {
        var n: usize = 0;
        for (p.items) |it| n += @intFromBool(it.marked);
        return n;
    }
};

/// What is unpushed, quarantined and in conflict for the sync remote,
/// with the ways to sync and to resolve.
pub const SyncPanel = struct {
    remote: []const u8,
    url: []const u8 = "",
    /// What about the remote couldn't be read.
    problem: []const u8 = "",
    rows: []const Row,
    selected: u32 = 0,
    scroll: u32 = 0,

    pub const Row = union(enum) {
        heading: []const u8,
        /// Nothing in a section.
        empty: []const u8,
        unpushed: struct { id: Id, label: []const u8, new: bool, milestone: bool },
        quarantined: struct {
            id: Id,
            label: []const u8,
            reason: []const u8,
            kept: bool,
            local: bool,
            milestone: bool = false,
        },
        conflict: struct { id: Id, label: []const u8, what: []const u8, field: ?Field },
    };

    fn selectable(r: Row) bool {
        return switch (r) {
            .heading, .empty => false,
            else => true,
        };
    }

    fn step(p: *SyncPanel, by: i32) void {
        var n: i64 = p.selected;
        while (true) {
            n += by;
            if (n < 0 or n >= p.rows.len) return;
            if (selectable(p.rows[@intCast(n)])) break;
        }
        p.selected = @intCast(n);
    }

    pub fn first(p: *SyncPanel) void {
        p.selected = 0;
        if (p.rows.len > 0 and !selectable(p.rows[0])) p.step(1);
    }
};

pub const Help = struct {
    scroll: u16 = 0,
    /// The lines the last draw showed: a page.
    rows: u16 = 0,
};

pub const Modal = union(enum) {
    prompt: Prompt,
    editor: Editor,
    menu: Menu,
    picker: Picker,
    sync_panel: SyncPanel,
    form: Form,
    milestone_form: MilestoneForm,
    confirm: Confirm,
    help: Help,

    pub fn deinit(m: *Modal, gpa: Allocator) void {
        switch (m.*) {
            .prompt => |*p| p.input.deinit(gpa),
            .editor => |*e| e.input.deinit(gpa),
            .form => |*f| f.deinit(gpa),
            .milestone_form => |*f| f.deinit(gpa),
            .picker => |*p| p.filter.deinit(gpa),
            .menu, .help, .confirm, .sync_panel => {},
        }
    }

    pub fn issue(m: *const Modal) ?Id {
        return switch (m.*) {
            .prompt => |*p| p.purpose.issue(),
            .editor => |*e| e.purpose.issue(),
            .menu => |*mn| mn.purpose.issue(),
            .form, .help, .milestone_form, .confirm, .picker, .sync_panel => null,
        };
    }

    /// Whether closing it loses something typed or marked.
    pub fn unsaved(m: *const Modal) bool {
        return switch (m.*) {
            .prompt => |*p| !std.mem.eql(u8, p.input.text(), p.opened),
            .editor => |*e| !std.mem.eql(u8, e.input.text(), e.original),
            .form => |*f| f.hasText(),
            .milestone_form => |*f| f.changed(),
            .picker => |*p| p.marked() > 0,
            .menu, .help, .confirm, .sync_panel => false,
        };
    }

    pub fn hint(m: *const Modal) []const u8 {
        return switch (m.*) {
            .prompt => |*p| if (p.date) "⏎ save  esc cancel  (" ++ dates.hint ++
                ")" else "⏎ save  esc cancel",
            .editor => "ctrl+s save  esc cancel  (⏎ new line)",
            .menu => "↑↓ j k choose  a letter jumps  ⏎ select  esc cancel",
            .form => "tab/↑↓ next field  ←→ choose  ctrl+s create  esc cancel",
            .milestone_form => "tab/↑↓ next field  ctrl+s save  esc cancel",
            .confirm => "←→ choose  ⏎ select  esc cancel",
            .sync_panel => "y sync  f fetch & merge  p push  ←→ remote  ↑↓ j k choose  ⏎ open  " ++
                "a accept remote  l keep local  esc close",
            .picker => |*p| if (p.multi) "type to filter  ↑↓ choose  tab mark several  ⏎ add  " ++
                "esc cancel" else "type to filter  ↑↓ choose  ⏎ select  esc cancel",
            .help => "↑↓ j k scroll  space pgup pgdn a page  g G ends  esc q ? or click to close",
        };
    }

    pub fn draw(m: *Modal, s: *AppState, f: ui.Frame, win: ui.Window) Allocator.Error!void {
        try f.hit(win, .backdrop);
        switch (m.*) {
            .prompt => |*p| try drawPrompt(s, f, win, p),
            .editor => |*e| try drawEditor(f, win, e),
            .menu => |*mn| try drawMenu(f, win, mn),
            .form => |*fm| try fm.draw(s, f, win),
            .milestone_form => |*fm| try fm.draw(s, f, win),
            .confirm => |*c| try drawConfirm(f, win, c),
            .picker => |*p| try drawPicker(f, win, p),
            .sync_panel => |*p| try drawSyncPanel(s, f, win, p),
            .help => |*h| try drawHelp(f, win, h),
        }
    }

    pub fn wheel(
        m: *Modal,
        s: *AppState,
        found: ?ui.Hits.Found,
        delta: i32,
    ) Allocator.Error!Action {
        _ = found;
        const a = s.input_arena.allocator();
        switch (m.*) {
            .editor => |*e| try e.input.scrollBy(a, delta),
            .form => |*fm| try fm.description.scrollBy(a, delta),
            .milestone_form => |*fm| try fm.description.scrollBy(a, delta),
            .menu => |*mn| {
                const n: i32 = @intCast(mn.options.len);
                mn.selected = @intCast(
                    std.math.clamp(@as(i32, mn.selected) + std.math.sign(delta), 0, n - 1),
                );
            },
            .help => |*h| h.scroll = @intCast(
                std.math.clamp(@as(i32, h.scroll) + delta, 0, help_lines.len),
            ),
            .prompt, .confirm => {},
            .sync_panel => |*p| p.step(std.math.sign(delta)),
            .picker => |*p| {
                const n: i64 = @intCast((try p.shown(a)).len);
                p.selected = @intCast(
                    std.math.clamp(@as(i64, p.selected) + std.math.sign(delta), 0, @max(n - 1, 0)),
                );
            },
        }
        return .none;
    }

    pub fn click(m: *Modal, s: *AppState, h: ui.Hits.Found) Allocator.Error!Action {
        const a = s.input_arena.allocator();
        const t = switch (h.target) {
            .modal => |t| t,
            .backdrop => {
                switch (m.*) {
                    .picker => |*p| closePicker(s, p),
                    .menu, .help, .confirm, .sync_panel => s.closeModal(),
                    else => {},
                }
                return .none;
            },
            else => return .none,
        };
        if (m.* == .help) {
            s.closeModal();
            return .none;
        }
        switch (t) {
            .ok => return submit(s),
            .cancel => s.closeModal(),
            .choice => |c| switch (m.*) {
                .menu => |*mn| {
                    if (c >= mn.options.len) return .none;
                    mn.selected = @intCast(c);
                    return submit(s);
                },
                .confirm => |*cf| {
                    if (c >= cf.choices.len) return .none;
                    cf.selected = @intCast(c);
                    return submit(s);
                },
                .sync_panel => |*p| {
                    if (c >= p.rows.len or !SyncPanel.selectable(p.rows[c])) return .none;
                    p.selected = c;
                    return syncPanelOpen(s, p);
                },
                .picker => |*p| {
                    const shown = try p.shown(a);
                    if (c >= shown.len) return .none;
                    p.selected = c;
                    // With marks, a click marks; else it picks.
                    if (p.multi and p.marked() > 0) {
                        const it = &p.items[shown[c]];
                        if (!it.disabled) it.marked = !it.marked;
                        s.discard_armed = false;
                        return .none;
                    }
                    return submit(s);
                },
                else => {},
            },
            .field => |n| switch (m.*) {
                .form => |*fm| {
                    fm.focus = n;
                    if (fm.textArea(n)) |ta| {
                        if (ta.multiline) try ta.click(a, h.y, h.x) else ta.clickLine(h.x);
                    }
                },
                .milestone_form => |*fm| {
                    fm.focus = n;
                    const ta = fm.textArea(n);
                    if (ta.multiline) try ta.click(a, h.y, h.x) else ta.clickLine(h.x);
                },
                .prompt => |*p| p.input.clickLine(h.x),
                .picker => |*p| p.filter.clickLine(h.x),
                .editor => |*e| try e.input.click(a, h.y, h.x),
                else => {},
            },
            .option => |o| switch (m.*) {
                .sync_panel => |*p| {
                    if (o.field == 0) return nextRemote(s, p, if (o.option == 0) -1 else 1);
                    return .{ .sync = switch (o.option) {
                        0 => .sync,
                        1 => .merge,
                        else => .push,
                    } };
                },
                .form => |*fm| {
                    fm.focus = o.field;
                    fm.setOption(o.field, o.option);
                },
                else => {},
            },
        }
        return .none;
    }
};

// Opening dialogs from the detail view.

fn dupe(s: *AppState, v: []const u8) []const u8 {
    return s.modalArena().dupe(u8, v) catch "";
}

fn print(s: *AppState, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(s.modalArena(), format, args) catch "";
}

/// `value` may live in the modal arena, which closing the open dialog
/// resets: it is copied first. `value` is the issue's, unless `fresh`.
/// From a dialog on the same issue (a menu's "Other…"), the tip that one
/// showed is kept.
pub fn openPrompt(
    s: *AppState,
    title: []const u8,
    hint: []const u8,
    value: []const u8,
    purpose: Purpose,
    fresh: bool,
) void {
    var input: TextArea = .init(false);
    input.set(s.gpa, value) catch {};
    const kept = s.modal_tip;
    s.closeModal();
    s.openModal(.{ .prompt = .{
        .title = dupe(s, title),
        .hint = dupe(s, hint),
        .original = if (fresh) null else dupe(s, input.text()),
        .opened = dupe(s, input.text()),
        .input = input,
        .purpose = purpose,
    } });
    if (kept) |k| if (s.modal_tip) |*t| if (t.id.eql(k.id.slice())) {
        t.tip = k.tip;
    };
}

/// For an answer that is what the issue already has: no write.
fn unchanged(s: *AppState) Action {
    s.closeModal();
    return s.noted("unchanged", .{});
}

pub fn editTitle(s: *AppState, i: u32) void {
    const issue = s.snap.issues[i];
    openPrompt(s, "Title", "", issue.title, .{ .title = .of(issue.id) }, false);
}

pub fn editDescription(s: *AppState, i: u32) void {
    const issue = s.snap.issues[i];
    s.closeModal();
    var e: Editor = .{
        .title = print(s, "Description of #{s}", .{shortId(issue.id)}),
        .original = dupe(s, issue.description),
        .purpose = .{ .description = .of(issue.id) },
    };
    e.input.set(s.gpa, issue.description) catch {};
    s.openModal(.{ .editor = e });
}

pub fn addComment(s: *AppState, i: u32) void {
    const issue = s.snap.issues[i];
    s.closeModal();
    s.openModal(.{ .editor = .{
        .title = print(s, "Comment on #{s}", .{shortId(issue.id)}),
        .original = "",
        .purpose = .{ .comment = .of(issue.id) },
    } });
}

pub fn editField(s: *AppState, i: u32, field: Field) void {
    const snap = s.snap;
    const issue = snap.issues[i];
    const purpose: Purpose = .{ .field = .{ .id = .of(issue.id), .field = field } };
    const a = s.modalArena();
    s.closeModal();
    const hint: []const u8, const value: []const u8 = switch (field) {
        .state, .workflow, .priority, .milestone => return openFieldMenu(s, i, field, purpose),
        .assignee => .{ "an email; empty unassigns", issue.field("Assignee") orelse "" },
        .labels => .{
            "comma-separated; empty removes all",
            std.mem.join(a, ", ", issue.labels) catch "",
        },
        .parent => blk: {
            const p = snap.proj.parent[i];
            break :blk .{
                "an issue ID (prefix); empty makes it top-level",
                if (p == std.math.maxInt(u32)) "" else shortId(snap.issues[p].id),
            };
        },
        .blocked_by => blk: {
            var ids: std.ArrayList(u8) = .empty;
            for (issue.blocked_by, 0..) |b, n| {
                if (n > 0) ids.append(a, ' ') catch {};
                ids.appendSlice(a, shortId(b)) catch {};
            }
            break :blk .{ "issue IDs (prefixes), space-separated; empty clears", ids.items };
        },
        .start, .due => blk: {
            const d = if (field == .start) issue.start_date else issue.due_date;
            break :blk .{ dates.hint, if (d) |date| print(s, "{f}", .{date}) else "" };
        },
        .estimate => .{
            "like 90m, 2h or 1h30m; empty clears",
            if (issue.estimate_minutes) |m| durationText(s, m) else "",
        },
    };
    openPrompt(s, field.label(), hint, value, purpose, false);
    if (field == .start or field == .due) s.modal.?.prompt.date = true;
}

/// A field with a few values, the issue's marked. Copied: the menu outlives
/// a reload of the snapshot they're in.
const FieldOptions = struct {
    a: Allocator,
    current: []const u8,
    list: std.ArrayList(Menu.Option) = .empty,

    fn add(o: *FieldOptions, label: []const u8, value: []const u8) void {
        o.list.append(o.a, .{
            .label = o.a.dupe(u8, label) catch return,
            .value = o.a.dupe(u8, value) catch return,
            .current = std.mem.eql(u8, value, o.current),
        }) catch {};
    }
};

fn openFieldMenu(s: *AppState, i: u32, field: Field, purpose: Purpose) void {
    const snap = s.snap;
    const issue = snap.issues[i];
    var o: FieldOptions = .{
        .a = s.modalArena(),
        .current = switch (field) {
            .state => issue.state.text(),
            .workflow => issue.workflow orelse "",
            .priority => issue.field("Priority") orelse "",
            // Catalog milestones by ID; a plain-text one is none of the options.
            .milestone => milestoneCurrent(snap, i),
            else => unreachable,
        },
    };
    switch (field) {
        .state => {
            o.add("open", "open");
            o.add("closed", "closed");
            for (snap.settings.done_states) |d| o.add(d, d);
            if (issue.state == .other and !issue.state.isDone(snap.settings.done_states)) {
                o.add(issue.state.text(), issue.state.text());
            }
        },
        .workflow => {
            for (snap.settings.workflow_states) |w| o.add(w, w);
            o.add("(default)", "");
        },
        .priority => {
            o.add("(none)", "");
            for ([_][]const u8{ "low", "medium", "high", "critical" }) |p| o.add(p, p);
        },
        .milestone => {
            for (snap.milestones) |m| if (m.status == .open) o.add(m.name, m.id);
            o.add("(none)", link_none);
            if (snap.proj.parent[i] != std.math.maxInt(u32)) {
                o.add("(inherit from parent)", link_inherit);
            }
            o.list.append(o.a, .{ .label = "Other…", .value = "", .other = true }) catch {};
        },
        else => unreachable,
    }
    var selected: u16 = 0;
    for (o.list.items, 0..) |option, n| if (option.current) {
        selected = @intCast(n);
    };
    s.openModal(.{ .menu = .{
        .title = print(s, "{s} of #{s}", .{ field.label(), shortId(issue.id) }),
        .options = o.list.items,
        .selected = selected,
        .purpose = purpose,
    } });
}

/// Menu values for milestone links that aren't a catalog ID.
pub const link_none = "none";
pub const link_inherit = "inherit";

/// The milestone menu's current value: the linked ID, `link_inherit`
/// when it follows its parent, `link_none` without one, and nothing for a
/// milestone written as plain text.
fn milestoneCurrent(snap: *const store.Snapshot, i: u32) []const u8 {
    const ext = &snap.issues[i];
    const has_parent = snap.proj.parent[i] != std.math.maxInt(u32);
    return switch (fields_fmt.MilestoneMode.of(
        ext.milestone_mode,
        .{ .has_id = ext.milestone_id != null, .has_parent = has_parent },
    )) {
        .explicit => ext.milestone_id orelse "\x00",
        .inherit => link_inherit,
        .none => if ((snap.issues[i].field(
            "Milestone",
        ) orelse @as([]const u8, "")).len > 0) "\x00" else link_none,
    };
}

/// A milestone menu value as a link. IDs are in the modal arena.
pub fn linkOf(value: []const u8) store.MilestoneLink {
    if (std.mem.eql(u8, value, link_none)) return .none;
    if (std.mem.eql(u8, value, link_inherit)) return .inherit;
    return .{ .id = value };
}

fn durationText(s: *AppState, minutes: u32) []const u8 {
    const h = minutes / 60;
    const m = minutes % 60;
    if (h == 0) return print(s, "{d}m", .{m});
    if (m == 0) return print(s, "{d}h", .{h});
    return print(s, "{d}h{d}m", .{ h, m });
}

/// The sort keys; choosing the current one flips the order.
pub fn openSort(s: *AppState) void {
    openSortMenu(s, filter.SortKey, s.issueQuery().key, "Sort by", .sort);
}

/// `Key`'s values as a menu, `current` marked.
fn openSortMenu(
    s: *AppState,
    comptime Key: type,
    current: Key,
    title: []const u8,
    purpose: Purpose,
) void {
    s.closeModal();
    const keys = std.enums.values(Key);
    const options = s.modalArena().alloc(
        Menu.Option,
        keys.len,
    ) catch return s.fail("out of memory", .{});
    var selected: u16 = 0;
    for (keys, options, 0..) |k, *o, n| {
        if (k == current) selected = @intCast(n);
        o.* = .{
            .label = print(s, "{s:<9} {s}", .{ k.label(), k.order() }),
            .value = k.label(),
            .current = k == current,
        };
    }
    s.openModal(.{ .menu = .{
        .title = title,
        .options = options,
        .selected = selected,
        .purpose = purpose,
    } });
}

/// Choosing the key in use flips the order; another sorts by it.
fn toggleSort(q: anytype, comptime Key: type, value: []const u8) void {
    const k = std.meta.stringToEnum(Key, value).?;
    if (q.key == k) q.reverse = !q.reverse else {
        q.key = k;
        q.reverse = false;
    }
}

/// The open milestones with their progress; choosing one filters the
/// list and the board by it (`m:`), "No milestone" by none.
pub fn openMilestones(s: *AppState) void {
    s.closeModal();
    const a = s.modalArena();
    var options: std.ArrayList(Menu.Option) = .empty;
    for (s.snap.milestones) |m| {
        if (m.status != .open) continue;
        const p = s.snap.proj.milestoneProgress(a, m.id) catch return s.fail("out of memory", .{});
        const due = if (m.due) |d| print(s, "  due {f}", .{d}) else "";
        options.append(a, .{
            .label = print(s, "{s}  {d}/{d} done{s}", .{ m.name, p.closed, p.total, due }),
            // A filter term is one word; a longer name matches by its first.
            .value = m.name[0 .. std.mem.findScalar(u8, m.name, ' ') orelse m.name.len],
        }) catch return s.fail("out of memory", .{});
    }
    options.append(a, .{ .label = "No milestone", .value = "" }) catch
        return s.fail("out of memory", .{});
    s.openModal(.{ .menu = .{
        .title = "Milestones",
        .options = options.items,
        .purpose = .milestones,
    } });
}

// Keys.

pub fn key(s: *AppState, k: vaxis.Key) Allocator.Error!Action {
    const m = &s.modal.?;
    const gpa = s.gpa;
    const a = s.input_arena.allocator();
    if (s.pasting) {
        try pasteKey(s, m, k);
        return .none;
    }
    const save = k.matches('s', .{ .ctrl = true }) or k.matches(K.f2, .{});
    switch (m.*) {
        .help => |*h| helpKey(s, h, k),
        .prompt => |*p| {
            if (k.matches(K.escape, .{})) {
                s.closeModal();
            } else if (k.matches(K.enter, .{}) or save) {
                return submit(s);
            } else {
                s.discard_armed = false;
                _ = try p.input.key(gpa, a, k);
            }
        },
        .editor => |*e| {
            if (k.matches(K.escape, .{})) {
                const changed = !std.mem.eql(u8, e.input.text(), e.original);
                const ask = "unsaved text: press esc again to discard, ctrl+s to save";
                closeOrAsk(s, changed, ask, .{});
            } else if (save) {
                return submit(s);
            } else {
                s.discard_armed = false;
                _ = try e.input.key(gpa, a, k);
            }
        },
        .menu => |*mn| {
            const n: i32 = @intCast(mn.options.len);
            if (k.matches(K.escape, .{}) or k.matches('q', .{})) {
                s.closeModal();
            } else if (k.matches(K.down, .{}) or k.matches('j', .{}) or k.matches(K.tab, .{})) {
                mn.selected = @intCast(@mod(@as(i32, mn.selected) + 1, n));
            } else if (k.matches(K.up, .{}) or k.matches('k', .{}) or
                k.matches(K.tab, .{ .shift = true }))
            {
                mn.selected = @intCast(@mod(@as(i32, mn.selected) - 1, n));
            } else if (k.matches(K.enter, .{}) or k.matches(K.space, .{})) {
                return submit(s);
            } else if (letterOf(k)) |l| {
                // Jump to the next option starting with the letter; q, j
                // and k keep closing and moving.
                if (nextStarting(mn.options, mn.selected, l)) |idx| mn.selected = @intCast(idx);
            }
        },
        .form => |*fm| return fm.key(s, k, save),
        .milestone_form => |*fm| return fm.key(s, k, save),
        .sync_panel => |*p| return syncPanelKey(s, p, k),
        .picker => |*p| return pickerKey(s, p, k, save),
        .confirm => |*c| {
            const n: i32 = @intCast(c.choices.len);
            if (k.matches(K.escape, .{}) or k.matches('q', .{})) {
                s.closeModal();
            } else if (k.matches(K.right, .{}) or k.matches(K.tab, .{}) or k.matches('l', .{})) {
                c.selected = @intCast(@mod(@as(i32, c.selected) + 1, n));
            } else if (k.matches(
                K.left,
                .{},
            ) or k.matches(K.tab, .{ .shift = true }) or k.matches('h', .{})) {
                c.selected = @intCast(@mod(@as(i32, c.selected) - 1, n));
            } else if (k.matches(K.enter, .{}) or k.matches(K.space, .{})) {
                return submit(s);
            } else if (letterOf(k)) |l| {
                // The first letter of an answer picks it, unless it is the
                // opening key's or another answer starts with it too.
                if (c.opener) |o| if (sameLetter(o, l)) return .none;
                const idx = nextStarting(c.choices, c.choices.len - 1, l) orelse return .none;
                if (nextStarting(c.choices, idx, l).? != idx) return .none;
                c.selected = @intCast(idx);
                return submit(s);
            }
        },
    }
    return .none;
}

fn helpKey(s: *AppState, h: *Help, k: vaxis.Key) void {
    const page: i32 = @max(h.rows -| 1, 1);
    const all: i32 = help_lines.len;
    const by: i32 = if (k.matches(K.down, .{}) or k.matches('j', .{}))
        1
    else if (k.matches(K.up, .{}) or k.matches('k', .{}))
        -1
    else if (k.matches(K.page_down, .{}) or k.matches(K.space, .{}))
        page
    else if (k.matches(K.page_up, .{}))
        -page
    else if (k.matches('g', .{}) or k.matches(K.home, .{}))
        -all
    else if (k.matches('G', .{}) or k.matches(K.end, .{}))
        all
    else {
        if (k.matches(K.escape, .{}) or k.matches('q', .{}) or k.matches('?', .{}) or
            k.matches(K.enter, .{}) or k.matches(K.f1, .{})) s.closeModal();
        return;
    };
    // Drawing keeps it within the lines.
    h.scroll = @intCast(std.math.clamp(@as(i32, h.scroll) + by, 0, all));
}

fn pickerKey(s: *AppState, p: *Picker, k: vaxis.Key, save: bool) Allocator.Error!Action {
    if (k.matches(K.escape, .{})) {
        if (p.filter.text().len > 0) {
            p.filter.clear();
            p.selected = 0;
        } else closePicker(s, p);
        return .none;
    }
    s.discard_armed = false;
    const a = s.input_arena.allocator();
    const shown = try p.shown(a);
    const last: i64 = @max(@as(i64, @intCast(shown.len)) - 1, 0);
    const ctrl: K.Modifiers = .{ .ctrl = true };
    const by: ?i64 = if (k.matches(K.down, .{}) or k.matches('n', ctrl) or k.matches('j', ctrl))
        1
    else if (k.matches(K.up, .{}) or k.matches('p', ctrl) or k.matches('k', ctrl))
        -1
    else if (k.matches(K.page_down, .{}))
        10
    else if (k.matches(K.page_up, .{}))
        -10
    else
        null;
    if (by) |b| {
        p.selected = @intCast(std.math.clamp(@as(i64, p.selected) + b, 0, last));
    } else if (p.multi and (k.matches(K.tab, .{}) or k.matches(K.tab, .{ .shift = true }))) {
        if (p.selected < shown.len) {
            const it = &p.items[shown[p.selected]];
            if (!it.disabled) it.marked = !it.marked;
            if (k.matches(K.tab, .{})) p.selected = @intCast(@min(@as(i64, p.selected) + 1, last));
        }
    } else if (k.matches(K.enter, .{}) or save) {
        return submit(s);
    } else {
        // Moving the cursor keeps the row; new text starts over.
        const before = try a.dupe(u8, p.filter.text());
        _ = try p.filter.key(s.gpa, a, k);
        if (!std.mem.eql(u8, before, p.filter.text())) p.selected = 0;
    }
    return .none;
}

/// Closing with something to lose asks once.
fn closeOrAsk(s: *AppState, losing: bool, comptime format: []const u8, args: anytype) void {
    if (losing and !s.discard_armed) {
        s.discard_armed = true;
        s.fail(format, args);
    } else s.closeModal();
}

/// Marks are a choice made: closing asks once before dropping them.
fn closePicker(s: *AppState, p: *const Picker) void {
    const marked = p.marked();
    closeOrAsk(s, marked > 0, "{d} marked: press esc again to drop them", .{marked});
}

/// The first character a key types, if it types one.
fn letterOf(k: vaxis.Key) ?u21 {
    return firstCodepoint(k.text orelse return null);
}

fn firstCodepoint(t: []const u8) ?u21 {
    if (t.len == 0) return null;
    const n = std.unicode.utf8ByteSequenceLength(t[0]) catch return null;
    if (n > t.len) return null;
    return std.unicode.utf8Decode(t[0..n]) catch null;
}

/// Letters equal ignoring ASCII case; others only when they are the same.
fn sameLetter(a: u21, b: u21) bool {
    if (a < 0x80 and b < 0x80) return std.ascii.toLower(
        @intCast(a),
    ) == std.ascii.toLower(@intCast(b));
    return a == b;
}

/// The next item after `from`, going round, whose label starts with the
/// letter `l`: `from` itself when it is the only one.
fn nextStarting(items: anytype, from: usize, l: u21) ?usize {
    for (1..items.len + 1) |step| {
        const idx = (from + step) % items.len;
        if (sameLetter(firstCodepoint(items[idx].label) orelse continue, l)) return idx;
    }
    return null;
}

/// After a key: a confirm it opened notes the key's letter.
pub fn noteOpener(s: *AppState, had_confirm: bool, k: vaxis.Key) void {
    if (had_confirm) return;
    const m = &(s.modal orelse return);
    if (m.* == .confirm) m.confirm.opener = letterOf(k);
}

/// Pasted text goes into the focused text box, whatever it holds; menus,
/// the help and a form's option fields take none of it.
fn pasteKey(s: *AppState, m: *Modal, k: vaxis.Key) Allocator.Error!void {
    const ta: *TextArea = switch (m.*) {
        .prompt => |*p| &p.input,
        .editor => |*e| &e.input,
        .form => |*fm| fm.textArea(fm.focus) orelse return,
        .milestone_form => |*fm| fm.textArea(fm.focus),
        .picker => |*p| &p.filter,
        .menu, .help, .confirm, .sync_panel => return,
    };
    s.discard_armed = false;
    try ta.pasteKey(s.gpa, k);
}

// Answers into actions.

/// The issue changed since the dialog opened (`AppState.modalStale`):
/// what it showed as unchanged may not be any more. Once the user has
/// been told, saving again replaces what is there now.
pub fn rebase(s: *AppState) void {
    const m = &(s.modal orelse return);
    switch (m.*) {
        // Any answer is a change now.
        .prompt => |*p| p.original = null,
        .menu => |*mn| for (mn.options) |*o| {
            o.current = false;
        },
        .editor => |*e| if (e.purpose == .description) {
            const i = s.snap.find(e.purpose.description.slice()) orelse return;
            e.original = dupe(s, s.snap.issues[i].description);
        },
        // An answer that writes a milestone expects the tip shown now.
        .confirm => |*c| for (c.choices) |*ch| if (ch.action == .edit_milestone) {
            const em = &ch.action.edit_milestone;
            if (s.snap.findMilestone(em.id.slice())) |n| em.edit.expect = s.snap.milestones[n].tip;
        },
        .form, .help, .picker, .sync_panel => {},
        .milestone_form => |*f| if (f.editing) |*e| {
            if (s.snap.findMilestone(e.id.slice())) |n| e.tip = s.snap.milestones[n].tip;
        },
    }
    if (m.* == .prompt and m.prompt.purpose == .milestone) {
        const mp = &m.prompt.purpose.milestone;
        if (s.snap.findMilestone(mp.id.slice())) |n| mp.tip = s.snap.milestones[n].tip;
    }
}

fn submit(s: *AppState) Action {
    const m = &s.modal.?;
    if (s.modalStale()) {
        const id = m.issue().?;
        s.rebaseModal();
        return s.failed(
            "#{s} changed meanwhile: save again to replace it with yours",
            .{shortId(id.slice())},
        );
    }
    if (milestoneStale(s)) |name| {
        rebase(s);
        return s.failed(
            "milestone {s} changed meanwhile: save again to replace it with yours",
            .{name},
        );
    }
    switch (m.*) {
        .help => return .none,
        .form => |*fm| return fm.submit(s),
        .milestone_form => |*fm| return fm.submit(s),
        .confirm => |*c| {
            const act = c.choices[c.selected].action;
            if (act == .none) s.closeModal();
            return act;
        },
        .picker => |*p| return pickerSubmit(s, p),
        .sync_panel => |*p| return syncPanelOpen(s, p),
        .editor => |*e| {
            const t = e.input.text();
            switch (e.purpose) {
                .description => |id| {
                    if (std.mem.eql(u8, t, e.original)) return unchanged(s);
                    return .{ .edit = .{ .id = id, .spec = .{ .description = t } } };
                },
                .comment => |id| {
                    if (std.mem.trim(u8, t, " \t\n").len == 0) {
                        return s.failed("a comment needs some text", .{});
                    }
                    return .{ .comment = .{ .id = id, .text = t } };
                },
                else => unreachable,
            }
        },
        .menu => |*mn| return menuSubmit(s, mn),
        .prompt => |*p| return promptSubmit(s, p),
    }
}

fn menuSubmit(s: *AppState, mn: *Menu) Action {
    const o = mn.options[mn.selected];
    if (o.disabled) return s.failed("{s}: reopen it first to add open work", .{o.label});
    switch (mn.purpose) {
        .stage_milestone => |id| {
            const link: draft_mod.Link = switch (linkOf(o.value)) {
                .none => .none,
                .inherit => .inherit,
                .id => |v| .{ .id = .of(v) },
            };
            return .{ .stage = .{ .milestone = .{ .id = id, .link = link } } };
        },
        .stage_unblock => |id| return .{
            .stage = .{ .remove_blocker = .{ .id = id, .blocker = .of(o.value) } },
        },
        .pane_pick => {
            const v = &s.milestone;
            v.other = if (std.mem.eql(u8, o.value, link_none)) .none else .{ .id = .of(o.value) };
            v.split = true;
            v.pane = 1;
            v.panes[1] = .{};
        },
        .milestones => {
            var buf: [256]u8 = undefined;
            const term = std.fmt.bufPrint(&buf, "m:{s}", .{o.value}) catch "m:";
            s.search.set(s.gpa, term) catch return s.failed("out of memory", .{});
            s.closeModal();
            s.filterChanged();
            return .none;
        },
        .sort => toggleSort(s.issueQuery(), filter.SortKey, o.value),
        .milestone_sort => {
            toggleSort(&s.ms_query, milestone_filter.SortKey, o.value);
            s.milestones.follow = true;
        },
        .field => |fp| {
            if (o.current) return unchanged(s);
            if (o.other) {
                openPrompt(
                    s,
                    "Milestone",
                    "a milestone name, kept as text if no open milestone has it",
                    "",
                    mn.purpose,
                    true,
                );
                return .none;
            }
            return switch (fp.field) {
                .state => .{ .state = .{ .id = fp.id, .state = o.value } },
                .workflow => .{
                    .edit = .{ .id = fp.id, .spec = .{ .workflow = .fromInput(o.value) } },
                },
                .priority => .{ .edit = .{ .id = fp.id, .spec = .{
                    .priority = if (core.Priority.parse(o.value)) |p| .{ .set = p } else .clear,
                } } },
                .milestone => .{ .milestone_link = .{ .id = fp.id, .link = linkOf(o.value) } },
                else => unreachable,
            };
        },
        else => unreachable,
    }
    s.closeModal();
    return .none;
}

fn promptSubmit(s: *AppState, p: *Prompt) Action {
    const t = std.mem.trim(u8, p.input.text(), " \t");
    if (p.original) |o| {
        if (std.mem.eql(u8, t, std.mem.trim(u8, o, " \t"))) return unchanged(s);
    }
    switch (p.purpose) {
        .title => |id| {
            if (t.len == 0) return s.failed("the title can't be empty", .{});
            return .{ .edit = .{ .id = id, .spec = .{ .title = t } } };
        },
        .field => |fp| return fieldAction(s, s.modalArena(), fp.id, fp.field, t),
        .stage_date => |sd| {
            const d: ?Date = if (t.len == 0) null else dateOrFail(s, t) orelse return .none;
            const i = s.snap.find(sd.id.slice()) orelse return .none;
            const cur = @import("timeline_view.zig").datesOf(s, i);
            const start = if (sd.start) d else cur.start;
            const due = if (sd.start) cur.due else d;
            if (start != null and due != null and start.?.order(due.?) == .gt) {
                return s.failed("the start can't be after the due date", .{});
            }
            // Only the date typed: the other stays what it is when applied.
            return .{ .stage = .{
                .dates = if (sd.start) .{ .id = sd.id, .start = d } else .{ .id = sd.id, .due = d },
            } };
        },
        .stage_ms_due => |id| {
            const d: ?Date = if (t.len == 0) null else dateOrFail(s, t) orelse return .none;
            return .{ .stage = .{ .milestone_due = .{ .id = id, .due = d } } };
        },
        .stage_estimate => |id| {
            const m: ?u32 = if (t.len == 0) null else durationOrFail(s, t) orelse return .none;
            return .{ .stage = .{ .estimate = .{ .id = id, .minutes = m } } };
        },
        .quick_add => |scope| {
            if (t.len == 0) {
                s.closeModal();
                return .none;
            }
            return .{ .quick_create = .{
                .title = t,
                .milestone_id = if (scope == .id) dupe(s, scope.id.slice()) else null,
            } };
        },
        .milestone => |mp| {
            var edit: store.MilestoneEdit = .{ .expect = mp.tip };
            switch (mp.what) {
                .name => {
                    if (!validName(s, t)) return .none;
                    edit.name = t;
                },
                .due => edit.due = dateValue(s, t) orelse return .none,
            }
            return .{ .edit_milestone = .{ .id = mp.id, .edit = edit } };
        },
        else => unreachable,
    }
}

/// What `Catalog` takes as a name, checked first to say why.
fn validName(s: *AppState, t: []const u8) bool {
    if (t.len == 0) {
        s.fail("a milestone needs a name", .{});
        return false;
    }
    if (t.len > 256 or std.mem.findAny(u8, t, "\r\n") != null) {
        s.fail("a milestone name is one line of at most 256 bytes", .{});
        return false;
    }
    return true;
}

/// The name of the milestone the open dialog edits, when it changed
/// since the dialog opened.
fn milestoneStale(s: *AppState) ?[]const u8 {
    const m = &(s.modal orelse return null);
    const mt: struct { Id, issuez.engine.Oid } = switch (m.*) {
        .prompt => |*p| if (p.purpose == .milestone) .{
            p.purpose.milestone.id,
            p.purpose.milestone.tip,
        } else return null,
        .milestone_form => |*f| if (f.editing) |e| .{ e.id, e.tip } else return null,
        else => return null,
    };
    const n = s.snap.findMilestone(mt[0].slice()) orelse return null;
    const now = s.snap.milestones[n];
    if (now.tip.eql(mt[1])) return null;
    return now.name;
}

fn fieldAction(s: *AppState, a: Allocator, id: Id, field: Field, t: []const u8) Action {
    const edit = struct {
        fn f(i: Id, spec: issuez.engine.EditSpec) Action {
            return .{ .edit = .{ .id = i, .spec = spec } };
        }
    }.f;
    switch (field) {
        .assignee => {
            if (t.len == 0) return edit(id, .{ .set_assignees = &.{} });
            const one = fields_fmt.Assignee.parse(t) orelse {
                return s.failed("'{s}' isn't an email", .{t});
            };
            const list = a.dupe(fields_fmt.Assignee, &.{one}) catch return .none;
            return edit(id, .{ .set_assignees = list });
        },
        .labels => return edit(id, .{ .set_labels = splitLabels(a, t) catch return .none }),
        .milestone => return .{ .milestone = .{ .id = id, .name = t } },
        .parent => {
            if (t.len == 0) return edit(id, .{ .parent = .clear });
            const p = resolve(s, t) orelse return .none;
            return edit(id, .{ .parent = .{ .set = p } });
        },
        .blocked_by => {
            var ids: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, t, " ,\t");
            while (it.next()) |prefix| {
                const b = resolve(s, std.mem.trimStart(u8, prefix, "#")) orelse return .none;
                ids.append(a, b) catch return .none;
            }
            return edit(id, .{ .set_blocked_by = ids.items });
        },
        .start, .due => {
            const value = dateValue(s, t) orelse return .none;
            return edit(
                id,
                if (field == .start) .{ .start_date = value } else .{ .due_date = value },
            );
        },
        .estimate => {
            if (t.len == 0) return edit(id, .{ .estimate_minutes = .clear });
            const m = durationOrFail(s, t) orelse return .none;
            return edit(id, .{ .estimate_minutes = .{ .set = m } });
        },
        .state, .workflow, .priority => unreachable,
    }
}

/// A typed date as an edit: empty clears it. Null, with a failure shown,
/// when it isn't one.
fn dateValue(s: *AppState, t: []const u8) ?issuez.engine.EditSpec.DateEdit {
    if (t.len == 0) return .clear;
    return .{ .set = dateOrFail(s, t) orelse return null };
}

/// A typed date; null, with a failure shown, when it isn't one.
fn dateOrFail(s: *AppState, t: []const u8) ?Date {
    return dates.parse(t, s.today, s.snap.settings.work_days) orelse {
        s.fail("'{s}' isn't a date like 2026-12-31, +3d or fri", .{t});
        return null;
    };
}

/// A typed duration in minutes; null, with a failure shown, when it
/// isn't one.
fn durationOrFail(s: *AppState, t: []const u8) ?u32 {
    return fields_fmt.parseDuration(t) orelse {
        s.fail("'{s}' isn't a duration like 90m, 2h or 1h30m", .{t});
        return null;
    };
}

fn splitLabels(a: Allocator, t: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, t, ',');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t");
        if (l.len > 0) try out.append(a, l);
    }
    return out.items;
}

/// An issue's full ID from a prefix, or a failure in the status line. In
/// the modal arena: the action outlives the snapshot its write replaces.
fn resolve(s: *AppState, prefix: []const u8) ?[]const u8 {
    const p = std.mem.trimStart(u8, prefix, "#");
    switch (s.snap.resolve(p)) {
        .one => |i| return s.modalArena().dupe(u8, s.snap.issues[i].id) catch {
            s.fail("out of memory", .{});
            return null;
        },
        .none => s.fail("no issue '{s}'", .{p}),
        .many => s.fail("'{s}' matches more than one issue; give more of the ID", .{p}),
    }
    return null;
}

// Drawing.

fn buttons(f: ui.Frame, win: ui.Window, row: u16, ok: []const u8) Allocator.Error!void {
    const ow = win.gwidth(ok) + 2;
    const cancel = "Cancel  esc";
    const cw = win.gwidth(cancel) + 2;
    var x = win.width -| (ow + cw + 1);
    x += try ui.button(f, win, x, row, cancel, .{ .modal = .cancel }, ui.buttonStyle(false));
    x += 1;
    _ = try ui.button(f, win, x, row, ok, .{ .modal = .ok }, ui.buttonStyle(true));
}

fn drawPrompt(s: *AppState, f: ui.Frame, win: ui.Window, p: *Prompt) Allocator.Error!void {
    const box = ui.centered(win, 72, 7);
    const inner = ui.panel(box, p.title, .{ .bg = palette.panel_bg });
    const input = inner.child(.{ .x_off = 1, .y_off = 1, .width = inner.width -| 2, .height = 1 });
    try p.input.draw(f.arena, input, .{ .bg = palette.input_bg }, true, "");
    try f.hit(input, .{ .modal = .{ .field = 0 } });
    const typed = std.mem.trim(u8, p.input.text(), " \t");
    const bg = palette.panel_bg;
    const note: []const u8, const style: ui.Style = if (!p.date or typed.len == 0)
        .{ p.hint, .{ .fg = palette.muted, .bg = bg, .italic = true } }
    else if (dates.parse(typed, s.today, s.snap.settings.work_days)) |d|
        .{ f.fmt("→ {f}, {s}", .{ d, d.weekday().short() }), .{ .fg = palette.ok, .bg = bg } }
    else
        .{ "not a date yet", .{ .fg = palette.err, .bg = bg, .italic = true } };
    _ = ui.text(inner, 1, 2, note, style);
    try buttons(f, inner, inner.height -| 1, "Save  ⏎");
}

fn drawEditor(f: ui.Frame, win: ui.Window, e: *Editor) Allocator.Error!void {
    const box = ui.centered(win, 100, win.height -| 4);
    const inner = ui.panel(box, e.title, .{ .bg = palette.panel_bg });
    const input = inner.child(
        .{ .x_off = 1, .y_off = 1, .width = inner.width -| 2, .height = inner.height -| 3 },
    );
    try e.input.draw(
        f.arena,
        input,
        .{ .bg = palette.input_bg },
        true,
        "Write here. Enter starts a new line.",
    );
    try f.hit(input, .{ .modal = .{ .field = 0 } });
    try buttons(f, inner, inner.height -| 1, "Save  ctrl+s");
}

fn drawMenu(f: ui.Frame, win: ui.Window, m: *Menu) Allocator.Error!void {
    var w: u16 = @intCast(@min(win.gwidth(m.title) + 6, 60));
    for (m.options) |o| w = @max(w, @as(u16, @intCast(@min(win.gwidth(o.label) + 8, 60))));
    const h: u16 = @intCast(@min(m.options.len + 2, win.height -| 2));
    const box = ui.centered(win, w, h);
    const inner = ui.panel(box, m.title, .{ .bg = palette.panel_bg });
    const rows = inner.height;
    if (m.selected < m.scroll) m.scroll = m.selected;
    if (m.selected >= m.scroll + rows) m.scroll = m.selected - rows + 1;
    var y: u16 = 0;
    while (y < rows and m.scroll + y < m.options.len) : (y += 1) {
        const n = m.scroll + y;
        const o = m.options[n];
        const row = inner.child(.{ .y_off = y, .height = 1 });
        const sel = n == m.selected;
        const bg: vaxis.Color = if (sel) palette.accent_bg else palette.panel_bg;
        row.fill(.{ .style = .{ .bg = bg } });
        _ = ui.text(row, 1, 0, if (o.current) "●" else " ", .{ .fg = palette.accent, .bg = bg });
        _ = ui.text(
            row,
            3,
            0,
            o.label,
            .{
                .bg = bg,
                .bold = sel and !o.disabled,
                .italic = o.other,
                .fg = if (o.disabled) palette.faint else .default,
            },
        );
        try f.hit(row, .{ .modal = .{ .choice = n } });
    }
}

fn syncPanelKey(s: *AppState, p: *SyncPanel, k: vaxis.Key) Action {
    if (k.matches(K.escape, .{}) or k.matches('q', .{}) or k.matches('Y', .{})) {
        s.closeModal();
        return .none;
    }
    if (k.matches(K.down, .{}) or k.matches('j', .{}) or k.matches(K.tab, .{})) {
        p.step(1);
    } else if (k.matches(
        K.up,
        .{},
    ) or k.matches('k', .{}) or k.matches(K.tab, .{ .shift = true })) {
        p.step(-1);
    } else if (k.matches(K.enter, .{})) {
        return syncPanelOpen(s, p);
    } else if (k.matches('y', .{})) {
        return .{ .sync = .sync };
    } else if (k.matches('f', .{})) {
        return .{ .sync = .merge };
    } else if (k.matches('p', .{})) {
        return .{ .sync = .push };
    } else if (k.matches(K.left, .{}) or k.matches(K.right, .{})) {
        return nextRemote(s, p, if (k.matches(K.left, .{})) -1 else 1);
    } else if (k.matches('a', .{}) or k.matches('l', .{})) {
        if (p.selected >= p.rows.len) return .none;
        const row = p.rows[p.selected];
        if (row != .quarantined) return s.noted("select a quarantined issue first", .{});
        const q = row.quarantined;
        const accept = k.matches('a', .{});
        const lines: []const []const u8 = if (accept) &.{
            "The remote's version replaces yours here.",
            "Yours is kept in refs/issuez-sync/<remote>/replaced/, nothing is lost.",
        } else &.{
            "Yours stays. A rewritten remote becomes the new baseline, so the",
            "next sync pushes yours; other refusals stop being reported.",
        };
        openConfirm(s, s.fmtInput(
            "{s} {s}?",
            .{
                if (accept) "Accept the remote version of" else "Keep the local version of",
                q.label,
            },
        ), lines, &.{
            .{
                .label = if (accept) "Accept remote" else "Keep local",
                .action = .{
                    .resolve = .{ .id = q.id, .how = if (accept) .accept_remote else .keep_local },
                },
            },
            .{ .label = "Cancel", .action = .open_sync_panel },
        });
    }
    return .none;
}

fn nextRemote(s: *AppState, p: *SyncPanel, by: i32) Action {
    const names = s.snap.remote.remotes;
    if (names.len < 2) return .none;
    var at: usize = 0;
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, p.remote)) {
        at = i;
    };
    const next: usize = @intCast(@mod(@as(i64, @intCast(at)) + by, @as(i64, @intCast(names.len))));
    return .{ .choose_remote = dupe(s, names[next]) };
}

/// Enter on a row: the issue it is about.
fn syncPanelOpen(s: *AppState, p: *SyncPanel) Action {
    if (p.selected >= p.rows.len) return .none;
    const id: Id, const field: ?Field = switch (p.rows[p.selected]) {
        .unpushed => |u| if (u.milestone) return .none else .{ u.id, null },
        .quarantined => |q| if (!q.local) {
            return s.noted("only on the remote: accept it (a) to see it here", .{});
        } else if (q.milestone) {
            if (s.snap.findMilestone(q.id.slice()) == null) return .none;
            s.closeModal();
            s.openMilestone(.{ .id = q.id });
            return .none;
        } else .{ q.id, null },
        .conflict => |c| .{ c.id, c.field },
        .heading, .empty => return .none,
    };
    if (s.snap.find(id.slice()) == null) return .none;
    s.closeModal();
    s.openIssue(id.slice());
    // Not when the timeline's draft held the user back.
    if (s.view != .detail) return .none;
    if (field) |fl| @import("detail_view.zig").focusField(s, fl);
    return .none;
}

fn drawSyncPanel(s: *AppState, f: ui.Frame, win: ui.Window, p: *SyncPanel) Allocator.Error!void {
    const box = ui.centered(win, @min(win.width -| 4, 104), win.height -| 2);
    const inner = ui.panel(box, "Sync", .{ .bg = palette.panel_bg });
    const bg = palette.panel_bg;
    const mt: ui.Style = .{ .fg = palette.muted, .bg = bg };
    // The remote, and the last sync.
    var l: ui.Line = .{ .f = f, .win = inner, .x = 1 };
    const off = ui.buttonStyle(false);
    const choose = s.snap.remote.remotes.len > 1;
    l.text("Remote ", mt);
    if (choose) try l.button("◂", .option(0, 0), off);
    l.x += 1;
    l.word(p.remote, .{ .fg = palette.accent, .bg = bg, .bold = true });
    if (choose) try l.button("▸", .option(0, 1), off);
    l.x += 2;
    l.text(p.url, mt);
    const last = if (s.sync.running) |kind|
        f.fmt(
            "{s} running: {s}…",
            .{ kind.label(), if (s.sync.phase) |ph| @tagName(ph) else "starting" },
        )
    else if (s.sync.last) |*synced| blk: {
        var buf: [512]u8 = undefined;
        break :blk f.fmt(
            "{s}, {s}",
            .{ @import("sync_job.zig").report(&buf, synced), ui.ago(f, s.sync.last_at) },
        );
    } else "not synced in this session";
    _ = ui.text(inner, 1, 1, "Last   ", mt);
    _ = ui.text(
        inner,
        8,
        1,
        last,
        .{
            .fg = if (s.sync.last != null and !s.sync.last.?.ok) palette.err else .default,
            .bg = bg,
        },
    );
    if (p.problem.len > 0) _ = ui.text(inner, 8, 2, p.problem, .{ .fg = palette.err, .bg = bg });

    const rows_h: u16 = inner.height -| 5;
    ui.keepInView(&p.scroll, p.selected, rows_h);
    var y: u16 = 0;
    while (y < rows_h and p.scroll + y < p.rows.len) : (y += 1) {
        const n = p.scroll + y;
        const row = inner.child(.{ .y_off = 3 + y, .height = 1 });
        const sel = n == p.selected;
        const rbg: vaxis.Color = if (sel) palette.accent_bg else bg;
        if (sel) row.fill(.{ .style = .{ .bg = rbg } });
        switch (p.rows[n]) {
            .heading => |h| _ = ui.text(
                row,
                1,
                0,
                h,
                .{ .fg = palette.accent, .bg = bg, .bold = true },
            ),
            .empty => |e| _ = ui.text(
                row,
                3,
                0,
                e,
                .{ .fg = palette.faint, .bg = bg, .italic = true },
            ),
            .unpushed => |u| {
                _ = ui.text(row, 3, 0, u.label, .{ .bg = rbg, .bold = sel });
                const tag = if (u.new) "new" else "edited";
                _ = ui.text(row, row.width -| 8, 0, tag, .{ .fg = palette.muted, .bg = rbg });
            },
            .quarantined => |q| {
                var cells: ui.Line = .{ .f = f, .win = row, .x = 3 };
                const fg = if (q.kept) palette.muted else vaxis.Color.default;
                cells.text(q.label, .{ .bg = rbg, .bold = sel, .fg = fg });
                cells.x += 2;
                cells.text(
                    if (q.kept) f.fmt("{s} · kept local", .{q.reason}) else q.reason,
                    .{ .fg = if (q.kept) palette.faint else palette.err, .bg = rbg },
                );
            },
            .conflict => |c| {
                var cells: ui.Line = .{ .f = f, .win = row, .x = 3 };
                cells.text(c.label, .{ .bg = rbg, .bold = sel });
                cells.x += 2;
                cells.text(c.what, .{ .fg = palette.medium, .bg = rbg });
            },
        }
        try f.hit(row, .{ .modal = .{ .choice = @intCast(n) } });
    }
    // Actions.
    const bar = inner.height -| 1;
    var acts: ui.Line = .{ .f = f, .win = inner, .x = 1, .y = bar };
    for ([_][]const u8{ "Sync  y", "Fetch & merge  f", "Push  p" }, 0..) |label, i| {
        try acts.button(label, .option(1, @intCast(i)), ui.buttonStyle(i == 0));
        acts.x += 1;
    }
    const close = "Close  esc";
    _ = try ui.button(
        f,
        inner,
        inner.width -| (inner.gwidth(close) + 3),
        bar,
        close,
        .{ .modal = .cancel },
        off,
    );
}

fn pickerSubmit(s: *AppState, p: *Picker) Action {
    const a = s.modalArena();
    const shown = p.shown(s.input_arena.allocator()) catch return .none;
    // The marked ones, else the highlighted one.
    var values: std.ArrayList([]const u8) = .empty;
    for (p.items) |it| if (it.marked) values.append(a, it.value) catch {};
    if (values.items.len == 0) {
        if (p.selected >= shown.len) return s.noted("nothing matches", .{});
        const it = p.items[shown[p.selected]];
        if (it.disabled) return s.failed("{s}: reopen it first to add open work", .{it.label});
        if (it.current and !p.multi) return unchanged(s);
        values.append(a, it.value) catch {};
    }
    const mv = @import("milestone_view.zig");
    switch (p.purpose) {
        .move => |ids| return mv.requestMove(s, ids, linkOf(values.items[0])),
        .add_to => |scope| {
            const ids = a.alloc(Id, values.items.len) catch return .none;
            for (ids, values.items) |*id, v| id.* = .of(v);
            return mv.requestMove(s, ids, switch (scope) {
                .none => .none,
                .id => |m| .{ .id = dupe(s, m.slice()) },
            });
        },
        .adopt => |parent| {
            const ids = a.alloc(Id, values.items.len) catch return .none;
            for (ids, values.items) |*id, v| id.* = .of(v);
            return .{ .adopt = .{ .parent = parent, .ids = ids } };
        },
        else => return .none,
    }
}

fn drawPicker(f: ui.Frame, win: ui.Window, p: *Picker) Allocator.Error!void {
    const shown = try p.shown(f.arena);
    if (shown.len > 0) p.selected = @min(
        p.selected,
        @as(u32, @intCast(shown.len - 1)),
    ) else p.selected = 0;
    const box = ui.centered(
        win,
        @min(win.width -| 4, 100),
        @min(win.height -| 2, @as(u16, @intCast(@min(p.items.len, 18))) + 6),
    );
    const inner = ui.panel(box, p.title, .{ .bg = palette.panel_bg });
    const bg = palette.panel_bg;
    _ = ui.text(inner, 1, 0, "/", .{ .fg = palette.accent, .bg = bg });
    const input = inner.child(.{ .x_off = 3, .y_off = 0, .width = inner.width -| 4, .height = 1 });
    try p.filter.draw(
        f.arena,
        input,
        .{ .bg = palette.input_bg },
        true,
        "type to filter: words in the title, an ID, a milestone",
    );
    try f.hit(input, .{ .modal = .{ .field = 0 } });
    const rows: u16 = inner.height -| 3;
    ui.keepInView(&p.scroll, p.selected, rows);
    var y: u16 = 0;
    while (y < rows and p.scroll + y < shown.len) : (y += 1) {
        const n = p.scroll + y;
        const it = p.items[shown[n]];
        const row = inner.child(.{ .y_off = y + 1, .height = 1 });
        const sel = n == p.selected;
        const rbg: vaxis.Color =
            if (sel) palette.accent_bg else if (it.marked) palette.mark_bg else bg;
        row.fill(.{ .style = .{ .bg = rbg } });
        _ = ui.text(
            row,
            1,
            0,
            if (it.marked) "✓" else if (it.current) "●" else " ",
            .{ .fg = if (it.marked) palette.ok else palette.accent, .bg = rbg },
        );
        const fg: vaxis.Color =
            if (it.disabled) palette.faint else if (it.done) palette.muted else .default;
        const lw = ui.text(
            row,
            3,
            0,
            it.label,
            .{ .fg = fg, .bg = rbg, .bold = sel and !it.disabled, .strikethrough = it.done },
        );
        if (it.detail.len > 0) {
            const dw = row.gwidth(it.detail);
            const dx = @max(3 + lw + 2, row.width -| (dw + 1));
            _ = ui.text(row, dx, 0, it.detail, .{ .fg = palette.muted, .bg = rbg });
        }
        try f.hit(row, .{ .modal = .{ .choice = @intCast(n) } });
    }
    if (shown.len == 0) _ = ui.text(
        inner,
        3,
        1,
        "nothing matches",
        .{ .fg = palette.muted, .bg = bg, .italic = true },
    );
    const marked = p.marked();
    const count = if (marked > 0)
        f.fmt("{d} of {d} · {d} marked", .{ shown.len, p.items.len, marked })
    else if (p.multi)
        f.fmt("{d} of {d} · tab marks several", .{ shown.len, p.items.len })
    else
        f.fmt("{d} of {d}", .{ shown.len, p.items.len });
    _ = ui.text(inner, 1, inner.height -| 1, count, .{ .fg = palette.muted, .bg = bg });
    const ok = if (marked > 0) f.fmt(
        "{s} {d}  ⏎",
        .{ p.verb, marked },
    ) else f.fmt("{s}  ⏎", .{p.verb});
    try buttons(f, inner, inner.height -| 1, ok);
}

fn drawConfirm(f: ui.Frame, win: ui.Window, c: *Confirm) Allocator.Error!void {
    var w: u16 = @intCast(@min(win.gwidth(c.title) + 6, 76));
    for (c.lines) |l| w = @max(w, @as(u16, @intCast(@min(win.gwidth(l) + 4, 76))));
    var bw: u16 = 0;
    for (c.choices) |ch| bw += win.gwidth(ch.label) + 3;
    w = @max(w, @min(bw + 4, 76));
    const box = ui.centered(win, w, @intCast(@min(c.lines.len + 5, win.height)));
    const inner = ui.panel(box, c.title, .{ .bg = palette.panel_bg });
    for (c.lines, 0..) |l, y| _ = ui.text(
        inner,
        1,
        @intCast(y + 1),
        l,
        .{ .bg = palette.panel_bg },
    );
    var l: ui.Line = .{ .f = f, .win = inner, .x = inner.width -| bw, .y = inner.height -| 1 };
    for (c.choices, 0..) |ch, n| {
        const target: ui.Target = .{ .modal = .{ .choice = @intCast(n) } };
        try l.button(ch.label, target, ui.buttonStyle(n == c.selected));
        l.x += 1;
    }
}

/// The question, with its texts copied into the modal arena. Keeps the
/// arena, where the answers' actions may have their strings: an open
/// dialog it replaces doesn't take them along.
pub fn openConfirm(
    s: *AppState,
    title: []const u8,
    lines: []const []const u8,
    choices: []const Confirm.Choice,
) void {
    const a = s.modalArena();
    const ls = a.alloc([]const u8, lines.len) catch return s.fail("out of memory", .{});
    for (ls, lines) |*o, l| o.* = dupe(s, l);
    const cs = a.alloc(Confirm.Choice, choices.len) catch return s.fail("out of memory", .{});
    for (cs, choices) |*o, ch| o.* = .{ .label = dupe(s, ch.label), .action = ch.action };
    s.openModal(.{ .confirm = .{ .title = dupe(s, title), .lines = ls, .choices = cs } });
}

/// `!` while the star notice shows: its buttons, with the keys.
pub fn openStar(s: *AppState) void {
    openConfirm(s, "Star git issue on GitHub", &.{
        if (s.star.gh) "One click stars it, with gh." else "Opens " ++ star.url ++ ".",
        "Later asks again in a month; Never stops asking.",
    }, &.{
        .{ .label = "Star it", .action = .{ .star = .star } },
        .{ .label = "Later", .action = .{ .star = .later } },
        .{ .label = "Never", .action = .{ .star = .never } },
    });
}

// Milestone dialogs.

/// The milestones view's sort keys; choosing the current one flips.
pub fn openMilestoneSort(s: *AppState) void {
    openSortMenu(
        s,
        milestone_filter.SortKey,
        s.ms_query.key,
        "Sort milestones by",
        .milestone_sort,
    );
}

/// Renaming a milestone, or setting its due date: by catalog position.
pub fn editMilestonePart(
    s: *AppState,
    n: u32,
    what: @FieldType(Purpose.MilestonePart, "what"),
) void {
    const m = s.snap.milestones[n];
    const purpose: Purpose = .{ .milestone = .{ .id = .of(m.id), .tip = m.tip, .what = what } };
    switch (what) {
        .name => openPrompt(
            s,
            s.fmtInput("Rename milestone {s}", .{m.name}),
            "one line, at most 256 bytes",
            m.name,
            purpose,
            false,
        ),
        .due => {
            const value = if (m.due) |d| print(s, "{f}", .{d}) else "";
            openPrompt(
                s,
                s.fmtInput("Due date of {s}", .{m.name}),
                dates.hint,
                value,
                purpose,
                false,
            );
            s.modal.?.prompt.date = true;
        },
    }
}

pub fn newMilestone(s: *AppState) void {
    s.closeModal();
    s.openModal(.{ .milestone_form = .{} });
}

pub fn editMilestone(s: *AppState, n: u32) void {
    const m = s.snap.milestones[n];
    s.closeModal();
    var f: MilestoneForm = .{ .editing = .{
        .id = .of(m.id),
        .tip = m.tip,
        .name = dupe(s, m.name),
        .due = if (m.due) |d| print(s, "{f}", .{d}) else "",
        .description = dupe(s, m.description),
    } };
    f.name.set(s.gpa, m.name) catch {};
    f.due.set(s.gpa, f.editing.?.due) catch {};
    f.description.set(s.gpa, m.description) catch {};
    s.openModal(.{ .milestone_form = f });
}

/// Creating or editing a milestone: name, due date, description.
pub const MilestoneForm = struct {
    name: TextArea = .init(false),
    due: TextArea = .init(false),
    description: TextArea = .init(true),
    focus: u8 = 0,
    /// The milestone edited, with what it had; null creates one.
    editing: ?Editing = null,

    pub const Editing = struct {
        id: Id,
        tip: issuez.engine.Oid,
        name: []const u8,
        due: []const u8,
        description: []const u8,
    };

    const labels = [_][]const u8{ "Name", "Due", "Description" };
    const description_rows = 5;

    pub fn deinit(f: *MilestoneForm, gpa: Allocator) void {
        f.name.deinit(gpa);
        f.due.deinit(gpa);
        f.description.deinit(gpa);
    }

    pub fn textArea(f: *MilestoneForm, n: u8) *TextArea {
        return switch (n) {
            0 => &f.name,
            1 => &f.due,
            else => &f.description,
        };
    }

    fn changed(f: *const MilestoneForm) bool {
        const e = f.editing orelse return f.name.text().len > 0 or f.due.text().len > 0 or
            f.description.text().len > 0;
        return !std.mem.eql(u8, f.name.text(), e.name) or !std.mem.eql(u8, f.due.text(), e.due) or
            !std.mem.eql(u8, f.description.text(), e.description);
    }

    fn key(f: *MilestoneForm, s: *AppState, k: vaxis.Key, save: bool) Allocator.Error!Action {
        if (save) return f.submit(s);
        if (k.matches(K.escape, .{})) {
            closeOrAsk(s, f.changed(), "press esc again to discard this milestone", .{});
            return .none;
        }
        s.discard_armed = false;
        const multiline = f.focus == 2;
        if (k.matches(K.tab, .{}) or (!multiline and k.matches(K.down, .{}))) {
            f.focus = (f.focus + 1) % 3;
            return .none;
        }
        if (k.matches(K.tab, .{ .shift = true }) or (!multiline and k.matches(K.up, .{}))) {
            f.focus = (f.focus + 2) % 3;
            return .none;
        }
        // Enter saves from a one-line field: name, Enter is a milestone.
        if (k.matches(K.enter, .{}) and !multiline) return f.submit(s);
        _ = try f.textArea(f.focus).key(s.gpa, s.input_arena.allocator(), k);
        return .none;
    }

    fn submit(f: *MilestoneForm, s: *AppState) Action {
        const name = std.mem.trim(u8, f.name.text(), " \t");
        if (!validName(s, name)) {
            f.focus = 0;
            return .none;
        }
        const due_text = std.mem.trim(u8, f.due.text(), " \t");
        const due = dateValue(s, due_text) orelse {
            f.focus = 1;
            return .none;
        };
        const description = std.mem.trimEnd(u8, f.description.text(), " \n");
        const e = f.editing orelse return .{ .create_milestone = .{
            .name = name,
            .due = if (due == .set) due.set else null,
            .description = description,
        } };
        var edit: store.MilestoneEdit = .{ .expect = e.tip };
        if (!std.mem.eql(u8, name, e.name)) edit.name = name;
        const was = Date.parse(e.due);
        const same_due = switch (due) {
            .clear => was == null,
            .set => |d| was != null and was.?.eql(d),
        };
        if (!same_due) edit.due = due;
        if (!std.mem.eql(
            u8,
            description,
            std.mem.trimEnd(u8, e.description, " \n"),
        )) edit.description = description;
        if (edit.name == null and edit.due == null and edit.description == null) return unchanged(
            s,
        );
        return .{ .edit_milestone = .{ .id = e.id, .edit = edit } };
    }

    fn draw(f: *MilestoneForm, s: *AppState, fr: ui.Frame, win: ui.Window) Allocator.Error!void {
        const h: u16 = description_rows + 9;
        const box = ui.centered(win, 80, h);
        const title = if (f.editing) |e| fr.fmt(
            "Edit milestone {s}",
            .{e.name},
        ) else "New milestone";
        const inner = ui.panel(box, title, .{ .bg = palette.panel_bg });
        const label_w: u16 = 13;
        const bg = palette.panel_bg;
        var y: u16 = 1;
        for (labels, 0..) |name, idx| {
            const n: u8 = @intCast(idx);
            const focused = f.focus == n;
            const rows: u16 = if (n == 2) description_rows else 1;
            _ = ui.text(
                inner,
                1,
                y,
                name,
                .{
                    .fg = if (focused) palette.accent else palette.muted,
                    .bg = bg,
                    .bold = focused,
                },
            );
            try fr.hit(
                inner.child(.{ .x_off = 1, .y_off = y, .width = label_w - 1, .height = 1 }),
                .{ .modal = .{ .field = n } },
            );
            const field_win = inner.child(
                .{
                    .x_off = label_w,
                    .y_off = y,
                    .width = inner.width -| label_w -| 1,
                    .height = rows,
                },
            );
            const placeholder: []const u8 = switch (n) {
                0 => "e.g. v1.0",
                1 => "optional: 2026-12-01, +2w, fri, eom",
                else => "What it is for (optional)",
            };
            const ta = f.textArea(n);
            try ta.draw(
                fr.arena,
                field_win,
                .{ .bg = if (focused) palette.input_bg else palette.select_bg },
                focused,
                placeholder,
            );
            try fr.hit(field_win, .{ .modal = .{ .field = n } });
            if (n == 1) {
                // The date it will be, as typed.
                const typed = std.mem.trim(u8, ta.text(), " \t");
                if (typed.len > 0) {
                    const parsed = dates.parse(typed, s.today, s.snap.settings.work_days);
                    const note = if (parsed) |d|
                        fr.fmt("→ {f}, {s}", .{ d, d.weekday().short() })
                    else
                        "not a date yet";
                    const fg = if (parsed != null) palette.ok else palette.err;
                    _ = ui.text(inner, label_w, y + 1, note, .{ .fg = fg, .bg = bg });
                }
                y += 1;
            }
            y += rows + 1;
        }
        try buttons(
            fr,
            inner,
            inner.height -| 1,
            if (f.editing != null) "Save  ctrl+s" else "Create  ⏎",
        );
    }
};

const help_lines = [_][]const u8{
    "Everywhere",
    "  1 2 3 4 / tab   list, board, milestones, timeline",
    "  n               new issue",
    "  /               filter                s / S    sort by… / reverse",
    "  f               open, done, all       ctrl+r   reload",
    "  M               milestones            p        sync with the remote",
    "  ?               this help             q        quit (back in an issue)",
    "  !               star git issue on GitHub, while the status bar asks",
    "  in menus a letter jumps to an option; j k q still move and close",
    "",
    "List and board",
    "  ↑↓ j k          move                  ⏎        open",
    "  a               new sub-issue         x        close / reopen",
    "  t               tree (list)           < >      move card (board)",
    "  ←→ h l          column (board)        g G      first / last",
    "",
    "Issue",
    "  ↑↓ j k tab      select a part         ⏎ space  edit or open it",
    "  t title  e description  c comment  x close/reopen",
    "  a new sub-issue  A add existing issues as sub-issues",
    "  s state  w workflow  p priority  u assignee  l labels  m milestone",
    "  P parent  b blocked by  S start  d due  E estimate  o go to parent",
    "  esc ← h         back",
    "",
    "Milestones",
    "  ⏎               its issues            n        new milestone",
    "  e edit  r rename  d due date  c complete  R retire  o reopen",
    "  s / S  sort / reverse   f  open, completed, retired, all",
    "  w               progress bars show work in progress too",
    "",
    "A milestone's issues",
    "  +               add existing issues   m        move to… (type to search)",
    "  [ ]             previous / next milestone",
    "  space * u       mark / all / unmark   n N      new here / quick add",
    "  v               split: a second pane  p        pick its milestone",
    "  tab             other pane            > <      move across",
    "  esc             back                  drag rows between the panes",
    "",
    "Timeline",
    "  ←→ h l ( )      scroll in time        shift / H L  a screen",
    "  z Z             zoom in / out         .        today",
    "  ↑↓ j k          rows                  [ ]      previous / next group",
    "  space           fold a group          ⏎        open the issue or milestone",
    "  D               blocker lines: selected, all, off    v  grouping",
    "  ◀ ▶ in the gutter: what the selected issue waits for / blocks; ⚠ doesn't fit",
    "",
    "Sync with the remote (the ⇅ badge: ↑ unpushed, ! quarantined, ✕ in conflict)",
    "  y               sync now: fetch, merge, push, in the background",
    "  Y               the sync panel: what's unpushed, quarantined (a accept remote,",
    "                  l keep local) and in conflict (⏎ opens the field); f fetch only,",
    "                  p push only, ←→ another remote",
    "  git config issue.remote <name> picks it; issue.autoSync <minutes> fetches",
    "  and merges on its own (never pushes)",
    "",
    "Timeline edit mode (E): nothing is written until applied",
    "  ←→ h l          move the bar a day    shift / H L  a week",
    "  < >  { }        due date / start      d s e    type due, start, estimate",
    "  alt+←→ alt+b f  start a day           ( ) ctrl+←→  scroll in time",
    "  ⏎               schedule from today   m        milestone",
    "  b               link a blocker        B        unlink one",
    "  n a x           refused: they write at once; apply or leave first",
    "  u U             undo / redo           ctrl+s   apply all, or none",
    "  r X             keep / drop yours when it changed elsewhere",
    "  esc             leave, discarding after asking; drag bars and their ends",
    "",
    "Dates",
    "  2026-12-01  today  tomorrow  +3d  -1w  +2m  fri  eom  eow",
    "",
    "Mouse",
    "  click selects, double-click opens; click any field to edit it;",
    "  click column titles to sort; drag cards between board columns;",
    "  the wheel scrolls lists, columns, issues and text boxes.",
    "",
    "Filter",
    "  words match title, ID or label; label:x  @who  p:high  s:closed",
    "  w:review  m:1.0  parent:ID  is:blocked|child|root|parent|unassigned",
    "  is:conflict|problem|unpushed|quarantined; - negates: -label:wontfix",
    "  milestones: words, is:overdue|at-risk|on-track|empty|blocked,",
    "  has:due  no:due  due:<2026-12-31  due:>2026-11-01",
};

fn drawHelp(f: ui.Frame, win: ui.Window, h: *Help) Allocator.Error!void {
    const box = ui.centered(win, 78, @intCast(@min(help_lines.len + 2, win.height -| 2)));
    const inner = ui.panel(box, "Help", .{ .bg = palette.panel_bg });
    try f.hit(box, .{ .modal = .cancel });
    h.rows = inner.height;
    h.scroll = @min(h.scroll, @as(u16, @intCast(help_lines.len -| inner.height)));
    var y: u16 = 0;
    while (y < inner.height and h.scroll + y < help_lines.len) : (y += 1) {
        const line = help_lines[h.scroll + y];
        const heading = line.len > 0 and line[0] != ' ';
        _ = ui.text(
            inner,
            1,
            y,
            line,
            .{
                .bg = palette.panel_bg,
                .fg = if (heading) palette.accent else .default,
                .bold = heading,
            },
        );
    }
}

/// Creating an issue, or a sub-issue of `parent`.
pub const Form = struct {
    title: TextArea = .init(false),
    description: TextArea = .init(true),
    labels: TextArea = .init(false),
    assignee: TextArea = .init(false),
    parent: TextArea = .init(false),
    focus: u8 = 0,
    priority: u8 = 0,
    /// 0 is the default state.
    workflow: u8 = 0,
    workflow_states: []const []const u8,
    /// The parent it was opened for, to show its title.
    for_parent: ?[]const u8 = null,
    /// 0 is none (or the parent's, for a sub-issue), then open milestones.
    milestone: u8 = 0,
    milestone_ids: []const []const u8 = &.{},
    milestone_names: []const []const u8 = &.{},

    const fields = [_][]const u8{
        "Title",
        "Description",
        "Priority",
        "Workflow",
        "Labels",
        "Assignee",
        "Parent",
        "Milestone",
    };
    const milestone_field = 7;
    const priorities = [_][]const u8{ "none", "low", "medium", "high", "critical" };
    const description_rows = 6;

    pub fn init(s: *AppState, parent: ?u32) Allocator.Error!Form {
        const a = s.modalArena();
        var f: Form = .{ .workflow_states = try dupeAll(a, s.snap.settings.workflow_states) };
        var ids: std.ArrayList([]const u8) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        for (s.snap.milestones) |m| {
            if (m.status != .open or ids.items.len == 254) continue;
            try ids.append(a, try a.dupe(u8, m.id));
            try names.append(a, try a.dupe(u8, m.name));
        }
        f.milestone_ids = ids.items;
        f.milestone_names = names.items;
        // In a milestone's view, into that milestone; a sub-issue
        // inherits its parent's.
        if (s.view == .milestone and parent == null) {
            const scope = s.milestone.focusedScope();
            if (scope == .id) for (f.milestone_ids, 0..) |id, n| {
                if (scope.id.eql(id)) f.milestone = @intCast(n + 1);
            };
        }
        if (parent) |p| {
            const issue = s.snap.issues[p];
            try f.parent.set(s.gpa, shortId(issue.id));
            f.for_parent = try std.fmt.allocPrint(
                a,
                "#{s} {s}",
                .{ shortId(issue.id), issue.title },
            );
        }
        // On the board, in the selected column.
        if (s.view == .board) if (s.board.columns.len > s.board.column) {
            const col = s.board.columns[s.board.column];
            if (!col.done) for (f.workflow_states, 0..) |w, n| {
                if (std.mem.eql(u8, w, col.name)) f.workflow = @intCast(n + 1);
            };
        };
        return f;
    }

    fn dupeAll(a: Allocator, list: []const []const u8) Allocator.Error![]const []const u8 {
        const out = try a.alloc([]const u8, @min(list.len, 254));
        for (out, list[0..out.len]) |*o, v| o.* = try a.dupe(u8, v);
        return out;
    }

    pub fn deinit(f: *Form, gpa: Allocator) void {
        f.title.deinit(gpa);
        f.description.deinit(gpa);
        f.labels.deinit(gpa);
        f.assignee.deinit(gpa);
        f.parent.deinit(gpa);
    }

    pub fn textArea(f: *Form, n: u8) ?*TextArea {
        return switch (n) {
            0 => &f.title,
            1 => &f.description,
            4 => &f.labels,
            5 => &f.assignee,
            6 => &f.parent,
            else => null,
        };
    }

    fn optionCount(f: *const Form, n: u8) u8 {
        return switch (n) {
            2 => priorities.len,
            3 => @intCast(f.workflow_states.len + 1),
            milestone_field => @intCast(f.milestone_ids.len + 1),
            else => 0,
        };
    }

    pub fn setOption(f: *Form, n: u8, option: u8) void {
        if (option >= f.optionCount(n)) return;
        switch (n) {
            2 => f.priority = option,
            3 => f.workflow = option,
            milestone_field => f.milestone = option,
            else => {},
        }
    }

    fn hasText(f: *const Form) bool {
        return f.title.text().len > 0 or f.description.text().len > 0 or f.labels.text().len > 0 or
            f.assignee.text().len > 0;
    }

    fn key(f: *Form, s: *AppState, k: vaxis.Key, save: bool) Allocator.Error!Action {
        const gpa = s.gpa;
        const a = s.input_arena.allocator();
        if (save) return f.submit(s);
        if (k.matches(K.escape, .{})) {
            closeOrAsk(s, f.hasText(), "press esc again to discard this issue", .{});
            return .none;
        }
        s.discard_armed = false;
        const n = fields.len;
        const multiline = f.focus == 1;
        const next = k.matches(K.tab, .{}) or (!multiline and k.matches(K.down, .{}));
        const prev = k.matches(K.tab, .{ .shift = true }) or (!multiline and k.matches(K.up, .{}));
        if (next) {
            f.focus = @intCast((f.focus + 1) % n);
            return .none;
        }
        if (prev) {
            f.focus = @intCast((f.focus + n - 1) % n);
            return .none;
        }
        if (k.matches(K.enter, .{}) and !multiline) {
            // Enter on the last field creates; elsewhere it moves on.
            if (f.focus == n - 1) return f.submit(s);
            f.focus += 1;
            return .none;
        }
        if (f.textArea(f.focus)) |ta| {
            _ = try ta.key(gpa, a, k);
            return .none;
        }
        // An option field.
        const count = f.optionCount(f.focus);
        const cur = f.optionOf(f.focus);
        if (k.matches(K.left, .{}) or k.matches('h', .{})) {
            f.setOption(f.focus, if (cur == 0) count - 1 else cur - 1);
        } else if (k.matches(K.right, .{}) or k.matches('l', .{}) or k.matches(K.space, .{})) {
            f.setOption(f.focus, (cur + 1) % count);
        }
        return .none;
    }

    fn optionOf(f: *const Form, n: u8) u8 {
        return switch (n) {
            2 => f.priority,
            3 => f.workflow,
            else => f.milestone,
        };
    }

    fn submit(f: *Form, s: *AppState) Action {
        const a = s.modalArena();
        const title = std.mem.trim(u8, f.title.text(), " \t");
        if (title.len == 0) {
            f.focus = 0;
            return s.failed("an issue needs a title", .{});
        }
        const parent_text = std.mem.trim(u8, f.parent.text(), " \t");
        const parent: ?[]const u8 = if (parent_text.len == 0)
            null
        else
            resolve(s, parent_text) orelse {
                f.focus = 6;
                return .none;
            };
        const assignee = std.mem.trim(u8, f.assignee.text(), " \t");
        return .{ .create = .{
            .title = title,
            .body = std.mem.trimEnd(u8, f.description.text(), " \n"),
            .labels = splitLabels(a, f.labels.text()) catch &.{},
            .assignee = if (assignee.len == 0) null else assignee,
            .priority = if (f.priority == 0) null else core.Priority.parse(priorities[f.priority]),
            .workflow = if (f.workflow == 0) null else f.workflow_states[f.workflow - 1],
            .parent = parent,
            .milestone_id = if (f.milestone == 0) null else f.milestone_ids[f.milestone - 1],
        } };
    }

    fn draw(f: *Form, s: *AppState, fr: ui.Frame, win: ui.Window) Allocator.Error!void {
        _ = s;
        // On a short terminal the gaps go, then description rows.
        const roomy: u16 = 2 * fields.len + description_rows + 4;
        const gap: u16 = if (win.height >= roomy) 1 else 0;
        const desc_rows: u16 = if (gap == 1) description_rows else std.math.clamp(
            win.height -| @as(u16, fields.len + 4),
            1,
            description_rows,
        );
        const h: u16 = if (gap == 1) roomy else @as(u16, fields.len - 1) + desc_rows + 4;
        const box = ui.centered(win, 90, h);
        const title = if (f.for_parent) |p| fr.fmt("New sub-issue of {s}", .{p}) else "New issue";
        const inner = ui.panel(box, title, .{ .bg = palette.panel_bg });
        const label_w: u16 = 13;
        const bg = palette.panel_bg;
        var y: u16 = 1;
        for (fields, 0..) |name, idx| {
            const n: u8 = @intCast(idx);
            const focused = f.focus == n;
            const rows: u16 = if (n == 1) desc_rows else 1;
            const chosen: ui.Style = .{
                .fg = .{ .index = 231 },
                .bg = if (focused) palette.accent_bg else palette.button_bg,
                .bold = true,
            };
            _ = ui.text(
                inner,
                1,
                y,
                name,
                .{
                    .fg = if (focused) palette.accent else palette.muted,
                    .bg = bg,
                    .bold = focused,
                },
            );
            const label_win = inner.child(
                .{ .x_off = 1, .y_off = y, .width = label_w - 1, .height = 1 },
            );
            try fr.hit(label_win, .{ .modal = .{ .field = n } });
            const field_win = inner.child(
                .{
                    .x_off = label_w,
                    .y_off = y,
                    .width = inner.width -| label_w -| 1,
                    .height = rows,
                },
            );
            if (f.textArea(n)) |ta| {
                const placeholder: []const u8 = switch (n) {
                    0 => "What needs doing?",
                    1 => "Details, steps, context… (Enter for new lines)",
                    4 => "comma-separated, e.g. bug, ui",
                    5 => "an email",
                    6 => "an issue ID prefix, for a sub-issue",
                    else => "",
                };
                try ta.draw(
                    fr.arena,
                    field_win,
                    .{ .bg = if (focused) palette.input_bg else palette.select_bg },
                    focused,
                    placeholder,
                );
                try fr.hit(field_win, .{ .modal = .{ .field = n } });
            } else if (n == milestone_field) {
                // One at a time: there may be many.
                const lab = if (f.milestone == 0)
                    (if (f.parent.text().len > 0) "the parent's" else "none")
                else
                    f.milestone_names[f.milestone - 1];
                var l: ui.Line = .{ .f = fr, .win = field_win };
                const count = f.optionCount(n);
                const before = if (f.milestone == 0) count - 1 else f.milestone - 1;
                try l.button("◂", .option(n, before), ui.buttonStyle(false));
                l.x += 1;
                try l.button(lab, .{ .modal = .{ .field = n } }, chosen);
                l.x += 1;
                try l.button("▸", .option(n, (f.milestone + 1) % count), ui.buttonStyle(false));
                if (count == 1) {
                    l.x += 2;
                    l.text("no open milestones", .{ .fg = palette.faint, .bg = bg });
                }
            } else {
                var l: ui.Line = .{ .f = fr, .win = field_win };
                const count = f.optionCount(n);
                const cur = f.optionOf(n);
                var o: u8 = 0;
                while (o < count) : (o += 1) {
                    const lab = if (n == 2)
                        priorities[o]
                    else if (o == 0)
                        "default"
                    else
                        f.workflow_states[o - 1];
                    const st: ui.Style =
                        if (o == cur) chosen else .{ .fg = palette.muted, .bg = palette.select_bg };
                    if (l.x >= field_win.width) break;
                    try l.button(lab, .option(n, o), st);
                    l.x += 1;
                }
            }
            y += rows + gap;
            if (n == 1) y -= gap;
        }
        try buttons(fr, inner, inner.height -| 1, "Create  ctrl+s");
    }
};

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
const AppState = @import("State.zig");

const Id = store.Id;
const TextArea = text_mod.TextArea;
const Action = AppState.Action;
const K = vaxis.Key;
const palette = ui.palette;
const fields_fmt = issuez.format.fields;
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

    /// The issue whose fields the answer replaces, so its write expects
    /// the tip the dialog showed. A comment replaces nothing.
    pub fn issue(p: Purpose) ?Id {
        return switch (p) {
            .title, .description => |id| id,
            .field => |fp| fp.id,
            .comment, .sort => null,
        };
    }
};

pub const Prompt = struct {
    title: []const u8,
    hint: []const u8,
    input: TextArea = .init(false),
    /// The value it started with: saving that again writes nothing. Null
    /// when any answer is a change.
    original: ?[]const u8 = null,
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
    };
};

pub const Modal = union(enum) {
    prompt: Prompt,
    editor: Editor,
    menu: Menu,
    form: Form,
    help: u16,

    pub fn deinit(m: *Modal, gpa: Allocator) void {
        switch (m.*) {
            .prompt => |*p| p.input.deinit(gpa),
            .editor => |*e| e.input.deinit(gpa),
            .form => |*f| f.deinit(gpa),
            .menu, .help => {},
        }
    }

    pub fn issue(m: *const Modal) ?Id {
        return switch (m.*) {
            .prompt => |*p| p.purpose.issue(),
            .editor => |*e| e.purpose.issue(),
            .menu => |*mn| mn.purpose.issue(),
            .form, .help => null,
        };
    }

    /// Whether closing it loses something typed.
    pub fn unsaved(m: *const Modal) bool {
        return switch (m.*) {
            .prompt => |*p| !std.mem.eql(u8, p.input.text(), p.original orelse ""),
            .editor => |*e| !std.mem.eql(u8, e.input.text(), e.original),
            .form => |*f| f.hasText(),
            .menu, .help => false,
        };
    }

    pub fn hint(m: *const Modal) []const u8 {
        return switch (m.*) {
            .prompt => "⏎ save  esc cancel",
            .editor => "ctrl+s save  esc cancel  (⏎ new line)",
            .menu => "↑↓ choose  ⏎ select  esc cancel",
            .form => "tab/↑↓ next field  ←→ choose  ctrl+s create  esc cancel",
            .help => "any key or click to close",
        };
    }

    pub fn draw(m: *Modal, s: *AppState, f: ui.Frame, win: ui.Window) Allocator.Error!void {
        try f.hit(win, .backdrop);
        switch (m.*) {
            .prompt => |*p| try drawPrompt(f, win, p),
            .editor => |*e| try drawEditor(f, win, e),
            .menu => |*mn| try drawMenu(f, win, mn),
            .form => |*fm| try fm.draw(s, f, win),
            .help => |*scroll| try drawHelp(f, win, scroll),
        }
    }

    pub fn wheel(m: *Modal, s: *AppState, found: ?ui.Hits.Found, delta: i32) Allocator.Error!Action {
        _ = found;
        const a = s.input_arena.allocator();
        switch (m.*) {
            .editor => |*e| try e.input.scrollBy(a, delta),
            .form => |*fm| try fm.description.scrollBy(a, delta),
            .menu => |*mn| {
                const n: i32 = @intCast(mn.options.len);
                mn.selected = @intCast(std.math.clamp(@as(i32, mn.selected) + std.math.sign(delta), 0, n - 1));
            },
            .help => |*scroll| scroll.* = @intCast(std.math.clamp(@as(i32, scroll.*) + delta, 0, help_lines.len)),
            .prompt => {},
        }
        return .none;
    }

    pub fn click(m: *Modal, s: *AppState, h: ui.Hits.Found) Allocator.Error!Action {
        const a = s.input_arena.allocator();
        const t = switch (h.target) {
            .modal => |t| t,
            .backdrop => {
                switch (m.*) {
                    .menu, .help => s.closeModal(),
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
                    mn.selected = c;
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
                .prompt => |*p| p.input.clickLine(h.x),
                .editor => |*e| try e.input.click(a, h.y, h.x),
                else => {},
            },
            .option => |o| switch (m.*) {
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
fn openPrompt(s: *AppState, title: []const u8, hint: []const u8, value: []const u8, purpose: Purpose, fresh: bool) void {
    var input: TextArea = .init(false);
    input.set(s.gpa, value) catch {};
    const kept = s.modal_tip;
    s.closeModal();
    s.openModal(.{ .prompt = .{
        .title = dupe(s, title),
        .hint = dupe(s, hint),
        .original = if (fresh) null else dupe(s, input.text()),
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
    s.info("unchanged", .{});
    return .none;
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
    const id: Id = .of(issue.id);
    const purpose: Purpose = .{ .field = .{ .id = id, .field = field } };
    const a = s.modalArena();
    s.closeModal();
    switch (field) {
        .state, .workflow, .priority, .milestone => {
            var options: std.ArrayList(Menu.Option) = .empty;
            const cur: []const u8 = switch (field) {
                .state => issue.state.text(),
                .workflow => issue.ext.workflow orelse "",
                .priority => issue.field("Priority") orelse "",
                // An inherited milestone isn't the issue's own: choosing
                // it sets it.
                .milestone => if (issue.ext.milestone_id == null and snap.proj.milestone[i] != null)
                    "\x00"
                else
                    snap.milestoneName(i) orelse "",
                else => unreachable,
            };
            // Copied: the menu outlives a reload of the snapshot they're in.
            const add = struct {
                fn f(list: *std.ArrayList(Menu.Option), arena: Allocator, o: Menu.Option, current: []const u8) void {
                    var opt = o;
                    opt.current = !o.other and std.mem.eql(u8, o.value, current);
                    opt.label = arena.dupe(u8, o.label) catch return;
                    opt.value = arena.dupe(u8, o.value) catch return;
                    list.append(arena, opt) catch {};
                }
            }.f;
            switch (field) {
                .state => {
                    add(&options, a, .{ .label = "open", .value = "open" }, cur);
                    add(&options, a, .{ .label = "closed", .value = "closed" }, cur);
                    for (snap.settings.done_states) |d| add(&options, a, .{ .label = d, .value = d }, cur);
                    if (issue.state == .other and !issue.state.isDone(snap.settings.done_states)) {
                        add(&options, a, .{ .label = issue.state.text(), .value = issue.state.text() }, cur);
                    }
                },
                .workflow => {
                    for (snap.settings.workflow_states) |w| add(&options, a, .{ .label = w, .value = w }, cur);
                    add(&options, a, .{ .label = "(default)", .value = "" }, cur);
                },
                .priority => {
                    add(&options, a, .{ .label = "(none)", .value = "" }, cur);
                    for ([_][]const u8{ "low", "medium", "high", "critical" }) |p| add(&options, a, .{ .label = p, .value = p }, cur);
                },
                .milestone => {
                    for (snap.milestones) |m| {
                        if (m.status != .open) continue;
                        add(&options, a, .{ .label = m.name, .value = m.name }, cur);
                    }
                    add(&options, a, .{ .label = "(none)", .value = "" }, cur);
                    add(&options, a, .{ .label = "Other…", .value = "", .other = true }, cur);
                },
                else => unreachable,
            }
            var selected: u16 = 0;
            for (options.items, 0..) |o, n| if (o.current) {
                selected = @intCast(n);
            };
            s.openModal(.{ .menu = .{
                .title = print(s, "{s} of #{s}", .{ field.label(), shortId(issue.id) }),
                .options = options.items,
                .selected = selected,
                .purpose = purpose,
            } });
        },
        .assignee => openPrompt(s, "Assignee", "an email; empty unassigns", issue.field("Assignee") orelse "", purpose, false),
        .labels => {
            const joined = std.mem.join(a, ", ", issue.labels) catch "";
            openPrompt(s, "Labels", "comma-separated; empty removes all", joined, purpose, false);
        },
        .parent => {
            const p = snap.proj.parent[i];
            const value = if (p == std.math.maxInt(u32)) "" else shortId(snap.issues[p].id);
            openPrompt(s, "Parent", "an issue ID (prefix); empty makes it top-level", value, purpose, false);
        },
        .blocked_by => {
            var ids: std.ArrayList(u8) = .empty;
            for (issue.ext.blocked_by, 0..) |b, n| {
                if (n > 0) ids.append(a, ' ') catch {};
                ids.appendSlice(a, shortId(b)) catch {};
            }
            openPrompt(s, "Blocked by", "issue IDs (prefixes), space-separated; empty clears", ids.items, purpose, false);
        },
        .start, .due => {
            const d = if (field == .start) issue.ext.start_date else issue.ext.due_date;
            const value = if (d) |date| print(s, "{f}", .{date}) else "";
            openPrompt(s, field.label(), "YYYY-MM-DD; empty clears", value, purpose, false);
        },
        .estimate => {
            const value = if (issue.ext.estimate_minutes) |m| durationText(s, m) else "";
            openPrompt(s, "Estimate", "like 90m, 2h or 1h30m; empty clears", value, purpose, false);
        },
    }
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
    s.closeModal();
    const keys = std.enums.values(filter.SortKey);
    const options = s.modalArena().alloc(Menu.Option, keys.len) catch return s.fail("out of memory", .{});
    var selected: u16 = 0;
    for (keys, options, 0..) |k, *o, n| {
        const current = k == s.query.key;
        if (current) selected = @intCast(n);
        o.* = .{ .label = print(s, "{s:<9} {s}", .{ k.label(), k.order() }), .value = k.label(), .current = current };
    }
    s.openModal(.{ .menu = .{ .title = "Sort by", .options = options, .selected = selected, .purpose = .sort } });
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
        .help => s.closeModal(),
        .prompt => |*p| {
            if (k.matches(K.escape, .{})) {
                s.closeModal();
            } else if (k.matches(K.enter, .{})) {
                return submit(s);
            } else if (save) {
                return submit(s);
            } else {
                s.discard_armed = false;
                _ = try p.input.key(gpa, a, k);
            }
        },
        .editor => |*e| {
            if (k.matches(K.escape, .{})) {
                const changed = !std.mem.eql(u8, e.input.text(), e.original);
                if (changed and !s.discard_armed) {
                    s.discard_armed = true;
                    s.fail("unsaved text: press esc again to discard, ctrl+s to save", .{});
                } else s.closeModal();
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
            } else if (k.matches(K.up, .{}) or k.matches('k', .{}) or k.matches(K.tab, .{ .shift = true })) {
                mn.selected = @intCast(@mod(@as(i32, mn.selected) - 1, n));
            } else if (k.matches(K.enter, .{}) or k.matches(K.space, .{})) {
                return submit(s);
            } else if (k.text) |t| {
                // Jump to the next option starting with the letter.
                if (t.len == 1) {
                    var n_: usize = 1;
                    while (n_ <= mn.options.len) : (n_ += 1) {
                        const idx = (mn.selected + n_) % mn.options.len;
                        const lab = mn.options[idx].label;
                        if (lab.len > 0 and std.ascii.toLower(lab[0]) == std.ascii.toLower(t[0])) {
                            mn.selected = @intCast(idx);
                            break;
                        }
                    }
                }
            }
        },
        .form => |*fm| return fm.key(s, k, save),
    }
    return .none;
}

/// Pasted text goes into the focused text box, whatever it holds; menus,
/// the help and a form's option fields take none of it.
fn pasteKey(s: *AppState, m: *Modal, k: vaxis.Key) Allocator.Error!void {
    const ta: *TextArea = switch (m.*) {
        .prompt => |*p| &p.input,
        .editor => |*e| &e.input,
        .form => |*fm| fm.textArea(fm.focus) orelse return,
        .menu, .help => return,
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
        .form, .help => {},
    }
}

fn submit(s: *AppState) Action {
    const m = &s.modal.?;
    const a = s.modalArena();
    if (s.modalStale()) {
        const id = m.issue().?;
        s.rebaseModal();
        s.fail("#{s} changed meanwhile: save again to replace it with yours", .{shortId(id.slice())});
        return .none;
    }
    switch (m.*) {
        .help => return .none,
        .form => |*fm| return fm.submit(s),
        .editor => |*e| {
            const t = e.input.text();
            switch (e.purpose) {
                .description => |id| {
                    if (std.mem.eql(u8, t, e.original)) return unchanged(s);
                    return .{ .edit = .{ .id = id, .spec = .{ .description = t } } };
                },
                .comment => |id| {
                    if (std.mem.trim(u8, t, " \t\n").len == 0) {
                        s.fail("a comment needs some text", .{});
                        return .none;
                    }
                    return .{ .comment = .{ .id = id, .text = t } };
                },
                else => unreachable,
            }
        },
        .menu => |*mn| {
            const o = mn.options[mn.selected];
            if (mn.purpose == .sort) {
                const k = std.meta.stringToEnum(filter.SortKey, o.value).?;
                if (s.query.key == k) s.query.reverse = !s.query.reverse else {
                    s.query.key = k;
                    s.query.reverse = false;
                }
                s.closeModal();
                return .none;
            }
            const fp = mn.purpose.field;
            if (o.current) return unchanged(s);
            if (o.other) {
                openPrompt(s, "Milestone", "a milestone name, kept as text if no open milestone has it", "", mn.purpose, true);
                return .none;
            }
            return switch (fp.field) {
                .state => .{ .state = .{ .id = fp.id, .state = o.value } },
                .workflow => .{ .edit = .{ .id = fp.id, .spec = .{ .workflow = o.value } } },
                .priority => .{ .edit = .{ .id = fp.id, .spec = .{
                    .priority = if (core.Priority.parse(o.value)) |p| .{ .set = p } else .clear,
                } } },
                .milestone => .{ .milestone = .{ .id = fp.id, .name = o.value } },
                else => unreachable,
            };
        },
        .prompt => |*p| {
            const t = std.mem.trim(u8, p.input.text(), " \t");
            if (p.original) |o| if (std.mem.eql(u8, t, std.mem.trim(u8, o, " \t"))) return unchanged(s);
            switch (p.purpose) {
                .title => |id| {
                    if (t.len == 0) {
                        s.fail("the title can't be empty", .{});
                        return .none;
                    }
                    return .{ .edit = .{ .id = id, .spec = .{ .title = t } } };
                },
                .field => |fp| return fieldAction(s, a, fp.id, fp.field, t),
                else => unreachable,
            }
        },
    }
}

fn fieldAction(s: *AppState, a: Allocator, id: Id, field: Field, t: []const u8) Action {
    const edit = struct {
        fn f(i: Id, spec: issuez.engine.EditSpec) Action {
            return .{ .edit = .{ .id = i, .spec = spec } };
        }
    }.f;
    switch (field) {
        .assignee => return edit(id, .{ .assignee = t }),
        .labels => return edit(id, .{ .set_labels = splitLabels(a, t) catch return .none }),
        .milestone => return .{ .milestone = .{ .id = id, .name = t } },
        .parent => {
            if (t.len == 0) return edit(id, .{ .parent = "" });
            const p = resolve(s, t) orelse return .none;
            return edit(id, .{ .parent = p });
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
            if (t.len > 0 and fields_fmt.Date.parse(t) == null) {
                s.fail("'{s}' isn't a date like 2026-12-31", .{t});
                return .none;
            }
            return edit(id, if (field == .start) .{ .start_date = t } else .{ .due_date = t });
        },
        .estimate => {
            if (t.len == 0) return edit(id, .{ .estimate_minutes = .clear });
            const m = fields_fmt.parseDuration(t) orelse {
                s.fail("'{s}' isn't a duration like 90m, 2h or 1h30m", .{t});
                return .none;
            };
            return edit(id, .{ .estimate_minutes = .{ .set = m } });
        },
        .state, .workflow, .priority => unreachable,
    }
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

fn drawPrompt(f: ui.Frame, win: ui.Window, p: *Prompt) Allocator.Error!void {
    const box = ui.centered(win, 72, 7);
    const inner = ui.panel(box, p.title, .{ .bg = palette.panel_bg });
    const input = inner.child(.{ .x_off = 1, .y_off = 1, .width = inner.width -| 2, .height = 1 });
    try p.input.draw(f.arena, input, .{ .bg = palette.input_bg }, true, "");
    try f.hit(input, .{ .modal = .{ .field = 0 } });
    _ = ui.text(inner, 1, 2, p.hint, .{ .fg = palette.muted, .bg = palette.panel_bg, .italic = true });
    try buttons(f, inner, inner.height -| 1, "Save  ⏎");
}

fn drawEditor(f: ui.Frame, win: ui.Window, e: *Editor) Allocator.Error!void {
    const box = ui.centered(win, 100, win.height -| 4);
    const inner = ui.panel(box, e.title, .{ .bg = palette.panel_bg });
    const input = inner.child(.{ .x_off = 1, .y_off = 1, .width = inner.width -| 2, .height = inner.height -| 3 });
    try e.input.draw(f.arena, input, .{ .bg = palette.input_bg }, true, "Write here. Enter starts a new line.");
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
        _ = ui.text(row, 3, 0, o.label, .{ .bg = bg, .bold = sel, .italic = o.other });
        try f.hit(row, .{ .modal = .{ .choice = n } });
    }
}

const help_lines = [_][]const u8{
    "Everywhere",
    "  1 / 2 / tab     list / board          n        new issue",
    "  /               filter                s / S    sort by… / reverse",
    "  f               open, done, all       ctrl+r   reload",
    "  ?               this help             q        quit (back in an issue)",
    "",
    "List and board",
    "  ↑↓ j k          move                  ⏎        open",
    "  a               new sub-issue         x        close / reopen",
    "  t               tree (list)           < >      move card (board)",
    "  ←→ h l          column (board)        g G      first / last",
    "",
    "Issue",
    "  ↑↓ j k tab      select a part         ⏎ space  edit or open it",
    "  t title  e description  c comment  a sub-issue  x close/reopen",
    "  s state  w workflow  p priority  u assignee  l labels  m milestone",
    "  P parent  b blocked by  S start  d due  E estimate  o go to parent",
    "  esc ← h         back",
    "",
    "Mouse",
    "  click selects, double-click opens; click any field to edit it;",
    "  click column titles to sort; drag cards between board columns;",
    "  the wheel scrolls lists, columns, issues and text boxes.",
    "",
    "Filter",
    "  words match title, ID or label; label:x  @who  p:high  s:closed",
    "  w:review  m:1.0  parent:ID  is:blocked|child|root|parent|unassigned",
    "  is:conflict|problem; a leading - negates: -label:wontfix",
};

fn drawHelp(f: ui.Frame, win: ui.Window, scroll: *u16) Allocator.Error!void {
    const box = ui.centered(win, 78, @intCast(@min(help_lines.len + 2, win.height -| 2)));
    const inner = ui.panel(box, "Help", .{ .bg = palette.panel_bg });
    try f.hit(box, .{ .modal = .cancel });
    scroll.* = @min(scroll.*, @as(u16, @intCast(help_lines.len -| inner.height)));
    var y: u16 = 0;
    while (y < inner.height and scroll.* + y < help_lines.len) : (y += 1) {
        const line = help_lines[scroll.* + y];
        const heading = line.len > 0 and line[0] != ' ';
        _ = ui.text(inner, 1, y, line, .{ .bg = palette.panel_bg, .fg = if (heading) palette.accent else .default, .bold = heading });
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

    const fields = [_][]const u8{ "Title", "Description", "Priority", "Workflow", "Labels", "Assignee", "Parent" };
    const priorities = [_][]const u8{ "none", "low", "medium", "high", "critical" };
    const description_rows = 6;

    pub fn init(s: *AppState, parent: ?u32) Allocator.Error!Form {
        const a = s.modalArena();
        var f: Form = .{ .workflow_states = try dupeAll(a, s.snap.settings.workflow_states) };
        if (parent) |p| {
            const issue = s.snap.issues[p];
            try f.parent.set(s.gpa, shortId(issue.id));
            f.for_parent = try std.fmt.allocPrint(a, "#{s} {s}", .{ shortId(issue.id), issue.title });
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
            else => 0,
        };
    }

    pub fn setOption(f: *Form, n: u8, option: u8) void {
        if (option >= f.optionCount(n)) return;
        switch (n) {
            2 => f.priority = option,
            3 => f.workflow = option,
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
            if (f.hasText() and !s.discard_armed) {
                s.discard_armed = true;
                s.fail("press esc again to discard this issue", .{});
            } else s.closeModal();
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
        const cur = if (f.focus == 2) f.priority else f.workflow;
        if (k.matches(K.left, .{}) or k.matches('h', .{})) {
            f.setOption(f.focus, if (cur == 0) count - 1 else cur - 1);
        } else if (k.matches(K.right, .{}) or k.matches('l', .{}) or k.matches(K.space, .{})) {
            f.setOption(f.focus, (cur + 1) % count);
        }
        return .none;
    }

    fn submit(f: *Form, s: *AppState) Action {
        const a = s.modalArena();
        const title = std.mem.trim(u8, f.title.text(), " \t");
        if (title.len == 0) {
            f.focus = 0;
            s.fail("an issue needs a title", .{});
            return .none;
        }
        const parent_text = std.mem.trim(u8, f.parent.text(), " \t");
        const parent: ?[]const u8 = if (parent_text.len == 0) null else resolve(s, parent_text) orelse {
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
        } };
    }

    fn draw(f: *Form, s: *AppState, fr: ui.Frame, win: ui.Window) Allocator.Error!void {
        _ = s;
        // On a short terminal the gaps go, then description rows.
        const roomy: u16 = 2 * fields.len + description_rows + 4;
        const gap: u16 = if (win.height >= roomy) 1 else 0;
        const desc_rows: u16 = if (gap == 1) description_rows else std.math.clamp(win.height -| @as(u16, fields.len + 4), 1, description_rows);
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
            _ = ui.text(inner, 1, y, name, .{ .fg = if (focused) palette.accent else palette.muted, .bg = bg, .bold = focused });
            const label_win = inner.child(.{ .x_off = 1, .y_off = y, .width = label_w - 1, .height = 1 });
            try fr.hit(label_win, .{ .modal = .{ .field = n } });
            const field_win = inner.child(.{ .x_off = label_w, .y_off = y, .width = inner.width -| label_w -| 1, .height = rows });
            if (f.textArea(n)) |ta| {
                const placeholder: []const u8 = switch (n) {
                    0 => "What needs doing?",
                    1 => "Details, steps, context… (Enter for new lines)",
                    4 => "comma-separated, e.g. bug, ui",
                    5 => "an email",
                    6 => "an issue ID prefix, for a sub-issue",
                    else => "",
                };
                try ta.draw(fr.arena, field_win, .{ .bg = if (focused) palette.input_bg else palette.select_bg }, focused, placeholder);
                try fr.hit(field_win, .{ .modal = .{ .field = n } });
            } else {
                var x: u16 = 0;
                const count = f.optionCount(n);
                const cur = if (n == 2) f.priority else f.workflow;
                var o: u8 = 0;
                while (o < count) : (o += 1) {
                    const lab = if (n == 2) priorities[o] else if (o == 0) "default" else f.workflow_states[o - 1];
                    const st: ui.Style = if (o == cur)
                        .{ .fg = .{ .index = 231 }, .bg = if (focused) palette.accent_bg else palette.button_bg, .bold = true }
                    else
                        .{ .fg = palette.muted, .bg = palette.select_bg };
                    if (x >= field_win.width) break;
                    x += try ui.button(fr, field_win, x, 0, lab, .{ .modal = .{ .option = .{ .field = n, .option = o } } }, st);
                    x += 1;
                }
            }
            y += rows + gap;
            if (n == 1) y -= gap;
        }
        try buttons(fr, inner, inner.height -| 1, "Create  ctrl+s");
    }
};

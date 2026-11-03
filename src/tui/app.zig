//! The TUI over one repository: the UI state, the store, and carrying out
//! the actions input produces.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const issuez = @import("issuez");

const ui = @import("ui.zig");
const store_mod = @import("store.zig");
const State = @import("State.zig");

const core = issuez.format.core;
const shortId = issuez.format.uuid.shortId;

pub fn App(comptime B: type) type {
    return struct {
        const Self = @This();
        pub const Store = store_mod.Store(B);

        store: Store,
        state: State,

        /// In place: the state points into the store.
        pub fn init(self: *Self, gpa: Allocator, backend: *B) void {
            self.store = .init(gpa, backend);
            self.state = .init(gpa, &self.store.snap);
        }

        pub fn deinit(self: *Self) void {
            self.state.deinit();
            self.store.deinit();
            self.* = undefined;
        }

        pub fn draw(self: *Self, win: ui.Window, now_s: i64) Allocator.Error!void {
            assert(self.state.snap == &self.store.snap);
            try self.state.draw(win, now_s);
        }

        /// False once the user quits.
        pub fn handle(self: *Self, input: State.Input, now_ms: i64) Allocator.Error!bool {
            const action = try self.state.handle(input, now_ms);
            return self.perform(action);
        }

        /// Reads the repository again, keeping what is shown. Quietly: for
        /// when the terminal gets the focus back.
        pub fn refresh(self: *Self) void {
            self.store.reload() catch |e| self.failWith(e);
        }

        /// Someone else may have written: the watcher saw the refs or
        /// `settings` (git config) change, or the terminal got the focus
        /// back. Reloads if the refs moved, keeping what is shown, and
        /// says what changed unless an error is showing.
        pub fn changedElsewhere(self: *Self, settings: bool) void {
            const s = &self.state;
            const out = (self.store.reloadIfChanged(settings) catch |e| return self.failWith(e)) orelse return;
            if (s.status_kind == .err and s.status().len > 0) return;
            if (out.issues == 1) {
                s.info("#{s} changed elsewhere", .{shortId(out.first.slice())});
            } else if (out.issues > 1) {
                s.info("{d} issues changed elsewhere", .{out.issues});
            } else if (out.milestones) {
                s.info("milestones changed elsewhere", .{});
            }
        }

        fn failWith(self: *Self, err: anyerror) void {
            var buf: [400]u8 = undefined;
            const msg = self.store.describe(err, &buf);
            self.state.fail("{s}", .{msg});
            if (err == error.VersionMismatch) self.store.reload() catch {};
        }

        fn perform(self: *Self, action: State.Action) bool {
            const s = &self.state;
            const st = &self.store;
            switch (action) {
                .none => {},
                .quit => return false,
                .reload => {
                    st.reload() catch |e| return self.failed(e);
                    s.info("reloaded: {d} issues", .{st.snap.issues.len});
                },
                .create => |input| {
                    const id = st.create(input) catch |e| return self.failed(e);
                    // The input lives in the modal arena.
                    if (input.parent) |p| {
                        s.info("created sub-issue #{s} of #{s}", .{ shortId(id.slice()), shortId(p) });
                    } else s.info("created #{s}", .{shortId(id.slice())});
                    s.closeModal();
                    s.select(id);
                },
                .edit => |e| {
                    st.edit(e.id.slice(), e.spec) catch |err| return self.failed(err);
                    s.closeModal();
                    s.info("saved", .{});
                },
                .milestone => |m| {
                    st.setMilestone(m.id.slice(), m.name) catch |err| return self.failed(err);
                    s.closeModal();
                    s.info("saved", .{});
                },
                .state => |x| {
                    if (!core.isState(x.state)) {
                        s.fail("'{s}' isn't a state", .{x.state});
                        return true;
                    }
                    st.setState(x.id.slice(), core.State.parse(x.state)) catch |err| return self.failed(err);
                    s.info("now {s}", .{x.state});
                    s.closeModal();
                },
                .comment => |c| {
                    st.comment(c.id.slice(), c.text) catch |err| return self.failed(err);
                    s.closeModal();
                    s.info("commented", .{});
                },
                .toggle => |id| {
                    const i = st.snap.find(id.slice()) orelse return true;
                    const done = st.snap.isDone(i);
                    st.setState(id.slice(), if (done) .open else .closed) catch |err| return self.failed(err);
                    s.info("{s} #{s}", .{ if (done) "reopened" else "closed", shortId(id.slice()) });
                },
                .move => |m| self.move(m.id, m.column, m.done),
            }
            return true;
        }

        /// `failWith`, then go on.
        fn failed(self: *Self, err: anyerror) bool {
            self.failWith(err);
            return true;
        }

        /// A card to another column: close it, reopen it, set its workflow
        /// state.
        fn move(self: *Self, id: store_mod.Id, column: []const u8, to_done: bool) void {
            const s = &self.state;
            const st = &self.store;
            const i = st.snap.find(id.slice()) orelse return;
            const done = st.snap.isDone(i);
            if (to_done) {
                if (done) return;
                st.setState(id.slice(), .closed) catch |e| return self.failWith(e);
                s.info("closed #{s}", .{shortId(id.slice())});
                return;
            }
            // The column name lives in the snapshot a write replaces.
            var name_buf: [256]u8 = undefined;
            if (column.len > name_buf.len) return self.failWith(error.UnknownWorkflowState);
            @memcpy(name_buf[0..column.len], column);
            const name = name_buf[0..column.len];
            const workflow = if (std.mem.eql(u8, name, "(none)")) "" else name;
            // Checked before reopening, so a refused state changes nothing.
            if (workflow.len > 0) st.snap.settings.checkWorkflow(workflow) catch |e| return self.failWith(e);
            if (done) st.setState(id.slice(), .open) catch |e| return self.failWith(e);
            const now = st.snap.find(id.slice()) orelse return;
            // The column it shows in, the default state included.
            const current = st.snap.proj.workflow(now) orelse "";
            if (!std.mem.eql(u8, current, workflow)) {
                st.edit(id.slice(), .{ .workflow = workflow }) catch |e| return self.failWith(e);
            }
            s.info("#{s} → {s}", .{ shortId(id.slice()), if (workflow.len == 0) "(none)" else workflow });
        }
    };
}

// Tests: the whole TUI on the simulator, driven by keys and clicks.

const testing = std.testing;
const GitSim = issuez.backend.GitSim;
const K = vaxis.Key;
const filter = @import("filter.zig");

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    world: GitSim.World,
    sim: GitSim,
    app: App(GitSim),
    screen: vaxis.Screen,
    now_ms: i64 = 1_700_000_000_000,

    const cols = 140;
    const rows = 40;

    fn init(h: *Harness) !void {
        h.arena_state = .init(testing.allocator);
        h.world = .{ .clones = &.{.{ .name = "local" }} };
        h.sim = try GitSim.init(h.arena_state.allocator(), &h.world, 0);
        h.app.init(testing.allocator, &h.sim);
        try h.app.store.reload();
        h.screen = try .init(testing.allocator, .{ .rows = rows, .cols = cols, .x_pixel = 0, .y_pixel = 0 });
        try h.draw();
    }

    fn deinit(h: *Harness) void {
        h.screen.deinit(testing.allocator);
        h.app.deinit();
        h.arena_state.deinit();
    }

    fn win(h: *Harness) ui.Window {
        return .{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = cols,
            .height = rows,
            .screen = &h.screen,
        };
    }

    fn draw(h: *Harness) !void {
        try h.app.draw(h.win(), @divFloor(h.now_ms, 1000));
    }

    fn input(h: *Harness, in: State.Input) !void {
        h.now_ms += 50;
        try testing.expect(try h.app.handle(in, h.now_ms));
        try h.draw();
    }

    fn press(h: *Harness, cp: u21, mods: K.Modifiers) !void {
        var buf: [4]u8 = undefined;
        const printable = cp >= 0x20 and cp < 0x7f and !mods.ctrl;
        const n = if (printable) std.unicode.utf8Encode(cp, &buf) catch 0 else 0;
        try h.input(.{ .key = .{ .codepoint = cp, .mods = mods, .text = if (printable) buf[0..n] else null } });
    }

    fn typeText(h: *Harness, s: []const u8) !void {
        for (s) |c| try h.press(c, .{});
    }

    /// A click in the middle of the first hit with this target.
    fn click(h: *Harness, target: ui.Target) !void {
        const hit = for (h.app.state.hits.items.items) |x| {
            if (x.target.eql(target)) break x;
        } else return error.NoSuchTarget;
        const m: vaxis.Mouse = .{
            .col = @intCast(hit.x + hit.w / 2),
            .row = @intCast(hit.y + hit.h / 2),
            .button = .left,
            .mods = .{},
            .type = .press,
        };
        try h.input(.{ .mouse = m });
        var up = m;
        up.type = .release;
        try h.input(.{ .mouse = up });
    }

    fn snap(h: *Harness) *const store_mod.Snapshot {
        return &h.app.store.snap;
    }

    fn byTitle(h: *Harness, title: []const u8) ?u32 {
        for (h.snap().issues, 0..) |issue, i| if (std.mem.eql(u8, issue.title, title)) return @intCast(i);
        return null;
    }

    /// Whether the screen shows the text on some row.
    fn shows(h: *Harness, needle: []const u8) bool {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(testing.allocator);
        for (0..rows) |y| {
            line.clearRetainingCapacity();
            for (0..cols) |x| {
                const cell = h.screen.readCell(@intCast(x), @intCast(y)) orelse continue;
                line.appendSlice(testing.allocator, cell.char.grapheme) catch return false;
            }
            if (std.mem.find(u8, line.items, needle) != null) return true;
        }
        return false;
    }
};

test "create an issue from the list with the keyboard" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try testing.expect(h.shows("No issues yet."));

    try h.press('n', .{});
    try testing.expect(h.app.state.modal != null);
    try h.typeText("Fix the login page");
    try h.press(K.tab, .{});
    try h.typeText("It breaks.");
    try h.press(K.tab, .{});
    try h.press(K.right, .{});
    try h.press(K.right, .{});
    try h.press(K.right, .{}); // high
    try h.press(K.tab, .{});
    try h.press(K.tab, .{});
    try h.typeText("bug, ui");
    try h.press('s', .{ .ctrl = true });

    try testing.expect(h.app.state.modal == null);
    const i = h.byTitle("Fix the login page").?;
    const issue = h.snap().issues[i];
    try testing.expectEqualStrings("It breaks.", issue.description);
    try testing.expectEqualStrings("high", issue.field("Priority").?);
    try testing.expectEqual(@as(usize, 2), issue.labels.len);
    try testing.expect(h.shows("Fix the login page"));
}

test "a sub-issue from the parent's detail view, by mouse" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.app.store.create(.{ .title = "Release 1.0" });
    try h.draw();

    // Double-click opens.
    try h.click(.{ .row = 0 });
    try h.click(.{ .row = 0 });
    try testing.expectEqual(ui.View.detail, h.app.state.view);
    try testing.expect(h.shows("Sub-issues"));

    // The section's item: "+ add sub-issue".
    const add = for (h.app.state.detail.items.items, 0..) |it, n| {
        if (it == .add_child and n >= h.app.state.detail.first) break n;
    } else unreachable;
    try h.click(.{ .item = @intCast(add) });
    try testing.expect(h.app.state.modal.? == .form);
    try h.typeText("Write the changelog");
    try h.click(.{ .modal = .ok });

    const parent = h.byTitle("Release 1.0").?;
    const child = h.byTitle("Write the changelog").?;
    try testing.expectEqual(parent, h.snap().proj.parent[child]);
    // Still on the parent, which lists it.
    try testing.expectEqual(ui.View.detail, h.app.state.view);
    try testing.expect(h.shows("Write the changelog"));
    try testing.expect(h.shows("0/1 done"));
}

test "edit fields in the detail view" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.app.store.create(.{ .title = "Old title" });
    try h.draw();
    try h.press(K.enter, .{});
    try testing.expectEqual(ui.View.detail, h.app.state.view);

    // Title by shortcut.
    try h.press('t', .{});
    try h.press('u', .{ .ctrl = true });
    try h.typeText("New title");
    try h.press(K.enter, .{});
    try testing.expect(h.byTitle("New title") != null);

    // Priority from the menu, by clicking the field.
    try h.click(.{ .item = for (h.app.state.detail.items.items, 0..) |it, n| {
        if (it == .field and it.field == .priority) break @intCast(n);
    } else unreachable });
    try testing.expect(h.app.state.modal.? == .menu);
    try h.click(.{ .modal = .{ .choice = 4 } }); // critical
    const i = h.byTitle("New title").?;
    try testing.expectEqualStrings("critical", h.snap().issues[i].field("Priority").?);

    // A bad date stays in the prompt.
    try h.press('d', .{});
    try h.typeText("tomorrow");
    try h.press(K.enter, .{});
    try testing.expect(h.app.state.modal != null);
    try h.press('u', .{ .ctrl = true });
    try h.typeText("2026-12-01");
    try h.press(K.enter, .{});
    try testing.expect(h.app.state.modal == null);
    try testing.expect(h.snap().issues[h.byTitle("New title").?].ext.due_date != null);

    // Description and a comment.
    try h.press('e', .{});
    try h.typeText("Line one");
    try h.press(K.enter, .{});
    try h.typeText("Line two");
    try h.press('s', .{ .ctrl = true });
    try testing.expectEqualStrings("Line one\nLine two", h.snap().issues[h.byTitle("New title").?].description);
    try h.press('c', .{});
    try h.typeText("Done soon.");
    try h.press('s', .{ .ctrl = true });
    try testing.expect(h.shows("Done soon."));

    // Close it.
    try h.press('x', .{});
    try testing.expect(h.snap().isDone(h.byTitle("New title").?));
}

test "board: move cards with keys and by dragging" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.app.store.create(.{ .title = "Card" });
    try h.press('2', .{});
    try testing.expectEqual(ui.View.board, h.app.state.view);
    try testing.expect(h.shows("backlog"));

    try h.press('>', .{});
    try testing.expectEqualStrings("ready", h.snap().issues[h.byTitle("Card").?].ext.workflow.?);

    // Drag from "ready" (column 1) to "review" (column 3).
    const card = for (h.app.state.hits.items.items) |x| {
        if (x.target == .card) break x;
    } else unreachable;
    const target = for (h.app.state.hits.items.items) |x| {
        if (x.target == .column and x.target.column == 3) break x;
    } else unreachable;
    const press: vaxis.Mouse = .{ .col = @intCast(card.x + 2), .row = @intCast(card.y + 1), .button = .left, .mods = .{}, .type = .press };
    try h.input(.{ .mouse = press });
    var drag = press;
    drag.type = .drag;
    drag.col = @intCast(target.x + 2);
    drag.row = @intCast(target.y + 4);
    try h.input(.{ .mouse = drag });
    try testing.expect(h.shows("drop"));
    var up = drag;
    up.type = .release;
    try h.input(.{ .mouse = up });
    try testing.expectEqualStrings("review", h.snap().issues[h.byTitle("Card").?].ext.workflow.?);

    // To done closes, and with scope "open" done work is hidden.
    try h.press('>', .{});
    try testing.expect(h.snap().isDone(h.byTitle("Card").?));
    try testing.expect(h.shows("Done work is hidden."));
}

test "list: filter, scope and sort" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.app.store.create(.{ .title = "Alpha", .labels = &.{"ui"}, .priority = .low });
    _ = try h.app.store.create(.{ .title = "Beta", .priority = .critical });
    const gamma = try h.app.store.create(.{ .title = "Gamma" });
    try h.app.store.setState(gamma.slice(), .closed);
    try h.draw();
    try testing.expectEqual(@as(usize, 2), h.app.state.list.rows.len);

    try h.press('/', .{});
    try h.typeText("label:ui");
    try testing.expectEqual(@as(usize, 1), h.app.state.list.rows.len);
    try h.press(K.escape, .{});
    try testing.expectEqual(@as(usize, 2), h.app.state.list.rows.len);
    try h.press(K.escape, .{});

    try h.click(.{ .scope = .all });
    try testing.expectEqual(@as(usize, 3), h.app.state.list.rows.len);

    try h.click(.{ .sort = .priority });
    const first = h.app.state.list.rows[0].issue;
    try testing.expectEqualStrings("Beta", h.snap().issues[first].title);
    try h.click(.{ .sort = .priority });
    try testing.expect(h.app.state.query.reverse);

    // The sort menu: a letter jumps to the key, choosing the current one flips.
    try h.press('s', .{});
    try h.press('t', .{});
    try h.press(K.enter, .{});
    try testing.expectEqual(filter.SortKey.title, h.app.state.query.key);
    try testing.expect(h.app.state.modal == null);
    try h.click(.{ .command = .sort });
    try h.click(.{ .modal = .{ .choice = @intFromEnum(filter.SortKey.priority) } });
    try testing.expectEqual(filter.SortKey.priority, h.app.state.query.key);
    try testing.expect(!h.app.state.query.reverse);
}

test "tree mode shows sub-issues under their parent" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const p = try h.app.store.create(.{ .title = "Parent" });
    _ = try h.app.store.create(.{ .title = "Child", .parent = p.slice() });
    _ = try h.app.store.create(.{ .title = "Other" });
    try h.press('t', .{});
    const rows = h.app.state.list.rows;
    try testing.expectEqual(@as(usize, 3), rows.len);
    for (rows, 0..) |r, n| {
        if (std.mem.eql(u8, h.snap().issues[r.issue].title, "Child")) {
            try testing.expectEqual(@as(u8, 1), r.depth);
            try testing.expectEqualStrings("Parent", h.snap().issues[rows[n - 1].issue].title);
        }
    }
    // Filtering keeps the parent as context.
    try h.press('/', .{});
    try h.typeText("Child");
    try testing.expectEqual(@as(usize, 2), h.app.state.list.rows.len);
    try testing.expect(h.app.state.list.rows[0].context);
}

test "dialogs keep their values, also across a reload" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const id = try h.app.store.create(.{ .title = "Labelled", .labels = &.{ "backend", "security" } });
    const parent = try h.app.store.create(.{ .title = "Parent" });
    h.app.state.openIssue(id.slice());
    try h.draw();

    // The prompt starts with the issue's value.
    try h.press('l', .{});
    try testing.expectEqualStrings("backend, security", h.app.state.modal.?.prompt.input.text());
    try h.press(K.escape, .{});

    // A menu outlives a reload, as when the terminal gets the focus back:
    // the custom state among the options is the snapshot's.
    try h.app.store.setState(id.slice(), core.State.parse("on-hold"));
    try h.press('s', .{});
    h.app.refresh();
    try h.draw();
    const options = h.app.state.modal.?.menu.options;
    try testing.expectEqualStrings("on-hold", options[options.len - 1].label);
    try testing.expect(h.shows("on-hold"));
    try h.press('o', .{});
    try h.press(K.enter, .{});
    try testing.expect(h.app.state.modal == null);
    try testing.expectEqualStrings("now open", h.app.state.status());

    // The status names the parent, read before the write's reload.
    try h.press(K.escape, .{});
    try h.press('n', .{});
    try h.typeText("Child");
    try h.click(.{ .modal = .{ .field = 6 } });
    try h.typeText(shortId(parent.slice()));
    try h.press('s', .{ .ctrl = true });
    var buf: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&buf, "of #{s}", .{shortId(parent.slice())});
    try testing.expect(std.mem.endsWith(u8, h.app.state.status(), want));
}

test "sort by ID" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    for ([_][]const u8{ "One", "Two", "Three", "Four" }) |t| _ = try h.app.store.create(.{ .title = t });
    try h.click(.{ .sort = .id });
    try testing.expectEqual(filter.SortKey.id, h.app.state.query.key);
    const rows = h.app.state.list.rows;
    try testing.expectEqual(@as(usize, 4), rows.len);
    for (rows[0 .. rows.len - 1], rows[1..]) |a, b| {
        try testing.expect(std.mem.order(u8, h.snap().issues[a.issue].id, h.snap().issues[b.issue].id) == .lt);
    }
}

test "saving what the issue already has writes nothing" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const id = try h.app.store.create(.{ .title = "Same", .body = "Text" });
    h.app.state.openIssue(id.slice());
    try h.draw();
    const tip = h.snap().issues[h.snap().find(id.slice()).?].tip;

    try h.press('t', .{});
    try h.press(K.enter, .{});
    try testing.expect(h.app.state.modal == null);
    try testing.expectEqualStrings("unchanged", h.app.state.status());
    try h.press('p', .{}); // the menu starts on the current "(none)"
    try h.press(K.enter, .{});
    try h.press('e', .{});
    try h.press('s', .{ .ctrl = true });
    try h.press('d', .{});
    try h.press(K.enter, .{});
    try testing.expect(h.app.state.modal == null);
    try testing.expectEqual(tip, h.snap().issues[h.snap().find(id.slice()).?].tip);

    // A real change still writes.
    try h.press('p', .{});
    try h.press('h', .{});
    try h.press(K.enter, .{});
    try testing.expectEqualStrings("high", h.snap().issues[h.snap().find(id.slice()).?].field("Priority").?);
}

test "the wheel scrolls the editor away from the cursor" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    for (0..200) |n| try body.print(testing.allocator, "line {d}\n", .{n});
    const id = try h.app.store.create(.{ .title = "Long", .body = body.items });
    h.app.state.openIssue(id.slice());
    try h.draw();
    try h.press('e', .{});
    const input = &h.app.state.modal.?.editor.input;
    const bottom = input.scroll;
    try testing.expect(bottom > 0);
    const wheel: vaxis.Mouse = .{ .col = Harness.cols / 2, .row = Harness.rows / 2, .button = .wheel_up, .mods = .{}, .type = .press };
    try h.input(.{ .mouse = wheel });
    try h.input(.{ .mouse = wheel });
    try testing.expectEqual(bottom - 6, input.scroll);
    // Typing brings the cursor back into view.
    try h.typeText("x");
    try testing.expectEqual(bottom, input.scroll);
}

test "ctrl+c asks again when text would be lost" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const ctrl_c: State.Input = .{ .key = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } };
    try h.press('n', .{});
    try h.typeText("Half-written");
    try testing.expect(try h.app.handle(ctrl_c, h.now_ms));
    try testing.expect(h.app.state.modal != null);
    try testing.expect(!try h.app.handle(ctrl_c, h.now_ms));

    // Nothing typed: quits at once.
    h.app.state.closeModal();
    try testing.expect(!try h.app.handle(ctrl_c, h.now_ms));
}

fn setConfig(h: *Harness, key: []const u8, value: []const u8) !void {
    try h.sim.config.append(h.arena_state.allocator(), .{ .key = key, .value = value });
    try h.app.store.reload();
    try h.draw();
}

test "sort by state: open first, in workflow order" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.app.store.create(.{ .title = "Review", .workflow = "review" });
    _ = try h.app.store.create(.{ .title = "Ready", .workflow = "ready" });
    _ = try h.app.store.create(.{ .title = "Default" });
    try h.click(.{ .sort = .state });
    const rows = h.app.state.list.rows;
    const want = [_][]const u8{ "Default", "Ready", "Review" };
    for (want, rows) |t, r| try testing.expectEqualStrings(t, h.snap().issues[r.issue].title);
}

test "board: a column for a state that isn't configured takes no cards" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.app.store.create(.{ .title = "Stale", .workflow = "review" });
    const card = try h.app.store.create(.{ .title = "Done" });
    try h.app.store.setState(card.slice(), .closed);
    try setConfig(&h, "issue.workflowStates", "backlog, ready");
    try h.press('2', .{});
    try h.click(.{ .scope = .all });
    const cols = h.app.state.board.columns;
    try testing.expectEqualStrings("review", cols[cols.len - 2].name);
    try testing.expect(!cols[cols.len - 2].target);

    // The done card, moved left onto "review": refused, still closed.
    try h.click(.{ .card = .{ .column = @intCast(cols.len - 1), .index = 0 } });
    try h.press('<', .{});
    try testing.expect(h.snap().isDone(h.snap().find(card.slice()).?));
    try testing.expect(std.mem.startsWith(u8, h.app.state.status(), "'review' isn't"));
}

test "board: done stays reachable with more columns than fit" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(testing.allocator);
    for (0..80) |n| try names.print(testing.allocator, "{s}s{d}", .{ if (n == 0) "" else ",", n });
    try setConfig(&h, "issue.workflowStates", names.items);
    try h.press('2', .{});
    const cols = h.app.state.board.columns;
    try testing.expect(cols.len <= 64);
    try testing.expect(cols[cols.len - 1].done);
    for (0..100) |_| try h.press(K.right, .{});
    try testing.expectEqual(@as(u16, @intCast(cols.len - 1)), h.app.state.board.column);
}

test "list: filtering keeps the selection in view" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    for (0..80) |n| {
        var buf: [16]u8 = undefined;
        _ = try h.app.store.create(.{ .title = try std.fmt.bufPrint(&buf, "Issue {d}", .{n}) });
    }
    try h.draw();
    try h.press('G', .{});
    try h.press('/', .{});
    try h.typeText("Issue");
    const l = &h.app.state.list;
    try testing.expect(l.scroll > 0);
    try testing.expect(l.selected >= l.scroll and l.selected < l.scroll + l.visible);
}

test "changes made elsewhere show, and say so" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const arena = h.arena_state.allocator();
    const other = issuez.Repo(GitSim).init(&h.sim);
    const mine = try h.app.store.create(.{ .title = "Mine" });
    h.app.state.select(mine);
    try h.draw();

    // Nothing moved: no reload, no message.
    const generation = h.app.store.generation;
    h.app.changedElsewhere(false);
    try testing.expectEqual(generation, h.app.store.generation);
    try testing.expectEqualStrings("", h.app.state.status());

    const theirs = try other.create(arena, .{ .title = "Written by another process" });
    h.app.changedElsewhere(false);
    try h.draw();
    try testing.expect(h.shows("Written by another process"));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&buf, "#{s} changed elsewhere", .{shortId(theirs.id.slice())}),
        h.app.state.status(),
    );
    // The selection stays.
    const selected = h.app.state.list.selectedIssue().?;
    try testing.expectEqualStrings(mine.slice(), h.app.store.snap.issues[selected].id);

    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{mine.slice()});
    _ = try other.edit(arena, ref, .{ .title = "Mine, renamed elsewhere" });
    _ = try other.create(arena, .{ .title = "Another" });
    h.app.changedElsewhere(false);
    try h.draw();
    try testing.expect(h.shows("Mine, renamed elsewhere"));
    try testing.expectEqualStrings("2 issues changed elsewhere", h.app.state.status());

    // An error stays on the status line.
    h.app.state.fail("something failed", .{});
    _ = try other.create(arena, .{ .title = "Third" });
    h.app.changedElsewhere(false);
    try h.draw();
    try testing.expect(h.shows("Third"));
    try testing.expectEqualStrings("something failed", h.app.state.status());
}

test "detail: the focus stays on its item when a reload adds items" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const p = try h.app.store.create(.{ .title = "Parent" });
    _ = try h.app.store.create(.{ .title = "First", .parent = p.slice() });
    h.app.state.openIssue(p.slice());
    try h.draw();
    try h.press('G', .{});
    const d = &h.app.state.detail;
    try testing.expect(d.items.items[d.focus] == .comment);

    _ = try h.app.store.create(.{ .title = "Second", .parent = p.slice() });
    h.app.refresh();
    try h.draw();
    try testing.expect(d.items.items[d.focus] == .comment);
}

fn paste(h: *Harness, keys: []const vaxis.Key) !void {
    try h.input(.paste_start);
    for (keys) |k| try h.input(.{ .key = k });
    try h.input(.paste_end);
}

fn char(c: *const [1]u8) vaxis.Key {
    return .{ .codepoint = c[0], .text = c };
}

test "a paste outside a text box runs no commands" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const id = try h.app.store.create(.{ .title = "Keep open" });
    try h.draw();
    // h.input fails the test if a key quits.
    try paste(&h, &.{ char("x"), char("n"), char("f"), char("q") });
    try testing.expect(!h.snap().isDone(h.snap().find(id.slice()).?));
    try testing.expect(h.app.state.modal == null);
    try testing.expectEqual(filter.Scope.open, h.app.state.query.scope);
}

test "a paste into the form's description keeps its tabs and newlines" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.press('n', .{});
    try h.typeText("Pasted");
    try h.press(K.tab, .{});
    try paste(&h, &.{
        char("a"), .{ .codepoint = K.tab },
        char("b"), .{ .codepoint = 'j', .mods = .{ .ctrl = true } },
        char("c"), .{ .codepoint = K.enter },
        char("d"),
    });
    const form = &h.app.state.modal.?.form;
    try testing.expectEqual(@as(u8, 1), form.focus);
    try testing.expectEqualStrings("a\tb\nc\nd", form.description.text());
    try testing.expectEqual(@as(u8, 0), form.priority);
}

test "a long status is cut at a character, with an ellipsis" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const long = "é" ** 600;
    h.app.state.fail("no issue '{s}'", .{long});
    const st = h.app.state.status();
    try testing.expect(std.unicode.utf8ValidateSlice(st));
    try testing.expect(std.mem.endsWith(u8, st, "…"));
    try testing.expect(std.mem.startsWith(u8, st, "no issue 'éé"));
}

test "a description changed meanwhile isn't overwritten without asking" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const id = try h.app.store.create(.{ .title = "Shared", .body = "Text" });
    h.app.state.openIssue(id.slice());
    try h.draw();
    try h.press('e', .{});
    try h.typeText(" mine");
    // Someone else, then a reload.
    try h.app.store.edit(id.slice(), .{ .description = "Theirs" });
    try h.press('s', .{ .ctrl = true });
    const desc = struct {
        fn of(hh: *Harness, i: store_mod.Id) []const u8 {
            return hh.snap().issues[hh.snap().find(i.slice()).?].description;
        }
    }.of;
    try testing.expect(h.app.state.modal != null);
    try testing.expectEqualStrings("Theirs", desc(&h, id));
    try testing.expect(std.mem.startsWith(u8, h.app.state.status(), "the description changed"));
    try h.press('s', .{ .ctrl = true });
    try testing.expect(h.app.state.modal == null);
    try testing.expectEqualStrings("Text mine", desc(&h, id));
}

test "an ID prefix picks the issue that isn't deleted" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // 17 issues: two share a first character.
    var ids: [17]store_mod.Id = undefined;
    for (&ids) |*id| id.* = try h.app.store.create(.{ .title = "x" });
    const pair: [2]usize = outer: for (ids, 0..) |a, n| {
        for (ids[n + 1 ..], n + 1..) |b, m| if (a.buf[0] == b.buf[0]) break :outer .{ n, m };
    } else unreachable;
    const prefix = ids[pair[0]].buf[0..1];
    // Leave one issue with that first character not deleted.
    const repo = issuez.Repo(GitSim).init(&h.sim);
    for (ids, 0..) |id, n| {
        if (n == pair[0] or id.buf[0] != prefix[0]) continue;
        const ref = try std.fmt.allocPrint(h.arena_state.allocator(), "{s}{s}", .{ issuez.engine.issue_ref_prefix, id.slice() });
        _ = try repo.setDeleted(h.arena_state.allocator(), ref, true, .{});
    }
    try h.app.store.reload();
    const got = h.snap().resolve(prefix);
    try testing.expect(got == .one);
    try testing.expectEqualStrings(ids[pair[0]].slice(), h.snap().issues[got.one].id);
}

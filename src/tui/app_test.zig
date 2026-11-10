//! The whole TUI on the simulator, driven by keys and clicks.

const std = @import("std");
const testing = std.testing;
const vaxis = @import("vaxis");
const issuez = @import("issuez");

const ui = @import("ui.zig");
const store_mod = @import("store.zig");
const State = @import("State.zig");
const sync_job = @import("sync_job.zig");
const modal = @import("modal.zig");
const filter = @import("filter.zig");
const timeline_view = @import("timeline_view.zig");
const timeline_edit = @import("timeline_edit.zig");
const App = @import("app.zig").App;

const core = issuez.format.core;
const shortId = issuez.format.uuid.shortId;
const GitSim = issuez.backend.GitSim;
const K = vaxis.Key;
const D = issuez.format.fields.Date;

fn date(s: []const u8) issuez.engine.EditSpec.DateEdit {
    return .{ .set = D.parse(s).? };
}

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    world: GitSim.World,
    sim: GitSim,
    app: App(GitSim),
    screen: vaxis.Screen,
    now_ms: i64 = 1_700_000_000_000,

    const cols = 140;
    const rows = 40;

    fn create() !*Harness {
        return createWorld(.{ .clones = &.{.{ .name = "local" }} });
    }

    /// With a remote, `origin`, which is clone 1 of the world.
    fn createRemote() !*Harness {
        return createWorld(.{ .seed = 5, .clones = &.{
            .{ .name = "local", .config = &.{.{ .key = "remote.origin.url", .value = "sim:hub" }} },
            .{ .name = "hub" },
        } });
    }

    /// The remote as another process sees it: write, then `commit`.
    fn hub(h: *Harness) !*GitSim {
        const sim = try h.arena_state.allocator().create(GitSim);
        sim.* = try GitSim.init(h.arena_state.allocator(), &h.world, 1);
        // Clones share the world's seed: other UUIDs than ours.
        var burn: [16]u8 = undefined;
        for (0..1000) |_| sim.randomBytes(&burn);
        return sim;
    }

    /// After another clone committed: this one sees the world anew, as
    /// a new process would. Commit its own writes before the other's.
    fn reopen(h: *Harness) !void {
        h.sim = try GitSim.init(h.arena_state.allocator(), &h.world, 0);
        try h.app.store.reload();
        try h.draw();
    }

    fn createWorld(world: GitSim.World) !*Harness {
        const h = try testing.allocator.create(Harness);
        errdefer testing.allocator.destroy(h);
        h.arena_state = .init(testing.allocator);
        h.now_ms = 1_700_000_000_000;
        h.world = world;
        // The caller's list is a temporary; commits write into it.
        h.world.clones = try h.arena_state.allocator().dupe(GitSim.World.Clone, world.clones);
        h.sim = try GitSim.init(h.arena_state.allocator(), &h.world, 0);
        h.app.init(testing.allocator, &h.sim);
        try h.app.store.reload();
        h.screen = try .init(
            testing.allocator,
            .{ .rows = rows, .cols = cols, .x_pixel = 0, .y_pixel = 0 },
        );
        try h.draw();
        return h;
    }

    fn destroy(h: *Harness) void {
        h.screen.deinit(testing.allocator);
        h.app.deinit();
        h.arena_state.deinit();
        testing.allocator.destroy(h);
    }

    /// Both of an issue's dates, `YYYY-MM-DD`.
    fn setDates(h: *Harness, id: []const u8, start: []const u8, due: []const u8) !void {
        try h.app.store.edit(id, .{ .start_date = date(start), .due_date = date(due) });
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
        try h.input(
            .{
                .key = .{
                    .codepoint = cp,
                    .mods = mods,
                    .text = if (printable) buf[0..n] else null,
                },
            },
        );
    }

    fn typeText(h: *Harness, s: []const u8) !void {
        for (s) |c| try h.press(c, .{});
    }

    /// A click in the middle of the first hit with this target, which
    /// must be the one on top there.
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
        const found = h.app.state.hits.find(m.col, m.row) orelse return error.TargetCovered;
        if (!found.target.eql(target)) return error.TargetCovered;
        try h.input(.{ .mouse = m });
        var up = m;
        up.type = .release;
        try h.input(.{ .mouse = up });
    }

    fn snap(h: *Harness) *const store_mod.Snapshot {
        return &h.app.store.snap;
    }

    fn byTitle(h: *Harness, title: []const u8) ?u32 {
        for (h.snap().issues, 0..) |issue, i| {
            if (std.mem.eql(u8, issue.title, title)) return @intCast(i);
        }
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
    const h = try Harness.create();
    defer h.destroy();
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
    const h = try Harness.create();
    defer h.destroy();
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

test "existing issues as sub-issues from the detail view" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const grand = try st.create(.{ .title = "Roadmap" });
    const parent = try st.create(.{ .title = "Release 1.0", .parent = grand.slice() });
    _ = try st.create(.{ .title = "Already a child", .parent = parent.slice() });
    const other = try st.create(.{ .title = "Other parent" });
    _ = try st.create(.{ .title = "Login page" });
    _ = try st.create(.{ .title = "Logout button", .parent = other.slice() });
    try h.draw();
    h.app.state.openIssue(parent.slice());
    try h.draw();

    // A lists all but itself, its ancestors and its sub-issues.
    try h.press('A', .{});
    const p = &h.app.state.modal.?.picker;
    try testing.expectEqual(@as(usize, 3), p.items.len);
    for (p.items) |it| {
        try testing.expect(std.mem.indexOf(u8, it.label, "Roadmap") == null);
        try testing.expect(std.mem.indexOf(u8, it.label, "Already a child") == null);
    }
    try testing.expect(h.shows("Add sub-issues to #"));
    try testing.expect(h.shows("sub-issue of #"));
    // Both "Log" ones in one go, one of them moving from another parent.
    try h.typeText("log");
    try h.press(K.tab, .{});
    try h.press(K.tab, .{});
    try h.press(K.enter, .{});
    try testing.expect(h.app.state.modal == null);
    try testing.expect(h.shows("added 2 issues as sub-issues"));
    const pi = h.byTitle("Release 1.0").?;
    try testing.expectEqual(pi, h.snap().proj.parent[h.byTitle("Login page").?]);
    try testing.expectEqual(pi, h.snap().proj.parent[h.byTitle("Logout button").?]);
    try testing.expect(h.shows("0/3 done"));

    // By mouse, from the section's row.
    const add = for (h.app.state.detail.items.items, 0..) |it, n| {
        if (it == .add_existing and n >= h.app.state.detail.first) break n;
    } else unreachable;
    try h.click(.{ .item = @intCast(add) });
    try h.typeText("other");
    try h.click(.{ .modal = .{ .choice = 0 } });
    try testing.expectEqual(pi, h.snap().proj.parent[h.byTitle("Other parent").?]);
    try testing.expect(h.shows("as a sub-issue of"));
}

test "edit fields in the detail view" {
    const h = try Harness.create();
    defer h.destroy();
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
    try h.typeText("someday");
    try h.press(K.enter, .{});
    try testing.expect(h.app.state.modal != null);
    try h.press('u', .{ .ctrl = true });
    try h.typeText("2026-12-01");
    try h.press(K.enter, .{});
    try testing.expect(h.app.state.modal == null);
    try testing.expect(h.snap().issues[h.byTitle("New title").?].due_date != null);

    // Description and a comment.
    try h.press('e', .{});
    try h.typeText("Line one");
    try h.press(K.enter, .{});
    try h.typeText("Line two");
    try h.press('s', .{ .ctrl = true });
    try testing.expectEqualStrings(
        "Line one\nLine two",
        h.snap().issues[h.byTitle("New title").?].description,
    );
    try h.press('c', .{});
    try h.typeText("Done soon.");
    try h.press('s', .{ .ctrl = true });
    try testing.expect(h.shows("Done soon."));

    // Close it.
    try h.press('x', .{});
    try testing.expect(h.snap().isDone(h.byTitle("New title").?));
}

test "detail: number, lock, ref, origin, reactions and purged comments" {
    const h = try Harness.create();
    defer h.destroy();
    const a = h.arena_state.allocator();
    const repo = issuez.Repo(GitSim).init(&h.sim);
    const created = try repo.create(a, .{
        .title = "Imported",
        .number = 12,
        .original = .{ .author = "octo@github", .id = "gh-12" },
    }, .{});
    const ref = try std.fmt.allocPrint(a, "refs/issues/{s}", .{created.id});
    _ = try repo.edit(
        a,
        ref,
        .{ .locked = true, .lock_reason = "too heated", .ref = .{ .set = "v2" } },
        .{},
    );
    const bad = try repo.comment(a, ref, .{ .text = "Abuse" }, .{});
    const fine = try repo.comment(
        a,
        ref,
        .{ .text = "Fine", .original = .{ .author = "cat@github" } },
        .{},
    );
    _ = try repo.react(a, ref, .{ .emoji = ":+1:" }, .{});
    _ = try repo.react(a, ref, .{ .target = fine.tip, .emoji = "heart" }, .{});
    _ = try issuez.purge.Purge(GitSim).fromRepo(repo).comment(a, ref, bad.tip, .{}, .{});
    try h.app.store.reload();
    try h.draw();
    try h.press(K.enter, .{});
    try testing.expectEqual(ui.View.detail, h.app.state.view);
    try testing.expect(h.shows("#12"));
    try testing.expect(h.shows(" locked "));
    try testing.expect(h.shows("locked: too heated"));
    try testing.expect(h.shows("ref v2"));
    try testing.expect(h.shows("imported from octo@github (gh-12)"));
    try testing.expect(h.shows(":+1: 1"));
    try testing.expect(h.shows("(via cat@github)"));
    try testing.expect(h.shows("heart 1"));
    try testing.expect(h.shows("(purged)"));
    try testing.expect(!h.shows("Abuse"));
}

test "board: move cards with keys and by dragging" {
    const h = try Harness.create();
    defer h.destroy();
    _ = try h.app.store.create(.{ .title = "Card" });
    try h.press('2', .{});
    try testing.expectEqual(ui.View.board, h.app.state.view);
    try testing.expect(h.shows("backlog"));

    try h.press('>', .{});
    try testing.expectEqualStrings("ready", h.snap().issues[h.byTitle("Card").?].workflow.?);

    // Drag from "ready" (column 1) to "review" (column 3).
    const card = for (h.app.state.hits.items.items) |x| {
        if (x.target == .card) break x;
    } else unreachable;
    const target = for (h.app.state.hits.items.items) |x| {
        if (x.target == .column and x.target.column == 3) break x;
    } else unreachable;
    const press: vaxis.Mouse = .{
        .col = @intCast(card.x + 2),
        .row = @intCast(card.y + 1),
        .button = .left,
        .mods = .{},
        .type = .press,
    };
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
    try testing.expectEqualStrings("review", h.snap().issues[h.byTitle("Card").?].workflow.?);

    // To done closes, and with scope "open" done work is hidden.
    try h.press('>', .{});
    try testing.expect(h.snap().isDone(h.byTitle("Card").?));
    try testing.expect(h.shows("Done work is hidden."));
}

test "list: filter, scope and sort" {
    const h = try Harness.create();
    defer h.destroy();
    _ = try h.app.store.create(.{ .title = "Alpha", .labels = &.{"ui"}, .priority = .low });
    _ = try h.app.store.create(.{ .title = "Beta", .priority = .critical });
    const gamma = try h.app.store.create(.{ .title = "Gamma" });
    try h.app.store.setState(gamma.slice(), .closed, null);
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
    try h.click(.{ .modal = .{ .choice = @backingInt(filter.SortKey.priority) } });
    try testing.expectEqual(filter.SortKey.priority, h.app.state.query.key);
    try testing.expect(!h.app.state.query.reverse);
}

test "milestones: M picks one to filter by; y syncs or says why not" {
    const h = try Harness.create();
    defer h.destroy();
    const repo = issuez.Repo(GitSim).init(&h.sim);
    const cat = issuez.Catalog(GitSim).fromRepo(repo);
    const v1 = try cat.create(h.arena_state.allocator(), .{ .name = "v1.0" }, .{});
    _ = try h.app.store.create(.{ .title = "In it" });
    const in_it = h.app.store.snap.issues[0].id;
    try h.app.store.edit(in_it, .{ .milestone = .linked(v1.id) });
    _ = try h.app.store.create(.{ .title = "Not in it" });
    try h.draw();
    try testing.expectEqual(@as(usize, 2), h.app.state.list.rows.len);

    try h.press('M', .{});
    const menu = h.app.state.modal.?.menu;
    try testing.expectEqual(@as(usize, 2), menu.options.len);
    try testing.expect(std.mem.startsWith(u8, menu.options[0].label, "v1.0  0/1 done"));
    try h.press(K.enter, .{});
    try testing.expect(h.app.state.modal == null);
    try testing.expectEqualStrings("m:v1.0", h.app.state.search.text());
    try testing.expectEqual(@as(usize, 1), h.app.state.list.rows.len);

    // "No milestone" filters by none.
    try h.press('M', .{});
    try h.press(K.down, .{});
    try h.press(K.enter, .{});
    try testing.expectEqualStrings("m:", h.app.state.search.text());
    try testing.expectEqual(@as(usize, 1), h.app.state.list.rows.len);

    try h.press('y', .{});
    try testing.expect(std.mem.startsWith(u8, h.app.state.status(), "no remote: add one"));
}

test "tree mode shows sub-issues under their parent" {
    const h = try Harness.create();
    defer h.destroy();
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
    const h = try Harness.create();
    defer h.destroy();
    const id = try h.app.store.create(
        .{ .title = "Labelled", .labels = &.{ "backend", "security" } },
    );
    const parent = try h.app.store.create(.{ .title = "Parent" });
    h.app.state.openIssue(id.slice());
    try h.draw();

    // The prompt starts with the issue's value.
    try h.press('l', .{});
    try testing.expectEqualStrings("backend, security", h.app.state.modal.?.prompt.input.text());
    try h.press(K.escape, .{});

    // A menu outlives a reload, as when the terminal gets the focus back:
    // the custom state among the options is the snapshot's.
    try h.app.store.setState(id.slice(), core.State.parse("on-hold"), null);
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
    const h = try Harness.create();
    defer h.destroy();
    for ([_][]const u8{ "One", "Two", "Three", "Four" }) |t| {
        _ = try h.app.store.create(.{ .title = t });
    }
    try h.click(.{ .sort = .id });
    try testing.expectEqual(filter.SortKey.id, h.app.state.query.key);
    const rows = h.app.state.list.rows;
    try testing.expectEqual(@as(usize, 4), rows.len);
    for (rows[0 .. rows.len - 1], rows[1..]) |a, b| {
        try testing.expect(
            std.mem.order(u8, h.snap().issues[a.issue].id, h.snap().issues[b.issue].id) == .lt,
        );
    }
}

test "saving what the issue already has writes nothing" {
    const h = try Harness.create();
    defer h.destroy();
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
    try testing.expectEqualStrings(
        "high",
        h.snap().issues[h.snap().find(id.slice()).?].field("Priority").?,
    );
}

test "the wheel scrolls the editor away from the cursor" {
    const h = try Harness.create();
    defer h.destroy();
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
    const wheel: vaxis.Mouse = .{
        .col = Harness.cols / 2,
        .row = Harness.rows / 2,
        .button = .wheel_up,
        .mods = .{},
        .type = .press,
    };
    try h.input(.{ .mouse = wheel });
    try h.input(.{ .mouse = wheel });
    try testing.expectEqual(bottom - 6, input.scroll);
    // Typing brings the cursor back into view.
    try h.typeText("x");
    try testing.expectEqual(bottom, input.scroll);
}

test "ctrl+c asks again when text would be lost" {
    const h = try Harness.create();
    defer h.destroy();
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
    const h = try Harness.create();
    defer h.destroy();
    _ = try h.app.store.create(.{ .title = "Review", .workflow = "review" });
    _ = try h.app.store.create(.{ .title = "Ready", .workflow = "ready" });
    _ = try h.app.store.create(.{ .title = "Default" });
    try h.click(.{ .sort = .state });
    const rows = h.app.state.list.rows;
    const want = [_][]const u8{ "Default", "Ready", "Review" };
    for (want, rows) |t, r| try testing.expectEqualStrings(t, h.snap().issues[r.issue].title);
}

test "board: a column for a state that isn't configured takes no cards" {
    const h = try Harness.create();
    defer h.destroy();
    _ = try h.app.store.create(.{ .title = "Stale", .workflow = "review" });
    const card = try h.app.store.create(.{ .title = "Done" });
    try h.app.store.setState(card.slice(), .closed, null);
    try setConfig(h, "issue.workflowStates", "backlog, ready");
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
    const h = try Harness.create();
    defer h.destroy();
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(testing.allocator);
    for (0..80) |n| try names.print(testing.allocator, "{s}s{d}", .{ if (n == 0) "" else ",", n });
    try setConfig(h, "issue.workflowStates", names.items);
    try h.press('2', .{});
    const cols = h.app.state.board.columns;
    try testing.expect(cols.len <= 64);
    try testing.expect(cols[cols.len - 1].done);
    for (0..100) |_| try h.press(K.right, .{});
    try testing.expectEqual(@as(u16, @intCast(cols.len - 1)), h.app.state.board.column);
}

test "list: filtering keeps the selection in view" {
    const h = try Harness.create();
    defer h.destroy();
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
    const h = try Harness.create();
    defer h.destroy();
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

    const theirs = try other.create(arena, .{ .title = "Written by another process" }, .{});
    h.app.changedElsewhere(false);
    try h.draw();
    try testing.expect(h.shows("Written by another process"));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&buf, "#{s} changed elsewhere", .{shortId(theirs.id)}),
        h.app.state.status(),
    );
    // The selection stays.
    const selected = h.app.state.list.selectedIssue().?;
    try testing.expectEqualStrings(mine.slice(), h.app.store.snap.issues[selected].id);

    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{mine.slice()});
    _ = try other.edit(arena, ref, .{ .title = "Mine, renamed elsewhere" }, .{});
    _ = try other.create(arena, .{ .title = "Another" }, .{});
    h.app.changedElsewhere(false);
    try h.draw();
    try testing.expect(h.shows("Mine, renamed elsewhere"));
    try testing.expectEqualStrings("2 issues changed elsewhere", h.app.state.status());

    // An error stays on the status line.
    h.app.state.fail("something failed", .{});
    _ = try other.create(arena, .{ .title = "Third" }, .{});
    h.app.changedElsewhere(false);
    try h.draw();
    try testing.expect(h.shows("Third"));
    try testing.expectEqualStrings("something failed", h.app.state.status());
}

test "detail: the focus stays on its item when a reload adds items" {
    const h = try Harness.create();
    defer h.destroy();
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
    const h = try Harness.create();
    defer h.destroy();
    const id = try h.app.store.create(.{ .title = "Keep open" });
    try h.draw();
    // h.input fails the test if a key quits.
    try paste(h, &.{ char("x"), char("n"), char("f"), char("q") });
    try testing.expect(!h.snap().isDone(h.snap().find(id.slice()).?));
    try testing.expect(h.app.state.modal == null);
    try testing.expectEqual(filter.Scope.open, h.app.state.query.scope);
}

test "a paste into the form's description keeps its tabs and newlines" {
    const h = try Harness.create();
    defer h.destroy();
    try h.press('n', .{});
    try h.typeText("Pasted");
    try h.press(K.tab, .{});
    try paste(h, &.{
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
    const h = try Harness.create();
    defer h.destroy();
    const long: []const u8 = @ptrCast(&@as([600][2]u8, @splat("é".*)));
    h.app.state.fail("no issue '{s}'", .{long});
    const st = h.app.state.status();
    try testing.expect(std.unicode.utf8ValidateSlice(st));
    try testing.expect(std.mem.endsWith(u8, st, "…"));
    try testing.expect(std.mem.startsWith(u8, st, "no issue 'éé"));
}

test "a description changed meanwhile isn't overwritten without asking" {
    const h = try Harness.create();
    defer h.destroy();
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
    try testing.expectEqualStrings("Theirs", desc(h, id));
    try testing.expect(
        std.mem.endsWith(
            u8,
            h.app.state.status(),
            "changed meanwhile: save again to replace it with yours",
        ),
    );
    try h.press('s', .{ .ctrl = true });
    try testing.expect(h.app.state.modal == null);
    try testing.expectEqualStrings("Text mine", desc(h, id));
}

test "a field changed elsewhere while its dialog is open isn't overwritten without asking" {
    const h = try Harness.create();
    defer h.destroy();
    const id = try h.app.store.create(.{ .title = "Shared", .labels = &.{"bug"} });
    h.app.state.openIssue(id.slice());
    try h.draw();
    try h.press('l', .{});
    try h.typeText(", ui");
    // Another process adds one, and the TUI follows.
    const ref = try std.fmt.allocPrint(
        h.arena_state.allocator(),
        "{s}{s}",
        .{ issuez.engine.issue_ref_prefix, id.slice() },
    );
    const other = issuez.Repo(GitSim).init(&h.sim);
    _ = try other.edit(h.arena_state.allocator(), ref, .{ .add_labels = &.{"urgent"} }, .{});
    h.app.changedElsewhere(false);
    try h.draw();
    const labels = struct {
        fn of(hh: *Harness, i: store_mod.Id) []const []const u8 {
            return hh.snap().issues[hh.snap().find(i.slice()).?].labels;
        }
    }.of;
    try testing.expectEqual(@as(usize, 2), labels(h, id).len);

    try h.press(K.enter, .{});
    try testing.expect(h.app.state.modal != null);
    try testing.expectEqual(@as(usize, 2), labels(h, id).len);
    try testing.expect(
        std.mem.endsWith(
            u8,
            h.app.state.status(),
            "changed meanwhile: save again to replace it with yours",
        ),
    );
    // Told, saving again is meant.
    try h.press(K.enter, .{});
    try testing.expect(h.app.state.modal == null);
    const now = labels(h, id);
    try testing.expectEqual(@as(usize, 2), now.len);
    for (now) |l| try testing.expect(std.mem.eql(u8, l, "bug") or std.mem.eql(u8, l, "ui"));
}

test "a menu answer that was the issue's when it opened still writes once it changed" {
    const h = try Harness.create();
    defer h.destroy();
    const id = try h.app.store.create(.{ .title = "Shared" });
    h.app.state.openIssue(id.slice());
    try h.draw();
    try h.press('p', .{}); // on the current "(none)"
    try h.app.store.edit(id.slice(), .{ .priority = .{ .set = .high } });
    try h.press(K.enter, .{});
    try testing.expect(h.app.state.modal != null);
    try h.press(K.enter, .{});
    try testing.expect(h.app.state.modal == null);
    try testing.expectEqual(
        @as(?[]const u8, null),
        h.snap().issues[h.snap().find(id.slice()).?].field("Priority"),
    );
}

test "a failed reload after a create doesn't keep the form for a second one" {
    const h = try Harness.create();
    defer h.destroy();
    try h.press('n', .{});
    try h.typeText("Once");
    try h.sim.configAdd("issue.doneStates", "open");
    try h.press('s', .{ .ctrl = true });
    try testing.expect(h.app.state.modal == null);
    try testing.expect(
        std.mem.startsWith(u8, h.app.state.status(), "git config issue.doneStates is invalid"),
    );
    try h.sim.configUnsetValue("issue.doneStates", "open");
    try h.app.store.reload();
    try testing.expectEqual(@as(usize, 1), h.snap().issues.len);
}

test "a terminal too small shows nothing and keys act on nothing" {
    const h = try Harness.create();
    defer h.destroy();
    _ = try h.app.store.create(.{ .title = "Keep open" });
    try h.draw();
    var small = h.win();
    small.width = 10;
    small.height = 4;
    try h.app.draw(small, 0);
    try testing.expectEqual(@as(usize, 0), h.app.state.list.rows.len);
    try testing.expect(try h.app.handle(.{ .key = .{ .codepoint = 'x' } }, h.now_ms));
    try testing.expect(!h.snap().isDone(0));
    try testing.expect(!try h.app.handle(.{ .key = .{ .codepoint = 'q', .text = "q" } }, h.now_ms));
}

test "an ID prefix picks the issue that isn't deleted" {
    const h = try Harness.create();
    defer h.destroy();
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
        const ref = try std.fmt.allocPrint(
            h.arena_state.allocator(),
            "{s}{s}",
            .{ issuez.engine.issue_ref_prefix, id.slice() },
        );
        _ = try repo.setDeleted(h.arena_state.allocator(), ref, .{}, .{});
    }
    try h.app.store.reload();
    const got = h.snap().resolve(prefix);
    try testing.expect(got == .one);
    try testing.expectEqualStrings(ids[pair[0]].slice(), h.snap().issues[got.one].id);
}

test "detail: the milestone menu links by ID, inherits and clears" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    // Two milestones named alike: the completed one isn't offered.
    const old = try st.createMilestone(.{ .name = "v1" });
    try st.editMilestone(old.slice(), .{ .status = .completed });
    const v1 = try st.createMilestone(.{ .name = "v1", .due = .parse("2026-12-01") });
    const parent = try st.create(.{ .title = "Parent", .milestone_id = v1.slice() });
    _ = try st.create(.{ .title = "Child", .parent = parent.slice() });
    try h.draw();
    const child = h.byTitle("Child").?;
    try testing.expectEqualStrings(v1.slice(), h.snap().proj.milestone[child].?);

    h.app.state.openIssue(h.snap().issues[child].id);
    try h.draw();
    try h.press('m', .{});
    const menu = h.app.state.modal.?.menu;
    try testing.expectEqual(@as(usize, 4), menu.options.len); // v1, none, inherit, other
    try testing.expect(menu.options[2].current);
    // (none): no milestone, and no longer inherited.
    try h.click(.{ .modal = .{ .choice = 1 } });
    try testing.expect(h.snap().proj.milestone[h.byTitle("Child").?] == null);
    try h.press('m', .{});
    try testing.expect(h.app.state.modal.?.menu.options[1].current);
    try h.click(.{ .modal = .{ .choice = 2 } });
    try testing.expectEqualStrings(v1.slice(), h.snap().proj.milestone[h.byTitle("Child").?].?);
    try h.press('m', .{});
    try h.click(.{ .modal = .{ .choice = 0 } });
    const c = h.snap().issues[h.byTitle("Child").?];
    try testing.expectEqualStrings(v1.slice(), c.milestone_id.?);
    try testing.expectEqualStrings("v1", c.field("Milestone").?);
}

test "store: milestones created and edited" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const id = try st.createMilestone(
        .{ .name = "v2", .due = .parse("2027-01-15"), .description = "Next." },
    );
    try testing.expectEqual(@as(usize, 1), h.snap().milestones.len);
    try st.editMilestone(id.slice(), .{ .name = "v2.0", .due = .clear });
    const m = h.snap().milestones[h.snap().findMilestone(id.slice()).?];
    try testing.expectEqualStrings("v2.0", m.name);
    try testing.expect(m.due == null);
    try testing.expectEqualStrings("Next.", m.description);
    // Completing needs the work done.
    const i = try st.create(.{ .title = "Work", .milestone_id = id.slice() });
    try testing.expectError(
        error.OpenWorkInMilestone,
        st.editMilestone(id.slice(), .{ .status = .completed }),
    );
    try st.setState(i.slice(), .closed, null);
    try st.editMilestone(id.slice(), .{ .status = .completed });
    // And then takes no new work.
    const j = try st.create(.{ .title = "Late" });
    try testing.expectError(
        error.MilestoneCompleted,
        st.setMilestoneLink(j.slice(), .{ .id = id.slice() }, null),
    );
}

test "milestones view: create, sort, filter, complete" {
    const h = try Harness.create();
    defer h.destroy();
    try h.press('3', .{});
    try testing.expectEqual(ui.View.milestones, h.app.state.view);
    try testing.expect(h.shows("No milestones yet."));

    // n, a name, Enter.
    try h.press('n', .{});
    try h.typeText("v1.0");
    try h.press(K.tab, .{});
    try h.typeText("2026-12-01");
    try h.press(K.enter, .{});
    try testing.expect(h.app.state.modal == null);
    try testing.expectEqual(@as(usize, 1), h.snap().milestones.len);
    try h.press('n', .{});
    try h.typeText("Alpha");
    try h.press(K.enter, .{});
    const v1 = h.snap().milestones[h.snap().findMilestone(h.snap().milestones[0].id).?];
    _ = v1;
    // Due first, none last: v1.0, then Alpha, then "(no milestone)".
    var rows = h.app.state.milestones.rows;
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("v1.0", h.snap().milestones[rows[0]].name);
    try testing.expect(h.shows("(no milestone)"));
    // By name.
    try h.click(.{ .ms_sort = .name });
    rows = h.app.state.milestones.rows;
    try testing.expectEqualStrings("Alpha", h.snap().milestones[rows[0]].name);

    // Work in v1.0, half done.
    const id = h.snap().milestones[rows[1]].id;
    const a = try h.app.store.create(.{ .title = "One", .milestone_id = id });
    _ = try h.app.store.create(.{ .title = "Two", .milestone_id = id });
    try h.app.store.setState(a.slice(), .closed, null);
    try h.draw();
    try testing.expect(h.shows("50%"));
    try h.press('/', .{});
    try h.typeText("is:empty");
    try h.press(K.enter, .{});
    try testing.expectEqual(@as(usize, 1), h.app.state.milestones.rows.len);
    try h.press(K.escape, .{});

    // Completing with open work says so, and shows it.
    const vi = for (h.app.state.milestones.rows, 0..) |n, r| {
        if (n < h.snap().milestones.len and std.mem.eql(
            u8,
            h.snap().milestones[n].name,
            "v1.0",
        )) break r;
    } else unreachable;
    try h.click(.{ .ms_row = @intCast(vi) });
    try h.press('c', .{});
    try testing.expect(h.app.state.modal.? == .confirm);
    try testing.expect(h.shows("1 of its 2 issues are still open"));
    try h.press(K.enter, .{}); // Show open issues
    try testing.expectEqual(ui.View.milestone, h.app.state.view);
    try testing.expect(h.shows("Two"));
    try testing.expect(!h.shows("One"));
    // Close it there, then complete.
    try h.press('x', .{});
    try h.press('c', .{});
    try testing.expect(h.shows("All 2 issues are done."));
    try h.press(K.enter, .{});
    try testing.expectEqual(
        issuez.format.fields.MilestoneStatus.completed,
        h.snap().milestones[h.snap().findMilestone(id).?].status,
    );
    // Back to the list of milestones; completed ones are in their scope.
    try h.press(K.escape, .{});
    try testing.expectEqual(ui.View.milestones, h.app.state.view);
    try testing.expect(!h.shows("v1.0"));
    try h.click(.{ .ms_scope = .completed });
    try testing.expect(h.shows("v1.0"));
    try testing.expect(h.shows("done"));
}

test "milestones view: rename, due date, retire, reopen" {
    const h = try Harness.create();
    defer h.destroy();
    _ = try h.app.store.createMilestone(.{ .name = "Draft" });
    try h.press('3', .{});
    try h.press('r', .{});
    try h.press('u', .{ .ctrl = true });
    try h.typeText("Release");
    try h.press(K.enter, .{});
    try testing.expectEqualStrings("Release", h.snap().milestones[0].name);
    try h.press('d', .{});
    try h.typeText("+2w");
    try testing.expect(h.shows("→ 2023-11-28"));
    try h.press(K.enter, .{});
    try testing.expect(
        h.snap().milestones[0].due.?.eql(D.parse("2023-11-28").?),
    );
    try h.press('R', .{});
    try h.press(K.enter, .{});
    try testing.expectEqual(
        issuez.format.fields.MilestoneStatus.retired,
        h.snap().milestones[0].status,
    );
    try h.click(.{ .ms_scope = .all });
    try h.press('g', .{});
    try h.press('o', .{});
    try testing.expectEqual(
        issuez.format.fields.MilestoneStatus.open,
        h.snap().milestones[0].status,
    );
    // Edited in the form: one commit for both.
    try h.press('e', .{});
    try h.press(K.tab, .{});
    try h.press('u', .{ .ctrl = true });
    try h.press(K.tab, .{});
    try h.typeText("For the release.");
    try h.press('s', .{ .ctrl = true });
    try testing.expect(h.snap().milestones[0].due == null);
    try testing.expectEqualStrings("For the release.", h.snap().milestones[0].description);
}

test "milestone view: create in it, quick add, move with ] and the menu" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const v1 = try st.createMilestone(.{ .name = "v1", .due = .parse("2026-12-01") });
    const v2 = try st.createMilestone(.{ .name = "v2", .due = .parse("2027-01-01") });
    try h.press('3', .{});
    try h.press(K.enter, .{});
    try testing.expectEqual(ui.View.milestone, h.app.state.view);
    try testing.expect(h.shows("No issues in this milestone yet"));

    // The form puts it in the milestone.
    try h.press('n', .{});
    try h.typeText("In v1");
    try h.press('s', .{ .ctrl = true });
    const in_v1 = h.snap().issues[h.byTitle("In v1").?];
    try testing.expectEqualStrings(v1.slice(), in_v1.milestone_id.?);
    // Quick add: two titles, then Esc.
    try h.press('N', .{});
    try h.typeText("Quick one");
    try h.press(K.enter, .{});
    try testing.expect(h.app.state.modal != null);
    try h.typeText("Quick two");
    try h.press(K.enter, .{});
    try h.press(K.escape, .{});
    try testing.expect(h.app.state.modal == null);
    try testing.expectEqual(@as(usize, 3), h.app.state.milestone.panes[0].rows.len);
    try testing.expectEqualStrings(v1.slice(), h.snap().proj.milestone[h.byTitle("Quick two").?].?);

    // ] to the next milestone.
    h.app.state.milestone.panes[0].selected_id = .of(h.snap().issues[h.byTitle("Quick one").?].id);
    try h.draw();
    try h.press(']', .{});
    try testing.expectEqualStrings(v2.slice(), h.snap().proj.milestone[h.byTitle("Quick one").?].?);
    try testing.expect(h.shows("moved #"));
    // [ from the first open milestone: to none.
    try h.press('[', .{});
    try testing.expect(h.shows("to no milestone"));
    try testing.expectEqual(@as(usize, 1), h.app.state.milestone.panes[0].rows.len);
    // Mark what is left, and one of v2's through the second pane, and
    // move them with the menu, in one write.
    try h.press(K.space, .{});
    try testing.expect(h.shows("1 marked"));
    try h.press('v', .{});
    try h.press('p', .{});
    try h.click(.{ .modal = .{ .choice = 2 } }); // (no milestone)
    try testing.expectEqual(@as(u16, 1), h.app.state.milestone.pane);
    try h.press(K.space, .{});
    try testing.expectEqual(@as(usize, 2), h.app.state.milestone.marks.items.len);
    try h.press('m', .{});
    const picker = h.app.state.modal.?.picker;
    try testing.expectEqualStrings("v1", picker.items[0].label);
    try testing.expectEqualStrings("due 2026-12-01", picker.items[0].detail);
    // Typing narrows it down; Enter picks.
    try h.typeText("v2");
    try testing.expect(h.shows("1 of 3"));
    try h.press(K.enter, .{});
    try testing.expectEqual(@as(usize, 0), h.app.state.milestone.marks.items.len);
    try testing.expect(h.shows("moved 2 issues to v2"));
    var in_v2: u32 = 0;
    for (h.snap().proj.milestone) |m| {
        if (m) |x| if (std.mem.eql(u8, x, v2.slice())) {
            in_v2 += 1;
        };
    }
    try testing.expectEqual(@as(u32, 3), in_v2);
}

test "milestone view: inherited sub-issues, split pane and dragging" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const v1 = try st.createMilestone(.{ .name = "v1" });
    const parent = try st.create(.{ .title = "Parent", .milestone_id = v1.slice() });
    _ = try st.create(.{ .title = "Child", .parent = parent.slice() });
    _ = try st.create(.{ .title = "Loose" });
    try h.draw();
    h.app.state.openMilestone(.{ .id = v1 });
    try h.draw();
    try testing.expect(h.shows("↳ inherited"));

    // Moving the child alone asks first.
    h.app.state.milestone.panes[0].selected_id = .of(h.snap().issues[h.byTitle("Child").?].id);
    try h.draw();
    try h.press('m', .{});
    try h.click(.{ .modal = .{ .choice = 1 } }); // (no milestone)
    try testing.expect(h.app.state.modal.? == .confirm);
    try h.press('w', .{}); // With the parents
    try testing.expect(h.snap().proj.milestone[h.byTitle("Parent").?] == null);
    try testing.expect(h.snap().proj.milestone[h.byTitle("Child").?] == null);
    try testing.expect(h.shows("with 1 sub-issues that inherit"));

    // Split: v1 left, the backlog right; drag Loose over to v1.
    try h.press('v', .{});
    try testing.expect(h.app.state.milestone.split);
    try testing.expect(h.shows("(no milestone) · "));
    const row = for (h.app.state.hits.items.items) |x| {
        if (x.target == .mrow and x.target.mrow.column == 1 and
            std.mem.eql(
                u8,
                h.snap().issues[
                    h.app.state.milestone.panes[1].rows[x.target.mrow.index].issue
                ].title,
                "Loose",
            )) break x;
    } else unreachable;
    const pane = for (h.app.state.hits.items.items) |x| {
        if (x.target == .mpane and x.target.mpane == 0) break x;
    } else unreachable;
    const press: vaxis.Mouse = .{
        .col = @intCast(row.x + 12),
        .row = @intCast(row.y),
        .button = .left,
        .mods = .{},
        .type = .press,
    };
    try h.input(.{ .mouse = press });
    var drag = press;
    drag.type = .drag;
    drag.col = @intCast(pane.x + 4);
    drag.row = @intCast(pane.y + 3);
    try h.input(.{ .mouse = drag });
    var up = drag;
    up.type = .release;
    try h.input(.{ .mouse = up });
    try testing.expectEqualStrings(v1.slice(), h.snap().proj.milestone[h.byTitle("Loose").?].?);
    // Opening an issue and coming back lands here.
    try h.press(K.enter, .{});
    try testing.expectEqual(ui.View.detail, h.app.state.view);
    try h.press(K.escape, .{});
    try testing.expectEqual(ui.View.milestone, h.app.state.view);
    try h.press(K.escape, .{});
    try testing.expectEqual(ui.View.list, h.app.state.view);
}

test "milestones view: lateness fits, the selection outlasts a filter, re-sorting follows it" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    // Harness time: 2023-11-14.
    _ = try st.createMilestone(.{ .name = "Late one", .due = .parse("2023-11-02") });
    _ = try st.createMilestone(.{ .name = "Soon one", .due = .parse("2023-11-15") });
    try h.press('3', .{});
    try testing.expect(h.shows("2023-11-02 12d late"));
    try testing.expect(h.shows("2023-11-15 tomorrow"));

    // Filtered out and back: the selection is still on it.
    const v = &h.app.state.milestones;
    try h.press('j', .{});
    try h.press('/', .{});
    try h.typeText("late");
    try h.press(K.enter, .{});
    try testing.expectEqual(@as(usize, 1), v.rows.len);
    try h.press(K.escape, .{});
    try testing.expectEqualStrings(
        "Soon one",
        h.snap().milestones[v.selectedMilestone(h.snap()).?].name,
    );
    // A term it doesn't know says so.
    try h.press('/', .{});
    try h.typeText("is:late");
    try testing.expect(h.shows("filter: unknown is:late"));
    try h.press(K.escape, .{});
    try h.press(K.escape, .{});

    // More than fit; the last one selected, then first after re-sorting.
    const a = h.arena_state.allocator();
    for (0..40) |n| _ = try st.createMilestone(
        .{ .name = try std.fmt.allocPrint(a, "M{d:0>2}", .{n}) },
    );
    try h.draw();
    try h.click(.{ .ms_sort = .name });
    try h.press('G', .{});
    try h.press('k', .{});
    try testing.expectEqualStrings(
        "Soon one",
        h.snap().milestones[v.selectedMilestone(h.snap()).?].name,
    );
    try testing.expect(v.scroll > 0);
    try h.press('S', .{});
    try testing.expectEqual(@as(u32, 0), v.selected);
    try testing.expectEqual(@as(u32, 0), v.scroll);
    try h.press('G', .{});
    try h.press('k', .{});
    try h.click(.sort_reverse);
    try testing.expect(v.selected >= v.scroll and v.selected < v.scroll + v.visible);
    try h.press('G', .{});
    try h.press('k', .{});
    try h.click(.{ .ms_sort = .name });
    try testing.expect(v.selected >= v.scroll and v.selected < v.scroll + v.visible);
}

test "milestones view: the no-milestone row shows whenever it is selectable" {
    const h = try Harness.create();
    defer h.destroy();
    try h.press('3', .{});
    var small = try vaxis.Screen.init(
        testing.allocator,
        .{ .rows = 8, .cols = 60, .x_pixel = 0, .y_pixel = 0 },
    );
    defer small.deinit(testing.allocator);
    const w: ui.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 60,
        .height = 8,
        .screen = &small,
    };
    try h.app.draw(w, @divFloor(h.now_ms, 1000));
    const row = for (h.app.state.hits.items.items) |x| {
        if (x.target == .ms_row) break x;
    } else return error.NoRow;
    try testing.expectEqual(@as(u32, 0), row.target.ms_row);
}

test "milestone view: pane button, header follows focus, marks, completed milestones" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const v1 = try st.createMilestone(.{ .name = "v1", .due = .parse("2026-12-01") });
    const v2 = try st.createMilestone(.{ .name = "v2", .due = .parse("2027-01-01") });
    const old = try st.createMilestone(.{ .name = "Shipped" });
    try st.editMilestone(old.slice(), .{ .status = .completed });
    _ = try st.create(.{ .title = "A1", .milestone_id = v1.slice() });
    _ = try st.create(.{ .title = "B1", .milestone_id = v2.slice() });
    _ = try st.create(.{ .title = "Loose" });
    try h.draw();
    h.app.state.openMilestone(.{ .id = v1 });
    try h.draw();
    const mv = &h.app.state.milestone;

    // p, then esc: still one pane.
    try h.press('p', .{});
    try h.press(K.escape, .{});
    try testing.expect(!mv.split);
    // Split; the button on the right pane's title picks it.
    try h.press('v', .{});
    try h.click(.{ .command = .pick_pane });
    const options = h.app.state.modal.?.menu.options;
    const pick = struct {
        fn at(opts: []const modal.Menu.Option, label: []const u8) u16 {
            for (opts, 0..) |o, n| if (std.mem.eql(u8, o.label, label)) return @intCast(n);
            unreachable;
        }
    }.at;
    try testing.expect(options[pick(options, "Shipped")].disabled);
    try h.click(.{ .modal = .{ .choice = pick(options, "Shipped") } });
    try testing.expect(h.shows("reopen it first"));
    try h.click(.{ .modal = .{ .choice = pick(options, "v2") } });
    try testing.expect(mv.other.eql(.{ .id = v2 }));
    try testing.expectEqual(@as(u16, 1), mv.pane);
    // The header is the focused pane's: completing is v2's.
    try h.click(.{ .command = .ms_complete });
    try testing.expect(h.shows("Complete v2?"));
    try h.press(K.escape, .{});

    // A mark on the right, the focus on the left: v1 isn't where it is.
    try h.press(K.space, .{});
    try h.press(K.tab, .{});
    try h.press('m', .{});
    for (h.app.state.modal.?.picker.items) |it| {
        try testing.expectEqual(std.mem.eql(u8, it.label, "v2"), it.current);
    }
    try h.press(K.escape, .{});
    // In one pane the mark is hidden: m is for the selected issue.
    try h.press('v', .{});
    try testing.expect(h.shows("0 marked, 1 hidden"));
    try h.press('m', .{});
    const a1 = h.snap().issues[h.byTitle("A1").?].id;
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(h.arena_state.allocator(), "Move #{s} to", .{shortId(a1)}),
        h.app.state.modal.?.picker.title,
    );
    try h.press(K.escape, .{});
    // Adding issues keeps the marks.
    try h.press('+', .{});
    try h.typeText("loose");
    try h.press(K.enter, .{});
    try testing.expectEqualStrings(v1.slice(), h.snap().proj.milestone[h.byTitle("Loose").?].?);
    try testing.expectEqual(@as(usize, 1), mv.marks.items.len);

    // Nothing moves into a completed milestone.
    try h.press('v', .{});
    mv.other = .{ .id = old };
    mv.pane = 0;
    try h.draw();
    try h.press('>', .{});
    try testing.expect(h.shows("Shipped is completed: reopen it"));
    try testing.expectEqualStrings(v1.slice(), h.snap().proj.milestone[h.byTitle("A1").?].?);
}

test "milestone view: context rows aren't in it, and say so" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const v1 = try st.createMilestone(.{ .name = "v1", .due = .parse("2026-12-01") });
    const v2 = try st.createMilestone(.{ .name = "v2", .due = .parse("2027-01-01") });
    const grand = try st.create(.{ .title = "Grand", .milestone_id = v2.slice() });
    const parent = try st.create(.{ .title = "Parent", .parent = grand.slice() });
    _ = try st.create(.{ .title = "Child", .parent = parent.slice(), .milestone_id = v1.slice() });
    try h.draw();
    h.app.state.openMilestone(.{ .id = v1 });
    try h.draw();
    const pane = &h.app.state.milestone.panes[0];
    try testing.expectEqual(@as(usize, 3), pane.rows.len);
    // Parent inherits v2, not v1.
    try testing.expect(!h.shows("↳ inherited"));
    pane.selected_id = .of(parent.slice());
    try h.draw();
    try h.press(']', .{});
    try testing.expect(h.shows("isn't in v1"));
    try testing.expectEqualStrings(v2.slice(), h.snap().proj.milestone[h.byTitle("Parent").?].?);
    try h.press(K.space, .{});
    try testing.expectEqual(@as(usize, 0), h.app.state.milestone.marks.items.len);
    try h.press('m', .{});
    try testing.expect(h.app.state.modal == null);
}

test "milestone view: why it is empty; open-only for one opening" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const v1 = try st.createMilestone(.{ .name = "v1", .description = "First\tline\r\nSecond" });
    const old = try st.createMilestone(.{ .name = "Shipped" });
    try st.editMilestone(old.slice(), .{ .status = .completed });
    const v3 = try st.createMilestone(.{ .name = "v3" });
    for ([_][]const u8{ "One", "Two" }) |t| {
        const id = try st.create(.{ .title = t, .milestone_id = v1.slice() });
        try st.setState(id.slice(), .closed, null);
    }
    _ = try st.create(.{ .title = "Open work", .milestone_id = v3.slice() });
    try h.draw();
    h.app.state.openMilestone(.{ .id = v1 });
    try h.draw();
    try testing.expect(h.shows("None of the 2 issues here match"));
    try testing.expect(h.shows("2/2 done"));
    try testing.expect(!h.shows("yet"));
    // The description's first line, with no control characters.
    try testing.expect(h.shows(" First line "));
    try testing.expect(!h.shows("Second"));
    h.app.state.openMilestone(.{ .id = old });
    try h.draw();
    try testing.expect(h.shows("No issues in this milestone: it is completed."));

    // "Show open issues" shows them, this once.
    try h.press(K.escape, .{});
    h.app.state.mv_query.scope = .all;
    try h.press('3', .{});
    const v = &h.app.state.milestones;
    while (!std.mem.eql(
        u8,
        h.snap().milestones[v.selectedMilestone(h.snap()).?].name,
        "v3",
    )) try h.press(
        'j',
        .{},
    );
    try h.press('c', .{});
    try h.press(K.enter, .{}); // Show open issues
    try testing.expectEqual(ui.View.milestone, h.app.state.view);
    try testing.expectEqual(filter.Scope.open, h.app.state.mv_query.scope);
    try h.press(K.escape, .{});
    try testing.expectEqual(filter.Scope.all, h.app.state.mv_query.scope);
}

test "moving issues: the ones gone, and every sub-issue that follows" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const v1 = try st.createMilestone(.{ .name = "v1" });
    const parent = try st.create(.{ .title = "Parent", .milestone_id = v1.slice() });
    const child = try st.create(.{ .title = "Child", .parent = parent.slice() });
    _ = try st.create(.{ .title = "Grandchild", .parent = child.slice() });
    try h.draw();
    const gone: store_mod.Id = .of("ffffffff-ffff-4fff-bfff-ffffffffffff");
    h.app.moveIssues(&.{ parent, gone }, .none, &.{});
    try h.draw();
    try testing.expect(h.shows("moved #"));
    try testing.expect(h.shows("with 2 sub-issues that inherit; 1 issue is gone meanwhile"));
    // The child moves itself: only the grandchild follows.
    h.app.moveIssues(&.{ parent, child }, .{ .id = v1.slice() }, &.{});
    try h.draw();
    try testing.expect(h.shows("moved 2 issues to v1, with 1 sub-issues that inherit"));
    h.app.moveIssues(&.{gone}, .none, &.{});
    try h.draw();
    try testing.expect(h.shows("1 issue is gone meanwhile: nothing to move"));
}

test "milestone view: moving marked issues unmarks them from the modal's IDs" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const v1 = try st.createMilestone(.{ .name = "v1" });
    const v2 = try st.createMilestone(.{ .name = "v2" });
    const a = try st.create(.{ .title = "A", .milestone_id = v1.slice() });
    const b = try st.create(.{ .title = "B", .milestone_id = v1.slice() });
    try h.draw();
    try h.app.state.milestone.marks.append(h.app.state.gpa, a);
    try h.app.state.milestone.marks.append(h.app.state.gpa, b);
    // The IDs past the modal arena's oldest node: closing it frees them.
    const ma = h.app.state.modalArena();
    _ = try ma.alloc(u8, 1 << 16);
    _ = try ma.alloc(u8, 1 << 16);
    const ids = try ma.dupe(store_mod.Id, &.{ a, b });
    h.app.moveIssues(ids, .{ .id = v2.slice() }, ids);
    try testing.expectEqual(@as(usize, 0), h.app.state.milestone.marks.items.len);
    try testing.expectEqualStrings(v2.slice(), h.snap().proj.milestone[h.byTitle("A").?].?);
}

test "timeline: bars, groups, blockers, zoom" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    // Harness time: 2023-11-14, a Tuesday.
    const v1 = try st.createMilestone(.{ .name = "v1", .due = .parse("2023-11-30") });
    const design = try st.create(.{ .title = "Design", .milestone_id = v1.slice() });
    try h.setDates(design.slice(), "2023-11-13", "2023-11-17");
    const build = try st.create(.{ .title = "Build", .milestone_id = v1.slice() });
    try st.edit(
        build.slice(),
        .{
            .start_date = date("2023-11-16"),
            .due_date = date("2023-12-05"),
            .add_blocked_by = &.{design.slice()},
        },
    );
    const docs = try st.create(.{ .title = "Docs", .milestone_id = v1.slice() });
    try st.edit(
        docs.slice(),
        .{ .due_date = date("2023-11-28"), .estimate_minutes = .{ .set = 16 * 60 } },
    );
    _ = try st.create(.{ .title = "Someday", .milestone_id = v1.slice() });
    const loose = try st.create(.{ .title = "Loose" });
    try st.edit(loose.slice(), .{ .due_date = date("2023-11-20") });
    try h.press('4', .{});
    try testing.expectEqual(ui.View.timeline, h.app.state.view);
    const t = &h.app.state.timeline;
    try testing.expect(h.shows("◆ v1"));
    try testing.expect(h.shows("1 without dates"));
    try testing.expect(h.shows("work ends after the due date"));
    try testing.expect(h.shows("Nov 2023"));
    // Design's bar starts on its start date: chart at column 36, rows
    // below the bar, the timeline's two and the header.
    const design_row = for (t.rows, 0..) |r, n| {
        if (r.kind == .issue and std.mem.eql(u8, h.snap().issues[r.issue].title, "Design")) break n;
    } else unreachable;
    const y: u16 = @intCast(4 + design_row - t.scroll);
    const x0: u16 = @intCast(36 + t.x(D.parse("2023-11-13").?.toDays()));
    try testing.expectEqualStrings("█", h.screen.readCell(x0, y).?.char.grapheme);
    try testing.expectEqualStrings("█", h.screen.readCell(x0 + 4, y).?.char.grapheme);
    try testing.expect(!std.mem.eql(u8, "█", h.screen.readCell(x0 + 5, y).?.char.grapheme));

    // Build: blocked by Design, which it starts before.
    try h.press('j', .{});
    try h.press('j', .{});
    try testing.expectEqualStrings("Build", h.snap().issues[t.selectedIssue().?].title);
    try testing.expect(h.shows("starts before #"));
    try testing.expect(h.shows("ends after its milestone is due"));
    try testing.expectEqualStrings("◀", h.screen.readCell(35, y).?.char.grapheme);

    // Zoom in keeps Build's start in place, more or less.
    const before = t.x(D.parse("2023-11-16").?.toDays());
    try h.press('z', .{});
    try testing.expectEqual(timeline_view.Zoom.day, t.zoom);
    try testing.expect(@abs(t.x(D.parse("2023-11-16").?.toDays()) - before) <= 3);
    try h.press('Z', .{});
    try h.press('Z', .{});
    try testing.expectEqual(timeline_view.Zoom.month, t.zoom);
    try h.click(.{ .tl_zoom = .week });
    try testing.expectEqual(timeline_view.Zoom.week, t.zoom);
    const origin = t.origin;
    try h.press(K.right, .{});
    try testing.expectEqual(origin + 7, t.origin);
    try h.press('.', .{});

    // Folding the group, unfolding what has no dates.
    const n = t.rows.len;
    try h.press('g', .{});
    try h.press(K.space, .{});
    try testing.expectEqual(n - 4, t.rows.len);
    try h.press(K.space, .{});
    const unscheduled = for (t.rows, 0..) |r, i| {
        if (r.kind == .unscheduled) break i;
    } else unreachable;
    try h.click(.{ .tl_row = @intCast(unscheduled) });
    try h.press(K.space, .{});
    try testing.expect(h.shows("Someday"));
    // Enter on a group: the milestone's issues.
    try h.press('g', .{});
    try h.press(K.enter, .{});
    try testing.expectEqual(ui.View.milestone, h.app.state.view);
    // T there: back to the timeline at the milestone.
    try h.press('T', .{});
    try testing.expectEqual(ui.View.timeline, h.app.state.view);
    try testing.expectEqual(timeline_view.Row.Kind.group, t.rows[t.selected].kind);
}

test "timeline edit mode: staged, applied all at once, guarded when leaving" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const v1 = try st.createMilestone(.{ .name = "v1", .due = .parse("2023-11-30") });
    const design = try st.create(.{ .title = "Design", .milestone_id = v1.slice() });
    try h.setDates(design.slice(), "2023-11-13", "2023-11-17");
    const build = try st.create(.{ .title = "Build", .milestone_id = v1.slice() });
    try h.setDates(build.slice(), "2023-11-20", "2023-11-24");
    const dates = struct {
        fn of(hh: *Harness, title: []const u8) [2]?D {
            const issue = hh.snap().issues[hh.byTitle(title).?];
            return .{ issue.start_date, issue.due_date };
        }
    }.of;
    try h.press('4', .{});
    const t = &h.app.state.timeline;
    try h.press('j', .{}); // Design
    try testing.expectEqualStrings("Design", h.snap().issues[t.selectedIssue().?].title);

    try h.press('E', .{});
    try testing.expect(t.editing);
    try testing.expect(h.shows("EDIT MODE"));
    try testing.expect(h.shows("no changes yet"));
    // A day later, then the due date one more: staged, not written.
    try h.press(K.right, .{});
    try h.press('>', .{});
    try testing.expect(h.shows("1 change not applied"));
    try testing.expect(dates(h, "Design")[0].?.eql(D.parse("2023-11-13").?));
    try testing.expect(
        timeline_view.datesOf(
            &h.app.state,
            h.byTitle("Design").?,
        ).due.?.eql(D.parse("2023-11-19").?),
    );
    // Undo and redo.
    try h.press('u', .{});
    try h.press('u', .{});
    try testing.expect(h.shows("no changes yet"));
    try h.press('U', .{});
    try h.press('U', .{});
    try testing.expect(h.shows("1 change not applied"));

    // Leaving asks; Esc keeps editing.
    try h.press('2', .{});
    try testing.expectEqual(ui.View.timeline, h.app.state.view);
    try testing.expect(h.app.state.modal.? == .confirm);
    try testing.expect(h.shows("not applied yet"));
    try h.press(K.escape, .{});
    try testing.expect(h.app.state.modal == null);
    try testing.expect(t.editing);
    // So does quitting: ctrl+c twice.
    try h.press('c', .{ .ctrl = true });
    try testing.expect(h.shows("ctrl+c again quits without them"));
    try h.press('j', .{});
    try h.press('k', .{});

    // Drag Build two days later by its body.
    try h.press('j', .{});
    try testing.expectEqualStrings("Build", h.snap().issues[t.selectedIssue().?].title);
    const row_y = for (h.app.state.hits.items.items) |x| {
        if (x.target == .tl_row and x.target.tl_row == t.selected) break x.y;
    } else unreachable;
    const bx: u16 = @intCast(@as(i32, t.chart_x) + t.x(D.parse("2023-11-22").?.toDays()));
    const press: vaxis.Mouse = .{
        .col = @intCast(bx),
        .row = @intCast(row_y),
        .button = .left,
        .mods = .{},
        .type = .press,
    };
    try h.input(.{ .mouse = press });
    var drag = press;
    drag.type = .drag;
    drag.col = @intCast(@as(i32, t.chart_x) + t.x(D.parse("2023-11-24").?.toDays()));
    try h.input(.{ .mouse = drag });
    try testing.expect(
        timeline_view.datesOf(
            &h.app.state,
            h.byTitle("Build").?,
        ).start.?.eql(D.parse("2023-11-22").?),
    );
    var up = drag;
    up.type = .release;
    try h.input(.{ .mouse = up });
    try testing.expect(h.shows("2 changes not applied"));
    try testing.expect(dates(h, "Build")[0].?.eql(D.parse("2023-11-20").?));

    // Build waits for Design, linked in the draft.
    try h.press('b', .{});
    try h.press('k', .{});
    try h.press(K.enter, .{});
    try testing.expect(h.shows("now waits for"));
    // The milestone's due date a week on.
    try h.press('g', .{});
    try h.press('L', .{});
    try testing.expect(h.shows("3 changes not applied"));

    // Apply: a summary, then one write.
    try h.press('s', .{ .ctrl = true });
    try testing.expect(h.app.state.modal.? == .confirm);
    try testing.expect(h.shows("Apply 3 changes?"));
    try testing.expect(h.shows("All of it is written at once"));
    try h.press(K.enter, .{});
    try testing.expect(!t.editing);
    try testing.expect(dates(h, "Design")[1].?.eql(D.parse("2023-11-19").?));
    try testing.expect(dates(h, "Design")[0].?.eql(D.parse("2023-11-14").?));
    try testing.expect(dates(h, "Build")[0].?.eql(D.parse("2023-11-22").?));
    try testing.expect(dates(h, "Build")[1].?.eql(D.parse("2023-11-26").?));
    try testing.expectEqual(@as(usize, 1), h.snap().issues[h.byTitle("Build").?].blocked_by.len);
    try testing.expect(h.snap().milestones[0].due.?.eql(D.parse("2023-12-07").?));
    try testing.expect(h.shows("applied 3 changes"));

    // Changed elsewhere meanwhile: marked, applying refuses until chosen.
    try h.press('E', .{});
    h.app.state.timeline.selected_key = .{ .issue = .{ .id = .of(design.slice()) } };
    try h.draw();
    try h.press(K.right, .{});
    try st.edit(design.slice(), .{ .title = "Design, renamed" });
    try h.draw();
    try testing.expect(h.shows("! 1 changed elsewhere"));
    try h.press('s', .{ .ctrl = true });
    try testing.expect(h.app.state.modal == null);
    try testing.expect(h.shows("r keeps your change"));
    try h.press('r', .{});
    try h.press('s', .{ .ctrl = true });
    try h.press(K.enter, .{});
    try testing.expect(dates(h, "Design, renamed")[0].?.eql(D.parse("2023-11-15").?));

    // Discarding writes nothing.
    try h.press('E', .{});
    try h.press(K.right, .{});
    try h.press(K.escape, .{});
    try testing.expect(h.shows("Discard timeline changes?"));
    try h.press('d', .{});
    try testing.expect(!t.editing);
    try testing.expect(dates(h, "Design, renamed")[0].?.eql(D.parse("2023-11-15").?));

    // Leaving with Apply writes, then goes.
    try h.press('E', .{});
    try h.press(K.right, .{});
    try h.press('1', .{});
    try h.press('a', .{});
    try testing.expectEqual(ui.View.list, h.app.state.view);
    try testing.expect(dates(h, "Design, renamed")[0].?.eql(D.parse("2023-11-16").?));
}

test "every view draws at any size, small or large" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const v1 = try st.createMilestone(
        .{
            .name = "A milestone with a rather long name",
            .due = .parse("2023-11-30"),
            .description = "Line one.\nLine two.",
        },
    );
    const p = try st.create(
        .{
            .title = "A parent issue whose title goes on and on and on",
            .milestone_id = v1.slice(),
        },
    );
    const c = try st.create(.{ .title = "Child", .parent = p.slice() });
    try st.edit(
        c.slice(),
        .{
            .start_date = date("2023-10-01"),
            .due_date = date("2024-03-01"),
            .estimate_minutes = .{ .set = 600 },
        },
    );
    const d = try st.create(.{ .title = "Due only", .milestone_id = v1.slice() });
    try st.edit(d.slice(), .{ .due_date = date("2023-11-20"), .add_blocked_by = &.{c.slice()} });
    _ = try st.create(.{ .title = "Loose" });

    var big = try vaxis.Screen.init(
        testing.allocator,
        .{ .rows = 70, .cols = 260, .x_pixel = 0, .y_pixel = 0 },
    );
    defer big.deinit(testing.allocator);
    const sizes = [_][2]u16{
        .{ 20, 6 },
        .{ 24, 8 },
        .{ 40, 12 },
        .{ 60, 16 },
        .{ 80, 24 },
        .{ 100, 30 },
        .{ 260, 70 },
    };
    const views = [_]u8{ '1', '2', '3', '4' };
    for (views) |v| {
        try h.press(v, .{});
        for (sizes) |sz| {
            const w: ui.Window = .{
                .x_off = 0,
                .y_off = 0,
                .parent_x_off = 0,
                .parent_y_off = 0,
                .width = sz[0],
                .height = sz[1],
                .screen = &big,
            };
            try h.app.draw(w, @divFloor(h.now_ms, 1000));
            // Scrolled far away and zoomed, and with each modal kind.
            if (v == '4') {
                for (0..3) |_| try h.app.draw(w, @divFloor(h.now_ms, 1000));
                h.app.state.timeline.scrollDays(10_000);
                try h.app.draw(w, @divFloor(h.now_ms, 1000));
                h.app.state.timeline.scrollDays(-20_000);
                try h.app.draw(w, @divFloor(h.now_ms, 1000));
                h.app.state.timeline.center_on = h.app.state.today.toDays();
            }
        }
    }
    // The milestone view, split, and the timeline in edit mode.
    try h.press('3', .{});
    try h.press(K.enter, .{});
    try h.press('v', .{});
    for (sizes) |sz| {
        const w: ui.Window = .{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = sz[0],
            .height = sz[1],
            .screen = &big,
        };
        try h.app.draw(w, @divFloor(h.now_ms, 1000));
    }
    try h.press('4', .{});
    try h.press('E', .{});
    try h.press('j', .{});
    try h.press(K.right, .{});
    for ([_]u8{ 'z', 'z', 'Z', 'Z', 'Z' }) |z| {
        try h.press(z, .{});
        for (sizes) |sz| {
            const w: ui.Window = .{
                .x_off = 0,
                .y_off = 0,
                .parent_x_off = 0,
                .parent_y_off = 0,
                .width = sz[0],
                .height = sz[1],
                .screen = &big,
            };
            try h.app.draw(w, @divFloor(h.now_ms, 1000));
        }
    }
    try h.press('s', .{ .ctrl = true });
    for (sizes) |sz| {
        const w: ui.Window = .{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = sz[0],
            .height = sz[1],
            .screen = &big,
        };
        try h.app.draw(w, @divFloor(h.now_ms, 1000));
    }
}

test "timeline edit mode: a row dragged onto another milestone's group" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const v1 = try st.createMilestone(.{ .name = "v1", .due = .parse("2023-11-30") });
    const v2 = try st.createMilestone(.{ .name = "v2", .due = .parse("2023-12-30") });
    const a = try st.create(.{ .title = "Work", .milestone_id = v1.slice() });
    try st.edit(a.slice(), .{ .due_date = date("2023-11-20") });
    _ = try st.create(.{ .title = "Other", .milestone_id = v2.slice() });
    try h.press('4', .{});
    try h.press('E', .{});
    const t = &h.app.state.timeline;
    const hit = struct {
        fn row(hh: *Harness, kind: timeline_view.Row.Kind, what: []const u8) ui.Hit {
            const tl = &hh.app.state.timeline;
            for (hh.app.state.hits.items.items) |x| {
                if (x.target != .tl_row) continue;
                const r = tl.rows[x.target.tl_row];
                if (r.kind != kind) continue;
                const name = if (kind == .group)
                    hh.snap().milestones[tl.groups[r.group].milestone.?].name
                else
                    hh.snap().issues[r.issue].title;
                if (std.mem.eql(u8, name, what)) return x;
            }
            unreachable;
        }
    }.row;
    const from = hit(h, .issue, "Work");
    const to = hit(h, .group, "v2");
    const press: vaxis.Mouse = .{
        .col = @intCast(from.x + 6),
        .row = @intCast(from.y),
        .button = .left,
        .mods = .{},
        .type = .press,
    };
    // Over v2, then off the rows to the top bar: letting go there cancels.
    {
        try h.input(.{ .mouse = press });
        var off = press;
        off.type = .drag;
        off.row = @intCast(to.y);
        try h.input(.{ .mouse = off });
        off.row = 0;
        try h.input(.{ .mouse = off });
        off.type = .release;
        try h.input(.{ .mouse = off });
        try testing.expectEqual(@as(usize, 0), t.changes());
    }
    try h.input(.{ .mouse = press });
    var drag = press;
    drag.type = .drag;
    drag.row = @intCast(to.y);
    try h.input(.{ .mouse = drag });
    var up = drag;
    up.type = .release;
    try h.input(.{ .mouse = up });
    try testing.expect(h.shows("(staged)"));
    try testing.expectEqual(@as(usize, 1), t.changes());
    // Shown in v2 already; written on apply.
    try testing.expectEqualStrings(v1.slice(), h.snap().proj.milestone[h.byTitle("Work").?].?);
    try h.press('s', .{ .ctrl = true });
    try h.press(K.enter, .{});
    try testing.expectEqualStrings(v2.slice(), h.snap().proj.milestone[h.byTitle("Work").?].?);
}

test "timeline edit mode: its keys come first, writes at once are refused" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const v1 = try st.createMilestone(.{ .name = "v1", .due = .parse("2023-11-30") });
    const design = try st.create(.{ .title = "Design", .milestone_id = v1.slice() });
    try h.setDates(design.slice(), "2023-11-13", "2023-11-17");
    try h.press('4', .{});
    const t = &h.app.state.timeline;
    try h.press('j', .{});
    try h.press('E', .{});
    // The start, due and estimate prompts, not the sort menu.
    for ([_]struct {
        u21,
        []const u8,
    }{ .{ 's', "Start of #" }, .{ 'd', "Due of #" }, .{ 'e', "Estimate of #" } }) |x| {
        try h.press(x[0], .{});
        try testing.expect(h.app.state.modal.? == .prompt);
        try testing.expect(h.shows(x[1]));
        try h.press(K.escape, .{});
        try testing.expect(h.app.state.modal == null);
    }
    // Creating writes at once: refused, like closing.
    const before = h.snap().issues.len;
    for ([_]u21{ 'n', 'a', 'x' }) |c| {
        try h.press(c, .{});
        try testing.expect(h.app.state.modal == null);
        try testing.expect(h.shows("writes at once"));
    }
    try testing.expectEqual(before, h.snap().issues.len);
    try testing.expect(!h.snap().isDone(h.byTitle("Design").?));
    // Sort and scope stay as they are.
    const q = h.app.state.tl_query;
    try h.press('S', .{});
    try h.press('f', .{});
    try testing.expectEqual(q.scope, h.app.state.tl_query.scope);
    try testing.expectEqual(q.reverse, h.app.state.tl_query.reverse);
    // ctrl+r reloads; U redoes.
    try h.press(K.right, .{});
    try h.press('u', .{});
    try h.press('r', .{ .ctrl = true });
    try testing.expectEqual(@as(usize, 0), t.changes());
    try h.press('U', .{});
    try testing.expectEqual(@as(usize, 1), t.changes());
    // Esc with a filter set: out of linking, then out of edit mode,
    // asking; the filter stays.
    try h.press('/', .{});
    try h.typeText("Design");
    try h.press(K.enter, .{});
    try h.press('b', .{});
    try testing.expect(t.linking != null);
    try h.press(K.escape, .{});
    try testing.expect(t.linking == null and t.editing);
    try h.press(K.escape, .{});
    try testing.expect(h.shows("Discard timeline changes?"));
    try testing.expectEqualStrings("Design", h.app.state.tl_search.text());
    try h.press('d', .{});
    try testing.expect(!t.editing);
}

test "timeline: an issue shown in two groups, each row reachable" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const v1 = try st.createMilestone(.{ .name = "v1", .due = .parse("2023-11-30") });
    const v2 = try st.createMilestone(.{ .name = "v2", .due = .parse("2023-12-30") });
    const p = try st.create(.{ .title = "Parent", .milestone_id = v1.slice() });
    try h.setDates(p.slice(), "2023-11-13", "2023-11-17");
    const c = try st.create(.{ .title = "Child", .parent = p.slice(), .milestone_id = v2.slice() });
    try h.setDates(c.slice(), "2023-11-20", "2023-11-24");
    try h.press('4', .{});
    const t = &h.app.state.timeline;
    // v1, Parent, v2, Parent (above its child), Child.
    try testing.expectEqual(@as(usize, 5), t.rows.len);
    try testing.expect(t.rows[3].context);
    try h.press('g', .{});
    for (1..5) |n| {
        try h.press('j', .{});
        try testing.expectEqual(@as(u32, @intCast(n)), t.selected);
    }
    try testing.expectEqualStrings("Child", h.snap().issues[t.selectedIssue().?].title);
    try h.press('k', .{});
    try testing.expectEqual(@as(u32, 3), t.selected);
    try h.press('[', .{});
    try testing.expectEqual(@as(u32, 2), t.selected);
}

test "timeline edit mode: an issue deleted between the question and applying stops it" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const a = try st.create(.{ .title = "A" });
    const b = try st.create(.{ .title = "B" });
    for ([_]store_mod.Id{ a, b }) |id| try st.edit(
        id.slice(),
        .{
            .start_date = date("2023-11-20"),
            .due_date = date("2023-11-24"),
        },
    );
    try h.press('4', .{});
    try h.press('E', .{});
    for ([_]store_mod.Id{ a, b }) |id| {
        h.app.state.timeline.selected_key = .{ .issue = .{ .id = id } };
        try h.draw();
        try h.press('l', .{});
    }
    try testing.expectEqual(@as(usize, 2), h.app.state.timeline.changes());
    try h.press('s', .{ .ctrl = true });
    try testing.expect(h.shows("Apply 2 changes?"));
    // Deleted elsewhere while the question is open.
    const repo = issuez.Repo(GitSim).init(&h.sim);
    const ref = try std.fmt.allocPrint(
        h.arena_state.allocator(),
        "{s}{s}",
        .{ issuez.engine.issue_ref_prefix, b.slice() },
    );
    _ = try repo.setDeleted(h.arena_state.allocator(), ref, .{}, .{});
    try st.reload();
    try h.press(K.enter, .{});
    try testing.expect(h.shows("deleted elsewhere"));
    // Nothing written: A is as it was, and its change still staged.
    try testing.expect(
        issuez.schedule.Dates.of(
            &h.snap().issues[h.byTitle("A").?],
        ).start.?.eql(D.parse("2023-11-20").?),
    );
    try testing.expectEqual(@as(usize, 1), h.app.state.timeline.changes());
}

test "timeline edit mode: a bar changed elsewhere while held is staged stale" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const v1 = try st.createMilestone(.{ .name = "v1", .due = .parse("2023-11-30") });
    const build = try st.create(.{ .title = "Build", .milestone_id = v1.slice() });
    try h.setDates(build.slice(), "2023-11-20", "2023-11-24");
    try h.press('4', .{});
    const t = &h.app.state.timeline;
    try h.press('j', .{});
    try h.press('E', .{});
    const y = for (h.app.state.hits.items.items) |x| {
        if (x.target == .tl_row and x.target.tl_row == t.selected) break x.y;
    } else unreachable;
    const at = @as(i32, t.chart_x) + t.x(D.parse("2023-11-22").?.toDays());
    var m: vaxis.Mouse = .{
        .col = @intCast(at),
        .row = @intCast(y),
        .button = .left,
        .mods = .{},
        .type = .press,
    };
    try h.input(.{ .mouse = m });
    // Someone moves Build's due date while it is held.
    try st.edit(build.slice(), .{ .due_date = date("2023-11-28") });
    try h.draw();
    m.type = .drag;
    m.col = @intCast(@as(i32, t.chart_x) + t.x(D.parse("2023-11-24").?.toDays()));
    try h.input(.{ .mouse = m });
    m.type = .release;
    try h.input(.{ .mouse = m });
    try testing.expectEqual(@as(usize, 1), t.changes());
    try h.draw();
    // Applying asks first rather than overwriting their date.
    try h.press('s', .{ .ctrl = true });
    try testing.expect(h.shows("r keeps your change"));
    const written = issuez.schedule.Dates.of(&h.snap().issues[h.byTitle("Build").?]);
    try testing.expect(written.due.?.eql(D.parse("2023-11-28").?));
}

test "timeline edit mode: drags across a reload and after leaving" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const v1 = try st.createMilestone(.{ .name = "v1", .due = .parse("2023-11-30") });
    const build = try st.create(.{ .title = "Build", .milestone_id = v1.slice() });
    try h.setDates(build.slice(), "2023-11-20", "2023-11-24");
    try h.press('4', .{});
    const t = &h.app.state.timeline;
    try h.press('j', .{});
    try h.press('E', .{});
    const grab = struct {
        fn f(hh: *Harness) !vaxis.Mouse {
            const tl = &hh.app.state.timeline;
            const y = for (hh.app.state.hits.items.items) |x| {
                if (x.target == .tl_row and x.target.tl_row == tl.selected) break x.y;
            } else unreachable;
            const bx = @as(i32, tl.chart_x) + tl.x(D.parse("2023-11-22").?.toDays());
            const m: vaxis.Mouse = .{
                .col = @intCast(bx),
                .row = @intCast(y),
                .button = .left,
                .mods = .{},
                .type = .press,
            };
            try hh.input(.{ .mouse = m });
            return m;
        }
    }.f;
    const later = @as(i32, t.chart_x) + t.x(D.parse("2023-11-24").?.toDays());

    // Held while others write: what is let go of lands on Build still.
    var m = try grab(h);
    const was = h.byTitle("Build").?;
    var others: [3]store_mod.Id = undefined;
    for (&others) |*o| {
        o.* = try st.create(.{ .title = "Other", .milestone_id = v1.slice() });
        try h.setDates(o.slice(), "2023-11-06", "2023-11-08");
    }
    try h.draw();
    // Elsewhere in the snapshot now.
    try testing.expect(h.byTitle("Build").? != was);
    m.type = .drag;
    m.col = @intCast(later);
    try h.input(.{ .mouse = m });
    m.type = .release;
    try h.input(.{ .mouse = m });
    try testing.expectEqual(@as(usize, 1), t.changes());
    try testing.expect(
        timeline_view.datesOf(
            &h.app.state,
            h.byTitle("Build").?,
        ).start.?.eql(D.parse("2023-11-22").?),
    );
    for (others) |o| {
        const i = h.snap().find(o.slice()).?;
        try testing.expect(
            timeline_view.datesOf(&h.app.state, i).start.?.eql(D.parse("2023-11-06").?),
        );
    }

    // A drag that comes back stages nothing.
    t.selected_key = .{ .issue = .{ .id = build } };
    try h.draw();
    m = try grab(h);
    m.type = .drag;
    m.col = @intCast(later);
    try h.input(.{ .mouse = m });
    m.col = @intCast(@as(i32, t.chart_x) + t.x(D.parse("2023-11-24").?.toDays() - 2));
    try h.input(.{ .mouse = m });
    m.type = .release;
    try h.input(.{ .mouse = m });
    try testing.expectEqual(@as(usize, 1), t.draft.len);

    // Esc while holding: edit mode ends, letting go stages nothing.
    try h.press('u', .{});
    try testing.expectEqual(@as(usize, 0), t.changes());
    m = try grab(h);
    m.type = .drag;
    m.col = @intCast(later);
    try h.input(.{ .mouse = m });
    try h.press(K.escape, .{});
    try testing.expect(!t.editing and t.bar_drag == null);
    m.type = .release;
    try h.input(.{ .mouse = m });
    try h.press('E', .{});
    try testing.expectEqual(@as(usize, 0), t.draft.len);
}

test "timeline edit mode: a bar the wrong way round still moves" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const odd = try st.create(.{ .title = "Odd" });
    try h.setDates(odd.slice(), "2023-11-24", "2023-11-20");
    try h.press('4', .{});
    const t = &h.app.state.timeline;
    try h.press('j', .{});
    try h.press('E', .{});
    try h.press('l', .{});
    try testing.expectEqual(@as(usize, 1), t.changes());
    const i = h.byTitle("Odd").?;
    try testing.expect(timeline_view.datesOf(&h.app.state, i).due.?.eql(D.parse("2023-11-21").?));
    // Its left end is its due date: dragging it moves that.
    const y = for (h.app.state.hits.items.items) |x| {
        if (x.target == .tl_row and x.target.tl_row == t.selected) break x.y;
    } else unreachable;
    var m: vaxis.Mouse = .{
        .col = @intCast(@as(i32, t.chart_x) + t.x(D.parse("2023-11-21").?.toDays())),
        .row = @intCast(y),
        .button = .left,
        .mods = .{},
        .type = .press,
    };
    try h.input(.{ .mouse = m });
    m.type = .drag;
    m.col = @intCast(@as(i32, t.chart_x) + t.x(D.parse("2023-11-17").?.toDays()));
    try h.input(.{ .mouse = m });
    m.type = .release;
    try h.input(.{ .mouse = m });
    const d = timeline_view.datesOf(&h.app.state, i);
    try testing.expect(d.due.?.eql(D.parse("2023-11-17").?));
    try testing.expect(d.start.?.eql(D.parse("2023-11-25").?));
    // Unsaved text and the draft: one warning names both.
    try h.press('s', .{});
    try h.typeText("x");
    try h.press('c', .{ .ctrl = true });
    try testing.expect(h.shows("unsaved text and 1 timeline changes"));
}

test "timeline edit mode: q on a terminal too small keeps a draft" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const design = try st.create(.{ .title = "Design" });
    try h.setDates(design.slice(), "2023-11-13", "2023-11-17");
    try h.press('4', .{});
    try h.press('j', .{});
    try h.press('E', .{});
    try h.press(K.right, .{});
    var tiny = try vaxis.Screen.init(
        testing.allocator,
        .{ .rows = 5, .cols = 20, .x_pixel = 0, .y_pixel = 0 },
    );
    defer tiny.deinit(testing.allocator);
    const w: ui.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 20,
        .height = 5,
        .screen = &tiny,
    };
    try h.app.draw(w, @divFloor(h.now_ms, 1000));
    try testing.expect(h.app.state.too_small);
    const q: State.Input = .{ .key = .{ .codepoint = 'q', .text = "q" } };
    try testing.expect(try h.app.handle(q, h.now_ms));
    try testing.expect(std.mem.find(u8, h.app.state.status(), "larger") != null);
    try testing.expect(h.app.state.timeline.editing);
    // Without changes it quits.
    h.app.state.timeline.draft.clear();
    try testing.expect(!try h.app.handle(q, h.now_ms));
}

test "timeline edit mode: the rows without dates fold, warnings follow a staged move" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const v1 = try st.createMilestone(.{ .name = "v1", .due = .parse("2023-11-30") });
    const v2 = try st.createMilestone(.{ .name = "v2", .due = .parse("2023-12-30") });
    const late = try st.create(.{ .title = "Late", .milestone_id = v1.slice() });
    try h.setDates(late.slice(), "2023-11-27", "2023-12-05");
    _ = try st.create(.{ .title = "Someday", .milestone_id = v1.slice() });
    try h.press('4', .{});
    const t = &h.app.state.timeline;
    try h.press('E', .{});
    // ⏎ on "1 without dates" shows them.
    const unscheduled = for (t.rows, 0..) |r, i| {
        if (r.kind == .unscheduled) break i;
    } else unreachable;
    t.selected_key = .{ .unscheduled = t.groups[t.rows[unscheduled].group].scope };
    try h.draw();
    try testing.expect(!h.shows("Someday"));
    try h.press(K.enter, .{});
    try testing.expect(h.shows("Someday"));

    // Ends after v1 is due; staged into v2 it fits.
    const i = h.byTitle("Late").?;
    var buf: [4]issuez.schedule.Warning = undefined;
    try testing.expectEqual(@as(usize, 1), timeline_view.warningsOf(&h.app.state, i, &buf).len);
    try testing.expect(
        timeline_edit.stage(&h.app.state, .{ .milestone = .{ .id = late, .link = .{ .id = v2 } } }),
    );
    try h.draw();
    try testing.expectEqual(@as(usize, 0), timeline_view.warningsOf(&h.app.state, i, &buf).len);
}

test "milestone view: add existing issues with a search, move with one" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const v1 = try st.createMilestone(.{ .name = "v1" });
    const v2 = try st.createMilestone(.{ .name = "v2" });
    _ = try st.create(.{ .title = "Login page" });
    _ = try st.create(.{ .title = "Logout button" });
    _ = try st.create(.{ .title = "Elsewhere", .milestone_id = v2.slice() });
    _ = try st.create(.{ .title = "Already in v1", .milestone_id = v1.slice() });
    try h.draw();
    h.app.state.openMilestone(.{ .id = v1 });
    try h.draw();

    // + lists what isn't in v1, with where it is now.
    try h.press('+', .{});
    var p = &h.app.state.modal.?.picker;
    try testing.expectEqual(@as(usize, 3), p.items.len);
    try testing.expect(h.shows("Add issues to v1"));
    try testing.expect(h.shows("no milestone"));
    // Filter, mark both "Log" ones with tab, add them in one go.
    try h.typeText("log");
    try testing.expect(h.shows("2 of 3"));
    try h.press(K.tab, .{});
    try h.press(K.tab, .{});
    p = &h.app.state.modal.?.picker;
    try testing.expect(h.shows("Add 2"));
    try h.press(K.enter, .{});
    try testing.expect(h.app.state.modal == null);
    try testing.expect(h.shows("moved 2 issues to v1"));
    try testing.expectEqual(@as(usize, 3), h.app.state.milestone.panes[0].rows.len);
    // One from another milestone, by clicking it.
    try h.click(.{ .command = .ms_add });
    try h.typeText("else");
    try h.click(.{ .modal = .{ .choice = 0 } });
    try testing.expectEqualStrings(v1.slice(), h.snap().proj.milestone[h.byTitle("Elsewhere").?].?);

    // m: out to another milestone, typed.
    h.app.state.milestone.panes[0].selected_id = .of(h.snap().issues[h.byTitle("Login page").?].id);
    try h.draw();
    try h.click(.{ .command = .ms_move });
    try testing.expect(h.shows("Move #"));
    try h.typeText("v2");
    try h.press(K.enter, .{});
    try testing.expectEqualStrings(
        v2.slice(),
        h.snap().proj.milestone[h.byTitle("Login page").?].?,
    );
    // And to none.
    h.app.state.milestone.panes[0].selected_id = .of(
        h.snap().issues[h.byTitle("Logout button").?].id,
    );
    try h.draw();
    try h.press('m', .{});
    try h.typeText("no mile");
    try h.press(K.enter, .{});
    try testing.expect(h.snap().proj.milestone[h.byTitle("Logout button").?] == null);
    // Esc clears the filter first, then closes.
    try h.press('+', .{});
    try h.typeText("zzz");
    try testing.expect(h.shows("nothing matches"));
    try h.press(K.escape, .{});
    try testing.expect(h.app.state.modal != null);
    try h.press(K.escape, .{});
    try testing.expect(h.app.state.modal == null);
}

test "help: keys scroll it, a few close it" {
    const h = try Harness.create();
    defer h.destroy();
    try h.press('?', .{});
    try testing.expect(h.shows("Everywhere"));
    try testing.expect(!h.shows("has:due"));
    // G to the end, g back, j a line, space a page.
    try h.press('G', .{});
    try testing.expect(h.shows("has:due"));
    try testing.expect(!h.shows("Everywhere"));
    try h.press('g', .{});
    try testing.expectEqual(@as(u16, 0), h.app.state.modal.?.help.scroll);
    try h.press('j', .{});
    try testing.expectEqual(@as(u16, 1), h.app.state.modal.?.help.scroll);
    try h.press(K.space, .{});
    const rows = h.app.state.modal.?.help.rows;
    try testing.expectEqual(rows, h.app.state.modal.?.help.scroll);
    try h.press(K.page_up, .{});
    try h.press('k', .{});
    try testing.expectEqual(@as(u16, 0), h.app.state.modal.?.help.scroll);
    // Other keys do nothing; esc, q, ? and enter close.
    try h.press('x', .{});
    try testing.expect(h.app.state.modal != null);
    try h.press(K.escape, .{});
    try testing.expect(h.app.state.modal == null);
    for ([_]u21{ 'q', '?', K.enter }) |cp| {
        try h.press('?', .{});
        try h.press(cp, .{});
        try testing.expect(h.app.state.modal == null);
    }
}

test "confirm: the opening key again, or a shared first letter, answers nothing" {
    const h = try Harness.create();
    defer h.destroy();
    _ = try h.app.store.createMilestone(.{ .name = "Empty" });
    try h.press('3', .{});
    const Status = issuez.format.fields.MilestoneStatus;
    // c c: Complete and Cancel both start with c, and c opened it.
    try h.press('c', .{});
    try h.press('c', .{});
    try h.press('C', .{});
    try testing.expect(h.app.state.modal.? == .confirm);
    try testing.expectEqual(Status.open, h.snap().milestones[0].status);
    try h.press(K.escape, .{});
    // R R, or r: R opened it.
    try h.press('R', .{});
    try h.press('R', .{});
    try h.press('r', .{});
    try testing.expect(h.app.state.modal.? == .confirm);
    try testing.expectEqual(Status.open, h.snap().milestones[0].status);
    try h.press(K.enter, .{});
    try testing.expectEqual(Status.retired, h.snap().milestones[0].status);

    // Opened otherwise: a letter only one answer starts with picks it.
    modal.openConfirm(&h.app.state, "Which?", &.{}, &.{
        .{ .label = "Keep", .action = .none },
        .{ .label = "Kill", .action = .reload },
        .{ .label = "Back", .action = .none },
    });
    try h.draw();
    try h.press('k', .{});
    try testing.expect(h.app.state.modal != null);
    try h.press('b', .{});
    try testing.expect(h.app.state.modal == null);
}

test "a milestone confirm saves once told the milestone changed meanwhile" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const id = try st.createMilestone(.{ .name = "M" });
    try h.press('3', .{});
    try h.click(.{ .ms_scope = .all });
    const Status = issuez.format.fields.MilestoneStatus;
    for ([_]struct { u21, Status }{ .{ 'c', .completed }, .{ 'R', .retired } }) |c| {
        if (h.snap().milestones[0].status != .open) try st.editMilestone(
            id.slice(),
            .{ .status = .open },
        );
        try h.draw();
        try h.press(c[0], .{});
        try testing.expect(h.app.state.modal.? == .confirm);
        try st.editMilestone(id.slice(), .{ .description = "theirs" });
        try h.draw();
        try h.press(K.enter, .{});
        try testing.expect(h.shows("changed meanwhile"));
        try testing.expect(h.app.state.modal.? == .confirm);
        try testing.expectEqual(Status.open, h.snap().milestones[0].status);
        try h.press(K.enter, .{});
        try testing.expect(h.app.state.modal == null);
        try testing.expectEqual(c[1], h.snap().milestones[0].status);
        try st.editMilestone(id.slice(), .{ .description = "" });
    }
}

test "a milestone edited in the form after it changed meanwhile keeps theirs" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const id = try st.createMilestone(.{ .name = "Draft" });
    try h.press('3', .{});
    try h.press('e', .{});
    try h.typeText(" 2");
    try st.editMilestone(id.slice(), .{ .description = "theirs" });
    try h.draw();
    try h.press('s', .{ .ctrl = true });
    try testing.expect(h.shows("changed meanwhile"));
    try testing.expect(h.app.state.modal.? == .milestone_form);
    try testing.expectEqualStrings("Draft", h.snap().milestones[0].name);
    try h.press('s', .{ .ctrl = true });
    try testing.expect(h.app.state.modal == null);
    try testing.expectEqualStrings("Draft 2", h.snap().milestones[0].name);
    try testing.expectEqualStrings("theirs", h.snap().milestones[0].description);
}

test "picker: marks aren't dropped without asking; moving the cursor keeps the row" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    const v1 = try st.createMilestone(.{ .name = "v1" });
    _ = try st.create(.{ .title = "Login" });
    _ = try st.create(.{ .title = "Logout" });
    _ = try st.create(.{ .title = "Other" });
    h.app.state.openMilestone(.{ .id = v1 });
    try h.draw();
    try h.press('+', .{});
    try h.typeText("l");
    try h.press(K.down, .{});
    try h.press(K.left, .{});
    try testing.expectEqual(@as(u32, 1), h.app.state.modal.?.picker.selected);
    try h.press(K.right, .{});
    try h.typeText("o");
    try testing.expectEqual(@as(u32, 0), h.app.state.modal.?.picker.selected);
    // Esc clears the filter first; with marks it asks, then drops them.
    try h.press(K.tab, .{});
    try h.press(K.escape, .{});
    try testing.expect(h.app.state.modal != null);
    try h.press(K.escape, .{});
    try testing.expect(h.shows("1 marked: press esc again"));
    try testing.expect(h.app.state.modal != null);
    try h.press(K.escape, .{});
    try testing.expect(h.app.state.modal == null);
    // A click beside it asks too, and so does ctrl+c.
    try h.press('+', .{});
    try h.press(K.tab, .{});
    const beside: vaxis.Mouse = .{
        .col = 0,
        .row = 1,
        .button = .left,
        .mods = .{},
        .type = .press,
    };
    try h.input(.{ .mouse = beside });
    try testing.expect(h.app.state.modal != null);
    try h.input(.{ .mouse = beside });
    try testing.expect(h.app.state.modal == null);
    try h.press('+', .{});
    try h.press(K.tab, .{});
    const ctrl_c: State.Input = .{ .key = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } };
    try testing.expect(try h.app.handle(ctrl_c, h.now_ms));
    try testing.expect(h.app.state.modal != null);
    try h.press(K.enter, .{});
    try testing.expect(h.shows("moved"));

    // A click doesn't mark what can't be chosen.
    const a = h.app.state.modalArena();
    const items = try a.dupe(modal.Picker.Item, &.{
        .{ .label = "one", .value = "1" },
        .{ .label = "two", .value = "2", .disabled = true },
    });
    h.app.state.openModal(
        .{
            .picker = .{
                .title = "Pick",
                .items = items,
                .multi = true,
                .purpose = .{ .add_to = .none },
                .verb = "Add",
            },
        },
    );
    try h.draw();
    try h.press(K.tab, .{});
    try h.click(.{ .modal = .{ .choice = 1 } });
    try testing.expect(!h.app.state.modal.?.picker.items[1].marked);
    h.app.state.closeModal();
}

test "a prompt is unsaved only when its text differs from what it opened with" {
    const h = try Harness.create();
    defer h.destroy();
    const id = try h.app.store.create(.{ .title = "One" });
    try h.draw();
    const ctrl_c: State.Input = .{ .key = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } };
    // Fresh, but filled in: nothing typed yet.
    modal.openPrompt(&h.app.state, "Due", "", "2026-01-01", .{ .stage_ms_due = id }, true);
    try testing.expect(!h.app.state.modal.?.unsaved());
    try h.typeText("x");
    try testing.expect(h.app.state.modal.?.unsaved());
    // Rebased: still what it opened with.
    modal.editTitle(&h.app.state, h.byTitle("One").?);
    h.app.state.rebaseModal();
    try testing.expect(!try h.app.handle(ctrl_c, h.now_ms));
}

test "menus: a letter jumps by its first character, j and k still move" {
    const h = try Harness.create();
    defer h.destroy();
    const st = &h.app.store;
    _ = try st.createMilestone(.{ .name = "Über" });
    _ = try st.createMilestone(.{ .name = "alpha" });
    _ = try st.createMilestone(.{ .name = "Beta" });
    _ = try st.create(.{ .title = "One" });
    try h.draw();
    modal.editField(&h.app.state, h.byTitle("One").?, .milestone);
    try h.draw();
    const label = struct {
        fn of(hh: *Harness) []const u8 {
            const m = hh.app.state.modal.?.menu;
            return m.options[m.selected].label;
        }
    }.of;
    try h.press('b', .{});
    try testing.expectEqualStrings("Beta", label(h));
    try h.input(.{ .key = .{ .codepoint = 'Ü', .text = "Ü" } });
    try testing.expectEqualStrings("Über", label(h));
    try h.press('A', .{});
    try testing.expectEqualStrings("alpha", label(h));
    const at = h.app.state.modal.?.menu.selected;
    try h.press('j', .{});
    try testing.expectEqual(at + 1, h.app.state.modal.?.menu.selected);
    try h.press('k', .{});
    try testing.expectEqual(at, h.app.state.modal.?.menu.selected);
}

test "sync: y brings in what the remote has and pushes ours; the badge counts" {
    const h = try Harness.createRemote();
    defer h.destroy();
    const a = h.arena_state.allocator();
    const mine = try h.app.store.create(.{ .title = "Made here" });
    try h.draw();
    try testing.expect(h.shows("⇅ origin ↑1"));
    try testing.expect(h.shows("↑")); // in the list
    try testing.expect(h.app.state.snap.remote.isUnpushed(mine.slice()));
    // Someone pushed one meanwhile.
    const hub = try h.hub();
    const theirs = try issuez.Repo(GitSim).init(hub).create(a, .{ .title = "Made elsewhere" }, .{});
    try hub.commit();

    try h.press('/', .{});
    try h.typeText("is:unpushed");
    try h.press(K.enter, .{});
    try testing.expectEqual(@as(usize, 1), h.app.state.list.rows.len);
    try h.press(K.escape, .{});

    try h.press('y', .{});
    try testing.expect(h.app.state.sync.running == null);
    try testing.expect(h.shows("synced with origin: 1 in, 1 out"));
    try testing.expect(h.shows("Made elsewhere"));
    try testing.expect(h.shows("⇅ origin ✓"));
    try testing.expect(h.snap().find(theirs.id) != null);
    // On the remote now.
    try h.sim.commit();
    const after = try h.hub();
    try testing.expect(
        try after.resolveRef(try std.fmt.allocPrint(a, "refs/issues/{s}", .{mine.slice()})) != null,
    );

    // Changed after: unpushed, and the detail view says so.
    try h.app.store.edit(mine.slice(), .{ .title = "Made here, renamed" });
    h.app.state.openIssue(mine.slice());
    try h.draw();
    try testing.expect(h.shows("these changes aren't on origin yet"));
}

test "sync: no remote says how to add one" {
    const h = try Harness.create();
    defer h.destroy();
    try testing.expect(h.shows("⇅ no remote"));
    try h.press('y', .{});
    try testing.expect(h.shows("no remote: add one with git remote add"));
    try h.click(.{ .command = .sync_panel });
    try testing.expect(h.app.state.modal == null);
}

test "sync panel: conflicts jump to the field, quarantines are kept or taken" {
    const h = try Harness.createRemote();
    defer h.destroy();
    const a = h.arena_state.allocator();
    const st = &h.app.store;
    const contested = try st.create(.{ .title = "Contested", .priority = .low });
    const doubled = try st.create(.{ .title = "Doubled" });
    try h.press('y', .{});
    try h.sim.commit();

    // The remote: a concurrent priority, and an unrelated history under
    // Doubled's ID.
    var hub = try h.hub();
    const ref = struct {
        fn f(al: std.mem.Allocator, id: []const u8) []const u8 {
            return std.fmt.allocPrint(al, "refs/issues/{s}", .{id}) catch unreachable;
        }
    }.f;
    _ = try issuez.Repo(
        GitSim,
    ).init(hub).edit(a, ref(a, contested.slice()), .{ .priority = .{ .set = .high } }, .{});
    const repo = issuez.Repo(GitSim).init(hub);
    const foreign = try repo.writeCommit(
        a,
        &.{},
        try repo.identity(a, null),
        "Doubled elsewhere\n\nState: open\nFormat-Version: 1\n",
    );
    const old = (try hub.resolveRef(ref(a, doubled.slice()))).?;
    try hub.updateRefs(
        &.{
            .{
                .name = ref(a, doubled.slice()),
                .op = .{ .update = .{ .new = foreign, .old = old } },
            },
        },
    );
    try hub.commit();
    try h.reopen();

    try st.edit(contested.slice(), .{ .priority = .{ .set = .critical } });
    try h.press('y', .{});
    try testing.expect(h.shows("1 quarantined"));
    try testing.expect(h.shows("1 in conflict (Y)"));
    try testing.expect(h.shows("!1"));
    try testing.expect(h.shows("✕1"));

    try h.press('Y', .{});
    const p = &h.app.state.modal.?.sync_panel;
    try testing.expect(h.shows("Quarantined (1)"));
    try testing.expect(h.shows("remote issue has unrelated history"));
    try testing.expect(h.shows("In conflict (1)"));
    try testing.expect(h.shows("Priority: kept"));
    // To the quarantined row, keep ours.
    while (p.rows[p.selected] != .quarantined) try h.press(K.down, .{});
    try h.press('l', .{});
    try testing.expect(h.app.state.modal.? == .confirm);
    try h.press(K.enter, .{});
    try testing.expect(h.app.state.modal.? == .sync_panel);
    try testing.expect(h.shows("kept local"));
    // The panel opened again on the same row; j and k move.
    const p2 = &h.app.state.modal.?.sync_panel;
    try testing.expect(p2.rows[p2.selected] == .quarantined);
    try h.press('j', .{});
    try testing.expect(p2.rows[p2.selected] == .conflict);
    try h.press('k', .{});
    try testing.expect(p2.rows[p2.selected] == .quarantined);
    try testing.expect(h.app.state.modal.? == .sync_panel);
    // The conflict: Enter opens the issue on its priority.
    while (p2.rows[p2.selected] != .conflict) try h.press('j', .{});
    try h.press(K.enter, .{});
    try testing.expectEqual(ui.View.detail, h.app.state.view);
    const focused = h.app.state.detail.items.items[h.app.state.detail.focus];
    try testing.expect(focused == .field and focused.field == .priority);
}

test "sync: quitting while one runs asks first" {
    const h = try Harness.createRemote();
    defer h.destroy();
    h.app.state.sync.running = .sync;
    try h.input(.{ .key = .{ .codepoint = 'q', .text = "q" } });
    try testing.expect(h.shows("q again quits and stops it"));
    h.now_ms += 50;
    try testing.expect(!try h.app.handle(.{ .key = .{ .codepoint = 'q', .text = "q" } }, h.now_ms));
}

test "sync: issue.autoSync fetches and merges on its own, never pushes" {
    const h = try Harness.createRemote();
    defer h.destroy();
    const a = h.arena_state.allocator();
    try h.sim.configAdd("issue.autoSync", "5");
    try h.app.store.reload();
    _ = try h.app.store.create(.{ .title = "Not for pushing" });
    const hub = try h.hub();
    _ = try issuez.Repo(GitSim).init(hub).create(a, .{ .title = "Arrived on its own" }, .{});
    try hub.commit();
    const t0: i64 = 1_700_000_000;
    h.app.tick(t0); // starts the clock
    h.app.tick(t0 + 60);
    try testing.expect(h.snap().issues.len == 1);
    h.app.tick(t0 + 5 * 60);
    try h.draw();
    try testing.expectEqual(@as(usize, 2), h.snap().issues.len);
    try testing.expect(h.shows("fetched from origin: 1 in, 0 out"));
    try testing.expect(h.shows("↑1"));
}

test "sync: push right after a fetch pushes, without fetching again" {
    const h = try Harness.createRemote();
    defer h.destroy();
    try h.press('y', .{});
    try testing.expect(h.app.state.sync.fetched_at > 0);
    try testing.expectEqualStrings("origin", h.app.state.sync.fetchedFrom());
    _ = try h.app.store.create(.{ .title = "After the fetch" });
    try h.draw();
    try h.press('Y', .{});
    try h.press('p', .{});
    try testing.expect(h.shows("pushed to origin: 0 in, 1 out"));
    try testing.expect(h.shows("⇅ origin ✓"));
    // Long after: a push fetches first, and still pushes.
    h.app.state.sync.fetched_at -= 3600;
    _ = try h.app.store.create(.{ .title = "Much later" });
    // The panel stays open, showing what the push did.
    try testing.expect(h.app.state.modal.? == .sync_panel);
    try h.press('p', .{});
    try testing.expect(h.shows("pushed to origin: 0 in, 1 out"));
}

/// The remote gets a history of its own under `ref`, as another process
/// would write it: the next sync quarantines it.
fn rewriteOnHub(h: *Harness, ref: []const u8, message: []const u8) !void {
    const a = h.arena_state.allocator();
    try h.sim.commit();
    const hub = try h.hub();
    const repo = issuez.Repo(GitSim).init(hub);
    const foreign = try repo.writeCommit(a, &.{}, try repo.identity(a, null), message);
    const old = (try hub.resolveRef(ref)).?;
    try hub.updateRefs(&.{.{ .name = ref, .op = .{ .update = .{ .new = foreign, .old = old } } }});
    try hub.commit();
    try h.reopen();
}

test "sync panel: a takes the remote's version of a quarantined issue" {
    const h = try Harness.createRemote();
    defer h.destroy();
    const a = h.arena_state.allocator();
    const doubled = try h.app.store.create(.{ .title = "Doubled" });
    try h.press('y', .{});
    try rewriteOnHub(
        h,
        try std.fmt.allocPrint(a, "refs/issues/{s}", .{doubled.slice()}),
        "Doubled elsewhere\n\nState: open\nFormat-Version: 1\n",
    );
    try h.press('y', .{});
    try testing.expect(h.shows("1 quarantined"));
    try h.press('Y', .{});
    const p = &h.app.state.modal.?.sync_panel;
    while (p.rows[p.selected] != .quarantined) try h.press('j', .{});
    try h.press('a', .{});
    try testing.expect(h.shows("Accept the remote version of"));
    try h.press(K.enter, .{});
    try testing.expect(h.shows("took the remote version"));
    try testing.expect(h.shows("Quarantined (0)"));
    try testing.expectEqualStrings(
        "Doubled elsewhere",
        h.snap().issues[h.snap().find(doubled.slice()).?].title,
    );
}

test "sync panel: a quarantined milestone opens in the milestone view" {
    const h = try Harness.createRemote();
    defer h.destroy();
    const a = h.arena_state.allocator();
    const id = try h.app.store.createMilestone(.{ .name = "Beta" });
    try h.press('y', .{});
    try rewriteOnHub(
        h,
        try std.fmt.allocPrint(a, "refs/milestones/{s}", .{id.slice()}),
        "Beta elsewhere\n\nFormat-Version: 1\n",
    );
    try h.press('y', .{});
    try testing.expect(h.shows("1 quarantined"));
    try h.press('Y', .{});
    try testing.expect(h.shows("milestone Beta"));
    const p = &h.app.state.modal.?.sync_panel;
    while (p.rows[p.selected] != .quarantined) try h.press('j', .{});
    try testing.expect(p.rows[p.selected].quarantined.local);
    try h.press(K.enter, .{});
    try testing.expectEqual(ui.View.milestone, h.app.state.view);
}

test "sync panel: ←→ pick another remote, not while a sync runs" {
    const h = try Harness.createWorld(.{ .seed = 5, .clones = &.{
        .{ .name = "local", .config = &.{
            .{ .key = "remote.origin.url", .value = "sim:hub" },
            .{ .key = "remote.other.url", .value = "sim:other" },
        } },
        .{ .name = "hub" },
        .{ .name = "other" },
    } });
    defer h.destroy();
    try testing.expect(h.shows("⇅ origin"));
    try h.press('Y', .{});
    try h.press(K.right, .{});
    try testing.expectEqualStrings("other", h.snap().remote.name.?);
    try testing.expectEqualStrings("other", h.app.state.modal.?.sync_panel.remote);
    try testing.expect(h.shows("syncs go to other now"));
    try h.press(K.left, .{});
    try testing.expectEqualStrings("origin", h.snap().remote.name.?);
    try h.click(.{ .modal = .{ .option = .{ .field = 0, .option = 1 } } });
    try testing.expectEqualStrings("other", h.snap().remote.name.?);
    try h.press('y', .{});
    try testing.expect(h.shows("synced with other"));

    // While a sync runs: neither a remote switch nor a resolve.
    h.app.state.sync.running = .sync;
    h.app.state.sync.setRunningRemote("other");
    try h.press(K.left, .{});
    try testing.expectEqualStrings("other", h.snap().remote.name.?);
    try testing.expect(h.shows("the sync with other is running"));
    const zeros: [40]u8 = @splat('0');
    try testing.expect(h.app.perform(.{ .resolve = .{ .id = .of(&zeros), .how = .keep_local } }));
    try h.draw();
    try testing.expect(h.shows("the sync with other is running"));
    // The badge names the running one's remote.
    h.app.state.closeModal();
    try h.app.store.chooseRemote("origin");
    try h.draw();
    try testing.expect(h.shows("⇅ other starting…"));
}

test "sync: a sync that can't start says why; an automatic one only in the badge" {
    const h = try Harness.createRemote();
    defer h.destroy();
    const Fake = struct {
        var err: anyerror = error.ConcurrencyUnavailable;
        var calls: u32 = 0;
        fn start(_: *anyopaque, _: []const u8, _: sync_job.Kind, _: bool, _: bool) anyerror!void {
            calls += 1;
            return err;
        }
    };
    var context: u8 = 0;
    h.app.runner = .{ .context = &context, .start = Fake.start };
    try h.press('y', .{});
    try testing.expect(h.app.state.sync.running == null);
    try testing.expect(h.shows("sync with origin couldn't start"));
    try testing.expect(h.shows("⇅ origin ⚠"));
    Fake.err = error.SyncRunning;
    try h.press('y', .{});
    try testing.expect(h.shows("a sync is running already"));

    // Automatic: quietly, and not again at the next tick.
    Fake.err = error.ConcurrencyUnavailable;
    h.app.state.info("", .{});
    try h.sim.configAdd("issue.autoSync", "5");
    try h.app.store.reload();
    const t0: i64 = 1_700_000_000;
    h.app.state.sync.last_at = 0;
    h.app.state.sync.auto_at = 0;
    h.app.tick(t0);
    const before = Fake.calls;
    h.app.tick(t0 + 5 * 60);
    try testing.expectEqual(before + 1, Fake.calls);
    h.app.tick(t0 + 5 * 60 + 15);
    try testing.expectEqual(before + 1, Fake.calls);
    try h.draw();
    try testing.expect(!h.shows("couldn't start"));
    try testing.expect(h.shows("⇅ origin ⚠"));
}

test "sync: an automatic one that fails turns the badge red, and the panel says why" {
    const h = try Harness.createWorld(.{ .clones = &.{
        .{ .name = "local", .config = &.{.{ .key = "remote.origin.url", .value = "sim:nowhere" }} },
    } });
    defer h.destroy();
    try h.sim.configAdd("issue.autoSync", "5");
    try h.app.store.reload();
    const t0: i64 = 1_700_000_000;
    h.app.tick(t0);
    h.app.tick(t0 + 5 * 60);
    try h.draw();
    try testing.expect(!h.shows("failed"));
    try testing.expect(h.shows("⇅ origin ⚠"));
    try h.press('Y', .{});
    try testing.expect(h.shows("fetch and merge with origin failed"));
    // One that fails while the panel is open leaves it red too.
    try h.press('p', .{});
    try testing.expect(h.shows("push with origin failed"));
    try h.press(K.escape, .{});
    try testing.expect(h.shows("⇅ origin ⚠"));
    try h.press('Y', .{});
    try h.press(K.escape, .{});
    try testing.expect(h.shows("⇅ origin ✓"));
}

test "sync: a remote that couldn't be read says why" {
    const h = try Harness.createRemote();
    defer h.destroy();
    h.app.store.snap.remote = .{
        .remotes = &.{"origin"},
        .problem = "git config issue.remote: no such remote",
    };
    try h.draw();
    try testing.expect(h.shows("⇅ remote ⚠"));
    try h.press('y', .{});
    try testing.expect(h.shows("git config issue.remote: no such remote"));
}

test "sync panel: the remote's problem outlives the snapshot it came from" {
    const h = try Harness.createRemote();
    defer h.destroy();
    var problem = "can't tell what isn't pushed".*;
    h.app.store.snap.remote = .{ .name = "origin", .remotes = &.{"origin"}, .problem = &problem };
    try h.press('Y', .{});
    try testing.expect(h.app.state.modal.? == .sync_panel);
    // As a reload freeing the old snapshot's arena would.
    @memset(&problem, 'x');
    h.app.store.snap.remote = .{ .name = "origin", .remotes = &.{"origin"} };
    try h.draw();
    try testing.expect(h.shows("can't tell what isn't pushed"));
}

test "sync: leaving the timeline to quit asks first while one runs" {
    const h = try Harness.createRemote();
    defer h.destroy();
    h.app.state.sync.running = .merge;
    h.app.state.sync.setRunningRemote("origin");
    try testing.expect(h.app.perform(.{ .leave_timeline = .{ .apply = false, .then = .quit } }));
    try h.draw();
    try testing.expect(h.shows("a fetch and merge with origin is running: q again quits"));
    try testing.expect(!h.app.perform(.{ .leave_timeline = .{ .apply = false, .then = .quit } }));
}

test "sync panel: X-Milestone-Mode conflicts open the milestone field" {
    const A = App(GitSim);
    try testing.expectEqual(modal.Field.milestone, A.fieldOf(.{ .field = "X-Milestone-Mode" }).?);
}

test "timeline: keep or drop a stale milestone without losing other draft edits" {
    const Status = issuez.format.fields.MilestoneStatus;
    for ([_]Status{ .open, .completed, .retired }) |status| {
        for ([_]u21{ 'r', 'X' }) |key| {
            const h = try Harness.create();
            defer h.destroy();
            const st = &h.app.store;
            const id = try st.createMilestone(.{ .name = "v1", .due = .parse("2023-11-30") });
            const issue = try st.create(.{ .title = "Work" });
            try st.edit(issue.slice(), .{ .start_date = date("2023-11-14") });
            try h.press('4', .{});
            try h.press('E', .{});
            try h.press('l', .{}); // The milestone's due date.
            h.app.state.timeline.selected_key = .{ .issue = .{ .id = issue } };
            try h.draw();
            try h.press('l', .{}); // An independent issue edit.
            try testing.expectEqual(@as(usize, 2), h.app.state.timeline.changes());
            try st.editMilestone(id.slice(), .{ .name = "Renamed elsewhere", .status = status });
            // Even without group rows, applying selects the stale milestone.
            h.app.state.timeline.grouping = .none;
            try h.draw();
            try h.press('s', .{ .ctrl = true });
            try testing.expect(h.shows("r keeps your change"));
            const t = &h.app.state.timeline;
            try testing.expectEqual(timeline_view.Row.Kind.group, t.rows[t.selected].kind);
            try testing.expect(t.groups[t.rows[t.selected].group].scope.id.eql(id.slice()));
            try h.press(key, .{});
            try testing.expectEqual(@as(usize, 0), t.plan.?.stale.len);
            try testing.expectEqual(@as(usize, 1), t.plan.?.issues.len);
            try testing.expectEqual(@as(usize, if (key == 'r') 1 else 0), t.plan.?.milestones.len);
            try h.press('s', .{ .ctrl = true });
            try h.press(K.enter, .{});
            try testing.expect(!t.editing);
            const m = h.snap().milestones[h.snap().findMilestone(id.slice()).?];
            try testing.expectEqualStrings("Renamed elsewhere", m.name);
            try testing.expectEqual(status, m.status);
            const due = if (key == 'r') "2023-12-01" else "2023-11-30";
            try testing.expect(m.due.?.eql(D.parse(due).?));
            const i = h.snap().find(issue.slice()).?;
            const start = D.parse("2023-11-15").?;
            try testing.expect(h.snap().issues[i].start_date.?.eql(start));
        }
    }
}

test "external pushes refresh the badge and unpushed filter without moving issues" {
    const h = try Harness.createRemote();
    defer h.destroy();
    const id = try h.app.store.create(.{ .title = "One" });
    try h.press('/', .{});
    try h.typeText("is:unpushed");
    try h.press(K.enter, .{});
    try testing.expect(h.snap().remote.isUnpushed(id.slice()));
    try testing.expectEqual(@as(usize, 1), h.app.state.list.rows.len);
    const generation = h.app.store.generation;
    _ = try issuez.Sync(GitSim).init(&h.sim).push(h.arena_state.allocator(), "origin", .{});
    h.app.changedElsewhere(false);
    try h.draw();
    try testing.expect(h.app.store.generation != generation);
    try testing.expect(!h.snap().remote.isUnpushed(id.slice()));
    try testing.expectEqual(@as(usize, 0), h.app.state.list.rows.len);
    try testing.expect(h.shows("origin ✓"));
    // Unchanged records do not trigger another reload.
    try testing.expect(try h.app.store.reloadIfChanged(false) == null);
}

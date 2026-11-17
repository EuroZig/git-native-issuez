//! The user's own views: the filter and sort of the list, the board, the
//! milestones or the timeline under a name, on a key of 5 to 0, next to
//! the four views' 1 to 4. Kept in the TUI's state file.
//!
//! A view shown puts its filter and sort into its default view's query;
//! the default's own wait in `Stash` until another tab is chosen.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const ui = @import("ui.zig");
const filter = @import("filter.zig");
const milestone_filter = @import("milestone_filter.zig");
const text_mod = @import("text.zig");
const AppState = @import("State.zig");

/// A slot's key: slot 0 is 5, the last is 0.
pub const keys = "567890";
pub const max = keys.len;
/// A name's bytes at most: it is a tab in the top bar.
pub const max_name = 32;

/// As kept in the file. Views, scopes and sort keys go by name, not as
/// enums: one a newer version adds makes only that view skipped here,
/// not the whole file unreadable.
pub const Saved = struct {
    name: []const u8 = "",
    /// The digit: 5 to 9, or 0.
    key: ?u8 = null,
    /// list, board, milestones or timeline.
    view: []const u8 = "list",
    filter: []const u8 = "",
    scope: []const u8 = "open",
    /// The view's own default when empty.
    sort: []const u8 = "",
    reverse: bool = false,
    /// The list and the timeline: sub-issues under their parents.
    tree: bool = false,
};

pub const Base = enum {
    list,
    board,
    milestones,
    timeline,

    pub fn of(v: ui.View) ?Base {
        return switch (v) {
            .list => .list,
            .board => .board,
            .milestones => .milestones,
            .timeline => .timeline,
            .milestone, .detail => null,
        };
    }

    pub fn view(b: Base) ui.View {
        return switch (b) {
            .list => .list,
            .board => .board,
            .milestones => .milestones,
            .timeline => .timeline,
        };
    }

    /// The default view's query as a session starts.
    fn defaults(b: Base) filter.Query {
        return switch (b) {
            .list => .{},
            .board => AppState.default_bd_query,
            .timeline => AppState.default_tl_query,
            .milestones => unreachable,
        };
    }
};

/// A view in memory. `filter` is the gpa's; the queries' texts are unused.
pub const View = struct {
    name: []const u8,
    base: Base,
    filter: []const u8,
    /// The list's, the board's or the timeline's.
    issues: filter.Query = .{},
    /// The milestones view's.
    milestones: milestone_filter.Query = .{},

    pub fn deinit(v: *View, gpa: Allocator) void {
        gpa.free(v.name);
        gpa.free(v.filter);
        v.* = undefined;
    }

    /// Null when this version doesn't know its view or its key; what it
    /// doesn't know of the rest is the view's default.
    fn fromSaved(gpa: Allocator, saved: Saved) Allocator.Error!?View {
        const base = std.meta.stringToEnum(Base, saved.view) orelse return null;
        if (!validName(saved.name)) return null;
        var v: View = .{ .name = undefined, .base = base, .filter = undefined };
        if (base == .milestones) {
            const q = &v.milestones;
            q.scope = std.meta.stringToEnum(milestone_filter.Scope, saved.scope) orelse q.scope;
            q.key = std.meta.stringToEnum(milestone_filter.SortKey, saved.sort) orelse q.key;
            q.reverse = saved.reverse;
        } else {
            const q = &v.issues;
            q.* = base.defaults();
            q.scope = std.meta.stringToEnum(filter.Scope, saved.scope) orelse q.scope;
            q.key = std.meta.stringToEnum(filter.SortKey, saved.sort) orelse q.key;
            q.reverse = saved.reverse;
            q.tree = saved.tree;
        }
        v.name = try gpa.dupe(u8, saved.name);
        errdefer gpa.free(v.name);
        v.filter = try gpa.dupe(u8, saved.filter);
        return v;
    }

    /// Strings are the view's.
    fn toSaved(v: *const View, slot: u8) Saved {
        var out: Saved = .{
            .name = v.name,
            .key = keys[slot] - '0',
            .view = @tagName(v.base),
            .filter = v.filter,
        };
        if (v.base == .milestones) {
            out.scope = @tagName(v.milestones.scope);
            out.sort = @tagName(v.milestones.key);
            out.reverse = v.milestones.reverse;
        } else {
            out.scope = @tagName(v.issues.scope);
            out.sort = @tagName(v.issues.key);
            out.reverse = v.issues.reverse;
            out.tree = v.issues.tree;
        }
        return out;
    }
};

/// A default view's filter and sort, while a view of the user's is in
/// their place. `text` is the gpa's.
pub const Stash = struct {
    issues: filter.Query = .{},
    milestones: milestone_filter.Query = .{},
    text: []u8 = &.{},
};

/// One line of at most `max_name` bytes, not blank.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    if (std.mem.trim(u8, name, " \t").len == 0) return false;
    return std.mem.findAny(u8, name, "\r\n\t") == null;
}

/// The slot of a key, 5 to 0.
pub fn slotOf(key: u21) ?u8 {
    if (key > 0x7f) return null;
    const n = std.mem.findScalar(u8, keys, @intCast(key)) orelse return null;
    return @intCast(n);
}

/// The views as read from the file, in place of any there were. A view
/// this version doesn't know, or on a key taken already, is skipped.
pub fn load(s: *AppState, saved: []const Saved) Allocator.Error!void {
    for (&s.views) |*slot| if (slot.*) |*v| {
        v.deinit(s.gpa);
        slot.* = null;
    };
    for (saved) |sv| {
        const key = sv.key orelse continue;
        if (key > 9) continue;
        const n = slotOf('0' + @as(u21, key)) orelse continue;
        if (s.views[n] != null) continue;
        s.views[n] = try View.fromSaved(s.gpa, sv) orelse continue;
    }
}

/// The views to write, by key; strings are the views'.
pub fn toSaved(s: *const AppState, a: Allocator) Allocator.Error![]const Saved {
    var out: std.ArrayList(Saved) = .empty;
    for (&s.views, 0..) |*slot, n| if (slot.*) |*v| {
        try out.append(a, v.toSaved(@intCast(n)));
    };
    return out.items;
}

pub fn deinit(s: *AppState) void {
    for (&s.views) |*slot| if (slot.*) |*v| v.deinit(s.gpa);
    s.gpa.free(s.stash.text);
}

/// Whether the tab of `slot` is the one shown: its view, or the milestone
/// opened from it.
pub fn shown(s: *const AppState, slot: u8) bool {
    if (s.custom != slot) return false;
    const v = s.views[slot] orelse return false;
    if (s.view == v.base.view()) return true;
    return v.base == .milestones and s.view == .milestone;
}

/// To the view on `slot`, as it was saved: again on its own key, back to
/// that after the filter or sort was changed.
pub fn open(s: *AppState, slot: u8) void {
    const v = &(s.views[slot] orelse return);
    const base = v.base.view();
    if (!@import("timeline_view.zig").edit.mayLeave(s, .{ .custom = slot })) return;
    // Leaves the one shown, if any.
    s.switchView(base);
    stash(s, v.base) catch return s.fail("out of memory", .{});
    apply(s, v) catch {
        unstash(s);
        return s.fail("out of memory", .{});
    };
    s.custom = slot;
    s.filterChanged();
}

/// The default view's filter and sort back; for leaving the view of the
/// user's for another tab.
pub fn leave(s: *AppState) void {
    if (s.custom == null) return;
    unstash(s);
    s.filterChanged();
}

fn stash(s: *AppState, base: Base) Allocator.Error!void {
    assert(s.custom == null);
    const text = switch (base) {
        .milestones => s.ms_search.text(),
        else => issuesOf(s, base).box.text(),
    };
    const owned = try s.gpa.dupe(u8, text);
    s.gpa.free(s.stash.text);
    s.stash = .{ .text = owned };
    switch (base) {
        .milestones => s.stash.milestones = s.ms_query,
        else => s.stash.issues = issuesOf(s, base).query.*,
    }
    s.stash_base = base;
}

fn unstash(s: *AppState) void {
    const base = s.stash_base;
    const box = switch (base) {
        .milestones => &s.ms_search,
        else => issuesOf(s, base).box,
    };
    // Out of memory: no filter rather than the view's.
    box.set(s.gpa, s.stash.text) catch box.clear();
    switch (base) {
        .milestones => s.ms_query = s.stash.milestones,
        else => issuesOf(s, base).query.* = s.stash.issues,
    }
    s.custom = null;
}

/// The issue query and filter box of a view other than the milestones.
fn issuesOf(s: *AppState, base: Base) struct { query: *filter.Query, box: *text_mod.TextArea } {
    return switch (base) {
        .list => .{ .query = &s.query, .box = &s.search },
        .board => .{ .query = &s.bd_query, .box = &s.bd_search },
        .timeline => .{ .query = &s.tl_query, .box = &s.tl_search },
        .milestones => unreachable,
    };
}

fn apply(s: *AppState, v: *const View) Allocator.Error!void {
    switch (v.base) {
        .milestones => {
            try s.ms_search.set(s.gpa, v.filter);
            s.ms_query.scope = v.milestones.scope;
            s.ms_query.key = v.milestones.key;
            s.ms_query.reverse = v.milestones.reverse;
        },
        .list, .board, .timeline => {
            const q = issuesOf(s, v.base).query;
            try issuesOf(s, v.base).box.set(s.gpa, v.filter);
            q.scope = v.issues.scope;
            q.key = v.issues.key;
            q.reverse = v.issues.reverse;
            q.tree = v.issues.tree;
        },
    }
}

/// The filter and sort shown now as the view on `slot`, named `name`,
/// in place of the one there: then it is the one shown. Only from one of
/// the four views.
pub fn save(s: *AppState, slot: u8, name: []const u8) Allocator.Error!void {
    assert(validName(name));
    const base = Base.of(s.view).?;
    // A view shown is on its own default view.
    if (s.custom) |c| assert(s.views[c].?.base.view() == s.view);
    var v: View = .{ .name = undefined, .base = base, .filter = undefined };
    if (base == .milestones) {
        v.milestones = s.currentMilestoneQuery();
        v.milestones.text = "";
    } else {
        v.issues = s.currentQuery();
        v.issues.text = "";
        v.issues.milestone = null;
        v.issues.effective = null;
    }
    v.filter = try s.gpa.dupe(u8, s.searchBox().text());
    errdefer s.gpa.free(v.filter);
    v.name = try s.gpa.dupe(u8, name);
    errdefer s.gpa.free(v.name);
    // Shown now, so the default's filter and sort wait meanwhile.
    if (s.custom == null) try stash(s, base);
    if (s.views[slot]) |*old| old.deinit(s.gpa);
    s.views[slot] = v;
    s.custom = slot;
}

/// The view on `slot` gone; shown, its default view's filter and sort
/// are back.
pub fn delete(s: *AppState, slot: u8) void {
    if (s.custom == slot) leave(s);
    if (s.views[slot]) |*v| v.deinit(s.gpa);
    s.views[slot] = null;
}

/// Where `V` saves to first: the view shown, else the first free key.
pub fn suggestedSlot(s: *const AppState) u8 {
    if (s.custom) |c| return c;
    for (s.views, 0..) |v, n| if (v == null) return @intCast(n);
    return 0;
}

const testing = std.testing;

test "saved: unknown views, keys and names skipped; unknown sorts are the default" {
    const gpa = testing.allocator;
    var s: AppState = .init(gpa, undefined);
    defer s.deinit();
    try load(&s, &.{
        .{ .name = "Bugs", .key = 5, .filter = "label:bug", .sort = "priority", .tree = true },
        .{ .name = "Taken", .key = 5 },
        .{ .name = "Gantt", .key = 6, .view = "gantt" },
        .{ .name = "", .key = 7 },
        .{ .name = "Low", .key = 3 },
        .{ .name = "Late", .key = 0, .view = "timeline", .sort = "someday", .scope = "all" },
        .{ .name = "Ms", .key = 9, .view = "milestones", .sort = "health", .reverse = true },
    });
    try testing.expectEqualStrings("Bugs", s.views[0].?.name);
    try testing.expectEqual(filter.SortKey.priority, s.views[0].?.issues.key);
    try testing.expect(s.views[1] == null and s.views[2] == null and s.views[3] == null);
    const late = s.views[5].?;
    try testing.expectEqual(filter.SortKey.start, late.issues.key);
    try testing.expectEqual(filter.Scope.all, late.issues.scope);
    try testing.expectEqual(milestone_filter.SortKey.health, s.views[4].?.milestones.key);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const out = try toSaved(&s, arena_state.allocator());
    try testing.expectEqual(3, out.len);
    try testing.expectEqualDeep(Saved{
        .name = "Bugs",
        .key = 5,
        .filter = "label:bug",
        .sort = "priority",
        .tree = true,
    }, out[0]);
    try testing.expectEqual(0, out[2].key);
}

test "names: one line, not blank, at most 32 bytes" {
    try testing.expect(validName("Bugs for 1.0"));
    try testing.expect(!validName(""));
    try testing.expect(!validName("   "));
    try testing.expect(!validName("a\nb"));
    try testing.expect(!validName("abcdefghijklmnopqrstuvwxyz0123456"));
}

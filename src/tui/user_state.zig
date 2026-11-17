//! What the TUI keeps for the user between sessions, in one ZON file
//! outside every repository: `git-issue/tui.zon` in the user's local
//! configuration folder, as known-folders has it (`$XDG_CONFIG_HOME`, by
//! default `~/.config`; `~/Library/Application Support` on macOS;
//! `%LOCALAPPDATA%` on Windows).
//!
//! Fields are only ever added, each with a default, so any version reads
//! any file: what a file lacks is the default, what a version doesn't know
//! it skips. A version that saves drops what it skipped. A file that isn't
//! ZON of this shape is left alone: nothing is saved over it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const known_folders = @import("known-folders");

const star = @import("star.zig");
const custom_view = @import("custom_view.zig");

pub const State = struct {
    /// The star notice.
    star: star.Record = .{},
    /// Before views were a project's: the views of every repository. Read
    /// once into a template called Imported (`migrated`), written empty.
    views: []const custom_view.Saved = &.{},
    /// The user's own views of each repository, on keys 5 to 0.
    projects: []const Project = &.{},
    /// Sets of views by name, for any repository.
    templates: []const Template = &.{},
};

pub const Project = struct {
    /// The repository's git common directory, absolute, symlinks resolved:
    /// its worktrees share it.
    path: []const u8 = "",
    views: []const custom_view.Saved = &.{},
};

pub const Template = struct {
    name: []const u8 = "",
    views: []const custom_view.Saved = &.{},
};

/// The views of the project at `project`, a `Project.path`; none when it
/// has no entry.
pub fn viewsOf(state: State, project: []const u8) []const custom_view.Saved {
    for (state.projects) |p| if (std.mem.eql(u8, p.path, project)) return p.views;
    return &.{};
}

/// `state` with `views` as the project's at `project`: an empty set drops
/// its entry. The slices are `a`'s or the caller's.
pub fn withViews(
    a: Allocator,
    state: State,
    project: []const u8,
    views: []const custom_view.Saved,
) Allocator.Error!State {
    var out = state;
    var list: std.ArrayList(Project) = .empty;
    for (state.projects) |p| if (!std.mem.eql(u8, p.path, project)) try list.append(a, p);
    if (views.len > 0) try list.append(a, .{ .path = project, .views = views });
    out.projects = list.items;
    return out;
}

pub fn findTemplate(state: State, name: []const u8) ?Template {
    for (state.templates) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

/// `state` with the template `name` holding `views`, in place of one of
/// that name; null `views` drops it.
pub fn withTemplate(
    a: Allocator,
    state: State,
    name: []const u8,
    views: ?[]const custom_view.Saved,
) Allocator.Error!State {
    var out = state;
    var list: std.ArrayList(Template) = .empty;
    var placed = false;
    for (state.templates) |t| {
        if (!std.mem.eql(u8, t.name, name)) {
            try list.append(a, t);
        } else if (views) |v| {
            try list.append(a, .{ .name = name, .views = v });
            placed = true;
        }
    }
    if (views) |v| if (!placed) try list.append(a, .{ .name = name, .views = v });
    out.templates = list.items;
    return out;
}

/// The views from before projects as a template, Imported (or Imported 2
/// and on, when taken), and no longer on their own; null when there are
/// none.
pub fn migrated(a: Allocator, state: State) Allocator.Error!?State {
    if (state.views.len == 0) return null;
    var name: []const u8 = "Imported";
    var n: u32 = 2;
    while (findTemplate(state, name) != null) : (n += 1) {
        name = try std.fmt.allocPrint(a, "Imported {d}", .{n});
    }
    var out = try withTemplate(a, state, name, state.views);
    out.views = &.{};
    return out;
}

const header =
    \\// git issue tui: what it keeps for you between sessions. Fields left
    \\// out take their defaults; deleting the file starts over.
    \\
;

/// Where the file is; null without a folder to keep it in.
pub fn path(io: std.Io, a: Allocator, environ_map: *const Environ.Map) ?[]const u8 {
    const dir = known_folders.getPath(io, a, environ_map, .local_configuration) catch |e| {
        // Quitting: whoever waits on the task must see it too.
        if (e == error.Canceled) io.recancel();
        return null;
    } orelse return null;
    return std.fs.path.join(a, &.{ dir, "git-issue", "tui.zon" }) catch null;
}

/// What reading takes at most: views of hundreds of repositories, and
/// more. A file past it can't be read, and so isn't saved over.
pub const max_bytes = 16 * 1024 * 1024;

/// The defaults when there is no file yet; null when it can't be read or
/// isn't the ZON it should be: then it isn't to be saved over either.
pub fn load(io: std.Io, a: Allocator, file: []const u8) ?State {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(max_bytes)) catch |e|
        switch (e) {
            error.FileNotFound => return .{},
            error.Canceled => {
                io.recancel();
                return null;
            },
            else => return null,
        };
    return parse(a, bytes);
}

pub fn parse(a: Allocator, bytes: []const u8) ?State {
    const source = a.dupeSentinel(u8, bytes, 0) catch return null;
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(State, .{
        .gpa = a,
        .arena = a,
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch null;
}

pub fn write(state: State, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(header);
    try std.zon.stringify.serialize(state, .{}, w);
    try w.writeByte('\n');
}

/// The star notice's task and the UI both write the file: each change
/// reads it again under this lock, so neither drops what the other wrote.
var lock: std.Io.Mutex = .init;

/// The file read, changed by `change(context, a, &state)` and saved,
/// under the lock. False when it couldn't be read or written.
pub fn update(
    io: std.Io,
    a: Allocator,
    file: []const u8,
    context: anytype,
    comptime change: fn (@TypeOf(context), Allocator, *State) Allocator.Error!void,
) bool {
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    var state = load(io, a, file) orelse return false;
    change(context, a, &state) catch return false;
    return save(io, a, file, state);
}

/// Whole or not at all: a temporary file renamed over it. False when it
/// couldn't be written.
pub fn save(io: std.Io, a: Allocator, file: []const u8, state: State) bool {
    var out: std.Io.Writer.Allocating = .init(a);
    write(state, &out.writer) catch return false;
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(file)) |dir| cwd.createDirPath(io, dir) catch return false;
    var suffix: [8]u8 = undefined;
    io.random(&suffix);
    const tmp = std.fmt.allocPrint(a, "{s}.tmp-{x}", .{ file, suffix }) catch return false;
    cwd.writeFile(io, .{ .sub_path = tmp, .data = out.written() }) catch return false;
    std.Io.Dir.rename(cwd, tmp, cwd, file, io) catch {
        cwd.deleteFile(io, tmp) catch {};
        return false;
    };
    return true;
}

const testing = std.testing;

test "projects: each its own views; none drops the entry" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mine: []const custom_view.Saved = &.{.{ .name = "Mine", .key = 5 }};
    const theirs: []const custom_view.Saved = &.{.{ .name = "Theirs", .key = 6 }};
    var s = try withViews(a, .{}, "/a/.git", mine);
    s = try withViews(a, s, "/b/.git", theirs);
    try testing.expectEqualStrings("Mine", viewsOf(s, "/a/.git")[0].name);
    try testing.expectEqualStrings("Theirs", viewsOf(s, "/b/.git")[0].name);
    try testing.expectEqual(0, viewsOf(s, "/c/.git").len);
    s = try withViews(a, s, "/a/.git", theirs);
    try testing.expectEqualStrings("Theirs", viewsOf(s, "/a/.git")[0].name);
    s = try withViews(a, s, "/a/.git", &.{});
    try testing.expectEqual(1, s.projects.len);
    // Written and read back.
    var out: std.Io.Writer.Allocating = .init(a);
    try write(s, &out.writer);
    try testing.expectEqualDeep(s, parse(a, out.written()).?);
}

test "templates: saved, replaced by name, dropped; the old views once as Imported" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const one: []const custom_view.Saved = &.{.{ .name = "One", .key = 5 }};
    const two: []const custom_view.Saved = &.{.{ .name = "Two", .key = 7 }};
    var s = try withTemplate(a, .{}, "Triage", one);
    s = try withTemplate(a, s, "Triage", two);
    try testing.expectEqual(1, s.templates.len);
    try testing.expectEqualStrings("Two", findTemplate(s, "Triage").?.views[0].name);
    s = try withTemplate(a, s, "Triage", null);
    try testing.expect(findTemplate(s, "Triage") == null);

    try testing.expect(try migrated(a, .{}) == null);
    s = try withTemplate(a, .{ .views = one }, "Imported", two);
    s = (try migrated(a, s)).?;
    try testing.expectEqual(0, s.views.len);
    try testing.expectEqualStrings("One", findTemplate(s, "Imported 2").?.views[0].name);
    try testing.expectEqualStrings("Two", findTemplate(s, "Imported").?.views[0].name);
    try testing.expect(try migrated(a, s) == null);
}

test "state: written and read back; missing fields default, unknown ones are skipped" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s: State = .{
        .star = .{ .first_seen = 17, .last_shown = 42, .shown = 2, .done = .never },
        .views = &.{
            .{ .name = "Bugs", .key = 5, .filter = "label:bug", .sort = "priority", .tree = true },
            .{ .name = "Due", .key = 0, .view = "milestones", .scope = "all", .reverse = true },
        },
    };
    var out: std.Io.Writer.Allocating = .init(a);
    try write(s, &out.writer);
    try testing.expectEqualDeep(s, parse(a, out.written()).?);
    try testing.expectEqualDeep(State{}, parse(a, ".{}").?);
    const newer = parse(a, ".{ .star = .{ .shown = 3, .later = 1 }, .theme = .dark }").?;
    try testing.expectEqualDeep(State{ .star = .{ .shown = 3 } }, newer);
}

test "state: damage is refused, not read as defaults" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expect(parse(a, "first-seen 17\n") == null);
    try testing.expect(parse(a, ".{ .star = .{ .done = .maybe } }") == null);
    try testing.expect(parse(a, ".{ .star = .{ .shown = -1 } }") == null);
}

test "save: into a folder made for it, over what was there" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const file = try std.fs.path.join(a, &.{ root, "git-issue", "tui.zon" });
    try testing.expectEqualDeep(State{}, load(testing.io, a, file).?);
    try testing.expect(save(testing.io, a, file, .{ .star = .{ .shown = 1 } }));
    try testing.expect(save(testing.io, a, file, .{ .star = .{ .shown = 2 } }));
    try testing.expectEqualDeep(State{ .star = .{ .shown = 2 } }, load(testing.io, a, file).?);
}

test "update: what the other writer saved meanwhile is kept" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const file = try std.fs.path.join(a, &.{ root, "tui.zon" });
    try testing.expect(save(testing.io, a, file, .{ .star = .{ .shown = 1 } }));
    const views: []const custom_view.Saved = &.{.{ .name = "Mine", .key = 6 }};
    try testing.expect(update(testing.io, a, file, views, struct {
        fn f(v: []const custom_view.Saved, _: Allocator, st: *State) Allocator.Error!void {
            st.views = v;
        }
    }.f));
    try testing.expectEqualDeep(
        State{ .star = .{ .shown = 1 }, .views = views },
        load(testing.io, a, file).?,
    );
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = file, .data = "damaged" });
    try testing.expect(!update(testing.io, a, file, views, struct {
        fn f(v: []const custom_view.Saved, _: Allocator, st: *State) Allocator.Error!void {
            st.views = v;
        }
    }.f));
}

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

pub const State = struct {
    /// The star notice.
    star: star.Record = .{},
};

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

/// The defaults when there is no file yet; null when it can't be read or
/// isn't the ZON it should be: then it isn't to be saved over either.
pub fn load(io: std.Io, a: Allocator, file: []const u8) ?State {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(64 * 1024)) catch |e|
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

test "state: written and read back; missing fields default, unknown ones are skipped" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s: State = .{
        .star = .{ .first_seen = 17, .last_shown = 42, .shown = 2, .done = .never },
    };
    var out: std.Io.Writer.Allocating = .init(a);
    try write(s, &out.writer);
    try testing.expectEqual(s, parse(a, out.written()).?);
    try testing.expectEqual(State{}, parse(a, ".{}").?);
    const newer = parse(a, ".{ .star = .{ .shown = 3, .later = 1 }, .theme = .dark }").?;
    try testing.expectEqual(State{ .star = .{ .shown = 3 } }, newer);
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
    try testing.expectEqual(State{}, load(testing.io, a, file).?);
    try testing.expect(save(testing.io, a, file, .{ .star = .{ .shown = 1 } }));
    try testing.expect(save(testing.io, a, file, .{ .star = .{ .shown = 2 } }));
    try testing.expectEqual(State{ .star = .{ .shown = 2 } }, load(testing.io, a, file).?);
}

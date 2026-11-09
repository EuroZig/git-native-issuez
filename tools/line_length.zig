//! `line-length <path>...`: every line of the Zig files under the paths
//! (files or directories) is at most 100 columns, counted in code points
//! (CONTRIBUTING.md, "Code"). Lists the lines that aren't.

const std = @import("std");

const limit = 100;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const cwd = std.Io.Dir.cwd();
    var long: usize = 0;
    for (args[1..]) |path| {
        if (std.mem.endsWith(u8, path, ".zig")) {
            long += try check(io, arena, cwd, path, path);
            continue;
        }
        var dir = try cwd.openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".zig")) continue;
            const shown = try std.fs.path.join(arena, &.{ path, e.path });
            long += try check(io, arena, dir, e.path, shown);
        }
    }
    // Silent on success: a build step that writes to stderr reads as failed.
    if (long == 0) return 0;
    std.debug.print("line-length: {d} line(s) over {d} columns\n", .{ long, limit });
    return 1;
}

fn check(
    io: std.Io,
    arena: std.mem.Allocator,
    dir: std.Io.Dir,
    path: []const u8,
    shown: []const u8,
) !usize {
    const data = try dir.readFileAlloc(io, path, arena, .limited(16 << 20));
    var long: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var n: usize = 0;
    while (lines.next()) |l| {
        n += 1;
        const columns = std.unicode.utf8CountCodepoints(l) catch l.len;
        if (columns <= limit) continue;
        std.debug.print("{s}:{d}: {d} columns\n", .{ shown, n, columns });
        long += 1;
    }
    return long;
}

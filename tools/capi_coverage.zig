//! `capi-coverage <issuez-api.json> <test dir>`: every C API function and
//! generated helper has a Zig test named after it:
//! `test "issuez_x: ..."`, or several names before the colon, separated by
//! ", ". Names that don't fit in the line go in `// covers: ...` lines
//! right above the test, also separated by ", ". `pending.txt` in the
//! test dir lists names without a test yet, one
//! per line; a name both pending and tested fails too, so the list only
//! shrinks.

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: capi-coverage <issuez-api.json> <test dir>\n", .{});
        return 2;
    }
    const cwd = std.Io.Dir.cwd();
    const json = try cwd.readFileAlloc(io, args[1], arena, .limited(16 << 20));
    const Api = struct {
        functions: []const struct { name: []const u8 },
        helpers: []const struct { name: []const u8 },
    };
    const parsed = try std.json.parseFromSliceLeaky(Api, arena, json, .{
        .ignore_unknown_fields = true,
    });
    var wanted: std.ArrayList([]const u8) = .empty;
    for (parsed.functions) |f| try wanted.append(arena, f.name);
    for (parsed.helpers) |h| try wanted.append(arena, h.name);

    var tested: std.StringHashMapUnmanaged(void) = .empty;
    var pending: std.StringHashMapUnmanaged(void) = .empty;
    var dir = try cwd.openDir(io, args[2], .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        const data = try dir.readFileAlloc(io, e.name, arena, .limited(16 << 20));
        if (std.mem.eql(u8, e.name, "pending.txt")) {
            var lines = std.mem.tokenizeAny(u8, data, "\r\n");
            while (lines.next()) |l| {
                const name = std.mem.trim(u8, l, " \t");
                if (name.len > 0 and name[0] != '#') try pending.put(arena, name, {});
            }
            continue;
        }
        if (!std.mem.endsWith(u8, e.name, ".zig")) continue;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |l| {
            const t = std.mem.trimStart(u8, l, " ");
            if (std.mem.startsWith(u8, t, "// covers: ")) {
                const list = std.mem.trimEnd(u8, t["// covers: ".len..], " ,");
                var names = std.mem.splitSequence(u8, list, ", ");
                while (names.next()) |n| try tested.put(arena, std.mem.trimEnd(u8, n, ","), {});
                continue;
            }
            if (!std.mem.startsWith(u8, t, "test \"")) continue;
            const rest = t["test \"".len..];
            const colon = std.mem.findScalar(u8, rest, ':') orelse continue;
            var names = std.mem.splitSequence(u8, rest[0..colon], ", ");
            while (names.next()) |n| try tested.put(arena, n, {});
        }
    }

    var failed = false;
    var missing: usize = 0;
    for (wanted.items) |name| {
        const has = tested.contains(name);
        const waits = pending.contains(name);
        if (has and waits) {
            std.debug.print("{s} has a test: take it off pending.txt\n", .{name});
            failed = true;
        } else if (!has and !waits) {
            std.debug.print("{s} has no test (test \"{s}: ...\")\n", .{ name, name });
            failed = true;
        }
        if (!has) missing += 1;
    }
    var pit = pending.keyIterator();
    while (pit.next()) |k| {
        const known = for (wanted.items) |w| {
            if (std.mem.eql(u8, w, k.*)) break true;
        } else false;
        if (!known) {
            std.debug.print("pending.txt names {s}, which the API doesn't have\n", .{k.*});
            failed = true;
        }
    }
    // Silent on success: a build step that writes to stderr reads as failed.
    if (failed) {
        std.debug.print(
            "capi-coverage: {d} of {d} without a test\n",
            .{ missing, wanted.items.len },
        );
        return 1;
    }
    return 0;
}

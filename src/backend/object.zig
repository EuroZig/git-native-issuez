//! Object IDs, commits, trees and git's object hashing. We encode objects
//! ourselves instead of calling `git commit-tree`, so `GitProcess` and
//! `GitSim` produce the same OIDs.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const hex_fmt = @import("../format/hex.zig");

pub const ObjectFormat = enum {
    sha1,
    sha256,

    pub fn byteLen(format: ObjectFormat) u8 {
        return switch (format) {
            .sha1 => 20,
            .sha256 => 32,
        };
    }

    pub fn hexLen(format: ObjectFormat) u8 {
        return format.byteLen() * 2;
    }

    pub fn parse(name: []const u8) ?ObjectFormat {
        return std.meta.stringToEnum(ObjectFormat, name);
    }
};

pub const ObjectKind = enum {
    commit,
    tree,
    blob,
    tag,

    pub fn parse(name: []const u8) ?ObjectKind {
        return std.meta.stringToEnum(ObjectKind, name);
    }
};

pub const Oid = struct {
    object_format: ObjectFormat,
    bytes: [max_byte_len]u8,

    pub const max_byte_len = 32;
    pub const max_hex_len = 64;

    pub const ParseError = error{InvalidOid};

    /// Full lowercase hex only, no abbreviations.
    pub fn parseHex(object_format: ObjectFormat, text: []const u8) ParseError!Oid {
        // hexToBytes also takes uppercase. git never writes it, and OIDs are
        // compared as text in ref names and trailers.
        if (text.len != object_format.hexLen() or !hex_fmt.isLower(text)) return error.InvalidOid;
        var oid: Oid = .{ .object_format = object_format, .bytes = @splat(0) };
        _ = std.fmt.hexToBytes(&oid.bytes, text) catch unreachable;
        return oid;
    }

    pub fn slice(oid: *const Oid) []const u8 {
        return oid.bytes[0..oid.object_format.byteLen()];
    }

    pub fn eql(a: Oid, b: Oid) bool {
        return a.object_format == b.object_format and std.mem.eql(u8, a.slice(), b.slice());
    }

    /// Same as hex order.
    pub fn order(a: Oid, b: Oid) std.math.Order {
        assert(a.object_format == b.object_format);
        return std.mem.order(u8, a.slice(), b.slice());
    }

    pub const Hex = struct {
        buf: [max_hex_len]u8,
        len: u8,

        pub fn slice(h: *const Hex) []const u8 {
            return h.buf[0..h.len];
        }

        /// The abbreviation `git log --oneline` and upstream print.
        pub fn short(h: *const Hex) []const u8 {
            return h.buf[0..7];
        }
    };

    pub fn hex(oid: Oid) Hex {
        var h: Hex = .{ .buf = undefined, .len = oid.object_format.hexLen() };
        _ = std.fmt.bufPrint(&h.buf, "{x}", .{oid.slice()}) catch unreachable;
        return h;
    }

    pub fn format(oid: Oid, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.printHex(oid.slice(), .lower);
    }
};

/// `H("<kind> <len>\0" ++ data)`, like git.
pub fn hashObject(format: ObjectFormat, kind: ObjectKind, data: []const u8) Oid {
    var header_buf: [32]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "{t} {d}\x00",
        .{ kind, data.len },
    ) catch unreachable;
    var oid: Oid = .{ .object_format = format, .bytes = @splat(0) };
    switch (format) {
        .sha1 => {
            var h = std.crypto.hash.Sha1.init(.{});
            h.update(header);
            h.update(data);
            h.final(oid.bytes[0..20]);
        },
        .sha256 => {
            var h = std.crypto.hash.sha2.Sha256.init(.{});
            h.update(header);
            h.update(data);
            h.final(oid.bytes[0..32]);
        },
    }
    return oid;
}

pub fn emptyTree(format: ObjectFormat) Oid {
    return hashObject(format, .tree, "");
}

/// `Name <email> <unix-seconds> <+hhmm>`
pub const Signature = struct {
    name: []const u8,
    email: []const u8,
    time: i64,
    /// Minutes east of UTC, so +0130 is 90.
    tz_offset_minutes: i16,

    pub const ParseError = error{InvalidSignature};

    pub fn isValid(sig: Signature) bool {
        return validIdentPart(sig.name) and validIdentPart(sig.email) and
            sig.tz_offset_minutes > -24 * 60 and sig.tz_offset_minutes < 24 * 60;
    }

    fn validIdentPart(s: []const u8) bool {
        for (s) |c| switch (c) {
            '<', '>', '\n', 0 => return false,
            else => {},
        };
        return true;
    }

    pub fn parse(line: []const u8) ParseError!Signature {
        const lt = std.mem.findScalar(u8, line, '<') orelse return error.InvalidSignature;
        const gt = std.mem.findScalarPos(u8, line, lt, '>') orelse return error.InvalidSignature;
        if (lt == 0 or line[lt - 1] != ' ') return error.InvalidSignature;
        const name = line[0 .. lt - 1];
        const email = line[lt + 1 .. gt];
        const rest = line[gt + 1 ..];
        if (rest.len < 1 or rest[0] != ' ') return error.InvalidSignature;
        var it = std.mem.splitScalar(u8, rest[1..], ' ');
        const time_str = it.next() orelse return error.InvalidSignature;
        const tz_str = it.next() orelse return error.InvalidSignature;
        if (it.next() != null) return error.InvalidSignature;
        const time = std.fmt.parseInt(i64, time_str, 10) catch return error.InvalidSignature;
        const tz = parseTz(tz_str) orelse return error.InvalidSignature;
        const sig: Signature = .{
            .name = name,
            .email = email,
            .time = time,
            .tz_offset_minutes = tz,
        };
        if (!sig.isValid()) return error.InvalidSignature;
        return sig;
    }

    fn parseTz(s: []const u8) ?i16 {
        if (s.len != 5) return null;
        const sign: i16 = switch (s[0]) {
            '+' => 1,
            '-' => -1,
            else => return null,
        };
        for (s[1..]) |c| if (!std.ascii.isDigit(c)) return null;
        const hours = std.fmt.parseInt(i16, s[1..3], 10) catch unreachable;
        const minutes = std.fmt.parseInt(i16, s[3..5], 10) catch unreachable;
        if (minutes >= 60) return null;
        return sign * (hours * 60 + minutes);
    }

    pub fn format(sig: Signature, w: *std.Io.Writer) std.Io.Writer.Error!void {
        assert(sig.isValid());
        const abs: u16 = @abs(sig.tz_offset_minutes);
        const sign: u8 = if (sig.tz_offset_minutes < 0) '-' else '+';
        try w.print("{s} <{s}> {d} {c}{d:0>2}{d:0>2}", .{
            sig.name, sig.email, sig.time, sign, abs / 60, abs % 60,
        });
    }
};

/// Slices point into the raw object data.
pub const Commit = struct {
    tree: Oid,
    parents: []const Oid,
    author: Signature,
    committer: Signature,
    message: []const u8,

    pub const ParseError = error{InvalidCommit} || Allocator.Error;

    /// Unknown headers (gpgsig, mergetag, ...) are skipped.
    pub fn parse(arena: Allocator, format: ObjectFormat, data: []const u8) ParseError!Commit {
        const header_end = std.mem.find(u8, data, "\n\n") orelse
            return error.InvalidCommit;
        const headers = data[0 .. header_end + 1];
        const message = data[header_end + 2 ..];

        var tree: ?Oid = null;
        var author: ?Signature = null;
        var committer: ?Signature = null;
        var parents: std.ArrayList(Oid) = .empty;

        var lines = std.mem.splitScalar(u8, headers[0 .. headers.len - 1], '\n');
        while (lines.next()) |line| {
            if (line.len > 0 and line[0] == ' ') continue; // continuation line
            const sp = std.mem.findScalar(u8, line, ' ') orelse return error.InvalidCommit;
            const key = line[0..sp];
            const value = line[sp + 1 ..];
            if (std.mem.eql(u8, key, "tree")) {
                if (tree != null) return error.InvalidCommit;
                tree = Oid.parseHex(format, value) catch return error.InvalidCommit;
            } else if (std.mem.eql(u8, key, "parent")) {
                if (tree == null or author != null) return error.InvalidCommit;
                try parents.append(
                    arena,
                    Oid.parseHex(format, value) catch return error.InvalidCommit,
                );
            } else if (std.mem.eql(u8, key, "author")) {
                if (author != null) return error.InvalidCommit;
                author = Signature.parse(value) catch return error.InvalidCommit;
            } else if (std.mem.eql(u8, key, "committer")) {
                if (committer != null) return error.InvalidCommit;
                committer = Signature.parse(value) catch return error.InvalidCommit;
            }
        }

        return .{
            .tree = tree orelse return error.InvalidCommit,
            .parents = try parents.toOwnedSlice(arena),
            .author = author orelse return error.InvalidCommit,
            .committer = committer orelse return error.InvalidCommit,
            .message = message,
        };
    }

    /// Byte for byte what `git commit-tree` writes. `message` must end with
    /// a newline.
    pub fn serialize(commit: Commit, w: *std.Io.Writer) std.Io.Writer.Error!void {
        assert(commit.message.len > 0 and commit.message[commit.message.len - 1] == '\n');
        try w.print("tree {f}\n", .{commit.tree});
        for (commit.parents) |p| {
            assert(p.object_format == commit.tree.object_format);
            try w.print("parent {f}\n", .{p});
        }
        try w.print("author {f}\n", .{commit.author});
        try w.print("committer {f}\n", .{commit.committer});
        try w.writeAll("\n");
        try w.writeAll(commit.message);
    }

    pub fn serializeAlloc(commit: Commit, gpa: Allocator) Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        commit.serialize(&aw.writer) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }
};

/// Flat trees of regular files, which is all we write.
pub const Tree = struct {
    pub const Entry = struct {
        /// No `/` and no NUL.
        name: []const u8,
        oid: Oid,
    };

    pub const ParseError = error{InvalidTree} || Allocator.Error;

    /// Mode 100644, sorted by name (git's order for plain files).
    pub fn serializeAlloc(arena: Allocator, entries: []const Entry) Allocator.Error![]u8 {
        const sorted = try arena.dupe(Entry, entries);
        std.mem.sort(Entry, sorted, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
        var out: std.ArrayList(u8) = .empty;
        for (sorted) |e| {
            assert(e.name.len > 0 and std.mem.findAny(u8, e.name, "/\x00") == null);
            try out.appendSlice(arena, "100644 ");
            try out.appendSlice(arena, e.name);
            try out.append(arena, 0);
            try out.appendSlice(arena, e.oid.slice());
        }
        return out.items;
    }

    /// Any mode, so the simulator can copy whatever a tree references.
    pub fn parse(arena: Allocator, format: ObjectFormat, data: []const u8) ParseError![]Entry {
        var out: std.ArrayList(Entry) = .empty;
        var rest = data;
        const n = format.byteLen();
        while (rest.len > 0) {
            const space = std.mem.findScalar(u8, rest, ' ') orelse return error.InvalidTree;
            const nul = std.mem.findScalarPos(u8, rest, space, 0) orelse
                return error.InvalidTree;
            if (nul + 1 + n > rest.len) return error.InvalidTree;
            var oid: Oid = .{ .object_format = format, .bytes = @splat(0) };
            @memcpy(oid.bytes[0..n], rest[nul + 1 ..][0..n]);
            try out.append(arena, .{ .name = rest[space + 1 .. nul], .oid = oid });
            rest = rest[nul + 1 + n ..];
        }
        return out.items;
    }
};

const testing = std.testing;

test "tree serialization matches git mktree" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = [_]Tree.Entry{
        .{ .name = "b.png", .oid = hashObject(.sha1, .blob, "x") },
        .{ .name = "a.txt", .oid = hashObject(.sha1, .blob, "hello\n") },
    };
    const data = try Tree.serializeAlloc(arena, &entries);
    const oid = hashObject(.sha1, .tree, data).hex();
    try testing.expectEqualStrings("33012a818981664607f900af8ea22cfc0a66a89f", oid.slice());
    const back = try Tree.parse(arena, .sha1, data);
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqualStrings("a.txt", back[0].name);
    try testing.expectError(error.InvalidTree, Tree.parse(arena, .sha1, "100644 x\x00ab"));
}

test "empty tree matches git" {
    const sha1 = emptyTree(.sha1).hex();
    try testing.expectEqualStrings("4b825dc642cb6eb9a060e54bf8d69288fbee4904", sha1.slice());
    const sha256 = emptyTree(.sha256).hex();
    try testing.expectEqualStrings(
        "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321",
        sha256.slice(),
    );
}

test "oid hex round trip and rejection" {
    const hex = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
    const oid = try Oid.parseHex(.sha1, hex);
    try testing.expectEqualStrings(hex, oid.hex().slice());
    try testing.expectError(error.InvalidOid, Oid.parseHex(.sha1, hex[0..7]));
    try testing.expectError(
        error.InvalidOid,
        Oid.parseHex(.sha1, "4B825DC642CB6EB9A060E54BF899D15006578022"),
    );
    try testing.expectError(
        error.InvalidOid,
        Oid.parseHex(.sha1, "4b825dc642cb6eb9a060e54bf8d69288fbee490g"),
    );
    try testing.expectError(error.InvalidOid, Oid.parseHex(.sha256, hex));
}

test "signature parse and format round trip" {
    const line = "Jane Doe <jane@example.com> 1700000000 -0130";
    const sig = try Signature.parse(line);
    try testing.expectEqualStrings("Jane Doe", sig.name);
    try testing.expectEqualStrings("jane@example.com", sig.email);
    try testing.expectEqual(@as(i64, 1700000000), sig.time);
    try testing.expectEqual(@as(i16, -90), sig.tz_offset_minutes);
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f}", .{sig});
    try testing.expectEqualStrings(line, w.buffered());
    try testing.expectError(error.InvalidSignature, Signature.parse("no email 1 +0000"));
    try testing.expectError(error.InvalidSignature, Signature.parse("A <a@b> x +0000"));
    try testing.expectError(error.InvalidSignature, Signature.parse("A <a@b> 1 +0060"));
}

test "commit serialize/parse round trip" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sig: Signature = .{ .name = "T", .email = "t@e.x", .time = 1, .tz_offset_minutes = 0 };
    const parent = try Oid.parseHex(.sha1, "1111111111111111111111111111111111111111");
    const commit: Commit = .{
        .tree = emptyTree(.sha1),
        .parents = &.{parent},
        .author = sig,
        .committer = sig,
        .message = "Title\n\nBody\n\nState: open\n",
    };
    const raw = try commit.serializeAlloc(arena);
    try testing.expectEqualStrings(
        "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n" ++
            "parent 1111111111111111111111111111111111111111\n" ++
            "author T <t@e.x> 1 +0000\n" ++
            "committer T <t@e.x> 1 +0000\n" ++
            "\nTitle\n\nBody\n\nState: open\n",
        raw,
    );
    const back = try Commit.parse(arena, .sha1, raw);
    try testing.expect(back.tree.eql(commit.tree));
    try testing.expectEqual(@as(usize, 1), back.parents.len);
    try testing.expect(back.parents[0].eql(parent));
    try testing.expectEqualStrings(commit.message, back.message);
}

test "commit parse skips unknown headers" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const raw = "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n" ++
        "author T <t@e.x> 1 +0000\n" ++
        "committer T <t@e.x> 1 +0000\n" ++
        "gpgsig -----BEGIN PGP SIGNATURE-----\n" ++
        " abc\n" ++
        " -----END PGP SIGNATURE-----\n" ++
        "\nMsg\n";
    const c = try Commit.parse(arena_state.allocator(), .sha1, raw);
    try testing.expectEqualStrings("Msg\n", c.message);
    try testing.expectEqual(@as(usize, 0), c.parents.len);
}

test "commit parse rejects malformed input" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.InvalidCommit, Commit.parse(arena, .sha1, "garbage"));
    try testing.expectError(error.InvalidCommit, Commit.parse(arena, .sha1, "tree 123\n\nmsg\n"));
    try testing.expectError(
        error.InvalidCommit,
        Commit.parse(
            arena,
            .sha1,
            "author T <t@e.x> 1 +0000\ncommitter T <t@e.x> 1 +0000\n\nmsg\n",
        ),
    );
}

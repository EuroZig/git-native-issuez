//! Attachment trailers, LFS pointers and image sniffing.
//!
//!     X-Attachment: <uuid> <media-type> <size> sha256:<hex> <name>
//!     X-Attachment-Removed: <uuid>

const std = @import("std");
const Allocator = std.mem.Allocator;
const uuid_fmt = @import("uuid.zig");
const hex_fmt = @import("hex.zig");

pub const add_key = "X-Attachment";
pub const remove_key = "X-Attachment-Removed";

/// Default write limits, see `Limits`.
pub const max_per_issue = 30;
pub const max_bytes = 5 * 1024 * 1024;
/// The largest size a trailer may state.
pub const max_object_bytes = 64 * 1024 * 1024;
pub const max_name_bytes = 255;

pub const Media = enum {
    png,
    jpeg,
    webp,

    pub fn mediaType(m: Media) []const u8 {
        return switch (m) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .webp => "image/webp",
        };
    }

    /// In the derived tree.
    pub fn extension(m: Media) []const u8 {
        return switch (m) {
            .png => "png",
            .jpeg => "jpg",
            .webp => "webp",
        };
    }

    pub fn parse(s: []const u8) ?Media {
        inline for (.{ Media.png, Media.jpeg, Media.webp }) |m| {
            if (std.mem.eql(u8, s, m.mediaType())) return m;
        }
        return null;
    }
};

/// 64 lowercase hex characters.
pub const Sha256 = struct {
    hex: [64]u8,

    pub fn of(data: []const u8) Sha256 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        return .{ .hex = std.fmt.bytesToHex(digest, .lower) };
    }

    pub fn parse(s: []const u8) ?Sha256 {
        if (s.len != 64 or !hex_fmt.isLower(s)) return null;
        var out: Sha256 = .{ .hex = undefined };
        @memcpy(&out.hex, s);
        return out;
    }

    pub fn slice(s: *const Sha256) []const u8 {
        return &s.hex;
    }

    pub fn eql(a: Sha256, b: Sha256) bool {
        return std.mem.eql(u8, &a.hex, &b.hex);
    }
};

pub const Spec = struct {
    id: []const u8,
    media: Media,
    size: u32,
    sha256: Sha256,
    name: []const u8,

    /// Hash, size and media type. The name may differ.
    pub fn sameObject(a: Spec, b: Spec) bool {
        return a.media == b.media and a.size == b.size and a.sha256.eql(b.sha256);
    }

    pub fn format(s: Spec, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} {s} {d} sha256:{s} {s}", .{
            s.id,
            s.media.mediaType(),
            s.size,
            &s.sha256.hex,
            s.name,
        });
    }
};

/// Null when the value doesn't follow the grammar.
pub fn parseSpec(value: []const u8) ?Spec {
    var it = std.mem.splitScalar(u8, value, ' ');
    const id = it.next() orelse return null;
    if (!uuid_fmt.isCanonical(id)) return null;
    const media = Media.parse(it.next() orelse return null) orelse return null;
    const size_text = it.next() orelse return null;
    if (size_text.len == 0 or (size_text.len > 1 and size_text[0] == '0')) return null;
    for (size_text) |c| if (!std.ascii.isDigit(c)) return null;
    const size = std.fmt.parseInt(u32, size_text, 10) catch return null;
    if (size == 0 or size > max_object_bytes) return null;
    const hash_text = it.next() orelse return null;
    if (!std.mem.startsWith(u8, hash_text, "sha256:")) return null;
    const sha = Sha256.parse(hash_text["sha256:".len..]) orelse return null;
    const name = it.rest();
    if (!isCleanName(name)) return null;
    return .{ .id = id, .media = media, .size = size, .sha256 = sha, .name = name };
}

/// Non-empty, at most 255 bytes of UTF-8, no control characters, no
/// leading or trailing space.
pub fn isCleanName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    if (name[0] == ' ' or name[name.len - 1] == ' ') return false;
    if (!std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// Last path component, control characters as spaces, trimmed, cut to 255
/// bytes on a UTF-8 boundary. "attachment" when nothing is left.
pub fn sanitizeName(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var base = raw;
    if (std.mem.findLastAny(u8, base, "/\\")) |i| base = base[i + 1 ..];
    var out: std.ArrayList(u8) = .empty;
    var view = std.unicode.Utf8View.init(base) catch blk: {
        // Not UTF-8: keep printable ASCII.
        for (base) |c| if (c >= 0x20 and c < 0x7f) try out.append(arena, c);
        break :blk null;
    };
    if (view) |*v| {
        var cps = v.iterator();
        while (cps.nextCodepointSlice()) |cp| {
            if (cp.len == 1 and (cp[0] < 0x20 or cp[0] == 0x7f)) {
                try out.append(arena, ' ');
            } else if (out.items.len + cp.len <= max_name_bytes) {
                try out.appendSlice(arena, cp);
            } else break;
        }
    }
    const trimmed = std.mem.trim(u8, out.items, " ");
    if (trimmed.len == 0) return "attachment";
    return trimmed;
}

/// Fully determined by hash and size.
pub fn lfsPointer(arena: Allocator, sha: Sha256, size: u32) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "version https://git-lfs.github.com/spec/v1\noid sha256:{s}\nsize {d}\n",
        .{ &sha.hex, size },
    );
}

pub const SniffError = error{
    UnsupportedType,
    Animated,
};

/// Media type from the magic bytes. Animated images are rejected.
pub fn sniff(data: []const u8) SniffError!Media {
    const png_magic = "\x89PNG\r\n\x1a\n";
    if (std.mem.startsWith(u8, data, png_magic)) {
        // Chunks are length (big endian u32), type, data, CRC. An `acTL`
        // before the first `IDAT` means APNG.
        var pos: usize = png_magic.len;
        while (pos + 8 <= data.len) {
            const len = std.mem.readInt(u32, data[pos..][0..4], .big);
            const kind = data[pos + 4 .. pos + 8];
            if (std.mem.eql(u8, kind, "acTL")) return error.Animated;
            if (std.mem.eql(u8, kind, "IDAT") or std.mem.eql(u8, kind, "IEND")) break;
            pos = std.math.add(usize, pos, 12 + @as(usize, len)) catch break;
        }
        return .png;
    }
    if (data.len >= 3 and data[0] == 0xff and data[1] == 0xd8 and data[2] == 0xff) return .jpeg;
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and
        std.mem.eql(u8, data[8..12], "WEBP"))
    {
        var pos: usize = 12;
        while (pos + 8 <= data.len) {
            const kind = data[pos .. pos + 4];
            const len = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
            if (std.mem.eql(u8, kind, "ANIM") or std.mem.eql(u8, kind, "ANMF"))
                return error.Animated;
            // VP8X flags: bit 1 is animation.
            if (std.mem.eql(u8, kind, "VP8X") and pos + 8 < data.len and
                data[pos + 8] & 0x02 != 0) return error.Animated;
            const padded = @as(usize, len) + (len & 1);
            pos = std.math.add(usize, pos, 8 + padded) catch break;
        }
        return .webp;
    }
    return error.UnsupportedType;
}

const testing = std.testing;

/// Tiny images for tests and the fuzzer.
pub const samples = struct {
    pub const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01" ++
        "\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x00IEND\xaeB`\x82";
    pub const apng = "\x89PNG\r\n\x1a\n\x00\x00\x00\x08acTL\x00\x00\x00\x01\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00IEND\xaeB`\x82";
    pub const jpeg = "\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xd9";
    pub const webp = "RIFF\x1a\x00\x00\x00WEBPVP8L\x0d\x00\x00\x00\x2f\x00\x00\x00\x10" ++
        "\x07\x10\x11\x11\x88\x88\xfe\x07\x00";
    pub const animated_webp = "RIFF\x1e\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x02\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00";
    pub const text = "just some text\n";
};

test "sniff: types, animation, garbage" {
    try testing.expectEqual(Media.png, try sniff(samples.png));
    try testing.expectEqual(Media.jpeg, try sniff(samples.jpeg));
    try testing.expectEqual(Media.webp, try sniff(samples.webp));
    try testing.expectError(error.Animated, sniff(samples.apng));
    try testing.expectError(error.Animated, sniff(samples.animated_webp));
    try testing.expectError(error.UnsupportedType, sniff(samples.text));
    try testing.expectError(error.UnsupportedType, sniff(""));
    // Truncated chunks never read out of bounds.
    for (0..samples.png.len) |n| _ = sniff(samples.png[0..n]) catch {};
    for (0..samples.animated_webp.len) |n| _ = sniff(samples.animated_webp[0..n]) catch {};
}

test "spec: round trip and rejects" {
    var buf: [400]u8 = undefined;
    const sha = Sha256.of(samples.png);
    const spec: Spec = .{
        .id = "1b4e28ba-2fa1-4d3b-a3f5-ef19b5a7633b",
        .media = .png,
        .size = samples.png.len,
        .sha256 = sha,
        .name = "Screenshot 2026-10-18.png",
    };
    const text = try std.fmt.bufPrint(&buf, "{f}", .{spec});
    const back = parseSpec(text).?;
    try testing.expect(back.sameObject(spec));
    try testing.expectEqualStrings(spec.name, back.name);

    const id = "1b4e28ba-2fa1-4d3b-a3f5-ef19b5a7633b";
    const h = "sha256:" ++ "a" ** 64;
    for ([_][]const u8{
        "",
        id,
        id ++ " image/gif 10 " ++ h ++ " x",
        id ++ " image/png 0 " ++ h ++ " x",
        id ++ " image/png 012 " ++ h ++ " x",
        id ++ " image/png 999999999 " ++ h ++ " x",
        id ++ " image/png 10 sha256:ABC x",
        id ++ " image/png 10 " ++ h,
        id ++ " image/png 10 " ++ h ++ " ",
        id ++ " image/png 10 " ++ h ++ "  lead",
        "not-a-uuid image/png 10 " ++ h ++ " x",
    }) |bad| try testing.expect(parseSpec(bad) == null);
    try testing.expect(parseSpec(id ++ " image/png 10 " ++ h ++ " a b  c") != null);
}

test "sanitizeName" {
    const a = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("shot.png", try sanitizeName(arena, "/tmp/x/shot.png"));
    try testing.expectEqualStrings("a b", try sanitizeName(arena, "a\nb"));
    try testing.expectEqualStrings("attachment", try sanitizeName(arena, " \t "));
    try testing.expectEqualStrings("ok", try sanitizeName(arena, "\xffok"));
    const long = try sanitizeName(arena, "é" ** 200);
    try testing.expect(long.len <= max_name_bytes and isCleanName(long));
}

test "lfsPointer" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const p = try lfsPointer(arena_state.allocator(), Sha256.parse("ab" ** 32).?, 12);
    try testing.expectEqualStrings(
        "version https://git-lfs.github.com/spec/v1\noid sha256:" ++ "ab" ** 32 ++ "\nsize 12\n",
        p,
    );
}

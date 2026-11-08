//! The header the compiler sees against the library's description of
//! itself: record sizes, field offsets and enum
//! values. Catches a header and a library out of step.

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const c = fixture.c;

const api_json = @embedFile("issuez-api.json");

const Api = struct {
    types: []const struct {
        name: []const u8,
        kind: []const u8,
        size: ?usize = null,
        fields: []const struct { name: []const u8, offset: usize } = &.{},
        values: []const struct { name: []const u8, value: i64 } = &.{},
    },
};

const FieldLayout = struct { name: []const u8, offset: usize };

const Layout = struct {
    name: []const u8,
    size: usize,
    fields: []const FieldLayout,
};

/// Macros C can use and Zig can't translate.
fn untranslatable(name: []const u8) bool {
    return std.mem.eql(u8, name, "ISSUEZ_OP_INIT");
}

/// Every `issuez_*` struct in the translated header.
const layouts = blk: {
    @setEvalBranchQuota(200_000);
    var out: []const Layout = &.{};
    for (@typeInfo(c).@"struct".decls) |d| {
        if (!std.mem.startsWith(u8, d.name, "issuez_")) continue;
        const v = @field(c, d.name);
        if (@TypeOf(v) != type) continue;
        const info = @typeInfo(v);
        if (info != .@"struct" or info.@"struct".layout != .@"extern") continue;
        var fields: []const FieldLayout = &.{};
        for (info.@"struct".fields) |f| fields = fields ++ [_]FieldLayout{.{
            .name = f.name,
            .offset = @offsetOf(v, f.name),
        }};
        out = out ++ [_]Layout{.{ .name = d.name, .size = @sizeOf(v), .fields = fields }};
    }
    break :blk out;
};

const Constant = struct { name: []const u8, value: i64 };

/// Every `ISSUEZ_*` integer constant in the translated header.
const constants = blk: {
    @setEvalBranchQuota(200_000);
    var out: []const Constant = &.{};
    for (@typeInfo(c).@"struct".decls) |d| {
        if (!std.mem.startsWith(u8, d.name, "ISSUEZ_") or untranslatable(d.name)) continue;
        const v = @field(c, d.name);
        switch (@typeInfo(@TypeOf(v))) {
            .int, .comptime_int => out = out ++ [_]Constant{.{ .name = d.name, .value = v }},
            else => {},
        }
    }
    break :blk out;
};

fn layoutOf(name: []const u8) ?Layout {
    for (layouts) |l| if (std.mem.eql(u8, l.name, name)) return l;
    return null;
}

fn constantOf(name: []const u8) ?i64 {
    for (constants) |k| if (std.mem.eql(u8, k.name, name)) return k.value;
    return null;
}

test "abi: records, inputs and values have the library's layout" {
    const arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    var arena = arena_state;
    defer arena.deinit();
    const api = try std.json.parseFromSliceLeaky(Api, arena.allocator(), api_json, .{
        .ignore_unknown_fields = true,
    });
    var checked: usize = 0;
    for (api.types) |t| {
        const sized = std.mem.eql(u8, t.kind, "record") or std.mem.eql(u8, t.kind, "input") or
            std.mem.eql(u8, t.kind, "value");
        if (!sized) continue;
        const l = layoutOf(t.name) orelse {
            std.debug.print("{s} isn't in the header\n", .{t.name});
            return error.MissingType;
        };
        testing.expectEqual(t.size.?, l.size) catch |e| {
            std.debug.print("{s}: size\n", .{t.name});
            return e;
        };
        try testing.expectEqual(t.fields.len, l.fields.len);
        for (t.fields, l.fields) |want, got| {
            try testing.expectEqualStrings(want.name, got.name);
            testing.expectEqual(want.offset, got.offset) catch |e| {
                std.debug.print("{s}.{s}: offset\n", .{ t.name, want.name });
                return e;
            };
        }
        checked += 1;
    }
    try testing.expect(checked >= 19);
}

test "abi: enum values are the library's" {
    const arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    var arena = arena_state;
    defer arena.deinit();
    const api = try std.json.parseFromSliceLeaky(Api, arena.allocator(), api_json, .{
        .ignore_unknown_fields = true,
    });
    var checked: usize = 0;
    for (api.types) |t| {
        if (!std.mem.eql(u8, t.kind, "enum")) continue;
        for (t.values) |v| {
            const got = constantOf(v.name) orelse {
                std.debug.print("{s} isn't in the header\n", .{v.name});
                return error.MissingConstant;
            };
            testing.expectEqual(v.value, got) catch |e| {
                std.debug.print("{s}\n", .{v.name});
                return e;
            };
            checked += 1;
        }
    }
    try testing.expect(checked > 100);
}

test "abi: reserved fields must be zero" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var problems: ?*c.issuez_problems = null;
    var op = std.mem.zeroes(c.issuez_op);
    op.verb = c.ISSUEZ_OP_SET;
    op.target = c.ISSUEZ_FIELD_TITLE;
    op.str = fixture.str("A title");
    op.reserved[1] = 1;
    try testing.expectEqual(
        @as(c.issuez_code, c.ISSUEZ_OK),
        c.issuez_ops_validate(c.ISSUEZ_LIST_ISSUE_CREATE, &op, 1, &problems, null),
    );
    try testing.expectEqual(@as(usize, 1), c.issuez_problems_len(problems));
    const p = c.issuez_problems_at(problems, 0).*;
    try testing.expectEqual(@as(u32, c.ISSUEZ_PROBLEM_BAD_FORMAT), p.kind);
    try testing.expectEqual(@as(i64, 0), p.op_index);
    c.issuez_problems_free(problems);
}

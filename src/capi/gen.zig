//! Writes `issuez.h` and `issuez-api.json` from `api.zig`.
//!
//!     issuez-gen <header path> <json path>

const std = @import("std");
const api = @import("api.zig");

const Writer = std.Io.Writer;

var arena: std.mem.Allocator = undefined;

pub fn main(init: std.process.Init) !u8 {
    arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: issuez-gen <header> <json>\n", .{});
        return 2;
    }
    var header: Writer.Allocating = .init(arena);
    try writeHeader(&header.writer);
    var json: Writer.Allocating = .init(arena);
    try writeJson(&json.writer);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(init.io, .{ .sub_path = args[1], .data = header.written() });
    try cwd.writeFile(init.io, .{ .sub_path = args[2], .data = json.written() });
    return 0;
}

// ─── C types ───────────────────────────────────────────────────────────

fn cType(comptime T: type) []const u8 {
    comptime return cTypeOf(T);
}

fn cTypeOf(comptime T: type) []const u8 {
    if (T == api.Code) return "issuez_code";
    if (T == api.LogFn) return "issuez_log_fn";
    if (T == c_int) return "int";
    if (T == anyopaque) return "void";
    if (T == usize) return "size_t";
    return switch (@typeInfo(T)) {
        .void => "void",
        .bool => "bool",
        .int => |i| (if (i.signedness == .signed) "int" else "uint") ++
            std.fmt.comptimePrint("{d}_t", .{i.bits}),
        .optional => |o| cType(o.child),
        .pointer => |p| ptr: {
            const base = if (p.child == u8) "char" else cType(p.child);
            const qualifier = if (p.attrs.@"const") "const " else "";
            break :ptr qualifier ++ base ++ (if (base[base.len - 1] == '*') "*" else " *");
        },
        .@"struct", .@"enum", .@"opaque" => T.c_name,
        else => @compileError("no C type for " ++ @typeName(T)),
    };
}

/// `const issuez_oid *oid`, `size_t n`, `uint8_t bytes[32]`.
fn cDecl(comptime T: type, comptime name: []const u8) []const u8 {
    comptime {
        if (@typeInfo(T) == .array) {
            const a = @typeInfo(T).array;
            return cType(a.child) ++ " " ++ name ++ std.fmt.comptimePrint("[{d}]", .{a.len});
        }
        const t = cType(T);
        return t ++ (if (t[t.len - 1] == '*') "" else " ") ++ name;
    }
}

fn upper(comptime s: []const u8) []const u8 {
    comptime {
        var buf: [s.len]u8 = undefined;
        for (s, &buf) |c, *o| o.* = std.ascii.toUpper(c);
        const out = buf;
        return &out;
    }
}

fn enumConst(comptime T: type, comptime field: []const u8) []const u8 {
    comptime return T.c_prefix ++ upper(field);
}

/// The `///` comment on a field of `T` in api.zig, lines joined.
fn docOf(comptime T: type, name: []const u8) ![]const u8 {
    const source = @embedFile("api.zig");
    const type_name = comptime std.fs.path.extension(@typeName(T))[1..];
    const start = std.mem.indexOf(u8, source, "pub const " ++ type_name ++ " = ").?;
    var lines = std.mem.splitScalar(u8, source[start..], '\n');
    var doc: std.ArrayList(u8) = .empty;
    while (lines.next()) |raw| {
        if (std.mem.eql(u8, raw, "};")) break;
        const line = std.mem.trim(u8, raw, " ");
        if (std.mem.startsWith(u8, line, "/// ")) {
            if (doc.items.len > 0) try doc.append(arena, ' ');
            try doc.appendSlice(arena, line[4..]);
        } else if (std.mem.startsWith(u8, line, name) and line.len > name.len and
            std.mem.indexOfScalar(u8, ":, ", line[name.len]) != null)
        {
            return doc.items;
        } else {
            doc.clearRetainingCapacity();
        }
    }
    return "";
}

// ─── Header ────────────────────────────────────────────────────────────

const width = 100;

fn writeHeader(w: *Writer) !void {
    @setEvalBranchQuota(1_000_000);
    try comment(w, "", api.preamble, true);
    try w.writeAll(
        \\#ifndef ISSUEZ_H
        \\#define ISSUEZ_H
        \\
        \\#include <stdbool.h>
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    );
    inline for (api.items) |item| {
        switch (item) {
            .section => |s| {
                try w.print("\n/* ---------------------------------------- {s} ", .{s[0]});
                try w.splatByteAll('-', width - 48 - s[0].len - 3);
                try w.writeAll(" */\n");
                if (s[1].len > 0) try comment(w, "", s[1], false);
                try w.writeAll("\n");
            },
            .prose => |p| try comment(w, "", p, false),
            .raw => |r| {
                try w.writeAll(comptime replaceVersion(r));
                try w.writeAll("\n\n");
            },
            .handles => |hs| {
                inline for (hs) |H| try w.print(
                    "typedef struct {s} {s};\n",
                    .{ H.c_name, H.c_name },
                );
                try w.writeAll("\n");
            },
            .type => |T| try writeType(w, T),
            .func => |func| try writeFunc(w, func),
            .helpers => |hs| inline for (hs) |h| try writeHelper(w, h),
        }
    }
    try w.writeAll(
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* ISSUEZ_H */
        \\
    );
}

fn replaceVersion(comptime r: []const u8) []const u8 {
    comptime {
        var s: []const u8 = r;
        for (.{
            .{ "@MAJOR@", api.version.major },
            .{ "@MINOR@", api.version.minor },
            .{ "@PATCH@", api.version.patch },
        }) |pair| {
            const at = std.mem.indexOf(u8, s, pair[0]) orelse continue;
            s = s[0..at] ++ std.fmt.comptimePrint("{d}", .{pair[1]}) ++ s[at + pair[0].len ..];
        }
        return s;
    }
}

/// A `/* ... */` block, words wrapped; lines that start with a space or
/// are blank keep their layout (lists, tables).
fn comment(w: *Writer, indent: []const u8, text: []const u8, keep_lines: bool) !void {
    if (text.len == 0) return;
    try w.print("{s}/*", .{indent});
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (keep_lines or line.len == 0 or line[0] == ' ') {
            if (first) try w.writeAll("\n");
            if (line.len == 0) {
                try w.print("{s} *\n", .{indent});
            } else {
                try w.print("{s} * {s}\n", .{ indent, line });
            }
            first = false;
            continue;
        }
        var col: usize = 0;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        while (words.next()) |word| {
            if (col == 0) {
                try w.print("{s}{s} * {s}", .{ if (first) "\n" else "", indent, word });
                first = false;
                col = indent.len + 3 + word.len;
            } else if (col + 1 + word.len > 80) {
                try w.print("\n{s} * {s}", .{ indent, word });
                col = indent.len + 3 + word.len;
            } else {
                try w.print(" {s}", .{word});
                col += 1 + word.len;
            }
        }
        try w.writeAll("\n");
    }
    try w.print("{s} */\n", .{indent});
}

fn writeType(w: *Writer, comptime T: type) !void {
    switch (@typeInfo(T)) {
        .@"enum" => |e| {
            try w.print("typedef enum {s} {{\n", .{T.c_name});
            inline for (e.field_names, e.field_values) |name, value| {
                const line = comptime std.fmt.comptimePrint("    {s} = {d},", .{
                    enumConst(T, name),
                    value,
                });
                const doc = try docOf(T, name);
                if (doc.len == 0) {
                    try w.print("{s}\n", .{line});
                } else if (line.len + doc.len + 7 <= width) {
                    try w.print("{s} /* {s} */\n", .{ line, doc });
                } else {
                    try w.print("    /* {s} */\n{s}\n", .{ doc, line });
                }
            }
            try w.print("}} {s};\n\n", .{T.c_name});
        },
        .@"struct" => |s| {
            try w.print("typedef struct {s} {{\n", .{T.c_name});
            inline for (s.field_names, s.field_types) |name, FieldT| {
                const line = comptime "    " ++ cDecl(FieldT, name) ++ ";";
                const doc = try docOf(T, name);
                if (doc.len == 0) {
                    try w.print("{s}\n", .{line});
                } else if (line.len + doc.len + 7 <= width) {
                    try w.print("{s} /* {s} */\n", .{ line, doc });
                } else {
                    try w.print("    /* {s} */\n{s}\n", .{ doc, line });
                }
            }
            try w.print("}} {s};\n\n", .{T.c_name});
        },
        else => @compileError("not a C type: " ++ @typeName(T)),
    }
}

fn funcInfo(comptime func: api.Func) std.lang.Type.Fn {
    const info = @typeInfo(func.T).@"fn";
    if (info.param_types.len != func.params.len)
        @compileError(func.name ++ ": parameter names don't match the type");
    return info;
}

fn writeFunc(w: *Writer, comptime func: api.Func) !void {
    const info = comptime funcInfo(func);
    if (func.doc.len > 0) try comment(w, "", func.doc, false);
    const head = comptime cDecl(info.return_type.?, func.name) ++ "(";
    const params = comptime ps: {
        var list: []const []const u8 = &.{};
        for (info.param_types, func.params) |p, name| list = list ++ .{cDecl(p.?, name)};
        break :ps list;
    };
    var total: usize = head.len + 2;
    for (params) |p| total += p.len + 2;
    try w.writeAll(head);
    if (params.len == 0) {
        try w.writeAll("void);\n\n");
        return;
    }
    if (total <= width) {
        for (params, 0..) |p, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(p);
        }
        try w.writeAll(");\n\n");
        return;
    }
    // Wrapped: as many parameters per line as fit, aligned after "(".
    const indent = if (head.len < 40) head.len else 4;
    var col: usize = head.len;
    for (params, 0..) |p, i| {
        const last = i == params.len - 1;
        const piece_len: usize = p.len + @as(usize, if (last) 2 else 1);
        if (i > 0) {
            if (col + 1 + piece_len > width) {
                try w.writeAll("\n");
                try w.splatByteAll(' ', indent);
                col = indent;
            } else {
                try w.writeAll(" ");
                col += 1;
            }
        } else if (indent == 4) {
            try w.writeAll("\n    ");
            col = 4;
        }
        try w.writeAll(p);
        try w.writeAll(if (last) ");" else ",");
        col += piece_len;
    }
    try w.writeAll("\n\n");
}

fn targetConst(comptime target: []const u8) []const u8 {
    // "opt:" names an option that shares a field's name.
    if (std.mem.startsWith(u8, target, "opt:")) return enumConst(api.Opt, target[4..]);
    if (@hasField(api.Field, target)) return enumConst(api.Field, target);
    if (@hasField(api.Opt, target)) return enumConst(api.Opt, target);
    @compileError("unknown op target " ++ target);
}

fn writeHelper(w: *Writer, comptime h: api.Helper) !void {
    const num = h.num_type ++ " " ++ h.param;
    const num2 = h.num2_type ++ " " ++ h.param2;
    const params, const sets = comptime switch (h.slot) {
        .str => .{ "issuez_str " ++ h.param, "    o.str = " ++ h.param ++ ";\n" },
        .num => .{ num, "    o.num = " ++ h.param ++ ";\n" },
        .date => .{ "issuez_date " ++ h.param, "    o.date = " ++ h.param ++ ";\n" },
        .oid => .{ "issuez_oid " ++ h.param, "    o.oid = " ++ h.param ++ ";\n" },
        .person => .{ "issuez_person " ++ h.param, "    o.person = " ++ h.param ++ ";\n" },
        .none => .{ "void", "" },
        .name_str => .{
            "issuez_str key, issuez_str value",
            "    o.name = key;\n    o.str = value;\n",
        },
        .committer => .{
            "issuez_str name, issuez_str email",
            "    o.person.name = name;\n    o.person.email = email;\n",
        },
        .num_str => .{
            num ++ ", issuez_str " ++ h.param2,
            "    o.num = " ++ h.param ++ ";\n    o.str = " ++ h.param2 ++ ";\n",
        },
        .str_num => .{
            "issuez_str " ++ h.param ++ ", " ++ num2,
            "    o.str = " ++ h.param ++ ";\n    o.num = " ++ h.param2 ++ ";\n",
        },
        .num_num2 => .{
            num ++ ", " ++ num2,
            "    o.num = " ++ h.param ++ ";\n    o.num2 = " ++ h.param2 ++ ";\n",
        },
        .name_num => .{
            "issuez_str name, " ++ num,
            "    o.name = name;\n    o.num = " ++ h.param ++ ";\n",
        },
        .attachment => .{
            "issuez_str id, issuez_str name, issuez_str data",
            "    o.id = id;\n    o.name = name;\n    o.str = data;\n",
        },
    };
    try w.print(
        \\static inline issuez_op {s}({s}) {{
        \\    issuez_op o = ISSUEZ_OP_INIT;
        \\    o.verb = {s};
        \\    o.target = {s};
        \\{s}    return o;
        \\}}
        \\
    , .{
        h.name,
        params,
        comptime enumConst(api.Verb, @tagName(h.verb)),
        comptime targetConst(h.target),
        sets,
    });
}

// ─── JSON ──────────────────────────────────────────────────────────────

fn str(w: *Writer, s: []const u8) !void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

fn writeJson(w: *Writer) !void {
    @setEvalBranchQuota(1_000_000);
    try w.print(
        "{{\n  \"version\": \"{d}.{d}.{d}\",\n  \"abi_version\": {d},\n  \"types\": [",
        .{ api.version.major, api.version.minor, api.version.patch, api.abi_version },
    );
    var first = true;
    inline for (api.items) |item| {
        switch (item) {
            .handles => |hs| inline for (hs) |H| {
                try sep(w, &first);
                try w.writeAll("{\"name\": ");
                try str(w, H.c_name);
                try w.writeAll(", \"kind\": \"handle\"}");
            },
            .type => |T| {
                try sep(w, &first);
                try jsonType(w, T);
            },
            else => {},
        }
    }
    try w.writeAll("\n  ],\n  \"functions\": [");
    first = true;
    comptime var section: []const u8 = "";
    inline for (api.items) |item| {
        switch (item) {
            .section => |s| section = s[0],
            .func => |func| {
                const info = comptime funcInfo(func);
                try sep(w, &first);
                try w.writeAll("{\"name\": ");
                try str(w, func.name);
                try w.writeAll(", \"section\": ");
                try str(w, section);
                try w.writeAll(", \"returns\": ");
                try str(w, comptime cType(info.return_type.?));
                try w.writeAll(", \"params\": [");
                inline for (info.param_types, func.params, 0..) |p, name, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll("{\"name\": ");
                    try str(w, name);
                    try w.writeAll(", \"type\": ");
                    try str(w, comptime cDecl(p.?, ""));
                    try w.writeAll("}");
                }
                try w.writeAll("], \"doc\": ");
                try str(w, func.doc);
                try w.writeAll("}");
            },
            else => {},
        }
    }
    try w.writeAll("\n  ],\n  \"helpers\": [");
    first = true;
    inline for (api.helpers) |h| {
        try sep(w, &first);
        try w.writeAll("{\"name\": ");
        try str(w, h.name);
        try w.writeAll(", \"verb\": ");
        try str(w, comptime enumConst(api.Verb, @tagName(h.verb)));
        try w.writeAll(", \"target\": ");
        try str(w, comptime targetConst(h.target));
        try w.writeAll(", \"slot\": ");
        try str(w, @tagName(h.slot));
        try w.writeAll("}");
    }
    try w.writeAll("\n  ]\n}\n");
}

fn sep(w: *Writer, first: *bool) !void {
    try w.writeAll(if (first.*) "\n    " else ",\n    ");
    first.* = false;
}

fn jsonType(w: *Writer, comptime T: type) !void {
    try w.writeAll("{\"name\": ");
    try str(w, T.c_name);
    switch (@typeInfo(T)) {
        .@"enum" => |e| {
            try w.writeAll(", \"kind\": \"enum\", \"values\": [");
            inline for (e.field_names, e.field_values, 0..) |name, value, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll("{\"name\": ");
                try str(w, comptime enumConst(T, name));
                try w.print(", \"value\": {d}, \"doc\": ", .{value});
                try str(w, try docOf(T, name));
                try w.writeAll("}");
            }
        },
        .@"struct" => |s| {
            try w.writeAll(", \"kind\": ");
            try str(w, @tagName(T.type_kind));
            try w.print(", \"size\": {d}, \"fields\": [", .{@sizeOf(T)});
            inline for (s.field_names, s.field_types, 0..) |name, FieldT, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll("{\"name\": ");
                try str(w, name);
                try w.writeAll(", \"type\": ");
                try str(w, comptime cDecl(FieldT, ""));
                try w.print(", \"offset\": {d}, \"doc\": ", .{@offsetOf(T, name)});
                try str(w, try docOf(T, name));
                try w.writeAll("}");
            }
        },
        else => unreachable,
    }
    try w.writeAll("]}");
}

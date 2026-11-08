//! The C library: exports every function `api.zig` declares. Each one is
//! looked up in the implementation files below and must have exactly the
//! declared type; a function without an implementation is exported as a
//! stub that fails with ISSUEZ_E_UNSUPPORTED (or returns nothing), so the
//! header is complete from the start.

const std = @import("std");
const api = @import("api.zig");
const rt = @import("rt.zig");

const impls = .{
    rt,
    @import("repo.zig"),
    @import("read.zig"),
    @import("write.zig"),
    @import("more.zig"),
    @import("watch.zig"),
    @import("store.zig"),
};

comptime {
    // For the Zig suite's leak check; never in the header.
    if (@import("capi_options").debug) @export(&debugLiveAllocations, .{
        .name = "issuez__debug_live_allocations",
    });
}

fn debugLiveAllocations() callconv(.c) i64 {
    return rt.liveAllocations();
}

comptime {
    @setEvalBranchQuota(1_000_000);
    for (api.items) |item| switch (item) {
        .func => |func| exportFunc(func),
        else => {},
    };
    // The other way round: nothing exported that the API doesn't declare.
    for (impls) |m| for (@typeInfo(m).@"struct".decls) |d| {
        if (std.mem.startsWith(u8, d.name, "issuez_") and !declared(d.name))
            @compileError(d.name ++ " is implemented but not declared in api.zig");
    };
}

fn declared(comptime name: []const u8) bool {
    for (api.items) |item| switch (item) {
        .func => |func| if (std.mem.eql(u8, func.name, name)) return true,
        else => {},
    };
    return false;
}

fn exportFunc(comptime func: api.Func) void {
    for (impls) |m| if (@hasDecl(m, func.name)) {
        const impl = @field(m, func.name);
        if (@TypeOf(impl) != func.T) @compileError(func.name ++ " has type " ++
            @typeName(@TypeOf(impl)) ++ ", api.zig declares " ++ @typeName(func.T));
        @export(&impl, .{ .name = func.name });
        return;
    };
    @export(&stub(func.T), .{ .name = func.name });
}

/// Implemented functions, for tests and `zig build capi-status`.
pub fn isImplemented(comptime name: []const u8) bool {
    inline for (impls) |m| if (@hasDecl(m, name)) return true;
    return false;
}

fn stub(comptime F: type) F {
    const info = @typeInfo(F).@"fn";
    const R = info.return_type.?;
    const P = struct {
        fn t(comptime i: usize) type {
            return info.params[i].type.?;
        }
    };
    return switch (info.params.len) {
        0 => struct {
            fn f() callconv(.c) R {
                return unsupported(R, .{});
            }
        }.f,
        1 => struct {
            fn f(a: P.t(0)) callconv(.c) R {
                return unsupported(R, .{a});
            }
        }.f,
        2 => struct {
            fn f(a: P.t(0), b: P.t(1)) callconv(.c) R {
                return unsupported(R, .{ a, b });
            }
        }.f,
        3 => struct {
            fn f(a: P.t(0), b: P.t(1), c: P.t(2)) callconv(.c) R {
                return unsupported(R, .{ a, b, c });
            }
        }.f,
        4 => struct {
            fn f(a: P.t(0), b: P.t(1), c: P.t(2), d: P.t(3)) callconv(.c) R {
                return unsupported(R, .{ a, b, c, d });
            }
        }.f,
        5 => struct {
            fn f(a: P.t(0), b: P.t(1), c: P.t(2), d: P.t(3), e: P.t(4)) callconv(.c) R {
                return unsupported(R, .{ a, b, c, d, e });
            }
        }.f,
        6 => struct {
            fn f(a: P.t(0), b: P.t(1), c: P.t(2), d: P.t(3), e: P.t(4), g: P.t(5)) callconv(.c) R {
                return unsupported(R, .{ a, b, c, d, e, g });
            }
        }.f,
        7 => struct {
            fn f(
                a: P.t(0),
                b: P.t(1),
                c: P.t(2),
                d: P.t(3),
                e: P.t(4),
                g: P.t(5),
                h: P.t(6),
            ) callconv(.c) R {
                return unsupported(R, .{ a, b, c, d, e, g, h });
            }
        }.f,
        8 => struct {
            fn f(
                a: P.t(0),
                b: P.t(1),
                c: P.t(2),
                d: P.t(3),
                e: P.t(4),
                g: P.t(5),
                h: P.t(6),
                i: P.t(7),
            ) callconv(.c) R {
                return unsupported(R, .{ a, b, c, d, e, g, h, i });
            }
        }.f,
        9 => struct {
            fn f(
                a: P.t(0),
                b: P.t(1),
                c: P.t(2),
                d: P.t(3),
                e: P.t(4),
                g: P.t(5),
                h: P.t(6),
                i: P.t(7),
                j: P.t(8),
            ) callconv(.c) R {
                return unsupported(R, .{ a, b, c, d, e, g, h, i, j });
            }
        }.f,
        else => @compileError("stub: too many parameters"),
    };
}

/// Fallible functions fail with UNSUPPORTED through their `err`; the rest
/// return a zero value (accessors of things not built yet: nothing there).
fn unsupported(comptime R: type, args: anytype) R {
    if (R == api.Code) {
        const last = args[args.len - 1];
        if (@TypeOf(last) == ?*?*api.Error) {
            return rt.fail(last, .e_unsupported, "not implemented yet", .{});
        }
        return .e_unsupported;
    }
    if (R == void) return;
    if (@typeInfo(R) == .pointer and !@typeInfo(R).pointer.is_allowzero)
        @compileError("a function returning " ++ @typeName(R) ++ " needs an implementation");
    return std.mem.zeroes(R);
}

test {
    _ = rt;
    _ = @import("cache.zig");
    inline for (impls) |m| _ = m;
}

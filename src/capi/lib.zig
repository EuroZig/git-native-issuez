//! The C library: exports every function `api.zig` declares. Each one is
//! looked up in the implementation files below and must have exactly the
//! declared type.

const std = @import("std");
const api = @import("api.zig");
const rt = @import("rt.zig");

const impls = .{
    rt,
    @import("repo.zig"),
    @import("read.zig"),
    @import("write.zig"),
    @import("more.zig"),
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
    @compileError(func.name ++ " is declared in api.zig but not implemented");
}

test {
    _ = rt;
    _ = @import("cache.zig");
    inline for (impls) |m| _ = m;
}

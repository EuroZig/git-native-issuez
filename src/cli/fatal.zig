//! Process-ending errors, for entry points only. Commands return an exit
//! code instead so the simulator keeps running after a failure.

const std = @import("std");

/// A user-facing error: prints `error: <msg>` and exits with status 1.
pub fn msg(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Only takes OutOfMemory so other errors can't end up here by accident.
pub fn oom(_: error{OutOfMemory}) noreturn {
    msg("out of memory", .{});
}

/// A bug in this program, never a user error.
pub fn bug(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.panic("bug: " ++ fmt, args);
}

//! What every subcommand receives. Commands are generic over the backend,
//! like the library's `Repo(B)`, so the same code runs on real git and on
//! `GitSim`.

const std = @import("std");

pub fn Context(comptime B: type) type {
    return struct {
        io: std.Io,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        out: *std.Io.Writer,
        err: *std.Io.Writer,
        environ_map: *std.process.Environ.Map,
        /// Opened before dispatch. Only commands that need a repository
        /// report the error, so `version` and `help` work anywhere.
        backend: B.Error!*B,
    };
}

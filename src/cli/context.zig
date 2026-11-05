//! What every subcommand receives. Commands are generic over the backend,
//! like the library's `Repo(B)`, so the same code runs on real git and on
//! `GitSim`.

const std = @import("std");

pub const ReadFileError = error{ FileNotFound, FileTooLarge, ReadFailed, OutOfMemory };

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
        /// What `openRepo` read from git config. Null before.
        settings: ?@import("issuez").Settings = null,
        /// What relative dates (`+3d`, `fri`) count from. Null: the local
        /// date now, read when first needed.
        today: ?@import("issuez").format.fields.Date = null,

        const Self = @This();

        /// A date as typed (`2026-12-01`, `today`, `+3d`, `fri`, `eom`),
        /// as git stores it; empty stays empty. Null when it isn't one.
        pub fn date(ctx: *Self, text: []const u8) std.mem.Allocator.Error!?[]const u8 {
            const issuez = @import("issuez");
            const today = ctx.today orelse issuez.local_time.today(ctx.io, ctx.gpa, ctx.environ_map);
            ctx.today = today;
            const work_days: issuez.format.fields.WorkDays = if (ctx.settings) |s| s.work_days else .all;
            return issuez.format.dates.resolve(ctx.arena, text, today, work_days);
        }

        /// A file named on the command line. A backend with files of its
        /// own (the simulator's world) serves them instead of the disk.
        pub fn readFile(ctx: *Self, path: []const u8, limit: usize) ReadFileError![]const u8 {
            if (@hasDecl(B, "readFile")) {
                const sim = ctx.backend catch return error.ReadFailed;
                const data = sim.readFile(path) orelse return error.FileNotFound;
                if (data.len > limit) return error.FileTooLarge;
                return data;
            }
            const cwd = std.Io.Dir.cwd();
            return cwd.readFileAlloc(ctx.io, path, ctx.arena, .limited(limit + 1)) catch |e|
                switch (e) {
                    error.FileNotFound => error.FileNotFound,
                    error.StreamTooLong => error.FileTooLarge,
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.ReadFailed,
                };
        }
    };
}

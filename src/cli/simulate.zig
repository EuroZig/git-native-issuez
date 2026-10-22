//! One CLI command on a simulated world, as `git-issue-sim` and the fuzzer
//! run it. The tests below run the fixture worlds in `worlds/` through the
//! oracle.

const std = @import("std");
const Allocator = std.mem.Allocator;
const issuez = @import("issuez");
const context = @import("context.zig");
const dispatch = @import("dispatch.zig");

const GitSim = issuez.backend.GitSim;
const World = GitSim.World;

/// Runs `argv` (without the program name) on clone `clone_index` and writes
/// the changes back into `world`. Returns the exit code.
pub fn run(
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    environ_map: *std.process.Environ.Map,
    world: *World,
    clone_index: usize,
    argv: []const []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) Allocator.Error!u8 {
    var sim = try GitSim.init(arena, world, clone_index);
    var ctx: context.Context(GitSim) = .{
        .io = io,
        .gpa = gpa,
        .arena = arena,
        .out = out,
        .err = err,
        .environ_map = environ_map,
        .backend = &sim,
    };
    const code = dispatch.run(GitSim, &ctx, "git-issue", argv);
    try sim.commit();
    return code;
}

test "fixture worlds through the oracle" {
    const oracle = @import("oracle");
    const testing = std.testing;
    const fixtures = [_][:0]const u8{
        @embedFile("worlds/empty.zon"),
        @embedFile("worlds/two-clones.zon"),
    };
    const Case = struct {
        clone: ?[]const u8 = null,
        cmd: oracle.Command,
        exit: u8,
        /// Part of the output.
        output: []const u8 = "",
    };
    const cases = [_]Case{
        .{ .cmd = .{ .read = &.{"version"} }, .exit = 0, .output = "git-issue version " },
        .{ .cmd = .{ .read = &.{"help"} }, .exit = 1, .output = "usage: git issue <command>" },
        .{ .clone = "bob", .cmd = .{ .read = &.{ "ls", "--all" } }, .exit = 0 },
        .{
            .cmd = .{ .read = &.{"no-such-command"} },
            .exit = 1,
            .output = "'no-such-command' is not a git-issue command",
        },
        .{
            .cmd = .{ .create = .{
                .title = "Simulated issue",
                .labels = &.{"bug"},
                .priority = "high",
            } },
            .exit = 0,
            .output = "Created issue ",
        },
        .{
            .cmd = .{ .comment = .{ .id = "ffff", .paragraphs = &.{"hello"} } },
            .exit = 1,
            .output = "not found",
        },
        .{ .cmd = .{ .read = &.{"fsck"} }, .exit = 0 },
        .{
            .cmd = .{ .state = .{ .id = "a7f3", .state = "" } },
            .exit = 1,
            .output = "error: state is required (--open, --close, or --state <value>)",
        },
        .{
            .cmd = .{ .init = .{ .remotes = &.{ "origin", "upstream" } } },
            .exit = 1,
            .output = "error: only one remote can be given",
        },
    };

    var environ_map = try testing.environ.createMap(testing.allocator);
    defer environ_map.deinit();
    for (fixtures) |fixture| for (cases) |case| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var world = try World.parse(arena, fixture, null);
        const before = world;
        const clone_index = if (case.clone) |name| world.cloneIndex(name).? else 0;
        var output: std.Io.Writer.Allocating = .init(arena);
        const argv = try case.cmd.argv(arena);
        const code = try run(
            testing.io,
            testing.allocator,
            arena,
            &environ_map,
            &world,
            clone_index,
            argv,
            &output.writer,
            &output.writer,
        );
        const shown = try std.mem.join(arena, " ", argv);
        errdefer std.debug.print("case: {s}\n{s}\n", .{ shown, output.written() });
        try testing.expectEqual(case.exit, code);
        try testing.expect(std.mem.find(u8, output.written(), case.output) != null);

        var report: oracle.Report = .{ .arena = arena };
        try oracle.checkTransition(arena, before, world, case.clone, case.cmd, code, &report);
        for (report.violations.items) |v| std.debug.print("  oracle: {s}\n", .{v});
        try testing.expect(report.ok());
    };
}

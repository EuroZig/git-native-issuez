//! A test runner that runs one slice of a binary's tests: `--shard=<i>/<n>`
//! takes every n-th test, starting at i. Several runs of one binary then
//! share the machine, while `zig build` still reports every test.
//!
//! The rest is std's test runner (lib/compiler/test_runner.zig) without
//! fuzzing: its server mode, its leak check and its failure on logged errors.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Server = std.zig.Server;
const TestResults = Server.Message.TestResults;

pub const std_options: std.Options = .{ .logFn = log };

var log_err_count: usize = 0;
var fba_buffer: [8192]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);
var stdin_buffer: [4096]u8 = undefined;
var stdout_buffer: [4096]u8 = undefined;

const Shard = struct {
    index: usize,
    count: usize,

    fn parse(text: []const u8) ?Shard {
        const slash = std.mem.findScalar(u8, text, '/') orelse return null;
        const index = std.fmt.parseUnsigned(usize, text[0..slash], 10) catch return null;
        const count = std.fmt.parseUnsigned(usize, text[slash + 1 ..], 10) catch return null;
        if (count == 0 or index >= count) return null;
        return .{ .index = index, .count = count };
    }

    /// The position in `builtin.test_functions` of the shard's `n`-th test.
    fn testIndex(shard: Shard, n: usize) usize {
        return shard.index + n * shard.count;
    }

    /// How many tests of `total` are the shard's.
    fn len(shard: Shard, total: usize) usize {
        return (total + shard.count - 1 - shard.index) / shard.count;
    }
};

pub fn main(init: std.process.Init.Minimal) void {
    const args = init.args.toSlice(fba.allocator()) catch |err|
        std.debug.panic("unable to parse command line args: {t}", .{err});

    var listen = false;
    var shard: Shard = .{ .index = 0, .count = 1 };
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) {
            listen = true;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else if (std.mem.startsWith(u8, arg, "--shard=")) {
            shard = Shard.parse(arg["--shard=".len..]) orelse
                @panic("unable to parse --shard command line argument");
        } else if (!std.mem.startsWith(u8, arg, "--cache-dir")) {
            std.debug.panic("unrecognized command line argument: {s}", .{arg});
        }
    }
    if (!listen) @panic("run these tests with zig build");
    serve(init, shard) catch |err| std.debug.panic("test runner failure: {t}", .{err});
}

fn serve(init: std.process.Init.Minimal, shard: Shard) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var stdin_reader: std.Io.File.Reader = .initStreaming(.stdin(), io, &stdin_buffer);
    var stdout_writer: std.Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    var server: Server = .{ .in = &stdin_reader.interface, .out = &stdout_writer.interface };
    try server.serveStringMessage(.zig_version, builtin.zig_version_string);
    while (true) {
        const header = try server.receiveMessage();
        switch (header.tag) {
            .exit => return std.process.exit(0),
            .query_test_metadata => try serveMetadata(&server, shard),
            .run_test => try runTest(&server, init, shard),
            else => std.debug.panic("unexpected message: {t}", .{header.tag}),
        }
    }
}

fn serveMetadata(server: *Server, shard: Shard) !void {
    var sa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer if (sa.deinit() != 0) @panic("test runner memory leak");
    const gpa = sa.allocator();

    var string_bytes: std.ArrayList(u8) = .empty;
    defer string_bytes.deinit(gpa);
    try string_bytes.append(gpa, 0); // 0 is null.

    const len = shard.len(builtin.test_functions.len);
    const names = try gpa.alloc(u32, len);
    defer gpa.free(names);
    const expected_panic_msgs = try gpa.alloc(u32, len);
    defer gpa.free(expected_panic_msgs);
    for (names, expected_panic_msgs, 0..) |*name, *expected_panic_msg, n| {
        name.* = @intCast(string_bytes.items.len);
        try string_bytes.appendSlice(gpa, builtin.test_functions[shard.testIndex(n)].name);
        try string_bytes.append(gpa, 0);
        expected_panic_msg.* = 0;
    }
    try server.serveTestMetadata(.{
        .names = names,
        .expected_panic_msgs = expected_panic_msgs,
        .string_bytes = string_bytes.items,
    });
}

fn runTest(server: *Server, init: std.process.Init.Minimal, shard: Shard) !void {
    testing.environ = init.environ;
    testing.allocator_instance = .init(std.heap.page_allocator, .{
        .canary = 0xc3a701ba,
        .check_write_after_free = true,
    });
    testing.io_instance = .init(testing.allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    log_err_count = 0;
    const n = try server.receiveBody_u32();
    const test_fn = builtin.test_functions[shard.testIndex(n)];
    // The build runner's timeouts count from here.
    try server.serveStringMessage(.test_started, &.{});

    const status: TestResults.Status = if (test_fn.func()) |_| .pass else |err| switch (err) {
        error.SkipZigTest => .skip,
        else => s: {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            break :s .fail;
        },
    };
    testing.io_instance.deinit();
    const leak_count = testing.allocator_instance.deinit();
    try server.serveTestResults(.{
        .index = n,
        .flags = .{
            .status = status,
            .fuzz = false,
            .log_err_count = std.math.lossyCast(
                @FieldType(TestResults.Flags, "log_err_count"),
                log_err_count,
            ),
            .leak_count = std.math.lossyCast(
                @FieldType(TestResults.Flags, "leak_count"),
                leak_count,
            ),
        },
    });
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@backingInt(level) <= @backingInt(std.log.Level.err)) log_err_count +|= 1;
    if (@backingInt(level) <= @backingInt(testing.log_level)) std.debug.print(
        "[" ++ @tagName(scope) ++ "] (" ++ @tagName(level) ++ "): " ++ format ++ "\n",
        args,
    );
}

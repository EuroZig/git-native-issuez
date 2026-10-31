//! `git-issue-fuzz`: seeded fuzzing on `GitSim`.
//!
//! Each case first drives random backend operations against a separate
//! model, then runs random commands on a few clones sharing a hub remote.
//! Every command is checked by the oracle and the engine's reading of each
//! issue is compared with the oracle's. Now and then another tool writes
//! extension fields (invalid ones too), or someone force-pushes to the
//! hub, so clones quarantine and resolve. Finally all clones sync,
//! accepting the hub's version of anything quarantined, until they hold
//! exactly the hub's refs. A failing case prints its seed:
//!
//!     git-issue-fuzz --seed <seed> --iterations 1

const std = @import("std");
const Allocator = std.mem.Allocator;
const issuez = @import("issuez");
const oracle = @import("oracle");
const fatal = @import("fatal.zig");
const simulate = @import("simulate.zig");

const object = issuez.backend.object;
const contract = issuez.backend.contract;
const GitSim = issuez.backend.GitSim;
const World = GitSim.World;
const Oid = object.Oid;
const Command = oracle.Command;
const spec = oracle.command;

const help =
    \\usage: git-issue-fuzz [--seed N] [--iterations N]
    \\
    \\Runs seeded fuzz cases against the simulator. Defaults: random seed,
    \\1000 iterations. Prints the seed of the first failing case and exits 1.
    \\
;

const max_clones = 3;
const max_ops = 64;
const ref_pool = [_][]const u8{
    "refs/issues/0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c",
    "refs/issues/1c7d5e74-7a6b-4b4f-8d3c-2e3f4a5b6c7d",
    "refs/issues/2d8e6f85-8b7c-4c5a-9e4d-3f4a5b6c7d8e",
    "refs/milestones/3e9f7a96-9c8d-4d6b-8f5e-4a5b6c7d8e9f",
};

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch |err| switch (err) {
        error.OutOfMemory => |e| fatal.oom(e),
        else => fatal.msg("unable to read command line arguments", .{}),
    };

    var seed: ?u64 = null;
    var iterations: u64 = 1000;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{help});
            return 0;
        } else if (std.mem.eql(u8, arg, "--seed") and i + 1 < args.len) {
            i += 1;
            seed = std.fmt.parseInt(u64, args[i], 10) catch fatal.msg(
                "invalid --seed '{s}'",
                .{args[i]},
            );
        } else if (std.mem.eql(u8, arg, "--iterations") and i + 1 < args.len) {
            i += 1;
            iterations = std.fmt.parseInt(u64, args[i], 10) catch fatal.msg(
                "invalid --iterations '{s}'",
                .{args[i]},
            );
        } else {
            fatal.msg("unknown argument '{s}'\n\n{s}", .{ arg, help });
        }
    }
    const base_seed = seed orelse blk: {
        var b: [8]u8 = undefined;
        io.random(&b);
        break :blk std.mem.readInt(u64, &b, .little);
    };
    std.debug.print("git-issue-fuzz: base seed {d}, {d} iterations\n", .{ base_seed, iterations });
    stats_gpa = init.gpa;

    var case: u64 = 0;
    while (case < iterations) : (case += 1) {
        const case_seed = base_seed +% case;
        var case_arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer case_arena.deinit();
        runCase(io, init.gpa, case_arena.allocator(), init.environ_map, case_seed) catch |err| {
            std.debug.print(
                "FAIL: case seed {d} ({t})\n" ++
                    "replay: git-issue-fuzz --seed {d} --iterations 1\n",
                .{ case_seed, err, case_seed },
            );
            stats.deinit(init.gpa);
            skips.deinit(init.gpa);
            return 1;
        };
    }
    for (stats.keys(), stats.values()) |cmd, v| {
        std.debug.print("  {s:<10} {d:>7} ok {d:>7} rejected\n", .{ cmd, v[0], v[1] });
    }
    for (skips.keys(), skips.values()) |reason, n| {
        std.debug.print("  oracle skipped {d:>5}x: {s}\n", .{ n, reason });
    }
    skips.deinit(init.gpa);
    std.debug.print("git-issue-fuzz: {d} cases passed\n", .{iterations});
    stats.deinit(init.gpa);
    return 0;
}

const CaseError = error{
    OutOfMemory,
    NotConverged,
    ModelMismatch,
    RoundTripMismatch,
    OracleRejected,
    OracleNoRule,
    WriteFailed,
};

fn runCase(
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    environ_map: *std.process.Environ.Map,
    seed: u64,
) CaseError!void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();

    const clone_count = rand.intRangeAtMost(usize, 1, max_clones);
    const clones = try arena.alloc(World.Clone, clone_count);
    for (
        clones,
        0..,
    ) |*c, idx| c.* = .{ .name = try std.fmt.allocPrint(arena, "clone{d}", .{idx}) };
    var world: World = .{
        .format = if (rand.boolean()) .sha1 else .sha256,
        .seed = rand.int(u64),
        .clock = .{
            .now = rand.intRangeAtMost(i64, 0, 4_000_000_000),
            .tz_offset_minutes = rand.intRangeAtMost(i16, -720, 840),
        },
        .clones = clones,
    };

    for (0..clone_count) |clone_index| {
        const before = world;
        var sim = try GitSim.init(arena, &world, clone_index);
        try driveBackend(arena, rand, &sim);
        try sim.commit();
        var report: oracle.Report = .{ .arena = arena };
        try oracle.checkInvariants(arena, before, world, &report);
        if (!report.ok()) return reject(report);
    }

    try checkRoundTrip(arena, world);

    try fuzzCommands(io, gpa, arena, environ_map, rand);
}

/// Printed at the end, to see that success paths get exercised and not just
/// rejections.
var stats: std.array_hash_map.String([2]u64) = .empty;
var stats_gpa: ?Allocator = null;

fn countOutcome(cmd: []const u8, ok: bool) void {
    const gpa = stats_gpa orelse return;
    const gop = stats.getOrPut(gpa, cmd) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .{ 0, 0 };
    gop.value_ptr[if (ok) 0 else 1] += 1;
}

/// Checks the oracle had no rule for, by reason. A growing count points at
/// a gap in its coverage.
var skips: std.array_hash_map.String(u64) = .empty;

fn countSkip(reason: []const u8) void {
    const gpa = stats_gpa orelse return;
    const gop = skips.getOrPut(gpa, reason) catch return;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
}

const words = [_][]const u8{
    "Crash",
    "on",
    "login",
    "fails",
    "Firefox",
    "\xc3\xbcber",
    "edge\xe2\x9c\x93",
    "--",
    "-x",
};
const label_pool = [_][]const u8{
    "bug",
    "auth",
    "ui",
    "Bug",
    "needs triage",
    " spaced ",
    "a,b",
    "",
};
const email_pool = [_][]const u8{ "a@e.x", "bob@example.com", "", "noat", "a@b", "@x.y" };
const priority_pool = [_][]const u8{ "low", "medium", "high", "critical", "urgent" };
const milestone_pool = [_][]const u8{ "v1", "v2", "Later", "2026 Q4", "" };
const milestone_key_pool = [_][]const u8{ "v1", "v2", "Later", "zzzz" };
const milestone_mode_pool = [_][]const u8{ "inherit", "none", "explicit", "auto" };
const message_pool = [_][]const u8{
    "Repro steps",                    "line one\nline two",  "para one\n\npara two",
    "Looks good.\n\nX-Deleted: true", "State: closed",       "Fixes: 12\nmore",
    "",                               "  trailing spaces  ",
};
/// `open` and `closed` are written as `--open` and `--close`.
const state_pool = [_][]const u8{ "open", "closed", "wontfix", "bad state", "in-review" };

fn pick(rand: std.Random, pool: []const []const u8) []const u8 {
    return pool[rand.uintLessThan(usize, pool.len)];
}

/// `must_succeed` is set for input the CLI has to accept.
const Generated = struct { cmd: Command, must_succeed: bool = false };

fn genPrefix(
    arena: Allocator,
    rand: std.Random,
    ids: []const []const u8,
) Allocator.Error![]const u8 {
    if (ids.len == 0 or rand.uintLessThan(u8, 8) == 0) return pick(rand, &.{ "ffff", "0", "zz" });
    const id = ids[rand.uintLessThan(usize, ids.len)];
    return arena.dupe(u8, id[0..rand.intRangeAtMost(usize, 4, id.len)]);
}

/// Up to `max` picks, each by `gen`.
fn some(
    arena: Allocator,
    rand: std.Random,
    max: usize,
    comptime gen: anytype,
    gen_args: anytype,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (0..rand.uintAtMost(usize, max)) |_| try out.append(arena, try @call(.auto, gen, gen_args));
    return out.items;
}

fn pickAlloc(rand: std.Random, pool: []const []const u8) Allocator.Error![]const u8 {
    return pick(rand, pool);
}

const date_pool = [_][]const u8{ "2026-11-01", "2026-12-31", "2028-02-29", "2026-02-30", "26-1-1" };
const estimate_pool = [_][]const u8{ "90", "0", "2h", "1h30m", "45m", "007", "2x", "" };
const workflow_pool = [_][]const u8{ "backlog", "ready", "review", "doing", "done", "In-Progress" };
const clear_pool = [_][]const u8{
    "parent",   "blockers", "start",    "due",       "estimate",
    "workflow", "assignee", "priority", "milestone", "labels",
};

/// Returns true when it set anything, since a create with planning fields
/// can't be predicted to succeed.
fn genExt(
    arena: Allocator,
    rand: std.Random,
    ids: []const []const u8,
    ext: *spec.Ext,
    edit: bool,
) Allocator.Error!bool {
    if (rand.uintLessThan(u8, 4) == 0) ext.parent = try genPrefix(arena, rand, ids);
    const blockers = if (rand.uintLessThan(u8, 3) == 0) @as(usize, 2) else 0;
    ext.blocked_by = try some(arena, rand, blockers, genPrefix, .{ arena, rand, ids });
    if (edit and rand.uintLessThan(u8, 5) == 0) {
        ext.unblock = try arena.dupe([]const u8, &.{try genPrefix(arena, rand, ids)});
    }
    const single = [_]struct { *?[]const u8, []const []const u8 }{
        .{ &ext.start, &date_pool },
        .{ &ext.due, &date_pool },
        .{ &ext.estimate, &estimate_pool },
        .{ &ext.workflow, &workflow_pool },
        .{ &ext.milestone_id, &milestone_key_pool },
        .{ &ext.milestone_mode, &milestone_mode_pool },
    };
    for (single) |x| if (rand.uintLessThan(u8, 5) == 0) {
        x[0].* = pick(rand, x[1]);
    };
    if (edit) {
        const clears = if (rand.uintLessThan(u8, 4) == 0) @as(usize, 2) else 0;
        ext.clear = try some(arena, rand, clears, pickAlloc, .{ rand, &clear_pool });
    }
    return !ext.isEmpty();
}

/// Milestone guards need long sequences (link, close, complete, reopen,
/// move, restore) that random commands rarely produce.
fn generateMilestoneWork(
    arena: Allocator,
    rand: std.Random,
    ids: []const []const u8,
    /// Used to keep duplicate names rare.
    milestones: usize,
) Allocator.Error!Generated {
    const id = try genPrefix(arena, rand, ids);
    const name = if (rand.uintLessThan(u8, 4) == 0) "v2" else "v1";
    var kind = rand.uintLessThan(u8, 8);
    if (milestones == 0 and rand.boolean()) kind = 0;
    if (kind == 0 and milestones > 0 and rand.uintLessThan(u8, 8) != 0) kind = 1;
    const cmd: Command = switch (kind) {
        0 => .{ .milestone = .{ .sub = .create, .name = name } },
        1 => .{ .milestone = .{
            .sub = switch (rand.uintLessThan(u8, 4)) {
                0, 1 => .complete,
                2 => .reopen,
                else => .retire,
            },
            .name = name,
        } },
        2 => .{ .create = .{
            .title = "Work",
            .milestone = name,
            .ext = .{ .parent = if (rand.boolean()) id else null },
        } },
        3 => .{ .create = .{ .title = "Sub", .ext = .{ .parent = id } } },
        4 => blk: {
            var x: spec.Edit = .{ .id = id };
            switch (rand.uintLessThan(u8, 5)) {
                0 => x.milestone = name,
                1 => x.ext.milestone_id = name,
                2 => x.ext.milestone_mode = pick(rand, &.{ "inherit", "none", "explicit" }),
                3 => x.ext.parent = try genPrefix(arena, rand, ids),
                else => x.ext.clear = try arena.dupe([]const u8, &.{
                    pick(rand, &.{ "milestone", "parent" }),
                }),
            }
            break :blk .{ .edit = x };
        },
        5, 6 => if (rand.boolean()) .{ .close = .{ .id = id } } else .{ .reopen = .{ .id = id } },
        else => if (rand.boolean()) .{ .delete = .{ .id = id } } else .{ .restore = .{ .id = id } },
    };
    return .{ .cmd = cmd };
}

fn generateLifecycle(
    arena: Allocator,
    rand: std.Random,
    ids: []const []const u8,
    commits: []const []const u8,
) Allocator.Error!Generated {
    const id = try genPrefix(arena, rand, ids);
    const cmd: Command = switch (rand.uintLessThan(u8, 5)) {
        4 => blk: { // milestones
            const names = [_][]const u8{ "v1", "v2", "Later", "v1" };
            const name = pick(rand, &names);
            break :blk switch (rand.uintLessThan(u8, 8)) {
                0, 1 => .{ .milestone = .{
                    .sub = .create,
                    .name = name,
                    .due = if (rand.boolean()) pick(rand, &date_pool) else null,
                } },
                2 => .{ .read = if (rand.boolean())
                    try arena.dupe([]const u8, &.{ "milestone", "ls", name, "--all" })
                else
                    try arena.dupe([]const u8, &.{ "milestone", "ls", name }) },
                3 => .{ .read = try arena.dupe([]const u8, &.{ "milestone", "show", name }) },
                4 => .{ .milestone = .{
                    .sub = .edit,
                    .name = name,
                    .new_name = pick(rand, &names),
                } },
                5 => .{ .milestone = .{ .sub = .complete, .name = name } },
                6 => .{ .milestone = .{ .sub = .reopen, .name = name } },
                else => .{ .milestone = .{ .sub = .retire, .name = name } },
            };
        },
        0 => if (rand.boolean()) .{ .delete = .{ .id = id } } else .{ .restore = .{ .id = id } },
        1 => blk: {
            const x: spec.Lifecycle = .{
                .id = id,
                .message = if (rand.boolean()) "Done" else null,
            };
            break :blk if (rand.boolean()) .{ .close = x } else .{ .reopen = x };
        },
        2 => blk: {
            const target = if (commits.len > 0 and rand.uintLessThan(u8, 4) != 0) inner: {
                const hex = commits[rand.uintLessThan(usize, commits.len)];
                break :inner hex[0..rand.intRangeAtMost(usize, 4, 10)];
            } else pick(rand, &.{ "abcd", "00", "ffffffff" });
            const kind: @FieldType(spec.CommentEvent, "kind") = switch (rand.uintLessThan(u8, 3)) {
                0 => .edit,
                1 => .delete,
                else => .restore,
            };
            break :blk .{ .comment_event = .{
                .id = id,
                .kind = kind,
                .target = target,
                .text = if (kind == .edit) pick(rand, &message_pool) else null,
            } };
        },
        else => .{ .edit = .{
            .id = id,
            .priority = if (rand.boolean()) "high" else null,
            .description = try arena.dupe([]const u8, &.{pick(rand, &message_pool)}),
        } },
    };
    return .{ .cmd = cmd };
}

fn generate(arena: Allocator, rand: std.Random, ids: []const []const u8) Allocator.Error!Generated {
    switch (rand.uintLessThan(u8, 15)) {
        0...2 => { // create
            var valid = true;
            var title: std.ArrayList([]const u8) = .empty;
            const n = rand.intRangeAtMost(usize, 0, 3);
            if (n == 0) valid = false;
            for (0..n) |_| {
                const w = pick(rand, &words);
                if (w[0] == '-') valid = false;
                try title.append(arena, w);
            }
            // One argument, so a word like `-x` reaches the CLI as part of
            // the title, or alone when it is the only word.
            var x: spec.Create = .{ .title = try std.mem.join(arena, " ", title.items) };
            if (rand.boolean()) {
                const l = pick(rand, &label_pool);
                if (std.mem.findScalar(u8, l, ',') != null) valid = false;
                x.labels = try arena.dupe([]const u8, &.{l});
            }
            if (rand.uintLessThan(u8, 3) == 0) {
                const e = pick(rand, &email_pool);
                if (!(e.len == 0 or std.mem.eql(u8, e, "a@e.x") or std.mem.eql(
                    u8,
                    e,
                    "bob@example.com",
                ))) valid = false;
                x.assignee = e;
            }
            if (rand.uintLessThan(u8, 3) == 0) {
                const p = pick(rand, &priority_pool);
                if (std.mem.eql(u8, p, "urgent")) valid = false;
                x.priority = p;
            }
            if (rand.uintLessThan(u8, 4) == 0) {
                const m = pick(rand, &milestone_pool);
                // A catalog name may be completed, retired or ambiguous.
                for (milestone_key_pool) |k| if (std.mem.eql(u8, k, m)) {
                    valid = false;
                };
                x.milestone = m;
            }
            const bodies = [_][]const u8{ "First paragraph.", "Two\nlines", "Fixes: 12" };
            if (rand.boolean()) x.body = pick(rand, &bodies);
            if (try genExt(arena, rand, ids, &x.ext, false)) valid = false;
            return .{ .cmd = .{ .create = x }, .must_succeed = valid };
        },
        3...4 => return .{ .cmd = .{ .comment = .{
            .id = try genPrefix(arena, rand, ids),
            .paragraphs = try some(arena, rand, 2, pickAlloc, .{ rand, &message_pool }),
        } } },
        5...6 => { // state
            const st = pick(rand, &state_pool);
            var x: spec.State = .{ .id = try genPrefix(arena, rand, ids), .state = st };
            if (std.mem.eql(u8, st, "open") or std.mem.eql(u8, st, "closed")) x.as_flag = true;
            const messages = [_][]const u8{ "Fixed in abc", "Duplicate", "Two\nlines" };
            if (rand.boolean()) x.message = pick(rand, &messages);
            if (rand.uintLessThan(u8, 3) == 0) x.fixed_by = "abc1234";
            if (rand.uintLessThan(u8, 3) == 0) x.reason = "completed";
            return .{ .cmd = .{ .state = x } };
        },
        7...8 => { // edit
            var x: spec.Edit = .{ .id = try genPrefix(arena, rand, ids) };
            const titles = [_][]const u8{ "New title", "Renamed \xe2\x9c\x93" };
            if (rand.uintLessThan(u8, 3) == 0) x.title = pick(rand, &titles);
            const set = try some(arena, rand, 2, pickAlloc, .{ rand, &label_pool });
            if (set.len > 0) x.set_labels = set;
            x.add = try some(arena, rand, 2, pickAlloc, .{ rand, &label_pool });
            x.remove = try some(arena, rand, 2, pickAlloc, .{ rand, &label_pool });
            if (rand.uintLessThan(u8, 3) == 0) x.assignee = pick(rand, &email_pool);
            if (rand.uintLessThan(u8, 3) == 0) x.priority = pick(rand, &priority_pool);
            if (rand.uintLessThan(u8, 4) == 0) x.milestone = pick(rand, &milestone_pool);
            _ = try genExt(arena, rand, ids, &x.ext, true);
            return .{ .cmd = .{ .edit = x } };
        },
        9 => return .{ .cmd = .{ .read = try arena.dupe([]const u8, &.{
            "ls",
            pick(rand, &.{ "--all", "-f", "-s" }),
            pick(rand, &.{ "full", "closed", "open", "oneline" }),
        }) } },
        10 => return .{ .cmd = .{ .read = if (rand.uintLessThan(u8, 3) == 0)
            try arena.dupe([]const u8, &.{ "fsck", pick(rand, &.{ "--quiet", "--" }) })
        else
            try arena.dupe([]const u8, &.{
                pick(rand, &.{ "show", "search" }),
                try genPrefix(arena, rand, ids),
            }) } },
        11 => {
            if (rand.uintLessThan(u8, 3) == 0) return .{ .cmd = .{ .quarantine = .{
                .remote = pick(rand, &.{ "origin", "nosuch" }),
                .accept = rand.boolean(),
                .id = try genPrefix(arena, rand, ids),
            } } };
            // Without a remote, merge and sync must refuse and change nothing.
            const verbs = [_][]const u8{
                "init", "version", "frobnicate", "merge", "sync", "status",
            };
            const verb = pick(rand, &verbs);
            if (std.mem.eql(u8, verb, "init")) return .{ .cmd = .{ .init = .{} } };
            return .{ .cmd = .{ .read = try arena.dupe([]const u8, &.{verb}) } };
        },
        else => {
            const remotes = [_][]const u8{ "origin", "origin", "origin", "nosuch" };
            const x: spec.Sync = .{ .remote = pick(rand, &remotes) };
            return .{ .cmd = switch (rand.uintLessThan(u8, 3)) {
                0 => blk: {
                    var merge = x;
                    if (rand.uintLessThan(u8, 4) == 0) {
                        if (rand.boolean()) merge.check = true else merge.no_fetch = true;
                    }
                    break :blk .{ .merge = merge };
                },
                1 => .{ .push = x },
                else => .{ .sync = x },
            } };
        },
    }
}

fn fuzzCommands(
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    environ_map: *std.process.Environ.Map,
    rand: std.Random,
) CaseError!void {
    // Work clones c0..cN share "hub" as origin.
    const work_count = rand.intRangeAtMost(usize, 1, 3);
    const clones = try arena.alloc(World.Clone, work_count + 1);
    const custom_workflow = rand.boolean();
    // `in-review` done, `wontfix` and `duplicate` open work.
    const custom_done = rand.uintLessThan(u8, 3) == 0;
    for (clones[0..work_count], 0..) |*c, idx| {
        var config: std.ArrayList(World.ConfigEntry) = .empty;
        try config.append(arena, .{ .key = "remote.origin.url", .value = "sim:hub" });
        if (custom_workflow) try config.append(
            arena,
            .{ .key = "issue.workflowStates", .value = "backlog, doing, done" },
        );
        if (custom_done) try config.append(arena, .{ .key = "issue.doneStates", .value = "in-review" });
        c.* = .{
            .name = try std.fmt.allocPrint(arena, "c{d}", .{idx}),
            .config = config.items,
        };
    }
    clones[work_count] = .{ .name = "hub" };
    var world: World = .{
        .format = if (rand.boolean()) .sha1 else .sha256,
        .seed = rand.int(u64),
        .clock = .{
            .now = 1_700_000_000,
            .tz_offset_minutes = rand.intRangeAtMost(i16, -720, 840),
        },
        .clones = clones,
    };

    const milestone_focus = rand.uintLessThan(u8, 3) == 0;
    for (0..rand.intRangeAtMost(usize, 5, 40)) |_| {
        const clone_index = rand.uintLessThan(usize, work_count);
        // So most generated prefixes resolve.
        var ids: std.ArrayList([]const u8) = .empty;
        for (world.clones[clone_index].refs) |r| {
            if (std.mem.startsWith(u8, r.name, "refs/issues/")) try ids.append(
                arena,
                r.name["refs/issues/".len..],
            );
        }
        if (rand.uintLessThan(u8, 5) == 0) {
            // Someone using upstream on this clone.
            try upstreamStep(arena, &world, clone_index);
            continue;
        }
        if (ids.items.len > 0 and rand.uintLessThan(u8, 10) == 0) {
            // Another tool writes extension fields, valid or not.
            try foreignStep(arena, rand, &world, clone_index, ids.items);
            continue;
        }
        if (rand.uintLessThan(u8, 10) == 0) {
            // Someone force-pushes to the hub.
            try rewriteHub(arena, rand, &world, work_count);
            continue;
        }
        const quarantined = try quarantinedIds(arena, world.clones[clone_index]);
        if (quarantined.len > 0 and rand.boolean()) {
            const id = pick(rand, quarantined);
            const cmd: Command = .{ .quarantine = .{
                .remote = "origin",
                .accept = rand.boolean(),
                .id = if (rand.boolean()) id else id[0..8],
            } };
            _ = try step(io, gpa, arena, environ_map, &world, clone_index, cmd, true);
            continue;
        }
        var milestone_count: usize = 0;
        for (world.clones[clone_index].refs) |r| {
            if (std.mem.startsWith(u8, r.name, "refs/milestones/")) milestone_count += 1;
        }
        // So comment events sometimes target a real comment.
        var commits: std.ArrayList([]const u8) = .empty;
        for (world.clones[clone_index].objects) |o| if (o.kind == .commit) {
            const oid = object.hashObject(world.format, .commit, o.data);
            try commits.append(arena, try arena.dupe(u8, oid.hex().slice()));
        };
        const gen = if (milestone_focus and rand.uintLessThan(u8, 2) == 0)
            try generateMilestoneWork(arena, rand, ids.items, milestone_count)
        else if (rand.uintLessThan(u8, 6) == 0)
            try generateLifecycle(arena, rand, ids.items, commits.items)
        else
            try generate(arena, rand, ids.items);
        _ = try step(io, gpa, arena, environ_map, &world, clone_index, gen.cmd, gen.must_succeed);
    }

    // Everyone syncs and takes the hub's version of whatever got
    // quarantined, until nothing changes. Then every clone must match the
    // hub.
    var round: usize = 0;
    while (round < 8) : (round += 1) {
        const snapshot = try issueRefsDigest(arena, world);
        var resolved = false;
        for (0..work_count) |i| {
            const code = try step(
                io,
                gpa,
                arena,
                environ_map,
                &world,
                i,
                .{ .sync = .{ .remote = "origin" } },
                true,
            );
            _ = code;
            for (try quarantinedIds(arena, world.clones[i])) |id| {
                const cmd: Command = .{ .quarantine = .{
                    .remote = "origin",
                    .accept = true,
                    .id = id,
                } };
                _ = try step(io, gpa, arena, environ_map, &world, i, cmd, true);
                resolved = true;
            }
        }
        if (!resolved and std.mem.eql(u8, snapshot, try issueRefsDigest(arena, world))) break;
    } else {
        std.debug.print("  sync did not settle after {d} rounds\n", .{round});
        return error.NotConverged;
    }
    const hub = world.clones[work_count];
    for (hub.objects) |o| {
        if (o.kind != .commit) continue;
        const c = object.Commit.parse(arena, world.format, o.data) catch continue;
        if (c.parents.len == 2 and std.mem.eql(u8, c.author.name, "git-issue")) countOutcome(
            "(merge commits)",
            true,
        );
    }
    for (world.clones[0..work_count]) |c| {
        if (!sameIssueRefs(hub, c)) {
            std.debug.print("  clone {s} differs from hub after full sync\n", .{c.name});
            return error.NotConverged;
        }
    }
    try checkRoundTrip(arena, world);
}

/// What an upstream user does: `git issue merge origin` (modelled by
/// oracle.upstream), then `git push origin 'refs/issues/*:refs/issues/*'`.
/// The engine must read the result like the oracle does, and sync must
/// still converge afterwards.
fn upstreamStep(arena: Allocator, world: *World, clone_index: usize) CaseError!void {
    const before = world.*;
    var sim = try GitSim.init(arena, world, clone_index);
    const staging = "refs/remotes/origin/issues/";
    sim.fetch(arena, "origin", &.{"+refs/issues/*:" ++ staging ++ "*"}) catch {
        countOutcome("(upstream merge)", false);
        return;
    };
    var merged = false;
    for (try sim.listRefs(arena, staging)) |s| {
        const id = s.name[staging.len..];
        const local_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{id});
        const local = try sim.resolveRef(local_name);
        if (local == null) {
            sim.updateRefs(&.{.{ .name = local_name, .op = .{ .create = s.oid } }}) catch {};
        } else if (local.?.eql(s.oid) or try sim.isAncestor(s.oid, local.?)) {
            // up to date, or the remote is behind
        } else if (try sim.isAncestor(local.?, s.oid)) {
            sim.updateRefs(&.{.{
                .name = local_name,
                .op = .{ .update = .{ .new = s.oid, .old = local.? } },
            }}) catch {};
        } else {
            const model = oracle.upstream.mergeMessage(arena, &sim, local.?, s.oid, "origin");
            const message = model catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => continue, // criss-cross or unrelated: not modelled
            };
            const who = sim.identity(arena) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.IdentityUnknown => continue,
            };
            const commit: object.Commit = .{
                .tree = object.emptyTree(world.format),
                .parents = &.{ local.?, s.oid },
                .author = who.author,
                .committer = who.committer,
                .message = message,
            };
            const oid = try sim.writeObject(.commit, try commit.serializeAlloc(arena));
            sim.updateRefs(&.{.{
                .name = local_name,
                .op = .{ .update = .{ .new = oid, .old = local.? } },
            }}) catch continue;
            merged = true;
        }
        sim.updateRefs(&.{.{ .name = s.name, .op = .{ .delete = s.oid } }}) catch {};
    }
    var specs: std.ArrayList([]const u8) = .empty;
    for (try sim.listRefs(arena, "refs/issues/")) |r| {
        try specs.append(arena, try std.fmt.allocPrint(arena, "{s}:{s}", .{ r.name, r.name }));
    }
    if (specs.items.len > 0) _ = sim.push(arena, "origin", specs.items, false) catch {};
    try sim.commit();
    countOutcome("(upstream merge commit)", merged);

    var report: oracle.Report = .{ .arena = arena };
    try oracle.checkInvariants(arena, before, world.*, &report);
    if (!report.ok()) {
        std.debug.print("  upstream-style merge on {s}\n", .{world.clones[clone_index].name});
        return reject(report);
    }
    try crossCheckModel(arena, world, clone_index);
}

/// Values another tool may write, `""` (a clear) and invalid ones included.
const foreign_pools = [_]struct { []const u8, []const []const u8 }{
    .{ "X-Parent", &.{ "", "not-a-uuid", "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c" } },
    .{ "X-Blocked-By", &.{ "", "nope", "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c, x" } },
    .{ "X-Start-Date", &date_pool },
    .{ "X-Due-Date", &(date_pool ++ [_][]const u8{""}) },
    .{ "X-Estimate-Minutes", &estimate_pool },
    .{ "X-Workflow-State", &(workflow_pool ++ [_][]const u8{""}) },
    .{ "X-Milestone-Mode", &milestone_mode_pool },
    .{ "X-Deleted", &.{ "true", "false", "maybe", "" } },
};

/// A commit on top of one issue with extension trailers, as a tool that
/// doesn't check them would write. Merges must restate such values as they
/// are, and readers must take them without failing.
fn foreignStep(
    arena: Allocator,
    rand: std.Random,
    world: *World,
    clone_index: usize,
    ids: []const []const u8,
) CaseError!void {
    const before = world.*;
    var sim = try GitSim.init(arena, world, clone_index);
    const name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{pick(rand, ids)});
    const tip = (try sim.resolveRef(name)) orelse return;
    var list: std.ArrayList(issuez.format.trailers.Trailer) = .empty;
    for (foreign_pools) |f| if (rand.uintLessThan(u8, 3) == 0) {
        var value = pick(rand, f[1]);
        // A reference to an issue of this clone.
        if (rand.uintLessThan(u8, 3) == 0 and (std.mem.eql(u8, f[0], "X-Parent") or
            std.mem.eql(u8, f[0], "X-Blocked-By"))) value = pick(rand, ids);
        try list.append(arena, .{ .key = f[0], .value = value });
    };
    if (list.items.len == 0) try list.append(arena, .{ .key = "X-Deleted", .value = "false" });
    const message = issuez.format.trailers.build(arena, "Edit fields", "", list.items) catch |err|
        switch (err) {
            error.OutOfMemory => |e| return e,
            else => unreachable, // no body, and every value is one line
        };
    const who = sim.identity(arena) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.IdentityUnknown => return,
    };
    const commit: object.Commit = .{
        .tree = object.emptyTree(world.format),
        .parents = &.{tip},
        .author = who.author,
        .committer = who.committer,
        .message = message,
    };
    const oid = try sim.writeObject(.commit, try commit.serializeAlloc(arena));
    sim.updateRefs(&.{.{ .name = name, .op = .{ .update = .{ .new = oid, .old = tip } } }}) catch
        return;
    try sim.commit();
    countOutcome("(foreign fields)", true);

    var report: oracle.Report = .{ .arena = arena };
    try oracle.checkInvariants(arena, before, world.*, &report);
    if (!report.ok()) {
        std.debug.print("  foreign fields on {s}\n", .{world.clones[clone_index].name});
        return reject(report);
    }
    try crossCheckModel(arena, world, clone_index);
}

/// A force-push to the hub: one issue goes back to an older commit of its
/// history, maybe with a new commit on top, or is replaced by an unrelated
/// one. Clones that merged the lost commits push them back after a plain
/// reset, and must quarantine the others.
fn rewriteHub(arena: Allocator, rand: std.Random, world: *World, hub_index: usize) CaseError!void {
    const before = world.*;
    var hub = try GitSim.init(arena, world, hub_index);
    const issues = try hub.listRefs(arena, "refs/issues/");
    if (issues.len == 0) return;
    const target = issues[rand.uintLessThan(usize, issues.len)];
    const tip_object = (try hub.readObject(arena, target.oid)).?;
    const tip = object.Commit.parse(arena, world.format, tip_object.data) catch
        return error.ModelMismatch;
    const sig: object.Signature = .{
        .name = "Mallory",
        .email = "mallory@example.invalid",
        .time = world.clock.now,
        .tz_offset_minutes = 0,
    };
    const kind = rand.uintLessThan(u8, 3);
    const new = if (tip.parents.len > 0 and kind != 0) blk: {
        const older = tip.parents[rand.uintLessThan(usize, tip.parents.len)];
        if (kind == 1) {
            countOutcome("(hub rewound)", true);
            break :blk older;
        }
        countOutcome("(hub rewritten)", true);
        const commit: object.Commit = .{
            .tree = object.emptyTree(world.format),
            .parents = &.{older},
            .author = sig,
            .committer = sig,
            .message = try std.fmt.allocPrint(arena, "Rewritten {d}\n", .{rand.int(u32)}),
        };
        break :blk try hub.writeObject(.commit, try commit.serializeAlloc(arena));
    } else blk: {
        countOutcome("(hub replaced)", true);
        const commit: object.Commit = .{
            .tree = object.emptyTree(world.format),
            .parents = &.{},
            .author = sig,
            .committer = sig,
            .message = try std.fmt.allocPrint(
                arena,
                "Started over {d}\n\nState: open\nFormat-Version: 1\n",
                .{rand.int(u32)},
            ),
        };
        break :blk try hub.writeObject(.commit, try commit.serializeAlloc(arena));
    };
    hub.updateRefs(&.{.{
        .name = target.name,
        .op = .{ .update = .{ .new = new, .old = target.oid } },
    }}) catch return error.ModelMismatch;
    try hub.commit();

    var report: oracle.Report = .{ .arena = arena };
    try oracle.checkInvariants(arena, before, world.*, &report);
    if (!report.ok()) {
        std.debug.print("  force-push of {s} to the hub\n", .{target.name});
        return reject(report);
    }
}

/// Issue IDs quarantined from origin on this clone.
fn quarantinedIds(arena: Allocator, clone: World.Clone) Allocator.Error![]const []const u8 {
    const prefix = "refs/issuez-sync/origin/quarantined/issues/";
    var out: std.ArrayList([]const u8) = .empty;
    for (clone.refs) |r| if (std.mem.startsWith(u8, r.name, prefix)) {
        try out.append(arena, r.name[prefix.len..]);
    };
    return out.items;
}

/// One CLI invocation, checked by the oracle, then the engine's reading of
/// every issue in the clone is compared with the oracle's.
fn step(
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    environ_map: *std.process.Environ.Map,
    world: *World,
    clone_index: usize,
    cmd: Command,
    must_succeed: bool,
) CaseError!u8 {
    const before = world.*;
    const writes = cmd.writes();
    const violations_before = if (writes) try guardViolations(arena, world, clone_index) else &.{};
    const argv = try cmd.argv(arena);
    var discard_buf: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&discard_buf);
    const code = try simulate.run(
        io,
        gpa,
        arena,
        environ_map,
        world,
        clone_index,
        argv,
        &discarding.writer,
        &discarding.writer,
    );
    countOutcome(cmd.verb(), code == 0);
    const shown = try std.mem.join(arena, " ", argv);
    const clone = world.clones[clone_index].name;

    if (must_succeed and code != 0) {
        std.debug.print("  valid command failed ({d}): {s}\n", .{ code, shown });
        return error.ModelMismatch;
    }
    var report: oracle.Report = .{ .arena = arena };
    oracle.checkTransition(arena, before, world.*, clone, cmd, code, &report) catch |err|
        switch (err) {
            error.OutOfMemory => |e| return e,
            error.NoRule => {
                std.debug.print(
                    "  no oracle rule for: {s} on {s} (exit {d})\n",
                    .{ shown, clone, code },
                );
                return error.OracleNoRule;
            },
        };
    for (report.skipped.items) |reason| countSkip(reason);
    if (!report.ok()) {
        std.debug.print("  command: {s} on {s} (exit {d})\n", .{ shown, clone, code });
        return reject(report);
    }
    try crossCheckModel(arena, world, clone_index);
    if (writes and code == 0) {
        // Our writes never break a guard, so no new violation may appear.
        for (try guardViolations(arena, world, clone_index)) |v| {
            if (issuez.format.labels.contains(violations_before, v)) continue;
            std.debug.print(
                "  {s} on {s} introduced a guard violation: {s}\n",
                .{ shown, clone, v },
            );
            return error.ModelMismatch;
        }
    }
    return code;
}

/// Projection problems a guard would have prevented, as `<id> <kind>`.
fn guardViolations(
    arena: Allocator,
    world: *World,
    clone_index: usize,
) CaseError![]const []const u8 {
    var sim = try GitSim.init(arena, world, clone_index);
    var repo = issuez.Repo(GitSim).init(&sim);
    // As the CLI reads it.
    if (sim.configGet(arena, "issue.doneStates") catch null) |raw| {
        var states: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |part| {
            const t = std.mem.trim(u8, part, " \t");
            if (t.len > 0) try states.append(arena, t);
        }
        repo.done_states = states.items;
    }
    const issues = repo.loadAll(arena) catch return error.ModelMismatch;
    const cat = issuez.Catalog(GitSim).of(repo);
    const milestones = cat.infos(arena) catch return error.ModelMismatch;
    const proj = try issuez.projection.build(arena, issues, .{
        .milestones = milestones,
        .done_states = repo.done_states,
    });
    var out: std.ArrayList([]const u8) = .empty;
    for (proj.problems) |p| switch (p.kind) {
        // Not guard rules: values from elsewhere, size limits, a parent
        // deleted later (restoring under it is allowed).
        .invalid_value,
        .too_many_leaves,
        .parent_deleted,
        .invalid_event,
        .pending_event,
        .event_in_other_issue,
        // Retiring keeps the issues in the milestone.
        .milestone_retired,
        // Upstream syncs issues but not milestones.
        .milestone_missing,
        => {},
        else => try out.append(arena, try std.fmt.allocPrint(arena, "{s} {t}", .{ p.id, p.kind })),
    };
    return out.items;
}

fn issueRefsDigest(arena: Allocator, world: World) Allocator.Error![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    for (world.clones) |c| {
        w.writer.print("{s}\n", .{c.name}) catch return error.OutOfMemory;
        for (c.refs) |r| if (isSynced(r.name)) {
            w.writer.print("{s} {s}\n", .{ r.name, r.oid }) catch return error.OutOfMemory;
        };
    }
    return w.written();
}

/// What sync has to converge.
fn isSynced(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "refs/issues/") or
        std.mem.startsWith(u8, name, "refs/milestones/");
}

fn sameIssueRefs(a: World.Clone, b: World.Clone) bool {
    var na: usize = 0;
    for (a.refs) |r| {
        if (!isSynced(r.name)) continue;
        na += 1;
        var found = false;
        for (b.refs) |o| if (std.mem.eql(u8, o.name, r.name) and std.mem.eql(u8, o.oid, r.oid)) {
            found = true;
        };
        if (!found) return false;
    }
    var nb: usize = 0;
    for (b.refs) |r| if (isSynced(r.name)) {
        nb += 1;
    };
    return na == nb;
}

fn crossCheckModel(arena: Allocator, world: *World, clone_index: usize) CaseError!void {
    var sim = try GitSim.init(arena, world, clone_index);
    const repo = issuez.Repo(GitSim).init(&sim);
    const naive_clone = try oracle.commands.Clone.init(
        arena,
        world.format,
        world.clones[clone_index],
    );
    const refs = repo.refs(arena) catch return error.ModelMismatch;
    for (refs) |r| {
        const issue = repo.load(arena, r) catch return error.ModelMismatch;
        const tip_hex = try arena.dupe(u8, r.tip.hex().slice());
        const n = naive_clone.naive(tip_hex) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.NoRule => return error.OracleNoRule,
        };
        const ok = std.mem.eql(u8, issue.title, n.title) and
            std.mem.eql(u8, issue.state.text(), n.state) and
            oracle.commands.sameSet(issue.labels, n.labels) and
            std.mem.eql(u8, issue.field("Assignee") orelse "", n.assignee) and
            std.mem.eql(u8, issue.field("Priority") orelse "", n.priority) and
            std.mem.eql(u8, issue.field("Milestone") orelse "", n.milestone) and
            std.mem.eql(u8, issue.field("X-Parent") orelse "", n.parent) and
            std.mem.eql(u8, issue.field("X-Start-Date") orelse "", n.start) and
            std.mem.eql(u8, issue.field("X-Due-Date") orelse "", n.due) and
            std.mem.eql(u8, issue.field("X-Estimate-Minutes") orelse "", n.estimate) and
            std.mem.eql(u8, issue.field("X-Workflow-State") orelse "", n.workflow) and
            std.mem.eql(u8, issue.field("X-Milestone-Id") orelse "", n.milestone_id) and
            std.mem.eql(u8, issue.field("X-Milestone-Mode") orelse "", n.milestone_mode) and
            sameBlockers(issue.ext, n.blocked_by) and
            issue.deleted == std.mem.eql(u8, n.deleted, "true");
        if (!ok) {
            std.debug.print(
                "  model mismatch on {s}:\n" ++
                    "    engine: '{s}' [{s}] labels={d} a='{s}' p='{s}' m='{s}'\n" ++
                    "    naive:  '{s}' [{s}] labels={d} a='{s}' p='{s}' m='{s}'\n",
                .{
                    r.id(),                             issue.title,
                    issue.state.text(),                 issue.labels.len,
                    issue.field("Assignee") orelse "",  issue.field("Priority") orelse "",
                    issue.field("Milestone") orelse "", n.title,
                    n.state,                            n.labels.len,
                    n.assignee,                         n.priority,
                    n.milestone,
                },
            );
            return error.ModelMismatch;
        }
    }
}

/// The engine's valid blockers plus its invalid ones are the oracle's set.
fn sameBlockers(ext: issuez.model.issue.Extensions, naive: []const []const u8) bool {
    var n: usize = ext.blocked_by.len;
    for (ext.invalid) |f| if (std.mem.eql(u8, f.key, "X-Blocked-By")) {
        n += 1;
    };
    if (n != naive.len) return false;
    for (ext.blocked_by) |b| if (!issuez.format.labels.contains(naive, b)) return false;
    return true;
}

fn driveBackend(arena: Allocator, rand: std.Random, sim: *GitSim) CaseError!void {
    const format = sim.objectFormat();
    var commits: std.ArrayList(Oid) = .empty;
    var model: std.StringHashMapUnmanaged(Oid) = .empty;

    for (0..rand.intRangeAtMost(usize, 1, max_ops)) |_| {
        switch (rand.uintLessThan(u8, 10)) {
            // A commit on the empty tree with 0 to 2 parents.
            0...3 => {
                var parents: [2]Oid = undefined;
                var parent_count: usize = 0;
                if (commits.items.len > 0) {
                    parent_count = rand.uintAtMost(usize, @min(2, commits.items.len));
                    for (parents[0..parent_count]) |*p| p.* = commits.items[
                        rand.uintLessThan(
                            usize,
                            commits.items.len,
                        )
                    ];
                    if (parent_count == 2 and parents[0].eql(parents[1])) parent_count = 1;
                }
                const who = sim.identity(arena) catch return backendMismatch("no identity", .{});
                const sig = who.author;
                var msg_buf: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &msg_buf,
                    "Commit {d}\n\nState: open\n",
                    .{rand.int(u32)},
                ) catch unreachable;
                const c: object.Commit = .{
                    .tree = object.emptyTree(format),
                    .parents = parents[0..parent_count],
                    .author = sig,
                    .committer = sig,
                    .message = msg,
                };
                const oid = try sim.writeObject(.commit, try c.serializeAlloc(arena));
                if (!oid.eql(object.hashObject(
                    format,
                    .commit,
                    try c.serializeAlloc(arena),
                ))) return backendMismatch("writeObject disagrees with git's hashing", .{});
                try commits.append(arena, oid);
            },
            // 1 to 3 ref updates, sometimes with stale expectations.
            4...7 => {
                if (commits.items.len == 0) continue;
                var updates: [3]contract.RefUpdate = undefined;
                var names_used: [3][]const u8 = undefined;
                var n: usize = 0;
                var predicted_ok = true;
                for (0..rand.intRangeAtMost(usize, 1, 3)) |_| {
                    const name = ref_pool[rand.uintLessThan(usize, ref_pool.len)];
                    var dup = false;
                    for (names_used[0..n]) |u| if (std.mem.eql(u8, u, name)) {
                        dup = true;
                    };
                    if (dup) continue;
                    const current = model.get(name);
                    const stale = rand.uintLessThan(u8, 4) == 0;
                    const target = commits.items[rand.uintLessThan(usize, commits.items.len)];
                    const op: contract.RefUpdate.Op = if (current) |cur| switch (rand.uintLessThan(
                        u8,
                        3,
                    )) {
                        0 => .{ .update = .{ .new = target, .old = if (stale) target else cur } },
                        1 => .{ .delete = if (stale) target else cur },
                        else => .{ .verify = if (stale) null else cur },
                    } else switch (rand.uintLessThan(u8, 2)) {
                        0 => if (stale) .{ .update = .{
                            .new = target,
                            .old = target,
                        } } else .{ .create = target },
                        else => .{ .verify = if (stale) target else null },
                    };
                    if (!expectationHolds(op, current)) predicted_ok = false;
                    updates[n] = .{ .name = name, .op = op };
                    names_used[n] = name;
                    n += 1;
                }
                if (n == 0) continue;
                const result = sim.updateRefs(updates[0..n]);
                if (result) |_| {
                    if (!predicted_ok)
                        return backendMismatch("ref update succeeded on a stale expectation", .{});
                    for (updates[0..n]) |u| switch (u.op) {
                        .create => |x| try model.put(arena, u.name, x),
                        .update => |x| try model.put(arena, u.name, x.new),
                        .delete => _ = model.remove(u.name),
                        .verify => {},
                    };
                } else |err| switch (err) {
                    error.RefConflict => if (predicted_ok)
                        return backendMismatch("ref update refused although it was current", .{}),
                    error.OutOfMemory => |e| return e,
                }
                for (ref_pool) |name| {
                    const actual = try sim.resolveRef(name);
                    const expected = model.get(name);
                    if (!sameRef(actual, expected))
                        return backendMismatch("{s} differs from the model", .{name});
                }
            },
            // Every merge base is an ancestor of both.
            else => {
                if (commits.items.len < 2) continue;
                const a = commits.items[rand.uintLessThan(usize, commits.items.len)];
                const b = commits.items[rand.uintLessThan(usize, commits.items.len)];
                const bases = try sim.mergeBases(arena, a, b);
                for (bases) |base| {
                    if (!try sim.isAncestor(
                        base,
                        a,
                    ) or !try sim.isAncestor(base, b))
                        return backendMismatch("a merge base isn't an ancestor", .{});
                }
                if (a.eql(b) and (bases.len != 1 or !bases[0].eql(a)))
                    return backendMismatch("merge base of a commit with itself isn't itself", .{});
            },
        }
    }
}

fn backendMismatch(comptime what: []const u8, args: anytype) CaseError {
    std.debug.print("  backend: " ++ what ++ "\n", args);
    return error.ModelMismatch;
}

fn expectationHolds(op: contract.RefUpdate.Op, current: ?Oid) bool {
    const expected: ?Oid = switch (op) {
        .create => null,
        .update => |x| x.old,
        .delete => |old| old,
        .verify => |old| old,
    };
    return sameRef(current, expected);
}

fn sameRef(a: ?Oid, b: ?Oid) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

fn checkRoundTrip(arena: Allocator, world: World) CaseError!void {
    var first: std.Io.Writer.Allocating = .init(arena);
    try world.write(&first.writer);
    const text = try arena.dupeZ(u8, first.written());
    const back = World.parse(arena, text, null) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseZon => return error.RoundTripMismatch,
    };
    var second: std.Io.Writer.Allocating = .init(arena);
    try back.write(&second.writer);
    if (!std.mem.eql(u8, first.written(), second.written())) return error.RoundTripMismatch;
}

fn reject(report: oracle.Report) CaseError {
    for (report.violations.items) |v| std.debug.print("  oracle: {s}\n", .{v});
    return error.OracleRejected;
}

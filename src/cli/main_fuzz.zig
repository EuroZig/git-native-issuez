//! `git-issue-fuzz`: seeded fuzzing on `GitSim`.
//!
//! Each case first drives random backend operations against a separate
//! model, then runs random commands on a few clones. Every command is
//! checked by the oracle and the engine's reading of each issue is compared
//! with the oracle's. A failing case prints its seed:
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
            return 1;
        };
    }
    for (stats.keys(), stats.values()) |cmd, v| {
        std.debug.print("  {s:<10} {d:>7} ok {d:>7} rejected\n", .{ cmd, v[0], v[1] });
    }
    std.debug.print("git-issue-fuzz: {d} cases passed\n", .{iterations});
    stats.deinit(init.gpa);
    return 0;
}

const CaseError = error{
    OutOfMemory,
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
const milestone_pool = [_][]const u8{ "v1", "2026 Q4", "" };
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

fn generate(arena: Allocator, rand: std.Random, ids: []const []const u8) Allocator.Error!Generated {
    switch (rand.uintLessThan(u8, 12)) {
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
            if (rand.uintLessThan(u8, 4) == 0) x.milestone = pick(rand, &milestone_pool);
            const bodies = [_][]const u8{ "First paragraph.", "Two\nlines", "Fixes: 12" };
            if (rand.boolean()) x.body = pick(rand, &bodies);
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
        else => {
            const verbs = [_][]const u8{ "init", "version", "frobnicate", "sync" };
            const verb = pick(rand, &verbs);
            if (std.mem.eql(u8, verb, "init")) return .{ .cmd = .{ .init = .{} } };
            return .{ .cmd = .{ .read = try arena.dupe([]const u8, &.{verb}) } };
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
    const work_count = rand.intRangeAtMost(usize, 1, 3);
    const clones = try arena.alloc(World.Clone, work_count);
    for (clones, 0..) |*c, idx| c.* = .{ .name = try std.fmt.allocPrint(arena, "c{d}", .{idx}) };
    var world: World = .{
        .format = if (rand.boolean()) .sha1 else .sha256,
        .seed = rand.int(u64),
        .clock = .{
            .now = 1_700_000_000,
            .tz_offset_minutes = rand.intRangeAtMost(i16, -720, 840),
        },
        .clones = clones,
    };

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
        const gen = try generate(arena, rand, ids.items);
        try step(io, gpa, arena, environ_map, &world, clone_index, gen.cmd, gen.must_succeed);
    }

    try checkRoundTrip(arena, world);
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
) CaseError!void {
    const before = world.*;
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
    if (!report.ok()) {
        std.debug.print("  command: {s} on {s} (exit {d})\n", .{ shown, clone, code });
        return reject(report);
    }
    try crossCheckModel(arena, world, clone_index);
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
            std.mem.eql(u8, issue.state, n.state) and
            oracle.commands.sameSet(issue.labels, n.labels) and
            std.mem.eql(u8, issue.field("Assignee") orelse "", n.assignee) and
            std.mem.eql(u8, issue.field("Priority") orelse "", n.priority) and
            std.mem.eql(u8, issue.field("Milestone") orelse "", n.milestone);
        if (!ok) {
            std.debug.print(
                "  model mismatch on {s}:\n" ++
                    "    engine: '{s}' [{s}] labels={d} a='{s}' p='{s}' m='{s}'\n" ++
                    "    naive:  '{s}' [{s}] labels={d} a='{s}' p='{s}' m='{s}'\n",
                .{
                    r.id(),                             issue.title,
                    issue.state,                        issue.labels.len,
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

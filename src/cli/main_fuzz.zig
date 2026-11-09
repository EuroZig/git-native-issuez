//! `git-issue-fuzz`: seeded fuzzing on `GitSim`.
//!
//! Each case first drives random backend operations against a separate
//! model, then runs random commands on a few clones sharing a hub remote.
//! Every command is checked by the oracle and the engine's reading of each
//! issue is compared with the oracle's. Now and then another tool writes
//! extension fields (invalid ones too), or someone force-pushes to the
//! hub, so clones quarantine and resolve. Read commands often run with
//! `--json`, whose output must parse and agree with the oracle's reading
//! of each issue it lists. Finally all clones sync, accepting the hub's
//! version of anything quarantined, until they hold exactly the hub's
//! refs. A failing case prints its seed:
//!
//!     git-issue-fuzz --seed <seed> --iterations 1

const std = @import("std");
const stableSort = @import("issuez").sort.stable;
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
const commands = oracle.commands;
const contains = issuez.format.labels.contains;

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
        const clone = clones[clone_index].name;
        try checkInvariants(arena, before, world, "backend operations on {s}", .{clone});
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
    // Not UTF-8, and characters JSON escapes.
    "bad\xff\xfe",
    "q\"uo\\te",
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
const email_pool = [_][]const u8{
    "a@e.x",
    "bob@example.com",
    "",
    "noat",
    "a@b",
    "@x.y",
    uuid_email,
};
/// The `<uuid> <email>` form: removing `a@e.x` removes it too.
const uuid_email = "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d a@e.x";

fn validEmail(e: []const u8) bool {
    return std.mem.eql(u8, e, "a@e.x") or std.mem.eql(u8, e, "bob@example.com") or
        std.mem.eql(u8, e, uuid_email);
}
/// Host fields: fine, cleared, not an X- key, the format's own, a space.
const field_pool = [_][]const u8{
    "X-Forgejo-Project=7", "X-Forgejo-Project=", "X-Forgejo-Ref-Id=a b", "Foo=1", "State=x",
    "X-Number=5",          "X-Forgejo-Ref-Id",
};
const original_pool = [_][]const u8{ "octocat", "github:o/r#1", "two\nlines" };
const number_pool = [_][]const u8{ "1", "2", "3", "12", "01", "0", "x" };
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

fn pickOid(rand: std.Random, oids: []const Oid) Oid {
    return oids[rand.uintLessThan(usize, oids.len)];
}

fn oneIn(rand: std.Random, n: u8) bool {
    return rand.uintLessThan(u8, n) == 0;
}

/// `must_succeed` is set for input the CLI has to accept.
const Generated = struct { cmd: Command, must_succeed: bool = false };

fn genPrefix(
    arena: Allocator,
    rand: std.Random,
    ids: []const []const u8,
) Allocator.Error![]const u8 {
    if (ids.len == 0 or oneIn(rand, 8)) return pick(rand, &.{ "ffff", "0", "zz" });
    // By number now and then: `#1`, which may match none, one or several.
    if (oneIn(rand, 10)) return pick(rand, &.{ "#1", "#2", "#3", "#01" });
    const id = pick(rand, ids);
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

/// Up to `max` picks from `pool`.
fn pickSome(
    arena: Allocator,
    rand: std.Random,
    max: usize,
    pool: []const []const u8,
) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, rand.uintAtMost(usize, max));
    for (out) |*p| p.* = pick(rand, pool);
    return out;
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
    if (oneIn(rand, 4)) ext.parent = try genPrefix(arena, rand, ids);
    const blockers = if (oneIn(rand, 3)) @as(usize, 2) else 0;
    ext.blocked_by = try some(arena, rand, blockers, genPrefix, .{ arena, rand, ids });
    if (edit and oneIn(rand, 5)) {
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
    for (single) |x| if (oneIn(rand, 5)) {
        x[0].* = pick(rand, x[1]);
    };
    if (edit) {
        const clears = if (oneIn(rand, 4)) @as(usize, 2) else 0;
        ext.clear = try pickSome(arena, rand, clears, &clear_pool);
    }
    return !ext.isEmpty();
}

const samples = issuez.format.attachment.samples;

const fuzz_files = [_]World.File{
    .{ .path = "shot.png", .data = samples.png },
    .{ .path = "dir/photo.jpg", .data = samples.jpeg },
    .{ .path = "pic.webp", .data = samples.webp },
    .{ .path = "anim.png", .data = samples.apng },
    .{ .path = "anim.webp", .data = samples.animated_webp },
    .{ .path = "notes.txt", .data = samples.text },
    .{ .path = "empty.png", .data = "" },
};
const file_pool = [_][]const u8{ "shot.png", "dir/photo.jpg", "pic.webp" };
const bad_file_pool = [_][]const u8{
    "anim.png", "anim.webp", "notes.txt", "empty.png", "missing.png",
};

fn pickFile(rand: std.Random) Allocator.Error![]const u8 {
    if (oneIn(rand, 8)) return pick(rand, &bad_file_pool);
    return pick(rand, &file_pool);
}

fn generateAttach(
    arena: Allocator,
    rand: std.Random,
    ids: []const []const u8,
    attachment_ids: []const []const u8,
) Allocator.Error!Generated {
    if (ids.len == 0) return .{ .cmd = .{ .create = .{ .title = "Needs a screenshot" } } };
    const id = try genPrefix(arena, rand, ids);
    const att = if (attachment_ids.len > 0 and !oneIn(rand, 5)) blk: {
        const full = pick(rand, attachment_ids);
        break :blk full[0..rand.intRangeAtMost(usize, 3, 36)];
    } else pick(rand, &.{ "abcd", "0000", "" });
    const cmd: Command = switch (rand.uintLessThan(u8, 8)) {
        0, 1 => .{ .attach = .{
            .sub = .add,
            .id = id,
            .words = try some(arena, rand, 2, pickFile, .{rand}),
            .text = if (oneIn(rand, 3)) pick(rand, &message_pool) else null,
            .name = if (oneIn(rand, 5))
                pick(rand, &.{ "x.png", " \tspaced ", "" })
            else
                null,
        } },
        2 => .{ .attach = .{
            .sub = .comment,
            .id = id,
            .words = try arena.dupe([]const u8, &.{try pickFile(rand)}),
            .text = if (!oneIn(rand, 4)) pick(rand, &message_pool) else null,
        } },
        3 => .{ .read = if (rand.boolean())
            try arena.dupe([]const u8, &.{ "attach", "ls", id })
        else
            try arena.dupe([]const u8, &.{ "attach", "cat", id, att }) },
        4 => .{ .attach = .{
            .sub = .rename,
            .id = id,
            .words = try arena.dupe([]const u8, &.{
                att,
                pick(rand, &.{ "new.png", "a/b.png", "" }),
            }),
        } },
        5, 6 => .{ .attach = .{
            .sub = .rm,
            .id = id,
            .words = try arena.dupe([]const u8, &.{att}),
            .text = if (rand.boolean()) "Drop it" else null,
        } },
        else => if (rand.boolean()) .repair else .{ .read = &.{ "fsck", "-q" } },
    };
    return .{ .cmd = cmd };
}

/// Milestone guards need long sequences (link, close, complete, reopen,
/// move, restore) that random commands rarely produce.
fn generateMilestoneWork(
    arena: Allocator,
    rand: std.Random,
    ids: []const []const u8,
    /// Few, to keep duplicate names rare. Named by ID now and then, which
    /// reaches retired milestones too.
    milestones: []const []const u8,
) Allocator.Error!Generated {
    const id = try genPrefix(arena, rand, ids);
    const by_id = milestones.len > 0 and oneIn(rand, 3);
    const named = if (oneIn(rand, 4)) "v2" else "v1";
    var kind = rand.uintLessThan(u8, 9);
    if (milestones.len == 0 and rand.boolean()) kind = 0;
    if (kind == 0 and milestones.len > 0 and !oneIn(rand, 8)) kind = 1;
    const name = if (by_id and kind != 0 and kind != 2)
        pick(rand, milestones)[0..8]
    else
        named;
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
        7 => if (rand.boolean()) .{ .delete = .{ .id = id } } else .{ .restore = .{ .id = id } },
        // Its issues and progress, inherited ones included; the catalog.
        else => .{ .read = if (!oneIn(rand, 3))
            try arena.dupe([]const u8, &.{ "milestone", "show", name })
        else if (rand.boolean())
            try arena.dupe([]const u8, &.{ "milestone", "ls", "--all" })
        else
            try arena.dupe([]const u8, &.{ "milestone", "ls" }) },
    };
    return .{ .cmd = cmd };
}

/// The commits of the first issue, so purges hit its comments.
fn firstIssueCommits(
    arena: Allocator,
    world: World,
    clone_index: usize,
    ids: []const []const u8,
) Allocator.Error![]const []const u8 {
    if (ids.len == 0) return &.{};
    const c = try commands.Clone.init(arena, world.format, world.clones[clone_index]);
    const name = try issueRef(arena, ids[0]);
    var out: std.ArrayList([]const u8) = .empty;
    var walk = try c.walk(c.ref(name) orelse return &.{});
    while (try walk.next()) |x| {
        const message = x.commit.message;
        // The root and merges now and then, which purge refuses.
        const comment = x.commit.parents.len == 1 and
            std.mem.find(u8, message, "X-Event:") == null;
        if (comment or out.items.len == 0) try out.append(arena, x.hex);
        // Twice more what a purge has to drop.
        const rich = std.mem.find(u8, message, "X-Original-") != null or
            std.mem.find(u8, message, "X-Attachment:") != null;
        if (comment and rich) try out.appendSlice(arena, &.{ x.hex, x.hex });
    }
    return out.items;
}

fn lifecycleMilestone(arena: Allocator, rand: std.Random) Allocator.Error!Command {
    const names = [_][]const u8{ "v1", "v2", "Later", "v1" };
    const name = pick(rand, &names);
    return switch (rand.uintLessThan(u8, 8)) {
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
}

fn generateLifecycle(
    arena: Allocator,
    rand: std.Random,
    ids: []const []const u8,
    commits: []const []const u8,
    first_commits: []const []const u8,
) Allocator.Error!Generated {
    const id = try genPrefix(arena, rand, ids);
    // Lock and unlock alone, so a reason set earlier meets an unlock.
    // Reactions, on the first issue so they meet: again, undone, on a comment.
    if (oneIn(rand, 6)) return .{ .cmd = .{ .react = .{
        .id = try genPrefix(arena, rand, ids[0..@min(ids.len, 1)]),
        .emoji = pick(rand, &.{ ":+1:", ":+1:", "\u{1F44D}", "two words", "a,b" }),
        .on = if (commits.len > 0 and oneIn(rand, 3))
            pick(rand, commits)[0..8]
        else
            null,
        .undo = oneIn(rand, 3),
    } } };
    // Purges, rare: they take what the other commands work on. Mostly a
    // comment of the first issue, so they meet edits, reactions and
    // each other.
    if (oneIn(rand, 15)) return .{ .cmd = .{ .purge = .{
        .id = if (ids.len > 0 and !oneIn(rand, 4))
            ids[0]
        else
            try genPrefix(arena, rand, ids[0..@min(ids.len, 1)]),
        .comment = if (first_commits.len > 0 and !oneIn(rand, 6))
            pick(rand, first_commits)[0..8]
        else
            null,
        .reason = if (rand.boolean()) "abuse" else null,
    } } };
    // On the first issue, so successive ones meet.
    if (oneIn(rand, 6)) return .{ .cmd = .{ .edit = .{
        .id = try genPrefix(arena, rand, ids[0..@min(ids.len, 1)]),
        .lock = !oneIn(rand, 3),
        .lock_reason = if (rand.boolean()) "too heated" else null,
    } } };
    const cmd: Command = switch (rand.uintLessThan(u8, 5)) {
        4 => try lifecycleMilestone(arena, rand),
        0 => if (rand.boolean()) .{ .delete = .{ .id = id } } else .{ .restore = .{ .id = id } },
        1 => blk: {
            const x: spec.Lifecycle = .{
                .id = id,
                .message = if (rand.boolean()) "Done" else null,
            };
            break :blk if (rand.boolean()) .{ .close = x } else .{ .reopen = x };
        },
        2 => blk: {
            const target = if (commits.len > 0 and !oneIn(rand, 4)) inner: {
                const hex = pick(rand, commits);
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

fn generateCreate(
    arena: Allocator,
    rand: std.Random,
    ids: []const []const u8,
) Allocator.Error!Generated {
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
    if (oneIn(rand, 3)) {
        const e = pick(rand, &email_pool);
        const allowed = [_][]const u8{ "", "a@e.x", "bob@example.com" };
        if (!contains(&allowed, e)) valid = false;
        x.assignee = e;
    }
    if (oneIn(rand, 4)) {
        x.more_assignees = try pickSome(arena, rand, 2, &email_pool);
        for (x.more_assignees) |e| if (!validEmail(e)) {
            valid = false;
        };
    }
    if (oneIn(rand, 4)) {
        x.number = pick(rand, &number_pool);
        // Taken, or not a number: either may fail.
        valid = false;
    }
    if (oneIn(rand, 5)) {
        x.fields = try pickSome(arena, rand, 2, &field_pool);
        for (x.fields) |fl| if (!commands.hostFieldOk(fl) or
            std.mem.endsWith(u8, fl, "="))
        {
            valid = false;
        };
    }
    if (oneIn(rand, 6)) {
        x.original_author = pick(rand, &original_pool);
        x.original_id = pick(rand, &original_pool);
        valid = false;
    }
    if (oneIn(rand, 3)) {
        const p = pick(rand, &priority_pool);
        if (std.mem.eql(u8, p, "urgent")) valid = false;
        x.priority = p;
    }
    if (oneIn(rand, 4)) {
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
}

fn generateState(
    arena: Allocator,
    rand: std.Random,
    ids: []const []const u8,
) Allocator.Error!Generated {
    const st = pick(rand, &state_pool);
    var x: spec.State = .{ .id = try genPrefix(arena, rand, ids), .state = st };
    if (std.mem.eql(u8, st, "open") or std.mem.eql(u8, st, "closed")) x.as_flag = true;
    const messages = [_][]const u8{ "Fixed in abc", "Duplicate", "Two\nlines" };
    if (rand.boolean()) x.message = pick(rand, &messages);
    if (oneIn(rand, 3)) x.fixed_by = "abc1234";
    if (oneIn(rand, 3)) x.reason = "completed";
    // A comment in the same commit; with -m the CLI refuses.
    if (oneIn(rand, 3)) x.comment = try pickSome(arena, rand, 2, &message_pool);
    return .{ .cmd = .{ .state = x } };
}

fn generateEdit(
    arena: Allocator,
    rand: std.Random,
    ids: []const []const u8,
) Allocator.Error!Generated {
    var x: spec.Edit = .{ .id = try genPrefix(arena, rand, ids) };
    const titles = [_][]const u8{ "New title", "Renamed \xe2\x9c\x93" };
    if (oneIn(rand, 3)) x.title = pick(rand, &titles);
    const set = try pickSome(arena, rand, 2, &label_pool);
    if (set.len > 0) x.set_labels = set;
    x.add = try pickSome(arena, rand, 2, &label_pool);
    x.remove = try pickSome(arena, rand, 2, &label_pool);
    if (oneIn(rand, 3)) x.assignee = pick(rand, &email_pool);
    if (oneIn(rand, 4)) x.add_assignees = try pickSome(arena, rand, 2, &email_pool);
    if (oneIn(rand, 5)) x.unassign = try pickSome(arena, rand, 2, &email_pool);
    if (oneIn(rand, 5)) x.number = pick(rand, &number_pool);
    if (oneIn(rand, 6)) {
        x.lock = rand.boolean();
        const reasons = [_][]const u8{ "too heated", "", "spam\nmore" };
        if (rand.boolean()) x.lock_reason = pick(rand, &reasons);
    }
    if (oneIn(rand, 6)) x.ref = pick(rand, &.{ "main", "refs/tags/v1", "a b", "" });
    if (oneIn(rand, 5)) x.fields = try pickSome(arena, rand, 2, &field_pool);
    if (oneIn(rand, 8)) x.original_author = pick(rand, &original_pool);
    if (oneIn(rand, 3)) x.priority = pick(rand, &priority_pool);
    if (oneIn(rand, 4)) x.milestone = pick(rand, &milestone_pool);
    _ = try genExt(arena, rand, ids, &x.ext, true);
    if (oneIn(rand, 3)) x.comment = try pickSome(arena, rand, 2, &message_pool);
    if (oneIn(rand, 4)) {
        x.state = pick(rand, &state_pool);
        if (rand.boolean()) x.fixed_by = "abc1234";
    } else if (oneIn(rand, 8)) x.fixed_by = "abc1234";
    return .{ .cmd = .{ .edit = x } };
}

fn generate(arena: Allocator, rand: std.Random, ids: []const []const u8) Allocator.Error!Generated {
    switch (rand.uintLessThan(u8, 15)) {
        0...2 => return generateCreate(arena, rand, ids),
        3...4 => return .{ .cmd = .{ .comment = .{
            .id = try genPrefix(arena, rand, ids),
            .paragraphs = try pickSome(arena, rand, 2, &message_pool),
            .original_author = if (oneIn(rand, 5)) pick(rand, &original_pool) else null,
            .original_id = if (oneIn(rand, 5)) pick(rand, &original_pool) else null,
        } } },
        5...6 => return generateState(arena, rand, ids),
        7...8 => return generateEdit(arena, rand, ids),
        9 => return .{ .cmd = .{ .read = try arena.dupe([]const u8, &.{
            "ls",
            pick(rand, &.{ "--all", "-f", "-s" }),
            pick(rand, &.{ "full", "closed", "open", "oneline" }),
        }) } },
        10 => return .{ .cmd = .{ .read = if (oneIn(rand, 3))
            try arena.dupe([]const u8, &.{ "fsck", pick(rand, &.{ "--quiet", "--" }) })
        else
            try arena.dupe([]const u8, &.{
                pick(rand, &.{ "show", "search", "tree" }),
                try genPrefix(arena, rand, ids),
            }) } },
        11 => {
            if (oneIn(rand, 3)) return .{ .cmd = .{ .quarantine = .{
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
                    if (oneIn(rand, 4)) {
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
    var world = try commandsWorld(arena, rand, work_count);

    var checker: PushChecker = .{ .rand = rand, .identity = world.identity.email };
    push_checker = &checker;
    GitSim.receive_hook = checker.hook();
    defer {
        push_checker = null;
        GitSim.receive_hook = null;
    }

    const milestone_focus = oneIn(rand, 3);
    for (0..rand.intRangeAtMost(usize, 5, 40)) |_| {
        const clone_index = rand.uintLessThan(usize, work_count);
        // So most generated prefixes resolve.
        const ids = try idsUnder(arena, world.clones[clone_index], "refs/issues/");
        if (oneIn(rand, 5)) {
            // Someone using upstream on this clone.
            try upstreamStep(arena, &world, clone_index);
        } else if (ids.len > 0 and oneIn(rand, 10)) {
            // Another tool writes extension fields, valid or not.
            try foreignStep(arena, rand, &world, clone_index, ids);
        } else if (oneIn(rand, 10)) {
            // Someone force-pushes to the hub.
            try rewriteHub(arena, rand, &world, work_count);
        } else if (oneIn(rand, 8)) {
            // A push the hub only checks.
            try pushCheckStep(arena, rand, &world, clone_index, work_count);
        } else {
            const gen = try generateNext(arena, rand, world, clone_index, ids, milestone_focus);
            const cmd = try withJson(arena, rand, gen.cmd);
            try step(io, gpa, arena, environ_map, &world, clone_index, cmd, gen.must_succeed);
        }
    }

    try settle(io, gpa, arena, environ_map, &world, work_count);
    if (checker.failed) return error.ModelMismatch;
    const hub = world.clones[work_count];
    for (hub.objects) |o| {
        if (o.kind != .commit) continue;
        const c = object.Commit.parse(arena, world.format, o.data) catch continue;
        if (c.parents.len == 2 and std.mem.eql(u8, c.author.name, "git-issue"))
            countOutcome("(merge commits)", true);
    }
    for (world.clones[0..work_count]) |c| {
        if (!sameIssueRefs(hub, c)) {
            std.debug.print("  clone {s} differs from hub after full sync\n", .{c.name});
            return error.NotConverged;
        }
    }
    try checkRoundTrip(arena, world);
}

/// `work_count` clones with the hub as origin, and the hub after them.
fn commandsWorld(arena: Allocator, rand: std.Random, work_count: usize) Allocator.Error!World {
    const clones = try arena.alloc(World.Clone, work_count + 1);
    const custom_workflow = rand.boolean();
    // `in-review` done, `wontfix` and `duplicate` open work.
    const custom_done = oneIn(rand, 3);
    // Attachment commands must refuse there, and its syncs still work.
    const without_lfs: ?usize = if (oneIn(rand, 4)) rand.uintLessThan(usize, work_count) else null;
    for (clones[0..work_count], 0..) |*c, idx| {
        var config: std.ArrayList(World.ConfigEntry) = .empty;
        try config.append(arena, .{ .key = "remote.origin.url", .value = "sim:hub" });
        if (custom_workflow) try config.append(
            arena,
            .{ .key = "issue.workflowStates", .value = "backlog, doing, done" },
        );
        if (custom_done) try config.append(
            arena,
            .{ .key = "issue.doneStates", .value = "in-review" },
        );
        if (without_lfs == idx) try config.append(arena, .{ .key = "sim.lfs", .value = "false" });
        c.* = .{
            .name = try std.fmt.allocPrint(arena, "c{d}", .{idx}),
            .config = config.items,
        };
    }
    clones[work_count] = .{ .name = "hub" };
    return .{
        .format = if (rand.boolean()) .sha1 else .sha256,
        .seed = rand.int(u64),
        .clock = .{
            .now = 1_700_000_000,
            .tz_offset_minutes = rand.intRangeAtMost(i16, -720, 840),
        },
        .clones = clones,
        .files = &fuzz_files,
    };
}

/// Resolving a quarantine now and then, otherwise a command from one of the
/// generators.
fn generateNext(
    arena: Allocator,
    rand: std.Random,
    world: World,
    clone_index: usize,
    ids: []const []const u8,
    milestone_focus: bool,
) Allocator.Error!Generated {
    const clone = world.clones[clone_index];
    const quarantined = try quarantinedIds(arena, clone);
    if (quarantined.len > 0 and rand.boolean()) {
        const id = pick(rand, quarantined);
        return .{ .must_succeed = true, .cmd = .{ .quarantine = .{
            .remote = "origin",
            .accept = rand.boolean(),
            .id = if (rand.boolean()) id else id[0..8],
        } } };
    }
    if (oneIn(rand, 8)) return generateAttach(arena, rand, ids, try attachmentIds(arena, clone));
    if (milestone_focus and oneIn(rand, 2)) {
        const milestones = try idsUnder(arena, clone, "refs/milestones/");
        return generateMilestoneWork(arena, rand, ids, milestones);
    }
    if (oneIn(rand, 6)) return generateLifecycle(
        arena,
        rand,
        ids,
        try commitIds(arena, world, clone_index),
        try firstIssueCommits(arena, world, clone_index, ids),
    );
    return generate(arena, rand, ids);
}

/// So comment events sometimes target a real comment.
fn commitIds(
    arena: Allocator,
    world: World,
    clone_index: usize,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (world.clones[clone_index].objects) |o| if (o.kind == .commit) {
        const oid = object.hashObject(world.format, .commit, o.data);
        try out.append(arena, try oid.hexAlloc(arena));
    };
    return out.items;
}

fn attachmentIds(arena: Allocator, clone: World.Clone) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (clone.objects) |o| if (o.kind == .commit) {
        var it = std.mem.splitSequence(u8, o.data, "X-Attachment: ");
        _ = it.next();
        while (it.next()) |rest| if (rest.len >= 36) {
            try out.append(arena, rest[0..36]);
        };
    };
    return out.items;
}

/// Everyone syncs and takes the hub's version of whatever got quarantined,
/// until nothing changes. Then every clone must match the hub.
fn settle(
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    environ_map: *std.process.Environ.Map,
    world: *World,
    work_count: usize,
) CaseError!void {
    const sync: Command = .{ .sync = .{ .remote = "origin" } };
    for (0..8) |_| {
        const snapshot = try issueRefsDigest(arena, world.*);
        var resolved = false;
        for (0..work_count) |i| {
            try step(io, gpa, arena, environ_map, world, i, sync, true);
            for (try quarantinedIds(arena, world.clones[i])) |id| {
                const cmd: Command = .{ .quarantine = .{
                    .remote = "origin",
                    .accept = true,
                    .id = id,
                } };
                try step(io, gpa, arena, environ_map, world, i, cmd, true);
                resolved = true;
            }
        }
        if (!resolved and std.mem.eql(u8, snapshot, try issueRefsDigest(arena, world.*))) return;
    }
    std.debug.print("  sync did not settle after 8 rounds\n", .{});
    return error.NotConverged;
}

/// What an upstream user does: `git issue merge origin` (modelled by
/// oracle.upstream), then `git push origin 'refs/issues/*:refs/issues/*'`.
/// The engine must read the result like the oracle does, and sync must
/// still converge afterwards.
fn upstreamStep(arena: Allocator, world: *World, clone_index: usize) CaseError!void {
    const before = world.*;
    var sim = try GitSim.init(arena, world, clone_index);
    const staging = "refs/remotes/origin/issues/";
    sim.fetch(arena, "origin", &.{"+refs/issues/*:" ++ staging ++ "*"}, .{}) catch {
        countOutcome("(upstream merge)", false);
        return;
    };
    var merged = false;
    for (try sim.listRefs(arena, staging)) |s| {
        const id = s.name[staging.len..];
        const local_name = try issueRef(arena, id);
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
            const oid = try writeEmptyCommit(arena, &sim, who, &.{ local.?, s.oid }, message);
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
    if (specs.items.len > 0) _ = sim.push(arena, "origin", specs.items, .{}) catch {};
    try sim.commit();
    countOutcome("(upstream merge commit)", merged);

    const clone = world.clones[clone_index].name;
    try checkInvariants(arena, before, world.*, "upstream-style merge on {s}", .{clone});
    try crossCheckModel(arena, world, clone_index);
}

/// A commit as issues are written: on the empty tree.
fn writeEmptyCommit(
    arena: Allocator,
    sim: *GitSim,
    who: contract.Identity,
    parents: []const Oid,
    message: []const u8,
) CaseError!Oid {
    const commit: object.Commit = .{
        .tree = object.emptyTree(sim.objectFormat()),
        .parents = parents,
        .author = who.author,
        .committer = who.committer,
        .message = message,
    };
    return sim.writeObject(.commit, try commit.serializeAlloc(arena));
}

/// Values another tool may write, `""` (a clear) and invalid ones included.
const foreign_pools = [_]struct { []const u8, []const []const u8 }{
    .{ "X-Parent", &.{ "", "not-a-uuid", "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c" } },
    .{ "X-Blocked-By", &.{ "", "nope", "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c, x" } },
    .{ "X-Start-Date", &date_pool },
    .{ "X-Due-Date", &(date_pool ++ [_][]const u8{""}) },
    .{ "X-Estimate-Minutes", &estimate_pool },
    .{ "X-Workflow-State", &(workflow_pool ++ [_][]const u8{ "", "do\xffing" }) },
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
    const name = try issueRef(arena, pick(rand, ids));
    const tip = (try sim.resolveRef(name)) orelse return;
    var list: std.ArrayList(issuez.format.trailers.Trailer) = .empty;
    for (foreign_pools) |f| if (oneIn(rand, 3)) {
        var value = pick(rand, f[1]);
        // A reference to an issue of this clone.
        if (oneIn(rand, 3) and (std.mem.eql(u8, f[0], "X-Parent") or
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
    const oid = try writeEmptyCommit(arena, &sim, who, &.{tip}, message);
    sim.updateRefs(&.{.{ .name = name, .op = .{ .update = .{ .new = oid, .old = tip } } }}) catch
        return;
    try sim.commit();
    countOutcome("(foreign fields)", true);

    const clone = world.clones[clone_index].name;
    try checkInvariants(arena, before, world.*, "foreign fields on {s}", .{clone});
    try crossCheckModel(arena, world, clone_index);
}

/// A force-push to the hub: one issue or milestone goes back to an older
/// commit of its history, maybe with a new commit on top, or is replaced by
/// an unrelated one. Clones that merged the lost commits push them back
/// after a plain reset, and must quarantine the others.
fn rewriteHub(arena: Allocator, rand: std.Random, world: *World, hub_index: usize) CaseError!void {
    const before = world.*;
    var hub = try GitSim.init(arena, world, hub_index);
    const milestones = try hub.listRefs(arena, "refs/milestones/");
    const milestone = milestones.len > 0 and oneIn(rand, 3);
    const refs = if (milestone) milestones else try hub.listRefs(arena, "refs/issues/");
    if (refs.len == 0) return;
    const target = refs[rand.uintLessThan(usize, refs.len)];
    const tip_object = (try hub.readObject(arena, target.oid)).?;
    const tip = object.Commit.parse(arena, world.format, tip_object.data) catch
        return error.ModelMismatch;
    const sig: object.Signature = .{
        .name = "Mallory",
        .email = "mallory@example.invalid",
        .time = world.clock.now,
        .tz_offset_minutes = 0,
    };
    const who: contract.Identity = .{ .author = sig, .committer = sig };
    const kind = rand.uintLessThan(u8, 3);
    const new = if (tip.parents.len > 0 and kind != 0) blk: {
        const older = pickOid(rand, tip.parents);
        if (kind == 1) {
            countOutcome("(hub rewound)", true);
            break :blk older;
        }
        countOutcome("(hub rewritten)", true);
        const message = try std.fmt.allocPrint(arena, "Rewritten {d}\n", .{rand.int(u32)});
        break :blk try writeEmptyCommit(arena, &hub, who, &.{older}, message);
    } else blk: {
        countOutcome("(hub replaced)", true);
        const message = try std.fmt.allocPrint(
            arena,
            "Started over {d}\n\n{s}\nFormat-Version: 1\n",
            .{ rand.int(u32), if (milestone) "Name: Over" else "State: open" },
        );
        break :blk try writeEmptyCommit(arena, &hub, who, &.{}, message);
    };
    // What the hub's push check would have said.
    if (push_checker) |c| try c.check(arena, &hub, &.{.{
        .name = target.name,
        .old = target.oid,
        .new = new,
    }}, false);
    hub.updateRefs(&.{.{
        .name = target.name,
        .op = .{ .update = .{ .new = new, .old = target.oid } },
    }}) catch return error.ModelMismatch;
    try hub.commit();

    try checkInvariants(arena, before, world.*, "force-push of {s} to the hub", .{target.name});
}

fn issueRef(arena: Allocator, id: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "refs/issues/{s}", .{id});
}

/// The rest of the names of the clone's refs under `prefix`.
fn idsUnder(
    arena: Allocator,
    clone: World.Clone,
    prefix: []const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (clone.refs) |r| if (std.mem.startsWith(u8, r.name, prefix)) {
        try out.append(arena, r.name[prefix.len..]);
    };
    return out.items;
}

/// Issue and milestone IDs quarantined from origin on this clone.
fn quarantinedIds(arena: Allocator, clone: World.Clone) Allocator.Error![]const []const u8 {
    return std.mem.concat(arena, []const u8, &.{
        try idsUnder(arena, clone, "refs/issuez-sync/origin/quarantined/issues/"),
        try idsUnder(arena, clone, "refs/issuez-sync/origin/quarantined/milestones/"),
    });
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
    const writes = cmd.writes();
    const violations_before = if (writes) try guardViolations(arena, world, clone_index) else &.{};
    const argv = try cmd.argv(arena);
    var discard_buf: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&discard_buf);
    const json = cmd == .read and contains(argv, "--json");
    var captured: std.Io.Writer.Allocating = .init(arena);
    if (push_checker) |c| c.honest = cmd == .push or cmd == .sync;
    defer if (push_checker) |c| {
        c.honest = false;
    };
    const code = try simulate.run(
        io,
        gpa,
        arena,
        environ_map,
        world,
        clone_index,
        argv,
        if (json) &captured.writer else &discarding.writer,
        &discarding.writer,
    );
    countOutcome(cmd.verb(), code == 0);
    const shown = try std.mem.join(arena, " ", argv);
    const clone = world.clones[clone_index].name;
    if (push_checker) |c| if (c.failed) {
        std.debug.print("  during: {s} on {s}\n", .{ shown, clone });
        return error.ModelMismatch;
    };

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
    if (code == 0) try checkAround(arena, world, clone_index);
    if (json and code == 0) try checkJson(arena, world, clone_index, argv, captured.written());
    if (!writes or code != 0) return;
    // Our writes never break a guard, so no new violation may appear.
    for (try guardViolations(arena, world, clone_index)) |v| {
        if (contains(violations_before, v)) continue;
        // A purged issue is gone: references to it dangle (§10).
        const issue_purge = cmd == .purge and cmd.purge.comment == null;
        if (issue_purge and (std.mem.endsWith(u8, v, " parent_missing") or
            std.mem.endsWith(u8, v, " blocker_missing"))) continue;
        std.debug.print("  {s} on {s} introduced a guard violation: {s}\n", .{ shown, clone, v });
        return error.ModelMismatch;
    }
}

/// Every issue projects the same from `Repo.loadAround` as from all
/// issues: what `show` prints and `show --json` reports.
fn checkAround(arena: Allocator, world: *World, clone_index: usize) CaseError!void {
    var sim = try GitSim.init(arena, world, clone_index);
    var repo = issuez.Repo(GitSim).init(&sim);
    repo.settings.done_states = try doneStatesOf(arena, &sim);
    // Unreadable issues make `loadAll` fail; nothing to compare then.
    const issues = repo.loadAll(arena) catch return;
    const cat = issuez.Catalog(GitSim).fromRepo(repo);
    const milestones = cat.infos(arena) catch return error.ModelMismatch;
    const options: issuez.projection.Options = .{
        .milestones = milestones,
        .done_states = repo.doneStates(),
    };
    const full = try issuez.projection.build(arena, issues, options);
    for (repo.refs(arena) catch return error.ModelMismatch) |r| {
        const i = full.find(r.id()) orelse continue;
        const around = repo.loadAround(arena, r) catch return error.ModelMismatch;
        const part = try issuez.projection.build(arena, around, options);
        const j = part.find(r.id()) orelse {
            std.debug.print("  issue {s} isn't among the issues around it\n", .{r.id()});
            return error.ModelMismatch;
        };
        const same = sameProblems(full.problemsOf(i), part.problemsOf(j)) and
            std.meta.eql(full.progress(i), part.progress(j)) and
            sameText(full.milestone[i], part.milestone[j]) and
            sameText(full.workflow(i), part.workflow(j)) and
            full.activelyBlocked(i) == part.activelyBlocked(j);
        if (!same) {
            std.debug.print(
                "  issue {s} projects differently from the {d} issues around it\n",
                .{ r.id(), around.len },
            );
            return error.ModelMismatch;
        }
    }
    countOutcome("(projection around)", true);
}

fn sameProblems(a: []const issuez.projection.Problem, b: []const issuez.projection.Problem) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.kind != y.kind or !sameText(x.other, y.other) or !sameText(x.key, y.key) or
            !sameText(x.value, y.value)) return false;
    }
    return true;
}

fn sameText(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// As the CLI reads `issue.doneStates`.
fn doneStatesOf(arena: Allocator, sim: *GitSim) Allocator.Error![]const []const u8 {
    const raw = (sim.configGet(arena, "issue.doneStates") catch null) orelse
        return &issuez.format.core.default_done_states;
    var states: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len > 0) try states.append(arena, t);
    }
    return states.items;
}

/// Projection problems a guard would have prevented, as `<id> <kind>`.
fn guardViolations(
    arena: Allocator,
    world: *World,
    clone_index: usize,
) CaseError![]const []const u8 {
    var sim = try GitSim.init(arena, world, clone_index);
    var repo = issuez.Repo(GitSim).init(&sim);
    repo.settings.done_states = try doneStatesOf(arena, &sim);
    const issues = repo.loadAll(arena) catch return error.ModelMismatch;
    const cat = issuez.Catalog(GitSim).fromRepo(repo);
    const milestones = cat.infos(arena) catch return error.ModelMismatch;
    const proj = try issuez.projection.build(arena, issues, .{
        .milestones = milestones,
        .done_states = repo.doneStates(),
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
        std.mem.startsWith(u8, name, "refs/milestones/") or
        std.mem.startsWith(u8, name, "refs/attachments/") or
        std.mem.startsWith(u8, name, "refs/issuez-purged/");
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

/// A history the oracle can't read fails the case here.
fn noRule(err: commands.RuleError) CaseError {
    return switch (err) {
        error.OutOfMemory => |e| e,
        error.NoRule => error.OracleNoRule,
    };
}

fn crossCheckModel(arena: Allocator, world: *World, clone_index: usize) CaseError!void {
    var sim = try GitSim.init(arena, world, clone_index);
    const repo = issuez.Repo(GitSim).init(&sim);
    const naive_clone = try commands.Clone.init(
        arena,
        world.format,
        world.clones[clone_index],
    );
    const refs = repo.refs(arena) catch return error.ModelMismatch;
    for (refs) |r| {
        const issue = repo.load(arena, r) catch return error.ModelMismatch;
        const tip_hex = try r.tip.hexAlloc(arena);
        const n = naive_clone.naive(tip_hex) catch |err| return noRule(err);
        const ok = std.mem.eql(u8, issue.title, n.title) and
            std.mem.eql(u8, issue.state.text(), n.state) and
            commands.sameSet(issue.labels, n.labels) and
            commands.isAssignee(n, issue.field("Assignee") orelse "") and
            std.mem.eql(u8, issue.field("Priority") orelse "", n.priority) and
            std.mem.eql(u8, issue.field("Milestone") orelse "", n.milestone) and
            std.mem.eql(u8, issue.field("X-Parent") orelse "", n.parent) and
            std.mem.eql(u8, issue.field("X-Start-Date") orelse "", n.start) and
            std.mem.eql(u8, issue.field("X-Due-Date") orelse "", n.due) and
            std.mem.eql(u8, issue.field("X-Estimate-Minutes") orelse "", n.estimate) and
            std.mem.eql(u8, issue.field("X-Workflow-State") orelse "", n.workflow) and
            std.mem.eql(u8, issue.field("X-Milestone-Id") orelse "", n.milestone_id) and
            std.mem.eql(u8, issue.field("X-Milestone-Mode") orelse "", n.milestone_mode) and
            sameBlockers(issue.extensions(), n.blocked_by) and
            sameAttachments(issue.attachments, n.attachments) and
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

/// Read commands that take `--json`, as their first words.
const json_reads = [_][]const []const u8{
    &.{"ls"},     &.{"show"},           &.{"tree"},              &.{"search"},
    &.{"status"}, &.{ "attach", "ls" }, &.{ "milestone", "ls" }, &.{ "milestone", "show" },
};

/// Adds `--json` to half the reads that take it.
fn withJson(arena: Allocator, rand: std.Random, cmd: Command) Allocator.Error!Command {
    const read = switch (cmd) {
        .read => |w| w,
        else => return cmd,
    };
    for (json_reads) |r| {
        if (read.len < r.len or !std.mem.eql(u8, read[0], r[0])) continue;
        if (r.len == 2 and !std.mem.eql(u8, read[1], r[1])) continue;
        if (rand.boolean()) return cmd;
        // Last, so it never becomes the value of an option.
        return .{ .read = try std.mem.concat(arena, []const u8, &.{ read, &.{"--json"} }) };
    }
    return cmd;
}

/// `--json` output must parse (the parser also rejects text that isn't
/// UTF-8), and every issue in it must read as the oracle reads the issue:
/// text with bytes that aren't UTF-8 replaced, as docs/json.md says.
fn checkJson(
    arena: Allocator,
    world: *World,
    clone_index: usize,
    argv: []const []const u8,
    out: []const u8,
) CaseError!void {
    const shown = try std.mem.join(arena, " ", argv);
    const clone = try commands.Clone.init(arena, world.format, world.clones[clone_index]);
    const j: JsonCheck = .{ .arena = arena, .clone = clone, .shown = shown, .out = out };
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{}) catch |err| {
        std.debug.print("  {s}: invalid JSON ({t}):\n{s}\n", .{ shown, err, out });
        return error.ModelMismatch;
    };
    var issues: std.ArrayList(std.json.ObjectMap) = .empty;
    const verb = argv[0];
    const ok = if (std.mem.eql(u8, verb, "ls"))
        try collect(arena, &issues, value, .list)
    else if (std.mem.eql(u8, verb, "show"))
        try collect(arena, &issues, value, .one)
    else if (std.mem.eql(u8, verb, "search"))
        try collect(arena, &issues, value, .matches)
    else if (std.mem.eql(u8, verb, "tree"))
        try collect(arena, &issues, value, .nodes)
    else
        value == .object or value == .array;
    if (!ok) {
        std.debug.print("  {s}: unexpected JSON shape:\n{s}\n", .{ shown, out });
        return error.ModelMismatch;
    }

    if (std.mem.eql(u8, verb, "status")) return j.status(value);
    if (std.mem.eql(u8, verb, "attach")) return j.attachments(value, argv[2]);
    if (std.mem.eql(u8, verb, "milestone")) return if (std.mem.eql(u8, argv[1], "ls"))
        j.milestoneList(value, contains(argv, "--all"))
    else
        j.milestoneShow(value);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (issues.items) |o| {
        const id = jsonText(o, "id") orelse return j.bad("an issue without an id");
        // `tree` may show an issue under each of its places; `ls` once.
        if ((try seen.fetchPut(arena, id, {})) != null and !std.mem.eql(u8, verb, "tree"))
            return j.bad("an issue twice");
        const n = (try j.naiveIssue(id)) orelse return j.bad("an issue that isn't there");
        if (!try sameAsNaive(arena, o, n)) {
            std.debug.print("  {s}: issue {s} differs from the oracle's reading\n", .{ shown, id });
            return j.bad("a wrong issue");
        }
        if (!std.mem.eql(u8, verb, "show")) continue;
        if (!sameHistories(o, n)) {
            std.debug.print(
                "  {s}: issue {s}: versions differ from the oracle's\n",
                .{ shown, id },
            );
            return j.bad("wrong versions");
        }
        try j.changes(o);
    }
    countOutcome("(--json issues)", true);
}

/// `status`, `attach ls` and `milestone` output against the refs and the
/// oracle's reading of them.
const JsonCheck = struct {
    arena: Allocator,
    clone: commands.Clone,
    shown: []const u8,
    out: []const u8,

    const Value = std.json.Value;
    const Refs = std.StringHashMapUnmanaged([]const u8);

    fn bad(j: JsonCheck, what: []const u8) CaseError {
        std.debug.print("  {s}: JSON with {s}:\n{s}\n", .{ j.shown, what, j.out });
        return error.ModelMismatch;
    }

    fn done(_: JsonCheck, what: []const u8) void {
        countOutcome(what, true);
    }

    fn asObject(v: Value) ?std.json.ObjectMap {
        return if (v == .object) v.object else null;
    }

    fn isText(j: JsonCheck, o: std.json.ObjectMap, key: []const u8, want: []const u8) !bool {
        return isUtf8(j.arena, o.get(key), want);
    }

    /// Refs under `base` and `rest`, by the rest of their name.
    fn refsUnder(j: JsonCheck, base: []const u8, rest: []const u8) Allocator.Error!Refs {
        const prefix = try std.mem.concat(j.arena, u8, &.{ base, rest });
        var out: Refs = .empty;
        for (j.clone.clone.refs) |r| if (std.mem.startsWith(u8, r.name, prefix)) {
            try out.put(j.arena, r.name[prefix.len..], r.oid);
        };
        return out;
    }

    fn naiveIssue(j: JsonCheck, id: []const u8) CaseError!?commands.NaiveIssue {
        const tip = j.clone.ref(try issueRef(j.arena, id)) orelse return null;
        return j.clone.naive(tip) catch |err| return noRule(err);
    }

    /// Remotes from the config; per remote the quarantines (from their
    /// records) and the pending issues: not quarantined, tip not the
    /// `pushed` record.
    fn status(j: JsonCheck, v: Value) CaseError!void {
        const o = asObject(v) orelse return j.bad("a status that isn't an object");
        var configured: std.ArrayList([]const u8) = .empty;
        for (j.clone.clone.config) |e| {
            if (!std.mem.startsWith(u8, e.key, "remote.") or !std.mem.endsWith(u8, e.key, ".url"))
                continue;
            try configured.append(j.arena, e.key["remote.".len .. e.key.len - ".url".len]);
        }
        const remotes = asArray(o.get("remotes")) orelse return j.bad("no remotes");
        if (remotes.len != configured.items.len) return j.bad("other remotes than configured");
        for (remotes) |rv| try j.statusRemote(rv, configured.items);
        const conflicts = asArray(o.get("conflicts")) orelse return j.bad("no conflicts list");
        for (conflicts) |cv| {
            const c = asObject(cv) orelse return j.bad("a conflict that isn't an object");
            const id = jsonText(c, "id") orelse return j.bad("a conflict without an id");
            if (try j.naiveIssue(id) == null) return j.bad(
                "a conflict on an issue that isn't there",
            );
            for ([_][]const u8{ "field", "kept", "lost" }) |k| {
                if (jsonText(c, k) == null) return j.bad("a conflict without field, kept or lost");
            }
        }
        j.done("(--json status)");
    }

    fn statusRemote(j: JsonCheck, rv: Value, configured: []const []const u8) CaseError!void {
        const r = asObject(rv) orelse return j.bad("a remote that isn't an object");
        const name = jsonText(r, "name") orelse return j.bad("a remote without a name");
        if (!contains(configured, name)) return j.bad("a remote that isn't configured");
        const base = try std.fmt.allocPrint(j.arena, "refs/issuez-sync/{s}/", .{name});
        const issue_marks = try j.refsUnder(base, "quarantined/issues/");
        const milestone_marks = try j.refsUnder(base, "quarantined/milestones/");
        const quarantined = asArray(r.get("quarantined")) orelse
            return j.bad("no quarantined list");
        if (quarantined.len != issue_marks.count() + milestone_marks.count())
            return j.bad("other quarantines than recorded");
        for (quarantined) |qv| try j.statusQuarantine(qv, base, issue_marks, milestone_marks);
        const pushed = try j.refsUnder(base, "pushed/issues/");
        var want: std.ArrayList([]const u8) = .empty;
        for (j.clone.clone.refs) |ref| {
            if (!std.mem.startsWith(u8, ref.name, "refs/issues/")) continue;
            const id = ref.name["refs/issues/".len..];
            if (issue_marks.contains(id)) continue;
            if (pushed.get(id)) |p| if (std.mem.eql(u8, p, ref.oid)) continue;
            try want.append(j.arena, id);
        }
        const pending = asArray(r.get("pending")) orelse return j.bad("no pending list");
        var got: std.ArrayList([]const u8) = .empty;
        for (pending) |p| {
            if (p != .string) return j.bad("a pending entry that isn't an ID");
            try got.append(j.arena, p.string);
        }
        if (!commands.sameSet(got.items, want.items) or got.items.len != want.items.len)
            return j.bad("other pending issues than the records say");
    }

    fn statusQuarantine(
        j: JsonCheck,
        qv: Value,
        base: []const u8,
        issue_marks: Refs,
        milestone_marks: Refs,
    ) CaseError!void {
        const q = asObject(qv) orelse return j.bad("a quarantine that isn't an object");
        const id = jsonText(q, "id") orelse return j.bad("a quarantine without an id");
        const kind = jsonText(q, "kind") orelse return j.bad("a quarantine without a kind");
        const ns = if (std.mem.eql(u8, kind, "issue"))
            "issues"
        else if (std.mem.eql(u8, kind, "milestone"))
            "milestones"
        else
            return j.bad("a quarantine of another kind");
        const marks = if (ns[0] == 'i') issue_marks else milestone_marks;
        const tip = marks.get(id) orelse return j.bad("a quarantine that isn't recorded");
        if (!std.mem.eql(u8, jsonText(q, "remote_tip") orelse "", tip))
            return j.bad("a quarantine with another remote tip");
        const kept = j.clone.ref(
            try std.fmt.allocPrint(j.arena, "{s}kept/{s}/{s}", .{ base, ns, id }),
        );
        const kept_local = q.get("kept_local") orelse return j.bad("no kept_local");
        const want_kept = kept != null and std.mem.eql(u8, kept.?, tip);
        if (kept_local != .bool or kept_local.bool != want_kept)
            return j.bad("a wrong kept_local");
        if (jsonText(q, "title") == null) return j.bad("a quarantine without a title");
        const reason = q.get("reason") orelse return j.bad("no reason");
        if (reason == .null) return;
        const known = [_][]const u8{ "unrelated_history", "rewound", "invalid_issue" };
        if (reason != .string or !contains(&known, reason.string))
            return j.bad("an unknown reason");
    }

    /// Exactly the issue's attachments as the oracle reads them.
    fn attachments(j: JsonCheck, v: Value, prefix: []const u8) CaseError!void {
        const listed = asArray(v) orelse return j.bad("attachments that aren't an array");
        const refs = try j.clone.matching(prefix);
        if (refs.len != 1) return j.bad("attachments of an ambiguous or unknown issue");
        const n = (try j.naiveIssue(refs[0]["refs/issues/".len..])).?;
        if (listed.len != n.attachments.len) return j.bad("other attachments than the oracle's");
        for (listed) |av| {
            const a = asObject(av) orelse return j.bad("an attachment that isn't an object");
            const id = jsonText(a, "id") orelse return j.bad("an attachment without an id");
            const want = for (n.attachments) |na| {
                if (std.mem.eql(u8, na.id, id)) break na;
            } else return j.bad("an attachment the oracle doesn't know");
            const size = a.get("size") orelse return j.bad("an attachment without a size");
            const want_size = std.fmt.parseInt(i64, want.size, 10) catch
                return j.bad("an attachment with a size the oracle can't read");
            if (!try j.isText(a, "name", want.name) or !try j.isText(a, "media_type", want.media) or
                !try j.isText(a, "sha256", want.sha256) or size != .integer or
                size.integer != want_size)
                return j.bad("an attachment that differs from the oracle's");
            const availability = jsonText(a, "availability") orelse "";
            if (!contains(&.{ "local", "missing", "corrupt" }, availability))
                return j.bad("an attachment without a known availability");
        }
        j.done("(--json attach ls)");
    }

    /// The catalog as the oracle reads it: open milestones, or all.
    fn milestoneList(j: JsonCheck, v: Value, all: bool) CaseError!void {
        const listed = asArray(v) orelse return j.bad("milestones that aren't an array");
        const naive = j.clone.milestones() catch |err| return noRule(err);
        var want: usize = 0;
        for (naive) |m| {
            if (!all and !std.mem.eql(u8, m.status, "open")) continue;
            want += 1;
        }
        if (listed.len != want) return j.bad("other milestones than the oracle's");
        for (listed) |mv| _ = try j.milestone(mv, naive, all);
        j.done("(--json milestone ls)");
    }

    fn milestone(
        j: JsonCheck,
        mv: Value,
        naive: []const commands.NaiveMilestone,
        all: bool,
    ) CaseError!commands.NaiveMilestone {
        const m = asObject(mv) orelse return j.bad("a milestone that isn't an object");
        const id = jsonText(m, "id") orelse return j.bad("a milestone without an id");
        const want = for (naive) |n| {
            if (std.mem.eql(u8, n.id, id)) break n;
        } else return j.bad("a milestone the oracle doesn't know");
        if (!all and !std.mem.eql(u8, want.status, "open"))
            return j.bad("a milestone that isn't open");
        if (!try j.isText(m, "name", want.name) or !try j.isText(m, "status", want.status) or
            !std.mem.eql(u8, jsonText(m, "short_id") orelse "", id[0..7]))
            return j.bad("a milestone that differs from the oracle's");
        return want;
    }

    /// Without restating inheritance: every listed issue is there, not
    /// deleted and linked to the milestone itself or through its parents;
    /// every issue linked directly (mode `explicit`, or unset with an ID)
    /// is listed, unless the milestone is retired.
    fn milestoneShow(j: JsonCheck, v: Value) CaseError!void {
        const naive = j.clone.milestones() catch |err| return noRule(err);
        const m = try j.milestone(v, naive, true);
        const progress = asObject(
            v.object.get("progress") orelse return j.bad("no progress"),
        ) orelse
            return j.bad("a progress that isn't an object");
        const closed = progress.get("closed") orelse return j.bad("no closed count");
        const total = progress.get("total") orelse return j.bad("no total count");
        if (closed != .integer or total != .integer or closed.integer < 0 or
            closed.integer > total.integer) return j.bad("a progress that doesn't add up");
        const members = asArray(v.object.get("issues")) orelse return j.bad("no issues list");
        var listed: std.ArrayList([]const u8) = .empty;
        for (members) |iv| {
            if (iv != .string) return j.bad("an issue entry that isn't an ID");
            try listed.append(j.arena, iv.string);
            var cur = (try j.naiveIssue(iv.string)) orelse
                return j.bad("an issue that isn't there");
            if (std.mem.eql(u8, cur.deleted, "true")) return j.bad("a deleted issue");
            // The nearest link up the chain; loops end at the step limit.
            var linked = false;
            for (0..64) |_| {
                if (std.mem.eql(u8, cur.milestone_id, m.id)) linked = true;
                if (linked or cur.parent.len == 0) break;
                cur = (try j.naiveIssue(cur.parent)) orelse break;
            }
            if (!linked) return j.bad("an issue not linked to the milestone");
        }
        if (total.integer > members.len) return j.bad("more leaves than issues");
        if (std.mem.eql(u8, m.status, "retired")) return j.done("(--json milestone show)");
        for (j.clone.clone.refs) |r| {
            if (!std.mem.startsWith(u8, r.name, "refs/issues/")) continue;
            const id = r.name["refs/issues/".len..];
            const n = (try j.naiveIssue(id)).?;
            const linked = std.mem.eql(u8, n.milestone_id, m.id);
            if (!linked or std.mem.eql(u8, n.deleted, "true")) continue;
            const mode = n.milestone_mode;
            if (std.mem.eql(u8, mode, "none") or std.mem.eql(u8, mode, "inherit")) continue;
            if (!contains(listed.items, id))
                return j.bad("a directly linked issue that isn't listed");
        }
        j.done("(--json milestone show)");
    }

    /// Each comment's `changes`, and `created_changes`, as the oracle states
    /// them, for the fields it knows.
    fn changes(j: JsonCheck, o: std.json.ObjectMap) CaseError!void {
        const history = asArray(o.get("description_history")) orelse &.{};
        if (history.len == 0 or history[0] != .object) return j.bad("no description_history");
        const root = jsonText(history[0].object, "id") orelse return j.bad("no root");
        try j.sameChanges(root, o.get("created_changes"));
        const comments = asArray(o.get("comments")) orelse return j.bad("no comments");
        for (comments) |c| {
            if (c != .object) return j.bad("a comment that isn't an object");
            const id = jsonText(c.object, "id") orelse return j.bad("a comment without an id");
            try j.sameChanges(id, c.object.get("changes"));
        }
    }

    fn sameChanges(j: JsonCheck, commit: []const u8, got: ?Value) CaseError!void {
        const want = commands.changesOf(j.clone, commit) catch |err| return noRule(err);
        const list = got orelse return j.bad("no changes");
        if (list != .array) return j.bad("changes that aren't a list");
        var count: usize = 0;
        for (list.array.items) |c| {
            if (c != .object) return j.bad("a change that isn't an object");
            const key = jsonText(c.object, "key") orelse return j.bad("a change without a key");
            if (knownChange(key)) count += 1;
        }
        for (want) |w| {
            const found = for (list.array.items) |c| {
                const key = jsonText(c.object, "key") orelse continue;
                const op = jsonText(c.object, "op") orelse continue;
                if (!std.mem.eql(u8, key, w.key) or !std.mem.eql(u8, op, w.op)) continue;
                const same_old = try j.sameSide(c.object.get("old"), w.old);
                if (same_old and try j.sameSide(c.object.get("new"), w.new)) break true;
            } else false;
            if (!found) {
                std.debug.print("  {s}: commit {s}: no change {s} {s} {?s} -> {?s}\n", .{
                    j.shown, commit, w.op, w.key, w.old, w.new,
                });
                return j.bad("a missing change");
            }
        }
        if (count != want.len) {
            std.debug.print(
                "  {s}: commit {s}: {d} changes, the oracle states {d}\n",
                .{ j.shown, commit, count, want.len },
            );
            return j.bad("extra changes");
        }
    }

    fn sameSide(j: JsonCheck, got: ?Value, want: ?[]const u8) Allocator.Error!bool {
        if (want) |text| return isUtf8(j.arena, got, text);
        return got != null and got.? == .null;
    }

    fn knownChange(key: []const u8) bool {
        return contains(&commands.change_scalars, key) or
            contains(&commands.change_sets, key) or std.mem.eql(u8, key, "X-Attachment");
    }
};

const Shape = enum { list, one, matches, nodes };

/// The issue objects of a command's output. False when the shape is wrong.
fn collect(
    arena: Allocator,
    issues: *std.ArrayList(std.json.ObjectMap),
    v: std.json.Value,
    shape: Shape,
) Allocator.Error!bool {
    switch (shape) {
        .one => {
            if (v != .object) return false;
            try issues.append(arena, v.object);
        },
        .list, .matches, .nodes => {
            if (v != .array) return false;
            for (v.array.items) |item| {
                if (item != .object) return false;
                if (shape == .list) {
                    try issues.append(arena, item.object);
                    continue;
                }
                const inner = item.object.get("issue") orelse return false;
                if (inner != .object) return false;
                try issues.append(arena, inner.object);
                if (shape == .nodes) {
                    const children = item.object.get("children") orelse return false;
                    if (!try collect(arena, issues, children, .nodes)) return false;
                }
            }
        },
    }
    return true;
}

fn asArray(v: ?std.json.Value) ?[]const std.json.Value {
    const a = v orelse return null;
    return if (a == .array) a.array.items else null;
}

fn jsonText(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// How `--json` writes text: bytes that aren't UTF-8 become U+FFFD.
fn utf8(arena: Allocator, v: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{f}", .{std.unicode.fmtUtf8(v)});
}

/// `v` is `--json`'s text for `want`.
fn isUtf8(arena: Allocator, v: ?std.json.Value, want: []const u8) Allocator.Error!bool {
    const x = v orelse return false;
    return x == .string and std.mem.eql(u8, x.string, try utf8(arena, want));
}

/// `description_history` and each comment's `history` hold the versions
/// the oracle finds: the same commits, each with the same kind.
fn sameHistories(o: std.json.ObjectMap, n: commands.NaiveIssue) bool {
    if (!sameRevisions(o.get("description_history"), n.description_history)) return false;
    const comments = asArray(o.get("comments")) orelse return false;
    for (comments) |c| {
        if (c != .object) return false;
        const merge = c.object.get("merge") orelse return false;
        if (merge == .bool and merge.bool) continue;
        const id = jsonText(c.object, "id") orelse return false;
        const want = for (n.comment_histories) |h| {
            if (std.mem.eql(u8, h.comment, id)) break h.revisions;
        } else return false;
        if (!sameRevisions(c.object.get("history"), want)) return false;
    }
    return true;
}

fn sameRevisions(v: ?std.json.Value, want: []const commands.NaiveRevision) bool {
    const list = asArray(v) orelse return false;
    if (list.len != want.len) return false;
    for (want) |w| {
        const found = for (list) |r| {
            if (r != .object) return false;
            const id = jsonText(r.object, "id") orelse return false;
            const kind = jsonText(r.object, "kind") orelse return false;
            if (std.mem.eql(u8, id, w.commit) and std.mem.eql(u8, kind, w.kind)) break true;
        } else false;
        if (!found) return false;
    }
    return true;
}

/// The core fields as the oracle reads them, `null` for "". Extension
/// fields only when set, since `--json` leaves out values it can't parse.
fn sameAsNaive(
    arena: Allocator,
    o: std.json.ObjectMap,
    n: commands.NaiveIssue,
) Allocator.Error!bool {
    const Pair = struct { []const u8, []const u8 };
    for ([_]Pair{
        .{ "title", n.title },             .{ "state", n.state },
        .{ "priority", n.priority },       .{ "milestone", n.milestone },
        .{ "lock_reason", n.lock_reason },
    }) |f| {
        const v = o.get(f[0]) orelse return false;
        if (f[1].len == 0) {
            if (v != .null) return false;
        } else if (!try isUtf8(arena, v, f[1])) return false;
    }
    for ([_]Pair{
        .{ "parent", n.parent },     .{ "start", n.start }, .{ "due", n.due },
        .{ "workflow", n.workflow }, .{ "ref", n.ref },     .{ "milestone_id", n.milestone_id },
    }) |f| {
        const v = o.get(f[0]) orelse return false;
        if (v != .null and !try isUtf8(arena, v, f[1])) return false;
    }
    for ([_]Pair{ .{ "locked", n.locked }, .{ "deleted", n.deleted } }) |f| {
        const v = o.get(f[0]) orelse return false;
        if (v != .bool or v.bool != std.mem.eql(u8, f[1], "true")) return false;
    }
    // `number` only when it reads as one.
    const number = o.get("number") orelse return false;
    if (commands.validNumber(n.number)) {
        const want = std.fmt.parseInt(i64, n.number, 10) catch -1;
        if (number != .integer or number.integer != want) return false;
    } else if (number != .null) return false;
    // Host fields, as written, in `fields`.
    const fields = o.get("fields") orelse return false;
    if (fields != .object) return false;
    for (commands.host_keys, n.host) |k, want| {
        const got = fields.object.get(k);
        if (want.len == 0) {
            if (got != null) return false;
        } else if (!try isUtf8(arena, got, want)) return false;
    }
    if (!try sameAssignees(arena, o, n)) return false;
    if (!try sameReactions(arena, o, n)) return false;

    const labels = asArray(o.get("labels")) orelse return false;
    if (labels.len != n.labels.len) return false;
    for (labels) |l| {
        if (l != .string) return false;
        const found = for (n.labels) |want| {
            if (std.mem.eql(u8, l.string, try utf8(arena, want))) break true;
        } else false;
        if (!found) return false;
    }
    const blocked_by = asArray(o.get("blocked_by")) orelse return false;
    for (blocked_by) |b| {
        if (b != .string or !contains(n.blocked_by, b.string)) return false;
    }
    const attachments = asArray(o.get("attachments")) orelse return false;
    if (attachments.len != n.attachments.len) return false;
    for (attachments) |a| {
        if (a != .object) return false;
        const id = jsonText(a.object, "id") orelse return false;
        const found = for (n.attachments) |na| {
            if (std.mem.eql(u8, na.id, id)) break true;
        } else false;
        if (!found) return false;
    }
    return true;
}

/// By email, also for the `<uuid> <email>` form; `assignees` in the oracle's
/// order.
fn sameAssignees(
    arena: Allocator,
    o: std.json.ObjectMap,
    n: commands.NaiveIssue,
) Allocator.Error!bool {
    const assignee = o.get("assignee") orelse return false;
    if (n.assignee.len == 0 and !n.assignee_any) {
        if (assignee != .null) return false;
    } else {
        if (assignee != .string) return false;
        const candidates: []const []const u8 = if (n.assignee_any) n.assignees else &.{n.assignee};
        const found = for (candidates) |c| {
            const raw = try utf8(arena, c);
            const suffix = try std.fmt.allocPrint(arena, " {s}", .{assignee.string});
            if (std.mem.eql(u8, assignee.string, raw) or std.mem.endsWith(u8, raw, suffix))
                break true;
        } else false;
        if (!found) return false;
    }
    const assignees = asArray(o.get("assignees")) orelse return false;
    if (assignees.len != n.assignees.len) return false;
    for (assignees, n.assignees) |got, want| {
        if (got != .string) return false;
        const raw = try utf8(arena, want);
        const email = if (std.mem.findScalarLast(u8, raw, ' ')) |sp| raw[sp + 1 ..] else raw;
        if (!std.mem.eql(u8, got.string, email) and !std.mem.eql(u8, got.string, raw)) return false;
    }
    return true;
}

/// The same members as the oracle's.
fn sameReactions(
    arena: Allocator,
    o: std.json.ObjectMap,
    n: commands.NaiveIssue,
) Allocator.Error!bool {
    const reactions = asArray(o.get("reactions")) orelse return false;
    var count: usize = 0;
    for (reactions) |r| {
        if (r != .object) return false;
        const on = r.object.get("comment");
        const target = if (on != null and on.? == .string) on.?.string else "-";
        const emoji = jsonText(r.object, "emoji") orelse return false;
        const users = asArray(r.object.get("users")) orelse return false;
        for (users) |u| {
            if (u != .string) return false;
            const member = try std.fmt.allocPrint(
                arena,
                "{s} {s} {s}",
                .{ target, emoji, u.string },
            );
            if (!commands.containsText(n.reactions, member)) return false;
            count += 1;
        }
    }
    return count == n.reactions.len;
}

fn sameAttachments(
    engine: []const issuez.model.issue.Attachment,
    naive: []const commands.NaiveAttachment,
) bool {
    if (engine.len != naive.len) return false;
    for (engine) |e| {
        const n = for (naive) |n| {
            if (std.mem.eql(u8, n.id, e.id)) break n;
        } else return false;
        if (!std.mem.eql(u8, n.name, e.name) or !std.mem.eql(u8, n.sha256, e.sha256.slice()) or
            !std.mem.eql(u8, n.media, e.media.mediaType())) return false;
    }
    return true;
}

/// The engine's valid blockers plus its invalid ones are the oracle's set.
fn sameBlockers(ext: issuez.model.issue.Extensions, naive: []const []const u8) bool {
    var n: usize = ext.blocked_by.len;
    for (ext.invalid_fields) |f| if (std.mem.eql(u8, f.key, "X-Blocked-By")) {
        n += 1;
    };
    if (n != naive.len) return false;
    for (ext.blocked_by) |b| if (!contains(naive, b)) return false;
    return true;
}

fn driveBackend(arena: Allocator, rand: std.Random, sim: *GitSim) CaseError!void {
    var commits: std.ArrayList(Oid) = .empty;
    var model: std.StringHashMapUnmanaged(Oid) = .empty;

    for (0..rand.intRangeAtMost(usize, 1, max_ops)) |_| {
        switch (rand.uintLessThan(u8, 10)) {
            0...3 => try commits.append(arena, try backendCommit(arena, rand, sim, commits.items)),
            4...7 => try backendRefUpdates(arena, rand, sim, commits.items, &model),
            else => try backendMergeBases(arena, rand, sim, commits.items),
        }
    }
}

/// A commit on the empty tree with 0 to 2 parents.
fn backendCommit(
    arena: Allocator,
    rand: std.Random,
    sim: *GitSim,
    commits: []const Oid,
) CaseError!Oid {
    var parents: [2]Oid = undefined;
    var parent_count: usize = 0;
    if (commits.len > 0) {
        parent_count = rand.uintAtMost(usize, @min(2, commits.len));
        for (parents[0..parent_count]) |*p| p.* = pickOid(rand, commits);
        if (parent_count == 2 and parents[0].eql(parents[1])) parent_count = 1;
    }
    const sig = (sim.identity(arena) catch return backendMismatch("no identity", .{})).author;
    const format = sim.objectFormat();
    const c: object.Commit = .{
        .tree = object.emptyTree(format),
        .parents = parents[0..parent_count],
        .author = sig,
        .committer = sig,
        .message = try std.fmt.allocPrint(arena, "Commit {d}\n\nState: open\n", .{rand.int(u32)}),
    };
    const data = try c.serializeAlloc(arena);
    const oid = try sim.writeObject(.commit, data);
    if (!oid.eql(object.hashObject(format, .commit, data)))
        return backendMismatch("writeObject disagrees with git's hashing", .{});
    return oid;
}

/// 1 to 3 ref updates, sometimes with stale expectations.
fn backendRefUpdates(
    arena: Allocator,
    rand: std.Random,
    sim: *GitSim,
    commits: []const Oid,
    model: *std.StringHashMapUnmanaged(Oid),
) CaseError!void {
    if (commits.len == 0) return;
    var updates: [3]contract.RefUpdate = undefined;
    var names_used: [3][]const u8 = undefined;
    var n: usize = 0;
    var predicted_ok = true;
    for (0..rand.intRangeAtMost(usize, 1, 3)) |_| {
        const name = pick(rand, &ref_pool);
        if (contains(names_used[0..n], name)) continue;
        const current = model.get(name);
        const stale = oneIn(rand, 4);
        const target = pickOid(rand, commits);
        const op: contract.RefUpdate.Op = if (current) |cur| switch (rand.uintLessThan(u8, 3)) {
            0 => .{ .update = .{ .new = target, .old = if (stale) target else cur } },
            1 => .{ .delete = if (stale) target else cur },
            else => .{ .verify = if (stale) null else cur },
        } else switch (rand.uintLessThan(u8, 2)) {
            0 => if (stale)
                .{ .update = .{ .new = target, .old = target } }
            else
                .{ .create = target },
            else => .{ .verify = if (stale) target else null },
        };
        if (!expectationHolds(op, current)) predicted_ok = false;
        updates[n] = .{ .name = name, .op = op };
        names_used[n] = name;
        n += 1;
    }
    if (n == 0) return;
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
        if (!sameRef(actual, model.get(name)))
            return backendMismatch("{s} differs from the model", .{name});
    }
}

/// Every merge base is an ancestor of both.
fn backendMergeBases(
    arena: Allocator,
    rand: std.Random,
    sim: *GitSim,
    commits: []const Oid,
) CaseError!void {
    if (commits.len < 2) return;
    const a = pickOid(rand, commits);
    const b = pickOid(rand, commits);
    const bases = try sim.mergeBases(arena, a, b);
    for (bases) |base| {
        if (!try sim.isAncestor(base, a) or !try sim.isAncestor(base, b))
            return backendMismatch("a merge base isn't an ancestor", .{});
    }
    if (a.eql(b) and (bases.len != 1 or !bases[0].eql(a)))
        return backendMismatch("merge base of a commit with itself isn't itself", .{});
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

/// The oracle's invariants over a step that isn't a CLI command.
fn checkInvariants(
    arena: Allocator,
    before: World,
    after: World,
    comptime what: []const u8,
    args: anytype,
) CaseError!void {
    var report: oracle.Report = .{ .arena = arena };
    try oracle.checkInvariants(arena, before, after, &report);
    if (report.ok()) return;
    std.debug.print("  " ++ what ++ "\n", args);
    return reject(report);
}

fn reject(report: oracle.Report) CaseError {
    for (report.violations.items) |v| std.debug.print("  oracle: {s}\n", .{v});
    return error.OracleRejected;
}

// ─── Push check ────────────────────────────────────────────────────────

/// Every push that reaches the hub goes through the push check, run by the
/// engine and by the oracle, which must agree; under a permissive policy an
/// honest sync must pass (format.md §11). Pushes are never refused here,
/// so the rest of the case runs as before.
const PushChecker = struct {
    rand: std.Random,
    identity: []const u8,
    /// A sync or push command is running: its pushes are honest.
    honest: bool = false,
    failed: bool = false,

    fn hook(c: *PushChecker) GitSim.ReceiveHook {
        return .{ .context = c, .receive = receive };
    }

    fn receive(
        context: *anyopaque,
        arena: Allocator,
        quarantine: *GitSim,
        updates: []const GitSim.Received,
    ) bool {
        const c: *PushChecker = @ptrCast(@alignCast(context));
        c.check(arena, quarantine, updates, c.honest) catch |e| {
            std.debug.print("  push check: {t}\n", .{e});
            c.failed = true;
        };
        return true;
    }

    fn policyOf(c: *PushChecker, arena: Allocator) Allocator.Error!issuez.push_check.Policy {
        const r = c.rand;
        if (r.boolean()) return .{ .allow_numbers = true, .allow_purge = true };
        var emails: std.ArrayList([]const u8) = .empty;
        if (!oneIn(r, 4)) try emails.append(
            arena,
            if (r.boolean()) c.identity else try std.ascii.allocUpperString(arena, c.identity),
        );
        if (r.boolean()) try emails.append(arena, "mallory@example.invalid");
        var ids: std.ArrayList([]const u8) = .empty;
        for (author_ids) |id| if (r.boolean()) try ids.append(
            arena,
            if (r.boolean()) id else try std.ascii.allocUpperString(arena, id),
        );
        return .{
            .pusher_emails = emails.items,
            .pusher_ids = ids.items,
            .author_policy = @enumFromInt(r.uintLessThan(u8, 3)),
            .allow_numbers = r.boolean(),
            .allow_purge = r.boolean(),
            // Now and then a budget for merges that runs out.
            .max_merge_work = if (oneIn(r, 4)) r.intRangeAtMost(u32, 1, 40) else 1_000_000,
        };
    }

    fn check(
        c: *PushChecker,
        arena: Allocator,
        q: *GitSim,
        updates: []const GitSim.Received,
        honest: bool,
    ) CaseError!void {
        const engine_policy = try c.policyOf(arena);
        const permissive = engine_policy.allow_numbers and engine_policy.allow_purge and
            engine_policy.author_policy == .any;
        const ups = try arena.alloc(issuez.push_check.Update, updates.len);
        const oups = try arena.alloc(oracle.push_check.Update, updates.len);
        for (updates, ups, oups) |u, *e, *o| {
            e.* = .{ .ref = u.name, .old = u.old, .new = u.new };
            o.* = .{
                .ref = u.name,
                .old = if (u.old) |x| try x.hexAlloc(arena) else null,
                .new = if (u.new) |x| try x.hexAlloc(arena) else null,
            };
        }
        const repo = issuez.Repo(GitSim).init(q);
        const got = issuez.PushCheck(GitSim).fromRepo(repo).check(
            arena,
            ups,
            engine_policy,
        ) catch |e| {
            std.debug.print("  push check failed: {t}\n", .{e});
            return error.ModelMismatch;
        };

        const view = try hubView(arena, q);
        const want = oracle.push_check.expect(view, oups, .{
            .pusher_emails = engine_policy.pusher_emails,
            .pusher_ids = engine_policy.pusher_ids,
            .authors = @enumFromInt(@intFromEnum(engine_policy.author_policy)),
            .allow_numbers = engine_policy.allow_numbers,
            .allow_purge = engine_policy.allow_purge,
            .max_merge_work = engine_policy.max_merge_work,
        }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoRule => return countSkip("push check of a history the oracle can't read"),
        };

        for (got, want) |g, w| {
            if (!w.skip) try compareVerdict(arena, g, w, honest and permissive);
        }
    }

    /// The hub as the oracle reads it.
    fn hubView(arena: Allocator, q: *GitSim) Allocator.Error!commands.Clone {
        var refs: std.ArrayList(World.Ref) = .empty;
        for (q.refs.keys(), q.refs.values()) |name, oid| try refs.append(
            arena,
            .{ .name = name, .oid = try oid.hexAlloc(arena) },
        );
        var objects: std.ArrayList(World.StoredObject) = .empty;
        var it = q.objects.valueIterator();
        while (it.next()) |o| try objects.append(arena, o.*);
        return commands.Clone.init(arena, q.world.format, .{
            .name = "hub",
            .refs = refs.items,
            .objects = objects.items,
        });
    }

    /// `must_pass`: an honest push under a permissive policy.
    fn compareVerdict(
        arena: Allocator,
        g: issuez.push_check.Verdict,
        w: oracle.push_check.Expect,
        must_pass: bool,
    ) CaseError!void {
        var kinds: std.ArrayList([]const u8) = .empty;
        var flags: std.ArrayList([]const u8) = .empty;
        var at: std.ArrayList([]const u8) = .empty;
        for (g.problems) |p| {
            const name = @tagName(p.kind);
            const per_commit = switch (p.kind) {
                .not_derived, .not_a_purge, .author_mismatch, .number_set => true,
                else => false,
            };
            if (per_commit) if (p.commit) |cm| {
                const tag = try std.fmt.allocPrint(arena, "{s}@{f}", .{ name, cm });
                if (!commands.containsText(at.items, tag)) try at.append(arena, tag);
            };
            if (!p.rejects and !commands.containsText(flags.items, name))
                try flags.append(arena, name);
            if (!commands.containsText(kinds.items, name)) try kinds.append(arena, name);
        }
        stableSort([]const u8, kinds.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        const same = std.mem.eql(u8, @tagName(g.action), w.action) and
            g.accept == w.accept and
            commands.sameSet(kinds.items, w.kinds) and
            commands.sameSet(flags.items, w.flags) and
            commands.sameSet(at.items, w.at) and
            g.needs_number == w.needs_number and
            g.touches_locked == w.touches_locked and
            (w.new_count == null or w.new_count.? == g.new_commits.len);
        if (!same) {
            std.debug.print(
                "  push check of {s} ({s} -> {s}) disagrees:\n" ++
                    "    engine: {t} accept={} {s} flags {s} number={} locked={} new={d}\n" ++
                    "    oracle: {s} accept={} {s} flags {s} number={} locked={} new={?d}\n",
                .{
                    g.update.ref,
                    if (g.update.old) |x| x.hex().slice()[0..8] else "-",
                    if (g.update.new) |x| x.hex().slice()[0..8] else "-",
                    g.action,
                    g.accept,
                    try std.mem.join(arena, ",", kinds.items),
                    try std.mem.join(arena, ",", flags.items),
                    g.needs_number,
                    g.touches_locked,
                    g.new_commits.len,
                    w.action,
                    w.accept,
                    try std.mem.join(arena, ",", w.kinds),
                    try std.mem.join(arena, ",", w.flags),
                    w.needs_number,
                    w.touches_locked,
                    w.new_count,
                },
            );
            return error.ModelMismatch;
        }
        countOutcome(if (g.accept) "(push check accepts)" else "(push check refuses)", true);
        if (g.touches_locked) countOutcome("(push check: touches locked)", true);
        if (g.gives_number) countOutcome("(push check: gives a number)", true);
        if (g.kind == .tombstone and g.accept) countOutcome("(push check: tombstone in)", true);
        // The stats keep their keys: static names only.
        inline for (std.meta.fields(issuez.push_check.ProblemKind)) |f| {
            if (commands.containsText(kinds.items, f.name))
                countOutcome("(push check: " ++ f.name ++ ")", true);
        }
        if (must_pass and !g.accept) {
            const only_numbers = for (g.problems) |p| {
                if (p.rejects and p.kind != .number_taken) break false;
            } else true;
            if (!only_numbers) {
                std.debug.print("  an honest push of {s} was refused: {s}\n", .{
                    g.update.ref,
                    try std.mem.join(arena, ",", kinds.items),
                });
                return error.ModelMismatch;
            }
        }
    }
};

var push_checker: ?*PushChecker = null;

/// Host UUIDs forged commits claim and policies give the pusher.
const author_ids = [_][]const u8{
    "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d",
    "1d9e8b63-4a2f-4c7b-8e3d-6f5a4b3c2d1e",
};

/// A push that never happens: the clone's refs and some mischief (deletes,
/// rewinds, local-only and misnamed refs) checked against the hub.
fn pushCheckStep(
    arena: Allocator,
    rand: std.Random,
    world: *World,
    clone_index: usize,
    hub_index: usize,
) CaseError!void {
    const checker = push_checker orelse return;
    var q = try GitSim.init(arena, world, hub_index);
    const clone = world.clones[clone_index];
    for (clone.objects) |o|
        try q.objects.put(arena, object.hashObject(world.format, o.kind, o.data), o);
    var updates: std.ArrayList(GitSim.Received) = .empty;
    for (clone.refs) |r| {
        if (!isSynced(r.name)) continue;
        const new = Oid.parseHex(world.format, r.oid) catch continue;
        const old = q.refs.get(r.name);
        if (old != null and old.?.eql(new)) continue;
        if (oneIn(rand, 4)) continue;
        try updates.append(arena, .{ .name = r.name, .old = old, .new = new });
    }
    const hub_refs = q.refs.keys();
    if (hub_refs.len > 0 and oneIn(rand, 3)) {
        const name = pick(rand, hub_refs);
        const tip = q.refs.get(name).?;
        const rewind: ?Oid = if (rand.boolean()) blk: {
            const o = (try q.readObject(arena, tip)) orelse break :blk null;
            const c = object.Commit.parse(arena, world.format, o.data) catch break :blk null;
            break :blk if (c.parents.len > 0) c.parents[0] else null;
        } else null;
        if (!containsName(updates.items, name)) try updates.append(arena, .{
            .name = name,
            .old = tip,
            .new = rewind,
        });
    }
    if (oneIn(rand, 6)) if (updates.items.len > 0) {
        const junk = [_][]const u8{
            "refs/issuez-guard/0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c",
            "refs/issues/not-a-uuid",
            "refs/heads/main",
        };
        const name = pick(rand, &junk);
        if (!containsName(updates.items, name) and q.refs.get(name) == null)
            try updates.append(arena, .{ .name = name, .old = null, .new = updates.items[0].new });
    };
    if (rand.boolean()) try forge(arena, rand, world, clone, &q, &updates);
    if (updates.items.len == 0) return;
    countOutcome("(push check step)", true);
    try checker.check(arena, &q, updates.items, false);
}

/// What `forge` writes with.
const Forger = struct {
    arena: Allocator,
    q: *GitSim,
    updates: *std.ArrayList(GitSim.Received),
    sig: object.Signature,

    /// A commit by the world's identity.
    fn commit(f: Forger, tree: Oid, parents: []const Oid, message: []const u8) CaseError!Oid {
        const c: object.Commit = .{
            .tree = tree,
            .parents = parents,
            .author = f.sig,
            .committer = f.sig,
            .message = message,
        };
        return f.q.writeObject(.commit, try c.serializeAlloc(f.arena));
    }

    /// The push's update of `name` now goes to `oid`. False when it had one
    /// already.
    fn update(f: Forger, name: []const u8, oid: Oid) Allocator.Error!bool {
        for (f.updates.items) |*u| if (std.mem.eql(u8, u.name, name)) {
            u.new = oid;
            return false;
        };
        try f.updates.append(f.arena, .{ .name = name, .old = f.q.refs.get(name), .new = oid });
        return true;
    }
};

/// Commits no tool of ours writes: numbers, files, a format from the
/// future, tombstones good and bad.
fn forge(
    arena: Allocator,
    rand: std.Random,
    world: *World,
    clone: World.Clone,
    q: *GitSim,
    updates: *std.ArrayList(GitSim.Received),
) CaseError!void {
    const f: Forger = .{ .arena = arena, .q = q, .updates = updates, .sig = .{
        .name = world.identity.name,
        .email = world.identity.email,
        .time = world.clock.now,
        .tz_offset_minutes = 0,
    } };
    var issues: std.ArrayList(World.Ref) = .empty;
    for (clone.refs) |r| if (std.mem.startsWith(u8, r.name, "refs/issues/")) {
        try issues.append(arena, r);
    };
    const empty = object.emptyTree(world.format);
    const kind = rand.uintLessThan(u8, 9);
    if (kind == 2 or issues.items.len == 0) {
        countOutcome("(push check forged: new format)", true);
        const oid = try f.commit(empty, &.{}, try std.fmt.allocPrint(
            arena,
            "Forged\n\nState: open\nFormat-Version: {d}\n",
            .{rand.intRangeAtMost(u8, 1, 2)},
        ));
        const name = try issueRef(arena, try randomUuid(arena, rand));
        return updates.append(arena, .{ .name = name, .old = null, .new = oid });
    }
    const target = issues.items[rand.uintLessThan(usize, issues.items.len)];
    const tip = Oid.parseHex(world.format, target.oid) catch return;
    switch (kind) {
        4 => return forgeDerived(f, rand, clone, target, tip),
        8 => {
            // A comment by a host user, maybe not the pusher, maybe no
            // UUID at all.
            countOutcome("(push check forged: author id)", true);
            const ids = author_ids ++ [_][]const u8{ "0C8D7A52-3F1E-4B6A-9D2C-5E4F3A2B1C0D", "x" };
            const message = try std.fmt.allocPrint(arena, "Hello\n\nX-Author-Id: {s}\n", .{
                pick(rand, &ids),
            });
            _ = try f.update(target.name, try f.commit(empty, &.{tip}, message));
        },
        7 => {
            // A comment that claims to be a rewrite of a commit still in
            // the history, of what another commit was, or of nothing here.
            countOutcome("(push check forged: rewritten from)", true);
            const tip_obj = (try q.readObject(arena, tip)) orelse return;
            const tip_commit = object.Commit.parse(arena, world.format, tip_obj.data) catch return;
            const claimed: []const u8 = switch (rand.uintLessThan(u8, 3)) {
                0 => try tip.hexAlloc(arena),
                1 => if (std.mem.find(u8, tip_commit.message, "X-Rewritten-From: ")) |at|
                    std.mem.sliceTo(tip_commit.message[at + "X-Rewritten-From: ".len ..], '\n')
                else
                    try tip.hexAlloc(arena),
                else => try object.hashObject(world.format, .blob, "elsewhere").hexAlloc(arena),
            };
            const message = try std.fmt.allocPrint(
                arena,
                "Spam\n\nX-Rewritten-From: {s}\n",
                .{claimed},
            );
            _ = try f.update(target.name, try f.commit(empty, &.{tip}, message));
        },
        6 => {
            // An issue's history under another UUID: purged text must not
            // come back that way.
            countOutcome("(push check forged: copy)", true);
            const name = try issueRef(arena, try randomUuid(arena, rand));
            const copied = (try purgedOnHub(arena, rand, q)) orelse tip;
            return updates.append(arena, .{ .name = name, .old = null, .new = copied });
        },
        5 => {
            // Two issues given one number in one push.
            countOutcome("(push check forged: numbers)", true);
            const n = rand.intRangeAtMost(u8, 1, 3);
            for (0..2) |_| {
                const t = issues.items[rand.uintLessThan(usize, issues.items.len)];
                if (containsName(updates.items, t.name)) continue;
                const parent = Oid.parseHex(world.format, t.oid) catch continue;
                const message = try std.fmt.allocPrint(arena, "Number\n\nX-Number: {d}\n", .{n});
                const oid = try f.commit(empty, &.{parent}, message);
                _ = try f.update(t.name, oid);
            }
        },
        0, 1 => {
            const tree = if (kind == 1) blk: {
                countOutcome("(push check forged: files)", true);
                const blob = try q.writeObject(.blob, "not an issue\n");
                break :blk try q.writeObject(
                    .tree,
                    try object.Tree.serializeAlloc(arena, &.{.{ .name = "x", .oid = blob }}),
                );
            } else empty;
            if (kind == 0) countOutcome("(push check forged: number)", true);
            const oid = try f.commit(tree, &.{tip}, try std.fmt.allocPrint(
                arena,
                "Number\n\nX-Number: {d}\n",
                .{rand.intRangeAtMost(u8, 1, 3)},
            ));
            _ = try f.update(target.name, oid);
        },
        else => return forgeTombstone(f, rand, target, tip),
    }
}

/// A commit some tombstone on the hub purged, if the hub still has one.
fn purgedOnHub(arena: Allocator, rand: std.Random, q: *GitSim) Allocator.Error!?Oid {
    var found: std.ArrayList(Oid) = .empty;
    for (q.refs.keys(), q.refs.values()) |name, oid| {
        if (!std.mem.startsWith(u8, name, "refs/issuez-purged/")) continue;
        const t = issuez.purge.readAt(arena, q, oid) catch continue;
        for ([_][]const Oid{ t.comments, t.roots }) |list| for (list) |x| {
            if (q.objects.contains(x)) try found.append(arena, x);
        };
    }
    if (found.items.len == 0) return null;
    return found.items[rand.uintLessThan(usize, found.items.len)];
}

/// A commit under the derived tip: pointers or not.
fn forgeDerived(
    f: Forger,
    rand: std.Random,
    clone: World.Clone,
    target: World.Ref,
    tip: Oid,
) CaseError!void {
    const arena = f.arena;
    const format = f.q.objectFormat();
    const id = target.name["refs/issues/".len..];
    const name = try std.fmt.allocPrint(arena, "refs/attachments/{s}", .{id});
    const hex = for (clone.refs) |r| {
        if (std.mem.eql(u8, r.name, name)) break r.oid;
    } else return;
    const d_oid = Oid.parseHex(format, hex) catch return;
    const d_obj = (try f.q.readObject(arena, d_oid)) orelse return;
    const d = object.Commit.parse(arena, format, d_obj.data) catch return;
    countOutcome("(push check forged: derived history)", true);
    const junk_tree = if (oneIn(rand, 3)) d.tree else blk: {
        const blob = try f.q.writeObject(.blob, "not a pointer\n");
        break :blk try f.q.writeObject(.tree, try object.Tree.serializeAlloc(arena, &.{.{
            .name = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c.png",
            .oid = blob,
        }}));
    };
    var under = d;
    under.tree = junk_tree;
    // This issue's derived message, a bare subject, or the issue's own tip.
    const choice = rand.uintLessThan(u8, 3);
    if (choice == 1) under.message = "Regenerate attachments\n";
    const j = if (choice == 2)
        tip
    else
        try f.q.writeObject(.commit, try under.serializeAlloc(arena));
    var top = d;
    top.parents = try arena.dupe(Oid, &.{j});
    const oid = try f.q.writeObject(.commit, try top.serializeAlloc(arena));
    if (!try f.update(name, oid)) return;
    if (!containsName(f.updates.items, target.name)) {
        const old = f.q.refs.get(target.name);
        if (old == null or !old.?.eql(tip))
            try f.updates.append(arena, .{ .name = target.name, .old = old, .new = tip });
    }
}

/// A tombstone good or bad, or one going away.
fn forgeTombstone(f: Forger, rand: std.Random, target: World.Ref, tip: Oid) CaseError!void {
    const arena = f.arena;
    countOutcome("(push check forged: tombstone)", true);
    const id = target.name["refs/issues/".len..];
    const tomb_name = try std.fmt.allocPrint(arena, "refs/issuez-purged/{s}", .{id});
    const old = f.q.refs.get(tomb_name);
    const messages = [_][]const u8{
        "Purge issue\n\nX-Purge: issue\n",
        "Junk\n\nX-Purge: maybe\n",
        try std.fmt.allocPrint(
            arena,
            "Purge comment\n\nX-Purge: comment\nX-Purged-Commit: {f}\n",
            .{tip},
        ),
        "Purge comment\n\nX-Purge: comment\nX-Purged-Commit: abc\n",
    };
    const oid = try f.commit(
        object.emptyTree(f.q.objectFormat()),
        if (old) |o| try arena.dupe(Oid, &.{o}) else &.{},
        pick(rand, &messages),
    );
    if (containsName(f.updates.items, tomb_name)) return;
    // Or the tombstone goes.
    const new: ?Oid = if (old != null and oneIn(rand, 4)) null else oid;
    try f.updates.append(arena, .{ .name = tomb_name, .old = old, .new = new });
    // The issue goes with it, now and then.
    if (f.q.refs.get(target.name)) |hub_tip| if (rand.boolean() and
        !containsName(f.updates.items, target.name))
        try f.updates.append(arena, .{ .name = target.name, .old = hub_tip, .new = null });
}

fn randomUuid(arena: Allocator, rand: std.Random) Allocator.Error![]const u8 {
    var b: [16]u8 = undefined;
    rand.bytes(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const h = std.fmt.bytesToHex(b, .lower);
    return std.fmt.allocPrint(arena, "{s}-{s}-{s}-{s}-{s}", .{
        h[0..8], h[8..12], h[12..16], h[16..20], h[20..32],
    });
}

fn containsName(list: []const GitSim.Received, name: []const u8) bool {
    for (list) |u| if (std.mem.eql(u8, u.name, name)) return true;
    return false;
}

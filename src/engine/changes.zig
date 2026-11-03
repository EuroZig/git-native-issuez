//! What changed in a repository's issues between two reads of its refs,
//! for a long-running front end that others write under: a TUI, a GUI,
//! the MCP server. Reading the refs is one `listRefs` per namespace, much
//! cheaper than loading the issues, so a front end told that something
//! may have changed (by a file watcher, a timer, the focus coming back)
//! checks `RefState` first and reloads only what moved.
//!
//!     const before = try RefState.read(arena, backend);
//!     // ... someone writes ...
//!     const after = try RefState.read(arena, backend);
//!     const d = try diff(arena, before, after);
//!     for (d.issues) |id| ... // created, changed or deleted
//!
//! Every write moves the issue's ref, so a changed issue always shows.
//! Settings live in git config, not in refs: reread those separately.

const std = @import("std");
const Allocator = std.mem.Allocator;
const contract = @import("../backend/contract.zig");
const repo_mod = @import("repo.zig");

const RefEntry = contract.RefEntry;

/// The namespaces whose refs make up what an issue shows, in name order.
pub const namespaces = [_][]const u8{
    repo_mod.attachment_ref_prefix,
    repo_mod.issue_ref_prefix,
    repo_mod.milestone_ref_prefix,
};

comptime {
    for (namespaces[0 .. namespaces.len - 1], namespaces[1..]) |a, b|
        std.debug.assert(std.mem.order(u8, a, b) == .lt);
}

pub const RefState = struct {
    /// Every ref in `namespaces`, sorted by name.
    refs: []const RefEntry = &.{},

    pub fn read(arena: Allocator, backend: anytype) !RefState {
        var all: std.ArrayList(RefEntry) = .empty;
        // Each listing is sorted and the namespaces are in order.
        for (namespaces) |prefix| try all.appendSlice(arena, try backend.listRefs(arena, prefix));
        return .{ .refs = all.items };
    }

    pub fn eql(a: RefState, b: RefState) bool {
        if (a.refs.len != b.refs.len) return false;
        for (a.refs, b.refs) |x, y| {
            if (!std.mem.eql(u8, x.name, y.name) or !x.oid.eql(y.oid)) return false;
        }
        return true;
    }

    /// A copy that owns its names, for keeping across reads.
    pub fn clone(s: RefState, gpa: Allocator) Allocator.Error!RefState {
        const refs = try gpa.alloc(RefEntry, s.refs.len);
        var done: usize = 0;
        errdefer {
            for (refs[0..done]) |r| gpa.free(r.name);
            gpa.free(refs);
        }
        for (s.refs, refs) |r, *o| {
            o.* = .{ .name = try gpa.dupe(u8, r.name), .oid = r.oid };
            done += 1;
        }
        return .{ .refs = refs };
    }

    /// Of a `clone`.
    pub fn deinit(s: *RefState, gpa: Allocator) void {
        for (s.refs) |r| gpa.free(r.name);
        gpa.free(s.refs);
        s.* = .{};
    }
};

pub const Diff = struct {
    /// IDs of the issues created, changed or deleted, their attachments
    /// included, sorted and once each.
    issues: []const []const u8 = &.{},
    /// Some milestone was created, changed or deleted. Milestones change
    /// what their issues show (names, progress), so a front end showing
    /// them reloads them all.
    milestones: bool = false,

    pub fn empty(d: Diff) bool {
        return d.issues.len == 0 and !d.milestones;
    }

    pub fn hasIssue(d: Diff, id: []const u8) bool {
        for (d.issues) |i| if (std.mem.eql(u8, i, id)) return true;
        return false;
    }
};

/// What moved from `old` to `new`. The IDs point into the states' names.
pub fn diff(arena: Allocator, old: RefState, new: RefState) Allocator.Error!Diff {
    var out: Diff = .{};
    var ids: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < old.refs.len or j < new.refs.len) {
        const changed: []const u8 = blk: {
            if (i == old.refs.len) {
                j += 1;
                break :blk new.refs[j - 1].name;
            }
            if (j == new.refs.len) {
                i += 1;
                break :blk old.refs[i - 1].name;
            }
            const a = old.refs[i];
            const b = new.refs[j];
            switch (std.mem.order(u8, a.name, b.name)) {
                .lt => {
                    i += 1;
                    break :blk a.name;
                },
                .gt => {
                    j += 1;
                    break :blk b.name;
                },
                .eq => {
                    i += 1;
                    j += 1;
                    if (a.oid.eql(b.oid)) continue;
                    break :blk a.name;
                },
            }
        };
        if (std.mem.startsWith(u8, changed, repo_mod.milestone_ref_prefix)) {
            out.milestones = true;
        } else if (issueOf(changed)) |id| {
            try ids.append(arena, id);
        }
    }
    std.mem.sortUnstable([]const u8, ids.items, {}, lessThan);
    var unique: usize = 0;
    for (ids.items) |id| {
        if (unique > 0 and std.mem.eql(u8, ids.items[unique - 1], id)) continue;
        ids.items[unique] = id;
        unique += 1;
    }
    out.issues = ids.items[0..unique];
    return out;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The issue an issue or attachment ref belongs to.
fn issueOf(name: []const u8) ?[]const u8 {
    for ([_][]const u8{ repo_mod.issue_ref_prefix, repo_mod.attachment_ref_prefix }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return name[prefix.len..];
    }
    return null;
}

const testing = std.testing;
const GitSim = @import("../backend/GitSim.zig");

test "changes between two reads" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .clones = &.{.{ .name = "local" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const r = repo_mod.Repo(GitSim).init(&sim);

    const empty = try RefState.read(arena, &sim);
    const a = try r.create(arena, .{ .title = "A" });
    const b = try r.create(arena, .{ .title = "B" });
    const two = try RefState.read(arena, &sim);
    try testing.expect(!two.eql(empty));
    try testing.expect(two.eql(try RefState.read(arena, &sim)));
    try testing.expect((try diff(arena, two, two)).empty());

    const created = try diff(arena, empty, two);
    try testing.expectEqual(@as(usize, 2), created.issues.len);
    try testing.expect(created.hasIssue(a.id.slice()) and created.hasIssue(b.id.slice()));
    try testing.expect(!created.milestones);

    const a_ref = try std.fmt.allocPrint(arena, "{s}{s}", .{ repo_mod.issue_ref_prefix, a.id.slice() });
    _ = try r.comment(arena, a_ref, .{ .text = "Hello" });
    var kept = try two.clone(testing.allocator);
    defer kept.deinit(testing.allocator);
    const commented = try diff(arena, kept, try RefState.read(arena, &sim));
    try testing.expectEqual(@as(usize, 1), commented.issues.len);
    try testing.expectEqualStrings(a.id.slice(), commented.issues[0]);

    // Deleted ones show too.
    const deleted = try diff(arena, two, empty);
    try testing.expectEqual(@as(usize, 2), deleted.issues.len);
}

test "an attachment ref counts as its issue; milestones as a whole" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const Oid = @import("../backend/object.zig").Oid;
    const x: Oid = .{ .object_format = .sha1, .bytes = @splat(1) };
    const y: Oid = .{ .object_format = .sha1, .bytes = @splat(2) };
    const old: RefState = .{ .refs = &.{
        .{ .name = "refs/attachments/i1", .oid = x },
        .{ .name = "refs/issues/i1", .oid = x },
        .{ .name = "refs/issues/i2", .oid = x },
        .{ .name = "refs/milestones/m1", .oid = x },
    } };
    const new: RefState = .{ .refs = &.{
        .{ .name = "refs/attachments/i1", .oid = y },
        .{ .name = "refs/issues/i1", .oid = y },
        .{ .name = "refs/issues/i2", .oid = x },
        .{ .name = "refs/milestones/m1", .oid = y },
    } };
    const d = try diff(arena_state.allocator(), old, new);
    try testing.expectEqual(@as(usize, 1), d.issues.len);
    try testing.expectEqualStrings("i1", d.issues[0]);
    try testing.expect(d.milestones);
}

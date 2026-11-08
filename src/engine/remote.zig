//! Setting a remote up for issues (`git issue init`): fetch refspecs that
//! bring its issues, milestones and attachment refs into
//! `refs/remotes/<remote>/`, where a merge takes them from, instead of
//! upstream's forced direct refspec that can drop unpushed issue commits.

const std = @import("std");
const Allocator = std.mem.Allocator;
const contract = @import("../backend/contract.zig");

/// Upstream's refspec. Forced and direct, so fetching can drop unpushed
/// issue commits.
pub const unsafe_refspec = "+refs/issues/*:refs/issues/*";

/// Where a fetch from `remote` puts its issues: what a merge takes them from.
fn stagingRefspec(arena: Allocator, remote: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "+refs/issues/*:refs/remotes/{s}/issues/*", .{remote});
}

fn milestoneRefspec(arena: Allocator, remote: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "+refs/milestones/*:refs/remotes/{s}/milestones/*", .{remote});
}

fn attachmentRefspec(arena: Allocator, remote: []const u8) Allocator.Error![]const u8 {
    const spec = "+refs/attachments/*:refs/remotes/{s}/attachments/*";
    return std.fmt.allocPrint(arena, spec, .{remote});
}

/// The remote to set up when none is named: the only one, else `origin`.
pub const Default = union(enum) {
    none,
    one: []const u8,
    /// Several and none is `origin`: the caller asks which.
    many: []const []const u8,
};

pub fn default(comptime B: type, arena: Allocator, backend: *B) B.Error!Default {
    const remotes = try backend.remoteNames(arena);
    return switch (remotes.len) {
        0 => .none,
        1 => .{ .one = remotes[0] },
        else => for (remotes) |r| {
            if (std.mem.eql(u8, r, "origin")) break .{ .one = r };
        } else .{ .many = remotes },
    };
}

pub const Options = struct {
    /// Remove upstream's unsafe refspec if the remote has it.
    fix_unsafe: bool = false,
};

/// What `configure` found and did.
pub const Setup = struct {
    /// The staging refspec was added now; false when it was there.
    configured: bool,
    /// Upstream's unsafe refspec was taken out (with `fix_unsafe`).
    removed_unsafe: bool = false,
    /// The remote still has upstream's unsafe refspec: a plain fetch can
    /// overwrite local issue refs.
    unsafe: bool = false,
};

/// Adds the fetch refspecs for issues, milestones and attachment refs to
/// `remote`, those it lacks. Idempotent.
pub fn configure(
    comptime B: type,
    arena: Allocator,
    backend: *B,
    remote: []const u8,
    options: Options,
) (B.Error || error{ NoSuchRemote, InvalidRemoteName })!Setup {
    if (!contract.isValidRemoteName(remote)) return error.InvalidRemoteName;
    const exists = for (try backend.remoteNames(arena)) |r| {
        if (std.mem.eql(u8, r, remote)) break true;
    } else false;
    if (!exists) return error.NoSuchRemote;
    const key = try std.fmt.allocPrint(arena, "remote.{s}.fetch", .{remote});
    const staging = try stagingRefspec(arena, remote);
    const milestones = try milestoneRefspec(arena, remote);
    const attachments = try attachmentRefspec(arena, remote);
    var has_staging = false;
    var has_milestones = false;
    var has_attachments = false;
    var has_unsafe = false;
    for (try backend.configGetAll(arena, key)) |spec| {
        if (std.mem.eql(u8, spec, staging)) has_staging = true;
        if (std.mem.eql(u8, spec, milestones)) has_milestones = true;
        if (std.mem.eql(u8, spec, attachments)) has_attachments = true;
        const forced = std.mem.trimStart(u8, spec, "+");
        if (std.mem.eql(u8, forced, unsafe_refspec[1..])) has_unsafe = true;
    }
    var out: Setup = .{ .configured = !has_staging };
    if (has_unsafe and options.fix_unsafe) {
        try backend.configUnsetValue(key, unsafe_refspec);
        try backend.configUnsetValue(key, unsafe_refspec[1..]);
        has_unsafe = false;
        out.removed_unsafe = true;
    }
    if (!has_milestones) try backend.configAdd(key, milestones);
    if (!has_attachments) try backend.configAdd(key, attachments);
    if (!has_staging) try backend.configAdd(key, staging);
    out.unsafe = has_unsafe;
    return out;
}

const testing = std.testing;

test "configure: the refspecs once, the unsafe one on request" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const GitSim = @import("../backend/GitSim.zig");
    var world: GitSim.World = .{ .seed = 73, .clones = &.{.{ .name = "a", .config = &.{
        .{ .key = "remote.origin.url", .value = "sim:hub" },
        .{ .key = "remote.origin.fetch", .value = unsafe_refspec },
    } }} };
    var sim = try GitSim.init(arena, &world, 0);
    try testing.expectEqualStrings("origin", (try default(GitSim, arena, &sim)).one);
    const first = try configure(GitSim, arena, &sim, "origin", .{});
    try testing.expect(first.configured and first.unsafe and !first.removed_unsafe);
    const again = try configure(GitSim, arena, &sim, "origin", .{ .fix_unsafe = true });
    try testing.expect(!again.configured and again.removed_unsafe and !again.unsafe);
    try testing.expectEqual(
        @as(usize, 3),
        (try sim.configGetAll(arena, "remote.origin.fetch")).len,
    );
    try testing.expectError(error.NoSuchRemote, configure(GitSim, arena, &sim, "upstream", .{}));
    try testing.expectError(error.InvalidRemoteName, configure(GitSim, arena, &sim, "a b", .{}));
}

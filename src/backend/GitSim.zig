//! In-memory backend: a world of clones, serialised as ZON.
//!
//! Objects hash like they do in git, so OIDs match `GitProcess`. Time and
//! randomness come from the world, so runs are deterministic. Breaking a
//! protocol rule (a commit pointing at missing objects, an invalid ref
//! name) is a bug in the caller and panics.

const GitSim = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const contract = @import("contract.zig");
const object = @import("object.zig");
const hex_fmt = @import("../format/hex.zig");
const Oid = object.Oid;
const ObjectFormat = object.ObjectFormat;
const ObjectKind = object.ObjectKind;
const Signature = object.Signature;

/// Objects are stored as kind and data only, so a world can't contain an
/// object with the wrong OID.
pub const World = struct {
    format: ObjectFormat = .sha1,
    /// Advanced by every run.
    seed: u64 = 0,
    clock: Clock = .{},
    identity: Identity = .{},
    clones: []const Clone,
    /// The files commands can read, e.g. for `attach add`.
    files: []const File = &.{},

    pub const File = struct { path: []const u8, data: []const u8 };

    pub const Clock = struct {
        /// Returned by the next `identity()` call.
        now: i64 = 1_700_000_000,
        tz_offset_minutes: i16 = 0,
        /// Added after every `identity()` call, so commits get increasing
        /// timestamps.
        step_seconds: u32 = 60,
    };

    pub const Identity = struct {
        name: []const u8 = "Sim User",
        email: []const u8 = "sim@example.invalid",
    };

    pub const Clone = struct {
        name: []const u8,
        config: []const ConfigEntry = &.{},
        refs: []const Ref = &.{},
        objects: []const StoredObject = &.{},
        lfs: []const LfsObject = &.{},
    };

    pub const LfsObject = struct {
        store: contract.LfsStore,
        sha256: []const u8,
        data: []const u8,
    };

    pub const ConfigEntry = struct { key: []const u8, value: []const u8 };
    pub const Ref = struct { name: []const u8, oid: []const u8 };
    pub const StoredObject = struct { kind: ObjectKind, data: []const u8 };

    pub const ParseError = error{ OutOfMemory, ParseZon };

    pub fn parse(
        arena: Allocator,
        source: [:0]const u8,
        diag: ?*std.zon.parse.Diagnostics,
    ) ParseError!World {
        return std.zon.parse.fromSliceAlloc(World, arena, source, diag, .{});
    }

    pub fn write(world: World, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try std.zon.stringify.serialize(world, .{}, w);
        try w.writeAll("\n");
    }

    pub fn cloneIndex(world: World, name: []const u8) ?usize {
        for (world.clones, 0..) |c, i| if (std.mem.eql(u8, c.name, name)) return i;
        return null;
    }
};

const ObjectMap = std.HashMapUnmanaged(
    Oid,
    World.StoredObject,
    OidContext,
    std.hash_map.default_max_load_percentage,
);

const OidContext = struct {
    pub fn hash(_: OidContext, oid: Oid) u64 {
        return std.mem.readInt(u64, oid.bytes[0..8], .little);
    }
    pub fn eql(_: OidContext, a: Oid, b: Oid) bool {
        return a.eql(b);
    }
};

arena: Allocator,
world: *World,
clone_index: usize,
objects: ObjectMap,
refs: std.array_hash_map.String(Oid),
config: std.ArrayList(World.ConfigEntry),
lfs: std.ArrayList(World.LfsObject),
prng: std.Random.DefaultPrng,

pub const Error = error{OutOfMemory};

/// Call `commit` to write the changes back into `world`.
pub fn init(arena: Allocator, world: *World, clone_index: usize) Error!GitSim {
    assert(clone_index < world.clones.len);
    const clone = world.clones[clone_index];
    var sim: GitSim = .{
        .arena = arena,
        .world = world,
        .clone_index = clone_index,
        .objects = .empty,
        .refs = .empty,
        .config = .empty,
        .lfs = .empty,
        .prng = .init(world.seed),
    };
    try sim.config.appendSlice(arena, clone.config);
    try sim.lfs.appendSlice(arena, clone.lfs);
    for (clone.objects) |o| {
        const oid = object.hashObject(world.format, o.kind, o.data);
        try sim.objects.put(arena, oid, o);
    }
    for (clone.refs) |r| {
        if (!contract.isValidRefName(r.name)) protocolViolation(
            "world has invalid ref name '{s}'",
            .{r.name},
        );
        const oid = Oid.parseHex(world.format, r.oid) catch
            protocolViolation("world ref '{s}' has invalid oid '{s}'", .{ r.name, r.oid });
        if (!sim.objects.contains(oid)) protocolViolation(
            "world ref '{s}' points at missing object {f}",
            .{ r.name, oid },
        );
        try sim.refs.put(arena, r.name, oid);
    }
    return sim;
}

/// Sorted, so worlds diff cleanly.
pub fn commit(sim: *GitSim) Error!void {
    const format = sim.world.format;

    const objs = try sim.arena.alloc(World.StoredObject, sim.objects.count());
    const oids = try sim.arena.alloc(Oid, sim.objects.count());
    var it = sim.objects.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) oids[i] = e.key_ptr.*;
    std.mem.sort(Oid, oids, {}, oidLessThan);
    for (oids, objs) |oid, *o| o.* = sim.objects.get(oid).?;

    const names = try sim.arena.dupe([]const u8, sim.refs.keys());
    std.mem.sort([]const u8, names, {}, stringLessThan);
    const refs = try sim.arena.alloc(World.Ref, names.len);
    for (names, refs) |name, *r| {
        const hex = sim.refs.get(name).?.hex();
        r.* = .{ .name = name, .oid = try sim.arena.dupe(u8, hex.slice()) };
    }

    const clones = try sim.arena.dupe(World.Clone, sim.world.clones);
    clones[sim.clone_index].objects = objs;
    clones[sim.clone_index].refs = refs;
    clones[sim.clone_index].config = sim.config.items;
    std.mem.sort(World.LfsObject, sim.lfs.items, {}, lfsLessThan);
    clones[sim.clone_index].lfs = sim.lfs.items;
    sim.world.clones = clones;
    sim.world.seed = sim.prng.next();
    _ = format;
}

pub fn objectFormat(sim: *const GitSim) ObjectFormat {
    return sim.world.format;
}

pub fn readObject(sim: *GitSim, arena: Allocator, oid: Oid) Error!?contract.Object {
    _ = arena;
    assert(oid.object_format == sim.world.format);
    const o = sim.objects.get(oid) orelse return null;
    return .{ .kind = o.kind, .data = o.data };
}

pub fn writeObject(sim: *GitSim, kind: ObjectKind, data: []const u8) Error!Oid {
    const format = sim.world.format;
    if (kind == .commit) {
        const c = object.Commit.parse(sim.arena, format, data) catch
            protocolViolation("wrote a commit object that does not decode", .{});
        if (!c.tree.eql(object.emptyTree(format)) and !sim.objects.contains(c.tree))
            protocolViolation("commit references missing tree {f}", .{c.tree});
        for (c.parents) |p| if (!sim.objects.contains(p))
            protocolViolation("commit references missing parent {f}", .{p});
    }
    const oid = object.hashObject(format, kind, data);
    const gop = try sim.objects.getOrPut(sim.arena, oid);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .kind = kind, .data = try sim.arena.dupe(u8, data) };
    }
    return oid;
}

pub fn resolveRef(sim: *GitSim, name: []const u8) Error!?Oid {
    if (!contract.isValidRefName(name)) protocolViolation("invalid ref name '{s}'", .{name});
    return sim.refs.get(name);
}

pub fn listRefs(sim: *GitSim, arena: Allocator, prefix: []const u8) Error![]contract.RefEntry {
    assert(std.mem.startsWith(u8, prefix, "refs/"));
    var entries: std.ArrayList(contract.RefEntry) = .empty;
    for (sim.refs.keys(), sim.refs.values()) |name, oid| {
        if (matchesPrefix(name, prefix)) try entries.append(arena, .{ .name = name, .oid = oid });
    }
    std.mem.sort(contract.RefEntry, entries.items, {}, refLessThan);
    return entries.toOwnedSlice(arena);
}

pub fn updateRefs(
    sim: *GitSim,
    updates: []const contract.RefUpdate,
) (Error || error{RefConflict})!void {
    assert(updates.len > 0);
    // Check everything first: all or nothing.
    for (updates, 0..) |u, i| {
        if (!contract.isValidRefName(u.name)) protocolViolation(
            "invalid ref name '{s}'",
            .{u.name},
        );
        for (updates[0..i]) |prev| if (std.mem.eql(u8, prev.name, u.name))
            protocolViolation("ref '{s}' appears twice in one transaction", .{u.name});
        const current = sim.refs.get(u.name);
        const expected: ?Oid = switch (u.op) {
            .create => null,
            .update => |x| x.old,
            .delete => |old| old,
            .verify => |old| old,
        };
        if (!sameRef(current, expected)) return error.RefConflict;
        const new: ?Oid = switch (u.op) {
            .create => |n| n,
            .update => |x| x.new,
            .delete, .verify => null,
        };
        if (new) |n| if (!sim.objects.contains(n))
            protocolViolation("ref '{s}' would point at missing object {f}", .{ u.name, n });
    }
    for (updates) |u| switch (u.op) {
        .create => |n| try sim.refs.put(sim.arena, try sim.arena.dupe(u8, u.name), n),
        .update => |x| sim.refs.getPtr(u.name).?.* = x.new,
        .delete => {
            const removed = sim.refs.orderedRemove(u.name);
            assert(removed);
        },
        .verify => {},
    };
}

pub fn isAncestor(sim: *GitSim, ancestor: Oid, descendant: Oid) Error!bool {
    var seen: std.HashMapUnmanaged(Oid, void, OidContext, 80) = .empty;
    var stack: std.ArrayList(Oid) = .empty;
    try stack.append(sim.arena, descendant);
    while (stack.pop()) |oid| {
        if (oid.eql(ancestor)) return true;
        const gop = try seen.getOrPut(sim.arena, oid);
        if (gop.found_existing) continue;
        for (try sim.parentsOf(oid)) |p| try stack.append(sim.arena, p);
    }
    return false;
}

/// Like `git merge-base --all`, sorted by OID.
pub fn mergeBases(sim: *GitSim, arena: Allocator, a: Oid, b: Oid) Error![]Oid {
    const anc_a = try sim.ancestorSet(a);
    const anc_b = try sim.ancestorSet(b);
    var common: std.ArrayList(Oid) = .empty;
    var it = anc_a.keyIterator();
    while (it.next()) |oid| if (anc_b.contains(oid.*)) try common.append(sim.arena, oid.*);

    var bases: std.ArrayList(Oid) = .empty;
    outer: for (common.items) |c| {
        for (common.items) |other| {
            if (other.eql(c)) continue;
            if (try sim.isAncestor(c, other)) continue :outer; // c is not "best"
        }
        try bases.append(arena, c);
    }
    std.mem.sort(Oid, bases.items, {}, oidLessThan);
    return bases.toOwnedSlice(arena);
}

pub fn configGet(sim: *GitSim, arena: Allocator, key: []const u8) Error!?[]const u8 {
    _ = arena;
    var found: ?[]const u8 = null;
    for (sim.config.items) |e| if (std.mem.eql(u8, e.key, key)) {
        found = e.value; // last one wins, like `git config --get`
    };
    return found;
}

pub fn configGetAll(sim: *GitSim, arena: Allocator, key: []const u8) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (sim.config.items) |e| if (std.mem.eql(u8, e.key, key)) try out.append(arena, e.value);
    return out.items;
}

pub fn configAdd(sim: *GitSim, key: []const u8, value: []const u8) Error!void {
    try sim.config.append(sim.arena, .{
        .key = try sim.arena.dupe(u8, key),
        .value = try sim.arena.dupe(u8, value),
    });
}

pub fn configUnsetValue(sim: *GitSim, key: []const u8, value: []const u8) Error!void {
    var i: usize = 0;
    while (i < sim.config.items.len) {
        const e = sim.config.items[i];
        if (std.mem.eql(u8, e.key, key) and std.mem.eql(u8, e.value, value)) {
            _ = sim.config.orderedRemove(i);
        } else i += 1;
    }
}

/// In first-seen order.
pub fn remoteNames(sim: *GitSim, arena: Allocator) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (sim.config.items) |e| {
        if (!std.mem.startsWith(
            u8,
            e.key,
            "remote.",
        ) or !std.mem.endsWith(u8, e.key, ".url")) continue;
        const name = e.key["remote.".len .. e.key.len - ".url".len];
        var dup = false;
        for (out.items) |n| if (std.mem.eql(u8, n, name)) {
            dup = true;
        };
        if (!dup) try out.append(arena, name);
    }
    std.mem.sort([]const u8, out.items, {}, stringLessThan);
    return out.items;
}

pub fn identity(
    sim: *GitSim,
    arena: Allocator,
) (Error || error{IdentityUnknown})!contract.Identity {
    _ = arena;
    const clock = &sim.world.clock;
    const sig: Signature = .{
        .name = sim.world.identity.name,
        .email = sim.world.identity.email,
        .time = clock.now,
        .tz_offset_minutes = clock.tz_offset_minutes,
    };
    if (sig.name.len == 0 or sig.email.len == 0) return error.IdentityUnknown;
    assert(sig.isValid());
    clock.now += clock.step_seconds;
    return .{ .author = sig, .committer = sig };
}

pub fn randomBytes(sim: *GitSim, buf: []u8) void {
    sim.prng.random().bytes(buf);
}

pub fn lfsRead(
    sim: *GitSim,
    arena: Allocator,
    store: contract.LfsStore,
    sha256: []const u8,
) Error!?[]const u8 {
    _ = arena;
    checkSha(sha256);
    for (sim.lfs.items) |o| if (o.store == store and std.mem.eql(u8, o.sha256, sha256)) {
        return o.data;
    };
    return null;
}

pub fn lfsWrite(
    sim: *GitSim,
    store: contract.LfsStore,
    sha256: []const u8,
    data: []const u8,
) Error!void {
    checkSha(sha256);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, sha256))
        protocolViolation("LFS object stored under a wrong hash", .{});
    for (sim.lfs.items) |o| if (o.store == store and std.mem.eql(u8, o.sha256, sha256)) return;
    try sim.lfs.append(sim.arena, .{
        .store = store,
        .sha256 = try sim.arena.dupe(u8, sha256),
        .data = try sim.arena.dupe(u8, data),
    });
}

pub fn lfsList(
    sim: *GitSim,
    arena: Allocator,
    store: contract.LfsStore,
) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (sim.lfs.items) |o| if (o.store == store) try out.append(arena, o.sha256);
    std.mem.sort([]const u8, out.items, {}, stringLessThan);
    return out.items;
}

/// Moves objects between the clones' git-lfs stores. A clone with
/// `sim.lfs = false` has no git-lfs.
pub fn lfsPush(
    sim: *GitSim,
    arena: Allocator,
    remote: []const u8,
    shas: []const []const u8,
) (Error || contract.LfsTransportError)!void {
    if (!try sim.hasGitLfs(arena)) return error.LfsUnavailable;
    const idx = (try sim.remoteClone(arena, remote)) orelse return error.LfsTransferFailed;
    var target: std.ArrayList(World.LfsObject) = .empty;
    try target.appendSlice(arena, sim.world.clones[idx].lfs);
    for (shas) |sha| {
        checkSha(sha);
        const data = (try sim.lfsRead(arena, .git_lfs, sha)) orelse return error.LfsTransferFailed;
        const have = for (target.items) |o| {
            if (o.store == .git_lfs and std.mem.eql(u8, o.sha256, sha)) break true;
        } else false;
        if (!have) try target.append(arena, .{
            .store = .git_lfs,
            .sha256 = try arena.dupe(u8, sha),
            .data = data,
        });
    }
    std.mem.sort(World.LfsObject, target.items, {}, lfsLessThan);
    const clones = try arena.dupe(World.Clone, sim.world.clones);
    clones[idx].lfs = target.items;
    sim.world.clones = clones;
}

pub fn lfsFetch(
    sim: *GitSim,
    arena: Allocator,
    remote: []const u8,
    local_refs: []const []const u8,
) (Error || contract.LfsTransportError)!void {
    if (!try sim.hasGitLfs(arena)) return error.LfsUnavailable;
    const idx = (try sim.remoteClone(arena, remote)) orelse return error.LfsTransferFailed;
    const format = sim.world.format;
    for (local_refs) |name| {
        const tip = sim.refs.get(name) orelse continue;
        const c = object.Commit.parse(arena, format, sim.objects.get(tip).?.data) catch continue;
        const tree = sim.objects.get(c.tree) orelse continue;
        const entries = object.Tree.parse(arena, format, tree.data) catch continue;
        for (entries) |e| {
            const blob = sim.objects.get(e.oid) orelse continue;
            const at = std.mem.find(u8, blob.data, "oid sha256:") orelse continue;
            if (at + 11 + 64 > blob.data.len) continue;
            const sha = blob.data[at + 11 ..][0..64];
            for (sim.world.clones[idx].lfs) |o| {
                if (o.store == .git_lfs and std.mem.eql(u8, o.sha256, sha)) {
                    try sim.lfsWrite(.git_lfs, sha, o.data);
                }
            }
        }
    }
}

fn hasGitLfs(sim: *GitSim, arena: Allocator) Error!bool {
    const v = (try sim.configGet(arena, "sim.lfs")) orelse return true;
    return !std.mem.eql(u8, v, "false");
}

pub fn readFile(sim: *GitSim, path: []const u8) ?[]const u8 {
    for (sim.world.files) |f| if (std.mem.eql(u8, f.path, path)) return f.data;
    return null;
}

fn checkSha(sha256: []const u8) void {
    if (sha256.len != 64 or !hex_fmt.isLower(sha256))
        protocolViolation("LFS id '{s}' is not a sha256", .{sha256});
}

fn lfsLessThan(_: void, a: World.LfsObject, b: World.LfsObject) bool {
    if (a.store != b.store) return @intFromEnum(a.store) < @intFromEnum(b.store);
    return std.mem.lessThan(u8, a.sha256, b.sha256);
}

/// Remotes are other clones: `remote.<name>.url = sim:<clone>`.
fn remoteClone(sim: *GitSim, arena: Allocator, remote: []const u8) Error!?usize {
    const key = try std.fmt.allocPrint(arena, "remote.{s}.url", .{remote});
    const url = (try sim.configGet(arena, key)) orelse return null;
    if (!std.mem.startsWith(u8, url, "sim:")) return null;
    const idx = sim.world.cloneIndex(url["sim:".len..]) orelse return null;
    if (idx == sim.clone_index) protocolViolation(
        "remote '{s}' points at the clone itself",
        .{remote},
    );
    return idx;
}

fn objectsOf(arena: Allocator, format: ObjectFormat, clone: World.Clone) Error!ObjectMap {
    var map: ObjectMap = .empty;
    for (clone.objects) |o| try map.put(arena, object.hashObject(format, o.kind, o.data), o);
    return map;
}

fn copyReachable(
    arena: Allocator,
    format: ObjectFormat,
    from: *const ObjectMap,
    into: *ObjectMap,
    start: Oid,
) Error!void {
    var stack: std.ArrayList(Oid) = .empty;
    try stack.append(arena, start);
    while (stack.pop()) |oid| {
        if (into.contains(oid)) continue;
        const o = from.get(oid) orelse {
            if (oid.eql(object.emptyTree(format))) continue; // always present in git
            protocolViolation("remote object {f} is missing", .{oid});
        };
        try into.put(arena, oid, o);
        if (o.kind == .commit) {
            const c = object.Commit.parse(arena, format, o.data) catch
                protocolViolation("remote commit {f} does not decode", .{oid});
            try stack.append(arena, c.tree);
            for (c.parents) |p| try stack.append(arena, p);
        } else if (o.kind == .tree) {
            const entries = object.Tree.parse(arena, format, o.data) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidTree => protocolViolation("remote tree {f} does not decode", .{oid}),
            };
            for (entries) |e| try stack.append(arena, e.oid);
        }
    }
}

const Refspec = struct { force: bool, src: []const u8, dst: []const u8 };

fn parseRefspec(spec: []const u8) Refspec {
    const force = spec.len > 0 and spec[0] == '+';
    const body = if (force) spec[1..] else spec;
    const colon = std.mem.findScalar(u8, body, ':') orelse protocolViolation(
        "refspec '{s}' has no ':'",
        .{spec},
    );
    return .{ .force = force, .src = body[0..colon], .dst = body[colon + 1 ..] };
}

fn mapRef(arena: Allocator, name: []const u8, spec: Refspec) Error!?[]const u8 {
    if (std.mem.endsWith(u8, spec.src, "*")) {
        const prefix = spec.src[0 .. spec.src.len - 1];
        if (!std.mem.startsWith(u8, name, prefix)) return null;
        if (!std.mem.endsWith(u8, spec.dst, "*")) protocolViolation("refspec dst lacks '*'", .{});
        return try std.mem.concat(
            arena,
            u8,
            &.{ spec.dst[0 .. spec.dst.len - 1], name[prefix.len..] },
        );
    }
    return if (std.mem.eql(u8, name, spec.src)) spec.dst else null;
}

pub fn fetch(
    sim: *GitSim,
    arena: Allocator,
    remote: []const u8,
    refspecs: []const []const u8,
) (Error || error{FetchFailed})!void {
    const idx = (try sim.remoteClone(arena, remote)) orelse return error.FetchFailed;
    const remote_clone = sim.world.clones[idx];
    const format = sim.world.format;
    const remote_objects = try objectsOf(arena, format, remote_clone);
    for (refspecs) |raw| {
        const spec = parseRefspec(raw);
        for (remote_clone.refs) |r| {
            const dst = (try mapRef(arena, r.name, spec)) orelse continue;
            if (!contract.isValidRefName(dst)) protocolViolation(
                "fetch into invalid ref '{s}'",
                .{dst},
            );
            const oid = Oid.parseHex(format, r.oid) catch protocolViolation("bad remote oid", .{});
            try copyReachable(arena, format, &remote_objects, &sim.objects, oid);
            const current = sim.refs.get(dst);
            if (current != null and !spec.force and !try sim.isAncestor(current.?, oid)) continue;
            try sim.refs.put(arena, try arena.dupe(u8, dst), oid);
        }
    }
}

pub fn push(
    sim: *GitSim,
    arena: Allocator,
    remote: []const u8,
    refspecs: []const []const u8,
    atomic: bool,
) (Error || error{PushFailed})!contract.PushResult {
    const idx = (try sim.remoteClone(arena, remote)) orelse return error.PushFailed;
    const target = sim.world.clones[idx];
    const format = sim.world.format;
    var target_objects = try objectsOf(arena, format, target);
    var target_refs: std.array_hash_map.String(Oid) = .empty;
    for (target.refs) |r| try target_refs.put(
        arena,
        r.name,
        Oid.parseHex(format, r.oid) catch protocolViolation("bad oid", .{}),
    );

    const Plan = struct { dst: []const u8, new: Oid, status: contract.PushedRef.Status };
    var plans: std.ArrayList(Plan) = .empty;
    var any_rejected = false;
    for (refspecs) |raw| {
        const spec = parseRefspec(raw);
        if (spec.force) protocolViolation("forced push '{s}'", .{raw});
        if (!contract.isValidRefName(spec.dst)) protocolViolation(
            "push to invalid ref '{s}'",
            .{spec.dst},
        );
        const new = sim.refs.get(spec.src) orelse return error.PushFailed;
        const old = target_refs.get(spec.dst);
        const status: contract.PushedRef.Status = if (old == null)
            .ok
        else if (old.?.eql(new))
            .up_to_date
        else if (sim.objects.contains(old.?) and try sim.isAncestor(old.?, new))
            .ok
        else
            .rejected;
        if (status == .rejected) any_rejected = true;
        try plans.append(arena, .{ .dst = spec.dst, .new = new, .status = status });
    }
    if (atomic and any_rejected) {
        for (plans.items) |*p| if (p.status == .ok) {
            p.status = .rejected;
        };
    }
    var changed = false;
    for (plans.items) |p| if (p.status == .ok) {
        try copyReachable(arena, format, &sim.objects, &target_objects, p.new);
        try target_refs.put(arena, p.dst, p.new);
        changed = true;
    };
    if (changed) {
        var objs: std.ArrayList(World.StoredObject) = .empty;
        var oids: std.ArrayList(Oid) = .empty;
        var it = target_objects.keyIterator();
        while (it.next()) |k| try oids.append(arena, k.*);
        std.mem.sort(Oid, oids.items, {}, oidLessThan);
        for (oids.items) |o| try objs.append(arena, target_objects.get(o).?);
        const names = try arena.dupe([]const u8, target_refs.keys());
        std.mem.sort([]const u8, names, {}, stringLessThan);
        var refs: std.ArrayList(World.Ref) = .empty;
        for (names) |n| try refs.append(arena, .{
            .name = n,
            .oid = try arena.dupe(u8, target_refs.get(n).?.hex().slice()),
        });
        const clones = try arena.dupe(World.Clone, sim.world.clones);
        clones[idx].objects = objs.items;
        clones[idx].refs = refs.items;
        sim.world.clones = clones;
    }
    const out = try arena.alloc(contract.PushedRef, plans.items.len);
    for (plans.items, out) |p, *o| o.* = .{ .name = p.dst, .status = p.status };
    return .{ .refs = out };
}

comptime {
    contract.assertBackend(GitSim);
}

fn parentsOf(sim: *GitSim, oid: Oid) Error![]const Oid {
    const o = sim.objects.get(oid) orelse protocolViolation("walked to missing object {f}", .{oid});
    if (o.kind != .commit) protocolViolation("walked to non-commit object {f}", .{oid});
    const c = object.Commit.parse(sim.arena, sim.world.format, o.data) catch
        protocolViolation("stored commit {f} does not decode", .{oid});
    return c.parents;
}

fn ancestorSet(sim: *GitSim, start: Oid) Error!std.HashMapUnmanaged(Oid, void, OidContext, 80) {
    var seen: std.HashMapUnmanaged(Oid, void, OidContext, 80) = .empty;
    var stack: std.ArrayList(Oid) = .empty;
    try stack.append(sim.arena, start);
    while (stack.pop()) |oid| {
        const gop = try seen.getOrPut(sim.arena, oid);
        if (gop.found_existing) continue;
        for (try sim.parentsOf(oid)) |p| try stack.append(sim.arena, p);
    }
    return seen;
}

/// `for-each-ref` semantics: equal, or a leading run of path components.
fn matchesPrefix(name: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    if (name.len == prefix.len) return true;
    return prefix[prefix.len - 1] == '/' or name[prefix.len] == '/';
}

fn sameRef(a: ?Oid, b: ?Oid) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

fn protocolViolation(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.panic("GitSim protocol violation: " ++ fmt, args);
}

fn oidLessThan(_: void, a: Oid, b: Oid) bool {
    return a.order(b) == .lt;
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn refLessThan(_: void, a: contract.RefEntry, b: contract.RefEntry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

const testing = std.testing;

fn testCommit(sim: *GitSim, parents: []const Oid, msg: []const u8) !Oid {
    const sig = (try sim.identity(sim.arena)).author;
    const c: object.Commit = .{
        .tree = object.emptyTree(sim.world.format),
        .parents = parents,
        .author = sig,
        .committer = sig,
        .message = msg,
    };
    return sim.writeObject(.commit, try c.serializeAlloc(sim.arena));
}

test "CAS transactions are all-or-nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: World = .{ .clones = &.{.{ .name = "a" }} };
    var sim: GitSim = try .init(arena, &world, 0);

    const c1 = try testCommit(&sim, &.{}, "one\n");
    const c2 = try testCommit(&sim, &.{c1}, "two\n");
    try sim.updateRefs(&.{.{ .name = "refs/issues/x", .op = .{ .create = c1 } }});
    try testing.expectError(
        error.RefConflict,
        sim.updateRefs(&.{.{ .name = "refs/issues/x", .op = .{ .create = c2 } }}),
    );

    // The second update conflicts, so the first must not apply either.
    try testing.expectError(error.RefConflict, sim.updateRefs(&.{
        .{ .name = "refs/issues/y", .op = .{ .create = c1 } },
        .{ .name = "refs/issues/x", .op = .{ .update = .{ .new = c2, .old = c2 } } },
    }));
    try testing.expect(try sim.resolveRef("refs/issues/y") == null);

    try sim.updateRefs(&.{
        .{ .name = "refs/issues/x", .op = .{ .update = .{ .new = c2, .old = c1 } } },
        .{ .name = "refs/issues/z", .op = .{ .verify = null } },
    });
    try testing.expect((try sim.resolveRef("refs/issues/x")).?.eql(c2));
}

test "merge bases and ancestry" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: World = .{ .clones = &.{.{ .name = "a" }} };
    var sim: GitSim = try .init(arena, &world, 0);

    const root = try testCommit(&sim, &.{}, "root\n");
    const left = try testCommit(&sim, &.{root}, "left\n");
    const right = try testCommit(&sim, &.{root}, "right\n");
    const m1 = try testCommit(&sim, &.{ left, right }, "m1\n");
    const m2 = try testCommit(&sim, &.{ right, left }, "m2\n");

    try testing.expect(try sim.isAncestor(root, m1));
    try testing.expect(!try sim.isAncestor(left, right));
    const one = try sim.mergeBases(arena, left, right);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expect(one[0].eql(root));
    // Criss-cross: two best common ancestors.
    const two = try sim.mergeBases(arena, m1, m2);
    try testing.expectEqual(@as(usize, 2), two.len);
}

test "world round trip through ZON is lossless" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: World = .{ .seed = 42, .clones = &.{ .{ .name = "a" }, .{ .name = "b" } } };
    var sim: GitSim = try .init(arena, &world, 0);
    const c = try testCommit(
        &sim,
        &.{},
        "Title \"quoted\"\n\nUnicode: ü ✓\n\nState: open\nFormat-Version: 1\n",
    );
    try sim.updateRefs(&.{.{ .name = "refs/issues/0f0e", .op = .{ .create = c } }});
    try sim.commit();

    var aw: std.Io.Writer.Allocating = .init(arena);
    try world.write(&aw.writer);
    const text = try arena.dupeZ(u8, aw.written());
    var back = try World.parse(arena, text, null);

    var aw2: std.Io.Writer.Allocating = .init(arena);
    try back.write(&aw2.writer);
    try testing.expectEqualStrings(aw.written(), aw2.written());

    var sim2: GitSim = try .init(arena, &back, 0);
    try testing.expect((try sim2.resolveRef("refs/issues/0f0e")).?.eql(c));
    try testing.expect(world.seed != 42);
}

test "deterministic identity and randomness" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w1: World = .{ .seed = 7, .clones = &.{.{ .name = "a" }} };
    var w2: World = .{ .seed = 7, .clones = &.{.{ .name = "a" }} };
    var s1: GitSim = try .init(arena, &w1, 0);
    var s2: GitSim = try .init(arena, &w2, 0);
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    s1.randomBytes(&b1);
    s2.randomBytes(&b2);
    try testing.expectEqualSlices(u8, &b1, &b2);
    const first = (try s1.identity(arena)).author;
    const second = (try s1.identity(arena)).author;
    try testing.expect(second.time > first.time);
}

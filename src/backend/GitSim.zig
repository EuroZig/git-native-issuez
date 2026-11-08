//! In-memory backend: a world of clones, serialised as ZON.
//!
//! Objects hash like they do in git, so OIDs match `GitProcess`. Time and
//! randomness come from the world, so runs are deterministic. Breaking a
//! protocol rule (a commit pointing at missing objects, an invalid ref
//! name) is a bug in the caller and panics.

const GitSim = @This();

const std = @import("std");
const stableSort = @import("../sort.zig").stable;
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

    /// Like GitProcess: `issuez` is the store, `git_lfs` git-lfs's copy
    /// for transfers.
    pub const LfsStore = enum { issuez, git_lfs };

    pub const LfsObject = struct {
        store: LfsStore,
        sha256: []const u8,
        data: []const u8,
    };

    pub const ConfigEntry = contract.ConfigEntry;
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

/// A pre-receive hook for simulations: runs before a push lands, on a
/// quarantine (the receiving clone with the pushed objects added, its refs
/// as they were). Refusing fails the push like a real hook: PushFailed.
pub const ReceiveHook = struct {
    context: *anyopaque,
    receive: *const fn (
        context: *anyopaque,
        arena: Allocator,
        quarantine: *GitSim,
        updates: []const Received,
    ) bool,
};

/// One ref a push changes; null for none.
pub const Received = struct { name: []const u8, old: ?Oid, new: ?Oid };

/// Off unless a simulator or fuzzer sets it. Global, since worlds are
/// plain values.
pub var receive_hook: ?ReceiveHook = null;

fn runReceiveHook(
    sim: *GitSim,
    arena: Allocator,
    idx: usize,
    objects: *const ObjectMap,
    updates: []const Received,
) Error!bool {
    const hook = receive_hook orelse return true;
    if (updates.len == 0) return true;
    var q = try GitSim.init(arena, sim.world, idx);
    q.objects = try objects.clone(arena);
    return hook.receive(hook.context, arena, &q, updates);
}

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
    stableSort(Oid, oids, {}, oidLessThan);
    for (oids, objs) |oid, *o| o.* = sim.objects.get(oid).?;

    const names = try sim.arena.dupe([]const u8, sim.refs.keys());
    stableSort([]const u8, names, {}, stringLessThan);
    const refs = try sim.arena.alloc(World.Ref, names.len);
    for (names, refs) |name, *r| {
        const hex = sim.refs.get(name).?.hex();
        r.* = .{ .name = name, .oid = try sim.arena.dupe(u8, hex.slice()) };
    }

    const clones = try sim.arena.dupe(World.Clone, sim.world.clones);
    clones[sim.clone_index].objects = objs;
    clones[sim.clone_index].refs = refs;
    clones[sim.clone_index].config = sim.config.items;
    stableSort(World.LfsObject, sim.lfs.items, {}, lfsLessThan);
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
    stableSort(contract.RefEntry, entries.items, {}, refLessThan);
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
    stableSort(Oid, bases.items, {}, oidLessThan);
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

/// Like `GitProcess.configList`: section and name lowercase, the
/// subsection as written.
pub fn configList(sim: *GitSim, arena: Allocator) Error![]const World.ConfigEntry {
    const out = try arena.alloc(World.ConfigEntry, sim.config.items.len);
    for (sim.config.items, out) |e, *o| {
        const key = try arena.dupe(u8, e.key);
        const first = std.mem.findScalar(u8, key, '.') orelse key.len;
        const last = std.mem.findScalarLast(u8, key, '.') orelse key.len;
        for (key[0..first]) |*c| c.* = std.ascii.toLower(c.*);
        if (last < key.len) for (key[last..]) |*c| {
            c.* = std.ascii.toLower(c.*);
        };
        o.* = .{ .key = key, .value = e.value };
    }
    return out;
}

/// Sorted, as `git remote` lists them.
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
    stableSort([]const u8, out.items, {}, stringLessThan);
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

/// Ours when it hashes right, else git-lfs's put into ours when it does,
/// else whatever there is. Like GitProcess.
pub fn lfsRead(sim: *GitSim, arena: Allocator, sha256: []const u8) Error!?[]const u8 {
    _ = arena;
    checkSha(sha256);
    const ours = sim.stored(.issuez, sha256);
    if (ours) |data| if (hashes(data, sha256)) return data;
    const theirs = sim.stored(.git_lfs, sha256) orelse return ours;
    if (!hashes(theirs, sha256)) return ours orelse theirs;
    try sim.store(.issuez, sha256, theirs);
    return theirs;
}

pub fn lfsSize(sim: *GitSim, sha256: []const u8) Error!?u64 {
    checkSha(sha256);
    return if (sim.stored(.issuez, sha256)) |d| d.len else null;
}

pub fn lfsWrite(sim: *GitSim, sha256: []const u8, data: []const u8) Error!void {
    checkSha(sha256);
    if (!hashes(data, sha256)) protocolViolation("LFS object stored under a wrong hash", .{});
    try sim.store(.issuez, sha256, data);
}

pub fn lfsList(sim: *GitSim, arena: Allocator) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (sim.lfs.items) |o| if (o.store == .issuez) try out.append(arena, o.sha256);
    stableSort([]const u8, out.items, {}, stringLessThan);
    return out.items;
}

fn stored(sim: *GitSim, s: World.LfsStore, sha256: []const u8) ?[]const u8 {
    for (sim.lfs.items) |o| if (o.store == s and std.mem.eql(u8, o.sha256, sha256)) {
        return o.data;
    };
    return null;
}

/// Replaces a damaged copy.
fn store(sim: *GitSim, s: World.LfsStore, sha256: []const u8, data: []const u8) Error!void {
    for (sim.lfs.items) |*o| if (o.store == s and std.mem.eql(u8, o.sha256, sha256)) {
        o.data = try sim.arena.dupe(u8, data);
        return;
    };
    try sim.lfs.append(sim.arena, .{
        .store = s,
        .sha256 = try sim.arena.dupe(u8, sha256),
        .data = try sim.arena.dupe(u8, data),
    });
}

fn hashes(data: []const u8, sha256: []const u8) bool {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, &hex, sha256);
}

/// Copies our objects into git-lfs's store, like GitProcess, then into the
/// remote clone's. A clone with `sim.lfs = false` has no git-lfs.
pub fn lfsPush(
    sim: *GitSim,
    arena: Allocator,
    remote: []const u8,
    shas: []const []const u8,
) (Error || contract.LfsTransportError)!void {
    if (!try sim.lfsAvailable(arena)) return error.LfsUnavailable;
    const idx = (try sim.remoteClone(arena, remote)) orelse return error.LfsTransferFailed;
    var target: std.ArrayList(World.LfsObject) = .empty;
    try target.appendSlice(arena, sim.world.clones[idx].lfs);
    for (shas) |sha| {
        checkSha(sha);
        if (sim.stored(.git_lfs, sha) == null) {
            const ours = sim.stored(.issuez, sha) orelse return error.LfsTransferFailed;
            try sim.store(.git_lfs, sha, ours);
        }
        const data = sim.stored(.git_lfs, sha).?;
        const have = for (target.items) |o| {
            if (o.store == .git_lfs and std.mem.eql(u8, o.sha256, sha)) break true;
        } else false;
        if (!have) try target.append(arena, .{
            .store = .git_lfs,
            .sha256 = try arena.dupe(u8, sha),
            .data = data,
        });
    }
    stableSort(World.LfsObject, target.items, {}, lfsLessThan);
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
    if (!try sim.lfsAvailable(arena)) return error.LfsUnavailable;
    const idx = (try sim.remoteClone(arena, remote)) orelse return error.LfsTransferFailed;
    const format = sim.world.format;
    // Like git-lfs: an unknown ref fails the whole call, and an object the
    // server lacks fails it after the others arrived.
    const tips = try arena.alloc(Oid, local_refs.len);
    for (local_refs, tips) |name, *tip| tip.* = sim.refs.get(name) orelse
        (Oid.parseHex(format, name) catch return error.LfsTransferFailed);
    var lacking = false;
    for (tips) |tip| {
        const obj = sim.objects.get(tip) orelse return error.LfsTransferFailed;
        const c = object.Commit.parse(arena, format, obj.data) catch continue;
        const tree = sim.objects.get(c.tree) orelse continue;
        const entries = object.Tree.parse(arena, format, tree.data) catch continue;
        for (entries) |e| {
            const blob = sim.objects.get(e.oid) orelse continue;
            const at = std.mem.find(u8, blob.data, "oid sha256:") orelse continue;
            if (at + 11 + 64 > blob.data.len) continue;
            const sha = blob.data[at + 11 ..][0..64];
            const found = for (sim.world.clones[idx].lfs) |o| {
                if (o.store == .git_lfs and std.mem.eql(u8, o.sha256, sha)) break o;
            } else null;
            if (found) |o| try sim.store(.git_lfs, sha, o.data) else lacking = true;
        }
    }
    if (lacking) return error.LfsTransferFailed;
}

/// False with `sim.lfs = false`.
pub fn lfsAvailable(sim: *GitSim, arena: Allocator) Error!bool {
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
    // A URL given instead of a name.
    const url = if (std.mem.startsWith(u8, remote, "sim:"))
        remote
    else
        (try sim.configGet(arena, key)) orelse return null;
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
    options: contract.FetchOptions,
) (Error || error{FetchFailed})!void {
    const idx = (try sim.remoteClone(arena, remote)) orelse return error.FetchFailed;
    const remote_clone = sim.world.clones[idx];
    const format = sim.world.format;
    const remote_objects = try objectsOf(arena, format, remote_clone);
    // Like `git fetch --prune`: a ref under a glob destination goes when no
    // refspec maps a remote ref to it any more (all refspecs together).
    if (options.prune) {
        var wanted: std.StringHashMapUnmanaged(void) = .empty;
        for (refspecs) |raw| {
            const spec = parseRefspec(raw);
            for (remote_clone.refs) |r| {
                const dst = (try mapRef(arena, r.name, spec)) orelse continue;
                try wanted.put(arena, dst, {});
            }
        }
        var gone: std.ArrayList([]const u8) = .empty;
        var it = sim.refs.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            if (wanted.contains(name)) continue;
            const pruned = for (refspecs) |raw| {
                const spec = parseRefspec(raw);
                if (!std.mem.endsWith(u8, spec.dst, "*")) continue;
                if (std.mem.startsWith(u8, name, spec.dst[0 .. spec.dst.len - 1])) break true;
            } else false;
            if (pruned) try gone.append(arena, name);
        }
        for (gone.items) |name| _ = sim.refs.orderedRemove(name);
    }
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
    options: contract.PushOptions,
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
    if (options.atomic and any_rejected) {
        for (plans.items) |*p| if (p.status == .ok) {
            p.status = .rejected;
        };
    }
    var received: std.ArrayList(Received) = .empty;
    for (plans.items) |p| if (p.status == .ok) {
        try copyReachable(arena, format, &sim.objects, &target_objects, p.new);
        try received.append(arena, .{ .name = p.dst, .old = target_refs.get(p.dst), .new = p.new });
    };
    if (!try sim.runReceiveHook(arena, idx, &target_objects, received.items))
        return error.PushFailed;
    var changed = false;
    for (plans.items) |p| if (p.status == .ok) {
        try target_refs.put(arena, p.dst, p.new);
        changed = true;
    };
    if (changed) try sim.storeRemote(arena, idx, &target_objects, &target_refs);
    const out = try arena.alloc(contract.PushedRef, plans.items.len);
    for (plans.items, out) |p, *o| o.* = .{ .name = p.dst, .status = p.status };
    return .{ .refs = out };
}

/// Atomic, like `git push --atomic --force-with-lease`: every ref must
/// still be what its lease expects, and then each is set to its source or
/// deleted, fast-forward or not.
/// A local ref, or like git an object ID this clone has.
fn leasedSource(sim: *const GitSim, src: []const u8) ?Oid {
    if (sim.refs.get(src)) |oid| return oid;
    const oid = Oid.parseHex(sim.world.format, src) catch return null;
    return if (sim.objects.contains(oid)) oid else null;
}

pub fn pushLeased(
    sim: *GitSim,
    arena: Allocator,
    remote: []const u8,
    updates: []const contract.LeasedRef,
) (Error || error{PushFailed})!contract.PushResult {
    assert(updates.len > 0);
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
    const out = try arena.alloc(contract.PushedRef, updates.len);
    var stale = false;
    for (updates, out) |u, *o| {
        if (!contract.isValidRefName(u.dst)) protocolViolation(
            "push to invalid ref '{s}'",
            .{u.dst},
        );
        const new: ?Oid = if (u.src) |src|
            sim.leasedSource(src) orelse return error.PushFailed
        else
            null;
        const old = target_refs.get(u.dst);
        o.* = .{ .name = u.dst, .status = .ok };
        if (!sameRef(old, u.expect)) {
            stale = true;
            o.status = .rejected;
        } else if (sameRef(old, new)) o.status = .up_to_date;
    }
    if (stale) {
        for (out) |*o| o.status = .rejected;
        return .{ .refs = out };
    }
    var received: std.ArrayList(Received) = .empty;
    for (updates, out) |u, o| {
        if (o.status == .up_to_date) continue;
        const new: ?Oid = if (u.src) |src| sim.leasedSource(src).? else null;
        if (new) |n| try copyReachable(arena, format, &sim.objects, &target_objects, n);
        try received.append(arena, .{ .name = u.dst, .old = target_refs.get(u.dst), .new = new });
    }
    if (!try sim.runReceiveHook(arena, idx, &target_objects, received.items))
        return error.PushFailed;
    for (updates) |u| {
        if (u.src) |src| {
            try target_refs.put(arena, u.dst, sim.leasedSource(src).?);
        } else _ = target_refs.orderedRemove(u.dst);
    }
    try sim.storeRemote(arena, idx, &target_objects, &target_refs);
    return .{ .refs = out };
}

fn storeRemote(
    sim: *GitSim,
    arena: Allocator,
    idx: usize,
    target_objects: anytype,
    target_refs: *std.array_hash_map.String(Oid),
) Error!void {
    {
        var objs: std.ArrayList(World.StoredObject) = .empty;
        var oids: std.ArrayList(Oid) = .empty;
        var it = target_objects.keyIterator();
        while (it.next()) |k| try oids.append(arena, k.*);
        stableSort(Oid, oids.items, {}, oidLessThan);
        for (oids.items) |o| try objs.append(arena, target_objects.get(o).?);
        const names = try arena.dupe([]const u8, target_refs.keys());
        stableSort([]const u8, names, {}, stringLessThan);
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

test "fetch prunes against all refspecs together, like git" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: World = .{ .clones = &.{
        .{ .name = "hub" },
        .{ .name = "a", .config = &.{.{ .key = "remote.hub.url", .value = "sim:hub" }} },
    } };
    var hub: GitSim = try .init(arena, &world, 0);
    const root = try testCommit(&hub, &.{}, "root\n");
    try hub.updateRefs(&.{
        .{ .name = "refs/x/one", .op = .{ .create = root } },
        .{ .name = "refs/y/two", .op = .{ .create = root } },
    });
    try hub.commit();

    var a: GitSim = try .init(arena, &world, 1);
    const own = try testCommit(&a, &.{}, "own\n");
    try a.updateRefs(&.{.{ .name = "refs/m/stale", .op = .{ .create = own } }});
    // The first destination lies inside the second: git keeps `m/y/two`
    // although the second refspec has no `y/two`, and prunes `m/stale`.
    try a.fetch(
        arena,
        "hub",
        &.{ "+refs/y/*:refs/m/y/*", "+refs/x/*:refs/m/*" },
        .{ .prune = true },
    );
    const left = try a.listRefs(arena, "refs/m/");
    try testing.expectEqual(@as(usize, 2), left.len);
    try testing.expectEqualStrings("refs/m/one", left[0].name);
    try testing.expectEqualStrings("refs/m/y/two", left[1].name);
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

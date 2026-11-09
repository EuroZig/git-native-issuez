//! A test backend: `GitSim` that lets another writer move a ref right
//! before our first update, to exercise the compare-and-swap retry. Only
//! tests import it; `root.zig` doesn't export it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const contract = @import("../backend/contract.zig");
const object = @import("../backend/object.zig");
const GitSim = @import("../backend/GitSim.zig");
const Oid = object.Oid;
const Repo = @import("repo.zig").Repo;

/// Lets another writer move a ref right before our first update, to
/// exercise the CAS retry.
pub const RacingSim = struct {
    sim: *GitSim,
    race: ?struct {
        ref: []const u8,
        message: []const u8,
        close: bool = false,
        description: bool = false,
        comment_edit: ?Oid = null,
        /// Creates an open child of this issue instead.
        child_of: ?[]const u8 = null,
    } = null,

    pub const Error = GitSim.Error;

    pub fn objectFormat(r: *const RacingSim) object.ObjectFormat {
        return r.sim.objectFormat();
    }
    pub fn readObject(r: *RacingSim, arena: Allocator, oid: Oid) Error!?contract.Object {
        return r.sim.readObject(arena, oid);
    }
    pub fn writeObject(r: *RacingSim, kind: object.ObjectKind, data: []const u8) Error!Oid {
        return r.sim.writeObject(kind, data);
    }
    pub fn resolveRef(r: *RacingSim, name: []const u8) Error!?Oid {
        return r.sim.resolveRef(name);
    }
    pub fn listRefs(r: *RacingSim, arena: Allocator, prefix: []const u8) Error![]contract.RefEntry {
        return r.sim.listRefs(arena, prefix);
    }
    pub fn updateRefs(
        r: *RacingSim,
        updates: []const contract.RefUpdate,
    ) (Error || error{RefConflict})!void {
        if (r.race) |race| {
            r.race = null;
            const other = Repo(GitSim).init(r.sim);
            const a = r.sim.arena;
            if (race.child_of) |parent| {
                _ = other.create(
                    a,
                    .{ .title = "Late child", .parent = parent },
                    .{},
                ) catch unreachable;
            } else if (race.description) {
                _ = other.edit(
                    a,
                    race.ref,
                    .{ .description = race.message },
                    .{},
                ) catch unreachable;
            } else if (race.comment_edit) |comment| {
                _ = other.commentEvent(
                    a,
                    race.ref,
                    .{ .target = comment, .event = .edit, .text = race.message },
                    .{},
                ) catch unreachable;
            } else if (race.close) {
                _ = other.setState(a, race.ref, .{ .state = .closed }, .{}) catch unreachable;
            } else {
                _ = other.comment(a, race.ref, .{ .text = race.message }, .{}) catch unreachable;
            }
        }
        return r.sim.updateRefs(updates);
    }
    pub fn isAncestor(r: *RacingSim, a: Oid, b: Oid) Error!bool {
        return r.sim.isAncestor(a, b);
    }
    pub fn mergeBases(r: *RacingSim, arena: Allocator, a: Oid, b: Oid) Error![]Oid {
        return r.sim.mergeBases(arena, a, b);
    }
    pub fn configGet(r: *RacingSim, arena: Allocator, key: []const u8) Error!?[]const u8 {
        return r.sim.configGet(arena, key);
    }
    pub fn configGetAll(r: *RacingSim, arena: Allocator, key: []const u8) Error![]const []const u8 {
        return r.sim.configGetAll(arena, key);
    }
    pub fn configAdd(r: *RacingSim, key: []const u8, value: []const u8) Error!void {
        return r.sim.configAdd(key, value);
    }
    pub fn configUnsetValue(r: *RacingSim, key: []const u8, value: []const u8) Error!void {
        return r.sim.configUnsetValue(key, value);
    }
    pub fn remoteNames(r: *RacingSim, arena: Allocator) Error![]const []const u8 {
        return r.sim.remoteNames(arena);
    }
    pub fn fetch(
        r: *RacingSim,
        arena: Allocator,
        remote: []const u8,
        refspecs: []const []const u8,
        options: contract.FetchOptions,
    ) (Error || error{FetchFailed})!void {
        return r.sim.fetch(arena, remote, refspecs, options);
    }
    pub fn push(
        r: *RacingSim,
        arena: Allocator,
        remote: []const u8,
        refspecs: []const []const u8,
        options: contract.PushOptions,
    ) (Error || error{PushFailed})!contract.PushResult {
        return r.sim.push(arena, remote, refspecs, options);
    }
    pub fn identity(
        r: *RacingSim,
        arena: Allocator,
    ) (Error || error{IdentityUnknown})!contract.Identity {
        return r.sim.identity(arena);
    }
    pub fn randomBytes(r: *RacingSim, buf: []u8) void {
        r.sim.randomBytes(buf);
    }
};

//! A custom backend. The engine is generic over a comptime backend type,
//! so you can put your own layer between the library and git.
//!
//! `Audited(Inner)` wraps any backend, logs every ref change and refuses
//! writes outside the issue namespaces. The example also shows `.expect`,
//! the version token an HTTP API would use as its ETag.
//!
//!   zig build example-custom-backend

const std = @import("std");
const issuez = @import("issuez");

const contract = issuez.backend.contract;
const GitSim = issuez.backend.GitSim;
const Allocator = std.mem.Allocator;

/// Forwards the backend contract (src/backend/contract.zig) to `Inner`.
fn Audited(comptime Inner: type) type {
    return struct {
        const Self = @This();

        inner: *Inner,
        log: *std.Io.Writer,

        pub const Error = Inner.Error;

        // The two operations this wrapper changes.

        pub fn updateRefs(
            self: *Self,
            updates: []const contract.RefUpdate,
        ) (Error || error{RefConflict})!void {
            for (updates) |u| {
                // The library only writes issue and bookkeeping refs, so
                // anything else is a bug.
                const allowed = std.mem.startsWith(u8, u.name, "refs/issues/") or
                    std.mem.startsWith(u8, u.name, "refs/issuez-sync/") or
                    std.mem.startsWith(u8, u.name, "refs/issuez-guard/");
                if (!allowed) @panic("write outside the issue namespaces");
                self.log.print("  ref {t} {s}\n", .{ u.op, u.name }) catch {};
            }
            return self.inner.updateRefs(updates);
        }

        pub fn push(
            self: *Self,
            arena: Allocator,
            remote: []const u8,
            refspecs: []const []const u8,
            atomic: bool,
        ) (Error || error{PushFailed})!contract.PushResult {
            self.log.print("  push {d} ref(s) to {s}\n", .{ refspecs.len, remote }) catch {};
            return self.inner.push(arena, remote, refspecs, atomic);
        }

        // Plain delegation for the rest of the contract.

        pub fn objectFormat(self: *const Self) issuez.backend.object.ObjectFormat {
            return self.inner.objectFormat();
        }
        pub fn readObject(
            self: *Self,
            arena: Allocator,
            oid: contract.Oid,
        ) Error!?contract.Object {
            return self.inner.readObject(arena, oid);
        }
        pub fn writeObject(
            self: *Self,
            kind: contract.ObjectKind,
            data: []const u8,
        ) Error!contract.Oid {
            return self.inner.writeObject(kind, data);
        }
        pub fn resolveRef(self: *Self, name: []const u8) Error!?contract.Oid {
            return self.inner.resolveRef(name);
        }
        pub fn listRefs(
            self: *Self,
            arena: Allocator,
            prefix: []const u8,
        ) Error![]contract.RefEntry {
            return self.inner.listRefs(arena, prefix);
        }
        pub fn isAncestor(self: *Self, a: contract.Oid, b: contract.Oid) Error!bool {
            return self.inner.isAncestor(a, b);
        }
        pub fn mergeBases(
            self: *Self,
            arena: Allocator,
            a: contract.Oid,
            b: contract.Oid,
        ) Error![]contract.Oid {
            return self.inner.mergeBases(arena, a, b);
        }
        pub fn configGet(self: *Self, arena: Allocator, key: []const u8) Error!?[]const u8 {
            return self.inner.configGet(arena, key);
        }
        pub fn configGetAll(
            self: *Self,
            arena: Allocator,
            key: []const u8,
        ) Error![]const []const u8 {
            return self.inner.configGetAll(arena, key);
        }
        pub fn configAdd(self: *Self, key: []const u8, value: []const u8) Error!void {
            return self.inner.configAdd(key, value);
        }
        pub fn configUnsetValue(self: *Self, key: []const u8, value: []const u8) Error!void {
            return self.inner.configUnsetValue(key, value);
        }
        pub fn remoteNames(self: *Self, arena: Allocator) Error![]const []const u8 {
            return self.inner.remoteNames(arena);
        }
        pub fn identity(
            self: *Self,
            arena: Allocator,
        ) (Error || error{IdentityUnknown})!contract.Identity {
            return self.inner.identity(arena);
        }
        pub fn randomBytes(self: *Self, buf: []u8) void {
            self.inner.randomBytes(buf);
        }
        pub fn fetch(
            self: *Self,
            arena: Allocator,
            remote: []const u8,
            refspecs: []const []const u8,
        ) (Error || error{FetchFailed})!void {
            return self.inner.fetch(arena, remote, refspecs);
        }

        comptime {
            contract.assertBackend(Self);
        }
    };
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    var world: GitSim.World = .{
        .identity = .{ .name = "Ada", .email = "ada@example.invalid" },
        .clones = &.{.{ .name = "local" }},
    };
    var sim = try GitSim.init(arena, &world, 0);
    const Backend = Audited(GitSim);
    var backend: Backend = .{ .inner = &sim, .log = out };
    const repo = issuez.Repo(Backend).init(&backend);

    try out.writeAll("create:\n");
    const created = try repo.create(arena, .{ .title = "Audit me" });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});

    // Two clients read the issue at the same version (the ETag)...
    const etag = created.tip;
    try out.writeAll("client A comments (based on the ETag):\n");
    const after_a = try repo.comment(arena, ref_name, .{ .text = "Seen it", .expect = etag });

    // ...client B's change is based on a version that no longer exists.
    try out.writeAll("client B closes (same, now stale ETag):\n");
    if (repo.setState(arena, ref_name, .{ .state = .closed, .expect = etag })) |_| {
        try out.writeAll("  unexpectedly applied\n");
    } else |err| switch (err) {
        error.VersionMismatch => try out.writeAll("  refused: VersionMismatch (reload, retry)\n"),
        else => |e| return e,
    }

    try out.writeAll("client B retries with the fresh ETag:\n");
    _ = try repo.setState(arena, ref_name, .{ .state = .closed, .expect = after_a });

    const tip = (try sim.resolveRef(ref_name)).?;
    const issue = try repo.load(arena, .{ .name = ref_name, .tip = tip });
    try out.print("\n{s}: {s}, {d} update(s)\n", .{ issue.title, issue.state.text(), issue.comments.len });
}

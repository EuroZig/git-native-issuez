//! The backend contract. The engine is generic over the backend type, and
//! `assertBackend` checks at compile time that it declares:
//!
//! ```
//! pub const Error: type;
//! fn objectFormat(self) ObjectFormat
//! fn readObject(self, arena, Oid) Error!?Object             // null when missing
//! fn writeObject(self, ObjectKind, data) Error!Oid
//! fn resolveRef(self, name) Error!?Oid
//! fn listRefs(self, arena, prefix) Error![]RefEntry         // sorted by name
//! fn updateRefs(self, []const RefUpdate) (Error || error{RefConflict})!void
//! fn isAncestor(self, ancestor: Oid, descendant: Oid) Error!bool
//! fn mergeBases(self, arena, Oid, Oid) Error![]Oid          // sorted
//! fn configGet(self, arena, key) Error!?[]const u8          // last value
//! fn configGetAll(self, arena, key) Error![]const []const u8
//! fn configAdd(self, key, value) Error!void
//! fn configUnsetValue(self, key, value) Error!void
//! fn remoteNames(self, arena) Error![]const []const u8
//! fn identity(self, arena) Error!Identity
//! fn randomBytes(self, buf: []u8) void
//! fn fetch(self, arena, remote, refspecs) (Error || error{FetchFailed})!void
//! fn push(self, arena, remote, refspecs, atomic) (Error || error{PushFailed})!PushResult
//! ```

const std = @import("std");
const object = @import("object.zig");

pub const ObjectFormat = object.ObjectFormat;
pub const ObjectKind = object.ObjectKind;
pub const Oid = object.Oid;
pub const Signature = object.Signature;

/// Git keeps author and committer separately, so do we.
pub const Identity = struct {
    author: Signature,
    committer: Signature,
};

pub const Object = struct {
    kind: ObjectKind,
    data: []const u8,
};

pub const RefEntry = struct {
    name: []const u8,
    oid: Oid,
};

/// Part of an all-or-nothing ref transaction. Every operation states the
/// value it expects, so nothing is ever overwritten blindly.
pub const RefUpdate = struct {
    name: []const u8,
    op: Op,

    pub const Op = union(enum) {
        /// The ref must not exist yet.
        create: Oid,
        update: struct { new: Oid, old: Oid },
        delete: Oid,
        /// Only checks the ref's value (null: absent).
        verify: ?Oid,
    };
};

/// With `atomic`, either every ref was updated or none.
pub const PushResult = struct {
    refs: []const PushedRef,

    pub fn rejected(r: PushResult) bool {
        for (r.refs) |p| if (p.status == .rejected) return true;
        return false;
    }
};

pub const PushedRef = struct {
    name: []const u8,
    status: Status,

    pub const Status = enum {
        ok,
        up_to_date,
        /// Not a fast-forward, or the atomic push failed because of another
        /// ref. When the remote refused a ref for any other reason (a hook,
        /// permissions), `push` fails with PushFailed instead.
        rejected,
    };
};

/// Remote names end up in refs and refspecs, so they must be one safe path
/// component.
pub fn isValidRemoteName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255 or name[0] == '-' or name[0] == '.') return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return std.mem.find(u8, name, "..") == null and !std.mem.endsWith(u8, name, ".lock");
}

/// A strict subset of `git check-ref-format`: enough for every ref we
/// write, and nothing that could inject into line-based plumbing.
pub fn isValidRefName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "refs/")) return false;
    if (name.len > 1024) return false;
    if (std.mem.endsWith(u8, name, "/") or std.mem.endsWith(u8, name, ".lock")) return false;
    if (std.mem.find(u8, name, "..") != null) return false;
    if (std.mem.find(u8, name, "//") != null) return false;
    for (name) |c| switch (c) {
        0...0x20, 0x7f...0xff, '~', '^', ':', '?', '*', '[', '\\' => return false,
        else => {},
    };
    return true;
}

pub fn assertBackend(comptime B: type) void {
    comptime {
        if (!@hasDecl(B, "Error") or @TypeOf(B.Error) != type)
            @compileError(@typeName(B) ++ " must declare `pub const Error = error{...};`");
        const required = [_][]const u8{
            "objectFormat", "readObject",   "writeObject", "resolveRef",
            "listRefs",     "updateRefs",   "isAncestor",  "mergeBases",
            "configGet",    "configGetAll", "configAdd",   "configUnsetValue",
            "remoteNames",  "identity",     "randomBytes", "fetch",
            "push",
        };
        for (required) |name| {
            if (!@hasDecl(B, name))
                @compileError(@typeName(B) ++ " is missing backend operation `" ++ name ++ "`");
        }
    }
}

test isValidRefName {
    const t = std.testing;
    try t.expect(isValidRefName("refs/issues/a7f3b2c1-4e5d-4a8b-9c1e-2f3a4b5c6d7e"));
    try t.expect(isValidRefName("refs/issuez-sync/origin/merged/issues/x"));
    try t.expect(!isValidRefName("HEAD"));
    try t.expect(!isValidRefName("refs/issues/a b"));
    try t.expect(!isValidRefName("refs/issues/a\nupdate refs/heads/main x"));
    try t.expect(!isValidRefName("refs/issues/../heads/main"));
    try t.expect(!isValidRefName("refs/issues/x.lock"));
    try t.expect(!isValidRefName("refs/issues/"));
}

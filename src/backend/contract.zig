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
//! fn identity(self, arena) (Error || error{IdentityUnknown})!Identity
//! fn randomBytes(self, buf: []u8) void
//! fn configList(self, arena) Error![]const ConfigEntry  // optional: every
//!     entry in git's order, keys lowercased; settings read it in one call
//! fn fetch(self, arena, remote, refspecs, FetchOptions) (Error || error{FetchFailed})!void
//! fn push(self, arena, remote, refspecs, PushOptions) (Error || error{PushFailed})!PushResult
//! ```
//!
//! Attachments also need an LFS store. Without it every other operation
//! still works and attachments fail with AttachmentsUnsupported:
//!
//! ```
//! fn lfsRead(self, arena, sha256_hex) Error!?[]const u8
//! fn lfsWrite(self, sha256_hex, data) Error!void  // atomic, replaces
//! fn lfsList(self, arena) Error![]const []const u8
//! ```
//!
//! `lfsRead` returns the stored bytes, damaged or not; the engine checks
//! them. A backend that keeps a second copy elsewhere, like GitProcess
//! with git-lfs's store, returns a copy that hashes right when it has one
//! and puts it back into the store.
//!
//! Optional: `lfsSize` lets `Attachments.list` check an object without
//! reading it. Without it `list` reads every object.
//!
//! ```
//! fn lfsSize(self, sha256_hex) Error!?u64
//! ```
//!
//! Optional too, the transfers. Without them attachments work locally, and
//! a push that has bytes to upload fails with LfsUnavailable unless the
//! caller uploads them itself (`Sync.PushOptions.before_push`):
//!
//! ```
//! fn lfsAvailable(self, arena) Error!bool         // git-lfs installed
//! fn lfsPush(self, arena, remote, sha256_hexes) (Error || LfsTransportError)!void
//! fn lfsFetch(self, arena, remote, refs_or_oids) (Error || LfsTransportError)!void
//! ```
//!
//! Optional, the one push that isn't a fast-forward, for purges (format.md
//! §10). Atomic: every ref must still be what its lease expects, else all
//! are rejected.
//!
//! ```
//! fn pushLeased(self, arena, remote, []const LeasedRef) (Error || error{PushFailed})!PushResult
//! ```
//!
//! `lfsPush` uploads objects from the store. `lfsFetch` downloads the
//! objects the trees of those refs or commits point at, so that
//! `lfsRead` finds them afterwards.

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

pub fn hasLfs(comptime B: type) bool {
    return @hasDecl(B, "lfsRead") and @hasDecl(B, "lfsWrite") and @hasDecl(B, "lfsList");
}

pub fn hasLfsSize(comptime B: type) bool {
    return hasLfs(B) and @hasDecl(B, "lfsSize");
}

pub fn hasLfsTransport(comptime B: type) bool {
    return hasLfs(B) and @hasDecl(B, "lfsAvailable") and
        @hasDecl(B, "lfsPush") and @hasDecl(B, "lfsFetch");
}

pub const LfsTransportError = error{
    /// git-lfs isn't installed.
    LfsUnavailable,
    /// git-lfs failed, e.g. the remote has no LFS server or lacks an
    /// object.
    LfsTransferFailed,
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

pub fn hasLeasedPush(comptime B: type) bool {
    return @hasDecl(B, "pushLeased");
}

/// Sets the remote's `dst` to the local ref `src` (or an object ID in
/// hex), or deletes it when `src` is null, if the remote's is still
/// `expect` (null: absent).
pub const LeasedRef = struct {
    src: ?[]const u8,
    dst: []const u8,
    expect: ?Oid,
};

/// A config entry, as `configList` gives them.
pub const ConfigEntry = struct { key: []const u8, value: []const u8 };

/// What a backend's `fetch` takes.
pub const FetchOptions = struct {
    /// Delete refs under the refspecs' destinations that the remote no
    /// longer has, as `git fetch --prune`.
    prune: bool = false,
};

/// What a backend's `push` takes.
pub const PushOptions = struct {
    /// All refs or none, as `git push --atomic`; a remote that can't falls
    /// back to a plain push.
    atomic: bool = false,
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
        /// Not a fast-forward, the atomic push failed because of another
        /// ref, or the remote's ref moved while it received the push. When
        /// the remote refused a ref for any other reason (a hook,
        /// permissions), `push` fails with PushFailed instead.
        rejected,
    };
};

/// A URL or path given instead of a remote's name (`git fetch` takes
/// either): has a `/` or `:`, and nothing that would break a command
/// line or a ref name read back.
pub fn isRemoteUrl(target: []const u8) bool {
    if (target.len == 0 or target.len > 4096 or target[0] == '-') return false;
    for (target) |c| if (c < 0x20 or c == 0x7f) return false;
    return std.mem.findAny(u8, target, "/:") != null;
}

/// What fetch and push take: a remote's name, or a URL or path.
pub fn isValidRemoteTarget(target: []const u8) bool {
    return isValidRemoteName(target) or isRemoteUrl(target);
}

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

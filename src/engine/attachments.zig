//! Images on issues, see docs/attachments.md.
//!
//! The trailers in the issue history are the source of truth. The bytes
//! live in our own LFS store, which `git lfs prune` doesn't touch.
//! git-lfs's store only holds copies for transfers. `refs/attachments/<id>`
//! lists the objects as LFS pointers so git-lfs and LFS servers see them.
//! It moves in the same transaction as the issue ref and can always be
//! rebuilt.
//!
//! The API takes and returns bytes, never paths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const contract = @import("../backend/contract.zig");
const object = @import("../backend/object.zig");
const trailers = @import("../format/trailers.zig");
const uuid_fmt = @import("../format/uuid.zig");
const labels_fmt = @import("../format/labels.zig");
const fmt = @import("../format/attachment.zig");
const issue_model = @import("../model/issue.zig");
const repo_mod = @import("repo.zig");

const Oid = object.Oid;
const Signature = object.Signature;
pub const Attachment = issue_model.Attachment;
pub const Media = fmt.Media;
pub const Issue = issue_model.Issue;

pub const ref_prefix = repo_mod.attachment_ref_prefix;

/// What `Sync`'s `before_push` receives.
pub const Upload = struct {
    sha256: []const u8,
    size: u32,
    data: []const u8,
};

/// Same identity as merge commits, so two clones deriving the same state
/// from the same parent write the same commit.
pub const derived_identity_name = "git-issue";
pub const derived_identity_email = "git-issue@invalid";
pub const derived_subject = "Regenerate attachments";

pub fn Attachments(comptime B: type) type {
    return struct {
        const Self = @This();
        pub const Repo = repo_mod.Repo(B);
        pub const Error = Repo.Error;

        repo: Repo,

        pub fn init(backend: *B) Self {
            return .{ .repo = Repo.init(backend) };
        }

        /// Uses the repo's limits.
        pub fn fromRepo(repo: Repo) Self {
            return .{ .repo = repo };
        }

        pub const Input = struct {
            /// Usually the file name. Sanitised: last path component, no
            /// control characters, at most 255 bytes.
            name: []const u8,
            data: []const u8,
            /// Must match the bytes if given. Null takes it from the bytes.
            media: ?Media = null,
        };

        pub const AddSpec = struct {
            files: []const Input,
            /// Posted in the same commit as the images. Null gives an "Add
            /// attachment" commit.
            /// arrive together. Null: an "Add attachment" commit.
            comment: ?[]const u8 = null,
            author: ?Signature = null,
            /// Only apply on top of this issue tip, see `Repo`.
            expect: ?Oid = null,
        };

        pub const Added = struct {
            tip: Oid,
            /// In input order.
            ids: []const []const u8,
        };

        pub const ChangeSpec = struct {
            /// Defaults to "Remove attachment" or "Rename attachment".
            message: ?[]const u8 = null,
            author: ?Signature = null,
            expect: ?Oid = null,
        };

        /// Checks what `add` would accept without writing anything, e.g.
        /// when a file is dropped. Returns the media type.
        pub fn validate(self: Self, input: Input) Error!Media {
            if (input.data.len == 0) return error.EmptyAttachment;
            if (input.data.len > self.repo.limits.max_attachment_bytes)
                return error.AttachmentTooLarge;
            const media = fmt.sniff(input.data) catch |e| return switch (e) {
                error.UnsupportedType => error.UnsupportedType,
                error.Animated => error.AnimatedImage,
            };
            if (input.media) |m| if (m != media) return error.MediaMismatch;
            return media;
        }

        /// Stores the bytes, then writes one commit with an `X-Attachment`
        /// per file, and moves the derived ref with it.
        pub fn add(self: Self, arena: Allocator, ref_name: []const u8, spec: AddSpec) Error!Added {
            try requireLfs();
            if (spec.files.len == 0) return error.NoAttachments;
            const specs = try arena.alloc(fmt.Spec, spec.files.len);
            const ids = try arena.alloc([]const u8, spec.files.len);
            for (spec.files, specs, ids) |f, *s, *id| {
                const media = try self.validate(f);
                var random: [16]u8 = undefined;
                self.repo.backend.randomBytes(&random);
                const uuid = uuid_fmt.Uuid.fromRandom(random);
                id.* = try arena.dupe(u8, uuid.slice());
                s.* = .{
                    .id = id.*,
                    .media = media,
                    .size = @intCast(f.data.len),
                    .sha256 = fmt.Sha256.of(f.data),
                    .name = try fmt.sanitizeName(arena, f.name),
                };
            }
            // Bytes first, so a failed commit leaves at most an object
            // nobody references (see `orphans`).
            for (spec.files, specs) |f, s| try self.store(s.sha256, f.data);

            var tl: std.ArrayList(trailers.Trailer) = .empty;
            for (specs) |s| try tl.append(arena, .{
                .key = fmt.add_key,
                .value = try std.fmt.allocPrint(arena, "{f}", .{s}),
            });
            const text = spec.comment orelse
                (if (specs.len == 1) "Add attachment" else "Add attachments");
            if (text.len > self.repo.limits.max_body_bytes) return error.TooLong;
            const split = repo_mod.splitMessage(text);
            const message = try trailers.build(arena, split.subject, split.body, tl.items);
            const tip = try self.repo.appendWith(arena, ref_name, spec.author, spec.expect, Builder{
                .self = self,
                .text = message,
                .added = specs,
            });
            return .{ .tip = tip, .ids = ids };
        }

        /// The bytes stay, since history still references them.
        pub fn remove(
            self: Self,
            arena: Allocator,
            ref_name: []const u8,
            ids: []const []const u8,
            spec: ChangeSpec,
        ) Error!Oid {
            try requireLfs();
            if (ids.len == 0) return error.NoAttachments;
            var tl: std.ArrayList(trailers.Trailer) = .empty;
            for (ids) |id| {
                if (!uuid_fmt.isCanonical(id)) return error.AttachmentNotFound;
                try tl.append(arena, .{ .key = fmt.remove_key, .value = id });
            }
            const subject = spec.message orelse
                (if (ids.len == 1) "Remove attachment" else "Remove attachments");
            const split = repo_mod.splitMessage(subject);
            return self.repo.appendWith(arena, ref_name, spec.author, spec.expect, Builder{
                .self = self,
                .text = try trailers.build(arena, split.subject, split.body, tl.items),
                .removed = ids,
            });
        }

        /// A new `X-Attachment` with the same object.
        pub fn rename(
            self: Self,
            arena: Allocator,
            ref_name: []const u8,
            id: []const u8,
            name: []const u8,
            spec: ChangeSpec,
        ) Error!Oid {
            try requireLfs();
            const clean = try fmt.sanitizeName(arena, name);
            const split = repo_mod.splitMessage(spec.message orelse "Rename attachment");
            return self.repo.appendWith(arena, ref_name, spec.author, spec.expect, RenameBuilder{
                .id = id,
                .name = clean,
                .subject = split.subject,
                .body = split.body,
            });
        }

        const Builder = struct {
            self: Self,
            text: []const u8,
            added: []const fmt.Spec = &.{},
            removed: []const []const u8 = &.{},

            pub fn message(b: Builder, arena: Allocator, current: Issue) Error![]const u8 {
                _ = arena;
                for (b.removed) |id| {
                    if (findPresent(current, id) == null) return error.AttachmentNotFound;
                }
                const count = current.attachments.len + b.added.len;
                if (count > b.self.repo.limits.max_attachments) return error.TooManyAttachments;
                return b.text;
            }

            pub fn after(
                b: Builder,
                arena: Allocator,
                current: Issue,
                new_tip: Oid,
            ) Error![]const contract.RefUpdate {
                var present: std.ArrayList(Pointer) = .empty;
                for (current.attachments) |a| {
                    if (labels_fmt.contains(b.removed, a.id)) continue;
                    try present.append(arena, .fromAttachment(a));
                }
                for (b.added) |s| try present.append(arena, .{
                    .id = s.id,
                    .media = s.media,
                    .size = s.size,
                    .sha256 = s.sha256,
                });
                return b.self.derivedUpdate(arena, current.id, new_tip, present.items);
            }
        };

        const RenameBuilder = struct {
            id: []const u8,
            name: []const u8,
            subject: []const u8,
            body: []const u8,

            pub fn message(b: RenameBuilder, arena: Allocator, current: Issue) Error![]const u8 {
                const a = findPresent(current, b.id) orelse return error.AttachmentNotFound;
                const s: fmt.Spec = .{
                    .id = a.id,
                    .media = a.media,
                    .size = a.size,
                    .sha256 = a.sha256,
                    .name = b.name,
                };
                return trailers.build(arena, b.subject, b.body, &.{.{
                    .key = fmt.add_key,
                    .value = try std.fmt.allocPrint(arena, "{f}", .{s}),
                }});
            }
            // Names aren't in the derived tree, nothing else to update.
        };

        pub const Match = union(enum) {
            none,
            one: Attachment,
            many: []const Attachment,
        };

        /// Full ID or a prefix of at least 4 characters.
        pub fn find(arena: Allocator, issue: Issue, prefix: []const u8) Allocator.Error!Match {
            if (prefix.len < 4) return .none;
            var hits: std.ArrayList(Attachment) = .empty;
            for (issue.attachments) |a| {
                if (std.mem.startsWith(u8, a.id, prefix)) try hits.append(arena, a);
            }
            return switch (hits.items.len) {
                0 => .none,
                1 => .{ .one = hits.items[0] },
                else => .{ .many = hits.items },
            };
        }

        pub const Content = union(enum) {
            /// Checked against the trailer's hash and size.
            bytes: []const u8,
            /// Not in this clone yet, e.g. after a clone without
            /// `git lfs fetch`.
            missing,
            /// The stored bytes don't match the trailer.
            corrupt,
        };

        /// Tries our store, then git-lfs's (after a `git lfs fetch`), and
        /// copies what it finds there into ours.
        pub fn read(self: Self, arena: Allocator, a: Attachment) Error!Content {
            try requireLfs();
            const sha = a.sha256.slice();
            if (try self.lfsRead(arena, .issuez, sha)) |data| {
                return if (matches(a, data)) .{ .bytes = data } else .corrupt;
            }
            const data = (try self.lfsRead(arena, .git_lfs, sha)) orelse
                return .missing;
            if (!matches(a, data)) return .corrupt;
            try self.lfsWrite(.issuez, sha, data);
            return .{ .bytes = data };
        }

        pub const Availability = enum { local, missing, corrupt };

        pub const Entry = struct {
            attachment: Attachment,
            availability: Availability,
        };

        /// Reads each object once to check it.
        pub fn list(self: Self, arena: Allocator, issue: Issue) Error![]const Entry {
            const out = try arena.alloc(Entry, issue.attachments.len);
            for (issue.attachments, out) |a, *e| e.* = .{
                .attachment = a,
                .availability = switch (try self.read(arena, a)) {
                    .bytes => .local,
                    .missing => .missing,
                    .corrupt => .corrupt,
                },
            };
            return out;
        }

        pub fn derivedRefName(arena: Allocator, issue_id: []const u8) Allocator.Error![]const u8 {
            return std.fmt.allocPrint(arena, "{s}{s}", .{ ref_prefix, issue_id });
        }

        pub const DerivedState = enum {
            /// Matches, or there are no attachments and no ref.
            ok,
            /// Attachments but no derived ref, e.g. in a clone that only
            /// has upstream's refspec.
            absent,
            /// The tree doesn't match the attachments.
            stale,
        };

        pub fn derivedState(self: Self, arena: Allocator, issue: Issue) Error!DerivedState {
            const name = try derivedRefName(arena, issue.id);
            const tip = (try self.repo.backend.resolveRef(name)) orelse
                return if (issue.attachments.len == 0) .ok else .absent;
            const pointers = try pointersOf(arena, issue.attachments);
            const want = try self.treeFor(arena, pointers, .hash_only);
            const c = try self.readCommit(arena, tip) orelse return .stale;
            return if (c.tree.eql(want)) .ok else .stale;
        }

        /// Returns the new derived tip, or null when nothing was needed.
        /// Never touches the issue ref.
        pub fn repair(self: Self, arena: Allocator, issue: Issue) Error!?Oid {
            try requireLfs();
            if (try self.derivedState(arena, issue) == .ok) return null;
            const ops = try self.derivedUpdate(
                arena,
                issue.id,
                issue.tip,
                try pointersOf(arena, issue.attachments),
            );
            self.repo.backend.updateRefs(ops) catch |e| switch (e) {
                error.RefConflict => return error.ConcurrentModification,
                else => |x| return x,
            };
            return switch (ops[0].op) {
                .create => |o| o,
                .update => |u| u.new,
                else => unreachable,
            };
        }

        /// Stored objects no issue references, left by failed writes.
        pub fn orphans(
            self: Self,
            arena: Allocator,
            issues: []const Issue,
        ) Error![]const []const u8 {
            try requireLfs();
            var used: std.StringHashMapUnmanaged(void) = .empty;
            for (issues) |i| {
                for (i.attachments) |a| {
                    try used.put(arena, try arena.dupe(u8, a.sha256.slice()), {});
                }
                for (i.removed_attachments) |a| {
                    try used.put(arena, try arena.dupe(u8, a.sha256.slice()), {});
                }
            }
            var out: std.ArrayList([]const u8) = .empty;
            for (try self.lfsList(arena, .issuez)) |sha| {
                if (!used.contains(sha)) try out.append(arena, sha);
            }
            return out.items;
        }

        const Pointer = struct {
            id: []const u8,
            media: Media,
            size: u32,
            sha256: fmt.Sha256,

            fn fromAttachment(a: Attachment) Pointer {
                return .{ .id = a.id, .media = a.media, .size = a.size, .sha256 = a.sha256 };
            }
        };

        fn pointersOf(arena: Allocator, list_: []const Attachment) Allocator.Error![]const Pointer {
            const out = try arena.alloc(Pointer, list_.len);
            for (list_, out) |a, *p| p.* = .fromAttachment(a);
            return out;
        }

        /// `derivedState` only hashes: checking must not write objects.
        fn treeFor(
            self: Self,
            arena: Allocator,
            pointers: []const Pointer,
            mode: enum { write, hash_only },
        ) Error!Oid {
            const format = self.repo.backend.objectFormat();
            var entries: std.ArrayList(object.Tree.Entry) = .empty;
            for (pointers) |p| {
                const blob = try fmt.lfsPointer(arena, p.sha256, p.size);
                try entries.append(arena, .{
                    .name = try std.fmt.allocPrint(
                        arena,
                        "{s}.{s}",
                        .{ p.id, p.media.extension() },
                    ),
                    .oid = switch (mode) {
                        .write => try self.repo.backend.writeObject(.blob, blob),
                        .hash_only => object.hashObject(format, .blob, blob),
                    },
                });
            }
            const data = try object.Tree.serializeAlloc(arena, entries.items);
            return switch (mode) {
                .write => self.repo.backend.writeObject(.tree, data),
                .hash_only => object.hashObject(format, .tree, data),
            };
        }

        /// A fast-forward of `refs/attachments/<id>` to a commit for
        /// `pointers`.
        fn derivedUpdate(
            self: Self,
            arena: Allocator,
            issue_id: []const u8,
            issue_tip: Oid,
            pointers: []const Pointer,
        ) Error![]const contract.RefUpdate {
            const name = try derivedRefName(arena, issue_id);
            const old = try self.repo.backend.resolveRef(name);
            const parents: []const Oid = if (old) |o| &.{o} else &.{};
            const oid = try self.derivedCommit(arena, issue_id, issue_tip, pointers, parents);
            const ops = try arena.alloc(contract.RefUpdate, 1);
            ops[0] = .{ .name = name, .op = if (old) |o|
                .{ .update = .{ .new = oid, .old = o } }
            else
                .{ .create = oid } };
            return ops;
        }

        /// Fixed identity, dated like the issue tip, parents sorted by OID,
        /// so clones deriving the same state write the same commit.
        fn derivedCommit(
            self: Self,
            arena: Allocator,
            issue_id: []const u8,
            issue_tip: Oid,
            pointers: []const Pointer,
            parents_in: []const Oid,
        ) Error!Oid {
            const tree = try self.treeFor(arena, pointers, .write);
            const tip_commit = (try self.readCommit(arena, issue_tip)) orelse
                return error.CorruptIssue;
            const sig: Signature = .{
                .name = derived_identity_name,
                .email = derived_identity_email,
                .time = tip_commit.committer.time,
                .tz_offset_minutes = 0,
            };
            const hex = issue_tip.hex();
            const message = try std.fmt.allocPrint(
                arena,
                "{s}\n\nX-Issue: {s}\nX-Issue-Tip: {s}\n",
                .{ derived_subject, issue_id, hex.slice() },
            );
            const parents = try arena.dupe(Oid, parents_in);
            std.mem.sort(Oid, parents, {}, struct {
                fn lt(_: void, x: Oid, y: Oid) bool {
                    return x.order(y) == .lt;
                }
            }.lt);
            const c: object.Commit = .{
                .tree = tree,
                .parents = parents,
                .author = sig,
                .committer = sig,
                .message = message,
            };
            return self.repo.backend.writeObject(.commit, try c.serializeAlloc(arena));
        }

        /// Run by sync after merging the issue. Fast-forwards to the
        /// remote's derived ref when that one is right, so clones converge.
        /// Otherwise writes a commit on top of both tips, so the next push
        /// is a fast-forward. Returns whether the ref moved. Only needs
        /// pointers, not the LFS store.
        pub fn reconcile(
            self: Self,
            arena: Allocator,
            issue: Issue,
            remote_tip: ?Oid,
        ) Error!bool {
            const name = try derivedRefName(arena, issue.id);
            const pointers = try pointersOf(arena, issue.attachments);
            const want = try self.treeFor(arena, pointers, .hash_only);
            var attempt: u8 = 0;
            while (attempt < self.repo.limits.cas_retries) : (attempt += 1) {
                const local = try self.repo.backend.resolveRef(name);
                if (local == null and remote_tip == null and issue.attachments.len == 0 and
                    issue.removed_attachments.len == 0) return false;
                const local_ok = if (local) |l| try self.treeIs(arena, l, want) else false;
                const remote_in_local = if (remote_tip) |r| (if (local) |l|
                    r.eql(l) or try self.repo.backend.isAncestor(r, l)
                else
                    false) else true;
                if (local_ok and remote_in_local) return false;

                var target: Oid = undefined;
                const remote_ok = if (remote_tip) |r| try self.treeIs(arena, r, want) else false;
                const local_in_remote = if (local) |l| (if (remote_tip) |r|
                    try self.repo.backend.isAncestor(l, r)
                else
                    false) else true;
                if (remote_ok and local_in_remote) {
                    target = remote_tip.?;
                } else {
                    var parents: std.ArrayList(Oid) = .empty;
                    if (local) |l| try parents.append(arena, l);
                    if (remote_tip) |r| if (!remote_in_local) {
                        // The remote tip already contains ours.
                        if (local != null and local_in_remote) parents.clearRetainingCapacity();
                        try parents.append(arena, r);
                    };
                    target = try self.derivedCommit(
                        arena,
                        issue.id,
                        issue.tip,
                        pointers,
                        parents.items,
                    );
                }
                const op: contract.RefUpdate.Op = if (local) |l|
                    .{ .update = .{ .new = target, .old = l } }
                else
                    .{ .create = target };
                self.repo.backend.updateRefs(&.{.{ .name = name, .op = op }}) catch |e| switch (e) {
                    error.RefConflict => continue,
                    else => |x| return x,
                };
                return true;
            }
            return error.ConcurrentModification;
        }

        fn treeIs(self: Self, arena: Allocator, commit: Oid, tree: Oid) Error!bool {
            const c = (try self.readCommit(arena, commit)) orelse return false;
            return c.tree.eql(tree);
        }

        pub const FetchReport = struct {
            /// Here now and not before.
            fetched: usize,
            /// The remote's LFS server didn't have them.
            missing: []const Attachment,
        };

        /// `git lfs fetch <remote> refs/attachments/<id>` for every issue
        /// with missing bytes, then adopts them. LfsUnavailable without
        /// git-lfs.
        pub fn fetch(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            issues: []const Issue,
        ) (Error || contract.LfsTransportError)!FetchReport {
            try requireLfs();
            if (comptime !contract.hasLfsTransport(B)) return error.LfsUnavailable;
            var refs: std.ArrayList([]const u8) = .empty;
            var wanted: std.ArrayList(Attachment) = .empty;
            for (issues) |i| {
                var any = false;
                for (i.attachments) |a| if (try self.read(arena, a) == .missing) {
                    try wanted.append(arena, a);
                    any = true;
                };
                if (any) try refs.append(arena, try derivedRefName(arena, i.id));
            }
            if (refs.items.len == 0) return .{ .fetched = 0, .missing = &.{} };
            try self.repo.backend.lfsFetch(arena, remote, refs.items);
            var fetched: usize = 0;
            var missing: std.ArrayList(Attachment) = .empty;
            for (wanted.items) |a| switch (try self.read(arena, a)) {
                .bytes => fetched += 1,
                else => try missing.append(arena, a),
            };
            return .{ .fetched = fetched, .missing = missing.items };
        }

        /// Copies the bytes this clone has into git-lfs's store, so
        /// `git lfs push` finds them. Missing ones are skipped: whoever
        /// attached them uploaded them.
        pub fn uploads(self: Self, arena: Allocator, issues: []const Issue) Error![]const Upload {
            try requireLfs();
            var out: std.ArrayList(Upload) = .empty;
            for (issues) |i| next: for (i.attachments) |a| {
                const sha = a.sha256.slice();
                for (out.items) |u| if (std.mem.eql(u8, u.sha256, sha)) continue :next;
                const data = switch (try self.read(arena, a)) {
                    .bytes => |d| d,
                    else => continue :next,
                };
                if (try self.lfsRead(arena, .git_lfs, sha) == null)
                    try self.lfsWrite(.git_lfs, sha, data);
                try out.append(arena, .{
                    .sha256 = try arena.dupe(u8, sha),
                    .size = a.size,
                    .data = data,
                });
            };
            return out.items;
        }

        fn readCommit(self: Self, arena: Allocator, oid: Oid) Error!?object.Commit {
            const o = (try self.repo.backend.readObject(arena, oid)) orelse return null;
            if (o.kind != .commit) return null;
            return object.Commit.parse(arena, oid.object_format, o.data) catch null;
        }

        fn store(self: Self, sha: fmt.Sha256, data: []const u8) Error!void {
            return self.lfsWrite(.issuez, sha.slice(), data);
        }

        fn requireLfs() Error!void {
            if (comptime !contract.hasLfs(B)) return error.AttachmentsUnsupported;
        }

        // Wrapped so backends without LFS still compile.
        fn lfsRead(
            self: Self,
            arena: Allocator,
            s: contract.LfsStore,
            sha: []const u8,
        ) Error!?[]const u8 {
            if (comptime contract.hasLfs(B)) return self.repo.backend.lfsRead(arena, s, sha);
            return error.AttachmentsUnsupported;
        }

        fn lfsWrite(
            self: Self,
            s: contract.LfsStore,
            sha: []const u8,
            data: []const u8,
        ) Error!void {
            if (comptime contract.hasLfs(B)) return self.repo.backend.lfsWrite(s, sha, data);
            return error.AttachmentsUnsupported;
        }

        fn lfsList(self: Self, arena: Allocator, s: contract.LfsStore) Error![]const []const u8 {
            if (comptime contract.hasLfs(B)) return self.repo.backend.lfsList(arena, s);
            return error.AttachmentsUnsupported;
        }
    };
}

fn findPresent(issue: Issue, id: []const u8) ?Attachment {
    for (issue.attachments) |a| if (std.mem.eql(u8, a.id, id)) return a;
    return null;
}

fn matches(a: Attachment, data: []const u8) bool {
    return data.len == a.size and fmt.Sha256.of(data).eql(a.sha256);
}

const testing = std.testing;
const GitSim = @import("../backend/GitSim.zig");
const samples = fmt.samples;

fn latest(repo: repo_mod.Repo(GitSim), arena: Allocator, sim: *GitSim, name: []const u8) !Issue {
    return repo.load(arena, .{ .name = name, .tip = (try sim.resolveRef(name)).? });
}

test "add, read, rename, remove" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 61, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = repo_mod.Repo(GitSim).init(&sim);
    const att = Attachments(GitSim).fromRepo(repo);
    const created = try repo.create(arena, .{ .title = "Login broken" });
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});

    const added = try att.add(arena, ref, .{
        .files = &.{
            .{ .name = "/home/me/shot.png", .data = samples.png },
            .{ .name = "photo", .data = samples.jpeg, .media = .jpeg },
        },
        .comment = "The button is cut off.",
    });
    var issue = try latest(repo, arena, &sim, ref);
    try testing.expect(issue.tip.eql(added.tip));
    try testing.expectEqual(@as(usize, 2), issue.attachments.len);
    try testing.expectEqualStrings("shot.png", issue.attachments[0].name);
    const last = issue.comments[issue.comments.len - 1];
    try testing.expectEqualStrings("The button is cut off.", last.subject);
    try testing.expectEqual(@as(usize, 2), last.attachments.len);
    switch (try att.read(arena, issue.attachments[0])) {
        .bytes => |b| try testing.expectEqualStrings(samples.png, b),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(DerivedOk, try att.derivedState(arena, issue));

    // One LFS pointer per attachment.
    const dname = try Attachments(GitSim).derivedRefName(arena, issue.id);
    const dtip = (try sim.resolveRef(dname)).?;
    const dcommit = (try att.readCommit(arena, dtip)).?;
    const tree = (try sim.readObject(arena, dcommit.tree)).?;
    const entries = try object.Tree.parse(arena, .sha1, tree.data);
    try testing.expectEqual(@as(usize, 2), entries.len);
    const blob = (try sim.readObject(arena, entries[0].oid)).?;
    const header = "version https://git-lfs.github.com/spec/v1\n";
    try testing.expect(std.mem.startsWith(u8, blob.data, header));

    _ = try att.rename(arena, ref, added.ids[0], "login.png", .{});
    _ = try att.remove(arena, ref, &.{added.ids[1]}, .{});
    issue = try latest(repo, arena, &sim, ref);
    try testing.expectEqual(@as(usize, 1), issue.attachments.len);
    try testing.expectEqualStrings("login.png", issue.attachments[0].name);
    try testing.expectEqual(@as(usize, 1), issue.removed_attachments.len);
    try testing.expectEqual(DerivedOk, try att.derivedState(arena, issue));
    const dtip2 = (try sim.resolveRef(dname)).?;
    try testing.expect(try sim.isAncestor(dtip, dtip2)); // fast-forward

    const gone = att.remove(arena, ref, &.{added.ids[1]}, .{});
    try testing.expectError(error.AttachmentNotFound, gone);
    try testing.expectError(error.UnsupportedType, att.add(arena, ref, .{
        .files = &.{.{ .name = "x", .data = samples.text }},
    }));
    const animated = att.validate(.{ .name = "x", .data = samples.apng });
    try testing.expectError(error.AnimatedImage, animated);
    try testing.expectError(error.MediaMismatch, att.validate(.{
        .name = "x",
        .data = samples.png,
        .media = .webp,
    }));
    try testing.expectError(error.EmptyAttachment, att.validate(.{ .name = "x", .data = "" }));
    try testing.expectError(error.NoAttachments, att.add(arena, ref, .{ .files = &.{} }));
    const prefix = issue.attachments[0].id[0..6];
    try testing.expect(try Attachments(GitSim).find(arena, issue, prefix) == .one);
}

const DerivedOk = Attachments(GitSim).DerivedState.ok;

test "limits, missing bytes, repair, orphans" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 62, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    var repo = repo_mod.Repo(GitSim).init(&sim);
    repo.limits.max_attachments = 2;
    repo.limits.max_attachment_bytes = 64;
    const att = Attachments(GitSim).fromRepo(repo);
    const created = try repo.create(arena, .{ .title = "Shots" });
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});
    try testing.expectError(error.AttachmentTooLarge, att.validate(.{
        .name = "big",
        .data = samples.png ++ "\x00" ** 64,
    }));
    const one: Attachments(GitSim).Input = .{ .name = "a.png", .data = samples.png };
    _ = try att.add(arena, ref, .{ .files = &.{ one, one } });
    try testing.expectError(error.TooManyAttachments, att.add(arena, ref, .{ .files = &.{one} }));

    // Bytes only in git-lfs's store, as after a fresh clone and
    // `git lfs fetch`: read finds and adopts them.
    var issue = try latest(repo, arena, &sim, ref);
    const sha = issue.attachments[0].sha256.slice();
    for (sim.lfs.items) |*o| o.store = .git_lfs;
    switch (try att.read(arena, issue.attachments[0])) {
        .bytes => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(try sim.lfsRead(arena, .issuez, sha) != null);
    // Gone from both: missing, not an error.
    sim.lfs.clearRetainingCapacity();
    const entries = try att.list(arena, issue);
    try testing.expectEqual(Attachments(GitSim).Availability.missing, entries[0].availability);

    // A deleted derived ref comes back with repair, once.
    const dname = try Attachments(GitSim).derivedRefName(arena, issue.id);
    const dtip = (try sim.resolveRef(dname)).?;
    try sim.updateRefs(&.{.{ .name = dname, .op = .{ .delete = dtip } }});
    const state = try att.derivedState(arena, issue);
    try testing.expectEqual(Attachments(GitSim).DerivedState.absent, state);
    try testing.expect(try att.repair(arena, issue) != null);
    try testing.expect(try att.repair(arena, issue) == null);

    // An object written by a failed add is an orphan.
    try sim.lfsWrite(.issuez, fmt.Sha256.of(samples.webp).slice(), samples.webp);
    issue = try latest(repo, arena, &sim, ref);
    const orphans = try att.orphans(arena, &.{issue});
    try testing.expectEqual(@as(usize, 1), orphans.len);
}

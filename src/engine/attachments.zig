//! Images on issues, see docs/attachments.md.
//!
//! The trailers in the issue history are the source of truth. The bytes
//! live in our own LFS store, which `git lfs prune` doesn't touch.
//! git-lfs's store only holds copies for transfers. `refs/attachments/<id>`
//! lists the objects as LFS pointers so git-lfs and LFS servers see them.
//! It moves in the same transaction as the issue ref and can always be
//! rebuilt.
//!
//! The API takes and returns bytes, never paths. Everything that reads or
//! writes attachments needs git-lfs on backends that can run it, and fails
//! up front with LfsUnavailable without it (see `ready`).

const std = @import("std");
const stableSort = @import("../sort.zig").stable;
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

/// Whether this repository has an attachment's bytes, and whole.
pub const Availability = enum { local, missing, corrupt };

/// An attachment as `Attachments(B).list` sees it.
pub const Entry = struct {
    attachment: Attachment,
    availability: Availability,
};

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
pub const derived_identity_name = @import("sync.zig").merge_identity_name;
pub const derived_identity_email = @import("sync.zig").merge_identity_email;
pub const derived_subject = "Regenerate attachments";

/// The derived ref of an issue's attachments, `refs/attachments/<id>`.
pub fn refName(arena: Allocator, issue_id: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}", .{ ref_prefix, issue_id });
}

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
            /// A v4 UUID the caller chose, e.g. the host's ID for the
            /// upload. Null picks a random one.
            id: ?[]const u8 = null,
        };

        pub const AddSpec = struct {
            files: []const Input,
            /// Posted in the same commit as the images. Null gives an "Add
            /// attachment" commit; blank is `EmptyText`.
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

        /// LfsUnavailable when the backend can run git-lfs and it isn't
        /// installed. Every call below that reads or writes attachments
        /// checks it first; call it to refuse before reading any file.
        pub fn ready(self: Self, arena: Allocator) Error!void {
            if (comptime !contract.hasLfs(B)) return error.AttachmentsUnsupported;
            if (comptime contract.hasLfsTransport(B)) {
                if (!try self.repo.backend.lfsAvailable(arena)) return error.LfsUnavailable;
            }
        }

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
        /// `options` as for `Repo.update`; a dry run stores no bytes.
        pub fn add(
            self_in: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            spec: AddSpec,
            options: repo_mod.WriteOptions,
        ) Error!Added {
            const self = self_in.withOptions(options);
            const ref_name = try repo_mod.refFor(arena, repo_mod.issue_ref_prefix, ref_or_id);
            try self.ready(arena);
            if (spec.files.len == 0) return error.NoAttachments;
            const specs = try arena.alloc(fmt.Spec, spec.files.len);
            const ids = try arena.alloc([]const u8, spec.files.len);
            for (spec.files, specs, ids) |f, *s, *id| {
                s.* = try self.prepare(arena, f);
                id.* = s.id;
            }
            var tl: std.ArrayList(trailers.Trailer) = .empty;
            for (specs) |s| try tl.append(arena, .{
                .key = fmt.add_key,
                .value = try std.fmt.allocPrint(arena, "{f}", .{s}),
            });
            if (spec.comment) |c| try repo_mod.checkNotBlank(c);
            try self.checkMessage(spec.comment);
            const text = spec.comment orelse
                (if (specs.len == 1) "Add attachment" else "Add attachments");
            const split = repo_mod.splitMessage(text);
            const message = try trailers.build(arena, split.subject, split.body, tl.items);
            // Bytes before the commit, so a failed commit leaves at most an
            // object nobody references (see `orphans`).
            if (!self.repo.call.dry_run) for (spec.files, specs) |f, s| try self.store(
                s.sha256,
                f.data,
            );
            const builder: Builder = .{ .self = self, .text = message, .added = specs };
            const repo = self.repo;
            const tip = try repo.appendIssue(arena, ref_name, spec.author, spec.expect, builder);
            return .{ .tip = tip, .ids = ids };
        }

        /// The size of a message or comment the caller gave. A blank
        /// `remove`/`rename` message gives the default; `add` refuses a
        /// blank comment, as `Repo.comment` does.
        fn checkMessage(self: Self, text: ?[]const u8) Error!void {
            const t = text orelse return;
            if (t.len > self.repo.limits.max_body_bytes) return error.TooLong;
        }

        /// The attachments with `options` for their next write.
        fn withOptions(self: Self, options: repo_mod.WriteOptions) Self {
            var me = self;
            me.repo = self.repo.withOptions(options);
            return me;
        }

        /// The bytes stay, since history still references them. `options`
        /// as for `Repo.update`.
        pub fn remove(
            self_in: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            ids: []const []const u8,
            spec: ChangeSpec,
            options: repo_mod.WriteOptions,
        ) Error!Oid {
            const self = self_in.withOptions(options);
            const ref_name = try repo_mod.refFor(arena, repo_mod.issue_ref_prefix, ref_or_id);
            try self.ready(arena);
            if (ids.len == 0) return error.NoAttachments;
            var tl: std.ArrayList(trailers.Trailer) = .empty;
            for (ids) |id| {
                if (!uuid_fmt.isCanonical(id)) return error.AttachmentNotFound;
                try tl.append(arena, .{ .key = fmt.remove_key, .value = id });
            }
            try self.checkMessage(spec.message);
            const subject = repo_mod.givenMessage(spec.message) orelse
                (if (ids.len == 1) "Remove attachment" else "Remove attachments");
            const split = repo_mod.splitMessage(subject);
            return self.repo.appendIssue(arena, ref_name, spec.author, spec.expect, Builder{
                .self = self,
                .text = try trailers.build(arena, split.subject, split.body, tl.items),
                .removed = ids,
            });
        }

        /// A new `X-Attachment` with the same object. `options` as for
        /// `Repo.update`.
        pub fn rename(
            self_in: Self,
            arena: Allocator,
            ref_or_id: []const u8,
            id: []const u8,
            name: []const u8,
            spec: ChangeSpec,
            options: repo_mod.WriteOptions,
        ) Error!Oid {
            const self = self_in.withOptions(options);
            const ref_name = try repo_mod.refFor(arena, repo_mod.issue_ref_prefix, ref_or_id);
            try self.ready(arena);
            const clean = try fmt.sanitizeName(arena, name);
            try self.checkMessage(spec.message);
            const split = repo_mod.splitMessage(
                repo_mod.givenMessage(spec.message) orelse "Rename attachment",
            );
            return self.repo.appendIssue(arena, ref_name, spec.author, spec.expect, RenameBuilder{
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
                const changes: repo_mod.AttachmentChanges = .{
                    .add = b.added,
                    .remove = b.removed,
                };
                try changes.check(current, b.self.repo.limits);
                return b.text;
            }

            pub fn after(
                b: Builder,
                arena: Allocator,
                current: Issue,
                new_tip: Oid,
            ) Error![]const contract.RefUpdate {
                return b.self.derivedAfter(
                    arena,
                    current.id,
                    current.attachments,
                    new_tip,
                    b.added,
                    b.removed,
                );
            }
        };

        /// What a write that adds or removes attachments without storing
        /// bytes needs: validated, hashed, named, with the given ID or a
        /// random one. The bytes go to `storeBytes`, or the caller keeps
        /// them (a host with its own LFS store).
        pub fn prepare(self: Self, arena: Allocator, input: Input) Error!fmt.Spec {
            const media = try self.validate(input);
            const id = if (input.id) |given| blk: {
                if (!uuid_fmt.isCanonical(given)) return error.InvalidValue;
                break :blk try arena.dupe(u8, given);
            } else blk: {
                var random: [16]u8 = undefined;
                self.repo.backend.randomBytes(&random);
                const uuid = uuid_fmt.Uuid.fromRandom(random);
                break :blk try arena.dupe(u8, uuid.slice());
            };
            return .{
                .id = id,
                .media = media,
                .size = @intCast(input.data.len),
                .sha256 = fmt.Sha256.of(input.data),
                .name = try fmt.sanitizeName(arena, input.name),
            };
        }

        /// The bytes of a prepared attachment, into this tool's store.
        pub fn storeBytes(
            self: Self,
            arena: Allocator,
            spec: fmt.Spec,
            data: []const u8,
        ) Error!void {
            try self.ready(arena);
            try self.store(spec.sha256, data);
        }

        /// Internal: the library's own plumbing, not API; it may change.
        /// The derived ref's update for a write that adds and removes
        /// attachments of issue `issue_id` (which had `before`) at
        /// `new_tip`, in the same transaction.
        pub fn derivedAfter(
            self: Self,
            arena: Allocator,
            issue_id: []const u8,
            before: []const Attachment,
            new_tip: Oid,
            added: []const fmt.Spec,
            removed: []const []const u8,
        ) Error![]const contract.RefUpdate {
            var present: std.ArrayList(Pointer) = .empty;
            for (before) |a| {
                if (labels_fmt.contains(removed, a.id)) continue;
                try present.append(arena, .fromAttachment(a));
            }
            for (added) |s| try present.append(arena, .{
                .id = s.id,
                .media = s.media,
                .size = s.size,
                .sha256 = s.sha256,
            });
            return self.derivedUpdate(arena, issue_id, new_tip, present.items);
        }

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

        /// The backend's store. GitProcess also looks in git-lfs's store
        /// (after a `git lfs fetch`) and copies a good copy found there
        /// into its own, over a damaged one.
        pub fn read(self: Self, arena: Allocator, a: Attachment) Error!Content {
            try self.ready(arena);
            return self.readStored(arena, a);
        }

        fn readStored(self: Self, arena: Allocator, a: Attachment) Error!Content {
            const data = (try self.lfsRead(arena, a.sha256.slice())) orelse return .missing;
            return if (matches(a, data)) .{ .bytes = data } else .corrupt;
        }

        pub const ListOptions = struct {
            /// Read and hash every object. Otherwise an object of the
            /// right size counts as `local` (when the backend can tell
            /// the size without reading it).
            verify: bool = false,
        };

        pub fn list(
            self: Self,
            arena: Allocator,
            issue: Issue,
            options: ListOptions,
        ) Error![]const Entry {
            try self.ready(arena);
            const out = try arena.alloc(Entry, issue.attachments.len);
            for (issue.attachments, out) |a, *e| e.* = .{
                .attachment = a,
                .availability = if (!options.verify and try self.lfsSize(a) == a.size)
                    .local
                else switch (try self.readStored(arena, a)) {
                    .bytes => .local,
                    .missing => .missing,
                    .corrupt => .corrupt,
                },
            };
            return out;
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
            const name = try refName(arena, issue.id);
            const tip = (try self.repo.backend.resolveRef(name)) orelse
                return if (issue.attachments.len == 0) .ok else .absent;
            const pointers = try pointersOf(arena, issue.attachments);
            const want = try self.treeFor(arena, pointers, .hash_only);
            const c = try self.readCommit(arena, tip) orelse return .stale;
            return if (c.tree.eql(want)) .ok else .stale;
        }

        /// Brings the derived ref in line with the issue. Returns whether
        /// it moved. Never touches the issue ref.
        pub fn repair(self: Self, arena: Allocator, issue: Issue) Error!bool {
            try self.ready(arena);
            return self.reconcile(arena, issue, null);
        }

        /// Stored objects no issue references, left by failed writes.
        pub fn orphans(
            self: Self,
            arena: Allocator,
            issues: []const Issue,
        ) Error![]const []const u8 {
            try self.ready(arena);
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
            for (try self.lfsList(arena)) |sha| {
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
            const name = try refName(arena, issue_id);
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
            const c = try derivedCommitOf(
                arena,
                issue_id,
                issue_tip,
                tip_commit.committer.time,
                tree,
                parents_in,
            );
            return self.repo.backend.writeObject(.commit, try c.serializeAlloc(arena));
        }

        /// Internal: the library's own plumbing, not API; it may change.
        /// The tree `attachments` derive, hashed only: checking must not
        /// write objects.
        pub fn derivedTree(
            self: Self,
            arena: Allocator,
            attachments: []const Attachment,
        ) Error!Oid {
            return self.treeFor(arena, try pointersOf(arena, attachments), .hash_only);
        }

        /// Internal: the library's own plumbing, not API; it may change.
        /// Run by sync after merging the issue. Fast-forwards to the
        /// remote's derived ref when that one is right, so clones converge.
        /// Otherwise writes a commit on top of both tips, so the next push
        /// is a fast-forward. Returns whether the ref moved. Only needs
        /// pointers, not the LFS store.
        pub fn reconcile(
            self: Self,
            arena: Allocator,
            issue: Issue,
            remote_tip_in: ?Oid,
        ) Error!bool {
            // Anyone can push anything there. What isn't a commit is
            // ignored, and the next push replaces it.
            const remote_tip = if (remote_tip_in) |r|
                (if (try self.readCommit(arena, r) != null) r else null)
            else
                null;
            const name = try refName(arena, issue.id);
            const pointers = try pointersOf(arena, issue.attachments);
            const want = try self.treeFor(arena, pointers, .hash_only);
            var attempt: u8 = 0;
            while (attempt < self.repo.limits.cas_retries) : (attempt += 1) {
                const local = try self.repo.backend.resolveRef(name);
                if (local == null and remote_tip == null and issue.attachments.len == 0 and
                    issue.removed_attachments.len == 0) return false;
                // Also regenerated when the tip it names left the issue's
                // history (a replaced history): a push check refuses it.
                const local_ok = if (local) |l|
                    try self.treeIs(arena, l, want) and try self.namesTipIn(arena, l, issue.tip)
                else
                    false;
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

        /// Whether the derived commit's `X-Issue-Tip` is in the history of
        /// `issue_tip`.
        fn namesTipIn(self: Self, arena: Allocator, derived: Oid, issue_tip: Oid) Error!bool {
            const c = (try self.readCommit(arena, derived)) orelse return false;
            const block = try trailers.parse(arena, c.message, .{});
            const hex = trailers.lastValue(block, "X-Issue-Tip") orelse return false;
            const tip = Oid.parseHex(issue_tip.object_format, hex) catch return false;
            if (tip.eql(issue_tip)) return true;
            if (try self.readCommit(arena, tip) == null) return false;
            return self.repo.backend.isAncestor(tip, issue_tip);
        }

        fn treeIs(self: Self, arena: Allocator, commit: Oid, tree: Oid) Error!bool {
            const c = (try self.readCommit(arena, commit)) orelse return false;
            return c.tree.eql(tree);
        }

        pub const FetchReport = struct {
            /// Here now and not before.
            fetched: usize,
            /// Still not here: the remote's LFS server didn't have them, or
            /// the transfer failed.
            missing: []const Attachment,
            /// git-lfs failed for some of them. The backend's last error
            /// output says why.
            transfer_failed: bool = false,
        };

        /// `git lfs fetch <remote> refs/attachments/<id>` for every issue
        /// with missing bytes, then adopts them. git-lfs reads the pointers
        /// from there, so when that ref is missing or out of date it gets
        /// a derived commit for the issue as it is instead. That commit is
        /// written as objects only: fetching never moves a ref.
        pub fn fetch(
            self: Self,
            arena: Allocator,
            remote: []const u8,
            issues: []const Issue,
        ) (Error || contract.LfsTransportError || error{InvalidRemoteName})!FetchReport {
            try self.ready(arena);
            if (comptime !contract.hasLfsTransport(B)) return error.LfsUnavailable;
            if (!contract.isValidRemoteName(remote)) return error.InvalidRemoteName;
            var refs: std.ArrayList([]const u8) = .empty;
            var wanted: std.ArrayList(Attachment) = .empty;
            for (issues) |i| {
                var any = false;
                for (i.attachments) |a| if (try self.readStored(arena, a) != .bytes) {
                    try wanted.append(arena, a);
                    any = true;
                };
                if (!any) continue;
                const name = try refName(arena, i.id);
                if (try self.derivedState(arena, i) == .ok) {
                    try refs.append(arena, name);
                    continue;
                }
                const old = try self.repo.backend.resolveRef(name);
                const parents: []const Oid = if (old) |o| &.{o} else &.{};
                const pointers = try pointersOf(arena, i.attachments);
                const oid = try self.derivedCommit(arena, i.id, i.tip, pointers, parents);
                try refs.append(arena, try oid.hexAlloc(arena));
            }
            if (refs.items.len == 0) return .{ .fetched = 0, .missing = &.{} };
            var failed = false;
            self.repo.backend.lfsFetch(arena, remote, refs.items) catch |e| switch (e) {
                error.LfsTransferFailed => failed = true,
                else => |x| return x,
            };
            var fetched: usize = 0;
            var missing: std.ArrayList(Attachment) = .empty;
            for (wanted.items) |a| switch (try self.readStored(arena, a)) {
                .bytes => fetched += 1,
                else => try missing.append(arena, a),
            };
            return .{ .fetched = fetched, .missing = missing.items, .transfer_failed = failed };
        }

        /// Internal: the library's own plumbing, not API; it may change.
        /// IDs of the attachments a derived commit lists, e.g. what the
        /// remote's derived ref already has.
        pub fn derivedIds(self: Self, arena: Allocator, tip: Oid) Error![]const []const u8 {
            const c = (try self.readCommit(arena, tip)) orelse return &.{};
            const t = (try self.repo.backend.readObject(arena, c.tree)) orelse return &.{};
            if (t.kind != .tree) return &.{};
            const entries = object.Tree.parse(arena, c.tree.object_format, t.data) catch
                return &.{};
            var out: std.ArrayList([]const u8) = .empty;
            for (entries) |e| {
                const dot = std.mem.findScalar(u8, e.name, '.') orelse continue;
                try out.append(arena, e.name[0..dot]);
            }
            return out.items;
        }

        /// Internal: the library's own plumbing, not API; it may change.
        /// The bytes this clone has of `list`, deduplicated. Missing ones
        /// are skipped: whoever attached them uploaded them.
        pub fn uploads(
            self: Self,
            arena: Allocator,
            list_: []const Attachment,
        ) Error![]const Upload {
            try requireStore();
            var out: std.ArrayList(Upload) = .empty;
            next: for (list_) |a| {
                const sha = a.sha256.slice();
                for (out.items) |u| if (std.mem.eql(u8, u.sha256, sha)) continue :next;
                const data = switch (try self.readStored(arena, a)) {
                    .bytes => |d| d,
                    else => continue :next,
                };
                try out.append(arena, .{
                    .sha256 = try arena.dupe(u8, sha),
                    .size = a.size,
                    .data = data,
                });
            }
            return out.items;
        }

        fn readCommit(self: Self, arena: Allocator, oid: Oid) Error!?object.Commit {
            const o = (try self.repo.backend.readObject(arena, oid)) orelse return null;
            if (o.kind != .commit) return null;
            return object.Commit.parse(arena, oid.object_format, o.data) catch null;
        }

        fn store(self: Self, sha: fmt.Sha256, data: []const u8) Error!void {
            return self.lfsWrite(sha.slice(), data);
        }

        fn requireStore() Error!void {
            if (comptime !contract.hasLfs(B)) return error.AttachmentsUnsupported;
        }

        // Wrapped so backends without LFS still compile.
        fn lfsRead(self: Self, arena: Allocator, sha: []const u8) Error!?[]const u8 {
            if (comptime contract.hasLfs(B)) return self.repo.backend.lfsRead(arena, sha);
            return error.AttachmentsUnsupported;
        }

        fn lfsWrite(self: Self, sha: []const u8, data: []const u8) Error!void {
            if (comptime contract.hasLfs(B)) return self.repo.backend.lfsWrite(sha, data);
            return error.AttachmentsUnsupported;
        }

        fn lfsList(self: Self, arena: Allocator) Error![]const []const u8 {
            if (comptime contract.hasLfs(B)) return self.repo.backend.lfsList(arena);
            return error.AttachmentsUnsupported;
        }

        /// Null when the backend can't tell without reading.
        fn lfsSize(self: Self, a: Attachment) Error!?u64 {
            if (comptime contract.hasLfsSize(B))
                return self.repo.backend.lfsSize(a.sha256.slice());
            return null;
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

/// Internal: the library's own plumbing, not API; it may change.
/// The derived commit for an issue tip (§7): fixed identity, dated like
/// the tip (`tip_time`), parents sorted by OID.
pub fn derivedCommitOf(
    arena: Allocator,
    issue_id: []const u8,
    issue_tip: Oid,
    tip_time: i64,
    tree: Oid,
    parents_in: []const Oid,
) Allocator.Error!object.Commit {
    const sig: Signature = .{
        .name = derived_identity_name,
        .email = derived_identity_email,
        .time = tip_time,
        .tz_offset_minutes = 0,
    };
    const hex = issue_tip.hex();
    const message = try std.fmt.allocPrint(
        arena,
        "{s}\n\nX-Issue: {s}\nX-Issue-Tip: {s}\n",
        .{ derived_subject, issue_id, hex.slice() },
    );
    const parents = try arena.dupe(Oid, parents_in);
    stableSort(Oid, parents, {}, struct {
        fn lt(_: void, x: Oid, y: Oid) bool {
            return x.order(y) == .lt;
        }
    }.lt);
    return .{
        .tree = tree,
        .parents = parents,
        .author = sig,
        .committer = sig,
        .message = message,
    };
}

test "add, read, rename, remove" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 61, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = repo_mod.Repo(GitSim).init(&sim);
    const att = Attachments(GitSim).fromRepo(repo);
    const created = try repo.create(arena, .{ .title = "Login broken" }, .{});
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});

    const added = try att.add(arena, ref, .{
        .files = &.{
            .{ .name = "/home/me/shot.png", .data = samples.png },
            .{ .name = "photo", .data = samples.jpeg, .media = .jpeg },
        },
        .comment = "The button is cut off.",
    }, .{});
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
    const dname = try refName(arena, issue.id);
    const dtip = (try sim.resolveRef(dname)).?;
    const dcommit = (try att.readCommit(arena, dtip)).?;
    const tree = (try sim.readObject(arena, dcommit.tree)).?;
    const entries = try object.Tree.parse(arena, .sha1, tree.data);
    try testing.expectEqual(@as(usize, 2), entries.len);
    const blob = (try sim.readObject(arena, entries[0].oid)).?;
    const header = "version https://git-lfs.github.com/spec/v1\n";
    try testing.expect(std.mem.startsWith(u8, blob.data, header));

    _ = try att.rename(arena, ref, added.ids[0], "login.png", .{}, .{});
    _ = try att.remove(arena, ref, &.{added.ids[1]}, .{}, .{});
    issue = try latest(repo, arena, &sim, ref);
    try testing.expectEqual(@as(usize, 1), issue.attachments.len);
    try testing.expectEqualStrings("login.png", issue.attachments[0].name);
    try testing.expectEqual(@as(usize, 1), issue.removed_attachments.len);
    try testing.expectEqual(DerivedOk, try att.derivedState(arena, issue));
    const dtip2 = (try sim.resolveRef(dname)).?;
    try testing.expect(try sim.isAncestor(dtip, dtip2)); // fast-forward

    const gone = att.remove(arena, ref, &.{added.ids[1]}, .{}, .{});
    try testing.expectError(error.AttachmentNotFound, gone);
    try testing.expectError(error.UnsupportedType, att.add(arena, ref, .{
        .files = &.{.{ .name = "x", .data = samples.text }},
    }, .{}));
    const animated = att.validate(.{ .name = "x", .data = samples.apng });
    try testing.expectError(error.AnimatedImage, animated);
    try testing.expectError(error.MediaMismatch, att.validate(.{
        .name = "x",
        .data = samples.png,
        .media = .webp,
    }));
    try testing.expectError(error.EmptyAttachment, att.validate(.{ .name = "x", .data = "" }));
    try testing.expectError(error.NoAttachments, att.add(arena, ref, .{ .files = &.{} }, .{}));
    try testing.expectError(error.EmptyText, att.add(arena, ref, .{
        .files = &.{.{ .name = "a.png", .data = samples.png }},
        .comment = " \n ",
    }, .{}));

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
    const created = try repo.create(arena, .{ .title = "Shots" }, .{});
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    try testing.expectError(error.AttachmentTooLarge, att.validate(.{
        .name = "big",
        .data = samples.png ++ "\x00" ** 64,
    }));
    const one: Attachments(GitSim).Input = .{ .name = "a.png", .data = samples.png };
    _ = try att.add(arena, ref, .{ .files = &.{ one, one } }, .{});
    try testing.expectError(
        error.TooManyAttachments,
        att.add(arena, ref, .{ .files = &.{one} }, .{}),
    );

    // Bytes only in git-lfs's store, as after a fresh clone and
    // `git lfs fetch`: read finds and adopts them.
    var issue = try latest(repo, arena, &sim, ref);
    const sha = issue.attachments[0].sha256.slice();
    for (sim.lfs.items) |*o| o.store = .git_lfs;
    switch (try att.read(arena, issue.attachments[0])) {
        .bytes => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(try sim.lfsSize(sha) != null);
    // Damaged at the same size: only a verifying list reads and sees it.

    for (sim.lfs.items) |*o| {
        const bad = try arena.dupe(u8, o.data);
        bad[bad.len - 1] ^= 1;
        o.data = bad;
    }
    try testing.expectEqual(Availability.local, (try att.list(arena, issue, .{}))[0].availability);
    const verified = try att.list(arena, issue, .{ .verify = true });
    try testing.expectEqual(Availability.corrupt, verified[0].availability);
    // Gone from both: missing, not an error.
    sim.lfs.clearRetainingCapacity();
    const entries = try att.list(arena, issue, .{});
    try testing.expectEqual(Availability.missing, entries[0].availability);

    // A deleted derived ref comes back with repair, once.
    const dname = try refName(arena, issue.id);
    const dtip = (try sim.resolveRef(dname)).?;
    try sim.updateRefs(&.{.{ .name = dname, .op = .{ .delete = dtip } }});
    const state = try att.derivedState(arena, issue);
    try testing.expectEqual(Attachments(GitSim).DerivedState.absent, state);
    try testing.expect(try att.repair(arena, issue));
    try testing.expect(!try att.repair(arena, issue));

    // An object written by a failed add is an orphan.
    try sim.lfsWrite(fmt.Sha256.of(samples.webp).slice(), samples.webp);
    issue = try latest(repo, arena, &sim, ref);
    const orphans = try att.orphans(arena, &.{issue});
    try testing.expectEqual(@as(usize, 1), orphans.len);
}

test "attachments in the commit of a write, bytes kept by the caller" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 63, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = repo_mod.Repo(GitSim).init(&sim);
    const att = Attachments(GitSim).fromRepo(repo);
    const host_id = "5b0c4e0e-2b8a-4f5e-9d39-6c1c1f0f2a77";
    try testing.expectError(error.InvalidValue, att.prepare(arena, .{
        .name = "a.png",
        .data = samples.png,
        .id = "not-a-uuid",
    }));

    // On the root: the description's image, with the host's ID. Nothing
    // is stored: the host keeps the bytes.
    const shot = try att.prepare(
        arena,
        .{ .name = "shot.png", .data = samples.png, .id = host_id },
    );
    try testing.expectEqualStrings(host_id, shot.id);
    try testing.expectError(error.AttachmentExists, repo.create(arena, .{
        .title = "Twice",
        .attachments = &.{ shot, shot },
    }, .{}));
    const created = try repo.create(
        arena,
        .{ .title = "Login broken", .attachments = &.{shot} },
        .{},
    );
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    var issue = try latest(repo, arena, &sim, ref);
    try testing.expectEqual(@as(usize, 1), issue.attachments.len);
    try testing.expect(issue.attachments[0].added_in.eql(created.tip));
    try testing.expectEqual(DerivedOk, try att.derivedState(arena, issue));
    try testing.expectEqual(@as(usize, 0), sim.lfs.items.len);
    try testing.expect(try att.read(arena, issue.attachments[0]) == .missing);

    // A comment with an image, in one commit.
    const photo = try att.prepare(arena, .{ .name = "photo.jpg", .data = samples.jpeg });
    try att.storeBytes(arena, photo, samples.jpeg);
    const commented = try repo.edit(arena, ref, .{
        .comment = "Here it is.",
        .attachments = .{ .add = &.{photo} },
    }, .{});
    issue = try latest(repo, arena, &sim, ref);
    const c = issue.comments[issue.comments.len - 1];
    try testing.expect(c.oid.eql(commented.tip));
    try testing.expectEqualStrings("Here it is.", c.subject);
    try testing.expectEqual(@as(usize, 1), c.attachments.len);
    try testing.expectEqual(DerivedOk, try att.derivedState(arena, issue));
    try testing.expectError(error.AttachmentExists, repo.edit(arena, ref, .{
        .attachments = .{ .add = &.{shot} },
    }, .{}));

    // A comment edit swaps its image; a description edit drops the root's.
    const webp = try att.prepare(arena, .{ .name = "better.webp", .data = samples.webp });
    _ = try repo.commentEvent(
        arena,
        ref,
        .{
            .target = commented.tip,
            .event = .edit,
            .text = "Here it is, sharper.",
            .attachments = .{ .add = &.{webp}, .remove = &.{photo.id} },
        },
        .{},
    );
    try testing.expectError(
        error.InvalidValue,
        repo.commentEvent(
            arena,
            ref,
            .{
                .target = commented.tip,
                .event = .delete,
                .attachments = .{ .remove = &.{webp.id} },
            },
            .{},
        ),
    );
    _ = try repo.edit(arena, ref, .{
        .description = "No image any more.",
        .attachments = .{ .remove = &.{host_id} },
    }, .{});
    issue = try latest(repo, arena, &sim, ref);
    try testing.expectEqual(@as(usize, 1), issue.attachments.len);
    try testing.expectEqualStrings("better.webp", issue.attachments[0].name);
    try testing.expectEqual(@as(usize, 2), issue.removed_attachments.len);
    try testing.expectEqualStrings("Edit description", try trailers.subject(
        arena,
        (try att.readCommit(arena, issue.tip)).?.message,
    ));
    try testing.expectEqual(DerivedOk, try att.derivedState(arena, issue));
    try testing.expectError(error.AttachmentNotFound, repo.edit(arena, ref, .{
        .attachments = .{ .remove = &.{host_id} },
    }, .{}));

    // Alone: the subjects `add` and `remove` write.
    const alone = try repo.edit(arena, ref, .{ .attachments = .{ .remove = &.{webp.id} } }, .{});
    try testing.expectEqualStrings("Remove attachment", try trailers.subject(
        arena,
        (try att.readCommit(arena, alone.tip)).?.message,
    ));
    issue = try latest(repo, arena, &sim, ref);
    try testing.expectEqual(@as(usize, 0), issue.attachments.len);
    try testing.expectEqual(DerivedOk, try att.derivedState(arena, issue));
}

test "add, remove, rename: a dry run stores no bytes and writes nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 62, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = repo_mod.Repo(GitSim).init(&sim);
    const att = Attachments(GitSim).fromRepo(repo);
    const created = try repo.create(arena, .{ .title = "Shots" }, .{});
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id});
    const files = [_]Attachments(GitSim).Input{.{ .name = "shot.png", .data = samples.png }};

    const dry = try att.add(arena, ref, .{ .files = &files }, .{ .dry_run = true });
    try testing.expectEqual(@as(usize, 1), dry.ids.len);
    try testing.expect(created.tip.eql((try sim.resolveRef(ref)).?));
    const sha = fmt.Sha256.of(samples.png);
    try testing.expect(try sim.lfsRead(arena, sha.slice()) == null);

    const ada = "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d";
    const added = try att.add(arena, ref, .{ .files = &files }, .{ .author_id = ada });
    const tip = try att.rename(arena, ref, added.ids[0], "s.png", .{}, .{ .dry_run = true });
    try testing.expect(added.tip.eql((try sim.resolveRef(ref)).?));
    try testing.expect(!tip.eql(added.tip));
    _ = try att.remove(arena, ref, added.ids, .{}, .{ .dry_run = true });
    try testing.expect(added.tip.eql((try sim.resolveRef(ref)).?));
    const issue = try repo.load(arena, .{ .name = ref, .tip = added.tip });
    try testing.expectEqualStrings(ada, issue_model.authorIdAt(issue.author_ids, added.tip).?);
}

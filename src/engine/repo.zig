//! Reading and writing issues through a backend.
//!
//! Every write reads the tip, builds a new commit on top of it and moves
//! the ref only if it still points at that tip. If it moved, we start over
//! from the new tip. We never just re-point the old commit at the new
//! tip, which is how upstream's retry can lose a concurrent edit.

const std = @import("std");
const Allocator = std.mem.Allocator;
const contract = @import("../backend/contract.zig");
const object = @import("../backend/object.zig");
const trailers = @import("../format/trailers.zig");
const labels_fmt = @import("../format/labels.zig");
const uuid_fmt = @import("../format/uuid.zig");
const core_fmt = @import("../format/core.zig");
const issue_model = @import("../model/issue.zig");

pub const Issue = issue_model.Issue;
pub const Oid = object.Oid;
pub const Signature = object.Signature;

pub const issue_ref_prefix = "refs/issues/";

pub const Limits = struct {
    /// No truncation: more commits than this is an error.
    max_commits_per_issue: u32 = 10_000,
    /// Use `loadPage` beyond this.
    max_issues: u32 = 100_000,
    page_size: u32 = 1_000,
    cas_retries: u8 = 8,
    max_title_bytes: u32 = 1024,
    max_body_bytes: u32 = 1024 * 1024,
    max_trailer_value_bytes: u32 = 4096,
    max_labels: u16 = 64,

    /// So no limit can be raised to the point of meaning nothing.
    pub const maximum: Limits = .{
        .max_commits_per_issue = 1_000_000,
        .max_issues = 10_000_000,
        .page_size = 100_000,
        .cas_retries = 64,
        .max_title_bytes = 64 * 1024,
        .max_body_bytes = 64 * 1024 * 1024,
        .max_trailer_value_bytes = 64 * 1024,
        .max_labels = 4096,
    };

    pub fn valid(l: Limits) bool {
        inline for (std.meta.fields(Limits)) |f| {
            const v = @field(l, f.name);
            if (v == 0 or v > @field(maximum, f.name)) return false;
        }
        return true;
    }

    comptime {
        std.debug.assert((Limits{}).valid());
    }
};

pub const IssueRef = struct {
    name: []const u8,
    tip: Oid,

    pub fn id(r: IssueRef) []const u8 {
        const slash = std.mem.findScalarLast(u8, r.name, '/') orelse return r.name;
        return r.name[slash + 1 ..];
    }
};

pub const Resolution = union(enum) {
    none,
    one: IssueRef,
    many: []const IssueRef,
};

pub const CreateSpec = struct {
    title: []const u8,
    body: []const u8 = "",
    labels: []const []const u8 = &.{},
    assignee: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    milestone: ?[]const u8 = null,
    /// Overrides the backend's identity.
    author: ?Signature = null,
};

/// Every spec has `expect`: the tip the caller based the change on (an
/// ETag, say). If the issue has changed since, the write fails with
/// VersionMismatch instead of being applied on top.
pub const CommentSpec = struct {
    text: []const u8,
    author: ?Signature = null,
    expect: ?Oid = null,
};

pub const StateSpec = struct {
    state: []const u8,
    /// Defaults to "Close issue", "Reopen issue", ...
    message: ?[]const u8 = null,
    fixed_by: ?[]const u8 = null,
    release: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    author: ?Signature = null,
    expect: ?Oid = null,
};

pub const EditSpec = struct {
    title: ?[]const u8 = null,
    /// Replaces the labels.
    set_labels: ?[]const []const u8 = null,
    add_labels: []const []const u8 = &.{},
    remove_labels: []const []const u8 = &.{},
    /// Empty clears it.
    assignee: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    milestone: ?[]const u8 = null,
    message: ?[]const u8 = null,
    author: ?Signature = null,
    expect: ?Oid = null,

    pub fn isEmpty(spec: EditSpec) bool {
        return spec.title == null and spec.set_labels == null and spec.add_labels.len == 0 and
            spec.remove_labels.len == 0 and spec.assignee == null and spec.priority == null and
            spec.milestone == null;
    }
};

pub const Change = enum {
    title,
    labels,
    assignee,
    priority,
    milestone,

    /// For default subjects like "Update title, assignee".
    pub fn name(c: Change) []const u8 {
        return @tagName(c);
    }
};

pub fn Repo(comptime B: type) type {
    contract.assertBackend(B);
    return struct {
        const Self = @This();

        backend: *B,
        limits: Limits = .{},

        pub const Error = B.Error || error{
            /// More commits than `Limits.max_commits_per_issue`.
            HistoryTooLong,
            /// A reachable object is missing or isn't a commit.
            CorruptIssue,
            /// Out of compare-and-swap retries.
            ConcurrentModification,
            /// The issue ref went away during a write.
            IssueDisappeared,
            IdentityUnknown,
            /// A newline in a field, or similar.
            InvalidText,
            /// The text's last paragraph would read as trailers.
            BodyLooksLikeTrailers,
            /// Over a `Limits` bound.
            TooLong,
            TooManyLabels,
            NothingToEdit,
            /// A value upstream doesn't allow, like an unknown priority.
            InvalidValue,
            /// Not `refs/issues/<valid ref component>`.
            InvalidIssueRef,
            /// The tip is no longer the `expect`ed one.
            VersionMismatch,
            /// Use `loadPage`.
            TooManyIssues,
            InvalidLimits,
        } || issue_model.Error;

        pub fn init(backend: *B) Self {
            return .{ .backend = backend };
        }

        /// Sorted by name, so by UUID.
        pub fn refs(self: Self, arena: Allocator) Error![]IssueRef {
            const entries = try self.backend.listRefs(arena, issue_ref_prefix);
            const out = try arena.alloc(IssueRef, entries.len);
            for (entries, out) |e, *r| r.* = .{ .name = e.name, .tip = e.oid };
            return out;
        }

        /// Like upstream's `refs/issues/<prefix>*`.
        pub fn resolve(self: Self, arena: Allocator, prefix: []const u8) Error!Resolution {
            const all = try self.refs(arena);
            var matches: std.ArrayList(IssueRef) = .empty;
            for (all) |r| if (std.mem.startsWith(u8, r.id(), prefix)) try matches.append(arena, r);
            return switch (matches.items.len) {
                0 => .none,
                1 => .{ .one = matches.items[0] },
                else => .{ .many = matches.items },
            };
        }

        pub fn load(self: Self, arena: Allocator, ref: IssueRef) Error!Issue {
            const commits = try self.loadCommits(arena, ref.tip);
            return issue_model.materialize(arena, ref.id(), ref.tip, commits);
        }

        pub fn loadAll(self: Self, arena: Allocator) Error![]Issue {
            try self.checkLimits();
            const all = try self.refs(arena);
            if (all.len > self.limits.max_issues) return error.TooManyIssues;
            const issues = try arena.alloc(Issue, all.len);
            for (all, issues) |r, *i| i.* = try self.load(arena, r);
            return issues;
        }

        pub const Page = struct {
            issues: []Issue,
            /// Null on the last page.
            next: ?[]const u8,
        };

        /// In ID order, after the issue ID `after`. `limit` defaults to
        /// and is capped by `Limits.page_size`.
        pub fn loadPage(
            self: Self,
            arena: Allocator,
            after: ?[]const u8,
            limit: ?u32,
        ) Error!Page {
            try self.checkLimits();
            const size = @min(limit orelse self.limits.page_size, self.limits.page_size);
            if (size == 0) return error.InvalidLimits;
            const all = try self.refs(arena);
            var start: usize = 0;
            if (after) |a| {
                while (start < all.len and std.mem.order(u8, all[start].id(), a) != .gt) start += 1;
            }
            const end = @min(all.len, start + size);
            const issues = try arena.alloc(Issue, end - start);
            for (all[start..end], issues) |r, *i| i.* = try self.load(arena, r);
            return .{
                .issues = issues,
                .next = if (end < all.len) all[end - 1].id() else null,
            };
        }

        fn checkLimits(self: Self) Error!void {
            if (!self.limits.valid()) return error.InvalidLimits;
        }

        pub fn loadCommits(self: Self, arena: Allocator, tip: Oid) Error![]issue_model.CommitInput {
            var out: std.ArrayList(issue_model.CommitInput) = .empty;
            var seen: std.AutoHashMapUnmanaged([Oid.max_byte_len]u8, void) = .empty;
            var stack: std.ArrayList(Oid) = .empty;
            try stack.append(arena, tip);
            try seen.put(arena, tip.bytes, {});
            const format = self.backend.objectFormat();
            while (stack.pop()) |oid| {
                if (out.items.len >= self.limits.max_commits_per_issue) return error.HistoryTooLong;
                const o = (try self.backend.readObject(
                    arena,
                    oid,
                )) orelse return error.CorruptIssue;
                if (o.kind != .commit) return error.CorruptIssue;
                const c = object.Commit.parse(
                    arena,
                    format,
                    o.data,
                ) catch return error.CorruptIssue;
                try out.append(arena, .{
                    .oid = oid,
                    .tree = c.tree,
                    .parents = c.parents,
                    .author = c.author,
                    .committer = c.committer,
                    .message = c.message,
                });
                for (c.parents) |p| {
                    const gop = try seen.getOrPut(arena, p.bytes);
                    if (!gop.found_existing) try stack.append(arena, p);
                }
            }
            return out.items;
        }

        pub const Problem = union(enum) {
            invalid_uuid,
            non_empty_tree: Oid,
            root_count: usize,
            missing_state,
            missing_format_version,
            unreadable: Error,
        };

        /// Upstream fsck's checks, with our trailer parsing.
        pub fn check(self: Self, arena: Allocator, ref: IssueRef) Allocator.Error![]const Problem {
            var problems: std.ArrayList(Problem) = .empty;
            if (!uuid_fmt.isCanonical(ref.id())) try problems.append(arena, .invalid_uuid);
            const commits = self.loadCommits(arena, ref.tip) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try problems.append(arena, .{ .unreadable = e });
                    return problems.items;
                },
            };
            const empty = object.emptyTree(self.backend.objectFormat());
            var roots: usize = 0;
            var root_message: ?[]const u8 = null;
            for (commits) |c| {
                if (c.tree) |t| if (!t.eql(empty)) try problems.append(
                    arena,
                    .{ .non_empty_tree = c.oid },
                );
                if (c.parents.len == 0) {
                    roots += 1;
                    root_message = c.message;
                }
            }
            if (roots != 1) try problems.append(arena, .{ .root_count = roots });
            if (root_message) |m| {
                const block = try trailers.parse(arena, m, .{});
                if (!trailers.has(block, "State")) try problems.append(arena, .missing_state);
                if (!trailers.has(block, "Format-Version"))
                    try problems.append(arena, .missing_format_version);
            }
            return problems.items;
        }

        pub const Created = struct { id: uuid_fmt.Uuid, tip: Oid };

        pub fn create(self: Self, arena: Allocator, spec: CreateSpec) Error!Created {
            try self.checkLimits();
            try self.checkText(spec.title, self.limits.max_title_bytes);
            if (spec.body.len > self.limits.max_body_bytes) return error.TooLong;
            const normalized = try self.normalizeLabels(arena, spec.labels);
            if (spec.priority) |v| if (!core_fmt.isPriority(v)) return error.InvalidValue;

            var list: std.ArrayList(trailers.Trailer) = .empty;
            try list.append(arena, .{ .key = "State", .value = "open" });
            if (normalized.len > 0) try list.append(
                arena,
                .{ .key = "Labels", .value = try labels_fmt.join(arena, normalized) },
            );
            if (spec.assignee) |v| if (v.len > 0) try list.append(
                arena,
                .{ .key = "Assignee", .value = v },
            );
            if (spec.priority) |v| try list.append(arena, .{ .key = "Priority", .value = v });
            if (spec.milestone) |v| if (v.len > 0) try list.append(
                arena,
                .{ .key = "Milestone", .value = v },
            );
            if (spec.assignee) |v| if (v.len > 0) try checkAssignee(v);
            try list.append(arena, .{ .key = "Format-Version", .value = "1" });
            for (list.items) |t| try self.checkText(t.value, self.limits.max_trailer_value_bytes);

            const message = try trailers.build(arena, spec.title, spec.body, list.items);
            const who = try self.identity(arena, spec.author);
            const oid = try self.writeCommit(arena, &.{}, who, message);

            // A UUID collision is a CAS conflict: retry with a new UUID.
            var attempt: u8 = 0;
            while (attempt < self.limits.cas_retries) : (attempt += 1) {
                var random: [16]u8 = undefined;
                self.backend.randomBytes(&random);
                const id = uuid_fmt.Uuid.fromRandom(random);
                const name = try std.fmt.allocPrint(
                    arena,
                    "{s}{s}",
                    .{ issue_ref_prefix, id.slice() },
                );
                self.backend.updateRefs(&.{.{ .name = name, .op = .{ .create = oid } }}) catch |err| switch (err) {
                    error.RefConflict => continue,
                    else => |e| return e,
                };
                return .{ .id = id, .tip = oid };
            }
            return error.ConcurrentModification;
        }

        pub fn comment(
            self: Self,
            arena: Allocator,
            ref_name: []const u8,
            spec: CommentSpec,
        ) Error!Oid {
            try self.checkLimits();
            if (spec.text.len > self.limits.max_body_bytes) return error.TooLong;
            const split = splitMessage(spec.text);
            const message = try trailers.build(arena, split.subject, split.body, &.{});
            return self.appendCommit(arena, ref_name, spec.author, spec.expect, FixedMessage{
                .text = message,
            });
        }

        pub fn setState(
            self: Self,
            arena: Allocator,
            ref_name: []const u8,
            spec: StateSpec,
        ) Error!Oid {
            try self.checkLimits();
            try self.checkText(spec.state, 64);
            if (!core_fmt.isState(spec.state)) return error.InvalidValue;
            var list: std.ArrayList(trailers.Trailer) = .empty;
            try list.append(arena, .{ .key = "State", .value = spec.state });
            if (spec.fixed_by) |v| try list.append(arena, .{ .key = "Fixed-By", .value = v });
            if (spec.release) |v| try list.append(arena, .{ .key = "Release", .value = v });
            if (spec.reason) |v| try list.append(arena, .{ .key = "Reason", .value = v });
            for (list.items) |t| try self.checkText(t.value, self.limits.max_trailer_value_bytes);
            const default_subject = if (std.mem.eql(u8, spec.state, "open"))
                "Reopen issue"
            else if (std.mem.eql(u8, spec.state, "closed"))
                "Close issue"
            else
                try std.fmt.allocPrint(arena, "Change state to {s}", .{spec.state});
            const split = splitMessage(spec.message orelse default_subject);
            const message = try trailers.build(arena, split.subject, split.body, list.items);
            return self.appendCommit(arena, ref_name, spec.author, spec.expect, FixedMessage{
                .text = message,
            });
        }

        pub const EditResult = struct { tip: Oid, changes: []const Change };

        pub fn edit(
            self: Self,
            arena: Allocator,
            ref_name: []const u8,
            spec: EditSpec,
        ) Error!EditResult {
            try self.checkLimits();
            if (spec.isEmpty()) return error.NothingToEdit;
            if (spec.title) |t| try self.checkText(t, self.limits.max_title_bytes);
            for ([_]?[]const u8{ spec.assignee, spec.priority, spec.milestone }) |v| {
                if (v) |value| try self.checkText(value, self.limits.max_trailer_value_bytes);
            }
            // An empty priority clears it.
            if (spec.priority) |v| {
                if (v.len > 0 and !core_fmt.isPriority(v)) return error.InvalidValue;
            }
            var changes: std.ArrayList(Change) = .empty;
            if (spec.title != null) try changes.append(arena, .title);
            if (spec.set_labels != null or spec.add_labels.len > 0 or spec.remove_labels.len > 0)
                try changes.append(arena, .labels);
            if (spec.assignee != null) try changes.append(arena, .assignee);
            if (spec.priority != null) try changes.append(arena, .priority);
            if (spec.milestone != null) try changes.append(arena, .milestone);
            if (spec.assignee) |v| if (v.len > 0) try checkAssignee(v);
            const builder: EditBuilder = .{ .repo = self, .spec = spec, .changes = changes.items };
            const tip = try self.appendCommit(arena, ref_name, spec.author, spec.expect, builder);
            return .{ .tip = tip, .changes = changes.items };
        }

        /// `builder.message` runs against the fresh tip on every attempt.
        /// With `expect` there's a single attempt: if the ref moved, that's
        /// the caller's conflict, not ours to rebase.
        fn appendCommit(
            self: Self,
            arena: Allocator,
            ref_name: []const u8,
            author: ?Signature,
            expect: ?Oid,
            builder: anytype,
        ) Error!Oid {
            const prefix = issue_ref_prefix;
            if (!std.mem.startsWith(u8, ref_name, prefix) or ref_name.len == prefix.len or
                !contract.isValidRefName(ref_name)) return error.InvalidIssueRef;
            var attempt: u8 = 0;
            while (attempt < self.limits.cas_retries) : (attempt += 1) {
                const tip = (try self.backend.resolveRef(ref_name)) orelse
                    return error.IssueDisappeared;
                if (expect) |want| if (!want.eql(tip)) return error.VersionMismatch;
                const current = try self.load(arena, .{ .name = ref_name, .tip = tip });
                const message = try builder.message(arena, current);
                const who = try self.identity(arena, author);
                const oid = try self.writeCommit(arena, &.{tip}, who, message);
                self.backend.updateRefs(&.{.{
                    .name = ref_name,
                    .op = .{ .update = .{ .new = oid, .old = tip } },
                }}) catch |err| switch (err) {
                    error.RefConflict => if (expect != null)
                        return error.VersionMismatch
                    else
                        continue,
                    else => |e| return e,
                };
                return oid;
            }
            return error.ConcurrentModification;
        }

        const FixedMessage = struct {
            text: []const u8,
            pub fn message(b: FixedMessage, arena: Allocator, current: Issue) Error![]const u8 {
                _ = arena;
                _ = current;
                return b.text;
            }
        };

        const EditBuilder = struct {
            repo: Self,
            spec: EditSpec,
            changes: []const Change,

            pub fn message(b: EditBuilder, arena: Allocator, current: Issue) Error![]const u8 {
                const spec = b.spec;
                var list: std.ArrayList(trailers.Trailer) = .empty;
                if (spec.title) |t| try list.append(arena, .{ .key = "Title", .value = t });
                const labels_changed = spec.set_labels != null or spec.add_labels.len > 0 or
                    spec.remove_labels.len > 0;
                if (labels_changed) {
                    // From the fresh state, on every attempt.
                    var next: std.ArrayList([]const u8) = .empty;
                    try next.appendSlice(arena, spec.set_labels orelse current.labels);
                    try next.appendSlice(arena, spec.add_labels);
                    // Trimmed, like upstream compares them.
                    const candidates = try b.repo.normalizeLabels(arena, next.items);
                    var kept: std.ArrayList([]const u8) = .empty;
                    for (candidates) |l| {
                        var removed = false;
                        for (spec.remove_labels) |r| if (std.mem.eql(
                            u8,
                            std.mem.trim(u8, r, " \t"),
                            l,
                        )) {
                            removed = true;
                        };
                        if (!removed) try kept.append(arena, l);
                    }
                    const normalized = kept.items;
                    try list.append(
                        arena,
                        .{ .key = "Labels", .value = try labels_fmt.join(arena, normalized) },
                    );
                }
                if (spec.assignee) |v| try list.append(arena, .{ .key = "Assignee", .value = v });
                if (spec.priority) |v| try list.append(arena, .{ .key = "Priority", .value = v });
                if (spec.milestone) |v| try list.append(arena, .{ .key = "Milestone", .value = v });
                const subject = spec.message orelse try defaultEditSubject(arena, b.changes);
                const split = splitMessage(subject);
                return trailers.build(arena, split.subject, split.body, list.items);
            }
        };

        pub fn writeCommit(
            self: Self,
            arena: Allocator,
            parents: []const Oid,
            who: contract.Identity,
            message: []const u8,
        ) Error!Oid {
            const format = self.backend.objectFormat();
            const c: object.Commit = .{
                .tree = object.emptyTree(format),
                .parents = parents,
                .author = who.author,
                .committer = who.committer,
                .message = message,
            };
            return self.backend.writeObject(.commit, try c.serializeAlloc(arena));
        }

        /// The backend's identity, with `author` replacing the author.
        pub fn identity(self: Self, arena: Allocator, author: ?Signature) Error!contract.Identity {
            const defaults = self.backend.identity(arena) catch |err| switch (err) {
                error.IdentityUnknown => if (author) |a| return .{
                    .author = a,
                    .committer = a,
                } else return error.IdentityUnknown,
                else => |e| return e,
            };
            if (author) |a| return .{ .author = a, .committer = defaults.committer };
            return defaults;
        }

        fn normalizeLabels(
            self: Self,
            arena: Allocator,
            raw: []const []const u8,
        ) Error![]const []const u8 {
            var out: std.ArrayList([]const u8) = .empty;
            for (raw) |l| {
                labels_fmt.validate(l) catch return error.InvalidText;
                const t = std.mem.trim(u8, l, " \t");
                if (t.len == 0 or labels_fmt.contains(out.items, t)) continue;
                try out.append(arena, t);
            }
            if (out.items.len > self.limits.max_labels) return error.TooManyLabels;
            return out.items;
        }

        fn checkText(self: Self, text: []const u8, max: u32) Error!void {
            _ = self;
            if (text.len > max) return error.TooLong;
            if (std.mem.findAny(u8, text, "\r\n") != null) return error.InvalidText;
        }
    };
}

fn checkAssignee(v: []const u8) error{InvalidValue}!void {
    if (core_fmt.checkEmail(v) != null) return error.InvalidValue;
}

fn defaultEditSubject(arena: Allocator, changes: []const Change) Allocator.Error![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (changes) |c| try names.append(arena, c.name());
    return std.fmt.allocPrint(arena, "Update {s}", .{try std.mem.join(arena, ", ", names.items)});
}

/// First paragraph is the subject, the rest the body, so `-m a -m b` gives
/// subject "a" and body "b".
fn splitMessage(text: []const u8) struct { subject: []const u8, body: []const u8 } {
    const trimmed = std.mem.trim(u8, text, "\n");
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, trimmed, i, '\n')) |nl| {
        const rest = trimmed[nl + 1 ..];
        const line_end = std.mem.findScalar(u8, rest, '\n') orelse rest.len;
        if (std.mem.trim(u8, rest[0..line_end], " \t\r").len == 0) {
            return .{ .subject = trimmed[0..nl], .body = skipBlankLines(rest) };
        }
        i = nl + 1;
    }
    return .{ .subject = trimmed, .body = "" };
}

/// Keeps the first line's indentation, so indented code in a comment
/// survives.
fn skipBlankLines(text: []const u8) []const u8 {
    var rest = text;
    while (rest.len > 0) {
        const line_end = std.mem.findScalar(u8, rest, '\n') orelse rest.len;
        if (std.mem.trim(u8, rest[0..line_end], " \t\r").len != 0) break;
        rest = if (line_end < rest.len) rest[line_end + 1 ..] else rest[rest.len..];
    }
    return rest;
}

test splitMessage {
    const t = std.testing;
    const a = splitMessage("one");
    try t.expectEqualStrings("one", a.subject);
    try t.expectEqualStrings("", a.body);
    const b = splitMessage("Repro\n\nDetail one\ndetail two");
    try t.expectEqualStrings("Repro", b.subject);
    try t.expectEqualStrings("Detail one\ndetail two", b.body);
    const c = splitMessage("line one\nline two\n\nbody");
    try t.expectEqualStrings("line one\nline two", c.subject);
    try t.expectEqualStrings("body", c.body);
    const d = splitMessage("Code:\n\n  \n    indented();\n");
    try t.expectEqualStrings("    indented();", d.body);
}

const GitSim = @import("../backend/GitSim.zig");
const testing = std.testing;

test "create, comment, state, edit and read back" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 3, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);

    const created = try repo.create(arena, .{
        .title = "Crash on login",
        .body = "First paragraph.\n\nSecond.",
        .labels = &.{ "bug", " auth ", "bug" },
        .assignee = "bob@e.x",
        .priority = "high",
    });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});
    _ = try repo.comment(arena, ref_name, .{ .text = "Repro on Firefox\n\nDetail line" });
    _ = try repo.setState(
        arena,
        ref_name,
        .{ .state = "closed", .message = "Fixed in abc", .fixed_by = "abc123" },
    );
    const edited = try repo.edit(
        arena,
        ref_name,
        .{ .add_labels = &.{"regression"}, .remove_labels = &.{"auth"}, .assignee = "" },
    );
    try testing.expectEqual(@as(usize, 2), edited.changes.len);

    const res = try repo.resolve(arena, created.id.short());
    const issue = try repo.load(arena, res.one);
    try testing.expectEqualStrings("Crash on login", issue.title);
    try testing.expectEqualStrings("First paragraph.\n\nSecond.", issue.description);
    try testing.expectEqualStrings("closed", issue.state);
    try testing.expectEqual(@as(usize, 2), issue.labels.len);
    try testing.expectEqualStrings("bug", issue.labels[0]);
    try testing.expectEqualStrings("regression", issue.labels[1]);
    try testing.expect(issue.field("Assignee") == null);
    try testing.expectEqualStrings("high", issue.field("Priority").?);
    try testing.expectEqualStrings("abc123", issue.field("Fixed-By").?);
    try testing.expectEqual(@as(usize, 3), issue.comments.len);
    try testing.expectEqualStrings("Repro on Firefox", issue.comments[0].subject);

    // Byte for byte what upstream writes.
    const root = (try sim.readObject(arena, issue.root)).?;
    const c = try object.Commit.parse(arena, .sha1, root.data);
    try testing.expectEqualStrings(
        "Crash on login\n\nFirst paragraph.\n\nSecond.\n\n" ++
            "State: open\nLabels: bug, auth\nAssignee: bob@e.x\n" ++
            "Priority: high\nFormat-Version: 1\n",
        c.message,
    );
    try testing.expect(c.tree.eql(object.emptyTree(.sha1)));
}

test "caller mistakes are errors, not panics" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 3, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const created = try repo.create(arena, .{ .title = "Target" });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});

    try testing.expectError(error.NothingToEdit, repo.edit(arena, ref_name, .{}));
    for ([_][]const u8{ "refs/heads/main", "refs/issues/", "refs/issues/a..b", "x" }) |bad| {
        try testing.expectError(error.InvalidIssueRef, repo.comment(arena, bad, .{ .text = "hi" }));
        try testing.expectError(
            error.InvalidIssueRef,
            repo.setState(arena, bad, .{ .state = "closed" }),
        );
        try testing.expectError(error.InvalidIssueRef, repo.edit(arena, bad, .{ .title = "t" }));
    }

    // Upstream's write rules hold for library callers too.
    for ([_]CreateSpec{
        .{ .title = "x", .priority = "urgent" },
        .{ .title = "x", .priority = "" },
        .{ .title = "x", .assignee = "ada" },
        .{ .title = "x", .assignee = "ada@example." },
    }) |bad| try testing.expectError(error.InvalidValue, repo.create(arena, bad));
    try testing.expectError(error.InvalidValue, repo.edit(arena, ref_name, .{ .priority = "p1" }));
    try testing.expectError(error.InvalidValue, repo.edit(arena, ref_name, .{ .assignee = "ada" }));
    try testing.expectError(
        error.InvalidValue,
        repo.setState(arena, ref_name, .{ .state = "in progress" }),
    );
    _ = try repo.edit(arena, ref_name, .{ .priority = "", .assignee = "" });
}

test "expect" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 5, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const created = try repo.create(arena, .{ .title = "Versioned" });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});

    // A client read the issue at `created.tip`, then someone else comments.
    const seen = created.tip;
    const other = try repo.comment(arena, ref_name, .{ .text = "Someone else" });

    try testing.expectError(
        error.VersionMismatch,
        repo.comment(arena, ref_name, .{ .text = "Mine", .expect = seen }),
    );
    try testing.expectError(
        error.VersionMismatch,
        repo.setState(arena, ref_name, .{ .state = "closed", .expect = seen }),
    );
    try testing.expectError(
        error.VersionMismatch,
        repo.edit(arena, ref_name, .{ .title = "Renamed", .expect = seen }),
    );
    // The refused calls wrote nothing.
    try testing.expect((try sim.resolveRef(ref_name)).?.eql(other));

    const next = try repo.comment(arena, ref_name, .{ .text = "Mine", .expect = other });
    const done = try repo.edit(arena, ref_name, .{ .title = "Renamed", .expect = next });
    try testing.expect((try sim.resolveRef(ref_name)).?.eql(done.tip));
}

test "limits and paging" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 9, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    var repo = Repo(GitSim).init(&sim);
    for (0..5) |i| _ = try repo.create(arena, .{
        .title = try std.fmt.allocPrint(arena, "Issue {d}", .{i}),
    });

    var seen: usize = 0;
    var after: ?[]const u8 = null;
    var pages: usize = 0;
    while (true) {
        const page = try repo.loadPage(arena, after, 2);
        seen += page.issues.len;
        pages += 1;
        after = page.next orelse break;
    }
    try testing.expectEqual(@as(usize, 5), seen);
    try testing.expectEqual(@as(usize, 3), pages);

    repo.limits.max_issues = 4;
    try testing.expectError(error.TooManyIssues, repo.loadAll(arena));
    repo.limits = .{};
    repo.limits.cas_retries = 0;
    try testing.expectError(error.InvalidLimits, repo.create(arena, .{ .title = "x" }));
    repo.limits = .{};
    repo.limits.max_body_bytes = Limits.maximum.max_body_bytes + 1;
    try testing.expectError(error.InvalidLimits, repo.loadAll(arena));
    try testing.expect(Limits.maximum.valid());
}

test "resolve: none, one, ambiguous" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 9, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    _ = try repo.create(arena, .{ .title = "one" });
    _ = try repo.create(arena, .{ .title = "two" });
    try testing.expect(try repo.resolve(arena, "zzzz") == .none);
    try testing.expect((try repo.resolve(arena, "")) == .many);
}

test "comments that would read as trailers are refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = Repo(GitSim).init(&sim);
    const created = try repo.create(arena, .{ .title = "t" });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});
    try testing.expectError(
        error.BodyLooksLikeTrailers,
        repo.comment(arena, ref_name, .{ .text = "I agree.\n\nX-Deleted: true" }),
    );
    // A single line is the subject, never a trailer.
    _ = try repo.comment(arena, ref_name, .{ .text = "State: closed" });
    try testing.expectEqualStrings(
        "open",
        (try repo.load(arena, (try repo.resolve(arena, created.id.short())).one)).state,
    );
    try testing.expectError(error.InvalidText, repo.create(arena, .{ .title = "two\nlines" }));
}

/// Lets another writer move a ref right before our first update, to
/// exercise the CAS retry.
const RacingSim = struct {
    sim: *GitSim,
    race: ?struct { ref: []const u8, message: []const u8, close: bool = false } = null,

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
            if (race.close) {
                _ = other.setState(a, race.ref, .{ .state = "closed" }) catch unreachable;
            } else {
                _ = other.comment(a, race.ref, .{ .text = race.message }) catch unreachable;
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
    ) (Error || error{FetchFailed})!void {
        return r.sim.fetch(arena, remote, refspecs);
    }
    pub fn push(
        r: *RacingSim,
        arena: Allocator,
        remote: []const u8,
        refspecs: []const []const u8,
        atomic: bool,
    ) (Error || error{PushFailed})!contract.PushResult {
        return r.sim.push(arena, remote, refspecs, atomic);
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

test "CAS conflict rebuilds the commit" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const created = try Repo(GitSim).init(&sim).create(arena, .{ .title = "t", .labels = &.{"a"} });
    const ref_name = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});

    var racing: RacingSim = .{
        .sim = &sim,
        .race = .{ .ref = ref_name, .message = "concurrent comment" },
    };
    const repo = Repo(RacingSim).init(&racing);
    _ = try repo.edit(arena, ref_name, .{ .add_labels = &.{"b"} });

    const issue = try repo.load(
        arena,
        .{ .name = ref_name, .tip = (try sim.resolveRef(ref_name)).? },
    );
    // Both the concurrent comment and our edit survive, in one chain.
    try testing.expectEqual(@as(usize, 2), issue.comments.len);
    try testing.expectEqualStrings("concurrent comment", issue.comments[0].subject);
    try testing.expectEqualStrings("Update labels", issue.comments[1].subject);
    try testing.expectEqual(@as(usize, 2), issue.labels.len);
}

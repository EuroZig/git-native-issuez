//! The oracle's own statement of purges (format.md §10): what a tombstone
//! says, and the history a set of purged comments rewrites to. Hashes the
//! commits it expects instead of writing them.

const std = @import("std");
const stableSort = @import("issuez").sort.stable;
const Allocator = std.mem.Allocator;
const issuez = @import("issuez");
const object = issuez.backend.object;
const trailers = issuez.format.trailers;
const commands = @import("commands.zig");

pub const prefix = "refs/issuez-purged/";

pub const Tomb = struct {
    issue: bool = false,
    /// First IDs, as hex.
    comments: []const []const u8 = &.{},

    pub fn covers(t: Tomb, first: []const u8) bool {
        return commands.containsText(t.comments, first);
    }
};

/// Every commit of the chain counts; what isn't a purge is ignored.
pub fn read(c: commands.Clone, tip: []const u8) Allocator.Error!Tomb {
    const arena = c.arena;
    var out: Tomb = .{};
    var comments: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(arena, tip);
    while (stack.pop()) |hex| {
        if ((try seen.getOrPut(arena, hex)).found_existing) continue;
        const cm = c.commit(hex) orelse continue;
        for (cm.parents) |p| try stack.append(arena, try p.hexAlloc(arena));
        const block = try commands.trailersOf(arena, cm.message);
        const kind = trailers.lastValue(block, "X-Purge") orelse continue;
        if (std.mem.eql(u8, kind, "issue")) out.issue = true;
        if (!std.mem.eql(u8, kind, "comment")) continue;
        for (block.trailers) |t| {
            if (!std.ascii.eqlIgnoreCase(t.key, "X-Purged-Commit")) continue;
            if (!isFullHex(c, t.value)) continue;
            if (!commands.containsText(comments.items, t.value))
                try comments.append(arena, t.value);
        }
    }
    out.comments = comments.items;
    return out;
}

/// The tombstone of issue `id` in this clone.
pub fn of(c: commands.Clone, id: []const u8) Allocator.Error!?Tomb {
    const name = try std.fmt.allocPrint(c.arena, "{s}{s}", .{ prefix, id });
    const tip = c.ref(name) orelse return null;
    return try read(c, tip);
}

fn isFullHex(c: commands.Clone, s: []const u8) bool {
    if (s.len != c.format.hexLen()) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return false;
    return true;
}

/// The commit's ID before any purge.
pub fn firstId(c: commands.Clone, hex: []const u8) Allocator.Error![]const u8 {
    const cm = c.commit(hex) orelse return hex;
    const block = try commands.trailersOf(c.arena, cm.message);
    const was = trailers.lastValue(block, "X-Rewritten-From") orelse return hex;
    return if (isFullHex(c, was)) was else hex;
}

/// Whether the history of `tip` still has text a purge took: a commit
/// whose first ID is purged and that isn't marked `X-Purged: true`.
pub fn leaks(c: commands.Clone, tip: []const u8, t: Tomb) Allocator.Error!?[]const u8 {
    const arena = c.arena;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(arena, tip);
    while (stack.pop()) |hex| {
        if ((try seen.getOrPut(arena, hex)).found_existing) continue;
        const cm = c.commit(hex) orelse continue;
        for (cm.parents) |p| try stack.append(arena, try p.hexAlloc(arena));
        if (!t.covers(try firstId(c, hex))) continue;
        const block = try commands.trailersOf(arena, cm.message);
        const marked = trailers.lastValue(block, "X-Purged") orelse "";
        if (!std.mem.eql(u8, marked, "true")) return hex;
    }
    return null;
}

/// What a purged comment keeps of its trailers: the format's keys, without
/// its text's, its images', its origin's and the rewrite's own. Anything else
/// can be text that parses as trailers.
const comment_keeps = [_][]const u8{
    "State",              "Title",            "Assignee",     "Priority",
    "Milestone",          "Format-Version",   "Fixed-By",     "Release",
    "Reason",             "X-Parent",         "X-Start-Date", "X-Due-Date",
    "X-Estimate-Minutes", "X-Workflow-State", "X-Deleted",    "X-Milestone-Id",
    "X-Milestone-Mode",   "X-Number",         "X-Locked",     "X-Lock-Reason",
    "X-Ref",              "Labels",           "X-Blocked-By", "X-Assignees",
    "Exported-Commit",    "X-Message",        "X-Reaction",   "X-Author-Id",
    "X-Event",            "X-Comment",
};

/// The tip `tip` rewrites to with `purged` (first IDs) purged. Null when
/// the history isn't all there.
pub fn rewrite(
    c: commands.Clone,
    tip: []const u8,
    purged: []const []const u8,
) Allocator.Error!?[]const u8 {
    var memo: std.StringHashMapUnmanaged([]const u8) = .empty;
    // The new commits too: a merge's new parents are read like any others.
    var over = c;
    over.objects = try c.objects.clone(c.arena);
    var in_history: std.StringHashMapUnmanaged(void) = .empty;
    {
        var stack: std.ArrayList([]const u8) = .empty;
        try stack.append(c.arena, tip);
        while (stack.pop()) |hex| {
            if ((try in_history.getOrPut(c.arena, hex)).found_existing) continue;
            const cm = c.commit(hex) orelse return null;
            for (cm.parents) |p| try stack.append(c.arena, try p.hexAlloc(c.arena));
        }
    }
    const r: Rewriter = .{
        .c = c,
        .purged = purged,
        .memo = &memo,
        .over = &over,
        .history = &in_history,
    };
    return try r.new(tip);
}

const Rewriter = struct {
    c: commands.Clone,
    purged: []const []const u8,
    memo: *std.StringHashMapUnmanaged([]const u8),
    over: *commands.Clone,
    history: *const std.StringHashMapUnmanaged(void),

    fn isPurged(r: Rewriter, hex: []const u8) Allocator.Error!bool {
        return commands.containsText(r.purged, try firstId(r.c, hex));
    }

    fn new(r: Rewriter, hex: []const u8) Allocator.Error![]const u8 {
        if (r.memo.get(hex)) |x| return x;
        const arena = r.c.arena;
        const cm = r.c.commit(hex).?;
        var parents: std.ArrayList(object.Oid) = .empty;
        var parent_hexes: std.ArrayList([]const u8) = .empty;
        var moved = false;
        for (cm.parents) |p| {
            const ph = try p.hexAlloc(arena);
            const np = try r.new(ph);
            if (!std.mem.eql(u8, np, ph)) moved = true;
            try parents.append(arena, object.Oid.parseHex(r.c.format, np) catch unreachable);
            try parent_hexes.append(arena, np);
        }
        // Parents a purge left one behind the other: nothing to merge.
        if (moved and parents.items.len > 1 and !try r.isPurged(hex)) {
            if (try r.lineTip(parent_hexes.items)) |only| {
                try r.memo.put(arena, hex, only);
                return only;
            }
        }
        const block = try commands.trailersOf(arena, cm.message);
        const first = try firstId(r.c, hex);
        const target = trailers.lastValue(block, "X-Comment");
        const in_issue = if (target) |t| r.history.contains(t) else false;
        var message = cm.message;
        var stamped = trailers.lastValue(block, "X-Rewritten-From") != null;
        if (try r.isPurged(hex)) {
            message = try purgedText(arena, block, "Purged comment", "", null, first);
            stamped = true;
        } else if (in_issue) {
            const t = target.?;
            const nt = try r.new(t);
            const event = trailers.lastValue(block, "X-Event") orelse "";
            if (try r.isPurged(t) and std.mem.eql(u8, event, "comment-edit")) {
                message = try purgedText(arena, block, "Edit comment", "Purged comment", nt, first);
                stamped = true;
            } else if (!std.mem.eql(u8, nt, t)) {
                message = try pointAt(arena, message, t, nt);
            }
        }
        if (moved and !try r.isPurged(hex) and isOwnMerge(cm)) {
            message = try r.restated(cm, block, parent_hexes.items, first);
            stamped = true;
        }
        var out = hex;
        if (moved or !std.mem.eql(u8, message, cm.message)) {
            if (!stamped) {
                const trimmed = std.mem.trimEnd(u8, message, " \t\r\n");
                const join: []const u8 = if (block.first_line != null) "\n" else "\n\n";
                message = try std.fmt.allocPrint(arena, "{s}{s}X-Rewritten-From: {s}\n", .{
                    trimmed,
                    join,
                    first,
                });
            }
            const commit: object.Commit = .{
                .tree = cm.tree,
                .parents = parents.items,
                .author = cm.author,
                .committer = cm.committer,
                .message = message,
            };
            const data = try commit.serializeAlloc(arena);
            out = try object.hashObject(r.c.format, .commit, data).hexAlloc(arena);
            try r.over.objects.put(arena, out, .{ .kind = .commit, .data = data });
        }
        try r.memo.put(arena, hex, out);
        return out;
    }

    /// The parent with all the others in its history.
    fn lineTip(r: Rewriter, parents: []const []const u8) Allocator.Error!?[]const u8 {
        const arena = r.c.arena;
        for (parents) |p| {
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            var stack: std.ArrayList([]const u8) = .empty;
            try stack.append(arena, p);
            while (stack.pop()) |x| {
                if ((try seen.getOrPut(arena, x)).found_existing) continue;
                const cm = r.over.commit(x) orelse continue;
                for (cm.parents) |y| try stack.append(arena, try y.hexAlloc(arena));
            }
            for (parents) |other| {
                if (!seen.contains(other)) break;
            } else return p;
        }
        return null;
    }

    /// What the new parents of an own merge resolve to (format.md §10).
    fn restated(
        r: Rewriter,
        cm: object.Commit,
        block: trailers.Block,
        parents: []const []const u8,
        first: []const u8,
    ) Allocator.Error![]const u8 {
        const arena = r.c.arena;
        var n = r.over.naiveAt(parents) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return cm.message,
        };
        n.labels = try sortedCopy(arena, n.labels);
        n.blocked_by = try sortedCopy(arena, n.blocked_by);
        var want = try commands.restatedBy(arena, n);
        if (trailers.lastValue(block, "X-Number")) |kept| {
            if (!std.mem.eql(u8, kept, n.number))
                try want.append(arena, .{ .key = "X-Number", .value = kept });
        }
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "Merge issue\n\n");
        for (want.items) |t| try out.print(arena, "{s}: {s}\n", .{ t.key, t.value });
        try out.print(arena, "X-Rewritten-From: {s}\n", .{first});
        return out.items;
    }
};

fn sortedCopy(arena: Allocator, set: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.dupe([]const u8, set);
    stableSort([]const u8, out, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return out;
}

fn isOwnMerge(cm: object.Commit) bool {
    if (cm.parents.len != 2) return false;
    if (!std.mem.eql(u8, cm.author.name, "git-issue")) return false;
    if (!std.mem.eql(u8, cm.author.email, "git-issue@invalid")) return false;
    return std.mem.eql(u8, std.mem.sliceTo(cm.message, '\n'), "Merge issue");
}

fn purgedText(
    arena: Allocator,
    block: trailers.Block,
    subject: []const u8,
    body: []const u8,
    target: ?[]const u8,
    first: []const u8,
) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, subject);
    if (body.len > 0) try out.print(arena, "\n\n{s}", .{body});
    try out.appendSlice(arena, "\n\n");
    for (block.trailers) |t| {
        const keep = for (comment_keeps) |k| {
            if (std.ascii.eqlIgnoreCase(k, t.key)) break true;
        } else false;
        if (!keep) continue;
        if (target != null and std.ascii.eqlIgnoreCase(t.key, "X-Comment")) {
            try out.print(arena, "X-Comment: {s}\n", .{target.?});
        } else try out.print(arena, "{s}: {s}\n", .{ t.key, t.value });
    }
    try out.print(arena, "X-Purged: true\nX-Rewritten-From: {s}\n", .{first});
    return out.items;
}

/// `X-Comment: <old>` lines point at `new`.
fn pointAt(
    arena: Allocator,
    message: []const u8,
    old: []const u8,
    new: []const u8,
) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, message, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        const colon = std.mem.findScalar(u8, line, ':');
        if (colon) |i| {
            const key = std.mem.trim(u8, line[0..i], " \t");
            const value = std.mem.trim(u8, line[i + 1 ..], " \t\r");
            if (std.ascii.eqlIgnoreCase(key, "X-Comment") and std.mem.eql(u8, value, old)) {
                try out.print(arena, "X-Comment: {s}", .{new});
                continue;
            }
        }
        try out.appendSlice(arena, line);
    }
    return out.items;
}

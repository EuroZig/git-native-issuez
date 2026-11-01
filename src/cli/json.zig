//! `--json` output, see docs/json.md. Fields may be added but never
//! renamed or removed.

const std = @import("std");
const issuez = @import("issuez");
const common = @import("common.zig");
const ext_flags = @import("ext_flags.zig");

const Allocator = std.mem.Allocator;
pub const Stringify = std.json.Stringify;
const Issue = issuez.engine.Issue;
const Projection = issuez.projection.Projection;

pub fn begin(w: *std.Io.Writer) Stringify {
    return .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
}

pub fn end(s: *Stringify) void {
    s.writer.writeAll("\n") catch {};
}

pub const Error = Stringify.Error || Allocator.Error;

/// `"field"` of a conflict: the key, `Description` or `Comment 3f9a1c2`.
pub fn conflictField(s: *Stringify, t: issuez.model.issue.Conflict.Target) Error!void {
    var buf: [32]u8 = undefined;
    try s.objectField("field");
    switch (t) {
        .field => |k| try s.write(k),
        else => try s.write(std.fmt.bufPrint(&buf, "{f}", .{t}) catch unreachable),
    }
}

fn field(s: *Stringify, key: []const u8, value: anytype) Error!void {
    try s.objectField(key);
    try s.write(value);
}

fn optional(s: *Stringify, key: []const u8, value: ?[]const u8) Error!void {
    try s.objectField(key);
    if (value) |v| try s.write(v) else try s.write(null);
}

fn time(s: *Stringify, key: []const u8, t: i64, tz: i16) Error!void {
    try s.objectField(key);
    try s.print("\"{f}\"", .{common.IsoDate{ .time = t, .tz = tz, .rfc3339 = true }});
}

fn date(s: *Stringify, key: []const u8, d: ?issuez.format.fields.Date) Error!void {
    try s.objectField(key);
    if (d) |v| try s.print("\"{f}\"", .{v}) else try s.write(null);
}

fn person(s: *Stringify, key: []const u8, sig: issuez.backend.object.Signature) Error!void {
    try s.objectField(key);
    try s.beginObject();
    try field(s, "name", sig.name);
    try field(s, "email", sig.email);
    try s.endObject();
}

pub const IssueOptions = struct {
    /// Description and comments.
    full: bool = false,
    /// Problems, effective milestone and workflow, progress.
    projection: ?Projection = null,
};

pub fn issue(s: *Stringify, arena: Allocator, i: Issue, options: IssueOptions) Error!void {
    try s.beginObject();
    try field(s, "id", i.id);
    try field(s, "short_id", issuez.format.uuid.shortId(i.id));
    try field(s, "title", i.title);
    try field(s, "state", i.state.text());
    try field(s, "deleted", i.deleted);
    try field(s, "labels", i.labels);
    try optional(s, "assignee", if (i.ext.assignee) |a| a.email else i.field("Assignee"));
    try optional(s, "priority", i.field("Priority"));
    try optional(s, "milestone", i.field("Milestone"));
    try optional(s, "milestone_id", i.ext.milestone_id);
    try optional(s, "parent", i.ext.parent);
    try field(s, "blocked_by", i.ext.blocked_by);
    try date(s, "start", i.ext.start_date);
    try date(s, "due", i.ext.due_date);
    try s.objectField("estimate_minutes");
    try s.write(i.ext.estimate_minutes);
    try optional(s, "workflow", i.ext.workflow);
    try person(s, "author", i.author);
    try time(s, "created", i.created, i.author.tz_offset_minutes);
    try time(s, "updated", i.updated, i.author.tz_offset_minutes);
    try s.objectField("fields");
    try s.beginObject();
    for (i.fields) |f| try field(s, f.key, f.value);
    try s.endObject();
    try s.objectField("conflicts");
    try s.beginArray();
    for (i.conflicts) |c| {
        try s.beginObject();
        try conflictField(s, c.target);
        try field(s, "kept", c.value);
        try field(s, "lost", c.lost);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("attachments");
    try s.beginArray();
    for (i.attachments) |a| try attachment(s, a, null);
    try s.endArray();
    if (options.projection) |p| if (p.find(i.id)) |idx| {
        try optional(s, "effective_milestone_id", p.milestone[idx]);
        try optional(s, "effective_workflow", p.workflow(idx));
        try s.objectField("progress");
        if (p.progress(idx)) |pr| {
            try s.beginObject();
            try field(s, "closed", pr.closed);
            try field(s, "total", pr.total);
            try s.endObject();
        } else try s.write(null);
        try field(s, "blocked", p.activelyBlocked(idx));
        try s.objectField("problems");
        try s.beginArray();
        for (p.problemsOf(idx)) |pr| try problem(s, arena, pr);
        try s.endArray();
    };
    if (options.full) {
        try field(s, "description", i.description);
        try s.objectField("comments");
        try s.beginArray();
        for (i.comments) |c| {
            try s.beginObject();
            const hex = c.oid.hex();
            try field(s, "id", hex.slice());
            try person(s, "author", c.author);
            try time(s, "date", c.author.time, c.author.tz_offset_minutes);
            try field(s, "subject", c.subject);
            try field(s, "text", try std.mem.join(arena, "\n", c.body));
            try optional(s, "state_change", if (c.state_change) |st| st.text() else null);
            try field(s, "merge", c.is_merge);
            try field(s, "edited", c.edited);
            try field(s, "deleted", c.deleted);
            try field(s, "attachments", c.attachments);
            try s.endObject();
        }
        try s.endArray();
    }
    try s.endObject();
}

pub fn attachment(
    s: *Stringify,
    a: issuez.model.issue.Attachment,
    availability: ?[]const u8,
) Error!void {
    try s.beginObject();
    try field(s, "id", a.id);
    try field(s, "name", a.name);
    try field(s, "media_type", a.media.mediaType());
    try field(s, "size", a.size);
    try field(s, "sha256", a.sha256.slice());
    const hex = a.added_in.hex();
    try field(s, "added_in", hex.slice());
    try person(s, "added_by", a.added_by);
    if (availability) |v| try field(s, "availability", v);
    try s.endObject();
}

pub fn milestone(s: *Stringify, m: issuez.milestone.Milestone) Error!void {
    try s.beginObject();
    try milestoneFields(s, m);
    try s.endObject();
}

fn milestoneFields(s: *Stringify, m: issuez.milestone.Milestone) Error!void {
    try field(s, "id", m.id);
    try field(s, "short_id", issuez.format.uuid.shortId(m.id));
    try field(s, "name", m.name);
    try field(s, "status", @tagName(m.status));
    try date(s, "due", m.due);
    try field(s, "description", m.description);
    try s.objectField("conflicts");
    try s.beginArray();
    for (m.conflicts) |c| {
        try s.beginObject();
        try conflictField(s, c.target);
        try field(s, "kept", c.value);
        try field(s, "lost", c.lost);
        try s.endObject();
    }
    try s.endArray();
}

pub fn milestoneDetail(
    s: *Stringify,
    arena: Allocator,
    m: issuez.milestone.Milestone,
    p: Projection,
) Error!void {
    try s.beginObject();
    try milestoneFields(s, m);
    const leaves = try p.milestoneLeaves(arena, m.id);
    var closed: u32 = 0;
    for (leaves) |i| {
        if (p.isDone(i)) closed += 1;
    }
    try s.objectField("progress");
    try s.beginObject();
    try field(s, "closed", closed);
    try field(s, "total", leaves.len);
    try s.endObject();
    try s.objectField("issues");
    try s.beginArray();
    for (p.issues, p.milestone) |i, in| {
        if (i.deleted) continue;
        if (!std.mem.eql(u8, in orelse continue, m.id)) continue;
        try s.write(i.id);
    }
    try s.endArray();
    try s.endObject();
}

pub fn problem(s: *Stringify, arena: Allocator, p: issuez.projection.Problem) Error!void {
    try s.beginObject();
    try field(s, "kind", @tagName(p.kind));
    try optional(s, "other", p.other);
    try optional(s, "key", p.key);
    try optional(s, "value", p.value);
    try field(s, "description", ext_flags.describeProblem(arena, p));
    try s.endObject();
}

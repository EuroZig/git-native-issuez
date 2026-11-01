//! `--json` output, see docs/json.md. Fields may be added but never
//! renamed or removed. Text goes through `string`: git allows any bytes,
//! JSON strings only UTF-8.

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

/// The exit code when writing fails: out of memory is reported, like on
/// the text paths, and a closed stdout isn't.
pub fn failed(err: *std.Io.Writer, e: Error) u8 {
    return switch (e) {
        error.OutOfMemory => common.oom(err),
        error.WriteFailed => common.exit_error,
    };
}

const Conflict = issuez.model.issue.Conflict;

/// `"conflicts": [...]`.
fn conflicts(s: *Stringify, list: []const Conflict) Error!void {
    try s.objectField("conflicts");
    try s.beginArray();
    for (list) |c| try conflict(s, c, null);
    try s.endArray();
}

/// One conflict. `status` adds the issue's `id` first.
pub fn conflict(s: *Stringify, c: Conflict, id: ?[]const u8) Error!void {
    try s.beginObject();
    if (id) |v| try field(s, "id", v);
    // The key, `Description` or `Comment 3f9a1c2`.
    var buf: [32]u8 = undefined;
    try s.objectField("field");
    switch (c.target) {
        .field => |k| try string(s, k),
        else => try s.write(std.fmt.bufPrint(&buf, "{f}", .{c.target}) catch unreachable),
    }
    try field(s, "kept", c.value);
    try field(s, "lost", c.lost);
    try s.endObject();
}

/// A JSON string. Bytes that aren't UTF-8 become U+FFFD (maximal subparts,
/// `std.unicode.fmtUtf8`), so text is always a string, never the array of
/// numbers `Stringify.write` makes of it.
pub fn string(s: *Stringify, v: []const u8) Error!void {
    if (std.unicode.utf8ValidateSlice(v)) return s.write(v);
    try s.beginWriteRaw();
    try s.writer.writeByte('"');
    var e: Escaping = .{ .out = s.writer, .options = s.options };
    try e.interface.print("{f}", .{std.unicode.fmtUtf8(v)});
    try s.writer.writeByte('"');
    s.endWriteRaw();
}

/// Escapes what is written to it as JSON string characters. Escaping works
/// byte by byte (`escape_unicode` is off), so any split of the input is fine.
const Escaping = struct {
    out: *std.Io.Writer,
    options: Stringify.Options,
    interface: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const e: *Escaping = @alignCast(@fieldParentPtr("interface", w));
        std.debug.assert(!e.options.escape_unicode);
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try Stringify.encodeJsonStringChars(d, e.options, e.out);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try Stringify.encodeJsonStringChars(last, e.options, e.out);
        return n + last.len * splat;
    }
};

/// `"key": value`, with text and lists of text through `string`.
pub fn field(s: *Stringify, key: []const u8, value: anytype) Error!void {
    try s.objectField(key);
    const T = @TypeOf(value);
    if (comptime isText(T)) return string(s, value);
    if (comptime isSlice(T) and isText(std.meta.Elem(T))) {
        try s.beginArray();
        for (value) |v| try string(s, v);
        return s.endArray();
    }
    try s.write(value);
}

fn isSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice,
        else => false,
    };
}

fn isText(comptime T: type) bool {
    return isSlice(T) and std.meta.Elem(T) == u8;
}

pub fn optional(s: *Stringify, key: []const u8, value: ?[]const u8) Error!void {
    try s.objectField(key);
    if (value) |v| try string(s, v) else try s.write(null);
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
    try time(s, "updated", i.updated, i.updated_tz_offset_minutes);
    try s.objectField("fields");
    try s.beginObject();
    for (i.fields) |f| try field(s, f.key, f.value);
    try s.endObject();
    try conflicts(s, i.conflicts);
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

/// `attach ls`: with each one's availability.
pub fn attachmentList(s: *Stringify, entries: anytype) Error!void {
    try s.beginArray();
    for (entries) |e| try attachment(s, e.attachment, @tagName(e.availability));
    try s.endArray();
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

/// Open ones, or `all`.
pub fn milestones(s: *Stringify, list: []const issuez.milestone.Milestone, all: bool) Error!void {
    try s.beginArray();
    for (list) |m| if (all or m.status == .open) try milestone(s, m);
    try s.endArray();
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
    try conflicts(s, m.conflicts);
}

pub fn milestoneDetail(
    s: *Stringify,
    arena: Allocator,
    m: issuez.milestone.Milestone,
    p: Projection,
) Error!void {
    try s.beginObject();
    try milestoneFields(s, m);
    const progress = try p.milestoneProgress(arena, m.id);
    try s.objectField("progress");
    try s.beginObject();
    try field(s, "closed", progress.closed);
    try field(s, "total", progress.total);
    try s.endObject();
    try s.objectField("issues");
    try s.beginArray();
    for (try p.milestoneIssues(arena, m.id)) |i| try s.write(p.issues[i].id);
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

const testing = std.testing;
const GitSim = issuez.backend.GitSim;

/// Writes with `render` and parses the result back.
fn roundTrip(arena: Allocator, render: anytype, args: anytype) !std.json.Value {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = begin(&out.writer);
    try @call(.auto, render, .{&s} ++ args);
    end(&s);
    // The parser rejects text that isn't UTF-8.
    return std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
}

fn expectKeys(expected: []const []const u8, v: std.json.Value) !void {
    const keys = v.object.keys();
    testing.expectEqual(expected.len, keys.len) catch |err| {
        for (keys) |k| std.debug.print("{s}\n", .{k});
        return err;
    };
    for (expected, keys) |e, k| try testing.expectEqualStrings(e, k);
}

const ada: issuez.backend.object.Signature = .{
    .name = "Ada",
    .email = "ada@example.com",
    .time = 1760999758,
    .tz_offset_minutes = 330,
};

test "the documented keys, in order" {
    // docs/json.md promises these. Adding a key means adding it here and
    // there; renaming or removing one breaks scripts.
    const issue_keys = [_][]const u8{
        "id",        "short_id",    "title",    "state",     "deleted",
        "labels",    "assignee",    "priority", "milestone", "milestone_id",
        "parent",    "blocked_by",  "start",    "due",       "estimate_minutes",
        "workflow",  "author",      "created",  "updated",   "fields",
        "conflicts", "attachments",
    };
    const projection_keys = [_][]const u8{
        "effective_milestone_id", "effective_workflow", "progress", "blocked", "problems",
    };
    const full_keys = [_][]const u8{ "description", "comments" };
    const comment_keys = [_][]const u8{
        "id",    "author", "date",    "subject",     "text", "state_change",
        "merge", "edited", "deleted", "attachments",
    };
    const attachment_keys = [_][]const u8{
        "id", "name", "media_type", "size", "sha256", "added_in", "added_by", "availability",
    };
    const milestone_keys = [_][]const u8{
        "id", "short_id", "name", "status", "due", "description", "conflicts",
    };
    const problem_keys = [_][]const u8{ "kind", "other", "key", "value", "description" };

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 7, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = issuez.Repo(GitSim).init(&sim);
    const catalog = issuez.milestone.Catalog(GitSim).init(&sim);
    _ = try catalog.create(arena, .{ .name = "v1", .due = "2026-12-01" });
    const created = try repo.create(arena, .{ .title = "Epic" });
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});
    _ = try repo.comment(arena, ref, .{ .text = "Hello" });
    const issues = try repo.loadAll(arena);
    // As another tool could write it, for a problem.
    issues[0].ext.parent = "00000000-0000-4000-8000-000000000000";
    const proj = try issuez.projection.build(arena, issues, .{});

    const short = try roundTrip(arena, issue, .{ arena, issues[0], IssueOptions{} });
    try expectKeys(&issue_keys, short);
    const projected = try roundTrip(arena, issue, .{ arena, issues[0], IssueOptions{ .projection = proj } });
    try expectKeys(&(issue_keys ++ projection_keys), projected);
    const full = try roundTrip(
        arena,
        issue,
        .{ arena, issues[0], IssueOptions{ .full = true, .projection = proj } },
    );
    try expectKeys(&(issue_keys ++ projection_keys ++ full_keys), full);
    try expectKeys(&comment_keys, full.object.get("comments").?.array.items[0]);
    const problems = projected.object.get("problems").?.array.items;
    try testing.expectEqualStrings("parent_missing", problems[0].object.get("kind").?.string);
    try expectKeys(&problem_keys, problems[0]);

    const a: issuez.model.issue.Attachment = .{
        .id = "720964d9-80f3-4953-bf91-3b32b2897504",
        .media = .png,
        .size = 45,
        .sha256 = .of("png"),
        .name = "shot.png",
        .added_in = issues[0].root,
        .added_by = ada,
    };
    try expectKeys(&attachment_keys, try roundTrip(arena, attachment, .{ a, "local" }));
    const listed = try roundTrip(arena, attachment, .{ a, null });
    try expectKeys(attachment_keys[0 .. attachment_keys.len - 1], listed);

    const ms = (try catalog.list(arena))[0];
    try expectKeys(&milestone_keys, try roundTrip(arena, milestone, .{ms}));
    const detail = try roundTrip(arena, milestoneDetail, .{ arena, ms, proj });
    try expectKeys(&(milestone_keys ++ [_][]const u8{ "progress", "issues" }), detail);
}

test "values: nulls, dates, times with the author's offset" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var world: GitSim.World = .{ .seed = 8, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = issuez.Repo(GitSim).init(&sim);
    for ([_]i16{ 330, -90, 0 }) |tz| {
        var author = ada;
        author.tz_offset_minutes = tz;
        _ = try repo.create(arena, .{
            .title = "Dated",
            .labels = &.{ "ui", "bug" },
            .assignee = "11111111-2222-4333-8444-555555555555 ada@example.com",
            .due_date = "2028-02-29",
            .estimate_minutes = 90,
            .author = author,
        });
    }
    _ = try repo.create(arena, .{ .title = "Bare", .author = ada });
    var created: [3][]const u8 = undefined;
    for (try repo.loadAll(arena)) |i| {
        const v = try roundTrip(arena, issue, .{ arena, i, IssueOptions{} });
        const o = v.object;
        if (std.mem.eql(u8, i.title, "Bare")) {
            for ([_][]const u8{
                "assignee", "priority", "milestone",        "milestone_id", "parent",
                "start",    "due",      "estimate_minutes", "workflow",
            }) |k| try testing.expect(o.get(k).? == .null);
            try testing.expectEqual(@as(usize, 0), o.get("labels").?.array.items.len);
            try testing.expectEqual(@as(usize, 0), o.get("fields").?.object.count());
            continue;
        }
        // The email, also for the `<uuid> <email>` form.
        try testing.expectEqualStrings("ada@example.com", o.get("assignee").?.string);
        try testing.expectEqualStrings("2028-02-29", o.get("due").?.string);
        try testing.expectEqual(@as(i64, 90), o.get("estimate_minutes").?.integer);
        try testing.expectEqualStrings("ui", o.get("labels").?.array.items[0].string);
        try testing.expectEqualStrings(i.id, o.get("id").?.string);
        try testing.expectEqualStrings(i.id[0..7], o.get("short_id").?.string);
        const index: usize = switch (i.author.tz_offset_minutes) {
            330 => 0,
            -90 => 1,
            else => 2,
        };
        created[index] = o.get("created").?.string;
    }
    try testing.expectEqualStrings("2025-10-21T04:05:58+05:30", created[0]);
    try testing.expectEqualStrings("2025-10-20T21:05:58-01:30", created[1]);
    try testing.expectEqualStrings("2025-10-20T22:35:58+00:00", created[2]);

    // `updated` has the offset of whoever wrote last.
    const bare = for (try repo.loadAll(arena)) |i| {
        if (std.mem.eql(u8, i.title, "Bare")) break i;
    } else unreachable;
    var later = ada;
    later.time += 3600;
    later.tz_offset_minutes = -300;
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{bare.id});
    _ = try repo.comment(arena, ref, .{ .text = "Later", .author = later });
    const commented = try repo.load(arena, (try repo.resolve(arena, bare.id)).one);
    const o = (try roundTrip(arena, issue, .{ arena, commented, IssueOptions{} })).object;
    try testing.expectEqualStrings("2025-10-21T04:05:58+05:30", o.get("created").?.string);
    try testing.expectEqualStrings("2025-10-20T18:35:58-05:00", o.get("updated").?.string);
}

test "text that isn't UTF-8 is still a string" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const field_value = struct {
        fn f(s: *Stringify, v: []const u8) Error!void {
            try s.beginObject();
            try field(s, "v", v);
            try s.endObject();
        }
    }.f;
    var long: std.ArrayList(u8) = .empty;
    // Longer than fmtUtf8's buffer, so the escaping writer sees it in parts.
    for (0..200) |_| try long.appendSlice(arena, "\"\\\xff\x01é");
    const cases = [_][]const u8{
        "plain",             "q\"uo\\te\ttab\x01ctl",
        "\xff\xfe bad é",
        "cut \xe2\x82",      "surrogate \xed\xa0\x80",
        "overlong \xc0\xaf", long.items,
    };
    for (cases) |c| {
        const v = try roundTrip(arena, field_value, .{c});
        const want = try std.fmt.allocPrint(arena, "{f}", .{std.unicode.fmtUtf8(c)});
        try testing.expectEqualStrings(want, v.object.get("v").?.string);
    }

    // Through an issue, where every text field takes this path.
    var world: GitSim.World = .{ .seed = 9, .clones = &.{.{ .name = "a" }} };
    var sim = try GitSim.init(arena, &world, 0);
    const repo = issuez.Repo(GitSim).init(&sim);
    const bad = "Login \xff broken";
    const created = try repo.create(arena, .{ .title = bad, .body = "Body \xfe" });
    const ref = try std.fmt.allocPrint(arena, "refs/issues/{s}", .{created.id.slice()});
    _ = try repo.comment(arena, ref, .{ .text = "Sub \xc3\n\nText \xff" });
    const i = try repo.load(arena, (try repo.refs(arena))[0]);
    const v = try roundTrip(arena, issue, .{ arena, i, IssueOptions{ .full = true } });
    const o = v.object;
    try testing.expectEqualStrings("Login \u{FFFD} broken", o.get("title").?.string);
    try testing.expectEqualStrings("Body \u{FFFD}", o.get("description").?.string);
    const comment = o.get("comments").?.array.items[0].object;
    try testing.expectEqualStrings("Sub \u{FFFD}", comment.get("subject").?.string);
    try testing.expectEqualStrings("Text \u{FFFD}", comment.get("text").?.string);
}

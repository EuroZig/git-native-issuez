//! The tools over JSON-RPC, on the in-memory simulator.

const std = @import("std");
const issuez = @import("issuez");
const mcp = @import("blitzmcp");
const tools = @import("tools.zig");

const testing = std.testing;
const GitSim = issuez.backend.GitSim;

const SimRepos = struct {
    sim: *GitSim,

    pub const Backend = GitSim;

    pub fn open(r: *SimRepos, _: *mcp.Context, _: ?[]const u8) !*GitSim {
        return r.sim;
    }

    pub fn close(_: *SimRepos, _: *GitSim) void {}
};

const Server = tools.Server(SimRepos, "0.0.0-test");

const Harness = struct {
    arena: std.mem.Allocator,
    server: Server,
    next_id: u32 = 1,

    /// The `result` of a `tools/call`.
    fn call(h: *Harness, name: []const u8, arguments: []const u8) !std.json.ObjectMap {
        const id = h.next_id;
        h.next_id += 1;
        const msg = try std.fmt.allocPrint(
            h.arena,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}",
            .{ id, name, arguments },
        );
        var reader: std.Io.Reader = .fixed("");
        var out: std.Io.Writer.Allocating = .init(h.arena);
        var stream: mcp.Transport.Stream = .init(&reader, &out.writer);
        try h.server.handleMessage(testing.io, testing.allocator, &stream.transport, msg);
        const response = try std.json.parseFromSliceLeaky(std.json.Value, h.arena, out.written(), .{});
        return response.object.get("result").?.object;
    }

    /// `structuredContent` of a call that must succeed.
    fn ok(h: *Harness, name: []const u8, arguments: []const u8) !std.json.ObjectMap {
        const result = try h.call(name, arguments);
        if (result.get("isError")) |e| if (e.bool) {
            std.debug.print("{s} failed: {s}\n", .{ name, result.get("content").?.array.items[0].object.get("text").?.string });
            return error.TestUnexpectedResult;
        };
        return result.get("structuredContent").?.object;
    }

    /// The error text of a call that must fail.
    fn failed(h: *Harness, name: []const u8, arguments: []const u8) ![]const u8 {
        const result = try h.call(name, arguments);
        try testing.expect(result.get("isError").?.bool);
        return result.get("content").?.array.items[0].object.get("text").?.string;
    }
};

fn str(o: std.json.ObjectMap, key: []const u8) []const u8 {
    return o.get(key).?.string;
}

test "create, list, show, comment, edit and close" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var world: GitSim.World = .{
        .identity = .{ .name = "Ada", .email = "ada@example.invalid" },
        .clones = &.{.{ .name = "local" }},
    };
    var sim = try GitSim.init(arena, &world, 0);
    var repos: SimRepos = .{ .sim = &sim };
    var handler: tools.Handler(SimRepos) = .{ .repos = &repos };
    var h: Harness = .{ .arena = arena, .server = .init(&handler) };
    h.server.connection.markInitialized(.{
        .protocolVersion = mcp.types.latest_protocol_version,
        .capabilities = .{},
        .clientInfo = .{ .name = "test", .version = "0" },
    });

    const parent = try h.ok("create_issue",
        \\{"title":"Release 1.0","labels":["release"],"priority":"high","due":"2026-12-01"}
    );
    const parent_id = str(parent, "id");
    const child_args = try std.fmt.allocPrint(arena,
        \\{{"title":"Write the changelog","description":"Every change since 0.1.","parent":"{s}","estimate":"1h30m","workflow":"ready"}}
    , .{str(parent, "short_id")});
    const child = try h.ok("create_issue", child_args);
    const child_id = str(child, "id");

    // The parent has an open sub-issue, so it can't be closed yet.
    const close_parent = try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"state\":\"closed\"}}", .{parent_id});
    try testing.expectEqualStrings(
        "the issue has open sub-issues; close them first",
        try h.failed("set_issue_state", close_parent),
    );

    const listed = try h.ok("list_issues", "{}");
    try testing.expectEqual(@as(i64, 2), listed.get("total").?.integer);
    // Newest first.
    const first = listed.get("issues").?.array.items[0].object;
    try testing.expectEqualStrings(child_id, str(first, "id"));
    try testing.expectEqualStrings(parent_id, str(first, "parent"));
    try testing.expectEqual(@as(i64, 90), first.get("estimate_minutes").?.integer);
    const second = listed.get("issues").?.array.items[1].object;
    try testing.expectEqualStrings("high", str(second, "priority"));
    try testing.expectEqualStrings("2026-12-01", str(second, "due"));
    try testing.expectEqual(@as(i64, 1), second.get("progress").?.object.get("total").?.integer);

    const comment_args = try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"text\":\"Started.\\n\\nDraft in the wiki.\"}}", .{child_id[0..8]});
    const commented = try h.ok("comment_issue", comment_args);

    // A stale version is refused.
    const stale = try std.fmt.allocPrint(arena,
        \\{{"id":"{s}","title":"Changelog","expect_version":"{s}"}}
    , .{ child_id, str(child, "version") });
    try testing.expectEqualStrings(
        "the issue changed since expect_version; read it again",
        try h.failed("edit_issue", stale),
    );
    const edit_args = try std.fmt.allocPrint(arena,
        \\{{"id":"{s}","title":"Changelog","add_labels":["docs"],"estimate":"","workflow":"in-progress","expect_version":"{s}"}}
    , .{ child_id, str(commented, "version") });
    const edited = try h.ok("edit_issue", edit_args);
    try testing.expectEqual(@as(usize, 4), edited.get("changes").?.array.items.len);
    const bad_workflow = try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"workflow\":\"done\"}}", .{child_id});
    try testing.expectEqualStrings(
        "unknown workflow state 'done' (one of: backlog, ready, in-progress, review)",
        try h.failed("edit_issue", bad_workflow),
    );

    const with_body = try std.fmt.allocPrint(arena,
        \\{{"id":"{s}","description":"New.","message":"Subject\n\nBody"}}
    , .{child_id});
    try testing.expectEqualStrings(
        "with description, message is only the commit subject: no blank lines",
        try h.failed("edit_issue", with_body),
    );

    const show_args = try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\"}}", .{child_id[0..7]});
    const shown = try h.ok("show_issue", show_args);
    const issue = shown.get("issue").?.object;
    try testing.expectEqualStrings("Changelog", str(issue, "title"));
    try testing.expectEqualStrings("in-progress", str(issue, "workflow"));
    try testing.expect(issue.get("estimate_minutes") == null or issue.get("estimate_minutes").? == .null);
    try testing.expectEqualStrings("Every change since 0.1.", str(shown, "description"));
    const comments = shown.get("comments").?.array.items;
    // The comment and the edit.
    try testing.expectEqual(@as(usize, 2), comments.len);
    try testing.expectEqualStrings("Started.", str(comments[0].object, "subject"));
    try testing.expectEqualStrings("Draft in the wiki.", str(comments[0].object, "text"));
    try testing.expectEqualStrings("comment", str(comments[0].object, "kind"));
    try testing.expectEqualStrings("update", str(comments[1].object, "kind"));

    const close_child = try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"state\":\"closed\",\"reason\":\"completed\"}}", .{child_id});
    _ = try h.ok("set_issue_state", close_child);
    const closed = try h.ok("set_issue_state", close_parent);
    try testing.expectEqualStrings("closed", str(closed, "state"));
    // What set_issue_state wrote is readable.
    const reason = (try h.ok("show_issue", show_args)).get("issue").?.object.get("fields").?.array.items;
    var found_reason = false;
    for (reason) |f| if (std.mem.eql(u8, str(f.object, "key"), "Reason")) {
        try testing.expectEqualStrings("completed", str(f.object, "value"));
        found_reason = true;
    };
    try testing.expect(found_reason);

    try testing.expectEqual(@as(i64, 0), (try h.ok("list_issues", "{}")).get("total").?.integer);
    try testing.expectEqual(@as(i64, 2), (try h.ok("list_issues", "{\"state\":\"closed\"}")).get("total").?.integer);

    const found = try h.ok("search_issues", "{\"text\":\"wiki\"}");
    try testing.expectEqual(@as(i64, 1), found.get("total").?.integer);
    const results = found.get("results").?.array.items;
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("Draft in the wiki.", results[0].object.get("matches").?.array.items[0].string);

    try testing.expectEqualStrings("no issue 'ffff'", try h.failed("show_issue", "{\"id\":\"ffff\"}"));

    // Every issue says `State: closed`; the limit caps the results.
    const capped = try h.ok("search_issues", "{\"text\":\"State\",\"limit\":1}");
    try testing.expectEqual(@as(i64, 2), capped.get("total").?.integer);
    try testing.expectEqual(@as(usize, 1), capped.get("results").?.array.items.len);
    try testing.expectEqualStrings(
        "the title or text must not be empty",
        try h.failed("create_issue", "{\"title\":\" \"}"),
    );
    try testing.expectEqualStrings(
        "labels must not contain commas or newlines",
        try h.failed("create_issue", "{\"title\":\"x\",\"labels\":[\"a,b\"]}"),
    );
}

test "milestones by name, as text and cleared" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var world: GitSim.World = .{
        .identity = .{ .name = "Ada", .email = "ada@example.invalid" },
        .clones = &.{.{ .name = "local" }},
    };
    var sim = try GitSim.init(arena, &world, 0);
    const v1 = try issuez.Catalog(GitSim).init(&sim).create(arena, .{ .name = "v1" });
    var repos: SimRepos = .{ .sim = &sim };
    var handler: tools.Handler(SimRepos) = .{ .repos = &repos };
    var h: Harness = .{ .arena = arena, .server = .init(&handler) };
    h.server.connection.markInitialized(.{
        .protocolVersion = mcp.types.latest_protocol_version,
        .capabilities = .{},
        .clientInfo = .{ .name = "test", .version = "0" },
    });

    const created = try h.ok("create_issue", "{\"title\":\"Ship\",\"milestone\":\"v1\"}");
    const id = str(created, "id");
    const show = try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\"}}", .{id});
    var issue = (try h.ok("show_issue", show)).get("issue").?.object;
    try testing.expectEqualStrings(v1.id.slice(), str(issue, "milestone_id"));

    // Plain text replaces the catalog link.
    _ = try h.ok("edit_issue", try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"milestone\":\"someday\"}}", .{id}));
    issue = (try h.ok("show_issue", show)).get("issue").?.object;
    try testing.expectEqualStrings("someday", str(issue, "milestone"));
    try testing.expect(issue.get("effective_milestone_id") == null or issue.get("effective_milestone_id").? == .null);

    try testing.expectEqualStrings(
        "give milestone or milestone_id, not both",
        try h.failed("edit_issue", try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"milestone\":\"v1\",\"milestone_id\":\"v1\"}}", .{id})),
    );
    _ = try h.ok("edit_issue", try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"milestone\":\"\"}}", .{id}));
    issue = (try h.ok("show_issue", show)).get("issue").?.object;
    try testing.expect(issue.get("milestone") == null or issue.get("milestone").? == .null);
}

test "tools/list" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var world: GitSim.World = .{
        .identity = .{ .name = "Ada", .email = "ada@example.invalid" },
        .clones = &.{.{ .name = "local" }},
    };
    var sim = try GitSim.init(arena, &world, 0);
    var repos: SimRepos = .{ .sim = &sim };
    var handler: tools.Handler(SimRepos) = .{ .repos = &repos };
    var server: Server = .init(&handler);
    server.connection.markInitialized(.{
        .protocolVersion = mcp.types.latest_protocol_version,
        .capabilities = .{},
        .clientInfo = .{ .name = "test", .version = "0" },
    });

    var reader: std.Io.Reader = .fixed("");
    var out: std.Io.Writer.Allocating = .init(arena);
    var stream: mcp.Transport.Stream = .init(&reader, &out.writer);
    try server.handleMessage(testing.io, testing.allocator, &stream.transport,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    const response = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const list = response.object.get("result").?.object.get("tools").?.array.items;
    const names = [_][]const u8{
        "list_issues",  "show_issue",    "search_issues", "list_milestones",
        "create_issue", "comment_issue", "edit_issue",    "set_issue_state",
    };
    try testing.expectEqual(names.len, list.len);
    for (names, list) |n, t| {
        try testing.expectEqualStrings(n, t.object.get("name").?.string);
        try testing.expect(t.object.get("outputSchema") != null);
    }
}

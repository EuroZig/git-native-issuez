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
    arena_state: std.heap.ArenaAllocator,
    arena: std.mem.Allocator,
    world: GitSim.World,
    sim: GitSim,
    repos: SimRepos,
    handler: tools.Handler(SimRepos),
    server: Server,
    next_id: u32,

    /// A server before `initialize`, on one simulated clone that is Ada's.
    fn createUninitialized() !*Harness {
        const h = try testing.allocator.create(Harness);
        errdefer testing.allocator.destroy(h);
        h.arena_state = .init(testing.allocator);
        errdefer h.arena_state.deinit();
        h.arena = h.arena_state.allocator();
        h.world = .{
            .identity = .{ .name = "Ada", .email = "ada@example.invalid" },
            .clones = &.{.{ .name = "local" }},
        };
        h.sim = try GitSim.init(h.arena, &h.world, 0);
        h.repos = .{ .sim = &h.sim };
        h.handler = .{ .repos = &h.repos };
        h.server = .init(&h.handler);
        h.next_id = 1;
        return h;
    }

    fn create() !*Harness {
        const h = try createUninitialized();
        h.server.connection.markInitialized(.{
            .protocolVersion = mcp.types.latest_protocol_version,
            .capabilities = .{},
            .clientInfo = .{ .name = "test", .version = "0" },
        });
        return h;
    }

    fn destroy(h: *Harness) void {
        h.arena_state.deinit();
        testing.allocator.destroy(h);
    }

    /// The parsed response to one JSON-RPC message.
    fn raw(h: *Harness, msg: []const u8) !std.json.ObjectMap {
        var reader: std.Io.Reader = .fixed("");
        var out: std.Io.Writer.Allocating = .init(h.arena);
        var stream: mcp.Transport.Stream = .init(&reader, &out.writer);
        try h.server.handleMessage(testing.io, testing.allocator, &stream.transport, msg);
        const response = try std.json.parseFromSliceLeaky(
            std.json.Value,
            h.arena,
            out.written(),
            .{},
        );
        return response.object;
    }

    /// The `result` of a `tools/call`.
    fn call(h: *Harness, name: []const u8, arguments: []const u8) !std.json.ObjectMap {
        const id = h.next_id;
        h.next_id += 1;
        const msg = try std.fmt.allocPrint(
            h.arena,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\"," ++
                "\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}",
            .{ id, name, arguments },
        );
        return (try h.raw(msg)).get("result").?.object;
    }

    /// The response to a request.
    fn send(h: *Harness, method: []const u8, params: []const u8) !std.json.ObjectMap {
        const id = h.next_id;
        h.next_id += 1;
        const msg = try std.fmt.allocPrint(
            h.arena,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
            .{ id, method, params },
        );
        return h.raw(msg);
    }

    /// The `result` of a request that must succeed.
    fn request(h: *Harness, method: []const u8, params: []const u8) !std.json.Value {
        const response = try h.send(method, params);
        if (response.get("error")) |e| {
            std.debug.print("{s} failed: {s}\n", .{ method, e.object.get("message").?.string });
            return error.TestUnexpectedResult;
        }
        return response.get("result").?;
    }

    /// The `error` of a request that must fail.
    fn requestError(h: *Harness, method: []const u8, params: []const u8) !std.json.ObjectMap {
        return (try h.send(method, params)).get("error").?.object;
    }

    /// A resource's JSON, parsed.
    fn readResource(h: *Harness, uri: []const u8) !std.json.Value {
        const params = try std.fmt.allocPrint(h.arena, "{{\"uri\":\"{s}\"}}", .{uri});
        const result = (try h.request("resources/read", params)).object;
        const contents = result.get("contents").?.array.items;
        try testing.expectEqual(@as(usize, 1), contents.len);
        try testing.expectEqualStrings(uri, str(contents[0].object, "uri"));
        try testing.expectEqualStrings("application/json", str(contents[0].object, "mimeType"));
        return std.json.parseFromSliceLeaky(
            std.json.Value,
            h.arena,
            str(contents[0].object, "text"),
            .{},
        );
    }

    /// `structuredContent` of a call that must succeed.
    fn ok(h: *Harness, name: []const u8, arguments: []const u8) !std.json.ObjectMap {
        const result = try h.call(name, arguments);
        if (result.get("isError")) |e| if (e.bool) {
            std.debug.print(
                "{s} failed: {s}\n",
                .{ name, result.get("content").?.array.items[0].object.get("text").?.string },
            );
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
    const h = try Harness.create();
    defer h.destroy();
    const arena = h.arena;
    // 2026-11-04 23:30 UTC: already the 5th an hour east.
    h.handler.zone = .{ .initial = 3600 };
    h.handler.now_s = 1_793_835_000;

    const parent = try h.ok("create_issue",
        \\{"title":"Release 1.0","labels":["release"],"priority":"high","due":"2026-12-01"}
    );
    const parent_id = str(parent, "id");
    const child_args = try std.fmt.allocPrint(arena,
        \\{{"title":"Write the changelog","description":"Every change since 0.1.",
        \\"parent":"{s}","estimate":"1h30m","workflow":"ready","start":"+2d","due":"eow"}}
    , .{str(parent, "short_id")});
    const child = try h.ok("create_issue", child_args);
    const child_id = str(child, "id");

    // The parent has an open sub-issue, so it can't be closed yet.
    try testing.expectEqualStrings(
        "due must be a date as YYYY-MM-DD, or like today, +3d, fri, eom, not 'soon'",
        try h.failed("create_issue", "{\"title\":\"Later\",\"due\":\"soon\"}"),
    );

    const close_parent = try std.fmt.allocPrint(
        arena,
        "{{\"id\":\"{s}\",\"state\":\"closed\"}}",
        .{parent_id},
    );
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
    // Relative to the local date, the 5th (a Thursday; the week ends on Sunday).
    try testing.expectEqualStrings("2026-11-07", str(first, "start"));
    try testing.expectEqualStrings("2026-11-08", str(first, "due"));
    const second = listed.get("issues").?.array.items[1].object;
    try testing.expectEqualStrings("high", str(second, "priority"));
    try testing.expectEqualStrings("2026-12-01", str(second, "due"));
    try testing.expectEqual(@as(i64, 1), second.get("progress").?.object.get("total").?.integer);

    const comment_args = try std.fmt.allocPrint(
        arena,
        "{{\"id\":\"{s}\",\"text\":\"Started.\\n\\nDraft in the wiki.\"}}",
        .{child_id[0..8]},
    );
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
        \\{{"id":"{s}","title":"Changelog","add_labels":["docs"],"estimate":"",
        \\"workflow":"in-progress","expect_version":"{s}"}}
    , .{ child_id, str(commented, "version") });
    const edited = try h.ok("edit_issue", edit_args);
    try testing.expectEqual(@as(usize, 4), edited.get("changes").?.array.items.len);
    const bad_workflow = try std.fmt.allocPrint(
        arena,
        "{{\"id\":\"{s}\",\"workflow\":\"done\"}}",
        .{child_id},
    );
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
    try testing.expect(
        issue.get("estimate_minutes") == null or issue.get("estimate_minutes").? == .null,
    );
    try testing.expectEqualStrings("Every change since 0.1.", str(shown, "description"));
    const comments = shown.get("comments").?.array.items;
    // The comment and the edit.
    try testing.expectEqual(@as(usize, 2), comments.len);
    try testing.expectEqualStrings("Started.", str(comments[0].object, "subject"));
    try testing.expectEqualStrings("Draft in the wiki.", str(comments[0].object, "text"));
    try testing.expectEqualStrings("comment", str(comments[0].object, "kind"));
    try testing.expectEqualStrings("update", str(comments[1].object, "kind"));

    const close_child = try std.fmt.allocPrint(
        arena,
        "{{\"id\":\"{s}\",\"state\":\"closed\",\"reason\":\"completed\"}}",
        .{child_id},
    );
    _ = try h.ok("set_issue_state", close_child);
    const closed = try h.ok("set_issue_state", close_parent);
    try testing.expectEqualStrings("closed", str(closed, "state"));
    // What set_issue_state wrote is readable.
    const reread = (try h.ok("show_issue", show_args)).get("issue").?.object;
    const reason = reread.get("fields").?.array.items;
    var found_reason = false;
    for (reason) |f| if (std.mem.eql(u8, str(f.object, "key"), "Reason")) {
        try testing.expectEqualStrings("completed", str(f.object, "value"));
        found_reason = true;
    };
    try testing.expect(found_reason);
    // Who closed it: the last write.
    const by = reread.get("closed").?.object;
    try testing.expectEqualStrings(str(reread, "version"), str(by, "commit"));
    try testing.expect(by.get("author").? == .object);

    try testing.expectEqual(@as(i64, 0), (try h.ok("list_issues", "{}")).get("total").?.integer);
    try testing.expectEqual(
        @as(i64, 2),
        (try h.ok("list_issues", "{\"state\":\"closed\"}")).get("total").?.integer,
    );

    const found = try h.ok("search_issues", "{\"text\":\"wiki\"}");
    try testing.expectEqual(@as(i64, 1), found.get("total").?.integer);
    const results = found.get("results").?.array.items;
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings(
        "Draft in the wiki.",
        results[0].object.get("matches").?.array.items[0].string,
    );

    try testing.expectEqualStrings(
        "no issue 'ffff'",
        try h.failed("show_issue", "{\"id\":\"ffff\"}"),
    );

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
    const h = try Harness.create();
    defer h.destroy();
    const arena = h.arena;
    const v1 = try issuez.Catalog(GitSim).init(&h.sim).create(arena, .{ .name = "v1" }, .{});

    const created = try h.ok("create_issue", "{\"title\":\"Ship\",\"milestone\":\"v1\"}");
    const id = str(created, "id");
    const show = try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\"}}", .{id});
    var issue = (try h.ok("show_issue", show)).get("issue").?.object;
    try testing.expectEqualStrings(v1.id, str(issue, "milestone_id"));

    // Plain text replaces the catalog link.
    _ = try h.ok(
        "edit_issue",
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"milestone\":\"someday\"}}", .{id}),
    );
    issue = (try h.ok("show_issue", show)).get("issue").?.object;
    try testing.expectEqualStrings("someday", str(issue, "milestone"));
    const effective = issue.get("effective_milestone_id");
    try testing.expect(effective == null or effective.? == .null);

    try testing.expectEqualStrings(
        "give milestone or milestone_id, not both",
        try h.failed(
            "edit_issue",
            try std.fmt.allocPrint(
                arena,
                "{{\"id\":\"{s}\",\"milestone\":\"v1\",\"milestone_id\":\"v1\"}}",
                .{id},
            ),
        ),
    );
    _ = try h.ok(
        "edit_issue",
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"milestone\":\"\"}}", .{id}),
    );
    issue = (try h.ok("show_issue", show)).get("issue").?.object;
    try testing.expect(issue.get("milestone") == null or issue.get("milestone").? == .null);
}

test "resources: list, templates, read" {
    const h = try Harness.create();
    defer h.destroy();
    const arena = h.arena;
    try testing.expect(Server.capabilities.resources != null);

    const listed = (try h.request("resources/list", "{}")).object;
    const uris = listed.get("resources").?.array.items;
    try testing.expectEqual(@as(usize, 2), uris.len);
    try testing.expectEqualStrings("git-issue://issues", str(uris[0].object, "uri"));
    try testing.expectEqualStrings("git-issue://milestones", str(uris[1].object, "uri"));
    const templates = (try h.request("resources/templates/list", "{}")).object;
    try testing.expectEqualStrings(
        "git-issue://issues/{id}",
        str(templates.get("resourceTemplates").?.array.items[0].object, "uriTemplate"),
    );

    const created = try h.ok("create_issue", "{\"title\":\"Read me as a resource\"}");
    const issues = try h.readResource("git-issue://issues");
    try testing.expectEqual(@as(i64, 1), issues.object.get("total").?.integer);
    const short = try std.fmt.allocPrint(
        arena,
        "git-issue://issues/{s}",
        .{str(created, "short_id")},
    );
    const one = try h.readResource(short);
    try testing.expectEqualStrings(
        "Read me as a resource",
        str(one.object.get("issue").?.object, "title"),
    );
    const milestones = try h.readResource("git-issue://milestones");
    try testing.expectEqual(@as(usize, 0), milestones.object.get("milestones").?.array.items.len);

    for ([_][]const u8{
        "git-issue://issues/0000000",
        "git-issue://nope",
        "git-issue://issues/",
        "file:///x",
    }) |uri| {
        const params = try std.fmt.allocPrint(arena, "{{\"uri\":\"{s}\"}}", .{uri});
        const err = try h.requestError("resources/read", params);
        try testing.expectEqual(@as(i64, -32002), err.get("code").?.integer);
    }
}

test "subscriptions: which a change touches" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var subs: tools.Subscriptions = .{};
    try subs.add(io, "git-issue://issues");
    try subs.add(io, "git-issue://issues/abc");
    try subs.add(io, "git-issue://issues/def");
    try subs.add(io, "git-issue://issues/abc");
    try testing.expectEqual(@as(u8, 3), subs.count);

    try testing.expectEqual(@as(usize, 0), (try subs.affected(io, arena, .{}, false)).len);
    const one = try subs.affected(io, arena, .{ .issues = &.{"abc12345"} }, false);
    try testing.expectEqual(@as(usize, 2), one.len);
    try testing.expectEqualStrings("git-issue://issues", one[0]);
    try testing.expectEqualStrings("git-issue://issues/abc", one[1]);
    try testing.expectEqual(
        @as(usize, 3),
        (try subs.affected(io, arena, .{ .milestones = true }, false)).len,
    );
    try testing.expectEqual(@as(usize, 3), (try subs.affected(io, arena, .{}, true)).len);

    subs.remove(io, "git-issue://issues");
    subs.remove(io, "git-issue://nope");
    const left = try subs.affected(io, arena, .{ .issues = &.{ "abc1", "def1" } }, false);
    try testing.expectEqual(@as(usize, 2), left.len);
}

test "resources/subscribe and unsubscribe" {
    const h = try Harness.create();
    defer h.destroy();
    try testing.expect(Server.capabilities.resources.?.subscribe.?);

    _ = try h.request("resources/subscribe", "{\"uri\":\"git-issue://issues\"}");
    _ = try h.request("resources/subscribe", "{\"uri\":\"git-issue://issues/abc\"}");
    try testing.expectEqual(@as(u8, 2), h.handler.subscriptions.count);
    const err = try h.requestError("resources/subscribe", "{\"uri\":\"git-issue://nope\"}");
    try testing.expectEqual(@as(i64, -32002), err.get("code").?.integer);
    _ = try h.request("resources/unsubscribe", "{\"uri\":\"git-issue://issues\"}");
    try testing.expectEqual(@as(u8, 1), h.handler.subscriptions.count);
}

test "tools/list" {
    const h = try Harness.create();
    defer h.destroy();

    const response = try h.raw(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    const list = response.get("result").?.object.get("tools").?.array.items;
    const names = [_][]const u8{
        "list_issues",     "show_issue",    "search_issues", "list_milestones",
        "create_issue",    "comment_issue", "edit_issue",    "react_issue",
        "set_issue_state",
    };
    try testing.expectEqual(names.len, list.len);
    for (names, list) |n, t| {
        try testing.expectEqualStrings(n, t.object.get("name").?.string);
        try testing.expect(t.object.get("outputSchema") != null);
    }
}

test "reactions, host fields and provenance" {
    const h = try Harness.create();
    defer h.destroy();
    const arena = h.arena;

    const created = try h.ok("create_issue",
        \\{"title":"Imported","fields":[{"key":"X-Forgejo-Project","value":"7"}],
        \\ "original_author":"octo@github","original_id":"gh-12"}
    );
    const id = str(created, "id");
    const commented = try h.ok("comment_issue", try std.fmt.allocPrint(arena,
        \\{{"id":"{s}","text":"Me too","original_author":"cat@github"}}
    , .{id}));
    const comment_id = str(commented, "comment_id");

    const on_issue = try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"emoji\":\":+1:\"}}", .{id});
    const first = try h.ok("react_issue", on_issue);
    try testing.expect(first.get("version").? == .string);
    // Twice the same: nothing to write.
    const again = try h.ok("react_issue", on_issue);
    try testing.expect(again.get("version") == null or again.get("version").? == .null);
    _ = try h.ok("react_issue", try std.fmt.allocPrint(arena,
        \\{{"id":"{s}","emoji":"heart","comment":"{s}"}}
    , .{ id, comment_id[0..8] }));
    try testing.expectEqualStrings(
        "no comment 'ffffffff' on this issue",
        try h.failed("react_issue", try std.fmt.allocPrint(arena,
            \\{{"id":"{s}","emoji":"heart","comment":"ffffffff"}}
        , .{id})),
    );
    try testing.expectEqualStrings(
        "an emoji is 1 to 64 bytes without whitespace or commas, not 'a b'",
        try h.failed("react_issue", try std.fmt.allocPrint(arena,
            \\{{"id":"{s}","emoji":"a b"}}
        , .{id})),
    );
    _ = try h.ok("edit_issue", try std.fmt.allocPrint(arena,
        \\{{"id":"{s}","fields":[{{"key":"X-Forgejo-Project","value":"8"}}]}}
    , .{id}));

    const shown = try h.ok(
        "show_issue",
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\"}}", .{id}),
    );
    try testing.expectEqualStrings("octo@github", str(shown, "original_author"));
    try testing.expectEqualStrings("gh-12", str(shown, "original_id"));
    const reactions = shown.get("reactions").?.array.items;
    try testing.expectEqual(@as(usize, 1), reactions.len);
    try testing.expectEqualStrings(":+1:", str(reactions[0].object, "emoji"));
    try testing.expectEqualStrings(
        "ada@example.invalid",
        reactions[0].object.get("users").?.array.items[0].string,
    );
    const comment = shown.get("comments").?.array.items[0].object;
    try testing.expectEqualStrings("cat@github", str(comment, "original_author"));
    try testing.expectEqualStrings(
        "heart",
        str(comment.get("reactions").?.array.items[0].object, "emoji"),
    );
    var project: ?[]const u8 = null;
    for (shown.get("issue").?.object.get("fields").?.array.items) |f| {
        if (std.mem.eql(
            u8,
            str(f.object, "key"),
            "X-Forgejo-Project",
        )) project = str(f.object, "value");
    }
    try testing.expectEqualStrings("8", project.?);
}

test "server/discover before initialize: an error clients fall back on" {
    // The stdio binding of protocol 2026-07-28: a client probes with
    // server/discover and falls back to initialize on any error but the
    // modern ones (-32020 to -32022). This server speaks 2025-11-25.
    const h = try Harness.createUninitialized();
    defer h.destroy();

    const response = try h.raw(
        \\{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{
        \\"io.modelcontextprotocol/protocolVersion":"2026-07-28",
        \\"io.modelcontextprotocol/clientCapabilities":{}}}}
    );
    try testing.expect(response.get("result") == null);
    const code = response.get("error").?.object.get("code").?.integer;
    try testing.expect(code < -32022 or code > -32020);
}

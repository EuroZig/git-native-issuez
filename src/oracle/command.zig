//! Commands as data. The fuzzer and the simulator tests build a `Command`,
//! render it with `argv` for the CLI, and hand the same value to the
//! oracle, which so never parses arguments. Issue IDs stay prefixes: the
//! oracle resolves them itself.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Command = union(enum) {
    /// Prints only, or isn't a command at all: nothing may change. As argv.
    read: []const []const u8,
    init: Init,
    create: Create,
    comment: Comment,
    state: State,
    edit: Edit,
    merge: Sync,
    push: Sync,
    sync: Sync,
    quarantine: Quarantine,
    close: Lifecycle,
    reopen: Lifecycle,
    delete: Lifecycle,
    restore: Lifecycle,
    comment_event: CommentEvent,

    /// The CLI's name for it, for messages and statistics.
    pub fn verb(c: Command) []const u8 {
        return switch (c) {
            .read => |words| if (words.len > 0) words[0] else "help",
            .comment_event => "comment",
            else => @tagName(c),
        };
    }

    /// Writes to issues or attachments when it succeeds.
    pub fn writes(c: Command) bool {
        return switch (c) {
            .read, .init, .merge, .push, .sync, .quarantine => false,
            else => true,
        };
    }

    pub fn argv(c: Command, arena: Allocator) Allocator.Error![]const []const u8 {
        var out: Argv = .{ .arena = arena };
        switch (c) {
            .read => |words| return words,
            .init => |x| {
                try out.word("init");
                for (x.remotes) |r| try out.word(r);
            },
            .create => |x| try x.render(&out),
            .comment => |x| try x.render(&out),
            .state => |x| try x.render(&out),
            .edit => |x| try x.render(&out),
            .merge, .push, .sync => |x| try x.render(&out, @tagName(c)),
            .quarantine => |x| try x.render(&out),
            .close, .reopen, .delete, .restore => |x| try x.render(&out, @tagName(c)),
            .comment_event => |x| try x.render(&out),
        }
        return out.list.items;
    }
};

const Argv = struct {
    arena: Allocator,
    list: std.ArrayList([]const u8) = .empty,

    fn word(a: *Argv, w: []const u8) Allocator.Error!void {
        try a.list.append(a.arena, w);
    }

    fn words(a: *Argv, ws: []const []const u8) Allocator.Error!void {
        try a.list.appendSlice(a.arena, ws);
    }

    /// `flag value`, when there is a value.
    fn opt(a: *Argv, flag: []const u8, value: ?[]const u8) Allocator.Error!void {
        if (value) |v| try a.words(&.{ flag, v });
    }

    /// `flag value` for each value.
    fn each(a: *Argv, flag: []const u8, values: []const []const u8) Allocator.Error!void {
        for (values) |v| try a.words(&.{ flag, v });
    }
};

pub const Init = struct {
    remotes: []const []const u8 = &.{},
};

pub const Create = struct {
    /// Empty, no title is given (the CLI refuses that).
    title: []const u8,
    body: ?[]const u8 = null,
    labels: []const []const u8 = &.{},
    assignee: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    milestone: ?[]const u8 = null,
    ext: Ext = .{},

    fn render(x: Create, out: *Argv) Allocator.Error!void {
        try out.word("create");
        try out.opt("-m", x.body);
        try out.each("-l", x.labels);
        try out.opt("-a", x.assignee);
        try out.opt("-p", x.priority);
        try out.opt("--milestone", x.milestone);
        try x.ext.render(out);
        // Last, so a title like `--` can't turn options into title words.
        if (x.title.len > 0) try out.word(x.title);
    }
};

/// Planning fields. References stay prefixes until the oracle resolves them.
pub const Ext = struct {
    parent: ?[]const u8 = null,
    blocked_by: []const []const u8 = &.{},
    /// Edit only.
    unblock: []const []const u8 = &.{},
    start: ?[]const u8 = null,
    due: ?[]const u8 = null,
    estimate: ?[]const u8 = null,
    workflow: ?[]const u8 = null,
    /// `--no-<field>`, edit only.
    clear: []const []const u8 = &.{},

    pub fn cleared(e: Ext, field: []const u8) bool {
        for (e.clear) |c| if (std.mem.eql(u8, c, field)) return true;
        return false;
    }

    pub fn isEmpty(e: Ext) bool {
        return e.parent == null and e.blocked_by.len == 0 and e.unblock.len == 0 and
            e.start == null and e.due == null and e.estimate == null and e.workflow == null and
            e.clear.len == 0;
    }

    fn render(e: Ext, out: *Argv) Allocator.Error!void {
        try out.opt("--parent", e.parent);
        try out.each("--blocked-by", e.blocked_by);
        try out.each("--unblock", e.unblock);
        try out.opt("--start", e.start);
        try out.opt("--due", e.due);
        try out.opt("--estimate", e.estimate);
        try out.opt("--workflow", e.workflow);
        for (e.clear) |f| try out.word(try std.fmt.allocPrint(out.arena, "--no-{s}", .{f}));
    }
};

pub const Comment = struct {
    id: []const u8,
    /// One `-m` each. None, the CLI refuses.
    paragraphs: []const []const u8 = &.{},

    fn render(x: Comment, out: *Argv) Allocator.Error!void {
        try out.words(&.{ "comment", x.id });
        try out.each("-m", x.paragraphs);
    }
};

pub const State = struct {
    id: []const u8,
    state: []const u8,
    /// `--open` and `--close` instead of `--state open|closed`.
    as_flag: bool = false,
    message: ?[]const u8 = null,
    fixed_by: ?[]const u8 = null,
    release: ?[]const u8 = null,
    reason: ?[]const u8 = null,

    fn render(x: State, out: *Argv) Allocator.Error!void {
        try out.words(&.{ "state", x.id });
        const flag: ?[]const u8 = if (!x.as_flag)
            null
        else if (std.mem.eql(u8, x.state, "open"))
            "--open"
        else if (std.mem.eql(u8, x.state, "closed")) "--close" else null;
        if (flag) |f| try out.word(f) else try out.opt("--state", x.state);
        try out.opt("-m", x.message);
        try out.opt("--fixed-by", x.fixed_by);
        try out.opt("--release", x.release);
        try out.opt("--reason", x.reason);
    }
};

/// Labels are combined with the previous label set: `set_labels` first,
/// then `add`, then `remove`.
pub const Edit = struct {
    id: []const u8,
    title: ?[]const u8 = null,
    set_labels: ?[]const []const u8 = null,
    add: []const []const u8 = &.{},
    /// Each may list several, comma separated.
    remove: []const []const u8 = &.{},
    assignee: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    milestone: ?[]const u8 = null,
    ext: Ext = .{},
    /// `--description`, written as its own commit after the other changes.
    description: []const []const u8 = &.{},

    /// Anything besides the description.
    pub fn changesFields(x: Edit) bool {
        return x.title != null or x.set_labels != null or x.add.len > 0 or
            x.remove.len > 0 or x.assignee != null or x.priority != null or
            x.milestone != null or !x.ext.isEmpty();
    }

    fn render(x: Edit, out: *Argv) Allocator.Error!void {
        try out.words(&.{ "edit", x.id });
        try out.opt("-t", x.title);
        try out.each("-l", x.set_labels orelse &.{});
        try out.each("--add-label", x.add);
        try out.each("--remove-label", x.remove);
        try out.opt("-a", x.assignee);
        try out.opt("-p", x.priority);
        try out.opt("--milestone", x.milestone);
        try x.ext.render(out);
        try out.each("--description", x.description);
    }
};

/// `merge`, `push` and `sync`.
pub const Sync = struct {
    remote: []const u8,
    /// merge only.
    check: bool = false,
    /// merge only.
    no_fetch: bool = false,

    fn render(x: Sync, out: *Argv, verb: []const u8) Allocator.Error!void {
        try out.words(&.{ verb, x.remote });
        if (x.check) try out.word("--check");
        if (x.no_fetch) try out.word("--no-fetch");
    }
};

pub const Quarantine = struct {
    remote: []const u8,
    id: []const u8,
    /// `--accept-remote`, else `--keep-local`.
    accept: bool,

    fn render(x: Quarantine, out: *Argv) Allocator.Error!void {
        const how = if (x.accept) "--accept-remote" else "--keep-local";
        try out.words(&.{ "quarantine", x.remote, how, x.id });
    }
};

/// `close`, `reopen`, `delete` and `restore`.
pub const Lifecycle = struct {
    id: []const u8,
    message: ?[]const u8 = null,

    fn render(x: Lifecycle, out: *Argv, verb: []const u8) Allocator.Error!void {
        try out.words(&.{ verb, x.id });
        try out.opt("-m", x.message);
    }
};

/// `comment <id> --edit|--delete|--restore <comment>`.
pub const CommentEvent = struct {
    id: []const u8,
    kind: enum { edit, delete, restore },
    /// A prefix of the comment's commit ID.
    target: []const u8,
    /// Edit only.
    text: ?[]const u8 = null,

    fn render(x: CommentEvent, out: *Argv) Allocator.Error!void {
        const flag = switch (x.kind) {
            .edit => "--edit",
            .delete => "--delete",
            .restore => "--restore",
        };
        try out.words(&.{ "comment", x.id, flag, x.target });
        try out.opt("-m", x.text);
    }
};

test "argv" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cmd: Command = .{ .state = .{ .id = "a7f3", .state = "closed", .as_flag = true } };
    const argv = try cmd.argv(arena);
    try std.testing.expectEqualStrings("state a7f3 --close", try std.mem.join(arena, " ", argv));
}

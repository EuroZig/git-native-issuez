//! Man pages, rendered from the help texts like the completions are.
//! `git-issue __manpages <dir>` is run by build.zig. Git turns
//! `git issue --help` into `man git-issue`.

const std = @import("std");
const Writer = std.Io.Writer;
const context = @import("context.zig");
const common = @import("common.zig");
const completion = @import("completion.zig");
const cmd_help = @import("cmd/help.zig");
const cmd_version = @import("cmd/version.zig");

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    if (B == @import("issuez").backend.GitSim) {
        ctx.err.writeAll("git-issue: '__manpages' is not available in the simulator.\n") catch {};
        return common.exit_error;
    }
    if (argv.len != 1) return common.missing(ctx.err, "__manpages", "output directory required");
    const dir_path = argv[0];
    const io = ctx.io;
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir_path) catch |e| return fail(ctx, dir_path, e);
    var dir = cwd.openDir(io, dir_path, .{}) catch |e| return fail(ctx, dir_path, e);
    defer dir.close(io);

    const spec = completion.parse(ctx.arena) catch return common.oom(ctx.err);
    var page: Writer.Allocating = .init(ctx.arena);
    writeMain(&page.writer, spec) catch return common.exit_error;
    dir.writeFile(io, .{ .sub_path = "git-issue.1", .data = page.written() }) catch |e|
        return fail(ctx, "git-issue.1", e);
    for (spec.commands) |c| {
        page.clearRetainingCapacity();
        writeCommand(&page.writer, c) catch return common.exit_error;
        const name = std.fmt.allocPrint(ctx.arena, "git-issue-{s}.1", .{c.name}) catch
            return common.exit_error;
        dir.writeFile(io, .{ .sub_path = name, .data = page.written() }) catch |e|
            return fail(ctx, name, e);
    }
    return common.exit_ok;
}

fn fail(ctx: anytype, path: []const u8, e: anyerror) u8 {
    ctx.err.print("error: cannot write '{s}': {t}\n", .{ path, e }) catch {};
    return common.exit_error;
}

/// `sub` is null for git-issue(1) itself.
fn header(w: *Writer, sub: ?[]const u8, summary: []const u8) Writer.Error!void {
    // No date, so the pages are reproducible.
    try w.writeAll(".TH GIT-ISSUE");
    if (sub) |s| {
        try w.writeByte('-');
        for (s) |c| try w.writeByte(std.ascii.toUpper(c));
    }
    try w.print(" 1 \"\" \"git-native-issuez {s}\" \"Git Manual\"\n", .{cmd_version.version});
    try w.writeAll(".SH NAME\ngit\\-issue");
    if (sub) |s| {
        try w.writeAll("\\-");
        try text(w, s);
    }
    try w.writeAll(" \\- ");
    try text(w, summary);
    try w.writeAll("\n");
}

pub fn writeMain(w: *Writer, spec: completion.Spec) Writer.Error!void {
    try header(w, null, "distributed issue tracking stored in Git");
    try body(w, cmd_help.text, .{ .bold_first_column = true });
    try w.writeAll(
        \\.SH NOTES
        \\Issues are stored as commits under refs/issues/ in the git-native-issue
        \\format, so this tool and upstream git-native-issue read and write the same
        \\issues. Provider import and export (GitHub, GitLab, Gitea, Azure DevOps)
        \\stay with upstream git-native-issue.
        \\
    );
    try w.writeAll(".SH SEE ALSO\n");
    for (spec.commands, 0..) |c, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.print("\\fBgit\\-issue\\-", .{});
        try text(w, c.name);
        try w.writeAll("\\fR(1)");
    }
    try w.writeAll(",\n\\fBgit\\fR(1)\n");
}

pub fn writeCommand(w: *Writer, c: completion.Command) Writer.Error!void {
    const help = completion.helpOf(c.name).?;
    try header(w, c.name, c.desc);
    try body(w, help, .{ .bold_first_column = false });
    if (c.options.len > 0) {
        try w.writeAll(".SH OPTIONS\n");
        for (c.options) |o| {
            try w.writeAll(".TP\n");
            if (o.short) |s| {
                try w.writeAll("\\fB");
                try text(w, s);
                try w.writeAll("\\fR");
                if (o.long != null) try w.writeAll(", ");
            }
            if (o.long) |l| {
                try w.writeAll("\\fB");
                try text(w, l);
                try w.writeAll("\\fR");
            }
            if (o.value) |v| {
                try w.writeAll(" \\fI");
                try text(w, v);
                try w.writeAll("\\fR");
            }
            try w.writeAll("\n");
            try line(w, o.desc);
        }
    }
    try w.writeAll(".SH SEE ALSO\n\\fBgit\\-issue\\fR(1)\n");
}

const BodyOptions = struct {
    bold_first_column: bool,
};

/// Everything but the `Options:` section, which becomes OPTIONS.
fn body(w: *Writer, help: []const u8, options: BodyOptions) Writer.Error!void {
    var lines = std.mem.splitScalar(u8, help, '\n');
    const usage = lines.first();
    try w.writeAll(".SH SYNOPSIS\n.nf\n");
    const prefix = "usage: ";
    try line(w, if (std.mem.startsWith(u8, usage, prefix)) usage[prefix.len..] else usage);
    try w.writeAll(".fi\n.SH DESCRIPTION\n");

    var in_options = false;
    var at_section_start = true;
    var in_paragraph = false;
    while (lines.next()) |l| {
        if (std.mem.trim(u8, l, " ").len == 0) {
            in_options = false;
            in_paragraph = false;
            continue;
        }
        const indented = l[0] == ' ';
        if (!indented and l[l.len - 1] == ':' and std.mem.count(u8, l, " ") < 3) {
            // A heading. A sentence ending in ':' introduces a list instead.
            if (std.mem.eql(u8, l, "Options:")) {
                in_options = true;
                continue;
            }
            try w.writeAll(".SS ");
            try line(w, l[0 .. l.len - 1]);
            at_section_start = true;
            in_paragraph = false;
            continue;
        }
        if (in_options) continue;
        if (!indented) {
            if (!in_paragraph and !at_section_start) try w.writeAll(".PP\n");
            in_paragraph = true;
            at_section_start = false;
            try line(w, l);
            continue;
        }
        in_paragraph = false;
        at_section_start = false;
        const item = std.mem.trimStart(u8, l, " ");
        if (std.mem.startsWith(u8, item, "- ")) {
            try w.writeAll(".IP \\(bu 2\n");
            try line(w, item[2..]);
        } else if (std.mem.find(u8, item, "  ")) |gap| {
            try w.writeAll(".TP\n");
            if (options.bold_first_column) try w.writeAll("\\fB");
            try text(w, item[0..gap]);
            if (options.bold_first_column) try w.writeAll("\\fR");
            try w.writeAll("\n");
            try line(w, std.mem.trim(u8, item[gap..], " "));
        } else {
            try w.writeAll(".RS\n");
            try line(w, item);
            try w.writeAll(".RE\n");
        }
    }
}

fn line(w: *Writer, s: []const u8) Writer.Error!void {
    if (s.len > 0 and (s[0] == '.' or s[0] == '\'')) try w.writeAll("\\&");
    try text(w, s);
    try w.writeAll("\n");
}

fn text(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\e"),
        '-' => try w.writeAll("\\-"),
        else => try w.writeByte(c),
    };
}

const testing = std.testing;

test "every page renders with the standard sections" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const spec = try completion.parse(arena);

    var main_page: Writer.Allocating = .init(arena);
    try writeMain(&main_page.writer, spec);
    for ([_][]const u8{ ".TH GIT-ISSUE 1", ".SH NAME", ".SH SYNOPSIS", ".SH SEE ALSO" }) |s| {
        try testing.expect(std.mem.find(u8, main_page.written(), s) != null);
    }
    try testing.expect(std.mem.find(u8, main_page.written(), "\\fBcreate\\fR") != null);

    for (spec.commands) |c| {
        var page: Writer.Allocating = .init(arena);
        try writeCommand(&page.writer, c);
        const out = page.written();
        try testing.expect(std.mem.startsWith(u8, out, ".TH GIT-ISSUE-"));
        try testing.expect(std.mem.find(u8, out, ".SH OPTIONS\n") != null);
        try testing.expect(std.mem.find(u8, out, "\\fB\\-\\-help\\fR") != null);
        // Nothing roff would read as a request.
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |l| {
            if (l.len == 0 or l[0] != '.') continue;
            const known = [_][]const u8{
                ".TH", ".SH", ".SS", ".PP", ".TP", ".IP", ".RS", ".RE", ".nf", ".fi",
            };
            var ok = false;
            for (known) |k| if (std.mem.startsWith(u8, l, k)) {
                ok = true;
            };
            testing.expect(ok) catch |err| {
                std.debug.print("{s}: unexpected request line '{s}'\n", .{ c.name, l });
                return err;
            };
        }
    }
}

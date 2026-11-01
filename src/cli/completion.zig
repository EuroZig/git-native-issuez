//! `git issue completion <bash|zsh|fish>`. The scripts are generated from
//! the help texts, so they can't drift from what the commands accept.
//! Each one covers `git-issue`, `git issue` (through the shell's git
//! completion) and the `git-issue-<sub>` entry points.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const context = @import("context.zig");
const common = @import("common.zig");
const entry_points = @import("entry_points.zig");
const cmd_help = @import("cmd/help.zig");
const cmd_version = @import("cmd/version.zig");

pub const help =
    \\usage: git issue completion <shell>
    \\
    \\Print a completion script for bash, zsh or fish. It completes
    \\`git issue`, `git-issue` and the `git-issue-<sub>` commands, including
    \\issue IDs and remote names. To load it:
    \\
    \\   bash:  git issue completion bash > ~/.local/share/bash-completion/completions/git-issue
    \\   zsh:   git issue completion zsh > "${fpath[1]}/_git-issue"
    \\   fish:  git issue completion fish > ~/.config/fish/completions/git-issue.fish
    \\
    \\`zig build install` installs them under share/ of the prefix.
    \\
    \\Options:
    \\   -h, --help    Show this help
    \\
;

pub const Shell = enum { bash, zsh, fish };

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    var shell: ?Shell = null;
    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            if (shell != null) return common.missing(ctx.err, "completion", "only one shell");
            shell = std.meta.stringToEnum(Shell, arg) orelse return common.missing(
                ctx.err,
                "completion",
                "shell must be bash, zsh or fish",
            );
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else {
            return common.unknownOption(ctx.err, "completion", arg);
        }
    }
    const s = shell orelse return common.missing(ctx.err, "completion", "shell is required");
    const spec = parse(ctx.arena) catch |e| switch (e) {
        error.OutOfMemory => return common.exit_error,
    };
    write(ctx.out, s, spec) catch return common.exit_error;
    return common.exit_ok;
}

/// A test checks that this matches the top-level usage.
const command_helps = [_]struct { []const u8, []const u8 }{
    .{ "create", @import("cmd/create.zig").help },
    .{ "ls", @import("cmd/ls.zig").help },
    .{ "show", @import("cmd/show.zig").help },
    .{ "comment", @import("cmd/comment.zig").help },
    .{ "edit", @import("cmd/edit.zig").help },
    .{ "state", @import("cmd/state.zig").help },
    .{ "search", @import("cmd/search.zig").help },
    .{ "merge", @import("cmd/merge.zig").merge_help },
    .{ "fsck", @import("cmd/fsck.zig").help },
    .{ "init", @import("cmd/init.zig").help },
    .{ "version", cmd_version.help },
    .{ "push", @import("cmd/merge.zig").push_help },
    .{ "sync", @import("cmd/merge.zig").sync_help },
    .{ "status", @import("cmd/status.zig").help },
    .{ "tree", @import("cmd/tree.zig").help },
    .{ "close", @import("cmd/close.zig").close_help },
    .{ "reopen", @import("cmd/close.zig").reopen_help },
    .{ "delete", @import("cmd/delete.zig").delete_help },
    .{ "restore", @import("cmd/delete.zig").restore_help },
    .{ "milestone", @import("cmd/milestone.zig").help },
    .{ "attach", @import("cmd/attach.zig").help },
    .{ "quarantine", @import("cmd/quarantine.zig").help },
    .{ "completion", help },
};

pub const Option = struct {
    short: ?[]const u8,
    long: ?[]const u8,
    /// `level` in `<level>`.
    value: ?[]const u8,
    desc: []const u8,
};

pub const Command = struct {
    name: []const u8,
    desc: []const u8,
    positional: ?[]const u8,
    options: []const Option,
};

pub const Spec = struct { commands: []const Command };

pub fn parse(arena: Allocator) Allocator.Error!Spec {
    var commands: std.ArrayList(Command) = .empty;
    var lines = std.mem.splitScalar(u8, cmd_help.text, '\n');
    while (lines.next()) |line| {
        const entry = commandLine(line) orelse continue;
        const sub_help = helpOf(entry.name) orelse continue;
        try commands.append(arena, .{
            .name = entry.name,
            .desc = entry.desc,
            .positional = usagePositional(sub_help),
            .options = try options(arena, sub_help),
        });
    }
    return .{ .commands = commands.items };
}

pub fn helpOf(name: []const u8) ?[]const u8 {
    for (command_helps) |h| if (std.mem.eql(u8, h[0], name)) return h[1];
    return null;
}

fn commandLine(line: []const u8) ?struct { name: []const u8, desc: []const u8 } {
    if (!std.mem.startsWith(u8, line, "   ") or line.len < 4 or line[3] == ' ') return null;
    const rest = line[3..];
    const gap = std.mem.find(u8, rest, "  ") orelse return null;
    return .{ .name = rest[0..gap], .desc = std.mem.trim(u8, rest[gap..], " ") };
}

fn usagePositional(text: []const u8) ?[]const u8 {
    const first = text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len];
    var words = std.mem.tokenizeScalar(u8, first, ' ');
    var seen_command = false;
    while (words.next()) |raw| {
        if (std.mem.eql(u8, raw, "usage:") or std.mem.eql(u8, raw, "git") or
            std.mem.eql(u8, raw, "issue")) continue;
        if (!seen_command) {
            seen_command = true;
            continue;
        }
        const w = std.mem.trim(u8, raw, "[]");
        if (w.len > 2 and w[0] == '<' and w[w.len - 1] == '>') return w[1 .. w.len - 1];
    }
    return null;
}

/// Option lines, with indented continuation lines appended.
fn options(arena: Allocator, text: []const u8) Allocator.Error![]const Option {
    var out: std.ArrayList(Option) = .empty;
    var desc: std.ArrayList(u8) = .empty;
    var desc_column: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const indent = line.len - std.mem.trimStart(u8, line, " ").len;
        const body = line[indent..];
        if (out.items.len > 0 and desc_column > 0 and indent >= desc_column and body.len > 0) {
            try desc.append(arena, ' ');
            try desc.appendSlice(arena, body);
            out.items[out.items.len - 1].desc = try arena.dupe(u8, desc.items);
            continue;
        }
        desc_column = 0;
        if (indent == 0 or body.len < 2 or body[0] != '-' or body[1] == ' ') continue;
        const gap = std.mem.find(u8, body, "  ") orelse body.len;
        var opt: Option = .{ .short = null, .long = null, .value = null, .desc = "" };
        var parts = std.mem.tokenizeAny(u8, body[0..gap], ", ");
        while (parts.next()) |p| {
            if (std.mem.startsWith(u8, p, "--")) {
                opt.long = p;
            } else if (p[0] == '-') {
                opt.short = p;
            } else if (p.len > 2 and p[0] == '<') {
                opt.value = p[1 .. p.len - 1];
            }
        }
        const rest = body[gap..];
        opt.desc = std.mem.trim(u8, rest, " ");
        desc.clearRetainingCapacity();
        try desc.appendSlice(arena, opt.desc);
        desc_column = indent + gap + (rest.len - std.mem.trimStart(u8, rest, " ").len);
        try out.append(arena, opt);
    }
    return out.items;
}

const Kind = union(enum) {
    none,
    issue,
    remote,
    words: []const u8,
};

fn kindOf(command: []const u8, placeholder: ?[]const u8) Kind {
    const p = placeholder orelse return .none;
    const eql = std.mem.eql;
    if (eql(u8, p, "issue-id")) return .issue;
    if (eql(u8, p, "remote")) return .remote;
    if (eql(u8, p, "level")) return .{ .words = "low medium high critical" };
    if (eql(u8, p, "format")) return .{ .words = "short full oneline" };
    if (eql(u8, p, "field")) return .{ .words = "created updated priority state" };
    if (eql(u8, p, "reason")) return .{ .words = "duplicate wontfix invalid completed" };
    if (eql(u8, p, "shell")) return .{ .words = "bash zsh fish" };
    if (eql(u8, p, "subcommand") and eql(u8, command, "milestone")) {
        return .{ .words = "create ls show edit complete reopen retire" };
    }
    if (eql(u8, p, "subcommand") and eql(u8, command, "attach")) {
        return .{ .words = "add ls cat rename rm fetch" };
    }
    if (eql(u8, p, "state")) return .{ .words = "open closed all" };
    if (eql(u8, p, "value") and eql(u8, command, "state")) return .{ .words = "open closed" };
    return .none;
}

pub fn write(w: *Writer, shell: Shell, spec: Spec) Writer.Error!void {
    switch (shell) {
        .bash => try writeBash(w, spec),
        .zsh => try writeZsh(w, spec),
        .fish => try writeFish(w, spec),
    }
}

fn writeHeader(w: *Writer, shell: Shell) Writer.Error!void {
    try w.print(
        "# {t} completion for git-issue (git-native-issuez {s}).\n" ++
            "# Generated by `git issue completion {t}`; do not edit.\n",
        .{ shell, cmd_version.version, shell },
    );
}

fn writeBash(w: *Writer, spec: Spec) Writer.Error!void {
    try writeHeader(w, .bash);
    try w.writeAll(
        \\
        \\__git_issue_ids() {
        \\    git issue ls --all --format oneline 2>/dev/null | cut -d' ' -f1
        \\}
        \\
        \\__git_issue_reply() { # <words> (empty: no completion)
        \\    local cur="${COMP_WORDS[COMP_CWORD]}"
        \\    COMPREPLY=($(compgen -W "$1" -- "$cur"))
        \\}
        \\
        \\# $1: index of the subcommand word in COMP_WORDS, or of the first
        \\# argument when $2 names the subcommand (git-issue-<sub>).
        \\__git_issue_complete() {
        \\    local first="$1" sub="$2"
        \\    local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD-1]}"
        \\    if [ -z "$sub" ]; then
        \\        if [ "$COMP_CWORD" -le "$first" ]; then
        \\
    );
    try w.writeAll("            __git_issue_reply \"");
    for (spec.commands, 0..) |c, i| try w.print("{s}{s}", .{ if (i > 0) " " else "", c.name });
    try w.writeAll(
        \\"
        \\            return
        \\        fi
        \\        sub="${COMP_WORDS[first]}"
        \\    fi
        \\    case "$sub" in
        \\
    );
    for (spec.commands) |c| {
        try w.print("    {s})\n        case \"$prev\" in\n", .{c.name});
        for (c.options) |o| {
            if (o.value == null) continue;
            try w.writeAll("            ");
            try writeJoined(w, o, "|");
            try w.writeAll(") ");
            try bashKind(w, kindOf(c.name, o.value));
            try w.writeAll("; return ;;\n");
        }
        try w.writeAll("        esac\n        case \"$cur\" in\n");
        try w.writeAll("            -*) __git_issue_reply \"");
        for (c.options, 0..) |o, i| {
            if (i > 0) try w.writeAll(" ");
            try writeJoined(w, o, " ");
        }
        try w.writeAll("\" ;;\n            *) ");
        try bashKind(w, kindOf(c.name, c.positional));
        try w.writeAll(" ;;\n        esac ;;\n");
    }
    try w.writeAll(
        \\    esac
        \\}
        \\
        \\# `git issue ...`, called by git's own bash completion.
        \\_git_issue() {
        \\    local i=1
        \\    while [ "$i" -lt "$COMP_CWORD" ] && [ "${COMP_WORDS[i]}" != issue ]; do
        \\        i=$((i + 1))
        \\    done
        \\    __git_issue_complete $((i + 1)) ""
        \\}
        \\
        \\_git_issue_command() { __git_issue_complete 1 ""; }
        \\_git_issue_entry_point() { # $1: the command as typed, maybe with a path
        \\    local name="${1##*/}"
        \\    __git_issue_complete 1 "${name#git-issue-}"
        \\}
        \\
        \\complete -o bashdefault -F _git_issue_command git-issue
        \\
    );
    try w.writeAll("complete -o bashdefault -F _git_issue_entry_point");
    for (entry_points.names) |n| try w.print(" git-issue-{s}", .{n});
    try w.writeAll("\n");
}

fn writeJoined(w: *Writer, o: Option, sep: []const u8) Writer.Error!void {
    if (o.short) |s| try w.writeAll(s);
    if (o.short != null and o.long != null) try w.writeAll(sep);
    if (o.long) |l| try w.writeAll(l);
}

fn bashKind(w: *Writer, kind: Kind) Writer.Error!void {
    switch (kind) {
        .none => try w.writeAll("COMPREPLY=()"),
        .issue => try w.writeAll("__git_issue_reply \"$(__git_issue_ids)\""),
        .remote => try w.writeAll("__git_issue_reply \"$(git remote 2>/dev/null)\""),
        .words => |words| try w.print("__git_issue_reply \"{s}\"", .{words}),
    }
}

fn writeZsh(w: *Writer, spec: Spec) Writer.Error!void {
    try w.writeAll("#compdef git-issue");
    for (entry_points.names) |n| try w.print(" git-issue-{s}", .{n});
    try w.writeAll("\n");
    try writeHeader(w, .zsh);
    try w.writeAll(
        \\# Install as `_git-issue` in $fpath; zsh's `git` completion then also
        \\# completes `git issue ...`.
        \\
        \\__git_issue_ids() {
        \\    local -a ids
        \\    local line
        \\    for line in ${(f)"$(git issue ls --all --format oneline 2>/dev/null)"}; do
        \\        ids+=("${line%% *}:${${line#* }#* }")
        \\    done
        \\    _describe -t issues 'issue' ids
        \\}
        \\
        \\__git_issue_remotes() {
        \\    local -a remotes
        \\    remotes=(${(f)"$(git remote 2>/dev/null)"})
        \\    _describe -t remotes 'remote' remotes
        \\}
        \\
        \\_git-issue() {
        \\    local sub
        \\    if [[ $service == git-issue-?* ]]; then
        \\        sub=${service#git-issue-}
        \\    else
        \\        local curcontext=$curcontext state line
        \\        _arguments -C '1: :->command' '*:: :->argument'
        \\        if [[ $state == command ]]; then
        \\            local -a commands
        \\            commands=(
        \\
    );
    for (spec.commands) |c| {
        try w.writeAll("                ");
        try zshQuoted(w, c.name, c.desc, ':');
        try w.writeAll("\n");
    }
    try w.writeAll(
        \\            )
        \\            _describe -t commands 'git-issue command' commands
        \\            return
        \\        fi
        \\        sub=$words[1]
        \\    fi
        \\    case $sub in
        \\
    );
    for (spec.commands) |c| {
        try w.print("        {s})\n            _arguments -s", .{c.name});
        for (c.options) |o| {
            try w.writeAll(" \\\n                ");
            // Repeatable, so -l can be given again.
            if (o.short != null and o.long != null) {
                try w.print("'*'{{{s},{s}}}'", .{ o.short.?, o.long.? });
            } else {
                try w.print("'*{s}", .{o.short orelse o.long.?});
            }
            try w.writeAll("[");
            try zshEscaped(w, o.desc);
            try w.writeAll("]");
            if (o.value) |v| {
                try w.print(":{s}:", .{v});
                try zshAction(w, kindOf(c.name, o.value));
            }
            try w.writeAll("'");
        }
        if (c.positional) |p| {
            try w.print(" \\\n                '1:{s}:", .{p});
            try zshAction(w, kindOf(c.name, c.positional));
            try w.writeAll("'");
        }
        try w.writeAll(" ;;\n");
    }
    try w.writeAll(
        \\    esac
        \\}
        \\
        \\_git-issue "$@"
        \\
    );
}

fn zshAction(w: *Writer, kind: Kind) Writer.Error!void {
    switch (kind) {
        .none => try w.writeAll(" "),
        .issue => try w.writeAll("__git_issue_ids"),
        .remote => try w.writeAll("__git_issue_remotes"),
        .words => |words| try w.print("({s})", .{words}),
    }
}

fn zshQuoted(w: *Writer, name: []const u8, desc: []const u8, sep: u8) Writer.Error!void {
    try w.print("'{s}{c}", .{ name, sep });
    try zshEscaped(w, desc);
    try w.writeAll("'");
}

fn zshEscaped(w: *Writer, text: []const u8) Writer.Error!void {
    for (text) |c| switch (c) {
        '\'' => try w.writeAll("'\\''"),
        '[', ']', ':' => try w.print("\\{c}", .{c}),
        else => try w.writeByte(c),
    };
}

fn writeFish(w: *Writer, spec: Spec) Writer.Error!void {
    try writeHeader(w, .fish);
    try w.writeAll(
        \\# Also completes `git issue ...`: fish's git completion runs
        \\# `complete -C "git-issue ..."` for git-<cmd> programs on PATH.
        \\
        \\function __git_issue_ids
        \\    command git issue ls --all --format oneline 2>/dev/null |
        \\        string replace -r '^(\S+) (\S+) (.*)$' '$1\t$3 ($2)'
        \\end
        \\
        \\function __git_issue_needs_command
        \\    test (count (commandline -xpc)) -eq 1
        \\end
        \\
        \\function __git_issue_using -a name
        \\    set -l cmd (commandline -xpc)
        \\    test (count $cmd) -ge 2; and test "$cmd[2]" = $name
        \\end
        \\
        \\complete -c git-issue -f
        \\
    );
    for (spec.commands) |c| {
        try w.print("complete -c git-issue -n __git_issue_needs_command -a {s} -d ", .{c.name});
        try fishQuoted(w, c.desc);
        try w.writeAll("\n");
    }
    for (spec.commands) |c| {
        try w.print("\n# {s}\n", .{c.name});
        for (c.options) |o| {
            try w.print("complete -c git-issue -n '__git_issue_using {s}'", .{c.name});
            if (o.short) |s| try w.print(" -s {s}", .{s[1..]});
            if (o.long) |l| try w.print(" -l {s}", .{l[2..]});
            if (o.value != null) {
                try w.writeAll(" -x");
                try fishArgs(w, kindOf(c.name, o.value));
            }
            try w.writeAll(" -d ");
            try fishQuoted(w, o.desc);
            try w.writeAll("\n");
        }
        switch (kindOf(c.name, c.positional)) {
            .none => {},
            else => |k| {
                try w.print("complete -c git-issue -n '__git_issue_using {s}'", .{c.name});
                try fishArgs(w, k);
                try w.writeAll("\n");
            },
        }
    }
    try w.writeAll("\n# git-issue-<sub> entry points\n");
    for (entry_points.names) |n| {
        try w.print("complete -c git-issue-{s} -f --wraps 'git-issue {s}'\n", .{ n, n });
    }
}

fn fishArgs(w: *Writer, kind: Kind) Writer.Error!void {
    switch (kind) {
        .none => {},
        .issue => try w.writeAll(" -a '(__git_issue_ids)'"),
        .remote => try w.writeAll(" -a '(command git remote 2>/dev/null)'"),
        .words => |words| try w.print(" -a '{s}'", .{words}),
    }
}

fn fishQuoted(w: *Writer, text: []const u8) Writer.Error!void {
    try w.writeByte('\'');
    for (text) |c| switch (c) {
        '\'', '\\' => try w.print("\\{c}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('\'');
}

const testing = std.testing;

test "every listed command has a help text and parses" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const spec = try parse(arena_state.allocator());
    var listed: usize = 0;
    var lines = std.mem.splitScalar(u8, cmd_help.text, '\n');
    while (lines.next()) |line| if (commandLine(line)) |c| {
        listed += 1;
        if (helpOf(c.name) == null) {
            std.debug.print("'{s}' has no help text in command_helps\n", .{c.name});
            return error.MissingHelp;
        }
    };
    try testing.expectEqual(listed, spec.commands.len);
    for (spec.commands) |c| {
        try testing.expect(c.desc.len > 0);
        var has_help = false;
        for (c.options) |o| {
            try testing.expect(o.long != null or o.short != null);
            try testing.expect(o.desc.len > 0);
            if (o.long) |l| if (std.mem.eql(u8, l, "--help")) {
                has_help = true;
            };
        }
        testing.expect(has_help) catch |err| {
            std.debug.print("'{s}' help lists no -h, --help option\n", .{c.name});
            return err;
        };
    }
}

test "spec parsing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const spec = try parse(arena_state.allocator());
    const find = struct {
        fn cmd(s: Spec, name: []const u8) Command {
            for (s.commands) |c| if (std.mem.eql(u8, c.name, name)) return c;
            unreachable;
        }
        fn opt(c: Command, long: []const u8) Option {
            for (c.options) |o| if (o.long != null and std.mem.eql(u8, o.long.?, long)) return o;
            unreachable;
        }
    };
    try testing.expectEqualStrings("issue-id", find.cmd(spec, "edit").positional.?);
    try testing.expectEqualStrings("remote", find.cmd(spec, "init").positional.?);
    try testing.expectEqualStrings("title", find.cmd(spec, "create").positional.?);
    try testing.expectEqualStrings("shell", find.cmd(spec, "completion").positional.?);
    try testing.expect(find.cmd(spec, "ls").positional == null);
    const prio = find.opt(find.cmd(spec, "create"), "--priority");
    try testing.expectEqualStrings("-p", prio.short.?);
    try testing.expectEqualStrings("level", prio.value.?);
    const fix = find.opt(find.cmd(spec, "init"), "--fix-refspec");
    try testing.expect(std.mem.endsWith(u8, fix.desc, "overwrite local issue refs"));
    try testing.expectEqualStrings("-q", find.opt(find.cmd(spec, "fsck"), "--quiet").short.?);
}

test "scripts generate for every shell" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const spec = try parse(arena_state.allocator());
    for (std.enums.values(Shell)) |shell| {
        var out: Writer.Allocating = .init(arena_state.allocator());
        try write(&out.writer, shell, spec);
        try testing.expect(std.mem.find(u8, out.written(), "create") != null);
        try testing.expect(std.mem.find(u8, out.written(), "add-label") != null);
    }
}

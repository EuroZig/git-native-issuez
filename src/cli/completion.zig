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
    const spec = parse(ctx.arena) catch return common.oom(ctx.err);
    write(ctx.arena, ctx.out, s, spec) catch |e| switch (e) {
        error.OutOfMemory => return common.oom(ctx.err),
        error.WriteFailed => return common.exit_error,
    };
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

/// `<name>` in a usage line. `<file>...` repeats.
pub const Positional = struct { name: []const u8, repeats: bool = false };

pub const Subcommand = struct {
    name: []const u8,
    desc: []const u8,
    positionals: []const Positional,
};

pub const Command = struct {
    name: []const u8,
    desc: []const u8,
    /// The arguments in order, options not counted.
    positionals: []const Positional,
    /// From a `Subcommands:` section: the first argument names one, and
    /// its own positionals follow it.
    subcommands: []const Subcommand,
    options: []const Option,

    /// Options that take a value, so the word after them isn't an argument.
    fn takesValue(c: Command, arena: Allocator) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (c.options) |o| if (o.value != null) {
            if (o.short) |v| try out.print(arena, "{s} ", .{v});
            if (o.long) |v| try out.print(arena, "{s} ", .{v});
        };
        return std.mem.trimEnd(u8, out.items, " ");
    }
};

pub const Spec = struct { commands: []const Command };

pub fn parse(arena: Allocator) Allocator.Error!Spec {
    var commands: std.ArrayList(Command) = .empty;
    var lines = std.mem.splitScalar(u8, cmd_help.text, '\n');
    while (lines.next()) |line| {
        const entry = commandLine(line) orelse continue;
        const sub_help = helpOf(entry.name) orelse continue;
        const usage = sub_help[0 .. std.mem.findScalar(u8, sub_help, '\n') orelse sub_help.len];
        const subcommands = try subcommandsOf(arena, sub_help);
        try commands.append(arena, .{
            .name = entry.name,
            .desc = entry.desc,
            // After `usage: git issue <name>`.
            .positionals = if (subcommands.len > 0) &.{} else try placeholders(arena, usage, 4),
            .subcommands = subcommands,
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

/// The `<name>`s among the words of `line` from word `skip` on, up to a
/// double space (where a description starts).
fn placeholders(arena: Allocator, line: []const u8, skip: usize) Allocator.Error![]const Positional {
    var out: std.ArrayList(Positional) = .empty;
    const trimmed = std.mem.trimStart(u8, line, " ");
    const end = std.mem.find(u8, trimmed, "  ") orelse trimmed.len;
    var words = std.mem.tokenizeScalar(u8, trimmed[0..end], ' ');
    var n: usize = 0;
    while (words.next()) |raw| : (n += 1) {
        if (n < skip) continue;
        const repeats = std.mem.endsWith(u8, raw, "...");
        const w = std.mem.trim(u8, if (repeats) raw[0 .. raw.len - 3] else raw, "[]");
        if (w.len > 2 and w[0] == '<' and w[w.len - 1] == '>') {
            try out.append(arena, .{ .name = w[1 .. w.len - 1], .repeats = repeats });
        }
    }
    return out.items;
}

/// `   add <issue-id> <file>...   Attach files` lines under `Subcommands:`.
fn subcommandsOf(arena: Allocator, text: []const u8) Allocator.Error![]const Subcommand {
    var out: std.ArrayList(Subcommand) = .empty;
    const start = std.mem.find(u8, text, "\nSubcommands:\n") orelse return &.{};
    var lines = std.mem.splitScalar(u8, text[start + "\nSubcommands:\n".len ..], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const body = std.mem.trimStart(u8, line, " ");
        const name = body[0 .. std.mem.findScalar(u8, body, ' ') orelse body.len];
        const gap = std.mem.find(u8, body, "  ") orelse body.len;
        try out.append(arena, .{
            .name = name,
            .desc = std.mem.trim(u8, body[gap..], " "),
            .positionals = try placeholders(arena, line, 1),
        });
    }
    return out.items;
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
    file,
    words: []const u8,
};

fn kindOf(command: []const u8, placeholder: ?[]const u8) Kind {
    const p = placeholder orelse return .none;
    const eql = std.mem.eql;
    if (eql(u8, p, "issue-id")) return .issue;
    if (eql(u8, p, "remote")) return .remote;
    if (eql(u8, p, "file")) return .file;
    if (eql(u8, p, "level")) return .{ .words = "low medium high critical" };
    if (eql(u8, p, "format")) return .{ .words = "short full oneline" };
    if (eql(u8, p, "field")) return .{ .words = "created updated priority state" };
    if (eql(u8, p, "reason")) return .{ .words = "duplicate wontfix invalid completed" };
    if (eql(u8, p, "shell")) return .{ .words = "bash zsh fish" };
    if (eql(u8, p, "state")) return .{ .words = "open closed all" };
    if (eql(u8, p, "value") and eql(u8, command, "state")) return .{ .words = "open closed" };
    return .none;
}

pub const Error = Writer.Error || Allocator.Error;

pub fn write(arena: Allocator, w: *Writer, shell: Shell, spec: Spec) Error!void {
    switch (shell) {
        .bash => try writeBash(arena, w, spec),
        .zsh => try writeZsh(w, spec),
        .fish => try writeFish(arena, w, spec),
    }
}

fn writeHeader(w: *Writer, shell: Shell) Writer.Error!void {
    try w.print(
        "# {t} completion for git-issue (git-native-issuez {s}).\n" ++
            "# Generated by `git issue completion {t}`; do not edit.\n",
        .{ shell, cmd_version.version, shell },
    );
}

fn writeBash(arena: Allocator, w: *Writer, spec: Spec) Error!void {
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
        \\# The arguments before the cursor from COMP_WORDS[$1] on: words that
        \\# aren't options or the value of an option in $2.
        \\__git_issue_args() {
        \\    __git_issue_words=()
        \\    local i skip=0
        \\    for ((i = $1; i < COMP_CWORD; i++)); do
        \\        local word="${COMP_WORDS[i]}"
        \\        if [ "$skip" = 1 ]; then
        \\            skip=0
        \\        elif [[ $word == -* ]]; then
        \\            [[ " $2 " == *" $word "* ]] && skip=1
        \\        else
        \\            __git_issue_words+=("$word")
        \\        fi
        \\    done
        \\}
        \\
        \\# $1: index of the subcommand word in COMP_WORDS, or of the first
        \\# argument when $2 names the subcommand (git-issue-<sub>).
        \\__git_issue_complete() {
        \\    local first="$1" sub="$2" start="$1"
        \\    local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD-1]}"
        \\    if [ -z "$sub" ]; then
        \\        start=$((first + 1))
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
        try w.print("\" ;;\n            *)\n                __git_issue_args \"$start\" \"{s}\"\n", .{
            try c.takesValue(arena),
        });
        if (c.subcommands.len == 0) {
            try bashPositionals(w, c.name, c.positionals, "${#__git_issue_words[@]}", "                ");
        } else {
            try w.writeAll(
                \\                local n=$((${#__git_issue_words[@]} - 1))
                \\                if [ "$n" -lt 0 ]; then
                \\                    __git_issue_reply "
            );
            for (c.subcommands, 0..) |sub, i| try w.print("{s}{s}", .{ if (i > 0) " " else "", sub.name });
            try w.writeAll(
                \\"
                \\                    return
                \\                fi
                \\                case "${__git_issue_words[0]}" in
                \\
            );
            for (c.subcommands) |sub| {
                try w.print("                    {s})\n", .{sub.name});
                try bashPositionals(w, c.name, sub.positionals, "$n", "                        ");
                try w.writeAll("                        ;;\n");
            }
            try w.writeAll("                esac\n");
        }
        try w.writeAll("                ;;\n        esac ;;\n");
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

/// A `case` on the argument count, `count`.
fn bashPositionals(
    w: *Writer,
    command: []const u8,
    positionals: []const Positional,
    count: []const u8,
    indent: []const u8,
) Writer.Error!void {
    try w.print("{s}case {s} in\n", .{ indent, count });
    var open_ended = false;
    for (positionals, 0..) |p, i| {
        if (p.repeats) {
            try w.print("{s}    *) ", .{indent});
            open_ended = true;
        } else try w.print("{s}    {d}) ", .{ indent, i });
        try bashKind(w, kindOf(command, p.name));
        try w.writeAll(" ;;\n");
        if (open_ended) break;
    }
    if (!open_ended) try w.print("{s}    *) COMPREPLY=() ;;\n", .{indent});
    try w.print("{s}esac\n", .{indent});
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
        .file => try w.writeAll("COMPREPLY=($(compgen -f -- \"$cur\"))"),
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
        \\    local sub curcontext=$curcontext state line
        \\    if [[ $service == git-issue-?* ]]; then
        \\        sub=${service#git-issue-}
        \\    else
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
        try w.print("        {s})\n", .{c.name});
        if (c.subcommands.len == 0) {
            try zshArguments(w, c, c.positionals, "            ");
            try w.writeAll(" ;;\n");
            continue;
        }
        // The subcommand, then its own arguments (`words` then starts at it).
        try zshArguments(w, c, &.{}, "            ");
        try w.writeAll(" \\\n                '1:subcommand:((");
        for (c.subcommands, 0..) |sub, i| {
            if (i > 0) try w.writeAll(" ");
            try w.print("{s}\\:", .{sub.name});
            // In `((item\:desc ...))` a space or parenthesis ends a description.
            for (sub.desc) |ch| switch (ch) {
                ' ', '(', ')' => try w.print("\\{c}", .{ch}),
                else => try zshEscaped(w, &.{ch}),
            };
        }
        try w.writeAll(
            \\))' '*:: :->sub'
            \\            [[ $state == sub ]] || return
            \\            case $words[1] in
            \\
        );
        for (c.subcommands) |sub| {
            try w.print("                {s})\n", .{sub.name});
            try zshArguments(w, c, sub.positionals, "                    ");
            try w.writeAll(" ;;\n");
        }
        try w.writeAll("            esac ;;\n");
    }
    try w.writeAll(
        \\    esac
        \\}
        \\
        \\_git-issue "$@"
        \\
    );
}

/// `_arguments` with the command's options and `positionals`.
fn zshArguments(
    w: *Writer,
    c: Command,
    positionals: []const Positional,
    indent: []const u8,
) Writer.Error!void {
    try w.print("{s}_arguments -s", .{indent});
    for (c.options) |o| {
        try w.print(" \\\n{s}    ", .{indent});
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
    for (positionals, 1..) |p, n| {
        if (p.repeats) {
            try w.print(" \\\n{s}    '*:{s}:", .{ indent, p.name });
        } else try w.print(" \\\n{s}    '{d}:{s}:", .{ indent, n, p.name });
        try zshAction(w, kindOf(c.name, p.name));
        try w.writeAll("'");
    }
}

fn zshAction(w: *Writer, kind: Kind) Writer.Error!void {
    switch (kind) {
        .none => try w.writeAll(" "),
        .issue => try w.writeAll("__git_issue_ids"),
        .remote => try w.writeAll("__git_issue_remotes"),
        .file => try w.writeAll("_files"),
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

fn writeFish(arena: Allocator, w: *Writer, spec: Spec) Error!void {
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
        \\# `commandline -o`: fish 3.x has no `-x`.
        \\function __git_issue_needs_command
        \\    test (count (commandline -opc)) -eq 1
        \\end
        \\
        \\function __git_issue_using -a name
        \\    set -l cmd (commandline -opc)
        \\    test (count $cmd) -ge 2; and test "$cmd[2]" = $name
        \\end
        \\
        \\# True when the next word is argument <index> (from 0, `1+`: or a
        \\# later one) of command <name>, or of its subcommand <sub> (`-`:
        \\# none). Options and the values in $__git_issue_values_<name> aren't
        \\# arguments.
        \\function __git_issue_at -a name sub index
        \\    set -l tokens (commandline -opc)
        \\    test (count $tokens) -ge 2; and test "$tokens[2]" = $name; or return 1
        \\    set -e tokens[1..2]
        \\    set -l values __git_issue_values_$name
        \\    set -l args
        \\    set -l skip 0
        \\    for t in $tokens
        \\        if test $skip -eq 1
        \\            set skip 0
        \\        else if string match -q -- '-*' $t
        \\            contains -- $t $$values; and set skip 1
        \\        else
        \\            set -a args $t
        \\        end
        \\    end
        \\    if test $sub != -
        \\        test (count $args) -ge 1; and test "$args[1]" = $sub; or return 1
        \\        set -e args[1]
        \\    end
        \\    set -l n (count $args)
        \\    if string match -q -- '*+' $index
        \\        test $n -ge (string trim -r -c + -- $index)
        \\    else
        \\        test $n -eq $index
        \\    end
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
                const kind = kindOf(c.name, o.value);
                // -x is -r and -f, and -f can't go with -F.
                try w.writeAll(if (kind == .file) " -r" else " -x");
                try fishArgs(w, kind);
            }
            try w.writeAll(" -d ");
            try fishQuoted(w, o.desc);
            try w.writeAll("\n");
        }
        const values = try c.takesValue(arena);
        if (values.len > 0) try w.print("set -g __git_issue_values_{s} {s}\n", .{ c.name, values });
        if (c.subcommands.len == 0) {
            try fishPositionals(w, c.name, "-", c.positionals);
            continue;
        }
        for (c.subcommands) |sub| {
            try w.print("complete -c git-issue -n '__git_issue_at {s} - 0' -a {s} -d ", .{
                c.name,
                sub.name,
            });
            try fishQuoted(w, sub.desc);
            try w.writeAll("\n");
            try fishPositionals(w, c.name, sub.name, sub.positionals);
        }
    }
    try w.writeAll("\n# git-issue-<sub> entry points\n");
    for (entry_points.names) |n| {
        try w.print("complete -c git-issue-{s} -f --wraps 'git-issue {s}'\n", .{ n, n });
    }
}

fn fishPositionals(
    w: *Writer,
    command: []const u8,
    sub: []const u8,
    positionals: []const Positional,
) Writer.Error!void {
    for (positionals, 0..) |p, i| {
        const kind = kindOf(command, p.name);
        if (kind != .none) {
            try w.print("complete -c git-issue -n '__git_issue_at {s} {s} {d}{s}'", .{
                command,
                sub,
                i,
                if (p.repeats) "+" else "",
            });
            try fishArgs(w, kind);
            try w.writeAll("\n");
        }
        if (p.repeats) break;
    }
}

fn fishArgs(w: *Writer, kind: Kind) Writer.Error!void {
    switch (kind) {
        .none => {},
        .file => try w.writeAll(" -F"),
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
    const arena = arena_state.allocator();
    const spec = try parse(arena);
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
    try testing.expectEqualStrings("issue-id", find.cmd(spec, "edit").positionals[0].name);
    try testing.expectEqualStrings("remote", find.cmd(spec, "init").positionals[0].name);
    try testing.expectEqualStrings("title", find.cmd(spec, "create").positionals[0].name);
    try testing.expectEqualStrings("shell", find.cmd(spec, "completion").positionals[0].name);
    try testing.expectEqual(@as(usize, 0), find.cmd(spec, "ls").positionals.len);
    // Options between arguments don't count.
    const quarantine = find.cmd(spec, "quarantine").positionals;
    try testing.expectEqual(@as(usize, 2), quarantine.len);
    try testing.expectEqualStrings("issue-id", quarantine[1].name);
    // Subcommands bring their own arguments.
    const attach = find.cmd(spec, "attach");
    try testing.expectEqual(@as(usize, 0), attach.positionals.len);
    try testing.expectEqual(@as(usize, 6), attach.subcommands.len);
    const add = attach.subcommands[0];
    try testing.expectEqualStrings("add", add.name);
    try testing.expectEqualStrings("Attach files (-m: post a comment with them)", add.desc);
    try testing.expectEqual(@as(usize, 2), add.positionals.len);
    try testing.expectEqualStrings("issue-id", add.positionals[0].name);
    try testing.expectEqualStrings("file", add.positionals[1].name);
    try testing.expect(add.positionals[1].repeats);
    const fetch = attach.subcommands[5];
    try testing.expectEqualStrings("issue-id", fetch.positionals[0].name);
    const milestone = find.cmd(spec, "milestone");
    try testing.expectEqual(@as(usize, 7), milestone.subcommands.len);
    try testing.expectEqual(@as(usize, 0), milestone.subcommands[1].positionals.len);
    try testing.expectEqualStrings("-m --message --name --remote", try attach.takesValue(arena));
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
        try write(arena_state.allocator(), &out.writer, shell, spec);
        try testing.expect(std.mem.find(u8, out.written(), "create") != null);
        try testing.expect(std.mem.find(u8, out.written(), "add-label") != null);
    }
}

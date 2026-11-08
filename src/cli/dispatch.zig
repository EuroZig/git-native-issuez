//! Subcommand dispatch, shared by `git-issue` and `git-issue-sim`. Called
//! as `git-issue <sub> ...` or, like upstream's scripts do, as
//! `git-issue-<sub> ...`. Top-level usage, version and unknown-command
//! output match upstream's dispatcher.

const std = @import("std");
const build_options = @import("build_options");
const context = @import("context.zig");
const common = @import("common.zig");
const cmd_version = @import("cmd/version.zig");
const cmd_help = @import("cmd/help.zig");
const cmd_create = @import("cmd/create.zig");
const cmd_ls = @import("cmd/ls.zig");
const cmd_show = @import("cmd/show.zig");
const cmd_comment = @import("cmd/comment.zig");
const cmd_edit = @import("cmd/edit.zig");
const cmd_state = @import("cmd/state.zig");
const cmd_search = @import("cmd/search.zig");
const cmd_fsck = @import("cmd/fsck.zig");
const cmd_init = @import("cmd/init.zig");
const cmd_merge = @import("cmd/merge.zig");
const cmd_status = @import("cmd/status.zig");
const cmd_tree = @import("cmd/tree.zig");
const cmd_delete = @import("cmd/delete.zig");
const cmd_close = @import("cmd/close.zig");
const cmd_milestone = @import("cmd/milestone.zig");
const cmd_quarantine = @import("cmd/quarantine.zig");
const cmd_attach = @import("cmd/attach.zig");
const cmd_react = @import("cmd/react.zig");
const cmd_purge = @import("cmd/purge.zig");
const cmd_push_check = @import("cmd/push_check.zig");
const completion = @import("completion.zig");
const manpage = @import("manpage.zig");
const tui = if (build_options.tui) @import("tui") else struct {};
const mcp = if (build_options.mcp) @import("mcp") else struct {};

pub const program = "git-issue";

/// Upstream's commands first, then ours.
pub const Command = enum {
    create,
    ls,
    show,
    comment,
    edit,
    state,
    search,
    import,
    @"export",
    sync,
    merge,
    fsck,
    init,
    version,
    @"--version",
    @"-v",
    help,
    @"--help",
    @"-h",
    tui,
    mcp,
    push,
    status,
    quarantine,
    tree,
    delete,
    restore,
    close,
    reopen,
    milestone,
    attach,
    react,
    purge,
    @"push-check",
    completion,
    /// Writes the man pages at build time. Not in the usage.
    __manpages,
};

/// `git issue` alone: the TUI for a person at a terminal in a repository,
/// else the usage, so scripts, pipes, agents and minimal builds see the
/// commands.
fn bare(comptime B: type, ctx: *context.Context(B)) u8 {
    if (build_options.tui and B == @import("issuez").backend.GitProcess) {
        const repo = if (ctx.backend) |_| true else |_| false;
        const terminal = (std.Io.File.stdin().isTty(ctx.io) catch false) and
            (std.Io.File.stdout().isTty(ctx.io) catch false);
        if (repo and terminal) return tui.main(
            ctx.io,
            ctx.gpa,
            ctx.environ_map,
            ctx.out,
            ctx.err,
            &.{},
        );
    }
    return cmd_help.usage(B, ctx);
}

pub const Invocation = struct {
    sub: ?[]const u8,
    args: []const []const u8,
};

pub fn resolve(argv0: []const u8, args: []const []const u8) Invocation {
    const base = programBaseName(argv0);
    if (std.mem.startsWith(u8, base, program ++ "-") and base.len > program.len + 1) {
        return .{ .sub = base[program.len + 1 ..], .args = args };
    }
    if (args.len == 0) return .{ .sub = null, .args = args };
    return .{ .sub = args[0], .args = args[1..] };
}

/// Basename without directory and `.exe`.
pub fn programBaseName(argv0: []const u8) []const u8 {
    const sep = std.mem.findLastAny(u8, argv0, "/\\");
    const base = if (sep) |i| argv0[i + 1 ..] else argv0;
    if (std.ascii.endsWithIgnoreCase(base, ".exe")) return base[0 .. base.len - 4];
    return base;
}

/// False for what only prints fixed text, so it runs no git.
pub fn usesRepository(argv0: []const u8, args: []const []const u8) bool {
    const sub = resolve(argv0, args).sub orelse return true;
    const cmd = std.meta.stringToEnum(Command, sub) orelse return true;
    return switch (cmd) {
        .version, .@"--version", .@"-v", .help, .@"--help", .@"-h" => false,
        else => true,
    };
}

test usesRepository {
    const t = std.testing;
    try t.expect(!usesRepository("git-issue", &.{"--version"}));
    try t.expect(!usesRepository("git-issue", &.{ "help", "ls" }));
    try t.expect(!usesRepository("git-issue-version", &.{}));
    try t.expect(usesRepository("git-issue", &.{}));
    try t.expect(usesRepository("git-issue", &.{"ls"}));
    try t.expect(usesRepository("git-issue-ls", &.{"--help"}));
    try t.expect(usesRepository("git-issue", &.{"nonsense"}));
}

pub fn run(
    comptime B: type,
    ctx: *context.Context(B),
    argv0: []const u8,
    args: []const []const u8,
) u8 {
    const inv = resolve(argv0, args);
    const sub = inv.sub orelse return bare(B, ctx);
    const cmd = std.meta.stringToEnum(Command, sub) orelse return unknown(B, ctx, sub);
    return switch (cmd) {
        .version, .@"--version", .@"-v" => cmd_version.main(B, ctx, inv.args),
        .help, .@"--help", .@"-h" => cmd_help.usage(B, ctx),
        .tui => if (build_options.tui)
            tui.main(ctx.io, ctx.gpa, ctx.environ_map, ctx.out, ctx.err, inv.args)
        else
            unavailable(B, ctx, sub, "-Dtui=true"),
        .mcp => if (build_options.mcp)
            mcp.main(ctx.io, ctx.gpa, ctx.environ_map, ctx.out, ctx.err, inv.args)
        else
            unavailable(B, ctx, sub, "-Dmcp=true"),
        .create => cmd_create.main(B, ctx, inv.args),
        .ls => cmd_ls.main(B, ctx, inv.args),
        .show => cmd_show.main(B, ctx, inv.args),
        .comment => cmd_comment.main(B, ctx, inv.args),
        .edit => cmd_edit.main(B, ctx, inv.args),
        .state => cmd_state.main(B, ctx, inv.args),
        .search => cmd_search.main(B, ctx, inv.args),
        .fsck => cmd_fsck.main(B, ctx, inv.args),
        .init => cmd_init.main(B, ctx, inv.args),
        .merge => cmd_merge.main(B, ctx, inv.args, .merge),
        .push => cmd_merge.main(B, ctx, inv.args, .push),
        .status => cmd_status.main(B, ctx, inv.args),
        .tree => cmd_tree.main(B, ctx, inv.args),
        .delete => cmd_delete.main(B, ctx, inv.args, true),
        .restore => cmd_delete.main(B, ctx, inv.args, false),
        .close => cmd_close.main(B, ctx, inv.args, true),
        .reopen => cmd_close.main(B, ctx, inv.args, false),
        .milestone => cmd_milestone.main(B, ctx, inv.args),
        .attach => cmd_attach.main(B, ctx, inv.args),
        .quarantine => cmd_quarantine.main(B, ctx, inv.args),
        .react => cmd_react.main(B, ctx, inv.args),
        .purge => cmd_purge.main(B, ctx, inv.args),
        .@"push-check" => cmd_push_check.main(B, ctx, inv.args),
        .completion => completion.main(B, ctx, inv.args),
        .__manpages => manpage.main(B, ctx, inv.args),
        .sync => if (hasHelp(inv.args))
            cmd_merge.main(B, ctx, inv.args, .sync)
        else if (firstPositional(inv.args)) |target|
            (if (isProvider(target))
                unsupportedBridge(B, ctx, sub)
            else
                cmd_merge.main(B, ctx, inv.args, .sync))
        else
            common.missing(ctx.err, sub, "remote or provider is required"),
        // Always upstream's, with or without a provider or --help.
        .import, .@"export" => unsupportedBridge(B, ctx, sub),
    };
}

fn unknown(comptime B: type, ctx: *context.Context(B), sub: []const u8) u8 {
    ctx.err.print(
        "git-issue: '{s}' is not a git-issue command. See 'git issue --help'.\n",
        .{sub},
    ) catch {};
    return common.exit_error;
}

fn hasHelp(args: []const []const u8) bool {
    for (args) |a| if (common.isHelp(a)) return true;
    return false;
}

/// Upstream's bridges: `github:<owner>/<repo>`, `gitlab:`, `gitea:`,
/// `forgejo:`. Any other target with a `:` is a URL.
fn isProvider(target: []const u8) bool {
    const colon = std.mem.findScalar(u8, target, ':') orelse return false;
    if (std.mem.startsWith(u8, target[colon..], "://")) return false;
    for ([_][]const u8{ "github", "gitlab", "gitea", "forgejo" }) |p| {
        if (std.mem.eql(u8, target[0..colon], p)) return true;
    }
    return false;
}

fn firstPositional(args: []const []const u8) ?[]const u8 {
    for (args) |a| if (a.len == 0 or a[0] != '-') return a;
    return null;
}

fn unsupportedBridge(comptime B: type, ctx: *context.Context(B), sub: []const u8) u8 {
    ctx.err.print(
        "git-issue: '{s}' with a provider (GitHub, GitLab, ...) is upstream's: run\n" ++
            "git-native-issue's git-issue-{s} in this repository, see\n" ++
            "https://github.com/remenoscodes/git-native-issue#platform-bridges\n",
        .{ sub, sub },
    ) catch {};
    return common.exit_error;
}

fn unavailable(
    comptime B: type,
    ctx: *context.Context(B),
    sub: []const u8,
    comptime option: []const u8,
) u8 {
    ctx.err.print(
        "git-issue: '{s}' is not in this build; build with " ++ option ++ " to include it.\n",
        .{sub},
    ) catch {};
    return common.exit_error;
}

test resolve {
    const t = std.testing;
    const a = resolve("/usr/local/bin/git-issue", &.{ "ls", "--all" });
    try t.expectEqualStrings("ls", a.sub.?);
    try t.expectEqual(@as(usize, 1), a.args.len);

    const b = resolve("/opt/bin/git-issue-create", &.{ "Title", "-l", "bug" });
    try t.expectEqualStrings("create", b.sub.?);
    try t.expectEqual(@as(usize, 3), b.args.len);

    const c = resolve("C:\\tools\\git-issue-show.EXE", &.{"abc"});
    try t.expectEqualStrings("show", c.sub.?);

    const d = resolve("git-issue", &.{});
    try t.expect(d.sub == null);

    const e = resolve("git-issue-", &.{"ls"});
    try t.expectEqualStrings("ls", e.sub.?);
}

test "entry point names" {
    const entry_points = @import("entry_points.zig");
    for (entry_points.names) |name| {
        std.testing.expect(std.meta.stringToEnum(Command, name) != null) catch |err| {
            std.debug.print("entry point '{s}' is not a command\n", .{name});
            return err;
        };
        try std.testing.expect(!entry_points.isReservedForUpstream(name));
    }
    try std.testing.expect(entry_points.isReservedForUpstream("sync"));
    try std.testing.expect(entry_points.isReservedForUpstream("import-github"));
}

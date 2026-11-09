//! `git issue push-check [options] [<old> <new> <ref>]...`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const issuez = @import("issuez");
const check_mod = issuez.push_check;
const uuid_fmt = issuez.format.uuid;

pub const help =
    \\usage: git issue push-check [options] [<old> <new> <ref>]...
    \\
    \\For a server's pre-receive hook: may this push be accepted? Reads the
    \\hook's input (<old> <new> <ref> per line) from stdin, or the updates
    \\from the arguments, and checks the issues, milestones, attachment refs
    \\and tombstones they bring (docs/format.md §11). Other refs are left to
    \\the host. Run it inside the hook so git's quarantine is in the
    \\environment; it writes nothing.
    \\
    \\Exits 1 and says why on stderr when any update is refused, e.g.
    \\
    \\    #!/bin/sh
    \\    exec git issue push-check --authors enforce --pusher-email "$PUSHER_EMAIL"
    \\
    \\Options:
    \\   --pusher-email <email>   The pusher's email (repeatable)
    \\   --pusher-id <uuid>       The pusher's host UUID (repeatable): new
    \\                            commits' X-Author-Id must be one of them
    \\   --authors <policy>       any (default), warn or enforce: new commits
    \\                            not by the pusher are let through, flagged
    \\                            or refused
    \\   --allow-numbers          Let clients give X-Number
    \\   --allow-purge            Let the pusher push tombstones (admins only:
    \\                            a tombstone purges every clone)
    \\   -q, --quiet              Print nothing for accepted updates
    \\   -h, --help               Show this help
    \\
;

pub fn main(comptime B: type, ctx: *context.Context(B), argv: []const []const u8) u8 {
    const arena = ctx.arena;
    var policy: check_mod.Policy = .{};
    var emails: std.ArrayList([]const u8) = .empty;
    var ids: std.ArrayList([]const u8) = .empty;
    var words: std.ArrayList([]const u8) = .empty;
    var quiet = false;
    const flags = [_]common.Flag{
        .{ "--pusher-email", .{ .list = &emails } },
        .{ "--allow-numbers", .{ .on = &policy.allow_numbers } },
        .{ "--allow-purge", .{ .on = &policy.allow_purge } },
        .{ "-q --quiet", .{ .on = &quiet } },
    };
    var parser = common.argParser(ctx, argv, .{
        .command = "push-check",
        .help = help,
        .positionals = .{ .words_and_separator = &words },
        .flags = &flags,
    });
    while (parser.next()) |arg| {
        if (common.isFlag(arg, "--pusher-id")) {
            const id = parser.value(arg) orelse return common.exit_error;
            if (!uuid_fmt.isCanonical(id))
                return common.fail(ctx.err, "error: --pusher-id needs a UUID\n");
            ids.append(arena, id) catch return common.oom(ctx.err);
        } else if (common.isFlag(arg, "--authors")) {
            const v = parser.value(arg) orelse return common.exit_error;
            policy.author_policy = std.meta.stringToEnum(check_mod.AuthorPolicy, v) orelse
                return common.fail(ctx.err, "error: --authors is any, warn or enforce\n");
        } else return parser.unknown(arg);
    }
    if (parser.exit) |exit| return exit;
    policy.pusher_emails = emails.items;
    policy.pusher_ids = ids.items;
    if (policy.author_policy != .any and emails.items.len == 0) return common.fail(
        ctx.err,
        "error: --authors needs the pusher's --pusher-email\n",
    );

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    var triples: std.ArrayList([3][]const u8) = .empty;
    if (words.items.len == 0) {
        const input = ctx.readStdin(max_input) catch |e| return common.fail(
            ctx.err,
            if (e == error.FileTooLarge)
                "error: the updates on stdin are over 16 MiB\n"
            else
                "error: can't read the updates from stdin\n",
        );
        switch (splitLines(arena, input, &triples) catch return common.oom(ctx.err)) {
            .ok => {},
            .bad => |line| {
                ctx.err.print("error: not <old> <new> <ref>: '{s}'\n", .{line}) catch {};
                return common.exit_error;
            },
        }
    } else {
        if (words.items.len % 3 != 0) return common.fail(
            ctx.err,
            "error: updates are <old> <new> <ref> triples\n",
        );
        var i: usize = 0;
        while (i < words.items.len) : (i += 3) triples.append(
            arena,
            words.items[i..][0..3].*,
        ) catch return common.oom(ctx.err);
    }
    const format = repo.backend.objectFormat();
    const updates = arena.alloc(check_mod.Update, triples.items.len) catch
        return common.oom(ctx.err);
    for (updates, triples.items) |*u, w| {
        u.* = .{
            .ref = w[2],
            .old = parseOid(format, w[0]) orelse return badOid(ctx, w[0]),
            .new = parseOid(format, w[1]) orelse return badOid(ctx, w[1]),
        };
        if (u.old == null and u.new == null) return badOid(ctx, w[0]);
    }

    const verdicts = issuez.PushCheck(B).fromRepo(repo).check(arena, updates, policy) catch |e|
        return common.repoFailed(B, ctx, e);
    var refused = false;
    for (verdicts) |v| {
        for (v.problems) |p| {
            const hex = if (p.commit) |c| c.hex() else null;
            ctx.err.print("{s}: {s}: {s}{s}{s}\n", .{
                if (p.rejects) "error" else "warning",
                v.update.ref,
                p.message,
                if (hex != null) " in " else "",
                if (hex) |h| h.slice()[0..12] else "",
            }) catch {};
        }
        if (!v.accept) refused = true;
        if (quiet or !v.accept or v.action == .ignored) continue;
        ctx.out.print("ok {s}{s}{s}\n", .{
            v.update.ref,
            if (v.needs_number) " (needs a number)" else "",
            if (v.touches_locked) " (locked)" else "",
        }) catch {};
    }
    if (refused) return common.fail(ctx.err, "error: push refused\n");
    return common.exit_ok;
}

/// The hook's input, as git sends it, fits well within this.
const max_input = 16 << 20;

/// One update per line, exactly `<old> <new> <ref>`; empty lines are
/// skipped. `.bad` holds the first line that isn't one.
fn splitLines(
    arena: std.mem.Allocator,
    input: []const u8,
    out: *std.ArrayList([3][]const u8),
) std.mem.Allocator.Error!union(enum) { ok, bad: []const u8 } {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ' ');
        var triple: [3][]const u8 = undefined;
        for (&triple) |*f| f.* = fields.next() orelse return .{ .bad = line };
        if (fields.next() != null) return .{ .bad = line };
        for (triple) |f| if (f.len == 0) return .{ .bad = line };
        try out.append(arena, triple);
    }
    return .ok;
}

/// Null for git's all-zero ID, which stands for no ref: as many zeros as
/// the repo's IDs have digits.
fn parseOid(format: issuez.backend.object.ObjectFormat, s: []const u8) ??issuez.engine.Oid {
    if (s.len != format.hexLen()) return null;
    if (std.mem.trimStart(u8, s, "0").len == 0) return @as(?issuez.engine.Oid, null);
    return @as(?issuez.engine.Oid, issuez.engine.Oid.parseHex(format, s) catch return null);
}

fn badOid(ctx: anytype, s: []const u8) u8 {
    ctx.err.print("error: not an object ID: '{s}'\n", .{s}) catch {};
    return common.exit_error;
}

test "the hook's input: one update per line, three fields each" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList([3][]const u8) = .empty;
    const ok = try splitLines(arena, "a b refs/issues/x\r\n\nc d refs/heads/main\n", &out);
    try std.testing.expect(ok == .ok);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("refs/heads/main", out.items[1][2]);
    // Words that add up to triples across lines are no update.
    for ([_][]const u8{ "a b\nrefs/issues/x c d\n", "a b c d\n", "a  b c\n" }) |input| {
        out.clearRetainingCapacity();
        try std.testing.expect(try splitLines(arena, input, &out) != .ok);
    }
}

test "the zero ID has as many digits as the repo's IDs" {
    const sha1: issuez.backend.object.ObjectFormat = .sha1;
    try std.testing.expect(parseOid(sha1, "0" ** 40).? == null);
    for ([_][]const u8{ "0", "00", "0" ** 39, "0" ** 64, "" }) |s|
        try std.testing.expect(parseOid(sha1, s) == null);
    const sha256: issuez.backend.object.ObjectFormat = .sha256;
    try std.testing.expect(parseOid(sha256, "0" ** 64).? == null);
    try std.testing.expect(parseOid(sha256, "0" ** 40) == null);
}

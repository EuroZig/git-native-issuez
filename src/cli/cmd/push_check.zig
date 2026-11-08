//! `git issue push-check [options] [<old> <new> <ref>]...`

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");
const issuez = @import("issuez");
const check_mod = issuez.push_check;

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
    var words: std.ArrayList([]const u8) = .empty;
    var quiet = false;
    var args: common.Args = .{ .list = argv };
    while (args.next()) |arg| {
        if (!args.isOption(arg)) {
            words.append(arena, arg) catch return common.oom(ctx.err);
        } else if (common.isHelp(arg)) {
            ctx.out.writeAll(help) catch {};
            return common.exit_ok;
        } else if (std.mem.eql(u8, arg, "--pusher-email")) {
            const e = args.value(ctx.err, arg) orelse return common.exit_error;
            emails.append(arena, e) catch return common.oom(ctx.err);
        } else if (std.mem.eql(u8, arg, "--authors")) {
            const v = args.value(ctx.err, arg) orelse return common.exit_error;
            policy.author_policy = std.meta.stringToEnum(check_mod.AuthorPolicy, v) orelse
                return common.fail(ctx.err, "error: --authors is any, warn or enforce\n");
        } else if (std.mem.eql(u8, arg, "--allow-numbers")) {
            policy.allow_numbers = true;
        } else if (std.mem.eql(u8, arg, "--allow-purge")) {
            policy.allow_purge = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else {
            return common.unknownOption(ctx.err, "push-check", arg);
        }
    }
    policy.pusher_emails = emails.items;
    if (policy.author_policy != .any and emails.items.len == 0) return common.fail(
        ctx.err,
        "error: --authors needs the pusher's --pusher-email\n",
    );

    const repo = common.openRepo(B, ctx) orelse return common.exit_fatal;
    if (words.items.len == 0) {
        const input = ctx.readStdin(16 << 20) catch
            return common.fail(ctx.err, "error: can't read the updates from stdin\n");
        var lines = std.mem.tokenizeAny(u8, input, "\r\n");
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            while (fields.next()) |f| words.append(arena, f) catch return common.oom(ctx.err);
        }
    }
    if (words.items.len % 3 != 0) return common.fail(
        ctx.err,
        "error: updates are <old> <new> <ref> triples\n",
    );
    const format = repo.backend.objectFormat();
    const updates = arena.alloc(check_mod.Update, words.items.len / 3) catch
        return common.oom(ctx.err);
    for (updates, 0..) |*u, i| {
        const w = words.items[i * 3 ..][0..3];
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

/// Null for git's all-zero ID, which stands for no ref.
fn parseOid(format: issuez.backend.object.ObjectFormat, s: []const u8) ??issuez.engine.Oid {
    if (s.len > 0 and std.mem.trimStart(u8, s, "0").len == 0) return @as(?issuez.engine.Oid, null);
    if (s.len != format.hexLen()) return null;
    return @as(?issuez.engine.Oid, issuez.engine.Oid.parseHex(format, s) catch return null);
}

fn badOid(ctx: anytype, s: []const u8) u8 {
    ctx.err.print("error: not an object ID: '{s}'\n", .{s}) catch {};
    return common.exit_error;
}

//! The push check, as a host's pre-receive hook runs it: the client's
//! objects in a quarantine, the server's as its alternate.

const std = @import("std");
const testing = std.testing;
const fixture = @import("fixture.zig");
const expect = @import("expect.zig");
const c = fixture.c;

/// `r` is the server; `client` writes and would push.
const Push = struct {
    r: fixture.Repo,
    client_path: []const u8,
    client: *c.issuez_repo,
    server_objects: []const u8,
    client_objects: []const u8,

    fn init(p: *Push) !void {
        try p.r.init(.{ .bare = true });
        errdefer p.r.deinit();
        p.client = try fixture.second(&p.r, "client", p.r.path);
        p.client_path = try std.fs.path.join(p.r.arena(), &.{ p.r.root, "client" });
        p.server_objects = try std.fs.path.join(p.r.arena(), &.{ p.r.path, "objects" });
        p.client_objects = try std.fs.path.join(
            p.r.arena(),
            &.{ p.client_path, ".git", "objects" },
        );
    }

    fn deinit(p: *Push) void {
        c.issuez_repo_close(p.client);
        p.r.deinit();
    }

    /// Really pushes these refs to the server, unchecked.
    fn land(p: *Push, refs: []const []const u8) !void {
        for (refs) |ref| _ = try fixture.runGit(p.r.arena(), p.client_path, &.{
            "push", "-q", "-f", "origin",
            try std.fmt.allocPrint(
                p.r.arena(),
                "{s}:{s}",
                .{ ref, ref },
            ),
        });
    }

    fn clientTip(p: *Push, ref: []const u8) !c.issuez_oid {
        const found = try fixture.revParse(p.r.arena(), p.client_path, ref);
        const hex = found orelse return std.mem.zeroes(c.issuez_oid);
        var oid: c.issuez_oid = undefined;
        try expect.code(c.ISSUEZ_OK, c.issuez_oid_parse(fixture.str(hex), &oid, null), null);
        return oid;
    }

    fn serverTip(p: *Push, ref: []const u8) !c.issuez_oid {
        const found = try fixture.revParse(p.r.arena(), p.r.path, ref);
        const hex = found orelse return std.mem.zeroes(c.issuez_oid);
        var oid: c.issuez_oid = undefined;
        try expect.code(c.ISSUEZ_OK, c.issuez_oid_parse(fixture.str(hex), &oid, null), null);
        return oid;
    }

    /// The update that would bring the server's `ref` to the client's.
    fn update(p: *Push, ref: []const u8) !c.issuez_ref_update {
        return .{
            .ref = fixture.str(try p.r.arena().dupe(u8, ref)),
            .old_oid = try p.serverTip(ref),
            .new_oid = try p.clientTip(ref),
            .reserved = .{ 0, 0 },
        };
    }

    /// Runs the check; the verdicts' kinds and the problem kinds of each.
    fn check(
        p: *Push,
        ups: []const c.issuez_ref_update,
        policy: []const c.issuez_op,
        want: c.issuez_code,
    ) !*c.issuez_push_verdicts {
        var ops: std.ArrayList(c.issuez_op) = .empty;
        try ops.appendSlice(p.r.arena(), &.{
            c.issuez_opt_object_dir(fixture.str(p.client_objects)),
            c.issuez_opt_alternate_object_dirs(fixture.str(p.server_objects)),
        });
        try ops.appendSlice(p.r.arena(), policy);
        var out: ?*c.issuez_push_verdicts = null;
        var err: ?*c.issuez_error = null;
        const rc = c.issuez_push_check(
            p.r.handle,
            ups.ptr,
            ups.len,
            ops.items.ptr,
            ops.items.len,
            null,
            &out,
            &err,
        );
        expect.code(want, rc, err) catch |e| {
            if (out) |o| dump(o);
            c.issuez_error_free(err);
            c.issuez_push_verdicts_free(out);
            return e;
        };
        c.issuez_error_free(err);
        return out.?;
    }
};

fn dump(v: *c.issuez_push_verdicts) void {
    for (0..c.issuez_push_verdicts_len(v)) |i| {
        const x = c.issuez_push_verdicts_at(v, i).*;
        std.debug.print(
            "  {s} action {d} accept {}\n",
            .{ fixture.slice(x.ref), x.action, x.accept },
        );
        for (0..c.issuez_problems_len(x.problems)) |k| {
            const pr = c.issuez_problems_at(x.problems, k).*;
            std.debug.print("    problem {d}: {s}\n", .{ pr.kind, fixture.slice(pr.message) });
        }
    }
}

fn problem(v: c.issuez_push_verdict, kind: c_uint) ?c.issuez_problem {
    for (0..c.issuez_problems_len(v.problems)) |k| {
        const pr = c.issuez_problems_at(v.problems, k).*;
        if (pr.kind == kind) return pr;
    }
    return null;
}

fn has(v: c.issuez_push_verdict, kind: c_uint) bool {
    return problem(v, kind) != null;
}

/// The problem of that kind says this field, offending commit and other issue.
fn expectProblem(
    v: c.issuez_push_verdict,
    kind: c_uint,
    field: c_uint,
    commit: ?c.issuez_oid,
    subject: []const u8,
) !void {
    const pr = problem(v, kind) orelse return error.TestExpectedProblem;
    try testing.expectEqual(@as(u32, field), pr.field);
    const hex = if (commit) |o| fixture.oidHex(o) else undefined;
    try expect.str(if (commit != null) std.mem.sliceTo(&hex, 0) else "", pr.value);
    try expect.str(subject, pr.subject);
}

fn verdict(v: *c.issuez_push_verdicts, i: usize) c.issuez_push_verdict {
    return c.issuez_push_verdicts_at(v, i).*;
}

const enforce_ada = [_]c.issuez_op{
    c.issuez_opt_pusher(
        .{ .name = .{}, .email = .{ .ptr = "ADA@example.invalid", .len = 19 }, .user_id = .{} },
    ),
    c.issuez_opt_author_policy(c.ISSUEZ_AUTHOR_ENFORCE),
};

// covers: issuez_push_verdicts_len, issuez_push_verdicts_at, issuez_push_verdicts_free
// covers: issuez_push_verdict_entry_at
test "issuez_push_check: create, fast-forward, ignored" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var p: Push = undefined;
    try p.init();
    defer p.deinit();
    const x = try fixture.titled(p.client, "New");
    const ref = try std.fmt.allocPrint(p.r.arena(), "refs/issues/{s}", .{x.idSlice()});
    const branch = c.issuez_ref_update{
        .ref = fixture.str("refs/heads/main"),
        .old_oid = .{},
        .new_oid = x.tip,
        .reserved = .{ 0, 0 },
    };
    var v = try p.check(&.{ try p.update(ref), branch }, &enforce_ada, c.ISSUEZ_OK);
    try testing.expectEqual(@as(usize, 2), c.issuez_push_verdicts_len(v));
    const created = verdict(v, 0);
    try expect.str(ref, created.ref);
    try testing.expect(created.accept);
    try testing.expectEqual(@as(u32, c.ISSUEZ_PUSH_CREATE), created.action);
    try testing.expectEqual(@as(u32, c.ISSUEZ_KIND_ISSUE), created.kind);
    try expect.str(x.idSlice(), created.id);
    try testing.expect(created.needs_number);
    try testing.expect(!created.touches_locked);
    try testing.expectEqual(@as(usize, 1), created.commit_count);
    try testing.expectEqual(@as(usize, 1), created.entry_count);
    const entry = c.issuez_push_verdict_entry_at(c.issuez_push_verdicts_at(v, 0), 0).*;
    try testing.expectEqual(@as(u32, c.ISSUEZ_ENTRY_CREATED), entry.kind);
    try testing.expect(c.issuez_push_verdict_entry_at(c.issuez_push_verdicts_at(v, 0), 1) == null);
    const ignored = verdict(v, 1);
    try expect.str("refs/heads/main", ignored.ref);
    try testing.expect(ignored.accept);
    try testing.expectEqual(@as(u32, c.ISSUEZ_PUSH_IGNORED), ignored.action);
    try testing.expectEqual(@as(u32, c.ISSUEZ_KIND_UNKNOWN), ignored.kind);
    try testing.expectEqual(@as(usize, 0), ignored.entry_count);
    try testing.expect(c.issuez_push_verdict_entry_at(c.issuez_push_verdicts_at(v, 1), 0) == null);
    try testing.expect(c.issuez_push_verdicts_at(v, 2) == null);
    c.issuez_push_verdicts_free(v);

    _ = try fixture.update(p.client, x.idStr(), &.{c.issuez_set_locked(true, .{})});
    try p.land(&.{ref});
    _ = try fixture.comment(p.client, x.idStr(), "More");
    v = try p.check(&.{try p.update(ref)}, &enforce_ada, c.ISSUEZ_OK);
    try testing.expectEqual(@as(u32, c.ISSUEZ_PUSH_FAST_FORWARD), verdict(v, 0).action);
    try testing.expect(verdict(v, 0).touches_locked);
    try testing.expectEqual(@as(usize, 1), verdict(v, 0).commit_count);
    try testing.expectEqual(
        @as(u32, c.ISSUEZ_ENTRY_COMMENT),
        c.issuez_push_verdict_entry_at(c.issuez_push_verdicts_at(v, 0), 0).*.kind,
    );
    c.issuez_push_verdicts_free(v);
    c.issuez_push_verdicts_free(null);
    try testing.expectEqual(@as(usize, 0), c.issuez_push_verdicts_len(null));
}

test "issuez_push_check: refused refs, rewinds, deletes, authors, numbers, formats" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var p: Push = undefined;
    try p.init();
    defer p.deinit();
    const a = p.r.arena();
    const x = try fixture.titled(p.client, "Base");
    const ref = try std.fmt.allocPrint(a, "refs/issues/{s}", .{x.idSlice()});
    _ = try fixture.comment(p.client, x.idStr(), "Second");
    try p.land(&.{ref});
    const server_tip = try p.serverTip(ref);
    const one = c.issuez_ref_update{
        .ref = fixture.str(ref),
        .old_oid = server_tip,
        .new_oid = x.tip,
        .reserved = .{ 0, 0 },
    };
    const gone = c.issuez_ref_update{
        .ref = fixture.str(ref),
        .old_oid = server_tip,
        .new_oid = .{},
        .reserved = .{ 0, 0 },
    };
    const local = c.issuez_ref_update{
        .ref = fixture.str("refs/issuez-guard/x"),
        .old_oid = .{},
        .new_oid = x.tip,
        .reserved = .{ 0, 0 },
    };
    const misnamed = c.issuez_ref_update{
        .ref = fixture.str("refs/issues/not-a-uuid"),
        .old_oid = .{},
        .new_oid = x.tip,
        .reserved = .{ 0, 0 },
    };
    var v = try p.check(&.{ one, gone, local, misnamed }, &.{}, c.ISSUEZ_E_REJECTED);
    try testing.expectEqual(@as(u32, c.ISSUEZ_PUSH_REWRITE), verdict(v, 0).action);
    try testing.expect(has(verdict(v, 0), c.ISSUEZ_PROBLEM_NON_FAST_FORWARD));
    try testing.expectEqual(@as(u32, c.ISSUEZ_PUSH_DELETE), verdict(v, 1).action);
    try testing.expect(has(verdict(v, 1), c.ISSUEZ_PROBLEM_REF_DELETED));
    try testing.expect(has(verdict(v, 2), c.ISSUEZ_PROBLEM_LOCAL_REF));
    try testing.expect(has(verdict(v, 3), c.ISSUEZ_PROBLEM_BAD_REF_NAME));
    c.issuez_push_verdicts_free(v);

    // Someone else's commit: refused under enforce, flagged under warn.
    const mallory: c.issuez_actor = .{
        .name = fixture.str("M"),
        .email = fixture.str("mallory@example.invalid"),
        .user_id = .{},
        .at = null,
        .reserved = .{ 0, 0, 0, 0 },
    };
    const cops = [_]c.issuez_op{c.issuez_set_comment(fixture.str("Spoofed"))};
    var w: ?*c.issuez_write = null;
    const spoof = try fixture.wrote(
        c.issuez_issue_update(p.client, x.idStr(), &cops, 1, &mallory, null, &w, null),
        w,
        null,
        "spoof",
    );
    v = try p.check(&.{try p.update(ref)}, &enforce_ada, c.ISSUEZ_E_REJECTED);
    try expectProblem(
        verdict(v, 0),
        c.ISSUEZ_PROBLEM_AUTHOR_MISMATCH,
        c.ISSUEZ_FIELD_UNKNOWN,
        spoof.commit,
        "",
    );
    c.issuez_push_verdicts_free(v);
    const warn = [_]c.issuez_op{
        c.issuez_opt_pusher_email(fixture.str("ada@example.invalid")),
        c.issuez_opt_author_policy(c.ISSUEZ_AUTHOR_WARN),
    };
    v = try p.check(&.{try p.update(ref)}, &warn, c.ISSUEZ_OK);
    try testing.expect(
        verdict(v, 0).accept and has(verdict(v, 0), c.ISSUEZ_PROBLEM_AUTHOR_MISMATCH),
    );
    c.issuez_push_verdicts_free(v);

    // A client number: refused unless clients may number; then a taken one.
    const numbered = try fixture.create(
        p.client,
        &.{ c.issuez_set_title(fixture.str("Numbered")), c.issuez_set_number(5) },
    );
    const nref = try std.fmt.allocPrint(a, "refs/issues/{s}", .{numbered.idSlice()});
    v = try p.check(&.{try p.update(nref)}, &.{}, c.ISSUEZ_E_REJECTED);
    try expectProblem(
        verdict(v, 0),
        c.ISSUEZ_PROBLEM_READ_ONLY_FIELD,
        c.ISSUEZ_FIELD_NUMBER,
        numbered.tip,
        "",
    );
    c.issuez_push_verdicts_free(v);
    const numbers = [_]c.issuez_op{c.issuez_opt_allow_numbers(true)};
    v = try p.check(&.{try p.update(nref)}, &numbers, c.ISSUEZ_OK);
    try testing.expect(!verdict(v, 0).needs_number);
    c.issuez_push_verdicts_free(v);
    try p.land(&.{nref});
    const twin = try fixture.titled(p.client, "Twin");
    const tref = try std.fmt.allocPrint(a, "refs/issues/{s}", .{twin.idSlice()});
    _ = try fixture.runGit(
        a,
        p.client_path,
        &.{
            "update-ref",
            tref,
            try fixture.runGit(
                a,
                p.client_path,
                &.{
                    "commit-tree",
                    try fixture.runGit(a, p.client_path, &.{
                        "hash-object", "-t", "tree", "-w", "/dev/null",
                    }),
                    "-p",
                    tref,
                    "-m",
                    "Number\n\nX-Number: 5",
                },
            ),
        },
    );
    v = try p.check(&.{try p.update(tref)}, &numbers, c.ISSUEZ_E_REJECTED);
    try expectProblem(
        verdict(v, 0),
        c.ISSUEZ_PROBLEM_DUPLICATE_NUMBER,
        c.ISSUEZ_FIELD_NUMBER,
        null,
        numbered.idSlice(),
    );
    c.issuez_push_verdicts_free(v);

    const tree = try fixture.runGit(
        a,
        p.client_path,
        &.{ "hash-object", "-t", "tree", "-w", "/dev/null" },
    );

    // The landed #5 becomes #6: only a foreign commit can say so.
    const renumbered = try fixture.runGit(
        a,
        p.client_path,
        &.{ "commit-tree", tree, "-p", nref, "-m", "Number\n\nX-Number: 6" },
    );
    _ = try fixture.runGit(a, p.client_path, &.{ "update-ref", nref, renumbered });
    v = try p.check(&.{try p.update(nref)}, &numbers, c.ISSUEZ_E_REJECTED);
    try expectProblem(
        verdict(v, 0),
        c.ISSUEZ_PROBLEM_READ_ONLY_FIELD,
        c.ISSUEZ_FIELD_NUMBER,
        null,
        "",
    );
    c.issuez_push_verdicts_free(v);

    // Another Format-Version.
    const future = try fixture.runGit(
        a,
        p.client_path,
        &.{ "commit-tree", tree, "-m", "Future\n\nState: open\nFormat-Version: 2" },
    );
    var foid: c.issuez_oid = undefined;
    _ = c.issuez_oid_parse(fixture.str(future), &foid, null);
    const fut = c.issuez_ref_update{
        .ref = fixture.str("refs/issues/0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c"),
        .old_oid = .{},
        .new_oid = foid,
        .reserved = .{ 0, 0 },
    };
    v = try p.check(&.{fut}, &.{}, c.ISSUEZ_E_REJECTED);
    try testing.expect(has(verdict(v, 0), c.ISSUEZ_PROBLEM_UNSUPPORTED_FORMAT));
    c.issuez_push_verdicts_free(v);
}

test "issuez_push_check: an X-Author-Id passes as the pusher's own UUID" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var p: Push = undefined;
    try p.init();
    defer p.deinit();
    const a = p.r.arena();
    // Ada's email, Mallory's UUID.
    const mallory = "1d9e8b63-4a2f-4c7b-8e3d-6f5a4b3c2d1e";
    const forged: c.issuez_actor = .{
        .name = fixture.str("Ada"),
        .email = fixture.str("ada@example.invalid"),
        .user_id = fixture.str(mallory),
        .at = null,
        .reserved = .{ 0, 0, 0, 0 },
    };
    const ops = [_]c.issuez_op{c.issuez_set_title(fixture.str("Forged"))};
    var w: ?*c.issuez_write = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_issue_create(p.client, &ops, 1, &forged, null, &w, null),
        null,
    );
    const ref = try std.fmt.allocPrint(
        a,
        "refs/issues/{s}",
        .{fixture.slice(c.issuez_write_id(w))},
    );
    c.issuez_write_free(w);
    const mallory_id = [_]c.issuez_op{
        c.issuez_opt_pusher_email(fixture.str("ada@example.invalid")),
        c.issuez_opt_pusher_user_id(fixture.str(mallory)),
        c.issuez_opt_author_policy(c.ISSUEZ_AUTHOR_ENFORCE),
    };
    const v = try p.check(&.{try p.update(ref)}, &mallory_id, c.ISSUEZ_OK);
    c.issuez_push_verdicts_free(v);
    // Not a UUID.
    const bad = [_]c.issuez_op{c.issuez_opt_pusher_user_id(fixture.str("42"))};
    const up = [_]c.issuez_ref_update{try p.update(ref)};
    var out: ?*c.issuez_push_verdicts = null;
    var err: ?*c.issuez_error = null;
    try testing.expect(c.issuez_push_check(
        p.r.handle,
        &up,
        1,
        &bad,
        1,
        null,
        &out,
        &err,
    ) != c.ISSUEZ_OK);
    try testing.expect(out == null);
    c.issuez_error_free(err);
}

test "issuez_push_check: purges need leave, and allow the rewrite" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var p: Push = undefined;
    try p.init();
    defer p.deinit();
    const a = p.r.arena();
    const x = try fixture.titled(p.client, "Talk");
    const said = try fixture.comment(p.client, x.idStr(), "Abuse");
    _ = try fixture.comment(p.client, x.idStr(), "Fine");
    const xref = try std.fmt.allocPrint(a, "refs/issues/{s}", .{x.idSlice()});
    try p.land(&.{xref});
    var pr: ?*c.issuez_purge_result = null;
    try expect.code(
        c.ISSUEZ_OK,
        c.issuez_purge_comment(
            p.client,
            x.idStr(),
            &said.commit,
            &fixture.ada,
            fixture.str("abuse"),
            null,
            &pr,
            null,
        ),
        null,
    );
    c.issuez_purge_result_free(pr);
    const xt = try std.fmt.allocPrint(a, "refs/issuez-purged/{s}", .{x.idSlice()});
    const ups = [_]c.issuez_ref_update{
        try p.update(xref),
        try p.update(xt),
    };

    var v = try p.check(&ups, &.{}, c.ISSUEZ_E_REJECTED);
    try testing.expect(has(verdict(v, 1), c.ISSUEZ_PROBLEM_PURGE_NOT_ALLOWED));
    c.issuez_push_verdicts_free(v);
    const leave = [_]c.issuez_op{c.issuez_opt_allow_purge(true)};
    v = try p.check(&ups, &leave, c.ISSUEZ_OK);
    try testing.expectEqual(@as(u32, c.ISSUEZ_PUSH_REWRITE), verdict(v, 0).action);
    try testing.expectEqual(@as(u32, c.ISSUEZ_KIND_TOMBSTONE), verdict(v, 1).kind);
    c.issuez_push_verdicts_free(v);

    // With the tombstone in, the old history can't come back.
    try p.land(&.{xt});
    const back = c.issuez_ref_update{
        .ref = fixture.str(xref),
        .old_oid = try p.serverTip(xref),
        .new_oid = try p.serverTip(xref),
        .reserved = .{ 0, 0 },
    };
    v = try p.check(&.{back}, &.{}, c.ISSUEZ_E_REJECTED);
    try testing.expect(has(verdict(v, 0), c.ISSUEZ_PROBLEM_PURGED));
    c.issuez_push_verdicts_free(v);
    // A forged tombstone commit isn't a purge.
    const tree = try fixture.runGit(
        a,
        p.client_path,
        &.{ "hash-object", "-t", "tree", "-w", "/dev/null" },
    );
    const forged = try fixture.runGit(
        a,
        p.client_path,
        &.{ "commit-tree", tree, "-p", xt, "-m", "Hello\n\nX-Purge: maybe" },
    );
    var foid: c.issuez_oid = undefined;
    _ = c.issuez_oid_parse(fixture.str(forged), &foid, null);
    const fake = c.issuez_ref_update{
        .ref = fixture.str(xt),
        .old_oid = try p.serverTip(xt),
        .new_oid = foid,
        .reserved = .{ 0, 0 },
    };
    v = try p.check(&.{fake}, &leave, c.ISSUEZ_E_REJECTED);
    try testing.expect(has(verdict(v, 0), c.ISSUEZ_PROBLEM_NOT_A_PURGE));
    c.issuez_push_verdicts_free(v);
}

test "issuez_push_check: derived attachment refs, the quarantine, bad input" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var p: Push = undefined;
    try p.init();
    defer p.deinit();
    const a = p.r.arena();
    const x = try fixture.titled(p.client, "Screenshot");
    const xref = try std.fmt.allocPrint(a, "refs/issues/{s}", .{x.idSlice()});
    // A derived ref with a tree of its own: not what the issue derives.
    const tree = try fixture.runGit(
        a,
        p.client_path,
        &.{ "hash-object", "-t", "tree", "-w", "/dev/null" },
    );
    const fake = try fixture.runGit(
        a,
        p.client_path,
        &.{ "commit-tree", tree, "-m", "Regenerate attachments" },
    );
    var foid: c.issuez_oid = undefined;
    _ = c.issuez_oid_parse(fixture.str(fake), &foid, null);
    const att = c.issuez_ref_update{
        .ref = fixture.str(try std.fmt.allocPrint(a, "refs/attachments/{s}", .{x.idSlice()})),
        .old_oid = .{},
        .new_oid = foid,
        .reserved = .{ 0, 0 },
    };
    const v = try p.check(&.{ try p.update(xref), att }, &.{}, c.ISSUEZ_E_REJECTED);
    try testing.expectEqual(@as(u32, c.ISSUEZ_KIND_ATTACHMENTS), verdict(v, 1).kind);
    try testing.expect(has(verdict(v, 1), c.ISSUEZ_PROBLEM_NOT_DERIVED));
    c.issuez_push_verdicts_free(v);

    // Without the quarantine the new objects aren't there.
    var out: ?*c.issuez_push_verdicts = null;
    const up = [_]c.issuez_ref_update{try p.update(xref)};
    try expect.code(
        c.ISSUEZ_E_REJECTED,
        c.issuez_push_check(p.r.handle, &up, 1, null, 0, null, &out, null),
        null,
    );
    try testing.expect(has(verdict(out.?, 0), c.ISSUEZ_PROBLEM_INVALID_HISTORY));
    c.issuez_push_verdicts_free(out);

    // Bad updates and options.
    const cases = [_]c.issuez_ref_update{
        .{ .ref = .{}, .old_oid = .{}, .new_oid = x.tip, .reserved = .{ 0, 0 } },
        .{ .ref = fixture.str(xref), .old_oid = .{}, .new_oid = .{}, .reserved = .{ 0, 0 } },
        .{ .ref = fixture.str(xref), .old_oid = .{}, .new_oid = x.tip, .reserved = .{ 1, 0 } },
    };
    for (cases) |bad| {
        out = null;
        const one = [_]c.issuez_ref_update{bad};
        try expect.code(
            c.ISSUEZ_E_INVALID_ARGUMENT,
            c.issuez_push_check(p.r.handle, &one, 1, null, 0, null, &out, null),
            null,
        );
        try testing.expect(out == null);
    }
    var err: ?*c.issuez_error = null;
    const wrong = [_]c.issuez_op{c.issuez_set_title(fixture.str("x"))};
    try expect.code(
        c.ISSUEZ_E_INVALID_VALUE,
        c.issuez_push_check(p.r.handle, &up, 1, &wrong, 1, null, &out, &err),
        err,
    );
    c.issuez_error_free(err);
    try expect.code(
        c.ISSUEZ_E_INVALID_ARGUMENT,
        c.issuez_push_check(p.r.handle, &up, 1, null, 0, null, null, null),
        null,
    );
}

test "issuez_push_verdict_attachment_at: the images new commits add, the issue's author" {
    const leaks = fixture.Leaks.start();
    defer leaks.check();
    var p: Push = undefined;
    try p.init();
    defer p.deinit();
    const a = p.r.arena();
    // The client keeps no bytes, as a host's clients upload them first.
    const opened = fixture.tryOpen(
        p.client_path,
        &.{fixture.opNum(c.ISSUEZ_OPT_ATTACHMENT_STORE, 0)},
        null,
    );
    try expect.code(c.ISSUEZ_OK, opened[0], null);
    const client = opened[1].?;
    defer c.issuez_repo_close(client);
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01" ++
        "\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x00IEND\xaeB`\x82";
    var image = fixture.opStr(c.ISSUEZ_FIELD_ATTACHMENTS, c.ISSUEZ_OP_ADD, png);
    image.name = fixture.str("shot.png");
    const x = try fixture.create(client, &.{ c.issuez_set_title(fixture.str("Pictured")), image });
    const xref = try std.fmt.allocPrint(a, "refs/issues/{s}", .{x.idSlice()});
    try p.land(&.{xref});
    const ops = [_]c.issuez_op{ c.issuez_set_comment(fixture.str("Another")), image };
    var w: ?*c.issuez_write = null;
    _ = try fixture.wrote(
        c.issuez_issue_update(client, x.idStr(), &ops, ops.len, &fixture.ada, null, &w, null),
        w,
        null,
        "comment",
    );
    const v = try p.check(&.{try p.update(xref)}, &.{}, c.ISSUEZ_OK);
    defer c.issuez_push_verdicts_free(v);
    const got = verdict(v, 0);
    try expect.str("ada@example.invalid", got.issue_author.*.email);
    // The root's image came with the earlier push; only the new one is here.
    try testing.expectEqual(@as(usize, 1), got.attachment_count);
    const att = c.issuez_push_verdict_attachment_at(c.issuez_push_verdicts_at(v, 0), 0).*;
    try testing.expectEqual(@as(usize, 64), att.sha256.len);
    try testing.expectEqual(@as(u64, png.len), att.size);
    try testing.expect(
        c.issuez_push_verdict_attachment_at(c.issuez_push_verdicts_at(v, 0), 1) == null,
    );
    try testing.expect(c.issuez_push_verdict_attachment_at(null, 0) == null);
}

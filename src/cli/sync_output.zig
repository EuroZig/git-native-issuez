//! Output shared by `merge`, `push` and `sync`. The issue lines are
//! upstream's, the quarantine lines are ours.

const std = @import("std");
const issuez = @import("issuez");
const uuid = issuez.format.uuid;
const sync = issuez.sync;

/// `a7f3c21` for an issue, `milestone a7f3c21` for a milestone.
pub fn label(buf: *[32]u8, ns: sync.Namespace, id: []const u8) []const u8 {
    if (ns != .milestones) return uuid.shortId(id);
    return std.fmt.bufPrint(buf, "milestone {s}", .{uuid.shortId(id)}) catch uuid.shortId(id);
}

pub fn printMerge(
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    remote: []const u8,
    report: sync.MergeReport,
    check: bool,
) void {
    if (report.entries.len == 0) {
        out.print("No issues found on remote '{s}'.\n", .{remote}) catch {};
        return;
    }
    for (report.entries) |e| {
        var buf: [32]u8 = undefined;
        const short = label(&buf, e.namespace, e.id);
        switch (e.outcome) {
            .created => if (check)
                out.print("[new] {s}: {s}\n", .{ short, e.title }) catch {}
            else
                out.print("Created {s}: {s}\n", .{ short, e.title }) catch {},
            .fast_forwarded => if (check)
                out.print("[fast-forward] {s}\n", .{short}) catch {}
            else
                out.print("Fast-forwarded {s}\n", .{short}) catch {},
            .merged => |base| if (check)
                out.print(
                    "[diverged] {s} (base: {s})\n",
                    .{ short, base.hex().short() },
                ) catch {}
            else
                out.print(
                    "Merged {s} (diverged at {s})\n",
                    .{ short, base.hex().short() },
                ) catch {},
            .up_to_date, .local_ahead => {},
            .quarantined => |reason| if (!e.kept_local) err.print("{s} {s}: {s}\n", .{
                if (check) "[quarantine]" else "Quarantined",
                short,
                reason.describe(),
            }) catch {},
        }
        for (e.conflicts) |c| err.print(
            "Conflict {s}: {f} was edited concurrently; kept '{s}', not '{s}'\n",
            .{ short, c.target, c.value, c.lost },
        ) catch {};
    }
    const up_to_date = report.count(.up_to_date) + report.count(.local_ahead);
    const counts = .{
        report.count(.created),
        report.count(.fast_forwarded),
        report.count(.merged),
        up_to_date,
    };
    if (check) {
        out.print("Check complete: {d} new, {d} fast-forward, " ++
            "{d} diverged, {d} up-to-date", counts) catch {};
    } else {
        out.print("Merge complete: {d} created, {d} fast-forwarded, " ++
            "{d} merged, {d} up-to-date", counts) catch {};
    }
    const quarantined = report.count(.quarantined);
    if (quarantined > 0) out.print(", {d} quarantined", .{quarantined}) catch {};
    out.writeAll("\n") catch {};
    var unacknowledged: usize = 0;
    for (report.entries) |e| if (e.outcome == .quarantined and !e.kept_local) {
        unacknowledged += 1;
    };
    if (unacknowledged > 0 and !check) {
        err.print(
            "warning: {d} remote issue(s) were not merged; local copies are untouched\n" ++
                "         and won't be pushed. See 'git issue status' to resolve them.\n",
            .{unacknowledged},
        ) catch {};
    }
}

pub fn printPush(
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    remote: []const u8,
    report: sync.PushReport,
) void {
    for (report.merges) |m| {
        out.print("The remote had new issue changes; merged them first:\n", .{}) catch {};
        printMerge(out, err, remote, m, false);
    }
    if (report.pushed == 0 and report.attachment_refs == 0) {
        out.writeAll("Everything up-to-date\n") catch {};
    } else if (report.pushed > 0) {
        out.print("Pushed {d} issue(s) to {s}.\n", .{ report.pushed, remote }) catch {};
    } else {
        out.print(
            "Pushed {d} attachment ref(s) to {s}.\n",
            .{ report.attachment_refs, remote },
        ) catch {};
    }
    if (report.lfs_uploaded > 0) out.print(
        "Uploaded {d} attachment object(s) to {s}'s LFS server.\n",
        .{ report.lfs_uploaded, remote },
    ) catch {};
    if (report.skipped_quarantined > 0) {
        err.print(
            "warning: {d} quarantined issue(s) not pushed " ++
                "(see 'git issue status {s}').\n",
            .{ report.skipped_quarantined, remote },
        ) catch {};
    }
}

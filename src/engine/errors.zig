//! What the library's errors mean, for front ends to show: a sentence
//! without a prefix or a final period, which says what to do where it can.
//! Front ends may say more (the CLI names its commands); a test checks that
//! every error of `Sync` (which includes `Repo`'s, `Catalog`'s and
//! `Attachments`') over both backends has a description.

const std = @import("std");

/// What a write refused and where: the error with the field (its trailer
/// key: "Title", "Labels", "X-Blocked-By", ...), the value and the limit
/// it broke. A front end shows it next to its input; `describe` words the
/// error alone.
pub const Diagnostic = struct {
    err: anyerror,
    key: []const u8,
    value: []const u8 = "",
    limit: ?u64 = null,
};

/// Collects what a write refused (`Repo.diagnostics`, `WriteOptions`).
pub const Diagnostics = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList(Diagnostic) = .empty,

    pub fn add(d: *Diagnostics, item: Diagnostic) void {
        d.list.append(d.arena, item) catch {};
    }

    /// The one the write failed on.
    pub fn last(d: *const Diagnostics) ?Diagnostic {
        return if (d.list.items.len > 0) d.list.items[d.list.items.len - 1] else null;
    }
};
const Limits = @import("repo.zig").Limits;

pub fn describe(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.Canceled => "canceled",
        // Backends.
        error.GitSpawnFailed => "could not run git (is it installed and on PATH?)",
        error.GitFailed => "a git command failed",
        error.GitTooOld => "git 2.30 or newer is required",
        error.NotARepository => "not a git repository",
        error.OutputTooLong => "git produced more output than allowed",
        error.GitTimedOut => "git took too long and was stopped",
        error.StoreFailed => "could not read or write the LFS store",
        error.RefConflict => "a ref changed while it was being updated",
        error.FetchFailed => "fetching from the remote failed",
        error.PushFailed => "pushing to the remote failed",
        error.LfsTransferFailed => "git-lfs couldn't transfer the attachment objects",
        // Reading issues.
        error.HistoryTooLong => "issue history is too long to load",
        error.CorruptIssue => "issue data is damaged",
        error.MissingParent => "an issue's history is incomplete (a parent commit is missing)",
        error.NoRoot => "an issue's history has no root commit",
        error.TooManyIssues => "more issues than the configured limit",
        error.InvalidLimits => "invalid limits",
        error.InvalidDoneStates => "git config issue.doneStates isn't valid: " ++
            @import("settings.zig").done_states_rule,
        error.InvalidIssueRef => "not an issue ref",
        // Writing issues.
        error.ConcurrentModification => "the issue kept changing while it was being updated; " ++
            "try again",
        error.IssueDisappeared => "the issue was deleted while it was being updated",
        error.VersionMismatch => "the issue changed since it was read",
        error.IdentityUnknown => "no git identity configured: set git config user.name and " ++
            "user.email",
        error.InvalidText => "values must not contain newlines",
        error.EmptyText => "the title or text must not be empty",
        error.BodyLooksLikeTrailers => "the last paragraph of the text would be read as issue " ++
            "metadata (lines like 'Key: value'); reword it or add a sentence after it",
        error.NumberAlreadySet => "the issue has another number already; numbers are written once",
        error.NumberTaken => "another issue here has that number",
        error.CommentNotAlone => "a comment can't go with a new description or a commit message",
        error.MessageHasBody => "with a new description, the message is only the subject (no " ++
            "blank lines)",
        error.TooLong => "text is too long",
        error.TooManyLabels => "too many labels",
        error.InvalidLabel => "labels must not contain commas or newlines",
        error.TooManyBlockers => "too many blockers",
        error.TooManyAssignees => "too many assignees",
        error.NothingToEdit => "nothing to change",
        error.InvalidValue => "invalid value (dates are YYYY-MM-DD, emails user@domain.tld, " ++
            "references full issue IDs, states letters, digits, '-' and '_', workflow states " ++
            "lowercase letters, digits and '-' starting with a letter, estimates within the " ++
            "limit, milestone mode explicit only with a milestone ID)",
        error.UnknownWorkflowState => "not one of the workflow states (git config " ++
            "issue.workflowStates; " ++
            "default backlog, ready, in-progress, review)",
        error.InvalidWorkflowStates => "git config issue.workflowStates has an entry that " ++
            "isn't a workflow state; " ++ @import("settings.zig").workflow_states_rule,
        error.ReferenceNotFound => "the referenced issue or milestone doesn't exist here",
        error.ParentIsSelf => "an issue can't be its own parent",
        error.ParentCycle => "that parent is the issue itself or one of its descendants " ++
            "(the hierarchy would loop)",
        error.TooDeep => "the hierarchy would be nested deeper than the depth limit",
        error.BlocksItself => "an issue can't block itself",
        error.BlockerCycle => "that issue is (transitively) blocked by this one; " ++
            "blocking it back would be a cycle",
        error.OpenDescendants => "the issue has open sub-issues; close them first",
        error.ClosedAncestor => "a parent (or one above it) is closed; reopen it first",
        error.GuardScanTooLarge => "checking the hierarchy would read more issues than allowed",
        error.ActiveChildren => "the issue has sub-issues that aren't deleted; delete or move " ++
            "them first",
        error.ParentDeleted => "that parent is deleted; restore it first",
        error.CommentNotFound => "that isn't a comment of this issue",
        error.DuplicateEdit => "the same issue or milestone is edited twice in one batch",
        // Milestones.
        error.MilestoneCompleted => "the milestone is completed; reopen it first",
        error.MilestoneRetired => "the milestone is retired; pick another one",
        error.OpenWorkInMilestone => "the milestone still has open issues; close or move them " ++
            "first",
        // Attachments.
        error.AttachmentsUnsupported => "this backend has no attachment store",
        error.LfsUnavailable => "attachments need git-lfs, which isn't installed " ++
            "(https://git-lfs.com)",
        error.UnsupportedType => "not a PNG, JPEG or WebP image",
        error.AnimatedImage => "animated images aren't supported",
        error.MediaMismatch => "the file's type doesn't match its contents",
        error.AttachmentTooLarge => "larger than the attachment size limit",
        error.EmptyAttachment => "the file is empty",
        error.TooManyAttachments => "more attachments than an issue may have",
        error.AttachmentNotFound => "no such attachment on this issue",
        error.NoAttachments => "no attachments given",
        error.AttachmentExists => "the issue has an attachment with that ID already",
        // Sync.
        error.InvalidRemoteName => "not a valid remote name",
        error.UnknownRemote => "no such remote",
        error.UnknownIssueRemote => "`git config issue.remote` names no remote; fix or unset it",
        error.PushRoundsExhausted => "the remote kept changing while pushing; try again",
        error.NotQuarantined => "the issue isn't quarantined",
        error.RemoteIssueInvalid => "the remote's issue fails the integrity checks; there is " ++
            "nothing valid to accept",
        error.BeforePushFailed => "the step before pushing failed, so nothing was pushed",
        error.LfsUploadFailed => "git-lfs couldn't upload the attachments' objects, so nothing " ++
            "was pushed",
        error.LeasedPushUnsupported => "a purge has to replace the remote's history, " ++
            "and this backend can't push with a lease",
        else => null,
    };
}

/// `describe`, with the numbers for errors about a limit:
/// `"{f}", .{errors.Description{ .err = e, .limits = repo.limits }}`.
/// Writes the error's name when it has no description.
pub const Description = struct {
    err: anyerror,
    /// The limits of the `Repo` that failed.
    limits: Limits,

    /// Whether `describe` knows the error.
    pub fn known(d: Description) bool {
        return describe(d.err) != null;
    }

    pub fn format(d: Description, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const l = d.limits;
        switch (d.err) {
            error.TooDeep => try w.print(
                "the hierarchy would be nested deeper than {d} levels",
                .{l.max_depth},
            ),
            error.TooManyAttachments => try w.print(
                "an issue can have at most {d} attachments",
                .{l.max_attachments},
            ),
            error.AttachmentTooLarge => {
                const mib = 1024 * 1024;
                const n = l.max_attachment_bytes;
                if (n % mib == 0) {
                    try w.print("larger than the attachment limit ({d} MiB)", .{n / mib});
                } else try w.print("larger than the attachment limit ({d} bytes)", .{n});
            },
            error.TooManyLabels => try w.print("too many labels (at most {d})", .{l.max_labels}),
            error.TooManyBlockers => try w.print(
                "too many blockers (at most {d})",
                .{l.max_blockers},
            ),
            error.TooLong => try w.print(
                "text is too long (titles {d} bytes, field values {d}, descriptions and " ++
                    "comments {d})",
                .{ l.max_title_bytes, l.max_trailer_value_bytes, l.max_body_bytes },
            ),
            else => if (describe(d.err)) |text|
                try w.writeAll(text)
            else
                try w.print("{t}", .{d.err}),
        }
    }
};

/// The backend's last error output (`GitProcess.lastStderr`), trimmed,
/// when it says more about `err`. Null for backends without one.
pub fn gitDetail(backend: anytype, err: anyerror) ?[]const u8 {
    if (!@hasDecl(@TypeOf(backend.*), "lastStderr") or !hasGitDetail(err)) return null;
    const d = std.mem.trim(u8, backend.lastStderr(), " \t\r\n");
    return if (d.len == 0) null else d;
}

/// Whether the backend's last error output says more about `err`.
fn hasGitDetail(err: anyerror) bool {
    return switch (err) {
        error.GitFailed,
        error.FetchFailed,
        error.PushFailed,
        error.IdentityUnknown,
        error.LfsTransferFailed,
        error.LfsUploadFailed,
        => true,
        else => false,
    };
}

test Description {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f}", .{Description{ .err = error.TooDeep, .limits = .{} }});
    try std.testing.expectEqualStrings(
        "the hierarchy would be nested deeper than 8 levels",
        w.buffered(),
    );
    w = .fixed(&buf);
    try w.print("{f}", .{Description{ .err = error.AttachmentTooLarge, .limits = .{} }});
    try std.testing.expectEqualStrings("larger than the attachment limit (5 MiB)", w.buffered());
}

test "every library error has a description" {
    const backends = [_]type{
        @import("../backend/GitProcess.zig"),
        @import("../backend/GitSim.zig"),
    };
    inline for (backends) |B| {
        const Sync = @import("sync.zig").Sync(B);
        const Settings = @import("settings.zig").Settings;
        inline for (.{ Sync.Error, Settings.Error }) |E| {
            inline for (@typeInfo(E).error_set.?) |e| {
                const err = @field(anyerror, e.name);
                std.testing.expect(describe(err) != null) catch |x| {
                    std.debug.print("no description for error.{s}\n", .{e.name});
                    return x;
                };
            }
        }
    }
}

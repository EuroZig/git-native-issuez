//! The MCP tools: thin wrappers around the library (`Repo`, `query`,
//! `projection`, `Catalog`). Each call gets the backend from `Repos.open`,
//! which must show the repository as it is now, changes made by other tools
//! in the meantime included.
//!
//! Generic over `Repos`, which hands out the backend for one call:
//!
//! ```
//! pub const Backend: type;
//! fn open(self, *mcp.Context, repo: ?[]const u8) !*Backend
//! fn close(self, *Backend) void
//! ```
//!
//! `repo` is the tool's `repo` argument, null for the server's own
//! repository. `open` reports its own errors, with `ctx.fail`.

const std = @import("std");
const issuez = @import("issuez");
const Date = issuez.format.fields.Date;
const mcp = @import("blitzmcp");

const Allocator = std.mem.Allocator;
const core = issuez.format.core;
const uuid = issuez.format.uuid;
const query = issuez.query;
const Oid = issuez.engine.Oid;
const IssueRef = issuez.engine.IssueRef;
const Projection = issuez.projection.Projection;

pub const instructions =
    \\Issues of the git repository, stored in git refs (refs/issues/*) in the
    \\git-native-issue format and shared with `git issue` and every clone.
    \\Issue IDs are UUIDs; a unique prefix (the 7-character short_id, say) is
    \\enough. Every change is a commit, nothing is rewritten. Writes take an
    \\optional expect_version (an issue's `version`): if the issue changed since,
    \\the write fails instead of overwriting. Sync with remotes is not done
    \\here: run `git issue sync <remote>`. Every tool takes an optional repo,
    \\an absolute path to the repository; without it, the server's repository
    \\(the directory the client started it in). Pass repo when working in
    \\another repository than that one. The server's repository is also
    \\served as resources (git-issue://issues, git-issue://milestones,
    \\git-issue://issues/{id}); subscribe to hear when others change them.
;

// Results. The field names follow `git issue --json` (docs/json.md).

pub const Person = struct { name: []const u8, email: []const u8 };

pub const Conflict = struct {
    /// A field name, `Description` or `Comment <id>`.
    field: []const u8,
    kept: []const u8,
    lost: []const u8,
};

pub const Problem = struct {
    kind: []const u8,
    /// The other issue involved, if any.
    other: ?[]const u8 = null,
    description: []const u8,
};

pub const Progress = struct { closed: u32, total: u32 };

/// Who closed a done issue, and when (`issuez.view.closure`).
pub const Closed = struct {
    author: Person,
    author_id: ?[]const u8 = null,
    date: []const u8,
    /// The commit that set the done state.
    commit: []const u8,
};

/// A trailer field, as written.
pub const Field = struct { key: []const u8, value: []const u8 };

pub const Issue = struct {
    id: []const u8,
    short_id: []const u8,
    /// The issue's tip commit. Pass it as `expect_version` to a write.
    version: []const u8,
    title: []const u8,
    state: []const u8,
    /// `closed` or one of git config issue.doneStates.
    done: bool,
    deleted: bool,
    labels: []const []const u8,
    assignee: ?[]const u8 = null,
    /// Everyone assigned, by email; `assignee` is the first.
    assignees: []const []const u8 = &.{},
    /// `#number`, when it has one.
    number: ?u64 = null,
    locked: bool = false,
    lock_reason: ?[]const u8 = null,
    /// The branch or tag it is about.
    ref: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    milestone: ?[]const u8 = null,
    milestone_id: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    blocked_by: []const []const u8,
    start: ?[]const u8 = null,
    due: ?[]const u8 = null,
    estimate_minutes: ?u32 = null,
    workflow: ?[]const u8 = null,
    author: Person,
    created: []const u8,
    updated: []const u8,
    /// Every other field with a value (Fixed-By, Release, Reason, ...).
    fields: []const Field,
    conflicts: []const Conflict,
    attachments: usize,
    /// Follows `inherit` up the parent chain.
    effective_milestone_id: ?[]const u8 = null,
    /// Includes the default for open issues without one.
    effective_workflow: ?[]const u8 = null,
    /// Done and total leaves below it. Null without sub-issues.
    progress: ?Progress = null,
    /// An open blocker remains.
    blocked: bool = false,
    problems: []const Problem = &.{},
    /// Null for an issue that isn't done, or was created done.
    closed: ?Closed = null,
};

pub const Comment = struct {
    /// The commit.
    id: []const u8,
    /// comment: text someone wrote. update: a commit that only changed
    /// fields or the state, or merged; its subject says what.
    kind: issuez.model.issue.Comment.Kind,
    author: Person,
    date: []const u8,
    subject: []const u8,
    text: []const u8,
    state_change: ?[]const u8 = null,
    merge: bool,
    edited: bool,
    /// A purge took its text, attachments and origin.
    purged: bool = false,
    /// Where imported text came from.
    original_author: ?[]const u8 = null,
    original_id: ?[]const u8 = null,
    reactions: []const Reaction = &.{},
};

/// Everyone who reacted with one emoji, by email.
pub const Reaction = struct { emoji: []const u8, users: []const []const u8 };

pub const IssueList = struct {
    /// Matching issues, before `limit`.
    total: usize,
    issues: []const Issue,
};

pub const IssueDetail = struct {
    issue: Issue,
    description: []const u8,
    /// Reactions on the issue itself; a comment's are with the comment.
    reactions: []const Reaction = &.{},
    /// Where an imported issue came from.
    original_author: ?[]const u8 = null,
    original_id: ?[]const u8 = null,
    /// Every commit after the first apart from events, oldest first:
    /// comments and updates (`kind`). Deleted comments are left out.
    comments: []const Comment,
};

pub const SearchHit = struct { issue: Issue, matches: []const []const u8 };

pub const SearchResult = struct {
    /// Matching issues, before `limit`.
    total: usize,
    results: []const SearchHit,
};

pub const Milestone = struct {
    id: []const u8,
    short_id: []const u8,
    name: []const u8,
    status: []const u8,
    due: ?[]const u8 = null,
    description: []const u8,
    progress: Progress,
};

pub const MilestoneList = struct { milestones: []const Milestone };

pub const Written = struct {
    id: []const u8,
    short_id: []const u8,
    /// The issue's new tip.
    version: []const u8,
};

pub const Commented = struct {
    id: []const u8,
    version: []const u8,
    /// The new comment's ID.
    comment_id: []const u8,
};

pub const Edited = struct {
    id: []const u8,
    version: []const u8,
    changes: []const []const u8,
};

pub const Reacted = struct {
    id: []const u8,
    /// The new tip; null when nothing changed (already so).
    version: ?[]const u8 = null,
};

pub const StateChanged = struct {
    id: []const u8,
    version: []const u8,
    state: []const u8,
};

// Arguments.

pub const ListArgs = struct {
    state: ?[]const u8 = null,
    label: ?[]const u8 = null,
    assignee: ?[]const u8 = null,
    priority: ?core.Priority = null,
    sort: query.SortKey = .created,
    reverse: bool = false,
    problems: bool = false,
    conflicts: bool = false,
    deleted: bool = false,
    limit: u32 = 100,
    repo: ?[]const u8 = null,

    pub const descriptions = .{
        .state = "open, closed, another state, or all. Default: every issue that isn't done " ++
            "(closed or a state in git config issue.doneStates).",
        .label = "Only issues with this label.",
        .assignee = "Only issues assigned to this email. Empty: unassigned issues.",
        .priority = "Only issues with this priority.",
        .sort = "Newest, highest or not done first; reverse flips it.",
        .reverse = "Reverse the order.",
        .problems = "Only issues with problems (missing or looping parents or blockers, invalid " ++
            "values, ...), in any state unless state is given.",
        .conflicts = "Only issues with fields edited concurrently.",
        .deleted = "Only deleted issues.",
        .limit = "At most this many issues (total counts them all).",
        .repo = repo_description,
    };
};

const repo_description = "The repository: an absolute path to any directory in it. " ++
    "Default: the server's repository.";

pub const IdArgs = struct {
    id: []const u8,
    repo: ?[]const u8 = null,

    pub const descriptions = .{
        .id = "The issue ID or a unique prefix.",
        .repo = repo_description,
    };
};

pub const SearchArgs = struct {
    text: []const u8,
    state: ?[]const u8 = null,
    ignore_case: bool = false,
    limit: u32 = 50,
    repo: ?[]const u8 = null,

    pub const descriptions = .{
        .text = "A fixed string, searched in titles, fields (as 'Key: value', State included), " ++
            "descriptions and comments.",
        .state = "open, closed, another state, or all (the default).",
        .ignore_case = "Ignore ASCII case.",
        .limit = "At most this many issues, newest first (total counts them all).",
        .repo = repo_description,
    };
};

pub const MilestoneArgs = struct {
    all: bool = false,
    repo: ?[]const u8 = null,

    pub const descriptions = .{
        .all = "Also completed and retired milestones.",
        .repo = repo_description,
    };
};

pub const CreateArgs = struct {
    title: []const u8,
    description: []const u8 = "",
    labels: []const []const u8 = &.{},
    assignee: ?[]const u8 = null,
    assignees: []const []const u8 = &.{},
    number: ?u64 = null,
    priority: ?core.Priority = null,
    milestone: ?[]const u8 = null,
    milestone_id: ?[]const u8 = null,
    milestone_mode: ?MilestoneMode = null,
    parent: ?[]const u8 = null,
    blocked_by: []const []const u8 = &.{},
    start: ?[]const u8 = null,
    due: ?[]const u8 = null,
    estimate: ?[]const u8 = null,
    workflow: ?[]const u8 = null,
    fields: []const Field = &.{},
    original_author: ?[]const u8 = null,
    original_id: ?[]const u8 = null,
    repo: ?[]const u8 = null,

    pub const descriptions = .{
        .title = "One line.",
        .description = "Markdown. Its last paragraph must not look like `Key: value` lines.",
        .labels = "Labels, without commas.",
        .assignee = "An email.",
        .assignees = "More emails to assign.",
        .number = number_description,
        .priority = "The priority.",
        .milestone = milestone_description,
        .milestone_id = milestone_id_description,
        .milestone_mode = milestone_mode_description,
        .parent = "The parent issue (ID or unique prefix).",
        .blocked_by = "Issues that block this one (IDs or unique prefixes).",
        .start = "Start date: YYYY-MM-DD, or relative to today in the user's time zone: today, " ++
            "tomorrow, +3d, -1w, +2m, fri, eom, eow.",
        .due = "Due date: YYYY-MM-DD, or relative to today in the user's time zone: today, " ++
            "tomorrow, +3d, -1w, +2m, fri, eom, eow.",
        .estimate = "Minutes, or a duration like 2h, 90m, 1h30m.",
        .workflow = "A workflow state from git config issue.workflowStates (default backlog, " ++
            "ready, in-progress, review).",
        .fields = fields_description,
        .original_author = original_author_description,
        .original_id = original_id_description,
        .repo = repo_description,
    };
};

const fields_description = "A host's own fields, keys starting X- that the format " ++
    "doesn't use (X-Forgejo-Project). An empty value clears one.";
const original_author_description = "Imports: who wrote it where it came from.";
const original_id_description = "Imports: its ID where it came from.";

const milestone_description = "A milestone name. It links the one open catalog milestone " ++
    "with exactly this name (see list_milestones); otherwise it is written as plain text.";
const milestone_id_description = "A catalog milestone by ID prefix or name. Not with milestone.";
const milestone_mode_description = "inherit: take the parent's milestone; none: no milestone, " ++
    "and stop inheriting; explicit: the catalog milestone given or already set.";

pub const MilestoneMode = issuez.format.fields.MilestoneMode;

pub const CommentArgs = struct {
    id: []const u8,
    text: []const u8,
    original_author: ?[]const u8 = null,
    original_id: ?[]const u8 = null,
    expect_version: ?[]const u8 = null,
    repo: ?[]const u8 = null,

    pub const descriptions = .{
        .id = "The issue ID or a unique prefix.",
        .text = "Markdown. The first line is the subject.",
        .original_author = original_author_description,
        .original_id = original_id_description,
        .expect_version = expect_description,
        .repo = repo_description,
    };
};

const expect_description = "Fail if the issue's version is no longer this one.";
const number_description = "The issue's number (#n), unique in this repository.";
const comment_description = "A comment in the same commit (Markdown, first line the subject).";

pub const EditArgs = struct {
    id: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    labels: ?[]const []const u8 = null,
    add_labels: []const []const u8 = &.{},
    remove_labels: []const []const u8 = &.{},
    assignee: ?[]const u8 = null,
    add_assignees: []const []const u8 = &.{},
    remove_assignees: []const []const u8 = &.{},
    number: ?u64 = null,
    locked: ?bool = null,
    lock_reason: ?[]const u8 = null,
    ref: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    milestone: ?[]const u8 = null,
    milestone_id: ?[]const u8 = null,
    milestone_mode: ?MilestoneMode = null,
    parent: ?[]const u8 = null,
    add_blocked_by: []const []const u8 = &.{},
    remove_blocked_by: []const []const u8 = &.{},
    start: ?[]const u8 = null,
    due: ?[]const u8 = null,
    estimate: ?[]const u8 = null,
    workflow: ?[]const u8 = null,
    fields: []const Field = &.{},
    message: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    expect_version: ?[]const u8 = null,
    repo: ?[]const u8 = null,

    pub const descriptions = .{
        .id = "The issue ID or a unique prefix.",
        .title = "The new title.",
        .description = "Replaces the description.",
        .labels = "Replaces every label.",
        .add_labels = "Labels to add.",
        .remove_labels = "Labels to remove.",
        .assignee = "An email. Empty unassigns everyone.",
        .add_assignees = "Emails to assign as well.",
        .remove_assignees = "Emails to unassign.",
        .locked = "Lock (true) or unlock (false) the conversation.",
        .lock_reason = "With locked true: why.",
        .ref = "The branch or tag it is about. Empty clears it.",
        .number = number_description ++ " Only when it has none.",
        .priority = "low, medium, high or critical. Empty clears it.",
        .milestone = milestone_description ++ " Empty clears it, and stops inheriting one.",
        .milestone_id = milestone_id_description,
        .milestone_mode = milestone_mode_description,
        .parent = "The parent issue (ID or unique prefix). Empty clears it.",
        .add_blocked_by = "Issues that now block this one.",
        .remove_blocked_by = "Blockers to remove.",
        .start = "Start date: YYYY-MM-DD, or relative to today in the user's time zone (today, " ++
            "+3d, fri, eom). Empty clears it.",
        .due = "Due date: YYYY-MM-DD, or relative to today in the user's time zone (today, +3d, " ++
            "fri, eom). Empty clears it.",
        .estimate = "Minutes, or a duration like 2h, 90m, 1h30m. Empty clears it.",
        .workflow = "A workflow state from git config issue.workflowStates. Empty clears it.",
        .fields = fields_description,
        .message = "The commit subject. Default: what changed.",
        .comment = comment_description ++ " Not with description or message.",
        .expect_version = expect_description,
        .repo = repo_description,
    };
};

pub const ReactArgs = struct {
    id: []const u8,
    emoji: []const u8,
    comment: ?[]const u8 = null,
    undo: bool = false,
    repo: ?[]const u8 = null,

    pub const descriptions = .{
        .id = "The issue ID or a unique prefix.",
        .emoji = "`:+1:` or the character itself.",
        .comment = "React to this comment (its ID or a unique prefix, see show_issue) " ++
            "instead of the issue.",
        .undo = "Take the reaction back.",
        .repo = repo_description,
    };
};

pub const StateArgs = struct {
    id: []const u8,
    state: []const u8,
    reason: ?[]const u8 = null,
    fixed_by: ?[]const u8 = null,
    release: ?[]const u8 = null,
    message: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    expect_version: ?[]const u8 = null,
    repo: ?[]const u8 = null,

    pub const descriptions = .{
        .id = "The issue ID or a unique prefix.",
        .state = "open, closed, or another state (letters, digits, - and _).",
        .reason = "Why it was closed: duplicate, wontfix, invalid or completed.",
        .fixed_by = "The commit that fixes it.",
        .release = "The release that ships the fix.",
        .message = "The commit subject. Default: Close issue, Reopen issue, ...",
        .comment = comment_description ++ " Not with message.",
        .expect_version = expect_description,
        .repo = repo_description,
    };
};

// Resources: the server's repository, as JSON in the tools' result types.

pub const uri_scheme = "git-issue://";
/// The issues that aren't done: `list_issues` without arguments.
pub const issues_uri = uri_scheme ++ "issues";
/// The open milestones: `list_milestones` without arguments.
pub const milestones_uri = uri_scheme ++ "milestones";
/// One issue, by ID or unique prefix: `show_issue`.
pub const issue_uri_prefix = issues_uri ++ "/";

pub const resources = [_]mcp.types.Resource{
    .{
        .uri = issues_uri,
        .name = "issues",
        .title = "Open issues",
        .description = "The issues that aren't done, newest first, at most 100 (list_issues " ++
            "without arguments).",
        .mimeType = "application/json",
    },
    .{
        .uri = milestones_uri,
        .name = "milestones",
        .title = "Open milestones",
        .description = "The open milestones with their progress (list_milestones without " ++
            "arguments).",
        .mimeType = "application/json",
    },
};

pub const resource_templates = [_]mcp.types.ResourceTemplate{.{
    .uriTemplate = issue_uri_prefix ++ "{id}",
    .name = "issue",
    .title = "An issue",
    .description = "An issue with its description and comments (show_issue); id is the UUID or " ++
        "a unique prefix.",
    .mimeType = "application/json",
}};

pub const ResourceUri = union(enum) {
    issues,
    milestones,
    /// The ID or prefix.
    issue: []const u8,

    pub fn parse(uri: []const u8) ?ResourceUri {
        if (std.mem.eql(u8, uri, issues_uri)) return .issues;
        if (std.mem.eql(u8, uri, milestones_uri)) return .milestones;
        if (!std.mem.startsWith(u8, uri, issue_uri_prefix)) return null;
        const id = uri[issue_uri_prefix.len..];
        if (id.len == 0 or std.mem.findScalar(u8, id, '/') != null) return null;
        return .{ .issue = id };
    }
};

/// The resources a client subscribed to. The server adds and removes; a
/// watcher's thread asks which a change touched.
pub const Subscriptions = struct {
    mutex: std.Io.Mutex = .init,
    uris: [max][max_uri_len]u8 = undefined,
    lens: [max]u8 = undefined,
    count: u8 = 0,

    pub const max = 128;
    /// An issue's URI with a full SHA-256-length ID fits.
    pub const max_uri_len = 160;

    pub const Error = error{ TooManySubscriptions, UriTooLong };

    pub fn add(s: *Subscriptions, io: std.Io, uri: []const u8) Error!void {
        if (uri.len > max_uri_len) return error.UriTooLong;
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        if (s.find(uri) != null) return;
        if (s.count == max) return error.TooManySubscriptions;
        @memcpy(s.uris[s.count][0..uri.len], uri);
        s.lens[s.count] = @intCast(uri.len);
        s.count += 1;
    }

    pub fn remove(s: *Subscriptions, io: std.Io, uri: []const u8) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        const i = s.find(uri) orelse return;
        s.count -= 1;
        s.uris[i] = s.uris[s.count];
        s.lens[i] = s.lens[s.count];
    }

    /// `send(context, uri)` if `uri` is still subscribed, under the lock:
    /// once an unsubscribe is answered, no notification for it follows.
    pub fn sendIfSubscribed(
        s: *Subscriptions,
        io: std.Io,
        uri: []const u8,
        context: anytype,
        comptime send: fn (@TypeOf(context), []const u8) anyerror!void,
    ) anyerror!void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        if (s.find(uri) == null) return;
        try send(context, uri);
    }

    fn find(s: *const Subscriptions, uri: []const u8) ?usize {
        for (0..s.count) |i| if (std.mem.eql(u8, s.at(i), uri)) return i;
        return null;
    }

    fn at(s: *const Subscriptions, i: usize) []const u8 {
        return s.uris[i][0..s.lens[i]];
    }

    /// The subscribed URIs whose content may have changed, in `arena`:
    /// `d` is what moved in the refs, `settings` that git config changed.
    /// The lists change with any issue or milestone. An issue's resource
    /// changes with the issue, the milestones and the settings; what it
    /// shows of other issues (progress, blocked) isn't followed.
    pub fn affected(
        s: *Subscriptions,
        io: std.Io,
        arena: Allocator,
        d: issuez.changes.Diff,
        settings: bool,
    ) Allocator.Error![]const []const u8 {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        var out: std.ArrayList([]const u8) = .empty;
        if (d.isEmpty() and !settings) return out.items;
        for (0..s.count) |i| {
            const u = s.at(i);
            const hit = switch (ResourceUri.parse(u) orelse continue) {
                .issues, .milestones => true,
                .issue => |prefix| settings or d.milestones or for (d.issues) |id| {
                    if (std.mem.startsWith(u8, id, prefix)) break true;
                } else false,
            };
            if (hit) try out.append(arena, try arena.dupe(u8, u));
        }
        return out.items;
    }
};

pub fn Handler(comptime Repos: type) type {
    const B = Repos.Backend;
    const Repo = issuez.Repo(B);
    const Catalog = issuez.Catalog(B);

    return struct {
        repos: *Repos,
        subscriptions: Subscriptions = .{},
        /// Where relative dates (`+3d`, `fri`) count from: the local date
        /// in `zone`, at `now_s` if set (tests), else now.
        zone: issuez.local_time.Zone = .utc,
        now_s: ?i64 = null,

        const Self = @This();

        /// One tool call's view of the repository.
        const Session = struct {
            backend: *B,
            repo: Repo,
            settings: issuez.Settings,

            /// `fail`, with the repo's limits and git's error output.
            fn fail(s: Session, ctx: *mcp.Context, e: anyerror) anyerror {
                return failWith(ctx, e, s.repo.limits, issuez.errors.gitDetail(s.backend, e));
            }

            fn catalog(s: Session) Catalog {
                return Catalog.fromRepo(s.repo);
            }

            /// Over `issues`, which must be every issue or `loadAround`'s.
            fn project(
                s: Session,
                arena: Allocator,
                issues: []const issuez.engine.Issue,
            ) !Projection {
                return s.catalog().project(arena, issues, .{});
            }
        };

        fn open(h: *Self, ctx: *mcp.Context, repo_path: ?[]const u8) !Session {
            const backend = try h.repos.open(ctx, repo_path);
            errdefer h.repos.close(backend);
            const settings = issuez.settings.read(B, ctx.arena, backend) catch |e|
                return failWith(ctx, e, .{}, issuez.errors.gitDetail(backend, e));
            var repo = Repo.fromSettings(backend, settings) catch |e| return ctx.fail(
                e,
                "git config issue.doneStates has '{s}'; " ++ issuez.settings.done_states_rule,
                .{settings.invalid_done_state.?},
            );
            // One listing of the issues per call, until a write.
            repo.call.listing = try ctx.arena.create(Repo.Listing);
            repo.call.listing.?.* = .{};
            return .{ .backend = backend, .repo = repo, .settings = settings };
        }

        fn close(h: *Self, s: Session) void {
            h.repos.close(s.backend);
        }

        /// A date as given (`2026-12-01`, `today`, `+3d`, `fri`, `eom`), as
        /// git stores it; empty stays empty, for clearing.
        /// A date as typed (`2026-12-01`, `today`, `+3d`, `fri`, `eom`).
        fn date(
            h: *Self,
            ctx: *mcp.Context,
            s: Session,
            field: []const u8,
            value: []const u8,
        ) !Date {
            const today = h.zone.today(h.now_s orelse issuez.local_time.nowS(ctx.io));
            return issuez.format.dates.parse(value, today, s.settings.work_days) orelse ctx.fail(
                error.InvalidValue,
                "{s} must be a date as YYYY-MM-DD, or like today, +3d, fri, eom, not '{s}'",
                .{ field, value },
            );
        }

        /// "" clears it.
        fn dateEdit(
            h: *Self,
            ctx: *mcp.Context,
            s: Session,
            field: []const u8,
            value: ?[]const u8,
        ) !?issuez.engine.EditSpec.DateEdit {
            const v = value orelse return null;
            if (v.len == 0) return .clear;
            return .{ .set = try h.date(ctx, s, field, v) };
        }

        pub fn listIssues(h: *Self, ctx: *mcp.Context, args: ListArgs) !IssueList {
            const arena = ctx.arena;
            const state = try stateFilter(ctx, args.state);
            const s = try h.open(ctx, args.repo);
            defer h.close(s);

            const all = s.repo.loadAll(arena) catch |e| return s.fail(ctx, e);
            const sorted = try query.list(arena, all, .{
                .state = state.state,
                .done = if (state.given or args.problems) null else false,
                .done_states = s.settings.done_states,
                .label = args.label,
                .assignee = args.assignee,
                .priority = args.priority,
                .deleted = args.deleted,
            }, .{
                .key = args.sort,
                .reverse = args.reverse,
                .done_states = s.settings.done_states,
            });
            const proj = s.project(arena, all) catch |e| return s.fail(ctx, e);

            var out: std.ArrayList(Issue) = .empty;
            var total: usize = 0;
            for (sorted) |issue| {
                if (args.conflicts and issue.conflicts.len == 0) continue;
                if (args.problems and proj.problemsOf(proj.find(issue.id).?).len == 0) continue;
                total += 1;
                if (out.items.len < args.limit) try out.append(
                    arena,
                    try issueResult(arena, s, issue, proj),
                );
            }
            return .{ .total = total, .issues = out.items };
        }

        pub fn showIssue(h: *Self, ctx: *mcp.Context, args: IdArgs) !IssueDetail {
            const arena = ctx.arena;
            const s = try h.open(ctx, args.repo);
            defer h.close(s);

            const ref = try resolveIssue(ctx, s, args.id);
            const around = s.repo.loadAround(arena, ref) catch |e| return s.fail(ctx, e);
            const proj = s.project(arena, around) catch |e| return s.fail(ctx, e);
            // loadAround has the issue first, unless it falls back to every
            // issue that loads and this one changed in between.
            const issue = if (proj.find(ref.id())) |i|
                proj.issues[i]
            else
                s.repo.load(arena, ref) catch |e| return s.fail(ctx, e);

            var comments: std.ArrayList(Comment) = .empty;
            for (issue.comments) |c| {
                if (c.deleted) continue;
                const hex = c.oid.hex();
                try comments.append(arena, .{
                    .id = try arena.dupe(u8, hex.slice()),
                    .kind = c.kind,
                    .author = try person(arena, c.author),
                    .date = try time(arena, c.author.time, c.author.tz_offset_minutes),
                    .subject = try text(arena, c.subject),
                    .text = try text(arena, try std.mem.join(arena, "\n", c.body)),
                    .state_change = if (c.state_change) |st| try text(arena, st.text()) else null,
                    .merge = c.is_merge,
                    .edited = c.edited,
                    .purged = c.purged,
                    .original_author = try optionalText(arena, c.original_author),
                    .original_id = try optionalText(arena, c.original_id),
                    .reactions = try reactionsOn(arena, issue, c.oid),
                });
            }
            return .{
                .issue = try issueResult(arena, s, issue, proj),
                .description = try text(arena, issue.description),
                .reactions = try reactionsOn(arena, issue, null),
                .original_author = try optionalText(arena, issue.original_author),
                .original_id = try optionalText(arena, issue.original_id),
                .comments = comments.items,
            };
        }

        pub fn reactIssue(h: *Self, ctx: *mcp.Context, args: ReactArgs) !Reacted {
            const arena = ctx.arena;
            if (!issuez.format.fields.isEmoji(args.emoji)) return ctx.fail(
                error.InvalidValue,
                "an emoji is 1 to 64 bytes without whitespace or commas, not '{s}'",
                .{args.emoji},
            );
            const s = try h.open(ctx, args.repo);
            defer h.close(s);

            const ref = try resolveIssue(ctx, s, args.id);
            var target: ?issuez.engine.Oid = null;
            if (args.comment) |prefix| {
                const issue = s.repo.load(arena, ref) catch |e| return s.fail(ctx, e);
                for (issue.comments) |c| {
                    if (c.is_merge) continue;
                    const hex = c.oid.hex();
                    if (!std.mem.startsWith(u8, hex.slice(), prefix)) continue;
                    if (target != null) return ctx.fail(
                        error.InvalidValue,
                        "comment '{s}' is ambiguous",
                        .{prefix},
                    );
                    target = c.oid;
                }
                if (target == null) return ctx.fail(
                    error.InvalidValue,
                    "no comment '{s}' on this issue",
                    .{prefix},
                );
            }
            const tip = s.repo.react(arena, ref.name, .{
                .target = target,
                .emoji = args.emoji,
                .present = !args.undo,
            }, .{}) catch |e| return s.fail(ctx, e);
            const version = if (tip.wrote) blk: {
                const hex = tip.tip.hex();
                break :blk try arena.dupe(u8, hex.slice());
            } else null;
            return .{ .id = ref.id(), .version = version };
        }

        pub fn searchIssues(h: *Self, ctx: *mcp.Context, args: SearchArgs) !SearchResult {
            const arena = ctx.arena;
            if (args.text.len == 0) return ctx.fail(
                error.InvalidValue,
                "text must not be empty",
                .{},
            );
            const state = try stateFilter(ctx, args.state orelse "all");
            const s = try h.open(ctx, args.repo);
            defer h.close(s);

            const all = s.repo.loadAll(arena) catch |e| return s.fail(ctx, e);
            const issues = try query.list(arena, all, .{
                .state = state.state,
                .done = null,
                .done_states = s.settings.done_states,
            }, .{ .done_states = s.settings.done_states });
            const proj = s.project(arena, all) catch |e| return s.fail(ctx, e);
            var out: std.ArrayList(SearchHit) = .empty;
            var total: usize = 0;
            for (issues) |issue| {
                const lines = try query.searchLines(
                    arena,
                    issue,
                    args.text,
                    .{ .ignore_case = args.ignore_case },
                );
                if (lines.len == 0) continue;
                total += 1;
                if (out.items.len == args.limit) continue;
                try out.append(arena, .{
                    .issue = try issueResult(arena, s, issue, proj),
                    .matches = try texts(arena, lines),
                });
            }
            return .{ .total = total, .results = out.items };
        }

        pub fn listMilestones(h: *Self, ctx: *mcp.Context, args: MilestoneArgs) !MilestoneList {
            const arena = ctx.arena;
            const s = try h.open(ctx, args.repo);
            defer h.close(s);

            const cat = s.catalog();
            const all = cat.list(arena) catch |e| return s.fail(ctx, e);
            const issues = s.repo.loadForGuards(arena) catch |e| return s.fail(ctx, e);
            const proj = cat.project(
                arena,
                issues,
                .{ .milestones = all },
            ) catch |e| return s.fail(ctx, e);
            var out: std.ArrayList(Milestone) = .empty;
            for (all) |m| {
                if (!args.all and m.status != .open) continue;
                const p = try proj.milestoneProgress(arena, m.id);
                try out.append(arena, .{
                    .id = try text(arena, m.id),
                    .short_id = try text(arena, uuid.shortId(m.id)),
                    .name = try text(arena, m.name),
                    .status = @tagName(m.status),
                    .due = if (m.due) |d| try std.fmt.allocPrint(arena, "{f}", .{d}) else null,
                    .description = try text(arena, m.description),
                    .progress = .{ .closed = p.closed, .total = p.total },
                });
            }
            return .{ .milestones = out.items };
        }

        pub fn createIssue(h: *Self, ctx: *mcp.Context, args: CreateArgs) !Written {
            const arena = ctx.arena;
            const s = try h.open(ctx, args.repo);
            defer h.close(s);

            var blockers: std.ArrayList([]const u8) = .empty;
            for (args.blocked_by) |b| try blockers.append(
                arena,
                (try resolveIssue(ctx, s, b)).id(),
            );
            if (args.workflow) |w| try checkWorkflow(ctx, s.settings, w);
            const ms = try chooseMilestone(ctx, s, .{
                .name = args.milestone,
                .id = args.milestone_id,
                .mode = args.milestone_mode,
                .parent_given = args.parent != null,
            });
            const created = s.repo.create(arena, .{
                .title = args.title,
                .body = args.description,
                .labels = args.labels,
                .assignees = try people(ctx, args.assignee, args.assignees),
                .number = args.number,
                .priority = args.priority,
                .milestone = ms.edit(),
                .parent = if (args.parent) |p| (try resolveIssue(ctx, s, p)).id() else null,
                .blocked_by = blockers.items,
                .start_date = if (args.start) |d| try h.date(ctx, s, "start", d) else null,
                .due_date = if (args.due) |d| try h.date(ctx, s, "due", d) else null,
                .estimate_minutes = if (args.estimate) |e| try duration(ctx, e) else null,
                .workflow = args.workflow,
                .extra = try hostFields(arena, args.fields),
                .original = .{ .author = args.original_author, .id = args.original_id },
            }, .{}) catch |e| return s.fail(ctx, e);
            const hex = created.tip.hex();
            return .{
                .id = try arena.dupe(u8, created.id),
                .short_id = try arena.dupe(u8, issuez.shortId(created.id)),
                .version = try arena.dupe(u8, hex.slice()),
            };
        }

        pub fn commentIssue(h: *Self, ctx: *mcp.Context, args: CommentArgs) !Commented {
            const arena = ctx.arena;
            const s = try h.open(ctx, args.repo);
            defer h.close(s);

            const ref = try resolveIssue(ctx, s, args.id);
            const tip = s.repo.comment(arena, ref.name, .{
                .text = args.text,
                .original = .{ .author = args.original_author, .id = args.original_id },
                .expect = try expectVersion(ctx, s.backend, args.expect_version),
            }, .{}) catch |e| return s.fail(ctx, e);
            const hex = tip.tip.hex();
            const version = try arena.dupe(u8, hex.slice());
            return .{ .id = ref.id(), .version = version, .comment_id = version };
        }

        pub fn editIssue(h: *Self, ctx: *mcp.Context, args: EditArgs) !Edited {
            const arena = ctx.arena;
            const s = try h.open(ctx, args.repo);
            defer h.close(s);

            const ref = try resolveIssue(ctx, s, args.id);
            var spec: issuez.engine.EditSpec = .{
                .title = args.title,
                .description = args.description,
                .set_labels = args.labels,
                .add_labels = args.add_labels,
                .remove_labels = args.remove_labels,
                .set_assignees = if (args.assignee) |a| try people(ctx, a, &.{}) else null,
                .add_assignees = try people(ctx, null, args.add_assignees),
                .remove_assignees = args.remove_assignees,
                .number = args.number,
                .locked = args.locked,
                .lock_reason = args.lock_reason,
                .ref = .fromInput(args.ref),
                .start_date = try h.dateEdit(ctx, s, "start", args.start),
                .due_date = try h.dateEdit(ctx, s, "due", args.due),
                .workflow = .fromInput(args.workflow),
                .message = args.message,
                .comment = args.comment,
                .extra = try hostFields(arena, args.fields),
                .expect = try expectVersion(ctx, s.backend, args.expect_version),
            };
            if (args.priority) |p| spec.priority = if (p.len == 0) .clear else .{
                .set = core.Priority.parse(p) orelse return ctx.fail(
                    error.InvalidValue,
                    "priority must be low, medium, high or critical, not '{s}'",
                    .{p},
                ),
            };
            if (args.estimate) |e| spec.estimate_minutes = if (e.len == 0) .clear else .{
                .set = try duration(ctx, e),
            };
            if (args.workflow) |w| if (w.len > 0) try checkWorkflow(ctx, s.settings, w);
            if (args.parent) |p| spec.parent = if (p.len == 0)
                .clear
            else
                .{ .set = (try resolveIssue(ctx, s, p)).id() };
            var add: std.ArrayList([]const u8) = .empty;
            for (args.add_blocked_by) |b| try add.append(arena, (try resolveIssue(ctx, s, b)).id());
            spec.add_blocked_by = add.items;
            var remove: std.ArrayList([]const u8) = .empty;
            for (args.remove_blocked_by) |b| try remove.append(
                arena,
                (try resolveIssue(ctx, s, b)).id(),
            );
            spec.remove_blocked_by = remove.items;
            const milestone_set = args.milestone != null or args.milestone_id != null or
                args.milestone_mode != null;
            if (milestone_set) {
                const current = s.repo.load(arena, ref) catch |e| return s.fail(ctx, e);
                const ms = try chooseMilestone(ctx, s, .{
                    .name = args.milestone,
                    .id = args.milestone_id,
                    .mode = args.milestone_mode,
                    .current = current,
                    .parent_given = args.parent != null and args.parent.?.len > 0,
                });
                spec.milestone = ms.edit();
            }

            const result = s.repo.edit(arena, ref.name, spec, .{}) catch |e| return s.fail(ctx, e);
            const changes = try arena.alloc([]const u8, result.changes.len);
            for (result.changes, changes) |c, *out| out.* = c.name();
            const hex = result.tip.hex();
            return .{
                .id = ref.id(),
                .version = try arena.dupe(u8, hex.slice()),
                .changes = changes,
            };
        }

        pub fn @"resources/list"() mcp.types.ListResourcesResult {
            return .{ .resources = &resources };
        }

        pub fn @"resources/templates/list"() mcp.types.ListResourceTemplatesResult {
            return .{ .resourceTemplates = &resource_templates };
        }

        pub fn @"resources/read"(
            h: *Self,
            ctx: *mcp.Context,
            params: mcp.types.ReadResourceRequestParams,
        ) !mcp.types.ReadResourceResult {
            const uri = ResourceUri.parse(params.uri) orelse
                return ctx.fail(error.ResourceNotFound, "no resource '{s}'", .{params.uri});
            const json = switch (uri) {
                .issues => try resourceJson(ctx, try h.listIssues(ctx, .{})),
                .milestones => try resourceJson(ctx, try h.listMilestones(ctx, .{})),
                .issue => |id| try resourceJson(ctx, h.showIssue(
                    ctx,
                    .{ .id = id },
                ) catch |e| switch (e) {
                    error.IssueNotFound => return ctx.fail(
                        error.ResourceNotFound,
                        "no issue '{s}'",
                        .{id},
                    ),
                    else => return e,
                }),
            };
            const contents = try ctx.arena.alloc(mcp.types.ResourceContents, 1);
            contents[0] = .{
                .text = .{ .uri = params.uri, .mimeType = "application/json", .text = json },
            };
            return .{ .contents = contents };
        }

        /// `Repos` may have `fn watch(self, *mcp.Context, *Subscriptions) !void`,
        /// to start telling the client about changes on the first one.
        pub fn @"resources/subscribe"(
            h: *Self,
            ctx: *mcp.Context,
            params: mcp.types.SubscribeRequestParams,
        ) !mcp.types.EmptyResult {
            if (ResourceUri.parse(params.uri) == null)
                return ctx.fail(error.ResourceNotFound, "no resource '{s}'", .{params.uri});
            if (@hasDecl(Repos, "watch")) try h.repos.watch(ctx, &h.subscriptions);
            h.subscriptions.add(ctx.io, params.uri) catch |e| return switch (e) {
                error.TooManySubscriptions => ctx.fail(
                    e,
                    "at most {d} subscriptions",
                    .{Subscriptions.max},
                ),
                error.UriTooLong => ctx.fail(
                    error.ResourceNotFound,
                    "no resource '{s}'",
                    .{params.uri},
                ),
            };
            return .{};
        }

        pub fn @"resources/unsubscribe"(
            h: *Self,
            ctx: *mcp.Context,
            params: mcp.types.UnsubscribeRequestParams,
        ) mcp.types.EmptyResult {
            h.subscriptions.remove(ctx.io, params.uri);
            return .{};
        }

        fn resourceJson(ctx: *mcp.Context, value: anytype) ![]const u8 {
            return std.json.Stringify.valueAlloc(
                ctx.arena,
                value,
                .{ .emit_null_optional_fields = false },
            );
        }

        pub fn setIssueState(h: *Self, ctx: *mcp.Context, args: StateArgs) !StateChanged {
            const arena = ctx.arena;
            if (!core.isState(args.state)) return ctx.fail(
                error.InvalidValue,
                "state must be letters, digits, '-' and '_', not '{s}'",
                .{args.state},
            );
            const s = try h.open(ctx, args.repo);
            defer h.close(s);

            const ref = try resolveIssue(ctx, s, args.id);
            const state = core.State.parse(args.state);
            const expect = try expectVersion(ctx, s.backend, args.expect_version);
            if (args.comment) |comment_text| {
                const result = s.repo.edit(arena, ref.name, .{
                    .state = state,
                    .fixed_by = args.fixed_by,
                    .release = args.release,
                    .reason = args.reason,
                    .comment = comment_text,
                    .message = args.message,
                    .expect = expect,
                }, .{}) catch |e| return s.fail(ctx, e);
                const hex = result.tip.hex();
                return .{
                    .id = ref.id(),
                    .version = try arena.dupe(u8, hex.slice()),
                    .state = state.text(),
                };
            }
            const tip = s.repo.setState(arena, ref.name, .{
                .state = state,
                .message = args.message,
                .fixed_by = args.fixed_by,
                .release = args.release,
                .reason = args.reason,
                .expect = try expectVersion(ctx, s.backend, args.expect_version),
            }, .{}) catch |e| return s.fail(ctx, e);
            const hex = tip.tip.hex();
            return .{
                .id = ref.id(),
                .version = try arena.dupe(u8, hex.slice()),
                .state = state.text(),
            };
        }

        /// `Catalog.choose`, refusals as tool errors.
        fn chooseMilestone(
            ctx: *mcp.Context,
            s: Session,
            spec: Catalog.ChoiceSpec,
        ) !Catalog.Choice {
            const chosen = s.catalog().choose(ctx.arena, spec) catch |e| return s.fail(ctx, e);
            const r = switch (chosen) {
                .ok => |c| return c,
                .refused => |r| r,
            };
            const e = error.InvalidMilestone;
            return switch (r) {
                .id_with_name => ctx.fail(e, "give milestone or milestone_id, not both", .{}),
                .id_with_mode => |m| ctx.fail(
                    e,
                    "milestone_id doesn't go with milestone_mode {t}",
                    .{m},
                ),
                .explicit_needs_milestone => ctx.fail(
                    e,
                    "milestone_mode explicit needs a milestone",
                    .{},
                ),
                .explicit_needs_id => ctx.fail(
                    e,
                    "milestone_mode explicit needs a milestone (milestone_id)",
                    .{},
                ),
                .no_such_milestone => |k| ctx.fail(
                    e,
                    "no milestone '{s}' (see list_milestones with all)",
                    .{k},
                ),
                .retired_name => |m| ctx.fail(
                    e,
                    "milestone '{s}' is retired; name it by its ID ({s})",
                    .{ m.name, uuid.shortId(m.id) },
                ),
                .ambiguous_id => |ms| ctx.fail(
                    e,
                    "'{s}' matches several milestones: {s}",
                    .{ spec.id.?, try milestoneNames(ctx.arena, ms) },
                ),
                .not_open => |m| ctx.fail(e, "milestone '{s}' is {t}{s}", .{
                    m.name,
                    m.status,
                    if (m.status == .completed) "; reopen it first" else "",
                }),
                .no_open_named => |n| ctx.fail(e, "no open milestone is named '{s}'", .{n}),
                .ambiguous_name => |ms| ctx.fail(
                    e,
                    "several open milestones are named '{s}' ({s}); give milestone_id instead",
                    .{ ms[0].name, try milestoneNames(ctx.arena, ms) },
                ),
            };
        }

        fn milestoneNames(arena: Allocator, ms: []const issuez.milestone.Milestone) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            for (ms, 0..) |m, i| {
                if (i > 0) try out.appendSlice(arena, ", ");
                try out.print(arena, "{s} {s}", .{ uuid.shortId(m.id), m.name });
            }
            return out.items;
        }

        fn resolveIssue(ctx: *mcp.Context, s: Session, prefix: []const u8) !IssueRef {
            if (prefix.len == 0) return ctx.fail(error.IssueNotFound, "the issue ID is empty", .{});
            switch (s.repo.resolve(ctx.arena, prefix) catch |e| return s.fail(ctx, e)) {
                .one => |r| return r,
                .none => return ctx.fail(error.IssueNotFound, "no issue '{s}'", .{prefix}),
                .many => |matches| {
                    var ids: std.ArrayList(u8) = .empty;
                    for (matches, 0..) |m, i| {
                        if (i > 0) try ids.appendSlice(ctx.arena, ", ");
                        try ids.appendSlice(ctx.arena, uuid.shortId(m.id()));
                    }
                    return ctx.fail(
                        error.AmbiguousId,
                        "'{s}' matches several issues ({s}); give more of the ID",
                        .{ prefix, ids.items },
                    );
                },
            }
        }

        fn expectVersion(ctx: *mcp.Context, backend: *B, version: ?[]const u8) !?Oid {
            const v = version orelse return null;
            return Oid.parseHex(backend.objectFormat(), v) catch
                ctx.fail(
                    error.InvalidValue,
                    "expect_version must be a full commit ID (an issue's version), not '{s}'",
                    .{v},
                );
        }

        fn issueResult(
            arena: Allocator,
            s: Session,
            i: issuez.engine.Issue,
            proj: Projection,
        ) !Issue {
            const hex = i.tip.hex();
            var out: Issue = .{
                .id = try text(arena, i.id),
                .short_id = try text(arena, uuid.shortId(i.id)),
                .version = try arena.dupe(u8, hex.slice()),
                .title = try text(arena, i.title),
                .state = try text(arena, i.state.text()),
                .done = s.repo.isDone(i),
                .deleted = i.deleted,
                .labels = try texts(arena, i.labels),
                .assignee = try optionalText(
                    arena,
                    if (i.assignee) |a| a.email else i.field("Assignee"),
                ),
                .assignees = try assigneeEmails(arena, i),
                .number = i.number,
                .locked = i.locked,
                .lock_reason = try optionalText(arena, i.lock_reason),
                .ref = try optionalText(arena, i.ref),
                .priority = try optionalText(arena, i.field("Priority")),
                .milestone = try optionalText(arena, i.milestone),
                .milestone_id = try optionalText(arena, i.milestone_id),
                .parent = try optionalText(arena, i.parent),
                .blocked_by = try texts(arena, i.blocked_by),
                .start = if (i.start_date) |d|
                    try std.fmt.allocPrint(arena, "{f}", .{d})
                else
                    null,
                .due = if (i.due_date) |d| try std.fmt.allocPrint(arena, "{f}", .{d}) else null,
                .estimate_minutes = i.estimate_minutes,
                .workflow = try optionalText(arena, i.workflow),
                .author = try person(arena, i.author),
                .created = try time(arena, i.created, i.author.tz_offset_minutes),
                .updated = try time(arena, i.updated, i.updated_tz_offset_minutes),
                .fields = try fieldList(arena, i.fields),
                .conflicts = try conflicts(arena, i.conflicts),
                .attachments = i.attachments.len,
            };
            if (issuez.view.closure(i, s.repo.doneStates())) |c| {
                const commit = c.commit.hex();
                out.closed = .{
                    .author = try person(arena, c.at),
                    .author_id = try optionalText(arena, c.author_id),
                    .date = try time(arena, c.at.time, c.at.tz_offset_minutes),
                    .commit = try arena.dupe(u8, commit.slice()),
                };
            }
            if (proj.find(i.id)) |idx| {
                out.effective_milestone_id = try optionalText(arena, proj.milestone[idx]);
                out.effective_workflow = try optionalText(arena, proj.workflow(idx));
                if (proj.progress(idx)) |p| out.progress = .{
                    .closed = p.closed,
                    .total = p.total,
                };
                out.blocked = proj.activelyBlocked(idx);
                const problems = proj.problemsOf(idx);
                const list = try arena.alloc(Problem, problems.len);
                for (problems, list) |p, *o| o.* = .{
                    .kind = @tagName(p.kind),
                    .other = try optionalText(arena, p.other),
                    .description = try text(arena, try std.fmt.allocPrint(arena, "{f}", .{p})),
                };
                out.problems = list;
            }
            return out;
        }
    };
}

/// The server for `Repos`, with every tool.
pub fn Server(comptime Repos: type, comptime version: []const u8) type {
    const H = Handler(Repos);
    const read_only: mcp.types.ToolAnnotations = .{ .readOnlyHint = true, .openWorldHint = false };
    const write: mcp.types.ToolAnnotations = .{
        .readOnlyHint = false,
        .destructiveHint = false,
        .openWorldHint = false,
    };
    return mcp.Server(H, .{
        .name = "git-issue",
        .title = "git-native-issuez",
        .version = version,
        .instructions = instructions,
        .tools = .{
            .{
                .name = "list_issues",
                .title = "List issues",
                .description = "Lists issues, by default those that aren't done, newest first.",
                .annotations = read_only,
                .call = H.listIssues,
            },
            .{
                .name = "show_issue",
                .title = "Show an issue",
                .description = "An issue with its description and comments.",
                .annotations = read_only,
                .call = H.showIssue,
            },
            .{
                .name = "search_issues",
                .title = "Search issues",
                .description = "Issues whose title, fields, description or comments contain a " ++
                    "text, with the matching lines.",
                .annotations = read_only,
                .call = H.searchIssues,
            },
            .{
                .name = "list_milestones",
                .title = "List milestones",
                .description = "The milestone catalog with each milestone's progress (done and " ++
                    "total leaf issues).",
                .annotations = read_only,
                .call = H.listMilestones,
            },
            .{
                .name = "create_issue",
                .title = "Create an issue",
                .description = "Creates an issue.",
                .annotations = write,
                .call = H.createIssue,
            },
            .{
                .name = "comment_issue",
                .title = "Comment on an issue",
                .description = "Adds a comment to an issue.",
                .annotations = write,
                .call = H.commentIssue,
            },
            .{
                .name = "edit_issue",
                .title = "Edit an issue",
                .description = "Changes an issue's title, description or fields, in one commit. " ++
                    "Fields left out stay as they are.",
                .annotations = write,
                .call = H.editIssue,
            },
            .{
                .name = "react_issue",
                .title = "React to an issue or a comment",
                .description = "Adds an emoji reaction (or takes it back) on an issue or one of " ++
                    "its comments. Reacting the same way twice changes nothing.",
                .annotations = write,
                .call = H.reactIssue,
            },
            .{
                .name = "set_issue_state",
                .title = "Close, reopen or change an issue's state",
                .description = "Sets an issue's state: closed, open, or another state. Closing " ++
                    "fails while sub-issues are open.",
                .annotations = write,
                .call = H.setIssueState,
            },
        },
    });
}

const StateFilter = struct { state: ?core.State = null, given: bool = false };

fn stateFilter(ctx: *mcp.Context, value: ?[]const u8) !StateFilter {
    const v = value orelse return .{};
    if (std.mem.eql(u8, v, "all")) return .{ .given = true };
    if (!core.isState(v)) return ctx.fail(
        error.InvalidValue,
        "state must be open, closed, another state (letters, digits, '-' and '_') or all, not " ++
            "'{s}'",
        .{v},
    );
    return .{ .state = core.State.parse(v), .given = true };
}

/// `first`, then `rest`, each an email (or `<uuid> <email>`); empty ones
/// are left out.
fn people(
    ctx: *mcp.Context,
    first: ?[]const u8,
    rest: []const []const u8,
) ![]const issuez.format.fields.Assignee {
    var out: std.ArrayList(issuez.format.fields.Assignee) = .empty;
    const all = try std.mem.concat(ctx.arena, []const u8, &.{
        if (first) |f| &.{f} else &.{},
        rest,
    });
    for (all) |v| {
        if (v.len == 0) continue;
        try out.append(ctx.arena, issuez.format.fields.Assignee.parse(v) orelse return ctx.fail(
            error.InvalidValue,
            "an assignee is an email, not '{s}'",
            .{v},
        ));
    }
    return out.items;
}

fn duration(ctx: *mcp.Context, value: []const u8) !u32 {
    return issuez.format.fields.parseDuration(value) orelse ctx.fail(
        error.InvalidValue,
        "estimate must be minutes or a duration like 2h, 90m, 1h30m, not '{s}'",
        .{value},
    );
}

fn checkWorkflow(ctx: *mcp.Context, settings: issuez.Settings, state: []const u8) !void {
    settings.checkWorkflow(state) catch |e| switch (e) {
        error.InvalidWorkflowStates => return ctx.fail(
            e,
            "git config issue.workflowStates has '{s}'; " ++ issuez.settings.workflow_states_rule,
            .{settings.invalid_workflow_state.?},
        ),
        error.InvalidValue => return failWith(ctx, e, .{}, null),
        error.UnknownWorkflowState => return ctx.fail(
            e,
            "unknown workflow state '{s}' (one of: {s})",
            .{ state, try std.mem.join(ctx.arena, ", ", settings.workflow_states) },
        ),
    };
}

/// Reports a library error with what it means (`issuez.errors`), for the
/// model to act on. `detail` is git's own error output, if any. Before a
/// repo exists, `limits` are the ones `Repo.init` gives (`.{}`).
pub fn failWith(
    ctx: *mcp.Context,
    e: anyerror,
    limits: issuez.engine.Limits,
    detail: ?[]const u8,
) anyerror {
    if (e == error.OutOfMemory or e == error.Canceled) return e;
    const description: issuez.errors.Description = .{ .err = e, .limits = limits };
    if (!description.known()) return e;
    const msg: []const u8 = switch (e) {
        error.VersionMismatch => "the issue changed since expect_version; read it again",
        error.NothingToEdit => "nothing to change: give at least one field",
        error.MessageHasBody => "with description, message is only the commit subject: no blank " ++
            "lines",
        error.CorruptIssue => "issue data is damaged (run 'git issue fsck')",
        else => try std.fmt.allocPrint(ctx.arena, "{f}", .{description}),
    };
    const d = detail orelse return ctx.fail(e, "{s}", .{msg});
    return ctx.fail(e, "{s}; git says: {s}", .{ msg, d });
}

/// Text as a JSON string must be UTF-8; git allows any bytes. Others become
/// U+FFFD.
fn assigneeEmails(
    arena: Allocator,
    i: issuez.model.issue.Issue,
) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, i.assignees.len);
    for (i.assignees, out) |a, *o| o.* = try text(arena, a.email);
    return out;
}

fn text(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    return std.fmt.allocPrint(arena, "{f}", .{std.unicode.fmtUtf8(s)});
}

fn optionalText(arena: Allocator, s: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (s) |v| try text(arena, v) else null;
}

fn texts(arena: Allocator, list: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, list.len);
    for (list, out) |s, *o| o.* = try text(arena, s);
    return out;
}

fn hostFields(
    arena: Allocator,
    list: []const Field,
) Allocator.Error![]const issuez.engine.HostField {
    const out = try arena.alloc(issuez.engine.HostField, list.len);
    for (list, out) |f, *o| o.* = .{ .key = f.key, .value = f.value };
    return out;
}

/// The reactions on `target` (null: the issue itself).
fn reactionsOn(
    arena: Allocator,
    issue: issuez.engine.Issue,
    target: ?issuez.engine.Oid,
) Allocator.Error![]const Reaction {
    var out: std.ArrayList(Reaction) = .empty;
    for (issue.reactions) |r| {
        const same = if (r.target) |t| (target != null and t.eql(target.?)) else target == null;
        if (!same) continue;
        const users = try arena.alloc([]const u8, r.users.len);
        for (r.users, users) |u, *o| o.* = try text(arena, u.email);
        try out.append(arena, .{ .emoji = try text(arena, r.emoji), .users = users });
    }
    return out.items;
}

fn person(arena: Allocator, sig: issuez.engine.Signature) Allocator.Error!Person {
    return .{ .name = try text(arena, sig.name), .email = try text(arena, sig.email) };
}

fn time(arena: Allocator, t: i64, tz: i16) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{f}",
        .{issuez.format.time.IsoDate{ .time = t, .tz = tz, .rfc3339 = true }},
    );
}

fn fieldList(
    arena: Allocator,
    list: []const issuez.model.issue.Field,
) Allocator.Error![]const Field {
    const out = try arena.alloc(Field, list.len);
    for (list, out) |f, *o| o.* = .{
        .key = try text(arena, f.key),
        .value = try text(arena, f.value),
    };
    return out;
}

fn conflicts(
    arena: Allocator,
    list: []const issuez.model.issue.Conflict,
) Allocator.Error![]const Conflict {
    const out = try arena.alloc(Conflict, list.len);
    for (list, out) |c, *o| o.* = .{
        .field = switch (c.target) {
            .field => |k| try text(arena, k),
            else => try std.fmt.allocPrint(arena, "{f}", .{c.target}),
        },
        .kept = try text(arena, c.value),
        .lost = try text(arena, c.lost),
    };
    return out;
}

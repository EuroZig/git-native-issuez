//! The C API, described once. `gen.zig` writes `issuez.h` and
//! `issuez-api.json` from it; `lib.zig` exports every function declared
//! here, checking at compile time that the implementation has exactly the
//! declared type.
//!
//! The types below are the ABI types themselves: the implementation uses
//! them directly, so the header can't drift from the code.
//! A `///` comment on one of their fields or values is its documentation
//! in the header and the JSON; a `//` comment stays here.
//!
//! Records the library owns only ever grow at the end (callers read them
//! through pointers). Value types and caller-allocated types are frozen;
//! the latter carry `reserved` space instead.

const std = @import("std");

/// The library's; a git suffix (`-12-ga3e21cfa`) parses as its pre-release.
pub const version: std.SemanticVersion =
    std.SemanticVersion.parse(@import("issuez").version) catch unreachable;
/// Major in the high 16 bits, minor in the low 16.
pub const abi_version: u32 = (version.major << 16) | version.minor;

// ─── Basic types ───────────────────────────────────────────────────────

pub const Str = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,

    pub const c_name = "issuez_str";
    pub const type_kind: TypeKind = .value;

    pub fn of(s: []const u8) Str {
        return .{ .ptr = s.ptr, .len = s.len };
    }

    pub fn slice(s: Str) []const u8 {
        const p = s.ptr orelse return "";
        return p[0..s.len];
    }
};

pub const Oid = extern struct {
    /// 20 (SHA-1), 32 (SHA-256), 0: none
    len: u8 = 0,
    bytes: [32]u8 = @splat(0),

    pub const c_name = "issuez_oid";
    pub const type_kind: TypeKind = .value;
};

pub const Time = extern struct {
    unix_seconds: i64 = 0,
    /// east of UTC: +0130 is 90
    tz_offset_minutes: i16 = 0,

    pub const c_name = "issuez_time";
    pub const type_kind: TypeKind = .value;
};

pub const Date = extern struct {
    year: i16 = 0,
    /// 1..12
    month: u8 = 0,
    /// 1..31
    day: u8 = 0,

    pub const c_name = "issuez_date";
    pub const type_kind: TypeKind = .value;
};

pub const Person = extern struct {
    /// {NULL,0} for assignees, which store no name
    name: Str = .{},
    email: Str = .{},
    /// the host's stable identity, a UUID; {NULL,0} when none
    user_id: Str = .{},

    pub const c_name = "issuez_person";
    pub const type_kind: TypeKind = .value;
};

pub const Actor = extern struct {
    name: Str = .{},
    email: Str = .{},
    /// optional UUID: X-Author-Id on every commit the call writes
    user_id: Str = .{},
    /// NULL: now, in UTC
    at: ?*const Time = null,
    /// zero
    reserved: [4]u64 = @splat(0),

    pub const c_name = "issuez_actor";
    pub const type_kind: TypeKind = .input;
};

pub const Progress = extern struct {
    done: u32 = 0,
    total: u32 = 0,

    pub const c_name = "issuez_progress";
    pub const type_kind: TypeKind = .value;
};

// ─── Enums ─────────────────────────────────────────────────────────────

pub const Code = enum(c_int) {
    ok = 0,
    /// header/library mismatch
    e_abi = 1,
    /// NULL handle, malformed UUID or oid, ...
    e_invalid_argument,
    /// a value breaks a format rule; see problems
    e_invalid_value,
    /// over a limit (title bytes, labels, ...)
    e_limit,
    e_not_found,
    /// resolve: several matches
    e_ambiguous,
    /// an expected tip didn't match (HTTP 409)
    e_version_mismatch,
    /// a hierarchy or milestone rule refused it; see problems
    e_guard,
    /// still racing after the retry budget (limit cas_retries): final
    e_contended,
    /// the issue was purged; it can't come back
    e_purged,
    /// history that can't be read as an issue
    e_corrupt,
    /// sync: remote history was rewritten
    e_quarantined,
    /// push check refused at least one ref
    e_rejected,
    e_not_a_repository,
    /// git failed; see the error's git stderr
    e_git,
    /// git older than 2.30
    e_git_version,
    e_timeout,
    e_cancelled,
    /// fetch or push to a remote failed
    e_network,
    /// git-lfs missing or a transfer failed
    e_lfs,
    /// not in this build, or not possible here
    e_unsupported,
    e_nomem,
    /// a bug: please report
    e_internal,
    _,

    pub const c_name = "issuez_code";
    pub const c_prefix = "ISSUEZ_";
};

pub const Kind = enum(u32) {
    unknown = 0,
    issue,
    milestone,
    // `refs/attachments/<uuid>`, in push verdicts.
    attachments,
    // `refs/issuez-purged/<uuid>`, in push verdicts.
    tombstone,
    _,

    pub const c_name = "issuez_kind";
    pub const c_prefix = "ISSUEZ_KIND_";
};

pub const ProblemKind = enum(u32) {
    unknown = 0,
    /// a title or text that is blank
    empty,
    /// LF/CR in a single-line value
    newline,
    too_long,
    too_many,
    /// date, email, state slug, UUID, ...
    bad_format,
    /// text whose last paragraph would read as trailers
    trailer_body,
    unknown_workflow_state,
    /// e.g. a number that is already set
    read_only_field,
    /// target not valid in this op list
    unknown_target,
    /// e.g. ADD on a scalar
    bad_verb,
    /// the target's slot is empty
    missing_value,
    /// these ops can't share one commit
    incompatible,
    self_reference,
    cycle,
    too_deep,
    /// parent, blocker or milestone not there
    missing_target,
    deleted_target,
    /// closing or deleting with live sub-issues
    open_children,
    /// opening work under a closed parent
    closed_ancestor,
    /// completed or retired
    milestone_closed,
    milestone_open_work,
    duplicate_number,
    /// concurrent setters disagree (reads)
    conflict,
    /// a stored value that doesn't parse (reads)
    invalid_stored_value,
    /// an event whose comment hasn't arrived (reads)
    pending_event,
    /// fails fsck or can't be read (push check)
    invalid_history,
    /// a Format-Version other than 1 (push check)
    unsupported_format,
    /// the new tip doesn't contain the old (push check)
    non_fast_forward,
    /// a delete no purge allows (push check)
    ref_deleted,
    /// refs/issuez-* that never leave a clone (push check)
    local_ref,
    /// not a UUID under an issuez prefix (push check)
    bad_ref_name,
    /// a new commit not by the pusher (push check)
    author_mismatch,
    /// purged issue or text coming back (push check)
    purged,
    /// a purge without ISSUEZ_OPT_ALLOW_PURGE (push check)
    purge_not_allowed,
    /// a tombstone commit that doesn't read as one (push check)
    not_a_purge,
    /// an attachments commit that isn't derived (push check)
    not_derived,
    _,

    pub const c_name = "issuez_problem_kind";
    pub const c_prefix = "ISSUEZ_PROBLEM_";
};

pub const Field = enum(u32) {
    unknown = 0,
    title,
    description,
    comment,
    state,
    workflow_state,
    labels,
    assignees,
    priority,
    milestone,
    parent,
    blocked_by,
    start_date,
    due_date,
    estimate,
    number,
    locked,
    ref,
    deleted,
    fixed_by,
    release,
    reason,
    /// writes: ADD str = the image's bytes, name = its file name, id = its v4 UUID if the caller
    /// chooses it; REMOVE str = a UUID
    attachments,
    /// update: ADD str = an emoji, REMOVE str takes it back; alone, with REACTION_TARGET for a
    /// comment, EXPECT and SUBJECT
    reactions,
    /// milestones
    name,
    milestone_status,
    /// a host field (X-Forgejo-*) or another unknown trailer
    extra,
    /// timeline only: the lock's reason changed (the LOCKED change of the same commit carries it
    /// too)
    lock_reason,
    _,

    pub const c_name = "issuez_field";
    pub const c_prefix = "ISSUEZ_FIELD_";

    pub fn key(field: Field) []const u8 {
        return switch (field) {
            .title => "Title",
            .description => "Description",
            .comment => "Comment",
            .state => "State",
            .workflow_state => "X-Workflow-State",
            .labels => "Labels",
            .assignees => "Assignee",
            .priority => "Priority",
            .milestone => "X-Milestone-Id",
            .parent => "X-Parent",
            .blocked_by => "X-Blocked-By",
            .start_date => "X-Start-Date",
            .due_date => "X-Due-Date",
            .estimate => "X-Estimate-Minutes",
            .number => "X-Number",
            .locked => "X-Locked",
            .ref => "X-Ref",
            .deleted => "X-Deleted",
            .fixed_by => "Fixed-By",
            .release => "Release",
            .reason => "Reason",
            .attachments => "X-Attachment",
            .reactions => "X-Reaction",
            .name => "Name",
            .milestone_status => "X-Milestone-Status",
            .extra => "",
            .lock_reason => "X-Lock-Reason",
            .unknown, _ => "",
        };
    }
};

pub const Verb = enum(u32) {
    unknown = 0,
    /// scalar or option: the value
    set,
    /// scalar: none; set: empty; option: default
    clear,
    /// set or list option: one member
    add,
    /// set: one member
    remove,
    /// milestone: follow the parent's
    inherit,
    _,

    pub const c_name = "issuez_verb";
    pub const c_prefix = "ISSUEZ_OP_";
};

pub const Opt = enum(u32) {
    unknown = 0,

    /// writes: oid. Fail with VERSION_MISMATCH if the tip isn't this
    expect = 0x100,
    /// writes: str. Commit subject where the library picks one
    subject,
    /// writes: str. Provenance for imports; not an issue field
    original_author,
    /// writes: str
    original_id,
    /// update: oid. The write edits this comment instead: COMMENT SET is its new text, with
    /// ATTACHMENTS, EXPECT and SUBJECT
    edit_comment,
    /// update: num. Fail with VERSION_MISMATCH unless the text the write edits (the description
    /// with SET DESCRIPTION, the comment with EDIT_COMMENT) was edited exactly this often (its EDIT
    /// revisions): a form's version of the text, which other changes to the issue don't touch
    expect_edits,
    /// update: oid. The write hides this comment instead; only EXPECT and SUBJECT go with it
    delete_comment,
    /// update: oid. The write shows this hidden comment again; only EXPECT and SUBJECT go with it
    restore_comment,
    /// update: oid. The comment REACTIONS ADD or REMOVE is on; without it, the issue
    reaction_target,
    /// ADD str: a prepared attachment trailer; external storage only
    prepared_attachment,

    /// query: num 0 not done (default), 1 done, -1 any
    q_done = 0x200,
    /// query: num 0 (default), 1, -1
    q_deleted,
    /// query: ADD str; members OR
    q_state,
    /// query: ADD str; OR
    q_workflow_state,
    /// query: ADD str; must have all
    q_label,
    /// query: ADD str; must have none
    q_not_label,
    /// query: SET
    q_no_labels,
    /// query: ADD str, an email or user id, "" unassigned; OR
    q_assignee,
    /// query: ADD str; OR
    q_author,
    /// query: ADD num (issuez_priority); OR
    q_priority,
    /// query: ADD str, the effective milestone, "" none; OR
    q_milestone,
    /// query: SET str
    q_parent,
    /// query: SET num 1 actively blocked, 0 not
    q_blocked,
    /// query: SET num after, num2 before (unix; 0 open end)
    q_updated,
    /// query: SET str, a fixed string; num 1 ignores case
    q_text,
    /// query: SET num (issuez_sort), num2 1 ascending
    q_order,
    /// query: SET num (default 100)
    q_limit,
    /// query: SET str, a cursor from issuez_issue_list_next_cursor
    q_after,

    /// open: str. Default "git" from PATH
    git_path = 0x300,
    /// open: SET name=str; CLEAR without name starts empty. Default: the process environment
    env,
    /// open: person (name, email). Default: git's identity
    committer,
    /// open: ADD str; overrides git config issue.doneStates. settings: ADD str writes the states
    /// given; CLEAR unsets the key (the defaults)
    done_state,
    /// open: ADD str; overrides issue.workflowStates
    workflow_state,
    /// open: ADD str; one "scope/x" label per issue: adding one takes the others off, two in one
    /// write are refused
    exclusive_scope,
    /// open: ADD str; allowed EXTRA keys (default "X-Forgejo-")
    extra_prefix,
    /// open: num; concurrent git sessions (default 4)
    pool_size,
    /// open: num
    timeout_local_ms,
    /// open: num
    timeout_network_ms,
    /// open: name ("max_labels", ...), num
    limit,
    /// open: num; issues kept loaded for queries (default 10000, 0 off)
    cache_issues,
    /// open: num 0/1 (default 1). 0: the caller keeps attachment bytes (a host's LFS store); writes
    /// store none and need no git-lfs
    attachment_store,

    /// sync: num 0/1 (default 1)
    sync_push = 0x400,
    /// sync: num 0/1 (default 1); 0 pushes refs/attachments but uploads no LFS bytes
    sync_attachments,

    /// push check: person; its user_id counts as pusher_user_id
    pusher = 0x500,
    /// push check: ADD str, the pusher's other verified emails
    pusher_email,
    /// push check: num (issuez_author_policy)
    author_policy,
    /// push check: num 0/1 (default 0)
    allow_numbers,
    /// push check: str, the quarantine's GIT_OBJECT_DIRECTORY
    object_dir,
    /// push check: str, GIT_ALTERNATE_OBJECT_DIRECTORIES
    alternate_object_dirs,
    /// push check: num 0/1 (default 0), the pusher may push tombstones
    allow_purge,
    /// push check: ADD str, the pusher's UUIDs: under the author policy, a new commit's X-Author-Id
    /// must be one
    pusher_user_id,
    _,

    pub const c_name = "issuez_opt";
    pub const c_prefix = "ISSUEZ_OPT_";
};

pub const OpList = enum(u32) {
    unknown = 0,
    issue_create,
    issue_update,
    milestone_create,
    milestone_update,
    query,
    open,
    sync,
    push_check,
    settings,
    _,

    pub const c_name = "issuez_op_list";
    pub const c_prefix = "ISSUEZ_LIST_";
};

pub const LogLevel = enum(u32) {
    off = 0,
    @"error",
    warn,
    info,
    /// one event per git request
    debug,
    trace,
    _,

    pub const c_name = "issuez_log_level";
    pub const c_prefix = "ISSUEZ_LOG_";
};

pub const ChangeKind = enum(u32) {
    unknown = 0,
    created,
    updated,
    /// the ref is gone (purge, or another tool)
    removed,
    _,

    pub const c_name = "issuez_change_kind";
    pub const c_prefix = "ISSUEZ_CHANGE_";
};

pub const State = enum(u32) {
    unknown = 0,
    open,
    closed,
    /// see issuez_issue_info.state_name
    other,
    _,

    pub const c_name = "issuez_state";
    pub const c_prefix = "ISSUEZ_STATE_";
};

pub const Priority = enum(u32) {
    /// also: not set
    unknown = 0,
    low,
    medium,
    high,
    critical,
    _,

    pub const c_name = "issuez_priority";
    pub const c_prefix = "ISSUEZ_PRIORITY_";
};

pub const EntryKind = enum(u32) {
    unknown = 0,
    created,
    /// comment points at it; may carry changes too
    comment,
    /// field changes only
    update,
    description_edit,
    comment_edit,
    comment_delete,
    comment_restore,
    reaction,
    /// changes only where it resolved a conflict
    merge,
    _,

    pub const c_name = "issuez_entry_kind";
    pub const c_prefix = "ISSUEZ_ENTRY_";
};

pub const Sort = enum(u32) {
    unknown = 0,
    created,
    updated,
    number,
    priority,
    due_date,
    comments,
    state,
    _,

    pub const c_name = "issuez_sort";
    pub const c_prefix = "ISSUEZ_SORT_";
};

pub const MilestoneStatus = enum(u32) {
    unknown = 0,
    open,
    completed,
    retired,
    _,

    pub const c_name = "issuez_milestone_status";
    pub const c_prefix = "ISSUEZ_MILESTONE_";
};

pub const QuarantineReason = enum(u32) {
    // It no longer applies; the next merge clears it.
    /// no longer applies; the next merge clears it
    unknown = 0,
    /// the remote issue shares no history with the local one
    unrelated_history,
    /// the remote history was rewritten since the last merge
    rewound,
    /// the remote issue fails the integrity checks
    invalid_issue,
    _,

    pub const c_name = "issuez_quarantine_reason";
    pub const c_prefix = "ISSUEZ_QUARANTINE_";
};

pub const QuarantineChoice = enum(u32) {
    unknown = 0,
    /// keep ours and stop reporting theirs
    keep_local,
    /// take theirs; the replaced version is kept
    take_remote,
    _,

    pub const c_name = "issuez_quarantine_choice";
    pub const c_prefix = "ISSUEZ_CHOICE_";
};

pub const Quarantined = extern struct {
    /// issuez_kind: ISSUE or MILESTONE
    kind: u32,
    id: Str,
    /// the local title, or the remote one when it only exists there
    title: Str,
    /// the refused remote version
    remote_tip: Oid,
    /// issuez_quarantine_reason
    reason: u32,
    /// acknowledged (issuez_quarantine_resolve, ISSUEZ_CHOICE_KEEP_LOCAL)
    kept_local: bool,

    pub const c_name = "issuez_quarantined";
    pub const type_kind: TypeKind = .record;
};

pub const FsckKind = enum(u32) {
    unknown = 0,
    // Fails one of upstream fsck's checks: an error.
    /// error: fails one of upstream fsck's checks
    integrity,
    /// note: an X-Milestone-Status no reader takes; it reads as open
    milestone_status,
    /// note: an attachment trailer the history ignores
    attachment_trailer,
    /// note: an attachment's bytes aren't in this repository
    attachment_missing,
    // An error.
    /// error: an attachment's stored bytes don't match it
    attachment_corrupt,
    /// note: refs/attachments/<id> is missing or stale (repair rewrites it)
    derived_ref,
    /// refs/attachments/<id> was rewritten
    repaired,
    // An error.
    /// error: checking or repairing attachments failed
    attachments_failed,
    /// note: without git-lfs the bytes weren't checked
    bytes_unchecked,
    /// note: stored objects no issue references (failed writes)
    orphans,
    /// note: remote versions a merge refused, subject the remote
    quarantined,
    /// note: a hierarchy or blocker problem across issues
    projection,
    _,

    pub const c_name = "issuez_fsck_kind";
    pub const c_prefix = "ISSUEZ_FSCK_";
};

pub const FsckFinding = extern struct {
    /// issuez_fsck_kind
    kind: u32,
    /// counted as an error; notes aren't
    is_error: bool,
    /// issuez_kind of subject; UNKNOWN for the repository
    subject_kind: u32,
    /// an issue or milestone UUID, a remote; {NULL,0} for the repository
    subject: Str,
    /// one sentence without a front end's commands
    message: Str,

    pub const c_name = "issuez_fsck_finding";
    pub const type_kind: TypeKind = .record;
};

pub const RemoteSetup = extern struct {
    /// the refspecs were added now; false when they were there
    configured: bool = false,
    /// upstream's forced refspec was taken out (ISSUEZ_REMOTE_FLAG_FIX_UNSAFE)
    removed_unsafe: bool = false,
    /// the remote still has upstream's forced refspec: a plain git fetch can overwrite local issue
    /// refs
    unsafe: bool = false,
    /// the library fills it; room to grow
    reserved: [2]u64 = @splat(0),

    pub const c_name = "issuez_remote_setup";
    pub const type_kind: TypeKind = .value;
};

pub const SearchHit = extern struct {
    issue_id: Str,
    line: Str,

    pub const c_name = "issuez_search_hit";
    pub const type_kind: TypeKind = .record;
};

pub const SearchFlag = enum(u32) {
    none = 0,
    /// bit: ASCII case-insensitive
    ignore_case = 1,
    _,

    pub const c_name = "issuez_search_flag";
    pub const c_prefix = "ISSUEZ_SEARCH_FLAG_";
};

pub const ShortId = extern struct {
    /// the full UUID
    id: Str,
    /// the shortest prefix no other issue's UUID starts with
    prefix: Str,

    pub const c_name = "issuez_short_id";
    pub const type_kind: TypeKind = .record;
};

pub const JsonFlag = enum(u32) {
    none = 0,
    /// bit: add the description, comments and history
    full = 1,
    _,

    pub const c_name = "issuez_json_flag";
    pub const c_prefix = "ISSUEZ_JSON_FLAG_";
};

pub const LoadFlag = enum(u32) {
    none = 0,
    /// bit: a missing or damaged issue fails the call
    strict = 1,
    _,

    pub const c_name = "issuez_load_flag";
    pub const c_prefix = "ISSUEZ_LOAD_FLAG_";
};

pub const FsckFlag = enum(u32) {
    none = 0,
    /// bit: rewrite missing or stale derived attachment refs (needs the attachment store); nothing
    /// else is written
    repair = 1,
    _,

    pub const c_name = "issuez_fsck_flag";
    pub const c_prefix = "ISSUEZ_FSCK_FLAG_";
};

pub const RemoteFlag = enum(u32) {
    none = 0,
    /// bit: take out upstream's forced refspec
    fix_unsafe = 1,
    _,

    pub const c_name = "issuez_remote_flag";
    pub const c_prefix = "ISSUEZ_REMOTE_FLAG_";
};

pub const SyncOutcome = enum(u32) {
    unknown = 0,
    up_to_date,
    /// came from the remote
    new,
    fast_forward,
    merged,
    /// ours went to the remote (also new local issues)
    pushed,
    /// remote history rewritten; see issuez_quarantine_resolve
    quarantined,
    /// not reported in this version: a push that can't land fails the call
    failed,
    /// purged by a tombstone; the push deletes the remote's copy
    purged,
    _,

    pub const c_name = "issuez_sync_outcome";
    pub const c_prefix = "ISSUEZ_SYNC_";
};

pub const AuthorPolicy = enum(u32) {
    unknown = 0,
    /// default
    any,
    /// accept, flag commits not by the pusher
    warn,
    /// reject them
    enforce,
    _,

    pub const c_name = "issuez_author_policy";
    pub const c_prefix = "ISSUEZ_AUTHOR_";
};

pub const PushAction = enum(u32) {
    unknown = 0,
    /// not an issuez ref: the host's business
    ignored,
    create,
    fast_forward,
    /// rejected unless a tombstone allows it (ISSUEZ_OPT_ALLOW_PURGE)
    rewrite,
    /// rejected unless a tombstone allows it (ISSUEZ_OPT_ALLOW_PURGE)
    delete,
    _,

    pub const c_name = "issuez_push_action";
    pub const c_prefix = "ISSUEZ_PUSH_";
};

// ─── Handles ───────────────────────────────────────────────────────────

fn Handle(comptime name: []const u8) type {
    return opaque {
        pub const c_name = name;
    };
}

pub const Error = Handle("issuez_error");
pub const Problems = Handle("issuez_problems");
pub const Cancel = Handle("issuez_cancel");
pub const Repo = Handle("issuez_repo");
pub const Matches = Handle("issuez_matches");
pub const Bytes = Handle("issuez_bytes");
pub const PreparedAttachment = Handle("issuez_prepared_attachment");
pub const Watch = Handle("issuez_watch");
pub const Store = Handle("issuez_store");
pub const FsckReport = Handle("issuez_fsck_report");
pub const SyncStatus = Handle("issuez_sync_status");
pub const SearchHits = Handle("issuez_search_hits");
pub const LabelCounts = Handle("issuez_label_counts");
pub const People = Handle("issuez_people");
pub const ShortIds = Handle("issuez_short_ids");
pub const Snapshot = Handle("issuez_snapshot");
pub const Diff = Handle("issuez_diff");
pub const Issue = Handle("issuez_issue");
pub const IssueList = Handle("issuez_issue_list");
pub const Write = Handle("issuez_write");
pub const Milestone = Handle("issuez_milestone");
pub const MilestoneList = Handle("issuez_milestone_list");
pub const Projection = Handle("issuez_projection");
pub const SyncReport = Handle("issuez_sync_report");
pub const PushVerdicts = Handle("issuez_push_verdicts");
pub const PurgeResult = Handle("issuez_purge_result");

// ─── Records ───────────────────────────────────────────────────────────

pub const TypeKind = enum {
    /// Frozen: copied freely, used in both directions.
    value,
    /// Owned by the library; grows only at the end.
    record,
    /// Allocated by the caller; frozen, with reserved space.
    input,
};

pub const Problem = extern struct {
    /// issuez_problem_kind
    kind: u32,
    /// issuez_field: what the caller should highlight
    field: u32,
    /// trailer key, for ISSUEZ_FIELD_EXTRA
    key: Str,
    /// the offending value, when there is one
    value: Str,
    /// the other issue or milestone UUID involved
    subject: Str,
    /// human-readable
    message: Str,
    /// the op that caused it; -1 when not from an op
    op_index: i64,

    pub const c_name = "issuez_problem";
    pub const type_kind: TypeKind = .record;
};

pub const LogEvent = extern struct {
    /// issuez_log_level
    level: u32,
    /// "issue.update", "git.cat-file", "sync"
    operation: Str,
    message: Str,
    /// {NULL,0} when not about a repo
    repo_path: Str,
    /// issue/milestone UUID or ref, if any
    subject: Str,
    /// -1 when not a timed step
    duration_ns: i64,
    /// retry number, 0 for the first
    attempt: u32,

    pub const c_name = "issuez_log_event";
    pub const type_kind: TypeKind = .record;
};

pub const LogFn = ?*const fn (userdata: ?*anyopaque, event: *const LogEvent) callconv(.c) void;

pub const WatchFn = ?*const fn (userdata: ?*anyopaque, changes: u32) callconv(.c) void;

pub const WatchChange = enum(u32) {
    none = 0,
    /// bit: issue, milestone or attachment refs moved: read them again (issuez_snapshot_take and
    /// issuez_diff_new say what)
    refs = 1,
    /// bit: the repository's config changed, which has the issue settings
    config = 2,
    _,

    pub const c_name = "issuez_watch_change";
    pub const c_prefix = "ISSUEZ_WATCH_";
};

pub const DiffEntry = extern struct {
    /// issuez_kind
    kind: u32,
    /// issuez_change_kind
    change: u32,
    id: Str,
    /// len 0 when created
    old_tip: Oid,
    /// len 0 when removed
    new_tip: Oid,

    pub const c_name = "issuez_diff_entry";
    pub const type_kind: TypeKind = .record;
};

pub const IssueInfo = extern struct {
    id: Str,
    /// pass as expect
    tip: Oid,
    /// false: no number yet, and number is 0
    has_number: bool,
    number: u64,
    format_version: Str,
    commit_count: u32,
    title: Str,
    description: Str,
    author: ?*const Person,
    created: Time,
    updated: Time,
    /// issuez_state
    state: u32,
    /// "open", "closed", "wontfix", ...
    state_name: Str,
    /// closed or one of the repo's done states
    is_done: bool,
    /// defaulted for open issues; {NULL,0} for done ones
    workflow_state: Str,
    /// who last made the issue done; NULL while it isn't
    closed_by: ?*const Person,
    /// when closed_by did; zero while it isn't done
    closed_at: Time,
    fixed_by: Str,
    release: Str,
    reason: Str,
    is_deleted: bool,
    is_locked: bool,
    lock_reason: Str,
    /// issuez_priority
    priority: u32,
    /// direct only; the effective one (through parents) is a projection answer
    milestone_id: Str,
    parent_id: Str,
    /// zero: none
    start_date: Date,
    /// zero: none
    due_date: Date,
    /// false: no estimate, and estimate_minutes is 0; true with 0 is an estimate of 0
    has_estimate_minutes: bool,
    estimate_minutes: u32,
    /// a branch or tag
    ref: Str,
    /// an imported issue's author in the other tracker; {NULL,0} otherwise
    original_author: Str,
    original_id: Str,
    /// issuez_issue_load_since's since isn't in the history; false from other loads
    rewritten: bool,

    pub const c_name = "issuez_issue_info";
    pub const type_kind: TypeKind = .record;
};

pub const MilestoneInfo = extern struct {
    id: Str,
    tip: Oid,
    name: Str,
    description: Str,
    /// issuez_milestone_status
    status: u32,
    /// zero: none
    due_date: Date,
    created: Time,
    /// of its latest commit
    updated: Time,
    /// false: no commit after the root set the status, and status_changed is zero
    has_status_changed: bool,
    /// when the status it has was set, by the last commit after the root that set it: a completed
    /// milestone's closing time
    status_changed: Time,
    /// who created it
    author: ?*const Person,

    pub const c_name = "issuez_milestone_info";
    pub const type_kind: TypeKind = .record;
};

pub const Reaction = extern struct {
    /// ":+1:" or a unicode emoji, as written
    emoji: Str,
    /// see issuez_reaction_user_at
    user_count: usize,

    pub const c_name = "issuez_reaction";
    pub const type_kind: TypeKind = .record;
};

pub const Comment = extern struct {
    /// full commit OID: the comment's stable ID
    id: Oid,
    author: ?*const Person,
    created: Time,
    /// of the latest edit; = created if none
    updated: Time,
    /// current text, trailers stripped
    text: Str,
    edited: bool,
    /// text still readable, for moderators
    deleted: bool,
    /// see issuez_comment_attachment_at
    attachment_count: usize,
    /// imported: its author in the other tracker; {NULL,0} otherwise
    original_author: Str,
    /// imported: its ID in the other tracker
    original_id: Str,
    /// a purge took its text, attachments and origin; its fields stay
    purged: bool,

    pub const c_name = "issuez_comment";
    pub const type_kind: TypeKind = .record;
};

/// Metadata prepared from validated image bytes. All strings belong to its handle.
pub const AttachmentSpec = extern struct {
    id: Str,
    media_type: Str,
    size: u64,
    sha256: Str,
    name: Str,

    pub const c_name = "issuez_attachment_spec";
    pub const type_kind: TypeKind = .record;
};

pub const Attachment = extern struct {
    /// v4 UUID; links in text are attachment:<id>
    id: Str,
    /// image/png, image/jpeg or image/webp
    media_type: Str,
    size: u64,
    /// 64 lowercase hex digits: the LFS object ID
    sha256: Str,
    name: Str,
    /// the commit that added it: a comment, the root, an edit
    added_in: Oid,
    added_by: ?*const Person,
    /// hidden by X-Attachment-Removed; its bytes are still referenced
    removed: bool,
    /// the comment it belongs to: added_in's comment, or the comment it edits; zero for the
    /// description's (the root, a description edit)
    comment: Oid = .{},
    /// when added_in was written
    at: Time = .{},

    pub const c_name = "issuez_attachment";
    pub const type_kind: TypeKind = .record;
};

pub const Change = extern struct {
    /// issuez_field; one change per field and member, whichever trailers said it
    field: u32,
    /// trailer key
    key: Str,
    /// issuez_verb: SET, CLEAR, ADD or REMOVE
    op: u32,
    /// canonical text: "2026-12-01", "high", a UUID, ...; the value before, also when the trailer
    /// didn't say it (a first TITLE: the root's subject, a first STATE: "open")
    old_value: Str,
    /// a cleared TITLE: the root's subject again
    new_value: Str,
    /// ASSIGNEES: the member removed, parsed; NULL otherwise
    old_person: ?*const Person = null,
    /// ASSIGNEES: the member added, parsed; NULL otherwise
    new_person: ?*const Person = null,
    /// START_DATE, DUE_DATE: parsed; zero: none
    old_date: Date = .{},
    /// START_DATE, DUE_DATE: parsed; zero: none
    new_date: Date = .{},
    /// STATE: whether the old state is done, by the repo's done states
    old_done: bool = false,
    /// STATE: whether the new state is done
    new_done: bool = false,
    /// LOCKED: the lock's reason as of this commit
    reason: Str = .{},

    pub const c_name = "issuez_change";
    pub const type_kind: TypeKind = .record;
};

pub const Entry = extern struct {
    /// issuez_entry_kind
    kind: u32,
    commit: Oid,
    author: ?*const Person,
    at: Time,
    /// COMMENT; the target for COMMENT_*; NULL otherwise
    comment: ?*const Comment,
    /// see issuez_entry_change_at
    change_count: usize,
    /// not reachable from issuez_issue_load_since's since; true elsewhere
    is_new: bool,

    pub const c_name = "issuez_entry";
    pub const type_kind: TypeKind = .record;
};

pub const RevisionKind = enum(u32) {
    unknown = 0,
    /// the comment itself, or the issue's root
    original,
    edit,
    /// text: what it hid
    delete,
    /// text: what it showed again
    restore,
    _,

    pub const c_name = "issuez_revision_kind";
    pub const c_prefix = "ISSUEZ_REVISION_";
};

pub const Revision = extern struct {
    /// the commit that wrote it: the comment, the root, or an event
    commit: Oid,
    author: ?*const Person,
    at: Time,
    /// issuez_revision_kind
    kind: u32,
    /// the whole text after it
    text: Str,

    pub const c_name = "issuez_revision";
    pub const type_kind: TypeKind = .record;
};

pub const Op = extern struct {
    /// issuez_verb
    verb: u32 = 0,
    /// issuez_field or issuez_opt
    target: u32 = 0,
    /// EXTRA key, ENV variable, LIMIT name, ATTACHMENTS file name
    name: Str = .{},
    str: Str = .{},
    /// integers, enums, flags (0/1), unix seconds
    num: i64 = 0,
    num2: i64 = 0,
    date: Date = .{},
    oid: Oid = .{},
    person: Person = .{},
    /// ADD ATTACHMENTS: the v4 UUID to give it (empty: one is picked)
    id: Str = .{},
    /// zero
    reserved: [2]u64 = @splat(0),

    pub const c_name = "issuez_op";
    pub const type_kind: TypeKind = .input;
};

pub const SyncItem = extern struct {
    /// issuez_kind
    kind: u32,
    id: Str,
    /// issuez_sync_outcome
    outcome: u32,
    /// after the sync
    local_tip: Oid,
    remote_tip: Oid,
    /// for QUARANTINED and FAILED
    reason: Str,

    pub const c_name = "issuez_sync_item";
    pub const type_kind: TypeKind = .record;
};

pub const RefUpdate = extern struct {
    ref: Str = .{},
    /// len 0 for a create
    old_oid: Oid = .{},
    /// len 0 for a delete
    new_oid: Oid = .{},
    /// zero
    reserved: [2]u64 = @splat(0),

    pub const c_name = "issuez_ref_update";
    pub const type_kind: TypeKind = .input;
};

pub const LabelCount = extern struct {
    name: Str,
    /// of them not done
    open: u32,
    /// issues carrying it
    total: u32,

    pub const c_name = "issuez_label_count";
    pub const type_kind: TypeKind = .record;
};

pub const KnownPerson = extern struct {
    /// the latest name they wrote under (empty for assignees only), email, user_id
    person: Person,
    /// issues they opened
    authored: u32,
    /// issues they are assigned
    assigned: u32,

    pub const c_name = "issuez_known_person";
    pub const type_kind: TypeKind = .record;
};

pub const PushVerdict = extern struct {
    ref: Str,
    /// issuez_kind; ISSUEZ_KIND_UNKNOWN for other refs
    kind: u32,
    id: Str,
    /// issuez_push_action
    action: u32,
    accept: bool,
    /// why not, or what to flag (author mismatch under WARN)
    problems: ?*const Problems,
    /// a new issue without one
    needs_number: bool,
    /// adds commits to a locked issue
    touches_locked: bool,
    /// new commits
    commit_count: usize,
    /// issues: the new commits as timeline entries, see issuez_push_verdict_entry_at; 0 for other
    /// kinds
    entry_count: usize,
    /// issues: who opened it (the pusher's own issue or not); NULL otherwise
    issue_author: ?*const Person = null,
    /// issues: attachments the new commits add, see issuez_push_verdict_attachment_at
    attachment_count: usize = 0,

    pub const c_name = "issuez_push_verdict";
    pub const type_kind: TypeKind = .record;
};

// ─── The header, in order ──────────────────────────────────────────────

pub const Func = struct {
    name: []const u8,
    T: type,
    params: []const []const u8,
    doc: []const u8 = "",
};

pub const Helper = struct {
    name: []const u8 = "",
    verb: Verb = .unknown,
    /// A Field or Opt tag name; "opt:<name>" for an Opt that shares a
    /// Field's name.
    target: []const u8 = "",
    slot: enum {
        str,
        num,
        date,
        oid,
        person,
        none,
        name_str,
        committer,
        /// num and a str (a lock and its reason).
        num_str,
        /// str and num (a text query and its case).
        str_num,
        /// num and num2.
        num_num2,
        /// name and num (a limit).
        name_num,
        /// id, name and the bytes as str (an attachment).
        attachment,
    } = .none,
    /// The C type and name of the num slot's parameter: an enum's type,
    /// `bool` for a 0/1 flag.
    num_type: []const u8 = "int64_t",
    param: []const u8 = "v",
    /// The same for num2 (or the str of num_str and str_num).
    num2_type: []const u8 = "int64_t",
    param2: []const u8 = "v2",
};

/// `issuez_q_<query option>`, `issuez_<verb>_<field>` (one label: ADD and
/// REMOVE take the singular) or `issuez_opt_<option>`.
fn helperName(comptime verb: Verb, comptime target: []const u8) []const u8 {
    if (std.mem.startsWith(u8, target, "q_")) return "issuez_" ++ target;
    if (std.mem.startsWith(u8, target, "opt:")) return "issuez_opt_" ++ target[4..];
    if (!@hasField(Field, target)) return "issuez_opt_" ++ target;
    const one = (verb == .add or verb == .remove) and target[target.len - 1] == 's';
    return "issuez_" ++ @tagName(verb) ++ "_" ++ if (one) target[0 .. target.len - 1] else target;
}

/// A helper's row. `more` has its parameters where they aren't the default,
/// and its name where it doesn't follow from the target.
fn h(
    comptime verb: Verb,
    comptime target: []const u8,
    comptime slot: @FieldType(Helper, "slot"),
    comptime more: Helper,
) Helper {
    var row = more;
    row.verb = verb;
    row.target = target;
    row.slot = slot;
    if (row.name.len == 0) row.name = helperName(verb, target);
    return row;
}

pub const Item = union(enum) {
    /// A banner and an optional comment below it.
    section: struct { []const u8, []const u8 },
    /// A comment block.
    prose: []const u8,
    /// C text emitted as is.
    raw: []const u8,
    handles: []const type,
    type: type,
    func: Func,
    helpers: []const Helper,
};

fn f(
    comptime name: []const u8,
    comptime T: type,
    comptime params: []const []const u8,
    comptime doc: []const u8,
) Item {
    return .{ .func = .{ .name = name, .T = T, .params = params, .doc = doc } };
}

const Err = ?*?*Error;
const Can = ?*Cancel;
const OpsPtr = ?[*]const Op;

pub const preamble =
    \\issuez.h - C API of git-native-issuez.
    \\
    \\Issues stored in git (refs/issues/<uuid>), compatible with
    \\git-native-issue format 1. Meant to be wrapped by bindings (Go, Rust,
    \\Python, Node) and usable from plain C.
    \\
    \\Generated from src/capi/api.zig by src/capi/gen.zig: don't edit.
    \\
    \\--------------------------------- Conventions ---------------------------------
    \\
    \\Status codes
    \\  Fallible functions return issuez_code: ISSUEZ_OK (0) or an
    \\  ISSUEZ_E_* code, so a switch over it can warn on a missing case.
    \\  Their last parameter is `issuez_error **err`. Pass NULL to ignore the
    \\  details; otherwise *err is set on failure (free with issuez_error_free)
    \\  and left untouched on success. Accessors on loaded objects never fail
    \\  and take no err.
    \\
    \\Ownership
    \\  - Every handle a function hands back through an out parameter
    \\    (`issuez_x **out`) is owned by the caller: free it with that type's
    \\    issuez_x_free (NULL is a no-op). The exceptions say so: the repo is
    \\    closed with issuez_repo_close, a watch ended with issuez_watch_stop.
    \\  - Everything an accessor returns (strings, `const T *` records, list
    \\    items) is borrowed from the handle it came from and lives until that
    \\    handle is freed.
    \\  - Handles that need the repo keep it alive, so handles may be freed in
    \\    any order, from any thread; issuez_repo_close drops the caller's
    \\    reference.
    \\
    \\Types
    \\  - Value types (issuez_str, issuez_oid, issuez_time, issuez_date,
    \\    issuez_person, issuez_progress) are frozen and copied freely.
    \\  - Records the library returns (issue and milestone info, comments,
    \\    entries, problems, ...) only ever grow at the end: read them through
    \\    the pointer, never copy one by value, never allocate one. Nested lists
    \\    are read with *_count and *_at accessors, never as arrays of records.
    \\  - Inputs the caller allocates (issuez_op, issuez_actor,
    \\    issuez_ref_update) are frozen and carry reserved space: zero it.
    \\  - Enum-valued fields of structs are uint32_t; the enums give the
    \\    values. Every enum has *_UNKNOWN = 0 (or OFF/OK) and may gain values
    \\    in minor versions: handle unknown values.
    \\
    \\Strings
    \\  issuez_str is ptr+len, UTF-8 (not validated where git doesn't), and
    \\  every string the library returns is also NUL-terminated (ptr[len] ==
    \\  0). An absent optional string is {NULL, 0}; an empty one is {"", 0}.
    \\  Inputs are read during the call only and never retained; for inputs
    \\  {NULL,0} and {"",0} mean the same.
    \\
    \\Writes
    \\  A write is one commit: a comment, a state change (with FIXED_BY,
    \\  RELEASE, REASON) and field edits together. A delete or restore is a
    \\  commit of its own, and a description edit can't carry a comment;
    \\  those combinations fail with ISSUEZ_E_INVALID_VALUE, problem INCOMPATIBLE.
    \\
    \\Op lists (writes, queries, options)
    \\  Calls taking several optional values take an array of issuez_op: a
    \\  verb (SET, CLEAR, ADD, REMOVE, INHERIT), a target (an issuez_field or
    \\  an issuez_opt) and the value in the slot the target names (str, num,
    \\  num2, date, oid, person, name). There are no builder objects: a
    \\  static inline helper builds each op (issuez_set_title, issuez_add_label,
    \\  issuez_q_done, issuez_opt_git_path, ...). Use the helpers; the struct
    \\  is the ABI under them. examples/c/quickstart.c shows the idiom.
    \\  - Ops apply in order; a later op on the same scalar wins. A set is
    \\    replaced by CLEAR followed by ADDs.
    \\  - Unused slots must be zero: start from ISSUEZ_OP_INIT or a helper.
    \\  - Nothing is checked until the call, which then reports every problem
    \\    at once (ISSUEZ_E_INVALID_VALUE), each with the index of its op.
    \\    issuez_ops_validate checks the format alone, without a repo.
    \\
    \\Names
    \\  issuez_<handle>_<verb>, the verb saying what a call does:
    \\  - _open, _close        the repo (issuez_repo_open, issuez_repo_close)
    \\  - _new                 a handle built from what the call is given
    \\                         (issuez_cancel_new, issuez_store_new, issuez_diff_new)
    \\  - _load*               an issue or milestone, read from git
    \\  - _info_of             a handle's single values, one record
    \\                         (issuez_issue_info_of, issuez_milestone_info_of)
    \\  - _take                a value read off the repo into a handle
    \\                         (issuez_snapshot_take, issuez_label_counts_take)
    \\  - plain verbs          operations (issuez_search, issuez_sync,
    \\                         issuez_fsck, issuez_issue_update)
    \\  - _start, _stop        a watch
    \\  - _free                every other handle
    \\  - _len, _at            the items of a list handle
    \\  - _<item>_count, _<item>_at
    \\                         a list inside another handle
    \\                         (issuez_issue_label_count, issuez_store_issue_count);
    \\                         a _count without an _at is a plain number
    \\  - _find                one item by key, NULL or {NULL,0} for none
    \\
    \\Flags and choices
    \\  A call's switches are a `uint32_t flags` of its issuez_<call>_flag bits
    \\  (0: the defaults), never a positional bool; a choice between named
    \\  outcomes is an enum. Optional strings are an issuez_str, {NULL,0} when
    \\  absent; optional objects (oids, actors) a pointer, NULL when absent.
    \\
    \\Threads
    \\  An issuez_repo is safe to use from any number of threads at once; it
    \\  keeps a pool of git sessions. Loaded objects are immutable and can be
    \\  read from any thread.
    \\
    \\Blocking, cancellation and signals
    \\  Calls that touch git block. They take an `issuez_cancel *` (may be
    \\  NULL): triggering it from any thread makes the call return
    \\  ISSUEZ_E_CANCELLED within about 50 ms, killing a git request that is
    \\  running (a fetch, a push). Writes are atomic: a write that returns
    \\  CANCELLED didn't happen (a ref update, once started, isn't
    \\  interrupted), and one whose commit landed returns OK. The library
    \\  installs no signal handlers. It writes to
    \\  pipes, so a host must not die of SIGPIPE: ignore it, or handle it as
    \\  the Go runtime does.
    \\
    \\IDs
    \\  Operations take full canonical UUIDs (lowercase, hyphenated). Turn
    \\  user input ("a7f3", "#12") into one with issuez_resolve. Versions and
    \\  commits are issuez_oid values.
;

pub const items = [_]Item{
    .{ .section = .{ "Version and init", "" } },
    .{ .raw =
    \\#define ISSUEZ_VERSION_MAJOR @MAJOR@
    \\#define ISSUEZ_VERSION_MINOR @MINOR@
    \\#define ISSUEZ_VERSION_PATCH @PATCH@
    \\/* Major in the high 16 bits, minor in the low 16. The library accepts a
    \\ * header with the same major and a minor <= its own; before 1.0 the minor
    \\ * must match. */
    \\#define ISSUEZ_ABI_VERSION ((ISSUEZ_VERSION_MAJOR << 16) | ISSUEZ_VERSION_MINOR)
    },
    .{ .handles = &.{ Error, Write, Milestone } },
    // Every fallible function returns it, issuez_init first.
    .{ .type = Code },
    f(
        "issuez_version",
        fn () callconv(.c) [*:0]const u8,
        &.{},
        "\"1.2.3\", or \"1.2.3-12-ga3e21cfa\" built from a git checkout past the tag. " ++
            "Static storage.",
    ),
    f("issuez_abi_version", fn () callconv(.c) u32, &.{}, ""),
    f(
        "issuez_init",
        fn (u32, Err) callconv(.c) Code,
        &.{ "abi_version", "err" },
        "Checks that the header and the library match: ISSUEZ_E_ABI when they " ++
            "don't. Optional: the first call of any function initialises the " ++
            "library; further calls are cheap no-ops.",
    ),

    .{ .section = .{ "Basic types", "" } },
    .{ .type = Str },
    .{ .raw =
    \\/* From a C literal or a NUL-terminated string. */
    \\#ifdef __cplusplus
    \\#define ISSUEZ_STR(lit) (issuez_str{ (lit), sizeof(lit) - 1 })
    \\#else
    \\#define ISSUEZ_STR(lit) ((issuez_str){ (lit), sizeof(lit) - 1 })
    \\#endif
    \\static inline issuez_str issuez_str_c(const char *s) {
    \\    issuez_str r;
    \\    r.ptr = s;
    \\    r.len = 0;
    \\    if (s) while (s[r.len]) r.len++;
    \\    return r;
    \\}
    },
    .{ .prose = "A git object ID: SHA-1 or SHA-256. A value type: copy it freely." },
    .{ .type = Oid },
    .{ .raw =
    \\/* The buffer issuez_oid_hex writes: 64 hex digits and a NUL. */
    \\#define ISSUEZ_OID_HEX_BUFSIZE 65
    },
    f(
        "issuez_oid_hex",
        fn (?*const Oid, ?[*]u8) callconv(.c) usize,
        &.{ "oid", "buf" },
        "Writes the lowercase hex and a NUL into buf (ISSUEZ_OID_HEX_BUFSIZE bytes). " ++
            "Returns the hex length (40 or 64), 0 for a none oid.",
    ),
    f(
        "issuez_oid_parse",
        fn (Str, ?*Oid, Err) callconv(.c) Code,
        &.{ "hex", "out", "err" },
        "Full hex only.",
    ),
    f("issuez_oid_eq", fn (?*const Oid, ?*const Oid) callconv(.c) bool, &.{ "a", "b" }, ""),
    .{ .prose = "A point in time as git records it." },
    .{ .type = Time },
    .{ .prose = "A calendar day (start and due dates)." },
    .{ .type = Date },
    .{ .prose = "A person as stored in git." },
    .{ .type = Person },
    .{ .prose = "The acting user of a write: the commit's author. The committer is the " ++
        "identity the repo was opened with." },
    .{ .type = Actor },
    .{ .type = Progress },

    .{ .section = .{ "Errors and problems", "" } },
    f(
        "issuez_code_name",
        fn (Code) callconv(.c) [*:0]const u8,
        &.{"code"},
        "Static and stable, e.g. \"VERSION_MISMATCH\".",
    ),
    .{ .handles = &.{Problems} },
    f("issuez_error_free", fn (?*Error) callconv(.c) void, &.{"err"}, ""),
    f("issuez_error_code", fn (?*const Error) callconv(.c) Code, &.{"err"}, ""),
    f(
        "issuez_error_message",
        fn (?*const Error) callconv(.c) Str,
        &.{"err"},
        "One sentence for humans, English, no trailing newline.",
    ),
    f(
        "issuez_error_subject",
        fn (?*const Error) callconv(.c) Str,
        &.{"err"},
        "What it is about, when known: an issue UUID, a ref, a field key.",
    ),
    f(
        "issuez_error_git_stderr",
        fn (?*const Error) callconv(.c) Str,
        &.{"err"},
        "git's stderr (trimmed, bounded), for GIT, NETWORK and LFS.",
    ),
    f(
        "issuez_error_current_tip",
        fn (?*const Error, ?*Oid) callconv(.c) bool,
        &.{ "err", "out" },
        "VERSION_MISMATCH: the issue's tip now.",
    ),
    f(
        "issuez_error_problems",
        fn (?*const Error) callconv(.c) ?*const Problems,
        &.{"err"},
        "INVALID_VALUE and GUARD carry every problem found. May be NULL.",
    ),
    f(
        "issuez_error_write",
        fn (?*const Error) callconv(.c) ?*const Write,
        &.{"err"},
        "A write that failed after its commit landed: its receipt, borrowed from " ++
            "err. NULL in this version: a cancelled write didn't happen, and one " ++
            "whose commit landed returns OK.",
    ),
    .{ .type = ProblemKind },
    .{ .type = Field },
    f(
        "issuez_field_key",
        fn (Field) callconv(.c) [*:0]const u8,
        &.{"field"},
        "Trailer key (\"Labels\", \"X-Due-Date\"), static storage.",
    ),
    .{ .type = Problem },
    f("issuez_problems_len", fn (?*const Problems) callconv(.c) usize, &.{"p"}, ""),
    f(
        "issuez_problems_at",
        fn (?*const Problems, usize) callconv(.c) ?*const Problem,
        &.{ "p", "i" },
        "",
    ),
    f(
        "issuez_problems_free",
        fn (?*Problems) callconv(.c) void,
        &.{"p"},
        "Only for lists returned as owned (`issuez_problems **out`).",
    ),

    .{ .section = .{
        "Op lists",
        "See \"Op lists\" in the conventions. Write targets, their slots and verbs:\n" ++
            "  TITLE, DESCRIPTION, COMMENT, STATE, FIXED_BY, RELEASE, REASON, NAME  SET str\n" ++
            "  REF                        SET str, CLEAR\n" ++
            "  WORKFLOW_STATE             SET str, CLEAR (default)\n" ++
            "  LABELS, BLOCKED_BY         ADD/REMOVE str, CLEAR\n" ++
            "  ASSIGNEES                  ADD/REMOVE person, CLEAR\n" ++
            "  PRIORITY                   SET num (issuez_priority), CLEAR\n" ++
            "  MILESTONE                  SET str (UUID), CLEAR, INHERIT\n" ++
            "  PARENT                     SET str (UUID), CLEAR\n" ++
            "  START_DATE, DUE_DATE       SET date, CLEAR\n" ++
            "  ESTIMATE                   SET num (minutes), CLEAR\n" ++
            "  LOCKED                     SET num (0/1), str (reason)\n" ++
            "  DELETED                    SET num (0/1): soft delete and restore\n" ++
            "  NUMBER                     SET num, write-once\n" ++
            "  MILESTONE_STATUS           SET num (issuez_milestone_status)\n" ++
            "  EXTRA                      SET name, str (\"\" clears)\n" ++
            "DESCRIPTION on create is the body; on update a description-edit event,\n" ++
            "which can't share a commit with COMMENT. COMMENT on create is INCOMPATIBLE.",
    } },
    .{ .type = Verb },
    .{ .type = Opt },
    .{ .type = Op },
    .{ .raw =
    \\#ifdef __cplusplus
    \\#define ISSUEZ_OP_INIT {}
    \\#else
    \\#define ISSUEZ_OP_INIT { 0 }
    \\#endif
    \\#define ISSUEZ_COUNT(arr) (sizeof(arr) / sizeof((arr)[0]))
    },
    .{ .type = OpList },
    f(
        "issuez_ops_validate",
        fn (OpList, OpsPtr, usize, ?*?*Problems, Err) callconv(.c) Code,
        &.{ "list", "ops", "n", "out", "err" },
        "Format rules only (no repo): verbs, slots, value grammar, default limits. " ++
            "*out is an empty list when everything is fine.",
    ),
    .{ .prose = "Helpers that build each op are at the end, under \"Op helpers\", after " ++
        "the enums they take." },

    .{ .section = .{ "Cancel and logging", "" } },
    .{ .handles = &.{Cancel} },
    f("issuez_cancel_new", fn () callconv(.c) ?*Cancel, &.{}, "NULL when out of memory."),
    f(
        "issuez_cancel_trigger",
        fn (?*Cancel) callconv(.c) void,
        &.{"c"},
        "Thread-safe and idempotent; affects every call using this token.",
    ),
    f("issuez_cancel_triggered", fn (?*const Cancel) callconv(.c) bool, &.{"c"}, ""),
    f("issuez_cancel_free", fn (?*Cancel) callconv(.c) void, &.{"c"}, ""),
    .{ .type = LogLevel },
    .{ .type = LogEvent },
    .{ .raw = "typedef void (*issuez_log_fn)(void *userdata, const issuez_log_event *event);" },
    f(
        "issuez_set_logger",
        fn (LogLevel, LogFn, ?*anyopaque) callconv(.c) void,
        &.{ "min_level", "cb", "userdata" },
        "Process-wide. Called from any thread, possibly concurrently; the event " ++
            "lives only during the call. Must not call back into issuez. NULL cb disables.",
    ),

    .{ .section = .{ "Repo", "" } },
    .{ .handles = &.{Repo} },
    f(
        "issuez_repo_open",
        fn (Str, OpsPtr, usize, ?*?*Repo, Err) callconv(.c) Code,
        &.{ "path", "opts", "n_opts", "out", "err" },
        "path: a work tree, any directory in it, or the git dir of a bare repo. " ++
            "opts: ISSUEZ_OPT_GIT_PATH .. ISSUEZ_OPT_CACHE_ISSUES (may be NULL, 0). Checks " ++
            "git's version; git sessions start lazily.",
    ),
    f(
        "issuez_repo_close",
        fn (?*Repo) callconv(.c) void,
        &.{"repo"},
        "Drops the caller's reference (see Ownership).",
    ),
    f("issuez_repo_git_dir", fn (?*const Repo) callconv(.c) Str, &.{"repo"}, ""),
    f(
        "issuez_repo_set_logger",
        fn (?*Repo, LogLevel, LogFn, ?*anyopaque) callconv(.c) void,
        &.{ "repo", "min_level", "cb", "userdata" },
        "A logger for this repo's calls, in place of the process-wide one (issuez_set_logger) " ++
            "while they run; the same rules. NULL cb goes back to the process-wide one.",
    ),
    f(
        "issuez_repo_drop_all",
        fn (?*Repo, Can, ?*usize, Err) callconv(.c) Code,
        &.{ "repo", "cancel", "dropped", "err" },
        "Deletes every ref of the library's (issues, milestones, attachments, tombstones " ++
            "and local state) in one transaction; *dropped is how many. It undoes an " ++
            "import into a repository that had none, with no writes running. Not a purge: " ++
            "clones keep their copies and sync them back.",
    ),
    f(
        "issuez_repo_begin_import",
        fn (?*Repo, Can, ?*?*Repo, Err) callconv(.c) Code,
        &.{ "repo", "cancel", "out", "err" },
        "A staging repo inheriting repo's settings and options, sharing its objects. " ++
            "Replay with ordinary writes, then commit_import. Closing it removes its " ++
            "private refs, also after failure. The target stays alive while staging. " ++
            "Do not write to a staging repo concurrently with commit or close.",
    ),
    f(
        "issuez_repo_commit_import",
        fn (?*Repo, Can, ?*usize, Err) callconv(.c) Code,
        &.{ "staging", "cancel", "adopted", "err" },
        "Publishes staging's shared refs to its target in one transaction. CONTENDED " ++
            "if a target ref already exists; no refs are published then. Call once on " ++
            "success, stop writing and close staging. Does not publish local cache refs.",
    ),
    f(
        "issuez_repo_adopt_refs",
        fn (?*Repo, ?*Repo, Can, ?*usize, Err) callconv(.c) Code,
        &.{ "repo", "from", "cancel", "adopted", "err" },
        "Creates in repo every issue, milestone, attachment and tombstone ref from has, " ++
            "in one transaction; *adopted is how many. An import written into a scratch " ++
            "repository whose git uses repo's objects (GIT_OBJECT_DIRECTORY) lands at once " ++
            "or not at all. CONTENDED when repo has one of them, CORRUPT when a tip's " ++
            "object isn't in repo's store; nothing is taken then.",
    ),
    f(
        "issuez_settings_write",
        fn (?*Repo, OpsPtr, usize, Can, Err) callconv(.c) Code,
        &.{ "repo", "ops", "n", "cancel", "err" },
        "Writes git config issue.doneStates and issue.workflowStates, what a settings " ++
            "page saves. ops: DONE_STATE and WORKFLOW_STATE, ADD each state (the key is " ++
            "set to them) or CLEAR (the key is unset: the defaults). Every state is checked " ++
            "first (INVALID_VALUE). Handles opened afterwards see the new settings.",
    ),
    f(
        "issuez_repo_limit",
        fn (?*const Repo, Str, ?*u64) callconv(.c) bool,
        &.{ "repo", "name", "out" },
        "The effective value of a limit (\"max_attachment_bytes\", \"cas_retries\", the " ++
            "names ISSUEZ_OPT_LIMIT takes); false for no such limit.",
    ),
    f(
        "issuez_repo_workflow_state_count",
        fn (?*const Repo) callconv(.c) usize,
        &.{"repo"},
        "The effective settings, from opts or git config.",
    ),
    f(
        "issuez_repo_workflow_state_at",
        fn (?*const Repo, usize) callconv(.c) Str,
        &.{ "repo", "i" },
        "",
    ),
    f("issuez_repo_done_state_count", fn (?*const Repo) callconv(.c) usize, &.{"repo"}, ""),
    f(
        "issuez_repo_done_state_at",
        fn (?*const Repo, usize) callconv(.c) Str,
        &.{ "repo", "i" },
        "",
    ),

    .{ .section = .{ "Resolve and change detection", "" } },
    .{ .type = Kind },
    .{ .handles = &.{Matches} },
    f(
        "issuez_resolve",
        fn (?*Repo, Kind, Str, Can, ?*?*Matches, Err) callconv(.c) Code,
        &.{ "repo", "kind", "input", "cancel", "out", "err" },
        "User input to UUIDs: a full UUID, a unique prefix (\"a7f3\"), a number " ++
            "(\"#12\"), or for milestones a name. OK with 0, 1 or more matches.",
    ),
    f("issuez_matches_len", fn (?*const Matches) callconv(.c) usize, &.{"m"}, ""),
    f("issuez_matches_at", fn (?*const Matches, usize) callconv(.c) Str, &.{ "m", "i" }, ""),
    f("issuez_matches_free", fn (?*Matches) callconv(.c) void, &.{"m"}, ""),
    .{ .prose = "Line search: the lines of what each issue says now (title, fields as " ++
        "`Key: value`, description, comments that aren't deleted) that contain a fixed " ++
        "string, as git issue search shows them." },
    .{ .type = SearchHit },
    .{ .type = SearchFlag },
    .{ .handles = &.{SearchHits} },
    f(
        "issuez_search",
        fn (?*Repo, Str, u32, Can, ?*?*SearchHits, Err) callconv(.c) Code,
        &.{ "repo", "needle", "flags", "cancel", "out", "err" },
        "Every hit in every issue that isn't deleted, by issue UUID. flags: " ++
            "issuez_search_flag bits.",
    ),
    f("issuez_search_hits_len", fn (?*const SearchHits) callconv(.c) usize, &.{"h"}, ""),
    f(
        "issuez_search_hits_at",
        fn (?*const SearchHits, usize) callconv(.c) ?*const SearchHit,
        &.{ "h", "i" },
        "",
    ),
    f("issuez_search_hits_free", fn (?*SearchHits) callconv(.c) void, &.{"h"}, ""),
    .{ .prose = "What pickers, filters and list views need across issues: the labels in use, " ++
        "the people the history knows, and the shortest unique ID prefixes. Deleted issues " ++
        "don't count in the labels and people." },
    .{ .handles = &.{ LabelCounts, People, ShortIds } },
    .{ .type = LabelCount },
    .{ .type = KnownPerson },
    .{ .type = ShortId },
    f(
        "issuez_label_counts_take",
        fn (?*Repo, Can, ?*?*LabelCounts, Err) callconv(.c) Code,
        &.{ "repo", "cancel", "out", "err" },
        "Every label in use, by name.",
    ),
    f("issuez_label_counts_len", fn (?*const LabelCounts) callconv(.c) usize, &.{"l"}, ""),
    f(
        "issuez_label_counts_at",
        fn (?*const LabelCounts, usize) callconv(.c) ?*const LabelCount,
        &.{ "l", "i" },
        "",
    ),
    f("issuez_label_counts_free", fn (?*LabelCounts) callconv(.c) void, &.{"l"}, ""),
    f(
        "issuez_people_take",
        fn (?*Repo, Can, ?*?*People, Err) callconv(.c) Code,
        &.{ "repo", "cancel", "out", "err" },
        "Everyone who opened or is assigned an issue, by email (compared ignoring case).",
    ),
    f("issuez_people_len", fn (?*const People) callconv(.c) usize, &.{"p"}, ""),
    f(
        "issuez_people_at",
        fn (?*const People, usize) callconv(.c) ?*const KnownPerson,
        &.{ "p", "i" },
        "",
    ),
    f("issuez_people_free", fn (?*People) callconv(.c) void, &.{"p"}, ""),
    f(
        "issuez_short_ids_take",
        fn (?*Repo, usize, Can, ?*?*ShortIds, Err) callconv(.c) Code,
        &.{ "repo", "min", "cancel", "out", "err" },
        "For every issue, the shortest prefix of its UUID that no other issue's starts " ++
            "with, at least min long: what a list shows so that issuez_resolve takes it.",
    ),
    f("issuez_short_ids_len", fn (?*const ShortIds) callconv(.c) usize, &.{"s"}, ""),
    f(
        "issuez_short_ids_at",
        fn (?*const ShortIds, usize) callconv(.c) ?*const ShortId,
        &.{ "s", "i" },
        "In UUID order.",
    ),
    f(
        "issuez_short_ids_find",
        fn (?*const ShortIds, Str) callconv(.c) Str,
        &.{ "s", "id" },
        "The prefix of a full UUID; {NULL,0} for one it doesn't know.",
    ),
    f("issuez_short_ids_free", fn (?*ShortIds) callconv(.c) void, &.{"s"}, ""),
    .{ .raw =
    \\/* The buffer issuez_resolve_one writes: a hyphenated UUID and a NUL. */
    \\#define ISSUEZ_UUID_BUFSIZE 37
    },
    f(
        "issuez_resolve_one",
        fn (?*Repo, Kind, Str, Can, ?[*]u8, Err) callconv(.c) Code,
        &.{ "repo", "kind", "input", "cancel", "buf", "err" },
        "Exactly one, or NOT_FOUND / AMBIGUOUS. Writes the UUID and a NUL into buf " ++
            "(ISSUEZ_UUID_BUFSIZE bytes).",
    ),
    .{ .prose = "Snapshot: every issue and milestone ref with its tip. Cheap (no issue is " ++
        "read), and serialisable so a host can store what it indexed." },
    .{ .handles = &.{ Snapshot, Diff } },
    f(
        "issuez_snapshot_take",
        fn (?*Repo, Can, ?*?*Snapshot, Err) callconv(.c) Code,
        &.{ "repo", "cancel", "out", "err" },
        "",
    ),
    f("issuez_snapshot_free", fn (?*Snapshot) callconv(.c) void, &.{"s"}, ""),
    f("issuez_snapshot_len", fn (?*const Snapshot) callconv(.c) usize, &.{"s"}, ""),
    f(
        "issuez_snapshot_at",
        fn (?*const Snapshot, usize, ?*Kind, ?*Str, ?*Oid) callconv(.c) void,
        &.{ "s", "i", "kind", "id", "tip" },
        "The i-th entry, sorted by kind, then UUID.",
    ),
    f(
        "issuez_snapshot_tip",
        fn (?*const Snapshot, Kind, Str, ?*Oid) callconv(.c) bool,
        &.{ "s", "kind", "id", "out" },
        "",
    ),
    f(
        "issuez_snapshot_encode",
        fn (?*const Snapshot) callconv(.c) Str,
        &.{"s"},
        "A stable, versioned binary encoding. The bytes live until s is freed.",
    ),
    f(
        "issuez_snapshot_decode",
        fn (Str, ?*?*Snapshot, Err) callconv(.c) Code,
        &.{ "bytes", "out", "err" },
        "Empty bytes decode to an empty snapshot.",
    ),
    .{ .type = ChangeKind },
    .{ .type = DiffEntry },
    f(
        "issuez_diff_new",
        fn (?*const Snapshot, ?*const Snapshot, ?*?*Diff, Err) callconv(.c) Code,
        &.{ "old_snap", "new_snap", "out", "err" },
        "old_snap may be NULL (everything is created). Pure: no git.",
    ),
    f("issuez_diff_len", fn (?*const Diff) callconv(.c) usize, &.{"d"}, ""),
    f(
        "issuez_diff_at",
        fn (?*const Diff, usize) callconv(.c) ?*const DiffEntry,
        &.{ "d", "i" },
        "",
    ),
    f("issuez_diff_free", fn (?*Diff) callconv(.c) void, &.{"d"}, ""),

    .{ .section = .{ "Watching", "Live updates: a callback when other processes (git issue, " ++
        "another front end, a sync) change a repository's issues on disk." } },
    .{ .type = WatchChange },
    .{ .raw = "typedef void (*issuez_watch_fn)(void *userdata, uint32_t changes);" },
    .{ .handles = &.{Watch} },
    f(
        "issuez_watch_start",
        fn (?*Repo, WatchFn, ?*anyopaque, ?*?*Watch, Err) callconv(.c) Code,
        &.{ "repo", "cb", "userdata", "out", "err" },
        "Calls cb with issuez_watch_change bits once a burst of changes is quiet (and at " ++
            "least every 400 ms while it isn't), on a thread of its own; our own writes " ++
            "count too. cb must not call issuez_watch_stop. A changed path says something " ++
            "may have changed, not what: read again.",
    ),
    f(
        "issuez_watch_stop",
        fn (?*Watch) callconv(.c) void,
        &.{"w"},
        "No call to cb after it returns.",
    ),
    .{ .section = .{ "Issues: read", "" } },
    .{ .handles = &.{ Issue, IssueList, Bytes } },
    f(
        "issuez_issue_load",
        fn (?*Repo, Str, Can, ?*?*Issue, Err) callconv(.c) Code,
        &.{ "repo", "id", "cancel", "out", "err" },
        "",
    ),
    f(
        "issuez_issue_load_at",
        fn (?*Repo, Str, ?*const Oid, ?*const Oid, Can, ?*?*Issue, Err) callconv(.c) Code,
        &.{ "repo", "id", "tip", "since", "cancel", "out", "err" },
        "Loads the exact tip, even after its ref moved or disappeared. tip must be nonzero " ++
            "and use the repository's object format. since is optional, as in load_since. " ++
            "Historical objects must still exist; this does not retain purged objects.",
    ),
    f(
        "issuez_issue_load_since",
        fn (?*Repo, Str, ?*const Oid, Can, ?*?*Issue, Err) callconv(.c) Code,
        &.{ "repo", "id", "since", "cancel", "out", "err" },
        "issuez_issue_load, with each timeline entry's is_new saying whether its commit " ++
            "is new since the tip since: what a host that projected the issue at since " ++
            "hasn't seen, merged-in commits included. NULL since: every entry is new. A " ++
            "since outside the issue's history (a purge rewrote it, or it isn't this " ++
            "issue's) makes none new and issuez_issue_info.rewritten true.",
    ),
    .{ .type = JsonFlag },
    f(
        "issuez_issue_json",
        fn (?*Repo, Str, u32, Can, ?*?*Bytes, Err) callconv(.c) Code,
        &.{ "repo", "id", "flags", "cancel", "out", "err" },
        "The issue as git issue show --json writes it (docs/json.md; " ++
            "ISSUEZ_JSON_FLAG_FULL adds the description, comments and history), UTF-8: one " ++
            "call for a binding that would rather parse JSON than call every accessor.",
    ),
    f(
        "issuez_issue_json_many",
        fn (?*Repo, ?[*]const Str, usize, u32, Can, ?*?*Bytes, Err) callconv(.c) Code,
        &.{ "repo", "ids", "n", "flags", "cancel", "out", "err" },
        "A JSON array of the issues with these full UUIDs, in their order; NULL ids and " ++
            "n 0: every issue that isn't deleted. Missing and damaged ones are left out.",
    ),
    .{ .type = LoadFlag },
    f(
        "issuez_issue_load_many",
        fn (?*Repo, ?[*]const Str, usize, u32, Can, ?*?*IssueList, Err) callconv(.c) Code,
        &.{ "repo", "ids", "n", "flags", "cancel", "out", "err" },
        "In the order of ids. Missing and damaged ones are skipped (see " ++
            "issuez_issue_list_skipped_at) unless ISSUEZ_LOAD_FLAG_STRICT.",
    ),
    f("issuez_issue_free", fn (?*Issue) callconv(.c) void, &.{"issue"}, ""),
    .{ .type = State },
    .{ .type = Priority },
    .{ .prose = "An issue's single values, one record; lists and lookups have their own calls " ++
        "below. Filled once, when the handle is built: reading it costs nothing and is safe " ++
        "from any thread, like the rest of a loaded object. A newer library may add fields at " ++
        "the end, which doesn't break a program built against this header because the library " ++
        "owns the memory: read it through the pointer, never copy or allocate one." },
    .{ .type = IssueInfo },
    f(
        "issuez_issue_info_of",
        fn (?*const Issue) callconv(.c) ?*const IssueInfo,
        &.{"i"},
        "Borrowed from i. NULL for a NULL handle.",
    ),
    f("issuez_issue_label_count", fn (?*const Issue) callconv(.c) usize, &.{"i"}, ""),
    f("issuez_issue_label_at", fn (?*const Issue, usize) callconv(.c) Str, &.{ "i", "k" }, ""),
    f("issuez_issue_has_label", fn (?*const Issue, Str) callconv(.c) bool, &.{ "i", "label" }, ""),
    f("issuez_issue_assignee_count", fn (?*const Issue) callconv(.c) usize, &.{"i"}, ""),
    f(
        "issuez_issue_assignee_at",
        fn (?*const Issue, usize) callconv(.c) ?*const Person,
        &.{ "i", "k" },
        "",
    ),
    f("issuez_issue_blocker_count", fn (?*const Issue) callconv(.c) usize, &.{"i"}, ""),
    f("issuez_issue_blocker_at", fn (?*const Issue, usize) callconv(.c) Str, &.{ "i", "k" }, ""),
    f(
        "issuez_issue_field",
        fn (?*const Issue, Str) callconv(.c) Str,
        &.{ "i", "key" },
        "Any trailer by key, case-insensitive, as resolved (unknown ones too).",
    ),
    f(
        "issuez_issue_extra_count",
        fn (?*const Issue) callconv(.c) usize,
        &.{"i"},
        "Fields this library doesn't interpret (X-Forgejo-* and others).",
    ),
    f(
        "issuez_issue_extra_at",
        fn (?*const Issue, usize, ?*Str, ?*Str) callconv(.c) void,
        &.{ "i", "k", "key", "value" },
        "",
    ),
    f(
        "issuez_issue_problems",
        fn (?*const Issue) callconv(.c) ?*const Problems,
        &.{"i"},
        "Invalid stored values (kept and ignored), unresolved events, and " ++
            "conflicts (two clones disagreed).",
    ),
    .{ .type = Reaction },
    f(
        "issuez_issue_reaction_count",
        fn (?*const Issue, ?*const Oid) callconv(.c) usize,
        &.{ "i", "comment" },
        "On the issue (comment NULL) or a comment.",
    ),
    f(
        "issuez_issue_reaction_at",
        fn (?*const Issue, ?*const Oid, usize) callconv(.c) ?*const Reaction,
        &.{ "i", "comment", "k" },
        "",
    ),
    f(
        "issuez_reaction_user_at",
        fn (?*const Reaction, usize) callconv(.c) ?*const Person,
        &.{ "r", "k" },
        "",
    ),
    .{ .prose = "Comments: text someone wrote, in order, deleted ones included. Field-only " ++
        "commits and merges are in the timeline." },
    .{ .type = Comment },
    f("issuez_issue_comment_count", fn (?*const Issue) callconv(.c) usize, &.{"i"}, ""),
    f(
        "issuez_issue_comment_at",
        fn (?*const Issue, usize) callconv(.c) ?*const Comment,
        &.{ "i", "k" },
        "",
    ),
    f(
        "issuez_issue_comment_find",
        fn (?*const Issue, ?*const Oid) callconv(.c) ?*const Comment,
        &.{ "i", "id" },
        "",
    ),
    f(
        "issuez_comment_attachment_at",
        fn (?*const Comment, usize) callconv(.c) Str,
        &.{ "c", "k" },
        "The UUID of an attachment the comment's commit added; {NULL,0} past the end.",
    ),
    .{ .prose = "Attachments: images on the issue (format.md §7), present ones first, oldest " ++
        "first, then the removed ones. The bytes are LFS objects; this library's CLI keeps " ++
        "them in the repository, a host in its LFS store." },
    .{ .type = Attachment },
    f("issuez_issue_attachment_count", fn (?*const Issue) callconv(.c) usize, &.{"i"}, ""),
    f(
        "issuez_issue_attachment_at",
        fn (?*const Issue, usize) callconv(.c) ?*const Attachment,
        &.{ "i", "k" },
        "",
    ),
    .{ .prose = "Timeline: every commit of the issue as a typed entry, oldest first. The " ++
        "changes use the verbs of writes: SET (old -> new), CLEAR, ADD, REMOVE." },
    .{ .type = Change },
    .{ .type = EntryKind },
    .{ .type = Entry },
    f("issuez_issue_timeline_count", fn (?*const Issue) callconv(.c) usize, &.{"i"}, ""),
    f(
        "issuez_issue_timeline_at",
        fn (?*const Issue, usize) callconv(.c) ?*const Entry,
        &.{ "i", "k" },
        "",
    ),
    f(
        "issuez_entry_change_at",
        fn (?*const Entry, usize) callconv(.c) ?*const Change,
        &.{ "e", "k" },
        "",
    ),
    .{ .prose = "Every version of the description (comment NULL) or a comment, oldest first. " ++
        "After concurrent edits the current text is the one the merge rule resolves to, " ++
        "which needn't be the last version." },
    .{ .type = RevisionKind },
    .{ .type = Revision },
    f(
        "issuez_issue_history_count",
        fn (?*const Issue, ?*const Oid) callconv(.c) usize,
        &.{ "i", "comment" },
        "",
    ),
    f(
        "issuez_issue_history_at",
        fn (?*const Issue, ?*const Oid, usize) callconv(.c) ?*const Revision,
        &.{ "i", "comment", "k" },
        "",
    ),

    .{ .section = .{ "Issues: query", "" } },
    .{ .type = Sort },
    f(
        "issuez_query_run",
        fn (?*Repo, OpsPtr, usize, Can, ?*?*IssueList, Err) callconv(.c) Code,
        &.{ "repo", "ops", "n", "cancel", "out", "err" },
        "ops: ISSUEZ_OPT_Q_*. Defaults: not done, not deleted, newest first, 100 per " ++
            "page. Q_TEXT is a fixed-string match, not a search engine.",
    ),
    f(
        "issuez_query_count",
        fn (?*Repo, OpsPtr, usize, Can, ?*u64, Err) callconv(.c) Code,
        &.{ "repo", "ops", "n", "cancel", "out", "err" },
        "Ignores Q_LIMIT and Q_AFTER.",
    ),
    f("issuez_issue_list_len", fn (?*const IssueList) callconv(.c) usize, &.{"l"}, ""),
    f(
        "issuez_issue_list_at",
        fn (?*const IssueList, usize) callconv(.c) ?*const Issue,
        &.{ "l", "i" },
        "",
    ),
    f(
        "issuez_issue_list_next_cursor",
        fn (?*const IssueList) callconv(.c) Str,
        &.{"l"},
        "{NULL,0} on the last page.",
    ),
    f(
        "issuez_issue_list_skipped_count",
        fn (?*const IssueList) callconv(.c) usize,
        &.{"l"},
        "Ids asked for or matched that couldn't be read (damaged).",
    ),
    f(
        "issuez_issue_list_skipped_at",
        fn (?*const IssueList, usize) callconv(.c) Str,
        &.{ "l", "i" },
        "",
    ),
    f("issuez_issue_list_free", fn (?*IssueList) callconv(.c) void, &.{"l"}, ""),
    .{ .section = .{ "Store", "A live view of a repository's issues for a front end: " ++
        "every issue, kept up to date by issuez_store_refresh, which loads only the issues " ++
        "whose tip moved. Issue handles from it are borrowed: valid until the next refresh " ++
        "or free. Not for concurrent use; the repo is." } },
    .{ .handles = &.{Store} },
    f(
        "issuez_store_new",
        fn (?*Repo, ?*?*Store, Err) callconv(.c) Code,
        &.{ "repo", "out", "err" },
        "Empty until the first refresh.",
    ),
    f(
        "issuez_store_refresh",
        fn (?*Store, Can, ?*bool, Err) callconv(.c) Code,
        &.{ "store", "cancel", "changed", "err" },
        "Reads the refs and loads what moved; *changed is false when nothing did and the " ++
            "handles stay valid.",
    ),
    f(
        "issuez_store_generation",
        fn (?*const Store) callconv(.c) u32,
        &.{"store"},
        "Bumped by every refresh that changed something.",
    ),
    f("issuez_store_issue_count", fn (?*const Store) callconv(.c) usize, &.{"store"}, ""),
    f(
        "issuez_store_issue_at",
        fn (?*const Store, usize) callconv(.c) ?*const Issue,
        &.{ "store", "i" },
        "In UUID order; deleted ones too.",
    ),
    f(
        "issuez_store_find",
        fn (?*const Store, Str) callconv(.c) ?*const Issue,
        &.{ "store", "id" },
        "By full UUID; NULL for none.",
    ),
    f("issuez_store_changed_count", fn (?*const Store) callconv(.c) usize, &.{"store"}, ""),
    f(
        "issuez_store_changed_at",
        fn (?*const Store, usize) callconv(.c) Str,
        &.{ "store", "i" },
        "UUIDs of the issues the last refresh found created, changed or deleted.",
    ),
    f("issuez_store_free", fn (?*Store) callconv(.c) void, &.{"store"}, ""),

    .{ .section = .{
        "Issues: write",
        "One op list, one commit: a user action (\"comment and close\", \"edit labels and " ++
            "assignees\", \"delete\") is one call. ISSUEZ_OPT_EXPECT and the other write " ++
            "options go in the same list.",
    } },
    f(
        "issuez_issue_check",
        fn (?*Repo, Str, OpsPtr, usize, Can, ?*?*Problems, Err) callconv(.c) Code,
        &.{ "repo", "id", "ops", "n", "cancel", "out", "err" },
        "Dry run: every problem the write would hit, without writing. OK with an " ++
            "empty list: it would succeed now. id {NULL,0}: as a create.",
    ),
    f(
        "issuez_issue_create",
        fn (?*Repo, OpsPtr, usize, ?*const Actor, Can, ?*?*Write, Err) callconv(.c) Code,
        &.{ "repo", "ops", "n", "actor", "cancel", "out", "err" },
        "TITLE is required.",
    ),
    f(
        "issuez_issue_update",
        fn (?*Repo, Str, OpsPtr, usize, ?*const Actor, Can, ?*?*Write, Err) callconv(.c) Code,
        &.{ "repo", "id", "ops", "n", "actor", "cancel", "out", "err" },
        "Every write to an existing issue: fields, a comment, a comment's edit, " ++
            "delete or restore (issuez_edit_comment, issuez_delete_comment, " ++
            "issuez_restore_comment), a reaction (issuez_add_reaction, " ++
            "issuez_reaction_target). A list that changes nothing (empty, or every " ++
            "value as it is) is OK and writes nothing (issuez_write_wrote).",
    ),
    f(
        "issuez_attachment_read",
        fn (?*Repo, Str, Str, Can, ?*?*Bytes, Err) callconv(.c) Code,
        &.{ "repo", "issue_id", "attachment_id", "cancel", "out", "err" },
        "An attachment's bytes from the repository's store, checked against its trailer: " ++
            "what a front end shows. NOT_FOUND for no such issue or attachment, LFS when " ++
            "the bytes aren't in this clone (git lfs fetch), CORRUPT when they don't match.",
    ),
    f(
        "issuez_bytes_data",
        fn (?*const Bytes) callconv(.c) Str,
        &.{"b"},
        "The bytes; not NUL-terminated text, binary.",
    ),
    f("issuez_bytes_free", fn (?*Bytes) callconv(.c) void, &.{"b"}, ""),
    f(
        "issuez_attachment_validate",
        fn (?*Repo, Str, Str, ?*Str, Err) callconv(.c) Code,
        &.{ "repo", "name", "data", "media_type", "err" },
        "Whether a write would take these bytes as an attachment (a PNG, JPEG or WebP, " ++
            "not animated, within the repo's limits), without writing. media_type (may be " ++
            "NULL) gets the type, a static string.",
    ),
    .{ .handles = &.{PreparedAttachment} },
    .{ .type = AttachmentSpec },
    f(
        "issuez_attachment_prepare",
        fn (?*Repo, Str, Str, Str, Can, ?*?*PreparedAttachment, Err) callconv(.c) Code,
        &.{ "repo", "id", "name", "data", "cancel", "out", "err" },
        "Validates and hashes bytes once, sanitizes the name and chooses an ID when empty. " ++
            "Store the bytes in the host's LFS store before using the prepared op. " ++
            "The write requires ATTACHMENT_STORE 0 and checks metadata and limits again.",
    ),
    f(
        "issuez_prepared_attachment_info",
        fn (?*const PreparedAttachment) callconv(.c) ?*const AttachmentSpec,
        &.{"p"},
        "Borrowed metadata for the host's storage, valid until p is freed.",
    ),
    f(
        "issuez_prepared_attachment_op",
        fn (?*const PreparedAttachment) callconv(.c) Op,
        &.{"p"},
        "An ADD op borrowing p's metadata. Keep p until the write returns.",
    ),
    f("issuez_prepared_attachment_free", fn (?*PreparedAttachment) callconv(.c) void, &.{"p"}, ""),
    .{ .prose = "The receipt of a write." },
    f("issuez_write_free", fn (?*Write) callconv(.c) void, &.{"w"}, ""),
    f("issuez_write_kind", fn (?*const Write) callconv(.c) Kind, &.{"w"}, ""),
    f("issuez_write_id", fn (?*const Write) callconv(.c) Str, &.{"w"}, ""),
    f(
        "issuez_write_wrote",
        fn (?*const Write) callconv(.c) bool,
        &.{"w"},
        "false: nothing to write (a no-op list, an idempotent reaction).",
    ),
    f("issuez_write_commit", fn (?*const Write) callconv(.c) Oid, &.{"w"}, ""),
    f("issuez_write_old_tip", fn (?*const Write) callconv(.c) Oid, &.{"w"}, "len 0 on create."),
    f("issuez_write_new_tip", fn (?*const Write) callconv(.c) Oid, &.{"w"}, "The next expect."),
    f(
        "issuez_write_retries",
        fn (?*const Write) callconv(.c) u32,
        &.{"w"},
        "Times the write started over after a concurrent change; usually 0.",
    ),
    f(
        "issuez_write_entry",
        fn (?*const Write) callconv(.c) ?*const Entry,
        &.{"w"},
        "The commit as a timeline entry, with its typed changes.",
    ),
    f(
        "issuez_write_load_issue",
        fn (?*const Write, Can, ?*?*Issue, Err) callconv(.c) Code,
        &.{ "w", "cancel", "out", "err" },
        "The issue as of the new tip, owned by the caller.",
    ),

    f(
        "issuez_write_load_milestone",
        fn (?*const Write, Can, ?*?*Milestone, Err) callconv(.c) Code,
        &.{ "w", "cancel", "out", "err" },
        "The milestone at the receipt's exact new tip, owned by the caller.",
    ),
    .{ .section = .{ "Milestones", "" } },
    .{ .handles = &.{MilestoneList} },
    .{ .type = MilestoneStatus },
    f(
        "issuez_milestone_load",
        fn (?*Repo, Str, Can, ?*?*Milestone, Err) callconv(.c) Code,
        &.{ "repo", "id", "cancel", "out", "err" },
        "",
    ),
    f(
        "issuez_milestone_load_at",
        fn (?*Repo, Str, ?*const Oid, Can, ?*?*Milestone, Err) callconv(.c) Code,
        &.{ "repo", "id", "tip", "cancel", "out", "err" },
        "The milestone at an exact, nonzero tip, even after its ref moved or disappeared.",
    ),
    f(
        "issuez_milestone_list_all",
        fn (?*Repo, Can, ?*?*MilestoneList, Err) callconv(.c) Code,
        &.{ "repo", "cancel", "out", "err" },
        "",
    ),
    f("issuez_milestone_free", fn (?*Milestone) callconv(.c) void, &.{"m"}, ""),
    f("issuez_milestone_list_len", fn (?*const MilestoneList) callconv(.c) usize, &.{"l"}, ""),
    f(
        "issuez_milestone_list_at",
        fn (?*const MilestoneList, usize) callconv(.c) ?*const Milestone,
        &.{ "l", "i" },
        "",
    ),
    f("issuez_milestone_list_free", fn (?*MilestoneList) callconv(.c) void, &.{"l"}, ""),
    .{ .prose = "A milestone's single values, one record, like issuez_issue_info: filled once " ++
        "when the handle is built, and fields may be added at the end, so read it through the " ++
        "pointer and never copy or allocate one." },
    .{ .type = MilestoneInfo },
    f(
        "issuez_milestone_info_of",
        fn (?*const Milestone) callconv(.c) ?*const MilestoneInfo,
        &.{"m"},
        "Borrowed from m. NULL for a NULL handle.",
    ),
    f(
        "issuez_milestone_problems",
        fn (?*const Milestone) callconv(.c) ?*const Problems,
        &.{"m"},
        "",
    ),
    f(
        "issuez_milestone_check",
        fn (?*Repo, Str, OpsPtr, usize, Can, ?*?*Problems, Err) callconv(.c) Code,
        &.{ "repo", "id", "ops", "n", "cancel", "out", "err" },
        "Fields: NAME (required on create), DESCRIPTION, DUE_DATE, MILESTONE_STATUS " ++
            "(COMPLETED is a GUARD problem while issues are open), plus ISSUEZ_OPT_EXPECT. " ++
            "id {NULL,0}: as a create.",
    ),
    f(
        "issuez_milestone_create",
        fn (?*Repo, OpsPtr, usize, ?*const Actor, Can, ?*?*Write, Err) callconv(.c) Code,
        &.{ "repo", "ops", "n", "actor", "cancel", "out", "err" },
        "",
    ),
    f(
        "issuez_milestone_update",
        fn (?*Repo, Str, OpsPtr, usize, ?*const Actor, Can, ?*?*Write, Err) callconv(.c) Code,
        &.{ "repo", "id", "ops", "n", "actor", "cancel", "out", "err" },
        "",
    ),

    .{ .section = .{
        "Projection",
        "Answers that need several issues: tree, blockers, progress, effective " ++
            "milestone, problems. Built from every issue, or from what one issue's " ++
            "answers need (cheaper; the same answers for that issue).",
    } },
    .{ .handles = &.{Projection} },
    f(
        "issuez_projection_build",
        fn (?*Repo, Can, ?*?*Projection, Err) callconv(.c) Code,
        &.{ "repo", "cancel", "out", "err" },
        "",
    ),
    f(
        "issuez_projection_around",
        fn (?*Repo, Str, Can, ?*?*Projection, Err) callconv(.c) Code,
        &.{ "repo", "id", "cancel", "out", "err" },
        "What one issue's answers need: the issue, its ancestors, descendants " ++
            "and blockers. Its answers are those of issuez_projection_build, but " ++
            "for whom it blocks: that needs every issue.",
    ),
    f("issuez_projection_free", fn (?*Projection) callconv(.c) void, &.{"p"}, ""),
    f(
        "issuez_projection_issues",
        fn (?*const Projection) callconv(.c) ?*const IssueList,
        &.{"p"},
        "The issues it covers, borrowed.",
    ),
    f(
        "issuez_projection_root_count",
        fn (?*const Projection) callconv(.c) usize,
        &.{"p"},
        "Roots in tree order (a broken parent makes an issue a root).",
    ),
    f(
        "issuez_projection_root_at",
        fn (?*const Projection, usize) callconv(.c) Str,
        &.{ "p", "i" },
        "",
    ),
    f(
        "issuez_projection_child_count",
        fn (?*const Projection, Str) callconv(.c) usize,
        &.{ "p", "id" },
        "",
    ),
    f(
        "issuez_projection_child_at",
        fn (?*const Projection, Str, usize) callconv(.c) Str,
        &.{ "p", "id", "i" },
        "",
    ),
    f(
        "issuez_projection_active_blocker_count",
        fn (?*const Projection, Str) callconv(.c) usize,
        &.{ "p", "id" },
        "Blockers that aren't done.",
    ),
    f(
        "issuez_projection_active_blocker_at",
        fn (?*const Projection, Str, usize) callconv(.c) Str,
        &.{ "p", "id", "i" },
        "",
    ),
    f(
        "issuez_projection_blocking_count",
        fn (?*const Projection, Str) callconv(.c) usize,
        &.{ "p", "id" },
        "Issues this one blocks.",
    ),
    f(
        "issuez_projection_blocking_at",
        fn (?*const Projection, Str, usize) callconv(.c) Str,
        &.{ "p", "id", "i" },
        "",
    ),
    f(
        "issuez_projection_progress",
        fn (?*const Projection, Str, ?*Progress) callconv(.c) bool,
        &.{ "p", "id", "out" },
        "Done and total leaves below the issue; false without sub-issues.",
    ),
    f(
        "issuez_projection_milestone_of",
        fn (?*const Projection, Str) callconv(.c) Str,
        &.{ "p", "id" },
        "Direct or through parents; {NULL,0} for none.",
    ),
    f(
        "issuez_projection_milestone_progress",
        fn (?*const Projection, Str) callconv(.c) Progress,
        &.{ "p", "milestone_id" },
        "",
    ),
    f(
        "issuez_projection_problems",
        fn (?*const Projection, Str) callconv(.c) ?*const Problems,
        &.{ "p", "id" },
        "Problems across issues (missing parent, cycle, ...); id {NULL,0} for all.",
    ),

    .{ .section = .{
        "Sync",
        "Fetch, merge and push issues and milestones with a remote. Never force-pushes " ++
            "or drops a version.",
    } },
    .{ .handles = &.{SyncReport} },
    .{ .type = SyncOutcome },
    .{ .type = SyncItem },
    f(
        "issuez_sync",
        fn (?*Repo, Str, OpsPtr, usize, Can, ?*?*SyncReport, Err) callconv(.c) Code,
        &.{ "repo", "remote", "opts", "n_opts", "cancel", "out", "err" },
        "opts: ISSUEZ_OPT_SYNC_*. OK even when some items failed or were " ++
            "quarantined: check the report.",
    ),
    f("issuez_sync_report_len", fn (?*const SyncReport) callconv(.c) usize, &.{"r"}, ""),
    f(
        "issuez_sync_report_at",
        fn (?*const SyncReport, usize) callconv(.c) ?*const SyncItem,
        &.{ "r", "i" },
        "",
    ),
    f("issuez_sync_report_ok", fn (?*const SyncReport) callconv(.c) bool, &.{"r"}, ""),
    f("issuez_sync_report_free", fn (?*SyncReport) callconv(.c) void, &.{"r"}, ""),
    .{ .prose = "Checking the issue data (git issue fsck): upstream fsck's checks on every " ++
        "issue and milestone, attachment trailers and bytes, derived attachment refs, " ++
        "quarantined remote versions, and hierarchy and blocker problems." },
    .{ .type = FsckKind },
    .{ .type = FsckFinding },
    .{ .type = FsckFlag },
    .{ .handles = &.{FsckReport} },
    f(
        "issuez_fsck",
        fn (?*Repo, u32, Can, ?*?*FsckReport, Err) callconv(.c) Code,
        &.{ "repo", "flags", "cancel", "out", "err" },
        "flags: issuez_fsck_flag bits. Without ISSUEZ_FSCK_FLAG_REPAIR nothing is written.",
    ),
    f("issuez_fsck_report_issue_count", fn (?*const FsckReport) callconv(.c) usize, &.{"r"}, ""),
    f(
        "issuez_fsck_report_milestone_count",
        fn (?*const FsckReport) callconv(.c) usize,
        &.{"r"},
        "",
    ),
    f("issuez_fsck_report_error_count", fn (?*const FsckReport) callconv(.c) usize, &.{"r"}, ""),
    f("issuez_fsck_report_len", fn (?*const FsckReport) callconv(.c) usize, &.{"r"}, ""),
    f(
        "issuez_fsck_report_at",
        fn (?*const FsckReport, usize) callconv(.c) ?*const FsckFinding,
        &.{ "r", "i" },
        "In the order the checks ran.",
    ),
    f("issuez_fsck_report_free", fn (?*FsckReport) callconv(.c) void, &.{"r"}, ""),
    .{ .prose = "Setting a remote up (git issue init): fetch refspecs that bring its " ++
        "issues, milestones and attachment refs into refs/remotes/<remote>/, where a merge " ++
        "takes them from. Optional: issuez_sync works without it." },
    .{ .type = RemoteSetup },
    .{ .type = RemoteFlag },
    f(
        "issuez_remote_default",
        fn (?*Repo, Can, ?*?*Matches, Err) callconv(.c) Code,
        &.{ "repo", "cancel", "out", "err" },
        "The remote to set up when none is named: one entry (the only remote, else " ++
            "origin), none, or every remote when there are several and none is origin.",
    ),
    f(
        "issuez_remote_configure",
        fn (?*Repo, Str, u32, Can, ?*RemoteSetup, Err) callconv(.c) Code,
        &.{ "repo", "remote", "flags", "cancel", "out", "err" },
        "Adds the refspecs remote lacks; idempotent. flags: issuez_remote_flag bits. " ++
            "NOT_FOUND for no such remote.",
    ),
    .{ .prose = "Sync status without the network: what is quarantined from a remote and what " ++
        "isn't pushed to it yet." },
    .{ .type = QuarantineReason },
    .{ .type = QuarantineChoice },
    .{ .type = Quarantined },
    .{ .handles = &.{SyncStatus} },
    f(
        "issuez_sync_status_take",
        fn (?*Repo, Str, Can, ?*?*SyncStatus, Err) callconv(.c) Code,
        &.{ "repo", "remote", "cancel", "out", "err" },
        "",
    ),
    f(
        "issuez_sync_status_quarantined_count",
        fn (?*const SyncStatus) callconv(.c) usize,
        &.{"s"},
        "",
    ),
    f(
        "issuez_sync_status_quarantined_at",
        fn (?*const SyncStatus, usize) callconv(.c) ?*const Quarantined,
        &.{ "s", "i" },
        "",
    ),
    f("issuez_sync_status_pending_count", fn (?*const SyncStatus) callconv(.c) usize, &.{"s"}, ""),
    f(
        "issuez_sync_status_pending_at",
        fn (?*const SyncStatus, usize) callconv(.c) Str,
        &.{ "s", "i" },
        "The UUID of an issue not pushed yet; quarantined ones aren't counted.",
    ),
    f("issuez_sync_status_free", fn (?*SyncStatus) callconv(.c) void, &.{"s"}, ""),
    f(
        "issuez_quarantine_resolve",
        fn (?*Repo, Str, Kind, Str, QuarantineChoice, Can, Err) callconv(.c) Code,
        &.{ "repo", "remote", "kind", "id", "choice", "cancel", "err" },
        "Keep ours, or take theirs (the replaced version is kept). INVALID_ARGUMENT for " ++
            "ISSUEZ_CHOICE_UNKNOWN.",
    ),

    .{ .section = .{
        "Push check",
        "For a server's pre-receive hook: may these ref updates be accepted? A " ++
            "judgement on the format only; the host adds its own policy (permissions, " ++
            "locks) using the verdicts.",
    } },
    .{ .handles = &.{PushVerdicts} },
    .{ .type = AuthorPolicy },
    .{ .type = RefUpdate },
    .{ .type = PushAction },
    .{ .type = PushVerdict },
    f(
        "issuez_push_check",
        fn (
            ?*Repo,
            ?[*]const RefUpdate,
            usize,
            OpsPtr,
            usize,
            Can,
            ?*?*PushVerdicts,
            Err,
        ) callconv(.c) Code,
        &.{ "repo", "updates", "n_updates", "opts", "n_opts", "cancel", "out", "err" },
        "opts: ISSUEZ_OPT_PUSHER .. ISSUEZ_OPT_ALLOW_PURGE. Reads the objects " ++
            "from the quarantine and writes nothing (format.md §11). OK when every " ++
            "verdict accepts, REJECTED otherwise (the verdicts are still set).",
    ),
    f("issuez_push_verdicts_len", fn (?*const PushVerdicts) callconv(.c) usize, &.{"v"}, ""),
    f(
        "issuez_push_verdicts_at",
        fn (?*const PushVerdicts, usize) callconv(.c) ?*const PushVerdict,
        &.{ "v", "i" },
        "",
    ),
    f(
        "issuez_push_verdict_entry_at",
        fn (?*const PushVerdict, usize) callconv(.c) ?*const Entry,
        &.{ "v", "k" },
        "The new commits of an issue as timeline entries, k < entry_count.",
    ),
    f(
        "issuez_push_verdict_attachment_at",
        fn (?*const PushVerdict, usize) callconv(.c) ?*const Attachment,
        &.{ "v", "k" },
        "An attachment the new commits add, k < attachment_count: its sha256 and size are " ++
            "the LFS object the host's store must have before it accepts the push.",
    ),
    f("issuez_push_verdicts_free", fn (?*PushVerdicts) callconv(.c) void, &.{"v"}, ""),

    .{ .section = .{
        "Purge",
        "Hard delete for moderation and legal requests. Rewrites or removes history, " ++
            "unlike everything else here, and leaves a tombstone " ++
            "(refs/issuez-purged/<uuid>) so syncs and pushes can't bring it back. Clones " ++
            "that already have the data keep it: the result says what was published.",
    } },
    .{ .handles = &.{PurgeResult} },
    f(
        "issuez_purge_issue",
        fn (?*Repo, Str, ?*const Actor, Str, Can, ?*?*PurgeResult, Err) callconv(.c) Code,
        &.{ "repo", "id", "actor", "reason", "cancel", "out", "err" },
        "",
    ),
    f(
        "issuez_purge_comment",
        fn (
            ?*Repo,
            Str,
            ?*const Oid,
            ?*const Actor,
            Str,
            Can,
            ?*?*PurgeResult,
            Err,
        ) callconv(.c) Code,
        &.{ "repo", "id", "comment", "actor", "reason", "cancel", "out", "err" },
        "Removes one comment's text and attachments; every later commit is " ++
            "rewritten, so tips change.",
    ),
    f("issuez_purge_result_free", fn (?*PurgeResult) callconv(.c) void, &.{"r"}, ""),
    f(
        "issuez_purge_result_new_tip",
        fn (?*const PurgeResult) callconv(.c) Oid,
        &.{"r"},
        "len 0: the issue is gone.",
    ),
    f(
        "issuez_purge_result_exposed_remote_count",
        fn (?*const PurgeResult) callconv(.c) usize,
        &.{"r"},
        "Remotes whose tracking refs show they had the purged commits, one synced by URL " ++
            "or path as the url-<hash> its refs are kept under. The next issuez_sync with " ++
            "each replaces their copy (leased on what it fetched).",
    ),
    f(
        "issuez_purge_result_exposed_remote_at",
        fn (?*const PurgeResult, usize) callconv(.c) Str,
        &.{ "r", "i" },
        "",
    ),
    f(
        "issuez_purge_result_attachment_count",
        fn (?*const PurgeResult) callconv(.c) usize,
        &.{"r"},
        "The attachments the purge took out of history: a host drops its copies of " ++
            "their bytes.",
    ),
    f(
        "issuez_purge_result_attachment_at",
        fn (?*const PurgeResult, usize) callconv(.c) Str,
        &.{ "r", "i" },
        "A UUID.",
    ),

    .{ .section = .{
        "Op helpers",
        "issuez_<verb>_<field>, issuez_q_<query option>, issuez_opt_<open option>, " ++
            "issuez_expect: one static inline function per op, typed and named for its " ++
            "value. Conveniences for C; bindings build issuez_op themselves.",
    } },
    .{ .helpers = &helpers },
};

pub const helpers = [_]Helper{
    h(.set, "title", .str, .{}),
    h(.set, "description", .str, .{}),
    h(.set, "comment", .str, .{}),
    h(.set, "state", .str, .{}),
    h(.set, "fixed_by", .str, .{}),
    h(.set, "release", .str, .{}),
    h(.set, "reason", .str, .{}),
    h(.set, "workflow_state", .str, .{}),
    h(.clear, "workflow_state", .none, .{}),
    h(.add, "labels", .str, .{}),
    h(.remove, "labels", .str, .{}),
    h(.clear, "labels", .none, .{}),
    h(.add, "assignees", .person, .{}),
    h(.remove, "assignees", .person, .{}),
    h(.clear, "assignees", .none, .{}),
    h(.set, "priority", .num, .{ .num_type = "issuez_priority", .param = "priority" }),
    h(.clear, "priority", .none, .{}),
    h(.set, "milestone", .str, .{}),
    h(.inherit, "milestone", .none, .{}),
    h(.clear, "milestone", .none, .{}),
    h(.set, "parent", .str, .{}),
    h(.clear, "parent", .none, .{}),
    h(.add, "blocked_by", .str, .{ .name = "issuez_add_blocker" }),
    h(.remove, "blocked_by", .str, .{ .name = "issuez_remove_blocker" }),
    h(.set, "start_date", .date, .{}),
    h(.clear, "start_date", .none, .{}),
    h(.set, "due_date", .date, .{}),
    h(.clear, "due_date", .none, .{}),
    h(.set, "estimate", .num, .{}),
    h(.clear, "estimate", .none, .{}),
    h(.set, "deleted", .num, .{ .num_type = "bool", .param = "deleted" }),
    h(.set, "number", .num, .{}),
    h(.set, "name", .str, .{}),
    h(.set, "milestone_status", .num, .{
        .num_type = "issuez_milestone_status",
        .param = "status",
    }),
    h(.set, "extra", .name_str, .{}),
    h(.set, "expect", .oid, .{ .name = "issuez_expect" }),
    h(.set, "subject", .str, .{ .name = "issuez_set_subject" }),
    h(.add, "q_label", .str, .{}),
    h(.add, "q_not_label", .str, .{}),
    h(.add, "q_assignee", .str, .{}),
    h(.add, "q_state", .str, .{}),
    h(.set, "q_done", .num, .{ .param = "done" }),
    h(.set, "q_limit", .num, .{}),
    h(.set, "q_after", .str, .{}),
    h(.set, "git_path", .str, .{}),
    h(.set, "committer", .committer, .{}),
    h(.set, "pool_size", .num, .{}),
    h(.set, "pusher", .person, .{}),
    h(.add, "pusher_email", .str, .{}),
    h(.set, "author_policy", .num, .{ .num_type = "issuez_author_policy", .param = "policy" }),
    h(.set, "allow_numbers", .num, .{ .num_type = "bool", .param = "allow" }),
    h(.set, "allow_purge", .num, .{ .num_type = "bool", .param = "allow" }),
    h(.add, "pusher_user_id", .str, .{}),
    h(.set, "object_dir", .str, .{}),
    h(.set, "alternate_object_dirs", .str, .{}),
    h(.set, "ref", .str, .{}),
    h(.clear, "ref", .none, .{}),
    h(.set, "locked", .num_str, .{ .num_type = "bool", .param = "locked", .param2 = "reason" }),
    h(.add, "attachments", .attachment, .{}),
    h(.remove, "attachments", .str, .{}),
    h(.set, "original_author", .str, .{ .name = "issuez_set_original_author" }),
    h(.set, "original_id", .str, .{ .name = "issuez_set_original_id" }),
    h(.set, "edit_comment", .oid, .{ .name = "issuez_edit_comment" }),
    h(.set, "expect_edits", .num, .{ .name = "issuez_expect_edits" }),
    h(.set, "delete_comment", .oid, .{ .name = "issuez_delete_comment" }),
    h(.set, "restore_comment", .oid, .{ .name = "issuez_restore_comment" }),
    h(.add, "reactions", .str, .{}),
    h(.remove, "reactions", .str, .{}),
    h(.set, "reaction_target", .oid, .{ .name = "issuez_reaction_target" }),
    h(.set, "q_deleted", .num, .{ .param = "deleted" }),
    h(.add, "q_workflow_state", .str, .{}),
    h(.set, "q_no_labels", .none, .{}),
    h(.add, "q_author", .str, .{}),
    h(.add, "q_priority", .num, .{ .num_type = "issuez_priority", .param = "priority" }),
    h(.add, "q_milestone", .str, .{}),
    h(.set, "q_parent", .str, .{}),
    h(.set, "q_blocked", .num, .{ .num_type = "bool", .param = "blocked" }),
    h(.set, "q_updated", .num_num2, .{ .param = "after", .param2 = "before" }),
    h(.set, "q_text", .str_num, .{ .param = "text", .num2_type = "bool", .param2 = "ignore_case" }),
    h(.set, "q_order", .num_num2, .{
        .num_type = "issuez_sort",
        .param = "sort",
        .num2_type = "bool",
        .param2 = "ascending",
    }),
    h(.set, "env", .name_str, .{}),
    h(.add, "done_state", .str, .{}),
    h(.add, "opt:workflow_state", .str, .{}),
    h(.add, "exclusive_scope", .str, .{}),
    h(.add, "extra_prefix", .str, .{}),
    h(.set, "timeout_local_ms", .num, .{}),
    h(.set, "timeout_network_ms", .num, .{}),
    h(.set, "limit", .name_num, .{ .param = "value" }),
    h(.set, "cache_issues", .num, .{}),
    h(.set, "attachment_store", .num, .{ .num_type = "bool", .param = "store" }),
    h(.set, "sync_push", .num, .{ .num_type = "bool", .param = "push" }),
    h(.set, "sync_attachments", .num, .{ .num_type = "bool", .param = "attachments" }),
};

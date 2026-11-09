/*
 * issuez.h - C API of git-native-issuez.
 *
 * Issues stored in git (refs/issues/<uuid>), compatible with
 * git-native-issue format 1. Meant to be wrapped by bindings (Go, Rust,
 * Python, Node) and usable from plain C.
 *
 * Generated from src/capi/api.zig by src/capi/gen.zig: don't edit.
 *
 * --------------------------------- Conventions ---------------------------------
 *
 * Status codes
 *   Fallible functions return issuez_code: ISSUEZ_OK (0) or an
 *   ISSUEZ_E_* code, so a switch over it can warn on a missing case.
 *   Their last parameter is `issuez_error **err`. Pass NULL to ignore the
 *   details; otherwise *err is set on failure (free with issuez_error_free)
 *   and left untouched on success. Accessors on loaded objects never fail
 *   and take no err.
 *
 * Ownership
 *   - Every handle a function hands back through an out parameter
 *     (`issuez_x **out`) is owned by the caller: free it with that type's
 *     issuez_x_free (NULL is a no-op). The exception says so: the repo is
 *     closed with issuez_repo_close.
 *   - Everything an accessor returns (strings, `const T *` records, list
 *     items) is borrowed from the handle it came from and lives until that
 *     handle is freed.
 *   - Handles that need the repo keep it alive, so handles may be freed in
 *     any order, from any thread; issuez_repo_close drops the caller's
 *     reference.
 *
 * Types
 *   - Value types (issuez_str, issuez_oid, issuez_time, issuez_date,
 *     issuez_person) are frozen and copied freely.
 *   - Records the library returns (issue and milestone info, comments,
 *     entries, problems, ...) only ever grow at the end: read them through
 *     the pointer, never copy one by value, never allocate one. Nested lists
 *     are read with *_count and *_at accessors, never as arrays of records.
 *   - Inputs the caller allocates (issuez_op, issuez_actor,
 *     issuez_ref_update) are frozen and carry reserved space: zero it.
 *   - Enum-valued fields of structs are uint32_t; the enums give the
 *     values. Every enum has *_UNKNOWN = 0 (or OFF/OK) and may gain values
 *     in minor versions: handle unknown values.
 *
 * Strings
 *   issuez_str is ptr+len, UTF-8 (not validated where git doesn't), and
 *   every string the library returns is also NUL-terminated (ptr[len] ==
 *   0). An absent optional string is {NULL, 0}; an empty one is {"", 0}.
 *   Inputs are read during the call only and never retained; for inputs
 *   {NULL,0} and {"",0} mean the same.
 *
 * Writes
 *   A write is one commit: a comment, a state change (with FIXED_BY,
 *   RELEASE, REASON) and field edits together. A delete or restore is a
 *   commit of its own, and a description edit can't carry a comment;
 *   those combinations fail with ISSUEZ_E_INVALID_VALUE, problem INCOMPATIBLE.
 *
 * Op lists (writes, queries, options)
 *   Calls taking several optional values take an array of issuez_op: a
 *   verb (SET, CLEAR, ADD, REMOVE, INHERIT), a target (an issuez_field or
 *   an issuez_opt) and the value in the slot the target names (str, num,
 *   num2, date, oid, person, name). There are no builder objects: a
 *   static inline helper builds each op (issuez_set_title, issuez_add_label,
 *   issuez_q_done, issuez_opt_git_path, ...). Use the helpers; the struct
 *   is the ABI under them. examples/c/quickstart.c shows the idiom.
 *   - Ops apply in order; a later op on the same scalar wins. A set is
 *     replaced by CLEAR followed by ADDs.
 *   - Unused slots must be zero: start from ISSUEZ_OP_INIT or a helper.
 *   - Nothing is checked until the call, which then reports every problem
 *     at once (ISSUEZ_E_INVALID_VALUE), each with the index of its op.
 *     issuez_ops_validate checks the format alone, without a repo.
 *
 * Names
 *   issuez_<handle>_<verb>, the verb saying what a call does:
 *   - _open, _close        the repo (issuez_repo_open, issuez_repo_close)
 *   - _new                 a handle built from what the call is given
 *                          (issuez_cancel_new)
 *   - _load*               an issue or milestone, read from git
 *   - _info_of             a handle's single values, one record
 *                          (issuez_issue_info_of, issuez_milestone_info_of)
 *   - _take                a value read off the repo into a handle
 *                          (issuez_snapshot_take)
 *   - plain verbs          operations (issuez_query_run, issuez_issue_update)
 *   - _free                every other handle
 *   - _len, _at            the items of a list handle
 *   - _<item>_count, _<item>_at
 *                          a list inside another handle
 *                          (issuez_issue_label_count);
 *                          a _count without an _at is a plain number
 *
 * Optional values
 *   Optional strings are an issuez_str, {NULL,0} when absent; optional
 *   objects (oids, actors) a pointer, NULL when absent.
 *
 * Threads
 *   An issuez_repo is safe to use from any number of threads at once; it
 *   keeps a pool of git sessions. Loaded objects are immutable and can be
 *   read from any thread. issuez_repo_close may come while other threads'
 *   calls on the repo run: each holds the repo until it returns. It must
 *   not race a call's start: a call made after it, or at the same time,
 *   uses a freed repo.
 *
 * Blocking, cancellation and signals
 *   Calls that touch git block. They take an `issuez_cancel *` (may be
 *   NULL): triggering it from any thread makes the call return
 *   ISSUEZ_E_CANCELLED within about 50 ms, killing a git request that is
 *   running. Writes are atomic: a write that returns
 *   CANCELLED didn't happen (a ref update, once started, isn't
 *   interrupted), and one whose commit landed returns OK, memory left
 *   or not: its receipt is allocated first, and its entry may then
 *   lack its changes and author. Two exceptions, where a failed call
 *   may have written: GIT when git's answer to the ref update couldn't
 *   be read, and an issuez_purge_comment that can't read the issue
 *   back. Reload to see which. The library
 *   installs no signal handlers. It writes to
 *   pipes, so a host must not die of SIGPIPE: ignore it, or handle it as
 *   the Go runtime does.
 *
 * IDs
 *   Operations take full canonical UUIDs (lowercase, hyphenated). Turn
 *   user input ("a7f3", "#12") into one with issuez_resolve_one. Versions and
 *   commits are issuez_oid values.
 */
#ifndef ISSUEZ_H
#define ISSUEZ_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------- Version and init --------------------------------- */

#define ISSUEZ_VERSION_MAJOR 0
#define ISSUEZ_VERSION_MINOR 4
#define ISSUEZ_VERSION_PATCH 0
/* Major in the high 16 bits, minor in the low 16. The library accepts a
 * header with the same major and a minor <= its own; before 1.0 the minor
 * must match. */
#define ISSUEZ_ABI_VERSION ((ISSUEZ_VERSION_MAJOR << 16) | ISSUEZ_VERSION_MINOR)

typedef struct issuez_error issuez_error;
typedef struct issuez_write issuez_write;
typedef struct issuez_milestone issuez_milestone;

typedef enum issuez_code {
    ISSUEZ_OK = 0,
    ISSUEZ_E_ABI = 1, /* header/library mismatch */
    ISSUEZ_E_INVALID_ARGUMENT = 2, /* NULL handle, malformed UUID or oid, ... */
    ISSUEZ_E_INVALID_VALUE = 3, /* a value breaks a format rule; see problems */
    ISSUEZ_E_LIMIT = 4, /* over a limit (title bytes, labels, ...) */
    ISSUEZ_E_NOT_FOUND = 5,
    ISSUEZ_E_AMBIGUOUS = 6, /* resolve: several matches */
    ISSUEZ_E_VERSION_MISMATCH = 7, /* an expected tip didn't match (HTTP 409) */
    ISSUEZ_E_GUARD = 8, /* a hierarchy or milestone rule refused it; see problems */
    ISSUEZ_E_CONTENDED = 9, /* still racing after the retry budget (limit cas_retries): final */
    ISSUEZ_E_PURGED = 10, /* the issue was purged; it can't come back */
    ISSUEZ_E_CORRUPT = 11, /* history that can't be read as an issue */
    ISSUEZ_E_REJECTED = 12, /* push check refused at least one ref */
    ISSUEZ_E_NOT_A_REPOSITORY = 13,
    ISSUEZ_E_GIT = 14, /* git failed; see the error's git stderr */
    ISSUEZ_E_GIT_VERSION = 15, /* git older than 2.30 */
    ISSUEZ_E_TIMEOUT = 16,
    ISSUEZ_E_CANCELLED = 17,
    ISSUEZ_E_LFS = 18, /* git-lfs missing or a transfer failed */
    ISSUEZ_E_UNSUPPORTED = 19, /* not in this build, or not possible here */
    ISSUEZ_E_NOMEM = 20,
    ISSUEZ_E_INTERNAL = 21, /* a bug: please report */
} issuez_code;

/*
 * "1.2.3", or "1.2.3-12-ga3e21cfa" built from a git checkout past the tag.
 * Static storage.
 */
const char *issuez_version(void);

/*
 * Checks that the header and the library match: ISSUEZ_E_ABI when they don't.
 * Optional: the first call of any function initialises the library; further
 * calls are cheap no-ops.
 */
issuez_code issuez_init(uint32_t abi_version, issuez_error **err);


/* ---------------------------------------- Basic types -------------------------------------- */

typedef struct issuez_str {
    const char *ptr;
    size_t len;
} issuez_str;

/* From a C literal or a NUL-terminated string. */
#ifdef __cplusplus
#define ISSUEZ_STR(lit) (issuez_str{ (lit), sizeof(lit) - 1 })
#else
#define ISSUEZ_STR(lit) ((issuez_str){ (lit), sizeof(lit) - 1 })
#endif
static inline issuez_str issuez_str_c(const char *s) {
    issuez_str r;
    r.ptr = s;
    r.len = 0;
    if (s) while (s[r.len]) r.len++;
    return r;
}

/*
 * A git object ID: SHA-1 or SHA-256. A value type: copy it freely.
 */
typedef struct issuez_oid {
    uint8_t len; /* 20 (SHA-1), 32 (SHA-256), 0: none */
    uint8_t bytes[32];
} issuez_oid;

/*
 * A point in time as git records it.
 */
typedef struct issuez_time {
    int64_t unix_seconds;
    int16_t tz_offset_minutes; /* east of UTC: +0130 is 90 */
} issuez_time;

/*
 * A calendar day (start and due dates).
 */
typedef struct issuez_date {
    int16_t year;
    uint8_t month; /* 1..12 */
    uint8_t day; /* 1..31 */
} issuez_date;

/*
 * A person as stored in git.
 */
typedef struct issuez_person {
    issuez_str name; /* {NULL,0} for assignees, which store no name */
    issuez_str email;
    issuez_str user_id; /* the host's stable identity, a UUID; {NULL,0} when none */
} issuez_person;

/*
 * The acting user of a write: the commit's author. The committer is the
 * identity the repo was opened with. Name and email can't hold <, >, a newline
 * or a NUL, and the time zone is less than a day off UTC: else the write fails
 * with INVALID_ARGUMENT.
 */
typedef struct issuez_actor {
    issuez_str name;
    issuez_str email;
    issuez_str user_id; /* optional UUID: X-Author-Id on every commit the call writes */
    const issuez_time *at; /* NULL: now, in UTC */
    uint64_t reserved[4]; /* zero */
} issuez_actor;


/* ---------------------------------------- Errors and problems ------------------------------ */

/*
 * Static and stable, e.g. "VERSION_MISMATCH".
 */
const char *issuez_code_name(issuez_code code);

typedef struct issuez_problems issuez_problems;

void issuez_error_free(issuez_error *err);

issuez_code issuez_error_code(const issuez_error *err);

/*
 * One sentence for humans, English, no trailing newline.
 */
issuez_str issuez_error_message(const issuez_error *err);

/*
 * What it is about, when known: an issue UUID, a ref, a field key.
 */
issuez_str issuez_error_subject(const issuez_error *err);

/*
 * git's stderr (trimmed, bounded), for GIT and LFS.
 */
issuez_str issuez_error_git_stderr(const issuez_error *err);

/*
 * VERSION_MISMATCH: the issue's tip now.
 */
bool issuez_error_current_tip(const issuez_error *err, issuez_oid *out);

/*
 * INVALID_VALUE and GUARD carry every problem found. May be NULL.
 */
const issuez_problems *issuez_error_problems(const issuez_error *err);

/*
 * A write that failed after its commit landed: its receipt, borrowed from err.
 * NULL in this version: a cancelled write didn't happen, and one whose commit
 * landed returns OK (see Blocking, cancellation and signals).
 */
const issuez_write *issuez_error_write(const issuez_error *err);

typedef enum issuez_problem_kind {
    ISSUEZ_PROBLEM_UNKNOWN = 0,
    ISSUEZ_PROBLEM_EMPTY = 1, /* a title or text that is blank */
    ISSUEZ_PROBLEM_NEWLINE = 2, /* LF/CR in a single-line value */
    ISSUEZ_PROBLEM_TOO_LONG = 3,
    ISSUEZ_PROBLEM_TOO_MANY = 4,
    ISSUEZ_PROBLEM_BAD_FORMAT = 5, /* date, email, state slug, UUID, ... */
    ISSUEZ_PROBLEM_TRAILER_BODY = 6, /* text whose last paragraph would read as trailers */
    ISSUEZ_PROBLEM_UNKNOWN_WORKFLOW_STATE = 7,
    ISSUEZ_PROBLEM_READ_ONLY_FIELD = 8, /* e.g. a number that is already set */
    ISSUEZ_PROBLEM_UNKNOWN_TARGET = 9, /* target not valid in this op list */
    ISSUEZ_PROBLEM_BAD_VERB = 10, /* e.g. ADD on a scalar */
    ISSUEZ_PROBLEM_MISSING_VALUE = 11, /* the target's slot is empty */
    ISSUEZ_PROBLEM_INCOMPATIBLE = 12, /* these ops can't share one commit */
    ISSUEZ_PROBLEM_SELF_REFERENCE = 13,
    ISSUEZ_PROBLEM_CYCLE = 14,
    ISSUEZ_PROBLEM_TOO_DEEP = 15,
    ISSUEZ_PROBLEM_MISSING_TARGET = 16, /* parent, blocker or milestone not there */
    ISSUEZ_PROBLEM_DELETED_TARGET = 17,
    ISSUEZ_PROBLEM_OPEN_CHILDREN = 18, /* closing or deleting with live sub-issues */
    ISSUEZ_PROBLEM_CLOSED_ANCESTOR = 19, /* opening work under a closed parent */
    ISSUEZ_PROBLEM_MILESTONE_CLOSED = 20, /* completed or retired */
    ISSUEZ_PROBLEM_MILESTONE_OPEN_WORK = 21,
    ISSUEZ_PROBLEM_DUPLICATE_NUMBER = 22,
    ISSUEZ_PROBLEM_CONFLICT = 23, /* concurrent setters disagree (reads) */
    ISSUEZ_PROBLEM_INVALID_STORED_VALUE = 24, /* a stored value that doesn't parse (reads) */
    ISSUEZ_PROBLEM_PENDING_EVENT = 25, /* an event whose comment hasn't arrived (reads) */
    /* fails fsck, can't be read, or has an X-Rewritten-From that names one of its commits (push check) */
    ISSUEZ_PROBLEM_INVALID_HISTORY = 26,
    ISSUEZ_PROBLEM_UNSUPPORTED_FORMAT = 27, /* a Format-Version other than 1 (push check) */
    ISSUEZ_PROBLEM_NON_FAST_FORWARD = 28, /* the new tip doesn't contain the old (push check) */
    ISSUEZ_PROBLEM_REF_DELETED = 29, /* a delete no purge allows (push check) */
    ISSUEZ_PROBLEM_LOCAL_REF = 30, /* refs/issuez-* that never leave a clone (push check) */
    ISSUEZ_PROBLEM_BAD_REF_NAME = 31, /* not a UUID under an issuez prefix (push check) */
    ISSUEZ_PROBLEM_AUTHOR_MISMATCH = 32, /* a new commit not by the pusher (push check) */
    ISSUEZ_PROBLEM_PURGED = 33, /* purged issue or text coming back (push check) */
    ISSUEZ_PROBLEM_PURGE_NOT_ALLOWED = 34, /* a purge without ISSUEZ_OPT_ALLOW_PURGE (push check) */
    ISSUEZ_PROBLEM_NOT_A_PURGE = 35, /* a tombstone commit that doesn't read as one (push check) */
    ISSUEZ_PROBLEM_NOT_DERIVED = 36, /* an attachments commit that isn't derived (push check) */
} issuez_problem_kind;

typedef enum issuez_field {
    ISSUEZ_FIELD_UNKNOWN = 0,
    ISSUEZ_FIELD_TITLE = 1,
    ISSUEZ_FIELD_DESCRIPTION = 2,
    ISSUEZ_FIELD_COMMENT = 3,
    ISSUEZ_FIELD_STATE = 4,
    ISSUEZ_FIELD_WORKFLOW_STATE = 5,
    ISSUEZ_FIELD_LABELS = 6,
    ISSUEZ_FIELD_ASSIGNEES = 7,
    ISSUEZ_FIELD_PRIORITY = 8,
    ISSUEZ_FIELD_MILESTONE = 9,
    ISSUEZ_FIELD_PARENT = 10,
    ISSUEZ_FIELD_BLOCKED_BY = 11,
    ISSUEZ_FIELD_START_DATE = 12,
    ISSUEZ_FIELD_DUE_DATE = 13,
    ISSUEZ_FIELD_ESTIMATE = 14,
    ISSUEZ_FIELD_NUMBER = 15,
    ISSUEZ_FIELD_LOCKED = 16,
    ISSUEZ_FIELD_REF = 17,
    ISSUEZ_FIELD_DELETED = 18,
    ISSUEZ_FIELD_FIXED_BY = 19,
    ISSUEZ_FIELD_RELEASE = 20,
    ISSUEZ_FIELD_REASON = 21,
    /* writes: ADD str = the image's bytes, name = its file name, id = its v4 UUID if the caller chooses it; REMOVE str = a UUID */
    ISSUEZ_FIELD_ATTACHMENTS = 22,
    /* update: ADD str = an emoji, REMOVE str takes it back; alone, with REACTION_TARGET for a comment, EXPECT and SUBJECT */
    ISSUEZ_FIELD_REACTIONS = 23,
    ISSUEZ_FIELD_NAME = 24, /* milestones */
    ISSUEZ_FIELD_MILESTONE_STATUS = 25,
    ISSUEZ_FIELD_EXTRA = 26, /* a host field (X-Forgejo-*) or another unknown trailer */
    /* timeline only: the lock's reason changed (the LOCKED change of the same commit carries it too) */
    ISSUEZ_FIELD_LOCK_REASON = 27,
} issuez_field;

/*
 * Trailer key ("Labels", "X-Due-Date"), static storage.
 */
const char *issuez_field_key(issuez_field field);

typedef struct issuez_problem {
    uint32_t kind; /* issuez_problem_kind */
    uint32_t field; /* issuez_field: what the caller should highlight */
    issuez_str key; /* trailer key, for ISSUEZ_FIELD_EXTRA */
    issuez_str value; /* the offending value, when there is one */
    issuez_str subject; /* the other issue or milestone UUID involved */
    issuez_str message; /* human-readable */
    int64_t op_index; /* the op that caused it; -1 when not from an op */
} issuez_problem;

size_t issuez_problems_len(const issuez_problems *p);

const issuez_problem *issuez_problems_at(const issuez_problems *p, size_t i);

/*
 * Only for lists returned as owned (`issuez_problems **out`).
 */
void issuez_problems_free(issuez_problems *p);


/* ---------------------------------------- Op lists ----------------------------------------- */
/*
 * See "Op lists" in the conventions. Write targets, their slots and verbs:
 *   TITLE, DESCRIPTION, COMMENT, STATE, FIXED_BY, RELEASE, REASON, NAME  SET str
 *   REF                        SET str, CLEAR
 *   WORKFLOW_STATE             SET str, CLEAR (default)
 *   LABELS, BLOCKED_BY         ADD/REMOVE str, CLEAR
 *   ASSIGNEES                  ADD/REMOVE person, CLEAR
 *   PRIORITY                   SET num (issuez_priority), CLEAR
 *   MILESTONE                  SET str (UUID), CLEAR, INHERIT
 *   PARENT                     SET str (UUID), CLEAR
 *   START_DATE, DUE_DATE       SET date, CLEAR
 *   ESTIMATE                   SET num (minutes), CLEAR
 *   LOCKED                     SET num (0/1), str (reason)
 *   DELETED                    SET num (0/1): soft delete and restore
 *   NUMBER                     SET num, write-once
 *   MILESTONE_STATUS           SET num (issuez_milestone_status)
 *   EXTRA                      SET name, str ("" clears)
 * DESCRIPTION on create is the body; on update a description-edit event,
 * which can't share a commit with COMMENT. COMMENT on create is INCOMPATIBLE.
 */

typedef enum issuez_verb {
    ISSUEZ_OP_UNKNOWN = 0,
    ISSUEZ_OP_SET = 1, /* scalar or option: the value */
    ISSUEZ_OP_CLEAR = 2, /* scalar: none; set: empty; option: default */
    ISSUEZ_OP_ADD = 3, /* set or list option: one member */
    ISSUEZ_OP_REMOVE = 4, /* set: one member */
    ISSUEZ_OP_INHERIT = 5, /* milestone: follow the parent's */
} issuez_verb;

typedef enum issuez_opt {
    ISSUEZ_OPT_UNKNOWN = 0,
    ISSUEZ_OPT_EXPECT = 256, /* writes: oid. Fail with VERSION_MISMATCH if the tip isn't this */
    ISSUEZ_OPT_SUBJECT = 257, /* writes: str. Commit subject where the library picks one */
    ISSUEZ_OPT_ORIGINAL_AUTHOR = 258, /* writes: str. Provenance for imports; not an issue field */
    ISSUEZ_OPT_ORIGINAL_ID = 259, /* writes: str */
    /* update: oid. The write edits this comment instead: COMMENT SET is its new text, with ATTACHMENTS, EXPECT and SUBJECT */
    ISSUEZ_OPT_EDIT_COMMENT = 260,
    /* update: num. Fail with VERSION_MISMATCH unless the text the write edits (the description with SET DESCRIPTION, the comment with EDIT_COMMENT) was edited exactly this often (its EDIT revisions): a form's version of the text, which other changes to the issue don't touch */
    ISSUEZ_OPT_EXPECT_EDITS = 261,
    /* update: oid. The write hides this comment instead; only EXPECT and SUBJECT go with it */
    ISSUEZ_OPT_DELETE_COMMENT = 262,
    /* update: oid. The write shows this hidden comment again; only EXPECT and SUBJECT go with it */
    ISSUEZ_OPT_RESTORE_COMMENT = 263,
    /* update: oid. The comment REACTIONS ADD or REMOVE is on; without it, the issue */
    ISSUEZ_OPT_REACTION_TARGET = 264,
    /* ADD str: "<id> <media_type> <size> sha256:<sha256> <name>", from issuez_prepared_attachment_info; external storage only */
    ISSUEZ_OPT_PREPARED_ATTACHMENT = 265,
    ISSUEZ_OPT_Q_DONE = 512, /* query: num 0 not done (default), 1 done, -1 any */
    ISSUEZ_OPT_Q_DELETED = 513, /* query: num 0 (default), 1, -1 */
    ISSUEZ_OPT_Q_STATE = 514, /* query: ADD str; members OR */
    ISSUEZ_OPT_Q_WORKFLOW_STATE = 515, /* query: ADD str; OR */
    ISSUEZ_OPT_Q_LABEL = 516, /* query: ADD str; must have all */
    ISSUEZ_OPT_Q_NOT_LABEL = 517, /* query: ADD str; must have none */
    ISSUEZ_OPT_Q_NO_LABELS = 518, /* query: SET */
    ISSUEZ_OPT_Q_ASSIGNEE = 519, /* query: ADD str, an email or user id, "" unassigned; OR */
    ISSUEZ_OPT_Q_AUTHOR = 520, /* query: ADD str; OR */
    ISSUEZ_OPT_Q_PRIORITY = 521, /* query: ADD num (issuez_priority); OR */
    ISSUEZ_OPT_Q_MILESTONE = 522, /* query: ADD str, the effective milestone, "" none; OR */
    ISSUEZ_OPT_Q_PARENT = 523, /* query: SET str */
    ISSUEZ_OPT_Q_BLOCKED = 524, /* query: SET num 1 actively blocked, 0 not */
    ISSUEZ_OPT_Q_UPDATED = 525, /* query: SET num after, num2 before (unix; 0 open end) */
    ISSUEZ_OPT_Q_TEXT = 526, /* query: SET str, a fixed string; num 1 ignores case */
    ISSUEZ_OPT_Q_ORDER = 527, /* query: SET num (issuez_sort), num2 1 ascending */
    ISSUEZ_OPT_Q_LIMIT = 528, /* query: SET num (default 100) */
    ISSUEZ_OPT_Q_AFTER = 529, /* query: SET str, a cursor from issuez_issue_list_next_cursor */
    ISSUEZ_OPT_GIT_PATH = 768, /* open: str. Default "git" from PATH */
    /* open: SET name=str; CLEAR without name starts empty. Default: the process environment */
    ISSUEZ_OPT_ENV = 769,
    /* open: person (name, email), without <, >, newline or NUL. Default: git's identity */
    ISSUEZ_OPT_COMMITTER = 770,
    ISSUEZ_OPT_DONE_STATE = 771, /* open: ADD str; overrides git config issue.doneStates */
    ISSUEZ_OPT_WORKFLOW_STATE = 772, /* open: ADD str; overrides issue.workflowStates */
    /* open: ADD str; one "scope/x" label per issue: adding one takes the others off, two in one write are refused */
    ISSUEZ_OPT_EXCLUSIVE_SCOPE = 773,
    ISSUEZ_OPT_EXTRA_PREFIX = 774, /* open: ADD str; allowed EXTRA keys (default "X-Forgejo-") */
    ISSUEZ_OPT_POOL_SIZE = 775, /* open: num; concurrent git sessions (default 4) */
    ISSUEZ_OPT_TIMEOUT_LOCAL_MS = 776, /* open: num */
    ISSUEZ_OPT_LIMIT = 777, /* open: name ("max_labels", ...), num */
    /* open: num; issues kept loaded for queries (default 10000, 0 off) */
    ISSUEZ_OPT_CACHE_ISSUES = 778,
    /* open: num 0/1 (default 1). 0: the caller keeps attachment bytes (a host's LFS store); writes store none and need no git-lfs */
    ISSUEZ_OPT_ATTACHMENT_STORE = 779,
    ISSUEZ_OPT_PUSHER = 1280, /* push check: person; its user_id counts as pusher_user_id */
    ISSUEZ_OPT_PUSHER_EMAIL = 1281, /* push check: ADD str, the pusher's other verified emails */
    ISSUEZ_OPT_AUTHOR_POLICY = 1282, /* push check: num (issuez_author_policy) */
    ISSUEZ_OPT_ALLOW_NUMBERS = 1283, /* push check: num 0/1 (default 0) */
    ISSUEZ_OPT_OBJECT_DIR = 1284, /* push check: str, the quarantine's GIT_OBJECT_DIRECTORY */
    ISSUEZ_OPT_ALTERNATE_OBJECT_DIRS = 1285, /* push check: str, GIT_ALTERNATE_OBJECT_DIRECTORIES */
    /* push check: num 0/1 (default 0), the pusher may push tombstones */
    ISSUEZ_OPT_ALLOW_PURGE = 1286,
    /* push check: ADD str, the pusher's UUIDs: under the author policy, a new commit's X-Author-Id must be one */
    ISSUEZ_OPT_PUSHER_USER_ID = 1287,
} issuez_opt;

typedef struct issuez_op {
    uint32_t verb; /* issuez_verb */
    uint32_t target; /* issuez_field or issuez_opt */
    issuez_str name; /* EXTRA key, ENV variable, LIMIT name, ATTACHMENTS file name */
    issuez_str str;
    int64_t num; /* integers, enums, flags (0/1), unix seconds */
    int64_t num2;
    issuez_date date;
    issuez_oid oid;
    issuez_person person;
    issuez_str id; /* ADD ATTACHMENTS: the v4 UUID to give it (empty: one is picked) */
    uint64_t reserved[2]; /* zero */
} issuez_op;

#ifdef __cplusplus
#define ISSUEZ_OP_INIT {}
#else
#define ISSUEZ_OP_INIT { 0 }
#endif
#define ISSUEZ_COUNT(arr) (sizeof(arr) / sizeof((arr)[0]))

typedef enum issuez_op_list {
    ISSUEZ_LIST_UNKNOWN = 0,
    ISSUEZ_LIST_ISSUE_CREATE = 1,
    ISSUEZ_LIST_ISSUE_UPDATE = 2,
    ISSUEZ_LIST_MILESTONE_CREATE = 3,
    ISSUEZ_LIST_MILESTONE_UPDATE = 4,
    ISSUEZ_LIST_QUERY = 5,
    ISSUEZ_LIST_OPEN = 6,
    ISSUEZ_LIST_PUSH_CHECK = 7,
} issuez_op_list;

/*
 * Format rules only (no repo): verbs, slots, value grammar, default limits.
 * *out is an empty list when everything is fine.
 */
issuez_code issuez_ops_validate(issuez_op_list list, const issuez_op *ops, size_t n,
                                issuez_problems **out, issuez_error **err);

/*
 * Helpers that build each op are at the end, under "Op helpers", after the
 * enums they take.
 */

/* ---------------------------------------- Cancel and logging ------------------------------- */

typedef struct issuez_cancel issuez_cancel;

/*
 * NULL when out of memory.
 */
issuez_cancel *issuez_cancel_new(void);

/*
 * Thread-safe and idempotent; affects every call using this token.
 */
void issuez_cancel_trigger(issuez_cancel *c);

void issuez_cancel_free(issuez_cancel *c);

typedef enum issuez_log_level {
    ISSUEZ_LOG_OFF = 0,
    ISSUEZ_LOG_ERROR = 1,
    ISSUEZ_LOG_WARN = 2,
    ISSUEZ_LOG_INFO = 3,
    ISSUEZ_LOG_DEBUG = 4, /* one event per git request */
    ISSUEZ_LOG_TRACE = 5,
} issuez_log_level;

typedef struct issuez_log_event {
    uint32_t level; /* issuez_log_level */
    issuez_str operation; /* "issue.update", "git.cat-file", "repo.open" */
    issuez_str message;
    issuez_str repo_path; /* {NULL,0} when not about a repo */
    issuez_str subject; /* issue/milestone UUID or ref, if any */
    int64_t duration_ns; /* -1 when not a timed step */
    uint32_t attempt; /* retry number, 0 for the first */
} issuez_log_event;

typedef void (*issuez_log_fn)(void *userdata, const issuez_log_event *event);

/*
 * Process-wide. Called from any thread, possibly concurrently; the event lives
 * only during the call. Must not call back into issuez. NULL cb disables.
 */
void issuez_set_logger(issuez_log_level min_level, issuez_log_fn cb, void *userdata);


/* ---------------------------------------- Repo --------------------------------------------- */

typedef struct issuez_repo issuez_repo;

/*
 * path: a work tree, any directory in it, or the git dir of a bare repo. opts:
 * ISSUEZ_OPT_GIT_PATH .. ISSUEZ_OPT_CACHE_ISSUES (may be NULL, 0). Checks git's
 * version; git sessions start lazily.
 */
issuez_code issuez_repo_open(issuez_str path, const issuez_op *opts, size_t n_opts,
                             issuez_repo **out, issuez_error **err);

/*
 * Drops the caller's reference (see Ownership).
 */
void issuez_repo_close(issuez_repo *repo);

issuez_str issuez_repo_git_dir(const issuez_repo *repo);

/*
 * A logger for this repo's calls, in place of the process-wide one
 * (issuez_set_logger) while they run; the same rules. NULL cb goes back to the
 * process-wide one.
 */
void issuez_repo_set_logger(issuez_repo *repo, issuez_log_level min_level, issuez_log_fn cb,
                            void *userdata);

/*
 * A staging repo inheriting repo's settings and options, sharing its objects.
 * Replay with ordinary writes, then commit_import. Closing it removes its
 * private refs, also after failure. The target stays alive while staging. Do
 * not write to a staging repo concurrently with commit or close.
 */
issuez_code issuez_repo_begin_import(issuez_repo *repo, issuez_cancel *cancel, issuez_repo **out,
                                     issuez_error **err);

/*
 * Publishes staging's shared refs to its target in one transaction. CONTENDED
 * if a target ref already exists; no refs are published then. Call once on
 * success, stop writing and close staging. Does not publish local cache refs.
 */
issuez_code issuez_repo_commit_import(issuez_repo *staging, issuez_cancel *cancel, size_t *adopted,
                                      issuez_error **err);

/*
 * The effective value of a limit ("max_attachment_bytes", "cas_retries", the
 * names ISSUEZ_OPT_LIMIT takes); false for no such limit.
 */
bool issuez_repo_limit(const issuez_repo *repo, issuez_str name, uint64_t *out);


/* ---------------------------------------- Resolve and change detection --------------------- */

typedef enum issuez_kind {
    ISSUEZ_KIND_UNKNOWN = 0,
    ISSUEZ_KIND_ISSUE = 1,
    ISSUEZ_KIND_MILESTONE = 2,
    ISSUEZ_KIND_ATTACHMENTS = 3,
    ISSUEZ_KIND_TOMBSTONE = 4,
} issuez_kind;

/* The buffer issuez_resolve_one writes: a hyphenated UUID and a NUL. */
#define ISSUEZ_UUID_BUFSIZE 37

/*
 * User input to a UUID: a full UUID, a unique prefix ("a7f3"), a number
 * ("#12"), or for milestones a name. Exactly one, or NOT_FOUND / AMBIGUOUS.
 * Writes the UUID and a NUL into buf (ISSUEZ_UUID_BUFSIZE bytes).
 */
issuez_code issuez_resolve_one(issuez_repo *repo, issuez_kind kind, issuez_str input,
                               issuez_cancel *cancel, char *buf, issuez_error **err);

/*
 * Snapshot: every issue and milestone ref with its tip. Cheap (no issue is
 * read). A host stores what it indexed in the encoding issuez_snapshot_decode
 * reads.
 */
typedef struct issuez_snapshot issuez_snapshot;

issuez_code issuez_snapshot_take(issuez_repo *repo, issuez_cancel *cancel, issuez_snapshot **out,
                                 issuez_error **err);

void issuez_snapshot_free(issuez_snapshot *s);

size_t issuez_snapshot_len(const issuez_snapshot *s);

/*
 * The i-th entry, sorted by kind, then UUID.
 */
void issuez_snapshot_at(const issuez_snapshot *s, size_t i, issuez_kind *kind, issuez_str *id,
                        issuez_oid *tip);

/*
 * The stable, versioned encoding: "issuez-snapshot 1\n", then a line "i <uuid>
 * <tip>\n" or "m <uuid> <tip>\n" per issue or milestone, the tip in full
 * lowercase hex. Empty bytes decode to an empty snapshot.
 */
issuez_code issuez_snapshot_decode(issuez_str bytes, issuez_snapshot **out, issuez_error **err);


/* ---------------------------------------- Issues: read ------------------------------------- */

typedef struct issuez_issue issuez_issue;
typedef struct issuez_issue_list issuez_issue_list;

issuez_code issuez_issue_load(issuez_repo *repo, issuez_str id, issuez_cancel *cancel,
                              issuez_issue **out, issuez_error **err);

/*
 * Loads the exact tip, even after its ref moved or disappeared. tip must be
 * nonzero and use the repository's object format. since is optional, as in
 * load_since. Historical objects must still exist; this does not retain purged
 * objects.
 */
issuez_code issuez_issue_load_at(issuez_repo *repo, issuez_str id, const issuez_oid *tip,
                                 const issuez_oid *since, issuez_cancel *cancel, issuez_issue **out,
                                 issuez_error **err);

/*
 * issuez_issue_load, with each timeline entry's is_new saying whether its
 * commit is new since the tip since: what a host that projected the issue at
 * since hasn't seen, merged-in commits included. NULL since: every entry is
 * new. A since outside the issue's history (a purge rewrote it, or it isn't
 * this issue's) makes none new and issuez_issue_info.rewritten true.
 */
issuez_code issuez_issue_load_since(issuez_repo *repo, issuez_str id, const issuez_oid *since,
                                    issuez_cancel *cancel, issuez_issue **out, issuez_error **err);

void issuez_issue_free(issuez_issue *issue);

typedef enum issuez_state {
    ISSUEZ_STATE_UNKNOWN = 0,
    ISSUEZ_STATE_OPEN = 1,
    ISSUEZ_STATE_CLOSED = 2,
    ISSUEZ_STATE_OTHER = 3, /* see issuez_issue_info.state_name */
} issuez_state;

typedef enum issuez_priority {
    ISSUEZ_PRIORITY_UNKNOWN = 0, /* also: not set */
    ISSUEZ_PRIORITY_LOW = 1,
    ISSUEZ_PRIORITY_MEDIUM = 2,
    ISSUEZ_PRIORITY_HIGH = 3,
    ISSUEZ_PRIORITY_CRITICAL = 4,
} issuez_priority;

/*
 * An issue's single values, one record; lists and lookups have their own calls
 * below. Filled once, when the handle is built: reading it costs nothing and is
 * safe from any thread, like the rest of a loaded object. A newer library may
 * add fields at the end, which doesn't break a program built against this
 * header because the library owns the memory: read it through the pointer,
 * never copy or allocate one.
 */
typedef struct issuez_issue_info {
    issuez_str id;
    issuez_oid tip; /* pass as expect */
    bool has_number; /* false: no number yet, and number is 0 */
    uint64_t number;
    issuez_str format_version;
    uint32_t commit_count;
    issuez_str title;
    issuez_str description;
    const issuez_person *author;
    issuez_time created;
    issuez_time updated;
    uint32_t state; /* issuez_state */
    issuez_str state_name; /* "open", "closed", "wontfix", ... */
    bool is_done; /* closed or one of the repo's done states */
    issuez_str workflow_state; /* defaulted for open issues; {NULL,0} for done ones */
    const issuez_person *closed_by; /* who last made the issue done; NULL while it isn't */
    issuez_time closed_at; /* when closed_by did; zero while it isn't done */
    issuez_str fixed_by;
    issuez_str release;
    issuez_str reason;
    bool is_deleted;
    bool is_locked;
    issuez_str lock_reason;
    uint32_t priority; /* issuez_priority */
    issuez_str milestone_id; /* direct only, not one inherited from a parent */
    issuez_str parent_id;
    issuez_date start_date; /* zero: none */
    issuez_date due_date; /* zero: none */
    /* false: no estimate, and estimate_minutes is 0; true with 0 is an estimate of 0 */
    bool has_estimate_minutes;
    uint32_t estimate_minutes;
    issuez_str ref; /* a branch or tag */
    /* an imported issue's author in the other tracker; {NULL,0} otherwise */
    issuez_str original_author;
    issuez_str original_id;
    /* issuez_issue_load_since's since isn't in the history; false from other loads */
    bool rewritten;
} issuez_issue_info;

/*
 * Borrowed from i. NULL for a NULL handle.
 */
const issuez_issue_info *issuez_issue_info_of(const issuez_issue *i);

size_t issuez_issue_label_count(const issuez_issue *i);

issuez_str issuez_issue_label_at(const issuez_issue *i, size_t k);

size_t issuez_issue_assignee_count(const issuez_issue *i);

const issuez_person *issuez_issue_assignee_at(const issuez_issue *i, size_t k);

size_t issuez_issue_blocker_count(const issuez_issue *i);

issuez_str issuez_issue_blocker_at(const issuez_issue *i, size_t k);

/*
 * Fields this library doesn't interpret (X-Forgejo-* and others).
 */
size_t issuez_issue_extra_count(const issuez_issue *i);

void issuez_issue_extra_at(const issuez_issue *i, size_t k, issuez_str *key, issuez_str *value);

/*
 * Invalid stored values (kept and ignored), unresolved events, and conflicts
 * (two clones disagreed).
 */
const issuez_problems *issuez_issue_problems(const issuez_issue *i);

typedef struct issuez_reaction {
    issuez_str emoji; /* ":+1:" or a unicode emoji, as written */
    size_t user_count; /* see issuez_reaction_user_at */
} issuez_reaction;

/*
 * On the issue (comment NULL) or a comment.
 */
size_t issuez_issue_reaction_count(const issuez_issue *i, const issuez_oid *comment);

const issuez_reaction *issuez_issue_reaction_at(
    const issuez_issue *i, const issuez_oid *comment, size_t k);

const issuez_person *issuez_reaction_user_at(const issuez_reaction *r, size_t k);

/*
 * Comments: text someone wrote, in order, deleted ones included. Field-only
 * commits and merges are in the timeline.
 */
typedef struct issuez_comment {
    issuez_oid id; /* full commit OID: the comment's stable ID */
    const issuez_person *author;
    issuez_time created;
    issuez_time updated; /* of the latest edit; = created if none */
    issuez_str text; /* current text, trailers stripped */
    bool edited;
    bool deleted; /* text still readable, for moderators */
    size_t attachment_count; /* see issuez_comment_attachment_at */
    issuez_str original_author; /* imported: its author in the other tracker; {NULL,0} otherwise */
    issuez_str original_id; /* imported: its ID in the other tracker */
    bool purged; /* a purge took its text, attachments and origin; its fields stay */
} issuez_comment;

size_t issuez_issue_comment_count(const issuez_issue *i);

const issuez_comment *issuez_issue_comment_at(const issuez_issue *i, size_t k);

/*
 * The UUID of an attachment the comment's commit added; {NULL,0} past the end.
 */
issuez_str issuez_comment_attachment_at(const issuez_comment *c, size_t k);

/*
 * Attachments: images on the issue (format.md §7), present ones first, oldest
 * first, then the removed ones. The bytes are LFS objects; this library's CLI
 * keeps them in the repository, a host in its LFS store.
 */
typedef struct issuez_attachment {
    issuez_str id; /* v4 UUID; links in text are attachment:<id> */
    issuez_str media_type; /* image/png, image/jpeg or image/webp */
    uint64_t size;
    issuez_str sha256; /* 64 lowercase hex digits: the LFS object ID */
    issuez_str name;
    issuez_oid added_in; /* the commit that added it: a comment, the root, an edit */
    const issuez_person *added_by;
    bool removed; /* hidden by X-Attachment-Removed; its bytes are still referenced */
    /* the comment it belongs to: added_in's comment, or the comment it edits; zero for the description's (the root, a description edit) */
    issuez_oid comment;
    issuez_time at; /* when added_in was written */
} issuez_attachment;

size_t issuez_issue_attachment_count(const issuez_issue *i);

const issuez_attachment *issuez_issue_attachment_at(const issuez_issue *i, size_t k);

/*
 * Timeline: every commit of the issue as a typed entry, oldest first. The
 * changes use the verbs of writes: SET (old -> new), CLEAR, ADD, REMOVE.
 */
typedef struct issuez_change {
    uint32_t field; /* issuez_field; one change per field and member, whichever trailers said it */
    issuez_str key; /* trailer key */
    uint32_t op; /* issuez_verb: SET, CLEAR, ADD or REMOVE */
    /* canonical text: "2026-12-01", "high", a UUID, ...; the value before, also when the trailer didn't say it (a first TITLE: the root's subject, a first STATE: "open") */
    issuez_str old_value;
    issuez_str new_value; /* a cleared TITLE: the root's subject again */
    const issuez_person *old_person; /* ASSIGNEES: the member removed, parsed; NULL otherwise */
    const issuez_person *new_person; /* ASSIGNEES: the member added, parsed; NULL otherwise */
    issuez_date old_date; /* START_DATE, DUE_DATE: parsed; zero: none */
    issuez_date new_date; /* START_DATE, DUE_DATE: parsed; zero: none */
    bool old_done; /* STATE: whether the old state is done, by the repo's done states */
    bool new_done; /* STATE: whether the new state is done */
    issuez_str reason; /* LOCKED: the lock's reason as of this commit */
} issuez_change;

typedef enum issuez_entry_kind {
    ISSUEZ_ENTRY_UNKNOWN = 0,
    ISSUEZ_ENTRY_CREATED = 1,
    ISSUEZ_ENTRY_COMMENT = 2, /* comment points at it; may carry changes too */
    ISSUEZ_ENTRY_UPDATE = 3, /* field changes only */
    ISSUEZ_ENTRY_DESCRIPTION_EDIT = 4,
    ISSUEZ_ENTRY_COMMENT_EDIT = 5,
    ISSUEZ_ENTRY_COMMENT_DELETE = 6,
    ISSUEZ_ENTRY_COMMENT_RESTORE = 7,
    ISSUEZ_ENTRY_REACTION = 8,
    ISSUEZ_ENTRY_MERGE = 9, /* changes only where it resolved a conflict */
} issuez_entry_kind;

typedef struct issuez_entry {
    uint32_t kind; /* issuez_entry_kind */
    issuez_oid commit;
    const issuez_person *author;
    issuez_time at;
    const issuez_comment *comment; /* COMMENT; the target for COMMENT_*; NULL otherwise */
    size_t change_count; /* see issuez_entry_change_at */
    bool is_new; /* not reachable from issuez_issue_load_since's since; true elsewhere */
} issuez_entry;

size_t issuez_issue_timeline_count(const issuez_issue *i);

const issuez_entry *issuez_issue_timeline_at(const issuez_issue *i, size_t k);

const issuez_change *issuez_entry_change_at(const issuez_entry *e, size_t k);

/*
 * Every version of the description (comment NULL) or a comment, oldest first.
 * After concurrent edits the current text is the one the merge rule resolves
 * to, which needn't be the last version.
 */
typedef enum issuez_revision_kind {
    ISSUEZ_REVISION_UNKNOWN = 0,
    ISSUEZ_REVISION_ORIGINAL = 1, /* the comment itself, or the issue's root */
    ISSUEZ_REVISION_EDIT = 2,
    ISSUEZ_REVISION_DELETE = 3, /* text: what it hid */
    ISSUEZ_REVISION_RESTORE = 4, /* text: what it showed again */
} issuez_revision_kind;

typedef struct issuez_revision {
    issuez_oid commit; /* the commit that wrote it: the comment, the root, or an event */
    const issuez_person *author;
    issuez_time at;
    uint32_t kind; /* issuez_revision_kind */
    issuez_str text; /* the whole text after it */
} issuez_revision;

size_t issuez_issue_history_count(const issuez_issue *i, const issuez_oid *comment);

const issuez_revision *issuez_issue_history_at(
    const issuez_issue *i, const issuez_oid *comment, size_t k);


/* ---------------------------------------- Issues: query ------------------------------------ */

typedef enum issuez_sort {
    ISSUEZ_SORT_UNKNOWN = 0,
    ISSUEZ_SORT_CREATED = 1,
    ISSUEZ_SORT_UPDATED = 2,
    ISSUEZ_SORT_NUMBER = 3,
    ISSUEZ_SORT_PRIORITY = 4,
    ISSUEZ_SORT_DUE_DATE = 5,
    ISSUEZ_SORT_COMMENTS = 6,
    ISSUEZ_SORT_STATE = 7,
} issuez_sort;

/*
 * ops: ISSUEZ_OPT_Q_*. Defaults: not done, not deleted, newest first, 100 per
 * page. Q_TEXT is a fixed-string match, not a search engine.
 */
issuez_code issuez_query_run(issuez_repo *repo, const issuez_op *ops, size_t n,
                             issuez_cancel *cancel, issuez_issue_list **out, issuez_error **err);

size_t issuez_issue_list_len(const issuez_issue_list *l);

const issuez_issue *issuez_issue_list_at(const issuez_issue_list *l, size_t i);

/*
 * {NULL,0} on the last page.
 */
issuez_str issuez_issue_list_next_cursor(const issuez_issue_list *l);

/*
 * Issues matched that couldn't be read (damaged).
 */
size_t issuez_issue_list_skipped_count(const issuez_issue_list *l);

issuez_str issuez_issue_list_skipped_at(const issuez_issue_list *l, size_t i);

void issuez_issue_list_free(issuez_issue_list *l);


/* ---------------------------------------- Issues: write ------------------------------------ */
/*
 * One op list, one commit: a user action ("comment and close", "edit labels and
 * assignees", "delete") is one call. ISSUEZ_OPT_EXPECT and the other write
 * options go in the same list.
 */

/*
 * TITLE is required.
 */
issuez_code issuez_issue_create(issuez_repo *repo, const issuez_op *ops, size_t n,
                                const issuez_actor *actor, issuez_cancel *cancel,
                                issuez_write **out, issuez_error **err);

/*
 * Every write to an existing issue: fields, a comment, a comment's edit, delete
 * or restore (issuez_edit_comment, issuez_delete_comment,
 * issuez_restore_comment), a reaction (issuez_add_reaction,
 * issuez_reaction_target). A list that changes nothing (empty, or every value
 * as it is) is OK and writes nothing (issuez_write_wrote).
 */
issuez_code issuez_issue_update(issuez_repo *repo, issuez_str id, const issuez_op *ops, size_t n,
                                const issuez_actor *actor, issuez_cancel *cancel,
                                issuez_write **out, issuez_error **err);

typedef struct issuez_prepared_attachment issuez_prepared_attachment;

typedef struct issuez_attachment_spec {
    issuez_str id;
    issuez_str media_type;
    uint64_t size;
    issuez_str sha256;
    issuez_str name;
} issuez_attachment_spec;

/*
 * Validates and hashes bytes once, sanitizes the name and chooses an ID when
 * empty. Store the bytes in the host's LFS store before writing
 * ISSUEZ_OPT_PREPARED_ATTACHMENT. The write requires ATTACHMENT_STORE 0 and
 * checks metadata and limits again.
 */
issuez_code issuez_attachment_prepare(issuez_repo *repo, issuez_str id, issuez_str name,
                                      issuez_str data, issuez_cancel *cancel,
                                      issuez_prepared_attachment **out, issuez_error **err);

/*
 * Borrowed metadata for the host's storage, valid until p is freed.
 */
const issuez_attachment_spec *issuez_prepared_attachment_info(
    const issuez_prepared_attachment *p);

void issuez_prepared_attachment_free(issuez_prepared_attachment *p);

/*
 * The receipt of a write.
 */
void issuez_write_free(issuez_write *w);

issuez_kind issuez_write_kind(const issuez_write *w);

issuez_str issuez_write_id(const issuez_write *w);

/*
 * false: nothing to write (a no-op list, an idempotent reaction).
 */
bool issuez_write_wrote(const issuez_write *w);

issuez_oid issuez_write_commit(const issuez_write *w);

/*
 * len 0 on create.
 */
issuez_oid issuez_write_old_tip(const issuez_write *w);

/*
 * The next expect.
 */
issuez_oid issuez_write_new_tip(const issuez_write *w);

/*
 * Times the write started over after a concurrent change; usually 0.
 */
uint32_t issuez_write_retries(const issuez_write *w);

/*
 * The commit as a timeline entry, with its typed changes.
 */
const issuez_entry *issuez_write_entry(const issuez_write *w);

/*
 * The issue as of the new tip, owned by the caller.
 */
issuez_code issuez_write_load_issue(const issuez_write *w, issuez_cancel *cancel,
                                    issuez_issue **out, issuez_error **err);

/*
 * The milestone at the receipt's exact new tip, owned by the caller.
 */
issuez_code issuez_write_load_milestone(
    const issuez_write *w, issuez_cancel *cancel, issuez_milestone **out, issuez_error **err);


/* ---------------------------------------- Milestones --------------------------------------- */

typedef struct issuez_milestone_list issuez_milestone_list;

typedef enum issuez_milestone_status {
    ISSUEZ_MILESTONE_UNKNOWN = 0,
    ISSUEZ_MILESTONE_OPEN = 1,
    ISSUEZ_MILESTONE_COMPLETED = 2,
    ISSUEZ_MILESTONE_RETIRED = 3,
} issuez_milestone_status;

issuez_code issuez_milestone_load(issuez_repo *repo, issuez_str id, issuez_cancel *cancel,
                                  issuez_milestone **out, issuez_error **err);

/*
 * The milestone at an exact, nonzero tip, even after its ref moved or
 * disappeared.
 */
issuez_code issuez_milestone_load_at(issuez_repo *repo, issuez_str id, const issuez_oid *tip,
                                     issuez_cancel *cancel, issuez_milestone **out,
                                     issuez_error **err);

issuez_code issuez_milestone_list_all(issuez_repo *repo, issuez_cancel *cancel,
                                      issuez_milestone_list **out, issuez_error **err);

void issuez_milestone_free(issuez_milestone *m);

size_t issuez_milestone_list_len(const issuez_milestone_list *l);

const issuez_milestone *issuez_milestone_list_at(const issuez_milestone_list *l, size_t i);

void issuez_milestone_list_free(issuez_milestone_list *l);

/*
 * A milestone's single values, one record, like issuez_issue_info: filled once
 * when the handle is built, and fields may be added at the end, so read it
 * through the pointer and never copy or allocate one.
 */
typedef struct issuez_milestone_info {
    issuez_str id;
    issuez_oid tip;
    issuez_str name;
    issuez_str description;
    uint32_t status; /* issuez_milestone_status */
    issuez_date due_date; /* zero: none */
    issuez_time created;
    issuez_time updated; /* of its latest commit */
    /* false: no commit after the root set the status, and status_changed is zero */
    bool has_status_changed;
    /* when the status it has was set, by the last commit after the root that set it: a completed milestone's closing time */
    issuez_time status_changed;
    const issuez_person *author; /* who created it */
} issuez_milestone_info;

/*
 * Borrowed from m. NULL for a NULL handle.
 */
const issuez_milestone_info *issuez_milestone_info_of(const issuez_milestone *m);

const issuez_problems *issuez_milestone_problems(const issuez_milestone *m);

/*
 * Fields: NAME (required on create), DESCRIPTION, DUE_DATE, MILESTONE_STATUS
 * (COMPLETED is a GUARD problem while issues are open), plus ISSUEZ_OPT_EXPECT.
 */
issuez_code issuez_milestone_create(issuez_repo *repo, const issuez_op *ops, size_t n,
                                    const issuez_actor *actor, issuez_cancel *cancel,
                                    issuez_write **out, issuez_error **err);

issuez_code issuez_milestone_update(issuez_repo *repo, issuez_str id, const issuez_op *ops,
                                    size_t n, const issuez_actor *actor, issuez_cancel *cancel,
                                    issuez_write **out, issuez_error **err);


/* ---------------------------------------- Fsck --------------------------------------------- */
/*
 * Checking the issue data, as git issue fsck does: upstream fsck's checks on
 * every issue and milestone, attachment trailers and bytes, derived attachment
 * refs, quarantined remote versions, and hierarchy and blocker problems.
 * Nothing is written. With ISSUEZ_OPT_ATTACHMENT_STORE 0 the bytes are the
 * caller's to check.
 */

typedef enum issuez_fsck_kind {
    ISSUEZ_FSCK_UNKNOWN = 0,
    ISSUEZ_FSCK_INTEGRITY = 1, /* error: fails one of upstream fsck's checks */
    /* note: an X-Milestone-Status no reader takes; it reads as open */
    ISSUEZ_FSCK_MILESTONE_STATUS = 2,
    ISSUEZ_FSCK_ATTACHMENT_TRAILER = 3, /* note: an attachment trailer the history ignores */
    ISSUEZ_FSCK_ATTACHMENT_MISSING = 4, /* note: an attachment's bytes aren't in this repository */
    ISSUEZ_FSCK_ATTACHMENT_CORRUPT = 5, /* error: an attachment's stored bytes don't match it */
    ISSUEZ_FSCK_DERIVED_REF = 6, /* note: refs/attachments/<id> is missing or stale */
    ISSUEZ_FSCK_ATTACHMENTS_FAILED = 7, /* error: checking attachments failed */
    ISSUEZ_FSCK_BYTES_UNCHECKED = 8, /* note: without git-lfs the bytes weren't checked */
    ISSUEZ_FSCK_ORPHANS = 9, /* note: stored objects no issue references (failed writes) */
    ISSUEZ_FSCK_QUARANTINED = 10, /* note: remote versions a merge refused, subject the remote */
    ISSUEZ_FSCK_PROJECTION = 11, /* note: a hierarchy or blocker problem across issues */
} issuez_fsck_kind;

typedef struct issuez_fsck_finding {
    uint32_t kind; /* issuez_fsck_kind */
    bool is_error; /* counted as an error; notes aren't */
    uint32_t subject_kind; /* issuez_kind of subject; UNKNOWN for the repository */
    issuez_str subject; /* an issue or milestone UUID, a remote; {NULL,0} for the repository */
    issuez_str message; /* one sentence without a front end's commands */
} issuez_fsck_finding;

typedef struct issuez_fsck_report issuez_fsck_report;

issuez_code issuez_fsck(issuez_repo *repo, issuez_cancel *cancel, issuez_fsck_report **out,
                        issuez_error **err);

size_t issuez_fsck_report_issue_count(const issuez_fsck_report *r);

size_t issuez_fsck_report_milestone_count(const issuez_fsck_report *r);

size_t issuez_fsck_report_error_count(const issuez_fsck_report *r);

size_t issuez_fsck_report_len(const issuez_fsck_report *r);

/*
 * In the order the checks ran.
 */
const issuez_fsck_finding *issuez_fsck_report_at(const issuez_fsck_report *r, size_t i);

void issuez_fsck_report_free(issuez_fsck_report *r);


/* ---------------------------------------- Push check --------------------------------------- */
/*
 * For a server's pre-receive hook: may these ref updates be accepted? A
 * judgement on the format only; the host adds its own policy (permissions,
 * locks) using the verdicts.
 */

typedef struct issuez_push_verdicts issuez_push_verdicts;

typedef enum issuez_author_policy {
    ISSUEZ_AUTHOR_UNKNOWN = 0,
    ISSUEZ_AUTHOR_ANY = 1, /* default */
    ISSUEZ_AUTHOR_WARN = 2, /* accept, flag commits not by the pusher */
    ISSUEZ_AUTHOR_ENFORCE = 3, /* reject them */
} issuez_author_policy;

typedef struct issuez_ref_update {
    issuez_str ref;
    issuez_oid old_oid; /* len 0 for a create */
    issuez_oid new_oid; /* len 0 for a delete */
    uint64_t reserved[2]; /* zero */
} issuez_ref_update;

typedef enum issuez_push_action {
    ISSUEZ_PUSH_UNKNOWN = 0,
    ISSUEZ_PUSH_IGNORED = 1, /* not an issuez ref: the host's business */
    ISSUEZ_PUSH_CREATE = 2,
    ISSUEZ_PUSH_FAST_FORWARD = 3,
    ISSUEZ_PUSH_REWRITE = 4, /* rejected unless a tombstone allows it (ISSUEZ_OPT_ALLOW_PURGE) */
    ISSUEZ_PUSH_DELETE = 5, /* rejected unless a tombstone allows it (ISSUEZ_OPT_ALLOW_PURGE) */
} issuez_push_action;

typedef struct issuez_push_verdict {
    issuez_str ref;
    uint32_t kind; /* issuez_kind; ISSUEZ_KIND_UNKNOWN for other refs */
    issuez_str id;
    uint32_t action; /* issuez_push_action */
    bool accept;
    const issuez_problems *problems; /* why not, or what to flag (author mismatch under WARN) */
    bool needs_number; /* a new issue without one */
    bool touches_locked; /* adds commits to a locked issue */
    size_t commit_count; /* new commits */
    /* issues: the new commits as timeline entries, see issuez_push_verdict_entry_at; 0 for other kinds */
    size_t entry_count;
    /* issues: who opened it (the pusher's own issue or not); NULL otherwise */
    const issuez_person *issue_author;
    /* issues: attachments the new commits add, see issuez_push_verdict_attachment_at */
    size_t attachment_count;
} issuez_push_verdict;

/*
 * opts: ISSUEZ_OPT_PUSHER .. ISSUEZ_OPT_ALLOW_PURGE. Reads the objects from the
 * quarantine and writes nothing (format.md §11). OK when every verdict
 * accepts, REJECTED otherwise (the verdicts are still set).
 */
issuez_code issuez_push_check(issuez_repo *repo, const issuez_ref_update *updates, size_t n_updates,
                              const issuez_op *opts, size_t n_opts, issuez_cancel *cancel,
                              issuez_push_verdicts **out, issuez_error **err);

size_t issuez_push_verdicts_len(const issuez_push_verdicts *v);

const issuez_push_verdict *issuez_push_verdicts_at(const issuez_push_verdicts *v, size_t i);

/*
 * The new commits of an issue as timeline entries, k < entry_count.
 */
const issuez_entry *issuez_push_verdict_entry_at(const issuez_push_verdict *v, size_t k);

/*
 * An attachment the new commits add, k < attachment_count: its sha256 and size
 * are the LFS object the host's store must have before it accepts the push.
 */
const issuez_attachment *issuez_push_verdict_attachment_at(
    const issuez_push_verdict *v, size_t k);

void issuez_push_verdicts_free(issuez_push_verdicts *v);


/* ---------------------------------------- Purge -------------------------------------------- */
/*
 * Hard delete for moderation and legal requests. Rewrites or removes history,
 * unlike everything else here, and leaves a tombstone
 * (refs/issuez-purged/<uuid>) so syncs and pushes can't bring it back. Clones
 * that already have the data keep it: the result says what was published.
 */

typedef struct issuez_purge_result issuez_purge_result;

issuez_code issuez_purge_issue(issuez_repo *repo, issuez_str id, const issuez_actor *actor,
                               issuez_str reason, issuez_cancel *cancel, issuez_purge_result **out,
                               issuez_error **err);

/*
 * Removes one comment's text and attachments; every later commit is rewritten,
 * so tips change.
 */
issuez_code issuez_purge_comment(issuez_repo *repo, issuez_str id, const issuez_oid *comment,
                                 const issuez_actor *actor, issuez_str reason,
                                 issuez_cancel *cancel, issuez_purge_result **out,
                                 issuez_error **err);

void issuez_purge_result_free(issuez_purge_result *r);

/*
 * len 0: the issue is gone.
 */
issuez_oid issuez_purge_result_new_tip(const issuez_purge_result *r);

/*
 * Remotes whose tracking refs show they had the purged commits, one synced by
 * URL or path as the url-<hash> its refs are kept under. The next git issue
 * sync with each replaces their copy (leased on what it fetched).
 */
size_t issuez_purge_result_exposed_remote_count(const issuez_purge_result *r);

issuez_str issuez_purge_result_exposed_remote_at(const issuez_purge_result *r, size_t i);

/*
 * The attachments the purge took out of history: a host drops its copies of
 * their bytes.
 */
size_t issuez_purge_result_attachment_count(const issuez_purge_result *r);

/*
 * A UUID.
 */
issuez_str issuez_purge_result_attachment_at(const issuez_purge_result *r, size_t i);


/* ---------------------------------------- Op helpers --------------------------------------- */
/*
 * issuez_<verb>_<field>, issuez_q_<query option>, issuez_opt_<open option>,
 * issuez_expect: one static inline function per op, typed and named for its
 * value. Conveniences for C; bindings build issuez_op themselves.
 */

static inline issuez_op issuez_set_title(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_TITLE;
    o.str = v;
    return o;
}
static inline issuez_op issuez_set_description(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_DESCRIPTION;
    o.str = v;
    return o;
}
static inline issuez_op issuez_set_comment(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_COMMENT;
    o.str = v;
    return o;
}
static inline issuez_op issuez_set_state(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_STATE;
    o.str = v;
    return o;
}
static inline issuez_op issuez_set_fixed_by(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_FIXED_BY;
    o.str = v;
    return o;
}
static inline issuez_op issuez_set_release(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_RELEASE;
    o.str = v;
    return o;
}
static inline issuez_op issuez_set_reason(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_REASON;
    o.str = v;
    return o;
}
static inline issuez_op issuez_set_workflow_state(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_WORKFLOW_STATE;
    o.str = v;
    return o;
}
static inline issuez_op issuez_clear_workflow_state(void) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_CLEAR;
    o.target = ISSUEZ_FIELD_WORKFLOW_STATE;
    return o;
}
static inline issuez_op issuez_add_label(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_FIELD_LABELS;
    o.str = v;
    return o;
}
static inline issuez_op issuez_remove_label(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_REMOVE;
    o.target = ISSUEZ_FIELD_LABELS;
    o.str = v;
    return o;
}
static inline issuez_op issuez_clear_labels(void) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_CLEAR;
    o.target = ISSUEZ_FIELD_LABELS;
    return o;
}
static inline issuez_op issuez_add_assignee(issuez_person v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_FIELD_ASSIGNEES;
    o.person = v;
    return o;
}
static inline issuez_op issuez_remove_assignee(issuez_person v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_REMOVE;
    o.target = ISSUEZ_FIELD_ASSIGNEES;
    o.person = v;
    return o;
}
static inline issuez_op issuez_clear_assignees(void) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_CLEAR;
    o.target = ISSUEZ_FIELD_ASSIGNEES;
    return o;
}
static inline issuez_op issuez_set_priority(issuez_priority priority) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_PRIORITY;
    o.num = priority;
    return o;
}
static inline issuez_op issuez_clear_priority(void) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_CLEAR;
    o.target = ISSUEZ_FIELD_PRIORITY;
    return o;
}
static inline issuez_op issuez_set_milestone(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_MILESTONE;
    o.str = v;
    return o;
}
static inline issuez_op issuez_inherit_milestone(void) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_INHERIT;
    o.target = ISSUEZ_FIELD_MILESTONE;
    return o;
}
static inline issuez_op issuez_clear_milestone(void) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_CLEAR;
    o.target = ISSUEZ_FIELD_MILESTONE;
    return o;
}
static inline issuez_op issuez_set_parent(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_PARENT;
    o.str = v;
    return o;
}
static inline issuez_op issuez_clear_parent(void) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_CLEAR;
    o.target = ISSUEZ_FIELD_PARENT;
    return o;
}
static inline issuez_op issuez_add_blocker(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_FIELD_BLOCKED_BY;
    o.str = v;
    return o;
}
static inline issuez_op issuez_remove_blocker(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_REMOVE;
    o.target = ISSUEZ_FIELD_BLOCKED_BY;
    o.str = v;
    return o;
}
static inline issuez_op issuez_set_start_date(issuez_date v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_START_DATE;
    o.date = v;
    return o;
}
static inline issuez_op issuez_clear_start_date(void) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_CLEAR;
    o.target = ISSUEZ_FIELD_START_DATE;
    return o;
}
static inline issuez_op issuez_set_due_date(issuez_date v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_DUE_DATE;
    o.date = v;
    return o;
}
static inline issuez_op issuez_clear_due_date(void) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_CLEAR;
    o.target = ISSUEZ_FIELD_DUE_DATE;
    return o;
}
static inline issuez_op issuez_set_estimate(int64_t v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_ESTIMATE;
    o.num = v;
    return o;
}
static inline issuez_op issuez_clear_estimate(void) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_CLEAR;
    o.target = ISSUEZ_FIELD_ESTIMATE;
    return o;
}
static inline issuez_op issuez_set_deleted(bool deleted) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_DELETED;
    o.num = deleted;
    return o;
}
static inline issuez_op issuez_set_number(int64_t v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_NUMBER;
    o.num = v;
    return o;
}
static inline issuez_op issuez_set_name(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_NAME;
    o.str = v;
    return o;
}
static inline issuez_op issuez_set_milestone_status(issuez_milestone_status status) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_MILESTONE_STATUS;
    o.num = status;
    return o;
}
static inline issuez_op issuez_set_extra(issuez_str key, issuez_str value) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_EXTRA;
    o.name = key;
    o.str = value;
    return o;
}
static inline issuez_op issuez_expect(issuez_oid v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_EXPECT;
    o.oid = v;
    return o;
}
static inline issuez_op issuez_set_subject(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_SUBJECT;
    o.str = v;
    return o;
}
static inline issuez_op issuez_q_label(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_OPT_Q_LABEL;
    o.str = v;
    return o;
}
static inline issuez_op issuez_q_not_label(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_OPT_Q_NOT_LABEL;
    o.str = v;
    return o;
}
static inline issuez_op issuez_q_assignee(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_OPT_Q_ASSIGNEE;
    o.str = v;
    return o;
}
static inline issuez_op issuez_q_state(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_OPT_Q_STATE;
    o.str = v;
    return o;
}
static inline issuez_op issuez_q_done(int64_t done) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_Q_DONE;
    o.num = done;
    return o;
}
static inline issuez_op issuez_q_limit(int64_t v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_Q_LIMIT;
    o.num = v;
    return o;
}
static inline issuez_op issuez_q_after(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_Q_AFTER;
    o.str = v;
    return o;
}
static inline issuez_op issuez_opt_git_path(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_GIT_PATH;
    o.str = v;
    return o;
}
static inline issuez_op issuez_opt_committer(issuez_str name, issuez_str email) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_COMMITTER;
    o.person.name = name;
    o.person.email = email;
    return o;
}
static inline issuez_op issuez_opt_pool_size(int64_t v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_POOL_SIZE;
    o.num = v;
    return o;
}
static inline issuez_op issuez_opt_pusher(issuez_person v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_PUSHER;
    o.person = v;
    return o;
}
static inline issuez_op issuez_opt_pusher_email(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_OPT_PUSHER_EMAIL;
    o.str = v;
    return o;
}
static inline issuez_op issuez_opt_author_policy(issuez_author_policy policy) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_AUTHOR_POLICY;
    o.num = policy;
    return o;
}
static inline issuez_op issuez_opt_allow_numbers(bool allow) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_ALLOW_NUMBERS;
    o.num = allow;
    return o;
}
static inline issuez_op issuez_opt_allow_purge(bool allow) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_ALLOW_PURGE;
    o.num = allow;
    return o;
}
static inline issuez_op issuez_opt_pusher_user_id(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_OPT_PUSHER_USER_ID;
    o.str = v;
    return o;
}
static inline issuez_op issuez_opt_object_dir(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_OBJECT_DIR;
    o.str = v;
    return o;
}
static inline issuez_op issuez_opt_alternate_object_dirs(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_ALTERNATE_OBJECT_DIRS;
    o.str = v;
    return o;
}
static inline issuez_op issuez_set_ref(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_REF;
    o.str = v;
    return o;
}
static inline issuez_op issuez_clear_ref(void) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_CLEAR;
    o.target = ISSUEZ_FIELD_REF;
    return o;
}
static inline issuez_op issuez_set_locked(bool locked, issuez_str reason) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_FIELD_LOCKED;
    o.num = locked;
    o.str = reason;
    return o;
}
static inline issuez_op issuez_add_attachment(issuez_str id, issuez_str name, issuez_str data) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_FIELD_ATTACHMENTS;
    o.id = id;
    o.name = name;
    o.str = data;
    return o;
}
static inline issuez_op issuez_remove_attachment(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_REMOVE;
    o.target = ISSUEZ_FIELD_ATTACHMENTS;
    o.str = v;
    return o;
}
static inline issuez_op issuez_set_original_author(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_ORIGINAL_AUTHOR;
    o.str = v;
    return o;
}
static inline issuez_op issuez_set_original_id(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_ORIGINAL_ID;
    o.str = v;
    return o;
}
static inline issuez_op issuez_edit_comment(issuez_oid v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_EDIT_COMMENT;
    o.oid = v;
    return o;
}
static inline issuez_op issuez_expect_edits(int64_t v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_EXPECT_EDITS;
    o.num = v;
    return o;
}
static inline issuez_op issuez_delete_comment(issuez_oid v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_DELETE_COMMENT;
    o.oid = v;
    return o;
}
static inline issuez_op issuez_restore_comment(issuez_oid v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_RESTORE_COMMENT;
    o.oid = v;
    return o;
}
static inline issuez_op issuez_add_reaction(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_FIELD_REACTIONS;
    o.str = v;
    return o;
}
static inline issuez_op issuez_remove_reaction(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_REMOVE;
    o.target = ISSUEZ_FIELD_REACTIONS;
    o.str = v;
    return o;
}
static inline issuez_op issuez_reaction_target(issuez_oid v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_REACTION_TARGET;
    o.oid = v;
    return o;
}
static inline issuez_op issuez_q_deleted(int64_t deleted) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_Q_DELETED;
    o.num = deleted;
    return o;
}
static inline issuez_op issuez_q_workflow_state(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_OPT_Q_WORKFLOW_STATE;
    o.str = v;
    return o;
}
static inline issuez_op issuez_q_no_labels(void) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_Q_NO_LABELS;
    return o;
}
static inline issuez_op issuez_q_author(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_OPT_Q_AUTHOR;
    o.str = v;
    return o;
}
static inline issuez_op issuez_q_priority(issuez_priority priority) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_OPT_Q_PRIORITY;
    o.num = priority;
    return o;
}
static inline issuez_op issuez_q_milestone(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_OPT_Q_MILESTONE;
    o.str = v;
    return o;
}
static inline issuez_op issuez_q_parent(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_Q_PARENT;
    o.str = v;
    return o;
}
static inline issuez_op issuez_q_blocked(bool blocked) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_Q_BLOCKED;
    o.num = blocked;
    return o;
}
static inline issuez_op issuez_q_updated(int64_t after, int64_t before) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_Q_UPDATED;
    o.num = after;
    o.num2 = before;
    return o;
}
static inline issuez_op issuez_q_text(issuez_str text, bool ignore_case) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_Q_TEXT;
    o.str = text;
    o.num = ignore_case;
    return o;
}
static inline issuez_op issuez_q_order(issuez_sort sort, bool ascending) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_Q_ORDER;
    o.num = sort;
    o.num2 = ascending;
    return o;
}
static inline issuez_op issuez_opt_env(issuez_str key, issuez_str value) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_ENV;
    o.name = key;
    o.str = value;
    return o;
}
static inline issuez_op issuez_opt_done_state(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_OPT_DONE_STATE;
    o.str = v;
    return o;
}
static inline issuez_op issuez_opt_workflow_state(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_OPT_WORKFLOW_STATE;
    o.str = v;
    return o;
}
static inline issuez_op issuez_opt_exclusive_scope(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_OPT_EXCLUSIVE_SCOPE;
    o.str = v;
    return o;
}
static inline issuez_op issuez_opt_extra_prefix(issuez_str v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_ADD;
    o.target = ISSUEZ_OPT_EXTRA_PREFIX;
    o.str = v;
    return o;
}
static inline issuez_op issuez_opt_timeout_local_ms(int64_t v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_TIMEOUT_LOCAL_MS;
    o.num = v;
    return o;
}
static inline issuez_op issuez_opt_limit(issuez_str name, int64_t value) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_LIMIT;
    o.name = name;
    o.num = value;
    return o;
}
static inline issuez_op issuez_opt_cache_issues(int64_t v) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_CACHE_ISSUES;
    o.num = v;
    return o;
}
static inline issuez_op issuez_opt_attachment_store(bool store) {
    issuez_op o = ISSUEZ_OP_INIT;
    o.verb = ISSUEZ_OP_SET;
    o.target = ISSUEZ_OPT_ATTACHMENT_STORE;
    o.num = store;
    return o;
}
#ifdef __cplusplus
}
#endif

#endif /* ISSUEZ_H */

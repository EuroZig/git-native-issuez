# Changelog

All notable changes to git-native-issuez. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/). Before 1.0, minor
versions may change the library API; the on-disk format only ever grows (see
[docs/format.md](docs/format.md)).

## [Unreleased]

## [0.5.0] - 2026-11-10

Zig 0.17, and a purge fix. The library API, the C ABI and the on-disk
format are as in 0.4.0, but a C host needs the 0.5.0 `issuez.h`: before
1.0, the header and the library must have the same minor version.

### Changed

- Building needs Zig 0.17 (0.17.1 recommended); Zig 0.16 is no longer
  supported. The TUI, MCP server and watcher dependencies (libvaxis,
  blitzmcp, nightwatch) moved to their Zig 0.17 versions. Projects that
  depend on the library need Zig 0.17 too.

### Fixed

- A Zig call to the header's `issuez_add_attachment`, translated with
  translate-c (`b.addTranslateC`), builds on x86_64 macOS again: the LLVM
  error listed under 0.4.0's known limitations was Zig 0.16's.
- A comment purge that upstream's merge undid, the comment back beside its
  rewrite, could leave an edit of the comment with its text. The next sync
  then rewrote the issue differently from the remote's copy, merged the two
  with a conflict, and pushed a history the push check refuses
  (`invalid_history`, `purged`). Purging now rewrites until nothing changes
  ([docs/format.md](docs/format.md) §10).

## [0.4.0] - 2026-11-08

The library can now be embedded from other languages, through a C API and a Go
binding. Also new: purge, for moderation and legal requests; a push check for
pre-receive hooks; and reactions, locks, issue numbers, several assignees and
import provenance. The Zig library's API changed in many places (see Changed);
the on-disk format only grew.

- C: the `libissuez-*` archives with this release, or `zig build capi`.
- Go: `go get github.com/EuroZig/git-native-issuez-go/issuez`.

### Added

- `zig build link` symlinks a checkout's build (`git-issue`, its entry
  points, completions and man pages) into `~/.local`, or `-Dlink-prefix`,
  so each later `zig build` updates what runs. `zig build unlink` removes
  those symlinks and nothing else.
- Host APIs: exact-tip issue and milestone reads and receipt reloads;
  C/Go prepared attachments for an external LFS store; staged imports
  with inherited options, atomic publication and automatic cleanup.
  `GitProcess.beginImport` exposes staging to Zig callers.
- Text edit preconditions in Zig (`EditSpec.expect_edits`) are checked inside the CAS retry loop,
  so unrelated writes do not cause false text conflicts.
- Attachments in the commit of another write: a new issue's root, a
  comment, a description or comment edit (`CreateSpec.attachments`,
  `EditSpec.attachments`; `Attachments.prepare` and `storeBytes`). In the C API, ADD and REMOVE
  ATTACHMENTS in issue op lists, `ISSUEZ_OPT_EDIT_COMMENT`,
  `ISSUEZ_OPT_ATTACHMENT_STORE` (a host keeps the bytes),
  and `issuez_issue_attachment_count`/`_at`;
  in Go, `Edit.AddAttachment`, `RemoveAttachment`, `EditComment`,
  `WithAttachmentStore` and `Issue.Attachments`.
- `X-Author-Id: <uuid>` (format.md §2): an actor's `user_id` goes on every
  commit it writes, and comes back as the author's `user_id` on issues,
  comments, timeline entries and receipts (Go `Person.UserID`). Hosts map
  authors by it, not by an email that may change. The push check refuses
  an `X-Author-Id` that isn't the pusher's under its author policy
  (`ISSUEZ_OPT_PUSHER_USER_ID`, the pusher's `user_id`, Go
  `PushPolicy.PusherUserIDs`).
- Go: end-to-end tests (`bindings/go/issuez/e2e`, build tag `e2e`) of the
  binding as a host uses it, against the CLI as clients do: indexing
  pushes, a pre-receive hook in Go, numbers, purges, attachments,
  concurrent writes and upstream's issues.
  `zig build test-go-e2e` runs them, `zig build test-bindings` every C API
  and Go test.
- Go: fuzz tests for `ParseOID`, `Snapshot.UnmarshalBinary` and
  validating an `Edit`, run by `zig build fuzz-go [-Dfuzz-time=60s]`. The build
  tag `issuez_debug` links an archive that counts its allocations, so they
  also check for leaks. `zig build test-go` runs their seeds that way and
  fails under 95% statement coverage.
- Go: `SetDefaultLogger` with `LogLevel` and `LogEvent`, `WithCacheIssues`, and
  the problem kinds it didn't name yet.
- `WriteOptions.dry_run`: a write runs every check, guards included (closed
  ancestor, open sub-issues, cycles, numbers taken, closed milestones), and
  writes nothing.
- Issues and milestones can be created closed (or in any state, with
  `Fixed-By`, `Release`, `Reason`) and completed or retired, on their
  root commit: imports bring them that way. `CreateSpec.state`,
  milestone `CreateSpec.status`; in the C API `SET STATE` and
  `SET MILESTONE_STATUS` on create.
- MCP: `react_issue` (an emoji on an issue or a comment, or taking it
  back); `create_issue`, `edit_issue` and `comment_issue` take a host's
  `fields` and import provenance (`original_author`, `original_id`);
  `show_issue` reports reactions, provenance and purged comments. Purging
  stays out of the MCP server on purpose.
- TUI: the detail view shows the number, a lock and its reason, the ref,
  where an imported issue or comment came from, every assignee, reactions
  and purged comments.
- C API: cancelling a call kills a git request that is running within about
  50 ms; a repo handle keeps issues loaded by tip (`ISSUEZ_OPT_CACHE_ISSUES`),
  so queries load only issues that changed; `issuez_write_retries` reports
  the write's CAS retries (`Receipt.retries` in the library).
- Push check, for a host's pre-receive hook ([docs/format.md](docs/format.md)
  §11): `git issue push-check [--authors any|warn|enforce] [--pusher-email
  <email>]... [--pusher-id <uuid>]... [--allow-numbers] [--allow-purge]` reads
  the hook's input and
  refuses non-fast-forwards, deletes, local-only refs, histories that fail
  `fsck` or have another `Format-Version`, client numbers, other people's
  commits (by policy), tombstones without leave to purge and attachment
  refs that aren't derived commits of their issue, purged text under any
  UUID (a tombstone's purged comments and purged issue roots) and an
  `X-Rewritten-From` that names a commit of the history; it reports issues
  without a number and commits to locked issues. Sync merges are checked
  within a budget (`Policy.max_merge_work`), past which none is exempt.
  One update per line on stdin. Reads git's quarantine and writes nothing.
  `PushCheck(B)` in the library, `issuez_push_check` with
  `ISSUEZ_OPT_ALLOW_PURGE` in the C API, `Repo.PushCheck` in the Go
  binding.
- Purge, for moderation and legal requests ([docs/format.md](docs/format.md)
  §10): `git issue purge <id> [--comment <id>] [--reason <text>] --yes`
  removes an issue, or one comment's text, attachments and origin, from
  history. A comment purge rewrites the issue deterministically from that
  commit on (`X-Purged`, `X-Rewritten-From`), so every clone gets the same
  commits; an `X-Rewritten-From` naming a commit still in the history is
  ignored. A tombstone, `refs/issuez-purged/<uuid>` (an issue's names its
  root, `X-Purged-Root`), syncs with the
  issues; merge and push apply it and replace or delete the remote's copy
  with the one push that isn't a fast-forward, leased on what was fetched.
  `purged` per comment in `--json`; `Purge(B)` in the library, the backend
  op `pushLeased`, `issuez_purge_issue`/`_comment` in the C API,
  `PurgeIssue`/`PurgeComment` in the Go binding.
- Reactions: `git issue react <id> <emoji> [--on <comment>] [--undo]`,
  event commits with `X-Event: reaction` and `X-Reaction: +<emoji>` or
  `-<emoji>`, per (target, emoji, author) merged like a set member
  ([docs/format.md](docs/format.md) §5); `reactions` in `--json`,
  `Repo.react` and `Issue.reactions` in the library. Reacting the same
  way twice writes nothing.
- Host fields and import provenance ([docs/format.md](docs/format.md) §2):
  `X-` keys the format doesn't use are fields of a host's own
  (`X-Forgejo-Project`), and `X-Original-Author` / `X-Original-Id` say
  where imported text came from, per commit; a commit that only sets host
  fields reads as an update. `create`/`edit --field
  KEY=VALUE`, `--original-author`, `--original-id` (also on `comment`);
  `original_author`/`original_id` in `show --json`; `CreateSpec.extra`,
  `EditSpec.extra`, `.original` on create, edit and comment specs.
- Locks and refs: `X-Locked` with `X-Lock-Reason` (information for hosts,
  which decide who may still comment) and `X-Ref`, the branch or tag an
  issue is about, a name `git check-ref-format --allow-onelevel` takes
  ([docs/format.md](docs/format.md) §3). `edit --lock`,
  `--lock-reason`, `--unlock`, `--ref`; `locked`, `lock_reason` and `ref`
  in `--json` and the MCP server; `EditSpec.locked`, `.lock_reason`, `.ref`.
- Issue numbers: `X-Number` ([docs/format.md](docs/format.md) §3), the
  issue's number in its host, written once and unique in a clone
  (`NumberAlreadySet`, `NumberTaken`, guarded by
  `refs/issuez-guard/number-<n>`). `#12` names an issue wherever an ID is
  taken, through the parents cache (now version 2, with each issue's
  number). `create`/`edit --number`, `number` in `--json` and the MCP
  server, `show` prints it, `ls --problems` reports duplicates from
  other clones (`duplicate_number`).
- Several assignees: `X-Assignees` ([docs/format.md](docs/format.md) §3),
  written beside `Assignee` (the first) only when there are two or more,
  so one assignee stays format 1 as it is; upstream's own `Assignee` edit
  sets them to that one. After concurrent edits `Assignee` is the newest
  one still assigned, else the first. `create`/`edit --add-assignee`, `edit
  --unassign`, `assignees` in `--json` and the MCP server, `ls -a`
  matching anyone assigned; `CreateSpec.assignees`,
  `EditSpec.set_assignees`/`add_assignees`/`remove_assignees` and
  `Extensions.assignees` in the library.
- A comment, a state change and field edits in one commit:
  `edit -c <text>`, `edit --state <value>` (with `--fixed-by`, `--release`,
  `--reason`), `state`/`close`/`reopen -c <text>`, and `comment` on the MCP
  server's `edit_issue` and `set_issue_state`. The commit's text is the
  comment, marked `X-Message: comment` so it reads as one beside the fields
  ([docs/format.md](docs/format.md) §2); upstream shows it as text with
  one more trailer line. `EditSpec.state`, `.fixed_by`, `.release`,
  `.reason` and `.comment` in the library.
- Every version of the description and of each comment: `show --history`,
  `description_history` and per-comment `history` in `show --json`, and
  `Issue.description_history` / `Comment.history` in the library.
- What each commit changed, typed: `changes` per comment and
  `created_changes` in `show --json` (`set`, `clear`, `add`, `remove`, with
  the values as written), `Comment.changes`, `Issue.created_changes` and
  `Issue.steps` (every commit after the root, events included) in the
  library; the C API's timeline entries and write receipts carry them.
- `libissuez-<version>-<platform>.tar.gz` in each release: the C library, its
  header and its API description, for macOS and Linux (glibc and musl).
- `issuez.version`, the version of the Zig library. The C API's
  `issuez_version()` and Go's `Version()` report it, like `git issue version`
  and the MCP server: `0.4.0-12-ga3e21cfa` built from a checkout past the tag.
  The header's `ISSUEZ_VERSION_*` follow `build.zig.zon`.
- `THIRD_PARTY_LICENSES` in every release archive, with the notices of the code
  they link.
- A C API for embedding the library in other languages: `zig build capi`
  builds `libissuez.a` with `issuez.h`, both generated from one description
  (`src/capi/api.zig`), and `docs/issuez-api.json` for binding generators.
  Op lists instead of builders, typed problems that point at the op they
  came from, cancel tokens, a thread-safe repo with a pool of git sessions
  (a call in flight keeps it open). An actor or committer git can't sign
  with is refused.
  An issue's and a milestone's single values come as one record
  (`issuez_issue_info_of`, `issuez_milestone_info_of`) that grows only at
  the end; lists and lookups have their own calls.
- A Go binding, `bindings/go` (cgo, Go 1.26): results copied into Go
  values, contexts for cancellation, `issuez.Edit` and `issuez.Query`
  values for writes and queries. `zig build go-libs`, `test-go`. Each release
  writes `github.com/EuroZig/git-native-issuez-go`, the binding with the
  archives in the module, so `go get` is all it takes. It also tags the module
  here as `bindings/go/vX.Y.Z`, which links the release's `libissuez` archive
  through `CGO_LDFLAGS` (see its README).
- `GitProcess.OpenOptions.git`: the git binary to run.
- Go: `RefPrefixes`, `IsRef` and `RefSpecs`, the library's ref namespaces
  and forced refspecs for mirrors, so hosts don't restate them.
- Go: `WithEnvOverrides`, variables on top of the process environment
  (`WithEnv` replaces it), so a host forces its own without copying
  `os.Environ()`.
- Go: `UserMessage(err)`, the message of a write refused for a rule the
  user can act on (an invalid value, a limit, a guard), for hosts to show.
- Go: `Repo.ResolveNumber(n)`, the issue numbered n.
- Go: `StateOpen` and `StateClosed` for `Edit.SetState`.
- Go: `Issue.Edits` and `Comment.Edits`, how often the description and a
  comment were edited, without `LoadHistory`: a version for a host's
  optimistic locking that doesn't need every text copied.
- Go: `Revision.Previous`, the text an edit replaced, for notifications
  that show both.
- `issuez_issue_load_since`: timeline entries say whether their commit is
  new since a tip a host saw (`issuez_entry.is_new`), by reachability, so
  commits merged in from a clone count even when they sort before it; a
  tip outside the history (a purge rewrote it) sets
  `issuez_issue_info.rewritten`. In Go, the load option `Since(tip)`,
  `Entry.New`, `Issue.Rewritten` and `Issue.NewEntries`.
- `issuez_repo_limit` (Go `Repo.Limit`), a limit's effective value, so a
  host checks sizes against the library's limits without restating them;
  Go `WithRetries`, the write retry budget (limit `cas_retries`).
  `ISSUEZ_E_CONTENDED` (Go `CodeContended`) is documented as final.
- Go: `Pool`, open repositories kept per key for hosts that serve many:
  shared by concurrent calls, the least recently used idle ones closed
  past a bound, dropped when a repository moves, `Forget` and `Close`.
- C API: `issuez_push_verdict.entry_count`, how many timeline entries
  `issuez_push_verdict_entry_at` has; `commit_count` counts commits.
- An attachment says the comment it belongs to and when it was added
  (`issuez_attachment.comment`, `at`; Go `Attachment.Comment`, `At`): the
  comment that added it or that its edit edits; none for the
  description's.
- `ISSUEZ_OPT_EXPECT_EDITS` (Go `Edit.ExpectEdits`): an update that edits
  the description or a comment fails with `VERSION_MISMATCH` unless that
  text was edited exactly so often, a form's version of the text that
  other changes to the issue don't touch.
- Milestones say when they were last changed, when their status was
  set (a completed one's closing time) and who created them
  (`updated`, `status_changed` and `author` of `issuez_milestone_info`; Go `Milestone.Updated`, `StatusChanged`,
  `Author`; in the library `Milestone.updated`, `status_changed`,
  `author`, `author_id`).
- Purge results list the attachments the purge took out of history
  (`issuez_purge_result_attachment_count`/`_at`, Go
  `PurgeResult.RemovedAttachments`), for hosts that keep the bytes.
- Push verdicts carry what a host's permission rules need without
  loading the issue: who opened it (`issuez_push_verdict.issue_author`,
  Go `PushVerdict.IssueAuthor`) and the attachments the new commits add
  with their LFS pointers (`attachment_count`,
  `issuez_push_verdict_attachment_at`; Go `PushVerdict.Attachments`).
  Go timeline entries name the author of the comment they add or touch
  (`Entry.CommentAuthor`).
- `Repo.dropAll`: every ref of the library's deleted in one transaction, to undo an
  import into a repository that had none.
- `Repo.adoptFrom`: a repository takes every issue, milestone,
  attachment and tombstone ref of another in one transaction. An import
  written into a scratch repository that uses this one's objects lands
  at once or not at all.
- C API: op helpers for every target the op lists take; new are
  `issuez_set_ref`, `issuez_clear_ref`, `issuez_set_locked`,
  `issuez_add_attachment`, `issuez_remove_attachment`,
  `issuez_set_original_author`, `issuez_set_original_id`,
  `issuez_edit_comment`, `issuez_expect_edits`, the query helpers
  `issuez_q_deleted`, `_workflow_state`, `_no_labels`, `_author`,
  `_priority`, `_milestone`, `_parent`, `_blocked`, `_updated`, `_text`,
  `_order`, and the open options `issuez_opt_env`,
  `_done_state`, `_workflow_state`, `_exclusive_scope`, `_extra_prefix`,
  `_timeout_local_ms`, `_limit`, `_cache_issues`, `_attachment_store`.
- Across issues, for pickers, filters and lists: the labels in use with
  counts, the people the history knows (authors and assignees), and the
  shortest unique ID prefixes. In the library `query.labelCounts`,
  `query.people`, `query.shortIds`.
- Writing the settings: `settings.write` (done and workflow states into
  git config, checked).
- `issuez_repo_set_logger` (Go `Repo.SetLogger`): a repo's own logger
  for its calls, in place of the process-wide one, so a host serving many
  repositories, or tests running side by side, can tell their events
  apart.
- Setting a remote up for issues is the library's (`remote.default`,
  `remote.configure`), not the CLI's; `git issue init` calls it.
- Fsck is the library's (`fsck.Fsck(B).run`, a report of events with
  `describe`); `git issue fsck` renders it with the same output. In the
  C API `issuez_fsck` with its report, in Go `Repo.Fsck`: they write nothing,
  and leave the bytes alone when the host keeps them (`check_bytes`).
- `Repo.open(arena, backend)` and `Repo.fromSettings(backend, settings)`: a
  repo with git config's issue settings applied (`Repo.settings`),
  refusing an invalid `issue.doneStates` (`error.InvalidDoneStates`).
  The CLI, MCP server and TUI use them in place of reading and applying
  the settings themselves.
- `Repo.update(arena, id, Update, WriteOptions)`: one entry for every
  write to an issue (fields, comments, description and comment edits,
  comment deletes and restores, soft deletes, reactions), routed to the
  commit it takes, with a `Receipt` (tip, wrote, retries, kind) in place
  of the `retries` and `skipped` pointer fields. The C API's update goes
  through it.
- C API: comment deletes and restores and reactions are update ops too
  (`ISSUEZ_OPT_DELETE_COMMENT`, `ISSUEZ_OPT_RESTORE_COMMENT`,
  `ISSUEZ_FIELD_REACTIONS` ADD and REMOVE with
  `ISSUEZ_OPT_REACTION_TARGET`; helpers `issuez_delete_comment`,
  `issuez_restore_comment`, `issuez_add_reaction`,
  `issuez_remove_reaction`, `issuez_reaction_target`), so every write
  to an issue goes through `issuez_issue_update`. Go `Edit.DeleteComment`,
  `Edit.RestoreComment`, `Edit.React`.
- `issuez.Store(B)`: a live view of a repository (every issue and
  milestone with the projection, `Snapshot.find`, `resolve`,
  `milestoneName`), whose `refresh` reloads only the issues whose refs
  moved and says what changed. The TUI's store is built on it, so a
  change elsewhere no longer reloads every issue.
- `issuez.view`: an issue as front ends show it, worked out once: its
  closure (who closed it, when), timeline entries with their comment and
  per-field typed changes, and each attachment's comment. The C API reads
  it instead of its own copies.
- Writes say what they refused: `errors.Diagnostics` (on `Repo`, or per
  call in `WriteOptions`) collects the error with the field's trailer
  key, the value and the limit. The C API's problems carry that key and
  value instead of a field guessed from the error.
- `issuez.open(B, arena, backend)` and `issuez.Handle(B)`: one entry to
  the library, a repository opened with its settings and every part over
  it (`milestones`, `sync`, `attachments`, `purge`, `pushCheck`, `fsck`,
  `store`, `configureRemote`). `Sync.fromRepo` keeps a repo's settings.
- `closed` in issue JSON (`ls`, `show`, `tree`, `search --json`,
  MCP issues): who closed a done issue, when, and
  the commit (`issuez.view.closure`); `null` while it is open.
- TUI: `M` lists the open milestones with their progress and filters the
  list and board by the one chosen (or by none).
- `git issue merge`, `push` and `sync` (and `Sync` in the library) take a
  URL or path instead of a remote's name: fetch and push go there, its
  refs under `refs/issuez-sync/url-<hash>/`. Only `github:`, `gitlab:`,
  `gitea:` and `forgejo:` targets are upstream's bridges.
- `examples/c/quickstart.c`, the C API's quickstart: `zig build
  example-c-quickstart`; `test-capi` runs it too.
- Go: every enum has a `String` method, its value's name in snake case
  (`PushFastForward` prints `fast_forward`, `PriorityNone` `none`), generated
  by `internal/enumgen` (`go generate`).
- Go: `Repo.All(ctx, q)`, an `iter.Seq2[*Issue, error]` over every page
  of a query: `for issue, err := range repo.All(ctx, q)`.

### Changed

- Faster on ReleaseSafe builds, which is what releases are: short lists no
  longer pay for `std.mem.sort`'s 512-item cache, which took half the time of
  `git issue ls -a` over 10 000 issues (1.18 s to 0.55 s).
- On macOS, `GitProcess` runs the real git rather than `/usr/bin/git`, which
  spends about 5 ms finding it on every run. Only when that stub is what's
  first on `PATH` and no other git was asked for.
- `git issue version` and `git issue help` no longer run git.
- `zig build test` and `ci` split `capi-zig`, `cli_git`, `interop` and
  `backend_git` into parallel runs, and `ci` runs upstream's suite and the Go
  tests alongside everything else: their output now only shows on a failure.
  `zig build test-upstream-suite` alone still prints its report.
- `zig build test-perf` and `ci` time both flavors, each fully ReleaseSafe. It
  used to time the CLI-only flavor with the library built for `-Doptimize`.
- Built from a git checkout, `git issue version` names the commit:
  `0.3.0-12-ga3e21cfa` twelve commits after v0.3.0, with `-dirty` for
  uncommitted changes. Release builds print just the version.
- Library writes take an issue's UUID where they took its ref name
  (`edit`, `comment`, `setState`, `setDeleted`, `commentEvent`,
  attachments), and `Repo.find` loads an issue by UUID; callers stop
  building `refs/issues/<uuid>` themselves.
- Write specs take dates as `format.fields.Date`: `CreateSpec.start_date`/
  `due_date` and the milestone `CreateSpec.due`, and `.{ .set = date }`
  or `.clear` (`EditSpec.DateEdit`) in `EditSpec` and the milestone
  `EditSpec.due`. `""` no longer clears a date. `Date.isValid`.
- Write specs take assignees as `format.fields.Assignee` (`.byEmail(e)`, or
  `.{ .uuid, .email }` for a host user): `CreateSpec.assignees`,
  `EditSpec.set_assignees` and `add_assignees`; `remove_assignees` are
  emails. `CreateSpec.assignee` and `EditSpec.assignee` are gone:
  `set_assignees = &.{}` unassigns everyone.
- The milestone of a write is one field, `CreateSpec.milestone`/
  `EditSpec.milestone: ?MilestoneEdit`: a text and a link (`keep`,
  `.id`, `pin`, `inherit`, `none`), with `.named(text)` and `.linked(id)`.
  It replaces `milestone`, `milestone_id` and `milestone_mode`;
  `Catalog.Choice.edit()` gives one from a name.
- One way to clear a field in `EditSpec`: `.clear`. `parent`, `workflow`
  and `ref` are `Edit([]const u8)` like the dates, estimate and priority;
  `.fromInput(text)` reads empty input as `.clear`. `""` no longer clears them.
- `Repo` holds only `backend`, `limits` and `settings`: `done_states` and
  `workflow_states` are `doneStates()` and `workflowStates()` (from the
  settings), and the per-call `retries`, `skipped` and `listing` moved to
  the internal `call`; pass `WriteOptions` and read the `Receipt`.
  `Settings.apply` is gone.
- Every issue write returns a `Receipt` (tip, wrote, retries, kind, and an
  edit's `changes`): `comment`, `setState`, `setDeleted` and `commentEvent`
  are shorthands for `update`, and `edit` for one edit commit. `EditResult`
  and `editDescription` (use `edit` with `.description`) are gone.
- `Repo.Created.id` and `Catalog.Created.id` are the full UUID as a
  string, what `find`, `resolve` and every write take (was a `Uuid`:
  drop `.slice()`). `issuez.shortId` gives the 7-character form (was
  `id.short()`).
- The root re-exports the types callers name most (`issuez.GitProcess`,
  `GitSim`, `Oid`, `Issue`, `IssueRef`, the write specs, `Update`,
  `Receipt`, `WriteOptions`, `Created`, `Edit`, `CommentEvent`).
  `CommentEvent` and the issue `Created` moved out of `Repo(B)`:
  `issuez.CommentEvent`, not `Repo(B).CommentEvent`. The quickstart and
  README start from `issuez.open`.
- `Oid.hexAlloc(gpa)` for the hex in memory; `MilestoneEdit.of`/`parts`
  are `fromParts`/`toParts`, and `Edit(T).input` is `fromInput`.
- `Sync.sync` and `Sync.push` take their `PushOptions` (`.{}` for none);
  `syncWith` and `pushWith` are gone.
- `Repo.check` takes `CheckOptions{ .root_keys }` (`checkWith` is gone).
  Every part comes from a repo the same way: `Catalog.fromRepo` (was
  `of`), as `Sync` and `Attachments`. `appendWith` is `appendIssue`,
  beside `appendMilestone`.
- `Repo.Error` is the union of named area sets, `ReadError`,
  `FormatError`, `GuardError`, `RaceError` and `AttachmentError`, so a
  `switch` can handle an area at once. Reads (`load`, `find`, `loadAll`,
  `loadPage`, `refs`, `resolve`, ...) return `LoadError`, without the write
  errors.
- `Issue` is flat: the extension fields (`parent`, `blocked_by`,
  `assignees`, `number`, `due_date`, `milestone_id`, ...) sit on it
  instead of under `issue.ext` (`issue.extensions()` gives them as one
  `Extensions` value), and `priority` and `milestone` are typed fields
  (`priority()` is gone; `field("Priority")` keeps the text).
  `Extensions.invalid` is `invalid_fields`.
- Library plumbing used only in its own file is private: `FixedMessage`,
  `Catalog.projection`, `errors.hasGitDetail`, `settings.parse`,
  `parseDoneStates`, `parseWorkflowStates` and `checkWorkflowState` (use
  `Settings.checkWorkflow`), and `trailers.parseLines`.
  `Sync.mergeCommitForTest` is gone.
- `RacingSim`, a test backend, moved out of `engine` (and so out of the
  public API) into `src/engine/racing_sim.zig`, which only tests import.
- `Repo.setDeleted(arena, id, .{ .deleted = false })` takes a
  `DeleteSpec` instead of a positional `deleted` flag, and
  `commentEvent(arena, id, .{ .target, .event, .text })` a
  `CommentEventSpec` instead of three positional values; `LifecycleSpec`
  is no longer public.
- `Repo.loadPage` takes `PageOptions{ .after, .limit }`, `checkCommits`
  takes `CheckOptions` like `check`, `refs` returns `[]const IssueRef`
  (so does `Catalog.refs`), and `milestoneInfo` returns `LoadError`.
- Library plumbing that sibling parts need stays `pub` (Zig has no
  package-private declarations), but says so: its doc starts with
  "Internal:" (`refFor`, `Repo.appendIssue`, `writeCommit`, `identity`,
  `readGuardRef`, the attachment derivation, purge's
  `readAt`/`rewrite`/`apply`/`unionOf`, ...), and `root.zig` states the
  rule. `readGuardRef` is a `Repo` method instead of taking `backend:
  anytype`, and `Guarded.ops` is private.
- Backends: `fetch` and `push` take `contract.FetchOptions{ .prune }`
  and `contract.PushOptions{ .atomic }` instead of a positional flag; a
  custom backend changes its signatures to match.
- Backends: one `contract.ConfigEntry` (GitProcess's and GitSim's are
  aliases), and the contract lists the optional `configList`;
  `settings.fromConfig` takes `[]const contract.ConfigEntry` instead of
  `anytype`.
- `Sync.pushFetched` is gone: `push(arena, remote, .{ .fetch = false })`
  right after a `merge` (`PushOptions.fetch`, as `MergeOptions.fetch`).
- `Attachments(B).derivedRefName` is `attachments.refName` at module
  level, like `purge.refName`.
- Problems print with `{f}`: `Repo(B).Problem` and `projection.Problem` have
  `format` (was `describeProblem` and `Problem.describe(arena)`), and
  `AttachmentProblem.Kind.text()` gives a problem kind's text.
- `Catalog.resolve` tells a retired milestone's name apart
  (`.retired_name`); `lookup`, its twin, and `editDescription` (use
  `edit(.{ .description })`) are gone.
- `changes.RefState.read` and `settings.read` take `comptime B: type` and
  `backend: *B` (as `issuez.open`) instead of `backend: anytype`, and name
  their error sets.
- `changes.Diff.empty()` is `isEmpty()`: `.empty` names an empty value in
  Zig, not a check.
- `attachments.Entry` and `Availability` are module-level (were
  `Attachments(B).Entry`).
- `Projection`'s query methods take `*const Projection` (it is large),
  and `Projection.empty` is the projection over no issues.
- `format.fields.MilestoneMode.of(written, .{ .has_id, .has_parent })`
  and `format.trailers.textLines(arena, body, .{ .has_title })` take an
  options struct instead of positional flags.
- `schedule` takes the projection by `*const` (`summarize`, `isStarted`,
  `spans`, `milestoneSpan`, `warnings`) and `Dates.of` the issue by
  `*const`; `spans` takes one `?schedule.Overlay{ .context, .dates }`
  instead of a function and a context.
- `sync.defaultRemote(B, arena, backend)` is generic over the backend
  type with a named error set (`B.Error || error{UnknownIssueRemote}`);
  `sync.chooseRemote(names, configured)` picks among remotes already
  read.
- `local_time.parseTzif` names its error set (`Allocator.Error ||
  error{Malformed}`); `format.dates.resolve` is gone, `dates.parse`
  gives the typed `Date`; `Repo.editBatchWith` is marked Internal (the
  milestone catalog's hook into `editBatch`).
- Every write takes `WriteOptions` as its last argument: `Repo.create`,
  `comment`, `setState`, `setDeleted`, `commentEvent`, `edit` and
  `editBatch`; `Catalog.create`, `edit` and `editBatch`; `Attachments.add`,
  `remove` and `rename` (`.{}` for none). An author ID stamps every commit a
  write makes, a batch's too; a dry run checks everything and writes nothing:
  `editBatch` updates no ref, `add` stores no bytes.

### Fixed

- The terminal UI redraws when the terminal is resized.
- Push and sync failed when the remote's ref moved while it received the
  push (`[remote rejected] (atomic transaction failed)`, "cannot lock
  ref"): a host writing an issue as a client pushed it. That is the
  remote moving, like a non-fast-forward: merge and push again.
- An edit that added and removed labels checked the label limit before the
  removals, so a full issue couldn't swap one label for another.
- A derived `refs/attachments/<uuid>` whose `X-Issue-Tip` left the issue's
  history (after `quarantine --accept-remote`) is regenerated before a
  push, so it never names a tip the remote doesn't have.
- A write that restates labels, assignees or blockers in another order
  is no change: it keeps the order the issue has and writes nothing. It
  wrote a commit that only reordered them. Documented: an update that
  states values the issue has writes nothing, so a host can state the
  whole state it wants.
- zsh completion offered no subcommands for `git issue attach`: the
  apostrophe in "attachment's" left `_arguments`' list unparsed.

### Known limitations

- Zig 0.16 can't compile a call to the header's `issuez_add_attachment`
  through `@cImport` on x86_64 macOS (LLVM: "Intrinsic has incorrect
  argument type!"). Build that op by hand there, as
  `test/capi_zig/helpers_test.zig` does; C and Go callers aren't affected.

## [0.3.0] - 2026-11-05

### Added
- The terminal UI's milestones view (`3`): every milestone with a progress
  bar, open, done and blocked counts, the due date and how far off it is,
  and its health (on track, at risk, overdue). Sorted by due date, name,
  progress, open work, health or creation, scoped to open, completed,
  retired or all, filtered with `is:overdue`, `is:at-risk`, `is:empty`,
  `due:<date` and words. Milestones are created, renamed, given a due date,
  completed (after saying what is still open), retired and reopened there.
- One milestone's issues, or those in none: moved to another milestone with
  a menu, `[` and `]`, several at once with marks, or dragged between two
  panes; created in it with the form or one title after another. Moving an
  issue that inherits its milestone asks whether alone or with its parent.
  `+` (or the "Add issues" button) brings existing issues in: a list of
  everything elsewhere to search as you type, Tab marks several. `m` (or
  "Move to…") moves the selected or marked issues out the same way.
- An issue's detail view adds existing issues as sub-issues: `A` (or the
  "+ Existing" button, or the row under the sub-issues) opens the same
  list to search, Tab marks several, and they move under it in one write.
  Its ancestors and current sub-issues aren't offered; `a` still creates
  a new one.
- The timeline (`4`): milestones, issues and blockers over the days, by
  day, week or month, with what doesn't fit marked. Its edit mode stages
  moves, new dates, estimates, milestones and blockers, by key or by
  dragging, with undo; `ctrl+s` writes them all at once, and leaving the
  view asks to apply or discard them. Changes made elsewhere meanwhile are
  marked, to keep or drop.
- Syncing from the TUI: a badge with what is unpushed, quarantined and in
  conflict for the remote; `y` syncs in the background (fetch, merge,
  push) with progress in the status line; `Y` opens a panel listing them,
  resolving quarantines (`a` accepts the remote's version, `l` keeps
  ours) and opening conflicting fields. `↑` and `!` mark issues in the
  list, board and detail view, and `is:unpushed` / `is:quarantined`
  filter them.
  `git config issue.remote` picks the remote and `issue.autoSync`
  fetches and merges every so many minutes, never pushing. git never
  prompts on the TUI's terminal: it runs without one, ssh in batch mode
  unless you set your own ssh command. With OpenSSH 8.4 or later, outside
  Windows, syncs share one ssh connection for 5 minutes through a socket
  in a private directory, so the fetch, the push and the next syncs pay
  the handshake once; a push right after a fetch doesn't fetch again.
  Quitting during a sync stops it.
- Dates take `today`, `tomorrow`, `+3d`, `-1w`, `+2m`, `fri`, `eom` and
  `eow` besides `YYYY-MM-DD`: in the TUI, which shows the date they mean
  as they are typed, in `--start` and `--due` (issues and milestones), and
  in the MCP tools' `start` and `due`. "Today" is the local date, from
  `TZ` or `/etc/localtime`. What is written is always `YYYY-MM-DD`.
- `git config issue.workDays` and `issue.hoursPerDay`: which days count in
  a schedule, and how long an estimate's day is.
- Library: sync progress phases, `Sync.unpushed` and `Sync.counts`,
  `sync.defaultRemote` (`UnknownIssueRemote` when `issue.remote` names
  no remote), and the `issue.autoSync` setting.
- Library: `format.dates` parses dates as people type them, relative to
  a given today (`dates.resolve` gives `YYYY-MM-DD`); `local_time` reads
  the local time zone (`TZ`, `/etc/localtime`) without libc; `Date` has
  `addMonths`, `endOfMonth` and `daysInMonth`.
- Library: `GitProcess.OpenOptions.no_terminal` runs git without a
  controlling terminal (a session of its own on POSIX, no console on
  Windows); stopping such a call stops its whole process group.
- Library: `Repo.editBatch` and `Catalog.editBatch` write several issues'
  edits, and milestones' due dates, in one ref transaction, checking the
  rules (parents, depth, blockers, milestones) on the issues as the batch
  leaves them; `Catalog.editBatch` returns the milestones' new tips too.
  `schedule` summarizes milestones, rates their health (in the caller's
  time zone), and turns dates and estimates into timeline spans with
  their warnings; `fields.Date` counts days and `fields.WorkDays` working
  days.

### Changed
- Library: `settings.parse(arena, done, workflow)` is now
  `settings.parse(arena, raw)`, taking every raw `issue.*` value at once.
- The TUI's milestone menu links by milestone ID, so two milestones of one
  name are no longer refused, and offers inheriting from the parent.
- `install.sh` is a quarter of its size: download, check against
  `SHA256SUMS`, unpack, and write `update-git-native-issuez`. `--uninstall`
  stays. Gone: the sudo handling (pipe it into `sudo sh` for a system
  prefix), the downgrade and reinstall guards, and the wget and openssl
  fallbacks (it needs `curl`, and `sha256sum` or `shasum`).

### Fixed
- Timeline draft conflicts on milestones can be kept with `r` or dropped
  with `X`; applying selects the stale milestone without losing other edits.
- The TUI refreshes its sync badge and filters when the CLI or another TUI
  changes sync records, including pushes that leave every issue tip alone.
- Restoring a closed issue is refused while open work sits below it
  (`OpenDescendants`), as closing it is. Work reopened under it while it
  was deleted left it closed over open sub-issues.

## [0.2.0] - 2026-11-03

### Added
- The terminal UI, `git issue tui`, built on the library. A sortable,
  filterable issue list, optionally as a tree of sub-issues; a kanban board
  with a column per workflow state and done work last; and a detail view
  where every field, the title and the description are edited in place,
  comments are added, and sub-issues are created from their parent. The
  filter takes words and `key:value` terms (`label:ui @ada p:high
  is:blocked -label:wontfix`). The mouse works everywhere: clicking selects
  and edits, double-clicking opens, column titles sort, cards drag between
  board columns, and the wheel scrolls. Writes check the issue hasn't
  changed since it was shown, and dialogs stay open when a write fails.
- Live updates. The terminal UI shows what other processes write (`git
  issue`, another TUI, an agent, a sync) as it happens, keeping the
  selection and open dialogs, and says which issue changed elsewhere.
- The MCP server serves the repository as resources (`git-issue://issues`,
  `git-issue://milestones`, `git-issue://issues/{id}`) with subscriptions:
  a client hears `notifications/resources/updated` when anyone changes
  what it subscribed to.
- `issuez.changes`: `RefState` and `diff`, what moved in a repository's
  issues between two reads, for long-running front ends.
- `git issue` without a command opens the terminal UI when run by a person
  at a terminal in a repository. Elsewhere (a pipe, a script, outside a
  repository, a minimal build) it still prints the usage.
- `install.sh --uninstall` (also `update-git-native-issuez --uninstall`)
  removes git-issue, its entry points, completions, man pages, docs and the
  updater from the prefix, installs by 0.1.0's script included. Other
  tools' `git-issue-*` files and the issues in your repositories stay.

### Changed
- The full build flavor, the default, now includes the terminal UI;
  `-Dtui=false` leaves it out, and `-Dminimal` still builds the CLI only.
  It adds two lazy dependencies, fetched only for builds with the TUI or
  the MCP server: libvaxis (the TUI) and nightwatch (watching the
  repository for live updates).

## [0.1.0] - 2026-11-03

The first release; everything below is new.

### Format and compatibility

- Reads and writes git-native-issue format 1. Issues written by either tool
  work in the other, and upstream's `fsck` passes on ours. Checked by
  cross-tool tests and by upstream's own test suite (219 required cases).
- Fields are computed from the whole commit history by the causal ordering
  rule. Concurrent edits are reported as conflicts instead of silently lost.
- Deterministic merge commits: clones that merge the same pair write the
  same commit. They restate the merged fields, extension fields included,
  and cleared fields as empty, so upstream shows the merged values.
- Extensions, all format-1 compatible ([docs/format.md](docs/format.md)):
  - planning fields: parent, blockers, start and due dates, estimate,
    workflow state;
  - lifecycle events: edit, delete and restore comments; edit the
    description; delete and restore issues;
  - a milestone catalog (`refs/milestones/*`) with issues linked by ID,
    inheritance through the hierarchy, and completion and retirement rules;
  - image attachments: `X-Attachment` trailers, bytes in an LFS store that
    `git lfs prune` can't lose, and a derived `refs/attachments/*` ref for
    git-lfs and LFS servers.

### CLI (`git-issue`)

- A drop-in replacement for upstream's commands: `create`, `ls`, `show`,
  `comment`, `edit`, `state`, `search`, `fsck`, `init`, `merge`, plus the
  `git-issue-<command>` entry points.
- New commands:
  - `push`, `sync` (git remotes), `status`, `quarantine`;
  - `close`, `reopen`, `delete`, `restore`, `tree`, `milestone`, `attach`;
  - `completion`.
- `sync` stages fetched refs instead of overwriting local ones, and
  quarantines unrelated or rewound remote histories instead of merging them.
  `init --fix-refspec` removes upstream's unsafe refspec.
- `--json` on read commands ([docs/json.md](docs/json.md)). `show --json`
  and the MCP server's `show_issue` mark each update as a `comment` or an
  `update` (`kind`).
- `closed` and the states in `git config issue.doneStates` (default
  `wontfix,duplicate`) count as done. `ls` lists what isn't done, and
  guards, blocking and progress treat the rest as open work.
- Shell completions (bash, zsh, fish) and man pages, generated from the help
  texts and installed by `zig build install`.
- Built for large trackers: git runs as a few long-lived processes per
  command, merge reads each remote history once and writes all refs in one
  transaction, and `show` and the write guards read only the issues around
  the one at hand (sub-issues through a local cache,
  `refs/issuez-cache/parents`). A merge of 2,000 issues where nothing
  changed takes under half a second.
- `mcp`: an MCP server on stdio for coding agents
  ([docs/mcp.md](docs/mcp.md)), with tools to list, show and search issues
  and milestones, and to create, comment on, edit and change the state of
  issues. Writes take the issue's `version` to refuse stale edits. The
  server starts outside a repository too, and every tool takes an optional
  `repo` (an absolute path), so one server serves every repository an agent
  works in. `git issue mcp install` registers it with Claude Code
  (`claude mcp add`, for every project by default); `--print` prints the
  JSON configuration for other clients.
- Two build flavors: full (the default, with the MCP server) and `-Dminimal`
  (CLI only; also `-Dmcp=false`). Releases ship both for Linux, macOS and
  Windows. Release binaries are stripped; the Windows archive has
  `git-issue.exe` only, for `git issue <command>`.
- `install.sh` installs a release on Linux and macOS: the latest by default,
  checked against its `SHA256SUMS`, into `~/.local`, with `sudo` for the
  copy only when the prefix needs it. `update-git-native-issuez` updates it
  with the same options.
- Provider import, export and sync (GitHub, GitLab, …) stay upstream's by
  design: the commands refuse and point to upstream's `git-issue-import` and
  `git-issue-export`.

### Library (`issuez`)

- `Repo`, `Sync`, `Catalog`, `Attachments`, `query` and `projection` over a
  comptime backend contract. Backends: `GitProcess` (real git) and `GitSim`
  (in memory, deterministic).
- Writes are compare-and-swap with retries, and accept an optional expected
  version (`expect`). Guards that check other issues add `verify` lines to
  the same `update-ref` transaction, and local `refs/issuez-guard/*` refs
  make a close or delete conflict with a concurrent new child.
- Typed values: `Issue.state` is a `State` (`open`, `closed` or another
  state as text), `issue.priority()` a `Priority` (the raw text stays in
  `field("Priority")`), and a conflict's `target` names a field, the
  description or a comment by its commit. Write specs take the same types.
- `settings` reads `issue.doneStates` and `issue.workflowStates`;
  `format.time.IsoDate` formats commit times; `projection.Problem.describe`
  says what a problem means; `Catalog.choose` turns a milestone name, ID and
  mode into what an issue write needs, with typed refusals;
  `Catalog.project` builds the projection front ends show; `errors.describe`
  says what every library error means (`errors.Description` with the numbers
  of the limits); `GitProcess.refresh` lets a long-running program see refs
  others wrote.
- Writes refuse what only the CLI refused before: an empty title or comment
  (`EmptyText`), a label with a comma (`InvalidLabel`), a workflow state
  outside `issue.workflowStates` (`UnknownWorkflowState`, from
  `Repo.workflow_states`; `InvalidWorkflowStates` while that setting is
  invalid). Attachment comments must not be blank either; a blank commit
  message gives the default subject, as upstream treats an empty `-m`.
- Attachments take and return bytes, with typed results. Sync takes a
  `before_push` hook for your own LFS upload.
- Examples in [examples/](examples/).

### Known limitations

- Not tested on Windows or with git 2.30.
- Not yet checked: a forge's LFS garbage collection with pointers only in
  `refs/attachments/*`.

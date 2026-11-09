# Gaps and known defects

Project-wide review (2026-10-20) of the code, tests, CI and docs against
[library-plan.md](library-plan.md) and [architecture.md](architecture.md).
Differences from upstream git-native-issue are tracked separately in
[upstream-parity.md](upstream-parity.md); every open item there is closed.

Marks: `[ ]` open, `[x]` done, `[-]` deferred by decision. Paths: `Z` = `src/`.

## 1. Defects

Fix these first; 1 and 2 break CI and use as a dependency.

- [x] **`zig build test-upstream-suite` always fails.** The runner prints its
  report to stderr, and Zig 0.16 treats stderr from a checked Run step as a
  diagnostic (`std/Build/Step/Run.zig:2721`), so the step fails although the
  runner exits 0 with 219/219 required tests passing. CI's "Upstream test
  suite" step is therefore red. Fix: `run_suite.stdio = .inherit` without
  `expectExitCode` (`build.zig`, `run_suite`), or print the report to stdout.
- [x] **The package can't be used as a dependency.** `build.zig` embeds
  `examples/*.out` with `@embedFile`, but `build.zig.zon` `paths` don't
  include `examples/`, so a consumer's build fails with
  `unable to open 'examples/quickstart.out'` (verified with a copy of only the
  packaged paths; nothing else breaks). Fix: define the example steps only
  when `isRootPackage(b)`, or add `examples/` to `paths`.
- [x] README dependency snippet calls `b.dependency("git_native_issuez", .{})`
  without `.target` / `.optimize`.
- [x] `Repo.edit` asserts a non-empty spec (`Z engine/repo.zig`, `edit`):
  caller input can panic the library instead of returning an error. Fixed
  with `error.NothingToEdit`; a malformed `ref_name` passed to `comment`,
  `setState` or `edit` (also an assert) is now `error.InvalidIssueRef`.
- [x] `anyerror` in the public API (`Z engine/repo.zig`, `Problem.unreadable`),
  which the plan forbids (§4 "Memory and limits").
- [x] `GitProcess.push` passes `--no-verify` (`Z backend/GitProcess.zig`,
  `push`): it skips users' pre-push hooks and the git-lfs pre-push hook that
  §7 relies on for attachments.
- [x] `git issue tui --help` prints to stderr; every other command prints help
  to stdout.
- [x] `__manpages` run through `git-issue-sim` writes real files, and the
  oracle's command list (`Z oracle/root.zig`) doesn't know `completion` or
  `__manpages`.
- [x] Stale docs and comments:
  - `Z root.zig` header says only the P0 backend layer is exposed;
  - `Z cli/main_fuzz.zig` header describes the P0 scope;
  - `test/upstream-allowlist.txt` and `test/upstream-expected.txt` comments
    say merge "arrives in P2";
  - library-plan §4 module layout (`merge/`, `mutate/`, `projection/`,
    `fsck/` vs the actual `engine/` and `model/`), `options.simulator`
    (there is a separate `main_sim.zig`), "each operation uses an internal
    arena" (callers pass an arena), the §8 `Command.parse` /
    `main(io, gpa, backend, args)` pattern, and the public API sketch
    (`Repo.open`, `get`, `mutate(id, version)`).

## 2. Library API

Gaps that matter to embedders such as Cockpit.

- [x] No optimistic-concurrency token: mutations can't take the expected
  `version` (issue tip) the plan calls "the ETag in Cockpit". `CommentSpec`,
  `StateSpec` and `EditSpec` take `.expect`; a stale one is
  `error.VersionMismatch`.
- [x] No query API (filter, sort, search): that logic lives in the CLI
  (`Z cli/cmd/ls.zig`, `search.zig`), so embedders reimplement it. Now
  `issuez.query` (`list` with `Filter`/`Order`, `searchLines`), used by
  `ls` and `search`.
- [x] No single `sync` call with one report; the report lacks the conflicted
  and pending lists of §7 "Status". `Sync.sync` returns a `SyncReport`;
  merge entries carry their remaining conflicts (`conflicted()`), and the
  push report lists the skipped (pending) IDs.
- [x] `Limits`: no comptime maxima asserted; no list paging ("issues per list
  page 1000"); `loadAll` is unbounded. `Limits.maximum` bounds every value
  (checked per call, `error.InvalidLimits`); `loadAll` stops at
  `max_issues`; `loadPage` pages in ID order.
- [x] No guide or example for writing a custom backend (the contract exists in
  `Z backend/contract.zig`). `examples/custom_backend.zig`, snapshot-tested.
- [x] No C API for embedders in other languages. `src/capi/`: `api.zig`
  describes it, `gen.zig` writes `issuez.h` and `docs/issuez-api.json`,
  `lib.zig` exports it with a compile-time check of every signature.
  `zig build capi`, `test-capi` (C under ASan/UBSan), Go binding in
  `bindings/go`.
- [x] C API gaps: cancelling a git request already running,
  attachments in `issuez_sync`, queries loading every issue, write retry
  counts, log strings not NUL-terminated. A running git request is killed
  within about 50 ms of a cancel; `issuez_sync` uploads attachments
  through git-lfs (`ISSUEZ_OPT_SYNC_ATTACHMENTS` 0 skips the bytes); the
  repo handle keeps issues loaded by tip (`ISSUEZ_OPT_CACHE_ISSUES`, 10000
  by default), so a query loads only what changed; `issuez_write_retries`
  reports CAS retries. `#N` lookups go through the parents cache.
- [x] What the Forgejo prototype restated (forgejo-integration.md §4.6):
  per-trailer timeline changes as text, no handle pool, uneven write
  options and comment-edit APIs, `ParseOID` of zeros, no entries-since,
  attachments without their comment, milestones without update or
  closing times, push verdicts without authors or pushed attachments,
  purges silent about attachments, imports that land commit by commit,
  restated sets written as changes. All closed.
- [x] Front ends rebuilt what the library knew (review of 2026-11-06):
  op helpers for half the targets, attachment bytes, labels in use,
  people, short IDs, settings writes, a per-repo logger, fsck, sync
  status, search and remote setup outside the C API, writes by ref name
  only, settings applied by hand, eight write functions and pointer
  side channels, errors without their field, the shown issue derived
  in the C layer, a TUI-only live store and watcher, no single entry,
  JSON only from the CLI. Closed: `issuez.open`/`Handle`, `Repo.open`,
  `Repo.update` with `Receipt`, `Diagnostics`, `issuez.view`,
  `issuez.Store`, `issuez.json`, `fsck`, `remote`, and their C and Go
  forms (`issuez_store`, `issuez_watch`, `issuez_fsck`, ...).
- [x] Write specs took dates, assignees and the milestone as text, with
  two ways to clear (`""` and `.clear`). Dates are `format.fields.Date`,
  assignees `format.fields.Assignee`, the milestone one `MilestoneEdit`
  (text and link), and every `EditSpec` field clears with `.clear`
  (`Edit(T)`; `.input` reads a form field where empty means clear).
- [x] The Go binding's records are copied by hand, and
  `TestRecordFieldsMapped` fails when the C API adds a field they don't
  read.
- [x] No server-side check of pushes. `git issue push-check` for a
  pre-receive hook, `issuez_push_check` / `Repo.PushCheck` for hosts
  (format.md §11): fsck, fast-forwards only, numbers, authors, tombstones
  only with leave to purge, derived refs; read from git's quarantine.

- [x] Host consistency review: receipt reloads followed the current ref,
  text expectations pinned unrelated changes, Go snapshot encodings
  ignored map mutations, prepared images could not cross the C boundary,
  and imports required manual scratch/object-directory setup. Exact-tip
  reads, engine-level text expectations, value-based snapshot encoding,
  prepared attachment metadata, and staged imports close these gaps.
  Go returns a committed receipt alongside reload errors; Forgejo uses
  external attachment storage and the import API. See [embedding.md](embedding.md).

## 3. Sync

- [x] Quarantined and pending issues can't be listed afterwards: no `status`
  command, and `fsck` doesn't report them (§7 says it should).
  `git issue status` (`Sync.status`); `fsck` notes them.
- [x] No way to resolve a quarantine (accept remote / keep local) for unrelated
  or rewound histories; such an issue stays quarantined.
  `git issue quarantine` (`Sync.resolve`), see library-plan §7.
- [x] Merge output doesn't report conflicts the merge created.
  `Conflict <id>: …` lines on stderr.
- [x] URL and path remotes (upstream fails, see
  [upstream-parity.md](upstream-parity.md)): `merge`, `push` and `sync`
  take a URL or path; fetch and push go there, its staging and
  bookkeeping refs under `refs/issuez-sync/url-<hash>/`
  (`sync.remoteKey`). `sync <provider>:...` stays upstream's bridge for
  its four providers only.

## 4. Planned features not started

See [library-plan.md §12](library-plan.md#12-phases).

- [x] **P3**:
  - [x] fields: `Assignee: <uuid> <email>`, `X-Parent`, `X-Blocked-By`,
    `X-Start-Date` / `X-Due-Date`, `X-Estimate-Minutes`,
    `X-Workflow-State` with `issue.workflowStates`, with the create/edit
    flags and the `--no-*` clear flags (`Z format/fields.zig`,
    `Issue`'s extension fields, `Z cli/ext_flags.zig`); `X-Blocked-By` merges per member
    like labels;
  - [x] guards with verify sets (`Z engine/repo.zig`, `runGuards`): self-
    and cyclic parents, depth > 8, self- and cyclic blockers, missing
    targets, closing with open descendants, open work under a closed
    ancestor. Every issue a guard reads is a `verify` line in the same ref
    transaction; the fuzzer checks that our writes never add a violation.
    Known limit: a child *created* concurrently with closing its parent
    can't be verified (only existing refs can); the projection reports it;
  - [x] the total projection (cycles, depth, children, blocking, progress,
    effective workflow; `Z engine/projection.zig`, property-tested on random
    graphs). Deleted interior nodes come with deletion in P4;
  - [x] `tree`, `ls --problems`, `ls --conflicts`;
  - [x] `fsck` notes hierarchy and blocker problems and dangling targets
    (not counted as errors, like quarantine); `show` lists the issue's own.
- [x] **P4**:
  - delete/restore, description edit, comment edit/delete/restore events
    (`Repo.setDeleted`, `editDescription`, `commentEvent`; resolved by the
    causal rule, concurrent edits reported as conflicts; dangling, invalid
    and cross-issue events reported); deleted issues pass through the
    projection; deleting a parent with live sub-issues and creating under a
    deleted parent are refused;
  - `ls --deleted`, `show --ids`, `comment --edit/--delete/--restore`,
    `edit --description`, `delete`, `restore`;
  - `close` / `reopen` aliases.
- [x] **P5**:
  - [x] milestone catalog (`refs/milestones/*`, `issuez.Catalog`) and
    `git issue milestone create|ls|show|edit|complete|reopen|retire`;
  - [x] milestone sync and refspec (sync is generic over the issues and
    milestones namespaces; `init` adds the milestones staging refspec);
  - [x] `--milestone-id` / `--milestone-mode`, `--no-milestone` stops
    inheriting;
  - [x] `--milestone <name>` resolution (one open match links the catalog
    milestone; unknown names stay text);
  - [x] completion and retirement rules (guards with verify lines; restore
    counts as placing open work); `milestone show` progress and issues;
    effective milestones in the projection, oracle and fuzzer.
- [x] **P6** (S3 decided: option A, the library's own store outside
  git-lfs's directory):
  - [x] P6a: format and model (`X-Attachment`, per-UUID causal merge),
    `issuez.Attachments` (bytes in/out, typed results), optional LFS
    operations in the backend contract, derived `refs/attachments/*` in the
    same transaction, `attach add|ls|cat|rename|rm`, `comment --attach`,
    `show`, `fsck` notes and `--repair`, oracle and fuzzer, upstream
    interop, [attachments.md](attachments.md), `examples/attachments.zig`;
  - [x] P6b: sync of `refs/attachments/*` (staging refspec, reconcile after
    merges, regenerate before push, convergence without extra commits),
    uploads before refs (`PushOptions.before_push`, else
    `git lfs push --object-id`, else a warning), on-demand `git lfs fetch`
    with adoption (`attach cat`, `attach fetch`), and a real git-lfs test
    including the `git lfs prune` regression;
  - [x] Forgejo's LFS GC with pointers only in `refs/attachments/*`: it
    keeps a meta object while its pointer blob exists, and the derived
    ref keeps the blob through `git gc --prune=now`. Forgejo's
    `TestIssuezImages` runs both and checks the attachment's object and
    download remain while an orphan goes; without the derived ref the
    object is collected.
- [x] **P7**: TUI (`Z tui/`): list (tree of sub-issues too), kanban
  board, detail view with every field edited in place, comments,
  sub-issues, milestones by name, live updates; the open milestones
  with progress to filter by (`M`) and sync with the default remote
  (`p`).
- [x] **P8**:
  - [x] release artifacts: `zig build release` cross-compiles both
    flavors for Linux (musl), macOS and Windows, with completions, man
    pages and `SHA256SUMS`; the public repository's release workflow
    publishes them;
  - [x] macOS: the pre-push hook runs `zig build ci` on macOS and the
    bindings in a Linux container (`test-bindings-linux`);
  - [-] Windows CI: deferred with the Windows tests (§5); the archive is
    cross-built, not run;
  - [x] CHANGELOG, CONTRIBUTING and an extension format spec
    ([format.md](format.md)).
- [-] MCP: Claude Code 2.1.308 sends `server/discover` (protocol
  2026-07-28) before `initialize`. blitzmcp answers "Server not
  initialized" and the client falls back to `initialize`. That is the
  stdio binding's rule for a server of 2025-11-25: any error but the
  modern ones (-32020 to -32022) means legacy, so the fallback is by
  design, and a test keeps the error outside that range. Deferred
  (2026-11-06): serving 2026-07-28 itself (stateless, per-request
  `_meta`, a `DiscoverResult`) is blitzmcp's work; answering
  `server/discover` before that would make clients send requests the
  server can't serve.
- [x] `--json` on read commands (§8 "Output"): `ls`, `show`, `tree`,
  `search`, `status`, `attach ls`, `milestone ls|show`; schema in
  [json.md](json.md).

## 5. Testing

Gaps against library-plan §10.

- [x] The fuzzer doesn't model upstream-style writes (e.g. upstream merge
  commits). `Z oracle/upstream.zig` models upstream's merge commit; the
  fuzzer runs upstream-style merge + push rounds on random clones (about
  120 merge commits per 5 000 cases), with the oracle's invariants, the
  engine/oracle cross-check and the convergence property on top.
- [x] The "simulator vs upstream" interop test is missing. `test/interop.zig`
  runs real upstream merges (three-way labels, one- and two-sided scalar
  changes, same-second ties) and compares each commit with the model.
- [x] No multi-process concurrency test against real git (only the in-memory
  `RacingSim` unit test in `Z engine/repo.zig`). `test/cli_git.zig`: 8
  parallel `git-issue` writers on one issue (~28 lost CAS races per run, all
  retried); every reported success is in the result.
- [x] The 10 000-issue performance smoke test exists only as a spike script,
  not in CI. `zig build test-perf`
  (`test/perf_smoke.zig`, ReleaseSafe, best of three `ls -a` against 2 s);
  CI runs it with a 2 s budget. Measured 0.75 s warm here, the same as before
  this work (S4's 0.49 s was another machine/git).
- [x] No real-git CLI or interop test on SHA-256 repositories (backend tests
  and simulator fuzzing only); reftable is claimed but never tested. Both
  formats in `test/cli_git.zig` (ours alone) and `test/interop.zig` (both
  tools through one remote); reftable when git >= 2.45.
- [-] No git 2.30 CI job (deliberate per §11; a known risk). Deferred
  (2026-10-20): no additional runner for now.
- [-] Windows is untested. Deferred (2026-10-20): no Windows runner for now.
- [x] Newer features checked by hand only: shell completions in real
  bash/zsh/fish, lazygit's menu (only its config validation and the commands
  are tested), `mandoc -T lint` on the man pages. Now automated where the
  tools exist (CI installs zsh, fish, mandoc): every script passes its
  shell's syntax check, bash and fish complete commands, values and IDs,
  every man page lints clean. zsh's completion system runs for real in a
  zpty (`test/cli_git.zig`; it found `attach`'s subcommands missing), and
  `test-tui-e2e` drives lazygit on a pseudo-terminal with the config from
  [lazygit.md](lazygit.md): the `I` menu, the list popup, and `n` creating
  an issue with a priority and a label.
- [x] `test-edge-cases.sh::empty comment rejected with error` passes for the
  right reason and can move into `test/upstream-expected.txt`. Required now
  (220/220).

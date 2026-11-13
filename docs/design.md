# Design

How git-native-issuez is put together, and why.

## Principles

1. **Format over tool.** The product is a git data format and a library that
   implements it. The CLI, the terminal UI and the MCP server are thin
   front ends over the library, and so is any program that embeds it.
2. **Git is the only source of truth.** All data lives in git objects
   reachable from refs.
3. **Upstream compatibility is a hard constraint.** Everything written here
   stays valid
   [git-native-issue](https://github.com/remenoscodes/git-native-issue)
   format 1 and survives upstream writing over it. The CLI may differ from
   upstream where that is an improvement
   ([compatibility.md](compatibility.md)); the format may not.
4. **Append-only.** State is computed from the whole history. Nothing is
   rewritten or removed: editing a comment or deleting an issue is a new
   commit (an event).
5. **Deterministic.** The same git objects give the same state on every
   clone. Time and randomness are inputs, never ambient.
6. **Bounded.** Every walk, buffer, count and retry has a limit, and going
   over it is an error, never silent truncation. The limits live in one
   `Limits` value with defaults and hard maxima.
7. **Side effects at the edge.** Parsing and reading an issue know nothing
   about processes or files. One backend owns everything that touches git,
   so the whole library also runs against an in-memory repository.
8. **Provider bridges stay upstream.** Import from and export to GitHub,
   GitLab, Gitea/Forgejo and Azure DevOps are currently _not_ reimplemented
   and there is no plan for that. Users run upstream's tools on the same
   repository.

## Layers

Each layer only imports the layers below it.

```
cli, tui, mcp ──► engine ──► model ──► format
               │
               └──► backend (comptime parameter)

tui, mcp ──► watch (live updates)
```

| Layer     | Files                 | Does                                                                                                      |
| --------- | --------------------- | --------------------------------------------------------------------------------------------------------- |
| `format`  | `src/format/`         | trailers exactly as git parses them, labels, UUIDs, hex, upstream's value rules, extension field grammars, dates as typed (`dates`), attachment trailers and image types |
| `model`   | `src/model/issue.zig` | one issue from its commit DAG: fields, comments, events, attachments, conflicts                           |
| `engine`  | `src/engine/`         | `Repo` (read, create, comment, edit, state, delete, check, guards), `Catalog`, `Attachments`, `Sync`, `query`, `projection`, `schedule`, `settings`, `errors`, `local_time` |
| `backend` | `src/backend/`        | the contract, `GitProcess`, `GitSim`, git objects                                                         |
| `cli`     | `src/cli/`            | argument parsing, output, exit codes                                                                      |
| `tui`     | `src/tui/`            | the terminal UI: list, board, detail, milestones and timeline over the engine, on libvaxis                |
| `mcp`     | `src/mcp/`            | the MCP server: tools and resources over the engine, typed results                                        |
| `watch`   | `src/watch/`          | `RepoWatcher`: tells the TUI and the MCP server when the issues on disk changed, on nightwatch            |

`format`, `model` and the projection are tested without git.

## The backend contract

`Repo(B)` is generic over a comptime backend type. There are no vtables: the
backend is duck typed, and `assertBackend` gives a readable compile error
for anything missing. The contract (`src/backend/contract.zig`) is a small
set of plumbing operations:

- objects: read and write by kind and OID;
- refs: resolve, list by prefix, and one all-or-nothing transaction in which
  every update states the value it expects;
- graph: is-ancestor and merge bases;
- config, remotes, the default identity;
- transport: fetch with explicit refspecs (optionally pruning), and push
  (optionally atomic) with a result per ref;
- random bytes, for UUIDs;
- optionally, an LFS store for attachment bytes (read, atomic write, list,
  and optionally the size without reading) and LFS transfer (push and
  fetch objects). Where transfers keep copies is the backend's business:
  the git backend goes through git-lfs's store. A backend without a store
  works for everything but attachments.

| Backend      | Use                                                                                                                                                                                                                                                                                                                   |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GitProcess` | Runs `git` from PATH with a fixed environment and `--` separators. Reads objects, and resolves single refs, through one long-lived `cat-file --batch`, and writes objects through one long-lived `hash-object -w --no-filters --stdin-paths` per type, so git still checks them and applies its permissions (and no attributes or filters). Output is bounded, and so is time: each call has a deadline (`Timeouts`), after which git is stopped. LFS objects are files under the git dir; transfers run `git lfs push` and `git lfs fetch` when git-lfs is installed.                                                    |
| `GitSim`     | An in-memory world of clones, serialised as ZON. Objects hash exactly like git, so OIDs are real. A remote is another clone of the world (`remote.<name>.url = sim:<clone>`). Clock and randomness come from the world. Each clone has both LFS stores, LFS transfers copy objects between clones, and like git-lfs a fetch fails on an unknown ref or an object the remote lacks. `sim.lfs = false` makes a clone without git-lfs. Breaking a protocol rule (a commit pointing at a missing object, an invalid ref name) panics. |
| your own     | Wrap or replace either one. `examples/custom_backend.zig` logs every ref change and push, and refuses writes outside the issue and bookkeeping refs.                                                                                                                                                                  |

## Reading an issue

The model walks the commit DAG parents first. Every field value remembers
its latest setters, the commits that set it with none an ancestor of
another. A merge pools both sides' setters and drops those another one
descends from; only concurrent setters that remain fall back to the later
author time, and a disagreement is reported as a conflict. The rule is in [format.md](format.md) §4.
Conflicts are a function of the DAG, so they are found in merges made by any
tool and nothing extra is stored.

The trailer parser matches `git interpret-trailers --parse`, because
upstream reads fields through git. Writers refuse text whose last paragraph
would parse as trailers.

Events (comment edit, delete and restore, description edit) are resolved
the same way, per target comment. An event whose comment hasn't arrived yet
waits for it. A value that doesn't parse (a date like `2026-02-30`) is kept,
ignored and reported, never an error: other tools write these issues too.

## The projection

Some questions need every issue at once: children, blockers, progress,
workflow states, effective milestones, and problems such as a parent that
is missing or loops back, or a milestone that is missing or retired.
`projection.build` (`src/engine/projection.zig`) answers them from the
loaded issues and nothing else. Merges and other tools can produce any
graph, so it accepts every input and never loops: a parent that is missing,
the issue itself, or part of a cycle is reported and the issue becomes a
root, so the tree still shows every issue exactly once. `tree`,
`ls --problems`, `fsck` and `milestone show` read it.

One issue's answers need fewer issues: `Repo.loadAround` loads the issue,
its ancestors, its descendants (through the parent cache, see "Writing an
issue") and the issues its blockers lead to, and a projection over those
gives that issue the same answers as one over every issue. `show` reads
it that way. Only an event whose comment is missing, which may target
another issue's comment, needs every issue. Issues that can't be loaded
are left out, as in the write guards (`fsck` reports them).

## Milestones

`Catalog(B)` (`src/engine/milestone.zig`) keeps milestones under
`refs/milestones/`. A milestone is read and written by the same `Repo(B)`
code as an issue (the model, compare and swap, merges), only under another
prefix and with its own trailers ([format.md](format.md) §6). Issues
reference a milestone by UUID; which milestone an issue is in, through its
parents, is a question for the projection. Completing a milestone reads
every issue in it and pins each one with a `verify` line, the same way the
issue guards do.

`Repo.editBatch` applies several issues' edits in one ref transaction.
`Catalog.editBatch` combines issue edits and milestone due dates in the
same transaction. Both check expected versions and guards before moving
any refs, so a timeline draft is applied together or refused together.
The guards read the batch's issues as the batch leaves them, so parent
loops, depth and milestone rules hold across edits of one batch.

`engine/schedule.zig` summarizes milestone progress and health, and turns
issue dates, estimates and blockers into timeline spans with warnings.
`fields.Date` supplies date arithmetic; `fields.WorkDays` counts working
days. Settings `issue.workDays` and `issue.hoursPerDay` control how an
estimate becomes a span (all days and eight hours per day by default).

`format/dates.zig` reads dates as people type them (`today`, `+3d`,
`fri`, `eom`) relative to a given today, and `dates.resolve` turns them
into `YYYY-MM-DD`, the only form ever written or read from a trailer. The
TUI, the CLI's `--start` and `--due` and the MCP tools share it.
`engine/local_time.zig` reads the local time zone (`TZ`, else
`/etc/localtime`, UTC on Windows) without libc, for what today is.

## Attachments

`Attachments(B)` (`src/engine/attachments.zig`) writes images onto issues
([attachments.md](attachments.md)). The trailers in the issue history are
the source of truth and the model reads them like any other field. The
bytes are LFS objects in a store of this tool's own, and copied into
git-lfs's store only for transfers, because `git lfs prune` would delete
them there. `refs/attachments/<uuid>` is derived: a tree of LFS pointers,
so git-lfs and LFS servers see the objects. A write stores the bytes
first, then moves the issue ref and the derived ref in one transaction.
Sync fetches the derived refs but never merges them; it rebuilds them from
the merged issues, so they converge like everything else. Bytes travel
only on push (`git lfs push`, or a hook for an embedder's own LFS client),
uploaded before any ref so a failed upload pushes nothing, and on demand
(`att.fetch`). On a backend that can run git-lfs, every attachment call
checks first that it is installed and fails with `LfsUnavailable` if not.

## Writing an issue (compare and swap)

1. Resolve the tip and read the issue.
2. Build the new commit with the tip as its parent.
3. Move the ref in a transaction that expects the old tip.
4. If the ref moved in the meantime, start again from step 1, up to
   `Limits.cas_retries` times.

The commit is rebuilt on every retry. Re-pointing an old commit at a new tip
would lose the concurrent change, which is how upstream's retry can drop an
edit.

Every write checks the values first: no newlines, the limits, and upstream's
rules for priority, state and the assignee's email (`src/format/core.zig`).
A program using the library can't write what upstream's commands would
refuse. The CLI uses the same checks and adds upstream's error messages.

Writes that touch the hierarchy also run guards
([format.md](format.md) §3): no parent or blocker loops, no open issue under
a closed one, no deleting an issue with live sub-issues. A guard reads other
issues, and every issue it reads gets a `verify` line in the same ref
transaction as the write. When one of them moves concurrently, the
transaction fails and the write starts again from step 1. Sub-issues are
found through `refs/issuez-cache/parents`, a blob of every issue's tip and
parent: only issues whose tip changed since are read. A `verify` can't
pin an absence, like no child under the issue being closed, so those
writes also move a local guard ref (`refs/issuez-guard/<uuid>`) of the
issue whose children matter, and two of them conflict. Milestones are
guarded the same way: no linking a completed or retired one, no open work
into a completed one, and no completing one with open issues. Concurrent writers
in one clone therefore can't break a guard; other clones still can, and the
projection reports it. The number of issues a guard may read is bounded
(`Limits.max_guard_scan`), and issues that can't be loaded are skipped, so
one damaged issue doesn't block every close.

A caller can pass `.expect` with the version it read (an issue's tip). The
write then fails with `VersionMismatch` instead of retrying when the issue
changed, like an HTTP ETag.

## Sync

`Sync(B)` (`src/engine/sync.zig`) sits on top of `Repo(B)`:

1. Fetch into `refs/issuez-sync/<remote>/seen/` with `--prune`. It stays
   between syncs, so an unchanged remote costs no ref writes, and the push
   of a `sync` reuses it. A fetch never writes `refs/issues/` or
   `refs/milestones/` directly. Milestones go through the same steps as
   issues.
2. Classify each fetched issue against the local one: new, fast-forward, up
   to date, local ahead, diverged, or to be quarantined (unrelated history,
   rewritten since the last merge, fails `fsck`). Local refs and records are
   read once per namespace, and an issue already merged at the same tip
   isn't checked again.
3. Fast-forward, or write a deterministic merge commit, with the same
   compare and swap as every other write. How the tips relate (and the
   merge bases) comes from the loaded histories, not a `git merge-base`
   per issue. The local ref writes go in one transaction; if it loses a
   race, those issues are merged again one by one.
4. Fetch again to learn what the remote has (someone may have
   force-pushed), then push what differs, atomically in batches. A
   rejection means the remote moved: merge again and retry, up to a fixed
   number of rounds.
5. Record what was merged and pushed in `refs/issuez-sync/`, a ref
   transaction per merge and per pushed batch (a quarantine marker and
   the attachments' records go on their own), and report every issue's
   outcome.

The bookkeeping refs are a cache: they make rewound remotes detectable and
`status` cheap, and losing them only costs a slower next sync. Nothing is
force-pushed or deleted. Quarantine keeps the local issue, and resolving it
keeps the version it replaces ([format.md](format.md) §8).

Merge commits are deterministic, so every clone that merges the same pair
writes the same commit. After all clones have exchanged everything, they
hold identical refs: the fuzzer checks exactly that.

## Errors and resources

- The library returns explicit error sets. `errors.describe` says what each
  error means (a test checks that every one has a description), and front
  ends turn them into messages and exit codes at the edge
  (`src/cli/common.zig`), with their own wording where they say more.
- Process-ending errors are only used by entry points (`src/cli/fatal.zig`).
  Commands return an exit code.
- The caller passes the allocator and `std.Io`. Each operation allocates
  from an arena.

## The CLI

- `main` receives `std.process.Init`: `io`, `gpa`, an arena and the
  environment.
- The binary dispatches on its name first, so `git-issue-create` behaves
  like `git-issue create`, as upstream's scripts and tests expect.
- One file per command in `src/cli/cmd/`, each with its `help` text and a
  `main`. Commands only talk to the library, never to git directly.
- Commands are generic over the backend, like `Repo(B)`, and get a
  `Context(B)` (`src/cli/context.zig`). `main` opens git before dispatch and
  stores the result or the error; only commands that need a repository
  report the error, so `version` and `help` work anywhere.
- `--json` is a second renderer over the same library results
  (`src/cli/json.zig`), next to the text output. Its schema only grows
  ([json.md](json.md)).
- The completion scripts (`src/cli/completion.zig`) and the man pages
  (`src/cli/manpage.zig`) are generated from the commands' `help` texts, so
  they can't drift from the options. `zig build install` runs the built
  binary to write them (`git-issue completion <shell>` and the hidden
  `git-issue __manpages <dir>`), so only native builds install them.

## The MCP server

- `git issue mcp` serves the issues to coding agents over the Model Context
  Protocol on stdio, built on [blitzmcp](https://github.com/StaffinityAI/blitzmcp).
  It is part of the default build and left out with `-Dminimal` or
  `-Dmcp=false`; as a dependency, the package builds neither it nor
  blitzmcp. See [mcp.md](mcp.md).
- Each tool calls the library (`Repo`, `query`, `projection`, `Catalog`),
  never the CLI's commands, and returns a typed result with an output
  schema. Rules both front ends need live in the library: milestone choice
  (`Catalog.choose`), the projection (`Catalog.project`), git config
  settings (`settings`), error descriptions (`errors`).
- One `GitProcess` per repository: the server's own (`--repo`, else the
  directory the client started it in) and up to 16 that tools name with
  `repo`. Each is opened on the first call that needs it, so the server
  starts outside a repository too. `GitProcess.refresh` ends its
  `cat-file` session before each call, so a call sees what other tools
  wrote in the meantime. Calls are handled one at a time.
- The server doesn't ask for the client's roots. Claude Code's are the
  directory it was started in and its `--add-dir` directories; a `cd` in
  its shell changes neither. The `--add-dir` directories are all that
  roots would add, and with several roots the server can't tell which one
  a call is for, so the call would still pass `repo`.
- The tools are generic over the backend; their tests drive them over
  JSON-RPC on `GitSim`. `zig build e2e` (part of `zig build ci`) drives
  the real `git-issue mcp` over stdio on real git repositories with the
  official MCP TypeScript SDK client, which also checks every result
  against the tool's output schema (`test/e2e/`).
- Resources: `git-issue://issues`, `git-issue://milestones` and
  `git-issue://issues/{id}`, the server's repository as JSON in the tools'
  result types. The first `resources/subscribe` starts a `RepoWatcher`
  with a `GitProcess` of its own; on a change its thread diffs
  `changes.RefState` and sends `notifications/resources/updated` for each
  subscribed URI the change touched. stdout is a thread-safe transport, so
  a notification never splits a response.

## The terminal UI

- `git issue tui`, and `git issue` alone at a terminal: a list (optionally
  a tree of sub-issues), a kanban board by workflow state, a detail view,
  milestones and a timeline, on
  [libvaxis](https://github.com/rockorager/libvaxis). Part of the default
  build; `-Dtui=false` or `-Dminimal` leave it out, and as a
  dependency the package builds neither it nor libvaxis.
- The store loads every issue into one snapshot, replaced whole by each
  reload; views keep issue IDs, never pointers into it. Every write goes
  through the same library calls as the CLI and checks the tip it showed,
  so a change made meanwhile fails the write instead of being overwritten.
- Input turns into actions on a state that knows nothing of the repository,
  so the whole UI is tested on `GitSim`, driven by keys and clicks.
- Live: a `RepoWatcher` posts to the event loop when anyone else writes.
  The store reloads only if `changes.RefState` moved since its last
  reload, which its own writes already did, and the status line says
  which issue changed elsewhere. Selection, view and open dialogs stay.
  Saving a dialog onto an issue that changed since the dialog opened says
  so and writes nothing; saving again replaces what is there now.
  Getting the terminal focus back runs the same check and rereads git
  config; without a watcher, that and `ctrl+r` still reload.
- Milestone views show progress, health and due dates, and support creating,
  completing, retiring and reopening milestones. Issues can be assigned or
  moved with search, marks, keys or dragging between panes.
- The timeline draws milestones, issues and blockers at day, week or month
  scale. Its edit mode stages changes with undo; applying uses the batch
  APIs above. Changes written elsewhere are marked for the user to keep
  or drop before applying the draft.
- `sync_job.zig` runs fetch, merge and push off the event loop, reporting
  phases through the library's sync progress callback. The badge and panel
  show unpushed work, quarantines and conflicts, with actions to resolve
  quarantines or open conflicting fields. `Sync.unpushed` and `Sync.counts`
  read local refs for the indicators.
- `sync.defaultRemote` uses `issue.remote`, otherwise the only remote,
  `origin`, or the first remote by name. `issue.autoSync` enables periodic
  fetch and merge, without pushing. The job runs as a concurrent Io task,
  so quitting cancels it and kills its git. Its git runs without a
  controlling terminal (`GitProcess.OpenOptions.no_terminal`, `setsid` on
  POSIX) and with `SSH_ASKPASS_REQUIRE=never`, so nothing prompts on the
  TUI's terminal, even with the user's own ssh command. Without one, ssh
  gets batch mode and connect and keep-alive timeouts; with OpenSSH 8.4
  or later outside Windows, connections are shared for five minutes
  through a socket in a private 0700 directory (`$XDG_RUNTIME_DIR/issuez`
  or `/tmp/issuez-<uid>`), and a push after a fresh fetch avoids fetching
  again.
- "Today" is the local date: the TUI asks `local_time` (in the engine)
  for the UTC offset before every frame, and `schedule.health` takes the
  same offset.

## The TUI's state file

- `src/tui/user_state.zig`: what the TUI keeps for the user between
  sessions (so far, when the star notice asked), as ZON in
  `git-issue/tui.zon` in the local configuration folder that
  [known-folders](https://github.com/ziglibs/known-folders), a lazy
  dependency of builds with the TUI, finds. Fields are only added, each
  with a default; unknown ones are skipped on reading, so any version
  reads any file. A file that doesn't parse is never saved over. Saves
  write a temporary file and rename it.

## Live updates

- `src/watch/RepoWatcher.zig`, over
  [nightwatch](https://github.com/neurocyte/nightwatch), a lazy dependency
  of builds with the TUI or the MCP server. It watches the common git dir
  but registers only `refs/`, the issue, milestone and attachment ref
  directories and `reftable/`; objects, logs and other refs are never
  registered. On macOS and the BSDs it uses directory-only kqueue watches:
  git writes a ref as `<ref>.lock` renamed over `<ref>`, so directory
  entries say everything, at one descriptor per directory.
- A path tells that something may have changed, not what. Paths map to a
  `Change` (refs or config), a lock counting as the file it locks. A thread
  of its own coalesces bursts: the listener runs once events stop for
  40 ms, and at least every 400 ms while they don't.
- What changed comes from the library: `changes.RefState.read` lists the
  three namespaces (one `listRefs` each) and `changes.diff` names the issues
  created, changed or deleted, and whether milestones changed. Every write
  moves its issue's ref, so nothing is missed. A program embedding the
  library uses the same pair with whatever watcher it has.

## Simulator, oracle and fuzzer

Every write rule is stated twice: once in the engine, and once in an oracle
written separately and kept simple. A bug has to be made twice, the same
way, to go unnoticed.

- **Simulator** (`src/cli/simulate.zig`): the real command code running
  against `GitSim`, on a world (ZON: clones, refs, objects, config, clock,
  seed). No processes and no files. `git-issue-sim` does the same from the
  command line, reading the world on stdin and writing the result to
  stdout.
- **Commands as data** (`src/oracle/command.zig`): a command is a `Command`
  value, such as `.{ .edit = .{ .id = "a7f3", .priority = "high" } }`. Its
  `argv` is what the CLI gets, and the oracle gets the value itself, so the
  oracle never parses arguments.
- **Oracle** (`src/oracle/`, `checkTransition`): checks that running the
  command on world BEFORE may give world AFTER:
  - for every command: objects never disappear, issue refs only reach
    empty-tree commits, other refs never change, only the target clone
    changes, and a failed command changes nothing;
  - per command: what `create`, `comment` (and its edit, delete and
    restore events), `edit` (with the extension fields and the
    description and the milestone fields), `state`, `close`, `reopen`,
    `delete`, `restore`, `milestone`, `attach`, `comment --attach`,
    `fsck --repair` and `init` may write, and that
    read-only commands change nothing. Messages are checked where the
    format depends on them (the root message, trailers, text the user
    wrote). Subjects the CLI picks itself are not;
  - for `merge`, `push`, `sync` and `quarantine`: issue refs are never
    deleted or rewound on either side, a merge commit has the deterministic
    shape and restates the oracle's own resolution of its parents (and
    reads exactly as its parents do), every
    remote issue arrives unless a real reason quarantines it, after a
    push the remote has every local tip that isn't quarantined, and every
    derived attachment ref matches its issue and was never rewound;
  - for attachments: the bytes are in the store, LFS objects are never
    deleted, a derived ref holds one pointer per present attachment, and
    no attachment command succeeds on a clone without git-lfs.

  It may not import the model or the engine, only git objects, the world
  format and the trailer parser (which is itself checked against git).

- **Upstream model** (`src/oracle/upstream.zig`): upstream's merge commit,
  so the fuzzer can mix upstream merges into its histories.
  `test/interop.zig` compares it with real upstream merges.
- **Fuzzer** (`git-issue-fuzz`, built with `-Dfuzz`): each case first runs
  random backend operations against a separate model of the contract, then
  random commands, valid and invalid (attachments include animated, empty
  and non-image files), on a few clones that share a hub, sometimes one
  of them without git-lfs
  remote, with some upstream merges mixed in, and commits from another
  tool that writes extension fields without checking them (invalid
  values, clears). Now and then someone
  force-pushes to the hub: it resets an issue to an older commit, which
  clones push back, or rewrites it from an older commit or replaces it with
  unrelated history, which clones quarantine and resolve.
  Every command is checked by the oracle, and the engine's reading of each
  issue is compared with the oracle's. After every write the projection
  must show no new guard violation: a guard can only be broken by other
  tools or concurrent clones, never by one of our own writes. After every
  step, each issue must project the same from `loadAround` as from every
  issue. What the
  oracle has no rule for is counted as skipped, so gaps show up in the
  statistics. At the end every clone syncs, taking
  the hub's version of anything quarantined, until nothing changes, and
  each must then hold exactly the hub's issues, milestones and derived
  attachment refs (convergence). The seed is
  printed, and `--seed <seed> --iterations 1` replays a failure.

`zig build test` runs the fixture worlds in `src/cli/worlds/` through the
simulator and the oracle, and a short fuzz run with a fixed seed: the same
cases every time, so it catches regressions. `zig build ci` adds a long
run on `-Dseed`, a fresh one on every CI run, which finds new bugs.

## Tests

- Unit tests next to the code, mostly on `GitSim`.
- `test/backend_git.zig`: `GitProcess` against real git, and `GitSim` must
  agree with git on OIDs and merge bases.
- `test/trailers_git.zig`: the trailer parser against git on random
  messages.
- `test/cli_git.zig`: the CLI against real git, for what only real git shows
  (identity rules, config, the environment).
- The examples, against their snapshots.
- `test/interop.zig` (`zig build test-interop`): both tools on the same
  repositories, each reading what the other wrote.
- `test/upstream_suite.zig` (`zig build test-upstream-suite`): upstream's
  own `t/*.sh` against our binary. `test/upstream-expected.txt` lists the
  tests that have to pass, `test/upstream-allowlist.txt` the ones we fail on
  purpose, each with its reason.
- `test/e2e/` (`zig build e2e`): `git-issue mcp` with the official MCP
  SDK client, including two servers on one repository that hear of each
  other's and the CLI's writes.
- `test/live_tui.zig` (`zig build test-tui-e2e`, also in `zig build e2e`):
  two `git-issue tui` on pseudo-terminals (`test/tui_e2e/tty_exec.zig`
  makes the terminal the TUI's controlling one), read through a small
  terminal emulator (`test/tui_e2e/Screen.zig`) so the test sees the
  screens as text. The CLI, the other TUI and an agent through the MCP
  server write, and both TUIs must show it with no key pressed.
- `test/perf_smoke.zig` (`zig build test-perf`): `ls -a` over 10 000
  issues within 2 s.

Upstream is GPL-2.0. It is a lazy dependency in `build.zig.zon`, fetched
only by `test-interop` and `test-upstream-suite` in this package, never
vendored and never fetched by packages that depend on this one.

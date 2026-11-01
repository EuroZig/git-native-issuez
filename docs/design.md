# Design

How git-native-issuez is put together, and why.

## Principles

1. **Format over tool.** The product is a git data format and a library that
   implements it. The CLI is a thin front end over the library, and so is
   any program that embeds it.
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
cli ──► engine ──► model ──► format
          │
          └──► backend (comptime parameter)
```

| Layer     | Files                 | Does                                                                                                      |
| --------- | --------------------- | --------------------------------------------------------------------------------------------------------- |
| `format`  | `src/format/`         | trailers exactly as git parses them, labels, UUIDs, hex, upstream's value rules, extension field grammars, attachment trailers and image types |
| `model`   | `src/model/issue.zig` | one issue from its commit DAG: fields, comments, events, attachments, conflicts                           |
| `engine`  | `src/engine/`         | `Repo` (read, create, comment, edit, state, delete, check, guards), `Catalog`, `Attachments`, `Sync`, `query`, `projection` |
| `backend` | `src/backend/`        | the contract, `GitProcess`, `GitSim`, git objects                                                         |
| `cli`     | `src/cli/`            | argument parsing, output, exit codes                                                                      |

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
- transport: fetch with explicit refspecs, and push (optionally atomic)
  with a result per ref;
- random bytes, for UUIDs;
- optionally, the LFS stores for attachment bytes (read, atomic write,
  list) and LFS transfer (push and fetch objects). A backend without them
  works for everything but attachments.

| Backend      | Use                                                                                                                                                                                                                                                                                                                   |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GitProcess` | Runs `git` from PATH with a fixed environment and `--` separators. Reads objects through one long-lived `cat-file --batch`. Output is bounded. LFS objects are files under the git dir; transfers run `git lfs push` and `git lfs fetch` when git-lfs is installed.                                                    |
| `GitSim`     | An in-memory world of clones, serialised as ZON. Objects hash exactly like git, so OIDs are real. A remote is another clone of the world (`remote.<name>.url = sim:<clone>`). Clock and randomness come from the world. Each clone has both LFS stores, LFS transfers copy objects between clones, and like git-lfs a fetch fails on an unknown ref or an object the remote lacks. `sim.lfs = false` makes a clone without git-lfs. Breaking a protocol rule (a commit pointing at a missing object, an invalid ref name) panics. |
| your own     | Wrap or replace either one. `examples/custom_backend.zig` logs every ref change and push, and refuses writes outside the issue and bookkeeping refs.                                                                                                                                                                  |

## Reading an issue

The model walks the commit DAG parents first. Every field value remembers
the commit that set it. At a merge, a setter that descends from the other
wins; only concurrent setters fall back to the later author time, and that
case is reported as a conflict. The rule is in [format.md](format.md) §4.
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

## Milestones

`Catalog(B)` (`src/engine/milestone.zig`) keeps milestones under
`refs/milestones/`. A milestone is read and written by the same `Repo(B)`
code as an issue (the model, compare and swap, merges), only under another
prefix and with its own trailers ([format.md](format.md) §6). Issues
reference a milestone by UUID; which milestone an issue is in, through its
parents, is a question for the projection. Completing a milestone reads
every issue in it and pins each one with a `verify` line, the same way the
issue guards do.

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
transaction fails and the write starts again from step 1. A `verify` can't
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

1. Fetch into `refs/remotes/<remote>/issues/` and
   `refs/remotes/<remote>/milestones/`. A fetch never writes `refs/issues/`
   or `refs/milestones/` directly. Milestones go through the same steps as
   issues.
2. Classify each fetched issue against the local one: new, fast-forward, up
   to date, local ahead, diverged, or to be quarantined (unrelated history,
   rewritten since the last merge, fails `fsck`).
3. Fast-forward, or write a deterministic merge commit, with the same
   compare and swap as every other write.
4. Fetch again to learn what the remote has (someone may have
   force-pushed), then push what differs, atomically in batches. A
   rejection means the remote moved: merge again and retry, up to a fixed
   number of rounds.
5. Record what was merged and pushed in `refs/issuez-sync/`, and report
   every issue's outcome.

The bookkeeping refs are a cache: they make rewound remotes detectable and
`status` cheap, and losing them only costs a slower next sync. Nothing is
force-pushed or deleted. Quarantine keeps the local issue, and resolving it
keeps the version it replaces ([format.md](format.md) §8).

Merge commits are deterministic, so every clone that merges the same pair
writes the same commit. After all clones have exchanged everything, they
hold identical refs: the fuzzer checks exactly that.

## Errors and resources

- The library returns explicit error sets. Front ends turn them into
  messages and exit codes at the edge (`src/cli/common.zig`).
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
  tools or concurrent clones, never by one of our own writes. What the
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
- `test/perf_smoke.zig` (`zig build test-perf`): `ls -a` over 10 000
  issues within 1 s.

Upstream is GPL-2.0. It is a lazy dependency in `build.zig.zon`, fetched
only by `test-interop` and `test-upstream-suite` in this package, never
vendored and never fetched by packages that depend on this one.

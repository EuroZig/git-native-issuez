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
   rewritten.
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

| Layer     | Files                 | Does                                                                            |
| --------- | --------------------- | ------------------------------------------------------------------------------- |
| `format`  | `src/format/`         | trailers exactly as git parses them, labels, UUIDs, hex, upstream's value rules |
| `model`   | `src/model/issue.zig` | one issue from its commit DAG: fields, comments, conflicts                      |
| `engine`  | `src/engine/`         | `Repo` (read, create, comment, edit, state, check) and `query` (filter, sort)   |
| `backend` | `src/backend/`        | the contract, `GitProcess`, `GitSim`, git objects                               |
| `cli`     | `src/cli/`            | argument parsing, output, exit codes                                            |

`format` and `model` are tested without git.

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
- random bytes, for UUIDs.

| Backend      | Use                                                                                                                                                                                                                                       |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GitProcess` | Runs `git` from PATH with a fixed environment and `--` separators. Reads objects through one long-lived `cat-file --batch`. Output is bounded.                                                                                            |
| `GitSim`     | An in-memory world of clones, serialised as ZON. Objects hash exactly like git, so OIDs are real. Clock and randomness come from the world. Breaking a protocol rule (a commit pointing at a missing object, an invalid ref name) panics. |
| your own     | Wrap or replace either one. `examples/custom_backend.zig` logs every ref change and refuses writes outside `refs/issues/`.                                                                                                                |

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

A caller can pass `.expect` with the version it read (an issue's tip). The
write then fails with `VersionMismatch` instead of retrying when the issue
changed, like an HTTP ETag.

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
  - per command: what `create`, `comment`, `edit`, `state` and `init` may
    write, and that read-only commands change nothing. Messages are checked
    where the format depends on them (the root message, trailers, text the
    user wrote). Subjects the CLI picks itself are not.

  It may not import the model or the engine, only git objects, the world
  format, the trailer parser (which is itself checked against git) and the
  format's limits.
- **Fuzzer** (`git-issue-fuzz`, built with `-Dfuzz`): each case first runs
  random backend operations against a separate model of the contract, then
  random commands, valid and invalid, on one to three clones of a random
  world. Every command is checked by the oracle, and the engine's reading
  of each issue is compared with the oracle's. The seed is printed, and
  `--seed <seed> --iterations 1` replays a failure.

`zig build test` runs the fixture worlds in `src/cli/worlds/` through the
simulator and the oracle, and a short fuzz run with a fixed seed.

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

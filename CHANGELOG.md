# Changelog

All notable changes to git-native-issuez. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/). Before 1.0, minor
versions may change the library API; the on-disk format only ever grows (see
[docs/format.md](docs/format.md)).

## [Unreleased]

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
- Not yet checked: Forgejo's LFS garbage collection with pointers only in
  `refs/attachments/*`.

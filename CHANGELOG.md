# Changelog

All notable changes to git-native-issuez. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/). Before 1.0, minor
versions may change the library API; the on-disk format only ever grows (see
[docs/format.md](docs/format.md)).

## [Unreleased]

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
- Not yet checked: Forgejo's LFS garbage collection with pointers only in
  `refs/attachments/*`.

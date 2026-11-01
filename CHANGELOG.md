# Changelog

All notable changes to git-native-issuez. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Before 1.0, minor versions may
change the library API; the on-disk format only ever grows (see
[docs/format.md](docs/format.md)).

## [Unreleased]

The first release; everything below is new.

### Format and compatibility
- Reads and writes git-native-issue format 1. Issues written by either tool
  work in the other, and upstream's `fsck` passes on ours. Checked by
  cross-tool tests and by upstream's own test suite (220 required cases).
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
- `--json` on read commands ([docs/json.md](docs/json.md)).
- `closed` and the states in `git config issue.doneStates` (default
  `wontfix,duplicate`) count as done. `ls` lists what isn't done, and
  guards, blocking and progress treat the rest as open work.
- Shell completions (bash, zsh, fish) and man pages, generated from the help
  texts and installed by `zig build install`.
- Provider import, export and sync (GitHub, GitLab, …) stay upstream's by
  design: the commands refuse and point to upstream's `git-issue-import` and
  `git-issue-export`.

### Library (`issuez`)
- `Repo`, `Sync`, `Catalog`, `Attachments`, `query` and `projection` over a
  comptime backend contract. Backends: `GitProcess` (real git) and
  `GitSim` (in memory, deterministic).
- Writes are compare-and-swap with retries, and accept an optional expected
  version (`expect`). Guards that check other issues add `verify` lines to
  the same `update-ref` transaction, and local `refs/issuez-guard/*` refs
  make a close or delete conflict with a concurrent new child.
- Typed values: `Issue.state` is a `State` (`open`, `closed` or another
  state as text), `issue.priority()` a `Priority` (the raw text stays in
  `field("Priority")`), and a conflict's `target` names a field, the
  description or a comment by its commit. Write specs take the same types.
- Attachments take and return bytes, with typed results. Sync takes a
  `before_push` hook for your own LFS upload.
- Examples in [examples/](examples/).

### Known limitations
- Not tested on Windows or with git 2.30.
- Not yet checked: Forgejo's LFS garbage collection with pointers only in
  `refs/attachments/*`.

# Compatibility with upstream

git-native-issuez is a drop-in for
[git-native-issue](https://github.com/remenoscodes/git-native-issue)
v1.3.3. The git format is the same and stays the same. The commands here
accept every upstream option with the same short and long forms. Where the
CLI behaves differently, it is on purpose, and this page says why.

`zig build test-upstream-suite` runs upstream's own tests against this
`git-issue`. `test/upstream-allowlist.txt` lists every test it fails on
purpose, with the reason.

## Provider bridges

`import`, `export` and provider `sync` (GitHub, GitLab, Gitea/Forgejo,
Azure DevOps) are not reimplemented and currently not planned;
contributions are welcome though. Until then, `git issue import ...` and
the others refuse and point to upstream: run its `git-issue-import`,
`git-issue-export` or `git-issue-sync` in the same repository. Both tools
share the issue refs. The trailers the bridges write (`Provider-ID`,
`Provider-Comment-ID`, `Exported-Commit`, `Parent-ID`) are read and kept,
never written.

`git issue sync` exists here, but it syncs with a git remote
(`git issue sync origin`). A provider argument (`git issue sync github:...`,
anything with a `:`) is refused with the pointer to upstream.

The `git-issue-<command>` entry points installed here never include
`import`, `export` or `sync`, so upstream's stay reachable when both tools
are installed.

## All commands

- `-h`/`--help` on a command prints to stdout and exits 0. Upstream exits
  1. Asking for help is not an error.
- A usage error prints `error: ...` and a `Run 'git issue X --help'` hint to
  stderr, instead of the full usage text on stdout, so stdout stays clean
  for scripts.
- Words after `--` are kept as arguments instead of being dropped.
- A missing identity gives upstream's messages (`fatal: user.name not set`,
  exit 128), looked up the same way (`GIT_AUTHOR_*`, then
  `GIT_COMMITTER_*`, then config). Like upstream, git is not allowed to
  invent an identity from the login name and hostname.
- When a concurrent write moves an issue, the write is rebuilt on the new
  tip and retried at once. Upstream sleeps and re-points its old commit,
  which can lose the other write.
- Lengths and counts are bounded (state, title, body, trailer values,
  labels). Upstream has no limits.
- `help` is a command and `version -h` prints help.

## create

- A body whose last paragraph would be read as trailers is refused.
  Upstream lets it add trailers to the root commit.
- Extra options for planning: `--parent`, `--blocked-by`, `--start`,
  `--due`, `--estimate` and `--workflow` (also on `edit`). Each writes an
  `X-` trailer ([format.md](format.md) §3) that upstream keeps and shows as
  a plain trailer line.
- `-a` also takes `<uuid> <email>`, which names a person independently of
  their address.
- Writes that would break the hierarchy are refused: a parent or blocker
  loop, a missing or deleted parent, an open issue under a closed one.
- `--milestone <name>` links the milestone of that name
  ([format.md](format.md) §6) when exactly one open milestone has it, and
  writes `X-Milestone-Id` next to `Milestone`. Otherwise the name is
  written as plain text, as upstream does. `--milestone-id <id or name>`
  links a milestone and fails if there is none. `--milestone-mode inherit`
  takes the parent's milestone, `--milestone-mode none` (or
  `--no-milestone`) none at all. A completed or retired milestone can't be
  linked, and open work can't go into a completed one.

## ls

- `-f full` prints labels normalized (`bug, ui`), as upstream writes them,
  rather than the raw trailer text.
- Assignee, priority and milestone come from the whole history (see
  [format.md](format.md) §4), so after merges they can differ from
  upstream's "last trailer found".
- `--conflicts` lists issues with concurrent writes, and which value won.
- Without `--state`, every issue that isn't done is listed: `closed` and
  the states in `git config issue.doneStates` (default `wontfix,
  duplicate`) are done, so `in-review` is listed too. Upstream lists `open`
  only; `--state open` still does.
- `--assignee <email>` also matches a `<uuid> <email>` value.
- `--problems` lists issues with problems (a parent or blocker that is
  missing or loops back, a missing or retired milestone, an invalid value,
  ...), each with the problem, in
  any state unless `--state` is given.
- Deleted issues are left out. `--deleted` lists only them. Upstream doesn't
  know about deletion and lists them.

## show

- Unknown options after the ID are rejected. Upstream ignores them.
- `Fixed-By`, `Release`, `Reason`, the planning fields (parent, blockers,
  dates, estimate, workflow state), other fields and conflicts are shown.
- Edited comments show their current text, deleted ones are left out, and
  the event commits themselves are not listed as updates. Upstream shows
  every commit as it was written. `--ids` adds each comment's ID.

## comment

- Whitespace-only text (`-m " "`) is refused.
- Only the last paragraph is checked for text that would read as trailers.
  git never reads a single paragraph as trailers.
- `--edit <comment-id> -m <text>`, `--delete <comment-id>` and
  `--restore <comment-id>` change a comment by adding an event commit
  ([format.md](format.md) §5). Nothing is rewritten.

## edit

- `-t ""` is an error. Upstream silently does nothing.
- `--milestone ""` clears the milestone, like `-a ""` clears the assignee.
  Upstream silently does nothing.
- `-l` together with `--add-label`/`--remove-label` applies the `-l` set
  first. Upstream silently drops `-l`.
- `--description <text>` replaces the description with an event commit.
  Other changes in the same `edit` go in that commit, and `-m` is its
  subject.
- The planning options of `create`, plus `--unblock` and `--no-<field>` to
  clear a field (`--no-parent`, `--no-blockers`, `--no-assignee`, ...).

## state

- Closing an issue with open sub-issues, or opening one under a closed
  ancestor, is refused. Upstream has no hierarchy. `closed` and the
  `issue.doneStates` (`wontfix`, `duplicate` by default) count as closed
  here; other states are open work.

## search

- `-i` folds ASCII only, so results don't depend on the locale.
- The subject is searched once. Upstream searches and counts it twice.
- What the issue says now is searched: the title, the fields, the
  description and the comments, edited ones as edited. Upstream greps every
  commit message, so it also finds replaced or deleted text and event
  trailers.
- Long results end with `... N more matching lines`.
- Deleted issues are left out.

## fsck

- Milestones are checked too, with `Name:` in place of `State:`.
- `-q` is accepted as `--quiet`, and unreadable histories are reported.
- Invalid extension values and hierarchy or blocker problems are noted on
  stderr, not counted as errors: other tools can write them.

## init

- The fetch refspec is `+refs/issues/*:refs/remotes/<remote>/issues/*`
  instead of upstream's `+refs/issues/*:refs/issues/*`. Upstream's lets a
  plain `git fetch` overwrite local issues and drop unpushed changes. Every
  command warns while a remote still has it, and `git issue init <remote>
  --fix-refspec` replaces it.
- A second refspec, `+refs/milestones/*:refs/remotes/<remote>/milestones/*`,
  fetches milestones the same way.
- Several remotes as arguments are refused. Upstream takes the last one.

## merge

- A field's merged value comes from the causal rule
  ([format.md](format.md) §4) over the whole history. Upstream does a
  three-way merge of the trailers it finds at the two tips and their merge
  base. The results agree on upstream's own tests. They differ when both
  sides changed a field: upstream takes the side whose tip has the later
  author time, the causal rule the later of the two changes, and reports a
  conflict.
- Merge commits are deterministic (fixed subject, identity and date, sorted
  parents; [format.md](format.md) §4), so two clones merging the same pair
  write the same commit instead of two that need merging again.
- A remote issue with no history in common with the local one, a remote
  that rewrote history since the last merge, or one that fails `fsck` is
  quarantined: left alone and reported by `status`, until `quarantine`
  resolves it. A remote merely reset to an older tip is not: the next push
  restores the local tip.
- Several remotes as arguments are refused, as for `push` and `sync`.
- Milestones are merged too, by the same rules. Upstream ignores them.
- The remote must be a configured remote name. URLs and paths are refused
  with a `git remote add` hint; upstream fails on them too, at the fetch.
- `--no-fetch` keeps the staging refs, like upstream. A fetching merge
  removes the ones it merged.

## Commands upstream doesn't have

- `push <remote>`: fetches to see what the remote has, then pushes the
  issues and milestones that differ, never with force. When the remote
  moved, it merges first and retries. When the remote refuses a ref (a
  hook, permissions), it stops with the remote's message.
- `sync <remote>`: `merge`, then `push`.
- `close` and `reopen <id>`: `state --close` and `state --open`.
- `delete` and `restore <id>`: hide an issue from `ls`, `tree` and
  `search`, and bring it back. Nothing is removed from history.
- `tree [<id>]`: the parent and child tree, with progress over each
  parent's leaves, blockers and problems.
- `milestone create|ls|show|edit|complete|reopen|retire`: manage
  milestones. `show` lists a milestone's issues, inherited ones included,
  and its progress. `complete` is refused while any of them is open.
  `edit` writes one commit for all its changes. A retired milestone is
  named by its ID only.
- `status [<remote>]`: issues not pushed yet, quarantined issues and how to
  resolve them, and issues with conflicts. Local state only.
- `quarantine <remote> --accept-remote|--keep-local <id>`: resolves a
  quarantined issue or milestone. Nothing is force-pushed and no version
  is dropped: the replaced local tip stays under `refs/issuez-sync/`.

`fsck` notes quarantined issues on stderr without counting them as errors.

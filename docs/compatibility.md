# Compatibility with upstream

git-native-issuez is a drop-in for
[git-native-issue](https://github.com/remenoscodes/git-native-issue)
v1.3.3. The git format is the same and stays the same. The commands here
accept every upstream option with the same short and long forms. Where the
CLI behaves differently, it is on purpose, and this page says why.

Upstream's `merge` is not in this version yet.

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

## ls

- `-f full` prints labels normalized (`bug, ui`), as upstream writes them,
  rather than the raw trailer text.
- Assignee, priority and milestone come from the whole history (see
  [format.md](format.md) §4), so after merges they can differ from
  upstream's "last trailer found".
- `--conflicts` lists issues with concurrent writes, and which value won.

## show

- Unknown options after the ID are rejected. Upstream ignores them.
- `Fixed-By`, `Release`, `Reason`, other fields and conflicts are shown.

## comment

- Whitespace-only text (`-m " "`) is refused.
- Only the last paragraph is checked for text that would read as trailers.
  git never reads a single paragraph as trailers.

## edit

- `-t ""` is an error. Upstream silently does nothing.
- `--milestone ""` clears the milestone, like `-a ""` clears the assignee.
  Upstream silently does nothing.
- `-l` together with `--add-label`/`--remove-label` applies the `-l` set
  first. Upstream silently drops `-l`.

## search

- `-i` folds ASCII only, so results don't depend on the locale.
- The subject is searched once. Upstream searches and counts it twice.
- Long results end with `... N more matching lines`.

## fsck

- `-q` is accepted as `--quiet`, and unreadable histories are reported.

## init

- The fetch refspec is `+refs/issues/*:refs/remotes/<remote>/issues/*`
  instead of upstream's `+refs/issues/*:refs/issues/*`. Upstream's lets a
  plain `git fetch` overwrite local issues and drop unpushed changes. Every
  command warns while a remote still has it, and `git issue init <remote>
  --fix-refspec` replaces it.
- Several remotes as arguments are refused. Upstream takes the last one.

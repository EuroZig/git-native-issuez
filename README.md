# git-native-issuez

Issue tracking stored in git, as a Zig library and a drop-in `git-issue`
command. It reads and writes the format of
[git-native-issue](https://github.com/remenoscodes/git-native-issue) (format
1), so issues written by either tool work with the other.

Issues live under `refs/issues/<uuid>` as chains of commits with an empty
tree. There is no server, no database and nothing in the working tree.

**Status:** early. This version covers format 1: creating, listing,
showing, commenting on, editing, closing and searching issues, `fsck` and
`init`, and sharing issues between clones through any git remote (`merge`,
`push`, `sync`). On top of format 1 it adds planning fields (parent issues,
blockers, dates, estimates, workflow states), milestones, lifecycle
events (editing and deleting comments, deleting and restoring issues) and
image attachments, as extra trailers that upstream keeps and shows.

> [!WARNING]
> Generative AI was used to edit and/or produce large portions of this code.
> Every line in this repo was verified by a human.

## Usage

```sh
zig build --prefix ~/.local     # installs git-issue and the git-issue-<sub> links
git issue create "Login page crashes" -l bug -p high
git issue ls
git issue comment a7f3 -m "Happens on Safari only."
git issue edit a7f3 -a ada@example.com
git issue create "Release 1.0" --due 2026-12-01
git issue edit a7f3 --parent 5e21 --estimate 2h
git issue tree                   # parents, sub-issues, progress, blockers
git issue milestone create v1.0 --due 2026-12-01
git issue edit 5e21 --milestone v1.0   # sub-issues inherit it
git issue milestone show v1.0    # its issues and progress
git issue comment a7f3 -m "Cut off on small screens." --attach login.png
git issue attach cat a7f3 fc7b > login.png
git issue close a7f3 --fixed-by 1a2b3c4
git issue show a7f3
git issue search -i safari
git issue fsck
git issue sync origin            # merge the remote's issues, push ours
```

Issue IDs can be shortened to any unique prefix.

Edits never rewrite history: `git issue comment <id> --edit <comment-id>`,
`--delete` and `--restore`, `git issue edit <id> --description` and
`git issue delete`/`restore` each add a commit. `git issue show --ids`
shows comment IDs, `git issue ls --problems` lists issues whose parent or
blocker is missing or loops back.

Milestones live under `refs/milestones/<uuid>` and sync with the issues.
An issue is in a milestone directly or through its parent, and a
milestone can only be completed once all of its issues are closed. Linking
one also writes upstream's `Milestone:` field, so upstream shows its
name.

Attachments are PNG, JPEG or WebP images. The issue history records each
one (ID, type, size, sha256, name), and the bytes are git-lfs objects:
`git issue sync` uploads them with `git lfs push` and `attach cat` or
`attach fetch` downloads them when needed. They are kept in a store that
`git lfs prune` doesn't touch. Attachments need git-lfs: without it the
attachment commands refuse, and everything else works. See
[docs/attachments.md](docs/attachments.md).

`git issue sync <remote>` fetches the remote's issues and milestones,
merges them, and pushes the local ones. Concurrent edits get a merge commit; which value
wins follows from the history, and `git issue ls --conflicts` shows where
two clones disagreed. Sync never force-pushes and never drops a version: a
remote issue whose history was rewritten is quarantined until you decide
(`git issue status`, `git issue quarantine`). Clones can sync with
upstream's `git issue merge` and `git push` too.

`git issue <command> --help` describes each command.

Like upstream, the `git-issue-<command>` entry points are installed next to
`git-issue`, so scripts that call them directly keep working.

**Importing from GitHub, GitLab, Gitea/Forgejo or Azure DevOps:** use
upstream's `git-issue-import <provider>:<path>` (and `git-issue-export` to
go back) in the same repository. The provider bridges are not reimplemented
here and are currently not planned, contributions are welcome though. The
issues they write work with this tool as they are, because both tools share
the format.

## Using the library

Add the package with `zig fetch --save <url>` and import the `issuez`
module:

```zig
// build.zig
const issuez_dep = b.dependency("git_native_issuez", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("issuez", issuez_dep.module("issuez"));
```

```zig
const issuez = @import("issuez");
const Repo = issuez.Repo(issuez.backend.GitProcess);

var git = try issuez.backend.GitProcess.open(io, gpa, .{ .path = ".", .environ_map = env });
defer git.close();
const repo = Repo.init(&git);
const created = try repo.create(arena, .{ .title = "Login page crashes", .labels = &.{"bug"} });
const open = try issuez.query.list(arena, try repo.loadAll(arena), .{ .state = .open }, .{});
for (open) |issue| std.debug.print("{s} {s}\n", .{ issue.state.text(), issue.title });
```

`Repo` is generic over its backend. `GitProcess` drives the `git` binary,
`GitSim` is an in-memory repository for tests, and you can bring your own
(see [docs/design.md](docs/design.md)).

| Example                                           | Shows                                                                                  | Run                                        |
| ------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------ |
| [quickstart.zig](examples/quickstart.zig)         | create, resolve by prefix, comment, edit, close, list, show (in memory, no git needed) | `zig build example-quickstart`             |
| [sync.zig](examples/sync.zig)                     | two clones syncing through a remote, with a concurrent edit (in memory)                | `zig build example-sync`                   |
| [attachments.zig](examples/attachments.zig)       | validate, attach with a comment, read bytes back, rename and remove (in memory)        | `zig build example-attachments`            |
| [real_repo.zig](examples/real_repo.zig)           | the same API on a real repository through `GitProcess`                                 | `zig build example-real-repo -- <repo> ls` |
| [custom_backend.zig](examples/custom_backend.zig) | your own backend (audit log, write policy) and ETag-style `.expect` versions           | `zig build example-custom-backend`         |

## Docs

- [docs/format.md](docs/format.md): the format on disk.
- [docs/attachments.md](docs/attachments.md): attachments in the CLI and
  the library.
- [docs/design.md](docs/design.md): how the library is put together.
- [docs/compatibility.md](docs/compatibility.md): where the CLI differs from
  upstream on purpose.

## Development

Requires Zig 0.16.0 and git 2.30 or newer.

```sh
zig build                      # git-issue and the git-issue-<sub> links
zig build test                 # unit, backend, CLI, simulator and fuzz smoke tests, examples
zig build test-interop         # both tools on shared repositories (fetches upstream)
zig build test-upstream-suite  # upstream's t/*.sh against our git-issue
zig build test-perf            # `ls -a` over 10 000 issues within 1 s
zig build ci -Dseed=N          # all of the above, plus long fuzz runs: what CI runs
zig build update-snapshots     # rewrite examples/*.out after an intended output change
```

`zig build test` runs every example. The in-memory ones must print exactly
their snapshot (`examples/<name>.out`), and `real-repo` runs against a fresh
repository in a temporary directory.

Every command runs in a simulator on an in-memory repository, and an
independent oracle checks what it may change. The fuzzer runs random
commands through both; see [docs/design.md](docs/design.md). Upstream is
only fetched for `test-interop` and `test-upstream-suite`, and never
vendored. [CONTRIBUTING.md](CONTRIBUTING.md) has the rules for changes.

## License

MIT, see [LICENSE](LICENSE). Upstream git-native-issue is GPL-2.0 and no
part of it is included here.

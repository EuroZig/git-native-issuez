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
image attachments, as extra trailers that upstream keeps and shows. Read
commands print JSON with `--json`, `git issue mcp` serves the issues to
coding agents, and the install includes shell completions and man pages.

> [!WARNING]
> Generative AI was used to edit and/or produce large portions of this code.
> Every line in this repo was verified by a human.

## Install

On Linux and macOS, `install.sh` downloads the latest release for your
machine, checks it against the release's `SHA256SUMS` and installs it into
`~/.local`:

```sh
curl -fsSL https://raw.githubusercontent.com/EuroZig/git-native-issuez/main/install.sh | sh
```

`sh -s -- --flavor minimal` picks the CLI-only flavor, `--version 0.1.0`
a release, `--prefix /usr/local` another place (`--help` lists them all).
Only the copy into a prefix you can't write to runs with `sudo` (or
`doas`), which asks for your password once; don't run the whole script
with `sudo`. It doesn't touch your shell configuration: if `~/.local/bin`
isn't on `PATH`, it says what to add. To read it first, download it and
run `sh install.sh`.

`update-git-native-issuez`, installed next to `git-issue`, updates to the
latest release with the same flavor and prefix. It leaves an up-to-date
install alone and refuses a downgrade without `--allow-downgrade`.

Each [release](https://github.com/EuroZig/git-native-issuez/releases) has
archives for Linux and macOS (x86_64 and aarch64) and Windows (x86_64), in
two flavors: `full`, the default with the MCP server, and `minimal`, the
CLI only. The Linux and macOS archives also have the shell completions,
man pages and docs under `share/`; the Windows archive has `git-issue.exe`
only, so run `git issue <command>` there. `SHA256SUMS` lists the checksums. By
hand, unpack one (`.tar.gz`, or `.zip` for Windows) into a prefix that has
`bin/` on your `PATH`, such as `~/.local`:

```sh
gh release download v0.1.0 --repo EuroZig/git-native-issuez --pattern '*-full-aarch64-macos.tar.gz'
tar -xzf git-native-issuez-0.1.0-full-aarch64-macos.tar.gz --strip-components=1 -C ~/.local
```

On macOS, an archive downloaded with a browser is quarantined and the
unpacked `git-issue` won't run; download it with `gh` or `curl -LO`
instead, or clear the flag with `xattr -d com.apple.quarantine <archive>`
before unpacking.

Or build it, with Zig 0.16.0: `zig build -Doptimize=ReleaseSafe --prefix ~/.local`
(add `-Dminimal` for the CLI only).

## Usage

```sh
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
git issue ls --json              # for scripts, see docs/json.md
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

`git issue <command> --help` describes each command. The same texts are
installed as man pages (`man git-issue-create`; `git issue --help` opens
`git-issue(1)` through git). `zig build install` puts them and the bash,
zsh and fish completions under the prefix's `share/`, for native builds.
`git issue completion <shell>` prints a completion script by hand.

`--json` on `ls`, `show`, `tree`, `search`, `status`, `attach ls`,
`milestone ls` and `milestone show` prints JSON for scripts and programs
that don't link the library. Fields are only ever added
([docs/json.md](docs/json.md)).

For [lazygit](https://github.com/jesseduffield/lazygit),
[docs/lazygit.md](docs/lazygit.md) has an issues menu under one key.

`git issue mcp` is a [Model Context Protocol](https://modelcontextprotocol.io)
server on stdio for coding agents: it lists, shows and searches issues and
milestones, and creates, comments on, edits, closes and reopens issues,
through the library. For Claude Code, run `git issue mcp install` once for
every project; [docs/mcp.md](docs/mcp.md) has the tools, the install scopes
and other clients.

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

As a dependency the package builds only the library, so blitzmcp (the MCP
server's dependency) is never fetched; pass `.mcp = true` to also get it in
the `git-issue` build.

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
- [docs/json.md](docs/json.md): the `--json` output.
- [docs/lazygit.md](docs/lazygit.md): an issues menu for lazygit.
- [docs/mcp.md](docs/mcp.md): the MCP server for coding agents.
- [docs/design.md](docs/design.md): how the library is put together.
- [docs/compatibility.md](docs/compatibility.md): where the CLI differs from
  upstream on purpose.
- [CHANGELOG.md](CHANGELOG.md): what changed.

## Development

Requires Zig 0.16.0 and git 2.30 or newer.

```sh
zig build                      # git-issue with the MCP server, the git-issue-<sub> links, completions, man pages
zig build -Dminimal            # the same without the MCP server
zig build test                 # unit, backend, CLI, simulator and fuzz smoke tests, examples
zig build test-interop         # both tools on shared repositories (fetches upstream)
zig build e2e                  # `git issue mcp` against the official MCP SDK client (Node.js, npm)
zig build test-upstream-suite  # upstream's t/*.sh against our git-issue
zig build test-perf            # `ls -a` over 10 000 issues within 2 s
zig build ci -Dseed=N          # all of the above, plus long fuzz runs: what CI runs
zig build update-snapshots     # rewrite examples/*.out after an intended output change
zig build release              # the release archives for every platform, cross-compiled, in zig-out/release/
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

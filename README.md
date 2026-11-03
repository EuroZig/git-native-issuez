# git-native-issuez

Issue tracking stored in git, as a Zig library and a drop-in `git-issue`
command. It reads and writes the format of
[git-native-issue](https://github.com/remenoscodes/git-native-issue) (format
1), so issues written by either tool work with the other.

- **No server, no database:** issues are commit chains under
  `refs/issues/<uuid>`, shared through any git remote.
- **More than format 1:** parent issues, blockers, dates, estimates,
  workflow states, milestones and image attachments, as extra trailers that
  upstream keeps and shows.
- **A terminal UI:** a list, a kanban board and a detail view, usable with
  the mouse, updating live when anyone else writes.
- **For coding agents:** `git issue mcp`, a Model Context Protocol server.
- **For scripts:** `--json` on every read command, man pages and shell
  completions.

![The list: issues with their labels, priority, workflow state, assignee and due date, sorted by priority](docs/issuez-list.png)

![The board: a column per workflow state, cards with priority, progress, labels and assignee](docs/issuez-board.png)

> [!WARNING]
> Generative AI was used to edit and/or produce large portions of this code.
> Every line in this repo was verified by a human.

## Install

```sh
# Linux and macOS
curl -fsSL https://raw.githubusercontent.com/EuroZig/git-native-issuez/main/install.sh | sh

# Homebrew (macOS 13 or later, Linux)
brew tap eurozig/tap
brew trust eurozig/tap
brew install git-native-issuez
```

Windows archives, the CLI-only flavor, the installer's options and building
from source: [Installing in detail](#installing-in-detail).

## Quick start

```sh
git issue create "Login page crashes" -l bug -p high
git issue ls
git issue comment a7f3 -m "Happens on Safari only."
git issue edit a7f3 -a ada@example.com --estimate 2h
git issue close a7f3 --fixed-by 1a2b3c4
git issue sync origin            # merge the remote's issues, push ours
git issue                        # at a terminal: the terminal UI
```

Issue IDs can be shortened to any unique prefix.
`git issue <command> --help` (or `man git-issue-<command>`) describes each
command.

## Features

### Planning and milestones

```sh
git issue edit a7f3 --parent 5e21 --due 2026-12-01
git issue tree                         # parents, sub-issues, progress, blockers
git issue milestone create v1.0 --due 2026-12-01
git issue edit 5e21 --milestone v1.0   # sub-issues inherit it
git issue milestone show v1.0          # its issues and progress
```

- An issue is in a milestone directly or through its parent; a milestone
  completes once all of its issues are closed.
- Milestones live under `refs/milestones/<uuid>` and sync with the issues.
  Linking one also writes upstream's `Milestone:` field.

### History is never rewritten

- Editing, deleting and restoring comments (`comment --edit`, `--delete`,
  `--restore`) and issues (`delete`, `restore`) each add a commit.
- `git issue show --ids` shows comment IDs; `git issue ls --problems` lists
  issues whose parent or blocker is missing or loops back.

### Sync

- `git issue sync <remote>` fetches, merges and pushes issues and
  milestones. Concurrent edits get a merge commit, and
  `git issue ls --conflicts` shows where clones disagreed.
- It never force-pushes or drops a version: an issue whose remote history
  was rewritten is quarantined until you decide (`git issue status`,
  `git issue quarantine`).
- Clones can also sync with upstream's `git issue merge` and `git push`.

### Attachments

```sh
git issue comment a7f3 -m "Cut off on small screens." --attach login.png
git issue attach cat a7f3 fc7b > login.png
```

PNG, JPEG or WebP images, stored as git-lfs objects that `git issue sync`
uploads and downloads. Without git-lfs only the attachment commands refuse.
See [docs/attachments.md](docs/attachments.md).

### Terminal UI

`git issue tui`, or plain `git issue` at a terminal:

- a list, optionally as a tree of sub-issues, sortable and filterable
  (`label:ui @ada p:high is:blocked -label:wontfix`);
- a kanban board with a column per workflow state;
- a detail view where every field is edited in place.

`?` shows the keys, and the mouse works everywhere. It follows what others
write as it happens: `git issue` in another terminal, another TUI, an agent,
a sync.

### Coding agents (MCP)

`git issue mcp` serves the issues over the
[Model Context Protocol](https://modelcontextprotocol.io) on stdio: tools to
list, show, search, create, comment on, edit and close issues, and resources
that notify subscribers of changes. For Claude Code, run
`git issue mcp install` once; [docs/mcp.md](docs/mcp.md) has the tools and
other clients.

### Scripts and other tools

- `--json` on `ls`, `show`, `tree`, `search`, `status`, `attach ls`,
  `milestone ls` and `milestone show`; fields are only ever added
  ([docs/json.md](docs/json.md)).
- The `git-issue-<command>` entry points are installed like upstream's, so
  scripts calling them keep working.
- [lazygit](https://github.com/jesseduffield/lazygit): an issues menu under
  one key ([docs/lazygit.md](docs/lazygit.md)).

### Importing from GitHub, GitLab and others

Import, export and two-way sync with GitHub, GitLab and Gitea/Forgejo, and
import from Azure DevOps, are upstream's: install
[git-native-issue](https://github.com/remenoscodes/git-native-issue) next to
this one and run its bridges in the same repository. Both tools share the
issue refs, so what they import works here as it is. git-native-issuez
doesn't install the `git-issue-import`, `git-issue-export` or
`git-issue-sync` entry points, so with both on `PATH` the hyphenated names
run upstream's; `git issue import` runs this one, which refuses and points
there. Both install a `git-issue`: `git issue` runs whichever comes first on
`PATH`, so put this one's directory first.

```sh
git-issue-import github:owner/repo --state all   # all issues, with comments
git-issue-export github:owner/repo               # local issues back to GitHub
git-issue-sync gitlab:group/project              # import, then export
```

Upstream's docs cover the providers, tokens and options:
[Platform Bridges](https://github.com/remenoscodes/git-native-issue#platform-bridges),
the [GitLab](https://github.com/remenoscodes/git-native-issue/blob/main/docs/gitlab-bridge.md)
and [Gitea/Forgejo](https://github.com/remenoscodes/git-native-issue/blob/main/docs/gitea-bridge.md)
bridges, and the
[migration guide](https://github.com/remenoscodes/git-native-issue/blob/main/docs/migration-guide.md).
The bridges aren't reimplemented here (contributions are welcome).

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

- `Repo` is generic over its backend: `GitProcess` drives the `git` binary,
  `GitSim` is an in-memory repository for tests, or bring your own
  ([docs/design.md](docs/design.md)).
- As a dependency the package builds only the library: libvaxis, blitzmcp
  and nightwatch are never fetched. Pass `.tui = true` or `.mcp = true` to
  build them into `git-issue`.

| Example                                           | Shows                                                                                  | Run                                        |
| ------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------ |
| [quickstart.zig](examples/quickstart.zig)         | create, resolve by prefix, comment, edit, close, list, show (in memory, no git needed) | `zig build example-quickstart`             |
| [sync.zig](examples/sync.zig)                     | two clones syncing through a remote, with a concurrent edit (in memory)                | `zig build example-sync`                   |
| [attachments.zig](examples/attachments.zig)       | validate, attach with a comment, read bytes back, rename and remove (in memory)        | `zig build example-attachments`            |
| [real_repo.zig](examples/real_repo.zig)           | the same API on a real repository through `GitProcess`                                 | `zig build example-real-repo -- <repo> ls` |
| [custom_backend.zig](examples/custom_backend.zig) | your own backend (audit log, write policy) and ETag-style `.expect` versions           | `zig build example-custom-backend`         |

## Docs

- [docs/format.md](docs/format.md): the format on disk.
- [docs/attachments.md](docs/attachments.md): attachments in the CLI and the
  library.
- [docs/json.md](docs/json.md): the `--json` output.
- [docs/lazygit.md](docs/lazygit.md): an issues menu for lazygit.
- [docs/mcp.md](docs/mcp.md): the MCP server for coding agents.
- [docs/design.md](docs/design.md): how the library is put together.
- [docs/compatibility.md](docs/compatibility.md): where the CLI differs from
  upstream on purpose.
- [CHANGELOG.md](CHANGELOG.md): what changed.

## Installing in detail

### Flavors and archives

Each [release](https://github.com/EuroZig/git-native-issuez/releases) has
two flavors, for Linux and macOS (x86_64, aarch64) and Windows (x86_64):

- `full`, the default: with the terminal UI and the MCP server;
- `minimal`: the CLI only.

The Linux and macOS archives also have the shell completions, man pages and
docs under `share/`. The Windows archive has `git-issue.exe` only: run
`git issue <command>` there. `SHA256SUMS` lists the checksums. To install
one by hand, unpack it into a prefix with `bin/` on your `PATH`:

```sh
gh release download v0.2.0 --repo EuroZig/git-native-issuez --pattern '*-full-aarch64-macos.tar.gz'
tar -xzf git-native-issuez-0.2.0-full-aarch64-macos.tar.gz --strip-components=1 -C ~/.local
```

On macOS, an archive downloaded with a browser is quarantined and
`git-issue` won't run: download it with `gh` or `curl -LO`, or run
`xattr -d com.apple.quarantine <archive>` before unpacking.

### install.sh

It downloads the latest release for your machine, checks it against
`SHA256SUMS` and unpacks it into `~/.local`.

- Options go after `sh -s --`: `--flavor minimal`, `--version 0.2.0`,
  `--prefix /usr/local`. For a prefix you can't write to, pipe it into
  `sudo sh -s -- --prefix /usr/local`.
- It doesn't touch your shell configuration: if `~/.local/bin` isn't on
  `PATH`, it says so.
- To read it first, download it and run `sh install.sh`.
- `update-git-native-issuez`, installed next to `git-issue`, updates with
  the same flavor and prefix; extra arguments (`--version`, `--no-verify`)
  go to `install.sh`. It refuses an `install.sh` older than the one it came
  from.
- `--no-verify` skips the checksum check, for that run only.
- `update-git-native-issuez --uninstall` (or
  `install.sh --uninstall --prefix <dir>`) removes everything it installed,
  and nothing else. The issues in your repositories stay.

### Homebrew

The [EuroZig tap](https://github.com/EuroZig/homebrew-tap) installs the full
flavor with the man pages and the bash, zsh and fish completions. Homebrew
only loads formulae from taps outside its own once you trust them, so
`brew trust eurozig/tap` is needed once; after that, `brew upgrade` keeps
git-native-issuez up to date with your other packages. A Homebrew without
`brew trust` doesn't need that line.

### From source

With Zig 0.16.0 and git 2.30 or newer:

```sh
zig build -Doptimize=ReleaseSafe --prefix ~/.local   # add -Dminimal for the CLI only
```

## Development

```sh
zig build                      # git-issue with the TUI and the MCP server, links, completions, man pages
zig build -Dminimal            # without the TUI and the MCP server (or -Dtui=false / -Dmcp=false)
zig build test                 # unit, backend, CLI, simulator and fuzz smoke tests, examples
zig build test-interop         # both tools on shared repositories (fetches upstream)
zig build e2e                  # the MCP server with the official SDK client (Node.js, npm),
                               # and two TUIs on pseudo-terminals following each other's writes
zig build test-tui-e2e         # only the TUIs' (Linux, macOS)
zig build test-upstream-suite  # upstream's t/*.sh against our git-issue
zig build test-perf            # `ls -a` over 10 000 issues within 2 s
zig build ci -Dseed=N          # all of the above, plus long fuzz runs: what CI runs
zig build update-snapshots     # rewrite examples/*.out after an intended output change
zig build release              # the release archives for every platform, in zig-out/release/
```

- Every command also runs in a simulator on an in-memory repository, where
  an independent oracle checks what it may change, and a fuzzer runs random
  commands through both ([docs/design.md](docs/design.md)).
- The in-memory examples must print exactly their snapshot
  (`examples/<name>.out`).
- Upstream is only fetched for `test-interop` and `test-upstream-suite`, and
  never vendored.
- [CONTRIBUTING.md](CONTRIBUTING.md) has the rules for changes.

## License

MIT, see [LICENSE](LICENSE). Upstream git-native-issue is GPL-2.0 and no
part of it is included here.

# git-native-issuez

Issue tracking stored in git, as a Zig library and a drop-in `git-issue`
command. It reads and writes the format of
[git-native-issue](https://github.com/remenoscodes/git-native-issue) (format
1), so issues written by either tool work with the other.

Issues live under `refs/issues/<uuid>` as chains of commits with an empty
tree. There is no server, no database and nothing in the working tree.

**Status:** early. This version covers format 1 on a single repository:
creating, listing, showing, commenting on, editing, closing and searching
issues, plus `fsck` and `init`. Sharing issues between clones (`merge`,
`push`, `sync`) is not here yet.

## Usage

```sh
zig build --prefix ~/.local     # installs git-issue and the git-issue-<sub> links
git issue create "Login page crashes" -l bug -p high
git issue ls
git issue comment a7f3 -m "Happens on Safari only."
git issue edit a7f3 -a ada@example.com
git issue state a7f3 --close --fixed-by 1a2b3c4
git issue show a7f3
git issue search -i safari
git issue fsck
```

Issue IDs can be shortened to any unique prefix.
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
const open = try issuez.query.list(arena, try repo.loadAll(arena), .{ .state = "open" }, .{});
for (open) |issue| std.debug.print("{s} {s}\n", .{ issue.state, issue.title });
```

`Repo` is generic over its backend. `GitProcess` drives the `git` binary,
`GitSim` is an in-memory repository for tests, and you can bring your own
(see [docs/design.md](docs/design.md)).

| Example                                           | Shows                                                                                  | Run                                        |
| ------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------ |
| [quickstart.zig](examples/quickstart.zig)         | create, resolve by prefix, comment, edit, close, list, show (in memory, no git needed) | `zig build example-quickstart`             |
| [real_repo.zig](examples/real_repo.zig)           | the same API on a real repository through `GitProcess`                                 | `zig build example-real-repo -- <repo> ls` |
| [custom_backend.zig](examples/custom_backend.zig) | your own backend (audit log, write policy) and ETag-style `.expect` versions           | `zig build example-custom-backend`         |

## Docs

- [docs/format.md](docs/format.md): the format on disk.
- [docs/design.md](docs/design.md): how the library is put together.
- [docs/compatibility.md](docs/compatibility.md): where the CLI differs from
  upstream on purpose.

## Development

Requires Zig 0.16.0 and git 2.30 or newer.

```sh
zig build                   # git-issue and the git-issue-<sub> links
zig build test              # unit tests, the backend against real git, CLI tests, examples
zig build update-snapshots  # rewrite examples/*.out after an intended output change
```

`zig build test` runs every example. The in-memory ones must print exactly
their snapshot (`examples/<name>.out`), and `real-repo` runs against a fresh
repository in a temporary directory.

> [!WARNING] Generative AI was used to edit and/or produce large portions of
> this code. Every line in this repo was verified by a human

## License

MIT, see [LICENSE](LICENSE). Upstream git-native-issue is GPL-2.0 and no
part of it is included here.

# Contributing

Contributions of any kind are welcome: bug reports, fixes, features, docs
and tests. For a bigger change, open an issue first so we can agree on the
approach before you put in the work.

## Setup

- Zig **0.16.0** (`minimum_zig_version` in `build.zig.zon`; 0.17 isn't
  supported yet).
- git ≥ 2.30.
- For the upstream suite: bash, and on Debian-like systems gawk (upstream's
  `fsck` fails on mawk) and uuid-runtime.

```sh
zig build test                 # the default check
zig build test-interop         # against upstream git-native-issue (fetched lazily)
zig build test-upstream-suite  # upstream's own t/*.sh against our binary
zig build test-perf            # 10 000 issues, `ls -a` within budget
zig build -Dfuzz -Doptimize=ReleaseSafe && zig-out/bin/git-issue-fuzz --iterations 4000
```

A change is ready when all five pass. When the fuzzer fails, it prints a
replay command (`--seed N --iterations 1`).

## Rules that keep the project working

- **The format stays upstream-compatible; the CLI may improve.** Every issue
  we write must stay valid format 1, readable by upstream and accepted by its
  `fsck` ([docs/format.md](docs/format.md)). CLI behaviour and messages may
  differ from upstream when that is better; record the difference in
  [docs/compatibility.md](docs/compatibility.md).
- **Provider bridges are open for contributions.** Import, export and
  provider sync (GitHub, GitLab, Gitea/Forgejo, Azure DevOps) aren't
  implemented here and the maintainers don't plan to, but contributions are
  welcome. Until then the CLI refuses them and points to upstream's tools.
  Upstream installs `git-issue-import`, `git-issue-export` and
  `git-issue-sync`, so names reserved for them
  (`src/cli/entry_points.zig`) are a question to settle in the issue first.
- **Library first.** Features belong in the library (`src/engine/`) with
  bytes-in/bytes-out APIs and typed errors; the CLI (`src/cli/`) is a thin
  client. Other programs build on the library the same way.
- **Every write rule is checked twice.** The engine enforces it. The oracle
  (`src/oracle/`) restates it independently, and the fuzzer
  (`src/cli/main_fuzz.zig`) generates the commands that exercise it. When
  you add a rule, add the oracle check, then break the engine on purpose and
  confirm the fuzzer catches it.
- **No unbounded work.** Every loop and read has a limit (`Limits`), and no
  input can make a computation loop or overflow.

## Code

- Lines stay at or under 100 columns, and `zig fmt` is applied.
- Comments explain why, not what. Match the density of the surrounding code.
- Tests sit next to the code (`test "…"` blocks), plus:
  - `test/backend_git.zig` and `test/trailers_git.zig`: the backend and the
    trailer parser against real git;
  - `test/cli_git.zig`: our binary against real git;
  - `test/interop.zig`: both tools on shared repositories;
  - `test/upstream_suite.zig`: upstream's tests against our binary. A test
    that has to pass goes in `test/upstream-expected.txt`, one where we
    differ on purpose in `test/upstream-allowlist.txt` with the reason;
  - `examples/`: every example runs in `zig build test`, and the in-memory
    ones must match their `.out` snapshot (`zig build update-snapshots`
    after an intended change).
- Docs: [docs/design.md](docs/design.md) describes how the code is put
  together. Update it, `format.md` or `compatibility.md` when a change
  affects them.

## Commits

One topic per commit, subject `(<type>) <summary>`, where `<type>` is `add`,
`fix` or `chore`, for example
`(add) search: --state filter`. The body says what changed and why, and
names the tests that cover it.

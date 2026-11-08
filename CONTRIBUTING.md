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
- For the attachment test in `test/cli_git.zig`: git-lfs. Without it the
  test is skipped.
- For the completion and man page test: zsh, fish and mandoc. Each check
  is skipped without its tool.
- For the C API and Go binding (`zig build test-bindings`, part of
  `zig build ci`): a C compiler and Go 1.26 or newer; git-lfs for the
  attachment scenarios. For `zig build test-bindings-linux`, the same in a
  Linux container: docker.
- For the MCP server's end-to-end tests (`zig build e2e`, part of
  `zig build ci`): Node.js 20 or newer and npm. They drive `git-issue mcp`
  with the official MCP TypeScript SDK client (`test/e2e/`). The TUI's,
  also in `zig build e2e` and alone as `zig build test-tui-e2e`, need
  nothing but Linux or macOS: two TUIs on pseudo-terminals
  (`test/live_tui.zig`).

```sh
zig build test                 # the quick check, TUI included
zig build test -Dtui=false     # the same without the TUI
zig build test-bindings        # the C API and Go binding (needs cc and Go 1.26+)
zig build test-bindings-linux  # the same in a Linux container (needs docker)
zig build ci                   # what CI runs: also interop, upstream's suite, perf
                               # and long fuzz runs (-Dseed=N for other cases)
```

A change is ready when `zig build ci` and `zig build test -Dtui=false`
pass. A failed CI run reproduces with `zig build ci -Dseed=<run id>`; the
run id is in the job's command line. When the fuzzer fails, it also prints
a replay command for that case
(`zig build -Dfuzz && zig-out/bin/git-issue-fuzz --seed N --iterations 1`).

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
- **`--json` output only grows.** Add fields, never rename, retype or
  remove them ([docs/json.md](docs/json.md)).

## Code

- Lines stay at or under 100 columns (`zig build test` checks the Zig
  files), and `zig fmt` is applied.
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

One topic per commit, subject `(<type>) <summary>`, where `<type>` is `add`
(new behaviour), `change` (different behaviour), `fix`, `refactor` (same
behaviour), `docs` or `chore`, for example
`(add) search: --state filter`. The body says what changed and why, and
names the tests that cover it. Update [CHANGELOG.md](CHANGELOG.md) under
"Unreleased" for user-visible changes.

## Releasing

1. Move the entries under `## [Unreleased]` in `CHANGELOG.md` to a new
   `## [X.Y.Z] - YYYY-MM-DD` section, set `.version = "X.Y.Z"` in
   `build.zig.zon`, and run `zig build capi-header`: the committed C header
   and API description carry the version. Point the examples in `README.md`,
   `bindings/go/README.md` and `install.sh` at it.
2. Merge to `main`, then tag the merge commit and push the tag:

   ```sh
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```

   `.github/workflows/release.yml` checks that the tag matches
   `build.zig.zon` and that `CHANGELOG.md` has the version, runs the
   tests natively on Linux and macOS (x86_64 and aarch64, both flavors;
   `zig build ci` on x86_64 Linux), and only if they all pass runs
   `zig build release` and publishes the release with the changelog entry
   as its notes. A failed gate publishes nothing: fix it, then move the
   tag (`git tag -f vX.Y.Z && git push -f origin vX.Y.Z`). After publishing
   it tags the Go module as `bindings/go/vX.Y.Z`, and updates the Homebrew tap
   and `EuroZig/git-native-issuez-go`, the Go module with the archives
   (`tools/go-module.sh`, deploy key in the secret `GO_MODULE_DEPLOY_KEY`).
   Don't move the Go tags: Go's checksum database remembers a version for good.
   If only `go-module` or `homebrew` fails, the release is out: rerun that job.

`zig build release` cross-compiles both flavors for every platform and
writes the archives and their `SHA256SUMS` to `zig-out/release/`; run it
before tagging to check them. It needs `sh`, `tar` and `zip`. To try
`install.sh` on them, run
`sh install.sh --from zig-out/release --version X.Y.Z --prefix /tmp/try`;
the release workflow does the same before it publishes.

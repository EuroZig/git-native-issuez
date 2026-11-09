//!   zig build                      git-issue, full: TUI and MCP server
//!   zig build link                 symlink it into ~/.local (-Dlink-prefix), `unlink` undoes it
//!   zig build -Dminimal            git-issue, CLI only (-Dtui=false -Dmcp=false)
//!   zig build -Dtui=false          without the TUI; -Dmcp=false without the MCP server
//!   zig build test                 unit, backend, simulator/oracle and fuzz smoke tests
//!   zig build simulator            git-issue-sim
//!   zig build -Dfuzz               also install git-issue-fuzz
//!   zig build release              both flavors and libissuez, every target, in zig-out/release/
//!   zig build test-interop         tests against upstream (fetched lazily)
//!   zig build test-upstream-suite  upstream's t/*.sh against our binary
//!   zig build test-perf            `ls` over 10 000 issues
//!   zig build e2e                  the MCP server against the official SDK client (Node.js),
//!                                  and the TUI's live updates on pseudo-terminals
//!   zig build test-tui-e2e         only the TUI's
//!   zig build ci [-Dseed=N]        what CI runs
//!   zig build examples             library examples (examples/*.zig)
//!   zig build example-<name>       run one (quickstart, sync, attachments, real-repo -- <path> ls)
//!   zig build update-snapshots     rewrite examples/*.out
//!   zig build capi                 libissuez.a, include/issuez.h, share/issuez/issuez-api.json
//!   zig build capi-header          rewrite the committed header and API description
//!   zig build go-libs [-Dgo-libs-all]  lib/go/<platform>/libissuez.a (host, or every target)
//!   zig build test-capi            the C smoke test under ASan (needs a C compiler)
//!   zig build test-go              the Go binding's tests (needs Go)
//!   zig build test-go-e2e          the Go binding against the CLI (needs Go)
//!   zig build test-bindings        test-capi-zig, test-capi, test-go and test-go-e2e
//!   zig build test-bindings-linux  the same in a Linux container (needs docker)
//!   zig build fuzz-go [-Dfuzz-time=60s]  fuzz the Go binding, with the leak check

const std = @import("std");
const entry_points = @import("src/cli/entry_points.zig");

const zon_version: []const u8 = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    if (isRootPackage(b)) {
        forgetOuterRepository(b);
        skipGitStub(b);
    }
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Projects depending on the library need neither the TUI nor the MCP
    // server, nor their dependencies.
    const minimal = b.option(
        bool,
        "minimal",
        "CLI only: no terminal UI and no MCP server (-Dtui=false -Dmcp=false)",
    ) orelse false;
    const full = isRootPackage(b) and !minimal;
    const tui = b.option(
        bool,
        "tui",
        "Include the terminal UI (default: true, false with -Dminimal or as a dependency)",
    ) orelse full;
    const mcp = b.option(
        bool,
        "mcp",
        "Include the MCP server (default: true, false with -Dminimal or as a dependency)",
    ) orelse full;
    const fuzz = b.option(bool, "fuzz", "Install the fuzzer") orelse false;

    // Dependents and the tests get build.zig.zon's version, so a commit alone
    // doesn't throw away test results. What gets installed gets git's.
    const issuez = b.addModule("issuez", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{versionImport(b, zon_version)},
    });
    const version = describeVersion(b);
    const cli: Cli = .init(b, target, optimize, b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{versionImport(b, version)},
    }));
    const extras = cli.parts(.{ .tui = tui, .mcp = mcp });
    const test_cli: Cli = .init(b, target, optimize, issuez);
    const oracle = test_cli.oracle;
    const test_extras = test_cli.parts(.{ .tui = tui, .mcp = mcp });

    const exe = cli.exe("git-issue", "src/cli/main.zig", optimize, extras);
    b.installArtifact(exe);
    installEntryPoints(b, exe);
    installCompletions(b, exe);
    installManPages(b, exe);
    addLinkSteps(b, exe);

    const release_step = b.step(
        "release",
        "Archives of both flavors for every release target, and SHA256SUMS",
    );
    // The full flavor's lazy dependencies are only fetched for a full build.
    if (full) {
        addRelease(b, release_step);
    } else {
        const fail = b.addFail("zig build release needs the full build: drop -Dminimal");
        release_step.dependOn(&fail.step);
    }

    const run_step = b.step("run", "Run git-issue");
    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    run_step.dependOn(&run_exe.step);

    // These never include the TUI or the MCP server.
    const sim = test_cli.exe("git-issue-sim", "src/cli/main_sim.zig", optimize, .{});
    const sim_step = b.step("simulator", "Build git-issue-sim");
    sim_step.dependOn(&b.addInstallArtifact(sim, .{}).step);

    const fuzz_exe = test_cli.exe("git-issue-fuzz", "src/cli/main_fuzz.zig", optimize, .{});
    if (fuzz) b.installArtifact(fuzz_exe);

    const test_step = b.step("test", "Run unit, backend, simulator/oracle and fuzz smoke tests");
    // Lines stay within 100 columns (CONTRIBUTING.md).
    if (isRootPackage(b) and hasPath(b, "tools")) {
        const line_length = b.addExecutable(.{
            .name = "line-length",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/line_length.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        const run = b.addRunArtifact(line_length);
        for ([_][]const u8{ "build.zig", "src", "test", "examples", "tools" }) |p|
            run.addArg(b.pathFromRoot(p));
        run.expectExitCode(0);
        run.has_side_effects = true;
        test_step.dependOn(&run.step);
    }

    const unit_roots = [_]struct { name: []const u8, module: *std.Build.Module }{
        .{ .name = "issuez", .module = issuez },
        .{ .name = "oracle", .module = oracle },
        .{ .name = "cli", .module = test_cli.module("src/cli/main.zig", optimize, test_extras) },
    };
    for (unit_roots) |u| {
        const t = b.addTest(.{ .name = u.name, .root_module = u.module });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    if (test_extras.tui) |m| {
        const t = b.addTest(.{ .name = "tui", .root_module = m });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
        b.step("test-tui", "Run the TUI's tests").dependOn(&run_t.step);
    }
    if (test_extras.mcp) |m| {
        const t = b.addTest(.{ .name = "mcp", .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    if (test_extras.watch) |m| {
        const t = b.addTest(.{ .name = "watch", .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Drives `git-issue mcp` with the official MCP TypeScript SDK client
    // (test/e2e/). Needs Node.js and npm. The test project is copied
    // into the cache and installed there, so `npm ci` is cached until one of
    // its files changes and the source tree stays clean.
    const e2e_step = b.step(
        "e2e",
        "Run the MCP server's and the TUI's end-to-end tests (needs Node.js and npm)",
    );
    if (extras.mcp != null) {
        const files = b.addWriteFiles();
        _ = files.addCopyFile(b.path("test/e2e/package.json"), "package.json");
        _ = files.addCopyFile(b.path("test/e2e/package-lock.json"), "package-lock.json");
        const script = files.addCopyFile(b.path("test/e2e/mcp.test.mjs"), "mcp.test.mjs");
        _ = files.addCopyFile(b.path("test/e2e/live_client.mjs"), "live_client.mjs");

        // From PATH when the step runs, so builds without Node.js work.
        const npm_ci = b.addSystemCommand(&.{ "npm", "ci", "--no-audit", "--no-fund" });
        npm_ci.setCwd(files.getDirectory());
        // Capturing the output makes the step cacheable.
        _ = npm_ci.captureStdOut(.{});

        const run_e2e = b.addSystemCommand(&.{"node"});
        run_e2e.setName("e2e git-issue mcp");
        run_e2e.addFileArg(script);
        run_e2e.addArtifactArg(exe);
        run_e2e.addArg(version);
        run_e2e.has_side_effects = true;
        run_e2e.step.dependOn(&npm_ci.step);
        e2e_step.dependOn(&run_e2e.step);

        // Two servers on one repository, and the command line: live updates.
        const live_mcp = b.addSystemCommand(&.{"node"});
        live_mcp.setName("e2e live updates, git-issue mcp");
        const live_script = b.path("test/e2e/live_mcp.test.mjs");
        live_mcp.addFileArg(files.addCopyFile(live_script, "live_mcp.test.mjs"));
        live_mcp.addArtifactArg(exe);
        live_mcp.has_side_effects = true;
        live_mcp.step.dependOn(&npm_ci.step);
        e2e_step.dependOn(&live_mcp.step);

        // A server in each of two linked worktrees, writing at once.
        const worktrees_mcp = b.addSystemCommand(&.{"node"});
        worktrees_mcp.setName("e2e live updates across worktrees, git-issue mcp");
        const worktrees_script = b.path("test/e2e/worktrees_mcp.test.mjs");
        worktrees_mcp.addFileArg(files.addCopyFile(worktrees_script, "worktrees_mcp.test.mjs"));
        worktrees_mcp.addArtifactArg(exe);
        worktrees_mcp.has_side_effects = true;
        worktrees_mcp.step.dependOn(&npm_ci.step);
        e2e_step.dependOn(&worktrees_mcp.step);
    } else {
        e2e_step.dependOn(&b.addFail("zig build e2e needs the MCP server: drop -Dminimal").step);
    }

    // Two TUIs on pseudo-terminals, the command line and an MCP server:
    // live updates in the TUI (test/live_tui.zig). POSIX hosts only.
    const tui_e2e_step = b.step(
        "test-tui-e2e",
        "Run the TUI's end-to-end tests on pseudo-terminals",
    );
    if (extras.tui != null and extras.mcp != null and b.graph.host.result.os.tag != .windows) {
        if (b.lazyDependency("vaxis", .{ .target = b.graph.host, .optimize = .Debug })) |vaxis| {
            const tty_exec = b.addExecutable(.{
                .name = "tty-exec",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/tui_e2e/tty_exec.zig"),
                    .target = b.graph.host,
                    .optimize = .Debug,
                    .link_libc = true,
                }),
            });
            const opts = b.addOptions();
            opts.addOptionPath("git_issue_exe", exe.getEmittedBin());
            opts.addOptionPath("tty_exec", tty_exec.getEmittedBin());
            opts.addOptionPath("lazygit_doc", b.path("docs/lazygit.md"));
            const t = b.addTest(.{
                .name = "live_tui",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/live_tui.zig"),
                    .target = b.graph.host,
                    .optimize = .Debug,
                    .link_libc = true,
                    .imports = &.{
                        .{ .name = "paths", .module = opts.createModule() },
                        .{ .name = "vaxis", .module = vaxis.module("vaxis") },
                    },
                }),
            });
            const run_t = b.addRunArtifact(t);
            run_t.has_side_effects = true;
            tui_e2e_step.dependOn(&run_t.step);
            e2e_step.dependOn(&run_t.step);
        }
    } else {
        const fail = b.addFail(
            "zig build test-tui-e2e needs the TUI, the MCP server and a POSIX host",
        );
        tui_e2e_step.dependOn(&fail.step);
    }

    {
        const t = b.addTest(.{
            .name = "backend_git",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/backend_git.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "issuez", .module = issuez }},
            }),
            .test_runner = shardRunner(b),
        });
        addShards(b, t, 4, test_step);
    }
    {
        const t = b.addTest(.{
            .name = "trailers_git",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/trailers_git.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "issuez", .module = issuez }},
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    {
        const opts = b.addOptions();
        opts.addOptionPath("git_issue_exe", exe.getEmittedBin());
        const t = b.addTest(.{
            .name = "cli_git",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/cli_git.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "paths", .module = opts.createModule() }},
            }),
            .test_runner = shardRunner(b),
        });
        addShards(b, t, 8, test_step);
    }

    // A smoke run: the same cases every time, so it catches regressions.
    // `ci` adds a long run on a fresh seed, which finds new bugs.
    const fuzz_run = b.addRunArtifact(fuzz_exe);
    fuzz_run.addArgs(&.{ "--seed", "20261018", "--iterations", "300" });
    fuzz_run.expectExitCode(0);
    fuzz_run.expectStdErrMatch("300 cases passed");
    test_step.dependOn(&fuzz_run.step);

    const bindings_step = addCapi(b, target, optimize, test_step, exe, version);
    const go_e2e = bindings_step.go_e2e;

    // Budget 2 s, on ReleaseSafe builds whatever -Doptimize says: that is
    // what users run, in both flavors. The whole of it has to be ReleaseSafe,
    // the library too. Most of the time is spent in git.
    const release_issuez = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &.{versionImport(b, zon_version)},
    });
    const release_cli: Cli = .init(b, target, .ReleaseSafe, release_issuez);
    const release_extras = release_cli.parts(.{ .tui = tui, .mcp = mcp });
    const all_perf_exes = [_]*std.Build.Step.Compile{
        release_cli.exe("git-issue", "src/cli/main.zig", .ReleaseSafe, .{}),
        release_cli.exe("git-issue", "src/cli/main.zig", .ReleaseSafe, release_extras),
    };
    // -Dminimal has only the one flavor.
    const perf_exes = all_perf_exes[0..if (tui or mcp) 2 else 1];
    const perf_runner = b.addExecutable(.{
        .name = "perf-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/perf_smoke.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    // One after the other, so the two do not share the CPU.
    const addPerfRuns = struct {
        fn add(
            builder: *std.Build,
            runner: *std.Build.Step.Compile,
            exes: []const *std.Build.Step.Compile,
            args: ?[]const []const u8,
            after: ?*std.Build.Step,
            step: *std.Build.Step,
        ) void {
            var previous = after;
            for (exes) |perf_exe| {
                const run = builder.addRunArtifact(runner);
                run.addArtifactArg(perf_exe);
                if (args) |a| run.addArgs(a);
                run.stdio = .inherit;
                if (previous) |p| run.step.dependOn(p);
                step.dependOn(&run.step);
                previous = &run.step;
            }
        }
    }.add;
    addPerfRuns(
        b,
        perf_runner,
        perf_exes,
        b.args,
        null,
        b.step("test-perf", "Time `ls -a` over 10 000 issues against the 2 s budget"),
    );

    // What CI runs, so `zig build ci -Dseed=<run id>` reproduces a CI run:
    // `test`, long fuzz and trailer runs on the seed, interop, upstream's
    // suite, and perf.
    const ci_step = b.step("ci", "Run what CI runs (-Dseed=<n> for its fuzz and trailer runs)");
    {
        const seed = b.fmt("{d}", .{b.option(u64, "seed", "Seed of the ci runs") orelse 20261018});
        ci_step.dependOn(test_step);
        ci_step.dependOn(bindings_step.step);
        if (extras.mcp != null) ci_step.dependOn(e2e_step);

        const long_fuzz = b.addRunArtifact(fuzz_exe);
        long_fuzz.addArgs(&.{ "--seed", seed, "--iterations", "5000" });
        long_fuzz.expectExitCode(0);
        long_fuzz.expectStdErrMatch("5000 cases passed");
        ci_step.dependOn(&long_fuzz.step);

        const trailers = b.addTest(.{
            .name = "trailers_git",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/trailers_git.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "issuez", .module = issuez }},
            }),
        });
        const long_trailers = b.addRunArtifact(trailers);
        long_trailers.setEnvironmentVariable("ISSUEZ_TRAILER_CASES", "5000");
        long_trailers.setEnvironmentVariable("ISSUEZ_TRAILER_SEED", seed);
        ci_step.dependOn(&long_trailers.step);

        // After the long fuzz run, so the two do not share the CPU.
        addPerfRuns(b, perf_runner, perf_exes, null, &long_fuzz.step, ci_step);
    }

    // The simulator examples need no git and must print exactly their
    // snapshot. Examples that need a repository get one from a test.
    const examples_step = b.step("examples", "Build the library usage examples");
    const update_snapshots = b.addUpdateSourceFiles();
    b.step("update-snapshots", "Rewrite examples/*.out from the examples' current output")
        .dependOn(&update_snapshots.step);
    const Example = struct {
        name: []const u8,
        root: []const u8,
        snapshot: ?[]const u8 = null,
        test_root: ?[]const u8 = null,
    };
    const examples = [_]Example{
        .{
            .name = "quickstart",
            .root = "examples/quickstart.zig",
            .snapshot = "examples/quickstart.out",
        },
        .{ .name = "sync", .root = "examples/sync.zig", .snapshot = "examples/sync.out" },
        .{
            .name = "attachments",
            .root = "examples/attachments.zig",
            .snapshot = "examples/attachments.out",
        },
        .{
            .name = "custom-backend",
            .root = "examples/custom_backend.zig",
            .snapshot = "examples/custom_backend.out",
        },
        .{
            .name = "real-repo",
            .root = "examples/real_repo.zig",
            .test_root = "test/example_real_repo.zig",
        },
    };
    // examples/ isn't part of the package, so only define the steps when
    // building this repository.
    if (isRootPackage(b) and hasPath(b, "examples")) {
        inline for (examples) |e| {
            const example = b.addExecutable(.{
                .name = "example-" ++ e.name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(e.root),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "issuez", .module = issuez }},
                }),
            });
            examples_step.dependOn(&b.addInstallArtifact(example, .{}).step);

            const run_example = b.addRunArtifact(example);
            if (b.args) |args| run_example.addArgs(args);
            b.step("example-" ++ e.name, "Run " ++ e.root).dependOn(&run_example.step);

            if (e.snapshot) |snapshot| {
                const check = b.addRunArtifact(example);
                check.expectExitCode(0);
                // Read at configure time: examples/ isn't in the package and
                // build.zig must still compile for dependents.
                check.expectStdOutEqual(readSnapshot(b, snapshot));
                test_step.dependOn(&check.step);

                const capture = b.addRunArtifact(example);
                capture.expectExitCode(0);
                update_snapshots.addCopyFileToSource(capture.captureStdOut(.{}), snapshot);
            }
            if (e.test_root) |test_root| {
                const opts = b.addOptions();
                opts.addOptionPath("example_exe", example.getEmittedBin());
                const t = b.addTest(.{
                    .name = "example-" ++ e.name,
                    .root_module = b.createModule(.{
                        .root_source_file = b.path(test_root),
                        .target = target,
                        .optimize = optimize,
                        .imports = &.{
                            .{ .name = "issuez", .module = issuez },
                            .{ .name = "paths", .module = opts.createModule() },
                        },
                    }),
                });
                test_step.dependOn(&b.addRunArtifact(t).step);
            }
        }
    }

    const interop_step = b.step(
        "test-interop",
        "Cross-tool tests against upstream git-native-issue",
    );
    const suite_step = b.step("test-upstream-suite", "Run upstream's t/*.sh against our git-issue");
    // Only here, so dependents never fetch the GPL upstream.
    if (isRootPackage(b)) {
        if (b.lazyDependency("git_native_issue", .{})) |upstream| {
            const opts = b.addOptions();
            opts.addOptionPath("upstream_bin", upstream.path("bin"));
            go_e2e.addDirectoryArg(upstream.path("bin"));
            opts.addOptionPath("git_issue_exe", exe.getEmittedBin());
            const interop = b.addTest(.{
                .name = "interop",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/interop.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "issuez", .module = issuez },
                        .{ .name = "oracle", .module = oracle },
                        .{ .name = "paths", .module = opts.createModule() },
                    },
                }),
                .test_runner = shardRunner(b),
            });
            addShards(b, interop, 8, interop_step);
            ci_step.dependOn(interop_step);

            const suite = b.addExecutable(.{
                .name = "upstream-suite",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/upstream_suite.zig"),
                    .target = b.graph.host,
                    .optimize = .Debug,
                }),
            });
            // Alone, the report is what you ran it for. In `ci` it only shows
            // on a failure, so the suite runs alongside everything else.
            const run_suite = b.addRunArtifact(suite);
            run_suite.stdio = .inherit;
            const quiet_suite = addQuietCommand(b, &.{});
            quiet_suite.setName("run upstream-suite");
            quiet_suite.addArtifactArg(suite);
            for ([_]*std.Build.Step.Run{ run_suite, quiet_suite }) |r| {
                r.addDirectoryArg(upstream.path(""));
                r.addArtifactArg(exe);
                r.addFileArg(b.path("test/upstream-expected.txt"));
                r.addFileArg(b.path("test/upstream-allowlist.txt"));
            }
            suite_step.dependOn(&run_suite.step);
            ci_step.dependOn(&quiet_suite.step);
        }
    }
}

/// In the order the release page lists them: by name.
const release_targets = [_]std.Target.Query{
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

const Flavor = struct { name: []const u8, full: bool };

const release_flavors = [_]Flavor{
    .{ .name = "full", .full = true },
    .{ .name = "minimal", .full = false },
};

/// `git-native-issuez-<version>-<flavor>-<arch>-<os>`, one per flavor and
/// target, cross-compiled (ReleaseSafe, stripped): `bin/` with the
/// `git-issue-<command>` entry points (not on Windows), the shell completions and man pages
/// (from a build that runs here), and LICENSE, THIRD_PARTY_LICENSES, README.md
/// and CHANGELOG.md in `share/doc/git-native-issuez/` (at the top on Windows). A `.zip` for
/// Windows, `.tar.gz` otherwise, all in `zig-out/release/` with their
/// `SHA256SUMS`. GitHub lists release assets by name, so the full flavor
/// comes first, and the C library's `libissuez-*` come after the programs.
/// Needs `sh`, `tar` and `zip`.
fn addRelease(b: *std.Build, step: *std.Build.Step) void {
    const version = zon_version;
    const sums = b.addSystemCommand(&.{ "sh", "-c", sums_script, "sh" });
    const sums_file = sums.addOutputFileArg("SHA256SUMS");
    step.dependOn(&b.addInstallFileWithDir(sums_file, release_dir, "SHA256SUMS").step);

    for (release_flavors) |flavor| {
        var exes: [release_targets.len]*std.Build.Step.Compile = undefined;
        var host_exe: ?*std.Build.Step.Compile = null;
        for (release_targets, &exes) |query, *exe| {
            exe.* = releaseExe(b, b.resolveTargetQuery(query), flavor);
            if (host_exe == null and runsOnHost(b, exe.*)) host_exe = exe.*;
        }
        // Completions and man pages are the same for every target.
        const gen = host_exe orelse releaseExe(b, b.graph.host, flavor);
        const scripts = completionScripts(b, gen);
        const pages = manPages(b, gen);

        for (exes) |exe| {
            const t = exe.rootModuleTarget();
            const windows = t.os.tag == .windows;
            const name = b.fmt("git-native-issuez-{s}-{s}-{t}-{t}", .{
                version, flavor.name, t.cpu.arch, t.os.tag,
            });
            const archive_name = b.fmt("{s}.{s}", .{ name, if (windows) "zip" else "tar.gz" });

            const pack = b.addSystemCommand(&.{ "sh", "-c", pack_script, "sh" });
            // Keeps macOS's tar from adding ._ files with extended attributes.
            pack.setEnvironmentVariable("COPYFILE_DISABLE", "1");
            const archive = pack.addOutputFileArg(archive_name);
            _ = pack.addOutputDirectoryArg("stage");
            pack.addArg(name);
            const bin = if (windows) "bin/git-issue.exe" else "bin/git-issue";
            pack.addArgs(&.{ "x", bin });
            pack.addFileArg(exe.getEmittedBin());
            // Zip has no symlinks, and a copy per command would make the
            // archive ten times larger: Windows gets `git issue <command>`.
            if (!windows) for (entry_points.names) |entry| {
                pack.addArgs(&.{ "l", b.fmt("bin/git-issue-{s}", .{entry}), "git-issue" });
            };
            // Under share/ like the rest, so unpacking into a prefix
            // doesn't put them at its top. Windows has no share/.
            const doc_dir = if (windows) "" else "share/doc/git-native-issuez/";
            const docs = [_][]const u8{
                "LICENSE",
                "THIRD_PARTY_LICENSES",
                "README.md",
                "CHANGELOG.md",
            };
            for (docs) |doc| {
                pack.addArgs(&.{ "f", b.fmt("{s}{s}", .{ doc_dir, doc }) });
                pack.addFileArg(b.path(doc));
            }
            if (!windows) {
                for (completionFiles(b)) |f| {
                    pack.addArgs(&.{ "f", f.path });
                    pack.addFileArg(scripts.of(f.shell));
                }
                pack.addArgs(&.{ "d", man_dir });
                pack.addDirectoryArg(pages);
            }

            sums.addFileArg(archive);
            step.dependOn(&b.addInstallFileWithDir(archive, release_dir, archive_name).step);
        }
    }

    // `libissuez-<version>-<arch>-<os>[-<abi>]`: the C library, its header and
    // its API description.
    for (lib_targets) |lib_target| {
        const resolved = b.resolveTargetQuery(lib_target.query);
        const t = resolved.result;
        const name = if (t.os.tag == .linux)
            b.fmt("libissuez-{s}-{t}-{t}-{t}", .{ version, t.cpu.arch, t.os.tag, t.abi })
        else
            b.fmt("libissuez-{s}-{t}-{t}", .{ version, t.cpu.arch, t.os.tag });
        const archive_name = b.fmt("{s}.tar.gz", .{name});

        const pack = b.addSystemCommand(&.{ "sh", "-c", pack_script, "sh" });
        pack.setEnvironmentVariable("COPYFILE_DISABLE", "1");
        const archive = pack.addOutputFileArg(archive_name);
        _ = pack.addOutputDirectoryArg("stage");
        pack.addArg(name);
        pack.addArgs(&.{ "f", "lib/libissuez.a" });
        pack.addFileArg(hostArchive(b, capiLib(b, resolved, .ReleaseSafe, false, version)));
        for ([_]struct { []const u8, []const u8 }{
            // The tests check that these two are what the generator writes.
            .{ "include/issuez.h", committed_header },
            .{ "share/issuez/issuez-api.json", committed_api_json },
            .{ "share/doc/libissuez/LICENSE", "LICENSE" },
            .{ "share/doc/libissuez/THIRD_PARTY_LICENSES", "THIRD_PARTY_LICENSES" },
            .{ "share/doc/libissuez/CHANGELOG.md", "CHANGELOG.md" },
        }) |file| {
            pack.addArgs(&.{ "f", file[0] });
            pack.addFileArg(b.path(file[1]));
        }

        sums.addFileArg(archive);
        step.dependOn(&b.addInstallFileWithDir(archive, release_dir, archive_name).step);
    }
}

const release_dir: std.Build.InstallDir = .{ .custom = "release" };

fn releaseExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    flavor: Flavor,
) *std.Build.Step.Compile {
    const issuez = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        // The tag's version: release.yml checks it is build.zig.zon's.
        .imports = &.{versionImport(b, zon_version)},
    });
    const cli: Cli = .init(b, target, .ReleaseSafe, issuez);
    const exe = cli.exe("git-issue", "src/cli/main.zig", .ReleaseSafe, cli.parts(.{
        .tui = flavor.full,
        .mcp = flavor.full,
    }));
    // Debug info would make the Linux binaries five times larger; macOS
    // builds go without it anyway. Stack traces show addresses instead.
    exe.root_module.strip = true;
    return exe;
}

/// `sh -c pack_script sh <archive> <stage dir> <name> [<kind> <path> <source>]...`
/// puts each source at `<name>/<path>` in the stage directory, then
/// archives `<name>` by the archive's extension. Kinds: `f` a file, `x`
/// an executable, `d` a directory's contents, `l` a symlink to `<source>`.
const pack_script =
    \\set -eu
    \\archive="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    \\stage=$2 name=$3
    \\shift 3
    \\rm -rf "${stage:?}/$name"
    \\while [ $# -gt 0 ]; do
    \\  dest="$stage/$name/$2"
    \\  mkdir -p "$(dirname "$dest")"
    \\  case $1 in
    \\    f) cp "$3" "$dest" && chmod 644 "$dest" ;;
    \\    x) cp "$3" "$dest" && chmod 755 "$dest" ;;
    \\    d) mkdir -p "$dest" && cp -R "$3/." "$dest" ;;
    \\    l) ln -s "$3" "$dest" ;;
    \\  esac
    \\  shift 3
    \\done
    \\cd "$stage"
    \\rm -f "$archive"
    \\case $archive in
    \\  *.zip) zip -qrX "$archive" "$name" ;;
    \\  *) tar -czf "$archive" "$name" ;;
    \\esac
;

/// `sh -c sums_script sh <output> <file>...`: `sha256sum`'s format, by
/// file name.
const sums_script =
    \\set -eu
    \\out=$1
    \\shift
    \\if command -v sha256sum >/dev/null; then sum="sha256sum"; else sum="shasum -a 256"; fi
    \\: > "$out"
    \\for f; do (cd "$(dirname "$f")" && $sum "$(basename "$f")") >> "$out"; done
;

/// Relative symlinks to `git-issue`, copies on Windows.
fn installEntryPoints(b: *std.Build, exe: *std.Build.Step.Compile) void {
    if (exe.rootModuleTarget().os.tag == .windows) {
        for (entry_points.names) |name| {
            const copy = b.addInstallArtifact(exe, .{
                .dest_sub_path = b.fmt("git-issue-{s}.exe", .{name}),
                .pdb_dir = .disabled,
                .implib_dir = .disabled,
            });
            b.getInstallStep().dependOn(&copy.step);
        }
        return;
    }
    const links = b.allocator.create(std.Build.Step) catch @panic("OOM");
    links.* = .init(.{
        .id = .custom,
        .name = "install git-issue-<sub> links",
        .owner = b,
        .makeFn = makeEntryPointLinks,
    });
    links.dependOn(&b.addInstallArtifact(exe, .{}).step);
    b.getInstallStep().dependOn(links);
}

fn makeEntryPointLinks(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = options;
    const b = step.owner;
    const io = b.graph.io;
    const bin = b.getInstallPath(.bin, "");
    for (entry_points.names) |name| {
        const link = b.pathJoin(&.{ bin, b.fmt("git-issue-{s}", .{name}) });
        std.Io.Dir.cwd().symLinkAtomic(io, "git-issue", link, .{}) catch |err|
            return step.fail("unable to symlink {s} -> git-issue: {t}", .{ link, err });
    }
}

/// Skipped for cross builds, where the binary can't run to print them.
fn installCompletions(b: *std.Build, exe: *std.Build.Step.Compile) void {
    if (!runsOnHost(b, exe)) return;
    const scripts = completionScripts(b, exe);
    for (completionFiles(b)) |f| b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        scripts.of(f.shell),
        .prefix,
        f.path,
    ).step);
}

/// Native builds only, like the completions.
fn installManPages(b: *std.Build, exe: *std.Build.Step.Compile) void {
    if (!runsOnHost(b, exe)) return;
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = manPages(b, exe),
        .install_dir = .prefix,
        .install_subdir = man_dir,
    }).step);
}

/// The `version` import of `src/root.zig`, which is `issuez.version`.
fn versionImport(b: *std.Build, version: []const u8) std.Build.Module.Import {
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    return .{ .name = "version", .module = options.createModule() };
}

/// `build.zig.zon`'s version, from git when building a checkout: just it
/// on the `v<version>` tag, `0.3.0-12-ga3e21cfa` twelve commits after the
/// tag, `0.3.0-ga3e21cfa` before there is one, each with `-dirty` for
/// uncommitted changes. Unchanged without git or a repository (an unpacked
/// source archive, a dependency).
fn describeVersion(b: *std.Build) []const u8 {
    if (!isRootPackage(b) or !hasPath(b, ".git")) return zon_version;
    const root = b.build_root.path orelse ".";
    const tag = "v" ++ zon_version;
    var code: u8 = undefined;
    if (b.runAllowFail(&.{
        "git", "-C", root, "describe", "--tags", "--long", "--dirty", "--abbrev=8", "--match", tag,
    }, &code, .ignore)) |out| {
        // v0.3.0-12-ga3e21cfa, or -0- on the tag itself.
        const rest = std.mem.trimEnd(u8, out, "\n")[tag.len..];
        if (std.mem.startsWith(u8, rest, "-0-g") and !std.mem.endsWith(u8, rest, "-dirty"))
            return zon_version;
        return b.fmt("{s}{s}", .{ zon_version, rest });
    } else |_| {}
    // No such tag (a shallow clone, or the version isn't tagged yet).
    const commit = b.runAllowFail(&.{
        "git", "-C", root, "describe", "--always", "--dirty", "--abbrev=8", "--exclude=*",
    }, &code, .ignore) catch return zon_version;
    return b.fmt("{s}-g{s}", .{ zon_version, std.mem.trimEnd(u8, commit, "\n") });
}

/// `zig build link` symlinks what `zig build` installs (git-issue, its
/// entry points, completions and man pages) into `-Dlink-prefix`, so the
/// next `zig build` updates what runs. A file already there is replaced.
/// `zig build unlink` removes the symlinks that point into this install
/// prefix and nothing else.
fn addLinkSteps(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const prefix = b.option(
        []const u8,
        "link-prefix",
        "Where `zig build link` puts its symlinks (default: ~/.local)",
    ) orelse if (b.graph.environ_map.get("HOME")) |home| b.pathJoin(&.{ home, ".local" }) else null;
    const link_step = b.step(
        "link",
        "Install, then symlink it into -Dlink-prefix (default: ~/.local)",
    );
    const unlink_step = b.step("unlink", "Remove the symlinks `zig build link` made");
    const problem: ?[]const u8 = if (exe.rootModuleTarget().os.tag == .windows)
        "zig build link has no Windows support: use zig build -p <prefix>"
    else if (!runsOnHost(b, exe))
        "zig build link needs a native build: drop -Dtarget"
    else if (prefix == null)
        "zig build link needs -Dlink-prefix: HOME is not set"
    else
        null;
    if (problem) |p| {
        link_step.dependOn(&b.addFail(p).step);
        unlink_step.dependOn(&b.addFail(p).step);
        return;
    }
    for ([_]struct { step: *std.Build.Step, remove: bool }{
        .{ .step = link_step, .remove = false },
        .{ .step = unlink_step, .remove = true },
    }) |s| {
        const links = b.allocator.create(Links) catch @panic("OOM");
        links.* = .{
            .step = .init(.{
                .id = .custom,
                .name = if (s.remove) "unlink from link prefix" else "link into link prefix",
                .owner = b,
                .makeFn = Links.make,
            }),
            .prefix = b.pathResolve(&.{ b.graph.cache.cwd, prefix.? }),
            .remove = s.remove,
        };
        if (!s.remove) links.step.dependOn(b.getInstallStep());
        s.step.dependOn(&links.step);
    }
}

const Links = struct {
    step: std.Build.Step,
    prefix: []const u8,
    remove: bool,

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const links: *Links = @fieldParentPtr("step", step);
        const b = step.owner;
        const io = b.graph.io;
        const cwd = std.Io.Dir.cwd();
        const installed = b.pathResolve(&.{ b.graph.cache.cwd, b.install_path });
        if (std.mem.eql(u8, installed, links.prefix))
            return step.fail("-Dlink-prefix is the install prefix ({s})", .{installed});

        var paths: std.ArrayList([]const u8) = .empty;
        try paths.append(b.allocator, "bin/git-issue");
        for (entry_points.names) |name|
            try paths.append(b.allocator, b.fmt("bin/git-issue-{s}", .{name}));
        for (completionFiles(b)) |f| try paths.append(b.allocator, f.path);
        // The pages the install made, or for unlink those in the link prefix.
        const pages_root = if (links.remove) links.prefix else installed;
        if (cwd.openDir(io, b.pathJoin(&.{ pages_root, man_dir }), .{ .iterate = true })) |dir| {
            var d = dir;
            defer d.close(io);
            var it = d.iterate();
            while (try it.next(io)) |entry| if (std.mem.startsWith(u8, entry.name, "git-issue"))
                try paths.append(b.allocator, b.fmt("{s}/{s}", .{ man_dir, entry.name }));
        } else |_| {}

        for (paths.items) |rel| {
            const target = b.pathJoin(&.{ installed, rel });
            const link = b.pathJoin(&.{ links.prefix, rel });
            if (links.remove) {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = cwd.readLink(io, link, &buf) catch continue;
                if (!std.mem.eql(u8, buf[0..n], target)) continue;
                cwd.deleteFile(io, link) catch |err|
                    return step.fail("unable to remove {s}: {t}", .{ link, err });
                continue;
            }
            cwd.createDirPath(io, std.fs.path.dirname(link).?) catch |err|
                return step.fail("unable to create the directory for {s}: {t}", .{ link, err });
            cwd.symLinkAtomic(io, target, link, .{}) catch |err|
                return step.fail("unable to symlink {s} -> {s}: {t}", .{ link, target, err });
        }
    }
};

const Shell = enum { bash, zsh, fish };

/// A completion script under the install prefix.
const CompletionFile = struct { shell: Shell, path: []const u8 };

/// bash-completion and fish look scripts up by command name, so every
/// entry point gets a copy. zsh's `#compdef` line covers them all.
fn completionFiles(b: *std.Build) []const CompletionFile {
    var files: std.ArrayList(CompletionFile) = .empty;
    const bash_dir = "share/bash-completion/completions";
    const fish_dir = "share/fish/vendor_completions.d";
    files.appendSlice(b.allocator, &.{
        .{ .shell = .bash, .path = bash_dir ++ "/git-issue" },
        .{ .shell = .zsh, .path = "share/zsh/site-functions/_git-issue" },
        .{ .shell = .fish, .path = fish_dir ++ "/git-issue.fish" },
    }) catch @panic("OOM");
    for (entry_points.names) |name| files.appendSlice(b.allocator, &.{
        .{ .shell = .bash, .path = b.fmt("{s}/git-issue-{s}", .{ bash_dir, name }) },
        .{ .shell = .fish, .path = b.fmt("{s}/git-issue-{s}.fish", .{ fish_dir, name }) },
    }) catch @panic("OOM");
    return files.items;
}

const CompletionScripts = struct {
    scripts: [3]std.Build.LazyPath,

    fn of(c: CompletionScripts, shell: Shell) std.Build.LazyPath {
        return c.scripts[@intFromEnum(shell)];
    }
};

/// What `exe completion <shell>` prints. `exe` must run on the host.
fn completionScripts(b: *std.Build, exe: *std.Build.Step.Compile) CompletionScripts {
    var out: CompletionScripts = undefined;
    for (std.enums.values(Shell), &out.scripts) |shell, *script| {
        const gen = b.addRunArtifact(exe);
        gen.addArgs(&.{ "completion", @tagName(shell) });
        gen.expectExitCode(0);
        script.* = gen.captureStdOut(.{});
    }
    return out;
}

const man_dir = "share/man/man1";

/// The man pages `exe` writes. `exe` must run on the host.
fn manPages(b: *std.Build, exe: *std.Build.Step.Compile) std.Build.LazyPath {
    const gen = b.addRunArtifact(exe);
    gen.addArg("__manpages");
    const pages = gen.addOutputDirectoryArg("man1");
    gen.expectExitCode(0);
    return pages;
}

fn runsOnHost(b: *std.Build, exe: *std.Build.Step.Compile) bool {
    const target = exe.rootModuleTarget();
    const host = b.graph.host.result;
    return target.os.tag == host.os.tag and target.cpu.arch == host.cpu.arch;
}

fn hasPath(b: *std.Build, path: []const u8) bool {
    b.build_root.handle.access(b.graph.io, path, .{}) catch return false;
    return true;
}

fn readSnapshot(b: *std.Build, path: []const u8) []const u8 {
    const limit: std.Io.Limit = .limited(1 << 20);
    return b.build_root.handle.readFileAlloc(b.graph.io, path, b.allocator, limit) catch |e|
        std.debug.panic("cannot read snapshot {s}: {t}", .{ path, e });
}

/// True when building this repository rather than using it as a dependency.
/// Git's repository-local variables (`git rev-parse --local-env-vars`),
/// which a git hook gets: `git commit -a` sets GIT_INDEX_FILE, a
/// worktree's hook GIT_DIR. Inherited, they'd point the tests' git at this
/// repository instead of their own. Gone from the environment every step
/// runs in.
fn forgetOuterRepository(b: *std.Build) void {
    for ([_][]const u8{
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG",             "GIT_CONFIG_PARAMETERS",
        "GIT_CONFIG_COUNT",                 "GIT_OBJECT_DIRECTORY",   "GIT_DIR",
        "GIT_WORK_TREE",                    "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
        "GIT_INDEX_FILE",                   "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE",
        "GIT_PREFIX",                       "GIT_SHALLOW_FILE",       "GIT_COMMON_DIR",
    }) |name| _ = b.graph.environ_map.swapRemove(name);
}

/// Every git the tests start, thousands of them, otherwise goes through
/// Apple's /usr/bin/git, which spends 5 ms finding the real one: a third of
/// the time of the suites that use git the most.
fn skipGitStub(b: *std.Build) void {
    if (b.graph.host.result.os.tag != .macos) return;
    var code: u8 = undefined;
    const out = b.runAllowFail(&.{ "git", "--exec-path" }, &code, .ignore) catch return;
    const dir = std.mem.trimEnd(u8, out, "\n");
    const path = b.graph.environ_map.get("PATH") orelse return;
    b.graph.environ_map.put("PATH", b.fmt("{s}:{s}", .{ dir, path })) catch @panic("OOM");
}

/// A test binary's tests run one after the other, and these suites spend
/// their time in git, so `shards` runs of it take a slice of the tests each.
fn shardRunner(b: *std.Build) std.Build.Step.Compile.TestRunner {
    return .{ .path = b.path("tools/shard_test_runner.zig"), .mode = .server };
}

fn addShards(
    b: *std.Build,
    t: *std.Build.Step.Compile,
    shards: u32,
    step: *std.Build.Step,
) void {
    for (0..shards) |i| {
        const run = b.addRunArtifact(t);
        run.setName(b.fmt("run test {s} {d}/{d}", .{ t.name, i + 1, shards }));
        run.addArg(b.fmt("--shard={d}/{d}", .{ i, shards }));
        step.dependOn(&run.step);
    }
}

/// `argv` with its output kept back unless it fails. A step that inherits
/// stdio holds the build's stderr lock from start to exit, so those steps
/// run one at a time, whatever else there is to do.
fn addQuietCommand(b: *std.Build, argv: []const []const u8) *std.Build.Step.Run {
    const quiet =
        \\log=$(mktemp)
        \\"$@" >"$log" 2>&1
        \\rc=$?
        \\[ "$rc" -eq 0 ] || cat "$log" >&2
        \\rm -f "$log"
        \\exit "$rc"
    ;
    const run = b.addSystemCommand(&.{ "sh", "-c", quiet, "sh" });
    run.addArgs(argv);
    run.has_side_effects = true;
    run.expectExitCode(0);
    return run;
}

fn isRootPackage(b: *std.Build) bool {
    return b.pkg_hash.len == 0;
}

/// The optional parts of `git-issue`. Null leaves one out.
const Extras = struct {
    tui: ?*std.Build.Module = null,
    mcp: ?*std.Build.Module = null,
    /// The repository watcher both use.
    watch: ?*std.Build.Module = null,
};

/// The modules `git-issue` is built from, for one target.
const Cli = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    issuez: *std.Build.Module,
    oracle: *std.Build.Module,
    mcp_help: *std.Build.Module,

    fn init(
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        issuez: *std.Build.Module,
    ) Cli {
        return .{
            .b = b,
            .target = target,
            .optimize = optimize,
            .issuez = issuez,
            .oracle = b.createModule(.{
                .root_source_file = b.path("src/oracle/root.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "issuez", .module = issuez }},
            }),
            .mcp_help = b.createModule(.{ .root_source_file = b.path("src/mcp/help.zig") }),
        };
    }

    fn dependencyArgs(cli: Cli) struct {
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    } {
        return .{ .target = cli.target, .optimize = cli.optimize };
    }

    /// The optional parts asked for, each null until its lazy dependency
    /// is fetched.
    fn parts(cli: Cli, want: struct { tui: bool, mcp: bool }) Extras {
        const b = cli.b;
        // Live updates, for both.
        const watch_module: ?*std.Build.Module = if (!want.tui and !want.mcp) null else blk: {
            const nightwatch = b.lazyDependency("nightwatch", cli.dependencyArgs()) orelse
                break :blk null;
            break :blk b.createModule(.{
                .root_source_file = b.path("src/watch/RepoWatcher.zig"),
                .target = cli.target,
                .optimize = cli.optimize,
                .imports = &.{.{ .name = "nightwatch", .module = nightwatch.module("nightwatch") }},
            });
        };
        const tui_module: ?*std.Build.Module = if (!want.tui) null else blk: {
            const vaxis = b.lazyDependency("vaxis", cli.dependencyArgs()) orelse break :blk null;
            break :blk b.createModule(.{
                .root_source_file = b.path("src/tui/main.zig"),
                .target = cli.target,
                .optimize = cli.optimize,
                .imports = &.{
                    .{ .name = "issuez", .module = cli.issuez },
                    .{ .name = "vaxis", .module = vaxis.module("vaxis") },
                    .{ .name = "RepoWatcher", .module = watch_module orelse break :blk null },
                },
            });
        };
        const mcp_module: ?*std.Build.Module = if (!want.mcp) null else blk: {
            const blitzmcp = b.lazyDependency("blitzmcp", cli.dependencyArgs()) orelse
                break :blk null;
            break :blk b.createModule(.{
                .root_source_file = b.path("src/mcp/main.zig"),
                .target = cli.target,
                .optimize = cli.optimize,
                .imports = &.{
                    .{ .name = "issuez", .module = cli.issuez },
                    .{ .name = "blitzmcp", .module = blitzmcp.module("blitzmcp") },
                    .{ .name = "mcp_help", .module = cli.mcp_help },
                    .{ .name = "RepoWatcher", .module = watch_module orelse break :blk null },
                },
            });
        };
        return .{ .tui = tui_module, .mcp = mcp_module, .watch = watch_module };
    }

    fn module(
        cli: Cli,
        root: []const u8,
        optimize: std.builtin.OptimizeMode,
        extras: Extras,
    ) *std.Build.Module {
        const b = cli.b;
        const options = b.addOptions();
        options.addOption(bool, "tui", extras.tui != null);
        options.addOption(bool, "mcp", extras.mcp != null);
        const m = b.createModule(.{
            .root_source_file = b.path(root),
            .target = cli.target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "issuez", .module = cli.issuez },
                .{ .name = "oracle", .module = cli.oracle },
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "mcp_help", .module = cli.mcp_help },
            },
        });
        if (extras.tui) |t| m.addImport("tui", t);
        if (extras.mcp) |t| m.addImport("mcp", t);
        return m;
    }

    fn exe(
        cli: Cli,
        name: []const u8,
        root: []const u8,
        optimize: std.builtin.OptimizeMode,
        extras: Extras,
    ) *std.Build.Step.Compile {
        return cli.b.addExecutable(.{
            .name = name,
            .root_module = cli.module(root, optimize, extras),
        });
    }
};

// ─── The C API and the Go binding ──────────────────────────────────────

/// Where the Go binding lives and what it commits: the header and the API
/// description. Its archives are build outputs; releases have them as
/// `libissuez-*`.
const go_pkg = "bindings/go/issuez";
const committed_header = go_pkg ++ "/include/issuez.h";
const committed_api_json = "docs/issuez-api.json";

/// The C library's platforms, in the Go binding's terms: GOOS_GOARCH[_musl]
/// and the Zig target.
const lib_targets = [_]struct { dir: []const u8, query: std.Target.Query }{
    .{
        .dir = "darwin_arm64",
        .query = .{
            .cpu_arch = .aarch64,
            .os_tag = .macos,
            .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } },
        },
    },
    .{
        .dir = "darwin_amd64",
        .query = .{
            .cpu_arch = .x86_64,
            .os_tag = .macos,
            .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } },
        },
    },
    .{
        .dir = "linux_amd64",
        .query = .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            .abi = .gnu,
            .glibc_version = .{ .major = 2, .minor = 28, .patch = 0 },
        },
    },
    .{
        .dir = "linux_amd64_musl",
        .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    },
    .{
        .dir = "linux_arm64",
        .query = .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .gnu,
            .glibc_version = .{ .major = 2, .minor = 28, .patch = 0 },
        },
    },
    .{
        .dir = "linux_arm64_musl",
        .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    },
    // ARMv6 code runs on v7 too, so one archive serves GOARM=6 and 7.
    .{
        .dir = "linux_arm",
        .query = .{
            .cpu_arch = .arm,
            .os_tag = .linux,
            .abi = .gnueabihf,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm1176jzf_s },
            .glibc_version = .{ .major = 2, .minor = 28, .patch = 0 },
        },
    },
    .{
        .dir = "linux_arm_musl",
        .query = .{
            .cpu_arch = .arm,
            .os_tag = .linux,
            .abi = .musleabihf,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm1176jzf_s },
        },
    },
};

fn capiLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Counts live allocations and exports `issuez__debug_live_allocations`.
    debug: bool,
    /// `issuez_version()`.
    version: []const u8,
) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption(bool, "debug", debug);
    // Live updates, when nightwatch is fetched (issuez_watch_start).
    const nightwatch = b.lazyDependency("nightwatch", .{ .target = target, .optimize = optimize });
    options.addOption(bool, "watch", nightwatch != null);
    const issuez = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
        .imports = &.{versionImport(b, version)},
    });
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "issuez",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
            .imports = &.{
                .{ .name = "issuez", .module = issuez },
                .{ .name = "capi_options", .module = options.createModule() },
            },
        }),
    });
    if (nightwatch) |nw| lib.root_module.addImport("RepoWatcher", b.createModule(.{
        .root_source_file = b.path("src/watch/RepoWatcher.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .imports = &.{.{ .name = "nightwatch", .module = nw.module("nightwatch") }},
    }));
    // The host links it with its own toolchain, which has no Zig runtime.
    lib.bundle_compiler_rt = true;
    return lib;
}

/// The archive repacked by `zig ar` (llvm-ar) in the target's format:
/// Apple's linker refuses the archives Zig writes itself (members not
/// 8-byte aligned).
fn hostArchive(b: *std.Build, lib: *std.Build.Step.Compile) std.Build.LazyPath {
    const format = if (lib.rootModuleTarget().os.tag.isDarwin()) "darwin" else "gnu";
    const run = b.addSystemCommand(&.{ "sh", "-c", repack_script, "sh", b.graph.zig_exe, format });
    run.addFileArg(lib.getEmittedBin());
    const out = run.addOutputFileArg("libissuez.a");
    run.setName(b.fmt("repack libissuez.a ({s})", .{format}));
    return out;
}

const repack_script =
    \\set -e
    \\zig="$1"; format="$2"
    \\abs() { (cd "$(dirname "$1")" && printf '%s/%s' "$(pwd)" "$(basename "$1")"); }
    \\lib=$(abs "$3"); out=$(abs "$4")
    \\work=$(mktemp -d)
    \\trap 'rm -rf "$work"' EXIT
    \\cd "$work"
    \\"$zig" ar x "$lib"
    \\chmod u+rw ./*.o
    \\rm -f "$out"
    \\"$zig" ar rcs --format="$format" "$out" ./*.o
;

/// A C file compiled with the system compiler and linked with the archive.
fn compileC(
    b: *std.Build,
    source: []const u8,
    header: std.Build.LazyPath,
    archive: std.Build.LazyPath,
    flags: []const []const u8,
) std.Build.LazyPath {
    const cc = b.addSystemCommand(&.{ "cc", "-std=c11", "-Wall", "-Wextra", "-Werror" });
    cc.addArgs(flags);
    // The archive is built for the exact host version; linking for an
    // older one makes ld warn, and a step that writes to stderr fails.
    if (b.graph.host.result.os.tag == .macos) {
        const v = b.graph.host.result.os.version_range.semver.min;
        cc.addArg(b.fmt("-mmacosx-version-min={d}.{d}.{d}", .{ v.major, v.minor, v.patch }));
    }
    cc.addPrefixedDirectoryArg("-I", header.dirname());
    cc.addFileArg(b.path(source));
    cc.addFileArg(archive);
    cc.addArgs(&.{ "-lpthread", "-o" });
    return cc.addOutputFileArg(std.fs.path.stem(source));
}

/// Sets up a command that runs the Go toolchain on the binding.
fn goCommand(b: *std.Build, run: *std.Build.Step.Run, committed: *std.Build.Step) void {
    run.setCwd(b.path("bindings/go"));
    run.setEnvironmentVariable("CGO_ENABLED", "1");
    // A go.work above this checkout (an embedder's) isn't ours.
    run.setEnvironmentVariable("GOWORK", "off");
    run.step.dependOn(committed);
}

fn addCapi(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    /// The CLI the Go end-to-end tests drive.
    exe: *std.Build.Step.Compile,
    /// What the archives that get installed report.
    version: []const u8,
) struct { go_e2e: *std.Build.Step.Run, step: *std.Build.Step } {
    const gen = b.addExecutable(.{
        .name = "issuez-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi/gen.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            // The header is committed, so it can't have git's version.
            .imports = &.{.{
                .name = "issuez",
                .module = b.createModule(.{
                    .root_source_file = b.path("src/root.zig"),
                    .imports = &.{versionImport(b, zon_version)},
                }),
            }},
        }),
    });
    const run_gen = b.addRunArtifact(gen);
    const header = run_gen.addOutputFileArg("issuez.h");
    const api_json = run_gen.addOutputFileArg("issuez-api.json");

    const lib = capiLib(b, target, optimize, false, zon_version);
    const archive = hostArchive(b, lib);
    const capi_step = b.step("capi", "Build libissuez.a with its header and API description");
    capi_step.dependOn(&b.addInstallFileWithDir(
        hostArchive(b, capiLib(b, target, optimize, false, version)),
        .lib,
        "libissuez.a",
    ).step);
    capi_step.dependOn(&b.addInstallFileWithDir(header, .header, "issuez.h").step);
    capi_step.dependOn(&b.addInstallFileWithDir(
        api_json,
        .{ .custom = "share/issuez" },
        "issuez-api.json",
    ).step);

    const update = b.addUpdateSourceFiles();
    update.addCopyFileToSource(header, committed_header);
    update.addCopyFileToSource(api_json, committed_api_json);
    b.step("capi-header", "Rewrite the committed issuez.h and issuez-api.json")
        .dependOn(&update.step);

    // The committed copies must be what the generator writes now.
    for ([_]struct { std.Build.LazyPath, []const u8 }{
        .{ header, committed_header },
        .{ api_json, committed_api_json },
    }) |pair| {
        const cmp = b.addSystemCommand(&.{ "cmp", "-s" });
        cmp.addFileArg(pair[0]);
        cmp.addFileArg(b.path(pair[1]));
        cmp.setName(b.fmt("{s} is current (zig build capi-header)", .{pair[1]}));
        cmp.expectExitCode(0);
        test_step.dependOn(&cmp.step);
    }

    const unit = b.addTest(.{ .name = "capi", .root_module = lib.root_module });
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // The C API through its header, called from Zig like an embedder would.
    // The library counts its live allocations.
    const debug_lib = capiLib(b, target, .Debug, true, zon_version);
    const translated = b.addTranslateC(.{
        .root_source_file = header,
        .target = target,
        .optimize = .Debug,
    });
    const zig_suite = b.addTest(.{
        .name = "capi-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/capi_zig/root.zig"),
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .imports = &.{.{ .name = "c", .module = translated.createModule() }},
        }),
        .test_runner = shardRunner(b),
    });
    zig_suite.root_module.linkLibrary(debug_lib);
    zig_suite.root_module.addAnonymousImport("issuez-api.json", .{ .root_source_file = api_json });
    // Every function and helper needs a test.
    const coverage = b.addExecutable(.{
        .name = "capi-coverage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/capi_coverage.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_coverage = b.addRunArtifact(coverage);
    run_coverage.addFileArg(api_json);
    run_coverage.addDirectoryArg(b.path("test/capi_zig"));
    run_coverage.expectExitCode(0);
    // The cache doesn't see the test files change inside the directory.
    run_coverage.has_side_effects = true;
    const zig_suite_step = b.step(
        "test-capi-zig",
        "Test every C API function from Zig, through the header",
    );
    zig_suite_step.dependOn(&run_coverage.step);
    addShards(b, zig_suite, 8, zig_suite_step);
    test_step.dependOn(zig_suite_step);

    // Archives for the Go binding. `go-libs` installs them; its tests link
    // this platform's, with build.zig.zon's version so a commit alone keeps
    // them, through CGO_LDFLAGS.
    const all = b.option(
        bool,
        "go-libs-all",
        "go-libs: every Go platform, not only the host",
    ) orelse false;
    const go_libs_step = b.step(
        "go-libs",
        "Install the Go binding's archives in lib/go/ (host, or -Dgo-libs-all)",
    );
    var go_test_lib: ?std.Build.LazyPath = null;
    var go_debug_lib: ?std.Build.LazyPath = null;
    for (lib_targets) |t| {
        const resolved = b.resolveTargetQuery(t.query);
        const host = b.graph.host.result;
        const on_host = resolved.result.os.tag == host.os.tag and
            resolved.result.cpu.arch == host.cpu.arch and
            (host.os.tag != .linux or resolved.result.abi.isMusl() == host.abi.isMusl());
        if (on_host) {
            go_test_lib = hostArchive(b, capiLib(b, resolved, .ReleaseSafe, false, zon_version));
            // The archive that counts its allocations, for the Go fuzz tests'
            // leak check (-tags issuez_debug).
            go_debug_lib = hostArchive(b, capiLib(b, resolved, .ReleaseSafe, true, zon_version));
        }
        if (!all and !on_host) continue;
        go_libs_step.dependOn(&b.addInstallFileWithDir(
            hostArchive(b, capiLib(b, resolved, .ReleaseSafe, false, version)),
            .{ .custom = b.fmt("lib/go/{s}", .{t.dir}) },
            "libissuez.a",
        ).step);
    }
    // No such platform (Windows): the target's, for the failure to say so.
    const go_test_archive = go_test_lib orelse archive;
    const go_debug_archive = go_debug_lib orelse archive;

    // The C smoke test, with the system compiler so ASan is available.
    const run_smoke = std.Build.Step.Run.create(b, "run C smoke test");
    run_smoke.addFileArg(compileC(b, "test/capi/smoke.c", header, archive, &.{
        "-g",
        "-fsanitize=address,undefined",
        "-fno-omit-frame-pointer",
    }));
    _ = run_smoke.addOutputDirectoryArg("work");
    // LeakSanitizer only exists on Linux; Apple's ASan aborts if asked.
    if (b.graph.host.result.os.tag == .linux) run_smoke.setEnvironmentVariable(
        "ASAN_OPTIONS",
        "detect_leaks=1",
    );
    run_smoke.expectExitCode(0);
    const test_capi = b.step("test-capi", "Run the C smoke test under ASan (needs cc)");
    test_capi.dependOn(&run_smoke.step);

    // The C quickstart, on a fresh repository; test-capi runs it too.
    const quickstart_c = compileC(b, "examples/c/quickstart.c", header, archive, &.{});
    const run_quickstart_c = b.addSystemCommand(&.{
        "sh",
        "-c",
        "git init -q \"$2\" && exec \"$1\" \"$2\"",
        "sh",
    });
    run_quickstart_c.addFileArg(quickstart_c);
    _ = run_quickstart_c.addOutputDirectoryArg("repo");
    run_quickstart_c.expectExitCode(0);
    b.step("example-c-quickstart", "Run examples/c/quickstart.c (needs cc)")
        .dependOn(&run_quickstart_c.step);
    test_capi.dependOn(&run_quickstart_c.step);

    // gofmt prints nothing, vet passes, then the tests under the race
    // detector in a random order, with a statement coverage floor on the
    // hand-written code, and the fuzz seeds with the leak check.
    const go_test = addQuietCommand(b, &.{
        "sh",
        "-c",
        \\set -e
        \\dir() { (cd "$(dirname "$1")" && pwd); }
        \\export CGO_LDFLAGS="-L$(dir "$2")"
        \\out=$(gofmt -l .)
        \\if [ -n "$out" ]; then echo "gofmt: $out" >&2; exit 1; fi
        \\go vet ./...
        \\cover=$(mktemp)
        \\hand=$(mktemp)
        \\trap 'rm -f "$cover" "$hand"' EXIT
        \\go test -race -count=1 -shuffle=on -coverprofile="$cover" ./...
        \\grep -v '/enums_gen\.go:' "$cover" >"$hand"
        \\total=$(go tool cover -func="$hand" | awk '/^total:/ { sub("%", "", $3); print $3 }')
        \\if ! awk -v t="$total" -v min="$1" 'BEGIN { exit !(t >= min) }'; then
        \\  echo "Go statement coverage $total% is under $1%" >&2; exit 1
        \\fi
        \\CGO_LDFLAGS="-L$(dir "$3")" go test -tags issuez_debug -count=1 -run '^Fuzz' ./issuez
        ,
        "sh",
        "95",
    });
    goCommand(b, go_test, &update.step);
    go_test.addFileArg(go_test_archive);
    go_test.addFileArg(go_debug_archive);
    b.step("test-go", "Run the Go binding's tests (needs Go)").dependOn(&go_test.step);

    // Each fuzz test in turn, with the leak check.
    const fuzz_time = b.option(
        []const u8,
        "fuzz-time",
        "fuzz-go: how long each Go fuzz test runs (go test -fuzztime)",
    ) orelse "30s";
    const go_fuzz = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\set -e
        \\CGO_LDFLAGS="-L$(cd "$(dirname "$2")" && pwd)"
        \\export CGO_LDFLAGS
        \\for f in FuzzParseOID FuzzSnapshotUnmarshal FuzzEditValidate; do
        \\  go test -tags issuez_debug -run '^$' -fuzz "^$f\$" -fuzztime "$1" ./issuez
        \\done
        ,
        "sh",
        fuzz_time,
    });
    goCommand(b, go_fuzz, &update.step);
    go_fuzz.addFileArg(go_debug_archive);
    go_fuzz.stdio = .inherit;
    b.step(
        "fuzz-go",
        "Fuzz the Go binding (-Dfuzz-time=60s each; needs Go)",
    ).dependOn(&go_fuzz.step);

    // The binding against the real CLI. The root package adds
    // upstream's bin directory as the second argument.
    const go_e2e = addQuietCommand(b, &.{
        "sh",
        "-c",
        \\set -e
        \\# go test runs in the package's directory: absolute paths only.
        \\abs() { (cd "$(dirname "$1")" && printf '%s/%s' "$(pwd)" "$(basename "$1")"); }
        \\CGO_LDFLAGS="-L$(dirname "$(abs "$1")")"
        \\ISSUEZ_GIT_ISSUE=$(abs "$2")
        \\ISSUEZ_UPSTREAM=${3:+$(abs "$3")}
        \\export CGO_LDFLAGS ISSUEZ_GIT_ISSUE ISSUEZ_UPSTREAM
        \\go vet -tags e2e ./issuez/e2e/...
        \\go test -tags e2e -count=1 ./issuez/e2e/...
        ,
        "sh",
    });
    goCommand(b, go_e2e, &update.step);
    go_e2e.addFileArg(go_test_archive);
    go_e2e.addArtifactArg(exe);
    b.step("test-go-e2e", "Run the Go binding's end-to-end tests against the CLI (needs Go)")
        .dependOn(&go_e2e.step);

    const bindings = b.step(
        "test-bindings",
        "Run every C API and Go binding test (needs cc and Go)",
    );
    bindings.dependOn(zig_suite_step);
    bindings.dependOn(&run_smoke.step);
    bindings.dependOn(&go_test.step);
    bindings.dependOn(&go_e2e.step);

    // The same on Linux, in a container (test/linux/), for a macOS host.
    const linux = b.addSystemCommand(&.{ "sh", "test/linux/test-bindings.sh" });
    linux.setCwd(b.path("."));
    linux.has_side_effects = true;
    linux.stdio = .inherit;
    b.step("test-bindings-linux", "Run test-bindings in a Linux container (needs docker)")
        .dependOn(&linux.step);
    return .{ .go_e2e = go_e2e, .step = bindings };
}

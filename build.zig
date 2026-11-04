//!   zig build                      git-issue, full: TUI and MCP server
//!   zig build -Dminimal            git-issue, CLI only (-Dtui=false -Dmcp=false)
//!   zig build -Dtui=false          without the TUI; -Dmcp=false without the MCP server
//!   zig build test                 unit, backend, simulator/oracle and fuzz smoke tests
//!   zig build simulator            git-issue-sim
//!   zig build -Dfuzz               also install git-issue-fuzz
//!   zig build release              both flavors for every release target, in zig-out/release/
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

const std = @import("std");
const entry_points = @import("src/cli/entry_points.zig");

pub fn build(b: *std.Build) void {
    if (isRootPackage(b)) forgetOuterRepository(b);
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

    const issuez = b.addModule("issuez", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cli: Cli = .init(b, target, optimize, issuez);
    const oracle = cli.oracle;
    const extras = cli.parts(.{ .tui = tui, .mcp = mcp });

    const exe = cli.exe("git-issue", "src/cli/main.zig", optimize, extras);
    b.installArtifact(exe);
    installEntryPoints(b, exe);
    installCompletions(b, exe);
    installManPages(b, exe);

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
    const sim = cli.exe("git-issue-sim", "src/cli/main_sim.zig", optimize, .{});
    const sim_step = b.step("simulator", "Build git-issue-sim");
    sim_step.dependOn(&b.addInstallArtifact(sim, .{}).step);

    const fuzz_exe = cli.exe("git-issue-fuzz", "src/cli/main_fuzz.zig", optimize, .{});
    if (fuzz) b.installArtifact(fuzz_exe);

    const test_step = b.step("test", "Run unit, backend, simulator/oracle and fuzz smoke tests");

    const unit_roots = [_]struct { name: []const u8, module: *std.Build.Module }{
        .{ .name = "issuez", .module = issuez },
        .{ .name = "oracle", .module = oracle },
        .{ .name = "cli", .module = cli.module("src/cli/main.zig", optimize, extras) },
    };
    for (unit_roots) |u| {
        const t = b.addTest(.{ .name = u.name, .root_module = u.module });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    if (extras.tui) |m| {
        const t = b.addTest(.{ .name = "tui", .root_module = m });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
        b.step("test-tui", "Run the TUI's tests").dependOn(&run_t.step);
    }
    if (extras.mcp) |m| {
        const t = b.addTest(.{ .name = "mcp", .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    if (extras.watch) |m| {
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
        run_e2e.addArg(@import("build.zig.zon").version);
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

    for ([_][]const u8{ "test/backend_git.zig", "test/trailers_git.zig" }) |root| {
        const t = b.addTest(.{
            .name = std.fs.path.stem(root),
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
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
        });
        const run_t = b.addRunArtifact(t);
        run_t.has_side_effects = true;
        test_step.dependOn(&run_t.step);
    }

    // A smoke run: the same cases every time, so it catches regressions.
    // `ci` adds a long run on a fresh seed, which finds new bugs.
    const fuzz_run = b.addRunArtifact(fuzz_exe);
    fuzz_run.addArgs(&.{ "--seed", "20261018", "--iterations", "300" });
    fuzz_run.expectExitCode(0);
    fuzz_run.expectStdErrMatch("300 cases passed");
    test_step.dependOn(&fuzz_run.step);

    // Budget 2 s, on a ReleaseSafe build whatever -Doptimize says: that is
    // what users run. Most of the time is spent in git.
    const perf_exe = cli.exe("git-issue", "src/cli/main.zig", .ReleaseSafe, .{});
    const perf_runner = b.addExecutable(.{
        .name = "perf-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/perf_smoke.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_perf = b.addRunArtifact(perf_runner);
    run_perf.addArtifactArg(perf_exe);
    if (b.args) |args| run_perf.addArgs(args);
    run_perf.stdio = .inherit;
    b.step("test-perf", "Time `ls -a` over 10 000 issues against the 2 s budget")
        .dependOn(&run_perf.step);

    // What CI runs, so `zig build ci -Dseed=<run id>` reproduces a CI run:
    // `test`, long fuzz and trailer runs on the seed, interop, upstream's
    // suite, and perf.
    const ci_step = b.step("ci", "Run what CI runs (-Dseed=<n> for its fuzz and trailer runs)");
    {
        const seed = b.fmt("{d}", .{b.option(u64, "seed", "Seed of the ci runs") orelse 20261018});
        ci_step.dependOn(test_step);
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

        const ci_perf = b.addRunArtifact(perf_runner);
        ci_perf.addArtifactArg(perf_exe);
        ci_perf.stdio = .inherit;
        // After the long fuzz run, so the two do not share the CPU.
        ci_perf.step.dependOn(&long_fuzz.step);
        ci_step.dependOn(&ci_perf.step);
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
                const run_test = b.addRunArtifact(t);
                run_test.has_side_effects = true;
                test_step.dependOn(&run_test.step);
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
            });
            const run_interop = b.addRunArtifact(interop);
            run_interop.has_side_effects = true;
            interop_step.dependOn(&run_interop.step);
            ci_step.dependOn(&run_interop.step);

            const suite = b.addExecutable(.{
                .name = "upstream-suite",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/upstream_suite.zig"),
                    .target = b.graph.host,
                    .optimize = .Debug,
                }),
            });
            const run_suite = b.addRunArtifact(suite);
            run_suite.addDirectoryArg(upstream.path(""));
            run_suite.addArtifactArg(exe);
            run_suite.addFileArg(b.path("test/upstream-expected.txt"));
            run_suite.addFileArg(b.path("test/upstream-allowlist.txt"));
            // The runner reports on stderr, which a checked step would treat
            // as a failure.
            run_suite.stdio = .inherit;
            suite_step.dependOn(&run_suite.step);
            ci_step.dependOn(&run_suite.step);
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
/// (from a build that runs here), and LICENSE, README.md and CHANGELOG.md
/// in `share/doc/git-native-issuez/` (at the top on Windows). A `.zip` for
/// Windows, `.tar.gz` otherwise, all in `zig-out/release/` with their
/// `SHA256SUMS`. GitHub lists release assets by name, so the full flavor
/// comes first. Needs `sh`, `tar` and `zip`.
fn addRelease(b: *std.Build, step: *std.Build.Step) void {
    const version = @import("build.zig.zon").version;
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
            for ([_][]const u8{ "LICENSE", "README.md", "CHANGELOG.md" }) |doc| {
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
    zon: *std.Build.Module,
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
            .zon = b.createModule(.{ .root_source_file = b.path("build.zig.zon") }),
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
                    .{ .name = "build.zig.zon", .module = cli.zon },
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
                .{ .name = "build.zig.zon", .module = cli.zon },
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

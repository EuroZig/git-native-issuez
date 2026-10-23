//!   zig build                      git-issue
//!   zig build test                 unit, backend, simulator/oracle and fuzz smoke tests
//!   zig build simulator            git-issue-sim
//!   zig build -Dfuzz               also install git-issue-fuzz
//!   zig build test-interop         tests against upstream (fetched lazily)
//!   zig build test-upstream-suite  upstream's t/*.sh against our binary
//!   zig build test-perf            `ls` over 10 000 issues
//!   zig build ci [-Dseed=N]        what CI runs
//!   zig build examples             library examples (examples/*.zig)
//!   zig build example-<name>       run one (quickstart, sync, real-repo -- <path> ls)
//!   zig build update-snapshots     rewrite examples/*.out

const std = @import("std");
const entry_points = @import("src/cli/entry_points.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const fuzz = b.option(bool, "fuzz", "Install the fuzzer") orelse false;

    const zon = b.createModule(.{ .root_source_file = b.path("build.zig.zon") });

    const issuez = b.addModule("issuez", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const oracle = b.createModule(.{
        .root_source_file = b.path("src/oracle/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "issuez", .module = issuez }},
    });

    const cli = Cli{ .b = b, .target = target, .issuez = issuez, .oracle = oracle, .zon = zon };

    const exe = cli.exe("git-issue", "src/cli/main.zig", optimize);
    b.installArtifact(exe);
    installEntryPoints(b, exe);

    const run_step = b.step("run", "Run git-issue");
    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    run_step.dependOn(&run_exe.step);

    const sim = cli.exe("git-issue-sim", "src/cli/main_sim.zig", optimize);
    const sim_step = b.step("simulator", "Build git-issue-sim");
    sim_step.dependOn(&b.addInstallArtifact(sim, .{}).step);

    const fuzz_exe = cli.exe("git-issue-fuzz", "src/cli/main_fuzz.zig", optimize);
    if (fuzz) b.installArtifact(fuzz_exe);

    const test_step = b.step("test", "Run unit, backend, simulator/oracle and fuzz smoke tests");

    const unit_roots = [_]struct { name: []const u8, module: *std.Build.Module }{
        .{ .name = "issuez", .module = issuez },
        .{ .name = "oracle", .module = oracle },
        .{ .name = "cli", .module = cli.module("src/cli/main.zig", optimize) },
    };
    for (unit_roots) |u| {
        const t = b.addTest(.{ .name = u.name, .root_module = u.module });
        test_step.dependOn(&b.addRunArtifact(t).step);
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

    // Budget 1 s. Most of the time is spent in git.
    const perf_exe = cli.exe("git-issue", "src/cli/main.zig", optimize);
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
    // suite, and perf with headroom for shared runners.
    const ci_step = b.step("ci", "Run what CI runs (-Dseed=<n> for its fuzz and trailer runs)");
    {
        const seed = b.fmt("{d}", .{b.option(u64, "seed", "Seed of the ci runs") orelse 20261018});
        ci_step.dependOn(test_step);

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
fn isRootPackage(b: *std.Build) bool {
    return b.pkg_hash.len == 0;
}

const Cli = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    issuez: *std.Build.Module,
    oracle: *std.Build.Module,
    zon: *std.Build.Module,

    fn module(
        cli: Cli,
        root: []const u8,
        optimize: std.builtin.OptimizeMode,
    ) *std.Build.Module {
        const b = cli.b;
        return b.createModule(.{
            .root_source_file = b.path(root),
            .target = cli.target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "issuez", .module = cli.issuez },
                .{ .name = "oracle", .module = cli.oracle },
                .{ .name = "build.zig.zon", .module = cli.zon },
            },
        });
    }

    fn exe(
        cli: Cli,
        name: []const u8,
        root: []const u8,
        optimize: std.builtin.OptimizeMode,
    ) *std.Build.Step.Compile {
        return cli.b.addExecutable(.{
            .name = name,
            .root_module = cli.module(root, optimize),
        });
    }
};

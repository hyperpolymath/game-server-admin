// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — FFI build configuration
//
// Compiles libgsa shared library implementing the C ABI declared in
// src/interface/abi/*.idr.  Primary target: x86_64-linux; cross-compile
// targets: aarch64-linux, x86_64-macos.

const std = @import("std");

pub fn build(b: *std.Build) void {
    // ---------------------------------------------------------------
    // Default target / optimisation from CLI flags
    // ---------------------------------------------------------------
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---------------------------------------------------------------
    // Optional: path to Gossamer library for full-stack builds
    //
    //   zig build -Dgossamer-lib-path=/path/to/gossamer/zig-out/lib
    //
    // When provided, the integration tests can link against
    // libgossamer.so for end-to-end verification.  Without this
    // flag, libgsa builds and tests standalone (which is fine —
    // Gossamer loads libgsa via dlopen at runtime).
    // ---------------------------------------------------------------
    const gossamer_lib_path = b.option(
        []const u8,
        "gossamer-lib-path",
        "Path to Gossamer zig-out/lib/ directory containing libgossamer.so",
    );

    // ---------------------------------------------------------------
    // Shared library — libgsa.so / libgsa.dylib / gsa.dll
    // ---------------------------------------------------------------
    const lib = b.addLibrary(.{
        .name = "gsa",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // needed for socket operations and posix APIs
        }),
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });

    b.installArtifact(lib);

    // ---------------------------------------------------------------
    // CLI executable — gsa
    // ---------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "gsa",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    if (b.args) |run_args| {
        run_exe.addArgs(run_args);
    }
    const run_step = b.step("run", "Run the GSA CLI");
    run_step.dependOn(&run_exe.step);

    // ---------------------------------------------------------------
    // Static library — libgsa.a
    // ---------------------------------------------------------------
    const lib_static = b.addLibrary(.{
        .name = "gsa",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(lib_static);

    // ---------------------------------------------------------------
    // Unit tests (compile every module individually)
    // ---------------------------------------------------------------
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests for all FFI modules");
    test_step.dependOn(&run_unit_tests.step);

    // ---------------------------------------------------------------
    // Shared module for test targets — exposes src/ modules to tests
    // without requiring relative imports outside the module path.
    // ---------------------------------------------------------------
    const src_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // ---------------------------------------------------------------
    // Integration tests
    // ---------------------------------------------------------------
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("test/integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    integration_mod.addImport("gsa", src_module);

    const integration_tests = b.addTest(.{
        .root_module = integration_mod,
    });

    // If gossamer library path is provided, add it to the integration tests
    // so they can resolve gossamer symbols during full-stack verification.
    if (gossamer_lib_path) |goss_path| {
        integration_mod.addLibraryPath(.{ .cwd_relative = goss_path });
        integration_mod.addRPath(.{ .cwd_relative = goss_path });
    }

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_step = b.step("test-integration", "Run FFI integration tests");
    integration_step.dependOn(&run_integration_tests.step);

    // ---------------------------------------------------------------
    // Smoke tests (end-to-end pipeline without live services)
    // ---------------------------------------------------------------
    const smoke_mod = b.createModule(.{
        .root_source_file = b.path("test/smoke_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    smoke_mod.addImport("gsa", src_module);

    const smoke_tests = b.addTest(.{
        .root_module = smoke_mod,
    });

    const run_smoke_tests = b.addRunArtifact(smoke_tests);
    const smoke_step = b.step("test-smoke", "Run end-to-end smoke tests (no live services needed)");
    smoke_step.dependOn(&run_smoke_tests.step);

    // ---------------------------------------------------------------
    // Property tests — invariant / property-based tests
    // ---------------------------------------------------------------
    const property_mod = b.createModule(.{
        .root_source_file = b.path("test/property_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    property_mod.addImport("gsa", src_module);

    const property_tests = b.addTest(.{
        .root_module = property_mod,
    });

    const run_property_tests = b.addRunArtifact(property_tests);
    const property_step = b.step("test-property", "Run property/invariant tests");
    property_step.dependOn(&run_property_tests.step);

    // ---------------------------------------------------------------
    // Benchmarks — micro-benchmark executable (prints to stderr)
    // ---------------------------------------------------------------
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench_main.zig"),
        .target = target,
        .optimize = .ReleaseFast, // always compile benchmarks with optimisations
        .link_libc = true,
    });
    bench_mod.addImport("gsa", src_module);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(b.getInstallStep());
    const bench_step = b.step("bench", "Run FFI micro-benchmarks");
    bench_step.dependOn(&run_bench.step);

    // ---------------------------------------------------------------
    // Cross-compile convenience targets
    // ---------------------------------------------------------------
    inline for (.{
        .{ "x86_64-linux", "Build libgsa for x86_64-linux" },
        .{ "aarch64-linux", "Build libgsa for aarch64-linux" },
        .{ "x86_64-macos", "Build libgsa for x86_64-macos" },
    }) |entry| {
        const cross_target = std.Target.Query.parse(.{
            .arch_os_abi = entry[0],
        }) catch unreachable;

        const cross_lib = b.addLibrary(.{
            .name = "gsa",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(cross_target),
                .optimize = optimize,
                .link_libc = true,
            }),
            .version = .{ .major = 0, .minor = 1, .patch = 0 },
        });

        const install_cross = b.addInstallArtifact(cross_lib, .{});
        const cross_step = b.step(entry[0], entry[1]);
        cross_step.dependOn(&install_cross.step);
    }
}

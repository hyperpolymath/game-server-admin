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
    // Integration tests
    // ---------------------------------------------------------------
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_step = b.step("test-integration", "Run FFI integration tests");
    integration_step.dependOn(&run_integration_tests.step);

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

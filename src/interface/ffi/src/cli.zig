// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — CLI runner
//
// Standalone executable that exercises the FFI layer directly without
// Gossamer.  Provides subcommands for common operations:
//   gsa status     — show VeriSimDB health and loaded profiles
//   gsa probe      — fingerprint a game server endpoint
//   gsa profiles   — list available game profiles
//   gsa version    — print version info
//
// This is the entry point for `just run` and `just gui` (headless mode).

const std = @import("std");
const gsa_core = @import("main.zig");
const probe_mod = @import("probe.zig");
const game_profiles = @import("game_profiles.zig");
const verisimdb_client = @import("verisimdb_client.zig");

/// Buffered writer wrapping a std.fs.File for stdout/stderr output.
fn getWriter(file: std.fs.File) std.fs.File.Writer {
    var buf: [4096]u8 = undefined;
    return file.writer(&buf);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Environment-driven config with sensible defaults
    const verisimdb_url = std.posix.getenv("GSA_VERISIMDB_URL") orelse "http://localhost:8090";
    const profiles_dir = std.posix.getenv("GSA_PROFILES_DIR") orelse "./profiles";

    const out = std.fs.File.stdout();

    if (args.len < 2) {
        printBanner(out);
        printUsage(out);
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        printVersion(out);
    } else if (std.mem.eql(u8, cmd, "status")) {
        cmdStatus(allocator, verisimdb_url, profiles_dir, out);
    } else if (std.mem.eql(u8, cmd, "profiles")) {
        cmdProfiles(allocator, profiles_dir, out);
    } else if (std.mem.eql(u8, cmd, "probe")) {
        if (args.len < 3) {
            const err_f = std.fs.File.stderr();
            err_f.writeAll("Usage: gsa probe <host> [port]\n") catch {};
            std.process.exit(1);
        }
        const port: u16 = if (args.len >= 4) std.fmt.parseInt(u16, args[3], 10) catch 27015 else 27015;
        cmdProbe(args[2], port, out);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printBanner(out);
        printUsage(out);
    } else {
        const err_f = std.fs.File.stderr();
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown command: {s}\n\n", .{cmd}) catch "Unknown command\n";
        err_f.writeAll(msg) catch {};
        printUsage(out);
        std.process.exit(1);
    }
}

// ── Subcommands ─────────────────────────────────────────────────────────────

/// Show overall system status: VeriSimDB health, loaded profiles, build info.
fn cmdStatus(allocator: std.mem.Allocator, verisimdb_url: []const u8, profiles_dir: []const u8, out: std.fs.File) void {
    printBanner(out);

    var line_buf: [1024]u8 = undefined;

    var msg = std.fmt.bufPrint(&line_buf, "  Build:     {s}\n  VeriSimDB: {s}\n  Profiles:  {s}\n\n", .{ gsa_core.BUILD_INFO, verisimdb_url, profiles_dir }) catch return;
    out.writeAll(msg) catch return;

    // VeriSimDB health check
    out.writeAll("  VeriSimDB health ... ") catch return;
    var client = verisimdb_client.VeriSimClient.init(allocator, verisimdb_url);
    defer client.deinit();

    const healthy = client.health() catch false;
    if (healthy) {
        out.writeAll("OK\n\n") catch return;
    } else {
        out.writeAll("FAIL\n  (is VeriSimDB running? Start with: just verisimdb-up)\n\n") catch return;
    }

    // Profile count
    var registry = game_profiles.ProfileRegistry.init(allocator);
    defer registry.deinit();
    const loaded = registry.loadFromDirectory(profiles_dir) catch 0;
    msg = std.fmt.bufPrint(&line_buf, "  Game profiles loaded: {d}\n", .{loaded}) catch return;
    out.writeAll(msg) catch return;

    // List profiles as JSON
    if (loaded > 0) {
        const json = registry.listProfiles(allocator) catch null;
        if (json) |j| {
            defer allocator.free(j);
            out.writeAll("\n  Profile data:\n  ") catch return;
            out.writeAll(j) catch return;
            out.writeAll("\n") catch return;
        }
    }

    out.writeAll("\n") catch return;
}

/// List game profiles from the profiles directory.
fn cmdProfiles(allocator: std.mem.Allocator, profiles_dir: []const u8, out: std.fs.File) void {
    var registry = game_profiles.ProfileRegistry.init(allocator);
    defer registry.deinit();

    const loaded = registry.loadFromDirectory(profiles_dir) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Failed to load profiles from {s}: {s}\n", .{ profiles_dir, @errorName(err) }) catch return;
        const err_f = std.fs.File.stderr();
        err_f.writeAll(msg) catch {};
        std.process.exit(1);
    };

    var line_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&line_buf, "Game profiles ({d} loaded from {s}):\n\n", .{ loaded, profiles_dir }) catch return;
    out.writeAll(msg) catch return;

    const json = registry.listProfiles(allocator) catch null;
    if (json) |j| {
        defer allocator.free(j);
        out.writeAll(j) catch return;
        out.writeAll("\n") catch return;
    }
    out.writeAll("\n") catch return;
}

/// Probe a game server at host:port and display fingerprint results.
fn cmdProbe(host: []const u8, port: u16, out: std.fs.File) void {
    var line_buf: [512]u8 = undefined;
    var msg = std.fmt.bufPrint(&line_buf, "Probing {s}:{d} ...\n\n", .{ host, port }) catch return;
    out.writeAll(msg) catch return;

    // Check known ports table first
    for (probe_mod.KNOWN_PORTS) |entry| {
        if (entry.port == port) {
            msg = std.fmt.bufPrint(&line_buf, "  Known port: {d} (protocol: {s})\n  Associated games: ", .{
                entry.port,
                @tagName(entry.protocol),
            }) catch break;
            out.writeAll(msg) catch return;
            for (entry.games, 0..) |game, i| {
                if (i > 0) out.writeAll(", ") catch return;
                out.writeAll(game) catch return;
            }
            out.writeAll("\n\n") catch return;
            break;
        }
    }

    // Attempt live probe via probeSingle (tries multiple protocols)
    out.writeAll("  Connecting ... ") catch return;
    var result = probe_mod.probeSingle(host, port, 5000) catch |err| {
        msg = std.fmt.bufPrint(&line_buf, "FAIL ({s})\n  Server may be offline or unreachable.\n\n", .{@errorName(err)}) catch return;
        out.writeAll(msg) catch return;
        return;
    };

    const game_id = result.gameIdSlice();
    const version = result.versionSlice();

    out.writeAll("OK\n\n") catch return;
    msg = std.fmt.bufPrint(&line_buf, "  Protocol:    {s}\n  Game:        {s}\n  Version:     {s}\n  Latency:     {d}ms\n\n", .{
        @tagName(result.protocol),
        if (game_id.len > 0) game_id else "(unknown)",
        if (version.len > 0) version else "(unknown)",
        result.latency_ms,
    }) catch return;
    out.writeAll(msg) catch return;
}

// ── Display helpers ─────────────────────────────────────────────────────────

fn printBanner(out: std.fs.File) void {
    out.writeAll(
        \\
        \\  ╔═══════════════════════════════════════════════╗
        \\  ║  Game Server Admin                            ║
        \\  ║  Universal game server probe & management     ║
        \\  ╚═══════════════════════════════════════════════╝
        \\
        \\
    ) catch {};
}

fn printVersion(out: std.fs.File) void {
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "gsa {s}\n", .{gsa_core.VERSION}) catch return;
    out.writeAll(msg) catch {};
}

fn printUsage(out: std.fs.File) void {
    out.writeAll(
        \\  Usage: gsa <command> [options]
        \\
        \\  Commands:
        \\    status              Show system status (VeriSimDB, profiles)
        \\    probe <host> [port] Probe a game server (default port: 27015)
        \\    profiles            List available game profiles
        \\    version             Print version
        \\    help                Show this help
        \\
        \\  Environment:
        \\    GSA_VERISIMDB_URL   VeriSimDB endpoint (default: http://[::1]:8090)
        \\    GSA_PROFILES_DIR    Profiles directory (default: ./profiles)
        \\
        \\
    ) catch {};
}

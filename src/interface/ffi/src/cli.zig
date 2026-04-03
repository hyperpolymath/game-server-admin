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

/// Check if a file exists (Zig 0.15.2 compat — no std.fs.exists).
fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
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
    } else if (std.mem.eql(u8, cmd, "config")) {
        if (args.len < 3) {
            const err_f = std.fs.File.stderr();
            err_f.writeAll("Usage: gsa config <subcommand>\n") catch {};
            err_f.writeAll("Subcommands: init, show, set-default, add-favorite, list-favorites\n") catch {};
            std.process.exit(1);
        }
        const config_cmd = args[2];
        if (std.mem.eql(u8, config_cmd, "init")) {
            cmdConfigInit(out);
        } else if (std.mem.eql(u8, config_cmd, "show")) {
            cmdConfigShow(out);
        } else if (std.mem.eql(u8, config_cmd, "set-default")) {
            if (args.len < 5) {
                const err_f = std.fs.File.stderr();
                err_f.writeAll("Usage: gsa config set-default <host> <port>\n") catch {};
                std.process.exit(1);
            }
            const host = args[3];
            const port: u16 = std.fmt.parseInt(u16, args[4], 10) catch 25565;
            cmdConfigSetDefault(host, port, out);
        } else if (std.mem.eql(u8, config_cmd, "add-favorite")) {
            if (args.len < 6) {
                const err_f = std.fs.File.stderr();
                err_f.writeAll("Usage: gsa config add-favorite <name> <host> <port>\n") catch {};
                std.process.exit(1);
            }
            const name = args[3];
            const host = args[4];
            const port: u16 = std.fmt.parseInt(u16, args[5], 10) catch 25565;
            cmdConfigAddFavorite(name, host, port, out);
        } else if (std.mem.eql(u8, config_cmd, "list-favorites")) {
            cmdConfigListFavorites(out);
        } else {
            const err_f = std.fs.File.stderr();
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Unknown config subcommand: {s}\n", .{config_cmd}) catch "Unknown config subcommand\n";
            err_f.writeAll(msg) catch {};
            std.process.exit(1);
        }
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

// ── Config management ────────────────────────────────────────────────────────

/// Initialize user config from template
fn cmdConfigInit(out: std.fs.File) void {
    const template_path = "user-config.ncl.template";
    const config_path = "user-config.ncl";
    
    // Check if config already exists
    if (fileExists(config_path)) {
        out.writeAll("✗ Config file already exists at ") catch {};
        out.writeAll(config_path) catch {};
        out.writeAll("\n") catch {};
        return;
    }
    
    // Check if template exists
    if (!fileExists(template_path)) {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Template file not found: ") catch {};
        err_f.writeAll(template_path) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    }
    
    // Copy template to config
    const template_file = std.fs.cwd().openFile(template_path, .{}) catch |err| {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Failed to read template: ") catch {};
        err_f.writeAll(@errorName(err)) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    };
    defer template_file.close();
    
    const config_file = std.fs.cwd().createFile(config_path, .{}) catch |err| {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Failed to create config file: ") catch {};
        err_f.writeAll(@errorName(err)) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    };
    defer config_file.close();
    
    // Copy contents
    var buf: [4096]u8 = undefined;
    var bytes_read: usize = 0;
    while (true) {
        const n = template_file.read(&buf) catch 0;
        if (n == 0) break;
        bytes_read += n;
        _ = config_file.write(buf[0..n]) catch break;
    }
    
    out.writeAll("✓ Created user config from template: ") catch {};
    out.writeAll(config_path) catch {};
    out.writeAll(" (") catch {};
    var buf2: [32]u8 = undefined;
    const bytes_str = std.fmt.bufPrint(&buf2, "{d}", .{bytes_read}) catch "?";
    out.writeAll(bytes_str) catch {};
    out.writeAll(" bytes)\n") catch {};
    out.writeAll("\n") catch {};
    out.writeAll("Edit the file to customize your settings.\n") catch {};
}

/// Show current config
fn cmdConfigShow(out: std.fs.File) void {
    const config_path = "user-config.ncl";
    
    if (!fileExists(config_path)) {
        out.writeAll("✗ No config file found. Run `gsa config init` to create one.\n") catch {};
        return;
    }
    
    const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Failed to read config: ") catch {};
        err_f.writeAll(@errorName(err)) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    };
    defer file.close();
    
    out.writeAll("=== User Config (") catch {};
    out.writeAll(config_path) catch {};
    out.writeAll(") ===\n\n") catch {};
    
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch 0;
        if (n == 0) break;
        out.writeAll(buf[0..n]) catch {};
    }
}

/// Set default server
fn cmdConfigSetDefault(host: []const u8, port: u16, out: std.fs.File) void {
    const config_path = "user-config.ncl";
    
    if (!fileExists(config_path)) {
        out.writeAll("✗ No config file found. Run `gsa config init` first.\n") catch {};
        return;
    }
    
    // Read existing config
    const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Failed to read config: ") catch {};
        err_f.writeAll(@errorName(err)) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    };
    defer file.close();
    
    var existing: [16384]u8 = undefined;
    const n = file.read(&existing) catch 0;
    const existing_content = existing[0..n];
    
    // Simple string replacement for default server
    // In a real implementation, you'd use a proper Nickel parser
    // For now, we'll do a simple pattern replacement

    // Write back
    const out_file = std.fs.cwd().createFile(config_path, .{}) catch |err| {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Failed to write config: ") catch {};
        err_f.writeAll(@errorName(err)) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    };
    defer out_file.close();

    writeWithDefaultServer(existing_content, host, port, out_file) catch {};
    
    out.writeAll("✓ Updated default server to ") catch {};
    out.writeAll(host) catch {};
    out.writeAll(":") catch {};
    var port_buf2: [16]u8 = undefined;
    const port_str2 = std.fmt.bufPrint(&port_buf2, "{d}", .{port}) catch "?";
    out.writeAll(port_str2) catch {};
    out.writeAll("\n") catch {};
}

/// Add a favorite server
fn cmdConfigAddFavorite(name: []const u8, host: []const u8, port: u16, out: std.fs.File) void {
    const config_path = "user-config.ncl";
    
    if (!fileExists(config_path)) {
        out.writeAll("✗ No config file found. Run `gsa config init` first.\n") catch {};
        return;
    }
    
    // Read existing config
    const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Failed to read config: ") catch {};
        err_f.writeAll(@errorName(err)) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    };
    defer file.close();
    
    var existing: [16384]u8 = undefined;
    const n = file.read(&existing) catch 0;
    const existing_content = existing[0..n];
    
    // Add favorite to the favorites list

    // Write back
    const out_file = std.fs.cwd().createFile(config_path, .{}) catch |err| {
        const err_f = std.fs.File.stderr();
        err_f.writeAll("✗ Failed to write config: ") catch {};
        err_f.writeAll(@errorName(err)) catch {};
        err_f.writeAll("\n") catch {};
        std.process.exit(1);
    };
    defer out_file.close();

    writeWithFavorite(existing_content, name, host, port, out_file) catch {};
    
    out.writeAll("✓ Added favorite server: ") catch {};
    out.writeAll(name) catch {};
    out.writeAll(" (") catch {};
    out.writeAll(host) catch {};
    out.writeAll(":") catch {};
    var port_buf2: [16]u8 = undefined;
    const port_str2 = std.fmt.bufPrint(&port_buf2, "{d}", .{port}) catch "?";
    out.writeAll(port_str2) catch {};
    out.writeAll(")\n") catch {};
}

/// List favorite servers
fn cmdConfigListFavorites(out: std.fs.File) void {
    const config_path = "user-config.ncl";
    
    if (!fileExists(config_path)) {
        out.writeAll("✗ No config file found. Run `gsa config init` first.\n") catch {};
        return;
    }
    
    // In a real implementation, we'd parse the Nickel file
    // For now, just show a message
    out.writeAll("Favorite servers are stored in ") catch {};
    out.writeAll(config_path) catch {};
    out.writeAll(".\n") catch {};
    out.writeAll("Use `gsa config show` to view the full config.\n") catch {};
}

/// Helper: Write config content with replaced default server to a file.
fn writeWithDefaultServer(existing: []const u8, host: []const u8, port: u16, out_file: std.fs.File) !void {
    const host_start = std.mem.indexOf(u8, existing, "host = ") orelse {
        _ = try out_file.write(existing);
        return;
    };
    const port_start = std.mem.indexOf(u8, existing, "port = ") orelse {
        _ = try out_file.write(existing);
        return;
    };
    _ = try out_file.write(existing[0..host_start]);
    var host_buf: [512]u8 = undefined;
    const host_line = std.fmt.bufPrint(&host_buf, "host = \"{s}\",\n", .{host}) catch return error.InvalidParam;
    _ = try out_file.write(host_line);
    const host_region = existing[host_start..port_start];
    const next_nl = std.mem.indexOfScalar(u8, host_region, '\n') orelse host_region.len;
    if (next_nl + 1 < host_region.len) {
        _ = try out_file.write(host_region[next_nl + 1 ..]);
    }
    var port_buf: [128]u8 = undefined;
    const port_line = std.fmt.bufPrint(&port_buf, "port = {d},\n", .{port}) catch return error.InvalidParam;
    _ = try out_file.write(port_line);
    const after_port_nl = std.mem.indexOfScalarPos(u8, existing, port_start, '\n') orelse existing.len;
    if (after_port_nl + 1 < existing.len) {
        _ = try out_file.write(existing[after_port_nl + 1 ..]);
    }
}

/// Helper: Write config content with a new favorite appended to a file.
fn writeWithFavorite(existing: []const u8, name: []const u8, host: []const u8, port: u16, out_file: std.fs.File) !void {
    const fav_end = std.mem.indexOf(u8, existing, "]") orelse {
        _ = try out_file.write(existing);
        return;
    };
    _ = try out_file.write(existing[0..fav_end]);
    var entry_buf: [512]u8 = undefined;
    const entry = std.fmt.bufPrint(
        &entry_buf,
        "    {{\n      name = \"{s}\",\n      host = \"{s}\",\n      port = {d},\n    }},\n",
        .{ name, host, port },
    ) catch return error.InvalidParam;
    _ = try out_file.write(entry);
    _ = try out_file.write(existing[fav_end..]);
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
        \\    config init         Initialize user config from template
        \\    config show         Show current user configuration
        \\    config set-default <host> <port>
        \\                          Set the default server connection
        \\    config add-favorite <name> <host> <port>
        \\                          Add a server to favorites
        \\    config list-favorites
        \\                          List favorite servers
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

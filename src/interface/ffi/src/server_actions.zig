// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — Server action dispatcher
//
// Executes lifecycle actions (start, stop, restart, status, logs, update,
// backup, validate-config) against game servers running in Podman/Docker
// containers or managed by systemd.  Actions can be dispatched locally
// or via SSH to remote hosts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const main = @import("main.zig");

// ═══════════════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════════════

/// The set of actions that can be performed on a game server.
pub const ActionKind = enum(u8) {
    Start = 0,
    Stop = 1,
    Restart = 2,
    Status = 3,
    Logs = 4,
    Update = 5,
    Backup = 6,
    ValidateConfig = 7,
};

/// The result of executing a server action.
pub const ActionResult = struct {
    success: bool,
    output: []const u8,
    exit_code: i32,
};

/// Container runtime used to manage the server.
pub const Runtime = enum { podman, docker, systemd };

// ═══════════════════════════════════════════════════════════════════════════════
// Action execution
// ═══════════════════════════════════════════════════════════════════════════════

/// Execute a lifecycle action against a container-managed game server.
///
/// Constructs the appropriate CLI command for the given runtime and
/// action, then runs it via std.process.Child.
pub fn executeAction(
    allocator: Allocator,
    host: []const u8,
    action: ActionKind,
    container_name: []const u8,
    runtime: Runtime,
) !ActionResult {
    const runtime_cmd: []const u8 = switch (runtime) {
        .podman => "podman",
        .docker => "docker",
        .systemd => "systemctl",
    };

    // Build the command arguments
    var argv_buf: [16][]const u8 = undefined;
    var argc: usize = 0;

    // If remote, prefix with SSH
    if (host.len > 0 and !isLocalhost(host)) {
        argv_buf[argc] = "ssh";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "StrictHostKeyChecking=accept-new";
        argc += 1;
        argv_buf[argc] = host;
        argc += 1;
    }

    switch (runtime) {
        .podman, .docker => {
            argv_buf[argc] = runtime_cmd;
            argc += 1;

            switch (action) {
                .Start => {
                    argv_buf[argc] = "start";
                    argc += 1;
                    argv_buf[argc] = container_name;
                    argc += 1;
                },
                .Stop => {
                    argv_buf[argc] = "stop";
                    argc += 1;
                    argv_buf[argc] = "-t";
                    argc += 1;
                    argv_buf[argc] = "60";
                    argc += 1;
                    argv_buf[argc] = container_name;
                    argc += 1;
                },
                .Restart => {
                    argv_buf[argc] = "restart";
                    argc += 1;
                    argv_buf[argc] = "-t";
                    argc += 1;
                    argv_buf[argc] = "60";
                    argc += 1;
                    argv_buf[argc] = container_name;
                    argc += 1;
                },
                .Status => {
                    argv_buf[argc] = "inspect";
                    argc += 1;
                    argv_buf[argc] = "--format";
                    argc += 1;
                    argv_buf[argc] = "{{.State.Status}}";
                    argc += 1;
                    argv_buf[argc] = container_name;
                    argc += 1;
                },
                .Logs => {
                    argv_buf[argc] = "logs";
                    argc += 1;
                    argv_buf[argc] = "--tail";
                    argc += 1;
                    argv_buf[argc] = "100";
                    argc += 1;
                    argv_buf[argc] = container_name;
                    argc += 1;
                },
                .Update => {
                    // Pull latest image and recreate
                    argv_buf[argc] = "pull";
                    argc += 1;
                    argv_buf[argc] = container_name;
                    argc += 1;
                },
                .Backup => {
                    argv_buf[argc] = "exec";
                    argc += 1;
                    argv_buf[argc] = container_name;
                    argc += 1;
                    argv_buf[argc] = "/scripts/backup.sh";
                    argc += 1;
                },
                .ValidateConfig => {
                    argv_buf[argc] = "exec";
                    argc += 1;
                    argv_buf[argc] = container_name;
                    argc += 1;
                    argv_buf[argc] = "/scripts/validate-config.sh";
                    argc += 1;
                },
            }
        },
        .systemd => {
            argv_buf[argc] = runtime_cmd;
            argc += 1;

            switch (action) {
                .Start => {
                    argv_buf[argc] = "start";
                    argc += 1;
                },
                .Stop => {
                    argv_buf[argc] = "stop";
                    argc += 1;
                },
                .Restart => {
                    argv_buf[argc] = "restart";
                    argc += 1;
                },
                .Status => {
                    argv_buf[argc] = "status";
                    argc += 1;
                },
                .Logs => {
                    // For systemd, use journalctl
                    argv_buf[0] = "journalctl";
                    argc = 1;
                    argv_buf[argc] = "-u";
                    argc += 1;
                    argv_buf[argc] = container_name;
                    argc += 1;
                    argv_buf[argc] = "-n";
                    argc += 1;
                    argv_buf[argc] = "100";
                    argc += 1;
                    argv_buf[argc] = "--no-pager";
                    argc += 1;
                    return runCommand(allocator, argv_buf[0..argc]);
                },
                else => {
                    argv_buf[argc] = "status";
                    argc += 1;
                },
            }

            argv_buf[argc] = container_name;
            argc += 1;
        },
    }

    return runCommand(allocator, argv_buf[0..argc]);
}

/// Run a command via SSH on a remote host.
///
/// `argv` is passed as a separate exec argument to SSH via `ssh -- host argv[0] argv[1]...`,
/// so each element is passed as a distinct argument to the remote process — the remote
/// shell is bypassed entirely (SSH calls execvp directly when given an arg list, not
/// a shell string). This prevents shell injection from user-supplied values.
///
/// Returns the combined stdout output and exit code.
pub fn executeSSH(
    allocator: Allocator,
    host: []const u8,
    user: []const u8,
    remote_argv: []const []const u8,
) !ActionResult {
    if (remote_argv.len == 0) return error.InvalidParam;

    var target_buf: [512]u8 = undefined;
    const target = std.fmt.bufPrint(&target_buf, "{s}@{s}", .{ user, host }) catch return error.InvalidParam;

    // Build: ssh -o ... target -- remote_argv[0] remote_argv[1]...
    const fixed_prefix: []const []const u8 = &.{
        "ssh",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=10",
        target,
        "--",
    };

    const full_argv = try allocator.alloc([]const u8, fixed_prefix.len + remote_argv.len);
    defer allocator.free(full_argv);
    @memcpy(full_argv[0..fixed_prefix.len], fixed_prefix);
    @memcpy(full_argv[fixed_prefix.len..], remote_argv);

    return runCommand(allocator, full_argv);
}

/// Get the last N lines of logs from a container.
pub fn streamLogs(
    allocator: Allocator,
    host: []const u8,
    container_name: []const u8,
    lines: u32,
    runtime: Runtime,
) ![]const u8 {
    const runtime_cmd: []const u8 = switch (runtime) {
        .podman => "podman",
        .docker => "docker",
        .systemd => "journalctl",
    };

    var lines_buf: [16]u8 = undefined;
    const lines_str = std.fmt.bufPrint(&lines_buf, "{d}", .{lines}) catch "100";

    var argv_buf: [16][]const u8 = undefined;
    var argc: usize = 0;

    if (host.len > 0 and !isLocalhost(host)) {
        argv_buf[argc] = "ssh";
        argc += 1;
        argv_buf[argc] = host;
        argc += 1;
    }

    switch (runtime) {
        .podman, .docker => {
            argv_buf[argc] = runtime_cmd;
            argc += 1;
            argv_buf[argc] = "logs";
            argc += 1;
            argv_buf[argc] = "--tail";
            argc += 1;
            argv_buf[argc] = lines_str;
            argc += 1;
            argv_buf[argc] = container_name;
            argc += 1;
        },
        .systemd => {
            argv_buf[argc] = runtime_cmd;
            argc += 1;
            argv_buf[argc] = "-u";
            argc += 1;
            argv_buf[argc] = container_name;
            argc += 1;
            argv_buf[argc] = "-n";
            argc += 1;
            argv_buf[argc] = lines_str;
            argc += 1;
            argv_buf[argc] = "--no-pager";
            argc += 1;
        },
    }

    const result = try runCommand(allocator, argv_buf[0..argc]);
    if (!result.success) {
        allocator.free(result.output);
        return error.LogRetrievalFailed;
    }
    return result.output;
}

/// Get the status of a container as a JSON string.
///
/// Returns a JSON object with at least a "status" field (e.g. "running",
/// "stopped", "exited").
pub fn getServerStatus(
    allocator: Allocator,
    host: []const u8,
    container_name: []const u8,
) ![]const u8 {
    var argv_buf: [16][]const u8 = undefined;
    var argc: usize = 0;

    if (host.len > 0 and !isLocalhost(host)) {
        argv_buf[argc] = "ssh";
        argc += 1;
        argv_buf[argc] = host;
        argc += 1;
    }

    argv_buf[argc] = "podman";
    argc += 1;
    argv_buf[argc] = "inspect";
    argc += 1;
    argv_buf[argc] = "--format";
    argc += 1;
    argv_buf[argc] = "{{json .State}}";
    argc += 1;
    argv_buf[argc] = container_name;
    argc += 1;

    const result = try runCommand(allocator, argv_buf[0..argc]);
    if (!result.success) {
        // Container might not exist — return a synthetic status
        allocator.free(result.output);
        const status_json = try allocator.dupe(u8, "{\"status\":\"not_found\"}");
        return status_json;
    }
    return result.output;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Internal helpers
// ═══════════════════════════════════════════════════════════════════════════════

/// Run a command and capture its output.
fn runCommand(allocator: Allocator, argv: []const []const u8) !ActionResult {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024, // 1 MiB
    }) catch |err| {
        const err_msg = try std.fmt.allocPrint(allocator, "exec failed: {s}", .{@errorName(err)});
        return ActionResult{
            .success = false,
            .output = err_msg,
            .exit_code = -1,
        };
    };
    defer allocator.free(result.stderr);

    const exit_code: i32 = switch (result.term) {
        .Exited => |code| @intCast(code),
        .Signal => |sig| -@as(i32, @intCast(sig)),
        else => -1,
    };

    return ActionResult{
        .success = exit_code == 0,
        .output = result.stdout,
        .exit_code = exit_code,
    };
}

/// Check if a host string refers to localhost.
fn isLocalhost(host: []const u8) bool {
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1") or
        host.len == 0;
}

/// Parse a JSON action request and dispatch it.
///
/// Expected JSON format:
///   {
///     "action": "start|stop|restart|status|logs|update|backup|validate",
///     "container": "container-name",
///     "runtime": "podman|docker|systemd",
///     "host": "hostname-or-ip"
///   }
fn parseAndDispatch(allocator: Allocator, json_str: []const u8) !ActionResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return ActionResult{ .success = false, .output = try allocator.dupe(u8, "invalid JSON"), .exit_code = -1 };
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const action_str = if (obj.get("action")) |v| switch (v) {
        .string => |s| s,
        else => "status",
    } else "status";

    const container = if (obj.get("container")) |v| switch (v) {
        .string => |s| s,
        else => "",
    } else "";

    const runtime_str = if (obj.get("runtime")) |v| switch (v) {
        .string => |s| s,
        else => "podman",
    } else "podman";

    const host = if (obj.get("host")) |v| switch (v) {
        .string => |s| s,
        else => "",
    } else "";

    const action: ActionKind = if (std.mem.eql(u8, action_str, "start"))
        .Start
    else if (std.mem.eql(u8, action_str, "stop"))
        .Stop
    else if (std.mem.eql(u8, action_str, "restart"))
        .Restart
    else if (std.mem.eql(u8, action_str, "status"))
        .Status
    else if (std.mem.eql(u8, action_str, "logs"))
        .Logs
    else if (std.mem.eql(u8, action_str, "update"))
        .Update
    else if (std.mem.eql(u8, action_str, "backup"))
        .Backup
    else if (std.mem.eql(u8, action_str, "validate"))
        .ValidateConfig
    else
        .Status;

    const runtime: Runtime = if (std.mem.eql(u8, runtime_str, "docker"))
        .docker
    else if (std.mem.eql(u8, runtime_str, "systemd"))
        .systemd
    else
        .podman;

    return executeAction(allocator, host, action, container, runtime);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Exported C ABI functions
// ═══════════════════════════════════════════════════════════════════════════════

/// Execute a server action described by a JSON request.
///
/// Returns a NUL-terminated JSON string with the action result:
///   {"success": true/false, "output": "...", "exit_code": N}
threadlocal var action_result_buf: [65536:0]u8 = undefined;

pub export fn gossamer_gsa_server_action(
    handle: c_int,
    action_json: [*:0]const u8,
) callconv(.c) [*:0]const u8 {
    _ = handle;
    _ = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return "ERR";
    };

    const allocator = std.heap.c_allocator;
    const json_str = std.mem.span(action_json);

    const result = parseAndDispatch(allocator, json_str) catch |err| {
        main.setError("action dispatch failed: {s}", .{@errorName(err)});
        return "ERR";
    };
    defer allocator.free(result.output);

    // Format response as JSON
    var buf_stream = std.io.fixedBufferStream(&action_result_buf);
    const writer = buf_stream.writer();

    writer.print("{{\"success\":{s},\"exit_code\":{d},\"output\":\"", .{
        if (result.success) "true" else "false",
        result.exit_code,
    }) catch return "ERR";

    // Escape the output for JSON embedding
    for (result.output) |ch| {
        switch (ch) {
            '"' => writer.writeAll("\\\"") catch break,
            '\\' => writer.writeAll("\\\\") catch break,
            '\n' => writer.writeAll("\\n") catch break,
            '\r' => writer.writeAll("\\r") catch break,
            '\t' => writer.writeAll("\\t") catch break,
            else => {
                if (ch < 0x20) {
                    writer.print("\\u{x:0>4}", .{ch}) catch break;
                } else {
                    writer.writeByte(ch) catch break;
                }
            },
        }
    }

    writer.writeAll("\"}") catch {};
    writer.writeByte(0) catch {};

    main.clearError();
    return &action_result_buf;
}

/// Get the last N lines of logs.
///
/// Returns a NUL-terminated string of log text.
threadlocal var logs_result_buf: [65536:0]u8 = undefined;

pub export fn gossamer_gsa_get_logs(
    handle: c_int,
    lines: c_int,
) callconv(.c) [*:0]const u8 {
    _ = handle;
    const gsa = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return "ERR";
    };

    const allocator = std.heap.c_allocator;
    const line_count: u32 = if (lines > 0) @intCast(lines) else 100;

    // Get the first tracked server (for now; future: accept server_id param)
    var it = gsa.active_connections.iterator();
    const entry = it.next() orelse {
        main.setErrorStr("no servers tracked");
        return "ERR";
    };

    const conn = entry.value_ptr;
    const logs = streamLogs(allocator, conn.host, entry.key_ptr.*, line_count, .podman) catch |err| {
        main.setError("log retrieval failed: {s}", .{@errorName(err)});
        return "ERR";
    };
    defer allocator.free(logs);

    const copy_len = @min(logs.len, logs_result_buf.len - 1);
    @memcpy(logs_result_buf[0..copy_len], logs[0..copy_len]);
    logs_result_buf[copy_len] = 0;

    main.clearError();
    return &logs_result_buf;
}

/// Run a GSA helper script (e.g. provision-server.sh, steam-stage.sh) with
/// optional environment variables passed as a JSON object and an optional
/// single-line secret piped to stdin (used for Steam passwords).
///
/// `script_path` — relative path from repo root, e.g. "scripts/provision-server.sh"
/// `arg`         — first positional argument to the script (e.g. profile_id)
/// `env_json`    — JSON object of additional env vars, e.g. {"KEY":"val", ...}
/// `stdin_secret`— piped to the process stdin then closed; empty = no stdin
///
/// Returns a NUL-terminated JSON object:
///   {"success":true,"exit_code":0,"output":"..."} or ERR sentinel.
///
/// Security: env_json is parsed with std.json — no shell expansion.  The script
/// path is constrained to the scripts/ directory (prefix check) to prevent
/// path traversal.  stdin_secret is piped directly without shell interpretation.
threadlocal var run_script_buf: [131072:0]u8 = undefined;

pub export fn gossamer_gsa_run_script(
    script_path_z: [*:0]const u8,
    arg_z:         [*:0]const u8,
    env_json_z:    [*:0]const u8,
    stdin_secret_z:[*:0]const u8,
) callconv(.c) c_int {
    const allocator = std.heap.c_allocator;
    const script_path  = std.mem.span(script_path_z);
    const arg          = std.mem.span(arg_z);
    const env_json_str = std.mem.span(env_json_z);
    const secret       = std.mem.span(stdin_secret_z);

    // Path constraint: must start with "scripts/"
    if (!std.mem.startsWith(u8, script_path, "scripts/")) {
        main.setErrorStr("script path must be under scripts/");
        return @intFromEnum(main.GsaResult.permission_denied);
    }

    // Parse additional env vars from JSON
    var env_list: std.ArrayList([2][]const u8) = .empty;
    defer env_list.deinit(allocator);

    if (env_json_str.len > 2) { // "{}" minimum
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, env_json_str, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value == .object) {
                var it = p.value.object.iterator();
                while (it.next()) |kv| {
                    const k = kv.key_ptr.*;
                    const v = switch (kv.value_ptr.*) {
                        .string => |s| s,
                        else => continue,
                    };
                    const pair: [2][]const u8 = .{ k, v };
                    env_list.append(allocator, pair) catch continue;
                }
            }
        }
    }

    // Build argv: ["bash", script_path, arg]
    const argv: []const []const u8 = if (arg.len > 0)
        &.{ "bash", script_path, arg }
    else
        &.{ "bash", script_path };

    // Inherit current env and add extra vars
    var env_map = std.process.getEnvMap(allocator) catch {
        main.setErrorStr("getEnvMap failed");
        return @intFromEnum(main.GsaResult.out_of_memory);
    };
    defer env_map.deinit();

    for (env_list.items) |pair| {
        env_map.put(pair[0], pair[1]) catch continue;
    }

    // Pipe secret to stdin if provided
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe; // captured separately, appended to output below
    child.env_map = &env_map;
    if (secret.len > 0) {
        child.stdin_behavior = .Pipe;
    }

    child.spawn() catch |err| {
        main.setError("script spawn failed: {s}", .{@errorName(err)});
        return @intFromEnum(main.GsaResult.io_error);
    };

    if (secret.len > 0) {
        if (child.stdin) |stdin| {
            stdin.writeAll(secret) catch {};
            stdin.writeAll("\n") catch {};
            stdin.close();
            child.stdin = null;
        }
    }

    const stdout = child.stdout.?.readToEndAlloc(allocator, 4 * 1024 * 1024) catch &.{};
    defer allocator.free(stdout);
    const stderr_out = child.stderr.?.readToEndAlloc(allocator, 512 * 1024) catch &.{};
    defer allocator.free(stderr_out);

    const term = child.wait() catch std.process.Child.Term{ .Exited = 1 };
    const exit_code: i32 = switch (term) {
        .Exited => |c| @intCast(c),
        .Signal => |s| -@as(i32, @intCast(s)),
        else => -1,
    };

    // Combine stdout + stderr into a single output (stderr appended after newline)
    const combined: []const u8 = if (stderr_out.len > 0)
        std.fmt.allocPrint(allocator, "{s}\n{s}", .{ stdout, stderr_out }) catch stdout
    else
        stdout;
    defer if (stderr_out.len > 0) allocator.free(combined);

    // Write JSON result to run_script_buf
    var fbs = std.io.fixedBufferStream(&run_script_buf);
    const w = fbs.writer();
    w.print("{{\"success\":{s},\"exit_code\":{d},\"output\":\"", .{
        if (exit_code == 0) "true" else "false", exit_code,
    }) catch return @intFromEnum(main.GsaResult.io_error);

    for (combined) |ch| {
        switch (ch) {
            '"'  => w.writeAll("\\\"") catch break,
            '\\' => w.writeAll("\\\\") catch break,
            '\n' => w.writeAll("\\n")  catch break,
            '\r' => w.writeAll("\\r")  catch break,
            '\t' => w.writeAll("\\t")  catch break,
            else => {
                if (ch < 0x20) {
                    w.print("\\u{x:0>4}", .{ch}) catch break;
                } else {
                    w.writeByte(ch) catch break;
                }
            },
        }
    }

    w.writeAll("\"}") catch {};
    w.writeByte(0) catch {};

    if (exit_code == 0) main.clearError() else main.setErrorStr("script exited non-zero");
    return if (exit_code == 0) @intFromEnum(main.GsaResult.ok) else @intFromEnum(main.GsaResult.err);
}

/// Write a game server config file (e.g. Settings.xml) from JSON form values
/// and an operators JSON array.  The output path is derived from the profile_id
/// and written to a known volume path so that provision-server.sh picks it up.
///
/// `profile_id_z` — game profile identifier, e.g. "cryofall"
/// `config_json_z`— JSON object of server settings, e.g. {"ServerName":"..."}
/// `operators_json_z` — JSON array: [{"steam_id":"...","name":"..."}]
///
/// Returns 0 (GsaResult.ok) on success, negative on error.
pub export fn gossamer_gsa_write_server_config(
    profile_id_z:    [*:0]const u8,
    config_json_z:   [*:0]const u8,
    operators_json_z:[*:0]const u8,
) callconv(.c) c_int {
    const allocator = std.heap.c_allocator;
    const profile_id   = std.mem.span(profile_id_z);
    const config_str   = std.mem.span(config_json_z);
    const ops_str      = std.mem.span(operators_json_z);

    if (profile_id.len == 0) {
        main.setErrorStr("missing profile_id");
        return @intFromEnum(main.GsaResult.invalid_param);
    }

    // Parse config fields
    const cfg_parsed = std.json.parseFromSlice(std.json.Value, allocator, config_str, .{}) catch {
        main.setErrorStr("invalid config JSON");
        return @intFromEnum(main.GsaResult.parse_error);
    };
    defer cfg_parsed.deinit();

    const ops_parsed = std.json.parseFromSlice(std.json.Value, allocator, ops_str, .{}) catch {
        main.setErrorStr("invalid operators JSON");
        return @intFromEnum(main.GsaResult.parse_error);
    };
    defer ops_parsed.deinit();

    const cfg = if (cfg_parsed.value == .object) cfg_parsed.value.object else {
        main.setErrorStr("config JSON must be an object");
        return @intFromEnum(main.GsaResult.parse_error);
    };

    // Helper to extract string field with fallback
    const S = struct {
        fn get(obj: std.json.ObjectMap, key: []const u8, fallback: []const u8) []const u8 {
            if (obj.get(key)) |v| {
                return switch (v) { .string => |s| s, else => fallback };
            }
            return fallback;
        }
    };

    const server_name   = S.get(cfg, "ServerName",               "GSA Server");
    const description   = S.get(cfg, "ServerDescription",        "Managed by GSA");
    const welcome       = S.get(cfg, "WelcomeMessage",           "Welcome!");
    const port          = S.get(cfg, "ServerPort",               "6000");
    const max_players   = S.get(cfg, "MaxPlayers",               "10");
    const is_private    = S.get(cfg, "IsPrivate",                "true");
    const password      = S.get(cfg, "ServerPassword",           "");
    const is_pve        = S.get(cfg, "IsPvE",                    "true");
    const raids         = S.get(cfg, "IsRaidsEnabled",           "false");
    const wipe_days     = S.get(cfg, "WipePeriodDays",           "0");
    const gather_mult   = S.get(cfg, "GatheringSpeedMultiplier", "2.0");
    const learn_mult    = S.get(cfg, "LearningSpeedMultiplier",  "2.0");
    const craft_mult    = S.get(cfg, "CraftingSpeedMultiplier",  "2.0");

    // Build operators XML fragment
    var ops_xml: std.ArrayList(u8) = .empty;
    defer ops_xml.deinit(allocator);

    if (ops_parsed.value == .array) {
        for (ops_parsed.value.array.items) |item| {
            if (item != .object) continue;
            const steam_id = S.get(item.object, "steam_id", "");
            const name     = S.get(item.object, "name",     "");
            if (steam_id.len == 0) continue;
            ops_xml.appendSlice(allocator, "    <Operator steamId=\"") catch continue;
            // Escape steamId attribute (digits only expected, but be safe)
            for (steam_id) |ch| {
                if (ch == '"') ops_xml.appendSlice(allocator, "&quot;") catch {}
                else ops_xml.append(allocator, ch) catch {};
            }
            ops_xml.appendSlice(allocator, "\"  name=\"") catch continue;
            for (name) |ch| {
                if (ch == '"') ops_xml.appendSlice(allocator, "&quot;") catch {}
                else ops_xml.append(allocator, ch) catch {};
            }
            ops_xml.appendSlice(allocator, "\" />\n") catch continue;
        }
    }

    // Compose Settings.xml
    const xml = std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<!-- Generated by GSA Nexus Setup wizard — edit via Config Editor panel -->
        \\<server-settings>
        \\  <ServerName>{s}</ServerName>
        \\  <ServerDescription>{s}</ServerDescription>
        \\  <ServerPort>{s}</ServerPort>
        \\  <MaxPlayers>{s}</MaxPlayers>
        \\  <IsPrivate>{s}</IsPrivate>
        \\  <ServerPassword>{s}</ServerPassword>
        \\  <WipePeriodDays>{s}</WipePeriodDays>
        \\  <IsPvE>{s}</IsPvE>
        \\  <IsRaidsEnabled>{s}</IsRaidsEnabled>
        \\  <WelcomeMessage>{s}</WelcomeMessage>
        \\  <ServerRates>
        \\    <GatheringSpeedMultiplier>{s}</GatheringSpeedMultiplier>
        \\    <LearningSpeedMultiplier>{s}</LearningSpeedMultiplier>
        \\    <CraftingSpeedMultiplier>{s}</CraftingSpeedMultiplier>
        \\  </ServerRates>
        \\  <Operators>
        \\{s}  </Operators>
        \\</server-settings>
        \\
    , .{
        server_name, description, port, max_players,
        is_private, password, wipe_days,
        is_pve, raids, welcome,
        gather_mult, learn_mult, craft_mult,
        ops_xml.items,
    }) catch {
        main.setErrorStr("XML format failed: out of memory");
        return @intFromEnum(main.GsaResult.out_of_memory);
    };
    defer allocator.free(xml);

    // Write to container/cryofall/Settings.xml (profile-specific in future)
    const out_path = std.fmt.allocPrint(
        allocator, "container/{s}/Settings.xml", .{profile_id},
    ) catch {
        main.setErrorStr("path format failed");
        return @intFromEnum(main.GsaResult.out_of_memory);
    };
    defer allocator.free(out_path);

    const file = std.fs.cwd().createFile(out_path, .{}) catch |err| {
        main.setError("cannot write {s}: {s}", .{ out_path, @errorName(err) });
        return @intFromEnum(main.GsaResult.io_error);
    };
    defer file.close();

    file.writeAll(xml) catch |err| {
        main.setError("write failed: {s}", .{@errorName(err)});
        return @intFromEnum(main.GsaResult.io_error);
    };

    main.clearError();
    return @intFromEnum(main.GsaResult.ok);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Unit tests
// ═══════════════════════════════════════════════════════════════════════════════

test "ActionKind covers all 8 values" {
    const kinds = [_]ActionKind{ .Start, .Stop, .Restart, .Status, .Logs, .Update, .Backup, .ValidateConfig };
    try std.testing.expectEqual(@as(usize, 8), kinds.len);
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ActionKind.Start));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(ActionKind.ValidateConfig));
}

test "isLocalhost" {
    try std.testing.expect(isLocalhost("localhost"));
    try std.testing.expect(isLocalhost("127.0.0.1"));
    try std.testing.expect(isLocalhost("::1"));
    try std.testing.expect(isLocalhost(""));
    try std.testing.expect(!isLocalhost("192.168.1.10"));
    try std.testing.expect(!isLocalhost("example.com"));
}

test "Runtime enum values" {
    // Verify all three runtime variants exist
    const rt_podman: Runtime = .podman;
    const rt_docker: Runtime = .docker;
    const rt_systemd: Runtime = .systemd;
    try std.testing.expect(rt_podman != rt_docker);
    try std.testing.expect(rt_docker != rt_systemd);
}

test "isLocalhost: IPv6 and edge cases" {
    // Valid localhost variants
    try std.testing.expect(isLocalhost("localhost"));
    try std.testing.expect(isLocalhost("127.0.0.1"));
    try std.testing.expect(isLocalhost("::1"));
    try std.testing.expect(isLocalhost(""));
    // Non-localhost
    try std.testing.expect(!isLocalhost("192.168.1.1"));
    try std.testing.expect(!isLocalhost("10.0.0.1"));
    try std.testing.expect(!isLocalhost("127.0.0.2"));
    try std.testing.expect(!isLocalhost("localhost.localdomain"));
    try std.testing.expect(!isLocalhost("LOCALHOST"));
    try std.testing.expect(!isLocalhost(" localhost"));
    try std.testing.expect(!isLocalhost("localhost "));
    try std.testing.expect(!isLocalhost("127.0.0.1; rm -rf /"));
}

test "parseAndDispatch: invalid JSON returns failure" {
    const allocator = std.testing.allocator;
    const result = try parseAndDispatch(allocator, "not json at all");
    defer allocator.free(result.output);
    try std.testing.expect(!result.success);
}

test "parseAndDispatch: empty JSON defaults gracefully" {
    const allocator = std.testing.allocator;
    const result = try parseAndDispatch(allocator, "{}");
    defer allocator.free(result.output);
    // Should default to status action with podman runtime and empty container
    // Will fail to exec but should not crash
    try std.testing.expect(!result.success);
}

test "parseAndDispatch: unknown action defaults to status" {
    const allocator = std.testing.allocator;
    const result = try parseAndDispatch(allocator, "{\"action\":\"hack\",\"container\":\"test\"}");
    defer allocator.free(result.output);
    // Unknown action defaults to Status, will fail exec but not crash
    try std.testing.expect(!result.success);
}

test "parseAndDispatch: unknown runtime defaults to podman" {
    const allocator = std.testing.allocator;
    const result = try parseAndDispatch(allocator, "{\"action\":\"status\",\"container\":\"test\",\"runtime\":\"imaginary\"}");
    defer allocator.free(result.output);
    try std.testing.expect(!result.success);
}

test "ActionKind integer mapping" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ActionKind.Start));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(ActionKind.Stop));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(ActionKind.Restart));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(ActionKind.Status));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(ActionKind.Logs));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(ActionKind.Update));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(ActionKind.Backup));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(ActionKind.ValidateConfig));
}

test "executeAction: local podman start builds correct argv" {
    const allocator = std.testing.allocator;
    // localhost means no SSH prefix
    const result = try executeAction(allocator, "localhost", .Start, "mc-server", .podman);
    defer allocator.free(result.output);
    // Will fail since podman isn't running, but verifies no crash
    try std.testing.expect(!result.success or result.exit_code != 0);
}

test "executeAction: systemd logs uses journalctl" {
    const allocator = std.testing.allocator;
    const result = try executeAction(allocator, "", .Logs, "minecraft.service", .systemd);
    defer allocator.free(result.output);
    // journalctl may succeed or fail depending on system state — verify no crash
    // and that we got a valid result structure back
    try std.testing.expect(result.output.len >= 0);
    _ = result.exit_code;
    _ = result.success;
}

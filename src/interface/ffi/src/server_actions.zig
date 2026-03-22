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

/// Run an arbitrary command via SSH on a remote host.
///
/// Returns the combined stdout output and exit code.
pub fn executeSSH(
    allocator: Allocator,
    host: []const u8,
    user: []const u8,
    command: []const u8,
) !ActionResult {
    var target_buf: [512]u8 = undefined;
    const target = std.fmt.bufPrint(&target_buf, "{s}@{s}", .{ user, host }) catch return error.InvalidParam;

    return runCommand(allocator, &.{
        "ssh",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "ConnectTimeout=10",
        target,
        command,
    });
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
threadlocal var action_result_buf: [65536]u8 = undefined;

export fn gossamer_gsa_server_action(
    handle: c_int,
    action_json: [*:0]const u8,
) callconv(.C) [*:0]const u8 {
    _ = handle;
    _ = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return @as([*:0]const u8, @ptrCast(&[_:0]u8{ 'E', 'R', 'R' }));
    };

    const allocator = std.heap.c_allocator;
    const json_str = std.mem.span(action_json);

    const result = parseAndDispatch(allocator, json_str) catch |err| {
        main.setError("action dispatch failed: {s}", .{@errorName(err)});
        return @as([*:0]const u8, @ptrCast(&[_:0]u8{ 'E', 'R', 'R' }));
    };
    defer allocator.free(result.output);

    // Format response as JSON
    var buf_stream = std.io.fixedBufferStream(&action_result_buf);
    const writer = buf_stream.writer();

    writer.print("{{\"success\":{s},\"exit_code\":{d},\"output\":\"", .{
        if (result.success) "true" else "false",
        result.exit_code,
    }) catch return @as([*:0]const u8, @ptrCast(&[_:0]u8{ 'E', 'R', 'R' }));

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
    return @as([*:0]const u8, @ptrCast(&action_result_buf));
}

/// Get the last N lines of logs.
///
/// Returns a NUL-terminated string of log text.
threadlocal var logs_result_buf: [65536]u8 = undefined;

export fn gossamer_gsa_get_logs(
    handle: c_int,
    lines: c_int,
) callconv(.C) [*:0]const u8 {
    _ = handle;
    const gsa = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return @as([*:0]const u8, @ptrCast(&[_:0]u8{ 'E', 'R', 'R' }));
    };

    const allocator = std.heap.c_allocator;
    const line_count: u32 = if (lines > 0) @intCast(lines) else 100;

    // Get the first tracked server (for now; future: accept server_id param)
    var it = gsa.active_connections.iterator();
    const entry = it.next() orelse {
        main.setErrorStr("no servers tracked");
        return @as([*:0]const u8, @ptrCast(&[_:0]u8{ 'E', 'R', 'R' }));
    };

    const conn = entry.value_ptr;
    const logs = streamLogs(allocator, conn.host, entry.key_ptr.*, line_count, .podman) catch |err| {
        main.setError("log retrieval failed: {s}", .{@errorName(err)});
        return @as([*:0]const u8, @ptrCast(&[_:0]u8{ 'E', 'R', 'R' }));
    };
    defer allocator.free(logs);

    const copy_len = @min(logs.len, logs_result_buf.len - 1);
    @memcpy(logs_result_buf[0..copy_len], logs[0..copy_len]);
    logs_result_buf[copy_len] = 0;

    main.clearError();
    return @as([*:0]const u8, @ptrCast(&logs_result_buf));
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

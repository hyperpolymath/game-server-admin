// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — Groove protocol client for Burble voice alerting
//
// Implements the Groove capability discovery protocol to find Burble
// and Vext endpoints on the local network, then sends voice alerts
// when server health thresholds are exceeded.
//
// Groove is a .well-known service discovery protocol:
//   GET /.well-known/groove   — capability discovery
//   POST /.well-known/groove/message — send alert message
//   POST /.well-known/groove/tts     — text-to-speech alert
//
// Default endpoints:
//   Burble: localhost:6473
//   Vext:   localhost:6480
//
// IMPORTANT: This module does NOT store any data in VeriSimDB.
// Groove is a transient protocol — alerts are fire-and-forget.

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;
const main = @import("main.zig");

// ═══════════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════════

/// Well-known path for Groove capability discovery.
const GROOVE_DISCOVERY_PATH: []const u8 = "/.well-known/groove";

/// Well-known path for sending alert messages via Groove.
const GROOVE_MESSAGE_PATH: []const u8 = "/.well-known/groove/message";

/// Well-known path for text-to-speech alerts via Groove.
const GROOVE_TTS_PATH: []const u8 = "/.well-known/groove/tts";

/// Maximum number of Groove targets we track simultaneously.
const MAX_TARGETS: usize = 8;

/// HTTP timeout for Groove probes (milliseconds).
const GROOVE_TIMEOUT_MS: u32 = 3000;

// ═══════════════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════════════

/// Alert severity levels.  Match Burble's internal severity enumeration.
pub const AlertSeverity = enum(u8) {
    info = 0,
    warning = 1,
    critical = 2,
    emergency = 3,
};

/// Status of a Groove target after discovery probe.
pub const TargetStatus = enum(u8) {
    unknown = 0,
    reachable = 1,
    not_reachable = 2,
    @"error" = 3,
};

/// A known Groove target (Burble, Vext, etc.).
pub const GrooveTarget = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    host: [256]u8 = [_]u8{0} ** 256,
    host_len: usize = 0,
    port: u16 = 0,
    status: TargetStatus = .unknown,
    supports_tts: bool = false,
    supports_message: bool = false,
    last_probe_ms: i64 = 0,

    /// Copy a slice into one of the fixed-size buffers.
    fn setBuf(dest: []u8, src: []const u8) usize {
        const copy_len = @min(src.len, dest.len);
        @memcpy(dest[0..copy_len], src[0..copy_len]);
        return copy_len;
    }

    pub fn setName(self: *GrooveTarget, n: []const u8) void {
        self.name_len = setBuf(&self.name, n);
    }

    pub fn setHost(self: *GrooveTarget, h: []const u8) void {
        self.host_len = setBuf(&self.host, h);
    }

    pub fn nameSlice(self: *const GrooveTarget) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn hostSlice(self: *const GrooveTarget) []const u8 {
        return self.host[0..self.host_len];
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Default targets — Burble and Vext
// ═══════════════════════════════════════════════════════════════════════════════

/// Pre-configured Groove targets to probe at discovery time.
const DefaultTarget = struct {
    name: []const u8,
    host: []const u8,
    port: u16,
};

const DEFAULT_TARGETS: []const DefaultTarget = &.{
    .{ .name = "burble", .host = "127.0.0.1", .port = 6473 },
    .{ .name = "vext", .host = "127.0.0.1", .port = 6480 },
};

// ═══════════════════════════════════════════════════════════════════════════════
// Groove target registry (thread-local)
// ═══════════════════════════════════════════════════════════════════════════════

/// Thread-local registry of discovered Groove targets.
threadlocal var groove_targets: [MAX_TARGETS]GrooveTarget = [_]GrooveTarget{.{}} ** MAX_TARGETS;
threadlocal var groove_target_count: usize = 0;

/// Find a target by name in the registry.
fn findTarget(name: []const u8) ?*GrooveTarget {
    for (groove_targets[0..groove_target_count]) |*target| {
        if (std.mem.eql(u8, target.nameSlice(), name)) {
            return target;
        }
    }
    return null;
}

/// Add or update a target in the registry.
fn upsertTarget(name: []const u8, host: []const u8, port: u16) *GrooveTarget {
    if (findTarget(name)) |existing| {
        existing.setHost(host);
        existing.port = port;
        return existing;
    }

    if (groove_target_count < MAX_TARGETS) {
        var target = &groove_targets[groove_target_count];
        target.* = .{};
        target.setName(name);
        target.setHost(host);
        target.port = port;
        groove_target_count += 1;
        return target;
    }

    // Registry full — overwrite the last slot
    var target = &groove_targets[MAX_TARGETS - 1];
    target.* = .{};
    target.setName(name);
    target.setHost(host);
    target.port = port;
    return target;
}

// ═══════════════════════════════════════════════════════════════════════════════
// HTTP helpers
// ═══════════════════════════════════════════════════════════════════════════════

/// Perform an HTTP GET against a Groove endpoint.
/// Returns the response body as an owned slice, or error.
fn grooveGet(
    allocator: Allocator,
    host: []const u8,
    port: u16,
    path: []const u8,
) ![]const u8 {
    var url_buf: [512]u8 = undefined;
    const url_str = std.fmt.bufPrint(&url_buf, "http://{s}:{d}{s}", .{ host, port, path }) catch return error.URLTooLong;

    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    errdefer alloc_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url_str },
        .method = .GET,
        .extra_headers = &.{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "User-Agent", .value = "GSA-Groove/0.1.0" },
        },
        .response_writer = &alloc_writer.writer,
    });

    if (result.status != .ok) {
        alloc_writer.deinit();
        return error.HTTPError;
    }

    var list = alloc_writer.toArrayList();
    return list.toOwnedSlice(allocator);
}

/// Perform an HTTP POST against a Groove endpoint with a JSON body.
/// Returns the response body as an owned slice, or error.
fn groovePost(
    allocator: Allocator,
    host: []const u8,
    port: u16,
    path: []const u8,
    body: []const u8,
) ![]const u8 {
    var url_buf: [512]u8 = undefined;
    const url_str = std.fmt.bufPrint(&url_buf, "http://{s}:{d}{s}", .{ host, port, path }) catch return error.URLTooLong;

    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    errdefer alloc_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url_str },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "User-Agent", .value = "GSA-Groove/0.1.0" },
        },
        .response_writer = &alloc_writer.writer,
    });

    if (result.status != .ok and result.status != .created and result.status != .accepted) {
        alloc_writer.deinit();
        return error.HTTPError;
    }

    var list = alloc_writer.toArrayList();
    return list.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Discovery — probe a single Groove target
// ═══════════════════════════════════════════════════════════════════════════════

/// Probe a single target's /.well-known/groove endpoint.
/// Parses the capability response and updates the target record.
fn probeTarget(target: *GrooveTarget) void {
    const allocator = std.heap.c_allocator;
    const host = target.hostSlice();

    const response = grooveGet(allocator, host, target.port, GROOVE_DISCOVERY_PATH) catch {
        target.status = .not_reachable;
        target.last_probe_ms = std.time.milliTimestamp();
        return;
    };
    defer allocator.free(response);

    // Parse capability flags from the JSON response.
    // Expected format: {"service":"burble","capabilities":["message","tts",...]}
    target.supports_message = std.mem.indexOf(u8, response, "\"message\"") != null;
    target.supports_tts = std.mem.indexOf(u8, response, "\"tts\"") != null;
    target.status = .reachable;
    target.last_probe_ms = std.time.milliTimestamp();
}

// ═══════════════════════════════════════════════════════════════════════════════
// Alert sending
// ═══════════════════════════════════════════════════════════════════════════════

/// Send a structured alert message to a Groove target.
///
/// The JSON payload conforms to the Groove message schema:
///   {"source": "gsa", "severity": "warning", "server_id": "...", "message": "..."}
fn sendAlert(
    target: *const GrooveTarget,
    severity: AlertSeverity,
    server_id: []const u8,
    message: []const u8,
) main.GsaResult {
    if (target.status != .reachable or !target.supports_message) {
        main.setErrorStr("groove target not reachable or lacks message capability");
        return .connection_refused;
    }

    const allocator = std.heap.c_allocator;
    const host = target.hostSlice();

    // Build JSON payload
    var body_buf: [2048]u8 = undefined;
    const severity_str: []const u8 = switch (severity) {
        .info => "info",
        .warning => "warning",
        .critical => "critical",
        .emergency => "emergency",
    };

    const body = std.fmt.bufPrint(&body_buf, "{{\"source\":\"gsa\",\"severity\":\"{s}\",\"server_id\":\"{s}\",\"message\":\"{s}\"}}", .{
        severity_str,
        server_id,
        message,
    }) catch {
        main.setErrorStr("alert payload too large");
        return .err;
    };

    const response = groovePost(allocator, host, target.port, GROOVE_MESSAGE_PATH, body) catch |err| {
        main.setError("groove alert failed: {s}", .{@errorName(err)});
        return .connection_refused;
    };
    allocator.free(response);

    return .ok;
}

/// Send a text-to-speech alert to a Groove target.
///
/// The JSON payload conforms to the Groove TTS schema:
///   {"source": "gsa", "text": "...", "priority": "high"}
fn sendTTSAlert(
    target: *const GrooveTarget,
    text: []const u8,
) main.GsaResult {
    if (target.status != .reachable or !target.supports_tts) {
        main.setErrorStr("groove target not reachable or lacks TTS capability");
        return .connection_refused;
    }

    const allocator = std.heap.c_allocator;
    const host = target.hostSlice();

    var body_buf: [2048]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"source\":\"gsa\",\"text\":\"{s}\",\"priority\":\"high\"}}", .{text}) catch {
        main.setErrorStr("TTS payload too large");
        return .err;
    };

    const response = groovePost(allocator, host, target.port, GROOVE_TTS_PATH, body) catch |err| {
        main.setError("groove TTS failed: {s}", .{@errorName(err)});
        return .connection_refused;
    };
    allocator.free(response);

    return .ok;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Exported C ABI functions
// ═══════════════════════════════════════════════════════════════════════════════

/// Discover all Groove targets (Burble, Vext, etc.).
///
/// Probes the default endpoints and populates the internal target registry.
/// Call this once at startup or when re-discovering services.
///
/// Returns 0 on success (at least one target reachable), or a GsaResult
/// error code if no targets are reachable.
pub export fn gossamer_gsa_groove_discover() callconv(.c) c_int {
    _ = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return @intFromEnum(main.GsaResult.not_initialized);
    };

    // Reset and populate from defaults
    groove_target_count = 0;
    for (DEFAULT_TARGETS) |dt| {
        const target = upsertTarget(dt.name, dt.host, dt.port);
        probeTarget(target);
    }

    // Check if at least one target is reachable
    var any_reachable = false;
    for (groove_targets[0..groove_target_count]) |target| {
        if (target.status == .reachable) {
            any_reachable = true;
            break;
        }
    }

    if (any_reachable) {
        main.clearError();
        return @intFromEnum(main.GsaResult.ok);
    } else {
        main.setErrorStr("no groove targets reachable");
        return @intFromEnum(main.GsaResult.connection_refused);
    }
}

/// Get the status of a specific Groove target as a JSON string.
///
/// `target_name` — name of the target (e.g. "burble", "vext").
///
/// Returns a NUL-terminated JSON string with the target status.
/// The pointer is valid until the next call on the same thread.
threadlocal var groove_status_buf: [1024]u8 = undefined;

pub export fn gossamer_gsa_groove_status(
    target_name: [*:0]const u8,
) callconv(.c) [*:0]const u8 {
    const name = std.mem.span(target_name);

    const target = findTarget(name) orelse {
        main.setError("groove target not found: {s}", .{name});
        // Return a valid JSON error string
        const err_json = "{\"status\":\"unknown\",\"name\":\"" ++ "";
        _ = err_json;
        var stream = std.io.fixedBufferStream(&groove_status_buf);
        stream.writer().print("{{\"status\":\"unknown\",\"name\":\"{s}\",\"reachable\":false}}", .{name}) catch {};
        stream.writer().writeByte(0) catch {};
        return @as([*:0]const u8, @ptrCast(&groove_status_buf));
    };

    const status_str: []const u8 = switch (target.status) {
        .unknown => "unknown",
        .reachable => "reachable",
        .not_reachable => "unreachable",
        .@"error" => "error",
    };

    var stream = std.io.fixedBufferStream(&groove_status_buf);
    stream.writer().print(
        "{{\"name\":\"{s}\",\"host\":\"{s}\",\"port\":{d},\"status\":\"{s}\",\"supports_tts\":{s},\"supports_message\":{s},\"last_probe_ms\":{d}}}",
        .{
            target.nameSlice(),
            target.hostSlice(),
            target.port,
            status_str,
            if (target.supports_tts) "true" else "false",
            if (target.supports_message) "true" else "false",
            target.last_probe_ms,
        },
    ) catch {};
    stream.writer().writeByte(0) catch {};

    return @as([*:0]const u8, @ptrCast(&groove_status_buf));
}

/// Send an alert message to the first reachable Groove target (Burble preferred).
///
/// `severity`  — 0=info, 1=warning, 2=critical, 3=emergency
/// `server_id` — the GSA server ID that triggered the alert
/// `message`   — human-readable alert description
///
/// Returns 0 on success, negative GsaResult on failure.
pub export fn gossamer_gsa_groove_alert(
    severity: c_int,
    server_id: [*:0]const u8,
    message: [*:0]const u8,
) callconv(.c) c_int {
    _ = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return @intFromEnum(main.GsaResult.not_initialized);
    };

    const sev: AlertSeverity = switch (severity) {
        0 => .info,
        1 => .warning,
        2 => .critical,
        3 => .emergency,
        else => .warning,
    };

    const sid = std.mem.span(server_id);
    const msg = std.mem.span(message);

    // Try Burble first, then any reachable target
    if (findTarget("burble")) |burble| {
        if (burble.status == .reachable) {
            const result = sendAlert(burble, sev, sid, msg);
            if (result == .ok) {
                main.clearError();
                return @intFromEnum(main.GsaResult.ok);
            }
        }
    }

    // Fall back to any reachable target with message capability
    for (groove_targets[0..groove_target_count]) |*target| {
        if (target.status == .reachable and target.supports_message) {
            const result = sendAlert(target, sev, sid, msg);
            if (result == .ok) {
                main.clearError();
                return @intFromEnum(main.GsaResult.ok);
            }
        }
    }

    main.setErrorStr("no groove targets available for alerting");
    return @intFromEnum(main.GsaResult.connection_refused);
}

/// Send a text-to-speech alert to the first reachable Groove target with
/// TTS capability (Burble preferred).
///
/// `text` — the text to be spoken by Burble's TTS engine.
///
/// Returns 0 on success, negative GsaResult on failure.
pub export fn gossamer_gsa_groove_tts_alert(
    text: [*:0]const u8,
) callconv(.c) c_int {
    _ = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return @intFromEnum(main.GsaResult.not_initialized);
    };

    const tts_text = std.mem.span(text);

    // Try Burble first (it is the primary TTS provider)
    if (findTarget("burble")) |burble| {
        if (burble.status == .reachable and burble.supports_tts) {
            const result = sendTTSAlert(burble, tts_text);
            if (result == .ok) {
                main.clearError();
                return @intFromEnum(main.GsaResult.ok);
            }
        }
    }

    // Fall back to any reachable target with TTS capability
    for (groove_targets[0..groove_target_count]) |*target| {
        if (target.status == .reachable and target.supports_tts) {
            const result = sendTTSAlert(target, tts_text);
            if (result == .ok) {
                main.clearError();
                return @intFromEnum(main.GsaResult.ok);
            }
        }
    }

    main.setErrorStr("no groove targets available for TTS");
    return @intFromEnum(main.GsaResult.connection_refused);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Unit tests
// ═══════════════════════════════════════════════════════════════════════════════

test "GrooveTarget set and get" {
    var target = GrooveTarget{};
    target.setName("burble");
    target.setHost("127.0.0.1");
    target.port = 6473;

    try std.testing.expectEqualStrings("burble", target.nameSlice());
    try std.testing.expectEqualStrings("127.0.0.1", target.hostSlice());
    try std.testing.expectEqual(@as(u16, 6473), target.port);
    try std.testing.expectEqual(TargetStatus.unknown, target.status);
}

test "AlertSeverity values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(AlertSeverity.info));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(AlertSeverity.warning));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(AlertSeverity.critical));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(AlertSeverity.emergency));
}

test "default targets table" {
    try std.testing.expectEqual(@as(usize, 2), DEFAULT_TARGETS.len);
    try std.testing.expectEqualStrings("burble", DEFAULT_TARGETS[0].name);
    try std.testing.expectEqual(@as(u16, 6473), DEFAULT_TARGETS[0].port);
    try std.testing.expectEqualStrings("vext", DEFAULT_TARGETS[1].name);
    try std.testing.expectEqual(@as(u16, 6480), DEFAULT_TARGETS[1].port);
}

test "upsert and find target" {
    // Reset registry
    groove_target_count = 0;

    const target = upsertTarget("test-burble", "127.0.0.1", 6473);
    try std.testing.expectEqualStrings("test-burble", target.nameSlice());
    try std.testing.expectEqual(@as(usize, 1), groove_target_count);

    // Upsert again — should update, not add
    const same = upsertTarget("test-burble", "192.168.1.1", 7000);
    try std.testing.expectEqual(@as(usize, 1), groove_target_count);
    try std.testing.expectEqualStrings("192.168.1.1", same.hostSlice());
    try std.testing.expectEqual(@as(u16, 7000), same.port);

    // Add a different target
    _ = upsertTarget("test-vext", "127.0.0.1", 6480);
    try std.testing.expectEqual(@as(usize, 2), groove_target_count);

    // Find by name
    const found = findTarget("test-burble");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("192.168.1.1", found.?.hostSlice());

    // Not found
    try std.testing.expect(findTarget("nonexistent") == null);

    // Clean up
    groove_target_count = 0;
}

test "target registry overflow: last slot overwritten at MAX_TARGETS" {
    groove_target_count = 0;
    // Fill all 8 slots
    var i: u16 = 0;
    while (i < MAX_TARGETS) : (i += 1) {
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "target-{d}", .{i}) catch "?";
        _ = upsertTarget(name, "127.0.0.1", 6000 + i);
    }
    try std.testing.expectEqual(@as(usize, MAX_TARGETS), groove_target_count);

    // Insert one more — should overwrite last slot
    _ = upsertTarget("overflow", "10.0.0.1", 9999);
    try std.testing.expectEqual(@as(usize, MAX_TARGETS), groove_target_count);
    // Last slot should be the overflow target
    try std.testing.expectEqualStrings("overflow", groove_targets[MAX_TARGETS - 1].nameSlice());
    groove_target_count = 0;
}

test "GrooveTarget buffer truncation: oversized name and host" {
    var target = GrooveTarget{};
    // Name buffer is 64 bytes — pass 100 chars
    const long_name = "A" ** 100;
    target.setName(long_name);
    try std.testing.expectEqual(@as(usize, 64), target.name_len);

    // Host buffer is 256 bytes — pass 512 chars
    const long_host = "B" ** 512;
    target.setHost(long_host);
    try std.testing.expectEqual(@as(usize, 256), target.host_len);
}

test "TargetStatus enum has 4 variants" {
    const fields = @typeInfo(TargetStatus).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 4), fields.len);
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(TargetStatus.unknown));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(TargetStatus.reachable));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(TargetStatus.not_reachable));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(TargetStatus.@"error"));
}

test "empty name and host edge case" {
    var target = GrooveTarget{};
    try std.testing.expectEqual(@as(usize, 0), target.name_len);
    try std.testing.expectEqual(@as(usize, 0), target.host_len);
    try std.testing.expectEqualStrings("", target.nameSlice());
    try std.testing.expectEqualStrings("", target.hostSlice());
}

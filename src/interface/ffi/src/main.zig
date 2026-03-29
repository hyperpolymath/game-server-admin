// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — Core lifecycle, error handling, and exported C ABI entry
// points.  Implements the FFI surface declared in src/interface/abi/Foreign.idr.
//
// Thread-local error storage, result codes, and the GsaHandle type live here.
// Every other module imports this as its root dependency.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── sibling modules ──────────────────────────────────────────────────────────
// These are `pub const` so their `pub export fn` declarations are included
// in the shared library's symbol table.
pub const probe = @import("probe.zig");
pub const config_extract = @import("config_extract.zig");
pub const a2ml_emit = @import("a2ml_emit.zig");
pub const verisimdb_client = @import("verisimdb_client.zig");
pub const server_actions = @import("server_actions.zig");
pub const game_profiles = @import("game_profiles.zig");
pub const groove_client = @import("groove_client.zig");

// Force the linker to include all exported functions from submodules.
// Without these references, Zig's linker may dead-strip the `pub export fn`
// declarations since nothing in main.zig calls them directly.
comptime {
    _ = &probe.gossamer_gsa_probe;
    _ = &probe.gossamer_gsa_fingerprint;
    _ = &config_extract.gossamer_gsa_extract_config;
    _ = &a2ml_emit.gossamer_gsa_a2ml_emit;
    _ = &a2ml_emit.gossamer_gsa_a2ml_parse;
    _ = &verisimdb_client.gossamer_gsa_verisimdb_store;
    _ = &verisimdb_client.gossamer_gsa_verisimdb_query;
    _ = &verisimdb_client.gossamer_gsa_verisimdb_health;
    _ = &verisimdb_client.gossamer_gsa_verisimdb_drift;
    _ = &server_actions.gossamer_gsa_server_action;
    _ = &server_actions.gossamer_gsa_get_logs;
    _ = &game_profiles.gossamer_gsa_load_profiles;
    _ = &game_profiles.gossamer_gsa_list_profiles;
    _ = &game_profiles.gossamer_gsa_add_profile;
    _ = &groove_client.gossamer_gsa_groove_discover;
    _ = &groove_client.gossamer_gsa_groove_status;
    _ = &groove_client.gossamer_gsa_groove_alert;
    _ = &groove_client.gossamer_gsa_groove_tts_alert;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════════

/// Semantic version of the FFI layer — keep in sync with build.zig
pub const VERSION: [:0]const u8 = "0.1.0";

/// Human-readable build tag
pub const BUILD_INFO: [:0]const u8 = "libgsa 0.1.0 (Zig " ++ @import("builtin").zig_version_string ++ ")";

// ═══════════════════════════════════════════════════════════════════════════════
// Result codes — must match GameServerAdmin.ABI.Types.Result (Idris2)
// ═══════════════════════════════════════════════════════════════════════════════

/// FFI result codes.  The integer values are contractual; the Idris2 ABI layer
/// converts between these and the dependent-type Result via `resultToInt`.
pub const GsaResult = enum(c_int) {
    ok = 0,
    err = 1,
    invalid_param = 2,
    out_of_memory = 3,
    null_pointer = 4,
    not_initialized = 5,
    timeout = 6,
    connection_refused = 7,
    protocol_error = 8,
    parse_error = 9,
    io_error = 10,
    permission_denied = 11,
    not_found = 12,
};

// ═══════════════════════════════════════════════════════════════════════════════
// Thread-local error buffer
// ═══════════════════════════════════════════════════════════════════════════════

/// Fixed-size thread-local buffer for the last error message.
/// Callers retrieve it via `gossamer_gsa_last_error`.
threadlocal var last_error_buf: [512]u8 = [_]u8{0} ** 512;
threadlocal var last_error_len: usize = 0;

/// Write an error message into the thread-local buffer.
pub fn setError(comptime fmt: []const u8, args: anytype) void {
    var buf_stream = std.io.fixedBufferStream(&last_error_buf);
    buf_stream.writer().print(fmt, args) catch {};
    last_error_len = buf_stream.pos;
    // ensure NUL terminator
    if (last_error_len < last_error_buf.len) {
        last_error_buf[last_error_len] = 0;
    }
}

/// Write a plain string error.
pub fn setErrorStr(msg: []const u8) void {
    const copy_len = @min(msg.len, last_error_buf.len - 1);
    @memcpy(last_error_buf[0..copy_len], msg[0..copy_len]);
    last_error_buf[copy_len] = 0;
    last_error_len = copy_len;
}

/// Clear the thread-local error.
pub fn clearError() void {
    last_error_buf[0] = 0;
    last_error_len = 0;
}

// ═══════════════════════════════════════════════════════════════════════════════
// GsaHandle — opaque library state
// ═══════════════════════════════════════════════════════════════════════════════

/// Connection state for a single tracked server.
pub const ConnectionState = struct {
    host: []const u8,
    port: u16,
    protocol: probe.ProbeProtocol,
    last_seen_ms: i64,
    healthy: bool,
};

/// Core handle carrying all mutable state.
pub const GsaHandle = struct {
    initialized: bool,
    allocator: Allocator,
    profile_registry: game_profiles.ProfileRegistry,
    verisimdb_url: []const u8,
    active_connections: std.StringHashMap(ConnectionState),

    /// Create a new GsaHandle.  Caller owns the returned pointer.
    pub fn create(
        allocator: Allocator,
        verisimdb_url: []const u8,
        profiles_dir: []const u8,
    ) !*GsaHandle {
        const self = try allocator.create(GsaHandle);
        errdefer allocator.destroy(self);

        self.* = .{
            .initialized = false,
            .allocator = allocator,
            .profile_registry = game_profiles.ProfileRegistry.init(allocator),
            .verisimdb_url = try allocator.dupe(u8, verisimdb_url),
            .active_connections = std.StringHashMap(ConnectionState).init(allocator),
        };

        // Load game profiles from the supplied directory
        if (profiles_dir.len > 0) {
            _ = self.profile_registry.loadFromDirectory(profiles_dir) catch |load_err| {
                setError("profile load failed: {s}", .{@errorName(load_err)});
                // non-fatal — we can still operate without profiles
            };
        }

        self.initialized = true;
        return self;
    }

    /// Release all owned memory.
    pub fn destroy(self: *GsaHandle) void {
        const alloc = self.allocator;
        self.profile_registry.deinit();
        alloc.free(self.verisimdb_url);

        var it = self.active_connections.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.host);
        }
        self.active_connections.deinit();

        self.initialized = false;
        alloc.destroy(self);
    }

    /// Register or update a server connection.
    pub fn trackServer(self: *GsaHandle, server_id: []const u8, state: ConnectionState) !void {
        const id_owned = try self.allocator.dupe(u8, server_id);
        errdefer self.allocator.free(id_owned);

        const host_owned = try self.allocator.dupe(u8, state.host);
        errdefer self.allocator.free(host_owned);

        var owned_state = state;
        owned_state.host = host_owned;

        if (self.active_connections.getPtr(server_id)) |existing| {
            self.allocator.free(existing.host);
            existing.* = owned_state;
            self.allocator.free(id_owned);
        } else {
            try self.active_connections.put(id_owned, owned_state);
        }
    }

    /// Retrieve tracked connection state for a server.
    pub fn getConnection(self: *GsaHandle, server_id: []const u8) ?ConnectionState {
        return self.active_connections.get(server_id);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Global singleton (one per process; guarded by a mutex for multi-threaded use)
// ═══════════════════════════════════════════════════════════════════════════════

var global_handle: ?*GsaHandle = null;
var global_mutex: std.Thread.Mutex = .{};

/// Obtain the global handle, or null if not initialised.
pub fn getGlobalHandle() ?*GsaHandle {
    global_mutex.lock();
    defer global_mutex.unlock();
    return global_handle;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Exported C ABI functions
// ═══════════════════════════════════════════════════════════════════════════════

/// Initialise the library.
///
/// `verisimdb_url` — base URL of the dedicated VeriSimDB instance (e.g.
///     "http://localhost:7820").
/// `profiles_dir` — filesystem path to directory containing .a2ml game
///     profiles.
///
/// Returns 0 on success, negative GsaResult on failure.
pub export fn gossamer_gsa_init(
    verisimdb_url: [*:0]const u8,
    profiles_dir: [*:0]const u8,
) callconv(.c) c_int {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_handle != null) {
        setErrorStr("already initialized");
        return @intFromEnum(GsaResult.err);
    }

    const allocator = std.heap.c_allocator;
    const url_slice = std.mem.span(verisimdb_url);
    const dir_slice = std.mem.span(profiles_dir);

    const handle = GsaHandle.create(allocator, url_slice, dir_slice) catch |e| {
        setError("init failed: {s}", .{@errorName(e)});
        return @intFromEnum(GsaResult.out_of_memory);
    };

    global_handle = handle;
    clearError();
    return @intFromEnum(GsaResult.ok);
}

/// Shut down the library and release all resources.
///
/// Returns 0 on success, negative GsaResult on failure.
pub export fn gossamer_gsa_shutdown() callconv(.c) c_int {
    global_mutex.lock();
    defer global_mutex.unlock();

    const handle = global_handle orelse {
        setErrorStr("not initialized");
        return @intFromEnum(GsaResult.not_initialized);
    };

    handle.destroy();
    global_handle = null;
    clearError();
    return @intFromEnum(GsaResult.ok);
}

/// Retrieve the last error message.
///
/// Returns a NUL-terminated string in thread-local storage.  The pointer
/// remains valid until the next FFI call on the same thread.
pub export fn gossamer_gsa_last_error() callconv(.c) [*:0]const u8 {
    return @as([*:0]const u8, @ptrCast(&last_error_buf));
}

/// Library version string (e.g. "0.1.0").
pub export fn gossamer_gsa_version() callconv(.c) [*:0]const u8 {
    return VERSION.ptr;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Unit tests
// ═══════════════════════════════════════════════════════════════════════════════

test "GsaResult values match Idris2 ABI" {
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(GsaResult.ok));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(GsaResult.err));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(GsaResult.invalid_param));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(GsaResult.out_of_memory));
    try std.testing.expectEqual(@as(c_int, 4), @intFromEnum(GsaResult.null_pointer));
    try std.testing.expectEqual(@as(c_int, 5), @intFromEnum(GsaResult.not_initialized));
    try std.testing.expectEqual(@as(c_int, 6), @intFromEnum(GsaResult.timeout));
    try std.testing.expectEqual(@as(c_int, 7), @intFromEnum(GsaResult.connection_refused));
    try std.testing.expectEqual(@as(c_int, 8), @intFromEnum(GsaResult.protocol_error));
    try std.testing.expectEqual(@as(c_int, 9), @intFromEnum(GsaResult.parse_error));
    try std.testing.expectEqual(@as(c_int, 10), @intFromEnum(GsaResult.io_error));
    try std.testing.expectEqual(@as(c_int, 11), @intFromEnum(GsaResult.permission_denied));
    try std.testing.expectEqual(@as(c_int, 12), @intFromEnum(GsaResult.not_found));
}

test "error buffer round-trip" {
    setErrorStr("test error 42");
    const msg = std.mem.span(gossamer_gsa_last_error());
    try std.testing.expectEqualStrings("test error 42", msg);

    clearError();
    const empty = std.mem.span(gossamer_gsa_last_error());
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "version string" {
    const ver = std.mem.span(gossamer_gsa_version());
    try std.testing.expectEqualStrings("0.1.0", ver);
}

test "GsaHandle create and destroy" {
    const allocator = std.testing.allocator;
    const handle = try GsaHandle.create(allocator, "http://localhost:7820", "");
    defer handle.destroy();

    try std.testing.expect(handle.initialized);
    try std.testing.expectEqualStrings("http://localhost:7820", handle.verisimdb_url);
}

test "GsaHandle track server" {
    const allocator = std.testing.allocator;
    const handle = try GsaHandle.create(allocator, "http://localhost:7820", "");
    defer handle.destroy();

    try handle.trackServer("mc-1", .{
        .host = "192.168.1.10",
        .port = 25565,
        .protocol = .MinecraftQuery,
        .last_seen_ms = 1000,
        .healthy = true,
    });

    const conn = handle.getConnection("mc-1") orelse return error.NotFound;
    try std.testing.expectEqual(@as(u16, 25565), conn.port);
    try std.testing.expect(conn.healthy);
}

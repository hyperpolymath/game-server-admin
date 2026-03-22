// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — VeriSimDB HTTP client
//
// Communicates with the dedicated VeriSimDB instance allocated to GSA.
// VeriSimDB is a hyperpolymath database combining vector search, drift
// detection, and provenance tracking in a single octad-based store.
//
// Each game server is represented as a VeriSimDB octad containing its
// config, probe data, spatial location, and provenance chain.
//
// IMPORTANT: This project has its own VeriSimDB instance and port.
// Never store GSA data in the VeriSimDB source repo.

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;
const main = @import("main.zig");
const config_extract = @import("config_extract.zig");
const probe = @import("probe.zig");

// ═══════════════════════════════════════════════════════════════════════════════
// VeriSimClient
// ═══════════════════════════════════════════════════════════════════════════════

/// HTTP client for a VeriSimDB instance.
///
/// All methods return JSON strings from the VeriSimDB API.  The caller
/// is responsible for parsing the JSON as needed.
pub const VeriSimClient = struct {
    base_url: []const u8,
    allocator: Allocator,
    http_client: http.Client,

    /// Create a new VeriSimDB client.
    pub fn init(allocator: Allocator, base_url: []const u8) VeriSimClient {
        return .{
            .base_url = base_url,
            .allocator = allocator,
            .http_client = http.Client{ .allocator = allocator },
        };
    }

    /// Clean up HTTP client resources.
    pub fn deinit(self: *VeriSimClient) void {
        self.http_client.deinit();
    }

    // ─── CRUD operations ─────────────────────────────────────────────

    /// Create a new octad.
    ///
    /// POST /api/v1/octads
    pub fn createOctad(self: *VeriSimClient, body_json: []const u8) ![]const u8 {
        return self.doRequest(.POST, "/api/v1/octads", body_json);
    }

    /// Get an octad by ID.
    ///
    /// GET /api/v1/octads/{id}
    pub fn getOctad(self: *VeriSimClient, id: []const u8) ![]const u8 {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/octads/{s}", .{id}) catch return error.PathTooLong;
        return self.doRequest(.GET, path, null);
    }

    /// Update an existing octad.
    ///
    /// PUT /api/v1/octads/{id}
    pub fn updateOctad(self: *VeriSimClient, id: []const u8, body_json: []const u8) ![]const u8 {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/octads/{s}", .{id}) catch return error.PathTooLong;
        return self.doRequest(.PUT, path, body_json);
    }

    /// Delete an octad.
    ///
    /// DELETE /api/v1/octads/{id}
    pub fn deleteOctad(self: *VeriSimClient, id: []const u8) !void {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/octads/{s}", .{id}) catch return error.PathTooLong;
        const result = try self.doRequest(.DELETE, path, null);
        self.allocator.free(result);
    }

    // ─── Search operations ───────────────────────────────────────────

    /// Full-text search across octads.
    ///
    /// GET /api/v1/search/text?q=...&limit=...
    pub fn searchText(self: *VeriSimClient, query: []const u8, limit: u32) ![]const u8 {
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/search/text?q={s}&limit={d}", .{ query, limit }) catch return error.PathTooLong;
        return self.doRequest(.GET, path, null);
    }

    /// Vector similarity search.
    ///
    /// POST /api/v1/search/vector
    pub fn searchVector(self: *VeriSimClient, embedding_json: []const u8, limit: u32) ![]const u8 {
        var body_buf: [4096]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{{\"embedding\":{s},\"limit\":{d}}}", .{ embedding_json, limit }) catch return error.BodyTooLong;
        return self.doRequest(.POST, "/api/v1/search/vector", body);
    }

    /// Execute a VQL (VeriSimDB Query Language) query.
    ///
    /// POST /api/v1/vql/execute
    pub fn executeVQL(self: *VeriSimClient, vql: []const u8) ![]const u8 {
        var body_buf: [4096]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{{\"query\":\"{s}\"}}", .{vql}) catch return error.BodyTooLong;
        return self.doRequest(.POST, "/api/v1/vql/execute", body);
    }

    // ─── Drift detection ─────────────────────────────────────────────

    /// Get drift status for a specific entity.
    ///
    /// GET /api/v1/drift/entity/{id}
    pub fn getDrift(self: *VeriSimClient, entity_id: []const u8) ![]const u8 {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/drift/entity/{s}", .{entity_id}) catch return error.PathTooLong;
        return self.doRequest(.GET, path, null);
    }

    /// Get global drift status.
    ///
    /// GET /api/v1/drift/status
    pub fn getDriftStatus(self: *VeriSimClient) ![]const u8 {
        return self.doRequest(.GET, "/api/v1/drift/status", null);
    }

    // ─── Provenance tracking ─────────────────────────────────────────

    /// Record a provenance event for an entity.
    ///
    /// POST /api/v1/provenance/{id}/record
    pub fn recordProvenance(self: *VeriSimClient, entity_id: []const u8, event_json: []const u8) !void {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/provenance/{s}/record", .{entity_id}) catch return error.PathTooLong;
        const result = try self.doRequest(.POST, path, event_json);
        self.allocator.free(result);
    }

    /// Get the provenance chain for an entity.
    ///
    /// GET /api/v1/provenance/{id}
    pub fn getProvenance(self: *VeriSimClient, entity_id: []const u8) ![]const u8 {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/provenance/{s}", .{entity_id}) catch return error.PathTooLong;
        return self.doRequest(.GET, path, null);
    }

    // ─── Health check ────────────────────────────────────────────────

    /// Check if the VeriSimDB instance is healthy.
    ///
    /// GET /health
    pub fn health(self: *VeriSimClient) !bool {
        const result = self.doRequest(.GET, "/health", null) catch return false;
        defer self.allocator.free(result);

        // The health endpoint returns {"status":"ok"} when healthy
        return std.mem.indexOf(u8, result, "\"ok\"") != null;
    }

    // ─── Internal HTTP helper ────────────────────────────────────────

    /// Perform an HTTP request against the VeriSimDB base URL.
    ///
    /// Returns the response body as an owned slice.  Caller must free
    /// with self.allocator.
    fn doRequest(
        self: *VeriSimClient,
        method: http.Method,
        path: []const u8,
        body: ?[]const u8,
    ) ![]const u8 {
        // Build the full URL
        var url_buf: [2048]u8 = undefined;
        const url_str = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ self.base_url, path }) catch return error.URLTooLong;

        const uri = std.Uri.parse(url_str) catch return error.InvalidURL;

        var header_buf: [4096]u8 = undefined;
        var req = try self.http_client.open(method, uri, .{
            .server_header_buffer = &header_buf,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Accept", .value = "application/json" },
            },
        });
        defer req.deinit();

        // Send body if present
        if (body) |b| {
            req.transfer_encoding = .{ .content_length = b.len };
        }

        try req.send();

        if (body) |b| {
            try req.writeAll(b);
        }

        try req.finish();
        try req.wait();

        // Check status
        if (req.status != .ok and req.status != .created and req.status != .no_content) {
            return error.HTTPError;
        }

        // Read response body
        const response_body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024);
        return response_body;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Server-to-octad conversion
// ═══════════════════════════════════════════════════════════════════════════════

/// Convert game server data into a VeriSimDB octad JSON request.
///
/// An octad bundles all eight facets of a server's identity:
///   1. metadata (server_id, game_id)
///   2. config (parsed configuration)
///   3. probe (protocol fingerprint)
///   4. spatial (physical/logical location)
///   5. temporal (timestamps)
///   6. relational (links to other servers)
///   7. provenance (change history)
///   8. semantic (embeddings for similarity search)
pub fn serverToOctadJson(
    allocator: Allocator,
    server_id: []const u8,
    game_id: []const u8,
    config: *const config_extract.ParsedConfig,
    probe_result: *const probe.ProbeResult,
    spatial: ?[3]f64,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("{\n");

    // Facet 1: metadata
    try writer.print("  \"metadata\": {{\"server_id\": \"{s}\", \"game_id\": \"{s}\"}},\n", .{ server_id, game_id });

    // Facet 2: config snapshot
    try writer.writeAll("  \"config\": {");
    for (config.fields.items, 0..) |field, i| {
        if (i > 0) try writer.writeAll(", ");
        if (field.is_secret) {
            try writer.print("\"{s}\": \"[REDACTED]\"", .{field.key});
        } else {
            try writer.print("\"{s}\": \"{s}\"", .{ field.key, field.value });
        }
    }
    try writer.writeAll("},\n");

    // Facet 3: probe
    try writer.print("  \"probe\": {{\"protocol\": {d}, \"port\": {d}, \"latency_ms\": {d}, \"version\": \"{s}\"}},\n", .{
        @intFromEnum(probe_result.protocol),
        probe_result.port,
        probe_result.latency_ms,
        probe_result.versionSlice(),
    });

    // Facet 4: spatial
    if (spatial) |s| {
        try writer.print("  \"spatial\": {{\"x\": {d}, \"y\": {d}, \"z\": {d}}},\n", .{ s[0], s[1], s[2] });
    } else {
        try writer.writeAll("  \"spatial\": null,\n");
    }

    // Facet 5: temporal
    try writer.print("  \"temporal\": {{\"created_at\": {d}, \"updated_at\": {d}}},\n", .{
        std.time.milliTimestamp(),
        std.time.milliTimestamp(),
    });

    // Facet 6: relational (empty for now)
    try writer.writeAll("  \"relational\": [],\n");

    // Facet 7: provenance (initial event)
    try writer.print("  \"provenance\": [{{\"event\": \"created\", \"timestamp\": {d}}}],\n", .{
        std.time.milliTimestamp(),
    });

    // Facet 8: semantic (placeholder — embedding computed server-side)
    try writer.writeAll("  \"semantic\": null\n");

    try writer.writeAll("}");

    return buf.toOwnedSlice();
}

// ═══════════════════════════════════════════════════════════════════════════════
// Exported C ABI functions
// ═══════════════════════════════════════════════════════════════════════════════

/// Store an octad in VeriSimDB.
///
/// `octad_json` — JSON string conforming to the VeriSimDB octad schema.
///
/// Returns 0 on success, negative GsaResult on failure.
export fn gossamer_gsa_verisimdb_store(
    octad_json: [*:0]const u8,
) callconv(.C) c_int {
    const gsa = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return @intFromEnum(main.GsaResult.not_initialized);
    };

    var client = VeriSimClient.init(std.heap.c_allocator, gsa.verisimdb_url);
    defer client.deinit();

    const body = std.mem.span(octad_json);
    const result = client.createOctad(body) catch |err| {
        main.setError("VeriSimDB store failed: {s}", .{@errorName(err)});
        return @intFromEnum(main.GsaResult.connection_refused);
    };
    std.heap.c_allocator.free(result);

    main.clearError();
    return @intFromEnum(main.GsaResult.ok);
}

/// Execute a VQL query against VeriSimDB.
///
/// Returns a NUL-terminated JSON string with the query results.
threadlocal var vql_result_buf: [16384]u8 = undefined;

export fn gossamer_gsa_verisimdb_query(
    vql: [*:0]const u8,
) callconv(.C) [*:0]const u8 {
    const gsa = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return @as([*:0]const u8, @ptrCast(&[_:0]u8{ 'E', 'R', 'R' }));
    };

    var client = VeriSimClient.init(std.heap.c_allocator, gsa.verisimdb_url);
    defer client.deinit();

    const vql_str = std.mem.span(vql);
    const result = client.executeVQL(vql_str) catch |err| {
        main.setError("VQL query failed: {s}", .{@errorName(err)});
        return @as([*:0]const u8, @ptrCast(&[_:0]u8{ 'E', 'R', 'R' }));
    };
    defer std.heap.c_allocator.free(result);

    const copy_len = @min(result.len, vql_result_buf.len - 1);
    @memcpy(vql_result_buf[0..copy_len], result[0..copy_len]);
    vql_result_buf[copy_len] = 0;

    main.clearError();
    return @as([*:0]const u8, @ptrCast(&vql_result_buf));
}

/// Check VeriSimDB health.
///
/// Returns 0 if healthy, non-zero otherwise.
export fn gossamer_gsa_verisimdb_health() callconv(.C) c_int {
    const gsa = main.getGlobalHandle() orelse {
        return @intFromEnum(main.GsaResult.not_initialized);
    };

    var client = VeriSimClient.init(std.heap.c_allocator, gsa.verisimdb_url);
    defer client.deinit();

    const healthy = client.health() catch false;
    return if (healthy) @intFromEnum(main.GsaResult.ok) else @intFromEnum(main.GsaResult.connection_refused);
}

/// Get drift information for a server.
threadlocal var drift_result_buf: [8192]u8 = undefined;

export fn gossamer_gsa_verisimdb_drift(
    server_id: [*:0]const u8,
) callconv(.C) [*:0]const u8 {
    const gsa = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return @as([*:0]const u8, @ptrCast(&[_:0]u8{ 'E', 'R', 'R' }));
    };

    var client = VeriSimClient.init(std.heap.c_allocator, gsa.verisimdb_url);
    defer client.deinit();

    const sid = std.mem.span(server_id);
    const result = client.getDrift(sid) catch |err| {
        main.setError("drift query failed: {s}", .{@errorName(err)});
        return @as([*:0]const u8, @ptrCast(&[_:0]u8{ 'E', 'R', 'R' }));
    };
    defer std.heap.c_allocator.free(result);

    const copy_len = @min(result.len, drift_result_buf.len - 1);
    @memcpy(drift_result_buf[0..copy_len], result[0..copy_len]);
    drift_result_buf[copy_len] = 0;

    main.clearError();
    return @as([*:0]const u8, @ptrCast(&drift_result_buf));
}

// ═══════════════════════════════════════════════════════════════════════════════
// Unit tests
// ═══════════════════════════════════════════════════════════════════════════════

test "VeriSimClient URL construction" {
    const client = VeriSimClient.init(std.testing.allocator, "http://localhost:7820");
    // Verify the base URL is stored correctly
    try std.testing.expectEqualStrings("http://localhost:7820", client.base_url);
}

test "serverToOctadJson basic" {
    const allocator = std.testing.allocator;

    var config = config_extract.ParsedConfig.init(allocator, .KeyValue, "/data/server.properties");
    defer config.deinit();
    try config.addField("server-name", "Test", "string", "", "", null, null, false);

    var pr = probe.ProbeResult{};
    pr.setGameId("minecraft-java");
    pr.setVersion("1.21.4");
    pr.port = 25565;
    pr.protocol = .MinecraftQuery;
    pr.latency_ms = 15;

    const json = try serverToOctadJson(allocator, "mc-1", "minecraft-java", &config, &pr, null);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"server_id\": \"mc-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"game_id\": \"minecraft-java\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"server-name\": \"Test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"spatial\": null") != null);
}

test "serverToOctadJson with spatial" {
    const allocator = std.testing.allocator;

    var config = config_extract.ParsedConfig.init(allocator, .KeyValue, "");
    defer config.deinit();

    var pr = probe.ProbeResult{};
    pr.port = 27015;
    pr.protocol = .SteamQuery;

    const spatial = [3]f64{ 51.5074, -0.1278, 0.0 }; // London
    const json = try serverToOctadJson(allocator, "cs2-uk", "cs2", &config, &pr, spatial);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"spatial\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"x\":") != null);
}

test "serverToOctadJson redacts secrets" {
    const allocator = std.testing.allocator;

    var config = config_extract.ParsedConfig.init(allocator, .KeyValue, "");
    defer config.deinit();
    try config.addField("rcon.password", "super_secret_123", "secret", "", "", null, null, true);

    var pr = probe.ProbeResult{};
    pr.port = 27015;

    const json = try serverToOctadJson(allocator, "s1", "game", &config, &pr, null);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "[REDACTED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "super_secret_123") == null);
}

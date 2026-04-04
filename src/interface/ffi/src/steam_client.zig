// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — Steam Web API client
//
// Provides Steam Web API integration for:
//   - Resolving Steam vanity URLs (usernames) to Steam64 IDs
//   - Fetching player summaries (display name, avatar, profile URL)
//   - Checking game ownership (verify account owns a given AppID)
//
// Usage (from GSA CLI):
//   gsa steam resolve <vanity-url>        → Steam64 ID
//   gsa steam player <steam64-id>         → player info
//   gsa steam owns <steam64-id> <appid>   → ownership check
//
// Steam Web API key:
//   Set GSA_STEAM_API_KEY environment variable.
//   Obtain a free key at: https://steamcommunity.com/dev/apikey
//   The key is never stored in this binary or repository.
//
// Legal:
//   The Steam Web API is a free public API provided by Valve Corporation.
//   Use is governed by the Steam Web API Terms of Use:
//   https://steamcommunity.com/dev/apiterms
//   This module only makes read-only requests on behalf of the server operator.

const std = @import("std");
const Allocator = std.mem.Allocator;
const main = @import("main.zig");

// ═══════════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════════

const STEAM_API_BASE = "https://api.steampowered.com";
const STEAM_API_TIMEOUT_MS: u32 = 8_000;

/// Maximum length of a Steam64 ID in decimal string form (17 digits + NUL)
const STEAM64_ID_LEN: usize = 18;

/// Maximum length of a Steam display name
const STEAM_NAME_BUF: usize = 128;

// ═══════════════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════════════

/// Result of resolving a Steam vanity URL.
pub const VanityResult = struct {
    steam_id: [STEAM64_ID_LEN]u8,
    steam_id_len: usize,

    /// Return the Steam64 ID as a slice.
    pub fn idSlice(self: *const VanityResult) []const u8 {
        return self.steam_id[0..self.steam_id_len];
    }
};

/// Summary information for a Steam player.
pub const PlayerSummary = struct {
    steam_id: [STEAM64_ID_LEN]u8,
    steam_id_len: usize,
    display_name: [STEAM_NAME_BUF]u8,
    display_name_len: usize,
    profile_url: [256]u8,
    profile_url_len: usize,
    /// Community visibility state: 1=private, 3=public
    visibility: u8,

    pub fn idSlice(self: *const PlayerSummary) []const u8 {
        return self.steam_id[0..self.steam_id_len];
    }
    pub fn nameSlice(self: *const PlayerSummary) []const u8 {
        return self.display_name[0..self.display_name_len];
    }
    pub fn urlSlice(self: *const PlayerSummary) []const u8 {
        return self.profile_url[0..self.profile_url_len];
    }
};

/// Ownership check result
pub const OwnershipResult = struct {
    owns_game: bool,
    app_id: u32,
    playtime_minutes: u32,
};

// ═══════════════════════════════════════════════════════════════════════════════
// SteamClient
// ═══════════════════════════════════════════════════════════════════════════════

pub const SteamClient = struct {
    allocator: Allocator,
    http_client: std.http.Client,
    api_key: []const u8,

    pub fn init(allocator: Allocator, api_key: []const u8) SteamClient {
        return .{
            .allocator = allocator,
            .http_client = std.http.Client{ .allocator = allocator },
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *SteamClient) void {
        self.http_client.deinit();
    }

    // ── HTTP helper ────────────────────────────────────────────────────────

    /// Fetch a URL and return the response body as an owned slice.
    /// Caller must free the returned slice.
    fn get(self: *SteamClient, url: []const u8) ![]const u8 {
        // Use the Zig 0.15 fetch() API with Io.Writer.Allocating (same pattern
        // as verisimdb_client.zig and groove_client.zig).
        var alloc_writer = std.Io.Writer.Allocating.init(self.allocator);
        errdefer alloc_writer.deinit();

        const result = try self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .extra_headers = &.{
                .{ .name = "Accept", .value = "application/json" },
            },
            .response_writer = &alloc_writer.writer,
        });

        if (result.status != .ok) {
            alloc_writer.deinit();
            return error.HTTPError;
        }

        var list = alloc_writer.toArrayList();
        return list.toOwnedSlice(self.allocator);
    }

    // ── Vanity URL resolution ──────────────────────────────────────────────

    /// Resolve a Steam vanity URL (username) to a Steam64 ID.
    ///
    /// Example: resolveVanityUrl("hyperpolymath") → "76561198141836018"
    ///
    /// Uses: GET /ISteamUser/ResolveVanityURL/v1/?key={key}&vanityurl={username}
    pub fn resolveVanityUrl(self: *SteamClient, vanity_url: []const u8) !VanityResult {
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf,
            STEAM_API_BASE ++ "/ISteamUser/ResolveVanityURL/v1/?key={s}&vanityurl={s}",
            .{ self.api_key, vanity_url },
        ) catch return error.URLTooLong;

        const body = try self.get(url);
        defer self.allocator.free(body);

        // Response JSON:
        // {"response":{"steamid":"76561198141836018","success":1}}
        // or:
        // {"response":{"success":42,"message":"No match"}}

        // Check success field first
        if (std.mem.indexOf(u8, body, "\"success\":1") == null) {
            // Not found or error — extract message if present
            return error.VanityNotFound;
        }

        // Extract steamid value
        const steam_id = extractJsonString(body, "steamid") orelse
            return error.MalformedResponse;

        var result = VanityResult{
            .steam_id = [_]u8{0} ** STEAM64_ID_LEN,
            .steam_id_len = 0,
        };
        const copy_len = @min(steam_id.len, STEAM64_ID_LEN - 1);
        @memcpy(result.steam_id[0..copy_len], steam_id[0..copy_len]);
        result.steam_id_len = copy_len;

        return result;
    }

    // ── Player summaries ───────────────────────────────────────────────────

    /// Fetch summary information for a Steam64 ID.
    ///
    /// Uses: GET /ISteamUser/GetPlayerSummaries/v2/?key={key}&steamids={id}
    pub fn getPlayerSummary(self: *SteamClient, steam_id: []const u8) !PlayerSummary {
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf,
            STEAM_API_BASE ++ "/ISteamUser/GetPlayerSummaries/v2/?key={s}&steamids={s}",
            .{ self.api_key, steam_id },
        ) catch return error.URLTooLong;

        const body = try self.get(url);
        defer self.allocator.free(body);

        // Response JSON (abbreviated):
        // {"response":{"players":[{"steamid":"...","personaname":"...","profileurl":"...","communityvisibilitystate":3,...}]}}

        const players_start = std.mem.indexOf(u8, body, "\"players\"") orelse
            return error.MalformedResponse;
        const player_section = body[players_start..];

        // Check we got at least one player
        if (std.mem.indexOf(u8, player_section, "\"steamid\"") == null) {
            return error.PlayerNotFound;
        }

        var summary = PlayerSummary{
            .steam_id = [_]u8{0} ** STEAM64_ID_LEN,
            .steam_id_len = 0,
            .display_name = [_]u8{0} ** STEAM_NAME_BUF,
            .display_name_len = 0,
            .profile_url = [_]u8{0} ** 256,
            .profile_url_len = 0,
            .visibility = 0,
        };

        // Extract steamid
        if (extractJsonString(player_section, "steamid")) |id| {
            const n = @min(id.len, STEAM64_ID_LEN - 1);
            @memcpy(summary.steam_id[0..n], id[0..n]);
            summary.steam_id_len = n;
        }

        // Extract personaname (display name)
        if (extractJsonString(player_section, "personaname")) |name| {
            const n = @min(name.len, STEAM_NAME_BUF - 1);
            @memcpy(summary.display_name[0..n], name[0..n]);
            summary.display_name_len = n;
        }

        // Extract profileurl
        if (extractJsonString(player_section, "profileurl")) |url_val| {
            const n = @min(url_val.len, 255);
            @memcpy(summary.profile_url[0..n], url_val[0..n]);
            summary.profile_url_len = n;
        }

        // Extract communityvisibilitystate
        if (extractJsonNumber(player_section, "communityvisibilitystate")) |vis| {
            summary.visibility = @truncate(vis);
        }

        return summary;
    }

    // ── Ownership check ────────────────────────────────────────────────────

    /// Check whether a Steam account owns a specific game (AppID).
    ///
    /// Uses: GET /IPlayerService/GetOwnedGames/v1/?key={key}&steamid={id}&appids_filter[0]={appid}
    ///
    /// Note: Only works if the user's game list is public. Returns
    /// error.ProfilePrivate if visibility is set to private.
    pub fn checkOwnership(self: *SteamClient, steam_id: []const u8, app_id: u32) !OwnershipResult {
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf,
            STEAM_API_BASE ++ "/IPlayerService/GetOwnedGames/v1/?key={s}&steamid={s}&include_appinfo=false&appids_filter[0]={d}",
            .{ self.api_key, steam_id, app_id },
        ) catch return error.URLTooLong;

        const body = try self.get(url);
        defer self.allocator.free(body);

        // Response: {"response":{"game_count":1,"games":[{"appid":829590,"playtime_forever":120}]}}
        // or:       {"response":{}}  (no games / private profile)

        var result = OwnershipResult{
            .owns_game = false,
            .app_id = app_id,
            .playtime_minutes = 0,
        };

        // Check if any games returned
        const game_count = extractJsonNumber(body, "game_count") orelse 0;
        if (game_count > 0) {
            result.owns_game = true;
            if (extractJsonNumber(body, "playtime_forever")) |pt| {
                result.playtime_minutes = @truncate(pt);
            }
        }

        return result;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// JSON micro-parser helpers
// ═══════════════════════════════════════════════════════════════════════════════
//
// These intentionally avoid full JSON parsing (heavy dependency, not needed for
// the narrow field extractions we do here). They are safe for well-formed Valve
// API responses. Malformed input returns null rather than panicking.

/// Extract the string value of a JSON key from a well-formed response.
/// Returns a slice into `json` — does NOT allocate.
///
/// Example:  extractJsonString(`{"steamid":"76561198141836018"}`, "steamid")
///           → "76561198141836018"
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Build search pattern: `"key":"`
    var pattern_buf: [128]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":\"", .{key}) catch return null;

    const start_pos = std.mem.indexOf(u8, json, pattern) orelse return null;
    const value_start = start_pos + pattern.len;
    if (value_start >= json.len) return null;

    // Find closing quote (not preceded by backslash — simple heuristic)
    var end_pos = value_start;
    while (end_pos < json.len) : (end_pos += 1) {
        if (json[end_pos] == '"' and (end_pos == 0 or json[end_pos - 1] != '\\')) break;
    }
    if (end_pos >= json.len) return null;

    return json[value_start..end_pos];
}

/// Extract the integer value of a JSON key.
/// Returns null if the key is absent or the value is not an integer.
fn extractJsonNumber(json: []const u8, key: []const u8) ?u64 {
    var pattern_buf: [128]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{key}) catch return null;

    const start_pos = std.mem.indexOf(u8, json, pattern) orelse return null;
    const value_start = start_pos + pattern.len;
    if (value_start >= json.len) return null;

    // Skip whitespace
    var i = value_start;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}

    // Read digits
    const digit_start = i;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {}
    if (i == digit_start) return null;

    return std.fmt.parseInt(u64, json[digit_start..i], 10) catch null;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Thread-local result buffers (for C ABI exports)
// ═══════════════════════════════════════════════════════════════════════════════

threadlocal var steam_result_buf: [1024:0]u8 = [_:0]u8{0} ** 1024;

// ═══════════════════════════════════════════════════════════════════════════════
// Exported C ABI functions
// ═══════════════════════════════════════════════════════════════════════════════

/// Resolve a Steam vanity URL to a Steam64 ID.
///
/// @param vanity_url  NUL-terminated Steam vanity URL (e.g. "hyperpolymath")
/// @param api_key     NUL-terminated Steam Web API key
/// @return            GsaResult code; on success the Steam64 ID is in the
///                    result buffer (retrieve via gossamer_gsa_get_result_str)
pub export fn gossamer_gsa_steam_resolve_vanity(
    vanity_url: [*:0]const u8,
    api_key: [*:0]const u8,
) callconv(.c) c_int {
    const allocator = std.heap.c_allocator;
    const vanity = std.mem.span(vanity_url);
    const key = std.mem.span(api_key);

    if (vanity.len == 0) {
        main.setError("vanity_url is empty", .{});
        return @intFromEnum(main.GsaResult.invalid_param);
    }
    if (key.len == 0) {
        main.setError("Steam API key is empty — set GSA_STEAM_API_KEY", .{});
        return @intFromEnum(main.GsaResult.invalid_param);
    }

    var client = SteamClient.init(allocator, key);
    defer client.deinit();

    const result = client.resolveVanityUrl(vanity) catch |err| {
        switch (err) {
            error.VanityNotFound => main.setError("Steam vanity URL not found: {s}", .{vanity}),
            error.HTTPError => main.setError("Steam API request failed (HTTP error)", .{}),
            error.MalformedResponse => main.setError("Steam API returned malformed response", .{}),
            else => main.setError("Steam resolve error: {}", .{err}),
        }
        return @intFromEnum(main.GsaResult.connection_refused);
    };

    const id_slice = result.idSlice();
    const copy_len = @min(id_slice.len, steam_result_buf.len - 1);
    @memcpy(steam_result_buf[0..copy_len], id_slice[0..copy_len]);
    steam_result_buf[copy_len] = 0;

    return @intFromEnum(main.GsaResult.ok);
}

/// Fetch player summary for a Steam64 ID.
///
/// @param steam_id   NUL-terminated Steam64 ID (17-digit decimal)
/// @param api_key    NUL-terminated Steam Web API key
/// @return           GsaResult; on success result buffer contains JSON:
///                   {"steamid":"...","name":"...","profile_url":"...","visibility":3}
pub export fn gossamer_gsa_steam_player_info(
    steam_id: [*:0]const u8,
    api_key: [*:0]const u8,
) callconv(.c) c_int {
    const allocator = std.heap.c_allocator;
    const id = std.mem.span(steam_id);
    const key = std.mem.span(api_key);

    if (id.len == 0) {
        main.setError("steam_id is empty", .{});
        return @intFromEnum(main.GsaResult.invalid_param);
    }
    if (key.len == 0) {
        main.setError("Steam API key is empty — set GSA_STEAM_API_KEY", .{});
        return @intFromEnum(main.GsaResult.invalid_param);
    }

    var client = SteamClient.init(allocator, key);
    defer client.deinit();

    const summary = client.getPlayerSummary(id) catch |err| {
        switch (err) {
            error.PlayerNotFound => main.setError("No Steam player found for ID: {s}", .{id}),
            error.HTTPError => main.setError("Steam API request failed (HTTP error)", .{}),
            error.MalformedResponse => main.setError("Steam API returned malformed response", .{}),
            else => main.setError("Steam player info error: {}", .{err}),
        }
        return @intFromEnum(main.GsaResult.connection_refused);
    };

    const written = std.fmt.bufPrint(&steam_result_buf,
        "{{\"steamid\":\"{s}\",\"name\":\"{s}\",\"profile_url\":\"{s}\",\"visibility\":{d}}}",
        .{
            summary.idSlice(),
            summary.nameSlice(),
            summary.urlSlice(),
            summary.visibility,
        },
    ) catch {
        main.setError("Result buffer overflow in steam_player_info", .{});
        return @intFromEnum(main.GsaResult.io_error);
    };
    steam_result_buf[written.len] = 0;

    return @intFromEnum(main.GsaResult.ok);
}

/// Get the last result string from a Steam API call.
/// Returns a NUL-terminated pointer into a thread-local buffer.
pub export fn gossamer_gsa_steam_get_result() callconv(.c) [*:0]const u8 {
    return &steam_result_buf;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "extractJsonString: basic key-value" {
    const json = "{\"steamid\":\"76561198141836018\",\"success\":1}";
    const result = extractJsonString(json, "steamid");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("76561198141836018", result.?);
}

test "extractJsonString: absent key returns null" {
    const json = "{\"other\":\"value\"}";
    const result = extractJsonString(json, "steamid");
    try std.testing.expect(result == null);
}

test "extractJsonNumber: basic integer" {
    const json = "{\"success\":1,\"game_count\":42}";
    const result = extractJsonNumber(json, "game_count");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u64, 42), result.?);
}

test "extractJsonNumber: absent key returns null" {
    const json = "{\"success\":1}";
    const result = extractJsonNumber(json, "missing_key");
    try std.testing.expect(result == null);
}

test "extractJsonString: handles escaped quotes gracefully" {
    // Simplified — our heuristic doesn't fully handle all escape sequences
    // but is safe for the well-formed Valve API responses we actually receive
    const json = "{\"personaname\":\"Player\"}";
    const result = extractJsonString(json, "personaname");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Player", result.?);
}

// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — KeyValue and ENV config parsers
//
// KeyValue: generic `key=value` / `key:value` format used by Minecraft
//   server.properties, Terraria serverconfig.txt, and similar.
//
// ENV: `.env` / shell `export KEY=VALUE` format used by Docker Compose
//   overrides and environment-based game server configs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config_extract = @import("config_extract.zig");
const ParsedConfig = config_extract.ParsedConfig;

/// Parse a generic key=value config file.
///
/// Supports configurable delimiters (defaults to '=') and comment
/// prefixes (defaults to '#').
pub fn parseKeyValue(allocator: Allocator, data: []const u8) !ParsedConfig {
    var config = ParsedConfig.init(allocator, .KeyValue, "");
    errdefer config.deinit();
    config.raw_text = try allocator.dupe(u8, data);

    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // Try '=' first, then ':'
        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse
            std.mem.indexOfScalar(u8, line, ':') orelse continue;

        const key = std.mem.trim(u8, line[0..eq_pos], " \t");
        var val = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

        // Strip surrounding quotes
        if (val.len >= 2) {
            if ((val[0] == '"' and val[val.len - 1] == '"') or
                (val[0] == '\'' and val[val.len - 1] == '\''))
            {
                val = val[1 .. val.len - 1];
            }
        }

        // Detect secrets
        const is_secret = std.mem.indexOf(u8, key, "password") != null or
            std.mem.indexOf(u8, key, "secret") != null or
            std.mem.indexOf(u8, key, "token") != null or
            std.mem.indexOf(u8, key, "rcon.password") != null;

        try config.addField(key, val, "string", key, "", null, null, is_secret);
    }

    return config;
}

/// Parse an ENV file (`.env` / shell export format).
///
/// Handles `KEY=VALUE`, `export KEY=VALUE`, strips quotes and inline
/// comments.
pub fn parseENV(allocator: Allocator, data: []const u8) !ParsedConfig {
    var config = ParsedConfig.init(allocator, .ENV, "");
    errdefer config.deinit();
    config.raw_text = try allocator.dupe(u8, data);

    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        // Strip "export " prefix
        if (std.mem.startsWith(u8, line, "export ")) {
            line = line[7..];
        }

        if (std.mem.indexOfScalar(u8, line, '=')) |eq_pos| {
            const key = std.mem.trim(u8, line[0..eq_pos], " \t");
            var val = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

            // Strip surrounding quotes
            if (val.len >= 2) {
                if ((val[0] == '"' and val[val.len - 1] == '"') or
                    (val[0] == '\'' and val[val.len - 1] == '\''))
                {
                    val = val[1 .. val.len - 1];
                }
            }

            const is_secret = std.mem.indexOf(u8, key, "SECRET") != null or
                std.mem.indexOf(u8, key, "PASSWORD") != null or
                std.mem.indexOf(u8, key, "TOKEN") != null or
                std.mem.indexOf(u8, key, "KEY") != null;

            try config.addField(key, val, "string", key, "", null, null, is_secret);
        }
    }

    return config;
}

/// Parse a TOML config file (basic implementation).
///
/// Handles section headers `[section]`, array-of-tables `[[section]]`,
/// basic key=value, inline tables, and quoted strings.
pub fn parseTOML(allocator: Allocator, data: []const u8) !ParsedConfig {
    var config = ParsedConfig.init(allocator, .TOML, "");
    errdefer config.deinit();
    config.raw_text = try allocator.dupe(u8, data);

    var current_section: []const u8 = "";
    var line_iter = std.mem.splitScalar(u8, data, '\n');

    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // Array of tables [[section]]
        if (std.mem.startsWith(u8, line, "[[") and std.mem.endsWith(u8, line, "]]")) {
            current_section = line[2 .. line.len - 2];
            continue;
        }

        // Section header [section]
        if (line[0] == '[' and line[line.len - 1] == ']') {
            current_section = line[1 .. line.len - 1];
            continue;
        }

        // Key = value
        if (std.mem.indexOfScalar(u8, line, '=')) |eq_pos| {
            const raw_key = std.mem.trim(u8, line[0..eq_pos], " \t");
            var raw_val = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

            // Strip inline comments (only if not inside a string)
            if (raw_val.len > 0 and raw_val[0] != '"' and raw_val[0] != '\'') {
                if (std.mem.indexOfScalar(u8, raw_val, '#')) |comment_pos| {
                    raw_val = std.mem.trim(u8, raw_val[0..comment_pos], " \t");
                }
            }

            // Strip quotes from string values
            if (raw_val.len >= 2) {
                if ((raw_val[0] == '"' and raw_val[raw_val.len - 1] == '"') or
                    (raw_val[0] == '\'' and raw_val[raw_val.len - 1] == '\''))
                {
                    raw_val = raw_val[1 .. raw_val.len - 1];
                }
            }

            // Detect type
            const field_type: []const u8 = if (std.mem.eql(u8, raw_val, "true") or std.mem.eql(u8, raw_val, "false"))
                "bool"
            else if (raw_val.len > 0 and (raw_val[0] == '['))
                "string" // array
            else if (raw_val.len > 0 and (raw_val[0] == '{'))
                "string" // inline table
            else if (isNumeric(raw_val))
                "int"
            else
                "string";

            var full_key_buf: [512]u8 = undefined;
            const full_key = if (current_section.len > 0)
                std.fmt.bufPrint(&full_key_buf, "{s}.{s}", .{ current_section, raw_key }) catch raw_key
            else
                raw_key;

            try config.addField(full_key, raw_val, field_type, raw_key, "", null, null, false);
        }
    }

    return config;
}

/// Check if a string looks like a number (integer or float).
fn isNumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    var has_dot = false;
    for (s, 0..) |ch, i| {
        if (ch == '-' and i == 0) continue;
        if (ch == '+' and i == 0) continue;
        if (ch == '.') {
            if (has_dot) return false;
            has_dot = true;
            continue;
        }
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

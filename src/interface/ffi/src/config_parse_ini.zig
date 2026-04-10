// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — INI config parser
//
// Handles `[Section]` headers, `key=value` and `key = value` lines,
// and strips `#` and `;` comments.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config_extract = @import("config_extract.zig");
const ParsedConfig = config_extract.ParsedConfig;

/// Parse an INI-format config file.
///
/// Handles `[Section]` headers, `key=value` and `key = value` lines,
/// and strips `#` and `;` comments.
pub fn parseINI(allocator: Allocator, data: []const u8) !ParsedConfig {
    var config = ParsedConfig.init(allocator, .INI, "");
    errdefer config.deinit();
    config.raw_text = try allocator.dupe(u8, data);

    var current_section: []const u8 = "";
    var line_iter = std.mem.splitScalar(u8, data, '\n');

    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#' or line[0] == ';') continue;

        // Section header
        if (line[0] == '[') {
            if (std.mem.indexOfScalar(u8, line, ']')) |close| {
                current_section = line[1..close];
            }
            continue;
        }

        // Key=value
        if (std.mem.indexOfScalar(u8, line, '=')) |eq_pos| {
            const raw_key = std.mem.trim(u8, line[0..eq_pos], " \t");
            var raw_val = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

            // Strip inline comments
            if (std.mem.indexOfScalar(u8, raw_val, '#')) |comment_pos| {
                if (comment_pos > 0 and raw_val[comment_pos - 1] == ' ') {
                    raw_val = std.mem.trim(u8, raw_val[0..comment_pos], " \t");
                }
            }

            // Build full key: section.key
            var full_key_buf: [512]u8 = undefined;
            const full_key = if (current_section.len > 0)
                std.fmt.bufPrint(&full_key_buf, "{s}.{s}", .{ current_section, raw_key }) catch raw_key
            else
                raw_key;

            try config.addField(full_key, raw_val, "string", raw_key, "", null, null, false);
        }
    }

    return config;
}

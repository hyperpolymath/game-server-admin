// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — JSON config parser
//
// Flattens nested JSON objects using dot notation:
//   `{"server": {"name": "x"}}` → key="server.name", value="x"

const std = @import("std");
const Allocator = std.mem.Allocator;
const config_extract = @import("config_extract.zig");
const ParsedConfig = config_extract.ParsedConfig;

/// Parse a JSON config file using std.json.
///
/// Flattens nested objects using dot notation: `{"server": {"name": "x"}}`
/// becomes key="server.name", value="x".
pub fn parseJSON(allocator: Allocator, data: []const u8) !ParsedConfig {
    var config = ParsedConfig.init(allocator, .JSON, "");
    errdefer config.deinit();
    config.raw_text = try allocator.dupe(u8, data);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        return config; // return empty config on parse failure
    };
    defer parsed.deinit();

    var prefix_buf: [1024]u8 = undefined;
    try flattenJsonValue(&config, parsed.value, &prefix_buf, 0);

    return config;
}

/// Recursively flatten a JSON value into config fields.
fn flattenJsonValue(
    config: *ParsedConfig,
    value: std.json.Value,
    prefix_buf: []u8,
    prefix_len: usize,
) !void {
    switch (value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                var new_prefix_len = prefix_len;

                if (prefix_len > 0) {
                    if (prefix_len + 1 + key.len > prefix_buf.len) continue;
                    prefix_buf[prefix_len] = '.';
                    new_prefix_len += 1;
                }

                if (new_prefix_len + key.len > prefix_buf.len) continue;
                @memcpy(prefix_buf[new_prefix_len .. new_prefix_len + key.len], key);
                new_prefix_len += key.len;

                try flattenJsonValue(config, entry.value_ptr.*, prefix_buf, new_prefix_len);
            }
        },
        .string => |s| {
            const full_key = prefix_buf[0..prefix_len];
            try config.addField(full_key, s, "string", "", "", null, null, false);
        },
        .integer => |n| {
            var val_buf: [32]u8 = undefined;
            const val_str = std.fmt.bufPrint(&val_buf, "{d}", .{n}) catch return;
            const full_key = prefix_buf[0..prefix_len];
            try config.addField(full_key, val_str, "int", "", "", null, null, false);
        },
        .float => |f| {
            var val_buf: [32]u8 = undefined;
            const val_str = std.fmt.bufPrint(&val_buf, "{d}", .{f}) catch return;
            const full_key = prefix_buf[0..prefix_len];
            try config.addField(full_key, val_str, "float", "", "", null, null, false);
        },
        .bool => |b| {
            const full_key = prefix_buf[0..prefix_len];
            try config.addField(full_key, if (b) "true" else "false", "bool", "", "", null, null, false);
        },
        .null => {
            const full_key = prefix_buf[0..prefix_len];
            try config.addField(full_key, "", "string", "", "", null, null, false);
        },
        .array => {
            // Represent arrays as "[array]" placeholder — full JSON serialisation
            // of arbitrary values requires the new Io.Writer interface which is
            // overkill for config extraction where arrays are rare.
            const full_key = prefix_buf[0..prefix_len];
            try config.addField(full_key, "[array]", "string", "", "", null, null, false);
        },
        .number_string => |s| {
            const full_key = prefix_buf[0..prefix_len];
            try config.addField(full_key, s, "string", "", "", null, null, false);
        },
    }
}

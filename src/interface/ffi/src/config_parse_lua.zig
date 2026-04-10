// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — Lua table config parser
//
// Handles deeply nested Lua tables used by Garry's Mod, Factorio,
// Don't Starve Together, and other Source/Unity game servers.
//
// Supports:
//   - `key = "value"` at top level
//   - `table = { key = value, ... }` (single-line)
//   - `table = {\n  key = value,\n}` (multi-line)
//   - `parent = { child = { key = value } }` (nested, up to 8 levels)
//   - `["string-key"] = value` (bracket-quoted keys)
//   - `[1] = value` (numeric array indices)
//   - `local table = { ... }` (local declarations)
//   - `--` line comments and `--[[ ]]` block comments

const std = @import("std");
const Allocator = std.mem.Allocator;
const config_extract = @import("config_extract.zig");
const ParsedConfig = config_extract.ParsedConfig;

/// Parse Lua table-style config files.
pub fn parseLua(allocator: Allocator, data: []const u8) !ParsedConfig {
    var config = ParsedConfig.init(allocator, .Lua, "");
    errdefer config.deinit();
    config.raw_text = try allocator.dupe(u8, data);

    // Path stack for nested tables (max 8 levels)
    var path_stack: [8][]const u8 = .{""} ** 8;
    var path_depth: u32 = 0;
    var in_block_comment = false;

    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        // Handle block comments: --[[ ... ]]
        if (in_block_comment) {
            if (std.mem.indexOf(u8, line, "]]") != null) {
                in_block_comment = false;
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "--[[")) {
            // Check if block comment ends on same line
            if (std.mem.indexOf(u8, line[4..], "]]") != null) continue;
            in_block_comment = true;
            continue;
        }

        // Skip line comments
        if (std.mem.startsWith(u8, line, "--")) continue;

        // Strip trailing line comments: `value, -- comment`
        if (std.mem.indexOf(u8, line, " --")) |comment_pos| {
            line = std.mem.trim(u8, line[0..comment_pos], " \t,");
        }

        // Count braces on this line to track nesting
        var opens: u32 = 0;
        var closes: u32 = 0;
        for (line) |ch| {
            if (ch == '{') opens += 1;
            if (ch == '}') closes += 1;
        }

        // Table assignment: `name = {` or `["name"] = {`
        if (opens > closes) {
            if (std.mem.indexOf(u8, line, "= {") orelse std.mem.indexOf(u8, line, "={")) |eq_brace| {
                var table_name = std.mem.trim(u8, line[0..eq_brace], " \t");

                // Strip "local " prefix
                if (std.mem.startsWith(u8, table_name, "local ")) {
                    table_name = std.mem.trim(u8, table_name[6..], " \t");
                }

                // Strip bracket-quoted keys: ["key"] → key
                table_name = stripBracketKey(table_name);

                if (path_depth < path_stack.len) {
                    path_stack[path_depth] = table_name;
                    path_depth += 1;
                }
            } else {
                // Anonymous table (bare `{` on a line)
                if (path_depth < path_stack.len) {
                    path_stack[path_depth] = "";
                    path_depth += 1;
                }
            }
            // If the line also has key=value before the brace, skip it
            // (table name is captured, values inside come on later lines)
            continue;
        }

        // Closing braces — pop path stack
        if (closes > opens) {
            var pops = closes - opens;
            while (pops > 0 and path_depth > 0) {
                path_depth -= 1;
                pops -= 1;
            }
            // If line has content before `}`, try to parse it
            if (std.mem.indexOfScalar(u8, line, '}')) |brace_pos| {
                if (brace_pos > 0) {
                    const before_brace = std.mem.trim(u8, line[0..brace_pos], " \t,");
                    if (before_brace.len > 0 and std.mem.indexOfScalar(u8, before_brace, '=') != null) {
                        try parseLuaKeyValue(&config, before_brace, &path_stack, path_depth);
                    }
                }
            }
            continue;
        }

        // Key = value line (no net brace change)
        if (std.mem.indexOfScalar(u8, line, '=')) |eq_pos| {
            // Skip comparisons (== ~= >=  <=)
            if (eq_pos + 1 < line.len and line[eq_pos + 1] == '=') continue;
            if (eq_pos > 0 and (line[eq_pos - 1] == '~' or line[eq_pos - 1] == '>' or line[eq_pos - 1] == '<')) continue;

            try parseLuaKeyValue(&config, line, &path_stack, path_depth);
        }
    }

    return config;
}

/// Parse a single Lua `key = value` line within the current path context.
fn parseLuaKeyValue(
    config: *ParsedConfig,
    line: []const u8,
    path_stack: *const [8][]const u8,
    path_depth: u32,
) !void {
    const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse return;

    // Skip comparisons
    if (eq_pos + 1 < line.len and line[eq_pos + 1] == '=') return;
    if (eq_pos > 0 and (line[eq_pos - 1] == '~' or line[eq_pos - 1] == '>' or line[eq_pos - 1] == '<')) return;

    var raw_key = std.mem.trim(u8, line[0..eq_pos], " \t");
    var raw_val = std.mem.trim(u8, line[eq_pos + 1 ..], " \t,");

    // Strip "local " prefix from key
    if (std.mem.startsWith(u8, raw_key, "local ")) {
        raw_key = std.mem.trim(u8, raw_key[6..], " \t");
    }

    // Strip bracket-quoted keys: ["key"] → key, [1] → 1
    raw_key = stripBracketKey(raw_key);

    // Skip if value opens a new table (handled by nesting logic)
    if (raw_val.len > 0 and raw_val[0] == '{') return;

    // Strip quotes from value
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
    else if (std.mem.eql(u8, raw_val, "nil"))
        "string"
    else if (isNumeric(raw_val))
        if (std.mem.indexOfScalar(u8, raw_val, '.') != null) "float" else "int"
    else
        "string";

    // Build dotted path: parent.child.key
    var full_key_buf: [512]u8 = undefined;
    var key_len: usize = 0;

    var i: u32 = 0;
    while (i < path_depth) : (i += 1) {
        if (path_stack[i].len > 0) {
            if (key_len > 0) {
                if (key_len < full_key_buf.len) {
                    full_key_buf[key_len] = '.';
                    key_len += 1;
                }
            }
            const seg = path_stack[i];
            const copy_len = @min(seg.len, full_key_buf.len - key_len);
            @memcpy(full_key_buf[key_len .. key_len + copy_len], seg[0..copy_len]);
            key_len += copy_len;
        }
    }

    // Append the key itself
    if (key_len > 0 and key_len < full_key_buf.len) {
        full_key_buf[key_len] = '.';
        key_len += 1;
    }
    const key_copy_len = @min(raw_key.len, full_key_buf.len - key_len);
    @memcpy(full_key_buf[key_len .. key_len + key_copy_len], raw_key[0..key_copy_len]);
    key_len += key_copy_len;

    const full_key = full_key_buf[0..key_len];

    try config.addField(full_key, raw_val, field_type, raw_key, "", null, null, false);
}

/// Strip Lua bracket-quoted keys: `["key"]` → `key`, `[1]` → `1`
fn stripBracketKey(key: []const u8) []const u8 {
    if (key.len >= 2 and key[0] == '[') {
        if (key[key.len - 1] == ']') {
            var inner = key[1 .. key.len - 1];
            // Strip inner quotes: ["key"] → key
            if (inner.len >= 2) {
                if ((inner[0] == '"' and inner[inner.len - 1] == '"') or
                    (inner[0] == '\'' and inner[inner.len - 1] == '\''))
                {
                    return inner[1 .. inner.len - 1];
                }
            }
            return inner;
        }
    }
    return key;
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

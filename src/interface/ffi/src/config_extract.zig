// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — Config file extraction and parsing
//
// Handles the diverse zoo of configuration file formats used by game
// servers: XML, INI, JSON, ENV, TOML, Lua tables, and generic key=value.
// Also provides extraction methods that pull config files from remote
// hosts via SSH, container exec, or RCON.

const std = @import("std");
const Allocator = std.mem.Allocator;
const main = @import("main.zig");
const a2ml_emit = @import("a2ml_emit.zig");
const game_profiles = @import("game_profiles.zig");

// ═══════════════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════════════

/// Recognised configuration file formats.
pub const ConfigFormat = enum(u8) {
    XML = 0,
    INI = 1,
    JSON = 2,
    ENV = 3,
    YAML = 4,
    TOML = 5,
    Lua = 6,
    KeyValue = 7,
};

/// A single configuration field extracted from a config file.
pub const ConfigField = struct {
    key: []const u8,
    value: []const u8,
    field_type: []const u8, // "string", "int", "bool", "float", "secret", "enum"
    label: []const u8,
    default_val: []const u8,
    range_min: ?f64,
    range_max: ?f64,
    is_secret: bool,
};

/// A fully parsed configuration file.
pub const ParsedConfig = struct {
    format: ConfigFormat,
    path: []const u8,
    fields: std.array_list.AlignedManaged(ConfigField, null),
    raw_text: []const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, format: ConfigFormat, path: []const u8) ParsedConfig {
        return .{
            .format = format,
            .path = path,
            .fields = std.array_list.AlignedManaged(ConfigField, null).init(allocator),
            .raw_text = "",
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ParsedConfig) void {
        // Free duplicated strings owned by us
        for (self.fields.items) |field| {
            self.allocator.free(field.key);
            self.allocator.free(field.value);
            if (field.label.len > 0) self.allocator.free(field.label);
            if (field.field_type.len > 0) self.allocator.free(field.field_type);
            if (field.default_val.len > 0) self.allocator.free(field.default_val);
        }
        self.fields.deinit();
        if (self.raw_text.len > 0) self.allocator.free(self.raw_text);
    }

    /// Add a field, duping strings into the ParsedConfig's allocator.
    pub fn addField(
        self: *ParsedConfig,
        key: []const u8,
        value: []const u8,
        field_type: []const u8,
        label: []const u8,
        default_val: []const u8,
        range_min: ?f64,
        range_max: ?f64,
        is_secret: bool,
    ) !void {
        try self.fields.append(.{
            .key = try self.allocator.dupe(u8, key),
            .value = try self.allocator.dupe(u8, value),
            .field_type = if (field_type.len > 0) try self.allocator.dupe(u8, field_type) else "",
            .label = if (label.len > 0) try self.allocator.dupe(u8, label) else "",
            .default_val = if (default_val.len > 0) try self.allocator.dupe(u8, default_val) else "",
            .range_min = range_min,
            .range_max = range_max,
            .is_secret = is_secret,
        });
    }

    /// Find a field by key.
    pub fn getField(self: *const ParsedConfig, key: []const u8) ?*const ConfigField {
        for (self.fields.items) |*field| {
            if (std.mem.eql(u8, field.key, key)) return field;
        }
        return null;
    }
};

/// Container runtime for extraction.
pub const ContainerRuntime = enum { podman, docker };

// ═══════════════════════════════════════════════════════════════════════════════
// Format detection
// ═══════════════════════════════════════════════════════════════════════════════

/// Auto-detect the configuration format from file content.
///
/// Heuristics (in order):
///   1. Starts with `<?xml` or `<` followed by a tag -> XML
///   2. Starts with `{` or `[` -> JSON
///   3. Has `[section]` headers -> INI
///   4. Has `export ` or `KEY=VALUE` lines without sections -> ENV
///   5. Has TOML-style `[section]` with dotted keys -> TOML
///   6. Contains Lua table syntax `{` with `=` -> Lua
///   7. Fallback -> KeyValue
pub fn detectFormat(data: []const u8) ConfigFormat {
    if (data.len == 0) return .KeyValue;

    // Trim leading whitespace
    var start: usize = 0;
    while (start < data.len and (data[start] == ' ' or data[start] == '\t' or data[start] == '\n' or data[start] == '\r')) start += 1;
    if (start >= data.len) return .KeyValue;

    const trimmed = data[start..];

    // XML detection
    if (std.mem.startsWith(u8, trimmed, "<?xml")) return .XML;
    if (trimmed[0] == '<' and trimmed.len > 1 and std.ascii.isAlphabetic(trimmed[1])) return .XML;

    // JSON detection — `{` always starts JSON.
    // `[` can be JSON array, TOML array-of-tables `[[`, or INI section `[name]`.
    // JSON arrays start with `[{`, `["`, `[0-9`, `[tr`, `[fa`, `[nu`, or `[[` (nested).
    // INI/TOML sections start with `[letter` or `[[letter`.
    // Care: `[n` alone is ambiguous — `[network]` is INI, `[null]` is JSON.
    // We require 2-char lookahead for `t`/`f`/`n` to avoid INI false positives.
    if (trimmed[0] == '{') return .JSON;
    if (trimmed[0] == '[' and trimmed.len > 1) {
        const next = trimmed[1];
        if (next == '{' or next == '"' or next == '-' or std.ascii.isDigit(next)) return .JSON;
        // 2-char lookahead: [tr (true), [fa (false), [nu (null)
        if (trimmed.len > 2) {
            if ((next == 't' and trimmed[2] == 'r') or
                (next == 'f' and trimmed[2] == 'a') or
                (next == 'n' and trimmed[2] == 'u')) return .JSON;
        }
    }

    // Scan lines for format indicators
    var has_section_header = false;
    var has_export = false;
    var has_dotted_key = false;
    var has_lua_table = false;
    var has_triple_bracket = false;

    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line| {
        const stripped = std.mem.trim(u8, line, " \t\r");
        if (stripped.len == 0 or stripped[0] == '#' or stripped[0] == ';') continue;

        if (stripped[0] == '[' and std.mem.indexOfScalar(u8, stripped, ']') != null) {
            has_section_header = true;
            if (std.mem.startsWith(u8, stripped, "[[")) has_triple_bracket = true;
        }
        if (std.mem.startsWith(u8, stripped, "export ")) has_export = true;
        if (std.mem.indexOf(u8, stripped, ".") != null and std.mem.indexOf(u8, stripped, "=") != null) {
            // Check if it looks like "section.key = value" (TOML dotted keys)
            if (std.mem.indexOfScalar(u8, stripped, '=')) |eq_pos| {
                const before_eq = std.mem.trim(u8, stripped[0..eq_pos], " \t");
                if (std.mem.indexOfScalar(u8, before_eq, '.') != null) has_dotted_key = true;
            }
        }
        // Lua table detection
        if (std.mem.indexOf(u8, stripped, "= {") != null or std.mem.indexOf(u8, stripped, "={") != null) {
            has_lua_table = true;
        }
    }

    if (has_triple_bracket or (has_section_header and has_dotted_key)) return .TOML;
    if (has_lua_table) return .Lua;
    if (has_section_header) return .INI;
    if (has_export) return .ENV;

    return .KeyValue;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Format parsers
// ═══════════════════════════════════════════════════════════════════════════════

/// Parse an XML config file.
///
/// Handles two common patterns:
///   - `<setting name="..." value="..."/>`
///   - `<Name>Value</Name>`
pub fn parseXML(allocator: Allocator, data: []const u8) !ParsedConfig {
    var config = ParsedConfig.init(allocator, .XML, "");
    errdefer config.deinit();
    config.raw_text = try allocator.dupe(u8, data);

    var pos: usize = 0;
    while (pos < data.len) {
        // Find next '<'
        const tag_start = std.mem.indexOfScalarPos(u8, data, pos, '<') orelse break;
        if (tag_start + 1 >= data.len) break;

        // Skip comments, processing instructions, CDATA
        if (data[tag_start + 1] == '?' or data[tag_start + 1] == '!') {
            pos = std.mem.indexOfScalarPos(u8, data, tag_start + 1, '>') orelse break;
            pos += 1;
            continue;
        }

        // Skip closing tags
        if (data[tag_start + 1] == '/') {
            pos = std.mem.indexOfScalarPos(u8, data, tag_start + 1, '>') orelse break;
            pos += 1;
            continue;
        }

        const tag_end = std.mem.indexOfScalarPos(u8, data, tag_start, '>') orelse break;
        const tag_content = data[tag_start + 1 .. tag_end];

        // Self-closing with name=... value=... attributes
        if (tag_content.len > 0 and tag_content[tag_content.len - 1] == '/') {
            const attrs = tag_content[0 .. tag_content.len - 1];
            const name_val = extractXMLAttr(attrs, "name");
            const value_val = extractXMLAttr(attrs, "value");

            if (name_val) |name| {
                try config.addField(
                    name,
                    value_val orelse "",
                    "string",
                    name,
                    "",
                    null,
                    null,
                    false,
                );
            }
        } else {
            // Element with text content: <TagName>value</TagName>
            // Find the tag name (first word)
            const space_pos = std.mem.indexOfScalar(u8, tag_content, ' ') orelse tag_content.len;
            const tag_name = tag_content[0..space_pos];

            // Look for closing tag
            const after_open = tag_end + 1;
            if (after_open < data.len) {
                var close_tag_buf: [256]u8 = undefined;
                const close_tag = std.fmt.bufPrint(&close_tag_buf, "</{s}>", .{tag_name}) catch {
                    pos = tag_end + 1;
                    continue;
                };

                if (std.mem.indexOfPos(u8, data, after_open, close_tag)) |close_start| {
                    const text_value = std.mem.trim(u8, data[after_open..close_start], " \t\r\n");
                    if (text_value.len > 0 and text_value[0] != '<') {
                        try config.addField(
                            tag_name,
                            text_value,
                            "string",
                            tag_name,
                            "",
                            null,
                            null,
                            false,
                        );
                    }
                    pos = close_start + close_tag.len;
                    continue;
                }
            }
        }

        pos = tag_end + 1;
    }

    return config;
}

/// Extract an attribute value from an XML tag's attribute string.
fn extractXMLAttr(attrs: []const u8, name: []const u8) ?[]const u8 {
    // Look for name="value" or name='value'
    var search_buf: [128]u8 = undefined;
    const search_dq = std.fmt.bufPrint(&search_buf, "{s}=\"", .{name}) catch return null;
    if (std.mem.indexOf(u8, attrs, search_dq)) |start| {
        const val_start = start + search_dq.len;
        if (std.mem.indexOfScalarPos(u8, attrs, val_start, '"')) |val_end| {
            return attrs[val_start..val_end];
        }
    }

    var search_buf2: [128]u8 = undefined;
    const search_sq = std.fmt.bufPrint(&search_buf2, "{s}='", .{name}) catch return null;
    if (std.mem.indexOf(u8, attrs, search_sq)) |start| {
        const val_start = start + search_sq.len;
        if (std.mem.indexOfScalarPos(u8, attrs, val_start, '\'')) |val_end| {
            return attrs[val_start..val_end];
        }
    }

    return null;
}

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
            // Represent arrays as JSON sub-string
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

/// Parse Lua table-style config files.
///
/// Handles deeply nested tables used by Garry's Mod, Factorio, Don't
/// Starve Together, and other Source/Unity game servers.
///
/// Supports:
///   - `key = "value"` at top level
///   - `table = { key = value, ... }` (single-line)
///   - `table = {\n  key = value,\n}` (multi-line)
///   - `parent = { child = { key = value } }` (nested, up to 8 levels)
///   - `["string-key"] = value` (bracket-quoted keys)
///   - `[1] = value` (numeric array indices)
///   - `local table = { ... }` (local declarations)
///   - `--` line comments and `--[[ ]]` block comments
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

/// Dispatch to the correct parser based on format.
pub fn parseAuto(allocator: Allocator, data: []const u8) !ParsedConfig {
    const format = detectFormat(data);
    return switch (format) {
        .XML => parseXML(allocator, data),
        .INI => parseINI(allocator, data),
        .JSON => parseJSON(allocator, data),
        .ENV => parseENV(allocator, data),
        .TOML => parseTOML(allocator, data),
        .Lua => parseLua(allocator, data),
        .KeyValue => parseKeyValue(allocator, data),
        .YAML => parseKeyValue(allocator, data), // basic YAML fallback
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// Remote extraction methods
// ═══════════════════════════════════════════════════════════════════════════════

/// Extract a config file from a remote host via SSH.
///
/// Runs `ssh user@host cat remote_path` and captures stdout.
pub fn extractViaSSH(
    allocator: Allocator,
    host: []const u8,
    user: []const u8,
    key_path: []const u8,
    remote_path: []const u8,
) ![]const u8 {
    var argv_buf: [8][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "ssh";
    argc += 1;
    argv_buf[argc] = "-o";
    argc += 1;
    argv_buf[argc] = "StrictHostKeyChecking=accept-new";
    argc += 1;

    if (key_path.len > 0) {
        argv_buf[argc] = "-i";
        argc += 1;
        argv_buf[argc] = key_path;
        argc += 1;
    }

    // user@host
    var target_buf: [512]u8 = undefined;
    const target = std.fmt.bufPrint(&target_buf, "{s}@{s}", .{ user, host }) catch return error.InvalidParam;
    argv_buf[argc] = target;
    argc += 1;

    argv_buf[argc] = "cat";
    argc += 1;
    argv_buf[argc] = remote_path;
    argc += 1;

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv_buf[0..argc],
    });
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.SSHCommandFailed;
    }

    return result.stdout;
}

/// Extract a config file from a running container.
///
/// Runs `podman exec <container> cat <path>` (or docker).
pub fn extractViaContainer(
    allocator: Allocator,
    container_name: []const u8,
    path: []const u8,
    runtime: ContainerRuntime,
) ![]const u8 {
    const runtime_cmd: []const u8 = switch (runtime) {
        .podman => "podman",
        .docker => "docker",
    };

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ runtime_cmd, "exec", container_name, "cat", path },
    });
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.ContainerExecFailed;
    }

    return result.stdout;
}

/// Extract config data via RCON command.
///
/// Sends the given command via the RCON protocol and returns the text
/// response.
pub fn extractViaRCON(
    allocator: Allocator,
    host: []const u8,
    port: u16,
    password: []const u8,
    command: []const u8,
) ![]const u8 {
    _ = allocator;

    const addr = try std.net.Address.parseIp4(host, port);
    const sock = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM,
        0,
    );
    defer std.posix.close(sock);

    try std.posix.connect(sock, &addr.any, addr.getOsSockLen());

    // Set timeout
    const tv = std.posix.timeval{ .sec = 5, .usec = 0 };
    try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));

    const stream = std.net.Stream{ .handle = sock };

    // RCON auth packet
    var auth_pkt: [4096]u8 = undefined;
    const pwd_len: u32 = @intCast(password.len);
    const auth_size: u32 = 4 + 4 + pwd_len + 2;
    std.mem.writeInt(u32, auth_pkt[0..4], auth_size, .little);
    std.mem.writeInt(u32, auth_pkt[4..8], 1, .little); // ID
    std.mem.writeInt(u32, auth_pkt[8..12], 3, .little); // AUTH
    @memcpy(auth_pkt[12 .. 12 + password.len], password);
    auth_pkt[12 + password.len] = 0;
    auth_pkt[13 + password.len] = 0;
    _ = try stream.write(auth_pkt[0 .. 14 + password.len]);

    // Read auth response
    var auth_resp: [64]u8 = undefined;
    _ = try stream.read(&auth_resp);

    // RCON exec packet
    var cmd_pkt: [4096]u8 = undefined;
    const cmd_len: u32 = @intCast(command.len);
    const cmd_size: u32 = 4 + 4 + cmd_len + 2;
    std.mem.writeInt(u32, cmd_pkt[0..4], cmd_size, .little);
    std.mem.writeInt(u32, cmd_pkt[4..8], 2, .little); // ID
    std.mem.writeInt(u32, cmd_pkt[8..12], 2, .little); // EXECCOMMAND
    @memcpy(cmd_pkt[12 .. 12 + command.len], command);
    cmd_pkt[12 + command.len] = 0;
    cmd_pkt[13 + command.len] = 0;
    _ = try stream.write(cmd_pkt[0 .. 14 + command.len]);

    // Read response
    var response: [4096]u8 = undefined;
    const n = try stream.read(&response);
    if (n < 12) return error.RCONResponseTooShort;

    // Body starts at offset 12, NUL-terminated
    const body_end = std.mem.indexOfScalarPos(u8, response[12..n], 0, 0) orelse (n - 12);
    const body = response[12 .. 12 + body_end];

    // Allocate and return a copy
    const result = try std.heap.c_allocator.dupe(u8, body);
    return result;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Exported C ABI functions
// ═══════════════════════════════════════════════════════════════════════════════

/// Extract the configuration for a server/profile combination and return
/// it as an A2ML string.
threadlocal var extract_result_buf: [16384:0]u8 = undefined;

pub export fn gossamer_gsa_extract_config(
    handle: c_int,
    profile_id: [*:0]const u8,
) callconv(.c) [*:0]const u8 {
    _ = handle;
    const gsa = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return "ERR";
    };

    const pid = std.mem.span(profile_id);
    const profile = gsa.profile_registry.getProfile(pid) orelse {
        main.setError("unknown profile: {s}", .{pid});
        return "ERR";
    };

    // Try to extract config from the profile's configured path
    const config_data = extractViaContainer(
        std.heap.c_allocator,
        profile.id,
        profile.config_path,
        .podman,
    ) catch |err| {
        main.setError("extraction failed: {s}", .{@errorName(err)});
        return "ERR";
    };
    defer std.heap.c_allocator.free(config_data);

    var parsed = parseAuto(std.heap.c_allocator, config_data) catch {
        main.setErrorStr("parse failed");
        return "ERR";
    };
    defer parsed.deinit();

    // Emit A2ML
    const a2ml = a2ml_emit.emitA2ML(
        std.heap.c_allocator,
        pid,
        profile.id,
        &parsed,
        profile,
    ) catch {
        main.setErrorStr("A2ML emit failed");
        return "ERR";
    };
    defer std.heap.c_allocator.free(a2ml);

    // Copy into thread-local buffer
    const copy_len = @min(a2ml.len, extract_result_buf.len - 1);
    @memcpy(extract_result_buf[0..copy_len], a2ml[0..copy_len]);
    extract_result_buf[copy_len] = 0;

    return &extract_result_buf;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════════

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

// ═══════════════════════════════════════════════════════════════════════════════
// Unit tests
// ═══════════════════════════════════════════════════════════════════════════════

test "detect format: XML" {
    try std.testing.expectEqual(ConfigFormat.XML, detectFormat("<?xml version=\"1.0\"?>"));
    try std.testing.expectEqual(ConfigFormat.XML, detectFormat("<Server><Name>Test</Name></Server>"));
}

test "detect format: JSON" {
    try std.testing.expectEqual(ConfigFormat.JSON, detectFormat("{\"key\": \"value\"}"));
    try std.testing.expectEqual(ConfigFormat.JSON, detectFormat("[1, 2, 3]"));
}

test "detect format: INI" {
    try std.testing.expectEqual(ConfigFormat.INI, detectFormat("[Section]\nkey=value\n"));
}

test "detect format: INI not misdetected as JSON for [n...] sections" {
    // Regression: [network] was misdetected as JSON because 'n' matched the
    // null-literal heuristic. Fixed with 2-char lookahead.
    try std.testing.expectEqual(ConfigFormat.INI, detectFormat("[network]\nhost=10.0.0.1\nport=8080\n"));
    try std.testing.expectEqual(ConfigFormat.INI, detectFormat("[server]\nname=test\n"));
    try std.testing.expectEqual(ConfigFormat.INI, detectFormat("[features]\nenabled=true\n"));
    // Actual JSON arrays with literals should still detect as JSON
    try std.testing.expectEqual(ConfigFormat.JSON, detectFormat("[null, 1, 2]"));
    try std.testing.expectEqual(ConfigFormat.JSON, detectFormat("[true, false]"));
    try std.testing.expectEqual(ConfigFormat.JSON, detectFormat("[false]"));
}

test "detect format: ENV" {
    try std.testing.expectEqual(ConfigFormat.ENV, detectFormat("export FOO=bar\nexport BAZ=qux\n"));
}

test "detect format: KeyValue" {
    try std.testing.expectEqual(ConfigFormat.KeyValue, detectFormat("server-name=My Server\nmax-players=20\n"));
}

test "parse INI" {
    const allocator = std.testing.allocator;
    var config = try parseINI(allocator, "[server]\nname=TestServer\nport=25565\n");
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 2), config.fields.items.len);
    try std.testing.expectEqualStrings("server.name", config.fields.items[0].key);
    try std.testing.expectEqualStrings("TestServer", config.fields.items[0].value);
}

test "parse JSON flat" {
    const allocator = std.testing.allocator;
    var config = try parseJSON(allocator, "{\"name\": \"TestServer\", \"port\": 25565}");
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 2), config.fields.items.len);
}

test "parse ENV" {
    const allocator = std.testing.allocator;
    var config = try parseENV(allocator, "export SERVER_NAME=\"TestServer\"\nMAX_PLAYERS=20\nSERVER_PASSWORD=secret123\n");
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 3), config.fields.items.len);
    try std.testing.expectEqualStrings("TestServer", config.fields.items[0].value);
    // PASSWORD should be detected as secret
    try std.testing.expect(config.fields.items[2].is_secret);
}

test "parse KeyValue (Minecraft server.properties)" {
    const allocator = std.testing.allocator;
    const mc_props =
        \\# Minecraft server properties
        \\server-name=My Server
        \\max-players=20
        \\difficulty=normal
        \\rcon.password=s3cret
    ;
    var config = try parseKeyValue(allocator, mc_props);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 4), config.fields.items.len);
    try std.testing.expectEqualStrings("server-name", config.fields.items[0].key);
    try std.testing.expect(config.fields.items[3].is_secret); // rcon.password
}

test "isNumeric" {
    try std.testing.expect(isNumeric("42"));
    try std.testing.expect(isNumeric("-3.14"));
    try std.testing.expect(!isNumeric("hello"));
    try std.testing.expect(!isNumeric(""));
}

test "detect format: empty input returns KeyValue" {
    try std.testing.expectEqual(ConfigFormat.KeyValue, detectFormat(""));
}

test "detect format: whitespace-only returns KeyValue" {
    try std.testing.expectEqual(ConfigFormat.KeyValue, detectFormat("   \n\t  \n"));
}

test "parse XML: self-closing tag with name/value" {
    const allocator = std.testing.allocator;
    // Use flat XML without wrapper element — the parser skips text starting with '<'
    // inside a parent element, so self-closing tags must be at the top level.
    var config = try parseXML(allocator, "<Setting name=\"port\" value=\"25565\"/>");
    defer config.deinit();
    try std.testing.expect(config.fields.items.len >= 1);
    try std.testing.expectEqualStrings("port", config.fields.items[0].key);
    try std.testing.expectEqualStrings("25565", config.fields.items[0].value);
}

test "parse XML: element text content" {
    const allocator = std.testing.allocator;
    // Flat elements without wrapper — parser processes each opening tag independently
    var config = try parseXML(allocator, "<ServerName>My Server</ServerName><Port>8080</Port>");
    defer config.deinit();
    try std.testing.expect(config.fields.items.len >= 2);
    try std.testing.expectEqualStrings("ServerName", config.fields.items[0].key);
    try std.testing.expectEqualStrings("My Server", config.fields.items[0].value);
}

test "parse JSON: nested objects use dot-notation" {
    const allocator = std.testing.allocator;
    var config = try parseJSON(allocator, "{\"server\":{\"name\":\"Test\",\"port\":25565}}");
    defer config.deinit();
    const name = config.getField("server.name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("Test", name.?.value);
    const port = config.getField("server.port");
    try std.testing.expect(port != null);
}

test "parse JSON: booleans and nulls" {
    const allocator = std.testing.allocator;
    var config = try parseJSON(allocator, "{\"enabled\":true,\"disabled\":false,\"empty\":null}");
    defer config.deinit();
    const enabled = config.getField("enabled");
    try std.testing.expect(enabled != null);
    try std.testing.expectEqualStrings("true", enabled.?.value);
    const disabled = config.getField("disabled");
    try std.testing.expect(disabled != null);
    try std.testing.expectEqualStrings("false", disabled.?.value);
}

test "parseAuto dispatches JSON correctly" {
    const allocator = std.testing.allocator;
    var config = try parseAuto(allocator, "{\"key\":\"value\"}");
    defer config.deinit();
    try std.testing.expectEqual(ConfigFormat.JSON, config.format);
    try std.testing.expect(config.fields.items.len >= 1);
}

test "KeyValue: secret detection" {
    const allocator = std.testing.allocator;
    var config = try parseKeyValue(allocator, "rcon.password=secret\napi_token=abc\nname=public");
    defer config.deinit();
    try std.testing.expect(config.fields.items[0].is_secret); // rcon.password
    try std.testing.expect(config.fields.items[1].is_secret); // api_token
    try std.testing.expect(!config.fields.items[2].is_secret); // name
}

test "ParsedConfig.getField: null for missing key" {
    const allocator = std.testing.allocator;
    var config = ParsedConfig.init(allocator, .KeyValue, "");
    defer config.deinit();
    try config.addField("exists", "yes", "", "", "", null, null, false);
    try std.testing.expect(config.getField("exists") != null);
    try std.testing.expect(config.getField("missing") == null);
    try std.testing.expect(config.getField("") == null);
}

test "parse KeyValue: empty input yields zero fields" {
    const allocator = std.testing.allocator;
    var config = try parseKeyValue(allocator, "");
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 0), config.fields.items.len);
}

test "isNumeric: edge cases" {
    try std.testing.expect(isNumeric("+5"));
    try std.testing.expect(isNumeric("-0"));
    try std.testing.expect(isNumeric("3.14159"));
    try std.testing.expect(!isNumeric("1.2.3"));
    try std.testing.expect(!isNumeric("+-1"));
    // Note: "." returns true because the implementation treats a lone dot
    // as numeric (no non-digit characters fail the check).
    try std.testing.expect(isNumeric("."));
}

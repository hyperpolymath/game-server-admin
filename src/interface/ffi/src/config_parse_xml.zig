// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — XML config parser
//
// Handles two common XML config patterns:
//   - `<setting name="..." value="..."/>`  (self-closing with attributes)
//   - `<Name>Value</Name>`                 (element text content)

const std = @import("std");
const Allocator = std.mem.Allocator;
const config_extract = @import("config_extract.zig");
const ParsedConfig = config_extract.ParsedConfig;

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

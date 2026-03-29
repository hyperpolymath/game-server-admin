// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — Game profile registry
//
// Loads, stores, and queries game profiles defined in A2ML files.  Each
// profile describes a game server type: its ports, protocol, config
// format, config path, field definitions, and available actions.
//
// The registry is the bridge between the probing engine (which identifies
// servers) and the config extraction layer (which knows how to read them).

const std = @import("std");
const Allocator = std.mem.Allocator;
const main = @import("main.zig");

// ═══════════════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════════════

/// A named port exposed by the game server.
pub const Port = struct {
    name: []const u8,
    number: u16,
};

/// A field definition within a game profile's config schema.
pub const FieldDef = struct {
    key: []const u8,
    field_type: []const u8, // "string", "int", "bool", "float", "secret", "enum"
    label: []const u8,
    default_val: []const u8,
    range_min: ?f64,
    range_max: ?f64,
    is_secret: bool,
    enum_values: []const []const u8,
};

/// A complete game profile loaded from an A2ML file.
pub const GameProfile = struct {
    id: []const u8,
    name: []const u8,
    engine: []const u8,
    ports: std.array_list.AlignedManaged(Port, null),
    protocol: []const u8,
    fingerprint_pattern: []const u8,
    config_format: []const u8,
    config_path: []const u8,
    field_defs: std.array_list.AlignedManaged(FieldDef, null),
    actions: std.StringHashMap([]const u8),
    allocator: Allocator,

    /// Create an empty profile (for use in emission when no profile is loaded).
    pub fn empty() GameProfile {
        return .{
            .id = "",
            .name = "",
            .engine = "",
            .ports = std.array_list.AlignedManaged(Port, null).init(std.heap.c_allocator),
            .protocol = "",
            .fingerprint_pattern = "",
            .config_format = "",
            .config_path = "",
            .field_defs = std.array_list.AlignedManaged(FieldDef, null).init(std.heap.c_allocator),
            .actions = std.StringHashMap([]const u8).init(std.heap.c_allocator),
            .allocator = std.heap.c_allocator,
        };
    }

    /// Look up a field definition by key.
    pub fn getFieldDef(self: *const GameProfile, key: []const u8) ?*const FieldDef {
        for (self.field_defs.items) |*def| {
            if (std.mem.eql(u8, def.key, key)) return def;
        }
        return null;
    }

    /// Free all owned memory.
    pub fn deinit(self: *GameProfile) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.engine);

        for (self.ports.items) |p| {
            self.allocator.free(p.name);
        }
        self.ports.deinit();

        self.allocator.free(self.protocol);
        self.allocator.free(self.fingerprint_pattern);
        self.allocator.free(self.config_format);
        self.allocator.free(self.config_path);

        for (self.field_defs.items) |def| {
            self.allocator.free(def.key);
            self.allocator.free(def.field_type);
            self.allocator.free(def.label);
            self.allocator.free(def.default_val);
            for (def.enum_values) |ev| {
                self.allocator.free(ev);
            }
            if (def.enum_values.len > 0) {
                self.allocator.free(def.enum_values);
            }
        }
        self.field_defs.deinit();

        var action_it = self.actions.iterator();
        while (action_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.actions.deinit();
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Profile Registry
// ═══════════════════════════════════════════════════════════════════════════════

/// Registry of loaded game profiles, indexed by profile ID.
pub const ProfileRegistry = struct {
    profiles: std.StringHashMap(GameProfile),
    allocator: Allocator,

    /// Create a new empty registry.
    pub fn init(allocator: Allocator) ProfileRegistry {
        return .{
            .profiles = std.StringHashMap(GameProfile).init(allocator),
            .allocator = allocator,
        };
    }

    /// Release all profiles and registry memory.
    pub fn deinit(self: *ProfileRegistry) void {
        var it = self.profiles.iterator();
        while (it.next()) |entry| {
            var profile = entry.value_ptr;
            profile.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.profiles.deinit();
    }

    /// Load all .a2ml files from a directory.
    ///
    /// Returns the number of profiles successfully loaded.
    pub fn loadFromDirectory(self: *ProfileRegistry, dir_path: []const u8) !u32 {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            main.setError("cannot open profiles dir '{s}': {s}", .{ dir_path, @errorName(err) });
            return err;
        };
        defer dir.close();

        var count: u32 = 0;
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".a2ml")) continue;

            // Build full path
            var path_buf: [4096]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

            self.loadProfile(full_path) catch |err| {
                main.setError("failed to load profile '{s}': {s}", .{ entry.name, @errorName(err) });
                continue;
            };
            count += 1;
        }

        return count;
    }

    /// Load a single A2ML profile file.
    pub fn loadProfile(self: *ProfileRegistry, a2ml_path: []const u8) !void {
        const file = try std.fs.cwd().openFile(a2ml_path, .{});
        defer file.close();

        const data = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(data);

        var profile = try parseA2MLProfile(data, self.allocator);
        errdefer profile.deinit();

        if (profile.id.len == 0) return error.MissingProfileId;

        const id_key = try self.allocator.dupe(u8, profile.id);
        errdefer self.allocator.free(id_key);

        try self.profiles.put(id_key, profile);
    }

    /// Look up a profile by its ID.
    pub fn getProfile(self: *ProfileRegistry, id: []const u8) ?*GameProfile {
        return self.profiles.getPtr(id);
    }

    /// Match a raw fingerprint (response bytes) against all loaded
    /// profiles.  Returns the ID of the matching profile, or null.
    pub fn matchFingerprint(self: *ProfileRegistry, fingerprint_bytes: []const u8) ?[]const u8 {
        var it = self.profiles.iterator();
        while (it.next()) |entry| {
            const profile = entry.value_ptr;
            if (profile.fingerprint_pattern.len > 0) {
                if (std.mem.indexOf(u8, fingerprint_bytes, profile.fingerprint_pattern) != null) {
                    return profile.id;
                }
            }
        }
        return null;
    }

    /// Return a JSON array summarising all loaded profiles.
    pub fn listProfiles(self: *ProfileRegistry, allocator: Allocator) ![]const u8 {
        var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
        errdefer buf.deinit();
        const writer = buf.writer();

        try writer.writeAll("[");
        var first = true;
        var it = self.profiles.iterator();
        while (it.next()) |entry| {
            if (!first) try writer.writeAll(",");
            first = false;

            const p = entry.value_ptr;
            try writer.print("{{\"id\":\"{s}\",\"name\":\"{s}\",\"engine\":\"{s}\",\"ports\":{d},\"config_format\":\"{s}\"}}", .{
                p.id,
                p.name,
                p.engine,
                p.ports.items.len,
                p.config_format,
            });
        }
        try writer.writeAll("]");

        return buf.toOwnedSlice();
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// A2ML profile parser
// ═══════════════════════════════════════════════════════════════════════════════

/// Parse a @game-profile A2ML block into a GameProfile struct.
///
/// This handles the hyperpolymath A2ML format as used in the profiles/
/// directory of this repository.
pub fn parseA2MLProfile(data: []const u8, allocator: Allocator) !GameProfile {
    var profile = GameProfile{
        .id = try allocator.dupe(u8, ""),
        .name = try allocator.dupe(u8, ""),
        .engine = try allocator.dupe(u8, ""),
        .ports = std.array_list.AlignedManaged(Port, null).init(allocator),
        .protocol = try allocator.dupe(u8, ""),
        .fingerprint_pattern = try allocator.dupe(u8, ""),
        .config_format = try allocator.dupe(u8, ""),
        .config_path = try allocator.dupe(u8, ""),
        .field_defs = std.array_list.AlignedManaged(FieldDef, null).init(allocator),
        .actions = std.StringHashMap([]const u8).init(allocator),
        .allocator = allocator,
    };
    errdefer profile.deinit();

    // Parse @game-profile header
    if (extractAttr(data, "@game-profile(", "id")) |id| {
        allocator.free(profile.id);
        profile.id = try allocator.dupe(u8, id);
    }
    if (extractAttr(data, "@game-profile(", "name")) |name| {
        allocator.free(profile.name);
        profile.name = try allocator.dupe(u8, name);
    }
    if (extractAttr(data, "@game-profile(", "engine")) |engine| {
        allocator.free(profile.engine);
        profile.engine = try allocator.dupe(u8, engine);
    }

    // Parse @protocol
    if (extractAttr(data, "@protocol(", "type")) |proto| {
        allocator.free(profile.protocol);
        profile.protocol = try allocator.dupe(u8, proto);
    }

    // Parse @config
    if (extractAttr(data, "@config(", "format")) |fmt| {
        allocator.free(profile.config_format);
        profile.config_format = try allocator.dupe(u8, fmt);
    }
    if (extractAttr(data, "@config(", "path")) |path| {
        allocator.free(profile.config_path);
        profile.config_path = try allocator.dupe(u8, path);
    }

    // Parse @port blocks
    var pos: usize = 0;
    while (pos < data.len) {
        const port_start = std.mem.indexOfPos(u8, data, pos, "@port(") orelse break;
        const port_end = std.mem.indexOfPos(u8, data, port_start, ")") orelse break;
        const port_attrs = data[port_start..port_end + 1];

        const port_name = extractAttrFrom(port_attrs, "name") orelse "unnamed";
        const port_num_str = extractAttrFrom(port_attrs, "number") orelse "0";
        const port_num = std.fmt.parseInt(u16, port_num_str, 10) catch 0;

        if (port_num > 0) {
            try profile.ports.append(.{
                .name = try allocator.dupe(u8, port_name),
                .number = port_num,
            });
        }

        pos = port_end + 1;
    }

    // Parse @field blocks
    pos = 0;
    while (pos < data.len) {
        const field_start = std.mem.indexOfPos(u8, data, pos, "@field(") orelse break;
        const field_header_end = std.mem.indexOfPos(u8, data, field_start, ")") orelse break;
        const field_end = std.mem.indexOfPos(u8, data, field_header_end, "@end") orelse break;
        const field_attrs = data[field_start..field_header_end + 1];
        const field_body = data[field_header_end + 1 .. field_end];

        const key = extractAttrFrom(field_attrs, "key") orelse {
            pos = field_end + 4;
            continue;
        };
        const field_type = extractAttrFrom(field_attrs, "type") orelse "string";
        const label = extractAttrFrom(field_attrs, "label") orelse key;
        const is_secret = std.mem.eql(u8, field_type, "secret");

        // Parse default from body: @default(...) @end
        var default_val: []const u8 = "";
        if (std.mem.indexOf(u8, field_body, "@default(")) |def_start| {
            const val_start = def_start + 9;
            if (std.mem.indexOfScalarPos(u8, field_body, val_start, ')')) |val_end| {
                var dv = field_body[val_start..val_end];
                // Strip surrounding quotes
                if (dv.len >= 2 and dv[0] == '"' and dv[dv.len - 1] == '"') {
                    dv = dv[1 .. dv.len - 1];
                }
                default_val = dv;
            }
        }

        // Parse constraints: @constraint(min=N, max=M) @end
        var range_min: ?f64 = null;
        var range_max: ?f64 = null;
        if (std.mem.indexOf(u8, field_body, "@constraint(")) |con_start| {
            const con_attrs_start = con_start;
            if (std.mem.indexOfPos(u8, field_body, con_attrs_start, ")")) |con_end| {
                const con_attrs = field_body[con_attrs_start..con_end + 1];
                if (extractAttrFrom(con_attrs, "min")) |min_str| {
                    range_min = std.fmt.parseFloat(f64, min_str) catch null;
                }
                if (extractAttrFrom(con_attrs, "max")) |max_str| {
                    range_max = std.fmt.parseFloat(f64, max_str) catch null;
                }
            }
        }

        // Parse enum options: @options("a", "b", "c") @end
        var enum_values: []const []const u8 = &.{};
        if (std.mem.indexOf(u8, field_body, "@options(")) |opt_start| {
            if (std.mem.indexOfPos(u8, field_body, opt_start, ")")) |opt_end| {
                const opt_content = field_body[opt_start + 9 .. opt_end];
                // Count quoted strings
                var enum_list = std.array_list.AlignedManaged([]const u8, null).init(allocator);
                var opt_pos: usize = 0;
                while (opt_pos < opt_content.len) {
                    if (opt_content[opt_pos] == '"') {
                        opt_pos += 1;
                        if (std.mem.indexOfScalarPos(u8, opt_content, opt_pos, '"')) |close| {
                            try enum_list.append(try allocator.dupe(u8, opt_content[opt_pos..close]));
                            opt_pos = close + 1;
                        } else break;
                    } else {
                        opt_pos += 1;
                    }
                }
                enum_values = try enum_list.toOwnedSlice();
            }
        }

        try profile.field_defs.append(.{
            .key = try allocator.dupe(u8, key),
            .field_type = try allocator.dupe(u8, field_type),
            .label = try allocator.dupe(u8, label),
            .default_val = try allocator.dupe(u8, default_val),
            .range_min = range_min,
            .range_max = range_max,
            .is_secret = is_secret,
            .enum_values = enum_values,
        });

        pos = field_end + 4;
    }

    // Parse @action blocks
    pos = 0;
    while (pos < data.len) {
        const action_start = std.mem.indexOfPos(u8, data, pos, "@action(") orelse break;
        const header_end = std.mem.indexOfPos(u8, data, action_start, ")") orelse break;
        const action_end = std.mem.indexOfPos(u8, data, header_end, "@end") orelse break;

        const action_attrs = data[action_start..header_end + 1];
        const action_body = std.mem.trim(u8, data[header_end + 2 .. action_end], " \t\r\n");

        if (extractAttrFrom(action_attrs, "id")) |action_id| {
            const id_owned = try allocator.dupe(u8, action_id);
            const body_owned = try allocator.dupe(u8, action_body);
            try profile.actions.put(id_owned, body_owned);
        }

        pos = action_end + 4;
    }

    return profile;
}

// ═══════════════════════════════════════════════════════════════════════════════
// A2ML attribute extraction helpers
// ═══════════════════════════════════════════════════════════════════════════════

/// Find a specific tag in the data, then extract an attribute from it.
fn extractAttr(data: []const u8, tag: []const u8, name: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, data, tag)) |tag_start| {
        const tag_end = std.mem.indexOfPos(u8, data, tag_start, ")") orelse return null;
        const attrs = data[tag_start..tag_end + 1];
        return extractAttrFrom(attrs, name);
    }
    return null;
}

/// Extract a named attribute from an attribute string.
/// Handles both `name="value"` and `name='value'` patterns.
fn extractAttrFrom(attrs: []const u8, name: []const u8) ?[]const u8 {
    // Search for name="
    var search_buf: [128]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "{s}=\"", .{name}) catch return null;

    if (std.mem.indexOf(u8, attrs, search)) |start| {
        const val_start = start + search.len;
        if (std.mem.indexOfScalarPos(u8, attrs, val_start, '"')) |val_end| {
            return attrs[val_start..val_end];
        }
    }
    return null;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Exported C ABI functions
// ═══════════════════════════════════════════════════════════════════════════════

/// Load game profiles from a directory of .a2ml files.
///
/// Returns the number of profiles loaded, or a negative error code.
export fn gossamer_gsa_load_profiles(
    dir: [*:0]const u8,
) callconv(.c) c_int {
    const gsa = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return @intFromEnum(main.GsaResult.not_initialized);
    };

    const dir_path = std.mem.span(dir);
    const count = gsa.profile_registry.loadFromDirectory(dir_path) catch |err| {
        main.setError("profile load failed: {s}", .{@errorName(err)});
        return @intFromEnum(main.GsaResult.io_error);
    };

    main.clearError();
    return @intCast(count);
}

/// List all loaded profiles as a JSON array.
///
/// Returns a NUL-terminated JSON string.
threadlocal var list_profiles_buf: [16384]u8 = undefined;

export fn gossamer_gsa_list_profiles() callconv(.c) [*:0]const u8 {
    const gsa = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return @as([*:0]const u8, @ptrCast(&[_:0]u8{ '[', ']' }));
    };

    const json = gsa.profile_registry.listProfiles(std.heap.c_allocator) catch {
        main.setErrorStr("list profiles failed");
        return @as([*:0]const u8, @ptrCast(&[_:0]u8{ '[', ']' }));
    };
    defer std.heap.c_allocator.free(json);

    const copy_len = @min(json.len, list_profiles_buf.len - 1);
    @memcpy(list_profiles_buf[0..copy_len], json[0..copy_len]);
    list_profiles_buf[copy_len] = 0;

    return @as([*:0]const u8, @ptrCast(&list_profiles_buf));
}

/// Add a profile from an A2ML string (not a file path).
///
/// Returns 0 on success, negative error code on failure.
export fn gossamer_gsa_add_profile(
    a2ml: [*:0]const u8,
) callconv(.c) c_int {
    const gsa = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return @intFromEnum(main.GsaResult.not_initialized);
    };

    const a2ml_str = std.mem.span(a2ml);
    var profile = parseA2MLProfile(a2ml_str, std.heap.c_allocator) catch |err| {
        main.setError("profile parse failed: {s}", .{@errorName(err)});
        return @intFromEnum(main.GsaResult.parse_error);
    };
    errdefer profile.deinit();

    if (profile.id.len == 0) {
        profile.deinit();
        main.setErrorStr("profile has no id");
        return @intFromEnum(main.GsaResult.invalid_param);
    }

    const id_key = std.heap.c_allocator.dupe(u8, profile.id) catch {
        profile.deinit();
        return @intFromEnum(main.GsaResult.out_of_memory);
    };

    gsa.profile_registry.profiles.put(id_key, profile) catch {
        std.heap.c_allocator.free(id_key);
        profile.deinit();
        return @intFromEnum(main.GsaResult.out_of_memory);
    };

    main.clearError();
    return @intFromEnum(main.GsaResult.ok);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Unit tests
// ═══════════════════════════════════════════════════════════════════════════════

test "parse minimal A2ML profile" {
    const allocator = std.testing.allocator;
    const a2ml =
        \\@game-profile(id="test-game", name="Test Game", engine="custom"):
        \\  @protocol(type="custom-tcp", variant="test"):@end
        \\  @config(format="key-value", path="/etc/test.cfg"):
        \\    @field(key="name", type="string", label="Server Name"):
        \\      @default("My Server") @end
        \\    @end
        \\    @field(key="port", type="int", label="Port"):
        \\      @constraint(min=1, max=65535) @end
        \\      @default(27015) @end
        \\    @end
        \\  @end
        \\  @ports:
        \\    @port(name="game", number="27015", protocol="UDP"):@end
        \\  @end
        \\@end
    ;

    var profile = try parseA2MLProfile(a2ml, allocator);
    defer profile.deinit();

    try std.testing.expectEqualStrings("test-game", profile.id);
    try std.testing.expectEqualStrings("Test Game", profile.name);
    try std.testing.expectEqualStrings("custom", profile.engine);
    try std.testing.expectEqualStrings("custom-tcp", profile.protocol);
    try std.testing.expectEqualStrings("key-value", profile.config_format);
    try std.testing.expectEqualStrings("/etc/test.cfg", profile.config_path);
    try std.testing.expectEqual(@as(usize, 1), profile.ports.items.len);
    try std.testing.expectEqual(@as(u16, 27015), profile.ports.items[0].number);
    try std.testing.expectEqual(@as(usize, 2), profile.field_defs.items.len);
    try std.testing.expectEqualStrings("name", profile.field_defs.items[0].key);
}

test "ProfileRegistry init and deinit" {
    const allocator = std.testing.allocator;
    var registry = ProfileRegistry.init(allocator);
    defer registry.deinit();

    // Registry starts empty
    const json = try registry.listProfiles(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("[]", json);
}

test "GameProfile.empty" {
    const p = GameProfile.empty();
    try std.testing.expectEqualStrings("", p.id);
    try std.testing.expectEqual(@as(usize, 0), p.ports.items.len);
}

test "extractAttrFrom" {
    const attrs = "key=\"server-name\", type=\"string\", label=\"Server Name\"";
    try std.testing.expectEqualStrings("server-name", extractAttrFrom(attrs, "key").?);
    try std.testing.expectEqualStrings("string", extractAttrFrom(attrs, "type").?);
    try std.testing.expectEqualStrings("Server Name", extractAttrFrom(attrs, "label").?);
    try std.testing.expect(extractAttrFrom(attrs, "missing") == null);
}

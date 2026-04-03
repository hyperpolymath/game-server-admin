// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — FFI integration tests
//
// These tests verify that the Zig FFI layer correctly implements the
// C ABI declared in src/interface/abi/*.idr.  They exercise the public
// API surface without requiring a running VeriSimDB instance or live
// game servers.

const std = @import("std");
const testing = std.testing;

// Import all modules via the gsa build module (see build.zig addImport)
const gsa = @import("gsa");
const main = gsa;
const probe = gsa.probe;
const config_extract = gsa.config_extract;
const a2ml_emit = gsa.a2ml_emit;
const verisimdb_client = gsa.verisimdb_client;
const server_actions = gsa.server_actions;
const game_profiles = gsa.game_profiles;

// ═══════════════════════════════════════════════════════════════════════════════
// 1. Result code mapping — all 13 values match Idris2 ABI
// ═══════════════════════════════════════════════════════════════════════════════

test "result codes: all 13 GsaResult values have correct integer mappings" {
    // These must match GameServerAdmin.ABI.Types.Result.resultToInt
    const expected = [_]struct { result: main.GsaResult, value: c_int }{
        .{ .result = .ok, .value = 0 },
        .{ .result = .err, .value = 1 },
        .{ .result = .invalid_param, .value = 2 },
        .{ .result = .out_of_memory, .value = 3 },
        .{ .result = .null_pointer, .value = 4 },
        .{ .result = .not_initialized, .value = 5 },
        .{ .result = .timeout, .value = 6 },
        .{ .result = .connection_refused, .value = 7 },
        .{ .result = .protocol_error, .value = 8 },
        .{ .result = .parse_error, .value = 9 },
        .{ .result = .io_error, .value = 10 },
        .{ .result = .permission_denied, .value = 11 },
        .{ .result = .not_found, .value = 12 },
    };

    // Verify total count
    try testing.expectEqual(@as(usize, 13), expected.len);

    for (expected) |e| {
        try testing.expectEqual(e.value, @intFromEnum(e.result));
    }
}

test "result codes: enum is exhaustive at 13 variants" {
    // Count all variants in the enum by trying to iterate
    const fields = @typeInfo(main.GsaResult).@"enum".fields;
    try testing.expectEqual(@as(usize, 13), fields.len);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 2. Config format detection
// ═══════════════════════════════════════════════════════════════════════════════

test "format detection: XML with processing instruction" {
    try testing.expectEqual(config_extract.ConfigFormat.XML, config_extract.detectFormat(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<ServerConfig>
        \\  <Name>My Server</Name>
        \\</ServerConfig>
    ));
}

test "format detection: XML with bare element" {
    try testing.expectEqual(config_extract.ConfigFormat.XML, config_extract.detectFormat(
        \\<Settings>
        \\  <Setting name="port" value="7777"/>
        \\</Settings>
    ));
}

test "format detection: INI with section headers" {
    try testing.expectEqual(config_extract.ConfigFormat.INI, config_extract.detectFormat(
        \\[Server]
        \\name = My Server
        \\port = 25565
        \\
        \\[Gameplay]
        \\difficulty = normal
    ));
}

test "format detection: JSON object" {
    try testing.expectEqual(config_extract.ConfigFormat.JSON, config_extract.detectFormat(
        \\{
        \\  "name": "My Server",
        \\  "port": 25565
        \\}
    ));
}

test "format detection: JSON array" {
    try testing.expectEqual(config_extract.ConfigFormat.JSON, config_extract.detectFormat(
        \\[{"id": 1}, {"id": 2}]
    ));
}

test "format detection: ENV with exports" {
    try testing.expectEqual(config_extract.ConfigFormat.ENV, config_extract.detectFormat(
        \\export SERVER_NAME="My Server"
        \\export MAX_PLAYERS=20
        \\export DIFFICULTY=normal
    ));
}

test "format detection: TOML with dotted keys" {
    try testing.expectEqual(config_extract.ConfigFormat.TOML, config_extract.detectFormat(
        \\[server]
        \\server.name = "My Server"
        \\server.port = 25565
    ));
}

test "format detection: TOML with array of tables" {
    try testing.expectEqual(config_extract.ConfigFormat.TOML, config_extract.detectFormat(
        \\[[plugins]]
        \\name = "essentials"
        \\enabled = true
    ));
}

test "format detection: Lua table" {
    try testing.expectEqual(config_extract.ConfigFormat.Lua, config_extract.detectFormat(
        \\-- DST server config
        \\local config = {
        \\  name = "My Server",
        \\  max_players = 6,
        \\}
    ));
}

test "Lua parser: deeply nested tables" {
    const allocator = testing.allocator;

    // Simulate a Don't Starve Together cluster config
    const lua_config =
        \\-- DST Cluster configuration
        \\local cluster = {
        \\  gameplay = {
        \\    max_players = 6,
        \\    pvp = false,
        \\    game_mode = "survival",
        \\    pause_when_empty = true,
        \\  },
        \\  network = {
        \\    cluster_name = "My DST Server",
        \\    cluster_password = "",
        \\    lan_only = false,
        \\  },
        \\  misc = {
        \\    console_enabled = true,
        \\  },
        \\}
    ;

    var config = try config_extract.parseLua(allocator, lua_config);
    defer config.deinit();

    // Should have dotted paths: cluster.gameplay.max_players, etc.
    try testing.expect(config.fields.items.len >= 7);

    // Check a deeply nested value
    const max_players = config.getField("cluster.gameplay.max_players");
    try testing.expect(max_players != null);
    try testing.expectEqualStrings("6", max_players.?.value);

    const cluster_name = config.getField("cluster.network.cluster_name");
    try testing.expect(cluster_name != null);
    try testing.expectEqualStrings("My DST Server", cluster_name.?.value);

    const pvp = config.getField("cluster.gameplay.pvp");
    try testing.expect(pvp != null);
    try testing.expectEqualStrings("false", pvp.?.value);
}

test "Lua parser: bracket-quoted keys" {
    const allocator = testing.allocator;

    const lua_config =
        \\ServerData = {
        \\  ["server-name"] = "Test",
        \\  ["max-players"] = 32,
        \\  [1] = "first",
        \\}
    ;

    var config = try config_extract.parseLua(allocator, lua_config);
    defer config.deinit();

    const name = config.getField("ServerData.server-name");
    try testing.expect(name != null);
    try testing.expectEqualStrings("Test", name.?.value);

    const idx = config.getField("ServerData.1");
    try testing.expect(idx != null);
    try testing.expectEqualStrings("first", idx.?.value);
}

test "Lua parser: block comments skipped" {
    const allocator = testing.allocator;

    const lua_config =
        \\--[[ This is a
        \\multi-line block comment
        \\that should be skipped ]]
        \\name = "actual_value"
        \\-- line comment
        \\port = 27015
    ;

    var config = try config_extract.parseLua(allocator, lua_config);
    defer config.deinit();

    try testing.expectEqual(@as(usize, 2), config.fields.items.len);
    try testing.expectEqualStrings("actual_value", config.fields.items[0].value);
}

test "format detection: key-value fallback (Minecraft properties)" {
    try testing.expectEqual(config_extract.ConfigFormat.KeyValue, config_extract.detectFormat(
        \\# Minecraft server properties
        \\server-name=My Server
        \\max-players=20
        \\difficulty=normal
    ));
}

// ═══════════════════════════════════════════════════════════════════════════════
// 3. A2ML emit/parse round-trip
// ═══════════════════════════════════════════════════════════════════════════════

test "A2ML: emit produces valid structure" {
    const allocator = testing.allocator;

    var config = config_extract.ParsedConfig.init(allocator, .KeyValue, "/data/server.properties");
    defer config.deinit();

    try config.addField("server-name", "Integration Test", "string", "Server Name", "Default", null, null, false);
    try config.addField("max-players", "32", "int", "Max Players", "20", 1.0, 100.0, false);
    try config.addField("rcon.password", "", "secret", "RCON Password", "", null, null, true);

    var profile = game_profiles.GameProfile.empty();

    const a2ml = try a2ml_emit.emitA2ML(allocator, "test-server-1", "minecraft-java", &config, &profile);
    defer allocator.free(a2ml);

    // Structural checks
    try testing.expect(std.mem.indexOf(u8, a2ml, "SPDX-License-Identifier") != null);
    try testing.expect(std.mem.indexOf(u8, a2ml, "@server(") != null);
    try testing.expect(std.mem.indexOf(u8, a2ml, "@config(") != null);
    try testing.expect(std.mem.indexOf(u8, a2ml, "@field(") != null);
    try testing.expect(std.mem.indexOf(u8, a2ml, "@end") != null);
}

test "A2ML: parse extracts all fields" {
    const allocator = testing.allocator;

    const a2ml =
        \\@server(id="s1", game="mc"):
        \\  @config(format="key-value", path="/data/server.properties"):
        \\    @field(key="name", type="string", label="Name", default="Default"):
        \\      "My Server"
        \\    @end
        \\    @field(key="port", type="int", label="Port", min="1", max="65535"):
        \\      "25565"
        \\    @end
        \\    @field(key="pass", type="secret", secret="true"):
        \\      "[REDACTED]"
        \\    @end
        \\  @end
        \\@end
    ;

    var parsed = try a2ml_emit.parseA2ML(allocator, a2ml);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 3), parsed.fields.items.len);

    try testing.expectEqualStrings("name", parsed.fields.items[0].key);
    try testing.expectEqualStrings("My Server", parsed.fields.items[0].value);
    try testing.expectEqualStrings("string", parsed.fields.items[0].field_type);

    try testing.expectEqualStrings("port", parsed.fields.items[1].key);
    try testing.expectEqualStrings("25565", parsed.fields.items[1].value);

    try testing.expect(parsed.fields.items[2].is_secret);
}

test "A2ML: round-trip preserves data" {
    const allocator = testing.allocator;

    var original = config_extract.ParsedConfig.init(allocator, .KeyValue, "/data/test.cfg");
    defer original.deinit();

    try original.addField("hostname", "Test Host", "string", "Hostname", "localhost", null, null, false);
    try original.addField("port", "8080", "int", "Port", "80", null, null, false);

    var profile = game_profiles.GameProfile.empty();

    // Emit
    const a2ml = try a2ml_emit.emitA2ML(allocator, "rt-test", "generic", &original, &profile);
    defer allocator.free(a2ml);

    // Parse back
    var restored = try a2ml_emit.parseA2ML(allocator, a2ml);
    defer restored.deinit();

    try testing.expectEqual(original.fields.items.len, restored.fields.items.len);

    for (original.fields.items, 0..) |orig_field, i| {
        try testing.expectEqualStrings(orig_field.key, restored.fields.items[i].key);
        try testing.expectEqualStrings(orig_field.value, restored.fields.items[i].value);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 4. Game profile loading from A2ML
// ═══════════════════════════════════════════════════════════════════════════════

test "game profile: parse Minecraft-style A2ML profile" {
    const allocator = testing.allocator;

    const mc_profile =
        \\@game-profile(id="minecraft-java", name="Minecraft Java Edition", engine="Java"):
        \\  @ports:
        \\    @port(name="query", number=25565, protocol="TCP"):@end
        \\    @port(name="rcon", number=25575, protocol="TCP"):@end
        \\  @end
        \\  @protocol(type="minecraft-query", variant="MC"):@end
        \\  @config(format="key-value", path="/data/server.properties"):
        \\    @field(key="motd", type="string", label="Message of the Day"):
        \\      @default("A Minecraft Server") @end
        \\    @end
        \\    @field(key="max-players", type="int", label="Max Players"):
        \\      @constraint(min=1, max=1000) @end
        \\      @default(20) @end
        \\    @end
        \\    @field(key="difficulty", type="enum", label="Difficulty"):
        \\      @options("peaceful", "easy", "normal", "hard") @end
        \\      @default("easy") @end
        \\    @end
        \\    @field(key="rcon.password", type="secret", label="RCON Password"):
        \\    @end
        \\  @end
        \\  @actions:
        \\    @action(id="start", label="Start Server"):
        \\      podman start minecraft-java
        \\    @end
        \\    @action(id="stop", label="Stop Server"):
        \\      podman stop -t 60 minecraft-java
        \\    @end
        \\  @end
        \\@end
    ;

    var profile = try game_profiles.parseA2MLProfile(mc_profile, allocator);
    defer profile.deinit();

    try testing.expectEqualStrings("minecraft-java", profile.id);
    try testing.expectEqualStrings("Minecraft Java Edition", profile.name);
    try testing.expectEqualStrings("Java", profile.engine);
    try testing.expectEqualStrings("minecraft-query", profile.protocol);
    try testing.expectEqualStrings("key-value", profile.config_format);
    try testing.expectEqualStrings("/data/server.properties", profile.config_path);

    // Ports
    try testing.expectEqual(@as(usize, 2), profile.ports.items.len);
    try testing.expectEqual(@as(u16, 25565), profile.ports.items[0].number);
    try testing.expectEqual(@as(u16, 25575), profile.ports.items[1].number);

    // Field definitions
    try testing.expectEqual(@as(usize, 4), profile.field_defs.items.len);

    // motd field
    try testing.expectEqualStrings("motd", profile.field_defs.items[0].key);
    try testing.expectEqualStrings("A Minecraft Server", profile.field_defs.items[0].default_val);

    // max-players with constraints
    try testing.expectEqualStrings("max-players", profile.field_defs.items[1].key);
    try testing.expectEqual(@as(?f64, 1.0), profile.field_defs.items[1].range_min);
    try testing.expectEqual(@as(?f64, 1000.0), profile.field_defs.items[1].range_max);

    // difficulty with enum options
    try testing.expectEqualStrings("difficulty", profile.field_defs.items[2].key);
    try testing.expectEqual(@as(usize, 4), profile.field_defs.items[2].enum_values.len);
    try testing.expectEqualStrings("peaceful", profile.field_defs.items[2].enum_values[0]);
    try testing.expectEqualStrings("hard", profile.field_defs.items[2].enum_values[3]);

    // rcon.password is secret
    try testing.expect(profile.field_defs.items[3].is_secret);

    // Actions
    try testing.expect(profile.actions.get("start") != null);
    try testing.expect(profile.actions.get("stop") != null);
}

test "game profile: registry starts empty" {
    const allocator = testing.allocator;
    var registry = game_profiles.ProfileRegistry.init(allocator);
    defer registry.deinit();

    const json = try registry.listProfiles(allocator);
    defer allocator.free(json);

    try testing.expectEqualStrings("[]", json);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 5. Port table completeness
// ═══════════════════════════════════════════════════════════════════════════════

test "known ports: table has at least 20 entries" {
    try testing.expect(probe.KNOWN_PORTS.len >= 20);
}

test "known ports: all ports are valid (1-65535)" {
    for (probe.KNOWN_PORTS) |kp| {
        try testing.expect(kp.port >= 1);
        // All entries have at least one game
        try testing.expect(kp.games.len >= 1);
    }
}

test "known ports: no duplicate ports" {
    for (probe.KNOWN_PORTS, 0..) |kp1, i| {
        for (probe.KNOWN_PORTS[i + 1 ..]) |kp2| {
            try testing.expect(kp1.port != kp2.port);
        }
    }
}

test "known ports: major games are represented" {
    const expected_ports = [_]u16{
        27015, // CS2 / TF2 / GMod
        25565, // Minecraft Java
        19132, // Minecraft Bedrock
        2456, // Valheim
        7777, // ARK / Unreal
        34197, // Factorio
        2302, // DayZ / Arma3
        28015, // Rust
    };

    for (expected_ports) |expected| {
        var found = false;
        for (probe.KNOWN_PORTS) |kp| {
            if (kp.port == expected) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 6. VeriSimDB client URL construction
// ═══════════════════════════════════════════════════════════════════════════════

test "VeriSimDB client: stores base URL" {
    const client = verisimdb_client.VeriSimClient.init(testing.allocator, "http://localhost:7820");
    try testing.expectEqualStrings("http://localhost:7820", client.base_url);
}

test "VeriSimDB client: different URLs are distinct" {
    const c1 = verisimdb_client.VeriSimClient.init(testing.allocator, "http://host1:7820");
    const c2 = verisimdb_client.VeriSimClient.init(testing.allocator, "http://host2:7821");
    try testing.expect(!std.mem.eql(u8, c1.base_url, c2.base_url));
}

test "VeriSimDB: serverToOctadJson produces valid structure" {
    const allocator = testing.allocator;

    var config = config_extract.ParsedConfig.init(allocator, .KeyValue, "/data/test.cfg");
    defer config.deinit();
    try config.addField("name", "Test", "string", "", "", null, null, false);
    try config.addField("secret", "hidden", "secret", "", "", null, null, true);

    var pr = probe.ProbeResult{};
    pr.setGameId("test-game");
    pr.setVersion("1.0.0");
    pr.port = 27015;
    pr.protocol = .SteamQuery;
    pr.latency_ms = 10;

    const json = try verisimdb_client.serverToOctadJson(
        allocator,
        "server-1",
        "test-game",
        &config,
        &pr,
        [3]f64{ 1.0, 2.0, 3.0 },
    );
    defer allocator.free(json);

    // Check structure
    try testing.expect(std.mem.indexOf(u8, json, "\"metadata\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"config\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"probe\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"spatial\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"temporal\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"relational\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"provenance\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"semantic\"") != null);

    // Secrets must be redacted
    try testing.expect(std.mem.indexOf(u8, json, "[REDACTED]") != null);
    try testing.expect(std.mem.indexOf(u8, json, "hidden") == null);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 7. Config diff computation
// ═══════════════════════════════════════════════════════════════════════════════

test "config diff: detect modifications" {
    const allocator = testing.allocator;

    var old = config_extract.ParsedConfig.init(allocator, .KeyValue, "");
    defer old.deinit();
    try old.addField("motd", "Old MOTD", "", "", "", null, null, false);
    try old.addField("max-players", "20", "", "", "", null, null, false);

    var new = config_extract.ParsedConfig.init(allocator, .KeyValue, "");
    defer new.deinit();
    try new.addField("motd", "New MOTD", "", "", "", null, null, false);
    try new.addField("max-players", "20", "", "", "", null, null, false);

    const diffs = try a2ml_emit.diffConfigs(allocator, &old, &new);
    defer a2ml_emit.freeDiffs(allocator, diffs);

    try testing.expectEqual(@as(usize, 1), diffs.len);
    try testing.expectEqualStrings("motd", diffs[0].key);
    try testing.expectEqual(a2ml_emit.DiffAction.Modified, diffs[0].action);
    try testing.expectEqualStrings("Old MOTD", diffs[0].old_value);
    try testing.expectEqualStrings("New MOTD", diffs[0].new_value);
}

test "config diff: detect additions" {
    const allocator = testing.allocator;

    var old = config_extract.ParsedConfig.init(allocator, .KeyValue, "");
    defer old.deinit();
    try old.addField("name", "Server", "", "", "", null, null, false);

    var new = config_extract.ParsedConfig.init(allocator, .KeyValue, "");
    defer new.deinit();
    try new.addField("name", "Server", "", "", "", null, null, false);
    try new.addField("port", "25565", "", "", "", null, null, false);

    const diffs = try a2ml_emit.diffConfigs(allocator, &old, &new);
    defer a2ml_emit.freeDiffs(allocator, diffs);

    try testing.expectEqual(@as(usize, 1), diffs.len);
    try testing.expectEqual(a2ml_emit.DiffAction.Added, diffs[0].action);
    try testing.expectEqualStrings("port", diffs[0].key);
}

test "config diff: detect removals" {
    const allocator = testing.allocator;

    var old = config_extract.ParsedConfig.init(allocator, .KeyValue, "");
    defer old.deinit();
    try old.addField("name", "Server", "", "", "", null, null, false);
    try old.addField("deprecated", "yes", "", "", "", null, null, false);

    var new = config_extract.ParsedConfig.init(allocator, .KeyValue, "");
    defer new.deinit();
    try new.addField("name", "Server", "", "", "", null, null, false);

    const diffs = try a2ml_emit.diffConfigs(allocator, &old, &new);
    defer a2ml_emit.freeDiffs(allocator, diffs);

    try testing.expectEqual(@as(usize, 1), diffs.len);
    try testing.expectEqual(a2ml_emit.DiffAction.Removed, diffs[0].action);
    try testing.expectEqualStrings("deprecated", diffs[0].key);
}

test "config diff: no changes yields empty diff" {
    const allocator = testing.allocator;

    var old = config_extract.ParsedConfig.init(allocator, .KeyValue, "");
    defer old.deinit();
    try old.addField("name", "Server", "", "", "", null, null, false);

    var new = config_extract.ParsedConfig.init(allocator, .KeyValue, "");
    defer new.deinit();
    try new.addField("name", "Server", "", "", "", null, null, false);

    const diffs = try a2ml_emit.diffConfigs(allocator, &old, &new);
    defer a2ml_emit.freeDiffs(allocator, diffs);

    try testing.expectEqual(@as(usize, 0), diffs.len);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 8. Additional integration checks
// ═══════════════════════════════════════════════════════════════════════════════

test "version string is semantic version" {
    const ver = std.mem.span(main.gossamer_gsa_version());
    try testing.expectEqualStrings("0.1.0", ver);

    // Check it has two dots (X.Y.Z)
    var dot_count: usize = 0;
    for (ver) |ch| {
        if (ch == '.') dot_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), dot_count);
}

test "error buffer: set and retrieve" {
    main.setErrorStr("test error from integration");
    const err = std.mem.span(main.gossamer_gsa_last_error());
    try testing.expectEqualStrings("test error from integration", err);
}

test "error buffer: clear" {
    main.setErrorStr("something");
    main.clearError();
    const err = std.mem.span(main.gossamer_gsa_last_error());
    try testing.expectEqual(@as(usize, 0), err.len);
}

test "error buffer: formatted error" {
    main.setError("probe failed on port {d}", .{@as(u16, 25565)});
    const err = std.mem.span(main.gossamer_gsa_last_error());
    try testing.expectEqualStrings("probe failed on port 25565", err);
}

test "ProbeProtocol enum has 8 variants" {
    const fields = @typeInfo(probe.ProbeProtocol).@"enum".fields;
    try testing.expectEqual(@as(usize, 8), fields.len);
}

test "ActionKind enum has 8 variants" {
    const fields = @typeInfo(server_actions.ActionKind).@"enum".fields;
    try testing.expectEqual(@as(usize, 8), fields.len);
}

test "ConfigFormat enum has 8 variants" {
    const fields = @typeInfo(config_extract.ConfigFormat).@"enum".fields;
    try testing.expectEqual(@as(usize, 8), fields.len);
}

test "GsaHandle: create, track, query, destroy" {
    const allocator = testing.allocator;
    const handle = try main.GsaHandle.create(allocator, "http://test:7820", "");
    defer handle.destroy();

    try testing.expect(handle.initialized);

    try handle.trackServer("valheim-1", .{
        .host = "10.0.0.1",
        .port = 2456,
        .protocol = .SteamQuery,
        .last_seen_ms = 42,
        .healthy = true,
    });

    const conn = handle.getConnection("valheim-1") orelse return error.NotFound;
    try testing.expectEqual(@as(u16, 2456), conn.port);
    try testing.expectEqual(probe.ProbeProtocol.SteamQuery, conn.protocol);
}

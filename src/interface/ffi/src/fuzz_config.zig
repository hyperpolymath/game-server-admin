// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — Fuzz testing harnesses for config parsers
//
// These fuzz targets exercise the security-critical config parsing
// boundary using Zig's built-in fuzzing support (std.testing.fuzz).
// Each harness feeds arbitrary byte sequences into a parser and
// verifies that:
//   1. The parser does not panic or invoke undefined behaviour.
//   2. Any returned ParsedConfig has consistent internal state.
//   3. Memory is correctly freed (tested via std.testing.allocator
//      which detects leaks).
//
// Run with: zig build test -- --fuzz
//
// Corpus seeds are embedded as string literals so the fuzzer starts
// from realistic inputs rather than random noise.

const std = @import("std");
const testing = std.testing;
const config_extract = @import("config_extract.zig");

// ═══════════════════════════════════════════════════════════════════════════════
// Corpus seeds — realistic config snippets for each format
// ═══════════════════════════════════════════════════════════════════════════════

const xml_seeds = [_][]const u8{
    "<?xml version=\"1.0\"?><Config><Port>25565</Port></Config>",
    "<Settings><Setting name=\"port\" value=\"7777\"/></Settings>",
    "<Server><Name>Test</Name><MaxPlayers>32</MaxPlayers></Server>",
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root>\n  <entry key=\"a\" value=\"b\"/>\n</root>",
    "<a><b><c>deep</c></b></a>",
    "",
};

const ini_seeds = [_][]const u8{
    "[Server]\nname=TestServer\nport=25565\n",
    "[Server]\nname = My Server\nport = 25565\n\n[Gameplay]\ndifficulty = normal\n",
    "; comment line\n[section]\nkey=value # inline comment\n",
    "[empty]\n\n[also_empty]\n",
    "",
};

const json_seeds = [_][]const u8{
    "{\"name\": \"TestServer\", \"port\": 25565}",
    "{\"server\":{\"name\":\"Test\",\"port\":25565,\"enabled\":true}}",
    "{\"a\":{\"b\":{\"c\":\"deep\"}}}",
    "{\"empty\":{},\"null_val\":null,\"bool\":false}",
    "[{\"id\":1},{\"id\":2}]",
    "{}",
    "",
};

const env_seeds = [_][]const u8{
    "export SERVER_NAME=\"TestServer\"\nMAX_PLAYERS=20\n",
    "# comment\nexport KEY=\"value\"\nSECRET_TOKEN=abc123\n",
    "PASSWORD='quoted'\nAPI_KEY=\"double_quoted\"\n",
    "SIMPLE=value\n",
    "",
};

const toml_seeds = [_][]const u8{
    "[server]\nhost = \"localhost\"\nport = 25565\n",
    "[[plugins]]\nname = \"essentials\"\n\n[[plugins]]\nname = \"worldedit\"\n",
    "[database]\ndb.host = \"localhost\"\ndb.port = 5432\n",
    "# TOML comment\n[section]\nkey = \"value\"\nbool_key = true\nint_key = 42\n",
    "",
};

const lua_seeds = [_][]const u8{
    "local config = {\n  name = \"Test\",\n  port = 8080,\n}\n",
    "-- comment\ndata = {\n  server = {\n    host = \"localhost\",\n    port = 25565,\n  },\n}\n",
    "cfg = {\n  [\"string-key\"] = \"value\",\n  [1] = \"first\",\n}\n",
    "--[[ block comment ]]\nlocal t = {\n  enabled = true,\n  ratio = 3.14,\n}\n",
    "simple_key = \"simple_value\"\n",
    "",
};

const kv_seeds = [_][]const u8{
    "server-name=My Server\nmax-players=20\ndifficulty=normal\n",
    "# Minecraft server properties\nserver-name=My Server\nrcon.password=s3cret\n",
    "key:value\nother:data\n",
    "quoted=\"value\"\nsingle='value'\n",
    "",
};

// ═══════════════════════════════════════════════════════════════════════════════
// Fuzz target: detectFormat
//
// The format detector must never panic on arbitrary byte sequences.
// ═══════════════════════════════════════════════════════════════════════════════

test "fuzz: detectFormat accepts arbitrary bytes without panic" {
    try testing.fuzz(.{}, struct {
        fn testOne(input: []const u8) !void {
            const result = config_extract.detectFormat(input);
            // Verify the result is a valid enum member (0..7)
            const raw: u8 = @intFromEnum(result);
            try testing.expect(raw <= 7);
        }
    }.testOne, .{
        .corpus = &xml_seeds ++ &ini_seeds ++ &json_seeds ++ &env_seeds ++ &toml_seeds ++ &lua_seeds ++ &kv_seeds,
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// Fuzz target: parseAuto
//
// The auto-dispatch parser must handle arbitrary bytes without panic
// or memory leak.
// ═══════════════════════════════════════════════════════════════════════════════

test "fuzz: parseAuto handles arbitrary bytes without panic or leak" {
    try testing.fuzz(.{}, struct {
        fn testOne(input: []const u8) !void {
            const allocator = testing.allocator;
            var config = config_extract.parseAuto(allocator, input) catch |err| {
                // OutOfMemory is acceptable under fuzzing; other errors
                // indicate a bug in the parser.
                switch (err) {
                    error.OutOfMemory => return,
                    else => return err,
                }
            };
            defer config.deinit();

            // Invariant: format must be a valid enum member
            const raw: u8 = @intFromEnum(config.format);
            try testing.expect(raw <= 7);

            // Invariant: every field key is non-empty
            for (config.fields.items) |field| {
                try testing.expect(field.key.len > 0);
            }
        }
    }.testOne, .{
        .corpus = &xml_seeds ++ &ini_seeds ++ &json_seeds ++ &env_seeds ++ &toml_seeds ++ &lua_seeds ++ &kv_seeds,
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// Fuzz target: parseXML
// ═══════════════════════════════════════════════════════════════════════════════

test "fuzz: parseXML handles arbitrary bytes without panic or leak" {
    try testing.fuzz(.{}, struct {
        fn testOne(input: []const u8) !void {
            const allocator = testing.allocator;
            var config = config_extract.parseXML(allocator, input) catch |err| {
                switch (err) {
                    error.OutOfMemory => return,
                    else => return err,
                }
            };
            defer config.deinit();
            try testing.expectEqual(config_extract.ConfigFormat.XML, config.format);
        }
    }.testOne, .{
        .corpus = &xml_seeds,
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// Fuzz target: parseINI
// ═══════════════════════════════════════════════════════════════════════════════

test "fuzz: parseINI handles arbitrary bytes without panic or leak" {
    try testing.fuzz(.{}, struct {
        fn testOne(input: []const u8) !void {
            const allocator = testing.allocator;
            var config = config_extract.parseINI(allocator, input) catch |err| {
                switch (err) {
                    error.OutOfMemory => return,
                    else => return err,
                }
            };
            defer config.deinit();
            try testing.expectEqual(config_extract.ConfigFormat.INI, config.format);
        }
    }.testOne, .{
        .corpus = &ini_seeds,
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// Fuzz target: parseJSON
// ═══════════════════════════════════════════════════════════════════════════════

test "fuzz: parseJSON handles arbitrary bytes without panic or leak" {
    try testing.fuzz(.{}, struct {
        fn testOne(input: []const u8) !void {
            const allocator = testing.allocator;
            var config = config_extract.parseJSON(allocator, input) catch |err| {
                switch (err) {
                    error.OutOfMemory => return,
                    else => return err,
                }
            };
            defer config.deinit();
            try testing.expectEqual(config_extract.ConfigFormat.JSON, config.format);
        }
    }.testOne, .{
        .corpus = &json_seeds,
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// Fuzz target: parseENV
// ═══════════════════════════════════════════════════════════════════════════════

test "fuzz: parseENV handles arbitrary bytes without panic or leak" {
    try testing.fuzz(.{}, struct {
        fn testOne(input: []const u8) !void {
            const allocator = testing.allocator;
            var config = config_extract.parseENV(allocator, input) catch |err| {
                switch (err) {
                    error.OutOfMemory => return,
                    else => return err,
                }
            };
            defer config.deinit();
            try testing.expectEqual(config_extract.ConfigFormat.ENV, config.format);
        }
    }.testOne, .{
        .corpus = &env_seeds,
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// Fuzz target: parseTOML
// ═══════════════════════════════════════════════════════════════════════════════

test "fuzz: parseTOML handles arbitrary bytes without panic or leak" {
    try testing.fuzz(.{}, struct {
        fn testOne(input: []const u8) !void {
            const allocator = testing.allocator;
            var config = config_extract.parseTOML(allocator, input) catch |err| {
                switch (err) {
                    error.OutOfMemory => return,
                    else => return err,
                }
            };
            defer config.deinit();
            try testing.expectEqual(config_extract.ConfigFormat.TOML, config.format);
        }
    }.testOne, .{
        .corpus = &toml_seeds,
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// Fuzz target: parseLua
// ═══════════════════════════════════════════════════════════════════════════════

test "fuzz: parseLua handles arbitrary bytes without panic or leak" {
    try testing.fuzz(.{}, struct {
        fn testOne(input: []const u8) !void {
            const allocator = testing.allocator;
            var config = config_extract.parseLua(allocator, input) catch |err| {
                switch (err) {
                    error.OutOfMemory => return,
                    else => return err,
                }
            };
            defer config.deinit();
            try testing.expectEqual(config_extract.ConfigFormat.Lua, config.format);
        }
    }.testOne, .{
        .corpus = &lua_seeds,
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// Fuzz target: parseKeyValue
// ═══════════════════════════════════════════════════════════════════════════════

test "fuzz: parseKeyValue handles arbitrary bytes without panic or leak" {
    try testing.fuzz(.{}, struct {
        fn testOne(input: []const u8) !void {
            const allocator = testing.allocator;
            var config = config_extract.parseKeyValue(allocator, input) catch |err| {
                switch (err) {
                    error.OutOfMemory => return,
                    else => return err,
                }
            };
            defer config.deinit();
            try testing.expectEqual(config_extract.ConfigFormat.KeyValue, config.format);
        }
    }.testOne, .{
        .corpus = &kv_seeds,
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// Fuzz target: detectFormat + parseAuto round-trip consistency
//
// Invariant: parseAuto(data).format == detectFormat(data)
// ═══════════════════════════════════════════════════════════════════════════════

test "fuzz: parseAuto format matches detectFormat" {
    try testing.fuzz(.{}, struct {
        fn testOne(input: []const u8) !void {
            const allocator = testing.allocator;
            const detected = config_extract.detectFormat(input);

            var config = config_extract.parseAuto(allocator, input) catch |err| {
                switch (err) {
                    error.OutOfMemory => return,
                    else => return err,
                }
            };
            defer config.deinit();

            // The format assigned by parseAuto must match detectFormat
            try testing.expectEqual(detected, config.format);
        }
    }.testOne, .{
        .corpus = &xml_seeds ++ &ini_seeds ++ &json_seeds ++ &env_seeds ++ &toml_seeds ++ &lua_seeds ++ &kv_seeds,
    });
}

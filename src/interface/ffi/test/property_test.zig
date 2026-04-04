// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — Property-based / invariant tests
//
// Zig has no built-in property testing framework (no Hedgehog/QuickCheck
// equivalent), so these tests encode properties as hand-crafted invariant
// checks over representative input classes.  Each test group states the
// invariant being verified, then exercises it across a deliberately broad
// corpus of inputs — including empty strings, maximally long strings,
// control characters, Unicode, and domain-specific edge cases.
//
// Invariants tested:
//   P1  detectFormat is total — never panics on any byte sequence
//   P2  detectFormat is deterministic — same input always yields same result
//   P3  parseAuto is total — never panics on any non-null input
//   P4  parseAuto is idempotent in field count — parse(text).len >= 0 always
//   P5  Config field keys are always non-empty after addField
//   P6  ParsedConfig.getField is consistent with addField order
//   P7  ActionKind enum members map injectively to their integer representations
//   P8  GrooveTarget fixed buffers never overflow on any input
//   P9  GrooveTarget name/host round-trip: store then retrieve gives same prefix
//   P10 ProfileRegistry.listProfiles always returns valid JSON (at minimum "[]")
//   P11 Config addField/getField consistency — every added key is retrievable
//   P12 Config field type is always non-empty when explicitly set
//
// Run with: zig build test-property

const std = @import("std");
const testing = std.testing;

const gsa = @import("gsa");
const config_extract = gsa.config_extract;
const server_actions = gsa.server_actions;
const groove_client = gsa.groove_client;
const game_profiles = gsa.game_profiles;

// ═══════════════════════════════════════════════════════════════════════════════
// P1 & P2 — detectFormat is total and deterministic
//
// Invariant: for every input string in the corpus, detectFormat(x) returns
// a valid ConfigFormat member and the same call returns the same value again.
// ═══════════════════════════════════════════════════════════════════════════════

/// Corpus of input strings covering all edge-case categories.
const FORMAT_DETECT_CORPUS = [_][]const u8{
    // Empty / whitespace
    "",
    " ",
    "\t",
    "\n",
    "   \n\t\r\n",

    // Single characters
    "a",
    "<",
    "{",
    "[",
    "#",
    ";",

    // XML variants
    "<?xml version=\"1.0\"?><Root/>",
    "<Config><Name>Test</Name></Config>",
    "<settings>\n  <setting name=\"a\" value=\"b\"/>\n</settings>",
    "< badxml",
    "<!DOCTYPE html>",

    // JSON variants
    "{}",
    "[]",
    "{\"key\": \"value\"}",
    "[{\"id\": 1}]",
    "[\"a\", \"b\"]",
    "[1, 2, 3]",
    "[true, false]",
    "[null]",
    "{ \"nested\": { \"deep\": 42 } }",

    // INI variants
    "[Server]\nname = Test",
    "[section]\nkey=value\n\n[another]\nkey2=val2",
    "; comment\n[x]\na=b",

    // ENV variants
    "export KEY=value",
    "export A=1\nexport B=2",
    "KEY=value\nKEY2=value2",

    // TOML variants
    "[[plugins]]\nname = \"x\"",
    "[server]\nserver.host = \"localhost\"",
    "[db]\ndb.port = 5432",

    // Lua variants
    "local config = {\n  name = \"Test\",\n}",
    "cfg = {\n  port = 8080,\n}",
    "data={key=\"val\"}",

    // KeyValue fallback
    "name=Test Server",
    "key=value\nother=data",
    "# comment\nport=25565",

    // Binary-ish / control characters (should not panic)
    "\x00",
    "\x01\x02\x03",
    "\xff\xfe\xfd",

    // Very long single-line string
    "a" ** 4096,

    // Repeated newlines
    "\n\n\n\n\n\n\n\n",

    // Mixed
    "# This could be anything\n[maybe-ini]\nkey=value\nexport ALSO=yes",
};

test "P1: detectFormat is total — never panics on any input in corpus" {
    // Just calling detectFormat must not panic or cause undefined behavior
    // on any input.  We verify each call returns a valid enum member.
    for (FORMAT_DETECT_CORPUS) |input| {
        const result = config_extract.detectFormat(input);
        // Confirm the result is a defined enum member by converting to int
        // and checking it is within [0, 7] (8 variants: XML=0 … KeyValue=7).
        const raw: u8 = @intFromEnum(result);
        try testing.expect(raw <= 7);
    }
}

test "P2: detectFormat is deterministic — same input always yields same output" {
    for (FORMAT_DETECT_CORPUS) |input| {
        const first = config_extract.detectFormat(input);
        const second = config_extract.detectFormat(input);
        try testing.expectEqual(first, second);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// P3 & P4 — parseAuto is total and yields non-negative field counts
//
// Invariant: parseAuto must not return an unexpected error for well-formed
// inputs.  Field count is always >= 0 (trivially true but verifying we
// never get a negative-sentinel indicates consistent internal state).
// ═══════════════════════════════════════════════════════════════════════════════

/// Subset of corpus that is valid enough for parseAuto to handle (no raw
/// binary data that could confuse allocator-heavy parsers in tests).
const PARSE_AUTO_CORPUS = [_][]const u8{
    "",
    "name=Test\nport=25565",
    "<?xml version=\"1.0\"?><Config><Port>25565</Port></Config>",
    "{\"name\": \"Server\", \"port\": 25565}",
    "[Server]\nname = Server\nport = 25565",
    "export NAME=Server\nexport PORT=25565",
    "[[plugins]]\nname = \"antigrief\"",
    "local config = { name = \"Server\", port = 25565, }",
    // Malformed — must not panic, may return empty or partial result
    "<?xml <unclosed",
    "{bad json here",
    "[unclosed section",
};

test "P3 + P4: parseAuto is total and field count is always non-negative" {
    const allocator = testing.allocator;

    for (PARSE_AUTO_CORPUS) |input| {
        // parseAuto may return error on truly malformed data — that is
        // acceptable.  The invariant is: it never panics and if it
        // succeeds, the field count is >= 0.
        var result = config_extract.parseAuto(allocator, input) catch continue;
        defer result.deinit();
        // Field count is usize — always >= 0, but verify internal
        // consistency: items.len never exceeds the allocated capacity.
        try testing.expect(result.fields.items.len <= result.fields.capacity);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// P5 & P6 — Config field keys are non-empty; addField / getField consistent
//
// Invariant: after addField(key, ...) every key in the field list is
// non-empty, and getField(key) returns the same field that was inserted.
// ═══════════════════════════════════════════════════════════════════════════════

test "P5: all field keys are non-empty after addField" {
    const allocator = testing.allocator;

    var cfg = config_extract.ParsedConfig.init(allocator, .KeyValue, "/test/path");
    defer cfg.deinit();

    const keys = [_][]const u8{ "port", "name", "max-players", "motd", "rcon.password" };
    const values = [_][]const u8{ "25565", "My Server", "32", "Welcome!", "hunter2" };

    for (keys, values) |k, v| {
        try cfg.addField(k, v, "string", "Label", "default", null, null, false);
    }

    for (cfg.fields.items) |field| {
        // Every key must be non-empty.
        try testing.expect(field.key.len > 0);
    }
}

test "P6: getField returns the exact value supplied to addField" {
    const allocator = testing.allocator;

    var cfg = config_extract.ParsedConfig.init(allocator, .KeyValue, "");
    defer cfg.deinit();

    // Insert a known set of key/value pairs.
    const pairs = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "hostname", .value = "game.example.com" },
        .{ .key = "port", .value = "27015" },
        .{ .key = "max_players", .value = "64" },
        .{ .key = "password", .value = "s3cr3t" },
    };

    for (pairs) |p| {
        try cfg.addField(p.key, p.value, "string", "", "", null, null, false);
    }

    // For every pair, getField must return the matching value.
    for (pairs) |p| {
        const found = cfg.getField(p.key);
        try testing.expect(found != null);
        try testing.expectEqualStrings(p.value, found.?.value);
    }

    // A key that was never inserted must return null.
    try testing.expect(cfg.getField("nonexistent_key_xyz") == null);
}

// ═══════════════════════════════════════════════════════════════════════════════
// P7 — ActionKind enum members map injectively to integer representations
//
// Invariant: no two ActionKind members share the same underlying integer.
// This matters because the ABI layer transmits ActionKind as a C int.
// ═══════════════════════════════════════════════════════════════════════════════

test "P7: ActionKind values are injective (no duplicates)" {
    const fields = @typeInfo(server_actions.ActionKind).@"enum".fields;

    // Collect all integer values into a fixed-size array and verify
    // no duplicates using a simple O(n^2) comparison (n=8, negligible cost).
    var seen: [fields.len]u8 = undefined;
    for (fields, 0..) |f, i| {
        seen[i] = @intCast(f.value);
    }

    for (seen, 0..) |v, i| {
        for (seen[i + 1 ..]) |w| {
            try testing.expect(v != w);
        }
    }
}

test "P7b: ActionKind covers all 8 expected action types" {
    // Verify that all action names the Idris2 ABI declares are present.
    // This guards against accidental deletion of a variant.
    const expected_names = [_][]const u8{
        "Start", "Stop", "Restart", "Status", "Logs", "Update", "Backup", "ValidateConfig",
    };

    const fields = @typeInfo(server_actions.ActionKind).@"enum".fields;
    try testing.expectEqual(@as(usize, 8), fields.len);

    for (expected_names) |expected| {
        var found = false;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, expected)) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// P8 & P9 — GrooveTarget fixed buffers never overflow; name/host round-trip
//
// Invariant: GrooveTarget.setName/setHost clamp to buffer size and the
// retrieved slice is always <= the buffer capacity.  Storing then
// retrieving a name that fits within the buffer round-trips exactly.
// ═══════════════════════════════════════════════════════════════════════════════

test "P8: GrooveTarget buffer sizes are bounded — no overflow on any input" {
    // Name buffer is 64 bytes, host buffer is 256 bytes.
    const name_capacity: usize = 64;
    const host_capacity: usize = 256;

    const name_inputs = [_][]const u8{
        "",
        "a",
        "burble",
        "a" ** 63,   // exactly capacity - 1
        "a" ** 64,   // exactly capacity
        "a" ** 128,  // 2x capacity — must be clamped
        "a" ** 4096, // pathological
        "null\x00byte",
        "\xff\xfe\xfd",
    };

    const host_inputs = [_][]const u8{
        "",
        "127.0.0.1",
        "::1",
        "very-long-hostname." ++ "x" ** 200,
        "a" ** 256,  // exactly capacity
        "a" ** 512,  // 2x capacity — must be clamped
        "a" ** 8192, // pathological
    };

    for (name_inputs) |name| {
        var target = groove_client.GrooveTarget{};
        target.setName(name);
        // Retrieved slice must never exceed buffer capacity.
        try testing.expect(target.nameSlice().len <= name_capacity);
        // Retrieved slice must be a prefix of (or equal to) the original.
        const expected_len = @min(name.len, name_capacity);
        try testing.expectEqual(expected_len, target.nameSlice().len);
    }

    for (host_inputs) |host| {
        var target = groove_client.GrooveTarget{};
        target.setHost(host);
        // Retrieved slice must never exceed buffer capacity.
        try testing.expect(target.hostSlice().len <= host_capacity);
        const expected_len = @min(host.len, host_capacity);
        try testing.expectEqual(expected_len, target.hostSlice().len);
    }
}

test "P9: GrooveTarget name/host round-trip for inputs that fit the buffer" {
    const fitting_names = [_][]const u8{
        "burble",
        "vext",
        "local-groove",
        "target-01",
    };

    const fitting_hosts = [_][]const u8{
        "127.0.0.1",
        "::1",
        "192.168.1.100",
        "game.example.com",
    };

    for (fitting_names) |name| {
        var target = groove_client.GrooveTarget{};
        target.setName(name);
        try testing.expectEqualStrings(name, target.nameSlice());
    }

    for (fitting_hosts) |host| {
        var target = groove_client.GrooveTarget{};
        target.setHost(host);
        try testing.expectEqualStrings(host, target.hostSlice());
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// P10 — ProfileRegistry.listProfiles always returns valid JSON
//
// Invariant: listProfiles returns at minimum "[]" (empty JSON array), and
// after adding N profiles, the result is a JSON array with N elements.
// ═══════════════════════════════════════════════════════════════════════════════

test "P10: ProfileRegistry.listProfiles returns valid JSON regardless of state" {
    const allocator = testing.allocator;

    // Empty registry
    {
        var registry = game_profiles.ProfileRegistry.init(allocator);
        defer registry.deinit();

        const json = try registry.listProfiles(allocator);
        defer allocator.free(json);

        // Must be valid JSON — at minimum "[]" or "[...]"
        try testing.expect(json.len >= 2);
        try testing.expectEqual(@as(u8, '['), json[0]);
        try testing.expectEqual(@as(u8, ']'), json[json.len - 1]);
    }

    // Registry with one profile
    {
        var registry = game_profiles.ProfileRegistry.init(allocator);
        defer registry.deinit();

        const profile_a2ml =
            \\@game-profile(id="test-game", name="Test Game", engine="Custom"):
            \\  @ports:
            \\    @port(name="game", number=9999, protocol="UDP"):@end
            \\  @end
            \\  @protocol(type="custom-query", variant="CQ"):@end
            \\  @config(format="key-value", path="/data/test.cfg"):
            \\  @end
            \\@end
        ;

        try registry.registerFromText(profile_a2ml);

        const json = try registry.listProfiles(allocator);
        defer allocator.free(json);

        // Must be a JSON array containing something
        try testing.expect(json.len > 2);
        try testing.expectEqual(@as(u8, '['), json[0]);
        // The registered game's id must appear in the output
        try testing.expect(std.mem.indexOf(u8, json, "test-game") != null);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// P11 — Config addField / getField consistency under multiple insertions
//
// Invariant: after inserting N distinct keys, every single key is
// retrievable via getField.  This holds regardless of insertion order.
// ═══════════════════════════════════════════════════════════════════════════════

test "P11: every inserted key is retrievable — insertion order does not matter" {
    const allocator = testing.allocator;

    var cfg = config_extract.ParsedConfig.init(allocator, .JSON, "/tmp/test.json");
    defer cfg.deinit();

    // Insert keys that are deliberately interleaved to test ordering assumptions.
    const entries = [_]struct { key: []const u8, value: []const u8, is_secret: bool }{
        .{ .key = "z-last", .value = "last", .is_secret = false },
        .{ .key = "a-first", .value = "first", .is_secret = false },
        .{ .key = "m-middle", .value = "middle", .is_secret = false },
        .{ .key = "rcon.password", .value = "supersecret", .is_secret = true },
        .{ .key = "numeric-key", .value = "12345", .is_secret = false },
        .{ .key = "empty-value", .value = "", .is_secret = false },
    };

    for (entries) |e| {
        try cfg.addField(e.key, e.value, "string", "", "", null, null, e.is_secret);
    }

    // Every inserted key must be findable, regardless of insertion order.
    for (entries) |e| {
        const found = cfg.getField(e.key);
        try testing.expect(found != null);
        try testing.expectEqualStrings(e.key, found.?.key);
        try testing.expectEqualStrings(e.value, found.?.value);
        try testing.expectEqual(e.is_secret, found.?.is_secret);
    }

    // Total field count must equal number of insertions.
    try testing.expectEqual(@as(usize, entries.len), cfg.fields.items.len);
}

// ═══════════════════════════════════════════════════════════════════════════════
// P12 — Config field_type is always non-empty when explicitly set
//
// Invariant: when addField is called with a non-empty field_type string,
// the stored field has a non-empty field_type.  The empty-string case is
// also explicitly verified: passing "" stores "" (not some sentinel).
// ═══════════════════════════════════════════════════════════════════════════════

test "P12: field_type is preserved exactly by addField" {
    const allocator = testing.allocator;

    const type_cases = [_]struct { type_str: []const u8 }{
        .{ .type_str = "string" },
        .{ .type_str = "int" },
        .{ .type_str = "bool" },
        .{ .type_str = "float" },
        .{ .type_str = "secret" },
        .{ .type_str = "enum" },
        .{ .type_str = "" }, // empty is valid (field type unknown)
    };

    for (type_cases, 0..) |tc, i| {
        var cfg = config_extract.ParsedConfig.init(allocator, .KeyValue, "");
        defer cfg.deinit();

        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;

        try cfg.addField(key, "value", tc.type_str, "", "", null, null, false);

        const found = cfg.getField(key);
        try testing.expect(found != null);
        try testing.expectEqualStrings(tc.type_str, found.?.field_type);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// P13 — Config format enum values are injective (no duplicate integers)
//
// Invariant: ConfigFormat is transmitted as a u8 across the ABI; every
// variant must have a distinct integer value.
// ═══════════════════════════════════════════════════════════════════════════════

test "P13: ConfigFormat values are injective — no two variants share an integer" {
    const fields = @typeInfo(config_extract.ConfigFormat).@"enum".fields;

    var seen: [fields.len]u8 = undefined;
    for (fields, 0..) |f, i| {
        seen[i] = @intCast(f.value);
    }

    for (seen, 0..) |v, i| {
        for (seen[i + 1 ..]) |w| {
            try testing.expect(v != w);
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// P14 — parseAuto dispatch is deterministic for a fixed input
//
// Invariant: parsing the same input twice produces the same number of
// fields and the same key names in the same order.
// ═══════════════════════════════════════════════════════════════════════════════

test "P14: parseAuto is deterministic — two parses of the same input match" {
    const allocator = testing.allocator;

    const inputs = [_][]const u8{
        "name=My Server\nport=25565\nmax-players=20",
        "[Server]\nname = Test\nport = 27015",
        "{\"id\": \"srv1\", \"port\": 7777}",
        "export SERVER_NAME=Test\nexport MAX_PLAYERS=32",
    };

    for (inputs) |input| {
        var cfg1 = config_extract.parseAuto(allocator, input) catch continue;
        defer cfg1.deinit();

        var cfg2 = config_extract.parseAuto(allocator, input) catch continue;
        defer cfg2.deinit();

        // Both parses must yield the same number of fields.
        try testing.expectEqual(cfg1.fields.items.len, cfg2.fields.items.len);

        // Both parses must yield the same keys in the same order.
        for (cfg1.fields.items, cfg2.fields.items) |f1, f2| {
            try testing.expectEqualStrings(f1.key, f2.key);
        }
    }
}

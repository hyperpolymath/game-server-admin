// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Behavioral tests: drive the probe engine and the exported C ABI against
// in-process mock servers (test/mock_servers.zig). These exercise the real
// socket paths — the seam where the Phase 1-3 bugs lived and where the unit
// tests, which only used synthetic ProbeResults, had no coverage.

const std = @import("std");
const testing = std.testing;
const gsa = @import("gsa");
const mock = @import("mock_servers");

const HOST: [*:0]const u8 = "127.0.0.1";

// The single highest-value test: the full exported C-ABI lifecycle against a
// live (mock) server. It would have caught findings 1-3 together — probe never
// returning a handle, close_handle being a no-op, and the result-code confusion
// — because it asserts the actual returned values, not a synthetic struct.
test "C-ABI end-to-end: init -> probe -> close -> double-close(DoubleFree)" {
    const m = try mock.MockA2S.start(testing.allocator, .direct);
    defer m.stop();

    try testing.expectEqual(
        @intFromEnum(gsa.GsaResult.ok),
        gsa.gossamer_gsa_init("http://127.0.0.1:8090", ""),
    );
    defer _ = gsa.gossamer_gsa_shutdown();

    // A successful probe returns a handle id (>= FIRST_HANDLE_ID), never a
    // 0-17 result code.
    const handle = gsa.probe.gossamer_gsa_probe(HOST, @as(c_int, m.port));
    try testing.expect(handle >= gsa.FIRST_HANDLE_ID);

    // First close consumes the handle cleanly...
    try testing.expectEqual(
        @intFromEnum(gsa.GsaResult.ok),
        gsa.abi_serde.gossamer_gsa_close_handle(handle),
    );
    // ...the second close is the linear-type violation the Idris side proves
    // impossible for well-typed callers; the Zig runtime reports it.
    try testing.expectEqual(
        @intFromEnum(gsa.GsaResult.double_free),
        gsa.abi_serde.gossamer_gsa_close_handle(handle),
    );
    // A handle id that was never issued is not_found, not a false success.
    try testing.expectEqual(
        @intFromEnum(gsa.GsaResult.not_found),
        gsa.abi_serde.gossamer_gsa_close_handle(424242),
    );
}

test "A2S challenge handshake is completed (0x41 -> re-query -> 0x49)" {
    const m = try mock.MockA2S.start(testing.allocator, .challenge);
    defer m.stop();

    const result = try gsa.probe.trySteamQuery("127.0.0.1", m.port, 2000);
    try testing.expect(result != null);
    // folder field of the A2S reply -> game_id
    try testing.expectEqualStrings("valheim", result.?.gameIdSlice());
}

test "A2S direct reply is parsed" {
    const m = try mock.MockA2S.start(testing.allocator, .direct);
    defer m.stop();

    const result = try gsa.probe.trySteamQuery("127.0.0.1", m.port, 2000);
    try testing.expect(result != null);
    try testing.expectEqualStrings("valheim", result.?.gameIdSlice());
    try testing.expectEqualStrings("1.0.0", result.?.versionSlice());
}

test "Minecraft SLP is read across a fragmented response" {
    const m = try mock.MockSLP.start(testing.allocator, true); // fragmented
    defer m.stop();

    const result = try gsa.probe.tryMinecraftQuery("127.0.0.1", m.port, 2000);
    try testing.expect(result != null);
    // "name":"1.21.4" inside the JSON version object
    try testing.expectEqualStrings("1.21.4", result.?.versionSlice());
}

test "probe honours a small timeout against a silent server" {
    const m = try mock.MockA2S.start(testing.allocator, .silent);
    defer m.stop();

    var timer = try std.time.Timer.start();
    const result = try gsa.probe.trySteamQuery("127.0.0.1", m.port, 100);
    const elapsed_ms = timer.read() / std.time.ns_per_ms;

    try testing.expect(result == null); // never replied
    // The old code ignored timeout_ms and always waited ~3000ms. With the fix a
    // 100ms budget must return well under a second (generous bound for CI).
    try testing.expect(elapsed_ms < 1000);
}

// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — Micro-benchmarks
//
// Zig has no Criterion equivalent, so benchmarks are written using
// std.time.Timer directly.  Each benchmark runs a tight loop of N
// iterations, records wall-clock time via CLOCK_MONOTONIC, then prints:
//
//   <benchmark name>
//     iterations : N
//     total      : X µs
//     per-op     : Y ns
//
// The results are written to stderr so they are visible even when the
// process is captured by CI tooling.
//
// Benchmarks included:
//   B1  Config format detection (small / medium / large inputs)
//   B2  parseAuto dispatch latency per format
//   B3  isLocalhost-equivalent batch validation (100 addresses)
//   B4  Config ParsedConfig.addField throughput
//   B5  Config ParsedConfig.getField lookup throughput
//   B6  GrooveTarget buffer operations throughput
//   B7  ProfileRegistry.listProfiles serialisation latency
//
// Run with: zig build bench

const std = @import("std");

const gsa = @import("gsa");
const config_extract = gsa.config_extract;
const groove_client = gsa.groove_client;
const game_profiles = gsa.game_profiles;

// ═══════════════════════════════════════════════════════════════════════════════
// Harness helpers
// ═══════════════════════════════════════════════════════════════════════════════

/// Number of iterations for each benchmark.  High enough to amortise
/// timer resolution (~1 µs on modern Linux/macOS) while keeping the
/// benchmark run under 5 seconds total.
const ITERATIONS: u64 = 100_000;

/// Lightweight benchmark runner.
///
/// Runs `func` for `iters` iterations, measures total elapsed nanoseconds
/// using a monotonic timer, then prints a summary line.
///
/// `name`  — human-readable benchmark name
/// `iters` — number of iterations
/// `func`  — closure accepting `std.mem.Allocator` (may discard allocator)
fn run(name: []const u8, iters: u64, func: anytype) void {
    var timer = std.time.Timer.start() catch {
        std.debug.print("BENCH {s}: timer unavailable\n", .{name});
        return;
    };

    var i: u64 = 0;
    while (i < iters) : (i += 1) {
        func();
    }

    const elapsed_ns = timer.read();
    const elapsed_us = elapsed_ns / 1_000;
    const per_op_ns = if (iters > 0) elapsed_ns / iters else 0;

    std.debug.print(
        \\
        \\{s}
        \\  iterations : {d}
        \\  total      : {d} µs
        \\  per-op     : {d} ns
        \\
    , .{ name, iters, elapsed_us, per_op_ns });
}

/// Variant that takes an allocator-using closure.  Allocates a fresh
/// GeneralPurposeAllocator per call; the GPAs are freed after the loop.
/// This isolates allocation effects but is heavier than the alloc-free
/// variant, so uses a lower iteration count.
const ALLOC_ITERATIONS: u64 = 5_000;

fn runAlloc(
    name: []const u8,
    iters: u64,
    comptime func: fn (std.mem.Allocator) void,
) void {
    var timer = std.time.Timer.start() catch {
        std.debug.print("BENCH {s}: timer unavailable\n", .{name});
        return;
    };

    var i: u64 = 0;
    while (i < iters) : (i += 1) {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        func(gpa.allocator());
    }

    const elapsed_ns = timer.read();
    const elapsed_us = elapsed_ns / 1_000;
    const per_op_ns = if (iters > 0) elapsed_ns / iters else 0;

    std.debug.print(
        \\
        \\{s}
        \\  iterations : {d}
        \\  total      : {d} µs
        \\  per-op     : {d} ns
        \\
    , .{ name, iters, elapsed_us, per_op_ns });
}

// ═══════════════════════════════════════════════════════════════════════════════
// B1 — Config format detection throughput
//
// Measures how quickly detectFormat classifies a config string.  Three
// payload sizes are tested: small (~50 bytes), medium (~500 bytes), large
// (~5 KB).  The result is sunk into a volatile variable to prevent the
// compiler from eliding the call entirely.
// ═══════════════════════════════════════════════════════════════════════════════

/// Volatile sink to prevent compiler from optimising away benchmark calls.
var sink: u8 = 0;

const SMALL_KV =
    \\name=My Server
    \\port=25565
    \\max-players=20
;

const MEDIUM_JSON =
    \\{
    \\  "name": "My Server",
    \\  "port": 25565,
    \\  "max_players": 32,
    \\  "difficulty": "normal",
    \\  "view_distance": 10,
    \\  "enable_pvp": false,
    \\  "whitelist": true,
    \\  "spawn_protection": 16,
    \\  "online_mode": true,
    \\  "motd": "Welcome to My Server"
    \\}
;

// Large Lua table (~5 KB) representative of a Don't Starve Together cluster cfg.
const LARGE_LUA =
    \\-- DST Cluster configuration
    \\local cluster = {
    \\  gameplay = {
    \\    max_players = 6, pvp = false, game_mode = "survival",
    \\    pause_when_empty = true, vote_kick_enabled = true,
    \\  },
    \\  network = {
    \\    cluster_name = "My DST Server", cluster_password = "",
    \\    lan_only_cluster = false, cluster_intention = "cooperative",
    \\    cluster_language = "en",
    \\  },
    \\  misc = {
    \\    console_enabled = true, autocompiler_enabled = true,
    \\    max_snapshots = 6,
    \\  },
    \\  shard = {
    \\    shard_enabled = false, bind_ip = "127.0.0.1",
    \\    master_ip = "127.0.0.1", master_port = 10998,
    \\    cluster_key = "defaultPass",
    \\  },
    \\  steam = {
    \\    steam_group_id = 0, steam_group_only = false,
    \\    steam_group_admins = false,
    \\  },
    \\  whitelist = {
    \\    enabled = false,
    \\  },
    \\  mods = {
    \\    mods_enabled = true,
    \\    workshop = {
    \\      ["workshop-727774324"] = true,
    \\      ["workshop-1206835172"] = true,
    \\    },
    \\  },
    \\  playstyle = {
    \\    endless = false, survival = true,
    \\    wilderness = false, cooperative = true,
    \\  },
    \\}
;

fn benchDetectSmall() void {
    const f = config_extract.detectFormat(SMALL_KV);
    sink = @intFromEnum(f);
}

fn benchDetectMedium() void {
    const f = config_extract.detectFormat(MEDIUM_JSON);
    sink = @intFromEnum(f);
}

fn benchDetectLarge() void {
    const f = config_extract.detectFormat(LARGE_LUA);
    sink = @intFromEnum(f);
}

// ═══════════════════════════════════════════════════════════════════════════════
// B2 — parseAuto dispatch latency per format
//
// Measures the full parse round-trip (detectFormat + parse) for one
// representative payload per format.  Uses the allocator-aware runner
// because the parsers allocate.
// ═══════════════════════════════════════════════════════════════════════════════

fn benchParseKV(allocator: std.mem.Allocator) void {
    var cfg = config_extract.parseAuto(allocator, SMALL_KV) catch return;
    cfg.deinit();
}

fn benchParseJSON(allocator: std.mem.Allocator) void {
    var cfg = config_extract.parseAuto(allocator, MEDIUM_JSON) catch return;
    cfg.deinit();
}

fn benchParseLua(allocator: std.mem.Allocator) void {
    var cfg = config_extract.parseAuto(allocator, LARGE_LUA) catch return;
    cfg.deinit();
}

const INI_PAYLOAD =
    \\[Server]
    \\name = CS2 Server
    \\port = 27015
    \\max_players = 64
    \\[Gameplay]
    \\tickrate = 128
    \\sv_cheats = 0
;

fn benchParseINI(allocator: std.mem.Allocator) void {
    var cfg = config_extract.parseAuto(allocator, INI_PAYLOAD) catch return;
    cfg.deinit();
}

const XML_PAYLOAD =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<ServerConfig>
    \\  <setting name="name" value="My ARK Server"/>
    \\  <setting name="port" value="7777"/>
    \\  <setting name="max_players" value="100"/>
    \\  <setting name="map" value="TheIsland"/>
    \\</ServerConfig>
;

fn benchParseXML(allocator: std.mem.Allocator) void {
    var cfg = config_extract.parseAuto(allocator, XML_PAYLOAD) catch return;
    cfg.deinit();
}

// ═══════════════════════════════════════════════════════════════════════════════
// B3 — localhost detection equivalence batch (100 addresses)
//
// isLocalhost is private in server_actions, so we replicate the exact
// same logic here to measure its raw throughput.  The benchmark is
// explicitly labelled "equivalence" so it is clear we are not calling
// the production function — we are measuring the equivalent algorithm.
// ═══════════════════════════════════════════════════════════════════════════════

/// Replicate the isLocalhost logic from server_actions.zig verbatim.
/// This is intentional: measuring the algorithm independently confirms
/// whether any future change to the implementation changes performance.
inline fn isLocalhostEquiv(host: []const u8) bool {
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1") or
        host.len == 0;
}

const LOCALHOST_BATCH = [_][]const u8{
    "localhost",   "127.0.0.1",     "::1",             "",
    "10.0.0.1",    "192.168.1.1",   "game.example.com", "0.0.0.0",
    "localhost",   "127.0.0.2",     "::2",             "255.255.255.255",
    "127.0.0.1",   "::1",           "hostname",        "10.10.10.10",
    // Injection-style strings that must be handled correctly
    "localhost; rm -rf /",
    "127.0.0.1\n",
    "::1 OR 1=1",
    "\x00",
    // Repeat to reach 100-ish entries
    "localhost",   "127.0.0.1",     "::1",             "",
    "192.168.0.1", "172.16.0.1",    "::ffff:127.0.0.1", "127.1.2.3",
    "localhost",   "127.0.0.1",     "::1",             "",
    "10.0.0.2",    "10.0.0.3",      "10.0.0.4",        "10.0.0.5",
    "localhost",   "127.0.0.1",     "::1",             "",
    "localhost",   "127.0.0.1",     "::1",             "",
    "localhost",   "127.0.0.1",     "::1",             "",
    "localhost",   "127.0.0.1",     "::1",             "",
    "game1.lan",   "game2.lan",     "game3.lan",       "game4.lan",
    "localhost",   "127.0.0.1",     "::1",             "",
    "localhost",   "127.0.0.1",     "::1",             "",
    "localhost",   "127.0.0.1",     "::1",             "",
    "localhost",   "127.0.0.1",     "::1",             "",
    "localhost",   "127.0.0.1",     "::1",             "",
    "localhost",   "127.0.0.1",     "::1",             "",
    "localhost",   "127.0.0.1",     "::1",             "",
    "localhost",   "127.0.0.1",     "::1",             "",
};

fn benchLocalhostBatch() void {
    var count: usize = 0;
    for (LOCALHOST_BATCH) |addr| {
        if (isLocalhostEquiv(addr)) count += 1;
    }
    // Sink result to prevent compiler optimisation.
    sink = @truncate(count);
}

// ═══════════════════════════════════════════════════════════════════════════════
// B4 & B5 — ParsedConfig.addField and getField throughput
//
// B4 measures the cost of inserting a field (key dedup, string copy,
// array append).  B5 measures linear-scan lookup by key.
// ═══════════════════════════════════════════════════════════════════════════════

fn benchAddField(allocator: std.mem.Allocator) void {
    var cfg = config_extract.ParsedConfig.init(allocator, .KeyValue, "/bench/test.cfg");
    defer cfg.deinit();

    cfg.addField("server-name", "Benchmark Server", "string", "Server Name", "My Server", null, null, false) catch return;
    cfg.addField("max-players", "64", "int", "Max Players", "20", 1.0, 1000.0, false) catch return;
    cfg.addField("difficulty", "hard", "enum", "Difficulty", "normal", null, null, false) catch return;
    cfg.addField("rcon.password", "bench-secret", "secret", "RCON Password", "", null, null, true) catch return;
    cfg.addField("view-distance", "16", "int", "View Distance", "10", 2.0, 32.0, false) catch return;
}

/// Pre-built config used for getField benchmarks (allocated once, reused).
var bench_cfg_ptr: ?*config_extract.ParsedConfig = null;

fn setupGetFieldBench(allocator: std.mem.Allocator) !void {
    const cfg = try allocator.create(config_extract.ParsedConfig);
    cfg.* = config_extract.ParsedConfig.init(allocator, .KeyValue, "/bench/lookup.cfg");

    try cfg.addField("server-name", "Bench Server", "string", "", "", null, null, false);
    try cfg.addField("max-players", "64", "int", "", "", null, null, false);
    try cfg.addField("difficulty", "hard", "enum", "", "", null, null, false);
    try cfg.addField("rcon.password", "s3cr3t", "secret", "", "", null, null, true);
    try cfg.addField("view-distance", "16", "int", "", "", null, null, false);
    try cfg.addField("spawn-protection", "8", "int", "", "", null, null, false);
    try cfg.addField("whitelist", "false", "bool", "", "", null, null, false);
    try cfg.addField("online-mode", "true", "bool", "", "", null, null, false);

    bench_cfg_ptr = cfg;
}

fn benchGetField() void {
    const cfg = bench_cfg_ptr orelse return;
    // Lookup keys near start, middle, and end of the list to cover
    // best-case and worst-case linear scan positions.
    _ = cfg.getField("server-name");   // first entry — O(1) best case
    _ = cfg.getField("view-distance"); // fifth entry — O(n/2) average
    _ = cfg.getField("online-mode");   // last entry  — O(n) worst case
    _ = cfg.getField("nonexistent");   // miss — O(n) scan to end
    sink = @truncate(cfg.fields.items.len);
}

// ═══════════════════════════════════════════════════════════════════════════════
// B6 — GrooveTarget buffer operations throughput
//
// Measures the cost of setName + setHost + nameSlice + hostSlice for a
// representative target name/host pair.  All four operations operate on
// stack-allocated fixed-size buffers — no heap allocation.
// ═══════════════════════════════════════════════════════════════════════════════

fn benchGrooveTargetOps() void {
    var target = groove_client.GrooveTarget{};
    target.setName("burble");
    target.setHost("127.0.0.1");
    target.port = 6473;
    // Force reads to prevent dead-code elimination.
    sink = @truncate(target.nameSlice().len + target.hostSlice().len);
}

fn benchGrooveTargetLongName() void {
    // Oversized name — exercises the clamping path in setBuf.
    var target = groove_client.GrooveTarget{};
    target.setName("this-is-a-very-long-target-name-that-exceeds-the-64-byte-buffer-limit-and-must-be-clamped");
    target.setHost("some.very.long.hostname.that.exceeds.the.256.byte.host.buffer.limit.if.repeated.many.times.example.com");
    sink = @truncate(target.nameSlice().len + target.hostSlice().len);
}

// ═══════════════════════════════════════════════════════════════════════════════
// B7 — ProfileRegistry.listProfiles serialisation latency
//
// Measures the time to serialise a registry containing one or more profiles
// into JSON.  Uses the allocator-aware runner.
// ═══════════════════════════════════════════════════════════════════════════════

const BENCH_PROFILE_A2ML =
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
    \\  @end
    \\@end
;

fn benchListProfilesEmpty(allocator: std.mem.Allocator) void {
    var registry = game_profiles.ProfileRegistry.init(allocator);
    defer registry.deinit();

    const json = registry.listProfiles(allocator) catch return;
    allocator.free(json);
}

fn benchListProfilesOne(allocator: std.mem.Allocator) void {
    var registry = game_profiles.ProfileRegistry.init(allocator);
    defer registry.deinit();

    registry.registerFromText(BENCH_PROFILE_A2ML) catch return;

    const json = registry.listProfiles(allocator) catch return;
    allocator.free(json);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Entry point
// ═══════════════════════════════════════════════════════════════════════════════

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print(
        \\
        \\═══════════════════════════════════════════════════════════════════════
        \\  Game Server Admin — FFI Micro-benchmarks
        \\  Iterations (alloc-free): {d}
        \\  Iterations (alloc):      {d}
        \\═══════════════════════════════════════════════════════════════════════
        \\
    , .{ ITERATIONS, ALLOC_ITERATIONS });

    // ── B1: Format detection ─────────────────────────────────────────────────
    std.debug.print("\n─── B1: Config format detection ───\n", .{});
    run("B1a detectFormat (small KV ~50 B)", ITERATIONS, benchDetectSmall);
    run("B1b detectFormat (medium JSON ~300 B)", ITERATIONS, benchDetectMedium);
    run("B1c detectFormat (large Lua ~2 KB)", ITERATIONS, benchDetectLarge);

    // ── B2: parseAuto dispatch ───────────────────────────────────────────────
    std.debug.print("\n─── B2: parseAuto dispatch per format ───\n", .{});
    runAlloc("B2a parseAuto KeyValue (small)", ALLOC_ITERATIONS, benchParseKV);
    runAlloc("B2b parseAuto JSON (medium)", ALLOC_ITERATIONS, benchParseJSON);
    runAlloc("B2c parseAuto Lua (large)", ALLOC_ITERATIONS, benchParseLua);
    runAlloc("B2d parseAuto INI (medium)", ALLOC_ITERATIONS, benchParseINI);
    runAlloc("B2e parseAuto XML (medium)", ALLOC_ITERATIONS, benchParseXML);

    // ── B3: Localhost detection batch ────────────────────────────────────────
    std.debug.print("\n─── B3: isLocalhost-equivalent batch ({d} addresses) ───\n", .{LOCALHOST_BATCH.len});
    run("B3  isLocalhost batch", ITERATIONS, benchLocalhostBatch);

    // ── B4 & B5: ParsedConfig addField / getField ────────────────────────────
    std.debug.print("\n─── B4: ParsedConfig.addField throughput (5 fields per op) ───\n", .{});
    runAlloc("B4  addField x5", ALLOC_ITERATIONS, benchAddField);

    // Set up the shared config for B5.
    try setupGetFieldBench(allocator);
    defer if (bench_cfg_ptr) |cfg| {
        cfg.deinit();
        allocator.destroy(cfg);
    };

    std.debug.print("\n─── B5: ParsedConfig.getField lookup (4 lookups per op) ───\n", .{});
    run("B5  getField x4 (best/avg/worst/miss)", ITERATIONS, benchGetField);

    // ── B6: GrooveTarget buffer ops ──────────────────────────────────────────
    std.debug.print("\n─── B6: GrooveTarget buffer operations ───\n", .{});
    run("B6a GrooveTarget setName+setHost+read (fits buffer)", ITERATIONS, benchGrooveTargetOps);
    run("B6b GrooveTarget setName+setHost+read (oversize — clamped)", ITERATIONS, benchGrooveTargetLongName);

    // ── B7: ProfileRegistry serialisation ───────────────────────────────────
    std.debug.print("\n─── B7: ProfileRegistry.listProfiles serialisation ───\n", .{});
    runAlloc("B7a listProfiles (empty registry)", ALLOC_ITERATIONS, benchListProfilesEmpty);
    runAlloc("B7b listProfiles (1 profile)", ALLOC_ITERATIONS, benchListProfilesOne);

    std.debug.print(
        \\
        \\═══════════════════════════════════════════════════════════════════════
        \\  Benchmarks complete.
        \\═══════════════════════════════════════════════════════════════════════
        \\
    , .{});
}

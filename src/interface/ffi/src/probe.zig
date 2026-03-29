// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — Protocol fingerprinting engine
//
// The core innovation of GSA: given a host and port, probe using multiple
// game server protocols to identify the running game, its version, and
// configuration paths.  This module implements:
//   - Steam A2S_INFO query (Source / GoldSrc engines)
//   - Minecraft SLP (Server List Ping)
//   - RCON handshake detection
//   - HTTP/REST header probing
//   - Raw TCP banner grabbing
//   - A comptime table of ~20 well-known game server ports

const std = @import("std");
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const main = @import("main.zig");
const game_profiles = @import("game_profiles.zig");

// ═══════════════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════════════

/// Protocol families recognised by the probing engine.
pub const ProbeProtocol = enum(u8) {
    SteamQuery = 0,
    RCON = 1,
    MinecraftQuery = 2,
    GameSpy = 3,
    REST = 4,
    SSH = 5,
    WebSocket = 6,
    CustomTCP = 7,
};

/// Entry in the comptime known-ports table.
pub const KnownPort = struct {
    port: u16,
    protocol: ProbeProtocol,
    games: []const []const u8,
};

/// Result of a successful probe against a single endpoint.
pub const ProbeResult = struct {
    game_id: [64]u8 = [_]u8{0} ** 64,
    game_id_len: usize = 0,
    version: [32]u8 = [_]u8{0} ** 32,
    version_len: usize = 0,
    protocol: ProbeProtocol = .CustomTCP,
    fingerprint_sig: [128]u8 = [_]u8{0} ** 128,
    fingerprint_sig_len: usize = 0,
    config_paths: [256]u8 = [_]u8{0} ** 256,
    config_paths_len: usize = 0,
    host: [256]u8 = [_]u8{0} ** 256,
    host_len: usize = 0,
    port: u16 = 0,
    latency_ms: u32 = 0,

    /// Copy a slice into one of the fixed-size buffers.
    fn setBuf(dest: []u8, src: []const u8) usize {
        const copy_len = @min(src.len, dest.len);
        @memcpy(dest[0..copy_len], src[0..copy_len]);
        return copy_len;
    }

    pub fn setGameId(self: *ProbeResult, id: []const u8) void {
        self.game_id_len = setBuf(&self.game_id, id);
    }

    pub fn setVersion(self: *ProbeResult, v: []const u8) void {
        self.version_len = setBuf(&self.version, v);
    }

    pub fn setHost(self: *ProbeResult, h: []const u8) void {
        self.host_len = setBuf(&self.host, h);
    }

    pub fn setFingerprintSig(self: *ProbeResult, sig: []const u8) void {
        self.fingerprint_sig_len = setBuf(&self.fingerprint_sig, sig);
    }

    pub fn setConfigPaths(self: *ProbeResult, paths: []const u8) void {
        self.config_paths_len = setBuf(&self.config_paths, paths);
    }

    pub fn gameIdSlice(self: *const ProbeResult) []const u8 {
        return self.game_id[0..self.game_id_len];
    }

    pub fn versionSlice(self: *const ProbeResult) []const u8 {
        return self.version[0..self.version_len];
    }

    pub fn hostSlice(self: *const ProbeResult) []const u8 {
        return self.host[0..self.host_len];
    }
};

/// Raw fingerprint data from a single protocol exchange.
pub const Fingerprint = struct {
    host: [256]u8 = [_]u8{0} ** 256,
    host_len: usize = 0,
    port: u16 = 0,
    protocol: ProbeProtocol = .CustomTCP,
    response_bytes: [1024]u8 = [_]u8{0} ** 1024,
    response_len: usize = 0,
    latency_ns: u64 = 0,
};

// ═══════════════════════════════════════════════════════════════════════════════
// Comptime known-port table
// ═══════════════════════════════════════════════════════════════════════════════

/// Well-known game server ports and the protocols / games associated with them.
pub const KNOWN_PORTS: []const KnownPort = &.{
    .{ .port = 27015, .protocol = .SteamQuery, .games = &.{ "cs2", "csgo", "tf2", "hl2dm", "garrysmod" } },
    .{ .port = 27016, .protocol = .SteamQuery, .games = &.{"cs2"} },
    .{ .port = 27020, .protocol = .SteamQuery, .games = &.{"tf2"} },
    .{ .port = 2456, .protocol = .SteamQuery, .games = &.{"valheim"} },
    .{ .port = 2457, .protocol = .SteamQuery, .games = &.{"valheim"} },
    .{ .port = 25565, .protocol = .MinecraftQuery, .games = &.{"minecraft-java"} },
    .{ .port = 19132, .protocol = .CustomTCP, .games = &.{"minecraft-bedrock"} },
    .{ .port = 7777, .protocol = .CustomTCP, .games = &.{ "ark", "unreal" } },
    .{ .port = 7778, .protocol = .SteamQuery, .games = &.{"ark"} },
    .{ .port = 34197, .protocol = .CustomTCP, .games = &.{"factorio"} },
    .{ .port = 27500, .protocol = .SteamQuery, .games = &.{"quake"} },
    .{ .port = 9876, .protocol = .SteamQuery, .games = &.{"satisfactory"} },
    .{ .port = 16261, .protocol = .CustomTCP, .games = &.{"project-zomboid"} },
    .{ .port = 2302, .protocol = .SteamQuery, .games = &.{ "dayz", "arma3" } },
    .{ .port = 28015, .protocol = .SteamQuery, .games = &.{"rust"} },
    .{ .port = 8766, .protocol = .SteamQuery, .games = &.{"dst"} },
    .{ .port = 10999, .protocol = .SteamQuery, .games = &.{"dst"} },
    .{ .port = 27102, .protocol = .SteamQuery, .games = &.{"barotrauma"} },
    .{ .port = 21025, .protocol = .CustomTCP, .games = &.{"starbound"} },
    .{ .port = 4380, .protocol = .SteamQuery, .games = &.{"steam-generic"} },
};

// ═══════════════════════════════════════════════════════════════════════════════
// Network helpers
// ═══════════════════════════════════════════════════════════════════════════════

/// Open a TCP connection to host:port with a timeout in milliseconds.
/// Returns the connected stream or an error.
fn tcpConnect(host: []const u8, port: u16, timeout_ms: u32) !net.Stream {
    const addr = try net.Address.parseIp4(host, port);
    const sock = try posix.socket(
        posix.AF.INET,
        posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
        0,
    );
    errdefer posix.close(sock);

    // non-blocking connect
    posix.connect(sock, &addr.any, addr.getOsSockLen()) catch |err| {
        if (err != error.WouldBlock) return err;
    };

    // poll for write-ready (connected)
    var pfd = [_]posix.pollfd{.{
        .fd = sock,
        .events = posix.POLL.OUT,
        .revents = 0,
    }};
    const nready = try posix.poll(&pfd, @intCast(timeout_ms));
    if (nready == 0) return error.ConnectionTimedOut;
    if (pfd[0].revents & posix.POLL.ERR != 0) return error.ConnectionRefused;

    // switch back to blocking for reads
    const flags = try posix.fcntl(sock, std.posix.F.GETFL, 0);
    // Clear NONBLOCK flag — in Zig 0.15 O is a packed struct, manipulate via @bitCast
    var oflags: std.posix.O = @bitCast(@as(u32, @truncate(flags)));
    oflags.NONBLOCK = false;
    _ = try posix.fcntl(sock, std.posix.F.SETFL, @as(usize, @as(u32, @bitCast(oflags))));

    return net.Stream{ .handle = sock };
}

/// Send a UDP datagram and wait for a response with timeout.
fn udpExchange(
    host: []const u8,
    port: u16,
    payload: []const u8,
    response_buf: []u8,
    timeout_ms: u32,
) !usize {
    const addr = try net.Address.parseIp4(host, port);
    const sock = try posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM,
        0,
    );
    defer posix.close(sock);

    // set receive timeout
    const timeout_sec: i64 = @intCast(timeout_ms / 1000);
    const timeout_usec: i64 = @intCast(@as(u64, timeout_ms % 1000) * 1000);
    const tv = posix.timeval{
        .sec = timeout_sec,
        .usec = timeout_usec,
    };
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));

    _ = try posix.sendto(sock, payload, 0, &addr.any, addr.getOsSockLen());

    const n = posix.recvfrom(sock, response_buf, 0, null, null) catch |err| {
        return switch (err) {
            error.WouldBlock => error.ConnectionTimedOut,
            else => err,
        };
    };
    return n;
}

/// Measure time between send and first byte of response, returning nanoseconds.
fn measureLatencyNs(start: std.time.Instant) u64 {
    const now = std.time.Instant.now() catch return 0;
    return now.since(start);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Protocol probes
// ═══════════════════════════════════════════════════════════════════════════════

/// Steam A2S_INFO query.  Sends the canonical challenge packet and parses
/// the Source Engine response header to extract game name and version.
///
/// Reference: https://developer.valvesoftware.com/wiki/Server_queries#A2S_INFO
pub fn trySteamQuery(host: []const u8, port: u16) !?ProbeResult {
    // A2S_INFO challenge: FF FF FF FF 54 "Source Engine Query\x00"
    const challenge = "\xff\xff\xff\xff\x54Source Engine Query\x00";
    var response_buf: [1400]u8 = undefined;

    const start = std.time.Instant.now() catch return null;
    const n = udpExchange(host, port, challenge, &response_buf, 3000) catch return null;
    const latency_ns = measureLatencyNs(start);

    if (n < 6) return null;
    const data = response_buf[0..n];

    // Validate header: FF FF FF FF 49 (type 'I' = 0x49)
    if (data[0] != 0xFF or data[1] != 0xFF or data[2] != 0xFF or data[3] != 0xFF)
        return null;

    // Response type: 0x49 (A2S_INFO), 0x41 (challenge — need to re-query)
    if (data[4] != 0x49) return null;

    // Parse: protocol(1) | name(NUL) | map(NUL) | folder(NUL) | game(NUL) | ...
    var pos: usize = 5;
    pos += 1; // skip protocol byte

    // server name (NUL-terminated)
    const name_start = pos;
    while (pos < n and data[pos] != 0) pos += 1;
    pos += 1; // skip NUL

    // map
    while (pos < n and data[pos] != 0) pos += 1;
    pos += 1;

    // folder (game directory)
    const folder_start = pos;
    while (pos < n and data[pos] != 0) pos += 1;
    const folder = data[folder_start..pos];
    pos += 1;

    // game description
    const game_start = pos;
    while (pos < n and data[pos] != 0) pos += 1;
    const game_desc = data[game_start..pos];
    _ = game_desc;
    pos += 1;

    // Steam app ID (2 bytes LE)
    if (pos + 2 > n) return null;
    pos += 2;

    // players, max players, bots (1 byte each)
    if (pos + 3 > n) return null;
    pos += 3;

    // server type, environment, visibility, VAC (1 byte each)
    if (pos + 4 > n) return null;
    pos += 4;

    // version string (NUL-terminated)
    const ver_start = pos;
    while (pos < n and data[pos] != 0) pos += 1;
    const version = data[ver_start..pos];

    var result = ProbeResult{};
    result.protocol = .SteamQuery;
    result.port = port;
    result.latency_ms = @intCast(latency_ns / std.time.ns_per_ms);
    result.setHost(host);
    result.setGameId(folder);
    result.setVersion(version);

    // Fingerprint signature: first 64 bytes of raw response
    const sig_len = @min(n, @as(usize, 64));
    result.setFingerprintSig(data[0..sig_len]);

    _ = name_start;
    return result;
}

/// Minecraft Server List Ping (SLP).
///
/// Performs the modern (1.7+) handshake + status request to retrieve
/// the server description, version, and player count.
pub fn tryMinecraftQuery(host: []const u8, port: u16) !?ProbeResult {
    var stream = tcpConnect(host, port, 3000) catch return null;
    defer stream.close();

    const start = std.time.Instant.now() catch return null;

    // Build handshake packet:  varint(packet_id=0x00) | varint(protocol=-1) |
    //   varint(host_len) | host | u16be(port) | varint(next_state=1)
    var handshake_buf: [512]u8 = undefined;
    var hs_pos: usize = 0;

    // Packet ID = 0x00
    handshake_buf[hs_pos] = 0x00;
    hs_pos += 1;

    // Protocol version = -1 (0xFF 0xFF 0xFF 0xFF 0x0F as varint)
    handshake_buf[hs_pos] = 0xFF;
    hs_pos += 1;
    handshake_buf[hs_pos] = 0xFF;
    hs_pos += 1;
    handshake_buf[hs_pos] = 0xFF;
    hs_pos += 1;
    handshake_buf[hs_pos] = 0xFF;
    hs_pos += 1;
    handshake_buf[hs_pos] = 0x0F;
    hs_pos += 1;

    // Host string as varint length + bytes
    const host_len_byte: u8 = @intCast(@min(host.len, 255));
    handshake_buf[hs_pos] = host_len_byte;
    hs_pos += 1;
    @memcpy(handshake_buf[hs_pos .. hs_pos + host_len_byte], host[0..host_len_byte]);
    hs_pos += host_len_byte;

    // Port (big-endian u16)
    handshake_buf[hs_pos] = @intCast(port >> 8);
    hs_pos += 1;
    handshake_buf[hs_pos] = @intCast(port & 0xFF);
    hs_pos += 1;

    // Next state = 1 (status)
    handshake_buf[hs_pos] = 0x01;
    hs_pos += 1;

    // Send handshake: varint(length) | data
    var frame_buf: [600]u8 = undefined;
    const hs_len_byte: u8 = @intCast(hs_pos);
    frame_buf[0] = hs_len_byte;
    @memcpy(frame_buf[1 .. 1 + hs_pos], handshake_buf[0..hs_pos]);
    _ = stream.write(frame_buf[0 .. 1 + hs_pos]) catch return null;

    // Send status request: length=1, packet_id=0x00
    _ = stream.write(&[_]u8{ 0x01, 0x00 }) catch return null;

    // Read response
    var read_buf: [4096]u8 = undefined;
    const bytes_read = stream.read(&read_buf) catch return null;
    if (bytes_read < 5) return null;

    const latency_ns = measureLatencyNs(start);

    // Parse: the response is a varint-length prefixed JSON payload.
    // Skip the length varint and packet ID, then extract the JSON.
    var rpos: usize = 0;

    // Skip packet length varint
    while (rpos < bytes_read and read_buf[rpos] & 0x80 != 0) rpos += 1;
    rpos += 1; // final byte of varint

    if (rpos >= bytes_read) return null;
    // Skip packet ID (0x00)
    rpos += 1;

    // Skip JSON string length varint
    while (rpos < bytes_read and read_buf[rpos] & 0x80 != 0) rpos += 1;
    rpos += 1;

    if (rpos >= bytes_read) return null;

    const json_data = read_buf[rpos..bytes_read];

    // Extract version name from JSON — look for "name":"<version>"
    var result = ProbeResult{};
    result.protocol = .MinecraftQuery;
    result.port = port;
    result.latency_ms = @intCast(latency_ns / std.time.ns_per_ms);
    result.setHost(host);
    result.setGameId("minecraft-java");
    result.setConfigPaths("/data/server.properties");

    // Simple JSON extraction for "name":" field inside "version":{...}
    if (std.mem.indexOf(u8, json_data, "\"name\":\"")) |idx| {
        const ver_start = idx + 8; // skip past "name":"
        if (std.mem.indexOfScalarPos(u8, json_data, ver_start, '"')) |ver_end| {
            result.setVersion(json_data[ver_start..ver_end]);
        }
    }

    const sig_len = @min(json_data.len, @as(usize, 128));
    result.setFingerprintSig(json_data[0..sig_len]);

    return result;
}

/// RCON handshake probe.
///
/// Sends an RCON authentication packet with an empty password; a valid
/// RCON server will respond with an auth-response packet (even if auth
/// fails), which confirms the protocol.
pub fn tryRCON(host: []const u8, port: u16) !?ProbeResult {
    var stream = tcpConnect(host, port, 3000) catch return null;
    defer stream.close();

    const start = std.time.Instant.now() catch return null;

    // RCON packet: int32le(size) | int32le(id) | int32le(type) | body | \x00\x00
    // Type 3 = SERVERDATA_AUTH
    const body = ""; // empty password probe
    const packet_size: u32 = 4 + 4 + @as(u32, @intCast(body.len)) + 2; // id + type + body + 2 NULs
    var pkt: [14]u8 = undefined;
    std.mem.writeInt(u32, pkt[0..4], packet_size, .little);
    std.mem.writeInt(u32, pkt[4..8], 1, .little); // request ID
    std.mem.writeInt(u32, pkt[8..12], 3, .little); // type = AUTH
    pkt[12] = 0; // body terminator
    pkt[13] = 0; // packet terminator

    _ = stream.write(&pkt) catch return null;

    var response: [64]u8 = undefined;
    const n = stream.read(&response) catch return null;
    if (n < 12) return null;

    const latency_ns = measureLatencyNs(start);

    // Valid RCON response: check that size and type fields are sane
    const resp_size = std.mem.readInt(u32, response[0..4], .little);
    const resp_type = std.mem.readInt(u32, response[8..12], .little);

    // type 2 = SERVERDATA_AUTH_RESPONSE, type 0 = SERVERDATA_RESPONSE_VALUE
    if (resp_size < 10 or (resp_type != 2 and resp_type != 0)) return null;

    var result = ProbeResult{};
    result.protocol = .RCON;
    result.port = port;
    result.latency_ms = @intCast(latency_ns / std.time.ns_per_ms);
    result.setHost(host);
    result.setGameId("rcon-compatible");

    return result;
}

/// HTTP probe — send a GET / and inspect the response for game-specific
/// indicators in headers or body content.
pub fn tryHTTPProbe(host: []const u8, port: u16) !?ProbeResult {
    var stream = tcpConnect(host, port, 3000) catch return null;
    defer stream.close();

    const start = std.time.Instant.now() catch return null;

    // Minimal HTTP/1.0 GET request
    var req_buf: [512]u8 = undefined;
    const req_len = std.fmt.bufPrint(&req_buf, "GET / HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{host}) catch return null;
    _ = stream.write(req_len) catch return null;

    var response: [2048]u8 = undefined;
    const n = stream.read(&response) catch return null;
    if (n < 12) return null;

    const latency_ns = measureLatencyNs(start);
    const data = response[0..n];

    // Must start with "HTTP/"
    if (!std.mem.startsWith(u8, data, "HTTP/")) return null;

    var result = ProbeResult{};
    result.protocol = .REST;
    result.port = port;
    result.latency_ms = @intCast(latency_ns / std.time.ns_per_ms);
    result.setHost(host);

    // Check for game-specific patterns in headers/body
    if (std.mem.indexOf(u8, data, "Factorio")) |_| {
        result.setGameId("factorio");
        result.setConfigPaths("/opt/factorio/data/server-settings.json");
    } else if (std.mem.indexOf(u8, data, "satisfactory")) |_| {
        result.setGameId("satisfactory");
    } else if (std.mem.indexOf(u8, data, "minecraft")) |_| {
        result.setGameId("minecraft-bedrock");
    } else {
        result.setGameId("http-unknown");
    }

    const sig_len = @min(n, @as(usize, 128));
    result.setFingerprintSig(data[0..sig_len]);

    return result;
}

/// Raw TCP banner grab — connect and read whatever the server sends
/// within the first 1024 bytes, then match against known patterns.
pub fn tryTCPBanner(host: []const u8, port: u16) !?ProbeResult {
    var stream = tcpConnect(host, port, 3000) catch return null;
    defer stream.close();

    const start = std.time.Instant.now() catch return null;

    var banner: [1024]u8 = undefined;
    const n = stream.read(&banner) catch return null;
    if (n == 0) return null;

    const latency_ns = measureLatencyNs(start);
    const data = banner[0..n];

    var result = ProbeResult{};
    result.protocol = .CustomTCP;
    result.port = port;
    result.latency_ms = @intCast(latency_ns / std.time.ns_per_ms);
    result.setHost(host);

    // Pattern matching against known banners
    if (std.mem.indexOf(u8, data, "SSH-")) |_| {
        result.protocol = .SSH;
        result.setGameId("ssh-host");
    } else if (std.mem.indexOf(u8, data, "Factorio")) |_| {
        result.setGameId("factorio");
    } else if (std.mem.indexOf(u8, data, "Project Zomboid")) |_| {
        result.setGameId("project-zomboid");
    } else if (std.mem.indexOf(u8, data, "Starbound")) |_| {
        result.setGameId("starbound");
    } else {
        result.setGameId("unknown-tcp");
    }

    const sig_len = @min(n, @as(usize, 128));
    result.setFingerprintSig(data[0..sig_len]);

    return result;
}

// ═══════════════════════════════════════════════════════════════════════════════
// High-level probe functions
// ═══════════════════════════════════════════════════════════════════════════════

/// Try all protocol probes on a single host:port and return the first
/// successful match.  Probes are attempted in priority order:
///   1. SteamQuery (UDP, most game servers)
///   2. MinecraftQuery (TCP SLP)
///   3. RCON (TCP)
///   4. HTTP (TCP)
///   5. TCP banner grab
pub fn probeSingle(host: []const u8, port: u16, timeout_ms: u32) !ProbeResult {
    _ = timeout_ms; // individual probes use their own timeouts

    // Try Steam A2S_INFO first — widest coverage
    if (try trySteamQuery(host, port)) |r| return r;

    // Minecraft SLP
    if (try tryMinecraftQuery(host, port)) |r| return r;

    // RCON handshake
    if (try tryRCON(host, port)) |r| return r;

    // HTTP/REST
    if (try tryHTTPProbe(host, port)) |r| return r;

    // Raw TCP
    if (try tryTCPBanner(host, port)) |r| return r;

    return error.NoProtocolMatched;
}

/// Probe multiple ports on the same host, collecting all successful results.
pub fn probeRange(
    allocator: Allocator,
    host: []const u8,
    ports: []const u16,
    timeout_ms: u32,
) ![]ProbeResult {
    var results = std.array_list.AlignedManaged(ProbeResult, null).init(allocator);
    errdefer results.deinit();

    for (ports) |port| {
        if (probeSingle(host, port, timeout_ms)) |result| {
            try results.append(result);
        } else |_| {}
    }

    return results.toOwnedSlice();
}

/// Low-level fingerprint: connect to host:port using the best-guess
/// protocol (from the known-ports table or TCP fallback) and capture
/// the raw exchange bytes + timing.
pub fn fingerprint(host: []const u8, port: u16) !Fingerprint {
    var fp = Fingerprint{};
    fp.port = port;
    const host_copy_len = @min(host.len, fp.host.len);
    @memcpy(fp.host[0..host_copy_len], host[0..host_copy_len]);
    fp.host_len = host_copy_len;

    // Check known-port table for protocol hint
    for (KNOWN_PORTS) |kp| {
        if (kp.port == port) {
            fp.protocol = kp.protocol;
            break;
        }
    }

    const start = std.time.Instant.now() catch return fp;

    switch (fp.protocol) {
        .SteamQuery => {
            const challenge = "\xff\xff\xff\xff\x54Source Engine Query\x00";
            fp.response_len = udpExchange(host, port, challenge, &fp.response_bytes, 3000) catch 0;
        },
        .MinecraftQuery, .CustomTCP => {
            var stream = tcpConnect(host, port, 3000) catch return fp;
            defer stream.close();
            fp.response_len = stream.read(&fp.response_bytes) catch 0;
        },
        else => {
            var stream = tcpConnect(host, port, 3000) catch return fp;
            defer stream.close();
            fp.response_len = stream.read(&fp.response_bytes) catch 0;
        },
    }

    fp.latency_ns = measureLatencyNs(start);
    return fp;
}

/// Match a raw fingerprint against the profile registry.
pub fn matchToProfile(
    fp: *const Fingerprint,
    registry: *game_profiles.ProfileRegistry,
) ?[]const u8 {
    const sig = fp.response_bytes[0..fp.response_len];
    if (sig.len == 0) return null;

    return registry.matchFingerprint(sig);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Exported C ABI functions
// ═══════════════════════════════════════════════════════════════════════════════

/// Probe a single host:port.
///
/// Returns 0 on success (result cached in handle), or a negative GsaResult
/// error code.
pub export fn gossamer_gsa_probe(
    host_ptr: [*:0]const u8,
    port_c: c_int,
) callconv(.c) c_int {
    const handle = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return @intFromEnum(main.GsaResult.not_initialized);
    };

    const host = std.mem.span(host_ptr);
    if (port_c < 1 or port_c > 65535) {
        main.setErrorStr("invalid port");
        return @intFromEnum(main.GsaResult.invalid_param);
    }
    const port: u16 = @intCast(port_c);

    const result = probeSingle(host, port, 5000) catch |err| {
        main.setError("probe failed: {s}", .{@errorName(err)});
        return @intFromEnum(main.GsaResult.connection_refused);
    };

    // Track the discovered server
    handle.trackServer(result.gameIdSlice(), .{
        .host = host,
        .port = port,
        .protocol = result.protocol,
        .last_seen_ms = std.time.milliTimestamp(),
        .healthy = true,
    }) catch {};

    main.clearError();
    return @intFromEnum(main.GsaResult.ok);
}

/// Fingerprint multiple ports (given as JSON array) on a host.
///
/// Returns a NUL-terminated JSON string with an array of fingerprint
/// objects.  Caller must treat the pointer as read-only; it is valid
/// until the next call to this function on the same thread.
threadlocal var fingerprint_result_buf: [8192]u8 = undefined;

pub export fn gossamer_gsa_fingerprint(
    host_ptr: [*:0]const u8,
    ports_json: [*:0]const u8,
) callconv(.c) [*:0]const u8 {
    const host = std.mem.span(host_ptr);
    const json_str = std.mem.span(ports_json);

    // Parse the JSON array of port numbers
    var buf_stream = std.io.fixedBufferStream(&fingerprint_result_buf);
    const writer = buf_stream.writer();

    writer.writeAll("[") catch return @as([*:0]const u8, @ptrCast(&[_:0]u8{'[', ']'}));

    // Simple JSON array parser: expect [1234, 5678, ...]
    var first = true;
    var pos: usize = 0;
    // Skip opening bracket
    while (pos < json_str.len and json_str[pos] != '[') pos += 1;
    if (pos < json_str.len) pos += 1;

    while (pos < json_str.len) {
        // Skip whitespace and commas
        while (pos < json_str.len and (json_str[pos] == ' ' or json_str[pos] == ',' or json_str[pos] == '\n' or json_str[pos] == '\t')) pos += 1;
        if (pos >= json_str.len or json_str[pos] == ']') break;

        // Parse integer
        var port_val: u16 = 0;
        while (pos < json_str.len and json_str[pos] >= '0' and json_str[pos] <= '9') {
            port_val = port_val *% 10 +% @as(u16, json_str[pos] - '0');
            pos += 1;
        }

        if (port_val > 0) {
            const fp = fingerprint(host, port_val) catch continue;

            if (!first) writer.writeAll(",") catch {};
            first = false;

            writer.print("{{\"port\":{d},\"protocol\":{d},\"response_len\":{d},\"latency_ns\":{d}}}", .{
                fp.port,
                @intFromEnum(fp.protocol),
                fp.response_len,
                fp.latency_ns,
            }) catch break;
        }
    }

    writer.writeAll("]") catch {};
    writer.writeByte(0) catch {};

    return @as([*:0]const u8, @ptrCast(&fingerprint_result_buf));
}

// ═══════════════════════════════════════════════════════════════════════════════
// Unit tests
// ═══════════════════════════════════════════════════════════════════════════════

test "known ports table is non-empty" {
    try std.testing.expect(KNOWN_PORTS.len >= 20);
}

test "known ports table has Minecraft on 25565" {
    var found = false;
    for (KNOWN_PORTS) |kp| {
        if (kp.port == 25565) {
            found = true;
            try std.testing.expectEqual(ProbeProtocol.MinecraftQuery, kp.protocol);
            break;
        }
    }
    try std.testing.expect(found);
}

test "known ports table has Steam on 27015" {
    var found = false;
    for (KNOWN_PORTS) |kp| {
        if (kp.port == 27015) {
            found = true;
            try std.testing.expectEqual(ProbeProtocol.SteamQuery, kp.protocol);
            break;
        }
    }
    try std.testing.expect(found);
}

test "ProbeResult set and get" {
    var r = ProbeResult{};
    r.setGameId("minecraft-java");
    r.setVersion("1.21.4");
    r.setHost("192.168.1.5");
    r.port = 25565;

    try std.testing.expectEqualStrings("minecraft-java", r.gameIdSlice());
    try std.testing.expectEqualStrings("1.21.4", r.versionSlice());
    try std.testing.expectEqualStrings("192.168.1.5", r.hostSlice());
    try std.testing.expectEqual(@as(u16, 25565), r.port);
}

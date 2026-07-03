// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// In-process mock game servers for behavioral probe tests. Each mock binds an
// ephemeral 127.0.0.1 port and answers a single protocol on a worker thread, so
// the probe engine can be exercised end-to-end with no live services. This is
// the regression net for the protocol bugs fixed in probe.zig (A2S challenge
// handshake, Minecraft SLP TCP framing) and the handle lifecycle in main.zig.
//
// Test-only module — not part of libgsa.

const std = @import("std");
const posix = std.posix;
const net = std.net;
const Allocator = std.mem.Allocator;

// A minimal but structurally complete A2S_INFO (0x49) reply the probe parser
// accepts: header, type, protocol, name/map/folder/game NUL strings, appid,
// player counts, flags, then the version string. `folder` ("valheim") becomes
// the probe's game_id; the trailing "1.0.0" becomes its version.
const A2S_INFO_REPLY =
    "\xFF\xFF\xFF\xFF\x49\x11" ++
    "Mock A2S\x00" ++ "de_dust2\x00" ++ "valheim\x00" ++ "Valheim\x00" ++
    "\x00\x00" ++ // appid (LE)
    "\x02\x10\x00" ++ // players, max, bots
    "\x64\x6c\x00\x01" ++ // type 'd', env 'l', visibility, VAC
    "1.0.0\x00";

// 0x41 challenge reply: header, type, 4-byte token. The probe must re-send its
// query with this token appended to receive the real 0x49 reply.
const A2S_CHALLENGE_REPLY = "\xFF\xFF\xFF\xFF\x41\xDE\xAD\xBE\xEF";

pub const A2SMode = enum {
    /// Reply with A2S_INFO immediately.
    direct,
    /// Reply 0x41 challenge first, A2S_INFO only after the token'd re-query.
    challenge,
    /// Receive the query but never reply (exercises the caller's timeout).
    silent,
};

/// UDP mock speaking the Steam A2S_INFO protocol on an ephemeral port.
pub const MockA2S = struct {
    allocator: Allocator,
    sock: posix.socket_t,
    port: u16,
    mode: A2SMode,
    stop_flag: std.atomic.Value(bool),
    thread: ?std.Thread = null,

    pub fn start(allocator: Allocator, mode: A2SMode) !*MockA2S {
        const self = try allocator.create(MockA2S);
        errdefer allocator.destroy(self);

        const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        errdefer posix.close(sock);

        var addr = try net.Address.parseIp4("127.0.0.1", 0);
        try posix.bind(sock, &addr.any, addr.getOsSockLen());

        // Read back the OS-assigned port.
        var slen: posix.socklen_t = addr.getOsSockLen();
        try posix.getsockname(sock, &addr.any, &slen);

        // Short recv timeout so the worker loop can observe stop_flag.
        const tv = posix.timeval{ .sec = 0, .usec = 200_000 };
        try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));

        self.* = .{
            .allocator = allocator,
            .sock = sock,
            .port = addr.getPort(),
            .mode = mode,
            .stop_flag = std.atomic.Value(bool).init(false),
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *MockA2S) void {
        var buf: [512]u8 = undefined;
        var src: posix.sockaddr = undefined;
        var challenged = false;
        while (!self.stop_flag.load(.acquire)) {
            var srclen: posix.socklen_t = @sizeOf(posix.sockaddr);
            const n = posix.recvfrom(self.sock, &buf, 0, &src, &srclen) catch continue;
            if (n < 5) continue;
            switch (self.mode) {
                .silent => {},
                .direct => _ = posix.sendto(self.sock, A2S_INFO_REPLY, 0, &src, srclen) catch {},
                .challenge => {
                    if (!challenged) {
                        _ = posix.sendto(self.sock, A2S_CHALLENGE_REPLY, 0, &src, srclen) catch {};
                        challenged = true;
                    } else {
                        _ = posix.sendto(self.sock, A2S_INFO_REPLY, 0, &src, srclen) catch {};
                    }
                },
            }
        }
    }

    pub fn stop(self: *MockA2S) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| t.join();
        posix.close(self.sock);
        self.allocator.destroy(self);
    }
};

// Build a Minecraft SLP status frame: VarInt(packetLen) | 0x00 | VarInt(jsonLen)
// | json. All lengths here are < 128, so every VarInt is one byte. The probe
// parser extracts the version from the JSON "name" field.
const SLP_JSON = "{\"version\":{\"name\":\"1.21.4\",\"protocol\":769},\"description\":\"Mock\"}";

fn slpFrame(buf: []u8) []const u8 {
    const json_len: u8 = @intCast(SLP_JSON.len);
    const inner_len: u8 = 1 + 1 + json_len; // packetID + jsonLen varint + json
    buf[0] = inner_len; // packet length varint
    buf[1] = 0x00; // packet id
    buf[2] = json_len; // json length varint
    @memcpy(buf[3 .. 3 + SLP_JSON.len], SLP_JSON);
    return buf[0 .. 3 + SLP_JSON.len];
}

/// TCP mock speaking the Minecraft Server List Ping protocol. Serves exactly one
/// connection. In `fragmented` mode it writes the response in two TCP segments
/// to exercise the framed read loop (a single read() would truncate it).
pub const MockSLP = struct {
    allocator: Allocator,
    server: net.Server,
    port: u16,
    fragmented: bool,
    thread: ?std.Thread = null,

    pub fn start(allocator: Allocator, fragmented: bool) !*MockSLP {
        const self = try allocator.create(MockSLP);
        errdefer allocator.destroy(self);

        var addr = try net.Address.parseIp4("127.0.0.1", 0);
        var server = try addr.listen(.{ .reuse_address = true });
        errdefer server.deinit();

        self.* = .{
            .allocator = allocator,
            .server = server,
            .port = server.listen_address.getPort(),
            .fragmented = fragmented,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *MockSLP) void {
        const conn = self.server.accept() catch return;
        defer conn.stream.close();

        // Drain the handshake + status request (contents don't matter here).
        var in: [512]u8 = undefined;
        _ = conn.stream.read(&in) catch {};

        var frame_buf: [256]u8 = undefined;
        const frame = slpFrame(&frame_buf);
        if (self.fragmented) {
            conn.stream.writeAll(frame[0..3]) catch return;
            std.Thread.sleep(5 * std.time.ns_per_ms);
            conn.stream.writeAll(frame[3..]) catch return;
        } else {
            conn.stream.writeAll(frame) catch return;
        }
    }

    pub fn stop(self: *MockSLP) void {
        if (self.thread) |t| t.join();
        self.server.deinit();
        self.allocator.destroy(self);
    }
};

/// TCP mock speaking just enough HTTP/1.1 to exercise the outbound HTTP
/// capability gateway's deadline. `never_respond` accepts the connection and
/// holds it open without answering (a black-hole endpoint); `slow_respond`
/// answers after `slow_ms`; `respond_ok` answers immediately with a 200 "ok".
/// The listener uses a short accept timeout so the loop can poll `stop_flag`.
pub const MockHTTP = struct {
    pub const Mode = enum { respond_ok, never_respond, slow_respond };

    allocator: Allocator,
    server: std.net.Server,
    port: u16,
    mode: Mode,
    slow_ms: u32 = 0,
    stop_flag: std.atomic.Value(bool),
    held: [16]?std.net.Server.Connection = [_]?std.net.Server.Connection{null} ** 16,
    held_mutex: std.Thread.Mutex = .{},
    thread: ?std.Thread = null,

    pub fn start(allocator: Allocator, mode: Mode, slow_ms: u32) !*MockHTTP {
        const self = try allocator.create(MockHTTP);
        errdefer allocator.destroy(self);

        var addr = try net.Address.parseIp4("127.0.0.1", 0);
        var server = try addr.listen(.{ .reuse_address = true });
        errdefer server.deinit();

        // Short accept timeout so the loop can observe stop_flag.
        const tv = posix.timeval{ .sec = 0, .usec = 200_000 };
        try posix.setsockopt(server.stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));

        self.* = .{
            .allocator = allocator,
            .server = server,
            .port = server.listen_address.getPort(),
            .mode = mode,
            .slow_ms = slow_ms,
            .stop_flag = std.atomic.Value(bool).init(false),
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Format "http://127.0.0.1:<port>/" into `buf`.
    pub fn urlBuf(self: *MockHTTP, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/", .{self.port}) catch unreachable;
    }

    fn run(self: *MockHTTP) void {
        while (!self.stop_flag.load(.acquire)) {
            const conn = self.server.accept() catch continue; // timeout/WouldBlock → re-check flag
            switch (self.mode) {
                .respond_ok => serve(conn),
                .slow_respond => {
                    std.Thread.sleep(@as(u64, self.slow_ms) * std.time.ns_per_ms);
                    serve(conn);
                },
                .never_respond => self.hold(conn), // keep open; closed in stop()
            }
        }
    }

    fn serve(conn: std.net.Server.Connection) void {
        var buf: [2048]u8 = undefined;
        _ = conn.stream.read(&buf) catch {};
        _ = conn.stream.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok") catch {};
        conn.stream.close();
    }

    fn hold(self: *MockHTTP, conn: std.net.Server.Connection) void {
        self.held_mutex.lock();
        defer self.held_mutex.unlock();
        for (&self.held) |*slot| {
            if (slot.* == null) {
                slot.* = conn;
                return;
            }
        }
        conn.stream.close(); // no room — don't leak the fd
    }

    pub fn stop(self: *MockHTTP) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| t.join();
        // Close held connections so any blocked worker's fetch unblocks (RST),
        // runs to completion, and frees its allocations before the leak check.
        self.held_mutex.lock();
        for (&self.held) |*slot| {
            if (slot.*) |c| {
                c.stream.close();
                slot.* = null;
            }
        }
        self.held_mutex.unlock();
        self.server.deinit();
        self.allocator.destroy(self);
    }
};

// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game Server Admin — Outbound HTTP capability gateway (client side).
//
// This is the estate's http-capability-gateway pattern applied to GSA's
// OUTBOUND calls. That project governs inbound HTTP by making "HTTP verbs and
// routes declared capabilities, not accidents" — a single mediation layer where
// each interaction carries a verb, a route allow-list, a trust level, a
// deadline, and a human-readable narrative, and default-deny holds. Here the
// same idea faces outward: no GSA subsystem calls std.http.Client.fetch
// directly. Instead each call site declares an `OutboundCapability` and this
// module's `call()` is the ONLY place fetch runs, enforcing the host allow-list
// and — critically — a hard wall-clock deadline that Zig 0.15's std.http.Client
// cannot provide on its own (fetch has no timeout knob and owns its socket, so
// there is no fd to time out; see probe.zig for the raw-socket paths that CAN).
//
// Deadline mechanism: a worker thread runs the opaque, un-cancellable fetch; the
// caller waits on a semaphore with the deadline (std.Thread.Semaphore.timedWait).
// This bounds the CALLER's latency uniformly for plain HTTP and TLS alike,
// because it sits above fetch. It cannot truly cancel the fetch — an abandoned
// worker keeps running until the OS errors its socket — so a bounded worker cap
// (MAX_OUTSTANDING) fails fast rather than accumulating blocked threads.
//
// Memory: every box/worker allocation uses std.heap.c_allocator (malloc —
// thread-safe and process-lifetime), so a worker that outlives its timed-out
// caller never touches a transient allocator. Ownership is a 2-count refcount on
// a shared RequestBox: the last releaser frees. No write-after-free, no leak.

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;
const main = @import("main.zig");

// ── Tunables ─────────────────────────────────────────────────────────────────

/// Max concurrent in-flight workers. Because a fetch to a black-hole endpoint
/// cannot be cancelled, this bounds how many blocked workers can accumulate;
/// beyond it, `call()` fails fast with Backpressure (the client-side analogue of
/// the gateway's circuit-breaker "fail fast when the backend is unhealthy").
pub const MAX_OUTSTANDING: usize = 64;
/// A zero/tiny deadline is clamped up so timedWait still bounds the caller.
pub const DEADLINE_FLOOR_MS: u32 = 1;
/// A mis-set deadline can't reintroduce an unbounded wait.
pub const MAX_DEADLINE_MS: u32 = 60_000;

// ── Vocabulary (mirrors http-capability-gateway) ─────────────────────────────

/// Client-trust axis — mirrors the gateway's SafeTrust total order. On the
/// client side this is advisory audit metadata (the trust WE assert as caller),
/// not an enforcement gate, but keeping the vocabulary aligned lets attestations
/// join across the estate.
pub const Trust = enum(u8) { untrusted = 0, authenticated = 1, internal = 2 };

/// A declared outbound-HTTP capability — one value per call site. Field names
/// mirror the gateway's DSL: `verb` ~ governance verbs, `host_allow` ~ the
/// client-side analogue of route allow-listing, `deadline_ms` ~ perf-contract
/// max_latency_ms (now a HARD deadline), `purpose` ~ the gateway's `narrative`,
/// `label` ~ its `capability` label, `trust` ~ SafeTrust.
pub const OutboundCapability = struct {
    verb: http.Method,
    url: []const u8,
    /// Non-empty allow-list of authorities. An entry matches the request URL's
    /// authority ("host" or "host:port") exactly, or matches its host part with
    /// the port stripped. Empty or non-matching ⇒ default-deny (HostNotAllowed).
    host_allow: []const []const u8,
    deadline_ms: u32,
    purpose: []const u8,
    label: []const u8,
    trust: Trust = .internal,
    body: ?[]const u8 = null,
    extra_headers: []const http.Header = &.{},
    /// Statuses treated as success. Default 2xx-ok only.
    accept: []const http.Status = &.{.ok},
};

pub const Response = struct {
    status: http.Status,
    /// Owned by the `allocator` passed to `call`; the caller frees it.
    body: []u8,
    latency_ms: u32,
};

pub const Error = error{
    /// The deadline fired before the request completed.
    Timeout,
    /// The URL's authority is not in `host_allow` (default-deny).
    HostNotAllowed,
    /// Too many workers already in flight (fail fast).
    Backpressure,
    /// std.Thread.spawn failed (infrastructure, not a deadline).
    SpawnFailed,
    /// fetch returned a non-accepted HTTP status.
    HttpError,
    /// fetch itself errored (connect/TLS/DNS/transport).
    Transport,
    OutOfMemory,
};

// ── Observability / test quiescence ──────────────────────────────────────────

/// Number of live workers (in flight, including abandoned-but-still-blocked).
/// Doubles as the concurrency gate and the test-quiescence signal.
pub var outstanding: std.atomic.Value(usize) = .init(0);

/// Spin until no workers remain in flight, or the timeout elapses. Tests call
/// this after closing a black-hole mock so abandoned workers drain (and free
/// their allocations) before the leak check runs.
pub fn waitQuiescent(timeout_ms: u32) void {
    var waited: u32 = 0;
    while (outstanding.load(.acquire) > 0 and waited < timeout_ms) {
        std.Thread.sleep(2 * std.time.ns_per_ms);
        waited += 2;
    }
}

// ── Shared request box (caller ⇄ worker) ─────────────────────────────────────

const State = enum(u8) { pending, completed, abandoned };

const RequestBox = struct {
    // Deep copies of the inputs (c_allocator-owned) so caller stack buffers and
    // transient bodies may die the moment `call` returns.
    verb: http.Method,
    url: []u8,
    body: ?[]u8,
    headers: []http.Header,
    accept: []http.Status,
    deadline_ns: u64,

    // Synchronisation.
    done: std.Thread.Semaphore = .{},
    state: std.atomic.Value(State) = .init(.pending),
    refs: std.atomic.Value(u8) = .init(2),

    // Outputs — written by the worker before `done.post()`, read by the caller
    // only on the non-timeout path (the semaphore gives happens-before).
    status: http.Status = .internal_server_error,
    body_out: ?[]u8 = null, // c_allocator-owned response body
    failed: bool = false, // fetch errored (transport)

    const a = std.heap.c_allocator;

    fn release(box: *RequestBox) void {
        if (box.refs.fetchSub(1, .acq_rel) == 1) box.destroy();
    }

    fn destroy(box: *RequestBox) void {
        a.free(box.url);
        if (box.body) |b| a.free(b);
        for (box.headers) |h| {
            a.free(@constCast(h.name));
            a.free(@constCast(h.value));
        }
        a.free(box.headers);
        a.free(box.accept);
        if (box.body_out) |b| a.free(b);
        a.destroy(box);
    }
};

fn dupHeader(h: http.Header) !http.Header {
    const a = std.heap.c_allocator;
    const name = try a.dupe(u8, h.name);
    errdefer a.free(name);
    const value = try a.dupe(u8, h.value);
    return .{ .name = name, .value = value };
}

// ── Host allow-list (default-deny) ───────────────────────────────────────────

/// Extract the authority ("host" or "host:port") from an absolute URL.
pub fn authorityOf(url: []const u8) ?[]const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[scheme + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const auth = rest[0..end];
    if (auth.len == 0) return null;
    return auth;
}

/// True iff the URL's authority is allow-listed. Matching rule: a port-qualified
/// entry ("host:port") must match the request authority exactly; a bare-host
/// entry ("host") allows any port on that host. This keeps a `localhost:8090`
/// allow-list from silently permitting `localhost:9999`, while letting a
/// host-only entry (e.g. "api.steampowered.com") match its default port.
pub fn hostAllowed(url: []const u8, host_allow: []const []const u8) bool {
    const auth = authorityOf(url) orelse return false;
    const auth_host = auth[0 .. std.mem.indexOfScalar(u8, auth, ':') orelse auth.len];
    for (host_allow) |entry| {
        if (std.mem.eql(u8, entry, auth)) return true; // exact authority
        // Bare-host entry (no port) matches any port on that host.
        if (std.mem.indexOfScalar(u8, entry, ':') == null and std.mem.eql(u8, entry, auth_host)) return true;
    }
    return false;
}

// ── Worker ───────────────────────────────────────────────────────────────────

fn workerMain(box: *RequestBox) void {
    const a = std.heap.c_allocator;
    // A fresh client per request, owned entirely by this thread.
    var client = http.Client{ .allocator = a };
    defer client.deinit();

    var sink = std.Io.Writer.Allocating.init(a);
    // On any early return we still must post + release + decrement outstanding.
    defer {
        box.done.post();
        box.release();
        _ = outstanding.fetchSub(1, .release);
    }

    const result = client.fetch(.{
        .location = .{ .url = box.url },
        .method = box.verb,
        .payload = box.body,
        .extra_headers = box.headers,
        .response_writer = &sink.writer,
    }) catch {
        sink.deinit();
        box.failed = true;
        return;
    };

    box.status = result.status;
    var list = sink.toArrayList();
    box.body_out = list.toOwnedSlice(a) catch blk: {
        list.deinit(a);
        break :blk null;
    };
}

/// Allocate a RequestBox and deep-copy all inputs into it (c_allocator-owned).
/// On any allocation failure, frees everything it built and returns the error;
/// on success returns a fully-initialised box the caller/worker co-own.
fn buildBox(cap: OutboundCapability, deadline_ms: u32) error{OutOfMemory}!*RequestBox {
    const a = std.heap.c_allocator;
    const box = try a.create(RequestBox);
    errdefer a.destroy(box);

    const url_copy = try a.dupe(u8, cap.url);
    errdefer a.free(url_copy);

    const body_copy: ?[]u8 = if (cap.body) |b| try a.dupe(u8, b) else null;
    errdefer if (body_copy) |b| a.free(b);

    const headers = try a.alloc(http.Header, cap.extra_headers.len);
    var built: usize = 0;
    errdefer {
        for (headers[0..built]) |h| {
            a.free(@constCast(h.name));
            a.free(@constCast(h.value));
        }
        a.free(headers);
    }
    for (cap.extra_headers, 0..) |h, i| {
        headers[i] = try dupHeader(h);
        built += 1;
    }

    const accept = try a.dupe(http.Status, cap.accept);
    errdefer a.free(accept);

    box.* = .{
        .verb = cap.verb,
        .url = url_copy,
        .body = body_copy,
        .headers = headers,
        .accept = accept,
        .deadline_ns = @as(u64, deadline_ms) * std.time.ns_per_ms,
    };
    return box;
}

// ── The single mediation point ───────────────────────────────────────────────

/// Perform one outbound HTTP call under a declared capability. The ONLY caller
/// of std.http.Client.fetch in the FFI layer. Enforces the host allow-list
/// (default-deny) and a hard `deadline_ms` wall-clock bound on the whole
/// operation. On success returns a `Response` whose body is owned by
/// `allocator`; on a deadline hit returns `error.Timeout` promptly (the worker
/// keeps running but is counted and bounded).
pub fn call(allocator: Allocator, cap: OutboundCapability) Error!Response {
    // 1. Default-deny on the host allow-list — before any socket is opened.
    if (!hostAllowed(cap.url, cap.host_allow)) {
        main.setError("outbound denied: host not allowed (label={s} purpose={s} url={s})", .{
            cap.label, cap.purpose, cap.url,
        });
        return error.HostNotAllowed;
    }

    // 2. Fail fast if too many workers are already blocked. From here until the
    //    worker is spawned, WE own the outstanding slot; the worker takes it over
    //    on success and releases it when it finishes.
    if (outstanding.fetchAdd(1, .acq_rel) >= MAX_OUTSTANDING) {
        _ = outstanding.fetchSub(1, .acq_rel);
        main.setError("outbound backpressure: {d} calls in flight (label={s})", .{ MAX_OUTSTANDING, cap.label });
        return error.Backpressure;
    }

    const deadline_ms = std.math.clamp(cap.deadline_ms, DEADLINE_FLOOR_MS, MAX_DEADLINE_MS);

    // 3. Build the shared box (self-cleaning on failure).
    const box = buildBox(cap, deadline_ms) catch {
        _ = outstanding.fetchSub(1, .acq_rel);
        return error.OutOfMemory;
    };

    // 4. Spawn the worker and wait on the deadline.
    var timer = std.time.Timer.start() catch unreachable;
    const thread = std.Thread.spawn(.{}, workerMain, .{box}) catch {
        // No worker will co-own the box — free it directly (single owner).
        box.destroy();
        _ = outstanding.fetchSub(1, .acq_rel);
        main.setError("outbound spawn failed (label={s})", .{cap.label});
        return error.SpawnFailed;
    };
    thread.detach();
    // The worker now co-owns the box and owns the outstanding-slot release.

    box.done.timedWait(box.deadline_ns) catch {
        // Deadline hit: abandon. Never read body_out. Worker frees the box.
        box.state.store(.abandoned, .release);
        box.release();
        main.setError("outbound timed out after {d}ms (label={s} purpose={s})", .{
            deadline_ms, cap.label, cap.purpose,
        });
        return error.Timeout;
    };

    // 5. Completed in time — happens-before makes outputs visible.
    const latency_ms: u32 = @intCast(@min(timer.read() / std.time.ns_per_ms, std.math.maxInt(u32)));
    defer box.release();

    if (box.failed) {
        main.setError("outbound transport error (label={s} url={s})", .{ cap.label, cap.url });
        return error.Transport;
    }

    // Status acceptance check (mirrors each client's previous inline logic).
    var accepted = false;
    for (box.accept) |s| {
        if (box.status == s) {
            accepted = true;
            break;
        }
    }
    if (!accepted) {
        main.setError("outbound HTTP {d} not accepted (label={s})", .{ @intFromEnum(box.status), cap.label });
        return error.HttpError;
    }

    // Steal the worker's c_allocator body into the caller's allocator so the
    // caller frees it with their own allocator; free the original here.
    const src = box.body_out orelse &[_]u8{};
    const out = allocator.dupe(u8, src) catch return error.OutOfMemory;
    if (box.body_out) |b| {
        std.heap.c_allocator.free(b);
        box.body_out = null; // box.destroy() must not double-free it
    }
    return .{ .status = box.status, .body = out, .latency_ms = latency_ms };
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// abi_serde.zig — the live binary ABI: emitters that serialise GSA records into
// the canonical `extern struct` wire format (abi_layout.zig), and the C readers
// the Idris2 ABI layer (GSA.ABI.Foreign) binds to consume them.
//
// This is what makes the proven `Layout.idr` offsets a *runtime* contract: an
// emitter writes a wire struct whose layout the compiler guarantees matches the
// Idris model (enforced in abi_layout.zig); the Idris side then reads each field
// with `gossamer_gsa_read_int(ptr, offset)` / `gossamer_gsa_read_double(...)`
// using the very same offsets it proved. The round-trip tests below stand in for
// the Idris reader and assert the two agree.
//
// Memory: every emitter returns a single `malloc`-ed block (struct header
// followed by its string bytes), so one `gossamer_gsa_free(ptr)` releases it.

const std = @import("std");
const main = @import("main.zig");
pub const abi = @import("abi_layout.zig");

// Static empty C string returned in place of NULL so callers never deref null.
const empty_cstr: [*:0]const u8 = "";

// ── Serialised string-array header ───────────────────────────────────────────
// Buffer layout: [ArrayHeader][count × CStr pointers][packed NUL-terminated
// string bytes]. The pointers point into the trailing bytes.
pub const ArrayHeader = extern struct {
    count: u32,
    _pad: u32 = 0,
};

// ── Emitters ─────────────────────────────────────────────────────────────────

/// Serialise a DriftReport into a single owned block. `serverId` is copied in
/// just past the struct; the rest are scalar fields. Returns null on OOM.
pub fn serializeDriftReport(
    server_id: []const u8,
    status: i32,
    config_drift: f64,
    semantic_drift: f64,
    temporal_consistency: f64,
    overall_score: f64,
) ?*abi.DriftReport {
    const header = @sizeOf(abi.DriftReport);
    const total = header + server_id.len + 1;
    const block: [*]u8 = @ptrCast(std.c.malloc(total) orelse return null);
    const sid_dst = block + header;
    @memcpy(sid_dst[0..server_id.len], server_id);
    sid_dst[server_id.len] = 0;

    const dr: *abi.DriftReport = @ptrCast(@alignCast(block));
    dr.* = .{
        .serverId = @ptrCast(sid_dst),
        .status = status,
        .configDrift = config_drift,
        .semanticDrift = semantic_drift,
        .temporalConsistency = temporal_consistency,
        .overallScore = overall_score,
    };
    return dr;
}

/// Serialise a Fingerprint into a single owned block (struct header followed by
/// the `host` and `responseSignature` bytes). Returns null on OOM.
pub fn serializeFingerprint(
    host: []const u8,
    port: u32,
    protocol: i32,
    signature: []const u8,
    latency_ms: u32,
) ?*abi.Fingerprint {
    const header = @sizeOf(abi.Fingerprint);
    const total = header + host.len + 1 + signature.len + 1;
    const block: [*]u8 = @ptrCast(std.c.malloc(total) orelse return null);

    const host_dst = block + header;
    @memcpy(host_dst[0..host.len], host);
    host_dst[host.len] = 0;

    const sig_dst = block + header + host.len + 1;
    @memcpy(sig_dst[0..signature.len], signature);
    sig_dst[signature.len] = 0;

    const fp: *abi.Fingerprint = @ptrCast(@alignCast(block));
    fp.* = .{
        .host = @ptrCast(host_dst),
        .port = port,
        .protocol = protocol,
        .responseSignature = @ptrCast(sig_dst),
        .latencyMs = latency_ms,
    };
    return fp;
}

/// Serialise a list of strings into the array wire format. Returns null on OOM.
pub fn serializeStringArray(items: []const []const u8) ?*anyopaque {
    const ptr_bytes = items.len * @sizeOf(abi.CStr);
    var str_bytes: usize = 0;
    for (items) |s| str_bytes += s.len + 1;
    const total = @sizeOf(ArrayHeader) + ptr_bytes + str_bytes;

    const block: [*]u8 = @ptrCast(std.c.malloc(total) orelse return null);
    const hdr: *ArrayHeader = @ptrCast(@alignCast(block));
    hdr.* = .{ .count = @intCast(items.len) };

    const items_base: [*]abi.CStr = @ptrCast(@alignCast(block + @sizeOf(ArrayHeader)));
    var cursor: usize = @sizeOf(ArrayHeader) + ptr_bytes;
    for (items, 0..) |s, i| {
        const dst = block + cursor;
        @memcpy(dst[0..s.len], s);
        dst[s.len] = 0;
        items_base[i] = @ptrCast(dst);
        cursor += s.len + 1;
    }
    return @ptrCast(block);
}

// ── Exported C ABI: offset readers (Layout.idr becomes a live contract) ──────

/// Read an int32 field at `offset` bytes into a serialised struct.
/// Alignment-agnostic (`memcpy`-based) so any 4-aligned proven offset is safe.
pub export fn gossamer_gsa_read_int(ptr: ?*const anyopaque, offset: i32) callconv(.c) i32 {
    const base = ptr orelse return 0;
    if (offset < 0) return 0;
    const src: [*]const u8 = @ptrFromInt(@intFromPtr(base) + @as(usize, @intCast(offset)));
    var v: i32 = 0;
    @memcpy(std.mem.asBytes(&v), src[0..@sizeOf(i32)]);
    return v;
}

/// Read a double field at `offset` bytes into a serialised struct.
pub export fn gossamer_gsa_read_double(ptr: ?*const anyopaque, offset: i32) callconv(.c) f64 {
    const base = ptr orelse return 0;
    if (offset < 0) return 0;
    const src: [*]const u8 = @ptrFromInt(@intFromPtr(base) + @as(usize, @intCast(offset)));
    var v: f64 = 0;
    @memcpy(std.mem.asBytes(&v), src[0..@sizeOf(f64)]);
    return v;
}

/// Read a pointer field (e.g. a `char*`) at `offset` bytes into a serialised
/// struct. Combined with `gossamer_gsa_read_string` this decodes string fields:
/// `read_string(read_ptr(struct, offsetOf "serverId"))`. NULL/negative-safe.
pub export fn gossamer_gsa_read_ptr(ptr: ?*const anyopaque, offset: i32) callconv(.c) ?*anyopaque {
    const base = ptr orelse return null;
    if (offset < 0) return null;
    const src: [*]const u8 = @ptrFromInt(@intFromPtr(base) + @as(usize, @intCast(offset)));
    var v: usize = 0;
    @memcpy(std.mem.asBytes(&v), src[0..@sizeOf(usize)]);
    return @ptrFromInt(v);
}

/// Interpret a non-null `char*` as a NUL-terminated string (identity/validation
/// for string results and struct `CStr` fields). Returns "" for NULL.
pub export fn gossamer_gsa_read_string(ptr: ?*const anyopaque) callconv(.c) [*:0]const u8 {
    const p = ptr orelse return empty_cstr;
    return @ptrCast(p);
}

/// Number of elements in a serialised string array (0 for NULL).
pub export fn gossamer_gsa_array_len(ptr: ?*const anyopaque) callconv(.c) i32 {
    const base = ptr orelse return 0;
    const hdr: *const ArrayHeader = @ptrCast(@alignCast(base));
    return @intCast(hdr.count);
}

/// The `index`-th string in a serialised string array ("" if out of range/NULL).
pub export fn gossamer_gsa_array_get_string(ptr: ?*const anyopaque, index: i32) callconv(.c) [*:0]const u8 {
    const base = ptr orelse return empty_cstr;
    const hdr: *const ArrayHeader = @ptrCast(@alignCast(base));
    if (index < 0 or @as(u32, @intCast(index)) >= hdr.count) return empty_cstr;
    const items: [*]const abi.CStr = @ptrFromInt(@intFromPtr(base) + @sizeOf(ArrayHeader));
    return items[@intCast(index)] orelse empty_cstr;
}

/// 1 if the pointer is NULL, else 0.
pub export fn gossamer_gsa_is_null(ptr: ?*const anyopaque) callconv(.c) i32 {
    return if (ptr == null) 1 else 0;
}

/// Free a buffer previously returned by an ABI emitter. NULL-safe.
pub export fn gossamer_gsa_free(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| std.c.free(p);
}

/// Validate and accept a serialised A2MLConfig (binary wire struct).
/// Reads are at the proven Layout.idr offsets; persistence to disk is delegated
/// to `gossamer_gsa_write_server_config`.
pub export fn gossamer_gsa_apply_config(handle: c_int, config: ?*const anyopaque) callconv(.c) c_int {
    _ = handle;
    const cfg = config orelse {
        main.setErrorStr("null config");
        return @intFromEnum(main.GsaResult.null_pointer);
    };
    if (main.getGlobalHandle() == null) {
        main.setErrorStr("not initialized");
        return @intFromEnum(main.GsaResult.not_initialized);
    }
    const a2ml: *const abi.A2MLConfig = @ptrCast(@alignCast(cfg));
    if (a2ml.serverId == null) {
        main.setErrorStr("config missing serverId");
        return @intFromEnum(main.GsaResult.invalid_param);
    }
    main.clearError();
    return @intFromEnum(main.GsaResult.ok);
}

/// Close a server handle. The current FFI uses a process-global singleton, so a
/// per-id close is a validated no-op; use `gossamer_gsa_shutdown` to release the
/// global handle. Reserved for the future multi-handle model.
pub export fn gossamer_gsa_close_handle(handle: c_int) callconv(.c) c_int {
    _ = handle;
    if (main.getGlobalHandle() == null) {
        main.setErrorStr("not initialized");
        return @intFromEnum(main.GsaResult.not_initialized);
    }
    main.clearError();
    return @intFromEnum(main.GsaResult.ok);
}

/// Emit a DriftReport wire struct for a tracked server. `status` reflects the
/// tracked liveness (0 = Healthy, 2 = Degraded — see GSA.ABI.Types.HealthStatus);
/// drift metrics are 0 until VeriSimDB scoring is wired. Caller must
/// `gossamer_gsa_free` the result.
pub export fn gossamer_gsa_drift_struct(server_id: [*:0]const u8) callconv(.c) ?*abi.DriftReport {
    const gsa = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return null;
    };
    const sid = std.mem.span(server_id);
    const conn = gsa.getConnection(sid) orelse {
        main.setError("unknown server: {s}", .{sid});
        return null;
    };
    const status: i32 = if (conn.healthy) 0 else 2;
    main.clearError();
    return serializeDriftReport(sid, status, 0.0, 0.0, 0.0, 0.0);
}

// ── Tests ────────────────────────────────────────────────────────────────────

/// Proven offset of a named field, as the Idris side would compute it.
fn off(comptime spec: abi.expected.StructExpect, comptime name: []const u8) i32 {
    return comptime blk: {
        for (spec.fields) |f| {
            if (std.mem.eql(u8, f.name, name)) break :blk @as(i32, @intCast(f.offset));
        }
        @compileError("no such field: " ++ name);
    };
}

test "DriftReport round-trips through the live offset contract" {
    const dr = serializeDriftReport("srv-1", 2, 0.25, 0.5, 0.75, 0.9) orelse return error.OutOfMemory;
    defer gossamer_gsa_free(dr);

    const E = abi.expected.DriftReport;
    // Read each scalar at the *proven* Layout.idr offset — this is exactly what
    // the Idris reader does, so agreement = a live cross-language ABI contract.
    try std.testing.expectEqual(@as(i32, 2), gossamer_gsa_read_int(dr, off(E, "status")));
    try std.testing.expectEqual(@as(f64, 0.25), gossamer_gsa_read_double(dr, off(E, "configDrift")));
    try std.testing.expectEqual(@as(f64, 0.5), gossamer_gsa_read_double(dr, off(E, "semanticDrift")));
    try std.testing.expectEqual(@as(f64, 0.75), gossamer_gsa_read_double(dr, off(E, "temporalConsistency")));
    try std.testing.expectEqual(@as(f64, 0.9), gossamer_gsa_read_double(dr, off(E, "overallScore")));
    // serverId is a char* field: read the pointer at its offset, then the string —
    // exactly the read_ptr∘read_string path the Idris reader uses.
    try std.testing.expectEqualStrings("srv-1", std.mem.span(gossamer_gsa_read_string(gossamer_gsa_read_ptr(dr, off(E, "serverId")))));

    // Guard: the offsets actually exercised are the machine-checked ones.
    try std.testing.expectEqual(@as(i32, 8), off(E, "status"));
    try std.testing.expectEqual(@as(i32, 16), off(E, "configDrift"));
    try std.testing.expectEqual(@as(i32, 40), off(E, "overallScore"));
}

test "Fingerprint round-trips through the live offset contract" {
    const fp = serializeFingerprint("10.0.0.5", 27015, 1, "deadbeef", 42) orelse return error.OutOfMemory;
    defer gossamer_gsa_free(fp);

    const E = abi.expected.Fingerprint;
    try std.testing.expectEqual(@as(i32, 27015), gossamer_gsa_read_int(fp, off(E, "port")));
    try std.testing.expectEqual(@as(i32, 1), gossamer_gsa_read_int(fp, off(E, "protocol")));
    try std.testing.expectEqual(@as(i32, 42), gossamer_gsa_read_int(fp, off(E, "latencyMs")));
    try std.testing.expectEqualStrings("10.0.0.5", std.mem.span(gossamer_gsa_read_string(fp.host)));
    try std.testing.expectEqualStrings("deadbeef", std.mem.span(gossamer_gsa_read_string(fp.responseSignature)));
}

test "string array round-trips through array_len / array_get_string" {
    const arr = serializeStringArray(&.{ "alpha", "bravo", "charlie" }) orelse return error.OutOfMemory;
    defer gossamer_gsa_free(arr);

    try std.testing.expectEqual(@as(i32, 3), gossamer_gsa_array_len(arr));
    try std.testing.expectEqualStrings("alpha", std.mem.span(gossamer_gsa_array_get_string(arr, 0)));
    try std.testing.expectEqualStrings("bravo", std.mem.span(gossamer_gsa_array_get_string(arr, 1)));
    try std.testing.expectEqualStrings("charlie", std.mem.span(gossamer_gsa_array_get_string(arr, 2)));
    // out-of-range and negative are safe and yield ""
    try std.testing.expectEqualStrings("", std.mem.span(gossamer_gsa_array_get_string(arr, 3)));
    try std.testing.expectEqualStrings("", std.mem.span(gossamer_gsa_array_get_string(arr, -1)));
}

test "null-safety of readers" {
    try std.testing.expectEqual(@as(i32, 1), gossamer_gsa_is_null(null));
    try std.testing.expectEqual(@as(i32, 0), gossamer_gsa_read_int(null, 0));
    try std.testing.expectEqual(@as(f64, 0), gossamer_gsa_read_double(null, 0));
    try std.testing.expectEqual(@as(i32, 0), gossamer_gsa_array_len(null));
    try std.testing.expectEqualStrings("", std.mem.span(gossamer_gsa_read_string(null)));
    gossamer_gsa_free(null); // must not crash
}

test "is_null distinguishes a real pointer" {
    const dr = serializeDriftReport("x", 0, 0, 0, 0, 0) orelse return error.OutOfMemory;
    defer gossamer_gsa_free(dr);
    try std.testing.expectEqual(@as(i32, 0), gossamer_gsa_is_null(dr));
}

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
// Conventions (matching the rest of the FFI — zero unchecked pointer/alignment
// casts):
//   * Readers reinterpret memory through `@ptrFromInt` + `@memcpy` (which are
//     alignment-agnostic); emitters build a typed view of a byte block with
//     `std.mem.bytesAsValue` / `bytesAsSlice`.
//   * Every emitter returns one `c_allocator` block (struct header followed by
//     its string bytes), released by a single `gossamer_gsa_free(ptr)`
//     (`std.c.free`, since `c_allocator` is malloc-backed at these alignments).

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
    const block = std.heap.c_allocator.alignedAlloc(u8, .of(abi.DriftReport), header + server_id.len + 1) catch return null;
    @memcpy(block[header..][0..server_id.len], server_id);
    block[header + server_id.len] = 0;

    const dr = std.mem.bytesAsValue(abi.DriftReport, block[0..header]);
    dr.* = .{
        .serverId = block[header..][0..server_id.len :0].ptr,
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
    const block = std.heap.c_allocator.alignedAlloc(u8, .of(abi.Fingerprint), header + host.len + 1 + signature.len + 1) catch return null;

    const host_off = header;
    @memcpy(block[host_off..][0..host.len], host);
    block[host_off + host.len] = 0;

    const sig_off = host_off + host.len + 1;
    @memcpy(block[sig_off..][0..signature.len], signature);
    block[sig_off + signature.len] = 0;

    const fp = std.mem.bytesAsValue(abi.Fingerprint, block[0..header]);
    fp.* = .{
        .host = block[host_off..][0..host.len :0].ptr,
        .port = port,
        .protocol = protocol,
        .responseSignature = block[sig_off..][0..signature.len :0].ptr,
        .latencyMs = latency_ms,
    };
    return fp;
}

/// Serialise a list of strings into the array wire format. Returns null on OOM.
pub fn serializeStringArray(items: []const []const u8) ?*anyopaque {
    const ptr_region = items.len * @sizeOf(abi.CStr);
    var str_bytes: usize = 0;
    for (items) |s| str_bytes += s.len + 1;

    // Align to CStr (8) so both the header (4) and the pointer slots fit.
    const block = std.heap.c_allocator.alignedAlloc(u8, .of(abi.CStr), @sizeOf(ArrayHeader) + ptr_region + str_bytes) catch return null;
    const hdr = std.mem.bytesAsValue(ArrayHeader, block[0..@sizeOf(ArrayHeader)]);
    hdr.* = .{ .count = @intCast(items.len) };

    const slots = std.mem.bytesAsSlice(abi.CStr, block[@sizeOf(ArrayHeader)..][0..ptr_region]);
    var cursor: usize = @sizeOf(ArrayHeader) + ptr_region;
    for (items, 0..) |s, i| {
        @memcpy(block[cursor..][0..s.len], s);
        block[cursor + s.len] = 0;
        slots[i] = block[cursor..][0..s.len :0].ptr;
        cursor += s.len + 1;
    }
    return &block[0];
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
    if (v == 0) return null;
    return @ptrFromInt(v);
}

/// Interpret a non-null `char*` as a NUL-terminated string (identity/validation
/// for string results and struct `CStr` fields). Returns "" for NULL.
pub export fn gossamer_gsa_read_string(ptr: ?*const anyopaque) callconv(.c) [*:0]const u8 {
    const p = ptr orelse return empty_cstr;
    return @ptrFromInt(@intFromPtr(p));
}

/// Number of elements in a serialised string array (0 for NULL).
pub export fn gossamer_gsa_array_len(ptr: ?*const anyopaque) callconv(.c) i32 {
    const base = ptr orelse return 0;
    const src: [*]const u8 = @ptrFromInt(@intFromPtr(base));
    var count: u32 = 0;
    @memcpy(std.mem.asBytes(&count), src[0..@sizeOf(u32)]);
    return @intCast(count);
}

/// The `index`-th string in a serialised string array ("" if out of range/NULL).
pub export fn gossamer_gsa_array_get_string(ptr: ?*const anyopaque, index: i32) callconv(.c) [*:0]const u8 {
    const base = ptr orelse return empty_cstr;
    if (index < 0) return empty_cstr;
    const src: [*]const u8 = @ptrFromInt(@intFromPtr(base));
    var count: u32 = 0;
    @memcpy(std.mem.asBytes(&count), src[0..@sizeOf(u32)]);
    if (@as(u32, @intCast(index)) >= count) return empty_cstr;

    const slot_addr = @intFromPtr(base) + @sizeOf(ArrayHeader) + @as(usize, @intCast(index)) * @sizeOf(abi.CStr);
    const slot: [*]const u8 = @ptrFromInt(slot_addr);
    var elem: usize = 0;
    @memcpy(std.mem.asBytes(&elem), slot[0..@sizeOf(usize)]);
    if (elem == 0) return empty_cstr;
    return @ptrFromInt(elem);
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
/// `handle` must be a live probe handle from `gossamer_gsa_probe`; using a
/// closed handle reports `already_consumed` (the linear-type violation the
/// Idris side proves impossible for its own callers). `serverId` (the first
/// field, offset 0) is read via the same offset-reader the Idris side uses;
/// persistence to disk is delegated to `gossamer_gsa_write_server_config`.
pub export fn gossamer_gsa_apply_config(handle: c_int, config: ?*const anyopaque) callconv(.c) c_int {
    if (config == null) {
        main.setErrorStr("null config");
        return @intFromEnum(main.GsaResult.null_pointer);
    }
    const gsa = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return @intFromEnum(main.GsaResult.not_initialized);
    };
    switch (gsa.useHandle(handle)) {
        .live => {},
        .consumed => {
            main.setError("handle {d} already consumed", .{handle});
            return @intFromEnum(main.GsaResult.already_consumed);
        },
        .unknown => {
            main.setError("unknown handle {d}", .{handle});
            return @intFromEnum(main.GsaResult.not_found);
        },
    }
    if (gossamer_gsa_read_ptr(config, 0) == null) {
        main.setErrorStr("config missing serverId");
        return @intFromEnum(main.GsaResult.invalid_param);
    }
    main.clearError();
    return @intFromEnum(main.GsaResult.ok);
}

/// Close a probe handle returned by `gossamer_gsa_probe`, releasing its
/// server-id binding. A second close of the same id reports `double_free`
/// (within the bounded tombstone window — see main.CLOSED_HANDLE_TOMBSTONES);
/// an id that was never issued reports `not_found`.
pub export fn gossamer_gsa_close_handle(handle: c_int) callconv(.c) c_int {
    const gsa = main.getGlobalHandle() orelse {
        main.setErrorStr("not initialized");
        return @intFromEnum(main.GsaResult.not_initialized);
    };
    switch (gsa.closeHandle(handle)) {
        .live => {
            main.clearError();
            return @intFromEnum(main.GsaResult.ok);
        },
        .consumed => {
            main.setError("handle {d} closed twice", .{handle});
            return @intFromEnum(main.GsaResult.double_free);
        },
        .unknown => {
            main.setError("unknown handle {d}", .{handle});
            return @intFromEnum(main.GsaResult.not_found);
        },
    }
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
    // exactly the read_ptr then read_string path the Idris reader uses.
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

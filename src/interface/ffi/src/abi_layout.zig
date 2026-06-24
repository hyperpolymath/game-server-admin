// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// abi_layout.zig — canonical C-ABI structs + Zig↔Idris layout cross-check.
//
// `Layout.idr` (GSA.ABI.Layout) carries machine-checked proofs that the GSA
// wire structs are internally consistent (NoOverlap / AllFieldsAligned /
// SizeAligned / SizeCoversFields). Those proofs operate on hand-written offset
// constants, so on their own they cannot guarantee the numbers match what a C
// compiler actually lays out. This module closes that gap:
//
//   1. It declares each of the 8 ABI structs as a Zig `extern struct` — the
//      real System-V / AAPCS64 C layout, with padding inserted by the compiler.
//   2. A comptime block asserts, for every struct and every (non-padding)
//      field, that Zig's `@offsetOf` / `@sizeOf` / `@alignOf` equal the proven
//      Idris constants (lifted verbatim into abi_layout_expected.zig by
//      scripts/gen_abi_expected.py). A divergence is a *compile error*, so the
//      library cannot build against a layout the proofs do not describe.
//
// Together with the Idris proofs this gives the end-to-end guarantee: the
// offsets the Idris side reads with `gossamer_gsa_read_int(ptr, offset)` are the
// offsets the C compiler writes. See abi_serde.zig for the live readers.
//
// Source of truth is Layout.idr. Never edit abi_layout_expected.zig by hand;
// regenerate it (`python3 scripts/gen_abi_expected.py`) and the offsets here
// will be re-checked on the next build.

const std = @import("std");
pub const expected = @import("abi_layout_expected.zig");

// Field type aliases. Both are 8-byte, 8-aligned pointers on our 64-bit
// targets; `CStr` documents a NUL-terminated `char*` a reader may dereference,
// `Ptr` documents an opaque `T*` / `T**` array pointer.
pub const CStr = ?[*:0]const u8;
pub const Ptr = ?*anyopaque;

// ── The 8 canonical wire structs (mirror GSA.ABI.Layout) ─────────────────────

/// ServerHandle — 16 bytes, 8-aligned.
pub const ServerHandle = extern struct {
    rawPtr: i32,
    serverId: CStr,
};

/// ProbeResult — 64 bytes, 8-aligned.
pub const ProbeResult = extern struct {
    gameId: CStr,
    version: CStr,
    protocol: i32,
    fingerprint: CStr,
    configPaths: Ptr, // char**
    pathCount: u32,
    host: CStr,
    port: u32,
};

/// ConfigField — 64 bytes, 8-aligned.
pub const ConfigField = extern struct {
    key: CStr,
    value: CStr,
    fieldType: CStr,
    label: CStr,
    defaultVal: CStr,
    rangeMin: i32,
    rangeMax: i32,
    hasMin: i32,
    hasMax: i32,
    isSecret: i32,
};

/// A2MLConfig — 48 bytes, 8-aligned.
pub const A2MLConfig = extern struct {
    serverId: CStr,
    gameId: CStr,
    format: i32,
    configPath: CStr,
    fields: Ptr, // ConfigField*
    fieldCount: u32,
};

/// GameProfile — 96 bytes, 8-aligned.
pub const GameProfile = extern struct {
    id: CStr,
    name: CStr,
    engine: CStr,
    ports: Ptr, // PortEntry*
    portCount: u32,
    protocol: i32,
    fingerprintPattern: CStr,
    configFormat: i32,
    configPath: CStr,
    fieldDefs: Ptr, // ConfigField*
    fieldDefCount: u32,
    actions: Ptr, // ActionEntry*
    actionCount: u32,
};

/// ServerOctad — 112 bytes, 8-aligned (VeriSimDB 8-modality record).
pub const ServerOctad = extern struct {
    graphData: CStr,
    vectorEmbedding: Ptr, // double*
    vectorLen: u32,
    tensorMetrics: Ptr, // double**
    tensorRows: u32,
    tensorCols: u32,
    semanticAnnotations: Ptr, // KVPair*
    annotationCount: u32,
    documentText: CStr,
    temporalVersion: u64,
    provenanceHash: CStr,
    hasSpatial: i32,
    spatialX: f64,
    spatialY: f64,
    spatialZ: f64,
};

/// Fingerprint — 32 bytes, 8-aligned.
pub const Fingerprint = extern struct {
    host: CStr,
    port: u32,
    protocol: i32,
    responseSignature: CStr,
    latencyMs: u32,
};

/// DriftReport — 48 bytes, 8-aligned.
pub const DriftReport = extern struct {
    serverId: CStr,
    status: i32,
    configDrift: f64,
    semanticDrift: f64,
    temporalConsistency: f64,
    overallScore: f64,
};

// ── Cross-check machinery ────────────────────────────────────────────────────

const Pair = struct { T: type, spec: expected.StructExpect };

/// Every wire struct paired with its proven Idris expectation.
pub const pairs = [_]Pair{
    .{ .T = ServerHandle, .spec = expected.ServerHandle },
    .{ .T = ProbeResult, .spec = expected.ProbeResult },
    .{ .T = ConfigField, .spec = expected.ConfigField },
    .{ .T = A2MLConfig, .spec = expected.A2MLConfig },
    .{ .T = GameProfile, .spec = expected.GameProfile },
    .{ .T = ServerOctad, .spec = expected.ServerOctad },
    .{ .T = Fingerprint, .spec = expected.Fingerprint },
    .{ .T = DriftReport, .spec = expected.DriftReport },
};

/// Compile-time assertion that the Zig layout of `T` matches the proven Idris
/// layout `spec`, field by field. Any mismatch is a hard `@compileError`.
fn assertLayout(comptime T: type, comptime spec: expected.StructExpect) void {
    if (@sizeOf(T) != spec.total_size)
        @compileError(spec.name ++ ": @sizeOf disagrees with Layout.idr");
    if (@alignOf(T) != spec.struct_align)
        @compileError(spec.name ++ ": @alignOf disagrees with Layout.idr");
    inline for (spec.fields) |f| {
        if (@offsetOf(T, f.name) != f.offset)
            @compileError(spec.name ++ "." ++ f.name ++ ": @offsetOf disagrees with Layout.idr");
        const FieldT = @FieldType(T, f.name);
        if (@sizeOf(FieldT) != f.size)
            @compileError(spec.name ++ "." ++ f.name ++ ": field @sizeOf disagrees with Layout.idr");
        if (@alignOf(FieldT) != f.alignment)
            @compileError(spec.name ++ "." ++ f.name ++ ": field @alignOf disagrees with Layout.idr");
    }
}

// Enforced on every build that touches this module (imported by main.zig).
comptime {
    for (pairs) |p| assertLayout(p.T, p.spec);
}

// ── Tests (surface the same guarantee through `zig build test`) ──────────────

test "extern struct layout matches machine-checked Layout.idr" {
    inline for (pairs) |p| {
        try std.testing.expectEqual(@as(u32, @sizeOf(p.T)), p.spec.total_size);
        try std.testing.expectEqual(@as(u32, @alignOf(p.T)), p.spec.struct_align);
        inline for (p.spec.fields) |f| {
            try std.testing.expectEqual(@as(u32, @offsetOf(p.T, f.name)), f.offset);
            const FieldT = @FieldType(p.T, f.name);
            try std.testing.expectEqual(@as(u32, @sizeOf(FieldT)), f.size);
            try std.testing.expectEqual(@as(u32, @alignOf(FieldT)), f.alignment);
        }
    }
}

test "all eight ABI structs are covered" {
    try std.testing.expectEqual(@as(usize, 8), pairs.len);
    try std.testing.expectEqual(@as(usize, 8), expected.all.len);
}

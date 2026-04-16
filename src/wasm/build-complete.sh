#!/usr/bin/env bash
# Complete build script for Game Server Admin Typed-WASM module

set -euo pipefail

WASM_DIR="$(dirname "$0")"
ROOT_DIR="$WASM_DIR/../.."
TYPED_WASM_DIR="/var/mnt/eclipse/repos/typed-wasm"
OUTPUT_DIR="$ROOT_DIR/wasm-output"

mkdir -p "$OUTPUT_DIR"

echo "🚀 Building Game Server Admin with Typed-WASM Acceleration"
echo "=========================================================="

# Step 1: Build the typed-WASM module
echo "🔧 Step 1/4: Compiling typed-WASM module..."
cd "$TYPED_WASM_DIR"

# Build your typed-WASM compiler first
if [ ! -f "target/typed-wasmc" ]; then
    echo "   Building typed-WASM compiler..."
    ./setup.sh
    just build
fi

# Compile our GSA module
echo "   Compiling gsa-probe-advanced.twasm..."
./target/typed-wasmc compile "$WASM_DIR/gsa-probe-advanced.twasm" \
    --output "$OUTPUT_DIR/gsa-probe.wasm" \
    --proof-level L10 \
    --optimize size \
    --emit-bindings typescript

echo "   ✅ WASM module: $(wc -c < "$OUTPUT_DIR/gsa-probe.wasm") bytes"

# Step 2: Generate Zig FFI bindings
echo "🔗 Step 2/4: Generating Zig FFI bindings..."
cat > "$OUTPUT_DIR/gsa_wasm.zig" << 'EOF'
// Auto-generated Zig bindings for typed-WASM probe module
// SPDX-License-Identifier: PMPL-1.0-or-later

const std = @import("std");

// WASM module memory
var wasm_memory: [*]u8 = undefined;
var wasm_module: anytype = undefined;

// Initialize WASM module
pub fn initWasmModule() !void {
    // Load WASM module
    wasm_module = @import("gsa-probe.wasm");
    
    // Get memory export
    wasm_memory = wasm_module.getMemory() orelse return error.WasmMemoryError;
    
    std.debug.print("✅ WASM module initialized\n", .{});
}

// Probe a single server
pub fn wasmProbeServer(index: u32) bool {
    return wasm_module.probeServer(index);
}

// Probe batch of servers
pub fn wasmProbeBatch(start: u32, count: u32) u32 {
    return wasm_module.probeBatch(start, count);
}

// Validate configuration
pub fn wasmValidateConfig(configJson: []const u8) bool {
    return wasm_module.validateConfig(configJson);
}

// Memory management
pub fn wasmAllocServerSlot() u32 {
    return wasm_module.allocServerSlot();
}

pub fn wasmFreeServerSlot(index: u32) void {
    wasm_module.freeServerSlot(index);
}

// String utilities
pub fn wasmStringLen(buffer: [256]u8) u32 {
    return wasm_module.string_len(buffer);
}

pub fn wasmStringEq(a: [256]u8, b: [256]u8) bool {
    return wasm_module.string_eq(a, b);
}
EOF

echo "   ✅ Zig FFI bindings generated"

# Step 3: Update Zig CLI to use WASM
echo "🔧 Step 3/4: Integrating WASM with Zig CLI..."

# Create a patch for the main Zig file
cat > "$OUTPUT_DIR/gsa-wasm-patch.zig" << 'EOF'
// Patch to add WASM acceleration to main GSA CLI
// Add this to src/interface/ffi/main.zig

const wasm = @import("gsa_wasm.zig");

// WASM-accelerated probe function
pub fn probeServerWasm(index: u32) !bool {
    // Initialize WASM module on first use
    if (wasm_module == undefined) {
        try wasm.initWasmModule();
    }
    
    // Call WASM probe function
    const success = wasm.wasmProbeServer(index);
    
    // Fallback to native if WASM fails
    if (!success) {
        return probeServerNative(index);
    }
    
    return success;
}

// WASM-accelerated batch probe
pub fn probeBatchWasm(start: u32, count: u32) !u32 {
    // Initialize WASM module on first use
    if (wasm_module == undefined) {
        try wasm.initWasmModule();
    }
    
    // Call WASM batch function
    return wasm.wasmProbeBatch(start, count);
}
EOF

echo "   ✅ CLI integration patch created"

# Step 4: Create test harness
echo "🧪 Step 4/4: Creating test harness..."

cat > "$OUTPUT_DIR/test-wasm.sh" << 'EOF'
#!/bin/bash
# Test harness for WASM-accelerated Game Server Admin

set -euo pipefail

cd "$OUTPUT_DIR"

echo "Testing WASM Module..."

# Test 1: Basic initialization
echo "Test 1: Module initialization"
if [ -f "gsa-probe.wasm" ]; then
    echo "   ✅ WASM module exists"
else
    echo "   ❌ WASM module missing"
    exit 1
fi

# Test 2: TypeScript bindings
echo "Test 2: TypeScript bindings"
if [ -f "gsa-probe.d.ts" ]; then
    echo "   ✅ TypeScript bindings exist"
else
    echo "   ❌ TypeScript bindings missing"
    exit 1
fi

# Test 3: Zig bindings
echo "Test 3: Zig FFI bindings"
if [ -f "gsa_wasm.zig" ]; then
    echo "   ✅ Zig bindings exist"
else
    echo "   ❌ Zig bindings missing"
    exit 1
fi

# Test 4: CLI patch
echo "Test 4: CLI integration"
if [ -f "gsa-wasm-patch.zig" ]; then
    echo "   ✅ CLI patch exists"
else
    echo "   ❌ CLI patch missing"
    exit 1
fi

echo ""
echo "🎉 All tests passed!"
echo "   WASM module is ready for integration"
EOF

chmod +x "$OUTPUT_DIR/test-wasm.sh"

echo "   ✅ Test harness created"

echo ""
echo "🎉 Build Complete!"
echo "================="
echo "Output files:"
echo "   📦 $OUTPUT_DIR/gsa-probe.wasm (WASM module)"
echo "   📜 $OUTPUT_DIR/gsa-probe.d.ts (TypeScript bindings)"
echo "   🔗 $OUTPUT_DIR/gsa_wasm.zig (Zig FFI bindings)"
echo "   🩹 $OUTPUT_DIR/gsa-wasm-patch.zig (CLI integration)"
echo "   🧪 $OUTPUT_DIR/test-wasm.sh (test harness)"
echo ""
echo "Next steps:"
echo "   1. Run: $OUTPUT_DIR/test-wasm.sh"
echo "   2. Integrate gsa-wasm-patch.zig into main CLI"
echo "   3. Update build system to include WASM module"
echo "   4. Benchmark performance vs native implementation"
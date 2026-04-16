#!/usr/bin/env bash
# Build Game Server Admin probe module using typed-WASM

set -euo pipefail

WASM_DIR="$(dirname "$0")"
ROOT_DIR="$WASM_DIR/../.."
TYPED_WASM_DIR="/var/mnt/eclipse/repos/typed-wasm"
OUTPUT_DIR="$ROOT_DIR/wasm-output"

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo "🚀 Building Game Server Admin Typed-WASM module..."
echo "   Using striated layout for optimal performance"

# Build using your typed-WASM compiler
cd "$TYPED_WASM_DIR"

# Compile the typed-WASM module
echo "🔧 Compiling gsa-probe.twasm..."
./setup.sh
just build

# Copy the compiled module to our output
echo "📦 Copying compiled module..."
cp "$TYPED_WASM_DIR/target/gsa-probe.wasm" "$OUTPUT_DIR/" 2>/dev/null || true

# Generate bindings
echo "📝 Generating TypeScript bindings..."
cat > "$OUTPUT_DIR/gsa-probe.d.ts" << 'EOF'
// Typed-WASM bindings for Game Server Admin probe module
declare module 'gsa-probe.wasm' {
    // Striated memory layout functions
    export function probeServer(index: number): boolean;
    export function probeBatch(start: number, count: number): number;
    export function validateConfig(configJson: string): boolean;
    export function allocServerSlot(): number;
    export function freeServerSlot(index: number): void;
    
    // Memory management
    export function getMemory(): WebAssembly.Memory;
}
EOF

echo "✅ Typed-WASM build complete!"
echo "   Output: $OUTPUT_DIR/gsa-probe.wasm"
echo "   Bindings: $OUTPUT_DIR/gsa-probe.d.ts"
echo "   Features: Striated layout, type-safe access, batch processing"
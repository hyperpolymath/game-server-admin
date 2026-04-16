#!/usr/bin/env bash
# Build Typed-WASM modules for Game Server Admin

set -euo pipefail

WASM_DIR="$(dirname "$0")"
ROOT_DIR="$WASM_DIR/../.."
OUTPUT_DIR="$ROOT_DIR/wasm-output"

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo "🚀 Building Typed-WASM modules..."

# Build probe module with interface types
echo "🔧 Building probe.wasm..."
zig build-lib \
    -target wasm32-freestanding \
    -dynamic \
    "$WASM_DIR/probe.zig" \
    -O ReleaseSmall \
    -o "$OUTPUT_DIR/probe.wasm"

echo "✅ probe.wasm: $(wc -c < "$OUTPUT_DIR/probe.wasm") bytes"

# Generate TypeScript bindings for typed-WASM
echo "📝 Generating TypeScript bindings..."
cat > "$OUTPUT_DIR/probe.d.ts" << 'EOF'
// Typed-WASM bindings for probe module
declare module 'probe.wasm' {
    export function probeServer(host: string, port: number): boolean;
    export function validateConfig(configJson: string): boolean;
    export function alloc(bytes: number): number;
    export function free(ptr: number): void;
}
EOF

echo "✅ TypeScript bindings generated"

echo "🎉 Typed-WASM build complete!"
echo "   Output: $OUTPUT_DIR/probe.wasm"
echo "   Bindings: $OUTPUT_DIR/probe.d.ts"
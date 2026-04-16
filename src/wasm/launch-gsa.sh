#!/usr/bin/env bash
# Robust Game Server Admin Launcher with Error Handling

set -euo pipefail

# Configuration
GSA_DIR="/var/mnt/eclipse/repos/game-server-admin"
WASM_DIR="$GSA_DIR/src/wasm"
CLI_BIN="$GSA_DIR/src/interface/ffi/zig-out/bin/gsa"
WASM_OUTPUT="$WASM_DIR/wasm-output"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Error handling function
error_exit() {
    echo "${RED}❌ ERROR: $1${NC}" >&2
    echo "${YELLOW}Try these fixes:${NC}"
    echo "  1. Start VeriSimDB: VERISIM_PORT=8090 nohup verisim-api > /tmp/verisimdb.log &"
    echo "  2. Initialize config: cd $GSA_DIR/src/interface/ffi && ./gsa config init"
    echo "  3. Check logs: tail -20 /tmp/game-server-admin.log"
    echo "  4. Run with debug: ./launch-gsa.sh --debug"
    exit 1
}

# Check VeriSimDB
echo "🔍 Checking VeriSimDB..."
if ! curl -sf http://localhost:8090/health >/dev/null 2>&1; then
    echo "${YELLOW}⚠️  VeriSimDB not running. Starting it now...${NC}"
    cd /var/mnt/eclipse/repos/nextgen-databases/verisimdb
    VERISIM_PORT=8090 nohup ./target/release/verisim-api > /tmp/verisimdb.log 2>&1 &
    sleep 2
    
    if ! curl -sf http://localhost:8090/health >/dev/null 2>&1; then
        error_exit "Failed to start VeriSimDB. Check /tmp/verisimdb.log"
    fi
    echo "${GREEN}✅ VeriSimDB started successfully${NC}"
fi

# Check configuration
echo "🔍 Checking configuration..."
cd "$GSA_DIR/src/interface/ffi/zig-out/bin"
CONFIG_DIR="$GSA_DIR/src/interface/ffi"
if [ ! -f "$CONFIG_DIR/user-config.ncl" ]; then
    echo "${YELLOW}⚠️  Configuration missing. Initializing...${NC}"
    if [ ! -f "$CONFIG_DIR/user-config.ncl.template" ]; then
        cp "$GSA_DIR/user-config.ncl.template" "$CONFIG_DIR/"
    fi
    cd "$CONFIG_DIR"
    if ./../zig-out/bin/gsa config init 2>/dev/null; then
        echo "${GREEN}✅ Configuration initialized${NC}"
    else
        error_exit "Failed to initialize configuration"
    fi
    cd "$GSA_DIR/src/interface/ffi/zig-out/bin"
fi

# Check if using WASM acceleration
USE_WASM=false
if [ "$1" = "--wasm" ] || [ -f "$WASM_OUTPUT/gsa-probe.wasm" ]; then
    USE_WASM=true
    echo "🔍 Initializing WASM module..."
    # WASM initialization would go here
fi

# Launch with proper error handling
echo "🚀 Launching Game Server Admin..."
cd "$GSA_DIR/src/interface/ffi/zig-out/bin"
if [ "$USE_WASM" = true ]; then
    echo "   (WASM acceleration enabled)"
    # WASM launch command would go here
    ./gsa "$@"
else
    ./gsa "$@"
fi

echo ""
echo "${GREEN}✅ Game Server Admin is running!${NC}"
echo "   Press Ctrl+C to exit"

# For desktop launcher, keep terminal open
if [ -t 1 ]; then
    # Interactive terminal - let the CLI run and keep open
    echo ""
    echo "${YELLOW}Tip: Use 'gsa help' to see all commands${NC}"
    echo "${YELLOW}Press Ctrl+C to exit${NC}"
    # Start interactive shell if no command given
    if [ $# -eq 0 ]; then
        while true; do
            echo -n "gsa> "
            read -r cmd
            if [ "$cmd" = "exit" ] || [ "$cmd" = "quit" ]; then
                break
            fi
            ./gsa $cmd
        done
    fi
else
    # Non-interactive - add delay to see output
    sleep 3
fi
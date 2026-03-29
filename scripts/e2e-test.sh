#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# e2e-test.sh — End-to-end integration test for Game Server Admin
#
# Tests the full pipeline:
#   1. Verify VeriSimDB is running on port 8090
#   2. Create a test octad via REST API
#   3. Query it back via VQL
#   4. Probe a real game server (if reachable)
#   5. Store probe results as octad
#   6. Verify drift detection responds
#   7. Clean up test data
#
# Usage:
#   ./scripts/e2e-test.sh                        # Auto-detect servers
#   ./scripts/e2e-test.sh mc.example.com:25565   # Probe specific server
#
# Prerequisites:
#   - gsa-verisimdb container running on port 8090
#   - curl installed

set -euo pipefail

VERISIMDB_URL="${GSA_VERISIMDB_URL:-http://[::1]:8090}"
TARGET_SERVER="${1:-}"
PASSED=0
FAILED=0
TOTAL=0

# ── Helpers ──────────────────────────────────────────────────────────

pass() { ((PASSED++)); ((TOTAL++)); echo "  PASS: $1"; }
fail() { ((FAILED++)); ((TOTAL++)); echo "  FAIL: $1"; }

check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

check_output() {
    local desc="$1"
    local expected="$2"
    shift 2
    local output
    output=$("$@" 2>/dev/null) || { fail "$desc (command failed)"; return; }
    if echo "$output" | grep -q "$expected"; then
        pass "$desc"
    else
        fail "$desc (expected '$expected' in output)"
    fi
}

echo "═══════════════════════════════════════════════════════════════"
echo "  Game Server Admin — End-to-End Integration Test"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "VeriSimDB URL: $VERISIMDB_URL"
echo "Target server: ${TARGET_SERVER:-auto-detect}"
echo ""

# ── Step 1: VeriSimDB Health ─────────────────────────────────────────

echo "Step 1: VeriSimDB health check"
check "VeriSimDB is reachable" curl -sf "${VERISIMDB_URL}/health"
check_output "VeriSimDB returns ok" "ok" curl -sf "${VERISIMDB_URL}/health"

if [[ $FAILED -gt 0 ]]; then
    echo ""
    echo "ABORT: VeriSimDB not running. Start it with:"
    echo "  systemctl --user start gsa-verisimdb"
    echo "  # or: podman run -d --name gsa-verisimdb -p [::1]:8090:8090 gsa-verisimdb:latest"
    exit 1
fi

# ── Step 2: Create Test Octad ────────────────────────────────────────

echo ""
echo "Step 2: Create test octad"

TEST_OCTAD=$(cat <<'JSON'
{
  "document": {
    "title": "e2e-test-server",
    "body": "Minecraft Java Edition test server for GSA e2e validation. Running version 1.21.4 with max-players=32 and difficulty=normal.",
    "fields": {"game_id": "minecraft-java", "test": "true"}
  },
  "semantic": {
    "types": ["https://gsa.hyperpolymath.dev/types/GameServer", "https://gsa.hyperpolymath.dev/types/GameServer/Minecraft"],
    "properties": {}
  },
  "graph": {
    "relationships": [["has-profile", "profile:minecraft-java"], ["in-cluster", "cluster:e2e-test"]]
  },
  "vector": {
    "embedding": [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
    "model": "test-8dim"
  },
  "provenance": {
    "event_type": "created",
    "actor": "gsa-e2e-test",
    "description": "Created by e2e integration test"
  },
  "spatial": {
    "latitude": 51.5074,
    "longitude": -0.1278,
    "altitude": 0.0
  },
  "metadata": {
    "game_id": "minecraft-java",
    "host": "127.0.0.1",
    "port": "25565",
    "protocol": "minecraft-query",
    "status": "test"
  }
}
JSON
)

CREATE_RESPONSE=$(curl -sf -X POST "${VERISIMDB_URL}/api/v1/octads" \
    -H "Content-Type: application/json" \
    -d "$TEST_OCTAD" 2>/dev/null) || { fail "Create octad (HTTP error)"; CREATE_RESPONSE=""; }

if [[ -n "$CREATE_RESPONSE" ]]; then
    OCTAD_ID=$(echo "$CREATE_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [[ -n "$OCTAD_ID" ]]; then
        pass "Create octad (id=$OCTAD_ID)"
    else
        # Try alternate JSON field names
        OCTAD_ID=$(echo "$CREATE_RESPONSE" | grep -o '"entity_id":"[^"]*"' | head -1 | cut -d'"' -f4)
        if [[ -n "$OCTAD_ID" ]]; then
            pass "Create octad (entity_id=$OCTAD_ID)"
        else
            fail "Create octad (no ID in response: ${CREATE_RESPONSE:0:200})"
            OCTAD_ID="e2e-test-fallback"
        fi
    fi
else
    OCTAD_ID="e2e-test-fallback"
fi

# ── Step 3: Query Octad Back ─────────────────────────────────────────

echo ""
echo "Step 3: Query octad back"

if [[ "$OCTAD_ID" != "e2e-test-fallback" ]]; then
    check_output "GET octad by ID" "e2e-test-server" \
        curl -sf "${VERISIMDB_URL}/api/v1/octads/${OCTAD_ID}"
fi

check_output "Text search for 'minecraft'" "minecraft" \
    curl -sf "${VERISIMDB_URL}/api/v1/search/text?q=minecraft&limit=5"

# ── Step 4: Drift Detection ──────────────────────────────────────────

echo ""
echo "Step 4: Drift detection"

check "Drift status endpoint responds" curl -sf "${VERISIMDB_URL}/api/v1/drift/status"

if [[ "$OCTAD_ID" != "e2e-test-fallback" ]]; then
    # Entity-level drift check
    DRIFT_RESPONSE=$(curl -sf "${VERISIMDB_URL}/api/v1/drift/entity/${OCTAD_ID}" 2>/dev/null) || true
    if [[ -n "$DRIFT_RESPONSE" ]]; then
        pass "Entity drift check (id=$OCTAD_ID)"
    else
        fail "Entity drift check"
    fi
fi

# ── Step 5: Live Server Probe (Optional) ─────────────────────────────

echo ""
echo "Step 5: Live server probe"

if [[ -z "$TARGET_SERVER" ]]; then
    # Try common public Minecraft servers (best-effort)
    PROBE_TARGETS=(
        "127.0.0.1:25565"
        "127.0.0.1:19132"
        "127.0.0.1:2456"
    )
    for target in "${PROBE_TARGETS[@]}"; do
        host="${target%:*}"
        port="${target#*:}"
        if timeout 2 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
            TARGET_SERVER="$target"
            echo "  Found reachable server: $TARGET_SERVER"
            break
        fi
    done
fi

if [[ -n "$TARGET_SERVER" ]]; then
    host="${TARGET_SERVER%:*}"
    port="${TARGET_SERVER#*:}"
    echo "  Probing $TARGET_SERVER..."

    # TCP connectivity check
    if timeout 3 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
        pass "TCP connect to $TARGET_SERVER"

        # Store probe result as octad
        PROBE_OCTAD=$(cat <<PROBEJSON
{
  "document": {
    "title": "probe-${host}-${port}",
    "body": "Live probe result for ${host}:${port} from GSA e2e test",
    "fields": {"probe": "true", "host": "$host", "port": "$port"}
  },
  "metadata": {
    "game_id": "unknown",
    "host": "$host",
    "port": "$port",
    "protocol": "tcp-connect",
    "status": "reachable"
  },
  "provenance": {
    "event_type": "probed",
    "actor": "gsa-e2e-test",
    "description": "Live TCP probe from e2e test"
  }
}
PROBEJSON
)
        PROBE_RESPONSE=$(curl -sf -X POST "${VERISIMDB_URL}/api/v1/octads" \
            -H "Content-Type: application/json" \
            -d "$PROBE_OCTAD" 2>/dev/null) || true

        if [[ -n "$PROBE_RESPONSE" ]]; then
            pass "Store probe result in VeriSimDB"
        else
            fail "Store probe result in VeriSimDB"
        fi
    else
        fail "TCP connect to $TARGET_SERVER (unreachable)"
    fi
else
    echo "  No reachable game servers found (skipping live probe)"
    echo "  To test with a specific server: $0 host:port"
fi

# ── Step 6: Cleanup ──────────────────────────────────────────────────

echo ""
echo "Step 6: Cleanup"

if [[ "$OCTAD_ID" != "e2e-test-fallback" ]]; then
    check "Delete test octad" curl -sf -X DELETE "${VERISIMDB_URL}/api/v1/octads/${OCTAD_ID}"
fi

# ── Summary ──────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Results: $PASSED passed, $FAILED failed, $TOTAL total"
echo "═══════════════════════════════════════════════════════════════"

if [[ $FAILED -gt 0 ]]; then
    exit 1
else
    echo "  All tests passed!"
    exit 0
fi

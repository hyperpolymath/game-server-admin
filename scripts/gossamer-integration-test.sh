#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# gossamer-integration-test.sh — Verify the Gossamer + libgsa.so integration chain
#
# Tests that all components of the full GUI pipeline exist and are compatible:
#   1. Ephapax compiler binary exists and runs
#   2. libgossamer.so exists and exports expected symbols
#   3. libgsa.so exists and exports expected symbols
#   4. Both libraries are ABI-compatible (same C calling convention)
#   5. Shell.eph and panel HTML files exist
#
# NOTE: Full Ephapax→Gossamer→libgsa execution requires `let!`, `__ffi()`,
# `module`, and `import` syntax support in the Ephapax parser, which is
# tracked in nextgen-languages/ephapax. This test validates the pre-conditions.
#
# Usage:
#   ./scripts/gossamer-integration-test.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EPHAPAX="${EPHAPAX:-/var/mnt/eclipse/repos/nextgen-languages/ephapax/target/debug/ephapax}"
LIBGOSSAMER="${LIBGOSSAMER:-/var/mnt/eclipse/repos/gossamer/src/interface/ffi/zig-out/lib/libgossamer.so}"
LIBGSA="${LIBGSA:-${REPO_DIR}/src/interface/ffi/zig-out/lib/libgsa.so}"

PASSED=0
FAILED=0
TOTAL=0

pass() { PASSED=$((PASSED + 1)); TOTAL=$((TOTAL + 1)); echo "  PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); TOTAL=$((TOTAL + 1)); echo "  FAIL: $1"; }

echo "═══════════════════════════════════════════════════════════════"
echo "  GSA Gossamer Integration Chain Test"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ── 1. Ephapax compiler ──────────────────────────────────────────────

echo "Step 1: Ephapax compiler"

if [[ -x "$EPHAPAX" ]]; then
    pass "Ephapax binary exists ($EPHAPAX)"
    if "$EPHAPAX" --version >/dev/null 2>&1; then
        version=$("$EPHAPAX" --version 2>&1 || true)
        pass "Ephapax runs (${version})"
    else
        fail "Ephapax won't execute (rebuild with: cargo build -p ephapax-cli)"
    fi
else
    fail "Ephapax binary not found at $EPHAPAX"
    echo "  Build with: cd nextgen-languages/ephapax && cargo build -p ephapax-cli"
fi

# ── 2. libgossamer.so ───────────────────────────────────────────────

echo ""
echo "Step 2: libgossamer.so"

if [[ -f "$LIBGOSSAMER" ]]; then
    pass "libgossamer.so exists ($LIBGOSSAMER)"

    # Check key exported symbols
    GOSS_SYMS=$(nm -D "$LIBGOSSAMER" 2>/dev/null || true)
    for sym in gossamer_create gossamer_run gossamer_load_html gossamer_channel_open gossamer_channel_bind; do
        if echo "$GOSS_SYMS" | grep -qF "$sym"; then
            pass "Symbol: $sym"
        else
            fail "Missing symbol: $sym"
        fi
    done
else
    fail "libgossamer.so not found at $LIBGOSSAMER"
    echo "  Build with: cd gossamer/src/interface/ffi && zig build"
fi

# ── 3. libgsa.so ────────────────────────────────────────────────────

echo ""
echo "Step 3: libgsa.so"

if [[ -f "$LIBGSA" ]]; then
    pass "libgsa.so exists ($LIBGSA)"

    GSA_SYMS=$(nm -D "$LIBGSA" 2>/dev/null || true)
    for sym in gossamer_gsa_init gossamer_gsa_shutdown gossamer_gsa_probe gossamer_gsa_extract_config gossamer_gsa_verisimdb_store gossamer_gsa_version; do
        if echo "$GSA_SYMS" | grep -qF "$sym"; then
            pass "Symbol: $sym"
        else
            fail "Missing symbol: $sym"
        fi
    done
else
    fail "libgsa.so not found at $LIBGSA"
    echo "  Build with: cd game-server-admin/src/interface/ffi && zig build"
fi

# ── 4. ABI compatibility ────────────────────────────────────────────

echo ""
echo "Step 4: ABI compatibility"

if [[ -f "$LIBGOSSAMER" ]] && [[ -f "$LIBGSA" ]]; then
    goss_arch=$(file "$LIBGOSSAMER" | grep -o 'x86-64\|aarch64\|ARM' || echo "unknown")
    gsa_arch=$(file "$LIBGSA" | grep -o 'x86-64\|aarch64\|ARM' || echo "unknown")

    if [[ "$goss_arch" == "$gsa_arch" ]]; then
        pass "Architecture match: ${goss_arch}"
    else
        fail "Architecture mismatch: gossamer=${goss_arch} gsa=${gsa_arch}"
    fi

    # Check no symbol conflicts
    goss_syms=$(nm -D "$LIBGOSSAMER" 2>/dev/null | grep " T " | awk '{print $3}' | sort)
    gsa_syms=$(nm -D "$LIBGSA" 2>/dev/null | grep " T " | awk '{print $3}' | sort)
    conflicts=$(comm -12 <(echo "$goss_syms") <(echo "$gsa_syms") | wc -l)

    if [[ "$conflicts" -eq 0 ]]; then
        pass "No symbol conflicts between libraries"
    else
        fail "$conflicts conflicting symbols"
    fi
fi

# ── 5. Source files ──────────────────────────────────────────────────

echo ""
echo "Step 5: GSA source files"

for f in src/core/Shell.eph src/core/Bridge.eph src/core/Types.eph src/core/Capabilities.eph src/gui/host.html; do
    if [[ -f "$REPO_DIR/$f" ]]; then
        pass "$f exists"
    else
        fail "$f missing"
    fi
done

# Check all 7 GUI panels exist
panel_count=$(ls -d "$REPO_DIR"/src/gui/panels/*/ 2>/dev/null | wc -l)
if [[ "$panel_count" -ge 7 ]]; then
    pass "$panel_count GUI panels found"
else
    fail "Expected 7+ panels, found $panel_count"
fi

# ── 6. Parser readiness ─────────────────────────────────────────────

echo ""
echo "Step 6: Ephapax parser feature readiness"

# Check basic let binding with semicolon sequencing (heredoc avoids bash escaping)
cat > /tmp/ephapax-test-basic.eph << 'EPHTEST'
fn main(): I32 = let x : I32 = 42 in x
EPHTEST
if "$EPHAPAX" check /tmp/ephapax-test-basic.eph >/dev/null 2>&1; then
    pass "Basic let binding works"
else
    fail "Basic let binding fails"
fi

# Check linear let! binding (use heredoc to avoid bash ! escaping)
cat > /tmp/ephapax-test-linear.eph << 'EPHTEST'
fn main(): I32 = let! x : I32 = 42 in x
EPHTEST
if "$EPHAPAX" check /tmp/ephapax-test-linear.eph >/dev/null 2>&1; then
    pass "Linear let! binding works"
else
    fail "Linear let! binding not yet supported (parser gap)"
    echo "  → Tracked in: nextgen-languages/ephapax"
    echo "  → Shell.eph requires: let!, __ffi(), module, import"
fi

rm -f /tmp/ephapax-test-basic.eph /tmp/ephapax-test-linear.eph

# ── Summary ──────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Results: $PASSED passed, $FAILED failed, $TOTAL total"
echo "═══════════════════════════════════════════════════════════════"

if [[ $FAILED -gt 0 ]]; then
    echo ""
    echo "  Known gaps: Ephapax parser needs let!, __ffi(), module, import"
    echo "  All non-parser tests should pass (libraries, symbols, files)"
    exit 1
else
    echo "  All tests passed — ready for full GUI execution!"
    exit 0
fi

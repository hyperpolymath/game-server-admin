#!/usr/bin/env bash
# Panel E2E Test — validates all GSA GUI panels and assets
#
# Checks:
#   1. All 7 panel HTML files exist
#   2. All panel .eph files exist
#   3. Panel-clade A2ML manifests exist
#   4. Host HTML exists
#   5. FLI JS files exist
#
# Exit 0 if all pass, 1 if any fail.
#
# SPDX-License-Identifier: PMPL-1.0-or-later

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

check() {
    local desc="$1"
    local path="$2"
    if [ -f "$REPO_ROOT/$path" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc ($path not found)"
        FAIL=$((FAIL + 1))
    fi
}

check_dir() {
    local desc="$1"
    local pattern="$2"
    local count
    count=$(find "$REPO_ROOT/$pattern" -type f 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
        echo "  PASS: $desc ($count files)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (no files matching $pattern)"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== GSA Panel E2E Tests ==="
echo ""

echo "[Panel HTML files]"
for panel in server-browser nexus-setup config-editor server-actions live-logs health-dashboard config-history cross-search; do
    check "Panel: $panel" "src/gui/panels/$panel/panel.html"
done

echo ""
echo "[Panel Ephapax files]"
for panel in server-browser nexus-setup config-editor server-actions live-logs health-dashboard config-history cross-search; do
    check "Panel .eph: $panel" "src/gui/panels/$panel/$panel.eph"
done

echo ""
echo "[Host HTML]"
check "host.html" "src/gui/host.html"

echo ""
echo "[FLI JS files]"
for fli in fli-editable fli-gauge fli-terminal fli-tooltip fli-undo; do
    check "FLI: $fli" "src/gui/fli/$fli.js"
done

echo ""
echo "[Panel Clade A2ML manifests]"
check_dir "GSA base clades" "panel-clades/gsa*/*.a2ml"
check_dir "FLI clades" "panel-clades/fli*/*.a2ml"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0

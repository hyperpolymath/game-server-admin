#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# install-quadlets.sh — Install/remove GSA VeriSimDB Podman Quadlet units
#
# Usage:
#   ./scripts/install-quadlets.sh           # Install quadlets
#   ./scripts/install-quadlets.sh --remove  # Remove quadlets
#   ./scripts/install-quadlets.sh --status  # Check status
#
# Installs systemd user units via Podman Quadlets so VeriSimDB starts
# automatically on login and survives reboots.
#
# Prerequisites:
#   - Podman with Quadlet support (Podman 4.4+)
#   - gsa-verisimdb:latest container image built (see: just verisimdb-build)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

QUADLET_DIR="${HOME}/.config/containers/systemd"
MAIN_QUADLET="gsa-verisimdb.container"
BACKUP_QUADLET="gsa-verisimdb-backup.container"

# ── Helpers ──────────────────────────────────────────────────────────

info()  { echo "  INFO: $*"; }
ok()    { echo "  OK:   $*"; }
err()   { echo "  ERR:  $*" >&2; }

check_image() {
    if ! podman image exists "localhost/gsa-verisimdb:latest" 2>/dev/null; then
        err "Container image 'gsa-verisimdb:latest' not found."
        err "Build it first:  just verisimdb-build"
        return 1
    fi
    return 0
}

# ── Install ──────────────────────────────────────────────────────────

do_install() {
    echo "═══════════════════════════════════════════════════"
    echo "  Installing GSA VeriSimDB Quadlets"
    echo "═══════════════════════════════════════════════════"
    echo ""

    # Verify image exists
    if ! check_image; then
        echo ""
        echo "Aborting. Build the image first, then re-run this script."
        exit 1
    fi

    # Create quadlet directory
    mkdir -p "$QUADLET_DIR"
    info "Quadlet directory: $QUADLET_DIR"

    # Copy quadlet files
    cp "$PROJECT_DIR/container/verisimdb/$MAIN_QUADLET" "$QUADLET_DIR/"
    ok "Installed $MAIN_QUADLET"

    cp "$PROJECT_DIR/container/verisimdb-backup/$BACKUP_QUADLET" "$QUADLET_DIR/"
    ok "Installed $BACKUP_QUADLET"

    # Reload systemd
    systemctl --user daemon-reload
    ok "systemd user daemon reloaded"

    echo ""
    echo "Quadlets installed. Next steps:"
    echo "  systemctl --user start gsa-verisimdb          # Start main (port 8090)"
    echo "  systemctl --user start gsa-verisimdb-backup   # Start backup (port 8091)"
    echo "  systemctl --user enable gsa-verisimdb         # Auto-start on login"
    echo "  just verisimdb-status                         # Check health"
}

# ── Remove ───────────────────────────────────────────────────────────

do_remove() {
    echo "═══════════════════════════════════════════════════"
    echo "  Removing GSA VeriSimDB Quadlets"
    echo "═══════════════════════════════════════════════════"
    echo ""

    # Stop services
    systemctl --user stop gsa-verisimdb-backup 2>/dev/null && ok "Stopped gsa-verisimdb-backup" || info "gsa-verisimdb-backup not running"
    systemctl --user stop gsa-verisimdb 2>/dev/null && ok "Stopped gsa-verisimdb" || info "gsa-verisimdb not running"

    # Remove quadlet files
    rm -f "$QUADLET_DIR/$MAIN_QUADLET" && ok "Removed $MAIN_QUADLET" || info "$MAIN_QUADLET not found"
    rm -f "$QUADLET_DIR/$BACKUP_QUADLET" && ok "Removed $BACKUP_QUADLET" || info "$BACKUP_QUADLET not found"

    # Reload
    systemctl --user daemon-reload
    ok "systemd user daemon reloaded"

    echo ""
    echo "Quadlets removed. Data volumes preserved."
    echo "To also remove volumes:"
    echo "  podman volume rm gsa-verisimdb-data"
    echo "  podman volume rm gsa-verisimdb-backup-data"
}

# ── Status ───────────────────────────────────────────────────────────

do_status() {
    echo "═══════════════════════════════════════════════════"
    echo "  GSA VeriSimDB Status"
    echo "═══════════════════════════════════════════════════"
    echo ""

    # Quadlet files
    echo "Quadlet files:"
    [ -f "$QUADLET_DIR/$MAIN_QUADLET" ] && ok "$MAIN_QUADLET installed" || info "$MAIN_QUADLET not installed"
    [ -f "$QUADLET_DIR/$BACKUP_QUADLET" ] && ok "$BACKUP_QUADLET installed" || info "$BACKUP_QUADLET not installed"

    # Container image
    echo ""
    echo "Container image:"
    if podman image exists "localhost/gsa-verisimdb:latest" 2>/dev/null; then
        ok "gsa-verisimdb:latest exists"
    else
        info "gsa-verisimdb:latest NOT found — run: just verisimdb-build"
    fi

    # Services
    echo ""
    echo "Services:"
    systemctl --user status gsa-verisimdb --no-pager 2>/dev/null | head -3 || info "gsa-verisimdb not loaded"
    echo ""
    systemctl --user status gsa-verisimdb-backup --no-pager 2>/dev/null | head -3 || info "gsa-verisimdb-backup not loaded"

    # Health
    echo ""
    echo "Health:"
    curl -sf http://[::1]:8090/health 2>/dev/null && echo " ← main (8090)" || echo "  main (8090): unreachable"
    curl -sf http://[::1]:8091/health 2>/dev/null && echo " ← backup (8091)" || echo "  backup (8091): unreachable"

    # Volumes
    echo ""
    echo "Volumes:"
    podman volume inspect gsa-verisimdb-data --format '{{.Name}}: {{.Mountpoint}}' 2>/dev/null || info "gsa-verisimdb-data not created"
    podman volume inspect gsa-verisimdb-backup-data --format '{{.Name}}: {{.Mountpoint}}' 2>/dev/null || info "gsa-verisimdb-backup-data not created"
}

# ── Main ─────────────────────────────────────────────────────────────

case "${1:-install}" in
    --remove|-r|remove)
        do_remove
        ;;
    --status|-s|status)
        do_status
        ;;
    --help|-h|help)
        echo "Usage: $0 [--remove|--status|--help]"
        echo ""
        echo "  (default)   Install quadlet units"
        echo "  --remove    Stop services and remove quadlet units"
        echo "  --status    Show service status and health"
        ;;
    *)
        do_install
        ;;
esac

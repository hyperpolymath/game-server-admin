#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# CryoFall dedicated server entrypoint — managed by Game Server Admin (GSA)
#
# On first run this script installs the game via SteamCMD (AppID 1200170).
# Subsequent starts skip the install and launch the server directly.
# GSA manages the lifecycle externally via `podman start/stop/restart cryofall`.
#
# Environment variables (set by gsa-cryofall.container Quadlet):
#   CRYOFALL_INSTALL_DIR    Game binary location  (default: /opt/cryofall)
#   CRYOFALL_DATA_DIR       Config + saves        (default: /data/cryofall)
#   CRYOFALL_BACKUP_DIR     World archives        (default: /data/backups)
#   CRYOFALL_APPID          SteamCMD app ID       (default: 1200170)
#   STEAMCMD_BIN            SteamCMD path         (default: /usr/local/bin/steamcmd)

set -e

INSTALL_DIR="${CRYOFALL_INSTALL_DIR:-/opt/cryofall}"
DATA_DIR="${CRYOFALL_DATA_DIR:-/data/cryofall}"
BACKUP_DIR="${CRYOFALL_BACKUP_DIR:-/data/backups}"
APPID="${CRYOFALL_APPID:-1200170}"
STEAMCMD="${STEAMCMD_BIN:-/usr/local/bin/steamcmd}"
SERVER_BINARY="${INSTALL_DIR}/CryoFall_Server.x86_64"

# ---------------------------------------------------------------------------
# Signal handling — propagate SIGTERM/SIGINT to the server process
# ---------------------------------------------------------------------------
#
# Podman sends SIGTERM when `podman stop` is called.  We forward it to the
# CryoFall server so it can perform a graceful shutdown (save world state,
# notify connected players).

SERVER_PID=""

cleanup() {
    if [ -n "${SERVER_PID}" ]; then
        echo "[gsa-cryofall] Received shutdown signal — forwarding to CryoFall server (PID ${SERVER_PID})..."
        kill -TERM "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
        echo "[gsa-cryofall] Server stopped cleanly."
    fi
    exit 0
}

trap cleanup TERM INT

# ---------------------------------------------------------------------------
# First-run: install game via SteamCMD
# ---------------------------------------------------------------------------
#
# If the server binary is absent we download it.  This happens once per
# persistent volume.  The `update` action in profiles/cryofall.a2ml re-runs
# SteamCMD inside the running container to patch the game in-place.

if [ ! -f "${SERVER_BINARY}" ]; then
    echo "[gsa-cryofall] CryoFall server not found at ${INSTALL_DIR}."

    # CryoFall dedicated server (AppID 1200170) is a DLC of app 552990 and
    # requires a Steam account that owns the game — anonymous login fails.
    #
    # Two routes to stage the server files:
    #
    # Route A — Steam credentials in environment (set STEAM_USER + STEAM_PASS):
    if [ -n "${STEAM_USER:-}" ] && [ -n "${STEAM_PASS:-}" ]; then
        echo "[gsa-cryofall] Installing via SteamCMD (authenticated as ${STEAM_USER})..."
        "${STEAMCMD}" \
            +force_install_dir "${INSTALL_DIR}" \
            +login "${STEAM_USER}" "${STEAM_PASS}" \
            +app_update "${APPID}" validate \
            +quit
        echo "[gsa-cryofall] Game installation complete."

    # Route B — Files pre-staged into the volume by GSA provisioner:
    # Run on the host (or locally) then rsync to the cryofall-game-data volume:
    #   steamcmd +login <user> +force_install_dir ./cryofall-server \
    #            +app_update 1200170 validate +quit
    #   rsync -az ./cryofall-server/ root@209.42.26.106:/path/to/volume/
    # Then restart this container — it will skip this block.
    else
        echo "[gsa-cryofall] ERROR: CryoFall server files not found and no Steam credentials set."
        echo "[gsa-cryofall] Stage the server files first — see QUICKSTART-USER.adoc or:"
        echo "[gsa-cryofall]   GSA GUI → CryoFall → Actions → 'Stage Server Files'"
        echo "[gsa-cryofall]   Or set STEAM_USER + STEAM_PASS environment variables."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# First-run: deploy default Settings.xml
# ---------------------------------------------------------------------------
#
# If no config exists we copy the GSA-managed default.  After that, GSA's
# config editor panel owns the file — edits from the Gossamer GUI are written
# to ${DATA_DIR}/Settings.xml via the config_extract FFI layer.

if [ ! -f "${DATA_DIR}/Settings.xml" ]; then
    echo "[gsa-cryofall] No Settings.xml found — deploying default from GSA profile..."
    mkdir -p "${DATA_DIR}/Saves"
    cp /app/defaults/Settings.xml "${DATA_DIR}/Settings.xml"
    echo "[gsa-cryofall] Settings.xml written to ${DATA_DIR}/Settings.xml."
fi

# Ensure backup dir exists (used by profiles/cryofall.a2ml `backup` action)
mkdir -p "${BACKUP_DIR}"

# ---------------------------------------------------------------------------
# Launch the server
# ---------------------------------------------------------------------------

echo "[gsa-cryofall] ─────────────────────────────────────────────────────"
echo "[gsa-cryofall]  CryoFall Dedicated Server"
echo "[gsa-cryofall]  Install: ${INSTALL_DIR}"
echo "[gsa-cryofall]  Data:    ${DATA_DIR}"
echo "[gsa-cryofall]  Backups: ${BACKUP_DIR}"
echo "[gsa-cryofall]  Ports:   UDP 6000 (game), UDP 6001 (discovery)"
echo "[gsa-cryofall]  Managed: Game Server Admin (GSA) via Podman"
echo "[gsa-cryofall] ─────────────────────────────────────────────────────"

# The CryoFall server is launched in the background so our cleanup trap can
# catch signals from Podman and forward them correctly.
# -configPath tells the Automaton engine where to find Settings.xml.
"${SERVER_BINARY}" -configPath "${DATA_DIR}" &
SERVER_PID=$!

echo "[gsa-cryofall] Server started (PID ${SERVER_PID})."
wait "${SERVER_PID}"
EXIT_CODE=$?

echo "[gsa-cryofall] Server process exited with code ${EXIT_CODE}."
exit "${EXIT_CODE}"

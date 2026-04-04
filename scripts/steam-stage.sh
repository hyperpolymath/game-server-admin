#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# GSA Steam Staging Script
#
# Downloads a Steam game server to a local directory using SteamCMD, then
# syncs the files into the target Podman volume on the deployment host.
#
# Legal note:
#   SteamCMD is provided free by Valve for deploying dedicated servers.
#   This script logs in using the operator's own Steam account to download
#   a server they are entitled to run. No DRM is bypassed; game files are
#   not redistributed. Use is subject to the Steam Subscriber Agreement.
#
# Usage:
#   ./scripts/steam-stage.sh [options]
#
#   Options:
#     --app-id <id>          Steam AppID of server to download (default: 1200170 = CryoFall)
#     --install-dir <path>   Local directory for downloaded files (default: /tmp/gsa-stage-<appid>)
#     --target-volume <name> Podman volume to sync into     (default: cryofall-game-data)
#     --target-host <host>   Remote host for rsync          (default: local)
#     --target-path <path>   Volume mount path on host      (auto-detected via podman inspect)
#     --steamcmd-dir <path>  Where SteamCMD is installed    (default: auto-detect or install)
#     --no-sync              Download only, do not sync to volume
#     --dry-run              Print commands without executing
#
# Environment variables:
#   STEAM_USER             Steam account username (prompted if not set)
#   STEAM_PASS             Steam account password (prompted if not set, never echoed)
#   STEAM_GUARD_CODE       Steam Guard code if required (prompted interactively)
#   GSA_STEAM_AUTH_DIR     Persist Steam auth tokens here (default: ~/.config/gsa/steam-auth)
#                          Reuse across runs to avoid Steam Guard on every invocation.
#
# Examples:
#   # Download CryoFall server, sync to local volume:
#   STEAM_USER=myaccount ./scripts/steam-stage.sh
#
#   # Download and sync to Verpex VPS:
#   STEAM_USER=myaccount ./scripts/steam-stage.sh \
#     --target-host root@209.42.26.106 \
#     --target-volume cryofall-game-data
#
#   # Dry run to preview:
#   ./scripts/steam-stage.sh --dry-run

set -euo pipefail

# ─── Colour output ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

log_step()  { echo -e "${BLUE}[steam-stage]${RESET} ${BOLD}$*${RESET}"; }
log_ok()    { echo -e "${GREEN}  ✓${RESET} $*"; }
log_warn()  { echo -e "${YELLOW}  ⚠${RESET} $*"; }
log_error() { echo -e "${RED}  ✗${RESET} $*" >&2; }
log_info()  { echo -e "    $*"; }

# ─── Defaults ─────────────────────────────────────────────────────────────────
APP_ID="1200170"
INSTALL_DIR=""
TARGET_VOLUME="cryofall-game-data"
TARGET_HOST=""
TARGET_PATH=""
STEAMCMD_DIR="${HOME}/.local/share/steamcmd"
NO_SYNC=0
DRY_RUN=0

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-id)        APP_ID="$2";       shift 2 ;;
        --install-dir)   INSTALL_DIR="$2";  shift 2 ;;
        --target-volume) TARGET_VOLUME="$2"; shift 2 ;;
        --target-host)   TARGET_HOST="$2";  shift 2 ;;
        --target-path)   TARGET_PATH="$2";  shift 2 ;;
        --steamcmd-dir)  STEAMCMD_DIR="$2"; shift 2 ;;
        --no-sync)       NO_SYNC=1;         shift ;;
        --dry-run)       DRY_RUN=1;         shift ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

INSTALL_DIR="${INSTALL_DIR:-/tmp/gsa-stage-${APP_ID}}"
STEAM_AUTH_DIR="${GSA_STEAM_AUTH_DIR:-${HOME}/.config/gsa/steam-auth}"

# ─── Helper: run or dry-run ───────────────────────────────────────────────────
run() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  GSA Steam Stage — AppID ${APP_ID}${RESET}"
echo -e "${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""
log_info "Install dir:    ${INSTALL_DIR}"
log_info "Target volume:  ${TARGET_VOLUME}"
log_info "Target host:    ${TARGET_HOST:-local}"
log_info "SteamCMD dir:   ${STEAMCMD_DIR}"
log_info "Auth token dir: ${STEAM_AUTH_DIR}"
[[ "${DRY_RUN}" == "1" ]] && log_warn "DRY RUN — no changes will be made"
echo ""

# ─── Step 1: Install SteamCMD if needed ──────────────────────────────────────
log_step "1/5  SteamCMD"

STEAMCMD_BIN="${STEAMCMD_DIR}/steamcmd.sh"

if [[ ! -f "${STEAMCMD_BIN}" ]]; then
    log_info "SteamCMD not found at ${STEAMCMD_DIR} — installing..."
    run mkdir -p "${STEAMCMD_DIR}"
    run bash -c "curl -sqL 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz' | tar -xzC '${STEAMCMD_DIR}'"
    # Bootstrap: triggers download of linux32/steamcmd
    run bash -c "cd '${STEAMCMD_DIR}' && ./steamcmd.sh +quit 2>/dev/null || true"
    if [[ ! -f "${STEAMCMD_DIR}/linux32/steamcmd" ]]; then
        log_error "SteamCMD bootstrap failed — linux32/steamcmd not found"
        exit 1
    fi
    log_ok "SteamCMD installed at ${STEAMCMD_DIR}"
else
    log_ok "SteamCMD found at ${STEAMCMD_BIN}"
fi

# Wrapper that cd's into STEAMCMD_DIR before running steamcmd.sh,
# so relative paths (linux32/steamcmd) resolve correctly.
STEAMCMD_RUN() {
    (cd "${STEAMCMD_DIR}" && ./steamcmd.sh "$@")
}

# ─── Step 2: Gather Steam credentials ────────────────────────────────────────
log_step "2/5  Steam credentials"

# Prompt for username if not provided
if [[ -z "${STEAM_USER:-}" ]]; then
    echo -n "    Steam username: "
    read -r STEAM_USER
fi
if [[ -z "${STEAM_USER}" ]]; then
    log_error "Steam username is required"
    exit 1
fi
log_ok "Username: ${STEAM_USER}"

# Prompt for password securely (no echo)
if [[ -z "${STEAM_PASS:-}" ]]; then
    echo -n "    Steam password: "
    read -rs STEAM_PASS
    echo ""
fi
if [[ -z "${STEAM_PASS}" ]]; then
    log_error "Steam password is required"
    exit 1
fi
log_ok "Password: [set]"

# ─── Step 3: Set up auth token persistence ───────────────────────────────────
log_step "3/5  Auth token cache"

# SteamCMD stores session auth tokens in ~/.steam/.
# We redirect this to a dedicated GSA auth dir so tokens persist across
# invocations, avoiding Steam Guard prompts after the first successful login.
# Tokens are bound to the machine; treat this directory as sensitive.

run mkdir -p "${STEAM_AUTH_DIR}"
run chmod 700 "${STEAM_AUTH_DIR}"

# Set STEAMCMDDIR so SteamCMD writes its config there
export STEAMCMDDIR="${STEAM_AUTH_DIR}"
export HOME_OVERRIDE="${STEAM_AUTH_DIR}"  # some SteamCMD versions use HOME

TOKEN_FILE="${STEAM_AUTH_DIR}/config/config.vdf"
if [[ -f "${TOKEN_FILE}" ]]; then
    log_ok "Cached auth token found — Steam Guard not required"
else
    log_warn "No cached token — Steam Guard code may be required on first login"
    log_info "After entering the code once, tokens are cached for future runs."
fi

# ─── Step 4: Download game server files ──────────────────────────────────────
log_step "4/5  Download via SteamCMD (AppID ${APP_ID})"

run mkdir -p "${INSTALL_DIR}"

if [[ "${DRY_RUN}" == "1" ]]; then
    log_warn "Dry run — skipping SteamCMD download"
else
    log_info "Logging in as ${STEAM_USER} and downloading AppID ${APP_ID}..."
    log_info "This is ~3 GB — take a break ☕"
    echo ""

    # Run SteamCMD interactively so Steam Guard prompts are visible to the user.
    # We do NOT pipe stdin, so the user can type the Steam Guard code if prompted.
    set +e
    (cd "${STEAMCMD_DIR}" && \
        HOME="${STEAM_AUTH_DIR}" \
        ./steamcmd.sh \
            +force_install_dir "${INSTALL_DIR}" \
            +login "${STEAM_USER}" "${STEAM_PASS}" \
            +app_update "${APP_ID}" validate \
            +quit)
    STEAMCMD_EXIT=$?
    set -e

    if [[ "${STEAMCMD_EXIT}" -ne 0 ]]; then
        log_error "SteamCMD exited with code ${STEAMCMD_EXIT}"
        log_warn "Common causes:"
        log_info "  - Invalid Steam credentials (check username/password)"
        log_info "  - Steam Guard code rejected or timed out"
        log_info "  - Account does not own CryoFall (AppID 829590)"
        log_info "  - Network timeout (retry usually works)"
        log_warn "Re-run to retry. Cached token will skip Steam Guard on retry."
        exit 1
    fi

    # Verify the server binary exists
    SERVER_BIN="${INSTALL_DIR}/CryoFall_Server.x86_64"
    if [[ ! -f "${SERVER_BIN}" ]]; then
        log_error "Download appeared to succeed but CryoFall_Server.x86_64 not found"
        log_error "Expected: ${SERVER_BIN}"
        exit 1
    fi
    log_ok "Server binary: ${SERVER_BIN}"
fi

# ─── Step 5: Sync to Podman volume ───────────────────────────────────────────
log_step "5/5  Sync to volume '${TARGET_VOLUME}'"

if [[ "${NO_SYNC}" == "1" ]]; then
    log_warn "NO_SYNC=1 — skipping volume sync"
    log_info "Files downloaded to: ${INSTALL_DIR}"
    log_info "Sync manually: rsync -az ${INSTALL_DIR}/ <host>:<volume-path>/"
    exit 0
fi

if [[ -n "${TARGET_HOST}" ]]; then
    # Remote host: detect volume mount path via SSH + podman inspect
    log_info "Syncing to remote host: ${TARGET_HOST}"
    if [[ -z "${TARGET_PATH}" ]]; then
        log_info "Detecting volume path on remote host..."
        TARGET_PATH=$(ssh "${TARGET_HOST}" \
            "podman volume inspect '${TARGET_VOLUME}' --format '{{.Mountpoint}}'" 2>/dev/null) || {
            log_error "Could not detect volume path on ${TARGET_HOST}"
            log_info "Set --target-path manually or ensure the volume exists:"
            log_info "  ssh ${TARGET_HOST} podman volume create ${TARGET_VOLUME}"
            exit 1
        }
    fi
    log_info "Remote volume path: ${TARGET_PATH}"
    run rsync -az --progress --delete \
        "${INSTALL_DIR}/" \
        "${TARGET_HOST}:${TARGET_PATH}/"
    log_ok "Synced to ${TARGET_HOST}:${TARGET_PATH}/"
else
    # Local host: detect volume mount path
    if [[ -z "${TARGET_PATH}" ]]; then
        TARGET_PATH=$(podman volume inspect "${TARGET_VOLUME}" \
            --format '{{.Mountpoint}}' 2>/dev/null) || {
            log_error "Could not inspect local volume '${TARGET_VOLUME}'"
            log_info "Create it first: podman volume create ${TARGET_VOLUME}"
            exit 1
        }
    fi
    log_info "Local volume path: ${TARGET_PATH}"
    run rsync -az --progress --delete \
        "${INSTALL_DIR}/" \
        "${TARGET_PATH}/"
    log_ok "Synced to ${TARGET_PATH}/"
fi

echo ""
echo -e "${GREEN}${BOLD}  Game files staged successfully!${RESET}"
echo ""
log_info "Restart the server container to pick up the new files:"
log_info "  podman start cryofall"
log_info "  # or via GSA: GSA GUI → CryoFall → Actions → Start"
echo ""

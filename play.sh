#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# play.sh — Self-healing, fault-tolerant, reflective launch script
# for Game Server Admin (GSA)
#
# This script is homoiconic: it reads and reasons about its own source.
# It can introspect its own capabilities, self-repair broken state,
# and recover from partial failures at every stage.
#
# CAPABILITIES (parsed reflectively from this source):
#   @cap:sync       — Verify repo is synchronised with remote
#   @cap:build      — Ensure latest build is present and current
#   @cap:run        — Launch the game/application
#   @cap:heal       — Self-heal broken state (missing tools, dirty worktrees)
#   @cap:reflect    — Introspect own source for capabilities and metadata
#   @cap:platform   — Auto-detect OS, arch, and available toolchains
#   @cap:fault      — Fault-tolerant with retry and graceful degradation

set -euo pipefail

# ─── Metaiconic core: the script can read itself ─────────────────────────────
readonly SELF="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SELF_DIR="$(dirname "$SELF")"
readonly SELF_NAME="$(basename "$SELF")"
readonly SELF_SHA="$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1 || echo "unknown")"

# ─── Reflective capability registry (parsed from @cap: tags above) ───────────
declare -A CAPS
_reflect_caps() {
    while IFS= read -r line; do
        if [[ "$line" =~ @cap:([a-z]+) ]]; then
            local cap="${BASH_REMATCH[1]}"
            local desc="${line#*— }"
            CAPS["$cap"]="$desc"
        fi
    done < "$SELF"
}

# ─── Platform detection ──────────────────────────────────────────────────────
declare PLAT_OS="" PLAT_ARCH="" PLAT_SHELL="" PLAT_DISPLAY=""

_detect_platform() {
    case "$(uname -s)" in
        Linux*)   PLAT_OS="linux"   ;;
        Darwin*)  PLAT_OS="macos"   ;;
        CYGWIN*|MINGW*|MSYS*) PLAT_OS="windows" ;;
        FreeBSD*) PLAT_OS="freebsd" ;;
        *)        PLAT_OS="unknown" ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)   PLAT_ARCH="x86_64"  ;;
        aarch64|arm64)  PLAT_ARCH="aarch64"  ;;
        armv7l)         PLAT_ARCH="armv7"    ;;
        riscv64)        PLAT_ARCH="riscv64"  ;;
        *)              PLAT_ARCH="$(uname -m)" ;;
    esac

    PLAT_SHELL="$(basename "${SHELL:-/bin/sh}")"

    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        PLAT_DISPLAY="wayland"
    elif [[ -n "${DISPLAY:-}" ]]; then
        PLAT_DISPLAY="x11"
    elif [[ "$PLAT_OS" == "macos" ]]; then
        PLAT_DISPLAY="quartz"
    else
        PLAT_DISPLAY="headless"
    fi
}

# ─── Colour + output ─────────────────────────────────────────────────────────
_supports_colour() {
    [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]
}

if _supports_colour; then
    readonly C_GREEN='\033[1;32m' C_RED='\033[1;31m' C_YELLOW='\033[1;33m'
    readonly C_CYAN='\033[1;36m' C_BOLD='\033[1m' C_DIM='\033[2m'
    readonly C_RESET='\033[0m'
else
    readonly C_GREEN='' C_RED='' C_YELLOW='' C_CYAN='' C_BOLD='' C_DIM='' C_RESET=''
fi

_info()  { printf "${C_CYAN}[info]${C_RESET}  %s\n" "$*"; }
_ok()    { printf "${C_GREEN}[  ok]${C_RESET}  %s\n" "$*"; }
_warn()  { printf "${C_YELLOW}[warn]${C_RESET}  %s\n" "$*" >&2; }
_fail()  { printf "${C_RED}[FAIL]${C_RESET}  %s\n" "$*" >&2; }
_step()  { printf "\n${C_BOLD}═══ %s ═══${C_RESET}\n" "$*"; }

# ─── Fault tolerance: retry with backoff ─────────────────────────────────────
_retry() {
    local max_attempts="${1}"; shift
    local delay="${1}"; shift
    local attempt=1
    while true; do
        if "$@"; then
            return 0
        fi
        if (( attempt >= max_attempts )); then
            _fail "Failed after ${max_attempts} attempts: $*"
            return 1
        fi
        _warn "Attempt ${attempt}/${max_attempts} failed, retrying in ${delay}s..."
        sleep "$delay"
        (( attempt++ ))
        (( delay *= 2 ))
    done
}

# ─── Self-healing: check and fix prerequisites ──────────────────────────────
_heal_tool() {
    local tool="$1" install_hint="$2"
    if command -v "$tool" &>/dev/null; then
        _ok "$tool found: $(command -v "$tool")"
        return 0
    fi
    _warn "$tool not found — attempting self-heal..."
    case "$PLAT_OS" in
        linux)
            if command -v rpm-ostree &>/dev/null; then
                _info "Fedora Atomic detected — install with: rpm-ostree install $install_hint"
            elif command -v dnf &>/dev/null; then
                _info "Try: sudo dnf install $install_hint"
            elif command -v apt-get &>/dev/null; then
                _info "Try: sudo apt-get install $install_hint"
            elif command -v pacman &>/dev/null; then
                _info "Try: sudo pacman -S $install_hint"
            fi
            ;;
        macos)
            if command -v brew &>/dev/null; then
                _info "Try: brew install $install_hint"
            fi
            ;;
    esac
    # Check asdf as fallback
    if command -v asdf &>/dev/null; then
        _info "asdf available — check: asdf plugin list all | grep $tool"
    fi
    _fail "$tool is required but could not be auto-installed"
    return 1
}

# ─── Git sync check ─────────────────────────────────────────────────────────
_check_sync() {
    _step "SYNC CHECK"
    cd "$SELF_DIR"

    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        _fail "Not a git repository: $SELF_DIR"
        return 1
    fi

    local branch
    branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")"
    _info "Branch: $branch"

    # Fetch with fault tolerance (network may be flaky)
    if _retry 3 2 git fetch --quiet origin 2>/dev/null; then
        _ok "Remote fetched successfully"
    else
        _warn "Could not reach remote — continuing with local state"
        return 0
    fi

    local local_sha remote_sha base_sha
    local_sha="$(git rev-parse HEAD)"
    remote_sha="$(git rev-parse "origin/${branch}" 2>/dev/null || echo "none")"

    if [[ "$remote_sha" == "none" ]]; then
        _warn "No remote tracking branch origin/${branch}"
        return 0
    fi

    if [[ "$local_sha" == "$remote_sha" ]]; then
        _ok "Local and remote are in sync ($branch @ ${local_sha:0:8})"
        return 0
    fi

    base_sha="$(git merge-base "$local_sha" "$remote_sha" 2>/dev/null || echo "none")"

    if [[ "$base_sha" == "$local_sha" ]]; then
        _warn "Local is behind remote — pulling..."
        if git pull --ff-only origin "$branch" 2>/dev/null; then
            _ok "Fast-forward pull succeeded"
        else
            _warn "Could not fast-forward — manual merge may be needed"
            return 1
        fi
    elif [[ "$base_sha" == "$remote_sha" ]]; then
        _warn "Local is ahead of remote (unpushed commits)"
        _info "Run 'git push' when ready"
    else
        _warn "Local and remote have diverged — manual resolution needed"
        return 1
    fi
}

# ─── Build check ─────────────────────────────────────────────────────────────
_check_build() {
    _step "BUILD CHECK"
    cd "$SELF_DIR"

    # GSA builds with: just build (which runs zig build under the hood)
    # The CLI binary lives at src/interface/ffi/zig-out/bin/gsa
    local binary="src/interface/ffi/zig-out/bin/gsa"

    # Check if build artifact exists and is newer than source
    local needs_build=false
    if [[ ! -f "$binary" ]]; then
        _warn "Build artifact not found: $binary"
        needs_build=true
    else
        # Check if any source file is newer than the binary
        local newest_src
        newest_src="$(find src/ -name '*.zig' -o -name '*.idr' -o -name '*.eph' 2>/dev/null \
                      | head -100 \
                      | xargs -I{} stat -c '%Y {}' {} 2>/dev/null \
                      | sort -rn | head -1 | cut -d' ' -f2 || echo "")"
        if [[ -n "$newest_src" ]] && [[ "$newest_src" -nt "$binary" ]]; then
            _warn "Source newer than build — rebuild needed"
            needs_build=true
        else
            _ok "Build is up to date"
        fi
    fi

    if [[ "$needs_build" == "true" ]]; then
        _info "Building GSA..."
        # Self-heal: ensure build tools are available
        _heal_tool "just" "just" || return 1
        _heal_tool "zig" "zig" || return 1

        if _retry 2 3 just build; then
            _ok "Build succeeded"
        else
            _fail "Build failed — check errors above"
            return 1
        fi
    fi
}

# ─── Run ──────────────────────────────────────────────────────────────────────
_run_game() {
    _step "LAUNCH"
    cd "$SELF_DIR"

    _info "Platform: ${PLAT_OS}/${PLAT_ARCH} (${PLAT_DISPLAY}, ${PLAT_SHELL})"
    _info "Starting Game Server Admin..."

    # GSA primary mode: status check + probe interface
    if command -v just &>/dev/null; then
        just run status
    else
        local binary="src/interface/ffi/zig-out/bin/gsa"
        if [[ -x "$binary" ]]; then
            "$binary" status
        else
            _fail "No way to run GSA — need 'just' or built binary"
            return 1
        fi
    fi
}

# ─── Reflection: introspect own capabilities ─────────────────────────────────
_show_reflection() {
    _step "SELF-REFLECTION"
    _info "Script: $SELF_NAME"
    _info "SHA256: ${SELF_SHA:0:16}..."
    _info "Size: $(wc -c < "$SELF") bytes, $(wc -l < "$SELF") lines"
    _info "Platform: ${PLAT_OS}/${PLAT_ARCH} (${PLAT_DISPLAY})"
    echo ""
    _info "Registered capabilities:"
    for cap in "${!CAPS[@]}"; do
        printf "  ${C_GREEN}@cap:%-10s${C_RESET} %s\n" "$cap" "${CAPS[$cap]}"
    done
}

# ─── The smiley ──────────────────────────────────────────────────────────────
_smiley() {
    printf "${C_GREEN}"
    cat << 'SMILEY'

            ██████████████████████████
        ████                          ████
      ██                                  ██
    ██                                      ██
  ██                                          ██
  ██      ████████          ████████          ██
██        ████████          ████████            ██
██        ████████          ████████            ██
██          ████              ████              ██
██                                              ██
██                                              ██
██            ██                  ██            ██
  ██          ██                  ██          ██
  ██            ████████████████            ██
    ██              ████████              ██
      ██                                ██
        ████                          ████
            ██████████████████████████

             Game Server Admin — Ready!

SMILEY
    printf "${C_RESET}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    _detect_platform
    _reflect_caps
    _smiley

    case "${1:-run}" in
        reflect|--reflect|-r)
            _show_reflection
            ;;
        sync|--sync)
            _check_sync
            ;;
        build|--build)
            _check_build
            ;;
        run|--run|"")
            _check_sync || _warn "Sync check had issues — continuing anyway"
            _check_build || { _fail "Build failed — cannot run"; exit 1; }
            _run_game
            ;;
        heal|--heal)
            _step "SELF-HEAL"
            _heal_tool "git" "git"
            _heal_tool "just" "just"
            _heal_tool "zig" "zig"
            _ok "Heal check complete"
            ;;
        help|--help|-h)
            _show_reflection
            echo ""
            _info "Usage: ./$SELF_NAME [command]"
            _info "  run      Full pipeline: sync → build → run (default)"
            _info "  sync     Check repo is synced with remote"
            _info "  build    Ensure latest build is present"
            _info "  heal     Check and fix prerequisites"
            _info "  reflect  Show script introspection data"
            _info "  help     This message"
            ;;
        *)
            _fail "Unknown command: $1 (try --help)"
            exit 1
            ;;
    esac
}

main "$@"

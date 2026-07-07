#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# affine-ffi-contract-check.sh — keep the AffineScript FFI layer in lockstep
# with the Zig FFI exports, the same way abi-contract.yml keeps the Idris2
# model in lockstep.
#
# Contract:
#   1. Every gossamer_gsa_* symbol declared in src/ui/tea/gsa_ffi.affine
#      must exist as a `pub export fn` in src/interface/ffi/src/*.zig
#      (no phantom bindings).
#   2. Every symbol listed in the CORE set below must be declared in the
#      .affine FFI layer (the interface cannot silently lose a capability).
#      The CORE set is the operational surface the GUI depends on; pure
#      ABI plumbing helpers (read_int/read_ptr/...) may be bound lazily.
#
# Exit 0 = in sync, exit 1 = drift (with a diff-style report).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AFFINE_FFI="$ROOT_DIR/src/ui/tea/gsa_ffi.affine"
ZIG_SRC_DIR="$ROOT_DIR/src/interface/ffi/src"

if [[ ! -f "$AFFINE_FFI" ]]; then
  echo "FAIL: $AFFINE_FFI not found" >&2
  exit 1
fi

# Symbols the AffineScript interface MUST bind (operational surface).
CORE_SYMBOLS=(
  gossamer_gsa_init
  gossamer_gsa_shutdown
  gossamer_gsa_version
  gossamer_gsa_last_error
  gossamer_gsa_probe
  gossamer_gsa_fingerprint
  gossamer_gsa_extract_config
  gossamer_gsa_apply_config
  gossamer_gsa_a2ml_emit
  gossamer_gsa_a2ml_parse
  gossamer_gsa_server_action
  gossamer_gsa_get_logs
  gossamer_gsa_run_script
  gossamer_gsa_write_server_config
  gossamer_gsa_load_profiles
  gossamer_gsa_list_profiles
  gossamer_gsa_add_profile
  gossamer_gsa_verisimdb_store
  gossamer_gsa_verisimdb_query
  gossamer_gsa_verisimdb_health
  gossamer_gsa_verisimdb_drift
  gossamer_gsa_groove_alert
  gossamer_gsa_groove_status
  gossamer_gsa_steam_resolve_vanity
  gossamer_gsa_steam_player_info
  gossamer_gsa_close_handle
  gossamer_gsa_free
)

declared=$(grep -oE 'gossamer_gsa_[a-z0-9_]+' "$AFFINE_FFI" | sort -u)
exported=$(grep -hoE 'pub export fn (gossamer_gsa_[a-z0-9_]+)' "$ZIG_SRC_DIR"/*.zig \
             | sed 's/pub export fn //' | sort -u)

fail=0

# 1. No phantom bindings: declared ⊆ exported
phantom=$(comm -23 <(echo "$declared") <(echo "$exported") || true)
if [[ -n "$phantom" ]]; then
  echo "FAIL: symbols declared in gsa_ffi.affine but not exported by the Zig FFI:" >&2
  echo "$phantom" | sed 's/^/  - /' >&2
  fail=1
fi

# 2. Core coverage: CORE ⊆ declared
missing=""
for sym in "${CORE_SYMBOLS[@]}"; do
  if ! grep -q "^${sym}$" <<<"$declared"; then
    missing+="  - ${sym}"$'\n'
  fi
done
if [[ -n "$missing" ]]; then
  echo "FAIL: core symbols missing from gsa_ffi.affine:" >&2
  printf '%s' "$missing" >&2
  fail=1
fi

if [[ "$fail" -eq 0 ]]; then
  n_declared=$(wc -l <<<"$declared")
  n_exported=$(wc -l <<<"$exported")
  echo "OK: AffineScript FFI layer in sync (${n_declared} declared / ${n_exported} exported, all ${#CORE_SYMBOLS[@]} core symbols bound)"
fi
exit "$fail"

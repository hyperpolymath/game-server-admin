#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
# Real Linux Idris -> libgsa checks; fixture files only, no game-server operation.
set -euo pipefail

build_root=${1:?Usage: bash scripts/test-idris-ffi.sh /absolute/dedicated/build-directory}
if [[ "$build_root" != /* || "$build_root" == / ]]; then
  echo 'A dedicated absolute build directory is required.' >&2
  exit 2
fi
repo_root=$(git rev-parse --show-toplevel)
mkdir -p "$build_root"

(
  cd "$repo_root/src/interface/ffi"
  zig build --prefix "$build_root/native" \
    --cache-dir "$build_root/zig-cache" \
    --global-cache-dir "$build_root/zig-global-cache"
)
(
  cd "$repo_root/src/interface/abi"
  idris2 --typecheck gsa-abi.ipkg --build-dir "$build_root/idris"
  idris2 --build gsa-abi-test.ipkg --build-dir "$build_root/idris"
)
LD_LIBRARY_PATH="$build_root/native/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  "$build_root/idris/exec/gsa-abi-runtime-test" \
  "$repo_root/src/interface/abi/fixtures"

# Planted failure: a file is not a fixture directory. Require the intended
# assertion to fail, not a missing library, compiler failure or arbitrary crash.
if failure_output=$(LD_LIBRARY_PATH="$build_root/native/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$build_root/idris/exec/gsa-abi-runtime-test" \
    "$repo_root/src/interface/abi/fixtures/fixture.a2ml"); then
  echo 'FAIL: invalid fixture directory unexpectedly passed.' >&2
  exit 1
else
  failure_status=$?
  if [[ "$failure_status" != 1 || "$failure_output" != *'FAIL real profile fixture loads and clears previous native error'* ]]; then
    printf '%s\n' "$failure_output" >&2
    echo 'FAIL: negative control did not reach the intended assertion.' >&2
    exit 1
  fi
  echo 'PASS: invalid fixture directory fails at the intended real-load assertion.'
fi

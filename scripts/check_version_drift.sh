#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# check_version_drift.sh — assert every *software* version string matches the
# canonical source of truth: main.zig's VERSION constant.
#
# Scope: the shipped-software version (the library, the CLI, the panel
# descriptors). The `[metadata] version` fields in .machine_readable/**/*.a2ml
# are the versions of those metadata documents themselves, not the software,
# and are deliberately NOT checked here.
#
# Run from anywhere: scripts/check_version_drift.sh
set -euo pipefail
cd "$(dirname "$0")/.."

canonical=$(grep -oE 'VERSION: \[:0\]const u8 = "[0-9]+\.[0-9]+\.[0-9]+"' \
  src/interface/ffi/src/main.zig | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
if [[ -z "${canonical:-}" ]]; then
  echo "ERROR: could not read canonical VERSION from main.zig" >&2
  exit 2
fi
echo "canonical (main.zig VERSION) = $canonical"

fail=0
check() {
  local file="$1" ver="$2"
  if [[ "$ver" != "$canonical" ]]; then
    echo "DRIFT: $file = '$ver' (expected '$canonical')"
    fail=1
  fi
}

# main.zig BUILD_INFO
check "main.zig BUILD_INFO" \
  "$(grep -oE 'libgsa [0-9]+\.[0-9]+\.[0-9]+' src/interface/ffi/src/main.zig | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"

# build.zig — both .version structs
while read -r v; do check "build.zig .version" "$v"; done < <(
  grep -oE '\.major = [0-9]+, \.minor = [0-9]+, \.patch = [0-9]+' src/interface/ffi/build.zig \
    | grep -oE '[0-9]+' | paste -sd' ' - | awk '{for(i=1;i<=NF;i+=3) print $i"."$(i+1)"."$(i+2)}')

# run.js
check "run.js" \
  "$(grep -oE 'version: "[0-9]+\.[0-9]+\.[0-9]+"' run.js | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"

# panels
for f in panels/manifest.json panels/*/panel.json; do
  check "$f" "$(grep -oE '"version": "[0-9]+\.[0-9]+\.[0-9]+"' "$f" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
done

if [[ $fail -eq 0 ]]; then
  echo "OK: all software versions == $canonical"
else
  echo "Version drift detected. Update the offending files or main.zig's VERSION." >&2
  exit 1
fi

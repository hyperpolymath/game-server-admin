#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Generate panel clade definitions from game profiles.
# Each profiles/*.a2ml file spawns a child clade under gsa-game.

set -euo pipefail

for profile in profiles/*.a2ml; do
  id=$(grep -oP 'id="\K[^"]+' "$profile" | head -1)
  name=$(grep -oP 'name="\K[^"]+' "$profile" | head -1)
  if [ -z "$id" ]; then continue; fi

  clade_dir="panel-clades/gsa-game-${id}"
  mkdir -p "$clade_dir"

  cat > "$clade_dir/GsaGame${id}.a2ml" << CLADE_EOF
# SPDX-License-Identifier: PMPL-1.0-or-later
# Auto-generated from profiles/${id}.a2ml

[clade-metadata]
id = "gsa-game-${id}"
name = "GSA ${name}"
short-name = "${name}"
version = "1.0.0"
kind = "game-profile"
icon = "gamepad"
description = "Game profile clade for ${name} — inherits from gsa-game"

[clade-traits]
has-backend = true
has-scanning = true
has-persistence = true
has-real-time = true

[clade-taxonomy]
inherits-from = "gsa-game"
CLADE_EOF
done

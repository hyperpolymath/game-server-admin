<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->
# TOPOLOGY.md — game-server-admin

## Purpose

Universal game server probe, configuration management, and administration panel. Attaches to any game server, fingerprints it via protocol probing, extracts its configuration into A2ML format, and provides a rich GUI for viewing, editing, and tracking config changes with full provenance. Built on Gossamer (linearly-typed webview shell) with VeriSimDB underpinning.

## Module Map

```
game-server-admin/
├── src/
│   ├── gui/          # Gossamer GUI layer (Ephapax + HTML/JS)
│   │   ├── panels/   # 7 Clade-citizen UI panels
│   │   ├── main.eph  # Ephapax entry point
│   │   └── host.html # Webview host
│   ├── core/         # Protocol probing + config extraction
│   ├── interface/    # IPC bridge (gossamer://)
│   └── (aspects, bridges, contracts, definitions, errors)
├── assets/           # Icons and static assets
├── docs/             # Architecture and usage docs
└── game-server-admin.desktop  # Linux desktop integration
```

## Data Flow

```
[Game server] ──► [Protocol probe] ──► [Config extraction] ──► [A2ML format]
                                                                      │
                                                         [VeriSimDB storage]
                                                                      │
                                               [Gossamer GUI / panels] ──► [User]
```

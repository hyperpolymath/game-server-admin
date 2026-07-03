<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# Architecture

GSA is four layers, each with a narrow, typed contract to the next. The design
principle: **push correctness down to where it can be proven, and keep every
boundary explicit.**

```mermaid
flowchart LR
    subgraph L1["① Presentation — Gossamer GUI"]
        direction TB
        EPH["Ephapax .eph<br/>Shell · Bridge · Capabilities"]
        HTML["8 HTML/JS panels<br/>server-browser, config-editor,<br/>server-actions, live-logs,<br/>health-dashboard, config-history,<br/>cross-search, nexus-setup"]
    end
    subgraph L2["② Engine — Zig FFI (libgsa.so + gsa CLI)"]
        direction TB
        PROBE["probe · config_extract<br/>a2ml_emit · server_actions"]
        CLIENTS["verisimdb / steam / groove clients<br/>+ http_capability gateway"]
        SERDE["abi_layout · abi_serde"]
    end
    subgraph L3["③ Contract — Idris2 ABI"]
        direction TB
        TYPES["Types.idr — 18 result codes,<br/>dependent-typed validation"]
        LAYOUT["Layout.idr — constructive<br/>memory-layout proofs"]
        FOREIGN["Foreign.idr — safe wrappers"]
    end
    subgraph L4["④ Persistence — VeriSimDB"]
        direction TB
        MAIN["main :8090<br/>config · probe · octads"]
        BACKUP["backup :8091<br/>save metadata · snapshots"]
    end

    L1 -->|"gossamer:// IPC"| L2
    L2 -->|"C ABI (18 codes)"| L3
    L2 -->|"REST"| L4
    L3 -. "proves the layout<br/>L2 is compiled against" .-> L2
```

## The layers

### ① Gossamer GUI — `src/core/`, `src/gui/`
The user-facing shell. **Ephapax** `.eph` modules (`Shell`, `Bridge`,
`Capabilities`) define the IPC contract and lifecycle; the actual UI is 8
fat `panel.html` files driven by FLI widgets. Ephapax's *linear types* guarantee
GUI handles (webview, channels, capabilities) are consumed exactly once — that
is the whole reason the presentation layer is written in Ephapax and not JS.
The GUI reaches the engine over the `gossamer://` IPC bridge; Gossamer loads
`libgsa` via `dlopen` at runtime.

### ② Zig FFI — `src/interface/ffi/`
The load-bearing engine and the one artifact you can run standalone (`gsa`
CLI + `libgsa.so`, 40 exported `gossamer_gsa_*` symbols). It owns:
- **probing** (`probe.zig`) — 5 protocols, DNS/IPv6, per-probe deadlines;
- **config extraction** (`config_extract.zig`) — 8 formats → flat typed fields;
- **A2ML** (`a2ml_emit.zig`) — serialise/parse/diff with secret redaction;
- **server actions** (`server_actions.zig`) — Podman/Docker/systemd, local or SSH, injection-hardened;
- **outbound HTTP** (`http_capability.zig`) — one deadline-enforcing gateway for the VeriSimDB/Steam/Groove clients;
- **the binary ABI** (`abi_layout.zig`, `abi_serde.zig`) — extern structs pinned to the proven Idris layout.

See [`docs/developer/FFI-MODULE-REFERENCE.adoc`](../developer/FFI-MODULE-REFERENCE.adoc).

### ③ Idris2 ABI — `src/interface/abi/`
The **specification**, with proofs. `Types.idr` carries the domain model with
dependent-typed validation (`ValidPort`, `NonEmpty`, `ValidConfig`) and the
18-variant `Result`. `Layout.idr` proves each wire struct's field offsets don't
overlap and are aligned — *zero postulates, all constructive*. `Foreign.idr`
wraps the raw C calls with the linear ServerHandle protocol. A code generator
lifts these facts into Zig so the compiler enforces them (see
[The Proven ABI](05-The-Proven-ABI.md)).

### ④ VeriSimDB — `container/verisimdb/`, `container/verisimdb-backup/`
Two dedicated instances: **main** (`:8090`) for server config, probe data and
8-modality octads; **backup** (`:8091`) for game-save metadata and restore
points. GSA is a *client* — the DB server itself is built from an external
source at container-build time.

## Data flow: a probe-to-store round-trip

```mermaid
sequenceDiagram
    actor U as User (GUI/CLI)
    participant B as Bridge (.eph)
    participant F as Zig FFI
    participant S as Game server
    participant V as VeriSimDB
    U->>B: probe host:port
    B->>F: gossamer_gsa_probe(host, port)
    F->>S: A2S / SLP / RCON / HTTP (with deadline)
    S-->>F: protocol reply
    F->>F: identify game · extract config · emit A2ML
    F->>V: store octad (via http_capability, deadline-bounded)
    F-->>B: handle id (≥1000) or result code
    B-->>U: server card + config + drift
```

## External dependencies (and graceful degradation)

| Dependency | GSA assumes | Without it |
|---|---|---|
| **Gossamer** | loads `libgsa` via dlopen; `gossamer://` IPC | CLI still works; GUI won't launch |
| **Ephapax** | compiles the `.eph` sources | CLI unaffected; GUI can't be built (2/25 chain tests blocked on parser gaps) |
| **VeriSimDB** | REST client to `:8090` | probing/config work; storage/drift return `verisimdb_unavailable` |
| **Groove** | HTTP voice/text alerts | alerts are best-effort; core unaffected |
| **panic-attack / standards** | CI lint + reusable workflows | local dev unaffected; CI degrades gracefully |

The rule of thumb: **anything you can do without a GUI, the `gsa` CLI can do
today.** Anything that needs the webview or live drift needs the estate running.

→ Next: [Installation](03-Installation.md)

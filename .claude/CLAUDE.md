# CLAUDE.md — Game Server Admin (GSA)

## Quick Context

Universal game server probe, config management, and administration tool.
Gossamer GUI + Zig FFI + Idris2 ABI + VeriSimDB backing store.

## Build & Test

```bash
# All commands run from src/interface/ffi/
cd src/interface/ffi

# Build shared + static library + CLI executable
zig build

# Run the CLI (from repo root)
just run status            # system status + VeriSimDB health + profiles
just run probe <host> [port]  # fingerprint a game server
just run profiles          # list supported games
just run version           # print version

# Run unit tests (fast, no I/O)
zig build test

# Run integration tests (36 tests, no live services)
zig build test-integration

# Run e2e smoke tests (full pipeline, no live services)
zig build test-smoke

# Build with optional Gossamer linking
zig build -Dgossamer-lib-path=/path/to/gossamer/src/interface/ffi/zig-out/lib

# Pre-commit check
panic-attack assail .
```

## Architecture

```
Gossamer GUI (Ephapax .eph)        -- src/core/, src/gui/panels/
    |  IPC (gossamer:// protocol)
Zig FFI (libgsa.so + gsa CLI)     -- src/interface/ffi/src/ (9 modules)
    |  C ABI (13 result codes)
Idris2 ABI (Types/Foreign/Layout)  -- src/interface/abi/
    |  REST (port 8090)
VeriSimDB (8-modality octads)      -- container/verisimdb/
```

### FFI Modules (src/interface/ffi/src/)

| Module | Purpose |
|--------|---------|
| `main.zig` | Lifecycle, GsaHandle, error buffer, result codes |
| `probe.zig` | Protocol fingerprinting (8 protocols, 20+ known ports) |
| `config_extract.zig` | Config parsing (8 formats: XML/INI/JSON/ENV/YAML/TOML/Lua/KV) |
| `a2ml_emit.zig` | A2ML serialisation + parsing + config diff |
| `verisimdb_client.zig` | VeriSimDB HTTP client (Zig 0.15 fetch API) |
| `server_actions.zig` | Start/stop/restart/logs via Podman/Docker/systemd |
| `game_profiles.zig` | A2ML profile registry + parser |
| `groove_client.zig` | .well-known Groove voice alerting |
| `cli.zig` | Standalone CLI executable (status, probe, profiles, version) |

## Key Conventions

- **All exported FFI functions** are prefixed `gossamer_gsa_` and use `pub export fn ... callconv(.c)`
- **Result codes** are contractual — must match `src/interface/abi/Types.idr`
- **Secrets** must be redacted as `[REDACTED]` in A2ML output and octad JSON
- **Machine-readable metadata** lives in `.machine_readable/` ONLY (never root)
- **Game profiles** are A2ML files in `profiles/` — support quoted AND unquoted attribute values
- **VeriSimDB instances** are dedicated — never store GSA data in the VeriSimDB source repo
  - **Main** (port 8090, `GSA_VERISIMDB_URL`): server config, probe data, octads
  - **Backup** (port 8091, `GSA_BACKUP_VERISIMDB_URL`): game save metadata, snapshots, restore points
- **Container images** use Chainguard Wolfi base, Podman, `Containerfile` (never Docker/Dockerfile)

## Current State (2026-03-29)

- **Completion**: 93% (Phases 1-12 complete, 13-15 nearly done)
- **Zig version**: 0.15.2 (see `.tool-versions`)
- **Exported FFI symbols**: 24 (comptime linker hints in main.zig)
- **Tests**: All 3 Zig suites pass. E2E: 8/8 against live VeriSimDB. Gossamer chain: 25/25.
- **VeriSimDB**: Main on 8090 (built, running), backup on 8091 (game saves)
- **Icon**: SVG + 256px PNG in assets/
- **Remaining**: Bitbucket mirror (SSH key issue)

## Lint / Quality

- `panic-attack assail .` before every commit
- `just check` for full quality sweep
- No dangerous patterns: `believe_me`, `assert_total`, `unsafeCoerce`, etc.
- All actions SHA-pinned in CI workflows

## File Locations

| What | Where |
|------|-------|
| AI manifest | `0-AI-MANIFEST.a2ml` (read FIRST) |
| State checkpoint | `.machine_readable/6a2/STATE.a2ml` |
| Game profiles | `profiles/*.a2ml` (17 games) |
| GUI panels | `src/gui/panels/` (7 panels) |
| Panel clades | `panel-clades/` (9 base + game children) |
| Ephapax core | `src/core/` (Shell, Bridge, Types, Capabilities) |
| VeriSimDB (main, port 8090) | `container/verisimdb/` |
| VeriSimDB (backup saves, port 8091) | `container/verisimdb-backup/` |
| Main quadlet | `container/verisimdb/gsa-verisimdb.container` |
| Backup quadlet | `container/verisimdb-backup/gsa-verisimdb-backup.container` |
| Icon assets | `assets/icon.svg`, `assets/icon-256.png` |
| E2E test | `scripts/e2e-test.sh` |
| Gossamer chain test | `scripts/gossamer-integration-test.sh` |
| CLI binary | `src/interface/ffi/zig-out/bin/gsa` |
| Desktop entry | `game-server-admin.desktop` |

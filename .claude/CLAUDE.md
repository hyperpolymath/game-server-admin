<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->
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

# Run integration tests (41 tests, no live services)
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
Zig FFI (libgsa.so + gsa CLI)     -- src/interface/ffi/src/ (13 modules)
    |  C ABI (18 result codes)
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
| `abi_layout.zig` | Canonical C-ABI `extern struct`s + comptime Zig↔Idris layout cross-check |
| `abi_serde.zig` | Binary ABI emitters + offset readers (`read_int`/`read_ptr`/…) — makes `Layout.idr` offsets a live contract |
| `steam_client.zig` | Steam Web API (vanity→Steam64, player summary, ownership) |
| `http_capability.zig` | HTTP capability gateway (Phase 11) — capability-scoped REST surface over the FFI |
| `cli.zig` | Standalone CLI executable (status, probe, profiles, version) |

`abi_layout_expected.zig` is generated from `Layout.idr` by
`scripts/gen_abi_expected.zig` (`zig run`; regenerate when `Layout.idr` changes).

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

## Current State (2026-07-07)

- **Completion**: 96% (15 phases built; hardening phases 4–8, tri-license + 0.9.0 version SSOT, HTTP capability gateway + illustrated wiki merged via PRs #61–#63; v1.0.0 gates still open — see Remaining)
- **CI (2026-07-07)**: Secret Scanner startup_failure fixed (caller job-level perms + repin to standards@891b1ed); Instant Sync red is owner-gated (dead FARM_DISPATCH_TOKEN, estate-wide); `.machine_readable/` migrated 6a2→descriptiles, agent_instructions→bot_directives per estate mandate
- **CI/Governance (2026-06-21, PRs #41–#45)**: workflows hardened (Scorecard wrapper job perms, presence-gated instant-sync, CodeQL `actions`, scoped `deno` perms); standards reusable pins at `4ddc926`; Hypatia false positives suppressed via `.hypatia-ignore` (the inert `.hypatia-baseline.json` was removed — `hypatia scan` never applied it); advisory scan at critical=0/high=0. Doc map + gaps: `docs/INDEX.adoc`.
- **Zig version**: 0.15.2 (see `.tool-versions`)
- **Exported FFI symbols**: 40 (comptime linker hints in main.zig)
- **Tests**: 140 Zig tests across 3 suites (unit: 94, integration: 41, smoke: 5). All passing (verified 2026-07-07).
  - Security tests for command injection in server_actions
  - Config parser edge cases for all 8 formats
  - A2ML round-trip, diff, and secret redaction tests
  - Groove target registry overflow and buffer truncation tests
  - ABI layout cross-check + binary ABI round-trip (read at proven `Layout.idr` offsets)
- **Idris2 ABI**: Alignment postulate replaced with constructive proof (`alignUpCeil` + `alignUpCeilIsMultiple`)
- **Cross-language ABI**: `abi_layout.zig` asserts (at compile time + `zig build test`) that the 8 `extern struct`s match the proven `Layout.idr` offsets/sizes; `abi_serde.zig` implements the offset readers/emitters so those offsets are a live runtime contract (was the open HIGH proof item)
- **VeriSimDB**: Main on 8090 (built, running), backup on 8091 (game saves)
- **Container**: Containerfile wired with real Zig build, entrypoint.sh execs gsa
- **Guix**: guix.scm has real build/install phases (flake.guix removed in the guix→guix migration)
- **Release CI**: release.yml builds Zig, packages tarball, uploads artifacts
- **Groove**: Full manifest with probe/config/drift/alert capabilities
- **Icon**: SVG + 256px PNG in assets/
- **Remaining (v1.0.0 gates)**: Gossamer chain env prerequisite (libgossamer.so unbuilt — needs `libgtk-3-dev libwebkit2gtk-4.1-dev`; the historical Ephapax parser gaps are CLOSED, verified 2026-07-07); CryoFall game-file staging (blocker B4, manual SteamCMD); Bitbucket mirror (SSH key -- manual step); OpenSSF badge; full docs pass

## Lint / Quality

- `panic-attack assail .` before every commit
- `just check` for full quality sweep
- No dangerous patterns: `believe_me`, `assert_total`, `unsafeCoerce`, etc.
- All actions SHA-pinned in CI workflows

## File Locations

| What | Where |
|------|-------|
| AI manifest | `0-AI-MANIFEST.a2ml` (read FIRST) |
| State checkpoint | `.machine_readable/descriptiles/STATE.a2ml` |
| Game profiles | `profiles/*.a2ml` (18 games) |
| GUI panels | `src/gui/panels/` (8 panels) |
| Panel clades | `panel-clades/` (9 base + game children) |
| Ephapax core | `src/core/` (Shell, Bridge, Types, Capabilities) |
| VeriSimDB (main, port 8090) | `container/verisimdb/` |
| VeriSimDB (backup saves, port 8091) | `container/verisimdb-backup/` |
| Main quadlet | `container/verisimdb/gsa-verisimdb.container` |
| Backup quadlet | `container/verisimdb-backup/gsa-verisimdb-backup.container` |
| Icon assets | `assets/icon.svg`, `assets/icon-256.png` |
| AffineScript interface (pure TEA core) | `src/ui/tea/gsa_gui.affine` |
| AffineScript FFI layer (libgsa externs + cmd_*) | `src/ui/tea/gsa_ffi.affine` |
| AffineScript↔Zig symbol contract check | `scripts/affine-ffi-contract-check.sh` (`just affine-contract`; typecheck: `just affine-check`) |
| E2E test | `scripts/e2e-test.sh` |
| Gossamer chain test | `scripts/gossamer-integration-test.sh` |
| CLI binary | `src/interface/ffi/zig-out/bin/gsa` |
| Desktop entry | `game-server-admin.desktop` |

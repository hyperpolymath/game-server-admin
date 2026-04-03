# Test & Benchmark Requirements

## Current State (2026-04-03 blitz)

- **Unit tests**: 67 tests across 8 Zig modules (was: NONE)
- **Integration tests**: 39 tests in `test/integration_test.zig`
- **Smoke tests**: 5 end-to-end tests in `test/smoke_test.zig`
- **Total**: 111 Zig tests, all passing
- **Benchmarks**: NONE (planned)
- **Fuzz**: No harness yet (placeholder removed; see `tests/fuzz/README.md`)

## What Was Added (2026-04-03)

### Security Tests (server_actions.zig — 8 new tests)
- isLocalhost edge cases: IPv6, injection strings, whitespace, case
- parseAndDispatch: invalid JSON, empty JSON, unknown action/runtime
- ActionKind integer mapping verification
- executeAction: local podman, systemd journalctl paths

### Config Parser Edge Cases (config_extract.zig — 11 new tests)
- Empty/whitespace input handling
- XML self-closing and element patterns
- JSON nested object flattening, booleans, nulls
- parseAuto dispatch verification
- Secret detection for password/token/secret keys
- ParsedConfig.getField null for missing keys
- isNumeric edge cases

### Groove Client Tests (groove_client.zig — 4 new tests)
- Target registry overflow (MAX_TARGETS = 8)
- Buffer truncation for oversized name/host
- TargetStatus enum completeness
- Empty name/host edge cases

### A2ML Tests (a2ml_emit.zig — 7 new tests)
- applyDiff: key-value Modified/Added/Removed
- extractA2MLAttr and extractQuotedValue edge cases
- Secret redaction verification

### Bug Fixes
- Fixed `std.json.stringify` -> `std.json.fmt` (Zig 0.15.2 compat)
- Fixed `std.fs.exists` -> `fileExists` helper (Zig 0.15.2 compat)
- Fixed `std.fs.cwd().createFile` signature (Zig 0.15.2 compat)
- Fixed broken multiline string in CLI usage text
- Fixed stack-returning helper functions (undefined behavior)
- Fixed multiple missing `catch {}` on writeAll calls

## What's Still Missing

### Ephapax / GUI Tests
- Core: Types.eph, Capabilities.eph, Shell.eph, Bridge.eph, GrooveClient.eph
- GUI: main.eph, 7 panel .eph files
- JavaScript: 5 bridge/glue files
- These require Ephapax compiler + Gossamer runtime

### Idris2 ABI Tests
- Layout.idr postulate replaced with constructive proof (`alignUpCeil` + `alignUpCeilIsMultiple`)
- No compile-time Idris2 tests wired into CI yet

### End-to-End (E2E)
- [ ] Game server lifecycle: discover -> connect -> configure -> monitor -> restart
- [ ] Panel system: load panels -> display -> interact
- [ ] Groove integration: discover services -> negotiate capabilities
- [ ] Per-game profile: load -> apply -> verify
- [ ] VeriSimDB integration: store -> query -> dashboard

### Aspect Tests
- [ ] Performance: poll latency, multi-server dashboard rendering
- [ ] Concurrency: multiple server management, concurrent sessions
- [ ] Error handling: unreachable servers, auth failures, malformed responses
- [ ] Accessibility: keyboard navigation, screen reader, color contrast

### Benchmarks Needed
- Server status poll frequency vs latency
- Multi-server dashboard rendering time (10, 50, 100 servers)
- Shell command execution roundtrip time
- Groove service discovery latency

### Self-Tests
- [ ] panic-attack assail on own repo
- [ ] Server connectivity self-test
- [ ] Groove handshake self-test

## Priority
- **DONE** — Core Zig FFI modules now have comprehensive tests including security-critical command injection coverage
- **MEDIUM** — Ephapax/GUI tests (requires runtime tooling)
- **LOW** — Benchmarks, fuzz harness, E2E with live services

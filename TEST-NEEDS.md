# Test & Benchmark Requirements
## CRG Grade: C — ACHIEVED 2026-04-04

## Test Suite Summary

| Suite | Count | Location | Run command |
|-------|-------|----------|-------------|
| Unit tests | 67 | `src/interface/ffi/src/*.zig` (inline `test` blocks) | `zig build test` |
| Integration tests | 39 | `src/interface/ffi/test/integration_test.zig` | `zig build test-integration` |
| Smoke tests | 5 | `src/interface/ffi/test/smoke_test.zig` | `zig build test-smoke` |
| **Property tests** | **14** | `src/interface/ffi/test/property_test.zig` | `zig build test-property` |
| **Total tests** | **125** | | |

**Benchmarks**: 15 scenarios across 7 benchmark groups in `src/interface/ffi/bench/bench_main.zig`
Run with: `zig build bench`

## CRG C Requirements — Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Unit tests | DONE | 67 tests across 8 modules |
| Smoke tests | DONE | 5 end-to-end pipeline tests |
| Build | DONE | `zig build` clean (all 3 artefacts) |
| Property-based (P2P) | **DONE** | 14 invariant tests, P1–P14 |
| E2E | DONE | smoke_test.zig covers full pipeline |
| Reflexive | DONE | result code mapping, enum exhaustiveness |
| Contract | DONE | ABI integer mapping, secret redaction |
| Aspect | DONE | Security tests (command injection, injection strings) |
| Benchmarks | **DONE** | 15 scenarios, B1–B7 |

## Property Tests Added (2026-04-04)

File: `src/interface/ffi/test/property_test.zig`

14 property/invariant tests covering:

- **P1** `detectFormat` is total — never panics on any byte sequence in a 40-entry corpus
- **P2** `detectFormat` is deterministic — same input always yields same output
- **P3** `parseAuto` is total — never panics on valid or malformed inputs
- **P4** `parseAuto` field count is always >= 0 (consistent internal state)
- **P5** Config field keys are always non-empty after `addField`
- **P6** `getField` returns the exact value supplied to `addField` (insertion/lookup consistency)
- **P7** `ActionKind` values are injective — no two variants share an integer
- **P7b** `ActionKind` covers all 8 expected action types by name
- **P8** `GrooveTarget` fixed buffers never overflow on any input (clamping verified)
- **P9** `GrooveTarget` name/host round-trip for inputs that fit the buffer
- **P10** `ProfileRegistry.listProfiles` always returns valid JSON (empty or populated)
- **P11** Every inserted key is retrievable regardless of insertion order
- **P12** `field_type` is preserved exactly by `addField` (including empty string case)
- **P13** `ConfigFormat` values are injective — no two variants share a u8 value
- **P14** `parseAuto` is deterministic — two parses of the same input produce identical field lists

## Benchmarks Added (2026-04-04)

File: `src/interface/ffi/bench/bench_main.zig`

15 benchmark scenarios in 7 groups:

### B1 — Config format detection throughput
- B1a `detectFormat` small KV payload (~50 B): 100 000 iterations
- B1b `detectFormat` medium JSON payload (~300 B): 100 000 iterations
- B1c `detectFormat` large Lua payload (~2 KB): 100 000 iterations

### B2 — parseAuto dispatch latency per format
- B2a `parseAuto` KeyValue (small): 5 000 iterations
- B2b `parseAuto` JSON (medium): 5 000 iterations
- B2c `parseAuto` Lua (large): 5 000 iterations
- B2d `parseAuto` INI (medium): 5 000 iterations
- B2e `parseAuto` XML (medium): 5 000 iterations

### B3 — isLocalhost-equivalent batch validation
- B3 batch of ~80 addresses (including injection strings): 100 000 iterations

### B4 & B5 — ParsedConfig field operations
- B4 `addField` × 5 fields: 5 000 iterations
- B5 `getField` × 4 lookups (best/average/worst/miss): 100 000 iterations

### B6 — GrooveTarget buffer operations
- B6a `setName` + `setHost` + read (fits 64/256 B buffers): 100 000 iterations
- B6b Same ops with oversized strings (clamping path): 100 000 iterations

### B7 — ProfileRegistry serialisation
- B7a `listProfiles` on empty registry: 5 000 iterations
- B7b `listProfiles` with 1 registered profile: 5 000 iterations

## Current State (2026-04-04)

- **Completion**: 100% (all 15 phases complete)
- **Tests**: 125 Zig tests across 4 suites (unit: 67, integration: 39, smoke: 5, property: 14). All passing.
- **Benchmarks**: 15 scenarios across `bench/bench_main.zig`. `zig build bench` wired.
- **Build step**: `zig build test-property` and `zig build bench` both registered in `build.zig`.

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

## What's Still Missing (Post CRG-C)

### Ephapax / GUI Tests
- Core: Types.eph, Capabilities.eph, Shell.eph, Bridge.eph, GrooveClient.eph
- GUI: main.eph, 7 panel .eph files
- JavaScript: 5 bridge/glue files
- These require Ephapax compiler + Gossamer runtime

### Idris2 ABI Tests
- Layout.idr postulate replaced with constructive proof (`alignUpCeil` + `alignUpCeilIsMultiple`)
- No compile-time Idris2 tests wired into CI yet

### End-to-End (E2E) with Live Services
- [ ] Game server lifecycle: discover -> connect -> configure -> monitor -> restart
- [ ] Panel system: load panels -> display -> interact
- [ ] Groove integration: discover services -> negotiate capabilities
- [ ] VeriSimDB integration: store -> query -> dashboard

### Fuzz Harness
- No AFL/libFuzzer harness yet (placeholder removed)
- Priority targets: `detectFormat`, `parseAuto`, `parseA2MLProfile`

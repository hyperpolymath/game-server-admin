# Test & Benchmark Requirements

## Current State
- Unit tests: NONE
- Integration tests: 2 Zig integration tests (template-level)
- E2E tests: NONE
- Benchmarks: NONE
- panic-attack scan: NEVER RUN (feature dir exists but no report)

## What's Missing
### Point-to-Point (P2P)
13 Zig + 13 Ephapax + 3 Idris2 + 5 JS + 1 ReScript source files with ZERO functional tests:

#### Core (Ephapax — 6 files):
- Types.eph — no tests
- Capabilities.eph — no tests
- Shell.eph — no tests
- Bridge.eph — no tests
- GrooveClient.eph — no tests

#### GUI (Ephapax — 1 file):
- main.eph — no tests

#### Zig (13 files):
- Only 2 template integration tests

#### JavaScript (5 files):
- No tests

#### Idris2 ABI (3 files):
- No verification tests

### End-to-End (E2E)
- Game server lifecycle: discover -> connect -> configure -> monitor -> restart
- Panel system: load panels -> display server status -> interact
- Groove integration: discover services -> negotiate capabilities
- Shell execution: send command -> execute on server -> return output
- Per-game profile: load profile -> apply settings -> verify
- VeriSimDB integration: store server metrics -> query -> dashboard
- Clade system integration: classify servers -> manage taxonomy

### Aspect Tests
- [ ] Security (shell command injection — CRITICAL, server credential handling, Groove auth, capability escalation)
- [ ] Performance (server monitoring poll latency, multi-server dashboard rendering)
- [ ] Concurrency (multiple server management, concurrent shell sessions)
- [ ] Error handling (server unreachable, auth failure, malformed server response)
- [ ] Accessibility (admin panel keyboard navigation, screen reader, color contrast)

### Build & Execution
- [ ] zig build — not verified
- [ ] Ephapax compile — not verified
- [ ] GUI launches — not verified
- [ ] Shell command execution — not verified
- [ ] Self-diagnostic — none

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
- **HIGH** — Game server administration tool (13 Zig + 13 Ephapax + 5 JS files) with ZERO functional tests. The Shell.eph module that executes commands on remote servers is a massive security surface that is completely untested. Command injection testing is non-negotiable for any tool that runs shell commands on game servers.

## FAKE-FUZZ ALERT

- `tests/fuzz/placeholder.txt` is a scorecard placeholder inherited from rsr-template-repo — it does NOT provide real fuzz testing
- Replace with an actual fuzz harness (see rsr-template-repo/tests/fuzz/README.adoc) or remove the file
- Priority: P2 — creates false impression of fuzz coverage

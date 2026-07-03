<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# Contributing

GSA has a few non-obvious rules that exist for good reasons (a machine-checked
ABI, a tri-license policy, a security-sensitive exec boundary). Follow these and
your change will sail through CI; ignore them and CI will stop you — which is the
point.

## Build & test

Everything runs from `src/interface/ffi/`:

```bash
cd src/interface/ffi
zig build                    # libgsa.so + libgsa.a + gsa CLI
zig build test               # unit tests
zig build test-integration   # integration
zig build test-behavioral    # real sockets + C-ABI + HTTP deadline
zig build test-cli test-smoke test-property
zig build fuzz               # config-parser fuzz seed corpus
```

You need **Zig 0.15.2 exactly** (see [Installation](03-Installation.md)). The
full suite is ~167 tests across six suites; keep them all green.

<a id="tests"></a>
### The tests that matter most

- **The C-ABI end-to-end test** (`test/behavioral_test.zig`) drives the real
  exported symbols against in-process mock servers
  (`init → probe → close → double-close`). It's the highest-value test in the
  repo — it's where the original ABI bugs hid. If you touch the handle lifecycle
  or result codes, this is your regression net.
- **Behavioral HTTP tests** exercise the deadline gateway (hung endpoint returns
  within its deadline; default-deny opens no socket). Run under `testing.allocator`
  so leaks fail the test.

## The ABI contract — do not hand-edit generated tables

The Idris2 model is the **single source of truth**. If you change result codes or
struct layouts:

1. Edit `src/interface/abi/Types.idr` (codes) or `Layout.idr` (layout).
2. **Regenerate** the tables:
   ```bash
   zig run scripts/gen_result_codes.zig    # → result_codes_expected.zig
   zig run scripts/gen_abi_expected.zig     # → abi_layout_expected.zig
   ```
3. Reconcile the Zig side (`main.zig` `GsaResult`, the `extern struct`s) until it
   compiles — the comptime cross-check will tell you exactly what's off.
4. `abi-contract.yml` re-runs the generators and does `git diff --exit-code`, and
   type-checks the Idris model. Forgetting step 2 = red CI.

See [The Proven ABI](05-The-Proven-ABI.md) and
[`docs/developer/FFI-MODULE-REFERENCE.adoc`](../developer/FFI-MODULE-REFERENCE.adoc).

## Coding conventions

- **Exported FFI functions** are `pub export fn gossamer_gsa_… callconv(.c)` and
  prefixed `gossamer_gsa_`.
- **Result codes are contractual** — they must match `Types.idr`. Don't invent a
  new numeric code; add a variant on both sides and regenerate.
- **Secrets are redacted** as `[REDACTED]` everywhere they're emitted (A2ML,
  octad JSON). Config fields typed `secret` must never print in the clear.
- **No dangerous proof escapes** — `believe_me`, `assert_total`, `unsafeCoerce`
  and friends are banned; `panic-attack assail .` enforces this.
- **Outbound HTTP goes through `http_capability.call()`** — never call
  `std.http.Client.fetch` directly. Declare a capability with a `host_allow`,
  `deadline_ms`, and `purpose`.
- **Containers** use Podman + `Containerfile` + Chainguard Wolfi. Never Docker,
  never `Dockerfile`.
- **Machine-readable metadata** lives in `.machine_readable/` only, never the
  repo root (except the canonical `0-AI-MANIFEST.a2ml`).

## Licensing (tri-license — put the right SPDX header on new files)

| File kind | SPDX identifier |
|---|---|
| Code — `.zig` `.idr` `.eph` `.js` `.html` `.sh` | `AGPL-3.0-or-later` |
| Machine-readable — `.a2ml` `.contractile` `.ncl` | `MPL-2.0` |
| Docs — `.adoc` `.md` | `CC-BY-SA-4.0` |

Every new file starts with an `SPDX-License-Identifier:` line matching this table.
The rationale is in [`docs/legal/LICENSE-POLICY.adoc`](../legal/LICENSE-POLICY.adoc).

## Versioning

The canonical version is `main.zig`'s `VERSION` (currently `0.9.0`). If you bump
it, run `scripts/check_version_drift.sh` — CI runs it too and fails on any
location that drifts from the SSOT.

## Pre-commit

```bash
panic-attack assail .     # banned patterns, unpinned actions, proof escapes
just quality              # full quality sweep (fmt-check + lint + test)
```

If `panic-attack` isn't installed in your environment, that's fine — CI is the
enforcing gate (`static-analysis-gate.yml` / `governance.yml`). All third-party
GitHub Actions must be **SHA-pinned**. Details in
[`docs/maintainer/CI-CD-GUIDE.adoc`](../maintainer/CI-CD-GUIDE.adoc) and the
[`SECURITY-SCANNING-RUNBOOK.adoc`](../maintainer/SECURITY-SCANNING-RUNBOOK.adoc).

## Branch & PR flow

- Develop on a feature branch; open a **draft** PR.
- Keep PRs focused — one concern per PR makes review (and the ABI gate) tractable.
- CI must be green: the six test suites + the ABI contract + version-drift +
  security scans.
- Adding a game? Just drop a `profiles/<game>.a2ml` — see
  [Probing & Games](04-Probing-and-Games.md#adding-a-game).
- Adding a GUI panel? Follow
  [`docs/developer/PANEL-EXTENSION-GUIDE.adoc`](../developer/PANEL-EXTENSION-GUIDE.adoc).

## Where things live

The full doc map is [`docs/INDEX.adoc`](../INDEX.adoc); the codebase quick-context
is `.claude/CLAUDE.md`; AI agents should read `0-AI-MANIFEST.a2ml` first.

→ Back to [Home](Home.md)

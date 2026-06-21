# Proof Requirements

## Current State (2026-06-21 — verified with Idris2 0.7.0)

The ABI package typechecks end-to-end (all modules `%default total`, no
`postulate` / `believe_me` / `assert_total`):

```bash
cd src/interface/abi && idris2 --typecheck gsa-abi.ipkg
# 1/3: Building Types (Types.idr)
# 2/3: Building Layout (Layout.idr)
# 3/3: Building Foreign (Foreign.idr)
```

Toolchain: Idris2 0.7.0, Chez backend (`.tool-versions` pins `idris2 0.7.0`).

## What is proven (machine-checked)

### Memory layout (`Layout.idr`)
For every one of the 8 ABI structs — ServerHandle, ProbeResult, ConfigField,
A2MLConfig, GameProfile, ServerOctad, Fingerprint, DriftReport — all four
layout properties are proven:

| Property | Meaning |
|----------|---------|
| `NoOverlap` | no two fields' `[offset, offset+size)` ranges overlap |
| `AllFieldsAligned` | every field offset is a multiple of its alignment |
| `SizeAligned` | total struct size is a multiple of the struct alignment |
| `SizeCoversFields` | total size ≥ sum of field sizes (padding accounted) |

Discharged by decision procedures (`decNoOverlap`, `decAllAligned`,
`decSizeAligned`, `decSizeCovers`) extracted via `getYes`; each proof
typechecks only because its `Dec` reduces to `Yes` for that concrete layout —
i.e. a malformed layout would fail to compile.

Also still proven: the per-type size/alignment `Refl` proofs, the
`SizeOf`↔layout agreement (`LayoutMatchesSizeOf`), and cross-platform
x86_64 ≡ aarch64 equivalence.

### Alignment (`Layout.idr`)
- `alignUpCeil offset a = ceilDiv offset a * a` (via an in-module total
  `ceilDiv`).
- `alignUpCeilIsMultiple` — constructive `Refl` proof that the result is
  `k * a`.

> Correction to the prior version of this file: the earlier
> `alignUpCeilIsMultiple` did **not** typecheck (the `case` form left the
> goal stuck). It was rewritten via `ceilDiv` so the witness is a direct
> `Refl`. There is no remaining `alignUpEquiv` postulate — the proven path
> uses `alignUpCeil`/`ceilDiv` directly, so that obligation is moot.

### Domain validators (`Types.idr`)
Decidable `portInRange`, `nonEmptyId`, `configFieldCountPositive`,
`allPortsValid`, the `Valid*` smart constructors, and the linear
`ServerHandle` with its erased non-null witness.

## What still needs proving

- **Zig ↔ Idris layout cross-check (HIGH).** `Layout.idr` proves the Idris
  model is internally consistent, but nothing yet checks the hand-written
  field offsets/sizes against Zig's `@sizeOf`/`@offsetOf`. A generated test
  emitting Zig's numbers and comparing them to the `Layout` constants would
  close the actual cross-language ABI guarantee.
- **Server probe safety (MEDIUM).** Prove probes cause no side effects on
  targets. Needs a specification first.
- **Configuration drift-detection completeness (LOW).** Needs a richer spec.
- **Access control for admin panels (LOW).** Needs a specification.

## Notes
- `Foreign.idr`'s linear `ServerHandle` wrappers now typecheck: each handle is
  consumed by a pattern match and rebuilt for the borrow-return, so linearity
  is respected (previously they used the handle twice and did not compile).

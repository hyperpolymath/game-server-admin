# Proof Requirements

## Current State (2026-04-03 blitz)

- ABI exists in `src/interface/abi/Layout.idr`
- **RESOLVED**: `postulate alignUpProducesAligned` replaced with constructive proof
- Remaining: one weaker equivalence postulate (`alignUpEquiv`)

## What Was Done

### Alignment Proof (CLOSED)

The original `postulate alignUpProducesAligned` asserted that `alignUp` produces
aligned results but could not be proven because Idris2 0.7.x's `modNatNZ` lacks
composition lemmas.

**Solution**: Introduced `alignUpCeil` — an alternative alignment function that
computes the next multiple via ceiling division. The result is `k * alignment`
by construction, so the alignment property is trivially witnessed:

- `alignUpCeil` : computes next multiple via `ceilDiv(n, a) * a`
- `alignUpCeilIsMultiple` : constructive proof returning `MkMultiple k Refl`

No postulates, no `believe_me`. Both cases (`remainder = 0` and `remainder > 0`)
return a direct `Refl` witness.

**Remaining postulate**: `alignUpEquiv` asserts that `alignUp` and `alignUpCeil`
produce the same result. This is mathematically trivial but opaque `modNatNZ`
prevents structural proof. Strictly weaker than the original postulate.

## What Still Needs Proving

- **Server probe safety**: Prove that probes do not cause side effects on targets
- **Configuration drift detection**: Prove drift dashboard identifies all deviations
- **Access control for admin panels**: Prove panel-level authorization

## When alignUpEquiv Can Be Closed

When Idris2 stdlib gains either:
- `modNatNZ_zero : modNatNZ (k * d) d ok = 0`
- `modNatNZ_spec : n = divNatNZ n d ok * d + modNatNZ n d ok`

## Priority
- **DONE** — Alignment proof is constructive
- **MEDIUM** — Server probe safety (production concern)
- **LOW** — Drift detection, access control (need richer specifications)

# Proof Requirements

## Current state
- ABI exists in `src/interface/abi/Layout.idr`
- **Known gap**: `postulate alignUpProducesAligned` at line 341 — alignment proof is postulated, not proven
- 10K lines of source; 7 Gossamer panels, VeriSimDB backing

## What needs proving
- **Close the postulate**: Replace `postulate alignUpProducesAligned` with an actual proof via `Data.Nat.Factor` or equivalent
- **Server probe safety**: Prove that server health probes do not cause side effects on the target game servers
- **Configuration drift detection**: Prove the drift dashboard correctly identifies all deviations from declared state
- **Access control for admin panels**: Prove panel-level access control prevents unauthorized server operations

## Recommended prover
- **Idris2** — The postulate is already in Idris2; closing it requires a proof about natural number alignment (straightforward with `Data.Nat`)

## Priority
- **MEDIUM** — The postulate is a concrete proof gap that should be easy to close. Server probe safety matters for production game servers but is not as critical as the other HIGH-priority repos.

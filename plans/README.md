# fx-Recibú executor plans

Active Plan 002 baseline: reviewed verification-repair commit `3b17523` on 2026-07-11.
Plans 001/003 are completed execution records; their original upstream
planning snapshot `5ee2585` was imported as content, not as a Git object in
this repository.

| Order | Plan | Finding | Linear | Status |
|---|---|---|---|---|
| 1 | [001 — Credit installments only on full payment](001-credit-installments-only-on-full-payment.md) | CORRECTNESS-01 | [BU-336](https://linear.app/bufi/issue/BU-336) | COMPLETE — 131 Foundry tests plus four invariant campaigns green |
| 2A | [002 — Consume canonical receivables exactly once](002-enforce-unique-receivable-commitments.md) | SECURITY-02 | [BU-318](https://linear.app/bufi/issue/BU-318) → [BU-322](https://linear.app/bufi/issue/BU-322) | COMPLETE — keyless local conformance; production authority gate remains |
| 2B | [003 — Consolidate the canonical installment ledger](003-consolidate-canonical-installment-ledger.md) | ARCH-03 | [BU-336](https://linear.app/bufi/issue/BU-336) | COMPLETE — 146 Foundry tests green |

Plan 003 is already integrated. Execute Plan 002 only from its re-vetted
baseline as production-disabled local conformance, then re-run the full
Foundry and root aggregate suites. The independently owned authority artifact
remains mandatory before live activation; the executor may not create or
self-approve it.

## Execution rules

Run each plan's exact ancestry/drift check before editing. Keep execution
keyless: no credentials, paid services, deployments, broadcasts, pushes, or
live database/RPC writes. Update only the relevant status row here.

## Findings disposition

- CORRECTNESS-01, SECURITY-02, and ARCH-03 are selected and fully planned.
- Provider debt, liquidity, and Aave state are deliberately excluded; their
  canonical owner is `fx-recibu-loans` after its binding ADRs.
- No selected local finding was rejected. Any ambiguity in the
  authority-issued invoice identity is an explicit STOP, not a weaker hash
  fallback.

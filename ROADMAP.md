# fx-Recibú — ROADMAP

> **Authoritative** (with `SPEC.md`). Build order, milestone gates, and the definition of done. Do not start a milestone before the previous milestone's **exit gate** is green. Do not write a contract before its dependencies have passing tests. Ask before any architectural deviation from `SPEC.md`.

## Global rules (apply to every milestone)

- **Interface-first:** `src/interfaces/I<Contract>.sol` before `src/.../<Contract>.sol`.
- **ASCII data-flow diagram** in every contract header before any code.
- **Tests co-land:** `test/unit/<Contract>.t.sol` (always) + `test/fork/<Contract>.fork.t.sol` (whenever Morpho / USYC / external state is touched). Run `forge test --match-contract <Contract>` after each file; report results + deviations before moving on.
- **License headers** on every adapted file (see `docs/LICENSE_BOUNDARIES.md`). GPL-2.0 Morpho: interfaces only. AGPL Tinlake/Huma: browser-only, never in `src/`.
- **Legal boundary** (`docs/LEGAL_BOUNDARIES.md`): a contract may mark an invoice legally assigned only after the authorized issuer/servicer has attested the required document hashes.
- **Foundry profile:** solc 0.8.26, optimizer 200, `via_ir=true`, fuzz 256 default / 1024 CI / 10000 deep. RPCs: `arc_testnet`, `arc_mainnet`, local anvil.

---

> **Standing inputs:** `docs/GATEMAN_AUDIT.md` (F1–F9 corrections — F2 identity home-chain and F6 custody reality are already folded into SPEC §2/§8) and `docs/BUCKET_ANALYSIS.md` (scorecard ~42%; closure plan items 1–5 map to CP-1/HP1/M-seeding/§8.3/B3 work). Re-run the bucket analysis at each milestone gate; a milestone is not done if its bucket score didn't move.

## M0 — Preflight docs  ·  gate: all four docs complete & reviewed

Deliverables (no Solidity yet):
- `docs/ARCHITECTURE_SUMMARY.md` — dependency graph; every contract; every external dep; the full flow *invoice lock → advance → escrow repayment (installments) → settlement → reputation update* (mirror SPEC §2 flow + §3.6).
- `docs/LEGAL_BOUNDARIES.md` — assignment is off-chain; contracts automate accounting/settlement/reputation/tranche state only; required off-chain document hashes per invoice; recourse vs non-recourse (SPEC §3.3); servicer authority.
- `docs/THREAT_MODEL.md` — identity/reputation attacks, fake invoice, fake debtor acceptance, servicer abuse, refund/escrow early-withdrawal, NAV oracle manipulation, Morpho market risk, tranche accounting, cross-default griefing, RFQ/FX settlement manipulation, Uniswap v4 hook abuse, **credit-passport gaming (self-dealing rings, fabricated revenue, score farming, inbox poisoning, compromised scoring service — SPEC_CREDIT_PASSPORT §P6)**. **Each threat maps to the SPEC control that bounds it (§3.5 / §3.6 / §4.8 / §4.9 / §P6).**
- `docs/LICENSE_BOUNDARIES.md` — Apache/MIT attribution rule; GPL interfaces-only; AGPL browser-only; `reference-only/` never imported from `src/`.

**Exit gate:** the four docs exist and the THREAT_MODEL threat→control mapping is complete.

## M0.5 — Parameter pin  ·  gate: SPEC §8 has no unset params

Pin every protocol parameter referenced by SPEC §3–§4 into `SPEC.md §8` + a `script/Params.sol` constants library:
`RECIBU_L0`, `RECIBU_RAMP_STEP`, `RECIBU_RAMP_MAX_BPS_PER_EPOCH`, `RECIBU_MAX_DEBTOR_BPS`, `RECIBU_MAX_VELOCITY`, reserve ratios (10/15/20/25%), advance-rate bases (90/85/75/60%), `S_pair` penalty, installment cadence bounds + grace windows, insurance-fee bps, yield split (50/30/20).
**Exit gate:** no `[STUB]` param remains; `Params.sol` compiles.

---

## M1 — Identity layer  ·  gate: identity + attestation tests green

Contracts (adapt from `lib/erc-8004-contracts/`, MIT, attribute):
- `BUFIIdentityRegistry` — + authorized-issuer logic; **shares the `agentId` space with desk-v1 `@bu/contracts/erc8004`** (verify a desk-v1 `agentId` resolves identically).
- `BUFIReputationRegistry` — + attestation types `PERMANENT_DEFAULT`, `PAID_ON_TIME_CUMULATIVE`.
- `BUFIValidationRegistry`.
- `BUAttestation` — authorized writer, HSM signer pattern, EIP-712 typed attestations, replay-protected nonces.

**Exit gate:** unit tests for authorized-issuer gating, EIP-712 attestation verification, **replay rejection**, and `PERMANENT_DEFAULT` being terminal (cannot be un-set on the same identity).

## M2 — Tier registry  ·  gate: SPEC §3 matrix reproduced by tests

- `WorkspaceTierRegistry` — reads `BUFIReputationRegistry`; computes `tier(S_seller)`, `tier(S_debtor)`, `S_pair`; exposes advance-rate, reserve ratio, recourse eligibility, tranche eligibility, and the graduated cap `L(w)` (SPEC §3.1–§3.5) as view functions.

**Exit gate:** table-driven tests reproduce the SPEC §3.1–§3.4 matrices exactly; **fuzz test proves `L(w)` is monotonic and only increases via realized `PAID_ON_TIME_CUMULATIVE`, never via a score attestation alone** (SPEC §4.9 invariant, tier-registry half).

## CP-1 — Credit Passport v0 (runs alongside M1–M2)  ·  gate: attested score end-to-end

Off-chain + desk-v1 track (`SPEC_CREDIT_PASSPORT.md` §P1–§P4); on-chain surface is only what M1 already built.

- v0 **deterministic** score: extend the existing 8-component payment score with motora cash-flow and magic-inbox trade-doc components (§P1 sources 1–4); point-in-time-correct feature store (§P2).
- Scoring service publishes `SCORE_SNAPSHOT{S_seller, S_debtor, modelVersion, featureRootHash}` + `KYB_STATUS` via `BUAttestation` (HSM signer decided and documented — shiva vs dedicated worker).
- Passport UI: extend the desk-v1 payment-score widget with the new components + "what raises your score" attributions.

**Exit gate:** a real KYB'd workspace's score computes from live motora + inbox + invoice data, lands on-chain as a verifiable attestation, and `WorkspaceTierRegistry` (M2) reads it back into the correct tier. Anti-gaming checks from §P6 that apply to v0 (source diversity, pair caps) are implemented in the pipeline.

## M3 — Invoice core  ·  gate: lock/exposure/NAV invariants green

- `InvoiceShelf` — Tinlake-Shelf-*inspired* (no AGPL copy); single owner of locked invoices; per-tier accounting; installment schedule (SPEC §3.6). `lockInvoice` gated by `WorkspaceOperatingReserve` **and** the §3.5 caps (aggregate `L(w)`, debtor concentration, velocity).
- `BIFTranche` ×3 (bIF-A/B/C) — ERC-20, 18-dec, mint/burn only by `InvoiceShelf`, no fee-on-transfer.
- `BUFIOracle` ×3 — implements Morpho `IOracle`; per-tranche NAV per **SPEC §6**.
- `OraclePauser` — >10% intra-block move circuit breaker.

**Exit gate — the fraud-containment invariants must pass here:**
- `invariant_atRiskExposureNeverExceedsLimit`: for all `w`, `atRiskExposure(w) ≤ L(w)` (SPEC §4.9).
- `invariant_outstandingAdvanceAccounting`: each lock books the full advance immediately; payments reduce it dollar-for-dollar; the first uncured miss writes off all then-outstanding principal (SPEC §3.6). v1 has no staged-drawdown or installment-size loss bound.
- `invariant_seniorNavParUnlessJuniorExhausted`: bIF-A NAV stays at par until bIF-C then bIF-B assets hit zero (SPEC §6.2 subordination).
- `lockInvoice` rejects: over-`L(w)`, over-concentration, over-velocity, missing bond for weak tier (SPEC §3.2/§3.5).

## M4 — Defaults stack  ·  gate: waterfall invariant green

- `WorkspaceOperatingReserve` — per-tier ratios 10/15/20/25%; posted-bond vs accrued (SPEC §3.2); swept on default **before** any LP tranche (SPEC §4.8 layer 2).
- `InflowDivertHook` — MSCA policy module; 25% diversion to debt service (recourse, SPEC §3.3).
- `CrossDefaultRegistry` — one-way flip on default; blocks residual release across all of the workspace's open invoices.
- `RestructureRouter` — ops-multisig-gated; writes `RESTRUCTURED` instead of `PERMANENT_DEFAULT`; **refuses to reclassify fraud** (SPEC §3.3).

**Exit gate:** `invariant_recoveryWaterfallOrder` — losses consume holdback → reserve → recourse → bIF-C → bIF-B → bIF-A in strict order, never skipping a layer (SPEC §4.8); cross-default freeze proven to net across a workspace's open invoices before any senior loss.

## M5 — Payment rails  ·  gate: escrow-safety invariants green

- `InvoiceMemoRouter` — adapt `circlefin/recibo` `Recibo.sol` (Apache, attribute); destination hardcoded to `ReceivableEscrow.deposit()`; structured-memo schema **matching desk-v1 `apps/cre/workflow-recibo-invoice`** (invoiceHandle, workspace agentId, invoiceId, workspaceId, debtorId, settlement ref).
- `ReceivableEscrow` — Refund-Protocol-*inspired* (do **not** copy blindly); per-tier lockups from `WorkspaceTierRegistry`; `settle()` → `InvoiceSettlement`; idle → Morpho idle-USDC market; yield split 50/30/20 (D20).
- `InvoiceSettlement` — orchestrator: apply inflow to earliest open installment (SPEC §3.6) → atomic Morpho repay → bIF-X burn → reputation event → recovery waterfall (SPEC §4.8).

**Refund-Protocol hardening (exit-gate invariants, SPEC §4.9 prevention line):**
- Identify + redesign/remove the early-withdrawal path.
- `invariant_arbiterCannotWithdrawUnrelatedFunds`.
- `invariant_everyEscrowAmountIsInvoiceBound` — every deposit/refund/withdrawal/settlement carries an `invoiceId`/`paymentId` binding; no unbound balance can exist.
- Arbiter permissions separated from fund custody.

## CP-2 — Offer engine + label capture (runs alongside M3–M5)  ·  gate: multisig offer end-to-end

- **Offer engine** (§P5): on invoice `accepted` between two KYB'd workspaces, compute `offer = advanceRate × face`, clipped by `L(w)` headroom, debtor-concentration, velocity, and tranche liquidity; surface the *"Get $X today"* card in the desk-v1 private-multisig approval inbox; rejection path shows which score component blocks and how to improve it.
- **Label capture**: Arc `Memo` installment events (SPEC §5.1) + bINV lifecycle events (SPEC §9) flow into the feature store as ground-truth labels (§P3) — the dataset ML v1 will train on starts accumulating **now**.
- Offer acceptance path wired: multisig signs → document attestations → `InvoiceShelf.lockInvoice` (M3) → advance.

**Exit gate:** full happy path on `arc_testnet` — accepted invoice → offer card → multisig accept → lock → advance → installment paid via Memo → `PAID_ON_TIME_CUMULATIVE` increments → next offer for the same workspace reflects the improved passport. Offer engine provably refuses: unKYB'd counterparty, `L(w)` breach, ring-flagged pair.

## M6 — LP product  ·  gate: allocation + cap tests green

- `BUFICreditVault` — MetaMorpho v1.1 via `MetaMorphoV1_1Factory`; allocates M1/M2 (fx-Telaraña) + M3/M4/M5 (fx-Recibú); BUFI Treasury MSCA curator; 10% performance fee.

**Exit gate:** fork test proves supply/allocation across M3/M4/M5, curator cap enforcement, and that senior-market (bIF-A) allocation cannot be drained by a junior-market loss.

## M7 — Uniswap v4 settlement-guard hook  ·  gate: guard reverts proven

- `RecibuSettlementGuardHook` — beforeSwap-first (SPEC §7 / build-prompt §9). Guards invoice-settlement FX only; **no rehypothecation in the hook** (idle escrow → Morpho from `ReceivableEscrow`/`MorphoVaultAdapter`).

**Exit gate:** unit tests prove `beforeSwap` reverts on every invalid state (non-whitelisted caller, bad `invoiceId`/status, cross-default flagged, stale oracle, TWAP deviation, slippage, wrong recipient) and `afterSwap` emits `RecibuFxSettlementSwap` + routes output only to `ReceivableEscrow`/`InvoiceSettlement`. Cross-reference `docs/THREAT_MODEL.md` "Uniswap v4 hook abuse".

## M8 — Deployment & testnet  ·  gate: Arc testnet dry-run green

Scripts:
- `DeployIdentity.s.sol`
- `DeployFactoringStack.s.sol` — InvoiceShelf + 3× BIFTranche + 3× BUFIOracle + settlement.
- `DeployMorphoMarkets.s.sol` — `createMarket` M3/M4/M5; **mandatory 1e9 share burn to `0xdEaD` after each market** (Morpho inflation front-run mitigation).
- `DeployVault.s.sol` — BUFICreditVault + initial caps.

**Exit gate:** full lifecycle dry-run on `arc_testnet` — lock a test invoice → advance → pay 2 of 3 installments → miss the 3rd → waterfall recovery → reputation update — with all §3.5/§3.6/§4.8/§4.9 invariants asserted on-chain.

## CP-3 — Passport ML v1 + portability (post-M8)  ·  gate: champion promoted with governance

- **ML v1** (§P3): gradient-boosted model with monotonic constraints, trained exclusively on the CP-2 label stream; champion/challenger backtests; drift monitors; ops human-review promotion; `modelVersion` in every attestation.
- **EAS mirroring**: mirror `SCORE_SNAPSHOT` / repayment attestations to Ethereum Attestation Service schemas — the passport becomes portable beyond BUFI (§P4).
- **Passport export**: workspace-facing verifiable artifact (`featureRootHash` Merkle proofs for invoice-level history).
- Capped update per epoch enforced (a score cannot jump tiers in one step — mirrors SPEC §3.5).

**Exit gate:** v1 beats v0 on backtested calibration without violating monotonic constraints; promotion runbook executed once end-to-end; an attestation mirrored to EAS resolves against the same `agentId` identity.

---

## Cross-cutting: audit readiness (continuous)

- Every fraud-containment invariant (§3.5 cap, §3.6 outstanding-advance accounting, §4.8 waterfall, §4.9 exposure) has a named `invariant_*` test that runs in the deep (10000-run) profile in CI.
- Coverage target ≥90% on `src/` before audit freeze.
- Freeze date & scope tracked against the fx-Recibú audit application (mirrors the fx-Telaraña audit discipline).

## Sequencing summary

```
Contracts track (strictly gated, sequential):
M0 docs → M0.5 params → M1 identity → M2 tier(§3) → M3 invoice-core(+fraud invariants)
      → M4 defaults(waterfall) → M5 rails(escrow-safety) → M6 LP vault → M7 v4 guard hook → M8 deploy+testnet

Credit Passport track (off-chain + desk-v1, runs in parallel, joins at gates):
CP-1 v0 score+attestation ═(needs M1, feeds M2)═ CP-2 offer engine+labels ═(needs M3+M5)═ CP-3 ML v1+EAS (post-M8)
```

Milestones are gated, not parallel *within a track*: a red exit gate blocks the next milestone. Cross-track joins: **M2's tier tests consume CP-1 attestations; CP-2's offer path requires M3 `lockInvoice` and M5 memo rails; CP-3 requires the M8 testnet label stream.** The fraud-containment invariants (M3/M4) and the CP anti-gaming pipeline checks (CP-1/CP-2 gates) are hard go-live blockers regardless of feature completeness.

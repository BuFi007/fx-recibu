# fx-Recibú — SPEC_CREDIT_PASSPORT

> **Authoritative** for the AI/ML payment-score engine ("Bu Credit Passport"). Companion to `SPEC.md`: that file consumes scores; this file defines how scores are produced, attested, and kept honest. The scoring engine is **off-chain ML + on-chain attestation** — no contract in `SPEC.md` ever computes a score, and no score alone ever raises credit exposure (SPEC §4.9 invariant: only *realized repayment* moves `L(w)`).

## §P0. What the Credit Passport is

A per-workspace, portable, attested credit artifact: **verifiable transaction history + repayment behavior**, built from everything a KYB'd workspace does inside desk-v1, distilled to the dual score (`S_seller`, `S_debtor`, `S_pair`) that prices factoring in `SPEC.md §3`, and published on-chain as HSM-signed EIP-712 attestations (ERC-8004-compatible; EAS-publishable later without redesign).

**Closed-loop by design (v2v).** Only desk-v1 workspaces that have **passed KYB/compliance** participate. Both sides of every scored invoice are known, verified entities. The product motion:

1. Workspace onboards → KYB approved → passport opens at zero history.
2. We **guide them to build the score**: connect bank accounts (motora), connect email (magic inbox), invoice other workspaces, pay on time. The UI shows the score, its components, and what raises it.
3. Once an invoice is **accepted** by a KYB'd counterparty workspace, the offer engine (§P5) can surface — in the desk-v1 **private-multisig approval inbox** — *"You can receive $X today for this invoice"*, where X is computed from both workspaces' passports.
4. Every repayment updates both passports. The passport compounds; leaving the platform abandons it — that is the retention mechanic and the collateral-substitute (SPEC §3.2).

## §P1. Data sources (all existing desk-v1 infrastructure)

| # | Source | System (real paths) | Signals extracted |
|---|---|---|---|
| 1 | **Bank transaction history + enrichment** | `apps/motora` — unified Plaid / Teller / GoCardless / Pluggy engine; `src/utils/enrich.ts`, `providers/company-data` | verified cash-flow (inflow/outflow levels, volatility, runway), counterparty enrichment, revenue seasonality, balance coverage of upcoming obligations |
| 2 | **Magic inbox (AR/AP open inbox)** | `apps/app/.../inbox/*` (OAuth email connect, `api/inbox/connect`, `retry-matching`, `promote`) + `workflows/inbox-document-intelligence.ts` (AI attachment/document processing) + `api/payables/receipts/.../match` | invoices received/sent outside BUFI, due dates vs. actual payment dates from statements/receipts, dispute signals, document-verified trade volume with off-platform counterparties |
| 3 | **Invoicing module lifecycle** | `packages/invoice` + `apps/worker` queues (generate/schedule/remind/settle) + CRE `workflow-recibo-invoice` / `workflow-invoice-settle` | issued→accepted→paid funnel, acceptance latency, reminder counts, partial payments, recurring-invoice regularity |
| 4 | **Financial analytics (20+ existing metrics)** | `apps/app/src/components/financial-analytics/` — financial-health score tabs, transaction-categories, accounts/balances, and the 8-component payment score (`payer_ratio` 20, `payer_timeliness` 20, `biller_collection` 20, `biller_timeliness` 10, `consistency` 10, `volume` 10, `relationship` 5, `recency` 5) | the v0 score baseline + health-score features (category concentration, expense discipline, balance trends) |
| 5 | **On-chain repayment behavior** | Arc `Memo` events (predeploy `0x5294E9927c3306DcBaDb03fe70b92e01cCede505`) keyed by `memoId = keccak(invoiceId ‖ installment)` + **bINV lifecycle events** (SPEC §9) + desk-v1 paid events (Circle webhook → `invoices.status='paid'`, `apps/shiva/routes/webhook/circle.ts`). NOT the CRE workflows — those run on ethereum-sepolia and are dormant (prod trigger commented out); adopt as optional reinforcement only (SPEC §2/§5.4) | ground-truth settled installments — the only source allowed to move `L(w)` |
| 6 | **Compliance state** | desk-v1 KYB pipeline | binary gate + entity metadata (jurisdiction, age, sector) |

**Consent + privacy boundary:** sources 1–2 are user-connected (OAuth) and revocable. Raw bank/email data **never leaves the scoring pipeline and never goes on-chain** — on-chain artifacts are scores, tier, `L(w)`, and document *hashes* only.

## §P2. Feature pipeline

```
motora tx stream ─┐
magic inbox docs ─┤→ enrichment + entity-resolution (counterparty graph, dedupe)
invoice events  ─┤→ feature store (per-workspace, per-pair, point-in-time correct)
analytics metrics┤→   ~40 features across 5 families:
on-chain events ─┘      F1 cash-flow (motora)   F2 trade-docs (inbox)
                        F3 invoice funnel        F4 behavioral (analytics)
                        F5 realized repayment (on-chain — ground truth)
```

Rules:
- **Point-in-time correctness**: every feature is computed as-of the scoring timestamp (no lookahead) so training labels are honest.
- **Pair features**: for every workspace pair (A,B) with history, compute `S_pair` inputs (count, value, on-time ratio, tenure of relationship, dispute count).
- **Source-diversity feature**: how many independent sources corroborate the workspace's activity. A workspace whose "revenue" appears only in self-issued invoices (no motora inflows, no inbox docs) scores structurally lower — the primary anti-fabrication lever.

## §P3. Model

**v0 (already running — deterministic):** the production score is server-computed, not a UI artifact: Postgres RPC `get_team_payment_score_v1` on a daily 07:00 UTC cron with a 12-month lookback, persisted to `team_payment_score_snapshots` (`packages/trigger/tasks/analytics/payment-score-scheduler.ts`); the financial-health composite (`get_runway_v8`, `get_profit_v7`, `get_revenue_v7`, `get_growth_rate_v4` → `team_financial_health_snapshots`) runs at 06:00 UTC. **v0.5 (ships with CP-1):** extend this engine with motora cash-flow and inbox trade-doc feature families — both pipelines are real (`apps/motora/src/utils/enrich.ts` LLM enrichment; `inbox-document-intelligence.ts` + scored receipt matcher) but neither currently feeds the score. Transparent, explainable, already rendered in the UI.

**v1 (ML):** gradient-boosted model (monotonic constraints on key features) predicting `P(all installments of next funded invoice pay on time)`.
- **Labels:** realized installment outcomes from source 5 only (on-chain, tamper-evident). No label from self-reported data.
- **Outputs:** `S_seller`, `S_debtor` (0–100, calibrated), plus per-feature attribution (SHAP-style) surfaced in the UI as "what raises your score".
- **Constraints:** monotonic in on-time ratio, cash-flow coverage, source diversity; capped update per epoch (a score cannot jump tiers in one step — mirrors SPEC §3.5 ramp).
- **Governance:** champion/challenger with backtests; drift monitors on feature distributions; human review (ops) required to promote a model version; every attestation records `modelVersion`.

**Hard guardrail (repeat of SPEC §4.9):** the score prices terms (advance rate, discount, recourse, tranche); it never unilaterally raises `L(w)`. ML can be fooled; the exposure ramp can only be earned by settled installments.

## §P4. Attestation layer ("the passport" on-chain)

- **Home chain = Arc** (SPEC §2, GATEMAN F2). `BUAttestation` publishes EIP-712 typed attestations, HSM-signed by the scoring service, replay-protected, into `BUFIReputationRegistry` on Arc. The desk-v1 ERC-8004 registries (read-only surface, ethereum/avalanche family, `0x8004A1…`/`0x8004BA…`) are **mirror targets only**. The old write path died with deprecated `desk-v1/packages/intelligence` (its successor `@bufinance/intelligence` carries no on-chain code — GATEMAN_AUDIT A1-RESOLVED), so **`BUAttestation` on Arc is the ecosystem's first identity write path**; the `workspaceId → arcAgentId` mapping table owned by the attestation service is the join, not an assumed shared id space.
- **Attestation types:** `SCORE_SNAPSHOT{S_seller,S_debtor,modelVersion,featureRootHash}`, `PAID_ON_TIME_CUMULATIVE`, `PERMANENT_DEFAULT`, `RESTRUCTURED`, `KYB_STATUS`.
- `featureRootHash` = Merkle root of the feature vector → the workspace can later *prove* what its passport contained at scoring time (dispute resolution, portability) without revealing raw data.
- **EAS compatibility:** schema is designed so the same attestations can be mirrored to Ethereum Attestation Service on any EAS-supported chain later — the passport is portable beyond BUFI, which is the "credit passport" promise.

## §P5. Offer engine (the multisig moment)

Trigger: invoice `accepted` by a KYB'd counterparty workspace (both passports exist).

```
offer = advanceRate(tier(S_debtor), S_pair)          // SPEC §3.1
        × faceValue
        , clipped by: L(seller) headroom             // SPEC §3.5
                      debtor-concentration cap
                      velocity cap
                      tranche availability (bIF-A/B/C liquidity in BUFICreditVault)
terms = { discount, N installments, recourse flag, bond requirement }   // SPEC §3.2–§3.6
```

Surfaced as a card in the desk-v1 **private-multisig approval inbox** (`components/multisig/multisig-approval-inbox.tsx` surface): *"Get $8,500 today for invoice #2026-0001 (face $10,000) — 3 installments, repaid by Acme Corp's payments. Your score: 74 (Strong). Accept?"* Acceptance = the multisig signs → `InvoiceShelf.lockInvoice` path begins (document attestations per SPEC §7 legal boundary). If no valid offer exists, the same card shows **why** (score component + what to improve) — that is the "guide them to a good score" loop.

**Second surface — conversational (Eve).** The offer is also deliverable through Eve (`bu-intelligence-agent`: Discord/Slack/web, authenticated userId→team→wallet, live). Implementation: add `get_factoring_offer` + `accept_advance` as `BuTool`s in **`@bufinance/intelligence`** (the published brain — Eve auto-inherits every tool); `accept_advance` never executes directly — it files the multisig op (dual control per SPEC §8.3.5), mirroring the existing gated approve-in-chat pattern (`agent/tools/ops_approve.ts`, `kawaii_gate.ts`). Eve asks; the multisig decides.

**Score + prize mechanics — reuse the tournament repo (verified templates):** the on-chain half of the passport score follows `fx-telarana-tournament/contracts/src/hub/KawaiiPower.sol` — soulbound by construction (no transfer/approve path), earned-never-bought, Merkle epoch checkpoints, bounded seasonal decay. The on-time-repayment prize pool follows `TournamentPrizePool.sol` — USYC-yield-funded via the live `FxReserveYieldRouter 0x623d…8b06`, KYC-gated, on-chain `splitBps`, pull-claims, `unclaimedLiability` solvency invariant. Adapt these contracts; do not parallel-build.

## §P6. Anti-gaming (assume adversarial workspaces)

| Attack | Control |
|---|---|
| Self-dealing ring (A invoices B, B invoices A, wash repayments) | counterparty-graph analysis (cycle detection, shared beneficial owners from KYB); pair-level caps; ring-flagged pairs excluded from `S_pair` and from `PAID_ON_TIME_CUMULATIVE` credit |
| Fabricated revenue | source-diversity requirement (§P2): invoices uncorroborated by motora inflows or inbox documents carry near-zero weight |
| Score farming with micro-invoices | on-chain line credit requires a realized installment ≥$250, is capped to 20% of the epoch-start line per 30-day epoch, and pair history requires a fully settled ≥$250 invoice; velocity caps still apply (SPEC §3.5) |
| Data poisoning of the inbox (fake emails/PDFs) | document-intelligence cross-checks (issuer domain age, statement reconciliation against motora); inbox-only signals never move `L(w)` |
| Compromised scoring service | HSM signing + attestation nonces; on-chain ramp invariant bounds the blast radius of any fake score to pricing (not exposure); `OraclePauser`-style anomaly alerts on attestation patterns |
| Stolen session / account takeover at the offer moment | **Verified gap: no device fingerprinting or actor binding exists anywhere in the ecosystem today.** Launch precondition (SPEC §8.3.4): device/session binding on offer acceptance + payout-address changes; dual-control multisig acceptance (§8.3.5) as the compensating control until then |
| Compliance theater | Screening code exists but ships flag-OFF (`CIRCLE_COMPLIANCE_ENABLED`); §8.3.1 makes flag-ON a launch precondition — the passport never scores an unscreened actor |

### §P6.1 What the score composes with (real, live defenses — verified paths)
The passport is one layer of a stack that already exists: fail-closed velocity limits (`packages/kv/src/velocity-core.ts`, $50k/day wallet · $500k/week team, enforced in `transfer.controller.ts`), fail-closed rate limiting (shiva + pasillo tiers), webhook signature verification + Circle IP allowlisting, mandatory idempotency keys (pasillo), the vendor compliance allowlist (`payable_vendors.compliance_status`), Persona/Alfred KYB with UBO linkage, and the UAFE guaranteed-delivery audit queue pattern. `L(w)` composes **on top of** these floors; it never replaces them.

## §P7. Deliverables & sequencing (extends ROADMAP)

- **CP-1 (with M1–M2):** v0 deterministic score + `SCORE_SNAPSHOT` attestations + passport UI (extend existing payment-score widget with motora/inbox components).
- **CP-2 (with M3–M5):** offer engine wired to the multisig inbox; on-chain label capture (installment outcomes → feature store).
- **CP-3 (post-M8):** ML v1 champion/challenger; EAS mirroring; passport export.

# fx-Recibú — SPEC

> **Authoritative.** This file + `ROADMAP.md` govern implementation. Where a contract comment and this file disagree, this file wins. Sections marked `[STUB]` are not yet authoritative and must be filled before the contracts they govern are built.

fx-Recibú is the on-chain **invoice factoring / receivables credit engine** for BUFI's existing invoicing module (`desk-v1`). Workspaces with a strong **payment score** sell **accepted** invoices for instant USDC liquidity, funded from BUFI's shared LP (`BUFICreditVault`, MetaMorpho v1.1, markets M3/M4/M5). Advances are priced and sized by the **dual payment score** of *both* the seller (collection reliability) and the debtor (payer reliability).

**Design axiom (read first): fraud will happen.** No attestation stack is perfect. The protocol is therefore designed for **prevention + containment + recovery**, and every parameter below is chosen so that the *maximum loss from any single fraudulent workspace or debtor is bounded, small, and slow to build up to* — see §3.5 (graduated exposure), §3.6 (installment amortization), §4.9 (fraud-tolerance model).

---

## §0. Slaying Moloch — why this protocol exists (normative framing)

> After Kevin Owocki, *Onchain Capital Allocation* — Moloch is the god of coordination failure: every situation where individually rational moves produce a collectively ruinous equilibrium.

Credit in Argentina is scarce not because Argentines don't produce — Buenos Aires works for the world — but because **nobody can afford to trust**. The lender can't verify the invoice. The debtor's payment history is trapped in a bank silo, a WhatsApp thread, an email inbox. Fraud pays, because defection is cheap, anonymous, and non-terminal: burn one counterparty, open a new CUIT, repeat. Every honest SME prices in everyone else's defection. That is Moloch's equilibrium, and it taxes every corridor invoice at double-digit rates or starves it of credit entirely.

The coordination failure is already visible **on our own chain**: the canonical Morpho markets on Arc hold **~$300k of third-party USDC supplied at 0 borrows — 0% utilization** (`arc-canonical-morpho-markets` manifest). Lenders showed up. Borrowers can't, because no mechanism converts *"this workspace pays its invoices"* into *"this workspace can borrow."* fx-Recibú is that mechanism.

How the machine inverts the equilibrium — each mechanism maps to a Moloch failure mode:

| Moloch's move | Protocol counter-move | Where |
|---|---|---|
| Trust is unverifiable → nobody extends credit | The Credit Passport: verifiable transaction history + repayment behavior, attested on-chain | `SPEC_CREDIT_PASSPORT.md` |
| Defection is cheap and repeatable | `PERMANENT_DEFAULT` is terminal on a KYB'd identity (Persona/Alfred UBO-linked — a new shell ≠ a new reputation); exposure `L(w)` is **earned only through realized repayment**, never bought, never attested into existence | §3.5, §4.9 |
| Fraud's payoff exceeds its cost | Installment amortization bounds any theft to ~one installment window minus the workspace's own posted first-loss; building a fraudulent line costs more time than it yields | §3.6, §4.9 |
| Cooperation doesn't compound | Every on-time installment raises `L(w)`, improves terms, and is publicly provable — the honest path is the profitable path, visibly | §3.5, §P5 |
| Value extraction masquerades as yield | Rebates and prizes are funded by real T-bill yield on real idle capital (the live, entitled USYC router), never emissions, never the next depositor | §5.3, B9 evidence |
| Records serve the powerful | Regulator-grade, guaranteed-delivery audit trail (the UAFE queue+DLQ pattern already running in fx-pasillo) + public attestation proof pages | §8 preconditions |

**Design law:** every parameter in this spec must make cooperation the dominant strategy for a rational actor in a high-fraud environment — and must assume the attacker is smart, local, and patient. When a mechanism protects the protocol at the honest user's expense, the mechanism is wrong.

## §1. Overview (AUTHORITATIVE)

fx-Recibú delivers two things, natively on Arc:

1. **SME Credit Passport** — a verifiable, attested credit history per workspace, built from bank-transaction enrichment (motora), the AI accounts-receivable inbox (magic inbox), the invoicing module, 20+ existing financial-analytics metrics, and on-chain repayment behavior. Spec: **`SPEC_CREDIT_PASSPORT.md`** (authoritative companion).
2. **Invoice factoring / receivables financing with automated repayment waterfalls** — tokenized accepted invoices (§9 bINV standard), advances priced by the dual passport score (§3), amortized installments (§3.6), escrowed stablecoin settlement over Arc Memo rails (§5), and the six-layer recovery waterfall (§4.8), funded from BUFI's shared DeFi liquidity (`BUFICreditVault`, MetaMorpho v1.1 — the same vault allocating to fx-Telaraña M1/M2 in `defi-web-app` protocol liquidity).

**v2v closed loop (hard gate):** participation requires a KYB/compliance-approved desk-v1 workspace on **both** sides of the invoice (`KYB_STATUS` attestation, §P4). fx-Recibú v1 does not finance invoices from or to unverified entities. The product motion: onboard → build the passport → invoice another workspace → on acceptance, the offer engine (§P5) surfaces *"you can receive $X today for this invoice"* in the desk-v1 private-multisig approval inbox → multisig accepts → `lockInvoice` → advance.

Actors: **seller/workspace** (KYB'd, holds a passport), **debtor workspace** (KYB'd, holds a passport), **LP** (via `BUFICreditVault` tranches), **servicer/scoring service** (HSM-attested, off-chain), **ops-multisig** (restructures, pauses).

## §2. Identity & Reputation (AUTHORITATIVE — corrected per GATEMAN_AUDIT F2)

**Home chain = Arc.** The source of truth for fx-Recibú identity + reputation is `BUFIIdentityRegistry` / `BUFIReputationRegistry` / `BUAttestation` **deployed on Arc**, where the credit, settlement, and Memo rails live.

**ERC-8004 reality check (verified + A1-resolved, do not re-assume):** the ecosystem's only **live** ERC-8004 surface is the read path (`packages/contracts/src/erc8004/`, ethereum/avalanche family, default **ethereum-sepolia**, registries `0x8004A169…432` / `0x8004BAa1…b63`), consumed as reads via hyper-mcp by Eve. The old base/baseSepolia write path lived in `desk-v1/packages/intelligence` — **deprecated; it did not migrate** into the published `@bufinance/intelligence` (which is the pure AI brain, zero on-chain code). **There is no live identity write path today** (GATEMAN_AUDIT A1-RESOLVED). Therefore:
- Arc registries are canonical; `BUAttestation` on Arc is the ecosystem's **first** identity write path — greenfield, no legacy divergence to reconcile.
- The ethereum-family ERC-8004 registries are **read-side mirror targets** (CP-3), never the source of truth.
- The desk-v1 `agentId` mapping is maintained by an explicit `workspaceId → (arcAgentId, erc8004AgentId?)` table owned by the attestation service — not by assuming one shared id space.

Scores are computed **off-chain** (per **`SPEC_CREDIT_PASSPORT.md`** §P2–§P3) and land on-chain only as **HSM-signed, replay-protected EIP-712 attestations** (`SCORE_SNAPSHOT`, `PAID_ON_TIME_CUMULATIVE`, `PERMANENT_DEFAULT`, `RESTRUCTURED`, `KYB_STATUS` — §P4). Settlement ground truth = **Arc Memo events + bINV lifecycle events** (§5.1, §9). No contract self-computes a score. Attestation schema is EAS-compatible so the passport is portable (§P4).

### §2.1 Intelligence & attestation layers — Eve, `@bufinance/intelligence`, CRE (AUTHORITATIVE)

**The brain (verified 2026-07-01):** `@bufinance/intelligence` **v0.3.2** (npm; source `bufinance-publish/intelligence`) is the consolidated "one brain" per its `CONSOLIDATION.md`: **framework-neutral AI tool definitions (33 `BuTool`s incl. `get-invoices`), the SOUL persona, the agent-loop config, arbitration, knowledge-graph, locale, and one-shot services — with ZERO on-chain code** (no viem/ethers; data access is HTTP to hyper-mcp + Shiva). It deprecates and replaces `desk-v1/packages/intelligence`. Consequence (GATEMAN A1-RESOLVED): the old base/baseSepolia ERC-8004 write path died with the deprecated package; **`BUAttestation` on Arc is the ecosystem's first identity write path.**

**The channel adapter:** Eve (`bu-intelligence-agent`) is the runtime — Discord / Slack / web, authenticated userId→team→wallet, consuming the brain's tools plus ~100 hyper-mcp trading/lending tools (Arc 5042002 default). fx-Recibú ships its agent surface as **`BuTool`s in the brain package** (`get_factoring_offer`, `accept_advance` — §P5); Eve inherits them automatically. `accept_advance` never executes: it files the multisig op (dual control, §8.3.5).

**CRE (Chainlink Runtime Environment) — role and verdict:**
- **v1: NOT a dependency.** Repayment ground truth is already tamper-evident on-chain (Arc Memo + bINV events) — a DON adds nothing to an on-chain fact. Score attestations are HSM-signed, and the §3.5/§4.9 invariant already bounds a compromised scorer to *pricing*, never *exposure*. CRE is also not yet available on Arc (desk-v1's workflows run on ethereum-sepolia, dormant, prod trigger commented out).
- **v2: the decentralization path for the attestation layer.** When CRE reaches Arc, its role is to convert "BUFI's HSM says" into "a DON quorum attests" — directly countering the *compromised scoring service* and *compliance theater* threat rows (§P6): (a) DON-verified `SCORE_SNAPSHOT` (quorum re-validates the published `modelVersion` against the `featureRootHash`); (b) document-existence attestation (invoice/assignment `receiptHash` — the pattern `workflow-recibo-invoice` already implements); (c) **cross-chain mirroring** of Arc attestations to the ethereum-family ERC-8004 registries (CP-3); (d) upgrading desk-v1's existing catalog (`workflow-invoice-settle`, `workflow-balance-attestation`, `workflow-transfer-verify`, `workflow-fee-reconciliation` — `packages/cre/src/constants.ts`) from dormant to passport data-source verifiers.
- **Design rule (encode in M1):** `BUAttestation` attestations carry a pluggable `verifierKind ∈ {HSM_EOA, DON_REPORT}` with an upgradeable verifier — CRE slots in **without a schema change** when it lands on Arc. Until then: dormant, never load-bearing.

---

## §3. Credit Engine — dual score → terms (AUTHORITATIVE)

### §3.0 Inputs

All 0–100, sourced from the desk-v1 payment-score model
(`desk-v1/apps/app/src/components/financial-analytics/components/invoices/payment-score/`), attested via `BUAttestation`:

| Symbol | Meaning | desk-v1 components (weights) |
|---|---|---|
| `S_debtor` | **Payer** reliability — will the invoice get paid? | `payer_ratio` (20), `payer_timeliness` (20) — normalized to 0–100 |
| `S_seller` | **Biller** reliability — collection + fraud/moral-hazard risk | `biller_collection` (20), `biller_timeliness` (10), `consistency` (10), `volume` (10), `relationship` (5), `recency` (5) — normalized to 0–100 |
| `S_pair` | Seller↔debtor relationship history (prior invoices between the two) | derived; 0 if no history |

**Tier bands (match desk-v1 exactly):** `Excellent ≥85 · Strong ≥70 · Moderate ≥50 · Developing <50`.

> **Role split (the core rule):** the **debtor** score prices the money (advance rate / discount / whether non-recourse exists), because the debtor is who repays. The **seller** score prices the *trust* (reserve, bond, recourse, tranche, exposure cap), because the seller is who can defraud or must buy back. A great seller with a weak debtor still gets a small, recourse-only, junior-funded advance — and vice-versa.

### §3.1 Advance rate (LTV) — a function of the debtor

`advanceRate = base(tier(S_debtor)) − pairPenalty(S_pair)`

| `tier(S_debtor)` | Base advance rate | Notes |
|---|---|---|
| Excellent | 90% | |
| Strong | 85% | |
| Moderate | 75% | |
| Developing | 60% | recourse-only; junior tranche only; often rejected |

`pairPenalty`: if `S_pair == 0` (no prior history between this seller and debtor), subtract 5% and force the invoice through the graduated-exposure cap (§3.5) at the *new-relationship* ceiling. This is the single biggest fake-debtor-collusion lever — an unknown seller↔debtor pair can never draw a large first advance.

The `1 − advanceRate` **holdback** is released to the seller only on full collection (§4). The holdback absorbs **dilution** (short-pay, disputes, credit notes) and is the seller's per-invoice skin-in-the-game. **This is a haircut, not posted collateral.**

### §3.2 Operating reserve & bond — a function of the seller

`WorkspaceOperatingReserve` target ratio and how it is funded:

| `tier(S_seller)` | Reserve ratio | Funding | Bond required before `lockInvoice` funds? |
|---|---|---|---|
| Excellent | 10% | accrued from spread | No |
| Strong | 15% | accrued from spread | No |
| Moderate | 20% | 50% posted USDC bond + 50% accrued | Partial |
| Developing / first-time | 25% | 100% posted USDC bond | **Yes — full** |

**This is the collateral answer.** Good-score sellers are **capital-light**: reputation substitutes for collateral and the reserve self-funds from fee spread. Weak/new sellers must **post a USDC bond** = `reserveRatio × outstandingAdvance` before `InvoiceShelf.lockInvoice` will release funds. The reserve is first-loss and is **swept on default before any LP tranche is touched** (§4.8, layer 2).

> Full over-collateralization is deliberately *not* required — it would defeat the purpose of factoring (a workspace factors precisely because it lacks working capital). The reserve/bond scales *down* to zero as the score earns it.

### §3.3 Recourse vs non-recourse

- **Non-recourse** (LP eats a *credit* default, not fraud) is offered **only if** `S_debtor ≥ Strong AND S_seller ≥ Strong AND S_pair > 0`. Priced with a higher discount + insurance-fee contribution (§4.9).
- **Otherwise recourse:** on default the seller owes the advance back; enforced by `InflowDivertHook` (25% of the workspace's future inflows) + `CrossDefaultRegistry` (freezes all residual releases) + reputation clawback.
- Fraud is **always recourse regardless of flag** — a `PERMANENT_DEFAULT` attributable to a fake invoice / fake acceptance voids any non-recourse protection (documented in `LEGAL_BOUNDARIES.md`; enforced by `RestructureRouter` refusing to reclassify fraud).

### §3.4 Tranche placement — combined risk

Which `BIFTranche` (funded from which Morpho market) may finance the invoice:

| Condition | Eligible tranche(s) |
|---|---|
| `S_debtor ≥ Strong AND S_seller ≥ Strong AND S_pair > 0` | bIF-A (senior), or B/C |
| Exactly one of the two is Moderate | bIF-B (mezzanine), or C |
| Any party Developing, or `S_pair == 0`, or first-time workspace | **bIF-C (junior) only** |

Senior LPs are structurally shielded: thin-history and weak-score deals are absorbed by junior first-loss capital before senior is exposed.

### §3.5 Graduated exposure — the fraud ramp (AUTHORITATIVE)

> Because fraud will pass attestation, the ceiling on *how much* a single workspace can ever be exposed for is the primary loss bound.

`WorkspaceTierRegistry` maintains a per-workspace **aggregate outstanding cap** `L(w)`, independent of any single invoice's face value:

- **Cold start:** a new/Developing workspace begins at `L0` (small, e.g. protocol-param `RECIBU_L0`, target ~$1–2k equivalent) *regardless of invoice size*. A $500k first invoice from an unknown workspace funds at most `L0`.
- **Ramp:** `L(w)` increases only as `PAID_ON_TIME_CUMULATIVE(w)` rises, by a **bounded step per settled installment** and a **max slope** (`RECIBU_RAMP_STEP`, `RECIBU_RAMP_MAX_BPS_PER_EPOCH`). The line cannot jump; it must be *earned* through realized on-time repayments, not attested scores alone.
- **Debtor concentration:** no single debtor may back more than `RECIBU_MAX_DEBTOR_BPS` (e.g. 30%) of `L(w)`. Blocks the "spin up one fake debtor and scale" attack.
- **Velocity:** max new advances per epoch (`RECIBU_MAX_VELOCITY`). Blocks burst-and-run.
- **Design target:** parameters chosen so the *time-and-cost to build a fraudulent line exceeds its payoff*. Building trust is slow and honest; cashing it out is one-shot and reputation-terminal.

`InvoiceShelf.lockInvoice` MUST reject any advance that would push aggregate outstanding above `L(w)`, breach debtor concentration, or exceed velocity.

### §3.6 Installment repayment — amortized recovery (AUTHORITATIVE, Exa Card / Exactly pattern)

> Reference model: **Exactly Protocol** fixed-rate **fixed-maturity** pools and the **Exa Card** "pay in installments" flow. Adapting that here is the core *containment* mechanism.

An advance is **not** a single bullet due at invoice maturity. It is split into `N` **installments**, each with its own **fixed maturity** (aligned to the debtor's payment schedule / net-terms milestones, or a synthetic BNPL-for-B2B schedule the ERP offers the debtor):

- Each installment maps to a fixed-maturity slot (a Morpho market maturity or a scheduled `ReceivableEscrow` sweep). `InvoiceSettlement` applies each Recibo-memo inflow to the **earliest open installment** for that invoice.
- **Reputation is incremental:** each on-time installment ticks `PAID_ON_TIME_CUMULATIVE`, which is what raises `L(w)` in §3.5. Trust compounds per-installment, not per-invoice.
- **Blast-radius bound (the whole point):** at any instant a workspace's *at-risk* exposure ≈ `installmentSize × (open installments within grace)`, **not** full invoice face. A fraud or default is surfaced at the **first missed installment**, so realized loss on a fraudulent invoice ≈ one installment window, not 100% of face.
- **Miss → escalate:** a missed installment past its grace window flips the invoice risk-state → triggers `CrossDefaultRegistry` (freeze all the workspace's residuals) → runs the §4.8 waterfall on the *outstanding* balance only.
- **Recourse buyback** (recourse mode) is likewise amortized: the seller repays the outstanding advance in installments funded from `InflowDivertHook` diversions — matching the Exa Card "installments" UX for the seller side.

`N`, installment cadence, and grace window are set at lock time from `tier(S_seller)`/`tier(S_debtor)` (weaker → more, smaller installments → tighter blast radius).

### §3.7 Multi-stablecoin denomination — StableFX invoices (AUTHORITATIVE, corrected per GATEMAN_AUDIT F4/F5)

Invoices may be denominated in any **StableFX asset with a live Arc financing rail**, not just USDC. The advance is disbursed **in the invoice's denomination asset** by borrowing it from the fx-telarana asset-loan Morpho markets — these are **already deployed on canonical MorphoBlue** (`0x65f435…`, LLTV 86%, `arc-asset-loan-morpho-markets-5042002.json`); they need seeding + SDK registration, not new protocol:

| Denomination | Financing rail (borrow asset vs USDC collateral) | Oracle mark | v1 status |
|---|---|---|---|
| USDC | direct from vault/tranche | n/a | **primary** |
| EURC | market `0xc33f06…7426` | Pyth EURC/USD | v1 |
| MXNB | market `0xcbc017…69a0` | Pyth USD/MXN inv. + manual MXN feed | v1 |
| QCAD | market `0x0094d4…532a` | manual CAD/USD (cron-fresh) | v1 |
| AUDF | market `0xbef2a3…9536` | Pyth AUD/USD + manual | v1 |
| cirBTC | market `0x4c5cc6…a3cb` | Pyth BTC/USD 24/7 | v1 (thin) |
| JPYC | **none on Arc** (no canonical JPYC token; markets are Fuji M5/M6) | — | **DEFERRED** |

Mechanics:
- **Exposure accounting stays in USD:** `L(w)`, concentration, and velocity caps (§3.5) are computed on the USD mark of the denomination asset at lock time, re-marked at each installment.
- **FX risk is the borrower's hedge, not the LP's:** the tranche lends USDC-collateralized borrow positions; a denomination-asset advance is oracle-marked debt in that asset, so LP exposure to the FX pair is bounded by the Morpho LLTV (86%) + the §4.8 waterfall.
- **Settlement conversion** (debtor pays in a different StableFX than the denomination) routes through the guarded FX leg: fx-telarana pools via `RecibuSettlementGuardHook` (§7) or the institutional RFQ (fx-pasillo StableFX RFQ + Permit2), with TWAP/oracle deviation checks. Depth honesty: live pool junior depth is ~$5–10k per pair — per-invoice conversion caps MUST respect it until deepened.
- **desk-v1 wiring gap (owned by CP-2/M8, not assumed):** invoice **prod** currency support is USDC/EURC only (`PROD_SUPPORTED_CURRENCIES`); the full StableFX registry exists (`packages/transfer-utils/src/stable-tokens.ts`) but templates, balance checks (`accept-and-pay.tsx:544`), and validation are USDC/EURC-hardcoded. Lifting this gate (enum + rendering + per-asset balance + settlement rail) is an explicit deliverable, feature-flagged per asset.

---

## §4. Settlement & Recovery (AUTHORITATIVE)

### §4.1–§4.7 `[STUB]`
Lock, advance disbursement, escrow accounting, per-installment `settle()`, NAV interaction (§6), fee/discount accrual, holdback release. Bind to: `InvoiceMemoRouter` (Recibo memo → `ReceivableEscrow.deposit`), `ReceivableEscrow` (per-tier lockups, idle→Morpho, 50/30/20 yield split), `InvoiceSettlement` (atomic Morpho repay → bIF-X burn → reputation event).

### §4.8 Recovery waterfall (AUTHORITATIVE)

On a missed installment past grace (or invoice default), recover the **outstanding** balance (never more than remains) in strict order. Senior LP principal is only ever touched after four buffers are exhausted:

```
default / missed installment (outstanding balance O)
  1. Per-invoice HOLDBACK           — unreleased reserve on this invoice        [absorbs dilution]
  2. WorkspaceOperatingReserve      — seller first-loss (posted bond + accrued)  [§3.2]
  3. RECOURSE clawback              — InflowDivertHook (25% of workspace inflows)
                                       + CrossDefaultRegistry freeze/net across
                                       ALL of the workspace's open invoices      [§3.3]
  4. bIF-C  junior tranche          — protocol/insurance first-loss LP           [§4.9 insurance]
  5. bIF-B  mezzanine tranche
  6. bIF-A  senior tranche          — LP principal; reached only if 1–5 < O
```

`InvoiceSettlement.recover()` implements this per SPEC §3.4 tranche of the invoice. `CrossDefaultRegistry` is a **one-way flip**: once a workspace defaults, residual release is blocked across *all* its open invoices so recovery can net across them before any LP loss is booked.

### §4.9 Fraud-tolerance model (AUTHORITATIVE)

Three lines of defense; assume the first is sometimes beaten:

1. **Prevention** — ERC-8004 identity; debtor-acceptance attestation; invoice + assignment document hashes; HSM-signed score attestations; `InvoiceMemoRouter` structured-memo binding (invoiceId/workspaceId/debtorId on every deposit); refund-path hardening on `ReceivableEscrow` (invoiceId/paymentId binding on every deposit/refund/withdrawal/settlement; arbiter perms separated from custody).
2. **Containment** — graduated exposure cap `L(w)` (§3.5); installment amortization (§3.6); debtor-concentration + velocity limits; junior-tranche placement for thin history (§3.4); per-workspace operating reserve (§3.2). **Net effect: max loss per fraudulent workspace ≈ `min(L(w), installmentSize × openInstallments)`, minus its posted bond + reserve.**
3. **Recovery** — the §4.8 waterfall; `CrossDefaultRegistry`; recourse clawback; `PERMANENT_DEFAULT` reputation burn (terminal — the workspace's line goes to zero and cannot be rebuilt on the same identity).
4. **Insurance buffer** — a protocol insurance fund (junior bIF-C + a settlement/insurance fee skimmed in `InvoiceSettlement` / the `RecibuSettlementGuardHook` `afterSwap`) sized to cover *expected* fraud loss at target volume, so realized fraud within the modeled bound never reaches senior LPs.

**Invariant (must be an on-chain invariant test):** for any workspace `w`, at all times
`atRiskExposure(w) ≤ L(w)` **and** `L(w)` is monotonic-increasing only via realized `PAID_ON_TIME_CUMULATIVE`, never via a score attestation alone. A fraud can cost at most the current `L(w)` less the workspace's own posted first-loss — a known, bounded, pre-funded number.

---

## §5. Payment rails — Arc-native Memo + Recibo (AUTHORITATIVE)

fx-Recibú runs natively on Arc and uses **two complementary memo rails**:

### §5.1 Arc `Memo` predeploy — the reconciliation rail

Arc ships a predeployed `Memo` contract (`0x5294E9927c3306DcBaDb03fe70b92e01cCede505` on Arc Testnet; USDC `0x36000…0000`). `Memo.memo(target, data, memoId, memoData)` forwards the inner USDC `transfer` **preserving the payer as sender** and emits an indexed `Memo(sender, target, callDataHash, memoId, memo, memoIndex)` event.

Binding rules:
- **`memoId = keccak256(invoiceId ‖ installmentIndex)`** — every installment payment is a Memo-wrapped USDC transfer, queryable later by `memoId` alone (indexed field) with no tx hash needed.
- `memoData` carries the **public** structured reference: `bINV` handle, workspace `agentId`s, settlement reference (schema shared with desk-v1 CRE `workflow-recibo-invoice`).
- `InvoiceMemoRouter` (build-prompt Step 5) is the `target`-side receiver: it validates the memo schema, matches `memoId` to an open installment in `InvoiceShelf`, and forwards funds to `ReceivableEscrow.deposit()` with the invoiceId/paymentId binding (§4.9 prevention). Unmatched memos land in a quarantine bucket, never in tranche accounting.
- The `Memo` event stream **is** on-chain data source #5 of the credit passport (§P1): settled installments are read from these events — tamper-evident ground truth for `PAID_ON_TIME_CUMULATIVE`.

### §5.2 Recibo — the encrypted-payload rail

`circlefin/recibo` (Apache-2.0, adapt with attribution) adds **encrypted** memo payloads for ERC-20 transfers. Use where the memo must carry private business data (line items, counterparty terms, dispute references) that must not be public on-chain. Public reconciliation stays on §5.1; sensitive payloads ride Recibo encryption. One payment MAY emit both (Arc Memo for indexing, Recibo payload for the encrypted document reference).

### §5.3 Escrow & settlement

- `ReceivableEscrow` — Refund-Protocol-*inspired* with the hardening list (build prompt Step 5): per-tier lockups from `WorkspaceTierRegistry`; idle escrow → Morpho idle-USDC market; yield split 50/30/20 (D20); every escrowed amount invoice-bound.
- `InvoiceSettlement` — applies each memo inflow to the **earliest open installment** (§3.6) → atomic Morpho repay → bIF-X burn → reputation event → waterfall on shortfall (§4.8).
- **Orchestration pattern (adopt, don't reinvent):** fx-pasillo's `SettlementOrchestrator` Durable Object is the proven shape for the off-chain leg — one DO per settlement, crash-safe state in DO storage, alarm-based polling, **zero-tolerance amount matching** (`AMOUNT_TOLERANCE_CENTS = 0`), per-step idempotency keys, persist-ID-before-work. fx-Recibú's off-chain settlement daemon reuses this pattern (and the `BufxKeeperLock` mutex for keeper serialization).

### §5.4 Corrections vs v1 spec (GATEMAN_AUDIT F1)

- The desk-v1 CRE workflows do **not** drive Arc settlement: `workflow-invoice-settle` attests Supabase invoices and `workflow-recibo-invoice` attests `BuInvoiceRecibo.sol` state, both on **ethereum-sepolia**, both **dormant** (prod trigger commented out). They are optional reinforcement, never the ground-truth rail. Ground truth = Arc Memo events (§5.1) + bINV lifecycle events (§9).
- The memo schema must stay compatible with **both** the desk-v1 shiva payment paths (Circle webhook → `invoices.status='paid'`, external-wallet tx verification) and the Arc Memo rail, so a desk-v1-paid invoice and an Arc-settled installment write the same passport event.
## §6. NAV / Oracle (AUTHORITATIVE)

One `BUFIOracle` deployment per tranche market (M3→bIF-A, M4→bIF-B, M5→bIF-C). Each implements Morpho Blue `IOracle` and prices its tranche token (the Morpho *collateral*) in USDC (the Morpho *loan asset*). **NAV is push-based from `InvoiceShelf` accounting — it is not a traded market price**, so it is not directly manipulable by a swap; the attack surface is the *timing/authorization* of the inputs (loss booking, reserve credit), guarded by §6.5 + `OraclePauser`.

### §6.1 What the oracle prices

`price()` returns **NAV per tranche token**: the recoverable USDC value backing the tranche, divided by the tranche token supply, in Morpho's fixed-point convention.

### §6.2 Tranche asset accounting (subordinated)

`InvoiceShelf` maintains, per tranche `T ∈ {A,B,C}`, in USDC smallest units (1e6):

```
trancheAssetsUSDC(T) = principal(T)          // advances funded from T, at outstanding balance
                     + accrued(T)            // fees + Morpho/idle yield attributed to T
                     - loss(T)               // realized losses ALLOCATED to T by the §4.8 waterfall
                     + reserveCredit(T)      // operating-reserve / insurance top-ups routed to T
   (floored at 0)
```

**Subordination is enforced in loss allocation, not in the oracle:** realized losses fill `loss(C)` until `trancheAssetsUSDC(C)==0`, then `loss(B)`, then `loss(A)` (matches §4.8 layers 4→5→6). Consequently:
- **bIF-A NAV stays at par** (`price ≈ 1.00 USDC/token, adjusted for accrued`) until *both* junior and mezzanine assets are exhausted. This is the `invariant_seniorNavParUnlessJuniorExhausted` gate in ROADMAP M3.
- **bIF-C absorbs first**, so its NAV moves first and most.

`yield/interest` distributes top-down per D20 (A then B then C by the 50/30/20 split feeding `accrued(T)`); `losses` fill bottom-up (C→B→A). Opposite directions — that is the tranche.

### §6.3 Morpho `IOracle.price()` formula

Morpho's `ORACLE_PRICE_SCALE = 1e36`, and a market computes borrowable value as
`value_loan_smallest = collateral_smallest · price / 1e36`.
With collateral = bIF-T (18 dec) and loan = USDC (6 dec):

```
price(T) = trancheAssetsUSDC(T) * 1e36 / trancheSupply(T)
```

where `trancheAssetsUSDC(T)` is 1e6-scaled and `trancheSupply(T)` is the bIF-T ERC-20 supply (1e18). This yields `price = navPerWholeToken(USDC) * 1e24`, i.e. a bIF-T worth exactly 1.00 USDC prices at `1e24`. Guard `trancheSupply(T) == 0 → revert` (empty tranche has no price).

### §6.4 Worked examples

**Baseline (par).** bIF-A market. `principal(A)=1,000,000e6`, `accrued(A)=12,000e6`, `loss(A)=0`, `reserveCredit(A)=0`, supply `1,000,000e18`.
`trancheAssetsUSDC(A)=1,012,000e6` → `price = 1,012,000e6 · 1e36 / 1,000,000e18 = 1.012e24`. NAV = **1.012 USDC/token** (par + accrued).

**Junior absorbs a loss.** bIF-C market, supply `200,000e18`, `principal(C)=200,000e6`, `accrued(C)=6,000e6`. A `$50,000` realized loss lands. Waterfall has already consumed holdback + reserve + recourse; the residual `50,000e6` allocates to C first:
`trancheAssetsUSDC(C)=200,000e6+6,000e6−50,000e6=156,000e6` → `price = 156,000e6·1e36/200,000e18 = 0.78e24`. bIF-C NAV = **0.78 USDC/token**. bIF-A/B unchanged at par — senior is untouched because `trancheAssetsUSDC(C) > 0` after the hit.

**Loss exceeds junior (spills to mezz).** Same C, loss `$220,000`. `loss(C)` caps at `206,000e6` (drives C to 0); the `14,000e6` remainder allocates to `loss(B)`. C prices at `0` (fully written down), B's NAV drops by `14,000e6/supply(B)`, A still par. This is the `invariant_seniorNavParUnlessJuniorExhausted` case.

### §6.5 `OraclePauser` — circuit breaker

`price(T)` is checked against the last-block value; a **>10% intra-block move** trips `OraclePauser`, which forces Morpho actions on that market to revert until an ops review clears it. Rationale: NAV should move smoothly (accrual + discrete, waterfall-ordered loss events); a >10% single-block jump implies a mis-booked loss/reserve-credit or a compromised writer, not real economics. Pausing fails safe (no borrow/liquidation at a bad NAV) rather than mismarking.

### §6.6 Manipulation notes (for THREAT_MODEL "NAV oracle manipulation")

- NAV inputs are writable only by `InvoiceShelf`/`InvoiceSettlement` under authorized-writer gating; no external actor can move `price()`.
- `reserveCredit(T)` inflation is the subtle vector (fake top-up → inflated senior NAV → over-borrow): require every `reserveCredit` to be backed by a real USDC transfer into the reserve and bound by the §3.2 ratio; assert `Σ trancheAssetsUSDC ≤ realUsdcUnderManagement` as an invariant.
- Loss-booking *delay* (hiding a default to keep NAV high) is bounded by §3.6: a missed installment auto-flips risk-state on-chain at its fixed maturity, so loss recognition is not discretionary.
## §7. Uniswap v4 settlement-guard hook `[STUB — see build prompt §9]`
## §8. Deployment, parameters & LAUNCH PRECONDITIONS (Argentina posture)

Protocol params to pin (M0.5): `RECIBU_L0`, `RECIBU_RAMP_STEP`, `RECIBU_RAMP_MAX_BPS_PER_EPOCH`, `RECIBU_MAX_DEBTOR_BPS`, `RECIBU_MAX_VELOCITY`, reserve ratios (10/15/20/25%), advance-rate bases (90/85/75/60%), `S_pair` penalty, installment cadence bounds + grace windows, insurance-fee bps, yield split (50/30/20), per-pair FX conversion caps (§3.7).

### §8.1 Vault & liquidity substrate (corrected per GATEMAN_AUDIT F3)
`BUFICreditVault` = a **Morpho Vault V2** instance via the factories already live on Arc — `VaultV2Factory 0x6b7F638B64539F83810A1f6ea81C703b561C3Be6` + `MorphoMarketV1AdapterV2Factory 0x9372EbEDF2C64344817c67dAeD99512F4b9DC434` (NOT MetaMorpho v1.1; no v1.1 factory exists on Arc). Allocation targets: canonical fx-Telaraña markets (CANON_*) + fx-Recibú tranches (M3/M4/M5). Interim/alternative senior substrate: `SharedFxVault 0x0E63eff2…` senior tranche (par-USDC, Morpho-rehypothecating, already live). Internal recipe doc: `defi-web-app docs/MORPHO_ARC_V2_UNLOCK.md`.

### §8.2 Custody reality for enforcement hooks (corrected per GATEMAN_AUDIT F6)
Default workspace custody = **single-key Circle DCW (custodial)** on `ETH-SEPOLIA / MATIC-AMOY / AVAX-FUJI`; MSCA multisig is real but opt-in (`wallets.custody_model` default `'dcw'`); login identity = SIWE EOA (`@bufinance/web3-signin`). Therefore:
- `InflowDivertHook` **v1 is a custody-layer policy**, enforced in shiva at the Circle-wallet level (ops-wallet policy bands + budget ledger + Address Book plugin) and via Circle **Gateway** sweep for the desk-v1→Arc capital leg — NOT an on-chain module on a wallet the workspace doesn't hold.
- The on-chain ERC-6900 diversion module is **v2**, gated on workspaces opting into modular (MSCA) custody with Arc support verified.
- The desk-v1→Arc bridge uses the existing `packages/circle-kit` Gateway unified-balance + CCTP rails.

### §8.3 Launch preconditions — non-negotiable in a high-fraud environment (GATEMAN_AUDIT F8)
1. **`CIRCLE_COMPLIANCE_ENABLED=true`** in every factoring environment — the screening code is wired (transfer/bill/ramps controllers) but ships flag-OFF as an APPROVED no-op. Factoring never launches with screening off.
2. **KYB-approved on BOTH sides** (`alfred_teams.kyb_status='approved'` + UBO complete) as a hard gate on offer generation — not just on payout.
3. **Velocity limits composed into `L(w)`**: the live fail-closed limits ($50k/day wallet, $500k/week team — `packages/kv/src/velocity-core.ts`) are a floor; factoring exposure adds its own cap, never relies on theirs alone.
4. **Actor binding**: device/session fingerprinting for offer-acceptance and payout-address changes — **no implementation exists anywhere in the ecosystem today** (verified gap); provider decision required before mainnet.
5. **Dual control**: factoring offers accepted only through the multisig approval inbox (weighted threshold), even for single-owner workspaces (owner + BUFI co-sign policy at launch).
6. **Guaranteed-delivery audit**: every advance/installment/default event flows through a pasillo-pattern audit queue + DLQ (UAFE-grade), regulator-readable.
7. **Payout-address allowlist**: advances disburse only to the workspace's verified Circle wallet or Address-Book-allowlisted addresses.
8. **AFIP path stated**: v1 operates on contractual assignment (LEGAL_BOUNDARIES.md) without factura-electrónica integration — but the spec commits to an AFIP/comprobante verification adapter as a passport data source before ARS-corridor scale (vision gap #1).

---

### Worked example (ties §3–§4 together)

Seller *Strong* (S_seller 74), debtor *Strong* (S_debtor 76), `S_pair > 0`. Invoice face **$10,000**, net-60, split into `N = 3` monthly installments.

- Advance rate 85% → **$8,500** advanced now; **$1,500** holdback retained.
- Seller reserve 15%, accrued (no bond). Tranche: bIF-A eligible. Non-recourse eligible (both Strong + history) but priced with insurance fee; assume seller picks recourse for a lower discount.
- Exposure check: `$8,500 ≤ L(w)` and `≤ 30%` debtor concentration — passes.
- Installments: 3 × ~$2,833 outstanding-amortizing, each a fixed maturity. **At-risk exposure is ever only ~one installment (~$2.8k), not $10k.**
- Debtor pays installments 1 & 2 on time → `PAID_ON_TIME_CUMULATIVE += 2`, `L(w)` steps up. Debtor misses installment 3.
- Recovery on the **outstanding ~$2,833**: holdback ($1,500) → operating reserve → recourse inflow-diversion → (only if still short) junior tranche. Senior bIF-A principal is untouched. Seller's score takes the default hit; if the invoice/debtor is proven fake, `PERMANENT_DEFAULT` zeroes the line.

Loss to LPs from a fully fraudulent version of this invoice ≈ **one installment window minus posted first-loss**, surfaced within ~30 days — not $10k at net-60.

---

## §9. bINV — the BUFI Invoice Standard (AUTHORITATIVE, v0.1)

Our own tokenized-invoice standard, so accepted receivables become a **DeFi-legible asset class** (Morpho collateral today via bIF tranches; composable beyond BUFI tomorrow). Reference patterns studied: Chainlink's onchain-factoring and invoice-tokenization/trade-finance writeups, Request Network's invoice object model, Tinlake NFT-per-asset, Huma receivable factoring (all reference-only per license rules).

- **Form:** ERC-721, one token per **accepted** invoice, minted by `InvoiceShelf` at lock, burnt at final settlement or write-off. Soulbound-by-default in v1 (transfer restricted to the shelf) — the *tranches* (bIF-A/B/C) are the fungible DeFi surface, not the invoice itself.
- **On-chain fields:** `invoiceId`, seller/debtor `agentId`s, face value + currency, issue/due dates, installment schedule (N, maturities, grace), status enum (`Accepted → Funded → PartiallyPaid → Settled | Defaulted | Restructured`), advance terms (rate, discount, recourse flag, tranche), and the **document-hash bundle** required by the legal boundary (§7 of the build prompt): invoice doc hash, receivables-assignment hash, payment-instruction hash, servicing + dispute policy hashes.
- **Off-chain payload:** the full invoice document (desk-v1 `packages/invoice` format) + assignment agreement, content-addressed; on-chain holds hashes only.
- **Event surface (indexer-first):** `InvoiceMinted/Funded/InstallmentPaid/InstallmentMissed/Settled/Defaulted/Restructured`, each carrying `invoiceId` + `memoId` linkage so the Arc Memo stream (§5.1), the passport (§P1 source 5), and the bINV lifecycle reconcile 1:1.
- **Why a standard and not just internal state:** (a) auditability — one schema for auditors/LPs to price; (b) the credit passport's `featureRootHash` can prove invoice-level history; (c) future venues (other lenders, secondary markets) can consume bINV without BUFI's stack.
- **Ancestor absorption (do not parallel-build):** desk-v1 already ships `contracts/recibo/src/BuInvoiceRecibo.sol` — a struct-mapping invoice ledger (status `None/Open/Settled/Attested/Void`, USDC memo-settled, `receiptHash` = hash of the canonical invoice PDF) with `ReciboInvoiceExtractor.sol` and CRE attestation companions. bINV **supersedes** it on Arc: adopt its status semantics and `receiptHash` document-binding convention, add the ERC-721 form + installments + the legal-assignment hash bundle it lacks, and provide a migration note so the dormant Sepolia deployment is retired, not duplicated. The desk-v1 acceptance chain (`team_invites → bills → invoices.accepted_at`) is the off-chain event that authorizes minting — there is **no `accepted` value in the `invoice_status` enum** (it's `draft/overdue/paid/unpaid/canceled/rejected/active`); bind to the real event, and fix the known drift (`'partial'` written by the bridge webhook but absent from the enum) upstream.

## §10. References (normative + informative)

| Ref | Use |
|---|---|
| Arc transaction memos — docs.arc.io `concepts/transaction-memos`, `tutorials/send-usdc-with-transaction-memo`; `Memo` predeploy `0x5294E9927c3306DcBaDb03fe70b92e01cCede505` | **Normative** for §5.1 |
| `circlefin/recibo` (+ Circle blog "Recibo: encrypted messages for ERC-20 transactions") | **Normative** for §5.2 (Apache-2.0, attribute) |
| `circlefin/refund-protocol` | Adapted-with-hardening for `ReceivableEscrow` (build prompt Step 5 warning) |
| Morpho Blue + MetaMorpho v1.1 | **Normative** for markets M3/M5 + `BUFICreditVault` (GPL: interfaces only) |
| `erc-8004-contracts` | **Normative** identity/reputation base (MIT, attribute) |
| Exactly Protocol fixed-maturity pools / Exa Card installments | Design reference for §3.6 |
| Chainlink: "Onchain Factoring" + "Invoice Tokenization for Trade Finance" articles | Informative for §9; CRE already used for scoring/settlement workflows |
| Tinlake, Huma, Request Network | Reference-only (AGPL rules — browser-only, never in `src/`) |
| desk-v1: `apps/motora`, magic inbox (`apps/app/.../inbox`, `workflows/inbox-document-intelligence.ts`), `packages/invoice`, financial-analytics | **Normative** data sources for `SPEC_CREDIT_PASSPORT.md` §P1 |
| `fx-telarana-tournament`: `KawaiiPower.sol` (soulbound earned-never-bought score) + `TournamentPrizePool.sol` (USYC-yield prize pool, on-chain splitBps, solvency invariant) | **Normative templates** for the passport's on-chain score + on-time-repayment prize pool (§P5) — adapt, don't parallel-build |
| Eve (`bu-intelligence-agent`) + `@bufinance/intelligence` (npm, the consolidated brain) | Conversational offer surface (§P5); factoring `BuTool`s land in the package, Eve inherits |
| `fx-matcher` (Go perps-executor live; Rust CLOB staged) — EIP-712 verify → `settleMatch` on Arc | Reuse for invoice-FX conversion settlement (§3.7) |
| `@bufinance/kyc-ui` (Persona KYB UI) · `@bufinance/ramps` Payout + `ramps-ui` · `@bufinance/fx` (StableFX client) · `@bufinance/analytics` (`BufiMetricsSnapshot`) | Factoring UX + metrics emission (`project:'recibu'`). ⚠ `ramps/kyc` + `ramps/compliance` subpaths are **stubs** — never treat as controls (§8.3) |

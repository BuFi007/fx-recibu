# fx-Recibú — Bucket Analysis (Round 1)

> Vision: invoice factoring + SME credit passport for KYB'd desk-v1 workspaces; multi-stablecoin (StableFX) invoices financed via fx-telarana Morpho markets on Arc; automated repayment waterfalls; Argentina-grade fraud resistance; coordination as a force for good (Owocki/Moloch).
> Scored against: the BUFI ecosystem as it exists in code (desk-v1, fx-telarana, defi-web-app, fx-pasillo, b-in-bufi) + fx-Recibu specs. Evidence: `docs/GATEMAN_AUDIT.md` + four file-grounded sweeps (2026-07-01). Score = (✓ + 0.5·◐)/total, rounded down to 5%.

## Bucket scorecard

| # | Bucket | Score | ✓ | ◐ | ✗ |
|---|---|---|---|---|---|
| **HP1** | **W2W offer moment** ("get $X today" in the multisig inbox) | **30%** | 2 | 1 | 5 |
| **HP2** | **Credit passport engine** (dual score, features, attestation) | **40%** | 3 | 2 | 5 |
| B1 | Identity & on-chain reputation | 40% | 3 | 1 | 4 |
| B2 | Invoice tokenization & bINV standard | 25% | 1 | 2 | 5 |
| B3 | Multi-stablecoin (StableFX) invoices | 40% | 3 | 1 | 4 |
| B4 | Factoring credit rails (Morpho markets + vault + tranches) | 40% | 4 | 0 | 5 |
| B5 | Settlement rails (Arc Memo, escrow, installments) | 40% | 3 | 1 | 4 |
| B6 | Fraud containment & compliance (Argentina posture) | 50% | 4 | 4 | 4 |
| B7 | Repayment waterfall + defaults stack | 30% | 2 | 1 | 5 |
| B8 | FX leg (fx-telarana swaps/oracles/RFQ) | 60% | 4 | 1 | 2 |
| B9 | Yield-on-idle + compliance wall | 65% | 4 | 0 | 2 |
| B10 | UX surfaces (analytics, factoring widgets, passport UI) | 55% | 4 | 1 | 3 |
| B11 | Force-for-good coordination mechanics | 40% | 1 | 4 | 2 |

**Overall: ~42%.** The substrate (B6/B8/B9/B10) is far ahead of the protocol (HP1/B2/B7). BUFI has already built the boring 60% that kills most factoring startups — scores, KYB, custody, velocity limits, FX, yield — and is missing exactly the coordination core: the offer, the token, the waterfall.

## Per-bucket detail

### HP1. W2W offer moment — 30%
Vision: "in DeskV1 private multisig they would see: you could get $X today for this invoice once it's been accepted."
- ✓ Acceptance event bindable — `apps/shiva/src/routes/invoices-accept.ts`, `invoices.accepted_at`
- ✓ v2v debtor resolution — `customers.bufi_team_id` → `team_invites(billing_relationship)` → `bills(biller_team_id, payer_team_id)`
- ◐ Dual-score read — per-team `team_payment_score_snapshots` exist; no pair (seller↔debtor) computation
- ✗ Offer computation (advanceRate × face, clipped by L(w)) — spec-only
- ✗ Offer card type in multisig approval inbox (`MultisigOpKind` has no factoring op)
- ✗ Multisig accept → lockInvoice path
- ✗ Rejection path with score-improvement guidance
- ✗ Factoring widget bound to data — `invoice-factoring-recommendations/index.tsx` is hardcoded MOCK

**To 100%:** offer service reading both snapshots + pair history; new `MultisigOpKind='factoring_offer'`; replace the mock widget with the live offer/eligibility card; wire accept → shelf lock.

### HP2. Credit passport engine — 40%
- ✓ Payer-side + ✓ biller-side scores — RPC `get_team_payment_score_v1`, daily cron, `team_payment_score_snapshots`
- ✓ Financial-health scores (runway/profit/growth/liquidity) — `financial-health-scheduler.ts`
- ◐ Bank cash-flow features — motora LLM enrichment real (`apps/motora/src/utils/enrich.ts`) but NOT folded into the score
- ◐ Inbox trade-doc features — pipeline real (`inbox-document-intelligence.ts`, receipt matcher) but NOT in the score
- ✗ On-chain repayment ground truth (Arc Memo / PAID_ON_TIME) — CRE workflows are Sepolia + dormant (Gateman F1)
- ✗ `S_pair` pair-history scoring · ✗ SCORE_SNAPSHOT attestation on-chain · ✗ anti-gaming (ring/source-diversity) · ✗ ML v1

**To 100%:** fold motora+inbox features into a v0.5 score; Arc-native attestation (F2 fix); pair scoring; label capture from Memo events.

### B1. Identity & reputation — 40%
- ✓ KYB state (`alfred_teams.kyb_status`, `teams.kyb_case_id`) · ✓ Persona/Alfred/UBO webhooks · ✓ ERC-8004 reads (`packages/contracts/src/erc8004/registry.ts`)
- ◐ ERC-8004 write path — exists but on base/baseSepolia (`packages/intelligence/src/agent/identity.ts`), diverging from the read path's ethereum/avalanche
- ✗ Single canonical identity chain including Arc (Gateman F2 — CRITICAL) · ✗ BUFIIdentityRegistry/BUAttestation deployed · ✗ HSM EIP-712 attestations · ✗ KYB_STATUS on-chain

### B2. Invoice tokenization & bINV — 25%
- ✓ Attestation column + public proof page — `invoices.attestation_tx_hash`, `/invoice/[token]`
- ◐ On-chain invoice ancestor — `contracts/recibo/src/BuInvoiceRecibo.sol` (struct ledger, Sepolia placeholder)
- ◐ Document-hash binding — `receiptHash` = hash of canonical invoice PDF (recibo workflow types)
- ✗ ERC-721 bINV · ✗ installments on-chain · ✗ lifecycle events · ✗ legal-assignment hash bundle · ✗ InvoiceShelf

### B3. Multi-stablecoin invoices — 40%
- ✓ Currency field (free-text, default USDC) · ✓ full StableFX registry (`packages/transfer-utils/src/stable-tokens.ts`: MXNB/QCAD/AUDF/JPYC/CIRBTC/BRLA/KRW1/PHPC/ZARU) · ✓ FX display widget (`invoice-currency-converter`)
- ◐ ARS corridor awareness (ramps/FX only, not invoices)
- ✗ Prod gate — `PROD_SUPPORTED_CURRENCIES` = USDC/EURC only · ✗ templates render StableFX (hardcoded USDC/EURC) · ✗ balance checks per asset (`accept-and-pay.tsx:544`) · ✗ settlement rail per asset

### B4. Factoring credit rails — 40%
- ✓ USDC-loan markets live (MXNB/QCAD/cirBTC collateral, canonical MorphoBlue `0x65f435…`) · ✓ **asset-loan markets deployed** (borrow AUDF/EURC/MXNB/QCAD/cirBTC vs USDC) · ✓ Vault V2 factories live (`VaultV2Factory 0x6b7F63…`) · ✓ ~$300k idle lender USDC, 0 borrows
- ✗ Asset-loan markets seeded + registered in app SDK (`MarketKey` union excludes them) · ✗ BUFICreditVault instance · ✗ bIF tranches · ✗ NAV oracles · ✗ JPYC on Arc (Fuji-only)

### B5. Settlement rails — 40%
- ✓ Arc Memo predeploy (`0x5294E9…505`) · ✓ Recibo memo-settlement pattern (BuInvoiceRecibo + circlefin/recibo) · ✓ Circle-webhook → `paid` detection (invoices, live)
- ◐ Crash-safe settlement orchestration pattern — pasillo `SettlementOrchestrator` DO (ramps domain, reusable)
- ✗ memoId=invoice binding · ✗ ReceivableEscrow · ✗ InvoiceMemoRouter · ✗ installment application

### B6. Fraud containment & compliance — 50%
- ✓ Velocity limits fail-closed ($50k/day wallet, $500k/week team — `packages/kv/src/velocity-core.ts`) · ✓ rate limits fail-closed (shiva + pasillo) · ✓ webhook sig verify + Circle IP allowlist · ✓ idempotency on money POSTs
- ◐ Sanctions screening — wired into transfer/bill/ramps but `CIRCLE_COMPLIANCE_ENABLED` default OFF · ◐ KYB as factoring precondition (KYB real; gate not enforced for factoring) · ◐ UAFE-grade audit trail (pasillo queue+DLQ; not on invoice flows) · ◐ dual-control (MSCA multisig real but opt-in; b-in-bufi approvals stub)
- ✗ Device/actor binding · ✗ behavioral anomaly detection · ✗ on-chain L(w) exposure cap · ✗ ring/self-dealing detection

### B7. Repayment waterfall + defaults — 30%
- ✓ Senior/junior tranching primitive (SharedFxVault, live) · ✓ insurance sink primitive (TurboFeeVault, live)
- ◐ Inflow-policy substrate — shiva ops-wallet policy bands (auto/approval/reject + budget ledger); no diversion logic
- ✗ Holdback · ✗ operating reserve · ✗ cross-default registry · ✗ tranched loss allocation · ✗ terminal PERMANENT_DEFAULT

### B8. FX leg — 60%
- ✓ 4 vault-backed StableFX pools live · ✓ weekend-proof oracles (all 6 assets marked) · ✓ FxRouter cross-currency (smoke-tested) · ✓ institutional RFQ (pasillo StableFX RFQ+Permit2)
- ◐ Depth (~$5–10k/pair — invoice-scale marginal) · ✗ RecibuSettlementGuardHook · ✗ JPYC pair (0 liquidity)

### B9. Yield-on-idle + compliance wall — 65%
- ✓ USYC router entitled + live · ✓ `Tier.RETAIL` hard-revert (compliance law on-chain) · ✓ Morpho idle-USDC supply path · ✓ sweep-position pattern live (PerpMarginYieldVault `0xF38b5c…`)
- ✗ Escrow-idle→yield wiring for invoices · ✗ 50/30/20 split

### B10. UX surfaces — 55%
- ✓ Payment-score widget (real data) · ✓ financial-health widget · ✓ multisig approval inbox · ✓ invoice acceptance UI
- ◐ Score attributions (breakdown shown; no "how to improve" loop)
- ✗ Factoring recommendations (MOCK) · ✗ customer payment trends (MOCK) · ✗ payment-trends chart (STUB — "Chart visualization goes here")

### B11. Force-for-good coordination — 40%
- ✓ Public verifiability — attestation proof page (`/invoice/[token]`)
- ◐ Cooperation compounds (score→status bands exist; score→terms loop missing) · ◐ regulator-grade audit (UAFE pattern exists, not on factoring) · ◐ yield-funded (not emission-funded) rebate precedent live in fx-telarana IL hook · ◐ positive-sum idle capital (USYC live, unwired)
- ✗ Trust earned only via realized repayment (L(w) invariant) · ✗ defection terminal (PERMANENT_DEFAULT)

## Vision gaps (flagged, not scored)
1. **AFIP/factura electrónica** — Argentina e-invoicing compliance absent from code AND from specs; load-bearing for "Buenos Aires works for the world."
2. **Legal servicer entity** — who signs assignments, who collects off-chain; specs name roles but no operating entity/runbook.
3. **desk-v1 chains ≠ Arc** — workspace money lives on ETH-SEPOLIA/AMOY/FUJI Circle wallets; capital bridge = Circle Gateway/CCTP (`packages/circle-kit`) exists but the workspace→Arc flow is undesigned.
4. **Data consent/revocation UX** for passport sources (motora/inbox OAuth) — spec asserts revocability; no UX.

## Closure plan (value × ease, top 5)
1. **Decide the identity home-chain and fix F2** (unblocks HP2/B1/B2): attest on Arc via BUAttestation; ERC-8004 sepolia/avalanche registries become mirrors. Spec fix + M1 scope.
2. **Ship the offer moment v0** (HP1 30→70%): off-chain offer service on the acceptance event → new `factoring_offer` multisig op kind → replace the mock widget. No Solidity required for the demo loop.
3. **Seed + register the asset-loan markets** (B4 40→65%, B3 unblocked): ops job — junior seeding + `MarketKey` union + envio indexing. The markets are already on-chain.
4. **Force the compliance posture on** (B6 50→75%): `CIRCLE_COMPLIANCE_ENABLED=true`, KYB-approved precondition for factoring actors, screening on every advance/repayment, velocity limits composed into L(w).
5. **Lift the multi-stablecoin prod gate for invoices** (B3 40→70%): currency enum + template rendering + per-asset balance checks behind a feature flag; JPYC excluded (no Arc token).

## Addendum — final ecosystem sweep (2026-07-01: Eve, tournament, matcher, analytics, BUFX, published pkgs)

New substrate found after Round-1 scoring (evidence file-grounded; scores below note direction, full re-score at next milestone gate):

- **HP1 (offer moment) gains a second delivery surface:** Eve (`bu-intelligence-agent`) is live on Discord/Slack/web, authenticated userId→team→wallet, with `get_invoices` + ~100 hyper-mcp tools (incl. lending on Arc 5042002) and a gated approve-in-chat loop (`agent/tools/kawaii_gate.ts`, `ops_approve.ts`). A `get_factoring_offer`/`accept_advance` `BuTool` added to `@bufinance/intelligence` is auto-inherited by Eve. The offer moment can be conversational AND multisig-gated.
- **B11 (force-for-good) has a live mechanics home — biggest find:** `fx-telarana-tournament/contracts/src/hub/KawaiiPower.sol` is the **soulbound, earned-never-bought score** (no transfer path by construction, VIP ladder, Merkle epoch checkpoints, bounded seasonal decay) — the direct template for the passport's on-chain score. `TournamentPrizePool.sol` is the **USYC-yield-funded, KYC-gated prize pool** with on-chain 50/30/20 `splitBps`, pull-claims, and a solvency invariant (`unclaimedLiability`), already wired to the live router `0x623d…8b06`. The spec's "yield-funded, never emissions" law has running code. B11 direction: 40% → ~55%.
- **B8 (FX leg):** fx-matcher's Go `perps-executor` is LIVE (EIP-712 verify → `settleMatch` on Arc); Rust CLOB staged. Invoice-FX conversion at advance time can reuse `eip712.go` / `spot_executor.rs` / `settlement.rs`.
- **B10/UX + onboarding:** `@bufinance/kyc-ui` (real Persona KYB UI), `@bufinance/ramps` Payout interface + `ramps-ui` (advance-disbursement UX), `@bufinance/fx` (invoice→USDC conversion client).
- **Observability:** `@bufinance/analytics` `BufiMetricsSnapshot` contract — fx-Recibú should emit `project:'recibu'` snapshots (advance volume, default rate, prize-pool size); consume, don't rebuild.
- **Two new façade flags:** `@bufinance/ramps/kyc` (`PersonaKycBridge`) and `/compliance` are **stubs** (throw placeholder errors, OFAC/travel-rule deferred "Phase 6") — same compliance-theater class as the flag-OFF screening (F8). **BUFX is stale** (~6 weeks) and is a request/venue layer, NOT the "spot+perp execution layer" the fx-telarana docs call it — treat that label as loose.

## External APIs / integrations needed

| Bucket | API/Service | Env var | Tier | Notes |
|---|---|---|---|---|
| B6 | Circle Compliance Engine | `CIRCLE_COMPLIANCE_ENABLED=true` + key | Circle-granted | Wired already; needs Circle eligibility + flag flip |
| HP2/B1 | Arc RPC | `ARC_RPC_URL` | free testnet | Attestation writes + Memo reads |
| B1 | ERC-8004 registries (mirror) | existing | n/a | `0x8004A1…`/`0x8004BA…` ethereum-family; mirror-only |
| B9 | Hashnote USYC Teller | entitled | Reg-S | Router `0x623d0D…` already entitled (bit-0) |
| B6 | Device intelligence (new) | TBD | paid | No provider in code today; required for actor binding — decision needed |
| HP2 | Workers-AI / existing LLM | existing | CF | Motora enrichment already runs deepseek on Workers-AI |
| B4 | Morpho Vault V2 factory | on-chain | n/a | `0x6b7F638B…` — vault deploy is a script, not an integration |

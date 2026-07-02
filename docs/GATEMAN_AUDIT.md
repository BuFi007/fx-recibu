# Gateman Verification Report — fx-Recibú specs vs. BUFI ecosystem reality

**Feature:** `SPEC.md` + `SPEC_CREDIT_PASSPORT.md` + `ROADMAP.md` (fx-Recibú invoice factoring + SME credit passport)
**Scope audited:** every claim the specs make about desk-v1, fx-telarana, defi-web-app, fx-pasillo, b-in-bufi
**Date:** 2026-07-01 · **Verifier:** Claude (4 parallel evidence sweeps, file-path-grounded)
**Posture:** the specs are AI output. Assume nothing, question everything, worship no one — including our own writing.

---

## 1. Checks PASSED (claim → evidence)

| # | Spec claim | Evidence | Verdict |
|---|---|---|---|
| P1 | 8-component payment score with stated weights | `apps/app/.../payment-score/index.tsx` `SCORE_COMPONENTS`; server RPC `get_team_payment_score_v1`, daily cron 07:00 UTC, 12-mo lookback → `team_payment_score_snapshots` | **REAL, production-grade** |
| P2 | 20+ financial-analytics metrics | 9 payment sub-scores + 5 health scores (`get_runway_v8`, `get_profit_v7`, `get_revenue_v7`, `get_growth_rate_v4`) + 11 chart metrics (`packages/analytics-core/src/constants.ts`) = **25** | REAL |
| P3 | Motora bank enrichment | Plaid/Teller/GoCardless/Pluggy/Iniciador/Mesh + real LLM enrichment (`apps/motora/src/utils/enrich.ts`, Workers-AI, KV-cached) + Google Places/Logo.dev company data | REAL, broader than claimed |
| P4 | Magic inbox AI pipeline | Gmail/Outlook connectors (`packages/inbox`), `inbox-document-intelligence.ts` → worker pipeline `ocr→extraction→classification→embedding→matching`, scored receipt↔bill matcher (`payables-receipt-matching.service.ts`) | REAL |
| P5 | Multisig approval inbox surface | Circle MSCA (ERC-6900) weighted-WebAuthn plugin ABIs (`packages/wallets/src/multisig`), `pending_multisig_ops` (RLS, threshold state machine), 7,339-line `smart-wallet.controller.ts`, treasury routes | REAL (opt-in; see F6) |
| P6 | KYB pipeline exists | Persona + Alfred: `alfred_teams.kyb_status` enum, `teams.kyb_case_id`, UBO webhook handlers (`routes/webhook/persona/handlers/`) | REAL |
| P7 | v2v invoicing (debtor = another workspace) | `customers.bufi_team_id` → `team_invites(type='billing_relationship')` → `bills(biller_team_id, payer_team_id)` | REAL today |
| P8 | Invoice acceptance event exists | `apps/shiva/src/routes/invoices-accept.ts` (+ `invoices.accepted_at`, bill `pending→accepted→paid`) | REAL — but not an invoice-status enum value (F7) |
| P9 | StableFX loans possible on fx-telarana | Asset-loan Morpho markets **deployed on canonical MorphoBlue** for AUDF/EURC/MXNB/QCAD/cirBTC (borrow asset vs USDC, LLTV 86%, `arc-asset-loan-morpho-markets-5042002.json`) + USDC-loan markets (MXNB/QCAD/cirBTC collateral) with ~$300k idle supply, 0 borrows | REAL on-chain; **unseeded + not app-registered** |
| P10 | Live USD marks for all StableFX | Pyth→RedStone→keeper manual feeds (MXN/AUD/CAD/JPY/USDC), weekend-proof, verified on closed-forex weekend | REAL |
| P11 | SharedFxVault tranching + USYC yield engine | Senior(par USDC, Morpho-rehyp)/junior(first-loss) built in `SharedFxVault.sol`; `FxReserveYieldRouter` USYC-entitled 2026-06-12, `Tier.RETAIL` reverts | REAL |
| P12 | Arc Memo predeploy rail | Predeploy `0x5294E9927c3306DcBaDb03fe70b92e01cCede505` (docs.arc.io, user-verified) | REAL |
| P13 | On-chain invoice ancestor exists | `desk-v1/contracts/recibo/src/BuInvoiceRecibo.sol` (status None/Open/Settled/Attested/Void, USDC memo-settled) + `ReciboInvoiceExtractor.sol` + CRE attestation workflows | REAL (embryonic, Sepolia placeholders) |

## 2. Checks FAILED (spec claim refuted or unsupported — fix in rewrite)

| # | Spec said | Reality | Severity |
|---|---|---|---|
| **F1** | CRE workflows (`workflow-recibo-invoice`, `workflow-invoice-settle`) drive Arc settlement events for the passport | Both target **ethereum-testnet-sepolia**, contracts placeholder-deployed, prod trigger **commented out** (`accept-and-pay.tsx:658-672` "TODO: Enable when CRE moves to mainnet") | HIGH — passport data-source #5 mis-wired |
| **F2** | Passport "shares the agentId space with desk-v1 `@bu/contracts/erc8004`" | ERC-8004 **read** path = ethereum/avalanche (default **ethereum-sepolia**, registries `0x8004A1…`/`0x8004BA…`); **write** path (`packages/intelligence`) = **base/baseSepolia**; fx-Recibú = **Arc**. Three chains, no mirror. | **CRITICAL** — identity layer as specced cannot exist; needs explicit home-chain + attestation-mirroring decision |
| **F3** | `BUFICreditVault` = MetaMorpho **v1.1** via `MetaMorphoV1_1Factory` | Arc has Morpho **Vault V2** factories deployed (`VaultV2Factory 0x6b7F638B…`, adapter factory `0x9372Eb…`, verified live); no v1.1 factory; no vault instance deployed; `BUFICreditVault` exists nowhere in code | HIGH — retarget to Vault V2; vault build is real scope |
| **F4** | JPYC invoices financeable on Arc alongside the others | **No canonical JPYC token on Arc** (intentionally excluded from asset-loan deploy); JPYC markets live on **Fuji** (M5/M6); Arc JPYC swap pool 0-liquidity | MEDIUM — JPYC = Fuji-routed or deferred |
| **F5** | Multi-stablecoin invoices are a near-term wiring of existing support | Invoice `currency` is free-text, **prod-supported = USDC/EURC only** (`PROD_SUPPORTED_CURRENCIES`); StableFX tokens exist in registry (`stable-tokens.ts` incl. MXNB/QCAD/AUDF/JPYC/CIRBTC/BRLA/…) but dev-gated; templates/balance-checks hardcode USDC/EURC; **no FX conversion of invoice amounts**; payment action hard-blocks currency mismatch | MEDIUM — true gap list is: prod-gate lift + template rendering + balance checks + settlement rail per asset |
| **F6** | Workspaces control on-chain identity/custody suitable for `InflowDivertHook` (MSCA policy module) | Default custody = **single-key Circle DCW (custodial)**, `wallets.custody_model` default `'dcw'`; MSCA multisig real but **opt-in**; login identity = SIWE **EOA** (bufi-sign-in-web); desk-v1 chains = **ETH-SEPOLIA / MATIC-AMOY / AVAX-FUJI — not Arc** | **CRITICAL** — inflow diversion must be enforced at the Circle-custody/shiva policy layer (ops-wallet policy bands, address-book plugin) or via Gateway sweep — not assumed as a user-held Arc MSCA |
| **F7** | "Accepted invoice" is an invoice status | `invoice_status` enum = `draft/overdue/paid/unpaid/canceled/rejected/active`; acceptance lives in `team_invites` + `bills` + `invoices.accepted_at`; bridge webhook writes out-of-enum `'partial'` (status drift bug) | LOW — bind offer trigger to the real event; upstream enum fix recommended |
| **F8** | (implied) compliance rails adequate for a high-fraud environment | Circle Compliance screening **feature-flagged OFF** (APPROVED no-op); **no device fingerprinting**; **no behavioral anomaly scoring**; b-in-bufi approvals UI is a stub; dev-mode KYB bypass in pasillo `customer-gate.ts` | HIGH for Argentina posture — must be forced-on preconditions in the spec |
| **F9** | (implied by liquidity story) UI reflects lending reality | `loan.tsx` `SEED_MARKETS` hardcodes both loan directions as `status:"live"` — overstates unseeded asset-loan markets | LOW — façade; fix or annotate |

## 3. Latent assets the specs UNDER-used (found by sweep, fold into rewrite)

- **fx-pasillo settlement machinery**: `SettlementOrchestrator` DO (crash-safe state machine, zero-tolerance amount matching, per-step idempotency), `BufxKeeperLock` mutex, **UAFE audit queue + DLQ** (regulator-grade guaranteed delivery — the exact pattern an AFIP/Argentina trail needs), tiered fail-closed rate limits, HMAC replay windows, Circle webhook RSA + IP allowlist.
- **Velocity limits, fail-closed**: `$50k/day per wallet, $500k/week per team` (`packages/kv/src/velocity-core.ts`) already enforced pre-transfer in shiva — the graduated-exposure `L(w)` has an off-chain sibling to compose with.
- **StableFX RFQ + Permit2 on Arc** (`fx-pasillo/src/providers/stablefx.ts`, `FxSettlementKind='rfq-permit2'|'amm-onchain'`) + multi-venue intent aggregator — the FX leg of multi-currency invoice settlement already has an institutional rail.
- **Circle Gateway unified balance + CCTP** (`packages/circle-kit`, shiva gateway controller) — the desk-v1(testnet chains)→Arc capital bridge exists.
- **Vendor compliance allowlist** (`payable_vendors.compliance_status`) — a second, team-level gate to reuse for debtor onboarding.
- **BuInvoiceRecibo.sol + extractors + escrow/ACE contracts** — fx-Recibú's bINV should absorb/supersede this ancestor explicitly, not parallel-build.
- **Hinkal private transfers + ghost mode** — optional privacy rail for factoring payouts (KYC-gated).

## 4. Scorecard (specs as shipped artifact)

| Category | Score | Note |
|---|---|---|
| Input validation (claims grounded before use) | 5/10 | Core desk-v1 widgets verified pre-spec; chain/deploy claims (F1–F4) were asserted from memory — the exact hallucination surface Gateman exists for |
| External identifiers | 4/10 | ERC-8004 addresses/chains and MetaMorpho version named without verification (F2, F3) |
| Fraud surface | 7/10 | §3.5/§3.6/§4.8/§4.9 containment design is sound; but relies on compliance rails that are OFF (F8) and custody that isn't user-held (F6) |
| Money/time/reversibility | 8/10 | Installments, waterfall, holdback, bounded ramp — strong; currency plurality understated (F5) |
| Failure modes | 6/10 | Waterfall covers credit failure; chain-fragmentation failure (F2) and rail-dormancy (F1) unhandled |
| Observability | 7/10 | bINV indexer-first events specced; UAFE-grade guaranteed-delivery audit not yet adopted |
| **AI verification** | **3/10** | Multiple confident, wrong, checkable claims shipped in v1 specs. This report is the correction. |

## 5. Risk level: **HIGH** (as specs stand) → target LOW after rewrite

**Sign-off: NO — do not build from the current specs.** Smallest set of changes that flips the verdict:
1. Fix F2 (identity home-chain: attest on **Arc** via `BUAttestation`; treat ERC-8004 sepolia/avalanche registries as *mirror targets*, not the source of truth).
2. Fix F3 (retarget BUFICreditVault → Morpho **Vault V2** factory on Arc, addresses above).
3. Fix F1 (passport ground truth = **Arc Memo events + bINV lifecycle events**; CRE/DON attestation becomes an optional verification layer, marked dormant-until-mainnet).
4. Fix F6 (InflowDivertHook v1 = shiva/Circle-custody policy enforcement + Gateway sweep; on-chain MSCA module = v2 when workspaces opt into modular custody on Arc).
5. Encode F8 as **launch preconditions**: `CIRCLE_COMPLIANCE_ENABLED=true`, screening on every factoring actor, device/actor binding requirement, dual-control approvals.
6. Fold F5's real gap list into the multi-currency section; JPYC → deferred (F4).

## 6. Verified constants (use these, not memory)

- Canonical MorphoBlue (Arc): `0x65f435eB4FF05f1481618694bC1ff7Ee4680c0A4` · AdaptiveCurveIrm `0xBD583cc9807980f9e41f7c8250f594fB6173abE3` · dead fork `0x3c9b95…` (never use)
- Asset-loan marketIds (borrow X vs USDC): AUDF `0xbef2a3…9536`, EURC `0xc33f06…7426`, MXNB `0xcbc017…69a0`, QCAD `0x0094d4…532a`, cirBTC `0x4c5cc6…a3cb`
- Canonical USDC-loan marketIds: MXNB `0x03dfa0…abcc`, QCAD `0xb8bf16…143d`, cirBTC `0x937b78…4a40`; Morpho-Labs M1/M2 EURC `0xd6df80…`/`0x5215cf…`
- Morpho Vault V2 factories (Arc): `VaultV2Factory 0x6b7F638B64539F83810A1f6ea81C703b561C3Be6`, `MorphoMarketV1AdapterV2Factory 0x9372EbEDF2C64344817c67dAeD99512F4b9DC434`
- Arc Memo predeploy `0x5294E9927c3306DcBaDb03fe70b92e01cCede505` · USDC `0x3600…0000`
- SharedFxVault `0x0E63eff212382F2679c3A363F60e00b7A6d6e3E4` · FxReserveYieldRouter `0x623d0DAfA24B59809a9fBfa3a60148F69aaB8b06` · FxOracleV2 `0xdA5Cd65521B64A7375C8d63EeDe52347783cEd74` · FxOracleCanon `0xf9b0356A31BC7125e2eD0DADf8b5957860d42c78`
- ERC-8004 registries (ethereum-family, mirror targets): identity `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`, reputation `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63`

## 7. Addenda

**A1 (2026-07-01, user correction):** `desk-v1/packages/intelligence` is **DEPRECATED** — superseded by the published npm package **`@bufinance/intelligence`**. F2's write-path evidence (`packages/intelligence/src/agent/identity.ts` → base/baseSepolia) therefore describes the deprecated code.

**A1 — RESOLVED (2026-07-01, verified):** `@bufinance/intelligence` v0.3.2 (source `bufinance-publish/intelligence`, per its `CONSOLIDATION.md`: the "one brain" — framework-neutral tools/SOUL/agent-loop/knowledge-graph, data access via HTTP to hyper-mcp + Shiva) contains **no ERC-8004 or on-chain identity code at all** (no viem/ethers; grep hits are incidental strings). Eve (`bu-intelligence-agent`) reaches ERC-8004 reputation only as **reads via hyper-mcp** (`agent/connections/hyper-mcp.ts:20`). The base/baseSepolia write path **did not migrate — it dies with the deprecated package**. Net: the ecosystem has **no live ERC-8004 write path**; the only live 8004 surface is the read path (`@bu/contracts/erc8004`, ethereum/avalanche). **F2 resolution stands and simplifies:** `BUAttestation` on Arc becomes the ecosystem's *first* identity write path — greenfield, no legacy divergence to reconcile; the ethereum-family registries remain read-side mirror targets.

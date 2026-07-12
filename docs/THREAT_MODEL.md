# fx-Recibú — Threat Model (M0)

> Each threat maps to the SPEC control that bounds it. A threat without an enforcement point is a finding, not a row. Passport-side threats: `SPEC_CREDIT_PASSPORT.md §P6`.

| # | Threat | Attacker + incentive | Control (enforcement point) |
|---|---|---|---|
| T1 | Identity/reputation forgery | forge scores → cheap credit | HSM EIP-712 attestations, replay nonces (`BUAttestation`); scores can only ever change *pricing* — exposure `L(w)` moves solely on settlement-role writes (`BUFIReputationRegistry` write-path law) |
| T2 | Fake invoice fraud | fabricate receivable, take advance, vanish | dual-side KYB gate; doc-hash bundle required at lock; **containment**: `L(w)` cold-start, debtor concentration, velocity, selected-tranche capacity, and seller first-loss. v1 funds the full advance at lock; the first uncured miss writes off all then-outstanding principal, while installments only accelerate detection/amortize after cash arrives (SPEC §3.5/§3.6/§4.9) |
| T3 | Fake debtor acceptance / collusion ring | A↔B wash invoices to farm repayment history | $250 minimum credited installment; 20% epoch-start line-growth cap; pair history only after a fully settled ≥$250 invoice; `S_pair=0` penalty + new-relationship cap; ring detection off-chain (KYB UBO graph); concentration + velocity caps |
| T4 | Servicer abuse | insider mis-attests / mis-services or substitutes its own cash for debtor history | role split (issuer ≠ settlement ≠ ops); canonical escrow wiring permanently disables direct servicer-funded payments; routers bind the current debtor owner; pending-cash default settlement remains keeper-gated; restructures are multisig-gated |
| T5 | Escrow early-withdrawal (refund-protocol lineage) | arbiter drains unrelated funds | ReceivableEscrow redesign: invoiceId/paymentId binding on EVERY movement; arbiter permissions separated from custody; `invariant_arbiterCannotWithdrawUnrelatedFunds` (M5 gate) |
| T6 | NAV oracle manipulation | inflate senior NAV → over-borrow | NAV is push-based from shelf accounting (not a market price); `reserveCredit` must be backed by real transfer; `Σ trancheAssets ≤ realUnderManagement` invariant; `OraclePauser` >10%/block breaker (SPEC §6.5–6.6) |
| T7 | Loss-booking delay | hide default to keep NAV high | installments have fixed maturities — miss auto-flips risk state on-chain; recognition is not discretionary (SPEC §3.6) |
| T8 | Morpho market risk | oracle/LLTV failure on asset-loan markets | 86% LLTV canonical markets; per-pair conversion caps sized to real pool depth (SPEC §3.7); USD-marked exposure re-marked per installment |
| T9 | Tranche accounting corruption | mint/burn outside waterfall | bIF mint/burn `onlyShelf`; loss allocation strictly C→B→A (`invariant_seniorNavParUnlessJuniorExhausted`, `invariant_recoveryWaterfallOrder`) |
| T10 | Cross-default griefing | dust-invoice default to freeze a healthy workspace | cross-default flips on the workspace's own default only, after grace; restructure path exists for legitimate distress; freeze blocks *residual release*, never deposits |
| T11 | RFQ/FX settlement manipulation | sandwich/thin-pool abuse on denomination conversion | conversion caps ≤ pool depth; TWAP/oracle deviation checks in the guard hook (M7); RFQ+Permit2 institutional path |
| T12 | Uniswap v4 hook abuse | invalid settlement swaps, defaulted-workspace residual release | `RecibuSettlementGuardHook.beforeSwap` whitelist + invoice-status + cross-default + recipient checks; reverts on any invalid state (M7) |
| T13 | Compromised HSM/scorer | mass fake scores | blast radius = pricing only (T1 law); anomaly alerting on attestation patterns; key behind multisig rotation |
| T14 | Governance/param abuse | quietly loosen caps | params in `Params.sol` are deploy-pinned; changes only via timelocked admin (mainnet posture per fx-telarana canary lesson) |

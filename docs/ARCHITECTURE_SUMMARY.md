# fx-Recibú — Architecture Summary (M0)

> Companion to `SPEC.md` (authoritative). This is the builder's map.

## Dependency graph

```
forge-std (test)      openzeppelin-contracts v5 (Ownable/AccessControl/EIP712/ECDSA/ERC721)
        │                      │
        └──────────┬───────────┘
                   ▼
  src/libraries/Params.sol        (M0.5 — pinned protocol constants)
                   │
  src/identity/                   (M1 — the passport's on-chain half)
    BUFIIdentityRegistry          workspaceId ↔ agentId ↔ owner; KYB flag (issuer-gated)
    BUFIReputationRegistry        scores (attested) + paidOnTimeCumulative (settlement-only) + terminal default
    BUAttestation                 EIP-712 HSM-signed writes; verifierKind pluggable {HSM_EOA, DON_REPORT}
                   │
  src/credit/                     (M2)
    WorkspaceTierRegistry         SPEC §3 matrices as views; L(w) monotonic in realized repayment
                   │
  src/invoice/                    (M3)
    InvoiceShelf                  locks accepted invoices; mints bINV; enforces L(w)/concentration/velocity
    BINV (ERC-721)                one token per accepted invoice; doc-hash bundle; installment schedule
    BIFTranche ×3                 bIF-A/B/C ERC-20, mint/burn only by shelf
    BUFIOracle + OraclePauser     Morpho IOracle NAV per tranche (SPEC §6), >10% intra-block breaker
                   │
  src/rails/                      (M4–M5)
    WorkspaceOperatingReserve · CrossDefaultRegistry · RestructureRouter
    InvoiceMemoRouter (Arc Memo predeploy 0x5294E9…505) · ReceivableEscrow · InvoiceSettlement
```

External (Arc, verified in GATEMAN_AUDIT §6): canonical MorphoBlue `0x65f435…`, asset-loan markets (deployed, unseeded), Vault V2 factory `0x6b7F638B…`, Arc Memo predeploy, USDC `0x3600…0000`.

## The full flow

1. **Invoice lock** — desk-v1 acceptance (`team_invites → bills → accepted_at`) + servicer document attestations authorize `InvoiceShelf.lockInvoice`; caps checked (`L(w)`, debtor concentration, velocity); bINV minted; advance funded from tranche liquidity (Morpho borrow for non-USDC denominations).
2. **Advance** — seller receives denomination asset minus discount; holdback retained; installment schedule (N, maturities, grace) written on-chain.
3. **Escrow repayment** — debtor pays via Arc Memo (`memoId = keccak(invoiceId‖installment)`) → `InvoiceMemoRouter` validates → `ReceivableEscrow.deposit` (invoice-bound); unmatched memos quarantine.
4. **Settlement** — `InvoiceSettlement` applies inflow to earliest open installment → Morpho repay → tranche accounting → **reputation event** (`paidOnTimeCumulative++`, the ONLY thing that raises `L(w)`); shortfall → §4.8 waterfall (holdback → reserve → recourse → bIF-C → bIF-B → bIF-A).
5. **Reputation update** — on-time raises capacity + terms; missed-past-grace flips risk state, triggers cross-default freeze; fraud → `PERMANENT_DEFAULT` (terminal on the KYB'd identity).

## Write-path law (who may write what)

| State | Only writer |
|---|---|
| KYB status, scores (`SCORE_SNAPSHOT`) | `BUAttestation` (HSM EIP-712, replay-protected) |
| `paidOnTimeCumulative` | settlement role (InvoiceSettlement) — never attestation |
| `PERMANENT_DEFAULT` | settlement/ops role; irreversible |
| `RESTRUCTURED` | ops multisig via RestructureRouter; refuses to reclassify fraud |
| bINV / tranche mint-burn | InvoiceShelf only |

This split IS the SPEC §4.9 invariant: a compromised scorer can mis-price but can never raise exposure.

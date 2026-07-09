# fx-Recibú

On-chain **invoice factoring + SME credit passport** for KYB'd BUFI workspaces, on Arc.
A workspace with a strong payment score sells an **accepted** invoice for instant USDC;
the advance is priced by the **dual payment score** of both seller and debtor, amortized
over installments, and funded from tranched LP capital — with a fraud blast-radius bounded
by design.

> **Authoritative specs:** `SPEC.md`, `SPEC_CREDIT_PASSPORT.md`, `ROADMAP.md`.
> **Audits/analysis:** `docs/GATEMAN_AUDIT.md`, `docs/BUCKET_ANALYSIS.md`, `docs/THREAT_MODEL.md`, `docs/LEGAL_BOUNDARIES.md`, `docs/LICENSE_BOUNDARIES.md`.

## Private AML Architecture (ACE)

Factoring settles **privately by default** — the seller's payout address + the settled amount never hit the
public chain in the clear. Compliance is enforced at the **shield boundary** (an AML check *before* funds enter
the privacy pool), not by making the ledger public. This follows the shared Veil/Haven flow used by BOTH invoice
factoring (this repo) and private payroll (`fx-sobre`):

```
  DEPOSIT            SHIELD                          WITHDRAW         RAMPS (KYC/KYB)
 Factor/LP ──▶ Fresh/Stealth ─▶ AML Check ─▶ Privacy Pool ─▶ Fresh Addr    Fiat ⇄ Crypto via
 capital      Address                                       (seller)      ID Verification +
                                                                          Licensed Provider + Bank
```

- **Deposit** — factor / tranche capital funds the shelf; the seller payout targets a **fresh address** per
  settlement (never reused).
- **Shield** — an **AML check** (ACE PolicyEngine) screens **seller + debtor** *before* `lockInvoice` / settle;
  a failed screen reverts (`PolicyRejected`), it does not quarantine-then-leak. Only the aggregate proof + the
  `RecibuPayment` twin (memoId) is public; per-party (address, amount) stays shielded.
- **Withdraw** — the seller receives `face − holdback` to a fresh address, unlinkable to the factor/LP.
- **Ramps** — seller off-ramp goes through **KYC (Persona) + a licensed provider**; the KYB-approved workspace
  credential is a reusable ACE attestation, verified once, read by the AML policy on each chain.

ACE (hide-sender + Privacy Pools inside a Confidential-HTTP TEE) is the shield. The `RecibuMemoRouter` +
`RecibuPayment` event is the on-chain settlement entry that then shields via ACE. Full design + the
now-vs-ACE-Early-Access build split:
**desk-v1 `docs/superpowers/specs/2026-07-09-private-aml-architecture-ace.md`**.
**Non-negotiable:** private is the default; a transparent settlement is an explicit, gated downgrade.

## Build status

`forge test` → **67 passing** (unit + integration + 4 fuzzed fraud-containment invariants
at 128k calls each; deep profile = 10k runs). Solidity 0.8.26, `via_ir`, optimizer 200.

## Contract map (milestones)

| Layer | Contracts | Milestone |
|---|---|---|
| Identity & reputation | `BUFIIdentityRegistry`, `BUFIReputationRegistry`, `BUAttestation` | M1 |
| Credit engine | `WorkspaceTierRegistry` (SPEC §3 + `L(w)`) | M2 |
| Invoice core | `InvoiceShelf`, `BINV` (bINV standard), `BIFTranche` ×3 | M3 |
| NAV | `BUFIOracle` (Morpho `IOracle` + circuit breaker) | M3b |
| Defaults | `WorkspaceOperatingReserve`, bond gate, `resolveDefault` | M4 |
| Settlement rails | `InvoiceMemoRouter` (Arc Memo), `ReceivableEscrow` (hardened), `InvoiceSettlement` | M5 |
| Uniswap v4 | `RecibuSettlementGuardHook` (beforeSwap guard) | M7 |
| Deploy | `script/Deploy.s.sol` (full wiring + admin handoff) | M8 |

M6 (BUFICreditVault over the deployed Morpho **Vault V2** factory `0x6b7F638B…`) is a
deploy-time instantiation of an external factory — scripted in `Deploy` notes, allocated
across the canonical fx-Telaraña + fx-Recibú markets; no new protocol contract.

## The three invariants that make it safe (SPEC §4.9)

1. **`L(w)` moves only on realized repayment** — a compromised scorer can misprice, never
   raise exposure. (`invariant_scoreAttestationNeverMovesLimit`, and monotone + capped.)
2. **Loss fills junior→senior** — senior NAV holds par until junior+mezz are wiped.
   (`invariant_seniorParUnlessJuniorExhausted`.)
3. **No phantom assets** — pool identity `liquid + principal == Σ deposits − Σ loss`, and
   USDC held == liquid + custodied holdback. (`invariant_poolIdentity`, `invariant_cashBacked`.)

Plus: installment amortization bounds a fraud loss to ~one window; the escrow binds every
movement to an `invoiceId` so an arbiter can never touch unrelated funds (`ReceivableEscrow`,
THREAT_MODEL T5).

## Run

```bash
forge test                     # full suite
forge test --match-path "test/invariant/*"   # fraud-containment invariants
FOUNDRY_PROFILE=deep forge test               # 10k-run fuzz gate
```

Deploy (Arc): set `DEPLOYER_PRIVATE_KEY`, `USDC`, `ADMIN`, `HSM_SIGNER`, then
`forge script script/Deploy.s.sol --rpc-url arc_testnet --broadcast`. Verified Arc
constants (USDC, Arc Memo predeploy, Morpho, Vault V2 factory, USYC router) are listed in
`docs/GATEMAN_AUDIT.md §6` and the `Deploy` header — use those, not memory.

## License

Apache-2.0 (contracts). See `docs/LICENSE_BOUNDARIES.md` for adapted-code attribution and
the GPL-interfaces-only / AGPL-browser-only rules.

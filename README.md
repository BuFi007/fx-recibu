# fx-Recibú

On-chain **invoice factoring + SME credit passport** for KYB'd BUFI workspaces, on Arc.
A workspace with a strong payment score sells an **accepted** invoice for instant USDC;
the advance is priced by the **dual payment score** of both seller and debtor, repaid
over installments, and funded from tranched LP capital — with exposure bounded by `L(w)`,
concentration, velocity, seller first-loss, and the tranche waterfall.

> **Authoritative specs:** `SPEC.md`, `SPEC_CREDIT_PASSPORT.md`, `ROADMAP.md`.
> **Audits/analysis:** `docs/GATEMAN_AUDIT.md`, `docs/BUCKET_ANALYSIS.md`, `docs/THREAT_MODEL.md`, `docs/LEGAL_BOUNDARIES.md`, `docs/LICENSE_BOUNDARIES.md`.

## Private AML architecture (production target)

Private settlement and ACE shielding are **future production gates**, not capabilities of the current local
conformance implementation. The repository contains an ACE-compatible KYB policy surface, but it does not yet
provide an end-to-end privacy pool, shielded payout, Confidential HTTP flow, or live ACE deployment. The current
settlement contracts and events must be treated as public-chain surfaces.

The intended production architecture keeps privacy as the default and enforces compliance at the **shield
boundary** (an AML check before funds enter the privacy pool):

```
  DEPOSIT            SHIELD                          WITHDRAW         RAMPS (KYC/KYB)
 Factor/LP ──▶ Fresh/Stealth ─▶ AML Check ─▶ Privacy Pool ─▶ Fresh Addr    Fiat ⇄ Crypto via
 capital      Address                                       (seller)      ID Verification +
                                                                          Licensed Provider + Bank
```

- **Deposit target** — factor / tranche capital funds the shelf; the seller payout uses a fresh address per
  settlement.
- **Shield target** — an ACE PolicyEngine screens seller + debtor before `lockInvoice` / settlement; a failed
  screen reverts instead of leaking settlement details.
- **Withdraw target** — the seller receives `face − holdback` through a shielded payout path.
- **Ramp target** — seller off-ramp uses Persona KYC plus a licensed provider; the KYB-approved workspace
  credential becomes a reusable ACE attestation.

The proposed shield uses ACE, hide-sender/privacy-pool primitives, and Confidential HTTP. The
`RecibuMemoRouter` + `RecibuPayment` event is the proposed reconciliation entrypoint, not proof that shielding
has occurred. Full design + the now-vs-ACE-Early-Access build split:
**desk-v1 `docs/superpowers/specs/2026-07-09-private-aml-architecture-ace.md`**.
Production activation remains blocked until the private-by-default path and its compliance controls are live
and independently verified.

## Build status

Keyless local conformance tests are available with Foundry. There is no live Arc deployment from this
repository: the production entrypoint `Deploy.run()` intentionally reverts with
`ProductionActivationDisabled` until the authority, verifier, privacy, and deployment-manifest gates are met.
Solidity 0.8.26, `via_ir`, optimizer 200.

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
| Deploy | `script/Deploy.s.sol` (local wiring helpers; production entrypoint disabled) | M8 gate |

M6 (BUFICreditVault over the deployed Morpho **Vault V2** factory `0x6b7F638B…`) is a
deploy-time instantiation of an external factory — scripted in `Deploy` notes, allocated
across the canonical fx-Telaraña + fx-Recibú markets; no new protocol contract.

## Mainnet deployments: MemoConduit CCTP (2026-10-16)

| Contract | Chain | Address | Status |
|---|---|---|---|
| SpokeMemoConduit | Avalanche 43114 | [`0x7b5b1425bb621b014b7257a0d0caf88c453e33c8`](https://snowtrace.io/address/0x7b5b1425bb621b014b7257a0d0caf88c453e33c8) | **Deployed**, tx [`0xaa73ba08…`](https://snowtrace.io/tx/0xaa73ba08086005bb23a98ca4f147c540cc18d17262f49a498902c7e1f344ad60), block 97734276, gas 3,328,621. No owner; one-way Avalanche→Arc via CCTP |
| MemoConduit (checkout, CCTP) | Arc 5042 | `0x1D4C802c18145C746B3BF5F12433C08b96e9066a` (predicted) | **Pending**, not deployed |
| MemoConduit (checkout, CCTP) | Avalanche 43114 | `0x28a3Ef42725396D006495B5312277DdDF849a354` (predicted) | **Pending**, not deployed |

The earlier SpokeMemoConduit prediction `0x0c678dDF…64d0` is wrong; use `0x7b5b1425bb621b014b7257a0d0caf88c453e33c8`. Record: `deployments/avalanche-mainnet-spoke-memo-conduit.json`; broadcast: `broadcast/DeploySpokeMemoConduitMainnet.s.sol/43114/run-latest.json`.

## The three invariants that make it safe (SPEC §4.9)

1. **`L(w)` moves only on realized repayment** — a compromised scorer can misprice, never
   raise exposure. (`invariant_scoreAttestationNeverMovesLimit`, and monotone + capped.)
2. **Loss fills junior→senior** — senior NAV holds par until junior+mezz are wiped.
   (`invariant_seniorParUnlessJuniorExhausted`.)
3. **No phantom assets** — pool identity `liquid + principal == Σ deposits − Σ loss`, and
   USDC held == liquid + custodied holdback. (`invariant_poolIdentity`, `invariant_cashBacked`.)

Line growth is separately fail-closed against wash-volume: a credited installment must
realize at least $250, aggregate credits cannot grow the line by more than 20% of its
epoch-start value per 30 days, and pair history begins only after a ≥$250 invoice fully settles.
Once canonical escrow is wired, the legacy direct-servicer payment harness is disabled;
production repayment history can enter only through debtor-owner-bound memo routing and settlement.

Installments provide earlier default detection and reduce outstanding principal as cash is
received; they do **not** stage the v1 advance. The full advance is disbursed at lock and the
first uncured miss underwrites/writes off all then-outstanding principal. The escrow binds every
movement to an `invoiceId` so an arbiter can never touch unrelated funds (`ReceivableEscrow`,
THREAT_MODEL T5).

## Keyless local verification

```bash
forge fmt --check
FOUNDRY_PROFILE=ci forge test
forge test --match-path "test/invariant/*"
```

These commands do not need credentials and do not broadcast. Do not use `--broadcast`: live Arc deployment is
a future, owner-reviewed production step. Candidate Arc constants and their evidence are tracked in
`docs/GATEMAN_AUDIT.md`; they must be re-verified and pinned in an approved deployment manifest before use.

## License

Apache-2.0 (contracts). See `docs/LICENSE_BOUNDARIES.md` for adapted-code attribution and
the GPL-interfaces-only / AGPL-browser-only rules.

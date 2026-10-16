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

## Contracts, status and deployments

Audited 2026-10-16 against `main` (7330e6c): `forge build` OK, `forge test` 285 passed / 0 failed (17 suites).
Production = BUFI desk ([BuFi007/desk-v1](https://github.com/BuFi007/desk-v1) `main`) on **Arc 5042** and **Avalanche C-Chain 43114**.
Smart-account / conduit contracts and the audit scope live in [BuFi007/BUFI-6900](https://github.com/BuFi007/BUFI-6900).

### Mainnet (production)

| Contract | Chain | Address | Source | Owner | Used by desk |
|---|---|---|---|---|---|
| `MemoConduit` | Arc 5042 | [`0x516340a244132c62BEdaE5F886Fd35845Af16ba2`](https://arcscan.app/address/0x516340a244132c62BEdaE5F886Fd35845Af16ba2) | `src/rails/MemoConduit.sol` @ 6f5d17b | none (immutable) | yes, live path |
| `MemoConduit` | Avalanche 43114 | [`0x536268d0A6C32a7161BA146F5673dFcF13F1fFe2`](https://snowtrace.io/address/0x536268d0A6C32a7161BA146F5673dFcF13F1fFe2) | `src/rails/MemoConduit.sol` @ 6f5d17b | none (immutable) | yes, live path |

Both share runtime codehash `0xedc25ef190ed44af950ff5a2d0cfc69efed3fd41a80db9a800077b6a278bcad4` (checked with `cast code` on 2026-10-16). Not audited yet; a fix ships as a new deployment plus a desk address switch. Records: `deployments/*-mainnet-memo-conduit.json`.

Where desk uses it: `packages/env/src/memo.ts` (`DEFAULT_MEMO_CONDUIT_ADDRESSES`, env `MEMO_CONDUIT_ADDRESSES`), `apps/shiva/src/services/memo-conduit-chains.ts`, `apps/shiva/src/services/treasury-memo-conduit.service.ts`, `packages/smart-contract-deploy/src/memo-conduit.ts` (ABI and nonce mirror), `contracts/deployments.json`.

### Contract inventory

| Contract | Path | Status | Desk prod | Deployments |
|---|---|---|---|---|
| MemoConduit | `src/rails/MemoConduit.sol` | live on mainnet | **used (live)** on 5042, 43114 | mainnet: Arc, Avalanche; testnet: Arc testnet, Fuji, Base/Arb/OP/Unichain Sepolia, Monad testnet |
| MemoConduit CCTP/CCTPx extension | branch `codex/memo-cctp-20261014` (a27a011) | testnet only, not merged | ABI only (`packages/smart-contract-deploy/src/memo-conduit-bridge.ts`); mainnet out of scope | testnets (see that branch) |
| RecibuMemoRouter | branch `feat/erc3009-memo-router` | testnet only, not merged | configured through env only (`packages/env/src/recibu.ts`, `RECIBU_MEMO_ROUTER_ADDRESSES`); path stays dark | Fuji, Arc testnet |
| InvoiceShelf | `src/invoice/InvoiceShelf.sol` | testnet | no | Arc testnet `0x787B141A8278D44bF1A514805f8EB6a4567DC464` |
| ReceivableEscrow | `src/rails/ReceivableEscrow.sol` | testnet | no | Arc testnet `0xd527bf1d048802402720aE3a3349666bf0f5B189` |
| InvoiceSettlement | `src/rails/InvoiceSettlement.sol` | testnet | no | Arc testnet `0x2060060E10d529039F4120C8bAa49D1BB258962D` |
| InvoiceMemoRouter | `src/rails/InvoiceMemoRouter.sol` | testnet | no (memoId mirrored in `packages/smart-contract-deploy/src/memo.ts`) | Arc testnet `0x9d0442f78604b9524bF2B17373ba9fB07dF4e000` |
| WorkspaceOperatingReserve | `src/rails/WorkspaceOperatingReserve.sol` | testnet | no | Arc testnet `0xFA71acC83CF15dd919aaB399e74976b982B84FDf` |
| BUFIIdentityRegistry | `src/identity/BUFIIdentityRegistry.sol` | testnet | no | Arc testnet `0x63e80E438cFd3727ec8E9536FE04281C1FA9bFb7` |
| BUFIReputationRegistry | `src/identity/BUFIReputationRegistry.sol` | testnet | no | Arc testnet `0xA37012Bf88E4A61B8D6968D0445173048d5Cc27F` |
| BUAttestation | `src/identity/BUAttestation.sol` | testnet | no | Arc testnet `0x9674aDB5e843737eC11B2A2B5166b0d06AdD8505` |
| WorkspaceTierRegistry | `src/credit/WorkspaceTierRegistry.sol` | testnet | no | Arc testnet `0x1899Ea3A876Fd7CbbE5144b21EEcBcA4F1C3E0D9` |
| BUFIOracle (senior/mezz/junior) | `src/invoice/BUFIOracle.sol` | testnet | no | Arc testnet `0xe80c…7725` / `0x1998…1411` / `0x5F69…925C` |
| BINV, BIFTranche | `src/invoice/` | not deployed separately | no | none |
| KybAttestationExtractor, KybWorkspacePolicy | `src/identity/` | not deployed | no | none |
| FactoringSettlementExtractor | `src/rails/FactoringSettlementExtractor.sol` | not deployed | no | none |
| RecibuSettlementGuardHook | `src/hooks/RecibuSettlementGuardHook.sol` | not deployed | no | none |

Deploy scripts: `script/Deploy.s.sol` (factoring rail), `script/DeployMemoConduit.s.sol` and `script/DeployMemoConduitTestnets.s.sol` (CREATE2 through `0x4e59b448…956C`, salt `keccak256("bufi.memo-conduit.v1")`).

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

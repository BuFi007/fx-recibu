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

## Mainnet deployments (Arc 5042, 2026-10-16)

Admin: Safe [`0x47Dc7D18A6E3a79F696714E7D47456a49B430D09`](https://arcscan.app/address/0x47Dc7D18A6E3a79F696714E7D47456a49B430D09). The deployer `0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474` holds no roles. Record: `deployments/arc-mainnet.json`; broadcast: `broadcast/DeployFxRecibuHubMainnet.s.sol/5042/run-latest.json`.

| Contract | Address | Deploy tx | Block |
|---|---|---|---|
| BUFIIdentityRegistry | [`0xe3D6De22135BBd463c0a97A5196782CBCC3f3322`](https://arcscan.app/address/0xe3D6De22135BBd463c0a97A5196782CBCC3f3322) | [`0x6a4775e8…`](https://arcscan.app/tx/0x6a4775e8ad53955bc40c14b5cbc1cc3b2e4f1993d4e3650b1330285ae7896e99) | 26311656 |
| BUFIReputationRegistry | [`0x30015db351747e39102da3F65f51CE0207052415`](https://arcscan.app/address/0x30015db351747e39102da3F65f51CE0207052415) | [`0x75f52147…`](https://arcscan.app/tx/0x75f52147681d748639f0ec7e349c3cefce91184319878d8ede9c50f351ccfd8e) | 26311661 |
| WorkspaceTierRegistry | [`0xfe06281b464d53f00cceca504114263C689e56fe`](https://arcscan.app/address/0xfe06281b464d53f00cceca504114263C689e56fe) | [`0x93d96eab…`](https://arcscan.app/tx/0x93d96eab9533d5478bf835f97f53fa31cb0c9407b786c5a377200a064877f6e4) | 26311668 |
| InvoiceShelf | [`0x8d3006f7be5b5e6e5B7709889a2E5d9EE4d3Cd0a`](https://arcscan.app/address/0x8d3006f7be5b5e6e5B7709889a2E5d9EE4d3Cd0a) | [`0xdef7b9bf…`](https://arcscan.app/tx/0xdef7b9bf1b5660d1bc51b7b6a97e26f668e621ff08917a9f1f3b671df173cde2) | 26311673 |
| MultiTokenReceivableEscrow | [`0xbb4b6BbdaEb3136571d33742385a1Ae59cEE57AB`](https://arcscan.app/address/0xbb4b6BbdaEb3136571d33742385a1Ae59cEE57AB) | [`0xa9120435…`](https://arcscan.app/tx/0xa91204359948a04a9a137da54df2b5c199b7602a1e85ea4e0062df00fe19b0ea) | 26311675 |
| RecibuMemoRouter | [`0x208FBDf4268C87c475189d9EcD7D59b4766E75cB`](https://arcscan.app/address/0x208FBDf4268C87c475189d9EcD7D59b4766E75cB) | [`0x55c44824…`](https://arcscan.app/tx/0x55c4482423368e8b70e1c5ab195ad118ee5d465b728583b3b3aca339db271db3) | 26311679 |

WorkspaceTierRegistry is immutable (no admin). InvoiceShelf: `MIDNIGHT_MODE=true`, `crossChainBuffer=21600`.

Safe wiring batch executed ([`0x4fb1ca1c…`](https://arcscan.app/tx/0x4fb1ca1cd062105f4b7cd09b91b61aaabf7fc0a04f9aaffe8f732094fd44900e)) and verified on-chain: router `tokenConfig(USDC) = (true, 3)`; `shelf.escrow` = the escrow; escrow `ROUTER_ROLE` → router; reputation `SETTLEMENT_ROLE` → shelf.

**Status: DATA-ONLY.** Unassigned: escrow `SETTLEMENT`/`ARBITER`, shelf `SERVICER`/`ADVANCE`/`OPS`, identity `ISSUER`, reputation `ATTESTOR`. No funds can be released or settled until the Safe grants them.

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

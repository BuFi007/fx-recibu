# Plan 003: Consolidate installment truth in InvoiceShelf

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. Execute this only after Plan 001 is complete. If a STOP condition
> occurs, stop and report; do not create another schedule ledger or change a
> funded invoice's economics. Update only this plan's status row in
> `plans/README.md` when its execution state changes. This plan maps to Linear
> BU-336 but does not authorize any Linear mutation.
>
> **Historical execution record**: upstream snapshot `5ee2585` was imported as
> content, not as a Git object. Plan 001 is reachable at `cabddcc`; this plan
> was delivered at `83cb818`. Verify with
> `git merge-base --is-ancestor cabddcc 83cb818 && git merge-base --is-ancestor 83cb818 HEAD`.
> This plan is complete and must not be re-executed as pending work.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: HIGH
- **Depends on**: `plans/001-credit-installments-only-on-full-payment.md`
- **Category**: tech-debt
- **Planned at**: upstream snapshot `5ee2585`; reachable prerequisite `cabddcc`, 2026-07-10
- **Linear mapping**: BU-336

## Why this matters

`InvoiceShelf` is the contractual invoice ledger, but both memo routers accept
and emit a caller-selected installment while escrow stores only an invoice
balance. The CRE extractor checks that the supplied memo hash matches the same
supplied index, then settles cash through `InvoiceShelf`, which independently
applies it to `paidInstallments`, the earliest open installment. A
self-consistent but stale/future correlation label can therefore disagree with
the schedule and events that actually move credit/default state. This plan
keeps every schedule and economic field in `InvoiceShelf`, exposes one
read-only current-installment projection, and makes Memo/CRE installment values
assertions against that projection rather than alternate state.

## Current state

Canonical contractual state already lives in `InvoiceShelf`:

```solidity
// src/invoice/InvoiceShelf.sol:54-68
struct Invoice {
    uint256 sellerAgentId;
    uint256 debtorAgentId;
    uint128 face;
    uint128 advance;
    uint128 outstanding;
    uint128 holdback;
    uint128 holdbackCollected;
    uint64 firstMaturity;
    uint32 interval;
    uint32 grace;
    uint8 nInstallments;
    uint8 paidInstallments;
    uint8 tranche;
    Status status;
}
```

At `src/invoice/InvoiceShelf.sol:289-325`, `_applyPayment` selects
`inv.paidInstallments`, derives its due time, allocates cash, updates exposure,
and emits the contractual `InstallmentPaid`. At `:328-375`, `markDefaulted`
uses the same earliest-open index, maturity, grace, outstanding, and escrow
guard. These remain authoritative.

The rail-facing interface does not expose that schedule at
`src/interfaces/IInvoiceShelf.sol:4-15`:

```solidity
interface IInvoiceShelf {
    enum Status { None, Funded, Settled, Defaulted }
    function applyPaymentFrom(uint256 invoiceId, uint256 amount, address payer) external;
    function invoiceStatus(uint256 invoiceId) external view returns (Status);
    function sellerAgentIdOf(uint256 invoiceId) external view returns (uint256);
}
```

Both routers derive a memo from caller input without validating it against the
shelf:

```solidity
// src/rails/InvoiceMemoRouter.sol:42-58
function memoIdOf(uint256 invoiceId, uint8 installment) public pure returns (bytes32) {
    return keccak256(abi.encodePacked(invoiceId, installment));
}
// pay(...) checks only amount and Funded, deposits invoice-only cash, then emits
// the caller's installment and memo.

// src/rails/RecibuMemoRouter.sol:67-70,144-162
function memoIdOf(uint256 invoiceId, uint8 installment) public pure returns (bytes32) {
    return keccak256(abi.encodePacked(invoiceId, installment));
}
// _guard(...) checks amount, token, and Funded; _bind(...) emits the supplied index.
```

The CRE path at `src/rails/FactoringSettlementExtractor.sol:239-248` verifies
only internal consistency before calling invoice-only settlement:

```solidity
(address token, uint256 invoiceId, uint8 installment, bytes32 memoId) =
    abi.decode(actionPayload, (address, uint256, uint8, bytes32));
bytes32 expectedMemoId = keccak256(abi.encodePacked(invoiceId, installment));
if (memoId != expectedMemoId) revert MemoIdMismatch(memoId, expectedMemoId);
SETTLEMENT.settle(invoiceId);
```

Plan 001's required delivered contract is part of this plan's current state:

- partial cash accumulates against the earliest open installment;
- `paidInstallments` advances and reputation is credited only on full
  installment completion;
- one payment may span complete installments;
- `InvoiceShelf` exposes a deterministic installment amount and a public
  current-progress value;
- default remains keyed to the earliest incomplete installment;
- principal, holdback, exposure, and funded-invoice economics remain unchanged.

The authoritative intent at `SPEC.md:146-158` says settlement applies cash to
the earliest open installment and that first maturity, cadence, grace, count,
and completion drive containment. Memo/CRE indices are correlation data only.

Repository conventions to preserve:

- exact Solidity 0.8.26, custom errors, explicit events, and role gates;
- the shared memo key is `keccak256(abi.encodePacked(uint256 invoiceId,
  uint8 installment))`;
- tests use Foundry fixtures and exact balance/event/custom-error assertions;
- no schedule or provider-health state is added to `fx-recibu-loans`.

## Commands you will need

Run from the `fx-recibu` repository root.

| Purpose | Command | Expected on success |
|---|---|---|
| Confirm execution ancestry | `git merge-base --is-ancestor cabddcc 83cb818 && git merge-base --is-ancestor 83cb818 HEAD` | exit 0 |
| Confirm Plan 001 | `git log --oneline --all -- src/invoice/InvoiceShelf.sol | head -20` and `rg -n 'InstallmentPaymentApplied|installmentAmount|paidInstallments' src/invoice/InvoiceShelf.sol` | Plan 001 implementation and full-payment semantics are present |
| Shelf tests | `forge test --match-path test/unit/InvoiceShelf.t.sol -vv` | exit 0 |
| Rails tests | `forge test --match-path 'test/unit/{Rails,RecibuMemoRouter,FactoringSettlementExtractor}.t.sol' -vv` | exit 0; if brace matching is unsupported, run the three files separately |
| Invariants | `forge test --match-path test/invariant/ShelfInvariants.t.sol -vv` | exit 0 |
| Full suite | `forge test` | exit 0; all repository tests pass |
| Format | `forge fmt --check src/interfaces/IInvoiceShelf.sol src/invoice/InvoiceShelf.sol src/libraries/InvoiceInstallmentKey.sol src/rails/InvoiceMemoRouter.sol src/rails/RecibuMemoRouter.sol src/rails/FactoringSettlementExtractor.sol test/unit/InvoiceShelf.t.sol test/unit/Rails.t.sol test/unit/RecibuMemoRouter.t.sol test/unit/FactoringSettlementExtractor.t.sol test/invariant/ShelfInvariants.t.sol` | exit 0, no diff |
| Patch hygiene | `git diff --check` | exit 0, no output |

No install, fork, RPC, deployment, migration, or sibling-repository command is
required.

## Scope

**In scope** — the only implementation/test files to create or modify:

- `src/interfaces/IInvoiceShelf.sol`
- `src/invoice/InvoiceShelf.sol`
- `src/libraries/InvoiceInstallmentKey.sol` — create; pure memo-key derivation only.
- `src/rails/InvoiceMemoRouter.sol`
- `src/rails/RecibuMemoRouter.sol`
- `src/rails/FactoringSettlementExtractor.sol`
- `test/unit/InvoiceShelf.t.sol`
- `test/unit/Rails.t.sol`
- `test/unit/RecibuMemoRouter.t.sol`
- `test/unit/FactoringSettlementExtractor.t.sol`
- `test/invariant/ShelfInvariants.t.sol`

**Out of scope** — do not touch:

- `src/rails/ReceivableEscrow.sol` and `InvoiceSettlement.sol`; invoice-bound
  escrow and FIFO settlement remain unchanged.
- Invoice economic allocation, principal/holdback/loss math, maturity/cadence/
  grace policy, default/restructure semantics, or Plan 001's partial-payment rule.
- `BUFIReputationRegistry`, `WorkspaceTierRegistry`, BINV, tranche, reserve, or
  identity contracts.
- Any file in `fx-recibu-loans`, Desk, CRE, or fx-telarana. In particular, do
  not create installment/schedule truth in the provider layer.
- Removing either existing router, changing deployed addresses, storage/data
  migration, reprocessing events, or live transactions.
- Any `plans/README.md` row other than this plan's status, GitHub, or Linear.

## Git workflow

- Branch: `codex/003-consolidate-canonical-installment-ledger`.
- Suggested conventional commit: `refactor(factoring): validate canonical installment correlation`.
- Do not push or open a PR unless explicitly instructed.

## Steps

### Step 1: Characterize the post-Plan-001 contractual ledger

Read Plan 001 and its final diff first. Extend `InvoiceShelf.t.sol` before the
rail refactor with characterization tests that pin:

- the current index is `paidInstallments`;
- partial progress leaves the index and default deadline unchanged;
- completing an installment advances exactly once;
- a spanning payment may complete several installments according to Plan 001;
- maturity and grace come only from the shelf schedule;
- full settlement leaves count/progress/economic balances exactly as Plan 001
  specifies.

Do not rename Plan 001's progress mapping or change its allocation rule merely
to make this plan's API prettier.

**Verify**: `forge test --match-path test/unit/InvoiceShelf.t.sol -vv` → exit 0; the characterization cases pass before router/extractor changes.

### Step 2: Expose one read-only current-installment projection

Extend `IInvoiceShelf` and `InvoiceShelf` with a view named
`currentInstallment(uint256 invoiceId)` returning:

- `index`: the earliest incomplete installment;
- `fullAmount`: the deterministic full amount from Plan 001;
- `paidAmount`: the progress already applied to that installment;
- `maturity`: that installment's fixed maturity;
- `graceEndsAt`: maturity plus the invoice's grace.

For a nonexistent, non-Funded, or fully completed invoice, use an exact custom
error rather than returning a synthetic index. Compute this projection directly
from the existing `Invoice` fields and Plan 001's progress/amount helper; do not
copy state to a new mapping or contract.

Add view tests proving the tuple changes only as shelf payment state changes.
No router, escrow, CRE report, provider, or off-chain value may write or
override it.

**Verify**: `forge test --match-path test/unit/InvoiceShelf.t.sol --match-test 'test_currentInstallment' -vv` → exit 0; new view tests pass.

### Step 3: Centralize only the pure correlation-key derivation

Create `src/libraries/InvoiceInstallmentKey.sol` with one internal pure helper
for `keccak256(abi.encodePacked(invoiceId, installment))`. It stores no state and
must not calculate maturity, amount, progress, delinquency, or status.

Make `InvoiceMemoRouter.memoIdOf`, `RecibuMemoRouter.memoIdOf`, and
`FactoringSettlementExtractor` delegate to this helper so the public router
functions/selectors and emitted memo values remain byte-identical. Do not move
the function into `fx-recibu-loans` or duplicate Desk's UUID memo convention.

**Verify**: `rg -n 'keccak256\(abi\.encodePacked\(invoiceId, installment\)\)' src` → exactly one implementation match in `InvoiceInstallmentKey.sol`; existing memo parity tests still pass.

### Step 4: Treat router installment input as an assertion before custody

In both memo routers, extend the existing guard path to call
`SHELF.currentInstallment(invoiceId)` and require the supplied installment to
equal the returned index. Add an exact custom error carrying invoice ID,
supplied index, and expected index. Perform this check before token transfer,
approval, or escrow mutation.

Preserve all current payment entrypoints, token capability checks, escrow
selection, amounts, and event selectors. Multiple deposits may still correlate
to the same currently open installment while cash awaits settlement; the router
must not increment schedule state or invent a pending schedule. Plan 001's
shelf allocation remains the only authority when escrow is drained.

Extend `Rails.t.sol` and `RecibuMemoRouter.t.sol` for legacy, permit, and
ERC-3009 paths:

- current index succeeds and balances/events remain unchanged;
- future and stale indices revert before any transfer/authorization custody
  change;
- partial shelf progress keeps the same accepted index;
- after completion, the old index rejects and the next index succeeds;
- failed assertions leave payer/router/escrow balances and authorization state
  unchanged.

**Verify**: run the Rails and RecibuMemoRouter test files separately → exit 0; all old and new cases pass.

### Step 5: Validate CRE correlation against the same projection

In `FactoringSettlementExtractor._settle`, retain token, memo hash,
operation-ID, target, chain, and expiry checks. After confirming the memo is
self-consistent, query `SHELF.currentInstallment(invoiceId)` and require the
report's installment to equal the shelf's current index before calling
`SETTLEMENT.settle(invoiceId)`. Reuse the same mismatch error shape or a clearly
named extractor-specific custom error.

The report index remains correlation/assertion input. It must not be passed to
a shelf mutator, change schedule state, choose a later maturity, or override
FIFO allocation. A mismatch revert must roll back `processed[operationId]` so a
corrected report can retry under the existing expiry rules.

Add extractor tests for:

- a future index with its correctly computed future memo ID (the current code's
  missing case) rejects and does not consume the operation;
- a stale index after the shelf advances rejects and remains retryable;
- a current index settles and consumes the operation once;
- a partial payment keeps the same current index;
- wrong token and wrong memo regressions remain green.

**Verify**: `forge test --match-path test/unit/FactoringSettlementExtractor.t.sol -vv` → exit 0; exact mismatch/retry assertions pass.

### Step 6: Prove no second ledger or economic drift was introduced

Extend `ShelfInvariants.t.sol` with an invariant that the public current index
equals shelf completion state and never exceeds `nInstallments`; only full
completion changes it. Keep existing exposure, pool-identity, and cash-backed
invariants.

Run the full suite and inspect the diff. Confirm no new mutable installment
state exists outside `InvoiceShelf`, no storage field was added to a router or
provider for schedule truth, and Plan 001's full/partial payment economics are
unchanged.

**Verify**: `forge test --match-path test/invariant/ShelfInvariants.t.sol -vv && forge test && git diff --check` → exit 0; all invariants and the full suite pass.

## Test plan

- Characterize Plan 001's delivered partial/full/spanning behavior before
  changing consumers.
- Add exact current-projection tests in `InvoiceShelf.t.sol`.
- Add future/stale/current correlation tests to both router suites, including
  negative balance and authorization-state assertions.
- Add the missing self-consistent-wrong-index CRE test and prove the operation
  remains retryable.
- Add a shelf invariant tying `currentInstallment` to completion/progress and
  retaining existing solvency/exposure invariants.
- Preserve all existing happy paths, event selectors, memo bytes, payment
  amounts, principal/holdback accounting, and default outcomes.
- Verification order: targeted shelf → routers → extractor → invariants → full
  `forge test`.

## Done criteria

ALL must hold:

- [ ] `git merge-base --is-ancestor cabddcc 83cb818` and `git merge-base --is-ancestor 83cb818 HEAD` exit 0; Plan 001 is present.
- [ ] `InvoiceShelf` remains the only mutable owner of first maturity, cadence, grace, installment count/progress, outstanding, holdback, status, delinquency/default, and restructure state.
- [ ] `currentInstallment` derives from existing shelf state and has no duplicate backing mapping.
- [ ] Both memo routers reject stale/future installment assertions before value movement.
- [ ] CRE rejects a self-consistent wrong installment/memo pair and does not consume its operation ID.
- [ ] `rg -n 'keccak256\(abi\.encodePacked\(invoiceId, installment\)\)' src` has exactly one library implementation.
- [ ] `rg -n 'paidInstallments\s*=' src/rails src/interfaces src/libraries` returns no matches.
- [ ] All targeted unit tests, invariant tests, `forge test`, format check, and `git diff --check` exit 0.
- [ ] Characterization tests prove funded-invoice payment economics, maturity/grace, principal, holdback, exposure, and default outcomes did not change.
- [ ] No file outside the in-scope list is modified.

## STOP conditions

Stop and report back; do not improvise if:

- Plan 001 has not landed, its tests are not green, or it does not preserve
  partial payments while crediting only full installments.
- The live post-Plan-001 symbols/state cannot produce the projection described
  here without another mutable ledger.
- An indexer or signed payload contract requires a supplied installment to
  advance or override the shelf schedule.
- Preserving a current payment path requires accepting an installment other
  than the shelf's earliest open installment.
- The change would reject amounts, alter allocation, change maturities/grace,
  or otherwise change funded-invoice economics rather than only validating
  correlation.
- A migration of live funded invoices, deployed contracts, or historical events
  becomes necessary.
- Work would put schedule/default state in `fx-recibu-loans`, CRE, Desk,
  escrow, or a router.
- A verification command fails twice after a reasonable correction.
- An out-of-scope file must change.

## Maintenance notes

- `InvoiceShelf` is the contract ledger. Memo, CRE, Desk, indexers, and provider
  systems may project its current index but may not become co-writers.
- Multiple escrow deposits can carry the same asserted current index while
  pending; settlement still allocates their aggregate through Plan 001's FIFO
  logic. Reviewers should not mistake custody aggregation for schedule state.
- The pure memo-key library is shared encoding only. A future custom schedule
  must still read the shelf; it must not grow policy inside the library.
- Provider health and liquidation remain separate from contractual delinquency
  and default. Any cross-system reconciliation is a later plan with explicit
  acknowledgement/retry ownership.
- Reviewers should scrutinize check ordering so stale/future inputs revert
  before token movement and CRE operation consumption.

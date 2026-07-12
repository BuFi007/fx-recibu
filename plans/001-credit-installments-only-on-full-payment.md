# Plan 001: Credit installments only when their full amount is paid

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. Update only this plan's status row in
> `plans/README.md` when its execution state changes.
>
> **Historical execution record**: upstream snapshot `5ee2585` was imported as
> content, not as a Git object. The reachable workspace import is `192e0f5`;
> this plan was delivered at `cabddcc`. Verify with
> `git merge-base --is-ancestor 192e0f5 cabddcc && git merge-base --is-ancestor cabddcc HEAD`.
> This plan is complete and must not be re-executed as pending work.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: bug
- **Planned at**: upstream snapshot `5ee2585`; reachable import `192e0f5`, 2026-07-10
- **Linear**: BU-336

## Why this matters

`InvoiceShelf` currently increments `paidInstallments` and awards on-time
reputation for every nonzero payment, even when the payment is far smaller
than the installment due. Small repeated payments can therefore manufacture
credit-limit increases and move the default clock to later maturities while
most principal remains unpaid. This plan preserves partial-payment support but
counts and rewards an installment exactly once, only when cumulative cash
allocated to that installment reaches its deterministic full amount.

## Current state

- `src/invoice/InvoiceShelf.sol` — authoritative invoice schedule, repayment,
  exposure, reputation, and default state machine.
- `test/unit/InvoiceShelf.t.sol` — focused shelf lifecycle tests. Existing
  tests use two equal `250e6` payments for a `500e6` face invoice.

The schedule fields at `src/invoice/InvoiceShelf.sol:54-68` contain a count and
completion index but no partial-progress accounting:

```solidity
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

Every nonzero payment advances the installment and can raise reputation at
`src/invoice/InvoiceShelf.sol:289-321`:

```solidity
if (amount == 0) revert ZeroAmount();
USDC.safeTransferFrom(payer, address(this), amount);

uint8 idx = inv.paidInstallments;
uint256 due = installmentDue(invoiceId, idx);
bool onTime = block.timestamp <= due + inv.grace;

// ... amount is split between outstanding and holdback ...

inv.outstanding -= toOutstanding;
inv.holdbackCollected += remainder;
inv.paidInstallments = idx + 1;

if (onTime) {
    REPUTATION.recordOnTimeInstallment(inv.sellerAgentId);
    REPUTATION.recordPairSettlement(inv.sellerAgentId, inv.debtorAgentId);
}
emit InstallmentPaid(invoiceId, idx, uint256(toOutstanding) + remainder, onTime);
```

Default then trusts that index to select the earliest open maturity at
`src/invoice/InvoiceShelf.sol:328-334`:

```solidity
function markDefaulted(uint256 invoiceId) external onlyRole(SERVICER_ROLE) {
    Invoice storage inv = invoices[invoiceId];
    if (inv.status != Status.Funded) revert BadStatus(invoiceId);
    uint256 due = installmentDue(invoiceId, inv.paidInstallments);
    if (block.timestamp <= due + inv.grace) revert NotPastGrace();
```

The existing happy-path convention at `test/unit/InvoiceShelf.t.sol:147-167`
is equal face-value installments, with principal recovery first and holdback
cash last:

```solidity
// installment 1 (face/2 = 250, all to outstanding): on time
vm.prank(servicer);
shelf.applyPayment(id, 250e6);

// installment 2 (250 = 175 outstanding + 75 holdback): completes face → settle
vm.warp(block.timestamp + 30 days);
vm.prank(servicer);
shelf.applyPayment(id, 250e6);
```

The authoritative rule in `SPEC.md:146-158` is that each installment is a
fixed-maturity slot, settlement applies cash to the earliest open installment,
and reputation increments per settled installment. Match that vocabulary.
Keep custom errors, explicit events, `uint128` USDC accounting, and the current
Checks-Effects-Interactions/revert-atomic style.

## Commands you will need

Run these from the `fx-recibu` repository root.

| Purpose | Command | Expected on success |
|---|---|---|
| Targeted shelf tests | `forge test --match-path test/unit/InvoiceShelf.t.sol -vv` | exit 0; all `InvoiceShelfTest` tests pass |
| Full suite | `forge test` | exit 0; all repository tests pass |
| Format check | `forge fmt --check src/invoice/InvoiceShelf.sol test/unit/InvoiceShelf.t.sol` | exit 0; no formatting diff |
| Patch hygiene | `git diff --check` | exit 0; no whitespace errors |
| Scope check | `git status --short` | only the two in-scope implementation/test files plus plan files are listed |

No install command is required; dependencies are already pinned under `lib/`
and the repository's `foundry.toml` pins Solidity 0.8.26.

## Scope

**In scope** (the only implementation files you should modify):

- `src/invoice/InvoiceShelf.sol`
- `test/unit/InvoiceShelf.t.sol`

**Out of scope** (do NOT touch):

- `src/rails/InvoiceSettlement.sol`, `ReceivableEscrow.sol`, and memo routers —
  they may continue delivering arbitrary positive partial amounts.
- `src/identity/BUFIReputationRegistry.sol` and
  `src/credit/WorkspaceTierRegistry.sol` — their existing one-call-per-complete-
  installment behavior is the desired downstream contract.
- `src/invoice/BINV.sol`, tranche accounting, loss allocation, reserve logic,
  and default-resolution policy.
- CRE workflow repositories, indexers, deployment scripts, deployments, and
  production data migration.
- Plan 002's receivable-commitment work. Do not combine the two changes.

## Git workflow

- Branch: `codex/001-credit-installments-only-on-full-payment`
- Use conventional commits, matching repository history. Suggested commit:
  `fix(shelf): credit only complete installments`.
- Do not push or open a PR unless the operator explicitly instructs it.

## Steps

### Step 1: Define deterministic installment amounts and partial progress

In `InvoiceShelf.sol`:

1. Add a separate public mapping keyed by `invoiceId` for the amount paid
   toward the currently open installment. Do not append a field to `Invoice`;
   preserving the existing public `invoices(uint256)` getter shape limits ABI
   churn.
2. Add a public view `installmentAmount(invoiceId, index)` (or equivalently
   explicit name) with this exact allocation rule:
   - installments `0 .. nInstallments-2` receive
     `face / nInstallments` using floor division;
   - the final installment receives
     `face - base * (nInstallments - 1)`, so all units are allocated and no
     rounding dust remains.
3. Reject an unknown invoice or `index >= nInstallments` with a typed custom
   error. Do not allow division by zero or a generic array/arithmetic panic.
4. Extend schedule validation in `lockInvoice` so `face >= nInstallments` in
   the token's smallest unit. This guarantees every installment is nonzero.
5. Add an `InstallmentPaymentApplied` event for cash allocated to an open
   installment. Include at least invoice ID, installment index, amount applied
   by that fragment, cumulative progress, and full installment amount.
6. Preserve the existing `InstallmentPaid` event signature, but redefine its
   emission point to mean a fully completed installment. This keeps the event
   selector stable while restoring the semantics promised by its name and the
   specification.

Do not change principal/holdback accounting in this step.

**Verify**: `forge test --match-path test/unit/InvoiceShelf.t.sol --match-test 'test_fullLifecycle_onTime|test_lock_gates' -vv` → exit 0; existing lifecycle and schedule-gate behavior still pass after adapting any exact typed-error expectations.

### Step 2: Allocate each payment across the earliest open installment(s)

Refactor `_applyPayment` without changing its external callers:

1. Preserve the current status, zero-amount, transfer, overpayment,
   outstanding, holdback, `totalPrincipal`, `totalLiquid`, and
   `totalHoldbackHeld` checks and effects.
2. Remove the unconditional `paidInstallments = idx + 1`, unconditional
   reputation calls, and unconditional `InstallmentPaid` emission.
3. Route the accepted `amount` through an internal installment-credit helper.
   Starting at `inv.paidInstallments`, apply cash to the earliest open
   installment's remaining amount. A payment may be smaller than one
   installment or span several installments.
4. For each fragment, update the progress mapping and emit
   `InstallmentPaymentApplied`.
5. Only when cumulative progress equals the full amount for that index:
   - reset progress to zero;
   - increment `paidInstallments` exactly once;
   - compute `onTime` against that completed index's fixed maturity plus grace;
   - call `recordOnTimeInstallment` and `recordPairSettlement` only if on time;
   - emit one `InstallmentPaid` carrying the full installment amount.
6. Continue with any remainder against the next index. The loop is bounded by
   `nInstallments`, whose protocol maximum is 12; include an explicit comment
   documenting that gas bound.
7. Before `_settle`, assert through normal typed control flow that full-face
   collection implies `paidInstallments == nInstallments` and current progress
   is zero. If this invariant is not true during implementation, STOP instead
   of adding a silent correction.
8. Leave `markDefaulted` keyed to `paidInstallments`. Because partial cash no
   longer advances the index, it will correctly continue to test the earliest
   incompletely paid installment.

All validation and state writes remain revert-atomic. A rejected overpayment
must not leave partial progress or accounting changes behind.

**Verify**: `forge test --match-path test/unit/InvoiceShelf.t.sol -vv` → exit 0; existing shelf behavior remains green before adding the full regression matrix.

### Step 3: Add regression and boundary tests

Extend `InvoiceShelf.t.sol` with named tests for all of the following:

- a one-unit payment changes cash/outstanding accounting but does not increment
  `paidInstallments`, reputation-derived `limitOf`, or pair history;
- several partial payments totaling one unit less than the installment do not
  credit it;
- the final fragment reaching the exact installment amount credits it once,
  resets progress, and raises the limit by exactly one `RAMP_STEP_USDC`;
- a payment that completes one installment and partially funds the next
  credits exactly one and leaves exact next-installment progress;
- a payment spanning multiple complete installments emits/credits each exactly
  once and never lets `paidInstallments` exceed `nInstallments`;
- a face amount not divisible by `nInstallments` assigns all rounding remainder
  to the final installment and settles with zero progress/dust;
- a face amount smaller than the installment count is rejected at lock;
- completing an installment after its grace window does not raise reputation;
- after a partial first installment, `markDefaulted` succeeds once the first
  maturity plus grace passes rather than using a later maturity;
- overpayment still reverts and leaves progress, exposure, balances, and
  installment count unchanged;
- the original two-payment happy lifecycle still settles, releases holdback,
  burns bINV, and earns exactly two reputation steps.

Add a bounded fuzz test that partitions a full installment into positive
pieces. Before the cumulative sum reaches the threshold, count and reputation
must remain unchanged; crossing the threshold credits exactly once. Bound the
number of fragments so the test remains cheap.

Use exact custom-error assertions and exact balance/count assertions. Do not
use generic `expectRevert()` for the new boundaries.

**Verify**: `forge test --match-path test/unit/InvoiceShelf.t.sol -vv` → exit 0; all existing and new installment tests pass.

### Step 4: Run full verification and inspect event semantics

Run formatting, the entire Foundry suite, and patch hygiene. Inspect the final
diff to confirm `InstallmentPaid` kept its selector and is emitted only from
the full-completion branch, while every accepted partial cash movement has an
`InstallmentPaymentApplied` audit event.

**Verify**: `forge fmt --check src/invoice/InvoiceShelf.sol test/unit/InvoiceShelf.t.sol && forge test && git diff --check` → exit 0; no test or formatting failures.

## Test plan

- Modify only `test/unit/InvoiceShelf.t.sol`.
- Model setup, role grants, funding, and balance assertions after the existing
  `test_fullLifecycle_onTime`, `test_latePayment_doesNotRaiseLimit`, and
  `test_overpaymentBeyondFace_rejected` tests.
- Add at least ten deterministic cases listed in Step 3 plus one bounded fuzz
  partition case.
- Check three state layers after partial and complete payments:
  installment state (`paidInstallments`, progress), economic state
  (`outstanding`, principal, liquid, holdback), and credit state (`limitOf`,
  pair history).
- Verification: `forge test --match-path test/unit/InvoiceShelf.t.sol -vv` → all
  shelf tests pass; `forge test` → the complete repository suite passes.

## Done criteria

ALL must hold:

- [ ] `forge test --match-path test/unit/InvoiceShelf.t.sol -vv` exits 0.
- [ ] `forge test` exits 0.
- [ ] `forge fmt --check src/invoice/InvoiceShelf.sol test/unit/InvoiceShelf.t.sol` exits 0.
- [ ] `git diff --check` exits 0.
- [ ] No positive payment increments `paidInstallments` until cumulative cash
      for the current installment reaches its full deterministic amount.
- [ ] Each completed installment increments count and on-time reputation at
      most once.
- [ ] Partial payments do not move the default deadline to a later installment.
- [ ] The sum of all computed installment amounts equals `face` for divisible
      and non-divisible faces.
- [ ] A full settlement ends with `paidInstallments == nInstallments` and zero
      progress.
- [ ] Existing principal, holdback, exposure, loss, and settlement tests remain
      green.
- [ ] `rg -n "paidInstallments = idx \+ 1" src/invoice/InvoiceShelf.sol` returns no matches.
- [ ] `git status --short` shows no implementation changes outside the two
      in-scope files.
- [ ] No deployment, push, PR, or external mutation was performed.

## STOP conditions

Stop and report back; do not improvise if:

- Either in-scope file differs from the Current state excerpts before work.
- Product/legal requirements specify unequal per-installment principals that
  cannot be represented by equal floor allocation plus final remainder.
- Partial payments are supposed to be rejected or quarantined instead of
  accumulated. That is a different settlement policy.
- A known indexer or passport consumer depends on `InstallmentPaid` meaning
  "any payment attempt" rather than "completed installment" and cannot consume
  the new partial-payment event.
- Full-face collection can occur without exactly completing all computed
  installment amounts; report the accounting counterexample rather than
  forcing the counters to match.
- The change requires modifying a settlement rail, reputation registry, or
  other out-of-scope contract.
- A verification command fails twice after a reasonable correction.

## Maintenance notes

- Reviewers should scrutinize rounding for non-divisible face values, payments
  spanning several installments, and the order of accounting versus external
  reputation calls.
- `Params.MAX_INSTALLMENTS` currently bounds the allocation loop at 12. Any
  future increase must include a gas review.
- The new progress mapping becomes part of invoice state consumed by future
  views/indexers. Never clear it except as an installment completes; full
  settlement must naturally leave it zero.
- If a future version supports custom installment principals, replace the
  deterministic helper with an explicitly committed schedule; do not layer
  exceptions over this equal-allocation rule.
- BU-336 owns any downstream indexer/event migration follow-up.

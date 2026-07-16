// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BUFIIdentityRegistry} from "../../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../../src/identity/BUFIReputationRegistry.sol";
import {WorkspaceTierRegistry} from "../../src/credit/WorkspaceTierRegistry.sol";
import {InvoiceShelf} from "../../src/invoice/InvoiceShelf.sol";
import {BINV} from "../../src/invoice/BINV.sol";
import {ReceivableEscrow} from "../../src/rails/ReceivableEscrow.sol";
import {InvoiceMemoRouter} from "../../src/rails/InvoiceMemoRouter.sol";
import {InvoiceSettlement} from "../../src/rails/InvoiceSettlement.sol";
import {IInvoiceShelf} from "../../src/interfaces/IInvoiceShelf.sol";
import {Params} from "../../src/libraries/Params.sol";
import {ReceivableCommitment} from "../../src/libraries/ReceivableCommitment.sol";
import {StrictAuthorityFixture, StrictAuthorityInvoiceVerifier} from "../utils/StrictAuthorityInvoiceVerifier.sol";

contract RailUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RailsTest is StrictAuthorityFixture {
    RailUSDC internal usdc;
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;
    InvoiceShelf internal shelf;
    StrictAuthorityInvoiceVerifier internal authorityVerifier;
    ReceivableEscrow internal escrow;
    InvoiceMemoRouter internal router;
    InvoiceSettlement internal settlement;

    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");
    address internal attestor = makeAddr("attestor");
    address internal servicer = makeAddr("servicer");
    address internal keeper = makeAddr("keeper");
    address internal ops = makeAddr("ops");
    address internal debtorPayer = makeAddr("debtorPayer");
    address internal sellerOwner = makeAddr("sellerOwner");

    uint256 internal seller;
    uint256 internal debtor;
    uint256 internal invId;

    uint128 internal constant FACE = 500e6;

    function setUp() public {
        usdc = new RailUSDC();
        identity = new BUFIIdentityRegistry(admin);
        reputation = new BUFIReputationRegistry(admin, identity);
        tiers = new WorkspaceTierRegistry(identity, reputation);
        (shelf, authorityVerifier) = _deployStrictShelf(usdc, identity, reputation, tiers, admin);
        escrow = new ReceivableEscrow(usdc, admin);
        router = new InvoiceMemoRouter(usdc, IInvoiceShelf(address(shelf)), escrow);
        settlement = new InvoiceSettlement(usdc, IInvoiceShelf(address(shelf)), escrow, admin);

        vm.startPrank(admin);
        identity.grantRole(identity.ISSUER_ROLE(), issuer);
        reputation.grantRole(reputation.ATTESTOR_ROLE(), attestor);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(shelf));
        shelf.grantRole(shelf.SERVICER_ROLE(), servicer);
        shelf.grantRole(shelf.SETTLEMENT_ROLE(), address(settlement));
        escrow.grantRole(escrow.ROUTER_ROLE(), address(router));
        escrow.grantRole(escrow.SETTLEMENT_ROLE(), address(settlement));
        escrow.grantRole(escrow.ARBITER_ROLE(), ops);
        settlement.grantRole(settlement.KEEPER_ROLE(), keeper);
        shelf.setEscrow(address(escrow));
        vm.stopPrank();

        seller = _ws("seller", sellerOwner, 74, 74);
        debtor = _ws("debtor", debtorPayer, 74, 87);

        address lp = makeAddr("lp");
        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(shelf), type(uint256).max);
        shelf.depositTranche(2, 1_000_000e6); // junior funds thin-history invoices
        vm.stopPrank();

        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _newApprovedTerms(authorityVerifier, seller, debtor, address(usdc), FACE, 2, firstMaturity, 30 days);
        vm.startPrank(servicer);
        invId = _lockInvoiceBound(shelf, seller, debtor, FACE, 2, firstMaturity, 30 days, terms, _docs());
        vm.stopPrank();

        usdc.mint(debtorPayer, 1_000_000e6);
        vm.prank(debtorPayer);
        usdc.approve(address(router), type(uint256).max);
    }

    function _ws(string memory tag, address owner_, uint8 s, uint8 d) internal returns (uint256 id) {
        vm.startPrank(issuer);
        id = identity.registerWorkspace(keccak256(bytes(tag)), owner_);
        identity.setKybStatus(id, true);
        vm.stopPrank();
        vm.prank(attestor);
        reputation.setScore(id, s, d, 1, bytes32("r"));
    }

    function _docs() internal pure returns (BINV.DocBundle memory) {
        return BINV.DocBundle(bytes32("i"), bytes32("a"), bytes32("p"), bytes32("s"), bytes32("d"));
    }

    // ── router: memo-bound deposit ──

    function test_router_paysIntoEscrowWithMemoId() public {
        bytes32 expectedMemo = router.memoIdOf(invId, 0);
        vm.expectEmit(true, true, true, true, address(router));
        emit InvoiceMemoRouter.RecibuPayment(invId, 0, expectedMemo, 250e6, debtorPayer);
        vm.prank(debtorPayer);
        router.pay(invId, 0, 250e6);

        assertEq(escrow.escrowedOf(invId), 250e6);
        assertEq(escrow.totalEscrowed(), 250e6);
        assertEq(usdc.balanceOf(address(escrow)), 250e6);
    }

    function test_router_rejectsUnfundedInvoice() public {
        vm.prank(debtorPayer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceMemoRouter.InvoiceNotFunded.selector, 999));
        router.pay(999, 0, 100e6);
    }

    function test_router_rejectsPayerThatDoesNotOwnDebtorWorkspace() public {
        address attacker = makeAddr("attacker");
        usdc.mint(attacker, 100e6);
        vm.prank(attacker);
        usdc.approve(address(router), 100e6);

        vm.expectRevert(
            abi.encodeWithSelector(InvoiceMemoRouter.UnauthorizedPayer.selector, invId, attacker, debtorPayer)
        );
        vm.prank(attacker);
        router.pay(invId, 0, 100e6);

        assertEq(usdc.balanceOf(attacker), 100e6);
        assertEq(escrow.escrowedOf(invId), 0);
    }

    function test_router_rejectsNonCanonicalShelfEscrowBeforeCustodyMutation() public {
        ReceivableEscrow wrongEscrow = new ReceivableEscrow(usdc, admin);
        InvoiceMemoRouter wrongRouter = new InvoiceMemoRouter(usdc, IInvoiceShelf(address(shelf)), wrongEscrow);
        bytes32 routerRole = wrongEscrow.ROUTER_ROLE();
        vm.prank(admin);
        wrongEscrow.grantRole(routerRole, address(wrongRouter));
        vm.prank(debtorPayer);
        usdc.approve(address(wrongRouter), 100e6);
        uint256 payerBalance = usdc.balanceOf(debtorPayer);

        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceMemoRouter.CanonicalEscrowMismatch.selector, address(wrongEscrow), address(escrow)
            )
        );
        vm.prank(debtorPayer);
        wrongRouter.pay(invId, 0, 100e6);

        assertEq(usdc.balanceOf(debtorPayer), payerBalance);
        assertEq(wrongEscrow.escrowedOf(invId), 0);
    }

    function test_router_rejectsFutureInstallmentBeforeCustodyMutation() public {
        uint256 payerBalance = usdc.balanceOf(debtorPayer);
        uint256 routerBalance = usdc.balanceOf(address(router));
        uint256 escrowBalance = usdc.balanceOf(address(escrow));
        uint256 allowance = usdc.allowance(debtorPayer, address(router));

        vm.expectRevert(
            abi.encodeWithSelector(InvoiceMemoRouter.InstallmentMismatch.selector, invId, uint8(1), uint8(0))
        );
        vm.prank(debtorPayer);
        router.pay(invId, 1, 100e6);

        assertEq(usdc.balanceOf(debtorPayer), payerBalance);
        assertEq(usdc.balanceOf(address(router)), routerBalance);
        assertEq(usdc.balanceOf(address(escrow)), escrowBalance);
        assertEq(usdc.allowance(debtorPayer, address(router)), allowance);
        assertEq(escrow.escrowedOf(invId), 0);
    }

    function test_router_partialShelfProgressKeepsCurrentInstallmentAccepted() public {
        vm.prank(debtorPayer);
        router.pay(invId, 0, 100e6);
        vm.prank(keeper);
        settlement.settle(invId);

        (uint8 index,, uint256 paidAmount,,) = shelf.currentInstallment(invId);
        assertEq(index, 0);
        assertEq(paidAmount, 100e6);

        vm.prank(debtorPayer);
        router.pay(invId, 0, 50e6);
        assertEq(escrow.escrowedOf(invId), 50e6);
    }

    function test_router_rejectsStaleAfterCompletionAndAcceptsNextInstallment() public {
        vm.prank(debtorPayer);
        router.pay(invId, 0, 250e6);
        vm.prank(keeper);
        settlement.settle(invId);

        uint256 payerBalance = usdc.balanceOf(debtorPayer);
        uint256 allowance = usdc.allowance(debtorPayer, address(router));
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceMemoRouter.InstallmentMismatch.selector, invId, uint8(0), uint8(1))
        );
        vm.prank(debtorPayer);
        router.pay(invId, 0, 100e6);

        assertEq(usdc.balanceOf(debtorPayer), payerBalance);
        assertEq(usdc.allowance(debtorPayer, address(router)), allowance);
        assertEq(escrow.escrowedOf(invId), 0);

        vm.prank(debtorPayer);
        router.pay(invId, 1, 100e6);
        assertEq(escrow.escrowedOf(invId), 100e6);
    }

    // ── settlement: escrow → shelf, drives reputation + settle ──

    function test_settlement_appliesEscrowToShelf_onTimeRaisesLimit() public {
        uint256 limitBefore = tiers.limitOf(seller);
        vm.warp(block.timestamp + 30 days);
        vm.prank(debtorPayer);
        router.pay(invId, 0, 250e6);

        vm.prank(keeper);
        uint256 applied = settlement.settle(invId);
        assertEq(applied, 250e6);
        assertEq(escrow.escrowedOf(invId), 0);
        // on-time installment recorded → L(w) grows; pair history waits for full settlement
        assertEq(tiers.limitOf(seller), limitBefore + Params.RAMP_STEP_USDC);
        assertFalse(tiers.hasPairHistory(seller, debtor), "pair history requires a fully settled invoice");
    }

    function test_settlement_fullLifecycleThroughRails() public {
        // installment 1
        vm.prank(debtorPayer);
        router.pay(invId, 0, 250e6);
        vm.prank(keeper);
        settlement.settle(invId);

        // installment 2 completes face → invoice settles, holdback released to seller
        uint256 sellerBal = usdc.balanceOf(sellerOwner);
        vm.warp(block.timestamp + 30 days);
        vm.prank(debtorPayer);
        router.pay(invId, 1, 250e6);
        vm.prank(keeper);
        settlement.settle(invId);

        assertEq(uint8(shelf.invoiceStatus(invId)), uint8(IInvoiceShelf.Status.Settled));
        assertEq(usdc.balanceOf(sellerOwner) - sellerBal, 75e6); // holdback
        assertTrue(tiers.hasPairHistory(seller, debtor));
    }

    function test_settlement_revertsWhenNothingEscrowed() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(InvoiceSettlement.NothingEscrowed.selector, invId));
        settlement.settle(invId);
    }

    function test_settlePendingAndMarkDefaulted_fullInstallmentCuresCurrentDefault() public {
        vm.warp(block.timestamp + 40 days);
        vm.prank(debtorPayer);
        router.pay(invId, 0, 250e6);

        vm.prank(keeper);
        (uint256 applied, bool defaulted) = settlement.settlePendingAndMarkDefaulted(invId);

        assertEq(applied, 250e6);
        assertFalse(defaulted);
        assertEq(escrow.escrowedOf(invId), 0);
        assertEq(uint8(shelf.invoiceStatus(invId)), uint8(IInvoiceShelf.Status.Funded));
        (uint8 index,, uint256 progress,,) = shelf.currentInstallment(invId);
        assertEq(index, 1);
        assertEq(progress, 0);
        assertEq(shelf.trancheLoss(2), 0);
        assertFalse(shelf.workspaceFrozen(seller));
    }

    function test_settlePendingAndMarkDefaulted_partialCureBooksOnlyNetLoss() public {
        vm.warp(block.timestamp + 40 days);
        vm.prank(debtorPayer);
        router.pay(invId, 0, 100e6);

        vm.prank(keeper);
        (uint256 applied, bool defaulted) = settlement.settlePendingAndMarkDefaulted(invId);

        assertEq(applied, 100e6);
        assertTrue(defaulted);
        assertEq(escrow.escrowedOf(invId), 0);
        assertEq(uint8(shelf.invoiceStatus(invId)), uint8(IInvoiceShelf.Status.Defaulted));
        assertEq(shelf.trancheLoss(2), 325e6, "real cash reduces loss before write-off");
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_settlePendingAndMarkDefaulted_dustCannotFrontRunDefault() public {
        vm.warp(block.timestamp + 40 days);
        vm.prank(debtorPayer);
        router.pay(invId, 0, 1);

        vm.prank(keeper);
        (uint256 applied, bool defaulted) = settlement.settlePendingAndMarkDefaulted(invId);

        assertEq(applied, 1);
        assertTrue(defaulted);
        assertEq(escrow.escrowedOf(invId), 0);
        assertEq(uint8(shelf.invoiceStatus(invId)), uint8(IInvoiceShelf.Status.Defaulted));
        assertEq(shelf.trancheLoss(2), 425e6 - 1, "dust is applied before objective default");
    }

    function test_settlePendingAndMarkDefaulted_cannotForceSettleBeforeGrace() public {
        vm.prank(debtorPayer);
        router.pay(invId, 0, 100e6);
        (,,,, uint256 graceEndsAt) = shelf.currentInstallment(invId);

        address permissionlessCaller = makeAddr("permissionlessCaller");
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceSettlement.DefaultWindowNotOpen.selector, invId, graceEndsAt, block.timestamp)
        );
        vm.prank(permissionlessCaller);
        settlement.settlePendingAndMarkDefaulted(invId);

        assertEq(escrow.escrowedOf(invId), 100e6, "refundable custody must remain untouched");
        assertEq(usdc.balanceOf(address(escrow)), 100e6);
        assertEq(uint8(shelf.invoiceStatus(invId)), uint8(IInvoiceShelf.Status.Funded));
    }

    function test_settlePendingAndMarkDefaulted_pendingCashRemainsKeeperGatedAfterGrace() public {
        vm.warp(block.timestamp + 40 days);
        vm.prank(debtorPayer);
        router.pay(invId, 0, 100e6);

        address permissionlessCaller = makeAddr("permissionlessCaller");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, permissionlessCaller, settlement.KEEPER_ROLE()
            )
        );
        vm.prank(permissionlessCaller);
        settlement.settlePendingAndMarkDefaulted(invId);

        assertEq(escrow.escrowedOf(invId), 100e6);
        assertEq(usdc.balanceOf(address(escrow)), 100e6);
        assertEq(uint8(shelf.invoiceStatus(invId)), uint8(IInvoiceShelf.Status.Funded));
    }

    // ── escrow hardening (refund-protocol redesign — THREAT_MODEL T5) ──

    function test_escrow_arbiterCannotTouchUnrelatedInvoice() public {
        // fund invoice A's escrow
        vm.prank(debtorPayer);
        router.pay(invId, 0, 250e6);

        // a SECOND invoice with zero escrow
        uint256 invB = 424242;
        // arbiter tries to refund invB (empty) to itself → cannot pull invId's funds
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ReceivableEscrow.RefundLockNotSet.selector, invB));
        escrow.refund(invB, ops, 250e6);
        // invId funds untouched
        assertEq(escrow.escrowedOf(invId), 250e6);
    }

    function test_escrow_refundRespectsLockup() public {
        (,,, uint256 maturity, uint256 graceEndsAt) = shelf.currentInstallment(invId);
        uint64 unlockAt = uint64(block.timestamp + (graceEndsAt - maturity));
        vm.prank(debtorPayer);
        router.pay(invId, 0, 250e6);

        assertEq(escrow.refundUnlockAt(invId), unlockAt);

        vm.warp(unlockAt - 1);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ReceivableEscrow.RefundLocked.selector, invId, unlockAt));
        escrow.refund(invId, debtorPayer, 100e6);

        vm.warp(unlockAt);
        vm.prank(ops);
        escrow.refund(invId, debtorPayer, 100e6); // exact policy boundary is allowed
        assertEq(escrow.escrowedOf(invId), 150e6);
    }

    function test_router_latePaymentStillGetsFullTierRefundWindow() public {
        (,,, uint256 maturity, uint256 graceEndsAt) = shelf.currentInstallment(invId);
        uint256 lockDuration = graceEndsAt - maturity;
        vm.warp(graceEndsAt + 1 days);
        uint64 unlockAt = uint64(block.timestamp + lockDuration);

        vm.prank(debtorPayer);
        router.pay(invId, 0, 100e6);
        assertEq(escrow.refundUnlockAt(invId), unlockAt);

        vm.warp(unlockAt - 1);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ReceivableEscrow.RefundLocked.selector, invId, unlockAt));
        escrow.refund(invId, debtorPayer, 100e6);

        vm.warp(unlockAt);
        vm.prank(ops);
        escrow.refund(invId, debtorPayer, 100e6);
        assertEq(escrow.escrowedOf(invId), 0);
    }

    function test_escrow_depositWithoutRefundLockFailsClosed() public {
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(ReceivableEscrow.AtomicRefundLockRequired.selector, invId));
        escrow.deposit(invId, 1, address(router));
    }

    function test_escrow_committedRefundLockCannotChange() public {
        vm.prank(debtorPayer);
        router.pay(invId, 0, 250e6);
        uint64 current = escrow.refundUnlockAt(invId);

        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(ReceivableEscrow.RefundLockAlreadyCommitted.selector, invId, current));
        escrow.setRefundLock(invId, current - 1);
    }

    function test_router_partialDepositsDoNotExtendCommittedRefundLock() public {
        vm.prank(debtorPayer);
        router.pay(invId, 0, 100e6);
        uint64 firstLock = escrow.refundUnlockAt(invId);

        vm.warp(block.timestamp + 1 days);
        vm.prank(debtorPayer);
        router.pay(invId, 0, 50e6);

        assertEq(escrow.refundUnlockAt(invId), firstLock);
        assertEq(escrow.escrowedOf(invId), 150e6);
    }

    function test_router_rejectsNewPartialDepositAfterCommittedWindowElapses() public {
        vm.prank(debtorPayer);
        router.pay(invId, 0, 100e6);
        uint64 committedLock = escrow.refundUnlockAt(invId);
        vm.warp(committedLock);
        uint256 payerBalance = usdc.balanceOf(debtorPayer);

        vm.expectRevert(abi.encodeWithSelector(ReceivableEscrow.RefundWindowElapsed.selector, invId, committedLock));
        vm.prank(debtorPayer);
        router.pay(invId, 0, 50e6);

        assertEq(usdc.balanceOf(debtorPayer), payerBalance);
        assertEq(escrow.escrowedOf(invId), 100e6);
        assertEq(escrow.refundUnlockAt(invId), committedLock);
    }

    function test_router_rejectsAggregatePartialOverpaymentBeforeCustodyMutation() public {
        vm.prank(debtorPayer);
        router.pay(invId, 0, 200e6);
        uint256 payerBalance = usdc.balanceOf(debtorPayer);
        uint256 allowance = usdc.allowance(debtorPayer, address(router));
        uint64 committedLock = escrow.refundUnlockAt(invId);

        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceMemoRouter.PaymentExceedsInstallmentRemaining.selector, invId, 51e6, 250e6, 200e6
            )
        );
        vm.prank(debtorPayer);
        router.pay(invId, 0, 51e6);

        assertEq(usdc.balanceOf(debtorPayer), payerBalance);
        assertEq(usdc.allowance(debtorPayer, address(router)), allowance);
        assertEq(escrow.escrowedOf(invId), 200e6);
        assertEq(escrow.refundUnlockAt(invId), committedLock);
    }

    function test_escrow_onlyRolesCanMoveFunds() public {
        vm.prank(debtorPayer);
        router.pay(invId, 0, 250e6);
        // random cannot release or refund
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        escrow.releaseTo(invId, makeAddr("rando"), 250e6);
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        escrow.refund(invId, makeAddr("rando"), 250e6);
        // deposit is router-gated
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        escrow.deposit(invId, 1, makeAddr("rando"));
    }

    /// @notice escrow solvency: Σ escrowedOf == USDC held, always.
    function test_escrow_solvency() public {
        vm.prank(debtorPayer);
        router.pay(invId, 0, 250e6);
        assertEq(escrow.totalEscrowed(), usdc.balanceOf(address(escrow)));
        vm.prank(keeper);
        settlement.settle(invId);
        assertEq(escrow.totalEscrowed(), usdc.balanceOf(address(escrow)));
        assertEq(escrow.totalEscrowed(), 0);
    }

    // ── markDefaulted must not phantom-default an invoice already paid into escrow ──
    //    (Gateman HIGH — markDefaulted ignored ReceivableEscrow, booking a fake loss
    //     + freezing a paying seller while the debtor's cash sat in escrow)

    function test_directServicerPaymentIsDisabledAfterCanonicalEscrowWiring() public {
        vm.prank(debtorPayer);
        router.pay(invId, 0, 200e6);
        usdc.mint(servicer, 100e6);
        vm.prank(servicer);
        usdc.approve(address(shelf), 100e6);

        uint256 servicerBalance = usdc.balanceOf(servicer);
        vm.prank(servicer);
        vm.expectRevert(InvoiceShelf.DirectPaymentDisabled.selector);
        shelf.applyPayment(invId, 100e6);
        assertEq(usdc.balanceOf(servicer), servicerBalance);
        assertEq(shelf.installmentProgress(invId), 0);
        assertEq(escrow.escrowedOf(invId), 200e6);

        vm.prank(keeper);
        assertEq(settlement.settle(invId), 200e6, "canonical escrow remains settleable");
        assertEq(shelf.installmentProgress(invId), 200e6);
        assertEq(escrow.escrowedOf(invId), 0);
    }

    function test_markDefaulted_revertsWhenEscrowFunded() public {
        // debtor pays on time into escrow, but the keeper has NOT settled yet
        vm.prank(debtorPayer);
        router.pay(invId, 0, 250e6);
        // installment-0 grace elapses before settle() runs
        vm.warp(block.timestamp + 40 days);
        // servicer default attempt must be blocked — the payment is sitting in escrow
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.EscrowPendingSettlement.selector, invId));
        shelf.markDefaulted(invId);
        // funds untouched, seller not frozen, no phantom loss
        assertEq(escrow.escrowedOf(invId), 250e6);
        assertFalse(shelf.workspaceFrozen(seller));
        assertEq(uint8(shelf.invoiceStatus(invId)), uint8(IInvoiceShelf.Status.Funded));
    }

    function test_markDefaulted_succeedsWhenGenuinelyUnpaid() public {
        // no escrow deposit at all; grace elapses → a real miss defaults normally
        vm.warp(block.timestamp + 40 days);
        vm.prank(servicer);
        shelf.markDefaulted(invId);
        assertEq(uint8(shelf.invoiceStatus(invId)), uint8(IInvoiceShelf.Status.Defaulted));
        assertTrue(shelf.workspaceFrozen(seller));
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BUFIIdentityRegistry} from "../../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../../src/identity/BUFIReputationRegistry.sol";
import {WorkspaceTierRegistry} from "../../src/credit/WorkspaceTierRegistry.sol";
import {InvoiceShelf} from "../../src/invoice/InvoiceShelf.sol";
import {BINV} from "../../src/invoice/BINV.sol";
import {ReceivableCommitment} from "../../src/libraries/ReceivableCommitment.sol";
import {FactoringEvidenceV1} from "../../src/libraries/FactoringEvidenceV1.sol";
import {ReceivableEscrow} from "../../src/rails/ReceivableEscrow.sol";
import {InvoiceMemoRouter} from "../../src/rails/InvoiceMemoRouter.sol";
import {InvoiceSettlement} from "../../src/rails/InvoiceSettlement.sol";
import {IInvoiceShelf} from "../../src/interfaces/IInvoiceShelf.sol";
import {Params} from "../../src/libraries/Params.sol";

contract RailUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RailsTest is Test {
    RailUSDC internal usdc;
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;
    InvoiceShelf internal shelf;
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
        shelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin, false);
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
        debtor = _ws("debtor", makeAddr("dOwner"), 74, 87);

        address lp = makeAddr("lp");
        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(shelf), type(uint256).max);
        shelf.depositTranche(2, 1_000_000e6); // junior funds thin-history invoices
        vm.stopPrank();

        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        vm.prank(servicer);
        invId = shelf.lockInvoice(
            seller,
            debtor,
            FACE,
            2,
            firstMaturity,
            30 days,
            _terms(keccak256("ARCA:rails:primary"), firstMaturity),
            _evidence(keccak256("ARCA:rails:primary")),
            _docs()
        );

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

    function _terms(bytes32 authorityId, uint64 firstMaturity)
        internal
        view
        returns (ReceivableCommitment.Terms memory)
    {
        return ReceivableCommitment.Terms({
            canonicalInvoiceCommitmentHash: authorityId,
            issuedAt: uint64(block.timestamp),
            dueAt: firstMaturity + 30 days
        });
    }

    function _evidence(bytes32 seed) internal pure returns (FactoringEvidenceV1 memory) {
        return FactoringEvidenceV1({
            featureRootHash: keccak256(abi.encode("FEATURE_ROOT", seed)),
            currentSnapshotHash: keccak256(abi.encode("CURRENT_SNAPSHOT", seed)),
            privateTermsHash: keccak256(abi.encode("PRIVATE_TERMS", seed))
        });
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

    // ── settlement: escrow → shelf, drives reputation + settle ──

    function test_settlement_appliesEscrowToShelf_onTimeRaisesLimit() public {
        uint256 limitBefore = tiers.limitOf(seller);
        vm.prank(debtorPayer);
        router.pay(invId, 0, 250e6);

        vm.prank(keeper);
        uint256 applied = settlement.settle(invId);
        assertEq(applied, 250e6);
        assertEq(escrow.escrowedOf(invId), 0);
        // on-time installment recorded → L(w) grew + pair history now exists
        assertEq(tiers.limitOf(seller), limitBefore + Params.RAMP_STEP_USDC);
        assertTrue(tiers.hasPairHistory(seller, debtor));
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
    }

    function test_settlement_revertsWhenNothingEscrowed() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(InvoiceSettlement.NothingEscrowed.selector, invId));
        settlement.settle(invId);
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
        vm.expectRevert(abi.encodeWithSelector(ReceivableEscrow.InsufficientEscrow.selector, invB, 0, 250e6));
        escrow.refund(invB, ops, 250e6);
        // invId funds untouched
        assertEq(escrow.escrowedOf(invId), 250e6);
    }

    function test_escrow_refundRespectsLockup() public {
        vm.prank(debtorPayer);
        router.pay(invId, 0, 250e6);
        // set a refund lock 7 days out (per-tier lockup); admin self-grants ROUTER_ROLE
        bytes32 routerRole = escrow.ROUTER_ROLE();
        uint64 unlockAt = uint64(block.timestamp + 7 days);
        vm.startPrank(admin);
        escrow.grantRole(routerRole, admin);
        escrow.setRefundLock(invId, unlockAt);
        vm.stopPrank();

        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ReceivableEscrow.RefundLocked.selector, invId, unlockAt));
        escrow.refund(invId, debtorPayer, 100e6);

        vm.warp(block.timestamp + 7 days);
        vm.prank(ops);
        escrow.refund(invId, debtorPayer, 100e6); // now allowed
        assertEq(escrow.escrowedOf(invId), 150e6);
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
        router.pay(invId, 0, 300e6);
        assertEq(escrow.totalEscrowed(), usdc.balanceOf(address(escrow)));
        vm.prank(keeper);
        settlement.settle(invId);
        assertEq(escrow.totalEscrowed(), usdc.balanceOf(address(escrow)));
        assertEq(escrow.totalEscrowed(), 0);
    }

    // ── markDefaulted must not phantom-default an invoice already paid into escrow ──
    //    (Gateman HIGH — markDefaulted ignored ReceivableEscrow, booking a fake loss
    //     + freezing a paying seller while the debtor's cash sat in escrow)

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

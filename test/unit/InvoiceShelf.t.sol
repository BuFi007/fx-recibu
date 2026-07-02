// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BUFIIdentityRegistry} from "../../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../../src/identity/BUFIReputationRegistry.sol";
import {WorkspaceTierRegistry} from "../../src/credit/WorkspaceTierRegistry.sol";
import {InvoiceShelf} from "../../src/invoice/InvoiceShelf.sol";
import {BINV} from "../../src/invoice/BINV.sol";
import {Params} from "../../src/libraries/Params.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Numbers used throughout (respecting the SPEC §3.5 caps at cold start):
///   L0 = 1,500 USDC · per-debtor concentration = 30% of L(w) = 450 USDC
///   face 500 · debtor Excellent(87) no pair history → advance 85% = 425 (≤ 450 ✓)
///   holdback = 75 · junior-funded (no pair history → TrancheEligibility.JuniorC)
contract InvoiceShelfTest is Test {
    MockUSDC internal usdc;
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;
    InvoiceShelf internal shelf;

    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");
    address internal attestor = makeAddr("attestor");
    address internal servicer = makeAddr("servicer");
    address internal lp = makeAddr("lp");
    address internal sellerOwner = makeAddr("sellerOwner");

    uint256 internal seller;
    uint256 internal debtor;

    uint128 internal constant FACE = 500e6;
    uint128 internal constant ADVANCE = 425e6; // 85%
    uint128 internal constant HOLDBACK = 75e6;

    function setUp() public {
        usdc = new MockUSDC();
        identity = new BUFIIdentityRegistry(admin);
        reputation = new BUFIReputationRegistry(admin, identity);
        tiers = new WorkspaceTierRegistry(identity, reputation);
        shelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin);

        vm.startPrank(admin);
        identity.grantRole(identity.ISSUER_ROLE(), issuer);
        reputation.grantRole(reputation.ATTESTOR_ROLE(), attestor);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(shelf));
        shelf.grantRole(shelf.SERVICER_ROLE(), servicer);
        vm.stopPrank();

        seller = _newWorkspace("seller", sellerOwner, 74, 74);
        debtor = _newWorkspace("debtor", makeAddr("debtorOwner"), 74, 87);

        // fund all three tranches
        usdc.mint(lp, 3_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(shelf), type(uint256).max);
        shelf.depositTranche(0, 1_000_000e6);
        shelf.depositTranche(1, 1_000_000e6);
        shelf.depositTranche(2, 1_000_000e6);
        vm.stopPrank();

        // servicer relays debtor cash in M3 tests (Memo router fronts this in M5)
        usdc.mint(servicer, 1_000_000e6);
        vm.prank(servicer);
        usdc.approve(address(shelf), type(uint256).max);
    }

    function _newWorkspace(string memory tag, address owner_, uint8 sellerScore, uint8 debtorScore)
        internal
        returns (uint256 id)
    {
        vm.startPrank(issuer);
        id = identity.registerWorkspace(keccak256(bytes(tag)), owner_);
        identity.setKybStatus(id, true);
        vm.stopPrank();
        vm.prank(attestor);
        reputation.setScore(id, sellerScore, debtorScore, 1, bytes32("r"));
    }

    function _docs() internal pure returns (BINV.DocBundle memory) {
        return BINV.DocBundle(bytes32("inv"), bytes32("assign"), bytes32("pay"), bytes32("svc"), bytes32("disp"));
    }

    function _lock(uint256 sellerId, uint256 debtorId, uint128 face) internal returns (uint256 id) {
        vm.prank(servicer);
        id = shelf.lockInvoice(sellerId, debtorId, face, 2, uint64(block.timestamp + 30 days), 30 days, _docs());
    }

    // ── lock ──

    function test_lock_fundsAdvanceMintsBinvTracksExposure() public {
        uint256 sellerBalBefore = usdc.balanceOf(sellerOwner);
        uint256 id = _lock(seller, debtor, FACE);

        assertEq(usdc.balanceOf(sellerOwner) - sellerBalBefore, ADVANCE);
        assertEq(shelf.BINV_TOKEN().ownerOf(id), sellerOwner);
        assertEq(shelf.outstandingOf(seller), ADVANCE);
        assertEq(shelf.debtorOutstandingOf(seller, debtor), ADVANCE);
        // shared pool: cash deployed, principal booked, junior tagged as first-loss layer
        assertEq(shelf.totalPrincipal(), ADVANCE);
        assertEq(shelf.totalLiquid(), 3_000_000e6 - ADVANCE);
        // NAV basis unchanged by lending (advance is a par receivable): junior still whole
        assertEq(shelf.trancheAssets(2), 1_000_000e6);
    }

    function test_lock_gates() public {
        // exposure cap: face 2000 → advance 1700 > L0 1500
        vm.prank(servicer);
        vm.expectRevert();
        shelf.lockInvoice(seller, debtor, 2000e6, 2, uint64(block.timestamp + 30 days), 30 days, _docs());

        // concentration cap: second invoice to the SAME debtor breaches 450
        _lock(seller, debtor, FACE); // 425 outstanding to this debtor
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.ConcentrationCapExceeded.selector, debtor));
        shelf.lockInvoice(seller, debtor, 100e6, 2, uint64(block.timestamp + 30 days), 30 days, _docs());

        // unKYB'd counterparty
        vm.prank(issuer);
        identity.setKybStatus(debtor, false);
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.NotEligible.selector, debtor));
        shelf.lockInvoice(seller, debtor, 100e6, 2, uint64(block.timestamp + 30 days), 30 days, _docs());

        // unauthorized caller
        vm.prank(lp);
        vm.expectRevert();
        shelf.lockInvoice(seller, debtor, 100e6, 2, uint64(block.timestamp + 30 days), 30 days, _docs());
    }

    // ── the happy loop: pay on time → L(w) grows → settle releases collected holdback ──

    function test_fullLifecycle_onTime() public {
        uint256 id = _lock(seller, debtor, FACE);
        uint256 limitBefore = tiers.limitOf(seller);

        // installment 1 (face/2 = 250, all to outstanding): on time
        vm.prank(servicer);
        shelf.applyPayment(id, 250e6);
        assertEq(tiers.limitOf(seller), limitBefore + Params.RAMP_STEP_USDC);
        assertTrue(tiers.hasPairHistory(seller, debtor));

        // installment 2 (250 = 175 outstanding + 75 holdback): completes face → settle
        uint256 sellerBal = usdc.balanceOf(sellerOwner);
        vm.warp(block.timestamp + 30 days);
        vm.prank(servicer);
        shelf.applyPayment(id, 250e6);

        assertEq(usdc.balanceOf(sellerOwner) - sellerBal, HOLDBACK, "holdback released on settle");
        assertEq(shelf.outstandingOf(seller), 0);
        assertEq(shelf.totalPrincipal(), 0, "pool made whole");
        assertEq(shelf.trancheAssets(2), 1_000_000e6, "junior NAV back to par, no loss");
        assertEq(tiers.limitOf(seller), limitBefore + 2 * Params.RAMP_STEP_USDC);
        BINV binv = shelf.BINV_TOKEN();
        vm.expectRevert();
        binv.ownerOf(id); // bINV burnt
    }

    function test_latePayment_doesNotRaiseLimit() public {
        uint256 id = _lock(seller, debtor, FACE);
        uint256 limitBefore = tiers.limitOf(seller);
        vm.warp(block.timestamp + 30 days + Params.GRACE_STRONG + 1); // past due1 + grace
        vm.prank(servicer);
        shelf.applyPayment(id, 250e6);
        assertEq(tiers.limitOf(seller), limitBefore, "late payment must not raise L(w)");
    }

    function test_overpaymentBeyondFace_rejected() public {
        uint256 id = _lock(seller, debtor, FACE);
        vm.prank(servicer);
        vm.expectRevert(InvoiceShelf.ZeroAmount.selector);
        shelf.applyPayment(id, FACE + 1);
    }

    // ── default: blast radius + junior-first waterfall + one-way freeze ──

    function test_default_blastRadiusAndJuniorFirstLoss() public {
        uint256 id = _lock(seller, debtor, FACE);

        // installment 1 paid on time (250 → outstanding 175)
        vm.prank(servicer);
        shelf.applyPayment(id, 250e6);

        // installment 2 missed → default past grace
        vm.warp(block.timestamp + 60 days + Params.GRACE_STRONG + 1);
        vm.prank(servicer);
        shelf.markDefaulted(id);

        // I2: loss (175) fills JUNIOR first; senior/mezz untouched
        assertEq(shelf.trancheLoss(2), 175e6);
        assertEq(shelf.trancheLoss(1), 0);
        assertEq(shelf.trancheLoss(0), 0);
        // blast radius (SPEC §3.6): loss ≈ one installment, NOT the full advance
        assertLt(shelf.trancheLoss(2), ADVANCE);
        // exposure cleared + one-way freeze
        assertEq(shelf.outstandingOf(seller), 0);
        assertTrue(shelf.workspaceFrozen(seller));
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.Frozen.selector, seller));
        shelf.lockInvoice(seller, debtor, 100e6, 2, uint64(block.timestamp + 30 days), 30 days, _docs());
    }

    function test_markDefaulted_revertsBeforeGrace() public {
        uint256 id = _lock(seller, debtor, FACE);
        vm.prank(servicer);
        vm.expectRevert(InvoiceShelf.NotPastGrace.selector);
        shelf.markDefaulted(id);
    }

    // ── I1: the aggregate exposure cap across debtors ──

    function test_exposureCap_aggregatesAcrossDebtors() public {
        // 3 × 425 to distinct debtors = 1,275 ≤ 1,500; the 4th (1,700 total) breaches L0
        uint256 d2 = _newWorkspace("debtor2", makeAddr("d2"), 74, 87);
        uint256 d3 = _newWorkspace("debtor3", makeAddr("d3"), 74, 87);
        uint256 d4 = _newWorkspace("debtor4", makeAddr("d4"), 74, 87);
        _lock(seller, debtor, FACE);
        _lock(seller, d2, FACE);
        _lock(seller, d3, FACE);
        assertEq(shelf.outstandingOf(seller), 3 * uint256(ADVANCE));

        vm.prank(servicer);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceShelf.ExposureCapExceeded.selector, seller, ADVANCE, Params.L0_USDC - 3 * uint256(ADVANCE)
            )
        );
        shelf.lockInvoice(seller, d4, FACE, 2, uint64(block.timestamp + 30 days), 30 days, _docs());
    }

    // ── I3: solvency — shelf USDC covers tranche liquidity + collected holdbacks ──

    function test_solvency_afterMixedLifecycles() public {
        uint256 d2 = _newWorkspace("debtor2b", makeAddr("d2b"), 74, 87);
        uint256 id1 = _lock(seller, debtor, FACE);
        uint256 id2 = _lock(seller, d2, FACE);

        vm.prank(servicer);
        shelf.applyPayment(id1, 250e6);
        vm.prank(servicer);
        shelf.applyPayment(id2, 250e6);
        vm.prank(servicer);
        shelf.applyPayment(id1, 250e6); // id1 settles (holdback out)

        vm.warp(block.timestamp + 60 days + Params.GRACE_STRONG + 1);
        vm.prank(servicer);
        shelf.markDefaulted(id2);

        // I3 solvency: real USDC held == fundable cash + outstanding-less... no — cash held
        // is liquid + collected holdback; deployed principal is out with sellers.
        assertEq(
            usdc.balanceOf(address(shelf)),
            shelf.totalLiquid() + shelf.totalHoldbackHeld(),
            "I3: balance == liquid + held holdback (no phantom cash)"
        );
        // pool identity: liquid + principal == Σ deposits − Σ loss
        uint256 netDeposits = 3_000_000e6 - (shelf.trancheLoss(0) + shelf.trancheLoss(1) + shelf.trancheLoss(2));
        assertEq(shelf.totalLiquid() + shelf.totalPrincipal(), netDeposits, "pool identity holds");
    }
}

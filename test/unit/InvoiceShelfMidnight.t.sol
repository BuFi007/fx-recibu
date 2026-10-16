// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BUFIIdentityRegistry} from "../../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../../src/identity/BUFIReputationRegistry.sol";
import {WorkspaceTierRegistry} from "../../src/credit/WorkspaceTierRegistry.sol";
import {InvoiceShelf} from "../../src/invoice/InvoiceShelf.sol";
import {BINV} from "../../src/invoice/BINV.sol";
import {ReceivableCommitment} from "../../src/libraries/ReceivableCommitment.sol";
import {FactoringEvidenceV1} from "../../src/libraries/FactoringEvidenceV1.sol";
import {MockUSDC} from "./InvoiceShelf.t.sol";

/// @notice Midnight path: registry-only shelf, bindAdvance, §11.B accounting, cross-chain buffer.
contract InvoiceShelfMidnightTest is Test {
    MockUSDC internal usdc;
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;
    InvoiceShelf internal shelf;

    address internal admin = makeAddr("safe");
    address internal issuer = makeAddr("issuer");
    address internal attestor = makeAddr("attestor");
    address internal servicer = makeAddr("servicer");
    address internal advancer = makeAddr("advanceRouter");
    address internal sellerOwner = makeAddr("sellerOwner");
    address internal account = makeAddr("creditAccount");
    bytes32 internal constant MARKET = keccak256("midnight-USDC/EURC-30d");

    uint256 internal seller;
    uint256 internal debtor;
    uint256 internal inv;

    function setUp() public {
        usdc = new MockUSDC();
        identity = new BUFIIdentityRegistry(admin);
        reputation = new BUFIReputationRegistry(admin, identity);
        tiers = new WorkspaceTierRegistry(identity, reputation);
        shelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin, true);
        vm.startPrank(admin);
        identity.grantRole(identity.ISSUER_ROLE(), issuer);
        reputation.grantRole(reputation.ATTESTOR_ROLE(), attestor);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(shelf));
        shelf.grantRole(shelf.SERVICER_ROLE(), servicer);
        shelf.grantRole(shelf.ADVANCE_ROLE(), advancer);
        vm.stopPrank();
        seller = _ws("seller", sellerOwner, 74, 74);
        debtor = _ws("debtor", makeAddr("debtorOwner"), 74, 87);
        inv = _lock();
    }

    function _ws(string memory tag, address owner_, uint8 s, uint8 d) internal returns (uint256 id) {
        vm.startPrank(issuer);
        id = identity.registerWorkspace(keccak256(bytes(tag)), owner_);
        identity.setKybStatus(id, true);
        vm.stopPrank();
        vm.prank(attestor);
        reputation.setScore(id, s, d, 1, bytes32("r"));
    }

    function _lock() internal returns (uint256 id) {
        uint64 first = uint64(block.timestamp + 30 days);
        bytes32 auth = keccak256("auth-1");
        vm.prank(servicer);
        id = shelf.lockInvoice(
            seller,
            debtor,
            500e6,
            2,
            first,
            30 days,
            ReceivableCommitment.Terms({
                canonicalInvoiceCommitmentHash: auth, issuedAt: uint64(block.timestamp), dueAt: first + 30 days
            }),
            FactoringEvidenceV1({
                featureRootHash: bytes32("f"), currentSnapshotHash: bytes32("c"), privateTermsHash: bytes32("p")
            }),
            BINV.DocBundle(bytes32("inv"), bytes32("assign"), bytes32("pay"), bytes32("svc"), bytes32("disp"))
        );
    }

    function _lateAfterFinal() internal view returns (uint256) {
        return shelf.dueDate(inv) + shelf.graceOf(inv) + shelf.crossChainBuffer();
    }

    function _bind(uint64 maturity) internal {
        vm.prank(advancer);
        shelf.bindAdvance(inv, account, MARKET, maturity, 400e6, 396e6, 11000, bytes32("score"));
    }

    // ── registry-only ──

    function test_tranchesOff_noCashMovesOnLock() public {
        assertTrue(shelf.MIDNIGHT_MODE());
        assertEq(address(shelf.tranches(0)), address(0));
        vm.expectRevert(InvoiceShelf.TranchesDisabled.selector);
        shelf.depositTranche(0, 1e6);
        assertEq(usdc.balanceOf(address(shelf)), 0);
        assertEq(usdc.balanceOf(sellerOwner), 0); // no advance paid by the shelf
        assertEq(uint8(shelf.invoiceStatus(inv)), uint8(InvoiceShelf.Status.Funded));
        assertEq(shelf.BINV_TOKEN().ownerOf(inv), sellerOwner);
    }

    function test_applyPayment_isRecordOnly() public {
        vm.prank(servicer);
        shelf.applyPayment(inv, 100e6); // servicer holds no tokens: would revert if it pulled
        assertEq(usdc.balanceOf(address(shelf)), 0);
        assertEq(shelf.totalLiquid(), 0);
    }

    // ── cross-chain buffer ──

    function test_buffer_defaultSixHours_andSafeSettable() public {
        assertEq(shelf.crossChainBuffer(), 6 hours);
        vm.expectRevert();
        shelf.setCrossChainBuffer(1 hours); // non-admin
        vm.prank(admin);
        shelf.setCrossChainBuffer(12 hours);
        assertEq(shelf.crossChainBuffer(), 12 hours);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.BufferTooLarge.selector, uint32(3 days + 1)));
        shelf.setCrossChainBuffer(3 days + 1);
    }

    function test_buffer_notLateUntilDueGraceBuffer() public {
        uint256 lateAt = shelf.lateAfter(inv, shelf.installmentDue(inv, 0));
        assertEq(lateAt, shelf.installmentDue(inv, 0) + shelf.graceOf(inv) + 6 hours);
        vm.warp(lateAt);
        assertFalse(shelf.isLate(inv));
        vm.prank(servicer);
        vm.expectRevert(InvoiceShelf.NotPastGrace.selector);
        shelf.markDefaulted(inv);
        vm.warp(lateAt + 1);
        assertTrue(shelf.isLate(inv));
        vm.prank(servicer);
        shelf.markDefaulted(inv);
        assertEq(uint8(shelf.invoiceStatus(inv)), uint8(InvoiceShelf.Status.Defaulted));
        assertEq(usdc.balanceOf(address(shelf)), 0);
    }

    function test_buffer_paymentInsideBufferIsOnTime() public {
        uint256 lateAt = shelf.lateAfter(inv, shelf.installmentDue(inv, 0));
        vm.warp(lateAt); // past due + grace, inside the CCTP in-flight buffer
        vm.expectEmit(true, false, false, true, address(shelf));
        emit InvoiceShelf.InstallmentPaid(inv, 0, 100e6, true);
        vm.prank(servicer);
        shelf.applyPayment(inv, 100e6);
    }

    function test_buffer_maturityMustCoverDueGraceBuffer() public {
        uint256 need = _lateAfterFinal();
        vm.prank(advancer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.MaturityBeforeDue.selector, uint64(need - 1), need));
        shelf.bindAdvance(inv, account, MARKET, uint64(need - 1), 400e6, 396e6, 11000, bytes32("score"));
        _bind(uint64(need));
    }

    function test_buffer_raisingBufferTightensMaturity() public {
        vm.prank(admin);
        shelf.setCrossChainBuffer(2 days);
        uint64 old = uint64(shelf.dueDate(inv) + shelf.graceOf(inv) + 6 hours);
        vm.prank(advancer);
        vm.expectPartialRevert(InvoiceShelf.MaturityBeforeDue.selector);
        shelf.bindAdvance(inv, account, MARKET, old, 400e6, 396e6, 11000, bytes32("score"));
    }

    // ── Midnight accounting ──

    function test_bindAdvance_emitsOriginated_and_isOnePerInvoice() public {
        uint64 m = uint64(_lateAfterFinal());
        vm.expectEmit(true, true, true, true, address(shelf));
        emit InvoiceShelf.AdvanceOriginated(inv, account, MARKET, 400e6, 396e6, m, 11000, bytes32("score"));
        _bind(m);
        (address a, bytes32 id, uint64 mat, uint128 units, uint128 repaid) = shelf.advanceOf(inv);
        assertEq(a, account);
        assertEq(id, MARKET);
        assertEq(mat, m);
        assertEq(units, 400e6);
        assertEq(repaid, 0);
        vm.prank(advancer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.AdvanceAlreadyBound.selector, inv));
        shelf.bindAdvance(inv, account, MARKET, m, 1, 1, 11000, bytes32(0));
    }

    function test_bindAdvance_onlyAdvanceRole() public {
        uint64 m = uint64(_lateAfterFinal());
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        shelf.bindAdvance(inv, account, MARKET, m, 1, 1, 11000, bytes32(0));
    }

    function test_repaymentSettled_and_repaid_unitsBounded() public {
        _bind(uint64(_lateAfterFinal()));
        vm.expectEmit(true, true, true, true, address(shelf));
        emit InvoiceShelf.RepaymentSettled(inv, MARKET, bytes32("cctpMsg"), 1, 150e6, 150e6, bytes32("memo"));
        vm.prank(advancer);
        shelf.recordRepaymentSettled(inv, 150e6, 150e6, 1, bytes32("cctpMsg"), bytes32("memo"));
        vm.prank(advancer);
        shelf.recordAdvanceRepaid(inv, 200e6, bytes32("memo2"));
        vm.prank(advancer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.UnitsExceedOpen.selector, uint256(51e6), uint256(50e6)));
        shelf.recordAdvanceLiquidated(inv, 51e6, 0, address(0), 0);
        vm.prank(advancer);
        shelf.recordAdvanceLiquidated(inv, 50e6, 60e6, address(usdc), 0);
        (,,,, uint128 repaid) = shelf.advanceOf(inv);
        assertEq(repaid, 400e6);
    }

    function test_repaymentSettled_requiresMessageHash_andBinding() public {
        vm.prank(advancer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.AdvanceNotBound.selector, inv));
        shelf.recordAdvanceRepaid(inv, 1, bytes32(0));
        _bind(uint64(_lateAfterFinal()));
        vm.prank(advancer);
        vm.expectRevert(InvoiceShelf.BadAdvance.selector);
        shelf.recordRepaymentSettled(inv, 1, 1, 1, bytes32(0), bytes32(0));
    }

    function test_trancheShelfRejectsBindAdvance() public {
        InvoiceShelf legacy = new InvoiceShelf(usdc, identity, reputation, tiers, admin, false);
        assertEq(legacy.crossChainBuffer(), 6 hours);
        bytes32 role = legacy.ADVANCE_ROLE();
        vm.prank(admin);
        legacy.grantRole(role, advancer);
        vm.prank(advancer);
        vm.expectRevert(InvoiceShelf.MidnightOnly.selector);
        legacy.bindAdvance(1, account, MARKET, 1, 1, 1, 0, bytes32(0));
    }
}

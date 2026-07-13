// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BUFIIdentityRegistry} from "../../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../../src/identity/BUFIReputationRegistry.sol";
import {WorkspaceTierRegistry} from "../../src/credit/WorkspaceTierRegistry.sol";
import {InvoiceShelf} from "../../src/invoice/InvoiceShelf.sol";
import {BINV} from "../../src/invoice/BINV.sol";
import {ReceivableEscrow} from "../../src/rails/ReceivableEscrow.sol";
import {RecibuMemoRouter} from "../../src/rails/RecibuMemoRouter.sol";
import {IInvoiceShelf} from "../../src/interfaces/IInvoiceShelf.sol";
import {MockUSDC3009} from "../mocks/MockUSDC3009.sol";
import {MockPlainToken} from "../mocks/MockPlainToken.sol";
import {ReceivableCommitment} from "../../src/libraries/ReceivableCommitment.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {StrictAuthorityFixture, StrictAuthorityInvoiceVerifier} from "../utils/StrictAuthorityInvoiceVerifier.sol";

/// @title RecibuMemoRouter unit tests — canonical-token gasless + legacy repayment.
/// @dev Alternate-token activation is fail-closed until a reviewed conversion registry can deliver
///      the shelf's canonical asset to its canonical escrow atomically.
contract RecibuMemoRouterTest is StrictAuthorityFixture {
    MockUSDC3009 internal usdc; // ERC-3009 (Circle-shaped)
    MockPlainToken internal alternate;

    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;
    InvoiceShelf internal shelf;
    StrictAuthorityInvoiceVerifier internal authorityVerifier;
    RecibuMemoRouter internal router;

    ReceivableEscrow internal escrowU;
    ReceivableEscrow internal alternateEscrow;

    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");
    address internal attestor = makeAddr("attestor");
    address internal servicer = makeAddr("servicer");
    address internal relayer = makeAddr("relayer");
    address internal arbiter = makeAddr("arbiter");
    address internal payer;
    uint256 internal payerKey;

    uint256 internal seller;
    uint256 internal debtor;
    uint256 internal invId;

    uint128 internal constant FACE = 500e6;

    function setUp() public {
        (payer, payerKey) = makeAddrAndKey("payer");

        usdc = new MockUSDC3009();
        alternate = new MockPlainToken("Alternate", "ALT", 6);

        identity = new BUFIIdentityRegistry(admin);
        reputation = new BUFIReputationRegistry(admin, identity);
        tiers = new WorkspaceTierRegistry(identity, reputation);
        (shelf, authorityVerifier) = _deployStrictShelf(usdc, identity, reputation, tiers, admin);

        escrowU = new ReceivableEscrow(usdc, admin);
        alternateEscrow = new ReceivableEscrow(alternate, admin);
        vm.prank(admin);
        shelf.setEscrow(address(escrowU));
        router = new RecibuMemoRouter(IInvoiceShelf(address(shelf)), admin);

        vm.startPrank(admin);
        identity.grantRole(identity.ISSUER_ROLE(), issuer);
        reputation.grantRole(reputation.ATTESTOR_ROLE(), attestor);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(shelf));
        shelf.grantRole(shelf.SERVICER_ROLE(), servicer);
        // Test-only state-advance harness. Production grants this role only to
        // InvoiceSettlement, which sources canonical debtor-bound escrow cash.
        shelf.grantRole(shelf.SETTLEMENT_ROLE(), address(this));
        escrowU.grantRole(escrowU.ROUTER_ROLE(), address(router));
        escrowU.grantRole(escrowU.ARBITER_ROLE(), arbiter);
        router.grantRole(router.MEMO_RELAYER_ROLE(), relayer);
        router.setToken(address(usdc), true, router.CAP_3009(), escrowU);
        vm.stopPrank();

        seller = _ws("seller", makeAddr("sellerOwner"), 74, 74);
        debtor = _ws("debtor", payer, 74, 87);

        address lp = makeAddr("lp");
        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(shelf), type(uint256).max);
        shelf.depositTranche(2, 1_000_000e6);
        vm.stopPrank();

        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _newApprovedTerms(authorityVerifier, seller, debtor, address(usdc), FACE, 2, firstMaturity, 30 days);
        vm.prank(servicer);
        invId = shelf.lockInvoice(seller, debtor, FACE, 2, firstMaturity, 30 days, terms, _docs());

        usdc.mint(payer, 1_000_000e6);
        alternate.mint(payer, 1_000_000e6);
    }

    // ── ERC-3009: gasless, one signed action ─────────────────────────────────

    function test_payWithAuthorization_gaslessOneTx() public {
        uint256 amount = 250e6;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = router.memoAuthorizationNonceOf(address(usdc), payer, invId, 0, amount, 0, validBefore);
        (uint8 v, bytes32 r, bytes32 s) = _sign3009(payer, address(router), amount, 0, validBefore, nonce);

        // NO prior approve. A relayer submits; gas is paid by the relayer, not the payer.
        vm.expectEmit(true, true, true, true, address(router));
        emit RecibuMemoRouter.RecibuPayment(invId, 0, router.memoIdOf(invId, 0), address(usdc), amount, payer);
        vm.prank(relayer);
        router.payWithAuthorization(address(usdc), payer, invId, 0, amount, 0, validBefore, nonce, v, r, s);

        assertEq(escrowU.escrowedOf(invId), amount);
        assertEq(usdc.balanceOf(address(escrowU)), amount);
        assertEq(usdc.balanceOf(payer), 1_000_000e6 - amount);
        assertEq(usdc.allowance(payer, address(router)), 0); // never approved
        assertTrue(usdc.authorizationState(payer, nonce));
    }

    function test_payWithAuthorization_setsPolicyRefundLockAtomically() public {
        uint256 amount = 100e6;
        uint256 validBefore = block.timestamp + 1 hours;
        (,,, uint256 maturity, uint256 graceEndsAt) = shelf.currentInstallment(invId);
        uint64 unlockAt = uint64(block.timestamp + (graceEndsAt - maturity));
        bytes32 nonce = router.memoAuthorizationNonceOf(address(usdc), payer, invId, 0, amount, 0, validBefore);
        (uint8 v, bytes32 r, bytes32 s) = _sign3009(payer, address(router), amount, 0, validBefore, nonce);

        vm.prank(relayer);
        router.payWithAuthorization(address(usdc), payer, invId, 0, amount, 0, validBefore, nonce, v, r, s);

        assertEq(escrowU.refundUnlockAt(invId), unlockAt);
        assertEq(escrowU.escrowedOf(invId), amount);

        vm.warp(unlockAt - 1);
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(ReceivableEscrow.RefundLocked.selector, invId, unlockAt));
        escrowU.refund(invId, payer, amount);

        vm.warp(unlockAt);
        vm.prank(arbiter);
        escrowU.refund(invId, payer, amount);
        assertEq(escrowU.escrowedOf(invId), 0);
        assertEq(usdc.balanceOf(payer), 1_000_000e6);
    }

    function test_payWithAuthorization_replayReverts() public {
        uint256 amount = 100e6;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = router.memoAuthorizationNonceOf(address(usdc), payer, invId, 0, amount, 0, validBefore);
        (uint8 v, bytes32 r, bytes32 s) = _sign3009(payer, address(router), amount, 0, validBefore, nonce);
        vm.prank(relayer);
        router.payWithAuthorization(address(usdc), payer, invId, 0, amount, 0, validBefore, nonce, v, r, s);

        vm.prank(relayer);
        vm.expectRevert(MockUSDC3009.AuthUsed.selector);
        router.payWithAuthorization(address(usdc), payer, invId, 0, amount, 0, validBefore, nonce, v, r, s);
    }

    function test_payWithAuthorization_expiredReverts() public {
        uint256 amount = 100e6;
        uint256 validBefore = block.timestamp; // now >= validBefore → expired
        bytes32 nonce = router.memoAuthorizationNonceOf(address(usdc), payer, invId, 0, amount, 0, validBefore);
        (uint8 v, bytes32 r, bytes32 s) = _sign3009(payer, address(router), amount, 0, validBefore, nonce);
        vm.prank(relayer);
        vm.expectRevert(MockUSDC3009.AuthExpired.selector);
        router.payWithAuthorization(address(usdc), payer, invId, 0, amount, 0, validBefore, nonce, v, r, s);
    }

    function test_payWithAuthorization_capMissingReverts() public {
        // The canonical token is configured for ERC-3009, not ERC-2612.
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(RecibuMemoRouter.CapabilityMissing.selector, address(usdc), router.CAP_PERMIT())
        );
        router.payWithPermit(address(usdc), payer, invId, 0, 1e6, block.timestamp + 1 hours, 0, 0, 0);
    }

    function test_payWithAuthorization_futureAssertionDoesNotConsumeAuthorization() public {
        uint256 amount = 100e6;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = router.memoAuthorizationNonceOf(address(usdc), payer, invId, 0, amount, 0, validBefore);
        (uint8 v, bytes32 r, bytes32 s) = _sign3009(payer, address(router), amount, 0, validBefore, nonce);
        uint256 payerBalance = usdc.balanceOf(payer);

        vm.expectRevert(
            abi.encodeWithSelector(RecibuMemoRouter.InstallmentMismatch.selector, invId, uint8(1), uint8(0))
        );
        vm.prank(relayer);
        router.payWithAuthorization(address(usdc), payer, invId, 1, amount, 0, validBefore, nonce, v, r, s);

        assertFalse(usdc.authorizationState(payer, nonce));
        assertEq(usdc.balanceOf(payer), payerBalance);
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(escrowU.escrowedOf(invId), 0);

        vm.prank(relayer);
        router.payWithAuthorization(address(usdc), payer, invId, 0, amount, 0, validBefore, nonce, v, r, s);
        assertTrue(usdc.authorizationState(payer, nonce));
        assertEq(escrowU.escrowedOf(invId), amount);
    }

    function test_payWithAuthorization_staleAssertionDoesNotConsumeAuthorization() public {
        _applyShelfPayment(250e6);
        uint256 amount = 100e6;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = router.memoAuthorizationNonceOf(address(usdc), payer, invId, 1, amount, 0, validBefore);
        (uint8 v, bytes32 r, bytes32 s) = _sign3009(payer, address(router), amount, 0, validBefore, nonce);
        uint256 payerBalance = usdc.balanceOf(payer);

        vm.expectRevert(
            abi.encodeWithSelector(RecibuMemoRouter.InstallmentMismatch.selector, invId, uint8(0), uint8(1))
        );
        vm.prank(relayer);
        router.payWithAuthorization(address(usdc), payer, invId, 0, amount, 0, validBefore, nonce, v, r, s);

        assertFalse(usdc.authorizationState(payer, nonce));
        assertEq(usdc.balanceOf(payer), payerBalance);
        assertEq(escrowU.escrowedOf(invId), 0);

        vm.prank(relayer);
        router.payWithAuthorization(address(usdc), payer, invId, 1, amount, 0, validBefore, nonce, v, r, s);
        assertTrue(usdc.authorizationState(payer, nonce));
        assertEq(escrowU.escrowedOf(invId), amount);
    }

    function test_payWithAuthorization_untrustedRelayerCannotConsumeAuthorization() public {
        uint256 amount = 100e6;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = router.memoAuthorizationNonceOf(address(usdc), payer, invId, 0, amount, 0, validBefore);
        (uint8 v, bytes32 r, bytes32 s) = _sign3009(payer, address(router), amount, 0, validBefore, nonce);
        address stranger = makeAddr("untrustedRelayer");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, router.MEMO_RELAYER_ROLE()
            )
        );
        vm.prank(stranger);
        router.payWithAuthorization(address(usdc), payer, invId, 0, amount, 0, validBefore, nonce, v, r, s);

        assertFalse(usdc.authorizationState(payer, nonce));
        assertEq(escrowU.escrowedOf(invId), 0);

        vm.prank(relayer);
        router.payWithAuthorization(address(usdc), payer, invId, 0, amount, 0, validBefore, nonce, v, r, s);
        assertTrue(usdc.authorizationState(payer, nonce));
    }

    function test_payWithAuthorization_invoiceSubstitutionCannotConsumeAuthorization() public {
        uint256 secondDebtor = _ws("secondDebtor", payer, 74, 87);
        uint256 secondInvoice = _lockInvoice(FACE, secondDebtor);
        uint256 amount = 100e6;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = router.memoAuthorizationNonceOf(address(usdc), payer, invId, 0, amount, 0, validBefore);
        bytes32 substitutedNonce =
            router.memoAuthorizationNonceOf(address(usdc), payer, secondInvoice, 0, amount, 0, validBefore);
        (uint8 v, bytes32 r, bytes32 s) = _sign3009(payer, address(router), amount, 0, validBefore, nonce);

        vm.expectRevert(
            abi.encodeWithSelector(RecibuMemoRouter.MemoAuthorizationNonceMismatch.selector, nonce, substitutedNonce)
        );
        vm.prank(relayer);
        router.payWithAuthorization(address(usdc), payer, secondInvoice, 0, amount, 0, validBefore, nonce, v, r, s);

        assertFalse(usdc.authorizationState(payer, nonce));
        assertEq(escrowU.escrowedOf(secondInvoice), 0);

        vm.prank(relayer);
        router.payWithAuthorization(address(usdc), payer, invId, 0, amount, 0, validBefore, nonce, v, r, s);
        assertTrue(usdc.authorizationState(payer, nonce));
        assertEq(escrowU.escrowedOf(invId), amount);
    }

    function test_payWithAuthorization_rejectsSignerThatIsNotDebtorOwner() public {
        address attacker = makeAddr("authorizationAttacker");
        uint256 amount = 100e6;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = router.memoAuthorizationNonceOf(address(usdc), attacker, invId, 0, amount, 0, validBefore);

        vm.expectRevert(abi.encodeWithSelector(RecibuMemoRouter.UnauthorizedPayer.selector, invId, attacker, payer));
        vm.prank(relayer);
        router.payWithAuthorization(address(usdc), attacker, invId, 0, amount, 0, validBefore, nonce, 0, 0, 0);

        assertFalse(usdc.authorizationState(attacker, nonce));
        assertEq(escrowU.escrowedOf(invId), 0);
    }

    function test_payWithPermit_requiresOwnerCaller() public {
        uint8 caps = router.CAP_3009() | router.CAP_PERMIT();
        vm.prank(admin);
        router.setToken(address(usdc), true, caps, escrowU);

        vm.expectRevert(abi.encodeWithSelector(RecibuMemoRouter.PermitCallerMustBeOwner.selector, relayer, payer));
        vm.prank(relayer);
        router.payWithPermit(address(usdc), payer, invId, 0, 100e6, block.timestamp + 1 hours, 0, 0, 0);

        assertEq(escrowU.escrowedOf(invId), 0);
    }

    function test_payWithPermit_invalidSignatureRevertsDespiteStandingAllowance() public {
        uint8 caps = router.CAP_3009() | router.CAP_PERMIT();
        vm.prank(admin);
        router.setToken(address(usdc), true, caps, escrowU);
        vm.prank(payer);
        usdc.approve(address(router), type(uint256).max);
        uint256 payerBalance = usdc.balanceOf(payer);

        vm.expectRevert();
        vm.prank(payer);
        router.payWithPermit(address(usdc), payer, invId, 0, 100e6, block.timestamp + 1 hours, 0, 0, 0);

        assertEq(usdc.balanceOf(payer), payerBalance);
        assertEq(usdc.allowance(payer, address(router)), type(uint256).max);
        assertEq(escrowU.escrowedOf(invId), 0);
    }

    // ── legacy fallback + guards ─────────────────────────────────────────────

    function test_pay_legacyApprove() public {
        uint256 amount = 250e6;
        vm.startPrank(payer);
        usdc.approve(address(router), amount);
        router.pay(address(usdc), invId, 0, amount);
        vm.stopPrank();
        assertEq(escrowU.escrowedOf(invId), amount);
    }

    function test_pay_legacyRejectsNonDebtorOwner() public {
        address attacker = makeAddr("legacyAttacker");
        usdc.mint(attacker, 100e6);
        vm.prank(attacker);
        usdc.approve(address(router), 100e6);

        vm.expectRevert(abi.encodeWithSelector(RecibuMemoRouter.UnauthorizedPayer.selector, invId, attacker, payer));
        vm.prank(attacker);
        router.pay(address(usdc), invId, 0, 100e6);

        assertEq(usdc.balanceOf(attacker), 100e6);
        assertEq(escrowU.escrowedOf(invId), 0);
    }

    function test_pay_partialDepositsDoNotExtendCommittedRefundLock() public {
        vm.startPrank(payer);
        usdc.approve(address(router), 150e6);
        router.pay(address(usdc), invId, 0, 100e6);
        vm.stopPrank();
        uint64 firstLock = escrowU.refundUnlockAt(invId);

        vm.warp(block.timestamp + 1 days);
        vm.prank(payer);
        router.pay(address(usdc), invId, 0, 50e6);

        assertEq(escrowU.refundUnlockAt(invId), firstLock);
        assertEq(escrowU.escrowedOf(invId), 150e6);
    }

    function test_pay_rejectsAggregatePartialOverpaymentBeforeTransfer() public {
        vm.startPrank(payer);
        usdc.approve(address(router), type(uint256).max);
        router.pay(address(usdc), invId, 0, 200e6);
        vm.stopPrank();
        uint256 payerBalance = usdc.balanceOf(payer);
        uint256 allowance = usdc.allowance(payer, address(router));
        uint64 committedLock = escrowU.refundUnlockAt(invId);

        vm.expectRevert(
            abi.encodeWithSelector(
                RecibuMemoRouter.PaymentExceedsInstallmentRemaining.selector, invId, address(usdc), 51e6, 250e6, 200e6
            )
        );
        vm.prank(payer);
        router.pay(address(usdc), invId, 0, 51e6);

        assertEq(usdc.balanceOf(payer), payerBalance);
        assertEq(usdc.allowance(payer, address(router)), allowance);
        assertEq(escrowU.escrowedOf(invId), 200e6);
        assertEq(escrowU.refundUnlockAt(invId), committedLock);
    }

    function test_pay_legacyRejectsFutureAndStaleBeforeTransfer() public {
        uint256 amount = 100e6;
        vm.prank(payer);
        usdc.approve(address(router), type(uint256).max);
        uint256 payerBalance = usdc.balanceOf(payer);
        uint256 allowance = usdc.allowance(payer, address(router));

        vm.expectRevert(
            abi.encodeWithSelector(RecibuMemoRouter.InstallmentMismatch.selector, invId, uint8(1), uint8(0))
        );
        vm.prank(payer);
        router.pay(address(usdc), invId, 1, amount);
        assertEq(usdc.balanceOf(payer), payerBalance);
        assertEq(usdc.allowance(payer, address(router)), allowance);
        assertEq(escrowU.escrowedOf(invId), 0);

        _applyShelfPayment(250e6);

        vm.expectRevert(
            abi.encodeWithSelector(RecibuMemoRouter.InstallmentMismatch.selector, invId, uint8(0), uint8(1))
        );
        vm.prank(payer);
        router.pay(address(usdc), invId, 0, amount);
        assertEq(usdc.balanceOf(payer), payerBalance);
        assertEq(usdc.allowance(payer, address(router)), allowance);
        assertEq(escrowU.escrowedOf(invId), 0);

        vm.prank(payer);
        router.pay(address(usdc), invId, 1, amount);
        assertEq(escrowU.escrowedOf(invId), amount);
    }

    function test_pay_activePathsKeepSameAssertionCurrentAfterPartialShelfProgress() public {
        _applyShelfPayment(100e6);
        (uint8 index,, uint256 paidAmount,,) = shelf.currentInstallment(invId);
        assertEq(index, 0);
        assertEq(paidAmount, 100e6);

        vm.startPrank(payer);
        usdc.approve(address(router), 50e6);
        router.pay(address(usdc), invId, 0, 50e6);
        vm.stopPrank();
        assertEq(escrowU.escrowedOf(invId), 50e6);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = router.memoAuthorizationNonceOf(address(usdc), payer, invId, 0, 50e6, 0, deadline);
        (uint8 authV, bytes32 authR, bytes32 authS) = _sign3009(payer, address(router), 50e6, 0, deadline, nonce);
        vm.prank(relayer);
        router.payWithAuthorization(address(usdc), payer, invId, 0, 50e6, 0, deadline, nonce, authV, authR, authS);
        assertEq(escrowU.escrowedOf(invId), 100e6);
    }

    function test_pay_unregisteredTokenReverts() public {
        MockPlainToken rogue = new MockPlainToken("Rogue", "RGE", 6);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RecibuMemoRouter.TokenNotAllowed.selector, address(rogue)));
        router.pay(address(rogue), invId, 0, 1e6);
    }

    function test_pay_unfundedInvoiceReverts() public {
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RecibuMemoRouter.InvoiceNotFunded.selector, uint256(999)));
        router.pay(address(usdc), 999, 0, 1e6);
    }

    function test_pay_zeroAmountReverts() public {
        vm.prank(payer);
        vm.expectRevert(RecibuMemoRouter.ZeroAmount.selector);
        router.pay(address(usdc), invId, 0, 0);
    }

    function test_setToken_rejectsNonCanonicalSettlementToken() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                RecibuMemoRouter.NonCanonicalSettlementToken.selector, address(alternate), address(usdc)
            )
        );
        router.setToken(address(alternate), true, 0, alternateEscrow);
    }

    function test_setToken_rejectsCanonicalTokenWithWrongTokenEscrow() public {
        uint8 cap = router.CAP_3009();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(RecibuMemoRouter.EscrowTokenMismatch.selector, address(usdc), address(alternate))
        );
        router.setToken(address(usdc), true, cap, alternateEscrow);
    }

    function test_setToken_cannotReplacePinnedCanonicalEscrow() public {
        ReceivableEscrow replacement = new ReceivableEscrow(usdc, admin);
        uint8 cap = router.CAP_3009();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                RecibuMemoRouter.CanonicalEscrowMismatch.selector, address(replacement), address(escrowU)
            )
        );
        router.setToken(address(usdc), true, cap, replacement);
    }

    function test_memoIdParity() public view {
        assertEq(router.memoIdOf(invId, 3), keccak256(abi.encodePacked(invId, uint8(3))));
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _sign3009(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(
            abi.encode(usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), from, to, value, validAfter, validBefore, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(payerKey, digest);
    }

    function _applyShelfPayment(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(shelf), amount);
        shelf.applyPaymentFrom(invId, amount, address(this));
    }

    function _lockInvoice(uint128 face, uint256 debtorAgentId) internal returns (uint256 id) {
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _newApprovedTerms(authorityVerifier, seller, debtorAgentId, address(usdc), face, 2, firstMaturity, 30 days);
        vm.prank(servicer);
        id = shelf.lockInvoice(seller, debtorAgentId, face, 2, firstMaturity, 30 days, terms, _docs());
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
}

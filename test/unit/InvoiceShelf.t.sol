// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BUFIIdentityRegistry} from "../../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../../src/identity/BUFIReputationRegistry.sol";
import {WorkspaceTierRegistry} from "../../src/credit/WorkspaceTierRegistry.sol";
import {InvoiceShelf} from "../../src/invoice/InvoiceShelf.sol";
import {BINV} from "../../src/invoice/BINV.sol";
import {IAuthorityInvoiceVerifier} from "../../src/interfaces/IAuthorityInvoiceVerifier.sol";
import {IReceivableDomainView} from "../../src/interfaces/IReceivableDomainView.sol";
import {Params} from "../../src/libraries/Params.sol";
import {ReceivableCommitment} from "../../src/libraries/ReceivableCommitment.sol";
import {StrictAuthorityFixture, StrictAuthorityInvoiceVerifier} from "../utils/StrictAuthorityInvoiceVerifier.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AllowAllAuthorityVerifier is IAuthorityInvoiceVerifier {
    function verifierConfigId() external pure returns (bytes32) {
        return keccak256("BUFI_STRICT_AUTHORITY_FIXTURE_V1");
    }

    function supportedSchemaVersion() external pure returns (uint16) {
        return 1;
    }

    function approvedChainId() external view returns (uint256) {
        return block.chainid;
    }

    function approvedShelf() external pure returns (address) {
        return address(0);
    }

    function isVerified(
        ReceivableCommitment.AuthorityRef calldata,
        uint256,
        uint256,
        address,
        uint128,
        bool,
        uint8,
        uint64,
        uint32
    ) external pure returns (bool) {
        return true;
    }
}

contract RejectingERC721Receiver {}

contract FailingTransferUSDC is ERC20 {
    address public rejectedRecipient;
    bool public transfersRejected;

    constructor() ERC20("Failing USD Coin", "fUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function rejectTransfersTo(address recipient, bool rejected) external {
        rejectedRecipient = recipient;
        transfersRejected = rejected;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (transfersRejected && from != address(0) && to == rejectedRecipient) revert("TRANSFER_REJECTED");
        super._update(from, to, value);
    }
}

/// Numbers used throughout (respecting the SPEC §3.5 caps at cold start):
///   L0 = 1,500 USDC · per-debtor concentration = 30% of L(w) = 450 USDC
///   face 500 · debtor Excellent(87) no pair history → advance 85% = 425 (≤ 450 ✓)
///   holdback = 75 · junior-funded (no pair history → TrancheEligibility.JuniorC)
contract InvoiceShelfTest is StrictAuthorityFixture {
    event InstallmentPaymentApplied(
        uint256 indexed invoiceId,
        uint8 indexed index,
        uint256 amount,
        uint256 cumulativeProgress,
        uint256 installmentAmount
    );
    event InstallmentPaid(uint256 indexed invoiceId, uint8 index, uint256 amount, bool creditedOnTime);

    MockUSDC internal usdc;
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;
    InvoiceShelf internal shelf;
    StrictAuthorityInvoiceVerifier internal authorityVerifier;

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
        (shelf, authorityVerifier) = _deployStrictShelf(usdc, identity, reputation, tiers, admin);

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
        return _lockSchedule(sellerId, debtorId, face, 2);
    }

    function _lockSchedule(uint256 sellerId, uint256 debtorId, uint128 face, uint8 nInstallments)
        internal
        returns (uint256 id)
    {
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms = _newApprovedTerms(
            authorityVerifier, sellerId, debtorId, address(usdc), face, nInstallments, firstMaturity, 30 days
        );
        vm.prank(servicer);
        id = shelf.lockInvoice(sellerId, debtorId, face, nInstallments, firstMaturity, 30 days, terms, _docs());
    }

    function _approvedTerms(
        uint256 sellerId,
        uint256 debtorId,
        uint128 face,
        uint8 nInstallments,
        uint64 firstMaturity,
        uint32 interval
    ) internal returns (ReceivableCommitment.FundingTerms memory) {
        return _newApprovedTerms(
            authorityVerifier, sellerId, debtorId, address(usdc), face, nInstallments, firstMaturity, interval
        );
    }

    function _lockExplicit(
        uint256 sellerId,
        uint256 debtorId,
        uint128 face,
        uint8 nInstallments,
        uint64 firstMaturity,
        uint32 interval,
        ReceivableCommitment.FundingTerms memory terms,
        BINV.DocBundle memory docs
    ) internal returns (uint256 invoiceId) {
        vm.prank(servicer);
        invoiceId = shelf.lockInvoice(sellerId, debtorId, face, nInstallments, firstMaturity, interval, terms, docs);
    }

    function _invoiceState(uint256 id)
        internal
        view
        returns (
            uint128 outstanding,
            uint128 holdbackCollected,
            uint8 nInstallments,
            uint8 paidInstallments,
            InvoiceShelf.Status status
        )
    {
        (,,,, outstanding,, holdbackCollected,,,, nInstallments, paidInstallments,, status) = shelf.invoices(id);
    }

    function _countEvents(Vm.Log[] memory entries, address emitter, bytes32 signature)
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == emitter && entries[i].topics.length > 0 && entries[i].topics[0] == signature) {
                ++count;
            }
        }
    }

    function _bookJuniorLoss() internal returns (uint256 id) {
        id = _lock(seller, debtor, FACE);
        vm.prank(servicer);
        shelf.applyPayment(id, 250e6);
        vm.warp(block.timestamp + 60 days + Params.GRACE_STRONG + 1);
        vm.prank(servicer);
        shelf.markDefaulted(id);
    }

    // ── LP entry / exit ──

    function test_depositTranche_revertsWhileAnyRecoveryClaimIsOpen() public {
        _bookJuniorLoss();
        address newLp = makeAddr("newLp");
        usdc.mint(newLp, 100e6);

        vm.startPrank(newLp);
        usdc.approve(address(shelf), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceShelf.PoolHasUnresolvedLoss.selector, uint256(175e6), uint256(175e6))
        );
        shelf.depositTranche(2, 100e6);
        vm.stopPrank();

        assertEq(shelf.tranches(2).balanceOf(newLp), 0);
        assertEq(shelf.trancheLoss(2), 175e6);
    }

    function test_redeemTranche_revertsWhileBookedLossExists() public {
        _bookJuniorLoss();
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.PoolNotIdle.selector, uint256(0), uint256(175e6)));
        shelf.redeemTranche(2, 1e18);
    }

    function test_fullCashRecoveryClearsClaimAndAllowsFreshParDeposit() public {
        uint256 id = _bookJuniorLoss();
        vm.prank(servicer);
        shelf.recoverDefault(id, 175e6);
        assertEq(shelf.trancheLoss(2), 0);
        assertEq(shelf.unrecoveredLossOf(id), 0);
        assertEq(shelf.sellerUnrecoveredLossOf(seller), 0);

        address freshLp = makeAddr("freshLp");
        usdc.mint(freshLp, 100e6);
        vm.startPrank(freshLp);
        usdc.approve(address(shelf), 100e6);
        uint256 freshShares = shelf.depositTranche(2, 100e6);
        vm.stopPrank();
        assertEq(freshShares, 100e18);
        assertEq(shelf.trancheAssets(2), 1_000_100e6);
    }

    function test_redeemTranche_revertsOnRoundingBoundsAndInsufficientBalance() public {
        vm.prank(lp);
        vm.expectRevert(InvoiceShelf.RedemptionRoundsToZero.selector);
        shelf.redeemTranche(2, 1);

        vm.prank(lp);
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceShelf.InsufficientTrancheShares.selector, 1_000_000e18 + 1, 1_000_000e18)
        );
        shelf.redeemTranche(2, 1_000_000e18 + 1);

        vm.startPrank(lp);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.InvalidTranche.selector, uint8(3)));
        shelf.depositTranche(3, 1);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.InvalidTranche.selector, uint8(3)));
        shelf.redeemTranche(3, 1);
        vm.stopPrank();
    }

    function test_redeemTranche_succeedsOnlyFromIdleCleanPool() public {
        uint256 shares = 100e18;
        uint256 lpBalanceBefore = usdc.balanceOf(lp);
        vm.prank(lp);
        uint256 assets = shelf.redeemTranche(2, shares);

        assertEq(assets, 100e6);
        assertEq(usdc.balanceOf(lp) - lpBalanceBefore, 100e6);
        assertEq(shelf.trancheDeposits(2), 999_900e6);
        assertEq(shelf.tranches(2).totalSupply(), 999_900e18);
    }

    function test_redeemTranche_revertsWhileAnyPrincipalIsDeployed() public {
        _lock(seller, debtor, FACE);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.PoolNotIdle.selector, uint256(ADVANCE), uint256(0)));
        shelf.redeemTranche(0, 1e18);
        assertEq(shelf.tranches(2).balanceOf(lp), 1_000_000e18);
    }

    function test_depositTranche_revertsInsteadOfBailingOutLiveWipedShares() public {
        (InvoiceShelf thinShelf, StrictAuthorityInvoiceVerifier thinVerifier) =
            _deployStrictShelf(usdc, identity, reputation, tiers, admin);
        vm.startPrank(admin);
        thinShelf.grantRole(thinShelf.SERVICER_ROLE(), servicer);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(thinShelf));
        vm.stopPrank();

        usdc.mint(lp, 1_000_425e6);
        vm.startPrank(lp);
        usdc.approve(address(thinShelf), type(uint256).max);
        thinShelf.depositTranche(0, 1_000_000e6);
        thinShelf.depositTranche(2, 425e6);
        vm.stopPrank();
        vm.prank(servicer);
        usdc.approve(address(thinShelf), type(uint256).max);

        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _newApprovedTerms(thinVerifier, seller, debtor, address(usdc), FACE, 2, firstMaturity, 30 days);
        vm.startPrank(servicer);
        uint256 invoiceId = thinShelf.lockInvoice(seller, debtor, FACE, 2, firstMaturity, 30 days, terms, _docs());
        vm.warp(block.timestamp + 30 days + Params.GRACE_STRONG + 1);
        thinShelf.markDefaulted(invoiceId);
        vm.stopPrank();

        assertEq(thinShelf.trancheAssets(2), 0);
        assertEq(thinShelf.tranches(2).totalSupply(), 425e18, "wiped shares remain live");
        address recapitalizer = makeAddr("recapitalizer");
        usdc.mint(recapitalizer, 100e6);
        vm.startPrank(recapitalizer);
        usdc.approve(address(thinShelf), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceShelf.PoolHasUnresolvedLoss.selector, uint256(425e6), uint256(425e6))
        );
        thinShelf.depositTranche(2, 100e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(recapitalizer), 100e6, "failed recap cannot transfer value to wiped LPs");
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
        assertEq(shelf.tranchePrincipal(2), ADVANCE);
        assertEq(shelf.trancheCapacity(2), 1_000_000e6 - ADVANCE);
        assertEq(shelf.totalLiquid(), 3_000_000e6 - ADVANCE);
        // NAV basis unchanged by lending (advance is a par receivable): junior still whole
        assertEq(shelf.trancheAssets(2), 1_000_000e6);
    }

    function test_juniorSelectedInvoiceCannotFundFromSeniorOnlyCapital() public {
        (InvoiceShelf seniorOnlyShelf, StrictAuthorityInvoiceVerifier verifier) =
            _deployStrictShelf(usdc, identity, reputation, tiers, admin);
        vm.startPrank(admin);
        seniorOnlyShelf.grantRole(seniorOnlyShelf.SERVICER_ROLE(), servicer);
        vm.stopPrank();

        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(seniorOnlyShelf), 1_000_000e6);
        seniorOnlyShelf.depositTranche(0, 1_000_000e6);
        vm.stopPrank();

        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _newApprovedTerms(verifier, seller, debtor, address(usdc), FACE, 2, firstMaturity, 30 days);
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.InsufficientTrancheLiquidity.selector, uint8(2)));
        seniorOnlyShelf.lockInvoice(seller, debtor, FACE, 2, firstMaturity, 30 days, terms, _docs());

        assertEq(seniorOnlyShelf.totalLiquid(), 1_000_000e6, "senior cash cannot leak into junior origination");
        assertEq(seniorOnlyShelf.tranchePrincipal(0), 0);
        assertEq(seniorOnlyShelf.tranchePrincipal(2), 0);
    }

    function test_recoverDefaultIsCashBackedCappedAndReversesLossSeniorFirst() public {
        // Earn real pair history so the next receivable is selected into Senior A.
        uint256 historyId = _lock(seller, debtor, FACE);
        vm.warp(shelf.installmentDue(historyId, 0));
        vm.prank(servicer);
        shelf.applyPayment(historyId, 250e6);
        vm.warp(shelf.installmentDue(historyId, 1));
        vm.prank(servicer);
        shelf.applyPayment(historyId, 250e6);
        assertTrue(tiers.hasPairHistory(seller, debtor));

        (InvoiceShelf recoveryShelf, StrictAuthorityInvoiceVerifier verifier) =
            _deployStrictShelf(usdc, identity, reputation, tiers, admin);
        vm.startPrank(admin);
        recoveryShelf.grantRole(recoveryShelf.SERVICER_ROLE(), servicer);
        vm.stopPrank();

        usdc.mint(lp, 1_200e6);
        vm.startPrank(lp);
        usdc.approve(address(recoveryShelf), 1_200e6);
        recoveryShelf.depositTranche(0, 1_000e6);
        recoveryShelf.depositTranche(1, 100e6);
        recoveryShelf.depositTranche(2, 100e6);
        vm.stopPrank();

        uint64 maturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _newApprovedTerms(verifier, seller, debtor, address(usdc), FACE, 2, maturity, 30 days);
        vm.prank(servicer);
        uint256 id = recoveryShelf.lockInvoice(seller, debtor, FACE, 2, maturity, 30 days, terms, _docs());
        assertEq(recoveryShelf.tranchePrincipal(0), 450e6, "pair-history advance selects Senior A");

        vm.warp(maturity + Params.GRACE_STRONG + 1);
        recoveryShelf.markDefaulted(id);
        assertEq(recoveryShelf.trancheLoss(0), 250e6);
        assertEq(recoveryShelf.trancheLoss(1), 100e6);
        assertEq(recoveryShelf.trancheLoss(2), 100e6);
        assertEq(recoveryShelf.unrecoveredLossOf(id), 450e6);

        address recoveryPayer = makeAddr("recoveryPayer");
        usdc.mint(recoveryPayer, 451e6);
        vm.startPrank(recoveryPayer);
        usdc.approve(address(recoveryShelf), type(uint256).max);
        recoveryShelf.recoverDefault(id, 300e6);
        assertEq(recoveryShelf.trancheLoss(0), 0, "senior loss reverses first");
        assertEq(recoveryShelf.trancheLoss(1), 50e6, "then mezzanine reverses");
        assertEq(recoveryShelf.trancheLoss(2), 100e6, "junior reverses last");

        vm.expectRevert(
            abi.encodeWithSelector(InvoiceShelf.RecoveryExceedsUnrecoveredLoss.selector, uint256(151e6), uint256(150e6))
        );
        recoveryShelf.recoverDefault(id, 151e6);
        assertEq(usdc.balanceOf(recoveryPayer), 151e6, "rejected over-recovery transfers no cash");

        recoveryShelf.recoverDefault(id, 150e6);
        vm.stopPrank();
        assertEq(recoveryShelf.unrecoveredLossOf(id), 0);
        assertEq(recoveryShelf.sellerUnrecoveredLossOf(seller), 0);
        assertEq(recoveryShelf.totalUnrecoveredLoss(), 0);
        assertEq(recoveryShelf.trancheLoss(0) + recoveryShelf.trancheLoss(1) + recoveryShelf.trancheLoss(2), 0);
    }

    function test_lockRejectsSelfDealingSellerAndDebtor() public {
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms = _approvedTerms(seller, seller, FACE, 2, firstMaturity, 30 days);
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.SelfDealingReceivable.selector, seller));
        shelf.lockInvoice(seller, seller, FACE, 2, firstMaturity, 30 days, terms, _docs());
    }

    function test_debtorPayerTracksCurrentWorkspaceOwner() public {
        uint256 id = _lock(seller, debtor, FACE);
        address original = identity.ownerOf(debtor);
        assertEq(shelf.debtorPayerOf(id), original);

        address rotated = makeAddr("rotatedDebtorOwner");
        vm.prank(issuer);
        identity.setWorkspaceOwner(debtor, rotated);
        assertEq(shelf.debtorPayerOf(id), rotated);

        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.UnknownInvoice.selector, uint256(999)));
        shelf.debtorPayerOf(999);
    }

    function test_anyoneCanMarkObjectiveDefaultAfterGrace() public {
        uint256 id = _lock(seller, debtor, FACE);
        vm.warp(shelf.installmentDue(id, 0) + Params.GRACE_STRONG + 1);
        vm.prank(makeAddr("keeper"));
        shelf.markDefaulted(id);
        (,,,, InvoiceShelf.Status status) = _invoiceState(id);
        assertEq(uint8(status), uint8(InvoiceShelf.Status.Defaulted));
        assertEq(shelf.tranchePrincipal(2), 0);
        assertEq(shelf.unrecoveredLossOf(id), ADVANCE);
    }

    function test_lock_gates() public {
        // exposure cap: face 2000 → advance 1700 > L0 1500
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory exposureTerms =
            _approvedTerms(seller, debtor, 2000e6, 2, firstMaturity, 30 days);
        vm.prank(servicer);
        vm.expectRevert();
        shelf.lockInvoice(seller, debtor, 2000e6, 2, firstMaturity, 30 days, exposureTerms, _docs());

        // concentration cap: second invoice to the SAME debtor breaches 450
        _lock(seller, debtor, FACE); // 425 outstanding to this debtor
        ReceivableCommitment.FundingTerms memory concentrationTerms =
            _approvedTerms(seller, debtor, 100e6, 2, firstMaturity, 30 days);
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.ConcentrationCapExceeded.selector, debtor));
        shelf.lockInvoice(seller, debtor, 100e6, 2, firstMaturity, 30 days, concentrationTerms, _docs());

        // unKYB'd counterparty
        vm.prank(issuer);
        identity.setKybStatus(debtor, false);
        ReceivableCommitment.FundingTerms memory eligibilityTerms =
            _approvedTerms(seller, debtor, 100e6, 2, firstMaturity, 30 days);
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.NotEligible.selector, debtor));
        shelf.lockInvoice(seller, debtor, 100e6, 2, firstMaturity, 30 days, eligibilityTerms, _docs());

        // unauthorized caller
        ReceivableCommitment.FundingTerms memory unauthorizedTerms =
            _approvedTerms(seller, debtor, 100e6, 2, firstMaturity, 30 days);
        vm.prank(lp);
        vm.expectRevert();
        shelf.lockInvoice(seller, debtor, 100e6, 2, firstMaturity, 30 days, unauthorizedTerms, _docs());
    }

    function test_fundingEvidenceStoresSeparatePermanentBindingsAndRejectsUnknown() public {
        bytes32 authorityInvoiceId = _nextAuthorityInvoiceId();
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms = _fundingTerms(authorityInvoiceId);
        _approveFunding(authorityVerifier, terms, seller, debtor, address(usdc), FACE, 2, firstMaturity, 30 days);
        uint256 invoiceId = _lockExplicit(seller, debtor, FACE, 2, firstMaturity, 30 days, terms, _docs());

        IReceivableDomainView.FundingEvidence memory evidence = shelf.fundingEvidence(invoiceId);
        assertEq(evidence.schemaVersion, ReceivableCommitment.VERSION);
        assertEq(evidence.verifierConfigId, TEST_VERIFIER_CONFIG_ID);
        assertEq(evidence.authorityInvoiceId, authorityInvoiceId);
        assertEq(evidence.authorityEvidenceCommitment, terms.authority.authorityEvidenceCommitment);
        assertEq(evidence.receivableCommitment, shelf.receivableCommitmentOf(invoiceId));
        assertEq(evidence.documentCommitment, shelf.documentCommitmentOf(invoiceId));
        assertTrue(evidence.consumed);
        assertEq(shelf.invoiceIdOfAuthorityInvoiceId(authorityInvoiceId), invoiceId);
        assertEq(shelf.invoiceIdOfReceivableCommitment(evidence.receivableCommitment), invoiceId);
        assertTrue(shelf.recourseOf(invoiceId));
        assertEq(shelf.advanceRateBpsOf(invoiceId), 8_500);

        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.UnknownFundingEvidence.selector, 999));
        shelf.fundingEvidence(999);
    }

    function test_rejectsUnsupportedAuthoritySchemaAndVerifierConfig() public {
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms = _fundingTerms(_nextAuthorityInvoiceId());

        terms.authority.schemaVersion = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceShelf.UnsupportedAuthoritySchema.selector, uint16(0), ReceivableCommitment.VERSION
            )
        );
        _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());

        terms = _fundingTerms(_nextAuthorityInvoiceId());
        terms.authority.schemaVersion = 2;
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceShelf.UnsupportedAuthoritySchema.selector, uint16(2), ReceivableCommitment.VERSION
            )
        );
        _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());

        terms = _fundingTerms(_nextAuthorityInvoiceId());
        terms.authority.verifierConfigId = bytes32(0);
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceShelf.VerifierConfigMismatch.selector, bytes32(0), TEST_VERIFIER_CONFIG_ID)
        );
        _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());

        terms = _fundingTerms(_nextAuthorityInvoiceId());
        bytes32 wrongConfig = keccak256("wrong verifier config");
        terms.authority.verifierConfigId = wrongConfig;
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceShelf.VerifierConfigMismatch.selector, wrongConfig, TEST_VERIFIER_CONFIG_ID)
        );
        _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());
    }

    function test_onlyFacturaEVoucherType19CanOriginateEvenWhenVerifierApproves() public {
        uint8[4] memory rejectedTypes = [uint8(0), uint8(20), uint8(21), uint8(42)];
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        for (uint256 i; i < rejectedTypes.length; ++i) {
            ReceivableCommitment.FundingTerms memory terms = _fundingTerms(_nextAuthorityInvoiceId());
            terms.authority.authorityVoucherType = rejectedTypes[i];
            _approveFunding(authorityVerifier, terms, seller, debtor, address(usdc), 100e6, 2, firstMaturity, 30 days);
            vm.expectRevert(
                abi.encodeWithSelector(InvoiceShelf.UnsupportedAuthorityVoucherType.selector, rejectedTypes[i])
            );
            _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());
        }
    }

    function test_eachRequiredDocumentHashFailsWithStableIndex() public {
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms = _fundingTerms(_nextAuthorityInvoiceId());
        _approveFunding(authorityVerifier, terms, seller, debtor, address(usdc), 100e6, 2, firstMaturity, 30 days);

        for (uint8 fieldIndex; fieldIndex < 5; ++fieldIndex) {
            BINV.DocBundle memory docs = _docs();
            if (fieldIndex == 0) docs.invoiceDocHash = bytes32(0);
            if (fieldIndex == 1) docs.assignmentHash = bytes32(0);
            if (fieldIndex == 2) docs.paymentInstructionHash = bytes32(0);
            if (fieldIndex == 3) docs.servicingPolicyHash = bytes32(0);
            if (fieldIndex == 4) docs.disputePolicyHash = bytes32(0);
            vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.MissingRequiredDocumentHash.selector, fieldIndex));
            _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, docs);
        }
        assertEq(shelf.invoiceIdOfAuthorityInvoiceId(terms.authority.authorityInvoiceId), 0);
    }

    function test_nonRecourseIsDisabledEvenForOtherwiseEligibleStrongPair() public {
        assertTrue(tiers.nonRecourseEligible(74, 87, true));
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms = _fundingTerms(_nextAuthorityInvoiceId());
        terms.recourse = false;
        _approveFunding(authorityVerifier, terms, seller, debtor, address(usdc), 100e6, 2, firstMaturity, 30 days);
        vm.expectRevert(InvoiceShelf.NonRecourseNotEnabled.selector);
        _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());
    }

    function test_invalidAndFutureAuthorityDatesFailBeforeVerification() public {
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms = _fundingTerms(_nextAuthorityInvoiceId());

        terms.authority.issuedAt = uint64(block.timestamp + 1);
        terms.authority.authorityPaymentDueAt = uint64(block.timestamp + 90 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceShelf.InvalidAuthorityDates.selector,
                terms.authority.issuedAt,
                terms.authority.authorityPaymentDueAt
            )
        );
        _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());

        terms = _fundingTerms(_nextAuthorityInvoiceId());
        terms.authority.authorityPaymentDueAt = terms.authority.issuedAt - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceShelf.InvalidAuthorityDates.selector,
                terms.authority.issuedAt,
                terms.authority.authorityPaymentDueAt
            )
        );
        _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());
    }

    function test_falseAndRevokedVerifierResultsFailWithoutConsumption() public {
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory falseTerms = _fundingTerms(_nextAuthorityInvoiceId());
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceShelf.AuthorityInvoiceNotVerified.selector, falseTerms.authority.authorityInvoiceId
            )
        );
        _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, falseTerms, _docs());
        assertEq(shelf.invoiceIdOfAuthorityInvoiceId(falseTerms.authority.authorityInvoiceId), 0);

        ReceivableCommitment.FundingTerms memory revokedTerms = _fundingTerms(_nextAuthorityInvoiceId());
        _approveFunding(
            authorityVerifier, revokedTerms, seller, debtor, address(usdc), 100e6, 2, firstMaturity, 30 days
        );
        authorityVerifier.setRevoked(revokedTerms.authority.authorityInvoiceId, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceShelf.AuthorityInvoiceNotVerified.selector, revokedTerms.authority.authorityInvoiceId
            )
        );
        _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, revokedTerms, _docs());
        assertEq(shelf.invoiceIdOfAuthorityInvoiceId(revokedTerms.authority.authorityInvoiceId), 0);
    }

    function test_lockRejectsPostConstructionVerifierConfigDrift() public {
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _approvedTerms(seller, debtor, 100e6, 2, firstMaturity, 30 days);
        bytes32 drifted = keccak256("drifted config");
        authorityVerifier.setVerifierConfigId(drifted);
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceShelf.VerifierConfigMismatch.selector, drifted, TEST_VERIFIER_CONFIG_ID)
        );
        _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());
        assertEq(shelf.nextInvoiceId(), 1);
    }

    function test_lockRejectsPostConstructionVerifierSchemaDrift() public {
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _approvedTerms(seller, debtor, 100e6, 2, firstMaturity, 30 days);
        authorityVerifier.setSupportedSchemaVersion(2);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceShelf.UnsupportedAuthoritySchema.selector, uint16(2), ReceivableCommitment.VERSION
            )
        );
        _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());
        assertEq(shelf.nextInvoiceId(), 1);
    }

    function test_lockRejectsPostConstructionVerifierShelfDrift() public {
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _approvedTerms(seller, debtor, 100e6, 2, firstMaturity, 30 days);
        address drifted = makeAddr("driftedShelf");
        authorityVerifier.setApprovedShelf(drifted);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.VerifierShelfMismatch.selector, drifted, address(shelf)));
        _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());
        assertEq(shelf.nextInvoiceId(), 1);
    }

    function test_lockRejectsPostConstructionVerifierChainDrift() public {
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _approvedTerms(seller, debtor, 100e6, 2, firstMaturity, 30 days);
        uint256 drifted = block.chainid + 1;
        authorityVerifier.setApprovedChainId(drifted);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.WrongVerifierChain.selector, drifted, block.chainid));
        _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());
        assertEq(shelf.nextInvoiceId(), 1);
    }

    function test_lockRejectsCurrentChainIdDrift() public {
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _approvedTerms(seller, debtor, 100e6, 2, firstMaturity, 30 days);
        uint256 pinnedChainId = shelf.AUTHORITY_VERIFIER_CHAIN_ID();
        uint256 driftedChainId = pinnedChainId + 1;
        uint256 liquidBefore = shelf.totalLiquid();
        uint256 sellerBalanceBefore = usdc.balanceOf(sellerOwner);

        vm.chainId(driftedChainId);
        vm.prank(servicer);
        vm.record();
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.WrongVerifierChain.selector, driftedChainId, pinnedChainId));
        shelf.lockInvoice(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());

        (bytes32[] memory verifierReads, bytes32[] memory verifierWrites) = vm.accesses(address(authorityVerifier));
        assertEq(verifierReads.length, 0, "current-chain drift reached verifier storage");
        assertEq(verifierWrites.length, 0, "current-chain drift wrote verifier storage");
        assertEq(shelf.nextInvoiceId(), 1);
        assertEq(shelf.invoiceIdOfAuthorityInvoiceId(terms.authority.authorityInvoiceId), 0);
        assertEq(shelf.totalPrincipal(), 0);
        assertEq(shelf.totalLiquid(), liquidBefore);
        assertEq(usdc.balanceOf(sellerOwner), sellerBalanceBefore);
    }

    function test_lockRejectsPostConstructionVerifierRuntimeCodehashDrift() public {
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _approvedTerms(seller, debtor, 100e6, 2, firstMaturity, 30 days);
        vm.etch(address(authorityVerifier), hex"00");
        bytes32 receivedCodehash = address(authorityVerifier).codehash;
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceShelf.VerifierDeploymentMismatch.selector,
                address(authorityVerifier),
                receivedCodehash,
                shelf.AUTHORITY_VERIFIER_CODEHASH()
            )
        );
        _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());
        assertEq(shelf.nextInvoiceId(), 1);
    }

    function test_constructorRejectsSelfConsistentSchemaTwo() public {
        bytes32 verifierCodehash = keccak256(type(StrictAuthorityInvoiceVerifier).runtimeCode);
        (StrictAuthorityInvoiceVerifier verifier, bytes32 salt,) = _prepareStrictShelfFixture(
            usdc,
            identity,
            reputation,
            tiers,
            admin,
            2,
            TEST_VERIFIER_CONFIG_ID,
            block.chainid,
            2,
            TEST_VERIFIER_CONFIG_ID,
            block.chainid,
            verifierCodehash
        );
        assertEq(verifier.supportedSchemaVersion(), 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceShelf.UnsupportedAuthoritySchema.selector, uint16(2), ReceivableCommitment.VERSION
            )
        );
        new InvoiceShelf{salt: salt}(
            usdc,
            identity,
            reputation,
            tiers,
            verifier,
            2,
            TEST_VERIFIER_CONFIG_ID,
            block.chainid,
            verifierCodehash,
            admin
        );
    }

    function test_constructorRejectsSameCodeDifferentConfig() public {
        bytes32 verifierCodehash = keccak256(type(StrictAuthorityInvoiceVerifier).runtimeCode);
        bytes32 differentConfig = keccak256("same code different storage config");
        (StrictAuthorityInvoiceVerifier verifier, bytes32 salt,) = _prepareStrictShelfFixture(
            usdc,
            identity,
            reputation,
            tiers,
            admin,
            ReceivableCommitment.VERSION,
            differentConfig,
            block.chainid,
            ReceivableCommitment.VERSION,
            TEST_VERIFIER_CONFIG_ID,
            block.chainid,
            verifierCodehash
        );
        assertEq(address(verifier).codehash, verifierCodehash);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceShelf.VerifierConfigMismatch.selector, differentConfig, TEST_VERIFIER_CONFIG_ID
            )
        );
        new InvoiceShelf{salt: salt}(
            usdc,
            identity,
            reputation,
            tiers,
            verifier,
            ReceivableCommitment.VERSION,
            TEST_VERIFIER_CONFIG_ID,
            block.chainid,
            verifierCodehash,
            admin
        );
    }

    function test_constructorRejectsEoaWrongChainWrongCodehashAndAllowAllSubstitute() public {
        address eoa = makeAddr("authorityVerifierEoa");
        bytes32 strictCodehash = keccak256(type(StrictAuthorityInvoiceVerifier).runtimeCode);
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceShelf.VerifierDeploymentMismatch.selector, eoa, eoa.codehash, strictCodehash)
        );
        new InvoiceShelf(
            usdc,
            identity,
            reputation,
            tiers,
            IAuthorityInvoiceVerifier(eoa),
            ReceivableCommitment.VERSION,
            TEST_VERIFIER_CONFIG_ID,
            block.chainid,
            strictCodehash,
            admin
        );

        vm.expectRevert(
            abi.encodeWithSelector(InvoiceShelf.WrongVerifierChain.selector, block.chainid, block.chainid + 1)
        );
        new InvoiceShelf(
            usdc,
            identity,
            reputation,
            tiers,
            authorityVerifier,
            ReceivableCommitment.VERSION,
            TEST_VERIFIER_CONFIG_ID,
            block.chainid + 1,
            strictCodehash,
            admin
        );

        bytes32 wrongCodehash = keccak256("wrong runtime codehash");
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceShelf.VerifierDeploymentMismatch.selector,
                address(authorityVerifier),
                address(authorityVerifier).codehash,
                wrongCodehash
            )
        );
        new InvoiceShelf(
            usdc,
            identity,
            reputation,
            tiers,
            authorityVerifier,
            ReceivableCommitment.VERSION,
            TEST_VERIFIER_CONFIG_ID,
            block.chainid,
            wrongCodehash,
            admin
        );

        AllowAllAuthorityVerifier allowAll = new AllowAllAuthorityVerifier();
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceShelf.VerifierDeploymentMismatch.selector,
                address(allowAll),
                address(allowAll).codehash,
                strictCodehash
            )
        );
        new InvoiceShelf(
            usdc,
            identity,
            reputation,
            tiers,
            allowAll,
            ReceivableCommitment.VERSION,
            TEST_VERIFIER_CONFIG_ID,
            block.chainid,
            strictCodehash,
            admin
        );
    }

    function test_constructorRejectsVerifierBoundToSecondShelf() public {
        vm.expectRevert();
        new InvoiceShelf(
            usdc,
            identity,
            reputation,
            tiers,
            authorityVerifier,
            ReceivableCommitment.VERSION,
            TEST_VERIFIER_CONFIG_ID,
            block.chainid,
            address(authorityVerifier).codehash,
            admin
        );
    }

    function test_distinctAuthorityIdsFundDistinctReceivables() public {
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory first = _approvedTerms(seller, debtor, 20e6, 2, firstMaturity, 30 days);
        uint256 firstInvoice = _lockExplicit(seller, debtor, 20e6, 2, firstMaturity, 30 days, first, _docs());

        ReceivableCommitment.FundingTerms memory second =
            _approvedTerms(seller, debtor, 20e6, 2, firstMaturity, 30 days);
        uint256 secondInvoice = _lockExplicit(seller, debtor, 20e6, 2, firstMaturity, 30 days, second, _docs());

        assertNotEq(first.authority.authorityInvoiceId, second.authority.authorityInvoiceId);
        assertNotEq(firstInvoice, secondInvoice);
        assertNotEq(shelf.receivableCommitmentOf(firstInvoice), shelf.receivableCommitmentOf(secondInvoice));
    }

    function test_duplicateAuthorityRemainsConsumedAfterSettlementAndBinvBurn() public {
        bytes32 authorityInvoiceId = _nextAuthorityInvoiceId();
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms = _fundingTerms(authorityInvoiceId);
        _approveFunding(authorityVerifier, terms, seller, debtor, address(usdc), FACE, 2, firstMaturity, 30 days);
        uint256 invoiceId = _lockExplicit(seller, debtor, FACE, 2, firstMaturity, 30 days, terms, _docs());
        bytes32 receivableCommitment = shelf.receivableCommitmentOf(invoiceId);
        bytes32 documentCommitment = shelf.documentCommitmentOf(invoiceId);

        vm.prank(servicer);
        shelf.applyPayment(invoiceId, FACE);
        assertEq(uint8(shelf.invoiceStatus(invoiceId)), uint8(InvoiceShelf.Status.Settled));
        BINV binv = shelf.BINV_TOKEN();
        vm.expectRevert();
        binv.ownerOf(invoiceId);

        assertEq(shelf.invoiceIdOfAuthorityInvoiceId(authorityInvoiceId), invoiceId);
        assertEq(shelf.authorityInvoiceIdOf(invoiceId), authorityInvoiceId);
        assertEq(shelf.receivableCommitmentOf(invoiceId), receivableCommitment);
        assertEq(shelf.documentCommitmentOf(invoiceId), documentCommitment);

        ReceivableCommitment.FundingTerms memory changedTerms = terms;
        changedTerms.authority.authorityEvidenceCommitment = keccak256("post-settlement changed evidence");
        changedTerms.authority.authorityPaymentDueAt += 1 days;
        _approveFunding(authorityVerifier, changedTerms, seller, debtor, address(usdc), FACE, 2, firstMaturity, 30 days);
        BINV.DocBundle memory changedDocs = _docs();
        changedDocs.invoiceDocHash = keccak256("post-settlement changed PDF");
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceShelf.AuthorityInvoiceAlreadyConsumed.selector, authorityInvoiceId, invoiceId)
        );
        _lockExplicit(seller, debtor, FACE, 2, firstMaturity, 30 days, changedTerms, changedDocs);
    }

    function test_duplicateAuthorityRemainsConsumedAfterDefaultAndBinvBurn() public {
        bytes32 authorityInvoiceId = _nextAuthorityInvoiceId();
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms = _fundingTerms(authorityInvoiceId);
        _approveFunding(authorityVerifier, terms, seller, debtor, address(usdc), 100e6, 2, firstMaturity, 30 days);
        uint256 invoiceId = _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());
        bytes32 receivableCommitment = shelf.receivableCommitmentOf(invoiceId);
        bytes32 documentCommitment = shelf.documentCommitmentOf(invoiceId);

        vm.warp(firstMaturity + Params.GRACE_STRONG + 1);
        vm.prank(servicer);
        shelf.markDefaulted(invoiceId);
        assertEq(uint8(shelf.invoiceStatus(invoiceId)), uint8(InvoiceShelf.Status.Defaulted));
        BINV binv = shelf.BINV_TOKEN();
        vm.expectRevert();
        binv.ownerOf(invoiceId);
        assertEq(shelf.invoiceIdOfAuthorityInvoiceId(authorityInvoiceId), invoiceId);
        assertEq(shelf.authorityInvoiceIdOf(invoiceId), authorityInvoiceId);
        assertEq(shelf.receivableCommitmentOf(invoiceId), receivableCommitment);
        assertEq(shelf.documentCommitmentOf(invoiceId), documentCommitment);

        ReceivableCommitment.FundingTerms memory changedTerms = terms;
        changedTerms.authority.authorityEvidenceCommitment = keccak256("post-default changed evidence");
        _approveFunding(
            authorityVerifier, changedTerms, seller, debtor, address(usdc), 100e6, 2, firstMaturity, 30 days
        );
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceShelf.AuthorityInvoiceAlreadyConsumed.selector, authorityInvoiceId, invoiceId)
        );
        _lockExplicit(seller, debtor, 100e6, 2, firstMaturity, 30 days, changedTerms, _docs());
    }

    function test_safeMintFailureRollsBackAuthorityConsumptionAndAccounting() public {
        RejectingERC721Receiver rejectingOwner = new RejectingERC721Receiver();
        uint256 rejectingSeller = _newWorkspace("rejectingSeller", address(rejectingOwner), 74, 74);
        bytes32 authorityInvoiceId = _nextAuthorityInvoiceId();
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms = _fundingTerms(authorityInvoiceId);
        _approveFunding(
            authorityVerifier, terms, rejectingSeller, debtor, address(usdc), 100e6, 2, firstMaturity, 30 days
        );
        uint256 liquidBefore = shelf.totalLiquid();

        vm.expectRevert();
        _lockExplicit(rejectingSeller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());

        assertEq(shelf.nextInvoiceId(), 1);
        assertEq(shelf.invoiceIdOfAuthorityInvoiceId(authorityInvoiceId), 0);
        assertEq(shelf.totalPrincipal(), 0);
        assertEq(shelf.totalLiquid(), liquidBefore);
        assertEq(shelf.outstandingOf(rejectingSeller), 0);
    }

    function test_transferFailureRollsBackMintConsumptionAndAccounting() public {
        FailingTransferUSDC failingUsdc = new FailingTransferUSDC();
        (InvoiceShelf failingShelf, StrictAuthorityInvoiceVerifier failingVerifier) =
            _deployStrictShelf(failingUsdc, identity, reputation, tiers, admin);
        vm.startPrank(admin);
        failingShelf.grantRole(failingShelf.SERVICER_ROLE(), servicer);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(failingShelf));
        vm.stopPrank();

        failingUsdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        failingUsdc.approve(address(failingShelf), type(uint256).max);
        failingShelf.depositTranche(2, 1_000_000e6);
        vm.stopPrank();

        bytes32 authorityInvoiceId = _nextAuthorityInvoiceId();
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms = _fundingTerms(authorityInvoiceId);
        failingVerifier.setApproval(
            terms.authority, seller, debtor, address(failingUsdc), 100e6, true, 2, firstMaturity, 30 days, true
        );
        failingUsdc.rejectTransfersTo(sellerOwner, true);

        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "TRANSFER_REJECTED"));
        failingShelf.lockInvoice(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());

        assertEq(failingShelf.nextInvoiceId(), 1);
        assertEq(failingShelf.invoiceIdOfAuthorityInvoiceId(authorityInvoiceId), 0);
        assertEq(failingShelf.totalPrincipal(), 0);
        assertEq(failingShelf.totalLiquid(), 1_000_000e6);
        BINV failingBinv = failingShelf.BINV_TOKEN();
        vm.expectRevert();
        failingBinv.ownerOf(1);
    }

    // ── the happy loop: pay on time → L(w) grows → settle releases collected holdback ──

    function test_fullLifecycle_onTime() public {
        uint256 id = _lock(seller, debtor, FACE);
        uint256 limitBefore = tiers.limitOf(seller);

        // installment 1 (face/2 = 250, all to outstanding): on time
        vm.warp(shelf.installmentDue(id, 0));
        vm.prank(servicer);
        shelf.applyPayment(id, 250e6);
        assertEq(tiers.limitOf(seller), limitBefore + Params.RAMP_STEP_USDC);
        assertFalse(tiers.hasPairHistory(seller, debtor), "an open invoice is not pair history");
        (,,, uint8 firstPaid,) = _invoiceState(id);
        assertEq(firstPaid, 1);
        assertEq(shelf.installmentProgress(id), 0);

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
        (,, uint8 nInstallments, uint8 paidInstallments, InvoiceShelf.Status status) = _invoiceState(id);
        assertEq(paidInstallments, nInstallments, "all installments complete");
        assertEq(uint8(status), uint8(InvoiceShelf.Status.Settled));
        assertEq(shelf.installmentProgress(id), 0, "no settlement dust");
        assertEq(reputation.paidOnTimeCumulative(seller), 2, "one reputation step per installment");
        assertEq(reputation.pairSettledCount(seller, debtor), 1, "one pair record per settled invoice");
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

    function test_futurePrepaymentSettlesCashButDoesNotFarmReputation() public {
        uint256 id = _lock(seller, debtor, FACE);
        uint256 limitBefore = tiers.limitOf(seller);

        vm.expectEmit(true, false, false, true, address(shelf));
        emit InstallmentPaid(id, 0, 250e6, false);
        vm.prank(servicer);
        shelf.applyPayment(id, 250e6);

        (,,, uint8 paidInstallments,) = _invoiceState(id);
        assertEq(paidInstallments, 1, "cash still advances the installment cursor");
        assertEq(tiers.limitOf(seller), limitBefore);
        assertEq(reputation.paidOnTimeCumulative(seller), 0);
        assertEq(reputation.pairSettledCount(seller, debtor), 0);
    }

    function test_overpaymentBeyondFace_rejected() public {
        uint256 id = _lock(seller, debtor, FACE);
        vm.prank(servicer);
        shelf.applyPayment(id, 1);

        uint256 shelfBalanceBefore = usdc.balanceOf(address(shelf));
        uint256 payerBalanceBefore = usdc.balanceOf(servicer);
        uint256 principalBefore = shelf.totalPrincipal();
        uint256 liquidBefore = shelf.totalLiquid();
        uint256 exposureBefore = shelf.outstandingOf(seller);
        (uint128 outstandingBefore, uint128 collectedBefore,, uint8 paidBefore,) = _invoiceState(id);

        vm.prank(servicer);
        vm.expectRevert(InvoiceShelf.ZeroAmount.selector);
        shelf.applyPayment(id, FACE); // one unit more than the remaining face

        (uint128 outstandingAfter, uint128 collectedAfter,, uint8 paidAfter,) = _invoiceState(id);
        assertEq(usdc.balanceOf(address(shelf)), shelfBalanceBefore, "shelf transfer reverted atomically");
        assertEq(usdc.balanceOf(servicer), payerBalanceBefore, "payer transfer reverted atomically");
        assertEq(shelf.totalPrincipal(), principalBefore);
        assertEq(shelf.totalLiquid(), liquidBefore);
        assertEq(shelf.outstandingOf(seller), exposureBefore);
        assertEq(outstandingAfter, outstandingBefore);
        assertEq(collectedAfter, collectedBefore);
        assertEq(paidAfter, paidBefore);
        assertEq(shelf.installmentProgress(id), 1, "nonzero progress survives rejected overpayment");
    }

    function test_oneUnitPaymentDoesNotCreditInstallmentOrReputation() public {
        uint256 id = _lock(seller, debtor, FACE);
        uint256 limitBefore = tiers.limitOf(seller);

        vm.expectEmit(true, true, false, true, address(shelf));
        emit InstallmentPaymentApplied(id, 0, 1, 1, 250e6);
        vm.prank(servicer);
        shelf.applyPayment(id, 1);

        (uint128 outstanding,, uint8 nInstallments, uint8 paidInstallments,) = _invoiceState(id);
        assertEq(outstanding, ADVANCE - 1, "cash still reduces principal");
        assertEq(nInstallments, 2);
        assertEq(paidInstallments, 0, "dust cannot complete an installment");
        assertEq(shelf.installmentProgress(id), 1);
        assertEq(shelf.outstandingOf(seller), ADVANCE - 1);
        assertEq(shelf.totalPrincipal(), ADVANCE - 1);
        assertEq(tiers.limitOf(seller), limitBefore);
        assertEq(reputation.paidOnTimeCumulative(seller), 0);
        assertEq(reputation.pairSettledCount(seller, debtor), 0);
    }

    function test_partialFragmentsOneUnitShortDoNotCreditInstallment() public {
        uint256 id = _lock(seller, debtor, FACE);
        uint256 limitBefore = tiers.limitOf(seller);

        vm.prank(servicer);
        shelf.applyPayment(id, 100e6);
        vm.prank(servicer);
        shelf.applyPayment(id, 149_999_999);

        (,,, uint8 paidInstallments,) = _invoiceState(id);
        assertEq(paidInstallments, 0);
        assertEq(shelf.installmentProgress(id), 250e6 - 1);
        assertEq(tiers.limitOf(seller), limitBefore);
        assertEq(reputation.pairSettledCount(seller, debtor), 0);
    }

    function test_finalFragmentCreditsExactlyOnceAndResetsProgress() public {
        uint256 id = _lock(seller, debtor, FACE);
        uint256 limitBefore = tiers.limitOf(seller);
        vm.warp(shelf.installmentDue(id, 0));

        vm.prank(servicer);
        shelf.applyPayment(id, 250e6 - 1);
        vm.prank(servicer);
        shelf.applyPayment(id, 1);

        (,,, uint8 paidInstallments,) = _invoiceState(id);
        assertEq(paidInstallments, 1);
        assertEq(shelf.installmentProgress(id), 0);
        assertEq(tiers.limitOf(seller), limitBefore + Params.RAMP_STEP_USDC);
        assertEq(reputation.paidOnTimeCumulative(seller), 1);
        assertEq(reputation.pairSettledCount(seller, debtor), 0);
    }

    function test_paymentCompletesOneAndPartiallyFundsNext() public {
        uint256 id = _lock(seller, debtor, FACE);
        vm.warp(shelf.installmentDue(id, 0));

        vm.prank(servicer);
        shelf.applyPayment(id, 300e6);

        (uint128 outstanding,, uint8 nInstallments, uint8 paidInstallments,) = _invoiceState(id);
        assertEq(outstanding, ADVANCE - 300e6);
        assertEq(nInstallments, 2);
        assertEq(paidInstallments, 1);
        assertEq(shelf.installmentProgress(id), 50e6);
        assertEq(reputation.paidOnTimeCumulative(seller), 1);
        assertEq(reputation.pairSettledCount(seller, debtor), 0);
    }

    function test_paymentSpansSeveralInstallmentsWithoutOverCrediting() public {
        uint256 id = _lockSchedule(seller, debtor, 400e6, 4);
        uint256 limitBefore = tiers.limitOf(seller);
        vm.warp(shelf.installmentDue(id, 0));

        vm.recordLogs();
        vm.prank(servicer);
        shelf.applyPayment(id, 250e6);
        Vm.Log[] memory paymentLogs = vm.getRecordedLogs();

        (,, uint8 nInstallments, uint8 paidAfterFirstPayment,) = _invoiceState(id);
        assertEq(nInstallments, 4);
        assertEq(paidAfterFirstPayment, 2, "two complete slots only");
        assertEq(shelf.installmentProgress(id), 50e6, "remainder belongs to slot three");
        assertEq(tiers.limitOf(seller), limitBefore, "sub-threshold slots cannot raise the line");
        assertEq(
            _countEvents(paymentLogs, address(shelf), keccak256("InstallmentPaid(uint256,uint8,uint256,bool)")),
            2,
            "one completion event per completed slot"
        );
        assertEq(
            _countEvents(
                paymentLogs,
                address(shelf),
                keccak256("InstallmentPaymentApplied(uint256,uint8,uint256,uint256,uint256)")
            ),
            3,
            "cash is auditable across all three allocation fragments"
        );

        vm.prank(servicer);
        shelf.applyPayment(id, 150e6);

        uint8 paidAtSettlement;
        InvoiceShelf.Status status;
        (,, nInstallments, paidAtSettlement, status) = _invoiceState(id);
        assertEq(paidAtSettlement, nInstallments);
        assertEq(paidAtSettlement, 4, "count cannot exceed schedule");
        assertEq(shelf.installmentProgress(id), 0);
        assertEq(uint8(status), uint8(InvoiceShelf.Status.Settled));
        assertEq(reputation.paidOnTimeCumulative(seller), 0, "small/future slots cannot farm reputation");
        assertEq(reputation.pairSettledCount(seller, debtor), 1);
    }

    function test_microInvoiceCannotFarmRampOrPairHistory() public {
        uint256 id = _lockSchedule(seller, debtor, 12, 12);
        uint256 limitBefore = tiers.limitOf(seller);
        vm.warp(shelf.installmentDue(id, 0));

        vm.expectEmit(true, false, false, true, address(shelf));
        emit InstallmentPaid(id, 0, 1, false);
        vm.prank(servicer);
        shelf.applyPayment(id, 12);

        assertEq(uint8(shelf.invoiceStatus(id)), uint8(InvoiceShelf.Status.Settled));
        assertEq(reputation.paidOnTimeCumulative(seller), 0);
        assertEq(tiers.limitOf(seller), limitBefore);
        assertEq(reputation.pairSettledCount(seller, debtor), 0);
    }

    function test_nonDivisibleFaceAssignsRemainderToFinalInstallmentAndSettles() public {
        uint128 oddFace = FACE + 2;
        uint256 id = _lockSchedule(seller, debtor, oddFace, 3);
        uint256 firstAmount = shelf.installmentAmount(id, 0);
        uint256 secondAmount = shelf.installmentAmount(id, 1);
        uint256 finalAmount = shelf.installmentAmount(id, 2);

        assertEq(firstAmount, 166_666_667);
        assertEq(secondAmount, firstAmount);
        assertEq(finalAmount, firstAmount + 1);
        assertEq(firstAmount + secondAmount + finalAmount, oddFace);

        vm.prank(servicer);
        shelf.applyPayment(id, firstAmount);
        vm.prank(servicer);
        shelf.applyPayment(id, secondAmount);
        vm.prank(servicer);
        shelf.applyPayment(id, finalAmount);

        (,, uint8 nInstallments, uint8 paidInstallments, InvoiceShelf.Status status) = _invoiceState(id);
        assertEq(paidInstallments, nInstallments);
        assertEq(shelf.installmentProgress(id), 0);
        assertEq(uint8(status), uint8(InvoiceShelf.Status.Settled));
    }

    function test_faceSmallerThanInstallmentCountIsRejectedAtLock() public {
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms = _approvedTerms(seller, debtor, 2, 3, firstMaturity, 30 days);
        vm.prank(servicer);
        vm.expectRevert(InvoiceShelf.BadSchedule.selector);
        shelf.lockInvoice(seller, debtor, 2, 3, firstMaturity, 30 days, terms, _docs());
    }

    function test_installmentAmountRejectsUnknownInvoiceAndOutOfRangeIndex() public {
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.UnknownInvoice.selector, 999));
        shelf.installmentAmount(999, 0);

        uint256 id = _lock(seller, debtor, FACE);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.BadInstallmentIndex.selector, id, 2));
        shelf.installmentAmount(id, 2);
    }

    function test_currentInstallmentProjectsExistingScheduleAndProgress() public {
        uint256 id = _lock(seller, debtor, FACE);
        uint256 firstMaturity = shelf.installmentDue(id, 0);

        (uint8 index, uint256 fullAmount, uint256 paidAmount, uint256 maturity, uint256 graceEndsAt) =
            shelf.currentInstallment(id);
        assertEq(index, 0);
        assertEq(fullAmount, 250e6);
        assertEq(paidAmount, 0);
        assertEq(maturity, firstMaturity);
        assertEq(graceEndsAt, firstMaturity + Params.GRACE_STRONG);

        vm.prank(servicer);
        shelf.applyPayment(id, 100e6);

        (index, fullAmount, paidAmount, maturity, graceEndsAt) = shelf.currentInstallment(id);
        assertEq(index, 0, "partial cash cannot move the projection");
        assertEq(fullAmount, 250e6);
        assertEq(paidAmount, 100e6);
        assertEq(maturity, firstMaturity, "partial cash cannot move maturity");
        assertEq(graceEndsAt, firstMaturity + Params.GRACE_STRONG);

        vm.prank(servicer);
        shelf.applyPayment(id, 150e6);

        (index, fullAmount, paidAmount, maturity, graceEndsAt) = shelf.currentInstallment(id);
        assertEq(index, 1, "full completion advances exactly once");
        assertEq(fullAmount, 250e6);
        assertEq(paidAmount, 0);
        assertEq(maturity, firstMaturity + 30 days);
        assertEq(graceEndsAt, firstMaturity + 30 days + Params.GRACE_STRONG);
    }

    function test_currentInstallmentRejectsInvoicesWithoutOpenFundedInstallment() public {
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceShelf.NoCurrentInstallment.selector, 999, InvoiceShelf.Status.None)
        );
        shelf.currentInstallment(999);

        uint256 settledId = _lock(seller, debtor, FACE);
        vm.prank(servicer);
        shelf.applyPayment(settledId, FACE);
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceShelf.NoCurrentInstallment.selector, settledId, InvoiceShelf.Status.Settled)
        );
        shelf.currentInstallment(settledId);

        uint256 defaultedId = _lock(seller, debtor, FACE);
        vm.warp(shelf.installmentDue(defaultedId, 0) + Params.GRACE_STRONG + 1);
        vm.prank(servicer);
        shelf.markDefaulted(defaultedId);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceShelf.NoCurrentInstallment.selector, defaultedId, InvoiceShelf.Status.Defaulted
            )
        );
        shelf.currentInstallment(defaultedId);
    }

    function test_completingInstallmentAfterGraceDoesNotRaiseReputation() public {
        uint256 id = _lock(seller, debtor, FACE);
        uint256 limitBefore = tiers.limitOf(seller);

        vm.prank(servicer);
        shelf.applyPayment(id, 250e6 - 1);
        vm.warp(shelf.installmentDue(id, 0) + Params.GRACE_STRONG + 1);
        vm.prank(servicer);
        shelf.applyPayment(id, 1);

        (,,, uint8 paidInstallments,) = _invoiceState(id);
        assertEq(paidInstallments, 1, "late cash still completes the slot");
        assertEq(shelf.installmentProgress(id), 0);
        assertEq(tiers.limitOf(seller), limitBefore, "late slot earns no limit increase");
        assertEq(reputation.paidOnTimeCumulative(seller), 0);
        assertEq(reputation.pairSettledCount(seller, debtor), 0);
    }

    function test_partialFirstInstallmentKeepsFirstDefaultDeadline() public {
        uint256 id = _lock(seller, debtor, FACE);

        vm.prank(servicer);
        shelf.applyPayment(id, 1);
        vm.warp(shelf.installmentDue(id, 0) + Params.GRACE_STRONG + 1);
        vm.prank(servicer);
        shelf.markDefaulted(id);

        (,,, uint8 paidInstallments, InvoiceShelf.Status status) = _invoiceState(id);
        assertEq(paidInstallments, 0, "partial cash cannot move the maturity cursor");
        assertEq(shelf.installmentProgress(id), 1);
        assertEq(uint8(status), uint8(InvoiceShelf.Status.Defaulted));
    }

    function testFuzz_installmentCreditsOnlyAfterPositiveFragmentsReachThreshold(uint96 rawFirst, uint96 rawSecond)
        public
    {
        uint256 id = _lock(seller, debtor, FACE);
        uint256 fullAmount = shelf.installmentAmount(id, 0);
        uint256 first = bound(uint256(rawFirst), 1, fullAmount - 2);
        uint256 second = bound(uint256(rawSecond), 1, fullAmount - first - 1);
        uint256 finalFragment = fullAmount - first - second;
        uint256 limitBefore = tiers.limitOf(seller);
        vm.warp(shelf.installmentDue(id, 0));

        vm.prank(servicer);
        shelf.applyPayment(id, first);
        (,,, uint8 paidAfterFirst,) = _invoiceState(id);
        assertEq(paidAfterFirst, 0);
        assertEq(shelf.installmentProgress(id), first);
        assertEq(tiers.limitOf(seller), limitBefore);

        vm.prank(servicer);
        shelf.applyPayment(id, second);
        (,,, uint8 paidAfterSecond,) = _invoiceState(id);
        assertEq(paidAfterSecond, 0);
        assertEq(shelf.installmentProgress(id), first + second);
        assertEq(tiers.limitOf(seller), limitBefore);

        vm.prank(servicer);
        shelf.applyPayment(id, finalFragment);
        (,,, uint8 paidAfterFinal,) = _invoiceState(id);
        assertEq(paidAfterFinal, 1);
        assertEq(shelf.installmentProgress(id), 0);
        assertEq(tiers.limitOf(seller), limitBefore + Params.RAMP_STEP_USDC);
        assertEq(reputation.paidOnTimeCumulative(seller), 1);
        assertEq(reputation.pairSettledCount(seller, debtor), 0);
    }

    // ── default: full outstanding write-off + junior-first waterfall + one-way freeze ──

    function test_defaultWritesOffFullOutstandingAndAllocatesJuniorFirst() public {
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
        // Installments do not stage the advance: every remaining principal dollar is lost.
        assertEq(shelf.unrecoveredLossOf(id), ADVANCE - 250e6);
        // exposure cleared + one-way freeze
        assertEq(shelf.outstandingOf(seller), 0);
        assertTrue(shelf.workspaceFrozen(seller));
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _approvedTerms(seller, debtor, 100e6, 2, firstMaturity, 30 days);
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.Frozen.selector, seller));
        shelf.lockInvoice(seller, debtor, 100e6, 2, firstMaturity, 30 days, terms, _docs());
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

        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms = _approvedTerms(seller, d4, FACE, 2, firstMaturity, 30 days);
        vm.prank(servicer);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceShelf.ExposureCapExceeded.selector, seller, ADVANCE, Params.L0_USDC - 3 * uint256(ADVANCE)
            )
        );
        shelf.lockInvoice(seller, d4, FACE, 2, firstMaturity, 30 days, terms, _docs());
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

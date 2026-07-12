// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BUFIIdentityRegistry} from "../../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../../src/identity/BUFIReputationRegistry.sol";
import {WorkspaceTierRegistry} from "../../src/credit/WorkspaceTierRegistry.sol";
import {InvoiceShelf} from "../../src/invoice/InvoiceShelf.sol";
import {BUFIOracle} from "../../src/invoice/BUFIOracle.sol";
import {WorkspaceOperatingReserve} from "../../src/rails/WorkspaceOperatingReserve.sol";
import {BINV} from "../../src/invoice/BINV.sol";
import {Params} from "../../src/libraries/Params.sol";
import {ReceivableCommitment} from "../../src/libraries/ReceivableCommitment.sol";
import {StrictAuthorityFixture, StrictAuthorityInvoiceVerifier} from "../utils/StrictAuthorityInvoiceVerifier.sol";

contract MockUSDC2 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// M3b (NAV oracle + breaker) + M4 (reserve layer-2 + default resolution).
contract OracleAndReserveTest is StrictAuthorityFixture {
    MockUSDC2 internal usdc;
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;
    InvoiceShelf internal shelf;
    StrictAuthorityInvoiceVerifier internal authorityVerifier;
    WorkspaceOperatingReserve internal reserve;
    BUFIOracle internal oracleC;

    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");
    address internal attestor = makeAddr("attestor");
    address internal servicer = makeAddr("servicer");
    address internal ops = makeAddr("ops");
    address internal lp = makeAddr("lp");
    address internal sellerOwner = makeAddr("sellerOwner");

    uint256 internal seller;
    uint256 internal debtor;

    function setUp() public {
        usdc = new MockUSDC2();
        identity = new BUFIIdentityRegistry(admin);
        reputation = new BUFIReputationRegistry(admin, identity);
        tiers = new WorkspaceTierRegistry(identity, reputation);
        (shelf, authorityVerifier) = _deployStrictShelf(usdc, identity, reputation, tiers, admin);
        reserve = new WorkspaceOperatingReserve(usdc, admin);
        oracleC = new BUFIOracle(shelf, 2, admin);

        vm.startPrank(admin);
        identity.grantRole(identity.ISSUER_ROLE(), issuer);
        reputation.grantRole(reputation.ATTESTOR_ROLE(), attestor);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(shelf));
        reputation.grantRole(reputation.OPS_ROLE(), address(shelf)); // resolveDefault writes
        shelf.grantRole(shelf.SERVICER_ROLE(), servicer);
        shelf.grantRole(shelf.OPS_ROLE(), ops);
        shelf.setReserve(reserve);
        reserve.grantRole(reserve.SHELF_ROLE(), address(shelf));
        vm.stopPrank();

        seller = _newWorkspace("seller", sellerOwner, 74, 74); // Strong: no bond required
        debtor = _newWorkspace("debtor", makeAddr("dOwner"), 74, 87);

        usdc.mint(lp, 3_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(shelf), type(uint256).max);
        shelf.depositTranche(0, 1_000_000e6);
        shelf.depositTranche(1, 1_000_000e6);
        shelf.depositTranche(2, 200_000e6); // junior thin, for NAV visibility
        vm.stopPrank();

        usdc.mint(servicer, 1_000_000e6);
        vm.prank(servicer);
        usdc.approve(address(shelf), type(uint256).max);
        usdc.mint(sellerOwner, 10_000e6);
        vm.prank(sellerOwner);
        usdc.approve(address(reserve), type(uint256).max);

        vm.prank(admin);
        oracleC.observe();
    }

    function _newWorkspace(string memory tag, address owner_, uint8 s, uint8 d) internal returns (uint256 id) {
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

    function _lockDefaultable() internal returns (uint256 id) {
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _newApprovedTerms(authorityVerifier, seller, debtor, address(usdc), 500e6, 2, firstMaturity, 30 days);
        vm.prank(servicer);
        id = shelf.lockInvoice(seller, debtor, 500e6, 2, firstMaturity, 30 days, terms, _docs());
        vm.warp(firstMaturity);
        vm.prank(servicer);
        shelf.applyPayment(id, 250e6); // installment 1 on time; outstanding 175
        vm.warp(firstMaturity + 30 days + Params.GRACE_STRONG + 1); // miss installment 2
    }

    // ── M3b: NAV oracle (SPEC §6 worked examples, adapted to live numbers) ──

    function test_nav_parAtDeposit() public {
        // 200k assets / 200k shares → 1.00 USDC/share ≡ 1e24 (SPEC §6.3 scale)
        assertEq(oracleC.price(), 1e24);
    }

    function test_nav_juniorWritedownOnLoss_seniorUntouched() public {
        uint256 id = _lockDefaultable();
        vm.prank(servicer);
        shelf.markDefaulted(id); // loss 175 → junior (no reserve posted; Strong seller)

        // junior NAV = (200_000 − 175) / 200_000 = 0.999125 → 0.999125e24
        assertEq(oracleC.price(), (uint256(200_000e6 - 175e6) * 1e36) / 200_000e18);
        // senior stays par
        BUFIOracle oracleA = new BUFIOracle(shelf, 0, admin);
        vm.prank(admin);
        oracleA.observe();
        assertEq(oracleA.price(), 1e24);
    }

    function test_breaker_tripsOnBigMove_thenOpsClears() public {
        vm.prank(admin);
        oracleC.observe(); // refresh baseline at par

        // engineer a >10% junior NAV drop: withdraw-like big loss via default with big face
        // (velocity/caps sized fine: face 500 → loss 175 is ~0.09%; instead trip by
        //  simulating many defaults is slow — use a fresh thin tranche instead)
        // Simplest honest path: new shelf with tiny junior so one default is >10%.
        (InvoiceShelf shelf2, StrictAuthorityInvoiceVerifier verifier2) =
            _deployStrictShelf(usdc, identity, reputation, tiers, admin);
        vm.startPrank(admin);
        shelf2.grantRole(shelf2.SERVICER_ROLE(), servicer);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(shelf2));
        vm.stopPrank();
        vm.startPrank(lp);
        usdc.approve(address(shelf2), type(uint256).max);
        shelf2.depositTranche(2, 1000e6); // junior = 1,000
        vm.stopPrank();
        vm.prank(servicer);
        usdc.approve(address(shelf2), type(uint256).max);
        BUFIOracle o2 = new BUFIOracle(shelf2, 2, admin);
        vm.prank(admin);
        o2.observe();

        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _newApprovedTerms(verifier2, seller, debtor, address(usdc), 500e6, 2, firstMaturity, 30 days);
        vm.prank(servicer);
        uint256 id = shelf2.lockInvoice(seller, debtor, 500e6, 2, firstMaturity, 30 days, terms, _docs());
        vm.prank(servicer);
        shelf2.applyPayment(id, 250e6);
        vm.warp(block.timestamp + 60 days + Params.GRACE_STRONG + 1);
        vm.prank(servicer);
        shelf2.markDefaulted(id); // loss 175 / 1000 = 17.5% > 10%

        // A consumer must fail closed immediately; safety cannot depend on a keeper
        // persisting the trip before the next lending action reads the oracle.
        assertFalse(o2.tripped());
        vm.expectRevert(BUFIOracle.Paused.selector);
        o2.price();
        assertFalse(o2.tripped(), "view-time guard does not mutate breaker state");

        o2.observe();
        assertTrue(o2.tripped());
        vm.expectRevert(BUFIOracle.Paused.selector);
        o2.price();

        vm.prank(admin);
        o2.clear();
        assertFalse(o2.tripped());
        assertGt(o2.price(), 0);
    }

    function test_nav_revertsOnEmptyTranche() public {
        (InvoiceShelf shelf3,) = _deployStrictShelf(usdc, identity, reputation, tiers, admin);
        BUFIOracle o3 = new BUFIOracle(shelf3, 1, admin);
        vm.expectRevert(BUFIOracle.EmptyTranche.selector);
        vm.prank(admin);
        o3.observe();
    }

    // ── M4: bond gate + reserve as waterfall layer 2 ──

    function test_bondGate_developingSellerMustPost() public {
        address weakOwner = makeAddr("weakOwner");
        uint256 weakSeller = _newWorkspace("weak", weakOwner, 30, 30); // Developing seller
        // advance rate keys on the DEBTOR (87=Excellent 90%, −5% no-pair = 85%): 400×85% = 340
        // required floor = 340 × 25% reserve × 100% bond = 85
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _newApprovedTerms(authorityVerifier, weakSeller, debtor, address(usdc), 400e6, 2, firstMaturity, 30 days);
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.BondNotPosted.selector, 85e6, 0));
        shelf.lockInvoice(weakSeller, debtor, 400e6, 2, firstMaturity, 30 days, terms, _docs());

        // post the bond → lock succeeds
        usdc.mint(weakOwner, 100e6);
        vm.startPrank(weakOwner);
        usdc.approve(address(reserve), type(uint256).max);
        reserve.postBond(weakSeller, 85e6);
        vm.stopPrank();
        vm.prank(servicer);
        shelf.lockInvoice(weakSeller, debtor, 400e6, 2, firstMaturity, 30 days, terms, _docs());
        assertEq(reserve.requiredOf(weakSeller), 85e6);
    }

    function test_reserveBurnsBeforeJuniorLoss() public {
        // Strong seller posts a voluntary 100 reserve anyway
        vm.prank(sellerOwner);
        reserve.postBond(seller, 100e6);

        uint256 id = _lockDefaultable(); // outstanding 175 at default
        vm.prank(servicer);
        shelf.markDefaulted(id);

        // layer 2 consumed the SELLER's 100 first; junior only ate 75
        assertEq(reserve.balanceOf(seller), 0);
        assertEq(shelf.trancheLoss(2), 75e6);
        assertEq(shelf.trancheLoss(1), 0);
        assertEq(shelf.trancheLoss(0), 0);
    }

    function test_withdrawReserveSurplus_authenticatesAndPaysCurrentIdentityOwner() public {
        vm.prank(sellerOwner);
        reserve.postBond(seller, 100e6);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.NotWorkspaceOwner.selector, seller, stranger));
        shelf.withdrawReserveSurplus(seller, 1e6);

        address newOwner = makeAddr("newOwner");
        vm.prank(issuer);
        identity.setWorkspaceOwner(seller, newOwner);
        vm.prank(sellerOwner);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.NotWorkspaceOwner.selector, seller, sellerOwner));
        shelf.withdrawReserveSurplus(seller, 1e6);

        uint256 ownerBalanceBefore = usdc.balanceOf(newOwner);
        vm.prank(newOwner);
        shelf.withdrawReserveSurplus(seller, 40e6);
        assertEq(usdc.balanceOf(newOwner) - ownerBalanceBefore, 40e6);
        assertEq(reserve.balanceOf(seller), 60e6);
    }

    function test_withdrawReserveSurplus_blocksOutstandingExposure() public {
        vm.prank(sellerOwner);
        reserve.postBond(seller, 100e6);
        _lockDefaultable();

        vm.prank(sellerOwner);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.OutstandingExposure.selector, seller, 175e6));
        shelf.withdrawReserveSurplus(seller, 1e6);
    }

    function test_withdrawReserveSurplus_blocksRequiredFloorEvenWithoutExposure() public {
        vm.prank(sellerOwner);
        reserve.postBond(seller, 100e6);
        vm.prank(address(shelf));
        reserve.setRequired(seller, 50e6);

        vm.prank(sellerOwner);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.ReserveFloorActive.selector, seller, 50e6));
        shelf.withdrawReserveSurplus(seller, 1e6);
    }

    function test_withdrawReserveSurplus_blocksFrozenWorkspace() public {
        vm.prank(sellerOwner);
        reserve.postBond(seller, 100e6);
        uint256 id = _lockDefaultable();
        vm.prank(servicer);
        shelf.markDefaulted(id);

        vm.prank(sellerOwner);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.Frozen.selector, seller));
        shelf.withdrawReserveSurplus(seller, 1e6);
    }

    // ── M4: resolution — fraud terminal vs restructure lifts freeze ──

    function test_resolveDefault_fraudIsTerminal() public {
        uint256 id = _lockDefaultable();
        vm.prank(servicer);
        shelf.markDefaulted(id);

        assertEq(shelf.unresolvedDefaultCountOf(seller), 1);

        vm.prank(ops);
        shelf.resolveDefault(id, true);
        assertTrue(reputation.permanentDefault(seller));
        assertEq(tiers.limitOf(seller), 0);
        assertTrue(shelf.workspaceFrozen(seller)); // freeze permanent on fraud
        assertEq(shelf.unresolvedDefaultCountOf(seller), 0);
        assertEq(
            uint8(shelf.defaultResolutionOf(id)), uint8(InvoiceShelf.DefaultResolution.Fraud), "fraud recorded once"
        );
    }

    function test_paymentRemainsLiveAfterTerminalSellerDefaultAndSkipsReputation() public {
        uint256 payingDebtor = _newWorkspace("terminalPayingDebtor", makeAddr("terminalPayer"), 74, 87);
        uint64 defaultMaturity = uint64(block.timestamp + 30 days);
        uint64 payingMaturity = uint64(block.timestamp + 90 days);
        ReceivableCommitment.FundingTerms memory defaultTerms =
            _newApprovedTerms(authorityVerifier, seller, debtor, address(usdc), 500e6, 2, defaultMaturity, 30 days);
        ReceivableCommitment.FundingTerms memory payingTerms = _newApprovedTerms(
            authorityVerifier, seller, payingDebtor, address(usdc), 500e6, 2, payingMaturity, 30 days
        );

        vm.startPrank(servicer);
        uint256 defaultId = shelf.lockInvoice(seller, debtor, 500e6, 2, defaultMaturity, 30 days, defaultTerms, _docs());
        uint256 payingId =
            shelf.lockInvoice(seller, payingDebtor, 500e6, 2, payingMaturity, 30 days, payingTerms, _docs());
        vm.stopPrank();

        vm.warp(defaultMaturity + Params.GRACE_STRONG + 1);
        shelf.markDefaulted(defaultId);
        vm.prank(ops);
        shelf.resolveDefault(defaultId, true);
        assertTrue(reputation.permanentDefault(seller));

        uint256 reputationBefore = reputation.paidOnTimeCumulative(seller);
        vm.prank(servicer);
        shelf.applyPayment(payingId, 500e6);

        (,,,,,,,,,,,,, InvoiceShelf.Status status) = shelf.invoices(payingId);
        assertEq(uint8(status), uint8(InvoiceShelf.Status.Settled));
        assertEq(reputation.paidOnTimeCumulative(seller), reputationBefore);
        assertEq(shelf.frozenHoldbackOf(seller), 75e6, "terminal seller residual stays contested");
    }

    function test_resolveDefault_restructureLiftsFreeze() public {
        uint256 id = _lockDefaultable();
        vm.prank(servicer);
        shelf.markDefaulted(id);

        vm.prank(ops);
        shelf.resolveDefault(id, false);
        assertFalse(reputation.permanentDefault(seller));
        assertEq(reputation.restructuredCount(seller), 1);
        assertTrue(shelf.workspaceFrozen(seller), "classification cannot forgive the LP loss");
        assertEq(shelf.unresolvedDefaultCountOf(seller), 0);
        assertEq(shelf.sellerUnrecoveredLossOf(seller), 175e6);
        assertEq(
            uint8(shelf.defaultResolutionOf(id)),
            uint8(InvoiceShelf.DefaultResolution.Restructured),
            "restructure recorded once"
        );
        // earned capacity survives a restructure (L(w) unchanged: 1 on-time installment)
        assertEq(tiers.limitOf(seller), Params.L0_USDC + Params.RAMP_STEP_USDC);

        vm.prank(servicer);
        shelf.recoverDefault(id, 175e6);
        assertFalse(shelf.workspaceFrozen(seller), "cash cure plus completed resolution reopens the workspace");
        assertEq(shelf.sellerUnrecoveredLossOf(seller), 0);

        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.DefaultAlreadyResolved.selector, id));
        shelf.resolveDefault(id, false);
        assertEq(shelf.unresolvedDefaultCountOf(seller), 0);
        assertEq(reputation.restructuredCount(seller), 1, "replay cannot mutate reputation");

        vm.prank(lp);
        vm.expectRevert(); // ops-only
        shelf.resolveDefault(id, false);
    }

    function test_resolveDefault_restructureWaitsForEverySellerDefault() public {
        uint256 secondDebtor = _newWorkspace("secondDebtor", makeAddr("secondDebtorOwner"), 74, 87);
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory firstTerms =
            _newApprovedTerms(authorityVerifier, seller, debtor, address(usdc), 500e6, 2, firstMaturity, 30 days);
        ReceivableCommitment.FundingTerms memory secondTerms =
            _newApprovedTerms(authorityVerifier, seller, secondDebtor, address(usdc), 500e6, 2, firstMaturity, 30 days);

        vm.startPrank(servicer);
        uint256 firstId = shelf.lockInvoice(seller, debtor, 500e6, 2, firstMaturity, 30 days, firstTerms, _docs());
        uint256 secondId =
            shelf.lockInvoice(seller, secondDebtor, 500e6, 2, firstMaturity, 30 days, secondTerms, _docs());
        shelf.applyPayment(firstId, 250e6);
        shelf.applyPayment(secondId, 250e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 60 days + Params.GRACE_STRONG + 1);
        vm.startPrank(servicer);
        shelf.markDefaulted(firstId);
        shelf.markDefaulted(secondId);
        vm.stopPrank();

        assertEq(shelf.unresolvedDefaultCountOf(seller), 2);
        assertTrue(shelf.workspaceFrozen(seller));

        vm.prank(ops);
        shelf.resolveDefault(firstId, false);
        assertEq(shelf.unresolvedDefaultCountOf(seller), 1);
        assertTrue(shelf.workspaceFrozen(seller), "one resolution cannot hide the second default");

        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.DefaultAlreadyResolved.selector, firstId));
        shelf.resolveDefault(firstId, false);
        assertEq(shelf.unresolvedDefaultCountOf(seller), 1, "replay cannot decrement the seller count");

        vm.prank(ops);
        shelf.resolveDefault(secondId, false);
        assertEq(shelf.unresolvedDefaultCountOf(seller), 0);
        assertTrue(shelf.workspaceFrozen(seller), "resolved-but-unrecovered losses keep cross-default active");
        assertEq(reputation.restructuredCount(seller), 2);

        vm.prank(servicer);
        shelf.recoverDefault(firstId, 175e6);
        assertTrue(shelf.workspaceFrozen(seller), "one unpaid default remains");
        vm.prank(servicer);
        shelf.recoverDefault(secondId, 175e6);
        assertFalse(shelf.workspaceFrozen(seller), "all resolutions plus zero loss reopen the workspace");
    }

    function test_markDefaulted_reclassifiesCollectedHoldbackUntilLegitimateResolution() public {
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _newApprovedTerms(authorityVerifier, seller, debtor, address(usdc), 500e6, 2, firstMaturity, 30 days);
        vm.startPrank(servicer);
        uint256 id = shelf.lockInvoice(seller, debtor, 500e6, 2, firstMaturity, 30 days, terms, _docs());
        shelf.applyPayment(id, 450e6); // advance repaid; 25 holdback collected; final installment still partial
        vm.stopPrank();

        assertEq(shelf.totalHoldbackHeld(), 25e6);
        uint256 liquidBeforeDefault = shelf.totalLiquid();
        vm.warp(block.timestamp + 60 days + Params.GRACE_STRONG + 1);
        vm.prank(servicer);
        shelf.markDefaulted(id);

        (,,,,,, uint128 invoiceHoldbackCollected,,,,,,,) = shelf.invoices(id);
        assertEq(invoiceHoldbackCollected, 0, "default cannot strand holdback on a terminal invoice state");
        assertEq(shelf.frozenHoldbackOf(seller), 25e6, "cash remains seller-attributed for ops resolution");
        assertEq(shelf.totalHoldbackHeld(), 25e6, "reclassification does not destroy the liability");
        assertEq(shelf.totalLiquid(), liquidBeforeDefault, "reclassification does not inflate pool cash");
        assertEq(shelf.trancheLoss(2), 0, "fully repaid principal creates no LP loss");

        uint256 sellerBalanceBefore = usdc.balanceOf(sellerOwner);
        vm.prank(ops);
        shelf.resolveDefault(id, false);
        assertEq(shelf.frozenHoldbackOf(seller), 0);
        assertEq(shelf.totalHoldbackHeld(), 0);
        assertEq(usdc.balanceOf(sellerOwner) - sellerBalanceBefore, 25e6);
        assertEq(usdc.balanceOf(address(shelf)), shelf.totalLiquid(), "released holdback leaves no phantom cash");
    }

    function test_resolveDefault_fraudNetsLossAndReleasesOnlyExcessContestedHoldback() public {
        uint256 payingDebtor = _newWorkspace("payingDebtor", makeAddr("payingDebtorOwner"), 74, 87);
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory defaultTerms =
            _newApprovedTerms(authorityVerifier, seller, debtor, address(usdc), 500e6, 2, firstMaturity, 30 days);
        ReceivableCommitment.FundingTerms memory payingTerms =
            _newApprovedTerms(authorityVerifier, seller, payingDebtor, address(usdc), 500e6, 2, firstMaturity, 30 days);

        vm.startPrank(servicer);
        uint256 defaultId = shelf.lockInvoice(seller, debtor, 500e6, 2, firstMaturity, 30 days, defaultTerms, _docs());
        uint256 payingId =
            shelf.lockInvoice(seller, payingDebtor, 500e6, 2, firstMaturity, 30 days, payingTerms, _docs());
        shelf.applyPayment(defaultId, 400e6); // leaves 25 outstanding and no collected holdback
        vm.stopPrank();

        vm.warp(block.timestamp + 60 days + Params.GRACE_STRONG + 1);
        vm.prank(servicer);
        shelf.markDefaulted(defaultId);
        assertEq(shelf.trancheLoss(2), 25e6);

        // This invoice pays after its seller was cross-default frozen. Its 75 holdback
        // therefore remains contested and seller-attributed instead of being released.
        vm.prank(servicer);
        shelf.applyPayment(payingId, 500e6);
        assertEq(shelf.frozenHoldbackOf(seller), 75e6);
        assertEq(shelf.totalHoldbackHeld(), 75e6);

        uint256 sellerBalanceBefore = usdc.balanceOf(sellerOwner);
        uint256 liquidBefore = shelf.totalLiquid();
        vm.prank(ops);
        shelf.resolveDefault(defaultId, true);

        // Only 25 reverses booked loss. Cash above the enforceable recovery claim is
        // released even though the identity decision remains terminal.
        assertEq(shelf.trancheLoss(2), 0);
        assertEq(shelf.frozenHoldbackOf(seller), 0);
        assertEq(shelf.totalHoldbackHeld(), 0);
        assertEq(shelf.totalLiquid(), liquidBefore + 25e6);
        assertEq(usdc.balanceOf(sellerOwner) - sellerBalanceBefore, 50e6);
        assertEq(usdc.balanceOf(address(shelf)), shelf.totalLiquid(), "no holdback liability remains");
    }

    function test_lateContestedHoldbackCanRecoverAlreadyResolvedLoss() public {
        uint256 payingDebtor = _newWorkspace("latePayingDebtor", makeAddr("latePayingDebtorOwner"), 74, 87);
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory defaultTerms =
            _newApprovedTerms(authorityVerifier, seller, debtor, address(usdc), 500e6, 2, firstMaturity, 30 days);
        ReceivableCommitment.FundingTerms memory payingTerms =
            _newApprovedTerms(authorityVerifier, seller, payingDebtor, address(usdc), 500e6, 2, firstMaturity, 30 days);

        vm.startPrank(servicer);
        uint256 defaultId = shelf.lockInvoice(seller, debtor, 500e6, 2, firstMaturity, 30 days, defaultTerms, _docs());
        uint256 payingId =
            shelf.lockInvoice(seller, payingDebtor, 500e6, 2, firstMaturity, 30 days, payingTerms, _docs());
        shelf.applyPayment(defaultId, 400e6); // 25 of principal remains at default
        vm.stopPrank();

        vm.warp(block.timestamp + 60 days + Params.GRACE_STRONG + 1);
        shelf.markDefaulted(defaultId);
        vm.prank(ops);
        shelf.resolveDefault(defaultId, false);
        assertEq(shelf.unrecoveredLossOf(defaultId), 25e6);

        // Recourse arrives only after the one-shot ops resolution. It stays seller-
        // attributed until the permissionless recovery path applies it to the loss.
        vm.prank(servicer);
        shelf.applyPayment(payingId, 500e6);
        assertEq(shelf.frozenHoldbackOf(seller), 75e6);

        uint256 sellerBalanceBefore = usdc.balanceOf(sellerOwner);
        uint256 applied = shelf.applyFrozenHoldback(defaultId);

        assertEq(applied, 25e6);
        assertEq(shelf.unrecoveredLossOf(defaultId), 0);
        assertEq(shelf.sellerUnrecoveredLossOf(seller), 0);
        assertEq(shelf.trancheLoss(2), 0);
        assertEq(shelf.frozenHoldbackOf(seller), 0);
        assertEq(usdc.balanceOf(sellerOwner) - sellerBalanceBefore, 50e6, "only true excess returns to seller");
        assertFalse(shelf.workspaceFrozen(seller), "resolved and fully recovered seller reopens");
        assertEq(usdc.balanceOf(address(shelf)), shelf.totalLiquid(), "recovery preserves cash identity");
    }
}

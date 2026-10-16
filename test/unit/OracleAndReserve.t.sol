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
import {ReceivableCommitment} from "../../src/libraries/ReceivableCommitment.sol";
import {FactoringEvidenceV1} from "../../src/libraries/FactoringEvidenceV1.sol";
import {Params} from "../../src/libraries/Params.sol";

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
contract OracleAndReserveTest is Test {
    MockUSDC2 internal usdc;
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;
    InvoiceShelf internal shelf;
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
        shelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin, false);
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
        vm.prank(servicer);
        id = shelf.lockInvoice(
            seller,
            debtor,
            500e6,
            2,
            firstMaturity,
            30 days,
            _terms(keccak256("ARCA:oracle:defaultable"), firstMaturity),
            _evidence(keccak256("ARCA:oracle:defaultable")),
            _docs()
        );
        vm.prank(servicer);
        shelf.applyPayment(id, 250e6); // installment 1 on time; outstanding 175
        vm.warp(block.timestamp + 60 days + Params.GRACE_STRONG + 1); // miss installment 2
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
        assertEq(oracleA.price(), 1e24);
    }

    function test_breaker_tripsOnBigMove_thenOpsClears() public {
        oracleC.observe(); // baseline at par

        // engineer a >10% junior NAV drop: withdraw-like big loss via default with big face
        // (velocity/caps sized fine: face 500 → loss 175 is ~0.09%; instead trip by
        //  simulating many defaults is slow — use a fresh thin tranche instead)
        // Simplest honest path: new shelf with tiny junior so one default is >10%.
        InvoiceShelf shelf2 = new InvoiceShelf(usdc, identity, reputation, tiers, admin, false);
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
        o2.observe();

        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        vm.prank(servicer);
        uint256 id = shelf2.lockInvoice(
            seller,
            debtor,
            500e6,
            2,
            firstMaturity,
            30 days,
            _terms(keccak256("ARCA:oracle:shelf2"), firstMaturity),
            _evidence(keccak256("ARCA:oracle:shelf2")),
            _docs()
        );
        vm.prank(servicer);
        shelf2.applyPayment(id, 250e6);
        vm.warp(block.timestamp + 60 days + Params.GRACE_STRONG + 1);
        vm.prank(servicer);
        shelf2.markDefaulted(id); // loss 175 / 1000 = 17.5% > 10%

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
        InvoiceShelf shelf3 = new InvoiceShelf(usdc, identity, reputation, tiers, admin, false);
        BUFIOracle o3 = new BUFIOracle(shelf3, 1, admin);
        vm.expectRevert(BUFIOracle.EmptyTranche.selector);
        o3.price();
    }

    // ── M4: bond gate + reserve as waterfall layer 2 ──

    function test_bondGate_developingSellerMustPost() public {
        address weakOwner = makeAddr("weakOwner");
        uint256 weakSeller = _newWorkspace("weak", weakOwner, 30, 30); // Developing seller
        // advance rate keys on the DEBTOR (87=Excellent 90%, −5% no-pair = 85%): 400×85% = 340
        // required floor = 340 × 25% reserve × 100% bond = 85
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.Terms memory terms = _terms(keccak256("ARCA:reserve:weak"), firstMaturity);
        FactoringEvidenceV1 memory evidence = _evidence(keccak256("ARCA:reserve:weak"));
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.BondNotPosted.selector, 85e6, 0));
        shelf.lockInvoice(weakSeller, debtor, 400e6, 2, firstMaturity, 30 days, terms, evidence, _docs());

        // post the bond → lock succeeds
        usdc.mint(weakOwner, 100e6);
        vm.startPrank(weakOwner);
        usdc.approve(address(reserve), type(uint256).max);
        reserve.postBond(weakSeller, 85e6);
        vm.stopPrank();
        vm.prank(servicer);
        shelf.lockInvoice(weakSeller, debtor, 400e6, 2, firstMaturity, 30 days, terms, evidence, _docs());
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

    // ── M4: resolution — fraud terminal vs restructure lifts freeze ──

    function test_resolveDefault_fraudIsTerminal() public {
        uint256 id = _lockDefaultable();
        vm.prank(servicer);
        shelf.markDefaulted(id);

        vm.prank(ops);
        shelf.resolveDefault(id, true);
        assertTrue(reputation.permanentDefault(seller));
        assertEq(tiers.limitOf(seller), 0);
        assertTrue(shelf.workspaceFrozen(seller)); // freeze permanent on fraud
    }

    function test_resolveDefault_restructureLiftsFreeze() public {
        uint256 id = _lockDefaultable();
        vm.prank(servicer);
        shelf.markDefaulted(id);

        vm.prank(ops);
        shelf.resolveDefault(id, false);
        assertFalse(reputation.permanentDefault(seller));
        assertEq(reputation.restructuredCount(seller), 1);
        assertFalse(shelf.workspaceFrozen(seller));
        // earned capacity survives a restructure (L(w) unchanged: 1 on-time installment)
        assertEq(tiers.limitOf(seller), Params.L0_USDC + Params.RAMP_STEP_USDC);

        vm.prank(lp);
        vm.expectRevert(); // ops-only
        shelf.resolveDefault(id, false);
    }
}

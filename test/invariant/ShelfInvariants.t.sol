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
import {ReceivableCommitment} from "../../src/libraries/ReceivableCommitment.sol";
import {FactoringEvidenceV1} from "../../src/libraries/FactoringEvidenceV1.sol";

contract InvUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Handler: fuzzes the full invoice lifecycle across a fixed roster of KYB'd
///      workspaces, so the invariant engine explores lock/pay/default interleavings.
contract ShelfHandler is Test {
    InvoiceShelf public shelf;
    BUFIIdentityRegistry public identity;
    BUFIReputationRegistry public reputation;
    WorkspaceTierRegistry public tiers;
    InvUSDC public usdc;

    uint256[] public sellers;
    uint256[] public debtors;
    address internal servicer;

    uint256[] public liveInvoices;
    uint256 public authorityNonce;

    constructor(
        InvoiceShelf _shelf,
        BUFIIdentityRegistry _identity,
        BUFIReputationRegistry _reputation,
        WorkspaceTierRegistry _tiers,
        InvUSDC _usdc,
        uint256[] memory _sellers,
        uint256[] memory _debtors,
        address _servicer
    ) {
        shelf = _shelf;
        identity = _identity;
        reputation = _reputation;
        tiers = _tiers;
        usdc = _usdc;
        sellers = _sellers;
        debtors = _debtors;
        servicer = _servicer;
    }

    function lock(uint256 sSeed, uint256 dSeed, uint128 face) external {
        uint256 seller = sellers[sSeed % sellers.length];
        uint256 debtor = debtors[dSeed % debtors.length];
        face = uint128(bound(face, 10e6, 400e6));
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        bytes32 authorityId = keccak256(abi.encode("INVARIANT_AUTHORITY_INVOICE", ++authorityNonce));
        ReceivableCommitment.Terms memory terms = ReceivableCommitment.Terms({
            canonicalInvoiceCommitmentHash: authorityId,
            issuedAt: uint64(block.timestamp),
            dueAt: firstMaturity + 30 days
        });
        FactoringEvidenceV1 memory evidence = FactoringEvidenceV1({
            featureRootHash: keccak256(abi.encode("FEATURE_ROOT", authorityId)),
            currentSnapshotHash: keccak256(abi.encode("CURRENT_SNAPSHOT", authorityId)),
            privateTermsHash: keccak256(abi.encode("PRIVATE_TERMS", authorityId))
        });
        vm.prank(servicer);
        try shelf.lockInvoice(seller, debtor, face, 2, firstMaturity, 30 days, terms, evidence, _docs()) returns (
            uint256 id
        ) {
            liveInvoices.push(id);
        } catch {}
    }

    function pay(uint256 idSeed, uint128 amount) external {
        if (liveInvoices.length == 0) return;
        uint256 id = liveInvoices[idSeed % liveInvoices.length];
        amount = uint128(bound(amount, 1e6, 400e6));
        vm.prank(servicer);
        try shelf.applyPayment(id, amount) {} catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 days, 90 days));
    }

    function markDefault(uint256 idSeed) external {
        if (liveInvoices.length == 0) return;
        uint256 id = liveInvoices[idSeed % liveInvoices.length];
        vm.prank(servicer);
        try shelf.markDefaulted(id) {} catch {}
    }

    function sellersLength() external view returns (uint256) {
        return sellers.length;
    }

    function sellerAt(uint256 i) external view returns (uint256) {
        return sellers[i];
    }

    function _docs() internal pure returns (BINV.DocBundle memory) {
        return BINV.DocBundle(bytes32("i"), bytes32("a"), bytes32("p"), bytes32("s"), bytes32("d"));
    }
}

contract ShelfInvariantsTest is Test {
    InvUSDC internal usdc;
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;
    InvoiceShelf internal shelf;
    ShelfHandler internal handler;

    address internal admin = makeAddr("admin");

    uint256 internal constant SENIOR = 500_000e6;
    uint256 internal constant MEZZ = 300_000e6;
    uint256 internal constant JUNIOR = 200_000e6;
    uint256 internal constant TOTAL_DEPOSITS = SENIOR + MEZZ + JUNIOR;

    function setUp() public {
        usdc = new InvUSDC();
        identity = new BUFIIdentityRegistry(admin);
        reputation = new BUFIReputationRegistry(admin, identity);
        tiers = new WorkspaceTierRegistry(identity, reputation);
        shelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin);

        address issuer = makeAddr("issuer");
        address attestor = makeAddr("attestor");
        address servicer = makeAddr("servicer");
        vm.startPrank(admin);
        identity.grantRole(identity.ISSUER_ROLE(), issuer);
        reputation.grantRole(reputation.ATTESTOR_ROLE(), attestor);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(shelf));
        shelf.grantRole(shelf.SERVICER_ROLE(), servicer);
        vm.stopPrank();

        uint256[] memory sellers = new uint256[](3);
        uint256[] memory debtors = new uint256[](3);
        for (uint256 i = 0; i < 3; ++i) {
            vm.startPrank(issuer);
            sellers[i] =
                identity.registerWorkspace(keccak256(abi.encode("seller", i)), makeAddr(string(abi.encode("s", i))));
            debtors[i] =
                identity.registerWorkspace(keccak256(abi.encode("debtor", i)), makeAddr(string(abi.encode("d", i))));
            identity.setKybStatus(sellers[i], true);
            identity.setKybStatus(debtors[i], true);
            vm.stopPrank();
            vm.startPrank(attestor);
            reputation.setScore(sellers[i], 74, 74, 1, bytes32("s"));
            reputation.setScore(debtors[i], 74, 87, 1, bytes32("d"));
            vm.stopPrank();
        }

        address lp = makeAddr("lp");
        usdc.mint(lp, TOTAL_DEPOSITS);
        vm.startPrank(lp);
        usdc.approve(address(shelf), type(uint256).max);
        shelf.depositTranche(0, SENIOR);
        shelf.depositTranche(1, MEZZ);
        shelf.depositTranche(2, JUNIOR);
        vm.stopPrank();

        usdc.mint(servicer, 100_000_000e6);
        vm.prank(servicer);
        usdc.approve(address(shelf), type(uint256).max);

        handler = new ShelfHandler(shelf, identity, reputation, tiers, usdc, sellers, debtors, servicer);
        // re-grant servicer role to the handler (it pranks servicer, so role is on servicer;
        // the handler calls via vm.prank(servicer) so no extra grant needed)
        targetContract(address(handler));
    }

    /// @notice I1 — no seller's aggregate at-risk exposure ever exceeds its earned L(w).
    function invariant_atRiskExposureNeverExceedsLimit() public view {
        for (uint256 i = 0; i < handler.sellersLength(); ++i) {
            uint256 s = handler.sellerAt(i);
            assertLe(shelf.outstandingOf(s), tiers.limitOf(s), "I1: exposure > L(w)");
        }
    }

    /// @notice I2 — senior (A) and mezz (B) NAV stay at par until the junior buffer is wiped;
    ///         senior only takes loss after both junior and mezz capacity are exhausted.
    function invariant_seniorParUnlessJuniorExhausted() public view {
        if (shelf.trancheLoss(0) > 0) {
            // senior touched → junior AND mezz must be fully wiped
            assertEq(shelf.trancheAssets(2), 0, "I2: senior loss while junior solvent");
            assertEq(shelf.trancheAssets(1), 0, "I2: senior loss while mezz solvent");
        }
        if (shelf.trancheLoss(1) > 0) {
            assertEq(shelf.trancheAssets(2), 0, "I2: mezz loss while junior solvent");
        }
    }

    /// @notice I3 — the pool identity always holds: fundable cash + deployed principal
    ///         == total LP deposits − realized losses. No phantom assets can be minted.
    function invariant_poolIdentity() public view {
        uint256 totalLoss = shelf.trancheLoss(0) + shelf.trancheLoss(1) + shelf.trancheLoss(2);
        assertEq(shelf.totalLiquid() + shelf.totalPrincipal(), TOTAL_DEPOSITS - totalLoss, "I3: pool identity broken");
    }

    /// @notice I3b — real USDC held equals fundable cash plus the holdback owed to sellers.
    function invariant_cashBacked() public view {
        assertEq(
            usdc.balanceOf(address(shelf)),
            shelf.totalLiquid() + shelf.totalHoldbackHeld(),
            "I3b: USDC balance != liquid + held holdback"
        );
    }

    /// @notice I4 — every successfully funded invoice permanently owns one unique,
    ///         nonzero canonical receivable commitment.
    function invariant_receivableCommitmentsAreInjective() public view {
        uint256 nextId = shelf.nextInvoiceId();
        for (uint256 invoiceId = 1; invoiceId < nextId; ++invoiceId) {
            bytes32 commitment = shelf.receivableCommitmentOf(invoiceId);
            bytes32 authorityInvoiceId = shelf.authorityInvoiceIdOf(invoiceId);
            assertNotEq(commitment, bytes32(0), "I4: funded invoice missing commitment");
            assertNotEq(authorityInvoiceId, bytes32(0), "I4: funded invoice missing authority ID");
            assertEq(
                shelf.invoiceIdOfReceivableCommitment(commitment),
                invoiceId,
                "I4: commitment points to different invoice"
            );
            assertEq(
                shelf.invoiceIdOfAuthorityInvoiceId(authorityInvoiceId),
                invoiceId,
                "I4: authority ID points to different invoice"
            );
            for (uint256 otherId = invoiceId + 1; otherId < nextId; ++otherId) {
                assertNotEq(commitment, shelf.receivableCommitmentOf(otherId), "I4: duplicate commitment");
                assertNotEq(authorityInvoiceId, shelf.authorityInvoiceIdOf(otherId), "I4: duplicate authority ID");
            }
        }
    }
}

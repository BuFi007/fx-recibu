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
import {StrictAuthorityFixture, StrictAuthorityInvoiceVerifier} from "../utils/StrictAuthorityInvoiceVerifier.sol";

contract InvUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Handler fuzzes the lifecycle and records non-vacuous authority coverage.
contract ShelfHandler is Test {
    InvoiceShelf public shelf;
    BUFIIdentityRegistry public identity;
    BUFIReputationRegistry public reputation;
    WorkspaceTierRegistry public tiers;
    StrictAuthorityInvoiceVerifier public authorityVerifier;
    InvUSDC public usdc;

    uint256[] public sellers;
    uint256[] public debtors;
    address internal servicer;

    uint256[] public liveInvoices;
    bytes32[] public fundedAuthorityIds;
    uint256[] public fundedInvoiceIds;

    uint256 public lockAttempts;
    uint256 public successfulLocks;
    uint256 public duplicateAttempts;
    uint256 public duplicateGuardReverts;
    uint256 public duplicateSuccesses;
    uint256 private authorityFixtureCounter;

    error UnexpectedDuplicateRevert(bytes reason);

    constructor(
        InvoiceShelf shelf_,
        BUFIIdentityRegistry identity_,
        BUFIReputationRegistry reputation_,
        WorkspaceTierRegistry tiers_,
        StrictAuthorityInvoiceVerifier authorityVerifier_,
        InvUSDC usdc_,
        uint256[] memory sellers_,
        uint256[] memory debtors_,
        address servicer_
    ) {
        shelf = shelf_;
        identity = identity_;
        reputation = reputation_;
        tiers = tiers_;
        authorityVerifier = authorityVerifier_;
        usdc = usdc_;
        sellers = sellers_;
        debtors = debtors_;
        servicer = servicer_;
    }

    function seedAuthorityCoverage(uint256 seller, uint256 debtor, uint128 face) external {
        bytes32 authorityInvoiceId = _nextAuthorityInvoiceId();
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms = _terms(authorityInvoiceId);
        BINV.DocBundle memory docs = _docs(bytes32("seed-a"));
        _approve(terms, seller, debtor, face, firstMaturity);

        ++lockAttempts;
        vm.prank(servicer);
        uint256 originalInvoiceId = shelf.lockInvoice(seller, debtor, face, 2, firstMaturity, 30 days, terms, docs);
        _recordSuccessfulLock(originalInvoiceId, authorityInvoiceId);

        ReceivableCommitment.FundingTerms memory changedTerms = terms;
        changedTerms.authority.authorityEvidenceCommitment = keccak256("invariant changed evidence");
        changedTerms.authority.authorityPaymentDueAt += 1 days;
        BINV.DocBundle memory changedDocs = _docs(bytes32("seed-b"));
        _approve(changedTerms, seller, debtor, face, firstMaturity);

        ++lockAttempts;
        ++duplicateAttempts;
        vm.prank(servicer);
        try shelf.lockInvoice(seller, debtor, face, 2, firstMaturity, 30 days, changedTerms, changedDocs) returns (
            uint256
        ) {
            ++duplicateSuccesses;
        } catch (bytes memory reason) {
            bytes memory expected = abi.encodeWithSelector(
                InvoiceShelf.AuthorityInvoiceAlreadyConsumed.selector, authorityInvoiceId, originalInvoiceId
            );
            if (keccak256(reason) != keccak256(expected)) revert UnexpectedDuplicateRevert(reason);
            ++duplicateGuardReverts;
        }
    }

    function lock(uint256 sellerSeed, uint256 debtorSeed, uint128 face) external {
        uint256 seller = sellers[sellerSeed % sellers.length];
        uint256 debtor = debtors[debtorSeed % debtors.length];
        face = uint128(bound(face, 10e6, 400e6));
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        bytes32 authorityInvoiceId = _nextAuthorityInvoiceId();
        ReceivableCommitment.FundingTerms memory terms = _terms(authorityInvoiceId);
        _approve(terms, seller, debtor, face, firstMaturity);

        ++lockAttempts;
        vm.prank(servicer);
        try shelf.lockInvoice(
            seller, debtor, face, 2, firstMaturity, 30 days, terms, _docs(authorityInvoiceId)
        ) returns (
            uint256 invoiceId
        ) {
            _recordSuccessfulLock(invoiceId, authorityInvoiceId);
        } catch {}
    }

    function pay(uint256 idSeed, uint128 amount) external {
        if (liveInvoices.length == 0) return;
        uint256 invoiceId = liveInvoices[idSeed % liveInvoices.length];
        amount = uint128(bound(amount, 1e6, 400e6));
        vm.prank(servicer);
        try shelf.applyPayment(invoiceId, amount) {} catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 days, 90 days));
    }

    function markDefault(uint256 idSeed) external {
        if (liveInvoices.length == 0) return;
        uint256 invoiceId = liveInvoices[idSeed % liveInvoices.length];
        vm.prank(servicer);
        try shelf.markDefaulted(invoiceId) {} catch {}
    }

    function sellersLength() external view returns (uint256) {
        return sellers.length;
    }

    function sellerAt(uint256 index) external view returns (uint256) {
        return sellers[index];
    }

    function liveInvoicesLength() external view returns (uint256) {
        return liveInvoices.length;
    }

    function liveInvoiceAt(uint256 index) external view returns (uint256) {
        return liveInvoices[index];
    }

    function fundedAuthorityIdsLength() external view returns (uint256) {
        return fundedAuthorityIds.length;
    }

    function fundedAuthorityIdAt(uint256 index) external view returns (bytes32) {
        return fundedAuthorityIds[index];
    }

    function fundedInvoiceIdAt(uint256 index) external view returns (uint256) {
        return fundedInvoiceIds[index];
    }

    function _recordSuccessfulLock(uint256 invoiceId, bytes32 authorityInvoiceId) internal {
        ++successfulLocks;
        liveInvoices.push(invoiceId);
        fundedAuthorityIds.push(authorityInvoiceId);
        fundedInvoiceIds.push(invoiceId);
    }

    function _nextAuthorityInvoiceId() internal returns (bytes32) {
        return
            keccak256(
                abi.encode("BUFI_INVARIANT_OPAQUE_AUTHORITY_FIXTURE_V1", address(this), ++authorityFixtureCounter)
            );
    }

    function _terms(bytes32 authorityInvoiceId) internal view returns (ReceivableCommitment.FundingTerms memory) {
        uint64 issuedAt = uint64(block.timestamp);
        if (issuedAt == 0) issuedAt = 1;
        return ReceivableCommitment.FundingTerms({
            authority: ReceivableCommitment.AuthorityRef({
                schemaVersion: ReceivableCommitment.VERSION,
                authorityInvoiceId: authorityInvoiceId,
                authorityEvidenceCommitment: keccak256(
                    abi.encode("BUFI_INVARIANT_AUTHORITY_EVIDENCE_V1", authorityInvoiceId)
                ),
                verifierConfigId: authorityVerifier.verifierConfigId(),
                authorityVoucherType: 19,
                issuedAt: issuedAt,
                authorityPaymentDueAt: issuedAt + 90 days
            }),
            recourse: true
        });
    }

    function _approve(
        ReceivableCommitment.FundingTerms memory terms,
        uint256 seller,
        uint256 debtor,
        uint128 face,
        uint64 firstMaturity
    ) internal {
        authorityVerifier.setApproval(
            terms.authority, seller, debtor, address(usdc), face, terms.recourse, 2, firstMaturity, 30 days, true
        );
    }

    function _docs(bytes32 namespace) internal pure returns (BINV.DocBundle memory) {
        return BINV.DocBundle({
            invoiceDocHash: keccak256(abi.encode(namespace, "invoice")),
            assignmentHash: keccak256(abi.encode(namespace, "assignment")),
            paymentInstructionHash: keccak256(abi.encode(namespace, "payment")),
            servicingPolicyHash: keccak256(abi.encode(namespace, "servicing")),
            disputePolicyHash: keccak256(abi.encode(namespace, "dispute"))
        });
    }
}

contract ShelfInvariantsTest is StrictAuthorityFixture {
    InvUSDC internal usdc;
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;
    InvoiceShelf internal shelf;
    StrictAuthorityInvoiceVerifier internal authorityVerifier;
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
        (shelf, authorityVerifier) = _deployStrictShelf(usdc, identity, reputation, tiers, admin);

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

        handler =
            new ShelfHandler(shelf, identity, reputation, tiers, authorityVerifier, usdc, sellers, debtors, servicer);
        handler.seedAuthorityCoverage(sellers[0], debtors[0], 20e6);
        targetContract(address(handler));
    }

    function invariant_authorityCoverageIsNonVacuous() public view {
        assertGt(handler.successfulLocks(), 0, "authority success coverage is empty");
        assertGt(handler.duplicateAttempts(), 0, "duplicate coverage is empty");
        assertEq(handler.duplicateSuccesses(), 0, "a duplicate authority funded");
        assertEq(handler.duplicateGuardReverts(), handler.duplicateAttempts());
        assertEq(handler.fundedAuthorityIdsLength(), handler.successfulLocks(), "successful lock index mismatch");
    }

    function invariant_authorityIdentityIsInjectiveAndPermanent() public view {
        uint256 length = handler.fundedAuthorityIdsLength();
        for (uint256 i = 0; i < length; ++i) {
            bytes32 authorityInvoiceId = handler.fundedAuthorityIdAt(i);
            uint256 invoiceId = handler.fundedInvoiceIdAt(i);
            assertEq(shelf.invoiceIdOfAuthorityInvoiceId(authorityInvoiceId), invoiceId);
            assertEq(shelf.authorityInvoiceIdOf(invoiceId), authorityInvoiceId);
            for (uint256 j = i + 1; j < length; ++j) {
                assertNotEq(authorityInvoiceId, handler.fundedAuthorityIdAt(j), "authority identity reused");
            }
        }
    }

    function invariant_atRiskExposureNeverExceedsLimit() public view {
        for (uint256 i = 0; i < handler.sellersLength(); ++i) {
            uint256 seller = handler.sellerAt(i);
            assertLe(shelf.outstandingOf(seller), tiers.limitOf(seller), "I1: exposure > L(w)");
        }
    }

    function invariant_seniorParUnlessJuniorExhausted() public view {
        if (shelf.trancheLoss(0) > 0) {
            assertEq(shelf.trancheAssets(2), 0, "I2: senior loss while junior solvent");
            assertEq(shelf.trancheAssets(1), 0, "I2: senior loss while mezz solvent");
        }
        if (shelf.trancheLoss(1) > 0) {
            assertEq(shelf.trancheAssets(2), 0, "I2: mezz loss while junior solvent");
        }
    }

    function invariant_poolIdentity() public view {
        uint256 totalLoss = shelf.trancheLoss(0) + shelf.trancheLoss(1) + shelf.trancheLoss(2);
        assertEq(shelf.totalLiquid() + shelf.totalPrincipal(), TOTAL_DEPOSITS - totalLoss, "I3: pool identity broken");
    }

    function invariant_cashBacked() public view {
        assertEq(
            usdc.balanceOf(address(shelf)),
            shelf.totalLiquid() + shelf.totalHoldbackHeld(),
            "I3b: USDC balance != liquid + held holdback"
        );
    }

    function invariant_currentInstallmentMatchesShelfLedger() public view {
        for (uint256 i = 0; i < handler.liveInvoicesLength(); ++i) {
            uint256 invoiceId = handler.liveInvoiceAt(i);
            (,,,,,,,,, uint32 grace, uint8 nInstallments, uint8 paidInstallments,, InvoiceShelf.Status status) =
                shelf.invoices(invoiceId);

            assertLe(paidInstallments, nInstallments, "I4: completion cursor exceeds schedule");
            if (status == InvoiceShelf.Status.Funded) {
                assertLt(paidInstallments, nInstallments, "I4: funded invoice has no open slot");
                (uint8 index, uint256 fullAmount, uint256 paidAmount, uint256 maturity, uint256 graceEndsAt) =
                    shelf.currentInstallment(invoiceId);

                assertEq(index, paidInstallments, "I4: projection diverges from completion cursor");
                assertEq(paidAmount, shelf.installmentProgress(invoiceId), "I4: projection progress diverges");
                assertEq(fullAmount, shelf.installmentAmount(invoiceId, index), "I4: projection amount diverges");
                assertLt(paidAmount, fullAmount, "I4: completed slot left at current cursor");
                assertEq(maturity, shelf.installmentDue(invoiceId, index), "I4: projection maturity diverges");
                assertEq(graceEndsAt, maturity + grace, "I4: projection grace diverges");
            } else {
                (bool ok,) = address(shelf)
                    .staticcall(abi.encodeWithSelector(InvoiceShelf.currentInstallment.selector, invoiceId));
                assertFalse(ok, "I4: non-funded invoice exposes a current slot");
                if (status == InvoiceShelf.Status.Settled) {
                    assertEq(paidInstallments, nInstallments, "I4: settled schedule incomplete");
                    assertEq(shelf.installmentProgress(invoiceId), 0, "I4: settled progress remains");
                }
            }
        }
    }
}

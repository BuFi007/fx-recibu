// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {BUFIIdentityRegistry} from "../../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../../src/identity/BUFIReputationRegistry.sol";
import {WorkspaceTierRegistry} from "../../src/credit/WorkspaceTierRegistry.sol";
import {InvoiceShelf} from "../../src/invoice/InvoiceShelf.sol";
import {BINV} from "../../src/invoice/BINV.sol";
import {ReceivableEscrow} from "../../src/rails/ReceivableEscrow.sol";
import {InvoiceMemoRouter} from "../../src/rails/InvoiceMemoRouter.sol";
import {InvoiceSettlement} from "../../src/rails/InvoiceSettlement.sol";
import {
    FactoringSettlementExtractor,
    IInvoiceSettlementTarget,
    IInvoiceShelfTarget
} from "../../src/rails/FactoringSettlementExtractor.sol";
import {IInvoiceShelf} from "../../src/interfaces/IInvoiceShelf.sol";
import {IReceiver} from "../../src/interfaces/IReceiver.sol";
import {ReceivableCommitment} from "../../src/libraries/ReceivableCommitment.sol";
import {FactoringEvidenceV1} from "../../src/libraries/FactoringEvidenceV1.sol";

contract ExtractorUSDC is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ExtractorShelfLinkMock {
    address public immutable USDC;

    constructor(address token) {
        USDC = token;
    }
}

contract FactoringSettlementExtractorTest is Test {
    uint64 internal constant ARC_CHAIN_SELECTOR = 3_034_092_155_422_581_607;
    uint128 internal constant FACE = 500e6;
    uint128 internal constant LOCK_FACE = 20e6;
    bytes32 internal constant LOCK_CANONICAL_INVOICE_HASH = keccak256("ARCA:extractor:canonical-invoice");

    ExtractorUSDC internal usdc;
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;
    InvoiceShelf internal shelf;
    ReceivableEscrow internal escrow;
    InvoiceMemoRouter internal router;
    InvoiceSettlement internal settlement;
    FactoringSettlementExtractor internal extractor;

    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");
    address internal attestor = makeAddr("attestor");
    address internal servicer = makeAddr("servicer");
    address internal forwarder = makeAddr("forwarder");
    address internal payer = makeAddr("payer");
    address internal sellerOwner = makeAddr("sellerOwner");

    uint256 internal seller;
    uint256 internal debtor;
    uint256 internal invoiceId;

    function setUp() public {
        usdc = new ExtractorUSDC("USD Coin", "USDC");
        identity = new BUFIIdentityRegistry(admin);
        reputation = new BUFIReputationRegistry(admin, identity);
        tiers = new WorkspaceTierRegistry(identity, reputation);
        shelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin, false);
        escrow = new ReceivableEscrow(usdc, admin);
        router = new InvoiceMemoRouter(usdc, IInvoiceShelf(address(shelf)), escrow);
        settlement = new InvoiceSettlement(usdc, IInvoiceShelf(address(shelf)), escrow, admin);
        extractor = new FactoringSettlementExtractor(
            address(this),
            forwarder,
            ARC_CHAIN_SELECTOR,
            IInvoiceShelfTarget(address(shelf)),
            IInvoiceSettlementTarget(address(settlement))
        );

        vm.startPrank(admin);
        identity.grantRole(identity.ISSUER_ROLE(), issuer);
        reputation.grantRole(reputation.ATTESTOR_ROLE(), attestor);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(shelf));
        shelf.grantRole(shelf.SERVICER_ROLE(), servicer);
        shelf.grantRole(shelf.SERVICER_ROLE(), address(extractor));
        shelf.grantRole(shelf.SETTLEMENT_ROLE(), address(settlement));
        escrow.grantRole(escrow.ROUTER_ROLE(), address(router));
        escrow.grantRole(escrow.SETTLEMENT_ROLE(), address(settlement));
        settlement.grantRole(settlement.KEEPER_ROLE(), address(extractor));
        shelf.setEscrow(address(escrow));
        vm.stopPrank();

        seller = _workspace("seller", sellerOwner, 74, 74);
        debtor = _workspace("debtor", makeAddr("debtorOwner"), 74, 87);

        address lp = makeAddr("lp");
        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(shelf), type(uint256).max);
        shelf.depositTranche(2, 1_000_000e6);
        vm.stopPrank();

        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        vm.prank(servicer);
        invoiceId = shelf.lockInvoice(
            seller,
            debtor,
            FACE,
            2,
            firstMaturity,
            30 days,
            _terms(keccak256("ARCA:extractor:seed"), firstMaturity, 2),
            _evidence(keccak256("ARCA:extractor:seed")),
            _docs()
        );

        usdc.mint(payer, 1_000_000e6);
        vm.prank(payer);
        usdc.approve(address(router), type(uint256).max);
    }

    // ── Receiver + administration ───────────────────────────────────────────

    function test_supportsIReceiverAndERC165() public view {
        assertTrue(extractor.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(extractor.supportsInterface(type(IERC165).interfaceId));
        assertFalse(extractor.supportsInterface(0xffffffff));
    }

    function test_onReportAndExtractRejectNonForwarder() public {
        address stranger = makeAddr("stranger");
        bytes memory inner = _defaultInner(keccak256("auth"), invoiceId, _deadline());

        vm.expectRevert(abi.encodeWithSelector(FactoringSettlementExtractor.NotForwarder.selector, stranger));
        vm.prank(stranger);
        extractor.onReport("", _outer(address(shelf), inner));

        vm.expectRevert(abi.encodeWithSelector(FactoringSettlementExtractor.NotForwarder.selector, stranger));
        vm.prank(stranger);
        extractor.extract(address(shelf), inner);
    }

    function test_setForwarderIsOwnerOnlyAndRejectsZero() public {
        address stranger = makeAddr("stranger");
        vm.expectRevert();
        vm.prank(stranger);
        extractor.setForwarder(stranger);

        vm.expectRevert(FactoringSettlementExtractor.ZeroAddress.selector);
        extractor.setForwarder(address(0));

        address next = makeAddr("nextForwarder");
        vm.expectEmit(true, true, false, true, address(extractor));
        emit FactoringSettlementExtractor.ForwarderUpdated(forwarder, next);
        extractor.setForwarder(next);
        assertEq(extractor.forwarder(), next);
    }

    function test_ownershipTransferIsTwoStep() public {
        address nextOwner = makeAddr("nextOwner");
        extractor.transferOwnership(nextOwner);
        assertEq(extractor.owner(), address(this));
        assertEq(extractor.pendingOwner(), nextOwner);

        vm.prank(nextOwner);
        extractor.acceptOwnership();
        assertEq(extractor.owner(), nextOwner);
    }

    function test_pauseBlocksBothReceiverEntries() public {
        bytes memory inner = _defaultInner(keccak256("paused"), invoiceId, _deadline());
        extractor.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(forwarder);
        extractor.onReport("", _outer(address(shelf), inner));

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(forwarder);
        extractor.extract(address(shelf), inner);

        extractor.unpause();
        assertFalse(extractor.paused());
    }

    function test_expectedWorkflowIdValidatesMetadataAndDisablesExtract() public {
        bytes32 workflowId = keccak256("workflow-factoring-lifecycle");
        extractor.setExpectedWorkflowId(workflowId);
        bytes memory inner = _settleInner(keccak256("workflow"), invoiceId, 0, address(usdc), _deadline());

        vm.prank(payer);
        router.pay(invoiceId, 0, 250e6);

        bytes memory metadata = abi.encodePacked(workflowId, bytes10("factoring"), address(this), bytes2(uint16(1)));
        vm.prank(forwarder);
        extractor.onReport(metadata, _outer(address(settlement), inner));
        assertEq(escrow.escrowedOf(invoiceId), 0);

        vm.expectRevert(FactoringSettlementExtractor.CompatibilityExtractDisabled.selector);
        vm.prank(forwarder);
        extractor.extract(address(settlement), inner);
    }

    function test_expectedWorkflowIdRejectsWrongOrMissingMetadata() public {
        bytes32 expected = keccak256("expected");
        bytes32 received = keccak256("received");
        extractor.setExpectedWorkflowId(expected);
        bytes memory inner = _defaultInner(keccak256("metadata"), invoiceId, _deadline());

        bytes memory metadata = abi.encodePacked(received, bytes10(0), address(0), bytes2(0));
        vm.expectRevert(
            abi.encodeWithSelector(FactoringSettlementExtractor.UnexpectedWorkflowId.selector, received, expected)
        );
        vm.prank(forwarder);
        extractor.onReport(metadata, _outer(address(shelf), inner));

        vm.expectRevert(abi.encodeWithSelector(FactoringSettlementExtractor.InvalidMetadataLength.selector, uint256(2)));
        vm.prank(forwarder);
        extractor.onReport(hex"1234", _outer(address(shelf), inner));
    }

    // ── Envelope validation + replay ─────────────────────────────────────────

    function test_rejectsUnknownActionWrongSelectorZeroOperationAndExpiry() public {
        bytes32 op = keccak256("envelope");
        bytes memory payload = abi.encode(invoiceId);

        vm.expectRevert(abi.encodeWithSelector(FactoringSettlementExtractor.UnknownAction.selector, uint8(0)));
        _callOnReport(address(shelf), _inner(0, ARC_CHAIN_SELECTOR, op, _deadline(), payload));

        uint64 wrongSelector = ARC_CHAIN_SELECTOR + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                FactoringSettlementExtractor.WrongChainSelector.selector, wrongSelector, ARC_CHAIN_SELECTOR
            )
        );
        _callOnReport(address(shelf), _inner(uint8(3), wrongSelector, op, _deadline(), payload));

        vm.expectRevert(FactoringSettlementExtractor.ZeroOperationId.selector);
        _callOnReport(address(shelf), _inner(uint8(3), ARC_CHAIN_SELECTOR, bytes32(0), _deadline(), payload));

        uint64 expired = uint64(block.timestamp - 1);
        vm.expectRevert(
            abi.encodeWithSelector(FactoringSettlementExtractor.ReportExpired.selector, expired, block.timestamp)
        );
        _callOnReport(address(shelf), _inner(uint8(3), ARC_CHAIN_SELECTOR, op, expired, payload));
    }

    function test_rejectsWrongTargetAndMalformedReports() public {
        bytes32 op = keccak256("target");
        bytes memory inner = _settleInner(op, invoiceId, 0, address(usdc), _deadline());
        vm.expectRevert(
            abi.encodeWithSelector(
                FactoringSettlementExtractor.WrongTarget.selector,
                extractor.ACTION_SETTLE(),
                address(shelf),
                address(settlement)
            )
        );
        _callOnReport(address(shelf), inner);
        assertFalse(extractor.processed(op));

        vm.expectRevert();
        vm.prank(forwarder);
        extractor.onReport("", hex"1234");

        bytes32 malformedOp = keccak256("malformed-action");
        bytes memory malformedInner =
            _inner(extractor.ACTION_SETTLE(), ARC_CHAIN_SELECTOR, malformedOp, _deadline(), hex"01");
        vm.expectRevert();
        _callOnReport(address(settlement), malformedInner);
        assertFalse(extractor.processed(malformedOp));
    }

    function test_successfulOperationCannotReplayAcrossEntryPoints() public {
        bytes32 op = keccak256("replay");
        bytes memory inner = _settleInner(op, invoiceId, 0, address(usdc), _deadline());
        vm.prank(payer);
        router.pay(invoiceId, 0, 250e6);

        _callOnReport(address(settlement), inner);
        assertTrue(extractor.processed(op));

        vm.expectRevert(abi.encodeWithSelector(FactoringSettlementExtractor.OperationAlreadyProcessed.selector, op));
        vm.prank(forwarder);
        extractor.extract(address(settlement), inner);
    }

    function test_failedTargetCallDoesNotConsumeOperationAndCanRetryBeforeExpiry() public {
        bytes32 op = keccak256("retry");
        bytes memory inner = _settleInner(op, invoiceId, 0, address(usdc), _deadline());

        vm.expectRevert(abi.encodeWithSelector(InvoiceSettlement.NothingEscrowed.selector, invoiceId));
        _callOnReport(address(settlement), inner);
        assertFalse(extractor.processed(op));

        vm.prank(payer);
        router.pay(invoiceId, 0, 250e6);
        _callOnReport(address(settlement), inner);
        assertTrue(extractor.processed(op));
    }

    // ── SETTLE ───────────────────────────────────────────────────────────────

    function test_settleDispatchDrainsEscrowAndRecordsRealizedPayment() public {
        bytes32 op = keccak256("settle-happy");
        vm.prank(payer);
        router.pay(invoiceId, 0, 250e6);

        vm.expectEmit(true, true, true, true, address(extractor));
        emit FactoringSettlementExtractor.SettlementExecuted(op, address(settlement), invoiceId);
        _callOnReport(address(settlement), _settleInner(op, invoiceId, 0, address(usdc), _deadline()));

        assertEq(escrow.escrowedOf(invoiceId), 0);
        assertEq(reputation.paidOnTimeCumulative(seller), 1);
        assertTrue(extractor.processed(op));
    }

    function test_settleCompatibilityExtractUsesSameWireAndGuards() public {
        bytes32 op = keccak256("extract-happy");
        bytes memory inner = _settleInner(op, invoiceId, 0, address(usdc), _deadline());
        vm.prank(payer);
        router.pay(invoiceId, 0, 250e6);

        vm.prank(forwarder);
        extractor.extract(address(settlement), inner);
        assertEq(escrow.escrowedOf(invoiceId), 0);
        assertTrue(extractor.processed(op));
    }

    function test_settleRejectsWrongTokenAndMemoWithoutConsumingOperation() public {
        vm.prank(payer);
        router.pay(invoiceId, 0, 250e6);

        bytes32 tokenOp = keccak256("wrong-token");
        address wrongToken = makeAddr("wrongToken");
        vm.expectRevert(
            abi.encodeWithSelector(
                FactoringSettlementExtractor.UnexpectedToken.selector,
                extractor.ACTION_SETTLE(),
                wrongToken,
                address(usdc)
            )
        );
        _callOnReport(address(settlement), _settleInner(tokenOp, invoiceId, 0, wrongToken, _deadline()));
        assertFalse(extractor.processed(tokenOp));
        assertEq(escrow.escrowedOf(invoiceId), 250e6);

        bytes32 memoOp = keccak256("wrong-memo");
        bytes32 wrongMemo = keccak256("wrong");
        bytes32 expectedMemo = _memoId(invoiceId, 0);
        bytes memory payload = abi.encode(address(usdc), invoiceId, uint8(0), wrongMemo);
        vm.expectRevert(
            abi.encodeWithSelector(FactoringSettlementExtractor.MemoIdMismatch.selector, wrongMemo, expectedMemo)
        );
        _callOnReport(address(settlement), _inner(uint8(1), ARC_CHAIN_SELECTOR, memoOp, _deadline(), payload));
        assertFalse(extractor.processed(memoOp));
        assertEq(escrow.escrowedOf(invoiceId), 250e6);
    }

    function test_settleBubblesMissingKeeperRoleAndDoesNotConsumeOperation() public {
        bytes32 op = keccak256("no-keeper");
        vm.prank(payer);
        router.pay(invoiceId, 0, 250e6);
        bytes32 keeperRole = settlement.KEEPER_ROLE();
        vm.prank(admin);
        settlement.revokeRole(keeperRole, address(extractor));

        vm.expectRevert();
        _callOnReport(address(settlement), _settleInner(op, invoiceId, 0, address(usdc), _deadline()));
        assertFalse(extractor.processed(op));
        assertEq(escrow.escrowedOf(invoiceId), 250e6);
    }

    // ── LOCK ─────────────────────────────────────────────────────────────────

    function test_lockDispatchEmitsDeskCorrelationAndPersistsDocBundle() public {
        bytes32 operationId = keccak256("desk-onchain-memo-id");
        uint256 expectedInvoiceId = shelf.nextInvoiceId();
        uint256 sellerBalanceBefore = usdc.balanceOf(sellerOwner);
        BINV.DocBundle memory docs = _lockDocs();

        vm.expectEmit(true, true, true, true, address(extractor));
        emit FactoringSettlementExtractor.InvoiceLockExecuted(operationId, address(shelf), expectedInvoiceId);
        _callOnReport(
            address(shelf),
            _lockInner(operationId, address(usdc), seller, debtor, 2, uint64(block.timestamp + 60 days), docs)
        );

        assertEq(shelf.nextInvoiceId(), expectedInvoiceId + 1);
        assertEq(uint8(shelf.invoiceStatus(expectedInvoiceId)), uint8(IInvoiceShelf.Status.Funded));
        assertEq(shelf.BINV_TOKEN().ownerOf(expectedInvoiceId), sellerOwner);
        assertEq(usdc.balanceOf(sellerOwner) - sellerBalanceBefore, 17e6);

        BINV.DocBundle memory stored = shelf.BINV_TOKEN().docBundleOf(expectedInvoiceId);
        assertEq(stored.invoiceDocHash, docs.invoiceDocHash);
        assertEq(stored.assignmentHash, docs.assignmentHash);
        assertEq(stored.paymentInstructionHash, docs.paymentInstructionHash);
        assertEq(stored.servicingPolicyHash, docs.servicingPolicyHash);
        assertEq(stored.disputePolicyHash, docs.disputePolicyHash);
        bytes32 expectedCommitment = shelf.computeReceivableCommitment(
            seller,
            debtor,
            LOCK_FACE,
            _terms(LOCK_CANONICAL_INVOICE_HASH, uint64(block.timestamp + 60 days), 2),
            docs.assignmentHash
        );
        assertEq(shelf.receivableCommitmentOf(expectedInvoiceId), expectedCommitment);
        assertEq(shelf.invoiceIdOfReceivableCommitment(expectedCommitment), expectedInvoiceId);
        FactoringEvidenceV1 memory evidence = _evidence(LOCK_CANONICAL_INVOICE_HASH);
        (bytes32 featureRootHash, bytes32 currentSnapshotHash, bytes32 privateTermsHash) =
            shelf.factoringEvidenceOf(expectedInvoiceId);
        assertEq(featureRootHash, evidence.featureRootHash);
        assertEq(currentSnapshotHash, evidence.currentSnapshotHash);
        assertEq(privateTermsHash, evidence.privateTermsHash);
        assertTrue(extractor.processed(operationId));
    }

    function test_lockReplayCannotMintOrAdvanceTwice() public {
        bytes32 op = keccak256("lock-replay");
        bytes memory inner =
            _lockInner(op, address(usdc), seller, debtor, 2, uint64(block.timestamp + 60 days), _lockDocs());
        _callOnReport(address(shelf), inner);
        uint256 nextAfterFirst = shelf.nextInvoiceId();
        uint256 sellerBalanceAfterFirst = usdc.balanceOf(sellerOwner);

        vm.expectRevert(abi.encodeWithSelector(FactoringSettlementExtractor.OperationAlreadyProcessed.selector, op));
        _callOnReport(address(shelf), inner);
        assertEq(shelf.nextInvoiceId(), nextAfterFirst);
        assertEq(usdc.balanceOf(sellerOwner), sellerBalanceAfterFirst);
    }

    function test_distinctOperationsCannotFinanceSameReceivableTwice() public {
        bytes32 opA = keccak256("lock-receivable-a");
        bytes32 opB = keccak256("lock-receivable-b");
        uint64 firstMaturity = uint64(block.timestamp + 60 days);
        BINV.DocBundle memory docsA = _lockDocs();
        _callOnReport(address(shelf), _lockInner(opA, address(usdc), seller, debtor, 2, firstMaturity, docsA));

        uint256 fundedInvoiceId = shelf.nextInvoiceId() - 1;
        uint256 nextAfterFirst = shelf.nextInvoiceId();
        uint256 sellerBalanceAfterFirst = usdc.balanceOf(sellerOwner);
        uint256 exposureAfterFirst = shelf.outstandingOf(seller);
        bytes32 commitment = shelf.receivableCommitmentOf(fundedInvoiceId);

        BINV.DocBundle memory docsB = _lockDocs();
        docsB.servicingPolicyHash = keccak256("changed-ancillary-servicing-policy");
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceShelf.ReceivableAlreadyConsumed.selector, commitment, fundedInvoiceId)
        );
        _callOnReport(address(shelf), _lockInner(opB, address(usdc), seller, debtor, 2, firstMaturity, docsB));

        assertFalse(extractor.processed(opB));
        assertEq(shelf.nextInvoiceId(), nextAfterFirst);
        assertEq(usdc.balanceOf(sellerOwner), sellerBalanceAfterFirst);
        assertEq(shelf.outstandingOf(seller), exposureAfterFirst);
        assertEq(shelf.invoiceIdOfReceivableCommitment(commitment), fundedInvoiceId);
    }

    function test_distinctOperationsCannotReuseAuthorityInvoiceWithChangedAssignment() public {
        bytes32 opA = keccak256("lock-authority-a");
        bytes32 opB = keccak256("lock-authority-b");
        uint64 firstMaturity = uint64(block.timestamp + 60 days);
        BINV.DocBundle memory docsA = _lockDocs();
        _callOnReport(address(shelf), _lockInner(opA, address(usdc), seller, debtor, 2, firstMaturity, docsA));

        uint256 fundedInvoiceId = shelf.nextInvoiceId() - 1;
        uint256 nextAfterFirst = shelf.nextInvoiceId();
        uint256 sellerBalanceAfterFirst = usdc.balanceOf(sellerOwner);
        uint256 exposureAfterFirst = shelf.outstandingOf(seller);
        bytes32 firstCommitment = shelf.receivableCommitmentOf(fundedInvoiceId);

        uint64 revisedFirstMaturity = firstMaturity + 1 days;
        BINV.DocBundle memory docsB = _lockDocs();
        docsB.assignmentHash = keccak256("changed-assignment-for-same-authority-invoice");
        FactoringEvidenceV1 memory revisedEvidence = _evidence(LOCK_CANONICAL_INVOICE_HASH);
        revisedEvidence.currentSnapshotHash = keccak256("revised-current-snapshot");
        revisedEvidence.privateTermsHash = keccak256("revised-private-terms");
        bytes32 changedCommitment = shelf.computeReceivableCommitment(
            seller,
            debtor,
            LOCK_FACE,
            _terms(LOCK_CANONICAL_INVOICE_HASH, revisedFirstMaturity, 2),
            docsB.assignmentHash
        );
        assertNotEq(changedCommitment, firstCommitment);

        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceShelf.AuthorityInvoiceAlreadyConsumed.selector,
                shelf.computeAuthorityInvoiceId(LOCK_CANONICAL_INVOICE_HASH),
                fundedInvoiceId
            )
        );
        _callOnReport(
            address(shelf),
            _lockInnerWithEvidence(opB, address(usdc), seller, debtor, 2, revisedFirstMaturity, revisedEvidence, docsB)
        );

        assertFalse(extractor.processed(opB));
        assertEq(shelf.nextInvoiceId(), nextAfterFirst);
        assertEq(usdc.balanceOf(sellerOwner), sellerBalanceAfterFirst);
        assertEq(shelf.outstandingOf(seller), exposureAfterFirst);
        assertEq(
            shelf.invoiceIdOfAuthorityInvoiceId(shelf.computeAuthorityInvoiceId(LOCK_CANONICAL_INVOICE_HASH)),
            fundedInvoiceId
        );
        assertEq(shelf.invoiceIdOfReceivableCommitment(changedCommitment), 0);
    }

    function test_lockRejectsIncompleteFactoringEvidenceWithoutConsumingOperation() public {
        bytes32 op = keccak256("lock-zero-evidence");
        uint64 firstMaturity = uint64(block.timestamp + 60 days);
        FactoringEvidenceV1 memory evidence = _evidence(LOCK_CANONICAL_INVOICE_HASH);
        evidence.currentSnapshotHash = bytes32(0);

        vm.expectRevert(InvoiceShelf.IncompleteFactoringEvidence.selector);
        _callOnReport(
            address(shelf),
            _lockInnerWithEvidence(op, address(usdc), seller, debtor, 2, firstMaturity, evidence, _lockDocs())
        );
        assertFalse(extractor.processed(op));
    }

    function test_lockRejectsWrongTokenBadScheduleAndIneligibleParty() public {
        bytes32 tokenOp = keccak256("lock-token");
        address wrongToken = makeAddr("wrongLockToken");
        vm.expectRevert(
            abi.encodeWithSelector(
                FactoringSettlementExtractor.UnexpectedToken.selector,
                extractor.ACTION_LOCK(),
                wrongToken,
                address(usdc)
            )
        );
        _callOnReport(
            address(shelf),
            _lockInner(tokenOp, wrongToken, seller, debtor, 2, uint64(block.timestamp + 60 days), _lockDocs())
        );
        assertFalse(extractor.processed(tokenOp));

        bytes32 scheduleOp = keccak256("lock-schedule");
        vm.expectRevert(InvoiceShelf.BadSchedule.selector);
        _callOnReport(
            address(shelf),
            _lockInner(scheduleOp, address(usdc), seller, debtor, 1, uint64(block.timestamp + 60 days), _lockDocs())
        );
        assertFalse(extractor.processed(scheduleOp));

        bytes32 eligibilityOp = keccak256("lock-eligibility");
        uint256 unknownAgent = 999;
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.NotEligible.selector, unknownAgent));
        _callOnReport(
            address(shelf),
            _lockInner(
                eligibilityOp, address(usdc), unknownAgent, debtor, 2, uint64(block.timestamp + 60 days), _lockDocs()
            )
        );
        assertFalse(extractor.processed(eligibilityOp));
    }

    function test_lockBubblesMissingServicerRole() public {
        bytes32 op = keccak256("no-servicer-lock");
        bytes32 servicerRole = shelf.SERVICER_ROLE();
        vm.prank(admin);
        shelf.revokeRole(servicerRole, address(extractor));

        vm.expectRevert();
        _callOnReport(
            address(shelf),
            _lockInner(op, address(usdc), seller, debtor, 2, uint64(block.timestamp + 60 days), _lockDocs())
        );
        assertFalse(extractor.processed(op));
    }

    // ── DEFAULT ──────────────────────────────────────────────────────────────

    function test_defaultDispatchAfterGraceFreezesWorkspace() public {
        bytes32 op = keccak256("default-happy");
        vm.warp(block.timestamp + 40 days);

        vm.expectEmit(true, true, true, true, address(extractor));
        emit FactoringSettlementExtractor.InvoiceDefaultExecuted(op, address(shelf), invoiceId);
        _callOnReport(address(shelf), _defaultInner(op, invoiceId, _deadline()));

        assertEq(uint8(shelf.invoiceStatus(invoiceId)), uint8(IInvoiceShelf.Status.Defaulted));
        assertTrue(shelf.workspaceFrozen(seller));
        assertTrue(extractor.processed(op));
    }

    function test_defaultRejectsBeforeGraceAndPendingEscrowWithoutConsumingOperation() public {
        bytes32 earlyOp = keccak256("default-early");
        vm.expectRevert(InvoiceShelf.NotPastGrace.selector);
        _callOnReport(address(shelf), _defaultInner(earlyOp, invoiceId, _deadline()));
        assertFalse(extractor.processed(earlyOp));

        vm.prank(payer);
        router.pay(invoiceId, 0, 250e6);
        vm.warp(block.timestamp + 40 days);
        bytes32 pendingOp = keccak256("default-pending");
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.EscrowPendingSettlement.selector, invoiceId));
        _callOnReport(address(shelf), _defaultInner(pendingOp, invoiceId, _deadline()));
        assertFalse(extractor.processed(pendingOp));
        assertEq(escrow.escrowedOf(invoiceId), 250e6);
    }

    function test_defaultBubblesMissingServicerRole() public {
        bytes32 op = keccak256("no-servicer-default");
        vm.warp(block.timestamp + 40 days);
        bytes32 servicerRole = shelf.SERVICER_ROLE();
        vm.prank(admin);
        shelf.revokeRole(servicerRole, address(extractor));

        vm.expectRevert();
        _callOnReport(address(shelf), _defaultInner(op, invoiceId, _deadline()));
        assertFalse(extractor.processed(op));
    }

    // ── Deployment linkage + least privilege ─────────────────────────────────

    function test_constructorRejectsZeroForwarderAndSelector() public {
        vm.expectRevert(FactoringSettlementExtractor.ZeroAddress.selector);
        new FactoringSettlementExtractor(
            address(this),
            address(0),
            ARC_CHAIN_SELECTOR,
            IInvoiceShelfTarget(address(shelf)),
            IInvoiceSettlementTarget(address(settlement))
        );

        vm.expectRevert(FactoringSettlementExtractor.ZeroChainSelector.selector);
        new FactoringSettlementExtractor(
            address(this),
            forwarder,
            0,
            IInvoiceShelfTarget(address(shelf)),
            IInvoiceSettlementTarget(address(settlement))
        );
    }

    function test_constructorRejectsMismatchedShelfTokenAndEscrowToken() public {
        ExtractorUSDC other = new ExtractorUSDC("Other", "OTH");
        ReceivableEscrow otherEscrow = new ReceivableEscrow(other, admin);
        InvoiceSettlement wrongSettlementToken =
            new InvoiceSettlement(other, IInvoiceShelf(address(shelf)), otherEscrow, admin);

        vm.expectRevert(
            abi.encodeWithSelector(
                FactoringSettlementExtractor.UnexpectedToken.selector, uint8(1), address(other), address(usdc)
            )
        );
        new FactoringSettlementExtractor(
            address(this),
            forwarder,
            ARC_CHAIN_SELECTOR,
            IInvoiceShelfTarget(address(shelf)),
            IInvoiceSettlementTarget(address(wrongSettlementToken))
        );

        InvoiceSettlement wrongEscrowToken =
            new InvoiceSettlement(usdc, IInvoiceShelf(address(shelf)), otherEscrow, admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                FactoringSettlementExtractor.SettlementEscrowTokenMismatch.selector, address(other), address(usdc)
            )
        );
        new FactoringSettlementExtractor(
            address(this),
            forwarder,
            ARC_CHAIN_SELECTOR,
            IInvoiceShelfTarget(address(shelf)),
            IInvoiceSettlementTarget(address(wrongEscrowToken))
        );
    }

    function test_constructorRejectsSettlementLinkedToDifferentShelf() public {
        ExtractorShelfLinkMock otherShelf = new ExtractorShelfLinkMock(address(usdc));
        vm.expectRevert(
            abi.encodeWithSelector(
                FactoringSettlementExtractor.SettlementShelfMismatch.selector, address(shelf), address(otherShelf)
            )
        );
        new FactoringSettlementExtractor(
            address(this),
            forwarder,
            ARC_CHAIN_SELECTOR,
            IInvoiceShelfTarget(address(otherShelf)),
            IInvoiceSettlementTarget(address(settlement))
        );
    }

    function test_rolesAreLeastPrivilege() public view {
        assertTrue(settlement.hasRole(settlement.KEEPER_ROLE(), address(extractor)));
        assertTrue(shelf.hasRole(shelf.SERVICER_ROLE(), address(extractor)));
        assertFalse(shelf.hasRole(shelf.SETTLEMENT_ROLE(), address(extractor)));
        assertFalse(escrow.hasRole(escrow.SETTLEMENT_ROLE(), address(extractor)));
        assertTrue(shelf.hasRole(shelf.SETTLEMENT_ROLE(), address(settlement)));
        assertTrue(escrow.hasRole(escrow.SETTLEMENT_ROLE(), address(settlement)));
    }

    function testFuzz_nonForwarderCannotConsumeOperation(address caller, bytes32 operationId) public {
        vm.assume(caller != forwarder);
        vm.assume(caller != address(0));
        if (operationId == bytes32(0)) operationId = bytes32(uint256(1));
        bytes memory inner = _defaultInner(operationId, invoiceId, _deadline());

        vm.expectRevert(abi.encodeWithSelector(FactoringSettlementExtractor.NotForwarder.selector, caller));
        vm.prank(caller);
        extractor.extract(address(shelf), inner);
        assertFalse(extractor.processed(operationId));
    }

    function testFuzz_wrongSelectorNeverConsumesOperation(uint64 selector) public {
        vm.assume(selector != ARC_CHAIN_SELECTOR);
        bytes32 operationId = keccak256(abi.encode("selector", selector));
        bytes memory inner =
            _inner(extractor.ACTION_DEFAULT(), selector, operationId, _deadline(), abi.encode(invoiceId));

        vm.expectRevert(
            abi.encodeWithSelector(
                FactoringSettlementExtractor.WrongChainSelector.selector, selector, ARC_CHAIN_SELECTOR
            )
        );
        _callOnReport(address(shelf), inner);
        assertFalse(extractor.processed(operationId));
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _workspace(string memory tag, address owner_, uint8 sellerScore, uint8 debtorScore)
        internal
        returns (uint256 id)
    {
        vm.startPrank(issuer);
        id = identity.registerWorkspace(keccak256(bytes(tag)), owner_);
        identity.setKybStatus(id, true);
        vm.stopPrank();
        vm.prank(attestor);
        reputation.setScore(id, sellerScore, debtorScore, 1, keccak256(bytes(tag)));
    }

    function _docs() internal pure returns (BINV.DocBundle memory) {
        return BINV.DocBundle({
            invoiceDocHash: keccak256("seed-invoice"),
            assignmentHash: keccak256("seed-assignment"),
            paymentInstructionHash: keccak256("seed-payment"),
            servicingPolicyHash: keccak256("seed-servicing"),
            disputePolicyHash: keccak256("seed-dispute")
        });
    }

    function _lockDocs() internal pure returns (BINV.DocBundle memory) {
        return BINV.DocBundle({
            invoiceDocHash: keccak256("lock-invoice"),
            assignmentHash: keccak256("lock-assignment"),
            paymentInstructionHash: keccak256("lock-payment"),
            servicingPolicyHash: keccak256("lock-servicing"),
            disputePolicyHash: keccak256("lock-dispute")
        });
    }

    function _deadline() internal view returns (uint64) {
        return uint64(block.timestamp + 1 days);
    }

    function _memoId(uint256 id, uint8 installment) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(id, installment));
    }

    function _inner(uint8 action, uint64 selector, bytes32 operationId, uint64 validUntil, bytes memory payload)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(action, selector, operationId, validUntil, payload);
    }

    function _outer(address target, bytes memory inner) internal pure returns (bytes memory) {
        return abi.encode(target, inner);
    }

    function _settleInner(bytes32 operationId, uint256 id, uint8 installment, address token, uint64 validUntil)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            uint8(1),
            ARC_CHAIN_SELECTOR,
            operationId,
            validUntil,
            abi.encode(token, id, installment, _memoId(id, installment))
        );
    }

    function _lockInner(
        bytes32 operationId,
        address token,
        uint256 sellerAgentId,
        uint256 debtorAgentId,
        uint8 nInstallments,
        uint64 firstMaturity,
        BINV.DocBundle memory docs
    ) internal view returns (bytes memory) {
        return _lockInnerWithEvidence(
            operationId,
            token,
            sellerAgentId,
            debtorAgentId,
            nInstallments,
            firstMaturity,
            _evidence(LOCK_CANONICAL_INVOICE_HASH),
            docs
        );
    }

    function _lockInnerWithEvidence(
        bytes32 operationId,
        address token,
        uint256 sellerAgentId,
        uint256 debtorAgentId,
        uint8 nInstallments,
        uint64 firstMaturity,
        FactoringEvidenceV1 memory evidence,
        BINV.DocBundle memory docs
    ) internal view returns (bytes memory) {
        bytes memory payload = abi.encode(
            token,
            sellerAgentId,
            debtorAgentId,
            LOCK_FACE,
            nInstallments,
            firstMaturity,
            uint32(30 days),
            _terms(LOCK_CANONICAL_INVOICE_HASH, firstMaturity, nInstallments),
            evidence,
            docs
        );
        return _inner(uint8(2), ARC_CHAIN_SELECTOR, operationId, _deadline(), payload);
    }

    function _terms(bytes32 authorityId, uint64 firstMaturity, uint8 nInstallments)
        internal
        view
        returns (ReceivableCommitment.Terms memory)
    {
        return ReceivableCommitment.Terms({
            canonicalInvoiceCommitmentHash: authorityId,
            issuedAt: uint64(block.timestamp),
            dueAt: uint64(uint256(firstMaturity) + uint256(nInstallments - 1) * 30 days)
        });
    }

    function _evidence(bytes32 seed) internal pure returns (FactoringEvidenceV1 memory) {
        return FactoringEvidenceV1({
            featureRootHash: keccak256(abi.encode("FEATURE_ROOT", seed)),
            currentSnapshotHash: keccak256(abi.encode("CURRENT_SNAPSHOT", seed)),
            privateTermsHash: keccak256(abi.encode("PRIVATE_TERMS", seed))
        });
    }

    function _defaultInner(bytes32 operationId, uint256 id, uint64 validUntil) internal pure returns (bytes memory) {
        return abi.encode(uint8(3), ARC_CHAIN_SELECTOR, operationId, validUntil, abi.encode(id));
    }

    function _callOnReport(address target, bytes memory inner) internal {
        vm.prank(forwarder);
        extractor.onReport("", _outer(target, inner));
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

import {BUFIIdentityRegistry} from "../../src/identity/BUFIIdentityRegistry.sol";
import {DocumentReceivableRegistry} from "../../src/invoice/DocumentReceivableRegistry.sol";
import {IDocumentReceivableRegistry} from "../../src/interfaces/IDocumentReceivableRegistry.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Minimal mocks for no-value / token-rejection tests
// ─────────────────────────────────────────────────────────────────────────────

contract MockERC721 is ERC721 {
    constructor() ERC721("Mock", "MCK") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

contract MockERC1155 is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

/// @notice Shared test fixture: deploys a real BUFIIdentityRegistry, registers one
///         workspace so tests have a valid creditor agent id, then deploys the
///         DocumentReceivableRegistry.
abstract contract DocumentReceivableBase is Test {
    // ── role constants (keccak256 matches contract + OZ) ─────────────────────
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 internal constant WRITER_ROLE = keccak256("WRITER_ROLE");

    // ── actors ────────────────────────────────────────────────────────────────
    address internal admin = makeAddr("admin");
    address internal writer = makeAddr("writer");
    address internal stranger = makeAddr("stranger");

    // ── contracts ─────────────────────────────────────────────────────────────
    BUFIIdentityRegistry internal identity;
    DocumentReceivableRegistry internal registry;

    // ── fixture data ──────────────────────────────────────────────────────────
    uint256 internal creditorAgentId;

    bytes32 internal constant WS_ID = keccak256("workspace-1");
    bytes32 internal constant DOC = keccak256("doc-1");
    bytes32 internal constant DEBTOR = keccak256("debtor-1");
    bytes32 internal constant UNIT = keccak256("USDC");
    bytes32 internal constant TERMS = keccak256("terms-v1");
    bytes32 internal constant DEST = keccak256("destination-1");
    bytes32 internal constant EVIDENCE_1 = keccak256("evidence-1");
    bytes32 internal constant EVIDENCE_2 = keccak256("evidence-2");
    bytes32 internal constant EVIDENCE_3 = keccak256("evidence-3");
    bytes32 internal constant LEGS = keccak256("legs-root-1");
    bytes32 internal constant REASON = keccak256("reason-1");
    bytes32 internal constant AUTH = keccak256("auth-1");

    uint64 internal constant ISSUED_AT = 1_700_000_000;
    uint64 internal constant DUE_AT = 1_700_000_000 + 30 days;
    uint128 internal constant PRINCIPAL = 1_000e6;

    function setUp() public virtual {
        // Deploy and wire identity registry
        address identityAdmin = makeAddr("identityAdmin");
        identity = new BUFIIdentityRegistry(identityAdmin);

        // Register a workspace so creditorAgentId is valid
        vm.prank(identityAdmin);
        identity.grantRole(keccak256("ISSUER_ROLE"), identityAdmin);

        vm.prank(identityAdmin);
        creditorAgentId = identity.registerWorkspace(WS_ID, identityAdmin);

        // Deploy the registry under test
        registry = new DocumentReceivableRegistry(admin, address(identity));

        // Grant writer role
        vm.prank(admin);
        registry.grantRole(WRITER_ROLE, writer);

        // Warp past issuedAt so block.timestamp > ISSUED_AT
        vm.warp(ISSUED_AT + 1);
    }

    /// @dev Returns a default valid RegisterArgs.
    function _defaultArgs() internal view returns (IDocumentReceivableRegistry.RegisterArgs memory) {
        return IDocumentReceivableRegistry.RegisterArgs({
            documentCommitment: DOC,
            creditorAgentId: creditorAgentId,
            debtorCommitment: DEBTOR,
            principal: PRINCIPAL,
            unit: UNIT,
            issuedAt: ISSUED_AT,
            dueAt: DUE_AT,
            installments: 3,
            termsHash: TERMS,
            destinationDigest: DEST
        });
    }

    /// @dev Registers the default receivable and returns its id.
    function _register() internal returns (uint256 id) {
        vm.prank(writer);
        id = registry.register(_defaultArgs());
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Constructor tests
// ─────────────────────────────────────────────────────────────────────────────
contract DocumentReceivableRegistry_Constructor is DocumentReceivableBase {
    function test_constructor_setsIdentity() public view {
        assertEq(address(registry.IDENTITY()), address(identity));
    }

    function test_constructor_grantsAdminRole() public view {
        assertTrue(registry.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_constructor_doesNotGrantWriterToAdmin() public view {
        assertFalse(registry.hasRole(WRITER_ROLE, admin));
    }

    function test_constructor_revert_zeroAdmin() public {
        vm.expectRevert(IDocumentReceivableRegistry.ZeroAddress.selector);
        new DocumentReceivableRegistry(address(0), address(identity));
    }

    function test_constructor_revert_zeroIdentity() public {
        vm.expectRevert(IDocumentReceivableRegistry.ZeroAddress.selector);
        new DocumentReceivableRegistry(admin, address(0));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pause / unpause
// ─────────────────────────────────────────────────────────────────────────────
contract DocumentReceivableRegistry_Pause is DocumentReceivableBase {
    function test_pause_onlyAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE
            )
        );
        registry.pause();
    }

    function test_unpause_onlyAdmin() public {
        vm.prank(admin);
        registry.pause();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE
            )
        );
        registry.unpause();
    }

    function test_pause_blocksAllWrites() public {
        vm.prank(admin);
        registry.pause();

        // register
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        registry.register(_defaultArgs());

        // recordPayment — need a registered id first, so use a fresh instance
        DocumentReceivableRegistry reg2 = new DocumentReceivableRegistry(admin, address(identity));
        vm.prank(admin);
        reg2.grantRole(WRITER_ROLE, writer);
        vm.prank(writer);
        uint256 id = reg2.register(_defaultArgs());

        vm.prank(admin);
        reg2.pause();

        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        reg2.recordPayment(id, 1, 100, EVIDENCE_1, LEGS);

        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        reg2.recordReversal(id, EVIDENCE_1, 50, REASON);

        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        reg2.amendTerms(id, keccak256("terms-v2"), 2, AUTH);
    }

    function test_unpause_restoresWrites() public {
        vm.prank(admin);
        registry.pause();

        vm.prank(admin);
        registry.unpause();

        vm.prank(writer);
        uint256 id = registry.register(_defaultArgs());
        assertEq(id, 1);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// register()
// ─────────────────────────────────────────────────────────────────────────────
contract DocumentReceivableRegistry_Register is DocumentReceivableBase {
    // ── Access control ────────────────────────────────────────────────────────

    function test_register_revert_nonWriter() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, WRITER_ROLE)
        );
        registry.register(_defaultArgs());
    }

    function test_register_revert_adminWithoutWriterRole() public {
        // admin has DEFAULT_ADMIN_ROLE but not WRITER_ROLE
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, WRITER_ROLE)
        );
        registry.register(_defaultArgs());
    }

    // ── Zero-field reverts ────────────────────────────────────────────────────

    function test_register_revert_zeroDocumentCommitment() public {
        IDocumentReceivableRegistry.RegisterArgs memory a = _defaultArgs();
        a.documentCommitment = bytes32(0);
        vm.prank(writer);
        vm.expectRevert(IDocumentReceivableRegistry.ZeroCommitment.selector);
        registry.register(a);
    }

    function test_register_revert_unknownCreditor() public {
        IDocumentReceivableRegistry.RegisterArgs memory a = _defaultArgs();
        a.creditorAgentId = 9999;
        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(IDocumentReceivableRegistry.UnknownCreditorAgent.selector, uint256(9999))
        );
        registry.register(a);
    }

    function test_register_revert_zeroDebtorCommitment() public {
        IDocumentReceivableRegistry.RegisterArgs memory a = _defaultArgs();
        a.debtorCommitment = bytes32(0);
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.ZeroField.selector, uint8(0)));
        registry.register(a);
    }

    function test_register_revert_zeroUnit() public {
        IDocumentReceivableRegistry.RegisterArgs memory a = _defaultArgs();
        a.unit = bytes32(0);
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.ZeroField.selector, uint8(1)));
        registry.register(a);
    }

    function test_register_revert_zeroTermsHash() public {
        IDocumentReceivableRegistry.RegisterArgs memory a = _defaultArgs();
        a.termsHash = bytes32(0);
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.ZeroField.selector, uint8(2)));
        registry.register(a);
    }

    function test_register_revert_zeroDestinationDigest() public {
        IDocumentReceivableRegistry.RegisterArgs memory a = _defaultArgs();
        a.destinationDigest = bytes32(0);
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.ZeroField.selector, uint8(3)));
        registry.register(a);
    }

    function test_register_revert_zeroPrincipal() public {
        IDocumentReceivableRegistry.RegisterArgs memory a = _defaultArgs();
        a.principal = 0;
        vm.prank(writer);
        vm.expectRevert(IDocumentReceivableRegistry.ZeroPrincipal.selector);
        registry.register(a);
    }

    function test_register_revert_zeroInstallments() public {
        IDocumentReceivableRegistry.RegisterArgs memory a = _defaultArgs();
        a.installments = 0;
        vm.prank(writer);
        vm.expectRevert(IDocumentReceivableRegistry.ZeroInstallments.selector);
        registry.register(a);
    }

    function test_register_revert_zeroIssuedAt() public {
        IDocumentReceivableRegistry.RegisterArgs memory a = _defaultArgs();
        a.issuedAt = 0;
        vm.prank(writer);
        vm.expectRevert(IDocumentReceivableRegistry.InvalidIssuedAt.selector);
        registry.register(a);
    }

    function test_register_revert_issuedAtInFuture() public {
        IDocumentReceivableRegistry.RegisterArgs memory a = _defaultArgs();
        a.issuedAt = uint64(block.timestamp) + 100;
        a.dueAt = uint64(block.timestamp) + 200;
        vm.prank(writer);
        vm.expectRevert(IDocumentReceivableRegistry.InvalidIssuedAt.selector);
        registry.register(a);
    }

    function test_register_revert_dueAtEqualIssuedAt() public {
        IDocumentReceivableRegistry.RegisterArgs memory a = _defaultArgs();
        a.dueAt = a.issuedAt;
        vm.prank(writer);
        vm.expectRevert(IDocumentReceivableRegistry.InvalidDueAt.selector);
        registry.register(a);
    }

    function test_register_revert_dueAtBeforeIssuedAt() public {
        IDocumentReceivableRegistry.RegisterArgs memory a = _defaultArgs();
        a.dueAt = a.issuedAt - 1;
        vm.prank(writer);
        vm.expectRevert(IDocumentReceivableRegistry.InvalidDueAt.selector);
        registry.register(a);
    }

    // ── Duplicate ─────────────────────────────────────────────────────────────

    function test_register_revert_duplicateCommitment() public {
        vm.prank(writer);
        uint256 firstId = registry.register(_defaultArgs());

        IDocumentReceivableRegistry.RegisterArgs memory a = _defaultArgs();
        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(IDocumentReceivableRegistry.DocumentAlreadyRegistered.selector, DOC, firstId)
        );
        registry.register(a);
    }

    // ── Happy path ────────────────────────────────────────────────────────────

    function test_register_sequentialIds() public {
        IDocumentReceivableRegistry.RegisterArgs memory a1 = _defaultArgs();
        IDocumentReceivableRegistry.RegisterArgs memory a2 = _defaultArgs();
        a2.documentCommitment = keccak256("doc-2");

        vm.prank(writer);
        uint256 id1 = registry.register(a1);
        vm.prank(writer);
        uint256 id2 = registry.register(a2);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(registry.nextReceivableId(), 3);
    }

    function test_register_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IDocumentReceivableRegistry.ReceivableRegistered(1, DOC, creditorAgentId, PRINCIPAL, UNIT, DUE_AT, TERMS);
        _register();
    }

    function test_register_storesCorrectFields() public {
        uint256 id = _register();
        IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);
        assertEq(r.documentCommitment, DOC);
        assertEq(r.creditorAgentId, creditorAgentId);
        assertEq(r.debtorCommitment, DEBTOR);
        assertEq(r.unit, UNIT);
        assertEq(r.termsHash, TERMS);
        assertEq(r.destinationDigest, DEST);
        assertEq(r.principal, PRINCIPAL);
        assertEq(r.paidUnits, 0);
        assertEq(r.issuedAt, ISSUED_AT);
        assertEq(r.dueAt, DUE_AT);
        assertEq(r.registeredAt, block.timestamp);
        assertEq(r.termsVersion, 1);
        assertEq(r.installments, 3);
        assertEq(uint8(r.status), uint8(IDocumentReceivableRegistry.Status.Open));
    }

    function test_register_storesTermsHashAtVersion1() public {
        uint256 id = _register();
        assertEq(registry.termsHashAt(id, 1), TERMS);
    }

    function test_register_idOfCommitmentRoundTrip() public {
        uint256 id = _register();
        assertEq(registry.idOfCommitment(DOC), id);
    }

    function test_register_unknownIdReturnsZeroStruct() public view {
        IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(999);
        assertEq(uint8(r.status), uint8(IDocumentReceivableRegistry.Status.None));
        assertEq(r.principal, 0);
    }

    function test_register_issuedAtEqualsBlockTimestampOk() public {
        IDocumentReceivableRegistry.RegisterArgs memory a = _defaultArgs();
        a.issuedAt = uint64(block.timestamp);
        vm.prank(writer);
        uint256 id = registry.register(a);
        assertEq(id, 1);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// recordPayment()
// ─────────────────────────────────────────────────────────────────────────────
contract DocumentReceivableRegistry_RecordPayment is DocumentReceivableBase {
    uint256 internal _id;

    function setUp() public override {
        super.setUp();
        _id = _register();
    }

    // ── Access control ────────────────────────────────────────────────────────

    function test_recordPayment_revert_nonWriter() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, WRITER_ROLE)
        );
        registry.recordPayment(_id, 1, 100, EVIDENCE_1, LEGS);
    }

    // ── Revert paths ──────────────────────────────────────────────────────────

    function test_recordPayment_revert_unknownId() public {
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.UnknownReceivable.selector, uint256(0)));
        registry.recordPayment(0, 1, 100, EVIDENCE_1, LEGS);

        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.UnknownReceivable.selector, uint256(999)));
        registry.recordPayment(999, 1, 100, EVIDENCE_1, LEGS);
    }

    function test_recordPayment_revert_installmentZero() public {
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.InvalidInstallment.selector, uint8(0)));
        registry.recordPayment(_id, 0, 100, EVIDENCE_1, LEGS);
    }

    function test_recordPayment_revert_installmentExceeds() public {
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.InvalidInstallment.selector, uint8(4)));
        registry.recordPayment(_id, 4, 100, EVIDENCE_1, LEGS); // installments==3
    }

    function test_recordPayment_revert_zeroUnits() public {
        vm.prank(writer);
        vm.expectRevert(IDocumentReceivableRegistry.ZeroUnits.selector);
        registry.recordPayment(_id, 1, 0, EVIDENCE_1, LEGS);
    }

    function test_recordPayment_revert_zeroEvidence() public {
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.ZeroField.selector, uint8(4)));
        registry.recordPayment(_id, 1, 100, bytes32(0), LEGS);
    }

    function test_recordPayment_revert_zeroLegsRoot() public {
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.ZeroField.selector, uint8(5)));
        registry.recordPayment(_id, 1, 100, EVIDENCE_1, bytes32(0));
    }

    function test_recordPayment_revert_evidenceAlreadyUsed_sameId() public {
        vm.prank(writer);
        registry.recordPayment(_id, 1, 100, EVIDENCE_1, LEGS);

        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.EvidenceAlreadyUsed.selector, EVIDENCE_1));
        registry.recordPayment(_id, 2, 100, EVIDENCE_1, LEGS);
    }

    function test_recordPayment_revert_evidenceAlreadyUsed_differentId() public {
        // Register a second receivable
        IDocumentReceivableRegistry.RegisterArgs memory a2 = _defaultArgs();
        a2.documentCommitment = keccak256("doc-2");
        vm.prank(writer);
        uint256 id2 = registry.register(a2);

        vm.prank(writer);
        registry.recordPayment(_id, 1, 100, EVIDENCE_1, LEGS);

        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.EvidenceAlreadyUsed.selector, EVIDENCE_1));
        registry.recordPayment(id2, 1, 100, EVIDENCE_1, LEGS);
    }

    function test_recordPayment_revert_overpayment() public {
        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDocumentReceivableRegistry.Overpayment.selector, _id, PRINCIPAL, uint128(0), PRINCIPAL + 1
            )
        );
        registry.recordPayment(_id, 1, PRINCIPAL + 1, EVIDENCE_1, LEGS);
    }

    function test_recordPayment_revert_overpayment_uint128Max() public {
        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDocumentReceivableRegistry.Overpayment.selector, _id, PRINCIPAL, uint128(0), type(uint128).max
            )
        );
        registry.recordPayment(_id, 1, type(uint128).max, EVIDENCE_1, LEGS);
    }

    // ── Happy path ────────────────────────────────────────────────────────────

    function test_recordPayment_partialPayment_statusPartiallyPaid() public {
        vm.prank(writer);
        registry.recordPayment(_id, 1, PRINCIPAL / 2, EVIDENCE_1, LEGS);

        IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(_id);
        assertEq(r.paidUnits, PRINCIPAL / 2);
        assertEq(r.grossAppliedUnits, PRINCIPAL / 2);
        assertEq(uint8(r.status), uint8(IDocumentReceivableRegistry.Status.PartiallyPaid));
    }

    function test_recordPayment_exactPayment_statusPaid() public {
        vm.prank(writer);
        registry.recordPayment(_id, 1, PRINCIPAL, EVIDENCE_1, LEGS);

        IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(_id);
        assertEq(r.paidUnits, PRINCIPAL);
        assertEq(uint8(r.status), uint8(IDocumentReceivableRegistry.Status.Paid));
    }

    function test_recordPayment_multiplePartialPayments() public {
        uint128 p1 = 300e6;
        uint128 p2 = 400e6;
        uint128 p3 = 300e6;

        vm.prank(writer);
        registry.recordPayment(_id, 1, p1, EVIDENCE_1, LEGS);
        vm.prank(writer);
        registry.recordPayment(_id, 2, p2, EVIDENCE_2, LEGS);
        vm.prank(writer);
        registry.recordPayment(_id, 3, p3, EVIDENCE_3, LEGS);

        IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(_id);
        assertEq(r.paidUnits, p1 + p2 + p3);
        assertEq(r.grossAppliedUnits, p1 + p2 + p3);
        assertEq(uint8(r.status), uint8(IDocumentReceivableRegistry.Status.Paid));
    }

    function test_recordPayment_emitsEvent() public {
        vm.expectEmit(true, false, true, true);
        emit IDocumentReceivableRegistry.PaymentRecorded(_id, 1, 100, 100, EVIDENCE_1, LEGS);
        vm.prank(writer);
        registry.recordPayment(_id, 1, 100, EVIDENCE_1, LEGS);
    }

    function test_recordPayment_updatesEvidenceUsed() public {
        assertFalse(registry.evidenceUsed(EVIDENCE_1));
        vm.prank(writer);
        registry.recordPayment(_id, 1, 100, EVIDENCE_1, LEGS);
        assertTrue(registry.evidenceUsed(EVIDENCE_1));
    }

    function test_recordPayment_paymentOf() public {
        vm.prank(writer);
        registry.recordPayment(_id, 1, 400e6, EVIDENCE_1, LEGS);

        (uint256 rid, uint128 applied, uint128 reversed) = registry.paymentOf(EVIDENCE_1);
        assertEq(rid, _id);
        assertEq(applied, 400e6);
        assertEq(reversed, 0);
    }

    function test_recordPayment_outstandingUnits() public {
        vm.prank(writer);
        registry.recordPayment(_id, 1, 400e6, EVIDENCE_1, LEGS);
        assertEq(registry.outstandingUnits(_id), PRINCIPAL - 400e6);
    }

    function test_recordPayment_outstandingUnits_unknownId() public view {
        assertEq(registry.outstandingUnits(999), 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// recordReversal()
// ─────────────────────────────────────────────────────────────────────────────
contract DocumentReceivableRegistry_RecordReversal is DocumentReceivableBase {
    uint256 internal _id;
    uint128 internal constant PAY_AMOUNT = 600e6;

    function setUp() public override {
        super.setUp();
        _id = _register();
        vm.prank(writer);
        registry.recordPayment(_id, 1, PAY_AMOUNT, EVIDENCE_1, LEGS);
    }

    // ── Access control ────────────────────────────────────────────────────────

    function test_recordReversal_revert_nonWriter() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, WRITER_ROLE)
        );
        registry.recordReversal(_id, EVIDENCE_1, 100, REASON);
    }

    // ── Revert paths ──────────────────────────────────────────────────────────

    function test_recordReversal_revert_unknownId() public {
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.UnknownReceivable.selector, uint256(999)));
        registry.recordReversal(999, EVIDENCE_1, 100, REASON);
    }

    function test_recordReversal_revert_zeroUnits() public {
        vm.prank(writer);
        vm.expectRevert(IDocumentReceivableRegistry.ZeroUnits.selector);
        registry.recordReversal(_id, EVIDENCE_1, 0, REASON);
    }

    function test_recordReversal_revert_zeroReasonHash() public {
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.ZeroField.selector, uint8(6)));
        registry.recordReversal(_id, EVIDENCE_1, 100, bytes32(0));
    }

    function test_recordReversal_revert_unknownEvidence() public {
        bytes32 bad = keccak256("not-a-payment");
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.UnknownEvidence.selector, bad));
        registry.recordReversal(_id, bad, 100, REASON);
    }

    function test_recordReversal_revert_evidenceBelongsToOtherId() public {
        // Register a second receivable and pay it with EVIDENCE_2
        IDocumentReceivableRegistry.RegisterArgs memory a2 = _defaultArgs();
        a2.documentCommitment = keccak256("doc-2");
        vm.prank(writer);
        uint256 id2 = registry.register(a2);
        vm.prank(writer);
        registry.recordPayment(id2, 1, 100, EVIDENCE_2, LEGS);

        // Try to reverse EVIDENCE_2 against _id (not id2)
        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDocumentReceivableRegistry.EvidenceReceivableMismatch.selector, EVIDENCE_2, _id, id2
            )
        );
        registry.recordReversal(_id, EVIDENCE_2, 100, REASON);
    }

    function test_recordReversal_revert_exceedsApplied() public {
        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDocumentReceivableRegistry.ReversalExceedsPayment.selector,
                EVIDENCE_1,
                PAY_AMOUNT,
                uint128(0),
                PAY_AMOUNT + 1
            )
        );
        registry.recordReversal(_id, EVIDENCE_1, PAY_AMOUNT + 1, REASON);
    }

    function test_recordReversal_revert_uint128Max() public {
        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDocumentReceivableRegistry.ReversalExceedsPayment.selector,
                EVIDENCE_1,
                PAY_AMOUNT,
                uint128(0),
                type(uint128).max
            )
        );
        registry.recordReversal(_id, EVIDENCE_1, type(uint128).max, REASON);
    }

    function test_recordReversal_revert_cumulativeExceedsApplied() public {
        // Partial reverse, then try to exceed remaining
        vm.prank(writer);
        registry.recordReversal(_id, EVIDENCE_1, 300e6, REASON);

        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDocumentReceivableRegistry.ReversalExceedsPayment.selector,
                EVIDENCE_1,
                PAY_AMOUNT,
                uint128(300e6),
                PAY_AMOUNT - 300e6 + 1
            )
        );
        registry.recordReversal(_id, EVIDENCE_1, PAY_AMOUNT - 300e6 + 1, REASON);
    }

    // ── Happy path ────────────────────────────────────────────────────────────

    function test_recordReversal_partialReversal() public {
        vm.prank(writer);
        registry.recordReversal(_id, EVIDENCE_1, 200e6, REASON);

        IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(_id);
        assertEq(r.paidUnits, PAY_AMOUNT - 200e6);
        assertEq(r.reversedUnits, 200e6);
        assertEq(r.grossAppliedUnits, PAY_AMOUNT); // unchanged
    }

    function test_recordReversal_fullReversal_statusOpen() public {
        vm.prank(writer);
        registry.recordReversal(_id, EVIDENCE_1, PAY_AMOUNT, REASON);

        IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(_id);
        assertEq(r.paidUnits, 0);
        assertEq(uint8(r.status), uint8(IDocumentReceivableRegistry.Status.Open));
    }

    function test_recordReversal_paidToPartiallyPaidToOpen() public {
        // Pay in full
        vm.prank(writer);
        registry.recordPayment(_id, 2, PRINCIPAL - PAY_AMOUNT, EVIDENCE_2, LEGS);
        assertEq(uint8(registry.receivableOf(_id).status), uint8(IDocumentReceivableRegistry.Status.Paid));

        // Partial reversal → PartiallyPaid
        vm.prank(writer);
        registry.recordReversal(_id, EVIDENCE_1, 1, REASON);
        assertEq(uint8(registry.receivableOf(_id).status), uint8(IDocumentReceivableRegistry.Status.PartiallyPaid));

        // Full reversal of first payment → Open
        vm.prank(writer);
        registry.recordReversal(_id, EVIDENCE_1, PAY_AMOUNT - 1, keccak256("reason-2"));
        // paidUnits is now just the second payment = PRINCIPAL - PAY_AMOUNT < PRINCIPAL → PartiallyPaid
        assertEq(uint8(registry.receivableOf(_id).status), uint8(IDocumentReceivableRegistry.Status.PartiallyPaid));

        // Now reverse the second payment
        vm.prank(writer);
        registry.recordReversal(_id, EVIDENCE_2, PRINCIPAL - PAY_AMOUNT, keccak256("reason-3"));
        assertEq(uint8(registry.receivableOf(_id).status), uint8(IDocumentReceivableRegistry.Status.Open));
    }

    function test_recordReversal_evidenceStillUsedAfterFullReversal() public {
        vm.prank(writer);
        registry.recordReversal(_id, EVIDENCE_1, PAY_AMOUNT, REASON);
        // Evidence is still "used" — cannot be re-recorded
        assertTrue(registry.evidenceUsed(EVIDENCE_1));
    }

    function test_recordReversal_payAgainAfterFullReversal() public {
        vm.prank(writer);
        registry.recordReversal(_id, EVIDENCE_1, PAY_AMOUNT, REASON);

        // Use a DIFFERENT evidence (original cannot be reused)
        vm.prank(writer);
        registry.recordPayment(_id, 1, PRINCIPAL, EVIDENCE_2, LEGS);

        IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(_id);
        // grossApplied = PAY_AMOUNT + PRINCIPAL; paidUnits = PRINCIPAL (net)
        assertEq(r.grossAppliedUnits, PAY_AMOUNT + PRINCIPAL);
        assertEq(r.paidUnits, PRINCIPAL);
        assertEq(uint8(r.status), uint8(IDocumentReceivableRegistry.Status.Paid));
    }

    function test_recordReversal_emitsEvent() public {
        uint128 paidAfter = PAY_AMOUNT - 100;
        vm.expectEmit(true, true, false, true);
        emit IDocumentReceivableRegistry.ReversalRecorded(_id, EVIDENCE_1, 100, paidAfter, REASON);
        vm.prank(writer);
        registry.recordReversal(_id, EVIDENCE_1, 100, REASON);
    }

    function test_recordReversal_updatesPaymentOf() public {
        vm.prank(writer);
        registry.recordReversal(_id, EVIDENCE_1, 200e6, REASON);

        (, uint128 applied, uint128 reversed) = registry.paymentOf(EVIDENCE_1);
        assertEq(applied, PAY_AMOUNT);
        assertEq(reversed, 200e6);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// amendTerms()
// ─────────────────────────────────────────────────────────────────────────────
contract DocumentReceivableRegistry_AmendTerms is DocumentReceivableBase {
    uint256 internal _id;
    bytes32 internal constant TERMS_V2 = keccak256("terms-v2");
    bytes32 internal constant TERMS_V3 = keccak256("terms-v3");

    function setUp() public override {
        super.setUp();
        _id = _register();
    }

    // ── Access control ────────────────────────────────────────────────────────

    function test_amendTerms_revert_nonWriter() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, WRITER_ROLE)
        );
        registry.amendTerms(_id, TERMS_V2, 2, AUTH);
    }

    // ── Revert paths ──────────────────────────────────────────────────────────

    function test_amendTerms_revert_unknownId() public {
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.UnknownReceivable.selector, uint256(999)));
        registry.amendTerms(999, TERMS_V2, 2, AUTH);
    }

    function test_amendTerms_revert_alreadyPaid() public {
        vm.prank(writer);
        registry.recordPayment(_id, 1, PRINCIPAL, EVIDENCE_1, LEGS);

        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.ReceivableAlreadyPaid.selector, _id));
        registry.amendTerms(_id, TERMS_V2, 2, AUTH);
    }

    function test_amendTerms_revert_wrongVersion() public {
        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(IDocumentReceivableRegistry.InvalidTermsVersion.selector, uint32(2), uint32(3))
        );
        registry.amendTerms(_id, TERMS_V2, 3, AUTH);
    }

    function test_amendTerms_revert_wrongVersionTooLow() public {
        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(IDocumentReceivableRegistry.InvalidTermsVersion.selector, uint32(2), uint32(1))
        );
        registry.amendTerms(_id, TERMS_V2, 1, AUTH);
    }

    function test_amendTerms_revert_zeroTermsHash() public {
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.ZeroField.selector, uint8(8)));
        registry.amendTerms(_id, bytes32(0), 2, AUTH);
    }

    function test_amendTerms_revert_zeroAuthorizationHash() public {
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.ZeroField.selector, uint8(7)));
        registry.amendTerms(_id, TERMS_V2, 2, bytes32(0));
    }

    // ── Happy path ────────────────────────────────────────────────────────────

    function test_amendTerms_updatesFields() public {
        vm.prank(writer);
        registry.amendTerms(_id, TERMS_V2, 2, AUTH);

        IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(_id);
        assertEq(r.termsHash, TERMS_V2);
        assertEq(r.termsVersion, 2);
    }

    function test_amendTerms_historyRetained() public {
        vm.prank(writer);
        registry.amendTerms(_id, TERMS_V2, 2, AUTH);
        vm.prank(writer);
        registry.amendTerms(_id, TERMS_V3, 3, AUTH);

        assertEq(registry.termsHashAt(_id, 1), TERMS);
        assertEq(registry.termsHashAt(_id, 2), TERMS_V2);
        assertEq(registry.termsHashAt(_id, 3), TERMS_V3);
    }

    function test_amendTerms_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IDocumentReceivableRegistry.TermsAmended(_id, 2, TERMS_V2, AUTH);
        vm.prank(writer);
        registry.amendTerms(_id, TERMS_V2, 2, AUTH);
    }

    function test_amendTerms_allowedAfterReversalUnPays() public {
        // Pay fully, try to amend (blocked), then reverse, then amend (allowed)
        vm.prank(writer);
        registry.recordPayment(_id, 1, PRINCIPAL, EVIDENCE_1, LEGS);

        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(IDocumentReceivableRegistry.ReceivableAlreadyPaid.selector, _id));
        registry.amendTerms(_id, TERMS_V2, 2, AUTH);

        // Reverse → goes back to PartiallyPaid or Open
        vm.prank(writer);
        registry.recordReversal(_id, EVIDENCE_1, PRINCIPAL, REASON);

        vm.prank(writer);
        registry.amendTerms(_id, TERMS_V2, 2, AUTH);
        assertEq(registry.receivableOf(_id).termsVersion, 2);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Role management
// ─────────────────────────────────────────────────────────────────────────────
contract DocumentReceivableRegistry_Roles is DocumentReceivableBase {
    function test_admin_canGrantWriterRole() public {
        address newWriter = makeAddr("newWriter");
        vm.prank(admin);
        registry.grantRole(WRITER_ROLE, newWriter);
        assertTrue(registry.hasRole(WRITER_ROLE, newWriter));
    }

    function test_admin_canRevokeWriterRole() public {
        vm.prank(admin);
        registry.revokeRole(WRITER_ROLE, writer);
        assertFalse(registry.hasRole(WRITER_ROLE, writer));

        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, writer, WRITER_ROLE)
        );
        registry.register(_defaultArgs());
    }

    function test_writer_cannotGrantRoles() public {
        address target = makeAddr("target");
        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, writer, DEFAULT_ADMIN_ROLE)
        );
        registry.grantRole(WRITER_ROLE, target);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// No-value: contract must reject ETH
// ─────────────────────────────────────────────────────────────────────────────
contract DocumentReceivableRegistry_NoValue is DocumentReceivableBase {
    function test_noValue_balanceStaysZero() public view {
        assertEq(address(registry).balance, 0);
    }

    function test_noValue_plainTransferReverts() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(registry).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(registry).balance, 0);
    }

    function test_noValue_callWithDataAndValueReverts() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(registry).call{value: 1 ether}(hex"deadbeef");
        assertFalse(ok);
        assertEq(address(registry).balance, 0);
    }

    function test_noValue_registerWithValueReverts() public {
        // Capture pre-state.
        uint256 nextBefore = registry.nextReceivableId();
        bytes memory data = abi.encodeWithSelector(registry.register.selector, _defaultArgs());
        vm.deal(writer, 1 ether);
        vm.prank(writer);
        (bool ok,) = address(registry).call{value: 1 ether}(data);
        assertFalse(ok);
        assertEq(address(registry).balance, 0);
        // State unchanged: no new id was assigned.
        assertEq(registry.nextReceivableId(), nextBefore, "nextReceivableId changed");
    }

    function test_noValue_recordPaymentWithValueReverts() public {
        uint256 id = _register();
        // Snapshot state before the attempted write-with-value.
        IDocumentReceivableRegistry.Receivable memory before = registry.receivableOf(id);
        bool evBefore = registry.evidenceUsed(EVIDENCE_1);

        bytes memory data =
            abi.encodeWithSelector(registry.recordPayment.selector, id, uint8(1), uint128(100), EVIDENCE_1, LEGS);
        vm.deal(writer, 1 ether);
        vm.prank(writer);
        (bool ok,) = address(registry).call{value: 1 ether}(data);
        assertFalse(ok);
        assertEq(address(registry).balance, 0);
        // State unchanged.
        IDocumentReceivableRegistry.Receivable memory after_ = registry.receivableOf(id);
        assertEq(after_.paidUnits, before.paidUnits, "paidUnits changed");
        assertEq(registry.evidenceUsed(EVIDENCE_1), evBefore, "evidence state changed");
    }

    function test_noValue_recordReversalWithValueReverts() public {
        uint256 id = _register();
        vm.prank(writer);
        registry.recordPayment(id, 1, 100, EVIDENCE_1, LEGS);

        IDocumentReceivableRegistry.Receivable memory before = registry.receivableOf(id);
        bytes memory data =
            abi.encodeWithSelector(registry.recordReversal.selector, id, EVIDENCE_1, uint128(50), REASON);
        vm.deal(writer, 1 ether);
        vm.prank(writer);
        (bool ok,) = address(registry).call{value: 1 ether}(data);
        assertFalse(ok);
        assertEq(address(registry).balance, 0);
        // State unchanged.
        IDocumentReceivableRegistry.Receivable memory after_ = registry.receivableOf(id);
        assertEq(after_.paidUnits, before.paidUnits, "paidUnits changed");
        assertEq(after_.reversedUnits, before.reversedUnits, "reversedUnits changed");
    }

    function test_noValue_amendTermsWithValueReverts() public {
        uint256 id = _register();
        IDocumentReceivableRegistry.Receivable memory before = registry.receivableOf(id);

        bytes memory data =
            abi.encodeWithSelector(registry.amendTerms.selector, id, keccak256("terms-v2"), uint32(2), AUTH);
        vm.deal(writer, 1 ether);
        vm.prank(writer);
        (bool ok,) = address(registry).call{value: 1 ether}(data);
        assertFalse(ok);
        assertEq(address(registry).balance, 0);
        // State unchanged.
        IDocumentReceivableRegistry.Receivable memory after_ = registry.receivableOf(id);
        assertEq(after_.termsVersion, before.termsVersion, "termsVersion changed");
        assertEq(after_.termsHash, before.termsHash, "termsHash changed");
    }

    // ── Token rejection (B4) ──────────────────────────────────────────────────

    /// @notice safeTransferFrom of an ERC-721 to the registry must revert
    ///         (no onERC721Received hook → the OZ receiver check reverts).
    function test_noValue_erc721SafeTransferReverts() public {
        MockERC721 nft = new MockERC721();
        address sender = makeAddr("nftSender");
        nft.mint(sender, 1);

        vm.prank(sender);
        vm.expectRevert();
        nft.safeTransferFrom(sender, address(registry), 1);
    }

    /// @notice safeTransferFrom of an ERC-1155 to the registry must revert
    ///         (no onERC1155Received hook → the OZ receiver check reverts).
    function test_noValue_erc1155SafeTransferReverts() public {
        MockERC1155 token = new MockERC1155();
        address sender = makeAddr("erc1155Sender");
        token.mint(sender, 1, 10);

        vm.prank(sender);
        vm.expectRevert();
        token.safeTransferFrom(sender, address(registry), 1, 5, "");
    }

    /// @notice Calling ERC-20 transfer(address,uint256) selector on the registry reverts.
    function test_noValue_erc20TransferSelectorReverts() public {
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", stranger, 1);
        (bool ok,) = address(registry).call(data);
        assertFalse(ok, "transfer selector unexpectedly succeeded");
    }

    /// @notice Calling ERC-20 approve(address,uint256) selector on the registry reverts.
    function test_noValue_erc20ApproveSelectorReverts() public {
        bytes memory data = abi.encodeWithSignature("approve(address,uint256)", stranger, 1);
        (bool ok,) = address(registry).call(data);
        assertFalse(ok, "approve selector unexpectedly succeeded");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fuzz tests
// ─────────────────────────────────────────────────────────────────────────────
contract DocumentReceivableRegistry_Fuzz is DocumentReceivableBase {
    /// @notice Fuzz random sequences of payments and reversals, asserting invariants.
    function testFuzz_paymentsAndReversals(uint128 p1, uint128 p2, uint128 rev1, uint128 rev2) public {
        vm.assume(PRINCIPAL > 0);
        // Bound payment amounts so they fit within principal (split evenly)
        p1 = uint128(bound(p1, 1, PRINCIPAL / 2));
        p2 = uint128(bound(p2, 1, PRINCIPAL - p1));

        uint256 id = _register();

        vm.prank(writer);
        registry.recordPayment(id, 1, p1, EVIDENCE_1, LEGS);
        vm.prank(writer);
        registry.recordPayment(id, 2, p2, EVIDENCE_2, LEGS);

        IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);
        assertEq(r.paidUnits, r.grossAppliedUnits - r.reversedUnits);
        assertLe(r.paidUnits, r.principal);
        assertEq(uint8(r.status), uint8(_expectedStatus(r.paidUnits, r.principal)));
        assertEq(registry.outstandingUnits(id), r.principal - r.paidUnits);

        // Bound reversals
        rev1 = uint128(bound(rev1, 0, p1));
        if (rev1 > 0) {
            vm.prank(writer);
            registry.recordReversal(id, EVIDENCE_1, rev1, REASON);
        }

        rev2 = uint128(bound(rev2, 0, p2));
        if (rev2 > 0) {
            vm.prank(writer);
            registry.recordReversal(id, EVIDENCE_2, rev2, keccak256("reason-2"));
        }

        r = registry.receivableOf(id);
        assertEq(r.paidUnits, r.grossAppliedUnits - r.reversedUnits);
        assertLe(r.paidUnits, r.principal);
        assertEq(uint8(r.status), uint8(_expectedStatus(r.paidUnits, r.principal)));
        assertEq(registry.outstandingUnits(id), r.principal - r.paidUnits);
    }

    /// @notice Fuzz register args — uses bound() for numeric fields so the corpus
    ///         stays valid and vm.assume only weeds out zero bytes32 inputs.
    function testFuzz_registerArgs(
        bytes32 docCommitment,
        bytes32 debtorCommitment,
        bytes32 unit,
        bytes32 termsHash,
        bytes32 destinationDigest,
        uint128 principal,
        uint64 issuedAt,
        uint64 dueAt,
        uint8 installments
    ) public {
        // Keep vm.assume only for non-zero bytes32 fields (low rejection rate).
        vm.assume(docCommitment != bytes32(0));
        vm.assume(debtorCommitment != bytes32(0));
        vm.assume(unit != bytes32(0));
        vm.assume(termsHash != bytes32(0));
        vm.assume(destinationDigest != bytes32(0));

        // Numeric fields use bound() so every seed is valid.
        issuedAt = uint64(bound(issuedAt, 1, block.timestamp));
        dueAt = uint64(bound(dueAt, uint256(issuedAt) + 1, type(uint64).max));
        principal = uint128(bound(principal, 1, type(uint128).max));
        installments = uint8(bound(installments, 1, 255));

        IDocumentReceivableRegistry.RegisterArgs memory a = IDocumentReceivableRegistry.RegisterArgs({
            documentCommitment: docCommitment,
            creditorAgentId: creditorAgentId,
            debtorCommitment: debtorCommitment,
            principal: principal,
            unit: unit,
            issuedAt: issuedAt,
            dueAt: dueAt,
            installments: installments,
            termsHash: termsHash,
            destinationDigest: destinationDigest
        });

        vm.prank(writer);
        uint256 id = registry.register(a);
        assertGt(id, 0);

        // Assert every stored field.
        IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);
        assertEq(r.documentCommitment, docCommitment);
        assertEq(r.creditorAgentId, creditorAgentId);
        assertEq(r.debtorCommitment, debtorCommitment);
        assertEq(r.unit, unit);
        assertEq(r.termsHash, termsHash);
        assertEq(r.destinationDigest, destinationDigest);
        assertEq(r.principal, principal);
        assertEq(r.paidUnits, 0);
        assertEq(r.grossAppliedUnits, 0);
        assertEq(r.reversedUnits, 0);
        assertEq(r.issuedAt, issuedAt);
        assertEq(r.dueAt, dueAt);
        assertEq(r.registeredAt, block.timestamp);
        assertEq(r.termsVersion, 1);
        assertEq(r.installments, installments);
        assertEq(uint8(r.status), uint8(IDocumentReceivableRegistry.Status.Open));

        // idOfCommitment round-trip.
        assertEq(registry.idOfCommitment(docCommitment), id);

        // termsHashAt(id, 1) == termsHash.
        assertEq(registry.termsHashAt(id, 1), termsHash);

        // Registering the same args again reverts DocumentAlreadyRegistered(doc, id).
        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(IDocumentReceivableRegistry.DocumentAlreadyRegistered.selector, docCommitment, id)
        );
        registry.register(a);
    }

    /// @notice Fuzz a random sequence of pay / reverse / overpay-attempt ops on one
    ///         receivable and assert the local mirror matches the registry after every op.
    function testFuzz_randomSequence(uint128 principalSeed, uint256[24] calldata ops) public {
        _runRandomSequence(principalSeed, ops);
    }

    // Split into a separate function so the compiler can allocate its own stack frame,
    // keeping testFuzz_randomSequence itself stack-light.
    function _runRandomSequence(uint128 principalSeed, uint256[24] calldata ops) internal {
        uint128 principal = uint128(bound(principalSeed, 1, type(uint128).max));

        // Register a fresh receivable with the fuzzed principal.
        {
            IDocumentReceivableRegistry.RegisterArgs memory a = _defaultArgs();
            a.documentCommitment = keccak256("fuzz-seq-doc");
            a.principal = principal;
            a.installments = 255;
            vm.prank(writer);
            registry.register(a);
        }
        uint256 id = registry.nextReceivableId() - 1;

        SeqMirror memory m;
        m.evidenceNonce = 1234;

        for (uint256 i = 0; i < ops.length; i++) {
            _seqStep(id, principal, ops[i], m);
            _seqAssert(id, principal, m);
        }
    }

    struct SeqMirror {
        // gross and reversed are uint256 to avoid overflow: gross can exceed uint128.max
        // when the same receivable is partially reversed and repaid multiple times
        // (gross accumulates across all pay rounds, so grossAppliedUnits can overflow
        // uint128 if principal is close to type(uint128).max and we cycle pay-reverse-pay).
        // The on-chain grossAppliedUnits is also uint128; the test bounds payments so that
        // the on-chain value never wraps, but we need wide arithmetic for the mirror.
        uint256 gross;
        uint256 reversed;
        bytes32[24] evidences;
        uint128[24] evApplied;
        uint128[24] evReversed;
        uint256 evCount;
        uint256 evidenceNonce;
    }

    function _seqStep(uint256 id, uint128 principal, uint256 op, SeqMirror memory m) internal {
        uint8 kind = uint8(op % 3);
        uint128 amount = uint128(op >> 8);

        if (kind == 0) {
            // PAY
            uint128 remaining = principal - uint128(m.gross - m.reversed);
            if (remaining == 0) return;
            // Cap amount so that on-chain grossAppliedUnits (uint128) doesn't overflow.
            // m.gross is uint256 so we must check before casting.
            if (m.gross >= type(uint128).max) return;
            uint128 grossHeadroom = type(uint128).max - uint128(m.gross);
            if (grossHeadroom == 0) return;
            uint128 maxAmount = remaining < grossHeadroom ? remaining : grossHeadroom;
            amount = uint128(bound(amount, 1, maxAmount));
            bytes32 evidence = keccak256(abi.encodePacked("fuzz-ev", m.evidenceNonce++));
            vm.prank(writer);
            registry.recordPayment(id, 1, amount, evidence, LEGS);
            m.evidences[m.evCount] = evidence;
            m.evApplied[m.evCount] = amount;
            m.evCount++;
            m.gross += amount;
        } else if (kind == 1) {
            // REVERSE
            if (m.evCount == 0) return;
            uint256 pick = op % m.evCount;
            uint128 reversible = m.evApplied[pick] - m.evReversed[pick];
            if (reversible == 0) return;
            uint128 rev = uint128(bound(amount, 1, reversible));
            vm.prank(writer);
            registry.recordReversal(id, m.evidences[pick], rev, REASON);
            m.evReversed[pick] += rev;
            m.reversed += rev;
        } else {
            // OVERPAY ATTEMPT — must revert with Overpayment.
            // Skip when principal == type(uint128).max: no value fits in uint128 that
            // exceeds principal, so the registry would never see an overpayment revert
            // (the contract's own overflow-safe check would catch it the same way).
            if (principal == type(uint128).max) return;
            uint128 netPaid = uint128(m.gross - m.reversed);
            uint128 overpay = principal + 1; // safe: principal < type(uint128).max
            bytes32 evidence = keccak256(abi.encodePacked("fuzz-ov", m.evidenceNonce++));
            vm.prank(writer);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IDocumentReceivableRegistry.Overpayment.selector, id, principal, netPaid, overpay
                )
            );
            registry.recordPayment(id, 1, overpay, evidence, LEGS);
        }
    }

    function _seqAssert(uint256 id, uint128 principal, SeqMirror memory m) internal view {
        IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);
        uint128 mirrorPaid = uint128(m.gross - m.reversed);
        assertEq(r.paidUnits, mirrorPaid, "paid mismatch");
        assertEq(r.grossAppliedUnits, uint128(m.gross), "gross mismatch");
        assertEq(r.reversedUnits, uint128(m.reversed), "reversed mismatch");
        assertLe(r.paidUnits, r.principal, "paid > principal");
        assertEq(uint8(r.status), uint8(_expectedStatus(r.paidUnits, r.principal)), "status wrong");
        assertEq(registry.outstandingUnits(id), r.principal - r.paidUnits, "outstanding wrong");
        // paymentOf for every evidence.
        for (uint256 j = 0; j < m.evCount; j++) {
            (uint256 rid, uint128 app, uint128 rev) = registry.paymentOf(m.evidences[j]);
            assertEq(rid, id, "paymentOf rid wrong");
            assertEq(app, m.evApplied[j], "paymentOf applied wrong");
            assertEq(rev, m.evReversed[j], "paymentOf reversed wrong");
        }
        assertEq(principal, r.principal, "principal changed");
    }

    function _expectedStatus(uint128 paid, uint128 principal)
        internal
        pure
        returns (IDocumentReceivableRegistry.Status)
    {
        if (paid == 0) return IDocumentReceivableRegistry.Status.Open;
        if (paid < principal) return IDocumentReceivableRegistry.Status.PartiallyPaid;
        return IDocumentReceivableRegistry.Status.Paid;
    }
}

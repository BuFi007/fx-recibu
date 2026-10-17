// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IDocumentReceivableRegistry} from "../interfaces/IDocumentReceivableRegistry.sol";
import {IAgentIdentityRegistry} from "../interfaces/IAgentIdentityRegistry.sol";

/// @title  DocumentReceivableRegistry
/// @notice DATA-ONLY registry that records identity and collection history of
///         issued, NOT-factored invoices.  Holds no tokens, moves no funds.
///
/// Access model:
///   DEFAULT_ADMIN_ROLE — pause / unpause, role management.
///   WRITER_ROLE        — register, recordPayment, recordReversal, amendTerms.
///
/// Checks-Effects-Interactions: the only external call is a STATICCALL to
/// `IDENTITY.ownerOf` in `register`, on a trusted, immutable address. It runs
/// before any state is written and cannot re-enter (static context).
///
/// Creditor existence: `IDENTITY` may be the ERC-8004 IdentityRegistry (ERC-721,
/// `ownerOf` reverts for an unknown id) or fx-recibu's BUFIIdentityRegistry
/// (`ownerOf` returns address(0) for an unknown id). `_creditorExists` treats a
/// revert, empty or malformed return data, and address(0) all as "unknown".
contract DocumentReceivableRegistry is AccessControl, Pausable, IDocumentReceivableRegistry {
    // ─────────────────────────────────────────────────────────────────────────
    // Constants & immutables
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Role required to write (register / record / amend) receivables.
    bytes32 public constant WRITER_ROLE = keccak256("WRITER_ROLE");

    /// @notice The agent-identity registry used to validate creditor agent ids
    ///         (ERC-8004 IdentityRegistry or BUFIIdentityRegistry; see {IAgentIdentityRegistry}).
    IAgentIdentityRegistry public immutable IDENTITY;

    // ─────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Next id to assign.  Starts at 1; 0 is the "unknown" sentinel.
    uint256 internal _nextId = 1;

    /// @dev Primary receivable storage, keyed by id.
    mapping(uint256 => Receivable) internal _receivables;

    /// @dev documentCommitment → receivable id (0 = not registered).
    mapping(bytes32 => uint256) internal _idOfCommitment;

    /// @dev evidence → PaymentRecord (receivableId == 0 means unused).
    mapping(bytes32 => PaymentRecord) internal _payments;

    /// @dev reversalEvidence → ReversalRecord (receivableId == 0 means unused).
    mapping(bytes32 => ReversalRecord) internal _reversals;

    /// @dev id → version → termsHash history.
    mapping(uint256 => mapping(uint32 => bytes32)) internal _termsHashAtVersion;

    // ─────────────────────────────────────────────────────────────────────────
    // Internal structs (not exposed through the interface)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Per-evidence payment record.
    struct PaymentRecord {
        uint256 receivableId; // 0 = slot not used
        uint128 appliedUnits;
        uint128 reversedUnits;
    }

    /// @dev Per-reversalEvidence reversal record.
    struct ReversalRecord {
        uint256 receivableId; // 0 = slot not used
        bytes32 originalEvidence;
        uint128 units;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /// @param admin_            Address to receive DEFAULT_ADMIN_ROLE.
    /// @param identityRegistry_ Address of the agent-identity registry (ERC-8004 or BUFIIdentityRegistry).
    constructor(address admin_, address identityRegistry_) {
        if (admin_ == address(0) || identityRegistry_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        IDENTITY = IAgentIdentityRegistry(identityRegistry_);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Pause all write operations.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause all write operations.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Write: register
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IDocumentReceivableRegistry
    function register(RegisterArgs calldata a)
        external
        onlyRole(WRITER_ROLE)
        whenNotPaused
        returns (uint256 receivableId)
    {
        // ── Validation ────────────────────────────────────────────────────────
        if (a.documentCommitment == bytes32(0)) revert ZeroCommitment();

        uint256 existingId = _idOfCommitment[a.documentCommitment];
        if (existingId != 0) revert DocumentAlreadyRegistered(a.documentCommitment, existingId);

        // Only external call in this function: a STATICCALL, before any effects (CEI safe).
        if (!_creditorExists(a.creditorAgentId)) revert UnknownCreditorAgent(a.creditorAgentId);

        if (a.debtorCommitment == bytes32(0)) revert ZeroField(0);
        if (a.unit == bytes32(0)) revert ZeroField(1);
        if (a.termsHash == bytes32(0)) revert ZeroField(2);
        if (a.destinationDigest == bytes32(0)) revert ZeroField(3);
        if (a.principal == 0) revert ZeroPrincipal();
        if (a.installments == 0) revert ZeroInstallments();
        if (a.issuedAt == 0 || a.issuedAt > block.timestamp) revert InvalidIssuedAt();
        if (a.dueAt <= a.issuedAt) revert InvalidDueAt();

        // ── Effects ───────────────────────────────────────────────────────────
        receivableId = _nextId++;

        _idOfCommitment[a.documentCommitment] = receivableId;
        _termsHashAtVersion[receivableId][1] = a.termsHash;

        Receivable storage r = _receivables[receivableId];
        r.documentCommitment = a.documentCommitment;
        r.creditorAgentId = a.creditorAgentId;
        r.debtorCommitment = a.debtorCommitment;
        r.unit = a.unit;
        r.termsHash = a.termsHash;
        r.destinationDigest = a.destinationDigest;
        r.principal = a.principal;
        r.issuedAt = a.issuedAt;
        r.dueAt = a.dueAt;
        r.registeredAt = uint64(block.timestamp);
        r.termsVersion = 1;
        r.installments = a.installments;
        r.status = Status.Open;
        // paidUnits, grossAppliedUnits, reversedUnits stay 0

        emit ReceivableRegistered(
            receivableId, a.documentCommitment, a.creditorAgentId, a.principal, a.unit, a.dueAt, a.termsHash
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Write: recordPayment
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IDocumentReceivableRegistry
    function recordPayment(
        uint256 id,
        uint8 installment,
        uint128 appliedUnits,
        bytes32 evidenceCommitment,
        bytes32 legsRoot
    ) external onlyRole(WRITER_ROLE) whenNotPaused {
        Receivable storage r = _requireKnown(id);

        // ── Validation ────────────────────────────────────────────────────────
        if (installment == 0 || installment > r.installments) revert InvalidInstallment(installment);
        if (appliedUnits == 0) revert ZeroUnits();
        if (evidenceCommitment == bytes32(0)) revert ZeroField(4);
        if (legsRoot == bytes32(0)) revert ZeroField(5);
        if (_isUsed(evidenceCommitment)) revert EvidenceAlreadyUsed(evidenceCommitment);

        // Overflow-safe: compare against remaining capacity, never add first.
        uint128 remaining = r.principal - r.paidUnits;
        if (appliedUnits > remaining) revert Overpayment(id, r.principal, r.paidUnits, appliedUnits);

        // ── Effects ───────────────────────────────────────────────────────────
        _payments[evidenceCommitment] = PaymentRecord({receivableId: id, appliedUnits: appliedUnits, reversedUnits: 0});

        r.paidUnits += appliedUnits;
        r.grossAppliedUnits += appliedUnits;
        r.status = _deriveStatus(r.paidUnits, r.principal);

        emit PaymentRecorded(id, installment, appliedUnits, r.paidUnits, evidenceCommitment, legsRoot);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Write: recordReversal
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IDocumentReceivableRegistry
    function recordReversal(uint256 id, bytes32 originalEvidence, uint128 units, bytes32 reversalEvidence)
        external
        onlyRole(WRITER_ROLE)
        whenNotPaused
    {
        Receivable storage r = _requireKnown(id);

        // ── Validation ────────────────────────────────────────────────────────
        if (units == 0) revert ZeroUnits();
        if (reversalEvidence == bytes32(0)) revert ZeroField(6);

        PaymentRecord storage rec = _payments[originalEvidence];
        if (rec.receivableId == 0) revert UnknownEvidence(originalEvidence);
        if (rec.receivableId != id) revert EvidenceReceivableMismatch(originalEvidence, id, rec.receivableId);

        // Global single-use namespace: covers payment evidences, reversal evidences,
        // and originalEvidence itself (which is already a payment evidence).
        if (_isUsed(reversalEvidence)) revert EvidenceAlreadyUsed(reversalEvidence);

        // Overflow-safe: compare remaining reversible capacity.
        uint128 reversibleRemaining = rec.appliedUnits - rec.reversedUnits;
        if (units > reversibleRemaining) {
            revert ReversalExceedsPayment(originalEvidence, rec.appliedUnits, rec.reversedUnits, units);
        }

        // ── Effects ───────────────────────────────────────────────────────────
        rec.reversedUnits += units;

        _reversals[reversalEvidence] =
            ReversalRecord({receivableId: id, originalEvidence: originalEvidence, units: units});

        r.paidUnits -= units;
        r.reversedUnits += units;
        r.status = _deriveStatus(r.paidUnits, r.principal);

        emit ReversalRecorded(id, originalEvidence, reversalEvidence, units, r.paidUnits);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Write: amendTerms
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IDocumentReceivableRegistry
    function amendTerms(uint256 id, bytes32 newTermsHash, uint32 newVersion, bytes32 authorizationHash)
        external
        onlyRole(WRITER_ROLE)
        whenNotPaused
    {
        Receivable storage r = _requireKnown(id);

        // ── Validation ────────────────────────────────────────────────────────
        if (r.status == Status.Paid) revert ReceivableAlreadyPaid(id);

        uint32 expected = r.termsVersion + 1;
        if (newVersion != expected) revert InvalidTermsVersion(expected, newVersion);

        if (newTermsHash == bytes32(0)) revert ZeroField(8);
        if (authorizationHash == bytes32(0)) revert ZeroField(7);

        // ── Effects ───────────────────────────────────────────────────────────
        r.termsHash = newTermsHash;
        r.termsVersion = newVersion;
        _termsHashAtVersion[id][newVersion] = newTermsHash;

        emit TermsAmended(id, newVersion, newTermsHash, authorizationHash);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IDocumentReceivableRegistry
    function receivableOf(uint256 id) external view returns (Receivable memory) {
        return _receivables[id]; // returns zero struct (Status.None) for unknown id
    }

    /// @inheritdoc IDocumentReceivableRegistry
    function idOfCommitment(bytes32 documentCommitment) external view returns (uint256) {
        return _idOfCommitment[documentCommitment];
    }

    /// @inheritdoc IDocumentReceivableRegistry
    function evidenceUsed(bytes32 evidence) external view returns (bool) {
        return _isUsed(evidence);
    }

    /// @inheritdoc IDocumentReceivableRegistry
    function paymentOf(bytes32 evidence)
        external
        view
        returns (uint256 receivableId, uint128 appliedUnits, uint128 reversedUnits)
    {
        PaymentRecord storage rec = _payments[evidence];
        return (rec.receivableId, rec.appliedUnits, rec.reversedUnits);
    }

    /// @inheritdoc IDocumentReceivableRegistry
    function reversalOf(bytes32 reversalEvidence)
        external
        view
        returns (uint256 receivableId, bytes32 originalEvidence, uint128 units)
    {
        ReversalRecord storage rec = _reversals[reversalEvidence];
        return (rec.receivableId, rec.originalEvidence, rec.units);
    }

    /// @inheritdoc IDocumentReceivableRegistry
    function outstandingUnits(uint256 id) external view returns (uint128) {
        Receivable storage r = _receivables[id];
        // If id is unknown, r.principal == 0 and r.paidUnits == 0 → returns 0.
        return r.principal - r.paidUnits;
    }

    /// @inheritdoc IDocumentReceivableRegistry
    function termsHashAt(uint256 id, uint32 version) external view returns (bytes32) {
        return _termsHashAtVersion[id][version];
    }

    /// @inheritdoc IDocumentReceivableRegistry
    function nextReceivableId() external view returns (uint256) {
        return _nextId;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Returns the storage pointer for `id` or reverts with {UnknownReceivable}.
    ///      A receivable is known iff id != 0 && id < _nextId.
    function _requireKnown(uint256 id) internal view returns (Receivable storage r) {
        if (id == 0 || id >= _nextId) revert UnknownReceivable(id);
        r = _receivables[id];
    }

    /// @dev Returns true if `evidence` is in use — either as a payment evidence or a
    ///      reversal evidence.  The two mappings share one global single-use namespace.
    function _isUsed(bytes32 evidence) internal view returns (bool) {
        return _payments[evidence].receivableId != 0 || _reversals[evidence].receivableId != 0;
    }

    /// @dev True iff `IDENTITY.ownerOf(agentId)` succeeds AND returns a well-formed,
    ///      non-zero address. A raw staticcall is used instead of `try/catch` because a
    ///      high-level try/catch does NOT catch empty or malformed return data (ABI
    ///      decoding of the result reverts in the caller); here those cases must read as
    ///      "unknown creditor", never as a bare revert.
    ///      - call reverts (ERC-721 `ERC721NonexistentToken`, or any other reason) → false
    ///      - target has no code / returns < 32 bytes                               → false
    ///      - returned word is not a clean 20-byte address (dirty upper bits)       → false
    ///      - returned address is address(0) (BUFIIdentityRegistry unknown id)      → false
    function _creditorExists(uint256 agentId) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            address(IDENTITY).staticcall(abi.encodeCall(IAgentIdentityRegistry.ownerOf, (agentId)));
        if (!ok || ret.length < 32) return false;
        uint256 raw = abi.decode(ret, (uint256));
        return raw != 0 && raw <= type(uint160).max;
    }

    /// @dev Pure status derivation.  paidUnits == 0 → Open; < principal → PartiallyPaid; == principal → Paid.
    function _deriveStatus(uint128 paid, uint128 principal) internal pure returns (Status) {
        if (paid == 0) return Status.Open;
        if (paid < principal) return Status.PartiallyPaid;
        return Status.Paid;
    }
}

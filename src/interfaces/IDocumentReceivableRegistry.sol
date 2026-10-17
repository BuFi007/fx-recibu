// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @title IDocumentReceivableRegistry
/// @notice Interface for the DocumentReceivableRegistry — a DATA-ONLY registry that records
///         identity and collection history of issued, NOT-factored invoices.
///         Holds no tokens, moves no funds, has no payable function.
interface IDocumentReceivableRegistry {
    // ─────────────────────────────────────────────────────────────────────────
    // Enums
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Life-cycle status of a receivable.
    /// @dev    None  = id does not exist (default zero value).
    ///         Open  = principal not yet fully paid.
    ///         PartiallyPaid = at least one unit applied, but paidUnits < principal.
    ///         Paid  = paidUnits == principal.
    enum Status {
        None,
        Open,
        PartiallyPaid,
        Paid
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Arguments required to register a new receivable.
    /// @param documentCommitment Unique hash that identifies the underlying document.
    /// @param creditorAgentId    Agent id of the creditor in the configured identity registry
    ///                           (ERC-8004 IdentityRegistry or BUFIIdentityRegistry; `ownerOf` must resolve).
    /// @param debtorCommitment   Privacy-preserving commitment to the debtor's identity.
    /// @param principal          Face value of the receivable in `unit` units.
    /// @param unit               Currency / unit of account (e.g. keccak256("USDC")).
    /// @param issuedAt           Unix timestamp when the invoice was issued (≤ block.timestamp).
    /// @param dueAt              Unix timestamp of the payment due date (> issuedAt).
    /// @param installments       Number of expected payment installments (≥ 1).
    /// @param termsHash          Hash of the legal / commercial terms document.
    /// @param destinationDigest  Commitment to the settlement destination.
    struct RegisterArgs {
        bytes32 documentCommitment;
        uint256 creditorAgentId;
        bytes32 debtorCommitment;
        uint128 principal;
        bytes32 unit;
        uint64 issuedAt;
        uint64 dueAt;
        uint8 installments;
        bytes32 termsHash;
        bytes32 destinationDigest;
    }

    /// @notice Full on-chain state of a registered receivable.
    /// @dev    Packed tightly into nine 256-bit slots (storage layout noted inline).
    ///
    ///  Slot 0: documentCommitment (bytes32)
    ///  Slot 1: creditorAgentId   (uint256)
    ///  Slot 2: debtorCommitment  (bytes32)
    ///  Slot 3: unit              (bytes32)
    ///  Slot 4: termsHash         (bytes32)
    ///  Slot 5: destinationDigest (bytes32)
    ///  Slot 6: principal(128) | paidUnits(128)
    ///  Slot 7: grossAppliedUnits(128) | reversedUnits(128)
    ///  Slot 8: issuedAt(64) | dueAt(64) | registeredAt(64) | termsVersion(32) | installments(8) | status(8) [=240 bits, fits]
    struct Receivable {
        bytes32 documentCommitment;
        uint256 creditorAgentId;
        bytes32 debtorCommitment;
        bytes32 unit;
        bytes32 termsHash;
        bytes32 destinationDigest;
        uint128 principal;
        uint128 paidUnits; // NET currently paid
        uint128 grossAppliedUnits; // sum of all appliedUnits ever
        uint128 reversedUnits; // sum of all reversals ever
        uint64 issuedAt;
        uint64 dueAt;
        uint64 registeredAt;
        uint32 termsVersion; // starts at 1
        uint8 installments;
        Status status;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Emitted when a new receivable is registered.
    event ReceivableRegistered(
        uint256 indexed id,
        bytes32 indexed documentCommitment,
        uint256 indexed creditorAgentId,
        uint128 principal,
        bytes32 unit,
        uint64 dueAt,
        bytes32 termsHash
    );

    /// @notice Emitted when a payment is recorded against a receivable.
    event PaymentRecorded(
        uint256 indexed id,
        uint8 installment,
        uint128 appliedUnits,
        uint128 paidUnitsAfter,
        bytes32 indexed evidenceCommitment,
        bytes32 legsRoot
    );

    /// @notice Emitted when a payment is reversed.
    event ReversalRecorded(
        uint256 indexed id,
        bytes32 indexed originalEvidence,
        bytes32 indexed reversalEvidence,
        uint128 units,
        uint128 paidUnitsAfter
    );

    /// @notice Emitted when the terms of a receivable are amended.
    event TermsAmended(uint256 indexed id, uint32 newVersion, bytes32 newTermsHash, bytes32 authorizationHash);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Either `admin` or `identityRegistry` was the zero address in the constructor.
    error ZeroAddress();

    /// @notice `documentCommitment` field is zero.
    error ZeroCommitment();

    /// @notice The document commitment is already registered under `existingId`.
    error DocumentAlreadyRegistered(bytes32 documentCommitment, uint256 existingId);

    /// @notice `IDENTITY.ownerOf(agentId)` reverted, returned no / malformed data, or returned address(0).
    error UnknownCreditorAgent(uint256 agentId);

    /// @notice A required `bytes32` field was zero. `field` encodes which one:
    ///         0 = debtorCommitment, 1 = unit, 2 = termsHash, 3 = destinationDigest,
    ///         4 = evidenceCommitment, 5 = legsRoot, 6 = reversalEvidence, 7 = authorizationHash,
    ///         8 = newTermsHash.
    error ZeroField(uint8 field);

    /// @notice `principal` was zero.
    error ZeroPrincipal();

    /// @notice `installments` was zero.
    error ZeroInstallments();

    /// @notice `appliedUnits` or `units` argument was zero.
    error ZeroUnits();

    /// @notice `issuedAt` was zero or greater than `block.timestamp`.
    error InvalidIssuedAt();

    /// @notice `dueAt` was not strictly greater than `issuedAt`.
    error InvalidDueAt();

    /// @notice The receivable id does not exist.
    error UnknownReceivable(uint256 id);

    /// @notice The installment number is out of range (0 or > installments).
    error InvalidInstallment(uint8 installment);

    /// @notice The evidence commitment has already been used for a previous payment.
    error EvidenceAlreadyUsed(bytes32 evidence);

    /// @notice Applying `appliedUnits` would exceed `principal` given the current `paidUnits`.
    error Overpayment(uint256 id, uint128 principal, uint128 paidUnits, uint128 appliedUnits);

    /// @notice The receivable is already fully paid.
    error ReceivableAlreadyPaid(uint256 id);

    /// @notice The original evidence does not correspond to a recorded payment.
    error UnknownEvidence(bytes32 evidence);

    /// @notice The original evidence belongs to a different receivable.
    error EvidenceReceivableMismatch(bytes32 evidence, uint256 expectedId, uint256 actualId);

    /// @notice Reversing `units` would exceed what was applied (minus prior reversals).
    error ReversalExceedsPayment(bytes32 evidence, uint128 applied, uint128 alreadyReversed, uint128 units);

    /// @notice `newVersion` must equal `currentVersion + 1`.
    error InvalidTermsVersion(uint32 expected, uint32 received);

    // ─────────────────────────────────────────────────────────────────────────
    // Write functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Register a new receivable.
    /// @param  a  Registration arguments (see {RegisterArgs}).
    /// @return receivableId  Sequential id starting at 1.
    function register(RegisterArgs calldata a) external returns (uint256 receivableId);

    /// @notice Record a payment installment against a receivable.
    /// @param id                 Receivable id.
    /// @param installment        Installment number (1-indexed, ≤ installments).
    /// @param appliedUnits       Units of payment being applied.
    /// @param evidenceCommitment Unique hash of the payment evidence.
    /// @param legsRoot           Merkle root of the payment legs.
    function recordPayment(
        uint256 id,
        uint8 installment,
        uint128 appliedUnits,
        bytes32 evidenceCommitment,
        bytes32 legsRoot
    ) external;

    /// @notice Record a reversal of a previously applied payment.
    /// @param id               Receivable id.
    /// @param originalEvidence Evidence commitment of the payment being reversed.
    /// @param units            Units to reverse (≤ applied − already reversed).
    /// @param reversalEvidence Single-use commitment that identifies this reversal document.
    ///                         Must be non-zero and unused in the global evidence namespace
    ///                         (shared with payment evidences).
    function recordReversal(uint256 id, bytes32 originalEvidence, uint128 units, bytes32 reversalEvidence) external;

    /// @notice Amend the terms of a receivable (strictly versioned).
    /// @param id                Receivable id.
    /// @param newTermsHash      Hash of the new terms document.
    /// @param newVersion        Must equal current termsVersion + 1.
    /// @param authorizationHash Hash of the authorising document.
    function amendTerms(uint256 id, bytes32 newTermsHash, uint32 newVersion, bytes32 authorizationHash) external;

    // ─────────────────────────────────────────────────────────────────────────
    // View functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the full receivable struct for `id`.
    ///         Returns a zero struct (Status.None) for unknown ids — does NOT revert.
    function receivableOf(uint256 id) external view returns (Receivable memory);

    /// @notice Returns the receivable id for a document commitment, or 0 if not registered.
    function idOfCommitment(bytes32 documentCommitment) external view returns (uint256);

    /// @notice Returns true if `evidence` has been used — either as a payment evidence
    ///         or as a reversal evidence.  The global namespace is shared.
    function evidenceUsed(bytes32 evidence) external view returns (bool);

    /// @notice Returns the payment record for `evidence`.
    ///         Returns (0,0,0) if not found.
    function paymentOf(bytes32 evidence)
        external
        view
        returns (uint256 receivableId, uint128 appliedUnits, uint128 reversedUnits);

    /// @notice Returns the reversal record for `reversalEvidence`.
    ///         Returns (0, bytes32(0), 0) if the reversal evidence is unknown.
    function reversalOf(bytes32 reversalEvidence)
        external
        view
        returns (uint256 receivableId, bytes32 originalEvidence, uint128 units);

    /// @notice Returns `principal - paidUnits` for `id`, or 0 for an unknown id.
    function outstandingUnits(uint256 id) external view returns (uint128);

    /// @notice Returns the terms hash recorded at `version` for `id`, or bytes32(0).
    function termsHashAt(uint256 id, uint32 version) external view returns (bytes32);

    /// @notice Returns the next receivable id that will be assigned (== current count + 1).
    function nextReceivableId() external view returns (uint256);
}

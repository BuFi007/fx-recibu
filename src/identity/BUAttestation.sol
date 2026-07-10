// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IBUFIIdentityRegistry} from "../interfaces/IBUFIIdentityRegistry.sol";
import {IBUFIReputationRegistry} from "../interfaces/IBUFIReputationRegistry.sol";

/// @title BUAttestation
/// @notice The bridge from the off-chain scoring service (SPEC_CREDIT_PASSPORT §P2–§P4)
///         to on-chain state. Anyone may relay an attestation; validity comes from the
///         HSM signature, a per-agent sequential nonce (replay protection), and a deadline.
///
///  scoring service (HSM key) ──sign EIP-712──▶ relayer ──▶ attestScore / attestKyb
///        │                                                     │ verify sig+nonce+deadline
///        │                                                     ▼
///        │                                   ReputationRegistry.setScore   (ATTESTOR_ROLE)
///        │                                   IdentityRegistry.setKybStatus (ISSUER_ROLE)
///
/// @dev verifierKind is pluggable by design (SPEC §2.1): v1 = HSM_EOA. When CRE reaches
///      Arc, a DON_REPORT verifier slots in behind the same attestation types with no
///      schema change (M-future; see docs/THREAT_MODEL.md T13).
contract BUAttestation is AccessControl, EIP712 {
    bytes32 public constant SIGNER_ADMIN_ROLE = keccak256("SIGNER_ADMIN_ROLE");
    uint8 public constant AGENT_KYB_KIND = 0;
    uint8 public constant TEAM_KYB_KIND = 1;
    uint8 public constant DON_SCORE_KIND = 2;

    bytes32 public constant SCORE_TYPEHASH = keccak256(
        "ScoreAttestation(uint256 agentId,uint8 sellerScore,uint8 debtorScore,uint32 modelVersion,bytes32 featureRootHash,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant KYB_TYPEHASH =
        keccak256("KybAttestation(uint256 agentId,bool approved,uint256 nonce,uint256 deadline)");

    IBUFIIdentityRegistry public immutable IDENTITY;
    IBUFIReputationRegistry public immutable REPUTATION;

    /// @notice the HSM signing key of the scoring service
    address public signer;
    address public donForwarder;
    bytes32 public expectedWorkflowId;
    uint64 public targetChainSelector;
    mapping(bytes32 => bool) public processedDonOperations;
    /// @notice Team-keyed KYB credential consumed by the ACE policy.
    ///         The key is keccak256(teamId), never a wallet address or PII.
    struct TeamKybState {
        bool approved;
        uint64 observedAt;
        uint64 validUntil;
        uint64 version;
        bytes32 operationId;
    }
    mapping(bytes32 => TeamKybState) internal _teamKyb;
    /// @notice sequential per-agent nonce — an attestation is single-use, in order
    mapping(uint256 => uint256) public nonces;

    event SignerSet(address indexed signer);
    event ScoreAttestationRelayed(uint256 indexed agentId, uint256 nonce, address relayer);
    event KybAttestationRelayed(uint256 indexed agentId, bool approved, uint256 nonce, address relayer);
    event TeamKybCredentialSet(bytes32 indexed teamKey, bool approved, uint64 validUntil, uint64 version, bytes32 operationId);
    event DonScoreAttestation(uint256 indexed agentId, uint8 sellerScore, uint8 debtorScore, uint32 modelVersion, bytes32 operationId);

    error ZeroAddress();
    error Expired(uint256 deadline);
    error BadNonce(uint256 expected, uint256 got);
    error BadSignature();
    error NotDonForwarder();
    error DonReplay(bytes32 operationId);
    error DonExpired();
    error DonWrongWorkflow();
    error DonWrongChain();
    error DonInvalidKind(uint8 kind);
    error DonInvalidSubject();
    error DonInvalidOperation();
    error DonInvalidExpiry();
    error DonInvalidVersion();
    error StaleTeamKybVersion(uint64 current, uint64 received);
    error DonMalformedReport();

    constructor(address admin, address signer_, IBUFIIdentityRegistry identity_, IBUFIReputationRegistry reputation_)
        EIP712("BUAttestation", "1")
    {
        if (admin == address(0) || signer_ == address(0)) revert ZeroAddress();
        if (address(identity_) == address(0) || address(reputation_) == address(0)) revert ZeroAddress();
        IDENTITY = identity_;
        REPUTATION = reputation_;
        signer = signer_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SIGNER_ADMIN_ROLE, admin);
        emit SignerSet(signer_);
    }

    /// @notice rotate the HSM key (admin multisig)
    function setSigner(address newSigner) external onlyRole(SIGNER_ADMIN_ROLE) {
        if (newSigner == address(0)) revert ZeroAddress();
        signer = newSigner;
        emit SignerSet(newSigner);
    }

    function setDonConfig(address forwarder, bytes32 workflowId, uint64 chainSelector) external onlyRole(DEFAULT_ADMIN_ROLE) { if (forwarder == address(0) || workflowId == bytes32(0) || chainSelector == 0) revert ZeroAddress(); donForwarder = forwarder; expectedWorkflowId = workflowId; targetChainSelector = chainSelector; }

    /// @notice CRE/DON report:
    ///         abi.encode(uint8 kind,uint256 subject,bool approved,uint64 validUntil,
    ///         uint64 version,bytes32 operationId,bytes32 workflowId,uint64 chainSelector,
    ///         uint64 expiresAt)
    ///         kind 0 targets the legacy agentId KYB state; kind 1 targets the
    ///         team-keyed credential (subject is uint256(bytes32(teamKey))).
    ///         kind 2 is an envelope `(uint8 kind, bytes inner)` whose inner
    ///         tuple carries a DON score attestation (no HSM signature).
    function onReport(bytes calldata, bytes calldata report) external {
        if (msg.sender != donForwarder) revert NotDonForwarder();
        if (report.length < 32) revert DonMalformedReport();
        uint8 reportKind = abi.decode(report, (uint8));

        if (reportKind == DON_SCORE_KIND) {
            if (report.length < 64) revert DonMalformedReport();
            uint256 innerOffset;
            assembly {
                innerOffset := calldataload(add(report.offset, 32))
            }
            if (innerOffset != 64) revert DonMalformedReport();
            (uint8 scoreKind, bytes memory inner) = abi.decode(report, (uint8, bytes));
            if (scoreKind != DON_SCORE_KIND) revert DonInvalidKind(scoreKind);
            (
                uint256 agentId,
                uint8 sellerScore,
                uint8 debtorScore,
                uint32 modelVersion,
                bytes32 featureRootHash,
                bytes32 scoreOperationId,
                bytes32 scoreWorkflowId,
                uint64 scoreChainSelector,
                uint64 scoreExpiresAt
            ) = abi.decode(inner, (uint256, uint8, uint8, uint32, bytes32, bytes32, bytes32, uint64, uint64));
            if (agentId == 0) revert DonInvalidSubject();
            _checkDonMetadata(scoreOperationId, scoreWorkflowId, scoreChainSelector, scoreExpiresAt);
            if (processedDonOperations[scoreOperationId]) revert DonReplay(scoreOperationId);
            processedDonOperations[scoreOperationId] = true;
            REPUTATION.setScore(agentId, sellerScore, debtorScore, modelVersion, featureRootHash);
            emit DonScoreAttestation(agentId, sellerScore, debtorScore, modelVersion, scoreOperationId);
            return;
        }

        if (reportKind > TEAM_KYB_KIND || report.length != 9 * 32) revert DonMalformedReport();
        (uint8 kind, uint256 subject, bool approved, uint64 validUntil, uint64 version, bytes32 operationId, bytes32 workflowId, uint64 chainSelector, uint64 expiresAt) = abi.decode(report, (uint8,uint256,bool,uint64,uint64,bytes32,bytes32,uint64,uint64));
        if (kind != reportKind) revert DonInvalidKind(kind);
        if (subject == 0) revert DonInvalidSubject();
        _checkDonMetadata(operationId, workflowId, chainSelector, expiresAt);
        if (processedDonOperations[operationId]) revert DonReplay(operationId);
        processedDonOperations[operationId] = true;

        if (kind == AGENT_KYB_KIND) {
            IDENTITY.setKybStatus(subject, approved, validUntil, version, operationId);
        } else {
            bytes32 teamKey = bytes32(subject);
            // Approved credentials must have a finite TTL. A rejected report may
            // use validUntil=0 as an explicit revocation.
            if (approved && validUntil <= block.timestamp) revert DonInvalidExpiry();
            _setTeamKyb(teamKey, approved, validUntil, version, operationId);
        }
    }

    function _checkDonMetadata(bytes32 operationId, bytes32 workflowId, uint64 chainSelector, uint64 expiresAt) internal view {
        if (workflowId != expectedWorkflowId) revert DonWrongWorkflow();
        if (chainSelector != targetChainSelector) revert DonWrongChain();
        if (expiresAt <= block.timestamp) revert DonExpired();
        if (operationId == bytes32(0)) revert DonInvalidOperation();
    }

    /// @notice Return the raw team credential for policy/audit consumers.
    function teamKybState(bytes32 teamKey)
        external
        view
        returns (bool approved, uint64 observedAt, uint64 validUntil, uint64 version, bytes32 operationId)
    {
        TeamKybState memory s = _teamKyb[teamKey];
        return (s.approved, s.observedAt, s.validUntil, s.version, s.operationId);
    }

    /// @notice True only while an approved team credential is within its TTL.
    function teamKybApproved(bytes32 teamKey) external view returns (bool) {
        TeamKybState memory s = _teamKyb[teamKey];
        return s.approved && s.validUntil > block.timestamp;
    }

    function attestScore(
        uint256 agentId,
        uint8 sellerScore,
        uint8 debtorScore,
        uint32 modelVersion,
        bytes32 featureRootHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkAndBumpNonce(agentId, nonce, deadline);
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    SCORE_TYPEHASH, agentId, sellerScore, debtorScore, modelVersion, featureRootHash, nonce, deadline
                )
            )
        );
        _verify(digest, signature);
        REPUTATION.setScore(agentId, sellerScore, debtorScore, modelVersion, featureRootHash);
        emit ScoreAttestationRelayed(agentId, nonce, msg.sender);
    }

    function attestKyb(uint256 agentId, bool approved, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
    {
        _checkAndBumpNonce(agentId, nonce, deadline);
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(KYB_TYPEHASH, agentId, approved, nonce, deadline)));
        _verify(digest, signature);
        IDENTITY.setKybStatus(agentId, approved);
        emit KybAttestationRelayed(agentId, approved, nonce, msg.sender);
    }

    function _checkAndBumpNonce(uint256 agentId, uint256 nonce, uint256 deadline) internal {
        if (block.timestamp > deadline) revert Expired(deadline);
        uint256 expected = nonces[agentId];
        if (nonce != expected) revert BadNonce(expected, nonce);
        nonces[agentId] = expected + 1;
    }

    function _verify(bytes32 digest, bytes calldata signature) internal view {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || recovered != signer) revert BadSignature();
    }

    function _setTeamKyb(bytes32 teamKey, bool approved, uint64 validUntil, uint64 version, bytes32 operationId) internal {
        if (teamKey == bytes32(0)) revert DonInvalidSubject();
        if (version == 0) revert DonInvalidVersion();
        TeamKybState storage current = _teamKyb[teamKey];
        if (version <= current.version) revert StaleTeamKybVersion(current.version, version);
        current.approved = approved;
        current.observedAt = uint64(block.timestamp);
        current.validUntil = validUntil;
        current.version = version;
        current.operationId = operationId;
        emit TeamKybCredentialSet(teamKey, approved, validUntil, version, operationId);
    }
}

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
    /// @notice sequential per-agent nonce — an attestation is single-use, in order
    mapping(uint256 => uint256) public nonces;

    event SignerSet(address indexed signer);
    event ScoreAttestationRelayed(uint256 indexed agentId, uint256 nonce, address relayer);
    event KybAttestationRelayed(uint256 indexed agentId, bool approved, uint256 nonce, address relayer);

    error ZeroAddress();
    error Expired(uint256 deadline);
    error BadNonce(uint256 expected, uint256 got);
    error BadSignature();
    error NotDonForwarder();
    error DonReplay(bytes32 operationId);
    error DonExpired();
    error DonWrongWorkflow();
    error DonWrongChain();

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

    /// @notice CRE/DON report: abi.encode(uint8 kind,uint256 agentId,bool approved,uint64 validUntil,uint64 version,bytes32 operationId,bytes32 workflowId,uint64 chainSelector,uint64 expiresAt)
    function onReport(bytes calldata, bytes calldata report) external {
        if (msg.sender != donForwarder) revert NotDonForwarder();
        (uint8 kind, uint256 agentId, bool approved, uint64 validUntil, uint64 version, bytes32 operationId, bytes32 workflowId, uint64 chainSelector, uint64 expiresAt) = abi.decode(report, (uint8,uint256,bool,uint64,uint64,bytes32,bytes32,uint64,uint64));
        if (kind > 1 || workflowId != expectedWorkflowId) revert DonWrongWorkflow(); if (chainSelector != targetChainSelector) revert DonWrongChain(); if (expiresAt < block.timestamp) revert DonExpired(); if (processedDonOperations[operationId]) revert DonReplay(operationId); processedDonOperations[operationId] = true;
        IDENTITY.setKybStatus(agentId, approved, validUntil, version, operationId);
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
}

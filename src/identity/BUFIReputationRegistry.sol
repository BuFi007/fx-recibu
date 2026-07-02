// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IBUFIIdentityRegistry} from "../interfaces/IBUFIIdentityRegistry.sol";
import {IBUFIReputationRegistry} from "../interfaces/IBUFIReputationRegistry.sol";

/// @title BUFIReputationRegistry
/// @notice The credit passport's on-chain state. WRITE-PATH LAW (SPEC §4.9):
///
///   ATTESTOR_ROLE (BUAttestation, HSM-verified) ──▶ scores ONLY (prices terms)
///   SETTLEMENT_ROLE (InvoiceSettlement)         ──▶ paidOnTimeCumulative ONLY
///                                                    (the sole input that raises L(w))
///   SETTLEMENT_ROLE | OPS_ROLE                  ──▶ PERMANENT_DEFAULT (terminal, no unset)
///   OPS_ROLE (multisig, via RestructureRouter)  ──▶ RESTRUCTURED marks
///
/// A compromised scorer can mis-price; it can never raise exposure. Enforced
/// here structurally, not by policy.
contract BUFIReputationRegistry is AccessControl, IBUFIReputationRegistry {
    bytes32 public constant ATTESTOR_ROLE = keccak256("ATTESTOR_ROLE");
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");

    IBUFIIdentityRegistry public immutable IDENTITY;

    mapping(uint256 => ScoreSnapshot) internal _scores;
    mapping(uint256 => uint256) internal _paidOnTime;
    mapping(uint256 => mapping(uint256 => uint256)) internal _pairSettled;
    mapping(uint256 => bool) internal _permanentDefault;
    mapping(uint256 => uint256) internal _restructured;

    error UnknownAgent(uint256 agentId);
    error ScoreOutOfRange();
    error AgentPermanentlyDefaulted(uint256 agentId);
    error ZeroAddress();

    constructor(address admin, IBUFIIdentityRegistry identity_) {
        if (admin == address(0) || address(identity_) == address(0)) revert ZeroAddress();
        IDENTITY = identity_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ── ATTESTOR: scores only ──────────────────────────────────────────

    function setScore(
        uint256 agentId,
        uint8 sellerScore,
        uint8 debtorScore,
        uint32 modelVersion,
        bytes32 featureRootHash
    ) external onlyRole(ATTESTOR_ROLE) {
        _requireLiveAgent(agentId);
        if (sellerScore > 100 || debtorScore > 100) revert ScoreOutOfRange();
        _scores[agentId] = ScoreSnapshot({
            sellerScore: sellerScore,
            debtorScore: debtorScore,
            modelVersion: modelVersion,
            featureRootHash: featureRootHash,
            attestedAt: uint64(block.timestamp)
        });
        emit ScoreAttested(agentId, sellerScore, debtorScore, modelVersion);
    }

    // ── SETTLEMENT: realized repayment only ────────────────────────────

    function recordOnTimeInstallment(uint256 agentId) external onlyRole(SETTLEMENT_ROLE) {
        _requireLiveAgent(agentId);
        uint256 cumulative = ++_paidOnTime[agentId];
        emit OnTimeInstallmentRecorded(agentId, cumulative);
    }

    function recordPairSettlement(uint256 sellerAgentId, uint256 debtorAgentId) external onlyRole(SETTLEMENT_ROLE) {
        _requireLiveAgent(sellerAgentId);
        if (!IDENTITY.exists(debtorAgentId)) revert UnknownAgent(debtorAgentId);
        uint256 count = ++_pairSettled[sellerAgentId][debtorAgentId];
        emit PairHistoryRecorded(sellerAgentId, debtorAgentId, count);
    }

    // ── Terminal / exceptional states ──────────────────────────────────

    function setPermanentDefault(uint256 agentId) external {
        if (!hasRole(SETTLEMENT_ROLE, msg.sender) && !hasRole(OPS_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, SETTLEMENT_ROLE);
        }
        _requireExists(agentId);
        // Idempotent, irreversible: there is deliberately NO unset function.
        _permanentDefault[agentId] = true;
        emit PermanentDefaultSet(agentId);
    }

    function markRestructured(uint256 agentId) external onlyRole(OPS_ROLE) {
        _requireLiveAgent(agentId);
        emit RestructuredMarked(agentId, ++_restructured[agentId]);
    }

    // ── Views ──────────────────────────────────────────────────────────

    function scoreOf(uint256 agentId) external view returns (ScoreSnapshot memory) {
        return _scores[agentId];
    }

    function paidOnTimeCumulative(uint256 agentId) external view returns (uint256) {
        return _paidOnTime[agentId];
    }

    function pairSettledCount(uint256 sellerAgentId, uint256 debtorAgentId) external view returns (uint256) {
        return _pairSettled[sellerAgentId][debtorAgentId];
    }

    function permanentDefault(uint256 agentId) external view returns (bool) {
        return _permanentDefault[agentId];
    }

    function restructuredCount(uint256 agentId) external view returns (uint256) {
        return _restructured[agentId];
    }

    function _requireExists(uint256 agentId) internal view {
        if (!IDENTITY.exists(agentId)) revert UnknownAgent(agentId);
    }

    /// @dev live = exists and not terminally defaulted. Score/repayment writes on a
    ///      defaulted identity are meaningless (the line is dead) — reject loudly.
    function _requireLiveAgent(uint256 agentId) internal view {
        _requireExists(agentId);
        if (_permanentDefault[agentId]) revert AgentPermanentlyDefaulted(agentId);
    }
}

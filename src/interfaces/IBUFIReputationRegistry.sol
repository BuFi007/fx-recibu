// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @title IBUFIReputationRegistry — attested scores + realized-repayment counters (the passport's on-chain half)
interface IBUFIReputationRegistry {
    struct ScoreSnapshot {
        uint8 sellerScore; // biller-side 0–100
        uint8 debtorScore; // payer-side 0–100
        uint32 modelVersion;
        bytes32 featureRootHash; // Merkle root of the feature vector at scoring time
        uint64 attestedAt;
    }

    event ScoreAttested(uint256 indexed agentId, uint8 sellerScore, uint8 debtorScore, uint32 modelVersion);
    event OnTimeInstallmentRecorded(uint256 indexed agentId, uint256 cumulative);
    event OnTimeInstallmentObserved(
        uint256 indexed agentId, uint256 realizedAmount, uint256 indexed epoch, bool credited
    );
    event PermanentDefaultSet(uint256 indexed agentId);
    event RestructuredMarked(uint256 indexed agentId, uint256 count);
    event PairHistoryRecorded(uint256 indexed sellerAgentId, uint256 indexed debtorAgentId, uint256 settledCount);

    function setScore(
        uint256 agentId,
        uint8 sellerScore,
        uint8 debtorScore,
        uint32 modelVersion,
        bytes32 featureRootHash
    ) external;

    function recordOnTimeInstallment(uint256 agentId, uint256 realizedAmount) external returns (bool credited);
    function recordPairSettlement(uint256 sellerAgentId, uint256 debtorAgentId) external;
    function setPermanentDefault(uint256 agentId) external;
    function markRestructured(uint256 agentId) external;

    function scoreOf(uint256 agentId) external view returns (ScoreSnapshot memory);
    function paidOnTimeCumulative(uint256 agentId) external view returns (uint256);
    function pairSettledCount(uint256 sellerAgentId, uint256 debtorAgentId) external view returns (uint256);
    function permanentDefault(uint256 agentId) external view returns (bool);
    function restructuredCount(uint256 agentId) external view returns (uint256);
}

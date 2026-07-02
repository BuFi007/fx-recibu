// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IBUFIIdentityRegistry} from "../interfaces/IBUFIIdentityRegistry.sol";
import {IBUFIReputationRegistry} from "../interfaces/IBUFIReputationRegistry.sol";
import {Params} from "../libraries/Params.sol";

/// @title WorkspaceTierRegistry
/// @notice SPEC §3 as view functions — the credit engine's pricing/eligibility matrix.
///         Stateless over (IdentityRegistry, ReputationRegistry): pure tier math + the
///         graduated exposure limit L(w).
///
///  ROLE SPLIT (SPEC §3.0): the DEBTOR's score prices the money (advance rate,
///  non-recourse); the SELLER's score prices the trust (reserve, bond, tranche).
///
///  L(w) INVARIANT (SPEC §3.5/§4.9): monotonic, and a function of REALIZED repayment
///  (paidOnTimeCumulative — settlement-only writes) plus the terminal-default flag.
///  Score attestations can never move it. Fuzz-proven in WorkspaceTierRegistry.t.sol.
contract WorkspaceTierRegistry {
    enum Tier {
        Developing, // score < 50
        Moderate, // 50–69
        Strong, // 70–84
        Excellent // 85–100
    }

    /// @notice most-senior tranche an invoice may be funded from (SPEC §3.4)
    enum TrancheEligibility {
        SeniorA, // both ≥ Strong with pair history
        MezzB, // exactly one side Moderate
        JuniorC // any Developing side, or no pair history
    }

    IBUFIIdentityRegistry public immutable IDENTITY;
    IBUFIReputationRegistry public immutable REPUTATION;

    error ZeroAddress();

    constructor(IBUFIIdentityRegistry identity_, IBUFIReputationRegistry reputation_) {
        if (address(identity_) == address(0) || address(reputation_) == address(0)) revert ZeroAddress();
        IDENTITY = identity_;
        REPUTATION = reputation_;
    }

    // ── Pure tier math (SPEC §3.0) ─────────────────────────────────────

    function tierOf(uint8 score) public pure returns (Tier) {
        if (score >= Params.SCORE_EXCELLENT) return Tier.Excellent;
        if (score >= Params.SCORE_STRONG) return Tier.Strong;
        if (score >= Params.SCORE_MODERATE) return Tier.Moderate;
        return Tier.Developing;
    }

    /// @notice advance rate in bps of face — a function of the DEBTOR (SPEC §3.1)
    function advanceRateBps(uint8 debtorScore, bool hasPairHistory) public pure returns (uint16) {
        Tier t = tierOf(debtorScore);
        uint16 base = t == Tier.Excellent
            ? Params.ADVANCE_EXCELLENT_BPS
            : t == Tier.Strong ? Params.ADVANCE_STRONG_BPS : t == Tier.Moderate ? Params.ADVANCE_MODERATE_BPS : Params.ADVANCE_DEVELOPING_BPS;
        if (!hasPairHistory) base -= Params.PAIR_PENALTY_BPS; // bases ≥ 6000 > penalty; cannot underflow
        return base;
    }

    /// @notice operating-reserve ratio in bps — a function of the SELLER (SPEC §3.2)
    function reserveRatioBps(uint8 sellerScore) public pure returns (uint16) {
        Tier t = tierOf(sellerScore);
        return t == Tier.Excellent
            ? Params.RESERVE_EXCELLENT_BPS
            : t == Tier.Strong ? Params.RESERVE_STRONG_BPS : t == Tier.Moderate ? Params.RESERVE_MODERATE_BPS : Params.RESERVE_DEVELOPING_BPS;
    }

    /// @notice share of the reserve that must be POSTED as a USDC bond before lockInvoice
    ///         funds (SPEC §3.2): Developing/first-time 100%, Moderate 50%, Strong+ 0
    ///         (accrued from spread — reputation substitutes for collateral).
    function bondShareBps(uint8 sellerScore) public pure returns (uint16) {
        Tier t = tierOf(sellerScore);
        if (t == Tier.Developing) return 10_000;
        if (t == Tier.Moderate) return 5_000;
        return 0;
    }

    /// @notice non-recourse offered only when both sides ≥ Strong AND pair history exists (SPEC §3.3)
    function nonRecourseEligible(uint8 sellerScore, uint8 debtorScore, bool hasPairHistory)
        public
        pure
        returns (bool)
    {
        return hasPairHistory && tierOf(sellerScore) >= Tier.Strong && tierOf(debtorScore) >= Tier.Strong;
    }

    /// @notice tranche placement (SPEC §3.4) — thin history is junior-funded by construction
    function trancheEligibility(uint8 sellerScore, uint8 debtorScore, bool hasPairHistory)
        public
        pure
        returns (TrancheEligibility)
    {
        Tier s = tierOf(sellerScore);
        Tier d = tierOf(debtorScore);
        if (s == Tier.Developing || d == Tier.Developing || !hasPairHistory) return TrancheEligibility.JuniorC;
        if (s >= Tier.Strong && d >= Tier.Strong) return TrancheEligibility.SeniorA;
        return TrancheEligibility.MezzB;
    }

    // ── L(w): the fraud ramp (SPEC §3.5) ───────────────────────────────

    /// @notice aggregate outstanding exposure cap for a workspace. Monotonic in
    ///         realized on-time installments; zero on terminal default; NEVER a
    ///         function of attested scores.
    function limitOf(uint256 agentId) public view returns (uint256) {
        if (REPUTATION.permanentDefault(agentId)) return 0;
        uint256 earned = Params.L0_USDC + REPUTATION.paidOnTimeCumulative(agentId) * Params.RAMP_STEP_USDC;
        return earned > Params.L_MAX_USDC ? Params.L_MAX_USDC : earned;
    }

    /// @notice per-debtor cap inside L(w) (SPEC §3.5 concentration rule)
    function debtorConcentrationCap(uint256 agentId) external view returns (uint256) {
        return (limitOf(agentId) * Params.MAX_DEBTOR_CONCENTRATION_BPS) / Params.BPS;
    }

    /// @notice the v2v hard gate: KYB-approved and not terminally defaulted (SPEC §1)
    function eligible(uint256 agentId) external view returns (bool) {
        return IDENTITY.kybApproved(agentId) && !REPUTATION.permanentDefault(agentId);
    }

    /// @notice pair history flag from realized settlements (never self-reported)
    function hasPairHistory(uint256 sellerAgentId, uint256 debtorAgentId) external view returns (bool) {
        return REPUTATION.pairSettledCount(sellerAgentId, debtorAgentId) > 0;
    }
}

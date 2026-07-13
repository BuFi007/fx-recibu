// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @title Params — fx-Recibú pinned protocol parameters (M0.5)
///
///  ┌──────────────────────────────────────────────────────────────────────┐
///  │ SPEC.md §8 param pin. PROPOSED DEFAULTS pending owner sign-off       │
///  │ (Linear BU-134). Every consumer reads THESE constants — no inline    │
///  │ magic numbers anywhere in src/. USDC amounts are 6-decimals.        │
///  └──────────────────────────────────────────────────────────────────────┘
library Params {
    // ── Tier score bands (0–100, matches desk-v1 payment-score bands) ──
    uint8 internal constant SCORE_EXCELLENT = 85;
    uint8 internal constant SCORE_STRONG = 70;
    uint8 internal constant SCORE_MODERATE = 50;

    // ── Advance rates by debtor tier, bps of face (SPEC §3.1) ──
    uint16 internal constant ADVANCE_EXCELLENT_BPS = 9000;
    uint16 internal constant ADVANCE_STRONG_BPS = 8500;
    uint16 internal constant ADVANCE_MODERATE_BPS = 7500;
    uint16 internal constant ADVANCE_DEVELOPING_BPS = 6000;
    /// @dev subtracted when the seller↔debtor pair has no history (S_pair == 0)
    uint16 internal constant PAIR_PENALTY_BPS = 500;

    // ── Operating reserve by seller tier, bps of outstanding (SPEC §3.2) ──
    uint16 internal constant RESERVE_EXCELLENT_BPS = 1000;
    uint16 internal constant RESERVE_STRONG_BPS = 1500;
    uint16 internal constant RESERVE_MODERATE_BPS = 2000;
    uint16 internal constant RESERVE_DEVELOPING_BPS = 2500;

    // ── Graduated exposure L(w) (SPEC §3.5) — USDC 6-dec ──
    /// @dev cold-start aggregate cap for a new/Developing workspace (~$1.5k)
    uint256 internal constant L0_USDC = 1_500e6;
    /// @dev L(w) step earned per on-time settled installment (~$250)
    uint256 internal constant RAMP_STEP_USDC = 250e6;
    /// @dev an installment below one ramp step is economically ineligible for line growth
    uint256 internal constant MIN_CREDITED_INSTALLMENT_USDC = RAMP_STEP_USDC;
    /// @dev maximum line growth within one epoch, relative to the epoch-start line (20%)
    uint16 internal constant RAMP_MAX_BPS_PER_EPOCH = 2000;
    /// @dev pair history requires one fully settled invoice of economically meaningful size
    uint256 internal constant MIN_PAIR_SETTLEMENT_USDC = RAMP_STEP_USDC;
    /// @dev hard ceiling on L(w) regardless of history (~$250k) — raise by governance only
    uint256 internal constant L_MAX_USDC = 250_000e6;
    /// @dev no single debtor may back more than this share of L(w)
    uint16 internal constant MAX_DEBTOR_CONCENTRATION_BPS = 3000;
    /// @dev max new advances per workspace per epoch
    uint16 internal constant MAX_ADVANCES_PER_EPOCH = 10;
    uint32 internal constant EPOCH_LENGTH = 30 days;

    // ── Installments (SPEC §3.6) ──
    uint8 internal constant MIN_INSTALLMENTS = 2;
    uint8 internal constant MAX_INSTALLMENTS = 12;
    uint32 internal constant MIN_INSTALLMENT_INTERVAL = 7 days;
    uint32 internal constant GRACE_STRONG = 5 days;
    uint32 internal constant GRACE_WEAK = 3 days;

    // ── Fees & splits ──
    uint16 internal constant INSURANCE_FEE_BPS = 50;
    /// @dev escrow idle-yield split (SPEC D20): senior / mezz / junior
    uint16 internal constant YIELD_SPLIT_A_BPS = 5000;
    uint16 internal constant YIELD_SPLIT_B_BPS = 3000;
    uint16 internal constant YIELD_SPLIT_C_BPS = 2000;

    // ── Oracle guard (SPEC §6.5) ──
    uint16 internal constant ORACLE_MAX_INTRABLOCK_MOVE_BPS = 1000;

    uint16 internal constant BPS = 10_000;
}

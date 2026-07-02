// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @title IOracle — Morpho Blue oracle interface (hand-declared; GPL interfaces-only
///        rule per docs/LICENSE_BOUNDARIES.md — no Morpho internals are copied).
/// @notice price() returns the collateral price in loan-token units scaled by 1e36,
///         i.e. valueLoan = collateralAmount × price / 1e36.
interface IOracle {
    function price() external view returns (uint256);
}

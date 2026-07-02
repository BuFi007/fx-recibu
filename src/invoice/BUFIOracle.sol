// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {InvoiceShelf} from "./InvoiceShelf.sol";
import {Params} from "../libraries/Params.sol";

/// @title BUFIOracle — per-tranche NAV oracle implementing Morpho IOracle (SPEC §6)
///
///  InvoiceShelf accounting (push-based, authorized writers only)
///        │ trancheAssets(t) − trancheLoss(t)      bIF-t.totalSupply()
///        ▼                                              ▼
///  price(t) = netAssetsUSDC(1e6) × 1e36 / supply(1e18)   →  1.00 USDC/share ≡ 1e24
///
/// NAV is NOT a traded price — it cannot be moved by a swap (SPEC §6.6). The attack
/// surface is authorized loss/reserve booking, so the circuit breaker guards WRITE-side
/// jumps: a >10% move vs the last observation trips the breaker and price() reverts
/// until ops clears it (fail-safe: Morpho actions halt rather than mismark).
/// @dev ROADMAP lists a separate OraclePauser; merged here with identical guarantee
///      (one observation store + trip flag) to keep the M3b surface minimal.
contract BUFIOracle is AccessControl, IOracle {
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");

    InvoiceShelf public immutable SHELF;
    uint8 public immutable TRANCHE;

    uint256 public lastObserved; // last price served (1e36 scale)
    bool public tripped;

    event Observed(uint256 price);
    event Tripped(uint256 lastObserved, uint256 attempted);
    event Cleared(uint256 rebasedTo);

    error Paused();
    error EmptyTranche();

    constructor(InvoiceShelf shelf, uint8 tranche, address admin) {
        SHELF = shelf;
        TRANCHE = tranche;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPS_ROLE, admin);
    }

    /// @notice Morpho-facing price. Reverts when tripped (fail-safe, SPEC §6.5).
    function price() external view returns (uint256) {
        if (tripped) revert Paused();
        return _nav();
    }

    /// @notice keeper poke: observe the current NAV and trip on a >10% move.
    ///         Anyone may poke — tripping is protective, never extractive.
    function observe() external returns (uint256 p) {
        p = _nav();
        uint256 last = lastObserved;
        if (last != 0 && _deviationBps(p, last) > Params.ORACLE_MAX_INTRABLOCK_MOVE_BPS) {
            tripped = true;
            emit Tripped(last, p);
            return last;
        }
        lastObserved = p;
        emit Observed(p);
    }

    /// @notice ops review clears the breaker and rebases the observation.
    function clear() external onlyRole(OPS_ROLE) {
        tripped = false;
        lastObserved = _nav();
        emit Cleared(lastObserved);
    }

    function _nav() internal view returns (uint256) {
        uint256 supply = SHELF.tranches(TRANCHE).totalSupply();
        if (supply == 0) revert EmptyTranche();
        // trancheAssets already nets allocated loss (deposits − loss, SPEC §6.2).
        // Scale the 6-dec USDC numerator to the 18-dec share supply per the Morpho
        // 1e36 convention: 1.00 USDC/share ≡ 1e24.
        return (SHELF.trancheAssets(TRANCHE) * 1e36) / supply;
    }

    function _deviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 diff = a > b ? a - b : b - a;
        return (diff * Params.BPS) / b;
    }
}

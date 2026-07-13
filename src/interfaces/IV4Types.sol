// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @title IV4Types — minimal Uniswap v4-core type + hook surface, hand-declared.
/// @notice We declare only what RecibuSettlementGuardHook needs (PoolKey, SwapParams,
///         BeforeSwapDelta, the two hook callbacks, the permissions struct), rather than
///         vendoring v4-core/periphery. Field order matches v4-core so a real deployment
///         binds to the canonical PoolManager. See docs/LICENSE_BOUNDARIES.md.
type Currency is address;

type BeforeSwapDelta is int256;

/// @dev v4-core PoolKey layout (currency0, currency1, fee, tickSpacing, hooks)
struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IPoolManager {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }
}

/// @dev the 14-permission struct v4 decodes from the hook address bits (HookMiner target)
struct HookPermissions {
    bool beforeInitialize;
    bool afterInitialize;
    bool beforeAddLiquidity;
    bool afterAddLiquidity;
    bool beforeRemoveLiquidity;
    bool afterRemoveLiquidity;
    bool beforeSwap;
    bool afterSwap;
    bool beforeDonate;
    bool afterDonate;
    bool beforeSwapReturnDelta;
    bool afterSwapReturnDelta;
    bool afterAddLiquidityReturnDelta;
    bool afterRemoveLiquidityReturnDelta;
}

library BeforeSwapDeltaLibrary {
    BeforeSwapDelta internal constant ZERO_DELTA = BeforeSwapDelta.wrap(0);
}

/// @dev Canonical Uniswap v4 low-address permission bits. A production hook must be
///      mined/deployed so `(uint160(hook) & ALL_HOOK_MASK) == declared permissions`.
///      RecibuSettlementGuardHook currently exposes these values for deployment tooling,
///      but deliberately permits only local-simulation deployment until that CREATE2
///      boundary and a live PoolManager integration have been reviewed.
library HookAddressFlags {
    uint160 internal constant ALL_HOOK_MASK = (1 << 14) - 1;
    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 internal constant AFTER_SWAP_FLAG = 1 << 6;
}

/// @dev Canonical v4 BalanceDelta packing: currency0 in the high int128 and
///      currency1 in the low int128. Positive deltas are owed to the caller.
library BalanceDeltaLibrary {
    function amount0(int256 delta) internal pure returns (int128 value) {
        assembly ("memory-safe") {
            value := sar(128, delta)
        }
    }

    function amount1(int256 delta) internal pure returns (int128 value) {
        assembly ("memory-safe") {
            value := signextend(15, delta)
        }
    }
}

/// @title IRecibuPriceFeed — the FX-mark freshness surface the guard checks (SPEC §7).
interface IRecibuPriceFeed {
    /// @return price 1e18-scaled mark, updatedAt unix seconds of last update
    function latest() external view returns (uint256 price, uint256 updatedAt);
}

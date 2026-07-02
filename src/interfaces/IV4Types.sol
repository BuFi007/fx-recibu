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

/// @title IRecibuPriceFeed — the FX-mark freshness surface the guard checks (SPEC §7).
interface IRecibuPriceFeed {
    /// @return price 1e18-scaled mark, updatedAt unix seconds of last update
    function latest() external view returns (uint256 price, uint256 updatedAt);
}

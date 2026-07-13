// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    Currency,
    PoolKey,
    IPoolManager,
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    BalanceDeltaLibrary,
    HookPermissions,
    HookAddressFlags,
    IRecibuPriceFeed
} from "../interfaces/IV4Types.sol";
import {IInvoiceShelf} from "../interfaces/IInvoiceShelf.sol";

/// @title RecibuSettlementGuardHook — Uniswap v4 guard for invoice-settlement FX (M7, SPEC §7)
///
///  Not a speculative-trading hook and NOT a PMM: it holds no liquidity and returns
///  ZERO_DELTA. Its only job is to REVERT a swap that isn't a legitimate, in-policy
///  invoice-settlement conversion — the v4 surface fx-Recibú actually needs.
///
///  beforeSwap(sender, key, params, hookData)
///    hookData = abi.encode(RecibuSwapContext)
///    ├─ onlyPoolManager
///    ├─ actual callback sender == expectedRequester and is whitelisted
///    ├─ invoiceId is Funded on the shelf                     (no settling dead invoices)
///    ├─ seller workspace NOT cross-default frozen            (SPEC §4.8 — no residual release)
///    ├─ recipient commitment ∈ {ReceivableEscrow, InvoiceSettlement}
///    ├─ deadline not passed
///    ├─ FX mark fresh (≤ maxOracleAge) and within maxDeviationBps of the swap's implied price
///    └─ revert on ANY invalid state
///  afterSwap → re-assert every guard, bind minAmountOut to the actual BalanceDelta,
///              then emit RecibuFxSettlementSwap (indexer-ready).
///
///  TRUST BOUNDARY: a v4 hook cannot observe the eventual `take(currency, recipient, amount)`
///  call. `recipient` is therefore an authenticated routing commitment, not proof of token
///  delivery. Governance MUST whitelist only trusted periphery contracts that construct
///  hookData and enforce delivery to the committed recipient. The hook independently binds
///  that periphery to `sender` and checks the actual swap output delta. No rehypothecation in
///  the hook (SPEC §9): idle escrow → Morpho is escrow-side.
///
///  DEPLOYMENT BOUNDARY: v1 is a local-simulation artifact only. Its constructor reverts on
///  every chain except Anvil's 31337. A live deployment remains disabled until HookMiner /
///  CREATE2 proves the canonical v4 permission bits, the exact PoolManager integration is
///  reviewed, and this chain-id kill switch is deliberately replaced. A direct local `new`
///  deployment is useful for guard tests but is not proof of a production-valid hook address.
contract RecibuSettlementGuardHook is AccessControl {
    using BalanceDeltaLibrary for int256;

    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");
    uint256 public constant LOCAL_SIMULATION_CHAIN_ID = 31_337;
    uint160 public constant ALL_HOOK_MASK = HookAddressFlags.ALL_HOOK_MASK;
    uint160 public constant EXPECTED_HOOK_FLAGS = HookAddressFlags.BEFORE_SWAP_FLAG | HookAddressFlags.AFTER_SWAP_FLAG;
    uint256 internal constant Q96 = 1 << 96;
    uint8 public constant MAX_SUPPORTED_DECIMALS = 18;
    uint256 public constant MAX_ORACLE_AGE_LIMIT = 1 hours;
    uint16 public constant MAX_DEVIATION_BPS_LIMIT = 1_000; // governance cannot loosen beyond 10%

    struct PoolConfiguration {
        // `PoolKey.hooks` is intentionally not caller-configurable: callbacks must
        // name this exact instance, so the constructor-derived value is address(this).
        Currency currency0;
        Currency currency1;
        uint24 fee;
        int24 tickSpacing;
        uint8 currency0Decimals;
        uint8 currency1Decimals;
        bool feedPriceIsCurrency1PerCurrency0;
    }

    struct RecibuSwapContext {
        bytes32 invoiceId; // encoded uint256 invoice id
        bytes32 workspaceId;
        bytes32 settlementId;
        bytes32 routeId;
        address expectedRequester; // must equal PoolManager's callback sender
        address recipient; // trusted-periphery routing commitment; see contract trust boundary
        uint256 minAmountOut;
        uint256 deadline;
        bool isRecoveryMode; // audit marker only; NEVER relaxes auth, oracle, or slippage checks
        bytes32 memoHash;
    }

    address public immutable POOL_MANAGER;
    IInvoiceShelf public immutable SHELF;
    address public immutable ESCROW;
    address public immutable SETTLEMENT;
    address public immutable GUARDED_CURRENCY0;
    address public immutable GUARDED_CURRENCY1;
    uint24 public immutable GUARDED_FEE;
    int24 public immutable GUARDED_TICK_SPACING;
    uint8 public immutable CURRENCY0_DECIMALS;
    uint8 public immutable CURRENCY1_DECIMALS;
    bool public immutable FEED_PRICE_IS_CURRENCY1_PER_CURRENCY0;
    IRecibuPriceFeed public priceFeed;

    uint256 public maxOracleAge = 60; // seconds
    uint16 public maxDeviationBps = 100; // 1% vs the swap's implied price
    mapping(address => bool) public whitelisted; // authorized settlement requesters

    event RecibuFxSettlementSwap(
        bytes32 indexed invoiceId,
        bytes32 indexed workspaceId,
        bytes32 indexed settlementId,
        bytes32 routeId,
        address requester,
        address recipient
    );
    event RecibuFxSwapBlocked(bytes32 indexed invoiceId, bytes32 indexed workspaceId, bytes32 routeId, bytes32 reason);
    event WhitelistSet(address indexed requester, bool allowed);
    event GuardParamsSet(uint256 maxOracleAge, uint16 maxDeviationBps, address priceFeed);

    error NotPoolManager();
    error LiveDeploymentDisabled(uint256 chainId);
    error InvalidPoolConfiguration();
    error UnexpectedPoolKey();
    error ExactOutputUnsupported(int256 amountSpecified);
    error ZeroSqrtPriceLimit();
    error NotWhitelisted(address requester);
    error RequesterMismatch(address sender, address expectedRequester);
    error InvoiceNotFunded(bytes32 invoiceId);
    error WorkspaceFrozen(uint256 agentId);
    error BadRecipient(address recipient);
    error ZeroMinimumAmountOut();
    error InsufficientAmountOut(uint256 actualAmountOut, uint256 minAmountOut);
    error DeadlinePassed(uint256 deadline);
    error InvalidOraclePrice();
    error InvalidImpliedPrice();
    error InvalidOracleTimestamp(uint256 updatedAt);
    error StaleOracle(uint256 updatedAt);
    error DeviationTooHigh(uint256 bps);
    error InvalidGuardParams(uint256 maxOracleAge, uint16 maxDeviationBps);
    error FreezeLookupFailed(uint256 agentId);
    error ZeroAddress();

    modifier onlyPoolManager() {
        if (msg.sender != POOL_MANAGER) revert NotPoolManager();
        _;
    }

    constructor(
        address poolManager,
        IInvoiceShelf shelf,
        address escrow,
        address settlement,
        PoolConfiguration memory pool,
        IRecibuPriceFeed feed,
        address admin
    ) {
        if (block.chainid != LOCAL_SIMULATION_CHAIN_ID) {
            revert LiveDeploymentDisabled(block.chainid);
        }
        if (
            poolManager == address(0) || address(shelf) == address(0) || escrow == address(0)
                || settlement == address(0) || address(feed) == address(0) || admin == address(0)
        ) {
            revert ZeroAddress();
        }
        address currency0 = Currency.unwrap(pool.currency0);
        address currency1 = Currency.unwrap(pool.currency1);
        if (
            currency0 == address(0) || currency1 == address(0) || currency0 == currency1 || pool.tickSpacing <= 0
                || pool.currency0Decimals > MAX_SUPPORTED_DECIMALS || pool.currency1Decimals > MAX_SUPPORTED_DECIMALS
        ) {
            revert InvalidPoolConfiguration();
        }
        POOL_MANAGER = poolManager;
        SHELF = shelf;
        ESCROW = escrow;
        SETTLEMENT = settlement;
        GUARDED_CURRENCY0 = currency0;
        GUARDED_CURRENCY1 = currency1;
        GUARDED_FEE = pool.fee;
        GUARDED_TICK_SPACING = pool.tickSpacing;
        CURRENCY0_DECIMALS = pool.currency0Decimals;
        CURRENCY1_DECIMALS = pool.currency1Decimals;
        FEED_PRICE_IS_CURRENCY1_PER_CURRENCY0 = pool.feedPriceIsCurrency1PerCurrency0;
        _setGuardParams(60, 100, feed);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPS_ROLE, admin);
    }

    function getHookPermissions() external pure returns (HookPermissions memory p) {
        p.beforeSwap = true;
        p.afterSwap = true;
        // no returnDelta flags: this is a guard, not a custom-accounting PMM.
    }

    /// @notice Whether this instance happens to carry the v4 callback bits it declares.
    /// @dev This is deployment-tooling introspection only. It does not lift the 31337-only
    ///      constructor boundary and a direct local deployment is expected to return false.
    function hasExpectedHookAddressFlags() external view returns (bool) {
        return uint160(address(this)) & ALL_HOOK_MASK == EXPECTED_HOOK_FLAGS;
    }

    /// @notice Authorizes a trusted swap periphery, not an arbitrary end user.
    /// @dev A whitelisted periphery must enforce actual output delivery to the
    ///      `recipient` commitment supplied in hookData.
    function setWhitelist(address requester, bool allowed) external onlyRole(OPS_ROLE) {
        if (requester == address(0)) revert ZeroAddress();
        whitelisted[requester] = allowed;
        emit WhitelistSet(requester, allowed);
    }

    function setGuardParams(uint256 maxOracleAge_, uint16 maxDeviationBps_, IRecibuPriceFeed feed)
        external
        onlyRole(OPS_ROLE)
    {
        _setGuardParams(maxOracleAge_, maxDeviationBps_, feed);
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        RecibuSwapContext memory ctx = abi.decode(hookData, (RecibuSwapContext));
        _guard(sender, key, ctx, params);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        int256 delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        RecibuSwapContext memory ctx = abi.decode(hookData, (RecibuSwapContext));
        _guard(sender, key, ctx, params);
        _checkAmountOut(params, delta, ctx.minAmountOut);
        emit RecibuFxSettlementSwap(
            ctx.invoiceId, ctx.workspaceId, ctx.settlementId, ctx.routeId, sender, ctx.recipient
        );
        return (this.afterSwap.selector, 0);
    }

    /// @dev the guard, factored out for direct unit testing without a live PoolManager.
    function _guard(
        address sender,
        PoolKey calldata key,
        RecibuSwapContext memory ctx,
        IPoolManager.SwapParams calldata params
    ) internal {
        _checkPoolKey(key);
        if (params.amountSpecified >= 0) revert ExactOutputUnsupported(params.amountSpecified);
        if (params.sqrtPriceLimitX96 == 0) revert ZeroSqrtPriceLimit();
        if (sender != ctx.expectedRequester) {
            emit RecibuFxSwapBlocked(ctx.invoiceId, ctx.workspaceId, ctx.routeId, "requester-mismatch");
            revert RequesterMismatch(sender, ctx.expectedRequester);
        }
        if (!whitelisted[sender]) {
            emit RecibuFxSwapBlocked(ctx.invoiceId, ctx.workspaceId, ctx.routeId, "requester");
            revert NotWhitelisted(sender);
        }
        uint256 invoiceId = uint256(ctx.invoiceId);
        if (SHELF.invoiceStatus(invoiceId) != IInvoiceShelf.Status.Funded) {
            emit RecibuFxSwapBlocked(ctx.invoiceId, ctx.workspaceId, ctx.routeId, "status");
            revert InvoiceNotFunded(ctx.invoiceId);
        }
        uint256 agentId = SHELF.sellerAgentIdOf(invoiceId);
        if (_frozen(agentId)) {
            emit RecibuFxSwapBlocked(ctx.invoiceId, ctx.workspaceId, ctx.routeId, "frozen");
            revert WorkspaceFrozen(agentId);
        }
        if (ctx.recipient != ESCROW && ctx.recipient != SETTLEMENT) {
            emit RecibuFxSwapBlocked(ctx.invoiceId, ctx.workspaceId, ctx.routeId, "recipient");
            revert BadRecipient(ctx.recipient);
        }
        if (block.timestamp > ctx.deadline) revert DeadlinePassed(ctx.deadline);
        if (ctx.minAmountOut == 0) revert ZeroMinimumAmountOut();
        _checkOracle(params);
    }

    function _checkOracle(IPoolManager.SwapParams calldata params) internal view {
        (uint256 price, uint256 updatedAt) = priceFeed.latest();
        if (price == 0) revert InvalidOraclePrice();
        if (updatedAt == 0 || updatedAt > block.timestamp) revert InvalidOracleTimestamp(updatedAt);
        if (block.timestamp - updatedAt > maxOracleAge) revert StaleOracle(updatedAt);
        uint256 implied = _normalizedLimitPrice(params.sqrtPriceLimitX96);
        uint256 diff = implied > price ? implied - price : price - implied;
        uint256 deviationBps = Math.mulDiv(diff, 10_000, price);
        if (deviationBps > maxDeviationBps) revert DeviationTooHigh(deviationBps);
    }

    /// @dev Converts the v4 raw currency1/currency0 sqrt price into a 1e18 human-unit
    ///      mark using the constructor-pinned decimals. Each multiplication is routed
    ///      through 512-bit Math.mulDiv; `sqrtP * sqrtP` is never evaluated in uint256.
    function _normalizedLimitPrice(uint160 sqrtPriceLimitX96) internal view returns (uint256 implied) {
        uint256 sqrtP = uint256(sqrtPriceLimitX96);
        uint256 decimalScale = 10 ** (uint256(CURRENCY0_DECIMALS) + 18);
        uint256 scaledSqrt = Math.mulDiv(sqrtP, decimalScale, Q96);
        uint256 direct = Math.mulDiv(scaledSqrt, sqrtP, Q96 * (10 ** uint256(CURRENCY1_DECIMALS)));
        if (direct == 0) revert InvalidImpliedPrice();
        implied = FEED_PRICE_IS_CURRENCY1_PER_CURRENCY0 ? direct : Math.mulDiv(1e18, 1e18, direct);
        if (implied == 0) revert InvalidImpliedPrice();
    }

    function _checkPoolKey(PoolKey calldata key) internal view {
        if (
            Currency.unwrap(key.currency0) != GUARDED_CURRENCY0 || Currency.unwrap(key.currency1) != GUARDED_CURRENCY1
                || key.fee != GUARDED_FEE || key.tickSpacing != GUARDED_TICK_SPACING || key.hooks != address(this)
        ) {
            revert UnexpectedPoolKey();
        }
    }

    function _checkAmountOut(IPoolManager.SwapParams calldata params, int256 delta, uint256 minAmountOut)
        internal
        pure
    {
        int128 outputDelta = params.zeroForOne ? delta.amount1() : delta.amount0();
        uint256 actualAmountOut = outputDelta > 0 ? uint256(uint128(outputDelta)) : 0;
        if (actualAmountOut < minAmountOut) revert InsufficientAmountOut(actualAmountOut, minAmountOut);
    }

    function _setGuardParams(uint256 maxOracleAge_, uint16 maxDeviationBps_, IRecibuPriceFeed feed) internal {
        if (address(feed) == address(0)) revert ZeroAddress();
        if (maxOracleAge_ == 0 || maxOracleAge_ > MAX_ORACLE_AGE_LIMIT || maxDeviationBps_ > MAX_DEVIATION_BPS_LIMIT) {
            revert InvalidGuardParams(maxOracleAge_, maxDeviationBps_);
        }
        maxOracleAge = maxOracleAge_;
        maxDeviationBps = maxDeviationBps_;
        priceFeed = feed;
        emit GuardParamsSet(maxOracleAge_, maxDeviationBps_, address(feed));
    }

    /// @dev shelf exposes workspaceFrozen(agentId) as a public mapping getter.
    function _frozen(uint256 agentId) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            address(SHELF).staticcall(abi.encodeWithSignature("workspaceFrozen(uint256)", agentId));
        if (!ok || ret.length != 32) revert FreezeLookupFailed(agentId);
        uint256 encoded;
        assembly ("memory-safe") {
            encoded := mload(add(ret, 0x20))
        }
        if (encoded > 1) revert FreezeLookupFailed(agentId);
        return encoded == 1;
    }
}

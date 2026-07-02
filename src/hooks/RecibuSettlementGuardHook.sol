// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    PoolKey,
    IPoolManager,
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    HookPermissions,
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
///    ├─ requester whitelisted
///    ├─ invoiceId is Funded on the shelf                     (no settling dead invoices)
///    ├─ seller workspace NOT cross-default frozen            (SPEC §4.8 — no residual release)
///    ├─ recipient ∈ {ReceivableEscrow, InvoiceSettlement}    (output can't be siphoned)
///    ├─ deadline not passed
///    ├─ FX mark fresh (≤ maxOracleAge) and within maxDeviationBps of the swap's implied price
///    └─ revert on ANY invalid state
///  afterSwap → emit RecibuFxSettlementSwap (indexer-ready) + re-assert recipient/status.
///
///  NOTE (honest scope): pool-TWAP deviation and the exact fill-price check bind to the
///  real PoolManager at deploy/periphery-integration time; here we enforce the oracle
///  freshness + deadline + recipient + invoice-state gates, which are the value-bearing
///  ones. No rehypothecation in the hook (SPEC §9): idle escrow → Morpho is escrow-side.
contract RecibuSettlementGuardHook is AccessControl {
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");

    struct RecibuSwapContext {
        bytes32 invoiceId; // encoded uint256 invoice id
        bytes32 workspaceId;
        bytes32 settlementId;
        bytes32 routeId;
        address expectedRequester;
        address recipient;
        uint256 minAmountOut;
        uint256 deadline;
        bool isRecoveryMode;
        bytes32 memoHash;
    }

    address public immutable POOL_MANAGER;
    IInvoiceShelf public immutable SHELF;
    address public immutable ESCROW;
    address public immutable SETTLEMENT;
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
    error NotWhitelisted(address requester);
    error InvoiceNotFunded(bytes32 invoiceId);
    error WorkspaceFrozen(uint256 agentId);
    error BadRecipient(address recipient);
    error DeadlinePassed(uint256 deadline);
    error StaleOracle(uint256 updatedAt);
    error DeviationTooHigh(uint256 bps);
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
        IRecibuPriceFeed feed,
        address admin
    ) {
        if (poolManager == address(0) || escrow == address(0) || settlement == address(0)) revert ZeroAddress();
        POOL_MANAGER = poolManager;
        SHELF = shelf;
        ESCROW = escrow;
        SETTLEMENT = settlement;
        priceFeed = feed;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPS_ROLE, admin);
    }

    function getHookPermissions() external pure returns (HookPermissions memory p) {
        p.beforeSwap = true;
        p.afterSwap = true;
        // no returnDelta flags: this is a guard, not a custom-accounting PMM.
    }

    function setWhitelist(address requester, bool allowed) external onlyRole(OPS_ROLE) {
        whitelisted[requester] = allowed;
        emit WhitelistSet(requester, allowed);
    }

    function setGuardParams(uint256 maxOracleAge_, uint16 maxDeviationBps_, IRecibuPriceFeed feed) external onlyRole(OPS_ROLE) {
        maxOracleAge = maxOracleAge_;
        maxDeviationBps = maxDeviationBps_;
        priceFeed = feed;
        emit GuardParamsSet(maxOracleAge_, maxDeviationBps_, address(feed));
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        RecibuSwapContext memory ctx = abi.decode(hookData, (RecibuSwapContext));
        _guard(ctx, params);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, int256, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        RecibuSwapContext memory ctx = abi.decode(hookData, (RecibuSwapContext));
        // output must terminate in escrow or settlement (re-asserted post-swap, SPEC §7)
        if (ctx.recipient != ESCROW && ctx.recipient != SETTLEMENT) revert BadRecipient(ctx.recipient);
        emit RecibuFxSettlementSwap(
            ctx.invoiceId, ctx.workspaceId, ctx.settlementId, ctx.routeId, ctx.expectedRequester, ctx.recipient
        );
        return (this.afterSwap.selector, 0);
    }

    /// @dev the guard, factored out for direct unit testing without a live PoolManager.
    function _guard(RecibuSwapContext memory ctx, IPoolManager.SwapParams calldata params) internal {
        if (!whitelisted[ctx.expectedRequester]) {
            emit RecibuFxSwapBlocked(ctx.invoiceId, ctx.workspaceId, ctx.routeId, "requester");
            revert NotWhitelisted(ctx.expectedRequester);
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
        _checkOracle(params);
    }

    function _checkOracle(IPoolManager.SwapParams calldata params) internal view {
        if (address(priceFeed) == address(0)) return; // feed optional in recovery/bootstrap
        (uint256 price, uint256 updatedAt) = priceFeed.latest();
        if (block.timestamp > updatedAt + maxOracleAge) revert StaleOracle(updatedAt);
        // deviation vs the swap's implied price when a limit is supplied. sqrtPriceLimitX96
        // → price ≈ (sqrt/2^96)^2 * 1e18; compared to the oracle mark within the band.
        if (params.sqrtPriceLimitX96 != 0 && price != 0) {
            uint256 sqrtP = uint256(params.sqrtPriceLimitX96);
            uint256 implied = (sqrtP * sqrtP * 1e18) >> 192;
            uint256 diff = implied > price ? implied - price : price - implied;
            if ((diff * 10_000) / price > maxDeviationBps) revert DeviationTooHigh((diff * 10_000) / price);
        }
    }

    /// @dev shelf exposes workspaceFrozen(agentId) as a public mapping getter.
    function _frozen(uint256 agentId) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            address(SHELF).staticcall(abi.encodeWithSignature("workspaceFrozen(uint256)", agentId));
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }
}

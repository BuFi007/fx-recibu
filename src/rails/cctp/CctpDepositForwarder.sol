// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ITokenMessengerV2} from "../../interfaces/ITokenMessengerV2.sol";

/**
 * @title CctpDepositForwarder
 * @notice Non-custodial, per-document USDC deposit address on Base.
 *
 *         Each live instance is a minimal proxy clone with 142 bytes of immutable args
 *         packed into the clone bytecode:
 *
 *           offset  size  field
 *           ------  ----  -----
 *            0      20    usdc              (address)
 *           20      20    tokenMessenger    (address)
 *           40       4    destinationDomain (uint32)
 *           44      32    mintRecipient     (bytes32)
 *           76      32    destinationCaller (bytes32)
 *          108       2    maxFastFeeBps     (uint16)
 *          110      32    documentCommitment (bytes32)
 *                  ---
 *                  142 bytes total
 *
 *         The implementation contract itself is permanently disabled (NotAClone guard).
 *
 * @dev Design invariants:
 *      - NO owner, NO admin, NO upgrade, NO pause, NO sweep.
 *      - No receive / fallback: native ETH sent here reverts. ETH forced in (SELFDESTRUCT,
 *        coinbase) and any token other than the bound USDC are unrecoverable BY DESIGN — adding a
 *        sweep would require an admin, and an admin could redirect funds.
 *      - No one can redirect funds: all routing params are immutable in the clone bytecode and the
 *        clone's CREATE2 address commits to them, so USDC sent to a predicted address can only
 *        ever be burned toward (destinationDomain, mintRecipient) with that destinationCaller,
 *        fee cap and hook data.
 *      - Liveness is Circle's: if USDC blacklists this address, if TokenMessengerV2's denylist
 *        covers this address (or the flushing tx.origin — any other caller can retry), if the
 *        balance exceeds TokenMinter.burnLimitsPerMessage (1e13 units = 10M USDC on Base and Base Sepolia, 2026-10-17),
 *        or if Circle ever upgrades TokenMessengerV2 to enforce a source-side minimum fee above
 *        what this clone may pay, flush() reverts and the funds STAY HERE (locked, never
 *        redirected) until the condition clears. The live Base / Base Sepolia implementations
 *        enforce no source-side minimum fee (verified 2026-10-17; pinned by the fork test).
 *      - Either finality is the caller's choice: fast pays at most maxFastFeeBps of the amount
 *        (Circle charges its actual fee, ≤ maxFee, out of the minted amount); standard pays 0.
 *        A maxFee below Circle's fast fee is accepted at source and is not a loss.
 *      - Only clones produced by CctpDepositForwarderFactory are BUFI deposit addresses. Anyone can
 *        clone this implementation with arbitrary args outside the factory; such a clone is not
 *        reachable from `factory.predict` and must never be handed to a payer.
 */
contract CctpDepositForwarder is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Magic identifier included in every hookData payload.
    bytes32 public constant FORWARDER_MAGIC = keccak256("bufi.cctp-deposit-forwarder.v1");

    /// @notice minFinalityThreshold used for fast-finality flushes.
    uint32 public constant FAST_FINALITY_THRESHOLD = 1000;

    /// @notice minFinalityThreshold used for standard-finality flushes.
    uint32 public constant STANDARD_FINALITY_THRESHOLD = 2000;

    /// @notice Absolute upper bound on maxFastFeeBps (100 bps = 1%).
    uint16 public constant MAX_FAST_FEE_BPS_CAP = 100;

    /// @notice Length of the packed immutable args every clone carries.
    uint256 public constant ARGS_LENGTH = 142;

    // -------------------------------------------------------------------------
    // Immutable — implementation identity guard
    // -------------------------------------------------------------------------

    /// @dev The address of the implementation contract itself; stored once at construction.
    ///      Any call on a clone has address(this) != _self, so the guard passes.
    ///      Any call directly on the implementation has address(this) == _self, so it reverts.
    address private immutable _self;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Called directly on the implementation contract, not on a clone.
    error NotAClone();

    /// @notice The clone's immutable args are not exactly ARGS_LENGTH bytes (not a factory clone).
    error BadArgsLength(uint256 length);

    /// @notice flush() called when USDC balance is zero.
    error NothingToFlush();

    /// @notice After depositForBurnWithHook the messenger left non-zero allowance.
    ///         This means the messenger did not consume all the approved tokens.
    error AllowanceNotConsumed();

    /// @notice After depositForBurnWithHook the forwarder still holds USDC.
    ///         This means the messenger did not burn all the approved tokens.
    error BalanceNotBurned();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when a successful flush completes.
     * @param amount              Total USDC flushed (before fees).
     * @param fast                True if fast-finality path was used.
     * @param maxFee              Maximum fee paid (0 for standard path).
     * @param destinationDomain   CCTP destination domain.
     * @param mintRecipient       Destination mint recipient (bytes32).
     * @param documentCommitment  Per-clone document commitment hash.
     */
    event Flushed(
        uint256 amount,
        bool fast,
        uint256 maxFee,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        bytes32 documentCommitment
    );

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    struct ForwarderConfig {
        address usdc;
        address tokenMessenger;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        bytes32 destinationCaller;
        uint16 maxFastFeeBps;
        bytes32 documentCommitment;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor() {
        // Lock the implementation address so clone guard works.
        _self = address(this);
    }

    // -------------------------------------------------------------------------
    // Clone-guard modifier
    // -------------------------------------------------------------------------

    /// @dev Reverts when called directly on the implementation (not through a clone).
    modifier onlyClone() {
        if (address(this) == _self) revert NotAClone();
        _;
    }

    // -------------------------------------------------------------------------
    // Core
    // -------------------------------------------------------------------------

    /**
     * @notice Flush the entire USDC balance of this forwarder to the bound destination via CCTP.
     *
     * @dev Permissionless — anyone may call this.
     *      Uses ReentrancyGuardTransient (EIP-1153) for gas-efficient reentrancy protection.
     *
     * @param fast  If true, use fast-finality path (FAST_FINALITY_THRESHOLD, non-zero maxFee).
     *              If false, use standard-finality path (STANDARD_FINALITY_THRESHOLD, maxFee = 0).
     *
     * @return amount  The USDC amount flushed.
     * @return maxFee  The maxFee passed to depositForBurnWithHook (0 for standard path).
     */
    function flush(bool fast) external nonReentrant onlyClone returns (uint256 amount, uint256 maxFee) {
        ForwarderConfig memory cfg = config();

        amount = IERC20(cfg.usdc).balanceOf(address(this));
        if (amount == 0) revert NothingToFlush();

        uint32 threshold;
        if (fast) {
            maxFee = _computeMaxFee(amount, cfg.maxFastFeeBps);
            threshold = FAST_FINALITY_THRESHOLD;
        } else {
            maxFee = 0;
            threshold = STANDARD_FINALITY_THRESHOLD;
        }

        // Approve exactly `amount` so the messenger can pull it.
        SafeERC20.forceApprove(IERC20(cfg.usdc), cfg.tokenMessenger, amount);

        // Call the messenger. The real TokenMessengerV2 will transferFrom(this, amount) then burn.
        ITokenMessengerV2(cfg.tokenMessenger)
            .depositForBurnWithHook(
                amount,
                cfg.destinationDomain,
                cfg.mintRecipient,
                cfg.usdc,
                cfg.destinationCaller,
                maxFee,
                threshold,
                abi.encode(FORWARDER_MAGIC, cfg.documentCommitment)
            );

        // Post-conditions: both must hold or the whole tx reverts.
        if (IERC20(cfg.usdc).allowance(address(this), cfg.tokenMessenger) != 0) {
            revert AllowanceNotConsumed();
        }
        if (IERC20(cfg.usdc).balanceOf(address(this)) != 0) {
            revert BalanceNotBurned();
        }

        emit Flushed(amount, fast, maxFee, cfg.destinationDomain, cfg.mintRecipient, cfg.documentCommitment);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /**
     * @notice Returns all seven immutable configuration parameters of this clone.
     */
    function config() public view onlyClone returns (ForwarderConfig memory cfg) {
        bytes memory args = Clones.fetchCloneArgs(address(this));
        cfg = _decodeArgs(args);
    }

    /**
     * @notice Returns the current USDC balance of this forwarder (i.e. the pending deposit).
     */
    function pendingAmount() external view onlyClone returns (uint256) {
        ForwarderConfig memory cfg = config();
        return IERC20(cfg.usdc).balanceOf(address(this));
    }

    /**
     * @notice Quote the maxFee that flush(fast) would use for a given amount.
     * @dev    Uses the same internal fee function as flush(); reads maxFastFeeBps from this
     *         clone's immutable args. Returns 0 for the standard path and for amount == 0.
     *
     * @param amount      Hypothetical flush amount.
     * @param fast        True for fast path, false for standard.
     * @return maxFeeOut  The maxFee that would be passed to depositForBurnWithHook.
     */
    function quoteMaxFee(uint256 amount, bool fast) external view onlyClone returns (uint256 maxFeeOut) {
        if (!fast) return 0;
        ForwarderConfig memory cfg = config();
        return _computeMaxFee(amount, cfg.maxFastFeeBps);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /**
     * @dev Decode the 142-byte immutable args into a ForwarderConfig.
     *
     *   offset  size  field
     *   ------  ----  -----
     *    0      20    usdc
     *   20      20    tokenMessenger
     *   40       4    destinationDomain
     *   44      32    mintRecipient
     *   76      32    destinationCaller
     *  108       2    maxFastFeeBps
     *  110      32    documentCommitment
     */
    function _decodeArgs(bytes memory args) internal pure returns (ForwarderConfig memory cfg) {
        if (args.length != ARGS_LENGTH) revert BadArgsLength(args.length);
        address usdc;
        address tokenMessenger;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        bytes32 destinationCaller;
        uint16 maxFastFeeBps;
        bytes32 documentCommitment;

        assembly ("memory-safe") {
            // args data starts at args + 0x20 (skip length slot)
            let ptr := add(args, 0x20)

            // address usdc: 20 bytes at offset 0 — right-aligned in 32-byte word
            usdc := shr(96, mload(ptr))

            // address tokenMessenger: 20 bytes at offset 20
            tokenMessenger := shr(96, mload(add(ptr, 20)))

            // uint32 destinationDomain: 4 bytes at offset 40 — right-aligned
            destinationDomain := shr(224, mload(add(ptr, 40)))

            // bytes32 mintRecipient: 32 bytes at offset 44
            mintRecipient := mload(add(ptr, 44))

            // bytes32 destinationCaller: 32 bytes at offset 76
            destinationCaller := mload(add(ptr, 76))

            // uint16 maxFastFeeBps: 2 bytes at offset 108 — right-aligned
            maxFastFeeBps := shr(240, mload(add(ptr, 108)))

            // bytes32 documentCommitment: 32 bytes at offset 110
            documentCommitment := mload(add(ptr, 110))
        }

        cfg.usdc = usdc;
        cfg.tokenMessenger = tokenMessenger;
        cfg.destinationDomain = destinationDomain;
        cfg.mintRecipient = mintRecipient;
        cfg.destinationCaller = destinationCaller;
        cfg.maxFastFeeBps = maxFastFeeBps;
        cfg.documentCommitment = documentCommitment;
    }

    /**
     * @dev Compute maxFee for the fast path:
     *        maxFee = ceil(amount * bps / 10_000)
     *      Special case: if the computed maxFee >= amount, clamp to amount - 1
     *      (so at least 1 unit always passes through; if amount == 1 this gives maxFee = 0).
     */
    function _computeMaxFee(uint256 amount, uint16 bps) internal pure returns (uint256 maxFee) {
        if (amount == 0) return 0;
        maxFee = Math.mulDiv(amount, bps, 10_000, Math.Rounding.Ceil);
        if (maxFee >= amount) {
            maxFee = amount - 1;
        }
    }
}

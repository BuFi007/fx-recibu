// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @dev Adapted-with-hardening from circlefin/refund-protocol (Apache-2.0). Upstream had
///      early-withdrawal / arbiter-custody risk (docs/THREAT_MODEL.md T5); this redesign
///      removes the arbitrary-withdrawal path entirely and binds EVERY movement to an
///      invoiceId, so an arbiter can never touch funds for an unrelated invoice.
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ReceivableEscrow — invoice-bound custody for debtor repayments (M5, SPEC §5.3)
///
///  debtor ──deposit(invoiceId, amt)──▶ escrowedOf[invoiceId] += amt   (invoice-bound)
///  SETTLEMENT_ROLE ──releaseTo(invoiceId, to, amt)──▶ funds ONLY for that invoiceId
///  ARBITER_ROLE ──refund(invoiceId, to, amt)──▶ ONLY that invoiceId, ONLY after lockup
///
/// Hardening invariants (test/unit + invariant):
///   - no function moves funds without an invoiceId argument;
///   - releaseTo/refund can never send more than escrowedOf[invoiceId];
///   - the arbiter has NO custody path that isn't invoice-scoped (kills the upstream bug);
///   - Σ escrowedOf == USDC held (no phantom escrow).
contract ReceivableEscrow is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 public constant ARBITER_ROLE = keccak256("ARBITER_ROLE"); // dispute refunds only, invoice-scoped
    bytes32 public constant ROUTER_ROLE = keccak256("ROUTER_ROLE"); // InvoiceMemoRouter deposits

    IERC20 public immutable USDC;

    mapping(uint256 => uint256) public escrowedOf; // invoiceId → held USDC
    mapping(uint256 => uint64) public refundUnlockAt; // invoiceId → earliest refund time
    uint256 public totalEscrowed; // Σ escrowedOf (idle-yield accounting anchor, SPEC §5.3)

    event Deposited(uint256 indexed invoiceId, address indexed from, uint256 amount);
    event Released(uint256 indexed invoiceId, address indexed to, uint256 amount);
    event Refunded(uint256 indexed invoiceId, address indexed to, uint256 amount);
    event RefundLockSet(uint256 indexed invoiceId, uint64 unlockAt);

    error ZeroAmount();
    error InsufficientEscrow(uint256 invoiceId, uint256 have, uint256 want);
    error RefundLocked(uint256 invoiceId, uint64 unlockAt);

    constructor(IERC20 usdc, address admin) {
        USDC = usdc;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice bind a repayment to an invoice. Caller (router) has already collected/approved.
    function deposit(uint256 invoiceId, uint256 amount, address from) external onlyRole(ROUTER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        USDC.safeTransferFrom(from, address(this), amount);
        escrowedOf[invoiceId] += amount;
        totalEscrowed += amount;
        emit Deposited(invoiceId, from, amount);
    }

    /// @notice per-tier refund lockup (SPEC §5.3): set the earliest time a dispute refund
    ///         may fire for this invoice. Set by the router/settlement at deposit time.
    function setRefundLock(uint256 invoiceId, uint64 unlockAt) external onlyRole(ROUTER_ROLE) {
        refundUnlockAt[invoiceId] = unlockAt;
        emit RefundLockSet(invoiceId, unlockAt);
    }

    /// @notice settlement pulls escrowed funds for THIS invoice only, toward its outstanding.
    function releaseTo(uint256 invoiceId, address to, uint256 amount) external onlyRole(SETTLEMENT_ROLE) nonReentrant {
        _debit(invoiceId, amount);
        USDC.safeTransfer(to, amount);
        emit Released(invoiceId, to, amount);
    }

    /// @notice dispute refund — invoice-scoped, arbiter-gated, and never before the lockup.
    ///         The arbiter can ONLY move funds already escrowed for this exact invoiceId.
    function refund(uint256 invoiceId, address to, uint256 amount) external onlyRole(ARBITER_ROLE) nonReentrant {
        uint64 unlock = refundUnlockAt[invoiceId];
        if (block.timestamp < unlock) revert RefundLocked(invoiceId, unlock);
        _debit(invoiceId, amount);
        USDC.safeTransfer(to, amount);
        emit Refunded(invoiceId, to, amount);
    }

    function _debit(uint256 invoiceId, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        uint256 have = escrowedOf[invoiceId];
        if (amount > have) revert InsufficientEscrow(invoiceId, have, amount);
        escrowedOf[invoiceId] = have - amount;
        totalEscrowed -= amount;
    }
}

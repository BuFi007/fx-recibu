// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MultiTokenReceivableEscrow — invoice-bound custody for debtor repayments, any
///        admin-allowlisted settlement token (Midnight hub; plan §11.C).
/// @notice Same hardening as ReceivableEscrow, generalized to N tokens:
///   - every invoice is bound to ONE token on its first deposit (`tokenOf`), later deposits
///     in another token revert, so `escrowedOf(invoiceId)` stays a single-asset amount;
///   - no function moves funds without an invoiceId; release/refund ≤ escrowedOf[invoiceId];
///   - Σ escrowedOf over invoices of token T == totalEscrowedOf[T] ≤ T.balanceOf(this).
///   SETTLEMENT_ROLE is reserved for the Midnight repay adapter (escrow → Midnight.repay).
contract MultiTokenReceivableEscrow is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 public constant ARBITER_ROLE = keccak256("ARBITER_ROLE");
    bytes32 public constant ROUTER_ROLE = keccak256("ROUTER_ROLE");

    mapping(address token => bool) public supportedToken;
    mapping(uint256 invoiceId => address) public tokenOf;
    mapping(uint256 invoiceId => uint256) public escrowedOf;
    mapping(uint256 invoiceId => uint64) public refundUnlockAt;
    mapping(address token => uint256) public totalEscrowedOf;

    event TokenSupported(address indexed token, bool supported);
    event Deposited(uint256 indexed invoiceId, address indexed token, address indexed from, uint256 amount);
    event Released(uint256 indexed invoiceId, address indexed token, address indexed to, uint256 amount);
    event Refunded(uint256 indexed invoiceId, address indexed token, address indexed to, uint256 amount);
    event RefundLockSet(uint256 indexed invoiceId, uint64 unlockAt);

    error ZeroAddress();
    error ZeroAmount();
    error TokenNotSupported(address token);
    error InvoiceTokenMismatch(uint256 invoiceId, address bound, address given);
    error InsufficientEscrow(uint256 invoiceId, uint256 have, uint256 want);
    error RefundLocked(uint256 invoiceId, uint64 unlockAt);
    error BalanceMismatch();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice enabling is free; disabling only blocks NEW deposits (existing funds stay releasable).
    function setToken(address token, bool supported) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        supportedToken[token] = supported;
        emit TokenSupported(token, supported);
    }

    function deposit(uint256 invoiceId, address token, uint256 amount, address from)
        external
        onlyRole(ROUTER_ROLE)
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        if (!supportedToken[token]) revert TokenNotSupported(token);
        address bound = tokenOf[invoiceId];
        if (bound == address(0)) tokenOf[invoiceId] = token;
        else if (bound != token) revert InvoiceTokenMismatch(invoiceId, bound, token);
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) != before + amount) revert BalanceMismatch(); // no fee-on-transfer
        escrowedOf[invoiceId] += amount;
        totalEscrowedOf[token] += amount;
        emit Deposited(invoiceId, token, from, amount);
    }

    function setRefundLock(uint256 invoiceId, uint64 unlockAt) external onlyRole(ROUTER_ROLE) {
        refundUnlockAt[invoiceId] = unlockAt;
        emit RefundLockSet(invoiceId, unlockAt);
    }

    function releaseTo(uint256 invoiceId, address to, uint256 amount) external onlyRole(SETTLEMENT_ROLE) nonReentrant {
        address token = _debit(invoiceId, amount);
        IERC20(token).safeTransfer(to, amount);
        emit Released(invoiceId, token, to, amount);
    }

    function refund(uint256 invoiceId, address to, uint256 amount) external onlyRole(ARBITER_ROLE) nonReentrant {
        uint64 unlock = refundUnlockAt[invoiceId];
        if (block.timestamp < unlock) revert RefundLocked(invoiceId, unlock);
        address token = _debit(invoiceId, amount);
        IERC20(token).safeTransfer(to, amount);
        emit Refunded(invoiceId, token, to, amount);
    }

    function _debit(uint256 invoiceId, uint256 amount) internal returns (address token) {
        if (amount == 0) revert ZeroAmount();
        uint256 have = escrowedOf[invoiceId];
        if (amount > have) revert InsufficientEscrow(invoiceId, have, amount);
        token = tokenOf[invoiceId];
        escrowedOf[invoiceId] = have - amount;
        totalEscrowedOf[token] -= amount;
    }
}

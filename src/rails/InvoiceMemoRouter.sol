// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @dev Adapted from circlefin/recibo (Apache-2.0): the structured-memo binding pattern.
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IInvoiceShelf} from "../interfaces/IInvoiceShelf.sol";
import {InvoiceInstallmentKey} from "../libraries/InvoiceInstallmentKey.sol";
import {ReceivableEscrow} from "./ReceivableEscrow.sol";

/// @title InvoiceMemoRouter — the Arc-Memo-shaped repayment front door (M5, SPEC §5.1)
///
///  debtor ──pay(invoiceId, installment, amount)──▶ pull USDC ──▶ ReceivableEscrow.deposit
///        │  memoId = keccak256(invoiceId ‖ installment)  (Arc Memo reconciliation key)
///        ▼
///  emits RecibuPayment{invoiceId, installment, memoId, amount, from} — the on-chain twin
///  of the Arc `Memo` event, so the passport's settlement ground truth (SPEC_CREDIT_PASSPORT
///  §P1 source 5) reads identically whether paid on-chain here or via the Memo predeploy.
///
/// Guarded: only funded invoices accept payment; unmatched/expired invoices revert rather
/// than quarantining (on-chain path is stricter than the raw predeploy).
contract InvoiceMemoRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;
    IInvoiceShelf public immutable SHELF;
    ReceivableEscrow public immutable ESCROW;

    event RecibuPayment(
        uint256 indexed invoiceId, uint8 indexed installment, bytes32 indexed memoId, uint256 amount, address from
    );

    error InvoiceNotFunded(uint256 invoiceId);
    error InstallmentMismatch(uint256 invoiceId, uint8 supplied, uint8 expected);
    error InvalidInstallmentAccounting(uint256 invoiceId, uint256 fullAmount, uint256 paidAmount);
    error PaymentExceedsInstallmentRemaining(
        uint256 invoiceId, uint256 attemptedAmount, uint256 shelfRemaining, uint256 pendingEscrow
    );
    error InvalidRefundWindow(uint256 invoiceId, uint256 maturity, uint256 graceEndsAt);
    error RefundUnlockOverflow(uint256 invoiceId, uint256 depositTimestamp, uint256 lockDuration);
    error SettlementTokenMismatch(address token, address expectedToken);
    error CanonicalEscrowMismatch(address escrow, address expectedEscrow);
    error UnauthorizedPayer(uint256 invoiceId, address payer, address expectedPayer);
    error ZeroAmount();

    constructor(IERC20 usdc, IInvoiceShelf shelf, ReceivableEscrow escrow) {
        address shelfToken = shelf.USDC();
        if (address(usdc) != shelfToken) revert SettlementTokenMismatch(address(usdc), shelfToken);
        address escrowToken = address(escrow.USDC());
        if (escrowToken != shelfToken) revert SettlementTokenMismatch(escrowToken, shelfToken);
        USDC = usdc;
        SHELF = shelf;
        ESCROW = escrow;
    }

    /// @notice the memoId is the canonical Arc-Memo reconciliation key for this installment.
    function memoIdOf(uint256 invoiceId, uint8 installment) public pure returns (bytes32) {
        return InvoiceInstallmentKey.memoId(invoiceId, installment);
    }

    /// @notice pay an installment. Pulls USDC from the debtor and binds it in escrow to the
    ///         invoice; settlement applies it out-of-band (keeps this path minimal + safe).
    function pay(uint256 invoiceId, uint8 installment, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        address shelfEscrow = SHELF.escrow();
        if (shelfEscrow != address(ESCROW)) revert CanonicalEscrowMismatch(address(ESCROW), shelfEscrow);
        if (SHELF.invoiceStatus(invoiceId) != IInvoiceShelf.Status.Funded) revert InvoiceNotFunded(invoiceId);
        address expectedPayer = SHELF.debtorPayerOf(invoiceId);
        if (msg.sender != expectedPayer) revert UnauthorizedPayer(invoiceId, msg.sender, expectedPayer);
        (uint8 expectedInstallment, uint256 fullAmount, uint256 paidAmount, uint256 maturity, uint256 graceEndsAt) =
            SHELF.currentInstallment(invoiceId);
        if (installment != expectedInstallment) {
            revert InstallmentMismatch(invoiceId, installment, expectedInstallment);
        }
        if (paidAmount > fullAmount) revert InvalidInstallmentAccounting(invoiceId, fullAmount, paidAmount);
        uint256 shelfRemaining = fullAmount - paidAmount;
        uint256 pendingEscrow = ESCROW.escrowedOf(invoiceId);
        if (pendingEscrow > shelfRemaining || amount > shelfRemaining - pendingEscrow) {
            revert PaymentExceedsInstallmentRemaining(invoiceId, amount, shelfRemaining, pendingEscrow);
        }
        if (graceEndsAt <= maturity) revert InvalidRefundWindow(invoiceId, maturity, graceEndsAt);
        uint256 lockDuration = graceEndsAt - maturity;
        if (lockDuration > type(uint64).max || block.timestamp > type(uint64).max - lockDuration) {
            revert RefundUnlockOverflow(invoiceId, block.timestamp, lockDuration);
        }
        uint64 refundUnlockAt = uint64(block.timestamp + lockDuration);

        // Pull to the router, then atomically bind custody and the shelf-authoritative
        // installment grace boundary (router holds ROUTER_ROLE on escrow).
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        USDC.forceApprove(address(ESCROW), amount);
        ESCROW.depositWithRefundLock(invoiceId, amount, address(this), refundUnlockAt);

        emit RecibuPayment(invoiceId, installment, memoIdOf(invoiceId, installment), amount, msg.sender);
    }
}

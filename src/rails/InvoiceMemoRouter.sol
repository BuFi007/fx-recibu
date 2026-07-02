// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @dev Adapted from circlefin/recibo (Apache-2.0): the structured-memo binding pattern.
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IInvoiceShelf} from "../interfaces/IInvoiceShelf.sol";
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
    error ZeroAmount();

    constructor(IERC20 usdc, IInvoiceShelf shelf, ReceivableEscrow escrow) {
        USDC = usdc;
        SHELF = shelf;
        ESCROW = escrow;
    }

    /// @notice the memoId is the canonical Arc-Memo reconciliation key for this installment.
    function memoIdOf(uint256 invoiceId, uint8 installment) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(invoiceId, installment));
    }

    /// @notice pay an installment. Pulls USDC from the debtor and binds it in escrow to the
    ///         invoice; settlement applies it out-of-band (keeps this path minimal + safe).
    function pay(uint256 invoiceId, uint8 installment, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (SHELF.invoiceStatus(invoiceId) != IInvoiceShelf.Status.Funded) revert InvoiceNotFunded(invoiceId);

        // pull to router, then deposit into escrow (router holds ROUTER_ROLE on escrow)
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        USDC.forceApprove(address(ESCROW), amount);
        ESCROW.deposit(invoiceId, amount, address(this));

        emit RecibuPayment(invoiceId, installment, memoIdOf(invoiceId, installment), amount, msg.sender);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IInvoiceShelf} from "../interfaces/IInvoiceShelf.sol";
import {ReceivableEscrow} from "./ReceivableEscrow.sol";

/// @title InvoiceSettlement — the orchestrator that moves escrowed cash into the shelf (M5)
///
///  keeper/servicer ──settle(invoiceId)──▶ release escrowedOf[invoiceId] to self
///        │                                approve shelf, applyPaymentFrom(invoiceId, amt, self)
///        ▼                                (shelf applies to earliest installment, books
///  escrow drained for this invoice          on-time reputation, runs waterfall on shortfall)
///
/// Holds ESCROW.SETTLEMENT_ROLE and SHELF.SETTLEMENT_ROLE. Never custodies beyond a single
/// atomic settle() call. Idle-escrow → Morpho supply is a SPEC §5.3 follow-up wired on the
/// escrow side; the settlement path stays a thin, auditable mover.
contract InvoiceSettlement is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    IERC20 public immutable USDC;
    IInvoiceShelf public immutable SHELF;
    ReceivableEscrow public immutable ESCROW;

    event Settled(uint256 indexed invoiceId, uint256 amountApplied);
    event PendingSettledAndDefaultEvaluated(uint256 indexed invoiceId, uint256 amountApplied, bool defaulted);

    error NothingEscrowed(uint256 invoiceId);
    error NotFunded(uint256 invoiceId);
    error DefaultWindowNotOpen(uint256 invoiceId, uint256 graceEndsAt, uint256 currentTimestamp);

    constructor(IERC20 usdc, IInvoiceShelf shelf, ReceivableEscrow escrow, address admin) {
        USDC = usdc;
        SHELF = shelf;
        ESCROW = escrow;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, admin);
    }

    /// @notice apply all currently-escrowed cash for an invoice to its outstanding balance.
    function settle(uint256 invoiceId) external onlyRole(KEEPER_ROLE) nonReentrant returns (uint256 amount) {
        if (SHELF.invoiceStatus(invoiceId) != IInvoiceShelf.Status.Funded) revert NotFunded(invoiceId);
        amount = ESCROW.escrowedOf(invoiceId);
        if (amount == 0) revert NothingEscrowed(invoiceId);

        _settlePending(invoiceId, amount);
    }

    /// @notice Apply an objective default after grace, atomically settling canonical escrow first.
    /// @dev The zero-escrow path is permissionless. Moving pending debtor cash remains a
    ///      KEEPER_ROLE action, preserving the escrow settlement/refund authority split while
    ///      still giving the trusted keeper one atomic dust-cure/default transaction.
    function settlePendingAndMarkDefaulted(uint256 invoiceId)
        external
        nonReentrant
        returns (uint256 amountApplied, bool defaulted)
    {
        if (SHELF.invoiceStatus(invoiceId) != IInvoiceShelf.Status.Funded) revert NotFunded(invoiceId);

        // This entry point is permissionless only because default eligibility is
        // objective. It must not become a second, permissionless settlement path
        // while escrowed cash is still inside its ordinary dispute/refund window.
        (,,,, uint256 currentGraceEndsAt) = SHELF.currentInstallment(invoiceId);
        if (block.timestamp <= currentGraceEndsAt) {
            revert DefaultWindowNotOpen(invoiceId, currentGraceEndsAt, block.timestamp);
        }

        amountApplied = ESCROW.escrowedOf(invoiceId);
        if (amountApplied == 0) {
            // Preserve fail-closed DEFAULT semantics: before grace the shelf reverts,
            // so a CRE operation is not consumed as a successful no-op.
            SHELF.markDefaulted(invoiceId);
            emit PendingSettledAndDefaultEvaluated(invoiceId, 0, true);
            return (0, true);
        }
        _checkRole(KEEPER_ROLE, msg.sender);
        _settlePending(invoiceId, amountApplied);

        IInvoiceShelf.Status status = SHELF.invoiceStatus(invoiceId);
        if (status == IInvoiceShelf.Status.Settled) {
            emit PendingSettledAndDefaultEvaluated(invoiceId, amountApplied, false);
            return (amountApplied, false);
        }
        if (status != IInvoiceShelf.Status.Funded) revert NotFunded(invoiceId);

        (,,,, uint256 graceEndsAt) = SHELF.currentInstallment(invoiceId);
        if (block.timestamp > graceEndsAt) {
            SHELF.markDefaulted(invoiceId);
            defaulted = true;
        }

        emit PendingSettledAndDefaultEvaluated(invoiceId, amountApplied, defaulted);
    }

    function _settlePending(uint256 invoiceId, uint256 amount) internal {
        ESCROW.releaseTo(invoiceId, address(this), amount);
        USDC.forceApprove(address(SHELF), amount);
        SHELF.applyPaymentFrom(invoiceId, amount, address(this));
        emit Settled(invoiceId, amount);
    }
}

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

    error NothingEscrowed(uint256 invoiceId);
    error NotFunded(uint256 invoiceId);

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

        ESCROW.releaseTo(invoiceId, address(this), amount);
        USDC.forceApprove(address(SHELF), amount);
        SHELF.applyPaymentFrom(invoiceId, amount, address(this));
        emit Settled(invoiceId, amount);
    }
}

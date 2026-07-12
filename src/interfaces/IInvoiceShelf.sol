// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @title IInvoiceShelf — the slice of InvoiceShelf that the settlement rails need.
interface IInvoiceShelf {
    enum Status {
        None,
        Funded,
        Settled,
        Defaulted
    }

    function applyPaymentFrom(uint256 invoiceId, uint256 amount, address payer) external;
    function USDC() external view returns (address);
    function escrow() external view returns (address);
    function invoiceStatus(uint256 invoiceId) external view returns (Status);
    function sellerAgentIdOf(uint256 invoiceId) external view returns (uint256);
    function debtorPayerOf(uint256 invoiceId) external view returns (address);

    /// @notice Permissionless objective default transition after the current
    ///         installment's grace window, provided no debtor cash is pending escrow.
    function markDefaulted(uint256 invoiceId) external;

    /// @notice Return the shelf-authoritative earliest incomplete installment.
    /// @dev Reverts when the invoice is not funded or has no open installment.
    function currentInstallment(uint256 invoiceId)
        external
        view
        returns (uint8 index, uint256 fullAmount, uint256 paidAmount, uint256 maturity, uint256 graceEndsAt);
}

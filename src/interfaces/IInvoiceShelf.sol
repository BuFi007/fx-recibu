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
    function invoiceStatus(uint256 invoiceId) external view returns (Status);
    function sellerAgentIdOf(uint256 invoiceId) external view returns (uint256);
}

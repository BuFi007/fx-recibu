// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @title InvoiceInstallmentKey — canonical correlation key for invoice payment rails.
/// @dev Encoding only. Schedule, progress and payment authority remain in InvoiceShelf.
library InvoiceInstallmentKey {
    function memoId(uint256 invoiceId, uint8 installment) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(invoiceId, installment));
    }
}

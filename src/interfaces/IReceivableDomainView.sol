// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @title IReceivableDomainView — canonical funded-evidence read boundary
interface IReceivableDomainView {
    struct FundingEvidence {
        uint16 schemaVersion;
        bytes32 verifierConfigId;
        bytes32 authorityInvoiceId;
        bytes32 authorityEvidenceCommitment;
        bytes32 receivableCommitment;
        bytes32 documentCommitment;
        bool consumed;
    }

    function fundingEvidence(uint256 invoiceId) external view returns (FundingEvidence memory);
    function invoiceIdOfAuthorityInvoiceId(bytes32 authorityInvoiceId) external view returns (uint256);
    function invoiceIdOfReceivableCommitment(bytes32 receivableCommitment) external view returns (uint256);
}

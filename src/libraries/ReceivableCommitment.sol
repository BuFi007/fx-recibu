// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {BINV} from "../invoice/BINV.sol";

/// @title ReceivableCommitment — canonical, versioned identity for one financed receivable
/// @notice The authority invoice ID is derived from Fantasmita's canonical invoice commitment
///         hash. It can never be substituted with a PDF, CRE operation, or local database ID.
library ReceivableCommitment {
    uint16 internal constant VERSION = 1;
    bytes32 internal constant DOMAIN = keccak256("BUFI_FX_RECIBU_RECEIVABLE_COMMITMENT_V1");
    bytes32 internal constant DOCUMENT_BUNDLE_DOMAIN = keccak256("BUFI_FX_RECIBU_DOCUMENT_BUNDLE_V1");
    bytes32 internal constant AUTHORITY_INVOICE_ID_DOMAIN = keccak256("BUFI_ARCA_FACTURA_E_AUTHORITY_INVOICE_ID_V1");

    struct Terms {
        bytes32 canonicalInvoiceCommitmentHash;
        uint64 issuedAt;
        uint64 dueAt;
    }

    function authorityInvoiceId(bytes32 canonicalInvoiceCommitmentHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(AUTHORITY_INVOICE_ID_DOMAIN, uint16(1), canonicalInvoiceCommitmentHash));
    }

    function compute(
        uint256 chainId,
        uint256 sellerAgentId,
        uint256 debtorAgentId,
        address currency,
        uint128 faceAmount,
        Terms memory terms,
        bytes32 assignmentHash
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN,
                VERSION,
                chainId,
                sellerAgentId,
                debtorAgentId,
                authorityInvoiceId(terms.canonicalInvoiceCommitmentHash),
                currency,
                faceAmount,
                terms.issuedAt,
                terms.dueAt,
                assignmentHash
            )
        );
    }

    function hashDocumentBundle(BINV.DocBundle memory docs) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                DOCUMENT_BUNDLE_DOMAIN,
                VERSION,
                docs.invoiceDocHash,
                docs.assignmentHash,
                docs.paymentInstructionHash,
                docs.servicingPolicyHash,
                docs.disputePolicyHash
            )
        );
    }
}

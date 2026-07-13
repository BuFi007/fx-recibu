// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {BINV} from "../invoice/BINV.sol";

/// @title ReceivableCommitment — canonical v1 authority and funding bindings
/// @notice Keeps the chain-independent authority identity separate from the
///         chain/domain-specific funded receivable and its legal documents.
library ReceivableCommitment {
    bytes32 internal constant RECEIVABLE_DOMAIN = keccak256("BUFI_FX_RECIBU_RECEIVABLE_V1");
    bytes32 internal constant DOCUMENT_DOMAIN = keccak256("BUFI_FX_RECIBU_DOCUMENT_BUNDLE_V1");
    uint16 internal constant VERSION = 1;

    struct AuthorityRef {
        uint16 schemaVersion;
        bytes32 authorityInvoiceId;
        bytes32 authorityEvidenceCommitment;
        bytes32 verifierConfigId;
        uint8 authorityVoucherType;
        uint64 issuedAt;
        uint64 authorityPaymentDueAt;
    }

    struct FundingTerms {
        AuthorityRef authority;
        bool recourse;
    }

    struct ScheduleTerms {
        uint8 nInstallments;
        uint64 firstMaturity;
        uint32 interval;
        uint32 grace;
    }

    struct ComputedFundingTerms {
        uint16 advanceRateBps;
        uint128 advanceAmount;
        uint128 holdbackAmount;
        uint8 tranche;
    }

    /// @dev A static tuple avoids compiler stack pressure while preserving the
    ///      exact flattened ABI encoding pinned by the v1 golden vector.
    struct ReceivablePreimage {
        bytes32 domain;
        uint16 version;
        uint256 chainId;
        address invoiceShelf;
        uint256 sellerAgentId;
        uint256 debtorAgentId;
        bytes32 authorityInvoiceId;
        bytes32 authorityEvidenceCommitment;
        bytes32 verifierConfigId;
        uint8 authorityVoucherType;
        address currency;
        uint128 faceAmount;
        bool recourse;
        uint16 advanceRateBps;
        uint128 advanceAmount;
        uint128 holdbackAmount;
        uint64 issuedAt;
        uint64 authorityPaymentDueAt;
        uint8 nInstallments;
        uint64 firstMaturity;
        uint32 interval;
        uint32 grace;
        uint8 tranche;
        bytes32 assignmentHash;
    }

    function hashReceivable(
        uint256 chainId,
        address invoiceShelf,
        uint256 sellerAgentId,
        uint256 debtorAgentId,
        address currency,
        uint128 faceAmount,
        FundingTerms memory terms,
        ScheduleTerms memory schedule,
        ComputedFundingTerms memory computed,
        bytes32 assignmentHash
    ) internal pure returns (bytes32) {
        ReceivablePreimage memory preimage = ReceivablePreimage({
            domain: RECEIVABLE_DOMAIN,
            version: VERSION,
            chainId: chainId,
            invoiceShelf: invoiceShelf,
            sellerAgentId: sellerAgentId,
            debtorAgentId: debtorAgentId,
            authorityInvoiceId: terms.authority.authorityInvoiceId,
            authorityEvidenceCommitment: terms.authority.authorityEvidenceCommitment,
            verifierConfigId: terms.authority.verifierConfigId,
            authorityVoucherType: terms.authority.authorityVoucherType,
            currency: currency,
            faceAmount: faceAmount,
            recourse: terms.recourse,
            advanceRateBps: computed.advanceRateBps,
            advanceAmount: computed.advanceAmount,
            holdbackAmount: computed.holdbackAmount,
            issuedAt: terms.authority.issuedAt,
            authorityPaymentDueAt: terms.authority.authorityPaymentDueAt,
            nInstallments: schedule.nInstallments,
            firstMaturity: schedule.firstMaturity,
            interval: schedule.interval,
            grace: schedule.grace,
            tranche: computed.tranche,
            assignmentHash: assignmentHash
        });
        return keccak256(abi.encode(preimage));
    }

    function hashDocumentBundle(AuthorityRef memory authority, BINV.DocBundle memory docs, bool recourse)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                DOCUMENT_DOMAIN,
                VERSION,
                authority.authorityInvoiceId,
                authority.authorityVoucherType,
                docs.invoiceDocHash,
                docs.assignmentHash,
                docs.paymentInstructionHash,
                docs.servicingPolicyHash,
                docs.disputePolicyHash,
                recourse
            )
        );
    }
}

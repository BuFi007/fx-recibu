// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {BINV} from "../../src/invoice/BINV.sol";
import {ReceivableCommitment} from "../../src/libraries/ReceivableCommitment.sol";

contract ReceivableCommitmentTest is Test {
    struct GoldenReceivable {
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

    uint256 internal constant CHAIN_ID = 5_042_002;
    address internal constant SHELF = 0x1111111111111111111111111111111111111111;
    address internal constant CURRENCY = 0x2222222222222222222222222222222222222222;
    uint256 internal constant SELLER = 101;
    uint256 internal constant DEBTOR = 202;
    uint128 internal constant FACE = 1_000_000_000;
    bytes32 internal constant AUTHORITY_ID = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
    bytes32 internal constant EVIDENCE = 0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;
    bytes32 internal constant CONFIG = 0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc;
    bytes32 internal constant ASSIGNMENT = 0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd;

    function test_domainConstantsAndVersionArePinned() public pure {
        assertEq(
            ReceivableCommitment.RECEIVABLE_DOMAIN, 0x49385b4266c49996eacbc5bd06bca8c63684a02c863914baaa554513aa983a3f
        );
        assertEq(
            ReceivableCommitment.DOCUMENT_DOMAIN, 0x29e20b268db4ae20ab8646be4f1d600213a14a7defce68fda440e2e93d4d05f0
        );
        assertEq(ReceivableCommitment.VERSION, 1);
    }

    function test_receivableGoldenVectorIsIndependentlyEncoded() public pure {
        ReceivableCommitment.FundingTerms memory terms = _terms();
        ReceivableCommitment.ScheduleTerms memory schedule = _schedule();
        ReceivableCommitment.ComputedFundingTerms memory computed = _computed();

        GoldenReceivable memory golden = GoldenReceivable({
            domain: 0x49385b4266c49996eacbc5bd06bca8c63684a02c863914baaa554513aa983a3f,
            version: 1,
            chainId: 5_042_002,
            invoiceShelf: 0x1111111111111111111111111111111111111111,
            sellerAgentId: 101,
            debtorAgentId: 202,
            authorityInvoiceId: 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,
            authorityEvidenceCommitment: 0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,
            verifierConfigId: 0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc,
            authorityVoucherType: 19,
            currency: 0x2222222222222222222222222222222222222222,
            faceAmount: 1_000_000_000,
            recourse: true,
            advanceRateBps: 8_000,
            advanceAmount: 800_000_000,
            holdbackAmount: 200_000_000,
            issuedAt: 1_780_000_000,
            authorityPaymentDueAt: 1_782_592_000,
            nInstallments: 4,
            firstMaturity: 1_780_648_000,
            interval: 648_000,
            grace: 432_000,
            tranche: 0,
            assignmentHash: 0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
        });
        bytes32 expected = keccak256(abi.encode(golden));

        assertEq(expected, 0x829261aa91a44479007c08156fc76e3da44676c422081e816b6d3455227d097a);
        assertEq(
            _hash(CHAIN_ID, SHELF, SELLER, DEBTOR, CURRENCY, FACE, terms, schedule, computed, ASSIGNMENT), expected
        );
    }

    function test_documentGoldenVectorIsIndependentlyEncoded() public pure {
        ReceivableCommitment.AuthorityRef memory authority = _authority();
        BINV.DocBundle memory docs = _goldenDocs();
        bytes32 expected = keccak256(
            abi.encode(
                bytes32(0x29e20b268db4ae20ab8646be4f1d600213a14a7defce68fda440e2e93d4d05f0),
                uint16(1),
                bytes32(0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa),
                uint8(19),
                bytes32(0x1111111111111111111111111111111111111111111111111111111111111111),
                bytes32(0x2222222222222222222222222222222222222222222222222222222222222222),
                bytes32(0x3333333333333333333333333333333333333333333333333333333333333333),
                bytes32(0x4444444444444444444444444444444444444444444444444444444444444444),
                bytes32(0x5555555555555555555555555555555555555555555555555555555555555555),
                true
            )
        );

        assertEq(expected, 0xc1d9671c9008465eb2b8c5d92de40dbaef60975ee33f9a9a6777cbdc4f3902bc);
        assertEq(ReceivableCommitment.hashDocumentBundle(authority, docs, true), expected);
    }

    function test_everyReceivableFieldIsSensitive() public pure {
        ReceivableCommitment.FundingTerms memory terms = _terms();
        ReceivableCommitment.ScheduleTerms memory schedule = _schedule();
        ReceivableCommitment.ComputedFundingTerms memory computed = _computed();
        bytes32 base = _hash(CHAIN_ID, SHELF, SELLER, DEBTOR, CURRENCY, FACE, terms, schedule, computed, ASSIGNMENT);

        _different(
            base, _hash(CHAIN_ID + 1, SHELF, SELLER, DEBTOR, CURRENCY, FACE, terms, schedule, computed, ASSIGNMENT)
        );
        _different(
            base,
            _hash(CHAIN_ID, address(0x3333), SELLER, DEBTOR, CURRENCY, FACE, terms, schedule, computed, ASSIGNMENT)
        );
        _different(
            base, _hash(CHAIN_ID, SHELF, SELLER + 1, DEBTOR, CURRENCY, FACE, terms, schedule, computed, ASSIGNMENT)
        );
        _different(
            base, _hash(CHAIN_ID, SHELF, SELLER, DEBTOR + 1, CURRENCY, FACE, terms, schedule, computed, ASSIGNMENT)
        );
        _different(
            base, _hash(CHAIN_ID, SHELF, SELLER, DEBTOR, address(0x4444), FACE, terms, schedule, computed, ASSIGNMENT)
        );
        _different(
            base, _hash(CHAIN_ID, SHELF, SELLER, DEBTOR, CURRENCY, FACE + 1, terms, schedule, computed, ASSIGNMENT)
        );

        terms.authority.authorityInvoiceId = bytes32(uint256(AUTHORITY_ID) + 1);
        _different(base, _hashCanonical(terms, schedule, computed, ASSIGNMENT));
        terms = _terms();
        terms.authority.authorityEvidenceCommitment = bytes32(uint256(EVIDENCE) + 1);
        _different(base, _hashCanonical(terms, schedule, computed, ASSIGNMENT));
        terms = _terms();
        terms.authority.verifierConfigId = bytes32(uint256(CONFIG) + 1);
        _different(base, _hashCanonical(terms, schedule, computed, ASSIGNMENT));
        terms = _terms();
        terms.authority.authorityVoucherType = 20;
        _different(base, _hashCanonical(terms, schedule, computed, ASSIGNMENT));
        terms = _terms();
        terms.recourse = false;
        _different(base, _hashCanonical(terms, schedule, computed, ASSIGNMENT));
        terms = _terms();
        terms.authority.issuedAt += 1;
        _different(base, _hashCanonical(terms, schedule, computed, ASSIGNMENT));
        terms = _terms();
        terms.authority.authorityPaymentDueAt += 1;
        _different(base, _hashCanonical(terms, schedule, computed, ASSIGNMENT));

        terms = _terms();
        schedule.nInstallments += 1;
        _different(base, _hashCanonical(terms, schedule, computed, ASSIGNMENT));
        schedule = _schedule();
        schedule.firstMaturity += 1;
        _different(base, _hashCanonical(terms, schedule, computed, ASSIGNMENT));
        schedule = _schedule();
        schedule.interval += 1;
        _different(base, _hashCanonical(terms, schedule, computed, ASSIGNMENT));
        schedule = _schedule();
        schedule.grace += 1;
        _different(base, _hashCanonical(terms, schedule, computed, ASSIGNMENT));

        schedule = _schedule();
        computed.advanceRateBps += 1;
        _different(base, _hashCanonical(terms, schedule, computed, ASSIGNMENT));
        computed = _computed();
        computed.advanceAmount += 1;
        _different(base, _hashCanonical(terms, schedule, computed, ASSIGNMENT));
        computed = _computed();
        computed.holdbackAmount += 1;
        _different(base, _hashCanonical(terms, schedule, computed, ASSIGNMENT));
        computed = _computed();
        computed.tranche += 1;
        _different(base, _hashCanonical(terms, schedule, computed, ASSIGNMENT));
        computed = _computed();
        _different(base, _hashCanonical(terms, schedule, computed, bytes32(uint256(ASSIGNMENT) + 1)));
    }

    function test_everyDocumentFieldIsSensitiveAndAssignmentBindsBothDomains() public pure {
        ReceivableCommitment.AuthorityRef memory authority = _authority();
        BINV.DocBundle memory docs = _goldenDocs();
        bytes32 baseDocument = ReceivableCommitment.hashDocumentBundle(authority, docs, true);
        bytes32 baseReceivable = _hashCanonical(_terms(), _schedule(), _computed(), docs.assignmentHash);

        authority.authorityInvoiceId = bytes32(uint256(AUTHORITY_ID) + 1);
        _different(baseDocument, ReceivableCommitment.hashDocumentBundle(authority, docs, true));
        authority = _authority();
        authority.authorityVoucherType = 20;
        _different(baseDocument, ReceivableCommitment.hashDocumentBundle(authority, docs, true));
        authority = _authority();
        _different(baseDocument, ReceivableCommitment.hashDocumentBundle(authority, docs, false));

        docs.invoiceDocHash = bytes32(uint256(docs.invoiceDocHash) + 1);
        _different(baseDocument, ReceivableCommitment.hashDocumentBundle(authority, docs, true));
        assertEq(baseReceivable, _hashCanonical(_terms(), _schedule(), _computed(), _goldenDocs().assignmentHash));
        docs = _goldenDocs();
        docs.paymentInstructionHash = bytes32(uint256(docs.paymentInstructionHash) + 1);
        _different(baseDocument, ReceivableCommitment.hashDocumentBundle(authority, docs, true));
        assertEq(baseReceivable, _hashCanonical(_terms(), _schedule(), _computed(), _goldenDocs().assignmentHash));
        docs = _goldenDocs();
        docs.servicingPolicyHash = bytes32(uint256(docs.servicingPolicyHash) + 1);
        _different(baseDocument, ReceivableCommitment.hashDocumentBundle(authority, docs, true));
        assertEq(baseReceivable, _hashCanonical(_terms(), _schedule(), _computed(), _goldenDocs().assignmentHash));
        docs = _goldenDocs();
        docs.disputePolicyHash = bytes32(uint256(docs.disputePolicyHash) + 1);
        _different(baseDocument, ReceivableCommitment.hashDocumentBundle(authority, docs, true));
        assertEq(baseReceivable, _hashCanonical(_terms(), _schedule(), _computed(), _goldenDocs().assignmentHash));

        docs = _goldenDocs();
        docs.assignmentHash = bytes32(uint256(docs.assignmentHash) + 1);
        _different(baseDocument, ReceivableCommitment.hashDocumentBundle(authority, docs, true));
        _different(baseReceivable, _hashCanonical(_terms(), _schedule(), _computed(), docs.assignmentHash));
    }

    function test_authorityIdRemainsOpaqueAndChainIndependent() public pure {
        ReceivableCommitment.FundingTerms memory terms = _terms();
        bytes32 opaqueId = terms.authority.authorityInvoiceId;
        bytes32 first = _hashCanonical(terms, _schedule(), _computed(), ASSIGNMENT);
        bytes32 second =
            _hash(CHAIN_ID + 1, SHELF, SELLER, DEBTOR, CURRENCY, FACE, terms, _schedule(), _computed(), ASSIGNMENT);

        assertEq(terms.authority.authorityInvoiceId, opaqueId);
        assertEq(opaqueId, AUTHORITY_ID);
        assertNotEq(first, second, "receivable is chain-bound while authority ID is not recomputed");
    }

    function test_evidenceAndDocumentsCannotCreateANewAuthorityId() public pure {
        ReceivableCommitment.FundingTerms memory terms = _terms();
        bytes32 opaqueId = terms.authority.authorityInvoiceId;
        bytes32 beforeReceivable = _hashCanonical(terms, _schedule(), _computed(), ASSIGNMENT);
        terms.authority.authorityEvidenceCommitment = keccak256("changed synthetic evidence");
        bytes32 afterReceivable = _hashCanonical(terms, _schedule(), _computed(), ASSIGNMENT);

        BINV.DocBundle memory docs = _goldenDocs();
        bytes32 beforeDocument = ReceivableCommitment.hashDocumentBundle(terms.authority, docs, true);
        docs.invoiceDocHash = keccak256("changed PDF");
        bytes32 afterDocument = ReceivableCommitment.hashDocumentBundle(terms.authority, docs, true);

        assertEq(terms.authority.authorityInvoiceId, opaqueId);
        assertNotEq(beforeReceivable, afterReceivable);
        assertNotEq(beforeDocument, afterDocument);
    }

    function test_hashesUseAbiEncodeNotPackedEncoding() public pure {
        ReceivableCommitment.FundingTerms memory terms = _terms();
        ReceivableCommitment.ScheduleTerms memory schedule = _schedule();
        ReceivableCommitment.ComputedFundingTerms memory computed = _computed();
        bytes memory packed = abi.encodePacked(
            ReceivableCommitment.RECEIVABLE_DOMAIN,
            ReceivableCommitment.VERSION,
            CHAIN_ID,
            SHELF,
            SELLER,
            DEBTOR,
            terms.authority.authorityInvoiceId,
            terms.authority.authorityEvidenceCommitment,
            terms.authority.verifierConfigId,
            terms.authority.authorityVoucherType,
            CURRENCY,
            FACE
        );
        packed = bytes.concat(
            packed,
            abi.encodePacked(
                terms.recourse,
                computed.advanceRateBps,
                computed.advanceAmount,
                computed.holdbackAmount,
                terms.authority.issuedAt,
                terms.authority.authorityPaymentDueAt,
                schedule.nInstallments,
                schedule.firstMaturity,
                schedule.interval,
                schedule.grace,
                computed.tranche,
                ASSIGNMENT
            )
        );
        assertNotEq(_hashCanonical(terms, schedule, computed, ASSIGNMENT), keccak256(packed));

        BINV.DocBundle memory docs = _goldenDocs();
        bytes32 packedDocument = keccak256(
            abi.encodePacked(
                ReceivableCommitment.DOCUMENT_DOMAIN,
                ReceivableCommitment.VERSION,
                terms.authority.authorityInvoiceId,
                terms.authority.authorityVoucherType,
                docs.invoiceDocHash,
                docs.assignmentHash,
                docs.paymentInstructionHash,
                docs.servicingPolicyHash,
                docs.disputePolicyHash,
                true
            )
        );
        assertNotEq(ReceivableCommitment.hashDocumentBundle(terms.authority, docs, true), packedDocument);
    }

    function _authority() internal pure returns (ReceivableCommitment.AuthorityRef memory) {
        return ReceivableCommitment.AuthorityRef({
            schemaVersion: 1,
            authorityInvoiceId: AUTHORITY_ID,
            authorityEvidenceCommitment: EVIDENCE,
            verifierConfigId: CONFIG,
            authorityVoucherType: 19,
            issuedAt: 1_780_000_000,
            authorityPaymentDueAt: 1_782_592_000
        });
    }

    function _terms() internal pure returns (ReceivableCommitment.FundingTerms memory) {
        return ReceivableCommitment.FundingTerms({authority: _authority(), recourse: true});
    }

    function _schedule() internal pure returns (ReceivableCommitment.ScheduleTerms memory) {
        return ReceivableCommitment.ScheduleTerms({
            nInstallments: 4, firstMaturity: 1_780_648_000, interval: 648_000, grace: 432_000
        });
    }

    function _computed() internal pure returns (ReceivableCommitment.ComputedFundingTerms memory) {
        return ReceivableCommitment.ComputedFundingTerms({
            advanceRateBps: 8_000, advanceAmount: 800_000_000, holdbackAmount: 200_000_000, tranche: 0
        });
    }

    function _goldenDocs() internal pure returns (BINV.DocBundle memory) {
        return BINV.DocBundle({
            invoiceDocHash: 0x1111111111111111111111111111111111111111111111111111111111111111,
            assignmentHash: 0x2222222222222222222222222222222222222222222222222222222222222222,
            paymentInstructionHash: 0x3333333333333333333333333333333333333333333333333333333333333333,
            servicingPolicyHash: 0x4444444444444444444444444444444444444444444444444444444444444444,
            disputePolicyHash: 0x5555555555555555555555555555555555555555555555555555555555555555
        });
    }

    function _hashCanonical(
        ReceivableCommitment.FundingTerms memory terms,
        ReceivableCommitment.ScheduleTerms memory schedule,
        ReceivableCommitment.ComputedFundingTerms memory computed,
        bytes32 assignmentHash
    ) internal pure returns (bytes32) {
        return _hash(CHAIN_ID, SHELF, SELLER, DEBTOR, CURRENCY, FACE, terms, schedule, computed, assignmentHash);
    }

    function _hash(
        uint256 chainId,
        address invoiceShelf,
        uint256 sellerAgentId,
        uint256 debtorAgentId,
        address currency,
        uint128 faceAmount,
        ReceivableCommitment.FundingTerms memory terms,
        ReceivableCommitment.ScheduleTerms memory schedule,
        ReceivableCommitment.ComputedFundingTerms memory computed,
        bytes32 assignmentHash
    ) internal pure returns (bytes32) {
        return ReceivableCommitment.hashReceivable(
            chainId,
            invoiceShelf,
            sellerAgentId,
            debtorAgentId,
            currency,
            faceAmount,
            terms,
            schedule,
            computed,
            assignmentHash
        );
    }

    function _different(bytes32 left, bytes32 right) internal pure {
        assertNotEq(left, right);
    }
}

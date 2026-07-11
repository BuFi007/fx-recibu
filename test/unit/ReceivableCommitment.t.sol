// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {BINV} from "../../src/invoice/BINV.sol";
import {ReceivableCommitment} from "../../src/libraries/ReceivableCommitment.sol";

contract ReceivableCommitmentTest is Test {
    uint256 internal constant CHAIN_ID = 42_161;
    uint256 internal constant SELLER = 101;
    uint256 internal constant DEBTOR = 202;
    address internal constant CURRENCY = 0x1111111111111111111111111111111111111111;
    uint128 internal constant FACE = 12_345_678;
    bytes32 internal constant CANONICAL_INVOICE_COMMITMENT_HASH =
        0x3d979a1a760497ac02f1e95b48336d2546923073af0640a875b1afc526a3e69a;
    bytes32 internal constant AUTHORITY_ID = 0xa40638045e4d986bcfb019ec8816fea2713a8a808ac7687eed9517bb4f2b8b66;
    bytes32 internal constant ASSIGNMENT = keccak256("assignment-v1");
    bytes32 internal constant GOLDEN_COMMITMENT = 0x716a92ecdb4bbfa083738f6b6679749e8abd99fa47103140e7cd682f98411243;

    function _terms() internal pure returns (ReceivableCommitment.Terms memory) {
        return ReceivableCommitment.Terms({
            canonicalInvoiceCommitmentHash: CANONICAL_INVOICE_COMMITMENT_HASH,
            issuedAt: 1_700_000_000,
            dueAt: 1_702_592_000
        });
    }

    function test_authorityInvoiceIdMatchesCrossRepositoryGoldenVector() public pure {
        bytes32 actual = ReceivableCommitment.authorityInvoiceId(CANONICAL_INVOICE_COMMITMENT_HASH);
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("BUFI_ARCA_FACTURA_E_AUTHORITY_INVOICE_ID_V1"), uint16(1), CANONICAL_INVOICE_COMMITMENT_HASH
            )
        );
        assertEq(expected, AUTHORITY_ID);
        assertEq(actual, AUTHORITY_ID);
    }

    function _docs() internal pure returns (BINV.DocBundle memory) {
        return BINV.DocBundle({
            invoiceDocHash: keccak256("invoice"),
            assignmentHash: ASSIGNMENT,
            paymentInstructionHash: keccak256("payment"),
            servicingPolicyHash: keccak256("servicing"),
            disputePolicyHash: keccak256("dispute")
        });
    }

    function _commit(
        uint256 chainId,
        uint256 seller,
        uint256 debtor,
        address currency,
        uint128 face,
        ReceivableCommitment.Terms memory terms,
        bytes32 assignment
    ) internal pure returns (bytes32) {
        return ReceivableCommitment.compute(chainId, seller, debtor, currency, face, terms, assignment);
    }

    function test_goldenVectorMatchesIndependentEncoding() public pure {
        ReceivableCommitment.Terms memory terms = _terms();
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("BUFI_FX_RECIBU_RECEIVABLE_COMMITMENT_V1"),
                uint16(1),
                CHAIN_ID,
                SELLER,
                DEBTOR,
                AUTHORITY_ID,
                CURRENCY,
                FACE,
                uint64(1_700_000_000),
                uint64(1_702_592_000),
                ASSIGNMENT
            )
        );
        bytes32 actual = _commit(CHAIN_ID, SELLER, DEBTOR, CURRENCY, FACE, terms, ASSIGNMENT);
        assertEq(expected, GOLDEN_COMMITMENT);
        assertEq(actual, GOLDEN_COMMITMENT);
    }

    function test_eachEconomicFieldChangesCommitment() public pure {
        ReceivableCommitment.Terms memory terms = _terms();
        bytes32 baseline = _commit(CHAIN_ID, SELLER, DEBTOR, CURRENCY, FACE, terms, ASSIGNMENT);

        assertNotEq(_commit(CHAIN_ID + 1, SELLER, DEBTOR, CURRENCY, FACE, terms, ASSIGNMENT), baseline);
        assertNotEq(_commit(CHAIN_ID, SELLER + 1, DEBTOR, CURRENCY, FACE, terms, ASSIGNMENT), baseline);
        assertNotEq(_commit(CHAIN_ID, SELLER, DEBTOR + 1, CURRENCY, FACE, terms, ASSIGNMENT), baseline);
        assertNotEq(_commit(CHAIN_ID, SELLER, DEBTOR, address(0x2222), FACE, terms, ASSIGNMENT), baseline);
        assertNotEq(_commit(CHAIN_ID, SELLER, DEBTOR, CURRENCY, FACE + 1, terms, ASSIGNMENT), baseline);

        terms.canonicalInvoiceCommitmentHash = bytes32(uint256(CANONICAL_INVOICE_COMMITMENT_HASH) + 1);
        assertNotEq(_commit(CHAIN_ID, SELLER, DEBTOR, CURRENCY, FACE, terms, ASSIGNMENT), baseline);
        terms = _terms();
        terms.issuedAt += 1;
        assertNotEq(_commit(CHAIN_ID, SELLER, DEBTOR, CURRENCY, FACE, terms, ASSIGNMENT), baseline);
        terms = _terms();
        terms.dueAt += 1;
        assertNotEq(_commit(CHAIN_ID, SELLER, DEBTOR, CURRENCY, FACE, terms, ASSIGNMENT), baseline);
        assertNotEq(
            _commit(CHAIN_ID, SELLER, DEBTOR, CURRENCY, FACE, _terms(), bytes32(uint256(ASSIGNMENT) + 1)), baseline
        );
    }

    function test_bundleHashBindsEveryDocumentButAncillaryDocsDoNotChangeReceivable() public pure {
        BINV.DocBundle memory docs = _docs();
        bytes32 bundle = ReceivableCommitment.hashDocumentBundle(docs);
        bytes32 commitment = _commit(CHAIN_ID, SELLER, DEBTOR, CURRENCY, FACE, _terms(), docs.assignmentHash);

        BINV.DocBundle memory changed = docs;
        changed.invoiceDocHash = bytes32(uint256(changed.invoiceDocHash) + 1);
        assertNotEq(ReceivableCommitment.hashDocumentBundle(changed), bundle);
        assertEq(_commit(CHAIN_ID, SELLER, DEBTOR, CURRENCY, FACE, _terms(), changed.assignmentHash), commitment);
        changed = _docs();
        changed.assignmentHash = bytes32(uint256(changed.assignmentHash) + 1);
        assertNotEq(ReceivableCommitment.hashDocumentBundle(changed), bundle);
        assertNotEq(_commit(CHAIN_ID, SELLER, DEBTOR, CURRENCY, FACE, _terms(), changed.assignmentHash), commitment);
        changed = _docs();
        changed.paymentInstructionHash = bytes32(uint256(changed.paymentInstructionHash) + 1);
        assertNotEq(ReceivableCommitment.hashDocumentBundle(changed), bundle);
        assertEq(_commit(CHAIN_ID, SELLER, DEBTOR, CURRENCY, FACE, _terms(), changed.assignmentHash), commitment);
        changed = _docs();
        changed.servicingPolicyHash = bytes32(uint256(changed.servicingPolicyHash) + 1);
        assertNotEq(ReceivableCommitment.hashDocumentBundle(changed), bundle);
        assertEq(_commit(CHAIN_ID, SELLER, DEBTOR, CURRENCY, FACE, _terms(), changed.assignmentHash), commitment);
        changed = _docs();
        changed.disputePolicyHash = bytes32(uint256(changed.disputePolicyHash) + 1);
        assertNotEq(ReceivableCommitment.hashDocumentBundle(changed), bundle);
        assertEq(_commit(CHAIN_ID, SELLER, DEBTOR, CURRENCY, FACE, _terms(), changed.assignmentHash), commitment);
    }
}
